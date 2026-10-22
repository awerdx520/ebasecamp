;;; ebasecamp-config-tests.el --- ebasecamp 清单加载测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T1.2 清单加载层（目录遍历 + load + 错误收集）的 ERT 测试。
;;
;; 每个测试在独立临时目录中构造清单，结束后递归删除（unwind-protect）。
;; 覆盖范围：bootstrap 语义、正常加载、文件名字典序、非 .el 文件忽略、
;; 语法错/重复组名/未知关键字的错误收集与回滚、引用校验、重新加载幂等、
;; 以及 project-file 与 ensure-directory 两个辅助函数。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebasecamp-config)

(defmacro ebasecamp-config-test--with-dir (&rest body)
  "在临时目录内顺序执行 BODY，结束后递归删除该目录。
BODY 内变量 `dir' 绑定为不带结尾斜杠的临时目录绝对路径。"
  (declare (indent 0) (debug t))
  `(let ((dir (make-temp-file "ebasecamp-config-test" t)))
     (unwind-protect
         (progn ,@body)
       (delete-directory dir :recursive))))

(defun ebasecamp-config-test--write (path content)
  "把字符串 CONTENT 写入 PATH，父目录不存在时一并创建。"
  (make-directory (file-name-directory path) t)
  (with-temp-file path (insert content)))

(defconst ebasecamp-config-test--group-source
  "(ebasecamp-define-group cache :services ((cache :image \"redis:7\")))\n"
  "定义一个名为 cache 的组的清单片段。")

(defun ebasecamp-config-test--project-source (name &optional extra)
  "返回定义项目 NAME 的清单片段。
EXTRA 非 nil 时原样附加在项目名之后（用于构造非法关键字等场景）。"
  (format "(ebasecamp-define-project %s :title \"%s\"%s)\n"
          name name (or extra "")))

(defun ebasecamp-config-test--names (objects accessor)
  "用 ACCESSOR 取出 OBJECTS 中的名字，返回名字列表。"
  (mapcar accessor objects))

(defconst ebasecamp-config-test--mysql-group-source
  (concat "(ebasecamp-define-group mysql\n"
          "  :services ((mysql :image \"mysql:8.4\" :ports ((3306 . 3306)))))\n")
  "定义一个名为 mysql 的组（无 :configs）的清单片段。")

(defconst ebasecamp-config-test--redis-group-source
  "(ebasecamp-define-group redis :services ((redis :image \"redis:7\")))\n"
  "定义一个名为 redis 的组（无 :configs）的清单片段。")

(defconst ebasecamp-config-test--mysql-dev-config-source
  (concat "(ebasecamp-define-group mysql\n"
          "  :services ((mysql :image \"mysql:8.4\" :ports ((3306 . 3306))))\n"
          "  :configs ((dev :project myapp\n"
          "                  :services ((mysql :ports ((3307 . 3306)))))))\n")
  "定义 mysql 组并带一份指向项目 myapp 的配置 dev 的清单片段。")

(defun ebasecamp-config-test--write-project (dir name extra)
  "在 DIR/projects/NAME.el 写入定义项目 NAME 的清单，EXTRA 原样附加在项目名之后。"
  (ebasecamp-config-test--write
   (expand-file-name (concat "projects/" (symbol-name name) ".el") dir)
   (ebasecamp-config-test--project-source (symbol-name name) extra)))

;;; 1. 目录不存在

(ert-deftest ebasecamp-config-test-missing-directory-needs-bootstrap ()
  "目录不存在时置 :bootstrap-needed，清单为空，且不创建目录。"
  (ebasecamp-config-test--with-dir
    (let* ((target (expand-file-name "no-such-dir" dir))
           (result (ebasecamp-config-load target)))
      (should-not (file-exists-p target))
      (should (eq t (plist-get result :bootstrap-needed)))
      (should-not (plist-get result :groups))
      (should-not (plist-get result :projects))
      (should-not (plist-get result :errors)))))

;;; 2. 正常加载

(ert-deftest ebasecamp-config-test-loads-groups-and-projects ()
  "groups.el 与 projects/*.el 均被加载，返回结构完整且无错误。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write (expand-file-name "groups.el" dir)
                                  ebasecamp-config-test--group-source)
    (ebasecamp-config-test--write (expand-file-name "projects/a.el" dir)
                                  (ebasecamp-config-test--project-source "a"))
    (ebasecamp-config-test--write (expand-file-name "projects/b.el" dir)
                                  (ebasecamp-config-test--project-source "b"))
    (let ((result (ebasecamp-config-load dir)))
      (should-not (plist-get result :bootstrap-needed))
      (should (equal '(cache)
                     (ebasecamp-config-test--names
                      (plist-get result :groups) #'ebasecamp-group-name)))
      (should (equal '(a b)
                     (ebasecamp-config-test--names
                      (plist-get result :projects) #'ebasecamp-project-name)))
      (should-not (plist-get result :errors)))))

;;; 3. 加载顺序

(ert-deftest ebasecamp-config-test-loads-project-files-in-name-order ()
  "projects/ 下按文件名字典序加载，与创建顺序无关。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write (expand-file-name "projects/b.el" dir)
                                  (ebasecamp-config-test--project-source "b"))
    (ebasecamp-config-test--write (expand-file-name "projects/a.el" dir)
                                  (ebasecamp-config-test--project-source "a"))
    (let ((result (ebasecamp-config-load dir)))
      (should (equal '(a b)
                     (ebasecamp-config-test--names
                      (plist-get result :projects) #'ebasecamp-project-name)))
      (should-not (plist-get result :errors)))))

;;; 4. 非 .el 文件

(ert-deftest ebasecamp-config-test-ignores-non-el-files ()
  "projects/ 下的非 .el 文件被忽略且不产生错误。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write (expand-file-name "projects/a.el" dir)
                                  (ebasecamp-config-test--project-source "a"))
    (ebasecamp-config-test--write (expand-file-name "projects/notes.txt" dir)
                                  "这不是清单，不该被加载\n")
    (let ((result (ebasecamp-config-load dir)))
      (should (equal '(a)
                     (ebasecamp-config-test--names
                      (plist-get result :projects) #'ebasecamp-project-name)))
      (should-not (plist-get result :errors)))))

;;; 5. groups.el 语法错

(ert-deftest ebasecamp-config-test-syntax-error-in-groups-reports-and-continues ()
  "groups.el 语法错时记一条错误、丢弃该文件的定义，其他文件继续加载。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write
     (expand-file-name "groups.el" dir)
     (concat ebasecamp-config-test--group-source "(\n"))
    (ebasecamp-config-test--write (expand-file-name "projects/b.el" dir)
                                  (ebasecamp-config-test--project-source "b"))
    (let* ((result (ebasecamp-config-load dir))
           (errors (plist-get result :errors))
           (error (car errors)))
      (should (= 1 (length errors)))
      (should-not (plist-get result :groups))
      (should (equal '(b)
                     (ebasecamp-config-test--names
                      (plist-get result :projects) #'ebasecamp-project-name)))
      (should (equal '(:file :condition :message)
                     (cl-remove-if-not #'keywordp error)))
      (should (equal (expand-file-name "groups.el" dir)
                     (plist-get error :file)))
      (should (stringp (plist-get error :message)))
      (should (consp (plist-get error :condition))))))

;;; 6. 重复组名

(ert-deftest ebasecamp-config-test-duplicate-group-reported ()
  "同一文件内重复定义组时记一条错误，并丢弃该文件已注册的组。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write
     (expand-file-name "groups.el" dir)
     (concat ebasecamp-config-test--group-source
             ebasecamp-config-test--group-source))
    (let* ((result (ebasecamp-config-load dir))
           (errors (plist-get result :errors)))
      (should (= 1 (length errors)))
      (should-not (plist-get result :groups))
      (should (string-match-p "已定义\\|重复\\|duplicate"
                              (plist-get (car errors) :message)))
      (should (eq 'ebasecamp-model-error
                  (car (plist-get (car errors) :condition)))))))

;;; 7. 未知关键字

(ert-deftest ebasecamp-config-test-unknown-keyword-isolated-to-file ()
  "某个项目文件用未知关键字时报错，其他项目文件正常加载。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write (expand-file-name "projects/a.el" dir)
                                  (ebasecamp-config-test--project-source
                                   "a" " :bogus t"))
    (ebasecamp-config-test--write (expand-file-name "projects/b.el" dir)
                                  (ebasecamp-config-test--project-source "b"))
    (let* ((result (ebasecamp-config-load dir))
           (errors (plist-get result :errors)))
      (should (= 1 (length errors)))
      (should (equal '(b)
                     (ebasecamp-config-test--names
                      (plist-get result :projects) #'ebasecamp-project-name)))
      (should (equal (expand-file-name "projects/a.el" dir)
                     (plist-get (car errors) :file))))))

;;; 7b. 中间文件出错的回滚

(ert-deftest ebasecamp-config-test-failure-keeps-earlier-definitions ()
  "中间文件出错时只丢弃该文件的定义，之前成功的定义经重放保留。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write (expand-file-name "groups.el" dir)
                                  ebasecamp-config-test--group-source)
    (ebasecamp-config-test--write (expand-file-name "projects/a.el" dir)
                                  (ebasecamp-config-test--project-source "a"))
    (ebasecamp-config-test--write
     (expand-file-name "projects/b.el" dir)
     (concat (ebasecamp-config-test--project-source "b") "(\n"))
    (ebasecamp-config-test--write (expand-file-name "projects/c.el" dir)
                                  (ebasecamp-config-test--project-source "c"))
    (let* ((result (ebasecamp-config-load dir))
           (errors (plist-get result :errors)))
      (should (= 1 (length errors)))
      (should (equal '(cache)
                     (ebasecamp-config-test--names
                      (plist-get result :groups) #'ebasecamp-group-name)))
      (should (equal '(a c)
                     (ebasecamp-config-test--names
                      (plist-get result :projects) #'ebasecamp-project-name)))
      (should (equal (expand-file-name "projects/b.el" dir)
                     (plist-get (car errors) :file))))))

;;; 8. 引用未定义组

(ert-deftest ebasecamp-config-test-missing-group-reference-reported ()
  "项目引用未定义组时记一条错误，消息含组名与项目名，并指向项目文件。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write (expand-file-name "groups.el" dir)
                                  ebasecamp-config-test--group-source)
    (ebasecamp-config-test--write
     (expand-file-name "projects/p.el" dir)
     "(ebasecamp-define-project p :title \"p\" :groups ((nosuchgroup)))\n")
    (let* ((result (ebasecamp-config-load dir))
           (errors (plist-get result :errors))
           (message (plist-get (car errors) :message)))
      (should (= 1 (length errors)))
      (should (string-match-p "nosuchgroup" message))
      (should (string-match-p "\\bp\\b" message))
      (should (equal (expand-file-name "projects/p.el" dir)
                     (plist-get (car errors) :file)))
      (should (eq 'ebasecamp-config-missing-group
                  (car (plist-get (car errors) :condition)))))))

;;; 9. 重新加载幂等

(ert-deftest ebasecamp-config-test-reload-is-idempotent ()
  "重新加载会先清空注册表，组数量不累积。"
  (ebasecamp-config-test--with-dir
    (let ((groups-file (expand-file-name "groups.el" dir)))
      (ebasecamp-config-test--write groups-file ebasecamp-config-test--group-source)
      (should (= 1 (length (plist-get (ebasecamp-config-load dir) :groups))))
      (ebasecamp-config-test--write
       groups-file
       (concat ebasecamp-config-test--group-source
               "(ebasecamp-define-group web :services ((web :image \"nginx:1\")))\n"))
      (let ((result (ebasecamp-config-load dir)))
        (should (= 2 (length (plist-get result :groups))))
        (should (equal '(cache web)
                       (ebasecamp-config-test--names
                        (plist-get result :groups) #'ebasecamp-group-name)))))))

;;; 10. project-file

(ert-deftest ebasecamp-config-test-project-file-path ()
  "project-file 返回 <dir>/projects/<name>.el 的绝对路径。"
  (ebasecamp-config-test--with-dir
    (should (equal (expand-file-name "projects/foo.el" dir)
                   (ebasecamp-config-project-file 'foo dir)))
    (should (equal (expand-file-name "projects/foo.el" dir)
                   (ebasecamp-config-project-file "foo" dir)))))

;;; 11. ensure-directory

(ert-deftest ebasecamp-config-test-ensure-directory-creates-parents ()
  "ensure-directory 递归创建目录并返回带结尾斜杠的绝对路径。"
  (ebasecamp-config-test--with-dir
    (let ((target (expand-file-name "a/b/c" dir)))
      (should-not (file-exists-p target))
      (should (equal (file-name-as-directory target)
                     (ebasecamp-config-ensure-directory target)))
      (should (file-directory-p target)))))

;;; 12. directory

(ert-deftest ebasecamp-config-test-directory-default-value ()
  "默认清单目录为 ~/.config/ebasecamp/ 的绝对路径且以 / 结尾。"
  (should (equal (expand-file-name "~/.config/ebasecamp/")
                 ebasecamp-config-directory))
  (should (file-name-absolute-p ebasecamp-config-directory))
  (should (string-suffix-p "/" ebasecamp-config-directory)))

(ert-deftest ebasecamp-config-test-directory-uses-variable-when-omitted ()
  "省略 DIRECTORY 时路径助手使用 `ebasecamp-config-directory' 并补结尾斜杠。"
  (let ((ebasecamp-config-directory "/tmp/ebc-config-dir-no-slash"))
    (should (equal "/tmp/ebc-config-dir-no-slash/"
                   (ebasecamp-config--directory)))
    (should (equal (expand-file-name "/tmp/ebc-config-dir-no-slash/projects/x.el")
                   (ebasecamp-config-project-file 'x)))))

(ert-deftest ebasecamp-config-test-ensure-directory-idempotent ()
  "目录已存在时重复调用返回同一路径，且不改动目录内已有文件。"
  (ebasecamp-config-test--with-dir
    (let* ((target (expand-file-name "list" dir))
           (marker (expand-file-name "groups.el" target))
           (first (ebasecamp-config-ensure-directory target)))
      (ebasecamp-config-test--write marker ";; keep\n")
      (should (equal first (ebasecamp-config-ensure-directory target)))
      (should (file-directory-p target))
      (should (equal ";; keep\n"
                     (with-temp-buffer
                       (insert-file-contents marker)
                       (buffer-string)))))))

;;; 13. B4 旧写法兼容

(ert-deftest ebasecamp-config-test-legacy-groups-only-load-is-unchanged ()
  "仅用旧 :groups 写法的清单：项目 groups 槽与 v0.1 逐字一致。
加载期物化对无 :configs 的清单必须是零副作用（引用内容与顺序都不变）。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write (expand-file-name "groups.el" dir)
                                  ebasecamp-config-test--mysql-group-source)
    (ebasecamp-config-test--write-project
     dir 'myapp
     " :groups ((mysql :services ((mysql :ports ((3307 . 3306))))))")
    (let* ((result (ebasecamp-config-load dir))
           (project (ebasecamp-model-project 'myapp)))
      (should-not (plist-get result :errors))
      (should (equal '((:group mysql :scope nil
                               :service-overrides
                               ((mysql :ports ((3307 . 3306))))))
                     (ebasecamp-project-groups project)))
      ;; 返回值里的项目对象与注册表读到同一份 groups 槽
      (should (equal (ebasecamp-project-groups project)
                     (ebasecamp-project-groups
                      (car (plist-get result :projects))))))))

(ert-deftest ebasecamp-config-test-legacy-and-configs-coexist ()
  "同一项目里旧 :groups 与配置侧共存：旧引用在前，物化结果在后。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write
     (expand-file-name "groups.el" dir)
     (concat ebasecamp-config-test--redis-group-source
             ebasecamp-config-test--mysql-dev-config-source))
    (ebasecamp-config-test--write-project dir 'myapp " :groups ((redis))")
    (let* ((result (ebasecamp-config-load dir))
           (groups (ebasecamp-project-groups
                    (ebasecamp-model-project 'myapp))))
      (should-not (plist-get result :errors))
      (should (equal '((:group redis :scope nil :service-overrides nil)
                       (:group mysql :scope per-project
                               :service-overrides
                               ((mysql :ports ((3307 . 3306))))))
                     groups)))))

(ert-deftest ebasecamp-config-test-legacy-duplicate-group-reference-is-error ()
  "D2 行为变更：旧 :groups 内重复引用同一组时加载报错。
v0.1 允许 `:groups ((mysql) (mysql))`（静默产生两个引用，下游 `cl-find`
只取首个）；v0.2 起按 D2 统一报错，且错误指向项目定义文件。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write (expand-file-name "groups.el" dir)
                                  ebasecamp-config-test--mysql-group-source)
    (ebasecamp-config-test--write-project dir 'p " :groups ((mysql) (mysql))")
    (let* ((result (ebasecamp-config-load dir))
           (errors (plist-get result :errors))
           (error (car errors)))
      (should (= 1 (length errors)))
      (should (equal (expand-file-name "projects/p.el" dir)
                     (plist-get error :file)))
      (should (string-match-p "重复引用" (plist-get error :message)))
      (should (string-match-p "mysql" (plist-get error :message)))
      (should (string-match-p "\\bp\\b" (plist-get error :message)))
      (should (eq 'ebasecamp-config-duplicate-group-ref
                  (car (plist-get error :condition))))
      ;; 项目本身仍被加载（定义期错误不丢弃项目）
      (should (ebasecamp-model-project 'p)))))

;;; 14. B5 加载流程集成（物化接入）

(ert-deftest ebasecamp-config-test-load-materializes-configs-into-projects ()
  "groups.el 的 :configs 在 load 后物化为项目组引用，键为 :service-overrides。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write (expand-file-name "groups.el" dir)
                                  ebasecamp-config-test--mysql-dev-config-source)
    (ebasecamp-config-test--write-project dir 'myapp "")
    (let* ((result (ebasecamp-config-load dir))
           (groups (ebasecamp-project-groups
                    (ebasecamp-model-project 'myapp))))
      (should-not (plist-get result :errors))
      (should (equal '((:group mysql :scope per-project
                               :service-overrides
                               ((mysql :ports ((3307 . 3306))))))
                     groups))
      ;; D6 键名不变量
      (should (plist-member (car groups) :service-overrides))
      (should-not (plist-member (car groups) :services)))))

(ert-deftest ebasecamp-config-test-load-reports-link-errors-with-file ()
  "配置指向未定义项目：错误进 :errors，:file 为 groups.el 的绝对路径。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write
     (expand-file-name "groups.el" dir)
     (concat "(ebasecamp-define-group mysql\n"
             "  :services ((mysql :image \"mysql:8.4\"))\n"
             "  :configs ((ghost :project nowhere)))\n"))
    (let* ((result (ebasecamp-config-load dir))
           (errors (plist-get result :errors))
           (error (car errors)))
      (should (= 1 (length errors)))
      (should (equal (expand-file-name "groups.el" dir)
                     (plist-get error :file)))
      (should (string-suffix-p "groups.el" (plist-get error :file)))
      (should (string-match-p "未定义的项目" (plist-get error :message)))
      (should (eq 'ebasecamp-model-config-link-error
                  (car (plist-get error :condition))))
      ;; condition 携带 (CODE . (组名 . 项目名)) 形式的上下文
      (should (equal '(:undefined-project (mysql . nowhere))
                     (cdr (plist-get error :condition)))))))

(ert-deftest ebasecamp-config-test-load-partial-success-keeps-good-configs ()
  "一份配置错误 + 一份正确：正确的已物化，错误的只进 :errors。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write
     (expand-file-name "groups.el" dir)
     (concat "(ebasecamp-define-group mysql\n"
             "  :services ((mysql :image \"mysql:8.4\" :ports ((3306 . 3306))))\n"
             "  :configs ((ghost :project nowhere)\n"
             "            (dev   :project myapp\n"
             "                   :services ((mysql :ports ((3307 . 3306)))))))\n"))
    (ebasecamp-config-test--write-project dir 'myapp "")
    (let ((result (ebasecamp-config-load dir)))
      (should (= 1 (length (plist-get result :errors))))
      (should (string-match-p "未定义的项目"
                              (plist-get (car (plist-get result :errors))
                                         :message)))
      (should (equal '((:group mysql :scope per-project
                               :service-overrides
                               ((mysql :ports ((3307 . 3306))))))
                     (ebasecamp-project-groups
                      (ebasecamp-model-project 'myapp)))))))

(ert-deftest ebasecamp-config-test-load-is-idempotent ()
  "连续两次 load 结果一致，物化不重复追加引用。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write
     (expand-file-name "groups.el" dir)
     (concat ebasecamp-config-test--redis-group-source
             ebasecamp-config-test--mysql-dev-config-source))
    (ebasecamp-config-test--write-project dir 'myapp " :groups ((redis))")
    (let* ((first-result (ebasecamp-config-load dir))
           (first (ebasecamp-project-groups
                   (ebasecamp-model-project 'myapp)))
           (second-result (ebasecamp-config-load dir))
           (second (ebasecamp-project-groups
                    (ebasecamp-model-project 'myapp))))
      (should-not (plist-get first-result :errors))
      (should-not (plist-get second-result :errors))
      (should (= 2 (length first)))
      (should (equal first second))
      (should (= 2 (length second))))))

(ert-deftest ebasecamp-config-test-load-directory-missing-still-works ()
  "目录不存在时仍返回空清单 + bootstrap-needed，物化步骤不介入、无错误。"
  (ebasecamp-config-test--with-dir
    (let* ((target (expand-file-name "missing" dir))
           (result (ebasecamp-config-load target)))
      (should-not (file-exists-p target))
      (should (eq t (plist-get result :bootstrap-needed)))
      (should-not (plist-get result :groups))
      (should-not (plist-get result :projects))
      (should-not (plist-get result :errors))
      (should-not (ebasecamp-model-projects)))))

(ert-deftest ebasecamp-config-test-load-groups-syntax-error-still-collected ()
  "groups.el 语法错时错误仍被收集，项目照常加载，物化不额外报错。"
  (ebasecamp-config-test--with-dir
    (ebasecamp-config-test--write
     (expand-file-name "groups.el" dir)
     (concat ebasecamp-config-test--mysql-group-source "(\n"))
    (ebasecamp-config-test--write-project dir 'a "")
    (let* ((result (ebasecamp-config-load dir))
           (errors (plist-get result :errors)))
      (should (= 1 (length errors)))
      (should (equal (expand-file-name "groups.el" dir)
                     (plist-get (car errors) :file)))
      (should-not (plist-get result :groups))
      (should (equal '(a)
                     (ebasecamp-config-test--names
                      (plist-get result :projects) #'ebasecamp-project-name)))
      (should-not (ebasecamp-project-groups
                   (ebasecamp-model-project 'a))))))

(provide 'ebasecamp-config-tests)
;;; ebasecamp-config-tests.el ends here
