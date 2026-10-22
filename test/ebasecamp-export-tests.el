;;; ebasecamp-export-tests.el --- ebasecamp 导出测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T4.3 导出（清单 → 部署用 compose 文件）的 ERT 测试。
;;
;; 导出语义（见 openspec/active/ebasecamp-m1-m3.md 的 T4.3）：
;; - 只导出 per-project 组的服务；shared 组的服务由部署环境自行提供；
;; - 不声明 `ebasecamp' external network —— 导出时用项目副本
;;   （`copy-ebasecamp-project' + `:shared-network' 置 nil），服务原有的自定义
;;   网络照旧保留，由 compose 自建 `<project>_<net>'；
;; - 标签注入、命名卷、`${VAR}' 引用由 compose 渲染层原样保证；
;; - 目标已存在时非交互报错、交互式提示「换路径 / 覆盖 / 取消」；
;; - 落盘前写 `<target>.tmp' 并用 `ebasecamp-docker-check-compose' 校验，
;;   通过才 rename，失败时目标与临时文件都不留。
;;
;; 覆盖范围（编号对应任务书 1–12，13–16 为交互分支与命令入口的补充）：
;; 1–2 默认路径；3–6 内容（头注释 / 无 external / 只有 per-project / 保留
;; `${VAR}'）；7–8 已存在冲突的 force 分支；9 校验失败不落盘；10–11 真实
;; docker 的校验与往返；12 安全断言（不落盘明文密钥）；13–15 交互三分支；
;; 16 交互式命令入口。
;;
;; 除第 10、11 项外一律用 `cl-letf' 伪造 `ebasecamp-docker-check-compose'，
;; 不依赖 docker 守护进程。

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'ebasecamp-model)
(require 'ebasecamp-compose)
(require 'ebasecamp-config)
(require 'ebasecamp-docker)
(require 'ebasecamp-export)

;;; 测试脚手架

(defconst ebasecamp-export-test--project-name 'shop
  "测试用项目名。")

(defun ebasecamp-export-test--read (file)
  "读取文件 FILE，返回完整内容字符串。"
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun ebasecamp-export-test--define-world (root &optional export-file)
  "在 ROOT 下注册测试用清单并返回项目对象。
清单含 shared 组 `base'（服务 mysql / adminer）与 per-project 组 `app'
（服务 api / cache）。EXPORT-FILE 非 nil 时写入项目的 `:export-file'。"
  (ebasecamp-model-reset)
  (ebasecamp-model--register-group
   'base
   (list :title "基础组件"
         :scope 'shared
         :services
         '((mysql
            :image "mysql:8.4"
            :environment (("MYSQL_ROOT_PASSWORD" . "${EBASECAMP_MYSQL_ROOT_PASSWORD}")
                          ("MYSQL_DATABASE" . "app"))
            :ports ((3306 . 3306))
            :volumes ((:source "mysql-data" :target "/var/lib/mysql"
                               :type volume)))
           (adminer
            :image "adminer:4"
            :ports ((8081 . 8080))))))
  (ebasecamp-model--register-group
   'app
   (list :title "应用"
         :scope 'per-project
         :services
         '((api
            :image "myapp/api:dev"
            :environment (("DB_PASSWORD" . "${EBASECAMP_MYSQL_ROOT_PASSWORD}")
                          ("CACHE_URL" . "redis://cache:6379/0"))
            :ports ((8080 . 80))
            :depends-on ("cache")
            :networks ("frontend")
            :restart "unless-stopped")
           (cache
            :image "redis:7.4"
            :volumes ((:source "cache-data" :target "/data" :type volume))))))
  (ebasecamp-model--register-project
   ebasecamp-export-test--project-name
   (append (list :title "Shop" :root root)
           (when export-file (list :export-file export-file))
           (list :groups '((base :scope shared)
                           (app :scope per-project))))))

(defmacro ebasecamp-export-test--with-root (&rest body)
  "在临时项目根目录下执行 BODY，结束后清理目录与清单注册表。
BODY 内 `root-dir' 为临时项目根目录（无尾斜杠）。"
  (declare (indent 0) (debug t))
  `(let ((root-dir (directory-file-name (make-temp-file "ebc-export-test-" t))))
     (unwind-protect
         (progn ,@body)
       (ebasecamp-model-reset)
       (ignore-errors (delete-directory root-dir t)))))

(defmacro ebasecamp-export-test--with-fake-check (result &rest body)
  "在伪造的 `ebasecamp-docker-check-compose'（返回 RESULT）下执行 BODY。
BODY 内 `checked-file' 为最后一次校验收到的文件路径。"
  (declare (indent 1) (debug t))
  `(let ((checked-file nil))
     (cl-letf (((symbol-function 'ebasecamp-docker-check-compose)
                (lambda (file)
                  (setq checked-file file)
                  ,result)))
       ,@body)))

(defun ebasecamp-export-test--skip-unless-docker ()
  "docker 与 compose 均不可用时跳过当前测试。"
  (unless (and (executable-find "docker")
               (eq 0 (ignore-errors
                       (plist-get (ebasecamp-docker-run-sync
                                   (list "compose" "version"))
                                  :exit))))
    (ert-skip "docker / compose 不可用")))

(defconst ebasecamp-export-test--ok-result
  '(:ok t :exit 0 :stderr "" :warnings nil)
  "伪造的校验通过结果。")

;;; 1. 默认导出路径

(ert-deftest ebasecamp-export-test-default-file-uses-export-file ()
  "项目 `:export-file' 非 nil 时作为默认导出路径，相对路径按 `:root' 展开。"
  (ebasecamp-export-test--with-root
    (let ((project (ebasecamp-export-test--define-world
                    root-dir "deploy/compose.yaml")))
      (should (equal (expand-file-name "deploy/compose.yaml" root-dir)
                     (ebasecamp-export-default-file project))))
    (let ((project (ebasecamp-export-test--define-world
                    root-dir "/tmp/ebc-export-abs/compose.yaml")))
      (should (equal "/tmp/ebc-export-abs/compose.yaml"
                     (ebasecamp-export-default-file project))))))

(ert-deftest ebasecamp-export-test-default-file-uses-root ()
  "没有 `:export-file' 时默认路径为 `<root>/docker-compose.ebasecamp.yaml'。"
  (ebasecamp-export-test--with-root
    (should (equal (expand-file-name "docker-compose.ebasecamp.yaml" root-dir)
                   (ebasecamp-export-default-file
                    (ebasecamp-export-test--define-world root-dir))))))

(ert-deftest ebasecamp-export-test-default-file-requires-root ()
  "`:root' 为 nil 且无 `:export-file' 时 signal `ebasecamp-export-error'。"
  (ebasecamp-export-test--with-root
    (ebasecamp-model-reset)
    (ebasecamp-define-group app :scope per-project :services ((api :image "x:1")))
    (ebasecamp-define-project noroot :groups ((app)))
    (should-error (ebasecamp-export-default-file
                   (ebasecamp-model-project 'noroot))
                  :type 'ebasecamp-export-error)
    ;; 显式传 :file 时不依赖 :root
    (ebasecamp-export-test--with-fake-check
        ebasecamp-export-test--ok-result
      (should (equal (expand-file-name "explicit.yaml" root-dir)
                     (ebasecamp-export-project
                      (ebasecamp-model-project 'noroot)
                      :file (expand-file-name "explicit.yaml" root-dir)))))))

;;; 2. 导出内容

(ert-deftest ebasecamp-export-test-writes-file-with-header ()
  "导出物落在默认路径，开头是 `#' 头注释（含来源/事实源/重新生成/shared 说明）。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-project project))
             (content (ebasecamp-export-test--read path))
             (lines (split-string content "\n" nil)))
        (should (equal (expand-file-name "docker-compose.ebasecamp.yaml" root-dir)
                       path))
        (should (file-exists-p path))
        ;; 前 4 行都是 `#' 注释
        (should (cl-every (lambda (line) (string-prefix-p "#" line))
                          (cl-subseq lines 0 4)))
        (should (string-match-p "由 ebasecamp 生成" (nth 0 lines)))
        (should (string-match-p "重新生成" content))
        ;; 事实源路径
        (should (string-match-p
                 (regexp-quote (ebasecamp-config-project-file
                                ebasecamp-export-test--project-name))
                 content))
        ;; shared 组未包含说明
        (should (string-match-p "shared 组" content))
        ;; compose 正文
        (should (string-match-p "^name: ebc-shop$" content))
        (should (string-match-p "services:" content))
        ;; 文件以单个换行结尾
        (should (string-suffix-p "\n" content))
        (should-not (string-suffix-p "\n\n" content))))))

(ert-deftest ebasecamp-export-test-no-external-network ()
  "导出物不声明 external network。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-project project))
             (content (ebasecamp-export-test--read path)))
        (should-not (string-match-p "external: true" content))
        (should-not (string-match-p "name: ebasecamp" content))
        ;; 服务自定义网络仍在顶层声明（由 compose 自建）
        (should (string-match-p "frontend: {}" content))))))

(ert-deftest ebasecamp-export-test-only-per-project-services ()
  "导出物只含 per-project 组的服务，shared 组的服务不出现。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-project project))
             (content (ebasecamp-export-test--read path)))
        (should (string-match-p "myapp/api:dev" content))
        (should (string-match-p "redis:7.4" content))
        (should-not (string-match-p "mysql:8.4" content))
        (should-not (string-match-p "adminer:4" content))
        ;; shared 组的端口与卷也不得出现
        (should-not (string-match-p "3306" content))
        (should-not (string-match-p "ebasecamp-shared-" content))
        ;; per-project 组的标签注入仍在（标签值按需加引号，这里不需要）
        (should (string-match-p "ebasecamp.group: app" content))
        (should (string-match-p "ebasecamp.scope: per-project" content))))))

(ert-deftest ebasecamp-export-test-keeps-variable-reference ()
  "导出物保留 `${VAR}' 字面量，不做插值。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-project project))
             (content (ebasecamp-export-test--read path)))
        (should (string-match-p
                 (regexp-quote "${EBASECAMP_MYSQL_ROOT_PASSWORD}") content))
        (should (string-match-p (regexp-quote "redis://cache:6379/0")
                                content))))))

;;; 3. 已存在冲突：非交互与 force

(ert-deftest ebasecamp-export-test-existing-without-force ()
  "目标已存在且无 force 时 signal，且原文件一字未动。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-default-file project)))
        (with-temp-file path (insert "sentinel\n"))
        (should-error (ebasecamp-export-project project)
                      :type 'ebasecamp-export-error)
        (should (equal "sentinel\n" (ebasecamp-export-test--read path)))))))

(ert-deftest ebasecamp-export-test-force-overwrites ()
  "`:force' 非 nil 时覆盖已存在的目标文件。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-default-file project)))
        (with-temp-file path (insert "sentinel\n"))
        (should (equal path (ebasecamp-export-project project :force t)))
        (let ((content (ebasecamp-export-test--read path)))
          (should-not (string-match-p "sentinel" content))
          (should (string-match-p "myapp/api:dev" content)))))))

;;; 4. 校验失败不落盘

(ert-deftest ebasecamp-export-test-check-failure-writes-nothing ()
  "校验失败时 signal 并删除临时文件，目标文件不产生。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check
        '(:ok nil :exit 1 :stderr "boom" :warnings nil)
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-default-file project))
             (error-data (should-error (ebasecamp-export-project project)
                                       :type 'ebasecamp-export-error)))
        (should (string-match-p "boom" (format "%s" (cdr error-data))))
        ;; 校验对象是同目录的临时文件
        (should (equal (concat path ".tmp") checked-file))
        (should-not (file-exists-p path))
        (should-not (file-exists-p (concat path ".tmp")))))))

(ert-deftest ebasecamp-export-test-check-failure-keeps-existing-file ()
  "校验失败且目标已存在（force 覆盖）时，目标文件保持原内容。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check
        '(:ok nil :exit 1 :stderr "boom" :warnings nil)
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-default-file project)))
        (with-temp-file path (insert "sentinel\n"))
        (should-error (ebasecamp-export-project project :force t)
                      :type 'ebasecamp-export-error)
        (should (equal "sentinel\n" (ebasecamp-export-test--read path)))
        (should-not (file-exists-p (concat path ".tmp")))))))

;;; 5. 交互分支（用 cl-letf 伪造 read-char-choice / read-file-name）

(defmacro ebasecamp-export-test--with-interactive (choice &rest body)
  "在「允许交互」且 `read-char-choice' 返回 CHOICE 的环境下执行 BODY。"
  (declare (indent 1) (debug t))
  `(let ((ebasecamp-export--interactive t)
         (noninteractive nil))
     (cl-letf (((symbol-function 'read-char-choice)
                (lambda (_prompt _chars) ,choice)))
       ,@body)))

(ert-deftest ebasecamp-export-test-interactive-cancel ()
  "交互式选「取消」时返回 nil，原文件不动。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-default-file project)))
        (with-temp-file path (insert "sentinel\n"))
        (ebasecamp-export-test--with-interactive ?c
          (should-not (ebasecamp-export-project project)))
        (should (equal "sentinel\n" (ebasecamp-export-test--read path)))))))

(ert-deftest ebasecamp-export-test-interactive-overwrite ()
  "交互式选「覆盖」时覆盖已有文件并返回路径。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-default-file project)))
        (with-temp-file path (insert "sentinel\n"))
        (ebasecamp-export-test--with-interactive ?o
          (should (equal path (ebasecamp-export-project project))))
        (should-not (string-match-p "sentinel"
                                    (ebasecamp-export-test--read path)))))))

(ert-deftest ebasecamp-export-test-interactive-change-path ()
  "交互式选「换一个路径」时写入 `read-file-name' 给出的新路径。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (path (ebasecamp-export-default-file project))
             (other (expand-file-name "other.yaml" root-dir)))
        (with-temp-file path (insert "sentinel\n"))
        (ebasecamp-export-test--with-interactive ?r
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _) other)))
            (should (equal other (ebasecamp-export-project project)))))
        (should (file-exists-p other))
        (should (string-match-p "myapp/api:dev"
                                (ebasecamp-export-test--read other)))
        ;; 原文件仍未被覆盖
        (should (equal "sentinel\n" (ebasecamp-export-test--read path)))))))

;;; 6. 真实 docker：校验与往返

(ert-deftest ebasecamp-export-test-real-check-passes ()
  "真实 `docker compose config -q' 校验导出物通过（docker 不可用时跳过）。"
  (ebasecamp-export-test--skip-unless-docker)
  (ebasecamp-export-test--with-root
    (let* ((project (ebasecamp-export-test--define-world root-dir))
           (path (ebasecamp-export-project project))
           (result (ebasecamp-docker-check-compose path)))
      (should (file-exists-p path))
      (should (plist-get result :ok)))))

(ert-deftest ebasecamp-export-test-roundtrip-service-names ()
  "导出物经 `config --format json' 读回，服务名集合与 per-project 服务一致。"
  (ebasecamp-export-test--skip-unless-docker)
  (ebasecamp-export-test--with-root
    (let* ((project (ebasecamp-export-test--define-world root-dir))
           (path (ebasecamp-export-project project))
           (result (ebasecamp-docker-run-sync
                    (list "compose" "-f" (expand-file-name path) "config"
                          "--no-interpolate" "--no-env-resolution"
                          "--no-path-resolution" "--format" "json"))))
      (should (eq 0 (plist-get result :exit)))
      (let* ((json (json-parse-string (plist-get result :stdout)
                                      :object-type 'hash-table))
             (services (gethash "services" json))
             (names nil))
        (maphash (lambda (name _value) (push name names)) services)
        (should (equal '("api" "cache") (sort names #'string<)))
        ;; 往返后 `${VAR}' 仍是引用形态
        (should (string-match-p
                 (regexp-quote "${EBASECAMP_MYSQL_ROOT_PASSWORD}")
                 (plist-get result :stdout)))))))

;;; 7. 安全：不落盘明文密钥

(ert-deftest ebasecamp-export-test-no-plaintext-secret ()
  "环境变量给探针明文后导出，导出物只含 `${VAR}' 引用。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let ((probe "fake-export-secret"))
        (unwind-protect
            (progn
              (setenv "EBASECAMP_MYSQL_ROOT_PASSWORD" probe)
              (let* ((project (ebasecamp-export-test--define-world root-dir))
                     (path (ebasecamp-export-project project))
                     (content (ebasecamp-export-test--read path)))
                (should (string-match-p
                         (regexp-quote "${EBASECAMP_MYSQL_ROOT_PASSWORD}")
                         content))
                (should-not (string-match-p (regexp-quote probe) content))))
          (setenv "EBASECAMP_MYSQL_ROOT_PASSWORD" nil))))))

;;; 8. 交互式命令入口

(ert-deftest ebasecamp-export-test-command-selects-project ()
  "未传 PROJECT 时用 `completing-read' 选项目并导出，返回路径。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (ebasecamp-export-test--define-world root-dir)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "shop")))
        (let ((path (ebasecamp-export-compose)))
          (should (equal (expand-file-name "docker-compose.ebasecamp.yaml"
                                          root-dir)
                         path))
          (should (file-exists-p path)))))))

(ert-deftest ebasecamp-export-test-command-honors-file-argument ()
  "显式传 FILE 时导出到该路径。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--define-world root-dir))
             (target (expand-file-name "deploy/out.yaml" root-dir)))
        (should (equal target (ebasecamp-export-compose project target)))
        (should (file-exists-p target))
        (should (string-match-p "myapp/api:dev"
                                (ebasecamp-export-test--read target)))))))

;;; 9. 绑定宿主 IP 端口（tech-debt #21 / D5）

(defun ebasecamp-export-test--host-ip-port-world (root)
  "在 ROOT 下注册含「绑定宿主 IP 端口」的清单，返回项目对象。
端口对象走导入层真实形态（`published' 字符串、`target' 整数），进服务
`:extra' 的 \"ports\" 键 —— 渲染层必须把它当序列而非映射。"
  (ebasecamp-model-reset)
  (ebasecamp-model--register-group
   'web
   (list :title "Web"
         :scope 'per-project
         :services
         '((web
            :image "nginx:1.27"
            :extra (("ports" (("host_ip" . "127.0.0.1")
                              ("mode" . "ingress")
                              ("protocol" . "tcp")
                              ("published" . "18097")
                              ("target" . 80))))))))
  (ebasecamp-model--register-project
   'site
   (list :title "Site" :root root
         :groups '((web :scope per-project)))))

(ert-deftest ebasecamp-export-test-render-host-ip-port-passes-config-q ()
  "含绑定宿主 IP 端口的项目可导出：ports 段为合法长语法，校验通过即落盘。
校验用 `cl-letf' 打桩（真实 docker 见 batch 闭环），因此本用例不依赖 docker。"
  (ebasecamp-export-test--with-root
    (ebasecamp-export-test--with-fake-check ebasecamp-export-test--ok-result
      (let* ((project (ebasecamp-export-test--host-ip-port-world root-dir))
             (path (ebasecamp-export-project project))
             (text (ebasecamp-export-test--read path)))
        ;; 导出成功且临时文件已被 rename 掉
        (should (file-exists-p path))
        (should-not (file-exists-p checked-file))
        ;; ports 段是「序列 + 对象映射」的正确形态
        (should (string-match-p "^    ports:$" text))
        (should (string-match-p "^\\s-+host_ip: 127\\.0\\.0\\.1$" text))
        (should (string-match-p "^\\s-+target: 80$" text))
        (should-not (string-match-p "(host_ip" text))))))

(provide 'ebasecamp-export-tests)
;;; ebasecamp-export-tests.el ends here
