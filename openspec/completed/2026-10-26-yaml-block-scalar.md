# ebasecamp v0.5.4 — YAML 块标量（顶层 `content:` 多行保真）

## 当前状态

- 阶段：**已归档**（2026-10-26 由 `openspec/active/` 移入 `openspec/completed/`，用普通 `mv` 而非 `git mv`）
- 已确认：方案 ✅（用户 2026-10-26：走**方案 A** —— `--escape-string` 换行转义 + `--yaml-value` 块标量；**D2 保真**：含 `\r` 时不转 LF，一律双引号转义保真）/ 计划 ✅（用户确认）/ 独立审查 ✅（两轮：第 1 轮「有条件通过」，已修 L3 flag 集、`equal` 判据、文档清单 4 处、转义映射陷阱等 9 项；第 2 轮通过）
- 结果：批次 1 / 2 / **2.3** / 3.1 / 3.2 **全部完成**（2.3 为批次 2 暴露的 `|+` 拼接缺陷，属计划外插入的修复批次，由用户 2026-10-26 明确授权）
- 测试基线：452 → **468**（批次 1 +10、批次 2.3 +2、批次 3.3 补测 +4；`make check` 468/468、compile 零 warning、check-parens 26 files）
- L3：`datarush-go` 三个顶层 config 经导入 → 渲染后与原文 `content` `equal` 全等（340/340、159/159、896/896 字节；换行 14/14、8/8、35/35），`config -q` exit 0；`|+` 最小复现修复前后 False → True
- 关键教训：`config -q` 只校验语法不校验内容保真 —— 判据必须是 `config --no-interpolate --no-env-resolution --no-path-resolution --format json` 后逐键 `equal`
- 回滚点：HEAD `b6caef3`（本轮改动未提交，安全点 `git stash create` 见批次记录）
- 后续：v0.6（观测：按钮旁显示键 / `hjkl` / avy），或 tech-debt #20（docker 测试竞态）/ #41（生成物固定 `container_name`）/ #42

## 目标

1. **消除静默改内容**（技术债 #33）：顶层 `configs` / `secrets` 的 inline 多行 `content:` 经「导入 → 渲染」后换行不再丢失。
2. **两个层次同时保证**：
   - **保真层**（任何上下文）：`--escape-string` 转义 `\n` / `\r`，使双引号标量（含 flow 序列）不再被 YAML 折叠；
   - **可读层**（block 上下文）：`--yaml-value` 的映射/序列分支把多行字符串渲染为块标量（`|` / `|-` / `|+`）。
3. **单行字符串行为零变化**（避免生成物 diff 噪音）。
4. **影响面明确（非越界）**：
   - 走 **A2 块标量**（`--yaml-value` 的映射/序列分支）：顶层 `configs` / `secrets` 的 `content`、服务级 `environment` / `labels` 的值（它们经 `--yaml-map` → `--yaml-value`）；
   - 走 **A1 双引号转义**：`command` 等其他位置（`--service-body` 里的字符串走 `--yaml-string`、列表走 `--yaml-flow-sequence`，**不经** `--yaml-value`，因此不会被块标量命中，保真靠转义）。
   - 两类位置的多行值现状都会被折叠，属同一缺陷修复；单行值不受影响。

## 非目标

- 不引入通用 YAML 库（仓库零外部依赖约束）
- 不支持 YAML 锚点 / 标签 / 折叠标量（`>`）
- 不改清单落盘格式（`prin1` 的 `\n` 本就无损）
- 不在模型层新增「值形态白名单」校验（非字符串值仍按现有序列/标量规则渲染）
- 不改 `docker compose config` 的调用参数

## 设计决策

### A1 转义保真（`--escape-string`）

现状（`lisp/ebasecamp-compose.el:105`）只转义 `\` 与 `"`，真实换行会被带进双引号标量内部，YAML 解析时按 flow scalar 折叠成空格（这正是 #33 的机制）。

- 改为转义四类：`\` → `\\`、`"` → `\"`、换行 `\n` → `\\n`、回车 `\r` → `\\r`。
- **tab 不转义**（YAML 双引号标量允许字面 tab）。
- **映射函数必须分情况**（这是最容易写错的地方）：`\n` → 两字符 `\` + `n`（即 Elisp 字面量 `"\\n"`）、`\r` → `"\\r"`、其余（`\` 与 `"`）→ `(concat "\\" match)`。**不能**对换行复用 `(concat "\\" match)` —— 那会产出「反斜杠 + 真实换行」，YAML 双引号标量里仍然是换行，照样折叠。
- 实现用**一次** `replace-regexp-in-string` 配正则 `"[\\\\\"\n\r]"` + `cond` 分派的映射函数，天然满足「每个字符只转义一次」；不要写成多轮 `replace-regexp-in-string`（第二轮会把第一轮插入的反斜线再转义）。
- `--quote-required-p`（`:92`）**新增判定：字符串含 `\n` 或 `\r` → 必须加引号**（保证非块标量上下文走双引号转义路径，绝不会落到裸标量）。
- 该改动自动覆盖 `--yaml-flow-item`（它调用 `--escape-string`），因此 `command: ["sh","-c","line1\nline2"]` 这类 flow 序列也保真。

### A2 块标量（`--yaml-value`）

现状（`:160`）映射分支形如 `key: <scalar>`；新增分支：

- **判据** `ebasecamp-compose--block-scalar-p (value)`：`(and (stringp value) (string-match-p "\n" value) (not (string-match-p "\r" value)))` —— 含 `\r` 的字符串**不走块标量**（见「边界」）。
- **渲染** `ebasecamp-compose--yaml-block-scalar (string indent)`：
  1. 统计末尾换行数 `n`（`string-match "\n+\\'"` 的匹配长度，无匹配为 0）；
  2. chomping 头：`n = 0` → `|-`；`n = 1` → `|`；`n >= 2` → `|+`；
  3. 内容 = 去掉末尾 `n` 个换行后的字符串，按 `"\n"` 切分；
  4. 每个**非空**行加 `(make-string indent ?\s)` 前缀；**空行输出为空串**（不加缩进，否则会保留尾随空格）；
  5. 输出 `header + "\n" + (mapconcat #'identity padded-lines "\n") + (make-string n ?\n)`。
- 调用点：
  - 映射分支：块标量头跟在 `key:` **同一行**（渲染为 `content: |`），内容行缩进为 `indent + 2`；不要硬编码具体列数，统一由键的缩进 `indent` 推导（见下方「缩进对照」）。
  - 序列分支：渲染为 `- |`（`-` 与 `|` 之间**一个空格**），内容行缩进为 `indent + 2`；`|` 的 chomping 头按字符串末尾换行数选择，规则同映射分支。
- **缩进对照（必须按实测核对）**：顶层段由 `--file-declarations-section`（`:488`）以 `--yaml-map alist 2` 渲染 →
  `configs:`（0 缩进）→ `  prometheus_config:`（2）→ `    content: |`（4，即 `indent + 2`）→ 内容行 `      line1`（6 = 内容的 `indent + 2`，其中 indent = 4）。
  实现时以「键行缩进 indent、内容行缩进 indent + 2」这一条统一规则推导，不要硬编码 4/6。

### 边界（必须处理或明确不处理）

| 情形 | 处理 |
|---|---|
| 字符串无换行 | 走现有路径（`--yaml-scalar`），行为逐字节不变（回归保护） |
| 字符串含 `\r`（如 CRLF） | **不走块标量** → `--quote-required-p` 判必须加引号 → 双引号 + `\r`/`\n` 转义**保真**（D2 裁决：不改写内容） |
| 空字符串 | 维持 `""` |
| 字符串以换行开头（首行为空） | 块标量首行输出空行；L3 用真实 docker 复核还原 |
| 内容行原本含前导空格 | 保留（内容行 = indent 前缀 + 原行） |
| 内容行原本含 tab | 保留 |
| 内容行是纯空白（"  "） | 输出 indent + 原空白（属于内容，不折叠） |
| 字符串只有一个 `\n`（即 `"\n"`） | `n = 1` → `\|`，内容行是 1 个空行 → 实测复核 |
| 非字符串值（列表/映射） | 不进入块标量分支，行为不变 |

## 任务

### 批次 1：实现 + ERT（10 个 deftest）

- [x] 1.1 红：`test/ebasecamp-compose-tests.el` 新增 **10 项**（每项一个 `ert-deftest`，**不要**把多个断言拆成多个 deftest，计数必须严格是 10）—— ①`|`（末尾单换行 `"a\nb\n"`）；②`|-`（无末尾换行 `"a\nb"`）；③`|+`（`"a\nb\n\n\n"`，末尾换行数精确还原）；④空行与行首空格保留（`"a\n\n  b\n"`）；⑤单行字符串**不**变块标量（`"plain"` / `"has space"` 的输出逐字节不变，**回归保护、天然绿**）；⑥`--escape-string` 与 `--quote-required-p`：`"a\nb"` → `a\\nb` 且 quote-required 为 t（两项断言放**同一个** deftest）；⑦flow 序列里的多行字符串走转义（`--yaml-flow-sequence` 输出含 `\\n`、不含字面换行）；⑧顶层 `configs` 段整体渲染（`configs:` 0 / 键 2 / `content: |` 4 / 内容行 6，断言精确前缀）；⑨`"\n"`（单换行：`n=1` → `|`，**期望渲染文本精确为 `content: |` + 2 个换行**）；⑩`"\n\n"`（整段只有换行：`n=2` → `|+`，**期望精确为 `content: |+` + 3 个换行**）。**分工**：ERT 只断言渲染文本形态，YAML 往返正确性由批次 2 的 L3 复核（ERT 不跑 docker）
      （依赖：无）验收：**FAILED**，既有 452 项零回归（预期 `Ran 462 tests, 453 results as expected, 9 unexpected` —— 9 红为 ①②③④⑥⑦⑧⑨⑩，1 绿为 ⑤）
- [x] 1.2 实现 A1 + A2（`--escape-string` 的分派映射 / `--quote-required-p` 加「含 `\n` **或** `\r`」/ `--block-scalar-p` / `--yaml-block-scalar` / `--yaml-value` 的映射与序列两处调用）
      （依赖：1.1）验收：**转绿 + `make check` 全绿（452 + 10 = 462 expected / 0 unexpected）**，compile 零 warning

### 批次 2：L3 真实 docker 往返

- [x] 2.1 用 `/tmp` 隔离清单：把 `datarush-go` 的原 compose（`/home/thomas/Workspace/Work/datarush-go/docker-compose.yaml`）导入为 `probe-cfg` → 渲染生成物 → 用**完整 flag 集**读回：`docker compose -f <生成物> config --no-interpolate --no-env-resolution --no-path-resolution --format json`（**不变量 5：缺任一 flag 即违反**；`--environment` 不是 `config` 的合法 flag，**禁止**）→ 对原 compose 同样运行一次同款命令 → 两侧 `json-parse-string` 后逐键比较三个顶层 config 的 `content` 字符串，要求 `(equal orig-content rendered-content)` **全等**（字节数与换行数只作辅助日志，不作判据）
      （依赖：1.2）验收：PASS，三个键 `equal` 全等；把两次命令、flag 集与比较结果写入「## 批次记录」
- [x] 2.2 附加对照：同一生成物 `config -q` exit 0（语法合法）；并记录 `$${...}` 在 `--no-interpolate` 下原样保留（块标量不处理 `$`，部署语义与现网一致）
      （依赖：2.1）验收：PASS
- [x] 2.3 **修复 `|+` 拼接缺陷**（批次 2 暴露的相邻缺陷）：`--yaml-block-scalar` 的返回值自带 n 个尾换行（`|` 为 1、`|+` 为 n），而 `--yaml-value` 用 `mapconcat … "\n"` **无条件**补分隔符 → 块标量后还有同层键时多 1 个换行；`|+`（keep）把多出的空行计入内容（`"x\ny\n\n"` 回读成 `"x\ny\n\n\n"`），`|` / `|-` 只是「依赖 chomping 偶然无害」。**修法**：新增内部助手 `ebasecamp-compose--yaml-join`（条目前按「已累积结果是否以 `\n` 结尾」决定是否补换行），替换 `--yaml-value` 映射分支与序列分支的两处 `mapconcat`；`--yaml-block-scalar` 的返回值不动（其 n 个换行语义正确），其它 `mapconcat` 调用点（`--service-body` 等不走块标量）不动。**先红后绿**：2 项新 deftest（映射内 `|+` / 映射内 `|` 后接同层键无夹层空行）先红，实现后转绿
      （依赖：2.2）验收：`make check` **464/464、0 unexpected**、compile 零 warning；L3 重跑 `|+` 最小复现 `equal` False → **True**；`datarush-go` 三键仍全等、`config -q` exit 0

### 批次 3：文档、版本与归档

- [x] 3.1 文档：`docs/adr/0009-yaml-block-scalar.org`（新 ADR：三层策略「块标量 / 双引号转义 / 裸标量」+ chomping 判据 + 边界表 + 否决项「拒绝建模」「引入 YAML 库」）、`openspec/tech-debt.md` #33 关闭（写明 v0.5.4 已修 + L3 证据）、`CHANGELOG.md` `## [0.5.4]`、`docs/user-guide.org` 删除「建议改用 `file:` 形态」的临时处置（改为「inline 多行 `content:` 已可保真往返」）、`AGENTS.md`（基线 452 → 464、当前状态、ADR 清单加 0009）、`openspec/decisions.md` 一行、版本号 14 处（13 个 `.el` 头 + `AGENTS.md`）
      （依赖：2.3）验收：grep 命中各关键词；`make check` 仍 464/464
- [x] 3.2 归档：本计划移入 `openspec/completed/`，`## 当前状态` 写明完成与 L3 结论；`AGENTS.md` 当前状态同步（进行中计划 → 无）
      （依赖：3.1）验收：`openspec/active/` 为空 —— **PASS**（2026-10-26 实测：普通 `mv` 移入 `openspec/completed/2026-10-26-yaml-block-scalar.md`；`ls -A openspec/active/` 为 0；`make check` 仍 464/464、compile 零 warning；`AGENTS.md` 进行中计划改「无」并把 v0.5.4 追加进已归档列表）

## 文档清单

| 文档 | 更新 |
|---|---|
| `docs/adr/0009-yaml-block-scalar.org` | 新 ADR（三层渲染策略 / chomping / 边界 / 否决项），**须引用 ADR-0006 决策 3**（「第一版只保证 `file:`/`external:`/`name:` 形态」→ 本 ADR 补齐 `content:`） |
| `Readme.org` | 两处「`content:` 多行目前不可表达」（约 `:238` 与 `:498`）改为「已支持，经块标量保真往返」 |
| `docs/architecture.org` | 约 `:426`「`content:` 多行字符串不可表达」同步为已支持 |
| `docs/compose-generation.org` | 约 `:245`「`content:` 多行不可表达」改为已支持；约 `:312`「加引号时转义 `\\` 与 `\"`」补为「并转义 `\n` / `\r`；多行值走块标量」 |
| `openspec/tech-debt.md` | #33 关闭 + L3 证据 |
| `CHANGELOG.md` | `## [0.5.4]` |
| `docs/user-guide.org` | 三处同步（防漏改正文声明）：约 `:593`（正文「两条已知限制」里 `content:` 多行不可表达）、约 `:631`（限制表「只支持单值形态」）、约 `:633`（限制表「老清单需重新导入一次」注意② 里「建议改成 `=file:=` 形态」）—— 全部改为「已支持块标量保真往返」并删除 `file:` 建议 |
| `AGENTS.md` | 基线 464 / 当前状态 / ADR 清单加 0009 |
| `openspec/decisions.md` | 追加决策行 |
| `lisp/ebasecamp-compose.el` Commentary | 「转义 `\\` 与 `"`」补为「转义 `\\` / `"` / `\n` / `\r`；多行标量走块标量」 |
| 14 处 `Version:` | `0.5.3` → `0.5.4` |

## 验证标准

- **L1**：`make check-parens` + `make compile`（零 warning）
- **L2**：`make test`，基线 452 → **464**（批次 1 新增 10 项 + 批次 2.3 新增 2 项）
- **L3**：批次 2 的真实 docker 往返（两侧 `config --format json` 的 `content` 字符串 `equal` 全等）+ `config -q` exit 0
- 每批次更新「## 当前状态」

## 注意事项

- **`--escape-string` 的映射函数必须分情况**：`\n` → `"\\n"`（反斜杠 + 字母 n）、`\r` → `"\\r"`、`\` 与 `"` → `(concat "\\" match)`。对换行复用 `(concat "\\" match)` 会产出「反斜杠 + 真实换行」，YAML 仍折叠。用**一次** `replace-regexp-in-string` + `cond` 分派，避免多轮转义。
- **`--quote-required-p` 的 `\r` 判定必须与 `\n` 一并加上**：漏 `\r` 会让含 CRLF 的字符串（`--block-scalar-p` 因含 `\r` 返回 nil）落到**裸标量**，内容直接损坏。
- **先读 `ebasecamp-compose--special-characters` 常量**：确认它是否已含 `\n` / `\r`，避免 `--quote-required-p` 重复判定或漏判（若已含，仍要保证块标量分支在前）。
- **块标量头与键同行**（`content: |`），内容行缩进 = 键缩进 + 2；不要硬编码 4/6，用 `indent` 推导（含序列分支 `- |`）。
- **空行不加缩进**：加了会保留尾随空格，往返时字节数变多。
- **`|+` 的末尾换行数必须精确还原**：`(make-string n ?\n)` 放在内容行之后（内容行末尾不带换行）。
- **含 `\r` 一律走双引号**（D2 保真），不要走块标量，也不要 `\r\n` → `\n` 改写。
- **单行零变化**：任何单行字符串的渲染结果逐字节不变（用例⑤守）。
- **影响面**：块标量（A2）只覆盖走 `--yaml-value` 的位置 —— 顶层 `configs` / `secrets` 的 `content`、服务级 `environment` / `labels`；`command` 等走 `--service-body` 的字段不经 `--yaml-value`，其多行保真靠 A1 转义。**不要在 `command` 分支加块标量逻辑**。
- **`config -q` 不足以判保真**：必须用 `config --format json` 后 `equal` 比较（v0.5.2 探针 T2/T3 的教训）；且读回命令必须带 `--no-interpolate --no-env-resolution --no-path-resolution`（不变量 5）。
- **L3 的前置路径**：`/home/thomas/Workspace/Work/datarush-go/docker-compose.yaml` 在 workspace root 之外，执行前先确认存在（reviewer 已实测存在，三个顶层 config 为 inline `content: |`）。
- 同一文件多次 `edit_file` 不得并行。

## 批次记录

（执行时按批次追加：用例分摊 / 实现要点与落点行号 / 红灯证据 / 绿灯证据 / 与计划的偏差。）

### 批次 1 记录（2026-10-26）

**用例分摊（10 项，均在 `test/ebasecamp-compose-tests.el` 的 `;;; 17.` 段）**

| # | deftest | 断言要点 |
|---|---|---|
| ① | `ebasecamp-compose-test-block-scalar-pipe-keeps-single-newline` | `--yaml-value '(("content" . "a\nb\n")) 4` 精确等于 `content: |` + 两行 6 缩进内容 + 末尾 1 换行 |
| ② | `ebasecamp-compose-test-block-scalar-strip-drops-trailing-newline` | `"a\nb"` → 头 `\|-`，精确文本无末尾换行（tail=0） |
| ③ | `ebasecamp-compose-test-block-scalar-keep-preserves-trailing-newlines` | `"a\nb\n\n\n"` → 头 `\|+`，精确文本 + 尾部换行数 = 3 |
| ④ | `ebasecamp-compose-test-block-scalar-blank-line-and-leading-spaces` | `"a\n\n  b\n"` → 精确文本；空行为空串（无缩进）、`  b` 行保留原前导 2 空格（共 8 空格 + b） |
| ⑤ | `ebasecamp-compose-test-single-line-scalars-unchanged` | `plain` → `k: plain`、`has space` → 裸标量、`a: b` → `k: "a: b"`，且不含 `\|`（回归保护，天然绿） |
| ⑥ | `ebasecamp-compose-test-escape-string-escapes-newline-and-carriage-return` | `--escape-string "a\nb"` = `a\nb`（反斜线+字母 n）、`--quote-required-p` 为真；`\r` 同款两断言；转义后不残留真实换行/回车 |
| ⑦ | `ebasecamp-compose-test-flow-sequence-escapes-multiline-item` | `--yaml-flow-sequence '("a\nb")` = `["a\nb"]`，正则命中字面 `\n`、不含字面换行 |
| ⑧ | `ebasecamp-compose-test-file-declarations-indent-multiline-content` | 经 `--file-declarations-section "configs"`：`configs:` 0 / `  app_cfg:` 2 / `    content: \|` 4 / `      line1` 6 / `      line2` 6 |
| ⑨ | `ebasecamp-compose-test-block-scalar-value-is-single-newline` | `"\n"`（n=1）→ 精确 `"    content: \|\n\n"`（`content: \|` + 2 换行） |
| ⑩ | `ebasecamp-compose-test-block-scalar-value-is-blank-lines` | `"\n\n"`（n=2）→ 精确 `"    content: \|+\n\n\n"`（`content: \|+` + 3 换行） |

**实现要点与落点行号（`lisp/ebasecamp-compose.el`）**

- `--special-characters`（`:64`）内容为 `:#{}[],&*!|>'"%@\``（反引号结尾），**不含** `\n` / `\r` —— 因此 `--quote-required-p` 的新增判定不是重复，属必需（否则多行字符串在不走块标量的上下文里会落到裸标量）。
- `--quote-required-p`（`:95`）：在「前后空白」两条之后、`--has-special-character-p` 之前新增 `(string-match-p "[\n\r]" string)`（`:104`）。`\r` 与 `\n` 一并加，保证 CRLF 走双引号转义而非裸标量。
- `--escape-string`（`:110`）：正则改为 `"[\\\\\"\n\r]"`，映射函数用 `cond` 分派 —— `\n` → `"\\n"`（反斜线 + 字母 n，两字符）、`\r` → `"\\r"`、其余 → `(concat "\\" match)`；**一次** `replace-regexp-in-string`（`literal`=t，无需再转义），无二次转义。
- `--block-scalar-p`（`:173`）：`(and (stringp value) (string-match-p "\n" value) (not (string-match-p "\r" value)))`。
- `--yaml-block-scalar`（`:181`）：末尾换行数 `n` 取 `"\n+\\'"` 匹配长度；chomping 头 `0 → |-` / `1 → |` / `≥2 → |+`；内容去尾部 `n` 换行后按 `\n` 切分，非空行加 `indent` 空格、空行输出空串；尾部 `(make-string n ?\n)` 拼在内容行之后。
- `--yaml-value`（`:197`）：映射分支（`:214`）与序列分支（`:228`）各加一条 `--block-scalar-p` 分支，插在「嵌套 list」分支之后、标量分支之前；映射分支 `(concat key " " (--yaml-block-scalar nested (+ indent 2)))`、序列分支 `(concat pad "- " (--yaml-block-scalar item (+ indent 2)))`。原 `if` 改写为等价的 `cond`（单行路径逐字节不变）。
- **未改** `--service-body` 的 `command` 分支（它走 `--yaml-string` / `--yaml-flow-sequence`，保真靠 A1）——按计划要求。
- 文件头 Commentary（YAML 输出约定段）同步为「转义 `\\` / `"` / `\n` / `\r`；多行标量走块标量」。
- 缩进全部由 `indent` 推导（映射内容行 `indent + 2`、序列内容行 `indent + 2`），无硬编码 4/6。

**红灯证据（步骤 1，实现前）**

```
Ran 462 tests, 453 results as expected, 9 unexpected (2026-10-26 16:21:50+0800, 5.226047 sec)

9 unexpected results:
   FAILED  ebasecamp-compose-test-block-scalar-blank-line-and-leading-spaces
   FAILED  ebasecamp-compose-test-block-scalar-keep-preserves-trailing-newlines
   FAILED  ebasecamp-compose-test-block-scalar-pipe-keeps-single-newline
   FAILED  ebasecamp-compose-test-block-scalar-strip-drops-trailing-newline
   FAILED  ebasecamp-compose-test-block-scalar-value-is-blank-lines
   FAILED  ebasecamp-compose-test-block-scalar-value-is-single-newline
   FAILED  ebasecamp-compose-test-escape-string-escapes-newline-and-carriage-return
   FAILED  ebasecamp-compose-test-file-declarations-indent-multiline-content
   FAILED  ebasecamp-compose-test-flow-sequence-escapes-multiline-item
```

与计划预期一致：9 红为①②③④⑥⑦⑧⑨⑩，唯一绿为⑤（单行回归保护），既有 452 项零回归。

**绿灯证据（步骤 3，实现后）**

```
$ make check-parens
check-parens OK (26 files)

$ make compile
（无输出，exit 0 —— byte-compile-error-on-warn 下零 warning）

$ make clean && make test
Ran 462 tests, 462 results as expected, 0 unexpected (2026-10-26 16:22:25+0800, 4.698687 sec)
```

`make check`（三目标串联）同样 exit 0。技术债 #20 的 docker 流捕获测试本批次未抖动，无需复跑。

**附加验证（非 ERT，`emacs -Q --batch` 自查边界，不影响 10 项计数）**

- 序列分支：`(--yaml-value '("a\nb") 2)` → `  - |-\n    a\n    b`（`- |` 间一空格，内容缩进 4）。
- CRLF：`(--yaml-value '(("k" . "a\r\nb")) 0)` → `k: "a\rb\n"`（字面转义，不走块标量，保真不改写）。
- `command` 多行：`--yaml-string` → `"sh -c 'line1\nline2'"`（字面转义）。
- 空串 → `k: ""`；首行为空（`"\na\n"`）→ `|` + 空行（无缩进）+ 内容行；纯空白内容行 `"a\n  \n"` → 缩进 + 原空白（4 空格）；tab 不转义。

**与计划的偏差**

1. `--quote-required-p` 的新判定插在「前后空白」之后而非 `or` 最前（语义等价，无短路差异；已按「新增一条 `or` 分支」执行）。
2. `--yaml-value` 的两个 `if` 改写为 `cond`（三路分支可读性更好），单行路径输出逐字节不变 —— 由用例⑤与既有 452 项守。
3. 序列分支的块标量实现**无专门 ERT**（计划 10 项清单未含该用例，故不擅自新增第 11 项）；改以本记录「附加验证」的手工自查 + 既有 452 项回归覆盖，真实往返由批次 2 L3 复核。
4. 计划要求「勾选 1.1/1.2」已完成；`AGENTS.md` 按计划留批次 3，本批次未改。

### 批次 2 记录（2026-10-26）

**环境与前置**

| 项 | 值 |
|---|---|
| HEAD | `b6caef3ca0150664cd1d894c1c64c53084b4cc84`（与批次 1 后一致，本批次未提交、未新建仓库内文件） |
| `git status --short`（执行前） | `M lisp/ebasecamp-compose.el` / `M test/ebasecamp-compose-tests.el` / `?? openspec/active/` |
| docker | `docker version --format '{{.Server.Version}}'` → **29.9.2** |
| 原 compose | `/home/thomas/Workspace/Work/datarush-go/docker-compose.yaml`（10521 字节，存在） |
| elisp-dev-mcp | **未调用**（本批次无 `elisp_mcp_*`，验证全走 `emacs -Q --batch` + docker CLI） |

**隔离清单与渲染（`emacs -Q --batch`，Makefile 同款 LOAD_PATH）**

```
mkdir -p /tmp/ebc-v054/{manifest,cache,out}

$ S=$HOME/thomas-emacs/.local/straight/build-31.1
$ emacs -Q --batch -L . -L lisp -L $S/etaf -L $S/etaf-ui -L $S/ebox -L $S/ecss -l /tmp/ebc-v054/probe.el
```

`probe.el` 用 `let` 绑定 `ebasecamp-config-directory` = `/tmp/ebc-v054/manifest/`、`ebasecamp-cache-directory` = `/tmp/ebc-v054/cache/`，依次：

1. `(ebasecamp-import-apply "/home/thomas/Workspace/Work/datarush-go/docker-compose.yaml" "probe-cfg" :directory "/tmp/ebc-v054/manifest/" :force t)`
2. `(ebasecamp-config-load)` → **`:errors` 0 条**
3. `(ebasecamp-compose-render (ebasecamp-model-project 'probe-cfg))` → 写入 `/tmp/ebc-v054/out/compose.yaml`

实测输出：`imported: /tmp/ebc-v054/manifest/projects/probe-cfg.el` / `load-errors: 0` / `rendered-bytes: 9474`。

**读回命令（两侧完全相同，不变量 5 的 flag 集齐全）**

```
$ docker compose -f /home/thomas/Workspace/Work/datarush-go/docker-compose.yaml \
    config --no-interpolate --no-env-resolution --no-path-resolution --format json > /tmp/ebc-v054/orig.json      # exit 0, stderr 0 字节
$ docker compose -f /tmp/ebc-v054/out/compose.yaml \
    config --no-interpolate --no-env-resolution --no-path-resolution --format json > /tmp/ebc-v054/rendered.json  # exit 0, stderr 0 字节
```

flag 集：`--no-interpolate` `--no-env-resolution` `--no-path-resolution` `--format json`（四项齐全）；**未使用** `--environment`（非 `config` 合法 flag）。两侧 `configs` 的键集合完全一致：`grafana_clickhouse_datasource` / `grafana_prometheus_datasource` / `prometheus_config`。

**键级比较（`python3` 严格字节相等，判据是 `==` 而非长度）**

| 键 | `equal` | 原 len / 渲染 len | 原换行 / 渲染换行 |
|---|---|---|---|
| `grafana_clickhouse_datasource` | **True** | 340 / 340 | 14 / 14 |
| `grafana_prometheus_datasource` | **True** | 159 / 159 | 8 / 8 |
| `prometheus_config` | **True** | 896 / 896 | 35 / 35 |

辅助日志：两侧 `content` 尾形态均为单个换行（如 `grafana_clickhouse_datasource` 尾 `'word: $${CLICKHOUSE_PASSWORD}\n'`、`prometheus_config` 尾 `'        app: datarush_collect\n'`），与「`|` clip 保留单个末尾换行」一致。**技术债 #33 的多行丢失在真实 docker 往返回路上已消除**（v0.5.4 前该处内容会被折叠成单行）。

**附加对照：`config -q`**

```
$ docker compose -f /tmp/ebc-v054/out/compose.yaml \
    --project-directory /home/thomas/Workspace/Work/datarush-go config -q
exit=0 · stdout 0 字节 · stderr 0 字节
```

**`$${...}` 在 `--no-interpolate` 下的形态（两侧一致，原样保留）**

```
$ 原 compose / 渲染物 content 均含：
      defaultDatabase: $${CLICKHOUSE_DB}
```

（另有 `$${CLICKHOUSE_USER}` / `$${CLICKHOUSE_PASSWORD}` 同样原样保留，未被转义、未被插值——块标量不处理 `$`，部署语义与现网一致。）

**暴露的相邻缺陷（`|+` 上下文多一个尾换行）—— 本批次未改生产代码**

`datarush-go` 三个 config 均为 `|`（n=1），故本批次验收不受影响；但为确认「夹层空行」是否有害，另建最小复现（`/tmp/ebc-v054/t2/`，原 compose 含 `content: |+` 的 `x\ny\n\n` 与 `content: |` 的 `z\n`，同样导入 → 渲染 → 两侧 `config --format json`）：

```
keep2 (|+, 原文 'x\ny\n\n')   equal=False  rend='x\ny\n\n\n'   ← 多一个尾换行
plain (|,  原文 'z\n')        equal=True   rend='z\n'
```

- 成因：`--yaml-block-scalar` 已输出 `(make-string n ?\n)`，其调用点把结果拼进 `--yaml-value` 的映射/序列分支，而外层 `mapconcat … "\n"` 的分隔符又补了一个换行 → 块标量之后多出一个空行。`|`（clip）会丢掉尾部空行故无害、`|-`（n=0，自身不带换行）恰好由分隔符补行故也正确，**只有 `|+`（keep，n ≥ 2）会把多余空行计入内容**。
- 渲染文本侧的同一现象（`|` 场景）：`content: |` 内容行之后、`    name:` 之前有一行空白，属 clip 会吞掉的无害夹层空行，但视觉上多一行。
- 影响面：仅「末尾 ≥ 2 换行的多行字符串」经映射/序列上下文（顶层 `configs`/`secrets` 的 `content`、服务级 `environment`/`labels`）。批次 1 的用例③只测 `--yaml-block-scalar` 的**独立**输出（不经 mapconcat），因此 ERT 天然测不到本缺陷——与「单测隔离 + L3 真实往返」的分工有关，已在上方「当前状态」列为待裁决项。

**与计划的偏差**

1. 计划 2.1 写「用 `json-parse-string`（Elisp）或 `python3`」——本批次选 **`python3`**（`json.load` 后 `==` 比字符串，等价于 `equal`），避免 Elisp `:null-object`/`:object-type 'alist` 与 plist 结构差异带来的判读噪音。
2. 计划只要求三个键比较，本批次**额外**做了 `|+` 最小复现（1 个 compose + 1 次导入/渲染/双向读回），以判断「渲染文本的夹层空行」是否为真缺陷。结论如上，**未改生产代码**（批次 2 明令）。
3. 计划 2.2 要求「记录 `$${...}` 原样保留」——已记录，并顺带确认渲染物 `config -q` 的 stdout/stderr 均为 0 字节（计划只要求 exit 0、stderr 空，更严格）。
4. `/tmp/ebc-v054/` 与探针脚本（`probe.el` / `probe2.el`）保留在仓库外作为证据，未进版本库；`git status --short` 与执行前完全一致（无新增文件）。

#### 2.3 `|+` 拼接缺陷修复（2026-10-26，严格 TDD）

**缺陷（已在 2.1 复现，结论沿用）**：`--yaml-block-scalar` 的返回值自带 n 个尾换行（`|` 为 1、`|+` 为 n），`--yaml-value` 用 `(mapconcat … "\n")` **无条件**补分隔符 → 块标量后还有同层条目时多 1 个换行。`|+`（keep）把多出的空行计入内容（`"x\ny\n\n"` → 回读 `"x\ny\n\n\n"`）；`|`（clip）/`|-`（n=0）只是**依赖 chomping 语义偶然无害**，不是正确性。

**修法**：新增内部助手 `ebasecamp-compose--yaml-join`，按「**已累积结果**是否以 `\n` 结尾」决定是否补换行（不是只看前一项——空串项、连续块标量才自洽），替换 `--yaml-value` 映射分支与序列分支的两处 `mapconcat`。`--yaml-block-scalar` 的返回值**不动**（n 个换行语义正确）；`--service-body` 等其它 `mapconcat` 调用点**不动**（不走块标量）。

**实现落点（`lisp/ebasecamp-compose.el`）**

| 位置 | 内容 |
|---|---|
| `:197` | 新增 `ebasecamp-compose--yaml-join`（13 行） |
| `:209` | `--yaml-value`（整体下移 13 行） |
| `:216` | 映射分支改为 `(--yaml-join (mapcar (lambda (pair) …) value))` |
| `:233` | 序列分支改为 `(--yaml-join (mapcar (lambda (item) …) value))` |

`--yaml-join` 的 docstring（原文）：

```
把同层条目 ITEMS 拼成一段文本，条目之间按需补一个换行。
与前一项以换行结尾时不补 —— 块标量（`|' / `|+'）的输出自带尾换行，无条件
补分隔符会让 `|+'（keep）把多余空行计入内容（值末尾 ≥2 换行时多 1 个）。
ITEMS 为空时返回空串。
```

**新增 2 项用例（`test/ebasecamp-compose-tests.el:725` / `:734`，`;;; 17.` 段末）**

| # | deftest | 输入 | 断言（精确文本） |
|---|---|---|---|
| ⑪ | `ebasecamp-compose-test-block-scalar-keep-in-mapping-does-not-add-newline` | `'(("content" . "x\ny\n\n") ("name" . "cfg"))`，缩进 4 | `"    content: |+\n      x\n      y\n\n    name: cfg"`（`y` 后恰 2 换行：1 个结束内容行 + 1 个语义空行；`name` 紧接其后、无夹层空行） |
| ⑫ | `ebasecamp-compose-test-block-scalar-pipe-in-mapping-no-extra-blank` | `'(("content" . "x\ny\n") ("name" . "cfg"))`，缩进 4 | `"    content: |\n      x\n      y\n    name: cfg"`（`y` 后恰 1 换行，紧接 `name`；不依赖 clip 吞空行的偶然行为） |

**红灯证据（步骤 1，实现前）**

```
$ make clean && make test
Ran 464 tests, 462 results as expected, 2 unexpected (2026-10-26 16:25:51+0800, 5.239264 sec)

2 unexpected results:
   FAILED  ebasecamp-compose-test-block-scalar-keep-in-mapping-does-not-add-newline
   FAILED  ebasecamp-compose-test-block-scalar-pipe-in-mapping-no-extra-blank
```

既有 462 项零回归，红项与预期（⑪⑫）完全一致。

**绿灯证据（步骤 3，实现后）**

```
$ make check-parens
check-parens OK (26 files)

$ make compile
（无输出 —— byte-compile-error-on-warn 下零 warning）

$ make check            # 三目标串联
exit=0
Ran 464 tests, 464 results as expected, 0 unexpected (2026-10-26 16:26:22+0800, 5.595017 sec)
```

**L3 重跑 1：`|+` 最小复现（`/tmp/ebc-v054/t2/`，同一命令与 flag 集）**

```
$ docker compose -f src.yaml config --no-interpolate --no-env-resolution --no-path-resolution --format json
$ docker compose -f out/compose.yaml config --no-interpolate --no-env-resolution --no-path-resolution --format json

keep2 (|+, 原文 'x\ny\n\n')   equal=True   rend='x\ny\n\n'    ← 修复前 False（'x\ny\n\n\n'）
plain (|,  原文 'z\n')        equal=True   rend='z\n'
config -q → exit=0, stdout 0 字节, stderr 0 字节
```

渲染文本同步变化：`|+` 块标量后由 2 行空白降为 1 行（语义空行），`|` 后不再有空行。

**L3 重跑 2：`datarush-go` 三键（同一命令、同一 flag 集）**

| 键 | `equal` | len 原/渲染 | 换行 原/渲染 |
|---|---|---|---|
| `grafana_clickhouse_datasource` | **True** | 340 / 340 | 14 / 14 |
| `grafana_prometheus_datasource` | **True** | 159 / 159 | 8 / 8 |
| `prometheus_config` | **True** | 896 / 896 | 35 / 35 |

```
$ docker compose -f /tmp/ebc-v054/out/compose.yaml \
    --project-directory /home/thomas/Workspace/Work/datarush-go config -q
exit=0 · stdout 0 字节 · stderr 0 字节
```

渲染字节数 9474 → 9471（3 个 `|` 块标量各去掉 1 个夹层空行），`content` 回读不变。

**与计划的偏差**

1. 任务显式要求「不 git 操作」，故**未创建 git 安全点**（默认门禁的安全点由 `git stash create` 产生，与「不 git 操作」冲突时以任务显式指令为准）。改动范围限 `lisp/` 1 个函数 + 2 处调用点 + 2 项测试，L1/L2/L3 全绿、无回滚需求。
2. 任务给出的 `--yaml-join` 实现原样采用（含 `dolist` + `string-suffix-p`），未做额外优化；`--yaml-value` 的两个分支由 `mapconcat` 改为 `(mapcar …)` + `--yaml-join`，函数体其余部分逐字节保持。
3. 计划文件同步改动的范围严格限定为任务列出的四项（任务 2.3 条目、当前状态、批次 2 记录、L2 基线 + 文档清单 AGENTS.md 行），未触及其它章节（批次 1 记录中的 462/452 等历史数字保留为当时证据）。


### 批次 3 记录（2026-10-26）

**安全点**

- `git rev-parse HEAD` → `b6caef3ca0150664cd1d894c1c64c53084b4cc84`（与批次 2 一致）
- `git stash create` → `beda216af37721a97ab9baf7558a657cec445a06`；未执行 `git add` / `commit` / `push`
- 本批次只动文档 + 版本号，**未触** `lisp/` 与 `test/`（`lisp/ebasecamp-compose.el` / `test/ebasecamp-compose-tests.el` 的两处 M 是批次 1 / 2.3 的既有改动，本批次零新增改动）

**逐文档改动摘要**

| 文档 | 位置 | 改动 |
|---|---|---|
| `docs/adr/0009-yaml-block-scalar.org` | 新建（115 行） | 背景（静默改内容 + `config -q` 不校验内容）+ 决策 1（保真层：四类转义 / 字面两字符 / 一次 replace）+ 决策 2（可读层：块标量判据 / chomping / 缩进 / 空行）+ 决策 3（`--yaml-join` 拼接触点）+ 影响面表 + 边界表 + 否决项 ① 拒绝建模 ② 引入 YAML 库 ③ CRLF 改写为 LF + 与 ADR-0006 的关系 + 验证证据 + 不变量（明确无新增）+ 状态 |
| `Readme.org` | `:238` | 「只支持 `file:` / `external` / `name` 形态…`content:` 多行目前不可表达」→「支持 inline `content:`（含多行），块标量保真往返；`config -q` 只校验语法，判据用 `--format json`」 |
| `Readme.org` | `:498` | 同上口径（已知限制节） |
| `docs/architecture.org` | `:426` | 「两条已知边界」→「已知边界」：`content:` 多行已支持 + 判据用 `--format json`；shared 生成物不含顶层段那条真边界保留 |
| `docs/compose-generation.org` | `:245` | `content:` 多行不可表达 → 已支持（块标量 + chomping 按末尾换行数） |
| `docs/compose-generation.org` | `:312` | 「加引号时转义 `\\` 与 `\"`」→ 补「并转义 `\n` / `\r`（字面两字符，不留真实换行）；block 上下文多行标量走块标量，不走双引号」 |
| `docs/user-guide.org` | `:593` | 「两条已知限制」→「已知限制」：`content:` 多行已支持，仅保留 shared 生成物一条 |
| `docs/user-guide.org` | `:631` | 限制表「只支持单值形态」→「`content` 多值 / 多行已支持」+ 判据 |
| `docs/user-guide.org` | `:633` | 注意②「建议改成 `file:` 形态」删除 →「inline 多行 `content:` 已可保真往返，无需改 `file:`；但 v0.5.1 之前导入的清单仍需重导入一次才能补齐 `:file-configs`」 |
| `openspec/tech-debt.md` | `#33` | 状态列 `待处理（已实际触发，2026-10-26）` → `已关闭（v0.5.4）`；条目末尾追加 v0.5.4 修复说明 + L3 证据 + 「`config -q` 不作判据」+ ADR-0009 |
| `CHANGELOG.md` | 顶部（`:5`） | 插入 `## [0.5.4] - 2026-10-26`：总述 + 修复 2 条（折叠 / keep 模式多算空行）+ 变更 3 条（块标量覆盖范围与 CRLF 保真 / 判据纪律 / 基线 452 → 464） |
| `AGENTS.md` | `:19` | `Version: 0.5.3` → `0.5.4` |
| `AGENTS.md` | `:23` / `:89` | 架构决策清单追加 ADR-0009（目录表与当前状态列表两处，各一句话说明三层策略与 chomping 判据） |
| `AGENTS.md` | `:84`–`:87` | 进行中计划 → v0.5.4（批次 1 / 2 / 2.3 / 3.1 完成，待归档 3.2）；基线 452 → **464**（452→462 批次 1 +10、462→464 批次 2.3 +2）；下一步去掉已关闭的 #33，改列 #20 / #41 / #42 |
| `openspec/decisions.md` | 末尾 | 追加 2026-10-26 一行（多行字符串标量走 YAML 块标量 + 换行转义，关联 ADR-0009） |
| 13 个 `.el` 文件头 | `:4` | `;; Version: 0.5.3` → `;; Version: 0.5.4` |

**版本号检查（14 处）**

```
$ grep -rl "^;; Version: 0\.5\.3$" --include="*.el" . | wc -l
13
$ grep -rn "Version: 0.5.3" . | grep -v openspec/completed | wc -l
0
$ grep -rn "Version: 0.5.4" . --include="*.el" --include="*.md" | grep -v openspec/completed | wc -l
14        # 13 个 .el + AGENTS.md:19
```

**grep 校验**

```
$ grep -rn "content:= 多行字符串不可表达|=content:= 多行不可表达" Readme.org docs/*.org | wc -l
0
$ grep -rln "块标量" Readme.org docs/architecture.org docs/compose-generation.org docs/user-guide.org docs/adr/0009-yaml-block-scalar.org
（5 个文件全部命中）
$ grep -o "已关闭（v0.5.4）" openspec/tech-debt.md | head -1
已关闭（v0.5.4）
$ grep -c "0009-yaml-block-scalar" AGENTS.md
2
$ grep -c "ADR-0009" openspec/decisions.md
1
$ grep -c "建议改成 =file:= 形态" docs/user-guide.org
0
```

**验证（L1 / L2）**

```
$ make check-parens
check-parens OK (26 files)

$ make compile
（无输出，exit 0 —— byte-compile-error-on-warn 下零 warning）

$ make check            # 三目标串联，exit 0
Ran 464 tests, 464 results as expected, 0 unexpected (2026-10-26 16:30:54+0800, 5.104667 sec)
```

技术债 #20 的 docker 流捕获测试本批次未抖动，无需复跑。本批次无代码改动，L3 沿用批次 2.1 / 2.3 的往返结论（`datarush-go` 三键全等 + `|+` 最小复现 True）。

**与计划的偏差**

1. `openspec/tech-debt.md` #33 追加说明里把块标量的三种 chomping 写法改写为 strip / clip / keep：markdown 表格以竖线分列，块标量写法会破坏列结构。语义与原文等价，完整写法保留在 ADR-0009 与 CHANGELOG。
2. `docs/user-guide.org:631` 的 org 表格单元格同理避开竖线（用 strip / clip / keep 表述）。
3. 计划文档清单里「`lisp/ebasecamp-compose.el` Commentary 补为…」一条已在批次 1 落地（`:40`–`:41` 现为「转义 `\\` / `"` / `\n` / `\r`；多行标量走块标量」），本批次核对确认无需再改。
4. 试跑 `org-mode-write-format` 脚本批量校准行内标记时，发现它会重排既有正文（Readme 438 行、architecture 532 行、compose-generation 220 行、user-guide 402 行差异），超出「只改清单所列位置」的范围，已回滚脚本改动；改为对自己写的行手工校准（`（=code=` → `（ =code=` 共 7 处、markdown 式 `**粗体**` → org `*粗体*` 1 处、表格内 `=n = 1=` 改为文字表述 1 处）。
5. `AGENTS.md` 下一步列表按任务要求删掉已关闭的 #33，改列 #20 / #41 / #42；「已归档」列表按任务要求**未**加入 v0.5.4（归档留到 3.2）。

**3.2 归档动作（2026-10-26）**

- 安全点：HEAD `b6caef3`（本轮改动未提交）；`git stash create` → `a8b7ea44f6b5c21ab662974c538445fa349afe11`
- 用 *普通 `mv`*（非 `git mv`）把 `openspec/active/` 下的同名文件移到 `openspec/completed/2026-10-26-yaml-block-scalar.md`（文件名不变，故不移目录看不出差别）
- 「## 当前状态」改写为归档态：阶段 / 已确认（方案 A + D2 保真、计划确认、两轮独立审查）/ 结果（批次 1 / 2 / 2.3 / 3.1 / 3.2）/ 基线 452 → 464 / L3 结论 / 关键教训（`config -q` 不校验内容）/ 回滚点 / 后续
- 勾选任务 3.2，并在验收后补 PASS 记录
- *产物引用同步*：`docs/adr/0009-yaml-block-scalar.org` 末尾「见 `openspec/…yaml-block-scalar.md` 的批次记录」由 `active/` 改为 `completed/`（读者须能打开该文件，属产物引用而非历史引文；与 ADR-0008 的写法一致）
- `AGENTS.md`：进行中计划 → **无**；已归档列表追加 v0.5.4；「v0.5.4 遗留：无」→「v0.5.4 已归档（2026-10-26），无遗留」；基线与下一步核对一致（464 / v0.6 或 #20·#41·#42）
- *历史引文保留未改*：本文件批次 2 记录里的 `?? openspec/active/` 是当时 `git status` 的原文；3.1 / 3.2 验收标准里的 `openspec/active/` 指 *目录*，属事实陈述
- 验证：`ls -A openspec/active/` = 0 项；`grep -rn "openspec/active/<本文件名>" --include=*.md --include=*.org .` = 0 命中（占位符写法：把路径字面写全会让本行命中自身）；`make check` 464/464

### 3.3 代码审查后的补测（2026-10-26）

**审查结论**：code-reviewer 审查**通过**，提 5 条建议（无阻断项）。

**采纳情况**

| 建议 | 内容 | 处置 |
|---|---|---|
| 1 | 缺「字面反斜线只转义一次」用例 —— ADR-0009 把「多轮转义」列为最易错点 | 采纳：新增用例 ⑬ |
| 2 | 序列分支块标量仅批次 1 的手工自查，无 ERT | 采纳：新增用例 ⑭ |
| 3 | 缺「首行为空」与「CRLF 走引号路径」两项边界 | 采纳：新增用例 ⑮ ⑯ |
| 4 | 建议删除部分冗余断言 | **不采纳**：保留冗余断言（双重保险，且是既有文件的表达风格） |
| 5 | `--yaml-block-scalar` 的 docstring 未说明「调用方须先排除含回车的字符串」 | 采纳：docstring 末尾补该说明 |

**4 项用例（全部天然绿，属补测而非红绿循环）**

| # | deftest | 断言要点 |
|---|---|---|
| ⑬ | `ebasecamp-compose-test-escape-string-escapes-literal-backslash` | `(--escape-string "a\\nb")` 的入参是 4 字符（a、反斜线、n、b，**不是**换行）；输出精确等于 5 字符 `a` + 两个反斜线 + `n` + `b`，且不含真实换行（守住「只转义一次」） |
| ⑭ | `ebasecamp-compose-test-sequence-block-scalar` | `(--yaml-sequence '("a\nb\n") 2)` 精确等于「2 空格 + `- ` + clip 块标量头」后接两行 4 缩进内容、末尾 1 换行 |
| ⑮ | `ebasecamp-compose-test-block-scalar-leading-blank-line` | `(--yaml-value '(("content" . "\na\n")) 4)` 精确等于 4 缩进键行 + clip 块标量头，随后一个**空行（无缩进）**、再一行 6 缩进的 `a`，末尾 1 换行 |
| ⑯ | `ebasecamp-compose-test-multiline-crlf-uses-quoted-scalar` | `(--yaml-value '(("content" . "a\r\nb")) 4)` 精确等于双引号标量（`\r` / `\n` 均为字面两字符）；且输出不含块标量头、不含真实回车与换行（D2：不走块标量、不改写为 LF） |

**验证（2026-10-26 实测）**

```
$ make clean && make test
Ran 468 tests, 468 results as expected, 0 unexpected (2026-10-26 16:42:33+0800, 5.388829 sec)

$ 4 项补测单跑（ert-run-tests-batch-and-exit 正则限定）
Ran 4 tests, 4 results as expected, 0 unexpected
  passed  1/4  ebasecamp-compose-test-block-scalar-leading-blank-line
  passed  2/4  ebasecamp-compose-test-escape-string-escapes-literal-backslash
  passed  3/4  ebasecamp-compose-test-multiline-crlf-uses-quoted-scalar
  passed  4/4  ebasecamp-compose-test-sequence-block-scalar
```

**实现改动**：仅 `ebasecamp-compose--yaml-block-scalar` 的 docstring 补一句（调用方须先用 `--block-scalar-p` 排除含回车字符串 —— 本函数不做该判定），**行为零变化**。

**文档同步**：`AGENTS.md`（基线与演进）/ `CHANGELOG.md`（`## [0.5.4]` 基线行）/ 本文件「## 当前状态」基线行均 464 → 468；`Readme.org` 的 `openspec/active/` 过时描述改为通用口径（顺带把 ADR 范围 `0001 ~ 0007` 补到 `0009`）。

**历史记录未改写**：批次 1 / 2.3 记录里的 462 / 464 数字保留为当时证据。
