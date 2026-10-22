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
;;   └─ etaf-label（底栏提示；T3 在这里放批量操作按钮）
;;
;; 清单为空时整棵树替换为 `etaf-empty'；当前项目无组时表格显示
;; `:empty-label'。
;;
;; 状态与生命周期：
;;
;; - 会话对象（`ebasecamp-ui-session'）持有 Data controller 与两个 `etaf-ref'：
;;   当前项目（`project-ref'）与选中 key 列表（`selected-ref'）。会话在
;;   `ebasecamp-ui-open' 中创建，`ebasecamp-ui-close' 中销毁；
;; - `etaf-on-mounted' → `ebasecamp-status-start'，回调里**只**调
;;   `etaf-data-load'（不调 `ebasecamp-data-refresh'，否则一次刷新会跑两次
;;   `docker ps'）；
;; - `etaf-on-unmounted' → `ebasecamp-status-stop' + `etaf-data-stop'；
;; - 项目切换：写 `project-ref'，再 `etaf-data-set-query' + `etaf-data-load'；
;; - 勾选服务只维护状态（`selected-ref'），本期不执行任何 docker 操作；
;;   T3 通过 `ebasecamp-ui-selected-keys' 消费它。
;;
;; 数据来源：`ebasecamp-data-project-records' 给出「清单 ∪ 状态」记录，
;; 因此清单里有定义但未启动的服务也会出现在表里（state 为 "stopped"）。
;;
;; 本模块不拼任何 docker 命令（那是 `ebasecamp-docker' / `ebasecamp-command'
;; 的职责），只消费 `ebasecamp-status' 与 `ebasecamp-data' 的公开接口。

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'ebasecamp-model)
(require 'ebasecamp-config)
(require 'ebasecamp-status)
(require 'ebasecamp-data)

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
CONTROLLER 为 Data controller；PROJECT-REF / SELECTED-REF 为 `etaf-ref'。"
  controller project-ref selected-ref)

(defvar ebasecamp-ui--session nil
  "当前界面会话（`ebasecamp-ui-session' 对象）；未打开时为 nil。")

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
  "创建并返回新的界面会话（controller + 两个 ref）。"
  (let* ((projects (mapcar #'ebasecamp-project-name
                           (ebasecamp-model-projects)))
         (controller (ebasecamp-data-controller))
         (project (car projects)))
    (when project
      (etaf-data-set-query controller (symbol-name project)))
    (ebasecamp-ui--session-create
     :controller controller
     :project-ref (etaf-ref project :name 'ebasecamp-ui-project)
     :selected-ref (etaf-ref nil :name 'ebasecamp-ui-selected))))

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
         (etaf-label
          :variant 'muted
          :text "只读界面：勾选服务供后续批量操作；容器状态每 3 秒刷新。"))))))

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
