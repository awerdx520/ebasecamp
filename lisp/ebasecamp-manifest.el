;;; ebasecamp-manifest.el --- ebasecamp 清单写盘内核（扫描 / 定位 / 替换 / 事务） -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.5.4
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 清单文件（`groups.el' / `projects/*.el'）的**局部**写盘内核：按实体定位顶层
;; form、只替换/追加/删除目标块、写后校验、失败回滚、外部修改检测。纯文本层，
;; 不依赖 UI，也不依赖 compose / docker 层。
;;
;; 三层分工：
;; - **扫描**（`--scan-forms'）：顺序 `read' 顶层 form，记录 `(:start :end
;;   :kind :name)'。位置是 1-based 的 buffer 位置，做字符串切片必须 `(1- pos)'。
;;   `read' 自身会跳过 `;' 行注释（实测 Emacs 31.1），但 `#| |#' 块注释会
;;   `invalid-read-syntax'，因此扫描器在 form 之间显式 `search-forward "|#"' 跳过
;;   并记入 `ebasecamp-manifest--notes'；未闭合时报 `user-error'。
;; - **编辑**（`--replace-form' / `--append-form' / `--remove-form'）：**纯函数**，
;;   接受全文返回新全文，不碰文件系统。目标块之外的字节（注释、空行、顺序、
;;   其它 form）原样保留；便于一次事务里做多处编辑（例如移动配置 = 源移除 +
;;   目标追加）。
;; - **事务**（`--write-transaction'）：快照错误集 → 内存里算出新全文 → 写前
;;   stat 校验 → 备份 → 原子写（同目录临时文件 + `rename-file'）→ 重新加载取
;;   新错误集 → **仅当出现写前没有的新错误**才回滚。回滚判据是「错误消息
;;   差集」而非「零错误」，否则用户其它文件里的既有错误会永久阻断写盘。
;;
;; 安全约定（继承 AGENTS.md 不变量 5、6）：清单只保存 `${VAR}' 引用与相对路径，
;; 本模块不插值、不读取、不打印任何密钥值。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebasecamp-config)

;;; 错误与常量

(define-error 'ebasecamp-manifest-error "ebasecamp 清单解析失败")
(define-error 'ebasecamp-config-write-error
  "ebasecamp 清单写盘失败"
  'ebasecamp-manifest-error)

(defconst ebasecamp-manifest--backup-prefix ".ebasecamp-backup-"
  "写盘前备份原文的临时文件前缀（同目录、隐藏文件）。
备份文件不带 `.el' 后缀，且 `ebasecamp-config--files' 只认 `groups.el' 与
`projects/*.el'，因此备份不会被清单加载器读到。")

(defconst ebasecamp-manifest--write-prefix ".ebasecamp-write-"
  "原子写使用的同目录临时文件前缀。")

(defconst ebasecamp-manifest--form-kinds
  '((ebasecamp-define-group . group)
    (ebasecamp-define-project . project))
  "顶层 form 的 car 符号到 kind 的映射。
未列出的 form（例如尾随的 provide form）kind 与 name 都为 nil。")

(defvar ebasecamp-manifest--notes nil
  "最近一次 `ebasecamp-manifest--scan-forms' 产生的提示信息列表。
只记入「跳过 `#| |#' 块注释（位置 N）」这类需要让用户知道的情况；扫描器
不修改文件，note 供调用方（如 UI）展示。")

;;; 文本读取与文件属性

(defun ebasecamp-manifest--read-text (file)
  "读取 FILE 全文并返回字符串。FILE 不存在时报 `user-error'。"
  (unless (file-exists-p file)
    (user-error "清单文件 %s 不存在" file))
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun ebasecamp-manifest--file-stamp (file)
  "返回 FILE 的 mtime 与 size 快照，用于外部修改检测。
MTIME 取 `file-attribute-modification-time'，与 SIZE 一起双判据：某些文件
系统的 mtime 精度只有 1 秒，size 兜底。文件不存在时返回 nil。"
  (let ((attributes (file-attributes file)))
    (when attributes
      (cons (file-attribute-modification-time attributes)
            (file-attribute-size attributes)))))

(defun ebasecamp-manifest--delete-file (file)
  "删除 FILE；FILE 为 nil 或不存在时静默返回。"
  (when (and file (file-exists-p file))
    (ignore-errors (delete-file file))))

(defun ebasecamp-manifest--write-file (file text)
  "把 TEXT 原子写入 FILE（同目录 `make-temp-file' + `rename-file' 覆盖）。
FILE 是符号链接时 `user-error'：`rename-file' 会替换**链接本身**而不是它指向
的目标，静默接受会把清单变成普通文件。写盘沿用原文件权限位（新文件时用
`make-temp-file' 的默认 600）。"
  (when (file-symlink-p file)
    (user-error "%s 是符号链接，拒绝原子写（rename 会替换链接本身而非目标）"
                file))
  (let* ((file (expand-file-name file))
         (directory (file-name-directory file))
         (temporary (make-temp-file (expand-file-name
                                     ebasecamp-manifest--write-prefix directory))))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (set-buffer-file-coding-system 'utf-8-unix)
            (insert text))
          (when (file-exists-p file)
            (ignore-errors (set-file-modes temporary (file-modes file))))
          (rename-file temporary file t)
          (setq temporary nil))
      (ebasecamp-manifest--delete-file temporary))))

(defun ebasecamp-manifest--write-new-file (file text)
  "把 TEXT 写入**尚不存在**的 FILE，返回 FILE 的绝对路径。
父目录不存在时递归创建——新增项目时 `projects/' 可能还不存在；FILE 已存在即
`user-error'（新增语义不允许覆盖既有清单，覆盖走 `--write-transaction'）。
落地复用 `--write-file'（同目录临时文件 + `rename-file' 原子覆盖），因此新文件
不会以半截内容出现。"
  (let ((file (expand-file-name file)))
    (when (file-exists-p file)
      (user-error "清单文件 %s 已存在，拒绝覆盖" file))
    (make-directory (file-name-directory file) t)
    (ebasecamp-manifest--write-file file text)
    file))

(defun ebasecamp-manifest--backup (file text)
  "把 TEXT 写入 FILE 同目录的备份文件，返回备份路径。
备份只在事务内部使用：写盘成功后删除；回滚时用它的内容恢复原文。"
  (let ((backup (make-temp-file
                 (expand-file-name ebasecamp-manifest--backup-prefix
                                   (file-name-directory (expand-file-name file))))))
    (with-temp-file backup
      (set-buffer-file-coding-system 'utf-8-unix)
      (insert text))
    backup))

;;; 扫描

(defun ebasecamp-manifest--skip-trivia ()
  "跳过空白、`;' 行注释与 `#| |#' 块注释。
`read' 自身会跳过 `;' 行注释（实测 Emacs 31.1），`forward-comment' 因此只是
保持与既有实现一致；`#| |#' 块注释 `forward-comment' **不**认，必须显式
`search-forward' 到 `|#'，否则 `read' 报 `invalid-read-syntax'。块注释只支持
出现在 form 之间（form 内部的块注释仍按语法错处理），未闭合时报 `user-error'。"
  (forward-comment (point-max))
  ;; 用 `looking-at'（会设置 match data）而不是 `looking-at-p'：后者不设置
  ;; match data，随后的 `match-end' 会取到上一次匹配的残留值。
  (while (looking-at "#|")
    (let ((start (point)))
      (goto-char (match-end 0))
      (unless (search-forward "|#" nil t)
        (user-error "清单块注释 #| 未闭合（位置 %d）" start))
      (push (format "跳过 #| |# 块注释（位置 %d）" start)
            ebasecamp-manifest--notes)
      (forward-comment (point-max)))))

(defun ebasecamp-manifest--form-kind (form)
  "返回顶层 FORM 的 kind：`group' / `project'，其它 form 返回 nil。"
  (cdr (assq (car-safe form) ebasecamp-manifest--form-kinds)))

(defun ebasecamp-manifest--form-name (form)
  "返回 `ebasecamp-define-group'/`ebasecamp-define-project' FORM 的实体名。
其它 form（例如 provide form）返回 nil；名字不是符号时也返回 nil。"
  (when (ebasecamp-manifest--form-kind form)
    (let ((name (car-safe (cdr-safe form))))
      (and (symbolp name) name))))

(defun ebasecamp-manifest--scan-text-forms (text &optional label)
  "扫描 TEXT 的顶层 form，返回 (:start N :end N :kind SYM :name SYM) 的列表。
:start 与 :end 是 **1-based** 的 TEXT 位置（:end 指向 form 最后一个字符之后），
做字符串切片时必须把位置减 1。kind 为 `group' / `project'，name 为实体名
符号，其它顶层 form 两者都是 nil。返回值按文本顺序排列。LABEL 只用于错误
消息（通常传文件名）。

与 `ebasecamp-manifest--scan-forms' 的分工：本函数接受**内存里的全文**，因此
写盘路径可以在「同一份新全文」上定位 form——写操作不能重新读盘，否则事务的
mtime 快照与「一次事务完成多处编辑」的原子性都会失效。

扫描只顺序 `read'，不做求值：字符串里的括号、`#' 引用、`;' 行注释都不影响
位置准确性。`#| |#' 块注释被跳过并记入 `ebasecamp-manifest--notes'
（见 `ebasecamp-manifest--skip-trivia'）；无法解析时 signal
`ebasecamp-manifest-error'（含 LABEL 与出错位置）。"
  (setq ebasecamp-manifest--notes nil)
  (with-temp-buffer
    (insert text)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (goto-char (point-min))
    (let ((forms nil))
      (ebasecamp-manifest--skip-trivia)
      (while (not (eobp))
        (let ((start (point)))
          (condition-case err
              (let ((form (read (current-buffer))))
                (push (list :start start
                            :end (point)
                            :kind (ebasecamp-manifest--form-kind form)
                            :name (ebasecamp-manifest--form-name form))
                      forms))
            (error
             (signal 'ebasecamp-manifest-error
                     (list (format "%s 在位置 %d 无法解析：%s"
                                   (or label "清单文本") start
                                   (error-message-string err)))))))
        (ebasecamp-manifest--skip-trivia))
      (nreverse forms))))

(defun ebasecamp-manifest--scan-forms (file)
  "扫描 FILE 的顶层 form，返回 (:start N :end N :kind SYM :name SYM) 的列表。
:start 与 :end 是 **1-based** 的 buffer 位置（:end 指向 form 最后一个字符之后），
做字符串切片时必须把位置减 1。kind 为 `group' / `project'，name 为实体名
符号，其它顶层 form 两者都是 nil。返回值按文件顺序排列。

读取与扫描分别委托 `ebasecamp-manifest--read-text' 与
`ebasecamp-manifest--scan-text-forms'（后者承载全部扫描逻辑，写盘路径复用它
在同一份内存全文上定位）；FILE 不存在时报 `user-error'，无法解析时 signal
`ebasecamp-manifest-error'（含文件与出错位置）。"
  (ebasecamp-manifest--scan-text-forms (ebasecamp-manifest--read-text file) file))

(defun ebasecamp-manifest--scan-forms-in-region (text start end)
  "在 TEXT 的 [START, END) 区间内顺序 `read' form。
返回 (:start N :end N :value OBJ) 列表；位置与 `--scan-text-forms' 同口径
（1-based），因此可直接交给 `--replace-form' 使用。

用途：在组 form **内部**定位子 form。先读出 `(ebasecamp-define-group NAME'
之后的元素（关键字与其取值，例如 `:services' 与紧随其后的服务列表），再在
服务列表的括号内部读出每个服务子 form；两步都靠本函数。

区间内的空白与 `;' 行注释被跳过（`read' 自身会跳过行注释），区间外的内容不读；
越界读取或语法错时 signal `ebasecamp-manifest-error'（不返回半截结果，避免
调用方在错误位置上替换文本）。"
  (with-temp-buffer
    (insert text)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (goto-char start)
    (let ((forms nil)
          (done nil))
      (while (not done)
        (forward-comment (point-max))
        (if (>= (point) end)
            (setq done t)
          (let ((form-start (point)))
            (condition-case err
                (let ((value (read (current-buffer))))
                  (push (list :start form-start :end (point) :value value) forms))
              (error
               (signal 'ebasecamp-manifest-error
                       (list (format "清单片段 [%d, %d) 在位置 %d 无法解析：%s"
                                     start end form-start
                                     (error-message-string err)))))))))
      (nreverse forms))))

(defun ebasecamp-manifest--locate-form (kind name forms)
  "在 FORMS 中找到 KIND（`group' / `project'）与 NAME 匹配的 form。
NAME 可以是符号或字符串。找不到返回 nil；同名多个时返回**第一个**。"
  (let ((target (if (stringp name) (intern name) name)))
    (cl-find-if (lambda (form)
                  (and (eq kind (plist-get form :kind))
                       (eq target (plist-get form :name))))
                forms)))

;;; 纯文本编辑（接受全文，返回新全文，不碰文件系统）

(defun ebasecamp-manifest--replace-form (text form new-text)
  "把 TEXT 中 FORM 指定的区段替换为 NEW-TEXT，返回新全文。
FORM 来自 `--scan-forms'；切片按记录位置减 1 换算（buffer 位置 1-based）。
NEW-TEXT 若以单个换行结尾会先去掉该换行：form 区段本身不含行终止符，行尾
换行属于 form 之外的内容，自动补齐会制造空行。其余字节逐字节保留。"
  (let* ((start (1- (plist-get form :start)))
         (end (1- (plist-get form :end)))
         (body (if (string-suffix-p "\n" new-text)
                   (substring new-text 0 -1)
                 new-text)))
    (concat (substring text 0 start) body (substring text end))))

(defun ebasecamp-manifest--replace-forms (text replacements)
  "把 TEXT 中的多处区段一次性替换，返回新全文。
REPLACEMENTS 为 ((FORM . NEW-TEXT) ...)，FORM 来自扫描结果（同一份 TEXT 的
扫描）。按 `:start' **降序**依次替换：先动靠后的区段，因此前一次替换造成的
长度变化不会让后一次的位置失效。用于「一次事务里改多处」（例如移动配置 =
源组移除 + 目标组追加），避免分两次写盘破坏原子性。"
  (let ((sorted (sort (copy-sequence replacements)
                      (lambda (first second)
                        (> (plist-get (car first) :start)
                           (plist-get (car second) :start))))))
    (dolist (replacement sorted text)
      (setq text (ebasecamp-manifest--replace-form
                  text (car replacement) (cdr replacement))))))

(defun ebasecamp-manifest--append-form (text new-text)
  "把 NEW-TEXT 追加到 TEXT 末尾，返回新全文。
TEXT 与 NEW-TEXT 各自缺少结尾换行时补一个，因此原内容与结尾换行都保留；
不额外插入空行（空行由调用方在 NEW-TEXT 里自行决定）。"
  (concat (if (string-suffix-p "\n" text) text (concat text "\n"))
          (if (string-suffix-p "\n" new-text) new-text (concat new-text "\n"))))

(defun ebasecamp-manifest--remove-form (text form)
  "从 TEXT 中删除 FORM 指定的 form 及其独占空行，返回新全文。
删除范围是 form 本身 + 它自己的行终止符；若删除点上下都成了空行（该 form
原来的分隔空行），再合并一个空行。相邻 form、注释与块注释（含块注释自身的
空行）都不受影响。"
  (let* ((start (1- (plist-get form :start)))
         (end (1- (plist-get form :end)))
         (head (substring text 0 start))
         (tail (substring text end)))
    (when (string-prefix-p "\n" tail)
      (setq tail (substring tail 1)))
    (when (and (string-suffix-p "\n" head)
               (string-prefix-p "\n" tail))
      (setq tail (substring tail 1)))
    (concat head tail)))

;;; form 生成器（同时是 `ebasecamp-import' 的唯一实现）

(defconst ebasecamp-manifest--service-output-keys
  '(:image :command :entrypoint :environment :labels :ports :volumes
    :depends-on :networks :healthcheck :working-dir :user :restart :extra)
  "落盘时服务字段的固定输出顺序。
契约示例 image → command → environment → ports → volumes → depends-on →
networks → healthcheck → restart → extra 的相对顺序在此保持不变；契约示例未
列出的 entrypoint / labels / working-dir / user 插在语义相邻处。")

(defun ebasecamp-manifest--literal (value)
  "把 VALUE 写成 Elisp 字面量字符串。
`prin1-to-string' 只转义引号、反斜杠与控制字符，`${VAR}' 引用因此原样保留；
绑定 `print-escape-newlines' 为 t，避免多行字符串破坏文件版式。"
  (let ((print-length nil)
        (print-level nil)
        (print-escape-newlines t))
    (prin1-to-string value)))

(defun ebasecamp-manifest-service-form (name plist)
  "把服务 NAME（symbol）与属性 PLIST 渲染为完整的 (NAME :KEY VALUE ...)。
首行不含缩进，续行缩进 4 空格；nil 值的键与空的 `:extra' 一律省略。
本函数是 `ebasecamp-import--service-form' 的唯一实现，导入与写操作共用，
避免两处格式漂移。"
  (let ((lines nil))
    (dolist (key ebasecamp-manifest--service-output-keys)
      (let ((value (plist-get plist key)))
        (when value
          (push (format "    %s %s" key (ebasecamp-manifest--literal value))
                lines))))
    (if lines
        (concat "(" (symbol-name name) "\n"
                (mapconcat #'identity (nreverse lines) "\n")
                ")")
      (concat "(" (symbol-name name) ")"))))

(defun ebasecamp-manifest-group-form (name services)
  "渲染 `ebasecamp-define-group' 形式的多行字符串。
NAME 为组名 symbol（同时是项目名），SERVICES 为 ((SERVICE . PLIST) ...)
alist。服务定义写在组的 `:services'，项目归属写在组内 `:configs'：
配置名取项目名、`:project' 同值，覆盖留空（服务定义已在组侧，无需重复）。
加载期由 `ebasecamp-model-link-configs' 把它物化成项目的组引用。"
  (let ((blocks (mapcar (lambda (pair)
                          (ebasecamp-manifest-service-form
                           (car pair) (cdr pair)))
                        services))
        (group (symbol-name name)))
    (concat
     "(ebasecamp-define-group " group "\n"
     "  :title " (ebasecamp-manifest--literal group) "\n"
     "  :scope per-project\n"
     (if blocks
         (concat "  :services\n  ("
                 (mapconcat #'identity blocks "\n   ")
                 ")\n")
       "  :services nil\n")
     ;; 配置名 = 项目名：物化后的组引用可追溯到导入来源，也满足
     ;; 「同项目同组至多 1 个引用」的校验
     "  :configs ((" group " :project " group ")))\n")))

(defun ebasecamp-manifest-config-form (spec)
  "把组内配置定义 SPEC 渲染为单行文本。
SPEC 形如 (配置名 :project 项目 [:services 覆盖...])，取自组 form 的原文
`read'，因此 `:services' 覆盖等键值一并保留。输出为 `prin1' 形态（`${VAR}'
原样、不插值），`read' 回来与原 SPEC `equal'。"
  (ebasecamp-manifest--literal spec))

(defun ebasecamp-manifest-group-form-from-plist (name plist)
  "把组 NAME 与属性 PLIST 渲染为组 form 的多行字符串（含结尾换行）。
与 `ebasecamp-manifest-group-form' 的分工：后者是**导入模板**（title / scope
由组名推导、configs 只写一份自引用配置）；本函数保留 PLIST 里的 `:title' /
`:scope' / `:services' / `:configs' 全部键值，供实体操作的「整组重渲染」使用
（新增 / 改 project / 删除 / 移动配置都只改组内的 `:configs'）。

排版边界：组 form **内部**会被规范化——键序固定为 title → scope → services →
configs，服务子 form 与配置项各占一行；组 form **之外**的字节（文件头、块间
注释、其它组、尾随 form）由 `ebasecamp-manifest--replace-form' 逐字节保留。
`:configs' 为空时写 `:configs nil'（组本身不因此消失）。"
  (let ((title (or (plist-get plist :title) (symbol-name name)))
        (scope (or (plist-get plist :scope) 'per-project))
        (services (plist-get plist :services))
        (configs (plist-get plist :configs)))
    (concat
     "(ebasecamp-define-group " (symbol-name name) "\n"
     "  :title " (ebasecamp-manifest--literal title) "\n"
     "  :scope " (symbol-name scope) "\n"
     (if services
         (concat "  :services\n  ("
                 (mapconcat (lambda (spec)
                              (ebasecamp-manifest-service-form
                               (car spec) (cdr spec)))
                            services
                            "\n   ")
                 ")\n")
       "  :services nil\n")
     (if configs
         (concat "  :configs ("
                 (mapconcat #'ebasecamp-manifest-config-form configs
                            "\n            ")
                 "))\n")
       "  :configs nil)\n"))))

(defun ebasecamp-manifest-project-form (name root &optional file-configs file-secrets)
  "渲染 `ebasecamp-define-project' 形式的多行字符串。
NAME 为项目名 symbol，ROOT 为项目根目录字符串，FILE-CONFIGS / FILE-SECRETS
为 compose 顶层 `configs' / `secrets' 段的原样结构（非 nil 时才写）。
不写 `:groups'：项目对组的引用由组内 `:configs' 在加载期物化而来，两处都写
会构成「同项目同组双引用」而报加载错误。无顶层段时输出与历史实现逐字节一致。"
  (let ((lines (list (concat "  :title "
                             (ebasecamp-manifest--literal (symbol-name name)))
                     (concat "  :root "
                             (ebasecamp-manifest--literal root)))))
    (when file-configs
      (setq lines (append lines
                          (list (concat "  :file-configs "
                                        (ebasecamp-manifest--literal
                                         file-configs))))))
    (when file-secrets
      (setq lines (append lines
                          (list (concat "  :file-secrets "
                                        (ebasecamp-manifest--literal
                                         file-secrets))))))
    (concat "(ebasecamp-define-project " (symbol-name name) "\n"
            (mapconcat #'identity lines "\n")
            ")\n")))

;;; 写盘事务

(defun ebasecamp-manifest--write-transaction (file write-fn &rest keys)
  "对 FILE 执行一次「校验 + 回滚」保护的写盘事务，返回写入后的加载结果。
WRITE-FN 接受原全文并返回新全文，必须在**内存里一次**完成全部编辑（例如
移动配置的「源组移除 + 目标组追加」），不得自己写盘。事务步骤：

1. 读原文，记录 mtime 与 size 快照，并快照当前 `ebasecamp-config-load'
   的错误消息列表；
2. 调 WRITE-FN 得到新全文（与原文相同时不写盘，直接返回加载结果）；
3. **写前再次 stat**：mtime 或 size 任一变化 → `user-error'（外部修改）；
4. 备份原文到同目录临时文件；
5. 原子写新全文；
6. 重新加载，比较错误消息集合：**仅当出现写前没有的新错误**才回滚；
7. 成功则删除备份并返回加载结果；回滚 = 用备份恢复原文、删除备份、
   重新加载，并 signal 出 `ebasecamp-config-write-error`（data 为
   消息、FILE 与备份路径；备份已删除时路径为 nil）。恢复本身失败时保留备份，
   message 中给出备份路径供手工恢复。

可选 KEYS：

- `:keep-backup' 非 nil 时**成功后也保留备份**，并把返回值改成
  `\(:result LOAD-RESULT :backup BACKUP-PATH)'——调用方据此做跨文件补偿
  （见 `ebasecamp-config-write--move-config-across-files'）。未写盘（新全文与
  原文相同）时 `:backup' 为 nil。不传该键时返回值仍是加载结果本身，既有调用
  点不受影响。

加载目录取 `ebasecamp-config-directory'：调用方须保证 FILE 属于该清单目录。
符号链接目标在事务开始前就被拒绝（`--write-file' 同判据），避免事到临头才
创建出备份文件。"
  (let* ((file (expand-file-name file))
         (keep-backup (plist-get keys :keep-backup))
         (original (ebasecamp-manifest--read-text file))
         (stamp (ebasecamp-manifest--file-stamp file))
         (old-errors (ebasecamp-config-error-messages (ebasecamp-config-load)))
         (new-text (funcall write-fn original)))
    (if (string= new-text original)
        (if keep-backup
            (list :result (ebasecamp-config-load) :backup nil)
          (ebasecamp-config-load))
      (when (file-symlink-p file)
        (user-error "%s 是符号链接，拒绝原子写（rename 会替换链接本身而非目标）"
                    file))
      (unless (equal stamp (ebasecamp-manifest--file-stamp file))
        (user-error "清单文件 %s 已被外部修改，先 `g' 重载再试" file))
      (let* ((backup (ebasecamp-manifest--backup file original))
             (result nil)
             (added nil)
             (keep-backup-file nil))    ; 需要把备份留给调用方 / 手工恢复时置 t
        (unwind-protect
            (progn
              (ebasecamp-manifest--write-file file new-text)
              (setq result (ebasecamp-config-load))
              (setq added (cl-set-difference
                           (ebasecamp-config-error-messages result)
                           old-errors :test #'equal))
              (cond
               ((null added)
                (if keep-backup
                    (progn (setq keep-backup-file t)
                           (list :result result :backup backup))
                  result))
               (t
                (condition-case restore-error
                    (progn
                      (ebasecamp-manifest--write-file file original)
                      (ebasecamp-config-load)
                      (signal 'ebasecamp-config-write-error
                              (list (format
                                     "写入 %s 后清单新增 %d 个错误，已回滚：%s"
                                     file (length added)
                                     (string-join added "；"))
                                    file nil)))
                  (ebasecamp-config-write-error
                   (signal (car restore-error) (cdr restore-error)))
                  (error
                   (setq keep-backup-file t)
                   (signal 'ebasecamp-config-write-error
                           (list (format
                                  "写入 %s 后新增 %d 个错误，且回滚失败（%s）；原文备份保留在 %s，请手工恢复。新增错误：%s"
                                  file (length added)
                                  (error-message-string restore-error) backup
                                  (string-join added "；"))
                                 file backup)))))))
          ;; 备份收尾：只有「明确要留给调用方」或「回滚失败需人工恢复」才保留，
          ;; 其余情况（成功、回滚成功、写盘或加载中途异常）一律删掉，避免事务
          ;; 泄漏临时文件（写盘失败时原文其实没变，删备份没有风险）。
          (unless keep-backup-file
            (ebasecamp-manifest--delete-file backup)))))))

(provide 'ebasecamp-manifest)

;;; ebasecamp-manifest.el ends here
