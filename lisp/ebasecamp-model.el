;;; ebasecamp-model.el --- ebasecamp 清单数据模型 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.5.3
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
;; - 组内配置访问器：ebasecamp-model-group-configs、ebasecamp-model-config、
;;   ebasecamp-model-config-project
;; - 项目覆盖合并：ebasecamp-model-resolve-services
;; - 加载期物化：ebasecamp-model-link-configs（把组内配置并入项目 groups 槽）
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
;; 组的 configs 槽保存组内配置，形如 ((CONFIG-NAME . PLIST) ...)：
;;   :project  必填 symbol，指向关联的项目（存在性在物化阶段校验）
;;   :services 可选，覆盖格式与项目组引用完全一致
;; 配置不允许 :scope（D9）——配置的 scope 恒等于组定义的 scope。
;;
;; 安全约定：清单只保存 ${VAR} 引用与相对路径；本模块不读取、不插值、
;; 不落盘任何密钥值。

;;; Code:

(require 'cl-lib)

(define-error 'ebasecamp-model-error "Invalid ebasecamp model")
(define-error 'ebasecamp-model-config-link-error
  "Config materialization error"
  'ebasecamp-model-error)

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
  "服务组定义。SCOPE 为 shared 或 per-project。
CONFIGS 为 ((CONFIG-NAME . PLIST) ...)，按定义顺序排列。"
  name title scope services configs)

(cl-defstruct (ebasecamp-project (:constructor ebasecamp-project-create))
  "项目定义。GROUPS 为归一化后的组引用 plist 列表。
FILE-CONFIGS / FILE-SECRETS 为 compose 顶层 `configs:' / `secrets:' 段的原样
结构（键全为字符串的 alist，可多层嵌套），未声明时为 nil。"
  name title root groups shared-network export-file file-configs file-secrets)

;;; 允许的关键字

(defconst ebasecamp-model--group-keywords
  '(:title :scope :services :configs)
  "组定义允许的关键字。")

(defconst ebasecamp-model--config-keywords
  '(:project :services)
  "组内配置允许的关键字。
配置的 scope 恒等于组定义的 scope（D9），因此不允许 :scope。")

(defconst ebasecamp-model--service-keywords
  '(:image :command :entrypoint :environment :labels :ports :volumes
    :healthcheck :depends-on :networks :working-dir :user :restart :extra)
  "服务定义允许的关键字。")

(defconst ebasecamp-model--project-keywords
  '(:title :root :shared-network :export-file :file-configs :file-secrets
    :groups)
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

(defvar ebasecamp-model--legacy-groups (make-hash-table :test #'eq)
  "物化前的项目组引用基线：项目名 -> 引用列表。
`ebasecamp-model-link-configs' 首次处理某项目时把它的 groups 槽记在这里，
之后的每次物化都以该基线为起点重算，因此重复调用不会累积重复引用。")

(defun ebasecamp-model-reset ()
  "清空组与项目注册表，供清单重新加载前调用。"
  (setq ebasecamp-model--groups nil
        ebasecamp-model--projects nil)
  (clrhash ebasecamp-model--legacy-groups))

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

(defun ebasecamp-model--as-group (value context)
  "把 VALUE（组对象或已注册的组名）解析为 ebasecamp-group 对象。
CONTEXT 用于错误消息。"
  (cond
   ((ebasecamp-group-p value) value)
   ((and value (symbolp value))
    (or (ebasecamp-model-group value)
        (ebasecamp-model--fail "%s: 组 %S 未注册" context value)))
   (t
    (ebasecamp-model--fail "%s: 期望组对象或组名，得到 %S" context value))))

(defun ebasecamp-model-group-configs (group)
  "返回 GROUP 的组内配置，形如 ((CONFIG-NAME . PLIST) ...)。
顺序为定义顺序；GROUP 可为组对象或已注册的组名。无配置时返回 nil。"
  (ebasecamp-group-configs (ebasecamp-model--as-group group "组配置")))

(defun ebasecamp-model-config (group config-name)
  "返回 GROUP 中名为 CONFIG-NAME 的配置 plist，不存在时返回 nil。
GROUP 可为组对象或已注册的组名。"
  (cdr (assq config-name (ebasecamp-model-group-configs group))))

(defun ebasecamp-model-config-project (config-plist)
  "返回配置 PLIST 关联的项目名（symbol）。"
  (plist-get config-plist :project))

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

(defun ebasecamp-model--check-file-mapping (value context)
  "检查 VALUE 为 nil 或「键全为字符串的 alist」，并递归校验所有嵌套层。
CONTEXT 用于错误消息。

值取自 compose 顶层 `configs:' / `secrets:' 段的原样结构，模型只做形态校验、
不做语义校验。为什么必须递归查字符串键：渲染层 `ebasecamp-compose--mapping-p'
只把「元素是 (STRING-KEY . VALUE)」的列表当映射，符号键会被当序列渲染成
`- file' 之类的错误 YAML（X0 实测：符号键 + 点对会 signal，符号键 + 正规表
会产出垃圾 YAML），因此这一层不给糊弄过去。"
  (cond
   ((null value) nil)
   ((not (and (consp value) (proper-list-p value)))
    (ebasecamp-model--fail "%s: 期望字符串键 alist 或 nil，得到 %S"
                           context value))
   (t
    (dolist (pair value)
      (unless (and (consp pair) (stringp (car pair)))
        (ebasecamp-model--fail
         "%s: 期望 (\"键\" . 值) 元素，键必须是字符串，得到 %S"
         context pair))
      (ebasecamp-model--check-file-mapping-nested
       (cdr pair) (format "%s 的 \"%s\"" context (car pair)))))))

(defun ebasecamp-model--check-file-mapping-nested (value context)
  "递归校验 VALUE 中每一层 alist 的键都是字符串；标量（字符串/数字/t）放行。
CONTEXT 用于错误消息。映射层与序列层的判别与渲染层一致：列表首元素是 cons
即当映射处理。"
  (cond
   ((or (null value) (not (consp value))) nil)
   ((not (proper-list-p value))
    (ebasecamp-model--fail "%s: 期望 alist / 列表 / 标量，得到点对列表 %S"
                           context value))
   ((consp (car value))                 ; 映射层
    (dolist (pair value)
      (unless (and (consp pair) (stringp (car pair)))
        (ebasecamp-model--fail "%s: 键必须是字符串，得到 %S" context pair))
      (ebasecamp-model--check-file-mapping-nested
       (cdr pair) (format "%s 的 \"%s\"" context (car pair)))))
   (t                                   ; 序列层
    (dolist (item value)
      (ebasecamp-model--check-file-mapping-nested item context)))))

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

(defun ebasecamp-model--normalize-service-overrides (overrides context)
  "把服务覆盖列表 OVERRIDES 归一化为 ((SERVICE-NAME . PLIST) ...)。
格式与项目组引用的 :services 完全一致。CONTEXT 用于错误消息。"
  (unless (or (null overrides) (proper-list-p overrides))
    (ebasecamp-model--fail "%s: :services 必须是列表，得到 %S"
                           context overrides))
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
                 plist ebasecamp-model--service-keywords service-context)
                (ebasecamp-model--check-service-values
                 plist service-context)
                (cons service-name plist))))
          overrides))

(defun ebasecamp-model--config-from-spec (spec context)
  "校验配置定义 SPEC 并返回 (CONFIG-NAME . PLIST)。
SPEC 形如 (CONFIG-NAME :project PROJECT :services 覆盖...)；配置不允许
:scope（D9）。:project 指向的项目是否存在留到物化阶段校验，因为项目
文件可能后加载。CONTEXT 用于错误消息。"
  (unless (consp spec)
    (ebasecamp-model--fail "%s: 配置定义必须是 (NAME 属性...)，得到 %S"
                           context spec))
  (let ((name (car spec)))
    (ebasecamp-model--check-name name (format "%s 的配置名" context))
    (let ((config-context (format "%s.%s" context name))
          (plist (cdr spec)))
      (when (plist-member plist :scope)
        (ebasecamp-model--fail
         "%s: 配置不允许 :scope（只允许 :project 与 :services）"
         config-context))
      (ebasecamp-model--check-plist plist ebasecamp-model--config-keywords
                                    config-context)
      (let ((project (plist-get plist :project)))
        (cond
         ((null project)
          (ebasecamp-model--fail "%s: 配置缺少 :project" config-context))
         ((not (symbolp project))
          (ebasecamp-model--fail "%s: :project 必须是 symbol，得到 %S"
                                 config-context project))))
      ;; 覆盖格式复用处：服务名是否存在同样留到物化阶段校验
      (ebasecamp-model--normalize-service-overrides
       (plist-get plist :services) config-context)
      (cons name plist))))

(defun ebasecamp-model--configs-from-specs (configs context)
  "把配置定义列表 CONFIGS 解析为 ((CONFIG-NAME . PLIST) ...)。
保持定义顺序，同组内配置名重复时报错。CONTEXT 用于错误消息。"
  (let ((parsed nil)
        (seen nil))
    (dolist (spec configs)
      (let* ((config (ebasecamp-model--config-from-spec spec context))
             (config-name (car config)))
        (when (memq config-name seen)
          (ebasecamp-model--fail "%s: 配置名 %S 重复" context config-name))
        (push config-name seen)
        (setq parsed (append parsed (list config)))))
    parsed))

(defun ebasecamp-model--group-from-spec (name plist context)
  "由组名 NAME 与属性 PLIST 构造 ebasecamp-group 对象。
CONTEXT 用于错误消息。"
  (ebasecamp-model--check-name name context)
  (let ((context (format "%s.%s" context name)))
    (ebasecamp-model--check-plist plist ebasecamp-model--group-keywords context)
    (let ((title (plist-get plist :title))
          (scope (plist-get plist :scope))
          (services (plist-get plist :services))
          (configs (plist-get plist :configs)))
      (when (and title (not (stringp title)))
        (ebasecamp-model--fail "%s: :title 必须是字符串，得到 %S"
                               context title))
      (when scope
        (ebasecamp-model--check-scope scope context))
      (unless (or (null services) (proper-list-p services))
        (ebasecamp-model--fail "%s: :services 必须是列表，得到 %S"
                               context services))
      (unless (or (null configs) (proper-list-p configs))
        (ebasecamp-model--fail "%s: :configs 必须是列表，得到 %S"
                               context configs))
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
                         services)
       :configs (ebasecamp-model--configs-from-specs configs context)))))

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
        (list :group name
              :scope scope
              :service-overrides
              (ebasecamp-model--normalize-service-overrides overrides context))))))

(defun ebasecamp-model--project-from-spec (name plist context)
  "由项目名 NAME 与属性 PLIST 构造 ebasecamp-project 对象。
CONTEXT 用于错误消息。"
  (ebasecamp-model--check-name name context)
  (let ((context (format "%s.%s" context name)))
    (ebasecamp-model--check-plist plist ebasecamp-model--project-keywords context)
    (let ((title (plist-get plist :title))
          (root (plist-get plist :root))
          (export-file (plist-get plist :export-file))
          (file-configs (plist-get plist :file-configs))
          (file-secrets (plist-get plist :file-secrets))
          (groups (plist-get plist :groups)))
      (when (and title (not (stringp title)))
        (ebasecamp-model--fail "%s: :title 必须是字符串，得到 %S"
                               context title))
      (when (and root (not (stringp root)))
        (ebasecamp-model--fail "%s: :root 必须是字符串，得到 %S" context root))
      (when (and export-file (not (stringp export-file)))
        (ebasecamp-model--fail "%s: :export-file 必须是字符串，得到 %S"
                               context export-file))
      (ebasecamp-model--check-file-mapping
       file-configs (concat context ":file-configs"))
      (ebasecamp-model--check-file-mapping
       file-secrets (concat context ":file-secrets"))
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
       :export-file export-file
       :file-configs file-configs
       :file-secrets file-secrets))))

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
ARGS 允许的关键字为 :title、:scope、:services、:configs，:scope 取值
shared 或 per-project，缺省 per-project。:configs 每项形如
\(CONFIG-NAME :project PROJECT :services 覆盖...)，配置不允许 :scope。
展开后注册到组注册表并返回组名。"
  (declare (indent 1))
  (unless (symbolp name)
    (ebasecamp-model--fail "组名必须是 symbol，得到 %S" name))
  `(progn
     (ebasecamp-model--register-group ',name ',args)
     ',name))

(defmacro ebasecamp-define-project (name &rest args)
  "定义项目 NAME，属性见 ARGS。
ARGS 允许的关键字为 :title、:root、:shared-network、:export-file、
:file-configs、:file-secrets、:groups。
:groups 的每一项形如 (GROUP :scope SCOPE :services ((SERVICE 属性...)...))。
:file-configs / :file-secrets 为 compose 顶层 `configs:' / `secrets:' 段的原样
结构（键全为字符串的 alist，可多层嵌套），未声明时为 nil。
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

;;; 加载期物化

(defun ebasecamp-model--legacy-groups-of (project)
  "返回 PROJECT 物化前的组引用列表。
首次调用某项目时把它的 groups 槽记为基线缓存，之后每次返回基线的浅拷贝，
使 `ebasecamp-model-link-configs' 可以「从基线重算」实现幂等。"
  (let* ((name (ebasecamp-project-name project))
         (snapshot (gethash name ebasecamp-model--legacy-groups
                            'ebasecamp-model--unset)))
    (when (eq snapshot 'ebasecamp-model--unset)
      (setq snapshot (copy-sequence (ebasecamp-project-groups project)))
      (puthash name snapshot ebasecamp-model--legacy-groups))
    (copy-sequence snapshot)))

(defun ebasecamp-model--link-error (code pair format-string &rest args)
  "构造一条物化错误项，形如 `ebasecamp-config-load' 的 :errors 元素。
CODE 为标识错误类别的关键字，PAIR 为 (组名 . 项目名) 上下文（供上层定位
定义文件），FORMAT-STRING 与 ARGS 组成人类可读描述。:file 恒为 nil，
由调用方补填。"
  (list :file nil
        :condition (list 'ebasecamp-model-config-link-error code pair)
        :message (apply #'format format-string args)))

(defun ebasecamp-model--config-ref (group config)
  "把 GROUP 的配置 CONFIG 转为项目组引用 plist。
CONFIG 形如 (CONFIG-NAME . PLIST)。返回
\(:group SYMBOL :scope SCOPE :service-overrides ALIST)（D6 键名不变量：
只写 :service-overrides，绝不写 :services）；覆盖项非法时以
`ebasecamp-model-error' 报错。"
  (let ((group-name (ebasecamp-group-name group)))
    (list :group group-name
          :scope (ebasecamp-group-scope group)
          :service-overrides
          (ebasecamp-model--normalize-service-overrides
           (plist-get (cdr config) :services)
           (format "配置 %s/%s" group-name (car config))))))

(defun ebasecamp-model--replace-group-reference (project group-name reference)
  "把 PROJECT 的 groups 槽中首个 :group 为 GROUP-NAME 的引用替换为 REFERENCE。
原位替换：只对该列表元素所在的 cell 做 setcar，保持元素位置不变；
REFERENCE 的 plist 内容不被修改（基线是浅拷贝，不得污染旧引用对象）。
命中并替换时返回 t，未命中返回 nil。"
  (let ((cells (ebasecamp-project-groups project))
        (replaced nil))
    (while (and cells (null replaced))
      (if (eq group-name (plist-get (car cells) :group))
          (progn
            (setcar cells reference)
            (setq replaced t))
        (setq cells (cdr cells))))
    replaced))

(defun ebasecamp-model--unknown-override (services overrides)
  "返回 OVERRIDES 中未在 SERVICES 里定义的首个服务名，全部存在时返回 nil。"
  (let (unknown)
    (while (and overrides (null unknown))
      (unless (cl-find (car (car overrides)) services
                       :key #'ebasecamp-service-name :test #'eq)
        (setq unknown (car (car overrides))))
      (setq overrides (cdr overrides)))
    unknown))

(defun ebasecamp-model-link-configs ()
  "把所有组的 :configs 物化进对应项目的 groups 槽。
返回错误列表，每项与 `ebasecamp-config-load' 的 :errors 元素同形
\(:file PATH :condition CONDITION-DATA :message STRING)，其中 :file 恒为
nil（模型层不感知文件），由调用方补填定义文件。本函数不 signal：单份配置
失败只记一条错误，其余配置继续物化。

物化规则：每份配置产出一个组引用
\(:group GROUP :scope GROUP-SCOPE :service-overrides ALIST)，ALIST 由
`ebasecamp-model--normalize-service-overrides' 归一化（D6：不写 :services）。
项目侧旧 :groups 引用保持在前（被组侧配置接管的除外，见下），物化结果按
「组定义顺序 → 配置定义顺序」追加在后。

旧写法兼容（A-I）：项目的旧 `:groups' 与组侧 `:configs' 指向**同一项目
同一组**时，由组侧配置**原位接管**该引用（列表位置不变，:group / :scope /
:service-overrides 取配置值），不记错误；仅当**两份以上组侧配置**指向同一
项目同一组时才记 :duplicate-group（容器标签无配置维度，服务名会撞）。

校验（任一命中即记错误并跳过该配置，不中断其余项）：
- 配置引用的项目未定义；
- 同项目同组已有**另一份配置**物化出的引用（旧 :groups 的引用可被接管，
  不算冲突）；
- shared 组配置份数超过 1（整组跳过，无法判定哪份生效）；
- 覆盖了组内不存在的服务；
- 覆盖项本身非法（`ebasecamp-model-error'，B2 已校验，此处兜底）。

幂等：首次调用时把每个项目的 groups 槽记为基线，之后每次调用都从基线
重算并重新追加，因此连续调用不会产生重复引用。不调用本函数时，项目
groups 槽保持定义时的原样（v0.1 行为不变）。"
  (let ((sources (make-hash-table :test #'equal))
        (legacy (make-hash-table :test #'equal))
        (errors nil))
    ;; 1. 项目 groups 槽回到物化前基线，并登记旧引用的来源：sources 供错误
    ;;    消息使用（其值只用于消息，不作判据），legacy 标记该引用可被组侧
    ;;    配置原位接管。
    (dolist (project (ebasecamp-model-projects))
      (let ((project-name (ebasecamp-project-name project))
            (baseline (ebasecamp-model--legacy-groups-of project)))
        (dolist (reference baseline)
          (puthash (cons project-name (plist-get reference :group))
                   "旧 :groups" sources)
          (puthash (cons project-name (plist-get reference :group)) t legacy))
        (setf (ebasecamp-project-groups project) baseline)))
    ;; 2. 逐组逐份配置校验并物化
    (dolist (group (ebasecamp-model-groups))
      (let* ((group-name (ebasecamp-group-name group))
             (configs (ebasecamp-group-configs group))
             (services (ebasecamp-group-services group)))
        (cond
         ((null configs) nil)
         ;; E3：shared 组至多 1 份配置
         ((and (eq (ebasecamp-group-scope group) 'shared)
               (> (length configs) 1))
          (push (ebasecamp-model--link-error
                 :shared-multiple-configs (cons group-name nil)
                 "shared 组 %s 至多 1 份配置（实际 %d 份）"
                 group-name (length configs))
                errors))
         (t
          (dolist (config configs)
            (let* ((config-name (car config))
                   (project-name
                    (ebasecamp-model-config-project (cdr config)))
                   (project (and project-name
                                 (ebasecamp-model-project project-name))))
              (cond
               ;; E1：配置引用了未定义的项目
               ((null project)
                (push (ebasecamp-model--link-error
                       :undefined-project (cons group-name project-name)
                       "配置 %s/%s 引用了未定义的项目 %s"
                       group-name config-name project-name)
                      errors))
               ;; E2：同项目同组已有引用（旧 :groups 或先前物化的配置）。
               ;; A-I：该引用若来自旧 :groups（legacy 有标记），不报错，交给
               ;; 下方物化分支原位接管；否则保持原判定记错误。
               ((and (cl-find group-name (ebasecamp-project-groups project)
                              :key (lambda (reference)
                                     (plist-get reference :group))
                              :test #'eq)
                     (not (gethash (cons project-name group-name) legacy)))
                (push (ebasecamp-model--link-error
                       :duplicate-group (cons group-name project-name)
                       "项目 %s 重复引用组 %s（来源：%s）"
                       project-name group-name
                       (or (gethash (cons project-name group-name) sources)
                           "另一份配置"))
                      errors))
               (t
                (let ((reference nil)
                      (failure nil))
                  (condition-case err
                      (setq reference (ebasecamp-model--config-ref
                                       group config))
                    (ebasecamp-model-error
                     (setq failure err)))
                  (cond
                   ;; E5：覆盖项本身非法（B2 已校验，此处兜底）
                   (failure
                    (push (ebasecamp-model--link-error
                           :invalid-services (cons group-name project-name)
                           "配置 %s/%s 的 :services 非法：%s"
                           group-name config-name
                           (error-message-string failure))
                          errors))
                   (t
                    (let ((unknown
                           (ebasecamp-model--unknown-override
                            services
                            (plist-get reference :service-overrides))))
                      (if unknown
                          ;; E4：覆盖了组内不存在的服务
                          (push (ebasecamp-model--link-error
                                 :unknown-service
                                 (cons group-name project-name)
                                 "配置 %s/%s 覆盖了不存在的服务 %s"
                                 group-name config-name unknown)
                                errors)
                        (if (gethash (cons project-name group-name) legacy)
                            ;; A-I：旧 :groups 的引用由组侧配置原位接管
                            ;; （位置不变），接管后立即清除 legacy 标记，
                            ;; 否则第二份配置会再次接管并静默丢掉第一份。
                            (progn
                              (ebasecamp-model--replace-group-reference
                               project group-name reference)
                              (remhash (cons project-name group-name) legacy))
                          (setf (ebasecamp-project-groups project)
                                (append (ebasecamp-project-groups project)
                                        (list reference))))
                        (puthash (cons project-name group-name)
                                 (format "配置 %s" config-name)
                                 sources))))))))))))))
    (nreverse errors)))

(provide 'ebasecamp-model)
;;; ebasecamp-model.el ends here
