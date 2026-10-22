;;; ebasecamp-ui-tests.el --- ebasecamp etaf 主界面测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; `lisp/ebasecamp-ui.el' 的 ERT 测试。
;;
;; C0（组为中心的骨架）后界面只有「顶栏 + 组树 + 右侧占位」，因此断言分两块：
;; - 渲染数据（`ebasecamp-ui--build-state'）：纯函数，直接断言 plist 结构；
;; - 渲染结果：`etaf-render' 只支持无状态组件（本界面有 `:setup' 生命周期），
;;   所以在 `emacs -Q --batch' 下用 `etaf-mount' 挂到真实 buffer 后断言
;;   `buffer-string'（已用探针验证 batch 下可挂载）。断言只匹配文案 token，
;;   不依赖列宽或换行位置。
;;
;; 骨架**不渲染**操作条 / notice / 确认框（底栏与段内派发留到 C5），因此这些
;; 机制的测试只覆盖函数层（notice 视图用独立 buffer 单独挂载断言），不依赖
;; 主界面树结构。
;;
;; 数据全部来自伪造的 `ebasecamp-docker-ps' 与临时清单元数据；每个用例在
;; 临时 `ebasecamp-config-directory' 下运行，结束时 `ebasecamp-ui-close'
;; 卸载运行时并停轮询（避免 repeating timer 泄漏到其他用例）。

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ebasecamp-model)
(require 'ebasecamp-command)
(require 'ebasecamp-import)
(require 'ebasecamp-export)
(require 'ebasecamp-ui)

;;; 测试脚手架

(defmacro ebasecamp-ui-test--with-ui (&rest body)
  "在临时清单目录 + 清空模型注册表中执行 BODY，结束后关闭界面并清理。"
  (declare (indent 0) (debug t))
  `(let ((ebasecamp-config-directory
          (file-name-as-directory (make-temp-file "ebasecamp-ui-test-" t))))
     (ebasecamp-model-reset)
     (unwind-protect
         (progn ,@body)
       (ignore-errors (ebasecamp-ui-close))
       (ebasecamp-status-stop)
       (ebasecamp-model-reset)
       (ignore-errors (delete-directory ebasecamp-config-directory t)))))

(defun ebasecamp-ui-test--container (project group service state health)
  "构造一个容器 plist（与 `ebasecamp-docker-ps' 产物形态一致）。"
  (list :id (format "id-%s-%s" group service)
        :names (format "%s-%s-1" project service)
        :image "mysql:8.4"
        :state state
        :health health
        :ports "0.0.0.0:3306->3306/tcp"
        :labels (list (cons "ebasecamp.managed" "true")
                      (cons "ebasecamp.project" project)
                      (cons "ebasecamp.group" group)
                      (cons "ebasecamp.service" service)
                      (cons "ebasecamp.scope" "shared"))
        :project project
        :group group
        :service service
        :scope "shared"))

(defmacro ebasecamp-ui-test--with-ps (containers &rest body)
  "在伪造 `ebasecamp-docker-ps'（返回 CONTAINERS）的上下文里执行 BODY。"
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'ebasecamp-docker-ps)
              (lambda () ,containers)))
     ,@body))

(defun ebasecamp-ui-test--manifest ()
  "定义一个项目 myapp（shared 组 mysql，2 个服务，无组内配置）。"
  (ebasecamp-define-group mysql
    :scope shared
    :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))
               (mysql-ro :image "mysql:8.4")))
  (ebasecamp-define-project myapp :groups ((mysql))))

(defun ebasecamp-ui-test--configs-manifest ()
  "定义组 mysql（per-project，2 份配置）与项目 myapp（不引用该组）。
组内配置都指向 myapp；项目 groups 槽留空，避免「重复引用组」物化错误。"
  (ebasecamp-define-group mysql
    :scope per-project
    :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306))))
    :configs ((dev :project myapp)
              (prod :project myapp)))
  (ebasecamp-define-project myapp :title "示例项目" :groups nil))

(defun ebasecamp-ui-test--buffer-text ()
  "返回 `ebasecamp-ui-buffer-name' buffer 的纯文本内容。"
  (substring-no-properties
   (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
     (buffer-string))))

(defun ebasecamp-ui-test--mount-text (view)
  "把 VIEW 挂到临时 buffer 上，返回其纯文本内容（用完即卸载并 kill）。
用于断言不属于主界面骨架的视图（例如 notice 的 etaf-alert）。"
  (let ((buffer (generate-new-buffer " *ebc-view*")))
    (unwind-protect
        (progn
          (etaf-mount buffer view)
          (substring-no-properties
           (with-current-buffer buffer (buffer-string))))
      (ignore-errors
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime)))
      (kill-buffer buffer))))

(defun ebasecamp-ui-test--contains-p (text token)
  "TEXT 是否包含 TOKEN（字面匹配）。"
  (and (string-match-p (regexp-quote token) text) t))

;;; 1. 空清单

(ert-deftest ebasecamp-ui-test-empty-manifest ()
  "清单无项目时渲染空态文案，不挂载 tabs / 表格。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (let ((text (ebasecamp-ui-test--buffer-text)))
        (should (ebasecamp-ui-test--contains-p text "还没有 ebasecamp 清单"))
        (should-not (ebasecamp-ui-test--contains-p text "刷新"))
        (should-not (ebasecamp-ui-test--contains-p text "服务"))))))

;;; 2. 渲染数据（C0 骨架：组为中心，不依赖项目）

(ert-deftest ebasecamp-ui-test-build-state-lists-groups-without-projects ()
  "只定义组、不定义项目时，state 仍列出全部组且 config-count 正确。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-define-group mysql
      :scope per-project
      :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306))))
      :configs ((dev :project later)      ; 项目尚未定义
                (prod :project later)))
    (ebasecamp-define-group cache
      :scope shared
      :services ((redis :image "redis:7")))
    (let* ((state (ebasecamp-ui--build-state))
           (groups (plist-get state :groups)))
      (should (equal '("mysql" "cache")
                     (mapcar (lambda (group) (plist-get group :name)) groups)))
      (should (equal 2 (plist-get (car groups) :config-count)))
      (should (equal 0 (plist-get (cadr groups) :config-count)))
      (should (equal "2 组 · 2 配置" (plist-get state :summary)))
      (should-not (plist-get state :empty-p))
      ;; 组的存在与项目无关：config 指向的项目未定义时 :project 仍有值
      (should (equal "later"
                     (plist-get (car (plist-get (car groups) :configs))
                                :project))))))

(ert-deftest ebasecamp-ui-test-build-state-includes-configs ()
  "组有 2 份配置时 state 的 :configs 两项，且带 :project 与项目标题。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--configs-manifest)
    (let* ((state (ebasecamp-ui--build-state))
           (group (car (plist-get state :groups)))
           (configs (plist-get group :configs)))
      (should (equal "mysql" (plist-get group :name)))
      (should (equal "per-project" (plist-get group :scope)))
      (should (equal 2 (plist-get group :config-count)))
      (should (equal '("dev" "prod")
                     (mapcar (lambda (config) (plist-get config :name))
                             configs)))
      (should (equal '("myapp" "myapp")
                     (mapcar (lambda (config) (plist-get config :project))
                             configs)))
      (should (equal '("示例项目" "示例项目")
                     (mapcar (lambda (config)
                               (plist-get config :project-title))
                             configs)))
      ;; 配置的 scope 恒等于组定义（D9）
      (should (equal '("per-project" "per-project")
                     (mapcar (lambda (config) (plist-get config :scope))
                             configs))))))

(ert-deftest ebasecamp-ui-test-build-state-empty ()
  "无任何组时 `:empty-p' 为 t、groups 为空、summary 为 0 组 0 配置。"
  (ebasecamp-ui-test--with-ui
    (let ((state (ebasecamp-ui--build-state)))
      (should (plist-get state :empty-p))
      (should-not (plist-get state :groups))
      (should (equal "0 组 · 0 配置" (plist-get state :summary))))))

;;; 3. 骨架渲染

(ert-deftest ebasecamp-ui-test-render-skeleton ()
  "batch 挂载后 buffer 含组名、配置名、「刷新」与右侧占位文案。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-define-group mysql
      :scope per-project
      :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306))))
      :configs ((dev :project myapp)))
    (ebasecamp-define-project myapp :title "示例项目" :groups nil)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (let ((text (ebasecamp-ui-test--buffer-text)))
        (should (ebasecamp-ui-test--contains-p text "mysql"))
        (should (ebasecamp-ui-test--contains-p text "dev"))
        (should (ebasecamp-ui-test--contains-p text "刷新"))
        (should (ebasecamp-ui-test--contains-p text "选择左侧的组"))
        ;; 顶栏统计文案来自 state
        (should (ebasecamp-ui-test--contains-p text "1 组 · 1 配置"))))))

(ert-deftest ebasecamp-ui-test-select-key-selects-group ()
  "选组 / 选配置节点都写 selected-group，并同步 state 的 :selected。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--configs-manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (let ((session (ebasecamp-ui-session)))
        (should-not (etaf-value (ebasecamp-ui-session-selected-group session)))
        (ebasecamp-ui--select-key session "group/mysql")
        (should (eq 'mysql (etaf-value (ebasecamp-ui-session-selected-group
                                        session))))
        (should (equal "mysql"
                       (plist-get (etaf-value (ebasecamp-ui-session-state
                                               session))
                                  :selected)))
        ;; 配置节点归一为它所属的组
        (ebasecamp-ui--select-key session "config/mysql/prod")
        (should (eq 'mysql (etaf-value (ebasecamp-ui-session-selected-group
                                        session))))
        (should (equal "mysql"
                       (plist-get (etaf-value (ebasecamp-ui-session-state
                                               session))
                                  :selected)))))))

(ert-deftest ebasecamp-ui-test-mount-collects-status-once ()
  "on-mounted 只经 `ebasecamp-status-start' 采一次快照，不重复跑 docker ps。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((calls 0))
      (cl-letf (((symbol-function 'ebasecamp-docker-ps)
                 (lambda ()
                   (cl-incf calls)
                   nil)))
        (ebasecamp-ui-open)
        (should (= 1 calls))
        (should (ebasecamp-status-running-p))))))

;;; 4. 文案映射（纯函数）

(ert-deftest ebasecamp-ui-test-state-label ()
  "state 文案映射：running/exited/stopped/created/paused/nil/其他。"
  (should (equal "RUNNING" (ebasecamp-ui--state-label "running")))
  (should (equal "RUNNING" (ebasecamp-ui--state-label "RUNNING")))
  (should (equal "STOPPED" (ebasecamp-ui--state-label "exited")))
  (should (equal "STOPPED" (ebasecamp-ui--state-label "stopped")))
  (should (equal "STOPPED" (ebasecamp-ui--state-label nil)))
  (should (equal "CREATED" (ebasecamp-ui--state-label "created")))
  (should (equal "PAUSED" (ebasecamp-ui--state-label "paused")))
  (should (equal "RESTARTING" (ebasecamp-ui--state-label "restarting"))))

(ert-deftest ebasecamp-ui-test-health-label ()
  "health 文案映射：nil/healthy/unhealthy/starting/其他。"
  (should (equal "-" (ebasecamp-ui--health-label nil)))
  (should (equal "-" (ebasecamp-ui--health-label "")))
  (should (equal "OK" (ebasecamp-ui--health-label "healthy")))
  (should (equal "BAD" (ebasecamp-ui--health-label "unhealthy")))
  (should (equal "STARTING" (ebasecamp-ui--health-label "starting")))
  (should (equal "WEIRD" (ebasecamp-ui--health-label "weird"))))

;;; 5. 当前项目（导入 / 导出入口的兼容层）

(ert-deftest ebasecamp-ui-test-current-project-compat-shim ()
  "兼容层：无会话 → nil；会话存在时回退清单第一个项目；选中组带配置时取其
配置的 :project。导出入口（C5 前不再改动）依赖这一行为。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--configs-manifest)
    (ebasecamp-define-group cache
      :scope shared
      :services ((redis :image "redis:7"))
      :configs ((dev :project other)))
    (ebasecamp-define-project other :groups nil)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      ;; 无选中 → 清单第一个项目（等价旧实现的默认项目）
      (should (eq 'myapp (ebasecamp-ui-current-project)))
      ;; 选中组有配置 → 取该配置的项目
      (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/cache")
      (should (eq 'other (ebasecamp-ui-current-project)))
      ;; 会话销毁后回到 nil
      (ebasecamp-ui-close)
      (should-not (ebasecamp-ui-current-project)))))

;;; 6. 选中状态

(ert-deftest ebasecamp-ui-test-selected-keys ()
  "selected-keys 初始为空；toggle 后包含对应 key，再 toggle 清空。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (should (null (ebasecamp-ui-selected-keys)))
      (let ((session (ebasecamp-ui-session))
            (key "myapp/mysql/mysql"))
        (ebasecamp-ui--toggle-selected session key t)
        (should (ebasecamp-ui--selected-p session key))
        (should (equal (list key) (ebasecamp-ui-selected-keys)))
        (ebasecamp-ui--toggle-selected session "myapp/mysql/mysql-ro" t)
        (should (equal 2 (length (ebasecamp-ui-selected-keys))))
        (ebasecamp-ui--toggle-selected session key nil)
        (should-not (ebasecamp-ui--selected-p session key))
        (should (equal '("myapp/mysql/mysql-ro")
                       (ebasecamp-ui-selected-keys)))))))

;;; 7. 关闭

(ert-deftest ebasecamp-ui-test-close-stops-polling ()
  "close 后 running-p 为 nil、buffer 消失、会话清空。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (should (ebasecamp-status-running-p))
      (should (get-buffer ebasecamp-ui-buffer-name))
      (ebasecamp-ui-close)
      (should-not (ebasecamp-status-running-p))
      (should-not (get-buffer ebasecamp-ui-buffer-name))
      (should-not ebasecamp-ui--session)
      (should-not (ebasecamp-ui-current-project))
      (should-not (ebasecamp-ui-selected-keys)))))

;;; 8. 动作派发与并发控制（函数层；骨架不渲染操作条，C5 恢复）

(defun ebasecamp-ui-test--select (keys)
  "把 KEYS（\"project/group/service\" 列表）全部勾选到当前会话里。"
  (let ((session (ebasecamp-ui-session)))
    (dolist (key keys)
      (ebasecamp-ui--toggle-selected session key t))))

(defun ebasecamp-ui-test--notice ()
  "返回当前会话的 notice 值。"
  (etaf-value (ebasecamp-ui-session-notice (ebasecamp-ui-session))))

(defun ebasecamp-ui-test--busy ()
  "返回当前会话的 busy 值。"
  (etaf-value (ebasecamp-ui-session-busy (ebasecamp-ui-session))))

(ert-deftest ebasecamp-ui-test-run-action-requires-selection ()
  "无选中服务时 start 被拒：不派发命令，notice 为 info。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (let ((called 0))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest _) (cl-incf called))))
          (should-not (ebasecamp-ui-run-action 'start))
          (should (= 0 called))
          (let ((notice (ebasecamp-ui-test--notice)))
            (should (eq 'info (plist-get notice :kind)))
            (should (equal "未选中服务" (plist-get notice :title)))
            (should (equal "请先勾选要操作的服务"
                           (plist-get notice :message)))))))))

(ert-deftest ebasecamp-ui-test-run-action-blocks-on-port-conflict ()
  "start 遇到 duplicate 端口冲突：不派发，notice 为 error 并汇总冲突。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (ebasecamp-ui-test--select '("myapp/mysql/mysql"))
      (let ((called 0))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest _) (cl-incf called)))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _)
                     (list (list :kind 'duplicate :port 3306
                                 :services '("mysql/mysql" "mysql/mysql-ro"))))))
          (should-not (ebasecamp-ui-run-action 'start))
          (should (= 0 called))
          (let ((notice (ebasecamp-ui-test--notice)))
            (should (eq 'error (plist-get notice :kind)))
            (should (equal "端口冲突" (plist-get notice :title)))
            (should (ebasecamp-ui-test--contains-p
                     (plist-get notice :message) "3306"))))))))

(ert-deftest ebasecamp-ui-test-run-action-dispatches-start ()
  "start 有选中且无冲突：派发一次，ACTION/项目/keys/on-complete 齐全。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (ebasecamp-ui-test--select '("myapp/mysql/mysql"))
      (let ((calls nil))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest args) (push args calls)))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _) nil)))
          (should (ebasecamp-ui-run-action 'start))
          (should (= 1 (length calls)))
          (let ((args (car calls)))
            (should (eq 'start (nth 0 args)))
            (should (eq 'myapp (nth 1 args)))
            (should (equal '("mysql/mysql") (nth 2 args)))
            (should (functionp (plist-get (nthcdr 3 args) :on-complete)))))))))

(ert-deftest ebasecamp-ui-test-run-action-stop-skips-conflict-check ()
  "stop 直接派发且不调用端口冲突检测。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (ebasecamp-ui-test--select '("myapp/mysql/mysql-ro"))
      (let ((calls nil)
            (conflict-called 0))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest args) (push args calls)))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _)
                     (cl-incf conflict-called)
                     nil)))
          (should (ebasecamp-ui-run-action 'stop))
          (should (= 0 conflict-called))
          (should (= 1 (length calls)))
          (should (eq 'stop (nth 0 (car calls))))
          (should (equal '("mysql/mysql-ro") (nth 2 (car calls)))))))))

(ert-deftest ebasecamp-ui-test-run-action-down-needs-confirmation ()
  "down 先开确认框不派发；确认后以 keys=nil 派发 down。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (ebasecamp-ui-test--select '("myapp/mysql/mysql"))
      (let ((calls nil))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest args) (push args calls))))
          (should (ebasecamp-ui-run-action 'down))
          (should-not calls)
          (should (etaf-value (ebasecamp-ui-session-confirm
                               (ebasecamp-ui-session))))
          (should (eq 'down (ebasecamp-ui-session-confirm-action
                             (ebasecamp-ui-session))))
          (should (ebasecamp-ui-confirm))
          (should (= 1 (length calls)))
          (should (eq 'down (nth 0 (car calls))))
          (should (null (nth 2 (car calls))))
          (should-not (etaf-value (ebasecamp-ui-session-confirm
                                   (ebasecamp-ui-session))))
          (should-not (ebasecamp-ui-session-confirm-action
                       (ebasecamp-ui-session))))))))

(ert-deftest ebasecamp-ui-test-run-action-rejected-while-busy ()
  "busy 期间再次 run-action 返回 nil，且命令只派发一次。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (ebasecamp-ui-test--select '("myapp/mysql/mysql"))
      (let ((calls nil))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest args) (push args calls)))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _) nil)))
          (should (ebasecamp-ui-run-action 'start))
          (should (ebasecamp-ui-test--busy))
          (should-not (ebasecamp-ui-run-action 'start))
          (should (= 1 (length calls)))
          (let ((notice (ebasecamp-ui-test--notice)))
            (should (eq 'info (plist-get notice :kind)))
            (should (equal "操作进行中" (plist-get notice :title)))))))))

(ert-deftest ebasecamp-ui-test-on-complete-clears-busy ()
  "on-complete 回调把 busy 复位为 nil 并写 notice。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (ebasecamp-ui-test--select '("myapp/mysql/mysql"))
      (let ((complete nil))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest args)
                     (setq complete (plist-get (nthcdr 3 args) :on-complete))))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _) nil)))
          (should (ebasecamp-ui-run-action 'start))
          (should (ebasecamp-ui-test--busy))
          (funcall complete (list :action 'start :project 'myapp :ok t :results nil))
          (should-not (ebasecamp-ui-test--busy))
          (let ((notice (ebasecamp-ui-test--notice)))
            ;; T3.4 起成功提示的 kind 是 success（原先为 info）
            (should (eq 'success (plist-get notice :kind)))
            (should (ebasecamp-ui-test--contains-p
                     (plist-get notice :message) "完成"))))))))

;;; 9. 错误链路与操作反馈（T3.4）

(defun ebasecamp-ui-test--complete (session action result)
  "用 SESSION + ACTION 构造的 on-complete 回调处理 RESULT。"
  (funcall (ebasecamp-ui--on-complete session action) result))

(defun ebasecamp-ui-test--ok-result (&rest extra)
  "构造一个 `:ok' 为 t 的完成结果 plist，EXTRA 覆盖默认字段。"
  (append extra
          (list :action 'start :project 'myapp :ok t
                :results (list (list :scope 'project :exit 0 :stderr ""))
                :auto-started-shared nil)))

(defun ebasecamp-ui-test--failed-result (stderr)
  "构造一个失败结果 plist（单批次，STDERR 为 stderr 原文）。"
  (list :action 'start :project 'myapp :ok nil
        :results (list (list :scope 'project :exit 1 :stderr stderr :failed t))
        :auto-started-shared nil))

(ert-deftest ebasecamp-ui-test-on-complete-success-notice ()
  "成功完成 → notice kind 为 success，title 含动作名与「完成」。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((session (ebasecamp-ui-session)))
      (ebasecamp-ui-test--complete session 'start
                                   (ebasecamp-ui-test--ok-result))
      (let ((notice (etaf-value (ebasecamp-ui-session-notice session))))
        (should (eq 'success (plist-get notice :kind)))
        (should (equal "启动完成" (plist-get notice :title)))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :title) "完成"))))))

(ert-deftest ebasecamp-ui-test-on-complete-success-auto-shared ()
  "成功且 `:auto-started-shared' 为真 → message 提示已自动启动 shared 服务。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((session (ebasecamp-ui-session)))
      (ebasecamp-ui-test--complete
       session 'stop
       (ebasecamp-ui-test--ok-result :auto-started-shared t))
      (let ((notice (etaf-value (ebasecamp-ui-session-notice session))))
        (should (eq 'success (plist-get notice :kind)))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :message) "自动启动"))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :message) "shared"))))))

(ert-deftest ebasecamp-ui-test-on-complete-failure-notice ()
  "失败 → kind error，message 取 stderr 首行，detail 为 stderr 原文。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((session (ebasecamp-ui-session)))
      (ebasecamp-ui-test--complete
       session 'restart
       (ebasecamp-ui-test--failed-result "\nboom\nmore detail\n"))
      (let ((notice (etaf-value (ebasecamp-ui-session-notice session))))
        (should (eq 'error (plist-get notice :kind)))
        (should (equal "重启失败" (plist-get notice :title)))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :message) "boom"))
        (should-not (ebasecamp-ui-test--contains-p
                     (plist-get notice :message) "more detail"))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :detail) "boom"))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :detail) "more detail"))))))

(ert-deftest ebasecamp-ui-test-on-complete-permission-denied ()
  "stderr 含 permission denied（大小写不敏感）→ 专门的权限提示。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((session (ebasecamp-ui-session)))
      (ebasecamp-ui-test--complete
       session 'start
       (ebasecamp-ui-test--failed-result
        "permission denied while trying to connect to the Docker daemon socket"))
      (let ((notice (etaf-value (ebasecamp-ui-session-notice session))))
        (should (eq 'error (plist-get notice :kind)))
        (should (string-match-p "无权\\|权限" (plist-get notice :title)))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :message) "docker 组"))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :detail) "permission denied"))))))

(ert-deftest ebasecamp-ui-test-on-complete-failure-without-stderr ()
  "失败但无 stderr（例如批次被跳过）→ kind 为 error 且 message 非空。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((session (ebasecamp-ui-session)))
      (ebasecamp-ui-test--complete
       session 'down
       (list :action 'down :project 'myapp :ok nil
             :results (list (list :scope 'project :exit nil :stderr ""
                                  :skipped t))
             :auto-started-shared nil))
      (let ((notice (etaf-value (ebasecamp-ui-session-notice session))))
        (should (eq 'error (plist-get notice :kind)))
        (should (equal "销毁未完成" (plist-get notice :title)))
        (should (and (stringp (plist-get notice :message))
                     (not (string-empty-p (plist-get notice :message)))))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :message) "跳过"))))))

(ert-deftest ebasecamp-ui-test-notice-view-mounts-as-alert ()
  "notice 非 nil 时 `ebasecamp-ui--notice-view' 渲染 etaf-alert（含 title、
message 与 `:dismissible' 的关闭按钮）；notice 为空时退化为默认提示 label。
骨架不把 notice 放进主界面树（C5 恢复底栏），因此这里单独挂载该视图断言。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((session (ebasecamp-ui-session)))
      (ebasecamp-ui--set-notice session 'error "端口冲突" "3306 已被占用")
      (let ((text (ebasecamp-ui-test--mount-text
                   (ebasecamp-ui--notice-view session))))
        (should (ebasecamp-ui-test--contains-p text "端口冲突"))
        (should (ebasecamp-ui-test--contains-p text "3306 已被占用"))
        ;; `:dismissible' 的关闭按钮是 alert 独有（无 notice 时只有一行 label）
        (should (ebasecamp-ui-test--contains-p text "×"))
        (should-not (ebasecamp-ui-test--contains-p text ebasecamp-ui--hint)))
      (ebasecamp-ui--clear-notice session)
      (let ((text (ebasecamp-ui-test--mount-text
                   (ebasecamp-ui--notice-view session))))
        (should (ebasecamp-ui-test--contains-p text ebasecamp-ui--hint))
        (should-not (ebasecamp-ui-test--contains-p text "端口冲突"))))))

(ert-deftest ebasecamp-ui-test-notice-dismiss-clears ()
  "关闭按钮的回调（`ebasecamp-ui--clear-notice'）把 notice 置回 nil。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((session (ebasecamp-ui-session)))
      (ebasecamp-ui--set-notice session 'error "端口冲突" "3306 已被占用")
      (should (etaf-value (ebasecamp-ui-session-notice session)))
      (ebasecamp-ui--clear-notice session)
      (should-not (etaf-value (ebasecamp-ui-session-notice session))))))

(ert-deftest ebasecamp-ui-test-notice-timer-cancelled-on-close ()
  "成功 notice 会挂定时器；close 后定时器被取消，timer-list 回到基线。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let* ((session (ebasecamp-ui-session))
           (baseline (length timer-list)))
      (ebasecamp-ui-test--complete session 'start
                                   (ebasecamp-ui-test--ok-result))
      (should (> (length timer-list) baseline))
      (should (timerp (ebasecamp-ui-session-notice-timer session)))
      (ebasecamp-ui-close)
      (should (= baseline (length timer-list))))))

;;; 10. 导入 / 导出入口

(ert-deftest ebasecamp-ui-test-export-without-project ()
  "无当前项目时导出：返回 nil、notice 为 info、导出层未被调用。"
  (ebasecamp-ui-test--with-ui
    (let ((called 0))
      (cl-letf (((symbol-function 'ebasecamp-export-project)
                 (lambda (&rest _) (cl-incf called) "/tmp/never.yaml")))
        (should-not (ebasecamp-ui-export-compose))
        (should (= 0 called))
        (let ((notice (ebasecamp-ui-test--notice)))
          (should (eq 'info (plist-get notice :kind)))
          (should (ebasecamp-ui-test--contains-p
                   (plist-get notice :title) "项目")))))))

(ert-deftest ebasecamp-ui-test-export-success ()
  "导出成功：调用导出层且 FORCE 为 nil，notice 为 success 且 message 含路径。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((calls nil)
          (target "/tmp/ebc-export/docker-compose.ebasecamp.yaml"))
      (cl-letf (((symbol-function 'ebasecamp-export-project)
                 (lambda (project &rest keys)
                   (push (cons project keys) calls)
                   target)))
        (should (equal target (ebasecamp-ui-export-compose)))
        (should (= 1 (length calls)))
        (should (ebasecamp-project-p (car (car calls))))
        (should (eq 'myapp (ebasecamp-project-name (car (car calls)))))
        (should-not (plist-get (cdr (car calls)) :force))
        (let ((notice (ebasecamp-ui-test--notice)))
          (should (eq 'success (plist-get notice :kind)))
          (should (ebasecamp-ui-test--contains-p
                   (plist-get notice :message) target)))))))

(ert-deftest ebasecamp-ui-test-export-failure ()
  "导出层 signal `ebasecamp-export-error' 时：返回 nil、notice 为 error。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (cl-letf (((symbol-function 'ebasecamp-export-project)
               (lambda (&rest _)
                 (signal 'ebasecamp-export-error
                         (list "/tmp/x.yaml 已存在；覆盖需显式指定 :force")))))
      (should-not (ebasecamp-ui-export-compose))
      (let ((notice (ebasecamp-ui-test--notice)))
        (should (eq 'error (plist-get notice :kind)))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :message) "覆盖需显式指定"))
        (should (ebasecamp-ui-test--contains-p
                 (plist-get notice :title) "导出"))))))

(defmacro ebasecamp-ui-test--with-compose-file (&rest body)
  "在临时目录里创建一个 compose.yaml 并在 BODY 中执行。
BODY 内可用 `compose-file' 取该文件绝对路径。"
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "ebc-ui-compose-" t))
          (compose-file (expand-file-name "compose.yaml" dir)))
     (unwind-protect
         (progn
           (with-temp-file compose-file (insert "services: {}\n"))
           ,@body)
       (ignore-errors (delete-directory dir t)))))

(ert-deftest ebasecamp-ui-test-import-success ()
  "选中文件 + 确认名字：apply 收到 (FILE NAME) 并被调用一次，notice 为 success。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--with-compose-file
      (let ((target (ebasecamp-config-project-file "fake-e2e"))
            (calls nil))
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (&rest _) compose-file))
                  ((symbol-function 'read-string)
                   (lambda (&rest _) "fake-e2e"))
                  ((symbol-function 'ebasecamp-import-suggest-name)
                   (lambda (&rest _) 'suggested))
                  ((symbol-function 'ebasecamp-import-apply)
                   (lambda (&rest args) (push args calls) target)))
          (should (equal target (ebasecamp-ui-import-compose)))
          (should (= 1 (length calls)))
          (let ((args (car calls)))
            (should (equal compose-file (nth 0 args)))
            (should (equal "fake-e2e" (nth 1 args)))
            ;; 目标不存在 → 不要求 force
            (should-not (plist-get (nthcdr 2 args) :force)))
          (let ((notice (ebasecamp-ui-test--notice)))
            (should (eq 'success (plist-get notice :kind)))
            (should (ebasecamp-ui-test--contains-p
                     (plist-get notice :message) target))))))))

(ert-deftest ebasecamp-ui-test-import-cancelled ()
  "用户取消选文件（`read-file-name' 返回 nil）：返回 nil、无 notice、不落盘。"
  (ebasecamp-ui-test--with-ui
    (let ((called 0))
      (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) nil))
                ((symbol-function 'ebasecamp-import-apply)
                 (lambda (&rest _) (cl-incf called) "/tmp/never.el")))
        (should-not (ebasecamp-ui-import-compose))
        (should (= 0 called))
        (should-not (ebasecamp-ui-test--notice))))))

(ert-deftest ebasecamp-ui-test-import-failure ()
  "apply signal `ebasecamp-import-error' 时：notice 为 error，detail 非空。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--with-compose-file
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) compose-file))
                ((symbol-function 'read-string) (lambda (&rest _) "fake-e2e"))
                ((symbol-function 'ebasecamp-import-suggest-name)
                 (lambda (&rest _) 'fake-e2e))
                ((symbol-function 'ebasecamp-import-apply)
                 (lambda (&rest _)
                   (signal 'ebasecamp-import-error
                           (list "读取 /tmp/compose.yaml 失败（退出码 1）"
                                 "go-yaml load error: line 3")))))
        (should-not (ebasecamp-ui-import-compose))
        (let ((notice (ebasecamp-ui-test--notice)))
          (should (eq 'error (plist-get notice :kind)))
          (should (ebasecamp-ui-test--contains-p
                   (plist-get notice :message) "退出码 1"))
          (should (stringp (plist-get notice :detail)))
          (should-not (string-empty-p (plist-get notice :detail)))
          (should (ebasecamp-ui-test--contains-p
                   (plist-get notice :detail) "go-yaml load error")))))))

;;; 11. 配置段渲染（C3）

;; 右栏把选中组的每份配置渲染成一个 `etaf-panel' 段（段头 + 服务表）。这些
;; 用例不改动主界面 buffer：`ebasecamp-ui-view' 直接挂到临时 buffer 上取文本，
;; 因此不依赖 `etaf-set-value' 在 batch 下是否会重新 patch 已有 buffer。
;; 选中状态也先写进会话再挂载视图，避免依赖渲染时序。

(defun ebasecamp-ui-test--project-container (project group service state)
  "构造一个 per-project scope 的容器 plist（与 `ebasecamp-docker-ps' 产物一致）。"
  (list :id (format "id-%s-%s" project service)
        :names (format "%s-%s-1" project service)
        :image "mysql:8.4"
        :state state
        :health (and (equal state "running") "healthy")
        :ports "0.0.0.0:3306->3306/tcp"
        :labels (list (cons "ebasecamp.managed" "true")
                      (cons "ebasecamp.project" project)
                      (cons "ebasecamp.group" group)
                      (cons "ebasecamp.service" service)
                      (cons "ebasecamp.scope" "per-project"))
        :project project
        :group group
        :service service
        :scope "per-project"))

(defun ebasecamp-ui-test--section-manifest ()
  "定义 per-project 组 mysql（2 服务 / 2 份配置）与两个项目：
dev → myapp（服务全 running）、prod → other（mysql-ro 未启动）。"
  (ebasecamp-define-group mysql
    :title "MySQL"
    :scope per-project
    :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))
               (mysql-ro :image "mysql:8.4"))
    :configs ((dev :project myapp)
              (prod :project other)))
  (ebasecamp-define-project myapp :title "示例项目" :groups nil)
  (ebasecamp-define-project other :title "另一项目" :groups nil))

(defun ebasecamp-ui-test--section-containers ()
  "返回覆盖上述两组实例的容器列表：myapp 两个服务 running，other 只有 mysql。"
  (list (ebasecamp-ui-test--project-container "myapp" "mysql" "mysql" "running")
        (ebasecamp-ui-test--project-container "myapp" "mysql" "mysql-ro"
                                             "running")
        (ebasecamp-ui-test--project-container "other" "mysql" "mysql"
                                             "running")))

(defun ebasecamp-ui-test--main-text ()
  "把主界面视图挂到临时 buffer 并返回纯文本（不动主界面 buffer）。"
  (ebasecamp-ui-test--mount-text (ebasecamp-ui-view)))

(defun ebasecamp-ui-test--render (&optional group-key)
  "建会话、(可选) 选中 GROUP-KEY、按最近快照重建 state，返回 (STATE . TEXT)。"
  (let ((session (ebasecamp-ui-session)))
    (when group-key
      (ebasecamp-ui--select-key session group-key))
    (ebasecamp-ui-refresh (ebasecamp-status-last-records) t)
    (cons (etaf-value (ebasecamp-ui-session-state session))
          (ebasecamp-ui-test--main-text))))

(ert-deftest ebasecamp-ui-test-build-state-includes-instances-and-counts ()
  "每组的 :instances 来自 group-instances，计数逐级汇总且每组只装配一次。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (ebasecamp-status-snapshot)
      (let* ((state (ebasecamp-ui--build-state))
             (group (car (plist-get state :groups)))
             (instances (plist-get group :instances))
             (first (car instances))
             (second (cadr instances)))
        (should (equal '("dev" "prod")
                       (mapcar (lambda (instance) (plist-get instance :config))
                               instances)))
        ;; dev 2/2 running，prod 1/2（mysql-ro 未启动）
        (should (equal '(2 1)
                       (mapcar (lambda (instance) (plist-get instance :running))
                               instances)))
        (should (equal '(2 2)
                       (mapcar (lambda (instance) (plist-get instance :total))
                               instances)))
        (should (equal 3 (plist-get group :running)))
        (should (equal 4 (plist-get group :total)))
        (should (equal "myapp" (plist-get first :project)))
        (should (equal "示例项目" (plist-get first :project-title)))
        (should (equal "per-project" (plist-get first :scope)))
        (should (equal 2 (length (plist-get first :records))))
        (should (equal "other" (plist-get second :project)))
        ;; 树节点文案：组 \"标题  (N 配置 · R/T running)\"，配置 \"dev → 项目  (R/T)\"
        (should (equal "MySQL  (2 配置 · 3/4 running)"
                       (ebasecamp-ui--group-caption group)))
        (should (equal "dev → 示例项目  (2/2)"
                       (ebasecamp-ui--config-caption
                        (car (plist-get group :configs)))))
        ;; 配置项也带计数：树的配置节点文案用
        (should (equal '(2 1)
                       (mapcar (lambda (config) (plist-get config :running))
                               (plist-get group :configs))))
        (should (equal '(2 2)
                       (mapcar (lambda (config) (plist-get config :total))
                               (plist-get group :configs))))
        ;; 一次 build-state 内每组只调一次 group-instances
        (let ((original (symbol-function 'ebasecamp-data-group-instances))
              (calls 0))
          (cl-letf (((symbol-function 'ebasecamp-data-group-instances)
                     (lambda (group)
                       (cl-incf calls)
                       (funcall original group))))
            (ebasecamp-ui--build-state)
            (should (= 1 calls))))))))

(ert-deftest ebasecamp-ui-test-render-sections-for-selected-group ()
  "选中组后右栏渲染每份配置一个段：段头（配置 → 项目 + 计数）+ 服务表行。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((text (cdr (ebasecamp-ui-test--render "group/mysql"))))
        (should (ebasecamp-ui-test--contains-p text "dev → 示例项目"))
        (should (ebasecamp-ui-test--contains-p text "prod → 另一项目"))
        (should (ebasecamp-ui-test--contains-p text "mysql-ro"))
        (should (ebasecamp-ui-test--contains-p text "RUNNING"))
        (should (ebasecamp-ui-test--contains-p text "STOPPED"))
        (should (ebasecamp-ui-test--contains-p text "2/2"))
        (should (ebasecamp-ui-test--contains-p text "1/2"))
        (should (ebasecamp-ui-test--contains-p text "启动选中"))
        (should (ebasecamp-ui-test--contains-p text "停止选中"))
        (should (ebasecamp-ui-test--contains-p text "重启选中"))
        (should (ebasecamp-ui-test--contains-p text "健康"))
        (should-not (ebasecamp-ui-test--contains-p text "选择左侧的组"))
        (should-not (ebasecamp-ui-test--contains-p text "尚未关联任何项目"))))))

(ert-deftest ebasecamp-ui-test-render-empty-configs-placeholder ()
  "组无配置：右栏含「尚未关联任何项目」并列出组定义的服务名（只读）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-define-group cache
      :title "Cache"
      :scope shared
      :services ((redis :image "redis:7")
                 (redis-ro :image "redis:7")))
    (ebasecamp-ui-test--with-ps nil
      (let ((text (cdr (ebasecamp-ui-test--render "group/cache"))))
        (should (ebasecamp-ui-test--contains-p text "尚未关联任何项目"))
        (should (ebasecamp-ui-test--contains-p text "只读"))
        (should (ebasecamp-ui-test--contains-p text "redis-ro"))
        (should-not (ebasecamp-ui-test--contains-p text "选择左侧的组"))))))

(ert-deftest ebasecamp-ui-test-render-no-selected-group-shows-placeholder ()
  "未选中组：右栏保持「选择左侧的组」占位，不渲染段与按钮。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((text (cdr (ebasecamp-ui-test--render))))
        (should (ebasecamp-ui-test--contains-p text "选择左侧的组"))
        (should-not (ebasecamp-ui-test--contains-p text "启动选中"))))))

(ert-deftest ebasecamp-ui-test-render-checkbox-writes-selection ()
  "服务行的 checkbox 用段内 key（\"组/服务\"）写回选中集合。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (let* ((session (ebasecamp-ui-session))
           (record (car (plist-get (car (ebasecamp-data-group-instances 'mysql))
                                   :records)))
           (key (ebasecamp-ui--instance-key "mysql" record))
           (cell (plist-get (car (ebasecamp-ui--columns session "mysql"))
                            :cell)))
      (should (equal "mysql/mysql" key))
      (should (ebasecamp-ui-test--contains-p
               (ebasecamp-ui-test--mount-text (funcall cell record)) "[ ]"))
      (ebasecamp-ui--toggle-selected session key t)
      (should (member key (ebasecamp-ui-selected-keys)))
      (should (ebasecamp-ui-test--contains-p
               (ebasecamp-ui-test--mount-text (funcall cell record)) "[x]"))
      (ebasecamp-ui--toggle-selected session key nil)
      (should-not (member key (ebasecamp-ui-selected-keys))))))

(ert-deftest ebasecamp-ui-test-header-buttons-disabled-when-busy ()
  "段头的三个生命周期按钮把 busy ref 的当前值传给 `:disabled'。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let* ((session (ebasecamp-ui-session))
             (_state (progn (ebasecamp-ui-refresh
                             (ebasecamp-status-last-records) t)
                            nil))
             (group (car (plist-get
                          (etaf-value (ebasecamp-ui-session-state session))
                          :groups)))
             (instance (car (plist-get group :instances))))
        (should-not (ebasecamp-ui--busy-p session))
        (cl-labels ((capture ()
                      (let (seen)
                        ;; C4 起 `--section-button' 多收一个 INSTANCE 参数
                        ;; （按钮要把实例带进派发），这里记录 disabled 与实例
                        (cl-letf (((symbol-function
                                    'ebasecamp-ui--section-button)
                                   (lambda (label action variant inst disabled)
                                     (push (list label action disabled inst) seen)
                                     (etaf-view (etaf-label :text label)))))
                          (ebasecamp-ui-test--mount-text
                           (ebasecamp-ui--instance-section
                            session "mysql" instance))
                          (reverse seen)))))
          (let ((seen (capture)))
            (should (equal '("启动选中" "停止选中" "重启选中")
                           (mapcar #'car seen)))
            (should (equal '(nil nil nil)
                           (mapcar (lambda (entry) (nth 2 entry)) seen))))
          (etaf-set-value (ebasecamp-ui-session-busy session) t)
          (should (ebasecamp-ui--busy-p session))
          (let ((seen (capture)))
            (should (equal '(t t t)
                           (mapcar (lambda (entry) (nth 2 entry)) seen)))))
        ;; 不替换按钮实现时，段头文案里三个按钮都在
        (let ((text (ebasecamp-ui-test--mount-text
                     (ebasecamp-ui--instance-section session "mysql" instance))))
          (should (ebasecamp-ui-test--contains-p text "启动选中"))
          (should (ebasecamp-ui-test--contains-p text "停止选中"))
          (should (ebasecamp-ui-test--contains-p text "重启选中")))))))

;;; 12. 段内派发（C4）

;; 段内按钮把「当前选中集合」派发到该段自己那份配置的项目上。这些用例全部
;; 打桩 `ebasecamp-command-run'（真 docker 一次都不跑）与
;; `ebasecamp-command-port-conflicts'，只断言调用参数与会话状态（busy / notice）。

(defun ebasecamp-ui-test--instances (&optional group-key)
  "建会话、选中 GROUP-KEY（默认 \"group/mysql\"）、刷新 state，返回该组实例列表。
实例来自 state 的 `:instances'（与渲染期同一份数据），因此 project 字段与
实际段头显示的一致。"
  (let ((session (ebasecamp-ui-session)))
    (ebasecamp-ui--select-key session (or group-key "group/mysql"))
    (ebasecamp-ui-refresh nil t)
    (plist-get (car (plist-get (etaf-value (ebasecamp-ui-session-state session))
                              :groups))
               :instances)))

(defun ebasecamp-ui-test--reset-busy ()
  "把当前会话的 busy 复位为 nil（等价于命令完成回调做的事）。"
  (etaf-set-value (ebasecamp-ui-session-busy (ebasecamp-ui-session)) nil))

(ert-deftest ebasecamp-ui-test-section-action-dispatches-with-instance-project ()
  "段内「启动选中」把 ACTION / 实例项目 / 选中 keys 传给命令层。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let* ((instance (car (ebasecamp-ui-test--instances)))
             (calls nil))
        (ebasecamp-ui-test--select '("mysql/mysql" "mysql/mysql-ro"))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest args) (push args calls)))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _) nil)))
          (should (ebasecamp-ui--section-action 'start instance))
          (should (= 1 (length calls)))
          (let* ((args (car calls))
                 (keys (nth 2 args)))
            (should (eq 'start (nth 0 args)))
            (should (equal "myapp" (nth 1 args)))
            (should (equal 2 (length keys)))
            (should (member "mysql/mysql" keys))
            (should (member "mysql/mysql-ro" keys))
            (should (functionp (plist-get (nthcdr 3 args) :on-complete))))
          (should (ebasecamp-ui-test--busy)))))))

(ert-deftest ebasecamp-ui-test-section-action-uses-own-project-per-instance ()
  "同组两份配置（myapp / other）各派发到自己的项目，不串段。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let* ((instances (ebasecamp-ui-test--instances))
             (dev (car instances))
             (prod (cadr instances))
             (projects nil))
        (ebasecamp-ui-test--select '("mysql/mysql"))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (_action project _keys &rest _)
                     (push project projects)))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _) nil)))
          (should (ebasecamp-ui--section-action 'start dev))
          (ebasecamp-ui-test--reset-busy)
          (should (ebasecamp-ui--section-action 'start prod))
          (should (equal '("myapp" "other") (reverse projects)))
          (should (equal "myapp" (plist-get dev :project)))
          (should (equal "other" (plist-get prod :project))))))))

(ert-deftest ebasecamp-ui-test-section-action-rejects-when-busy ()
  "busy 为真时段内派发被拒：不调用命令层，notice 为「操作进行中」。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let* ((instance (car (ebasecamp-ui-test--instances)))
             (called 0))
        (ebasecamp-ui-test--select '("mysql/mysql"))
        (etaf-set-value (ebasecamp-ui-session-busy (ebasecamp-ui-session)) t)
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest _) (cl-incf called))))
          (should-not (ebasecamp-ui--section-action 'start instance))
          (should (= 0 called))
          (let ((notice (ebasecamp-ui-test--notice)))
            (should (eq 'info (plist-get notice :kind)))
            (should (equal "操作进行中" (plist-get notice :title)))
            (should (equal "请等待当前命令完成"
                           (plist-get notice :message)))))))))

(ert-deftest ebasecamp-ui-test-section-action-rejects-empty-selection ()
  "未勾选服务时段内派发被拒：不派发并提示先勾选服务。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let* ((instance (car (ebasecamp-ui-test--instances)))
             (called 0))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest _) (cl-incf called))))
          (should-not (ebasecamp-ui--section-action 'start instance))
          (should (= 0 called))
          (let ((notice (ebasecamp-ui-test--notice)))
            (should (eq 'info (plist-get notice :kind)))
            (should (equal "未选中服务" (plist-get notice :title)))
            ;; 标题与正文其一含「请先勾选」，兼容后续文案微调
            (should (ebasecamp-ui-test--contains-p
                     (format "%s%s" (plist-get notice :title)
                             (plist-get notice :message))
                     "请先勾选"))))))))

(ert-deftest ebasecamp-ui-test-section-action-blocks-on-port-conflict ()
  "start 遇到阻塞类端口冲突（duplicate）：不派发，notice 为 error + 摘要。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let* ((instance (car (ebasecamp-ui-test--instances)))
             (called 0)
             (conflicts nil))
        (ebasecamp-ui-test--select '("mysql/mysql" "mysql/mysql-ro"))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest _) (cl-incf called)))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (project keys)
                     (setq conflicts (list project keys))
                     (list (list :kind 'duplicate :port 3306
                                 :services '("mysql/mysql" "mysql/mysql-ro"))))))
          (should-not (ebasecamp-ui--section-action 'start instance))
          (should (= 0 called))
          ;; 冲突检测用的是该段项目 + 当前选中 keys
          (should (equal "myapp" (nth 0 conflicts)))
          (should (equal 2 (length (nth 1 conflicts))))
          (let ((notice (ebasecamp-ui-test--notice)))
            (should (eq 'error (plist-get notice :kind)))
            (should (equal "端口冲突" (plist-get notice :title)))
            (should (ebasecamp-ui-test--contains-p
                     (plist-get notice :message) "3306"))))))))

(ert-deftest ebasecamp-ui-test-section-action-allows-soft-conflict ()
  "start 遇到软冲突（unknown）：仍派发，notice 为 info「端口提示」。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let* ((instance (car (ebasecamp-ui-test--instances)))
             (calls 0))
        (ebasecamp-ui-test--select '("mysql/mysql"))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest _) (cl-incf calls)))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _)
                     (list (list :kind 'unknown :port 3306
                                 :service "mysql/mysql"
                                 :hint "端口探测不可用，已跳过")))))
          (should (ebasecamp-ui--section-action 'start instance))
          (should (= 1 calls))
          (let ((notice (ebasecamp-ui-test--notice)))
            (should (eq 'info (plist-get notice :kind)))
            (should (equal "端口提示" (plist-get notice :title)))
            (should (ebasecamp-ui-test--contains-p
                     (plist-get notice :message) "3306"))))))))

(ert-deftest ebasecamp-ui-test-section-action-double-click-dispatches-once ()
  "连续两次段内派发只派发一次（第一次置 busy，第二次被挡）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let* ((instance (car (ebasecamp-ui-test--instances)))
             (calls 0))
        (ebasecamp-ui-test--select '("mysql/mysql"))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest _) (cl-incf calls)))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _) nil)))
          (should (ebasecamp-ui--section-action 'start instance))
          (should-not (ebasecamp-ui--section-action 'start instance))
          (should (= 1 calls)))))))

(ert-deftest ebasecamp-ui-test-section-action-resets-busy-on-dispatch-error ()
  "命令层 signal `ebasecamp-command-busy' 时 busy 复位为 nil 并写 notice。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((instance (car (ebasecamp-ui-test--instances))))
        (ebasecamp-ui-test--select '("mysql/mysql"))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest _)
                     (signal 'ebasecamp-command-busy
                             (list "项目 myapp 已有命令在执行"))))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _) nil)))
          (should-not (ebasecamp-ui--section-action 'start instance))
          (should-not (ebasecamp-ui-test--busy))
          (let ((notice (ebasecamp-ui-test--notice)))
            (should (eq 'error (plist-get notice :kind)))
            (should (equal "命令派发失败" (plist-get notice :title)))
            (should (ebasecamp-ui-test--contains-p
                     (plist-get notice :message) "已有命令在执行"))))))))

(provide 'ebasecamp-ui-tests)
;;; ebasecamp-ui-tests.el ends here
