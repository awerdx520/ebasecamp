;;; ebasecamp-model-tests.el --- ebasecamp 数据模型测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T1.1 数据模型层（纯数据、无 IO）的 ERT 测试。
;;
;; 覆盖范围：定义宏的合法定义与字段校验、注册表与重复检测、
;; 项目组引用归一化、项目覆盖合并（整体替换 / 按键合并 / 不可变性）。

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

;;; ebasecamp-model-tests.el ends here
