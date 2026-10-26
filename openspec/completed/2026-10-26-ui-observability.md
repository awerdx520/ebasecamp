# ebasecamp v0.6 — 界面观测能力（按钮显示键 / hjkl / avy）

## 当前状态

- 阶段：**已归档**（2026-10-26 用普通 `mv` 从 `openspec/active/` 移入 `openspec/completed/`，未用 `git mv`）
- 已确认：方案 ✅（D1 `j`/`k` 焦点移动 / D2 `h`/`l` 树折叠 / D3 avy 可选依赖）/ 计划 ✅ / 独立审查 ✅（两轮：首轮「有条件通过」，修 6 项 + 3 处措辞；次轮通过）
- 结果：批次 1 / 2 / 3 / 4.1 / 4.3 / 4.4 完成；**任务 4.2 用户选择跳过**（保留未勾选）
- 测试基线：468 → **481**（批次 1 +4 / 批次 2 +2 / 批次 3 +5 / 批次 4.4 补测 +2）
- L3：4.2 用户目检**未执行**（用户 2026-10-26 明确跳过）；交互正确性由 479/479 测试 + 批次 3 的真实界面探针替代覆盖（`f` → 提示字母 → `point` 与焦点一致、`overlay-lists` 为 0、轮询暂停后恢复）
- 关键教训：`etaf-tree` 不为条目生成 ref（`etaf-runtime-host-node` 对树 key 恒 nil），树项定位改用「顺序对齐 + 数量安全阀」；新键必须追加 `--root-keys` 表尾，否则挤掉 `?` 首屏断言
- 回滚点：HEAD `f04f4bf`（本轮改动未提交）
- 后续：v0.7，或 tech-debt #20 / #41 / #42 / #43 / #44

## 目标

1. **键位可发现性**：底栏与段头的生命周期按钮上直接显示对应键（`[I] 导入 compose` / `[s] 启动选中` …），且提示文案与 `?` 帮助同源不漂移。
2. **vim 手感导航**：`j`/`k` 移动**焦点**（选中组不变）、`h`/`l` 在树内折叠/展开；保留 `n`/`p`（换组）与 `1`/`2`/`3`（跳区域）语义不变。
3. **按字母跳转**：`f` 触发 avy 跳转到组 / 配置 / 服务行；无 avy 时降级 `completing-read`。

## 非目标

- 不设 `etaf-set-direction-scheme 'vim`（全局变量，冲突即 `user-error`，见调研）
- 不改 `n` / `p` / `1` / `2` / `3` / `t` 等既有键语义
- 不做键位可配置化（`defcustom` 化整套键表）
- 不改默认 `:split-ratio` 与布局主题
- 不覆盖视口外节点（`ebox-node-position` 对未绘制节点返回 nil，接受「只跳可见项」）

## 设计决策

### A 按钮旁显示键

- **拼接位置**：`ebasecamp-ui--footer-button` 与 `--section-button` **内部**拼接，各新增一个可选的 `key` 参数（调用方传键名）。**label 参数值保持不变**，因此 `--goto-section` 的 `search-forward "启动选中"` 与 `header-buttons-disabled-when-busy` 的 label 断言都不破。
- **但替身 arity 会破**：`header-buttons-disabled-when-busy`（`test/ebasecamp-ui-tests.el:810`）用 **5 参** lambda 打桩 `--section-button`，而 `--instance-header` 会改为 6 参调用 → `wrong-number-of-arguments`。批次 1 必须把该替身改为**兼容写法** `(&rest _)`（或 `(label action variant inst disabled &optional key)`），**不要**写成 6 个必填参数 —— 1.1 阶段生产代码仍是 5 参调用，写死 6 必填会引入计划外的 `wrong-number-of-arguments` 红；这与 v0.5.2「新增可选参数打破旧替身」是同一类问题。
- **形态**：`(format "[%s] %s" key label)`；`key` 为 nil 时输出与原 label 逐字节一致（回归保护）。
- **映射**：
  - 底栏：`I` → 导入 compose、`o` → 导出 compose、`D` → 销毁环境（与 `--root-keys` 的 LABEL 完全一致）
  - 段头：`s` → 启动选中、`x` → 停止选中、`r` → 重启选中（按钮 label；键表 LABEL 是「启动该段选中」等**更长的形式**）
- **防漂移判据（写死，不留到实现时拍脑袋）**：新增常量 `ebasecamp-ui--button-key-hints`（`((LABEL . KEY) …)`），一致性测试断言两件事：
  1. 每个 (LABEL . KEY) 的 **KEY 必须存在**于 `--root-keys` 或 `--section-keys`；
  2. 找到的条目的 LABEL 必须满足 `(string-prefix-p 按钮LABEL 键表LABEL)` —— 按钮用短形式、键表用长形式（`启动选中` 是 `启动该段选中` 的前缀；底栏三键两者相同）。**实测修正**：段级这一条**不成立**（`启动该段选中` 的第三个字符是「该」），批次 1 改为「按序包含」判据，见「批次 1 记录 · 与计划的偏差 1」。
  这两条足以防「键绑错」与「文案漂移」，又不要求两处文案逐字相同。
- **宽度**：段头提示只进第二行（三个按钮行），估算 14 → 26 列，右栏 ~55 列，安全；第一行（配置名 + 两个 badge）不动。

### B hjkl

- 新增 4 个**零参交互命令** `--move-focus-up` / `-down` / `-left` / `-right`（`:keys` 的 COMMAND 槽要求 `commandp` + `call-interactively`，且必须零参），内部调一个非交互 helper `--move-focus (direction)` 转交 etaf 的方向链路。`j` → `'down`、`k` → `'up`、`h` → `'left`、`l` → `'right`。**不要**直接把 `etaf-direction` 绑进 `:keys` —— 它有 `(interactive)` 且会 `completing-read` 问方向（`etaf-keys.el:695-701`），按键时会弹提示；`--focus-tree` 等既有命令的注释已警告过这一点。
- `h`/`l` 在树内由 `etaf-tree` 已有的 `:on-direction`（`right` 展开、`left` 收起）消费，**不新增树代码**；到边界时按框架既有行为外溢（实测确认）。
- 四个键**追加到 `--root-keys` 表尾**（不可插在最前，否则挤掉 `?` 首屏 4 条断言），LABEL 分别写「焦点下移」「焦点上移」「折叠」「展开」。
- 既有精确集合用例（`root-keys-complete`、`root-keys-final-set` 的长度 16）必须同批次更新为 20。

### C avy 跳转

- 触发键 `f`，命令 `ebasecamp-ui-avy-jump`（追加到 `--root-keys` 表尾，LABEL「跳转到组/配置/服务」）。
- **候选收集**（语义路径，只收集组 / 配置 / 服务行）：
  1. 从 `ebasecamp-ui-session` 的 state 取组名与配置名，服务行来自各段 `:records`；
  2. 每个候选映射到对应 ref（组用 `--group-key`、配置用树 key、服务行用 `--row-ref` 的 key）；
  3. ref → `etaf-runtime-host-node` → `ebox-node-position` 取 buffer 位置；位置为 nil（视口外/未绘制）的候选**跳过**并计数，全部跳过时 `message` 说明「没有可见的跳转目标」。
- **执行**：`(require 'avy nil t)` 成功 → 用 `avy-process`（候选为 `(POS . KEY)` 或 avy 期望的形态，实现时按 avy 实际 API 校准）；失败 → 降级 `completing-read`（候选名列表）→ 选中后 `goto-char` + `ebox-focus` 到对应 ref（或最接近的可见位置）。
- **轮询竞争**：jump 前记录 `(ebasecamp-status-running-p)` 与 `ebasecamp-status--tick-function` 的当前值，`unwind-protect` 中恢复 —— 防止 3 秒刷新重渲染导致 overlay 错位/残留。两个接口细节必须遵守（`lisp/ebasecamp-status.el:202-226`）：`ebasecamp-status-stop` 会**清空** `--tick-function`；`ebasecamp-status-start` 会**立即 tick 一次**（跑 `docker ps`）。因此恢复时要把先前保存的 tick-function 传回 `start`，且**只在原本 running 时才恢复**（原本已停止就不要启动）。
- **只读**：界面 buffer 是只读的，avy 只用 overlay，不改 buffer；若实测 `avy--process` 与 etaf 的 `emulation-mode-map-alists` 冲突，退化为「显示候选编号 + `read-key`」的自实现提示（同批次内决定，计划记录实测结论）。

### D 文档

新增 `docs/adr/0010-ui-observability.org`：键位可发现性（按钮提示与键表同源）、hjkl 语义（焦点移动而非换组、h/l 折叠、禁用 `etaf-set-direction-scheme`）、avy 可选依赖与降级路径、视口外不跳的边界。

## 任务

### 批次 1：按钮旁显示键

- [x] 1.1 红：`test/ebasecamp-ui-tests.el` 新增 3 项 —— ①底栏三个按钮的 label 含 `[I]` / `[o]` / `[D]` 前缀且仍含原文案子串；②段头三个按钮含 `[s]` / `[x]` / `[r]`；③`--footer-button` / `--section-button` 在 `key` 为 nil 时输出与原 label **逐字节一致**（回归保护）。**同时修既有用例**：`header-buttons-disabled-when-busy` 的 5 参 `--section-button` 替身改为**兼容写法** `(&rest _)`（或 `(label action variant inst disabled &optional key)`），**不要**写成 6 个必填参数 —— 1.1 阶段生产代码仍是 5 参调用，写死 6 必填会引入计划外的 `wrong-number-of-arguments` 红
      （依赖：无）验收：**FAILED**（①② 红，③ 天然绿）
- [x] 1.2 红+绿：新增常量 `ebasecamp-ui--button-key-hints` 与一致性测试 1 项（判据见「设计决策 A · 防漂移判据」：KEY 存在于键表 + 按钮 LABEL 是键表 LABEL 的前缀）；实现 A
      （依赖：1.1）验收：**`make check` 全绿**（基线 468 → 472），compile 零 warning
- [ ] 1.3 L3 目检（用户）：底栏与段头按钮可见键提示；`?` 帮助内容未变（与 2.3 / 3.3 合并到 4.2 一次真实界面目检 —— 减少打断）

### 批次 2：hjkl

- [x] 2.1 红：`test/ebasecamp-ui-tests.el` 新增 2 项 —— ①`j`/`k` 后用 `ebox-focused-node` 断言**焦点节点前后变化**，同时用 `selected-group` ref 断言**选中组不变**（`ebasecamp-ui-test--focused-within-p` 判的是「焦点在哪个区域」，不适用于「焦点移动」，不要用它）；②`h`/`l` 对可折叠组触发折叠/展开（断言 `expanded` ref 或树文本变化）。同时更新 `root-keys-complete` / `root-keys-final-set` 的精确集合与长度（16 → 20）
      （依赖：1.2）验收：**FAILED**（2 项新红 + 2 项既有因集合变化而红）
- [x] 2.2 实现 B（`--move-focus` + 4 个根级键追加表尾）
      （依赖：2.1）验收：**`make check` 全绿**（472 → 474），compile 零 warning
- [ ] 2.3 L3 目检（用户）：`j`/`k` 焦点在树内上下移动、右栏不变；`h`/`l` 折叠/展开生效；`n`/`p` 仍换组（合并到 4.2 一次真实界面目检）

### 批次 3：avy 跳转

- [x] 3.1 红：`test/ebasecamp-ui-tests.el` 新增 5 项 —— ①候选收集：构造含 2 组 1 配置 2 服务行的界面，断言候选数量与名称；② avy 路径：`cl-letf` 打桩 `avy-process` 捕获候选，断言被调用一次且候选非空；③降级路径：打桩 `(require 'avy nil t)` 返回 nil → 断言走 `completing-read` 且选中后焦点落到目标；④跳转期间状态轮询被暂停并恢复（打桩 `ebasecamp-status-stop` / `start`，断言 `start` 收到先前保存的 tick-function 且调用顺序正确）；⑤无可见候选时 `message` 且不报错。**同时更新** `root-keys-complete` / `root-keys-final-set` 的精确集合与长度（20 → 21，新增 `f`）
      （依赖：2.2）验收：**FAILED**（既有 474 项中 2 项因集合变化而红 + 5 项新红）→ 实测 `Ran 479 tests, 472 results as expected, 7 unexpected` ✅
- [x] 3.2 实现 C（`--avy-candidates` / `--avy-jump` / `f` 键追加表尾 / 轮询暂停恢复 / 降级）
      （依赖：3.1）验收：**`make check` 全绿**（474 → 479），compile 零 warning；若 avy 与 etaf 键层实测冲突，改自实现提示并把结论写入批次记录
      → 实测全绿（479 / 0 unexpected）；实际函数名为 `--avy-targets` / `--avy-jump-visible` / `ebasecamp-ui-avy-jump`，avy 与 etaf 键层**无冲突**（见批次 3 记录「偏差 1」）
- [ ] 3.3 L3 实测记录：真实界面按 `f` → 出现字母提示 → 跳转到选中组/配置；滚动区外目标的行为记录（合并到 4.2 一次真实界面目检）

### 批次 4：文档、目检与归档

- [x] 4.1 文档：`docs/adr/0010-ui-observability.org`、`Readme.org`（键位表加 `f`/`j`/`k`/`h`/`l`）、`docs/user-guide.org`（键位与按钮提示说明）、`docs/architecture.org`（UI 层键位来源）、`CHANGELOG.md` `## [0.6.0]`、`AGENTS.md`（基线、当前状态、ADR 清单加 0010）、`openspec/decisions.md`、版本号 14 处 `0.5.4` → `0.6.0`
      （依赖：3.3）验收：grep 命中；`make check` 仍全绿 ✅（479/479、compile 零 warning、check-parens 26 files；残留 `Version: 0.5.4` = 0）
- [ ] 4.2 用户目检（真实界面）：按钮键提示、hjkl、`f` 跳转三项各一次
      （依赖：4.1）验收：**用户确认 ✅**（用户 2026-10-26 明确选择跳过；替代覆盖见「## 当前状态」）
- [x] 4.3 归档：计划移入 `openspec/completed/`，`## 当前状态` 写明完成；`AGENTS.md` 当前状态同步
      （依赖：4.2）验收：`openspec/active/` 为空 ✅（2026-10-26 实测：普通 `mv` 移入 `openspec/completed/2026-10-26-ui-observability.md`，未用 `git mv`；`ls -A openspec/active/` = 0 项；`make check` 仍 479/479、compile 零 warning、check-parens 26 files；`AGENTS.md` 进行中计划改「无」并把 v0.6 追加进已归档列表）

## 文档清单

| 文档 | 更新 |
|---|---|
| `docs/adr/0010-ui-observability.org` | 新 ADR（键位可发现性 / hjkl 语义 / avy 可选依赖与降级 / 视口外边界） |
| `Readme.org` | 键位表补 `f` / `j` / `k` / `h` / `l` 与按钮提示说明 |
| `docs/user-guide.org` | 键位表与「按钮上的方括号提示」说明 |
| `docs/architecture.org` | UI 层键位来源（`--root-keys` / `--section-keys` / `--button-key-hints` 三者关系） |
| `docs/troubleshooting.org` | 键位相关条目同步：约 `:437-490`（第 11/12 节）、约 `:484`「根级 9 条 + 段内 5 条」的陈旧计数、约 `:472`「吞掉所有未绑定的 printing key（含 `i`）」需改为「`f` / `j` / `k` / `h` / `l` 已绑定，不再被吞」 |
| `CHANGELOG.md` | `## [0.6.0]` |
| `AGENTS.md` | 基线（468 → 预计 479）/ 当前状态 / ADR 清单加 0010 |
| `openspec/decisions.md` | 追加决策行 |
| 14 处 `Version:` | `0.5.4` → `0.6.0` |

## 验证标准

- **L1**：`make check-parens` + `make compile`（零 warning）
- **L2**：`make test`，基线 468 → 预计 479（批次 1 +4、批次 2 +2、批次 3 +5，以实测为准）
- **L3**：批次 1.3 / 2.3 / 3.3 / 4.2 的目检与实测记录
- 每批次更新「## 当前状态」

## 注意事项

- **新键一律追加到 `--root-keys` 表尾**：插到前面会挤掉 `help-surface-mentions-keys` 首屏的 4 条断言。
- **`label` 参数值不变**：键提示在 `--footer-button` / `--section-button` 内部拼，否则 `header-buttons-disabled-when-busy` 与 `--goto-section` 的 `search-forward` 锚点会破。
- **不要设 `etaf-set-direction-scheme 'vim`**：全局变量 + 冲突 `user-error`。
- **`--root-keys` 的精确集合用例必须随批次同步**（16 → 20 → 21），不要为了让测试过而改成「包含」断言（会失去漂移防线）。
- **avy 期间必须暂停状态轮询**：3 秒刷新会重渲染并重写行，overlay 可能错位或残留。
- **视口外节点** `ebox-node-position` 返回 nil：跳过并在全部跳过时 `message`，不要 goto 到错误位置。
- **`f` 键可能与 evil 的 `f`（char motion）心智冲突**：界面内根 Host 的 `:key-scope 'local` 会吞掉未绑定 key 并优先 root keys，实现后实测确认；文档里注明「界面内 `f` 是跳转」。
- 同一文件多次 `edit_file` 不得并行。
- 安全点：每批次动手前 `git stash create`（不改工作区），不要 `git add` / `commit`。

## 批次记录

（执行时按批次追加。）

### 批次 1：按钮旁显示键（2026-10-26 完成）

状态：1.1 ✅ / 1.2 ✅ / **1.3 未做**（与 2.3 / 3.3 合并到 4.2 一次真实界面目检）。

**用例分摊（+4，基线 468 → 472）** —— 全部在 `test/ebasecamp-ui-tests.el` 新分节
「批次 1（v0.6 计划「设计决策 A」）：按钮旁显示键」（`:3543`）：

| 用例 | 行号 | 断言要点 |
|---|---|---|
| `ebasecamp-ui-test-footer-buttons-show-keys` | `:3567` | 主界面渲染文本同时含 `[I]`+「导入 compose」、`[o]`+「导出 compose」、`[D]`+「销毁环境」（6 条：键提示存在 **且** 原文案仍在） |
| `ebasecamp-ui-test-section-buttons-show-keys` | `:3583` | 挂载 `--instance-section` 的文本含 `[s]` / `[x]` / `[r]` 与三个原文案 |
| `ebasecamp-ui-test-button-key-nil-keeps-label` | `:3608` | `KEY` 省略时 `--footer-button` / `--section-button` 的输出 `string-trim` 后**逐字等于**原 label，且不含 `[` |
| `ebasecamp-ui-test-button-key-hints-match-key-tables` | `:3626` | 遍历 `--button-key-hints`：① KEY 必在 `--root-keys` 或 `--section-keys` 里（`hits` 非空）；② 每个命中条目的 LABEL 必须「按序包含」按钮文案 |

辅助函数 `ebasecamp-ui-test--label-subsequence-p`（`:3552`）：判断 SHORT 的字符是否按序出现在 LONG 中 —— 承载「按钮短形式 vs 键表长形式」的等价关系（见偏差 1）。

**实现要点**（`lisp/ebasecamp-ui.el`）：

- `ebasecamp-ui--button-key-hints`（`:1349`）：6 条 `((LABEL . KEY) …)`，**位于 `--footer-button` 之前** —— `byte-compile-error-on-warn` 下先定义后使用，且 docstring 明确它是「渲染索引」而非键位事实源。
- `ebasecamp-ui--button-label`（`:1362`）：`(if key (format "[%s] %s" key label) label)`，`key` 为 nil 时逐字节返回原 label。
- `--footer-button`（`:1366`）新增 `&optional key`，`:label (ebasecamp-ui--button-label label key)`；`--footer-view`（`:1377`）三处传 `"I"` / `"o"` / `"D"`。
- `--section-button`（`:1536`）新增 `&optional key`（形参跨行排布，与既有 `instance disabled` 同一续行风格）；`--instance-header`（`:1553`）三处传 `"s"` / `"x"` / `"r"`。
- `label` 参数值保持不变 → `--goto-section` 的 `search-forward "启动选中"` 锚点、段内替身的 label 断言、`renders-footer-buttons` 的 contains 断言全部未改仍绿。

**红绿证据**：

- 红（实现前，`make test`）：`Ran 472 tests, 469 results as expected, 3 unexpected` —— 红项 = `footer-buttons-show-keys`（`contains-p text "[I]"` → nil）、`section-buttons-show-keys`（`contains-p text "[s]"` → nil）、`button-key-hints-match-key-tables`（`(void-variable ebasecamp-ui--button-key-hints)`）；③ `button-key-nil-keeps-label` 天然绿；既有 468 项零回归。
- 绿（实现后，`make check`）：`check-parens OK (26 files)`；`compile` 零 warning（单独 `make compile` 输出 0 行、exit 0、产出 12 个 `.elc`）；`Ran 472 tests, 472 results as expected, 0 unexpected`。技术债 #20 未抖，未复跑。

**与计划的偏差（3 项，均在本批次内闭环）**：

1. **「按钮 LABEL 是键表 LABEL 的前缀」不成立**（「设计决策 A · 防漂移判据」第 2 条）。实测 `(string-prefix-p "启动选中" "启动该段选中")` = nil —— 段级键表 LABEL 的第三个字符是「该」。改用「按序包含」（`--label-subsequence-p`）：它是 prefix 的严格超集，仍能拦住「键绑错」与「换成不相干文案」，又不要求两处逐字相同。**未采用**的替代方案：把段级键表 LABEL 改成短形式 —— 会连带 `help-data-includes-labels`（断言「启动该段选中」等 5 条）与 `?` 帮助文案，改动面更大。若需改口径请指示。
2. **`--goto-first-checkbox` 必须换定位方式**（计划文件清单未列，属实现 A 的连带修复）。原实现 `search-forward "["`：键提示引入 `[s]` / `[x]` 后先命中按钮提示，`--checkbox-ref-at-point` 取到 nil，导致既有用例 `checkbox-refs-are-stable` 与 `spc-activates-checkbox` 变红（实测 2 项）。只认 mark 字形同样不行：`[x]` 既是勾选态 mark，又是「停止选中」的键提示 `[x]`。最终实现为「逐个候选 mark + `--checkbox-ref-at-point` 自校验」，与按钮文案彻底解耦（找完仍无命中则 `error`）。
3. **既有替身取 `&optional _key`**（计划允许的两种写法之一），并把注释改为记录 arity 演进（C4 的 `INSTANCE`、v0.6 的 `KEY`）。

安全点：`git stash create` 返回空（工作区无 tracked 改动，只有未跟踪的 `openspec/active/`）→ 本批次回滚等价于 `git checkout -- lisp/ebasecamp-ui.el test/ebasecamp-ui-tests.el`；实际未触发回滚。

### 批次 2：hjkl（2026-10-26 完成）

状态：2.1 ✅ / 2.2 ✅ / **2.3 未做**（合并到 4.2 一次真实界面目检）。

**用例分摊（+2 新增 / 2 修改，基线 472 → 474）**：

| 用例 | 行号 | 动作 | 断言要点 |
|---|---|---|---|
| `ebasecamp-ui-test-j-k-move-focus-not-selection` | `:3684` | 新增 | `--focus-region 'tree` 落焦点 → 记 `--focused-ref` 与 `selected-group` → `j`：焦点 ref **变化** 且 `selected-group` 仍是 `mysql` → `k`：焦点 ref **回到原值** 且选中组仍不变 |
| `ebasecamp-ui-test-h-l-toggle-tree-expansion` | `:3710` | 新增 | 焦点在组节点（默认展开，`expanded` = `("group/mysql")`）→ `h`：`expanded` 不再含该组、焦点 ref **不动** → `l`：`expanded` 恢复 `("group/mysql")`、焦点 ref 仍不动 |
| `ebasecamp-ui-test-root-keys-complete` | `:1497` | 修改 | 精确集合 16 → 20（加 `h j k l`，按字母序插入 `g` 与 `n` 之间）；docstring 补键位来源 |
| `ebasecamp-ui-test-root-keys-final-set` | `:2057` | 修改 | `(= 20 (length keys))` + 同一精确集合；docstring 16 → 20 |

新增辅助函数（`test/ebasecamp-ui-tests.el`）：`--focused-ref`（`:2746`）返回焦点节点的 Host ref（**不用 `equal` 比 `ebox-node` 对象**：节点带 parent 指针是圆形结构，`equal` 既慢又不可靠；ref 形如 `(etaf-host N M)` 是普通列表）、`--expanded`（`:2756`）读会话 `expanded` ref。

**实现要点**（`lisp/ebasecamp-ui.el`）：

- `--move-focus`（`:2490`）非交互 helper，单行转交 `(etaf-direction direction)`；`--move-focus-down/up/left/right`（`:2499` / `:2504` / `:2509` / `:2515`）四个零参交互薄包装（`:keys` 的 COMMAND 槽要求 `commandp` + `call-interactively`，而 `etaf-direction` 的 `(interactive)` 会 `completing-read` 问方向）。
- `--root-keys`（`:2521`）表尾追加 4 条（`:2558` 起）顺序 `j`（焦点下移）/ `k`（焦点上移）/ `h`（折叠（焦点左移））/ `l`（展开（焦点右移））；docstring 补「走 etaf 方向链路 / 树内先被 `:on-direction` 消费 / 不设 `etaf-set-direction-scheme` 的 vim 方案 / 追加表尾不动 `?` 首屏清单」。
- **未新增任何树折叠代码**：折叠完全由 `etaf-ui` 的 `etaf-tree` 分支节点 `:on-direction` 承担（`etaf-ui/lisp/etaf-ui-advanced.el`：`right` 未展开则 `toggle` 并返回 `handled`、`left` 已展开则 `toggle` 并返回 `handled`，其余 `release`）。

**红绿证据**：

- 红（实现前，`make test`）：`Ran 474 tests, 470 results as expected, 4 unexpected`，四项 condition 原文：
  - `j-k-move-focus-not-selection`：`(should-not (equal before after)) :form (equal (etaf-host 26 26) (etaf-host 26 26)) :value t` —— `j` 未绑定，`--focus-region` 之后按键无任何位移。
  - `h-l-toggle-tree-expansion`：`(should-not (member "group/mysql" (ebasecamp-ui-test--expanded))) :form (member "group/mysql" ("group/mysql")) :value ("group/mysql")` —— `h` 未绑定，折叠状态不变。
  - `root-keys-complete`：`(equal '("1" "2" "3" "D" "E" "I" "M" "S" "X" "e" ...) (sort ... ...))` 不成立（实得 16 项、期望 20 项）。
  - `root-keys-final-set`：`(should (= 20 (length keys))) :form (= 20 16) :value nil`。
- 绿（实现后）：`make check-parens` → `check-parens OK (26 files)`；`make compile`（先 `make clean`）→ **输出 0 行、exit 0、13 个 `.elc`**（零 warning）；`make test` → `Ran 474 tests, 474 results as expected, 0 unexpected`。技术债 #20 未抖，未复跑。
  — 中途一次 `make compile` 因新 docstring 里写了 `'vim'`（两个未转义单引号）报 `docstring has wrong usage of unescaped single quotes`，改成 `` `etaf-set-direction-scheme' 的 vim 方案 `` 后归零，属 L1 第 1 轮修复。

**`etaf-direction` 的实际调用形态**：

- 签名 `(etaf-direction direction &optional runtime)`（`etaf-keys.el:695`），非交互调用**只需 direction**；`runtime` 省略时按 `etaf--current-runtime` → 当前 buffer 的 runtime 兜底（`etaf-runtime-require-mounted`），因此命令在界面 buffer 内经 `execute-kbd-macro` 调用时天然命中主界面 runtime，**无需额外前置**（不需要手工 `etaf-runtime-require-mounted`，也不需传事件）。
- 内部顺序：最近的 Host `:on-direction`（返回 `handled` / `hold` → 停）→ 聚焦的 separator / slider 步进 → 区域内外溢 → 无 region 时 ebox 空间移动（到边界 `ebox-scroll-*`）。返回值是移动后的 Host ref，无处可移为 nil。
- 该函数**不能**直接进 `:keys`：带 `(interactive)` 且会 `completing-read` 问方向 —— 与计划「设计决策 B」一致。

**`h` / `l` 折叠的真实行为（探针实测，单组 `mysql` 默认展开）**：

| 状态 | 键 | `:on-direction` 结果 | 实际效果 |
|---|---|---|---|
| 组已展开 | `h`（left） | `toggle` 收起 + `handled` | `expanded` 由 `("group/mysql")` → `nil`，焦点 ref **不变**，返回原 ref |
| 组已收起 | `h`（left） | `release` | 落回方向移动：实测左侧无可进入区域 → 返回 **nil**（焦点不动，无外溢目标） |
| 组已收起 | `l`（right） | `toggle` 展开 + `handled` | `expanded` 恢复 `("group/mysql")`，焦点 ref 不变 |
| 组已展开 | `l`（right） | `release` | 落回方向移动：**外溢到右栏**，实测焦点 ref 从 `(etaf-host 1 26)` → `(etaf-host 1 94)`（右栏区域首个停靠点） |

即「默认全部展开」下 `h` 一定有效（收起），`l` 在收起态有效、在展开态外溢成焦点右移 —— 因此用例断言顺序写死为 `h` 后 `l`，**未**为断言好看改语义。用例只守护树内折叠（`expanded` 变化 + 焦点不动），外溢行为不写死 ref 数值（停靠点由 ebox 排序决定，会随 etaf-ui 组件结构变化）。

**与计划的偏差（2 项）**：

1. **`j`/`k` 用例里没有先把视口外的第二个组带进来**：计划允许「构造两个组」，实测单组 `mysql` 的三行（组 + 2 配置）已足够让 `down` 位移两次（`(etaf-host N 26)` → `29` → `32`），因此沿用 `--with-open-ui` 的单组夹具，少一处夹具改动。
2. **`h`/`l` 用例额外断言「焦点 ref 不动」**（计划只要求断言 `expanded` 变化）：`h`/`l` 走 `handled` 分支时焦点不应动，加这条才能区分「折叠」与「折叠 + 焦点乱跳」。同时**没有**断言展开态按 `l` 外溢到右栏 —— 那是框架行为、依赖停靠点排序，写死会把 etaf-ui 内部结构变更变成红。

安全点：`git stash create` → `071c03bc0f394c6ad81dbd2cdc3570ad2378b3b7`（工作区含批次 1 的两个 M；未跟踪的 `openspec/active/` 不入 stash，故回滚需另行保留计划文件）。未触发回滚。

### 批次 3：avy 跳转（2026-10-26 完成）

状态：3.1 ✅ / 3.2 ✅ / **3.3 未做**（合并到 4.2 一次真实界面目检）。

**设计要点（实现前先定，避免测试依赖真实 avy）**

- 「avy 是否可用」抽成唯一判定入口 `ebasecamp-ui--avy-available-p`（`(and (require 'avy nil t) t)`），测试只打桩它；因此 `make test` 的 load-path **不需要**含 avy（Makefile 未改）。
- 候选收集拆成纯函数 `--avy-targets`（只读会话 state，不碰 buffer）；位置解析单独成 `--target-position`（唯一碰 buffer 的环节）；跳转成 `--jump-to`。三段各自可打桩，测试不需要真实 avy、也不需要真实按键提示。
- 选择逻辑抽到 `--avy-jump-visible`：avy 分支把**位置列表**交给 `avy-process`，降级分支用 `--prompt` 选名字。命令本体 `ebasecamp-ui-avy-jump` 只负责「候选 → 位置 → 暂停轮询 → 选一个 → 恢复」。

**候选收集的实现形态**（`lisp/ebasecamp-ui.el`，插在 `--move-focus-right` 与 `--root-keys` 之间）

| 函数 | 职责 |
|---|---|
| `--avy-available-p` | `(require 'avy nil t)` 成功即 t |
| `--avy-targets` | `((NAME . KEY) …)`：组 → `(组名 . "group/组名")`；配置 → `("组名/配置名" . "config/组名/配置名")`；服务行 → `("组名/服务名" . "组名/服务名")`。按 KEY 去重（同组多份配置的同名服务只留一个） |
| `--tree-visible-keys` | 按树渲染顺序给出可见条目 key（组总可见；配置仅当组 key 在 `expanded` 里） |
| `--tree-button-nodes` | 树 Host（`ebasecamp-ui-tree`）子树内 `etaf-button` 类节点，渲染顺序 |
| `--tree-target-position` | 可见 key 列表与按钮节点列表**按序对齐**取位置；两者数量不等时返回 nil（宁可全放弃，也不跳到错条目） |
| `--target-position` | 树 key 走上面的对齐；服务行走 `--row-ref` → `etaf-runtime-host-node` → `ebox-node-position` |
| `--focus-at-position` | `goto-char` 后沿祖先链找可接收焦点的节点（`ebox-focus` 对不可聚焦节点 `user-error`） |
| `--jump-to` | 位置（可显式传入）+ `--focus-at-position`，返回落点 |
| `--avy-jump-visible` | avy 分支 / `--prompt` 降级分支 |
| `ebasecamp-ui-avy-jump` | 命令本体（`interactive`），根级 `f` |

**为什么树项要「按序对齐」而不是按文本匹配**（探针实测，`/tmp/ebc-probe3*.el`）：`etaf-tree` 是 etaf-ui 组件，**不为条目生成 ref**（`etaf-runtime-host-node` 只认注册 Host），条目节点也没有 `id` / `key` / `data` / `:help-echo` / `:aria-label`（`etaf` 把 `:aria-label` 从 fallthrough 里滤掉，见 `etaf-view.el` 的 `etaf--owned-semantic-property-p`）。按绘制文本匹配也不可行：窄栏里树标签被截断，且**截断后的绘制区间会与右栏文本粘连** —— 实测配置条目节点的 bounds 取出的文本是 `"     dev → 示例项  MySQL"`（尾部粘上右栏内容）。因此唯一既不依赖文本、也不改框架的办法是「可见条目顺序 = 树内按钮顺序」对齐 + 数量校验。

**avy 实际 API 形态**（`avy.el:868`）

- 签名 `(avy-process CANDIDATES &optional OVERLAY-FN CLEANUP-FN)`；`CANDIDATES` 可为位置列表（内部补成 `(POS . WINDOW)`），也接受 `(START . END)` 区间。
- 默认动作 `avy-action-goto`：**它自己 `goto-char`**，并返回选中位置。所以 avy 负责移动 point，插件负责把 ebox 焦点搬到同一节点（`--focus-at-position`）。
- 实测（batch 探针，avy 加入 load-path 后用 `execute-kbd-macro (kbd "f a")` 走真实路径）：`f` → 出现提示 → `a` 选中第一个候选 → `point` = 46、焦点节点位置 = 46（`(etaf-host 1 26)`，组 mysql 的树按钮）。**无 overlay 残留**（`overlay-lists` 前后都是 0），**avy 与 etaf 键层 / 只读 buffer 无冲突**，未走「自实现字母提示」分支。

**`--avy-targets` 返回的实际形态**（探针实测，2 组 / 1 配置 / 2 服务行夹具）

```elisp
(("mysql" . "group/mysql")
 ("redis" . "group/redis")
 ("mysql/dev" . "config/mysql/dev")
 ("mysql/mysql" . "mysql/mysql")
 ("mysql/mysql-ro" . "mysql/mysql-ro"))
```

对应位置（`ebox-viewport-height` 40）：`group/mysql` → 46、`config/mysql/dev` → 67、`group/redis` → 112、`mysql/mysql` → 304、`mysql/mysql-ro` → 355。

**轮询暂停的实现**（`ebasecamp-ui-avy-jump` 尾部）

```elisp
(let ((was-running (ebasecamp-status-running-p))
      (tick-function ebasecamp-status--tick-function))
  (when was-running (ebasecamp-status-stop))
  (unwind-protect
      (ebasecamp-ui--avy-jump-visible visible)
    (when was-running
      (ebasecamp-status-start tick-function))))
```

两个接口细节都遵守了：`ebasecamp-status-stop` 会清空 `--tick-function`，所以先存再 stop；`ebasecamp-status-start` 会立刻 tick 一次（跑 `docker ps`），所以**只在原本 running 时**恢复。实测（界面打开后 `running-p=t`）：avy 跳转后与降级跳转后 `running-p` 仍为 `t`、`--tick-function` 仍在。

**红绿证据**

- 红（实现前，`make test`）：`Ran 479 tests, 472 results as expected, 7 unexpected`，7 项正是 5 新 + 2 集合：
  - `avy-targets-collect`：`(void-function ebasecamp-ui--avy-targets)`
  - `f-uses-avy-when-available`：`((should (= 1 (length calls))) :form (= 1 0) :value nil)` —— `f` 未绑定，`avy-process` 一次都没被调
  - `f-falls-back-to-completing-read`：`((should (= 1 (length prompts))) :form (= 1 0) :value nil)`
  - `jump-pauses-status-polling` / `jump-reports-when-no-visible-target`：`(void-function ebasecamp-ui-avy-jump)`
  - `root-keys-complete`：`proper-lists-of-different-length 21 20 ... first-mismatch-at 10`
  - `root-keys-final-set`：`(should (= 21 (length keys))) :form (= 21 20) :value nil`
- 绿（实现后）：`make check-parens` → `check-parens OK (26 files)`；`make compile`（先 `make clean`）→ **输出 0 行、exit 0、13 个 `.elc`**（零 warning）；`make test` → `Ran 479 tests, 479 results as expected, 0 unexpected`。技术债 #20 未抖，未复跑。

**与计划的偏差（3 项）**

1. **函数名从 `--avy-candidates` / `--avy-jump` 改为 `--avy-targets` / `ebasecamp-ui-avy-jump`（+ 三个内部 helper）**：`--avy-jump` 会被误读成「执行跳转」，而命令体要做「收集 → 暂停轮询 → 选 → 恢复」，跳转本身交给 `--jump-to`。分层后每个环节都能单独打桩，测试不依赖真实 avy。
2. **大幅偏离计划「ref → `etaf-runtime-host-node` → `ebox-node-position`」的树项路径**（见上文「为什么树项要按序对齐」）：树条目没有 ref，`etaf-runtime-host-node` 对树 key 恒返回 nil。改为「可见条目顺序 ↔ 树内按钮顺序」对齐 + 数量校验；服务行仍走计划里的 ref 路径（`--row-ref` 是插件自己声明的 Host ref，可靠）。**未采用**「给 `etaf-tree` 传 ref」—— 那要改 etaf-ui 组件，超出插件边界。
3. **跳转不改选中组、不切勾选**：计划 3.x 提到降级分支「`--select-key`（组/配置）或 `--toggle-row`/聚焦（服务行）」。实测 `--select-key` 会重建 state 并触发整树重渲染 → 刚落点的位置立刻失效；`--toggle-row` 更是把导航键变成写操作（勾选状态被跳转键改写）。因此 `f` 只做「移动 point + 搬焦点」，选中组仍由 `n`/`p`/`RET`/鼠标负责。测试据此改为「打桩 `--jump-to` 后断言 key 正确」而不是断言「选中组变化」。

安全点：`git stash create` → `93f5bcc70598612fc32ec137a1189fdbfb8f1db2`（工作区含批次 1/2 的两个 M；未跟踪的 `openspec/active/` 不入 stash）。未触发回滚。

**修复记录（L2 第 1 轮）**：实现后第一次 `make test` 只剩 1 项红（`f-falls-back-to-completing-read`）—— `cl-find` 默认判据是 `eql`，按名字找 plist 时字符串永远不匹配；改为 `:test #'equal`（位置仍用 `:test #'eql`）。

### 批次 4：文档、目检与归档

#### 4.1 文档沉淀 + 版本号 + 清理杂散文件（2026-10-26 完成）

状态：4.1 ✅ / 4.2 未做 / 4.3 未做。**不改 `lisp/` 与 `test/` 任何代码**（本批次纯文档 + 版本号）。

**0. 清理杂散文件**

`1.log`（仓库根，未跟踪）经 `head -5` 确认为**探针工具调用日志**：内容是 `emacs -Q --batch -L . -L lisp -L …/straight/build-31.1/etaf … -l test/ebasecamp-ui-tests.el -l /tmp/ebc-hjkl-probe.el` 与 `grep -E "PROBE|error|Error"` 这类命令回显（批次 2 的 hjkl 探针留下的），不含任何源码或文档。已 `rm` 删除。

**1. 逐文档改动摘要**

| 文档 | 改动 |
|---|---|
| `docs/adr/0010-ui-observability.org` | **新增**（约 150 行）。结构对齐 ADR-0009：背景 → 决策 1（按钮显示键 + 1a 一致性判据与局限 + 1b 勾选列连带修复）→ 决策 2（hjkl）→ 决策 3（avy 跳转 + 3a 树项位置解析假设被推翻 + 3b 只搬焦点 + 3c 视口外）→ 已知边界 → 否决项 → 验证证据 → 与既有 ADR 的关系 → 不变量 → 状态 |
| `Readme.org` | 首行版本 `0.5.3` → `0.6.0`（原值本就落后 v0.5.4）；「界面键位」引言后新增**按钮方括号提示**段落（`[I] 导入 compose` 与 `?` 帮助同源）；根级键位表在 `1`/`2`/`3` 后插入 `j`/`k`、`h`/`l`、`f` 三行；表后补三段说明（焦点 vs 选中组、`h`/`l` 的折叠与外溢、`f` 只跳可见目标且**界面内不是 evil 的 char motion**） |
| `docs/user-guide.org` | 布局表「底栏」行加键提示；「段头两行」第 2 项改为 `[s]/[x]/[r]` 并说明与 `?` 同源；「底部三个按钮」表三行加 `[I]/[o]/[D]`，表后补键提示说明；「布局与导航」由「五件事」改「六件事」并新增第 6 项（hjkl + `f`）；「界面操作与键位」在「切换组」后新增 **快速到某个组 / 配置** 小节（`f` 三条要点：avy / 无 avy 降级 / 只跳可见目标 + 只搬焦点；`j`/`k` 焦点移动；`h`/`l` 折叠与外溢；与 `1`/`2`/`3` 的分工） |
| `docs/architecture.org` | 键位三层表「根 Host 9 条」→「21 条」；新增 **键位来源：事实源 → 渲染索引 → 按钮文案**（三层表 + 拼接在渲染层 / 参数零变更的理由 + 一致性判据含「按序包含」非前缀 + 为何不合并成一张表）；新增 **勾选列定位改用 ref 自校验**（原 `search-forward "["` 为何破、只认 mark 为何也不行、候选 mark + ref 自校验） |
| `docs/troubleshooting.org` | 第 12 节「吞键」条：`i` 仍被吞，但 `f`/`j`/`k`/`h`/`l` 已绑定；同节「排查命令」后的 `?` 说明由「根级 9 条 + 段内 5 条」→「根级 21 条 + 段级 5 条」；第 12 节「修法」新增一条：hjkl/f 正常应有反应 + 无反应时如何自查 + `f` 不是 evil char motion |
| `CHANGELOG.md` | 插入 `## [0.6.0] - 2026-10-26`（Keep a Changelog：导语 + `### 新增` 3 条 + `### 修复` 1 条 + `### 变更` 2 条，含基线 468 → 479 的分批拆分）。**注意**：初稿误用 org 的 `=code=` 行内标记，已改为 markdown 反引号（`.md` 文件内 org 标记会原样显示） |
| `openspec/tech-debt.md` | 追加 #43 / #44 / #45（正文与任务给定文本逐字一致） |
| `AGENTS.md` | ①目录表 `ebasecamp.el` 行 `Version: 0.5.4` → `0.6.0`；②目录表 `docs/` 行 ADR 清单尾部加 `0010-ui-observability.org`；③「架构决策」行同样加 0010（含三条否决项摘要）；④测试基线 `468` → `479`（演进 `452 → 468（v0.5.4）→ 472 → 474 → 479`）；⑤「进行中计划」由「无」改为指向本计划（待 4.2 目检后归档）；⑥「下一步」改为 v0.7 或技术债 #20 / #41 / #42 / #43 / #44 |
| `openspec/decisions.md` | 追加 1 行（2026-10-26）：决策三件套（按钮显示键 + hjkl + `f` 跳转 avy 可选依赖）/ 理由（可发现性差 + 零外部依赖约束）/ ADR-0010 |
| 13 个 `.el` 文件头 | `;; Version: 0.5.4` → `;; Version: 0.6.0`（`ebasecamp.el` + `lisp/` 下 12 个） |

**2. 版本号检查**

- 改动数：**14 处**（13 个 `.el` 文件头 + `AGENTS.md` 目录表 1 处）；`Readme.org` 首行另有版本号，`0.5.3` → `0.6.0`（原值落后一个版本，顺手对齐）。
- `grep -rn "Version: 0.5.4" . | grep -v openspec/completed` → **0 命中**；`grep -rn "Version: 0.6.0" --include="*.el" .` → **13** 命中。

**3. 验证（`make check` 三段）**

| 段 | 命令 | 结果 |
|---|---|---|
| L1 括号 | `make check-parens` | `check-parens OK (26 files)` |
| L1 编译 | `make clean` + `make compile` | 输出 **0 行**、exit 0、产出 **13 个 `.elc`**（零 warning） |
| L2 测试 | `make test` | `Ran 479 tests, 479 results as expected, 0 unexpected` |
| 串联 | `make check` | exit 0（三段全绿；技术债 #20 未抖，未复跑） |

**4. 与计划的偏差（2 项，均属信息补充而非语义变更）**

1. **`--goto-first-checkbox` 实为测试助手 `ebasecamp-ui-test--goto-first-checkbox`**（`test/ebasecamp-ui-tests.el:1744`），不是 `lisp/` 里的生产函数。任务与批次 1 记录都用了简称，写 ADR 时按 *实际符号名* 表述（并点明它在 `test/` 里），避免后来者去 `lisp/` 里搜不到。
2. **`AGENTS.md` 的 v0.5.4 基线细分被压缩**：原文有「452 → 462 / 464 / 468 各自来自哪批」，改写为「452 → 468（v0.5.4）→ 472 → 474 → 479」一行演进链；细分仍留在 `openspec/completed/2026-10-26-yaml-block-scalar.md` 与 `CHANGELOG.md` 的 `[0.5.4]` 条目（同时删掉与「已归档」行重复的 v0.5.3 遗留说明，避免同一事实两处维护）。

**5. 清理的杂散文件**：`1.log`（已 `rm`）。

#### 4.4 代码审查后的修复与补测（2026-10-26 完成）

**审查结论**：code-reviewer 给「有条件通过」，2 项 important（跳转类型判别靠猜 key 前缀、关键不变量缺 ERT 守护）+ 2 处 nit。本批次全部处理，**生产代码只改 1 处**（`--target-position`），其余为补测与文档。

**修复（生产代码唯一改动）**：`--target-position` 的类型判别由「猜 key 前缀」改为「查事实源」。

- 改前：`(string-match-p "\\`\\(?:group\\|config\\)/" key)` 命中则走树定位，否则走行 ref。
- 问题：组名只受 `[a-z0-9_-]` 约束、**没有保留字** —— 组名叫 `group` 或 `config` 时，它的服务行 key（如 `config/redis`）会被判成树 key，`--tree-target-position` 找不到对应条目后返回 nil → 跳转静默失效（不报错、不跳，用户无从察觉）。
- 改后：`(member key (ebasecamp-ui--tree-visible-keys))` 命中才走树定位，否则走新抽出的 `--target-row-position`。判据与 key 长什么样无关，只与「它是不是当前可见树条目」有关。
- 顺手把行 ref 定位从内联代码抽成 `--target-row-position`（语义不变）：两条路径各自可打桩、可单独测，也让安全阀用例能断言「树定位失败时不会退回行路径」。

**补测（2 项，基线 479 → 481）**：

| 用例 | 断言要点 |
|---|---|
| `ebasecamp-ui-test-tree-target-safety-valve-rejects-mismatch` | 真实渲染界面后先断言 `--tree-target-position "group/mysql"` 返回位置（正常路径）；再 `cl-letf` 把 `--tree-button-nodes` 打桩成「少一个节点」（保留原函数引用后 `butlast`，避免自递归），断言返回 **nil**（数量安全阀生效、宁可不跳）；同一 key 经 `--target-position` 也只能得 nil（树定位失败不退回行路径） |
| `ebasecamp-ui-test-jump-does-not-change-selection` | 先 `--toggle-selected "mysql/mysql" t` 预置非空勾选集合（空集合无法证明「没被清空」）→ 记 `selected-group` 与 `selected-keys` → `--jump-to "group/redis" <pos>`（位置显式传入）→ 断言两者与调用前完全相同（跳转不改选中组、不切勾选） |

**首跑结果：两项天然绿**（`Ran 481 tests, 481 results as expected, 0 unexpected`），即实现与 ADR-0010 决策 3b「`f` 只搬焦点，不写状态」及 ADR 的「数量必须相等」安全阀一致，无需改实现迁就测试。

**nit（2 处）**：

1. `help-data-includes-labels` 的 docstring「16 条根级 LABEL」→「**21 条**根级 LABEL（含 N1 的三个区域跳转键，以及 v0.6 新增的 `f`/`j`/`k`/`h`/`l`）」。原值在批次 1/2/3 加键后已陈旧。
2. `button-key-hints-match-key-tables` 补兜底断言 `(should-not (string-empty-p label))` —— `--label-subsequence-p` 对空串恒真，空 LABEL 会让判据 ② 退化成永远通过的空壳。

**L1 过程中的一次自伤（非计划偏差）**：新用例首次写入时两个 `ert-deftest` 的收尾括号各少 1–2 个，`make check-parens` 报 `Unmatched bracket`。用 `read` 逐 form 定位到「第二个 form 吃掉到文件尾」，修正后 `check-parens OK (26 files)` —— 属编辑器内容的手工计数错误，实现与测试逻辑未变。

**验证**：`make check` 全绿 —— `check-parens OK (26 files)` / `compile` 输出 0 行、exit 0、13 个 `.elc`（零 warning）/ `Ran 481 tests, 481 results as expected, 0 unexpected`。

**与计划的偏差**：任务文本写「`### 4.4`」，实际用 `#### 4.4` 以便与同级的 `#### 4.1` 对齐（`###` 会让它脱离 `### 批次 4` 的层级）；任务文本的 `(ebasecamp-ui--jump-to (cons "group/xxx" <pos>))` 与真实签名 `(key &optional position)` 不符，按签名改为 `(--jump-to "group/xxx" <pos>)`。


