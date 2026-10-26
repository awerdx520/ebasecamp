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
(require 'ebasecamp)

;;; 测试脚手架

(defmacro ebasecamp-ui-test--with-ui (&rest body)
  "在临时清单目录 + 清空模型注册表中执行 BODY，结束后关闭界面并清理。
`ebasecamp-cache-directory' 也绑定到临时目录：W 批次起界面关闭时会写
`ui-state.el'（左栏宽度），不隔离会把测试产生的状态落到用户真实缓存里，并让
各用例之间通过该文件相互影响（保存 0.3 的用例污染后续读默认值的用例）。"
  (declare (indent 0) (debug t))
  `(let ((ebasecamp-config-directory
          (file-name-as-directory (make-temp-file "ebasecamp-ui-test-" t)))
         (ebasecamp-cache-directory
          (file-name-as-directory (make-temp-file "ebasecamp-ui-cache-" t))))
     (ebasecamp-model-reset)
     (unwind-protect
         (progn ,@body)
       (ignore-errors (ebasecamp-ui-close))
       (ebasecamp-status-stop)
       (ebasecamp-model-reset)
       (ignore-errors (delete-directory ebasecamp-config-directory t))
       (ignore-errors (delete-directory ebasecamp-cache-directory t)))))

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

;;; 5.（已删除）当前项目兼容层
;;
;; C5 起导入 / 导出 / 销毁都改为「用 `completing-read' 显式选项目」，
;; `ebasecamp-ui-current-project' 兼容层已无调用点并删除，因此原第 5 节
;; `current-project-compat-shim' 用例同时删除（选项目语义由第 13 节覆盖）。

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
      (should-not (ebasecamp-ui-selected-keys)))))

;;; 8. 会话与派发（函数层）

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
          (should (ebasecamp-ui--dispatch
                   (ebasecamp-ui-session) 'start "myapp" '("mysql/mysql")))
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

;; C5 起导出改为「`completing-read' 选项目」（D5），不再依赖
;; `ebasecamp-ui-current-project' 兼容层；用例统一打桩 `completing-read'。

(ert-deftest ebasecamp-ui-test-export-success ()
  "导出成功：completing-read 选中的项目传给导出层且 FORCE 为 nil，
notice 为 success 且 message 含路径。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((calls nil)
          (target "/tmp/ebc-export/docker-compose.ebasecamp.yaml"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "myapp"))
                ((symbol-function 'ebasecamp-export-project)
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
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "myapp"))
              ((symbol-function 'ebasecamp-export-project)
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
                        ;; （按钮要把实例带进派发），这里记录 disabled 与实例；
                        ;; v0.6 起再多收一个**可选** KEY（按钮文案前置键提示），
                        ;; 替身因此放宽为 `&optional _key' —— 不写成 6 个必填参数，
                        ;; 否则 1.1 阶段（生产代码仍是 5 参调用）会引入计划外的
                        ;; `wrong-number-of-arguments' 红。
                        (cl-letf (((symbol-function
                                    'ebasecamp-ui--section-button)
                                   (lambda (label action variant inst disabled
                                            &optional _key)
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

(ert-deftest ebasecamp-ui-test-section-action-resets-busy-on-command-error ()
  "命令层 signal `ebasecamp-command-error' 时 busy 复位为 nil 并写 error notice。
命令层 busy（`ebasecamp-command-busy'）自 C5 起归为 info「操作进行中」，
由第 13 节的 `dispatch-busy-maps-to-info' 覆盖。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((instance (car (ebasecamp-ui-test--instances))))
        (ebasecamp-ui-test--select '("mysql/mysql"))
        (cl-letf (((symbol-function 'ebasecamp-command-run)
                   (lambda (&rest _)
                     (signal 'ebasecamp-command-error
                             (list "项目 myapp 没有 per-project 组的服务可 down"))))
                  ((symbol-function 'ebasecamp-command-port-conflicts)
                   (lambda (&rest _) nil)))
          (should-not (ebasecamp-ui--section-action 'start instance))
          (should-not (ebasecamp-ui-test--busy))
          (let ((notice (ebasecamp-ui-test--notice)))
            (should (eq 'error (plist-get notice :kind)))
            (should (equal "命令派发失败" (plist-get notice :title)))
            (should (ebasecamp-ui-test--contains-p
                     (plist-get notice :message) "没有 per-project"))))))))

;;; 13. 底栏、选项目导出与销毁确认（C5）

;; 底栏三个入口都不参与 `busy' 判定（不是生命周期动作）；导出与销毁都用
;; `completing-read' 显式选项目（D5），不再经过「当前项目」兼容层。销毁把
;; 待确认动作写成 `(down . 项目名)' 交给确认框，确认后才派发（keys 为 nil）。

(ert-deftest ebasecamp-ui-test-renders-footer-buttons ()
  "主界面底栏渲染「导入 compose」「导出 compose」「销毁环境」三个入口。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((text (cdr (ebasecamp-ui-test--render "group/mysql"))))
        (should (ebasecamp-ui-test--contains-p text "导入 compose"))
        (should (ebasecamp-ui-test--contains-p text "导出 compose"))
        (should (ebasecamp-ui-test--contains-p text "销毁环境"))))))

(ert-deftest ebasecamp-ui-test-export-without-projects-notices ()
  "清单无项目时导出：notice info「没有可用项目」，不调用导出层。"
  (ebasecamp-ui-test--with-ui
    (let ((called 0))
      (cl-letf (((symbol-function 'ebasecamp-export-project)
                 (lambda (&rest _) (cl-incf called) "/tmp/never.yaml")))
        (should-not (ebasecamp-ui-export-compose))
        (should (= 0 called))
        (let ((notice (ebasecamp-ui-test--notice)))
          (should (eq 'info (plist-get notice :kind)))
          (should (equal "没有可用项目" (plist-get notice :title)))
          (should-not (plist-get notice :detail)))))))

(ert-deftest ebasecamp-ui-test-export-selects-project-via-completing-read ()
  "completing-read 选到 \"myapp\" 时导出层收到 myapp 的项目对象。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (let ((prompt nil)
          (collection nil)
          (received nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (p coll &rest _)
                   (setq prompt p collection coll)
                   "myapp"))
                ((symbol-function 'ebasecamp-export-project)
                 (lambda (project &rest _)
                   (setq received project)
                   "/tmp/ebc-out.yaml")))
        (should (equal "/tmp/ebc-out.yaml" (ebasecamp-ui-export-compose)))
        (should (ebasecamp-project-p received))
        (should (eq 'myapp (ebasecamp-project-name received)))
        (should (ebasecamp-ui-test--contains-p prompt "导出项目"))
        ;; 候选集合是清单里的项目名（symbol-name 形态）
        (should (member "myapp" collection))
        (should (member "other" collection))
        (let ((notice (ebasecamp-ui-test--notice)))
          (should (eq 'success (plist-get notice :kind)))
          (should (equal "导出完成" (plist-get notice :title)))
          (should (ebasecamp-ui-test--contains-p
                   (plist-get notice :message) "/tmp/ebc-out.yaml")))))))

(ert-deftest ebasecamp-ui-test-export-cancel-is-silent ()
  "选项目时用户取消（`quit'）：返回 nil、无 notice、不调用导出层。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (let ((called 0))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (signal 'quit nil)))
                ((symbol-function 'ebasecamp-export-project)
                 (lambda (&rest _) (cl-incf called) "/tmp/never.yaml")))
        (should-not (ebasecamp-ui-export-compose))
        (should (= 0 called))
        (should-not (ebasecamp-ui-test--notice))))))

(ert-deftest ebasecamp-ui-test-destroy-requires-confirmation ()
  "销毁：选完项目只置 confirm ref 与 confirm-action，不派发命令。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (let ((called 0))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "myapp"))
                ((symbol-function 'ebasecamp-command-run)
                 (lambda (&rest _) (cl-incf called))))
        (should (ebasecamp-ui-destroy-environment))
        (should (= 0 called))
        (let ((session (ebasecamp-ui-session)))
          (should (etaf-value (ebasecamp-ui-session-confirm session)))
          (should (equal '(down . myapp)
                         (ebasecamp-ui-session-confirm-action session))))))))

(ert-deftest ebasecamp-ui-test-destroy-confirm-dispatches-down ()
  "确认销毁：command-run 收到 (down myapp nil)，confirm 状态清空。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (let ((calls nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "myapp"))
                ((symbol-function 'ebasecamp-command-run)
                 (lambda (&rest args) (push args calls))))
        (should (ebasecamp-ui-destroy-environment))
        (should (ebasecamp-ui-confirm))
        (should (= 1 (length calls)))
        (should (eq 'down (nth 0 (car calls))))
        (should (eq 'myapp (nth 1 (car calls))))
        (should (null (nth 2 (car calls))))
        (let ((session (ebasecamp-ui-session)))
          (should-not (etaf-value (ebasecamp-ui-session-confirm session)))
          (should-not (ebasecamp-ui-session-confirm-action session)))))))

(ert-deftest ebasecamp-ui-test-destroy-dialog-text-mentions-project ()
  "确认框文案点名项目，并说明不会删除卷、shared 组不受影响。
batch 下 `etaf-dialog' 走 root-layer 投影，内容不落 buffer（实测挂载后文本为空
串），因此断言文案函数本身 + 组件已注册（确认框确由该组件渲染）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (let ((session (ebasecamp-ui-session)))
      (setf (ebasecamp-ui-session-confirm-action session) '(down . myapp))
      (etaf-set-value (ebasecamp-ui-session-confirm session) t)
      (let ((message (ebasecamp-ui--confirm-message 'myapp)))
        (should (ebasecamp-ui-test--contains-p message "myapp"))
        (should (ebasecamp-ui-test--contains-p message "不会删除卷"))
        (should (ebasecamp-ui-test--contains-p message "shared")))
      ;; 确认框组件已注册（`etaf-node' / View 语法据此解析）
      (should (etaf--component-spec-p
               (gethash 'ebasecamp-ui-confirm-dialog etaf--view-registry))))))

(ert-deftest ebasecamp-ui-test-dispatch-busy-maps-to-info ()
  "命令层 busy（`ebasecamp-command-busy'）经段内路径：notice 为 info、busy 复位。
C4 的 `--section-dispatch' 曾把这种情况归为 error「命令派发失败」，C5 合并
两条派发路径后统一为 info「操作进行中」。"
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
            (should (eq 'info (plist-get notice :kind)))
            (should (equal "操作进行中" (plist-get notice :title)))
            (should (equal "请等待当前命令完成" (plist-get notice :message)))))))))

(ert-deftest ebasecamp-ui-test-dispatch-other-error-maps-to-error ()
  "其他错误：notice 为 error「命令派发失败」+ 消息，busy 复位。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (let ((session (ebasecamp-ui-session)))
      (cl-letf (((symbol-function 'ebasecamp-command-run)
                 (lambda (&rest _)
                   (signal 'ebasecamp-command-error
                           (list "shared 组不提供 down")))))
        (should-not (ebasecamp-ui--dispatch session 'down "myapp" nil))
        (should-not (ebasecamp-ui-test--busy))
        (let ((notice (ebasecamp-ui-test--notice)))
          (should (eq 'error (plist-get notice :kind)))
          (should (equal "命令派发失败" (plist-get notice :title)))
          (should (ebasecamp-ui-test--contains-p
                   (plist-get notice :message) "shared 组不提供 down")))))))

;;; 14. 刷新容错、展开保持与重开重建（C7 覆盖补齐）

(ert-deftest ebasecamp-ui-test-refresh-survives-snapshot-failure ()
  "snapshot 失败（docker 权限错误）时 refresh 不 signal，state 保持上次计数。
`ebasecamp-ui-refresh' 未收到记录时先跑 `ebasecamp-status-snapshot'；后者已把
错误消化进 `ebasecamp-status-last-error' 并保留 `last-records'，因此统计不清零、
也不把异常抛给轮询回调。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (ebasecamp-ui-open)
      (let ((before (ebasecamp-ui-refresh)))
        (should (equal 3 (plist-get (car (plist-get before :groups)) :running))))
      (cl-letf (((symbol-function 'ebasecamp-docker-ps)
                 (lambda () (error "permission denied"))))
        (should (ebasecamp-ui-refresh)))
      (should (ebasecamp-status-last-error))
      (let* ((state (etaf-value (ebasecamp-ui-session-state (ebasecamp-ui-session))))
             (group (car (plist-get state :groups))))
        (should (equal 3 (plist-get group :running)))
        (should (equal 4 (plist-get group :total)))))))

(ert-deftest ebasecamp-ui-test-expanded-persists-across-rerender ()
  "`on-toggle' 写入的 expanded 值在 state 重建后的再次渲染中保持（折叠生效）。
树的展开状态由会话的 expanded ref 持有：树回调只写该 ref，不参与 items 裁剪，
所以折叠后子节点不渲染、但 state 里的配置项仍然完整。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (let* ((session (ebasecamp-ui-session))
             (expanded (lambda ()
                         (etaf-value (ebasecamp-ui-session-expanded session)))))
        (should (equal '("group/mysql") (funcall expanded)))
        (should (ebasecamp-ui-test--contains-p
                 (ebasecamp-ui-test--buffer-text) "dev →"))
        (etaf-set-value (ebasecamp-ui-session-expanded session) nil)
        (ebasecamp-ui-refresh (ebasecamp-status-last-records) t)
        (should-not (funcall expanded))
        (let ((text (ebasecamp-ui-test--buffer-text)))
          (should (ebasecamp-ui-test--contains-p text "mysql"))
          (should-not (ebasecamp-ui-test--contains-p text "dev →")))
        (should (equal '("dev" "prod")
                       (mapcar (lambda (config) (plist-get config :name))
                               (plist-get
                                (car (plist-get
                                      (etaf-value
                                       (ebasecamp-ui-session-state session))
                                      :groups))
                                :configs))))))))

(ert-deftest ebasecamp-ui-test-reopen-rebuilds-session ()
  "close 后再次 open 重建会话：新会话对象、选择/提示/确认归零、buffer 重挂载。
`ebasecamp-ui-close' 把 `ebasecamp-ui--session' 置 nil 并 kill buffer，因此再次
open 走全新会话（不残留上一次的选中集合、提示与确认状态）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (let ((first (ebasecamp-ui-session)))
        (ebasecamp-ui--select-key first "group/mysql")
        (ebasecamp-ui--toggle-selected first "mysql/mysql" t)
        (ebasecamp-ui--set-notice first 'info "提示" "内容")
        (ebasecamp-ui-close)
        (should-not ebasecamp-ui--session)
        (ebasecamp-ui-open)
        (let ((second (ebasecamp-ui-session)))
          (should-not (eq first second))
          (should (get-buffer ebasecamp-ui-buffer-name))
          (should (ebasecamp-status-running-p))
          (should-not (etaf-value (ebasecamp-ui-session-selected-group second)))
          (should-not (ebasecamp-ui-selected-keys))
          (should-not (etaf-value (ebasecamp-ui-session-notice second)))
          (should-not (etaf-value (ebasecamp-ui-session-confirm second)))
          (should (equal '("group/mysql")
                         (etaf-value
                          (ebasecamp-ui-session-expanded second)))))))))

;;; 15. 旧写法可见性与迁移提示（C8）

;; v0.1 清单只在项目侧写 `:groups'。回退后组视图必须能看到这些关联（段 + 迁移
;; 提示 + 组节点文案），打开界面时还要用 `message' 报告计数，避免「命令失灵」。

(defun ebasecamp-ui-test--legacy-manifest ()
  "定义 v0.1 风格清单：两个组都没有 `:configs'，项目 example 用 `:groups' 引用。"
  (ebasecamp-define-group mysql
    :title "MySQL"
    :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))
               (mysql-ro :image "mysql:8.4")))
  (ebasecamp-define-group redis
    :services ((redis :image "redis:7" :ports ((6379 . 6379)))))
  (ebasecamp-define-project example
    :title "示例项目"
    :groups ((mysql) (redis))))

(defun ebasecamp-ui-test--capture-ebasecamp-messages (function)
  "调用 FUNCTION，返回其中以 \"ebasecamp\" 开头的 `message' 文案列表。"
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format-message format-string args) messages)
                 nil)))
      (funcall function))
    (nreverse (cl-remove-if-not
               (lambda (text) (string-prefix-p "ebasecamp" text))
               messages))))

(ert-deftest ebasecamp-ui-test-build-state-legacy-counts ()
  "旧写法清单：组 `:config-count' 为 0，`:instances' 非空且带 `:legacy'。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--legacy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let* ((state (ebasecamp-ui--build-state))
             (group (car (plist-get state :groups)))
             (instances (plist-get group :instances))
             (instance (car instances)))
        (should (equal "2 组 · 0 配置" (plist-get state :summary)))
        (should (equal 0 (plist-get group :config-count)))
        (should (null (plist-get group :configs)))
        (should (= 1 (length instances)))
        (should (eq t (plist-get instance :legacy)))
        (should (null (plist-get instance :config)))
        (should (equal "example" (plist-get instance :project)))
        (should (equal "示例项目" (plist-get instance :project-title)))
        (should (equal 2 (length (plist-get instance :records))))
        (should (equal '(0 2)
                       (list (plist-get instance :running)
                             (plist-get instance :total))))))))

(ert-deftest ebasecamp-ui-test-render-legacy-section-caption ()
  "旧写法实例的段头为「（旧写法）→ 项目」，并在组标题下给出迁移提示。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--legacy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-status-snapshot)
      (let* ((session (ebasecamp-ui-session)))
        (ebasecamp-ui--select-key session "group/mysql")
        (ebasecamp-ui-refresh (ebasecamp-status-last-records) t)
        (let ((text (ebasecamp-ui-test--main-text)))
          (should (ebasecamp-ui-test--contains-p text "（旧写法）→ 示例项目"))
          (should (ebasecamp-ui-test--contains-p text "建议改为 :configs"))
          (should (ebasecamp-ui-test--contains-p text "per-project"))
          (should (ebasecamp-ui-test--contains-p text "mysql-ro"))
          (should (ebasecamp-ui-test--contains-p text "启动选中")))))))

(ert-deftest ebasecamp-ui-test-render-group-label-legacy ()
  "组无配置但有旧写法关联 → 组节点文案为「(旧 · N 项目)」。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--legacy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-status-snapshot)
      (let* ((state (ebasecamp-ui--build-state))
             (group (car (plist-get state :groups)))
             (items (ebasecamp-ui--tree-items state))
             (text (ebasecamp-ui-test--main-text)))
        (should (equal "MySQL  (旧 · 1 项目)"
                       (ebasecamp-ui--group-caption group)))
        (should (equal "MySQL  (旧 · 1 项目)"
                       (plist-get (car items) :label)))
        ;; 树节点文案在 batch 下会被 etaf-tree 省略号截断（`*ebasecamp*` 实测
        ;; 只到 "MySQL  (旧"），故 buffer 断言放到「旧」这一段前缀，完整文案
        ;; 由上面两条 caption / items 断言保证。
        (should (ebasecamp-ui-test--contains-p text "MySQL  (旧"))))))

(ert-deftest ebasecamp-ui-test-open-messages-counts ()
  "交互调用 `ebasecamp-ui-open' 时用 `message' 报告组 / 配置 / 旧写法关联数。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--legacy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((messages (ebasecamp-ui-test--capture-ebasecamp-messages
                       (lambda () (call-interactively #'ebasecamp-ui-open)))))
        (should (= 1 (length messages)))
        (let ((text (car messages)))
          (should (ebasecamp-ui-test--contains-p text "2 组"))
          (should (ebasecamp-ui-test--contains-p text "0 配置"))
          (should (ebasecamp-ui-test--contains-p text "2 个旧写法关联")))))))

(ert-deftest ebasecamp-ui-test-command-shows-buffer-in-window ()
  "走 `M-x ebasecamp' 的真实路径（普通函数调用）时，主界面 buffer 必须显示在选中 window。
回归：`ebasecamp-ui-open' 曾把 `pop-to-buffer' 放进 `(when (called-interactively-p
'any) …)'，而 `ebasecamp' 是**普通函数调用**，`called-interactively-p' 不跨帧
传播、恒为 nil → buffer 被创建并挂载却永不显示（用户只看到一条 minibuffer 回执）。
因此这里刻意不用 `call-interactively'，直接调 `(ebasecamp)'。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--legacy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((before (length (window-list)))
            (buffer (ebasecamp)))
        (should (eq buffer (get-buffer ebasecamp-ui-buffer-name)))
        (should (get-buffer ebasecamp-ui-buffer-name))
        ;; batch 下同样有 terminal frame 与 window（实测 `get-buffer-window'
        ;; 返回 `#<window 1 on *ebasecamp*>），故可直接断言「显示在某窗口」；
        ;; 再断言选中 window 的 buffer 就是它，防止「显示在别处」蒙过。
        (should (get-buffer-window ebasecamp-ui-buffer-name))
        (should (eq (window-buffer (selected-window))
                    (get-buffer ebasecamp-ui-buffer-name)))
        ;; 「不动其它 window」：窗口数必须不变（`display-buffer-reuse-window'
        ;; 组合会在无可复用窗口时 split 出第二个窗口，实测过）。
        (should (= before (length (window-list))))))))

(ert-deftest ebasecamp-ui-test-open-does-not-duplicate-message ()
  "交互调用 `ebasecamp-ui-open' 时恰好 1 条 \"ebasecamp：\" 回执。
显示改为无条件发生（不再受 `called-interactively-p' 门控）后，回执仍只允许
一条：`M-x ebasecamp-ui-open' 由 open 自己发，`M-x ebasecamp' 由命令发。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--legacy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((messages (ebasecamp-ui-test--capture-ebasecamp-messages
                       (lambda () (call-interactively #'ebasecamp-ui-open)))))
        (should (= 1 (length messages)))
        (should (ebasecamp-ui-test--contains-p (car messages) "ebasecamp："))))))

(ert-deftest ebasecamp-ui-test-render-no-config-no-legacy-label ()
  "组既无配置也无旧写法关联 → 组节点文案为「(未关联)」。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-define-group mysql
      :title "MySQL"
      :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))))
    (ebasecamp-ui-test--with-ps nil
      (let* ((state (ebasecamp-ui--build-state))
             (group (car (plist-get state :groups))))
        (should (null (plist-get group :instances)))
        (should (equal "MySQL  (未关联)"
                       (ebasecamp-ui--group-caption group)))))))

;;; U1. buffer 身份与只读
;;
;; 界面的「写」能力必须被移除：buffer 用专用主模式（派生 `special-mode'）
;; 并只读，根 Host 声明 `:key-scope 'local' 使未绑定的 printing key 被吞掉。
;; 三条断言分别覆盖 mode / read-only、吞键效果（`i` 不再落入 self-insert）、
;; 以及键链最外层确实是 local 边界。

(ert-deftest ebasecamp-ui-test-open-sets-ui-mode-and-read-only ()
  "打开界面后 buffer 使用 `ebasecamp-ui-mode' 且 `buffer-read-only' 为 t。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
        (should (eq major-mode 'ebasecamp-ui-mode))
        (should buffer-read-only)))))

(ert-deftest ebasecamp-ui-test-ui-buffer-swallows-insert-key ()
  "根 Host 的 local 边界吞掉 `i'：绑定为 `ignore'，按下后文本不变且不报错。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
        (should (eq (etaf--keys-binding [?\i]) #'ignore))
        (let ((before (buffer-string)))
          (condition-case err
              (execute-kbd-macro (kbd "i"))
            (error (ert-fail (format "按 i 触发 signal：%S" err))))
          (should (equal before (buffer-string))))))))

(ert-deftest ebasecamp-ui-test-root-host-declares-local-scope ()
  "键链最外层（根 Host）满足 `etaf--keys-boundary-p'，即声明了 local 边界。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
        (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
               (chain (etaf--keys-chain runtime)))
          (should runtime)
          (should chain)
          (should (etaf--keys-boundary-p runtime (car (last chain)))))))))

;;; U2. 根级键位
;;
;; 根宿主用 `:keys' 声明全部根级键（`ebasecamp-ui--root-keys' 是单一事实源），
;; 每条必须带中文 LABEL（`etaf-help' 只展示有 LABEL 的条目）。
;; 本批次只覆盖 `q g n p I o D`：`e` 在 U5、`SPC` 在 U4 才实现，完整集合由
;; U6 的最终断言覆盖。注意 major-mode map 上的 printing key 会被 etaf runtime
;; 键层遮住（U1 实测 `(key-binding (kbd "q"))` = `ignore`），因此按键断言必须
;; 走 `etaf--keys-binding' 或 `execute-kbd-macro'，不能用 `key-binding'。

(defun ebasecamp-ui-test--three-groups-manifest ()
  "定义三个组（alpha / beta / gamma），供 `n' / `p' 的循环断言使用。
必须同时定义一个项目：`ebasecamp-ui-open' 在 `ebasecamp-model-projects' 为空时
会按 `ebasecamp-config-directory'（临时空目录）加载一次清单，把只定义了组的
注册表清空（实测：不定义项目时 `--next-group' 看到 0 个组）。"
  (ebasecamp-define-group alpha
    :scope shared
    :services ((alpha-svc :image "alpine:3")))
  (ebasecamp-define-group beta
    :scope shared
    :services ((beta-svc :image "alpine:3")))
  (ebasecamp-define-group gamma
    :scope shared
    :services ((gamma-svc :image "alpine:3")))
  (ebasecamp-define-project myapp :title "示例项目" :groups nil))

(defun ebasecamp-ui-test--selected-group ()
  "返回当前会话的 `selected-group' 值（symbol 或 nil）。"
  (etaf-value (ebasecamp-ui-session-selected-group (ebasecamp-ui-session))))

(ert-deftest ebasecamp-ui-test-root-keys-complete ()
  "`--root-keys' 的键集合恰为 q f g h j k l n p e t I o D 1 2 3 S E M X，每条带非空 LABEL 且能通过校验。
`SPC` 不在本表：它被 ebox 内建的激活键（`[32]`）占用，见
`spc-activates-checkbox'。
`e`（编辑清单）在 U5 加入，`t`（切换勾选）在 U4 加入，`1`/`2`/`3`（区域跳转）
在 N1 加入，`S`/`E`/`M`/`X`（写操作）在 W4 加入，`h`/`j`/`k`/`l`（vim 方向
导航）在 v0.6 批次 2 加入，`f`（avy 跳转）在 v0.6 批次 3 加入 —— 本用例守护
「当前阶段已有的键一个不少、一个不多」。"
  (ebasecamp-ui-test--with-ui
    (let ((keys (ebasecamp-ui--root-keys)))
      (should (equal '("1" "2" "3" "D" "E" "I" "M" "S" "X"
                       "e" "f" "g" "h" "j" "k" "l" "n" "o" "p" "q" "t")
                     (sort (mapcar (lambda (entry)
                                     (key-description (etaf--keys-event (car entry))))
                                   keys)
                           #'string<)))
      (dolist (entry keys)
        (should (stringp (nth 2 entry)))
        (should-not (string-empty-p (nth 2 entry))))
      ;; `etaf--keys-validate' 不 signal（返回 KEYS 本身）
      (should (equal keys (etaf--keys-validate keys))))))

(ert-deftest ebasecamp-ui-test-next-group-cycles ()
  "`n'（`--next-group'）在三个组之间顺序切换，末尾回绕；按键同样生效。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--three-groups-manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      ;; 起点：无选中组
      (etaf-set-value (ebasecamp-ui-session-selected-group (ebasecamp-ui-session)) nil)
      (should-not (ebasecamp-ui-test--selected-group))
      (ebasecamp-ui--next-group)
      (should (eq 'alpha (ebasecamp-ui-test--selected-group)))
      (ebasecamp-ui--next-group)
      (should (eq 'beta (ebasecamp-ui-test--selected-group)))
      (ebasecamp-ui--next-group)
      (should (eq 'gamma (ebasecamp-ui-test--selected-group)))
      (ebasecamp-ui--next-group)
      (should (eq 'alpha (ebasecamp-ui-test--selected-group)))
      ;; 按键断言：在界面 buffer 内按 `n' 同样推进选中组
      (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
        (let ((before (ebasecamp-ui-test--selected-group)))
          (execute-kbd-macro (kbd "n"))
          (should (eq 'beta (ebasecamp-ui-test--selected-group)))
          (should-not (eq before (ebasecamp-ui-test--selected-group))))))))

(ert-deftest ebasecamp-ui-test-previous-group-cycles ()
  "`p'（`--previous-group'）反向切换：无选中组时取最后一个，越界回绕。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--three-groups-manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (etaf-set-value (ebasecamp-ui-session-selected-group (ebasecamp-ui-session)) nil)
      (should-not (ebasecamp-ui-test--selected-group))
      (ebasecamp-ui--previous-group)
      (should (eq 'gamma (ebasecamp-ui-test--selected-group)))
      (ebasecamp-ui--previous-group)
      (should (eq 'beta (ebasecamp-ui-test--selected-group)))
      (ebasecamp-ui--previous-group)
      (should (eq 'alpha (ebasecamp-ui-test--selected-group)))
      (ebasecamp-ui--previous-group)
      (should (eq 'gamma (ebasecamp-ui-test--selected-group)))
      (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
        (let ((before (ebasecamp-ui-test--selected-group)))
          (execute-kbd-macro (kbd "p"))
          (should (eq 'beta (ebasecamp-ui-test--selected-group)))
          (should-not (eq before (ebasecamp-ui-test--selected-group))))))))

(ert-deftest ebasecamp-ui-test-reload-key-reloads ()
  "`g' 触发 `ebasecamp-reload'，且不额外调用一次 `ebasecamp-ui-refresh'。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
        (let ((reload-count 0)
              (refresh-count 0))
          (cl-letf (((symbol-function 'ebasecamp-reload)
                     (lambda ()
                       (cl-incf reload-count)
                       (list :groups nil :projects nil :errors nil)))
                    ((symbol-function 'ebasecamp-ui-refresh)
                     (lambda (&rest _args)
                       (cl-incf refresh-count)
                       nil)))
            ;; 绑定存在且不是被 local 边界吞掉的 `ignore'
            (let ((binding (etaf--keys-binding [?\g])))
              (should binding)
              (should-not (eq binding #'ignore)))
            (execute-kbd-macro (kbd "g"))
            (should (>= reload-count 1))
            ;; 界面刷新由 `ebasecamp-reload' 内部完成，不得二次刷新（会跑两次 docker ps）
            (should (= 0 refresh-count))))))))

(ert-deftest ebasecamp-ui-test-q-key-is-bound ()
  "`q' 进了根 Host 的 `:keys'：不再是 `ignore'（U1 阶段被 etaf 键层遮住）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
        (let ((binding (etaf--keys-binding [?\q])))
          (should binding)
          (should-not (eq binding #'ignore)))))))

;;; 14. 段级键位（U3）

;; 段级键 `s' / `x' / `r' / `a' / `A' 挂在「段」自己的 Host 上：命中范围由 point
;; 所在段决定（etaf 键链从 point/焦点所在 Host 向上找，遇 `:key-scope 'local'
;; 边界停止）。段级键的派发与段内按钮同源（`ebasecamp-ui--section-action'），
;; 因此同一实例、同一项目，不会串段。
;;
;; 注意两条实测事实（本文件其余用例同样适用）：
;; 1. `execute-kbd-macro' 在 batch 下于 **selected window 的 buffer** 执行，
;;    因此按键断言前必须用 `ebasecamp-ui-open' 显示界面 buffer（`with-current-buffer'
;;    只够读文本，不足以让按键落到界面 buffer）。
;; 2. 界面打开后默认没有选中组（右栏显示「选择左侧的组」），断言段内按键前要
;;    先选中组并等重渲染把段画出来。

(defun ebasecamp-ui-test--two-groups-manifest ()
  "定义两个 per-project 组（mysql：2 份配置 / 2 服务；redis：1 份配置 / 1 服务）。
两组服务名互不重叠，用于验证「段级全不选只影响该段」——同组多份配置的段共享
同一个 `组名/服务名' key（见 `ebasecamp-ui--instance-key' 的说明），无法区分。"
  (ebasecamp-define-group mysql
    :title "MySQL"
    :scope per-project
    :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))
               (mysql-ro :image "mysql:8.4"))
    :configs ((dev :project myapp)
              (prod :project other)))
  (ebasecamp-define-group redis
    :title "Redis"
    :scope per-project
    :services ((redis :image "redis:7"))
    :configs ((cache :project other)))
  (ebasecamp-define-project myapp :title "示例项目" :groups nil)
  (ebasecamp-define-project other :title "另一项目" :groups nil))

(defun ebasecamp-ui-test--goto-section (&optional index)
  "把 point 移到第 INDEX（默认 1）个配置段的段头行，返回 point。
定位锚点是段头第二行的按钮文案「启动选中」：段头第一行的 `dev → 项目' 文案在
左树里也有同名节点（`ebasecamp-ui--config-caption'），`search-forward \"dev →\"'
会先命中左树，键链因此落到树 Host 上（实测 `etaf--keys-binding' 返回 `ignore'），
段级键一条都不会命中。"
  (goto-char (point-min))
  (search-forward "启动选中" nil nil (or index 1)))

(defmacro ebasecamp-ui-test--with-open-ui (&rest body)
  "打开界面并选中组 mysql，在界面 buffer 内按 BODY 执行按键断言。
`ebasecamp-ui-open' 负责把界面 buffer 显示到选中 window（batch 下
`execute-kbd-macro' 只在 selected window 的 buffer 里生效）。"
  (declare (indent 0) (debug t))
  `(progn
     (ebasecamp-ui-open)
     (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/mysql")
     (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
       ,@body)))

(ert-deftest ebasecamp-ui-test-section-keys-dispatch ()
  "point 在第一段内按 `s' / `x' / `r'：派发该段自己的实例与动作。
打桩 `ebasecamp-ui--section-action' 记录 (ACTION INSTANCE)，断言三键依次收到
start / stop / restart，且实例是第一段（dev → myapp），不是第二段（prod）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (ebasecamp-ui-test--with-open-ui
        (let (calls)
          (cl-letf (((symbol-function 'ebasecamp-ui--section-action)
                     (lambda (action instance)
                       (push (list action instance) calls))))
            (dolist (key '("s" "x" "r"))
              (ebasecamp-ui-test--goto-section)
              (execute-kbd-macro (kbd key)))
            (setq calls (nreverse calls))
            (should (equal '(start stop restart) (mapcar #'car calls)))
            ;; 三键都作用在第一段的实例上（不串到 prod → other）
            (should (equal '("dev" "dev" "dev")
                           (mapcar (lambda (call) (plist-get (cadr call) :config))
                                   calls)))
            (should (equal '("myapp" "myapp" "myapp")
                           (mapcar (lambda (call) (plist-get (cadr call) :project))
                                   calls)))))))))

(ert-deftest ebasecamp-ui-test-section-select-all ()
  "point 在第一段内按 `a'：选中集合恰为该段全部服务的 `组名/服务名'。
用 `sort' + `equal' 比较，不依赖选中集合的内部顺序。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (ebasecamp-ui-test--with-open-ui
        (should-not (ebasecamp-ui-selected-keys))
        (ebasecamp-ui-test--goto-section)
        (execute-kbd-macro (kbd "a"))
        (should (equal '("mysql/mysql" "mysql/mysql-ro")
                       (sort (ebasecamp-ui-selected-keys) #'string<)))))))

(ert-deftest ebasecamp-ui-test-section-deselect-all ()
  "第一段 `a'、切到 redis 组 `a'、回到第一段 `A'：只移除第一段的 key。
redis 的 key 原样保留（段级全不选必须只作用于 point 所在段）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--two-groups-manifest)
    (ebasecamp-ui-test--with-ps
        (list (ebasecamp-ui-test--project-container "myapp" "mysql" "mysql"
                                                    "running")
              (ebasecamp-ui-test--project-container "myapp" "mysql" "mysql-ro"
                                                    "running")
              (ebasecamp-ui-test--project-container "other" "redis" "redis"
                                                    "running"))
      (ebasecamp-ui-test--with-open-ui
        ;; 第一段（mysql → dev → myapp）全选
        (ebasecamp-ui-test--goto-section)
        (execute-kbd-macro (kbd "a"))
        (should (equal '("mysql/mysql" "mysql/mysql-ro")
                       (sort (ebasecamp-ui-selected-keys) #'string<)))
        ;; 切到 redis 组（根级 `n'），选中它的唯一服务
        (execute-kbd-macro (kbd "n"))
        (should (eq 'redis (etaf-value
                            (ebasecamp-ui-session-selected-group
                             (ebasecamp-ui-session)))))
        (ebasecamp-ui-test--goto-section)
        (execute-kbd-macro (kbd "a"))
        (should (equal '("mysql/mysql" "mysql/mysql-ro" "redis/redis")
                       (sort (ebasecamp-ui-selected-keys) #'string<)))
        ;; 回到 mysql 组，在第一段按 `A'：只清掉该段的 key
        (execute-kbd-macro (kbd "p"))
        (should (eq 'mysql (etaf-value
                            (ebasecamp-ui-session-selected-group
                             (ebasecamp-ui-session)))))
        (ebasecamp-ui-test--goto-section)
        (execute-kbd-macro (kbd "A"))
        (should (equal '("redis/redis")
                       (sort (ebasecamp-ui-selected-keys) #'string<)))))))

;;; U4. 行级切换勾选（`t`）与 ebox 内建激活（`SPC`）
;;
;; 方案 A（用户 2026-10-23 裁决）：`SPC` 保持 ebox 的「激活当前控件」语义 ——
;; `[32]` 属 `ebox--activation-keys`，节点级 char-property keymap 在按键查找中
;; 先于 etaf 键层（`emulation-mode-map-alists`），root Host 的 `:keys` 拦不住它。
;; 行级切换另绑 `t`，由我们的键层接管，因此在按钮上不会误触。
;;
;; `t` 必须只作用于「point 所在的服务行」，并且**绝不能用**
;; `etaf-activate'：U4 步骤 0 探针实测 `etaf-activate' 无焦点时按 point 处的
;; `RET' 绑定、有焦点时按**焦点**宿主 —— 界面里段内「启动选中 / 停止选中 /
;; 重启选中」按钮就在同一 buffer 里，误触会直接起停容器。
;; 因此实现走「稳定 `:ref'（checkbox 与行各一套）+ `etaf-dispatch-event'」，
;; 本组用例除功能外还断言「按 `t` 不会触发段内按钮」这条安全边界。

(defun ebasecamp-ui-test--goto-first-checkbox ()
  "把 point 移到界面里第一个服务勾选框的 mark 上（`[' 字符处）。
落点必须在 mark 内部：探针实测 point 在 `[ ]' 之后的单元格边界上时最近的 Host
已不属于该 checkbox；而落在 mark 内时最近的 Host 是 mark 自己的生成 ref，
`--checkbox-ref-at-point' 需要沿父节点向上才能取到 checkbox 的显式 ref —— 这也正是
真实使用中（点选 mark 本身）会走的路径。

定位**不能**用裸 `search-forward \"[\"'，也不能只认 mark 字形：v0.6 起段头按钮
文案前置键提示（`[s] 启动选中' / `[x] 停止选中'），而 `[x]' 同时是勾选状态的
mark 字形（`etaf-ui' 的 checkbox 只产出 `[ ]' 与 `[x]'）。因此这里逐个尝试
`[ ]' / `[x]' 候选，**用 `--checkbox-ref-at-point' 自校验**：只有真正落在
checkbox mark 内（能解出 ref）才算命中，按钮提示里的 `[x]' 因解不出 ref 被跳过。
这样以后改按钮文案或键提示格式都不必再动本函数。"
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found)
                (re-search-forward "\\[\\(?: \\|x\\)\\]" nil t))
      (backward-char 2)                     ; mark 内部（`[' 处）
      (if (ebasecamp-ui--checkbox-ref-at-point)
          (setq found t)
        (forward-char 2)))                  ; 不是勾选框 → 从 mark 之后继续找
    (unless found
      (error "界面里找不到服务勾选框的 mark"))))

(defun ebasecamp-ui-test--goto-service-cell ()
  "把 point 移到服务表第二行（mysql-ro）的「服务」单元格上（**非** checkbox 单元格）。
用服务名 `mysql-ro' 定位：它只出现在服务表行内（左树只有组与配置标题，镜像列
截断为 `mysql:8'），且不受列宽影响。"
  (goto-char (point-min))
  (search-forward "mysql-ro")
  (backward-char 2))

(ert-deftest ebasecamp-ui-test-t-toggles-row-at-point ()
  "point 在服务行的非 checkbox 单元格上按 `t'：勾选该行，再按一次取消。
行级切换由行 ref（`ebasecamp-ui-row-<组名>/<服务名>'）解析出同一行的 checkbox
ref 再派发 `press'，因此行内任意单元格都能命中，且只作用于该行自己的勾选框。

**视口必须放大**（`ebox-viewport-height` 60）：L1.2 起右栏是区域内部滚动容器，
batch 下不固定视口时视口高度由内容决定（约 11 行），第二行服务落在滚动视口之外
不会被绘制，`search-forward' 找不到 `mysql-ro'。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((ebox-viewport-height 60))
        (ebasecamp-ui-test--with-open-ui
          (should-not (ebasecamp-ui-selected-keys))
          (ebasecamp-ui-test--goto-service-cell)
          (execute-kbd-macro (kbd "t"))
          (let ((keys (ebasecamp-ui-selected-keys)))
            (should (= 1 (length keys)))
            (should (string-prefix-p "mysql/" (car keys))))
          ;; 再按一次：重新定位（勾选状态变化会重建 buffer 文本）
          (ebasecamp-ui-test--goto-service-cell)
          (execute-kbd-macro (kbd "t"))
          (should-not (ebasecamp-ui-selected-keys)))))))


(ert-deftest ebasecamp-ui-test-spc-activates-checkbox ()
  "point 在 `[ ]' mark 上按 `SPC'：由 ebox 内建激活键勾选，再按一次取消。
守护框架既有语义（方案 A 让 `SPC' 与 `RET' 同义）：`[32]' 属
`ebox--activation-keys'，在可激活节点上由节点级 char-property keymap 先截获，
etaf 的根 Host `:keys' 拿不到该事件 —— 所以 `SPC' 不在 `--root-keys' 里，行级
切换改用 `t'（见 `t-toggles-row-at-point'）。
**本用例不得为了绿灯而删除**：它是「`SPC' 仍能勾选 checkbox」的唯一自动化证据。

**视口必须放大**（`ebox-viewport-height` 60）：与 `t-toggles-row-at-point' 同理，
L1.2 起服务表在区域内部滚动容器里，不放大视口时表格行会落在滚动视口之外。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((ebox-viewport-height 60))
        (ebasecamp-ui-test--with-open-ui
          (should-not (ebasecamp-ui-selected-keys))
          (ebasecamp-ui-test--goto-first-checkbox)
          (execute-kbd-macro (kbd "SPC"))
          (let ((keys (ebasecamp-ui-selected-keys)))
            (should (= 1 (length keys)))
            (should (string-prefix-p "mysql/" (car keys))))
          ;; 再按一次：重新定位（勾选状态变化会重建 buffer 文本）
          (ebasecamp-ui-test--goto-first-checkbox)
          (execute-kbd-macro (kbd "SPC"))
          (should-not (ebasecamp-ui-selected-keys)))))))


(ert-deftest ebasecamp-ui-test-t-outside-row-is-noop ()
  "point 在顶栏（不在任何服务行上）按 `t'：选中集合与 notice 都不变。
静默 no-op 是刻意的：方向键 / Tab 路过时不应刷提示。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (ebasecamp-ui-test--with-open-ui
        (let ((session (ebasecamp-ui-session)))
          (ebasecamp-ui--toggle-selected session "mysql/mysql" t)
          (etaf-set-value (ebasecamp-ui-session-notice session) nil)
          (goto-char (point-min))
          (execute-kbd-macro (kbd "t"))
          (should (equal '("mysql/mysql") (ebasecamp-ui-selected-keys)))
          (should-not (etaf-value (ebasecamp-ui-session-notice session))))))))

(ert-deftest ebasecamp-ui-test-t-does-not-press-section-buttons ()
  "point 在段内「启动选中」按钮上按 `t'：不派发段级动作、不改变选中（防误触）。
段内按钮与 checkbox 同处一个 buffer；`t' 归我们的 etaf 键层（ebox 只截获
`[13] [return] [32] [mouse-1]'），因此在按钮上按 `t' 是安全的 —— 这正是方案 A
把行级切换放在 `t' 而非 `SPC' 的理由。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (ebasecamp-ui-test--with-open-ui
        (let (calls)
          (cl-letf (((symbol-function 'ebasecamp-ui--section-action)
                     (lambda (action instance)
                       (push (list action instance) calls))))
            (ebasecamp-ui-test--goto-section)
            (execute-kbd-macro (kbd "t"))
            (should-not calls)
            (should-not (ebasecamp-ui-selected-keys))))))))

(ert-deftest ebasecamp-ui-test-checkbox-refs-are-stable ()
  "同一服务行的 checkbox ref 在两次 `ebasecamp-ui-refresh' 后保持不变。
ref 由 `组名/服务名' 派生（`intern'），因此重渲染/刷新不改变身份 —— 这正是
「不再需要会话级 `select-actions' 表」（计划 U4.2 原设计）的依据：ref 自带
指向当前渲染的定义，刷新后不会留下过期条目。

视口固定 60 行：L1.2 起服务表在区域内部滚动容器里，视口过矮时表格行落在滚动
视口之外不被绘制（batch 下视口高度还会随窗口状态变化，必须显式固定）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((ebox-viewport-height 60))
        (ebasecamp-ui-open)
        (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/mysql")
        (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
          (ebasecamp-ui-test--goto-first-checkbox)
          (let ((first (ebasecamp-ui--checkbox-ref-at-point)))
            (should first)
            (should (string-prefix-p "ebasecamp-ui-check-" (symbol-name first)))
            (ebasecamp-ui-refresh (ebasecamp-status-last-records) t)
            (ebasecamp-ui-test--goto-first-checkbox)
            (should (eq first (ebasecamp-ui--checkbox-ref-at-point)))
            (ebasecamp-ui-refresh (ebasecamp-status-last-records) t)
            (ebasecamp-ui-test--goto-first-checkbox)
            (should (eq first (ebasecamp-ui--checkbox-ref-at-point)))))))))


;;; U5. 编辑入口（`e`）与唯一写入口
;;
;; 界面 buffer 只读（U1），写只能发生在清单文件里：`e' →
;; `ebasecamp-ui-edit-manifest' 先按组名跨文件定位（组可能在 `groups.el'，也
;; 可能在 `projects/*.el'），再 `find-file' 该文件并把 point 定位到
;; `(ebasecamp-define-group <组名>'。错误/边界路径：无选中组（`user-error'）、
;; 磁盘上定位不到该组（降级：`message' + 打开 `groups.el' 文件头，不 signal）、
;; 连可编辑的清单文件都没有（`user-error' + 指向 `ebasecamp-create-sample-config'）、
;; 以及键位本身是否进了根 Host 的 `:keys'。
;;
;; 用例必须落在**真实文件**上：定位断言依赖磁盘上 `(ebasecamp-define-group mysql'
;; 的实际文本形态（样例清单的组定义是单行头 + 缩进关键字），不能用内存注册表替代。

(ert-deftest ebasecamp-ui-test-edit-manifest-opens-groups-and-locates-group ()
  "选中组后调用编辑入口：打开 `<dir>/groups.el' 且 point 落在该组定义行上。"
  (ebasecamp-ui-test--with-ui
    ;; 写真实清单（groups.el + projects/example.el），并让 `ebasecamp-ui-open'
    ;; 经 `--ensure-manifest' 从磁盘加载（内存注册表此时为空）。
    (ebasecamp-create-sample-config)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (ebasecamp-ui--set-selected-group (ebasecamp-ui-session) 'mysql)
      (let ((buffer (ebasecamp-ui-edit-manifest)))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal (expand-file-name "groups.el"
                                               ebasecamp-config-directory)
                             (buffer-file-name)))
              (should (ebasecamp-ui-test--contains-p
                       (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position))
                       "(ebasecamp-define-group mysql")))
          ;; 清掉这个 buffer：后续用例不该被「已访问 groups.el」污染
          (kill-buffer buffer))))))

(ert-deftest ebasecamp-ui-test-edit-manifest-errors-without-file ()
  "清单目录里没有 groups.el：`user-error'，消息含目录路径与 `ebasecamp-create-sample-config'。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (should-not (file-exists-p (expand-file-name "groups.el"
                                                 ebasecamp-config-directory)))
    (ebasecamp-ui--set-selected-group (ebasecamp-ui-session) 'mysql)
    (let ((message (error-message-string
                    (should-error (ebasecamp-ui-edit-manifest)
                                  :type 'user-error))))
      (should (string-match-p (regexp-quote ebasecamp-config-directory) message))
      (should (string-match-p (regexp-quote "ebasecamp-create-sample-config")
                              message)))))

(ert-deftest ebasecamp-ui-test-edit-manifest-without-selected-group ()
  "无选中组时调用编辑入口：`user-error' 提示先选组（不改动任何 buffer）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (should-not (ebasecamp-ui-test--selected-group))
    (let ((message (error-message-string
                    (should-error (ebasecamp-ui-edit-manifest)
                                  :type 'user-error))))
      (should (string-match-p "选中" message)))))

(ert-deftest ebasecamp-ui-test-edit-manifest-locates-project-file ()
  "组定义在 `projects/x.el' 时 `e' 打开该文件并定位到组定义；
磁盘上定位不到该组时降级为打开 `groups.el' 文件头 + `message'（不 signal）。"
  (ebasecamp-ui-test--with-ui
    (let ((dir ebasecamp-config-directory))
      (make-directory (expand-file-name "projects/" dir) t)
      (with-temp-file (expand-file-name "projects/x.el" dir)
        (insert ";;; -*- lexical-binding: t; -*-\n"
                "(ebasecamp-define-group mysql\n"
                "  :title \"mysql\"\n"
                "  :scope per-project\n"
                "  :services ((mysql :image \"mysql:8.4\"))\n"
                "  :configs nil)\n"
                "\n"
                "(ebasecamp-define-project myapp\n"
                "  :title \"myapp\"\n"
                "  :root \"/tmp/ebc-myapp\")\n"))
      (with-temp-file (expand-file-name "groups.el" dir)
        (insert ";;; -*- lexical-binding: t; -*-\n"
                "(ebasecamp-define-group other\n"
                "  :title \"other\"\n"
                "  :scope per-project\n"
                "  :services ((web :image \"nginx:1.27\"))\n"
                "  :configs nil)\n"))
      (ebasecamp-config-load)
      ;; ① 组在 projects/x.el：`e' 打开该文件并把 point 定位到组定义
      (ebasecamp-ui--set-selected-group (ebasecamp-ui-session) 'mysql)
      (let ((buffer (ebasecamp-ui-edit-manifest)))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal (expand-file-name "projects/x.el" dir)
                             (buffer-file-name)))
              (should (ebasecamp-ui-test--contains-p
                       (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position))
                       "(ebasecamp-define-group mysql")))
          (kill-buffer buffer)))
      ;; ② 磁盘上定位不到该组（只有 other）：降级为 groups.el 文件头 + message
      (ebasecamp-ui--set-selected-group (ebasecamp-ui-session) 'phantom)
      (let ((notes nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (push (apply #'format format-string args) notes)
                     nil)))
          (let ((buffer (ebasecamp-ui-edit-manifest)))
            (unwind-protect
                (with-current-buffer buffer
                  (should (equal (expand-file-name "groups.el" dir)
                                 (buffer-file-name)))
                  (should (= (point-min) (point))))
              (kill-buffer buffer))))
        (should (string-match-p "phantom" (mapconcat #'identity notes " | ")))))))

(ert-deftest ebasecamp-ui-test-e-key-is-bound ()
  "`e' 进了根 Host 的 `:keys'：绑定存在且不是 local 边界的 `ignore'。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
        (let ((binding (etaf--keys-binding [?e])))
          (should binding)
          (should-not (eq binding #'ignore)))))))

;;; U6. 帮助与可发现性
;;
;; 键位的**可发现性**只有一条来源：`--root-keys' / `--section-keys' 的第 3 元素
;; LABEL（`etaf-help' 会**跳过没有 LABEL 的条目**，见 etaf-help.el 的
;; `etaf-help-data'：`(when (nth 2 entry) …)'）。因此本组用例守护两件事：
;; 1. 每条键都有非空 LABEL，且键表本身能过 `etaf--keys-validate'；
;; 2. LABEL 真的能被 `etaf-help-data' 收集到（`?` 帮助的端到端核对）。
;;
;; 实测（batch 探针，本文件用例固化）：`etaf-help-data' 与 `etaf-help' 在
;; `emacs -Q --batch' 下**都可用** —— 前者按 point 所在键链返回 `:groups'，
;; 后者立即挂载只读 catalog（`etaf-next-tick' 在 batch 之外立刻执行）。
;; 故 U6.2 的「帮助面提及键位」不需要降级为人工目检。

(defun ebasecamp-ui-test--help-labels (&optional data)
  "返回 `etaf-help-data' 快照里全部条目的 LABEL 列表（跨组拍平）。
DATA 省略时按当前 buffer 现场取快照；调用前须把 point 放在要断言的作用域内
（`etaf--keys-chain' 从 point / 焦点所在 Host 向外走到 `:key-scope 'local' 边界）。"
  (let ((groups (plist-get (or data (etaf-help-data)) :groups)))
    (apply #'append
           (mapcar (lambda (group)
                     (mapcar (lambda (entry) (plist-get entry :label))
                             (plist-get group :entries)))
                   groups))))

(ert-deftest ebasecamp-ui-test-all-keys-have-labels ()
  "根级与段级键表的每条都是 (KEY COMMAND LABEL)，LABEL 为非空字符串。
LABEL 是可发现性的唯一来源（`etaf-help' 跳过无 LABEL 的条目）；COMMAND 必须
`commandp`（`etaf--keys-run' 对 commandp 用 `call-interactively'，段级闭包因此
必须带 `(interactive)'）；整表要能通过 `etaf--keys-validate' 不 signal。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let* ((instance (car (ebasecamp-ui-test--instances)))
             (root (ebasecamp-ui--root-keys))
             (section (ebasecamp-ui--section-keys "mysql" instance)))
        (dolist (keys (list root section))
          (should keys)
          (dolist (entry keys)
            (should (consp entry))
            ;; KEY 可被 `etaf--keys-event' 归一（字符串或事件向量都行）
            (should (etaf--keys-event (car entry)))
            (should (commandp (nth 1 entry)))
            (should (stringp (nth 2 entry)))
            (should-not (string-empty-p (nth 2 entry))))
          ;; `etaf--keys-validate' 不 signal，且返回同一份 KEYS
          (should (equal keys (etaf--keys-validate keys))))))))

(ert-deftest ebasecamp-ui-test-root-keys-final-set ()
  "根级键的**最终集合**恰为 q f g h j k l n p e t I o D 1 2 3 S E M X（21 条），一个不多一个不少。
用 `key-description' 把每条 KEY 归一后再 `sort' + `equal' 做**精确等值**比较
（不用「包含」断言，否则多绑/少绑都发现不了）。`SPC` **不在**本表：`[32]` 属于
ebox 的 `ebox--activation-keys'（节点级 char-property keymap，按键查找中先于
etaf 键层），写进 `:keys' 也收不到事件 —— 它由 ebox 内建处理，等价于
「激活当前控件」（= `RET'）；行级切换勾选因此用 `t'（见 `t-toggles-row-at-point'）。
`1`/`2`/`3` 是 N1 加的区域跳转键（跳到左栏 / 右栏 / 底栏）；`S`/`E`/`M`/`X`
是 W4 加的写操作键（编辑服务 / 编辑配置 / 移动配置 / 清单操作）；`h`/`j`/`k`/`l`
是 v0.6 批次 2 加的 vim 方向导航键（焦点移动 + 树折叠展开，**不改**选中组）；
`f` 是 v0.6 批次 3 加的 avy 跳转键（组 / 配置 / 服务行）。"
  (ebasecamp-ui-test--with-ui
    (let* ((keys (ebasecamp-ui--root-keys))
           (descriptions (mapcar (lambda (entry)
                                   (key-description (etaf--keys-event (car entry))))
                                 keys)))
      (should (= 21 (length keys)))
      (should (equal '("1" "2" "3" "D" "E" "I" "M" "S" "X"
                       "e" "f" "g" "h" "j" "k" "l" "n" "o" "p" "q" "t")
                     (sort (copy-sequence descriptions) #'string<)))
      ;; `SPC` 由 ebox 内建激活处理，不得出现在本表
      (should-not (member "SPC" descriptions))
      (should-not (member "RET" descriptions)))))

(ert-deftest ebasecamp-ui-test-help-data-includes-labels ()
  "`etaf-help-data' 能收集到根级与段级的全部 LABEL（`?` 帮助的端到端核对）。
point 在顶栏区时键链只到根 Host，收集到 21 条根级 LABEL（含 N1 加的三个区域
跳转键，以及 v0.6 新增的 `f`/`j`/`k`/`h`/`l`）；point 落到某个配置段内时段 Host
的 5 条段级 LABEL 一并进入快照（段键与根键不重叠，不会互相 shadow）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (ebasecamp-ui-test--with-open-ui
        (goto-char (point-min))
        (let ((labels (ebasecamp-ui-test--help-labels)))
          (should labels)
          (dolist (label '("关闭界面" "重载清单并刷新" "下一个组" "上一个组"
                           "编辑当前组清单" "切换勾选"
                           "导入 compose" "导出 compose" "销毁环境"
                           "跳到左栏" "跳到右栏" "跳到底栏"
                           "编辑服务" "编辑配置" "移动配置" "清单操作"))
            (should (member label labels))))
        ;; point 进入第一段 → 段级 LABEL 也出现在快照里
        (ebasecamp-ui-test--goto-section)
        (let ((labels (ebasecamp-ui-test--help-labels)))
          (dolist (label '("启动该段选中" "停止该段选中" "重启该段选中"
                           "全选该段服务" "全不选该段服务"))
            (should (member label labels))))))))

(ert-deftest ebasecamp-ui-test-help-key-is-available ()
  "`?` 处于可用状态：`(etaf--keys-binding [??])' 非 nil 且不是 `ignore'。
`?` 是 etaf 的框架保留键（`etaf-help'，见帮助面「通用导航 · 查看快捷键」），
应用不能绑也不能覆盖；`[??]' 在 Elisp 里读作事件向量 `[63]'（字符 `?'）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
        (let ((binding (etaf--keys-binding [??])))
          (should binding)
          (should-not (eq binding #'ignore)))))))

(ert-deftest ebasecamp-ui-test-help-surface-mentions-keys ()
  "`?` 的帮助面在 batch 下真能挂载，并列出根级键的 LABEL（U6.2，未降级）。
帮助面是 etaf 的只读 modal catalog（标题「快捷键 · 只读」）；它按可用视口裁剪
条目 —— 全量运行时首屏只渲染前 4 条根级键（「编辑当前组清单」及之后的条目被裁掉，
实测同一用例单独跑时能多渲一条，说明裁剪量随窗口可用行数变化）。因此这里只断言
**首屏必然出现**的 4 条根级 LABEL + 标题，其余 LABEL 的全量核对交给
`help-data-includes-labels`（它断言的是数据快照，不经视口裁剪）。
收尾断言 `etaf-help-close' 后 `etaf--help-state' 清空且 buffer 文本复原。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
        (let ((before (substring-no-properties (buffer-string))))
          (unwind-protect
              (progn
                (goto-char (point-min))
                (etaf-help)
                (should etaf--help-state)
                (let ((text (substring-no-properties (buffer-string))))
                  (should-not (equal before text))
                  (should (ebasecamp-ui-test--contains-p text "快捷键"))
                  (dolist (label '("关闭界面" "重载清单并刷新"
                                   "下一个组" "上一个组"))
                    (should (ebasecamp-ui-test--contains-p text label))))
                (etaf-help-close)
                (should-not etaf--help-state)
                (should (equal before (substring-no-properties (buffer-string)))))
            (ignore-errors (etaf-help-close))))))))

;;; L. 三段式布局（根 flex 纵向、中间区限高滚动、底栏常驻）
;;
;; 判据全部来自 `ebox' 的布局结果（`ebox-node-geometry' / `ebox-geo-vh' /
;; `ebox-geo-ch'），**不**用 `set-frame-height'：L0.1 实测 batch 下
;; `(set-frame-height nil 40)' 后 `frame-height' 仍为 25、ebox 视口不受影响。
;; 一律用 `(let ((ebox-viewport-height 20)) ...)' 固定视口，且该绑定必须包住
;; `ebasecamp-ui-open'（mount 时才读这个变量）。
;;
;; 注意不要 `%S' 打印 `ebox-node-layout'：布局结构含循环引用，未开
;; `print-circle' 会卡死。只取标量（`:y' / `:height' / `vh' / `ch'）。

(defun ebasecamp-ui-test--wide-manifest ()
  "定义组 bulk（per-project、1 份配置 dev → myapp、20 个服务）。
服务多到足以让右栏内容高于 20 行视口，从而可验证「区域内部滚动」。"
  (ebasecamp-define-group bulk
    :title "Bulk"
    :scope per-project
    :services ((svc01 :image "mysql:8.4") (svc02 :image "mysql:8.4")
               (svc03 :image "mysql:8.4") (svc04 :image "mysql:8.4")
               (svc05 :image "mysql:8.4") (svc06 :image "mysql:8.4")
               (svc07 :image "mysql:8.4") (svc08 :image "mysql:8.4")
               (svc09 :image "mysql:8.4") (svc10 :image "mysql:8.4")
               (svc11 :image "mysql:8.4") (svc12 :image "mysql:8.4")
               (svc13 :image "mysql:8.4") (svc14 :image "mysql:8.4")
               (svc15 :image "mysql:8.4") (svc16 :image "mysql:8.4")
               (svc17 :image "mysql:8.4") (svc18 :image "mysql:8.4")
               (svc19 :image "mysql:8.4") (svc20 :image "mysql:8.4"))
    :configs ((dev :project myapp)))
  (ebasecamp-define-project myapp :title "示例项目" :groups nil))

(defun ebasecamp-ui-test--runtime ()
  "返回主界面 buffer 的 etaf runtime（未挂载时 nil）。"
  (etaf-runtime-for-buffer (get-buffer ebasecamp-ui-buffer-name)))

(defun ebasecamp-ui-test--node (ref)
  "返回主界面里 REF 对应的 ebox 节点（未声明该 ref 时 nil）。"
  (when-let* ((runtime (ebasecamp-ui-test--runtime)))
    (etaf-runtime-host-node runtime ref)))

(defun ebasecamp-ui-test--geo (ref)
  "返回 REF 节点的 `ebox-node-geometry'（(:x :y :width :height) 或 nil）。"
  (when-let* ((node (ebasecamp-ui-test--node ref)))
    (ebox-node-geometry node)))

(ert-deftest ebasecamp-ui-test-open-uses-flex-column-root ()
  "根 Host 必须是 `flex' 纵向容器，且高度取 `stretch'。
`column' / `row' 不走 flex 分配算法（只有 tag 为 `flex' 的节点进
`ebox--layout-flex'），写 `column' 时中间区撑不开、底栏掉出视口。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open)
        (let* ((node (ebasecamp-ui-test--node 'ebasecamp-ui-root))
               (props (and node (ebox-node-props node))))
          (should node)
          (should (eq 'flex (ebox-node-tag node)))
          (should (eq 'column (plist-get props :flex-direction)))
          (should (eq 'stretch (plist-get props :height)))
          ;; 根高等于固定视口（20 行）：三段式总高 = 视口高，整窗不滚
          (should (equal 20 (plist-get (ebox-node-geometry node) :height))))))))

(ert-deftest ebasecamp-ui-test-body-region-is-scrollable ()
  "中间区被限高（严格小于视口），左右两栏各自 `:overflow 'scroll' 且内容高于视口。
滚动落在两个 pane 上（中间区是 flex 容器，只负责「撑满剩余高度」）；
`etaf-scroll-by' 作用在右栏时 offset 真的变化。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open)
        (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/bulk")
        (let* ((runtime (ebasecamp-ui-test--runtime))
               (body (ebasecamp-ui-test--node 'ebasecamp-ui-body))
               (body-geo (ebasecamp-ui-test--geo 'ebasecamp-ui-body))
               (tree (ebasecamp-ui-test--node 'ebasecamp-ui-tree))
               (detail (ebasecamp-ui-test--node 'ebasecamp-ui-detail))
               (detail-geo (ebox-node-layout detail)))
          (should body)
          ;; 中间区：flex-grow 1 + min-height (lh 0)（可收缩），被限高
          (should (equal 1 (plist-get (ebox-node-props body) :flex-grow)))
          (should (equal '(lh 0) (plist-get (ebox-node-props body) :min-height)))
          (should (> (plist-get body-geo :height) 0))
          (should (< (plist-get body-geo :height) 20))
          ;; 两栏都是滚动容器
          (should (eq 'scroll (plist-get (ebox-node-props tree) :overflow)))
          (should (eq 'scroll (plist-get (ebox-node-props detail) :overflow)))
          ;; 右栏内容高于自身视口 → 可滚
          (should (< (ebox-geo-vh detail-geo) (ebox-geo-ch detail-geo)))
          (should (equal 3 (etaf-scroll-by runtime 'ebasecamp-ui-detail 3)))
          (should (> (etaf-scroll-offset runtime 'ebasecamp-ui-detail) 0)))))))

(ert-deftest ebasecamp-ui-test-footer-pinned-at-bottom ()
  "底栏几何的下沿贴住视口下沿（允许 0–1 行误差），且不低于中间区。
底栏 `:flex-shrink 0'，中间区 `:min-height (lh 0)' 承担全部收缩。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open)
        (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/bulk")
        (let* ((root-geo (ebasecamp-ui-test--geo 'ebasecamp-ui-root))
               (footer (ebasecamp-ui-test--node 'ebasecamp-ui-footer))
               (footer-geo (ebasecamp-ui-test--geo 'ebasecamp-ui-footer))
               (body-geo (ebasecamp-ui-test--geo 'ebasecamp-ui-body))
               (bottom (+ (plist-get footer-geo :y) (plist-get footer-geo :height)))
               (viewport-bottom (+ (plist-get root-geo :y)
                                   (plist-get root-geo :height))))
          (should footer)
          (should (equal 0 (plist-get (ebox-node-props footer) :flex-shrink)))
          ;; 下沿 ≈ 视口下沿（0–1 行误差）
          (should (<= 0 (- viewport-bottom bottom) 1))
          ;; 底栏在中间区之下（不与中间区重叠）
          (should (< (+ (plist-get body-geo :y) (plist-get body-geo :height))
                     bottom)))))))

(ert-deftest ebasecamp-ui-test-scroll-body-keeps-header-footer ()
  "滚动右栏后顶栏与底栏文本仍在 buffer 里（整窗不随区域滚动）。
参照 `etaf/tests/etaf-events-tests.el' 的 head / 滚动区 / foot 写法；
末尾再滚到**底部**（`etaf-scroll-to ... 'end`），断言底栏仍在最后一行：
底栏几何的下沿不因区域滚动而移动。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open)
        (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/bulk")
        (let ((runtime (ebasecamp-ui-test--runtime)))
          (etaf-scroll-by runtime 'ebasecamp-ui-detail 5)
          (should (> (etaf-scroll-offset runtime 'ebasecamp-ui-detail) 0))
          (let ((text (ebasecamp-ui-test--buffer-text)))
            (dolist (token '("ebasecamp" "导入 compose" "导出 compose" "销毁环境"))
              (should (ebasecamp-ui-test--contains-p text token))))
          ;; 滚到底：底栏仍在（下沿不动，顶栏/底栏文本不消失）
          (let ((before (ebasecamp-ui-test--geo 'ebasecamp-ui-footer)))
            (etaf-scroll-to runtime 'ebasecamp-ui-detail 'end)
            (should (> (etaf-scroll-offset runtime 'ebasecamp-ui-detail) 5))
            (should (equal before (ebasecamp-ui-test--geo 'ebasecamp-ui-footer)))
            (let ((text (ebasecamp-ui-test--buffer-text)))
              (dolist (token '("ebasecamp" "导入 compose" "销毁环境"))
                (should (ebasecamp-ui-test--contains-p text token))))))))))



;;; 主题（批次 T：face 基础色 + 明暗 palette 状态色）

(defconst ebasecamp-ui-test--render-functions
  '(ebasecamp-ui-app
    ebasecamp-ui--tree-view
    ebasecamp-ui--detail-view
    ebasecamp-ui--footer-view
    ebasecamp-ui--footer-button
    ebasecamp-ui--notice-view
    ebasecamp-ui--instance-section
    ebasecamp-ui--instance-header
    ebasecamp-ui--service-table
    ebasecamp-ui--group-header-row
    ebasecamp-ui--legacy-hint-view
    ebasecamp-ui--empty-configs-view
    ebasecamp-ui--detail-placeholder
    ebasecamp-ui--select-cell
    ebasecamp-ui--state-cell
    ebasecamp-ui--ports-cell
    ebasecamp-ui--health-cell
    ebasecamp-ui--scope-badge
    ebasecamp-ui--section-button)
  "色值字面量扫描的**显式范围**（render 函数名清单）。
清单界定「render 区」的边界：属性级扫描只在这 19 个函数的定义体内进行，
palette / `defcustom' 默认值定义区不在范围内。清单本身也被断言 —— 每个名字
必须在 `lisp/ebasecamp-ui.el' 里有 `defun'（或 `etaf-define-component'）定义，
否则拼错会静默缩小扫描面导致假绿。")

(defconst ebasecamp-ui-test--required-theme-tokens
  '(:ui-fg :ui-bg :ui-panel-fg :ui-panel-bg :ui-panel-border :ui-muted-fg
    :ui-border :ui-divider-bg :ui-table-border
    :ui-accent :ui-accent-fg :ui-accent-soft-bg
    :ui-success-fg :ui-success-bg :ui-success-border
    :ui-warning-fg :ui-warning-bg :ui-warning-border
    :ui-danger-fg :ui-danger-bg :ui-danger-border
    :ui-info-fg :ui-info-bg :ui-info-border
    :ui-disabled-fg :ui-disabled-bg :ui-disabled-border
    :ui-button-primary-fg :ui-button-primary-bg
    :ui-button-secondary-fg :ui-button-secondary-bg
    :ui-button-ghost-fg
    :ui-checkbox-enabled-fg
    :ui-table-selected-fg :ui-table-selected-bg)
  "计划 T4 的 35 个必需 token（9 个基础色 + 26 个状态色）。
未列入的 token（`:ui-shell-*' / `:ui-window-*' / `:ui-search-*' /
`:ui-picker-*' / `:ui-playing-card-*' / `:ui-data-grid-*'）继续走 etaf-ui
palette 回退 —— 这些组件在界面上不出现，不为「全量」而覆盖。")

(defun ebasecamp-ui-test--source-file ()
  "返回 `lisp/ebasecamp-ui.el' 的绝对路径（取已加载库所在目录的上一级）。"
  (let ((lib (locate-library "ebasecamp-ui")))
    (should lib)
    (expand-file-name "lisp/ebasecamp-ui.el"
                      (file-name-directory
                       (directory-file-name (file-name-directory lib))))))

(defun ebasecamp-ui-test--definition-source (file name)
  "返回 FILE 里 NAME 的定义源码（`defun' 或 `etaf-define-component'）。
找不到时返回 nil。用 `forward-sexp' 取完整 sexp 边界，不手写括号匹配。"
  (with-temp-buffer
    (insert-file-contents file)
    (let ((needles (list (format "(defun %s " name)
                         (format "(etaf-define-component %s " name)))
          start)
      (while (and (null start) needles)
        (goto-char (point-min))
        (when (search-forward (car needles) nil t)
          (setq start (match-beginning 0)))
        (setq needles (cdr needles)))
      (when start
        (goto-char start)
        (let ((end (ignore-errors (progn (forward-sexp 1) (point)))))
          (and end (buffer-substring-no-properties start end)))))))

(defun ebasecamp-ui-test--node-by-class (root class)
  "在 ROOT 子树里返回第一个 class 列表含 CLASS 的节点（找不到 nil）。"
  (let (found)
    (ebox-node-walk root
                    (lambda (node)
                      (when (and (null found)
                                 (member class
                                         (ignore-errors (ebox-node-classes node))))
                        (setq found node))))
    found))

;; 测试专用组件：把 `ebasecamp-ui--theme' 提供给子树并渲染状态徽标。
;; 用于验证「token 真的贯通到 etaf-ui 组件」（badge 的背景色 == theme 值）。
(etaf-define-component ebasecamp-ui-test--theme-probe ()
  "测试用组件：provide `ebasecamp-ui--theme' 后渲染一个 running 状态徽标。"
  :setup (etaf-theme-provide ebasecamp-ui--theme)
  :render
  (etaf-view
   (box :ref 'ebasecamp-ui-test-badge-host :width 'stretch
     (expr (ebasecamp-ui--state-cell '(:state "running"))))))

(ert-deftest ebasecamp-ui-test-render-region-has-no-literal-colors ()
  "render 函数区内不得出现「样式属性 + 色值字面量」。
扫描范围由 `ebasecamp-ui-test--render-functions' 显式界定（属性级检查，不是
全文 grep）：色值字面量只允许出现在 `ebasecamp-ui--palette-light' /
`ebasecamp-ui--palette-dark' 与 `ebasecamp-ui-theme' 的默认值里。
清单里每个名字都必须有定义 —— 否则清单拼错会让扫描面静默缩小。"
  (let ((file (ebasecamp-ui-test--source-file))
        (pattern ":\\(bgcolor\\|color\\|background-color\\|border\\)[[:space:]]+\"#[0-9A-Fa-f]\\{6\\}\""))
    (dolist (name ebasecamp-ui-test--render-functions)
      (let ((source (ebasecamp-ui-test--definition-source
                     file (symbol-name name))))
        (should source)
        (should-not (string-match-p pattern source))))))

(ert-deftest ebasecamp-ui-test-theme-plist-covers-required-tokens ()
  "`ebasecamp-ui--theme-plist' 返回覆盖 T4 全部 35 个 token 的 plist。
集合比较是**双向精确**的（既不缺、也不多），每个值必须是非空字符串（etaf 的
Theme 值最终要落到 Host 的色值属性上，nil 会让属性静默消失）。"
  (let* ((plist (ebasecamp-ui--theme-plist))
         (keys (cl-loop for (key _value) on plist by #'cddr collect key)))
    (should (proper-list-p plist))
    (should (zerop (% (length plist) 2)))
    (should (= 35 (length ebasecamp-ui-test--required-theme-tokens)))
    ;; 键数正好 35（重复键会让 etaf 的默认值展开出现重复条目）
    (should (= 35 (length keys)))
    ;; 不缺
    (should (null (cl-set-difference ebasecamp-ui-test--required-theme-tokens
                                     keys)))
    ;; 不多
    (should (null (cl-set-difference keys
                                     ebasecamp-ui-test--required-theme-tokens)))
    (cl-loop for (_key value) on plist by #'cddr
             do (should (and (stringp value) (not (string-empty-p value)))))))

(ert-deftest ebasecamp-ui-test-theme-plist-dark-differs ()
  "暗色模式下状态色不得等于 etaf-ui 的浅色 palette；基础色随明暗不同。
两半：
① `:ui-success-bg' 在 dark 下 ≠ `\"#DCEBDD\"'（etaf-ui `etaf-ui--style-palette'
   的浅色 success 背景），且 `:ui-bg' / `:ui-fg' 明暗不同 —— 否则「暗色主题下
   界面发白」的根因（只有一套浅色值）没被消除；
② `--state-cell' 渲染出的 badge 背景色等于 theme 的 `:ui-success-bg' ——
   token 真的贯通到 etaf-ui 组件（provide 生效），不只是 plist 里有一堆色值。"
  (let ((original (frame-parameter nil 'background-mode)))
    (unwind-protect
        (progn
          (set-frame-parameter nil 'background-mode 'dark)
          (ebasecamp-ui--refresh-theme)
          (let ((dark (ebasecamp-ui--theme-plist)))
            (should (eq 'dark (ebasecamp-ui--background-mode)))
            (should-not (equal "#DCEBDD" (plist-get dark :ui-success-bg)))
            (set-frame-parameter nil 'background-mode 'light)
            (ebasecamp-ui--refresh-theme)
            (let ((light (ebasecamp-ui--theme-plist)))
              (should (eq 'light (ebasecamp-ui--background-mode)))
              (should-not (equal (plist-get light :ui-bg)
                                 (plist-get dark :ui-bg)))
              (should-not (equal (plist-get light :ui-fg)
                                 (plist-get dark :ui-fg)))
              (should-not (equal (plist-get light :ui-success-bg)
                                 (plist-get dark :ui-success-bg)))
              ;; ② badge 端到端（用 dark 下的 theme 值断言）
              (set-frame-parameter nil 'background-mode 'dark)
              (ebasecamp-ui--refresh-theme)
              (let ((buf (generate-new-buffer " *ebasecamp-theme-probe*")))
                (unwind-protect
                    (with-current-buffer buf
                      (setq ebox-viewport-height 10)
                      (etaf-mount buf (etaf-view (ebasecamp-ui-test--theme-probe)))
                      (let* ((runtime (etaf-runtime-for-buffer buf))
                             (host (etaf-runtime-host-node
                                    runtime 'ebasecamp-ui-test-badge-host))
                             (badge (and host
                                         (ebasecamp-ui-test--node-by-class
                                          host "etaf-badge"))))
                        (should host)
                        (should badge)
                        (should (equal (plist-get (ebox-node-props badge)
                                                  :background-color)
                                       (plist-get dark :ui-success-bg)))))
                  (kill-buffer buf))))))
      (set-frame-parameter nil 'background-mode original)
      (ebasecamp-ui--refresh-theme))))

(ert-deftest ebasecamp-ui-test-theme-follows-load-theme ()
  "`load-theme' 切换后 theme ref 的值随明暗变化（`enable-theme-functions' 钩子）。
`ebasecamp-ui-open' 挂钩子、`ebasecamp-ui-close' 卸载（对称，T1.4）。
modus-operandi / modus-vivendi 是 Emacs 31.1 内置主题（实测 `load-theme' 会把
`background-mode' 帧参数改成 light / dark）。用例 `unwind-protect' 收尾恢复原
主题态。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20)
            (original (copy-sequence custom-enabled-themes))
            dark light)
        (unwind-protect
            (progn
              (ebasecamp-ui-open)
              (should (memq 'ebasecamp-ui--theme-hook enable-theme-functions))
              (should (memq 'ebasecamp-ui--theme-hook disable-theme-functions))
              (load-theme 'modus-vivendi t)
              (setq dark (etaf-value ebasecamp-ui--theme))
              (should (eq 'dark (ebasecamp-ui--background-mode)))
              (load-theme 'modus-operandi t)
              (setq light (etaf-value ebasecamp-ui--theme))
              (should (eq 'light (ebasecamp-ui--background-mode)))
              ;; ref 真的被钩子更新：暗色与浅色两套值不同
              (should-not (equal (plist-get dark :ui-bg)
                                 (plist-get light :ui-bg)))
              (should-not (equal (plist-get dark :ui-success-bg)
                                 (plist-get light :ui-success-bg)))
              ;; plist 仍完整（钩子走的是同一个生成函数）
              (should (= 35 (length (cl-loop for (key _value) on light by #'cddr
                                             collect key))))
              ;; close 之后钩子被移除（与 open 对称）
              (ebasecamp-ui-close)
              (should-not (memq 'ebasecamp-ui--theme-hook
                                enable-theme-functions))
              (should-not (memq 'ebasecamp-ui--theme-hook
                                disable-theme-functions)))
          (mapc #'disable-theme (copy-sequence custom-enabled-themes))
          (mapc (lambda (theme) (load-theme theme t)) original))))))

;;; W. 左栏宽度与持久化（defcustom 默认 0.26、可拖动、跨会话记住、越界钳制）
;;
;; 判据分两层：
;; - **布局**：`(let ((ebox-viewport-height 20)) ...)' 固定视口后取
;;   `ebasecamp-ui-tree' / `ebasecamp-ui-detail' 的 `ebox-geo-bw'（像素）；
;; - **持久化**：`ebasecamp-cache-directory' 由 `--with-ui' 绑到临时目录，状态文件
;;   用 `(read (current-buffer))' 校验形态（不匹配文本格式，只匹配数据）。
;; 越界值必须在**渲染前**钳制：`etaf-splitter' 的 `:ratio' 校验是
;; `(<= min-ratio ratio max-ratio)'，越界会让 `etaf-check-prop' 在渲染期 signal
;; （界面直接打不开），所以「打开界面不报错」本身也是一条断言。

(defun ebasecamp-ui-test--split-ratio-current ()
  "返回当前会话的左栏宽度占比（`etaf-ref' 的值）。"
  (etaf-value (ebasecamp-ui-session-split-ratio (ebasecamp-ui-session))))

(defun ebasecamp-ui-test--pane-bw (ref)
  "返回 REF 节点的边框宽（像素）；节点未布局时 nil。"
  (when-let* ((node (ebasecamp-ui-test--node ref))
              (layout (ebox-node-layout node)))
    (ebox-geo-bw layout)))

(defun ebasecamp-ui-test--write-ui-state (content)
  "把 CONTENT 原样写入界面状态文件，返回该路径。
用于模拟三类非法输入：非 plist、非 `(:split-ratio NUMBER)' 形态、ratio 越界。"
  (let ((file (ebasecamp-ui--ui-state-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert content))
    file))

(ert-deftest ebasecamp-ui-test-split-ratio-default ()
  "新建会话的左栏占比是 defcustom 默认 0.26；无状态文件时载入也返回 0.26。
另断言布局确实按 0.26 分配（左栏约占 splitter 宽的 26%，容差 ±2% 吸收
`%' 单位取整与分隔线 3px）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (should (= 0.26 ebasecamp-ui--split-ratio))
      (should (= 0.15 ebasecamp-ui--split-ratio-min))
      (should (= 0.55 ebasecamp-ui--split-ratio-max))
      ;; 状态文件不存在 → 回退 defcustom 默认
      (should-not (file-exists-p (ebasecamp-ui--ui-state-file)))
      (should (equal 0.26 (ebasecamp-ui--load-ui-state)))
      ;; 打开界面后会话 ref 承载默认值
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open))
      (should (equal 0.26 (ebasecamp-ui-test--split-ratio-current)))
      (let* ((tree (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-tree))
             (detail (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-detail))
             (total (+ tree detail 3)))
        (should (and (integerp tree) (integerp detail) (> total 0)))
        (should (<= 0.24 (/ (float tree) total) 0.28))))))

(ert-deftest ebasecamp-ui-test-split-ratio-default-single-source ()
  "默认占比收敛为单一常量 `ebasecamp-ui--split-ratio-default'。
三条读取路径都必须回落到该常量，而不是各自写死字面量：defcustom 的默认值、
`--load-ui-state' 无状态文件时的回退、`--current-split-ratio' 无会话分支。
另断言常量本身仍是 0.26 —— 收敛常量不得顺手改掉既有默认行为。"
  (ebasecamp-ui-test--with-ui
    (should (= 0.26 ebasecamp-ui--split-ratio-default))
    ;; defcustom 默认值同源（`default-value' 取标准值，不受用例内 let 影响）
    (should (equal ebasecamp-ui--split-ratio-default
                   (default-value 'ebasecamp-ui--split-ratio)))
    ;; 无状态文件 → 回退常量
    (should-not (file-exists-p (ebasecamp-ui--ui-state-file)))
    (should (equal ebasecamp-ui--split-ratio-default
                   (ebasecamp-ui--load-ui-state)))
    ;; 无会话 → 回退常量
    (let ((ebasecamp-ui--session nil))
      (should (equal ebasecamp-ui--split-ratio-default
                     (ebasecamp-ui--current-split-ratio))))))

(ert-deftest ebasecamp-ui-test-set-split-ratio-updates-layout ()
  "`--set-split-ratio' 写会话 ref 后左栏变宽、右栏变窄；设回 0.26 复原。
ref 变化自然驱动 splitter 重渲染（`etaf-splitter' 的 `:ratio' 经
`etaf-ui--reactive-value' 追踪读取），这里不手动重建整棵树。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open)
        (let ((tree-default (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-tree))
              (detail-default (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-detail)))
          (should (equal 0.26 (ebasecamp-ui-test--split-ratio-current)))
          (should (integerp tree-default))
          (should (integerp detail-default))
          (ebasecamp-ui--set-split-ratio 0.4)
          (should (equal 0.4 (ebasecamp-ui-test--split-ratio-current)))
          (let ((tree (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-tree))
                (detail (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-detail)))
            ;; 左栏明显变宽、右栏变窄（同一次布局里两者互补）
            (should (> tree tree-default))
            (should (< detail detail-default))
            (should (equal (+ tree detail) (+ tree-default detail-default))))
          ;; 设回 0.26 → 几何完全复原
          (ebasecamp-ui--set-split-ratio 0.26)
          (should (equal tree-default (ebasecamp-ui-test--pane-bw
                                       'ebasecamp-ui-tree)))
          (should (equal detail-default (ebasecamp-ui-test--pane-bw
                                         'ebasecamp-ui-detail)))
          ;; 非数字输入被忽略（不写 ref、不 signal）
          (ebasecamp-ui--set-split-ratio "0.5")
          (should (equal 0.26 (ebasecamp-ui-test--split-ratio-current))))))))

(ert-deftest ebasecamp-ui-test-ui-state-roundtrip ()
  "`--set-split-ratio' → `--save-ui-state' → `--load-ui-state' 往返得 0.3。
文件内容必须是 `(:split-ratio 0.3)' 形态（用 `read' 校验，不比文本）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui--set-split-ratio 0.3)
    (ebasecamp-ui--save-ui-state)
    (let ((file (ebasecamp-ui--ui-state-file)))
      (should (file-exists-p file))
      ;; 路径落在 `ebasecamp-cache-directory' 下（运行时缓存，不是清单）
      (should (equal (expand-file-name "ui-state.el" ebasecamp-cache-directory)
                     file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (should (equal '(:split-ratio 0.3) (read (current-buffer)))))
      (should (equal 0.3 (ebasecamp-ui--load-ui-state)))
      ;; 新会话（`ebasecamp-ui--session' 置空后重建）载入 0.3
      (let ((ebasecamp-ui--session nil))
        (should (equal 0.3 (ebasecamp-ui-test--split-ratio-current)))
        ;; 同一临时目录里再存一次仍是 0.3（原子覆盖可重复执行）
        (ebasecamp-ui--save-ui-state)
        (should (equal 0.3 (ebasecamp-ui--load-ui-state)))))))

(ert-deftest ebasecamp-ui-test-ui-state-invalid-falls-back ()
  "状态文件缺失 / 非 plist / 越界 ratio 一律回退默认或钳制到 [0.15, 0.55]，
且**不得在渲染期 signal**（打开界面不报错）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((file (ebasecamp-ui--ui-state-file)))
        ;; ① 文件不存在
        (should-not (file-exists-p file))
        (should (equal 0.26 (ebasecamp-ui--load-ui-state)))
        ;; ② 非 plist / 非 `(:split-ratio NUMBER)' 形态 → 默认
        (dolist (content '("(foo)" "\"just a string\"" "(:other 1)"
                           "(:split-ratio \"0.3\")" "(:split-ratio nil)"
                           "" "(((" "#<marker>" ":split-ratio 0.3"))
          (ebasecamp-ui-test--write-ui-state content)
          (should (equal 0.26 (ebasecamp-ui--load-ui-state))))
        ;; ③ 越界 → 钳制到边界
        (ebasecamp-ui-test--write-ui-state "(:split-ratio 0.9)")
        (should (equal 0.55 (ebasecamp-ui--load-ui-state)))
        (ebasecamp-ui-test--write-ui-state "(:split-ratio -1)")
        (should (equal 0.15 (ebasecamp-ui--load-ui-state)))
        (ebasecamp-ui-test--write-ui-state "(:split-ratio 0.4)")
        (should (equal 0.4 (ebasecamp-ui--load-ui-state)))
        ;; 渲染期不 signal：三类非法文件各自打开一次界面都不报错，
        ;; 且会话 ref 落在 [0.15, 0.55] 内
        (dolist (content '("(:split-ratio 0.9)" "(:split-ratio -1)" "(foo)" ""))
          (ignore-errors (ebasecamp-ui-close))
          (ebasecamp-ui-test--write-ui-state content)
          (let ((ebox-viewport-height 20))
            (should (ebasecamp-ui-open)))
          (let ((ratio (ebasecamp-ui-test--split-ratio-current)))
            (should (numberp ratio))
            (should (<= 0.15 ratio 0.55)))
          (should (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-tree)))))))

;; 上面一组用例覆盖**状态文件**里的越界值；下面这条覆盖**defcustom** 本身被直接
;; `setq' 成越界值的情形 —— 用户 / 第三方配置 `(setq ebasecamp-ui--split-ratio 0.9)'
;; 后状态文件往往不存在，走的是 `--load-ui-state' 的 fallback 分支；若 fallback 原样
;; 返回 defcustom，越界值就进了 `etaf-splitter' 的 `:ratio'，渲染期 `etaf-check-prop'
;; signal，界面打不开。因此 fallback 分支也必须过 `--clamp-ratio'。

(ert-deftest ebasecamp-ui-test-split-ratio-defcustom-out-of-range-clamped ()
  "defcustom `ebasecamp-ui--split-ratio' 越界 / 非数字时读入即矫正，不进渲染。
三条路径：0.9 → 钳到上限 0.55；-1 → 钳到下限 0.15；\"0.3\"（非数字）→ 回退
默认 0.26。状态文件始终不存在（每个分支前删掉上一次 close 落盘的文件），
因此测的正是 fallback 分支。除了断言返回值，还要断言 `ebasecamp-ui-open'
不 signal 且会话 ref 与左栏实际宽度都落在 `[0.15, 0.55]' 内。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      ;; ① 越界上限：0.9 → 0.55
      (should-not (file-exists-p (ebasecamp-ui--ui-state-file)))
      (let ((ebasecamp-ui--split-ratio 0.9))
        (should (equal 0.55 (ebasecamp-ui--load-ui-state)))
        (let ((ebox-viewport-height 20))
          (should (ebasecamp-ui-open)))
        (let ((ratio (ebasecamp-ui-test--split-ratio-current)))
          (should (numberp ratio))
          (should (<= 0.15 ratio 0.55))
          (should (equal 0.55 ratio)))
        (let* ((tree (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-tree))
               (detail (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-detail))
               (total (+ tree detail 3)))
          (should (and (integerp tree) (integerp detail) (> total 0)))
          (should (<= 0.53 (/ (float tree) total) 0.57))))
      ;; ② 越界下限：-1 → 0.15（先删掉 ① 的 close 落盘的状态文件）
      (ignore-errors (ebasecamp-ui-close))
      (ignore-errors (delete-file (ebasecamp-ui--ui-state-file)))
      (should-not (file-exists-p (ebasecamp-ui--ui-state-file)))
      (let ((ebasecamp-ui--split-ratio -1))
        (should (equal 0.15 (ebasecamp-ui--load-ui-state)))
        (let ((ebox-viewport-height 20))
          (should (ebasecamp-ui-open)))
        (should (equal 0.15 (ebasecamp-ui-test--split-ratio-current)))
        (let* ((tree (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-tree))
               (detail (ebasecamp-ui-test--pane-bw 'ebasecamp-ui-detail))
               (total (+ tree detail 3)))
          (should (and (integerp tree) (integerp detail) (> total 0)))
          (should (<= 0.13 (/ (float tree) total) 0.17))))
      ;; ③ 非数字："0.3" → `--clamp-ratio' 返回 nil → 回退默认 0.26
      (ignore-errors (ebasecamp-ui-close))
      (ignore-errors (delete-file (ebasecamp-ui--ui-state-file)))
      (let ((ebasecamp-ui--split-ratio "0.3"))
        (should (equal 0.26 (ebasecamp-ui--load-ui-state)))
        (let ((ebox-viewport-height 20))
          (should (ebasecamp-ui-open)))
        (should (equal 0.26 (ebasecamp-ui-test--split-ratio-current))))
      (ignore-errors (ebasecamp-ui-close)))))

;;; N. 区域跳转（`1' / `2' / `3'）
;;
;; `ebasecamp-ui--focus-region' 把焦点移到三区域各自的**第一个停靠点**
;; （`etaf-focus-within'）。停靠点由 ebox 排序决定，**不保证**落在区域 Host
;; 本身（实测落点是区域内部的 `box' / 控件节点），因此断言一律用
;; 「焦点节点是否在该区域子树内」（`ebox-node-ancestor-p'），不断言具体控件 ——
;; 停靠点集合会随 etaf-ui 组件内部结构变化。
;;
;; 用例先在另一个区域落一次焦点再跳到目标区域：这样「焦点真的移动了」是被
;; 证明的，而不是「本来就巧合地在里面」。
;;
;; 注意 `--focused-within-p' 的返回值必须**全由祖先关系决定**：早先版本在
;; `or' 末尾多写了一个 `t'（永远返回 t），任何区域都能「通过」，红绿判定全部
;; 失效 —— 断言 `should-not (--focused-within-p 别的区域)' 才是这组用例的
;; 判别力来源，不要为「让它通过」把它改回去。

(defun ebasecamp-ui-test--focused-node ()
  "返回主界面 buffer 当前的焦点节点（`ebox-focused-node'，无焦点时为 nil）。"
  (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
    (ebox-focused-node)))

(defun ebasecamp-ui-test--focused-ref ()
  "返回主界面当前焦点节点的 Host ref（无焦点 / 无 runtime 时 nil）。
比对「焦点是否移动」一律用它，**不要**直接 `equal' 两个 `ebox-node' 节点对象：
节点带 parent 指针（圆形结构），`equal' 在大结构上既慢又不可靠；ref 形如
`(etaf-host N M)' 是普通列表，`equal' 语义稳定。"
  (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
    (when-let* ((node (ebox-focused-node))
                (runtime (etaf-runtime-for-buffer (current-buffer))))
      (etaf-runtime-node-host-ref runtime node))))

(defun ebasecamp-ui-test--expanded ()
  "返回会话的 `expanded' 值（树折叠状态的 key 列表）。"
  (etaf-value (ebasecamp-ui-session-expanded (ebasecamp-ui-session))))

(defun ebasecamp-ui-test--focused-within-p (ref)
  "返回非 nil 当焦点节点落在 REF 的子树内（含 REF 节点自身）。
主界面未挂载或没有焦点节点时返回 nil。"
  (let ((root (ebasecamp-ui-test--node ref))
        (focused (ebasecamp-ui-test--focused-node)))
    (and root focused
         (or (eq root focused)
             (ebox-node-ancestor-p root focused)))))

(ert-deftest ebasecamp-ui-test-focus-region-tree ()
  "`(ebasecamp-ui--focus-region 'tree)` 把焦点移进左树 `ebasecamp-ui-tree` 子树。
先跳右栏再跳左栏，证明焦点确实被移动（不是恰好落在树里）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open)
        (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/bulk")
        (ebasecamp-ui--focus-region 'detail)
        (should (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-detail))
        (ebasecamp-ui--focus-region 'tree)
        (should (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-tree))
        (should-not (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-detail))))))

(ert-deftest ebasecamp-ui-test-focus-region-detail ()
  "`(ebasecamp-ui--focus-region 'detail)` 把焦点移进右栏 `ebasecamp-ui-detail` 子树。
先跳左栏再跳右栏，证明焦点确实被移动。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open)
        (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/bulk")
        (ebasecamp-ui--focus-region 'tree)
        (should (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-tree))
        (ebasecamp-ui--focus-region 'detail)
        (should (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-detail))
        (should-not (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-tree))))))

(ert-deftest ebasecamp-ui-test-focus-region-footer ()
  "`(ebasecamp-ui--focus-region 'footer)` 把焦点移进底栏 `ebasecamp-ui-footer` 子树。
先跳左树再跳底栏，证明焦点确实被移动。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open)
        (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/bulk")
        (ebasecamp-ui--focus-region 'tree)
        (should (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-tree))
        (ebasecamp-ui--focus-region 'footer)
        (should (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-footer))
        (should-not (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-tree))))))

(ert-deftest ebasecamp-ui-test-focus-region-unknown-is-noop ()
  "未知区域 symbol 静默 no-op：不 signal、焦点不变。
无 etaf runtime 的 buffer 里调用同样静默返回 nil —— `--focus-region' 是
按键回调，任何路径都不该把错误抛到用户面前（`etaf-focus-within' 对不存在的
ref 会 `user-error'，必须被兜住）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open)
        (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/bulk")
        (ebasecamp-ui--focus-region 'footer)
        (let ((before (ebasecamp-ui-test--focused-node)))
          (should before)
          (should-not (condition-case err
                          (progn (ebasecamp-ui--focus-region 'nope) nil)
                        (error err)))
          (should (eq before (ebasecamp-ui-test--focused-node))))
        (with-temp-buffer
          (should-not (condition-case err
                          (ebasecamp-ui--focus-region 'tree)
                        (error err))))))))

(ert-deftest ebasecamp-ui-test-focus-region-keys-bound ()
  "`1' / `2' / `3' 都绑到了真实命令（非 nil、非 `#'ignore'），且按键真的跳转。
`ignore' 是 `:key-scope 'local' 对**未绑定** printing key 的兜底（ADR-0003），
因此「非 ignore」正是「该键已绑定」的判据。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--wide-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 20))
        (ebasecamp-ui-open)
        (ebasecamp-ui--select-key (ebasecamp-ui-session) "group/bulk")
        (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
          (dolist (event (list [?1] [?2] [?3]))
            (let ((binding (etaf--keys-binding event)))
              (should binding)
              (should-not (eq binding #'ignore))
              (should (commandp binding))))
          ;; 端到端：按键真的把焦点送进对应区域
          (execute-kbd-macro (kbd "1"))
          (should (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-tree))
          (execute-kbd-macro (kbd "2"))
          (should (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-detail))
          (execute-kbd-macro (kbd "3"))
          (should (ebasecamp-ui-test--focused-within-p 'ebasecamp-ui-footer)))))))

;;; 批次 P：项目上下文默认定位
;;
;; 三条用例覆盖 P1 契约（`ebasecamp-ui--project-for-directory' +
;; `ebasecamp-ui--first-group-for-project' + `ebasecamp-ui--new-session'）：
;; 1. 在项目 A 的子目录里打开 → 选中 A 的第一份配置所在组（redis）。清单里 A 的组
;;    **排在第二个**，所以「恰好选中第一个组」的实现过不了这条（判别力来源）；
;; 2. `default-directory` 不在任何项目 root 下 → 回退**既有行为：无选中组**
;;    （右栏「选择左侧的组」，`n' 落到第一个组）。刻意不改这条既有行为：界面在
;;    任意目录打开都自动选中第一个组等于删掉「未选中」态，且会让
;;    `render-no-selected-group-shows-placeholder' 等占位断言集体失效；
;; 3. 项目 A 存在但没有任何组的 `:configs` 引用它 → 同样回退，且不 signal。
;;
;; 项目 `:root' 必须在运行时按临时目录构造，而 `ebasecamp-define-project` 是宏
;; （ARGS 整体被 quote，表达式不求值），因此清单里先定义项目，再用公开访问器
;; `ebasecamp-project-root' 的 `setf' 写入临时目录 —— 模型注册表保存的是同一个
;; 对象，`ebasecamp-model-projects' 只是浅拷贝列表。

(defmacro ebasecamp-ui-test--with-project-roots (a b &rest body)
  "把 A / B 绑定到两个新建的临时项目目录（均带尾斜杠，A 下含 src/ 子目录），执行 BODY。
结束（含异常）时递归删除这两个目录的公共父目录。"
  (declare (indent 2) (debug t))
  `(let* ((base (file-name-as-directory (make-temp-file "ebasecamp-ui-proj-" t)))
          (,a (expand-file-name "a/" base))
          (,b (expand-file-name "b/" base)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "src/" ,a) t)
           (make-directory ,b t)
           ,@body)
       (ignore-errors (delete-directory base t)))))

(defun ebasecamp-ui-test--project-roots-manifest (root-a root-b)
  "定义项目 a（root ROOT-A）/ b（root ROOT-B）与两个 per-project 组。
组顺序刻意让项目 a 的组**排在后面**：mysql（配置 dev → 项目 b）在前，
redis（配置 cache → 项目 a）在后。"
  (ebasecamp-define-project a :title "项目 A" :groups nil)
  (ebasecamp-define-project b :title "项目 B" :groups nil)
  (setf (ebasecamp-project-root (ebasecamp-model-project 'a))
        (directory-file-name root-a)
        (ebasecamp-project-root (ebasecamp-model-project 'b))
        (directory-file-name root-b))
  (ebasecamp-define-group mysql
    :title "MySQL"
    :scope per-project
    :services ((mysql :image "mysql:8.4"))
    :configs ((dev :project b)))
  (ebasecamp-define-group redis
    :title "Redis"
    :scope per-project
    :services ((redis :image "redis:7"))
    :configs ((cache :project a))))

(ert-deftest ebasecamp-ui-test-open-selects-project-group ()
  "在项目 A 的子目录里打开界面 → 默认选中 A 的第一份配置所在组（redis）。
A 的组在组顺序里排第二（mysql 在前），因此「选第一个组」的实现过不了本用例。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--with-project-roots a b
      (ebasecamp-ui-test--project-roots-manifest a b)
      (ebasecamp-ui-test--with-ps nil
        (let ((default-directory (file-name-as-directory
                                  (expand-file-name "src" a))))
          (ebasecamp-ui-open))
        (should (eq 'redis (ebasecamp-ui-test--selected-group)))
        ;; state 的 :selected 必须与 ref 同步（右栏段按 state 渲染）
        (should (equal "redis"
                       (plist-get (etaf-value (ebasecamp-ui-session-state
                                               (ebasecamp-ui-session)))
                                  :selected)))))))

(ert-deftest ebasecamp-ui-test-open-falls-back-when-no-project ()
  "`default-directory` 不在任何项目 root 下 → 无项目命中，回退既有行为（无选中组）。
判别力来自函数级断言（`--project-for-directory` 必须返回 nil）加打开后的
`selected-group` 仍为 nil：右栏显示「选择左侧的组」，`n` 从第一个组 mysql 开始。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--with-project-roots a b
      (ebasecamp-ui-test--project-roots-manifest a b)
      (ebasecamp-ui-test--with-ps nil
        (let ((default-directory (expand-file-name temporary-file-directory)))
          (should-not (ebasecamp-ui--project-for-directory default-directory))
          (ebasecamp-ui-open)
          (should-not (ebasecamp-ui-test--selected-group))
          (let ((state (etaf-value (ebasecamp-ui-session-state
                                    (ebasecamp-ui-session)))))
            (should-not (plist-get state :selected))
            (should (eq 'mysql (car (ebasecamp-ui--group-names state)))))
          (should (ebasecamp-ui-test--contains-p
                   (ebasecamp-ui-test--buffer-text) "选择左侧的组")))))))

(ert-deftest ebasecamp-ui-test-open-falls-back-when-project-has-no-config ()
  "项目 A 存在但没有任何组的 `:configs` 引用它 → 回退（无选中组），且不 signal。
项目命中链路是「DIR → 项目 → 该项目的第一份配置 → 组」，第二跳落空时必须静默
回退，不能把 `user-error` 抛到打开界面的用户面前。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--with-project-roots a b
      (ebasecamp-define-project a :title "项目 A" :groups nil)
      (ebasecamp-define-project b :title "项目 B" :groups nil)
      (setf (ebasecamp-project-root (ebasecamp-model-project 'a))
            (directory-file-name a)
            (ebasecamp-project-root (ebasecamp-model-project 'b))
            (directory-file-name b))
      (ebasecamp-define-group mysql
        :title "MySQL"
        :scope per-project
        :services ((mysql :image "mysql:8.4"))
        :configs ((dev :project b)))
      (ebasecamp-ui-test--with-ps nil
        (let ((default-directory (file-name-as-directory
                                  (expand-file-name "src" a))))
          ;; 第一跳命中项目 a，第二跳（a 的配置）落空
          (should (eq 'a (ebasecamp-project-name
                          (ebasecamp-ui--project-for-directory default-directory))))
          (should-not (ebasecamp-ui--first-group-for-project 'a))
          (should-not (condition-case err
                          (progn (ebasecamp-ui-open) nil)
                        (error err)))
          (should-not (ebasecamp-ui-test--selected-group)))))))

;;; 19. 清单写操作（W4：服务编辑 dialog + `E` / `M` / `X`）
;;
;; W0.3 实测的三条硬约束决定了这一节的断言形态：
;; 1. `etaf-dialog` 的 buffer 文本**永远不含** dialog 内容（root-layer 投影）→
;;    断言只能落在**组件 ref / 回调 / 停靠点**上，不能断言 `buffer-string`；
;; 2. `:ref` 只接受 symbol / function / nil（传 `etaf-ref` 对象会报错）→ 字段用
;;    `:bind`，按钮用 symbol ref；
;; 3. `slot :name 'footer` 必须是 dialog 的**直接子项**（嵌在 column 里会报
;;    `Unresolved View item: footer`）。
;;
;; 四个写命令（`S` / `E` / `M` / `X`）一律**直接调用命令函数**而不是 `execute-kbd-macro`：
;; 命令内部走 `etaf-call-with-input'，在事件回调上下文里它会真的去开 minibuffer，
;; batch 下会挂住。键位本身的可达性由 `write-keys-bound' 单独断言。

(defun ebasecamp-ui-test--write-manifest ()
  "W4 用的清单：组 mysql（1 份配置 dev → myapp、2 个服务，字段齐全）+ 组 redis。
两个组的配置都指向已定义项目，服务名 `write-svc' / `write-ro' 在界面文本里唯一
（不会与镜像列的 `mysql:8.4' 串匹配）。"
  (ebasecamp-define-group mysql
    :title "MySQL"
    :scope per-project
    :services ((write-svc :image "mysql:8.4"
                          :ports ((3307 . 3306))
                          :environment (("MYSQL_ROOT_PASSWORD" . "${DB_PASSWORD}")
                                        ("TZ" . "Asia/Shanghai"))
                          :volumes ((:source "./data" :target "/var/lib/mysql"
                                     :type bind))
                          :command ("mysqld" "--max-connections=200")
                          :restart "unless-stopped")
               (write-ro :image "mysql:8.4"))
    :configs ((dev :project myapp)))
  (ebasecamp-define-group redis
    :title "Redis"
    :scope per-project
    :services ((redis :image "redis:7"))
    :configs ((cache :project other)))
  (ebasecamp-define-project myapp :title "示例项目" :groups nil)
  (ebasecamp-define-project other :title "另一项目" :groups nil))

(defun ebasecamp-ui-test--goto-service (name)
  "把 point 移到服务表里服务名 NAME 的单元格上（**非** checkbox 单元格）。
镜像列会把 `mysql:8.4' 截断成 `mysql:8'，因此用服务名定位不受列宽影响。"
  (goto-char (point-min))
  (search-forward name)
  (backward-char 2))

(defun ebasecamp-ui-test--editor ()
  "返回服务编辑 dialog 的 ref 注册表（组件 `:bindings' 写入）；未挂载时返回 nil。"
  ebasecamp-ui--service-editor)

(defun ebasecamp-ui-test--editor-value (key)
  "返回服务编辑 dialog 注册表里 KEY 对应 ref 的当前值。"
  (etaf-value (plist-get (ebasecamp-ui-test--editor) key)))

(ert-deftest ebasecamp-ui-test-service-dialog-prefills ()
  "`S' 打开服务编辑框：6 个字段 ref 等于该服务的现有字段（多行字段保留换行）。
dialog 内容不落 buffer（W0.3 实测），因此断言只读 ref 值。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (should-not (ebasecamp-ui-test--editor-value :open))
          (ebasecamp-ui-test--goto-service "write-svc")
          (ebasecamp-ui--open-service-editor)
          (should (ebasecamp-ui-test--editor-value :open))
          (should (equal "mysql:8.4"
                         (ebasecamp-ui-test--editor-value :image)))
          (should (equal "3307:3306"
                         (ebasecamp-ui-test--editor-value :ports)))
          (should (equal (concat "MYSQL_ROOT_PASSWORD=${DB_PASSWORD}\n"
                                 "TZ=Asia/Shanghai")
                         (ebasecamp-ui-test--editor-value :environment)))
          (should (equal "./data:/var/lib/mysql"
                         (ebasecamp-ui-test--editor-value :volumes)))
          (should (equal "mysqld\n--max-connections=200"
                         (ebasecamp-ui-test--editor-value :command)))
          (should (equal "unless-stopped"
                         (ebasecamp-ui-test--editor-value :restart)))
          (should-not (ebasecamp-ui-test--editor-value :error))
          ;; 保存/取消按钮的 symbol ref 已渲染成 Host（ref 只接受 symbol）
          (let ((runtime (etaf-runtime-for-buffer
                          (get-buffer ebasecamp-ui-buffer-name))))
            (should (etaf-runtime-host-node
                     runtime 'ebasecamp-ui-service-save))
            (should (etaf-runtime-host-node
                     runtime 'ebasecamp-ui-service-cancel))))))))

(ert-deftest ebasecamp-ui-test-service-dialog-save-writes ()
  "改一个字段后保存：写盘函数收到 (组名 服务名 字段alist)，其中**只**含改动的字段；
成功后 dialog 关闭并重载清单。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (calls nil)
            (reloads 0))
        (ebasecamp-ui-test--with-open-ui
          (ebasecamp-ui-test--goto-service "write-svc")
          (ebasecamp-ui--open-service-editor)
          (cl-letf (((symbol-function
                      'ebasecamp-config-write-update-service-fields)
                     (lambda (group service fields)
                       (push (list group service fields) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () (cl-incf reloads) nil)))
            (etaf-set-value (plist-get (ebasecamp-ui-test--editor) :ports)
                            "3308:3306")
            (ebasecamp-ui--service-dialog-save)
            (should (= 1 (length calls)))
            (should (equal '("mysql" "write-svc" (:ports ((3308 . 3306))))
                           (car calls)))
            (should-not (ebasecamp-ui-test--editor-value :open))
            (should (= 1 reloads))))))))

(ert-deftest ebasecamp-ui-test-service-dialog-invalid-keeps-open ()
  "端口填非法值后保存：dialog **保持打开**、error ref 非空、写盘函数未被调用。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (calls 0))
        (ebasecamp-ui-test--with-open-ui
          (ebasecamp-ui-test--goto-service "write-svc")
          (ebasecamp-ui--open-service-editor)
          (cl-letf (((symbol-function
                      'ebasecamp-config-write-update-service-fields)
                     (lambda (&rest _) (cl-incf calls))))
            (etaf-set-value (plist-get (ebasecamp-ui-test--editor) :ports)
                            "abc")
            (ebasecamp-ui--service-dialog-save)
            (should (ebasecamp-ui-test--editor-value :open))
            (let ((error-text (ebasecamp-ui-test--editor-value :error)))
              (should (stringp error-text))
              (should (string-match-p "第 1 行" error-text)))
            (should (= 0 calls))
            ;; 改回合法值再保存：error 被清掉且真正写盘
            (etaf-set-value (plist-get (ebasecamp-ui-test--editor) :ports)
                            "3307:3306")
            (ebasecamp-ui--service-dialog-save)
            (should-not (ebasecamp-ui-test--editor-value :error))))))))

(ert-deftest ebasecamp-ui-test-x-menu-dispatch ()
  "`X' 清单操作菜单：选「新建配置」后依次收集配置名与项目，派发到 `-add-config'。
`completing-read' 按顺序返回菜单项 / 配置名 / 项目名（全部经
`etaf-call-with-input' 收集，与既有 `I' / `o' 一致）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (answers '("新建配置" "prod" "myapp"))
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (pop answers)))
                    ((symbol-function 'ebasecamp-config-write-add-config)
                     (lambda (group config project &optional _migrate)
                       (push (list group config project) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--manifest-menu)
            (should (equal '(("mysql" "prod" myapp)) calls))
            (should-not answers)))))))

(ert-deftest ebasecamp-ui-test-move-config-prompts ()
  "`M' 移动配置：先选目标组再选目标项目，派发到 `-move-config' 的
`(源组 配置 目标组 项目)'。源配置取选中组里唯一的配置（不额外提问）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (answers '("redis" "myapp"))
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (pop answers)))
                    ((symbol-function 'ebasecamp-config-write-move-config)
                     (lambda (from config to project)
                       (push (list from config to project) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--move-config)
            (should (equal '(("mysql" "dev" "redis" myapp)) calls))
            (should-not answers)))))))

(ert-deftest ebasecamp-ui-test-write-keys-bound ()
  "四个写操作键 `S' / `E' / `M' / `X' 都已进入根 Host 的 `:keys'（不是 `ignore'）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (dolist (key '(?S ?E ?M ?X))
            (let ((binding (etaf--keys-binding (vector key))))
              (should binding)
              (should-not (eq binding #'ignore)))))))))

;;; 批次 4（A-II）：旧 :groups 迁移的用户确认（写盘层绝不静默）

;; UI 是唯一的触发点：两个入口（`X' → 新建配置、`E' → 改配置关联项目）在调用
;; 写盘前用 `ebasecamp-config-write--legacy-reference-file' 检测旧引用，命中才
;; `y-or-n-p'；答 yes 传 `migrate-legacy' = t，答 no 传 nil（仍成功，走 A-I 兼容
;; 路径，下次再提示）。
;;
;; 测试用 `cl-letf' 打桩三处：
;; - `ebasecamp-config-write--legacy-reference-file'：UI 测试的清单是内存定义
;;   （`ebasecamp-define-group'/`-project'），磁盘上没有 `projects/*.el'，真实现
;;   必然返回 nil；打桩让它命中，从而验证 UI 的确认与传参逻辑本身；
;; - `y-or-n-p'：记录是否被问、返回 t / nil；
;; - 写盘入口：捕获实参（含第 4 参 migrate-legacy）。

(ert-deftest ebasecamp-ui-test-x-new-config-asks-before-migrating-legacy ()
  "「新建配置」命中旧引用 → 问一次 `y-or-n-p'；答 yes 时写盘第 4 参为非 nil。
确认文案照抄计划（项目名 / 组名 / 「旧写法 :groups」/「接管」）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (answers '("新建配置" "prod" "myapp"))
            (asked nil)
            (lookups nil)
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (pop answers)))
                    ((symbol-function 'y-or-n-p)
                     (lambda (prompt) (push prompt asked) t))
                    ((symbol-function
                      'ebasecamp-config-write--legacy-reference-file)
                     (lambda (project group)
                       (push (list project group) lookups)
                       (list "/tmp/legacy/demo.el" :start 1 :end 2)))
                    ((symbol-function 'ebasecamp-config-write-add-config)
                     (lambda (group config project &optional migrate)
                       (push (list group config project migrate) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--manifest-menu)
            ;; 查询按 `(项目 组)' 顺序，且只问一次
            (should (equal '((myapp "mysql")) lookups))
            (should (= 1 (length asked)))
            (should (string-match-p "项目 myapp" (car asked)))
            (should (string-match-p "组 mysql" (car asked)))
            (should (string-match-p "旧写法 :groups" (car asked)))
            (should (string-match-p "接管" (car asked)))
            (should (string-match-p "是否同时删掉" (car asked)))
            ;; 写盘第 4 参为非 nil
            (should (= 1 (length calls)))
            (should (equal '("mysql" "prod" myapp) (butlast (car calls))))
            (should (nth 3 (car calls)))
            (should-not answers)))))))

(ert-deftest ebasecamp-ui-test-x-new-config-declines-migration ()
  "答 no → 写盘第 4 参为 nil，流程仍成功（无 error notice）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (answers '("新建配置" "prod" "myapp"))
            (asked 0)
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (pop answers)))
                    ((symbol-function 'y-or-n-p)
                     (lambda (_prompt) (cl-incf asked) nil))
                    ((symbol-function
                      'ebasecamp-config-write--legacy-reference-file)
                     (lambda (&rest _) (list "/tmp/legacy/demo.el" :start 1)))
                    ((symbol-function 'ebasecamp-config-write-add-config)
                     (lambda (group config project &optional migrate)
                       (push (list group config project migrate) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--manifest-menu)
            (should (= 1 asked))
            (should (= 1 (length calls)))
            (should-not (nth 3 (car calls)))
            ;; 流程成功：notice 不是 error
            (let ((notice (ebasecamp-ui-test--notice)))
              (should-not (eq 'error (plist-get notice :kind))))
            (should-not answers)))))))

(ert-deftest ebasecamp-ui-test-e-editor-asks-before-migrating-legacy ()
  "`E'（`--open-config-editor'）命中旧引用 → 问一次 `y-or-n-p'，答 yes 时
`-update-config-project' 的第 4 参为非 nil。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (answers '("myapp"))
            (asked nil)
            (lookups nil)
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (pop answers)))
                    ((symbol-function 'y-or-n-p)
                     (lambda (prompt) (push prompt asked) t))
                    ((symbol-function
                      'ebasecamp-config-write--legacy-reference-file)
                     (lambda (project group)
                       (push (list project group) lookups)
                       (list "/tmp/legacy/demo.el" :start 1 :end 2)))
                    ((symbol-function
                      'ebasecamp-config-write-update-config-project)
                     (lambda (group config project &optional migrate)
                       (push (list group config project migrate) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--open-config-editor)
            (should (equal '((myapp "mysql")) lookups))
            (should (= 1 (length asked)))
            (should (string-match-p "项目 myapp" (car asked)))
            (should (= 1 (length calls)))
            (should (equal '("mysql" dev myapp) (butlast (car calls))))
            (should (nth 3 (car calls)))
            (should-not answers)))))))

;;; 批次 2（v0.5.3 计划 B 节）：项目 `:root' 可选的界面入口
;;
;; 三条约束决定了断言形态：
;; 1. `--read-name' 与 `--read-optional-path' 内部都调 `--prompt'，同一分支会
;;    连续调 3 次（name / title / root）→ 打桩 `--prompt' 时按 **prompt 文案**取
;;    答案（`ebasecamp-ui-test--prompt-reply'），不按调用序号（顺序会随实现微调漂移）；
;; 2. 「新建项目」的后果说明写在 prompt 文案里，不用 `message'（`--after-write' 会
;;    先发 success notice 再 `ebasecamp-reload'，`message' 会被覆盖）→ 断言落在
;;    **收集到的 prompt 串**上；
;; 3. `--confirm' 答 no 时抛 `user-error'，但 `--manifest-menu' 的
;;    `condition-case' 会把它转成 error notice（docstring 明写的契约）→ 拒绝路径的
;;    断言落在 notice 文案（含「取消」）与「写盘零调用」上，而不是 `should-error'。

(defun ebasecamp-ui-test--prompt-reply (prompt table)
  "按 PROMPT 文案从 TABLE 取一个答案。
TABLE 是有序的 (正则 . 值) 列表：第一条正则匹配 PROMPT 者生效；`(t . 值)' 作兜底。
未命中且无兜底时 `error' —— 避免打桩静默返回 nil 让用例误绿。"
  (let ((pair (cl-find-if (lambda (cell)
                            (or (eq t (car cell))
                                (and (stringp (car cell))
                                     (string-match-p (car cell) prompt))))
                          table)))
    (if pair
        (cdr pair)
      (error "未预期的 prompt：%s" prompt))))

(ert-deftest ebasecamp-ui-test-read-optional-path ()
  "`--read-optional-path'：空 / 纯空白输入 → nil，带首尾空白的输入 → 去空白字符串。
与 `--read-name' 的「空即 user-error」形成对照（同一空输入 `--read-name' 会抛错），
这是本批次放开 `:root' 必填的核心语义差异。"
  (ebasecamp-ui-test--with-ui
    (let ((answer ""))
      (cl-letf (((symbol-function 'ebasecamp-ui--prompt)
                 (lambda (&rest _) answer)))
        (should-not (ebasecamp-ui--read-optional-path "项目根目录（可留空）： "))
        (setq answer "   ")
        (should-not (ebasecamp-ui--read-optional-path "项目根目录（可留空）： "))
        (setq answer "  /tmp/x  ")
        (should (equal "/tmp/x"
                       (ebasecamp-ui--read-optional-path "项目根目录（可留空）： ")))
        ;; 对照：同一空输入走 `--read-name' 必须 user-error（实体名仍必填）
        (setq answer "")
        (should-error (ebasecamp-ui--read-name "项目根目录： ") :type 'user-error)))))

(ert-deftest ebasecamp-ui-test-x-new-project-allows-empty-root ()
  "「新建项目」root 留空 → `-add-project' 第 3 参为 nil，且 root 的 prompt 文案
同时含「留空」「不参与目录定位」「导出需显式选路径」（后果说明在输入前即可见）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (prompts nil)
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'ebasecamp-ui--prompt)
                     (lambda (prompt &rest _)
                       (push prompt prompts)
                       (ebasecamp-ui-test--prompt-reply
                        prompt
                        '(("清单操作" . "新建项目")
                          ("新项目名" . "myapp")
                          ("项目标题" . "我的应用")
                          ("根目录" . "")))))
                    ((symbol-function 'ebasecamp-config-write-add-project)
                     (lambda (name title root)
                       (push (list name title root) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--manifest-menu)
            ;; 写盘第 3 参（root）为 nil
            (should (= 1 (length calls)))
            (should (equal '("myapp" "我的应用" nil) (car calls)))
            (should-not (nth 2 (car calls)))
            ;; 含「留空」的那一条 prompt 同时含后果说明
            (let ((root-prompt (cl-find-if (lambda (p) (string-match-p "留空" p))
                                           prompts)))
              (should root-prompt)
              (should (string-match-p "不参与目录定位" root-prompt))
              (should (string-match-p "导出需显式选路径" root-prompt)))
            ;; 写操作后不再用 `message' 提示（`--after-write' 的 notice 才是唯一通道）
            (should (eq 'success
                        (plist-get (ebasecamp-ui-test--notice) :kind)))))))))

(ert-deftest ebasecamp-ui-test-x-edit-project-clears-root ()
  "「改项目」：项目原本有 root、root 输入为空 → 先 `--confirm'（答 yes）→
`-update-project' 收到 `(项目 title nil t)'（root nil + `clear-root' 非 nil）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (setf (ebasecamp-project-root (ebasecamp-model-project 'myapp)) "/srv/myapp")
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (asked nil)
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'ebasecamp-ui--prompt)
                     (lambda (prompt &rest _)
                       (ebasecamp-ui-test--prompt-reply
                        prompt
                        '(("清单操作" . "改项目")
                          ("要改的项目" . "myapp")
                          ("新标题" . "示例项目")
                          ("根目录" . "")))))
                    ((symbol-function 'y-or-n-p)
                     (lambda (prompt) (push prompt asked) t))
                    ((symbol-function 'ebasecamp-config-write-update-project)
                     (lambda (name title root &optional clear-root)
                       (push (list name title root clear-root) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--manifest-menu)
            ;; 问了一次，文案照抄计划（项目名 / :root / 三条后果）
            (should (= 1 (length asked)))
            (should (string-match-p "清空项目 myapp 的 :root" (car asked)))
            (should (string-match-p "不再按目录定位" (car asked)))
            (should (string-match-p "导出须显式选路径" (car asked)))
            (should (string-match-p "降级为警告" (car asked)))
            ;; 第 3 参 nil + 第 4 参非 nil
            (should (= 1 (length calls)))
            (should (equal '(myapp "示例项目" nil t) (car calls)))))))))

(ert-deftest ebasecamp-ui-test-x-edit-project-clear-root-declined ()
  "同上但答 no → 流程以 error notice「已取消」收尾，`-update-project' **零调用**。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (setf (ebasecamp-project-root (ebasecamp-model-project 'myapp)) "/srv/myapp")
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (asked 0)
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'ebasecamp-ui--prompt)
                     (lambda (prompt &rest _)
                       (ebasecamp-ui-test--prompt-reply
                        prompt
                        '(("清单操作" . "改项目")
                          ("要改的项目" . "myapp")
                          ("新标题" . "示例项目")
                          ("根目录" . "")))))
                    ((symbol-function 'y-or-n-p)
                     (lambda (_prompt) (cl-incf asked) nil))
                    ((symbol-function 'ebasecamp-config-write-update-project)
                     (lambda (name title root &optional clear-root)
                       (push (list name title root clear-root) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--manifest-menu)
            (should (= 1 asked))
            ;; 确认在写盘前：答 no 时写盘零调用
            (should-not calls)
            ;; `--confirm' 的 user-error 被菜单的 condition-case 转成 error notice
            (let ((notice (ebasecamp-ui-test--notice)))
              (should (eq 'error (plist-get notice :kind)))
              (should (string-match-p
                       "取消"
                       (or (plist-get notice :message)
                           (plist-get notice :title)
                           ""))))))))))

(ert-deftest ebasecamp-ui-test-x-edit-project-empty-root-stays-empty ()
  "项目原本就无 root、root 输入为空 → **不弹**确认（幂等），
`-update-project' 收到 `(项目 title nil nil)'（第 4 参 nil，不触发清空分支）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (should-not (ebasecamp-project-root (ebasecamp-model-project 'myapp)))
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (asked 0)
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'ebasecamp-ui--prompt)
                     (lambda (prompt &rest _)
                       (ebasecamp-ui-test--prompt-reply
                        prompt
                        '(("清单操作" . "改项目")
                          ("要改的项目" . "myapp")
                          ("新标题" . "示例项目")
                          ("根目录" . "")))))
                    ((symbol-function 'y-or-n-p)
                     (lambda (_prompt) (cl-incf asked) t))
                    ((symbol-function 'ebasecamp-config-write-update-project)
                     (lambda (name title root &optional clear-root)
                       (push (list name title root clear-root) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--manifest-menu)
            (should (= 0 asked))
            (should (= 1 (length calls)))
            (should (equal '(myapp "示例项目" nil nil) (car calls)))
            (should-not (nth 3 (car calls)))))))))

;;; 批次 4.3（目检缺陷 A）：界面向写盘层传的 scope 必须是符号

;; `ebasecamp-ui--scope-choices' 是字符串表（`completing-read' 只接受字符串），
;; 而模型层与写盘层用符号比对（`ebasecamp-model--scopes' + `memq'）。界面若不转换，
;; `memq' 恒 nil → 写盘前就报「组 scope 必须是 shared 或 per-project，得到
;; \"per-project\"」，groups.el 永远建不出来。两个入口（新建组 / 改组）都必须转换。

(ert-deftest ebasecamp-ui-test-x-new-group-passes-symbol-scope ()
  "「新建组」：`completing-read' 返回的字符串 scope 必须先转成符号再进写盘层。
断言 `-add-group' 第 3 参是符号 `shared'（不是字符串 \"shared\"），且流程以成功
notice 收尾（即缺陷现象「写盘前报 scope 非法」已消失）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'ebasecamp-ui--prompt)
                     (lambda (prompt &rest _)
                       (ebasecamp-ui-test--prompt-reply
                        prompt
                        '(("清单操作" . "新建组")
                          ("新组名" . "cache")
                          ("组标题" . "Cache")
                          ("scope" . "shared")))))
                    ((symbol-function 'ebasecamp-config-write-add-group)
                     (lambda (name title scope)
                       (push (list name title scope) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--manifest-menu)
            (should (= 1 (length calls)))
            ;; 第 1、2 参仍是字符串（名字与标题不转换）
            (should (equal '("cache" "Cache") (butlast (car calls))))
            ;; 第 3 参：符号（`eq' 而非 `equal' —— 缺陷正是符号/字符串不匹配）
            (should (eq 'shared (nth 2 (car calls))))
            (should (symbolp (nth 2 (car calls))))
            (should (eq 'success
                        (plist-get (ebasecamp-ui-test--notice) :kind)))))))))

(ert-deftest ebasecamp-ui-test-x-edit-group-passes-symbol-scope ()
  "「改组」：scope 打桩返回字符串 \"per-project\" → `-update-group' 收到符号
`per-project'。改组是另一条独立分支（含 `initial' 取当前 scope 的 `symbol-name'），
必须与新建组同样转换。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--write-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40)
            (calls nil))
        (ebasecamp-ui-test--with-open-ui
          (cl-letf (((symbol-function 'ebasecamp-ui--prompt)
                     (lambda (prompt &rest _)
                       (ebasecamp-ui-test--prompt-reply
                        prompt
                        '(("清单操作" . "改组")
                          ("新标题" . "MySQL 8.4")
                          ("scope" . "per-project")))))
                    ((symbol-function 'ebasecamp-config-write-update-group)
                     (lambda (name title scope)
                       (push (list name title scope) calls)))
                    ((symbol-function 'ebasecamp-reload)
                     (lambda () nil)))
            (ebasecamp-ui--manifest-menu)
            (should (= 1 (length calls)))
            ;; 选中组 mysql（`--with-open-ui' 已选中），名字仍是字符串
            (should (equal '("mysql" "MySQL 8.4") (butlast (car calls))))
            (should (eq 'per-project (nth 2 (car calls))))
            (should (symbolp (nth 2 (car calls))))
            (should (eq 'success
                        (plist-get (ebasecamp-ui-test--notice) :kind)))))))))

;;; 批次 1（v0.6 计划「设计决策 A」）：按钮旁显示键
;;
;; 键提示在 `--footer-button' / `--section-button' **内部**拼接，`label' 参数
;; 值不变 —— 因此 `--goto-section' 的 `search-forward "启动选中"' 锚点与段内
;; 替身的 label 断言都不破。这里分开守护两件事：
;; 1. 渲染：底栏 / 段头六个按钮的文本里出现 `[KEY] ' 前缀且原文案仍在；
;; 2. 不漂移：`--button-key-hints' 的每个 KEY 都真存在于键表，且按钮文案与
;;    键表 LABEL 指向同一动作（不是两处各写一遍、互不相干）。

(defun ebasecamp-ui-test--label-subsequence-p (short long)
  "SHORT 的每个字符都按顺序出现在 LONG 中时返回 t，否则返回 nil。
用来表达「按钮文案与键表 LABEL 指向同一动作」：底栏两者逐字相同，段级键表
则在按钮文案中间**插入**了「该段」（`启动选中' → `启动该段选中'），所以关系
不是 `string-prefix-p'（`启动该段选中' 的第三个字符是「该」而非「选」），
而是「按序包含」。"
  (let ((start 0)
        (ok t))
    (dotimes (n (length short))
      (let ((pos (cl-position (aref short n) long :start start :test #'eq)))
        (if pos
            (setq start (1+ pos))
          (setq ok nil))))
    ok))

(ert-deftest ebasecamp-ui-test-footer-buttons-show-keys ()
  "底栏三个按钮的渲染文本同时含 `[I]' / `[o]' / `[D]' 与原文案。
键名取自 `--root-keys'（`I' 导入 compose / `o' 导出 compose / `D' 销毁环境），
每对断言都是「键提示存在 + 原文案仍在」两项——只断言键提示会让「文案被键
替换掉」也蒙混过关。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((text (cdr (ebasecamp-ui-test--render "group/mysql"))))
        (should (ebasecamp-ui-test--contains-p text "[I]"))
        (should (ebasecamp-ui-test--contains-p text "导入 compose"))
        (should (ebasecamp-ui-test--contains-p text "[o]"))
        (should (ebasecamp-ui-test--contains-p text "导出 compose"))
        (should (ebasecamp-ui-test--contains-p text "[D]"))
        (should (ebasecamp-ui-test--contains-p text "销毁环境"))))))

(ert-deftest ebasecamp-ui-test-section-buttons-show-keys ()
  "段头三个按钮的渲染文本同时含 `[s]' / `[x]' / `[r]' 与原文案。
键名取自 `--section-keys'（段级 `s' / `x' / `r' → start / stop / restart）。
只挂载 `--instance-section'（不动主界面 buffer），断言对象是按钮行的实际
渲染文本。"
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
             (instance (car (plist-get group :instances)))
             (text (ebasecamp-ui-test--mount-text
                    (ebasecamp-ui--instance-section session "mysql" instance))))
        (should (ebasecamp-ui-test--contains-p text "[s]"))
        (should (ebasecamp-ui-test--contains-p text "启动选中"))
        (should (ebasecamp-ui-test--contains-p text "[x]"))
        (should (ebasecamp-ui-test--contains-p text "停止选中"))
        (should (ebasecamp-ui-test--contains-p text "[r]"))
        (should (ebasecamp-ui-test--contains-p text "重启选中"))))))

(ert-deftest ebasecamp-ui-test-button-key-nil-keeps-label ()
  "KEY 省略（nil）时两个按钮的输出与原 LABEL **逐字节一致**（回归保护）。
既有调用方（以及第三方视图代码）可以继续只传原有参数；键提示只在显式传 KEY
时出现。`string-trim' 只去掉按钮渲染的横向留白，标签内部的空格（`导入 compose'）
原样保留。"
  (ebasecamp-ui-test--with-ui
    (let ((footer (string-trim
                   (ebasecamp-ui-test--mount-text
                    (ebasecamp-ui--footer-button "导入 compose" #'ignore))))
          (section (string-trim
                    (ebasecamp-ui-test--mount-text
                     (ebasecamp-ui--section-button "启动选中" 'start 'primary
                                                   nil nil)))))
      (should (equal "导入 compose" footer))
      (should-not (ebasecamp-ui-test--contains-p footer "["))
      (should (equal "启动选中" section))
      (should-not (ebasecamp-ui-test--contains-p section "[")))))

(ert-deftest ebasecamp-ui-test-button-key-hints-match-key-tables ()
  "`--button-key-hints' 的每个键都存在于键表，且按钮文案指向同一动作。
两条判据（防「键绑错」与「文案漂移」）：
① KEY 必须能在 `--root-keys' 或 `--section-keys' 里找到 —— 例如把导出写成
   `I'（与导入撞键）会在这里红；
② 命中条目的 LABEL 必须按序包含按钮文案 —— 按钮用短形式（`启动选中'），
   段级键表用长形式（`启动该段选中'），两者不是前缀关系，判据见
   `ebasecamp-ui-test--label-subsequence-p'。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let* ((instance (car (ebasecamp-ui-test--instances)))
             (tables (list (cons 'root (ebasecamp-ui--root-keys))
                           (cons 'section (ebasecamp-ui--section-keys
                                           "mysql" instance)))))
        (should ebasecamp-ui--button-key-hints)
        (dolist (hint ebasecamp-ui--button-key-hints)
          (let* ((label (car hint))
                 (key (cdr hint))
                 (hits (cl-loop for (scope . entries) in tables
                                append (cl-loop for entry in entries
                                                when (equal key (car entry))
                                                collect (cons scope (nth 2 entry))))))
            (should (stringp label))
            ;; 兜底：LABEL 非空 —— `--label-subsequence-p' 对空串恒真，
            ;; 空 LABEL 会让判据 ② 变成永远通过的空壳断言
            (should-not (string-empty-p label))
            (should (stringp key))
            ;; ① KEY 必须在某张键表里
            (should hits)
            ;; ② 每个命中条目的 LABEL 都要指向同一动作
            (dolist (hit hits)
              (should (ebasecamp-ui-test--label-subsequence-p
                       label (cdr hit))))))))))

;;; 批次 2（v0.6 计划「设计决策 B」）：hjkl 方向导航
;;
;; `j' / `k' 移动**焦点**（`etaf-direction' 的方向链路），选中组不变；
;; `h' / `l' 在树内先被 `etaf-tree' 分支节点的 `:on-direction' 消费
;; （left 收起 / right 展开），到边界才落回焦点移动。因此这里的断言分两类：
;; 1. 焦点移动：比较 `--focused-ref'（ref 是普通列表，`equal' 可靠）；
;; 2. 折叠状态：比较会话的 `expanded' ref。
;;
;; 焦点起点用 `--focus-region 'tree'：它落到树内第一个停靠点（实测是组节点的
;; 按钮），既保证 `h'/`l' 作用在分支节点上，也保证「焦点真的从别处移过来」。

(ert-deftest ebasecamp-ui-test-j-k-move-focus-not-selection ()
  "`j' 下移、`k' 上移焦点，且**选中组不变**。
这与 `n'/`p'（换组）是两套语义：`j'/`k' 只动焦点，不动 selected-group。
先 `--focus-region 'tree'` 把焦点送进树内第一个停靠点，再按 `j'：焦点 ref 必须
变化、选中组必须仍是 mysql；再按 `k' 回到原焦点（`up' 与 `down' 在同一列上
可逆，实测 ref 回到原值）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (ebasecamp-ui--focus-region 'tree)
          (let ((before (ebasecamp-ui-test--focused-ref))
                (group-before (ebasecamp-ui-test--selected-group)))
            (should before)
            (should (eq 'mysql group-before))
            (execute-kbd-macro (kbd "j"))
            (let ((after (ebasecamp-ui-test--focused-ref)))
              (should after)
              (should-not (equal before after))
              ;; `j' 不是换组键：选中组一个都不能变
              (should (eq group-before (ebasecamp-ui-test--selected-group))))
            (execute-kbd-macro (kbd "k"))
            (should (equal before (ebasecamp-ui-test--focused-ref)))
            (should (eq group-before (ebasecamp-ui-test--selected-group)))))))))

(ert-deftest ebasecamp-ui-test-h-l-toggle-tree-expansion ()
  "`h' 收起焦点所在的组、`l' 重新展开，折叠状态写回会话的 `expanded' ref。
默认清单里全部组默认展开（`--default-expanded'），因此断言顺序是
`h'（展开 → 收起）再 `l'（收起 → 展开）。折叠由 `etaf-tree' 分支节点的
`:on-direction' 消费（`left' → 收起 + `handled'、`right' → 展开 + `handled'），
焦点在折叠动作中**不动**；已展开时按 `l' 才外溢成焦点右移（下一用例之外，
本用例只守护树内折叠语义）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--section-manifest)
    (ebasecamp-ui-test--with-ps (ebasecamp-ui-test--section-containers)
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (ebasecamp-ui--focus-region 'tree)
          (let ((focused (ebasecamp-ui-test--focused-ref)))
            (should focused)
            (should (equal '("group/mysql") (ebasecamp-ui-test--expanded)))
            ;; h：组节点已展开 → 收起（焦点不动）
            (execute-kbd-macro (kbd "h"))
            (should-not (member "group/mysql" (ebasecamp-ui-test--expanded)))
            (should (equal focused (ebasecamp-ui-test--focused-ref)))
            ;; l：组节点已收起 → 重新展开（焦点仍不动）
            (execute-kbd-macro (kbd "l"))
            (should (equal '("group/mysql") (ebasecamp-ui-test--expanded)))
            (should (equal focused (ebasecamp-ui-test--focused-ref)))))))))

;;; 批次 3（v0.6 计划「设计决策 C」）：avy 跳转（`f'）
;;
;; `f' 收集三类候选（组 / 配置 / 服务行），每个候选映射到 buffer 位置后交给 avy
;; 显示字母提示；未安装 avy 时降级 `completing-read'。本组用例把三个环节都切开
;; 打桩，因此**不依赖 avy 是否安装**、也不依赖真实按键提示：
;; 1. 候选收集：`--avy-targets' 是纯函数（只读会话 state），断言名字与 key；
;; 2. avy 路径：打桩 `--avy-available-p' / `avy-process' / `--target-position'，
;;    断言候选是位置列表、选中后跳到对应 key；
;; 3. 降级路径：`--avy-available-p' 为 nil 时打桩 `--prompt'，断言问一次且跳转；
;; 4. 轮询暂停：打桩 `ebasecamp-status-stop' / `-start'，断言顺序与实参；
;; 5. 无可见目标：全部位置为 nil 时只 `message'，不 signal。
;;
;; 注意 `avy-process' 在 `make test' 的 load-path 里**不存在**（Makefile 的
;; load-path 不含 avy），所以打桩不能写成 `cl-letf' + `(symbol-function ...)'
;; —— 取旧值时 `cl-letf' 会对未定义函数 `void-function'。用
;; `ebasecamp-ui-test--stub'。

(defmacro ebasecamp-ui-test--stub (symbol function &rest body)
  "把 SYMBOL 的函数定义临时设为 FUNCTION 后执行 BODY，结束后恢复原状。
与 `cl-letf' + `(symbol-function SYMBOL)' 的差别：SYMBOL 原本**没有**函数定义
（例如未安装 avy 时的 `avy-process'）时也能用 —— `cl-letf' 保存旧值时会对
未定义符号 `void-function'。"
  (declare (indent 2) (debug (symbolp form body)))
  `(let ((had (fboundp ',symbol))
         (old (and (fboundp ',symbol) (symbol-function ',symbol))))
     (unwind-protect
         (progn (fset ',symbol ,function) ,@body)
       (if had (fset ',symbol old) (fmakunbound ',symbol)))))

(defun ebasecamp-ui-test--avy-manifest ()
  "批次 3 夹具：2 组 / 1 份配置 / 2 个服务行。
mysql（per-project，2 服务 + 1 份配置 dev → myapp）与 redis（per-project，
1 服务、未关联）。选中 mysql 后右栏只有一段、2 个服务行；redis 没有配置因此
不贡献服务行 —— 候选恰为「2 组 + 1 配置 + 2 行」。"
  (ebasecamp-define-group mysql
    :title "MySQL"
    :scope per-project
    :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))
               (mysql-ro :image "mysql:8.4"))
    :configs ((dev :project myapp)))
  (ebasecamp-define-group redis
    :title "Redis"
    :scope per-project
    :services ((redis :image "redis:7")))
  (ebasecamp-define-project myapp :title "示例项目" :groups nil))

(ert-deftest ebasecamp-ui-test-avy-targets-collect ()
  "`--avy-targets' 收集 2 组 + 1 配置 + 2 服务行，NAME 与 KEY 都是非空字符串。
NAME 是给 `completing-read' 与字母提示看的人类可读名：组用组名，配置用
\"组名/配置名\"（跨组同名配置不混淆），服务行用段内 key \"组名/服务名\"。
KEY 是跳转身份：组 / 配置为树 key（`--group-key' / `--config-key'），服务行为
`--instance-key'（`--target-position' 据此派生行 ref）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--avy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (let ((targets (ebasecamp-ui--avy-targets)))
            (should (= 5 (length targets)))
            (should (equal '("mysql" "redis" "mysql/dev"
                             "mysql/mysql" "mysql/mysql-ro")
                           (mapcar #'car targets)))
            (should (equal '("group/mysql" "group/redis" "config/mysql/dev"
                             "mysql/mysql" "mysql/mysql-ro")
                           (mapcar #'cdr targets)))
            (dolist (target targets)
              (should (stringp (car target)))
              (should-not (string-empty-p (car target)))
              (should (stringp (cdr target)))
              (should-not (string-empty-p (cdr target))))))))))

(ert-deftest ebasecamp-ui-test-f-uses-avy-when-available ()
  "`f' 在 avy 可用时调一次 `avy-process'，候选是非空的位置列表；选中后按 key 跳转。
位置由 `--target-position' 解析，这里打桩成 100/110/…（确定性）；`avy-process'
打桩成「选第一个候选」，`--jump-to' 打桩成记录 (KEY . POSITION)。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--avy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (let (calls jumped)
            (ebasecamp-ui-test--stub
                avy-process
                (lambda (candidates &optional _overlay-fn _cleanup-fn)
                  (push (copy-sequence candidates) calls)
                  (car candidates))
              (cl-letf (((symbol-function 'ebasecamp-ui--avy-available-p)
                         (lambda () t))
                        ((symbol-function 'ebasecamp-ui--target-position)
                         (let ((counter 100))
                           (lambda (_key)
                             (prog1 counter (setq counter (+ counter 10))))))
                        ((symbol-function 'ebasecamp-ui--jump-to)
                         (lambda (key &optional position)
                           (push (cons key position) jumped)
                           position)))
                (execute-kbd-macro (kbd "f"))))
            (should (= 1 (length calls)))
            (let ((candidates (car calls)))
              (should candidates)
              (should (= 5 (length candidates)))
              (should (cl-every #'integerp candidates))
              (should (equal '(100 110 120 130 140) candidates)))
            ;; avy 选中的是第一个候选位置 → 第一个候选（组 mysql）
            (should (equal '(("group/mysql" . 100)) jumped))))))))

(ert-deftest ebasecamp-ui-test-f-falls-back-to-completing-read ()
  "avy 不可用时降级 `completing-read'：问一次、候选为全部名字，选中后跳到对应 key。
打桩 `--prompt'（界面统一输入入口）返回第二类候选 \"mysql/dev\"，断言
`--jump-to' 收到配置的树 key —— 证明「名字 → key」的映射没有错位。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--avy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (let (prompts jumped)
            (cl-letf (((symbol-function 'ebasecamp-ui--avy-available-p)
                       (lambda () nil))
                      ((symbol-function 'ebasecamp-ui--prompt)
                       (lambda (prompt &optional collection _require-match _initial)
                         (push (list prompt collection) prompts)
                         "mysql/dev"))
                      ((symbol-function 'ebasecamp-ui--target-position)
                       (lambda (_key) 200))
                      ((symbol-function 'ebasecamp-ui--jump-to)
                       (lambda (key &optional position)
                         (push (cons key position) jumped)
                         position)))
              (execute-kbd-macro (kbd "f")))
            (should (= 1 (length prompts)))
            (should (string-match-p "跳转" (car (car prompts))))
            (should (equal '("mysql" "redis" "mysql/dev"
                             "mysql/mysql" "mysql/mysql-ro")
                           (cadr (car prompts))))
            (should (equal '(("config/mysql/dev" . 200)) jumped))))))))

(ert-deftest ebasecamp-ui-test-jump-pauses-status-polling ()
  "跳转期间暂停状态轮询，结束后按原状恢复。
`ebasecamp-status-stop' 会清空 `--tick-function'、`ebasecamp-status-start' 会立即
tick 一次（跑 `docker ps'），所以恢复必须把**先前保存的** tick-function 传回，
且只在原本 running 时才恢复。两条断言：①原本 running → 顺序 stop → start，
start 收到原 tick-function；②原本未 running → 既不 stop 也不 start。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--avy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (let (calls)
            (ebasecamp-ui-test--stub
                avy-process
                (lambda (candidates &optional _overlay-fn _cleanup-fn)
                  (car candidates))
              ;; ① 原本在轮询
              (cl-letf (((symbol-function 'ebasecamp-status-running-p)
                         (lambda () t))
                        ((symbol-function 'ebasecamp-status-stop)
                         (lambda () (push 'stop calls)))
                        ((symbol-function 'ebasecamp-status-start)
                         (lambda (function)
                           (push (list 'start function) calls)
                           t))
                        ((symbol-function 'ebasecamp-ui--avy-available-p)
                         (lambda () t))
                        ((symbol-function 'ebasecamp-ui--target-position)
                         (lambda (_key) 100))
                        ((symbol-function 'ebasecamp-ui--jump-to)
                         (lambda (_key &optional position) position)))
                (let ((ebasecamp-status--tick-function
                       'ebasecamp-ui-test--tick))
                  (ebasecamp-ui-avy-jump)))
              (should (equal '(stop (start ebasecamp-ui-test--tick))
                             (nreverse calls)))
              ;; ② 原本未轮询 → 不恢复（既不 stop 也不 start）
              (setq calls nil)
              (cl-letf (((symbol-function 'ebasecamp-status-running-p)
                         (lambda () nil))
                        ((symbol-function 'ebasecamp-status-stop)
                         (lambda () (push 'stop calls)))
                        ((symbol-function 'ebasecamp-status-start)
                         (lambda (function)
                           (push (list 'start function) calls)
                           t))
                        ((symbol-function 'ebasecamp-ui--avy-available-p)
                         (lambda () t))
                        ((symbol-function 'ebasecamp-ui--target-position)
                         (lambda (_key) 100))
                        ((symbol-function 'ebasecamp-ui--jump-to)
                         (lambda (_key &optional position) position)))
                (let ((ebasecamp-status--tick-function
                       'ebasecamp-ui-test--tick))
                  (ebasecamp-ui-avy-jump)))
              (should-not calls))))))))

(ert-deftest ebasecamp-ui-test-jump-reports-when-no-visible-target ()
  "没有可见跳转目标时 `message' 说明、返回 nil、不 signal。
两种成因都覆盖：①有候选但位置全为 nil（视口外 / 树未对齐）；
②根本没有候选（会话未建立 / 清单为空）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--avy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (let (messages)
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest arguments)
                         (push (apply #'format format-string arguments) messages)))
                      ((symbol-function 'ebasecamp-ui--avy-available-p)
                       (lambda () t))
                      ((symbol-function 'ebasecamp-ui--target-position)
                       (lambda (_key) nil)))
              ;; ① 候选存在但都不可见
              (should-not (ebasecamp-ui-avy-jump))
              (should (= 1 (length messages)))
              (should (string-match-p "没有" (car messages)))
              (should (string-match-p "可见" (car messages)))
              ;; ② 没有候选
              (setq messages nil)
              (cl-letf (((symbol-function 'ebasecamp-ui--avy-targets)
                         (lambda () nil)))
                (should-not (ebasecamp-ui-avy-jump)))
              (should (= 1 (length messages)))
              (should (string-match-p "没有" (car messages))))))))))

(ert-deftest ebasecamp-ui-test-tree-target-safety-valve-rejects-mismatch ()
  "树项「按序对齐」的数量安全阀：可见 key 数与按钮节点数不等时全部放弃。
数量相等时 `--tree-target-position' 必须给出位置（正常路径），把
`--tree-button-nodes' 打桩成少一个节点后必须返回 nil —— 宁可不跳，也不按
错位的对应关系跳到别的条目。同一 key 经 `--target-position' 也只能得到 nil：
它按「key 是否属于可见树 key」判别类型，树定位失败时不会退回服务行路径
（`group/mysql' 也确实是行 ref 解不出的 key）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--avy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (should (integer-or-marker-p
                   (ebasecamp-ui--tree-target-position "group/mysql")))
          (let ((original (symbol-function 'ebasecamp-ui--tree-button-nodes)))
            (cl-letf (((symbol-function 'ebasecamp-ui--tree-button-nodes)
                       (lambda (runtime) (butlast (funcall original runtime)))))
              (should-not (ebasecamp-ui--tree-target-position "group/mysql"))
              (should-not (ebasecamp-ui--target-position "group/mysql")))))))))

(ert-deftest ebasecamp-ui-test-jump-does-not-change-selection ()
  "`--jump-to' 只移动 point 与焦点：选中组与勾选集合都不变。
跳转若写状态会触发整树重渲染、让刚落的位置立刻失效，而且导航键不该带写副作用。
先预置一个勾选项（空集合无法证明「没被清空」），再跳到另一个组，断言两者与
调用前完全相同。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--avy-manifest)
    (ebasecamp-ui-test--with-ps nil
      (let ((ebox-viewport-height 40))
        (ebasecamp-ui-test--with-open-ui
          (ebasecamp-ui--toggle-selected (ebasecamp-ui-session) "mysql/mysql" t)
          (let ((group-before (ebasecamp-ui-test--selected-group))
                (keys-before (copy-sequence (ebasecamp-ui-selected-keys)))
                (position (ebasecamp-ui--tree-target-position "group/redis")))
            (should (eq 'mysql group-before))
            (should (equal '("mysql/mysql") keys-before))
            (should (integer-or-marker-p position))
            (should (ebasecamp-ui--jump-to "group/redis" position))
            (should (eq group-before (ebasecamp-ui-test--selected-group)))
            (should (equal keys-before (ebasecamp-ui-selected-keys)))))))))

(provide 'ebasecamp-ui-tests)
;;; ebasecamp-ui-tests.el ends here
