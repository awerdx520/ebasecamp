;;; ebasecamp-import.el --- ebasecamp 导入映射（compose → 清单） -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.4.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 把项目 compose 文件读成 `ebasecamp-model' 的项目结构，并把它落盘成清单。
;;
;; 两个阶段：
;; - **纯映射**（`ebasecamp-import-parse' 等）：compose → `ebasecamp-project'
;;   结构，不落盘、不改清单、不创建注册项；
;; - **落盘**（`ebasecamp-import-apply'）：把该结构物化为一份
;;   `ebasecamp-define-group'（服务定义）+ 一份 `ebasecamp-define-project'
;;   （项目定义）的 Elisp 清单文件 `<dir>/projects/<name>.el'，写盘后自校验
;;   可解析与可加载，失败即回滚。
;;
;; 落盘时「组名 = 项目名」：模型没有「项目内联服务」的概念，服务必须挂在组
;; 上；组名与项目同名既保证项目内组引用唯一，也让不同项目的同名服务不会在
;; 注册表里冲突（每个项目文件各自带一个同名组）。
;;
;; 落盘格式（v0.2「组内配置」写法）：服务定义写在 `ebasecamp-define-group' 的
;; `:services'，项目归属写在同一个组的 `:configs'（配置名 = 项目名、
;; `:project' 同值、覆盖留空）；`ebasecamp-define-project' 只写 `:title' 与
;; `:root'，**不写** `:groups' —— 项目侧的组引用由加载期的
;; `ebasecamp-model-link-configs' 从 `:configs' 物化而来，两处都写会构成
;; 「同项目同组双引用」而被加载层报错。
;;
;; 读取命令固定为
;;
;;   docker compose -f <file> config --no-interpolate --no-env-resolution \
;;     --no-path-resolution --format json
;;
;; 三个 flag 缺一不可（见 AGENTS.md 不变量 5）：缺 `--no-interpolate' 会让
;; `${SECRET}' 被展开成明文或静默空串（退出码仍为 0），缺 `--no-env-resolution'
;; 会把 env_file 内容合并进输出，缺 `--no-path-resolution' 会把相对路径绝对化。
;;
;; 映射要点：
;; - 顶层 `name' 只用于推断项目名（`ebasecamp-import-suggest-name'），不写入项目；
;; - `labels' 剔除 `ebasecamp.*' 与 `com.docker.compose.*' 前缀键；
;; - `ports' 只保留「tcp + 有 published + 未绑定特定宿主 IP」的条目，映射为
;;   (PUBLISHED . TARGET) 整数对；无法用当前 model 表达的端口原样进 `:extra'
;;   的 "ports" 桶（含 udp 等非 tcp 协议、缺 published、绑定到具体宿主 IP）；
;; - `env_file' 归一为**相对路径字符串列表**（`(\"./db.env\")'）进 `:extra' 的
;;   "env_file" 桶；对象形态只取 `path'（`required' / `format' 暂丢弃，见
;;   openspec/tech-debt.md），路径保持相对（依赖 `--no-path-resolution'）。
;;   不用 volumes 语义的 (:source PATH :type env)：`env_file' 只接受字符串或
;;   字符串列表，且「单元素 plist 列表」会被渲染层的 mapping 判据误判，
;;   导出产出 compose 无法解析的 YAML（D3 实测缺陷，D4 修复）；
;; - 其余未识别字段原样进 `:extra'（键为字符串），供导出时回写。
;;
;; JSON 解析：用 `json-parse-string' 的 `:object-type hash-table'。默认的 alist
;; 模式会把合法标识符形式的键（`image'、`working_dir' 等）转成 **symbol**，需要
;; 再统一转回字符串；而 hash-table 模式的键天然是字符串，且 hash-table 与数组
;; （`:array-type list'）类型上无歧义 —— 不存在「alist 还是对象数组」的判别问题
;; （`ebasecamp-docker.el' 的 `--stringify-json-keys' 只处理单层对象，嵌套在数组
;; 里的对象无法用同一手法无歧义归一）。因此本模块在解析入口直接把 hash-table
;; 递归转成「字符串键 alist + 列表」，下游一律按字符串键取值。
;;
;; 服务定义暂存位置：模型没有「项目内联服务」的概念，项目的 groups 是组引用。
;; 导入结果把全部服务按 `((SERVICE-SYMBOL . PLIST) ...)' 放进组引用 `app' 的
;; `:service-overrides'（该结构与 `ebasecamp-model--group-ref-from-spec' 归一化
;; 后的形态一致），T4.2 落盘时再物化成 `ebasecamp-define-group' 的服务定义。
;;
;; 安全约定：本模块不读取、不打印、不落盘任何密钥值；environment 中的 `${VAR}'
;; 引用原样保留。

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'ebasecamp-model)
(require 'ebasecamp-config)
(require 'ebasecamp-docker)

(define-error 'ebasecamp-import-error "ebasecamp 导入失败")

(defconst ebasecamp-import--name-regexp "\\`[a-z0-9_-]+\\'"
  "项目名与组名的合法形式（转小写后匹配）。")

(defconst ebasecamp-import--config-arguments
  '("config" "--no-interpolate" "--no-env-resolution" "--no-path-resolution"
    "--format" "json")
  "读取项目 compose 的固定参数（`config' 之后的部分）。
三个 `--no-*' 是安全与保真硬约束，缺一即违反 AGENTS.md 不变量 5。")

(defconst ebasecamp-import--label-prefixes
  '("ebasecamp." "com.docker.compose.")
  "导入时剔除的标签前缀：前者是插件自己注入的托管标签，后者由 compose 生成。")

(defconst ebasecamp-import--recognized-service-keys
  '("image" "command" "entrypoint" "environment" "labels" "ports" "volumes"
    "networks" "healthcheck" "depends_on" "working_dir" "user" "restart"
    "env_file")
  "已在映射规则中显式处理的 compose 服务字段。
其余字段一律原样进 `:extra'。")

(defconst ebasecamp-import--healthcheck-keys
  '(("test" . :test)
    ("interval" . :interval)
    ("timeout" . :timeout)
    ("retries" . :retries)
    ("start_period" . :start-period))
  "healthcheck 子字段到清单 plist 关键字（compose JSON 用下划线命名）。")

(defconst ebasecamp-import--wildcard-host-ips
  '("0.0.0.0" "::" "[::]" "")
  "等价于「绑定全部接口」的 host_ip 取值。
出于其它取值的端口绑定到具体宿主 IP，当前 model 无法表达。")

;;; JSON → 字符串键 alist

(defun ebasecamp-import--json->sexp (value)
  "把 `json-parse-string' 的结果 VALUE 递归转成字符串键 alist + 列表。
对象（hash-table）按键名 `string<' 排序，数组（列表）保持原序，标量原样返回。"
  (cond
   ((hash-table-p value)
    (mapcar (lambda (key)
              (cons key (ebasecamp-import--json->sexp (gethash key value))))
            (sort (hash-table-keys value) #'string<)))
   ((vectorp value)
    (mapcar #'ebasecamp-import--json->sexp (append value nil)))
   ((consp value)
    (mapcar #'ebasecamp-import--json->sexp value))
   (t value)))

(defun ebasecamp-import--parse-json-object (json)
  "把 JSON 字符串 JSON 解析为字符串键 alist。
解析失败 signal `ebasecamp-import-error'。`null' 解析为 nil，`false' 解析为
符号 `:false'（与 `true' 的 t 区分）。"
  (condition-case err
      (ebasecamp-import--json->sexp
       (json-parse-string json
                          :object-type 'hash-table
                          :array-type 'list
                          :null-object nil))
    (error
     (signal 'ebasecamp-import-error
             (list (format "compose 配置不是合法 JSON：%s"
                           (error-message-string err)))))))

;;; 取值助手

(defun ebasecamp-import--field (object key)
  "从字符串键 alist OBJECT 取 KEY 的值；缺失或 OBJECT 不是 alist 时返回 nil。"
  (cdr (assoc key object)))

(defun ebasecamp-import--string-field (object key)
  "从 OBJECT 取 KEY 的字符串值；缺失或非字符串时返回 nil。"
  (let ((value (ebasecamp-import--field object key)))
    (and (stringp value) value)))

(defun ebasecamp-import--scalar-string (value)
  "把 JSON 标量 VALUE 归一为字符串。
null → 空串（compose 里 `- KEY' 这种只声明键名的写法导出后即为 null），
短横线 `:false' → \"false\"，数字 → 十进制文本。"
  (cond
   ((stringp value) value)
   ((null value) "")
   ((numberp value) (number-to-string value))
   ((eq value :false) "false")
   ((eq value t) "true")
   (t (format "%s" value))))

(defun ebasecamp-import--string-list (value)
  "把 JSON 数组 VALUE 归一为字符串列表。
字符串（shell 形式的 command/entrypoint）原样返回，以保留 shell 语义；
null 返回 nil。"
  (cond
   ((null value) nil)
   ((stringp value) value)
   ((listp value) (mapcar #'ebasecamp-import--scalar-string value))
   (t nil)))

(defun ebasecamp-import--name-candidate (string)
  "STRING 是合法项目名时返回其小写 symbol，否则返回 nil。"
  (let ((candidate (and (stringp string) (downcase string))))
    (when (and candidate (string-match-p ebasecamp-import--name-regexp candidate))
      (intern candidate))))

;;; 字段映射

(defun ebasecamp-import--environment (value)
  "把 compose 的 environment VALUE 映射为字符串 alist。
map 形态（compose 归一化后的常态）→ ((KEY . VALUE) ...)；
数组形态（`KEY=VALUE'）按第一个 `=' 兜底切分。`${VAR}' 原样保留。"
  (cond
   ((null value) nil)
   ((and (listp value) (cl-every #'stringp value))
    (mapcar (lambda (entry)
              (let ((equals (string-match "=" entry)))
                (if equals
                    (cons (substring entry 0 equals)
                          (substring entry (1+ equals)))
                  (cons entry ""))))
            value))
   ((listp value)
    (mapcar (lambda (pair)
              (cons (ebasecamp-import--scalar-string (car pair))
                    (ebasecamp-import--scalar-string (cdr pair))))
            value))
   (t nil)))

(defun ebasecamp-import--labels (value)
  "把 compose 的 labels VALUE 映射为字符串 alist，剔除插件与 compose 注入的键。"
  (cl-remove-if
   (lambda (pair)
     (cl-some (lambda (prefix)
                (string-prefix-p prefix (car pair)))
              ebasecamp-import--label-prefixes))
   (mapcar (lambda (pair)
             (cons (ebasecamp-import--scalar-string (car pair))
                   (ebasecamp-import--scalar-string (cdr pair))))
           (if (and (listp value) (cl-every #'stringp value))
               ;; `- k=v' 的数组写法（compose 通常会归一化，这里兜底）
               (ebasecamp-import--environment value)
             value))))

(defun ebasecamp-import--published-port (value)
  "从 published VALUE 取端口号（整数），取不到时返回 nil。
支持整数、\"8080\"、含 IP 的 \"127.0.0.1:9090\"（取最后一个 `:' 之后的端口段）。"
  (cond
   ((integerp value) value)
   ((numberp value) (truncate value))
   ((stringp value)
    (let ((last (car (last (split-string value ":" t)))))
      (when (and last (string-match "\\`\\([0-9]+\\)" last))
        (string-to-number (match-string 1 last)))))
   (t nil)))

(defun ebasecamp-import--ports (value)
  "把 compose 的 ports VALUE 映射为 (PORTS . EXTRAS) 两半。
PORTS 为 (PUBLISHED . TARGET) 整数对列表；EXTRAS 为无法用当前 model 表达的
原始端口对象列表（缺 published / target、非 tcp 协议、绑定具体宿主 IP）。"
  (let ((ports nil)
        (extras nil))
    (dolist (object value)
      (let ((target (ebasecamp-import--field object "target"))
            (published (ebasecamp-import--published-port
                        (ebasecamp-import--field object "published")))
            (protocol (ebasecamp-import--string-field object "protocol"))
            (host-ip (ebasecamp-import--string-field object "host_ip")))
        (if (and (consp object)
                 (integerp target)
                 published
                 (or (null protocol) (equal protocol "tcp"))
                 (or (null host-ip)
                     (member host-ip ebasecamp-import--wildcard-host-ips)))
            (push (cons published target) ports)
          (push object extras))))
    (cons (nreverse ports) (nreverse extras))))

(defun ebasecamp-import--volumes (value)
  "把 compose 的 volumes VALUE 映射为 (VOLUMES . EXTRAS) 两半。
VOLUMES 元素为 plist (:source S :target T :type bind|volume [:read-only t])；
tmpfs 等其它类型进 EXTRAS 原始对象列表。"
  (let ((volumes nil)
        (extras nil))
    (dolist (object value)
      (let ((type (ebasecamp-import--string-field object "type"))
            (source (ebasecamp-import--string-field object "source"))
            (target (ebasecamp-import--string-field object "target"))
            (read-only (ebasecamp-import--field object "read_only")))
        (cond
         ((and source target (member type '("bind" "volume")))
          (push (append (list :source source
                              :target target
                              :type (if (equal type "bind") 'bind 'volume))
                        (when (eq read-only t) (list :read-only t)))
                volumes))
         (t (push object extras)))))
    (cons (nreverse volumes) (nreverse extras))))

(defun ebasecamp-import--networks (value)
  "把 compose 的 networks VALUE（map 或数组）映射为网络名列表，剔除 default。"
  (let ((names (cond
                ((null value) nil)
                ((and (listp value) (cl-every #'stringp value)) value)
                ((listp value)
                 (mapcar (lambda (item)
                           (if (consp item) (car item) item))
                         value)))))
    (cl-remove "default" names :test #'equal)))

(defun ebasecamp-import--depends-on (value)
  "把 compose 的 depends_on VALUE 归一为服务名列表。
对象形态（带 condition，compose 5.x 的常态）取键名；数组形态取元素。"
  (cond
   ((null value) nil)
   ((and (listp value) (cl-every #'stringp value)) value)
   ((listp value)
    (mapcar (lambda (item) (if (consp item) (car item) (format "%s" item)))
            value))
   (t nil)))

(defun ebasecamp-import--healthcheck (value)
  "把 compose 的 healthcheck VALUE 映射为 plist；缺失或空对象时返回 nil。"
  (when (listp value)
    (let ((plist nil))
      (dolist (pair ebasecamp-import--healthcheck-keys)
        (let ((field (ebasecamp-import--field value (car pair))))
          (when field
            (setq plist (append plist (list (cdr pair) field))))))
      plist)))

(defun ebasecamp-import--env-file (value)
  "把 compose 的 env_file VALUE 归一为相对路径字符串列表。
只保留路径引用，不读取文件内容；路径保持 compose 中的相对形式。
compose 的 env_file 合法形态为字符串 / 字符串列表 / {path, required, …} 对象：
字符串原样保留，对象只取 `path' 字段，无 path 的项丢弃（顺序保持不变）。
不用 volumes 语义的 (:source PATH :type env)：`env_file' 不接受该形态，而
「单元素 plist 列表」还会被渲染层 `ebasecamp-compose--mapping-p' 误判为映射，
导出产出 compose 无法解析的 YAML（D3 实测缺陷）。字符串列表则渲染为合法序列
（`- ./db.env'，纯路径不触发引号）。"
  (delq nil
        (mapcar (lambda (item)
                  (cond
                   ((stringp item) item)
                   ((consp item) (ebasecamp-import--string-field item "path"))))
                (cond
                 ((stringp value) (list value))
                 ((listp value) value)
                 (t nil)))))

(defun ebasecamp-import--extra (object ports-extras volumes-extras env-file)
  "组装服务的 `:extra' alist：未识别字段 + 无法表达的 ports / volumes / env_file。"
  (let ((extra nil))
    (dolist (pair object)
      (unless (member (car pair) ebasecamp-import--recognized-service-keys)
        (push (cons (car pair) (cdr pair)) extra)))
    (when ports-extras
      (push (cons "ports" ports-extras) extra))
    (when volumes-extras
      (push (cons "volumes" volumes-extras) extra))
    (when env-file
      (push (cons "env_file" env-file) extra))
    (nreverse extra)))

(defun ebasecamp-import--service-plist (object)
  "把单个 compose 服务对象 OBJECT 映射为服务属性 plist（未校验）。"
  (let* ((ports (ebasecamp-import--ports (ebasecamp-import--field object "ports")))
         (volumes (ebasecamp-import--volumes
                   (ebasecamp-import--field object "volumes")))
         (env-file (ebasecamp-import--env-file
                    (ebasecamp-import--field object "env_file"))))
    (list :image (ebasecamp-import--string-field object "image")
          :command (ebasecamp-import--string-list
                    (ebasecamp-import--field object "command"))
          :entrypoint (ebasecamp-import--string-list
                       (ebasecamp-import--field object "entrypoint"))
          :environment (ebasecamp-import--environment
                        (ebasecamp-import--field object "environment"))
          :labels (ebasecamp-import--labels
                   (ebasecamp-import--field object "labels"))
          :ports (car ports)
          :volumes (car volumes)
          :healthcheck (ebasecamp-import--healthcheck
                        (ebasecamp-import--field object "healthcheck"))
          :depends-on (ebasecamp-import--depends-on
                       (ebasecamp-import--field object "depends_on"))
          :networks (ebasecamp-import--networks
                     (ebasecamp-import--field object "networks"))
          :working-dir (ebasecamp-import--string-field object "working_dir")
          :user (ebasecamp-import--string-field object "user")
          :restart (ebasecamp-import--string-field object "restart")
          :extra (ebasecamp-import--extra
                  object (cdr ports) (cdr volumes) env-file))))

(defun ebasecamp-import--checked-service-plist (name object)
  "映射服务 NAME 的 OBJECT 并用 `ebasecamp-model' 的校验入口验证。
校验失败时把 `ebasecamp-model-error' 转成 `ebasecamp-import-error'，避免
把模型内部错误类型泄漏到调用方。"
  (let ((plist (ebasecamp-import--service-plist object)))
    (condition-case err
        (progn
          ;; 仅借模型层做字段校验（:image 必填、ports 为整数对、volumes 的
          ;; :type 取值等），映射结果仍以 plist 形式返回供落盘使用
          (ebasecamp-model--service-from-spec name plist "导入")
          plist)
      (ebasecamp-model-error
       (signal 'ebasecamp-import-error
               (list (format "服务 %s 无法映射到清单：%s"
                             name (error-message-string err))))))))

;;; 项目名推断

(defun ebasecamp-import--name-from-file (file)
  "由 FILE 的父目录名 → 文件名（去扩展名）推断项目名 symbol，都非法则 imported。"
  (or (ebasecamp-import--name-candidate
       (file-name-nondirectory
        (directory-file-name
         (file-name-directory (expand-file-name file)))))
      (ebasecamp-import--name-candidate (file-name-base (expand-file-name file)))
      'imported))

(defun ebasecamp-import--config-json (file)
  "执行 compose config 读取 FILE，返回 stdout；失败或非零退出时返回 nil。
本函数为「尽力而为」用途（只用于推断项目名），不 signal。"
  (condition-case nil
      (let* ((result (ebasecamp-docker-run-sync
                      (append (list "compose" "-f" (expand-file-name file))
                              ebasecamp-import--config-arguments)))
             (exit (plist-get result :exit)))
        (and (numberp exit) (zerop exit) (plist-get result :stdout)))
    (error nil)))

(defun ebasecamp-import--declared-name (json)
  "从 JSON 字符串取出顶层 `name'；解析失败或缺失时返回 nil。"
  (condition-case nil
      (ebasecamp-import--string-field
       (ebasecamp-import--parse-json-object json) "name")
    (error nil)))

;;; 公开入口

(defun ebasecamp-import-suggest-name (file &optional json)
  "推断 compose 文件 FILE 的建议项目名（symbol）。
顺序：JSON 顶层 `name'（合法则转小写采用）→ FILE 父目录名 → FILE 文件名（去
扩展名）→ `imported'。JSON 为可选的已读取 JSON 字符串（缺省时自行执行
`docker compose config' 读取，失败按「无 name」处理），供纯函数测试注入。"
  (let ((json (or json (ebasecamp-import--config-json file))))
    (or (ebasecamp-import--name-candidate
         (and json (ebasecamp-import--declared-name json)))
        (ebasecamp-import--name-from-file file))))

(defun ebasecamp-import-parse-json (json &optional file)
  "把 compose config 的 JSON 字符串映射为 `ebasecamp-project' 结构（纯函数）。
FILE 可选，仅用于项目名回退（缺省时回退为 `imported'）。
映射规则见本文件 Commentary 与计划「导入映射规则」节。
JSON 非法、缺 services、服务字段无法映射时 signal `ebasecamp-import-error'。"
  (let* ((object (ebasecamp-import--parse-json-object json))
         (services (and (listp object) (ebasecamp-import--field object "services"))))
    (unless (and (listp services) services)
      (signal 'ebasecamp-import-error
              (list "compose 配置中没有可导入的 services 定义")))
    (let* ((service-plists
            (mapcar (lambda (pair)
                      (cons (intern (car pair))
                            (ebasecamp-import--checked-service-plist
                             (intern (car pair)) (cdr pair))))
                    services))
           (name (or (ebasecamp-import--name-candidate
                      (ebasecamp-import--string-field object "name"))
                     (if file
                         (ebasecamp-import--name-from-file file)
                       'imported))))
      (ebasecamp-project-create
       :name name
       :title (symbol-name name)
       :root nil
       ;; 模型没有「项目内联服务」：服务定义暂存到组引用 app 的
       ;; :service-overrides，T4.2 落盘时物化为 ebasecamp-define-group
       :groups (list (list :group 'app
                           :scope 'per-project
                           :service-overrides service-plists))
       :shared-network t
       :export-file nil))))

(defun ebasecamp-import-parse (file)
  "读取 compose 文件 FILE 并映射为 `ebasecamp-project' 结构。
执行
  docker compose -f FILE config --no-interpolate --no-env-resolution \\
    --no-path-resolution --format json
非零退出或缺命令时 signal `ebasecamp-import-error'（携带 stderr 首行）。"
  (let* ((path (expand-file-name file))
         (result (condition-case err
                     (ebasecamp-docker-run-sync
                      (append (list "compose" "-f" path)
                              ebasecamp-import--config-arguments))
                   (ebasecamp-docker-error
                    (signal 'ebasecamp-import-error
                            (list (format "无法执行 docker compose 读取 %s：%s"
                                          path (error-message-string err)))))))
         (exit (plist-get result :exit))
         (stderr (or (plist-get result :stderr) "")))
    (unless (and (numberp exit) (zerop exit))
      (signal 'ebasecamp-import-error
              (list (format "读取 %s 失败（docker compose config 退出码 %s）：%s"
                            path exit
                            (or (car (split-string stderr "\n" t)) "无输出")))))
    (ebasecamp-import-parse-json (or (plist-get result :stdout) "") path)))

;;; 结果访问

(defun ebasecamp-import-service-plists (project)
  "返回 PROJECT 里导入的服务 alist：((SERVICE-SYMBOL . PLIST) ...)。
返回的是副本，调用方修改不会影响 PROJECT。"
  (let ((ref (car (ebasecamp-project-groups project))))
    (copy-tree (plist-get ref :service-overrides))))

(defun ebasecamp-import-service-plist (project name)
  "返回 PROJECT 中名为 NAME（symbol 或字符串）的服务属性 plist；不存在时 nil。"
  (cdr (assq (if (stringp name) (intern name) name)
             (ebasecamp-import-service-plists project))))

;;; 清单落盘

(defconst ebasecamp-import--service-output-keys
  '(:image :command :entrypoint :environment :labels :ports :volumes
    :depends-on :networks :healthcheck :working-dir :user :restart :extra)
  "落盘时服务字段的固定输出顺序。
契约示例 image → command → environment → ports → volumes → depends-on →
networks → healthcheck → restart → extra 的相对顺序在此保持不变；契约示例未
列出的 entrypoint / labels / working-dir / user 插在语义相邻处。")

(defconst ebasecamp-import--manifest-form-count 2
  "导入生成的清单文件应含的顶层 form 数：一个组定义 + 一个项目定义。")

(defun ebasecamp-import--literal (value)
  "把 VALUE 写成 Elisp 字面量字符串。
`prin1-to-string' 只转义引号、反斜杠与控制字符，`${VAR}' 引用因此原样保留；
绑定 `print-escape-newlines' 为 t，避免多行字符串破坏文件版式。"
  (let ((print-length nil)
        (print-level nil)
        (print-escape-newlines t))
    (prin1-to-string value)))

(defun ebasecamp-import--normalize-name (name)
  "把 NAME（symbol 或字符串）校验为合法项目名并返回 symbol。
不匹配 `[a-z0-9_-]+' 时 signal `ebasecamp-import-error'（大写、空格、空串、
含点或含斜杠都不合法）。校验针对 NAME 的**原始形式**，不做小写容错。"
  (let ((text (and name
                   (cond ((stringp name) name)
                         ((symbolp name) (symbol-name name)))))
        ;; 必须关掉大小写折叠：默认的 case-fold-search 为 t 会让 "Upper"
        ;; 匹配 [a-z...]
        (case-fold-search nil))
    (unless (and text (string-match-p ebasecamp-import--name-regexp text))
      (signal 'ebasecamp-import-error
              (list (format
                     "项目名 %S 非法：只允许小写字母、数字、下划线与连字符（%s）"
                     name ebasecamp-import--name-regexp))))
    (intern (downcase text))))

(defun ebasecamp-import--service-form (name plist)
  "把服务 NAME（symbol）与属性 PLIST 渲染为完整的 `(NAME :KEY VALUE ...)'。
首行不含缩进，续行缩进 4 空格；nil 值的键与空的 `:extra' 一律省略。"
  (let ((lines nil))
    (dolist (key ebasecamp-import--service-output-keys)
      (let ((value (plist-get plist key)))
        (when value
          (push (format "    %s %s" key (ebasecamp-import--literal value))
                lines))))
    (if lines
        (concat "(" (symbol-name name) "\n"
                (mapconcat #'identity (nreverse lines) "\n")
                ")")
      (concat "(" (symbol-name name) ")"))))

(defun ebasecamp-import--group-form (name services)
  "渲染 `ebasecamp-define-group' 形式的多行字符串。
NAME 为组名 symbol（同时是项目名），SERVICES 为 ((SERVICE . PLIST) ...)
alist。服务定义写在组的 `:services'，项目归属写在组内 `:configs'：
配置名取项目名、`:project' 同值，覆盖留空（服务定义已在组侧，无需重复）。
加载期由 `ebasecamp-model-link-configs' 把它物化成项目的组引用。"
  (let ((blocks (mapcar (lambda (pair)
                          (ebasecamp-import--service-form
                           (car pair) (cdr pair)))
                        services))
        (group (symbol-name name)))
    (concat
     "(ebasecamp-define-group " group "\n"
     "  :title " (ebasecamp-import--literal group) "\n"
     "  :scope per-project\n"
     (if blocks
         (concat "  :services\n  ("
                 (mapconcat #'identity blocks "\n   ")
                 ")\n")
       "  :services nil\n")
     ;; 配置名 = 项目名：物化后的组引用可追溯到导入来源，也满足
     ;; 「同项目同组至多 1 个引用」的校验
     "  :configs ((" group " :project " group ")))\n")))

(defun ebasecamp-import--project-form (name root)
  "渲染 `ebasecamp-define-project' 形式的多行字符串。
NAME 为项目名 symbol，ROOT 为项目根目录字符串。
不写 `:groups'：项目对组的引用由组内 `:configs' 在加载期物化而来，两处都写
会构成「同项目同组双引用」而报加载错误。"
  (concat
   "(ebasecamp-define-project " (symbol-name name) "\n"
   "  :title " (ebasecamp-import--literal (symbol-name name)) "\n"
   "  :root " (ebasecamp-import--literal root) ")\n"))

(defun ebasecamp-import--manifest-content (name source root services)
  "生成清单文件全文。
NAME 为项目名 symbol（同时是组名），SOURCE 为 compose 文件绝对路径，ROOT 为
项目根目录，SERVICES 为导入的服务 alist。文件以单个换行结尾。
版式对齐 `ebasecamp-create-sample-config' 的模板：首行文件局部变量、第二行
文件说明、空行后两行注释交代来源与安全约定。"
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; " (symbol-name name) ".el --- ebasecamp 清单（由 compose 导入）\n"
   "\n"
   ";; 由 M-x ebasecamp-import-file 从 " source " 导入。\n"
   ";; 安全约定：只保存 ${VAR} 引用，不保存密钥明文。\n"
   "\n"
   (ebasecamp-import--group-form name services)
   "\n"
   (ebasecamp-import--project-form name root)))

(defun ebasecamp-import--read-forms (file)
  "读出 FILE 的全部顶层 form 并返回列表。
读取未完成（括号不平衡、语法错）时 signal `ebasecamp-import-error'；文件尾部
只有注释或空白时视为正常结束（完整性由调用方用 form 数量判断）。
注释必须用 `forward-comment' 显式跳过：临时 buffer 里的 `read' 不认 `;' 注释，
会把整段注释当符号一路吃到文件末尾。"
  (with-temp-buffer
    (insert-file-contents file)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (goto-char (point-min))
    (let ((forms nil))
      (condition-case err
          (progn
            (forward-comment (point-max))
            (while (not (eobp))
              (push (read (current-buffer)) forms)
              (forward-comment (point-max))))
        (error
         (signal 'ebasecamp-import-error
                 (list (format "生成的清单无法解析：%s"
                               (error-message-string err))))))
      (nreverse forms))))

(defun ebasecamp-import--restore-file (file backup)
  "把 FILE 恢复到 BACKUP 的内容；BACKUP 为 nil 时删除 FILE。"
  (if backup
      (with-temp-file file (insert backup))
    (when (file-exists-p file)
      (delete-file file))))

(cl-defun ebasecamp-import-apply (file name &key force directory root)
  "把 compose 文件 FILE 导入为清单文件，返回清单文件的绝对路径。

NAME 为项目名（string 或 symbol），须匹配 `[a-z0-9_-]+'，否则 signal
`ebasecamp-import-error'。该名字同时用作**组名**：模型没有「项目内联服务」
概念，服务必须挂在组上，组名与项目同名可保证项目内组引用唯一、不同项目之间
互不冲突。

生成文件为 `ebasecamp-config-project-file' 指向的路径
\\(<DIRECTORY>/projects/<name>.el'，DIRECTORY 省略时用
`ebasecamp-config-directory'），内容为一份 `ebasecamp-define-group'（`:services'
放服务定义、`:configs' 放项目归属）加一份 `ebasecamp-define-project'
（`:title' 与 `:root'，不写 `:groups'），带来源文件注释头。

FORCE 为 nil 且目标已存在时 signal `ebasecamp-import-error'（不动原文件）；
非 nil 时覆盖。ROOT 为项目根目录字符串，省略时用 FILE 所在目录（去掉尾部
斜杠）。

写盘后自校验：先读回全部顶层 form 确认可解析且数量为
`ebasecamp-import--manifest-form-count'；再用 `ebasecamp-config-load' 确认
\(1) 零错误、(2) 新项目已注册、(3) 组内 `:configs' 已物化出带
`:service-overrides' 键的组引用。任一步失败都回滚（原来有文件则恢复原内容，
否则删除新文件）并 signal。清单只保存 `${VAR}' 引用与相对路径，不读写任何
密钥值。"
  (let* ((project-name (ebasecamp-import--normalize-name name))
         (target (ebasecamp-config-project-file
                  project-name
                  (ebasecamp-config-ensure-directory directory)))
         (source (expand-file-name file))
         (backup (when (file-exists-p target)
                   (with-temp-buffer
                     (insert-file-contents target)
                     (buffer-string)))))
    (when (and backup (not force))
      (signal 'ebasecamp-import-error
              (list (format "%s 已存在；覆盖需显式指定 force" target))))
    (let ((services (ebasecamp-import-service-plists
                     (ebasecamp-import-parse source)))
          (project-root (or root
                            (directory-file-name
                             (file-name-directory source)))))
      (make-directory (file-name-directory target) t)
      (with-temp-file target
        (insert (ebasecamp-import--manifest-content
                 project-name source project-root services)))
      ;; 自校验 1：文件可解析且 form 数量符合预期
      (let ((forms (ebasecamp-import--read-forms target)))
        (unless (= ebasecamp-import--manifest-form-count (length forms))
          (ebasecamp-import--restore-file target backup)
          (signal 'ebasecamp-import-error
                  (list (format
                         "%s 自校验失败：期望 %d 个顶层 form，实际 %d 个"
                         target ebasecamp-import--manifest-form-count
                         (length forms))))))
      ;; 自校验 2：清单层能加载、新项目已注册，且组内 :configs 已物化为
      ;; 带 :service-overrides 键的组引用（v0.2 格式的落地判据）
      (let* ((status (ebasecamp-config-load directory))
             (errors (plist-get status :errors))
             (project (ebasecamp-model-project project-name))
             (ref (and project
                       (cl-find project-name
                                (ebasecamp-project-groups project)
                                :key (lambda (reference)
                                       (plist-get reference :group))
                                :test #'eq)))
             (failure nil))
        (cond
         (errors
          (setq failure
                (mapconcat (lambda (item) (plist-get item :message))
                           errors "；")))
         ((null project)
          (setq failure "写入后新项目未出现在清单注册表中"))
         ((null ref)
          (setq failure (format "组内 :configs 未物化出指向组 %s 的引用"
                                project-name)))
         ((null (plist-member ref :service-overrides))
          (setq failure "物化出的组引用缺少 :service-overrides 键")))
        (when failure
          (ebasecamp-import--restore-file target backup)
          (signal 'ebasecamp-import-error
                  (list (format "%s 自校验失败：%s" target failure)))))
      target)))

;;;###autoload
(defun ebasecamp-import-file (file &optional name)
  "交互式把 compose 文件 FILE 导入为清单，返回清单文件绝对路径。
NAME 为默认项目名，省略时由 `ebasecamp-import-suggest-name' 推断；用户可在
迷你缓冲区中确认或修改。目标清单文件已存在时须确认才覆盖，用户拒绝则
`user-error' 中止。"
  (interactive "fCompose 文件：")
  (let* ((default (or name (ebasecamp-import-suggest-name file)))
         (input (read-string (format "项目名（%s）：" default)
                             nil nil
                             (if (stringp default)
                                 default
                               (symbol-name default))))
         (project-name (ebasecamp-import--normalize-name
                        (if (string-empty-p input) default input)))
         (target (ebasecamp-config-project-file project-name)))
    (when (and (file-exists-p target)
               (not (y-or-n-p (format "%s 已存在，覆盖？" target))))
      (user-error "已取消导入"))
    (let ((path (ebasecamp-import-apply file project-name :force t)))
      (message "已导入到 %s，运行 M-x ebasecamp 查看" path)
      path)))

(provide 'ebasecamp-import)
;;; ebasecamp-import.el ends here
