;;; ebasecamp-data.el --- ebasecamp 清单 ∪ 状态的 ETAF Data 适配 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.1.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块把「清单」与「容器状态」合并成 UI 可直接消费的记录，并适配为
;; ETAF Data 层的 source 与 controller（`etaf-data-grid' 等组件直接消费）。
;; 只使用 etaf 的公开 API：`etaf-data-source' / `etaf-data-controller' /
;; `etaf-data-load' / `etaf-data-set-query' / `etaf-data-items' /
;; `etaf-data-total' / `etaf-data-stop'，不触碰 `etaf-data--' 私有函数。
;;
;; 数据语义（T2.3 修正）：表格展示的是**清单里定义的服务**，而不是
;; `docker ps' 里恰好存在的容器。清单有定义但未启动的服务必须出现在表里，
;; 其 `:state' 为 "stopped"。因此记录 = 清单服务 ∪ 同名容器状态。
;;
;; 记录字段（plist，字段齐全，缺失值为 nil）：
;;
;;   (:project "myapp" :group "mysql" :service "mysql" :scope "shared"
;;    :image "mysql:8.4" :desired-ports "3306:3306"
;;    :state "running" :health "healthy" :id "…" :names "…"
;;    :ports "0.0.0.0:3306->3306/tcp")
;;
;; - `:project' / `:group' / `:service' 一律为字符串（清单里是 symbol，
;;   这里归一为字符串，与 docker 标签、选择身份一致）；
;; - `:image' 来自清单服务定义；`:desired-ports' 由服务的 `ports' 渲染为
;;   "PUB1:TGT1,PUB2:TGT2"，无端口时为 nil；
;; - `:state' / `:health' / `:id' / `:names' / `:ports' 来自
;;   `ebasecamp-status-last-records' 中三元组相同的记录；未命中时
;;   `:state' 为 "stopped"，其余为 nil；
;; - 排序：先 group 名字典序，再 service 名字典序。
;;
;; 职责边界：
;;
;; - source 的 `:load' **只读**「最近一次成功快照」，不主动执行
;;   `docker ps'。轮询归 `ebasecamp-status'：UI 在轮询回调里调
;;   `etaf-data-load'，本模块不重复采集（避免一次刷新跑两次 docker ps）；
;; - **本模块不起轮询**，controller 由 UI 持有（`:auto-load' 为 nil，
;;   显式 load），销毁时调 `etaf-data-stop'；source 的 `:dispose' 为空 ——
;;   没有任何全局资源。
;;
;; query 语义（`etaf-data-set-query' 可传的值）：
;;
;; - nil —— 所有项目的记录按项目名字典序拼接；
;; - 字符串或 symbol —— 按项目名取该项目记录；
;; - plist（如 `(:project "myapp" :group "mysql")'）—— 先按 `:project'
;;   取得项目记录，再按其余键逐条 AND 过滤。
;;
;; item-key 为 "project/group/service"：容器 ID 在重启后变化，而三元组是
;; 选择状态的稳定身份（也是记录与状态记录的匹配键）。

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'ebasecamp-model)
(require 'ebasecamp-status)

;;; 名字与端口归一

(defun ebasecamp-data--name-string (name)
  "把清单里的 NAME（symbol 或字符串）归一为字符串；nil 返回 nil。"
  (cond
   ((null name) nil)
   ((stringp name) name)
   ((symbolp name) (symbol-name name))
   (t (format "%s" name))))

(defun ebasecamp-data--service-ports (service)
  "把 SERVICE 的 ports 渲染为 \"PUB1:TGT1,PUB2:TGT2\"；无端口返回 nil。"
  (let ((ports (ebasecamp-service-ports service)))
    (when ports
      (mapconcat (lambda (pair)
                   (format "%d:%d" (car pair) (cdr pair)))
                 ports ","))))

(defun ebasecamp-data--item-key (record)
  "返回记录 RECORD 的选择身份 \"project/group/service\"。"
  (format "%s/%s/%s"
          (plist-get record :project)
          (plist-get record :group)
          (plist-get record :service)))

;;; 清单 ∪ 状态

(defun ebasecamp-data--status-index ()
  "返回状态记录索引：hash，键为 item-key，值为状态记录。
只读 `ebasecamp-status-last-records'，不触发任何采集。"
  (let ((table (make-hash-table :test #'equal)))
    (dolist (record (ebasecamp-status-last-records))
      (puthash (ebasecamp-data--item-key record) record table))
    table))

(defun ebasecamp-data--resolve-project (project)
  "把 PROJECT（对象 / symbol / 字符串）解析为 ebasecamp-project 对象。
无法解析时返回 nil。"
  (cond
   ((null project) nil)
   ((ebasecamp-project-p project) project)
   ((symbolp project) (ebasecamp-model-project project))
   ((stringp project) (ebasecamp-model-project (intern project)))
   (t nil)))

(defun ebasecamp-data--group-ref-scope (group-ref)
  "返回组引用 GROUP-REF 的生效 scope 字符串。
组引用未显式给出 `:scope' 时回退到组定义的 scope，仍取不到时按
`per-project'。纯函数。"
  (let ((scope (plist-get group-ref :scope)))
    (ebasecamp-data--name-string
     (or scope
         (let ((group (ebasecamp-model-group
                       (plist-get group-ref :group))))
           (and group (ebasecamp-group-scope group)))
         'per-project))))

(defun ebasecamp-data--record-lessp (a b)
  "记录 A 是否应排在 B 之前：先 group 名字典序，再 service 名字典序。纯函数。"
  (let ((group-a (or (plist-get a :group) ""))
        (group-b (or (plist-get b :group) "")))
    (if (equal group-a group-b)
        (string< (or (plist-get a :service) "")
                 (or (plist-get b :service) ""))
      (string< group-a group-b))))

(defun ebasecamp-data--service-record (project-name group-name scope status
                                                    service)
  "构造一条服务记录。
PROJECT-NAME / GROUP-NAME / SCOPE 为字符串，STATUS 为命中的状态记录（可为
nil），SERVICE 为清单服务对象。纯函数。"
  (list :project project-name
        :group group-name
        :service (ebasecamp-data--name-string
                  (ebasecamp-service-name service))
        :scope scope
        :image (ebasecamp-service-image service)
        :desired-ports (ebasecamp-data--service-ports service)
        :state (or (plist-get status :state) "stopped")
        :health (plist-get status :health)
        :id (plist-get status :id)
        :names (plist-get status :names)
        :ports (plist-get status :ports)))

(defun ebasecamp-data-project-records (project)
  "返回项目 PROJECT 的服务记录列表（清单 ∪ 状态，纯函数）。
PROJECT 可为 ebasecamp-project 对象、symbol 或字符串项目名；无法解析时返回
nil。每条记录字段见模块 Commentary；清单中有定义但 docker 中无容器的服务
其 `:state' 为 \"stopped\"。排序先 group 名字典序、再 service 名字典序。"
  (when-let* ((object (ebasecamp-data--resolve-project project)))
    (let ((project-name (ebasecamp-data--name-string
                         (ebasecamp-project-name object)))
          (index (ebasecamp-data--status-index))
          (records nil))
      (dolist (group-ref (ebasecamp-project-groups object))
        (let ((group-name (ebasecamp-data--name-string
                           (plist-get group-ref :group)))
              (scope (ebasecamp-data--group-ref-scope group-ref)))
          (dolist (service (ebasecamp-model-resolve-services object group-ref))
            (let* ((service-name (ebasecamp-data--name-string
                                  (ebasecamp-service-name service)))
                   (key (format "%s/%s/%s" project-name group-name service-name))
                   (status (gethash key index)))
              (push (ebasecamp-data--service-record
                     project-name group-name scope status service)
                    records)))))
      (sort records #'ebasecamp-data--record-lessp))))

;;; 组配置实例装配

;; 「组 → 配置 → 项目实例」是 v0.2 界面的渲染单位：组是全局第一等对象，
;; 一份配置关联一个项目。`ebasecamp-data-group-instances' 把二者翻译成 UI
;; 可直接消费的实例列表，每份配置一项，记录仍走 `--service-record'，因此与
;; `ebasecamp-data-project-records' 同构同源。

(defun ebasecamp-data--resolve-group (group)
  "把 GROUP（对象 / symbol / 字符串）解析为 ebasecamp-group 对象。
无法解析时返回 nil。"
  (cond
   ((null group) nil)
   ((ebasecamp-group-p group) group)
   ((symbolp group) (ebasecamp-model-group group))
   ((stringp group) (ebasecamp-model-group (intern group)))
   (t nil)))

(defun ebasecamp-data--config-ref (project group-name scope)
  "返回配置物化后的组引用（纯函数）。
优先取 PROJECT 的 groups 槽里 `:group' 等于 GROUP-NAME 的第一项 —— 那是
`ebasecamp-model-link-configs' 物化的结果，含该配置的 `:service-overrides'。
PROJECT 为 nil（配置指向的项目不存在）或该项目尚未物化时，回退为
`(:group GROUP-NAME :scope SCOPE)'，使只读展示不因缺少物化而 signal。"
  (or (and project
           (cl-find group-name (ebasecamp-project-groups project)
                    :key (lambda (group-ref) (plist-get group-ref :group))
                    :test #'eq))
      (list :group group-name :scope scope)))

(defun ebasecamp-data--instance-indexes ()
  "返回状态索引对 (SHARED . PROJECT)，供组配置实例装配使用。
SHARED 的键为 \"group/service\"，只收 `:scope' 为 \"shared\" 的记录 ——
shared 容器的 `ebasecamp.project' 标签记的是**发起项目**而非本配置的项目
（D8），因此匹配时必须忽略项目；PROJECT 的键为 \"project/group/service\"。
只读 `ebasecamp-status-last-records'，不触发采集。同一键多次出现时后者覆盖
（与 `ebasecamp-data--status-index' 一致）。"
  (let ((shared (make-hash-table :test #'equal))
        (project (make-hash-table :test #'equal)))
    (dolist (record (ebasecamp-status-last-records))
      (let ((project-name (ebasecamp-data--name-string
                           (plist-get record :project)))
            (group-name (ebasecamp-data--name-string
                         (plist-get record :group)))
            (service-name (ebasecamp-data--name-string
                           (plist-get record :service)))
            (scope (ebasecamp-data--name-string (plist-get record :scope))))
        (when (equal scope "shared")
          (puthash (format "%s/%s" group-name service-name) record shared))
        (puthash (format "%s/%s/%s" project-name group-name service-name)
                 record project)))
    (cons shared project)))

(defun ebasecamp-data--instance-status (indexes project-name group-name scope
                                               service-name)
  "按 D8 规则取服务记录的状态记录（可能为 nil，纯函数）。
SCOPE 为 \"shared\" 时只按 GROUP-NAME + SERVICE-NAME 命中并忽略 PROJECT-NAME；
其余按 PROJECT-NAME + GROUP-NAME + SERVICE-NAME 命中。"
  (if (equal scope "shared")
      (gethash (format "%s/%s" group-name service-name) (car indexes))
    (gethash (format "%s/%s/%s" project-name group-name service-name)
             (cdr indexes))))

(defun ebasecamp-data--instance-services (group project group-ref)
  "返回实例的服务对象列表（纯函数）。
PROJECT 已注册时交给 `ebasecamp-model-resolve-services' 合并 GROUP-REF 的
服务覆盖；PROJECT 为 nil（配置指向的项目不存在）时回退到 GROUP 的默认定义
副本，保证只读展示不崩。"
  (if project
      (ebasecamp-model-resolve-services project group-ref)
    (mapcar #'copy-ebasecamp-service (ebasecamp-group-services group))))

(defun ebasecamp-data--instance-records (group project config-plist indexes)
  "装配单份配置实例的服务记录列表（清单 ∪ 状态，纯函数）。
GROUP 为 ebasecamp-group 对象，PROJECT 为配置指向的项目对象（可为 nil，
表示项目未注册），CONFIG-PLIST 为配置 plist，INDEXES 见
`ebasecamp-data--instance-indexes'。记录按服务名升序。"
  (let* ((group-symbol (ebasecamp-group-name group))
         (group-name (ebasecamp-data--name-string group-symbol))
         (group-scope (ebasecamp-group-scope group))
         (scope (ebasecamp-data--name-string group-scope))
         (project-name (ebasecamp-data--name-string
                        (ebasecamp-model-config-project config-plist)))
         (group-ref (ebasecamp-data--config-ref project group-symbol
                                               group-scope))
         (records nil))
    (dolist (service (ebasecamp-data--instance-services group project group-ref))
      (let ((service-name (ebasecamp-data--name-string
                           (ebasecamp-service-name service))))
        (push (ebasecamp-data--service-record
               project-name group-name scope
               (ebasecamp-data--instance-status indexes project-name
                                                group-name scope service-name)
               service)
              records)))
    (sort records #'ebasecamp-data--record-lessp)))

(defun ebasecamp-data-group-instances (group)
  "返回 GROUP 的配置实例列表，每份配置一项（纯函数，无 IO）。
GROUP 可为 ebasecamp-group 对象、symbol 或字符串组名；组不存在或组无配置时
返回 nil。每项形如

  (:config 配置名 :project 项目名 :project-title 项目 title
   :scope scope :records (记录 ...))

其中 `:config' 为配置名（字符串，按定义顺序），`:project' 为配置的
`:project'（字符串），`:project-title' 为项目 title（项目未注册时为 nil），
`:scope' 为组定义的 scope（D9：配置不覆盖 scope），`:records' 与
`ebasecamp-data-project-records' 同构：清单服务 ∪ 状态，字段为
\(:project :group :service :scope :image :desired-ports :state :health :id
 :names :ports)，按服务名升序。

服务取自已物化的组引用（优先用 PROJECT 的 groups 槽里同组那一项的
`:service-overrides'），项目未物化时回退到组默认定义。

状态匹配（D8）：`:scope' 为 \"shared\" 时按 `:group' + `:scope' 匹配并忽略
`:project'（shared 容器标签记的是发起项目，可能不是本配置的项目）；否则
`:project' 与 `:group' 都相等才命中。状态只读
`ebasecamp-status-last-records'，不触发采集；未命中时 `:state' 为
\"stopped\"。"
  (when-let* ((group-object (ebasecamp-data--resolve-group group))
              (configs (ebasecamp-model-group-configs group-object)))
    (let ((indexes (ebasecamp-data--instance-indexes))
          (scope (ebasecamp-data--name-string
                  (ebasecamp-group-scope group-object)))
          (instances nil))
      (dolist (config configs)
        (let* ((config-plist (cdr config))
               (project-symbol (ebasecamp-model-config-project config-plist))
               (project (and project-symbol
                             (ebasecamp-model-project project-symbol))))
          (push (list :config (ebasecamp-data--name-string (car config))
                      :project (ebasecamp-data--name-string project-symbol)
                      :project-title (and project
                                          (ebasecamp-project-title project))
                      :scope scope
                      :records (ebasecamp-data--instance-records
                                group-object project config-plist indexes))
                instances)))
      (nreverse instances))))

(defun ebasecamp-data--all-records ()
  "返回所有项目记录的拼接，项目按名字典序排列。纯函数。"
  (let ((names (sort (delq nil (mapcar
                                (lambda (project)
                                  (ebasecamp-data--name-string
                                   (ebasecamp-project-name project)))
                                (ebasecamp-model-projects)))
                     #'string<))
        (records nil))
    (dolist (name names)
      (setq records (append records (ebasecamp-data-project-records name))))
    records))

;;; 过滤与分页

(defun ebasecamp-data--field-equal (key record value)
  "记录 RECORD 的 KEY 字段是否等于 VALUE。
KEY 为 `:project' / `:group' / `:service' 时按字符串比较（清单侧是 symbol），
其余键用 `equal'。"
  (if (memq key '(:project :group :service))
      (equal (ebasecamp-data--name-string (plist-get record key))
             (ebasecamp-data--name-string value))
    (equal (plist-get record key) value)))

(defun ebasecamp-data--filter (records query)
  "按 QUERY 过滤记录列表 RECORDS，返回子列表（保持原顺序）。
QUERY 为 nil 时不过滤；plist 时按给定键逐条 AND 过滤。"
  (if (null query)
      records
    (cl-remove-if-not
     (lambda (record)
       (cl-loop for (key value) on query by #'cddr
                always (ebasecamp-data--field-equal key record value)))
     records)))

(defun ebasecamp-data--slice (items page page-size)
  "从 ITEMS 中取出 PAGE（1 起）与 PAGE-SIZE 指定的切片。纯函数。"
  (let* ((page (max 1 (or page 1)))
         (page-size (max 1 (or page-size 20)))
         (start (* (1- page) page-size))
         (end (+ start page-size))
         (length (length items)))
    (cl-subseq items (min start length) (min end length))))

(defun ebasecamp-data--query-records (query)
  "按 QUERY 取出候选记录列表（过滤与分页之前）。纯函数。
nil 取全部项目；字符串/symbol 取单个项目；plist 先按 `:project' 取值
（缺省时取全部），再由调用方按其余键过滤。"
  (cond
   ((null query) (ebasecamp-data--all-records))
   ((or (stringp query) (symbolp query))
    (ebasecamp-data-project-records query))
   ((listp query)
    (let ((project (plist-get query :project)))
      (if project
          (ebasecamp-data-project-records project)
        (ebasecamp-data--all-records))))
   (t (ebasecamp-data--all-records))))

(defun ebasecamp-data--load (query page page-size)
  "source 的 `:load' 实现：按 QUERY 取记录后分页。
返回 `(:items RECORDS :total N :page PAGE :page-size PAGE-SIZE)'，
其中 `:total' 是过滤后的总条数（分页前）。"
  (let* ((candidates (ebasecamp-data--query-records query))
         (filtered (if (and (listp query) (not (stringp query)))
                       (ebasecamp-data--filter
                        candidates
                        (cl-loop for (key value) on query by #'cddr
                                 unless (eq key :project)
                                 append (list key value)))
                     candidates)))
    (list :items (ebasecamp-data--slice filtered page page-size)
          :total (length filtered)
          :page (max 1 (or page 1))
          :page-size (max 1 (or page-size 20)))))

;;; source 与 controller

(defun ebasecamp-data-source ()
  "创建服务表的 ETAF Data source。
capabilities：`:load'（见 `ebasecamp-data--load'）、`:item-key'（稳定身份）、
`:provider' 为 `ebasecamp'。`:dispose' 刻意不提供 —— 本 source 不持有任何
全局资源（轮询归 `ebasecamp-status'）。"
  (etaf-data-source
   :name 'ebasecamp-services
   :provider 'ebasecamp
   :item-key #'ebasecamp-data--item-key
   :load #'ebasecamp-data--load))

(defun ebasecamp-data-controller ()
  "创建服务表的 ETAF Data controller（`:auto-load' 为 nil）。
由 UI 持有，加载用 `etaf-data-load'（或 `ebasecamp-data-refresh'），销毁用
`etaf-data-stop'。"
  (etaf-data-controller (ebasecamp-data-source)
                        :auto-load nil
                        :name 'ebasecamp-services))

(defun ebasecamp-data-refresh (controller)
  "用最新快照刷新 CONTROLLER。
先调 `ebasecamp-status-snapshot' 采一次新数据（成功则覆盖 last-records），再
`etaf-data-load' 让 CONTROLLER 重新走 source 的 `:load'。返回同步加载结果
（`(:items … :total …)'），controller 已停止或加载失败时返回 nil。"
  (condition-case err
      (progn
        (ebasecamp-status-snapshot)
        (etaf-data-load controller))
    ((error quit)
     (message "ebasecamp: 刷新状态数据失败：%S" err)
     nil)))

(provide 'ebasecamp-data)
;;; ebasecamp-data.el ends here
