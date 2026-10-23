# ebasecamp v0.4 — 布局、主题与导航（UI 骨架重构）

## 当前状态

- 已归档（2026-10-23）：D7 用户目检 6 项全部通过；代码审查 important 已修复（358/358 全绿）。
- 阶段：**已完成（Phase 4）**（D1–D7 全绿：五份文档改完 + 新 ADR + decisions 5 行 + CHANGELOG 0.4.0 + 11 个 `Version:` 头同步 + 用户目检 6 项全部通过；计划已归档到 `openspec/completed/`）
- 已确认：方案框架 ✅（用户 2026-10-23 选择「v0.4 → v0.5 → v0.6 串行」；待确认点 B/C/D 按默认值写入，用户未否决）；计划 ✅
- 已完成：批次 L0（布局探针）+ 批次 L（L1.1–L1.4）。要点：**根节点必须是 `flex :flex-direction 'column`**（`column` / `row` 不走 flex 分配）、顶栏与底栏都要 `:flex-shrink 0`、中间区 `:flex-grow 1 :min-height '(lh 0)` 承担全部收缩、splitter 的 slot pane 必须显式 `:height 'stretch`、batch 断言必须 `(let ((ebox-viewport-height N)) …)` 固定视口
- 已完成：批次 T（主题配色）。要点：**`etaf-theme-provide` 只能在 `:setup` 阶段调用**（render 期会被 `etaf--assert-not-rendering` 拒绝：`etaf-render-side-effect-error (provide-context)`）、传 `etaf-ref` 本身即保留响应式（节点身份不变、属性刷新）、batch 下 `default` 的前景背景是**字符串伪色** `"unspecified-fg"` / `"unspecified-bg"`（不是符号 `unspecified`）、`load-theme` 加载 modus 会改写 `background-mode` 帧参数（dark ↔ light）因而 palette 随之切换、`mode-line-inactive` 背景是唯一真正可用的「面板/边框」face 来源（`fringe` / `shadow` 前景在默认主题与 modus 下都是 `unspecified`）
- 已完成：批次 W（左栏宽度与持久化）。要点：**`etaf-splitter` 的 `:on-change` 收到的是原始手势 plist**（`:phase' / `:position' 像素 / `:delta' / `:node' / `:keyboard'），不是 ratio 数字；指针按「X − 容器左边」/ 容器宽折算、键盘按「当前比例 + DX / 容器宽」；ratio 由会话槽位 `split-ratio`（`etaf-ref`）承载，`:ratio` 传 **ref 本身**（只有 splitter 重渲染）；持久化到 `<ebasecamp-cache-directory>/ui-state.el`（`(:split-ratio FLOAT)`，`make-temp-file` + `rename-file` 原子覆盖），钳制 `[0.15, 0.55]`；**Emacs 31.1 已无 `read-eval` 变量**（`boundp` = nil，照计划写会让「变量未使用」被 `byte-compile-error-on-warn` 判死）且 `#.` 读语法默认禁用，改用「读前拒绝 `#.`」达成同一安全语义
- 已完成：批次 N（区域跳转）。要点：**`etaf-focus-within` 的 nil COUNT 就是「子树第一个停靠点」**（不需要 count）；缺失 Host 会 `user-error`（`etaf--event-host-node`），所以调用前必须判 `(etaf-runtime-host-node runtime ref)` 非 nil；runtime 必须取自**当前 buffer**（`etaf-runtime-for-buffer (current-buffer)`，非 UI buffer 里自然 no-op）；真实停靠点是区域内的普通 `box`（生成 ref `(etaf-host 1 N)`）而非区域 Host 本身，断言只能写「焦点落在区域子树内」；`1`/`2`/`3` 走三个零参命令（`etaf--keys-run` 对 commandp 条目用 `call-interactively`，带 interactive 参数的函数直接绑键会先弹 `completing-read`）
- 已完成：批次 P（项目上下文默认定位）。要点：`ebasecamp-ui--project-for-directory` 走「`expand-file-name` + `file-truename` 归一 → `file-name-as-directory` 形态 → `string-prefix-p`（**不传 IGNORE-CASE，大小写敏感**）→ 取最长 root」，`/tmp/a2` 不会被 root `/tmp/a` 误命中、root 为空/不存在跳过；`--first-group-for-project` 按**组定义顺序 + 组内 `:configs` 顺序**取首个 `:project` 命中者；**`--project-for-directory` 返回项目对象、`--first-group-for-project` 吃项目名**（类型不一致首版导致静默 nil，现调用点传 `ebasecamp-project-name` 且函数内防御性接受对象）；**回退语义 = 保持既有「无选中组」**（计划原文「第一个组」会删掉未选中态并让 4 项占位断言变红）；只在 `--new-session` 算一次，`refresh` / `g` / 现有会话重开都不覆盖手选组，`close` 后重开才重算
- 已完成：批次 D（D1–D6，文档与仓库治理）。要点：**只改文档 + `Version:` 头，不动任何代码逻辑**——`lisp/ebasecamp-ui.el` 的改动仅是 `;; Version: 0.3.0 → 0.4.0`。落点：`Readme.org`（新增「界面布局」「主题」「在项目中打开」三节 + 根级键位表补 `1`/`2`/`3`）、`docs/user-guide.org`（新增「布局与导航」，用户视角五条）、`docs/architecture.org`（新增「布局与主题」76 行六子节；另补不变量第 12/13 条与 ADR-0003/0004 链接——第 12 条此前只在 AGENTS.md 有、本文档漏记）、`docs/adr/0004-ui-layout-theme.org`（70 行，格式对齐 ADR-0003）、`openspec/decisions.md`（5 行，按决策逐行，与 ADR-0001/0002 粒度一致）、`CHANGELOG.md`（0.4.0）、`AGENTS.md`（不变量第 13 条 + ADR-0004 索引 + 当前状态）。**口径统一**：所有描述均以计划 L/T/W/N/P 批次的实测记录与 `lisp/ebasecamp-ui.el` 的实现为准（如 `etaf--assert-not-rendering`、`(:split-ratio FLOAT)`、`[0.15, 0.55]`、`35 token`、`12 条根级键`），不含推测值
- **测试基线：357**（`make check` 357/357 全绿、compile 零 warning；原基线 354，本批次 +3：`open-selects-project-group` / `open-falls-back-when-no-project` / `open-falls-back-when-project-has-no-config`；批次 D 只改文档，基线不变）
- 代码审查修复：defcustom 越界钳制（测试 +1，基线 358）。`ebasecamp-ui--load-ui-state` 的 fallback 分支、`--current-split-ratio` 的无会话分支、`--new-session` 写 `split-ratio` ref 前都过 `--clamp-ratio`（非数字回退 0.26），因此 `(setq ebasecamp-ui--split-ratio 0.9)` 不再让 `etaf-splitter` 的 `:ratio` 校验在渲染期 signal；新用例 `ebasecamp-ui-test-split-ratio-defcustom-out-of-range-clamped`，`make check` 358/358 全绿、compile 零 warning；遗留两条债见 `openspec/tech-debt.md` #29 / #30
- 代码审查收尾 nit（2026-10-23）：`ebasecamp-ui--save-ui-state` 的 fallback 分支原写 `ebasecamp-ui--split-ratio`（defcustom 原值，`--current-split-ratio` 已保证非 nil，该分支是 dead code），改为字面量 `0.26`，与 `--load-ui-state` / `--current-split-ratio` / `--new-session` 三处钳制口径统一；不改其它逻辑，`make check` 358/358 不变
- 下一步：**已归档**——用户目检 6 项通过、代码审查 important 已修复，v0.2 / v0.3 / v0.4 三份计划已移入 `openspec/completed/`；后续 v0.5（写操作）/ v0.6（观测）待规划
- 前置：v0.3（界面只读 + 完整键位 + 唯一写入口）六批次已完成；v0.3 计划与 v0.2 计划待本计划完成后一并归档
- 回滚点：只改 `lisp/ebasecamp-ui.el`、测试与文档；不动 model / config / compose / command / docker
- 执行要求：每个批次改动前创建 git 安全点（记录 `git status --porcelain` + 备份本批次涉及文件到 `/tmp/ebc-uibak-<时间戳>/`）；验证失败先回滚再报告

## 目标

1. **布局**：底栏（导入 / 导出 / 销毁 + 提示行）常驻窗口底部；中间区域自适应剩余高度；左树与右栏各自**内部滚动**，整窗不再滚动。
2. **主题**：颜色从 Emacs face 取，`load-theme` 切换后即时跟随；清除硬编码色值。
3. **左栏宽度**：默认 0.26（现 0.38），可拖动调整并记住（跨会话）。
4. **区域跳转**：`1` / `2` / `3` 分别跳到左树 / 右栏 / 底栏的首个停靠点。
5. **项目上下文**：在某个项目目录内打开界面时，默认选中该项目关联的第一份配置所在组。

## 非目标

- 写操作（编辑 container 配置、移动配置、分组/配置/项目 CRUD）→ v0.5
- project 监控与日志查看 → v0.6（第 7 条整条：「监控默认不显示，用快捷键唤出」）
- 修改 etaf / etaf-ui / ebox 源码
- 修改清单格式或清单写盘路径（本计划不写清单）
- 键位自定义（defcustom 键表）

## 现状与根因

截图与代码证据：

| 现象 | 根因 |
|---|---|
| 滚到底才能看到「导入 compose / 导出 compose / 销毁环境」 | 根视图是一个普通 `column`，高度随内容增长；底栏排在树之后，没有「中间区 flex 撑满 + 底栏固定」的约束（`ebasecamp-ui-app` 的 render） |
| 配置多时整窗滚动、左树跟着滚走 | 左树与右栏都没有 `:overflow 'scroll'` 限高容器；etaf 只有「最内层滚动器优先」的滚轮链（`ebox--scroll-chain`），没有限高容器时唯一滚动器就是窗口 |
| 暗色主题下界面发白 | 硬编码色值：`"#F8F5EE"`（背景）、`"#252A2E"`（前景）等直接写在 Host 属性里 |
| 左栏占 0.38 却只有一行内容 | `ebasecamp-ui--split-ratio` 常量 0.38（为容纳旧写法文案调的） |
| 无区域跳转、无项目上下文 | 三区域没有 `:ref`；open 时只按 `--default-expanded` 展开，不读 `default-directory` |
| 暗色下 badge / alert 仍是浅色块 | etaf-ui 的 variant 色走 `:ui-*` semantic token（`etaf-ui/lisp/etaf-ui-style.el:16-89`），其 `etaf-ui--style-palette` **只有一套浅色值**；不 provide 这些 token 就整体回退浅色 |

已核实的能力边界（不要重复验证）：

- 区域内滚动**支持**：`:overflow 'scroll'` + 高度约束；滚轮按最内层滚动器优先（`ebox/lisp/ebox-interaction.el:1868`、`:1874`）；etaf 测试有 `head` / 滚动区 / `foot` 的现成范式（`etaf/tests/etaf-events-tests.el:178`）。
- 底栏固定**无** `fixed` / sticky bottom：`:sticky` 只支持 top（写 header-line，每 Runtime 1 个、限单行，`etaf/etaf.el:1027`）；`:position` 只有 static/relative/absolute（`ebox/lisp/ebox-style.el:778`）。→ 只能靠 flex 布局让「总高 = 窗口高」使整窗不滚。
- 高度关键字：`auto / min-content / max-content / fit-content / stretch`（`ebox/lisp/ebox-style.el:696`）；`content` 只作 `:flex-basis`。
- 主题：`etaf-theme-provide` / `etaf-theme-token` 支持 plist 与 ref，属性级刷新不整树重渲染（`etaf/lisp/etaf-context.el:132`、`:208`）；但**不读 face、无主题钩子**（etaf/etaf-ui 全仓库无 `enable-theme-functions` 匹配）。
- `etaf-splitter`：`:ratio` 可响应式、`:on-change` 即拖动回调、支持 `min-ratio` / `max-ratio`（`etaf-ui/lisp/etaf-ui-desktop.el:544`、`:604`）。
- 焦点：无「跳 group」API；`etaf-focus-within` 可按 Host ref 落到子树首/末停靠点（`etaf/lisp/etaf-events.el:428`）。
- 区域滚动需要**显式高度约束**：flex 父列内用 `:flex-grow 1 :min-height (lh 0)` 允许收缩（`ebox/lisp/ebox-flex.el:269`）。

## 设计决策

- **L1 三段式 flex 布局**：根 `column` `:height 'stretch`（= 窗口高）→ 顶栏（固定高）/ 中间区（`:flex-grow 1`、`:min-height '(lh 0)`）/ 底栏（`:flex-shrink 0`）。除中间区外都不参与收缩。
- **L2 中间区两栏各自滚动**：`etaf-splitter` 放在中间区；左右两个 pane 各包一层 `:overflow 'scroll'` 且高度由父 flex 约束（不写死 `(lh N)`）。左树与右栏互不干扰。
- **L3 底栏语义不变**：仍是 `--footer-view` + `--notice-view` + 确认框；只是被移进固定区。
- **L4 宽度**：`ebasecamp-ui--split-ratio` 由 defcustom（默认 0.26）+ 会话 ref 承载；`min-ratio 0.15` / `max-ratio 0.55`；拖动经 `:on-change` 写回 ref 并持久化。
- **L5 宽度持久化**：`(expand-file-name "ui-state.el" ebasecamp-cache-directory)`（`make-temp-file` 生成唯一 tmp → `rename-file` 原子覆盖；只存 `(:split-ratio FLOAT)`），读取失败/文件缺失/越界静默回退默认并钳制到 `[min-ratio, max-ratio]`；不写任何密钥。
- **T1 主题分层（两层）**：
  - **基础色（从 face 取）**：`:ui-fg`（`default` 前景）、`:ui-bg`（`default` 背景）、`:ui-panel-fg` / `:ui-panel-bg`（面板：`mode-line-inactive` → 回退 `default`）、`:ui-muted-fg`（`shadow` 前景）、`:ui-border` / `:ui-panel-border` / `:ui-table-border` / `:ui-divider-bg`（`fringe` 前景 → 回退 `mode-line-inactive` 背景）。
  - **状态色（内置明暗两套 palette，按 `(frame-parameter nil 'background-mode)` 选 `light` / `dark`）**：`:ui-success-fg/-bg/-border`、`:ui-warning-*`、`:ui-danger-*`、`:ui-info-*`、`:ui-accent`、`:ui-accent-fg`、`:ui-accent-soft-bg`、`:ui-disabled-fg/-bg/-border`、`:ui-button-primary-fg/-bg`、`:ui-button-secondary-fg/-bg`、`:ui-button-ghost-fg`、`:ui-checkbox-enabled-fg`、`:ui-table-selected-fg/-bg`。
  - **回退规则**：`face-attribute` 返回 `unspecified` 时，基础色回退到内置 palette 的同名键；状态色不经 face。
  - **覆盖范围**：只覆盖 ebasecamp 实际渲染用到的 token（见 T4）。未覆盖的 token（`:ui-shell-*` / `:ui-window-*` / `:ui-search-*` / `:ui-picker-*` / `:ui-playing-card-*` / `:ui-data-grid-*`）继续走 etaf-ui palette 回退——这些组件在界面上不出现。
  - `defcustom ebasecamp-ui-theme`（nil = 跟随；plist = 显式覆盖，覆盖时与内置 palette 合并）。
- **T2 主题生效方式**：一个 `etaf-ref` 承载 plist + `etaf-theme-provide` 包住根 Host（根子树所有 Host 读 `etaf-theme-token`）；挂 `enable-theme-functions` / `disable-theme-functions` 更新 ref → 属性级刷新，不整树重渲染；`ebasecamp-ui-close` 与重建会话时对称移除/重建。
- **T3 色值守护（两条，属性级而非全文 grep）**：① `lisp/ebasecamp-ui.el` 的 **render 函数区**内不得出现「样式属性 + 色值字面量」的组合（正则 `:(bgcolor|color|background-color|border)[[:space:]]+"#[0-9A-Fa-f]\\{6\\}"`）；palette/token 定义区与 `defcustom` 默认值不在扫描范围，扫描范围用「render 函数名清单」显式界定并写进测试 docstring；② `(ebasecamp-ui--theme-plist)` 覆盖 T4 的必需 token 集且值均为非空字符串。
- **T4 必需 token 集（最小覆盖，35 个）**：`:ui-fg :ui-bg :ui-panel-fg :ui-panel-bg :ui-panel-border :ui-muted-fg :ui-border :ui-divider-bg :ui-table-border :ui-accent :ui-accent-fg :ui-accent-soft-bg :ui-success-fg :ui-success-bg :ui-success-border :ui-warning-fg :ui-warning-bg :ui-warning-border :ui-danger-fg :ui-danger-bg :ui-danger-border :ui-info-fg :ui-info-bg :ui-info-border :ui-disabled-fg :ui-disabled-bg :ui-disabled-border :ui-button-primary-fg :ui-button-primary-bg :ui-button-secondary-fg :ui-button-secondary-bg :ui-button-ghost-fg :ui-checkbox-enabled-fg :ui-table-selected-fg :ui-table-selected-bg`。
- **N1 区域跳转**：三区域各加 `:ref`（`ebasecamp-ui-tree` / `ebasecamp-ui-detail` / `ebasecamp-ui-footer`）；`ebasecamp-ui--focus-region` 用 `(etaf-focus-within runtime ref)`；root keys 增加 `1` / `2` / `3` 三条（中文 LABEL：「跳到左栏」/「跳到右栏」/「跳到底栏」）。
- **P1 项目上下文**：`ebasecamp-ui--project-for-directory (dir)` 用「最长前缀匹配」在 `ebasecamp-model-projects` 里找 `:root` 是 DIR 祖先的项目；命中 → `selected-group` 设为**该项目第一份配置**所属组并展开该组；未命中 / DIR 为 nil / 无项目 → **保持既有行为：不选中任何组**（右栏「选择左侧的组」，`n` 从第一个组开始）。「回退到第一个组」的措辞按「不选中」落实：自动选中第一个组会删掉未选中态，并让 `render-no-selected-group-shows-placeholder` / `render-skeleton` 等 4 项既有占位断言变红（P1.2 实测确认）。
- **P2 只算一次**：只在 `ebasecamp-ui-open` 建会话时计算；`ebasecamp-ui-refresh` / `g` 不覆盖用户手选的组。
- **H 第 7 条整条移入 v0.6**（理解：监控面板默认不显示，用快捷键唤出）；本计划不做快捷键显示策略调整。

## 任务

### 批次 L0：布局探针（先验证，失败即停）

- [x] L0.1 最小 view 探针（**修正：根不能用 `column`，必须是 `flex :flex-direction 'column`**——`column` / `row` 不走 flex 分配算法，只有 tag 为 `flex` 的节点进 `ebox--layout-flex`）：`(flex :flex-direction 'column :height 'stretch (row 顶栏 :flex-shrink 0) (box :flex-grow 1 :min-height '(lh 0) …splitter…) (row 底栏 :flex-shrink 0))`，`etaf-mount` 到真实 buffer 后断言：
      ⓪ **先验证 batch 环境**：`(set-frame-height nil 40)` 后 `(frame-height)` 是否变为 40、ebox 视口测量是否随之更新（记录实测值）；若不可靠 → 后续一律用 `ebox-node-layout` 几何断言作判据，不依赖窗口行数
      ① 中间区几何 `vh > 0` 且小于其内容高；② 底栏几何 `top + height ≈ 窗口高`；③ 整树不产生窗口滚动（`(window-start)` 为 `point-min` 且 buffer 行数 ≤ 窗口行数，或按 ⓪ 结论改用几何判据）；④ 中间区 `etaf-scroll-by` 后顶栏/底栏文本不变
      （依赖：无）验收：⓪ 有实测记录；①②③④ PASS；任一失败 → **停止并报告**，按实际几何调整设计后重跑

      **实测记录（2026-10-23，`emacs -Q --batch`，视口 `(let ((ebox-viewport-height 20)) …)`）**：
      - ⓪ batch 环境：`noninteractive=t`、`frame-height=25`、`frame-width=80`、`frame-char-width=1`、`frame-char-height=1`（`line-height=1`）、`ebox--default-viewport-width=80`（像素）、`ebox--default-viewport-height=nil`；`(set-frame-height nil 40)` 后 `frame-height` **仍为 25**（不生效，`window-body-height=38` 亦不参与 ebox 视口）。→ 判据一律用 `ebox-node-layout` 几何 + `(let ((ebox-viewport-height 20)) …)` 固定视口，**不用 `set-frame-height`**。
      - ① 中间区：root `vh=20 ch=20`；中间 `box :flex-grow 1 :min-height '(lh 0)` → `y=1 h=18 vh=18 ch=18`；左 pane `bw=24 vh=18 ch=30`、右 pane `bw=53 vh=18 ch=30`（`ch > vh` 可滚）✅
      - ② 底栏：`y=19 h=1` → `y+h=20` = 视口高；顶栏 `y=0 h=1` ✅
      - ③ 整窗不滚：root `ch=20 == vh=20`（对照：根用 `column` 时 root `ch=32`、底栏 `y+h=32` 掉出视口、buffer 文本里**没有**「底栏」）✅
      - ④ 中间区 `(etaf-scroll-by runtime 'left 3)` → 返回 `3`、`etaf-scroll-offset` = `3`；buffer 首行仍是「顶栏」、末行仍是「底栏」✅
      - 附①（本轮补充）：**顶栏 row 也必须 `:flex-shrink 0`**——不写时被压缩到 `h=0`，标题文本从 buffer 中消失（`顶栏` 匹配失败）。
      - 附②（本轮补充）：根用 `column` 的对照组里 `etaf-scroll-by` 返回 `0`（pane `vh == ch`），即「外层不是 flex → 中间区得不到限高 → 滚动恒无效」。
- [x] L0.2 探针：`etaf-splitter` 放进 `:flex-grow 1` 容器后，左右两个 pane 能否各自 `:overflow 'scroll'` 且 splitter 自身高度撑满中间区。若 splitter 破坏高度约束 → 改用「自绘两栏」（`row` + 左列 `:width (list '% ratio)` + 自绘分隔线 + 右列 `:flex-grow 1`），并**同时验证自绘分隔线的拖动**：分隔线加 `:ref` + `:on-drag`，拖拽回调把新比例写回 ratio ref（W 批次按两种结构分别验收）
      （依赖：L0.1）验收：记录采用哪种结构 + 实测几何 +（若自绘）拖动回调是否生效

      **实测记录**：**采用 `etaf-splitter`，自绘两栏分支未启用**。splitter 自身不能直接吃 `:flex-grow` / `:min-height`（组件签名是 `&key orientation ratio min-ratio max-ratio on-change use class overlay z-index divider-content overlay-rect visible`，多传关键字会报错），必须外面包一层——`box :flex-grow 1 :min-height '(lh 0)` 与 `flex :flex-direction 'column :flex-grow 1 :min-height '(lh 0)` 两种包裹几何**完全一致**（中间 `vh=18`，左 `bw=24` / 右 `bw=53` @ 视口 80px、ratio 0.3）。**slot 里的 pane 必须显式 `:height 'stretch`**，否则 pane 高度等于内容高（`vh == ch`）、`etaf-scroll-by` 恒返回 0。
- [x] L0.3 探针：`:ratio` 由 `etaf-ref` 驱动 + `:on-change` 拖动后，两栏宽度变化、内容重排、无 error；拖动后重新 `etaf-mount` 仍用新 ratio
      （依赖：L0.2）验收：PASS

      **实测记录**：PASS（比例驱动宽度已验）。`ratio 0.3` @ 视口 80px → 左 `bw=24`、右 `bw=53`（80 − 24 − 3px 分隔线）；`etaf-splitter` 的 `:ratio` 经 `etaf-ui--reactive-value` 读值，因此接受 `etaf-ref`；拖拽走 `:on-change`。**ref 写入后立即 flush 的批处理复测未通过（脚本副作用，非结构问题）**，拖拽与持久化的接线和验收归 W 批次（W1.1/W1.2），L 批次只用常量 ratio（`ebasecamp-ui--split-ratio`）。

### 批次 L：布局实现

- [x] L1.1 红：断言渲染树中**根 Host 是 `flex` 且 `:flex-direction` 为 `column`、`:height` 为 `stretch`**（`column` / `row` 不走 flex 算法，`:flex-grow` / `:flex-shrink` 在它们身上被忽略——外层必须是 `flex`）、中间 Host `:flex-grow` 1 且 `:min-height` 为 `(lh 0)`、底栏 Host `:flex-shrink` 0；底栏三个入口文本（「导入 compose」等）在 buffer 中仍存在
      （依赖：L0.1）验收：用例 FAILED（红）

      **实测**：红阶段 `Ran 341 tests, 337 as expected, 4 unexpected` —— 4 项新用例全 FAILED（`open-uses-flex-column-root` 取不到 `ebasecamp-ui-root` 节点、`body-region-is-scrollable` 的 `aref nil`、`footer-pinned-at-bottom` 的 `+ nil`、`scroll-body-keeps-header-footer` 的 `Host ebasecamp-ui-detail is not mounted`），其余 337 项全绿。绿后 `341/341`。
- [x] L1.2 实现：按 L0 结论重排 `ebasecamp-ui-app` 的 render 为三段式（**根 `(flex :flex-direction 'column :height 'stretch …)`**）；左树与右栏各包限高滚动容器（`column :height 'stretch :overflow 'scroll`，插在 splitter 的两个 slot 里）
      （依赖：L1.1）验收：L1.1 转绿；`make check` 全绿

      **实测几何（batch，`(let ((ebox-viewport-height 20)) …)`，1 组 1 配置 20 服务）**：root `tag=flex`、`:flex-direction column :height stretch`、`geo (:y 0 :height 20)`、`vh=18 ch=18`；顶栏 `row` `y=1 h=1`（`flex-shrink 0`）；中间区 `box` `flex-grow 1` + `min-height (lh 0)`、`y=5 h=8`；左树 `column`（`overflow scroll`）`w=26 vh=8 ch=2`；右栏 `column`（`overflow scroll`）`w=46 vh=8 ch=32` → 可滚；底栏 `flex column`（`flex-shrink 0`）`y=16 h=3`（下沿 19，距视口下沿 1 行 = 底部 padding）；`(etaf-scroll-by … 'ebasecamp-ui-detail 3)` → 3、offset = 3；滚动后文本仍含「ebasecamp / 导入 compose / 导出 compose / 销毁环境」。
      **实现要点（两处 L0 未覆盖、本轮实测才发现）**：① `flex` **不接受** `:item-gap`（`Ebox flex rejected properties`），纵向间距要用 `:row-gap '(lh 1)`（`column-gap` 不接受 `lh` 单位）；② 右栏内容列自带 `:height 'stretch`，直接放进滚动列会被拉成「滚动的视口高」（pane 的 `ch` 等于子节点 border-box → `vh == ch` → 滚不动），必须在两者的中间垫一层 `box`（高度取内容），内容才恢复自然高度并溢出。
      **连带调整（3 个既有用例）**：区域内部滚动后，落在滚动视口之外的行不再被绘制，因此 `spc-activates-checkbox`、`t-toggles-row-at-point`、`checkbox-refs-are-stable` 三个「按文本定位勾选框」的用例改为 `(let ((ebox-viewport-height 60)) …)` 包住 open（batch 默认视口高度随窗口状态变化，必须显式固定）。
- [x] L1.3 红：中间区滚动后顶栏与底栏文本不变（`etaf-scroll-by` + buffer 文本断言，参考 `etaf/tests/etaf-events-tests.el:178` 的写法）
      （依赖：L1.2）验收：用例 FAILED（红）

      **实测**：与 L1.1 同批红（`scroll-body-keeps-header-footer` FAILED，`etaf-scroll-by` 报 `Host ebasecamp-ui-detail is not mounted`）。
- [x] L1.4 实现（若 L1.3 红）：确保左树/右栏滚动区带 `:overflow 'scroll'` 且高度约束正确；补「滚动到底部时底栏仍在最后一行」的断言
      （依赖：L1.3）验收：L1.3 转绿

      **实测**：右栏 `etaf-scroll-by 5` 后 offset > 0 且顶栏/底栏文本仍在；再 `(etaf-scroll-to … 'end)` 后 offset > 5、底栏 `ebox-node-geometry` 与滚动前**完全一致**（下沿不动），文本仍含「ebasecamp / 导入 compose / 销毁环境」。左树 `ch=2 < vh=8`（该清单只有 1 组 1 配置，无需滚动），结构上仍是 `:overflow 'scroll'` 容器。

### 批次 T：主题配色

- [x] T1.1 红：① render 函数区（用显式函数名清单界定并写入测试 docstring）内不得出现「样式属性 + 色值字面量」（正则 `:(bgcolor|color|background-color|border)[[:space:]]+"#[0-9A-Fa-f]\\{6\\}"`）；② `(ebasecamp-ui--theme-plist)` 覆盖 T4 的 35 个必需 token 且每个值为非空字符串
      （依赖：无）验收：两项 FAILED（红）

      **实测（红阶段）**：新增 4 项用例后 `make test` → `Ran 345 tests, 341 as expected, 4 unexpected`，4 项全是新用例：`render-region-has-no-literal-colors`（命中 `ebasecamp-ui-app` 里的 `:bgcolor "#F8F5EE"`）、`theme-plist-covers-required-tokens` / `theme-plist-dark-differs`（`void-function ebasecamp-ui--theme-plist` / `ebasecamp-ui--refresh-theme`）、`theme-follows-load-theme`（同上，钩子未实现）。其余 341 项全绿。
      **测试实现要点**：扫描范围用 `ebasecamp-ui-test--render-functions` 19 个函数名显式界定，取源码用 `search-forward "(defun NAME "`（兼容 `etaf-define-component`）+ `forward-sexp` 取 sexp 边界，并**先断言每个名字都有定义**（清单拼错会让扫描面静默缩小 → 假绿）。**踩坑**：Emacs regexp 的分组/择一是 `\\(…\\)` / `\\|`，照抄计划里的 BRE 写法 `:(a\|b)` 会 `invalid-regexp "Unmatched ) or \\)"`。
- [x] T1.2 实现：新增 `ebasecamp-ui--palette-light` / `--palette-dark`（明暗两套状态色；色值字面量**只允许**出现在这两个定义区与 `defcustom` 默认值）+ `--face-color`（`face-attribute` 取值，`unspecified` 回退内置 palette）+ `--theme-plist`（基础色取自 face、状态色取自对应 palette，合并成 T4 的 35 键）+ `defcustom ebasecamp-ui-theme` + `etaf-ref` + `etaf-theme-provide` 包根 Host；清除 render 区所有色值字面量
      （依赖：T1.1）验收：T1.1 转绿；`make check` 全绿

      **实现**：① `ebasecamp-ui--palette-light` / `--palette-dark` 各 **35 键**（9 个基础色回退值 + 26 个状态色），键集合完全一致；② `--background-mode`（读 `background-mode` 帧参数，nil 按 light）、`--palette`、`--color-value-p`（判 `nil` / 符号 `unspecified` / 字符串 `unspecified-fg|bg` 三种「无值」形态）、`--face-color FACE ATTRIBUTE [KEY PALETTE]`（`(face-attribute face attribute nil t)`，无值回退 palette 的 KEY；**不**回退 `default` 同属性避免自指）、`--border-color`（`fringe` 前景 → `mode-line-inactive` 背景 → palette）、`--theme-merge`（按键去重覆盖）、`--theme-plist [MODE]`（`(--theme-merge ebasecamp-ui-theme (--theme-merge base palette))`）；③ `defcustom ebasecamp-ui-theme`（nil = 跟随；plist = 覆盖，`:type '(plist :key-type symbol :value-type color)'`）；④ `defvar ebasecamp-ui--theme`（`etaf-ref`，值 = `--theme-plist` 结果，`:name 'ebasecamp-ui-theme`）；⑤ `ebasecamp-ui-app` 的 `:setup` 首行 `(etaf-theme-provide ebasecamp-ui--theme)`（传 ref 本身，不是 `(etaf-value …)`）；⑥ 两处根 Host（空清单分支 + 正常分支）`:bgcolor` / `:color` 改成 `(etaf-theme-token :ui-bg)` / `(etaf-theme-token :ui-fg)`，render 区再无色值字面量。
      **face 实测（`emacs -Q --batch`，Emacs 31.1）**：`default` 前景 `"unspecified-fg"`、背景 `"unspecified-bg"`（**字符串伪色**，`symbolp` 为 nil；加载 modus 后仍是这两个值）；`shadow` 前景 / `fringe` 前景 / `mode-line-inactive` 前景与背景在无主题时全是符号 `unspecified`；**加载 modus 后 `mode-line-inactive` 背景变为 `#2d2d2d`（vivendi）/ `#e6e6e6`（operandi）**——这是唯一真正可用的面板/边框 face 来源；`fringe` 前景即使 modus 也不定义。未定义 face 查询会 `(error "Invalid face")`，`--face-color` 用 `condition-case` 兜住。
      **palette 最终色值**：light —— success `#2F6B43/#DCEBDD/#6D8A73`、warning `#8A4B08/#FFF3D6/#D99A2B`、danger `#C0392B/#FDECEA/#CF6A6A`（比 etaf-ui 的 `#FF6B6B` 更深，浅底上对比度更好）、info `#155E75/#E0F2FE/#38A3C7`、disabled `#687386/#E5E7EB/#9CA3AF`、accent `#2F6FE4/#FFFFFF/#DCE7FA`、button-primary `#FFFFFF/#2F6FE4`、button-secondary `#1F4FB0/#DCE7FA`、ghost/checkbox `#252A2E`、table-selected `#2F6B43/#DCEBDD`；基础色回退值 `:ui-fg #252A2E` / `:ui-bg #FFFDF8` / `:ui-panel-bg #F7F4EC` / `:ui-panel-border #C9D0DA` / `:ui-muted-fg #526174` / `:ui-border #687386` / `:ui-divider-bg #DCE3EB` / `:ui-table-border #687386`。dark —— success `#7BC98F/#1E3A28/#3E6B4E`、warning `#E5B567/#3D2E12/#8A6A2B`、danger `#FF8A80/#3E1F1F/#A34A4A`、info `#7FCBE8/#10333F/#2A6B80`、disabled `#8A94A6/#2A2F37/#4A5260`、accent `#6EA8FF/#0B1220/#223C5C`、button-primary `#0B1220/#6EA8FF`、button-secondary `#BFD8FF/#223C5C`、ghost/checkbox `#D7DEE8`、table-selected `#9FE0B0/#1E3A28`；基础色回退值 `:ui-fg #D7DEE8` / `:ui-bg #1B1F24` / `:ui-panel-bg #23282F` / `:ui-panel-border #3C4450` / `:ui-muted-fg #8A94A6` / `:ui-border #4A5260` / `:ui-divider-bg #2F353D` / `:ui-table-border #4A5260`。
      **`etaf-theme-provide` 用法（探针实测）**：在 `:render` 里调用会 signal `etaf-render-side-effect-error (provide-context)`（`etaf-provide` 有 `etaf--assert-not-rendering` 守卫）→ 必须放 `:setup`；传 `etaf-ref` 本身即可，取值变化后**同一节点身份**的 `:bgcolor` 从旧值变新值（属性级刷新），不重挂载；不 provide 时 `(etaf-theme-token :ui-bg)` 无 default → 属性直接消失（nil）；嵌套子树里更近的 provide 覆盖外层（etaf-ui 组件自带的 token 会被我们的 provide 覆盖）。
- [x] T1.3 红：`(load-theme 'modus-vivendi t)` → `(load-theme 'modus-operandi t)` 后 theme ref 的值变化（`:ui-bg` 不同、`:ui-success-bg` 随明暗切换）；用例 `unwind-protect` 收尾 `disable-theme` 恢复原主题态（modus-operandi / modus-vivendi 为 Emacs 31.1 内置主题，标 `事实✓`）
      （依赖：T1.2）验收：用例 FAILED（红）

      **实测（红阶段）**：与 T1.1 同批红（`theme-follows-load-theme` FAILED —— `void-function ebasecamp-ui--refresh-theme`）。
      **batch 探针结论**：`enable-theme-functions` / `disable-theme-functions` 在 31.1 均 `boundp`，`load-theme` 时会被调用且参数是被启用/停用的主题名（每次 `load-theme` 先记一次 `user` 再记目标主题）；`load-theme 'modus-vivendi` 会把 `(frame-parameter nil 'background-mode)` 置 `dark`，`'modus-operandi` 置 `light`。
- [x] T1.4 实现（若 T1.3 红）：挂 `enable-theme-functions` / `disable-theme-functions` 更新 theme ref；`ebasecamp-ui-close` 与重建会话时对称移除/重建（写进 docstring）
      （依赖：T1.3）验收：T1.3 转绿

      **实现**：`--theme-hook (_theme)`（重算整份 plist，不按主题增量推断）+ `--refresh-theme`（写 ref，值相同则不写）+ `--theme-hooks-install` / `--theme-hooks-remove`（`add-hook` 幂等）。**挂载位置**：`ebasecamp-ui-open` 内、`etaf-mount` 之前（先挂后挂载 → 首帧即用最新配色），序列为 `--ensure-manifest` → `ebasecamp-ui-session` → `--theme-hooks-install` → `--refresh-theme` → 显示 buffer → `ebasecamp-ui-mode` → `etaf-mount`。**卸载位置**：`ebasecamp-ui-close` 的**第一行**（先解耦主题再做卸载/停轮询，任何后续失败都不会残留钩子）；close 的 docstring 已补「卸载主题钩子」。重建会话（`--with-ui` 里 close 后重 open）走同一对函数，天然对称。
      **实测**：界面打开时 `load-theme vivendi → operandi`，ref 的 `:ui-bg` 由 `#1B1F24` 变 `#FFFDF8`、`:ui-success-bg` 由 `#1E3A28` 变 `#DCEBDD`、`:ui-panel-bg` 由 `#2d2d2d`（face！）变 `#e6e6e6`；**渲染中的根 Host `:bgcolor` 同步变**（`#1B1F24` → `#FFFDF8`）且节点身份不变；close 后两个 hook 列表里都不再有 `ebasecamp-ui--theme-hook`。
- [x] T1.5 红（B1 守护）：暗色模式下 `:ui-success-bg` 等状态 token 不得等于 etaf-ui palette 的浅色值（如 `"#DCEBDD"`）；且 `--scope-badge` / `--state-cell` 渲染出的 Host 背景色等于 theme 值
      （依赖：T1.2）验收：用例 FAILED（红）

      **实测（红阶段）**：`theme-plist-dark-differs` FAILED（`void-function ebasecamp-ui--refresh-theme`）。转绿后同用例覆盖两半：① `(set-frame-parameter nil 'background-mode 'dark)` 下 `:ui-success-bg` = `#1E3A28` ≠ `#DCEBDD`，`:ui-bg` / `:ui-fg` / `:ui-success-bg` 明暗均不同；② `--state-cell`（running → `success` variant）渲染出的 `etaf-badge` 节点 `:background-color` == theme 的 `:ui-success-bg`（测试用专用组件 `ebasecamp-ui-test--theme-probe` 把 `ebasecamp-ui--theme` provide 给它，再用 `ebox-node-walk` + `ebox-node-classes` 找 `etaf-badge` 节点）。`unwind-protect` 恢复原 `background-mode` 并重算 ref。
- [x] T1.6 实现（若 T1.5 红）：核对 badge / alert / table / button / checkbox 全部走 `etaf-theme-token`，缺口补齐
      （依赖：T1.5）验收：T1.5 转绿

      **核对结果（缺口 2 处，均已在 T1.2 补齐）**：① `--scope-badge` / `--state-cell` / `--health-cell` / 段内按钮 / `etaf-alert` / `etaf-checkbox` / `etaf-table` / `etaf-divider` 本身**已经**走 `:ui-*` semantic token（`etaf-ui-feedback.el:14-18` 的 `etaf-ui--feedback-keys` + `etaf-ui--style-token`），此前「暗色下仍是浅色块」的根因是**界面从未 provide 过 token**（整体回退 `etaf-ui--style-palette` 的单套浅色值）；② 唯一直接写色值的地方是根 Host 的 `:bgcolor` / `:color`（硬编码 `#F8F5EE` / `#252A2E`），改成 token。**未覆盖的 token**（`:ui-shell-*` / `:ui-window-*` / `:ui-search-*` / `:ui-picker-*` / `:ui-playing-card-*` / `:ui-data-grid-*`）继续走 etaf-ui 回退——这些组件界面上不出现，未为「全量」而覆盖。

### 批次 W：左栏宽度与拖动

- [x] W1.1 红：默认 ratio 为 0.26；`(ebasecamp-ui--set-split-ratio 0.3)` 后 ref 值变化且布局宽度百分比随之变化；`--save-ui-state` → `--load-ui-state` 往返得 0.3；文件缺失 / 内容非法 / **ratio 越界（0.9、-1）** 三种情形一律回退默认并**钳制到 `[min-ratio, max-ratio]`**（越界不得在渲染期 signal）
      （依赖：L1.2）验收：四项 FAILED（红）

      **实测（红阶段）**：新增 4 项用例后 `make test` → `Ran 349 tests, 345 as expected, 4 unexpected`，4 项全是新用例：`split-ratio-default`（断言 `(= 0.26 0.38)` 失败）、`set-split-ratio-updates-layout`（`void-function ebasecamp-ui-session-split-ratio`）、`ui-state-invalid-falls-back`（`void-function ebasecamp-ui--ui-state-file`）、`ui-state-roundtrip`（`void-function ebasecamp-ui--set-split-ratio`）；其余 345 项全绿。绿后 `349/349`。
      **测试脚手架改动（连带必需）**：`ebasecamp-ui-test--with-ui` 追加把 `ebasecamp-cache-directory` 也绑到临时目录 —— `ebasecamp-ui-close` 现在会写 `ui-state.el`，不隔离会让「存 0.3」的用例污染「读默认值」的用例（跨用例经真实缓存文件互相影响）。非法 / 越界状态文件用 `with-temp-file` 直接写入后再调 `--load-ui-state`，并在每轮 `open` 前重写（否则前一次 `close` 的保存会把文件覆盖成合法内容，测试变假绿）。
- [x] W1.2 实现：ratio defcustom + 会话 ref + 拖动回调（splitter `:on-change`；若 L0.2 选自绘则用分隔线 `:on-drag`）写回 + `ebasecamp-ui--save-ui-state`（路径 `(expand-file-name "ui-state.el" ebasecamp-cache-directory)`，目录不存在时 `make-directory` 递归创建；`make-temp-file` 生成唯一 tmp 后 `rename-file` 覆盖）+ `--load-ui-state`（`(let ((read-eval nil)) (read …))`，只接受 `(:split-ratio NUMBER)` 形态，其余非法；读到数字后钳制到 `[min-ratio, max-ratio]`）
      （依赖：W1.1）验收：W1.1 转绿

      **`:on-change` 实际签名（读源码 + 实测，两处结论一致）**：收到的是**原始手势 plist**，不是 ratio 数字。`etaf-splitter` 把 `:on-change` 原样接到分隔线 Host 的 `:on-drag`（`etaf-ui/lisp/etaf-ui-desktop.el:533`、`:620`），形态来自 `ebox-keymap-create` 的 `:drag` 协议（`ebox/lisp/ebox-interaction.el:456`）：`:phase`（`start`/`move`/`end`/`cancel`）、`:position`（指针 `(X . Y)` 像素）、`:delta`（相对按下点 `(DX . DY)` 像素）、`:node`（分隔线节点）、`:keyboard`（`t` = 来自 `etaf-drag-step`）。比例折算两条分支：**指针**按「指针 X − 容器左边界」/ 容器宽（容器 = 分隔线节点的父节点，即 splitter 的 flex 根）；**键盘**没有绝对坐标（`etaf-drag-step` 传 `:position (0 . 0)` → 位移），按「当前比例 + DX / 容器宽」。
      **ratio 承载方式**：会话槽位 `split-ratio`（`etaf-ref`，name `ebasecamp-ui-split-ratio`，初始值 = `--load-ui-state`）；splitter 的 `:ratio` 传**ref 本身**（`etaf-ui--reactive-value` 追踪读取 → 只有 splitter 重渲染，不连带整个 `ebasecamp-ui-app` 在每次鼠标移动时重建）。`ebasecamp-ui--split-ratio` 保留原名改为 defcustom（默认 0.26），`--split-ratio-min` / `-max` 为 defconst 0.15 / 0.55，同时作为 splitter 的 `:min-ratio` / `:max-ratio`。
      **实测几何（batch，`(let ((ebox-viewport-height 20)) …)`，根 padding 后 splitter 容器宽 75px、x=2）**：0.26 → tree `bw=19` / detail `bw=53`；0.4 → `30` / `42`；设回 0.26 → `19` / `53`（完全复原）；入参 0.9 → ref 变 0.55（钳制），入参字符串 → 忽略。合成手势：指针 x=28 → ratio `0.3467`、tree `bw=26`（`move` 阶段布局已即时跟随）；键盘 `DX=5%` → `0.3467 + 0.05 = 0.4`（`end` 阶段同时落盘）。
      **重渲染不打断拖动（探针）**：ratio 0.26 → 0.4 后，分隔线节点与 `ebasecamp-ui-tree` 节点都是**同一个 ebox 节点对象**（`eq` 为 t），即 etaf 保留 Host 身份、只换几何 —— 真实鼠标拖动不会因为「节点被替换」被判 `target-unavailable` 而中途取消。
      **state 文件**：`<ebasecamp-cache-directory>/ui-state.el`，内容 `(:split-ratio 0.33)\n`（`prin1`）；`make-temp-file` 同目录唯一 tmp → `rename-file` 原子覆盖；写盘失败只 `message`不 signal（close / 拖动回调里不阻断关闭）。`--load-ui-state` 回退实测：`(:split-ratio 0.9)` → `0.55`、`(:split-ratio -1)` → `0.15`、`(foo)` → `0.26`、空文件 → `0.26`、`#.(+ 1 2)` → `0.26`、文件缺失 → `0.26`。
      **偏差（必须记录）：`read-eval` 方案在 Emacs 31.1 不可用**。该变量已不存在（`(boundp 'read-eval)` = nil），照计划写 `(let ((read-eval nil)) (read (current-buffer)))` 会因「变量未被使用」被 `byte-compile-error-on-warn t` 判为编译错误（`make compile` 直接失败）。同时 31.1 起 `#.` 读语法默认禁用（`(read "#.(+ 1 2)")` → `invalid-read-syntax "#."`）。**替代实现**：读前显式拒绝含 `#.` 的文本（合法状态文件永不含该序列），保证「不执行文件内容」的语义在 31.1 与旧版 Emacs（`read-eval` 默认 t）上都成立。
      **close 保存策略**：拖动 `end` 阶段落盘一次（跨会话记住）；`ebasecamp-ui-close` 在销毁会话前再存一次（覆盖「拖到一半直接关闭」）。`start` / `cancel` 不动状态（手势取消不固化中间态）。

### 批次 N：区域跳转

- [x] N1.1 红：`(ebasecamp-ui--focus-region 'tree)` 后 `(ebox-focused-node)` 落在左树 `:ref` 子树内；`'detail` / `'footer` 同理；未知区域 symbol 静默 no-op
      （依赖：L1.2）验收：FAILED（红）

      **实测（红阶段）**：新增 5 项用例（`focus-region-tree` / `-detail` / `-footer` /
      `-unknown-is-noop` / `-keys-bound`）后 `make test` → `Ran 354 tests, 346 as expected,
      8 unexpected`：5 项新用例全 FAILED（`void-function ebasecamp-ui--focus-region`），
      外加三条既有键位用例（仍在 9 条 → 12 条的落差上，见 N1.2）。其余 346 项全绿。
      绿后 `354/354`。
      **判别力修正（本轮发现）**：测试辅助函数 `ebasecamp-ui-test--focused-within-p` 原写
      `(or (eq root focused) (ebox-node-ancestor-p root focused) t)` —— 末尾的 `t` 让函数
      **恒真**，任何区域都能「通过」，`should-not (--focused-within-p 别的区域)` 完全失效
      （假绿）。已删除该 `t` 并在该节注释里写明「不要为让它通过改回去」。
- [x] N1.2 实现：三区域 `:ref` + `--focus-region` + root keys 增加 `1` / `2` / `3`（中文 LABEL：「跳到左栏」/「跳到右栏」/「跳到底栏」）
      （依赖：N1.1）验收：N1.1 转绿；**必须同步修改三条既有测试**：`ebasecamp-ui-test-root-keys-complete`（精确集合 9 → 12）、`ebasecamp-ui-test-root-keys-final-set`（`(= 12 (length keys))` + 精确集合）、`ebasecamp-ui-test-help-data-includes-labels`（LABEL 清单补「跳到左栏 / 跳到右栏 / 跳到底栏」并更新 docstring 的「9 条根级」文案）

      **实现（只改 `lisp/ebasecamp-ui.el`）**：
      ① `ebasecamp-ui--region-refs`（defconst，`((tree . ebasecamp-ui-tree) (detail . ebasecamp-ui-detail) (footer . ebasecamp-ui-footer))`）+
      `ebasecamp-ui--region-ref REGION`（`alist-get`，未知区域 nil，纯函数）；
      ② `ebasecamp-ui--focus-region REGION`（带 `interactive` 的 `completing-read'，候选取自 `--region-refs`，避免第二份清单）：取 `(etaf-runtime-for-buffer (current-buffer))` + ref → **两者都存在且 `(etaf-runtime-host-node runtime ref)` 非 nil** 时才 `(etaf-focus-within runtime ref)`，否则返回 nil（静默 no-op）；
      ③ 三个零参命令 `--focus-tree` / `--focus-detail` / `--focus-footer`，root keys 在 `n`/`p` 之后、`e` 之前插入 `("1" … "跳到左栏")` / `("2" … "跳到右栏")` / `("3" … "跳到底栏")`，共 12 条；`--root-keys` docstring 补一段（printing key 绑定后 evil 数字前缀在界面内失效，与 `q`/`g` 同理）。
      **为什么需要三个零参命令**：`etaf--keys-run` 对 commandp 条目走 `call-interactively`，把带 interactive 参数的 `--focus-region` 直接绑到键上会在按键时先 `completing-read` 问区域。
      **三条既有测试**：上一轮（红阶段，与本批次同一测试文件）已同步改成 12 条 —— `root-keys-complete` 精确集合含 `1`/`2`/`3`、`root-keys-final-set` 为 `(= 12 (length keys))` + 12 条精确集合、`help-data-includes-labels` 的 LABEL 清单已含「跳到左栏 / 跳到右栏 / 跳到底栏」且 docstring 已写「12 条」。本轮**只核对未再改动**（红阶段它们正是 8 项 FAILED 中的 3 项）。
      **`etaf-focus-within` 实际行为（读源码 + 探针）**：`(etaf-focus-within RUNTIME HOST-REF &optional COUNT)`，**COUNT 不需要**——nil 即「子树第一个停靠点」；零值只查询当前焦点是否在内。缺失 Host 时经 `etaf--event-host-node` signal `user-error`（`"No committed ETAF Host"`），因此必须在调用前判 `etaf-runtime-host-node` 非 nil；runtime 必须已挂载（`etaf-runtime-require-mounted`）。真实停靠点是区域内的普通 `box`（生成 ref `(etaf-host 1 N)`），**不是**区域 Host 本身 —— 断言只能写「焦点是否在区域子树内」。
- [x] N1.3 红：`(etaf--keys-binding [?1])` / `[?2]` / `[?3]` 均非 `nil` 且非 `#'ignore`
      （依赖：N1.2）验收：转绿

      **实测（绿后）**：`(etaf--keys-binding [?\1])` 三者均返回 wrapper（`commandp` = t、`eq #'ignore` = nil），条目命令分别为 `ebasecamp-ui--focus-tree` / `-detail` / `-footer`；`execute-kbd-macro` 按 `1`/`2`/`3` 端到端把焦点送进对应区域子树（用例 `focus-region-keys-bound` 覆盖）。

### 批次 P：项目上下文默认定位

- [x] P1.1 红：`let` 绑定 `default-directory` 为项目 A root 的子目录 → `(ebasecamp-ui-open)` 后 `selected-group` 为「A 的第一份配置」的组。**「第一份」定义**：按 `ebasecamp-model-groups` 的组顺序、组内 `:configs` 顺序，首个 `:project` 命中 A 的配置。另两条：`default-directory` 不在任何项目 root 下 → 第一个组；A 无配置 → 第一个组
      （依赖：L1.2）验收：三项 FAILED（红）

      **实测（红阶段）**：新增 3 项用例后 `make test` → `Ran 357 tests, 354 as expected, 3 unexpected`，3 项全是新用例：`open-selects-project-group`（`(eq 'redis <selected>)` 实得 nil）、`open-falls-back-when-no-project` / `open-falls-back-when-project-has-no-config`（`void-function ebasecamp-ui--project-for-directory`）。其余 354 项全绿。绿后 `357/357`。
      **回退语义的裁决（与计划措辞的偏差，已确认取值）**：计划写「未命中 → 第一个组」，但**既有行为是「无选中组」**（右栏显示「选择左侧的组」），且 `render-no-selected-group-shows-placeholder`、`render-skeleton` 等 4 项既有用例都断言该占位文案。若回退时自动选中第一个组，等于删掉「未选中」态并让这 4 项集体变红——超出 P 批次范围。故取「回退 = 保持既有行为（`selected-group` 为 nil，`n` 从第一个组开始）」，两条回退用例据此断言：函数级（`--project-for-directory` 必须返回 nil）+ 打开后 `selected-group` 仍为 nil + `(car (--group-names state))` 是第一个组 mysql + buffer 含「选择左侧的组」。
      **测试脚手架要点**：`ebasecamp-define-project` 是宏，ARGS 整体被 quote（`(ebasecamp-define-project pa :root my-var)` 里 `my-var` 不求值），因此项目 `:root` 只能定义后用公开访问器 `(setf (ebasecamp-project-root (ebasecamp-model-project 'pa)) DIR)` 写入（注册表持有同一对象，`ebasecamp-model-projects` 只是浅拷贝）。清单 helper `ebasecamp-ui-test--project-roots-manifest` 刻意让项目 a 的组（redis，配置 cache → a）排在 mysql（配置 dev → b）**之后**，使「选中第一个组」的实现必然失败。
- [x] P1.2 实现：`ebasecamp-ui--project-for-directory`（最长前缀匹配；DIR 与每个项目 `:root` **都**先 `expand-file-name` 再 `file-truename` 归一后比较；root 为空或不存在时跳过；**默认大小写敏感**，不提供大小写不敏感开关；多个 root 命中时取最长者）+ 在 `ebasecamp-ui-open` 建会话时设置 `selected-group`（默认全展开时展开动作是 no-op）
      （依赖：P1.1）验收：P1.1 转绿

      **实现（只改 `lisp/ebasecamp-ui.el`，两函数 + 会话一处）**：
      ① `ebasecamp-ui--project-for-directory DIR`（554 行附近）：`(stringp DIR)` + `(file-directory-p DIR)` 双前置，否则 nil；`target = (file-name-as-directory (file-truename (expand-file-name DIR)))`；遍历 `(ebasecamp-model-projects)`，`root` 须为**非空字符串且 `file-directory-p`**，`prefix = (file-name-as-directory (file-truename (expand-file-name root)))`，`(> (length prefix) best-length)` + `(string-prefix-p prefix target)` 同时成立才替换 → 天然的**最长 root 胜出**；返回项目对象。`string-prefix-p` **不传第三参数**（默认大小写敏感），也不绑 `case-fold-search`。
      ② `ebasecamp-ui--first-group-for-project PROJECT`：PROJECT 归一为名字（`ebasecamp-project-p` 时取 `ebasecamp-project-name`），`cl-loop` 按 `(ebasecamp-model-groups)` 顺序、组内 `(ebasecamp-model-group-configs group)` 顺序（元素 `(CONFIG-NAME . PLIST)`，取 `cdr` 送 `ebasecamp-model-config-project`）找首个 `eq` 命中，返回 `(ebasecamp-group-name group)`；无命中 nil。
      ③ `ebasecamp-ui--new-session`：`(let* ((project (--project-for-directory default-directory)) (group (and project (--first-group-for-project (ebasecamp-project-name project))))) …)`，`:state` 用 `(--build-state group)`、`:selected-group` 用 `(etaf-ref group …)`；其余槽位（expanded / selected-ref / split-ratio / busy / notice / confirm）不变。`--default-expanded` 仍全展开，故「展开该组」是 no-op，无需额外动作。
      **访问器实测名称（`事实✓`，读 `lisp/ebasecamp-model.el`）**：`ebasecamp-model-groups` / `ebasecamp-model-projects`（均 `copy-sequence`）、`ebasecamp-model-group-configs`（`((CONFIG-NAME . PLIST) …)`）、`ebasecamp-model-config-project`（`plist-get :project`）、`ebasecamp-project-root` / `ebasecamp-project-name`（cl-defstruct 访问器，`(setf …)` 可用）；`ebasecamp-model-project NAME` 取对象。
      **踩坑（本批次唯一返工）**：`--project-for-directory` 返回**项目对象**，而 `--first-group-for-project` 按**项目名 `eq`** 比较；首版把对象直接传进去 → 静默返回 nil、界面「打开了但不选中」。已两处修：调用点传 `(ebasecamp-project-name project)`，函数内再防御性接受对象（`ebasecamp-project-p` 时归一为名字）。教训：命中链路两跳的类型契约必须显式（对象 vs 名字），否则失败形态是「静默 nil」而非报错。
      **batch 探针（`emacs -Q --batch`，2 项目 2 组，A 的组 `redis` 在组序第 2）**：`open`(`/tmp/ebc-probe/a/src/`) → `selected=redis`（summary `2 组 · 2 配置`）；`open`(`/tmp/ebc-probe/` 无关目录) → `selected=nil`；`open`(`/tmp/ebc-probe/b/` 项目 B root 本身) → `selected=mysql`（B 的第一份配置所在组）。`--project-for-directory`：`/tmp/ebc-probe/a/src/` → `pa`、`a/` 本身 → `pa`、**相似前缀 `/tmp/ebc-probe/a2/` → nil**（不误命中）、不存在的 `a/nope/` → nil、`nil` → nil。
      **最长匹配验证（三层嵌套 root `/tmp/ebc-probe2` < `a` < `a/deep`）**：`a/deep/sub/` → `pdeep`、`a/deep/` → `pdeep`、`a/` → `pa`、`/tmp/ebc-probe2/` → `outer`、`b/` → `pb`；界面在该清单下 `open(a/deep/sub)` → `selected=redis`。
      **「只算一次」验证（P2）**：`open` → `mysql`；`ebasecamp-ui-refresh` → 仍 `mysql`；手选 `redis` 后 `refresh` / `refresh(nil, t)` → 仍 `redis`；会话存在时再次 `open` → 仍 `redis`（不重算）；`close` 后重开 → 回到 `mysql`（重算）。`g`（`--reload-and-refresh`）只调 `ebasecamp-reload`，后者内部只调 `ebasecamp-ui-refresh`（`ebasecamp.el:171`），**不触碰 selected-group、不重建会话**。

### 批次 D：文档与目检

- [x] D1 `Readme.org`：布局说明（底栏常驻、区域内部滚动）、`1`/`2`/`3` 键、左栏可拖动、主题跟随
      （依赖：P1.2）验收：`grep -c '底栏' Readme.org` ≥ 1、`grep -c '跳到左栏' Readme.org` ≥ 1、`grep -c '拖动' Readme.org` ≥ 1

      **完成记录**：新增 `** 界面布局`（10 行：底栏常驻 / 左右两栏各自内部滚动 / 左栏宽度可拖动 0.15–0.55 默认 0.26 / 宽度跨会话记住到 `ui-state.el`）、`** 主题`（16 行：主题两层 + `load-theme` 即时生效 + `ebasecamp-ui-theme` 覆盖示例 + 35 token 范围）、`** 在项目中打开`（9 行：第一份配置定义 / 最长 root / 无匹配不选中 / 只算一次）；根级键位表插入 `1` / `2` / `3` 一行并补「printing key 使 evil 数字前缀失效」一句；文件头版本 `0.2.0 → 0.4.0`（D5 同步的一部分）。Readme.org 351 → 386 行。grep 实测：底栏 **5**、跳到左栏 **1**、拖动 **2**、`ebasecamp-ui-theme` **2**。
- [x] D2 `docs/user-guide.org`：同上 + 「在项目目录里打开会定位到该项目」的行为说明
      （依赖：D1）验收：`grep -c '定位到该项目' docs/user-guide.org` ≥ 1

      **完成记录**：在 `* 界面操作` 的 `** 布局` 表之后新增 `** 布局与导航`（11 行，用户视角五条：底栏常驻 + 区域各自滚动、`1`/`2`/`3` 跳区域、左栏拖动与记住、主题跟随、在项目目录里打开会定位到该项目且无匹配不选中）。user-guide.org 510 → 520 行。grep 实测：定位到该项目 **1**、拖动 **1**、跳到左栏 **1**。
- [x] D3 `docs/architecture.org`：新增「布局与主题」节（flex 三段式、无 sticky bottom 的自实现边界、主题两层（face + 明暗 palette）、`enable-theme-functions` 钩子、区域 scroll 的限高前提、ui-state 属运行时缓存）
      （依赖：D2）验收：该节含「flex」「sticky」「enable-theme-functions」三个关键词

      **完成记录**：在 `* UI buffer 身份与键位分层` 之后、`* 已删除 / 不再使用的机制` 之前新增 `* 布局与主题`（76 行，六个子节：flex 三段式（含「没有 sticky bottom 可用」的四条硬约束 + 结构表）/ 区域内部滚动的前提（两个坑）/ 主题两层与主题钩子（face 三种无值形态、`etaf-theme-provide` 只能在 `:setup`、钩子对称）/ `ui-state.el` 是运行时状态缓存 / 区域跳转（三条实测结论 + 为何要三个零参命令）/ 项目定位（双 `file-truename` 归一、大小写敏感、第一份配置顺序契约、无匹配不选中））。另同步两处：不变量清单补第 12 / 13 条（12 条此前漏在本文档）、相关文档补 ADR-0003 / ADR-0004 链接。architecture.org 312 → 391 行。关键词实测：flex **12**、sticky **2**、enable-theme-functions **1**、etaf-theme-provide **1**、file-truename **1**。
- [x] D4 `docs/adr/0004-ui-layout-theme.org` + `openspec/decisions.md`。ADR 必须含：① `ui-state.el` 是运行时状态缓存（位于 `ebasecamp-cache-directory`、非清单、非用户编辑），不破坏 ADR-0003 的「清单只经 `e` 编辑」不变量；② 三条否决备选（用 `:sticky top` 代替底栏 / 只用硬编码两套 plist 不读 face / 引入主题库依赖）
      （依赖：D3）验收：ADR 存在且含上述三点；`grep -c '0004' openspec/decisions.md` ≥ 1

      **完成记录**：新建 `docs/adr/0004-ui-layout-theme.org`（70 行，格式对齐 ADR-0003：状态 Accepted / 日期 2026-10-23 / 背景五条根因 → 决策六条 → 后果（正面 7 条 + 代价与已知边界 7 条 + 单独一节「`ui-state.el` 的定位（与 ADR-0003 不变量不冲突）」）→ 备选与否决 A–F 六条 → 状态节引用 ADR-0001 / ADR-0003 / tech-debt #28）。`openspec/decisions.md` 追加 **5 行**（不是 1 行）——按 ADR-0004 的五个决策各占一行（flex 三段式 / 主题两层 / 宽度持久化 / 区域跳转 / 项目定位），与 ADR-0001（8 行）、ADR-0002（5 行）、ADR-0003（2 行）的既有粒度一致。grep 实测：decisions.md 含 `0004` **5** 行；ADR 含 `sticky` 2、`硬编码的明暗两套 plist` 1、`主题库依赖` 1、`运行时状态缓存` 1、`ADR-0003` 3、`tech-debt.md` 2。
- [x] D5 `CHANGELOG.md` 0.4.0 + 全部 `Version:` 同步
      （依赖：D4）验收：`grep -c '0.4.0' CHANGELOG.md ebasecamp.el lisp/*.el` 总行数 ≥ 12

      **完成记录**：新增 `## [0.4.0] - 2026-10-23`（27 行：新增 5 条 / 变更 5 条 / 修复 3 条，遵循 Keep a Changelog）。`Version:` 头 11 个文件（`ebasecamp.el` + `lisp/*.el` 10 个）全部 `0.3.0 → 0.4.0`。CHANGELOG.md 119 → 145 行。验收实测总行数 **12**（CHANGELOG 1 + ebasecamp.el 1 + 10 个模块各 1）。
- [x] D6 `AGENTS.md`：当前状态与 `docs/adr/0004` 索引；补一条可机械检查的不变量「UI 样式不得硬编码色值（只允许出现在 palette/token 定义区与 defcustom 默认值）」
      （依赖：D5）验收：不变量清单含该条；`grep -c '0004' AGENTS.md` ≥ 1

      **完成记录**：不变量清单补第 13 条（含测试守护函数名 `render-region-has-no-literal-colors` 与扫描范围口径）；`docs/` 行补 `docs/adr/0004-ui-layout-theme.org`；「当前状态」改为 v0.4 批次 D 文档完成（待 D7 目检）、基线 357、三份待归档计划（v0.2 / v0.3 / v0.4）说明、架构决策列表补 ADR-0004。AGENTS.md 92 → 93 行。grep 实测：含 `0004` **3** 行、不变量条目 **1** 条。
- [x] D7 用户目检（L3）：①底栏常驻可见、不再整窗滚动；②配置多时左树/右栏各自滚动、顶栏底栏不动；③暗色主题下配色协调、切换主题即时变化；④左栏变窄（0.26）且可拖动、重开仍记住；⑤`1`/`2`/`3` 跳转；⑥在项目目录内打开定位到该项目配置
  - 实测结论（2026-10-23，用户确认 6 项全部通过）：底栏常驻；左树/右栏各自内部滚动；暗色主题配色协调且切换主题即时生效；左栏 0.26 可拖动且重开仍记住；`1`-`2`-`3` 区域跳转正常；在项目目录内打开自动定位到该项目配置
      （依赖：D6）验收：用户确认

## 文档清单

| 文档 | 本计划触发的更新 |
|---|---|
| `Readme.org` | 布局、`1`/`2`/`3`、拖动宽度、主题跟随 |
| `docs/user-guide.org` | 布局与项目上下文行为 |
| `docs/architecture.org` | 新增「布局与主题」节 |
| `docs/adr/0004-ui-layout-theme.org` | 新 ADR |
| `openspec/decisions.md` | 追加决策与否决备选 |
| `AGENTS.md` | 当前状态、ADR 索引、可能的新不变量 |
| `CHANGELOG.md` | 0.4.0 |
| `openspec/tech-debt.md` | 若 L0 探针暴露 etaf 限制（如 splitter 与 flex 不兼容），记一条 |

## 验证标准

- **L1**：`make check-parens` + `make compile`（零 warning）
- **L2**：`make test` 全绿（当前基线 337；预计新增 ≥12 项）
- **L3**：用户目检 6 项（见 D7）。布局几何断言在 batch 下以 `ebox-node-layout` 为准；窗口行数不足时按 L0.1 ⓪ 的结论处理（`set-frame-height` 生效则放大后测试，否则只用几何判据），两种情形都记录环境
- 每批次完成更新本文件「## 当前状态」

## 注意事项

- **`column` / `row` 上 `:flex-*` 无效，必须用 `flex`**（L0.1 实测，2026-10-23）：只有 tag 为 `flex` 的节点进 `ebox--layout-flex`；`:flex-grow` / `:flex-shrink` / `:min-height` 只在该 flex 容器的**子节点**上被读取。三段式外层写 `(flex :flex-direction 'column :height 'stretch …)`；写成 `(column …)` 时内容高 32 > 视口 20、底栏掉出视口、`etaf-scroll-by` 恒返回 0。
- **splitter 的 slot pane 必须显式 `:height 'stretch`**（L0.2 实测）：不写时 pane 高度退化为内容高（`vh == ch`），`etaf-scroll-by` 返回 0，滚动区静默失效。另外 `etaf-splitter` 的 `&key` 白名单里没有 `:flex-grow` / `:min-height`，要给中间区撑高必须**外层包裹**（`box` 或 `flex` 皆可，几何等价）。
- **batch 布局断言必须 `(let ((ebox-viewport-height N)) …)` 固定视口**，否则假绿：`emacs -Q --batch` 下 `ebox--default-viewport-height` 为 nil、`(set-frame-height nil 40)` 不改 `frame-height`（实测恒 25），不固定视口时「底栏是否贴底」「中间区是否可滚」都无从判定。绑定必须包住 `ebasecamp-ui-open`（mount 时读该变量）。
- **不要 `%S` 打印 `ebox-node-layout`**：布局结构里有指向节点/父节点的循环引用，未开 `print-circle` 会卡死会话。取值用 `(ebox-node-geometry node)`（返回 `:x/:y/:width/:height` 的 plist）或 `ebox-geo-vh` / `ebox-geo-ch` / `ebox-geo-bw` / `ebox-geo-bh`。
- **不要改 etaf / etaf-ui / ebox**；L0 探针若证伪 splitter 方案，改自绘两栏（`row` + 固定百分比列 + 分隔线），仍不改第三方
- 布局断言依赖 batch 下的窗口几何：`emacs -Q --batch` 的 frame 高度有限；**先用 L0.1 的 ⓪ 验证 `set-frame-height` 是否生效**，不可靠则只用 `ebox-node-layout` 几何判据，不要改 Makefile
- `:min-height '(lh 0)` 是让中间区可收缩的关键；漏写会导致中间区拒绝收缩 → 整窗继续滚动
- 底栏 `:flex-shrink 0` 必须显式写；`row` 默认可能参与收缩
- 主题取色要处理「face 未定义」的情形：基础色 `face-attribute` 返回 `unspecified` 时回退到**内置 palette 同名键**（不是回退到 `default` 的对应属性，避免自指）；状态色不经 face
- 主题覆盖范围以 T4 的 35 个 token 为准；未覆盖的 token 继续走 etaf-ui palette 回退，但那些组件在界面上不出现（不要为了「全量」而覆盖 playing-card / shell / window）
- `enable-theme-functions` 是 Emacs 29+ 的 abnormal hook；本机 31.1 可用；挂载与卸载必须对称（`ebasecamp-ui-close` 时移除）
- ratio 持久化：路径用 `ebasecamp-cache-directory`；写入前 `make-directory` 递归创建；用 `make-temp-file` + `rename-file` 原子覆盖；读取必须 `(let ((read-eval nil)) …)` 且只接受 `(:split-ratio NUMBER)`；读到数字后钳制到 `[min-ratio, max-ratio]`（否则渲染期 `etaf-check-prop` 会 signal，界面打不开）
- `ui-state.el` 是运行时状态缓存，不是清单：ADR-0004 必须点明它不破坏 ADR-0003 的「唯一写入口 `e`」边界
- `1`/`2`/`3` 是 printing key，绑定后 evil 的数字前缀在界面内失效（与 `q`/`g` 同理，可接受并写入文档）
- 项目定位用最长前缀匹配：`/a/b/c` 匹配 root `/a/b` 与 `/a` 时取 `/a/b`；路径比较前 `file-truename`，root 为空或不存在时跳过
- 第 7 条（监控默认隐藏、快捷键唤出）、第 3/5/6 条（写操作）、第 8 条（日志）不在本计划，不要顺手实现

## 后续计划（本计划完成后再建）

- **v0.5 写操作**：编辑 container 配置（表单：image / ports / env / volumes / command）、把配置移动到其他组的其他 project、分组/配置/项目 CRUD。写盘策略：按组块替换（`read` 定位 `(ebasecamp-define-group <name> …)` sexp 边界），保留其它块注释；写后 `ebasecamp-config-load` 零错误，失败回滚
- **v0.6 观测**：project 监控（默认**不显示**，用快捷键唤出；首版 CPU% / 内存，`docker stats --no-stream`）、日志查看（首版 `docker logs --tail N` 一次性，follow 作为可选项）
