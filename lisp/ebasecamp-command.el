;;; ebasecamp-command.el --- ebasecamp 生命周期命令与端口冲突检测 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.2.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 生命周期层：把「用户选中的服务集合」翻译成 docker compose 命令并异步执行。
;; 不渲染界面、不采集状态 —— 界面层（`ebasecamp-ui'）只调用本模块的接口。
;;
;; 为什么必须按 scope 拆批：一个项目可能同时引用 shared 组与 per-project 组，
;; 两者运行在**不同的 compose 项目**里：
;;
;; - per-project 组 → `-p ebc-<project>'，生成物 <cache>/<project>/compose.yaml
;; - shared 组      → `-p ebc-shared'，生成物 <cache>/_shared/compose.yaml
;;
;; 因此一次启停操作要拆成最多两批，分别 `docker compose ... up/stop/restart'。
;; shared 组的 `down' **不提供**：其他项目可能正在使用这些容器，`down' 会把
;; 它们一起删掉。`down' 只对 per-project 批次开放，且不带 `-v'（不删卷）。
;;
;; 分层：
;; - 纯函数（不执行命令，可单测）：`ebasecamp-command-service-key'、
;;   `ebasecamp-command-split-keys'、`ebasecamp-command-compose-args'、
;;   `ebasecamp-command-port-conflicts'；
;; - 执行层：`ebasecamp-command-run'（异步）、`ebasecamp-command-pending-p'、
;;   `ebasecamp-command-ensure-network'（同步，秒级）。
;;
;; 并发不变量：同一项目同时只允许一批生命周期命令。pending 标记在派发前
;; 置位、在全部批次结束后清除；重复调用 signal `ebasecamp-command-busy'。
;;
;; 端口冲突检测（T3.3）：启动前的两步检查 —— ①选中集合内 published 端口重复；
;; ②宿主端口已被占用。探测不可用（权限等）降级为 `unknown'，**不阻塞**启动。
;;
;; 跨 scope depends_on（tech-debt #13）：per-project 服务的 depends-on 可能指向
;; shared 组服务（如 api → mysql）。compose 层按 scope 渲染时会剔除这类跨集合
;; 依赖（否则 `up' 报 depends on undefined service），因此本模块在 `start' 时
;; 先补齐 shared 批次：`:requires-shared' 非空则串行先跑 shared、成功后才跑
;; per-project；失败即中止。stop / restart / down 不做补齐（补齐等于在停止
;; 操作里反向启动容器）。
;;
;; 安全约定：命令参数一律以字符串列表直接交给 `make-process'（不经 shell），
;; stderr 原样保留供上层展示；本模块不读取、不打印、不落盘任何密钥值。

;;; Code:

(require 'cl-lib)
(require 'ebasecamp-model)
(require 'ebasecamp-compose)
(require 'ebasecamp-docker)

(define-error 'ebasecamp-command-error "ebasecamp 命令参数错误")
(define-error 'ebasecamp-command-busy
  "ebasecamp 已有命令在执行" 'ebasecamp-command-error)

(defconst ebasecamp-command--network "ebasecamp"
  "托管容器共享的 external network 名。
与 `ebasecamp-compose' 顶层声明的 external network 必须一致，否则 `up' 会
因「引用了未定义网络」失败。")

(defconst ebasecamp-command--actions '(start stop restart down)
  "允许的动作：启动、停止、重启、拆除。")

(defvar ebasecamp-command--pending (make-hash-table :test #'equal)
  "正在执行的生命周期命令，键为项目名字符串，值为 t。
同一项目同一时刻最多一批；批次全部结束后删除键。")

(defvar ebasecamp-command--port-free-p #'ebasecamp-command--port-probe
  "宿主端口空闲探测函数（注入点）：接收 PORT 整数，空闲返回 t、被占用返回 nil。
默认走 `ebasecamp-command--port-probe'（`make-network-process' bind 探测）；
测试注入替身以避免真实 bind。")

;;; 项目与服务标识

(defun ebasecamp-command--name (project)
  "返回 PROJECT 的项目名（字符串）。
PROJECT 可以是 ebasecamp-project 对象、项目名 symbol 或字符串；无法解析时
signal `ebasecamp-command-error'。不要求项目已注册（供 pending 查询使用）。"
  (cond
   ((ebasecamp-project-p project)
    (symbol-name (ebasecamp-project-name project)))
   ((symbolp project) (symbol-name project))
   ((stringp project) project)
   (t (signal 'ebasecamp-command-error
              (list (format "PROJECT 必须是项目对象、名字 symbol 或字符串，得到 %S"
                            project))))))

(defun ebasecamp-command--project (project)
  "把 PROJECT（对象、名字 symbol 或字符串）解析为已注册的项目对象。
未注册时 signal `ebasecamp-command-error'。"
  (if (ebasecamp-project-p project)
      project
    (let ((name (ebasecamp-command--name project))
          (symbol nil))
      (setq symbol (intern name))
      (or (ebasecamp-model-project symbol)
          (signal 'ebasecamp-command-error
                  (list (format "项目 %s 未注册" name)))))))

(defun ebasecamp-command--scope (ref)
  "返回组引用 REF 的有效 scope，归一为 `project' 或 `shared' 两个 symbol。
有效 scope 由 `ebasecamp-compose--ref-scope' 计算（项目级 :scope 覆盖优先），
再归并为本模块的两值域。"
  (if (eq 'shared (ebasecamp-compose--ref-scope ref)) 'shared 'project))

(defun ebasecamp-command--scope-refs (project scope)
  "返回 PROJECT 中有效 scope 为 SCOPE 的组引用列表（保持定义顺序）。"
  (cl-remove-if-not (lambda (ref) (eq scope (ebasecamp-command--scope ref)))
                    (ebasecamp-project-groups project)))

(defun ebasecamp-command--symbol (value context)
  "把 VALUE（symbol 或非空字符串）转成 symbol。
取值非法时以 CONTEXT 报告 `ebasecamp-command-error'。"
  (cond
   ((and (symbolp value) value) value)
   ((and (stringp value) (not (equal value ""))) (intern value))
   (t (signal 'ebasecamp-command-error
              (list (format "%s: 期望组名或服务名的 symbol/字符串，得到 %S"
                            context value))))))

(defun ebasecamp-command--parse-key (key)
  "把服务标识 KEY 拆成 (GROUP . SERVICE) 的 symbol 对。
KEY 可以是 \"group/service\" 字符串，或含 :group 与 :service 的 plist。
格式非法时 signal `ebasecamp-command-error'。"
  (cond
   ((stringp key)
    (let ((slash (string-match "/" key)))
      (unless (and slash (> slash 0) (< slash (1- (length key))))
        (signal 'ebasecamp-command-error
                (list (format "服务标识 %S 必须形如 group/service" key))))
      (cons (intern (substring key 0 slash))
            (intern (substring key (1+ slash))))))
   ((and (consp key) (keywordp (car key)))
    (cons (ebasecamp-command--symbol (plist-get key :group) "服务标识 :group")
          (ebasecamp-command--symbol (plist-get key :service) "服务标识 :service")))
   ((and (consp key) (symbolp (car key)) (symbolp (cdr key)))
    (cons (car key) (cdr key)))
   (t (signal 'ebasecamp-command-error
              (list (format "无法识别的服务标识 %S（期望 group/service 或 plist）"
                            key))))))

(defun ebasecamp-command-service-key (record)
  "把服务标识 RECORD 归一为 \"group/service\" 字符串。
RECORD 可以是 \"group/service\" 字符串、含 :group 与 :service 的 plist
（如 `ebasecamp-status' 的状态记录），或 (GROUP . SERVICE) 点对。
格式非法时 signal `ebasecamp-command-error'。纯函数。"
  (let ((pair (ebasecamp-command--parse-key record)))
    (format "%s/%s" (car pair) (cdr pair))))

;;; 选中集合

(defun ebasecamp-command--entry (ref service)
  "由组引用 REF 与解析后的服务 SERVICE 构造选中项 plist。
字段：`:key'（\"group/service\"）、`:scope'（project/shared）、`:group'、
`:service'、`:record'（含项目覆盖的服务对象）。"
  (let ((group (plist-get ref :group))
        (name (ebasecamp-service-name service)))
    (list :key (format "%s/%s" group name)
          :scope (ebasecamp-command--scope ref)
          :group group
          :service name
          :record service)))

(defun ebasecamp-command--ref-service (project ref name)
  "在 PROJECT 中的组引用 REF 下按 NAME 找解析后的服务对象。
不存在时 signal `ebasecamp-command-error'。"
  (let ((service (cl-find name (ebasecamp-model-resolve-services project ref)
                          :key #'ebasecamp-service-name
                          :test #'eq)))
    (or service
        (signal 'ebasecamp-command-error
                (list (format "组 %s 中不存在服务 %s"
                              (plist-get ref :group) name))))))

(defun ebasecamp-command--selection (project keys)
  "返回 PROJECT 的选中项列表（每项见 `ebasecamp-command--entry'）。
KEYS 为 nil 时返回项目全部服务（按项目定义顺序与组内顺序）；否则按 KEYS
逐个解析，未知组或未知服务 signal `ebasecamp-command-error'。重复的 KEY 只
保留首次出现。纯函数（只读清单，不执行命令）。"
  (let ((entries nil)
        (seen (make-hash-table :test #'equal)))
    (if (null keys)
        (dolist (ref (ebasecamp-project-groups project))
          (dolist (service (ebasecamp-model-resolve-services project ref))
            (push (ebasecamp-command--entry ref service) entries)))
      (dolist (key keys)
        (let* ((pair (ebasecamp-command--parse-key key))
               (group (car pair))
               (service (cdr pair))
               (ref (cl-find group (ebasecamp-project-groups project)
                             :key (lambda (ref) (plist-get ref :group))
                             :test #'eq)))
          (unless ref
            (signal 'ebasecamp-command-error
                    (list (format "项目 %s 未引用组 %s"
                                  (ebasecamp-project-name project) group))))
          (let* ((record (ebasecamp-command--ref-service project ref service))
                 (entry (ebasecamp-command--entry ref record))
                 (key (plist-get entry :key)))
            (unless (gethash key seen)
              (puthash key t seen)
              (push entry entries))))))
    (nreverse entries)))

;;; scope 拆分（纯函数）

(defun ebasecamp-command--scope-service-names (project scope)
  "返回 PROJECT 中 SCOPE 各组提供的服务名列表（字符串数组、去重、定义顺序）。"
  (let ((names nil))
    (dolist (ref (ebasecamp-command--scope-refs project scope))
      (dolist (service (ebasecamp-model-resolve-services project ref))
        (let ((name (symbol-name (ebasecamp-service-name service))))
          (unless (member name names)
            (setq names (append names (list name)))))))
    names))

(defun ebasecamp-command--requires-shared (project entries)
  "返回 ENTRIES 需要先行启动的 shared 服务名列表（去重、按名字排序）。
取每个服务的**原始** depends-on（模型层解析结果，未经 compose 渲染剔除）：
落在项目 per-project 各组服务集合内的是同批依赖（生成物里已有定义），不计入；
属于 shared 组服务集合的记入结果 —— 它们在另一个 compose 项目（`ebc-shared'）
里，不先把 shared 批次启起来就会 `depends on undefined service'。"
  (let ((own (ebasecamp-command--scope-service-names project 'project))
        (available (ebasecamp-command--scope-service-names project 'shared))
        (result nil))
    (dolist (entry entries)
      (dolist (dependency (ebasecamp-service-depends-on
                           (plist-get entry :record)))
        (let ((name (ebasecamp-command--service-name dependency)))
          (when (and (not (member name own))
                     (member name available)
                     (not (member name result)))
            (setq result (append result (list name)))))))
    (sort result #'string<)))

(defun ebasecamp-command--check-requires (project requires)
  "校验 REQUIRES 中每个名字都是 PROJECT 的 shared 组服务。
不在 shared 服务集合中时 signal `ebasecamp-command-error'（清单不一致：
依赖既不在本批生成物里，也无法通过 shared 批次启动）。"
  (let ((available (ebasecamp-command--scope-service-names project 'shared)))
    (dolist (name requires)
      (unless (member name available)
        (signal 'ebasecamp-command-error
                (list (format "项目 %s 依赖的 shared 服务 %s 不存在（清单不一致）"
                              (ebasecamp-project-name project) name)))))))

(defun ebasecamp-command--branch-shell (project scope services)
  "构造 SCOPE 批次的执行描述 plist，服务集合为 SERVICES；SERVICES 为 nil 返回 nil。
返回字段：`:scope'、`:file'（`ebasecamp-compose-cache-file' 的生成物路径，
只含该 scope 的组）、`:name'（compose 项目名）、`:services'（服务名列表）、
`:groups'（该 scope 的组名列表，供渲染时做 group-filter）。"
  (when services
    (let* ((refs (ebasecamp-command--scope-refs project scope))
           (groups (mapcar (lambda (ref) (plist-get ref :group)) refs)))
      (unless refs
        (signal 'ebasecamp-command-error
                (list (format "项目 %s 的 %s scope 缺少组引用"
                              (ebasecamp-project-name project) scope))))
      (list :scope scope
            :file (ebasecamp-compose-cache-file project groups)
            :name (ebasecamp-compose-project-name project (car refs))
            :services services
            :groups groups))))

(defun ebasecamp-command--shared-branch (project shared requires)
  "返回自动补齐依赖用的 shared 批次，服务集合覆盖 REQUIRES。
SHARED 为本次选中产生的 shared 批次（可能为 nil）：已包含 REQUIRES 全部名字
时直接复用；否则在选中服务之后追加缺失的依赖服务名（保留选中顺序）。"
  (let* ((selected (and shared (plist-get shared :services)))
         (missing (cl-set-difference requires selected :test #'equal)))
    (if (null missing)
        shared
      (ebasecamp-command--branch-shell project 'shared
                                      (append selected missing)))))

(defun ebasecamp-command--branch (project selection scope)
  "构造 SCOPE 批次的执行描述 plist；该 scope 无选中项时返回 nil。
字段见 `ebasecamp-command--branch-shell'；per-project 批次另含
`:requires-shared'（本批服务的原始 depends-on 中属于 shared 组、需要先启动的
服务名，去重排序，无跨 scope 依赖时为 nil）。"
  (let* ((entries (cl-remove-if-not
                   (lambda (entry) (eq scope (plist-get entry :scope)))
                   selection))
         (branch (ebasecamp-command--branch-shell
                  project scope
                  (mapcar (lambda (entry)
                            (symbol-name (plist-get entry :service)))
                          entries))))
    (if (and branch (eq scope 'project))
        (append branch
                (list :requires-shared
                      (ebasecamp-command--requires-shared project entries)))
      branch)))

(defun ebasecamp-command-split-keys (project keys)
  "把选中服务 KEYS 按 scope 分流为 shared 与 per-project 两批。
返回 plist `(:project BRANCH :shared BRANCH)'，某 scope 无选中服务时对应值
为 nil，BRANCH 结构见 `ebasecamp-command--branch-shell'；per-project 批次另含
`:requires-shared'（跨 scope 依赖的 shared 服务名列表，见
`ebasecamp-command--requires-shared'），shared 批次不带该键。
KEYS 元素为 \"group/service\" 字符串或 (:group G :service S) plist；nil 表示
项目全部服务。未知 group/service signal `ebasecamp-command-error'。
纯函数：不执行命令、不落盘（`:file' 只计算路径）。"
  (let* ((object (ebasecamp-command--project project))
         (selection (ebasecamp-command--selection object keys))
         (result (list :project nil :shared nil)))
    (dolist (scope '(project shared))
      (let ((branch (ebasecamp-command--branch object selection scope)))
        (when branch
          (setf (plist-get result (if (eq scope 'shared) :shared :project))
                branch))))
    result))

;;; 命令行构造（纯函数）

(defun ebasecamp-command--service-name (service)
  "把服务名 SERVICE（symbol 或字符串）转成命令行用的字符串。"
  (cond ((stringp service) service)
        ((symbolp service) (symbol-name service))
        (t (signal 'ebasecamp-command-error
                   (list (format "服务名必须是 symbol 或字符串，得到 %S"
                                 service))))))

(defun ebasecamp-command-compose-args (action file project-name services)
  "构造 docker compose 的参数列表（不含可执行文件名）。纯函数。
ACTION 为 start / stop / restart / down：
- start   → (\"compose\" \"-f\" FILE \"-p\" NAME \"up\" \"-d\" SVC...)
- stop    → (\"compose\" \"-f\" FILE \"-p\" NAME \"stop\" SVC...)
- restart → (\"compose\" \"-f\" FILE \"-p\" NAME \"restart\" SVC...)
- down    → (\"compose\" \"-f\" FILE \"-p\" NAME \"down\")，**不带 -v**，
  且 SERVICES 必须为空（down 的语义是整个 compose 项目）。
SERVICES 元素为 symbol 或字符串。ACTION 非法或 down 收到服务名时 signal
`ebasecamp-command-error'。"
  (unless (memq action ebasecamp-command--actions)
    (signal 'ebasecamp-command-error
            (list (format "未知动作 %S（允许 %s）"
                          action ebasecamp-command--actions))))
  (let ((head (list "compose" "-f" file "-p" project-name)))
    (cond
     ((eq action 'down)
      (when services
        (signal 'ebasecamp-command-error
                (list "down 不接受服务名：其语义是整个 compose 项目")))
      (append head (list "down")))
     ((eq action 'start)
      (append head (list "up" "-d")
              (mapcar #'ebasecamp-command--service-name services)))
     (t
      (append head (list (symbol-name action))
              (mapcar #'ebasecamp-command--service-name services))))))

;;; external network

(defun ebasecamp-command-ensure-network ()
  "确保 external network `ebasecamp' 存在，返回 t。
先 `docker network inspect'；不存在时 `docker network create'；create 失败但
stderr 含 \"already exists\"（并发创建）视为成功。其余失败 signal
`ebasecamp-command-error' 并保留 stderr。同步执行（秒级，不阻塞 UI 刷新）。"
  (let* ((inspect (ebasecamp-docker-run-sync
                   (list "network" "inspect" ebasecamp-command--network)))
         (exit (plist-get inspect :exit)))
    (if (and (numberp exit) (zerop exit))
        t
      (let* ((created (ebasecamp-docker-run-sync
                       (list "network" "create" ebasecamp-command--network)))
             (created-exit (plist-get created :exit))
             (stderr (or (plist-get created :stderr) "")))
        (cond
         ((and (numberp created-exit) (zerop created-exit)) t)
         ((string-match-p "already exists" stderr) t)
         (t (signal 'ebasecamp-command-error
                    (list (format "无法创建 external network %s：%s"
                                  ebasecamp-command--network
                                  (ebasecamp-docker--first-line stderr))))))))))

;;; 执行层

(defun ebasecamp-command-pending-p (project)
  "判断 PROJECT 是否有正在执行的生命周期命令。返回 t 或 nil。
PROJECT 可为项目对象、symbol 或字符串。"
  (and (gethash (ebasecamp-command--name project) ebasecamp-command--pending) t))

(defun ebasecamp-command--result (branch result)
  "把分支 BRANCH 的异步执行结果 RESULT 归一为批次结果 plist。
字段：`:scope'、`:exit'、`:stderr'（超时等异常时取 `:message'，保持可展示）。"
  (list :scope (plist-get branch :scope)
        :exit (plist-get result :exit)
        :stderr (or (plist-get result :stderr) (plist-get result :message) "")))

(defun ebasecamp-command--successful-p (result)
  "判断批次结果 RESULT 是否成功（退出码为 0）。"
  (let ((exit (plist-get result :exit)))
    (and (numberp exit) (zerop exit))))

(defun ebasecamp-command--dispatch (action object name branches
                                          sequential auto-shared on-complete)
  "派发批次 BRANCHES（分支 plist 列表），返回已启动的进程列表。
SEQUENTIAL 非 nil 时按顺序派发，某批次失败后中止后续批次（结果记为
`:skipped'）；AUTO-SHARED 非 nil 表示 shared 批次是为跨 scope 依赖自动补齐的。
ON-COMPLETE 在所有批次结束后调用，参数 plist：
`(:action :project :ok :results :auto-started-shared :order)'，
`:results' 元素为 `(:scope :exit :stderr [:failed t|:skipped t])'，
`:order' 为实际派发的 scope 顺序。"
  (let* ((total (length branches))
         (results (make-vector total nil))
         (remaining total)
         (executed nil)
         (finished nil)
         (processes nil))
    (puthash name t ebasecamp-command--pending)
    (cl-labels
        ((report ()
           (unless finished
             (setq finished t)
             (remhash name ebasecamp-command--pending)
             (when (functionp on-complete)
               (funcall on-complete
                        (list :action action
                              :project (ebasecamp-project-name object)
                              :ok (cl-every #'ebasecamp-command--successful-p
                                            (append results nil))
                              :results (append results nil)
                              :auto-started-shared (and auto-shared t)
                              :order (nreverse executed))))))
         (skip (from)
           (let ((index from))
             (while (< index total)
               (aset results index
                     (list :scope (plist-get (nth index branches) :scope)
                           :exit nil :stderr "" :skipped t))
               (cl-decf remaining)
               (setq index (1+ index))))
           (report))
         (settle (index result)
           (let* ((branch (nth index branches))
                  (entry (ebasecamp-command--result branch result))
                  (ok (ebasecamp-command--successful-p entry)))
             (aset results index (if ok entry (append entry (list :failed t))))
             (cl-decf remaining)
             (cond
              ((and sequential (not ok)) (skip (1+ index)))
              ((<= remaining 0) (report))
              (sequential (launch (1+ index))))))
         (launch (index)
           (let* ((branch (nth index branches))
                  (file (ebasecamp-compose-write
                         object (plist-get branch :groups)))
                  (args (ebasecamp-command-compose-args
                         action file (plist-get branch :name)
                         (unless (eq action 'down)
                           (plist-get branch :services)))))
             (setq executed (cons (plist-get branch :scope) executed))
             (push (ebasecamp-docker-run-async
                    args
                    (lambda (result) (settle index result)))
                   processes))))
      (condition-case err
          (if sequential
              (launch 0)
            (dotimes (index total) (launch index)))
        ((error quit)
         ;; 派发失败（生成物写入 / 参数构造）时释放 pending，避免永久锁死
         (unless finished
           (setq finished t)
           (remhash name ebasecamp-command--pending))
         (signal (car err) (cdr err))))
      (nreverse processes))))

(cl-defun ebasecamp-command-run (action project keys &key on-complete)
  "执行生命周期 ACTION（start / stop / restart / down），返回启动的进程列表。
PROJECT 为项目对象、symbol 或字符串；KEYS 为选中服务（nil 表示全部）。
执行顺序：
1. 同一项目已有命令在执行（`ebasecamp-command-pending-p'）→ signal
   `ebasecamp-command-busy'；
2. 按 scope 拆分（`ebasecamp-command-split-keys'）；down 对 shared 分支
   signal `ebasecamp-command-error'（shared 组可能被其他项目使用）；
3. start 且 per-project 批次带 `:requires-shared'（跨 scope depends_on）时：
   校验依赖确实是 shared 组服务（否则 signal `ebasecamp-command-error'），
   然后**串行**先跑 shared 批次（服务集合覆盖这些依赖）、成功后才跑
   per-project 批次；shared 失败即中止，未派发的批次记为 `:skipped'。
   stop / restart / down 不做自动补齐 —— 补齐等于在停止/重启操作里反向启动
   容器；
4. `ebasecamp-command-ensure-network' 同步确保 external network 存在；
5. 每个非 nil 分支：先 `ebasecamp-compose-write' 写该 scope 的生成物，再
   `ebasecamp-docker-run-async' 异步执行；down 不追加服务名；
6. 全部批次结束后清除 pending 并调用 ON-COMPLETE，参数为 plist：
   `(:action ACTION :project NAME :ok BOOL :results ((:scope S :exit N
   :stderr STR [:failed t|:skipped t]) ...) :auto-started-shared BOOL
   :order (SCOPE ...))'，任一分支失败 `:ok' 为 nil，stderr 原样保留。
返回已启动进程对象列表（无分支或同步完成时可能为 nil）。"
  (let* ((object (ebasecamp-command--project project))
         (name (ebasecamp-command--name object)))
    (when (ebasecamp-command-pending-p name)
      (signal 'ebasecamp-command-busy
              (list (format "项目 %s 已有命令在执行" name))))
    (let* ((split (ebasecamp-command-split-keys object keys))
           (project-branch (plist-get split :project))
           (shared-branch (plist-get split :shared))
           (requires (and project-branch
                          (plist-get project-branch :requires-shared))))
      (when (eq action 'down)
        (when shared-branch
          (signal 'ebasecamp-command-error
                  (list "shared 组不提供 down：其他项目可能正在使用这些容器")))
        (unless project-branch
          (signal 'ebasecamp-command-error
                  (list (format "项目 %s 没有 per-project 组的服务可 down" name)))))
      (let ((auto (and requires (eq action 'start) t)))
        (when auto
          (ebasecamp-command--check-requires object requires))
        (ebasecamp-command-ensure-network)
        (if auto
            (ebasecamp-command--dispatch
             action object name
             (list (ebasecamp-command--shared-branch
                    object shared-branch requires)
                   project-branch)
             t t on-complete)
          (ebasecamp-command--dispatch
           action object name
           (delq nil (list project-branch shared-branch))
           nil nil on-complete))))))

;;; 端口冲突检测（T3.3）

(defun ebasecamp-command--port-probe (port)
  "默认宿主端口探测：尝试 bind 0.0.0.0:PORT，成功返回 t、被占用返回 nil。
端口被占用时底层 signal 的错误（Address already in use）归一为 nil；其他
错误（权限等）原样再 signal，由调用方降级为 `unknown'。"
  (condition-case err
      (let ((process (make-network-process
                      :name "ebasecamp-port-probe"
                      :server t
                      :host "0.0.0.0"
                      :service port
                      :noquery t)))
        (delete-process process)
        t)
    ((error quit)
     (let ((message (downcase (error-message-string err))))
       (if (string-match-p "address already in use\\|address in use\\|in use"
                           message)
           nil
         (signal (car err) (cdr err)))))))

(defun ebasecamp-command--port-entries (selection)
  "返回选中项中带 published 端口的 (ENTRY . PORT) 列表（保持选择顺序）。"
  (let ((pairs nil))
    (dolist (entry selection)
      (dolist (pair (ebasecamp-service-ports (plist-get entry :record)))
        (when (car pair)
          (setq pairs (append pairs (list (cons entry (car pair))))))))
    pairs))

(defun ebasecamp-command-port-conflicts (project keys)
  "检测 PROJECT 中选中服务 KEYS 的端口冲突，返回冲突列表。
KEYS 语义同 `ebasecamp-command-split-keys'（nil 表示全部服务）。
冲突项 plist（`duplicate' 在前，`busy'/`unknown' 按选择顺序在后）：
- `(:kind duplicate :port P :services (\"g/s1\" \"g/s2\"))' —— 选中集合内
  published 端口重复；
- `(:kind busy :port P :service \"g/s\" :hint \"宿主端口已被占用\")'；
- `(:kind unknown :port P :service \"g/s\" :hint \"端口探测不可用，已跳过\")'
  —— 探测本身报错（权限等），**不阻塞**启动。
只检查 published 非 nil 的端口。探测函数由 `ebasecamp-command--port-free-p'
注入。纯函数（只读清单 + 探测）。"
  (let* ((object (ebasecamp-command--project project))
         (selection (ebasecamp-command--selection object keys))
         (pairs (ebasecamp-command--port-entries selection))
         (by-port (make-hash-table :test #'eql))
         (order nil))
    (dolist (pair pairs)
      (let ((port (cdr pair)))
        (unless (gethash port by-port)
          (setq order (append order (list port))))
        (puthash port (append (gethash port by-port) (list (car pair))) by-port)))
    (let ((conflicts nil))
      (dolist (port order)
        (let ((entries (gethash port by-port)))
          (when (>= (length entries) 2)
            (setq conflicts
                  (append conflicts
                          (list (list :kind 'duplicate
                                      :port port
                                      :services (mapcar (lambda (entry)
                                                          (plist-get entry :key))
                                                        entries))))))))
      (dolist (pair pairs)
        (let* ((entry (car pair))
               (port (cdr pair))
               (failure nil)
               (free (condition-case err
                         (funcall ebasecamp-command--port-free-p port)
                       ((error quit) (setq failure err) nil))))
          (cond
           (failure
            (setq conflicts
                  (append conflicts
                          (list (list :kind 'unknown
                                      :port port
                                      :service (plist-get entry :key)
                                      :hint "端口探测不可用，已跳过")))))
           ((null free)
            (setq conflicts
                  (append conflicts
                          (list (list :kind 'busy
                                      :port port
                                      :service (plist-get entry :key)
                                      :hint "宿主端口已被占用"))))))))
      conflicts)))

(provide 'ebasecamp-command)
;;; ebasecamp-command.el ends here
