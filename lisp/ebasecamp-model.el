;;; ebasecamp-model.el --- ebasecamp 清单数据模型 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.1.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; ebasecamp 的清单数据模型：纯数据层，不做 IO，不依赖 etaf 与 docker。
;;
;; 组成：
;; - 三个 record：ebasecamp-service、ebasecamp-group、ebasecamp-project
;; - 清单定义宏：ebasecamp-define-group、ebasecamp-define-project
;; - 进程内注册表与访问器：ebasecamp-model-group、ebasecamp-model-project、
;;   ebasecamp-model-groups、ebasecamp-model-projects、ebasecamp-model-reset
;; - 项目覆盖合并：ebasecamp-model-resolve-services
;;
;; 字段约定：
;; - name 为 symbol
;; - ports 元素为整数对 (PUBLISHED . TARGET)
;; - volumes 元素为 plist
;;   (:source S :target T :type volume|bind [:read-only t])
;; - environment 与 labels 为字符串 alist，值中的 ${VAR} 原样保留
;; - healthcheck 为 plist 或 nil
;; - extra 保存未识别的字段，导出时原样回写
;;
;; 项目的 groups 字段归一化为 plist 列表：
;;   (:group SYMBOL :scope nil|shared|per-project :service-overrides ALIST)
;; 其中 ALIST 形如 ((SERVICE-NAME . PLIST) ...)。
;;
;; 安全约定：清单只保存 ${VAR} 引用与相对路径；本模块不读取、不插值、
;; 不落盘任何密钥值。

;;; Code:

(require 'cl-lib)

(define-error 'ebasecamp-model-error "Invalid ebasecamp model")

(defun ebasecamp-model--fail (format-string &rest args)
  "以 ebasecamp-model-error 报告清单错误。
FORMAT-STRING 与 ARGS 组成人类可读的错误描述。"
  (signal 'ebasecamp-model-error
          (list (apply #'format format-string args))))

;;; 数据结构

(cl-defstruct (ebasecamp-service (:constructor ebasecamp-service-create))
  "单个服务定义。字段语义见本文件 Commentary 的字段约定。"
  name image command entrypoint environment labels ports volumes healthcheck
  depends-on networks working-dir user restart extra)

(cl-defstruct (ebasecamp-group (:constructor ebasecamp-group-create))
  "服务组定义。SCOPE 为 shared 或 per-project。"
  name title scope services)

(cl-defstruct (ebasecamp-project (:constructor ebasecamp-project-create))
  "项目定义。GROUPS 为归一化后的组引用 plist 列表。"
  name title root groups shared-network export-file)

;;; 允许的关键字

(defconst ebasecamp-model--group-keywords
  '(:title :scope :services)
  "组定义允许的关键字。")

(defconst ebasecamp-model--service-keywords
  '(:image :command :entrypoint :environment :labels :ports :volumes
    :healthcheck :depends-on :networks :working-dir :user :restart :extra)
  "服务定义允许的关键字。")

(defconst ebasecamp-model--project-keywords
  '(:title :root :shared-network :export-file :groups)
  "项目定义允许的关键字。")

(defconst ebasecamp-model--group-ref-keywords
  '(:scope :services)
  "项目内组引用允许的关键字。")

(defconst ebasecamp-model--scopes
  '(shared per-project)
  "组 scope 的合法取值。")

;;; 注册表与访问器

(defvar ebasecamp-model--groups nil
  "已注册的组，按定义顺序排列，元素为 ebasecamp-group 对象。")

(defvar ebasecamp-model--projects nil
  "已注册的项目，按定义顺序排列，元素为 ebasecamp-project 对象。")

(defun ebasecamp-model-reset ()
  "清空组与项目注册表，供清单重新加载前调用。"
  (setq ebasecamp-model--groups nil
        ebasecamp-model--projects nil))

(defun ebasecamp-model-groups ()
  "返回已注册的组列表，顺序为定义顺序。"
  (copy-sequence ebasecamp-model--groups))

(defun ebasecamp-model-projects ()
  "返回已注册的项目列表，顺序为定义顺序。"
  (copy-sequence ebasecamp-model--projects))

(defun ebasecamp-model-group (name)
  "返回名为 NAME 的组对象，不存在时返回 nil。"
  (cl-find name ebasecamp-model--groups
           :key #'ebasecamp-group-name :test #'eq))

(defun ebasecamp-model-project (name)
  "返回名为 NAME 的项目对象，不存在时返回 nil。"
  (cl-find name ebasecamp-model--projects
           :key #'ebasecamp-project-name :test #'eq))

;;; 校验助手

(defun ebasecamp-model--check-name (name context)
  "检查 NAME 是非 nil 的 symbol，否则以 CONTEXT 报告错误。"
  (unless (and name (symbolp name))
    (ebasecamp-model--fail "%s: 名字必须是 symbol，得到 %S" context name)))

(defun ebasecamp-model--check-plist (plist allowed context)
  "检查 PLIST 的键均属于 ALLOWED 且每个键都有取值。
CONTEXT 用于错误消息。"
  (let ((rest plist))
    (while rest
      (let ((key (car rest)))
        (unless (keywordp key)
          (ebasecamp-model--fail "%s: 期望关键字，得到 %S" context key))
        (unless (memq key allowed)
          (ebasecamp-model--fail "%s: 未知关键字 %S" context key))
        (unless (cdr rest)
          (ebasecamp-model--fail "%s: 关键字 %S 缺少取值" context key))
        (setq rest (cddr rest))))))

(defun ebasecamp-model--check-scope (scope context)
  "检查 SCOPE 属于 ebasecamp-model--scopes，否则报告错误。"
  (unless (memq scope ebasecamp-model--scopes)
    (ebasecamp-model--fail "%s: 非法 scope %S（允许 shared 或 per-project）"
                           context scope)))

(defun ebasecamp-model--check-string-list (value context)
  "检查 VALUE 为 nil 或字符串列表。"
  (unless (or (null value)
              (and (proper-list-p value)
                   (cl-every #'stringp value)))
    (ebasecamp-model--fail "%s: 期望字符串列表或 nil，得到 %S" context value)))

(defun ebasecamp-model--check-alist (value context)
  "检查 VALUE 为 nil 或字符串到字符串的 alist。"
  (unless (or (null value)
              (and (proper-list-p value)
                   (cl-every (lambda (pair)
                               (and (consp pair)
                                    (stringp (car pair))
                                    (stringp (cdr pair))))
                             value)))
    (ebasecamp-model--fail "%s: 期望字符串 alist 或 nil，得到 %S"
                           context value)))

(defun ebasecamp-model--check-ports (value context)
  "检查 VALUE 为 nil 或 (PUBLISHED . TARGET) 整数对列表。"
  (unless (or (null value) (proper-list-p value))
    (ebasecamp-model--fail "%s: ports 必须是列表，得到 %S" context value))
  (dolist (pair value)
    (unless (and (consp pair)
                 (integerp (car pair))
                 (integerp (cdr pair)))
      (ebasecamp-model--fail
       "%s: ports 元素必须是 (PUBLISHED . TARGET) 整数对，得到 %S"
       context pair))))

(defun ebasecamp-model--check-volumes (value context)
  "检查 VALUE 为 nil 或 plist 形式的卷列表。"
  (unless (or (null value) (proper-list-p value))
    (ebasecamp-model--fail "%s: volumes 必须是列表，得到 %S" context value))
  (dolist (volume value)
    (unless (and (proper-list-p volume) (keywordp (car volume)))
      (ebasecamp-model--fail "%s: volumes 元素必须是 plist，得到 %S"
                             context volume))
    (when (/= 0 (% (length volume) 2))
      (ebasecamp-model--fail "%s: volumes 元素 plist 长度必须是偶数，得到 %S"
                             context volume))
    (let ((type (plist-get volume :type)))
      (unless (memq type '(volume bind))
        (ebasecamp-model--fail
         "%s: volumes 元素的 :type 必须是 volume 或 bind，得到 %S"
         context type)))))

(defun ebasecamp-model--check-healthcheck (value context)
  "检查 VALUE 为 nil 或 plist。"
  (unless (or (null value)
              (and (proper-list-p value)
                   (keywordp (car value))
                   (= 0 (% (length value) 2))))
    (ebasecamp-model--fail "%s: healthcheck 必须是 plist 或 nil，得到 %S"
                           context value)))

(defun ebasecamp-model--check-service-values (plist context)
  "校验服务属性 PLIST 中全部可选字段的取值。
调用方须先用 ebasecamp-model--check-plist 检查关键字。"
  (ebasecamp-model--check-ports (plist-get plist :ports) context)
  (ebasecamp-model--check-volumes (plist-get plist :volumes) context)
  (ebasecamp-model--check-alist (plist-get plist :environment) context)
  (ebasecamp-model--check-alist (plist-get plist :labels) context)
  (ebasecamp-model--check-healthcheck (plist-get plist :healthcheck) context)
  (ebasecamp-model--check-string-list (plist-get plist :depends-on) context)
  (ebasecamp-model--check-string-list (plist-get plist :networks) context)
  (dolist (key '(:command :entrypoint))
    (let ((value (plist-get plist key)))
      (unless (or (null value) (stringp value))
        (ebasecamp-model--check-string-list value context))))
  (dolist (key '(:working-dir :user :restart))
    (let ((value (plist-get plist key)))
      (when (and value (not (stringp value)))
        (ebasecamp-model--fail "%s: %s 必须是字符串，得到 %S"
                               context key value))))
  (let ((extra (plist-get plist :extra)))
    (unless (or (null extra) (proper-list-p extra))
      (ebasecamp-model--fail "%s: extra 必须是 alist，得到 %S"
                             context extra))))

(defun ebasecamp-model--normalize-string-list (value context)
  "把 VALUE 归一化为字符串列表或 nil；字符串按单元素列表处理。"
  (cond
   ((null value) nil)
   ((stringp value) (list value))
   (t (ebasecamp-model--check-string-list value context)
      value)))

;;; 归一化

(defun ebasecamp-model--service-from-spec (name plist context)
  "由服务名 NAME 与属性 PLIST 构造 ebasecamp-service 对象。
CONTEXT 用于错误消息。"
  (ebasecamp-model--check-name name context)
  (let ((context (format "%s.%s" context name)))
    (ebasecamp-model--check-plist plist ebasecamp-model--service-keywords context)
    (let ((image (plist-get plist :image)))
      (unless (and (stringp image) (not (equal image "")))
        (ebasecamp-model--fail "%s: 缺少必填的 :image 字符串" context))
      (ebasecamp-model--check-service-values plist context)
      (ebasecamp-service-create
       :name name
       :image image
       :command (ebasecamp-model--normalize-string-list
                 (plist-get plist :command) context)
       :entrypoint (ebasecamp-model--normalize-string-list
                    (plist-get plist :entrypoint) context)
       :environment (plist-get plist :environment)
       :labels (plist-get plist :labels)
       :ports (plist-get plist :ports)
       :volumes (plist-get plist :volumes)
       :healthcheck (plist-get plist :healthcheck)
       :depends-on (plist-get plist :depends-on)
       :networks (plist-get plist :networks)
       :working-dir (plist-get plist :working-dir)
       :user (plist-get plist :user)
       :restart (plist-get plist :restart)
       :extra (plist-get plist :extra)))))

(defun ebasecamp-model--group-from-spec (name plist context)
  "由组名 NAME 与属性 PLIST 构造 ebasecamp-group 对象。
CONTEXT 用于错误消息。"
  (ebasecamp-model--check-name name context)
  (let ((context (format "%s.%s" context name)))
    (ebasecamp-model--check-plist plist ebasecamp-model--group-keywords context)
    (let ((title (plist-get plist :title))
          (scope (plist-get plist :scope))
          (services (plist-get plist :services)))
      (when (and title (not (stringp title)))
        (ebasecamp-model--fail "%s: :title 必须是字符串，得到 %S"
                               context title))
      (when scope
        (ebasecamp-model--check-scope scope context))
      (unless (or (null services) (proper-list-p services))
        (ebasecamp-model--fail "%s: :services 必须是列表，得到 %S"
                               context services))
      (dolist (spec services)
        (unless (consp spec)
          (ebasecamp-model--fail
           "%s: 服务定义必须是 (NAME 属性...)，得到 %S" context spec)))
      (ebasecamp-group-create
       :name name
       :title (or title (symbol-name name))
       :scope (or scope 'per-project)
       :services (mapcar (lambda (spec)
                           (ebasecamp-model--service-from-spec
                            (car spec) (cdr spec) context))
                         services)))))

(defun ebasecamp-model--group-ref-from-spec (spec context)
  "把项目里的组引用 SPEC 归一化为 plist。
返回 (:group SYMBOL :scope SCOPE :service-overrides ALIST)，其中 ALIST
形如 ((SERVICE-NAME . PLIST) ...)。CONTEXT 用于错误消息。"
  (unless (consp spec)
    (ebasecamp-model--fail "%s: 组引用必须是 (GROUP 属性...)，得到 %S"
                           context spec))
  (let ((name (car spec)))
    (ebasecamp-model--check-name name context)
    (let ((context (format "%s.%s" context name)))
      (ebasecamp-model--check-plist (cdr spec) ebasecamp-model--group-ref-keywords
                                    context)
      (let ((scope (plist-get (cdr spec) :scope))
            (overrides (plist-get (cdr spec) :services)))
        (when scope
          (ebasecamp-model--check-scope scope context))
        (unless (or (null overrides) (proper-list-p overrides))
          (ebasecamp-model--fail "%s: :services 必须是列表，得到 %S"
                                 context overrides))
        (list :group name
              :scope scope
              :service-overrides
              (mapcar (lambda (override)
                        (unless (consp override)
                          (ebasecamp-model--fail
                           "%s: 服务覆盖必须是 (NAME 属性...)，得到 %S"
                           context override))
                        (let ((service-name (car override))
                              (plist (cdr override)))
                          (ebasecamp-model--check-name service-name context)
                          (let ((service-context
                                 (format "%s.%s" context service-name)))
                            (ebasecamp-model--check-plist
                             plist ebasecamp-model--service-keywords
                             service-context)
                            (ebasecamp-model--check-service-values
                             plist service-context)
                            (cons service-name plist))))
                      overrides))))))

(defun ebasecamp-model--project-from-spec (name plist context)
  "由项目名 NAME 与属性 PLIST 构造 ebasecamp-project 对象。
CONTEXT 用于错误消息。"
  (ebasecamp-model--check-name name context)
  (let ((context (format "%s.%s" context name)))
    (ebasecamp-model--check-plist plist ebasecamp-model--project-keywords context)
    (let ((title (plist-get plist :title))
          (root (plist-get plist :root))
          (export-file (plist-get plist :export-file))
          (groups (plist-get plist :groups)))
      (when (and title (not (stringp title)))
        (ebasecamp-model--fail "%s: :title 必须是字符串，得到 %S"
                               context title))
      (when (and root (not (stringp root)))
        (ebasecamp-model--fail "%s: :root 必须是字符串，得到 %S" context root))
      (when (and export-file (not (stringp export-file)))
        (ebasecamp-model--fail "%s: :export-file 必须是字符串，得到 %S"
                               context export-file))
      (unless (or (null groups) (proper-list-p groups))
        (ebasecamp-model--fail "%s: :groups 必须是列表，得到 %S"
                               context groups))
      (ebasecamp-project-create
       :name name
       :title (or title (symbol-name name))
       :root root
       :groups (mapcar (lambda (spec)
                         (ebasecamp-model--group-ref-from-spec spec context))
                       groups)
       :shared-network (if (plist-member plist :shared-network)
                           (and (plist-get plist :shared-network) t)
                         t)
       :export-file export-file))))

;;; 注册

(defun ebasecamp-model--register-group (name plist)
  "注册组 NAME（属性 PLIST），返回新注册的组对象。
同名组已存在时报错，要求先调用 ebasecamp-model-reset。"
  (when (ebasecamp-model-group name)
    (ebasecamp-model--fail
     "组 %s 已定义；重新定义前须先调用 ebasecamp-model-reset" name))
  (let ((group (ebasecamp-model--group-from-spec name plist "清单")))
    (setq ebasecamp-model--groups
          (append ebasecamp-model--groups (list group)))
    group))

(defun ebasecamp-model--register-project (name plist)
  "注册项目 NAME（属性 PLIST），返回新注册的项目对象。
同名项目已存在时报错，要求先调用 ebasecamp-model-reset。"
  (when (ebasecamp-model-project name)
    (ebasecamp-model--fail
     "项目 %s 已定义；重新定义前须先调用 ebasecamp-model-reset" name))
  (let ((project (ebasecamp-model--project-from-spec name plist "清单")))
    (setq ebasecamp-model--projects
          (append ebasecamp-model--projects (list project)))
    project))

;;; 定义宏

(defmacro ebasecamp-define-group (name &rest args)
  "定义服务组 NAME，属性见 ARGS。
ARGS 允许的关键字为 :title、:scope、:services，:scope 取值 shared 或
per-project，缺省 per-project。展开后注册到组注册表并返回组名。"
  (declare (indent 1))
  (unless (symbolp name)
    (ebasecamp-model--fail "组名必须是 symbol，得到 %S" name))
  `(progn
     (ebasecamp-model--register-group ',name ',args)
     ',name))

(defmacro ebasecamp-define-project (name &rest args)
  "定义项目 NAME，属性见 ARGS。
ARGS 允许的关键字为 :title、:root、:shared-network、:export-file、:groups。
:groups 的每一项形如 (GROUP :scope SCOPE :services ((SERVICE 属性...)...))。
展开后注册到项目注册表并返回项目名。"
  (declare (indent 1))
  (unless (symbolp name)
    (ebasecamp-model--fail "项目名必须是 symbol，得到 %S" name))
  `(progn
     (ebasecamp-model--register-project ',name ',args)
     ',name))

;;; 覆盖合并

(defun ebasecamp-model--merge-alist (base override)
  "按键合并 BASE 与 OVERRIDE 两个 alist，返回新的 alist。
OVERRIDE 中出现的键覆盖 BASE 的同名值，BASE 其余键保留原顺序。
不修改 BASE 与 OVERRIDE 的原有结构。"
  (let ((result (mapcar (lambda (pair) (cons (car pair) (cdr pair))) base)))
    (dolist (pair override)
      (let ((cell (assoc (car pair) result)))
        (if cell
            (setcdr cell (cdr pair))
          (setq result (append result (list (cons (car pair) (cdr pair))))))))
    result))

(defun ebasecamp-model--merge-service (service override context)
  "把服务覆盖 OVERRIDE（plist）合并到 SERVICE 的副本并返回新对象。
image、command、entrypoint、ports、volumes、healthcheck、depends-on、
networks、working-dir、user、restart 整体替换；environment、labels 与
extra 按键合并。CONTEXT 用于错误消息。"
  (ebasecamp-model--check-plist override ebasecamp-model--service-keywords context)
  (let ((merged (copy-ebasecamp-service service)))
    (when (plist-member override :image)
      (setf (ebasecamp-service-image merged) (plist-get override :image)))
    (when (plist-member override :command)
      (setf (ebasecamp-service-command merged)
            (ebasecamp-model--normalize-string-list
             (plist-get override :command) context)))
    (when (plist-member override :entrypoint)
      (setf (ebasecamp-service-entrypoint merged)
            (ebasecamp-model--normalize-string-list
             (plist-get override :entrypoint) context)))
    (when (plist-member override :ports)
      (setf (ebasecamp-service-ports merged) (plist-get override :ports)))
    (when (plist-member override :volumes)
      (setf (ebasecamp-service-volumes merged) (plist-get override :volumes)))
    (when (plist-member override :healthcheck)
      (setf (ebasecamp-service-healthcheck merged)
            (plist-get override :healthcheck)))
    (when (plist-member override :depends-on)
      (setf (ebasecamp-service-depends-on merged)
            (plist-get override :depends-on)))
    (when (plist-member override :networks)
      (setf (ebasecamp-service-networks merged)
            (plist-get override :networks)))
    (when (plist-member override :working-dir)
      (setf (ebasecamp-service-working-dir merged)
            (plist-get override :working-dir)))
    (when (plist-member override :user)
      (setf (ebasecamp-service-user merged) (plist-get override :user)))
    (when (plist-member override :restart)
      (setf (ebasecamp-service-restart merged) (plist-get override :restart)))
    (when (plist-member override :environment)
      (setf (ebasecamp-service-environment merged)
            (ebasecamp-model--merge-alist
             (ebasecamp-service-environment merged)
             (plist-get override :environment))))
    (when (plist-member override :labels)
      (setf (ebasecamp-service-labels merged)
            (ebasecamp-model--merge-alist
             (ebasecamp-service-labels merged)
             (plist-get override :labels))))
    (when (plist-member override :extra)
      (setf (ebasecamp-service-extra merged)
            (ebasecamp-model--merge-alist
             (ebasecamp-service-extra merged)
             (plist-get override :extra))))
    merged))

(defun ebasecamp-model-resolve-services (project group-ref)
  "返回组引用 GROUP-REF 在项目 PROJECT 下的服务列表。
GROUP-REF 为项目 groups 字段中的一项，形如
(:group SYMBOL :scope SCOPE :service-overrides ALIST)。
GROUP-REF 的 :scope 只影响该项目的解析语义，不修改组对象；返回的
service 均为新对象，不修改组内已有对象。"
  (unless (ebasecamp-project-p project)
    (ebasecamp-model--fail "PROJECT 必须是 ebasecamp-project 对象，得到 %S"
                           project))
  (let* ((name (plist-get group-ref :group))
         (group (and name (ebasecamp-model-group name)))
         (context (format "项目 %s / 组 %S"
                          (ebasecamp-project-name project) name)))
    (unless group
      (ebasecamp-model--fail "%s: 组未注册" context))
    (let ((overrides (plist-get group-ref :service-overrides))
          (services (ebasecamp-group-services group))
          (result nil))
      (dolist (override overrides)
        (unless (cl-find (car override) services
                         :key #'ebasecamp-service-name :test #'eq)
          (ebasecamp-model--fail "%s: 覆盖了不存在的服务 %S"
                                 context (car override))))
      (dolist (service services)
        (let ((cell (assq (ebasecamp-service-name service) overrides)))
          (push (if cell
                    (ebasecamp-model--merge-service service (cdr cell) context)
                  (copy-ebasecamp-service service))
                result)))
      (nreverse result))))

(provide 'ebasecamp-model)
;;; ebasecamp-model.el ends here
