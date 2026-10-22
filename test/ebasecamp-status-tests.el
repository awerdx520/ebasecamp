;;; ebasecamp-status-tests.el --- ebasecamp 状态层测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T2.1 状态层（归一化 / 聚合 / 轮询生命周期）的 ERT 测试。
;;
;; 不依赖真实 docker：所有涉 `ebasecamp-docker-ps' 的用例用 `cl-letf' 绑定
;; 其 `symbol-function'，返回构造的容器 plist（字段与
;; `ebasecamp-docker--container-from-json' 的产物一致：既有从标签解出的
;; `:project' 等顶层字段，也有 `:labels' alist）。
;;
;; 定时器纪律：每个启用轮询的用例都在 `unwind-protect' 中调用
;; `ebasecamp-status-stop'，否则遗留的 repeating timer 会泄漏到其他用例，
;; 让 `timer-list' 断言与时序断言变得不可预测。

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ebasecamp-status)

;;; 测试脚手架

(defun ebasecamp-status-test--container (project group service scope state
                                                 health &optional ports)
  "构造一个容器 plist，字段形态与 docker 层产物一致。
PROJECT / GROUP / SERVICE / SCOPE 为标签值，STATE 为容器状态，HEALTH 为
健康状态，PORTS 为端口字符串。"
  (let ((labels nil))
    (push (cons "ebasecamp.managed" "true") labels)
    (when project (push (cons "ebasecamp.project" project) labels))
    (when group (push (cons "ebasecamp.group" group) labels))
    (when service (push (cons "ebasecamp.service" service) labels))
    (when scope (push (cons "ebasecamp.scope" scope) labels))
    (list :id (format "id-%s-%s" (or group "") (or service ""))
          :names (format "%s-%s-1" (or project "") (or service ""))
          :image "mysql:8.4"
          :state state
          :health health
          :ports (or ports "")
          :labels (nreverse labels)
          :project project
          :group group
          :service service
          :scope scope)))

(defconst ebasecamp-status-test--record-keys
  '(:project :group :service :scope :state :health :ports :id :names :image)
  "状态记录必须齐全的字段（缺失值用 nil）。")

(defun ebasecamp-status-test--timer-count (timer)
  "返回 TIMER 在 `timer-list' 中出现的次数（按对象身份比较）。"
  (cl-count timer timer-list :test #'eq))

(defmacro ebasecamp-status-test--with-ps (containers &rest body)
  "在伪造 `ebasecamp-docker-ps'（返回 CONTAINERS）的上下文中执行 BODY。
同时把\"最近一次成功记录\"与\"最近错误\"动态绑定为空，使每个用例的状态
互不污染（定时器不在绑定范围内 —— 它必须由用例的 `unwind-protect' 收尾）。"
  (declare (indent 1) (debug t))
  `(let ((ebasecamp-status--last-records nil)
         (ebasecamp-status--last-error nil))
     (cl-letf (((symbol-function 'ebasecamp-docker-ps)
                (lambda () ,containers)))
       ,@body)))

;;; 1. health 归一

(ert-deftest ebasecamp-status-test-normalize-health-none-empty-nil ()
  "health 为 \"none\" / \"\" / nil 时归一为 nil，\"healthy\" 原样保留。"
  (let* ((records
          (ebasecamp-status-normalize
           (list (ebasecamp-status-test--container "app" "db" "mysql" "shared"
                                                   "running" "none")
                 (ebasecamp-status-test--container "app" "db" "mysql" "shared"
                                                   "running" "")
                 (ebasecamp-status-test--container "app" "db" "mysql" "shared"
                                                   "running" nil)
                 (ebasecamp-status-test--container "app" "db" "mysql" "shared"
                                                   "running" "healthy")
                 (ebasecamp-status-test--container "app" "db" "mysql" "shared"
                                                   "running" "unhealthy"))))
    (should (null (plist-get (nth 0 records) :health)))
    (should (null (plist-get (nth 1 records) :health)))
    (should (null (plist-get (nth 2 records) :health)))
    (should (equal (plist-get (nth 3 records) :health) "healthy"))
    (should (equal (plist-get (nth 4 records) :health) "unhealthy")))))

;;; 2. labels 缺失

(ert-deftest ebasecamp-status-test-normalize-missing-labels ()
  "未注入 ebasecamp 标签的容器：归属字段全部为 nil，但字段本身齐全。"
  (let ((records (ebasecamp-status-normalize
                  (list (list :id "abc" :state "running" :health "none")))))
    (should (= 1 (length records)))
    (let ((record (car records)))
      (dolist (key ebasecamp-status-test--record-keys)
        (should (plist-member record key)))
      (dolist (key '(:project :group :service :scope))
        (should (null (plist-get record key))))
      (should (equal (plist-get record :state) "running"))
      (should (equal (plist-get record :id) "abc")))))

;;; 3. 多容器

(ert-deftest ebasecamp-status-test-normalize-multiple ()
  "多容器按输入顺序逐条归一，字段映射正确。"
  (let ((records
         (ebasecamp-status-normalize
          (list (ebasecamp-status-test--container "app" "db" "mysql" "shared"
                                                  "running" "healthy"
                                                  "0.0.0.0:3306->3306/tcp")
                (ebasecamp-status-test--container "app" "cache" "redis"
                                                  "per-project" "exited" "none")
                (ebasecamp-status-test--container "other" "db" "pg"
                                                  "shared" "created" nil)))))
    (should (= 3 (length records)))
    (should (equal (mapcar (lambda (r) (plist-get r :service)) records)
                   '("mysql" "redis" "pg")))
    (should (equal (plist-get (nth 0 records) :group) "db"))
    (should (equal (plist-get (nth 0 records) :project) "app"))
    (should (equal (plist-get (nth 0 records) :scope) "shared"))
    (should (equal (plist-get (nth 0 records) :ports)
                   "0.0.0.0:3306->3306/tcp"))
    (should (equal (plist-get (nth 0 records) :image) "mysql:8.4"))
    (should (equal (plist-get (nth 1 records) :state) "exited"))
    (should (equal (plist-get (nth 2 records) :state) "created"))))

;;; 4–8. 聚合

(ert-deftest ebasecamp-status-test-aggregate-up ()
  "组内 2 个服务全部 running → state 为 \"up\"，running 与 total 均为 2。"
  (let* ((records
          (ebasecamp-status-normalize
           (list (ebasecamp-status-test--container "myapp" "mysql" "mysql"
                                                   "shared" "running" "healthy")
                 (ebasecamp-status-test--container "myapp" "mysql" "mysql-ro"
                                                   "shared" "running" nil))))
         (aggregate (ebasecamp-status-aggregate records)))
    (should (= 1 (length aggregate)))
    (let ((entry (car aggregate)))
      (should (equal (plist-get entry :project) "myapp"))
      (should (equal (plist-get entry :group) "mysql"))
      (should (equal (plist-get entry :scope) "shared"))
      (should (= 2 (plist-get entry :total)))
      (should (= 2 (plist-get entry :running)))
      (should (= 0 (plist-get entry :unhealthy)))
      (should (equal (plist-get entry :state) "up")))))

(ert-deftest ebasecamp-status-test-aggregate-partial ()
  "一 running 一 exited → state 为 \"partial\"。"
  (let* ((records
          (ebasecamp-status-normalize
           (list (ebasecamp-status-test--container "myapp" "db" "mysql"
                                                   "shared" "running" nil)
                 (ebasecamp-status-test--container "myapp" "db" "pg"
                                                   "shared" "exited" nil))))
         (entry (car (ebasecamp-status-aggregate records))))
    (should (= 2 (plist-get entry :total)))
    (should (= 1 (plist-get entry :running)))
    (should (equal (plist-get entry :state) "partial"))))

(ert-deftest ebasecamp-status-test-aggregate-down ()
  "全部 exited → state 为 \"down\"，running 为 0。"
  (let* ((records
          (ebasecamp-status-normalize
           (list (ebasecamp-status-test--container "myapp" "db" "mysql"
                                                   "shared" "exited" nil)
                 (ebasecamp-status-test--container "myapp" "db" "pg"
                                                   "shared" "created" nil))))
         (entry (car (ebasecamp-status-aggregate records))))
    (should (= 2 (plist-get entry :total)))
    (should (= 0 (plist-get entry :running)))
    (should (equal (plist-get entry :state) "down"))))

(ert-deftest ebasecamp-status-test-aggregate-unhealthy-count ()
  "`:unhealthy' 统计 health 为 \"unhealthy\" 的条数。"
  (let* ((records
          (ebasecamp-status-normalize
           (list (ebasecamp-status-test--container "myapp" "db" "mysql"
                                                   "shared" "running"
                                                   "unhealthy")
                 (ebasecamp-status-test--container "myapp" "db" "pg"
                                                   "shared" "running"
                                                   "unhealthy")
                 (ebasecamp-status-test--container "myapp" "db" "redis"
                                                   "shared" "running"
                                                   "healthy"))))
         (entry (car (ebasecamp-status-aggregate records))))
    (should (= 3 (plist-get entry :total)))
    (should (= 2 (plist-get entry :unhealthy)))
    (should (equal (plist-get entry :state) "up"))))

(ert-deftest ebasecamp-status-test-aggregate-sort-stable ()
  "聚合结果先按 project 字典序、再按 group 字典序排列。"
  (let* ((records
          (ebasecamp-status-normalize
           (list (ebasecamp-status-test--container "beta" "zulu" "s1"
                                                   "shared" "running" nil)
                 (ebasecamp-status-test--container "alpha" "zulu" "s2"
                                                   "shared" "running" nil)
                 (ebasecamp-status-test--container "beta" "alpha" "s3"
                                                   "shared" "exited" nil)
                 (ebasecamp-status-test--container "alpha" "alpha" "s4"
                                                   "shared" "running" nil))))
         (aggregate (ebasecamp-status-aggregate records)))
    (should (equal (mapcar (lambda (e) (list (plist-get e :project)
                                             (plist-get e :group)))
                           aggregate)
                   '(("alpha" "alpha") ("alpha" "zulu")
                     ("beta" "alpha") ("beta" "zulu"))))))

;;; 9. group-records

(ert-deftest ebasecamp-status-test-group-records ()
  "只返回指定 project + group 的记录，且保持输入顺序。"
  (let* ((records
          (ebasecamp-status-normalize
           (list (ebasecamp-status-test--container "myapp" "mysql" "mysql"
                                                   "shared" "running" nil)
                 (ebasecamp-status-test--container "myapp" "redis" "redis"
                                                   "shared" "running" nil)
                 (ebasecamp-status-test--container "other" "mysql" "mysql"
                                                   "shared" "running" nil)
                 (ebasecamp-status-test--container "myapp" "mysql" "mysql-ro"
                                                   "shared" "exited" nil)))))
    (let ((selected (ebasecamp-status-group-records records "myapp" "mysql")))
      (should (equal (mapcar (lambda (r) (plist-get r :service)) selected)
                     '("mysql" "mysql-ro"))))
    (should (null (ebasecamp-status-group-records records "myapp" "absent")))))

;;; 10. start 立即刷新一次

(ert-deftest ebasecamp-status-test-start-refreshes-immediately ()
  "start 后立即刷新一次：last-records 有值、running-p 为 t、回调被调用。"
  (let ((calls 0))
    (unwind-protect
        (progn
          (ebasecamp-status-test--with-ps
              (list (ebasecamp-status-test--container "myapp" "db" "mysql"
                                                      "shared" "running"
                                                      "healthy"))
            (ebasecamp-status-start (lambda () (cl-incf calls)))
            (should (ebasecamp-status-running-p))
            (should (= 1 calls))
            (should (= 1 (length (ebasecamp-status-last-records))))
            (should (null (ebasecamp-status-last-error)))
            (should (equal (plist-get (car (ebasecamp-status-last-records))
                                      :service)
                           "mysql"))))
      (ebasecamp-status-stop))))

;;; 11. start 幂等

(ert-deftest ebasecamp-status-test-start-idempotent ()
  "连续 start 两次：仍只有一个定时器，旧定时器被取消。"
  (unwind-protect
      (progn
        (ebasecamp-status-test--with-ps nil
          (ebasecamp-status-start #'ignore)
          (let ((first-timer ebasecamp-status--timer))
            (should (timerp first-timer))
            (should (= 1 (ebasecamp-status-test--timer-count first-timer)))
            (ebasecamp-status-start #'ignore)
            (should (ebasecamp-status-running-p))
            (should-not (memq first-timer timer-list))
            ;; 内部计数断言：当前持有的 timer 在 `timer-list' 中恰好出现一次
            (should (= 1 (ebasecamp-status-test--timer-count
                          ebasecamp-status--timer))))))
    (ebasecamp-status-stop)))

;;; 12. stop

(ert-deftest ebasecamp-status-test-stop ()
  "stop 后 running-p 为 nil、内部 timer 置 nil，且可重复调用。"
  (unwind-protect
      (progn
        (ebasecamp-status-test--with-ps nil
          (ebasecamp-status-start #'ignore)
          (should (ebasecamp-status-running-p))
          (ebasecamp-status-stop)
          (should-not (ebasecamp-status-running-p))
          (should (null ebasecamp-status--timer))
          ;; 幂等：再次 stop 不报错、状态不变
          (ebasecamp-status-stop)
          (should-not (ebasecamp-status-running-p))))
    (ebasecamp-status-stop)))

;;; 13. docker 报错

(ert-deftest ebasecamp-status-test-start-survives-docker-error ()
  "docker 调用报错时不崩溃、继续轮询，并记录 last-error。"
  (unwind-protect
      (progn
        (cl-letf (((symbol-function 'ebasecamp-docker-ps)
                   (lambda ()
                     (signal 'ebasecamp-docker-exit '(:exit 1)))))
          (ebasecamp-status-start #'ignore)
          (should (ebasecamp-status-running-p))
          (should (ebasecamp-status-last-error))
          (should (null (ebasecamp-status-last-records))))
        ;; 错误后轮询仍活着：手动触发一次 tick 仍不崩溃
        (ebasecamp-status--tick)
        (should (ebasecamp-status-running-p)))
    (ebasecamp-status-stop)))

;;; 14. 轮询回调

(ert-deftest ebasecamp-status-test-polling-calls-function ()
  "间隔 0.1s 时回调在有限时间内被重复调用（至少 2 次）。"
  (let ((ebasecamp-status-refresh-interval 0.1)
        (calls 0)
        (deadline (+ (float-time) 10)))
    (unwind-protect
        (progn
          (ebasecamp-status-test--with-ps
              (list (ebasecamp-status-test--container "myapp" "db" "mysql"
                                                      "shared" "running" nil))
            (ebasecamp-status-start (lambda () (cl-incf calls)))
            (while (and (< calls 2) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should (>= calls 2)))
      (ebasecamp-status-stop))))

(provide 'ebasecamp-status-tests)
;;; ebasecamp-status-tests.el ends here
