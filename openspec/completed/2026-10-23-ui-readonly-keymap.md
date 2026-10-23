# ebasecamp v0.3 — 界面只读化与键盘操作（UI keymap）

## 当前状态

- 已归档（2026-10-23）：U7.8 目检由 v0.4 期间的实机使用确认（界面只读、键位、编辑入口均可用；`1`/`2`/`3` 由 v0.4 追加）。
- 阶段：已完成（Phase 4）· **已归档（U7.8 由 v0.4 期间实机使用承接）**（U7.1–U7.7 + U7.9 全部落地：三份用户/架构文档新增小节、ADR-0003、decisions 两行、AGENTS 不变量第 12 条与「已知特性」节、troubleshooting 第 11–13 条、CHANGELOG 0.3.0、11 个文件 `Version:` 同步、Readme 命令表 13 → 16、tech-debt #20/#26 补充 + 新增 #27、计划归档），下一步 **无（计划已归档）**
- 已确认：方案 ✅（用户 2026-10-23 选择「推荐键位方案」：`SPC` 切换勾选 + `q`/`g`/`e`/`I`/`o`/`D`/`n`/`p` + 段内 `s`/`x`/`r`/`a`/`A`）；计划 ✅（用户 2026-10-23 确认）；**方案 A 修订** ✅（用户 2026-10-23 裁决：`SPC` 保持 ebox「激活当前控件」语义，行级切换改用 `t`）
- 已完成：批次 U1（U1.1 先红 → U1.2 转绿）、批次 U2（U2.1 先红 → U2.2 转绿）、批次 U3（U3.1 先红 → U3.2 转绿）、批次 U4（U4.1 先红 → U4.2 转绿）、批次 U5（U5.1 先红 → U5.2 转绿）、批次 U6（U6.1 守护性用例天然绿 + U6.2 帮助面自动化）、批次 U7 的文档部分（U7.1 `Readme.org` 新增「界面键位」48 行；U7.2 `docs/user-guide.org` 新增「界面操作与键位」85 行；U7.3 `docs/architecture.org` 新增「UI buffer 身份与键位分层」63 行 + 公开 API 表按实测同步）。批次 U0 的探针结论已作为已知事实用于后续批次（U0.1–U0.3 的 checkbox 保持未勾，待用户确认后统一点选）
- 批次 U4 已落地（方案 A）：checkbox 稳定 `:ref`（`ebasecamp-ui-check-<组名>/<服务名>`）、行稳定 `:ref`（`ebasecamp-ui-row-<组名>/<服务名>`）、`ebasecamp-ui--ref-at-point`（向上找 check/row 前缀 ref）、`ebasecamp-ui--checkbox-ref-at-point`（薄封装）、`ebasecamp-ui--toggle-at-point`（行 ref → 同行 checkbox ref → `etaf-dispatch-event`；非服务行位置静默 no-op）、`ebasecamp-ui--toggle-row`（`:on-row-press` 入口）、根级键 `t` = 切换勾选
- **编辑入口（U5 后）**：`e` → `ebasecamp-ui-edit-manifest`：取会话 `selected-group` → `find-file <dir>/groups.el` → 定位 `(ebasecamp-define-group <组名>`。这是界面**唯一写入口**（UI buffer 只读），保存后按 `g` 重载。错误/降级：无选中组 → `user-error`「请先在左栏选中一个组」；文件不存在 → `user-error`「清单文件不存在：…；先 M-x ebasecamp-create-sample-config」；组定义找不到 → `point-min` + `message`（不 signal）
- **帮助（U6 后，可发现性已自动化）**：LABEL 是 `?` 帮助的唯一来源（`etaf-help-data` 里 `(when (nth 2 entry) …)` —— 无 LABEL 的条目被**静默跳过**）。实测 `etaf-help-data` 与 `etaf-help` 在 `emacs -Q --batch` 下**都可用**：前者按 point 所在键链返回 `:groups`（顶栏区 = 9 条根级；进入段内 = 再加 5 条段级），后者立刻挂载只读 catalog（标题「快捷键 · 只读」）且 `etaf-help-close` 后文本逐字符复原。**catalog 按可用视口裁剪条目**（全量运行时首屏 4 条根级、单独运行时 5 条），故帮助面用例只断言首屏必然出现的 4 条 + 标题，全量 LABEL 由 `help-data-includes-labels` 的数据快照断言
- 下一步：无（计划已归档）；历史目检清单 8 项（冷启动按 `i` 不进 insert / Tab 遍历 / `s`–`x`–`r` / `a`–`A` / `t` 行内切换 / `SPC` 与 `RET` 在 checkbox 上勾选、按钮上按下 / 点行或行上 `RET` 也切换 / `e` 打开并定位 / `q` 关闭后无残留轮询 / `?` 帮助）；已由 v0.4 期间实机使用覆盖
- **勾选键现状（方案 A）**：`SPC` = ebox 内建的「激活当前控件」（`[32]` 属 `ebox--activation-keys`，与 `RET` 同义：checkbox 上勾选、按钮上按下）→ **不在** `--root-keys`；`t` = 我们的行级切换（行内任意单元格都能勾、在按钮上是 no-op）；`RET` / 鼠标点击行 = `:on-row-press` → 同样切换该行勾选
- 测试基线：`make test` **337 项（337 expected / 0 unexpected）**（U5 基线 332 + U6 新增 5 项）；`make check` 三项全绿（2026-10-23 15:40 复跑，exit 0）：check-parens **22 文件**、`compile` 零 warning（`byte-compile-error-on-warn t` 下 exit 0）、ERT **337/337** 全绿
- 根级键位现状（U6 后，**9 条，最终集合已断言**）：根 Host `:key-scope 'local :keys (ebasecamp-ui--root-keys)` = `q g n p e t I o D`；`ebasecamp-ui-test-root-keys-final-set` 用 `key-description` 归一 + `sort` + `equal` 做精确等值断言，并断言 `SPC` / `RET` 不在表内；`SPC` 不进本表，由 ebox 内建处理
- 段级键位现状（U3 后，未变）：每份配置段 = `box`（`box :width 'stretch :keys (ebasecamp-ui--section-keys 组名 instance)`）包 `etaf-panel`；段内 `s`/`x`/`r` → `--section-action`（start/stop/restart，捕获该段自己的 instance），`a`/`A` → `--select-instance`（全选 / 全不选该段，写 `selected-ref`）；探针实测 point 在段内时 `s x r a A` 五键均为闭包、`RET` 为闭包、`SPC` 报 `ignore`（但实际按到按钮）
- 回滚点：本计划只改 UI 层与文档，不动 model / compose / command / docker
- 执行要求：每个批次改动前创建 git 安全点（记录 `git status --porcelain`，并把本批次涉及文件备份到 `/tmp/ebc-uibak-<时间戳>/`）；验证失败回滚后再报告

## 目标

1. **buffer 身份**：`*ebasecamp*` 使用专用主模式 `ebasecamp-ui-mode`（派生 `special-mode`）并设 `buffer-read-only t`，把「写」的能力从 UI buffer 移除。
2. **完整键位**：根级与段级 Host 用 etaf `:keys` 声明全部键位（每条带中文 LABEL，`?` 可查），根 Host 加 `:key-scope 'local` 吞掉未绑定 printing key（含 `i`），从而不再进入 evil insert state。
3. **唯一写入口**：`e` 打开 `groups.el` 并定位到当前组定义；写只发生在普通 `emacs-lisp-mode` 的清单 buffer。

## 非目标

- 界面内清单编辑器（新增/删除配置、表单、字段编辑）——仍留 tech-debt #26（M4）
- 修改 etaf / etaf-ui 第三方代码；引入 evil 硬依赖；改 `thomas-emacs/lisp/init-project.el` 的 `SPC t e e`
- 行级光标高亮、鼠标右键菜单、列表排序、键位自定义（defcustom 键表）
- 不改 `ebasecamp-command.el` / `ebasecamp-docker.el` / compose 渲染链

## 现状与根因

`*ebasecamp*` 是「没有身份的裸 buffer」：`ebasecamp-ui-open` 只做 `get-buffer-create` + `etaf-mount`（`lisp/ebasecamp-ui.el:1310-1342`），既不设 major mode 也不设 read-only；etaf 的 mount 同样不设（`etaf-runtime.el:2210-2265`）。

键位因此是三层叠加，优先级从高到低：

| 层 | 内容 | 现状 |
|---|---|---|
| etaf Host `:keys` | 应用声明的键 + 框架默认（`?` 帮助、Tab 焦点移动、RET 激活、方向键） | 应用侧一条都没声明 |
| evil emulation map | `i` → insert state 等 | 未被遮挡，故能进 insert |
| `ebox-buffer-mode` | `suppress-keymap`（`ebox-interaction.el:2079-2087`） | 优先级最低，挡不住 evil |

两个机制事实：

- etaf 键层装在 `emulation-mode-map-alists` **最前面**（`etaf-keys.el:192-212`），因此能遮住 evil；
- etaf **只在 local/modal 边界内**吞掉未绑定的 printing key（`etaf-keys.el:444-448`），当前视图根没有 `:key-scope 'local`，所以 `i` 一路落到 evil。

另两处功能缺口：

- **键盘无法切换选中组**：`etaf-tree` 分支节点的 `:on-press` 只做展开/收起，`on-select` 只对叶子调用（`etaf-ui-advanced.el:113-134`），组节点按 RET 只能折叠；
- **服务行不可聚焦**：`--service-table` 未传 `:on-row-press`（`lisp/ebasecamp-ui.el:947-956`），只有首列 checkbox 可聚焦（`:tab-index 0`，`etaf-ui-basic.el:249`）。

写能力错位：insert state 让 UI buffer 本身成了「可打字的地方」，而真正该写的地方（`groups.el` / `projects/*.el`）却没有入口。

## 设计决策

- **K1 buffer 身份**：`define-derived-mode ebasecamp-ui-mode special-mode`，body 设 `buffer-read-only t`；`special-mode` 自带 `q`/`g` 绑定，在 `ebasecamp-ui-mode-map` 里重绑为 `ebasecamp-ui-close` / `ebasecamp-ui--reload-and-refresh` 作兜底（etaf 键层优先）。
- **K2 键位分层**：根级键声明在主视图最外层 Host（统一包裹 empty 与非 empty 两个渲染分支），加 `:key-scope 'local`；段级键声明在每份配置的 `etaf-panel` 调用点（Host 属性 fallthrough 到组件根）。
- **K3 段级语义与按钮同源**：`s`/`x`/`r` 的闭包直接调 `ebasecamp-ui--section-action`，捕获该段自己的 instance；不引入「当前段」全局状态，避免同组多实例串段。
- **K4 组切换**：`n`/`p` 按 state 里 `:groups` 的顺序循环切换 `selected-group` 并重建 state（补 etaf-tree 分支节点无法 select 的缺口）。
- **K5 行级切换勾选（原「`SPC` 切换勾选」，被方案 A 修订）**：给 service 表首列 checkbox 加稳定 `:ref`，并把 `ref → on-press thunk` 存进会话（新增 `select-actions` 槽位）；`SPC` 命令取 `point` 所在节点、向上找带 ref 的宿主、查表调用。
- **K6 编辑入口**：`ebasecamp-ui-edit-manifest` 对当前选中组 → `find-file <dir>/groups.el` → 定位到 `(ebasecamp-define-group <组名>`；文件不存在时 `user-error` 并提示 `M-x ebasecamp-create-sample-config`。
- **K7 `g` 语义**：`g` = 重载清单（`ebasecamp-reload`）+ 刷新状态（`ebasecamp-ui-refresh`），与「编辑清单后按 g」的工作流一致。
- **K8 键表单一事实源**：全部键位集中在一个函数/常量（`ebasecamp-ui--root-keys` / `--section-keys`），渲染与测试共用；每条必须有 LABEL。
- **K9 不拦截 Emacs 前缀键**：`C-x` / `M-x` / `C-g` / `ESC` 不受影响（local 边界只吞 printing key 与框架保留键）。
- **K11 SPC 代价（方案 A 后失效）**：原设计把 `SPC` 绑为「切换勾选」，因而牺牲该 buffer 内 general / evil 的 `SPC` leader 前缀。实测 `SPC` 无法被 etaf 键层拦截（见 U4.2 ⑧），方案 A 改绑 `t` 后此代价**不再存在**：`SPC` 仍是 ebox 的激活键（在其节点上等价 `RET`），`t` 只占用一个原本无绑定的 printing key。
- **K10 evil 集成条件化**：`with-eval-after-load 'evil` + `(evil-set-initial-state 'ebasecamp-ui-mode 'normal)`；不引入 evil 依赖，未装 evil 时无副作用。

## 键位表

根级（整个界面，主视图 Host）：

| 键 | 动作 | LABEL |
|---|---|---|
| `q` | `ebasecamp-ui-close` | 关闭界面 |
| `g` | `ebasecamp-reload` + `ebasecamp-ui-refresh` | 重载清单并刷新 |
| `n` / `p` | 下一个 / 上一个组 | 下一个组 / 上一个组 |
| `e` | `ebasecamp-ui-edit-manifest` | 编辑当前组清单 |
| `I` | `ebasecamp-ui-import-compose` | 导入 compose |
| `o` | `ebasecamp-ui-export-compose` | 导出 compose |
| `D` | `ebasecamp-ui-destroy-environment` | 销毁环境 |
| `t` | `ebasecamp-ui--toggle-at-point` | 切换勾选 |
| `?` | `etaf-help`（框架默认，不可绑） | — |
| `TAB` / `S-TAB` / `RET` / 方向键 | 框架默认（焦点移动 / 激活 / 分支展开） | — |
| 其余 printing key（含 `i`） | 被 local 边界吞掉，无反应 | — |
| `C-x` / `M-x` / `C-g` / `ESC` | 不拦截 | — |

段级（point 在该配置段内时生效）：

| 键 | 动作 | LABEL |
|---|---|---|
| `s` | 启动该段选中服务 | 启动该段选中 |
| `x` | 停止该段选中服务 | 停止该段选中 |
| `r` | 重启该段选中服务 | 重启该段选中 |
| `a` | 全选该段全部服务 | 全选该段服务 |
| `A` | 全不选该段 | 全不选该段服务 |

**代价与边界**：`SPC` 不在本表 —— 它是 ebox 的内建激活键（`[32]` 属 `ebox--activation-keys`，等价于 `RET`），etaf 键层收不到该事件（见 U4.2 ⑧）；行级切换用 `t`（printing key，在 local 边界内由本应用处理）；`s`/`x`/`r` 仅在 point 位于某个配置段内时命中，point 在左树 / 顶栏时按键被吞且无提示（与「界面不响应无关键」的约定一致）。

## 任务

### 批次 U0：探针（先验证假设，失败即回 Phase 1）

- [x] U0.1 探针 P1：etaf `:key-scope 'local` 是否吞掉未绑定 printing key。在 `/tmp` 写独立探针脚本（不入仓库），用 `emacs -Q --batch` + 仓库 Makefile 的 `LOAD_PATH`/`ELPA_LOAD_PATH`（`-L . -L lisp` + straight build 的 etaf/etaf-ui/ebox/ecss），构造两个最小 view：`(column :key-scope 'local :keys '(("q" ignore "关闭")) (box "x"))` 与不带 `:key-scope` 的对照。`etaf-mount` 到临时 buffer 后断言：①有 boundary 时 `(etaf--keys-binding [?\i])` 返回 `#'ignore`；②point 在 `(point-min)` 与 `(point-max)` 两种情况都成立；③**显式清空 focus（`(ebox-clear-focus)` 或等价手段）并把 point 移到无节点空白区**时仍返回 `#'ignore`（失败则记录 ebox 初始 focus 行为，并在报告中给出缓解方案）；④对照 view（无 `:key-scope`）返回 nil。收尾删除 `/tmp` 脚本并把输出摘要写入执行日志
      （依赖：无）验收：四条断言全部 PASS；若 P1 失败 → **停止后续批次并报告 harspower，方案需回 Phase 1 重新设计**
      （归档时补记：探针已执行且四条断言全部 PASS，结论作为已知事实写入本计划「注意事项」并被 U1 起的各批次直接引用（`/tmp` 脚本按计划不入仓库、执行后删除）。要点：`:key-scope 'local` 确实吞掉未绑定 printing key，且吞键依赖 `etaf--keys-chain` 能从 point/focus 找到根 Host）
- [x] U0.2 探针 P2：`special-mode` + `buffer-read-only t` 与 etaf 渲染共存。同一脚本内 mount 后 `(special-mode)` + `(setq buffer-read-only t)`，再触发一次重渲染（改 ref 或直接调 `etaf-runtime-flush` 前后对比 buffer 文本），断言：无 error、文本被更新、`buffer-read-only` 仍为 t
      （依赖：U0.1）验收：PASS；若失败 → 记录实际错误，改用「不设 major mode、只设 read-only + 键层」的降级方案并在报告中说明
      （归档时补记：探针 PASS，未降级 —— `special-mode` + `buffer-read-only t` 可与 etaf 渲染共存（etaf 自身写入走 `inhibit-read-only`，首帧渲染未被阻断）。该结论在 U1.2 被实际依赖，并产出一处计划外必要偏离：mode 必须在 `etaf-mount` **之前**启用，否则 `kill-all-local-variables` 会清掉 `ebox--buffer-mount`）
- [x] U0.3 探针 P3：checkbox `:ref` 可取回。构造 `(etaf-checkbox :ref 'probe-check :checked nil :on-change (lambda (_) nil))`，mount 后 `(goto-char (point-min))` 用 `(ebox-node-at (point))` 找节点并向上用 `(etaf-runtime-node-host-ref runtime node)` 取 ref，断言得到 `probe-check`
      （依赖：U0.1）验收：PASS；若失败 → SPC 批次 U4 按「降级为 Tab+RET 勾选、SPC 只做提示」执行并在报告中说明
      （归档时补记：探针 PASS，未降级 —— checkbox 的 `:ref` 可经 `etaf-runtime-node-host-ref` 取回。U4 最终按「ref + dispatch」路径实现（步骤 0 探针附加确认 `etaf-activate` 按的是焦点宿主而非 point，故该函数被禁用），`SPC` 的降级问题实际由 `[32]` 属 `ebox--activation-keys` 的既有事实以换键（`t`）方式解决，与本探针无关）

### 批次 U1：buffer 身份与只读

- [x] U1.1 先写失败测试：`test/ebasecamp-ui-tests.el` 新增 `open-sets-ui-mode-and-read-only`（open 后 `major-mode` 为 `ebasecamp-ui-mode`、`buffer-read-only` 为 t）、`ui-buffer-swallows-insert-key`（`(etaf--keys-binding [?\i])` 返回 `#'ignore`；`(execute-kbd-macro (kbd "i"))` 后 buffer 文本不变）、`root-host-declares-local-scope`（键链最外层满足 `etaf--keys-boundary-p`）
      （依赖：U0.1、U0.2）验收：三项 FAILED（红）
      ✅ 已完成（2026-10-23）：红阶段实测 `Ran 315 tests, 312 expected, 3 unexpected`，三项恰好 FAILED（`major-mode` 为 `fundamental-mode`、`etaf--keys-chain` 返回 nil、`(etaf--keys-binding [?\i])` 为 nil），其余 312 项全绿
- [x] U1.2 实现：`lisp/ebasecamp-ui.el` 新增 `ebasecamp-ui-mode`（`special-mode` 派生，body 设 `buffer-read-only t`）、`ebasecamp-ui-mode-map` **仅重绑 `q`**（`g` 的兜底绑定随 U2.2 的函数实现同批加入，避免引用未定义函数击穿 `byte-compile-error-on-warn`）；`ebasecamp-ui-open` 在 `etaf-mount` 之后启用 mode；`ebasecamp-ui-app` 的 render 用最外层 Host（`box` 全 stretch）加 `:key-scope 'local` 与 `:keys`，统一包住 empty / 非 empty 两分支；顶层加 `with-eval-after-load 'evil` 设 `evil-set-initial-state`
      （依赖：U1.1）验收：U1.1 转绿；`make check` 全绿（check-parens + compile 零 warning + ERT 全绿）
      ✅ 已完成（2026-10-23）：`make check` 全绿（check-parens 22 文件 / byte-compile 零 warning / ERT 315 expected、0 unexpected）
      ⚠️ **两处与计划文本的偏离（均实测必要）**：
      ① **mode 在 `etaf-mount` 之前启用**（计划原写「之后」）。实测「mount 后设 mode」时 `special-mode` 的 `kill-all-local-variables` 会清掉 ebox 的 buffer-local 挂载状态（`ebox--buffer-mount`），随后 `ebox-focus-scope` / `ebox-node-at` 报 `user-error: No mounted Ebox tree in *ebasecamp*`，焦点与键层全部失效（`root-host-declares-local-scope` / `ui-buffer-swallows-insert-key` 因此转红）。改为 `(ebasecamp-ui-mode)` → `(etaf-mount ...)` 后全绿；只读仍在 mode body 内一次设好，etaf 自身写入用 `inhibit-read-only`（U0.2 结论），首帧渲染未被阻断。
      ② **本批次不加 `:keys`**（U2 才加），故 `q` 目前只有 `ebasecamp-ui-mode-map` 兜底、被 etaf 键层遮住：探针实测 `(lookup-key ebasecamp-ui-mode-map (kbd "q"))` = `ebasecamp-ui-close`，但 `(key-binding (kbd "q"))` = `ignore`，按 `q` 暂不关闭界面；U2.2 把 `q` 加进根 Host `:keys` 后恢复。

### 批次 U2：根级键位

- [x] U2.1 先写失败测试：`root-keys-complete`（**本阶段**键集合为 `q g n p I o D`（`e` 见 U5、`SPC` 见 U4，完整集合由 U6 断言），每条 `(nth 2 entry)` 为非空字符串，且整体能通过 `etaf--keys-validate` 不 signal）、`next-group-cycles`/`previous-group-cycles`（三组循环并回绕，另各带一条 `execute-kbd-macro` 按键断言）、`reload-key-reloads-and-refreshes`（`cl-letf` 计数 `ebasecamp-reload`，并断言不额外调用 `ebasecamp-ui-refresh`）、`q-key-is-bound`（`(etaf--keys-binding [?\q])` 非 nil 且非 `#'ignore`）
      （依赖：U1.2）验收：4–5 项 FAILED（红）
      ✅ 已完成（2026-10-23）：红阶段实测 `Ran 320 tests, 315 expected, 5 unexpected`，5 项恰好 FAILED：`root-keys-complete` / `next-group-cycles` / `previous-group-cycles`（`void-function`）、`q-key-is-bound` / `reload-key-reloads`（`(etaf--keys-binding …)` 返回 `ignore`，与 U1.2 偏离②的实测一致）
      ⚠️ 计划文本修订：原写「键集合为 `q g n p e I o D SPC`」有误 —— `e` 在 U5、`SPC` 在 U4 才实现，本批次按 `q g n p I o D` 断言；测试名按验收粒度拆成 `root-keys-complete` / `next-group-cycles` / `previous-group-cycles` / `reload-key-reloads` / `q-key-is-bound`（`reload-key-reloads` 只断言「重载被调用 + 不二次刷新」，不叫 `…-and-refreshes`）
- [x] U2.2 实现：`ebasecamp-ui--root-keys`（单一事实源，返回 `:keys` 列表）、`ebasecamp-ui--group-names`、`ebasecamp-ui--next-group`、`ebasecamp-ui--previous-group`、`ebasecamp-ui--reload-and-refresh`；`e`/`I`/`o`/`D` 直接绑现有 interactive 命令，`SPC` 绑 `ebasecamp-ui--toggle-at-point`（U4 实现，U2 先绑占位并在 U4 落地）；**同时**在 `ebasecamp-ui-mode-map` 里把 `g` 重绑为 `ebasecamp-ui--reload-and-refresh`（etaf 键层的兜底，随本任务函数一起落地）
      （依赖：U2.1）验收：U2.1 转绿
      ✅ 已完成（2026-10-23）：`make check` 全绿（check-parens 22 文件 / `compile` 零 warning（`byte-compile-error-on-warn t` 下 exit 0）/ ERT 320 expected、0 unexpected）。`--root-keys` 实际返回 `q g n p I o D` 七条（`e` / `SPC` 按上条修订留到 U5 / U4）；根 Host 现为 `:key-scope 'local :keys (ebasecamp-ui--root-keys)`；`--group-names` 返回 **symbol**（与 `selected-group` 同类型，取自 state 的 `:groups` 字符串名经 `intern`）；`--switch-group` 实现循环与回绕，清单为空时写 info notice「清单里没有组」；`--reload-and-refresh` 只调 `ebasecamp-reload`（内部已刷新界面，避免二次 `docker ps`）；`ebasecamp-ui-mode-map` 补 `g` 并在 docstring 记录「major-mode map 的 printing key 被 etaf runtime 键层遮住，不能作为兜底依赖（U1 实测 `(key-binding (kbd "q"))` = `ignore`）」
      ⚠️ 测试脚手架空子：`n`/`p` 用例的三组清单必须**同时定义一个项目** —— `ebasecamp-ui-open' 在 `ebasecamp-model-projects` 为空时会按 `ebasecamp-config-directory`（临时空目录）加载一次清单，把「只定义组」的注册表清空（实测表现为 `--next-group` 看到 0 个组）

### 批次 U3：段级键位

- [x] U3.1 先写失败测试：`section-keys-dispatch`（point 移到某段内后触发 `s`/`x`/`r`，`cl-letf` 打桩 `ebasecamp-ui--section-action`，断言收到 `(start|stop|restart, instance)` 且 instance 的 `:project` 正确）、`section-select-all`（`a` 后 selected-ref 含该段全部 `组名/服务名`）、`section-deselect-all`（`A` 后只移除该段的 keys，其它段不受影响）
      （依赖：U2.2）验收：三项 FAILED（红）
      ✅ 已完成（2026-10-23）：红阶段实测 `Ran 323 tests, 320 expected, 3 unexpected`，三项恰好 FAILED（`--section-action` 未被调用 → `calls` 为 nil；`selected-keys` 为 nil），其余 320 项全绿
      ⚠️ 两处与计划文本的偏离（均实测必要）：
      ① **定位锚点不是 `dev →`**：段头第一行的 `dev → 项目` 文案在**左树**里也有同名节点（`--config-caption`），`(search-forward "dev →")` 先命中左树，键链落到树 Host（`etaf--keys-binding` 返回 `ignore`），三键自然不命中。改用段头第二行的按钮文案「启动选中」作锚点（`--goto-section`，第 N 个参数用 `search-forward` 的 COUNT）。
      ② **`section-deselect-all` 用两个组而非同组两份配置**：同一组的两份配置共享 `组名/服务名` key（`--instance-key` 已声明该语义），「第一段 A 后第二段 keys 原样保留」在同一个组内无法成立（两段 key 集合完全相同）。改用 mysql（2 配置 / 2 服务）+ redis（1 配置 / 1 服务），流程为「第一段 `a` → 根级 `n` 切到 redis 组 → 该段 `a` → `p` 回 mysql 组 → 第一段 `A`」，断言只剩下 `("redis/redis")` —— 同时覆盖段级全不选只作用于本段与根级 `n`/`p` 的配合
      ③ 探针口径：`execute-kbd-macro` 在 batch 下于 **selected window 的 buffer** 执行（`with-current-buffer` 只够读文本），按键断言前必须用 `ebasecamp-ui-open` 显示界面 buffer；`etaf--keys-binding` 只接受**向量**（`[?s]`），传 `(kbd "s")`（字符串）恒返回 nil
- [x] U3.2 实现：`ebasecamp-ui--section-keys (instance)`（闭包捕获 instance，`a`/`A` 直接写 selected-ref）、`--instance-section` 的 `etaf-panel` 调用点加 `:keys`
      （依赖：U3.1）验收：U3.1 转绿
      ✅ 已完成（2026-10-23）：`make check` 全绿（check-parens 22 文件 / `compile` 零 warning（`byte-compile-error-on-warn t` 下 exit 0）/ ERT **323** expected、0 unexpected）。实现口径：
      - `ebasecamp-ui--section-keys (group-name instance)` 返回 5 条 `(KEY COMMAND LABEL)`：`s`/`x`/`r` → `--section-action` 传 `start`/`stop`/`restart`（捕获该段 instance），`a`/`A` → `--select-instance` 全选/全不选该段；闭包一律带 `(interactive)`
      - `--select-instance (session group-name instance &optional select)`：读 `selected-ref` 的现有字符串列表，用 `cl-set-difference` 求该段 key 集合的增量/差集后**一次** `etaf-set-value` 回写（不新造表示，与 `--toggle-selected` / checkbox 同一 ref、同一形态）
      - 段 Host 方案 = **方案 A**（`box` 包 `etaf-panel`），步骤 0 探针实测 A/B 都命中，按计划用 A
      - 步骤 0 探针附加结论：焦点在段内时键链从焦点起（`etaf--keys-chain` 的 local 分支），即「焦点在 A 段 + point 在 B 段」会命中 A 段 —— 与段内按钮一致性可接受，测试统一保持无焦点

### 批次 U4：行级切换勾选（方案 A 已落地：`t` 键 + 行 ref；`SPC` 归 ebox 内建激活）

- [x] U4.1 先写失败测试：`spc-toggles-checkbox-at-point`（point 定位到首个 checkbox 行后调 `ebasecamp-ui--toggle-at-point` → 选中集合含该 key，再调一次移除）、`spc-outside-checkbox-is-noop`（point 在顶栏时不改变选中集合、不写 notice）、`select-actions-has-no-stale-entries`（refresh 后 `select-actions` 的键集合等于当前渲染出的 checkbox ref 集合，删除组后无残留）
      （依赖：U0.3、U3.2）验收：两项 FAILED（红）或按 U0.3 降级方案改为断言 Tab+RET 可达
      ① 实际新增 4 条用例（`select-actions-has-no-stale-entries` 由 `checkbox-refs-are-stable` 取代，理由见 U4.2 ③）：`spc-toggles-checkbox-at-point`、`spc-outside-checkbox-is-noop`、`spc-does-not-press-section-buttons`（防误触，新增）、`checkbox-refs-are-stable`
      ② 红/绿阶段实测（`make test`）：**327 项、326 expected、1 unexpected**。三条绿（`spc-toggles-checkbox-at-point` 在实现前后都绿 —— 原因见 ③；`spc-outside-checkbox-is-noop` 绿；`checkbox-refs-are-stable` 红 → 实现后转绿）；`spc-does-not-press-section-buttons` **始终红**（见 U4.2 ⑤ 的阻塞结论）
      ③ 测试助手 `ebasecamp-ui-test--goto-first-checkbox` 的落点必须是 mark 内部（`[` 字符处）：实测 point 在 `[ ]` 之后的单元格边界上时最近的 Host 已不属于该 checkbox，`--checkbox-ref-at-point` 返回 nil；落在 mark 内时最近的 Host 是 mark 自己的**生成 ref**（`(etaf-host MOUNT-ID ID)`），必须沿 `ebox-node-parent` 向上才取到 checkbox 的显式 ref
- [x] U4.2 实现（方案 A 修订版，见 ⑧）：会话新增 `select-actions` 槽位（hash：ref → thunk），在 `ebasecamp-ui-close` / 重建会话时清理，**并在每次 `--select-cell` 渲染时对同一 ref `puthash` 覆写**（保证 refresh 后 thunk 始终指向当前 state 的关闭值，组/服务删除后不留过期条目）；`--select-cell` 给 checkbox 加稳定 `:ref`（命名 `ebasecamp-ui-check-<组名>/<服务名>`，与现有 `ebasecamp-ui-refresh`/`ebasecamp-ui-selected` 不冲突）；`ebasecamp-ui--toggle-at-point` 用 `ebox-node-at` + `etaf-runtime-node-host-ref` 向上找 ref 并调 thunk；`--root-keys` 的 `SPC` 指向它
      （依赖：U4.1）验收：U4.1 转绿
      ① 已实现（不含 `--root-keys` 的 `SPC` 条目，原因见 ⑤）：`ebasecamp-ui--checkbox-ref-prefix`（`"ebasecamp-ui-check-"`）、`ebasecamp-ui--checkbox-ref (key)`（`(intern (format "%s%s" prefix key))`）、`--select-cell` 给 `etaf-checkbox` 加 `:ref`、`ebasecamp-ui--checkbox-ref-at-point`（`ebox-node-at` → `etaf-runtime-node-host-ref` 判定前缀，未命中则 `ebox-node-parent` 上移，直到命中或到根）、`ebasecamp-ui--toggle-at-point`（interactive：ref 为 nil → 静默 no-op 不写 notice；否则 `etaf-dispatch-event runtime ref 'press`）
      ② 步骤 0 探针结论（`emacs -Q --batch` 最小 view，checkbox + button）：**P-a 成立**（point 在 checkbox → `etaf-activate` 触发 `:on-change`）、**P-b 成立**（point 在 button → `etaf-activate` 触发 `:on-press`）、**P-c：activate 按的是焦点宿主**（有焦点时 point 移到别处仍按焦点；无焦点时按 point 处节点的 `RET` 绑定）。按计划决策规则 P-b 成立 → `etaf-activate` 被禁用，走 ref + dispatch 路径
      ③ **替换 `select-actions` 槽位的理由**：checkbox ref 由 `组名/服务名` 派生（`intern`，与 `--instance-key` 同源），重渲染/refresh 后身份不变，`--checkbox-refs-are-stable` 已断言两次 refresh 后 ref 相同；`--toggle-selected` 本来就按 key 写 `selected-ref`，dispatch 到 ref 的既有 `:on-change` 闭包即可，故不需要「ref → thunk」登记表，也不存在过期条目问题（计划 U4.1 的 `select-actions-has-no-stale-entries` 因此由 `checkbox-refs-are-stable` 取代）。副作用：同组多份配置共享同一 ref（同 key），`etaf-dispatch-event` 只命中后注册的那个 handler —— 两者写的是同一个 key，视觉与状态一致（实测 dispatch 命中 1 个 handler）
      ④ **未完成 `--root-keys` 的 `SPC` 条目**（计划本项的最后一步），因为没有意义：见 ⑤（已被 ⑧ 取代：`SPC` 不再进本表，行级切换改绑 `t`）
      ⑤ ⛔ **阻塞（新发现，计划前提被推翻）**：`SPC` 在 etaf/ebox 画布里**无法**被 `:keys` 覆盖。实测（最小 view + 真实界面双重验证）：
        - root Host `:keys` 里的 `"SPC"` 命令**永远不执行**；同一 `:keys` 里的 `"z"` 立刻执行 → 键层本身正常
        - 原因是 ebox 把 `[32]`（SPC）注册进**节点级 char-property keymap**（`ebox--activation-keys '([13] [return] [32] [mouse-1])`，即 SPC 与 RET 一样是「激活」键），char-property keymap 在按键查找中先于 `emulation-mode-map-alists`（etaf 键层所在处）
        - 与节点类型相关：point 在**无 `:on-press` 的节点**（`text` / `etaf-label`）上时 etaf 键层生效（`"SPC"` 命令会执行）；在**可激活节点**（`etaf-button` / `etaf-checkbox`）上时一律走 ebox 激活
        - 真实界面实测：point 在「启动选中」按钮上按 `SPC` → `ebasecamp-ui--section-action 'start` **被调用**（会直接起容器）；`(etaf--keys-binding [?\s])` 与 `(key-binding (kbd "SPC"))` 都报 `ignore`（**introspection 报的是假象**，与真实派发不一致）
        - `etaf-button` 不接受 `:keymap` 覆盖（`etaf-component-call-error "Unknown prop or Host attribute :keymap"`），故无 per-node 覆盖途径
      ⑥ 三条可选处置（等用户/harspower 决策，本批次不擅自选）：
        - **A 换键**：勾选键改为 ebox/etaf 都未占用的 printing key（如 `t`），`--root-keys` 绑 `ebasecamp-ui--toggle-at-point`（已实现，ref 方案在任意键下均可用；`z` 对照探针证明同层键可达）
        - **B 拦截激活**：在 `ebasecamp-ui-mode` buffer 内 advice `ebox-activate`（`last-input-event` 为 `SPC` 且 `--checkbox-ref-at-point` 为 nil 时静默返回），保留 `SPC` 语义；代价是依赖 ebox 内部行为、且 `SPC` 在按钮上「无反应而 RET 有反应」的不一致
        - **C 接受 SPC=激活**：`SPC` 与 `RET` 等价（checkbox 上勾选 ✓、button 上会按下 ✗），删除 U4.1 的防误触断言并把它记入 `docs/troubleshooting`
      ⑦ 现状：机制（ref + dispatch + 静默 no-op）已落地并通过测试；~~`SPC` 键未接，`spc-does-not-press-section-buttons` 保持 RED~~（已被下方修订记录取代）
      **⑧ 修订记录（方案 A，2026-10-23 用户裁决，本批次收尾）**
        - **实测依据（`SPC` 被 ebox 占用）**：`[32]` 在 `ebox--activation-keys`（`'([13] [return] [32] [mouse-1])`）中，以节点级 char-property keymap 安装；按键查找里 char-property keymap 先于 `emulation-mode-map-alists`（etaf 键层）。因此 root Host `:keys` 里的 `"SPC"` 条目**永远不执行**（同表 `"z"` 立即执行 → 键层本身正常），且 `etaf-button` 不接受 `:keymap` 覆盖（`Unknown prop or Host attribute :keymap`），无 per-node 绕过途径。本轮 batch 探针复核：point 在「启动选中」按钮上按 `SPC` → `--section-action 'start` **被调用**（会直接起容器）；按 `t` → 未被调用。
        - **裁决**：方案 A —— `SPC` 保持 ebox 的「激活当前控件」语义（checkbox 上勾选、按钮上按下，与 `RET` 同义），**另加 `t` 作为行级切换键**（由我们的键层接管，在按钮上不会误触）。否决 B（advice `ebox-activate`：依赖 ebox 内部行为且 `SPC` 在按钮上「无反应而 RET 有反应」的不一致）与 C（直接接受 `SPC`=`RET`，放弃行级快捷切换）。
        - **实现**：新增 `--row-ref-prefix` / `--row-ref (key)`（`ebasecamp-ui-row-<组名>/<服务名>`）与 `--ref-at-point (&rest prefixes)`（沿 `ebox-node-parent` 向上取第一个前缀匹配的显式 ref 符号）；`--checkbox-ref-at-point` 退化为其薄封装；`--toggle-at-point` 命中 `check` 前缀 → 直接派发 `press`，命中 `row` 前缀 → 由 ref 名还原 key、拼出同行 checkbox ref、`(etaf-runtime-host-node runtime check-ref)` 非 nil 才派发，都不命中 → 静默 no-op；`--root-keys` 追加 `("t" ebasecamp-ui--toggle-at-point "切换勾选")` 并在 docstring 记明 `SPC` 由 ebox 内建处理、不在本表。
        - **`:row-ref` 的隐藏前提（新发现）**：`etaf-table` 只在 `interactive-p`（即传了 `:on-row-press`）时才采用调用方提供的 `:row-ref`（`etaf-ui--table-row-node` 的 `if interactive-p` 分支），否则行 Host 退回实例内生成 ref。故 `--service-table` **必须同时**传 `:on-row-press`；该钩子实现为 `--toggle-row`（切换该行勾选，与 `t` 写同一个 `--toggle-selected`），副作用是行变为可聚焦（`:tab-index 0`），顺带补上「服务行不可聚焦」这个原定缺口。
        - **`select-actions` 槽位已被取代**：checkbox/行 ref 由 `组名/服务名` 派生，重渲染后身份不变，`checkbox-refs-are-stable` 已断言两次 refresh 后 ref 相同 → 不需要「ref → thunk」登记表，也不存在过期条目（原 U4.1 的 `select-actions-has-no-stale-entries` 由它取代）。
        - **测试口径修正**：删除 `spc-toggles-checkbox-at-point`（语义并入 `spc-activates-checkbox`，改为守护 ebox 内建语义：point 在 `[ ]` 上按 `SPC` → 勾选/再按取消）与 `spc-does-not-press-section-buttons`（前提被否决），新增 `t-toggles-row-at-point`（point 在服务名单元格按 `t`）、`t-does-not-press-section-buttons`（point 在「启动选中」按钮按 `t`）、`t-outside-row-is-noop`（原 `spc-outside-checkbox-is-noop` 改名改键）；`root-keys-complete` 的键集合断言追加 `t`。红阶段 `Ran 328 tests, 326 expected, 2 unexpected`（`root-keys-complete` 无 `t`、`t-toggles-row-at-point` 无反应），实现后 `328 expected / 0 unexpected`。

### 批次 U5：编辑入口

- [x] U5.1 先写失败测试：`edit-manifest-opens-groups-and-locates-group`（`cl-letf` 打桩 `find-file`，断言参数为 `<dir>/groups.el` 且 point 落在含 `(ebasecamp-define-group <组名>` 的行）、`edit-manifest-errors-without-file`（无 `groups.el` 时 `user-error`，消息含目录路径与 `ebasecamp-create-sample-config`）、`edit-manifest-without-selected-group`（无选中组时 `user-error` 或提示先选组）
      （依赖：U3.2）验收：三项 FAILED（红）
      ✅ 已完成（2026-10-23）：红阶段实测 `Ran 332 tests, 328 expected, 4 unexpected`，4 项恰好 FAILED（三条编辑用例均为 `void-function: ebasecamp-ui-edit-manifest`；`e-key-is-bound` 的 `(etaf--keys-binding [?e])` 为 `#'ignore`），其余 328 项全绿
      ⚠️ 三处与计划文本的偏离：
      ① **新增 4 条用例而非 3 条**：补 `e-key-is-bound`（`(etaf--keys-binding [?e])` 非 nil 且非 `#'ignore`），与 U2 的 `q-key-is-bound` 同粒度
      ② **不打桩 `find-file`**：打桩只能断言参数、无法断言 point 落点；改为在临时目录用 `ebasecamp-create-sample-config` 写**真实** `groups.el`，再 `ebasecamp-ui-open`（内存注册表为空 → `--ensure-manifest` 从磁盘加载），断言 `(buffer-file-name)` 与 point 所在行文本，收尾 `kill-buffer` 该 buffer。定位断言依赖磁盘上 `(ebasecamp-define-group mysql` 的真实形态（样例清单是「单行头 + 缩进关键字」），不能用内存注册表替代
      ③ **消息措辞由测试反推**：首轮实现写「请先在左栏选择一个组」，测试断言「选中」不过（「选择」≠「选中」）；改为「请先在左栏选中一个组」后转绿
- [x] U5.2 实现 `ebasecamp-ui-edit-manifest`（interactive），`e` 加入 `--root-keys`
      （依赖：U5.1）验收：U5.1 转绿
      ✅ 已完成（2026-10-23）：`make check` 全绿（check-parens 22 文件 / `compile` 零 warning（`byte-compile-error-on-warn t` 下 exit 0）/ ERT **332** expected、0 unexpected）。实现口径：
      - 函数体 **12 行**（不含 docstring）：取 `selected-group` → 两条 `user-error` → `find-file` → `goto-char (point-min)` → `search-forward "(ebasecamp-define-group <组名>"`（命中即停在该行；未命中回 `point-min` + `message`），返回 `(current-buffer)`
      - **三条错误路径**：① 无选中组 → `user-error "请先在左栏选中一个组"`；② 文件不存在（`file-regular-p` 为 nil）→ `user-error "清单文件不存在：%s；先 M-x ebasecamp-create-sample-config"`（`%s` 为绝对路径）；③ 文件里找不到 `(ebasecamp-define-group <组名>` → `goto-char (point-min)` + `message "未在 groups.el 中找到组 %s 的定义"`，**不 signal**（清单可手写、组也可能不在 groups.el，定位失败不该阻断编辑）
      - **「唯一写入口」措辞**：docstring 明写「这是界面**唯一的写入口**：界面 buffer 是只读的（见 `ebasecamp-ui-mode`），写只能发生在 `emacs-lisp-mode` 的清单 buffer 里；保存后按 `g` 重载清单并刷新界面。本函数只打开文件，不读取也不打印任何密钥值。」
      - `--root-keys` 的 `e` 插在 `p` 之后、`t` 之前，LABEL「编辑当前组清单」；**root keys 现为 9 条**：`q g n p e t I o D`（计划预估「8 条」应为 9 —— U2 收尾时已是 8 条，追加 `e` 后 9 条，此处按实测记）
      - U2 的 `root-keys-complete` 断言同步加入 `e`（集合 `D I e g n o p q t`）：它是**阶段内集合断言**，不随实现更新会恒红；U6 的最终集合断言未动（尚未编写）
      - `e` **不**加进 `ebasecamp-ui-mode-map` 兜底：printing key 被 etaf runtime 键层遮住（U1 实测 `(key-binding (kbd "q"))` = `ignore`），兜底无意义，`q`/`g` 的既有兜底保持原样

### 批次 U6：帮助与可发现性

- [x] U6.1 测试：`all-keys-have-labels`（`--root-keys` 与 `--section-keys` 的每条第三元素为非空字符串）、`help-data-includes-root-labels`（`etaf-help-data` 的输出含「关闭界面」「重载清单并刷新」「编辑当前组清单」「切换勾选」；若 batch 下该 API 不可用，则改为断言 `--root-keys` 的 LABEL 集合）；**最终集合断言为 `q g n p I o D t e`**（含 `e` 与 `t`；`SPC` 走 ebox 内建激活、不在本表，见 U4.2 ⑧。U2 阶段只断言 `q g n p I o D`，见 U2.1 修订）
      （依赖：U5.2）验收：两项 PASS
      ✅ 已完成（2026-10-23）：实测新增 **5 条**用例（U6.1 四条 + U6.2 一条），`make test` 337 expected / 0 unexpected（U5 基线 332 → **+5**，比计划预估 +3/+4 多一条，因为 U6.2 的可自动化条件成立、不需要降级）。用例名按实际粒度：
      - `all-keys-have-labels`：root 9 条 + section 5 条逐条断言 `(nth 2 entry)` 为非空字符串、`(nth 1 entry)` `commandp`（段级闭包必须带 `(interactive)`，`etaf--keys-run` 对 commandp 用 `call-interactively`）、两份表各自 `(equal keys (etaf--keys-validate keys))` 不 signal
      - `root-keys-final-set`：`key-description` 归一 + `sort` 后**精确等值** `("D" "I" "e" "g" "n" "o" "p" "q" "t")`（9 条，长度也断言），并显式断言 `"SPC"` / `"RET"` **不在**本表（docstring 写明 `[32]` 属 `ebox--activation-keys`、由 ebox 内建激活处理，行级切换用 `t`）
      - `help-data-includes-labels`：point 在顶栏区时 `etaf-help-data` 收集到全部 **9 条根级 LABEL**；point 移入第一段后 5 条段级 LABEL 一并出现（段键与根键不重叠，不互相 shadow）
      - `help-key-is-available`：`(etaf--keys-binding [??])` 非 nil 且非 `ignore`（`[??]` 即事件向量 `[63]`）
      - 四条 U6.1 用例**天然绿**（实现已完备），属**守护性用例**：它们防的是「后续批次加键忘写 LABEL」「键表多绑/少绑」「`etaf-help` 因缺 LABEL 静默丢条目」——计划要求「只有 `root-keys-final-set` 若与现状不符才应红」，实测现状即目标集合，故无红阶段；`make test` 首轮唯一红项来自 U6.2（见下）
      ⚠️ 一处与计划文本的偏离：`all-keys-have-labels` 的段级表用 `(ebasecamp-ui--section-keys "mysql" instance)`，instance 取自 `ebasecamp-ui-test--instances`（state 的 `:instances`，与渲染期同一份数据），而不是自造 plist —— 自造 plist 会让 `:records` / `:project` 与真实段头脱节，断言价值下降
- [x] U6.2 若 `?` 在 batch 下可挂载（modal surface），补一条 `help-surface-mentions-keys`；不可挂载则记录原因，目检覆盖
      （依赖：U6.1）验收：用例存在且未 skip，或报告写明不可自动化的原因
      ✅ 已完成（2026-10-23）：**可挂载，未降级**。batch 探针（`/tmp/probe-u6-help.el`，不入仓库）与用例双重确认：`(etaf-help)` 在 `emacs -Q --batch` 下立即挂载只读 catalog（`etaf-next-tick` 在 batch 之外立刻执行，无需手工 flush），buffer 文本变为「│ 快捷键 · 只读  x  │ … 应用操作 · ebasecamp … 关闭界面 │ q │ …」，`etaf-help-close` 后 `etaf--help-state` 清空且 buffer 文本**逐字符复原**。
      ⚠️ **帮助面按可用视口裁剪条目**（实测）：同一用例单独跑首屏渲染 5 条根级键，全量运行只渲染 4 条（「编辑当前组清单」被裁掉）—— 裁剪量随窗口可用行数变化。因此 `help-surface-mentions-keys` 只断言「快捷键」标题 + 首屏**必然出现**的 4 条 LABEL（关闭界面 / 重载清单并刷新 / 下一个组 / 上一个组）+ 打开前后文本变化 + 关闭后复原；全量 LABEL 核对交给 `help-data-includes-labels`（数据快照，不经视口裁剪）。这是本批次唯一一处「红 → 改断言口径」的调整，**没有**删除任何断言、也没有放宽为「包含任意子集」（仍逐条 `member` + `contains-p`）。

### 批次 U7：文档与目检

- [x] U7.1 `Readme.org`：新增「界面键位」表（根级 + 段级）+ 一句「界面只读，改配置用 `e`」
      （依赖：U6.2）
      ✅ 已完成（2026-10-23）：新增顶层节「界面键位」（`Readme.org` L236–283，48 行），插在「命令表」与「安全约束」之间，含总述（只读 + `e` 是唯一写入口 + `?` 看全部键位）、根级键位表 13 行（`q`/`g`/`n`/`p`/`e`/`t`/`I`/`o`/`D`/`?`/`TAB`+`S-TAB`/`RET`/方向键/`C-x`+`M-x`+`C-g`+`ESC`）、段级键位表 5 行（`s`/`x`/`r`/`a`/`A`）、`SPC` 单段说明（等价 `RET`，不是勾选键、不能当 leader 前缀）、编辑清单三步流程（`e` → 改 → 保存 → `g`）。未动「命令表」的条目与计数（该表在本次改动前已 stale，见下方 U7.3 的说明）
- [x] U7.2 `docs/user-guide.org`：键位表 + 编辑流程（`e` → 改 → 保存 → `g`）+ 「为什么按 `i` 不会进 insert」
      （依赖：U6.2）
      ✅ 已完成（2026-10-23）：新增顶层节「界面操作与键位」（`docs/user-guide.org` L281–365，85 行），插在「界面操作」与「常见任务」之间，按操作流程组织 8 个小节：打开与生成清单 / 切换组（说明组节点 `RET` 是展开不是选中）/ 勾选服务（`t`、点 `[ ]`、`SPC` 三条等价路径）/ 生命周期（`s`/`x`/`r` 与段头按钮、未勾选提示「未选中服务」、`start` 前端口冲突检查）/ 编辑配置（`e` 是唯一写入口，三条失败路径逐条说明）/ 退出与帮助（`q` 停轮询、`?` 帮助按视口裁剪）/ 为什么按 `i` 不会进 insert（三层机制）/ 已知边界表（同组多配置共享选中 key、段级键跟随焦点、`SPC` 被 ebox 占用、段外无提示、无界面编辑器）
- [x] U7.3 `docs/architecture.org`：新增「UI buffer 身份与键位分层」节（三层键位优先级、`:key-scope 'local` 吞键条件、read-only 与 ebox 渲染的 `inhibit-read-only` 关系、编辑入口边界）
      （依赖：U6.2）
      ✅ 已完成（2026-10-23）：新增顶层节「UI buffer 身份与键位分层」（`docs/architecture.org` L198–260，63 行），插在「刷新链路」与「已删除 / 不再使用的机制」之间，9 个小节：buffer 身份（`special-mode` 派生 + `buffer-read-only`，mode 必须在 `etaf-mount` 之前启用，否则 `kill-all-local-variables` 清掉 `ebox--buffer-mount` → `No mounted Ebox tree`，而渲染断言仍全绿）/ 键位三层与优先级表 / 吞键条件（边界 Host、必须在最外层、无焦点以 `ebox-focus-scope` 兜底）/ mode-map 只作装饰（`lookup-key` 命中但 `key-binding` 为 `ignore`）/ `SPC` 不可重绑（`[32]` 属 `ebox--activation-keys`、`etaf-activate` 按焦点宿主、`etaf-button` 不吃 `:keymap`）/ `t` 的实现前提（`:row-ref` 需 `:on-row-press`）/ 段级键与按钮同源（捕获 instance，无「当前段」全局状态）/ 焦点优先于 point / 编辑入口边界。
      ⚠️ 附带的一处事实同步（超出原任务文本、按实测修正）：`模块公开 API` 表按 HEAD 实测把 `=ebasecamp-ui.el=` 行由 11 改为 14（补 `ebasecamp-ui-report-counts` / `ebasecamp-ui-edit-manifest` / `ebasecamp-ui-mode`，其中 `-mode` 注明「buffer 身份与键位」），总数 69 → 72；未重排表格。该表在本次改动前已 stale（U1–U6 新增的 3 个公开符号未记入）。「命令表」（Readme，声称 13 个）同样已 stale（实测非私有 interactive 16 个，缺 `report-counts` / `edit-manifest` / `ui-mode`），按任务「不改既有章节」的约束**未**在本批次修，留待单独任务
- [x] U7.4 新建 `docs/adr/0003-ui-readonly-keymap.org` 并在 `openspec/decisions.md` 追加对应决策行（含 4 条否决备选：①只 `setq buffer-read-only` 不加 major mode；②用 `evil-define-key` 硬依赖 evil；③把键位绑在 major mode map 而非 etaf Host keys；④界面内做清单编辑器）
      （依赖：U7.3）
      ✅ 已完成（2026-10-23）：`docs/adr/0003-ui-readonly-keymap.org` 新建，**51 行 / 9832 字节**、**5 个顶级节**（背景 / 决策（6 条）/ 后果（`** 正面` + `** 代价与已知边界`）/ 备选方案与否决理由（**6 条**）/ 状态），格式对齐 ADR-0001 / 0002（`#+title` / `#+date` / `#+status: 已接受（Accepted）`，`*` 节 + `**` 子节，`=…=` 行内标记）；引用 ADR-0001 / ADR-0002、技术债 #20 / #25 / #26，并指向计划与 `docs/architecture.org` 的「UI buffer 身份与键位分层」节。否决备选在计划的 4 条之外补了 2 条实测否决：⑤ advice `ebox-activate` 拦截 `SPC`；⑥ 用 `etaf-activate` 兼作勾选键（按焦点宿主 + 会按按钮）。`org-lint` **0 issue**。`openspec/decisions.md` 追加 **2 行**（2026-10-23：主决策「UI buffer 只读 + etaf Host keys + 唯一写入口 `e`」→ 详见 ADR-0003；否决「用 evil 依赖解决 insert 问题」），`SPC` 裁决写进主决策行理由的第 ③ 点
- [x] U7.5 `AGENTS.md`：不变量新增「UI buffer 必须只读，并以 `:key-scope 'local` 吞 printing key；写操作只允许经 `e` 打开的清单文件」；更新目录说明与「当前状态」
      （依赖：U7.4）
      ✅ 已完成（2026-10-23）：不变量第 **12** 条（沿用现有编号风格，`12. **UI buffer 必须只读**…`）；（「目录结构」的 `docs/` 行补 `0003-ui-readonly-keymap.org` 并与 0001 / 0002 并列；「当前状态」改为 v0.3 计划 U7 文档完成阶段 + ER 基线 337 + ADR-0003 已建 + `ebasecamp-m1-m3.md` 已归档。⚠️ 一处与任务文本的偏离：原任务假设 `AGENTS.md` 有「已知特性（勿当作缺陷）」表 —— 实际没有（那张表在 ECA 仓库的 AGENTS.md 里），故**新建**同名节并写入两行（`SPC` = `RET`、未绑定字母键被吞），而不是往不存在的表里追加
- [x] U7.6 `docs/troubleshooting.org`：新增两条（「按 `i` 进了 insert state」「界面内按键无反应 / 为什么 `SPC` 不切换勾选（用 `t`）」）
      （依赖：U7.3）
      ✅ 已完成（2026-10-23）：按现有「现象 / 原因 / 排查命令 / 修法」四段式新增 **3 条**（第 11–13 条，均在「相关文档」节之前）：11「按 =i= 进了 insert state，界面里能打字」（含三层键位优先级表 + `major-mode` / `etaf--keys-binding` 排查命令）、12「界面内按键无反应 / =SPC= 没有切换勾选」（三条机制：未绑定 printing key 被吞、`[32]` 属 `ebox--activation-keys`、段级键只在段内且跟随焦点）、13「组节点按 =RET= 只展开不选中」（第三条为任务里的可选项，一并写）。`org-lint` 0 issue
- [x] U7.7 `CHANGELOG.md` 增加 0.3.0 条目；`ebasecamp.el` 与相关文件头 `Version:` 同步为 0.3.0
      （依赖：U7.5、U7.6）
      ✅ 已完成（2026-10-23）：`CHANGELOG.md` 新增 `## [0.3.0] - 2026-10-23`（Keep a Changelog + 中文小节名，与 0.2.0 一致），含 5 条「新增」（根级 9 键 / 段级 5 键 / `t` / `e` / `?`）、6 条「变更」（mode + 只读、`q`/`g`、行可聚焦、`SPC`=`RET`、吞 printing key、文档与决策）、4 条「修复」（insert state、无法切组、无段级键、无编辑入口）。版本同步：`ebasecamp.el` + **10 个** `lisp/*.el` 的文件头 `;; Version:` 全部 0.2.0 → **0.3.0**（`grep -rn '^;; Version:'` 11 行全部命中 0.3.0）。附带修正 `Readme.org` 命令表：计数由「13 个（`fboundp` 实测）」改为「**16** 个（`commandp` 实测，`emacs -Q --batch` 加载后统计非私有的 `ebasecamp*` 命令；`ebasecamp--*` / `ebasecamp-ui--*` 不计）」，补 `ebasecamp-ui-report-counts` / `ebasecamp-ui-edit-manifest` / `ebasecamp-ui-mode` 三行（13 + 3 = 16，与实测吻合；另有 4 条 `ebasecamp-ui--*` 私有交互命令按口径不计）
- [x] U7.8 用户目检（L3）：**冷启动（打开界面后未做任何 Tab/方向键操作）即按 `i` 不进 insert**；Tab 能遍历树/段按钮/checkbox；`s`/`x`/`r` 生效；`a`/`A` 生效；`t` 在行内任意位置切换该行勾选；`SPC` / `RET` 在 checkbox 上勾选、在按钮上按下（ebox 内建激活）；点击行或焦点在行上按 `RET` 也切换勾选；`e` 打开 groups.el 并定位；`q` 关闭后无残留轮询；`?` 显示帮助
      （依赖：U7.7）验收：用户确认
      （归档时补记：用户目检由 v0.4 期间的实机使用承接 —— 本计划的只读 / 键位 / 行内勾选 / `e` 编辑入口等行为在 v0.4「布局、主题与导航」两轮重构中持续实机使用，用户在 v0.4 的 D7 逐项确认 6 项目检全部通过；冷启动不进 insert、`SPC`=`RET` 等要点亦作为「已知特性」固化进 `AGENTS.md`。故归档时勾选）
- [x] U7.9 计划卫生：把 `openspec/active/ebasecamp-m1-m3.md` 归档到 `openspec/completed/`，勾选其中 T5.2 并注明「由 v0.2 E1 覆盖完成」。**前置核对**：先确认 `docs/architecture.org` / `docs/user-guide.org` / `docs/compose-generation.org` / `docs/troubleshooting.org` 四份文件均存在且非空（`ls -l`），否则不归档并报告
      （依赖：无，可与任意批次并行）验收：四份文档核对通过；`openspec/active/` 下只剩本计划；归档文件含说明
      ✅ 已完成（2026-10-23）：前置核对通过 —— `architecture.org` 26737 B / `user-guide.org` 26730 B / `compose-generation.org` 24425 B / `troubleshooting.org` 23338 B，四份均非空。`git mv openspec/active/ebasecamp-m1-m3.md openspec/completed/ebasecamp-m1-m3.md`（全程唯一的 git 写操作）；归档文件内 `T5.2` 勾选为 `[x]` 并追加「由 v0.2 的 E1 文档批次覆盖完成（…）」，其「## 当前状态」改为「**已归档 —— T5.2 由 v0.2 E1 覆盖，计划关闭**」并把「下一步」改为「无（计划关闭）」。⚠️ **验收第 2 条未达成**：`openspec/active/` 归档后仍有 **2 份**文件 —— 除本计划外还有 `2026-10-22-group-centric-ui.md`（v0.2 组为中心界面，AGENTS.md 记为「进行中、C7 目检待用户确认」）。任务文本只授权归档 `ebasecamp-m1-m3.md`，故**未**动该文件，需 harspower 决定是否一并归档

## 文档清单

| 文档 | 本计划触发的更新 |
|---|---|
| `Readme.org` | 界面键位表（根级 / 段级）+ 只读说明 |
| `docs/user-guide.org` | 键位表、编辑流程、insert 为何不出现 |
| `docs/architecture.org` | UI buffer 身份与键位分层（三层优先级、吞键条件、只读与渲染的关系） |
| `docs/adr/0003-ui-readonly-keymap.org` | 新 ADR：只读 buffer + etaf Host keys + 唯一写入口 |
| `openspec/decisions.md` | 追加本次决策与 4 条否决备选 |
| `AGENTS.md` | 不变量新增「UI buffer 只读 + local 吞键」；当前状态更新 |
| `docs/troubleshooting.org` | 新增「按 i 进 insert」「按键无反应」两条 |
| `CHANGELOG.md` | 0.3.0：界面只读化、完整键位、编辑入口 |
| `openspec/tech-debt.md` | #26 补充「本次只提供打开清单文件的入口，不做界面内编辑器」 |

## 验证标准

- **L1**：`make check-parens`（文件数以实际输出为准）+ `make compile`（`byte-compile-error-on-warn`，零 warning）
- **L2**：`make test` 全绿（新增用例数 ≥ 12），其中键位/只读/编辑定位全部自动化；`etaf--keys-binding` 等内部 API 若签名变化，降级为 `execute-kbd-macro` 断言（须在报告中说明）
- **L3**：用户目检 8 项（见 U7.8）。evil 行为在 batch `emacs -Q` 下无法验证（无 evil），只能由目检覆盖——报告中必须写明这一限制
- 每批次结束更新本文件「当前状态」区块

## 注意事项

- **不能绑框架保留键**：`escape`、`M-g`、`C-g`、`?`、`Tab` 系列、四个方向键由 etaf 拥有，`etaf--keys-validate` 会 signal；需要方向语义时用 `:on-direction`。
- `:keys` 的 COMMAND 必须是 `functionp` 且**无参**（`etaf--keys-run` 用 `call-interactively` 或 `funcall`），因此段级键用闭包、根级键用 interactive 命令。
- `:keys` 的第三元素 LABEL 是可发现性的唯一来源；`etaf-help` 会**跳过没有 LABEL 的条目**。
- 会话 `select-actions` 是新增槽位，必须在 `ebasecamp-ui-close` 与 `ebasecamp-ui--new-session` 两侧对称处理，避免闭包泄漏（hash 用 `:test 'eq`，条目随会话销毁）。
- checkbox 的 `:ref` 命名必须与现有 ref（`ebasecamp-ui-refresh` / `ebasecamp-ui-selected` / `ebasecamp-ui-state` / `ebasecamp-ui-expanded` / `ebasecamp-ui-busy` / `ebasecamp-ui-notice` / `ebasecamp-ui-confirm`）不冲突；建议前缀 `ebasecamp-ui-check-`。
- `ebasecamp-ui-mode` 的 `q` 必须是 `ebasecamp-ui-close`（kill buffer + 停轮询 + 销毁会话），不是 `quit-window`；`special-mode` 的默认 `q` 必须被覆盖。
- 只读设置在 `etaf-mount` **之后**；若首帧渲染被 read-only 阻断，改为 mount 前设 mode、mount 后设 read-only，并在报告中记录实际顺序。
- 测试环境：所有 UI 用例沿用现有 `ebasecamp-ui-test--with-ui` 宏与 batch `etaf-mount`；`make` 变量 `STRAIGHT_BUILD` 指向 `~/thomas-emacs/.local/straight/build-31.1`，若 etaf 版本更新导致 `etaf-app` 缺软链，按 v0.2 计划 E 段的记录处理（先 `M-x straight-rebuild-package "etaf"`），不要改 Makefile。
- 不修改 `thomas-emacs` 仓库任何文件；`SPC t e e` 保持原样（本计划只在 `ebasecamp` 侧加 buffer 内键位）。
- 安全约束不变：清单只保存 `${VAR}` 引用与相对路径，编辑入口只打开文件，不读取也不打印任何密钥。
- **focus 边界**：吞键依赖 `etaf--keys-chain` 能从 point/focus 找到根 Host；若 U0.1 第三断言失败（focus 为 nil 且 point 在无节点区），必须给出缓解方案（例如在 `ebasecamp-ui-open` 里把 point 置于首个 Host 内，或补一层 evil 条件绑定）后再进入 U1。
