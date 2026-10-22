;;; ebasecamp-tests.el --- ebasecamp 包入口测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T2.4 包入口（`ebasecamp.el'）的 ERT 测试。
;;
;; 覆盖：包可加载、`ebasecamp' 是命令、`ebasecamp-create-sample-config'
;; 生成的示例清单可被 `ebasecamp-config-load' 无错加载、已存在清单时拒绝
;; 覆盖（FORCE 时放行）、生成文件首行的 lexical-binding 声明，以及
;; `ebasecamp' 命令会调用 `ebasecamp-ui-open'（用 cl-letf 替换，不真挂界面）。
;;
;; 每个用例绑定临时 `ebasecamp-config-directory'，结束时递归删除临时目录
;; 并清空模型注册表，避免把示例清单的定义残留给其他测试文件。

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ebasecamp)

;;; 测试脚手架

(defmacro ebasecamp-test--with-dir (&rest body)
  "在临时清单目录内执行 BODY，结束后删除目录并清空注册表。
BODY 内 `ebasecamp-config-directory' 绑定为带结尾斜杠的临时目录。"
  (declare (indent 0) (debug t))
  `(let ((ebasecamp-config-directory
          (file-name-as-directory (make-temp-file "ebasecamp-test-" t))))
     (unwind-protect
         (progn ,@body)
       (ebasecamp-model-reset)
       (ignore-errors (delete-directory ebasecamp-config-directory t)))))

(defun ebasecamp-test--first-line (path)
  "返回文件 PATH 的首行文本（去掉换行符）。"
  (with-temp-buffer
    (insert-file-contents path)
    (goto-char (point-min))
    (buffer-substring-no-properties (line-beginning-position)
                                    (line-end-position))))

;;; 1. 包加载

(ert-deftest ebasecamp-test-requires ()
  "`ebasecamp' 可加载，且 feature 已提供。"
  (require 'ebasecamp)
  (should (featurep 'ebasecamp)))

(ert-deftest ebasecamp-test-command ()
  "`ebasecamp' 是交互式命令。"
  (should (commandp 'ebasecamp)))

;;; 2. 示例清单

(ert-deftest ebasecamp-test-create-sample-config ()
  "示例清单生成两个文件，且能被加载：2 个组、1 个项目、无错误。"
  (ebasecamp-test--with-dir
    (let ((groups-file (ebasecamp-create-sample-config)))
      (should (equal (expand-file-name "groups.el" ebasecamp-config-directory)
                     groups-file))
      (should (file-regular-p groups-file))
      (should (file-regular-p
               (ebasecamp-config-project-file "example"
                                              ebasecamp-config-directory)))
      (let ((result (ebasecamp-config-load ebasecamp-config-directory)))
        (should (null (plist-get result :errors)))
        (should (= 2 (length (plist-get result :groups))))
        (should (= 1 (length (plist-get result :projects))))
        (should (equal 'mysql
                       (ebasecamp-group-name
                        (ebasecamp-model-group 'mysql))))
        (should (eq 'shared (ebasecamp-group-scope
                             (ebasecamp-model-group 'mysql))))
        (should (eq 'per-project (ebasecamp-group-scope
                                  (ebasecamp-model-group 'redis))))
        (should (null (plist-get result :bootstrap-needed)))))))

(ert-deftest ebasecamp-test-create-sample-config-keeps-secrets-as-reference ()
  "示例清单里的 mysql 密码是 ${VAR} 引用，不是明文。"
  (ebasecamp-test--with-dir
    (ebasecamp-create-sample-config)
    (ebasecamp-config-load ebasecamp-config-directory)
    (let* ((group (ebasecamp-model-group 'mysql))
           (service (car (ebasecamp-group-services group)))
           (value (cdr (assoc "MYSQL_ROOT_PASSWORD"
                              (ebasecamp-service-environment service)))))
      (should (equal "${EBASECAMP_MYSQL_ROOT_PASSWORD}" value)))))

(ert-deftest ebasecamp-test-create-sample-config-refuses-overwrite ()
  "已存在清单时无 FORCE 报错，带 FORCE 覆盖成功。"
  (ebasecamp-test--with-dir
    (ebasecamp-create-sample-config)
    (should-error (ebasecamp-create-sample-config) :type 'user-error)
    (should (stringp (ebasecamp-create-sample-config t)))))

(ert-deftest ebasecamp-test-create-sample-config-lexical-binding ()
  "生成的两个文件首行都声明 lexical-binding。"
  (ebasecamp-test--with-dir
    (let ((groups-file (ebasecamp-create-sample-config)))
      (should (string-match-p "lexical-binding"
                              (ebasecamp-test--first-line groups-file)))
      (should (string-match-p
               "lexical-binding"
               (ebasecamp-test--first-line
                (ebasecamp-config-project-file "example"
                                               ebasecamp-config-directory)))))))

(defun ebasecamp-test--call (function)
  "调用 FUNCTION 并返回 (RESULT . MESSAGES) 形式的结果。
RESULT 为返回值，MESSAGES 为调用期间产生的消息列表。"
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages)
                 nil)))
      (cons (funcall function) (nreverse messages)))))

(ert-deftest ebasecamp-test-reload-reports-counts ()
  "`ebasecamp-reload' 返回加载结果，并报告组/项目数。"
  (ebasecamp-test--with-dir
    (ebasecamp-create-sample-config)
    (let* ((outcome (ebasecamp-test--call #'ebasecamp-reload))
           (result (car outcome))
           (reported (string-join (cdr outcome) "\n")))
      (should (= 2 (length (plist-get result :groups))))
      (should (= 1 (length (plist-get result :projects))))
      (should (string-match-p "已加载 2 个组、1 个项目" reported)))))

;;; 3. 命令派发

(ert-deftest ebasecamp-test-command-opens-ui ()
  "`ebasecamp' 命令调用 `ebasecamp-ui-open'，且加载清单后不报错。"
  (ebasecamp-test--with-dir
    (ebasecamp-create-sample-config)
    (ebasecamp-config-load ebasecamp-config-directory)
    (let ((calls 0))
      (cl-letf (((symbol-function 'ebasecamp-ui-open)
                 (lambda ()
                   (cl-incf calls)
                   'stub-buffer)))
        (should (eq 'stub-buffer (ebasecamp)))
        (should (= 1 calls))))))

(provide 'ebasecamp-tests)
;;; ebasecamp-tests.el ends here
