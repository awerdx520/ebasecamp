;;; ebasecamp-data.el --- ebasecamp 清单 ∪ 状态记录的纯装配 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.5.3
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块把「清单」与「容器状态」装配成 UI 可直接消费的记录。它是纯装配
;; 层：不依赖任何 UI 框架，不做加载 / 查询 / 分页 / 轮询，也不持有全局资源。
;; 界面层直接调用 `ebasecamp-data-project-records' 或
;; `ebasecamp-data-group-instances' 取 plist 记录后自行渲染。
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
;; - 记录只读「最近一次成功快照」（`ebasecamp-status-last-records'），不主动
;;   执行 `docker ps'：轮询归 `ebasecamp-status'，本模块不重复采集（避免一次
;;   刷新跑两次 docker ps）；
;; - 除读快照外无 IO，不起定时器、不持 buffer、不缓存。
;;
;; item-key 为 "project/group/service"：容器 ID 在重启后变化，而三元组是
;; 选择状态的稳定身份（也是记录与状态记录的匹配键）。

;;; Code:

(require 'cl-lib)
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

(defun ebasecamp-data--instance-records (group project config-plist indexes
                                               &optional scope-override)
  "装配单份配置实例的服务记录列表（清单 ∪ 状态，纯函数）。
GROUP 为 ebasecamp-group 对象，PROJECT 为配置指向的项目对象（可为 nil，
表示项目未注册），CONFIG-PLIST 为配置 plist，INDEXES 见
`ebasecamp-data--instance-indexes'。SCOPE-OVERRIDE 非 nil 时用它替代组定义的
scope（旧写法实例允许引用级 `:scope' 覆盖，此时状态匹配必须按该 scope）。
记录按服务名升序。"
  (let* ((group-symbol (ebasecamp-group-name group))
         (group-name (ebasecamp-data--name-string group-symbol))
         (group-scope (ebasecamp-group-scope group))
         (scope (or (ebasecamp-data--name-string scope-override)
                    (ebasecamp-data--name-string group-scope)))
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

(defun ebasecamp-data--legacy-project-lessp (a b)
  "项目 A 是否应排在 B 之前（项目名升序）。纯函数。"
  (string< (ebasecamp-data--name-string (ebasecamp-project-name a))
           (ebasecamp-data--name-string (ebasecamp-project-name b))))

(defun ebasecamp-data--legacy-instances (group indexes)
  "为 GROUP 装配「旧写法实例」列表（纯函数，无 IO）。
GROUP 为 ebasecamp-group 对象，INDEXES 见 `ebasecamp-data--instance-indexes'。
按项目名升序扫描 `ebasecamp-model-projects'，把每个项目 groups 槽里 `:group'
等于 GROUP 的那条引用转成一个实例：它有「组无 `:configs'」（v0.1 清单只在
项目侧声明 `:groups'）时才被装配，使旧写法在组视图里仍然可见。

字段与配置实例相同（`:project' / `:project-title' / `:scope' / `:records'），
另加 `:legacy' t，且 `:config' 为 nil（旧写法没有配置名）。`:scope' 取引用的
生效 scope —— 旧写法允许引用级覆盖，记录的状态匹配须按该 scope。"
  (let* ((group-symbol (ebasecamp-group-name group))
         (instances nil))
    (dolist (project (sort (copy-sequence (ebasecamp-model-projects))
                           #'ebasecamp-data--legacy-project-lessp))
      (let ((group-ref (cl-find group-symbol (ebasecamp-project-groups project)
                                :key (lambda (ref) (plist-get ref :group))
                                :test #'eq)))
        (when group-ref
          (let ((project-symbol (ebasecamp-project-name project))
                (scope (ebasecamp-data--group-ref-scope group-ref)))
            (push (list :config nil
                        :project (ebasecamp-data--name-string project-symbol)
                        :project-title (ebasecamp-project-title project)
                        :scope scope
                        :legacy t
                        :records (ebasecamp-data--instance-records
                                  group project (list :project project-symbol)
                                  indexes scope))
                  instances)))))
    (nreverse instances)))

(defun ebasecamp-data-group-instances (group)
  "返回 GROUP 的配置实例列表，每份配置一项（纯函数，无 IO）。
GROUP 可为 ebasecamp-group 对象、symbol 或字符串组名；组不存在时返回 nil。
每项形如

  (:config 配置名 :project 项目名 :project-title 项目 title
   :scope scope :records (记录 ...))

其中 `:config' 为配置名（字符串，按定义顺序），`:project' 为配置的
`:project'（字符串），`:project-title' 为项目 title（项目未注册时为 nil），
`:scope' 为组定义的 scope（D9：配置不覆盖 scope），`:records' 与
`ebasecamp-data-project-records' 同构：清单服务 ∪ 状态，字段为
\(:project :group :service :scope :image :desired-ports :state :health :id
 :names :ports)，按服务名升序。

**旧写法回退**：组没有 `:configs' 时（v0.1 清单只在项目侧写 `:groups'）改为
扫描项目侧的组引用，每个引用一个「旧写法实例」—— 字段同上，另加 `:legacy'
t、`:config' 为 nil、`:scope' 取引用的生效 scope，顺序按项目名升序。组有
`:configs' 时行为完全不变，不混入旧写法实例（同一项目同组的重复引用在加载期
已报 `ebasecamp-config-duplicate-group-ref'）。

服务取自已物化的组引用（优先用 PROJECT 的 groups 槽里同组那一项的
`:service-overrides'），项目未物化时回退到组默认定义。

状态匹配（D8）：`:scope' 为 \"shared\" 时按 `:group' + `:scope' 匹配并忽略
`:project'（shared 容器标签记的是发起项目，可能不是本配置的项目）；否则
`:project' 与 `:group' 都相等才命中。状态只读
`ebasecamp-status-last-records'，不触发采集；未命中时 `:state' 为
\"stopped\"。"
  (when-let* ((group-object (ebasecamp-data--resolve-group group)))
    (let ((indexes (ebasecamp-data--instance-indexes))
          (configs (ebasecamp-model-group-configs group-object)))
      (if (null configs)
          (ebasecamp-data--legacy-instances group-object indexes)
        (let ((scope (ebasecamp-data--name-string
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
          (nreverse instances))))))

(provide 'ebasecamp-data)
;;; ebasecamp-data.el ends here
