;;; ebasecamp-data-tests.el --- ebasecamp 清单 ∪ 状态记录装配层测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T2.3：「清单 ∪ 状态」记录装配的 ERT 测试。C6 起 ETAF Data 适配层
;; （source / controller / load / 过滤 / 分页）已删除，本套测试只覆盖纯装配
;; API：记录装配、组配置实例装配与纯函数辅助。
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
;; 纯函数纪律：本模块不持有轮询、不起定时器、不加载 UI 框架；测试全部是
;; 对纯装配函数及其辅助函数的直接调用。

;;; Code:

(require 'cl-lib)
(require 'ert)
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

(defun ebasecamp-data-test--by-group (records group)
  "返回 RECORDS 中 `:group' 等于 GROUP 的记录（保持原顺序）。"
  (cl-remove-if-not
   (lambda (record) (equal group (plist-get record :group)))
   records))

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

(defun ebasecamp-data-test--record-of (records service)
  "返回 RECORDS 中服务名为 SERVICE 的那条记录；找不到时返回 nil。"
  (cl-find service records
           :key (lambda (record) (plist-get record :service))
           :test #'equal))

;;; 1. 清单 ∪ 状态：清单有定义、docker 无容器

(ert-deftest ebasecamp-data-test-manifest-only-services-are-stopped ()
  "清单有 2 个服务但 docker 无任何容器 → 2 条记录，state 均为 \"stopped\"。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let* ((records (ebasecamp-data-project-records 'myapp))
             ;; myapp 引用 mysql（2 服务）+ redis（1 服务），这里只取 mysql 组
             (group (ebasecamp-data-test--by-group records "mysql")))
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
             (group (ebasecamp-data-test--by-group records "mysql"))
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

;;; 2. desired-ports 渲染

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

;;; 3. 排序稳定

(ert-deftest ebasecamp-data-test-project-records-order ()
  "project-records 先按 group 字典序、再按 service 字典序排序。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let ((records (ebasecamp-data-project-records 'myapp)))
        (should (equal '("mysql/mysql" "mysql/mysql-ro" "redis/redis")
                       (ebasecamp-data-test--keys records)))
        ;; 幂等：重复调用顺序完全一致
        (should (equal records (ebasecamp-data-project-records 'myapp)))))))

;;; 4. item-key 稳定性

(ert-deftest ebasecamp-data-test-item-key ()
  "item-key 为 \"project/group/service\"，同服务稳定、不同服务可区分。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      (let* ((records (ebasecamp-data-project-records 'myapp))
             (first (nth 0 records))
             (second (nth 1 records)))
        (should (equal "myapp/mysql/mysql"
                       (ebasecamp-data--item-key first)))
        (should (equal (ebasecamp-data--item-key first)
                       (ebasecamp-data--item-key first)))
        (should-not (equal (ebasecamp-data--item-key first)
                           (ebasecamp-data--item-key second)))))))

;;; 5. 纯函数辅助：scope 回退 / 项目解析

(ert-deftest ebasecamp-data-test-group-ref-scope ()
  "组引用显式 `:scope' 优先，其次回退组定义的 scope，都没有时按 per-project。"
  (ebasecamp-data-test--with-manifest
    ;; 显式 scope 优先（mysql 定义为 shared，这里显式给 per-project）
    (should (equal "per-project"
                   (ebasecamp-data--group-ref-scope
                    '(:group mysql :scope per-project))))
    (should (equal "shared"
                   (ebasecamp-data--group-ref-scope
                    '(:group mysql :scope "shared"))))
    ;; 无 `:scope' → 回退组定义（mysql = shared，redis = per-project）
    (should (equal "shared"
                   (ebasecamp-data--group-ref-scope '(:group mysql))))
    (should (equal "per-project"
                   (ebasecamp-data--group-ref-scope '(:group redis))))
    ;; 组不存在 → 按 per-project
    (should (equal "per-project"
                   (ebasecamp-data--group-ref-scope
                    '(:group no-such-group))))))

(ert-deftest ebasecamp-data-test-resolve-project ()
  "对象 / symbol / 字符串都解析到同一 ebasecamp-project；无法解析时 nil。"
  (ebasecamp-data-test--with-manifest
    (let ((object (ebasecamp-model-project 'myapp)))
      (should (eq object (ebasecamp-data--resolve-project object)))
      (should (eq object (ebasecamp-data--resolve-project 'myapp)))
      (should (eq object (ebasecamp-data--resolve-project "myapp"))))
    (should (null (ebasecamp-data--resolve-project nil)))
    (should (null (ebasecamp-data--resolve-project 'no-such-project)))
    (should (null (ebasecamp-data--resolve-project "no-such-project")))
    (should (null (ebasecamp-data--resolve-project 42)))))

;;; 6. 组配置实例装配

;; `ebasecamp-data-group-instances' 把「组 → 配置」翻译成 UI 可渲染的
;; 「组 → 配置实例」：每份配置一项，每项的 `:records' 与
;; `ebasecamp-data-project-records' 同构同源（都走 `--service-record'）。
;;
;; 状态匹配分两种（D8）：shared 组按 `:scope "shared"' + `:group' 匹配，
;; **忽略** `:project'（容器标签记的是发起项目，不是本配置的项目）；
;; 其余按 `:project' + `:group' 匹配。

(ert-deftest ebasecamp-data-test-group-instances-two-configs ()
  "组有 2 份配置指向 2 个项目 → 2 个实例，顺序与定义一致。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-define-project prod :title "生产项目")
    (ebasecamp-define-group db
      :services ((pg :image "postgres:16" :ports ((5432 . 5432))))
      :configs ((dev :project myapp) (prod :project prod)))
    (ebasecamp-model-link-configs)
    (ebasecamp-data-test--with-status nil
      (let ((instances (ebasecamp-data-group-instances 'db)))
        (should (= 2 (length instances)))
        (should (equal '("dev" "prod")
                       (mapcar (lambda (instance)
                                 (plist-get instance :config))
                               instances)))
        (should (equal '("myapp" "prod")
                       (mapcar (lambda (instance)
                                 (plist-get instance :project))
                               instances)))
        (should (equal '("myapp" "生产项目")
                       (mapcar (lambda (instance)
                                 (plist-get instance :project-title))
                               instances)))
        (should (equal '("per-project" "per-project")
                       (mapcar (lambda (instance)
                                 (plist-get instance :scope))
                               instances)))
        (dolist (instance instances)
          (let ((records (plist-get instance :records)))
            (should (equal '("pg") (ebasecamp-data-test--services records)))
            (should (equal "stopped"
                           (plist-get (ebasecamp-data-test--record-of
                                       records "pg")
                                      :state)))))))))

(ert-deftest ebasecamp-data-test-group-instances-unreferenced-and-missing ()
  "组无配置且无项目引用 → nil（回退也找不到旧写法关联）；组不存在 → nil。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-define-group unused
      :services ((tool :image "busybox:1.36")))
    (ebasecamp-data-test--with-status nil
      (should (null (ebasecamp-data-group-instances 'unused)))
      (should (null (ebasecamp-data-group-instances
                     (ebasecamp-model-group 'unused))))
      (should (null (ebasecamp-data-group-instances 'no-such-group))))))

(ert-deftest ebasecamp-data-test-group-instances-shared-ignores-project ()
  "shared 组：状态记录的 `:project' 与配置项目不同也能命中（D8）。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-define-group cache
      :scope shared
      :services ((redis :image "redis:7" :ports ((6379 . 6379)))
                 (sentinel :image "redis:7"))
      :configs ((main :project myapp)))
    (ebasecamp-model-link-configs)
    (ebasecamp-data-test--with-status
        (list (ebasecamp-data-test--container "other" "cache" "redis"
                                              "running" "healthy" "c-redis")
              (ebasecamp-data-test--container "myapp" "cache" "sentinel"
                                              "exited" nil "c-sentinel"))
      (let* ((instance (car (ebasecamp-data-group-instances 'cache)))
             (records (plist-get instance :records))
             (redis (ebasecamp-data-test--record-of records "redis"))
             (sentinel (ebasecamp-data-test--record-of records "sentinel")))
        (should (equal "shared" (plist-get instance :scope)))
        (should (equal "myapp" (plist-get instance :project)))
        ;; 状态记录的 project 是 other，仍按 scope+group 命中
        (should (equal "running" (plist-get redis :state)))
        (should (equal "healthy" (plist-get redis :health)))
        (should (equal "c-redis" (plist-get redis :id)))
        (should (equal "exited" (plist-get sentinel :state)))
        (should (equal "c-sentinel" (plist-get sentinel :id)))
        ;; 对照：按 project 过滤的 project-records 看不到那条 running
        (let* ((project-records
                (ebasecamp-data-test--by-group
                 (ebasecamp-data-project-records 'myapp) "cache"))
               (project-redis (ebasecamp-data-test--record-of
                               project-records "redis")))
          (should (equal "stopped" (plist-get project-redis :state))))))))

(ert-deftest ebasecamp-data-test-group-instances-per-project-filters-by-project ()
  "per-project 组：同名组在两个项目都有状态记录时，实例只看到自己项目的记录。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-define-group queue
      :services ((redis :image "redis:7" :ports ((6379 . 6379))))
      :configs ((dev :project myapp) (prod :project other)))
    (ebasecamp-model-link-configs)
    (ebasecamp-data-test--with-status
        (list (ebasecamp-data-test--container "myapp" "queue" "redis"
                                              "running" "healthy" "c-dev")
              (ebasecamp-data-test--container "other" "queue" "redis"
                                              "exited" nil "c-prod"))
      (let* ((instances (ebasecamp-data-group-instances 'queue))
             (dev (nth 0 instances))
             (prod (nth 1 instances))
             (dev-record (ebasecamp-data-test--record-of
                          (plist-get dev :records) "redis"))
             (prod-record (ebasecamp-data-test--record-of
                           (plist-get prod :records) "redis")))
        (should (= 2 (length instances)))
        (should (equal "running" (plist-get dev-record :state)))
        (should (equal "c-dev" (plist-get dev-record :id)))
        (should (equal "exited" (plist-get prod-record :state)))
        (should (equal "c-prod" (plist-get prod-record :id)))
        (should (equal '("myapp") (mapcar (lambda (record)
                                            (plist-get record :project))
                                          (plist-get dev :records))))
        (should (equal '("other") (mapcar (lambda (record)
                                            (plist-get record :project))
                                          (plist-get prod :records))))))))

(ert-deftest ebasecamp-data-test-group-instances-records-match-project-records ()
  "同一组同一项目：实例 `:records' 与 `project-records' 的该组子集逐条 equal。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-define-group cache
      :scope shared
      :services ((redis :image "redis:7" :ports ((6379 . 6379)))
                 (sentinel :image "redis:7"))
      :configs ((main :project myapp)))
    (ebasecamp-model-link-configs)
    (ebasecamp-data-test--with-status
        (list (ebasecamp-data-test--container "myapp" "cache" "redis"
                                              "running" "healthy" "c1"))
      (let* ((instance (car (ebasecamp-data-group-instances 'cache)))
             (instance-records (plist-get instance :records))
             (project-records
              (ebasecamp-data-test--by-group
               (ebasecamp-data-project-records 'myapp) "cache")))
        (should (= 2 (length project-records)))
        (should (= 2 (length instance-records)))
        (should (equal project-records instance-records))
        (should (equal '("redis" "sentinel")
                       (ebasecamp-data-test--services instance-records)))))))

(ert-deftest ebasecamp-data-test-group-instances-uses-overrides ()
  "配置的服务覆盖（端口）反映到实例 `:desired-ports'。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-define-group cache
      :services ((redis :image "redis:7" :ports ((6379 . 6379))))
      :configs ((plain :project myapp)
                (shifted :project other
                         :services ((redis :ports ((6380 . 6379)))))))
    (ebasecamp-model-link-configs)
    (ebasecamp-data-test--with-status nil
      (let* ((instances (ebasecamp-data-group-instances 'cache))
             (plain (nth 0 instances))
             (shifted (nth 1 instances))
             (plain-record (ebasecamp-data-test--record-of
                            (plist-get plain :records) "redis"))
             (shifted-record (ebasecamp-data-test--record-of
                              (plist-get shifted :records) "redis")))
        (should (= 2 (length instances)))
        (should (equal "6379:6379" (plist-get plain-record :desired-ports)))
        (should (equal "6380:6379" (plist-get shifted-record :desired-ports)))
        (should (equal "redis:7" (plist-get shifted-record :image)))))))

(ert-deftest ebasecamp-data-test-group-instances-defensive-without-link ()
  "配置指向的项目不存在（未物化）→ 仍返回实例，记录来自组默认定义，不 signal。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-define-group cache
      :scope shared
      :services ((redis :image "redis:7" :ports ((6379 . 6379))))
      :configs ((main :project ghost)))
    ;; 刻意不调用 `ebasecamp-model-link-configs'：项目 ghost 从未注册
    (ebasecamp-data-test--with-status nil
      (let* ((instances (ebasecamp-data-group-instances 'cache))
             (instance (car instances))
             (records (plist-get instance :records))
             (record (ebasecamp-data-test--record-of records "redis")))
        (should (= 1 (length instances)))
        (should (equal "main" (plist-get instance :config)))
        (should (equal "ghost" (plist-get instance :project)))
        (should (null (plist-get instance :project-title)))
        (should (equal "shared" (plist-get instance :scope)))
        (should (equal '("redis")
                       (ebasecamp-data-test--services records)))
        (should (equal "redis:7" (plist-get record :image)))
        (should (equal "6379:6379" (plist-get record :desired-ports)))
        (should (equal "stopped" (plist-get record :state)))))))

;;; 8. 旧写法（项目侧 :groups）回退（C8）

;; v0.1 清单只在项目侧写 `:groups'，组侧没有 `:configs'。若不回退，组视图
;; 会把「有服务、被项目引用」的组显示成 0 配置的空壳。回退实例沿用配置实例
;; 的键，另加 `:legacy' t、`:config' nil（无配置名）。

(ert-deftest ebasecamp-data-test-group-instances-legacy-fallback ()
  "组无 `:configs' 但被两个项目引用 → 2 个 `:legacy' 实例，按项目名升序。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status nil
      ;; 组 redis 无配置；myapp 与 other 都在项目侧引用它
      (let ((instances (ebasecamp-data-group-instances 'redis)))
        (should (= 2 (length instances)))
        (should (equal '("myapp" "other")
                       (mapcar (lambda (instance)
                                 (plist-get instance :project))
                               instances)))
        (dolist (instance instances)
          (should (eq t (plist-get instance :legacy)))
          (should (null (plist-get instance :config)))
          (should (equal "per-project" (plist-get instance :scope)))
          (should (equal '("redis")
                         (ebasecamp-data-test--services
                          (plist-get instance :records)))))))))

(ert-deftest ebasecamp-data-test-group-instances-legacy-not-mixed ()
  "组有 `:configs' 时只返回配置实例，不混入其他项目的旧写法引用。"
  (ebasecamp-model-reset)
  (unwind-protect
      (progn
        ;; myapp 侧不写 :groups（避免「同项目同组多引用」报错），other 侧仍用旧写法
        (ebasecamp-define-group cache
          :services ((redis :image "redis:7" :ports ((6379 . 6379))))
          :configs ((main :project myapp)))
        (ebasecamp-define-project myapp :groups nil)
        (ebasecamp-define-project other :groups ((cache)))
        (ebasecamp-model-link-configs)
        (ebasecamp-data-test--with-status nil
          (let ((instances (ebasecamp-data-group-instances 'cache)))
            (should (= 1 (length instances)))
            (should (equal "main" (plist-get (car instances) :config)))
            (should (equal "myapp" (plist-get (car instances) :project)))
            (should-not (plist-get (car instances) :legacy)))))
    (ebasecamp-model-reset)))

(ert-deftest ebasecamp-data-test-group-instances-legacy-records ()
  "旧写法实例的 `:records' 与 `project-records' 的该组子集逐条 equal。"
  (ebasecamp-data-test--with-manifest
    (ebasecamp-data-test--with-status
        (list (ebasecamp-data-test--container "myapp" "mysql" "mysql"
                                              "running" "healthy" "c1"))
      (let* ((instance (car (ebasecamp-data-group-instances 'mysql)))
             (project-records
              (ebasecamp-data-test--by-group
               (ebasecamp-data-project-records 'myapp) "mysql")))
        (should (plist-get instance :legacy))
        (should (equal "myapp" (plist-get instance :project)))
        (should (= 2 (length project-records)))
        (should (equal project-records (plist-get instance :records)))
        (should (equal "running"
                       (plist-get (ebasecamp-data-test--record-of
                                   (plist-get instance :records) "mysql")
                                  :state)))))))

(provide 'ebasecamp-data-tests)
;;; ebasecamp-data-tests.el ends here
