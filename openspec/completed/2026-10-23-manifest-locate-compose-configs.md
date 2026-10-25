# ebasecamp v0.5.1 — 写盘定位修复与 compose 顶层 configs/secrets

## 当前状态

- 阶段：**已归档**（2026-10-24 移入 completed/）
- 已确认：方案 ✅ + 计划 ✅（用户 2026-10-23）
- 结果：X0–X4.5 全部完成；**X4.6 用户目检未能按原计划执行**——现网清单实为 create-sample-config 示例清单，无 datarush-go 项目，诊断副本 `/tmp/ebc-diag` 已不存在；改以等价链路验证替代（写盘跨文件定位 / 预校验拒绝不合法生成物 / 重新导入修复往返 三链路在 `/tmp` 副本 + 真实 docker CLI 上 PASS，证据见 v0.5.2 计划的「探针记录」与「批次 5 记录」）
- 视觉目检项：已并入 v0.5.2 批次 5.4 目检清单
- 后续：v0.5.2 承接了本计划暴露的两个新阻断缺陷（旧 `:groups` 与组侧配置共存必失败、顶层 `configs`/`secrets` 相对路径在生成物中失效），见 `openspec/active/2026-10-24-legacy-groups-and-project-directory.md`

## 目标

1. **写盘按组名跨文件定位**：组定义在 `groups.el` 或 `projects/*.el` 都能被写操作定位；`groups.el` 不存在不再是硬失败。
2. **compose 顶层 `configs:` / `secrets:` 支持**：模型可存、导入保留、渲染输出，`config -q` 通过。
3. **`s` 前 compose 预校验**：把 `invalid compose project` 变成可读错误，且不执行 `up`。

## 非目标

- project `:root` 可选（v0.5.2）
- 按钮旁显示键 / `hjkl` / avy（v0.6）
- 界面编辑顶层 `configs` / `secrets`（第一版只保证导入 → 渲染往返不丢）
- 顶层其它未知键的完整建模（只做「不静默丢弃」的警告）
- 修改已有清单（迁移由用户重新导入完成）

## 诊断结论

| 问题 | 根因 | 证据 |
|---|---|---|
| 「新建配置」报 `清单文件 …/groups.el 不存在` | 写盘层把「组定义只能在 `groups.el`」写死（`ebasecamp-config-write--groups-file`，`config-write.el:326`）；导入层把组 + 项目写进 `projects/<name>.el`（`import.el:605-624`）；加载层两者都读 | 副本上复现：`add-config` / `update-service-fields` / `update-config-project` / `remove-config` / `move-config` / `update-group` / `remove-group` 全部报该错；项目 CRUD 不受影响 |
| 按 `s` 报 `service "grafana" refers to undefined config …` | 渲染层只输出 `name`/`services`/`networks`/`volumes`，**无顶层 `configs:`/`secrets:`**；服务级 `configs` 经 `:extra` 透传；导入时顶层段被**静默丢弃** | 删掉两个服务的 `configs:` 块后 `config -q` exit 0；最小合法 compose 也 exit 0，排除环境问题 |

另两条实测事实：
- 用户清单的 `projects/datarush-go.el` 里，`configs` 顶层段已丢失，但服务级 `configs:` 引用仍在 `:extra`（字符串键 `"configs"`）。
- 同名组可能出现在多个文件（`add-group` 新建 `groups.el` 后旧组仍在 `projects/*.el`）。**加载层行为待实测确认**：`--register-group` 对已存在组名会 signal「组 X 已定义」，但诊断报告称未观察到错误——X0.1 必须实测「groups.el 与 projects/x.el 各定义一个同名组」时的 `ebasecamp-config-load` 结果，并按实测结论决定是否需要在加载期改进错误消息。

## X0 实测记录（探针结论，X1 实现必须遵守）

- **P1 同名组的加载层行为（已实测，结论确定）**：`groups.el` 与 `projects/x.el` 各定义同名组时，`ebasecamp-config-load` **返回错误**（消息含「组 X 已定义」，由 `--register-group` signal），且**后加载文件整体回滚**——同文件里的项目定义一起消失（`--reload` 重放已成功文件，不回补）。推论：定位函数对 >1 命中必须 `user-error` 拒绝写盘，**不能**沿用 `ebasecamp-manifest--locate-form` 的「返回第一个」语义；错误消息必须说明「否则该项目不会出现在界面中」，否则用户无法理解为什么「改完没效果」。
- **P2 清单文件枚举顺序（已实测）**：`ebasecamp-config--files` 的顺序恒为 `groups.el`（存在时）→ `projects/*.el` 字典序（`--project-files` 用 `string<` 排序）。定位函数按该顺序收集命中文件，报错时按同一顺序列出。
- **P3 写盘内核的接口形态（已实测）**：`ebasecamp-manifest--scan-forms` 返回 `(:start :end :kind :name)`（位置 1-based，切片须 `(1- pos)`）；`--write-transaction` **写盘成功即删除备份**，因此跨文件移动要用备份做补偿，必须先给事务加 `:keep-backup`（成功也保留备份并交回备份路径）。另：`--render-group` 返回的是**组片段**而不是整份全文（W3.2 曾因此丢兄弟组），任何写回都必须经 `--replace-form` / `--replace-forms` 包住。
- **P4 顶层 `configs:` 的 `--yaml-map` 表达力（X0.2 结论）**：`--yaml-map` 只认**字符串键**的 alist（`--mapping-p` 判据），嵌套 `{source: {file: …}}` 可用两层字符串键 alist 表达；符号键会被当序列渲染成错误 YAML → 模型层必须校验「键为字符串」。多行字符串值（`content:` 多行）**不能用现有字面量写法表达**（记录为限制，X2 不处理）。

## 设计决策

- **X1 组定位**：新增 `ebasecamp-config-write--manifest-file-for-group (group-name)`——按 `ebasecamp-config--files` 顺序（`groups.el` 优先，其次 `projects/*.el` 字典序）扫描含该组 form 的文件；0 个 → `user-error`「清单里没有组 X」；>1 个 → `user-error`「组 X 在多个文件中定义（列出文件），请先清理重复定义」。
- **X2 `--edit-manifest` 改造**：接受目标 FILE（由 X1 决定），不再固定 `groups.el`；`-add-group` 保持「`groups.el` 不存在则新建」，但**写前检查全仓同名组**。
- **X3 写操作入口对齐**：`-update-service-fields` / `-add-config` / `-update-config-project` / `-remove-config` / `-move-config`（源组 + 目标组各自定位；**同文件时一次事务，跨文件时两次事务、第二段失败需回滚第一段**）/ `-update-group` / `-remove-group` 全部改用 X1；`--config-references`（删项目前的引用扫描）改为**遍历所有含 group form 的清单文件**（不得只扫 `groups.el`）；`--legacy-group-references`（删组前）继续遍历 `projects/*.el`（它扫的是 project form 的旧 `:groups`）；`ebasecamp-ui-edit-manifest`（`e`）也改为定位真实文件，**定位失败时降级为打开文件头 + `message`（不阻断）**，保持现有语义。
- **X3b `link-configs` 错误归属**：`ebasecamp-config` 物化期错误原先固定把 `:file` 指向 `groups.el`，改为指向**组定义实际所在文件**（复用 X1 的定位函数）。
- **X4 模型**：`ebasecamp-project` 新增 `file-configs` / `file-secrets` 槽（alist，**键必须是字符串**、值为 plist/alist，原样保留）；`--project-from-spec` 白名单加入 `:file-configs` / `:file-secrets`（值必须为「键为字符串的 alist」或 nil，否则 `ebasecamp-model--fail`——因为 `--yaml-map` 的 `--mapping-p` 只认字符串键，符号键会被当序列渲染成错误 YAML）。
- **X4b project 落盘键同步**：`ebasecamp-config-write--project-output-keys` 加入 `:file-configs` / `:file-secrets`，保证 `-update-project` 重渲染时不丢这两个槽；`ebasecamp-import--project-form`（→ `ebasecamp-manifest-project-form`）也输出这两个键（仅非空时，值用 `--literal` 原样 `prin1`）。
- **X5 导入**：`ebasecamp-import-parse` / `-parse-json` 读取顶层 `configs` / `secrets` → 存入项目结构；**warnings 经动态变量承载**（`ebasecamp-import--last-warnings`，每次导入重置），**不改变 `parse` / `parse-json` 的返回值**（保持 project 对象，避免破坏 `ebasecamp-import-service-plists` 等调用点）；新增访问器 `ebasecamp-import-warnings` 读最近一次；UI / `ebasecamp-import-file` 用 `message` 提示未知顶层键，不静默丢；导入落盘的 project form 输出 `:file-configs` / `:file-secrets`（仅非空时；见 X4b）。
- **X6 渲染**：`ebasecamp-compose-render` 在**per-project** 生成物输出顶层 `configs:` / `secrets:`（来自项目 `:file-configs` / `:file-secrets`，用 `--yaml-map` 渲染）；shared 生成物（`ebc-shared`）不输出（记录为限制：shared 服务引用 config 需自行处理）。
- **X7 预校验放 command 层**（覆盖所有入口，避免 UI 层重复渲染）：`ebasecamp-command-run` 在 `ebasecamp-compose-write` 之后、启动 docker 之前，对**本次要启动的每个生成物**（shared 与 per-project 都算）调用 `ebasecamp-docker-check-compose`；失败 → 中止并返回带 stderr 首行的失败结果（UI 现有 `--report-result` 会展示为 error notice）。不再在 `--section-action` 里重复渲染；shared 生成物因引用 config 失败时同样给出可读错误。
- **X8 迁移**：不改用户清单；修好后用户重新导入一次原 compose 即可补齐顶层段（文档给步骤）；另提供 `ebasecamp-config-write-update-project-file-configs`（写项目 `:file-configs` / `:file-secrets`，供后续界面或脚本用，第一版不接 UI）。

## 任务

### 批次 X0：探针（失败即停）

- [x] X0.1 探针：在 `/tmp` 造「只有 `projects/x.el`（含组+项目）、无 `groups.el`」的清单，验证 `--manifest-file-for-group` 思路可行（扫 `ebasecamp-config--files`、定位 form、返回文件路径）；**并实测「groups.el 与 projects/x.el 各定义一个同名组」时 `ebasecamp-config-load` 是否报错**（代码上 `--register-group` 会 signal「组 X 已定义」，诊断报告称未观察到——以实测为准，据此决定加载期是否需要改进错误消息）；同时验证「同名组在两文件」时能检测到
      （依赖：无）验收：PASS + 实测输出 + 加载层行为结论 → **实测：报「组 X 已定义」且后加载文件整体回滚（同文件项目一起消失）**，结论见「X0 实测记录」P1
- [x] X0.2 探针：造一份含顶层 `configs:` 的 compose（参考用户那份的结构，脱敏），验证「导入 → 项目结构带顶层段 → 渲染输出 `configs:` → `docker compose config -q` exit 0」链路可行；记录 `--yaml-map` 对该结构的渲染结果
      （依赖：无）验收：PASS；若 `--yaml-map` 不能表达顶层 configs 结构，记录并给替代写法 → **实测：两层字符串键 alist 可表达；符号键与多行 `content:` 不可表达**，结论见「X0 实测记录」P4

### 批次 X1：写盘跨文件定位

- [x] X1.1 红：`--manifest-file-for-group`（单文件命中 / 无组 / 双文件同名）、`-add-config` 在「无 groups.el、组在 projects/x.el」时成功且写进该文件、`groups.el` 不被创建、`-update-service-fields` / `-update-config-project` / `-remove-config` / `-update-group` / `-remove-group` 同场景成功、`-move-config` **跨文件**（源组在 projects/a.el、目标组在 projects/b.el）两段都生效且第二段失败时回滚第一段、`--config-references` 在组位于 projects/x.el 时能扫到 `:project` 引用、`e` 定位落到 projects/x.el
      （依赖：X0.1）验收：**FAILED → 8 项红（400 tests / 392 expected / 8 unexpected）**；`e` 的用例放在 `test/ebasecamp-ui-tests.el`（U5 段，复用 etaf 会话脚手架，避免在写盘测试里引入 UI 依赖），其余 7 项在 `test/ebasecamp-config-write-tests.el`
- [x] X1.2 实现 X1/X2/X3 的文件定位改造（只改 `lisp/ebasecamp-config-write.el`、`lisp/ebasecamp-manifest.el`、`lisp/ebasecamp-ui.el` 的 `e` 定位）
      （依赖：X1.1）验收：**转绿 + `make check` 全绿（400/400，392 无回归）**；语义与用法见「X1 实现记录」

## X1 实现记录（语义与用法，供 X2/X3 复用）

- **定位函数语义**（`ebasecamp-config-write--manifest-file-for-group`）：
  - 收集层 `--group-manifest-files`：遍历 `ebasecamp-config--files`（`groups.el` → `projects/*.el` 字典序），只保留**含组 form** 的文件（不含组 form 的文件不可能定义组，跳过不改变结果）；`--group-files` 在同一批文件里收集定义该组的全部文件，**不做唯一性裁决**（供 `-add-group` 查重与引用扫描复用）。
  - 裁决层：0 命中 → `user-error`「清单里没有组 X（已扫描 N 个文件）」；>1 命中 → `user-error`「组 X 在多个文件中定义（<文件列表>）；请先清理重复定义——同名组会让后加载的文件整体回滚，其中项目不会出现在界面中」；1 命中 → 返回绝对路径。**不复用** `ebasecamp-manifest--locate-form`（它按设计「返回第一个」）。
  - 全部 8 个写入口（`-update-service-fields` / `-add-config` / `-update-config-project` / `-remove-config` / `-move-config` 的两个组各自定位 / `-update-group` / `-remove-group`）都先定位再开事务；`--edit-manifest` 改为 `(file editor)`，不再内部取 `groups.el`。`-add-group` 仍固定写 `groups.el`（新组不往项目文件塞），但写前用 `--group-files` 扫**全清单**查重。
- **`--config-references`**：改为遍历所有含组 form 的文件（**故意允许多命中**，引用扫描只需全覆盖）；`--legacy-group-references` 保持只遍历 `projects/*.el`（它扫的是项目 form 的旧 `:groups`），已确认未改动。
- **`:keep-backup` 用法**（`ebasecamp-manifest--write-transaction`，签名 `(file write-fn &rest keys)`）：
  - 传 `:keep-backup t` 时成功也保留备份，返回值变为 `(:result LOAD-RESULT :backup BACKUP-PATH)`；未写盘（新全文等于原文）时 `:backup` 为 nil；不传该键时返回值仍是加载结果（既有调用点零改动）。
  - 备份收尾统一放在 `unwind-protect` 里：只有「调用方要保留」或「回滚失败需人工恢复」才留备份，成功 / 回滚成功 / 中途异常（含写盘失败）一律删除——否则写盘失败会泄漏 `.ebasecamp-backup-*`（探针 C 实测到的现象，已修）。
- **跨文件 move 回滚实现**（`-move-config` → `--move-config-within-file` / `--move-config-across-files`）：
  1. 同文件：沿用一次事务 + `--replace-forms`（两处区段降序替换），无中间态；
  2. 跨文件：先对两份原文做**统一前置校验**（`--check-move` 返回要搬走的 `(CONFIG :project P [:services …])`，拒绝条件全部在任何写盘之前抛出）→ ① 源文件事务移除配置（`:keep-backup t`）→ ② 目标文件事务追加配置 → ② 失败则 `--restore-backup` 用 ① 的备份**恢复源文件原文**再 `signal` 原错误；两段都成功才删两个备份。
  3. 语义记录：跨文件移动 = **两次事务 + 显式备份补偿，非单事务原子**（对 ADR-0005 决策 2 的部分退化，ADR-0006 必记）。
- **`e` 的降级路径**（`ebasecamp-ui-edit-manifest`）：定位成功 → 打开组定义所在文件并定位到 `(ebasecamp-define-group X'`；`user-error`（没有该组 / 同名组重复）→ 先 `message` 原因、再退到 `groups.el`（不存在则第一个项目文件），打开后仍搜不到就 `goto-char point-min` + `message`，**不 signal**；连可编辑清单文件都没有 → `user-error`（保留目录路径 + `ebasecamp-create-sample-config` 提示，兼容 U5 原用例）。

## X2 实现记录（语义与用法，供 X3/X4 复用）

- **模型校验（`ebasecamp-model--check-file-mapping` + `--check-file-mapping-nested`）**：`ebasecamp-project` 新增 `file-configs` / `file-secrets` 两个槽（放在 `export-file` 之后，保持既有槽位顺序不变），`ebasecamp-model--project-keywords` 加入 `:file-configs` / `:file-secrets`。校验分**入口**与**递归**两层：入口只接受 nil 或「元素全为 `("字符串键" . 值)` 的 proper list」，递归层接受标量并继续下钻——判别规则与渲染层 `ebasecamp-compose--mapping-p` **完全一致**（「列表首元素是 cons」即当映射层，此时该层所有键都必须是字符串）。这样「模型放行」与「渲染正确」是同一判据，不会出现「加载通过但渲染成垃圾 YAML」。计划里写的 `--check-file-段` 是笔误/占位，实现取名 `--check-file-mapping`。
- **导入 warnings 接口**：新增 `ebasecamp-import--last-warnings`（动态变量，`parse-json` 开头重置）+ 访问器 `ebasecamp-import-warnings`（返回副本）+ 写入口 `ebasecamp-import--warn`；`parse-json` 遍历顶层键，凡不在 `ebasecamp-import--top-level-keys`（`name` / `services` / `networks` / `volumes` / `configs` / `secrets` / `version` / `include`）的一条一条记 `"顶层键 X 暂不支持，已忽略"`。**`parse` / `parse-json` 返回值不变**（仍是 project 对象），`ebasecamp-import-service-plists` 等既有调用点零改动；`ebasecamp-import-file` 有 warnings 时先 `message` 汇总条数，再报导入路径。
- **落盘输出**：`ebasecamp-manifest-project-form (NAME ROOT &optional FILE-CONFIGS FILE-SECRETS)` 只在非空时追加 `:file-configs` / `:file-secrets`（值经 `--literal` 原样 `prin1`，`${VAR}` 与相对路径不插值）；无顶层段时输出与历史实现**逐字节一致**（闭合括号仍在 `:root` 行尾）。`ebasecamp-config-write--project-output-keys` 加入两个键并改为「非空才写」，因此 `-update-project` 改 title/root 时两个槽保值。
- **渲染位置**：`ebasecamp-compose--file-declarations-section` 用 `--yaml-map` 渲染（键名一层缩进 2、嵌套层 4），段顺序为 `name` → `services` → `networks` → `volumes` → `configs` → `secrets`（与 docker 惯例一致）。是否输出由 `(ebasecamp-compose--all-shared-p refs)` 决定：**refs 全为 shared 时省略**（`_shared` 生成物），其余情况输出——因此 `ebasecamp-export--deployment-project` 的副本（只留 per-project refs）自然带上顶层段，`ebasecamp-export-project` 无需额外改动。
- **实现期自查修掉的隐患**：`ebasecamp-import--last-warnings` 的 `defvar` 一开始写在 `parse-json` **之后**——`make compile`（全量一次编译）因前面的文件已 `require` 过 import.el 而侥幸无警告，但**单文件编译**会 `Error: assignment to free variable`（已实测）。现将 defconst / defvar / 访问器整体上移到「项目名推断」之前（首个使用点之前），单文件与全量编译均零警告。
- **`content:` 仍不支持**（不变）：顶层 config 的 `content:` 多行字符串超出 `--yaml-map` 表达力（双引号标量折行会静默改内容且 `config -q` 仍 exit 0），第一版只保证 `file:` / `external` / `name` 形态往返；记入 tech-debt。
- **计划与实现的偏差（测试示例笔误）**：计划 X2.1 把 `(("web_cfg" . ((file . "./web.conf"))))` 写成「合法」，同一句又要求「嵌套符号键报错」——两者互斥。按「必读 1」（`--yaml-map` 只认字符串键、模型层必须递归校验）判定后者为准，合法用例统一用字符串键 `("file" . "./web.conf")`，符号键（顶层与嵌套）一律 `ebasecamp-model-error`。
- **docker 闭环实测（X2.3）**：
  - 输入 `/tmp/ebc-x2/compose/web.yaml`（服务级 `configs: [{source: web_cfg, target: …}]` + 顶层 `configs: {web_cfg: {file: ./web.conf}}`）→ `ebasecamp-import-apply` → `/tmp/ebc-x2/config/projects/probe-web.el`，`ebasecamp-config-load` 错误 nil，清单带 `:file-configs (("web_cfg" ("file" . "./web.conf") ("name" . "compose_web_cfg")))`。
  - `ebasecamp-export-project` → `/tmp/ebc-x2/compose/docker-compose.ebasecamp.yaml`（服务级 `configs:` 从 `:extra` 透传、顶层 `configs:` 由项目槽渲染）→ `docker compose -f <导出> config -q` **exit=0 / stderr=""**；`config` 解析出的 `configs:` 段为 `web_cfg: {name: compose_web_cfg, file: /tmp/ebc-x2/compose/web.conf}`。
  - 同一导出物删掉顶层 `configs:` 段后 `config -q` **exit=1**、stderr `service "api" refers to undefined config web_cfg: invalid compose project` —— 复现并证实 v0.5.1 要修的第二个阻断缺陷。
  - `/tmp/ebc-x2/compose/unknown.yaml`（顶层 `x-unknown:`）→ 导入成功、`ebasecamp-config-load` 零错误、`(ebasecamp-import-warnings)` = `("顶层键 x-unknown 暂不支持，已忽略")`；docker 的 `config --format json` **保留** `x-*` 顶层键，故真实链路同样能报出警告。
  - 附带实测：docker 会把顶层 config 条目规范化为带 `name: <原项目>_<键名>` 的形态，导入如实保留（`name` 属第一版支持的键之一），不影响 `config -q`。
  - 附加闭环（超出 X2.3 最低要求）：①把上面的导出物**再导入一次** → 加载零错误、`:file-configs` 仍为 `(("web_cfg" ("file" . "./web.conf") ("name" . "compose_web_cfg")))`、二次导出 `config -q` 仍 exit=0（往返稳定）；②顶层 `secrets: {db_pass: {file: ./db_pass.txt}}` + 服务级 `secrets: [db_pass]` → 导入 → 导出 → `config -q` **exit=0 / stderr=""**，`:file-secrets` 保留 `("db_pass" ("file" . "./db_pass.txt") ("name" . "compose_db_pass"))`。



## X3 实现记录（预校验语义，供 X4 文档复用）

- **插入位置**：`ebasecamp-command-run` 内，`check-requires` 之后、`ebasecamp-command-ensure-network` **之前**——生成物不合法时连 external network 都不创建（零副作用），随后才建网络并派发。
- **「先全部校验、再统一启动」的实现**：新增 `ebasecamp-command--preflight (object branches)`——逐分支 `ebasecamp-compose-write` 写生成物 + `ebasecamp-docker-check-compose` 校验，**只写盘与校验、不派发任何 docker 进程**，因此全部通过后才进入 `--dispatch`，不会出现「已启动容器无法回滚」的部分启动。首个失败即停止后续校验（后面的分支连写盘都省掉）。
- **写盘不重复**：`--preflight` 把 `ebasecamp-compose-write` 的实际路径以 `:written` 追加到分支 plist（**不复用 `:file`**——`:file` 是 `--branch-shell` 预算的缓存路径，`:file` 再追加会被 `plist-get` 取到前者且破坏既有用例断言）；`--dispatch` 的 `launch` 改为 `(or (plist-get branch :written) (ebasecamp-compose-write …))`，即「预校验过就复用、没预校验（stop/down）就照旧写一次」。既有「每个分支只写一次生成物」的断言（`run-dispatches-both-scopes` 的 `writes` 计数）不变。
- **失败载荷与成功路径同构**：`ebasecamp-command--preflight-report` 生成与 `--dispatch` 的 `report` 相同字段的结果 plist（`:action :project :ok :results :auto-started-shared :order`），失败分支带 `:failed t` + `:exit` + `:stderr`（原文保留，UI 用 `ebasecamp-docker--first-line` 展示首行），其余分支标 `:skipped t`，`:order` 为 nil（一个都没派发）；`ebasecamp-command-run` 此时返回 nil（无进程）。`ebasecamp-ui--report-result` 无需改动。
- **动作范围**：新常量 `ebasecamp-command--validated-actions` = `(start restart)`。`stop` / `down` 不校验——它们作用于已存在的容器，生成物暂时不合法时更应先允许停掉服务。`run-down-omits-services` 用例把 `check-compose` 桩成 `(error "down 不应做 compose 预校验")`，作为该不变量的守卫。
- **既有测试的桩调整**：`run-dispatches-both-scopes` / `run-args-per-branch`（restart）/ `run-busy` / `run-failure-keeps-stderr` / `run-auto-starts-shared` / `run-shared-failure-aborts-project` / `run-without-requires-keeps-single-branch` 显式打桩 `ebasecamp-docker-check-compose` → `(:ok t :exit 0 :stderr "")`（此前它们只打桩 `run-sync`，校验会经同一桩「侥幸」通过——显式打桩让用例不再依赖 `check-compose` 的内部实现）。`run-unknown-required-shared-service` 在 `check-requires` 就 signal，不进入预校验，未加桩。
- **docstring**：`ebasecamp-command-run` 增加「生成物预校验（X3）」段，说明「校验通过前不建网络、不派发任何进程」「start 串行无法回滚故先校验后启动」「stop/down 不校验」；`--dispatch` 与 `launch` 补 `:written` 语义。
- **batch 探针（真实 docker，Docker 29.9.1 / Compose 5.6.1）**：
  - 造 `/tmp/ebc-x3/broken`（服务级 `configs: [web_cfg]` 但项目无 `:file-configs`）→ `ebasecamp-command-run 'start` 返回 **nil**、结果 `(:ok nil … :results ((:scope project :exit 1 :stderr "service \"api\" refers to undefined config web_cfg: invalid compose project\n" :failed t)))`、pending 已清除、`docker ps -a --filter label=ebasecamp.project=probe-x3` **0 个容器**。
  - 补 `:file-configs` 后（`/tmp/ebc-x3/fixed`）→ 同一路径 `ebasecamp-docker-check-compose` **:ok t / exit 0 / stderr ""**，`ebasecamp-command--preflight` 的 `:failure` 为 nil 且 `:written` 即为生成物路径 —— 即 `run` 的真实预校验路径放行。（**刻意不跑 `up`**：镜像不存在会触发 pull，探针只验证「校验放行 + 不派发前零副作用」这一点。）

### 批次 X2：compose 顶层 configs/secrets

- [x] X2.1 红：模型接受 `:file-configs`/`:file-secrets`（合法字符串键 alist / nil；**符号键与非法值报错**）；导入保留顶层段（含 `{source: {file: …}}` 嵌套结构往返）；导入未知顶层键产生 warnings（可经 `ebasecamp-import-warnings` 读到）；`-update-project` 改 title/root 后两个槽不丢；渲染 per-project 输出 `configs:`/`secrets:`；shared 不输出
      （依赖：X0.2）验收：**FAILED → 12 项红（412 tests / 400 expected / 12 unexpected）**；模型 3 项、导入 5 项（含 `-update-project` 保值）、渲染 3 项、导出 docker 闭环 1 项
- [x] X2.2 实现 `ebasecamp-model.el`（槽 + 白名单 + 字符串键校验）、`ebasecamp-import.el`（读取 + 落盘输出 + warnings 接口）、`ebasecamp-compose.el`（顶层段渲染）；同步 `ebasecamp-config-write--project-output-keys`（见 X4b）。若联调困难可拆 X2.2a（模型）/ X2.2b（导入）/ X2.2c（渲染），测试仍作为一组验收
      （依赖：X2.1）验收：**转绿 + `make check` 全绿（412/412，400 无回归）**；实现语义见「X2 实现记录」
- [x] X2.3 真实 docker 闭环：导入含顶层 `configs` 的 compose → 加载零错误 → 导出 → `docker compose config -q` exit 0 且 stderr 无 error
      （依赖：X2.2）验收：**PASS**；命令与输出见「X2 实现记录」末节

### 批次 X3：`s` 预校验

- [x] X3.1 红：`ebasecamp-command-run` 在生成物 compose 校验失败时**返回失败结果并带 stderr 首行**（不启动 docker 进程，用 `cl-letf` 打桩 `ebasecamp-docker-run-async` 断言未调用）；校验通过时正常执行；shared 与 per-project 两种生成物各一条用例
      （依赖：X2.2）验收：**FAILED → 3 项红（415 tests / 412 expected / 3 unexpected）**；用例 `run-aborts-on-invalid-compose` / `run-checks-shared-and-project` / `run-proceeds-when-compose-valid`，既有 412 项零回归
- [x] X3.2 实现（改 `lisp/ebasecamp-command.el`；`lisp/ebasecamp-ui.el` 无需改动）；**同步 `test/ebasecamp-command-tests.el` 的 run 系列**：显式打桩 `ebasecamp-docker-check-compose` 返回 `(:ok t)`，并确认预校验不改变既有 `:results` / 调用次数断言
      （依赖：X3.1）验收：**转绿 + `make check` 全绿（415/415，412 无回归）**；语义见「X3 实现记录」

### 批次 X4：文档与目检

- [x] X4.1 `Readme.org` / `docs/user-guide.org`：写操作不再要求 `groups.el`；顶层 `configs`/`secrets` 与「重新导入」迁移步骤；`s` 前置校验提示
      （依赖：X3.2）验收：grep 含「groups.el 不再必须」「重新导入」「configs」
- [x] X4.2 `docs/architecture.org`：写盘定位节补「跨文件定位 + 同名裁决」；「清单写盘」节补顶层 configs/secrets 的模型与渲染
      （依赖：X4.1）验收：含「跨文件」「同名」「顶层」
- [x] X4.3 `docs/adr/0006-manifest-locate-compose-configs.org` + `openspec/decisions.md`：ADR 必须**标注扩展 ADR-0005 决策 1（定位改为跨文件）**与**ADR-0003 决策 6 中「`e` → groups.el」表述已过时**，decisions.md 加对应修订行
      （依赖：X4.2）验收：ADR 含两条决策、三条否决、两处扩展注记，以及「跨文件移动 = 两次事务 + 备份补偿，非单事务原子」的记录
- [x] X4.4 `CHANGELOG.md` 0.5.1 + `Version:` 同步
      （依赖：X4.3）验收：`grep -c '0.5.1'` ≥ 1、全部 Version 为 0.5.1
- [x] X4.5 `AGENTS.md` 当前状态（基线更新、v0.5.1 完成）+ `openspec/tech-debt.md` 记录「shared 生成物不含顶层 configs/secrets」与「顶层未知键仅 warning」
      （依赖：X4.4）验收：命中
- [x] X4.6 用户目检：①在 `datarush-go` 上新建配置成功（不再报 groups.el）；②按 `s` 若仍有 compose 问题，提示可读且不启动；③重新导入该 compose 后 `s` 能通过校验/启动（2026-10-24 归档结论：现网无该清单，改以等价链路验证 PASS；视觉项并入 v0.5.2 5.4）
      （依赖：X4.5）验收：用户确认

## X4 文档记录（新增节 / 行数 / 验收）

- **X4.1 `Readme.org`**（437 → 480 行）：新增 `** 组定义放哪里：groups.el 或 projects/*.el`（含「同名组 → 后加载文件整体回滚、其中项目不出现在界面」+ 写操作拒绝）、`** compose 顶层 =configs= / =secrets=`（`:file-configs` / `:file-secrets` 形态、**老清单重新导入一次**、`content:` 多行不支持、shared 不含、界面不编辑）、`** 启动前的 compose 预校验`（逐分支校验 / 零副作用 / `stop`·`D` 不校验）；改写写操作段落（跨文件定位 + 跨文件 move 两次事务 + 备份补偿）、`e` / `ebasecamp-ui-edit-manifest` 三处描述、已知限制 +5 条、文档索引 ADR 范围改到 0006。grep：「groups.el 或 projects」1 / 「重新导入」3 / 「预校验」3。
- **X4.1 `docs/user-guide.org`**（588 → 615 行）：新增 `** 组定义可以放在 groups.el 或 projects/*.el`（同名组三条：加载层报错 + 后加载文件整体回滚 + 写操作拒绝，附「典型来路」）、`** 顶层 configs / secrets 与「重新导入」`（三步迁移步骤）；启停要点 +1 条（预校验）；`e` 节四步与「四条失败路径」；限制表 +4 条。grep：「同名组」3 / 「重新导入」4 / 「预校验」2。
- **X4.2 `docs/architecture.org`**（473 → 511 行）：新增 `** 跨文件定位（=ebasecamp-config-write--manifest-file-for-group=）`（两层收集/裁决、0 与 >1 命中的报错、为何不能复用 `--locate-form`、八个写入口、`add-group` 例外、引用扫描口径分化）、`** compose 顶层 =configs= / =secrets=（模型与渲染）`（槽 / 递归字符串键校验与 `--mapping-p` 同判据 / 导入 warnings / 落盘 / 段序 / shared 不含）、`** 启动前预校验（=ebasecamp-command--preflight=）`（位置在 `ensure-network` 前、逐分支写+校验不派发、`:written` 复用、失败载荷同构、动作范围）。grep：「跨文件」2 / 「同名」4 / 「file-configs」2 / 「预校验」2。
- **X4.3** 新建 `docs/adr/0006-manifest-locate-compose-configs.org`（95 行；决策 3 小节：跨文件定位+同名拒绝 / 顶层段存项目并渲染 / 预校验前置；否决 3 条：自动创建 `groups.el` / 顶层段进服务级 `:extra` / 字符串列表存引用；两处扩展注记：扩展 ADR-0005 决策 1、ADR-0003 决策 6「`e` → groups.el」已过时；显式记录「跨文件移动 = 两次事务 + 显式备份补偿，非单事务原子」）。`openspec/decisions.md` +7 行（3 决策 + 1 修订 + 3 否决）。
- **X4.4** `CHANGELOG.md` 新增 `## [0.5.1] - 2026-10-23`（修复 ×2 / 变更 ×3）；`;; Version:` 全部改 **0.5.1**（实测 **13** 个文件：`ebasecamp.el` + `lisp/` 12 个模块 —— 计划里写的「15 个」与实测不符，`grep -rn '^;; Version:' ebasecamp.el lisp/*.el` 结果为 13 行，已按实测处理）。
- **X4.5** `AGENTS.md` 当前状态（基线 **415**、v0.5.1 完成待目检、下一步 v0.5.2 root 可选）+ 目录结构表 ADR 范围加 0006；`openspec/tech-debt.md` +3 条（#32 shared 生成物不含顶层 configs/secrets、#33 顶层 `content:` 多行不可表达且 `config -q` 仍 exit 0、#34 顶层未知键只 warning 不阻断）。
- **验证**：`make check` 全绿（`check-parens OK (26 files)` / `compile` 零 warning（`byte-compile-error-on-warn t`，EXIT=0）/ `make test` **415 expected / 0 unexpected**）；`org-lint` 四份文件：`architecture.org` 与 ADR-0006 **0 问题**，`Readme.org` **0 问题**（曾因并行编辑损坏出现多余 `#+end_src`，已从备份恢复后串行重做），`user-guide.org` 2 条 **既有** `item-number` 提示（基线同样存在，行号因新增节偏移 +11）。
- **过程教训**：同一文件的多处 `edit_file` **不能并行**（并行写同一文件会交错覆盖，产生重复片段与多余块标记）。本轮 Readme 因此损坏，改为「从备份恢复 + 一次性原子脚本逐条断言 count==1」重做后校验 `begin/end` 配对平衡（12/12 → 13/13）。

## 文档清单

| 文档 | 更新 |
|---|---|
| `Readme.org` | 写盘定位、顶层 configs/secrets、迁移步骤 |
| `docs/user-guide.org` | 同上（操作视角） |
| `docs/architecture.org` | 跨文件定位 + 同名裁决 + 顶层段模型/渲染 |
| `docs/adr/0006-manifest-locate-compose-configs.org` | 新 ADR |
| `openspec/decisions.md` | 追加决策 |
| `AGENTS.md` | 当前状态 |
| `CHANGELOG.md` | 0.5.1 |
| `openspec/tech-debt.md` | shared 不含顶层段；顶层未知键只 warning |

## 验证标准

- **L1**：`make check-parens` + `make compile`（零 warning）
- **L2**：`make test` 全绿（基线 392；预计新增 ≥ 10）；真实 docker 闭环（X2.3）强制
- **L3**：用户目检 3 项（X4.6）
- 每批次更新「## 当前状态」

## 注意事项

- **同名组裁决**：同一组名出现在多个文件时拒绝写（提示清理），不要静默选第一个；`add-group` 写前检查全仓同名。
- **不要自动创建 `groups.el`** 来「修」定位问题（会造出双份同名组）；只有 `add-group` 在确实没有该组时才新建文件。
- 渲染 shared 生成物时**不输出**顶层段（记录限制）；不要为了「统一」把项目级 configs 塞进 `ebc-shared`。
- `s` 预校验放在 `ebasecamp-command-run`（不是 UI 层），对**本次要启动的每个生成物**（shared 与 per-project）都做；校验失败不得派发 `up`。
- `--config-references` 必须遍历所有含 group form 的清单文件（X1 的定位函数同源）；`--legacy-group-references` 继续遍历 `projects/*.el`（它扫的是 project form 的旧 `:groups`）。
- **跨文件移动配置**：两次 `--write-transaction` 不是原子的；第二段失败时必须用第一段的备份**恢复原文**（而不是依赖错误集差分）。实现要点：给 `--write-transaction` 增加可选参数 `:keep-backup`（成功时也保留备份并返回备份路径），先在内存算好两段新全文、分别调用并保留备份，任一失败按逆序用备份恢复，全部成功后才删备份。ADR-0006 必须记录「跨文件移动 = 两次事务 + 显式备份补偿，非单事务原子」（这是对 ADR-0005 决策 2 的部分退化）。
- `:file-configs` / `:file-secrets` 的值是 **compose 原样结构**：模型层只校验「**字符串键** alist 或 nil」（`--yaml-map` 的 `--mapping-p` 只认字符串键，符号键会被渲染成错误 YAML），不做更深语义校验；非法形态 `ebasecamp-model--fail`。
- `config -q` 判据仍是「退出码 + stderr」双条件；stderr 里 `level=warning` 可接受。
- 导入未知顶层键只 warning，不阻断导入（避免用户无法导入）。
- 迁移只提供「重新导入」与写盘 API，不自动改用户清单。
- **不要顺手做 v0.5.2（root 可选）与 v0.6（hjkl/avy/按钮显示键）**。
- **同名组在加载层是硬错误**（X0 实测）：`groups.el` 与 `projects/x.el` 各定义同名组时加载报「组 X 已定义」，且**后加载文件整体回滚**——同文件里的项目一起从界面消失。因此写盘定位对 >1 命中必须 `user-error` 并提示「否则该项目不会出现在界面中」，禁止静默选第一个。
- **`--locate-form` 不能用于文件裁决**：它明确「同名多个时返回第一个」，语义只适合「同一份已扫文本内取唯一 form」。跨文件定位要自己收集全部命中再裁决（`--manifest-file-for-group`），引用扫描（`--config-references`）则故意允许多命中。
- **`content:` 多行值不可表达**：`--yaml-map` 只认字符串键 alist + 单行标量；顶层 `configs` 的 `content:` 多行字符串在现有字面量写法下会被 `--literal` 转义成单行 `\n`，第一版不建模（记入 tech-debt），X2 只处理 `file:` / `external:` / `name:` 这类单值结构。


## 后续计划

- **v0.5.2**：project `:root` 可选（无 root 不参与项目定位；导出必须显式选路径）
- **v0.6**：按钮旁显示键（`s`/`x`/`r`、`I`/`o`/`D`）、`h/j/k/l` 移动、avy 跳转；随后是原计划的监控与日志
