;;; ebasecamp-docker.el --- ebasecamp docker CLI 进程封装与输出解析 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.5.3
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块只做「进程 + 解析」两件事，不判断任何业务语义（哪些服务该起、
;; 容器归属哪个项目、状态如何聚合）—— 那些在 status / command 层。对外提供：
;;
;; 1. `ebasecamp-docker-run-sync' / `ebasecamp-docker-run-async'：执行 docker
;;    CLI，捕获 stdout / stderr / 退出码，超时 kill 进程；
;; 2. `ebasecamp-docker-check-compose'：`docker compose -f FILE config -q'
;;    校验，按「退出码 + stderr」双判据给出结论与 warning 列表；
;; 3. `ebasecamp-docker-ps' / `ebasecamp-docker-parse-ps-output' /
;;    `ebasecamp-docker-parse-labels'：容器列表采集与纯解析；
;; 4. `ebasecamp-docker-version-check'：compose 版本检测；
;;    `ebasecamp-docker-classify-error'：错误归一化（含权限错误）。
;;
;; 实测约束（Docker 29.9.1 / Compose 5.6.0，2026-10-22）：
;;
;; - `docker ps' 的长字段（ID / Labels / Command 等）默认被截断并以 `…' 结尾，
;;   必须显式 `--no-trunc'，否则标签与容器归属判定失效；
;; - `--format '{{json .}}'' 每行是一个 16 键 JSON 对象，键为：
;;   Command CreatedAt HealthStatus ID Image Labels LocalVolumes Mounts Names
;;   Networks Platform Ports RunningFor Size State Status；
;; - `Labels' 是逗号拼接的**单个字符串**（如 `a=1,b=2'），值内可能含 `=' 与
;;   `,'；按第一个 `=' 切分可恢复键与值，但值内含逗号时无法与下一个标签区分
;;   （docker 不转义，只能按已知前缀猜测）。`Mounts' 同样是逗号串，本模块只
;;   保留原字符串，不做切分；
;; - `State' 是枚举（running / exited / created …），`Status' 是人类可读文本；
;; - 无健康检查时 `HealthStatus' 为 "none"（并非空串），本模块原样保留，
;;   只有空串才归一为 nil；
;; - `docker compose config -q'：合法文件零输出且 exit 0；YAML / schema 错
;;   exit 1 且 stderr 含错误；未定义变量只产生 `level=warning' 行且 exit 0 ——
;;   因此退出码不足以判错，必须同时检查 stderr 是否含 `level=error'；
;; - 权限不足（docker socket）典型 stderr 含 `permission denied'。
;;
;; 安全约定：本模块只执行命令并解析 stdout / stderr，不读取、不打印、不落盘
;; 任何密钥；`${VAR}' 引用由 docker 自身处理，本模块不做插值、不做转义。

;;; Code:

(require 'cl-lib)
(require 'json)

(defcustom ebasecamp-docker-executable "docker"
  "docker 可执行文件路径。"
  :type 'string
  :group 'ebasecamp)

(defcustom ebasecamp-docker-timeout-seconds 30
  "单次 docker 调用的默认超时（秒）。
超时后进程被 kill 并 signal `ebasecamp-docker-timeout'（同步）或回调
`(:error ebasecamp-docker-timeout …)'（异步）。"
  :type 'number
  :group 'ebasecamp)

(define-error 'ebasecamp-docker-error "ebasecamp docker 调用失败")
(define-error 'ebasecamp-docker-permission
  "ebasecamp 无权访问 docker" 'ebasecamp-docker-error)
(define-error 'ebasecamp-docker-timeout
  "ebasecamp docker 调用超时" 'ebasecamp-docker-error)
(define-error 'ebasecamp-docker-exit
  "ebasecamp docker 命令非零退出" 'ebasecamp-docker-error)

(defconst ebasecamp-docker--supported-compose-major 5
  "本插件实测验证的 Compose 主版本。
其他主版本不视为错误，只给出警告：语义差异（尤其 `config --format json'
的键集）可能导致导入映射偏差。")

(defvar ebasecamp-docker--run-sync-function nil
  "同步执行注入点，仅供测试替换。
非 nil 时 `ebasecamp-docker-run-sync' 改用它，签名 `(ARGS TIMEOUT)'，
返回值与 `ebasecamp-docker-run-sync' 相同；为 nil 时走真实进程实现。
`ebasecamp-docker-ps' / `ebasecamp-docker-check-compose' /
`ebasecamp-docker-version-check' 都经由 `ebasecamp-docker-run-sync'，
因此测试可在无 docker 环境下覆盖它们的控制流。")

;;; 小工具

(defun ebasecamp-docker--command-string (args)
  "把 ARGS 拼成供错误信息使用的单行命令文本（不执行任何东西）。"
  (mapconcat #'identity (cons ebasecamp-docker-executable args) " "))

(defun ebasecamp-docker--buffer-string (buffer)
  "返回 BUFFER 的完整内容；BUFFER 已死或不是 buffer 时返回空串。"
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-string))
    ""))

(defun ebasecamp-docker--first-line (text)
  "返回 TEXT 的第一行非空内容；没有时返回 \"无输出\"。"
  (or (car (split-string (or text "") "\n" t)) "无输出"))

(defun ebasecamp-docker--level-lines (text marker)
  "返回 TEXT 中所有含 MARKER 的行，保持原顺序；空行被丢弃。
用于从 compose 的 stderr 中挑出 `level=warning' / `level=error' 行。"
  (cl-remove-if-not (lambda (line) (string-match-p (regexp-quote marker) line))
                    (split-string (or text "") "\n" t)))

;;; 同步执行

(defun ebasecamp-docker--run-sync-process (args timeout)
  "真实执行 docker ARGS 并同步等待，返回 (:exit N :stdout STR :stderr STR)。
超过 TIMEOUT 秒时 kill 进程并 signal `ebasecamp-docker-timeout'。
不因非零退出而 signal —— 由调用方判断。"
  (let* ((stdout-buffer (generate-new-buffer " *ebasecamp-docker-out*"))
         (stderr-buffer (generate-new-buffer " *ebasecamp-docker-err*"))
         ;; stderr 必须用自建 pipe process：直接把 buffer 传给 :stderr 时，
         ;; Emacs 内部 pipe 的默认 sentinel 会往该 buffer 追加
         ;; "Process ... stderr finished"，污染 stderr 原文
         (stderr-process (make-pipe-process
                          :name "ebasecamp-docker-stderr"
                          :buffer stderr-buffer
                          :noquery t
                          :sentinel #'ignore
                          :coding 'utf-8-unix))
         (deadline (+ (float-time) (or timeout ebasecamp-docker-timeout-seconds)))
         (process nil)
         (timed-out nil))
    (unwind-protect
        (progn
          (setq process (make-process
                         :name "ebasecamp-docker"
                         :command (cons ebasecamp-docker-executable args)
                         :buffer stdout-buffer
                         :stderr stderr-process
                         :connection-type 'pipe
                         :noquery t
                         ;; 默认 sentinel 会把 "exited abnormally" 写进 stdout
                         ;; buffer，污染解析结果
                         :sentinel #'ignore
                         :coding 'utf-8-unix))
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process 0.05))
          (when (process-live-p process)
            (setq timed-out t)
            (ignore-errors (kill-process process)))
          (if timed-out
              (signal 'ebasecamp-docker-timeout
                      (list (format "%s 超过 %s 秒未返回"
                                    (ebasecamp-docker--command-string args)
                                    timeout)))
            (list :exit (process-exit-status process)
                  :stdout (ebasecamp-docker--buffer-string stdout-buffer)
                  :stderr (ebasecamp-docker--buffer-string stderr-buffer))))
      (when (process-live-p stderr-process)
        (delete-process stderr-process))
      (when (buffer-live-p stdout-buffer)
        (kill-buffer stdout-buffer))
      (when (buffer-live-p stderr-buffer)
        (kill-buffer stderr-buffer)))))

(cl-defun ebasecamp-docker-run-sync (args &key timeout)
  "同步执行 docker ARGS，返回 (:exit N :stdout STR :stderr STR)。
ARGS 为字符串列表（不经 shell，元素原样传给进程，不受引号/花括号转义影响）。
TIMEOUT 为秒，缺省 `ebasecamp-docker-timeout-seconds'；超时 kill 进程并
signal `ebasecamp-docker-timeout'。
非零退出**不** signal：调用方按需用 `ebasecamp-docker-classify-error' 判定。"
  (funcall (or ebasecamp-docker--run-sync-function
               #'ebasecamp-docker--run-sync-process)
           args
           (or timeout ebasecamp-docker-timeout-seconds)))

;;; 异步执行

(cl-defun ebasecamp-docker--run-async-process (args callback timeout)
  "真实异步执行 docker ARGS，返回 process 对象。
CALLBACK 恰好被调用一次：正常结束时收到
`(:exit N :stdout STR :stderr STR)'，超时收到
`(:error ebasecamp-docker-timeout :message STR)'。
超时会先 kill 进程（SIGKILL）再回调；回调前已清理临时 buffer 与 timer，
因此 sentinel 与 timer 不会重复回调。"
  (let* ((stdout-buffer (generate-new-buffer " *ebasecamp-docker-out*"))
         (stderr-buffer (generate-new-buffer " *ebasecamp-docker-err*"))
         ;; 同同步实现：stderr 走自建 pipe process，避免默认 sentinel 往
         ;; stderr buffer 追加 "Process ... stderr finished"
         (stderr-process (make-pipe-process
                          :name "ebasecamp-docker-stderr"
                          :buffer stderr-buffer
                          :noquery t
                          :sentinel #'ignore
                          :coding 'utf-8-unix))
         (finished nil)
         (timer nil)
         (process nil))
    (cl-labels
        ((cleanup ()
                  (when (process-live-p stderr-process)
                    (delete-process stderr-process))
                  (when (buffer-live-p stdout-buffer)
                    (kill-buffer stdout-buffer))
                  (when (buffer-live-p stderr-buffer)
                    (kill-buffer stderr-buffer))
                  (when (timerp timer)
                    (cancel-timer timer))))
      (setq process
            (make-process
             :name "ebasecamp-docker"
             :command (cons ebasecamp-docker-executable args)
             :buffer stdout-buffer
             :stderr stderr-process
             :connection-type 'pipe
             :noquery t
             :coding 'utf-8-unix
             :sentinel
             (lambda (proc _event)
               (unless (process-live-p proc)
                 (unless finished
                   (setq finished t)
                   (let ((result (list :exit (process-exit-status proc)
                                       :stdout (ebasecamp-docker--buffer-string
                                                stdout-buffer)
                                       :stderr (ebasecamp-docker--buffer-string
                                                stderr-buffer))))
                     (cleanup)
                     (funcall callback result)))))))
      (setq timer
            (run-at-time
             timeout nil
             (lambda ()
               ;; 先置 finished，避免 kill 触发的 sentinel 抢先投递 exit 结果
               (unless finished
                 (setq finished t)
                 (when (process-live-p process)
                   (ignore-errors (kill-process process)))
                 (cleanup)
                 (funcall callback
                          (list :error 'ebasecamp-docker-timeout
                                :message (format "%s 超过 %s 秒未返回"
                                                 (ebasecamp-docker--command-string
                                                  args)
                                                 timeout)))))))
      process)))

(cl-defun ebasecamp-docker-run-async (args callback &key timeout)
  "异步执行 docker ARGS，返回 process 对象，不阻塞 Emacs。
ARGS 同 `ebasecamp-docker-run-sync'。CALLBACK 在进程 sentinel 或超时 timer
中执行，收到 `(:exit N :stdout STR :stderr STR)'（正常结束，非零退出也不
signal）或 `(:error ebasecamp-docker-timeout :message STR)'（超时且进程已
被 kill）。TIMEOUT 缺省 `ebasecamp-docker-timeout-seconds'。"
  (ebasecamp-docker--run-async-process
   args callback (or timeout ebasecamp-docker-timeout-seconds)))

;;; 错误归一化

(defun ebasecamp-docker-classify-error (exit stderr)
  "把退出码 EXIT 与 stderr STDERR 归一为 plist。
返回：
- `(:type ok)'：EXIT 为 0；
- `(:type permission :hint STR)'：STDERR 含 `permission denied'（大小写不敏感）；
- `(:type exit :exit N :stderr S)'：其余非零退出。
STDERR 为 nil 时按空串处理。纯函数，不执行任何命令。"
  (let ((stderr (or stderr "")))
    (cond
     ((and (numberp exit) (zerop exit))
      (list :type 'ok))
     ((string-match-p "permission denied" (downcase stderr))
      (list :type 'permission
            :hint "将用户加入 docker 组或修正 socket 权限"))
     (t
      (list :type 'exit :exit exit :stderr stderr)))))

;;; compose 校验

(defun ebasecamp-docker-check-compose (file &optional root)
  "用 `docker compose -f FILE config -q' 校验 compose 文件 FILE。
返回 plist：
- `:ok' —— 退出码为 0 **且** stderr 不含 `level=error'。退出码 0 不足以判定
  通过（未定义变量只警告），故为双判据；
- `:exit' —— 退出码；
- `:stderr' —— stderr 原文（失败时供 UI 展开）；
- `:warnings' —— stderr 中所有 `level=warning' 行（字符串列表，按原顺序），
  warning 不影响 `:ok'。
FILE 会被展开为绝对路径后传给 docker。
ROOT 非 nil 时在 `-f FILE' 之后、`config' 之前注入 `--project-directory'（经
`expand-file-name' 绝对化）——该 flag 是 docker compose 的**根级** flag，必须
位于子命令之前，用于把清单里的相对路径（含顶层 configs/secrets 的 `file:'）
按项目 root 解析。ROOT 必须与 `ebasecamp-command-compose-args' 派发时用的
**同一基准**，否则会重现「校验通过、启动炸」。ROOT 为 nil 时命令行与不传该
参数时逐字节一致（回退到 compose 文件所在目录为基准）。"
  (let* ((args (append (list "compose" "-f" (expand-file-name file))
                       (when root
                         (list "--project-directory" (expand-file-name root)))
                       (list "config" "-q")))
         (result (ebasecamp-docker-run-sync args))
         (exit (plist-get result :exit))
         (stderr (or (plist-get result :stderr) "")))
    (list :ok (and (numberp exit)
                   (zerop exit)
                   (null (ebasecamp-docker--level-lines stderr "level=error")))
          :exit exit
          :stderr stderr
          :warnings (ebasecamp-docker--level-lines stderr "level=warning"))))

;;; 容器列表

(defun ebasecamp-docker-parse-labels (string)
  "把 docker `Labels' 字段的逗号串 STRING 解析为 alist（键值均为字符串）。
STRING 形如 \"k1=v1,k2=v2\"：
- 先按 `,' 切分，空段忽略；每段再按**第一个** `=' 切分为键与值；
- 值可以是空串（docker 会输出 `key=' 这类空值项）；
- 值内含 `=' 时完整保留（如 \"a=b=c\" → (\"a\" . \"b=c\")）；
- 值内含 `,' 时**无法**与下一个标签区分（docker 不转义），会被错误切开 ——
  这是该输出格式的固有限制，调用方按已知前缀取值即可规避。
STRING 为 nil 或空串时返回 nil。纯函数。"
  (let ((labels nil))
    (dolist (segment (split-string (or string "") "," t))
      (let ((equals (string-match "=" segment)))
        (when equals
          (push (cons (substring segment 0 equals)
                      (substring segment (1+ equals)))
                labels))))
    (nreverse labels)))

(defun ebasecamp-docker--stringify-json-keys (object)
  "把 JSON 对象 OBJECT（alist）的 symbol 键转成字符串键，返回值 alist。
Emacs 的 `json-parse-string' 没有 key 类型选项：合法标识符形式的键（如
\"ID\"、\"HealthStatus\"）一律被转成 symbol，其余保留字符串。解析后统一
规范化，使下游只需按字符串键取值。"
  (mapcar (lambda (pair)
            (cons (if (symbolp (car pair))
                      (symbol-name (car pair))
                    (car pair))
                  (cdr pair)))
          object))

(defun ebasecamp-docker--json-field (object key)
  "从 JSON 对象 OBJECT（键已规范化为字符串的 alist）取 KEY 的字符串值。
缺失或值不是字符串（如 null）时返回 nil。"
  (let ((value (alist-get key object nil nil #'equal)))
    (and (stringp value) value)))

(defun ebasecamp-docker--container-from-json (object)
  "把 `docker ps --format {{json .}}` 的单行对象 OBJECT 转为容器 plist。
字段：`:id' `:names' `:image' `:state' `:status' `:health' `:labels' `:ports'
以及从标签解出的 `:project' `:group' `:service' `:scope'。"
  (let* ((labels (ebasecamp-docker-parse-labels
                  (ebasecamp-docker--json-field object "Labels")))
         (health (ebasecamp-docker--json-field object "HealthStatus")))
    (list :id (ebasecamp-docker--json-field object "ID")
          :names (ebasecamp-docker--json-field object "Names")
          :image (ebasecamp-docker--json-field object "Image")
          :state (ebasecamp-docker--json-field object "State")
          :status (ebasecamp-docker--json-field object "Status")
          ;; 实测无健康检查时为 "none"，只有空串才归一为 nil
          :health (and health (not (equal health "")) health)
          :labels labels
          ;; Ports 原样保留（未做结构化解析，空串保留为空串）
          :ports (or (ebasecamp-docker--json-field object "Ports") "")
          :project (cdr (assoc "ebasecamp.project" labels))
          :group (cdr (assoc "ebasecamp.group" labels))
          :service (cdr (assoc "ebasecamp.service" labels))
          :scope (cdr (assoc "ebasecamp.scope" labels)))))

(defun ebasecamp-docker-parse-ps-output (string)
  "解析 `docker ps --format {{json .}}` 的输出 STRING，返回容器 plist 列表。
逐行 `json-parse-string'（`:object-type alist'）后转容器 plist（字段见
`ebasecamp-docker--container-from-json'）。**无法解析的行被忽略**（不报错、
不计数），空行同样跳过；STRING 为 nil 或空串时返回 nil。纯函数。"
  (let ((containers nil))
    (dolist (line (split-string (or string "") "\n" t))
      (let ((object (condition-case nil
                        (json-parse-string line :object-type 'alist)
                      (error nil))))
        ;; 注意用 consp 而非 listp：解析失败返回 nil，而 (listp nil) 为 t
        (when (consp object)
          (push (ebasecamp-docker--container-from-json
                 (ebasecamp-docker--stringify-json-keys object))
                containers))))
    (nreverse containers)))

(defun ebasecamp-docker-ps ()
  "采集全部 ebasecamp 托管容器，返回容器 plist 列表。
执行 `docker ps -a --no-trunc --filter label=ebasecamp.managed=true
--format {{json .}}`（`--no-trunc' 是必需项：否则 ID 与 Labels 被截断）。
非零退出时 signal：权限错误 signal `ebasecamp-docker-permission'（携带
`:hint' 与 `:stderr'），其余 signal `ebasecamp-docker-exit'（携带 `:exit'
与 `:stderr'）。"
  (let* ((result (ebasecamp-docker-run-sync
                  (list "ps" "-a" "--no-trunc"
                        "--filter" "label=ebasecamp.managed=true"
                        "--format" "{{json .}}")))
         (exit (plist-get result :exit))
         (stderr (or (plist-get result :stderr) ""))
         (classification (ebasecamp-docker-classify-error exit stderr)))
    (pcase (plist-get classification :type)
      ('ok
       (ebasecamp-docker-parse-ps-output (plist-get result :stdout)))
      ('permission
       (signal 'ebasecamp-docker-permission
               (list :hint (plist-get classification :hint)
                     :stderr stderr)))
      (_
       (signal 'ebasecamp-docker-exit
               (list :exit exit :stderr stderr))))))

;;; 版本检测

(defun ebasecamp-docker--parse-version (text)
  "从 TEXT 中提取第一个三段版本号（如 \"5.6.0\"），找不到返回 nil。"
  (when (and (stringp text)
             (string-match "\\([0-9]+\\)\\.\\([0-9]+\\)\\.\\([0-9]+\\)" text))
    (match-string 0 text)))

(defun ebasecamp-docker-version-check ()
  "检测 `docker compose version'，返回
`(:compose-version VER :ok BOOL :warning STR-or-nil)'。
- 主版本为 `ebasecamp-docker--supported-compose-major'（5）时 `:ok' 为 t；
- 其他主版本 `:ok' 为 nil，`:warning' 提示「本插件按 Compose 5.x 验证，
  其他主版本行为可能不同」；
- 命令失败或取不到版本号时 `:ok' 为 nil，`:warning' 含失败原因。
不 signal：版本不符只降级为警告，由 UI 决定如何呈现。"
  (let* ((result (ebasecamp-docker-run-sync (list "compose" "version")))
         (exit (plist-get result :exit))
         (stdout (or (plist-get result :stdout) ""))
         (stderr (or (plist-get result :stderr) ""))
         (version (ebasecamp-docker--parse-version stdout)))
    (cond
     ((not (and (numberp exit) (zerop exit)))
      (list :compose-version nil
            :ok nil
            :warning (format "无法执行 `docker compose version'（退出码 %s）：%s"
                             exit
                             (ebasecamp-docker--first-line
                              (concat stderr stdout)))))
     ((null version)
      (list :compose-version nil
            :ok nil
            :warning (format "无法从 `docker compose version' 输出解析版本号：%s"
                             (ebasecamp-docker--first-line stdout))))
     (t
      (let ((major (string-to-number (car (split-string version "\\.")))))
        (if (= major ebasecamp-docker--supported-compose-major)
            (list :compose-version version :ok t :warning nil)
          (list :compose-version version
                :ok nil
                :warning (format
                          "检测到 Docker Compose %s；本插件按 Compose %d.x 验证，其他主版本行为可能不同"
                          version
                          ebasecamp-docker--supported-compose-major))))))))

(provide 'ebasecamp-docker)
;;; ebasecamp-docker.el ends here
