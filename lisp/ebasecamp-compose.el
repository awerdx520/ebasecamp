;;; ebasecamp-compose.el --- ebasecamp compose 生成 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.5.3
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 清单 → compose 的唯一渲染入口：把 `ebasecamp-model' 的组与项目（含项目级
;; 覆盖）渲染为 docker compose 可接受的 YAML 文本。本模块只做「写」：不调用
;; docker、不解析 YAML（读取 compose 一律交给 `docker compose config'）。
;;
;; 命名不变量（见 AGENTS.md）：
;; - 被渲染的组全部为 shared 时，compose 项目名固定 `ebc-shared'；
;; - 否则为 `ebc-<project>'；
;; - 项目名与组名只允许 [a-z0-9_-]+，由 `ebasecamp-compose--name-string' 校验。
;;
;; 生成物位置：<ebasecamp-cache-directory>/<project>/compose.yaml；shared 组
;; 单独生成时目录为 `_shared'，避免与项目自身生成物互相覆盖。
;;
;; 网络声明：`ebasecamp' 在顶层声明为 external network（project 的
;; shared-network 非 nil 时）；服务引用的其余网络在顶层以空映射声明，由
;; compose 按项目创建 —— 不声明会让 `config -q' 报「引用了未定义网络」。
;;
;; 跨 scope 依赖：shared 组与 per-project 组落在不同 compose 项目
;; （`ebc-shared' / `ebc-<project>'），生成物互相独立。按 scope 渲染
;; （GROUP-FILTER 非 nil）时，depends-on 中指向本次未渲染服务的名字会被剔除
;; —— 这些依赖在另一个 compose 项目里，保留会让 `docker compose up' 报
;; 「depends on undefined service」。全量渲染（GROUP-FILTER 为 nil，预览/导出）
;; 保留全部依赖，供 `ebasecamp-command' 计算跨 scope 依赖闭包。
;;
;; 标签不变量：所有托管服务注入 ebasecamp.managed / .project / .group /
;; .service / .scope 五项；用户 labels 先写入，同名键由注入项覆盖。
;;
;; 只读约定：`ebasecamp-model-resolve-services' 返回的是浅拷贝，ports /
;; volumes / environment / extra 的列表结构与组内对象共享，因此本模块对这些
;; 字段一律只读，禁止 setcar / plist-put 就地修改（需要副本时自行复制 cons）。
;;
;; YAML 输出约定：2 空格缩进、block style；标量按需加双引号并转义 `\\` 与
;; `"'；image 属已知安全的镜像引用，按原样裸写；序列化器只覆盖清单可能出现的
;; 类型（字符串/数字/布尔/列表/alist）。
;;
;; 安全约定：environment 中的 ${VAR} 原样保留，不插值、不转义 `$'。

;;; Code:

(require 'cl-lib)
(require 'ebasecamp-model)

(define-error 'ebasecamp-compose-error "Invalid ebasecamp compose")

(defcustom ebasecamp-cache-directory (expand-file-name "~/.cache/ebasecamp/")
  "ebasecamp 生成物缓存目录。
compose 生成物写入 <该目录>/<project>/compose.yaml，属可随时重建的派生产物，
不得手工编辑。"
  :type 'directory
  :group 'ebasecamp)

(defconst ebasecamp-compose--name-regexp "\\`[a-z0-9_-]+\\'"
  "项目名与组名的合法字符集：小写字母、数字、下划线、连字符。")

(defconst ebasecamp-compose--special-characters ":#{}[],&*!|>'\"%@`"
  "YAML 标量中必须加双引号的字符。")

;;; 名字校验

(defun ebasecamp-compose--name-string (name context)
  "把 NAME（symbol 或字符串）转成字符串并校验字符集，返回该字符串。
NAME 必须匹配 [a-z0-9_-]+，否则以 CONTEXT 报告 ebasecamp-compose-error。
纯函数：不读写注册表、不访问文件。"
  (let ((string (cond ((stringp name) name)
                      ((symbolp name) (symbol-name name))
                      (t nil)))
        (case-fold-search nil))
    (unless (and string (string-match-p ebasecamp-compose--name-regexp string))
      (signal 'ebasecamp-compose-error
              (list (format "%s: 名字 %S 不合法，只允许 [a-z0-9_-]+"
                            context name))))
    string))

;;; 标量序列化

(defun ebasecamp-compose--has-special-character-p (string)
  "判断 STRING 是否含有必须加引号的特殊字符。"
  (let ((rest (string-to-list ebasecamp-compose--special-characters))
        (found nil))
    (while (and rest (not found))
      (when (string-match-p (regexp-quote (char-to-string (car rest))) string)
        (setq found t))
      (setq rest (cdr rest)))
    found))

(defun ebasecamp-compose--quote-required-p (string)
  "判断 STRING 作为 YAML 标量是否必须加双引号。
含特殊字符、前后空格、空串，或形如数字/布尔（含 null、~）时需要加引号。"
  (or (equal string "")
      (string-match-p "\\`[[:space:]]" string)
      (string-match-p "[[:space:]]\\'" string)
      (ebasecamp-compose--has-special-character-p string)
      (string-match-p "\\`[-+]?[0-9]+\\(?:\\.[0-9]+\\)?\\'" string)
      (member (downcase string)
              '("true" "false" "yes" "no" "on" "off" "null" "~"))))

(defun ebasecamp-compose--escape-string (string)
  "转义 STRING 中的反斜线与双引号，供双引号标量使用。"
  (replace-regexp-in-string
   "[\\\\\"]" (lambda (match) (concat "\\" match)) string t t))

(defun ebasecamp-compose--yaml-string (string)
  "把 STRING 渲染为 YAML 标量，必要时加双引号。"
  (if (ebasecamp-compose--quote-required-p string)
      (concat "\"" (ebasecamp-compose--escape-string string) "\"")
    string))

(defun ebasecamp-compose--yaml-scalar (value)
  "把标量 VALUE 渲染为 YAML 文本。
nil 输出 null，t 输出 true，数字原样，其余按字符串处理。"
  (cond
   ((null value) "null")
   ((eq value t) "true")
   ((numberp value) (number-to-string value))
   (t (ebasecamp-compose--yaml-string
       (if (stringp value) value (format "%s" value))))))

(defun ebasecamp-compose--yaml-key (key)
  "把映射键 KEY 渲染为 YAML 文本。
关键字去掉前导冒号，symbol 取名字，其余按字符串处理。"
  (ebasecamp-compose--yaml-string
   (cond ((keywordp key) (substring (symbol-name key) 1))
         ((symbolp key) (symbol-name key))
         ((stringp key) key)
         (t (format "%s" key)))))

(defun ebasecamp-compose--mapping-p (value)
  "判断 VALUE 是否为映射（元素为 (STRING-KEY . VALUE) 的 alist）。
键必须是字符串：清单里 alist 的键一律是字符串，而「元素为 alist 的列表」
（如 `:extra' 里的端口对象列表 `(((\"host_ip\" . \"127.0.0.1\") …))'）是
序列，不能当映射展开 —— 否则 `(car pair)' 是 cons，会被 `--yaml-key' 渲染成
`(host_ip . 127.0.0.1)' 这类垃圾键（tech-debt #21）。"
  (and (consp value)
       (consp (car value))
       (stringp (caar value))))

;;; 序列化器

(defun ebasecamp-compose--yaml-flow-item (item)
  "把 ITEM 渲染为 flow 序列元素：字符串一律加双引号。"
  (cond ((null item) "null")
        ((eq item t) "true")
        ((numberp item) (number-to-string item))
        ((stringp item) (concat "\"" (ebasecamp-compose--escape-string item) "\""))
        (t (concat "\""
                   (ebasecamp-compose--escape-string (format "%s" item))
                   "\""))))

(defun ebasecamp-compose--yaml-flow-sequence (items)
  "把 ITEMS 渲染为 flow 序列，如 [\"sleep\",\"3600\"]。"
  (concat "[" (mapconcat #'ebasecamp-compose--yaml-flow-item items ",") "]"))

(defun ebasecamp-compose--yaml-value (value indent)
  "把 VALUE 渲染为 block 风格 YAML 文本，每行缩进 INDENT 个空格。
映射逐键展开、列表渲染为 `- item'、其余按标量输出；嵌套值缩进 2 空格。"
  (cond
   ((ebasecamp-compose--mapping-p value)
    (mapconcat
     (lambda (pair)
       (let ((key (concat (make-string indent ?\s)
                          (ebasecamp-compose--yaml-key (car pair))
                          ":"))
             (nested (cdr pair)))
         (if (and (listp nested) nested)
             (concat key "\n"
                     (ebasecamp-compose--yaml-value nested (+ indent 2)))
           (concat key " " (ebasecamp-compose--yaml-scalar nested)))))
     value
     "\n"))
   ((and (listp value) value)
    (mapconcat
     (lambda (item)
       (let ((pad (make-string indent ?\s)))
         (if (and (listp item) item)
             (concat pad "-\n"
                     (ebasecamp-compose--yaml-value item (+ indent 2)))
           (concat pad "- " (ebasecamp-compose--yaml-scalar item)))))
     value
     "\n"))
   (t (concat (make-string indent ?\s)
              (ebasecamp-compose--yaml-scalar value)))))

(defun ebasecamp-compose--yaml-map (alist indent)
  "把 ALIST 渲染为 block 映射，每行缩进 INDENT 个空格。"
  (ebasecamp-compose--yaml-value alist indent))

(defun ebasecamp-compose--yaml-sequence (items indent)
  "把 ITEMS 渲染为 block 序列，每项一行并缩进 INDENT 个空格。"
  (ebasecamp-compose--yaml-value items indent))

;;; 组引用与 scope

(defun ebasecamp-compose--ref-group-name (ref)
  "返回组引用 REF 指向的组名 symbol。
REF 可以是项目 groups 字段中的引用 plist、ebasecamp-group 对象或组名 symbol。"
  (cond ((ebasecamp-group-p ref) (ebasecamp-group-name ref))
        ((consp ref) (plist-get ref :group))
        (t ref)))

(defun ebasecamp-compose--ref-scope (ref)
  "返回组引用 REF 的有效 scope（shared 或 per-project）。
引用里的 :scope 覆盖组自身声明；缺省取组声明的 scope；组不存在时按
per-project 处理。"
  (let* ((name (ebasecamp-compose--ref-group-name ref))
         (group (and name (ebasecamp-model-group name)))
         (declared (cond ((ebasecamp-group-p ref) (ebasecamp-group-scope ref))
                         ((consp ref)
                          (or (plist-get ref :scope)
                              (and group (ebasecamp-group-scope group))))
                         (t (and group (ebasecamp-group-scope group))))))
    (or declared 'per-project)))

(defun ebasecamp-compose--scope-string (scope)
  "把 SCOPE（shared 或 per-project）转为标签与卷名使用的字符串。"
  (if (eq scope 'shared) "shared" "per-project"))

(defun ebasecamp-compose--all-shared-p (refs)
  "判断组引用列表 REFS 是否非空且全部为 shared scope。"
  (and refs
       (cl-every (lambda (ref) (eq 'shared (ebasecamp-compose--ref-scope ref)))
                 refs)))

(defun ebasecamp-compose--compose-name (project refs)
  "由项目 PROJECT 与被渲染的组引用 REFS 推导 compose 项目名。
REFS 全部为 shared 时为 \"ebc-shared\"，否则为 \"ebc-<project>\"；
项目名与全部组名都经过字符集校验。"
  (let ((project-name (ebasecamp-compose--name-string
                       (ebasecamp-project-name project) "项目名")))
    (dolist (ref refs)
      (ebasecamp-compose--name-string
       (ebasecamp-compose--ref-group-name ref) "组名"))
    (if (ebasecamp-compose--all-shared-p refs)
        "ebc-shared"
      (concat "ebc-" project-name))))

(defun ebasecamp-compose--group-refs (project group-filter)
  "返回 PROJECT 中需要渲染的组引用列表。
GROUP-FILTER 为 nil 时返回项目引用的全部组（保持项目定义顺序）；否则
只保留其 :group 命中 GROUP-FILTER 的引用；GROUP-FILTER 可以是 symbol、
字符串或它们的列表。过滤项未被项目引用时报 ebasecamp-compose-error。"
  (let ((refs (ebasecamp-project-groups project)))
    (if (null group-filter)
        refs
      (let ((names (mapcar (lambda (item) (if (stringp item) (intern item) item))
                           (if (listp group-filter) group-filter
                             (list group-filter))))
            (referenced (mapcar #'ebasecamp-compose--ref-group-name refs)))
        (dolist (name names)
          (unless (memq name referenced)
            (signal 'ebasecamp-compose-error
                    (list (format "项目 %s 未引用组 %S"
                                  (ebasecamp-project-name project) name)))))
        (cl-remove-if-not
         (lambda (ref) (memq (ebasecamp-compose--ref-group-name ref) names))
         refs)))))

(defun ebasecamp-compose--check-project (project)
  "校验 PROJECT 为 ebasecamp-project 对象，否则报 ebasecamp-compose-error。"
  (unless (ebasecamp-project-p project)
    (signal 'ebasecamp-compose-error
            (list (format "PROJECT 必须是 ebasecamp-project 对象，得到 %S"
                          project)))))

;;; 服务体渲染

(defun ebasecamp-compose--volume-entries (service scope group-name)
  "返回 SERVICE 的卷挂载条目列表，元素为 (VOLUME-NAME . MOUNT)。
命名卷的 MOUNT 为 \"<卷名>:<target>\"，VOLUME-NAME 为该卷在顶层的声明名；
bind 卷的 VOLUME-NAME 为 nil。SCOPE 与 GROUP-NAME 参与命名卷名构造，
:read-only 非 nil 时 MOUNT 追加 \":ro\"。只读 SERVICE 的 volumes 字段。"
  (let ((entries nil))
    (dolist (volume (ebasecamp-service-volumes service))
      (let* ((source (plist-get volume :source))
             (target (plist-get volume :target))
             (named (eq (plist-get volume :type) 'volume))
             (volume-name (and named
                               (format "ebasecamp-%s-%s-%s"
                                       (ebasecamp-compose--scope-string scope)
                                       group-name
                                       source)))
             (mount (concat (if named volume-name source)
                            ":"
                            target
                            (if (plist-get volume :read-only) ":ro" ""))))
        (push (cons volume-name mount) entries)))
    (nreverse entries)))

(defun ebasecamp-compose--service-labels (service context)
  "返回 SERVICE 的 labels alist：用户 labels 在前，注入项覆盖同名键。
CONTEXT 为 plist，提供 :project、:group、:scope。不修改 SERVICE 的 labels。"
  (let ((labels (mapcar (lambda (pair) (cons (car pair) (cdr pair)))
                        (ebasecamp-service-labels service)))
        (injected (list (cons "ebasecamp.managed" "true")
                        (cons "ebasecamp.project"
                              (format "%s" (plist-get context :project)))
                        (cons "ebasecamp.group"
                              (format "%s" (plist-get context :group)))
                        (cons "ebasecamp.service"
                              (format "%s" (ebasecamp-service-name service)))
                        (cons "ebasecamp.scope"
                              (ebasecamp-compose--scope-string
                               (plist-get context :scope))))))
    (dolist (pair injected)
      (let ((cell (assoc (car pair) labels)))
        (if cell
            (setcdr cell (cdr pair))
          (setq labels (append labels (list (cons (car pair) (cdr pair))))))))
    labels))

(defun ebasecamp-compose--service-networks (service context)
  "返回 SERVICE 应加入的网络名列表：原有网络在前，ebasecamp 追加在后。
仅当 CONTEXT 的 :shared-network 非 nil 时追加 ebasecamp；重复项只保留一次。
只读 SERVICE 的 networks 字段。"
  (let ((networks (append (ebasecamp-service-networks service) nil)))
    (when (plist-get context :shared-network)
      (unless (member "ebasecamp" networks)
        (setq networks (append networks (list "ebasecamp")))))
    (cl-remove-duplicates networks :test #'equal)))

(defun ebasecamp-compose--filtered-depends-on (depends-on allowed)
  "按 ALLOWED 过滤服务依赖 DEPENDS-ON，返回新列表。
ALLOWED 为 nil 时原样返回 DEPENDS-ON（全量渲染：预览与导出不剔除任何依赖）。
ALLOWED 非 nil 时只保留其成员：按 scope 渲染时生成物只含本次渲染的服务，
指向其他 compose 项目（如 shared 组的 `ebc-shared'）的依赖无法解析，保留会
让 `docker compose up' 报 depends on undefined service。"
  (if (null allowed)
      depends-on
    (cl-remove-if-not (lambda (dependency) (member dependency allowed))
                      depends-on)))

(defun ebasecamp-compose--healthcheck-body (healthcheck indent)
  "把 healthcheck plist HEALTHCHECK 渲染为 block 映射，每行缩进 INDENT。
列表值（如 test）渲染为 flow 序列，其余按标量输出。"
  (let ((lines nil)
        (rest healthcheck))
    (while rest
      (let ((value (cadr rest)))
        (push (concat (make-string indent ?\s)
                      (ebasecamp-compose--yaml-key (car rest))
                      ": "
                      (if (and (listp value) value)
                          (ebasecamp-compose--yaml-flow-sequence value)
                        (ebasecamp-compose--yaml-scalar value)))
              lines))
      (setq rest (cddr rest)))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun ebasecamp-compose--service-body (service context volume-entries
                                               &optional allowed-depends)
  "返回 SERVICE 的服务体文本（每行缩进 4 个空格）。
CONTEXT 为 plist，提供 :project、:group、:scope、:shared-network；
VOLUME-ENTRIES 为 `ebasecamp-compose--volume-entries' 的结果。
ALLOWED-DEPENDS 为 nil 时保留全部 depends-on；非 nil 时只保留其中的名字
（见 `ebasecamp-compose--filtered-depends-on'），剔除后为空则不输出该键。

`:extra' 里的 \"ports\" / \"volumes\" 桶与显式 `:ports' / `:volumes' 字段
同名：二者必须合并成 *单一* 序列（简单项在前、复杂对象项在后）后只渲染一个
键，否则 YAML 会同时出现两个同名键、解析器直接拒绝（`mapping key \"ports\"
already defined'，tech-debt #23 / D6）。合并只影响这两个键，其余 `:extra`
键照旧在服务体末尾展开。"
  (let* ((lines nil)
         (pad (make-string 4 ?\s))
         (nested 6)
         (image (ebasecamp-service-image service))
         (entrypoint (ebasecamp-service-entrypoint service))
         (command (ebasecamp-service-command service))
         (scalars (list (cons "working_dir" (ebasecamp-service-working-dir service))
                        (cons "user" (ebasecamp-service-user service))
                        (cons "restart" (ebasecamp-service-restart service))))
         (environment (ebasecamp-service-environment service))
         (ports (ebasecamp-service-ports service))
         (depends-on (ebasecamp-compose--filtered-depends-on
                      (ebasecamp-service-depends-on service) allowed-depends))
         (healthcheck (ebasecamp-service-healthcheck service))
         (extra (ebasecamp-service-extra service))
         ;; `:extra' 的同名桶（原始对象列表）与其余键分开处理
         (extra-ports (cdr (assoc "ports" extra)))
         (extra-volumes (cdr (assoc "volumes" extra)))
         (rest-extra (cl-remove-if
                      (lambda (pair)
                        (member (car pair) '("ports" "volumes")))
                      extra))
         ;; 简单项（字符串）在前，复杂对象项（alist）在后
         (merged-ports (append (mapcar (lambda (pair)
                                         (format "%d:%d" (car pair) (cdr pair)))
                                       ports)
                               extra-ports))
         (merged-volumes (append (mapcar #'cdr volume-entries)
                                 extra-volumes)))
    ;; 镜像引用属已知安全值，按原样裸写
    (push (concat pad "image: " image) lines)
    (dolist (pair (list (cons "entrypoint" entrypoint)
                        (cons "command" command)))
      (when (cdr pair)
        (push (concat pad (car pair) ": "
                      (if (stringp (cdr pair))
                          (ebasecamp-compose--yaml-string (cdr pair))
                        (ebasecamp-compose--yaml-flow-sequence (cdr pair))))
              lines)))
    (dolist (pair scalars)
      (when (cdr pair)
        (push (concat pad (car pair) ": "
                      (ebasecamp-compose--yaml-string (cdr pair)))
              lines)))
    (when environment
      (push (concat pad "environment:\n"
                    (ebasecamp-compose--yaml-map environment nested))
            lines))
    (push (concat pad "labels:\n"
                  (ebasecamp-compose--yaml-map
                   (ebasecamp-compose--service-labels service context)
                   nested))
          lines)
    (when merged-ports
      (push (concat pad "ports:\n"
                    (ebasecamp-compose--yaml-sequence merged-ports nested))
            lines))
    (when merged-volumes
      (push (concat pad "volumes:\n"
                    (ebasecamp-compose--yaml-sequence merged-volumes nested))
            lines))
    (let ((networks (ebasecamp-compose--service-networks service context)))
      (when networks
        (push (concat pad "networks:\n"
                      (ebasecamp-compose--yaml-sequence networks nested))
              lines)))
    (when depends-on
      (push (concat pad "depends_on:\n"
                    (ebasecamp-compose--yaml-sequence depends-on nested))
            lines))
    (when healthcheck
      (push (concat pad "healthcheck:\n"
                    (ebasecamp-compose--healthcheck-body healthcheck nested))
            lines))
    (when rest-extra
      (push (ebasecamp-compose--yaml-map rest-extra 4) lines))
    (mapconcat #'identity (nreverse lines) "\n")))

;;; 段组装

(defun ebasecamp-compose--services-section (services)
  "把已渲染的服务列表 SERVICES 组装为 services 段文本。
SERVICES 元素为 (NAME . BODY)；为空时输出 `services: {}'。"
  (if (null services)
      "services: {}"
    (concat "services:\n"
            (mapconcat (lambda (entry)
                         (concat "  "
                                 (ebasecamp-compose--yaml-key (car entry))
                                 ":\n"
                                 (cdr entry)))
                       services
                       "\n"))))

(defun ebasecamp-compose--networks-section (shared-network user-networks)
  "返回顶层 networks 段文本。
SHARED-NETWORK 非 nil 时把 `ebasecamp' 声明为 external network；
USER-NETWORKS 为服务引用的其余网络名，按空映射声明（由 compose 按项目创建）。"
  (concat "networks:\n"
          (mapconcat
           #'identity
           (append
            (when shared-network
              (list (concat "  ebasecamp:\n"
                            "    external: true\n"
                            "    name: ebasecamp")))
            (mapcar (lambda (name)
                      (concat "  " (ebasecamp-compose--yaml-key name) ": {}"))
                    user-networks))
           "\n")))

(defun ebasecamp-compose--volumes-section (volumes)
  "把命名卷列表 VOLUMES 组装为顶层 volumes 段文本（值为空映射）。"
  (concat "volumes:\n"
          (mapconcat (lambda (name)
                       (concat "  " (ebasecamp-compose--yaml-key name) ": {}"))
                     volumes
                     "\n")))

(defun ebasecamp-compose--file-declarations-section (title alist)
  "把项目顶层 ALIST 渲染为 TITLE 段（`configs' / `secrets'）。
ALIST 为 compose 原样结构（字符串键 alist，可嵌套），nil 时返回 nil。
键必须是字符串（模型层已校验）：`--yaml-map' 的 `--mapping-p' 只认字符串键，
符号键会被当序列渲染成错误 YAML。"
  (when alist
    (concat title ":\n" (ebasecamp-compose--yaml-map alist 2))))

;;; 公共接口

(defun ebasecamp-compose-project-name (project group)
  "返回 PROJECT 中组 GROUP 对应的 compose 项目名。
组 scope 为 shared 时固定为 \"ebc-shared\"，否则为 \"ebc-<project>\"。
GROUP 可以是项目 groups 字段中的引用 plist、ebasecamp-group 对象或组名
symbol。项目名或组名不匹配 [a-z0-9_-]+ 时报 ebasecamp-compose-error。"
  (ebasecamp-compose--check-project project)
  (ebasecamp-compose--compose-name project (list group)))

(defun ebasecamp-compose-render (project &optional group-filter)
  "把 PROJECT 渲染为 compose YAML 文本并返回。
GROUP-FILTER 为 nil 时渲染项目引用的全部组；为 symbol、字符串或它们的列表
时只渲染指定组（用于 shared 组单独生成）。返回文本以单个换行结尾。

GROUP-FILTER 非 nil（按 scope 渲染）时，服务 depends-on 中指向**本次未渲染
服务**的名字被剔除 —— 这些依赖属于另一个 compose 项目（shared 组在
`ebc-shared'、per-project 组在 `ebc-<project>'），保留会让 `docker compose up'
报 depends on undefined service。GROUP-FILTER 为 nil（预览/导出）时行为不变。

顶层 `configs:' / `secrets:' 段取自项目的 `:file-configs' / `:file-secrets'，
只在 per-project 生成物里输出（refs 全为 shared 时省略）。"
  (ebasecamp-compose--check-project project)
  (let* ((refs (ebasecamp-compose--group-refs project group-filter))
         (name (ebasecamp-compose--compose-name project refs))
         (shared-network (ebasecamp-project-shared-network project))
         (pairs nil)
         (services nil)
         (networks nil)
         (volumes nil)
         (allowed nil))
    ;; 第一遍：收集本次渲染的服务（同名只保留首个，与第二遍去重规则一致），
    ;; filter 模式下同时得到 depends-on 白名单。
    (dolist (ref refs)
      (dolist (service (ebasecamp-model-resolve-services project ref))
        (unless (cl-find (ebasecamp-service-name service) pairs
                         :key (lambda (pair) (ebasecamp-service-name (cdr pair)))
                         :test #'eq)
          (setq pairs (cons (cons ref service) pairs)))))
    (setq pairs (nreverse pairs))
    (when group-filter
      (dolist (pair pairs)
        (let ((service-name
               (symbol-name (ebasecamp-service-name (cdr pair)))))
          (unless (member service-name allowed)
            (setq allowed (append allowed (list service-name)))))))
    ;; 第二遍：渲染服务体
    (dolist (pair pairs)
      (let* ((ref (car pair))
             (service (cdr pair))
             (group-name (ebasecamp-compose--ref-group-name ref))
             (scope (ebasecamp-compose--ref-scope ref))
             (context (list :project (ebasecamp-project-name project)
                            :group group-name
                            :scope scope
                            :shared-network shared-network))
             (entries (ebasecamp-compose--volume-entries
                       service scope group-name))
             (body (ebasecamp-compose--service-body
                    service context entries allowed))
             (service-networks (ebasecamp-compose--service-networks
                                service context)))
        (dolist (entry entries)
          (when (and (car entry) (not (member (car entry) volumes)))
            (setq volumes (append volumes (list (car entry))))))
        (dolist (network service-networks)
          (when (and (not (equal network "ebasecamp"))
                     (not (member network networks)))
            (setq networks (append networks (list network)))))
        (setq services
              (append services
                      (list (cons (ebasecamp-service-name service) body))))))
    (let ((sections (list (concat "name: " name)
                          (ebasecamp-compose--services-section services))))
      (when (or shared-network networks)
        (setq sections (append sections
                               (list (ebasecamp-compose--networks-section
                                      shared-network networks)))))
      (when volumes
        (setq sections (append sections
                               (list (ebasecamp-compose--volumes-section
                                      volumes)))))
      ;; 顶层 configs / secrets 只进 per-project 生成物：shared 生成物
      ;; （`ebc-shared'）由部署环境自行提供这些对象，塞进去会让同一份声明
      ;; 出现在两个 compose 项目里（记入 tech-debt）。
      (unless (ebasecamp-compose--all-shared-p refs)
        (dolist (section
                 (list (ebasecamp-compose--file-declarations-section
                        "configs" (ebasecamp-project-file-configs project))
                       (ebasecamp-compose--file-declarations-section
                        "secrets" (ebasecamp-project-file-secrets project))))
          (when section
            (setq sections (append sections (list section))))))
      (concat (mapconcat #'identity sections "\n") "\n"))))

(defun ebasecamp-compose-cache-file (project &optional group-filter)
  "返回 PROJECT 的 compose 生成物绝对路径（不写盘）。
路径形如 <ebasecamp-cache-directory>/<project>/compose.yaml；shared 组单独
渲染时目录为 `_shared'。GROUP-FILTER 语义同 `ebasecamp-compose-render'。"
  (ebasecamp-compose--check-project project)
  (let* ((refs (ebasecamp-compose--group-refs project group-filter))
         (sub (if (ebasecamp-compose--all-shared-p refs)
                  "_shared"
                (ebasecamp-compose--name-string
                 (ebasecamp-project-name project) "项目名"))))
    (expand-file-name
     (concat sub "/compose.yaml")
     (file-name-as-directory (expand-file-name ebasecamp-cache-directory)))))

(defun ebasecamp-compose-write (project &optional group-filter)
  "把 PROJECT 渲染为 compose YAML 并写入缓存目录，返回生成文件绝对路径。
目标目录不存在时递归创建；GROUP-FILTER 语义同 `ebasecamp-compose-render'。"
  (let ((path (ebasecamp-compose-cache-file project group-filter))
        (text (ebasecamp-compose-render project group-filter))
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert text))
    path))

(provide 'ebasecamp-compose)
;;; ebasecamp-compose.el ends here
