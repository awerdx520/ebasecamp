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
;;   │                 （下一行）导入 compose / 导出 compose
;;   ├─ etaf-alert（notice；无提示时退化为一行 etaf-label 操作提示）
;;   └─ etaf-dialog（销毁环境确认；`:open' 绑在会话的 confirm ref 上）
;;
;; 清单为空时整棵树替换为 `etaf-empty'；当前项目无组时表格显示
;; `:empty-label'。
;;
;; 状态与生命周期：
;;
;; - 会话对象（`ebasecamp-ui-session'）持有 Data controller 与若干 `etaf-ref'：
;;   当前项目（`project-ref'）、选中 key 列表（`selected-ref'）、生命周期命令
;;   执行中标记（`busy'）、操作提示（`notice'，值为 nil 或
;;   `(:kind error|warning|success|info :title STR :message STR :detail STR-or-nil)'）、
;;   销毁确认框开关（`confirm'），以及提示自动清除定时器（`notice-timer'）。
;;   会话在 `ebasecamp-ui-open' 中创建，`ebasecamp-ui-close' 中销毁；
;; - 提示的呈现：notice 非 nil 时渲染 `etaf-alert'（`:variant' 由 `:kind' 映射、
;;   `:dismissible' 的关闭按钮清空 notice），`:detail' 以换行拼接进 message；
;;   成功 / 信息类提示在 `ebasecamp-ui-notice-timeout' 秒后自动清除，定时器
;;   存进会话，`ebasecamp-ui-close' 与写新 notice 时都会先取消它（防泄漏）。
;;   这里不用 `etaf-toast'：其实测要求 `:anchor' 必填（必须是带 `:id' 的
;;   Host），且 batch 下只画出标题、正文不可见，无法覆盖需要展示 stderr 的
;;   场景；
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

(defcustom ebasecamp-ui-group-pane-width (quote (ch 20))
  "组列表面板的宽度（etaf 长度表达式）。"
  :type 'sexp
  :group 'ebasecamp)

(defcustom ebasecamp-ui-notice-timeout 3
  "成功 / 信息类提示自动清除的秒数。
错误类提示不自动清除（需要用户阅读 stderr），只能手动关闭。"
  :type 'number
  :group 'ebasecamp)

;;; 会话

(cl-defstruct (ebasecamp-ui-session (:constructor ebasecamp-ui--session-create))
  "一次界面会话的可变状态。
CONTROLLER 为 Data controller；PROJECT-REF / SELECTED-REF / BUSY / NOTICE /
CONFIRM 均为 `etaf-ref'；CONFIRM-ACTION 为等待确认的动作 symbol（无则 nil）；
NOTICE-TIMER 为临时的提示自动清除定时器（无则 nil，必须随会话一起取消）。"
  controller project-ref selected-ref busy notice confirm confirm-action
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

;;; 交互

(defun ebasecamp-ui--select-project (session key)
  "把当前项目切到 KEY（项目名 symbol），清空选中项，并重载表格数据。
选中 key 带项目前缀，跨项目残留会让命令层拿到不属于当前项目的 key（报
「未引用组」），因此切换项目必须清空选中。"
  (etaf-set-value (ebasecamp-ui-session-project-ref session) key)
  (etaf-set-value (ebasecamp-ui-session-selected-ref session) nil)
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
         (expr (ebasecamp-ui--notice-view session))
         (expr (ebasecamp-ui--confirm-dialog session)))))))

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

(defun ebasecamp-ui-refresh ()
  "手动刷新：采一次容器状态快照并让表格重新加载。返回加载结果（可能为 nil）。"
  (interactive)
  (let ((session ebasecamp-ui--session))
    (when session
      (ebasecamp-data-refresh (ebasecamp-ui-session-controller session)))))

(defun ebasecamp-ui-close ()
  "关闭主界面：卸载运行时（触发 unmounted 收尾）、停轮询、取消提示定时器、
销毁会话与 buffer。返回 nil。"
  (interactive)
  (when-let* ((buffer (get-buffer ebasecamp-ui-buffer-name)))
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (etaf-unmount runtime))
    (kill-buffer buffer))
  (ebasecamp-status-stop)
  (when-let* ((session ebasecamp-ui--session))
    (ebasecamp-ui--cancel-notice-timer session)
    (etaf-data-stop (ebasecamp-ui-session-controller session))
    (setq ebasecamp-ui--session nil))
  nil)

(provide 'ebasecamp-ui)
;;; ebasecamp-ui.el ends here
