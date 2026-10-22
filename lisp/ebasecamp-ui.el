;;; ebasecamp-ui.el --- ebasecamp 只读主界面（etaf / etaf-ui） -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.1.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 主界面（**组为中心的骨架**，C0）：在一个 etaf 缓冲区里展示「组 → 配置」
;; 两级的只读视图。组来自清单（`ebasecamp-model-groups'），因此**不依赖**
;; 项目是否存在；配置来自组的 configs 槽（`ebasecamp-model-group-configs'）。
;;
;; 布局（一个 Host 树）：
;;
;;   根 column
;;   ├─ row（顶栏）: etaf-label "ebasecamp" + 统计 label + etaf-button "刷新"
;;   ├─ etaf-divider
;;   ├─ etaf-splitter（horizontal，ratio 0.32）
;;   │  ├─ slot first  → etaf-tree（组 → 配置 两级）
;;   │  └─ slot second → 右栏（见 `ebasecamp-ui--detail-view'）：
;;   │       未选中组   → 占位「选择左侧的组」
;;   │       选中组无配置 → 空态「尚未关联任何项目」+ 组定义的服务名（只读）
;;   │       选中组有配置 → 组标题行（标题 + scope 徽标 + "N 配置"）
;;   │                     + 每份配置一个 `etaf-panel' 段：
;;   │                         header 槽 = 段头 row（配置 → 项目 + scope 徽标
;;   │                         + running/total 徽标 + 启动/停止/重启按钮）
;;   │                         default 槽 = etaf-divider + 服务表 etaf-table
;;   └─ etaf-divider
;;
;; 无任何组时整棵树替换为 `etaf-empty'（引导用户去
;; `ebasecamp-config-directory' 定义清单）。
;;
;; 状态与生命周期：
;;
;; - 会话对象（`ebasecamp-ui-session'）持有若干 `etaf-ref'：
;;   渲染数据（`state'，见 `ebasecamp-ui--build-state'）、选中的组名
;;   （`selected-group'，symbol 或 nil）、树的展开 key 列表（`expanded'）、
;;   勾选的服务 key 列表（`selected-ref'）、生命周期命令执行中标记（`busy'）、
;;   操作提示（`notice'，值为 nil 或
;;   `(:kind error|warning|success|info :title STR :message STR :detail STR-or-nil)'）、
;;   销毁确认框开关（`confirm'）、待确认动作（`confirm-action'），以及
;;   提示自动清除定时器（`notice-timer'）。会话在 `ebasecamp-ui-open' 中创建，
;;   `ebasecamp-ui-close' 中销毁；
;; - 渲染数据是**单一 plist**：`ebasecamp-ui-refresh' 重新采集状态、重建
;;   state 并写回 ref，视图只需读 ref 就整体重渲染（不需要 render-tick）。
;;   state 里每组带 `:instances'（每份配置一项，由
;;   `ebasecamp-data-group-instances' 装配）与逐级汇总的 `:running' /
;;   `:total' —— 一次 state 构建每组只装配一次实例，避免重复读状态快照；
;; - `etaf-on-mounted' → `ebasecamp-status-start'，回调里调
;;   `ebasecamp-ui-refresh'（传入 `ebasecamp-status-last-records'，避免轮询
;;   一次刷新跑两次 `docker ps'）；
;; - `etaf-on-unmounted' → `ebasecamp-status-stop' + 取消提示定时器；
;; - 树的选择：`:on-select' 把组名写进 `selected-group'，`:on-toggle' 把新的
;;   key 列表写进 `expanded'（展开状态由会话持有，重渲染后保持）；
;; - 服务勾选的 key 形如 "组名/服务名"（`ebasecamp-ui--instance-key'）：
;;   同一组在不同项目实例下若服务同名，选中状态**跨段共享** —— 这是第一期
;;   语义（容器 ID 与项目名不参与 key，重启后选中仍稳定）。`selected-ref'
;;   由 `ebasecamp-ui-selected-keys' 消费：段内按钮经
;;   `ebasecamp-ui--section-action' 按**该段自己的** `:project' 派发到命令层
;;   （C4）；旧的项目视图接口 `ebasecamp-ui-run-action' 仍走
;;   `ebasecamp-ui--run-action'（C5 迁移到「选项目」语义）；底栏留 C5；
;; - 提示的呈现：`ebasecamp-ui--notice-view' 把 notice 渲染成 `etaf-alert'
;;   （`:detail' 以换行拼接进 message，`:dismissible' 的关闭按钮清空 notice）；
;;   成功 / 信息类提示在 `ebasecamp-ui-notice-timeout' 秒后自动清除，定时器
;;   存进会话，`ebasecamp-ui-close' 与写新 notice 时都会先取消它（防泄漏）。
;;   这里不用 `etaf-toast'：其实测要求 `:anchor' 必填（必须是带 `:id' 的
;;   Host），且 batch 下只画出标题、正文不可见，无法覆盖需要展示 stderr 的
;;   场景；
;; - `busy' 为真时操作条与段内按钮全部 `:disabled'，`ebasecamp-ui-run-action'
;;   与 `ebasecamp-ui--section-action' 也直接拒绝（双保险：UI 不渲染可点按钮，
;;   函数层不被误调）。
;;
;; 渲染期读 ref（`etaf-value'）会建立渲染依赖：写 ref 即可让统计文案、树项、
;; 展开状态同步更新。注意 `etaf-button' 的 `:disabled' 只接受布尔值（传 ref
;; 对象会 signal `etaf-renderer-error'），必须在渲染时读取其值。
;;
;; 本模块不拼任何 docker 命令（那是 `ebasecamp-docker' / `ebasecamp-command'
;; 的职责），只消费 `ebasecamp-status'、`ebasecamp-data' 与
;; `ebasecamp-command' 的公开接口。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'ebasecamp-model)
(require 'ebasecamp-config)
(require 'ebasecamp-import)
(require 'ebasecamp-export)
(require 'ebasecamp-status)
(require 'ebasecamp-data)
(require 'ebasecamp-command)

(defcustom ebasecamp-ui-buffer-name "*ebasecamp*"
  "ebasecamp 主界面的缓冲区名。"
  :type 'string
  :group 'ebasecamp)

(defcustom ebasecamp-ui-notice-timeout 3
  "成功 / 信息类提示自动清除的秒数。
错误类提示不自动清除（需要用户阅读 stderr），只能手动关闭。"
  :type 'number
  :group 'ebasecamp)

(defconst ebasecamp-ui--split-ratio 0.32
  "左侧组树的宽度占比（`etaf-splitter' 的 `:ratio'）。")

;;; 会话

(cl-defstruct (ebasecamp-ui-session (:constructor ebasecamp-ui--session-create))
  "一次界面会话的可变状态。
STATE 为整棵树的渲染数据（plist，见 `ebasecamp-ui--build-state'）；
SELECTED-GROUP 为当前选中的组名（symbol 或 nil）；EXPANDED 为 `etaf-tree'
的展开 key 列表；SELECTED-REF / BUSY / NOTICE / CONFIRM 均为 `etaf-ref'；
CONFIRM-ACTION 为等待确认的动作 symbol（无则 nil）；NOTICE-TIMER 为临时的
提示自动清除定时器（无则 nil，必须随会话一起取消）。"
  state selected-group expanded selected-ref busy notice confirm confirm-action
  notice-timer)

(defvar ebasecamp-ui--session nil
  "当前界面会话（`ebasecamp-ui-session' 对象）；未打开时为 nil。")

(defconst ebasecamp-ui--hint
  "勾选服务后可批量启动 / 停止 / 重启；销毁环境只移除本项目的 per-project 容器。"
  "操作条下方的默认提示文案（notice 为空时显示）。")

(defun ebasecamp-ui--ensure-manifest ()
  "模型注册表为空时，按 `ebasecamp-config-directory' 加载一次清单。
加载错误已被 `ebasecamp-config-load' 收集到返回值的 `:errors'，这里只在
异常（读目录失败等）时吞掉错误并记录消息，不影响界面渲染。"
  (when (null (ebasecamp-model-projects))
    (condition-case err
        (ebasecamp-config-load ebasecamp-config-directory)
      ((error quit)
       (message "ebasecamp: 加载清单失败：%S" err))))
  nil)

(defun ebasecamp-ui--default-expanded ()
  "返回默认展开的树 key 列表：清单里的全部组（默认全部展开）。"
  (mapcar (lambda (group)
            (ebasecamp-ui--group-key (symbol-name (ebasecamp-group-name group))))
          (ebasecamp-model-groups)))

(defun ebasecamp-ui--new-session ()
  "创建并返回新的界面会话（state / selected-group / expanded 及各 ref）。"
  (ebasecamp-ui--session-create
   :state (etaf-ref (ebasecamp-ui--build-state) :name 'ebasecamp-ui-state)
   :selected-group (etaf-ref nil :name 'ebasecamp-ui-selected-group)
   :expanded (etaf-ref (ebasecamp-ui--default-expanded)
                       :name 'ebasecamp-ui-expanded)
   :selected-ref (etaf-ref nil :name 'ebasecamp-ui-selected)
   :busy (etaf-ref nil :name 'ebasecamp-ui-busy)
   :notice (etaf-ref nil :name 'ebasecamp-ui-notice)
   :confirm (etaf-ref nil :name 'ebasecamp-ui-confirm)
   :confirm-action nil))

(defun ebasecamp-ui-session ()
  "返回当前会话；不存在时创建。
会话在 `ebasecamp-ui-open' 中建立；直接调用本函数便于测试与
`ebasecamp-ui-refresh' 在 buffer 已被外部 kill 后仍可用。"
  (or ebasecamp-ui--session
      (setq ebasecamp-ui--session (ebasecamp-ui--new-session))))

;;; 渲染数据（state）

(defun ebasecamp-ui--running-count (records)
  "返回 RECORDS 中 `:state' 为 running 的条数（大小写不敏感）。纯函数。"
  (cl-loop for record in records
           count (equal "running"
                        (ebasecamp-ui--normalize-state (plist-get record :state)))))

(defun ebasecamp-ui--instance-state (instance)
  "把 `ebasecamp-data-group-instances' 的实例 INSTANCE 转成 state 的段项 plist。
字段：`:config' 配置名、`:project' 项目名、`:project-title' 项目标题（项目
未定义时为 nil）、`:scope' 组 scope（配置的 scope 恒等于组定义，D9）、
`:running' running 服务条数、`:total' 服务总条数、`:records' 服务记录列表。
纯函数。"
  (let ((records (plist-get instance :records)))
    (list :config (plist-get instance :config)
          :project (plist-get instance :project)
          :project-title (plist-get instance :project-title)
          :scope (plist-get instance :scope)
          :running (ebasecamp-ui--running-count records)
          :total (length records)
          :records records)))

(defun ebasecamp-ui--config-state (instance)
  "把段项 INSTANCE 转成 state 的配置项 plist（树的配置节点消费）。
字段：`:name' 配置名、`:project' 项目名、`:project-title' 项目标题、
`:scope'、`:running'、`:total'。纯函数。"
  (list :name (plist-get instance :config)
        :project (plist-get instance :project)
        :project-title (plist-get instance :project-title)
        :scope (plist-get instance :scope)
        :running (plist-get instance :running)
        :total (plist-get instance :total)))

(defun ebasecamp-ui--group-service-names (group)
  "返回组定义里的服务名列表（只用于无配置组的只读展示）。纯函数。"
  (mapcar (lambda (service)
            (format "%s" (ebasecamp-service-name service)))
          (ebasecamp-group-services group)))

(defun ebasecamp-ui--group-state (group)
  "把组对象 GROUP 转成 state 的组项 plist。
字段：`:name' 组名、`:title' 组标题、`:scope' scope、`:config-count' 配置
份数、`:running' / `:total'（各实例求和）、`:configs' 配置项列表（见
`ebasecamp-ui--config-state'）、`:instances' 段项列表（见
`ebasecamp-ui--instance-state'）、`:service-names' 组定义的服务名。
组配置实例经 `ebasecamp-data-group-instances' 每组建装配**一次**，配置项由
实例派生，避免重复读状态快照。纯函数。"
  (let* ((instances (mapcar #'ebasecamp-ui--instance-state
                            (ebasecamp-data-group-instances group)))
         (configs (mapcar #'ebasecamp-ui--config-state instances)))
    (list :name (symbol-name (ebasecamp-group-name group))
          :title (ebasecamp-group-title group)
          :scope (symbol-name (ebasecamp-group-scope group))
          :config-count (length configs)
          :running (apply #'+ 0 (mapcar (lambda (instance)
                                          (plist-get instance :running))
                                        instances))
          :total (apply #'+ 0 (mapcar (lambda (instance)
                                        (plist-get instance :total))
                                      instances))
          :configs configs
          :instances instances
          :service-names (ebasecamp-ui--group-service-names group))))

(defun ebasecamp-ui--build-state (&optional selected-group)
  "构建整棵树的渲染数据（plist）。纯函数（只读模型注册表与状态快照）。
SELECTED-GROUP 为选中组名（symbol 或 nil），写进 `:selected'（字符串）。
结构：
  (:summary \"3 组 · 5 配置\"
   :groups ((:name \"mysql\" :title \"MySQL\" :scope \"per-project\"
             :config-count 2 :running 3 :total 4
             :configs ((:name \"dev\" :project \"myapp\"
                        :project-title \"示例项目\" :scope \"per-project\"
                        :running 2 :total 2))
             :instances ((:config \"dev\" :project \"myapp\"
                          :project-title \"示例项目\" :scope \"per-project\"
                          :running 2 :total 2 :records (…)))
             :service-names (\"mysql\" \"mysql-ro\"))
            …)
   :selected \"mysql\" :empty-p nil)
组来自 `ebasecamp-model-groups'（**不依赖**项目是否存在）；配置实例来自
`ebasecamp-data-group-instances'；`:running' / `:total' 由实例的 `:records'
逐级汇总（`:state' 为 \"running\" 的条数 / 总条数）。无任何组时 `:empty-p'
为 t，视图显示引导空态。"
  (let* ((groups (mapcar #'ebasecamp-ui--group-state (ebasecamp-model-groups)))
         (configs (apply #'+ 0 (mapcar (lambda (group)
                                         (plist-get group :config-count))
                                       groups))))
    (list :summary (format "%d 组 · %d 配置" (length groups) configs)
          :groups groups
          :selected (and selected-group (symbol-name selected-group))
          :empty-p (null groups))))

;;; 状态与文案映射

(defun ebasecamp-ui--normalize-state (state)
  "把 STATE 归一为小写字符串或 nil（非字符串按 nil 处理）。纯函数。"
  (and (stringp state) (downcase state)))

(defun ebasecamp-ui--state-label (state)
  "把容器状态 STATE 映射为表格文案。
running → RUNNING；exited / stopped / nil → STOPPED；created → CREATED；
paused → PAUSED；其余原样大写。纯函数。"
  (let ((value (ebasecamp-ui--normalize-state state)))
    (pcase value
      ((or 'nil "") "STOPPED")
      ("running" "RUNNING")
      ((or "exited" "stopped") "STOPPED")
      ("created" "CREATED")
      ("paused" "PAUSED")
      (_ (upcase value)))))

(defun ebasecamp-ui--state-variant (state)
  "把容器状态 STATE 映射为 `etaf-badge' 的语义 variant。纯函数。"
  (pcase (ebasecamp-ui--normalize-state state)
    ("running" 'success)
    ("paused" 'warning)
    ("created" 'info)
    (_ 'neutral)))

(defun ebasecamp-ui--health-label (health)
  "把健康状态 HEALTH 映射为表格文案。
nil → \"-\"；healthy → OK；unhealthy → BAD；starting → STARTING；其余大写。
纯函数。"
  (let ((value (ebasecamp-ui--normalize-state health)))
    (pcase value
      ((or 'nil "") "-")
      ("healthy" "OK")
      ("unhealthy" "BAD")
      ("starting" "STARTING")
      (_ (upcase value)))))

(defun ebasecamp-ui--health-variant (health)
  "把健康状态 HEALTH 映射为 `etaf-label' 的语义 variant。纯函数。"
  (pcase (ebasecamp-ui--normalize-state health)
    ("healthy" 'success)
    ("unhealthy" 'danger)
    ("starting" 'warning)
    (_ 'muted)))

(defun ebasecamp-ui--ports-label (record)
  "返回 RECORD 的端口文案：优先 desired-ports，其次实际 ports，都无则 \"-\"。
纯函数。"
  (let ((value (or (plist-get record :desired-ports)
                   (plist-get record :ports))))
    (if (and (stringp value) (not (equal value "")))
        value
      "-")))

;;; 选中状态

(defun ebasecamp-ui--selected-p (session key)
  "KEY 是否在 SESSION 的选中列表里。"
  (and (member key (etaf-value (ebasecamp-ui-session-selected-ref session))) t))

(defun ebasecamp-ui--toggle-selected (session key next)
  "把 KEY 的选中状态设为 NEXT（布尔），返回更新后的选中列表。"
  (let* ((ref (ebasecamp-ui-session-selected-ref session))
         (keys (etaf-value ref))
         (updated (if next
                      (if (member key keys) keys (cons key keys))
                    (delete key (copy-sequence keys)))))
    (etaf-set-value ref updated)))

(defun ebasecamp-ui--instance-key (group-name record)
  "返回记录 RECORD 在段内的选中 key，形如 \"组名/服务名\"。
GROUP-NAME 可为 symbol 或字符串，RECORD 为服务记录 plist（见
`ebasecamp-data-group-instances'）。

已定的选择模型（C4 直接消费）：
- `selected-ref' 存字符串列表，元素形如 \"组名/服务名\"；
- 容器 ID 与项目名**不参与** key，因此容器重启后选中状态仍然稳定；
- 同一组在不同项目实例下若服务同名，key 相同 → 选中状态**跨段共享**。
  这是可接受的第一期语义（段内按钮的派发留 C4，届时按段隔离选中集合）；
  需要按实例区分时应把配置名并入 key，但那要等容器标签新增配置维度。

纯函数。"
  (format "%s/%s" group-name (plist-get record :service)))

(defun ebasecamp-ui-selected-keys ()
  "返回当前勾选的服务 key 列表（形如 \"组名/服务名\"）。
会话未建立时返回 nil；批量操作按钮消费本函数。"
  (let ((session ebasecamp-ui--session))
    (and session
         (copy-sequence
          (etaf-value (ebasecamp-ui-session-selected-ref session))))))

;;; 操作提示（notice）

(defconst ebasecamp-ui--blocking-conflict-kinds '(duplicate busy)
  "会阻塞启动的端口冲突类型。
`unknown'（探测不可用）不阻塞，只作为提示写进 notice。")

(defconst ebasecamp-ui--transient-notice-kinds '(success info)
  "会自动清除的 notice 类型；错误类需要用户阅读细节，只能手动关闭。")

(defun ebasecamp-ui--cancel-notice-timer (session)
  "取消 SESSION 的提示自动清除定时器（无定时器时不动），返回 nil。"
  (when session
    (when-let* ((timer (ebasecamp-ui-session-notice-timer session)))
      (cancel-timer timer)
      (setf (ebasecamp-ui-session-notice-timer session) nil)))
  nil)

(defun ebasecamp-ui--clear-notice (session)
  "清空 SESSION 的 notice 及其自动清除定时器，返回 nil。
Dismissible alert 的 `:on-dismiss' 与定时器回调都走本函数。"
  (when session
    (ebasecamp-ui--cancel-notice-timer session)
    (etaf-set-value (ebasecamp-ui-session-notice session) nil))
  nil)

(defun ebasecamp-ui--schedule-notice-clear (session notice)
  "为瞬时类 NOTICE 安排自动清除定时器，返回定时器；不需要时返回 nil。
定时器存进 SESSION，`ebasecamp-ui-close' 与写新 notice 前都会取消它。
回调只在 SESSION 仍是当前会话时清除，避免关闭后操作已销毁的会话。"
  (when (and session
             (memq (plist-get notice :kind) ebasecamp-ui--transient-notice-kinds))
    (let ((timer (run-with-timer
                  ebasecamp-ui-notice-timeout nil
                  (lambda ()
                    (when (eq session ebasecamp-ui--session)
                      (ebasecamp-ui--clear-notice session))))))
      (setf (ebasecamp-ui-session-notice-timer session) timer)
      timer)))

(defun ebasecamp-ui--set-notice (session kind title message &optional detail)
  "把 SESSION 的 notice 写成 KIND + TITLE + MESSAGE + DETAIL，返回 nil。
KIND 为 error / warning / success / info；成功与信息类通知会在
`ebasecamp-ui-notice-timeout' 秒后自动清除（定时器存进会话）。"
  (when session
    (ebasecamp-ui--cancel-notice-timer session)
    (let ((notice (list :kind kind :title title :message message :detail detail)))
      (etaf-set-value (ebasecamp-ui-session-notice session) notice)
      (ebasecamp-ui--schedule-notice-clear session notice)))
  nil)

(defun ebasecamp-ui--notice (session)
  "返回 SESSION 的 notice 值（nil 或 plist），读 ref 以建立渲染依赖。"
  (and session (etaf-value (ebasecamp-ui-session-notice session))))

(defun ebasecamp-ui--notice-body (notice)
  "返回 NOTICE 的正文：MESSAGE，DETAIL 非空时以换行追加。纯函数。"
  (let ((message (or (plist-get notice :message) ""))
        (detail (plist-get notice :detail)))
    (if (and (stringp detail) (not (string-empty-p detail)))
        (format "%s\n%s" message detail)
      message)))

(defun ebasecamp-ui--kind-variant (kind)
  "把 notice 的 KIND 映射为 `etaf-alert' 的 `:variant'（error → danger）。纯函数。"
  (pcase kind
    ('error 'danger)
    ('warning 'warning)
    ('success 'success)
    (_ 'info)))

(defun ebasecamp-ui--notice-view (session)
  "返回操作条下方的提示视图。
无 notice 时给默认的操作提示 label；有 notice 时渲染 `etaf-alert'
（`:dismissible' 的关闭按钮清空 notice，`:detail' 以换行拼进 message）。"
  (let ((notice (ebasecamp-ui--notice session)))
    (if (null notice)
        (etaf-view (etaf-label :text ebasecamp-ui--hint :variant 'muted))
      (etaf-view
       (etaf-alert
        :title (or (plist-get notice :title) "")
        :message (ebasecamp-ui--notice-body notice)
        :variant (ebasecamp-ui--kind-variant (plist-get notice :kind))
        :dismissible t
        :on-dismiss (lambda () (ebasecamp-ui--clear-notice session)))))))

;;; 动作名与端口冲突汇总

(defun ebasecamp-ui--action-label (action)
  "返回动作 ACTION 的中文短名（用于 notice 文案）。纯函数。"
  (pcase action
    ('start "启动")
    ('stop "停止")
    ('restart "重启")
    ('down "销毁")
    (_ (format "%s" action))))

(defun ebasecamp-ui--conflict-summary (conflicts)
  "把冲突列表 CONFLICTS 汇总为一行中文文案。纯函数。"
  (mapconcat
   (lambda (conflict)
     (let ((kind (plist-get conflict :kind))
           (port (plist-get conflict :port)))
       (pcase kind
         ('duplicate
          (format "端口 %s 在 %s 之间重复" port
                  (mapconcat #'identity
                             (plist-get conflict :services) "、")))
         ('busy
          (format "端口 %s 已被占用（%s）" port (plist-get conflict :service)))
         (_
          (format "端口 %s 探测不可用，已跳过（%s）"
                  port (plist-get conflict :service))))))
   conflicts "；"))

(defun ebasecamp-ui--split-conflicts (conflicts)
  "把冲突列表 CONFLICTS 拆成 (BLOCKING . SOFT) 两簇。
BLOCKING 是 `ebasecamp-ui--blocking-conflict-kinds' 中的类型（必须拒绝启动），
SOFT 是其余（如 `unknown'，只提示）。纯函数。"
  (let ((blocking nil)
        (soft nil))
    (dolist (conflict conflicts)
      (if (memq (plist-get conflict :kind) ebasecamp-ui--blocking-conflict-kinds)
          (setq blocking (append blocking (list conflict)))
        (setq soft (append soft (list conflict)))))
    (cons blocking soft)))

;;; 选中 key → 命令层 key

(defun ebasecamp-ui--command-key (key)
  "把界面选中 KEY 归一为命令层的 \"group/service\"。
段内 key 已是该形态（两段），原样返回；三段形态（旧的
\"project/group/service\"）剥离项目前缀；其他形态也原样返回。纯函数。"
  (let ((parts (and (stringp key) (split-string key "/"))))
    (if (and parts (= 3 (length parts)) (nth 1 parts) (nth 2 parts))
        (format "%s/%s" (nth 1 parts) (nth 2 parts))
      key)))

(defun ebasecamp-ui--command-keys (keys)
  "把界面选中 key 列表 KEYS 转成命令层 key 列表（逐项 `ebasecamp-ui--command-key'）。
纯函数。"
  (mapcar #'ebasecamp-ui--command-key keys))

;;; 树项 / 列

(defun ebasecamp-ui--ratio-label (running total)
  "返回 \"运行/总数\" 文案（如 \"2/2\"）。纯函数。"
  (format "%d/%d" running total))

(defun ebasecamp-ui--group-label (group)
  "返回组项的标题文案（标题缺失时回退组名）。纯函数。"
  (or (plist-get group :title) (plist-get group :name)))

(defun ebasecamp-ui--group-caption (group)
  "返回组项的显示文案：标题 + 配置份数 + running 汇总。
无服务时省略 running 部分（如 \"redis  (0 配置)\"），否则如
\"MySQL  (2 配置 · 3/4 running)\"。GROUP 为 state 的组项 plist。纯函数。"
  (let ((total (or (plist-get group :total) 0))
        (head (format "%s  (%d 配置"
                      (ebasecamp-ui--group-label group)
                      (plist-get group :config-count))))
    (if (> total 0)
        (format "%s · %s running)"
                head
                (ebasecamp-ui--ratio-label
                 (or (plist-get group :running) 0) total))
      (concat head ")"))))

(defun ebasecamp-ui--config-caption (config)
  "返回配置项的显示文案：配置名 → 项目 + running 计数。
如 \"dev → 示例项目  (2/2)\"；项目标题缺失时回退项目名，无服务时省略计数。
CONFIG 为 state 的配置项 plist。纯函数。"
  (let* ((target (or (plist-get config :project-title)
                     (plist-get config :project)
                     ""))
         (total (or (plist-get config :total) 0)))
    (if (> total 0)
        (format "%s → %s  (%s)"
                (plist-get config :name) target
                (ebasecamp-ui--ratio-label
                 (or (plist-get config :running) 0) total))
      (format "%s → %s" (plist-get config :name) target))))

(defun ebasecamp-ui--group-key (group-name)
  "返回组节点的树 key（字符串 \"group/组名\"）。
`etaf-tree' 要求全局唯一的**标量** key，因此组与配置用不同前缀区分。纯函数。"
  (format "group/%s" group-name))

(defun ebasecamp-ui--config-key (group-name config-name)
  "返回配置节点的树 key（字符串 \"config/组名/配置名\"）。纯函数。"
  (format "config/%s/%s" group-name config-name))

(defun ebasecamp-ui--tree-key-group (key)
  "把树 key KEY（\"group/GROUP\" 或 \"config/GROUP/CONFIG\"）归一为组名 symbol。
无法判定时返回 nil。纯函数。"
  (when (and (stringp key) (string-match-p "/" key))
    (let ((name (nth 1 (split-string key "/"))))
      (and name (not (string-empty-p name)) (intern name)))))

(defun ebasecamp-ui--tree-items (state)
  "把渲染数据 STATE 转成 `etaf-tree' 的 `:items'（组 → 配置 两级）。
组项带 `:children'（该组的全部配置），配置是叶子。组名全来自清单，因此
没有项目时也能列出。纯函数。"
  (mapcar
   (lambda (group)
     (let ((group-name (plist-get group :name)))
       (list :key (ebasecamp-ui--group-key group-name)
             :label (ebasecamp-ui--group-caption group)
             :children
             (mapcar (lambda (config)
                       (list :key (ebasecamp-ui--config-key
                                   group-name
                                   (plist-get config :name))
                             :label (ebasecamp-ui--config-caption config)))
                     (plist-get group :configs)))))
   (plist-get state :groups)))

(defun ebasecamp-ui--select-cell (session group-name record)
  "选中列的单元格：checkbox 写回 SESSION 的选中列表。
key 为段内身份 \"组名/服务名\"（见 `ebasecamp-ui--instance-key'）。"
  (let ((key (ebasecamp-ui--instance-key group-name record)))
    (etaf-view
     (etaf-checkbox
      :checked (ebasecamp-ui--selected-p session key)
      :on-change (lambda (next)
                   (ebasecamp-ui--toggle-selected session key next))))))

(defun ebasecamp-ui--state-cell (record)
  "状态列的单元格：semantic badge 呈现状态文案。"
  (let ((state (plist-get record :state)))
    (etaf-view
     (etaf-badge :text (ebasecamp-ui--state-label state)
                 :variant (ebasecamp-ui--state-variant state)))))

(defun ebasecamp-ui--ports-cell (record)
  "端口列的单元格：期望端口优先，其次实际端口。"
  (etaf-view (etaf-label :text (ebasecamp-ui--ports-label record))))

(defun ebasecamp-ui--health-cell (record)
  "健康列的单元格：语义 label 呈现健康文案。"
  (let ((health (plist-get record :health)))
    (etaf-view
     (etaf-label :text (ebasecamp-ui--health-label health)
                 :variant (ebasecamp-ui--health-variant health)))))

(defun ebasecamp-ui--columns (session group-name)
  "返回服务表的列定义（第一列为选中 checkbox）。
GROUP-NAME 为组名（段内 key 的组部分）。列 `:key' 用关键字，与记录 plist
的键一致，无 `:cell' 的列可直接取值。
镜像与端口用 `(fr 2)' 抢占剩余宽度（80 列终端下右栏只有约 48 列，定宽相加会
把「健康」列挤出可视区），其余列用字符宽度容量。"
  (list (list :key :select :label "" :width 3
              :cell (lambda (record)
                      (ebasecamp-ui--select-cell session group-name record)))
        (list :key :service :label "服务" :width 9)
        (list :key :image :label "镜像" :width '(fr 2))
        (list :key :state :label "状态" :width 8
              :cell #'ebasecamp-ui--state-cell)
        (list :key :ports :label "端口" :width '(fr 2)
              :cell #'ebasecamp-ui--ports-cell)
        (list :key :health :label "健康" :width 5
              :cell #'ebasecamp-ui--health-cell)))

;;; 动作派发与并发控制

(defun ebasecamp-ui--failed-branch (results)
  "从批次结果 RESULTS 里返回第一个失败分支，无则返回 nil。
失败判定：`:failed' 为真，或 `:exit' 为数字且非 0。纯函数。"
  (cl-find-if (lambda (entry)
                (let ((exit (plist-get entry :exit)))
                  (or (plist-get entry :failed)
                      (and (numberp exit) (/= exit 0)))))
              results))

(defun ebasecamp-ui--first-line (text)
  "返回 TEXT 的第一个非空行（去掉首尾空白）；无内容时返回 nil。纯函数。"
  (when (stringp text)
    (cl-find-if (lambda (line) (not (string-empty-p line)))
                (mapcar #'string-trim (split-string text "\n")))))

(defun ebasecamp-ui--report-result (session label result)
  "把批次结果 RESULT 写成 SESSION 的 notice，LABEL 为动作中文名。返回 nil。
成功 → 绿色完成提示（`:auto-started-shared' 为真时额外说明）；
失败 → 从 `:results' 取失败分支的 stderr：含 permission denied 时给 docker
组提示，否则把 stderr 首行作为 message、原文作为 detail；无 stderr（例如
批次被跳过）时说明「未完成」。"
  (if (plist-get result :ok)
      (ebasecamp-ui--set-notice
       session 'success (format "%s完成" label)
       (if (plist-get result :auto-started-shared)
           "所有批次已执行完成；已自动启动 shared 服务"
         "所有批次已执行完成"))
    (let* ((failed (ebasecamp-ui--failed-branch (plist-get result :results)))
           (stderr (or (and failed (plist-get failed :stderr)) ""))
           (first (ebasecamp-ui--first-line stderr)))
      (cond
       ((string-match-p "permission denied" (downcase stderr))
        (ebasecamp-ui--set-notice
         session 'error "无权访问 Docker"
         "请将当前用户加入 docker 组并重新登录，或检查 /var/run/docker.sock 权限"
         stderr))
       (first
        (ebasecamp-ui--set-notice session 'error (format "%s失败" label)
                                  first stderr))
       (t
        (ebasecamp-ui--set-notice
         session 'error (format "%s未完成" label)
         "部分批次被跳过（没有可展示的错误输出），请查看命令行输出")))))
  nil)

(defun ebasecamp-ui--on-complete (session action)
  "构造 `ebasecamp-command-run' 的完成回调。
回调里清 SESSION 的 busy、刷新数据，并按 RESULT 的 `:ok' / `:results' /
`:auto-started-shared' 写成功或失败的 notice（失败时带 stderr 原文 detail）。"
  (let ((label (ebasecamp-ui--action-label action)))
    (lambda (result)
      (etaf-set-value (ebasecamp-ui-session-busy session) nil)
      (ebasecamp-ui-refresh)
      (ebasecamp-ui--report-result session label result)
      nil)))

(defun ebasecamp-ui--dispatch (session action project keys)
  "把生命周期动作 ACTION（PROJECT + KEYS）派发到命令层，返回 t 或 nil。
**唯一的派发路径**：段内生命周期按钮（`ebasecamp-ui--section-action'）与销毁
确认（`ebasecamp-ui-confirm'）都走本函数，C5 起不再有第二条派发路径。
派发前置 busy；命令层 signal 时按类型映射 notice 并复位 busy（绝不让界面卡在
「执行中」）：
- `ebasecamp-command-busy'（同项目已有命令在执行）→ info「操作进行中」；
- 其他 error（含 `ebasecamp-command-error'）→ error「命令派发失败」+ 消息。
返回 t 表示已派发，nil 表示被拒。"
  (etaf-set-value (ebasecamp-ui-session-busy session) t)
  (condition-case err
      (progn
        (ebasecamp-command-run
         action project keys
         :on-complete (ebasecamp-ui--on-complete session action))
        t)
    (ebasecamp-command-busy
     (etaf-set-value (ebasecamp-ui-session-busy session) nil)
     (ebasecamp-ui--set-notice session 'info "操作进行中" "请等待当前命令完成")
     nil)
    ((error quit)
     (etaf-set-value (ebasecamp-ui-session-busy session) nil)
     (ebasecamp-ui--set-notice session 'error "命令派发失败"
                               (error-message-string err))
     nil)))

(defun ebasecamp-ui-confirm ()
  "执行确认框里待确认的动作，返回 t（已派发）或 nil。
待确认动作（会话的 `confirm-action'）形如 `(down . 项目名)'，由
`ebasecamp-ui-destroy-environment' 设置；确认后先清空确认状态（避免重复
派发），再按「全部服务」（keys 为 nil）经 `ebasecamp-ui--dispatch' 派发。
交互入口：确认框的「确认销毁」按钮与 `M-x'。"
  (interactive)
  (let* ((session ebasecamp-ui--session)
         (pending (and session (ebasecamp-ui-session-confirm-action session))))
    (when session
      (etaf-set-value (ebasecamp-ui-session-confirm session) nil)
      (setf (ebasecamp-ui-session-confirm-action session) nil))
    (if (and session pending)
        (ebasecamp-ui--dispatch session (car pending) (cdr pending) nil)
      nil)))

(defun ebasecamp-ui-dismiss-confirm ()
  "关闭确认框并丢弃待确认动作，返回 nil。"
  (interactive)
  (let ((session ebasecamp-ui--session))
    (when session
      (etaf-set-value (ebasecamp-ui-session-confirm session) nil)
      (setf (ebasecamp-ui-session-confirm-action session) nil)))
  nil)

;;; 底栏与销毁确认视图（C5）

;; 底栏是主视图 column 的最后一个内容行（分割线之后、notice 之前）：导入
;; compose / 导出 compose / 销毁环境三个 ghost 按钮。三者都不是生命周期动作，
;; 故**不参与** busy 判定（busy 期间仍可点）；销毁的危险性由二次确认
;; （`ebasecamp-ui-confirm-dialog'）承担。

(defun ebasecamp-ui--footer-button (label function)
  "返回底栏按钮：文案 LABEL，按下调用 FUNCTION。纯视图，不参与 busy 判定。"
  (etaf-view
   (etaf-button
    :label label
    :variant 'ghost
    :on-press (lambda () (funcall function)))))

(defun ebasecamp-ui--footer-view ()
  "返回主界面底栏：导入 compose / 导出 compose / 销毁环境。"
  (etaf-view
   (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
     (expr (ebasecamp-ui--footer-button
            "导入 compose" #'ebasecamp-ui-import-compose))
     (expr (ebasecamp-ui--footer-button
            "导出 compose" #'ebasecamp-ui-export-compose))
     (expr (ebasecamp-ui--footer-button
            "销毁环境" #'ebasecamp-ui-destroy-environment)))))

(defun ebasecamp-ui--confirm-message (project)
  "返回销毁 PROJECT 的确认文案：点名项目、不删卷、shared 组不受影响。纯函数。"
  (format (concat "将停止并移除项目 %s 的全部 per-project 容器，"
                  "不会删除卷。shared 组不受影响。")
          (or project "（未选择）")))

(etaf-define-component ebasecamp-ui-confirm-dialog ()
  "销毁环境的二次确认框：会话 `confirm' ref 为真时弹出。
`:render' 里读 `confirm' ref，因此打开 / 关闭都会让本组件重建——文案得以在
打开的那一刻按 `confirm-action' 的 `(动作 . 项目名)' 求值（若写成普通视图
函数，文案会在父组件上一次渲染时就固定下来）。"
  :render
  (let* ((session (ebasecamp-ui-session))
         (open (etaf-value (ebasecamp-ui-session-confirm session)))
         (pending (and open (ebasecamp-ui-session-confirm-action session))))
    (when pending
      (etaf-view
       (etaf-dialog
        :open (ebasecamp-ui-session-confirm session)
        :title "销毁环境"
        :width '(ch 56)
        :close-label nil
        :on-close (lambda () (ebasecamp-ui-dismiss-confirm))
        (column :width 'stretch :item-gap '(lh 1)
          (etaf-label :text (ebasecamp-ui--confirm-message (cdr pending)))
          (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
            (etaf-button :label "取消" :variant 'secondary
                         :on-press (lambda () (ebasecamp-ui-dismiss-confirm)))
            (etaf-button :label "确认销毁" :variant 'primary
                         :on-press (lambda () (ebasecamp-ui-confirm))))))))))

;;; 交互与视图（组为中心的骨架）

(defun ebasecamp-ui--select-key (session key)
  "把树节点的选择写进 SESSION：KEY 归一为所属组名，同时重建 state。
配置节点的 key 是 \"config/组名/配置名\"，选中配置等同于选中它所属的组；
服务勾选由段内服务表的 checkbox 维护（key 见 `ebasecamp-ui--instance-key'）。"
  (let ((group (ebasecamp-ui--tree-key-group key)))
    (etaf-set-value (ebasecamp-ui-session-selected-group session) group)
    (etaf-set-value (ebasecamp-ui-session-state session)
                    (ebasecamp-ui--build-state group))))

(defun ebasecamp-ui--tree-view (session)
  "返回左侧组树（组 → 配置 两级）。
`:items' 取自会话的 state（渲染期读取，state 改写即重建树）；
`:expanded' 绑会话的 expanded ref，`:on-toggle' 把新的 key 列表写回同一
ref（展开状态由会话持有，重渲染后保持）；`:on-select' 写 selected-group。"
  (etaf-view
   (etaf-tree
    :items (ebasecamp-ui--tree-items
            (etaf-value (ebasecamp-ui-session-state session)))
    :expanded (ebasecamp-ui-session-expanded session)
    :on-toggle (lambda (next)
                 (etaf-set-value (ebasecamp-ui-session-expanded session) next))
    :on-select (lambda (key) (ebasecamp-ui--select-key session key)))))

;;; 右栏段渲染（C3）与段内派发（C4）

;; 右栏是「选中组 → 每份配置一个 `etaf-panel' 段」的视图。段头含
;; 配置名 → 项目、scope 徽标、running/total 徽标与三个生命周期按钮；
;; 段体是服务表（首列 checkbox，选中状态写进会话的 selected-ref）。
;; 段内按钮的派发（C4）走 `ebasecamp-ui--section-action'：把该段**自己的**
;; `:project' 与当前选中集合交给命令层，不再经过 `ebasecamp-ui-current-project'
;; 兼容层，因此同组多个实例不会串段。`:disabled' 仍由渲染期的 busy 求值。

(defun ebasecamp-ui--busy-p (session)
  "SESSION 的 busy ref 当前是否为真（渲染期读取以建立渲染依赖）。"
  (and (etaf-value (ebasecamp-ui-session-busy session)) t))

(defun ebasecamp-ui--scope-badge (scope)
  "返回 scope 徽标：per-project → info，shared → warning，其余 neutral。
SCOPE 为 scope 字符串（如 \"per-project\"）。"
  (etaf-view
   (etaf-badge :text (or scope "")
               :variant (pcase scope
                          ("per-project" 'info)
                          ("shared" 'warning)
                          (_ 'neutral)))))

(defun ebasecamp-ui--ratio-variant (running total)
  "返回 running/total 徽标的语义 variant。纯函数。
无服务（TOTAL 为 0）或全部未运行（RUNNING 为 0）→ neutral；
全部运行 → success；其余 → warning。"
  (let ((running (or running 0))
        (total (or total 0)))
    (cond ((zerop total) 'neutral)
          ((zerop running) 'neutral)
          ((= running total) 'success)
          (t 'warning))))

(defun ebasecamp-ui--instance-caption (instance)
  "返回段头文案：配置名 → 项目标题（如 \"dev → 示例项目\"）。
项目标题缺失时回退项目名。INSTANCE 为 state 的段项 plist。纯函数。"
  (format "%s → %s"
          (or (plist-get instance :config) "")
          (or (plist-get instance :project-title)
              (plist-get instance :project)
              "")))

(defun ebasecamp-ui--section-action (action instance)
  "对配置实例 INSTANCE 派发生命周期 ACTION。
实例含 :config / :project / :records；keys 取会话选中集合（段内唯一：右栏只显示
当前选中组的实例，故 \"组名/服务名\" 形式的 key 对该段全部有效）。
判定顺序（任一命中即返回 nil 并写 notice，不派发）：
1. 会话 busy → info「操作进行中」；
2. 实例的 `:project' 为空 → info「该项目未定义」；
3. 选中集合为空 → info「未选中服务」；
4. ACTION 为 start 时先做端口冲突检测：`duplicate' / `busy' 阻塞（error
   「端口冲突」），`unknown' 只提示（info「端口提示」）后继续；
5. 派发 `ebasecamp-command-run'：前置 busy=t，命令层 signal 时复位 busy 并写
   error「命令派发失败」。成功返回 t。
完成回调沿用 `ebasecamp-ui--on-complete'（复位 busy → 刷新 → 报告结果）。"
  (let* ((session (ebasecamp-ui-session))
         (project (plist-get instance :project))
         (keys (ebasecamp-ui-selected-keys)))
    (cond
     ((ebasecamp-ui--busy-p session)
      (ebasecamp-ui--set-notice session 'info "操作进行中" "请等待当前命令完成")
      nil)
     ((or (null project) (and (stringp project) (string-empty-p project)))
      (ebasecamp-ui--set-notice session 'info "该项目未定义"
                                "这段配置指向的项目不在清单里，请先定义该项目")
      nil)
     ((null keys)
      (ebasecamp-ui--set-notice session 'info "未选中服务"
                                "请先勾选要操作的服务")
      nil)
     ((not (eq action 'start))
      (ebasecamp-ui--dispatch session action project keys))
     (t
      (let* ((conflicts (ebasecamp-command-port-conflicts project keys))
             (split (ebasecamp-ui--split-conflicts conflicts))
             (blocking (car split))
             (soft (cdr split)))
        (if blocking
            (progn
              (ebasecamp-ui--set-notice
               session 'error "端口冲突"
               (ebasecamp-ui--conflict-summary blocking))
              nil)
          (when soft
            (ebasecamp-ui--set-notice
             session 'info "端口提示"
             (ebasecamp-ui--conflict-summary soft)))
          (ebasecamp-ui--dispatch session action project keys)))))))

(defun ebasecamp-ui--section-button (label action variant instance disabled)
  "返回段内生命周期按钮：文案 LABEL、语义 VARIANT，按下对 INSTANCE 派发 ACTION。
INSTANCE 为 state 的段项 plist（`:config' / `:project' / `:records'）—— 按钮
只绑定该段自己的项目，不读 `ebasecamp-ui-current-project' 兼容层。
DISABLED 为真时禁用 —— `etaf-button' 的 `:disabled' 只接受布尔值，调用方
必须在渲染期从 busy ref 取当前值传入（不能传 ref 对象）。"
  (etaf-view
   (etaf-button
    :label label
    :variant variant
    :disabled (and disabled t)
    :on-press (lambda () (ebasecamp-ui--section-action action instance)))))

(defun ebasecamp-ui--instance-header (instance disabled)
  "返回段头：第一行 = 配置 → 项目（strong）+ scope 徽标 + running/total 徽标，
第二行 = 启动 / 停止 / 重启按钮（DISABLED 为真时三个按钮全部禁用）。
两行而不是一行：80 列终端下段头单行会超出右栏宽度，尾部按钮被裁切。"
  (let ((running (or (plist-get instance :running) 0))
        (total (or (plist-get instance :total) 0)))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
       (row :width 'stretch :cross-align 'center :item-gap '(ch 1)
         (etaf-label :text (ebasecamp-ui--instance-caption instance)
                     :variant 'strong)
         (expr (ebasecamp-ui--scope-badge (plist-get instance :scope)))
         (etaf-badge :text (ebasecamp-ui--ratio-label running total)
                     :variant (ebasecamp-ui--ratio-variant running total)))
       (row :width 'stretch :cross-align 'center :item-gap '(ch 1)
         (expr (ebasecamp-ui--section-button
                "启动选中" 'start 'primary instance disabled))
         (expr (ebasecamp-ui--section-button
                "停止选中" 'stop 'secondary instance disabled))
         (expr (ebasecamp-ui--section-button
                "重启选中" 'restart 'secondary instance disabled)))))))

(defun ebasecamp-ui--service-table (session group-name instance)
  "返回段的服务表：列见 `ebasecamp-ui--columns'，行为实例的 `:records'。
`:row-key' 用段内身份 \"组名/服务名\"，段内唯一。"
  (etaf-view
   (etaf-table
    :columns (ebasecamp-ui--columns session group-name)
    :rows (plist-get instance :records)
    :row-key (lambda (record)
               (ebasecamp-ui--instance-key group-name record)))))

(defun ebasecamp-ui--instance-section (session group-name instance)
  "返回一份配置的段：`etaf-panel'（bordered）。
header 槽为段头行（见 `ebasecamp-ui--instance-header'，busy 在渲染期取值）；
default 槽为分隔线 + 服务表（见 `ebasecamp-ui--service-table'）。"
  (etaf-view
   (etaf-panel :variant 'bordered :width 'stretch
     (slot :name 'header
       (expr (ebasecamp-ui--instance-header
              instance (ebasecamp-ui--busy-p session))))
     (etaf-divider)
     (expr (ebasecamp-ui--service-table session group-name instance)))))

(defun ebasecamp-ui--group-header-row (group)
  "返回右栏顶部的组标题行：组标题 + scope 徽标 + \"N 配置\"。
GROUP 为 state 的组项 plist。"
  (etaf-view
   (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
     (etaf-label :text (ebasecamp-ui--group-label group) :variant 'strong)
     (expr (ebasecamp-ui--scope-badge (plist-get group :scope)))
     (etaf-label :text (format "%d 配置" (plist-get group :config-count))
                 :variant 'muted))))

(defun ebasecamp-ui--empty-configs-view (group)
  "返回「组无配置」的右栏：空态 + 组定义的服务名（只读提示）。
GROUP 为 state 的组项 plist；服务名取自 `:service-names'（组定义，未经配置
覆盖），列出以便确认该组确实有服务但尚未关联项目。"
  (let ((names (plist-get group :service-names)))
    (etaf-view
     (column :width 'stretch :height 'stretch :cross-align 'start
             :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
       (etaf-empty
        :title "尚未关联任何项目"
        :description "在 groups.el 里给该组加 :configs 后即可在此启停服务。")
       (etaf-label
        :text (if names
                  (format "组内服务（只读）：%s" (mapconcat #'identity names "、"))
                "组内尚未定义服务")
        :variant 'muted)))))

(defun ebasecamp-ui--detail-view (session state)
  "返回右栏视图。STATE 为渲染数据（读它建立渲染依赖）。三种形态：
1. 未选中组 → 占位「选择左侧的组」；
2. 选中组无配置 → 空态「尚未关联任何项目」+ 组定义的服务名（只读）；
3. 选中组有配置 → 组标题行 + 每份配置一个 `etaf-panel' 段。"
  (let* ((selected (plist-get state :selected))
         (group (and selected
                     (cl-find selected (plist-get state :groups)
                              :key (lambda (item) (plist-get item :name))
                              :test #'equal))))
    (cond
     ((null group)
      (ebasecamp-ui--detail-placeholder))
     ((null (plist-get group :instances))
      (ebasecamp-ui--empty-configs-view group))
     (t
      (let ((group-name (plist-get group :name)))
        (etaf-view
         (column :width 'stretch :height 'stretch :cross-align 'stretch
                 :padding '((lh 1) (ch 1)) :item-gap '(lh 1)
           (expr (ebasecamp-ui--group-header-row group))
           (column :width 'stretch :item-gap '(lh 1)
             (box :for (instance (plist-get group :instances))
                  :key (plist-get instance :config)
                  :width 'stretch
               (expr (ebasecamp-ui--instance-section
                      session group-name instance)))))))))))

(defun ebasecamp-ui--detail-placeholder ()
  "返回右侧面板的占位视图：未选中组时显示「选择左侧的组」。"
  (etaf-view
   (column :width 'stretch :height 'stretch :cross-align 'start
           :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
     (etaf-label :text "选择左侧的组" :variant 'muted))))

(defun ebasecamp-ui-view ()
  "返回 ebasecamp 主界面的视图（`etaf-view' 规范化后的对象）。"
  (etaf-view (ebasecamp-ui-app)))

(etaf-define-component ebasecamp-ui-app ()
  "渲染 ebasecamp 主界面：顶栏（标题 + 统计 + 刷新）、组树、右栏配置段。"
  :setup
  (let ((session (ebasecamp-ui-session)))
    (etaf-on-mounted
     (lambda ()
       (ebasecamp-status-start
        (lambda ()
          ;; 轮询刚跑过 `docker ps'：把结果连同「已提供」标记传下去，
          ;; 避免一次刷新采集两次（空表也算已采集）。
          (ebasecamp-ui-refresh (ebasecamp-status-last-records) t)))))
    (etaf-on-unmounted
     (lambda ()
       (ebasecamp-status-stop)
       (ebasecamp-ui--cancel-notice-timer session)))
    nil)
  :render
  (let* ((session (ebasecamp-ui-session))
         (state (etaf-value (ebasecamp-ui-session-state session))))
    ;; 读 selected-group / expanded 建立渲染依赖：选择或展开变化即重渲染
    ;; （树自身也读 expanded，这里显式读是为了让骨架整体对两者敏感）。
    (etaf-value (ebasecamp-ui-session-selected-group session))
    (etaf-value (ebasecamp-ui-session-expanded session))
    (if (plist-get state :empty-p)
        (etaf-view
         (box :width 'stretch :padding '((lh 2) (px 3)) :bgcolor "#F8F5EE"
              (etaf-empty
               :title "还没有 ebasecamp 清单"
               :description
               (format "在 %s 下定义 groups.el 与 projects/*.el 后重新打开。"
                       ebasecamp-config-directory))))
      (etaf-view
       (column :width 'stretch :height 'stretch :bgcolor "#F8F5EE"
               :color "#252A2E" :padding '((lh 1) (px 2))
               :item-gap '(lh 1)
         (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
           (etaf-label :text "ebasecamp" :variant 'strong)
           (etaf-label :text (plist-get state :summary) :variant 'muted)
           (box :flex-grow 1)
           (etaf-button :label "刷新" :variant 'secondary
                        :ref 'ebasecamp-ui-refresh
                        :on-press (lambda () (ebasecamp-ui-refresh))))
         (etaf-divider)
         (etaf-splitter
          :orientation 'horizontal
          :ratio ebasecamp-ui--split-ratio
          (slot :name 'first
            (expr (ebasecamp-ui--tree-view session)))
          (slot :name 'second
            (expr (ebasecamp-ui--detail-view session state))))
         (etaf-divider)
         (expr (ebasecamp-ui--footer-view))
         (expr (ebasecamp-ui--notice-view session))
         (ebasecamp-ui-confirm-dialog))))))

;;; 导入 / 导出入口

(defun ebasecamp-ui--error-text (err)
  "从错误对象 ERR（`(SYMBOL . DATA)'）取主消息字符串。纯函数。"
  (let ((data (cdr err)))
    (cond
     ((and data (stringp (car data))) (car data))
     (t (error-message-string err)))))

(defun ebasecamp-ui--error-detail (err)
  "从错误对象 ERR 取可展示的细节（DATA 中主消息之后的项）；无则 nil。纯函数。"
  (let ((rest (cddr err)))
    (when rest
      (mapconcat (lambda (item) (if (stringp item) item (format "%S" item)))
                 rest "\n"))))

(defun ebasecamp-ui--call-with-input (reader)
  "在有 etaf 事件上下文时用 `etaf-call-with-input' 执行 READER，否则直接执行。
`etaf-call-with-input' 只在 Host 事件回调（按钮 `:on-press'）里可用，否则
signal `etaf-event-error'；因此 `M-x' 直接调用与 ERT 场景降级为裸调用。
只捕获该错误类型：READER 自身的错误必须原样上抛，否则会被执行两次。"
  (if (fboundp 'etaf-call-with-input)
      (condition-case nil
          (etaf-call-with-input reader)
        (etaf-event-error (funcall reader)))
    (funcall reader)))

(defun ebasecamp-ui--read-compose-file ()
  "读一个 compose 文件路径；用户取消时返回 nil。
经 `ebasecamp-ui--call-with-input' 调用 `read-file-name'，使事件回调里由
Ebox 负责目标有效性与焦点恢复。"
  (ebasecamp-ui--call-with-input
   (lambda () (read-file-name "Compose 文件：" nil nil t))))

(defun ebasecamp-ui--import-name (file)
  "推断 FILE 的项目名并让用户确认，返回非空字符串。
空输入（直接回车）按建议名处理，与 `ebasecamp-import-file' 一致。"
  (let* ((default (ebasecamp-import-suggest-name file))
         (text (if (stringp default) default (symbol-name default)))
         (input (read-string (format "项目名（%s）：" text) nil nil text)))
    (if (string-empty-p (string-trim input)) text input)))

(defun ebasecamp-ui--target-file (name)
  "返回 NAME 对应的清单文件路径；NAME 非法时返回 nil。
归一与 `ebasecamp-import-apply' 同源（都经 `ebasecamp-import--normalize-name'），
否则大小写不一致会让「已存在」检查与实际写入路径错位。"
  (condition-case nil
      (ebasecamp-config-project-file (ebasecamp-import--normalize-name name))
    (ebasecamp-import-error nil)))

(defun ebasecamp-ui--import-compose (session file)
  "把 FILE 导入清单，成功后写 SESSION 的 notice 并刷新界面；返回落盘路径。
目标文件已存在时先经 `y-or-n-p' 确认覆盖，用户拒绝则返回 nil（不写 notice）。"
  (let* ((file (expand-file-name file))
         (name (ebasecamp-ui--import-name file))
         (target (ebasecamp-ui--target-file name))
         (force (and target (file-exists-p target) t)))
    (if (and force (not (y-or-n-p (format "%s 已存在，覆盖？" target))))
        nil
      (let ((path (ebasecamp-import-apply file name :force force)))
        (ebasecamp-ui--set-notice session 'success "导入完成" path)
        (ebasecamp-ui-refresh)
        path))))

(defun ebasecamp-ui-import-compose ()
  "选择 compose 文件导入为清单，成功后提示并刷新界面。返回落盘路径或 nil。
交互链：选文件（`read-file-name'）→ 确认项目名（`read-string'）→ 冲突时
`y-or-n-p' 确认覆盖 → `ebasecamp-import-apply' 落盘。项目根目录取 compose
文件父目录（与 `ebasecamp-import-apply' 的默认一致），不再单独提问。
用户取消（`quit'）静默返回 nil。"
  (interactive)
  (let ((session (ebasecamp-ui-session)))
    (condition-case err
        (let ((file (ebasecamp-ui--read-compose-file)))
          (when file
            (ebasecamp-ui--import-compose session file)))
      (quit nil)
      (ebasecamp-import-error
       (ebasecamp-ui--set-notice session 'error "导入失败"
                                 (ebasecamp-ui--error-text err)
                                 (ebasecamp-ui--error-detail err))
       nil)
      (error
       (ebasecamp-ui--set-notice session 'error "导入失败"
                                 (error-message-string err))
       nil))))

(defun ebasecamp-ui--read-project (prompt)
  "用 `completing-read' 从清单里选项目，返回项目名 symbol；未选到返回 nil。
PROMPT 为提示文案。清单无项目时写 info notice「没有可用项目」并返回 nil
（不抛错，让调用方安静收场）；用户取消选择时 `completing-read' 会 signal
`quit'，由调用方静默转成 nil。"
  (let ((projects (ebasecamp-model-projects)))
    (if (null projects)
        (progn
          (ebasecamp-ui--set-notice (ebasecamp-ui-session) 'info "没有可用项目"
                                    "请先在清单中定义项目")
          nil)
      (let ((name (completing-read
                   prompt
                   (mapcar (lambda (project)
                             (symbol-name (ebasecamp-project-name project)))
                           projects)
                   nil t)))
        (and (stringp name)
             (not (string-empty-p name))
             (intern name))))))

(defun ebasecamp-ui-export-compose ()
  "选项目并导出为部署用 compose 文件，成功后提示。返回导出路径或 nil。
项目经 `completing-read' 选择（D5：不再依赖「当前项目」兼容层）；返回 nil 的
三种情形一律安静：清单无项目（写 info notice「没有可用项目」）、用户取消
选择（`quit'）、导出层返回 nil（例如冲突三选一里选了取消）。
路径选择与覆盖冲突「换一个路径 / 覆盖 / 取消」三选一都由
`ebasecamp-export-project' 负责（这里把 `ebasecamp-export--interactive' 绑成
t，使事件回调上下文也能弹出该询问）。"
  (interactive)
  (let ((session (ebasecamp-ui-session)))
    (condition-case err
        (when-let* ((name (ebasecamp-ui--read-project "导出项目： ")))
          (let ((ebasecamp-export--interactive t)
                (path (ebasecamp-export-project
                       (ebasecamp-model-project name) :force nil)))
            (when path
              (ebasecamp-ui--set-notice session 'success "导出完成" path))
            path))
      (quit nil)
      (ebasecamp-export-error
       (ebasecamp-ui--set-notice session 'error "导出失败"
                                 (ebasecamp-ui--error-text err)
                                 (ebasecamp-ui--error-detail err))
       nil)
      (error
       (ebasecamp-ui--set-notice session 'error "导出失败"
                                 (error-message-string err))
       nil))))

(defun ebasecamp-ui-destroy-environment ()
  "选项目并把「销毁环境」转入二次确认，返回 t（已转入确认）或 nil。
交互链：`completing-read' 选项目 → 待确认动作写成 `(down . 项目名)'、置
`confirm' ref 为 t → `ebasecamp-ui-confirm-dialog' 弹出（文案点名该项目）。
真正的派发发生在确认按钮（`ebasecamp-ui-confirm'），且 keys 为 nil（全部
服务）：`down' 的语义是整个 compose 项目，shared 组不提供 down。
返回 nil 的两种情形一律安静：清单无项目（info notice「没有可用项目」）、
用户取消选择（`quit'）。"
  (interactive)
  (let ((session (ebasecamp-ui-session)))
    (condition-case nil
        (when-let* ((name (ebasecamp-ui--read-project "销毁项目： ")))
          (setf (ebasecamp-ui-session-confirm-action session) (cons 'down name))
          (etaf-set-value (ebasecamp-ui-session-confirm session) t)
          t)
      (quit nil))))

;;; 公开 API

(defun ebasecamp-ui-open ()
  "打开（或复用）ebasecamp 主界面 buffer，返回该 buffer。
清单未加载时先按 `ebasecamp-config-directory' 加载一次；buffer 已有运行时
则直接复用，不重复挂载。"
  (interactive)
  (ebasecamp-ui--ensure-manifest)
  (ebasecamp-ui-session)
  (let ((buffer (get-buffer-create ebasecamp-ui-buffer-name)))
    (with-current-buffer buffer
      (unless (etaf-runtime-for-buffer buffer)
        (etaf-mount buffer (ebasecamp-ui-view))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(defun ebasecamp-ui-refresh (&optional records supplied-p)
  "重新采集容器状态、重建渲染数据并写回会话，返回新的 state plist。
RECORDS 为已采集的状态记录（轮询回调传入；SUPPLIED-P 为真表示调用方明确
提供了记录，即使其值为 nil（例如 `docker ps' 返回空表）也不再重复采集，
避免一次刷新跑两次 `docker ps'）。未提供时调用
`ebasecamp-status-snapshot'（失败不 signal，错误留在
`ebasecamp-status-last-error'，旧记录保留）。
state 的 running / total 统计由 `ebasecamp-ui--build-state' 经
`ebasecamp-data-group-instances' 读 `ebasecamp-status-last-records' 得到，
因此快照必须先发生（轮询与命令完成后的刷新都靠它更新 last-records）；本函数
的 RECORDS 参数只用于「已采集」标记，不再参与 state 构建。"
  (interactive)
  (let ((session ebasecamp-ui--session))
    (when session
      (unless supplied-p
        (ebasecamp-status-snapshot))
      ;; RECORDS 仅作「已采集」标记（state 直接消费 last-records），
      ;; 显式消费它以满足「无未使用变量」的编译约束。
      (ignore records)
      (let* ((selected (etaf-value (ebasecamp-ui-session-selected-group session)))
             (state (ebasecamp-ui--build-state selected)))
        (etaf-set-value (ebasecamp-ui-session-state session) state)
        state))))

(defun ebasecamp-ui-close ()
  "关闭主界面：卸载运行时（触发 unmounted 收尾）、kill buffer、停轮询、
取消提示定时器、销毁会话。返回 nil。"
  (interactive)
  (when-let* ((buffer (get-buffer ebasecamp-ui-buffer-name)))
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (etaf-unmount runtime))
    (kill-buffer buffer))
  (ebasecamp-status-stop)
  (when-let* ((session ebasecamp-ui--session))
    (ebasecamp-ui--cancel-notice-timer session)
    (setq ebasecamp-ui--session nil))
  nil)

(provide 'ebasecamp-ui)
;;; ebasecamp-ui.el ends here
