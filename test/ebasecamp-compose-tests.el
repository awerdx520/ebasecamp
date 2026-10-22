;;; ebasecamp-compose-tests.el --- ebasecamp compose 生成测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T1.3 compose 生成层（清单 → compose YAML，只写不解析）的 ERT 测试。
;;
;; 覆盖范围：项目命名不变量（ebc-shared / ebc-<project>）与项目名/组名
;; 字符集校验、单服务与多服务渲染、environment 中 ${VAR} 原样保留、标签
;; 注入优先级、命名卷与 bind 卷、external network 附加与关闭、group-filter
;; 过滤、extra 字段序列化与引号策略、healthcheck 与 depends_on 形态、
;; 生成物落盘路径与内容、结尾换行。

;;; Code:

(require 'ert)
(require 'ebasecamp-model)
(require 'ebasecamp-compose)

;;; 测试脚手架

(defmacro ebasecamp-compose-test--clean (&rest body)
  "在清空的注册表与临时缓存目录下顺序执行 BODY，结束后清理。"
  (declare (indent 0) (debug t))
  `(let ((ebasecamp-cache-directory
          (file-name-as-directory (make-temp-file "ebasecamp-cache-test-" t))))
     (ebasecamp-model-reset)
     (unwind-protect
         (progn ,@body)
       (ebasecamp-model-reset)
       (ignore-errors (delete-directory ebasecamp-cache-directory t)))))

(defun ebasecamp-compose-test--single ()
  "构造单服务清单：per-project 组 db + 项目 myapp，返回 myapp 项目对象。"
  (ebasecamp-define-group db
    :title "数据库"
    :services
    ((mysql :image "mysql:8.4"
            :environment (("MYSQL_DATABASE" . "dev")
                          ("MYSQL_ROOT_PASSWORD"
                           . "${EBASECAMP_MYSQL_ROOT_PASSWORD}"))
            :ports ((3306 . 3306))
            :volumes ((:source "mysql-data"
                       :target "/var/lib/mysql"
                       :type volume)))))
  (ebasecamp-define-project myapp :groups ((db)))
  (ebasecamp-model-project 'myapp))

(defun ebasecamp-compose-test--manifest ()
  "构造多组清单：shared 组 mysql + per-project 组 app + 项目 myapp。
返回 myapp 项目对象；项目依次引用 shared 与 per-project 各一个组。"
  (ebasecamp-define-group mysql
    :title "MySQL 基础组件"
    :scope shared
    :services
    ((mysql :image "mysql:8.4"
            :environment (("MYSQL_DATABASE" . "dev")
                          ("MYSQL_ROOT_PASSWORD"
                           . "${EBASECAMP_MYSQL_ROOT_PASSWORD}"))
            :ports ((3306 . 3306))
            :volumes ((:source "mysql-data"
                       :target "/var/lib/mysql"
                       :type volume))
            :healthcheck (:test ("CMD" "mysqladmin" "ping")
                          :interval "10s"
                          :timeout "5s"
                          :retries 3))))
  (ebasecamp-define-group app
    :scope per-project
    :services
    ((api :image "app:1"
          :command ("serve" "--port" "8080")
          :ports ((8080 . 8080))
          :depends-on ("mysql")
          :networks ("internal")
          :labels (("ebasecamp.project" . "hacked")
                   ("custom.label" . "kept"))
          :volumes ((:source "./conf"
                     :target "/etc/app"
                     :type bind
                     :read-only t))
          :extra (("description" . "local api: dev")))))
  (ebasecamp-define-project myapp :groups ((mysql) (app)))
  (ebasecamp-model-project 'myapp))

(defun ebasecamp-compose-test--no-network ()
  "构造关闭 shared-network 的项目清单，返回该项目对象。"
  (ebasecamp-define-group web
    :services ((web :image "nginx:1.27")))
  (ebasecamp-define-project solo :shared-network nil :groups ((web)))
  (ebasecamp-model-project 'solo))

(defun ebasecamp-compose-test--custom-network ()
  "构造关闭 shared-network 但服务引用自定义网络的项目清单。
返回该项目对象。"
  (ebasecamp-define-group queue
    :services ((rabbit :image "rabbitmq:4" :networks ("mqnet"))))
  (ebasecamp-define-project job :shared-network nil :groups ((queue)))
  (ebasecamp-model-project 'job))

;;; 1. 项目命名

(ert-deftest ebasecamp-compose-test-project-name-by-scope ()
  "shared 组的 compose 项目名为 ebc-shared，per-project 为 ebc-<project>。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--manifest))
           (refs (ebasecamp-project-groups project)))
      (should (equal "ebc-shared"
                     (ebasecamp-compose-project-name project (nth 0 refs))))
      (should (equal "ebc-myapp"
                     (ebasecamp-compose-project-name project (nth 1 refs))))
      ;; 组对象与组名 symbol 同样支持
      (should (equal "ebc-shared"
                     (ebasecamp-compose-project-name
                      project (ebasecamp-model-group 'mysql))))
      (should (equal "ebc-myapp"
                     (ebasecamp-compose-project-name project 'app))))))

(ert-deftest ebasecamp-compose-test-project-name-rejects-invalid-names ()
  "项目名或组名不匹配 [a-z0-9_-]+ 时触发 ebasecamp-compose-error。"
  (ebasecamp-compose-test--clean
    ;; 项目名含大写
    (ebasecamp-define-group ok :services ((s :image "img")))
    (ebasecamp-define-project MyApp :groups ((ok)))
    (should-error
     (ebasecamp-compose-project-name
      (ebasecamp-model-project 'MyApp)
      (car (ebasecamp-project-groups (ebasecamp-model-project 'MyApp))))
     :type 'ebasecamp-compose-error)
    ;; 项目名含点号
    (ebasecamp-define-project my.app :groups ((ok)))
    (should-error
     (ebasecamp-compose-project-name
      (ebasecamp-model-project 'my.app)
      (car (ebasecamp-project-groups (ebasecamp-model-project 'my.app))))
     :type 'ebasecamp-compose-error)
    ;; 组名含空格
    (let ((bad (intern "bad group")))
      (eval `(ebasecamp-define-group ,bad :services ((s :image "img"))) t)
      (eval `(ebasecamp-define-project p :groups ((,bad))) t)
      (should-error
       (ebasecamp-compose-project-name
        (ebasecamp-model-project 'p)
        (car (ebasecamp-project-groups (ebasecamp-model-project 'p))))
       :type 'ebasecamp-compose-error))))

;;; 2. 单服务渲染

(ert-deftest ebasecamp-compose-test-render-single-service ()
  "单服务渲染产出 name、image、端口与五项注入标签。"
  (ebasecamp-compose-test--clean
    (let ((yaml (ebasecamp-compose-render (ebasecamp-compose-test--single))))
      (should (string-prefix-p "name: ebc-myapp\n" yaml))
      (should (string-match-p "^name: ebc-myapp$" yaml))
      (should (string-match-p "^  mysql:$" yaml))
      (should (string-match-p "image: mysql:8.4" yaml))
      (should (string-match-p "^      - \"3306:3306\"$" yaml))
      (should (string-match-p "ebasecamp\\.managed: \"true\"" yaml))
      (should (string-match-p "ebasecamp\\.project: myapp" yaml))
      (should (string-match-p "ebasecamp\\.group: db" yaml))
      (should (string-match-p "ebasecamp\\.service: mysql" yaml))
      (should (string-match-p "ebasecamp\\.scope: per-project" yaml))
      ;; environment 键值：普通值裸写
      (should (string-match-p "MYSQL_DATABASE: dev" yaml)))))

;;; 3. 多服务

(ert-deftest ebasecamp-compose-test-render-multiple-services ()
  "两个组的服务都出现在 services 段下。"
  (ebasecamp-compose-test--clean
    (let ((yaml (ebasecamp-compose-render (ebasecamp-compose-test--manifest))))
      (should (string-match-p "^name: ebc-myapp$" yaml))
      (should (string-match-p "^services:$" yaml))
      (should (string-match-p "^  mysql:$" yaml))
      (should (string-match-p "^  api:$" yaml))
      (should (string-match-p "ebasecamp\\.scope: shared" yaml))
      (should (string-match-p "ebasecamp\\.scope: per-project" yaml)))))

;;; 4. ${VAR} 原样保留

(ert-deftest ebasecamp-compose-test-keeps-variable-reference ()
  "environment 中的 ${VAR} 原样保留：不插值、不转义 $。"
  (ebasecamp-compose-test--clean
    (let ((project (ebasecamp-compose-test--single))
          (probe "PLAINTEXT-SECRET-PROBE"))
      (setenv "EBASECAMP_MYSQL_ROOT_PASSWORD" probe)
      (unwind-protect
          (let ((yaml (ebasecamp-compose-render project)))
            (should (string-match-p
                     (regexp-quote "${EBASECAMP_MYSQL_ROOT_PASSWORD}") yaml))
            (should-not (string-match-p (regexp-quote probe) yaml))
            (should-not (string-match-p "\\\\\\${" yaml)))
        (setenv "EBASECAMP_MYSQL_ROOT_PASSWORD" nil)))))

;;; 5. 标签注入优先

(ert-deftest ebasecamp-compose-test-injected-labels-win ()
  "用户 labels 与注入 labels 同名时注入优先，其余用户标签保留。"
  (ebasecamp-compose-test--clean
    (let ((yaml (ebasecamp-compose-render (ebasecamp-compose-test--manifest))))
      (should (string-match-p "ebasecamp\\.project: myapp" yaml))
      (should-not (string-match-p "hacked" yaml))
      (should (string-match-p "custom\\.label: kept" yaml)))))

;;; 6. 卷

(ert-deftest ebasecamp-compose-test-render-named-volume ()
  "命名卷在服务内引用 ebasecamp-<scope>-<group>-<source>，并在顶层声明。"
  (ebasecamp-compose-test--clean
    (let ((yaml (ebasecamp-compose-render (ebasecamp-compose-test--single))))
      (should (string-match-p
               (regexp-quote "- \"ebasecamp-per-project-db-mysql-data:/var/lib/mysql\"")
               yaml))
      (should (string-match-p "^volumes:$" yaml))
      (should (string-match-p
               (regexp-quote "  ebasecamp-per-project-db-mysql-data: {}")
               yaml)))))

(ert-deftest ebasecamp-compose-test-render-bind-volume ()
  "bind 卷原样输出 source:target，read-only 时追加 :ro，且不产生顶层声明。"
  (ebasecamp-compose-test--clean
    (let ((yaml (ebasecamp-compose-render (ebasecamp-compose-test--manifest)
                                          'app)))
      (should (string-match-p (regexp-quote "- \"./conf:/etc/app:ro\"") yaml))
      (should-not (string-match-p "^volumes:$" yaml)))))

;;; 7. 网络

(ert-deftest ebasecamp-compose-test-render-without-shared-network ()
  "shared-network 为 nil 且无自定义网络时无顶层 networks 段。"
  (ebasecamp-compose-test--clean
    (let ((yaml (ebasecamp-compose-render (ebasecamp-compose-test--no-network))))
      (should-not (string-match-p (regexp-quote "- ebasecamp") yaml))
      (should-not (string-match-p "^networks:$" yaml)))))

(ert-deftest ebasecamp-compose-test-render-declares-custom-network ()
  "服务引用的自定义网络在顶层以空映射声明（否则 config -q 报未定义网络）。"
  (ebasecamp-compose-test--clean
    (let ((yaml (ebasecamp-compose-render
                 (ebasecamp-compose-test--custom-network))))
      (should (string-match-p "^      - mqnet$" yaml))
      (should (string-match-p "^networks:$" yaml))
      (should (string-match-p "^  mqnet: {}$" yaml))
      (should-not (string-match-p "^  ebasecamp:$" yaml)))))

(ert-deftest ebasecamp-compose-test-render-with-shared-network ()
  "shared-network 非 nil 时服务加入 ebasecamp，顶层声明 external network。"
  (ebasecamp-compose-test--clean
    (let ((yaml (ebasecamp-compose-render (ebasecamp-compose-test--manifest))))
      (should (string-match-p "^networks:$" yaml))
      (should (string-match-p "^  ebasecamp:$" yaml))
      (should (string-match-p "^    external: true$" yaml))
      (should (string-match-p "^    name: ebasecamp$" yaml))
      (should (string-match-p "^  internal: {}$" yaml))
      (should (string-match-p "^      - internal$" yaml))
      (should (string-match-p "^      - ebasecamp$" yaml)))))

;;; 8. group-filter

(ert-deftest ebasecamp-compose-test-render-group-filter ()
  "group-filter 只渲染指定组；shared 组单独生成时项目名为 ebc-shared。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--manifest))
           (shared (ebasecamp-compose-render project 'mysql))
           (own (ebasecamp-compose-render project 'app)))
      (should (string-match-p "^name: ebc-shared$" shared))
      (should (string-match-p "^  mysql:$" shared))
      (should-not (string-match-p "^  api:$" shared))
      (should (string-match-p "^name: ebc-myapp$" own))
      (should (string-match-p "^  api:$" own))
      (should-not (string-match-p "^  mysql:$" own))
      ;; 列表形式等价
      (should (equal shared (ebasecamp-compose-render project '(mysql)))))))

;;; 9. extra 与引号策略

(ert-deftest ebasecamp-compose-test-render-extra-description ()
  "extra 字段原样转 YAML，含特殊字符的字符串加双引号。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--manifest))
           (yaml (ebasecamp-compose-render project 'app)))
      (should (string-match-p
               (regexp-quote "description: \"local api: dev\"") yaml)))))

;;; 10. 落盘

(ert-deftest ebasecamp-compose-test-write-creates-cache-file ()
  "write 在缓存目录 <dir>/<project>/compose.yaml 落盘，内容等于 render 结果。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--single))
           (path (ebasecamp-compose-cache-file project)))
      (should (string-match-p "/myapp/compose\\.yaml\\'" path))
      (should-not (file-exists-p path))
      (let ((written (ebasecamp-compose-write project)))
        (should (equal path written))
        (should (file-exists-p written))
        (should (equal (ebasecamp-compose-render project)
                       (with-temp-buffer
                         (insert-file-contents written)
                         (buffer-string))))))))

;;; 11. 结尾换行

(ert-deftest ebasecamp-compose-test-render-ends-with-single-newline ()
  "渲染结果以单个换行结尾，不出现多余空行。"
  (ebasecamp-compose-test--clean
    (dolist (yaml (list (ebasecamp-compose-render
                         (ebasecamp-compose-test--manifest))
                        (ebasecamp-compose-render
                         (ebasecamp-compose-test--no-network))))
      (should (string-suffix-p "\n" yaml))
      (should-not (string-suffix-p "\n\n" yaml))
      (should-not (string-match-p "\n\n" yaml)))))

;;; 12. healthcheck 与 depends_on

(ert-deftest ebasecamp-compose-test-render-healthcheck ()
  "healthcheck 渲染为 block 映射，test 为 flow 列表。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--manifest))
           (yaml (ebasecamp-compose-render project 'mysql)))
      (should (string-match-p "^    healthcheck:$" yaml))
      (should (string-match-p
               (regexp-quote "      test: [\"CMD\",\"mysqladmin\",\"ping\"]")
               yaml))
      (should (string-match-p "^      interval: 10s$" yaml))
      (should (string-match-p "^      timeout: 5s$" yaml))
      (should (string-match-p "^      retries: 3$" yaml)))))

(ert-deftest ebasecamp-compose-test-render-depends-on ()
  "depends_on 渲染为 block 列表。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--manifest))
           (yaml (ebasecamp-compose-render project 'app)))
      (should (string-match-p "    depends_on:\n      - mysql" yaml))
      (should (string-match-p
               (regexp-quote "    command: [\"serve\",\"--port\",\"8080\"]") yaml)))))

;;; ebasecamp-compose-tests.el ends here
