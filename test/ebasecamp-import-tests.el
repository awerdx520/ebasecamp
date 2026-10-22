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

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ebasecamp-model)
(require 'ebasecamp-import)

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
  "env_file 以 (:source PATH :type env) 放进 extra，路径相对；未识别字段原样进 extra。"
  (let* ((api (ebasecamp-import-service-plist (ebasecamp-import-test--project) "api"))
         (extra (plist-get api :extra))
         (env-file (cdr (assoc "env_file" extra))))
    (should (equal '((:source "./api.env" :type env)) env-file))
    (should-not (string-prefix-p "/" (plist-get (car env-file) :source)))
    (should (equal "128m" (cdr (assoc "shm_size" extra))))
    ;; 已识别的字段不得出现在 extra 中
    (dolist (key '("image" "command" "entrypoint" "environment" "labels"
                   "volumes" "networks" "depends_on" "healthcheck"
                   "working_dir" "user" "restart"))
      (should-not (assoc key extra)))))

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

(provide 'ebasecamp-import-tests)
;;; ebasecamp-import-tests.el ends here
