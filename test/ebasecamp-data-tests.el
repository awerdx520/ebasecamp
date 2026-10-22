;;; ebasecamp-data-tests.el --- ebasecamp ETAF Data 适配层测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T2.3：Data 层改为「清单 ∪ 状态」语义后的 ERT 测试。
;;
;; 记录来源不再是 `docker ps' 的产物，而是**清单里定义的服务**：清单有定义
;; 但未启动的服务必须出现，且 `:state' 为 "stopped"。因此每个用例都先构造
;; 清单（`ebasecamp-define-group' / `ebasecamp-define-project'），需要容器
;; 状态的用例再伪造 `ebasecamp-docker-ps' 并刷新快照。
;;
;; 清单 fixture（`ebasecamp-data-test--with-manifest'）：
;;
;; - 组 mysql（shared，2 服务 mysql + mysql-ro）
;; - 组 redis（默认 per-project，1 服务 redis）
;; - 组 web（shared，1 服务 web，双端口）
;; - 项目 myapp  → mysql + redis（3 条记录）
;; - 项目 other  → redis（1 条）
;; - 项目 site   → web（1 条）
;;
;; 记录总数 5；项目名字典序 myapp < other < site。
;;
;; 定时器纪律：本模块不持有轮询（轮询归 `ebasecamp-status'），测试只需保证
;; 每个 controller 都被 `etaf-data-stop' 收尾。

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'etaf)
(require 'ebasecamp-model)
(require 'ebasecamp-data)

;;; 测试脚手架

(defmacro ebasecamp-data-test--with-manifest (&rest body)
  "在清空的模型注册表上定义测试清单后顺序执行 BODY，结束后再清空。"
  (declare (indent 0) (debug t))
  `(progn
     (ebasecamp-model-reset)
     (unwind-protect
         (progn
           (ebasecamp-define-group mysql
             :scope shared
             :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))
                        (mysql-ro :image "mysql:8.4")))
           (ebasecamp-define-group redis
             :services ((redis :image "redis:7" :ports ((6379 . 6379)))))
           (ebasecamp-define-group web
             :scope shared
             :services ((web :image "nginx:1.27"
                             :ports ((8080 . 80) (8443 . 443)))))
           (ebasecamp-define-project myapp :groups ((mysql) (redis)))
           (ebasecamp-define-project other :groups ((redis)))
           (ebasecamp-define-project site :groups ((web)))
           ,@body)
       (ebasecamp-model-reset))))

(defun ebasecamp-data-test--container (project group service state health id)
  "构造一个容器 plist，字段形态与 `ebasecamp-docker-ps' 的产物一致。
PROJECT / GROUP / SERVICE 为标签值，STATE / HEALTH 为容器状态，ID 为容器 ID。"
  (let ((labels (list (cons "ebasecamp.managed" "true")
                      (cons "ebasecamp.project" project)
                      (cons "ebasecamp.group" group)
                      (cons "ebasecamp.service" service)
                      (cons "ebasecamp.scope" "shared"))))
    (list :id id
          :names (format "%s-%s-1" project service)
          :image "mysql:8.4"
          :state state
          :health health
          :ports "0.0.0.0:3306->3306/tcp"
          :labels labels
          :project project
          :group group
          :service service
          :scope "shared")))

(defmacro ebasecamp-data-test--with-status (containers &rest body)
  "在\"最近成功记录\"为 CONTAINERS 快照的上下文里执行 BODY。
用伪造的 `ebasecamp-docker-ps' 走一次真实 `ebasecamp-status-snapshot'，
再动态绑定 `ebasecamp-status--last-records'，使 source 只读快照。"
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'ebasecamp-docker-ps)
              (lambda () ,containers)))
     (let ((ebasecamp-status--last-records
            (ebasecamp-status-normalize (ebasecamp-docker-ps)))
           (ebasecamp-status--last-error nil))
       ,@body)))

(defun ebasecamp-data-test--load-function ()
  "取 `ebasecamp-data-source' 的 `:load' 回调。"
  (plist-get (etaf-data-source-capabilities (ebasecamp-data-source)) :load))

(defun ebasecamp-data-test--services (records)
  "返回 RECORDS 的服务名字符串列表。"
  (mapcar (lambda (record) (plist-get record :service)) records))

(defun ebasecamp-data-test--keys (records)
  "返回 RECORDS 的 \"group/service\" 列表。"
  (mapcar (lambda (record)
            (format "%s/%s"
                    (plist-get record :group)
                    (plist-get record :service)))
          records))

;;; 1. source 对象

(ert-deftest ebasecamp-data-test-source-shape ()
  "source 是合法 ETAF Data source：`:load' / `:item-key' 为函数、provider 为 ebasecamp。"
  (let* ((source (ebasecamp-data-source))
         (capabilities (etaf-data-source-capabilities source)))
    (should (etaf-data-source-p source))
    (should (functionp (plist-get capabilities :load)))
    (should (functionp (plist-get capabilities :item-key)))
    (should (eq (plist-get capabilities :provider) 'ebasecamp))))

;;; 2. 清单 ∪ 状态：清单有定义、docker 无容器

(ert-deftest ebasecamp-data-test-manifest-only-services-are-stopped ()
  "清单有 2 个服务但 docker 无任何容器 → 2 条记录，state 均为 \"stopped\"。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let* ((records (ebasecamp-data-project-records 'myapp))
             ;; myapp 引用 mysql（2 服务）+ redis（1 服务），这里只取 mysql 组
             (group (ebasecamp-data--filter records '(:group "mysql"))))
        (should (= 2 (length group)))
        (should (equal '("mysql" "mysql-ro")
                       (ebasecamp-data-test--services group)))
        (dolist (record group)
          (should (equal "stopped" (plist-get record :state)))
          (should (null (plist-get record :health)))
          (should (null (plist-get record :id)))
          (should (null (plist-get record :names)))
          (should (null (plist-get record :ports))))
        (should (equal "mysql:8.4" (plist-get (car group) :image)))))))

(ert-deftest ebasecamp-data-test-one-running-one-stopped ()
  "清单有 2 个服务、docker 有 1 个 running → 1 条 running + 1 条 stopped。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status
        (list (ebasecamp-data-test--container "myapp" "mysql" "mysql"
                                              "running" "healthy" "abc123"))
      (let* ((records (ebasecamp-data-project-records 'myapp))
             (group (ebasecamp-data--filter records '(:group "mysql")))
             (running (cl-find "mysql" group
                               :key (lambda (r) (plist-get r :service))
                               :test #'equal))
             (stopped (cl-find "mysql-ro" group
                               :key (lambda (r) (plist-get r :service))
                               :test #'equal)))
        (should (= 2 (length group)))
        (should (equal "running" (plist-get running :state)))
        (should (equal "healthy" (plist-get running :health)))
        (should (equal "abc123" (plist-get running :id)))
        (should (equal "myapp-mysql-1" (plist-get running :names)))
        (should (equal "0.0.0.0:3306->3306/tcp" (plist-get running :ports)))
        (should (equal "stopped" (plist-get stopped :state)))
        (should (null (plist-get stopped :id)))))))

;;; 3. desired-ports 渲染

(ert-deftest ebasecamp-data-test-desired-ports ()
  "desired-ports 由服务 ports 渲染：单端口 \"A:B\"，多端口逗号连接，无端口为 nil。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let* ((myapp (ebasecamp-data-project-records 'myapp))
             (mysql (cl-find "mysql" myapp
                             :key (lambda (r) (plist-get r :service))
                             :test #'equal))
             (mysql-ro (cl-find "mysql-ro" myapp
                                :key (lambda (r) (plist-get r :service))
                                :test #'equal))
             (site (ebasecamp-data-project-records 'site)))
        (should (equal "3306:3306" (plist-get mysql :desired-ports)))
        (should (null (plist-get mysql-ro :desired-ports)))
        (should (equal "8080:80,8443:443"
                       (plist-get (car site) :desired-ports)))))))

;;; 4. 排序稳定

(ert-deftest ebasecamp-data-test-project-records-order ()
  "project-records 先按 group 字典序、再按 service 字典序排序。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let ((records (ebasecamp-data-project-records 'myapp)))
        (should (equal '("mysql/mysql" "mysql/mysql-ro" "redis/redis")
                       (ebasecamp-data-test--keys records)))
        ;; 幂等：重复调用顺序完全一致
        (should (equal records (ebasecamp-data-project-records 'myapp)))))))

;;; 5. load 回调的 query 语义

(ert-deftest ebasecamp-data-test-load-all ()
  "query 为 nil 时返回所有项目的记录（按项目名字典序），并带分页字段。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let* ((load (ebasecamp-data-test--load-function))
             (result (funcall load nil 1 20)))
        (should (= 5 (length (plist-get result :items))))
        (should (= 5 (plist-get result :total)))
        (should (= 1 (plist-get result :page)))
        (should (= 20 (plist-get result :page-size)))
        (should (equal '("myapp" "myapp" "myapp" "other" "site")
                       (mapcar (lambda (r) (plist-get r :project))
                               (plist-get result :items))))))))

(ert-deftest ebasecamp-data-test-load-project-string ()
  "query 为字符串时取该项目记录（清单顺序 → group/service 排序）。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let* ((load (ebasecamp-data-test--load-function))
             (result (funcall load "myapp" 1 20)))
        (should (equal 3 (length (plist-get result :items))))
        (should (= 3 (plist-get result :total)))
        (should (equal '("mysql" "mysql-ro" "redis")
                       (ebasecamp-data-test--services
                        (plist-get result :items))))))))

(ert-deftest ebasecamp-data-test-load-project-symbol ()
  "query 为 symbol 时同样按项目名取记录。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let* ((load (ebasecamp-data-test--load-function))
             (result (funcall load 'other 1 20)))
        (should (equal '("redis")
                       (ebasecamp-data-test--services
                        (plist-get result :items))))))))

(ert-deftest ebasecamp-data-test-load-plist-query ()
  "query 为 plist 时先按 `:project' 取项目，再按其余键逐条过滤。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let ((load (ebasecamp-data-test--load-function)))
        (let ((result (funcall load '(:project "myapp" :group "mysql") 1 20)))
          (should (equal 2 (length (plist-get result :items))))
          (should (= 2 (plist-get result :total))))
        (let ((result (funcall load '(:project "myapp" :group "redis") 1 20)))
          (should (equal 1 (length (plist-get result :items)))))
        (let ((result (funcall load '(:project "myapp" :group "nope") 1 20)))
          (should (null (plist-get result :items)))
          (should (= 0 (plist-get result :total))))
        ;; 不给 :project 时跨项目过滤
        (let ((result (funcall load '(:group "redis") 1 20)))
          (should (equal 2 (length (plist-get result :items))))
          (should (equal '("myapp" "other")
                         (mapcar (lambda (r) (plist-get r :project))
                                 (plist-get result :items)))))))))

(ert-deftest ebasecamp-data-test-load-unknown-project ()
  "query 指向不存在的项目时返回空结果，不报错。"
  (ebasecamp-data-test--with-manifest
    (let* ((load (ebasecamp-data-test--load-function))
           (result (funcall load 'nope 1 20)))
      (should (null (plist-get result :items)))
      (should (= 0 (plist-get result :total))))))

(ert-deftest ebasecamp-data-test-load-paging ()
  "分页参数生效：page-size 为 1、page 为 2 时返回第二条记录。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let* ((load (ebasecamp-data-test--load-function))
             (result (funcall load nil 2 1)))
        (should (equal 1 (length (plist-get result :items))))
        (should (equal '("mysql-ro")
                       (ebasecamp-data-test--services
                        (plist-get result :items))))
        (should (= 5 (plist-get result :total)))))))

;;; 6. controller 集成

(ert-deftest ebasecamp-data-test-controller-load ()
  "controller 加载后 items / total 与清单一致，set-query 后重载生效。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let ((controller (etaf-data-controller (ebasecamp-data-source)
                                              :auto-load nil)))
        (unwind-protect
            (progn
              (should (etaf-data-load controller))
              (should (= 5 (length (etaf-value (etaf-data-items controller)))))
              (should (= 5 (etaf-value (etaf-data-total controller))))
              (etaf-data-set-query controller "myapp")
              (should (etaf-data-load controller))
              (should (= 3 (length (etaf-value (etaf-data-items controller)))))
              (should (= 3 (etaf-value (etaf-data-total controller)))))
          (etaf-data-stop controller))))))

;;; 7. refresh 走最新快照

(ert-deftest ebasecamp-data-test-refresh-picks-new-snapshot ()
  "refresh 采新快照后重载：容器从 0 个变 1 个 running，记录状态同步变化。"
  (ebasecamp-data-test--with-manifest
    (let ((containers nil))
      (cl-letf (((symbol-function 'ebasecamp-docker-ps)
                 (lambda () containers)))
        (let ((controller (etaf-data-controller (ebasecamp-data-source)
                                                :auto-load nil))
              (ebasecamp-status--last-records nil)
              (ebasecamp-status--last-error nil))
          (unwind-protect
              (progn
                (should (etaf-data-load controller))
                (should (= 5 (length (etaf-value (etaf-data-items controller)))))
                (let ((stopped (etaf-value (etaf-data-items controller))))
                  (should (cl-every (lambda (record)
                                      (equal "stopped" (plist-get record :state)))
                                    stopped)))
                (setq containers
                      (list (ebasecamp-data-test--container
                             "myapp" "mysql" "mysql" "running" "healthy"
                             "abc123")))
                (should (ebasecamp-data-refresh controller))
                (let ((loaded (etaf-value (etaf-data-items controller)))
                      (running nil))
                  (should (= 5 (length loaded)))
                  (dolist (record loaded)
                    (when (equal "running" (plist-get record :state))
                      (setq running record)))
                  (should running)
                  (should (equal "myapp/mysql/mysql"
                                 (ebasecamp-data--item-key running)))
                  (should (equal "abc123" (plist-get running :id)))))
            (etaf-data-stop controller)))))))

;;; 8. item-key 稳定性

(ert-deftest ebasecamp-data-test-item-key ()
  "item-key 为 \"project/group/service\"，同服务稳定、不同服务可区分。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let* ((source (ebasecamp-data-source))
             (item-key (plist-get (etaf-data-source-capabilities source)
                                  :item-key))
             (records (ebasecamp-data-project-records 'myapp))
             (first (nth 0 records))
             (second (nth 1 records)))
        (should (functionp item-key))
        (should (equal "myapp/mysql/mysql" (funcall item-key first)))
        (should (equal (funcall item-key first) (funcall item-key first)))
        (should-not (equal (funcall item-key first)
                           (funcall item-key second)))))))

(provide 'ebasecamp-data-tests)
;;; ebasecamp-data-tests.el ends here
