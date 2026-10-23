;;; ebasecamp-manifest-tests.el --- 清单写盘内核测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; W1.1 / W1.3 的 ERT 测试：清单写盘内核（`ebasecamp-manifest'）。
;;
;; 覆盖范围：
;; - `ebasecamp-manifest--scan-forms' 的顶层 form 扫描：首行文件局部变量、
;;   两个组、字符串内括号、`#' 引用、`;' 行注释、`#| |#' 块注释、尾随
;;   `(provide)'；返回 `(:start :end :kind :name)'；
;; - `--replace-form' / `--append-form' / `--remove-form' 的纯文本行为
;;   （目标块之外逐字节不变）；
;; - `--write-transaction' 的四条路径：成功、引入新错误回滚、既有错误不阻断、
;;   写前检测到外部修改（mtime 变化）；另加原子写的符号链接边界。
;;
;; 事务测试用临时清单目录（`groups.el' + `projects/*.el'）并把
;; `ebasecamp-config-directory' 绑到该目录，因此不读用户真实清单、不依赖
;; docker。位置切片一律按 1-based buffer 位置处理（字符串下标 = 位置 - 1）。

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ebasecamp-model)
(require 'ebasecamp-config)
(require 'ebasecamp-manifest)

;;; 测试脚手架

(defvar ebasecamp-manifest-test--config-dir nil
  "当前测试使用的临时清单目录（无尾斜杠）。
由 `ebasecamp-manifest-test--with-directory' 动态绑定，供脚手架函数读取。")

(defconst ebasecamp-manifest-test--probe-text
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; probe.el --- 扫描探针清单\n"
   "\n"
   ";; 第一组之前有行注释；字符串里带括号 \"a(b)c\"，还有 #' 引用\n"
   "(ebasecamp-define-group alpha\n"
   "  :title \"alpha\"\n"
   "  :scope per-project\n"
   "  :services\n"
   "  ((web :image \"nginx:1.27\"\n"
   "        :command (\"sh\" \"-c\" \"echo a(b)c\")\n"
   "        :callback #'ignore)\n"
   "   (db :image \"mysql:8\"\n"
   "       :environment ((\"K\" . \"v(w)\"))))\n"
   "  :configs ((alpha :project probe-app)))\n"
   "\n"
   "#| 块注释不产生 form，里面的括号 ( 不平衡也不该炸 |#\n"
   "\n"
   "(ebasecamp-define-group beta\n"
   "  :title \"beta\"\n"
   "  :scope shared\n"
   "  :services ((cache :image \"redis:7.4\"))\n"
   "  :configs ((beta :project probe-app)))\n"
   "\n"
   ";; 尾随 form\n"
   "(provide 'probe)\n")
  "与 W0.1 探针同构的清单文本（2 个组 + 块注释 + 尾随 form）。")

(defconst ebasecamp-manifest-test--base-groups
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; groups.el --- 事务测试用最小清单\n"
   "\n"
   "(ebasecamp-define-group alpha\n"
   "  :title \"alpha\"\n"
   "  :scope per-project\n"
   "  :services\n"
   "  ((web :image \"nginx:1.27\"\n"
   "        :ports ((8080 . 80))))\n"
   "  :configs ((alpha :project probe-app)))\n")
  "可被 `ebasecamp-config-load' 正常加载的最小 groups.el。")

(defconst ebasecamp-manifest-test--base-project
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   "\n"
   "(ebasecamp-define-project probe-app\n"
   "  :title \"probe-app\"\n"
   "  :root \"/tmp/probe-app\")\n")
  "与 `--base-groups' 配套的项目定义。")

(defconst ebasecamp-manifest-test--gamma-form
  (concat
   "(ebasecamp-define-group gamma\n"
   "  :title \"gamma\"\n"
   "  :scope shared\n"
   "  :services nil\n"
   "  :configs nil)")
  "追加用的合法组 form（不含结尾换行）。")

(defconst ebasecamp-manifest-test--broken-form
  "(ebasecamp-define-group gamma :scope bogus)"
  "追加后会引入新加载错误的组 form（`:scope' 非法）。")

(defmacro ebasecamp-manifest-test--with-directory (&rest body)
  "在临时清单目录中执行 BODY。
BODY 内 `ebasecamp-manifest-test--config-dir' 为该目录绝对路径（无尾斜杠），
`ebasecamp-config-directory' 指向同一目录。"
  (declare (indent 0) (debug t))
  `(let* ((ebasecamp-manifest-test--config-dir (make-temp-file "ebc-manifest-" t))
          (ebasecamp-config-directory
           (file-name-as-directory ebasecamp-manifest-test--config-dir)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory ebasecamp-manifest-test--config-dir t)))))

(defun ebasecamp-manifest-test--read (file)
  "读取 FILE 全文并返回字符串。"
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun ebasecamp-manifest-test--write (file text)
  "把 TEXT 写入 FILE（覆盖）。"
  (with-temp-file file (insert text)))

(defun ebasecamp-manifest-test--manifest-file ()
  "返回当前临时清单目录里 `groups.el' 的绝对路径。"
  (expand-file-name "groups.el" ebasecamp-manifest-test--config-dir))

(defun ebasecamp-manifest-test--write-base ()
  "在当前临时清单目录写入可加载的基础清单（groups.el + 一个项目）。"
  (ebasecamp-manifest-test--write
   (ebasecamp-manifest-test--manifest-file)
   ebasecamp-manifest-test--base-groups)
  (make-directory
   (expand-file-name "projects/" ebasecamp-manifest-test--config-dir) t)
  (ebasecamp-manifest-test--write
   (expand-file-name "projects/probe-app.el" ebasecamp-manifest-test--config-dir)
   ebasecamp-manifest-test--base-project))

(defun ebasecamp-manifest-test--scan-text (text)
  "把 TEXT 落到当前临时清单目录的临时文件后扫描，返回 form 列表。"
  (let ((file (expand-file-name "scan-probe.el"
                                ebasecamp-manifest-test--config-dir)))
    (ebasecamp-manifest-test--write file text)
    (ebasecamp-manifest--scan-forms file)))

(defun ebasecamp-manifest-test--slice (text form)
  "按 1-based 位置从 TEXT 切出 FORM 的原文。
切片必须 `(1- position)'：buffer 位置从 1 起算，字符串下标从 0 起算。"
  (substring text (1- (plist-get form :start)) (1- (plist-get form :end))))

(defun ebasecamp-manifest-test--slice-as-form (text form)
  "把 TEXT 中 FORM 的切片 read 成 Lisp 对象后返回。"
  (read (ebasecamp-manifest-test--slice text form)))

(defun ebasecamp-manifest-test--leftovers ()
  "返回当前临时清单目录里遗留的备份 / 写盘临时文件名列表。"
  (directory-files ebasecamp-manifest-test--config-dir nil "\\`\\.ebasecamp-"))

(defun ebasecamp-manifest-test--kinds (forms)
  "返回 FORMS 的 kind 列表。"
  (mapcar (lambda (form) (plist-get form :kind)) forms))

(defun ebasecamp-manifest-test--names (forms)
  "返回 FORMS 的 name 列表。"
  (mapcar (lambda (form) (plist-get form :name)) forms))

;;; 1. 扫描

(ert-deftest ebasecamp-manifest-test-scan-forms ()
  "扫描返回每个顶层 form 的 (:start :end :kind :name)，块注释不产生 form。"
  (ebasecamp-manifest-test--with-directory
    (let* ((text ebasecamp-manifest-test--probe-text)
           (forms (ebasecamp-manifest-test--scan-text text)))
      ;; 3 个顶层 form：alpha 组、beta 组、尾随 (provide)
      (should (= 3 (length forms)))
      (should (equal '(group group nil) (ebasecamp-manifest-test--kinds forms)))
      (should (equal '(alpha beta nil) (ebasecamp-manifest-test--names forms)))
      ;; start/end 合法且切片非空
      (dolist (form forms)
        (should (integerp (plist-get form :start)))
        (should (integerp (plist-get form :end)))
        (should (< (plist-get form :start) (plist-get form :end)))
        (should (stringp (ebasecamp-manifest-test--slice text form))))
      ;; 切片能被 read 回同一个顶层 form（验证 1-based 位置换算正确）
      (let* ((alpha (nth 0 forms))
             (beta (nth 1 forms))
             (tail (nth 2 forms))
             (alpha-form (ebasecamp-manifest-test--slice-as-form text alpha))
             (beta-form (ebasecamp-manifest-test--slice-as-form text beta)))
        (should (eq 'ebasecamp-define-group (car alpha-form)))
        (should (eq 'alpha (cadr alpha-form)))
        ;; 字符串内的括号没有把 form 提前截断
        (should (equal '("sh" "-c" "echo a(b)c")
                       (plist-get (cdr (car (plist-get alpha-form :services)))
                                  :command)))
        ;; `#' 引用被 read 成 (function ignore)
        (should (eq 'function
                    (car (plist-get (cdr (car (plist-get alpha-form :services)))
                                    :callback))))
        (should (eq 'beta (cadr beta-form)))
        (should (equal '(provide 'probe)
                       (ebasecamp-manifest-test--slice-as-form text tail))))
      ;; 块注释既不成 form，也没有混进任何切片
      (dolist (form forms)
        (should-not (string-match-p "块注释"
                                    (ebasecamp-manifest-test--slice text form))))
      ;; 位置递增：前一个 form 的 end 不晚于后一个 form 的 start
      (should (<= (plist-get (nth 0 forms) :end) (plist-get (nth 1 forms) :start)))
      (should (<= (plist-get (nth 1 forms) :end) (plist-get (nth 2 forms) :start))))))

;;; 2. 替换

(ert-deftest ebasecamp-manifest-test-replace-form ()
  "替换第一个组后，其余字节逐字节不变。"
  (ebasecamp-manifest-test--with-directory
    (let* ((text ebasecamp-manifest-test--probe-text)
           (forms (ebasecamp-manifest-test--scan-text text))
           (alpha (nth 0 forms))
           (start (1- (plist-get alpha :start)))
           (end (1- (plist-get alpha :end)))
           (new (concat "(ebasecamp-define-group alpha\n"
                        "  :title \"alpha-new\"\n"
                        "  :scope per-project\n"
                        "  :services ((web :image \"nginx:1.27\"))\n"
                        "  :configs ((alpha :project probe-app)))"))
           (result (ebasecamp-manifest--replace-form text alpha new)))
      ;; 前段（含首行局部变量与注释）逐字节不变
      (should (equal (substring text 0 start) (substring result 0 start)))
      ;; 后段（第二组、块注释、尾随 form）整体右移，内容逐字节不变
      (should (equal (substring text end)
                     (substring result (+ start (length new)))))
      ;; 目标区段就是新文本
      (should (equal new (substring result start (+ start (length new)))))
      ;; 重新扫描：仍是 3 个 form，第一组标题已更新，其余 form 文本不变
      (let ((after (ebasecamp-manifest-test--scan-text result)))
        (should (= 3 (length after)))
        (should (equal '(group group nil) (ebasecamp-manifest-test--kinds after)))
        (should (equal (ebasecamp-manifest-test--slice text (nth 1 forms))
                       (ebasecamp-manifest-test--slice result (nth 1 after))))
        (should (equal (ebasecamp-manifest-test--slice text (nth 2 forms))
                       (ebasecamp-manifest-test--slice result (nth 2 after))))
        (should (string-match-p "alpha-new"
                                (ebasecamp-manifest-test--slice result
                                                                (nth 0 after))))))))

;;; 3. 追加

(ert-deftest ebasecamp-manifest-test-append-form ()
  "追加到文件末尾，保留结尾换行，原内容不变。"
  (ebasecamp-manifest-test--with-directory
    (let* ((text ebasecamp-manifest-test--probe-text)
           (new ebasecamp-manifest-test--gamma-form)
           (result (ebasecamp-manifest--append-form text new)))
      (should (string-prefix-p text result))
      (should (string-suffix-p "\n" result))
      (should (string-suffix-p (concat new "\n") result))
      (let ((before (ebasecamp-manifest-test--scan-text text))
            (after (ebasecamp-manifest-test--scan-text result)))
        (should (= 4 (length after)))
        (should (eq 'group (plist-get (car (last after)) :kind)))
        (should (eq 'gamma (plist-get (car (last after)) :name)))
        ;; 原有 3 个 form 的文本逐字节不变
        (dotimes (index 3)
          (should (equal (ebasecamp-manifest-test--slice text (nth index before))
                         (ebasecamp-manifest-test--slice result
                                                         (nth index after)))))))))

;;; 4. 删除

(ert-deftest ebasecamp-manifest-test-remove-form ()
  "删除组 form 及其独占空行；不删除相邻 form 与注释。"
  (ebasecamp-manifest-test--with-directory
    (let* ((text ebasecamp-manifest-test--probe-text)
           (forms (ebasecamp-manifest-test--scan-text text))
           (alpha-text (ebasecamp-manifest-test--slice text (nth 0 forms)))
           (result (ebasecamp-manifest--remove-form text (nth 1 forms))))
      (should-not (string-match-p "(ebasecamp-define-group beta" result))
      ;; 相邻内容都在：块注释、尾随注释、尾随 form、alpha 组
      (should (string-match-p "#| 块注释" result))
      (should (string-match-p ";; 尾随 form" result))
      (should (string-match-p "(provide 'probe)" result))
      ;; alpha 组文本逐字节不变（见下方重新扫描断言）
      (should-not (string-match-p "(ebasecamp-define-group beta" result))
      ;; 不留 triple newline（独占空行被合并，相邻空行不被吞）
      (should-not (string-match-p "\n\n\n" result))
      ;; 重新扫描：2 个 form（alpha 组 + 尾随 form），alpha 文本未变
      (let ((after (ebasecamp-manifest-test--scan-text result)))
        (should (= 2 (length after)))
        (should (equal '(group nil) (ebasecamp-manifest-test--kinds after)))
        (should (equal '(alpha nil) (ebasecamp-manifest-test--names after)))
        (should (equal alpha-text
                       (ebasecamp-manifest-test--slice result (nth 0 after))))))))

;;; 5. 事务：成功

(ert-deftest ebasecamp-manifest-test-write-transaction-success ()
  "写一个合法改动 → 文件被替换、加载无新增错误、备份被删除。"
  (ebasecamp-manifest-test--with-directory
    (ebasecamp-manifest-test--write-base)
    (let* ((file (ebasecamp-manifest-test--manifest-file))
           (original (ebasecamp-manifest-test--read file))
           (before (ebasecamp-config-load))
           (result (ebasecamp-manifest--write-transaction
                    file
                    (lambda (text)
                      (ebasecamp-manifest--append-form
                       text ebasecamp-manifest-test--gamma-form))))
           (written (ebasecamp-manifest-test--read file)))
      (should (null (plist-get before :errors)))
      (should (null (plist-get result :errors)))
      (should (string-prefix-p original written))
      (should (string-match-p "ebasecamp-define-group gamma" written))
      ;; 新组已注册、既有组仍在
      (should (ebasecamp-model-group 'gamma))
      (should (ebasecamp-model-group 'alpha))
      ;; 备份与写盘临时文件都不留
      (should-not (ebasecamp-manifest-test--leftovers)))))

;;; 6. 事务：引入新错误 → 回滚

(ert-deftest ebasecamp-manifest-test-write-transaction-rollback ()
  "写入引入新错误的内容 → signal `ebasecamp-config-write-error' 且文件恢复原文。"
  (ebasecamp-manifest-test--with-directory
    (ebasecamp-manifest-test--write-base)
    (let* ((file (ebasecamp-manifest-test--manifest-file))
           (original (ebasecamp-manifest-test--read file))
           (hash (secure-hash 'sha256 original)))
      (should-error
       (ebasecamp-manifest--write-transaction
        file
        (lambda (text)
          (ebasecamp-manifest--append-form
           text ebasecamp-manifest-test--broken-form)))
       :type 'ebasecamp-config-write-error)
      ;; 文件逐字节恢复（sha256 一致）
      (should (equal hash
                     (secure-hash 'sha256 (ebasecamp-manifest-test--read file))))
      (should (equal original (ebasecamp-manifest-test--read file)))
      ;; 回滚策略：恢复成功后删除备份（不留 `.ebasecamp-*' 文件）
      (should-not (ebasecamp-manifest-test--leftovers))
      ;; 回滚后清单重新可加载、零错误
      (should (null (plist-get (ebasecamp-config-load) :errors))))))

;;; 7. 事务：既有错误不阻断

(ert-deftest ebasecamp-manifest-test-write-transaction-existing-errors ()
  "先人为制造既有错误，再写一个不新增错误的改动 → 不回滚、改动生效。"
  (ebasecamp-manifest-test--with-directory
    (ebasecamp-manifest-test--write-base)
    ;; 既有错误：项目引用未定义的组 ghost（与本次写盘无关）
    (ebasecamp-manifest-test--write
     (expand-file-name "projects/broken-app.el"
                       ebasecamp-manifest-test--config-dir)
     (concat "(ebasecamp-define-project broken-app\n"
             "  :title \"broken-app\"\n"
             "  :groups ((ghost :scope per-project)))\n"))
    (let* ((file (ebasecamp-manifest-test--manifest-file))
           (before-errors (plist-get (ebasecamp-config-load) :errors))
           (result (ebasecamp-manifest--write-transaction
                    file
                    (lambda (text)
                      (ebasecamp-manifest--append-form
                       text ebasecamp-manifest-test--gamma-form))))
           (after-errors (plist-get result :errors))
           (messages (lambda (errors)
                       (mapcar (lambda (error) (plist-get error :message))
                               errors))))
      ;; 前提：确实存在既有错误，且消息提到了 ghost
      (should (cl-plusp (length before-errors)))
      (should (string-match-p "ghost"
                              (mapconcat #'identity
                                         (funcall messages before-errors) " ")))
      ;; 未回滚：改动生效、组已注册
      (should (string-match-p "ebasecamp-define-group gamma"
                              (ebasecamp-manifest-test--read file)))
      (should (ebasecamp-model-group 'gamma))
      ;; 既有错误数量与内容不变（没被本次写盘"修掉"或放大）
      (should (= (length before-errors) (length after-errors)))
      (should (equal (funcall messages before-errors)
                     (funcall messages after-errors)))
      (should-not (ebasecamp-manifest-test--leftovers)))))

;;; 8. 事务：写前检测外部修改

(ert-deftest ebasecamp-manifest-test-write-transaction-stale ()
  "写前人为改 mtime → `user-error'「文件已被外部修改」。"
  (ebasecamp-manifest-test--with-directory
    (ebasecamp-manifest-test--write-base)
    (let* ((file (ebasecamp-manifest-test--manifest-file))
           (original (ebasecamp-manifest-test--read file)))
      (should-error
       (ebasecamp-manifest--write-transaction
        file
        (lambda (text)
          ;; 模拟另一进程在事务快照与我方写盘之间改了文件
          (set-file-times file (time-add (current-time) 120))
          (ebasecamp-manifest--append-form
           text ebasecamp-manifest-test--gamma-form)))
       :type 'user-error)
      ;; 内容未被写盘改动（只动了 mtime）
      (should (equal original (ebasecamp-manifest-test--read file)))
      (should-not (ebasecamp-manifest-test--leftovers)))))

;;; 9. 原子写：符号链接边界

(ert-deftest ebasecamp-manifest-test-write-transaction-symlink ()
  "目标是符号链接时拒绝原子写（rename 会替换链接本身而非目标）。"
  (ebasecamp-manifest-test--with-directory
    (ebasecamp-manifest-test--write-base)
    (let* ((target (ebasecamp-manifest-test--manifest-file))
           (link (expand-file-name "link.el"
                                   ebasecamp-manifest-test--config-dir))
           (original (ebasecamp-manifest-test--read target)))
      (make-symbolic-link target link)
      (should-error
       (ebasecamp-manifest--write-transaction
        link
        (lambda (text)
          (ebasecamp-manifest--append-form
           text ebasecamp-manifest-test--gamma-form)))
       :type 'user-error)
      ;; 链接仍是链接，目标文件内容未被改动
      (should (file-symlink-p link))
      (should (equal original (ebasecamp-manifest-test--read target)))
      (should-not (ebasecamp-manifest-test--leftovers)))))

(provide 'ebasecamp-manifest-tests)

;;; ebasecamp-manifest-tests.el ends here
