;;; ebasecamp-config-write-tests.el --- 清单字段映射与实体操作测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; W2.1 / W2.2 的 ERT 测试：服务字段的双向文本映射（纯函数层，无 IO）。
;;
;; W3.1 起追加实体操作测试（真实临时清单目录 + 写盘事务）：
;; - `ebasecamp-config-write-update-service-fields'：只覆盖被编辑的键，其余
;;   键按**原文 plist** 保值（含 `:healthcheck' / `:extra' 嵌套结构），服务子
;;   form 之外的字节逐字节不变；字段值未改动时不写盘；
;; - `-add-config' / `-update-config-project' / `-remove-config'：组内配置
;;   增改删 + D2 冲突（同一项目同一组只允许 1 个引用）；
;; - `-move-config'：一次事务内「源组移除 + 目标组追加」，失败时两个组都保持
;;   原样（无部分写入）。
;;
;; W3.3 起追加项目与组的 CRUD 测试（同一个临时清单目录脚手架）：
;; - `-add-project' / `-update-project'：新增 `projects/<name>.el`（已存在即拒），
;;   改 `:title' / `:root' 时保留 `:shared-network' / `:export-file' 等无关键，
;;   其它项目文件逐字节不变；
;; - `-remove-project'：被组侧 `:configs' 引用时拒绝并列出「组/配置」；未被引用
;;   时删除文件且无新增加载错误；
;; - `-add-group' / `-update-group'：向 groups.el 追加 / 改写组 form（改
;;   `:title' / `:scope' 的 `per-project' ↔ `shared'），兄弟组字节不变；
;; - `-remove-group'：被项目侧旧写法 `:groups' 引用时拒绝并列出项目名。
;;   **两处引用扫描的归属不可混用**：删项目扫组侧 `:configs'，删组扫项目侧旧
;;   `:groups'。
;;
;; W2 覆盖六个字段（字段映射，纯函数层）：
;; - `ports'：`((PUBLISHED . TARGET))' ↔ 每行 `HOST:CONTAINER'（单段 `N' 视为
;;   `((N . N))'，但 `to-text' 恒写 `HOST:CONTAINER' 不折叠）；
;; - `environment'：`((KEY . VALUE))' ↔ 每行 `KEY=VALUE'（首个 `=' 切分）；
;; - `volumes'：plist 列表 ↔ 每行 `SRC:DST[:ro]'（单段 = 具名卷挂载）；
;; - `command'：字符串列表 ↔ 每行一个参数（无换行时按空白切分）；
;; - `restart'：字符串 ↔ 原样文本（枚举 + 自定义 free-form）；
;; - `image'：单行非空。
;;
;; 非法输入一律 `user-error'，消息以「第 N 行：」开头（行号 1-based，空行不计）。

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ebasecamp-model)
(require 'ebasecamp-config)
(require 'ebasecamp-config-write)

;;; 脚手架

(defun ebasecamp-config-write-test--error-message (function)
  "调用 FUNCTION，断言其触发 `user-error'，返回错误消息字符串。"
  (let (message)
    (condition-case err
        (funcall function)
      (user-error (setq message (error-message-string err))))
    (unless message
      (ert-fail "期望触发 user-error，但没有报错"))
    message))

(defun ebasecamp-config-write-test--line-error (function line)
  "断言 FUNCTION 触发带「第 LINE 行：」前缀的 `user-error'，返回消息。"
  (let ((message (ebasecamp-config-write-test--error-message function)))
    (unless (string-prefix-p (format "第 %d 行：" line) message)
      (ert-fail (format "期望错误消息以「第 %d 行：」开头，实际为 %S"
                        line message)))
    message))

;;; 1. ports

(ert-deftest ebasecamp-config-write-test-ports-roundtrip ()
  "ports 文本 ↔ `((PUBLISHED . TARGET))' 往返；非法行报行号。"
  ;; 单行往返
  (should (equal (ebasecamp-config-write-ports-to-text '((8080 . 80)))
                 "8080:80"))
  (should (equal (ebasecamp-config-write-text-to-ports "8080:80")
                 '((8080 . 80))))
  ;; 多行往返
  (should (equal (ebasecamp-config-write-ports-to-text
                  '((8080 . 80) (3307 . 3306)))
                 "8080:80\n3307:3306"))
  (should (equal (ebasecamp-config-write-text-to-ports "8080:80\n3307:3306")
                 '((8080 . 80) (3307 . 3306))))
  ;; 空值
  (should (equal (ebasecamp-config-write-ports-to-text nil) ""))
  (should (equal (ebasecamp-config-write-text-to-ports "") nil))
  ;; HOST == TARGET 时也写两段（不折叠），往返稳定
  (should (equal (ebasecamp-config-write-ports-to-text '((80 . 80))) "80:80"))
  (should (equal (ebasecamp-config-write-text-to-ports "80:80") '((80 . 80))))
  ;; 单段输入 = 仅容器端口 → ((N . N))
  (should (equal (ebasecamp-config-write-text-to-ports "80") '((80 . 80))))
  ;; 空行与行首尾空白忽略
  (should (equal (ebasecamp-config-write-text-to-ports "\n8080:80\n\n 3307:3306 \n")
                 '((8080 . 80) (3307 . 3306))))
  ;; 非法输入：非数字 / 负号 / 缺一段 / 多冒号
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-ports "8080:80\nabc")) 2)
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-ports "-1:80")) 1)
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-ports "8080:")) 1)
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-ports ":80")) 1)
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-ports "1:2:3")) 1)
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-ports "8080:8o80")) 1))

;;; 2. environment

(ert-deftest ebasecamp-config-write-test-environment-roundtrip ()
  "environment 文本 ↔ 字符串 alist 往返；`${VAR}' 原样保留；非法行报行号。"
  (should (equal (ebasecamp-config-write-environment-to-text
                  '(("A" . "1") ("B" . "${X}")))
                 "A=1\nB=${X}"))
  (should (equal (ebasecamp-config-write-text-to-environment "A=1\nB=${X}")
                 '(("A" . "1") ("B" . "${X}"))))
  ;; 空值合法
  (should (equal (ebasecamp-config-write-text-to-environment "A=")
                 '(("A" . ""))))
  ;; 值里含 `=' 时按首个 `=' 切分
  (should (equal (ebasecamp-config-write-text-to-environment "A=--opt=1")
                 '(("A" . "--opt=1"))))
  ;; 空文本与空行
  (should (equal (ebasecamp-config-write-environment-to-text nil) ""))
  (should (equal (ebasecamp-config-write-text-to-environment "") nil))
  (should (equal (ebasecamp-config-write-text-to-environment "A=1\n\nB=2\n")
                 '(("A" . "1") ("B" . "2"))))
  ;; 非法：缺 `=' / 空键 / 重复键（报第二处行号）
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-environment "A=1\nBROKEN")) 2)
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-environment "=1")) 1)
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-environment "A=1\nA=2")) 2))

;;; 3. volumes

(ert-deftest ebasecamp-config-write-test-volumes-roundtrip ()
  "volumes 文本 ↔ plist 列表往返（bind / 具名卷 / 单段）；非法行报行号。"
  ;; bind + ro
  (should (equal (ebasecamp-config-write-volumes-to-text
                  '((:source "./data" :target "/var/lib/mysql" :type bind
                             :read-only t)))
                 "./data:/var/lib/mysql:ro"))
  (should (equal (ebasecamp-config-write-text-to-volumes
                  "./data:/var/lib/mysql:ro")
                 '((:source "./data" :target "/var/lib/mysql" :type bind
                            :read-only t))))
  ;; 命名卷（不以 `.` / `/` 开头）
  (should (equal (ebasecamp-config-write-volumes-to-text
                  '((:source "data" :target "/x" :type volume)))
                 "data:/x"))
  (should (equal (ebasecamp-config-write-text-to-volumes "data:/x")
                 '((:source "data" :target "/x" :type volume))))
  ;; 绝对路径源 → bind
  (should (equal (ebasecamp-config-write-text-to-volumes "/host/conf:/etc/conf")
                 '((:source "/host/conf" :target "/etc/conf" :type bind))))
  ;; 单段 → 只挂容器路径（匿名卷）
  (should (equal (ebasecamp-config-write-volumes-to-text
                  '((:target "/x" :type volume)))
                 "/x"))
  (should (equal (ebasecamp-config-write-text-to-volumes "/x")
                 '((:target "/x" :type volume))))
  ;; 多行 + 空行
  (should (equal (ebasecamp-config-write-volumes-to-text
                  '((:target "/x" :type volume)
                    (:source "./data" :target "/var/lib/mysql" :type bind)))
                 "/x\n./data:/var/lib/mysql"))
  (should (equal (ebasecamp-config-write-text-to-volumes
                  "/x\n\n./data:/var/lib/mysql\n")
                 '((:target "/x" :type volume)
                   (:source "./data" :target "/var/lib/mysql" :type bind))))
  ;; 空值
  (should (equal (ebasecamp-config-write-volumes-to-text nil) ""))
  (should (equal (ebasecamp-config-write-text-to-volumes "") nil))
  ;; 非法：多冒号（不支持第四段）/ 空段 / 未知第三段
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-volumes "a:b:c:d")) 1)
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-volumes "./data:/var/lib/mysql:ro\n:/x")) 2)
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-volumes "data:")) 1)
  (ebasecamp-config-write-test--line-error
   (lambda () (ebasecamp-config-write-text-to-volumes "data:/x:rw")) 1))

;;; 4. command

(ert-deftest ebasecamp-config-write-test-command-roundtrip ()
  "command 多行文本 ↔ 字符串列表；空行忽略；无换行时按空白切分。"
  (should (equal (ebasecamp-config-write-command-to-text
                  '("mysqld" "--defaults-file=/a b"))
                 "mysqld\n--defaults-file=/a b"))
  (should (equal (ebasecamp-config-write-text-to-command
                  "mysqld\n--defaults-file=/a b")
                 '("mysqld" "--defaults-file=/a b")))
  ;; 空行（含只有空白的行）忽略，尾随换行容忍
  (should (equal (ebasecamp-config-write-text-to-command
                  "mysqld\n\n   \n--x=1\n")
                 '("mysqld" "--x=1")))
  ;; 无换行 → 按空白切分
  (should (equal (ebasecamp-config-write-text-to-command "mysqld --x=1")
                 '("mysqld" "--x=1")))
  (should (equal (ebasecamp-config-write-text-to-command "  mysqld  ")
                 '("mysqld")))
  ;; 空值
  (should (equal (ebasecamp-config-write-command-to-text nil) ""))
  (should (equal (ebasecamp-config-write-text-to-command "") nil))
  (should (equal (ebasecamp-config-write-text-to-command "\n \n") nil)))

;;; 5. restart

(ert-deftest ebasecamp-config-write-test-restart-roundtrip ()
  "restart 四个枚举值往返；非枚举 free-form 原值往返不报错。"
  (dolist (value '("no" "always" "on-failure" "unless-stopped"))
    (should (equal (ebasecamp-config-write-restart-to-text value) value))
    (should (equal (ebasecamp-config-write-text-to-restart value) value))
    (should (ebasecamp-config-write-restart-enum-p value)))
  ;; 自定义值（compose 的 free-form 形态）
  (should (equal (ebasecamp-config-write-restart-to-text "on-failure:5")
                 "on-failure:5"))
  (should (equal (ebasecamp-config-write-text-to-restart "on-failure:5")
                 "on-failure:5"))
  (should-not (ebasecamp-config-write-restart-enum-p "on-failure:5"))
  ;; 空白容忍与空值
  (should (equal (ebasecamp-config-write-text-to-restart "  always  ") "always"))
  (should (equal (ebasecamp-config-write-text-to-restart "") nil))
  (should (equal (ebasecamp-config-write-restart-to-text nil) "")))

;;; 6. image

(ert-deftest ebasecamp-config-write-test-image-required ()
  "image 必填：合法值去首尾空白；空串 / 空白 / nil 报 `user-error'。"
  (should (equal (ebasecamp-config-write-text-to-image "mysql:8") "mysql:8"))
  (should (equal (ebasecamp-config-write-text-to-image "  mysql:8.4  ")
                 "mysql:8.4"))
  (dolist (bad (list "" "   " "\n\t" nil))
    (let ((message (ebasecamp-config-write-test--error-message
                    (lambda () (ebasecamp-config-write-text-to-image bad)))))
      (unless (string-match-p "不能为空" message)
        (ert-fail (format "期望消息含「不能为空」，实际为 %S" message))))))

;;; 7. `${VAR}' 与相对路径保真

(ert-deftest ebasecamp-config-write-test-values-preserve-var-refs ()
  "environment / volumes 中的 `${VAR}' 引用与相对路径往返后逐字节不变。"
  (let ((environment '(("DB_HOST" . "${MYSQL_HOST}")
                       ("URL" . "http://${H}:${P}/x")
                       ("EMPTY" . "")))
        (volumes '((:source "./data/${SUB}" :target "/var/lib/${NAME}"
                            :type bind :read-only t)
                   (:source "../conf" :target "/etc/conf" :type bind))))
    (should (equal (ebasecamp-config-write-environment-to-text environment)
                   "DB_HOST=${MYSQL_HOST}\nURL=http://${H}:${P}/x\nEMPTY="))
    (should (equal (ebasecamp-config-write-text-to-environment
                    (ebasecamp-config-write-environment-to-text environment))
                   environment))
    (should (equal (ebasecamp-config-write-volumes-to-text volumes)
                   "./data/${SUB}:/var/lib/${NAME}:ro\n../conf:/etc/conf"))
    (should (equal (ebasecamp-config-write-text-to-volumes
                    (ebasecamp-config-write-volumes-to-text volumes))
                   volumes))))

;;; W3 实体操作：临时清单目录脚手架

(defvar ebasecamp-config-write-test--directory nil
  "当前测试使用的临时清单目录（无尾斜杠）。
由 `ebasecamp-config-write-test--with-directory' 动态绑定。")

(defconst ebasecamp-config-write-test--service-groups
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; groups.el --- W3 服务字段更新测试清单\n"
   "\n"
   ";; alpha 组：db 服务带 6 个可编辑键之外的字段（healthcheck / extra）\n"
   "(ebasecamp-define-group alpha\n"
   "  :title \"alpha\"\n"
   "  :scope per-project\n"
   "  :services\n"
   "  ((web :image \"nginx:1.27\"\n"
   "        :ports ((8080 . 80)))\n"
   "   (db :image \"mysql:8\"\n"
   "       :ports ((3307 . 3306))\n"
   "       :environment ((\"MYSQL_DATABASE\" . \"app\"))\n"
   "       :healthcheck (:test (\"CMD\" \"mysqladmin\" \"ping\") :interval \"10s\")\n"
   "       :restart \"always\"\n"
   "       :extra ((mem-limit . \"512m\")\n"
   "               (log-opts . ((\"max-size\" . \"10m\"))))))\n"
   "  :configs ((alpha :project app)))\n"
   "\n"
   ";; beta 组在 alpha 之后：服务字段更新不应影响它\n"
   "(ebasecamp-define-group beta\n"
   "  :title \"beta\"\n"
   "  :scope per-project\n"
   "  :services ((dev :image \"ubuntu:24.04\"))\n"
   "  :configs ((be :project b)))\n")
  "服务字段更新测试用的 groups.el（两个组，db 服务带未编辑字段）。")

(defconst ebasecamp-config-write-test--config-groups
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; groups.el --- W3 配置 CRUD 测试清单\n"
   "\n"
   "(ebasecamp-define-group alpha\n"
   "  :title \"alpha\"\n"
   "  :scope per-project\n"
   "  :services ((db :image \"mysql:8\"))\n"
   "  :configs ((dev :project a)\n"
   "            (other :project c)))\n"
   "\n"
   "(ebasecamp-define-group beta\n"
   "  :title \"beta\"\n"
   "  :scope per-project\n"
   "  :services ((web :image \"nginx:1.27\"))\n"
   "  :configs ((be :project b)))\n")
  "配置 CRUD / 移动测试用的 groups.el（alpha 两份配置、beta 一份配置）。")

(defconst ebasecamp-config-write-test--projects
  '(("app" . "/tmp/ebc-app")
    ("a" . "/tmp/ebc-a")
    ("b" . "/tmp/ebc-b")
    ("b2" . "/tmp/ebc-b2")
    ("c" . "/tmp/ebc-c")
    ("myapp" . "/tmp/ebc-myapp"))
  "测试清单里可用的项目（名字 . root）。")

(defmacro ebasecamp-config-write-test--with-directory (&rest body)
  "在临时清单目录中执行 BODY。
BODY 内 `ebasecamp-config-directory' 指向该临时目录，
`ebasecamp-config-write-test--directory' 保存同一路径（无尾斜杠）。"
  (declare (indent 0) (debug t))
  `(let* ((ebasecamp-config-write-test--directory
           (make-temp-file "ebc-config-write-" t))
          (ebasecamp-config-directory
           (file-name-as-directory ebasecamp-config-write-test--directory)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors
         (delete-directory ebasecamp-config-write-test--directory t)))))

(defun ebasecamp-config-write-test--write-flat (file text)
  "把 TEXT 覆盖写入 FILE。"
  (with-temp-file file (insert text)))

(defun ebasecamp-config-write-test--read (file)
  "读取 FILE 全文并返回字符串。"
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun ebasecamp-config-write-test--groups-file ()
  "返回当前临时清单目录里 `groups.el' 的绝对路径。"
  (expand-file-name "groups.el" ebasecamp-config-write-test--directory))

(defun ebasecamp-config-write-test--write-manifest (groups-text)
  "写入 GROUPS-TEXT 与 `--projects' 里的全部项目文件。"
  (ebasecamp-config-write-test--write-flat
   (ebasecamp-config-write-test--groups-file) groups-text)
  (make-directory
   (expand-file-name "projects/" ebasecamp-config-write-test--directory) t)
  (dolist (project ebasecamp-config-write-test--projects)
    (ebasecamp-config-write-test--write-flat
     (expand-file-name (concat "projects/" (car project) ".el")
                       ebasecamp-config-write-test--directory)
     (concat ";;; -*- lexical-binding: t; -*-\n"
             "(ebasecamp-define-project " (car project) "\n"
             "  :title \"" (car project) "\"\n"
             "  :root \"" (cdr project) "\")\n"))))

(defun ebasecamp-config-write-test--hash (file)
  "返回 FILE 内容的 sha256。"
  (secure-hash 'sha256 (ebasecamp-config-write-test--read file)))

(defun ebasecamp-config-write-test--mtime (file)
  "返回 FILE 的 mtime。"
  (file-attribute-modification-time (file-attributes file)))

(defun ebasecamp-config-write-test--leftovers ()
  "返回当前临时清单目录里遗留的备份 / 写盘临时文件名列表。"
  (directory-files ebasecamp-config-write-test--directory nil "\\`\\.ebasecamp-"))

(defun ebasecamp-config-write-test--read-form-at (text marker)
  "从 TEXT 中 MARKER 处 `read' 一个 form 并返回该 form。
MARKER 是 form 开头的唯一片段（例如 `(db'）；找不到时 `ert-fail'。
按原文 `read'，因此断言的是真实落盘内容而非写盘实现的中间产物。"
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (unless (search-forward marker nil t)
      (ert-fail (format "在文本里找不到标记 %S" marker)))
    (goto-char (match-beginning 0))
    (read (current-buffer))))

(defun ebasecamp-config-write-test--read-service (text marker)
  "从 TEXT 中 MARKER 处 `read' 服务子 form，返回其属性 plist。
服务子 form 形如 (SERVICE :KEY VALUE ...)，因此属性 plist 是 `(cdr FORM)'。"
  (cdr (ebasecamp-config-write-test--read-form-at text marker)))

(defun ebasecamp-config-write-test--read-group (text marker)
  "从 TEXT 中 MARKER 处 `read' 组 form，返回其属性 plist。
组 form 形如 (ebasecamp-define-group NAME :KEY VALUE ...)，因此属性 plist 是
`(cddr FORM)'。"
  (cddr (ebasecamp-config-write-test--read-form-at text marker)))

(defun ebasecamp-config-write-test--configs-of (group-name)
  "返回清单加载后组 GROUP-NAME 的配置名列表。"
  (mapcar #'car (ebasecamp-model-group-configs group-name)))

(defun ebasecamp-config-write-test--error-matching (function pattern)
  "断言 FUNCTION 触发消息匹配 PATTERN 的 `user-error'，返回该消息。"
  (let ((message (ebasecamp-config-write-test--error-message function)))
    (unless (string-match-p pattern message)
      (ert-fail (format "期望错误消息匹配 %S，实际为 %S" pattern message)))
    message))

;;; W3.1-1 服务字段更新：只改被编辑键，其余键按原文保值

(ert-deftest ebasecamp-config-write-test-update-service-fields ()
  "更新 :ports 与 :restart：其余键值保真，服务子 form 之外的字节不变。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--service-groups)
    (let* ((file (ebasecamp-config-write-test--groups-file))
           (before (ebasecamp-config-write-test--read file))
           ;; 服务子 form 之前的全部字节（含 web 服务、组头、行注释）
           (prefix (substring before 0 (string-match-p "(db" before)))
           ;; 服务子 form 之后的全部字节（组 :configs、beta 组、注释）
           (tail-marker ":configs ((alpha :project app)))")
           (suffix (substring before (string-match-p tail-marker before)))
           (result (ebasecamp-config-write-update-service-fields
                    'alpha 'db
                    '(:ports ((9090 . 90)) :restart "unless-stopped")))
           (after (ebasecamp-config-write-test--read file))
           (before-db (ebasecamp-config-write-test--read-service
                       before "(db"))
           (after-db (ebasecamp-config-write-test--read-service
                      after "(db")))
      ;; 写盘未引入加载错误
      (should (null (plist-get result :errors)))
      ;; 被编辑的两个键为新值
      (should (equal '((9090 . 90)) (plist-get after-db :ports)))
      (should (equal "unless-stopped" (plist-get after-db :restart)))
      ;; 未编辑键的值与原文一致（含 :extra 的嵌套结构）
      (dolist (key '(:image :environment :healthcheck :extra))
        (should (equal (plist-get before-db key) (plist-get after-db key))))
      (should (equal '((mem-limit . "512m") (log-opts . (("max-size" . "10m"))))
                     (plist-get after-db :extra)))
      ;; 未编辑键没有被静默丢弃（键集合不变）
      (let ((keys (lambda (plist)
                    (let ((rest plist) (acc nil))
                      (while rest
                        (push (car rest) acc)
                        (setq rest (cddr rest)))
                      (sort acc (lambda (a b) (string< (symbol-name a)
                                                       (symbol-name b))))))))
        (should (equal (funcall keys before-db) (funcall keys after-db))))
      ;; 服务子 form 之外的字节逐字节不变
      (should (string-prefix-p prefix after))
      (should (string-suffix-p suffix after))
      ;; 组 alpha 的配置未被波及
      (ebasecamp-config-load)
      (should (equal '((alpha :project app))
                     (mapcar #'identity (ebasecamp-model-group-configs 'alpha)))))))

;;; W3.1-2 服务字段更新：值未改动 => 不写盘

(ert-deftest ebasecamp-config-write-test-update-service-unchanged-skips ()
  "表单值与原值完全相同 → 不写盘（sha256 与 mtime 都不变）。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--service-groups)
    (let* ((file (ebasecamp-config-write-test--groups-file))
           (hash (ebasecamp-config-write-test--hash file))
           (mtime (ebasecamp-config-write-test--mtime file)))
      (ebasecamp-config-write-update-service-fields
       'alpha 'db '(:ports ((3307 . 3306)) :restart "always"))
      (should (equal hash (ebasecamp-config-write-test--hash file)))
      (should (equal mtime (ebasecamp-config-write-test--mtime file)))
      (should-not (ebasecamp-config-write-test--leftovers)))))

;;; W3.1-3 新增配置（含 D2 冲突拒绝）

(ert-deftest ebasecamp-config-write-test-add-config ()
  "给组追加 (dev :project myapp)：加载无新增错误、model 里出现该配置；
目标组已有同项目引用时 `user-error'（消息含项目名与组名）。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    ;; D2 冲突：组 alpha 已有配置 other 引用项目 c
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-add-config 'alpha 'second 'c))
     "项目 c.*组 alpha")
    ;; 配置名重复：组 alpha 已有 dev
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-add-config 'alpha 'dev 'myapp))
     "已有配置 dev")
    ;; 组不存在
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-add-config 'ghost 'second 'myapp))
     "没有组 ghost")
    ;; 成功路径
    (let ((result (ebasecamp-config-write-add-config 'alpha 'second 'myapp)))
      (should (null (plist-get result :errors)))
      (should (equal '(dev other second)
                     (ebasecamp-config-write-test--configs-of 'alpha)))
      (should (eq 'myapp (ebasecamp-model-config-project
                          (ebasecamp-model-config 'alpha 'second))))
      ;; 落盘文本可被 read 回新配置，且原配置仍在
      (let ((plist (ebasecamp-config-write-test--read-group
                    (ebasecamp-config-write-test--read
                     (ebasecamp-config-write-test--groups-file))
                    "(ebasecamp-define-group alpha")))
        (should (equal '((dev :project a)
                         (other :project c)
                         (second :project myapp))
                       (plist-get plist :configs))))
      ;; 兄弟组与文件头必须逐字节保留：写盘事务拿到的必须是「整份新全文」，
      ;; 而不是只渲染了目标组的那一段（W3.3 回归断言，见 `--replace-group'）
      (let ((text (ebasecamp-config-write-test--read
                   (ebasecamp-config-write-test--groups-file))))
        (should (string-prefix-p ";;; -*- lexical-binding: t; -*-" text))
        (should (string-match-p "(ebasecamp-define-group beta" text))
        (should (equal '((be :project b))
                       (plist-get (ebasecamp-config-write-test--read-group
                                   text "(ebasecamp-define-group beta")
                                  :configs)))))))

;;; W3.1-4 改配置 :project 与删除配置

(ert-deftest ebasecamp-config-write-test-update-and-remove-config ()
  "改配置 :project（同组已有同项目引用则拒绝）；删除配置后组仍存在。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    ;; 冲突：组 alpha 的 other 已引用项目 c
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-update-config-project 'alpha 'dev 'c))
     "项目 c.*组 alpha")
    ;; 配置不存在
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-update-config-project 'alpha 'ghost 'b))
     "没有配置 ghost")
    ;; 成功改 project：dev 从 a 改到 b
    (let ((result (ebasecamp-config-write-update-config-project
                   'alpha 'dev 'b)))
      (should (null (plist-get result :errors)))
      (should (eq 'b (ebasecamp-model-config-project
                      (ebasecamp-model-config 'alpha 'dev))))
      ;; 另一份配置未被波及
      (should (eq 'c (ebasecamp-model-config-project
                      (ebasecamp-model-config 'alpha 'other)))))
    ;; 删除配置：组仍在，配置消失
    (let ((result (ebasecamp-config-write-remove-config 'alpha 'dev)))
      (should (null (plist-get result :errors)))
      (should (ebasecamp-model-group 'alpha))
      (should (equal '(other) (ebasecamp-config-write-test--configs-of 'alpha)))
      (should-not (string-match-p "(dev :project"
                                  (ebasecamp-config-write-test--read
                                   (ebasecamp-config-write-test--groups-file)))))
    ;; 删除不存在的配置
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-remove-config 'alpha 'ghost))
     "没有配置 ghost")))

;;; W3.1-5 移动配置（同一 in-memory 全文一次改两处）

(ert-deftest ebasecamp-config-write-test-move-config ()
  "配置 dev 从 alpha 移到 beta：一次事务内源移除 + 目标追加；
目标组已有同项目引用时 `user-error' 且两个组都保持原样。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    ;; 失败路径：beta 的 be 已引用项目 b
    (let* ((file (ebasecamp-config-write-test--groups-file))
           (hash (ebasecamp-config-write-test--hash file)))
      (ebasecamp-config-write-test--error-matching
       (lambda () (ebasecamp-config-write-move-config 'alpha 'dev 'beta 'b))
       "项目 b.*组 beta")
      ;; 无部分写入：文件逐字节不变
      (should (equal hash (ebasecamp-config-write-test--hash file)))
      (ebasecamp-config-load)
      (should (equal '(dev other)
                     (ebasecamp-config-write-test--configs-of 'alpha)))
      (should (equal '(be) (ebasecamp-config-write-test--configs-of 'beta))))
    ;; 源组没有该配置
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-move-config 'alpha 'ghost 'beta 'b2))
     "没有配置 ghost")
    ;; 成功路径：dev → beta / 项目 b2
    (let ((result (ebasecamp-config-write-move-config 'alpha 'dev 'beta 'b2)))
      (should (null (plist-get result :errors)))
      (should (equal '(other) (ebasecamp-config-write-test--configs-of 'alpha)))
      (should (equal '(be dev) (ebasecamp-config-write-test--configs-of 'beta)))
      (should (eq 'b2 (ebasecamp-model-config-project
                       (ebasecamp-model-config 'beta 'dev))))
      ;; 两个组都还在（源组删掉最后一份配置时组也必须保留）
      (should (ebasecamp-model-group 'alpha))
      (should (ebasecamp-model-group 'beta)))
    ;; 源组删除最后一份配置后组仍保留（:configs nil）
    (let ((result (ebasecamp-config-write-move-config 'alpha 'other 'beta 'a)))
      (should (null (plist-get result :errors)))
      (should (ebasecamp-model-group 'alpha))
      (should-not (ebasecamp-config-write-test--configs-of 'alpha))
      (should (member 'other (ebasecamp-config-write-test--configs-of 'beta))))
    (should (string-match-p ":configs nil"
                            (ebasecamp-config-write-test--read
                             (ebasecamp-config-write-test--groups-file))))))

;;; W3.3 项目与组 CRUD

(defun ebasecamp-config-write-test--project-file (name)
  "返回当前临时清单目录里项目 NAME 的文件绝对路径。"
  (expand-file-name (concat "projects/" name ".el")
                    ebasecamp-config-write-test--directory))

(defun ebasecamp-config-write-test--all-project-hashes ()
  "返回当前临时清单目录里每个项目文件的 (文件名 . sha256) 列表。"
  (mapcar (lambda (file)
            (cons (file-name-nondirectory file)
                  (ebasecamp-config-write-test--hash file)))
          (directory-files (expand-file-name "projects/"
                                             ebasecamp-config-write-test--directory)
                           t "\\.el\\'")))

(defconst ebasecamp-config-write-test--legacy-project
  (concat ";;; -*- lexical-binding: t; -*-\n"
          "(ebasecamp-define-project legacy\n"
          "  :title \"legacy\"\n"
          "  :root \"/tmp/ebc-legacy\"\n"
          "  :groups ((beta :scope per-project)))\n")
  "带项目侧旧写法 `:groups' 引用的项目文件内容（引用组 beta）。")

(ert-deftest ebasecamp-config-write-test-add-project ()
  "新增项目：文件被创建、内容可加载、model 能查到；同名已存在则拒绝且原文件不变。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let ((file (ebasecamp-config-write-test--project-file "newproj")))
      (should-not (file-exists-p file))
      (let ((result (ebasecamp-config-write-add-project
                     'newproj "新项目" "/tmp/ebc-new")))
        (should (null (plist-get result :errors)))
        (should (file-exists-p file))
        ;; 文件可被加载器读取：重新加载没有新增错误
        (should (null (plist-get (ebasecamp-config-load) :errors)))
        (let ((project (ebasecamp-model-project 'newproj)))
          (should project)
          (should (equal "新项目" (ebasecamp-project-title project)))
          (should (equal "/tmp/ebc-new" (ebasecamp-project-root project))))
        ;; 只写项目自身：不写项目侧旧写法 :groups（AGENTS 不变量 9）
        (should-not (string-match-p ":groups"
                                    (ebasecamp-config-write-test--read file)))
        (should-not (ebasecamp-config-write-test--leftovers))))
    ;; 同名项目已存在 → user-error 且原文件逐字节不变
    (let* ((file (ebasecamp-config-write-test--project-file "app"))
           (hash (ebasecamp-config-write-test--hash file)))
      (ebasecamp-config-write-test--error-matching
       (lambda () (ebasecamp-config-write-add-project 'app "x" "/tmp/x"))
       "已存在")
      (should (equal hash (ebasecamp-config-write-test--hash file))))
    ;; 非法名字（大写 / 空格）在写盘前被拒
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-add-project 'Bad\ Name "x" "/tmp/x"))
     "非法")
    (should-not (file-exists-p
                 (ebasecamp-config-write-test--project-file "Bad Name")))
    (should-not (ebasecamp-config-write-test--leftovers))))

(ert-deftest ebasecamp-config-write-test-update-project ()
  "改 :title / :root：加载后 model 反映新值，其它项目文件与无关键不受影响。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    ;; 额外写一个带无关键的项目文件，验证更新时它们被原样保留
    (ebasecamp-config-write-test--write-flat
     (ebasecamp-config-write-test--project-file "extra")
     (concat "(ebasecamp-define-project extra\n"
             "  :title \"extra\"\n"
             "  :root \"/tmp/ebc-extra\"\n"
             "  :shared-network nil\n"
             "  :export-file \"compose.override.yaml\")\n"))
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let ((others (assoc-delete-all
                   "app.el"
                   (ebasecamp-config-write-test--all-project-hashes))))
      (let ((result (ebasecamp-config-write-update-project
                     'app "应用" "/srv/app")))
        (should (null (plist-get result :errors)))
        (let ((project (ebasecamp-model-project 'app)))
          (should (equal "应用" (ebasecamp-project-title project)))
          (should (equal "/srv/app" (ebasecamp-project-root project))))
        ;; 其它项目文件逐字节不变
        (should (equal others
                       (assoc-delete-all
                        "app.el"
                        (ebasecamp-config-write-test--all-project-hashes))))))
    ;; 无关键（:shared-network / :export-file）在更新后保留
    (let ((result (ebasecamp-config-write-update-project
                   'extra "extra 改名" "/srv/extra")))
      (should (null (plist-get result :errors)))
      (let ((plist (cddr (ebasecamp-config-write-test--read-form-at
                          (ebasecamp-config-write-test--read
                           (ebasecamp-config-write-test--project-file "extra"))
                          "(ebasecamp-define-project extra"))))
        (should (equal "extra 改名" (plist-get plist :title)))
        (should (equal "/srv/extra" (plist-get plist :root)))
        (should (plist-member plist :shared-network))
        (should-not (plist-get plist :shared-network))
        (should (equal "compose.override.yaml" (plist-get plist :export-file)))))
    ;; 项目不存在
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-update-project 'ghost "x" "/x"))
     "没有项目 ghost")
    (should-not (ebasecamp-config-write-test--leftovers))))

(ert-deftest ebasecamp-config-write-test-remove-project ()
  "未被引用时删除项目文件；被组侧 :configs 引用时拒绝并列出「组/配置」。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    ;; alpha 组的 dev 配置引用项目 a → 拒绝，文件逐字节不变
    (let* ((file (ebasecamp-config-write-test--project-file "a"))
           (hash (ebasecamp-config-write-test--hash file)))
      (let ((message (ebasecamp-config-write-test--error-matching
                      (lambda () (ebasecamp-config-write-remove-project 'a))
                      "alpha/dev")))
        (should (string-match-p "项目 a" message)))
      (should (file-exists-p file))
      (should (equal hash (ebasecamp-config-write-test--hash file))))
    ;; 未被引用 → 删除文件，加载无新增错误
    (let* ((file (ebasecamp-config-write-test--project-file "myapp"))
           (result (ebasecamp-config-write-remove-project 'myapp)))
      (should (null (plist-get result :errors)))
      (should-not (file-exists-p file))
      (should-not (ebasecamp-model-project 'myapp))
      ;; 其它项目与组不受影响
      (should (ebasecamp-model-project 'app))
      (should (ebasecamp-model-group 'alpha))
      (should (equal '(dev other)
                     (ebasecamp-config-write-test--configs-of 'alpha))))
    ;; 项目不存在
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-remove-project 'ghost))
     "没有项目 ghost")
    (should-not (ebasecamp-config-write-test--leftovers))))

(ert-deftest ebasecamp-config-write-test-add-group ()
  "向 groups.el 追加组 form：加载无错误、model 有该组；同名组已存在则拒绝。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let ((result (ebasecamp-config-write-add-group
                   'gamma "gamma 组" 'per-project)))
      (should (null (plist-get result :errors)))
      (let ((group (ebasecamp-model-group 'gamma)))
        (should group)
        (should (equal "gamma 组" (ebasecamp-group-title group)))
        (should (eq 'per-project (ebasecamp-group-scope group)))
        (should-not (ebasecamp-model-group-configs 'gamma)))
      ;; 原有组与配置不受影响
      (should (ebasecamp-model-group 'alpha))
      (should (equal '(dev other) (ebasecamp-config-write-test--configs-of 'alpha)))
      ;; 落盘文本：新组 form 追加在末尾，`:services nil'，文件仍以换行结尾
      (let ((text (ebasecamp-config-write-test--read
                   (ebasecamp-config-write-test--groups-file))))
        (should (string-match-p "(ebasecamp-define-group gamma" text))
        (should (string-match-p ":services nil" text))
        (should (string-suffix-p "\n" text))))
    ;; 同名组已存在 → user-error
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-add-group 'alpha "x" 'per-project))
     "已有组 alpha")
    ;; 非法 scope 在写盘前被拒
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-add-group 'delta "d" 'bogus))
     "scope")
    (should-not (ebasecamp-config-write-test--leftovers))))

(ert-deftest ebasecamp-config-write-test-update-group ()
  "改 :title / :scope（per-project ↔ shared）：model 反映新值，其它组字节不变。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let* ((before (ebasecamp-config-write-test--read
                    (ebasecamp-config-write-test--groups-file)))
           (alpha-form (substring before 0 (string-match-p
                                            "(ebasecamp-define-group beta"
                                            before))))
      (let ((result (ebasecamp-config-write-update-group
                     'beta "beta 组" 'shared)))
        (should (null (plist-get result :errors)))
        (let ((group (ebasecamp-model-group 'beta)))
          (should (equal "beta 组" (ebasecamp-group-title group)))
          (should (eq 'shared (ebasecamp-group-scope group))))
        ;; alpha 组（含块间注释）逐字节不变
        (should (string-prefix-p
                 alpha-form
                 (ebasecamp-config-write-test--read
                  (ebasecamp-config-write-test--groups-file)))))
      ;; 改回 per-project
      (let ((result (ebasecamp-config-write-update-group
                     'beta "beta" 'per-project)))
        (should (null (plist-get result :errors)))
        (should (eq 'per-project (ebasecamp-group-scope
                                  (ebasecamp-model-group 'beta))))
        (should (equal "beta" (ebasecamp-group-title
                               (ebasecamp-model-group 'beta))))))
    ;; 组不存在
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-update-group 'ghost "x" 'per-project))
     "没有组 ghost")
    ;; 非法 scope
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-update-group 'alpha "x" 'bogus))
     "scope")
    (should-not (ebasecamp-config-write-test--leftovers))))

(ert-deftest ebasecamp-config-write-test-remove-group ()
  "删除组 form：被项目侧旧写法 :groups 引用时拒绝并列出项目名；否则删除后无新增错误。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (ebasecamp-config-write-test--write-flat
     (ebasecamp-config-write-test--project-file "legacy")
     ebasecamp-config-write-test--legacy-project)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    ;; beta 被项目 legacy 的旧写法引用 → 拒绝，groups.el 逐字节不变
    (let* ((file (ebasecamp-config-write-test--groups-file))
           (hash (ebasecamp-config-write-test--hash file)))
      (let ((message (ebasecamp-config-write-test--error-matching
                      (lambda () (ebasecamp-config-write-remove-group 'beta))
                      "legacy")))
        (should (string-match-p "beta" message)))
      (should (equal hash (ebasecamp-config-write-test--hash file))))
    ;; alpha 未被任何项目侧旧写法引用 → 删除组 form，加载无新增错误
    (let ((result (ebasecamp-config-write-remove-group 'alpha)))
      (should (null (plist-get result :errors)))
      (should-not (ebasecamp-model-group 'alpha))
      (should (ebasecamp-model-group 'beta))
      (should-not (string-match-p
                   "(ebasecamp-define-group alpha"
                   (ebasecamp-config-write-test--read
                    (ebasecamp-config-write-test--groups-file)))))
    ;; 组不存在
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-remove-group 'ghost))
     "没有组 ghost")
    (should-not (ebasecamp-config-write-test--leftovers))))

;;; X1 写盘跨文件定位（组可以定义在 groups.el 或 projects/*.el）

;; 背景（X0 实测）：导入层把「组 + 项目」一起写进 `projects/<name>.el'，而写盘
;; 层原先写死「组定义只能在 groups.el」，于是「新建配置」在导入来的清单上直接
;; 报「清单文件 …/groups.el 不存在」。另一个 X0 实测结论决定了裁决规则：同名组
;; 出现在两个文件时**加载层报错且后加载文件整体回滚**（同文件的项目一起消失），
;; 所以定位函数对 >1 命中必须拒绝，不能静默选第一个。

(defconst ebasecamp-config-write-test--group-in-project-file
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; projects/x.el --- 组写在项目文件里（导入的落盘形态，无 groups.el）\n"
   "\n"
   "(ebasecamp-define-group xgroup\n"
   "  :title \"xgroup\"\n"
   "  :scope per-project\n"
   "  :services ((db :image \"mysql:8\"\n"
   "              :ports ((3307 . 3306))))\n"
   "  :configs ((dev :project xproj)))\n"
   "\n"
   ";; 兄弟组：写 xgroup 时它及其之后的字节必须原样保留\n"
   "(ebasecamp-define-group xsibling\n"
   "  :title \"xsibling\"\n"
   "  :scope per-project\n"
   "  :services ((web :image \"nginx:1.27\"))\n"
   "  :configs nil)\n")
  "「组定义在项目文件里」的清单：`projects/x.el' 含两个组（xgroup / xsibling）。")

(defconst ebasecamp-config-write-test--group-a
  ";;; -*- lexical-binding: t; -*-\n(ebasecamp-define-group agroup\n  :title \"agroup\"\n  :scope per-project\n  :services ((db :image \"mysql:8\"))\n  :configs ((mover :project pa)))\n"
  "跨文件移动的源组文件：`projects/a.el'（配置 mover 引用项目 pa）。")

(defconst ebasecamp-config-write-test--group-b
  ";;; -*- lexical-binding: t; -*-\n(ebasecamp-define-group bgroup\n  :title \"bgroup\"\n  :scope per-project\n  :services ((db :image \"mysql:8\"))\n  :configs ((keep :project pb)\n            (taken :project pc)))\n"
  "跨文件移动的目标组文件：`projects/b.el'（taken 已引用项目 pc）。")

(defun ebasecamp-config-write-test--write-project-text (name text)
  "把 TEXT 写成 `projects/NAME.el'（目录不存在则创建）。"
  (make-directory
   (expand-file-name "projects/" ebasecamp-config-write-test--directory) t)
  (ebasecamp-config-write-test--write-flat
   (expand-file-name (concat "projects/" name ".el")
                     ebasecamp-config-write-test--directory)
   text))

(defun ebasecamp-config-write-test--write-project-files (names)
  "为 NAMES 里每个项目名写一个项目文件（不写 `groups.el'）。"
  (dolist (name names)
    (ebasecamp-config-write-test--write-project-text
     name
     (concat ";;; -*- lexical-binding: t; -*-\n"
             "(ebasecamp-define-project " name "\n"
             "  :title \"" name "\"\n"
             "  :root \"/tmp/ebc-" name "\")\n"))))

(defun ebasecamp-config-write-test--write-single-group-manifest ()
  "写「无 groups.el、组在 `projects/x.el'」的清单（项目 xproj / yproj）。"
  (ebasecamp-config-write-test--write-project-text
   "x" ebasecamp-config-write-test--group-in-project-file)
  (ebasecamp-config-write-test--write-project-files '("xproj" "yproj")))

(defun ebasecamp-config-write-test--locate (group-name)
  "调用定位函数（内部函数，测试直接验证其语义）。"
  (ebasecamp-config-write--manifest-file-for-group group-name))

(ert-deftest ebasecamp-config-write-test-locate-file-single ()
  "组只定义在 `projects/x.el' → 返回该文件；没有 `groups.el' 不是错误。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-single-group-manifest)
    (should-not (file-exists-p (ebasecamp-config-write-test--groups-file)))
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (should (equal (expand-file-name "projects/x.el"
                                     ebasecamp-config-write-test--directory)
                   (ebasecamp-config-write-test--locate 'xgroup)))
    ;; 名字传字符串与符号等价
    (should (equal (expand-file-name "projects/x.el"
                                     ebasecamp-config-write-test--directory)
                   (ebasecamp-config-write-test--locate "xsibling")))))

(ert-deftest ebasecamp-config-write-test-locate-file-none ()
  "清单里没有该组 → `user-error'，消息含「没有组」与已扫描文件数。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-single-group-manifest)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let ((message (ebasecamp-config-write-test--error-matching
                    (lambda () (ebasecamp-config-write-test--locate 'ghost))
                    "没有组 ghost")))
      (should (string-match-p "已扫描 [0-9]+ 个文件" message)))))

(ert-deftest ebasecamp-config-write-test-locate-file-duplicate ()
  "同名组同时出现在 `groups.el' 与 `projects/x.el' → 拒绝并列出两个文件与回滚提示。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-single-group-manifest)
    (ebasecamp-config-write-test--write-flat
     (ebasecamp-config-write-test--groups-file)
     (concat ";;; -*- lexical-binding: t; -*-\n"
             "(ebasecamp-define-group xgroup\n"
             "  :title \"xgroup\"\n"
             "  :scope per-project\n"
             "  :services ((db :image \"mysql:8\"))\n"
             "  :configs nil)\n"))
    (let ((message (ebasecamp-config-write-test--error-matching
                    (lambda () (ebasecamp-config-write-test--locate 'xgroup))
                    "多个文件")))
      ;; 两个文件都要列出（顺序为加载顺序：groups.el 在前）
      (should (string-match-p "groups\\.el" message))
      (should (string-match-p "projects/x\\.el" message))
      (should (string-match-p "不会出现在界面中" message))
      (should (< (string-match-p "groups\\.el" message)
                 (string-match-p "projects/x\\.el" message))))
    ;; 加载层确实报错：后加载的 projects/x.el 整体回滚（X0 实测结论）
    (let ((errors (ebasecamp-config-error-messages (ebasecamp-config-load))))
      (should errors)
      (should (string-match-p "已定义" (mapconcat #'identity errors "；")))
      (should-not (ebasecamp-model-group 'xsibling)))
    ;; 只有一份定义的组不受影响
    (should (equal (expand-file-name "projects/x.el"
                                     ebasecamp-config-write-test--directory)
                   (ebasecamp-config-write-test--locate 'xsibling)))))

(ert-deftest ebasecamp-config-write-test-add-config-without-groups-file ()
  "无 groups.el、组在 `projects/x.el'：新增配置写进该文件、groups.el 不被创建、兄弟内容不变。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-single-group-manifest)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let* ((file (expand-file-name "projects/x.el"
                                   ebasecamp-config-write-test--directory))
           (before (ebasecamp-config-write-test--read file))
           ;; 兄弟组及其之后的全部字节（含块间注释、结尾换行）
           (sibling (substring before (string-match-p ";; 兄弟组" before)))
           (result (ebasecamp-config-write-add-config 'xgroup 'extra 'yproj))
           (after (ebasecamp-config-write-test--read file)))
      (should (null (plist-get result :errors)))
      ;; 写进了组定义所在文件，且没有凭空创建 groups.el
      (should-not (file-exists-p (ebasecamp-config-write-test--groups-file)))
      (should (equal '(dev extra) (ebasecamp-config-write-test--configs-of 'xgroup)))
      (should (eq 'yproj (ebasecamp-model-config-project
                          (ebasecamp-model-config 'xgroup 'extra))))
      ;; 文件头与兄弟内容逐字节保留
      (should (string-prefix-p ";;; -*- lexical-binding: t; -*-" after))
      (should (string-suffix-p sibling after))
      (should (equal '((dev :project xproj) (extra :project yproj))
                     (plist-get (ebasecamp-config-write-test--read-group
                                 after "(ebasecamp-define-group xgroup")
                                :configs)))
      (should-not (ebasecamp-config-write-test--leftovers)))))

(ert-deftest ebasecamp-config-write-test-multi-entrypoints-without-groups-file ()
  "无 groups.el 时五个实体操作入口（服务字段 / 配置 project / 增删配置 / 改组 / 删组）都命中 projects/x.el。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-single-group-manifest)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let ((file (expand-file-name "projects/x.el"
                                  ebasecamp-config-write-test--directory)))
      ;; ① 服务字段
      (should (null (plist-get (ebasecamp-config-write-update-service-fields
                                'xgroup 'db '(:restart "always"))
                               :errors)))
      (let ((text (ebasecamp-config-write-test--read file)))
        (should (equal "always"
                       (plist-get (ebasecamp-config-write-test--read-service
                                   text "(db")
                                  :restart))))
      ;; ② 改配置 :project
      (should (null (plist-get (ebasecamp-config-write-update-config-project
                                'xgroup 'dev 'yproj)
                               :errors)))
      (should (eq 'yproj (ebasecamp-model-config-project
                          (ebasecamp-model-config 'xgroup 'dev))))
      ;; ③ 新增配置 + ④ 删除配置
      (should (null (plist-get (ebasecamp-config-write-add-config
                                'xgroup 'extra 'xproj)
                               :errors)))
      (should (null (plist-get (ebasecamp-config-write-remove-config
                                'xgroup 'extra)
                               :errors)))
      (should (equal '(dev) (ebasecamp-config-write-test--configs-of 'xgroup)))
      ;; ⑤ 改组（标题）
      (should (null (plist-get (ebasecamp-config-write-update-group
                                'xgroup "xgroup 改名" nil)
                               :errors)))
      (should (equal "xgroup 改名"
                     (ebasecamp-group-title (ebasecamp-model-group 'xgroup))))
      ;; ⑥ 删组
      (should (null (plist-get (ebasecamp-config-write-remove-group 'xgroup)
                               :errors)))
      (should-not (ebasecamp-model-group 'xgroup))
      ;; 全程都在 projects/x.el 上动，groups.el 始终没有被创建
      (should-not (file-exists-p (ebasecamp-config-write-test--groups-file)))
      (should (ebasecamp-model-group 'xsibling))
      (should (string-match-p "(ebasecamp-define-group xsibling"
                              (ebasecamp-config-write-test--read file)))
      (should-not (string-match-p "(ebasecamp-define-group xgroup"
                                  (ebasecamp-config-write-test--read file))))
    (should-not (ebasecamp-config-write-test--leftovers))))

(ert-deftest ebasecamp-config-write-test-move-config-across-files ()
  "跨文件移动：源组在 `projects/a.el`、目标组在 `projects/b.el`，两文件都更新；
目标组已有同项目引用时拒绝且两文件逐字节不变（备份补偿，无部分写入）。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-project-text
     "a" ebasecamp-config-write-test--group-a)
    (ebasecamp-config-write-test--write-project-text
     "b" ebasecamp-config-write-test--group-b)
    (ebasecamp-config-write-test--write-project-files '("pa" "pb" "pc"))
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let* ((a-file (expand-file-name "projects/a.el"
                                     ebasecamp-config-write-test--directory))
           (b-file (expand-file-name "projects/b.el"
                                     ebasecamp-config-write-test--directory))
           (a-hash (ebasecamp-config-write-test--hash a-file))
           (b-hash (ebasecamp-config-write-test--hash b-file)))
      ;; 失败路径：bgroup 的 taken 已引用项目 pc（D2）→ 两个文件都不许动
      (ebasecamp-config-write-test--error-matching
       (lambda () (ebasecamp-config-write-move-config
                   'agroup 'mover 'bgroup 'pc))
       "项目 pc.*组 bgroup")
      (should (equal a-hash (ebasecamp-config-write-test--hash a-file)))
      (should (equal b-hash (ebasecamp-config-write-test--hash b-file)))
      (ebasecamp-config-load)
      (should (equal '(mover) (ebasecamp-config-write-test--configs-of 'agroup)))
      (should (equal '(keep taken)
                     (ebasecamp-config-write-test--configs-of 'bgroup)))
      (should-not (ebasecamp-config-write-test--leftovers)))
    ;; 成功路径：mover 从 a.el 的 agroup 移到 b.el 的 bgroup，项目 pa
    (let ((result (ebasecamp-config-write-move-config
                   'agroup 'mover 'bgroup 'pa)))
      (should (null (plist-get result :errors)))
      (should-not (ebasecamp-config-write-test--configs-of 'agroup))
      (should (equal '(keep taken mover)
                     (ebasecamp-config-write-test--configs-of 'bgroup)))
      (should (eq 'pa (ebasecamp-model-config-project
                       (ebasecamp-model-config 'bgroup 'mover))))
      ;; 源文件：组还在、配置已移除；目标文件：配置已写入
      (let ((a-text (ebasecamp-config-write-test--read
                     (expand-file-name "projects/a.el"
                                       ebasecamp-config-write-test--directory)))
            (b-text (ebasecamp-config-write-test--read
                     (expand-file-name "projects/b.el"
                                       ebasecamp-config-write-test--directory))))
        (should (string-match-p "(ebasecamp-define-group agroup" a-text))
        (should (string-match-p ":configs nil" a-text))
        (should (string-match-p "(mover :project pa)" b-text))
        (should (string-match-p "(keep :project pb)" b-text))))
    ;; 两次事务都不遗留备份文件
    (should-not (ebasecamp-config-write-test--leftovers))
    (should-not (directory-files
                 (expand-file-name "projects/"
                                   ebasecamp-config-write-test--directory)
                 nil "\\`\\.ebasecamp-"))))

(ert-deftest ebasecamp-config-write-test-config-references-cross-file ()
  "组在 `projects/x.el' 且引用项目 xproj：删项目被拒绝，消息列出「组/配置」。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-single-group-manifest)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let* ((file (expand-file-name "projects/xproj.el"
                                   ebasecamp-config-write-test--directory))
           (hash (ebasecamp-config-write-test--hash file))
           (message (ebasecamp-config-write-test--error-matching
                     (lambda () (ebasecamp-config-write-remove-project 'xproj))
                     "xgroup/dev")))
      (should (string-match-p "项目 xproj" message))
      ;; 被拒时不删文件、内容逐字节不变
      (should (file-exists-p file))
      (should (equal hash (ebasecamp-config-write-test--hash file))))))

;;; 批次 4（A-II）：旧 :groups 写盘迁移（须用户确认，绝不静默）

;; 背景：A-I 让「旧 :groups + 组侧配置」共存不报错；A-II 在用户确认后把旧引用
;; 真正从项目文件里删掉。两条编排路径**必须分别实现**：
;; - 同文件（组与项目在同一个 `projects/*.el'）→ 一次事务内两处降序替换
;;   （组侧 `:configs' 追加 + 项目侧 `:groups' 删元素），复用
;;   `--move-config-within-file' 的 `--replace-forms' 模式；
;; - 跨文件（组在 groups.el、项目在 projects/*.el）→ 两次事务 + 备份补偿
;;   （第二段失败用第一段备份恢复组文件原文并 signal 原错误），复用
;;   `--move-config-across-files' 的补偿模式。
;; 写盘层 `migrate-legacy' 默认 nil：脚本 / 测试调用零行为变更（项目文件逐字节
;; 不变，由用例④守护）。

(defconst ebasecamp-config-write-test--legacy-same-file
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; projects/x.el --- 组与项目同文件，项目仍用旧写法 :groups\n"
   "\n"
   "(ebasecamp-define-group db\n"
   "  :title \"db\"\n"
   "  :scope per-project\n"
   "  :services ((postgres :image \"postgres:16\"))\n"
   "  :configs nil)\n"
   "\n"
   "(ebasecamp-define-group cache\n"
   "  :title \"cache\"\n"
   "  :scope per-project\n"
   "  :services ((redis :image \"redis:7\"))\n"
   "  :configs nil)\n"
   "\n"
   "(ebasecamp-define-project demo\n"
   "  :title \"demo\"\n"
   "  :root \"/tmp/ebc-demo\"\n"
   "  :groups ((db) (cache)))\n")
  "同文件迁移用的清单：`projects/x.el' 含两个组 + 一个用旧写法引用它们的项目。")

(defconst ebasecamp-config-write-test--legacy-groups-file
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; groups.el --- 跨文件迁移：组定义\n"
   "\n"
   "(ebasecamp-define-group db\n"
   "  :title \"db\"\n"
   "  :scope per-project\n"
   "  :services ((postgres :image \"postgres:16\"))\n"
   "  :configs nil)\n")
  "跨文件迁移的组文件：组 db 没有配置，项目侧仍用旧写法引用它。")

(defconst ebasecamp-config-write-test--legacy-project-file
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; projects/demo.el --- 跨文件迁移：项目定义（旧写法引用组）\n"
   "\n"
   "(ebasecamp-define-project demo\n"
   "  :title \"demo\"\n"
   "  :root \"/tmp/ebc-demo\"\n"
   "  :groups ((db)))\n")
  "跨文件迁移的项目文件：`:groups' 只有组 db 这条旧引用。")

(defun ebasecamp-config-write-test--write-legacy-across-files ()
  "写跨文件迁移清单：组 db 在 groups.el、项目 demo 在 projects/demo.el。"
  (ebasecamp-config-write-test--write-flat
   (ebasecamp-config-write-test--groups-file)
   ebasecamp-config-write-test--legacy-groups-file)
  (ebasecamp-config-write-test--write-project-text
   "demo" ebasecamp-config-write-test--legacy-project-file))

(defun ebasecamp-config-write-test--legacy-file-path ()
  "返回同文件迁移清单的文件路径（`projects/x.el'）。"
  (expand-file-name "projects/x.el"
                    ebasecamp-config-write-test--directory))

(ert-deftest ebasecamp-config-write-test-migrate-legacy-within-file ()
  "同文件迁移：一次事务里组侧 `:configs' 追加 + 项目侧删该旧引用元素。
其余元素原位保留，组定义本身不被删除，重载零错误。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-project-text
     "x" ebasecamp-config-write-test--legacy-same-file)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let* ((file (ebasecamp-config-write-test--legacy-file-path))
           (result (ebasecamp-config-write-add-config "db" "cfg" 'demo t))
           (text (ebasecamp-config-write-test--read file)))
      (should (null (plist-get result :errors)))
      ;; 组侧：配置已追加
      (should (equal '(cfg)
                     (ebasecamp-config-write-test--configs-of 'db)))
      (should (eq 'demo (ebasecamp-model-config-project
                         (ebasecamp-model-config 'db 'cfg))))
      ;; 项目侧：db 这条被删，cache 原位保留（不是整套重写）
      (should (string-match-p ":groups ((cache))" text))
      (should-not (string-match-p "(db)" text))
      ;; 同文件里的两个组定义都还在
      (should (string-match-p "(ebasecamp-define-group db" text))
      (should (string-match-p "(ebasecamp-define-group cache" text))
      ;; 重载零错误
      (should (null (plist-get (ebasecamp-config-load) :errors)))
      (should-not (ebasecamp-config-write-test--leftovers)))))

(ert-deftest ebasecamp-config-write-test-migrate-legacy-across-files ()
  "跨文件迁移：组文件事务追加配置，项目文件事务删除旧引用，两段都生效。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-legacy-across-files)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let* ((groups-file (ebasecamp-config-write-test--groups-file))
           (project-file (expand-file-name
                          "projects/demo.el"
                          ebasecamp-config-write-test--directory))
           (result (ebasecamp-config-write-add-config 'db 'cfg 'demo t))
           (groups-text (ebasecamp-config-write-test--read groups-file))
           (project-text (ebasecamp-config-write-test--read project-file)))
      (should (null (plist-get result :errors)))
      ;; 第一段：组文件拿到配置
      (should (equal '(cfg)
                     (ebasecamp-config-write-test--configs-of 'db)))
      (should (string-match-p "(cfg :project demo)" groups-text))
      ;; 第二段：项目文件的旧引用被删（唯一元素 → 整条键移除）
      (should-not (string-match-p ":groups" project-text))
      (should (string-match-p "(ebasecamp-define-project demo" project-text))
      ;; 重载零错误，两次事务都不遗留备份
      (should (null (plist-get (ebasecamp-config-load) :errors)))
      (should-not (ebasecamp-config-write-test--leftovers))
      (should-not (directory-files
                   (expand-file-name "projects/"
                                     ebasecamp-config-write-test--directory)
                   nil "\\`\\.ebasecamp-")))))

(ert-deftest ebasecamp-config-write-test-migrate-legacy-rolls-back-first-transaction ()
  "跨文件第二段失败 → 用第一段备份恢复组文件原文，并把原错误 signal 出去。
两段都**逐字节**回到迁移前状态（跨文件没有原子性，只能靠备份补偿）。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-legacy-across-files)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let* ((groups-file (ebasecamp-config-write-test--groups-file))
           (project-file (expand-file-name
                          "projects/demo.el"
                          ebasecamp-config-write-test--directory))
           (groups-before (ebasecamp-config-write-test--read groups-file))
           (project-before (ebasecamp-config-write-test--read project-file))
           (original (symbol-function 'ebasecamp-manifest--write-transaction))
           (calls 0))
      ;; 打桩：第二次事务（项目文件那段）直接失败
      (cl-letf (((symbol-function 'ebasecamp-manifest--write-transaction)
                 (lambda (file write-fn &rest keys)
                   (cl-incf calls)
                   (when (= calls 2)
                     (error "模拟第二段写盘失败"))
                   (apply original file write-fn keys))))
        (should-error (ebasecamp-config-write-add-config 'db 'cfg 'demo t)
                      :type 'error))
      (should (= 2 calls))
      ;; 第一段已被补偿回滚：组文件逐字节恢复原文
      (should (equal groups-before
                     (ebasecamp-config-write-test--read groups-file)))
      ;; 第二段自身没写盘：项目文件也逐字节不变
      (should (equal project-before
                     (ebasecamp-config-write-test--read project-file)))
      (should-not (ebasecamp-config-write-test--leftovers))
      (should-not (directory-files
                   (expand-file-name "projects/"
                                     ebasecamp-config-write-test--directory)
                   nil "\\`\\.ebasecamp-"))
      ;; 磁盘状态与迁移前一致：组无配置、项目仍有旧引用
      (ebasecamp-config-load)
      (should-not (ebasecamp-config-write-test--configs-of 'db))
      (should (string-match-p ":groups ((db))"
                              (ebasecamp-config-write-test--read
                               project-file))))))

(ert-deftest ebasecamp-config-write-test-migrate-legacy-default-nil-keeps-project-file ()
  "默认 `migrate-legacy' = nil：只写组文件，项目文件**逐字节不变**（绝不静默改写）。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-legacy-across-files)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let* ((groups-file (ebasecamp-config-write-test--groups-file))
           (project-file (expand-file-name
                          "projects/demo.el"
                          ebasecamp-config-write-test--directory))
           (project-before (ebasecamp-config-write-test--read project-file))
           (result (ebasecamp-config-write-add-config 'db 'cfg 'demo)))
      (should (null (plist-get result :errors)))
      (should (equal '(cfg)
                     (ebasecamp-config-write-test--configs-of 'db)))
      (should (string-match-p "(cfg :project demo)"
                              (ebasecamp-config-write-test--read groups-file)))
      ;; 项目文件一个字节都没动
      (should (equal project-before
                     (ebasecamp-config-write-test--read project-file)))
      (should-not (ebasecamp-config-write-test--leftovers)))))

(ert-deftest ebasecamp-config-write-test-migrate-legacy-removes-empty-groups-key ()
  "`:groups' 只剩该组一条时**整条键被移除**（不留 `:groups nil'），重载零错误。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-project-text
     "x"
     (concat ";;; -*- lexical-binding: t; -*-\n"
             ";;; projects/x.el --- 旧写法只有一条引用\n"
             "\n"
             "(ebasecamp-define-group db\n"
             "  :title \"db\"\n"
             "  :scope per-project\n"
             "  :services ((postgres :image \"postgres:16\"))\n"
             "  :configs nil)\n"
             "\n"
             "(ebasecamp-define-project demo\n"
             "  :title \"demo\"\n"
             "  :root \"/tmp/ebc-demo\"\n"
             "  :groups ((db)))\n"))
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let* ((file (ebasecamp-config-write-test--legacy-file-path))
           (result (ebasecamp-config-write-add-config 'db 'cfg 'demo t))
           (text (ebasecamp-config-write-test--read file)))
      (should (null (plist-get result :errors)))
      ;; 整个 `:groups' 键（含关键字与值）消失——不是 `:groups nil'
      (should-not (string-match-p ":groups" text))
      (should-not (string-match-p "nil)" text))
      ;; 项目 form 的其余键与结尾逐字节保留
      (should (string-match-p "(ebasecamp-define-project demo" text))
      (should (string-match-p ":root \"/tmp/ebc-demo\")" text))
      ;; 重载零错误：项目不再引用该组，配置接管为唯一有效引用
      (should (null (plist-get (ebasecamp-config-load) :errors)))
      (should (equal '(cfg)
                     (ebasecamp-config-write-test--configs-of 'db)))
      (should-not (ebasecamp-config-write-test--leftovers)))))

;;; v0.7 批次 B6（#38）：界面 `E' 的跨文件迁移闭环
;;
;; `E' = `ebasecamp-ui--open-config-editor' → `ebasecamp-config-write-update-config-project'
;; 传 `migrate-legacy' t。迁移方向是「组文件新增 `:project' + 项目文件删旧
;; `:groups' 引用」，写盘层走 `--migrate-across-files'（两次事务 + 备份补偿）。
;; 上一节（A-II）已覆盖 `add-config' 的跨文件迁移，本节补 `E' 这一条路径，
;; 并额外断言**零备份残留**：跨文件路径会先拿 `:keep-backup'，两段都成功后
;; 必须删掉备份，否则每次 `E' 都在清单目录里留下隐藏文件。
;;
;; 清单形态：组 db 的配置 `cfg' 原指项目 a（项目 a 由 `:configs' 关联、正常
;; 物化），项目 demo 仍用旧写法 `:groups ((db))' 引用组 db。`E' 把 cfg 改指
;; demo 后，demo 的旧引用被组侧配置接管并删除。

(defconst ebasecamp-config-write-test--e-migration-groups
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; groups.el --- `E' 跨文件迁移：组 db 的配置 cfg 指向项目 a\n"
   "\n"
   "(ebasecamp-define-group db\n"
   "  :title \"db\"\n"
   "  :scope per-project\n"
   "  :services ((postgres :image \"postgres:16\"))\n"
   "  :configs ((cfg :project a)))\n")
  "`E' 跨文件迁移的组文件：配置 cfg 原本关联项目 a。")

(defconst ebasecamp-config-write-test--e-migration-project-demo
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; projects/demo.el --- 项目定义（旧写法仍引用组 db）\n"
   "\n"
   "(ebasecamp-define-project demo\n"
   "  :title \"demo\"\n"
   "  :root \"/tmp/ebc-demo\"\n"
   "  :groups ((db)))\n")
  "`E' 跨文件迁移的项目文件：`:groups' 只有组 db 这条旧引用。")

(defun ebasecamp-config-write-test--write-e-migration-manifest ()
  "写 `E' 迁移用的清单：groups.el + projects/a.el + projects/demo.el。
项目 a 与 demo 分开建文件，保证「组定义」与「项目定义」确实跨文件（同文件会
走一次事务路径，测不到备份补偿）。"
  (ebasecamp-config-write-test--write-flat
   (ebasecamp-config-write-test--groups-file)
   ebasecamp-config-write-test--e-migration-groups)
  (make-directory
   (expand-file-name "projects/" ebasecamp-config-write-test--directory) t)
  (ebasecamp-config-write-test--write-flat
   (expand-file-name "projects/a.el" ebasecamp-config-write-test--directory)
   (concat ";;; -*- lexical-binding: t; -*-\n"
           "(ebasecamp-define-project a\n"
           "  :title \"a\"\n"
           "  :root \"/tmp/ebc-a\")\n"))
  (ebasecamp-config-write-test--write-flat
   (expand-file-name "projects/demo.el" ebasecamp-config-write-test--directory)
   ebasecamp-config-write-test--e-migration-project-demo))

(ert-deftest ebasecamp-config-write-test-e-migration-moves-group-ref-across-files ()
  "`E'（`update-config-project' + `migrate-legacy' t）跨文件迁移：
① 组文件出现新 `:project'；② 项目文件 `:groups' 消失；③ 零备份残留。

`temporary-file-directory' 显式绑到 `/tmp/'：本机 `TMPDIR' 指向仓库根
（2026-10-30 实测），不绑的话临时清单目录会落到工作树里。"
  (let ((temporary-file-directory "/tmp/"))
    (ebasecamp-config-write-test--with-directory
      (ebasecamp-config-write-test--write-e-migration-manifest)
      (should (null (plist-get (ebasecamp-config-load) :errors)))
      (let* ((groups-file (ebasecamp-config-write-test--groups-file))
             (projects-dir (expand-file-name "projects/"
                                             ebasecamp-config-write-test--directory))
             (project-file (expand-file-name "demo.el" projects-dir))
             (result (ebasecamp-config-write-update-config-project 'db 'cfg 'demo t))
             (groups-text (ebasecamp-config-write-test--read groups-file))
             (project-text (ebasecamp-config-write-test--read project-file)))
        (should (null (plist-get result :errors)))
        ;; ① 组文件：配置 cfg 的 `:project' 改为 demo，配置本身与组都保留
        (should (string-match-p "(cfg :project demo)" groups-text))
        (should (string-match-p "(ebasecamp-define-group db" groups-text))
        (should (eq 'demo (ebasecamp-model-config-project
                           (ebasecamp-model-config 'db 'cfg))))
        ;; ② 项目文件：旧 `:groups' 键整条消失，项目 form 其余键逐字节保留
        (should-not (string-match-p ":groups" project-text))
        (should (string-match-p "(ebasecamp-define-project demo" project-text))
        (should (string-match-p ":root \"/tmp/ebc-demo\")" project-text))
        ;; ③ 零备份残留：两次事务的备份都已删除（清单根与 projects/ 都查）
        (should-not (ebasecamp-config-write-test--leftovers))
        (should-not (directory-files
                     projects-dir nil
                     "\\(\\`\\.ebasecamp-\\|\\`\\.#\\|\\.bak\\'\\|~\\'\\)"))
        ;; 重载零错误：组侧配置是唯一有效引用，不会报重复组引用
        (should (null (plist-get (ebasecamp-config-load) :errors)))
        (should (equal '(cfg) (ebasecamp-config-write-test--configs-of 'db)))))))

;;; v0.5.3 批次 1：项目 :root 可选（写盘层）

(defconst ebasecamp-config-write-test--no-key-project
  (concat "(ebasecamp-define-project extra\n"
          "  :title \"extra\"\n"
          "  :root \"/tmp/ebc-extra\"\n"
          "  :shared-network nil\n"
          "  :export-file \"compose.override.yaml\")\n")
  "带无关键（`:shared-network' / `:export-file'）的项目文件内容。
供清空 `:root' 时验证无关键被原样保留。")

(ert-deftest ebasecamp-config-write-test-add-project-without-root ()
  "新增项目 root 为 nil：允许成功、文件不写 `:root' 键、加载零错误、model root 为 nil。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let ((file (ebasecamp-config-write-test--project-file "newproj")))
      (should-not (file-exists-p file))
      (let ((result (ebasecamp-config-write-add-project
                     'newproj "新项目" nil)))
        (should (null (plist-get result :errors)))
        (should (file-exists-p file))
        ;; 文件可被加载器读取：重新加载没有新增错误
        (should (null (plist-get (ebasecamp-config-load) :errors)))
        (let ((project (ebasecamp-model-project 'newproj)))
          (should project)
          (should (equal "新项目" (ebasecamp-project-title project)))
          (should-not (ebasecamp-project-root project)))
        ;; 落盘文本不含 `:root'（不是 `:root nil'）
        (should-not (string-match-p ":root"
                                    (ebasecamp-config-write-test--read file)))
        (should-not (ebasecamp-config-write-test--leftovers))))))

(ert-deftest ebasecamp-config-write-test-add-project-rejects-blank-root ()
  "root 为空串或纯空白仍拒绝（只有 nil 表示无根目录），且不产生文件。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (dolist (root '("" "   "))
      (ebasecamp-config-write-test--error-matching
       (lambda () (ebasecamp-config-write-add-project 'blankproj "空白" root))
       "根目录")
      (should-not (file-exists-p
                   (ebasecamp-config-write-test--project-file "blankproj"))))
    (should-not (ebasecamp-config-write-test--leftovers))))

(ert-deftest ebasecamp-config-write-test-update-project-clear-root ()
  "改项目传 clear-root：`:root' 键真正消失（不是 `:root nil'），无关键保留。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (ebasecamp-config-write-test--write-flat
     (ebasecamp-config-write-test--project-file "extra")
     ebasecamp-config-write-test--no-key-project)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    ;; app 原本有 :root → 清空后 model root 为 nil，:title 取新值
    (let ((result (ebasecamp-config-write-update-project 'app "应用" nil t)))
      (should (null (plist-get result :errors)))
      (let ((project (ebasecamp-model-project 'app)))
        (should (equal "应用" (ebasecamp-project-title project)))
        (should-not (ebasecamp-project-root project)))
      (let* ((text (ebasecamp-config-write-test--read
                    (ebasecamp-config-write-test--project-file "app")))
             (plist (cddr (ebasecamp-config-write-test--read-form-at
                           text "(ebasecamp-define-project app"))))
        (should (equal "应用" (plist-get plist :title)))
        ;; 键消失，而不是 `:root nil'
        (should-not (plist-member plist :root))
        (should-not (string-match-p ":root" text))))
    ;; 无关键（:shared-network / :export-file）在清空 :root 时保留
    (let ((result (ebasecamp-config-write-update-project
                   'extra "extra 应用" nil t)))
      (should (null (plist-get result :errors)))
      (let ((plist (cddr (ebasecamp-config-write-test--read-form-at
                          (ebasecamp-config-write-test--read
                           (ebasecamp-config-write-test--project-file "extra"))
                          "(ebasecamp-define-project extra"))))
        (should (equal "extra 应用" (plist-get plist :title)))
        (should-not (plist-member plist :root))
        (should (plist-member plist :shared-network))
        (should-not (plist-get plist :shared-network))
        (should (equal "compose.override.yaml"
                       (plist-get plist :export-file)))))
    (should-not (ebasecamp-config-write-test--leftovers))))

(ert-deftest ebasecamp-config-write-test-update-project-nil-root-keeps-file ()
  "root 传 nil 且不传 clear-root：不改 `:root'，同参数再次调用文件逐字节不变。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let ((file (ebasecamp-config-write-test--project-file "app")))
      ;; 首次：把 :title 改成「应用」，root 传 nil 不改 root
      (should (null (plist-get (ebasecamp-config-write-update-project
                                'app "应用" nil)
                              :errors)))
      ;; 同参数第二次：无改动 → 文件逐字节不变
      (let ((hash (ebasecamp-config-write-test--hash file)))
        (should (null (plist-get (ebasecamp-config-write-update-project
                                  'app "应用" nil)
                                :errors)))
        (should (equal hash (ebasecamp-config-write-test--hash file)))
        ;; nil root 不等于清空：原 :root 仍在
        (should (ebasecamp-project-root (ebasecamp-model-project 'app)))))
    (should-not (ebasecamp-config-write-test--leftovers))))

(ert-deftest ebasecamp-config-write-test-update-project-title-keeps-root-absent ()
  "无 root 项目改 `:title'：文件仍不含 `:root'（不得写出 `:root nil'）。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (should (null (plist-get (ebasecamp-config-write-add-project
                              'newproj "新项目" nil)
                             :errors)))
    (let* ((file (ebasecamp-config-write-test--project-file "newproj"))
           (result (ebasecamp-config-write-update-project
                    'newproj "改名" nil)))
      (should (null (plist-get result :errors)))
      (let* ((text (ebasecamp-config-write-test--read file))
             (plist (cddr (ebasecamp-config-write-test--read-form-at
                           text "(ebasecamp-define-project newproj"))))
        (should (equal "改名" (plist-get plist :title)))
        (should-not (plist-member plist :root))
        (should-not (string-match-p ":root" text)))
      (should (null (plist-get (ebasecamp-config-load) :errors)))
      (should-not (ebasecamp-config-write-test--leftovers)))))

(ert-deftest ebasecamp-config-write-test-update-project-rejects-root-with-clear ()
  "root 与 clear-root 同时非 nil：`user-error'（参数互斥），文件逐字节不变。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    (let* ((file (ebasecamp-config-write-test--project-file "app"))
           (hash (ebasecamp-config-write-test--hash file)))
      (ebasecamp-config-write-test--error-matching
       (lambda ()
         (ebasecamp-config-write-update-project 'app "应用" "/srv/app" t))
       "互斥")
      (should (equal hash (ebasecamp-config-write-test--hash file))))
    (should-not (ebasecamp-config-write-test--leftovers))))

;;; v0.7 批次 B3：#42 项目 :root 写入前 trim 并回写

(defun ebasecamp-config-write-test--read-project (name)
  "读回落盘项目 NAME 的定义 form 的属性 plist。
不经 model 层，断言的是真实落盘内容（与 `--read-group' 对称）。"
  (cddr (ebasecamp-config-write-test--read-form-at
         (ebasecamp-config-write-test--read
          (ebasecamp-config-write-test--project-file name))
         (format "(ebasecamp-define-project %s" name))))

(ert-deftest ebasecamp-config-write-test-add-project-trims-root ()
  "新增项目带首尾空白 root：落盘 `:root' 已 trim；nil / 纯空白 / 正常值语义不变。"
  (ebasecamp-config-write-test--with-directory
    (ebasecamp-config-write-test--write-manifest
     ebasecamp-config-write-test--config-groups)
    (should (null (plist-get (ebasecamp-config-load) :errors)))
    ;; ① 主断言：带空白 → 落盘 :root 已 trim（读回落盘文本 + model 槽）
    (should (null (plist-get (ebasecamp-config-write-add-project
                              'trimproj "空白" "  /srv/app  ")
                             :errors)))
    (should (equal "/srv/app"
                   (plist-get (ebasecamp-config-write-test--read-project "trimproj")
                              :root)))
    (should (equal "/srv/app"
                   (ebasecamp-project-root (ebasecamp-model-project 'trimproj))))
    (should-not (string-match-p
                 "  /srv/app  "
                 (ebasecamp-config-write-test--read
                  (ebasecamp-config-write-test--project-file "trimproj"))))
    ;; ② nil → 不写 `:root' 键（不是 `:root nil'）
    (should (null (plist-get (ebasecamp-config-write-add-project
                              'nilrootproj "无根" nil)
                             :errors)))
    (should-not (plist-member
                 (ebasecamp-config-write-test--read-project "nilrootproj")
                 :root))
    ;; ③ 纯空白 → user-error，且不产生文件
    (ebasecamp-config-write-test--error-matching
     (lambda () (ebasecamp-config-write-add-project 'blanktrim "空白" "   "))
     "根目录")
    (should-not (file-exists-p
                 (ebasecamp-config-write-test--project-file "blanktrim")))
    ;; ④ 正常值 → 落盘不变
    (should (null (plist-get (ebasecamp-config-write-add-project
                              'plainproj "正常" "/srv/app")
                             :errors)))
    (should (equal "/srv/app"
                   (plist-get (ebasecamp-config-write-test--read-project "plainproj")
                              :root)))
    (should (equal "/srv/app"
                   (ebasecamp-project-root (ebasecamp-model-project 'plainproj))))
    (should-not (ebasecamp-config-write-test--leftovers))))

(provide 'ebasecamp-config-write-tests)
;;; ebasecamp-config-write-tests.el ends here
