;;; ebasecamp-ui.el --- ebasecamp 只读主界面（etaf / etaf-ui） -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.5.4
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 主界面：在一个 etaf 缓冲区里展示组为中心的「组 → 配置」两级视图。组来自
;; 清单（`ebasecamp-model-groups'），因此**不依赖**项目是否存在；配置来自
;; 组的 configs 槽（`ebasecamp-model-group-configs'），每份配置指向一个项目。
;;
;; 布局（一个 Host 树）：
;;
;;   根 column
;;   ├─ row（顶栏）: etaf-label "ebasecamp" + 统计 label + etaf-button "刷新"
;;   ├─ etaf-divider
;;   ├─ etaf-splitter（horizontal，ratio 0.32）
;;   │  ├─ slot first  → etaf-tree（组 → 配置 两级）
;;   │  └─ slot second → 右栏（见 `ebasecamp-ui--detail-view'）：
;;   │       未选中组   → 占位「选择左侧的组」
;;   │       选中组无配置 → 空态「尚未关联任何项目」+ 组定义的服务名（只读）
;;   │       选中组有配置 → 组标题行（标题 + scope 徽标 + "N 配置"）
;;   │                     + 每份配置一个 `etaf-panel' 段：
;;   │                         header 槽 = 段头 row（配置 → 项目 + scope 徽标
;;   │                         + running/total 徽标 + 启动/停止/重启按钮）
;;   │                         default 槽 = etaf-divider + 服务表 etaf-table
;;   ├─ etaf-divider
;;   ├─ row（底栏）: 导入 compose / 导出 compose / 销毁环境（ghost 按钮）
;;   ├─ 提示区: `etaf-alert'（`ebasecamp-ui--notice-view'）
;;   └─ 销毁确认框: `etaf-dialog'（`ebasecamp-ui-confirm-dialog'，读 confirm ref）
;;
;; 无任何组时整棵树替换为 `etaf-empty'（引导用户去
;; `ebasecamp-config-directory' 定义清单）。
;;
;; 状态与生命周期：
;;
;; - 会话对象（`ebasecamp-ui-session'）持有若干 `etaf-ref'：
;;   渲染数据（`state'，见 `ebasecamp-ui--build-state'）、选中的组名
;;   （`selected-group'，symbol 或 nil）、树的展开 key 列表（`expanded'）、
;;   勾选的服务 key 列表（`selected-ref'）、生命周期命令执行中标记（`busy'）、
;;   操作提示（`notice'，值为 nil 或
;;   `(:kind error|warning|success|info :title STR :message STR :detail STR-or-nil)'）、
;;   销毁确认框开关（`confirm'）、待确认动作（`confirm-action'），以及
;;   提示自动清除定时器（`notice-timer'）。会话在 `ebasecamp-ui-open' 中创建，
;;   `ebasecamp-ui-close' 中销毁；
;; - 渲染数据是**单一 plist**：`ebasecamp-ui-refresh' 重新采集状态、重建
;;   state 并写回 ref，视图只需读 ref 就整体重渲染（不需要 render-tick）。
;;   state 里每组带 `:instances'（每份配置一项，由
;;   `ebasecamp-data-group-instances' 装配）与逐级汇总的 `:running' /
;;   `:total' —— 一次 state 构建每组只装配一次实例，避免重复读状态快照；
;; - `etaf-on-mounted' → `ebasecamp-status-start'，回调里调
;;   `ebasecamp-ui-refresh'（传入 `ebasecamp-status-last-records'，避免轮询
;;   一次刷新跑两次 `docker ps'）；
;; - `etaf-on-unmounted' → `ebasecamp-status-stop' + 取消提示定时器；
;; - 树的选择：`:on-select' 把组名写进 `selected-group'，`:on-toggle' 把新的
;;   key 列表写进 `expanded'（展开状态由会话持有，重渲染后保持）；
;; - 服务勾选的 key 形如 "组名/服务名"（`ebasecamp-ui--instance-key'）：
;;   同一组在不同项目实例下若服务同名，选中状态**跨段共享** —— 这是第一期
;;   语义（容器 ID 与项目名不参与 key，重启后选中仍稳定）。`selected-ref'
;;   由 `ebasecamp-ui-selected-keys' 消费：段内按钮经
;;   `ebasecamp-ui--section-action' 按**该段自己的** `:project' 派发到命令层
;;   （`ebasecamp-command-run'），同组多实例因此不会串段；
;; - 底栏三个动作（`ebasecamp-ui--footer-view'）：导入 compose
;;   （`ebasecamp-ui-import-compose'）、导出 compose
;;   （`ebasecamp-ui-export-compose'）、销毁环境
;;   （`ebasecamp-ui-destroy-environment'）。导出与销毁都用 `completing-read'
;;   选项目；销毁先写 `confirm-action' 再打开 `etaf-dialog' 二次确认，
;;   `ebasecamp-ui-confirm' 确认后走与段内按钮同一条派发路径
;;   `ebasecamp-ui--dispatch'（keys 为 nil = 全部服务）；
;; - 提示的呈现：`ebasecamp-ui--notice-view' 把 notice 渲染成 `etaf-alert'
;;   （`:detail' 以换行拼接进 message，`:dismissible' 的关闭按钮清空 notice）；
;;   成功 / 信息类提示在 `ebasecamp-ui-notice-timeout' 秒后自动清除，定时器
;;   存进会话，`ebasecamp-ui-close' 与写新 notice 时都会先取消它（防泄漏）。
;;   这里不用 `etaf-toast'：其实测要求 `:anchor' 必填（必须是带 `:id' 的
;;   Host），且 batch 下只画出标题、正文不可见，无法覆盖需要展示 stderr 的
;;   场景；
;; - `busy' 为真时段内按钮全部 `:disabled'（渲染期从 ref 求值），
;;   `ebasecamp-ui--section-action' 与 `ebasecamp-ui--dispatch' 也直接拒绝
;;   （双保险：UI 不渲染可点按钮，函数层不被误调）；底栏三个动作不是生命
;;   周期命令，故不参与 busy 判定，销毁的危险性由二次确认承担。
;;
;; 渲染期读 ref（`etaf-value'）会建立渲染依赖：写 ref 即可让统计文案、树项、
;; 展开状态同步更新。注意 `etaf-button' 的 `:disabled' 只接受布尔值（传 ref
;; 对象会 signal `etaf-renderer-error'），必须在渲染时读取其值。
;;
;; 配色（v0.4 批次 T）：两层 —— 基础色（前景 / 背景 / 面板 / 边框）从 Emacs
;; face 取，状态色（success / warning / danger / info / disabled / accent /
;; button / checkbox / table-selected）取内置的明暗两套 palette，按
;; `background-mode' 帧参数选择（见 `ebasecamp-ui--theme-plist'）。整套 token 由
;; `ebasecamp-ui--theme'（一个 `etaf-ref'）承载，经 `etaf-theme-provide' 在
;; `ebasecamp-ui-app' 的 `:setup' 里提供给整棵子树；`load-theme' 切换时
;; `enable-theme-functions' / `disable-theme-functions' 钩子重算 ref，只刷新属性
;; 不整树重挂载。render 区因此**不含任何色值字面量**（全部走
;; `etaf-theme-token'），由测试机械守护。
;;
;; 本模块不拼任何 docker 命令（那是 `ebasecamp-docker' / `ebasecamp-command'
;; 的职责），只消费 `ebasecamp-status'、`ebasecamp-data' 与
;; `ebasecamp-command' 的公开接口。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'ebasecamp-model)
(require 'ebasecamp-config)
(require 'ebasecamp-config-write)
(require 'ebasecamp-import)
(require 'ebasecamp-export)
(require 'ebasecamp-status)
(require 'ebasecamp-data)
(require 'ebasecamp-command)

(defcustom ebasecamp-ui-buffer-name "*ebasecamp*"
  "ebasecamp 主界面的缓冲区名。"
  :type 'string
  :group 'ebasecamp)

(defcustom ebasecamp-ui-notice-timeout 3
  "成功 / 信息类提示自动清除的秒数。
错误类提示不自动清除（需要用户阅读 stderr），只能手动关闭。"
  :type 'number
  :group 'ebasecamp)

;; 默认左栏宽度占比的**单一来源**：defcustom 默认值、两处 fallback、保存时的
;; fallback 与新建会话的 ref 初值全部引用本常量 —— 改默认值只需改这一处，否则
;; 「删掉状态文件后重置」的行为会取决于走的是哪条路径。
(defconst ebasecamp-ui--split-ratio-default 0.26
  "左侧组树默认宽度占比（`etaf-splitter' 的 `:ratio'）的唯一来源。
`ebasecamp-ui--split-ratio' 的 defcustom 默认值、`--load-ui-state' /
`--current-split-ratio' / `--save-ui-state' 的 fallback、以及新建会话的 ref
初值都引用本常量。")

(defcustom ebasecamp-ui--split-ratio ebasecamp-ui--split-ratio-default
  "左侧组树的默认宽度占比（`etaf-splitter' 的 `:ratio'）。
只是**默认值**：会话里真正生效的是 `ebasecamp-ui-session-split-ratio'（一个
`etaf-ref'），拖动分隔线后写入会话并持久化到 `ebasecamp-ui--ui-state-file'。
默认值见 `ebasecamp-ui--split-ratio-default' 而非旧的 0.38 —— 组节点
文案已改短（不再拼「· N 项目」），该宽度足够显示组名与勾选框，把宽度让给右栏
的服务表格。
越界值在读入时钳制到 `[ebasecamp-ui--split-ratio-min, -max]'：fallback 路径
同样过钳制，因此直接 `setq' 本变量也不会导致渲染失败。"
  :type 'number
  :group 'ebasecamp)

(defconst ebasecamp-ui--split-ratio-min 0.15
  "左栏宽度占比下限（`etaf-splitter' 的 `:min-ratio'）。
再窄组名会被截断到不可读；同时它是钳制下界 —— 越界值不钳制会让
`etaf-splitter' 的 `:ratio' 校验在渲染期 signal。")

(defconst ebasecamp-ui--split-ratio-max 0.55
  "左栏宽度占比上限（`etaf-splitter' 的 `:max-ratio'）。
再宽右栏的服务表格会被挤到无法阅读；同时它是钳制上界（见上）。")

(defun ebasecamp-ui--clamp-ratio (value)
  "把 VALUE 钳制到 `[ebasecamp-ui--split-ratio-min, -max]' 并返回。
VALUE 不是数字时返回 nil（调用方据此跳过写入，而不是替用户猜一个值）。
钳制是**渲染前置条件**：`etaf-splitter' 的 `:ratio' 校验为
`(<= min-ratio ratio max-ratio)'，越界值会让 `etaf-check-prop' 在渲染期
signal，界面直接打不开。"
  (when (numberp value)
    (max ebasecamp-ui--split-ratio-min
         (min ebasecamp-ui--split-ratio-max value))))

;;; 左栏宽度的运行时状态（ui-state.el）

;; `ui-state.el' 是**运行时状态缓存**（位于 `ebasecamp-cache-directory'），不是
;; 清单：不参与 `ebasecamp-config-load'，不经界面 `e'（编辑清单）入口，可随时
;; 删除（下次打开回默认）。因此它不破坏 ADR-0003 的「清单唯一写入口」不变量。

(defun ebasecamp-ui--ui-state-file ()
  "返回界面运行时状态文件路径：`<ebasecamp-cache-directory>/ui-state.el'。"
  (expand-file-name "ui-state.el" ebasecamp-cache-directory))

(defun ebasecamp-ui--load-ui-state ()
  "读 `ebasecamp-ui--ui-state-file'，返回左栏宽度占比（浮点）。
回退规则：文件不存在 / 读不出 / 形态不是 `(:split-ratio NUMBER)' 时返回
**经钳制**的 `ebasecamp-ui--split-ratio'（defcustom 默认）。defcustom 被用户
`setq' 成越界值时同样钳到 `[min, max]'，非数字则回退
`ebasecamp-ui--split-ratio-default'；读到数字后一律
经 `ebasecamp-ui--clamp-ratio' 钳制（越界值不得进入渲染）。
只接受 `(:split-ratio NUMBER)' 一种形态：`car' 必须是 `:split-ratio'，其余
（`(foo)'、裸字符串、空文件、`(:other 1)'、ratio 为字符串或 nil）全按非法处理。
**不执行文件中的代码**：Emacs 31.1 起 `#.' 读语法默认禁用（`(read \"#.(+ 1 2)\")'
返回 `invalid-read-syntax \"#.\"'），且 `read-eval' 变量已不存在（实测 `boundp'
为 nil，写 `(let ((read-eval nil)) ...)' 会触发「Unused lexical variable」编译
错误）。为了在旧版 Emacs（其 `read-eval' 默认 t）上也不执行代码，读前显式拒绝
含 `#.' 的文本 —— 合法状态文件永远不会有这个序列。"
  (let ((file (ebasecamp-ui--ui-state-file)))
    (or (and (file-readable-p file)
             (condition-case nil
                 (with-temp-buffer
                   (insert-file-contents file)
                   (let ((text (buffer-string)))
                     (unless (string-match-p "#\\." text)
                       (goto-char (point-min))
                       (let ((form (read (current-buffer))))
                         (when (and (consp form) (eq :split-ratio (car form)))
                           (ebasecamp-ui--clamp-ratio (cadr form)))))))
               ((error quit) nil)))
        ;; fallback 也不得把 defcustom 原样放行：它可能被 `setq' 成越界值
        ;; （渲染期 `etaf-splitter' 的 `:ratio' 校验会 signal）；非数字时
        ;; `--clamp-ratio' 返回 nil，回退默认值常量。
        (or (ebasecamp-ui--clamp-ratio ebasecamp-ui--split-ratio)
            ebasecamp-ui--split-ratio-default))))

(defun ebasecamp-ui--current-split-ratio ()
  "返回当前会话的左栏宽度占比；没有会话时返回（钳制后的）defcustom 默认值。"
  (let ((session ebasecamp-ui--session))
    (if session
        (etaf-value (ebasecamp-ui-session-split-ratio session))
      (or (ebasecamp-ui--clamp-ratio ebasecamp-ui--split-ratio)
          ebasecamp-ui--split-ratio-default))))

(defun ebasecamp-ui--set-split-ratio (value)
  "把当前会话的左栏宽度占比设为 VALUE（先钳制），返回会话里的新值。
VALUE 不是数字时忽略（不写 ref、不 signal）。只写 ref 不重渲染整棵树：
splitter 的 `:ratio' 收的就是这个 ref，`etaf-ui--reactive-value' 的追踪读取
让**只有 splitter 自己**在值变化时重渲染。"
  (let ((ratio (ebasecamp-ui--clamp-ratio value)))
    (when ratio
      (etaf-set-value (ebasecamp-ui-session-split-ratio (ebasecamp-ui-session))
                      ratio))
    (ebasecamp-ui--current-split-ratio)))

(defun ebasecamp-ui--save-ui-state ()
  "把当前左栏宽度占比写入 `ebasecamp-ui--ui-state-file'，返回路径（失败 nil）。
目录不存在时 `make-directory' 递归创建；先写同目录 `make-temp-file' 生成的唯一
临时文件，再 `rename-file' 原子覆盖目标 —— 避免写一半留下损坏文件（那会让下次
打开回退默认）。内容只有 `(:split-ratio FLOAT)'：不含密钥、不含清单内容。
写盘失败只 `message' 不 signal：本函数在 `ebasecamp-ui-close' 与拖动回调里
调用，缓存目录不可写不应阻断关闭界面。"
  (let ((file (ebasecamp-ui--ui-state-file))
        ;; `--current-split-ratio' 恒返回数字：会话在时取 ref 值（由
        ;; `--load-ui-state' / `--set-split-ratio' 写入，均已钳制），无会话时
        ;; 返回钳制后的 defcustom 默认值或默认常量，因此不需要再 `or' 兜底。
        (ratio (ebasecamp-ui--current-split-ratio)))
    (condition-case err
        (let* ((directory (file-name-directory file))
               (temp nil))
          (make-directory directory t)
          (setq temp (make-temp-file (expand-file-name "ui-state-" directory)
                                     nil ".el"))
          (unwind-protect
              (progn
                (with-temp-file temp
                  (prin1 (list :split-ratio ratio) (current-buffer))
                  (insert "\n"))
                (rename-file temp file t))
            (when (file-exists-p temp)
              (ignore-errors (delete-file temp)))))
      ((error quit)
       (message "ebasecamp: 保存界面状态失败：%S" err)
       (setq file nil)))
    file))

;;; 拖动分隔线（`etaf-splitter' 的 `:on-change'）

(defun ebasecamp-ui--splitter-drag-ratio (gesture)
  "把拖动 GESTURE 折算成新的左栏宽度占比（浮点）或 nil。
`etaf-splitter' 的 `:on-change' 收到的**不是新比例数字，而是原始手势 plist**：
它被原样接到分隔线 Host 的 `:on-drag' 上（`etaf-ui-desktop.el' 的
`etaf-splitter' `:render' 与 `etaf-ui--splitter-overlay-divider'），形态来自
`ebox-keymap-create' 的 `:drag' 协议 —— `:phase'（`start' / `move' / `end' /
`cancel'）、`:position'（指针 `(X . Y)'，X 为像素）、`:delta'（相对按下点的
`(DX . DY)' 像素）、`:node'（分隔线节点）、`:keyboard'（`t' 表示来自
`etaf-drag-step' 的键盘拖动）。
指针拖动按「指针 X − 容器左边界」/ 容器宽度折算，容器取分隔线节点的父节点
（splitter 的 flex 根）；键盘拖动没有绝对坐标（`:position' 只有 (0 . 0) 与位移），
改按「当前比例 + DX / 容器宽度」折算。容器几何拿不到时返回 nil（调用方跳过）。"
  (let* ((node (plist-get gesture :node))
         (parent (and node (ebox-node-parent node)))
         (geometry (and parent (ignore-errors (ebox-node-geometry parent))))
         (left (plist-get geometry :x))
         (width (plist-get geometry :width)))
    (when (and (numberp left) (numberp width) (> width 0))
      (if (plist-get gesture :keyboard)
          (let ((dx (car-safe (plist-get gesture :delta))))
            (when (numberp dx)
              (ebasecamp-ui--clamp-ratio
               (+ (ebasecamp-ui--current-split-ratio) (/ (float dx) width)))))
        (let ((x (car-safe (plist-get gesture :position))))
          (when (numberp x)
            (ebasecamp-ui--clamp-ratio (/ (float (- x left)) width))))))))

(defun ebasecamp-ui--splitter-on-change (gesture)
  "`etaf-splitter' 的 `:on-change' 回调：拖动时更新并持久化左栏宽度占比。
`move' 阶段只写会话 ref（布局即时跟随，ref 变化自然驱动重渲染 —— 这里**不**
手动重渲染整棵树，否则每次鼠标移动都重建整个界面）；`end' 阶段写回并落盘一次
（跨会话记住）；`start' / `cancel' 不动状态（手势被取消时不该固化中间态）。"
  (pcase (plist-get gesture :phase)
    ('move
     (when-let* ((ratio (ebasecamp-ui--splitter-drag-ratio gesture)))
       (ebasecamp-ui--set-split-ratio ratio)))
    ('end
     (when-let* ((ratio (ebasecamp-ui--splitter-drag-ratio gesture)))
       (ebasecamp-ui--set-split-ratio ratio)
       (ebasecamp-ui--save-ui-state)))))

;;; 主题（face 基础色 + 明暗两套 palette 状态色）

;; 两层设计（见 `openspec/completed/2026-10-23-ui-layout-theme-nav.md' 的 T1）：
;;
;; - **基础色（9 个）**：从 Emacs face 取（`default' / `mode-line-inactive' /
;;   `shadow' / `fringe'），因此跟随用户当前的 `load-theme'；
;; - **状态色（26 个）**：success / warning / danger / info / disabled / accent /
;;   button / checkbox / table-selected。etaf-ui 的 `etaf-ui--style-palette' 只有
;;   一套浅色值，暗色主题下 badge / alert 仍是浅色块；这里内置明暗两套，按
;;   `(frame-parameter nil \\='background-mode)' 选择；
;; - **回退**：`face-attribute' 返回 `unspecified'（batch / TTY 下 `default' 的
;;   前景背景是 `\"unspecified-fg\"' / `\"unspecified-bg\"' 伪色）时，基础色回退到
;;   内置 palette 的**同名键**，不回退到 `default' 的同名属性（避免自指）；
;; - **覆盖**：`ebasecamp-ui-theme' 非 nil 时按键覆盖生成结果（plist）。
;;
;; 色值字面量在这里集中（palette 与 defcustom 默认值），render 区一律用
;; `etaf-theme-token'，由 `test/ebasecamp-ui-tests.el' 的
;; `ebasecamp-ui-test-render-region-has-no-literal-colors' 机械守护。

(defcustom ebasecamp-ui-theme nil
  "覆盖内置主题 token 的 plist；nil 表示完全跟随（face + 明暗 palette）。
非 nil 时按键覆盖 `ebasecamp-ui--theme-plist' 的生成结果（同键以本值优先），
键用 `:ui-*' 关键字，值为色值字符串，例如
`(:ui-accent \"#B45309\" :ui-accent-soft-bg \"#FDF2E3\")'。
只覆盖确有需要的键：未覆盖的键仍按「face → 内置 palette」生成。"
  :type '(plist :key-type symbol :value-type color)
  :group 'ebasecamp)

(defconst ebasecamp-ui--palette-light
  '(:ui-fg "#252A2E"
    :ui-bg "#FFFDF8"
    :ui-panel-fg "#252A2E"
    :ui-panel-bg "#F7F4EC"
    :ui-panel-border "#C9D0DA"
    :ui-muted-fg "#526174"
    :ui-border "#687386"
    :ui-divider-bg "#DCE3EB"
    :ui-table-border "#687386"
    :ui-accent "#2F6FE4"
    :ui-accent-fg "#FFFFFF"
    :ui-accent-soft-bg "#DCE7FA"
    :ui-success-fg "#2F6B43"
    :ui-success-bg "#DCEBDD"
    :ui-success-border "#6D8A73"
    :ui-warning-fg "#8A4B08"
    :ui-warning-bg "#FFF3D6"
    :ui-warning-border "#D99A2B"
    :ui-danger-fg "#C0392B"
    :ui-danger-bg "#FDECEA"
    :ui-danger-border "#CF6A6A"
    :ui-info-fg "#155E75"
    :ui-info-bg "#E0F2FE"
    :ui-info-border "#38A3C7"
    :ui-disabled-fg "#687386"
    :ui-disabled-bg "#E5E7EB"
    :ui-disabled-border "#9CA3AF"
    :ui-button-primary-fg "#FFFFFF"
    :ui-button-primary-bg "#2F6FE4"
    :ui-button-secondary-fg "#1F4FB0"
    :ui-button-secondary-bg "#DCE7FA"
    :ui-button-ghost-fg "#252A2E"
    :ui-checkbox-enabled-fg "#252A2E"
    :ui-table-selected-fg "#2F6B43"
    :ui-table-selected-bg "#DCEBDD")
  "浅色 palette：9 个基础色回退值 + 26 个状态色。
基础色那 9 个键只在对应 face 的属性为 `unspecified' 时使用（face 有值时 face
优先）；状态色一律取本 palette。")

(defconst ebasecamp-ui--palette-dark
  '(:ui-fg "#D7DEE8"
    :ui-bg "#1B1F24"
    :ui-panel-fg "#D7DEE8"
    :ui-panel-bg "#23282F"
    :ui-panel-border "#3C4450"
    :ui-muted-fg "#8A94A6"
    :ui-border "#4A5260"
    :ui-divider-bg "#2F353D"
    :ui-table-border "#4A5260"
    :ui-accent "#6EA8FF"
    :ui-accent-fg "#0B1220"
    :ui-accent-soft-bg "#223C5C"
    :ui-success-fg "#7BC98F"
    :ui-success-bg "#1E3A28"
    :ui-success-border "#3E6B4E"
    :ui-warning-fg "#E5B567"
    :ui-warning-bg "#3D2E12"
    :ui-warning-border "#8A6A2B"
    :ui-danger-fg "#FF8A80"
    :ui-danger-bg "#3E1F1F"
    :ui-danger-border "#A34A4A"
    :ui-info-fg "#7FCBE8"
    :ui-info-bg "#10333F"
    :ui-info-border "#2A6B80"
    :ui-disabled-fg "#8A94A6"
    :ui-disabled-bg "#2A2F37"
    :ui-disabled-border "#4A5260"
    :ui-button-primary-fg "#0B1220"
    :ui-button-primary-bg "#6EA8FF"
    :ui-button-secondary-fg "#BFD8FF"
    :ui-button-secondary-bg "#223C5C"
    :ui-button-ghost-fg "#D7DEE8"
    :ui-checkbox-enabled-fg "#D7DEE8"
    :ui-table-selected-fg "#9FE0B0"
    :ui-table-selected-bg "#1E3A28")
  "暗色 palette：键集合与 `ebasecamp-ui--palette-light' 完全相同。
低亮度背景（success-bg 等）不是「把浅色值调暗一点」，而是独立取的低饱和深色，
以保证暗色主题下 badge / alert 的文字对比度。")

(defun ebasecamp-ui--background-mode ()
  "返回当前帧的明暗模式：`dark' 或 `light'。
来源是 `background-mode' 帧参数（`load-theme' 加载 modus 主题时会被改写）；
缺省（nil）按 `light' 处理。纯函数。"
  (if (eq (frame-parameter nil 'background-mode) 'dark) 'dark 'light))

(defun ebasecamp-ui--palette (mode)
  "返回 MODE（`light' / `dark'）对应的内置 palette。纯函数。"
  (if (eq mode 'dark) ebasecamp-ui--palette-dark ebasecamp-ui--palette-light))

(defun ebasecamp-ui--color-value-p (value)
  "返回 VALUE 是否为可用色值（非空字符串且不是 `unspecified' 伪色）。
`face-attribute' 在无显示环境（batch / TTY）下对 `default' 的前景背景返回
字符串 `\"unspecified-fg\"' / `\"unspecified-bg\"'（实测 Emacs 31.1），其他 face
返回符号 `unspecified' —— 两者都必须判为「无值」。纯函数。"
  (and (stringp value)
       (not (string-empty-p value))
       (not (string-prefix-p "unspecified" value))))

(defun ebasecamp-ui--face-color (face attribute &optional key palette)
  "返回 FACE 的 ATTRIBUTE 颜色；无值时回退到 PALETTE 里 KEY 的值。
`face-attribute' 用 `(face-attribute FACE ATTRIBUTE nil t)'（inherit 打开，取
最终生效值）；FACE 未定义时（`Invalid face'）同样按无值处理。
**不**回退到 `default' 的同名属性：那会让 `:ui-panel-*' 等键退化成与
`:ui-fg' / `:ui-bg' 完全相同（自指），丢失面板层次。纯函数（只读 face）。"
  (let ((value (condition-case nil
                   (face-attribute face attribute nil t)
                 (error nil))))
    (cond
     ((ebasecamp-ui--color-value-p value) value)
     (key (plist-get palette key))
     (t nil))))

(defun ebasecamp-ui--border-color (palette key)
  "返回边框类颜色：`fringe' 前景 → `mode-line-inactive' 背景 → PALETTE 的 KEY。
`fringe' 前景在默认主题下是 `unspecified'（实测 31.1，modus 也不定义），
所以真正的常用来源是 `mode-line-inactive' 背景（分隔线/面板边框取它最协调）。
纯函数。"
  (or (ebasecamp-ui--face-color 'fringe :foreground)
      (ebasecamp-ui--face-color 'mode-line-inactive :background)
      (plist-get palette key)))

(defun ebasecamp-ui--theme-merge (override base)
  "把 OVERRIDE 的键覆盖到 BASE 之上，返回新 plist（同键以 OVERRIDE 为准）。
两份都是 `:keyword value' 形式的 plist；结果按键去重（不含重复键），以免
`etaf-theme-provide' 的默认值展开出现重复条目。纯函数。"
  (let ((result (cl-copy-list override)))
    (cl-loop for (key value) on base by #'cddr
             unless (plist-member result key)
             do (setq result (plist-put result key value)))
    result))

(defun ebasecamp-ui--theme-plist (&optional mode)
  "返回提供给 etaf 的主题 plist（计划 T4 的 35 个 `:ui-*' token）。
基础色（9 个）取 face（未指定时回退 palette 同名键），状态色（26 个）取
MODE 对应的内置 palette；两份合并后按键去重。MODE 缺省读
`(frame-parameter nil \\='background-mode)'，显式传入便于按指定明暗生成（测试
与「预览另一套主题」场景）。`ebasecamp-ui-theme' 非 nil 时其键最后覆盖。
纯函数（除读 face 与帧参数外无副作用）。"
  (let* ((palette (ebasecamp-ui--palette
                   (or mode (ebasecamp-ui--background-mode))))
         (base (list :ui-fg (ebasecamp-ui--face-color
                             'default :foreground :ui-fg palette)
                     :ui-bg (ebasecamp-ui--face-color
                             'default :background :ui-bg palette)
                     :ui-panel-fg (or (ebasecamp-ui--face-color
                                       'mode-line-inactive :foreground)
                                      (ebasecamp-ui--face-color
                                       'default :foreground :ui-panel-fg palette))
                     :ui-panel-bg (or (ebasecamp-ui--face-color
                                       'mode-line-inactive :background)
                                      (ebasecamp-ui--face-color
                                       'default :background :ui-panel-bg palette))
                     :ui-panel-border (ebasecamp-ui--border-color
                                       palette :ui-panel-border)
                     :ui-muted-fg (ebasecamp-ui--face-color
                                   'shadow :foreground :ui-muted-fg palette)
                     :ui-border (ebasecamp-ui--border-color palette :ui-border)
                     :ui-divider-bg (ebasecamp-ui--border-color
                                     palette :ui-divider-bg)
                     :ui-table-border (ebasecamp-ui--border-color
                                       palette :ui-table-border))))
    (ebasecamp-ui--theme-merge ebasecamp-ui-theme
                               (ebasecamp-ui--theme-merge base palette))))

(defvar ebasecamp-ui--theme (etaf-ref (ebasecamp-ui--theme-plist)
                                      :name 'ebasecamp-ui-theme)
  "承载当前主题 plist 的 `etaf-ref'。
`ebasecamp-ui-app' 的 `:setup' 用 `etaf-theme-provide' 把它提供给整棵子树，
因此根子树里所有 Host 的 `etaf-theme-token'（含 etaf-ui 组件的 badge / alert /
button / table）都从这里取值。ref 被 Host 订阅：值变化只刷新属性，不整树重挂载
（探针实测：同一节点身份不变而 `:bgcolor' 从旧值变为新值）。")

(defun ebasecamp-ui--refresh-theme ()
  "重新计算主题 plist 并写回 `ebasecamp-ui--theme'，返回新 plist。
主题钩子（`ebasecamp-ui--theme-hook'）与切换明暗的测试都走这里；写 ref 触发
属性级刷新。"
  (let ((plist (ebasecamp-ui--theme-plist)))
    (when (and ebasecamp-ui--theme
               (not (equal plist (etaf-value ebasecamp-ui--theme))))
      (etaf-set-value ebasecamp-ui--theme plist))
    plist))

(defun ebasecamp-ui--theme-hook (_theme)
  "`enable-theme-functions' / `disable-theme-functions' 的回调：重算主题。
参数（刚启用/停用的主题名）不使用 —— face 与 `background-mode' 都是**全量**
状态，重算整份 plist 比按 theme 增量推断更简单也更不容易漏（主题层叠时
最后一次 `load-theme' 的 face 才是当前生效值）。"
  (ebasecamp-ui--refresh-theme))

(defun ebasecamp-ui--theme-hooks-install ()
  "挂载主题钩子（`ebasecamp-ui-open' 调用）。
`enable-theme-functions' / `disable-theme-functions' 是 Emacs 29+ 的 abnormal
hook（本机 31.1 实测存在且 `load-theme' 时会调用，参数为被启用/停用的主题名）；
`add-hook' 对同一函数幂等，重复 open 不会重复挂载。"
  (add-hook 'enable-theme-functions #'ebasecamp-ui--theme-hook)
  (add-hook 'disable-theme-functions #'ebasecamp-ui--theme-hook))

(defun ebasecamp-ui--theme-hooks-remove ()
  "卸载主题钩子（`ebasecamp-ui-close' 调用，与 install 严格对称）。
界面关闭后 ref 不再需要跟随主题；残留钩子会在每次 `load-theme' 时白算一遍
plist，且让「关掉界面就与主题解耦」的语义失真。"
  (remove-hook 'enable-theme-functions #'ebasecamp-ui--theme-hook)
  (remove-hook 'disable-theme-functions #'ebasecamp-ui--theme-hook))

;;; 会话

(cl-defstruct (ebasecamp-ui-session (:constructor ebasecamp-ui--session-create))
  "一次界面会话的可变状态。
STATE 为整棵树的渲染数据（plist，见 `ebasecamp-ui--build-state'）；
SELECTED-GROUP 为当前选中的组名（symbol 或 nil）；EXPANDED 为 `etaf-tree'
的展开 key 列表；SELECTED-REF / BUSY / NOTICE / CONFIRM / SPLIT-RATIO 均为 `etaf-ref'；
SPLIT-RATIO 是左栏宽度占比（初始值来自 `ebasecamp-ui--load-ui-state'，拖动时
更新并落盘）；CONFIRM-ACTION 为等待确认的动作 symbol（无则 nil）；
NOTICE-TIMER 为临时的提示自动清除定时器（无则 nil，必须随会话一起取消）。"
  state selected-group expanded selected-ref busy notice confirm confirm-action
  split-ratio notice-timer)

(defvar ebasecamp-ui--session nil
  "当前界面会话（`ebasecamp-ui-session' 对象）；未打开时为 nil。")

(defconst ebasecamp-ui--hint
  "勾选服务后可批量启动 / 停止 / 重启；销毁环境只移除本项目的 per-project 容器。"
  "界面底部提示区的默认文案（notice 为空时显示）。")

(defun ebasecamp-ui--ensure-manifest ()
  "模型注册表为空时，按 `ebasecamp-config-directory' 加载一次清单。
加载错误已被 `ebasecamp-config-load' 收集到返回值的 `:errors'，这里只在
异常（读目录失败等）时吞掉错误并记录消息，不影响界面渲染。"
  (when (null (ebasecamp-model-projects))
    (condition-case err
        (ebasecamp-config-load ebasecamp-config-directory)
      ((error quit)
       (message "ebasecamp: 加载清单失败：%S" err))))
  nil)

(defun ebasecamp-ui--default-expanded ()
  "返回默认展开的树 key 列表：清单里的全部组（默认全部展开）。"
  (mapcar (lambda (group)
            (ebasecamp-ui--group-key (symbol-name (ebasecamp-group-name group))))
          (ebasecamp-model-groups)))

;;; 项目上下文（`default-directory' → 项目 → 第一份配置所在组）

(defun ebasecamp-ui--project-for-directory (dir)
  "返回 DIR 所属的项目对象（最长 `:root' 前缀匹配）；无命中返回 nil。
三类输入直接给 nil：DIR 为 nil / 非字符串 / 不是已存在的目录。DIR 与每个项目
的 `:root' 都先 `expand-file-name' 再 `file-truename' 归一（`~'、`..'、软链
因此等价），比较前统一成 `file-name-as-directory' 形态 —— 只匹配**整段目录**，
`/tmp/a2' 不会被 root `/tmp/a' 命中。**大小写敏感**：`string-prefix-p' 默认
即敏感，这里既不传第三参数也不绑 `case-fold-search'（`/tmp/A' 与 `/tmp/a' 是
两个目录）。`:root' 为空串或目录不存在的项目跳过；多个命中取 root 最长者
（`/a/b/c' 同时命中 `/a/b' 与 `/a' 时取 `/a/b'）。纯函数。"
  (when (and (stringp dir) (file-directory-p dir))
    (let ((target (file-name-as-directory (file-truename (expand-file-name dir))))
          (best nil)
          (best-length 0))
      (dolist (project (ebasecamp-model-projects))
        (let ((root (ebasecamp-project-root project)))
          (when (and (stringp root) (not (string-empty-p root))
                     (file-directory-p root))
            (let* ((prefix (file-name-as-directory
                            (file-truename (expand-file-name root))))
                   (length (length prefix)))
              (when (and (> length best-length)
                         (string-prefix-p prefix target))
                (setq best project
                      best-length length))))))
      best)))

(defun ebasecamp-ui--first-group-for-project (project)
  "返回 PROJECT 的**第一份配置**所在组名（symbol），无命中返回 nil。
PROJECT 为项目名 symbol（也接受项目对象，内部归一为名字 —— 传对象却按 `eq'
比名字会静默返回 nil，是这个函数最容易踩的坑）。
「第一份」= 按 `ebasecamp-model-groups' 的组顺序、组内 `:configs' 顺序，首个
`:project' 命中 PROJECT 的配置。因此顺序契约只由清单的组定义顺序决定，不看项目
`groups' 槽（物化产物里也有该组，但物化顺序不是契约）。纯函数。"
  (let ((name (if (ebasecamp-project-p project)
                  (ebasecamp-project-name project)
                project)))
    (when name
      (cl-loop for group in (ebasecamp-model-groups)
               when (cl-loop for cell in (ebasecamp-model-group-configs group)
                             thereis (eq name
                                         (ebasecamp-model-config-project
                                          (cdr cell))))
               return (ebasecamp-group-name group)))))

(defun ebasecamp-ui--new-session ()
  "创建并返回新的界面会话（state / selected-group / expanded 及各 ref）。
左栏宽度占比在这里从 `ebasecamp-ui--ui-state-file' 载入（拖动过就用记住的值，
没拖过 / 文件非法就是 defcustom 默认）；本函数只读缓存文件，不写盘。

**项目上下文默认定位（P1/P2）**：按 `default-directory' 找所属项目
（`ebasecamp-ui--project-for-directory'），再取该项目第一份配置所在组
（`ebasecamp-ui--first-group-for-project'）作为初始选中组；任一跳落空就保持
既有行为（无选中组，右栏显示「选择左侧的组」）。只在这里算**一次** ——
`ebasecamp-ui-refresh' / `g' 只按现有 selected-group 重建 state，不覆盖用户
手选的组。"
  (let* ((project (ebasecamp-ui--project-for-directory default-directory))
         (group (and project
                     (ebasecamp-ui--first-group-for-project
                      (ebasecamp-project-name project)))))
    (ebasecamp-ui--session-create
     :state (etaf-ref (ebasecamp-ui--build-state group) :name 'ebasecamp-ui-state)
     :selected-group (etaf-ref group :name 'ebasecamp-ui-selected-group)
     :expanded (etaf-ref (ebasecamp-ui--default-expanded)
                         :name 'ebasecamp-ui-expanded)
     :selected-ref (etaf-ref nil :name 'ebasecamp-ui-selected)
     ;; 双保险：`--load-ui-state' 已钳过，这里再钳一次兜住任何绕过它的路径 ——
     ;; 越界 ratio 会让 `etaf-splitter' 的 `:ratio' 校验在渲染期 signal。
     :split-ratio (etaf-ref (or (ebasecamp-ui--clamp-ratio
                                 (ebasecamp-ui--load-ui-state))
                                ebasecamp-ui--split-ratio-default)
                            :name 'ebasecamp-ui-split-ratio)
     :busy (etaf-ref nil :name 'ebasecamp-ui-busy)
     :notice (etaf-ref nil :name 'ebasecamp-ui-notice)
     :confirm (etaf-ref nil :name 'ebasecamp-ui-confirm)
     :confirm-action nil)))

(defun ebasecamp-ui-session ()
  "返回当前会话；不存在时创建。
会话在 `ebasecamp-ui-open' 中建立；直接调用本函数便于测试与
`ebasecamp-ui-refresh' 在 buffer 已被外部 kill 后仍可用。"
  (or ebasecamp-ui--session
      (setq ebasecamp-ui--session (ebasecamp-ui--new-session))))

;;; 渲染数据（state）

(defun ebasecamp-ui--running-count (records)
  "返回 RECORDS 中 `:state' 为 running 的条数（大小写不敏感）。纯函数。"
  (cl-loop for record in records
           count (equal "running"
                        (ebasecamp-ui--normalize-state (plist-get record :state)))))

(defun ebasecamp-ui--instance-state (instance)
  "把 `ebasecamp-data-group-instances' 的实例 INSTANCE 转成 state 的段项 plist。
字段：`:config' 配置名（旧写法实例为 nil）、`:project' 项目名、
`:project-title' 项目标题（项目未定义时为 nil）、`:scope' 组 scope（配置的
scope 恒等于组定义，D9）、`:running' running 服务条数、`:total' 服务总条数、
`:records' 服务记录列表、`:legacy' 是否为旧写法（项目侧 `:groups'）实例。
纯函数。"
  (let ((records (plist-get instance :records)))
    (list :config (plist-get instance :config)
          :project (plist-get instance :project)
          :project-title (plist-get instance :project-title)
          :scope (plist-get instance :scope)
          :running (ebasecamp-ui--running-count records)
          :total (length records)
          :legacy (and (plist-get instance :legacy) t)
          :records records)))

(defun ebasecamp-ui--config-state (instance)
  "把段项 INSTANCE 转成 state 的配置项 plist（树的配置节点消费）。
字段：`:name' 配置名、`:project' 项目名、`:project-title' 项目标题、
`:scope'、`:running'、`:total'。纯函数。"
  (list :name (plist-get instance :config)
        :project (plist-get instance :project)
        :project-title (plist-get instance :project-title)
        :scope (plist-get instance :scope)
        :running (plist-get instance :running)
        :total (plist-get instance :total)))

(defun ebasecamp-ui--group-service-names (group)
  "返回组定义里的服务名列表（只用于无配置组的只读展示）。纯函数。"
  (mapcar (lambda (service)
            (format "%s" (ebasecamp-service-name service)))
          (ebasecamp-group-services group)))

(defun ebasecamp-ui--group-state (group)
  "把组对象 GROUP 转成 state 的组项 plist。
字段：`:name' 组名、`:title' 组标题、`:scope' scope、`:config-count' 配置
份数、`:legacy-count' 旧写法（项目侧 `:groups'）实例数、`:running' /
`:total'（各实例求和）、`:configs' 配置项列表（见
`ebasecamp-ui--config-state'）、`:instances' 段项列表（见
`ebasecamp-ui--instance-state'）、`:service-names' 组定义的服务名。
组配置实例经 `ebasecamp-data-group-instances' 每组建装配**一次**，配置项由
**配置实例**派生（旧写法实例没有配置名，不进树），避免重复读状态快照。纯函数。"
  (let* ((instances (mapcar #'ebasecamp-ui--instance-state
                            (ebasecamp-data-group-instances group)))
         (configs (mapcar #'ebasecamp-ui--config-state
                          (cl-remove-if (lambda (instance)
                                          (plist-get instance :legacy))
                                        instances))))
    (list :name (symbol-name (ebasecamp-group-name group))
          :title (ebasecamp-group-title group)
          :scope (symbol-name (ebasecamp-group-scope group))
          :config-count (length configs)
          :legacy-count (- (length instances) (length configs))
          :running (apply #'+ 0 (mapcar (lambda (instance)
                                          (plist-get instance :running))
                                        instances))
          :total (apply #'+ 0 (mapcar (lambda (instance)
                                        (plist-get instance :total))
                                      instances))
          :configs configs
          :instances instances
          :service-names (ebasecamp-ui--group-service-names group))))

(defun ebasecamp-ui--build-state (&optional selected-group)
  "构建整棵树的渲染数据（plist）。纯函数（只读模型注册表与状态快照）。
SELECTED-GROUP 为选中组名（symbol 或 nil），写进 `:selected'（字符串）。
结构：
  (:summary \"3 组 · 5 配置\"
   :groups ((:name \"mysql\" :title \"MySQL\" :scope \"per-project\"
             :config-count 2 :running 3 :total 4
             :configs ((:name \"dev\" :project \"myapp\"
                        :project-title \"示例项目\" :scope \"per-project\"
                        :running 2 :total 2))
             :instances ((:config \"dev\" :project \"myapp\"
                          :project-title \"示例项目\" :scope \"per-project\"
                          :running 2 :total 2 :records (…)))
             :service-names (\"mysql\" \"mysql-ro\"))
            …)
   :selected \"mysql\" :empty-p nil)
组来自 `ebasecamp-model-groups'（**不依赖**项目是否存在）；配置实例来自
`ebasecamp-data-group-instances'；`:running' / `:total' 由实例的 `:records'
逐级汇总（`:state' 为 \"running\" 的条数 / 总条数）。无任何组时 `:empty-p'
为 t，视图显示引导空态。"
  (let* ((groups (mapcar #'ebasecamp-ui--group-state (ebasecamp-model-groups)))
         (configs (apply #'+ 0 (mapcar (lambda (group)
                                         (plist-get group :config-count))
                                       groups))))
    (list :summary (format "%d 组 · %d 配置" (length groups) configs)
          :groups groups
          :selected (and selected-group (symbol-name selected-group))
          :empty-p (null groups))))

;;; 状态与文案映射

(defun ebasecamp-ui--normalize-state (state)
  "把 STATE 归一为小写字符串或 nil（非字符串按 nil 处理）。纯函数。"
  (and (stringp state) (downcase state)))

(defun ebasecamp-ui--state-label (state)
  "把容器状态 STATE 映射为表格文案。
running → RUNNING；exited / stopped / nil → STOPPED；created → CREATED；
paused → PAUSED；其余原样大写。纯函数。"
  (let ((value (ebasecamp-ui--normalize-state state)))
    (pcase value
      ((or 'nil "") "STOPPED")
      ("running" "RUNNING")
      ((or "exited" "stopped") "STOPPED")
      ("created" "CREATED")
      ("paused" "PAUSED")
      (_ (upcase value)))))

(defun ebasecamp-ui--state-variant (state)
  "把容器状态 STATE 映射为 `etaf-badge' 的语义 variant。纯函数。"
  (pcase (ebasecamp-ui--normalize-state state)
    ("running" 'success)
    ("paused" 'warning)
    ("created" 'info)
    (_ 'neutral)))

(defun ebasecamp-ui--health-label (health)
  "把健康状态 HEALTH 映射为表格文案。
nil → \"-\"；healthy → OK；unhealthy → BAD；starting → STARTING；其余大写。
纯函数。"
  (let ((value (ebasecamp-ui--normalize-state health)))
    (pcase value
      ((or 'nil "") "-")
      ("healthy" "OK")
      ("unhealthy" "BAD")
      ("starting" "STARTING")
      (_ (upcase value)))))

(defun ebasecamp-ui--health-variant (health)
  "把健康状态 HEALTH 映射为 `etaf-label' 的语义 variant。纯函数。"
  (pcase (ebasecamp-ui--normalize-state health)
    ("healthy" 'success)
    ("unhealthy" 'danger)
    ("starting" 'warning)
    (_ 'muted)))

(defun ebasecamp-ui--ports-label (record)
  "返回 RECORD 的端口文案：优先 desired-ports，其次实际 ports，都无则 \"-\"。
纯函数。"
  (let ((value (or (plist-get record :desired-ports)
                   (plist-get record :ports))))
    (if (and (stringp value) (not (equal value "")))
        value
      "-")))

;;; 选中状态

(defun ebasecamp-ui--selected-p (session key)
  "KEY 是否在 SESSION 的选中列表里。"
  (and (member key (etaf-value (ebasecamp-ui-session-selected-ref session))) t))

(defun ebasecamp-ui--toggle-selected (session key next)
  "把 KEY 的选中状态设为 NEXT（布尔），返回更新后的选中列表。"
  (let* ((ref (ebasecamp-ui-session-selected-ref session))
         (keys (etaf-value ref))
         (updated (if next
                      (if (member key keys) keys (cons key keys))
                    (delete key (copy-sequence keys)))))
    (etaf-set-value ref updated)))

(defun ebasecamp-ui--select-instance (session group-name instance &optional select)
  "把 INSTANCE 这一段的全部服务加入（SELECT 非 nil）或移出 SESSION 的选中集合。
key 沿用段内身份 \"组名/服务名\"（见 `ebasecamp-ui--instance-key'），数据结构与
`ebasecamp-ui--toggle-selected' 完全一致 —— 都写
`ebasecamp-ui-session-selected-ref' 里的字符串列表，因此段头 checkbox 与段级
`a' / `A' 互相可见，不存在第二套选中表示。
只改 INSTANCE 自己记录对应的 key：其它段、其它组的 key 原样保留（同组多份配置
共享同名服务的 key 是 `--instance-key' 已声明的语义）。返回更新后的选中列表。"
  (let* ((ref (ebasecamp-ui-session-selected-ref session))
         (keys (etaf-value ref))
         (section (mapcar (lambda (record)
                            (ebasecamp-ui--instance-key group-name record))
                          (plist-get instance :records)))
         (updated (if select
                      (append (cl-set-difference section keys :test #'equal)
                              keys)
                    (cl-set-difference keys section :test #'equal))))
    (etaf-set-value ref updated)))

(defun ebasecamp-ui--instance-key (group-name record)
  "返回记录 RECORD 在段内的选中 key，形如 \"组名/服务名\"。
GROUP-NAME 可为 symbol 或字符串，RECORD 为服务记录 plist（见
`ebasecamp-data-group-instances'）。

已定的选择模型（`ebasecamp-ui--section-action' 直接消费）：
- `selected-ref' 存字符串列表，元素形如 \"组名/服务名\"；
- 容器 ID 与项目名**不参与** key，因此容器重启后选中状态仍然稳定；
- 同一组在不同项目实例下若服务同名，key 相同 → 选中状态**跨段共享**。
  这是可接受的第一期语义（段内按钮只按该段自己的项目派发，故不串段）；
  需要按实例区分选中时应把配置名并入 key，但那要等容器标签新增配置维度。

纯函数。"
  (format "%s/%s" group-name (plist-get record :service)))

(defun ebasecamp-ui-selected-keys ()
  "返回当前勾选的服务 key 列表（形如 \"组名/服务名\"）。
会话未建立时返回 nil；批量操作按钮消费本函数。"
  (let ((session ebasecamp-ui--session))
    (and session
         (copy-sequence
          (etaf-value (ebasecamp-ui-session-selected-ref session))))))

;;; 操作提示（notice）

(defconst ebasecamp-ui--blocking-conflict-kinds '(duplicate busy)
  "会阻塞启动的端口冲突类型。
`unknown'（探测不可用）不阻塞，只作为提示写进 notice。")

(defconst ebasecamp-ui--transient-notice-kinds '(success info)
  "会自动清除的 notice 类型；错误类需要用户阅读细节，只能手动关闭。")

(defun ebasecamp-ui--cancel-notice-timer (session)
  "取消 SESSION 的提示自动清除定时器（无定时器时不动），返回 nil。"
  (when session
    (when-let* ((timer (ebasecamp-ui-session-notice-timer session)))
      (cancel-timer timer)
      (setf (ebasecamp-ui-session-notice-timer session) nil)))
  nil)

(defun ebasecamp-ui--clear-notice (session)
  "清空 SESSION 的 notice 及其自动清除定时器，返回 nil。
Dismissible alert 的 `:on-dismiss' 与定时器回调都走本函数。"
  (when session
    (ebasecamp-ui--cancel-notice-timer session)
    (etaf-set-value (ebasecamp-ui-session-notice session) nil))
  nil)

(defun ebasecamp-ui--schedule-notice-clear (session notice)
  "为瞬时类 NOTICE 安排自动清除定时器，返回定时器；不需要时返回 nil。
定时器存进 SESSION，`ebasecamp-ui-close' 与写新 notice 前都会取消它。
回调只在 SESSION 仍是当前会话时清除，避免关闭后操作已销毁的会话。"
  (when (and session
             (memq (plist-get notice :kind) ebasecamp-ui--transient-notice-kinds))
    (let ((timer (run-with-timer
                  ebasecamp-ui-notice-timeout nil
                  (lambda ()
                    (when (eq session ebasecamp-ui--session)
                      (ebasecamp-ui--clear-notice session))))))
      (setf (ebasecamp-ui-session-notice-timer session) timer)
      timer)))

(defun ebasecamp-ui--set-notice (session kind title message &optional detail)
  "把 SESSION 的 notice 写成 KIND + TITLE + MESSAGE + DETAIL，返回 nil。
KIND 为 error / warning / success / info；成功与信息类通知会在
`ebasecamp-ui-notice-timeout' 秒后自动清除（定时器存进会话）。"
  (when session
    (ebasecamp-ui--cancel-notice-timer session)
    (let ((notice (list :kind kind :title title :message message :detail detail)))
      (etaf-set-value (ebasecamp-ui-session-notice session) notice)
      (ebasecamp-ui--schedule-notice-clear session notice)))
  nil)

(defun ebasecamp-ui--notice (session)
  "返回 SESSION 的 notice 值（nil 或 plist），读 ref 以建立渲染依赖。"
  (and session (etaf-value (ebasecamp-ui-session-notice session))))

(defun ebasecamp-ui--notice-body (notice)
  "返回 NOTICE 的正文：MESSAGE，DETAIL 非空时以换行追加。纯函数。"
  (let ((message (or (plist-get notice :message) ""))
        (detail (plist-get notice :detail)))
    (if (and (stringp detail) (not (string-empty-p detail)))
        (format "%s\n%s" message detail)
      message)))

(defun ebasecamp-ui--kind-variant (kind)
  "把 notice 的 KIND 映射为 `etaf-alert' 的 `:variant'（error → danger）。纯函数。"
  (pcase kind
    ('error 'danger)
    ('warning 'warning)
    ('success 'success)
    (_ 'info)))

(defun ebasecamp-ui--notice-view (session)
  "返回界面底部提示区的提示视图。
无 notice 时给默认的操作提示 label；有 notice 时渲染 `etaf-alert'
（`:dismissible' 的关闭按钮清空 notice，`:detail' 以换行拼进 message）。"
  (let ((notice (ebasecamp-ui--notice session)))
    (if (null notice)
        (etaf-view (etaf-label :text ebasecamp-ui--hint :variant 'muted))
      (etaf-view
       (etaf-alert
        :title (or (plist-get notice :title) "")
        :message (ebasecamp-ui--notice-body notice)
        :variant (ebasecamp-ui--kind-variant (plist-get notice :kind))
        :dismissible t
        :on-dismiss (lambda () (ebasecamp-ui--clear-notice session)))))))

;;; 动作名与端口冲突汇总

(defun ebasecamp-ui--action-label (action)
  "返回动作 ACTION 的中文短名（用于 notice 文案）。纯函数。"
  (pcase action
    ('start "启动")
    ('stop "停止")
    ('restart "重启")
    ('down "销毁")
    (_ (format "%s" action))))

(defun ebasecamp-ui--conflict-summary (conflicts)
  "把冲突列表 CONFLICTS 汇总为一行中文文案。纯函数。"
  (mapconcat
   (lambda (conflict)
     (let ((kind (plist-get conflict :kind))
           (port (plist-get conflict :port)))
       (pcase kind
         ('duplicate
          (format "端口 %s 在 %s 之间重复" port
                  (mapconcat #'identity
                             (plist-get conflict :services) "、")))
         ('busy
          (format "端口 %s 已被占用（%s）" port (plist-get conflict :service)))
         (_
          (format "端口 %s 探测不可用，已跳过（%s）"
                  port (plist-get conflict :service))))))
   conflicts "；"))

(defun ebasecamp-ui--split-conflicts (conflicts)
  "把冲突列表 CONFLICTS 拆成 (BLOCKING . SOFT) 两簇。
BLOCKING 是 `ebasecamp-ui--blocking-conflict-kinds' 中的类型（必须拒绝启动），
SOFT 是其余（如 `unknown'，只提示）。纯函数。"
  (let ((blocking nil)
        (soft nil))
    (dolist (conflict conflicts)
      (if (memq (plist-get conflict :kind) ebasecamp-ui--blocking-conflict-kinds)
          (setq blocking (append blocking (list conflict)))
        (setq soft (append soft (list conflict)))))
    (cons blocking soft)))

;;; 树项 / 列

(defun ebasecamp-ui--ratio-label (running total)
  "返回 \"运行/总数\" 文案（如 \"2/2\"）。纯函数。"
  (format "%d/%d" running total))

(defun ebasecamp-ui--group-label (group)
  "返回组项的标题文案（标题缺失时回退组名）。纯函数。"
  (or (plist-get group :title) (plist-get group :name)))

(defun ebasecamp-ui--group-caption (group)
  "返回组项的显示文案：标题 + 配置份数 + running 汇总。
有配置时如 \"MySQL  (2 配置 · 3/4 running)\"（无服务时省略 running 部分，
如 \"MySQL  (2 配置)\"）；组无配置但有旧写法（项目侧 `:groups'）关联时如
\"MySQL  (旧 · 1 项目)\"（用「旧」而非「旧写法」：左栏占比有限，实测更长的
文案会把尾部「· N 项目」截掉）；既无配置也无关联时如 \"MySQL  (未关联)\"。
GROUP 为 state 的组项 plist。纯函数。"
  (let ((title (ebasecamp-ui--group-label group))
        (config-count (or (plist-get group :config-count) 0))
        (legacy-count (or (plist-get group :legacy-count) 0))
        (total (or (plist-get group :total) 0)))
    (cond
     ((> config-count 0)
      (let ((head (format "%s  (%d 配置" title config-count)))
        (if (> total 0)
            (format "%s · %s running)"
                    head
                    (ebasecamp-ui--ratio-label
                     (or (plist-get group :running) 0) total))
          (concat head ")"))))
     ((> legacy-count 0)
      (format "%s  (旧 · %d 项目)" title legacy-count))
     (t
      (format "%s  (未关联)" title)))))

(defun ebasecamp-ui--config-caption (config)
  "返回配置项的显示文案：配置名 → 项目 + running 计数。
如 \"dev → 示例项目  (2/2)\"；项目标题缺失时回退项目名，无服务时省略计数。
CONFIG 为 state 的配置项 plist。纯函数。"
  (let* ((target (or (plist-get config :project-title)
                     (plist-get config :project)
                     ""))
         (total (or (plist-get config :total) 0)))
    (if (> total 0)
        (format "%s → %s  (%s)"
                (plist-get config :name) target
                (ebasecamp-ui--ratio-label
                 (or (plist-get config :running) 0) total))
      (format "%s → %s" (plist-get config :name) target))))

(defun ebasecamp-ui--group-key (group-name)
  "返回组节点的树 key（字符串 \"group/组名\"）。
`etaf-tree' 要求全局唯一的**标量** key，因此组与配置用不同前缀区分。纯函数。"
  (format "group/%s" group-name))

(defun ebasecamp-ui--config-key (group-name config-name)
  "返回配置节点的树 key（字符串 \"config/组名/配置名\"）。纯函数。"
  (format "config/%s/%s" group-name config-name))

(defun ebasecamp-ui--tree-key-group (key)
  "把树 key KEY（\"group/GROUP\" 或 \"config/GROUP/CONFIG\"）归一为组名 symbol。
无法判定时返回 nil。纯函数。"
  (when (and (stringp key) (string-match-p "/" key))
    (let ((name (nth 1 (split-string key "/"))))
      (and name (not (string-empty-p name)) (intern name)))))

(defun ebasecamp-ui--tree-items (state)
  "把渲染数据 STATE 转成 `etaf-tree' 的 `:items'（组 → 配置 两级）。
组项带 `:children'（该组的全部配置），配置是叶子。组名全来自清单，因此
没有项目时也能列出。纯函数。"
  (mapcar
   (lambda (group)
     (let ((group-name (plist-get group :name)))
       (list :key (ebasecamp-ui--group-key group-name)
             :label (ebasecamp-ui--group-caption group)
             :children
             (mapcar (lambda (config)
                       (list :key (ebasecamp-ui--config-key
                                   group-name
                                   (plist-get config :name))
                             :label (ebasecamp-ui--config-caption config)))
                     (plist-get group :configs)))))
   (plist-get state :groups)))

(defconst ebasecamp-ui--checkbox-ref-prefix "ebasecamp-ui-check-"
  "服务行 checkbox 的 ref 前缀。
`--select-cell' 用它生成 ref，`--checkbox-ref-at-point' 用它识别 ref。
与既有 ref（`ebasecamp-ui-refresh' / `ebasecamp-ui-selected' /
`ebasecamp-ui-state' / `ebasecamp-ui-expanded' / `ebasecamp-ui-busy' /
`ebasecamp-ui-notice' / `ebasecamp-ui-confirm'）不冲突。")

(defun ebasecamp-ui--checkbox-ref (key)
  "返回选中 key（\"组名/服务名\"）对应的 checkbox ref 符号。纯函数。
同组多份配置共享同一个 key（见 `ebasecamp-ui--instance-key'），因此 ref 也
共享 —— 与既有选中语义一致：两段里的同名服务行勾选状态本就联动。"
  (intern (format "%s%s" ebasecamp-ui--checkbox-ref-prefix key)))

(defconst ebasecamp-ui--row-ref-prefix "ebasecamp-ui-row-"
  "服务表整行 ref 的前缀。
`--service-table' 用它生成行 ref，`--ref-at-point' 用它识别「point 落在行内任意
单元格」的情形。行 ref 与 checkbox ref（`--checkbox-ref-prefix'）由同一个 key
派生，因此从行 ref 可还原出该行的 checkbox ref —— 行级切换键 `t' 据此派发。")

(defun ebasecamp-ui--row-ref (key)
  "返回选中 key（\"组名/服务名\"）对应的行 ref 符号。纯函数。
与 `--checkbox-ref' 同源（同一 key），两者只差前缀。"
  (intern (format "%s%s" ebasecamp-ui--row-ref-prefix key)))

(defun ebasecamp-ui--select-cell (session group-name record)
  "选中列的单元格：checkbox 写回 SESSION 的选中列表。
key 为段内身份 \"组名/服务名\"（见 `ebasecamp-ui--instance-key'），同时用作
checkbox 的稳定 `:ref'（见 `ebasecamp-ui--checkbox-ref'）：ref 由 key 派生，
重渲染/刷新后身份不变，因此不需要额外的「ref → 动作」登记表。"
  (let* ((key (ebasecamp-ui--instance-key group-name record))
         (ref (ebasecamp-ui--checkbox-ref key)))
    (etaf-view
     (etaf-checkbox
      :ref ref
      :checked (ebasecamp-ui--selected-p session key)
      :on-change (lambda (next)
                   (ebasecamp-ui--toggle-selected session key next))))))

(defun ebasecamp-ui--ref-at-point (&rest prefixes)
  "返回 point 所在节点向上最近、名字以 PREFIXES 之一开头的显式 ref 符号。
找不到返回 nil。实现要点（探针实测）：
- point 落在 mark / label 文本内部时，最近的 Host 是它自己的生成 ref
  （`(etaf-host MOUNT-ID ID)'），取不到显式 ref，因此要沿 `ebox-node-parent'
  逐级向上再试（`etaf-runtime-node-host-ref' 每次跳到最近的已注册 Host）；
- 返回类型可能是生成 ref（list），只有前缀匹配的**符号**才算命中。"
  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
         (node (and runtime (ignore-errors (ebox-node-at (point)))))
         found)
    (while (and runtime node (not found))
      (let ((ref (etaf-runtime-node-host-ref runtime node)))
        (if (and (symbolp ref)
                 (cl-some (lambda (prefix)
                            (string-prefix-p prefix (symbol-name ref)))
                          prefixes))
            (setq found ref)
          (setq node (ebox-node-parent node)))))
    found))

(defun ebasecamp-ui--checkbox-ref-at-point ()
  "返回 point 所在节点向上最近的服务行 checkbox ref（见 `--select-cell'）。
找不到返回 nil。只查 checkbox 前缀，是 `--ref-at-point' 的薄封装：行级切换键
`t' 用通用版本（同时识别行 ref，见 `--toggle-at-point'），测试与探针用它断言
checkbox ref 的稳定性（见 `checkbox-refs-are-stable'）。"
  (ebasecamp-ui--ref-at-point ebasecamp-ui--checkbox-ref-prefix))

(defun ebasecamp-ui--toggle-row (session group-name record)
  "切换 RECORD 这一行的勾选状态，返回 nil。
`etaf-table' 的 `:on-row-press' 入口（鼠标点击行、焦点在行上按 `RET'）：
与行级键 `t'（`--toggle-at-point'）写同一个 `--toggle-selected'，不存在第二套
选中表示。"
  (let ((key (ebasecamp-ui--instance-key group-name record)))
    (ebasecamp-ui--toggle-selected
     session key (not (ebasecamp-ui--selected-p session key)))))

(defun ebasecamp-ui--toggle-at-point ()
  "切换 point 所在服务行的勾选状态，返回 nil。绑在根级键 `t' 上。
point 落在行内任意单元格（命中行 ref）或 checkbox 上（命中 checkbox ref）都生效：
行 ref 先还原出同一行的 checkbox ref，确认该 checkbox 在本 buffer 里已渲染后派发
`press'，事件落在 checkbox 的 `:on-change' 上。
point 不在任何服务行上时**静默** no-op（不写 notice）：Tab / 误按时不应刷出提示。

派发方式刻意不用 `etaf-activate'：U4 步骤 0 探针实测它按的是**焦点**宿主
（无焦点时按 point 处节点的 `RET' 绑定），而界面里段内「启动选中 / 停止选中 /
重启选中」按钮就在同一 buffer —— 用 activate 会把误触直接变成起停容器。
`SPC' 不能用作行级切换键：`[32]' 属 `ebox--activation-keys'，节点级
char-property keymap 先于 etaf 键层，写进 `:keys' 也永远收不到该事件（它仍是 ebox
的「激活当前控件」语义，见 `spc-activates-checkbox'）。"
  (interactive)
  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
         (ref (and runtime
                   (ebasecamp-ui--ref-at-point
                    ebasecamp-ui--checkbox-ref-prefix
                    ebasecamp-ui--row-ref-prefix))))
    (when ref
      (let* ((name (symbol-name ref))
             (check-ref
              (if (string-prefix-p ebasecamp-ui--checkbox-ref-prefix name)
                  ref
                (ebasecamp-ui--checkbox-ref
                 (substring name (length ebasecamp-ui--row-ref-prefix))))))
        ;; 只派发已渲染的 checkbox：ref 由 key 派生，未渲染的 ref 没有 handler，
        ;; `etaf-dispatch-event' 会 signal。
        (when (etaf-runtime-host-node runtime check-ref)
          (etaf-dispatch-event runtime check-ref 'press)))))
  nil)

(defun ebasecamp-ui--state-cell (record)
  "状态列的单元格：semantic badge 呈现状态文案。"
  (let ((state (plist-get record :state)))
    (etaf-view
     (etaf-badge :text (ebasecamp-ui--state-label state)
                 :variant (ebasecamp-ui--state-variant state)))))

(defun ebasecamp-ui--ports-cell (record)
  "端口列的单元格：期望端口优先，其次实际端口。"
  (etaf-view (etaf-label :text (ebasecamp-ui--ports-label record))))

(defun ebasecamp-ui--health-cell (record)
  "健康列的单元格：语义 label 呈现健康文案。"
  (let ((health (plist-get record :health)))
    (etaf-view
     (etaf-label :text (ebasecamp-ui--health-label health)
                 :variant (ebasecamp-ui--health-variant health)))))

(defun ebasecamp-ui--columns (session group-name)
  "返回服务表的列定义（第一列为选中 checkbox）。
GROUP-NAME 为组名（段内 key 的组部分）。列 `:key' 用关键字，与记录 plist
的键一致，无 `:cell' 的列可直接取值。
镜像与端口用 `(fr 2)' 抢占剩余宽度（80 列终端下右栏只有约 48 列，定宽相加会
把「健康」列挤出可视区），其余列用字符宽度容量。"
  (list (list :key :select :label "" :width 3
              :cell (lambda (record)
                      (ebasecamp-ui--select-cell session group-name record)))
        (list :key :service :label "服务" :width 9)
        (list :key :image :label "镜像" :width '(fr 2))
        (list :key :state :label "状态" :width 8
              :cell #'ebasecamp-ui--state-cell)
        (list :key :ports :label "端口" :width '(fr 2)
              :cell #'ebasecamp-ui--ports-cell)
        (list :key :health :label "健康" :width 5
              :cell #'ebasecamp-ui--health-cell)))

;;; 动作派发与并发控制

(defun ebasecamp-ui--failed-branch (results)
  "从批次结果 RESULTS 里返回第一个失败分支，无则返回 nil。
失败判定：`:failed' 为真，或 `:exit' 为数字且非 0。纯函数。"
  (cl-find-if (lambda (entry)
                (let ((exit (plist-get entry :exit)))
                  (or (plist-get entry :failed)
                      (and (numberp exit) (/= exit 0)))))
              results))

(defun ebasecamp-ui--first-line (text)
  "返回 TEXT 的第一个非空行（去掉首尾空白）；无内容时返回 nil。纯函数。"
  (when (stringp text)
    (cl-find-if (lambda (line) (not (string-empty-p line)))
                (mapcar #'string-trim (split-string text "\n")))))

(defun ebasecamp-ui--report-result (session label result)
  "把批次结果 RESULT 写成 SESSION 的 notice，LABEL 为动作中文名。返回 nil。
成功 → 绿色完成提示（`:auto-started-shared' 为真时额外说明；
`:preflight-warnings' 非空时在 detail 末尾追加「（N 条预校验警告）」——
预校验警告不改变成功与否，只是一条「有东西没能校验」的提示）；
失败 → 从 `:results' 取失败分支的 stderr：含 permission denied 时给 docker
组提示，否则把 stderr 首行作为 message、原文作为 detail；无 stderr（例如
批次被跳过）时说明「未完成」。"
  (if (plist-get result :ok)
      (let ((warnings (plist-get result :preflight-warnings)))
        (ebasecamp-ui--set-notice
         session 'success (format "%s完成" label)
         (concat (if (plist-get result :auto-started-shared)
                     "所有批次已执行完成；已自动启动 shared 服务"
                   "所有批次已执行完成")
                 (if warnings
                     (format "（%d 条预校验警告）" (length warnings))
                   ""))))
    (let* ((failed (ebasecamp-ui--failed-branch (plist-get result :results)))
           (stderr (or (and failed (plist-get failed :stderr)) ""))
           (first (ebasecamp-ui--first-line stderr)))
      (cond
       ((string-match-p "permission denied" (downcase stderr))
        (ebasecamp-ui--set-notice
         session 'error "无权访问 Docker"
         "请将当前用户加入 docker 组并重新登录，或检查 /var/run/docker.sock 权限"
         stderr))
       (first
        (ebasecamp-ui--set-notice session 'error (format "%s失败" label)
                                  first stderr))
       (t
        (ebasecamp-ui--set-notice
         session 'error (format "%s未完成" label)
         "部分批次被跳过（没有可展示的错误输出），请查看命令行输出")))))
  nil)

(defun ebasecamp-ui--on-complete (session action)
  "构造 `ebasecamp-command-run' 的完成回调。
回调里清 SESSION 的 busy、刷新数据，并按 RESULT 的 `:ok' / `:results' /
`:auto-started-shared' 写成功或失败的 notice（失败时带 stderr 原文 detail）。"
  (let ((label (ebasecamp-ui--action-label action)))
    (lambda (result)
      (etaf-set-value (ebasecamp-ui-session-busy session) nil)
      (ebasecamp-ui-refresh)
      (ebasecamp-ui--report-result session label result)
      nil)))

(defun ebasecamp-ui--dispatch (session action project keys)
  "把生命周期动作 ACTION（PROJECT + KEYS）派发到命令层，返回 t 或 nil。
**唯一的派发路径**：段内生命周期按钮（`ebasecamp-ui--section-action'）与销毁
确认（`ebasecamp-ui-confirm'）都走本函数，没有第二条派发路径。
派发前置 busy；命令层 signal 时按类型映射 notice 并复位 busy（绝不让界面卡在
「执行中」）：
- `ebasecamp-command-busy'（同项目已有命令在执行）→ info「操作进行中」；
- 其他 error（含 `ebasecamp-command-error'）→ error「命令派发失败」+ 消息。
返回 t 表示已派发，nil 表示被拒。"
  (etaf-set-value (ebasecamp-ui-session-busy session) t)
  (condition-case err
      (progn
        (ebasecamp-command-run
         action project keys
         :on-complete (ebasecamp-ui--on-complete session action))
        t)
    (ebasecamp-command-busy
     (etaf-set-value (ebasecamp-ui-session-busy session) nil)
     (ebasecamp-ui--set-notice session 'info "操作进行中" "请等待当前命令完成")
     nil)
    ((error quit)
     (etaf-set-value (ebasecamp-ui-session-busy session) nil)
     (ebasecamp-ui--set-notice session 'error "命令派发失败"
                               (error-message-string err))
     nil)))

(defun ebasecamp-ui-confirm ()
  "执行确认框里待确认的动作，返回 t（已派发）或 nil。
待确认动作（会话的 `confirm-action'）形如 `(down . 项目名)'，由
`ebasecamp-ui-destroy-environment' 设置；确认后先清空确认状态（避免重复
派发），再按「全部服务」（keys 为 nil）经 `ebasecamp-ui--dispatch' 派发。
交互入口：确认框的「确认销毁」按钮与 `M-x'。"
  (interactive)
  (let* ((session ebasecamp-ui--session)
         (pending (and session (ebasecamp-ui-session-confirm-action session))))
    (when session
      (etaf-set-value (ebasecamp-ui-session-confirm session) nil)
      (setf (ebasecamp-ui-session-confirm-action session) nil))
    (if (and session pending)
        (ebasecamp-ui--dispatch session (car pending) (cdr pending) nil)
      nil)))

(defun ebasecamp-ui-dismiss-confirm ()
  "关闭确认框并丢弃待确认动作，返回 nil。"
  (interactive)
  (let ((session ebasecamp-ui--session))
    (when session
      (etaf-set-value (ebasecamp-ui-session-confirm session) nil)
      (setf (ebasecamp-ui-session-confirm-action session) nil)))
  nil)

;;; 底栏与销毁确认视图

;; 底栏是主视图 column 的最后一个内容行（分割线之后、notice 之前）：导入
;; compose / 导出 compose / 销毁环境三个 ghost 按钮。三者都不是生命周期动作，
;; 故**不参与** busy 判定（busy 期间仍可点）；销毁的危险性由二次确认
;; （`ebasecamp-ui-confirm-dialog'）承担。

(defun ebasecamp-ui--footer-button (label function)
  "返回底栏按钮：文案 LABEL，按下调用 FUNCTION。纯视图，不参与 busy 判定。"
  (etaf-view
   (etaf-button
    :label label
    :variant 'ghost
    :on-press (lambda () (funcall function)))))

(defun ebasecamp-ui--footer-view ()
  "返回主界面底栏：导入 compose / 导出 compose / 销毁环境。"
  (etaf-view
   (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
     (expr (ebasecamp-ui--footer-button
            "导入 compose" #'ebasecamp-ui-import-compose))
     (expr (ebasecamp-ui--footer-button
            "导出 compose" #'ebasecamp-ui-export-compose))
     (expr (ebasecamp-ui--footer-button
            "销毁环境" #'ebasecamp-ui-destroy-environment)))))

(defun ebasecamp-ui--confirm-message (project)
  "返回销毁 PROJECT 的确认文案：点名项目、不删卷、shared 组不受影响。纯函数。"
  (format (concat "将停止并移除项目 %s 的全部 per-project 容器，"
                  "不会删除卷。shared 组不受影响。")
          (or project "（未选择）")))

(etaf-define-component ebasecamp-ui-confirm-dialog ()
  "销毁环境的二次确认框：会话 `confirm' ref 为真时弹出。
`:render' 里读 `confirm' ref，因此打开 / 关闭都会让本组件重建——文案得以在
打开的那一刻按 `confirm-action' 的 `(动作 . 项目名)' 求值（若写成普通视图
函数，文案会在父组件上一次渲染时就固定下来）。"
  :render
  (let* ((session (ebasecamp-ui-session))
         (open (etaf-value (ebasecamp-ui-session-confirm session)))
         (pending (and open (ebasecamp-ui-session-confirm-action session))))
    (when pending
      (etaf-view
       (etaf-dialog
        :open (ebasecamp-ui-session-confirm session)
        :title "销毁环境"
        :width '(ch 56)
        :close-label nil
        :on-close (lambda () (ebasecamp-ui-dismiss-confirm))
        (column :width 'stretch :item-gap '(lh 1)
          (etaf-label :text (ebasecamp-ui--confirm-message (cdr pending)))
          (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
            (etaf-button :label "取消" :variant 'secondary
                         :on-press (lambda () (ebasecamp-ui-dismiss-confirm)))
            (etaf-button :label "确认销毁" :variant 'primary
                         :on-press (lambda () (ebasecamp-ui-confirm))))))))))

;;; 交互与视图（组为中心的骨架）

(defun ebasecamp-ui--select-key (session key)
  "把树节点的选择写进 SESSION：KEY 归一为所属组名，同时重建 state。
配置节点的 key 是 \"config/组名/配置名\"，选中配置等同于选中它所属的组；
服务勾选由段内服务表的 checkbox 维护（key 见 `ebasecamp-ui--instance-key'）。"
  (let ((group (ebasecamp-ui--tree-key-group key)))
    (etaf-set-value (ebasecamp-ui-session-selected-group session) group)
    (etaf-set-value (ebasecamp-ui-session-state session)
                    (ebasecamp-ui--build-state group))))

(defun ebasecamp-ui--tree-view (session)
  "返回左侧组树（组 → 配置 两级）。
`:items' 取自会话的 state（渲染期读取，state 改写即重建树）；
`:expanded' 绑会话的 expanded ref，`:on-toggle' 把新的 key 列表写回同一
ref（展开状态由会话持有，重渲染后保持）；`:on-select' 写 selected-group。"
  (etaf-view
   (etaf-tree
    :items (ebasecamp-ui--tree-items
            (etaf-value (ebasecamp-ui-session-state session)))
    :expanded (ebasecamp-ui-session-expanded session)
    :on-toggle (lambda (next)
                 (etaf-set-value (ebasecamp-ui-session-expanded session) next))
    :on-select (lambda (key) (ebasecamp-ui--select-key session key)))))

;;; 右栏段渲染与段内派发

;; 右栏是「选中组 → 每份配置一个 `etaf-panel' 段」的视图。段头含
;; 配置名 → 项目、scope 徽标、running/total 徽标与三个生命周期按钮；
;; 段体是服务表（首列 checkbox，选中状态写进会话的 selected-ref）。
;; 段内按钮的派发走 `ebasecamp-ui--section-action'：把该段**自己的**
;; `:project' 与当前选中集合交给命令层，因此同组多个实例不会串段。
;; `:disabled' 由渲染期的 busy 值决定。

(defun ebasecamp-ui--busy-p (session)
  "SESSION 的 busy ref 当前是否为真（渲染期读取以建立渲染依赖）。"
  (and (etaf-value (ebasecamp-ui-session-busy session)) t))

(defun ebasecamp-ui--scope-badge (scope)
  "返回 scope 徽标：per-project → info，shared → warning，其余 neutral。
SCOPE 为 scope 字符串（如 \"per-project\"）。"
  (etaf-view
   (etaf-badge :text (or scope "")
               :variant (pcase scope
                          ("per-project" 'info)
                          ("shared" 'warning)
                          (_ 'neutral)))))

(defun ebasecamp-ui--ratio-variant (running total)
  "返回 running/total 徽标的语义 variant。纯函数。
无服务（TOTAL 为 0）或全部未运行（RUNNING 为 0）→ neutral；
全部运行 → success；其余 → warning。"
  (let ((running (or running 0))
        (total (or total 0)))
    (cond ((zerop total) 'neutral)
          ((zerop running) 'neutral)
          ((= running total) 'success)
          (t 'warning))))

(defun ebasecamp-ui--instance-caption (instance)
  "返回段头文案：配置名 → 项目标题（如 \"dev → 示例项目\"）。
项目标题缺失时回退项目名。旧写法（项目侧 `:groups'）实例没有配置名，段头为
\"（旧写法）→ 示例项目\"，以区别于已声明 `:configs' 的配置。"
  (let ((target (or (plist-get instance :project-title)
                    (plist-get instance :project)
                    "")))
    (if (plist-get instance :legacy)
        (format "（旧写法）→ %s" target)
      (format "%s → %s" (or (plist-get instance :config) "") target))))

(defun ebasecamp-ui--section-action (action instance)
  "对配置实例 INSTANCE 派发生命周期 ACTION。
实例含 :config / :project / :records；keys 取会话选中集合（段内唯一：右栏只显示
当前选中组的实例，故 \"组名/服务名\" 形式的 key 对该段全部有效）。
判定顺序（任一命中即返回 nil 并写 notice，不派发）：
1. 会话 busy → info「操作进行中」；
2. 实例的 `:project' 为空 → info「该项目未定义」；
3. 选中集合为空 → info「未选中服务」；
4. ACTION 为 start 时先做端口冲突检测：`duplicate' / `busy' 阻塞（error
   「端口冲突」），`unknown' 只提示（info「端口提示」）后继续；
5. 派发 `ebasecamp-command-run'：前置 busy=t，命令层 signal 时复位 busy 并写
   error「命令派发失败」。成功返回 t。
完成回调沿用 `ebasecamp-ui--on-complete'（复位 busy → 刷新 → 报告结果）。"
  (let* ((session (ebasecamp-ui-session))
         (project (plist-get instance :project))
         (keys (ebasecamp-ui-selected-keys)))
    (cond
     ((ebasecamp-ui--busy-p session)
      (ebasecamp-ui--set-notice session 'info "操作进行中" "请等待当前命令完成")
      nil)
     ((or (null project) (and (stringp project) (string-empty-p project)))
      (ebasecamp-ui--set-notice session 'info "该项目未定义"
                                "这段配置指向的项目不在清单里，请先定义该项目")
      nil)
     ((null keys)
      (ebasecamp-ui--set-notice session 'info "未选中服务"
                                "请先勾选要操作的服务")
      nil)
     ((not (eq action 'start))
      (ebasecamp-ui--dispatch session action project keys))
     (t
      (let* ((conflicts (ebasecamp-command-port-conflicts project keys))
             (split (ebasecamp-ui--split-conflicts conflicts))
             (blocking (car split))
             (soft (cdr split)))
        (if blocking
            (progn
              (ebasecamp-ui--set-notice
               session 'error "端口冲突"
               (ebasecamp-ui--conflict-summary blocking))
              nil)
          (when soft
            (ebasecamp-ui--set-notice
             session 'info "端口提示"
             (ebasecamp-ui--conflict-summary soft)))
          (ebasecamp-ui--dispatch session action project keys)))))))

(defun ebasecamp-ui--section-button (label action variant instance disabled)
  "返回段内生命周期按钮：文案 LABEL、语义 VARIANT，按下对 INSTANCE 派发 ACTION。
INSTANCE 为 state 的段项 plist（`:config' / `:project' / `:records'）—— 按钮
只绑定该段自己的项目。
DISABLED 为真时禁用 —— `etaf-button' 的 `:disabled' 只接受布尔值，调用方
必须在渲染期从 busy ref 取当前值传入（不能传 ref 对象）。"
  (etaf-view
   (etaf-button
    :label label
    :variant variant
    :disabled (and disabled t)
    :on-press (lambda () (ebasecamp-ui--section-action action instance)))))

(defun ebasecamp-ui--instance-header (instance disabled)
  "返回段头：第一行 = 配置 → 项目（strong）+ scope 徽标 + running/total 徽标，
第二行 = 启动 / 停止 / 重启按钮（DISABLED 为真时三个按钮全部禁用）。
两行而不是一行：80 列终端下段头单行会超出右栏宽度，尾部按钮被裁切。"
  (let ((running (or (plist-get instance :running) 0))
        (total (or (plist-get instance :total) 0)))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0)
       (row :width 'stretch :cross-align 'center :item-gap '(ch 1)
         (etaf-label :text (ebasecamp-ui--instance-caption instance)
                     :variant 'strong)
         (expr (ebasecamp-ui--scope-badge (plist-get instance :scope)))
         (etaf-badge :text (ebasecamp-ui--ratio-label running total)
                     :variant (ebasecamp-ui--ratio-variant running total)))
       (row :width 'stretch :cross-align 'center :item-gap '(ch 1)
         (expr (ebasecamp-ui--section-button
                "启动选中" 'start 'primary instance disabled))
         (expr (ebasecamp-ui--section-button
                "停止选中" 'stop 'secondary instance disabled))
         (expr (ebasecamp-ui--section-button
                "重启选中" 'restart 'secondary instance disabled)))))))

(defun ebasecamp-ui--service-table (session group-name instance)
  "返回段的服务表：列见 `ebasecamp-ui--columns'，行为实例的 `:records'。
`:row-key' / `:row-ref' 都用段内身份 \"组名/服务名\"（段内唯一）。
`:on-row-press' 必须给：`etaf-table' 只在「行可交互」时采用调用方提供的
`:row-ref'（`etaf-ui--table-row-node' 的 `interactive-p' 分支），否则行 Host 退回
实例内生成 ref，行级切换键 `t' 就取不到行身份；它同时让行可聚焦（`:tab-index 0'）。
行被按下（鼠标点击、焦点在行上按 `RET'）即切换该行勾选，与 `t' 同语义。"
  (etaf-view
   (etaf-table
    :columns (ebasecamp-ui--columns session group-name)
    :rows (plist-get instance :records)
    :row-key (lambda (record)
               (ebasecamp-ui--instance-key group-name record))
    :row-ref (lambda (record)
               (ebasecamp-ui--row-ref
                (ebasecamp-ui--instance-key group-name record)))
    :on-row-press (lambda (record)
                    (ebasecamp-ui--toggle-row session group-name record)))))

(defun ebasecamp-ui--section-keys (group-name instance)
  "返回配置段（GROUP-NAME + INSTANCE）的 `:keys' 列表，每条 (KEY COMMAND LABEL)。
这是**段级键位的单一事实源**：`ebasecamp-ui--instance-section' 的段 Host 直接
消费它，测试也断言它的键集合，避免「渲染里绑了但帮助/测试里没有」。

语义（与段头按钮同源）：
- `s' / `x' / `r' → `ebasecamp-ui--section-action' 传 `start' / `stop' /
  `restart'，捕获**该段自己的** INSTANCE（不引入「当前段」全局状态，同组多实例
  不会串段）；
- `a' / `A' → `ebasecamp-ui--select-instance' 全选 / 全不选**该段**服务。

COMMAND 必须是**无参** command：`etaf--keys-run' 对 commandp 用
`call-interactively'，所以闭包必须带 `(interactive)'。
每条的 LABEL 不能省 —— `etaf-help' 会跳过没有 LABEL 的条目。"
  (let ((session (ebasecamp-ui-session)))
    (list (list "s" (lambda () (interactive)
                      (ebasecamp-ui--section-action 'start instance))
                "启动该段选中")
          (list "x" (lambda () (interactive)
                      (ebasecamp-ui--section-action 'stop instance))
                "停止该段选中")
          (list "r" (lambda () (interactive)
                      (ebasecamp-ui--section-action 'restart instance))
                "重启该段选中")
          (list "a" (lambda () (interactive)
                      (ebasecamp-ui--select-instance
                       session group-name instance t))
                "全选该段服务")
          (list "A" (lambda () (interactive)
                      (ebasecamp-ui--select-instance
                       session group-name instance nil))
                "全不选该段服务"))))

(defun ebasecamp-ui--instance-section (session group-name instance)
  "返回一份配置的段：`etaf-panel'（bordered）包在带 `:keys' 的 `box' Host 里。
段 Host 声明段级键（见 `ebasecamp-ui--section-keys'）：etaf 键链从 point/焦点
所在 Host 向上找，因此只有 point 落在本段内时 `s' / `x' / `r' / `a' / `A' 才
命中；段外按键被根 Host 的 `:key-scope`（值 local）边界吞掉。
header 槽为段头行（见 `ebasecamp-ui--instance-header'，busy 在渲染期取值）；
default 槽为分隔线 + 服务表（见 `ebasecamp-ui--service-table'）。"
  (etaf-view
   (box :width 'stretch
        :keys (ebasecamp-ui--section-keys group-name instance)
     (etaf-panel :variant 'bordered :width 'stretch
       (slot :name 'header
         (expr (ebasecamp-ui--instance-header
                instance (ebasecamp-ui--busy-p session))))
       (etaf-divider)
       (expr (ebasecamp-ui--service-table session group-name instance))))))

(defun ebasecamp-ui--group-header-row (group)
  "返回右栏顶部的组标题行：组标题 + scope 徽标 + \"N 配置\"。
GROUP 为 state 的组项 plist。"
  (etaf-view
   (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
     (etaf-label :text (ebasecamp-ui--group-label group) :variant 'strong)
     (expr (ebasecamp-ui--scope-badge (plist-get group :scope)))
     (etaf-label :text (format "%d 配置" (plist-get group :config-count))
                 :variant 'muted))))

(defun ebasecamp-ui--legacy-instances (group)
  "返回组项 GROUP 中旧写法（项目侧 `:groups'）实例的列表。纯函数。"
  (cl-remove-if-not (lambda (instance) (plist-get instance :legacy))
                    (plist-get group :instances)))

(defconst ebasecamp-ui--legacy-hint
  (concat "提示：该组尚未声明 :configs（当前关联来自项目侧 :groups 旧写法），"
          "建议改为 :configs ((<配置名> :project <项目>))")
  "组只有旧写法关联时给出的迁移提示文案。")

(defun ebasecamp-ui--legacy-hint-view (group)
  "返回组的迁移提示视图；组无旧写法实例时返回 nil。
只在组**没有** `:configs'、关联全部来自项目侧 `:groups' 时出现（组有配置即
已是新写法，不必提示）。调用方用 `(expr …)' 放入渲染树 —— 该位置接受 nil。
纯函数。"
  (when (ebasecamp-ui--legacy-instances group)
    (etaf-view
     (etaf-label :text ebasecamp-ui--legacy-hint :variant 'warning))))

(defun ebasecamp-ui--empty-configs-view (group)
  "返回「组无配置」的右栏：空态 + 组定义的服务名（只读提示）。
GROUP 为 state 的组项 plist；服务名取自 `:service-names'（组定义，未经配置
覆盖），列出以便确认该组确实有服务但尚未关联项目。"
  (let ((names (plist-get group :service-names)))
    (etaf-view
     (column :width 'stretch :height 'stretch :cross-align 'start
             :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
       (etaf-empty
        :title "尚未关联任何项目"
        :description "在 groups.el 里给该组加 :configs 后即可在此启停服务。")
       (etaf-label
        :text (if names
                  (format "组内服务（只读）：%s" (mapconcat #'identity names "、"))
                "组内尚未定义服务")
        :variant 'muted)))))

(defun ebasecamp-ui--detail-view (session state)
  "返回右栏视图。STATE 为渲染数据（读它建立渲染依赖）。三种形态：
1. 未选中组 → 占位「选择左侧的组」；
2. 选中组无任何实例 → 空态「尚未关联任何项目」+ 组定义的服务名（只读）；
3. 选中组有实例 → 组标题行（+ 旧写法迁移提示）+ 每个实例一个 `etaf-panel' 段。
旧写法（项目侧 `:groups'）实例没有配置名，段 key 回退为项目名（段内唯一）。"
  (let* ((selected (plist-get state :selected))
         (group (and selected
                     (cl-find selected (plist-get state :groups)
                              :key (lambda (item) (plist-get item :name))
                              :test #'equal))))
    (cond
     ((null group)
      (ebasecamp-ui--detail-placeholder))
     ((null (plist-get group :instances))
      (ebasecamp-ui--empty-configs-view group))
     (t
      (let ((group-name (plist-get group :name)))
        (etaf-view
         (column :width 'stretch :height 'stretch :cross-align 'stretch
                 :padding '((lh 1) (ch 1)) :item-gap '(lh 1)
           (expr (ebasecamp-ui--group-header-row group))
           (expr (ebasecamp-ui--legacy-hint-view group))
           (column :width 'stretch :item-gap '(lh 1)
             (box :for (instance (plist-get group :instances))
                  :key (or (plist-get instance :config)
                           (plist-get instance :project))
                  :width 'stretch
               (expr (ebasecamp-ui--instance-section
                      session group-name instance)))))))))))

(defun ebasecamp-ui--detail-placeholder ()
  "返回右侧面板的占位视图：未选中组时显示「选择左侧的组」。"
  (etaf-view
   (column :width 'stretch :height 'stretch :cross-align 'start
           :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
     (etaf-label :text "选择左侧的组" :variant 'muted))))

(defun ebasecamp-ui-view ()
  "返回 ebasecamp 主界面的视图（`etaf-view' 规范化后的对象）。"
  (etaf-view (ebasecamp-ui-app)))

;;; 同步输入助手（事件回调 / M-x / ERT 三态统一）

;; `etaf-call-with-input' 只在 Host 事件回调里可用，否则 signal
;; `etaf-event-error'；下面三个函数把「事件内 / 事件外」两种上下文统一起来，
;; 导入导出与「清单写操作」（`S' / `E' / `M' / `X'）共用。

(defun ebasecamp-ui--error-text (err)
  "从错误对象 ERR（`(SYMBOL . DATA)'）取主消息字符串。纯函数。"
  (let ((data (cdr err)))
    (cond
     ((and data (stringp (car data))) (car data))
     (t (error-message-string err)))))

(defun ebasecamp-ui--error-detail (err)
  "从错误对象 ERR 取可展示的细节（DATA 中主消息之后的项）；无则 nil。纯函数。"
  (let ((rest (cddr err)))
    (when rest
      (mapconcat (lambda (item) (if (stringp item) item (format "%S" item)))
                 rest "\n"))))

(defun ebasecamp-ui--call-with-input (reader)
  "在有 etaf 事件上下文时用 `etaf-call-with-input' 执行 READER，否则直接执行。
`etaf-call-with-input' 只在 Host 事件回调（按钮 `:on-press'）里可用，否则
signal `etaf-event-error'；因此 `M-x' 直接调用与 ERT 场景降级为裸调用。
只捕获该错误类型：READER 自身的错误必须原样上抛，否则会被执行两次。"
  (if (fboundp 'etaf-call-with-input)
      (condition-case nil
          (etaf-call-with-input reader)
        (etaf-event-error (funcall reader)))
    (funcall reader)))

;;; 清单写操作（W4：服务编辑 dialog + `S' / `E' / `M' / `X'）

;; 界面 buffer 仍然只读（ADR-0003）：写操作全部经 `ebasecamp-config-write' 的实体
;; 操作落盘（内部走 `ebasecamp-manifest--write-transaction'：备份 → 原子写 →
;; 仅新增错误才回滚 → 先检测外部修改），界面只是清单的投影。
;;
;; 三条 W0.3 实测约束决定了实现形态：
;; ① `etaf-dialog' 的 buffer 文本**永远不含** dialog 内容（root-layer 投影）→
;;    字段值只能存 `etaf-ref' 并由回调读回，测试断言 ref 而非文本；
;; ② `:ref' 只接受 symbol / function / nil（传 `etaf-ref' 对象会报错）→ 字段用
;;    `:bind' 绑 ref，按钮用 symbol ref；
;; ③ `slot :name 'footer` 必须是 dialog 的**直接子项**（嵌进 column 会报
;;    `Unresolved View item: footer`）；
;; ④ 写盘 + 重载是重活，放在 `etaf-next-tick' 里执行，让「保存中」先渲染。

(defvar ebasecamp-ui--service-editor nil
  "服务编辑 dialog 的 ref 注册表（plist）。
键：`:open' / `:group'（组名字符串）/ `:service'（服务名字符串）/ `:original'（打开
时的 6 字段文本 alist）/ `:image' / `:ports' / `:environment' / `:volumes' /
`:command' / `:restart' / `:error'。全部是 `etaf-ref'（统一形态，无需区分
「ref 还是值」）。
由 `ebasecamp-ui-service-dialog' 的 `:bindings' 在挂载时写入；未打开过界面时为 nil。
测试与 `--open-service-editor' / `--service-dialog-save' 都从这里取 ref。")

(defconst ebasecamp-ui--service-field-parsers
  '((:image . ebasecamp-config-write-text-to-image)
    (:ports . ebasecamp-config-write-text-to-ports)
    (:environment . ebasecamp-config-write-text-to-environment)
    (:volumes . ebasecamp-config-write-text-to-volumes)
    (:command . ebasecamp-config-write-text-to-command)
    (:restart . ebasecamp-config-write-text-to-restart))
  "服务表单字段 → 文本解析函数（W2 的 `text-to-*'，失败时 `user-error' 带行号）。
顺序即错误报告顺序：镜像优先（它是唯一必填字段）。")

(defun ebasecamp-ui--service-editor-new ()
  "创建服务编辑 dialog 的 ref 注册表，记进 `ebasecamp-ui--service-editor' 并返回。
只能在组件 `:bindings'（或其它非渲染期）调用 —— `etaf-ref' 禁止在 `:render' 内创建。"
  (setq ebasecamp-ui--service-editor
        (list :open (etaf-ref nil :name 'ebasecamp-ui-service-open)
              :group (etaf-ref nil :name 'ebasecamp-ui-service-group)
              :service (etaf-ref nil :name 'ebasecamp-ui-service-service)
              :original (etaf-ref nil :name 'ebasecamp-ui-service-original)
              :image (etaf-ref "" :name 'ebasecamp-ui-service-image)
              :ports (etaf-ref "" :name 'ebasecamp-ui-service-ports)
              :environment (etaf-ref "" :name 'ebasecamp-ui-service-environment)
              :volumes (etaf-ref "" :name 'ebasecamp-ui-service-volumes)
              :command (etaf-ref "" :name 'ebasecamp-ui-service-command)
              :restart (etaf-ref "" :name 'ebasecamp-ui-service-restart)
              :error (etaf-ref nil :name 'ebasecamp-ui-service-error))))

(defun ebasecamp-ui--service-field-text (service)
  "返回 SERVICE（`ebasecamp-service' 对象）的 6 个表单字段文本，alist 形态。
多行字段保留换行（`ports' / `environment' / `volumes' 每行一条，`command' 每行
一个参数）；`${VAR}' 与相对路径原样输出（不做任何插值）。"
  (list (cons :image (or (ebasecamp-service-image service) ""))
        (cons :ports (ebasecamp-config-write-ports-to-text
                      (ebasecamp-service-ports service)))
        (cons :environment (ebasecamp-config-write-environment-to-text
                            (ebasecamp-service-environment service)))
        (cons :volumes (ebasecamp-config-write-volumes-to-text
                        (ebasecamp-service-volumes service)))
        (cons :command (ebasecamp-config-write-command-to-text
                        (ebasecamp-service-command service)))
        (cons :restart (ebasecamp-config-write-restart-to-text
                        (ebasecamp-service-restart service)))))

(defun ebasecamp-ui--service-field-changes (editor)
  "把 EDITOR 里**改动过**的字段解析成 `-update-service-fields' 的属性 plist。
只返回文本与 `:original' 不同的字段：未改动的字段不进写盘请求，因此 shell 形式的
`command' 原值（字符串）不会被强制改写成 exec 形式列表（W2 口径：shell 形式不在
表单编辑范围内）。
任一字段解析失败即 `user-error'（消息带行号，直接取自 W2 的 `text-to-*'）。"
  (let ((original (etaf-value (plist-get editor :original)))
        (fields nil))
    (dolist (cell ebasecamp-ui--service-field-parsers)
      (let ((key (car cell))
            (text (etaf-value (plist-get editor (car cell)))))
        (unless (equal text (alist-get key original))
          (setq fields (append fields
                               (list key (funcall (cdr cell) text)))))))
    fields))

(defun ebasecamp-ui--restart-options (current)
  "返回 `etaf-select' 的 restart 选项（alist）。
固定含「默认」（空串）+ 四个枚举 + 当前值（free-form 如 `on-failure:5' 必须作为
一个选项出现，否则 `etaf-select' 会因「值不在 options 里」报错）+「自定义…」。"
  (append '(("" . "（默认）"))
          (mapcar (lambda (value) (cons value value))
                  ebasecamp-config-write-restart-values)
          (when (and (stringp current)
                     (not (string-empty-p current))
                     (not (member current ebasecamp-config-write-restart-values)))
            (list (cons current current)))
          '(("__custom__" . "自定义…"))))

(defun ebasecamp-ui--service-dialog-error-view (text)
  "错误提示视图：TEXT 非空时返回 danger label，否则 nil（占 0 行）。
dialog 内容不进 buffer 文本（W0.3），这里是校验错误的**唯一**展示位。"
  (when (and (stringp text) (not (string-empty-p text)))
    (etaf-view (etaf-label :text text :variant 'danger))))

(etaf-define-component ebasecamp-ui-service-dialog ()
  "服务字段编辑 dialog（根级 `S'）。
组件**始终挂载**：`:open' 为 nil 时 dialog 不显示，但 `:bindings' 里的 ref 一直
可用，`ebasecamp-ui--open-service-editor' 因此能在打开前把 6 个字段与 `:open'
一次写完（`etaf-batch' 只发布一次）。
`slot :name \\='footer\\='` 是 dialog 的直接子项（W0.3 约束 ③）；内容文案不落 buffer，
所以错误只用 `--service-dialog-error-view' 渲染、靠 `:error' ref 断言。"
  :bindings ((editor (ebasecamp-ui--service-editor-new)))
  :render
  (etaf-view
   (etaf-dialog
    :open (plist-get editor :open)
    :title "编辑服务"
    :width '(ch 56)
    :close-label nil
    :on-close (lambda () (etaf-set-value (plist-get editor :open) nil))
    (column :width 'stretch :item-gap '(lh 1)
      (etaf-label :text (format "%s / %s"
                                (or (etaf-value (plist-get editor :group)) "")
                                (or (etaf-value (plist-get editor :service)) ""))
                  :variant 'muted)
      (etaf-text-input :bind (plist-get editor :image)
                       :label "镜像（image）"
                       :ref 'ebasecamp-ui-service-image)
      (etaf-text-input :bind (plist-get editor :ports)
                       :label "端口（每行 HOST:CONTAINER）" :rows 4
                       :ref 'ebasecamp-ui-service-ports)
      (etaf-text-input :bind (plist-get editor :environment)
                       :label "环境变量（每行 KEY=VALUE）" :rows 4
                       :ref 'ebasecamp-ui-service-environment)
      (etaf-text-input :bind (plist-get editor :volumes)
                       :label "卷（每行 SRC:DST[:ro]）" :rows 4
                       :ref 'ebasecamp-ui-service-volumes)
      (etaf-text-input :bind (plist-get editor :command)
                       :label "命令（每行一个参数）" :rows 3
                       :ref 'ebasecamp-ui-service-command)
      (etaf-select :value (etaf-value (plist-get editor :restart))
                   :options (ebasecamp-ui--restart-options
                             (etaf-value (plist-get editor :restart)))
                   :label "重启策略（restart）"
                   :presentation 'dropdown
                   :ref 'ebasecamp-ui-service-restart
                   :on-change
                   (lambda (value)
                     (if (equal value "__custom__")
                         (let ((text (ebasecamp-ui--call-with-input
                                      (lambda ()
                                        (read-string "重启策略（如 on-failure:5）： ")))))
                           (when (and (stringp text)
                                      (not (string-empty-p (string-trim text))))
                             (etaf-set-value (plist-get editor :restart)
                                             (string-trim text))))
                       (etaf-set-value (plist-get editor :restart) value))))
      (expr (ebasecamp-ui--service-dialog-error-view
             (etaf-value (plist-get editor :error)))))
    (slot :name 'footer
      (row :width 'stretch :cross-align 'center :item-gap '(ch 2)
        (etaf-button :label "取消" :variant 'secondary
                     :ref 'ebasecamp-ui-service-cancel
                     :on-press (lambda ()
                                 (etaf-set-value (plist-get editor :open) nil)))
        (etaf-button :label "保存" :variant 'primary
                     :ref 'ebasecamp-ui-service-save
                     :on-press (lambda () (ebasecamp-ui--service-dialog-save))))))))

(defun ebasecamp-ui--row-key-at-point ()
  "返回 point 所在服务行的段内身份 `\"组名/服务名\"`；不在服务行时返回 nil。
行 ref 与 checkbox ref 都接受（点在勾选框上也应能编辑该行服务），两者前缀不同
但后缀是同一个 key（`ebasecamp-ui--instance-key'）。"
  (let ((ref (ebasecamp-ui--ref-at-point ebasecamp-ui--row-ref-prefix
                                         ebasecamp-ui--checkbox-ref-prefix)))
    (when ref
      (let ((name (symbol-name ref)))
        (if (string-prefix-p ebasecamp-ui--row-ref-prefix name)
            (substring name (length ebasecamp-ui--row-ref-prefix))
          (substring name (length ebasecamp-ui--checkbox-ref-prefix)))))))

(defun ebasecamp-ui--split-instance-key (key)
  "把 KEY（`\"组名/服务名\"`）按**首个** `/` 切成 `(组名 服务名)`，都是字符串。
不用 `split-string' 默认的全切：服务名本身可能不含 `/`，但用首个 `/` 是计划
明确的口径，避免任何歧义。无法切分时 `user-error'。"
  (let ((slash (string-match "/" key)))
    (unless slash
      (user-error "无法从行标识 %s 解析组名与服务名" key))
    (list (substring key 0 slash) (substring key (1+ slash)))))

(defun ebasecamp-ui--open-service-editor ()
  "编辑 point 所在服务（根级 `S'）：预填 6 个字段并打开 dialog，返回 t。
定位链：`--ref-at-point' 取行 / checkbox ref → 剥前缀得 `组名/服务名' →
`ebasecamp-model-group' + `ebasecamp-group-services' 取服务对象（**从组定义**
取值而非改后 model 归一化，未编辑字段写回时由写盘层从原文 plist 保真）→
`--service-field-text' 渲染 6 个字段文本 → `etaf-batch' 一次写完并置 `:open'。
point 不在服务行 / 清单里查不到该服务 → `user-error'。"
  (interactive)
  (let ((editor ebasecamp-ui--service-editor))
    (unless editor
      (user-error "服务编辑框未就绪（先打开 ebasecamp 主界面）"))
    (let ((key (or (ebasecamp-ui--row-key-at-point)
                   (user-error "请把光标移到服务行"))))
      (pcase-let ((`(,group ,service) (ebasecamp-ui--split-instance-key key)))
        (let* ((group-object (ebasecamp-model-group (intern group)))
               (service-object
                (and group-object
                     (cl-find service (ebasecamp-group-services group-object)
                              :key (lambda (item)
                                     (symbol-name (ebasecamp-service-name item)))
                              :test #'equal))))
          (unless service-object
            (user-error "清单里找不到组 %s 的服务 %s" group service))
          (let ((texts (ebasecamp-ui--service-field-text service-object)))
            (etaf-batch
              (etaf-set-value (plist-get editor :group) group)
              (etaf-set-value (plist-get editor :service) service)
              (etaf-set-value (plist-get editor :original) texts)
              (dolist (cell ebasecamp-ui--service-field-parsers)
                (etaf-set-value (plist-get editor (car cell))
                                (alist-get (car cell) texts)))
              (etaf-set-value (plist-get editor :error) nil)
              (etaf-set-value (plist-get editor :open) t)))
          t)))))

(defun ebasecamp-ui--service-dialog-save ()
  "服务编辑 dialog 的保存回调：本地解析 → 写盘 → 重载刷新 → 关闭，返回 t 或 nil。
失败路径**不关闭**：解析失败（W2 的 `user-error' 带行号）与写盘失败（事务回滚后
signal）都把消息写进 `:error' ref 并保持 dialog 打开，用户可继续修正。
无字段改动 → 直接关闭且不写盘。
写盘放在 `etaf-next-tick'：让「保存中」先渲染；batch / 非批处理上下文里它立即执行。"
  (interactive)
  (let ((editor ebasecamp-ui--service-editor))
    (unless editor
      (user-error "服务编辑框未就绪（先打开 ebasecamp 主界面）"))
    (condition-case err
        (let ((fields (ebasecamp-ui--service-field-changes editor))
              (group (etaf-value (plist-get editor :group)))
              (service (etaf-value (plist-get editor :service))))
          (etaf-set-value (plist-get editor :error) nil)
          (cond
           ((null fields)
            (etaf-set-value (plist-get editor :open) nil)
            nil)
           (t
            (let ((open (plist-get editor :open))
                  (error-ref (plist-get editor :error))
                  (session (ebasecamp-ui-session)))
              (etaf-next-tick
               (lambda ()
                 (condition-case write-error
                     (progn
                       (ebasecamp-config-write-update-service-fields
                        group service fields)
                       (etaf-set-value open nil)
                       (ebasecamp-ui--after-write
                        session group "服务已更新"
                        (format "%s / %s" group service)))
                   ((error quit)
                    (etaf-set-value error-ref
                                    (error-message-string write-error))))))
              t))))
      (user-error
       (etaf-set-value (plist-get editor :error) (error-message-string err))
       nil))))

(defun ebasecamp-ui--prompt (prompt &optional collection require-match initial)
  "在事件回调安全地问一句并返回字符串（`completing-read'）。
COLLECTION 为 nil 时允许自由输入（新增实体名用）。事件上下文里经
`etaf-call-with-input' 走 Ebox 的输入边界；`M-x' / ERT 场景降级为裸调用
（见 `ebasecamp-ui--call-with-input'）。"
  (ebasecamp-ui--call-with-input
   (lambda () (completing-read prompt collection nil require-match initial))))

(defun ebasecamp-ui--confirm (prompt)
  "在事件回调安全地做一次 y-or-n 确认；用户否决时 `user-error'「已取消」。"
  (unless (ebasecamp-ui--call-with-input (lambda () (y-or-n-p prompt)))
    (user-error "已取消")))

(defun ebasecamp-ui--read-name (prompt &optional initial)
  "收集一个实体名（允许自由输入），返回去首尾空白的字符串。
空输入 `user-error'；名字合法性与唯一性由写盘层校验（`--entity-name' / D2），
界面层不重复实现。"
  (let ((text (string-trim (ebasecamp-ui--prompt prompt nil nil initial))))
    (when (string-empty-p text)
      (user-error "%s不能为空" prompt))
    text))

(defun ebasecamp-ui--read-optional-path (prompt &optional initial)
  "收集一个可选路径（允许自由输入），返回去首尾空白的字符串或 nil。
空输入与纯空白都返回 nil（表示「没有」）；非空时返回 `string-trim' 后的字符串。
不做 `expand-file-name'、不访问文件系统 —— 与写盘层「清单只保存引用」一致
（相对路径原样保留，`~' 不展开）。
对比：`ebasecamp-ui--read-name' 空输入即 `user-error'（实体名必填），本函数专供
可选路径（项目 `:root'）使用；`ebasecamp-ui--manifest-menu' 的两处项目分支据此
把「留空」翻译成 nil。"
  (let ((text (string-trim (ebasecamp-ui--prompt prompt nil nil initial))))
    (unless (string-empty-p text)
      text)))

(defun ebasecamp-ui--group-name-strings ()
  "返回清单里全部组名（字符串），供 `completing-read' 使用。"
  (mapcar (lambda (group) (symbol-name (ebasecamp-group-name group)))
          (ebasecamp-model-groups)))

(defun ebasecamp-ui--require-project (prompt)
  "用 `completing-read' 从清单里选一个已存在的项目，返回项目名 symbol。
清单无项目时 `user-error'（与 `--read-project' 的「安静返回 nil」不同：这里是
写操作的必要参数，静默返回会让调用方在半途放弃）。"
  (let ((names (mapcar (lambda (project)
                         (symbol-name (ebasecamp-project-name project)))
                       (ebasecamp-model-projects))))
    (unless names
      (user-error "清单里没有项目"))
    (intern (ebasecamp-ui--prompt prompt names t))))

(defun ebasecamp-ui--require-group (group)
  "返回选中组 GROUP（symbol）的字符串名；无选中组时 `user-error'。"
  (unless group
    (user-error "请先在左栏选中一个组"))
  (symbol-name group))

(defun ebasecamp-ui--require-group-object (group-object)
  "返回选中的组对象 GROUP-OBJECT；未选中或清单里查不到时 `user-error'。"
  (unless group-object
    (user-error "请先在左栏选中一个组"))
  group-object)

(defun ebasecamp-ui--legacy-reference-p (group project)
  "判断项目 PROJECT 的旧写法 `:groups' 是否仍引用组 GROUP。
GROUP 为组名字符串（选中组的 `symbol-name'），PROJECT 可为符号或字符串。
只读定位（`ebasecamp-config-write--legacy-reference-file'），不写盘。"
  (and (ebasecamp-config-write--legacy-reference-file project group) t))

(defun ebasecamp-ui--confirm-legacy-migration (group project action)
  "检测旧 `:groups' 引用并请用户确认，返回写盘层 `migrate-legacy' 的实参。
GROUP 为组名字符串，PROJECT 为项目名，ACTION 是嵌进文案的短语
（「新建配置后」/「改配置后」）。命中旧引用时问一句：

  项目 example 的旧写法 :groups 仍引用组 redis；新建配置后该旧引用将被组侧
  配置接管。是否同时删掉这条旧引用？

答 yes 返回 t、答 no 返回 nil；未命中直接返回 nil（不打扰用户）。
`y-or-n-p' 经 `--call-with-input' 包装（事件上下文里走 Ebox 输入边界，`M-x' /
ERT 场景降级为裸调用）。**绝不在没有确认的情况下返回 t**：写盘层的
`migrate-legacy' 默认 nil，只有这里答 yes 才会改写项目文件。"
  (when (ebasecamp-ui--legacy-reference-p group project)
    (ebasecamp-ui--call-with-input
     (lambda ()
       (y-or-n-p
        (format (concat "项目 %s 的旧写法 :groups 仍引用组 %s；%s该旧引用"
                        "将被组侧配置接管。是否同时删掉这条旧引用？")
                project group action))))))

(defun ebasecamp-ui--choose-config (group-object prompt)
  "返回 GROUP-OBJECT 里要操作的配置名（symbol）。
只有 1 份配置时直接返回（不提问，`M' / `E' 因此在单配置组上只问必要参数）；
多份时用 `completing-read' 选。组内无配置 → `user-error'。"
  (let ((configs (ebasecamp-model-group-configs group-object)))
    (cond
     ((null configs)
      (user-error "组 %s 没有任何配置" (ebasecamp-group-name group-object)))
     ((null (cdr configs))
      (car (car configs)))
     (t
      (intern (ebasecamp-ui--prompt
               prompt
               (mapcar (lambda (cell) (symbol-name (car cell))) configs)
               t))))))

(defun ebasecamp-ui--after-write (session group title message)
  "写操作成功后的统一收尾：成功 notice → 重载清单（内部刷新界面）→ 恢复选中组。
GROUP 为组名字符串：写后该组仍存在才恢复选中，否则清空选中（不留指向已删除组的
悬空选择）。展开状态是会话里的 key 列表，重载后 key 不变，无需重设。"
  (when session
    (ebasecamp-ui--set-notice session 'success title message))
  (ebasecamp-reload)
  (when session
    (let ((name (and (stringp group) (intern group))))
      (ebasecamp-ui--set-selected-group
       session (and name (ebasecamp-model-group name) name))))
  nil)

(defun ebasecamp-ui--open-config-editor ()
  "改当前配置关联的项目（根级 `E'），返回 `--after-write' 的结果或 nil。
链路：选中组 → 选配置（单配置组不提问）→ `completing-read' 选项目（当前配置的
项目作为默认输入）→ `ebasecamp-config-write-update-config-project'（D2 冲突由
写盘层拒绝）→ 重载刷新并保留选中组。
`quit'（用户取消）静默返回 nil；写盘错误转成 error notice。"
  (interactive)
  (let* ((session (ebasecamp-ui-session))
         (group (etaf-value (ebasecamp-ui-session-selected-group session)))
         (group-name (ebasecamp-ui--require-group group))
         (group-object (or (ebasecamp-model-group group)
                           (user-error "清单里找不到组 %s" group)))
         (config (ebasecamp-ui--choose-config group-object "要改的配置： "))
         (current (ebasecamp-model-config-project
                   (cdr (assoc config (ebasecamp-model-group-configs group-object)))))
         (names (mapcar (lambda (project)
                          (symbol-name (ebasecamp-project-name project)))
                        (ebasecamp-model-projects)))
         (_ (unless names (user-error "清单里没有项目")))
         (project (intern (ebasecamp-ui--prompt
                           (format "新项目（当前 %s）： " (or current "无"))
                           names t (and current (symbol-name current))))))
    (condition-case err
        (progn
          (ebasecamp-config-write-update-config-project
           group-name config project
           ;; A-II：命中旧 `:groups' 引用时经用户确认才迁移（默认 nil）
           (ebasecamp-ui--confirm-legacy-migration
            group-name project "改配置后"))
          (ebasecamp-ui--after-write session group-name
                                     "配置已更新"
                                     (format "%s → %s" config project)))
      (quit nil)
      (error
       (ebasecamp-ui--set-notice session 'error "更新配置失败"
                                 (error-message-string err))
       nil))))

(defun ebasecamp-ui--move-config ()
  "把选中组的配置移到「其他组 + 项目」（根级 `M'），返回 `--after-write' 结果或 nil。
链路：选中组 → 选配置（单配置组不提问）→ 选目标组（候选里排除当前组）→ 选目标
项目 → `ebasecamp-config-write-move-config'（**一次事务**内源组移除 + 目标组追加）。
没有其它组可接收时 `user-error'。"
  (interactive)
  (let* ((session (ebasecamp-ui-session))
         (group (etaf-value (ebasecamp-ui-session-selected-group session)))
         (group-name (ebasecamp-ui--require-group group))
         (group-object (or (ebasecamp-model-group group)
                           (user-error "清单里找不到组 %s" group)))
         (config (ebasecamp-ui--choose-config group-object "要移动的配置： "))
         (targets (delq nil (mapcar (lambda (other)
                                      (let ((name (ebasecamp-group-name other)))
                                        (unless (eq name group)
                                          (symbol-name name))))
                                    (ebasecamp-model-groups))))
         (_ (unless targets (user-error "没有其它组可以接收配置")))
         (target (intern (ebasecamp-ui--prompt "目标组： " targets t)))
         (project (ebasecamp-ui--require-project "目标项目： ")))
    (condition-case err
        (progn
          (ebasecamp-config-write-move-config
           group-name (symbol-name config) (symbol-name target) project)
          (ebasecamp-ui--after-write session (symbol-name target)
                                     "配置已移动"
                                     (format "%s → %s / %s"
                                             config target project)))
      (quit nil)
      (error
       (ebasecamp-ui--set-notice session 'error "移动配置失败"
                                 (error-message-string err))
       nil))))

(defconst ebasecamp-ui--manifest-menu-items
  '("新建配置" "删除配置" "新建项目" "改项目" "删除项目"
    "新建组" "改组" "删除组")
  "根级 `X' 的清单操作菜单项（顺序即提示顺序）。")

(defconst ebasecamp-ui--scope-choices '("shared" "per-project")
  "组 scope 的可选值（字符串形态供 `completing-read'；与
`ebasecamp-model--scopes' 一致）。")

(defun ebasecamp-ui--read-scope (prompt &optional initial)
  "读一个 scope，返回符号 `shared' 或 `per-project'。
`--scope-choices' 是字符串表（`completing-read' 只接受字符串），而模型层与
写盘层都用符号比对（`ebasecamp-model--scopes' + `memq'）—— 这一层转换只在
此处做一次。`require-match' 恒为 t：把输入限制在 `--scope-choices' 内，否则
`intern' 会造出任意符号。"
  (intern (ebasecamp-ui--prompt prompt ebasecamp-ui--scope-choices t initial)))

(defun ebasecamp-ui--manifest-menu ()
  "清单操作菜单（根级 `X'）：配置 / 项目 / 组的 CRUD 统一收在一个
`completing-read' 里，逐项收集参数后调写盘层，成功后重载刷新。
删除类操作都先 `y-or-n-p' 确认，文案写明「只删清单定义，容器需用 `D' 销毁」
（AGENTS 禁止删除容器）。通用收尾：
- 用户取消（`quit'）→ 静默返回 nil；
- 写盘失败（`user-error' / `ebasecamp-config-write-error'）→ error notice，
  文案取 `error-message-string'（事务回滚后的消息已含原因）。"
  (interactive)
  (let* ((session (ebasecamp-ui-session))
         (group (etaf-value (ebasecamp-ui-session-selected-group session)))
         (group-object (and group (ebasecamp-model-group group))))
    (condition-case err
        (let ((choice (ebasecamp-ui--prompt "清单操作： "
                                            ebasecamp-ui--manifest-menu-items t))
              (notice-group (and group (symbol-name group))))
          (pcase choice
            ("新建配置"
             (let* ((config (ebasecamp-ui--read-name "配置名： "))
                    (group-name (ebasecamp-ui--require-group group))
                    (project (ebasecamp-ui--require-project "关联项目： ")))
               (ebasecamp-config-write-add-config
                group-name config project
                ;; A-II：命中旧 `:groups' 引用时经用户确认才迁移（默认 nil）
                (ebasecamp-ui--confirm-legacy-migration
                 group-name project "新建配置后"))))
            ("删除配置"
             (let ((config (ebasecamp-ui--choose-config
                            (ebasecamp-ui--require-group-object group-object)
                            "要删除的配置： ")))
               (ebasecamp-ui--confirm
                (format "从组 %s 删除配置 %s？只删清单定义，容器需用 D 销毁。"
                        group config))
               (ebasecamp-config-write-remove-config
                (ebasecamp-ui--require-group group) config)))
            ("新建项目"
             (let ((name (ebasecamp-ui--read-name "新项目名： "))
                   (title (ebasecamp-ui--read-name "项目标题： "))
                   (root (ebasecamp-ui--read-optional-path
                          (concat "项目根目录（可留空；留空则不参与目录定位、"
                                  "导出需显式选路径）： ")
                          (directory-file-name default-directory))))
               (setq notice-group nil)
               (ebasecamp-config-write-add-project name title root)))
            ("改项目"
             (let* ((name (ebasecamp-ui--require-project "要改的项目： "))
                    (project (ebasecamp-model-project name))
                    (title (ebasecamp-ui--read-name
                            "新标题： " (or (ebasecamp-project-title project) "")))
                    (current (ebasecamp-project-root project))
                    (root (ebasecamp-ui--read-optional-path
                           (concat "新根目录（可留空；留空即清空 :root —— 之后界面"
                                   "不再按目录定位当前项目、导出须显式选路径、"
                                   "相对路径校验降级为警告）： ")
                           (or current (directory-file-name default-directory))))
                    ;; 留空且原本有 root 才是「清空」（要确认）；原本无 root 时幂等，
                    ;; 不弹确认（否则每次改 title 都会被问一次）
                    (clear-root (and (null root) current t)))
               (setq notice-group nil)
               (when clear-root
                 (ebasecamp-ui--confirm
                  (format (concat "清空项目 %s 的 :root？清空后界面不再按目录定位"
                                  "当前项目、导出须显式选路径、相对路径校验"
                                  "降级为警告。")
                          name)))
               (ebasecamp-config-write-update-project name title root clear-root)))
            ("删除项目"
             (let ((name (ebasecamp-ui--require-project "要删除的项目： ")))
               (ebasecamp-ui--confirm
                (format "删除项目 %s？只删清单文件，容器需用 D 销毁。" name))
               (setq notice-group nil)
               (ebasecamp-config-write-remove-project name)))
            ("新建组"
             (let ((name (ebasecamp-ui--read-name "新组名： "))
                   (title (ebasecamp-ui--read-name "组标题： "))
                   (scope (ebasecamp-ui--read-scope "scope： ")))
               (ebasecamp-config-write-add-group name title scope)
               (setq notice-group name)))
            ("改组"
             (let* ((target (or (and group (symbol-name group))
                                (ebasecamp-ui--prompt
                                 "要改的组： "
                                 (ebasecamp-ui--group-name-strings) t)))
                    (target-object (ebasecamp-model-group (intern target)))
                    (title (ebasecamp-ui--read-name
                            "新标题： " (or (ebasecamp-group-title target-object) "")))
                    (scope (ebasecamp-ui--read-scope
                            (format "scope（当前 %s）： "
                                    (ebasecamp-group-scope target-object))
                            (symbol-name (ebasecamp-group-scope target-object)))))
               (ebasecamp-config-write-update-group target title scope)
               (setq notice-group target)))
            ("删除组"
             (let* ((target (or (and group (symbol-name group))
                                (ebasecamp-ui--prompt
                                 "要删除的组： "
                                 (ebasecamp-ui--group-name-strings) t)))
                    (target-object (ebasecamp-model-group (intern target))))
               (ebasecamp-ui--confirm
                (format
                 "删除组 %s（%d 份配置、%d 个服务）？只删清单定义，容器需用 D 销毁。"
                 target
                 (length (ebasecamp-model-group-configs target-object))
                 (length (ebasecamp-group-services target-object))))
               (ebasecamp-config-write-remove-group target)
               (setq notice-group nil))))
          (ebasecamp-ui--after-write session notice-group "清单已更新" choice))
      (quit nil)
      (error
       (ebasecamp-ui--set-notice session 'error "清单操作失败"
                                 (error-message-string err))
       nil))))

;;; 根级键位（单一事实源）

;; 根宿主的 `:keys' 与 `ebasecamp-ui-mode-map' 的兜底绑定都从这里派生/对齐，
;; 避免「键在渲染里绑了但帮助里没有」「测试断言的集合与实现漂移」。
;; 键表只列**本阶段已实现**的键：`e'（编辑清单）在 U5、`SPC'（切换勾选）在
;; U4 加入；完整集合由 U6 的最终断言覆盖。

(declare-function ebasecamp-reload "ebasecamp" ())

(defun ebasecamp-ui--group-names (state)
  "返回 STATE 里的组名列表（symbol，与 `selected-group' 同类型）。
顺序与 `:groups' 一致（即左树的组顺序）；组名为空串的组也包含在内 ——
`n' / `p' 的循环必须与渲染出来的组一一对应，不做任何过滤。纯函数。"
  (mapcar (lambda (group)
            (intern (or (plist-get group :name) "")))
          (plist-get state :groups)))

(defun ebasecamp-ui--set-selected-group (session group)
  "把 SESSION 的选中组写成 GROUP（symbol 或 nil），并按 GROUP 重建 state。
写 selected-group 与 state 两个 ref，渲染依赖因此同时失效（树的选择态与
右栏段同步更新）。返回 nil。"
  (etaf-set-value (ebasecamp-ui-session-selected-group session) group)
  (etaf-set-value (ebasecamp-ui-session-state session)
                  (ebasecamp-ui--build-state group))
  nil)

(defun ebasecamp-ui--switch-group (step)
  "按 STEP（1 = 下一个，-1 = 上一个）切换 SESSION 的选中组，返回新组名或 nil。
无选中组时 STEP 为 1 取第一个、为 -1 取最后一个；有选中组时按 state 里
`:groups' 的顺序循环，越界回绕。选中的组已不在清单里（例如清单被重载删除）
时按「无选中组」处理。清单为空时写 info notice 并 no-op（返回 nil）。
补的是 `etaf-tree' 的缺口：分支节点的 `:on-press' 只做展开/收起，
`on-select' 只对叶子调用，按 RET 无法选中组。"
  (let* ((session (ebasecamp-ui-session))
         (names (ebasecamp-ui--group-names
                 (etaf-value (ebasecamp-ui-session-state session))))
         (current (etaf-value (ebasecamp-ui-session-selected-group session)))
         (index (and current (cl-position current names)))
         (count (length names)))
    (cond
     ((zerop count)
      (ebasecamp-ui--set-notice session 'info "清单里没有组"
                                "先在 groups.el 里定义至少一个组")
      nil)
     ((null index)
      (let ((target (if (> step 0) (car names) (car (last names)))))
        (ebasecamp-ui--set-selected-group session target)
        target))
     (t
      (let ((target (nth (mod (+ index step) count) names)))
        (ebasecamp-ui--set-selected-group session target)
        target)))))

(defun ebasecamp-ui--next-group ()
  "切换到下一个组（末尾回绕），见 `ebasecamp-ui--switch-group'。"
  (interactive)
  (ebasecamp-ui--switch-group 1))

(defun ebasecamp-ui--previous-group ()
  "切换到上一个组（开头回绕），见 `ebasecamp-ui--switch-group'。"
  (interactive)
  (ebasecamp-ui--switch-group -1))

(defun ebasecamp-ui--reload-and-refresh ()
  "重载清单并刷新界面（根级 `g'）。
界面刷新完全由 `ebasecamp-reload' 内部完成：它检测到界面 buffer 存在时调用
`ebasecamp-ui-refresh'。这里**不**再手工调用 `ebasecamp-ui-refresh' ——
否则一次按键会跑两遍 `docker ps'（一次来自 refresh，一次来自状态轮询）。
返回 `ebasecamp-reload' 的结果 plist。"
  (interactive)
  (ebasecamp-reload))

;;; 区域跳转（根级 `1' / `2' / `3'）

(defconst ebasecamp-ui--region-refs
  '((tree . ebasecamp-ui-tree)
    (detail . ebasecamp-ui-detail)
    (footer . ebasecamp-ui-footer))
  "区域 symbol 到该区域根 Host 的 `:ref' 的映射。
三个 ref 由 `ebasecamp-ui-app' 的 render 声明（空清单分支没有底栏，因此
`footer' 可能查不到 Host，见 `ebasecamp-ui--focus-region'）。")

(defun ebasecamp-ui--region-ref (region)
  "返回 REGION 对应的区域根 `:ref'；未知区域返回 nil。纯函数。"
  (alist-get region ebasecamp-ui--region-refs))

(defun ebasecamp-ui--focus-region (region)
  "把焦点移到 REGION 的首个停靠点，返回焦点节点或 nil。
REGION 取 `tree'（左树）/ `detail'（右栏）/ `footer'（底栏），映射见
`ebasecamp-ui--region-ref'。

停靠点由 ebox 排序决定，**不保证**落在区域 Host 本身（通常是区域内第一个
可聚焦控件），因此本函数只承诺「焦点进入该区域子树」。

三类静默 no-op（不 signal、不写 notice）：
① 未知 REGION；
② 当前 buffer 没有已挂载的 ETAF 运行时（`M-x' 在别的 buffer 里误触、
`with-temp-buffer' 里的探针）；
③ 该区域 Host 未渲染（空清单没有底栏）。
静默是刻意的：本函数是按键回调，异常不该弹到用户面前。`etaf-focus-within'
对缺失 Host 会 `user-error'（经 `etaf--event-host-node'），所以「Host 存在」
必须在调用前判掉。

不传 COUNT：`etaf-focus-within' 的 nil COUNT 即「子树第一个停靠点」。"
  (interactive
   (list (intern (completing-read
                  "跳到区域："
                  (mapcar (lambda (cell) (symbol-name (car cell)))
                          ebasecamp-ui--region-refs)
                  nil t))))
  (let ((runtime (etaf-runtime-for-buffer (current-buffer)))
        (ref (ebasecamp-ui--region-ref region)))
    (when (and runtime ref (etaf-runtime-host-node runtime ref))
      (etaf-focus-within runtime ref))))

;; 三个零参命令只为给根级键 `1' / `2' / `3' 做绑定用：`etaf--keys-run' 走
;; `call-interactively'，带 interactive 参数的 `--focus-region' 直接绑上去会在
;; 按键时去 `completing-read' 问区域。
(defun ebasecamp-ui--focus-tree ()
  "跳到左栏（`1'），见 `ebasecamp-ui--focus-region'。"
  (interactive)
  (ebasecamp-ui--focus-region 'tree))

(defun ebasecamp-ui--focus-detail ()
  "跳到右栏（`2'），见 `ebasecamp-ui--focus-region'。"
  (interactive)
  (ebasecamp-ui--focus-region 'detail))

(defun ebasecamp-ui--focus-footer ()
  "跳到底栏（`3'），见 `ebasecamp-ui--focus-region'。"
  (interactive)
  (ebasecamp-ui--focus-region 'footer))

(defun ebasecamp-ui--root-keys ()
  "返回根宿主的 `:keys' 列表，每条为 (KEY COMMAND LABEL)。
这是根级键位的单一事实源：`ebasecamp-ui-app' 的根 Host 直接消费它，
`ebasecamp-ui-mode-map' 的兜底绑定与之对齐，测试也断言它的键集合。
LABEL 必须非空 —— `etaf-help' 会跳过没有 LABEL 的条目，那是键位可发现性的
唯一来源。
不能绑框架保留键（`escape' / `M-g' / `C-g' / `?` / Tab 系列 / 方向键）：
`etaf--keys-validate' 会 signal；需要方向语义时用 `:on-direction'。
`SPC' **不在**本表：`[32]' 属 ebox 的 `ebox--activation-keys'，节点级
char-property keymap 先于 etaf 键层，写进来也收不到事件（它由 ebox 内建处理，
等价于「激活当前控件」= `RET'）；行级切换勾选用 `t'。
`1' / `2' / `3' 是区域跳转（左栏 / 右栏 / 底栏的首个停靠点）。它们是
printing key，绑定后 evil 的数字前缀在界面内失效 —— 与 `q' / `g' 同理，
可接受。"
  (list (list "q" #'ebasecamp-ui-close "关闭界面")
        (list "g" #'ebasecamp-ui--reload-and-refresh "重载清单并刷新")
        (list "n" #'ebasecamp-ui--next-group "下一个组")
        (list "p" #'ebasecamp-ui--previous-group "上一个组")
        (list "1" #'ebasecamp-ui--focus-tree "跳到左栏")
        (list "2" #'ebasecamp-ui--focus-detail "跳到右栏")
        (list "3" #'ebasecamp-ui--focus-footer "跳到底栏")
        (list "e" #'ebasecamp-ui-edit-manifest "编辑当前组清单")
        (list "S" #'ebasecamp-ui--open-service-editor "编辑服务")
        (list "E" #'ebasecamp-ui--open-config-editor "编辑配置")
        (list "M" #'ebasecamp-ui--move-config "移动配置")
        (list "X" #'ebasecamp-ui--manifest-menu "清单操作")
        (list "t" #'ebasecamp-ui--toggle-at-point "切换勾选")
        (list "I" #'ebasecamp-ui-import-compose "导入 compose")
        (list "o" #'ebasecamp-ui-export-compose "导出 compose")
        (list "D" #'ebasecamp-ui-destroy-environment "销毁环境")))

;;; 编辑入口（界面唯一的写入口）

(defun ebasecamp-ui-edit-manifest ()
  "打开当前选中组**定义所在**的清单文件并定位到该组的定义（根级 `e'）。
这是界面**唯一的写入口**：界面 buffer 是只读的（见 `ebasecamp-ui-mode'），
写只能发生在 `emacs-lisp-mode' 的清单 buffer 里；保存后按 `g' 重载清单并
刷新界面。本函数只打开文件，不读取也不打印任何密钥值。

文件由 `ebasecamp-config-write--manifest-file-for-group' 按组名跨文件定位——
组可能在 `groups.el'，也可能在 `projects/*.el'（导入层就把组写进项目文件），
不再固定打开 `groups.el'。三条降级路径都不阻断编辑：
- 无选中组 → `user-error'；
- 定位失败（清单里没有该组 / 同名组重复定义）→ 先 `message' 说明原因，再退到
  `groups.el'（不存在则退到第一个项目文件）；连可编辑的清单文件都没有 →
  `user-error' 提示 `ebasecamp-create-sample-config' / `X' 新建组；
- 文件里搜不到 `(ebasecamp-define-group <组名>' → 退到文件头并 `message'，
  **不 signal**（清单可以手写，定位失败不该阻断编辑）。"
  (interactive)
  (let ((group (etaf-value (ebasecamp-ui-session-selected-group
                            (ebasecamp-ui-session))))
        (file nil))
    (unless group
      (user-error "请先在左栏选中一个组"))
    (setq file
          (condition-case err
              (ebasecamp-config-write--manifest-file-for-group group)
            (user-error
             (message "%s" (error-message-string err))
             nil)))
    ;; 降级：定位失败也要能编辑——优先 groups.el（新组的自然落点），其次第一个
    ;; 项目文件（组本来就写在项目文件里的清单形态）。
    (unless file
      (let ((groups (expand-file-name "groups.el" ebasecamp-config-directory)))
        (setq file (if (file-regular-p groups)
                       groups
                     (car (ebasecamp-config--project-files
                           ebasecamp-config-directory))))))
    (unless (and file (file-regular-p file))
      (user-error "清单里没有组 %s，也没有可编辑的清单文件：%s；先 M-x ebasecamp-create-sample-config 或按 X 新建组"
                  group ebasecamp-config-directory))
    (find-file file)
    (goto-char (point-min))
    (unless (search-forward (format "(ebasecamp-define-group %s"
                                    (symbol-name group))
                            nil t)
      (goto-char (point-min))
      (message "未在 %s 中找到组 %s 的定义"
               (file-name-nondirectory file) group))
    (current-buffer)))

(etaf-define-component ebasecamp-ui-app ()
  "渲染 ebasecamp 主界面：顶栏（标题 + 统计 + 刷新）、组树、右栏配置段。"
  :setup
  (let ((session (ebasecamp-ui-session)))
    ;; 主题必须在这里 provide（`:setup' 阶段），不能在 `:render' 里 ——
    ;; `etaf-provide' 有 `etaf--assert-not-rendering' 守卫，render 期调用会
    ;; signal `etaf-render-side-effect-error (provide-context)'（探针实测）。
    ;; 传 ref 本身即可（`etaf-theme-provide' 对 ref/computed 保留响应式），
    ;; 因此 `ebasecamp-ui--refresh-theme' 写 ref 只刷新属性、不重挂载。
    (etaf-theme-provide ebasecamp-ui--theme)
    (etaf-on-mounted
     (lambda ()
       (ebasecamp-status-start
        (lambda ()
          ;; 轮询刚跑过 `docker ps'：把结果连同「已提供」标记传下去，
          ;; 避免一次刷新采集两次（空表也算已采集）。
          (ebasecamp-ui-refresh (ebasecamp-status-last-records) t)))))
    (etaf-on-unmounted
     (lambda ()
       (ebasecamp-status-stop)
       (ebasecamp-ui--cancel-notice-timer session)))
    nil)
  :render
  (let* ((session (ebasecamp-ui-session))
         (state (etaf-value (ebasecamp-ui-session-state session))))
    ;; 读 selected-group / expanded 建立渲染依赖：选择或展开变化即重渲染
    ;; （树自身也读 expanded，这里显式读是为了让骨架整体对两者敏感）。
    (etaf-value (ebasecamp-ui-session-selected-group session))
    (etaf-value (ebasecamp-ui-session-expanded session))
    ;; 三段式布局（L0 探针结论，见 openspec/completed/2026-10-23-ui-layout-theme-nav.md）：
    ;; - 根必须是 `flex' 纵向节点：只有 tag 为 `flex' 的节点走 `ebox--layout-flex'，
    ;;   `column' / `row' 会忽略子节点的 `:flex-grow' / `:flex-shrink'；
    ;; - 顶栏与底栏 `:flex-shrink 0'（不写会被压缩到 0 行，文本直接从 buffer 消失）；
    ;; - 中间区 `:flex-grow 1 :min-height '(lh 0)'` 承担全部收缩，因此整窗永不滚动；
    ;; - 两个 pane 各包一层 `:height 'stretch :overflow 'scroll'` 的列，各自内部滚动
    ;;   （splitter 的 slot 内容必须显式 `:height 'stretch'`，否则 pane `vh == ch'、
    ;;   `etaf-scroll-by' 恒返回 0）。
    ;; 空清单分支没有底栏（只显示空态），因此不声明 `ebasecamp-ui-footer` ref。
    (if (plist-get state :empty-p)
        (etaf-view
         (flex :flex-direction 'column :width 'stretch :height 'stretch
               :key-scope 'local :keys (ebasecamp-ui--root-keys)
               :ref 'ebasecamp-ui-root
               :bgcolor (etaf-theme-token :ui-bg) :color (etaf-theme-token :ui-fg)
               :padding '((lh 1) (px 2))
           (box :width 'stretch :flex-grow 1 :min-height '(lh 0)
                :padding '((lh 2) (px 3))
             (etaf-empty
              :title "还没有 ebasecamp 清单"
              :description
              (format "在 %s 下定义 groups.el 与 projects/*.el 后重新打开。"
                      ebasecamp-config-directory)))))
      (etaf-view
       (flex :flex-direction 'column :width 'stretch :height 'stretch
             :key-scope 'local :keys (ebasecamp-ui--root-keys)
             :ref 'ebasecamp-ui-root
             :bgcolor (etaf-theme-token :ui-bg) :color (etaf-theme-token :ui-fg)
             :padding '((lh 1) (px 2)) :row-gap '(lh 1)
         ;; ① 顶栏（固定）
         (row :ref 'ebasecamp-ui-header :width 'stretch :flex-shrink 0
              :cross-align 'center :item-gap '(ch 2)
           (etaf-label :text "ebasecamp" :variant 'strong)
           (etaf-label :text (plist-get state :summary) :variant 'muted)
           (box :flex-grow 1)
           (etaf-button :label "刷新" :variant 'secondary
                        :ref 'ebasecamp-ui-refresh
                        :on-press (lambda () (ebasecamp-ui-refresh))))
         (etaf-divider)
         ;; ② 中间区（撑满剩余高度；左右各一个内部滚动容器）
         (box :ref 'ebasecamp-ui-body :width 'stretch :flex-grow 1
              :min-height '(lh 0)
           (etaf-splitter
            :orientation 'horizontal
            ;; ratio 传 **ref 本身**（不是 `etaf-value` 的值）：splitter 内部经
            ;; `etaf-ui--reactive-value' 追踪读取，因此只有它自己在拖动时重渲染，
            ;; 不会连带整个 `ebasecamp-ui-app` 重建（拖动是逐鼠标移动的高频事件）。
            :ratio (ebasecamp-ui-session-split-ratio session)
            :min-ratio ebasecamp-ui--split-ratio-min
            :max-ratio ebasecamp-ui--split-ratio-max
            :on-change #'ebasecamp-ui--splitter-on-change
            (slot :name 'first
              (column :ref 'ebasecamp-ui-tree :width 'stretch :height 'stretch
                      :overflow 'scroll
                (expr (ebasecamp-ui--tree-view session))))
            (slot :name 'second
              (column :ref 'ebasecamp-ui-detail :width 'stretch
                      :height 'stretch :overflow 'scroll
                ;; 内容列自身 `:height 'stretch'，直接放进滚动列会「被拉成滚动的视口高」
                ;; （pane 的 ch 等于子节点的 border-box → `vh == ch` → 滚不动）。
                ;; 中间垫一层 `box'（高度取内容），内容列才恢复自然高度并溢出，滚动生效。
                (box :width 'stretch
                  (expr (ebasecamp-ui--detail-view session state)))))))
         (etaf-divider)
         ;; ③ 底栏（固定）：动作行 + 提示行 + 二次确认框
         (flex :flex-direction 'column :ref 'ebasecamp-ui-footer
               :width 'stretch :flex-shrink 0
           (expr (ebasecamp-ui--footer-view))
           (expr (ebasecamp-ui--notice-view session))
           (ebasecamp-ui-confirm-dialog)
           (ebasecamp-ui-service-dialog)))))))

;;; 导入 / 导出入口

(defun ebasecamp-ui--read-compose-file ()
  "读一个 compose 文件路径；用户取消时返回 nil。
经 `ebasecamp-ui--call-with-input' 调用 `read-file-name'，使事件回调里由
Ebox 负责目标有效性与焦点恢复。"
  (ebasecamp-ui--call-with-input
   (lambda () (read-file-name "Compose 文件：" nil nil t))))

(defun ebasecamp-ui--import-name (file)
  "推断 FILE 的项目名并让用户确认，返回非空字符串。
空输入（直接回车）按建议名处理，与 `ebasecamp-import-file' 一致。"
  (let* ((default (ebasecamp-import-suggest-name file))
         (text (if (stringp default) default (symbol-name default)))
         (input (read-string (format "项目名（%s）：" text) nil nil text)))
    (if (string-empty-p (string-trim input)) text input)))

(defun ebasecamp-ui--target-file (name)
  "返回 NAME 对应的清单文件路径；NAME 非法时返回 nil。
归一与 `ebasecamp-import-apply' 同源（都经 `ebasecamp-import--normalize-name'），
否则大小写不一致会让「已存在」检查与实际写入路径错位。"
  (condition-case nil
      (ebasecamp-config-project-file (ebasecamp-import--normalize-name name))
    (ebasecamp-import-error nil)))

(defun ebasecamp-ui--import-compose (session file)
  "把 FILE 导入清单，成功后写 SESSION 的 notice 并刷新界面；返回落盘路径。
目标文件已存在时先经 `y-or-n-p' 确认覆盖，用户拒绝则返回 nil（不写 notice）。"
  (let* ((file (expand-file-name file))
         (name (ebasecamp-ui--import-name file))
         (target (ebasecamp-ui--target-file name))
         (force (and target (file-exists-p target) t)))
    (if (and force (not (y-or-n-p (format "%s 已存在，覆盖？" target))))
        nil
      (let ((path (ebasecamp-import-apply file name :force force)))
        (ebasecamp-ui--set-notice session 'success "导入完成" path)
        (ebasecamp-ui-refresh)
        path))))

(defun ebasecamp-ui-import-compose ()
  "选择 compose 文件导入为清单，成功后提示并刷新界面。返回落盘路径或 nil。
交互链：选文件（`read-file-name'）→ 确认项目名（`read-string'）→ 冲突时
`y-or-n-p' 确认覆盖 → `ebasecamp-import-apply' 落盘。项目根目录取 compose
文件父目录（与 `ebasecamp-import-apply' 的默认一致），不再单独提问。
用户取消（`quit'）静默返回 nil。"
  (interactive)
  (let ((session (ebasecamp-ui-session)))
    (condition-case err
        (let ((file (ebasecamp-ui--read-compose-file)))
          (when file
            (ebasecamp-ui--import-compose session file)))
      (quit nil)
      (ebasecamp-import-error
       (ebasecamp-ui--set-notice session 'error "导入失败"
                                 (ebasecamp-ui--error-text err)
                                 (ebasecamp-ui--error-detail err))
       nil)
      (error
       (ebasecamp-ui--set-notice session 'error "导入失败"
                                 (error-message-string err))
       nil))))

(defun ebasecamp-ui--read-project (prompt)
  "用 `completing-read' 从清单里选项目，返回项目名 symbol；未选到返回 nil。
PROMPT 为提示文案。清单无项目时写 info notice「没有可用项目」并返回 nil
（不抛错，让调用方安静收场）；用户取消选择时 `completing-read' 会 signal
`quit'，由调用方静默转成 nil。"
  (let ((projects (ebasecamp-model-projects)))
    (if (null projects)
        (progn
          (ebasecamp-ui--set-notice (ebasecamp-ui-session) 'info "没有可用项目"
                                    "请先在清单中定义项目")
          nil)
      (let ((name (completing-read
                   prompt
                   (mapcar (lambda (project)
                             (symbol-name (ebasecamp-project-name project)))
                           projects)
                   nil t)))
        (and (stringp name)
             (not (string-empty-p name))
             (intern name))))))

(defun ebasecamp-ui-export-compose ()
  "选项目并导出为部署用 compose 文件，成功后提示。返回导出路径或 nil。
项目经 `completing-read' 选择（不依赖任何「当前项目」状态）；返回 nil 的
三种情形一律安静：清单无项目（写 info notice「没有可用项目」）、用户取消
选择（`quit'）、导出层返回 nil（例如冲突三选一里选了取消）。
路径选择与覆盖冲突「换一个路径 / 覆盖 / 取消」三选一都由
`ebasecamp-export-project' 负责（这里把 `ebasecamp-export--interactive' 绑成
t，使事件回调上下文也能弹出该询问）。"
  (interactive)
  (let ((session (ebasecamp-ui-session)))
    (condition-case err
        (when-let* ((name (ebasecamp-ui--read-project "导出项目： ")))
          (let ((ebasecamp-export--interactive t)
                (path (ebasecamp-export-project
                       (ebasecamp-model-project name) :force nil)))
            (when path
              (ebasecamp-ui--set-notice session 'success "导出完成" path))
            path))
      (quit nil)
      (ebasecamp-export-error
       (ebasecamp-ui--set-notice session 'error "导出失败"
                                 (ebasecamp-ui--error-text err)
                                 (ebasecamp-ui--error-detail err))
       nil)
      (error
       (ebasecamp-ui--set-notice session 'error "导出失败"
                                 (error-message-string err))
       nil))))

(defun ebasecamp-ui-destroy-environment ()
  "选项目并把「销毁环境」转入二次确认，返回 t（已转入确认）或 nil。
交互链：`completing-read' 选项目 → 待确认动作写成 `(down . 项目名)'、置
`confirm' ref 为 t → `ebasecamp-ui-confirm-dialog' 弹出（文案点名该项目）。
真正的派发发生在确认按钮（`ebasecamp-ui-confirm'），且 keys 为 nil（全部
服务）：`down' 的语义是整个 compose 项目，shared 组不提供 down。
返回 nil 的两种情形一律安静：清单无项目（info notice「没有可用项目」）、
用户取消选择（`quit'）。"
  (interactive)
  (let ((session (ebasecamp-ui-session)))
    (condition-case nil
        (when-let* ((name (ebasecamp-ui--read-project "销毁项目： ")))
          (setf (ebasecamp-ui-session-confirm-action session) (cons 'down name))
          (etaf-set-value (ebasecamp-ui-session-confirm session) t)
          t)
      (quit nil))))

;;; 公开 API

(defun ebasecamp-ui--legacy-count (state)
  "返回 STATE 中旧写法（项目侧 `:groups'）实例的总数。纯函数。"
  (apply #'+ 0 (mapcar (lambda (group)
                         (or (plist-get group :legacy-count) 0))
                       (plist-get state :groups))))

(defun ebasecamp-ui--report-counts (state)
  "用 `message' 报告 STATE 的组数 / 配置数，有旧写法关联时附加其数量。"
  (let ((groups (length (plist-get state :groups)))
        (configs (apply #'+ 0 (mapcar (lambda (group)
                                        (or (plist-get group :config-count) 0))
                                      (plist-get state :groups))))
        (legacy (ebasecamp-ui--legacy-count state)))
    (if (> legacy 0)
        (message "ebasecamp：%d 组 · %d 配置（%d 个旧写法关联）"
                 groups configs legacy)
      (message "ebasecamp：%d 组 · %d 配置" groups configs))))

(defun ebasecamp-ui-report-counts ()
  "用 `message' 报告当前会话的组数 / 配置数（有旧写法关联时附其数量）。
界面打开后给用户一条回执，避免「组树 0 配置 + 无任何输出」被误判为命令失灵。
会话不存在时静默返回 nil。"
  (interactive)
  (when ebasecamp-ui--session
    (ebasecamp-ui--report-counts
     (etaf-value (ebasecamp-ui-session-state ebasecamp-ui--session)))))

(defun ebasecamp-ui--display-buffer (buffer)
  "把 BUFFER 显示在选中 window 中并选中该 window。
BUFFER 已在某窗口显示时复用之（`select-window'）；否则用 `display-buffer-same-window'
把选中 window 的 buffer 直接换成 BUFFER —— 即用户已确认的显示策略：当前
window 切过去，不拆分、不删除其它 window。

不要把它写成 `(pop-to-buffer BUFFER \\='((display-buffer-reuse-window
display-buffer-same-window)))'：batch 实测 `display-buffer-reuse-window' 在
「无可复用窗口」时**会 split** 出第二个窗口（`*scratch*` 留在原窗口，frame
被拆成两半），与「不动其它 window」的策略相反。"
  (let ((window (get-buffer-window buffer)))
    (if window
        (progn (select-window window) window)
      (pop-to-buffer buffer '(display-buffer-same-window)))))

(defun ebasecamp-ui-open ()
  "打开（或复用）ebasecamp 主界面 buffer，并把它显示在选中 window，返回该 buffer。
清单未加载时先按 `ebasecamp-config-directory' 加载一次；buffer 已有运行时
则直接复用，不重复挂载。

**显示无条件发生**（见 `ebasecamp-ui--display-buffer'）：当前 window 直接切到
界面 buffer，不拆分、不删除其它 window。顺序是「先显示、后挂载」：`etaf-mount'
期间 `ebox' 要按窗口宽度测量视口，buffer 尚未显示时只能拿到默认视口宽度，而
`ebox-refit' 只在窗口尺寸变化时被动触发 —— 先显示让首帧即按真实宽度排版。
挂载失败时把选中 window 恢复为显示前的 buffer，再原样 re-signal（不吞错）。

被**直接**交互调用（\\[ebasecamp-ui-open]）时额外用 `message' 报告「N 组 · M
配置」；由 `ebasecamp' 命令间接调用时不报告，回执由该命令在打开后自行报告
（`called-interactively-p' 不跨帧传播，回执必须落在用户实际调用的那个命令上，
否则 `M-x ebasecamp' 会漏发或重发）。
注意：显示不能放在 `called-interactively-p' 门控里 —— 那正是「`M-x ebasecamp'
建好 buffer 却永不显示」的成因。"
  (interactive)
  (ebasecamp-ui--ensure-manifest)
  (ebasecamp-ui-session)
  ;; 主题跟随：open 挂钩子、close 卸载（严格对称）。必须在挂载前挂上，首帧即
  ;; 用最新的 face / 明暗得到配色（挂载后再挂会让首帧用旧 plist）。
  (ebasecamp-ui--theme-hooks-install)
  (ebasecamp-ui--refresh-theme)
  (let ((buffer (get-buffer-create ebasecamp-ui-buffer-name))
        (previous (window-buffer (selected-window))))
    (ebasecamp-ui--display-buffer buffer)
    (condition-case err
        (with-current-buffer buffer
          ;; 主模式必须**先于**挂载建立：`special-mode' 会
          ;; `kill-all-local-variables'，若放在 `etaf-mount' 之后会清掉 ebox 的
          ;; buffer-local 挂载状态（`ebox--buffer-mount'），`ebox-focus-scope' /
          ;; `ebox-node-at' 随即报 "No mounted Ebox tree"，键盘焦点与键层全部
          ;; 失效（实测）。只读也在这里一次设好：etaf 自己的写入用
          ;; `inhibit-read-only'，不受影响（U0.2 探针结论）。
          (ebasecamp-ui-mode)
          (unless (etaf-runtime-for-buffer buffer)
            (etaf-mount buffer (ebasecamp-ui-view))))
      ((error quit)
       (set-window-buffer (selected-window) previous)
       (signal (car err) (cdr err))))
    (when (called-interactively-p 'any)
      (ebasecamp-ui-report-counts))
    buffer))

(defun ebasecamp-ui-refresh (&optional records supplied-p)
  "重新采集容器状态、重建渲染数据并写回会话，返回新的 state plist。
RECORDS 为已采集的状态记录（轮询回调传入；SUPPLIED-P 为真表示调用方明确
提供了记录，即使其值为 nil（例如 `docker ps' 返回空表）也不再重复采集，
避免一次刷新跑两次 `docker ps'）。未提供时调用
`ebasecamp-status-snapshot'（失败不 signal，错误留在
`ebasecamp-status-last-error'，旧记录保留）。
state 的 running / total 统计由 `ebasecamp-ui--build-state' 经
`ebasecamp-data-group-instances' 读 `ebasecamp-status-last-records' 得到，
因此快照必须先发生（轮询与命令完成后的刷新都靠它更新 last-records）；本函数
的 RECORDS 参数只用于「已采集」标记，不再参与 state 构建。"
  (interactive)
  (let ((session ebasecamp-ui--session))
    (when session
      (unless supplied-p
        (ebasecamp-status-snapshot))
      ;; RECORDS 仅作「已采集」标记（state 直接消费 last-records），
      ;; 显式消费它以满足「无未使用变量」的编译约束。
      (ignore records)
      (let* ((selected (etaf-value (ebasecamp-ui-session-selected-group session)))
             (state (ebasecamp-ui--build-state selected)))
        (etaf-set-value (ebasecamp-ui-session-state session) state)
        state))))

(defun ebasecamp-ui-close ()
  "关闭主界面：卸载运行时（触发 unmounted 收尾）、kill buffer、停轮询、
取消提示定时器、卸载主题钩子、销毁会话。返回 nil。
关闭前把左栏宽度占比落盘一次（拖动结束时已存过，这里保证「拖到一半直接关闭」
也记住；写盘失败不阻断关闭，见 `ebasecamp-ui--save-ui-state'）。"
  (interactive)
  (ebasecamp-ui--theme-hooks-remove)
  (when ebasecamp-ui--session
    (ebasecamp-ui--save-ui-state))
  (when-let* ((buffer (get-buffer ebasecamp-ui-buffer-name)))
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (etaf-unmount runtime))
    (kill-buffer buffer))
  (ebasecamp-status-stop)
  (when-let* ((session ebasecamp-ui--session))
    (ebasecamp-ui--cancel-notice-timer session)
    (setq ebasecamp-ui--session nil))
  nil)

;;; 主模式（buffer 身份与键位）

(declare-function evil-set-initial-state "evil" (mode state))

(define-derived-mode ebasecamp-ui-mode special-mode "EBEcamp"
  "ebasecamp 主界面的主模式。
派生自 `special-mode'：界面内容由 etaf 渲染，本 buffer 不接受用户编辑 ——
所有写操作都发生在清单文件（`groups.el' / `projects/*.el'）里，界面只是它的
投影。因此 body 把 `buffer-read-only' 置为 t，把「写」的能力从界面移除。

键位分两层：etaf 的 Host `:keys' 层（装在 `emulation-mode-map-alists' 最前面，
优先级更高，负责界面内的全部操作键，见 `ebasecamp-ui--root-keys'）与本模式的
`ebasecamp-ui-mode-map'（兜底，重绑 `q' 与 `g'）。

**实测事实**：本 map 上的 printing key 会被 etaf 的 runtime 键层遮住 ——
U1 实测 `(lookup-key ebasecamp-ui-mode-map (kbd \"q\"))` 为
`ebasecamp-ui-close'，但 `(key-binding (kbd \"q\"))` 返回 `ignore'
（local 边界对未绑定 printing key 一律回 `ignore'）。因此这里的绑定只是
「没装 etaf 键层时」的兜底，不能作为界面上按键生效的依赖；界面内按键必须
声明在根宿主的 `:keys' 里。"
  (setq-local buffer-read-only t))

;; `special-mode' 自带的 `q' 绑的是 `quit-window'（只切走窗口）；关闭界面必须
;; 走 `ebasecamp-ui-close'：卸载运行时、停轮询、取消提示定时器、销毁会话。
;; `g' 同理：`special-mode' 没有 `g' 的默认绑定，这里补的是「etaf 键层不可用」
;; 时的装饰性兜底（正常路径走根 Host `:keys'）。
(define-key ebasecamp-ui-mode-map (kbd "q") #'ebasecamp-ui-close)
(define-key ebasecamp-ui-mode-map (kbd "g") #'ebasecamp-ui--reload-and-refresh)

;; 装了 evil 时让该 mode 一进入就是 normal state（`i' 不再进 insert）。
;; 不引入 evil 依赖：未装 evil 时 `with-eval-after-load' 永不触发。
(with-eval-after-load 'evil
  (evil-set-initial-state 'ebasecamp-ui-mode 'normal))

(provide 'ebasecamp-ui)
;;; ebasecamp-ui.el ends here
