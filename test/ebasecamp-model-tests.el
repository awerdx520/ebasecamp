;;; ebasecamp-model-tests.el --- ebasecamp 数据模型测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T1.1 数据模型层（纯数据、无 IO）的 ERT 测试。
;;
;; 覆盖范围：定义宏的合法定义与字段校验、注册表与重复检测、
;; 项目组引用归一化、项目覆盖合并（整体替换 / 按键合并 / 不可变性）、
;; 组内配置（:configs）的解析与访问器。

;;; Code:

(require 'ert)
(require 'ebasecamp-model)

(defmacro ebasecamp-model-test--clean (&rest body)
  "在清空的注册表下顺序执行 BODY，结束后再次清空注册表。"
  (declare (indent 0) (debug t))
  `(progn
     (ebasecamp-model-reset)
     (unwind-protect
         (progn ,@body)
       (ebasecamp-model-reset))))

;;; 1. 组注册与默认值

(ert-deftest ebasecamp-model-test-define-group-registers-group ()
  "定义组后可取回，且 title 默认是 symbol 名、scope 默认 per-project。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group mysql
      :services ((mysql :image "mysql:8.4")))

    (let ((group (ebasecamp-model-group 'mysql)))
      (should (ebasecamp-group-p group))
      (should (eq 'mysql (ebasecamp-group-name group)))
      (should (equal "mysql" (ebasecamp-group-title group)))
      (should (eq 'per-project (ebasecamp-group-scope group)))
      (should (= 1 (length (ebasecamp-group-services group))))
      (should (equal "mysql:8.4"
                     (ebasecamp-service-image
                      (car (ebasecamp-group-services group)))))
      (should (equal '(mysql)
                     (mapcar #'ebasecamp-group-name
                             (ebasecamp-model-groups)))))))

;;; 2. 未知关键字

(ert-deftest ebasecamp-model-test-define-group-rejects-unknown-keyword ()
  "组定义中的未知关键字触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (should-error
     (eval '(ebasecamp-define-group g
              :services ((s :image "img"))
              :bogus t)
           t)
     :type 'ebasecamp-model-error)))

;;; 3. 服务缺 :image

(ert-deftest ebasecamp-model-test-service-requires-image ()
  "服务缺少 :image 时触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (should-error
     (eval '(ebasecamp-define-group g
              :services ((s :ports ((80 . 80)))))
           t)
     :type 'ebasecamp-model-error)))

;;; 4. 非法 scope

(ert-deftest ebasecamp-model-test-rejects-invalid-scope ()
  "非法 :scope 值触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (should-error
     (eval '(ebasecamp-define-group g
              :scope global
              :services ((s :image "img")))
           t)
     :type 'ebasecamp-model-error)))

;;; 5. ports 必须是整数对

(ert-deftest ebasecamp-model-test-ports-require-integer-pairs ()
  "ports 元素不是整数对时触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (should-error
     (eval '(ebasecamp-define-group g
              :services ((s :image "img" :ports ((8080 . "8080")))))
           t)
     :type 'ebasecamp-model-error)
    (should-error
     (eval '(ebasecamp-define-group h
              :services ((s :image "img" :ports ((8080 8080)))))
           t)
     :type 'ebasecamp-model-error)))

;;; 6. 重复注册与 reset

(ert-deftest ebasecamp-model-test-duplicate-group-rejected-then-reset ()
  "重复注册同名组报错；reset 后可重新定义。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g :services ((s :image "img")))
    (should-error
     (eval '(ebasecamp-define-group g :services ((s :image "img"))) t)
     :type 'ebasecamp-model-error)
    (ebasecamp-model-reset)
    (ebasecamp-define-group g :services ((s :image "img2")))
    (should (equal "img2"
                   (ebasecamp-service-image
                    (car (ebasecamp-group-services
                          (ebasecamp-model-group 'g))))))))

;;; 7. 项目注册与 groups 归一化

(ert-deftest ebasecamp-model-test-define-project-normalizes-group-refs ()
  "项目定义把组引用归一化为 plist 形式。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group mysql :services ((mysql :image "mysql:8.4")))
    (ebasecamp-define-group app :services ((api :image "app:1")))

    (ebasecamp-define-project myapp
      :title "MyApp 本地开发"
      :root "~/Workspace/myapp"
      :groups
      ((mysql)
       (app :services
            ((api :ports ((8080 . 8080))
                  :environment (("DB_HOST" . "mysql")))))))

    (let ((project (ebasecamp-model-project 'myapp)))
      (should (ebasecamp-project-p project))
      (should (eq 'myapp (ebasecamp-project-name project)))
      (should (equal "MyApp 本地开发" (ebasecamp-project-title project)))
      (should (equal "~/Workspace/myapp" (ebasecamp-project-root project)))
      (should (eq t (ebasecamp-project-shared-network project)))
      (should (null (ebasecamp-project-export-file project)))
      (should (equal '((:group mysql :scope nil :service-overrides nil)
                       (:group app :scope nil
                               :service-overrides
                               ((api :ports ((8080 . 8080))
                                     :environment (("DB_HOST" . "mysql"))))))
                     (ebasecamp-project-groups project)))
      (should (equal '(myapp)
                     (mapcar #'ebasecamp-project-name
                             (ebasecamp-model-projects)))))))

;;; 7b. 项目顶层 configs / secrets（X2）

(ert-deftest ebasecamp-model-test-project-defaults ()
  "未提供 :file-configs / :file-secrets 时两个槽都是 nil。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-project plain)
    (let ((project (ebasecamp-model-project 'plain)))
      (should (null (ebasecamp-project-file-configs project)))
      (should (null (ebasecamp-project-file-secrets project))))))

(ert-deftest ebasecamp-model-test-project-file-configs ()
  "项目 :file-configs 接受 nil 或「键全为字符串的 alist」（含多层嵌套）。
键不是字符串（顶层或嵌套）以及非 alist 的取值一律报 `ebasecamp-model-error`：
渲染层的 `--mapping-p' 只认字符串键，符号键会被当序列渲染成错误 YAML。"
  (ebasecamp-model-test--clean
    ;; 单层：配置名 → (("file" . "./web.conf"))
    (ebasecamp-define-project simple
      :file-configs (("web_cfg" . (("file" . "./web.conf")))))
    (should (equal '(("web_cfg" . (("file" . "./web.conf"))))
                   (ebasecamp-project-file-configs
                    (ebasecamp-model-project 'simple))))
    ;; 嵌套两层
    (ebasecamp-define-project nested
      :file-configs (("a" . (("b" . (("file" . "./x")))))))
    (should (equal '(("a" . (("b" . (("file" . "./x"))))))
                   (ebasecamp-project-file-configs
                    (ebasecamp-model-project 'nested))))
    ;; 顶层符号键
    (should-error
     (eval '(ebasecamp-define-project bad
              :file-configs ((file . "./x"))) t)
     :type 'ebasecamp-model-error)
    ;; 嵌套符号键
    (should-error
     (eval '(ebasecamp-define-project bad
              :file-configs (("a" . ((file . "./x"))))) t)
     :type 'ebasecamp-model-error)
    ;; 非 alist 取值
    (should-error
     (eval '(ebasecamp-define-project bad :file-configs "web.conf") t)
     :type 'ebasecamp-model-error)
    (should-error
     (eval '(ebasecamp-define-project bad :file-configs 42) t)
     :type 'ebasecamp-model-error)))

(ert-deftest ebasecamp-model-test-project-file-secrets ()
  "项目 :file-secrets 与 :file-configs 同一规则：字符串键 alist 或 nil。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-project simple
      :file-secrets (("db_pass" . (("file" . "./db_pass.txt")))))
    (should (equal '(("db_pass" . (("file" . "./db_pass.txt"))))
                   (ebasecamp-project-file-secrets
                    (ebasecamp-model-project 'simple))))
    (ebasecamp-define-project anchored
      :file-secrets (("db_pass" . (("external" . t)))
                     ("api_key" . (("file" . "${EBASECAMP_KEY_FILE}")))))
    (should (equal '(("db_pass" . (("external" . t)))
                     ("api_key" . (("file" . "${EBASECAMP_KEY_FILE}"))))
                   (ebasecamp-project-file-secrets
                    (ebasecamp-model-project 'anchored))))
    (should-error
     (eval '(ebasecamp-define-project bad
              :file-secrets ((db_pass . "./x"))) t)
     :type 'ebasecamp-model-error)
    (should-error
     (eval '(ebasecamp-define-project bad
              :file-secrets (("db_pass" . ((file . "./x"))))) t)
     :type 'ebasecamp-model-error)))

;;; 8. 无覆盖时的解析结果

(ert-deftest ebasecamp-model-test-resolve-services-without-overrides ()
  "无服务覆盖时，解析结果与组内服务等价。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g
      :services ((a :image "a:1" :ports ((80 . 80)))
                 (b :image "b:1")))
    (ebasecamp-define-project p :groups ((g)))

    (let ((resolved (ebasecamp-model-resolve-services
                     (ebasecamp-model-project 'p)
                     (car (ebasecamp-project-groups
                           (ebasecamp-model-project 'p))))))
      (should (= 2 (length resolved)))
      (should (equal '(a b) (mapcar #'ebasecamp-service-name resolved)))
      (should (equal "a:1" (ebasecamp-service-image (nth 0 resolved))))
      (should (equal '((80 . 80)) (ebasecamp-service-ports (nth 0 resolved))))
      (should (equal "b:1" (ebasecamp-service-image (nth 1 resolved)))))))

;;; 9. scope 覆盖不修改原组对象

(ert-deftest ebasecamp-model-test-resolve-services-keeps-group-scope ()
  "项目的 :scope 覆盖只影响解析结果，不修改已注册的组对象。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group base :scope shared :services ((s :image "img")))
    (ebasecamp-define-project p :groups ((base :scope per-project)))

    (ebasecamp-model-resolve-services
     (ebasecamp-model-project 'p)
     (car (ebasecamp-project-groups (ebasecamp-model-project 'p))))

    (should (eq 'shared (ebasecamp-group-scope
                         (ebasecamp-model-group 'base))))))

;;; 10. environment 按键合并

(ert-deftest ebasecamp-model-test-resolve-services-merges-environment ()
  "environment 按键合并：新键覆盖旧值，未提及的键保留。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g
      :services ((svc :image "img:1"
                      :environment (("A" . "1") ("B" . "2")))))
    (ebasecamp-define-project p
      :groups ((g :services
                  ((svc :environment (("B" . "9") ("C" . "3")))))))

    (let* ((resolved (ebasecamp-model-resolve-services
                      (ebasecamp-model-project 'p)
                      (car (ebasecamp-project-groups
                            (ebasecamp-model-project 'p)))))
           (env (ebasecamp-service-environment (car resolved))))
      (should (= 3 (length env)))
      (should (equal "1" (cdr (assoc "A" env))))
      (should (equal "9" (cdr (assoc "B" env))))
      (should (equal "3" (cdr (assoc "C" env))))
      (should (equal "2"
                     (cdr (assoc "B"
                                 (ebasecamp-service-environment
                                  (car (ebasecamp-group-services
                                        (ebasecamp-model-group 'g)))))))))))

;;; 11. ports 整体替换

(ert-deftest ebasecamp-model-test-resolve-services-replaces-ports ()
  "ports 整体替换而不是逐项合并。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g
      :services ((svc :image "img:1" :ports ((80 . 80) (443 . 443)))))
    (ebasecamp-define-project p
      :groups ((g :services ((svc :ports ((8080 . 80)))))))

    (let ((resolved (ebasecamp-model-resolve-services
                     (ebasecamp-model-project 'p)
                     (car (ebasecamp-project-groups
                           (ebasecamp-model-project 'p))))))
      (should (= 1 (length resolved)))
      (should (equal '((8080 . 80))
                     (ebasecamp-service-ports (car resolved)))))))

;;; 12. 覆盖不存在的服务名

(ert-deftest ebasecamp-model-test-resolve-services-rejects-unknown-service ()
  "覆盖不存在的服务名时触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g :services ((svc :image "img:1")))
    (ebasecamp-define-project p
      :groups ((g :services ((nope :ports ((80 . 80)))))))

    (should-error
     (ebasecamp-model-resolve-services
      (ebasecamp-model-project 'p)
      (car (ebasecamp-project-groups (ebasecamp-model-project 'p))))
     :type 'ebasecamp-model-error)))

;;; 13. 返回新对象、原对象不变

(ert-deftest ebasecamp-model-test-resolve-services-returns-new-objects ()
  "解析返回新的 service 对象，且不修改组内原对象。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g
      :services ((svc :image "img:1" :ports ((80 . 80)))))
    (ebasecamp-define-project p
      :groups ((g :services ((svc :image "img:2" :ports ((81 . 81)))))))

    (let* ((original (car (ebasecamp-group-services (ebasecamp-model-group 'g))))
           (resolved (car (ebasecamp-model-resolve-services
                           (ebasecamp-model-project 'p)
                           (car (ebasecamp-project-groups
                                 (ebasecamp-model-project 'p)))))))
      (should-not (eq original resolved))
      (should (equal "img:2" (ebasecamp-service-image resolved)))
      (should (equal '((81 . 81)) (ebasecamp-service-ports resolved)))
      ;; 原对象字段未变
      (should (equal "img:1" (ebasecamp-service-image original)))
      (should (equal '((80 . 80)) (ebasecamp-service-ports original))))))

;;; 14. 项目定义校验（补充用例）

(ert-deftest ebasecamp-model-test-define-project-validates-input ()
  "项目定义的未知关键字、非法 scope、未知组引用键均报错。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g :services ((s :image "img")))
    (should-error
     (eval '(ebasecamp-define-project p :bogus 1) t)
     :type 'ebasecamp-model-error)
    (should-error
     (eval '(ebasecamp-define-project p :groups ((g :scope nowhere))) t)
     :type 'ebasecamp-model-error)
    (should-error
     (eval '(ebasecamp-define-project p :groups ((g :weird ((s :image "x"))))) t)
     :type 'ebasecamp-model-error)))

;;; 15. 未注册的组

(ert-deftest ebasecamp-model-test-resolve-services-rejects-unknown-group ()
  "解析未注册的组时触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-project p :groups ((missing)))
    (should-error
     (ebasecamp-model-resolve-services
      (ebasecamp-model-project 'p)
      (car (ebasecamp-project-groups (ebasecamp-model-project 'p))))
     :type 'ebasecamp-model-error)))

;;; 16. volumes plist 形式

(ert-deftest ebasecamp-model-test-volumes-are-plists ()
  "volumes 以 plist 形式保存，支持 volume 与 bind 两种类型。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g
      :services
      ((mysql :image "mysql:8.4"
              :volumes ((:source "data" :target "/var/lib/mysql" :type volume)
                        (:source "./conf" :target "/etc/mysql" :type bind
                                 :read-only t)))))
    (let ((volumes (ebasecamp-service-volumes
                    (car (ebasecamp-group-services
                          (ebasecamp-model-group 'g))))))
      (should (equal '(:source "data" :target "/var/lib/mysql" :type volume)
                     (nth 0 volumes)))
      (should (eq t (plist-get (nth 1 volumes) :read-only))))))

;;; 17. 服务级未知关键字

(ert-deftest ebasecamp-model-test-service-rejects-unknown-keyword ()
  "服务级未知关键字触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (should-error
     (eval '(ebasecamp-define-group g
              :services ((s :image "img" :shm-size "1g")))
           t)
     :type 'ebasecamp-model-error)))

;;; 18. 未识别字段进 extra

(ert-deftest ebasecamp-model-test-extra-keeps-unknown-service-fields ()
  "未识别的服务字段原样保存在 extra 中。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g
      :services ((s :image "img" :extra (("shm_size" . "1g")))))
    (should (equal '(("shm_size" . "1g"))
                   (ebasecamp-service-extra
                    (car (ebasecamp-group-services
                          (ebasecamp-model-group 'g))))))))

;;; 19. 组内配置（:configs）

(defun ebasecamp-model-test--config-error-message (form)
  "断言 FORM 触发 ebasecamp-model-error，返回错误消息字符串。
FORM 以 `eval' 求值，用法与既有用例一致。"
  (let (message)
    (condition-case err
        (eval form t)
      (ebasecamp-model-error
       (setq message (error-message-string err))))
    (unless message
      (ert-fail (format "期望 %S 触发 ebasecamp-model-error，但没有报错" form)))
    message))

(ert-deftest ebasecamp-model-test-configs-parses-valid-definitions ()
  "合法 :configs 解析为 ((NAME . PLIST) ...)，且不改变组的 scope。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group mysql
      :title "MySQL"
      :scope per-project
      :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306))))
      :configs ((dev  :project myapp :services ((mysql :ports ((3307 . 3306)))))
                (test :project other)))

    (let ((group (ebasecamp-model-group 'mysql)))
      (should (equal '((dev :project myapp
                            :services ((mysql :ports ((3307 . 3306)))))
                       (test :project other))
                     (ebasecamp-model-group-configs group)))
      ;; struct 槽与访问器读到同一份数据
      (should (equal (ebasecamp-group-configs group)
                     (ebasecamp-model-group-configs group)))
      ;; D9：配置不改变组 scope，也不影响组内服务定义
      (should (eq 'per-project (ebasecamp-group-scope group)))
      (should (= 1 (length (ebasecamp-group-services group))))
      (should (equal "mysql:8.4"
                     (ebasecamp-service-image
                      (car (ebasecamp-group-services group))))))))

(ert-deftest ebasecamp-model-test-configs-default-to-nil ()
  "缺省 :configs 与显式 nil 均表示「无配置组」，不是错误。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group bare :services ((s :image "img")))
    (ebasecamp-define-group empty :services ((s :image "img")) :configs nil)
    (should-not (ebasecamp-model-group-configs (ebasecamp-model-group 'bare)))
    (should-not (ebasecamp-model-group-configs (ebasecamp-model-group 'empty)))
    (should-not (ebasecamp-model-config (ebasecamp-model-group 'bare) 'dev))))

(ert-deftest ebasecamp-model-test-configs-require-proper-list ()
  "非 proper list 的 :configs 触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group g
                       :services ((s :image "img"))
                       :configs (dev . myapp)))))
      (should (string-match-p ":configs 必须是列表" message)))))

(ert-deftest ebasecamp-model-test-configs-item-must-be-cons ()
  "配置项不是 (NAME 属性...) 形态时触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group g
                       :services ((s :image "img"))
                       :configs (dev)))))
      (should (string-match-p "配置定义必须是" message)))))

(ert-deftest ebasecamp-model-test-configs-name-must-be-symbol ()
  "配置名不是 symbol 时触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group g
                       :services ((s :image "img"))
                       :configs (("dev" :project myapp))))))
      (should (string-match-p "名字必须是 symbol" message)))))

(ert-deftest ebasecamp-model-test-configs-reject-duplicates ()
  "同组内配置名重复时触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group g
                       :services ((s :image "img"))
                       :configs ((dev :project p1)
                                 (dev :project p2))))))
      (should (string-match-p "重复" message)))
    ;; 报错后组不应留在注册表里
    (should-not (ebasecamp-model-group 'g))))

(ert-deftest ebasecamp-model-test-configs-reject-scope ()
  "配置不允许 :scope（D9），错误信息须点明只允许 :project 与 :services。"
  (ebasecamp-model-test--clean
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group g
                       :services ((s :image "img"))
                       :configs ((dev :project myapp :scope shared))))))
      (should (string-match-p ":scope" message))
      (should (string-match-p "只允许 :project 与 :services" message)))))

(ert-deftest ebasecamp-model-test-configs-require-project ()
  "配置缺 :project 时触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group g
                       :services ((s :image "img"))
                       :configs ((dev :services ((s :ports ((8080 . 80))))))))))
      (should (string-match-p "缺少 :project" message)))))

(ert-deftest ebasecamp-model-test-configs-project-must-be-symbol ()
  "配置的 :project 不是 symbol 时触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group g
                       :services ((s :image "img"))
                       :configs ((dev :project "myapp"))))))
      (should (string-match-p ":project 必须是 symbol" message)))))

(ert-deftest ebasecamp-model-test-configs-services-must-be-list ()
  "配置的 :services 不是 proper list 时触发 ebasecamp-model-error。"
  (ebasecamp-model-test--clean
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group g
                       :services ((s :image "img"))
                       :configs ((dev :project myapp :services (s . 1)))))))
      (should (string-match-p ":services 必须是列表" message)))))

(ert-deftest ebasecamp-model-test-configs-validate-service-overrides ()
  "配置 :services 复用组引用的覆盖校验：形态、关键字、取值。"
  (ebasecamp-model-test--clean
    ;; 覆盖项不是 (NAME 属性...)
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group g
                       :services ((s :image "img"))
                       :configs ((dev :project myapp :services (s)))))))
      (should (string-match-p "服务覆盖必须是" message)))
    ;; 未知关键字
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group h
                       :services ((s :image "img"))
                       :configs ((dev :project myapp
                                      :services ((s :bogus 1))))))))
      (should (string-match-p "未知关键字" message)))
    ;; 取值为空
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group i
                       :services ((s :image "img"))
                       :configs ((dev :project myapp
                                      :services ((s :ports))))))))
      (should (string-match-p "缺少取值" message)))
    ;; 取值非法
    (let ((message (ebasecamp-model-test--config-error-message
                    '(ebasecamp-define-group k
                       :services ((s :image "img"))
                       :configs ((dev :project myapp
                                      :services ((s :ports ((8080 . "80"))))))))))
      (should (string-match-p "整数对" message)))
    ;; 覆盖不存在的服务名不在此阶段校验（推迟到物化阶段）
    (ebasecamp-define-group j
      :services ((s :image "img"))
      :configs ((dev :project myapp :services ((nope :ports ((8080 . 80)))))))
    (should (equal '((dev :project myapp
                          :services ((nope :ports ((8080 . 80))))))
                   (ebasecamp-model-group-configs (ebasecamp-model-group 'j))))))

(ert-deftest ebasecamp-model-test-config-accessor ()
  "ebasecamp-model-config 按组与配置名定位，保持定义顺序，缺失返回 nil。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g
      :services ((s :image "img"))
      :configs ((dev :project p1)
                (test :project p2 :services ((s :ports ((81 . 80)))))
                (prod :project p3)))
    (let ((group (ebasecamp-model-group 'g)))
      (should (equal '(dev test prod)
                     (mapcar #'car (ebasecamp-model-group-configs group))))
      (should (equal '(:project p2 :services ((s :ports ((81 . 80)))))
                     (ebasecamp-model-config group 'test)))
      (should-not (ebasecamp-model-config group 'missing))
      ;; 也接受已注册的组名
      (should (equal '(:project p1) (ebasecamp-model-config 'g 'dev))))))

(ert-deftest ebasecamp-model-test-config-project-accessor ()
  "ebasecamp-model-config-project 从配置 plist 取出 :project。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group g
      :services ((s :image "img"))
      :configs ((dev :project myapp :services ((s :ports ((8080 . 80)))))
                (only :project alone)))
    (let ((group (ebasecamp-model-group 'g)))
      (should (eq 'myapp (ebasecamp-model-config-project
                          (ebasecamp-model-config group 'dev))))
      (should (eq 'alone (ebasecamp-model-config-project
                          (ebasecamp-model-config group 'only))))
      (should-not (ebasecamp-model-config-project nil)))))

;;; 20. 加载期物化（ebasecamp-model-link-configs）

(ert-deftest ebasecamp-model-test-configs-materialize-into-project-groups ()
  "两份配置分别物化到两个项目，ref 为 (:group ... :scope ... :service-overrides ...)。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group mysql
      :scope per-project
      :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306))))
      :configs ((dev  :project myapp :services ((mysql :ports ((3307 . 3306)))))
                (prod :project otherapp)))
    (ebasecamp-define-project myapp)
    (ebasecamp-define-project otherapp)

    (should-not (ebasecamp-model-link-configs))
    (should (equal '((:group mysql :scope per-project
                             :service-overrides ((mysql :ports ((3307 . 3306))))))
                   (ebasecamp-project-groups (ebasecamp-model-project 'myapp))))
    (should (equal '((:group mysql :scope per-project :service-overrides nil))
                   (ebasecamp-project-groups
                    (ebasecamp-model-project 'otherapp))))))

(ert-deftest ebasecamp-model-test-materialized-ref-uses-service-overrides-key ()
  "D6 键名不变量：物化 ref 用 :service-overrides，绝不写 :services。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group mysql
      :services ((mysql :image "mysql:8.4"))
      :configs ((dev :project myapp :services ((mysql :ports ((3307 . 3306)))))))
    (ebasecamp-define-project myapp)

    (ebasecamp-model-link-configs)
    (let ((ref (car (ebasecamp-project-groups
                     (ebasecamp-model-project 'myapp)))))
      (should (plist-get ref :service-overrides))
      (should-not (plist-member ref :services))
      (should-not (memq :services ref))
      (should (eq :service-overrides (nth 4 ref))))))

(ert-deftest ebasecamp-model-test-materialized-overrides-take-effect ()
  "配置覆盖端口后 resolve-services 返回覆盖值，且组定义本身不被改动。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group mysql
      :services ((mysql :image "mysql:8.4" :ports ((3306 . 3306))))
      :configs ((dev :project myapp :services ((mysql :ports ((3307 . 3306)))))))
    (ebasecamp-define-project myapp)

    (ebasecamp-model-link-configs)
    (let* ((project (ebasecamp-model-project 'myapp))
           (services (ebasecamp-model-resolve-services
                      project (car (ebasecamp-project-groups project)))))
      (should (equal '((3307 . 3306))
                     (ebasecamp-service-ports (car services))))
      (should (equal "mysql:8.4" (ebasecamp-service-image (car services))))
      ;; 组内服务定义不受配置影响
      (should (equal '((3306 . 3306))
                     (ebasecamp-service-ports
                      (car (ebasecamp-group-services
                            (ebasecamp-model-group 'mysql)))))))))

(ert-deftest ebasecamp-model-test-materialize-appends-after-legacy-groups ()
  "旧 :groups 引用在前，配置物化结果追加在后。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group redis
      :services ((redis :image "redis:7")))
    (ebasecamp-define-group mysql
      :services ((mysql :image "mysql:8.4"))
      :configs ((dev :project myapp)))
    (ebasecamp-define-project myapp :groups ((redis)))

    (should-not (ebasecamp-model-link-configs))
    (should (equal '((:group redis :scope nil :service-overrides nil)
                     (:group mysql :scope per-project :service-overrides nil))
                   (ebasecamp-project-groups
                    (ebasecamp-model-project 'myapp))))))

(ert-deftest ebasecamp-model-test-materialize-errors-on-undefined-project ()
  "E1：配置引用未定义项目时只记错误，其余配置照常物化。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group mysql
      :services ((mysql :image "mysql:8.4"))
      :configs ((ghost :project nowhere)
                (dev   :project myapp)))
    (ebasecamp-define-project myapp)

    (let ((errors (ebasecamp-model-link-configs)))
      (should (= 1 (length errors)))
      (should (equal "配置 mysql/ghost 引用了未定义的项目 nowhere"
                     (plist-get (car errors) :message)))
      (should (eq 'ebasecamp-model-config-link-error
                  (car (plist-get (car errors) :condition))))
      (should-not (plist-get (car errors) :file))
      ;; 其余配置仍被物化
      (should (equal '((:group mysql :scope per-project :service-overrides nil))
                     (ebasecamp-project-groups
                      (ebasecamp-model-project 'myapp)))))))

(ert-deftest ebasecamp-model-test-materialize-errors-on-duplicate-group-reference ()
  "E2（冲突形态）：旧 :groups 与配置指向同组时记错误，不追加重复引用。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group mysql
      :services ((mysql :image "mysql:8.4"))
      :configs ((dev :project myapp)))
    (ebasecamp-define-project myapp :groups ((mysql)))

    (let ((errors (ebasecamp-model-link-configs)))
      (should (= 1 (length errors)))
      (should (equal "项目 myapp 重复引用组 mysql（来源：旧 :groups）"
                     (plist-get (car errors) :message)))
      (should (equal '((:group mysql :scope nil :service-overrides nil))
                     (ebasecamp-project-groups
                      (ebasecamp-model-project 'myapp)))))))

(ert-deftest ebasecamp-model-test-materialize-errors-on-duplicate-configs-same-project ()
  "E2（配置间形态）：两份配置指向同一项目同一组时，第二份记错误。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group mysql
      :services ((mysql :image "mysql:8.4"))
      :configs ((dev  :project myapp)
                (test :project myapp)))
    (ebasecamp-define-project myapp)

    (let ((errors (ebasecamp-model-link-configs)))
      (should (= 1 (length errors)))
      (should (equal "项目 myapp 重复引用组 mysql（来源：配置 dev）"
                     (plist-get (car errors) :message)))
      (should (= 1 (length (ebasecamp-project-groups
                            (ebasecamp-model-project 'myapp))))))))

(ert-deftest ebasecamp-model-test-materialize-errors-on-shared-multiple-configs ()
  "E3：shared 组配置超过 1 份时记一条错误，且该组不物化。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group shared-db
      :scope shared
      :services ((db :image "postgres:16"))
      :configs ((host-a :project a)
                (host-b :project b)))
    (ebasecamp-define-project a)
    (ebasecamp-define-project b)

    (let ((errors (ebasecamp-model-link-configs)))
      (should (= 1 (length errors)))
      (should (equal "shared 组 shared-db 至多 1 份配置（实际 2 份）"
                     (plist-get (car errors) :message)))
      ;; 不判定哪一份生效 → 该组全部跳过
      (should-not (ebasecamp-project-groups (ebasecamp-model-project 'a)))
      (should-not (ebasecamp-project-groups (ebasecamp-model-project 'b))))))

(ert-deftest ebasecamp-model-test-materialize-errors-on-unknown-service-override ()
  "E4：配置覆盖了组内不存在的服务时记错误，该配置不物化。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group mysql
      :services ((mysql :image "mysql:8.4"))
      :configs ((dev :project myapp :services ((nope :ports ((3307 . 3306)))))))
    (ebasecamp-define-project myapp)

    (let ((errors (ebasecamp-model-link-configs)))
      (should (= 1 (length errors)))
      (should (equal "配置 mysql/dev 覆盖了不存在的服务 nope"
                     (plist-get (car errors) :message)))
      (should-not (ebasecamp-project-groups
                   (ebasecamp-model-project 'myapp))))))

(ert-deftest ebasecamp-model-test-materialize-is-idempotent ()
  "连续两次物化结果相同且不报错，不产生重复引用。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group redis
      :services ((redis :image "redis:7")))
    (ebasecamp-define-group mysql
      :services ((mysql :image "mysql:8.4"))
      :configs ((dev :project myapp :services ((mysql :ports ((3307 . 3306)))))))
    (ebasecamp-define-project myapp :groups ((redis)))

    (should-not (ebasecamp-model-link-configs))
    (let ((first (ebasecamp-project-groups (ebasecamp-model-project 'myapp))))
      (should (= 2 (length first)))
      (should-not (ebasecamp-model-link-configs))
      (should (equal first
                     (ebasecamp-project-groups
                      (ebasecamp-model-project 'myapp))))
      (should (= 2 (length (ebasecamp-project-groups
                            (ebasecamp-model-project 'myapp))))))))

(ert-deftest ebasecamp-model-test-materialize-no-configs-is-noop ()
  "无配置组不产生引用、不产生错误，项目 groups 槽保持不变。"
  (ebasecamp-model-test--clean
    (ebasecamp-define-group redis
      :services ((redis :image "redis:7")))
    (ebasecamp-define-project myapp :groups ((redis)))

    (let ((before (ebasecamp-project-groups (ebasecamp-model-project 'myapp))))
      (should-not (ebasecamp-model-link-configs))
      (should (equal before
                     (ebasecamp-project-groups
                      (ebasecamp-model-project 'myapp)))))))

;;; ebasecamp-model-tests.el ends here
