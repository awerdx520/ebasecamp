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

(provide 'ebasecamp-ui-tests)
;;; ebasecamp-ui-tests.el ends here
