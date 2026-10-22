;;; ebasecamp-ui-tests.el --- ebasecamp etaf 主界面测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T2.3：etaf 主界面（`lisp/ebasecamp-ui.el'）的 ERT 测试。
;;
;; 渲染策略：`etaf-render' 只支持无状态组件（本界面有 `:setup' 生命周期），
;; 所以在 `emacs -Q --batch' 下用 `etaf-mount' 挂到真实 buffer 后断言
;; `buffer-string'（已用探针验证 batch 下可挂载）。断言只匹配文案 token，
;; 不依赖列宽或换行位置。
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
  "定义一个项目 myapp（shared 组 mysql，2 个服务）。"
  (ebasecamp-define-group mysql
    :scope shared
    :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306)))
               (mysql-ro :image "mysql:8.4")))
  (ebasecamp-define-project myapp :groups ((mysql))))

(defun ebasecamp-ui-test--buffer-text ()
  "返回 `ebasecamp-ui-buffer-name' buffer 的纯文本内容。"
  (substring-no-properties
   (with-current-buffer (get-buffer ebasecamp-ui-buffer-name)
     (buffer-string))))

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

;;; 2. 主界面渲染

(ert-deftest ebasecamp-ui-test-renders-projects-groups-services ()
  "1 项目 2 服务、docker 1 个 running：渲染含项目名、组名、两个服务名与状态文案。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps
        (list (ebasecamp-ui-test--container "myapp" "mysql" "mysql"
                                           "running" "healthy"))
      (ebasecamp-ui-open)
      (let ((text (ebasecamp-ui-test--buffer-text)))
        (should (ebasecamp-ui-test--contains-p text "myapp"))
        (should (ebasecamp-ui-test--contains-p text "mysql  (1/2)"))
        (should (ebasecamp-ui-test--contains-p text "mysql-ro"))
        (should (ebasecamp-ui-test--contains-p text "RUNNING"))
        (should (ebasecamp-ui-test--contains-p text "STOPPED"))
        (should (ebasecamp-ui-test--contains-p text "3306:3306"))
        (should (ebasecamp-ui-test--contains-p text "OK"))))))

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

;;; 3. 文案映射（纯函数）

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

;;; 4. 当前项目

(ert-deftest ebasecamp-ui-test-current-project-defaults-to-first ()
  "current-project 初始为第一个项目（定义顺序）。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-define-project other :groups ((mysql)))
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (should (eq 'myapp (ebasecamp-ui-current-project))))))

;;; 5. 选中状态

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

;;; 6. 关闭

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

;;; 7. 项目切换

(ert-deftest ebasecamp-ui-test-select-project-switches-query ()
  "切项目会写 project-ref、更新 controller query、重载数据并同步重渲染。
两个项目刻意绑定不同组：`other' 用组 cache（1 服务），因此组面板标签从
\"mysql  (0/2)\" 变为 \"cache  (0/1)\"，可用来验证重渲染确实发生。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-define-group cache
      :services ((redis :image "redis:7")))
    (ebasecamp-define-project other :groups ((cache)))
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (let* ((session (ebasecamp-ui-session))
             (controller (ebasecamp-ui-session-controller session)))
        (should (equal "myapp" (etaf-value (etaf-data-query controller))))
        (should (ebasecamp-ui-test--contains-p
                 (ebasecamp-ui-test--buffer-text) "mysql  (0/2)"))
        (ebasecamp-ui--select-project session 'other)
        (should (eq 'other (ebasecamp-ui-current-project)))
        (should (equal "other" (etaf-value (etaf-data-query controller))))
        (should (equal '("other")
                       (mapcar (lambda (record) (plist-get record :project))
                               (etaf-value (etaf-data-items controller)))))
        (let ((text (ebasecamp-ui-test--buffer-text)))
          (should (ebasecamp-ui-test--contains-p text "cache  (0/1)"))
          (should (ebasecamp-ui-test--contains-p text "redis"))
          (should-not (ebasecamp-ui-test--contains-p text "mysql  (0/2)")))))))

;;; 8. 操作条与并发控制（T3.2）

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

(ert-deftest ebasecamp-ui-test-renders-action-bar ()
  "主界面渲染四个生命周期操作按钮文案。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (let ((text (ebasecamp-ui-test--buffer-text)))
        (should (ebasecamp-ui-test--contains-p text "启动选中"))
        (should (ebasecamp-ui-test--contains-p text "停止选中"))
        (should (ebasecamp-ui-test--contains-p text "重启选中"))
        (should (ebasecamp-ui-test--contains-p text "销毁环境"))))))

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

(ert-deftest ebasecamp-ui-test-notice-rendered-as-alert ()
  "notice 非 nil 时界面渲染 etaf-alert，buffer-string 含 title 与 message。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((session (ebasecamp-ui-session)))
      (ebasecamp-ui--set-notice session 'error "端口冲突" "3306 已被占用")
      (ebasecamp-ui-test--with-ps nil
        (ebasecamp-ui-open)
        (let ((text (ebasecamp-ui-test--buffer-text)))
          (should (ebasecamp-ui-test--contains-p text "端口冲突"))
          (should (ebasecamp-ui-test--contains-p text "3306 已被占用"))
          ;; `:dismissible' 的关闭按钮是 alert 独有（旧实现只有一行 label）
          (should (ebasecamp-ui-test--contains-p text "×"))
          (should-not (ebasecamp-ui-test--contains-p
                       text ebasecamp-ui--hint)))))))

(ert-deftest ebasecamp-ui-test-notice-dismiss-clears ()
  "关闭按钮的回调（`ebasecamp-ui--clear-notice'）把 notice 置回 nil。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (let ((session (ebasecamp-ui-session)))
      (ebasecamp-ui--set-notice session 'error "端口冲突" "3306 已被占用")
      (should (etaf-value (ebasecamp-ui-session-notice session)))
      (ebasecamp-ui--clear-notice session)
      (should-not (etaf-value (ebasecamp-ui-session-notice session))))))

(ert-deftest ebasecamp-ui-test-select-project-clears-selection ()
  "切换项目会清空选中列表，避免跨项目残留 key。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-define-project other :groups ((mysql)))
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (ebasecamp-ui-test--select '("myapp/mysql/mysql"))
      (should (= 1 (length (ebasecamp-ui-selected-keys))))
      (ebasecamp-ui--select-project (ebasecamp-ui-session) 'other)
      (should-not (ebasecamp-ui-selected-keys))
      (should (eq 'other (ebasecamp-ui-current-project))))))

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

;;; 10. 导入 / 导出入口（T4.4）

(ert-deftest ebasecamp-ui-test-renders-import-export-buttons ()
  "操作条除四个生命周期按钮外，还渲染「导入 compose」「导出 compose」。"
  (ebasecamp-ui-test--with-ui
    (ebasecamp-ui-test--manifest)
    (ebasecamp-ui-test--with-ps nil
      (ebasecamp-ui-open)
      (let ((text (ebasecamp-ui-test--buffer-text)))
        (should (ebasecamp-ui-test--contains-p text "导入 compose"))
        (should (ebasecamp-ui-test--contains-p text "导出 compose"))
        ;; 生命周期按钮未被挤掉
        (should (ebasecamp-ui-test--contains-p text "启动选中"))
        (should (ebasecamp-ui-test--contains-p text "销毁环境"))))))

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

(provide 'ebasecamp-ui-tests)
;;; ebasecamp-ui-tests.el ends here
