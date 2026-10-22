;;; ebasecamp-data.el --- ebasecamp 状态层的 ETAF Data 适配 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.1.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块把状态层（`ebasecamp-status'）适配为 ETAF Data 层的 source 与
;; controller，供 `etaf-data-grid' 等组件直接消费。只使用 etaf 的公开 API：
;; `etaf-data-source' / `etaf-data-controller' / `etaf-data-load' /
;; `etaf-data-set-query' / `etaf-data-items' / `etaf-data-total' /
;; `etaf-data-stop'，不触碰 `etaf-data--' 私有函数。
;;
;; 职责边界：
;;
;; - source 的 `:load' 只读「最近一次成功快照」；缓存为空（首次渲染、尚未
;;   轮询）时才主动采集一次，避免 UI 打开时是空白；
;; - **本模块不起轮询** —— 轮询归 `ebasecamp-status'，UI 在轮询回调里调
;;   `ebasecamp-data-refresh' 把新快照推给 controller；
;; - controller 由 UI 持有（`:auto-load' 为 nil，显式 load），销毁时调
;;   `etaf-data-stop'；source 的 `:dispose' 为空 —— 没有任何全局资源。
;;
;; query 语义（`etaf-data-set-query' 可传的值）：
;;
;; - nil —— 全部状态记录；
;; - 字符串或 symbol —— 按 `:project' 精确过滤；
;; - plist（如 `(:project "myapp" :group "mysql")'）—— 按给定键逐条 AND 过滤。
;;
;; item-key 为 \"project/group/service\"：容器 ID 在重启后变化，而三元组是
;; 选择状态的稳定身份。

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'ebasecamp-status)

(defun ebasecamp-data--item-key (record)
  "返回状态记录 RECORD 的选择身份 \"project/group/service\"。"
  (format "%s/%s/%s"
          (plist-get record :project)
          (plist-get record :group)
          (plist-get record :service)))

(defun ebasecamp-data--records ()
  "返回供 source 消费的状态记录列表。
优先用 `ebasecamp-status-last-records'（轮询已采到）；为空时（首渲染）主动
采集一次。采集失败返回 nil（错误已记入 `ebasecamp-status-last-error'）。"
  (or (ebasecamp-status-last-records)
      (ebasecamp-status-snapshot)))

(defun ebasecamp-data--filter (records query)
  "按 QUERY 过滤状态记录列表 RECORDS，返回子列表（保持原顺序）。
QUERY 为 nil 时不过滤；字符串/symbol 按 `:project' 过滤；plist 按给定键
逐条 AND 过滤（键为记录 plist 的键）。其他类型视为不过滤。"
  (cond
   ((null query) records)
   ((or (stringp query) (symbolp query))
    (let ((project (if (symbolp query) (symbol-name query) query)))
      (cl-remove-if-not (lambda (record)
                          (equal (plist-get record :project) project))
                        records)))
   ((listp query)
    (cl-remove-if-not
     (lambda (record)
       (cl-loop for (key value) on query by #'cddr
                always (equal (plist-get record key) value)))
     records))
   (t records)))

(defun ebasecamp-data--slice (items page page-size)
  "从 ITEMS 中取出 PAGE（1 起）与 PAGE-SIZE 指定的切片。纯函数。"
  (let* ((page (max 1 (or page 1)))
         (page-size (max 1 (or page-size 20)))
         (start (* (1- page) page-size))
         (end (+ start page-size))
         (length (length items)))
    (cl-subseq items (min start length) (min end length))))

(defun ebasecamp-data--load (query page page-size)
  "source 的 `:load' 实现：按 QUERY 过滤后分页。
返回 `(:items RECORDS :total N :page PAGE :page-size PAGE-SIZE)'，
其中 `:total' 是过滤后的总条数（分页前）。"
  (let* ((filtered (ebasecamp-data--filter (ebasecamp-data--records) query)))
    (list :items (ebasecamp-data--slice filtered page page-size)
          :total (length filtered)
          :page (max 1 (or page 1))
          :page-size (max 1 (or page-size 20)))))

(defun ebasecamp-data-source ()
  "创建状态表的 ETAF Data source。
capabilities：`:load'（见 `ebasecamp-data--load'）、`:item-key'（稳定身份）、
`:provider' 为 `ebasecamp'。`:dispose' 刻意不提供 —— 本 source 不持有任何
全局资源（轮询归 `ebasecamp-status'）。"
  (etaf-data-source
   :name 'ebasecamp-status
   :provider 'ebasecamp
   :item-key #'ebasecamp-data--item-key
   :load #'ebasecamp-data--load))

(defun ebasecamp-data-controller ()
  "创建状态表的 ETAF Data controller（`:auto-load' 为 nil）。
由 UI 持有，加载用 `etaf-data-load'（或 `ebasecamp-data-refresh'），销毁用
`etaf-data-stop'。"
  (etaf-data-controller (ebasecamp-data-source)
                        :auto-load nil
                        :name 'ebasecamp-status))

(defun ebasecamp-data-refresh (controller)
  "用最新快照刷新 CONTROLLER。
先调 `ebasecamp-status-snapshot' 采一次新数据（成功则覆盖 last-records），再
`etaf-data-load' 让 CONTROLLER 重新走 source 的 `:load'。返回同步加载结果
（`(:items … :total …)'），controller 已停止或加载失败时返回 nil。"
  (condition-case err
      (progn
        (ebasecamp-status-snapshot)
        (etaf-data-load controller))
    ((error quit)
     (message "ebasecamp: 刷新状态数据失败：%S" err)
     nil)))

(provide 'ebasecamp-data)
;;; ebasecamp-data.el ends here
