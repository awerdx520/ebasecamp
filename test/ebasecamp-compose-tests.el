;;; ebasecamp-compose-tests.el --- ebasecamp compose 生成测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T1.3 compose 生成层（清单 → compose YAML，只写不解析）的 ERT 测试。
;;
;; 覆盖范围：项目命名不变量（ebc-shared / ebc-<project>）与项目名/组名
;; 字符集校验、单服务与多服务渲染、environment 中 ${VAR} 原样保留、标签
;; 注入优先级、命名卷与 bind 卷、external network 附加与关闭、group-filter
;; 过滤、extra 字段序列化与引号策略、healthcheck 与 depends_on 形态、
;; 生成物落盘路径与内容、结尾换行、mapping 判据（alist vs alist 列表）。

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

(defun ebasecamp-compose-test--cross-depends ()
  "构造跨 scope 依赖的清单，返回 shop 项目对象。
shared 组 mysql 提供 mysql；per-project 组 app 提供 api（依赖 mysql 与同组
worker）与 worker；per-project 组 tools 提供 migrate（只依赖 mysql，属组外）。
mysql 属 shared 组而 api、migrate 属 per-project 组，两批落在不同 compose
项目（ebc-shared / ebc-shop），因此跨集合依赖必须按 scope 剔除。"
  (ebasecamp-define-group mysql
    :title "MySQL"
    :scope shared
    :services
    ((mysql :image "mysql:8.4")))
  (ebasecamp-define-group app
    :scope per-project
    :services
    ((api :image "app:1" :depends-on ("mysql" "worker"))
     (worker :image "app:1")))
  (ebasecamp-define-group tools
    :scope per-project
    :services
    ((migrate :image "app:1" :depends-on ("mysql"))))
  (ebasecamp-define-project shop :groups ((mysql) (app) (tools)))
  (ebasecamp-model-project 'shop))

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
  "depends_on 在全量渲染中渲染为 block 列表（含跨组合法依赖）。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--manifest))
           (yaml (ebasecamp-compose-render project)))
      (should (string-match-p "    depends_on:\n      - mysql" yaml))
      (should (string-match-p
               (regexp-quote "    command: [\"serve\",\"--port\",\"8080\"]") yaml)))))

;;; 13. 跨 scope depends_on（tech-debt #13）

(ert-deftest ebasecamp-compose-test-filter-keeps-in-set-depends-on ()
  "filter 渲染：依赖落在同一生成物的服务被保留。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--cross-depends))
           (yaml (ebasecamp-compose-render project '(app tools))))
      (should (string-match-p "^name: ebc-shop$" yaml))
      ;; api 依赖 worker（同为 app 组）→ 保留
      (should (string-match-p "    depends_on:\n      - worker\n" yaml)))))

(ert-deftest ebasecamp-compose-test-filter-drops-cross-set-depends-on ()
  "filter 渲染：依赖指向集合外服务（跨 compose 项目）时被剔除。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--cross-depends))
           (yaml (ebasecamp-compose-render project '(app))))
      (should (string-match-p "^  api:$" yaml))
      (should (string-match-p "    depends_on:\n      - worker\n" yaml))
      (should-not (string-match-p (regexp-quote "- mysql") yaml))
      (should-not (string-match-p "mysql" yaml)))))

(ert-deftest ebasecamp-compose-test-filter-drops-empty-depends-on ()
  "filter 渲染：剔除后依赖为空时生成物不出现 depends_on 键。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--cross-depends))
           (yaml (ebasecamp-compose-render project '(tools))))
      (should (string-match-p "^  migrate:$" yaml))
      (should-not (string-match-p "depends_on" yaml))
      (should-not (string-match-p "mysql" yaml)))))

(ert-deftest ebasecamp-compose-test-no-filter-keeps-cross-set-depends-on ()
  "无 filter 渲染（预览/导出）行为不变：跨组依赖完整保留。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--cross-depends))
           (yaml (ebasecamp-compose-render project)))
      (should (string-match-p
               "    depends_on:\n      - mysql\n      - worker\n" yaml))
      (should (string-match-p "    depends_on:\n      - mysql\n" yaml)))))

;;; 14. cache-file / write 的 shared 分支

(ert-deftest ebasecamp-compose-test-cache-file-shared-directory ()
  "只过滤出 shared 组时生成物目录为 _shared，混合或不过滤时为项目名。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--manifest))
           (shared (ebasecamp-compose-cache-file project 'mysql))
           (own (ebasecamp-compose-cache-file project 'app))
           (all (ebasecamp-compose-cache-file project))
           (root (file-name-as-directory
                  (expand-file-name ebasecamp-cache-directory))))
      (should (equal (expand-file-name "_shared/compose.yaml" root) shared))
      (should (equal (expand-file-name "myapp/compose.yaml" root) own))
      (should (equal (expand-file-name "myapp/compose.yaml" root) all))
      ;; 纯路径计算，不写盘
      (should-not (file-exists-p shared)))))

(ert-deftest ebasecamp-compose-test-write-shared-branch ()
  "write 在 group-filter 只含 shared 组时写入 _shared/compose.yaml。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--manifest))
           (path (ebasecamp-compose-write project 'mysql))
           (root (file-name-as-directory
                  (expand-file-name ebasecamp-cache-directory)))
           (content (with-temp-buffer
                      (insert-file-contents path)
                      (buffer-string))))
      (should (equal (expand-file-name "_shared/compose.yaml" root) path))
      (should (file-exists-p path))
      (should (equal (ebasecamp-compose-render project 'mysql) content))
      (should (string-match-p "^name: ebc-shared$" content))
      (should (string-match-p "^  mysql:$" content))
      (should-not (string-match-p "^  api:$" content)))))

;;; 15. mapping 判据（tech-debt #21 / D5）

(defun ebasecamp-compose-test--host-ip-port ()
  "构造含「绑定宿主 IP 端口」的项目，返回项目对象。
端口对象取自导入层真实形态（D3 实测）：`published' 是字符串、`target' 是
整数，整份对象列表落在服务的 `:extra' 里（键为 \"ports\"）。"
  (ebasecamp-define-group web
    :services
    ((web :image "nginx:1.27"
          :extra (("ports" (("host_ip" . "127.0.0.1")
                            ("mode" . "ingress")
                            ("protocol" . "tcp")
                            ("published" . "18097")
                            ("target" . 80)))))))
  (ebasecamp-define-project site :root "/tmp/ebc-site" :groups ((web)))
  (ebasecamp-model-project 'site))

(ert-deftest ebasecamp-compose-test-mapping-p-rejects-plist-list ()
  "字符串键的 alist 判为映射；「单元素 alist 列表」判为非映射（走序列分支）。"
  (should (ebasecamp-compose--mapping-p '(("a" . "b"))))
  (should (ebasecamp-compose--mapping-p '(("a" . "b") ("c" . "d"))))
  ;; 形如 ((("host_ip" . "127.0.0.1") …))：列表里放的是端口对象，不是键值对
  (should-not (ebasecamp-compose--mapping-p
               '((("host_ip" . "127.0.0.1") ("target" . 80)))))
  (should-not (ebasecamp-compose--mapping-p '((("a" . "b") ("c" . "d")))))
  ;; 空值与纯标量序列都不是映射
  (should-not (ebasecamp-compose--mapping-p nil))
  (should-not (ebasecamp-compose--mapping-p '("a" "b"))))

(ert-deftest ebasecamp-compose-test-yaml-renders-port-object-list-as-sequence ()
  "`:extra' 里的端口对象列表渲染为 block 序列（compose 长语法）。
不再把 alist 当 (KEY . VALUE) 对展开，因而不产出 `(host_ip . 127.0.0.1):'
这类垃圾键。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--host-ip-port))
           (yaml (ebasecamp-compose-render project)))
      (should (string-match-p "^    ports:$" yaml))
      ;; 恰好一层序列项：`-' 单独成行，对象字段在下一层缩进（不重复嵌套）
      (should (string-match-p
               "    ports:\n      -\\s-*\n        host_ip: 127\\.0\\.0\\.1\n"
               yaml))
      (should (string-match-p "^\\s-+mode: ingress$" yaml))
      (should (string-match-p "^\\s-+protocol: tcp$" yaml))
      ;; published 是字符串，加引号后才不会被 compose 读成整数之外的类型
      (should (string-match-p "^\\s-+published: \"18097\"$" yaml))
      (should (string-match-p "^\\s-+target: 80$" yaml))
      (should-not (string-match-p "(host_ip" yaml))
      (should-not (string-match-p "127\\.0\\.0\\.1):" yaml)))))

;;; 16. 同名桶合并（tech-debt #23 / D6）

(defun ebasecamp-compose-test--line-count (line text)
  "返回 TEXT 中与 LINE 完全相同的行数（按行精确比较，避免子串误计）。"
  (let ((count 0))
    (dolist (candidate (split-string text "\n"))
      (when (equal line candidate)
        (setq count (1+ count))))
    count))

(defun ebasecamp-compose-test--mixed-ports-and-volumes ()
  "构造「可表达 + 不可表达」端口与卷并存的项目，返回项目对象。
端口与卷对象取自导入层真实形态（D3 实测）：不可表达项以原始对象列表落在
服务 `:extra' 的 \"ports\" / \"volumes\" 桶里；另带一个无关 `:extra' 键
`shm_size' 用于验证其余键照旧展开。"
  (ebasecamp-define-group web
    :services
    ((web :image "nginx:1.27"
          :ports ((8080 . 80))
          :volumes ((:source "./src" :target "/app/src" :type bind))
          :extra (("shm_size" . "128m")
                  ;; 可表达 8080:80 之外的 udp 端口对象
                  ("ports" (("host_ip" . "127.0.0.1")
                            ("mode" . "ingress")
                            ("protocol" . "udp")
                            ("published" . "9090")
                            ("target" . 9090)))
                  ;; bind 卷之外的 tmpfs 卷对象
                  ("volumes" (("type" . "tmpfs")
                              ("target" . "/tmp")))))))
  (ebasecamp-define-project site :root "/tmp/ebc-site" :groups ((web)))
  (ebasecamp-model-project 'site))

(ert-deftest ebasecamp-compose-test-renders-single-ports-key-when-mixed ()
  "显式 `:ports' 与 `:extra' 的 ports 桶并存时只渲染一个 ports 键。
简单项（\"8080:80\" 字符串）在前、复杂对象项（alist）在后，各自形状完整。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--mixed-ports-and-volumes))
           (yaml (ebasecamp-compose-render project)))
      (should (= 1 (ebasecamp-compose-test--line-count "    ports:" yaml)))
      (should (string-match-p
               (concat "    ports:\n"
                       "      - \"8080:80\"\n"
                       "      -\\s-*\n"
                       "        host_ip: 127\\.0\\.0\\.1\n"
                       "        mode: ingress\n"
                       "        protocol: udp\n"
                       "        published: \"9090\"\n"
                       "        target: 9090\n")
               yaml))
      ;; 不得再出现把 alist 当键展开的垃圾键
      (should-not (string-match-p "(host_ip" yaml)))))

(ert-deftest ebasecamp-compose-test-renders-single-volumes-key-when-mixed ()
  "bind 卷与 `:extra' 的 tmpfs 卷并存时只渲染一个 volumes 键，两项都在。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--mixed-ports-and-volumes))
           (yaml (ebasecamp-compose-render project)))
      (should (= 1 (ebasecamp-compose-test--line-count "    volumes:" yaml)))
      (should (string-match-p
               (concat "    volumes:\n"
                       "      - \"./src:/app/src\"\n"
                       "      -\\s-*\n"
                       "        type: tmpfs\n"
                       "        target: /tmp\n")
               yaml))
      ;; 顶层 volumes 段只声明命名卷：本清单无命名卷，故不该出现
      (should (= 0 (ebasecamp-compose-test--line-count "volumes:" yaml))))))

(ert-deftest ebasecamp-compose-test-extra-without-ports-volumes-unchanged ()
  "其余 `:extra' 键照旧渲染，位置仍为服务体末尾。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--mixed-ports-and-volumes))
           (yaml (ebasecamp-compose-render project)))
      (should (= 1 (ebasecamp-compose-test--line-count "    shm_size: 128m" yaml)))
      ;; 服务体最后一行仍是 extra 展开出来的 shm_size（其后即顶层 networks 段）
      (should (string-match-p "    shm_size: 128m\nnetworks:" yaml)))))

(ert-deftest ebasecamp-compose-test-no-ports-no-volumes-still-omits-keys ()
  "既无显式端口/卷、也无同名 extra 桶时不渲染 ports / volumes 键。"
  (ebasecamp-compose-test--clean
    (let* ((project (ebasecamp-compose-test--no-network))
           (yaml (ebasecamp-compose-render project)))
      (should (= 0 (ebasecamp-compose-test--line-count "    ports:" yaml)))
      (should (= 0 (ebasecamp-compose-test--line-count "    volumes:" yaml))))))

;;; ebasecamp-compose-tests.el ends here
