;;; ebasecamp-command-tests.el --- ebasecamp 生命周期命令测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T3.1 生命周期命令层与 T3.3 端口冲突检测的 ERT 测试。
;;
;; 覆盖范围：
;; - 纯函数：`ebasecamp-command-service-key'（服务标识归一）、
;;   `ebasecamp-command-split-keys'（按 scope 分流 shared / per-project，
;;   含未知 group/service 报错、空 KEYS 取全量、只有 shared 组时 :project 为
;;   nil、项目级 scope 覆盖）、`ebasecamp-command-compose-args'（四个动作的
;;   参数顺序与 down 的约束）；
;; - 执行层：`ebasecamp-command-run' 的分支派发次数、`on-complete' 结果 plist、
;;   并发互斥（`ebasecamp-command-busy'）、失败分支的 stderr 透传、
;;   `ebasecamp-command-ensure-network' 的 inspect/create 短路逻辑。
;;
;; **本文件绝不执行真实 docker**：`ebasecamp-docker-run-async' /
;; `ebasecamp-docker-run-sync' / `ebasecamp-compose-write' 一律用 `cl-letf'
;; mock；端口探测一律注入替身函数，不做真实 bind。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebasecamp-model)
(require 'ebasecamp-compose)
(require 'ebasecamp-docker)
(require 'ebasecamp-command)

;;; 测试脚手架

(defmacro ebasecamp-command-test--clean (&rest body)
  "在清空的注册表、临时缓存目录与清空的 pending 表下执行 BODY，结束后清理。"
  (declare (indent 0) (debug t))
  `(let ((ebasecamp-cache-directory
          (file-name-as-directory (make-temp-file "ebasecamp-command-test-" t))))
     (ebasecamp-model-reset)
     (clrhash ebasecamp-command--pending)
     (unwind-protect
         (progn ,@body)
       (ebasecamp-model-reset)
       (clrhash ebasecamp-command--pending)
       (ignore-errors (delete-directory ebasecamp-cache-directory t)))))

(defun ebasecamp-command-test--mixed ()
  "构造混合清单：shared 组 cache（redis）+ per-project 组 db（mysql）。
返回 myapp 项目对象。"
  (ebasecamp-define-group cache
    :title "缓存"
    :scope shared
    :services
    ((redis :image "redis:7" :ports ((6379 . 6379)))))
  (ebasecamp-define-group db
    :scope per-project
    :services
    ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))))
  (ebasecamp-define-project myapp :groups ((cache) (db)))
  (ebasecamp-model-project 'myapp))

(defun ebasecamp-command-test--shared-only ()
  "构造只引用 shared 组的项目，返回 myapp 项目对象。"
  (ebasecamp-define-group cache
    :title "缓存"
    :scope shared
    :services
    ((redis :image "redis:7" :ports ((6379 . 6379)))
     (memcached :image "memcached:1" :ports ((11211 . 11211)))))
  (ebasecamp-define-project myapp :groups ((cache)))
  (ebasecamp-model-project 'myapp))

(defun ebasecamp-command-test--duplicate ()
  "构造两个服务 published 端口相同的清单（3306），返回 myapp 项目对象。"
  (ebasecamp-define-group db
    :scope per-project
    :services
    ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))
     (mysql-ro :image "mysql:8.4" :ports ((3306 . 3306)))))
  (ebasecamp-define-project myapp :groups ((db)))
  (ebasecamp-model-project 'myapp))

(defun ebasecamp-command-test--single-port ()
  "构造单服务（published 3306）的清单，返回 myapp 项目对象。"
  (ebasecamp-define-group db
    :scope per-project
    :services
    ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))))
  (ebasecamp-define-project myapp :groups ((db)))
  (ebasecamp-model-project 'myapp))

(defun ebasecamp-command-test--no-ports ()
  "构造无 published 端口的服务，返回 myapp 项目对象。"
  (ebasecamp-define-group app
    :scope per-project
    :services
    ((web :image "nginx:1")))
  (ebasecamp-define-project myapp :groups ((app)))
  (ebasecamp-model-project 'myapp))

(defun ebasecamp-command-test--cross-depends ()
  "构造跨 scope 依赖的清单，返回 myapp 项目对象。
shared 组 cache 提供 redis；per-project 组 app 提供 api，其 depends-on 指向
shared 组的 redis —— per-project 生成物里没有 redis 定义。"
  (ebasecamp-define-group cache
    :title "缓存"
    :scope shared
    :services
    ((redis :image "redis:7" :ports ((6379 . 6379)))))
  (ebasecamp-define-group app
    :scope per-project
    :services
    ((api :image "app:1" :depends-on ("redis"))))
  (ebasecamp-define-project myapp :groups ((cache) (app)))
  (ebasecamp-model-project 'myapp))

(defun ebasecamp-command-test--stub-sync (exit stderr)
  "构造 `ebasecamp-docker-run-sync' 的替身，恒返回 EXIT / STDERR。"
  (lambda (_args &rest _) (list :exit exit :stdout "" :stderr stderr)))

;;; T3.1 纯函数：service-key

(ert-deftest ebasecamp-command-test-service-key-string ()
  "服务标识：\"group/service\" 字符串原样（规范化）返回。"
  (should (equal "mysql/db" (ebasecamp-command-service-key "mysql/db"))))

(ert-deftest ebasecamp-command-test-service-key-plist ()
  "服务标识：plist RECORD 归一为 \"group/service\"。"
  (should (equal "mysql/db"
                 (ebasecamp-command-service-key
                  (list :project "myapp" :group "mysql" :service "db"))))
  (should (equal "mysql/db"
                 (ebasecamp-command-service-key
                  (list :group 'mysql :service 'db)))))

(ert-deftest ebasecamp-command-test-service-key-invalid ()
  "服务标识：缺少斜线或为空时报 ebasecamp-command-error。"
  (should-error (ebasecamp-command-service-key "mysql")
                :type 'ebasecamp-command-error)
  (should-error (ebasecamp-command-service-key "/db")
                :type 'ebasecamp-command-error)
  (should-error (ebasecamp-command-service-key "mysql/")
                :type 'ebasecamp-command-error))

;;; T3.1 纯函数：split-keys

(ert-deftest ebasecamp-command-test-split-keys-mixed-scopes ()
  "KEYS 跨 shared 与 per-project → 两个分支，服务名与项目名各自正确。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--mixed))
           (split (ebasecamp-command-split-keys
                   project '("cache/redis" "db/mysql")))
           (shared (plist-get split :shared))
           (own (plist-get split :project)))
      (should shared)
      (should own)
      (should (equal "ebc-shared" (plist-get shared :name)))
      (should (equal "ebc-myapp" (plist-get own :name)))
      (should (equal '("redis") (plist-get shared :services)))
      (should (equal '("mysql") (plist-get own :services)))
      (should (string-match-p "/_shared/compose\\.yaml\\'"
                              (plist-get shared :file)))
      (should (string-match-p "/myapp/compose\\.yaml\\'" (plist-get own :file))))))

(ert-deftest ebasecamp-command-test-split-keys-empty-means-all ()
  "KEYS 为空 → 每个 scope 下全部服务。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--mixed))
           (split (ebasecamp-command-split-keys project nil)))
      (should (equal '("redis") (plist-get (plist-get split :shared) :services)))
      (should (equal '("mysql") (plist-get (plist-get split :project) :services))))))

(ert-deftest ebasecamp-command-test-split-keys-unknown-group ()
  "未知 group 或未知 service → ebasecamp-command-error。"
  (ebasecamp-command-test--clean
    (let ((project (ebasecamp-command-test--mixed)))
      (should-error (ebasecamp-command-split-keys project '("nope/redis"))
                    :type 'ebasecamp-command-error)
      (should-error (ebasecamp-command-split-keys project '("db/nope"))
                    :type 'ebasecamp-command-error))))

(ert-deftest ebasecamp-command-test-split-keys-shared-only ()
  "只有 shared 组时 :project 分支为 nil。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--shared-only))
           (split (ebasecamp-command-split-keys project nil)))
      (should-not (plist-get split :project))
      (should (equal "ebc-shared" (plist-get (plist-get split :shared) :name)))
      (should (equal '("redis" "memcached")
                     (plist-get (plist-get split :shared) :services))))))

(ert-deftest ebasecamp-command-test-split-keys-scope-override ()
  "项目级 group-ref 的 :scope 覆盖生效：shared 组被声明为 per-project 后进 project 分支。"
  (ebasecamp-command-test--clean
    (ebasecamp-define-group cache
      :title "缓存"
      :scope shared
      :services
      ((redis :image "redis:7" :ports ((6379 . 6379)))))
    (ebasecamp-define-project myapp :groups ((cache :scope per-project)))
    (let* ((project (ebasecamp-model-project 'myapp))
           (split (ebasecamp-command-split-keys project nil)))
      (should-not (plist-get split :shared))
      (should (equal "ebc-myapp" (plist-get (plist-get split :project) :name)))
      (should (equal '("redis") (plist-get (plist-get split :project) :services))))))

;;; T3.1 纯函数：compose-args

(ert-deftest ebasecamp-command-test-compose-args-lifecycle ()
  "start / stop / restart 的参数顺序与服务名追加。"
  (should (equal '("compose" "-f" "/tmp/f.yaml" "-p" "ebc-myapp"
                   "up" "-d" "mysql" "redis")
                 (ebasecamp-command-compose-args
                  'start "/tmp/f.yaml" "ebc-myapp" '("mysql" "redis"))))
  (should (equal '("compose" "-f" "/tmp/f.yaml" "-p" "ebc-myapp"
                   "stop" "mysql")
                 (ebasecamp-command-compose-args
                  'stop "/tmp/f.yaml" "ebc-myapp" '("mysql"))))
  (should (equal '("compose" "-f" "/tmp/f.yaml" "-p" "ebc-myapp"
                   "restart" "mysql")
                 (ebasecamp-command-compose-args
                  'restart "/tmp/f.yaml" "ebc-myapp" '("mysql")))))

(ert-deftest ebasecamp-command-test-compose-args-down ()
  "down 不带 -v、不接受服务名；传服务名报错。"
  (should (equal '("compose" "-f" "/tmp/f.yaml" "-p" "ebc-myapp" "down")
                 (ebasecamp-command-compose-args
                  'down "/tmp/f.yaml" "ebc-myapp" nil)))
  (should-error (ebasecamp-command-compose-args
                 'down "/tmp/f.yaml" "ebc-myapp" '("mysql"))
                :type 'ebasecamp-command-error)
  (should-error (ebasecamp-command-compose-args
                 'nope "/tmp/f.yaml" "ebc-myapp" nil)
                :type 'ebasecamp-command-error))

;;; T3.1 执行层

(ert-deftest ebasecamp-command-test-run-dispatches-both-scopes ()
  "run：两个 scope 分支各写一次生成物、各异步执行一次，on-complete 收到 :ok t。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--mixed))
           (writes nil)
           (calls nil)
           (result nil))
      (cl-letf (((symbol-function 'ebasecamp-compose-write)
                 (lambda (_project group-filter)
                   (push group-filter writes)
                   (format "/tmp/%s-compose.yaml"
                           (mapconcat #'symbol-name group-filter "-"))))
                ((symbol-function 'ebasecamp-docker-run-sync)
                 (ebasecamp-command-test--stub-sync 0 ""))
                ((symbol-function 'ebasecamp-docker-run-async)
                 (lambda (args callback &rest _)
                   (push args calls)
                   (funcall callback (list :exit 0 :stdout "" :stderr ""))
                   'fake-process)))
        (let ((processes (ebasecamp-command-run
                          'start project '("cache/redis" "db/mysql")
                          :on-complete (lambda (value) (setq result value)))))
          (should (= 2 (length calls)))
          (should (= 2 (length writes)))
          (should (equal 2 (length processes)))
          (should (eq t (plist-get result :ok)))
          (should (eq 'start (plist-get result :action)))
          (should (eq 'myapp (plist-get result :project)))
          (should (equal 2 (length (plist-get result :results))))
          (should (equal '(project shared)
                         (mapcar (lambda (entry) (plist-get entry :scope))
                                 (plist-get result :results))))
          (should-not (ebasecamp-command-pending-p project)))))))

(ert-deftest ebasecamp-command-test-run-args-per-branch ()
  "run：各自分支使用自己的生成物路径与项目名，服务名只含选中服务。"
  (ebasecamp-command-test--clean
    (let ((project (ebasecamp-command-test--mixed))
          (calls nil))
      (cl-letf (((symbol-function 'ebasecamp-compose-write)
                 (lambda (_project group-filter)
                   (format "/tmp/%s.yaml" (mapconcat #'symbol-name group-filter "-"))))
                ((symbol-function 'ebasecamp-docker-run-sync)
                 (ebasecamp-command-test--stub-sync 0 ""))
                ((symbol-function 'ebasecamp-docker-run-async)
                 (lambda (args callback &rest _)
                   (push args calls)
                   (funcall callback (list :exit 0 :stdout "" :stderr "")))))
        (ebasecamp-command-run 'restart project nil)
        (should (equal 2 (length calls)))
        (let ((shared-args (cl-find-if
                            (lambda (args) (equal "ebc-shared" (nth 4 args)))
                            calls))
              (own-args (cl-find-if
                         (lambda (args) (equal "ebc-myapp" (nth 4 args)))
                         calls)))
          (should shared-args)
          (should own-args)
          (should (equal '("restart" "redis") (nthcdr 5 shared-args)))
          (should (equal '("restart" "mysql") (nthcdr 5 own-args)))
          (should (equal "/tmp/cache.yaml" (nth 2 shared-args)))
          (should (equal "/tmp/db.yaml" (nth 2 own-args))))))))

(ert-deftest ebasecamp-command-test-run-busy ()
  "run 并发：第一次未完成时第二次 → ebasecamp-command-busy。"
  (ebasecamp-command-test--clean
    (let ((project (ebasecamp-command-test--mixed))
          (callbacks nil))
      (cl-letf (((symbol-function 'ebasecamp-compose-write)
                 (lambda (_project _filter) "/tmp/fake.yaml"))
                ((symbol-function 'ebasecamp-docker-run-sync)
                 (ebasecamp-command-test--stub-sync 0 ""))
                ((symbol-function 'ebasecamp-docker-run-async)
                 (lambda (_args callback &rest _)
                   (push callback callbacks)
                   'fake-process)))
        (ebasecamp-command-run 'start project nil)
        (should (ebasecamp-command-pending-p project))
        (should-error (ebasecamp-command-run 'start project nil)
                      :type 'ebasecamp-command-busy)
        ;; 收尾：让所有未完成回调归零，pending 应被清除
        (dolist (callback callbacks)
          (funcall callback (list :exit 0 :stdout "" :stderr "")))
        (should-not (ebasecamp-command-pending-p project))))))

(ert-deftest ebasecamp-command-test-run-failure-keeps-stderr ()
  "run 失败：一个分支退出码 1 → :ok 为 nil，:results 含该 stderr。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--mixed))
           (result nil)
           (index 0))
      (cl-letf (((symbol-function 'ebasecamp-compose-write)
                 (lambda (_project _filter) "/tmp/fake.yaml"))
                ((symbol-function 'ebasecamp-docker-run-sync)
                 (ebasecamp-command-test--stub-sync 0 ""))
                ((symbol-function 'ebasecamp-docker-run-async)
                 (lambda (_args callback &rest _)
                   (setq index (1+ index))
                   (if (= index 1)
                       (funcall callback (list :exit 1 :stdout ""
                                               :stderr "Error: port is already allocated"))
                     (funcall callback (list :exit 0 :stdout "" :stderr "")))
                   'fake-process)))
        (ebasecamp-command-run 'start project nil
                               :on-complete (lambda (value) (setq result value)))
        (should-not (plist-get result :ok))
        (should (equal 1 (plist-get (nth 0 (plist-get result :results)) :exit)))
        (should (equal "Error: port is already allocated"
                       (plist-get (nth 0 (plist-get result :results)) :stderr)))
        (should (= 0 (plist-get (nth 1 (plist-get result :results)) :exit)))))))

(ert-deftest ebasecamp-command-test-run-down-rejects-shared ()
  "down：存在 shared 分支时拒绝（shared 组可能被其他项目使用）。"
  (ebasecamp-command-test--clean
    (let ((project (ebasecamp-command-test--mixed))
          (called 0))
      (cl-letf (((symbol-function 'ebasecamp-compose-write)
                 (lambda (_project _filter) "/tmp/fake.yaml"))
                ((symbol-function 'ebasecamp-docker-run-sync)
                 (ebasecamp-command-test--stub-sync 0 ""))
                ((symbol-function 'ebasecamp-docker-run-async)
                 (lambda (&rest _) (setq called (1+ called)))))
        (should-error (ebasecamp-command-run 'down project nil)
                      :type 'ebasecamp-command-error)
        (should (= 0 called))
        (should-not (ebasecamp-command-pending-p project))))))

(ert-deftest ebasecamp-command-test-run-down-omits-services ()
  "down：即使 KEYS 为空（全量服务）也不追加服务名。"
  (ebasecamp-command-test--clean
    (ebasecamp-define-group db
      :scope per-project
      :services
      ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))))
    (ebasecamp-define-project myapp :groups ((db)))
    (let ((project (ebasecamp-model-project 'myapp))
          (calls nil))
      (cl-letf (((symbol-function 'ebasecamp-compose-write)
                 (lambda (_project _filter) "/tmp/fake.yaml"))
                ((symbol-function 'ebasecamp-docker-run-sync)
                 (ebasecamp-command-test--stub-sync 0 ""))
                ((symbol-function 'ebasecamp-docker-run-async)
                 (lambda (args callback &rest _)
                   (push args calls)
                   (funcall callback (list :exit 0 :stdout "" :stderr "")))))
        (ebasecamp-command-run 'down project nil)
        (should (equal 1 (length calls)))
        (should (equal '("compose" "-f" "/tmp/fake.yaml" "-p" "ebc-myapp" "down")
                       (car calls)))))))

(ert-deftest ebasecamp-command-test-ensure-network-existing ()
  "ensure-network：inspect 成功 → 不调用 create。"
  (let ((calls nil))
    (cl-letf (((symbol-function 'ebasecamp-docker-run-sync)
               (lambda (args &rest _)
                 (push args calls)
                 (list :exit 0 :stdout "[]" :stderr ""))))
      (should (ebasecamp-command-ensure-network))
      (should (equal 1 (length calls)))
      (should (equal '("network" "inspect" "ebasecamp") (car calls))))))

(ert-deftest ebasecamp-command-test-ensure-network-creates ()
  "ensure-network：inspect 失败 → 调用 create。"
  (let ((calls nil))
    (cl-letf (((symbol-function 'ebasecamp-docker-run-sync)
               (lambda (args &rest _)
                 (push args calls)
                 (if (equal "inspect" (nth 1 args))
                     (list :exit 1 :stdout ""
                           :stderr "Error: No such network: ebasecamp")
                   (list :exit 0 :stdout "net-id" :stderr "")))))
      (should (ebasecamp-command-ensure-network))
      (should (equal 2 (length calls)))
      (should (equal '("network" "create" "ebasecamp") (car calls))))))

(ert-deftest ebasecamp-command-test-ensure-network-already-exists ()
  "ensure-network：create 失败但 stderr 含 already exists → 视为成功。"
  (cl-letf (((symbol-function 'ebasecamp-docker-run-sync)
             (lambda (args &rest _)
               (if (equal "inspect" (nth 1 args))
                   (list :exit 1 :stdout "" :stderr "Error: No such network")
                 (list :exit 1 :stdout ""
                       :stderr "Error response from daemon: network with name ebasecamp already exists")))))
    (should (ebasecamp-command-ensure-network))))

(ert-deftest ebasecamp-command-test-ensure-network-failure ()
  "ensure-network：create 失败且非 already exists → ebasecamp-command-error。"
  (cl-letf (((symbol-function 'ebasecamp-docker-run-sync)
             (lambda (args &rest _)
               (if (equal "inspect" (nth 1 args))
                   (list :exit 1 :stdout "" :stderr "Error: No such network")
                 (list :exit 1 :stdout ""
                       :stderr "Error response from daemon: permission denied")))))
    (should-error (ebasecamp-command-ensure-network)
                  :type 'ebasecamp-command-error)))

;;; T3.3 端口冲突检测

(ert-deftest ebasecamp-command-test-port-conflicts-duplicate ()
  "两个服务 published 端口相同 → 1 条 duplicate。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--duplicate))
           (ebasecamp-command--port-free-p (lambda (_port) t))
           (conflicts (ebasecamp-command-port-conflicts project nil)))
      (should (equal 1 (length conflicts)))
      (should (eq 'duplicate (plist-get (car conflicts) :kind)))
      (should (= 3306 (plist-get (car conflicts) :port)))
      (should (equal '("db/mysql" "db/mysql-ro")
                     (plist-get (car conflicts) :services))))))

(ert-deftest ebasecamp-command-test-port-conflicts-busy ()
  "注入探测函数返回 nil → 1 条 busy。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--single-port))
           (ebasecamp-command--port-free-p (lambda (_port) nil))
           (conflicts (ebasecamp-command-port-conflicts project nil)))
      (should (equal 1 (length conflicts)))
      (should (eq 'busy (plist-get (car conflicts) :kind)))
      (should (= 3306 (plist-get (car conflicts) :port)))
      (should (equal "db/mysql" (plist-get (car conflicts) :service)))
      (should (plist-get (car conflicts) :hint)))))

(ert-deftest ebasecamp-command-test-port-conflicts-none ()
  "全部空闲 → nil。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--single-port))
           (ebasecamp-command--port-free-p (lambda (_port) t)))
      (should-not (ebasecamp-command-port-conflicts project nil)))))

(ert-deftest ebasecamp-command-test-port-conflicts-probe-error ()
  "探测函数 signal → :kind unknown，且不抛出。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--single-port))
           (ebasecamp-command--port-free-p
            (lambda (_port) (error "permission denied")))
           (conflicts (ebasecamp-command-port-conflicts project nil)))
      (should (equal 1 (length conflicts)))
      (should (eq 'unknown (plist-get (car conflicts) :kind)))
      (should (= 3306 (plist-get (car conflicts) :port)))
      (should (equal "db/mysql" (plist-get (car conflicts) :service))))))

(ert-deftest ebasecamp-command-test-port-conflicts-ignores-unpublished ()
  "无 published 端口的服务被忽略，且不调用探测函数。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--no-ports))
           (probes 0)
           (ebasecamp-command--port-free-p
            (lambda (_port) (setq probes (1+ probes)) t)))
      (should-not (ebasecamp-command-port-conflicts project nil))
      (should (= 0 probes)))))

;;; T3.1 补强：跨 scope 的 depends_on

(ert-deftest ebasecamp-command-test-split-keys-requires-shared ()
  "per-project 服务依赖 shared 服务 → project 分支记录 :requires-shared。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--cross-depends))
           (split (ebasecamp-command-split-keys project '("app/api"))))
      ;; 只选了 per-project 服务 → 本次 shared 分支为空
      (should-not (plist-get split :shared))
      (should (equal '("redis")
                     (plist-get (plist-get split :project) :requires-shared)))
      ;; 全量选择时 shared 分支存在，project 分支仍记录同一依赖
      (let ((all (ebasecamp-command-split-keys project nil)))
        (should (equal '("redis") (plist-get (plist-get all :shared) :services)))
        (should (equal '("redis")
                       (plist-get (plist-get all :project) :requires-shared)))
        ;; shared 分支不带 :requires-shared
        (should-not (plist-get (plist-get all :shared) :requires-shared))))))

(ert-deftest ebasecamp-command-test-split-keys-no-requires-shared ()
  "无跨 scope 依赖 → 两个分支的 :requires-shared 均为 nil。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--mixed))
           (split (ebasecamp-command-split-keys project nil)))
      (should-not (plist-get (plist-get split :project) :requires-shared))
      (should-not (plist-get (plist-get split :shared) :requires-shared)))))

(ert-deftest ebasecamp-command-test-run-auto-starts-shared ()
  "run：存在 :requires-shared → shared 先、project 后，:order 与标志正确。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--cross-depends))
           (calls nil)
           (result nil))
      (cl-letf (((symbol-function 'ebasecamp-compose-write)
                 (lambda (_project group-filter)
                   (format "/tmp/%s.yaml"
                           (mapconcat #'symbol-name group-filter "-"))))
                ((symbol-function 'ebasecamp-docker-run-sync)
                 (ebasecamp-command-test--stub-sync 0 ""))
                ((symbol-function 'ebasecamp-docker-run-async)
                 (lambda (args callback &rest _)
                   (push args calls)
                   (funcall callback (list :exit 0 :stdout "" :stderr ""))
                   'fake-process)))
        (ebasecamp-command-run 'start project '("app/api")
                               :on-complete (lambda (value) (setq result value)))
        (setq calls (nreverse calls))
        (should (equal 2 (length calls)))
        ;; 第一条命令是 shared 批次（只含被依赖的 redis）
        (should (equal "ebc-shared" (nth 4 (nth 0 calls))))
        (should (equal '("up" "-d" "redis") (nthcdr 5 (nth 0 calls))))
        ;; 第二条是 project 批次
        (should (equal "ebc-myapp" (nth 4 (nth 1 calls))))
        (should (equal '("up" "-d" "api") (nthcdr 5 (nth 1 calls))))
        (should (equal '(shared project) (plist-get result :order)))
        (should (eq t (plist-get result :auto-started-shared)))
        (should (eq t (plist-get result :ok)))
        (should-not (ebasecamp-command-pending-p project))))))

(ert-deftest ebasecamp-command-test-run-shared-failure-aborts-project ()
  "run：shared 批次失败 → project 分支未执行，:ok nil，shared 结果标 :failed。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--cross-depends))
           (calls nil)
           (result nil))
      (cl-letf (((symbol-function 'ebasecamp-compose-write)
                 (lambda (_project _filter) "/tmp/fake.yaml"))
                ((symbol-function 'ebasecamp-docker-run-sync)
                 (ebasecamp-command-test--stub-sync 0 ""))
                ((symbol-function 'ebasecamp-docker-run-async)
                 (lambda (args callback &rest _)
                   (push args calls)
                   (funcall callback
                            (list :exit 1 :stdout "" :stderr "Error: shared boom"))
                   'fake-process)))
        (ebasecamp-command-run 'start project '("app/api")
                               :on-complete (lambda (value) (setq result value)))
        (should (= 1 (length calls)))
        (should (equal "ebc-shared" (nth 4 (car calls))))
        (should-not (plist-get result :ok))
        (should (equal '(shared) (plist-get result :order)))
        (let ((shared-result (nth 0 (plist-get result :results))))
          (should (eq 'shared (plist-get shared-result :scope)))
          (should (eq t (plist-get shared-result :failed)))
          (should (equal 1 (plist-get shared-result :exit)))
          (should (equal "Error: shared boom" (plist-get shared-result :stderr))))
        ;; project 分支未执行，标记为 skipped
        (should (eq t (plist-get (nth 1 (plist-get result :results)) :skipped)))
        (should-not (ebasecamp-command-pending-p project))))))

(ert-deftest ebasecamp-command-test-run-unknown-required-shared-service ()
  "run：:requires-shared 指向项目 shared 组中不存在的服务 → ebasecamp-command-error。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--cross-depends))
           (calls 0))
      ;; 分流层保证 :requires-shared 来自 shared 服务集合，这里直接注入越界值
      ;; 验证 run 的清单一致性防御
      (cl-letf (((symbol-function 'ebasecamp-command-split-keys)
                 (lambda (&rest _)
                   (list :project (list :scope 'project
                                        :file "/tmp/own.yaml"
                                        :name "ebc-myapp"
                                        :services '("api")
                                        :groups '(app)
                                        :requires-shared '("ghost"))
                         :shared (list :scope 'shared
                                       :file "/tmp/shared.yaml"
                                       :name "ebc-shared"
                                       :services '("redis")
                                       :groups '(cache)))))
                ((symbol-function 'ebasecamp-compose-write)
                 (lambda (_project _filter) "/tmp/fake.yaml"))
                ((symbol-function 'ebasecamp-docker-run-sync)
                 (ebasecamp-command-test--stub-sync 0 ""))
                ((symbol-function 'ebasecamp-docker-run-async)
                 (lambda (&rest _) (setq calls (1+ calls)))))
        (should-error (ebasecamp-command-run 'start project '("app/api"))
                      :type 'ebasecamp-command-error)
        (should (= 0 calls))
        (should-not (ebasecamp-command-pending-p project))))))

(ert-deftest ebasecamp-command-test-run-without-requires-keeps-single-branch ()
  "run：无跨 scope 依赖 → 只执行 project 分支，:auto-started-shared 为 nil。"
  (ebasecamp-command-test--clean
    (let* ((project (ebasecamp-command-test--mixed))
           (calls nil)
           (result nil))
      (cl-letf (((symbol-function 'ebasecamp-compose-write)
                 (lambda (_project _filter) "/tmp/fake.yaml"))
                ((symbol-function 'ebasecamp-docker-run-sync)
                 (ebasecamp-command-test--stub-sync 0 ""))
                ((symbol-function 'ebasecamp-docker-run-async)
                 (lambda (args callback &rest _)
                   (push args calls)
                   (funcall callback (list :exit 0 :stdout "" :stderr ""))
                   'fake-process)))
        (ebasecamp-command-run 'start project '("db/mysql")
                               :on-complete (lambda (value) (setq result value)))
        (should (equal 1 (length calls)))
        (should (equal "ebc-myapp" (nth 4 (car calls))))
        (should (equal '("up" "-d" "mysql") (nthcdr 5 (car calls))))
        (should-not (plist-get result :auto-started-shared))
        (should (equal '(project) (plist-get result :order)))
        (should (eq t (plist-get result :ok)))))))

;;; 错误条件定义

(ert-deftest ebasecamp-command-test-error-hierarchy ()
  "错误条件：busy 是 command-error 的子类。"
  (should (memq 'ebasecamp-command-error
                (get 'ebasecamp-command-busy 'error-conditions))))
(provide 'ebasecamp-command-tests)
;;; ebasecamp-command-tests.el ends here
