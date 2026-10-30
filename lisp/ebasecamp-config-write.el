;;; ebasecamp-config-write.el --- ebasecamp 清单写操作（字段映射 / 实体操作） -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.6.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 清单写操作的纯函数层与实体操作层：
;;
;; - **字段映射**（W2，纯函数、无 IO）：服务 6 个字段的结构 ↔ 文本双向映射；
;; - **实体操作**（W3，经 manifest 扫描 + 写盘事务）：服务字段写回、组内配置的
;;   新增 / 改 `:project' / 删除 / 跨组移动，以及项目与组自身的 CRUD（W3.3）。
;;
;; 两层分工：映射层只做「文本 ↔ 结构」，不碰文件；实体操作层不重新实现文本
;; 生成，一律复用 `ebasecamp-manifest' 的生成器与
;; `ebasecamp-manifest--write-transaction'（备份 → 原子写 → 仅新增错误才回滚），
;; 也不经 model 对象重建——不改的字段必须按**原文 plist** 保值。
;;
;; 新增文件的路径：项目写 `projects/<name>.el`（不存在则连同 `projects/' 一起
;; 创建），组写 `groups.el`（不存在则新建）。**改动已有组时的落盘文件不是固定的**：
;; 组可能定义在 `groups.el'，也可能定义在 `projects/*.el'（导入层就把「组 + 项目」
;; 一起写进项目文件），因此每次写操作先用 `--manifest-file-for-group' 按组名跨
;; 文件定位，再在该文件上开事务；同名组出现在两个文件时定位函数 `user-error'
;; 拒绝写盘（加载层对重复组名报错并回滚后加载文件，静默选第一个会让修改看起来
;; 无效）。新增/删除不走「原文替换」事务，
;; 而是「写前快照错误集 → 写/删 → 差集校验 → 有新增错误就撤掉」：
;;   - 新增项目 / 新增组（groups.el 不存在时）：`ebasecamp-manifest--write-new-file`
;;     落地，校验失败删除该文件；
;;   - 删除项目：删除前先确认路径确在 `projects/' 且文件名与项目名一致，然后
;;     「删文件 → 校验 → 有新增错误就用原文与原始权限位恢复」。
;; 两处引用扫描的归属不可混用：删除**项目**前扫组侧 `:configs' 的 `:project'
;; （`--config-references'）；删除**组**前扫项目侧旧写法 `:groups'
;; （`--legacy-group-references'）。
;;
;; 映射规则（与计划的「数据映射」表一一对应）：
;; - `ports'：结构 `((PUBLISHED . TARGET) ...)' ↔ 文本每行 `PUBLISHED:TARGET'。
;;   **单段语义**：输入（文本 → 结构）允许只写 `CONTAINER'，按「仅容器端口」
;;   解释为 `((N . N))'；输出（结构 → 文本）**恒写两段**，即使 HOST == TARGET
;;   也不折叠成单段——这样 `((80 . 80))' 与 `"80"' 两个来源的往返都稳定。
;; - `environment'：结构 `((KEY . VALUE) ...)' ↔ 文本每行 `KEY=VALUE'，按**首个**
;;   `=' 切分（值里可以再含 `='）。`${VAR}' 一律原样保留，绝不插值。
;; - `volumes'：结构为 **plist 列表** `(:source SRC :target DST :type bind|volume
;;   [:read-only t])'（model 只接受 plist，字符串列表会被 `ebasecamp-config-load'
;;   拒绝）↔ 文本每行 `SRC:DST[:ro]'。类型推断：`SRC' 以 `.` 或 `/` 开头 → bind，
;;   否则命名卷 volume；**单段** `DST' → `(:target DST :type volume)'（匿名卷）；
;;   只有 `:source' 为空/nil 时才输出单段。第三段只接受 `ro'（其它写法、`tmpfs'、
;;   四段以上的形态不在此表单编辑，直接报错而不是静默改写）。
;; - `command'：`("arg" ...)' ↔ 文本每行一个参数（**行内空格属于参数本身**）；
;;   文本**不含换行**时按空白切分（便于手输一行）。这是 **exec 形式**的边界：
;;   shell 形式的原值（含 `sh -c' 语义的单个字符串）由调用方在「用户未改动」
;;   时跳过重写，本模块不负责把它转成列表。
;; - `restart'：字符串 ↔ 原样文本，四个枚举值（`no' / `always' / `on-failure' /
;;   `unless-stopped'）之外允许 free-form（如 `"on-failure:5"'），不报错。
;; - `image'：单行非空字符串，首尾空白去掉后为空即 `user-error'。
;;
;; 错误约定：所有**解析**（文本 → 结构）失败一律 `user-error'，消息以
;; 「第 N 行：…」开头（行号 1-based、空行不计入内容但占行号）；结构 → 文本 的
;; 非法输入（例如不是整数对）直接 `user-error'，不带行号。
;; 复用的父错误 `ebasecamp-config-write-error' 定义在 `ebasecamp-manifest.el'
;; （W1.4），本模块只 `require' 不重定义，避免两处口径漂移。
;;
;; 安全约定（AGENTS.md 不变量 6）：本模块只搬运 `${VAR}' 引用与相对路径，
;; 不插值、不读取、不打印任何密钥值。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebasecamp-manifest)
;; 复用导入侧的实体名校验（`ebasecamp-import--normalize-name'）：项目名与组名
;; 是同一口径（AGENTS 不变量 1，`[a-z0-9_-]+'），不在这里另立实现以免漂移。
;; 代价是写操作层传递依赖导入层（含 docker / json），换来的是校验规则唯一。
(require 'ebasecamp-import)

;;; 常量

(defconst ebasecamp-config-write-restart-values
  '("no" "always" "on-failure" "unless-stopped")
  "restart 字段的枚举值（与 compose 一致）。
不在其中的值按 free-form 处理（例如 `\"on-failure:5\"'），表单落到「自定义」。")

(defconst ebasecamp-config-write--port-regexp
  "\\`\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\'"
  "端口行的正则：`HOST:CONTAINER' 或单段 `CONTAINER'（均为十进制整数）。")

;;; 错误构造

(defun ebasecamp-config-write--line-error (line format-string &rest args)
  "在第 LINE 行报 `user-error'，FORMAT-STRING 与 ARGS 组成消息主体。"
  (user-error "第 %d 行：%s" line (apply #'format format-string args)))

(defun ebasecamp-config-write--plist-error (format-string &rest args)
  "报不带行号的 `user-error'（结构 → 文本 方向的非法输入）。"
  (user-error "%s" (apply #'format format-string args)))

;;; ports

(defun ebasecamp-config-write-ports-to-text (ports)
  "把结构 PORTS 渲染为文本，每行 `PUBLISHED:TARGET'。
PORTS 为 `((PUBLISHED . TARGET) ...)' 整数对列表（与
`ebasecamp-model--check-ports' 一致）；nil 渲染为空串。
单段形态只用于输入，输出恒为两段（见文件头「单段语义」）。"
  (mapconcat (lambda (pair)
               (unless (and (consp pair)
                            (integerp (car pair))
                            (integerp (cdr pair)))
                 (ebasecamp-config-write--plist-error
                  "ports 元素必须是 (PUBLISHED . TARGET) 整数对，得到 %S" pair))
               (format "%d:%d" (car pair) (cdr pair)))
             ports
             "\n"))

(defun ebasecamp-config-write-text-to-ports (text)
  "把文本 TEXT 解析为 `((PUBLISHED . TARGET) ...)'。
每行 `HOST:CONTAINER'；**单段** `CONTAINER' 按仅容器端口解释为 `((N . N))'。
空行与行的首尾空白忽略；行号 1-based 计入空行。
非整数、负数、缺一段（`8080:' / `:80'）、多冒号等一律 `user-error' 并带行号。"
  (let ((line-number 0)
        (ports nil))
    (dolist (raw-line (split-string (or text "") "\n"))
      (setq line-number (1+ line-number))
      (let ((line (string-trim raw-line)))
        (unless (string-empty-p line)
          (unless (string-match ebasecamp-config-write--port-regexp line)
            (ebasecamp-config-write--line-error
             line-number
             "端口必须写成 `HOST:CONTAINER' 或 `CONTAINER'（十进制整数），得到 %S"
             line))
          (let ((published (string-to-number (match-string 1 line)))
                (target (match-string 2 line)))
            (push (cons published
                        (if target (string-to-number target) published))
                  ports)))))
    (nreverse ports)))

;;; environment

(defun ebasecamp-config-write-environment-to-text (environment)
  "把 alist ENVIRONMENT 渲染为文本，每行 `KEY=VALUE'。
键值均为字符串；`${VAR}' 引用原样输出（本函数不做任何插值）。"
  (mapconcat (lambda (pair)
               (unless (and (consp pair) (stringp (car pair)) (stringp (cdr pair)))
                 (ebasecamp-config-write--plist-error
                  "environment 元素必须是 (KEY . VALUE) 字符串对，得到 %S" pair))
               (concat (car pair) "=" (cdr pair)))
             environment
             "\n"))

(defun ebasecamp-config-write-text-to-environment (text)
  "把文本 TEXT 解析为 `((KEY . VALUE) ...)'，每行 `KEY=VALUE'。
按**首个** `=' 切分，因此值里可以再含 `='；`${VAR}' 原样保留。
空行与行的首尾空白忽略。缺 `='、空键、重复键一律 `user-error' 并带行号
（重复键报第二次出现的行号，并指出首次出现的行号）。"
  (let ((line-number 0)
        (seen nil)
        (environment nil))
    (dolist (raw-line (split-string (or text "") "\n"))
      (setq line-number (1+ line-number))
      (let ((line (string-trim raw-line)))
        (unless (string-empty-p line)
          (let ((equals (string-match "=" line)))
            (unless equals
              (ebasecamp-config-write--line-error
               line-number "环境变量必须写成 KEY=VALUE，得到 %S" line))
            (let ((key (substring line 0 equals))
                  (value (substring line (1+ equals))))
              (when (string-empty-p key)
                (ebasecamp-config-write--line-error
                 line-number "环境变量键不能为空，得到 %S" line))
              (let ((first-line (cdr (assoc key seen))))
                (when first-line
                  (ebasecamp-config-write--line-error
                   line-number "环境变量键 %s 重复（首次出现在第 %d 行）"
                   key first-line)))
              (push (cons key line-number) seen)
              (push (cons key value) environment))))))
    (nreverse environment)))

;;; volumes

(defun ebasecamp-config-write--path-like-p (source)
  "判断卷源 SOURCE 是否为宿主路径（`.' 或 `/' 开头 → bind 挂载）。"
  (or (string-prefix-p "/" source)
      (string-prefix-p "." source)))

(defun ebasecamp-config-write--volume-to-text (volume)
  "把单个卷 plist VOLUME 渲染为 `SRC:DST[:ro]'；缺 `:source' 时只写 `DST'。"
  (unless (and (proper-list-p volume) (keywordp (car volume)))
    (ebasecamp-config-write--plist-error
     "volumes 元素必须是 plist（如 (:source \"./data\" :target \"/x\" :type bind)），得到 %S"
     volume))
  (let ((source (plist-get volume :source))
        (target (plist-get volume :target))
        (read-only (plist-get volume :read-only)))
    (unless (and (stringp target) (not (string-empty-p target)))
      (ebasecamp-config-write--plist-error
       "volumes 元素的 :target 必须是非空字符串，得到 %S" volume))
    (when (and source (not (stringp source)))
      (ebasecamp-config-write--plist-error
       "volumes 元素的 :source 必须是字符串或 nil，得到 %S" volume))
    (if (and (stringp source) (not (string-empty-p source)))
        (concat source ":" target (if read-only ":ro" ""))
      target)))

(defun ebasecamp-config-write-volumes-to-text (volumes)
  "把卷 plist 列表 VOLUMES 渲染为文本，每行 `SRC:DST[:ro]'（缺源时只写 `DST'）。
VOLUMES 元素形态见 `ebasecamp-config-write--volume-to-text'；nil 渲染为空串。"
  (mapconcat #'ebasecamp-config-write--volume-to-text volumes "\n"))

(defun ebasecamp-config-write--parse-volume (line line-number)
  "解析单行卷文本 LINE（行号 LINE-NUMBER）为 plist。
1 段 `DST' → 匿名卷；2 段 `SRC:DST' → 按源推断 bind / volume；
3 段且第三段为 `ro' → 只读。其余形态 `user-error' 带行号。"
  (let* ((segments (split-string line ":"))
         (count (length segments)))
    (when (> count 3)
      (ebasecamp-config-write--line-error
       line-number
       "卷写法段数过多（只支持 `SRC:DST[:ro]' 或 `DST'），得到 %S" line))
    (if (= count 1)
        (progn
          (when (string-empty-p (car segments))
            (ebasecamp-config-write--line-error
             line-number "卷的容器路径不能为空，得到 %S" line))
          (list :target (car segments) :type 'volume))
      (let ((source (nth 0 segments))
            (target (nth 1 segments))
            (flag (nth 2 segments)))
        (when (string-empty-p source)
          (ebasecamp-config-write--line-error
           line-number "卷的源路径不能为空（写成 `SRC:DST' 或只写 `DST'），得到 %S" line))
        (when (string-empty-p target)
          (ebasecamp-config-write--line-error
           line-number "卷的容器路径不能为空，得到 %S" line))
        (when (and flag (not (equal flag "ro")))
          (ebasecamp-config-write--line-error
           line-number "卷的第三段只支持 `ro'（只读），得到 %S" line))
        (append (list :source source
                      :target target
                      :type (if (ebasecamp-config-write--path-like-p source)
                                'bind
                              'volume))
                (when (equal flag "ro") (list :read-only t)))))))

(defun ebasecamp-config-write-text-to-volumes (text)
  "把文本 TEXT 解析为卷 plist 列表，每行 `SRC:DST[:ro]'。
类型推断：源以 `.` 或 `/` 开头 → `:type bind'，否则 `:type volume'；
单段 `DST' → `(:target DST :type volume)'（匿名卷）。
空行与行的首尾空白忽略；`tmpfs'、多段等不支持的形态一律 `user-error' 带行号
（不静默改写）。`${VAR}' 与相对路径原样保留。"
  (let ((line-number 0)
        (volumes nil))
    (dolist (raw-line (split-string (or text "") "\n"))
      (setq line-number (1+ line-number))
      (let ((line (string-trim raw-line)))
        (unless (string-empty-p line)
          (push (ebasecamp-config-write--parse-volume line line-number) volumes))))
    (nreverse volumes)))

;;; command

(defun ebasecamp-config-write-command-to-text (command)
  "把参数列表 COMMAND 渲染为文本，每行一个参数（exec 形式）。
参数内的空格因此得以保留；含换行的参数无法表达（compose 里也不会出现）。"
  (dolist (argument command)
    (unless (stringp argument)
      (ebasecamp-config-write--plist-error
       "command 元素必须是字符串，得到 %S" argument)))
  (mapconcat #'identity command "\n"))

(defun ebasecamp-config-write-text-to-command (text)
  "把文本 TEXT 解析为参数列表（exec 形式）。
文本**含换行**时：每行一个参数，行内空格属于参数本身，空白行忽略；
文本**不含换行**时：按空白切分（便于手输 `mysqld --x=1'）。
本函数只支持 exec 形式：shell 形式的原值（`sh -c' 语义）不在表单编辑范围内，
调用方应在用户未改动时跳过重写。"
  (let ((text (or text "")))
    (if (string-match-p "\n" text)
        (let ((arguments nil))
          (dolist (line (split-string text "\n"))
            (unless (string-empty-p (string-trim line))
              (push line arguments)))
          (nreverse arguments))
      (split-string (string-trim text) "[ \t]+" t))))

;;; restart

(defun ebasecamp-config-write-restart-enum-p (value)
  "判断 VALUE 是否为 restart 的枚举值之一（见
`ebasecamp-config-write-restart-values'）。"
  (and (stringp value)
       (member value ebasecamp-config-write-restart-values)
       t))

(defun ebasecamp-config-write-restart-to-text (restart)
  "把 RESTART 字符串渲染为文本；nil 渲染为空串。"
  (cond
   ((null restart) "")
   ((stringp restart) restart)
   (t (ebasecamp-config-write--plist-error
       "restart 必须是字符串或 nil，得到 %S" restart))))

(defun ebasecamp-config-write-text-to-restart (text)
  "把文本 TEXT 解析为 restart 字符串；空白文本返回 nil。
不去校验枚举：`on-failure:5' 这类 compose free-form 值原样保留。"
  (let ((value (string-trim (or text ""))))
    (if (string-empty-p value) nil value)))

;;; image

(defun ebasecamp-config-write-text-to-image (text)
  "把文本 TEXT 解析为镜像名（去掉首尾空白）。
空串、只有空白或 nil → `user-error'「镜像（image）不能为空」。"
  (let ((value (string-trim (or text ""))))
    (when (string-empty-p value)
      (ebasecamp-config-write--plist-error "镜像（image）不能为空"))
    value))

;;; 实体操作：路径、缩进与扫描辅助

(defconst ebasecamp-config-write-editable-service-keys
  '(:image :command :environment :ports :volumes :restart)
  "可经表单编辑并由 `ebasecamp-config-write-update-service-fields' 写回的字段。
与计划 M5「数据映射」的 6 个字段一致。其余服务字段（`healthcheck' / `labels' /
`networks' / `extra' / `entrypoint' / `working-dir' / `user' / `depends-on'）
写回时一律按原文保留；把不在本列表里的键传给更新函数会 `user-error'，避免
调用方以为「传了就生效」而实际被静默丢弃。")

(defun ebasecamp-config-write--groups-file ()
  "返回当前清单目录里 `groups.el' 的绝对路径。"
  (expand-file-name "groups.el" (ebasecamp-config--directory)))

;;; 实体操作：跨文件定位组
;;
;; 组可以定义在 `groups.el'，也可以定义在 `projects/*.el'（导入层就把「组 +
;; 项目」一起写进项目文件，见 `ebasecamp-import'）。加载层两者都读，因此写操作
;; 不能再假定「组定义在 groups.el」。
;;
;; 裁决规则由 X0 实测结论决定：同名组出现在两个文件时加载层报「组 X 已定义」
;; 且**后加载文件整体回滚**（同文件里的项目一起从界面消失），所以定位对
;; >1 命中必须拒绝写盘——静默选第一个会让用户的修改落在「被回滚的那份定义」上，
;; 看起来「改完没效果」，而界面上项目已经不见。

(defun ebasecamp-config-write--group-manifest-files ()
  "返回清单里**含组 form** 的全部文件（`groups.el' 优先，其次 `projects/*.el'）。
顺序与 `ebasecamp-config--files' 的加载顺序一致。不含组 form 的文件被跳过：
它不可能定义任何组，跳过不改变定位结果，只是省掉重复扫描。"
  (let ((files nil))
    (dolist (file (ebasecamp-config--files (ebasecamp-config--directory)))
      (when (cl-find 'group (ebasecamp-manifest--scan-forms file)
                     :key (lambda (form) (plist-get form :kind)))
        (push file files)))
    (nreverse files)))

(defun ebasecamp-config-write--group-files (group-name)
  "返回清单里定义组 GROUP-NAME 的全部文件（按加载顺序，可能 0 / 1 / 多个）。
**不做唯一性裁决**：裁决交给 `--manifest-file-for-group'，引用扫描则故意要
全覆盖（`--config-references'）。GROUP-NAME 可为符号或字符串。"
  (let ((hits nil))
    (dolist (file (ebasecamp-config-write--group-manifest-files))
      (when (ebasecamp-manifest--locate-form
             'group group-name (ebasecamp-manifest--scan-forms file))
        (push file hits)))
    (nreverse hits)))

(defun ebasecamp-config-write--manifest-file-for-group (group-name)
  "返回定义组 GROUP-NAME 的清单文件绝对路径（0 命中 / 多命中都 `user-error'）。
GROUP-NAME 可为符号或字符串。按 `ebasecamp-config--files' 的顺序（`groups.el'
优先，其次 `projects/*.el' 字典序）扫描含该组 form 的文件：

- 0 命中 → `user-error'「清单里没有组 X（已扫描 N 个文件）」；
- >1 命中（同名组被重复定义）→ `user-error' 并列出全部文件，让用户先清理；
  **不能**复用 `ebasecamp-manifest--locate-form' 的「返回第一个」语义：加载层
  对重复组名报「组 X 已定义」并回滚后加载文件，写错文件会让修改看似无效，而
  同文件的项目已经从界面消失；
- 1 命中 → 返回该文件。"
  (let* ((files (ebasecamp-config-write--group-manifest-files))
         (hits (ebasecamp-config-write--group-files group-name)))
    (cond
     ((null hits)
      (user-error "清单里没有组 %s（已扫描 %d 个文件）"
                  group-name (length files)))
     ((cdr hits)
      (user-error
       "组 %s 在多个文件中定义（%s）；请先清理重复定义——同名组会让后加载的文件整体回滚，其中项目不会出现在界面中"
       group-name (mapconcat #'identity hits "、")))
     (t (car hits)))))

(defun ebasecamp-config-write--symbol (value context)
  "把 VALUE（符号或字符串）归一化为符号；其它类型 `user-error'。
CONTEXT 用于错误消息。"
  (cond
   ((symbolp value) value)
   ((stringp value) (intern value))
   (t (user-error "%s 必须是符号或字符串，得到 %S" context value))))

(defun ebasecamp-config-write--column-at (text form)
  "返回 TEXT 中 FORM 起点所在的列（0-based，制表符按 1 列计）。
用于把生成器的相对缩进整体右移，使重渲染的片段与它在文件里的位置对齐。"
  (let ((index (1- (plist-get form :start)))
        (column 0))
    (while (and (> index 0)
                (not (eq ?\n (aref text (1- index)))))
      (setq index (1- index))
      (setq column (1+ column)))
    column))

(defun ebasecamp-config-write--indent-text (text column)
  "把 TEXT 的续行统一加 COLUMN 个空格缩进，首行与空行不变。
生成器（`ebasecamp-manifest-service-form' / `-group-form-from-plist'）的缩进
以列 0 为基准，整体右移后正好接在原文的缩进列上。"
  (if (<= (or column 0) 0)
      text
    (let* ((lines (split-string text "\n"))
           (prefix (make-string column ?\s)))
      (mapconcat #'identity
                 (cons (car lines)
                       (mapcar (lambda (line)
                                 (if (string-empty-p line)
                                     line
                                   (concat prefix line)))
                               (cdr lines)))
                 "\n"))))

(defun ebasecamp-config-write--form-plist (text form)
  "读出 TEXT 中 FORM（顶层组 form 的扫描记录）的属性 plist。
组 form 形如 (ebasecamp-define-group NAME :KEY VALUE ...)，因此取
`(cddr FORM-OBJ)'。**不经 model 归一化**——写回时未编辑的键保持用户原值形态
（例如 `:command' 原为字符串就仍是字符串）。"
  (cddr (read (substring text
                         (1- (plist-get form :start))
                         (1- (plist-get form :end))))))

(defun ebasecamp-config-write--require-group (file forms group-name)
  "从 FORMS 取组 GROUP-NAME 的扫描记录；没有该组时 `user-error'。"
  (or (ebasecamp-manifest--locate-form 'group group-name forms)
      (user-error "清单 %s 里没有组 %s" file group-name)))

(defun ebasecamp-config-write--edit-manifest (file editor &optional keep-backup)
  "对清单 FILE 执行一次写盘事务，返回写后的加载结果。
FILE 是**组定义实际所在**的清单文件——调用方先用
`--manifest-file-for-group' 定位（组可能在 `groups.el'，也可能在
`projects/*.el'），不要再固定取 `groups.el'。

EDITOR 接受 (TEXT FORMS FILE) 并返回新全文：TEXT 是原文，FORMS 是它在
`ebasecamp-manifest--scan-text-forms' 下的扫描结果，FILE 是该文件路径。

EDITOR 必须在内存里一次完成全部编辑（多处编辑用
`ebasecamp-manifest--replace-forms'，按位置降序替换保证原子性），且不得自己
写盘：备份、原子写、外部修改检测与「新增错误才回滚」统一由
`ebasecamp-manifest--write-transaction' 负责。EDITOR 里 signal 的
`user-error'（例如 D2 冲突）在任何写盘动作之前抛出，因此不会留下半截写入。

KEEP-BACKUP 非 nil 时把 `:keep-backup' 透传给
`ebasecamp-manifest--write-transaction'，返回值随之变成
`\(:result LOAD-RESULT :backup BACKUP-PATH)'——跨文件编排需要第一段的事务前
备份做补偿（见 `--migrate-across-files'）。默认 nil 时返回值与历史一致
（既有调用点零改动）。"
  (ebasecamp-manifest--write-transaction
   file
   (lambda (text)
     (funcall editor text
              (ebasecamp-manifest--scan-text-forms text file)
              file))
   :keep-backup keep-backup))

(defun ebasecamp-config-write--render-group (text form plist)
  "把组 FORM（扫描记录）按 PLIST 重渲染，返回可替换该区段的新文本。
组 form 内部排版规范化（见 `ebasecamp-manifest-group-form-from-plist'），
续行缩进对齐到 FORM 在原文件里的列。"
  (ebasecamp-config-write--indent-text
   (ebasecamp-manifest-group-form-from-plist (plist-get form :name) plist)
   (ebasecamp-config-write--column-at text form)))

(defun ebasecamp-config-write--replace-group (text form plist)
  "把 TEXT 中组 FORM 的区段替换为重渲染后的组（PLIST 为组属性），返回新全文。
**必须用它而不是直接返回 `--render-group' 的结果**：`--render-group' 只渲染
目标组这一段的文本，写盘事务需要的是「整份新全文」——直接把渲染结果当全文会
把 groups.el 覆盖成单个组（兄弟组与文件头全部丢失）。组之外的字节由
`ebasecamp-manifest--replace-form' 逐字节保留。"
  (ebasecamp-manifest--replace-form
   text form (ebasecamp-config-write--render-group text form plist)))

(defun ebasecamp-config-write--with-configs (plist configs)
  "返回 PLIST 的浅拷贝，`:configs' 设为 CONFIGS。
浅拷贝只为不修改 `read' 出来的原文 plist 之外的对象——原文 plist 本身是一次性
对象，但显式拷贝让「渲染用的 plist」与「比较用的 plist」互不影响。"
  (plist-put (copy-sequence plist) :configs configs))

;;; 实体操作：D2 校验

(defun ebasecamp-config-write--check-project-conflict (group-name configs project
                                                                  &optional ignore)
  "校验组 GROUP-NAME 的配置 CONFIGS 中没有别的配置引用 PROJECT（D2 不变量）。
CONFIGS 是从原文读出的 ((配置名 :project P ...) ...)；IGNORE 为自身配置名
（改 `:project' 或组内移动时排除自己）。同一项目 + 同一组只允许 1 个引用，
冲突时 `user-error'，消息含项目名、组名与来源配置名。"
  (let ((conflict (cl-find-if
                   (lambda (spec)
                     (and (not (eq (car spec) ignore))
                          (eq project (plist-get (cdr spec) :project))))
                   configs)))
    (when conflict
      (user-error
       "项目 %s 已引用组 %s（来源：配置 %s）；同一项目同一组只允许 1 个引用"
       project group-name (car conflict)))))

;;; 实体操作：服务字段更新

(defun ebasecamp-config-write--check-fields (fields)
  "校验 FIELDS 是关键字 plist 且键都属于 `--editable-service-keys'。"
  (unless (proper-list-p fields)
    (user-error "服务字段必须是 plist，得到 %S" fields))
  (unless (= 0 (% (length fields) 2))
    (user-error "服务字段 plist 的键值必须成对，得到 %S" fields))
  (let ((rest fields))
    (while rest
      (unless (keywordp (car rest))
        (user-error "服务字段名必须是关键字，得到 %S" (car rest)))
      (unless (memq (car rest) ebasecamp-config-write-editable-service-keys)
        (user-error "字段 %s 不支持写回（只支持 %s）" (car rest)
                    (mapconcat #'symbol-name
                               ebasecamp-config-write-editable-service-keys
                               " / ")))
      (setq rest (cddr rest)))))

(defun ebasecamp-config-write--merge-service-fields (original fields)
  "把 FIELDS 合并进原文服务 plist ORIGINAL，返回新 plist。
保持 ORIGINAL 的键顺序；FIELDS 里值为 nil 的键表示删除该键；ORIGINAL 没有的
新键按 FIELDS 的顺序追加在末尾。其余键的值**原样带回**（不经 model 归一化）。"
  (let ((result nil))
    (let ((rest original))
      (while rest
        (let ((key (car rest))
              (value (cadr rest)))
          (if (plist-member fields key)
              (let ((replacement (plist-get fields key)))
                (when replacement
                  (setq result (append result (list key replacement)))))
            (setq result (append result (list key value)))))
        (setq rest (cddr rest))))
    (let ((rest fields))
      (while rest
        (let ((key (car rest))
              (value (cadr rest)))
          (unless (plist-member original key)
            (when value
              (setq result (append result (list key value))))))
        (setq rest (cddr rest))))
    result))

(defun ebasecamp-config-write--fields-unchanged-p (original fields)
  "判断 FIELDS 的每个键都与 ORIGINAL 的取值 `equal'（提供 nil 与缺键等价）。"
  (let ((rest fields)
        (unchanged t))
    (while (and rest unchanged)
      (unless (equal (plist-get fields (car rest))
                     (plist-get original (car rest)))
        (setq unchanged nil))
      (setq rest (cddr rest)))
    unchanged))

(defun ebasecamp-config-write--head-end (text form)
  "返回 TEXT 中顶层 form FORM 头部 `(SYMBOL NAME' 之后的位置（1-based）。
组 form `(ebasecamp-define-group NAME ...)' 与项目 form
`(ebasecamp-define-project NAME ...)' 是同一形态（car 符号 + 实体名 + 关键字），
因此「跳过 car 与名字」这一步两者共用；调用方据此从第一个关键字开始顺序读元素。"
  (with-temp-buffer
    (insert text)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (goto-char (plist-get form :start))
    (forward-char 1)                ; 跳过 `('
    (read (current-buffer))         ; ebasecamp-define-group / -project
    (read (current-buffer))         ; 实体名
    (point)))

(defun ebasecamp-config-write--group-head-end (text form)
  "返回 TEXT 中组 FORM 头部 `(ebasecamp-define-group NAME' 之后的位置（1-based）。
调用方据此从组内第一个关键字开始顺序读元素；实现委托 `--head-end'（同一形态）。"
  (ebasecamp-config-write--head-end text form))

(defun ebasecamp-config-write--service-region (text form service-name)
  "在组 FORM 的文本里定位服务 SERVICE-NAME 的子 form，返回 (:start :end)。
做法（两级区域扫描，不写自定义扫描器）：先跳过 `(ebasecamp-define-group NAME'
头部，在组 form 内部顺序读元素（关键字与取值），取 `:services' 关键字的取值
元素，再在它的括号内部顺序读服务子 form。组内没有 `:services'、`:services'
不是列表、或该服务不存在时返回 nil。"
  (let* ((elements (ebasecamp-manifest--scan-forms-in-region
                    text
                    (ebasecamp-config-write--group-head-end text form)
                    (1- (plist-get form :end))))
         (services nil))
    (while (and elements (null services))
      (when (eq :services (plist-get (car elements) :value))
        (setq services (cadr elements)))
      (setq elements (cdr elements)))
    (when (and services (consp (plist-get services :value)))
      (cl-find-if
       (lambda (element)
         (let ((value (plist-get element :value)))
           (and (consp value) (eq service-name (car value)))))
       (ebasecamp-manifest--scan-forms-in-region
        text
        (1+ (plist-get services :start))
        (1- (plist-get services :end)))))))

(defun ebasecamp-config-write-update-service-fields (group-name service-name fields)
  "把服务 SERVICE-NAME 的 FIELDS 写回组 GROUP-NAME 的定义。
组定义所在的清单文件由定位函数决定（`groups.el' 或 `projects/*.el'）。
GROUP-NAME / SERVICE-NAME 可为符号或字符串；FIELDS 为属性 plist，键限于
`ebasecamp-config-write-editable-service-keys'（image / ports / environment /
volumes / command / restart），取值为**结构形态**（`:ports' 取
`((9090 . 90))'、`:environment' 取 `((\"K\" . \"V\"))'）；某个键的值为 nil
表示删除该键。文本形态请先用本模块的 `text-to-*' 解析。

保值保证：未出现在 FIELDS 里的键从**原文 plist** 取值后原样带回（不经 model
归一化），因此 `:healthcheck' / `:extra' / `:labels' / `:networks' 等字段的
值不变；服务子 form 之外的字节（其它服务、组 `:configs'、注释）逐字节保留，
服务子 form 内部的注释与排版按 `ebasecamp-manifest-service-form' 规范化。

FIELDS 的每个键都与原值相同时**不写盘**（文件内容与 mtime 都不变），直接返回
当前加载结果。写盘成功返回加载结果；写后引入新加载错误时由
`ebasecamp-manifest--write-transaction' 回滚并 signal
`ebasecamp-config-write-error'。"
  (let ((group (ebasecamp-config-write--symbol group-name "组名"))
        (service (ebasecamp-config-write--symbol service-name "服务名")))
    (ebasecamp-config-write--check-fields fields)
    (ebasecamp-config-write--edit-manifest
     (ebasecamp-config-write--manifest-file-for-group group)
     (lambda (text forms file)
       (let* ((form (ebasecamp-config-write--require-group file forms group))
              (plist (ebasecamp-config-write--form-plist text form))
              (spec (assq service (plist-get plist :services))))
         (unless spec
           (user-error "组 %s 没有服务 %s" group service))
         (if (ebasecamp-config-write--fields-unchanged-p (cdr spec) fields)
             text
           (let ((region (ebasecamp-config-write--service-region
                          text form service)))
             (unless region
               (user-error "在组 %s 的文本里定位不到服务 %s 的定义"
                           group service))
             (ebasecamp-manifest--replace-form
              text region
              (ebasecamp-config-write--indent-text
               (ebasecamp-manifest-service-form
                service
                (ebasecamp-config-write--merge-service-fields (cdr spec) fields))
               (ebasecamp-config-write--column-at text region))))))))))

;;; 实体操作：旧写法 :groups 的定位与迁移（A-II）
;;
;; 背景：A-I 让「项目侧旧 `:groups' + 组侧 `:configs'」指向同项目同组时不再报错
;; （组侧配置原位接管）。A-II 在**用户确认**后把旧引用从项目文件里真正删掉；
;; 写盘层的 `migrate-legacy' 参数默认 nil，脚本 / 测试调用零行为变更。
;;
;; 定位不复用 `ebasecamp-manifest--locate-form'（那是「单个 form」的单命中语义，
;; 给不出 `:groups' **元素**的区间），也不复用 `--legacy-group-references'（只回
;; 项目名列表、没有位置）。这里做的是两级区域扫描：先在 project form 内定位
;; `:groups' 关键字与它的取值列表，再在列表内部定位引用该组的那一个元素。

(defun ebasecamp-config-write--project-form-in (forms project)
  "从扫描结果 FORMS 里取项目 PROJECT 的 form 记录；没有返回 nil。
只在一个文件的 FORMS 内匹配（同文件内项目名唯一——重名项目是加载错误）。"
  (cl-find-if (lambda (form)
                (and (eq 'project (plist-get form :kind))
                     (eq project (plist-get form :name))))
              forms))

(defun ebasecamp-config-write--groups-element-region (text form group)
  "在 TEXT 的 project FORM 内定位 `:groups' 里引用组 GROUP 的元素。
返回 plist：`:start' / `:end'（该**元素**的 1-based 区间，切片用 `(1- pos)'）、
`:key-start' / `:key-end' / `:value-end'（`:groups' 键与值的区间，供「删整键」
用）、`:sole'（该元素是否为 `:groups' 里唯一元素）。
FORM 里没有 `:groups'、`:groups' 不是列表、或列表里没有该组时返回 nil。

做法与 `--service-region' 同一模式（两级区域扫描，不写自定义扫描器）：先跳过
`(ebasecamp-define-project NAME' 头部，在 form 内部顺序读关键字与取值，取
`:groups' 的取值元素；再在它的括号内部顺序读每个引用元素，按 `car-safe' 匹配
组名。只匹配**第一个**命中——`:groups' 里重复写同一组本身是加载错误，这里不
做裁决。"
  (let* ((elements (ebasecamp-manifest--scan-forms-in-region
                    text
                    (ebasecamp-config-write--head-end text form)
                    (1- (plist-get form :end))))
         (key nil)
         (value nil)
         (rest elements))
    (while (and rest (null value))
      (when (eq :groups (plist-get (car rest) :value))
        (setq key (car rest)
              value (cadr rest)))
      (setq rest (cdr rest)))
    (when (and key value (consp (plist-get value :value)))
      (let* ((children (ebasecamp-manifest--scan-forms-in-region
                        text
                        (1+ (plist-get value :start))
                        (1- (plist-get value :end))))
             (element (cl-find-if
                       (lambda (child)
                         (eq group (car-safe (plist-get child :value))))
                       children)))
        (when element
          (list :start (plist-get element :start)
                :end (plist-get element :end)
                :key-start (plist-get key :start)
                :key-end (plist-get key :end)
                :value-end (plist-get value :end)
                :sole (= 1 (length children))))))))

(defun ebasecamp-config-write--element-removal-bounds (text start end)
  "返回删除 TEXT 中 `[START, END)'（0-based）元素时的实际区间 `(FROM . TO)'。
连同相邻空白一起删，避免留下双空格或空行：优先吃**后面**的一个空格；其后是
换行时连换行与下一行的缩进一起吃掉（多行 `:groups' 排版）；最后才吃**前面**的
一个空格。"
  (cond
   ((and (< end (length text)) (eq ?\s (aref text end)))
    (cons start (1+ end)))
   ((and (< end (length text)) (eq ?\n (aref text end)))
    (let ((index (1+ end)))
      (while (and (< index (length text))
                  (memq (aref text index) '(?\s ?\t)))
        (setq index (1+ index)))
      (cons start index)))
   ((and (> start 0) (eq ?\s (aref text (1- start))))
    (cons (1- start) end))
   (t (cons start end))))

(defun ebasecamp-config-write--key-removal-bounds (text start end)
  "返回删除 TEXT 中 `:groups' 键 `[START, END)'（0-based）时的实际区间。
连同该键所在行的缩进与行首换行一起删，避免留下空行；键与值同一行且前面还有
其它内容（手写的单行 form）时只吃掉前面的空白。"
  (let ((from start))
    (while (and (> from 0) (memq (aref text (1- from)) '(?\s ?\t)))
      (setq from (1- from)))
    (when (and (> from 0) (eq ?\n (aref text (1- from))))
      (setq from (1- from)))
    (cons from end)))

(defun ebasecamp-config-write--removal-form (text region)
  "把 `--groups-element-region' 的结果换算成一处「删除」编辑 `(FORM . \"\")'。
REGION 的位置是 **1-based**（切片口径同扫描器，内部统一 `1-` 换算成 0-based）。
REGION 的 `:sole' 为真时删整个 `:groups' 键（**不**留 `:groups nil'——项目渲染
用 `plist-member' 判定，键还在就会渲染出空值），否则只删该元素。
FORM 是只带 `:start' / `:end' 的假扫描记录，可直接交给
`ebasecamp-manifest--replace-forms'（与其它替换一起按位置降序应用）。"
  (let ((bounds (if (plist-get region :sole)
                    (ebasecamp-config-write--key-removal-bounds
                     text (1- (plist-get region :key-start))
                     (1- (plist-get region :value-end)))
                  (ebasecamp-config-write--element-removal-bounds
                   text
                   (1- (plist-get region :start))
                   (1- (plist-get region :end))))))
    (cons (list :start (1+ (car bounds)) :end (1+ (cdr bounds))) "")))

(defun ebasecamp-config-write--legacy-reference-file (project-name group-name)
  "返回项目 PROJECT-NAME 的旧写法 `:groups' 仍引用组 GROUP-NAME 的定位信息。
返回 `(FILE . PLIST)'：FILE 是项目定义所在的 `projects/*.el'，PLIST 含
`:start' / `:end'（该 `:groups' **元素**的 1-based 区间，切片用 `(1- pos)'）、
`:form-start' / `:form-end'（所在 project form 的区间）与 `:sole'（该元素是否为
`:groups' 里唯一元素）。无命中返回 nil。

只扫 `projects/*.el'（`ebasecamp-config--project-files' 的字典序）：新写法
（组侧 `:configs' 加载期物化）不落在项目文件里，因此这里只反映用户手写的引用。
**多文件命中时按该列表的顺序（字典序）返回第一个**：同一项目在同一清单里重名
定义本身就是加载错误（后加载的文件整体回滚），这里不裁决也不报错——写盘层
只需要一个可删的位置，重名项目交给加载层的错误提示。
读取原文而不看 model：model 可能因既有加载错误缺定义，而定位必须看到磁盘上的
真实引用（理由同 `--legacy-group-references'）。"
  (let ((project (ebasecamp-config-write--symbol project-name "项目名"))
        (group (ebasecamp-config-write--symbol group-name "组名"))
        (found nil))
    (dolist (file (ebasecamp-config--project-files))
      (unless found
        (let* ((text (ebasecamp-manifest--read-text file))
               (forms (ebasecamp-manifest--scan-text-forms text file))
               (form (ebasecamp-config-write--project-form-in forms project))
               (region (and form
                            (ebasecamp-config-write--groups-element-region
                             text form group))))
          (when region
            (setq found
                  (cons file
                        (list :start (plist-get region :start)
                              :end (plist-get region :end)
                              :form-start (plist-get form :start)
                              :form-end (plist-get form :end)
                              :sole (plist-get region :sole))))))))
    found))

(defun ebasecamp-config-write--remove-legacy-editor (project group)
  "返回删除项目 PROJECT 的 `:groups' 里组 GROUP 旧引用的 editor。
editor 只做一处区段删除（元素或整条 `:groups' 键），因此文件其它字节逐字节不变。"
  (lambda (text forms file)
    (let ((form (ebasecamp-config-write--project-form-in forms project)))
      (unless form
        (user-error "文件 %s 里没有项目 %s 的定义" file project))
      (let ((region (ebasecamp-config-write--groups-element-region
                     text form group)))
        (unless region
          (user-error "项目 %s 的 :groups 里没有对组 %s 的旧引用" project group))
        (ebasecamp-manifest--replace-forms
         text (list (ebasecamp-config-write--removal-form text region)))))))

(defun ebasecamp-config-write--migrate-legacy (project-name group-name)
  "删除项目 PROJECT-NAME 清单文件里 `:groups' 对组 GROUP-NAME 的旧引用（一次事务）。
`:groups' 只剩该元素时整条键被移除（不留 `:groups nil'）。返回写后的加载结果。

这是 A-II 跨文件路径的**第二段**，也是「只删旧引用」的独立入口；同文件路径不
用它（那时组侧追加与项目侧删除必须在同一次事务里完成，见
`--add-config-within-file-editor'）。拒绝条件（`user-error'，写盘前抛出）：
项目 / 组名非法、清单里找不到该旧引用、文件里没有该项目的 form。"
  (let* ((project (ebasecamp-config-write--symbol project-name "项目名"))
         (group (ebasecamp-config-write--symbol group-name "组名"))
         (reference (ebasecamp-config-write--legacy-reference-file project group)))
    (unless reference
      (user-error "清单里没有项目 %s 对组 %s 的旧 :groups 引用" project group))
    (ebasecamp-config-write--edit-manifest
     (car reference)
     (ebasecamp-config-write--remove-legacy-editor project group))))

(defun ebasecamp-config-write--migrate-across-files (group-file editor project group)
  "跨文件「改组 + 删旧引用」：**两次写盘事务 + 备份补偿**（不引入新原子性假设）。
GROUP-FILE 是组定义所在文件，EDITOR 是组侧编辑函数（新增配置 / 改配置
`:project' 共用本补偿模式），PROJECT / GROUP 是删除旧引用所需的名字。

① 先写组文件（`:keep-backup' 拿到事务前备份）→ ② 再删项目侧旧引用
（`--migrate-legacy' 自己是一次事务）；② 失败（包括「写后新增加载错误」触发的
自身回滚）时用 ① 的备份**恢复组文件原文**并把原错误 signal 出去，因此磁盘上
不会留下「组已加配置、旧引用还在」的半截状态。两段都成功才删除备份并返回加载
结果。对 ADR-0005 决策 2（单事务）的部分退化沿用在 ADR-0006 的口径：跨文件写盘
没有跨文件原子性可用，只能靠显式备份补偿。"
  (let* ((first (ebasecamp-config-write--edit-manifest group-file editor t))
         (backup (plist-get first :backup)))
    (condition-case err
        (let ((result (ebasecamp-config-write--migrate-legacy project group)))
          (ebasecamp-manifest--delete-file backup)
          result)
      (error
       (ebasecamp-config-write--restore-backup group-file backup)
       (signal (car err) (cdr err))))))

;;; 实体操作：组内配置的增改删与移动

(defun ebasecamp-config-write--add-config-editor (group config project)
  "返回「向组 GROUP 的 `:configs' 追加 CONFIG（`:project PROJECT'）」的 editor。
拒绝条件（都是 `user-error'，在任何写盘动作之前抛出）：组内已有同名配置、
**D2 冲突**（该组已有别的配置引用同一项目）。"
  (lambda (text forms file)
    (let* ((form (ebasecamp-config-write--require-group file forms group))
           (plist (ebasecamp-config-write--form-plist text form))
           (configs (plist-get plist :configs)))
      (when (assq config configs)
        (user-error "组 %s 已有配置 %s" group config))
      (ebasecamp-config-write--check-project-conflict group configs project)
      (ebasecamp-config-write--replace-group
       text form
       (ebasecamp-config-write--with-configs
        plist (append configs (list (list config :project project))))))))

(defun ebasecamp-config-write--add-config-within-file-editor (group config project)
  "返回「组侧追加配置 + 项目侧删旧引用」的 editor（**同一次事务**内两处替换）。
复用 `--move-config-within-file' 的 `--replace-forms' 模式：两处区段按 `:start'
降序应用，因此写盘只有一次，不存在「组已加、旧引用没删」的中间状态。"
  (lambda (text forms file)
    (let* ((group-form (ebasecamp-config-write--require-group file forms group))
           (plist (ebasecamp-config-write--form-plist text group-form))
           (configs (plist-get plist :configs))
           (project-form (ebasecamp-config-write--project-form-in forms project)))
      (when (assq config configs)
        (user-error "组 %s 已有配置 %s" group config))
      (ebasecamp-config-write--check-project-conflict group configs project)
      (unless project-form
        (user-error "文件 %s 里没有项目 %s 的定义" file project))
      (let ((region (ebasecamp-config-write--groups-element-region
                     text project-form group)))
        (unless region
          (user-error "项目 %s 的 :groups 里没有对组 %s 的旧引用" project group))
        (ebasecamp-manifest--replace-forms
         text
         (list
          (cons group-form
                (ebasecamp-config-write--render-group
                 text group-form
                 (ebasecamp-config-write--with-configs
                  plist (append configs (list (list config :project project))))))
          (ebasecamp-config-write--removal-form text region)))))))

(defun ebasecamp-config-write--update-config-project-editor (group config project)
  "返回「把组 GROUP 的配置 CONFIG 的 `:project' 改成 PROJECT」的 editor。
配置的其它键（`:services' 覆盖）原样保留；`:project' 与原值相同时不写盘（返回
原文），因此既有调用点的「没有改动就不碰文件」语义不变。"
  (lambda (text forms file)
    (let* ((form (ebasecamp-config-write--require-group file forms group))
           (plist (ebasecamp-config-write--form-plist text form))
           (configs (plist-get plist :configs))
           (spec (assq config configs)))
      (unless spec
        (user-error "组 %s 没有配置 %s" group config))
      (ebasecamp-config-write--check-project-conflict
       group configs project config)
      (if (eq project (plist-get (cdr spec) :project))
          text
        (ebasecamp-config-write--replace-group
         text form
         (ebasecamp-config-write--with-configs
          plist
          (mapcar (lambda (existing)
                    (if (eq (car existing) config)
                        (cons config
                              (plist-put (copy-sequence (cdr existing))
                                         :project project))
                      existing))
                  configs)))))))

(defun ebasecamp-config-write--update-config-project-within-file-editor
    (group config project)
  "返回「组侧改 `:project' + 项目侧删旧引用」的 editor（同一次事务）。
`:project' 与原值相同时组侧返回原文（不重渲染），但仍删项目侧旧引用——用户既然
确认了迁移，旧引用就该清掉。"
  (lambda (text forms file)
    (let* ((group-form (ebasecamp-config-write--require-group file forms group))
           (plist (ebasecamp-config-write--form-plist text group-form))
           (configs (plist-get plist :configs))
           (spec (assq config configs))
           (project-form (ebasecamp-config-write--project-form-in forms project)))
      (unless spec
        (user-error "组 %s 没有配置 %s" group config))
      (ebasecamp-config-write--check-project-conflict
       group configs project config)
      (unless project-form
        (user-error "文件 %s 里没有项目 %s 的定义" file project))
      (let ((region (ebasecamp-config-write--groups-element-region
                     text project-form group)))
        (unless region
          (user-error "项目 %s 的 :groups 里没有对组 %s 的旧引用" project group))
        (ebasecamp-manifest--replace-forms
         text
         (append
          (unless (eq project (plist-get (cdr spec) :project))
            (list
             (cons group-form
                   (ebasecamp-config-write--render-group
                    text group-form
                    (ebasecamp-config-write--with-configs
                     plist
                     (mapcar (lambda (existing)
                               (if (eq (car existing) config)
                                   (cons config
                                         (plist-put
                                          (copy-sequence (cdr existing))
                                          :project project))
                                 existing))
                             configs))))))
          (list (ebasecamp-config-write--removal-form text region))))))))

(defun ebasecamp-config-write-add-config (group-name config-name project
                                                    &optional migrate-legacy)
  "给组 GROUP-NAME 追加配置 CONFIG-NAME，关联项目 PROJECT（均为符号或字符串）。
只写组侧 `:configs'（AGENTS 不变量 9），不写项目侧旧 `:groups'。

MIGRATE-LEGACY 非 nil 时，额外把项目侧旧写法 `:groups' 里对本组的引用删掉
（A-II 迁移）。**默认 nil：脚本 / 测试 / 程序化调用绝不改写项目文件**——只有
界面层在 `y-or-n-p' 得到 yes 之后才传 t（见 `ebasecamp-ui--manifest-menu'）。
两条编排路径按「组定义与项目定义是否在同一文件」分派：

- 同文件（组写在 `projects/x.el'，项目也在该文件）→ **一次事务**内两处降序替换
  （组侧 `:configs' 追加 + 项目侧删元素），复用 `--replace-forms'；
- 跨文件（组在 `groups.el'、项目在 `projects/*.el'）→ **两次事务 + 备份补偿**：
  第二段失败用第一段的备份恢复组文件原文并 signal 原错误（沿用
  `--move-config-across-files' 的补偿模式，跨文件没有原子性可用）；
- 没命中旧引用（或 MIGRATE-LEGACY 为 nil）→ 走原有单事务路径，逐字节不变。

拒绝条件（都是 `user-error'，在任何写盘动作之前抛出）：
- 组不存在 / 组内已有同名配置；
- **D2 冲突**：该组已有别的配置引用同一项目（同一项目同一组只允许 1 个引用）；
- MIGRATE-LEGACY 非 nil 但旧引用定位到的文件里没有该项目的 form（清单被外部
  改坏的极端情形）。

成功时整组 form 被重渲染（组内部排版规范化），返回写后的加载结果；
写后引入新加载错误时由事务回滚并 signal `ebasecamp-config-write-error'。"
  (let ((group (ebasecamp-config-write--symbol group-name "组名"))
        (config (ebasecamp-config-write--symbol config-name "配置名"))
        (project (ebasecamp-config-write--symbol project "项目名")))
    (let* ((group-file (ebasecamp-config-write--manifest-file-for-group group))
           (reference (and migrate-legacy
                           (ebasecamp-config-write--legacy-reference-file
                            project group))))
      (cond
       ((null reference)
        (ebasecamp-config-write--edit-manifest
         group-file
         (ebasecamp-config-write--add-config-editor group config project)))
       ((equal (expand-file-name (car reference)) group-file)
        (ebasecamp-config-write--edit-manifest
         group-file
         (ebasecamp-config-write--add-config-within-file-editor
          group config project)))
       (t
        (ebasecamp-config-write--migrate-across-files
         group-file
         (ebasecamp-config-write--add-config-editor group config project)
         project group))))))

(defun ebasecamp-config-write-update-config-project (group-name config-name project
                                                                &optional migrate-legacy)
  "把组 GROUP-NAME 中配置 CONFIG-NAME 的 `:project' 改为 PROJECT。
配置的其它键（`:services' 覆盖）原样保留；项目侧的组引用由加载期物化，不手写。

MIGRATE-LEGACY 非 nil 时额外删掉项目侧旧写法 `:groups' 里对本组的引用（A-II
迁移；界面层 `E' 在用户确认后传 t）。**默认 nil：绝不改写项目文件。**
分派与补偿语义同 `ebasecamp-config-write-add-config'：同文件一次事务、跨文件
两次事务 + 备份补偿。`:project' 与原值相同时组文件不写盘，但仍会删旧引用。

拒绝条件（`user-error'，写盘前抛出）：组或配置不存在；**D2 冲突**——同组内
还有别的配置引用 PROJECT。"
  (let ((group (ebasecamp-config-write--symbol group-name "组名"))
        (config (ebasecamp-config-write--symbol config-name "配置名"))
        (project (ebasecamp-config-write--symbol project "项目名")))
    (let* ((group-file (ebasecamp-config-write--manifest-file-for-group group))
           (reference (and migrate-legacy
                           (ebasecamp-config-write--legacy-reference-file
                            project group))))
      (cond
       ((null reference)
        (ebasecamp-config-write--edit-manifest
         group-file
         (ebasecamp-config-write--update-config-project-editor
          group config project)))
       ((equal (expand-file-name (car reference)) group-file)
        (ebasecamp-config-write--edit-manifest
         group-file
         (ebasecamp-config-write--update-config-project-within-file-editor
          group config project)))
       (t
        (ebasecamp-config-write--migrate-across-files
         group-file
         (ebasecamp-config-write--update-config-project-editor
          group config project)
         project group))))))

(defun ebasecamp-config-write-remove-config (group-name config-name)
  "从组 GROUP-NAME 删除配置 CONFIG-NAME；组本身保留（删掉最后一份配置后
`:configs' 变成 nil，不会连带删除组）。
配置不存在时 `user-error'。成功返回写后的加载结果。"
  (let ((group (ebasecamp-config-write--symbol group-name "组名"))
        (config (ebasecamp-config-write--symbol config-name "配置名")))
    (ebasecamp-config-write--edit-manifest
     (ebasecamp-config-write--manifest-file-for-group group)
     (lambda (text forms file)
       (let* ((form (ebasecamp-config-write--require-group file forms group))
              (plist (ebasecamp-config-write--form-plist text form))
              (configs (plist-get plist :configs)))
         (unless (assq config configs)
           (user-error "组 %s 没有配置 %s" group config))
         (ebasecamp-config-write--replace-group
          text form
          (ebasecamp-config-write--with-configs
           plist (assq-delete-all config configs))))))))

(defun ebasecamp-config-write--check-move
    (source-name source-plist target-name target-plist config project same-group)
  "校验移动配置的拒绝条件，返回要搬走的配置 form。
SOURCE-PLIST / TARGET-PLIST 是源组与目标组的**原文**属性 plist（同一个组时
传同一个）；SAME-GROUP 为 t 表示源组与目标组是同一个组。返回形态为
\(CONFIG :project PROJECT [:services 覆盖])，`:services' 覆盖随配置一起搬走。

拒绝条件（都是 `user-error'，调用方保证在写盘前抛出）：源组没有 CONFIG、
目标组已有同名配置、**D2 冲突**（目标组已有别的配置引用 PROJECT；同组时排除
自己）。同文件与跨文件两条路径共用本函数，避免两处口径漂移。"
  (let* ((from-configs (plist-get source-plist :configs))
         (to-configs (plist-get target-plist :configs))
         (spec (assq config from-configs)))
    (unless spec
      (user-error "组 %s 没有配置 %s" source-name config))
    (unless same-group
      (when (assq config to-configs)
        (user-error "组 %s 已有配置 %s" target-name config)))
    (ebasecamp-config-write--check-project-conflict
     target-name to-configs project (if same-group config nil))
    (let ((overrides (plist-get (cdr spec) :services)))
      (append (list config :project project)
              (when overrides (list :services overrides))))))

(defun ebasecamp-config-write--restore-backup (file backup)
  "用 BACKUP 里的事务前原文恢复 FILE，删除备份并重新加载，返回加载结果。
这是跨文件移动的**补偿动作**（不在任何写盘事务内）：恢复失败时 signal
`ebasecamp-config-write-error'，消息给出备份路径并**保留备份**供手工恢复。
BACKUP 为 nil（第一段没写盘）时只重新加载。"
  (when backup
    (condition-case err
        (progn
          (ebasecamp-manifest--write-file
           file (ebasecamp-manifest--read-text backup))
          (ebasecamp-manifest--delete-file backup))
      (error
       (signal 'ebasecamp-config-write-error
               (list (format
                      "跨文件移动回滚失败（%s）：%s 的事务前备份保留在 %s，请手工恢复"
                      (error-message-string err) file backup)
                     file backup)))))
  (ebasecamp-config-load))

(defun ebasecamp-config-write--move-config-across-files
    (source-file target-file source target config project)
  "跨文件移动配置：**两次写盘事务 + 备份补偿**，不是单事务原子操作。
SOURCE-FILE / TARGET-FILE 分别是源组与目标组定义所在文件（由定位函数给出），
SOURCE / TARGET / CONFIG / PROJECT 均为符号。

步骤：先在内存里对两份原文做统一校验（拒绝条件全部在任何写盘动作之前抛出），
再 ① 源文件事务移除配置（`:keep-backup' 保留事务前备份）→ ② 目标文件事务追加
配置；② 失败（包括「写后新增加载错误」触发的自身回滚）时用 ① 的备份**恢复源
文件原文**并把原错误 signal 出去，因此磁盘上不会留下「源组已删、目标组没加」
的半截状态。两段都成功才删除两个备份，返回写后的加载结果。

对 ADR-0005 决策 2（单事务）的部分退化已记录在 ADR-0006：跨文件写盘没有跨文件
原子性可用，只能靠显式备份补偿。"
  (let* ((source-text (ebasecamp-manifest--read-text source-file))
         (target-text (ebasecamp-manifest--read-text target-file))
         (source-form (ebasecamp-config-write--require-group
                       source-file
                       (ebasecamp-manifest--scan-text-forms source-text source-file)
                       source))
         (target-form (ebasecamp-config-write--require-group
                       target-file
                       (ebasecamp-manifest--scan-text-forms target-text target-file)
                       target))
         (moved (ebasecamp-config-write--check-move
                 source (ebasecamp-config-write--form-plist source-text source-form)
                 target (ebasecamp-config-write--form-plist target-text target-form)
                 config project nil))
         (removal
          (lambda (text)
            (let* ((form (ebasecamp-config-write--require-group
                          source-file
                          (ebasecamp-manifest--scan-text-forms text source-file)
                          source))
                   (plist (ebasecamp-config-write--form-plist text form)))
              (ebasecamp-config-write--replace-group
               text form
               (ebasecamp-config-write--with-configs
                plist (assq-delete-all config (plist-get plist :configs)))))))
         (addition
          (lambda (text)
            (let* ((form (ebasecamp-config-write--require-group
                          target-file
                          (ebasecamp-manifest--scan-text-forms text target-file)
                          target))
                   (plist (ebasecamp-config-write--form-plist text form))
                   (configs (plist-get plist :configs)))
              (when (assq config configs)
                (user-error "组 %s 已有配置 %s" target config))
              (ebasecamp-config-write--replace-group
               text form
               (ebasecamp-config-write--with-configs
                plist (append configs (list moved)))))))
         (first (ebasecamp-manifest--write-transaction
                 source-file removal :keep-backup t))
         (source-backup (plist-get first :backup)))
    (condition-case err
        (let ((second (ebasecamp-manifest--write-transaction
                       target-file addition :keep-backup t)))
          (ebasecamp-manifest--delete-file (plist-get second :backup))
          (ebasecamp-manifest--delete-file source-backup)
          (plist-get second :result))
      (error
       (ebasecamp-config-write--restore-backup source-file source-backup)
       (signal (car err) (cdr err))))))

(defun ebasecamp-config-write--move-config-within-file
    (file source target config project)
  "在**同一个**清单 FILE 内移动配置：一次事务里完成源组移除与目标组追加。
SOURCE / TARGET / CONFIG / PROJECT 均为符号。实现要点：两处区段替换用
`ebasecamp-manifest--replace-forms'（按位置降序应用），因此写盘只有一次，
不存在「源组已删、目标组没加」的中间状态。返回写后的加载结果。"
  (ebasecamp-config-write--edit-manifest
   file
   (lambda (text forms file)
     (let* ((same-group (eq source target))
            (from-form (ebasecamp-config-write--require-group file forms source))
            (to-form (ebasecamp-config-write--require-group file forms target))
            (from-plist (ebasecamp-config-write--form-plist text from-form))
            (to-plist (if same-group
                          from-plist
                        (ebasecamp-config-write--form-plist text to-form)))
            (moved (ebasecamp-config-write--check-move
                    source from-plist target to-plist config project same-group))
            (remaining (assq-delete-all
                        config (plist-get from-plist :configs))))
       (if same-group
           (ebasecamp-config-write--replace-group
            text from-form
            (ebasecamp-config-write--with-configs
             from-plist (append remaining (list moved))))
         (ebasecamp-manifest--replace-forms
          text
          (list
           (cons from-form
                 (ebasecamp-config-write--render-group
                  text from-form
                  (ebasecamp-config-write--with-configs from-plist remaining)))
           (cons to-form
                 (ebasecamp-config-write--render-group
                  text to-form
                  (ebasecamp-config-write--with-configs
                   to-plist
                   (append (plist-get to-plist :configs) (list moved))))))))))))

(defun ebasecamp-config-write-move-config (from-group config-name to-group project)
  "把配置 CONFIG-NAME 从组 FROM-GROUP 移到组 TO-GROUP，并把 `:project' 设为
PROJECT（四个参数均可为符号或字符串）。

**定位**：源组与目标组各自按组名跨文件定位（`--manifest-file-for-group'）——
两个组可以都在 `groups.el'、都在 `projects/*.el'、或分处两个文件。

**原子性**：两段编辑在**同一份内存全文**里完成（两次区段替换按位置降序应用），
只经过一次写盘事务，因此同文件移动不存在「源组已删、目标组没加」的中间状态。
跨文件时没有跨文件原子性可用，改为**两次事务 + 备份补偿**
（`--move-config-across-files'）：第二段失败会用第一段的备份恢复源文件原文。
配置原有的 `:services' 覆盖随配置一起搬走（若目标组没有同名服务，写后加载会
报错并由事务回滚，不会留下半截数据）。

拒绝条件（`user-error'，都在写盘之前抛出）：源组/目标组不存在、同名组重复定义、
源组没有该配置、目标组已有同名配置、**D2 冲突**（目标组已有别的配置引用
PROJECT）。源组删掉最后一份配置后组仍保留（`:configs nil'）。成功返回写后的
加载结果。"
  (let* ((source (ebasecamp-config-write--symbol from-group "源组名"))
         (config (ebasecamp-config-write--symbol config-name "配置名"))
         (target (ebasecamp-config-write--symbol to-group "目标组名"))
         (project (ebasecamp-config-write--symbol project "项目名"))
         (source-file (ebasecamp-config-write--manifest-file-for-group source))
         (target-file (ebasecamp-config-write--manifest-file-for-group target)))
    (if (equal source-file target-file)
        (ebasecamp-config-write--move-config-within-file
         source-file source target config project)
      (ebasecamp-config-write--move-config-across-files
       source-file target-file source target config project))))

;;; 实体操作：实体名校验、错误差集与删除事务（项目 / 组 CRUD 共用）

(defun ebasecamp-config-write--entity-name (value context)
  "校验 VALUE 是合法的实体名（项目名 / 组名）并返回 symbol。
合法形态为 `[a-z0-9_-]+'（AGENTS 不变量 1：项目名与组名同一口径）。校验复用
`ebasecamp-import--normalize-name'，大小写与空格都不做容错；出错时统一转成本
模块口径的 `user-error'（写操作的拒绝条件只有一种条件类型，界面层好处理），
消息里用 CONTEXT（「项目名」/「组名」）指明是哪一类。"
  (condition-case nil
      (ebasecamp-import--normalize-name value)
    (ebasecamp-import-error
     (user-error "%s %S 非法：只允许小写字母、数字、下划线与连字符"
                 context value))))

(defun ebasecamp-config-write--check-scope (scope)
  "校验组的 SCOPE 属于 `shared' / `per-project'，返回 SCOPE。
取值集合复用模型层的 `ebasecamp-model--scopes'（唯一定义），不另立常量。"
  (unless (memq scope ebasecamp-model--scopes)
    (user-error "组 scope 必须是 shared 或 per-project，得到 %S" scope))
  scope)

(defun ebasecamp-config-write--check-new-errors (file old-errors result rollback)
  "比较 RESULT 与 OLD-ERRORS 的错误消息差集，有新增错误就 ROLLBACK 再 signal。
返回 RESULT。判据与写盘事务一致：只比较 `ebasecamp-config-error-messages' 的
消息文本，因此既有错误（含用户其它文件里与本次操作无关的错误）不会误触回滚。
ROLLBACK 是「撤掉本次新增 / 删除」的无参函数；它自己失败时 signal
`ebasecamp-config-write-error' 并在消息里说明需要人工介入。FILE 只用于消息。"
  (let ((added (cl-set-difference (ebasecamp-config-error-messages result)
                                  old-errors :test #'equal)))
    (if (null added)
        result
      (condition-case rollback-error
          (progn
            (funcall rollback)
            (ebasecamp-config-load)
            (signal 'ebasecamp-config-write-error
                    (list (format "写入 %s 后清单新增 %d 个错误，已回滚：%s"
                                  file (length added) (string-join added "；"))
                          file nil)))
        (ebasecamp-config-write-error
         (signal (car rollback-error) (cdr rollback-error)))
        (error
         (signal 'ebasecamp-config-write-error
                 (list (format
                        "%s 写后新增 %d 个错误且回滚失败（%s），请手工检查该文件。新增错误：%s"
                        file (length added)
                        (error-message-string rollback-error)
                        (string-join added "；"))
                       file nil)))))))

(defun ebasecamp-config-write--projects-directory ()
  "返回当前清单目录下 `projects/' 的绝对路径（以目录分隔符结尾）。"
  (expand-file-name "projects/" (ebasecamp-config--directory)))

(defun ebasecamp-config-write--check-project-path (file project)
  "校验 FILE 是项目 PROJECT 在 `projects/' 下的清单文件，返回其绝对路径。
不属于时 `user-error'。删除前必须确认（`ebasecamp-config-directory' 可被绑定到
任意目录，不能盲目相信拼接结果）：父目录等于当前清单目录的 `projects/'，且
文件名等于 `<PROJECT>.el'。"
  (let ((file (expand-file-name file)))
    (unless (and (equal (directory-file-name (file-name-directory file))
                        (directory-file-name
                         (ebasecamp-config-write--projects-directory)))
                 (equal (file-name-nondirectory file)
                        (concat (symbol-name project) ".el")))
      (user-error "拒绝删除清单目录之外的文件 %s" file))
    file))

(defun ebasecamp-config-write--delete-file-transaction (file project)
  "删除项目 PROJECT 的清单文件 FILE，返回删除后的加载结果。
步骤：校验路径归属（`--check-project-path'）→ 记录原文与权限位 → 删文件 →
重新加载 → **仅当出现删除前没有的新错误**时用一个普通文件写回原文并恢复权限位
（回滚），再 signal `ebasecamp-config-write-error'。符号链接直接拒绝：删除会
移除链接本身，而恢复会造出一个普通文件，两边的语义对不上。"
  (let ((file (ebasecamp-config-write--check-project-path file project)))
    (when (file-symlink-p file)
      (user-error "%s 是符号链接，拒绝删除" file))
    (let* ((original (ebasecamp-manifest--read-text file))
           (modes (file-modes file))
           (old-errors (ebasecamp-config-error-messages (ebasecamp-config-load))))
      (delete-file file)
      (ebasecamp-config-write--check-new-errors
       file old-errors (ebasecamp-config-load)
       (lambda ()
         (ebasecamp-manifest--write-file file original)
         (when modes (ignore-errors (set-file-modes file modes))))))))

;;; 实体操作：项目 CRUD

(defconst ebasecamp-config-write--project-output-keys
  '(:title :root :shared-network :export-file :file-configs :file-secrets
    :groups)
  "项目 form 的输出键顺序（与 `ebasecamp-model--project-keywords' 一致）。
`ebasecamp-manifest-project-form' 只服务导入（title 恒等于项目名、不写无关键），
项目 CRUD 需要保留 `:shared-network' / `:export-file' / `:file-configs' /
`:file-secrets' / 手写的 `:groups'，因此在这里单独渲染。`:groups' 只在该键原本
就存在时才写回（用户手写的旧写法），新增项目一律不写（AGENTS 不变量 9：项目对
组的引用由组侧 `:configs' 物化）。")

(defun ebasecamp-config-write--project-form (name plist)
  "把项目 NAME 与属性 PLIST 渲染为项目 form 的多行字符串（含结尾换行）。
键序固定为 title → root → shared-network → export-file → groups，缺省的键不写；
`:title' 缺省时回落项目名。值一律经 `ebasecamp-manifest--literal' 落盘，
`${VAR}' 引用与相对路径原样保留。"
  (let ((lines nil))
    (dolist (key ebasecamp-config-write--project-output-keys)
      (cond
       ((eq key :title)
        (push (format "  :title %s"
                      (ebasecamp-manifest--literal
                       (or (plist-get plist :title) (symbol-name name))))
              lines))
       ((eq key :root)
        (let ((root (plist-get plist :root)))
          (when root
            (push (format "  :root %s" (ebasecamp-manifest--literal root))
                  lines))))
       ((memq key '(:file-configs :file-secrets))
        ;; compose 顶层段的原样结构，只在非空时写（空值写出来是噪音）
        (let ((value (plist-get plist key)))
          (when value
            (push (format "  %s %s" key
                          (ebasecamp-manifest--literal value))
                  lines))))
       ((plist-member plist key)
        (push (format "  %s %s" key
                      (ebasecamp-manifest--literal (plist-get plist key)))
              lines))))
    (concat "(ebasecamp-define-project " (symbol-name name) "\n"
            (mapconcat #'identity (nreverse lines) "\n")
            ")\n")))

(defun ebasecamp-config-write--check-root (project root)
  "校验 ROOT 是项目 PROJECT 的根目录，返回 ROOT 去掉首尾空白后的结果。
**nil 是合法状态**（无根目录项目：不参与目录定位、不作路径基准、导出须显式选
路径，见 AGENTS 不变量 16），此时原样返回 nil（不参与 trim）。非 nil 时必须是
去掉首尾空白后仍非空的字符串——空串与纯空白仍拒绝，否则「键存在但值为空」会与
「键不存在」两种形态并存。

**返回值是 trim 后的路径，调用方应把它写回自己的 `root' 变量**（形如
`(setq root (ebasecamp-config-write--check-root project root))'），否则带空白的
原值会原样落盘。调用点必须保留 `(when root ...)' 外层判空：nil 分支不得进
trim，也不得因 trim 把 nil 变成空串。

清单只保存引用（相对路径可原样保留），因此只做形状检查：不解析、不展开 `~'、
不访问文件系统。"
  (unless (or (null root)
              (and (stringp root) (not (string-empty-p (string-trim root)))))
    (user-error "项目 %s 的根目录必须是非空字符串或 nil，得到 %S" project root))
  (when root (string-trim root)))

(defun ebasecamp-config-write--plist-remove (plist key)
  "返回从 PLIST 去掉 KEY 之后的**新** plist，其余键保持原有顺序。
不修改 PLIST 本身（`plist-remprop' 是破坏性操作，而调用方传入的 plist 可能被
后续逻辑复用）；KEY 不存在时返回与 PLIST 等值的新列表。用于清空 `:root'：
必须让键消失，不得写 `:root nil'（否则 `plist-member' 判定会失真）。"
  (let ((result nil)
        (rest plist))
    (while rest
      (unless (eq (car rest) key)
        (setq result (append result (list (car rest) (cadr rest)))))
      (setq rest (cddr rest)))
    result))

(defun ebasecamp-config-write-add-project (name title root)
  "新增项目 NAME（`:title' TITLE、`:root' ROOT），写 `projects/<NAME>.el'。
NAME 必须是合法实体名（`[a-z0-9_-]+'）；TITLE 省略时取项目名；ROOT 为 nil
表示**无根目录项目**（不写 `:root' 键：不参与目录定位、不作路径基准、导出须
显式选路径），非 nil 时必须是去空白后非空的字符串。文件已存在即 `user-error'
（新增不覆盖，改项目用 `ebasecamp-config-write-update-project'）。`projects/'
不存在时一并创建。

写盘方式：快照当前加载错误集 → `ebasecamp-manifest--write-new-file' 落盘 →
重新加载比较错误差集；出现新增错误时删除该文件并 signal
`ebasecamp-config-write-error'。新增项目没有「原文」，所以错误集快照在写**之前**。
成功返回写后的加载结果（`plist-get' 取 `:errors' 为 nil 表示无新增错误）。"
  (let* ((project (ebasecamp-config-write--entity-name name "项目名")))
    (when root
      ;; 回写 trim 后的值：后续落盘用的是这个变量，不回写就落原值
      (setq root (ebasecamp-config-write--check-root project root)))
    (when (and title (not (stringp title)))
      (user-error "项目 %s 的标题必须是字符串，得到 %S" project title))
    (let ((file (ebasecamp-config-project-file project)))
      (when (file-exists-p file)
        (user-error "项目 %s 已存在（文件 %s），改项目请用更新操作" project file))
      (let ((old-errors (ebasecamp-config-error-messages (ebasecamp-config-load))))
        (ebasecamp-manifest--write-new-file
         file (ebasecamp-config-write--project-form
               project (list :title title :root root)))
        (ebasecamp-config-write--check-new-errors
         file old-errors (ebasecamp-config-load)
         (lambda () (delete-file file)))))))

(defun ebasecamp-config-write-update-project (name title root &optional clear-root)
  "改项目 NAME 的 `:title' / `:root'，写回它的清单文件。
TITLE 与 ROOT 都为 nil 且 CLEAR-ROOT 为 nil 时不改这两个键（文件内容不变即
不写盘）；ROOT 给了就校验「非 nil 即非空字符串」。

CLEAR-ROOT 非 nil 表示**清空根目录**：从项目 plist 里真正移除 `:root' 键
（不是写 `:root nil'——键存在与键不存在必须可区分），使该项目变成无根目录
项目（不参与目录定位、不作路径基准、导出须显式选路径）。
CLEAR-ROOT 与 ROOT **互斥**：同时非 nil 即 `user-error'，不静默偏向任一方；
互斥校验与 `--check-root' 都在 `ebasecamp-manifest--write-transaction' **之前**，
因此参数错误不会产生任何写盘动作（连备份都不做）。

项目定义里的其它键（`:shared-network' / `:export-file' / 手写的 `:groups'）按
**原文 plist** 原样保留；文件之外（其它项目文件）逐字节不变，目标文件经
`ebasecamp-manifest--write-transaction' 事务写盘（备份 → 原子写 → 仅新增错误
才回滚 → 写前检测外部修改）。

拒绝条件（`user-error'）：项目名非法、TITLE 非字符串、ROOT 与 CLEAR-ROOT 同时
给出、ROOT 为空串 / 纯空白、文件不存在、文件里没有该项目 form。"
  (let* ((project (ebasecamp-config-write--entity-name name "项目名"))
         (file (ebasecamp-config-project-file project)))
    (when (and title (not (stringp title)))
      (user-error "项目 %s 的标题必须是字符串，得到 %S" project title))
    (when (and root clear-root)
      (user-error "项目 %s 的根目录参数互斥：ROOT 与 CLEAR-ROOT 不能同时给出（%S / %S）"
                  project root clear-root))
    (when root
      ;; 回写 trim 后的值：后续 `plist-put' 用的是这个变量。
      ;; clear-root 分支 root 为 nil（互斥校验已挡），不会进这里，也不受影响。
      (setq root (ebasecamp-config-write--check-root project root)))
    (unless (file-exists-p file)
      (user-error "没有项目 %s（文件 %s 不存在）" project file))
    (ebasecamp-manifest--write-transaction
     file
     (lambda (text)
       (let* ((form (or (ebasecamp-manifest--locate-form
                         'project project
                         (ebasecamp-manifest--scan-text-forms text file))
                        (user-error "文件 %s 里没有项目 %s 的定义" file project)))
              (plist (ebasecamp-config-write--form-plist text form))
              (updated plist))
         (when title
           (setq updated (plist-put (copy-sequence updated) :title title)))
         (when root
           (setq updated (plist-put (copy-sequence updated) :root root)))
         (when clear-root
           ;; 去掉键本身，而不是置 nil；`--plist-remove' 返回新列表
           (setq updated (ebasecamp-config-write--plist-remove updated :root)))
         (if (equal plist updated)
             text
           (ebasecamp-manifest--replace-form
            text form
            (ebasecamp-config-write--project-form project updated))))))))

(defun ebasecamp-config-write-remove-project (name)
  "删除项目 NAME 的清单文件 `projects/<NAME>.el'，返回删除后的加载结果。
**只删清单定义，不删容器**（容器需用 `D' 销毁）。

拒绝条件（`user-error'，都在删除之前）：
- 项目名非法 / 文件不存在；
- 仍被组的 `:configs' 引用（引用扫描见 `--config-references'，消息按
  「组/配置」逐条列出，例如 `alpha/dev'），否则删项目后这些配置会「引用未定义
  项目」而让整个清单加载报错。

删除走 `--delete-file-transaction'：删除后重新加载，出现新增错误时恢复文件与
权限位并 signal `ebasecamp-config-write-error'。"
  (let* ((project (ebasecamp-config-write--entity-name name "项目名"))
         (file (ebasecamp-config-project-file project))
         (references (ebasecamp-config-write--config-references project)))
    (when references
      (user-error
       "项目 %s 被以下组配置引用：%s；先删除这些配置或改其 :project 再删项目"
       project (mapconcat #'identity references "、")))
    (unless (file-exists-p file)
      (user-error "没有项目 %s（文件 %s 不存在）" project file))
    (ebasecamp-config-write--delete-file-transaction file project)))

;;; 实体操作：组 CRUD

(defun ebasecamp-config-write--legacy-group-references (group)
  "返回用项目侧**旧写法** `:groups' 引用组 GROUP 的项目名列表。
只读 `projects/*.el' 顶层的 `(ebasecamp-define-project NAME :groups
\((GROUP :scope …) …))'：新写法（组侧 `:configs' 加载期物化）不落在项目文件里，
因此这里只反映用户手写的引用。删除组前扫**这一处**——另一处是删除项目前扫
组侧 `:configs'（`--config-references'），两者不可混用。

读取原文而不看 model：model 可能因既有加载错误缺定义，而引用扫描必须看到
磁盘上的真实引用。项目名优先取 form 的名字，取不到时回落文件名。"
  (let ((names nil))
    (dolist (file (ebasecamp-config--project-files))
      (let ((text (ebasecamp-manifest--read-text file)))
        (dolist (form (ebasecamp-manifest--scan-text-forms text file))
          (when (eq 'project (plist-get form :kind))
            (let* ((object (read (substring text
                                            (1- (plist-get form :start))
                                            (1- (plist-get form :end)))))
                   (references (plist-get (cddr object) :groups)))
              (when (cl-find group references :key #'car-safe :test #'eq)
                (push (format "%s" (or (plist-get form :name)
                                       (file-name-sans-extension
                                        (file-name-nondirectory file))))
                      names)))))))
    (nreverse names)))

(defun ebasecamp-config-write--config-references (project)
  "返回把 PROJECT 写进组侧 `:configs' 的「组/配置」字符串列表。
遍历清单里**所有含组 form 的文件**（`groups.el' 与 `projects/*.el' 都算）：
组可以定义在任一清单文件里（导入层就把组写进项目文件），只扫 `groups.el' 会漏
引用，从而让删除项目跳过检查、删完让整个清单加载报错。顺序为文件加载顺序、
组定义顺序、组内配置顺序；没有任何组文件时返回 nil。

与 `--manifest-file-for-group' 的差别：这里**故意允许多命中**（同名组重复定义
时仍要全覆盖扫描），所以复用 `--group-files' 的收集逻辑而不做唯一性裁决。
读取原文而不看 model（理由同 `--legacy-group-references'），因此即使清单当前
有加载错误也能准确判断引用关系。"
  (let ((references nil))
    (dolist (file (ebasecamp-config-write--group-manifest-files))
      (let ((text (ebasecamp-manifest--read-text file)))
        (dolist (form (ebasecamp-manifest--scan-text-forms text file))
          (when (eq 'group (plist-get form :kind))
            (dolist (spec (plist-get (ebasecamp-config-write--form-plist text form)
                                     :configs))
              (when (eq project (plist-get (cdr-safe spec) :project))
                (push (format "%s/%s" (plist-get form :name) (car-safe spec))
                      references)))))))
    (nreverse references)))

(defun ebasecamp-config-write-add-group (name title scope)
  "向 groups.el 追加组 NAME（`:title' TITLE、`:scope' SCOPE），返回加载结果。
TITLE 省略时取组名；SCOPE 省略时取 `per-project'，只接受 `shared' /
`per-project'。新组不带服务与配置（`:services nil' / `:configs nil'），需要
服务请用导入流程或手工编辑。

新增的落盘位置固定是 `groups.el'（新组不往项目文件里塞）：不存在（全新清单）
时连同目录一起新建；存在时追加到文件末尾并在前面补一个空行，原有 form、注释
与结尾换行都保留。**拒绝条件（`user-error'）**：名字非法、scope 非法、清单里
（任意文件）已有同名组——查重扫全清单，否则在 `projects/*.el' 里已定义该组的
情况下会造出同名组，加载层对重复组名报错并回滚后加载文件，同文件的项目一起从
界面消失。"
  (let* ((group (ebasecamp-config-write--entity-name name "组名"))
         (scope (ebasecamp-config-write--check-scope (or scope 'per-project)))
         (file (ebasecamp-config-write--groups-file))
         (form (ebasecamp-manifest-group-form-from-plist
                group (list :title (or title (symbol-name group))
                            :scope scope))))
    (when (and title (not (stringp title)))
      (user-error "组 %s 的标题必须是字符串，得到 %S" group title))
    ;; 写前查重必须扫**全清单**：组可能已定义在 `projects/*.el'（导入的落盘
    ;; 形态），只看 groups.el 会造出同名组——加载层对重复组名报错并回滚后加载
    ;; 文件，同文件的项目一起从界面消失。
    (let ((existing (ebasecamp-config-write--group-files group)))
      (when existing
        (user-error "清单里已有组 %s（定义在 %s）；改组请用更新操作"
                    group (mapconcat #'identity existing "、"))))
    (if (file-exists-p file)
        (ebasecamp-config-write--edit-manifest
         file
         (lambda (text forms file)
           (when (ebasecamp-manifest--locate-form 'group group forms)
             (user-error "清单 %s 里已有组 %s" file group))
           (ebasecamp-manifest--append-form text (concat "\n" form))))
      (let ((old-errors (ebasecamp-config-error-messages (ebasecamp-config-load))))
        (ebasecamp-manifest--write-new-file
         file (concat ";;; -*- lexical-binding: t; -*-\n\n" form))
        (ebasecamp-config-write--check-new-errors
         file old-errors (ebasecamp-config-load)
         (lambda () (delete-file file)))))))

(defun ebasecamp-config-write-update-group (name title scope)
  "改组 NAME 的 `:title' / `:scope'（`per-project' ↔ `shared'），返回加载结果。
两个参数可只给一个；都为 nil 时**不写盘**（避免只为规范化排版而改动文件）。
组内的 `:services' 与 `:configs' 按**原文 plist** 保留。

改 scope 的语义影响由调用方（界面层）二次确认：`shared' 组至多 1 份配置，
且多份配置的 `shared' 组会让加载报错——这里不额外前置拦截，冲突交给写盘事务
兜底（写后出现「shared 组 X 至多 1 份配置」这类新错误即回滚，错误消息本身可
直接展示给用户）。拒绝条件：组名非法、scope 非法、清单里没有该组（或同名组在
多个文件中重复定义——定位函数会拒绝并列出文件）。"
  (let* ((group (ebasecamp-config-write--entity-name name "组名"))
         (scope (and scope (ebasecamp-config-write--check-scope scope))))
    (when (and title (not (stringp title)))
      (user-error "组 %s 的标题必须是字符串，得到 %S" group title))
    (ebasecamp-config-write--edit-manifest
     (ebasecamp-config-write--manifest-file-for-group group)
     (lambda (text forms file)
       (let* ((form (ebasecamp-config-write--require-group file forms group))
              (plist (ebasecamp-config-write--form-plist text form))
              (updated plist))
         (when title
           (setq updated (plist-put (copy-sequence updated) :title title)))
         (when scope
           (setq updated (plist-put (copy-sequence updated) :scope scope)))
         (if (equal plist updated)
             text
           (ebasecamp-config-write--replace-group text form updated)))))))

(defun ebasecamp-config-write-remove-group (name)
  "从组定义所在文件删除组 NAME 的定义，返回加载结果。
**只删清单定义，不删容器**（容器需用 `D' 销毁）；该组内的配置随组一起消失。

拒绝条件（`user-error'，删除之前）：组名非法 / 清单里没有该组（或同名组在多个
文件中重复定义）；以及**项目侧旧写法 `:groups' 仍引用该组**——扫描见
`--legacy-group-references'，消息按项目名列出让用户先清掉手写引用，否则删组后
这些项目会「引用未定义的组」而让清单加载报错。

写盘走 `ebasecamp-config-write--edit-manifest' 的写盘事务
（`ebasecamp-manifest--remove-form' 删除该 form 及它的独占空行，其它组与注释
逐字节保留）。"
  (let* ((group (ebasecamp-config-write--entity-name name "组名"))
         (file (ebasecamp-config-write--manifest-file-for-group group))
         (referencing (ebasecamp-config-write--legacy-group-references group)))
    (when referencing
      (user-error
       "组 %s 被以下项目的旧写法 :groups 引用：%s；先删掉项目里的引用再删组"
       group (mapconcat #'identity referencing "、")))
    (ebasecamp-config-write--edit-manifest
     file
     (lambda (text forms file)
       (ebasecamp-manifest--remove-form
        text (ebasecamp-config-write--require-group file forms group))))))

(provide 'ebasecamp-config-write)
;;; ebasecamp-config-write.el ends here
