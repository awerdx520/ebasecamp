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
;;   │  └─ slot second → column（占位："选择左侧的组"）
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
;;   生命周期命令执行中标记（`busy'，C4 用）、操作提示（`notice'，值为 nil 或
;;   `(:kind error|warning|success|info :title STR :message STR :detail STR-or-nil)'）、
;;   销毁确认框开关（`confirm'，C5 用）、待确认动作（`confirm-action'），以及
;;   提示自动清除定时器（`notice-timer'）。会话在 `ebasecamp-ui-open' 中创建，
;;   `ebasecamp-ui-close' 中销毁；
;; - 渲染数据是**单一 plist**：`ebasecamp-ui-refresh' 重新采集状态、重建
;;   state 并写回 ref，视图只需读 ref 就整体重渲染（不需要 render-tick）；
;; - `etaf-on-mounted' → `ebasecamp-status-start'，回调里调
;;   `ebasecamp-ui-refresh'（传入 `ebasecamp-status-last-records'，避免轮询
;;   一次刷新跑两次 `docker ps'）；
;; - `etaf-on-unmounted' → `ebasecamp-status-stop' + 取消提示定时器；
;; - 树的选择：`:on-select' 把组名写进 `selected-group'，`:on-toggle' 把新的
;;   key 列表写进 `expanded'（展开状态由会话持有，重渲染后保持）；
;; - 提示的呈现：`ebasecamp-ui--notice-view' 把 notice 渲染成 `etaf-alert'
;;   （`:detail' 以换行拼接进 message，`:dismissible' 的关闭按钮清空 notice）；
;;   成功 / 信息类提示在 `ebasecamp-ui-notice-timeout' 秒后自动清除，定时器
;;   存进会话，`ebasecamp-ui-close' 与写新 notice 时都会先取消它（防泄漏）。
;;   这里不用 `etaf-toast'：其实测要求 `:anchor' 必填（必须是带 `:id' 的
;;   Host），且 batch 下只画出标题、正文不可见，无法覆盖需要展示 stderr 的
;;   场景；
;; - 勾选服务只维护状态（`selected-ref'），操作条经 `ebasecamp-ui-selected-keys'
;;   消费它，经 `ebasecamp-ui-run-action' 派发到命令层（本轮的骨架**不渲染**
;;   操作条、notice、确认框：底栏与段内派发留到 C5，届时 selected-ref 会被
;;   按配置 / 服务的选择模型替换）；
;; - `busy' 为真时操作条全部 `:disabled'，`ebasecamp-ui-run-action' 也直接
;;   拒绝（双保险：UI 不渲染可点按钮，函数层不被误调）。
;;
;; 渲染期读 ref（`etaf-value'）会建立渲染依赖：写 ref 即可让统计文案、树项、
;; 展开状态同步更新。注意 `etaf-button' 的 `:disabled' 只接受布尔值（传 ref
;; 对象会 signal `etaf-renderer-error'），必须在渲染时读取其值。
;;
;; 本轮**不做** running / total 统计（C2 / C3）：state 里只有静态清单信息，
;; 采集到的状态记录留在 `ebasecamp-status-last-records' 供后续批次消费。
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

(defun ebasecamp-ui--config-state (group config)
  "把 GROUP 的一份配置 CONFIG（(NAME . PLIST)）转成 state 的配置项 plist。
字段：`:name' 配置名、`:project' 项目名、`:project-title' 项目标题（项目未
定义时为 nil）、`:scope' 组 scope（配置的 scope 恒等于组定义，D9）。纯函数。"
  (let* ((project-name (ebasecamp-model-config-project (cdr config)))
         (project (and project-name (ebasecamp-model-project project-name))))
    (list :name (symbol-name (car config))
          :project (and project-name (symbol-name project-name))
          :project-title (and project (ebasecamp-project-title project))
          :scope (symbol-name (ebasecamp-group-scope group)))))

(defun ebasecamp-ui--group-state (group)
  "把组对象 GROUP 转成 state 的组项 plist。
字段：`:name' 组名、`:title' 组标题、`:scope' scope、`:config-count' 配置
份数、`:configs' 配置项列表（见 `ebasecamp-ui--config-state'）。纯函数。"
  (let ((configs (ebasecamp-model-group-configs group)))
    (list :name (symbol-name (ebasecamp-group-name group))
          :title (ebasecamp-group-title group)
          :scope (symbol-name (ebasecamp-group-scope group))
          :config-count (length configs)
          :configs (mapcar (lambda (config)
                             (ebasecamp-ui--config-state group config))
                           configs))))

(defun ebasecamp-ui--build-state (&optional selected-group)
  "构建整棵树的渲染数据（plist）。纯函数（只读模型注册表）。
SELECTED-GROUP 为选中组名（symbol 或 nil），写进 `:selected'（字符串）。
结构：
  (:summary \"3 组 · 5 配置\"
   :groups ((:name \"mysql\" :title \"MySQL\" :scope \"per-project\"
             :config-count 2
             :configs ((:name \"dev\" :project \"myapp\"
                        :project-title \"示例项目\" :scope \"per-project\")
                       …))
            …)
   :selected \"mysql\" :empty-p nil)
组来自 `ebasecamp-model-groups'（**不依赖**项目是否存在）；配置来自
`ebasecamp-model-group-configs'。无任何组时 `:empty-p' 为 t，视图显示引导
空态。不含 running / total 统计（C2 / C3 才引入状态数据）。"
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

(defun ebasecamp-ui-selected-keys ()
  "返回当前选中的服务 key 列表（\"project/group/service\" 字符串）。
会话未建立时返回 nil；T3 的批量操作按钮消费本函数。"
  (let ((session ebasecamp-ui--session))
    (and session
         (copy-sequence
          (etaf-value (ebasecamp-ui-session-selected-ref session))))))

(defun ebasecamp-ui-current-project ()
  "返回当前「项目」名（symbol）；无法判定时返回 nil。
组为中心的骨架没有「当前项目」概念，本函数仅作为**导入 / 导出入口的兼容层**
保留（`ebasecamp-ui-import-compose' / `ebasecamp-ui-export-compose' 本轮不动，
C5 会改为按选中组 / 配置显式选择目标）：
1. 会话不存在时返回 nil；
2. 否则优先取选中组首份配置的 `:project'（组内没有配置时跳过）；
3. 仍无结果时回退到清单里的第一个项目（等价于旧实现「默认第一个项目」）。"
  (when-let* ((session ebasecamp-ui--session))
    (let* ((selected (etaf-value (ebasecamp-ui-session-selected-group session)))
           (configs (and selected
                         (ebasecamp-model-group selected)
                         (ebasecamp-model-group-configs selected))))
      (or (and configs (ebasecamp-model-config-project (cdr (car configs))))
          (let ((projects (ebasecamp-model-projects)))
            (and projects (ebasecamp-project-name (car projects))))))))

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
  "把界面选中 KEY（\"project/group/service\"）转成命令层 \"group/service\"。
只有三段形式才剥离项目前缀，其他形态原样返回。纯函数。"
  (let ((parts (and (stringp key) (split-string key "/"))))
    (if (and parts (= 3 (length parts)) (nth 1 parts) (nth 2 parts))
        (format "%s/%s" (nth 1 parts) (nth 2 parts))
      key)))

(defun ebasecamp-ui--command-keys (keys)
  "把界面选中 key 列表 KEYS 转成命令层 key 列表（逐项 `ebasecamp-ui--command-key'）。
纯函数。"
  (mapcar #'ebasecamp-ui--command-key keys))

;;; 树项 / 列

(defun ebasecamp-ui--group-caption (group)
  "返回组项的显示文案：标题 + 配置份数（如 \"mysql  (2)\"）。纯函数。
GROUP 为 state 的组项 plist。"
  (format "%s  (%d)" (plist-get group :title)
          (plist-get group :config-count)))

(defun ebasecamp-ui--config-caption (config)
  "返回配置项的显示文案：配置名 + 关联项目（如 \"dev  → 示例项目\"）。纯函数。
CONFIG 为 state 的配置项 plist；项目标题缺失时回退到项目名。"
  (format "%s  → %s" (plist-get config :name)
          (or (plist-get config :project-title)
              (plist-get config :project)
              "")))

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

(defun ebasecamp-ui--select-cell (session record)
  "选中列的单元格：checkbox 写回 SESSION 的选中列表。"
  (let ((key (ebasecamp-data--item-key record)))
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

(defun ebasecamp-ui--columns (session)
  "返回服务表的列定义（第一列为选中 checkbox）。
列 `:key' 用关键字，与记录 plist 的键一致，无 `:cell' 的列可直接取值。"
  (list (list :key :select :label "" :width 3
              :cell (lambda (record)
                      (ebasecamp-ui--select-cell session record)))
        (list :key :service :label "服务" :width 9)
        (list :key :image :label "镜像" :width 10)
        (list :key :state :label "状态" :width 9
              :cell #'ebasecamp-ui--state-cell)
        (list :key :ports :label "端口" :width 10
              :cell #'ebasecamp-ui--ports-cell)
        (list :key :health :label "健康" :width 8
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
  "真正派发 ACTION（PROJECT + KEYS），返回 t（已派发）或 nil（被拒）。
派发前置 busy，命令层抛 `ebasecamp-command-busy' 或其他错误时复位 busy 并写
notice，绝不让界面卡在「执行中」。"
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

(defun ebasecamp-ui--run-action (action confirmed)
  "`ebasecamp-ui-run-action' 的实现；CONFIRMED 非 nil 表示已通过销毁确认。
返回值：t 表示已受理（已派发，或销毁动作已转入确认），nil 表示被拒。"
  (let* ((session (ebasecamp-ui-session))
         (project (ebasecamp-ui-current-project)))
    (cond
     ((etaf-value (ebasecamp-ui-session-busy session))
      (ebasecamp-ui--set-notice session 'info "操作进行中" "请等待当前命令完成")
      nil)
     ((null project)
      (ebasecamp-ui--set-notice session 'info "没有可用项目"
                                "请先在清单中定义项目")
      nil)
     ((eq action 'down)
      (if confirmed
          (ebasecamp-ui--dispatch session action project nil)
        (setf (ebasecamp-ui-session-confirm-action session) action)
        (etaf-set-value (ebasecamp-ui-session-confirm session) t)
        t))
     ((not (memq action '(start stop restart)))
      (ebasecamp-ui--set-notice session 'error "未知动作"
                                (format "不支持的动作 %S" action))
      nil)
     (t
      (let ((keys (ebasecamp-ui--command-keys (ebasecamp-ui-selected-keys))))
        (cond
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
              (ebasecamp-ui--dispatch session action project keys))))))))))

(defun ebasecamp-ui-run-action (action)
  "执行生命周期 ACTION（start / stop / restart / down），返回 t 或 nil。
返回 t 表示已受理：start / stop / restart 已派发到命令层，down 已转入确认；
返回 nil 表示被拒，并把原因写进会话的 notice。拒绝条件：
- 会话 busy（已有命令在执行）；
- 无当前项目；
- start / stop / restart 未勾选服务；
- start 的端口冲突含 `duplicate' / `busy'（只含 `unknown' 时放行并提示）；
- ACTION 不是四种动作之一。
本函数经 `ebasecamp-command-run' 派发，自身不拼接任何 docker 命令。"
  (ebasecamp-ui--run-action action nil))

(defun ebasecamp-ui-confirm ()
  "执行确认框里待确认的动作（当前只有 down），返回 t 或 nil。
确认按钮与测试调用本函数；无论成功与否都先清空待确认状态，避免重复派发。"
  (interactive)
  (let* ((session ebasecamp-ui--session)
         (action (and session (ebasecamp-ui-session-confirm-action session))))
    (when session
      (etaf-set-value (ebasecamp-ui-session-confirm session) nil)
      (setf (ebasecamp-ui-session-confirm-action session) nil))
    (if (and session action)
        (ebasecamp-ui--run-action action t)
      nil)))

(defun ebasecamp-ui-dismiss-confirm ()
  "关闭确认框并丢弃待确认动作，返回 nil。"
  (interactive)
  (let ((session ebasecamp-ui--session))
    (when session
      (etaf-set-value (ebasecamp-ui-session-confirm session) nil)
      (setf (ebasecamp-ui-session-confirm-action session) nil)))
  nil)

;;; 操作条与确认框视图

(defun ebasecamp-ui--action-button (session label action variant)
  "返回操作条按钮：文案 LABEL、语义 VARIANT，按下派发 ACTION。
SESSION 的 busy 为真时按钮禁用（渲染期读 ref，写 ref 即触发重渲染）。"
  (etaf-view
   (etaf-button
    :label label
    :variant variant
    :disabled (and (etaf-value (ebasecamp-ui-session-busy session)) t)
    :on-press (lambda () (ebasecamp-ui-run-action action)))))

(defun ebasecamp-ui--bar-button (label function variant)
  "返回操作条按钮：文案 LABEL、语义 VARIANT，按下调用 FUNCTION。
与 `ebasecamp-ui--action-button' 的区别：本函数直接调用回调，不经
`ebasecamp-ui-run-action' 派发生命周期动作。"
  (etaf-view
   (etaf-button
    :label label
    :variant variant
    :on-press (lambda () (funcall function)))))

(defun ebasecamp-ui--action-bar (session)
  "返回底栏操作条：生命周期按钮一行，导入 / 导出 compose 入口一行。
导入 / 导出不参与 `busy' 判定（它们不是生命周期动作），因此恒可点。
两行而不是一行：80 列终端下六个按钮同行会溢出，标签会被裁切。"
  (etaf-view
   (column :width 'stretch :item-gap '(lh 0)
     (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
       (expr (ebasecamp-ui--action-button session "启动选中" 'start 'primary))
       (expr (ebasecamp-ui--action-button session "停止选中" 'stop 'secondary))
       (expr (ebasecamp-ui--action-button session "重启选中" 'restart 'secondary))
       (expr (ebasecamp-ui--action-button session "销毁环境" 'down 'ghost)))
     (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
       (expr (ebasecamp-ui--bar-button
              "导入 compose" #'ebasecamp-ui-import-compose 'ghost))
       (expr (ebasecamp-ui--bar-button
              "导出 compose" #'ebasecamp-ui-export-compose 'ghost))))))

(defun ebasecamp-ui--confirm-dialog (session)
  "返回销毁环境的确认框：`:open' 绑在 SESSION 的 confirm ref 上。
`etaf-dialog' 的 `:open' 接受 ref（内部经 `etaf-ui--reactive-value' 读取并
建立渲染依赖），因此写 ref 即可开关对话框。"
  (etaf-view
   (etaf-dialog
    :open (ebasecamp-ui-session-confirm session)
    :title "销毁环境"
    :width '(ch 46)
    :close-label nil
    :on-close (lambda () (ebasecamp-ui-dismiss-confirm))
    (column :width 'stretch :item-gap '(lh 1)
      (etaf-label
       :text "将停止并移除本项目（per-project）的全部容器，不会删除卷。")
      (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
        (etaf-button :label "取消" :variant 'secondary
                     :on-press (lambda () (ebasecamp-ui-dismiss-confirm)))
        (etaf-button :label "确认销毁" :variant 'primary
                     :on-press (lambda () (ebasecamp-ui-confirm))))))))

;;; 交互与视图（组为中心的骨架）

(defun ebasecamp-ui--select-key (session key)
  "把树节点的选择写进 SESSION：KEY 归一为所属组名，同时重建 state。
配置节点的 key 是 \"config/组名/配置名\"，选中配置等同于选中它所属的组
（段内（配置 / 服务）的选择留到 C5）。"
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

(defun ebasecamp-ui--detail-placeholder ()
  "返回右侧面板的占位视图。段渲染（配置 / 服务 / 状态）留到 C1 / C2。"
  (etaf-view
   (column :width 'stretch :height 'stretch :cross-align 'start
           :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
     (etaf-label :text "选择左侧的组" :variant 'muted))))

(defun ebasecamp-ui-view ()
  "返回 ebasecamp 主界面的视图（`etaf-view' 规范化后的对象）。"
  (etaf-view (ebasecamp-ui-app)))

(etaf-define-component ebasecamp-ui-app ()
  "渲染 ebasecamp 组为中心的骨架：顶栏（标题 + 统计 + 刷新）、组树、右侧占位。"
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
            (expr (ebasecamp-ui--detail-placeholder))))
         (etaf-divider))))))

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

(defun ebasecamp-ui-export-compose ()
  "把当前项目导出为部署用 compose 文件，成功后提示。返回导出路径或 nil。
路径选择与覆盖冲突「换一个路径 / 覆盖 / 取消」三选一都由
`ebasecamp-export-project' 负责（这里把 `ebasecamp-export--interactive' 绑成
t，使事件回调上下文也能弹出该询问）。"
  (interactive)
  (let ((session (ebasecamp-ui-session))
        (project (ebasecamp-ui-current-project)))
    (if (null project)
        (progn
          (ebasecamp-ui--set-notice session 'info "请先选择项目"
                                    "清单里还没有项目，或尚未选定项目")
          nil)
      (condition-case err
          (let ((ebasecamp-export--interactive t)
                (path (ebasecamp-export-project
                       (ebasecamp-model-project project) :force nil)))
            (when path
              (ebasecamp-ui--set-notice session 'success "导出完成" path))
            path)
        (quit nil)
        (ebasecamp-export-error
         (ebasecamp-ui--set-notice session 'error "导出失败"
                                   (ebasecamp-ui--error-text err)
                                   (ebasecamp-ui--error-detail err))
         nil)
        (error
         (ebasecamp-ui--set-notice session 'error "导出失败"
                                   (error-message-string err))
         nil)))))

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
`ebasecamp-status-last-error'，旧记录保留）。骨架的 state 暂不消费 RECORDS
（running / total 统计是 C2 / C3 的事），但采集必须发生：轮询与命令完成后的
刷新都靠它更新 `ebasecamp-status-last-records'。"
  (interactive)
  (let ((session ebasecamp-ui--session))
    (when session
      (unless supplied-p
        (ebasecamp-status-snapshot))
      ;; RECORDS 本轮不参与 state 构建（running / total 是 C2 / C3 的事），
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
