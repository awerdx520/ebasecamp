;;; ebasecamp-import-tests.el --- ebasecamp 导入映射测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T4.1 导入映射（纯映射，不落盘）的 ERT 测试。
;;
;; 覆盖范围：
;; - `ebasecamp-import-parse-json' 对实测 fixture 的字段映射（image / command /
;;   entrypoint / environment / labels / ports / volumes / depends_on /
;;   networks / healthcheck / working-dir / user / restart / extra）；
;; - `${VAR}' 引用原样保留（未插值）；
;; - `ebasecamp-import-suggest-name' 的命名回退顺序；
;; - 非法 JSON、docker 非零退出 → `ebasecamp-import-error'；
;; - 真实 docker 的一次解析（docker 不可用时跳过）；
;; - 安全断言：环境变量给探针明文时，解析结果中不出现该明文。
;;
;; fixture：test/fixtures/compose-config-noint.json 为
;; `docker compose -f compose.yaml config --no-interpolate --no-env-resolution
;; --no-path-resolution --format json' 的实测输出（99 行），对应的输入为同目录
;; 的 compose-config-noint.yaml。
;;
;; T4.2 落盘（`ebasecamp-import-apply'）的测试用临时清单目录 + 伪造的
;; `ebasecamp-docker--run-sync-function'（返回同一 fixture JSON），因此不依赖
;; docker：断言生成文件存在与格式、可被清单层加载、服务字段还原、已存在拒绝
;; 与 force 覆盖、非法名拒绝、`:root` 默认值与显式值、`${VAR}` 原样保留、
;; 自校验失败回滚。

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ebasecamp-model)
(require 'ebasecamp-config)
(require 'ebasecamp-import)
(require 'ebasecamp-export)

;;; 测试脚手架

(defconst ebasecamp-import-test--fixtures-directory
  (expand-file-name
   "fixtures/"
   (file-name-directory (or load-file-name buffer-file-name)))
  "本测试所用 fixture 目录的绝对路径。")

(defconst ebasecamp-import-test--fixture "compose-config-noint.json"
  "实测 compose config JSON fixture 的文件名。")

(defconst ebasecamp-import-test--compose-fixture "compose-config-noint.yaml"
  "与上面的 JSON fixture 对应的 compose 输入文件。")

(defun ebasecamp-import-test--fixture-text (name)
  "读取 fixtures 目录下的 NAME，返回完整字符串。"
  (with-temp-buffer
    (insert-file-contents (expand-file-name name
                                           ebasecamp-import-test--fixtures-directory))
    (buffer-string)))

(defun ebasecamp-import-test--config-json ()
  "返回实测 compose config JSON 字符串。"
  (ebasecamp-import-test--fixture-text ebasecamp-import-test--fixture))

(defun ebasecamp-import-test--project (&optional json)
  "用实测 fixture（或 JSON）解析出的项目对象。"
  (ebasecamp-import-parse-json (or json (ebasecamp-import-test--config-json))))

(defmacro ebasecamp-import-test--with-fake-sync (exit stdout stderr &rest body)
  "在伪造的同步执行结果（EXIT / STDOUT / STDERR）下执行 BODY。"
  (declare (indent 3) (debug t))
  `(let ((ebasecamp-docker--run-sync-function
          (lambda (_args _timeout)
            (list :exit ,exit :stdout ,stdout :stderr ,stderr))))
     ,@body))

(defmacro ebasecamp-import-test--with-temp-compose (compose-text &rest body)
  "把 COMPOSE-TEXT 写入临时目录的 compose.yaml 与 api.env，并在 BODY 中执行。
BODY 内可用 `compose-file' 取 compose 文件绝对路径。"
  (declare (indent 1) (debug t))
  `(let* ((dir (make-temp-file "ebc-import-test-" t))
          (compose-file (expand-file-name "compose.yaml" dir)))
     (unwind-protect
         (progn
           (with-temp-file compose-file (insert ,compose-text))
           (with-temp-file (expand-file-name "api.env" dir)
             (insert "FROM_FILE=1\n"))
           ,@body)
       (delete-directory dir t))))

;;; 1. 服务与基础字段

(ert-deftest ebasecamp-import-test-parse-json-services ()
  "实测 fixture 解析出两个服务，且 api 的基础字段映射正确。"
  (let* ((project (ebasecamp-import-test--project))
         (services (ebasecamp-import-service-plists project)))
    (should (ebasecamp-project-p project))
    (should (= 2 (length services)))
    (should (equal '(api cache) (mapcar #'car services)))
    (let ((api (ebasecamp-import-service-plist project "api")))
      (should (equal "myapp/api:dev" (plist-get api :image)))
      (should (equal '("sh" "-c" "run --port 8080") (plist-get api :command)))
      (should (equal '("/entry.sh") (plist-get api :entrypoint)))
      (should (equal "/app" (plist-get api :working-dir)))
      (should (equal "1000:1000" (plist-get api :user)))
      (should (equal "unless-stopped" (plist-get api :restart))))
    (let ((cache (ebasecamp-import-service-plist project "cache")))
      (should (equal "redis:7.4" (plist-get cache :image)))
      ;; 实测 --no-interpolate 下 cache 服务没有 command / entrypoint 键
      (should-not (plist-get cache :command))
      (should-not (plist-get cache :entrypoint)))))

(ert-deftest ebasecamp-import-test-project-header ()
  "项目名取 JSON 顶层 name；组为 app（per-project），shared-network 为 t。"
  (let* ((project (ebasecamp-import-test--project))
         (ref (car (ebasecamp-project-groups project))))
    (should (eq 'probe-app (ebasecamp-project-name project)))
    (should (equal "probe-app" (ebasecamp-project-title project)))
    (should-not (ebasecamp-project-root project))
    (should-not (ebasecamp-project-export-file project))
    (should (ebasecamp-project-shared-network project))
    (should (eq 'app (plist-get ref :group)))
    (should (eq 'per-project (plist-get ref :scope)))))

;;; 2. environment：${VAR} 不插值

(ert-deftest ebasecamp-import-test-environment-keeps-reference ()
  "environment 映射为字符串 alist，且 `${VAR}' 引用原样保留。"
  (let* ((api (ebasecamp-import-service-plist (ebasecamp-import-test--project) "api"))
         (environment (plist-get api :environment)))
    (should (equal "mysql" (cdr (assoc "DB_HOST" environment))))
    (should (equal "redis://cache:6379/0" (cdr (assoc "CACHE_URL" environment))))
    (should (equal "${PROBE_SECRET}" (cdr (assoc "SECRET_REF" environment))))
    (should (equal "${PROBE_OTHER:-fallback}"
                   (cdr (assoc "SECRET_DEFAULT" environment))))
    (should (cl-every #'stringp (mapcar #'cdr environment)))))

;;; 3. labels：剔除 ebasecamp.* 与 com.docker.compose.*

(ert-deftest ebasecamp-import-test-labels-stripped ()
  "labels 保留用户标签，剔除 ebasecamp.* 与 com.docker.compose.* 前缀键。"
  (let* ((api (ebasecamp-import-service-plist (ebasecamp-import-test--project) "api"))
         (labels (plist-get api :labels)))
    (should (equal "backend" (cdr (assoc "com.example.team" labels))))
    (should-not (assoc "ebasecamp.managed" labels))
    (should-not (assoc "com.docker.compose.project" labels))
    (should (= 1 (length labels)))))

;;; 4. ports：整数对 + 不可表达的端口进 extra

(ert-deftest ebasecamp-import-test-ports ()
  "tcp 且绑定 0.0.0.0 的端口映射为 (PUBLISHED . TARGET) 整数对。
带宿主 IP（127.0.0.1）且协议为 udp 的端口无法用当前 model 表达，进入
extra 的 \"ports\" 桶保留原始对象。"
  (let* ((api (ebasecamp-import-service-plist (ebasecamp-import-test--project) "api"))
         (ports (plist-get api :ports))
         (extra-ports (cdr (assoc "ports" (plist-get api :extra)))))
    (should (equal '((8080 . 80)) ports))
    (should (= 1 (length extra-ports)))
    (let ((raw (car extra-ports)))
      (should (equal "9090" (cdr (assoc "published" raw))))
      (should (equal 9090 (cdr (assoc "target" raw))))
      (should (equal "udp" (cdr (assoc "protocol" raw))))
      (should (equal "127.0.0.1" (cdr (assoc "host_ip" raw)))))))

(ert-deftest ebasecamp-import-test-ports-published-with-ip ()
  "published 形如 \"127.0.0.1:9091\" 时取末尾端口段；缺 published 的端口进 extra。"
  (let* ((json "{\"services\":{\"api\":{\"image\":\"x:1\",\"ports\":[{\"published\":\"127.0.0.1:9091\",\"target\":91,\"protocol\":\"tcp\"},{\"target\":92}]}}}")
         (api (ebasecamp-import-service-plist (ebasecamp-import-parse-json json) "api")))
    (should (equal '((9091 . 91)) (plist-get api :ports)))
    (should (= 1 (length (cdr (assoc "ports" (plist-get api :extra))))))))

;;; 5. volumes

(ert-deftest ebasecamp-import-test-volumes ()
  "bind 卷带 :read-only，命名卷 type 为 volume，路径保持相对。"
  (let* ((api (ebasecamp-import-service-plist (ebasecamp-import-test--project) "api"))
         (volumes (plist-get api :volumes)))
    (should (= 2 (length volumes)))
    (should (equal '(:source "./src" :target "/app/src" :type bind :read-only t)
                   (car volumes)))
    (should (equal '(:source "api-cache" :target "/cache" :type volume)
                   (cadr volumes)))
    ;; 相对路径未被绝对化（--no-path-resolution）
    (should-not (string-prefix-p "/" (plist-get (car volumes) :source)))))

;;; 6. depends_on / networks

(ert-deftest ebasecamp-import-test-depends-on ()
  "对象形态的 depends_on 归一为服务名列表。"
  (let* ((api (ebasecamp-import-service-plist (ebasecamp-import-test--project) "api")))
    (should (equal '("cache") (plist-get api :depends-on)))))

(ert-deftest ebasecamp-import-test-depends-on-list-form ()
  "数组形态的 depends_on 同样归一为服务名列表。"
  (let* ((json "{\"services\":{\"api\":{\"image\":\"x:1\",\"depends_on\":[\"a\",\"b\"]}}}")
         (api (ebasecamp-import-service-plist (ebasecamp-import-parse-json json) "api")))
    (should (equal '("a" "b") (plist-get api :depends-on)))))

(ert-deftest ebasecamp-import-test-networks-drops-default ()
  "networks 映射为网络名列表，且剔除 default。"
  (let* ((project (ebasecamp-import-test--project))
         (api (ebasecamp-import-service-plist project "api")))
    (should (equal '("backend") (plist-get api :networks))))
  (let* ((json "{\"services\":{\"api\":{\"image\":\"x:1\",\"networks\":{\"default\":null,\"backend\":null}}}}")
         (api (ebasecamp-import-service-plist (ebasecamp-import-parse-json json) "api")))
    (should (equal '("backend") (plist-get api :networks)))))

;;; 7. healthcheck 与 extra

(ert-deftest ebasecamp-import-test-healthcheck ()
  "healthcheck 映射为 plist：test 为列表，interval 为字符串，retries 为整数。"
  (let* ((api (ebasecamp-import-service-plist (ebasecamp-import-test--project) "api"))
         (healthcheck (plist-get api :healthcheck)))
    (should (equal '("CMD" "curl" "-f" "http://localhost/health")
                   (plist-get healthcheck :test)))
    (should (equal "10s" (plist-get healthcheck :interval)))
    (should (equal 3 (plist-get healthcheck :retries)))))

(ert-deftest ebasecamp-import-test-extra-env-file-and-unknown-fields ()
  "env_file 以相对路径字符串列表放进 extra；未识别字段原样进 extra。"
  (let* ((api (ebasecamp-import-service-plist (ebasecamp-import-test--project) "api"))
         (extra (plist-get api :extra))
         (env-file (cdr (assoc "env_file" extra))))
    (should (equal '("./api.env") env-file))
    (should-not (string-prefix-p "/" (car env-file)))
    (should (equal "128m" (cdr (assoc "shm_size" extra))))
    ;; 已识别的字段不得出现在 extra 中
    (dolist (key '("image" "command" "entrypoint" "environment" "labels"
                   "volumes" "networks" "depends_on" "healthcheck"
                   "working_dir" "user" "restart"))
      (should-not (assoc key extra)))))

;;; 7.1 D4：env_file 往返（回归：含 env_file 的项目必须能导出并通过校验）

(ert-deftest ebasecamp-import-test-env-file-maps-to-path-string-list ()
  "env_file 归一为相对路径字符串列表，不带 volumes 语义的 `:source' / `:type'。
D3 缺陷：旧实现返回 ((:source PATH :type env) …)，该 plist 列表被渲染层
`ebasecamp-compose--mapping-p' 误判为映射，导出产出 compose 无法解析的 YAML。"
  (let* ((api (ebasecamp-import-service-plist (ebasecamp-import-test--project) "api"))
         (env-file (cdr (assoc "env_file" (plist-get api :extra)))))
    (should (equal '("./api.env") env-file))
    ;; 相对路径未被绝对化（--no-path-resolution）
    (should-not (string-prefix-p "/" (car env-file)))
    ;; 不含任何关键字/嵌套结构：volumes 语义残留会让渲染层走映射分支
    (should-not (cl-some (lambda (item)
                           (or (keywordp item) (consp item)))
                         env-file))))

(ert-deftest ebasecamp-import-test-env-file-object-form-keeps-path ()
  "对象形态（{path, required}）归一为路径字符串列表，保持顺序并丢弃无 path 项。"
  (let* ((json (concat "{\"services\":{\"api\":{\"image\":\"x:1\","
                       "\"env_file\":[{\"path\":\"./x.env\"}]}}}"))
         (api (ebasecamp-import-service-plist
               (ebasecamp-import-parse-json json) "api")))
    (should (equal '("./x.env")
                   (cdr (assoc "env_file" (plist-get api :extra))))))
  ;; 混合形态（字符串 + 带 path 的对象 + 无 path 的对象）按原序保留、无 path 丢弃
  (let* ((json (concat "{\"services\":{\"api\":{\"image\":\"x:1\","
                       "\"env_file\":[\"./a.env\","
                       "{\"path\":\"./x.env\",\"required\":false},"
                       "{\"required\":true}]}}}"))
         (api (ebasecamp-import-service-plist
               (ebasecamp-import-parse-json json) "api")))
    (should (equal '("./a.env" "./x.env")
                   (cdr (assoc "env_file" (plist-get api :extra)))))))

(defun ebasecamp-import-test--env-file-section (lines start)
  "返回 LINES 中第 START 行（`env_file:' 所在行）之后的序列条目行。
条目行判定：以 6 个空格 + `- ' 开头；遇到其它行即结束。"
  (let ((rest (nthcdr (1+ start) lines))
        (section nil))
    (while (and rest (string-prefix-p "      - " (car rest)))
      (setq section (append section (list (car rest))))
      (setq rest (cdr rest)))
    section))

(ert-deftest ebasecamp-import-test-env-file-export-roundtrip-renders-string-list ()
  "导入 → 导出的 compose 文本中，`env_file' 之下是 `- ./api.env' 字符串列表。
不得出现映射语义残留（`source:' / `\":type\"'），段落总行数 ≤5。
渲染层按需加引号（`ebasecamp-compose--quote-required-p'），纯路径不需要引号。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (let* ((_manifest (ebasecamp-import-apply compose-file "probe-app"))
           (status (ebasecamp-config-load config-dir))
           (project (ebasecamp-model-project 'probe-app))
           (text (ebasecamp-export--content project))
           (lines (split-string text "\n"))
           (start (cl-position-if
                   (lambda (line) (string-match-p "\\` +env_file:\\'" line))
                   lines))
           (section nil))
      (should (null (plist-get status :errors)))
      (should (integerp start))
      (setq section (ebasecamp-import-test--env-file-section lines start))
      (should (= 1 (length section)))
      (should (string-match-p "\\`      - \"?\\./api\\.env\"?\\'" (car section)))
      (should (<= (+ 1 (length section)) 5))
      (let ((section-text (mapconcat #'identity section "\n")))
        (should-not (string-match-p "source:" section-text))
        (should-not (string-match-p (regexp-quote ":type") section-text))))))

(ert-deftest ebasecamp-import-test-env-file-export-passes-check ()
  "含 env_file 的项目能导出落盘（打桩 compose 校验，不依赖 docker 守护进程）。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (let* ((_manifest (ebasecamp-import-apply compose-file "probe-app"))
           (_status (ebasecamp-config-load config-dir))
           (project (ebasecamp-model-project 'probe-app))
           (checked nil)
           (target nil))
      (cl-letf (((symbol-function 'ebasecamp-docker-check-compose)
                 (lambda (file)
                   (push file checked)
                   (list :ok t :exit 0 :stderr ""))))
        (setq target (ebasecamp-export-project project :force t)))
      (should (stringp target))
      (should (file-exists-p target))
      ;; 校验对象是临时文件，通过后原子替换目标
      (should (equal (list (concat target ".tmp")) checked))
      (should-not (file-exists-p (concat target ".tmp")))
      (let ((text (ebasecamp-import-test--read target)))
        (should (string-match-p "env_file:" text))
        (should (string-match-p "- \"?\\./api\\.env\"?" text))
        (should-not (string-match-p "source:" text))))))

;;; 8. suggest-name

(ert-deftest ebasecamp-import-test-suggest-name-uses-json-name ()
  "JSON 顶层 name 合法时用作项目名。"
  (should (eq 'probe-app
              (ebasecamp-import-suggest-name
               "/tmp/whatever/docker-compose.yaml"
               (ebasecamp-import-test--config-json)))))

(ert-deftest ebasecamp-import-test-suggest-name-falls-back-to-directory ()
  "JSON name 非法（大写、含点）时回退到 compose 文件父目录名（转小写）。"
  (let ((dir (make-temp-file "ebc-suggest-" t)))
    (unwind-protect
        (let ((file (expand-file-name "compose.yaml" dir))
              (json "{\"name\":\"Bad.Name\",\"services\":{\"api\":{\"image\":\"x:1\"}}}"))
          (should (eq (intern (downcase (file-name-nondirectory
                                         (directory-file-name dir))))
                      (ebasecamp-import-suggest-name file json))))
      (delete-directory dir t))))

(ert-deftest ebasecamp-import-test-suggest-name-falls-back-to-file-name ()
  "父目录名非法时回退到文件名（去扩展名）。"
  (let* ((json "{\"name\":\"Not Valid\",\"services\":{\"api\":{\"image\":\"x:1\"}}}")
         (dir (make-temp-file "Bad.Dir" t)))
    (unwind-protect
        (should (eq 'my-compose
                    (ebasecamp-import-suggest-name
                     (expand-file-name "my-compose.yaml" dir)
                     json)))
      (delete-directory dir t))))

(ert-deftest ebasecamp-import-test-suggest-name-defaults-to-imported ()
  "文件名与目录名都非法时返回 imported。"
  (let ((json "{\"services\":{\"api\":{\"image\":\"x:1\"}}}"))
    (should (eq 'imported
                (ebasecamp-import-suggest-name "/tmp/Bad.Dir/Bad File.yaml" json)))))

(ert-deftest ebasecamp-import-test-parse-json-uses-suggest-name-fallback ()
  "无 JSON name 且未提供文件时项目名回退为 imported。"
  (should (eq 'imported
              (ebasecamp-project-name
               (ebasecamp-import-parse-json
                "{\"services\":{\"api\":{\"image\":\"x:1\"}}}")))))

;;; 9. 错误路径

(ert-deftest ebasecamp-import-test-parse-json-invalid-json ()
  "非法 JSON 输入 signal `ebasecamp-import-error'。"
  (should-error (ebasecamp-import-parse-json "{not json")
                :type 'ebasecamp-import-error)
  (should-error (ebasecamp-import-parse-json "")
                :type 'ebasecamp-import-error))

(ert-deftest ebasecamp-import-test-parse-json-missing-services ()
  "缺少 services 时 signal `ebasecamp-import-error'。"
  (should-error (ebasecamp-import-parse-json "{\"name\":\"x\"}")
                :type 'ebasecamp-import-error)
  (should-error (ebasecamp-import-parse-json "{\"services\":{}}")
                :type 'ebasecamp-import-error))

(ert-deftest ebasecamp-import-test-parse-docker-failure ()
  "docker compose config 非零退出时 signal `ebasecamp-import-error' 并带上 stderr。"
  (ebasecamp-import-test--with-fake-sync
      1 "" "go-yaml load error: line 3" 
    (let ((error-data (should-error (ebasecamp-import-parse "/tmp/compose.yaml")
                                    :type 'ebasecamp-import-error)))
      (should (string-match-p "go-yaml load error"
                              (format "%s" (cdr error-data)))))))

;;; 10. 真实 docker（不可用时跳过）

(ert-deftest ebasecamp-import-test-parse-real-docker ()
  "对实测 compose 输入跑一次真实解析：服务数 2、无错误、image 正确。"
  (unless (and (executable-find "docker")
               (eq 0 (ignore-errors
                       (plist-get (ebasecamp-docker-run-sync (list "compose" "version"))
                                  :exit))))
    (ert-skip "docker / compose 不可用"))
  (ebasecamp-import-test--with-temp-compose
      (ebasecamp-import-test--fixture-text ebasecamp-import-test--compose-fixture)
    (let* ((project (ebasecamp-import-parse compose-file))
           (services (ebasecamp-import-service-plists project)))
      (should (eq 'probe-app (ebasecamp-project-name project)))
      (should (= 2 (length services)))
      (should (equal "myapp/api:dev"
                     (plist-get (ebasecamp-import-service-plist project "api")
                                :image))))))

;;; 11. 安全断言

(ert-deftest ebasecamp-import-test-no-plaintext-in-fixture ()
  "fixture JSON 本身不含探针明文，只有 `${VAR}' 引用。"
  (let ((json (ebasecamp-import-test--config-json)))
    (should (string-match-p (regexp-quote "${PROBE_SECRET}") json))
    (should (string-match-p (regexp-quote "${PROBE_OTHER:-fallback}") json))))

(ert-deftest ebasecamp-import-test-no-plaintext-with-env-set ()
  "环境变量给探针明文时，解析结果不出现该明文。"
  (unless (and (executable-find "docker")
               (eq 0 (ignore-errors
                       (plist-get (ebasecamp-docker-run-sync (list "compose" "version"))
                                  :exit))))
    (ert-skip "docker / compose 不可用"))
  (ebasecamp-import-test--with-temp-compose
      (ebasecamp-import-test--fixture-text ebasecamp-import-test--compose-fixture)
    (let ((process-environment
           (cons "PROBE_SECRET=fake-import-secret"
                 (cons "PROBE_OTHER=fake-import-other" process-environment)))
          (result nil))
      (setq result (prin1-to-string (ebasecamp-import-parse compose-file)))
      (should (string-match-p (regexp-quote "${PROBE_SECRET}") result))
      (should-not (string-match-p "fake-import-secret" result))
      (should-not (string-match-p "fake-import-other" result)))))

;;; 12. 落盘语义（T4.2）

(defun ebasecamp-import-test--read (file)
  "读取文件 FILE，返回完整内容字符串。"
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defmacro ebasecamp-import-test--with-manifest (compose-name &rest body)
  "在临时清单目录与临时 compose 目录下执行 BODY。
绑定 `config-dir'（临时清单目录，无尾斜杠）、`compose-dir'（临时 compose
目录，无尾斜杠）、`compose-file'（COMPOSE-NAME 对应的绝对路径），并把
`ebasecamp-config-directory' 指向 `config-dir'。
compose 读取由 `ebasecamp-docker--run-sync-function' 伪造为实测 fixture，
因此不依赖 docker。"
  (declare (indent 1) (debug t))
  `(let* ((config-dir (make-temp-file "ebc-import-config-" t))
          (compose-dir (make-temp-file "ebc-import-compose-" t))
          (compose-file (expand-file-name ,compose-name compose-dir))
          (ebasecamp-config-directory config-dir)
          (ebasecamp-docker--run-sync-function
           (lambda (_args _timeout)
             (list :exit 0
                   :stdout (ebasecamp-import-test--config-json)
                   :stderr ""))))
     (unwind-protect
         (progn
           (with-temp-file compose-file (insert "services: {}\n"))
           ,@body)
       (ignore-errors (delete-directory config-dir t))
       (ignore-errors (delete-directory compose-dir t)))))

(defun ebasecamp-import-test--target (name config-dir)
  "返回 NAME 在 CONFIG-DIR 下的清单文件绝对路径。"
  (expand-file-name (concat "projects/" name ".el")
                    (file-name-as-directory config-dir)))

(ert-deftest ebasecamp-import-test-apply-writes-file ()
  "apply 返回 projects/<name>.el 绝对路径，文件含组/项目定义与文件头。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (let* ((path (ebasecamp-import-apply compose-file "probe-app"))
           (content (ebasecamp-import-test--read path)))
      (should (file-exists-p path))
      (should (equal (ebasecamp-import-test--target "probe-app" config-dir) path))
      (should (string-match-p "lexical-binding: t" content))
      (should (string-match-p "^(ebasecamp-define-group probe-app$" content))
      (should (string-match-p "^(ebasecamp-define-project probe-app$" content))
      ;; 注释头对齐 create-sample-config 的模板，并交代来源与安全约定
      (should (string-match-p "^;;; probe-app\\.el --- ebasecamp 清单" content))
      (should (string-match-p "由 M-x ebasecamp-import-file 从 " content))
      (should (string-match-p "安全约定：只保存" content))
      ;; 末尾单个换行
      (should (string-suffix-p ")\n" content))
      (should-not (string-suffix-p "\n\n" content)))))

;;; 12.1 v0.2 落盘格式：组内 :configs

(ert-deftest ebasecamp-import-test-apply-writes-configs ()
  "落盘文本用组内 :configs 表达项目归属，且配置名与组名/项目名一致。
配置名取项目名是为了让「哪个项目用了这份组定义」在清单里直接可读，也便于
物化后按 (组名 . 项目名) 定位来源。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (let ((content (ebasecamp-import-test--read
                    (ebasecamp-import-apply compose-file "probe-app"))))
      (should (string-match-p (regexp-quote ":configs ((") content))
      (should (string-match-p (regexp-quote ":project probe-app") content))
      (should (string-match-p
               (regexp-quote "((probe-app :project probe-app))") content)))))

(ert-deftest ebasecamp-import-test-apply-does-not-write-project-groups ()
  "项目定义段不再写 :groups：组引用改由组内 :configs 在加载期物化。
旧写法（项目侧 :groups）仍被模型兼容，但导入不再产出它，避免同一项目
里出现「旧引用 + 配置引用」两份来源。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (let* ((content (ebasecamp-import-test--read
                     (ebasecamp-import-apply compose-file "probe-app")))
           (start (string-match "(ebasecamp-define-project probe-app" content)))
      (should start)
      (should-not (string-match-p ":groups" (substring content start)))
      ;; 全文都不该出现 :groups（服务定义进组 :services，不进项目）
      (should-not (string-match-p ":groups" content)))))

(ert-deftest ebasecamp-import-test-apply-roundtrip-loadable ()
  "落盘文件加载零错误，且项目 groups 槽里有带 :service-overrides 键的 ref。
`:service-overrides' 是物化产物的键名不变量（D6）：ref 必须由配置物化
而来，而不是退回旧 :groups 写法。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (ebasecamp-import-apply compose-file "probe-app")
    (let* ((status (ebasecamp-config-load config-dir))
           (project (ebasecamp-model-project 'probe-app))
           (refs (and project (ebasecamp-project-groups project)))
           (ref (and refs (cl-find 'probe-app refs
                                   :key (lambda (item) (plist-get item :group))))))
      (should (null (plist-get status :errors)))
      (should project)
      (should (= 1 (length refs)))
      (should ref)
      (should (plist-member ref :service-overrides))
      (should (eq 'per-project (plist-get ref :scope))))))

(ert-deftest ebasecamp-import-test-apply-keeps-var-references ()
  "落盘文本保留 `${VAR}' 原文，且不含环境里给的探针明文。
导入链路只搬运 `compose config --no-interpolate' 的输出，任何一层插值都会
在清单里留下明文，因此落盘后必须逐字核对。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (let* ((process-environment
            (cons "PROBE_SECRET=fake-manifest-secret"
                  (cons "PROBE_OTHER=fake-manifest-other" process-environment)))
           (content (ebasecamp-import-test--read
                     (ebasecamp-import-apply compose-file "probe-app"))))
      (should (string-match-p (regexp-quote "${PROBE_SECRET}") content))
      (should (string-match-p (regexp-quote "${PROBE_OTHER:-fallback}") content))
      (should-not (string-match-p "fake-manifest-secret" content))
      (should-not (string-match-p "fake-manifest-other" content))
      ;; 不应被转义成 \$ 形式（那样 compose 侧就取不到变量了）
      (should-not (string-match-p (regexp-quote "\\${PROBE_SECRET}") content)))))

(ert-deftest ebasecamp-import-test-apply-loadable ()
  "生成的文件能被 `ebasecamp-config-load' 加载：无错误、1 组 1 项目。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (ebasecamp-import-apply compose-file "probe-app")
    (let ((status (ebasecamp-config-load config-dir)))
      (should (null (plist-get status :errors)))
      (should-not (plist-get status :bootstrap-needed))
      (should (= 1 (length (plist-get status :groups))))
      (should (= 1 (length (plist-get status :projects))))
      (should (eq 'probe-app (ebasecamp-project-name
                              (car (plist-get status :projects)))))
      (should (eq 'probe-app (ebasecamp-group-name
                              (car (plist-get status :groups)))))
      (should (eq 'per-project (ebasecamp-group-scope
                                (car (plist-get status :groups))))))))

(ert-deftest ebasecamp-import-test-apply-services-resolve ()
  "落盘后经 `ebasecamp-model-resolve-services' 取回的服务字段正确。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (ebasecamp-import-apply compose-file "probe-app")
    (ebasecamp-config-load config-dir)
    (let* ((project (ebasecamp-model-project 'probe-app))
           (services (ebasecamp-model-resolve-services
                      project (car (ebasecamp-project-groups project))))
           (api (cl-find 'api services :key #'ebasecamp-service-name))
           (cache (cl-find 'cache services :key #'ebasecamp-service-name)))
      (should (= 2 (length services)))
      (should (equal "myapp/api:dev" (ebasecamp-service-image api)))
      (should (equal '((8080 . 80)) (ebasecamp-service-ports api)))
      (should (equal "${PROBE_SECRET}"
                     (cdr (assoc "SECRET_REF"
                                 (ebasecamp-service-environment api)))))
      (should (equal "${PROBE_OTHER:-fallback}"
                     (cdr (assoc "SECRET_DEFAULT"
                                 (ebasecamp-service-environment api)))))
      (should (eq t (plist-get (car (ebasecamp-service-volumes api))
                               :read-only)))
      (should (equal '("cache") (ebasecamp-service-depends-on api)))
      (should (equal '("backend") (ebasecamp-service-networks cache)))
      (should (equal "redis:7.4" (ebasecamp-service-image cache))))))

(ert-deftest ebasecamp-import-test-apply-existing-without-force ()
  "目标已存在且未指定 force 时 signal，且原文件内容一字未动。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (let ((path (ebasecamp-import-apply compose-file "probe-app")))
      (with-temp-file path (insert ";;; sentinel\n"))
      (should-error (ebasecamp-import-apply compose-file "probe-app")
                    :type 'ebasecamp-import-error)
      (should (equal ";;; sentinel\n" (ebasecamp-import-test--read path))))))

(ert-deftest ebasecamp-import-test-apply-force-overwrites ()
  "force 非 nil 时覆盖已存在的目标文件。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (let ((path (ebasecamp-import-apply compose-file "probe-app")))
      (with-temp-file path (insert ";;; sentinel\n"))
      (should (equal path (ebasecamp-import-apply compose-file "probe-app"
                                                  :force t)))
      (should-not (string-match-p "sentinel" (ebasecamp-import-test--read path)))
      (should (string-match-p "ebasecamp-define-group"
                              (ebasecamp-import-test--read path))))))

(ert-deftest ebasecamp-import-test-apply-rejects-invalid-names ()
  "非法名（含空格、大写、空串）signal `ebasecamp-import-error'，不落盘。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (dolist (name '("Bad Name" "Upper" "UPPER" "" "with.dot" "with/slash"))
      (should-error (ebasecamp-import-apply compose-file name)
                    :type 'ebasecamp-import-error))
    (should-not (file-directory-p (expand-file-name "projects" config-dir)))))

(ert-deftest ebasecamp-import-test-apply-root-defaults-to-compose-directory ()
  ":root 省略时取 compose 文件父目录，且不带尾斜杠。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (ebasecamp-import-apply compose-file "probe-app")
    (ebasecamp-config-load config-dir)
    (let ((root (ebasecamp-project-root (ebasecamp-model-project 'probe-app))))
      (should (equal (directory-file-name compose-dir) root))
      (should-not (string-suffix-p "/" root)))))

(ert-deftest ebasecamp-import-test-apply-root-explicit ()
  ":root 显式传入时优先使用该值。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (ebasecamp-import-apply compose-file "probe-app" :root "/srv/probe-app")
    (ebasecamp-config-load config-dir)
    (should (equal "/srv/probe-app"
                   (ebasecamp-project-root
                    (ebasecamp-model-project 'probe-app))))
    (should (string-match-p (regexp-quote ":root \"/srv/probe-app\"")
                            (ebasecamp-import-test--read
                             (ebasecamp-import-test--target "probe-app"
                                                            config-dir))))))

(ert-deftest ebasecamp-import-test-apply-keeps-variable-reference ()
  "生成文件中 `${VAR}' 原样出现，不带 `\\$' 转义。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (let ((content (ebasecamp-import-test--read
                    (ebasecamp-import-apply compose-file "probe-app"))))
      (should (string-match-p (regexp-quote "${PROBE_SECRET}") content))
      (should (string-match-p (regexp-quote "${PROBE_OTHER:-fallback}") content))
      (should-not (string-match-p (regexp-quote "\\${PROBE_SECRET}") content)))))

(ert-deftest ebasecamp-import-test-apply-rollback-on-invalid-service ()
  "自校验失败时回滚：新文件被删除；原本有文件时恢复原内容。"
  (ebasecamp-import-test--with-manifest "compose.yaml"
    (let ((path (ebasecamp-import-test--target "probe-app" config-dir))
          (broken (lambda (_file)
                    (ebasecamp-project-create
                     :name 'probe-app
                     :title "probe-app"
                     :groups (list (list :group 'app
                                         :scope 'per-project
                                         :service-overrides
                                         (list (cons 'api (list :image nil)))))))))
      ;; 情形 1：目标不存在 → 自校验失败后不得留下文件
      (cl-letf (((symbol-function 'ebasecamp-import-parse) broken))
        (should-error (ebasecamp-import-apply compose-file "probe-app")
                      :type 'ebasecamp-import-error))
      (should-not (file-exists-p path))
      ;; 情形 2：目标已存在 + force → 自校验失败后恢复原内容
      (with-temp-file path (insert ";;; sentinel\n"))
      (cl-letf (((symbol-function 'ebasecamp-import-parse) broken))
        (should-error (ebasecamp-import-apply compose-file "probe-app" :force t)
                      :type 'ebasecamp-import-error))
      (should (equal ";;; sentinel\n" (ebasecamp-import-test--read path))))))

;;; 13. 导入 → 导出全链路安全断言（T4.5）

(defconst ebasecamp-import-test--e2e-secret "fake-e2e-secret"
  "端到端安全断言用的探针明文。只用于断言它不出现在任何落盘文件里。")

(defconst ebasecamp-import-test--e2e-compose
  (concat
   "services:\n"
   "  api:\n"
   "    image: myapp/api:dev\n"
   "    env_file:\n"
   "      - ./api.env\n"
   "    environment:\n"
   "      SECRET_REF: \"${FAKE_SECRET}\"\n"
   "    ports:\n"
   "      - \"8080:80\"\n")
  "端到端用例的 compose 输入：含 `${FAKE_SECRET}' 引用与相对 `env_file'。")

(defconst ebasecamp-import-test--e2e-json
  (concat
   "{\"name\":\"probe-e2e\",\"services\":{\"api\":{"
   "\"image\":\"myapp/api:dev\","
   "\"environment\":{\"SECRET_REF\":\"${FAKE_SECRET}\"},"
   "\"env_file\":[{\"path\":\"./api.env\",\"required\":true}],"
   "\"ports\":[{\"mode\":\"ingress\",\"target\":80,\"published\":\"8080\","
   "\"protocol\":\"tcp\"}]}}}")
  "docker 不可用时替代 `compose config' 输出的 JSON（与实测形态一致）。")

(defun ebasecamp-import-test--e2e-docker-p ()
  "判断真实 docker compose 是否可用于端到端用例。"
  (and (executable-find "docker")
       (eq 0 (ignore-errors
               (plist-get (ebasecamp-docker-run-sync (list "compose" "version"))
                          :exit)))))

(ert-deftest ebasecamp-import-test-e2e-import-export-keeps-reference ()
  "导入 → 清单 → 导出全链路：两处文件都保留 `${FAKE_SECRET}'、都不含探针明文。
环境里给了 `FAKE_SECRET=fake-e2e-secret'，因此任何一次插值都会在落盘文本里
留下明文；清单侧的 `env_file' 还必须是相对路径（`--no-path-resolution'）。"
  (let* ((config-dir (make-temp-file "ebc-e2e-config-" t))
         (compose-dir (make-temp-file "ebc-e2e-compose-" t))
         (compose-file (expand-file-name "compose.yaml" compose-dir))
         (ebasecamp-config-directory config-dir)
         (process-environment
          (cons (format "FAKE_SECRET=%s" ebasecamp-import-test--e2e-secret)
                process-environment))
         (use-docker (ebasecamp-import-test--e2e-docker-p)))
    (unwind-protect
        (progn
          (with-temp-file compose-file
            (insert ebasecamp-import-test--e2e-compose))
          (with-temp-file (expand-file-name "api.env" compose-dir)
            (insert "FROM_FILE=1\n"))
          (let* ((ebasecamp-docker--run-sync-function
                  (unless use-docker
                    (lambda (_args _timeout)
                      (list :exit 0
                            :stdout ebasecamp-import-test--e2e-json
                            :stderr ""))))
                 (manifest (ebasecamp-import-apply compose-file "probe-e2e"))
                 (status (ebasecamp-config-load config-dir))
                 (project (ebasecamp-model-project 'probe-e2e))
                 (export-file nil))
            (should (null (plist-get status :errors)))
            ;; 清单侧
            (let ((manifest-text (ebasecamp-import-test--read manifest)))
              (should (string-match-p (regexp-quote "${FAKE_SECRET}")
                                      manifest-text))
              (should-not (string-match-p
                           (regexp-quote ebasecamp-import-test--e2e-secret)
                           manifest-text))
              ;; env_file 只留相对路径引用
              (should (string-match-p "\"./api.env\"" manifest-text))
              (should-not (string-match-p "\"/[^\"]*api\\.env\"" manifest-text)))
            ;; 导出侧（docker 校验打桩，不依赖守护进程）
            (cl-letf (((symbol-function 'ebasecamp-docker-check-compose)
                       (lambda (&rest _) (list :ok t :exit 0 :stderr ""))))
              (setq export-file (ebasecamp-export-project project :force t)))
            (should (file-exists-p export-file))
            (let ((export-text (ebasecamp-import-test--read export-file)))
              (should (string-match-p (regexp-quote "${FAKE_SECRET}")
                                      export-text))
              (should-not (string-match-p
                           (regexp-quote ebasecamp-import-test--e2e-secret)
                           export-text)))))
      (ignore-errors (delete-directory config-dir t))
      (ignore-errors (delete-directory compose-dir t)))))

(provide 'ebasecamp-import-tests)
;;; ebasecamp-import-tests.el ends here
