;;; ebasecamp-docker-tests.el --- ebasecamp docker 适配层测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T1.4 docker 适配层（进程封装 + 输出解析）的 ERT 测试。
;;
;; 覆盖范围：`parse-labels' / `parse-ps-output' 纯函数解析（含实测 16 键 JSON
;; fixture、Labels 逗号串、HealthStatus 空串、非法行忽略、多行）、
;; `classify-error' 三类归类、`check-compose' 双判据（退出码 + stderr）、
;; `run-sync' / `run-async' 的输出捕获与超时 kill、`version-check' 主版本判定、
;; `ps' 的命令行不变量（--no-trunc / filter / format）。
;;
;; 不依赖真实 docker 守护进程的做法：
;; - 纯函数测试直接喂字符串；
;; - 需要执行进程的测试把 `ebasecamp-docker-executable' 绑成 "sh"；
;; - 需要伪造 docker 输出的测试把 `ebasecamp-docker--run-sync-function' 绑成
;;   返回预设 plist 的 lambda（`ps' / `version-check' 走该注入点）。
;; 仅 `check-compose' 的三项测试真实调用 docker，docker 不可用时跳过。
;;
;; fixture：test/fixtures/docker-ps-managed.jsonl 为 Docker 29.9.1 实测输出
;; （`docker ps -a --no-trunc --format '{{json .}}'` 两行，各 16 键）。

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ebasecamp-docker)

;;; 测试脚手架

(defconst ebasecamp-docker-test--fixtures-directory
  (expand-file-name
   "fixtures/"
   (file-name-directory (or load-file-name buffer-file-name)))
  "本测试所用 fixture 目录的绝对路径。")

(defun ebasecamp-docker-test--fixture-lines (name)
  "读取 fixtures 目录下的 NAME，返回非空行列表。"
  (with-temp-buffer
    (insert-file-contents (expand-file-name name
                                           ebasecamp-docker-test--fixtures-directory))
    (split-string (buffer-string) "\n" t)))

(defun ebasecamp-docker-test--wait (predicate &optional timeout)
  "有界等待 PREDICATE 返回非 nil，最长 TIMEOUT 秒（默认 10）。
返回 PREDICATE 的最后取值；不做无限循环。"
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defmacro ebasecamp-docker-test--with-fake-sync (exit stdout stderr &rest body)
  "在伪造的同步执行结果（EXIT / STDOUT / STDERR）下执行 BODY。"
  (declare (indent 3) (debug t))
  `(let ((ebasecamp-docker--run-sync-function
          (lambda (_args _timeout)
            (list :exit ,exit :stdout ,stdout :stderr ,stderr))))
     ,@body))

;;; 1–3. parse-labels

(ert-deftest ebasecamp-docker-test-parse-labels-basic ()
  "逗号串按第一个 = 切分为 alist。"
  (should (equal '(("a" . "1") ("b" . "2"))
                 (ebasecamp-docker-parse-labels "a=1,b=2"))))

(ert-deftest ebasecamp-docker-test-parse-labels-empty ()
  "空值保留，空输入返回 nil，空段被忽略。"
  (should (equal '(("a" . "")) (ebasecamp-docker-parse-labels "a=")))
  (should-not (ebasecamp-docker-parse-labels ""))
  (should-not (ebasecamp-docker-parse-labels nil))
  ;; docker 实测会输出 `com.docker.compose.depends_on=' 这类空值项，
  ;; 相邻逗号产生的空段必须被忽略
  (should (equal '(("a" . "1") ("c" . "3"))
                 (ebasecamp-docker-parse-labels "a=1,,c=3,"))))

(ert-deftest ebasecamp-docker-test-parse-labels-value-with-equals ()
  "值内的 = 原样保留（按第一个 = 切分）。"
  (should (equal '(("a" . "b=c")) (ebasecamp-docker-parse-labels "a=b=c")))
  ;; 实测标签值可能含路径与冒号
  (should (equal '(("com.docker.compose.project.config_files"
                    . "/home/u/docker-compose.yml"))
                 (ebasecamp-docker-parse-labels
                  "com.docker.compose.project.config_files=/home/u/docker-compose.yml"))))

;;; 4–7. parse-ps-output

(ert-deftest ebasecamp-docker-test-parse-ps-output-fixture-fields ()
  "用实测 16 键 JSON fixture 断言字段与 ebasecamp.* 标签解出结果。"
  (let* ((line (car (ebasecamp-docker-test--fixture-lines
                     "docker-ps-managed.jsonl")))
         (containers (ebasecamp-docker-parse-ps-output line))
         (container (car containers)))
    (should (= 1 (length containers)))
    (should (equal "2e3c588d4ce3685e98625f7ce1fcb33f6235d3b7dfb2f5a9e87b61f579c64c70"
                   (plist-get container :id)))
    (should (equal "t14-probe-a" (plist-get container :names)))
    (should (equal "alpine:3.20" (plist-get container :image)))
    (should (equal "created" (plist-get container :state)))
    (should (equal "Created" (plist-get container :status)))
    ;; Docker 29 无健康检查时 HealthStatus 为 "none"（非空串），按原值保留
    (should (equal "none" (plist-get container :health)))
    (should (equal "" (plist-get container :ports)))
    (should (equal "myapp" (plist-get container :project)))
    (should (equal "db" (plist-get container :group)))
    (should (equal "mysql" (plist-get container :service)))
    (should (equal "per-project" (plist-get container :scope)))
    ;; labels 为完整 alist（含 com.docker.compose.* 与 ebasecamp.*）
    (should (equal "true" (cdr (assoc "ebasecamp.managed"
                                      (plist-get container :labels)))))
    (should (equal "mysql" (cdr (assoc "com.docker.compose.service"
                                       (plist-get container :labels)))))))

(ert-deftest ebasecamp-docker-test-parse-ps-output-empty-health ()
  "HealthStatus 为空串时 :health 为 nil。"
  (let* ((line (car (ebasecamp-docker-test--fixture-lines
                     "docker-ps-managed.jsonl")))
         (patched (replace-regexp-in-string
                   "\"HealthStatus\":\"none\"" "\"HealthStatus\":\"\"" line t t))
         (container (car (ebasecamp-docker-parse-ps-output patched))))
    (should-not (plist-get container :health))
    (should (equal "t14-probe-a" (plist-get container :names)))))

(ert-deftest ebasecamp-docker-test-parse-ps-output-multiple ()
  "两行输入解析为两个容器，标签各自独立。"
  (let* ((lines (ebasecamp-docker-test--fixture-lines "docker-ps-managed.jsonl"))
         (containers (ebasecamp-docker-parse-ps-output
                      (mapconcat #'identity lines "\n"))))
    (should (= 2 (length lines)))
    (should (= 2 (length containers)))
    (should (equal '("t14-probe-a" "t14-probe-b")
                   (mapcar (lambda (c) (plist-get c :names)) containers)))
    (should (equal '("per-project" "shared")
                   (mapcar (lambda (c) (plist-get c :scope)) containers)))
    (should (equal '("db" "mysql")
                   (mapcar (lambda (c) (plist-get c :group)) containers)))))

(ert-deftest ebasecamp-docker-test-parse-ps-output-ignores-invalid-line ()
  "无法解析的行被忽略，其余行正常解析；空输入返回 nil。"
  (let* ((lines (ebasecamp-docker-test--fixture-lines "docker-ps-managed.jsonl"))
         (containers (ebasecamp-docker-parse-ps-output
                      (mapconcat #'identity
                                 (list (nth 0 lines)
                                       "not a json line"
                                       ""
                                       (nth 1 lines))
                                 "\n"))))
    (should (= 2 (length containers)))
    (should (equal '("t14-probe-a" "t14-probe-b")
                   (mapcar (lambda (c) (plist-get c :names)) containers)))
    (should-not (ebasecamp-docker-parse-ps-output ""))
    (should-not (ebasecamp-docker-parse-ps-output "\n\n"))))

;;; 8–10. classify-error

(ert-deftest ebasecamp-docker-test-classify-error-ok ()
  "exit 0 归类为 ok。"
  (should (equal '(:type ok) (ebasecamp-docker-classify-error 0 "")))
  (should (equal '(:type ok)
                 (ebasecamp-docker-classify-error
                  0 "level=warning msg=\"The \\\"X\\\" variable is not set\""))))

(ert-deftest ebasecamp-docker-test-classify-error-permission ()
  "stderr 含 permission denied（大小写不敏感）归类为 permission 并带修复提示。"
  (dolist (stderr '("permission denied while trying to connect to the Docker daemon socket"
                    "Permission Denied: /var/run/docker.sock"))
    (let ((result (ebasecamp-docker-classify-error 1 stderr)))
      (should (eq 'permission (plist-get result :type)))
      (should (stringp (plist-get result :hint)))
      (should (string-match-p "docker 组" (plist-get result :hint))))))

(ert-deftest ebasecamp-docker-test-classify-error-exit ()
  "普通非零退出归类为 exit 并保留退出码与 stderr。"
  (let ((result (ebasecamp-docker-classify-error 1 "invalid containerPort: bad")))
    (should (eq 'exit (plist-get result :type)))
    (should (= 1 (plist-get result :exit)))
    (should (equal "invalid containerPort: bad" (plist-get result :stderr)))))

;;; 11–13. check-compose（真实 docker，不可用时跳过）

(defmacro ebasecamp-docker-test--with-compose-file (content &rest body)
  "把 CONTENT 写入临时 compose 文件并在 BODY 中绑定 `file' 为其实路径。"
  (declare (indent 1) (debug t))
  `(let* ((dir (make-temp-file "ebasecamp-docker-test-" t))
          (file (expand-file-name "compose.yaml" dir)))
     (unwind-protect
         (progn
           (with-temp-file file (insert ,content))
           (let ((file file)) ,@body))
       (ignore-errors (delete-directory dir t)))))

(ert-deftest ebasecamp-docker-test-check-compose-valid ()
  "合法 compose 返回 :ok t 与 :exit 0。"
  (unless (executable-find "docker") (ert-skip "docker 不可用"))
  (ebasecamp-docker-test--with-compose-file
      "services:\n  web:\n    image: alpine:3.20\n"
    (let ((result (ebasecamp-docker-check-compose file)))
      (should (plist-get result :ok))
      (should (= 0 (plist-get result :exit))))))

(ert-deftest ebasecamp-docker-test-check-compose-invalid ()
  "非法 compose（schema 错）返回 :ok nil 与非零退出码，stderr 保留原文。"
  (unless (executable-find "docker") (ert-skip "docker 不可用"))
  (ebasecamp-docker-test--with-compose-file
      "services:\n  web:\n    image: alpine:3.20\n    ports:\n      - \"bad\"\n"
    (let ((result (ebasecamp-docker-check-compose file)))
      (should-not (plist-get result :ok))
      (should (/= 0 (plist-get result :exit)))
      (should (stringp (plist-get result :stderr)))
      (should (> (length (plist-get result :stderr)) 0)))))

(ert-deftest ebasecamp-docker-test-check-compose-undefined-variable-warns ()
  "未定义变量只产 warning 且 exit 0，:ok 仍为 t，:warnings 非空。"
  (unless (executable-find "docker") (ert-skip "docker 不可用"))
  (ebasecamp-docker-test--with-compose-file
      "services:\n  web:\n    image: alpine:3.20\n    environment:\n      FOO: \"${EBASECAMP_UNDEFINED_VAR}\"\n"
    (let ((result (ebasecamp-docker-check-compose file)))
      (should (plist-get result :ok))
      (should (= 0 (plist-get result :exit)))
      (should (plist-get result :warnings))
      (should (cl-every (lambda (line) (string-match-p "level=warning" line))
                        (plist-get result :warnings))))))

;;; 14–16. run-sync / run-async

(ert-deftest ebasecamp-docker-test-run-sync-captures-streams ()
  "同步执行捕获 stdout / stderr / 退出码，非零退出不 signal。"
  (let ((ebasecamp-docker-executable "sh"))
    (let ((result (ebasecamp-docker-run-sync
                   (list "-c" "printf out; printf err 1>&2; exit 3"))))
      (should (= 3 (plist-get result :exit)))
      (should (equal "out" (plist-get result :stdout)))
      (should (equal "err" (plist-get result :stderr))))
    (let ((result (ebasecamp-docker-run-sync (list "-c" "printf ok"))))
      (should (= 0 (plist-get result :exit)))
      (should (equal "ok" (plist-get result :stdout)))
      (should (equal "" (plist-get result :stderr))))))

(ert-deftest ebasecamp-docker-test-run-sync-timeout ()
  "同步执行超时 signal ebasecamp-docker-timeout。"
  (let ((ebasecamp-docker-executable "sh")
        (t0 (float-time)))
    (should-error (ebasecamp-docker-run-sync (list "-c" "sleep 3") :timeout 0.2)
                  :type 'ebasecamp-docker-timeout)
    ;; 必须真的提前返回，而不是等 sleep 结束
    (should (< (- (float-time) t0) 2.5))))

(ert-deftest ebasecamp-docker-test-run-async-captures-streams ()
  "异步执行在回调中给出 :exit / :stdout / :stderr。"
  (let ((ebasecamp-docker-executable "sh")
        (results nil))
    (ebasecamp-docker-run-async (list "-c" "printf out; printf err 1>&2")
                                (lambda (result) (push result results)))
    (should (ebasecamp-docker-test--wait (lambda () results)))
    (let ((result (car results)))
      (should (= 1 (length results)))
      (should (= 0 (plist-get result :exit)))
      (should (equal "out" (plist-get result :stdout)))
      (should (equal "err" (plist-get result :stderr))))))

(ert-deftest ebasecamp-docker-test-run-async-timeout-kills-process ()
  "异步执行超时回调 ebasecamp-docker-timeout 且进程被 kill。"
  (let ((ebasecamp-docker-executable "sh")
        (results nil)
        (t0 (float-time))
        process)
    (setq process (ebasecamp-docker-run-async
                   (list "-c" "sleep 3")
                   (lambda (result) (push result results))
                   :timeout 0.3))
    (should (processp process))
    (should (ebasecamp-docker-test--wait (lambda () results)))
    (let ((result (car results)))
      (should (= 1 (length results)))
      (should (eq 'ebasecamp-docker-timeout (plist-get result :error)))
      (should (stringp (plist-get result :message))))
    (should-not (process-live-p process))
    (should (< (- (float-time) t0) 2.5))))

;;; 17–18. version-check

(ert-deftest ebasecamp-docker-test-version-check-compose-5 ()
  "Compose 5.x 视为受支持版本，:compose-version 为三段版本号。"
  (ebasecamp-docker-test--with-fake-sync
      0 "Docker Compose version 5.6.0\n" ""
    (let ((result (ebasecamp-docker-version-check)))
      (should (equal "5.6.0" (plist-get result :compose-version)))
      (should (plist-get result :ok))
      (should-not (plist-get result :warning)))))

(ert-deftest ebasecamp-docker-test-version-check-other-major-warns ()
  "非 5.x 主版本 :ok nil 并给出警告文案。"
  (ebasecamp-docker-test--with-fake-sync
      0 "Docker Compose version 2.20.0\n" ""
    (let ((result (ebasecamp-docker-version-check)))
      (should (equal "2.20.0" (plist-get result :compose-version)))
      (should-not (plist-get result :ok))
      (should (stringp (plist-get result :warning)))
      (should (string-match-p "5\\.x" (plist-get result :warning))))))

(ert-deftest ebasecamp-docker-test-version-check-command-failure ()
  "命令失败时 :ok nil，:warning 含失败原因。"
  (ebasecamp-docker-test--with-fake-sync
      1 "" "docker: 'compose' is not a docker command"
    (let ((result (ebasecamp-docker-version-check)))
      (should-not (plist-get result :ok))
      (should-not (plist-get result :compose-version))
      (should (string-match-p "compose" (plist-get result :warning))))))

;;; 19–21. ps

(ert-deftest ebasecamp-docker-test-ps-command-line-invariants ()
  "ps 的命令行必须带 --no-trunc、managed 过滤条件与 {{json .}} 格式。"
  (let (captured
        (lines (ebasecamp-docker-test--fixture-lines "docker-ps-managed.jsonl")))
    (let ((ebasecamp-docker--run-sync-function
           (lambda (args _timeout)
             (setq captured args)
             (list :exit 0
                   :stdout (concat (mapconcat #'identity lines "\n") "\n")
                   :stderr ""))))
      (let ((containers (ebasecamp-docker-ps)))
        (should (= 2 (length containers)))
        (should (equal '("ps" "-a" "--no-trunc"
                         "--filter" "label=ebasecamp.managed=true"
                         "--format" "{{json .}}")
                       captured))))))

(ert-deftest ebasecamp-docker-test-ps-signals-exit ()
  "ps 非零退出 signal ebasecamp-docker-exit 并携带数据。"
  (ebasecamp-docker-test--with-fake-sync
      1 "" "invalid filter"
    (let ((error-data (should-error (ebasecamp-docker-ps)
                                    :type 'ebasecamp-docker-exit)))
      (should (= 1 (plist-get (cdr error-data) :exit)))
      (should (equal "invalid filter"
                     (plist-get (cdr error-data) :stderr))))))

(ert-deftest ebasecamp-docker-test-ps-signals-permission ()
  "ps 遇 permission denied 时 signal ebasecamp-docker-permission。"
  (ebasecamp-docker-test--with-fake-sync
      1 "" "permission denied while trying to connect to the Docker daemon socket"
    (should-error (ebasecamp-docker-ps) :type 'ebasecamp-docker-permission)))

;;; 19. 默认超时透传

(ert-deftest ebasecamp-docker-test-run-sync-default-timeout ()
  "未传 :timeout 时把 `ebasecamp-docker-timeout-seconds' 透传给执行层。"
  (should (= 30 ebasecamp-docker-timeout-seconds))
  (let ((ebasecamp-docker-timeout-seconds 7)
        (seen nil))
    (let ((ebasecamp-docker--run-sync-function
           (lambda (_args timeout)
             (setq seen timeout)
             (list :exit 0 :stdout "" :stderr ""))))
      (ebasecamp-docker-run-sync '("ps"))
      (should (= 7 seen))
      ;; 显式 :timeout 优先于 defcustom
      (ebasecamp-docker-run-sync '("ps") :timeout 0.5)
      (should (= 0.5 seen)))))

;;; ebasecamp-docker-tests.el ends here
