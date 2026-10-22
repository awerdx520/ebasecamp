;;; ebasecamp-data-tests.el --- ebasecamp ETAF Data 适配层测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; T2.2：把状态层适配为 ETAF Data 层（`etaf-data-source' /
;; `etaf-data-controller'）的 ERT 测试。
;;
;; 数据全部来自伪造的 `ebasecamp-docker-ps'，不触碰真实 docker；控制器在
;; `emacs -Q --batch' 下可正常创建、加载与停止（已用探针验证），因此没有
;; `ert-skip' 用例。
;;
;; 定时器纪律：本模块不持有轮询（轮询归 `ebasecamp-status'），测试只需保证
;; 每个 controller 都被 `ebasecamp-data-stop' 收尾，避免 effect scope 泄漏。

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'etaf)
(require 'ebasecamp-data)

;;; 测试脚手架

(defun ebasecamp-data-test--record (project group service state health)
  "构造一条状态记录（形态与 `ebasecamp-status-normalize' 产物一致）。"
  (list :project project :group group :service service :scope "shared"
        :state state :health health :ports "" :id (format "id-%s" service)
        :names (format "%s-%s-1" project service) :image "mysql:8.4"))

(defun ebasecamp-data-test--records ()
  "三容器 fixture：myapp/mysql 组两个服务、other/redis 组一个服务。"
  (list (ebasecamp-data-test--record "myapp" "mysql" "mysql"
                                     "running" "healthy")
        (ebasecamp-data-test--record "myapp" "mysql" "mysql-ro"
                                     "exited" nil)
        (ebasecamp-data-test--record "other" "redis" "redis"
                                     "running" nil)))

(defmacro ebasecamp-data-test--with-ps (containers &rest body)
  "在伪造 `ebasecamp-docker-ps'（返回 CONTAINERS）的上下文中执行 BODY。
\"最近成功记录\"与\"最近错误\"被动态绑定为空，使每个用例都从冷缓存开始。"
  (declare (indent 1) (debug t))
  `(let ((ebasecamp-status--last-records nil)
         (ebasecamp-status--last-error nil))
     (cl-letf (((symbol-function 'ebasecamp-docker-ps)
                (lambda () ,containers)))
       ,@body)))

(defun ebasecamp-data-test--load-function (source)
  "从 SOURCE 的公开 capabilities 中取出 `:load' 回调。"
  (plist-get (etaf-data-source-capabilities source) :load))

;;; 1. source 对象

(ert-deftest ebasecamp-data-test-source-shape ()
  "source 是合法 ETAF Data source：`:load' 为函数、`:item-key' 为函数、provider 为 ebasecamp。"
  (let* ((source (ebasecamp-data-source))
         (capabilities (etaf-data-source-capabilities source)))
    (should (etaf-data-source-p source))
    (should (functionp (plist-get capabilities :load)))
    (should (functionp (plist-get capabilities :item-key)))
    (should (eq (plist-get capabilities :provider) 'ebasecamp))))

;;; 2. load 回调的过滤语义

(ert-deftest ebasecamp-data-test-load-all ()
  "query 为 nil 时返回全部记录，并带 :total / :page / :page-size。"
  (ebasecamp-data-test--with-ps (ebasecamp-data-test--records)
    (let* ((load (ebasecamp-data-test--load-function (ebasecamp-data-source)))
           (result (funcall load nil 1 20)))
      (should (equal 3 (length (plist-get result :items))))
      (should (= 3 (plist-get result :total)))
      (should (= 1 (plist-get result :page)))
      (should (= 20 (plist-get result :page-size))))))

(ert-deftest ebasecamp-data-test-load-project-string ()
  "query 为字符串时按 `:project' 过滤。"
  (ebasecamp-data-test--with-ps (ebasecamp-data-test--records)
    (let* ((load (ebasecamp-data-test--load-function (ebasecamp-data-source)))
           (result (funcall load "myapp" 1 20)))
      (should (equal 2 (length (plist-get result :items))))
      (should (= 2 (plist-get result :total)))
      (should (equal '("mysql" "mysql-ro")
                     (mapcar (lambda (r) (plist-get r :service))
                             (plist-get result :items)))))))

(ert-deftest ebasecamp-data-test-load-project-symbol ()
  "query 为 symbol 时同样按 `:project' 过滤。"
  (ebasecamp-data-test--with-ps (ebasecamp-data-test--records)
    (let* ((load (ebasecamp-data-test--load-function (ebasecamp-data-source)))
           (result (funcall load 'other 1 20)))
      (should (equal '("redis")
                     (mapcar (lambda (r) (plist-get r :service))
                             (plist-get result :items)))))))

(ert-deftest ebasecamp-data-test-load-plist-query ()
  "query 为 plist 时按给定键逐条 AND 过滤（project + group 双层）。"
  (ebasecamp-data-test--with-ps (ebasecamp-data-test--records)
    (let* ((load (ebasecamp-data-test--load-function (ebasecamp-data-source)))
           (result (funcall load '(:project "myapp" :group "mysql") 1 20)))
      (should (equal 2 (length (plist-get result :items))))
      (should (= 2 (plist-get result :total))))
    (let* ((load (ebasecamp-data-test--load-function (ebasecamp-data-source)))
           (result (funcall load '(:project "myapp" :group "redis") 1 20)))
      (should (null (plist-get result :items)))
      (should (= 0 (plist-get result :total))))))

(ert-deftest ebasecamp-data-test-load-paging ()
  "分页参数生效：page-size 为 1、page 为 2 时返回第二条记录。"
  (ebasecamp-data-test--with-ps (ebasecamp-data-test--records)
    (let* ((load (ebasecamp-data-test--load-function (ebasecamp-data-source)))
           (result (funcall load nil 2 1)))
      (should (equal 1 (length (plist-get result :items))))
      (should (equal '("mysql-ro")
                     (mapcar (lambda (r) (plist-get r :service))
                             (plist-get result :items))))
      (should (= 3 (plist-get result :total))))))

;;; 3. controller 集成

(ert-deftest ebasecamp-data-test-controller-load ()
  "controller 加载后 items / total 与 fixture 一致，set-query 后重载生效。"
  (ebasecamp-data-test--with-ps (ebasecamp-data-test--records)
    (let ((controller (etaf-data-controller (ebasecamp-data-source)
                                            :auto-load nil)))
      (unwind-protect
          (progn
            (should (etaf-data-load controller))
            (should (= 3 (length (etaf-value (etaf-data-items controller)))))
            (should (= 3 (etaf-value (etaf-data-total controller))))
            (etaf-data-set-query controller "myapp")
            (should (etaf-data-load controller))
            (should (= 2 (length (etaf-value (etaf-data-items controller)))))
            (should (= 2 (etaf-value (etaf-data-total controller)))))
        (etaf-data-stop controller)))))

;;; 4. refresh

(ert-deftest ebasecamp-data-test-refresh-picks-new-snapshot ()
  "refresh 用最新快照重载：fixture 从 1 条变 2 条后 items 同步变化。"
  (let ((containers (list (ebasecamp-data-test--record "myapp" "mysql" "mysql"
                                                       "running" "healthy"))))
    (ebasecamp-data-test--with-ps containers
      (let ((controller (etaf-data-controller (ebasecamp-data-source)
                                              :auto-load nil)))
        (unwind-protect
            (progn
              (should (etaf-data-load controller))
              (should (= 1 (length (etaf-value (etaf-data-items controller)))))
              (setq containers
                    (list (nth 0 containers)
                          (ebasecamp-data-test--record "myapp" "mysql" "mysql-ro"
                                                       "exited" nil)))
              (should (ebasecamp-data-refresh controller))
              (should (= 2 (length (etaf-value (etaf-data-items controller)))))
              (should (= 2 (etaf-value (etaf-data-total controller)))))
          (etaf-data-stop controller))))))

;;; 5. item-key 稳定性

(ert-deftest ebasecamp-data-test-item-key ()
  "item-key 为 \"project/group/service\"，同一容器稳定、不同服务可区分。"
  (let* ((source (ebasecamp-data-source))
         (item-key (plist-get (etaf-data-source-capabilities source)
                              :item-key))
         (record (ebasecamp-data-test--record "myapp" "mysql" "mysql"
                                              "running" "healthy"))
         (other (ebasecamp-data-test--record "myapp" "mysql" "mysql-ro"
                                             "running" nil)))
    (should (functionp item-key))
    (should (equal (funcall item-key record) "myapp/mysql/mysql"))
    (should (equal (funcall item-key record) (funcall item-key record)))
    (should-not (equal (funcall item-key record) (funcall item-key other)))))

(provide 'ebasecamp-data-tests)
;;; ebasecamp-data-tests.el ends here
