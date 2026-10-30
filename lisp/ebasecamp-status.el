;;; ebasecamp-status.el --- ebasecamp 容器状态归一、聚合与轮询 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.6.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 本模块把 docker 层的容器 plist（`ebasecamp-docker-ps' 的产物）归一为
;; UI 可直接消费的状态记录，并按 `ebasecamp-status-refresh-interval' 轮询刷新。
;; 不依赖 etaf、不做任何渲染 —— 界面层（`ebasecamp-ui'）与 Data 适配层
;; （`ebasecamp-data'）都从这里取数据。
;;
;; 状态记录（plist，字段齐全，缺失值为 nil）：
;;
;;   (:project "myapp" :group "mysql" :service "mysql" :scope "shared"
;;    :state "running" :health "healthy" :ports "0.0.0.0:3306->3306/tcp"
;;    :id "abc…" :names "myapp-mysql-1" :image "mysql:8.4")
;;
;; 归一规则：
;;
;; - `:health' 的 "none"（实测无健康检查时 docker 输出该值）、空串与 nil 统一
;;   归一为 nil，其余（healthy / unhealthy / starting）原样保留；否则 UI 会把
;;   "none" 当成一种健康状态渲染（tech-debt #10）；
;; - `:state' 归一为小写字符串（running / exited / created / paused …），原样
;;   保留语义，不做 up/down 之类的二次判断 —— 那是聚合层的事；
;; - `:project' / `:group' / `:service' / `:scope' 只从标签
;;   `ebasecamp.project' 等**精确键**取值（不允许前缀模糊匹配），标签缺失时
;;   回退到 docker 层已解出的同名顶层字段，仍缺失则为 nil。前缀模糊会让
;;   `ebasecamp.project-x' 这类无关标签误命中；
;; - `:ports' 与 `:image' 原样透传，不做结构化解析。
;;
;; 聚合（`ebasecamp-status-aggregate'）按 `(project group)' 分组，`:state' 取
;; `"up"'（running == total 且 total > 0）/ `"down"'（running == 0）/
;; `"partial"'（其余），并统计 `:unhealthy' 条数；排序先 project 后 group 的
;; 字典序，保证 UI 行序稳定。
;;
;; 轮询：`ebasecamp-status-start' 立即刷新一次再按间隔重复；刷新失败（docker
;; 权限/非零退出/超时）不崩溃也不停表，错误留在 `ebasecamp-status-last-error'
;; 供 UI 提示，最近一次成功的记录留在 `ebasecamp-status-last-records' 供 UI
;; 初次渲染。定时器只允许存在一个（重复 start 会先停再起）。

;;; Code:

(require 'cl-lib)
(require 'ebasecamp-docker)

(defcustom ebasecamp-status-refresh-interval 3
  "容器状态轮询间隔（秒）。"
  :type 'number
  :group 'ebasecamp)

(defvar ebasecamp-status--timer nil
  "当前轮询定时器；nil 表示未在轮询。
不直接用 `timer-list' 判活：其他包的定时器也会出现在其中。")

(defvar ebasecamp-status--tick-function nil
  "每次刷新后调用的无参数函数；nil 表示不需要通知。")

(defvar ebasecamp-status--last-records nil
  "最近一次**成功**刷新得到的状态记录列表。
刷新失败时保持不变，供 UI 在错误状态下继续显示旧数据。")

(defvar ebasecamp-status--last-error nil
  "最近一次刷新失败的错误对象（`(SYMBOL . DATA)' 形态）；成功时为 nil。")

;;; 归一化

(defun ebasecamp-status--health (health)
  "归一健康状态 HEALTH：\"none\" / \"\" / nil → nil，其余原样返回。
docker 在容器无健康检查时输出 \"none\"，它不是一种健康状态。"
  (cond
   ((null health) nil)
   ((not (stringp health)) health)
   ((member (downcase health) '("" "none")) nil)
   (t health)))

(defun ebasecamp-status--state (state)
  "归一容器状态 STATE：小写字符串原样语义，非字符串返回 nil。"
  (and (stringp state) (downcase state)))

(defun ebasecamp-status--label (container key field)
  "从容器 CONTAINER 的标签精确取 KEY 的值；取不到时回退到顶层 FIELD。
空串按未设置处理（返回 nil）。只做精确键匹配，不做前缀匹配。"
  (let* ((labels (plist-get container :labels))
         (value (and (listp labels) (cdr (assoc key labels))))
         (value (if (and (stringp value) (equal value "")) nil value)))
    (or value (plist-get container field))))

(defun ebasecamp-status--record (container)
  "把容器 plist CONTAINER 归一为状态记录 plist（字段见模块 Commentary）。"
  (list :project (ebasecamp-status--label container "ebasecamp.project" :project)
        :group (ebasecamp-status--label container "ebasecamp.group" :group)
        :service (ebasecamp-status--label container "ebasecamp.service" :service)
        :scope (ebasecamp-status--label container "ebasecamp.scope" :scope)
        :state (ebasecamp-status--state (plist-get container :state))
        :health (ebasecamp-status--health (plist-get container :health))
        :ports (plist-get container :ports)
        :id (plist-get container :id)
        :names (plist-get container :names)
        :image (plist-get container :image)))

(defun ebasecamp-status-normalize (containers)
  "把 docker 容器 plist 列表 CONTAINERS 归一为状态记录列表（纯函数）。
保持输入顺序；每条记录的字段齐全，缺失值为 nil。"
  (mapcar #'ebasecamp-status--record containers))

;;; 聚合

(defun ebasecamp-status--entry-state (entry)
  "按 ENTRY 的 total / running 计算聚合状态字符串。"
  (let ((total (plist-get entry :total))
        (running (plist-get entry :running)))
    (cond
     ((and (> total 0) (= running total)) "up")
     ((zerop running) "down")
     (t "partial"))))

(defun ebasecamp-status--entry-lessp (a b)
  "聚合项 A 是否应排在 B 之前：先 project 字典序，再 group 字典序。"
  (let ((project-a (or (plist-get a :project) ""))
        (project-b (or (plist-get b :project) "")))
    (if (equal project-a project-b)
        (string< (or (plist-get a :group) "")
                 (or (plist-get b :group) ""))
      (string< project-a project-b))))

(defun ebasecamp-status-aggregate (records)
  "把状态记录列表 RECORDS 按 `(project group)' 聚合。
返回聚合列表，每项形如
`(:project P :group G :scope S :total N :running N :unhealthy N :state S)'，
其中 `:state' 为 \"up\" / \"down\" / \"partial\"，`:scope' 取该组首条记录。
排序先 project 后 group 的字典序，保证 UI 行序稳定。"
  (let ((table (make-hash-table :test #'equal)))
    (dolist (record records)
      (let* ((key (list (plist-get record :project)
                        (plist-get record :group)))
             (entry (gethash key table)))
        (unless entry
          (setq entry (list :project (plist-get record :project)
                            :group (plist-get record :group)
                            :scope (plist-get record :scope)
                            :total 0
                            :running 0
                            :unhealthy 0
                            :state "down"))
          (puthash key entry table))
        (setf (plist-get entry :total) (1+ (plist-get entry :total)))
        (when (equal (plist-get record :state) "running")
          (setf (plist-get entry :running) (1+ (plist-get entry :running))))
        (when (equal (plist-get record :health) "unhealthy")
          (setf (plist-get entry :unhealthy) (1+ (plist-get entry :unhealthy))))))
    (let ((entries nil))
      (maphash (lambda (_key entry) (push entry entries)) table)
      (dolist (entry entries)
        (setf (plist-get entry :state) (ebasecamp-status--entry-state entry)))
      (sort entries #'ebasecamp-status--entry-lessp))))

(defun ebasecamp-status-group-records (records project group)
  "从 RECORDS 中取出属于 PROJECT 项目 GROUP 组的状态记录（保持原顺序）。

**不含 scope 语义**：只按 `:project' 与 `:group' 精确双键过滤，`:scope' 不参与
判定。shared 容器的 `ebasecamp.project' 标签记的是**发起项目**而非本配置的
项目（D8），因此 shared 组不能用本函数取记录 —— 匹配 shared 请用
`ebasecamp-data--instance-status'（`:scope' 为 \"shared\" 时按组名 + 服务名命中、
忽略项目名；索引由 `ebasecamp-data--instance-indexes' 建立），或直接用上层装配
入口 `ebasecamp-data-group-instances'。"
  (cl-remove-if-not (lambda (record)
                      (and (equal (plist-get record :project) project)
                           (equal (plist-get record :group) group)))
                    records))

;;; 采集与轮询

(defun ebasecamp-status-snapshot ()
  "采集并归一当前容器状态，返回状态记录列表。
内部调用 `ebasecamp-docker-ps'（即真实执行 `docker ps'）；成功时更新
`ebasecamp-status-last-records' 并清空 `ebasecamp-status-last-error'。
失败（权限错误、非零退出、超时）时**不** signal：错误存入
`ebasecamp-status-last-error'，`last-records' 保持上一次成功值，返回 nil。
这样轮询回调不会因为一次 docker 抖动而中断。"
  (condition-case err
      (let ((records (ebasecamp-status-normalize (ebasecamp-docker-ps))))
        (setq ebasecamp-status--last-records records
              ebasecamp-status--last-error nil)
        records)
    ((error quit)
     (setq ebasecamp-status--last-error err)
     nil)))

(defun ebasecamp-status-last-records ()
  "返回最近一次成功刷新的状态记录列表（可能为 nil）。"
  ebasecamp-status--last-records)

(defun ebasecamp-status-last-error ()
  "返回最近一次刷新失败的错误对象；无错误时返回 nil。"
  ebasecamp-status--last-error)

(defun ebasecamp-status--tick ()
  "执行一次刷新，然后调用 `ebasecamp-status--tick-function'（若有）。
刷新错误已在 `ebasecamp-status-snapshot' 内消化，不会中断定时器。"
  (ebasecamp-status-snapshot)
  (when (functionp ebasecamp-status--tick-function)
    (funcall ebasecamp-status--tick-function)))

(defun ebasecamp-status-running-p ()
  "轮询是否在运行：运行中返回 t，否则 nil。"
  (and (timerp ebasecamp-status--timer) t))

(defun ebasecamp-status-start (function)
  "启动状态轮询，FUNCTION 为每次刷新后调用的无参数函数（可为 nil）。
行为：
- 幂等：已在轮询时先 `ebasecamp-status-stop' 再重启，保证只有一个定时器；
- 立即刷新一次（因此 last-records 在返回时已有值），之后每
  `ebasecamp-status-refresh-interval' 秒刷新一次；
- 刷新失败不中断轮询，错误见 `ebasecamp-status-last-error'。
返回 t。"
  (ebasecamp-status-stop)
  (setq ebasecamp-status--tick-function function)
  (ebasecamp-status--tick)
  (setq ebasecamp-status--timer
        (run-with-timer ebasecamp-status-refresh-interval
                        ebasecamp-status-refresh-interval
                        #'ebasecamp-status--tick))
  t)

(defun ebasecamp-status-stop ()
  "停止状态轮询（幂等）：取消定时器并清空回调。
不清 `last-records' / `last-error' —— 停止后 UI 仍可显示最后已知状态。"
  (when (timerp ebasecamp-status--timer)
    (cancel-timer ebasecamp-status--timer))
  (setq ebasecamp-status--timer nil
        ebasecamp-status--tick-function nil))

(provide 'ebasecamp-status)
;;; ebasecamp-status.el ends here
