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

;;; 4. 文档守护：Readme 命令表 ↔ `commandp'

(defun ebasecamp-test--readme-path ()
  "返回仓库根 Readme.org 的绝对路径。
`make test' 把仓库根放进 `load-path'，`locate-library' 命中的 `ebasecamp.el'
（或残留的 `.elc'）就在仓库根，Readme.org 与其同级；若换成 straight 布局
（`lisp/' 为子目录、库文件在子目录里）则退一级再找。两种布局都找不到就 FAIL。"
  (let* ((lib (or (locate-library "ebasecamp")
                  (ert-fail "找不到 ebasecamp 库，无法定位 Readme.org")))
         (dir (file-name-directory lib))
         (candidates (list (expand-file-name "Readme.org" dir)
                           (expand-file-name "../Readme.org" dir))))
    (or (cl-find-if #'file-exists-p candidates)
        (ert-fail (format "在 %S 里都找不到 Readme.org" candidates)))))

(defun ebasecamp-test--readme-command-names ()
  "解析 Readme.org 的 *命令表段*，返回表内登记的命令名（字符串列表）。
解析范围严格限定为「| 命令 | 说明 |」表头之后的那张表：先跳到表头，再跳过紧随
的分隔行（`|--+--|'），随后连续读取以 `|' 起始的行直到表结束，只取形如
`| =NAME= |' 的数据行。**禁止全文件扫描 `^| ='** —— 全文件该模式共 61 行
（含属性表与 Makefile 表），会误判。表头 / 分隔行缺失时 ert-fail 并点名
「Readme 命令表格式变化」，不静默通过。"
  (let ((path (ebasecamp-test--readme-path))
        names)
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (unless (re-search-forward "^| 命令 | 说明 |$" nil t)
        (ert-fail (format "Readme 命令表格式变化，请检查表头/分隔行/段边界：%s 里找不到「| 命令 | 说明 |」表头"
                          path)))
      (forward-line 1)
      (unless (looking-at-p "^|[-+]")
        (ert-fail "Readme 命令表格式变化，请检查表头/分隔行/段边界：表头下一行不是 `|--+--|' 分隔行"))
      (while (progn (forward-line 1)
                    (looking-at-p "^|"))
        (when (looking-at "^| =\\([^=]+\\)= |")
          (push (match-string-no-properties 1) names))))
    (nreverse names)))

(defun ebasecamp-test--public-command-names ()
  "返回 `ebasecamp*' 的非私有命令名（排除含 `--' 的内部命令）。"
  (let (acc)
    (mapatoms (lambda (symbol)
                (when (and (commandp symbol)
                           (string-prefix-p "ebasecamp" (symbol-name symbol))
                           (not (string-match-p "--" (symbol-name symbol))))
                  (push (symbol-name symbol) acc))))
    (nreverse acc)))

(ert-deftest ebasecamp-test-readme-command-table-matches-commandp ()
  "Readme 命令表登记的条数与集合必须与 `commandp' 实测一致（机械守护）。
两类文档漂移都在这里红：新增命令却没写进表（条数不足 17），或表里留着不存在 /
已删除的命令（集合差异）。"
  (let* ((documented (ebasecamp-test--readme-command-names))
         (actual (ebasecamp-test--public-command-names)))
    ;; ① 数量门禁：新增 / 删除命令时 Readme 命令表必须同步（当前 17 条）。
    (should (= 17 (length documented)))
    ;; ② 集合同等：排序后比较，避免表内顺序敏感。
    (let ((sorted-actual (sort (copy-sequence actual) #'string<))
          (sorted-doc (sort (copy-sequence documented) #'string<)))
      (unless (equal sorted-actual sorted-doc)
        (ert-fail
         (format
          "Readme 命令表格式变化，请检查表头/分隔行/段边界：Readme 登记 %d 条、commandp 实测 %d 条；仅代码有 %S，仅 Readme 有 %S"
          (length documented) (length actual)
          (cl-set-difference actual documented :test #'equal)
          (cl-set-difference documented actual :test #'equal))))
      (should (equal sorted-actual sorted-doc)))))

(provide 'ebasecamp-tests)
;;; ebasecamp-tests.el ends here
