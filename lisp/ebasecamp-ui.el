;;; ebasecamp-ui.el --- ebasecamp 只读主界面（etaf / etaf-ui） -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.1.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 主界面：在一个 etaf 缓冲区里展示「项目 → 组 → 服务」三层的只读视图。
;;
;; 布局（一个 Host 树）：
;;
;;   根 column
;;   ├─ row（顶栏）: etaf-tabs（项目）+ etaf-button（刷新）
;;   ├─ etaf-divider
;;   ├─ row（主体）
;;   │  ├─ box → etaf-tree（当前项目的组，扁平结构，叶子即组）
;;   │  └─ box → etaf-data-grid（服务表：服务 / 镜像 / 状态 / 端口 / 健康）
;;   ├─ etaf-divider
;;   ├─ row（操作条）: 启动选中 / 停止选中 / 重启选中 / 销毁环境
;;   ├─ etaf-label（notice；无提示时显示操作提示）
;;   └─ etaf-dialog（销毁环境确认；`:open' 绑在会话的 confirm ref 上）
;;
;; 清单为空时整棵树替换为 `etaf-empty'；当前项目无组时表格显示
;; `:empty-label'。
;;
;; 状态与生命周期：
;;
;; - 会话对象（`ebasecamp-ui-session'）持有 Data controller 与四个 `etaf-ref'：
;;   当前项目（`project-ref'）、选中 key 列表（`selected-ref'）、生命周期命令
;;   执行中标记（`busy'）、操作提示（`notice'，值为 nil 或
;;   `(:kind error|info :title STR :message STR)')、销毁确认框开关（`confirm'）。
;;   会话在 `ebasecamp-ui-open' 中创建，`ebasecamp-ui-close' 中销毁；
;; - `etaf-on-mounted' → `ebasecamp-status-start'，回调里**只**调
;;   `etaf-data-load'（不调 `ebasecamp-data-refresh'，否则一次刷新会跑两次
;;   `docker ps'）；
;; - `etaf-on-unmounted' → `ebasecamp-status-stop' + `etaf-data-stop'；
;; - 项目切换：写 `project-ref'，再 `etaf-data-set-query' + `etaf-data-load'；
;; - 勾选服务只维护状态（`selected-ref'），操作条经 `ebasecamp-ui-selected-keys'
;;   消费它，经 `ebasecamp-ui-run-action' 派发到命令层；
;; - `busy' 为真时操作条全部 `:disabled'，`ebasecamp-ui-run-action' 也直接
;;   拒绝（双保险：UI 不渲染可点按钮，函数层不被误调）。
;;
;; 渲染期读 ref（`etaf-value'）会建立渲染依赖：写 ref 即可让按钮的
;; `:disabled'、notice 文案、确认框开关同步更新，因此**不需要**额外的
;; render-tick 机制。注意 `etaf-button' 的 `:disabled' 只接受布尔值（传 ref
;; 对象会 signal `etaf-renderer-error'），必须在渲染时读取其值。
;;
;; 数据来源：`ebasecamp-data-project-records' 给出「清单 ∪ 状态」记录，
;; 因此清单里有定义但未启动的服务也会出现在表里（state 为 "stopped"）。
;;
;; 本模块不拼任何 docker 命令（那是 `ebasecamp-docker' / `ebasecamp-command'
;; 的职责），只消费 `ebasecamp-status'、`ebasecamp-data' 与
;; `ebasecamp-command' 的公开接口。

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'ebasecamp-model)
(require 'ebasecamp-config)
(require 'ebasecamp-status)
(require 'ebasecamp-data)
(require 'ebasecamp-command)

(defcustom ebasecamp-ui-buffer-name "*ebasecamp*"
  "ebasecamp 主界面的缓冲区名。"
  :type 'string
  :group 'ebasecamp)

(defcustom ebasecamp-ui-group-pane-width (quote (ch 20))
  "组列表面板的宽度（etaf 长度表达式）。"
  :type 'sexp
  :group 'ebasecamp)

;;; 会话

(cl-defstruct (ebasecamp-ui-session (:constructor ebasecamp-ui--session-create))
  "一次界面会话的可变状态。
CONTROLLER 为 Data controller；PROJECT-REF / SELECTED-REF / BUSY / NOTICE /
CONFIRM 均为 `etaf-ref'；CONFIRM-ACTION 为等待确认的动作 symbol（无则 nil）。"
  controller project-ref selected-ref busy notice confirm confirm-action)

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

(defun ebasecamp-ui--new-session ()
  "创建并返回新的界面会话（controller + 项目 / 选中 / busy / notice / confirm ref）。"
  (let* ((projects (mapcar #'ebasecamp-project-name
                           (ebasecamp-model-projects)))
         (controller (ebasecamp-data-controller))
         (project (car projects)))
    (when project
      (etaf-data-set-query controller (symbol-name project)))
    (ebasecamp-ui--session-create
     :controller controller
     :project-ref (etaf-ref project :name 'ebasecamp-ui-project)
     :selected-ref (etaf-ref nil :name 'ebasecamp-ui-selected)
     :busy (etaf-ref nil :name 'ebasecamp-ui-busy)
     :notice (etaf-ref nil :name 'ebasecamp-ui-notice)
     :confirm (etaf-ref nil :name 'ebasecamp-ui-confirm)
     :confirm-action nil)))

(defun ebasecamp-ui-session ()
  "返回当前会话；不存在时创建。
会话在 `ebasecamp-ui-open' 中建立；直接调用本函数便于测试与
`ebasecamp-ui-refresh' 在 buffer 已被外部 kill 后仍可用。"
  (or ebasecamp-ui--session
      (setq ebasecamp-ui--session (ebasecamp-ui--new-session))))

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
  "返回当前项目名（symbol）；无项目或未打开界面时返回 nil。"
  (let ((session ebasecamp-ui--session))
    (and session (etaf-value (ebasecamp-ui-session-project-ref session)))))

;;; 操作提示（notice）

(defconst ebasecamp-ui--blocking-conflict-kinds '(duplicate busy)
  "会阻塞启动的端口冲突类型。
`unknown'（探测不可用）不阻塞，只作为提示写进 notice。")

(defun ebasecamp-ui--set-notice (session kind title message)
  "把 SESSION 的 notice 写成 KIND（error/info）+ TITLE + MESSAGE，返回 nil。"
  (when session
    (etaf-set-value (ebasecamp-ui-session-notice session)
                    (list :kind kind :title title :message message)))
  nil)

(defun ebasecamp-ui--notice (session)
  "返回 SESSION 的 notice 值（nil 或 plist），读 ref 以建立渲染依赖。"
  (and session (etaf-value (ebasecamp-ui-session-notice session))))

(defun ebasecamp-ui--notice-text (session)
  "返回操作条下方的提示文案：有 notice 用「标题：正文」，否则用默认提示。"
  (let ((notice (ebasecamp-ui--notice session)))
    (if (and notice (plist-get notice :title))
        (format "%s：%s" (plist-get notice :title)
                (or (plist-get notice :message) ""))
      ebasecamp-ui--hint)))

(defun ebasecamp-ui--notice-variant (session)
  "把 notice 的语义映射为 `etaf-label' 的 variant。纯展示逻辑。"
  (pcase (plist-get (ebasecamp-ui--notice session) :kind)
    ('error 'danger)
    ('info 'muted)
    (_ 'muted)))

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

;;; 项目 / 组 / 列

(defun ebasecamp-ui--tab-items (projects)
  "把项目对象列表 PROJECTS 转成 `etaf-tabs' 的 :items。
key 与 label 都用项目名，保证唯一。"
  (mapcar (lambda (project)
            (let ((name (symbol-name (ebasecamp-project-name project))))
              (list :key (ebasecamp-project-name project) :label name)))
          projects))

(defun ebasecamp-ui--project-running (aggregates group-name)
  "从聚合项 AGGREGATES 中取 GROUP-NAME 的 running 数（无则 0）。"
  (let ((entry (cl-find group-name aggregates
                        :key (lambda (item)
                               (ebasecamp-data--name-string
                                (plist-get item :group)))
                        :test #'equal)))
    (or (and entry (plist-get entry :running)) 0)))

(defun ebasecamp-ui--group-items (project-name records)
  "返回 PROJECT-NAME 的分组树项（扁平结构，叶子即组）。
RECORDS 为该项目当前的服务记录（`ebasecamp-data' 的「清单 ∪ 状态」），
running 数来自 `ebasecamp-status-aggregate'，total 数来自清单（清单是唯一
事实源）。无项目时返回 nil。"
  (when-let* ((project (and project-name
                            (ebasecamp-model-project project-name))))
    (let* ((name (ebasecamp-data--name-string project-name))
           (aggregates (ebasecamp-status-aggregate
                        (cl-remove-if-not
                         (lambda (record)
                           (equal (ebasecamp-data--name-string
                                   (plist-get record :project))
                                  name))
                         records)))
           (items nil))
      (dolist (group-ref (ebasecamp-project-groups project))
        (let* ((group-name (ebasecamp-data--name-string
                            (plist-get group-ref :group)))
               (total (length (ebasecamp-model-resolve-services
                               project group-ref)))
               (running (ebasecamp-ui--project-running aggregates group-name)))
          (push (list :key group-name
                      :label (format "%s  (%d/%d)" group-name running total))
                items)))
      (nreverse items))))

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

(defun ebasecamp-ui--on-complete (session action)
  "构造 `ebasecamp-command-run' 的完成回调。
回调里清 SESSION 的 busy、刷新数据、并写 ACTION 的完成 / 失败 notice。"
  (let ((label (ebasecamp-ui--action-label action)))
    (lambda (result)
      (etaf-set-value (ebasecamp-ui-session-busy session) nil)
      (ebasecamp-ui-refresh)
      (if (plist-get result :ok)
          (ebasecamp-ui--set-notice
           session 'info (format "%s完成" label)
           "所有批次已执行完成")
        (ebasecamp-ui--set-notice
         session 'error (format "%s失败" label)
         "批次未全部成功，请查看命令行输出"))
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

(defun ebasecamp-ui--action-bar (session)
  "返回底栏操作条：启动选中 / 停止选中 / 重启选中 / 销毁环境。"
  (etaf-view
   (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
     (expr (ebasecamp-ui--action-button session "启动选中" 'start 'primary))
     (expr (ebasecamp-ui--action-button session "停止选中" 'stop 'secondary))
     (expr (ebasecamp-ui--action-button session "重启选中" 'restart 'secondary))
     (expr (ebasecamp-ui--action-button session "销毁环境" 'down 'ghost)))))

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

;;; 交互

(defun ebasecamp-ui--select-project (session key)
  "把当前项目切到 KEY（项目名 symbol），并重载表格数据。"
  (etaf-set-value (ebasecamp-ui-session-project-ref session) key)
  (let ((controller (ebasecamp-ui-session-controller session)))
    (etaf-data-set-query controller (symbol-name key))
    (etaf-data-load controller)))

(defun ebasecamp-ui-view ()
  "返回 ebasecamp 主界面的视图（`etaf-view' 规范化后的对象）。"
  (etaf-view (ebasecamp-ui-app)))

(etaf-define-component ebasecamp-ui-app ()
  "渲染 ebasecamp 只读主界面（顶栏 tabs + 刷新、组列表、服务表、底栏提示）。"
  :setup
  (let ((session (ebasecamp-ui-session)))
    (etaf-on-mounted
     (lambda ()
       (ebasecamp-status-start
        (lambda ()
          (etaf-data-load (ebasecamp-ui-session-controller session))))))
    (etaf-on-unmounted
     (lambda ()
       (ebasecamp-status-stop)
       (etaf-data-stop (ebasecamp-ui-session-controller session))))
    nil)
  :render
  (let* ((session (ebasecamp-ui-session))
         (projects (ebasecamp-model-projects))
         (current (ebasecamp-ui-current-project))
         (controller (ebasecamp-ui-session-controller session))
         ;; 读 items 使本组件成为 Data 的依赖：每次 load 后组列表的
         ;; "(running/total)" 随之刷新（status 记录本身不是 reactive 源）。
         (records (etaf-value (etaf-data-items controller)))
         (groups (ebasecamp-ui--group-items current records)))
    (if (null projects)
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
           (box :flex-grow 1
             (etaf-tabs :items (ebasecamp-ui--tab-items projects)
                        :active current
                        :on-change (lambda (key)
                                     (ebasecamp-ui--select-project session key))))
           (etaf-button :label "刷新" :variant 'secondary
                        :ref 'ebasecamp-ui-refresh
                        :on-press (lambda () (ebasecamp-ui-refresh))))
         (etaf-divider)
         (row :width 'stretch :cross-align 'start :item-gap '(ch 2)
           (box :width ebasecamp-ui-group-pane-width :flex-shrink 0
             (etaf-tree :if groups
                        :items groups
                        :expanded nil))
           (box :flex-grow 1 :flex-shrink 1 :flex-basis '(ch 48)
             (etaf-data-grid
              :controller controller
              :columns (ebasecamp-ui--columns session)
              :row-key #'ebasecamp-data--item-key
              :loading-label "正在加载…"
              :error-label "读取容器状态失败"
              :empty-label "该项目还没有服务")))
         (etaf-divider)
         (expr (ebasecamp-ui--action-bar session))
         (etaf-label
          :variant (ebasecamp-ui--notice-variant session)
          :text (ebasecamp-ui--notice-text session))
         (expr (ebasecamp-ui--confirm-dialog session)))))))

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

(defun ebasecamp-ui-refresh ()
  "手动刷新：采一次容器状态快照并让表格重新加载。返回加载结果（可能为 nil）。"
  (interactive)
  (let ((session ebasecamp-ui--session))
    (when session
      (ebasecamp-data-refresh (ebasecamp-ui-session-controller session)))))

(defun ebasecamp-ui-close ()
  "关闭主界面：卸载运行时（触发 unmounted 收尾）、停轮询、销毁会话与 buffer。
返回 nil。"
  (interactive)
  (when-let* ((buffer (get-buffer ebasecamp-ui-buffer-name)))
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (etaf-unmount runtime))
    (kill-buffer buffer))
  (ebasecamp-status-stop)
  (when-let* ((session ebasecamp-ui--session))
    (etaf-data-stop (ebasecamp-ui-session-controller session))
    (setq ebasecamp-ui--session nil))
  nil)

(provide 'ebasecamp-ui)
;;; ebasecamp-ui.el ends here
