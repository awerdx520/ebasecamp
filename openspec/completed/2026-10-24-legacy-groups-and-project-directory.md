# ebasecamp v0.5.2 — 旧 :groups 去重与迁移 + compose 路径基准

## 当前状态

- 阶段：**已归档**（2026-10-24 移入 `openspec/completed/`）
- 已确认：方案 ✅（用户 2026-10-24：A-I + A-II **都做**，A-II 的自动迁移**必须经用户确认、不得静默改写项目文件**；B 采用 B-I + B-II 组合，`:root` 为 nil 时回退并 warning）；计划 ✅（用户 2026-10-24）
- 结果：批次 1–5.4 **全部完成**。加载期旧 `:groups` 原位接管（A-I）、写盘迁移须用户确认（A-II）、派发与预校验统一 `--project-directory`（B-I）、顶层 `configs`/`secrets` 的 `file:` 存在性预校验 + `:preflight-warnings` 透传（B-II）均已落地。
- 测试基线：415 → **436 expected / 0 unexpected**（`make check` 全绿：`check-parens` 26 files / `compile` 零 warning / `test` 436）；批次分解 415 → 418（批次 1 净 +3）→ 424（批次 2 +6）→ 428（批次 3 +4）→ 436（批次 4 +8）。
- L3 目检：**4 项全部通过**（2026-10-24，用户在自己的 Emacs 中执行：①`X` 新建配置关联 `example` 选 yes → 成功且旧引用被清；②再新建选 no → 仍成功且不重复提示；③`s` 启动成功；④删掉 config 文件后 `s` 给可读错误且不启动）。
- 回滚点：`lisp/ebasecamp-model.el`、`lisp/ebasecamp-command.el`、`lisp/ebasecamp-docker.el`、`lisp/ebasecamp-config-write.el`、`lisp/ebasecamp-ui.el`、测试与文档（本次为最终提交，回滚点由 git 提交本身承担）。
- 后续：v0.5.3（project `:root` 可选）→ v0.6（观测）；遗留技术债见 `openspec/tech-debt.md` #20 / #29 / #30 / #35–#40。

## 目标

1. **旧 `:groups` 与组侧 `:configs` 共存不再报错**（A-I）：同项目同组的旧写法引用被组侧配置**原位接管**，只有「两份以上配置指向同项目同组」才报错。
2. **旧写法可经用户确认后清理**（A-II）：界面新建/改配置时检测到同项目同组的旧 `:groups` 引用，弹确认；确认后在同一批事务里删掉该旧条目（跨文件则两次事务 + 备份补偿）。
3. **compose 路径基准修正**（B-I）：派发与预校验统一注入 `--project-directory <项目 root>`，使清单里的相对路径按项目 root 解析而非生成物所在的 cache 目录。
4. **预校验覆盖 config/secret 文件存在性**（B-II）：`config -q` 不校验这一层，改由 Elisp 侧按 `<root>/<file>` 检查，缺失时给出可读错误并中止启动。

## 非目标

- project `:root` 可选（顺延 v0.5.3；本计划只做「root 为 nil 时回退 + warning」，不改 root 的必填性/语义）
- 按钮旁显示键 / `hjkl` / avy（v0.6）
- 导出场景的路径基准（`ebasecamp-export` 的目标位置由用户选，若不在项目 root 下则顶层 `configs.file` 相对路径同样失效——本计划只记 tech-debt，不修；`export.el:209` 的 `check-compose` 调用**不传 root**，只影响 `env_file` 相对路径的校验基准，不影响 config/secret 存在性）
- 相对 `volumes` source 的存在性检查（同样只在容器创建阶段失败，记 tech-debt）
- `ebasecamp-import.el` 的 `docker compose config` 调用（`:435` / `:514` 读的是**用户项目自身的 compose 文件**，其所在目录即项目 root，基准本就正确，**不得**加 `--project-directory`；ADR-0007 须写明该理由）
- 界面编辑顶层 `configs` / `secrets`（第一版仍只保证导入 → 渲染往返）
- 顶层未知键由 warning 升级为阻断

## 探针记录（2026-10-24 实测，实现必须遵守）

### P1 现网清单核对（推翻 v0.5.1 诊断前提）

- `~/.config/ebasecamp/` 现为 `M-x ebasecamp-create-sample-config` 生成的**示例清单**：`groups.el`（`mysql` scope shared + `redis` scope per-project，两者都**没有** `:configs`）、`projects/example.el`（`:root "~/Workspace/example"`，**该目录不存在**，用旧写法 `:groups ((mysql) (redis))`）。
- 无 `datarush-go` 项目，`/tmp/ebc-diag/` 已不存在 → v0.5.1 的 X4.6 目检场景无法复现。
- 由此暴露 **A 缺陷的必然性**：示例清单正是「组无配置 + 项目用旧写法」的形态，任何 `X` → 新建配置关联 `example` 都会让同一组同时被旧 `:groups` 与组侧 `:configs` 引用 → `ebasecamp-config--duplicate-group-ref` / `:duplicate-group` → 事务回滚。实测错误原文：`写入 …/groups.el 后清单新增 1 个错误，已回滚：项目 example 重复引用组 redis（来源：旧 :groups）`。

### P2 docker 路径基准（B 的修法依据）

| 项 | 命令 | 实测 |
|---|---|---|
| T2 | `-f <cache>/compose.yaml config -q` | **exit 0**（`config -q` **不校验** config/secret 的 `file:` 是否存在） |
| T3 | `-f <cache>/compose.yaml config --format json` | `configs.my_cfg.file = /tmp/ebc-b/cache/conf/app.conf` → **基准 = compose 文件所在目录** |
| T4 | `-f <cache>/compose.yaml --project-directory <proj> config --format json` | `configs.my_cfg.file = /tmp/ebc-b/proj/conf/app.conf` → **基准被改写为项目 root** |
| T7a/T7b | `up --dry-run`（有/无 `--project-directory`） | 两者都 exit 0、输出相同 → **dry-run 测不出** |
| 补证 1 | `compose create`（未启动）缺失源 | **exit 1**：`bind source path does not exist: /tmp/ebc-b/cache/conf/app.conf` |
| 补证 2 | 同上 + `--project-directory <proj>` | **exit 0**（源存在即可） |
| 补证 3 | `env_file: ./app.env` 缺失 | **config -q exit 1**（`config` 会校验 env_file，却不校验 configs/secrets） |
| 补证 4 | secret 变体 | 规则与 configs 完全一致 |
| 补证 5 | 相对 volume source / `.env` | `--project-directory` 一并生效；**加上该 flag 后 docker 会读取 `<root>/.env`** |
| 补证 6 | flag 位置 | `--project-directory` 是**根级 flag**，必须在子命令**之前**（`compose -f FILE --project-directory DIR <subcmd>`）；`-p` 显式传入，项目名不漂移 |

结论：B-I 用 `--project-directory`；B-II 必须由 Elisp 侧做文件存在性检查（H3）；`.env` 额外读取是行为变更，须在 ADR 记录。

## 设计决策

### A-I 加载期去重（`ebasecamp-model--link-configs`）

- 现状：步骤 1 把项目 groups 槽回到旧 `:groups` 基线，并登记 `sources[(project . group)] = "旧 :groups"`；步骤 2 逐配置物化，E2 判据「同项目同组已有引用（不论来源）」→ 记 `:duplicate-group` 错误。
- 改为**双簿记**（`sources` + `legacy` 两个 hash，键都是 `(项目名 . 组名)`）：
  - `sources` 继续登记「当前有效引用的来源」：旧 `:groups` → `"旧 :groups"`；物化成功 → `(format "配置 %s" config-name)`（**保持现有形态**，消息可读性更好）；兜底串 `"另一份配置"` 只用于消息，**不作判据**；
  - `legacy` 只登记「该引用当前由旧 `:groups` 提供、可被组侧配置接管」的标记（值 `t`）；步骤 1 对每条旧引用置位；
  - E2 命中时：`legacy` 有标记 → **原位替换**为本次物化结果（`:group` / `:scope` / `:service-overrides` 取组侧配置），**不记错误**，随后 `(remhash (cons project-name group-name) legacy)` 并把 `sources` 更新为 `(format "配置 %s" config-name)`；`legacy` 无标记 → 保持现状，记 `:duplicate-group`，消息仍为 `来源：%s`（`%s` 取 `sources` 的配置名，`(or ... "另一份配置")` 兜底不变）。
  - 三种组合的落点：旧 `:groups` + 1 份配置 → 接管；旧 `:groups` 被接管后再来第 2 份配置 → 报错并点名第一份配置；纯 2 份配置（无旧写法）→ 报错并点名第一份配置。
- 顺序语义：替换保持旧引用在原位（项目 groups 槽顺序不变），配置的顺序不影响结果。
- 幂等性：函数每次从基线重算，`sources` 每次重建，不累积。
- **不变量 9 修订**（`AGENTS.md`）：由「同一项目对同一组重复引用一律加载报错」改为「同一项目同一组只允许 **1 个有效引用**；旧 `:groups` 与组侧 `:configs` 指向同项目同组时以**组侧配置**为准（原位接管、不报错），仅当**两份以上组侧配置**指向同项目同组时报 `ebasecamp-config-duplicate-group-ref`」。

### A-II 写盘迁移（须用户确认，绝不静默）

- 新增内部助手 `ebasecamp-config-write--legacy-reference-file (project-name group-name)`：遍历 `projects/*.el` 定位「含旧 `:groups` 且该组名在其中的项目 form」所在文件，返回 `(FILE . POSITION-DATA)` 或 nil；复用 X1 的 `--group-files` / 表单扫描（**不得**复用 `ebasecamp-manifest--locate-form` 的单命中语义）。
- 新增 `ebasecamp-config-write--migrate-legacy (project-name group-name)`：删除项目文件里该组名的旧引用条目（`:groups` 列表元素），一次事务；**该组名是 `:groups` 里唯一元素时整条 `:groups` 键移除**（避免留下空列表）。
- 写盘入口加**显式可选参数**（默认 nil，非交互调用零行为变更）：
  - `ebasecamp-config-write-add-config (group config project &optional migrate-legacy)`
  - `ebasecamp-config-write-update-config-project (group config project &optional migrate-legacy)`
- **两条编排路径必须分别实现，不可合并**：
  1. **同文件**（组定义在 `projects/x.el`，且该项目定义也在同一文件——v0.5.1 X1 已支持组写在项目文件）：**一次事务**内两处降序替换（组侧 `:configs` 追加 + 项目侧 `:groups` 删元素），复用 `--move-config-within-file` 的 `--replace-forms` 模式；
  2. **跨文件**（最常见：组在 `groups.el`、项目在 `projects/*.el`）：先写组文件事务（须拿到备份）→ 再写项目文件事务 → 第二段失败用第一段备份恢复原文并 `signal` 原错误（**复用 `--move-config-across-files` 的补偿模式，不引入新原子性假设**）。
- **`--edit-manifest` 必须支持透传 `:keep-backup`**：现状（`config-write.el:441`）直接调 `ebasecamp-manifest--write-transaction` 且不传该键，而 `add-config` 走的正是它（`:654`）→ 跨文件路径**拿不到备份**。改为 `(defun ebasecamp-config-write--edit-manifest (file editor &optional keep-backup))`：非 nil 时透传 `:keep-backup t` 并原样返回 `(:result … :backup …)`；默认 nil 时返回值形态与现在一致（既有调用点零改动）。
- **删除 `:groups` 元素必须真正移除 key**：删掉唯一元素时用 `plist-remprop`（或等价方式去掉 `:groups` 及其值），**不得**把值置 nil —— `--project-form`（`config-write.el:998`）用 `plist-member` 判定，key 仍在会渲染出 `:groups nil`。
- **`--legacy-reference-file` 返回形态**：`(FILE . PLIST)`，`PLIST` 至少含 `:start` / `:end`（该 `:groups` **元素**的 1-based 区间，切片用 `(1- pos)`）与 `:form-start` / `:form-end`（所在 project form 区间）；无命中返回 nil。**不得**复用 `ebasecamp-manifest--locate-form`（单命中语义）或 `--legacy-group-references`（只返回项目名列表、无位置）。
- **UI 层（唯一触发点）**：`ebasecamp-ui--manifest-menu` 的「新建配置」与 `ebasecamp-ui--open-config-editor`（`E`）在调用写盘前，若 `--legacy-reference-file` 命中，则 `y-or-n-p`：
  「项目 example 的旧写法 :groups 仍引用组 redis；新建配置后该旧引用将被组侧配置接管。是否同时删掉这条旧引用？」
  - 答 yes → 传 `migrate-legacy` = t；答 no → 传 nil（仍能成功，走 A-I 兼容路径，下次再提示）。
  - **绝不在无确认的情况下传 t**；脚本/测试调用默认 nil。
- `-move-config`（`M`）第一版**不做迁移**（跨组移动不新增同项目同组关联；若撞到旧写法由 A-I 兼容），记入「限制」。

### B-I 派发与预校验统一基准

- `ebasecamp-command-compose-args (action file project-name services &optional root)`：`root` 非 nil 时在 `-f FILE` 之后、子命令之前插入 `--project-directory` + `(expand-file-name root)`；nil 时参数与当前**逐字节一致**（既有测试零改动）。
- `ebasecamp-command--dispatch` / `--preflight` 传 `(ebasecamp-project-root project)`。
- `ebasecamp-docker-check-compose (file &optional root)`：`root` 非 nil 时同样注入（预校验与真实派发**必须同基准**，否则重现「校验过、启动炸」）。
- `ebc-shared` 生成物：用**触发本次操作的项目的 root**（shared 分支由谁触发就用谁的 root；shared 配置的 `:project` 只是渲染上下文，可能不是触发者）。
- `:root` 为 nil（模型允许，`model.el:494` 只在非 nil 时校验类型）→ 不传 flag，退回当前行为；由 B-II 给 warning（不硬失败）。

### B-II 预校验文件存在性

- 位置：`ebasecamp-command--preflight` 内、`ebasecamp-docker-check-compose` **之前**（`lib/preflight` 已有逐分支结构，见 `command.el:402-430`）。
- 判据（只对**将要启动**的分支；`stop` / `down` 不校验，沿用 `ebasecamp-command--validated-actions`）：
  - 取项目 `:file-configs` / `:file-secrets`（**只取本项目**；shared 分支不检查项目级顶层段——shared 生成物本就不输出顶层段）；
  - 逐条取 `file:` 值：**绝对路径** → 直接 `file-exists-p`；**相对路径** → 拼 `<root>/<file>` 后检查；**无 `file:`（如 `external: true` / 纯 `name:`）** → 跳过；
  - `root` 为 nil 且存在相对路径 → 记 **warning**（不失败），消息「项目 X 无 :root，无法校验顶层 config `app_cfg` 的 file `./conf/app.conf`」；warning 集合命名 **`:preflight-warnings`**（**刻意不复用 `:warnings`**——`check-compose` 的 `:warnings` 是 compose stderr 的 `level=warning` 行，语义不同）；
  - **成功路径的透传链路（必须实现，否则 warning 到不了 UI）**：`ebasecamp-command--preflight` 的返回值新增 `:preflight-warnings`（字符串列表）→ `ebasecamp-command-run` 的**成功分支**把 `(plist-get preflight :preflight-warnings)` 作为新参数传给 `ebasecamp-command--dispatch`（签名加 `&optional preflight-warnings`）→ `--dispatch` 内的 `report()` 把该值加入 on-complete plist 的 `:preflight-warnings` 字段 → `ebasecamp-ui--report-result` 成功分支在 detail 末尾按计数追加「（N 条预校验警告）」。**注意：`--preflight-report` 是失败路径专用，成功场景根本不经过它**，不要在那里拼装成功提示；
  - 失败路径与判定不受影响：warning 不改变 `:ok` / `:failed` / `:exit`；
  - 相对 `volumes` source 缺失同样会在容器创建阶段失败（探针补证 5），**本计划不检查**，记入 tech-debt；
  - 缺失 → 预校验失败，`:stderr` 用可读消息「顶层 config `app_cfg` 的 file `./conf/app.conf` 不存在（基准：<root>）」，`:exit` 为 nil 但 `:failed t`（与 X3 的失败载荷同构，UI 零改动）。
- 不新增「渲染层改路径」逻辑：`ebasecamp-compose.el` **一行不改**（路径语义仍由 docker 的 `--project-directory` 决定）。

## 任务

### 批次 1：A-I 加载期去重

- [x] 1.1 红：`test/ebasecamp-model-tests.el` 新增 4 项——①旧 `:groups` + 组侧 1 份配置指向同项目同组 → `link-configs` **零错误**、该引用变配置形态（含 `:service-overrides`，顺序仍在原位）；②组侧 **2 份**配置指向同项目同组（**无**旧写法）→ 报 `:duplicate-group`，消息含「来源：配置 config-a」（点名第一份配置）；③旧 `:groups` 被接管后再来第 2 份配置 → 报 `:duplicate-group`，消息含「来源：配置 <第一份>」（验证 `legacy` 标记已被清除）；④旧 `:groups` 无组侧配置 → 引用保持 `:service-overrides` 为 nil 的 legacy 形态（回归保护）
      （依赖：无）验收：**FAILED**——①③ 红，②与④ 为天然绿的回归保护（`make test` 计数 419 下 **2 unexpected**；② 早被既有 `materialize-errors-on-duplicate-configs-same-project` 守护，④ 是既有行为）
- [x] 1.2 实现 `ebasecamp-model--link-configs` 的 E2 判据分支 + `sources` 升级语义 + docstring（写明「旧写法原位接管、仅多配置冲突报错」）
      （依赖：1.1）验收：**转绿 + `make check` 全绿（415 − 1（语义反转的旧用例被新增①顶替）+ 4 新增 = 418 expected / 0 unexpected）+ 同步修订 `AGENTS.md` 不变量 9 的文字（只改该条，其余不动，避免批次 5 之前代码与文档口径相反）**

### 批次 2：B-I `--project-directory`

- [x] 2.1 红：`test/ebasecamp-command-tests.el`——`ebasecamp-command-compose-args` 传 root 时参数序列为 `("compose" "-f" FILE "--project-directory" ROOT "-p" NAME ...)`（四个动作各一条，断言**位置**：`--project-directory` 在 `-f` 之后、子命令之前）；不传 root 时与旧序列 `equal`；`test/ebasecamp-docker-tests.el`——`check-compose` 传 root 时命令行含该 flag 且 root 绝对化
      （依赖：无）验收：**FAILED**，既有 418 项零回归（本批次新增 6 项红：4 个动作的位置断言 + 1 项不传 root 时逐字节一致 + 1 项 check-compose 注入）（实测 2026-10-24：`Ran 424 tests, 418 results as expected, 6 unexpected`，6 个失败项正是新增用例；用例分摊见「## 批次 2 记录」——4 个动作各 1 个 deftest（每个含「带 root 位置断言」+「不带 root 逐字节一致」两条 should）+ 1 项 root 绝对化 = command 5 项，docker 1 项，合计 6）
- [x] 2.2 实现 `command.el`（`--compose-args` 加可选 `root`、`--dispatch` / `--preflight` 传 root）+ `docker.el`（`check-compose` 加可选 `root`）
      （依赖：2.1）验收：**转绿 + `make check` 全绿（418 + 本批次 6 项 = 424 expected / 0 unexpected）**（实测 2026-10-24：`Ran 424 tests, 424 results as expected, 0 unexpected`；`check-parens OK (26 files)`；`make compile` 零 warning、exit 0）

### 批次 3：B-II 预校验文件存在性

- [x] 3.1 红：`test/ebasecamp-command-tests.el` 新增 4 项——①`:file-configs` 相对路径缺失 → `run` 返回失败、消息含「不存在（基准：」、`run-async` 零调用；②文件存在 → 放行；③`root` 为 nil 且有相对路径 → **warning 不失败**，且结果 plist 的 `:preflight-warnings` 含该条消息（命令层可见，验证透传起点）；④`external: true` / 无 `file:` → 跳过不报错
      （依赖：2.2）验收：**FAILED**，既有 424 项零回归（本批次新增 4 项红）（实测 2026-10-24：`Ran 428 tests, 425 results as expected, 3 unexpected` —— 其中 2 项是新增红灯（①`run-aborts-on-missing-top-level-file`、③`run-warns-when-root-missing`），②④ 为**天然绿**（既有实现不检查任何文件，故「存在→放行」「无 file→跳过」本就直接通过，作回归保护），第 3 项 `ebasecamp-docker-test-run-sync-captures-streams` 为**既有偶发抖动**（复跑即过，与本批次无关）；既有 424 项零回归）
- [x] 3.2 实现 `ebasecamp-command--preflight` 的文件存在性检查（warning 集合命名 `:preflight-warnings`，并经 `ebasecamp-command-run` 成功分支 → `ebasecamp-command--dispatch`（新增 `&optional preflight-warnings`）→ `:report-result` 透传到成功提示）
      （依赖：3.1）验收：**转绿 + `make check` 全绿（424 + 本批次 4 项 = 428 expected / 0 unexpected）**（实测 2026-10-24：`Ran 428 tests, 428 results as expected, 0 unexpected`；`check-parens OK (26 files)`；`make compile` 零 warning、`make check` exit 0）

### 批次 4：A-II 写盘迁移（须用户确认）

- [x] 4.1 红：`test/ebasecamp-config-write-tests.el` 新增 5 项——①`add-config` 传 `migrate-legacy=t` 时项目文件里该组旧引用被删除（**同文件**情形）；②跨文件情形（组在 `groups.el`、项目在 `projects/x.el`）两段都生效；③跨文件第二段失败 → 第一段回滚（项目文件与组文件都恢复原文）；④`migrate-legacy=nil`（默认）时**项目文件逐字节不变**；⑤`:groups` 仅剩该组一条时整条键被移除（断言渲染结果**不含** `:groups`，而非出现 `:groups nil`）。`test/ebasecamp-ui-tests.el` 新增 3 项（复用 U 段 etaf 脚手架，`cl-letf` 打桩 `ebasecamp-config-write-add-config` 与 `y-or-n-p`）——⑥「新建配置」命中旧引用时 `y-or-n-p` 被调用、答 yes 时写盘收到 `t`；⑦答 no 时写盘收到 `nil` 且流程仍成功；⑧`E`（`ebasecamp-ui--open-config-editor`）同样调 `y-or-n-p` 并正确传参（该入口无既有单测，本条为新增覆盖）
      （依赖：1.2）验收：**FAILED**，既有 428 项零回归（本批次新增 8 项红）（实测 2026-10-24：`Ran 436 tests, 429 results as expected, 7 unexpected` —— ④`-migrate-legacy-default-nil-keeps-project-file` 为**天然绿**：默认 nil 走既有单事务路径，项目文件本就不动，作回归保护；其余 7 项（写盘 4 + UI 3）全红）
- [x] 4.2 实现：`--legacy-reference-file`（返回 `(FILE . PLIST)`）/ `--migrate-legacy` / `--edit-manifest` 的 `:keep-backup` 透传 / `--add-config` 与 `--update-config-project` 的 `migrate-legacy` 可选参数（同文件单事务、跨文件两事务 + 备份补偿两条路径）/ 两处 UI `y-or-n-p` 确认
      （依赖：4.1）验收：**转绿 + `make check` 全绿（428 + 本批次 8 项 = 436 expected / 0 unexpected）**（实测 2026-10-24：`Ran 436 tests, 436 results as expected, 0 unexpected`；`check-parens OK (26 files)`；`make compile` 零 warning、`make check` exit 0）

### 批次 5：闭环、文档与目检

- [x] 5.1 真实 docker 闭环（示例清单，`/tmp` 副本）：在 `example` 上新建配置关联 `redis`（确认迁移）→ 加载零错误 → `s` 预校验通过 → 用 `docker compose create` 或 `config --format json` 验证 `--project-directory` 生效；再构造顶层 `configs.file` 缺失场景，确认预校验给可读错误且零派发
      （依赖：4.2）验收：PASS + 命令与输出记录进「## 批次 4 记录」
- [x] 5.2 文档：`AGENTS.md`（新增「派发与预校验必须同用 `--project-directory`」不变量 + 当前状态/基线；不变量 9 文字已在 1.2 修订，此处只复核）、`docs/adr/0007-legacy-groups-and-project-directory.org`（两决策 + 否决项 + `.env` 副作用 + 不变量 9 修订依据）、`openspec/decisions.md`、`Readme.org`、`docs/user-guide.org`、`docs/architecture.org`、`CHANGELOG.md`（0.5.2）、`openspec/tech-debt.md`（导出路径基准 / 相对 `volumes` source 未检查 / `-move-config` 不迁移 / `A-II` 首版只覆盖两个入口 / 预校验警告的展示范围：`:report-result` 成功分支的「N 条预校验警告」仅由批次 5.4 目检覆盖，无单测）
      （依赖：5.1）验收：grep 命中各关键词
- [x] 5.3 归档 v0.5.1：`openspec/active/2026-10-23-manifest-locate-compose-configs.md` 移入 `completed/`，其「## 当前状态」写明「X4.6 因现网无该清单无法执行，等价链路 PASS（证据见本计划探针记录），视觉项并入 v0.5.2 批次 5 目检」；同步 `AGENTS.md` 当前状态与基线
      （依赖：5.2）验收：`openspec/active/` 只剩本计划
- [x] 5.4 用户目检：①示例清单上 `X` → 新建配置关联 `example` 成功（弹确认时选 yes，项目文件旧引用被清掉）；②再新建一次配置选 no → 仍成功且不重复提示（旧引用已被清）；③`s` 启动成功；④删掉一个 config 文件后 `s` 给可读错误且不启动
      （依赖：5.3）验收：**用户确认 ✅**（2026-10-24 在真实 Emacs 中目检 4 项全部通过）

## 文档清单

| 文档 | 更新 |
|---|---|
| `AGENTS.md` | 不变量 9 修订（批次 1.2）+ 新增 `--project-directory` 不变量 + 当前状态/基线 |
| `docs/adr/0007-legacy-groups-and-project-directory.org` | 新 ADR（两决策、否决项、`.env` 副作用、跨文件补偿） |
| `openspec/decisions.md` | 追加决策行 |
| `Readme.org` / `docs/user-guide.org` | 旧写法接管 + 迁移确认 + 路径基准（含 `.env` 行为） |
| `docs/architecture.org` | 物化冲突判定 + 派发参数构造 |
| `CHANGELOG.md` | `## [0.5.2]` + `Version:` 全部改 0.5.2（13 个文件） |
| `openspec/tech-debt.md` | 导出路径基准、`-move-config` 不迁移、A-II 覆盖范围 |
| `openspec/completed/` | v0.5.1 计划归档 |

## 验证标准

- **L1**：`make check-parens` + `make compile`（零 warning）
- **L2**：`make test` 全绿（基线 415 → 终值 436，即净新增 21 项：批次 1 净 +3（−1 +4）/ 批次 2 +6 / 批次 3 +4 / 批次 4 +8）；批次 5.1 真实 docker 闭环强制
- **L3**：用户目检 4 项（批次 5.4）
- 每批次更新「## 当前状态」

## 注意事项

- **A-I 不得破坏顺序与幂等**：替换必须原位（旧引用位置不变）；**必须用 `legacy` 标记而非 `sources` 的字符串值来裁决「能否接管」**，替换后立刻 `remhash` 该键并把 `sources` 更新为当前配置名——否则第二份配置会再次接管并**静默丢掉第一份**（本方案最容易写错的地方，用例②③专门守护）。
- **`sources` 的字符串值只用于错误消息，不能当判据**：`"旧 :groups"` / `"配置 X"` / 兜底 `"另一份配置"` 三种形态共存，任何「比较字符串决定行为」的写法都是错的。
- **A-II 绝不能静默**：写盘层默认 `migrate-legacy` = nil；只有 UI 层 `y-or-n-p` 答 yes 才传 t。测试必须有一条「默认 nil 时项目文件逐字节不变」的断言。
- **A-II 跨文件不是原子的**：两次事务 + `:keep-backup` 备份补偿，第二段失败必须恢复第一段原文并 `signal` 原错误；ADR-0007 必须记「部分退化」，沿用 ADR-0006 的表述口径。
- **`--project-directory` 是根级 flag**：必须插在 `-f FILE` 之后、子命令**之前**，写成 `compose -f FILE --project-directory DIR up -d …`；放错位置 docker 报 `unknown flag`（探针补证 6）。
- **预校验与派发必须同基准**：`check-compose` 不传 root 而 `up` 传了（或反之）会重现「校验过、启动炸」。两条路径必须共用同一份 root 推导。
- **`config -q` 不校验 config/secret 文件存在性**（T2 实测），只有 `env_file` 会被 `config` 校验（补证 3）——不要把「补 B-II」理解为「`config -q` 够了」。
- **`up --dry-run` 不能用来验证路径基准**（T7a/T7b 输出相同）；闭环验证用 `config --format json` 看 `configs.<n>.file` 解析值，或 `compose create`（**必须事后 `compose down` 清理**，否则第二次 `create` 会静默假成功 —— 探针发现的坑）。
- **`--project-directory` 会让 docker 读取 `<root>/.env`**（补证 5）：这是行为变更，ADR 与用户文档都要写明；`-p` 已显式传入，项目名不漂移。
- **`ebc-shared` 用触发项目的 root**：不要试图从 shared 配置的 `:project` 反推（那只是渲染上下文）；root 为 nil 时退回旧行为并由 B-II warning。
- **渲染层一行不改**：`ebasecamp-compose.el` 保持相对路径原样输出（不变量 6）；修正基准的责任在命令行 flag，不在渲染。
- **禁止调用 `docker compose config --environment`**：实测会转储宿主机全部环境变量（含密钥类变量名，79 行），插件任何路径都不得调用。
- **不要顺手做 v0.5.3（root 可选）与 v0.6**；`export` 的路径基准只记 tech-debt。
- 同一文件的多次 `edit_file` **不得并行**（v0.5.1 曾因此损坏 Readme）。

## 批次 1 记录

### 实现要点（A-I 加载期去重）

- **双簿记**：`ebasecamp-model-link-configs` 内并列新建两个 hash（键均为 `(项目名 . 组名)`）——`sources`（`model.el:764`）只承载错误消息里的来源串，`legacy`（`model.el:765`）只承载「该引用当前由旧 `:groups` 提供、可被组侧配置接管」的标记；两者每次调用在函数内 `let` 新建，天然幂等。
- **置位**：步骤 1 遍历项目基线时对每条旧引用同时 `puthash` `sources` = `"旧 :groups"` 与 `legacy` = `t`（`model.el:774-776`）。
- **E2 判据按标记裁决**（`model.el:809-816`）：命中「同项目同组已有引用」且 `legacy` 无标记 → 保持原判定，记 `:duplicate-group`，消息模板与 `(or … "另一份配置")` 兜底不变；`legacy` 有标记 → 不报错，落入物化分支。
- **原位替换**：物化成功且 E4（未知服务）/ E5（覆盖非法）均通过后，`(gethash … legacy)` 为真 → 调 `ebasecamp-model--replace-group-reference`（`model.el:710`：遍历 groups 槽，对 `:group` 匹配的**首个列表 cell** 做 `setcar`），保持元素位置不变；随即 `remhash` 该键（`model.el:860`）并把 `sources` 更新为 `"配置 <config-name>"`（`model.el:864`）。无标记 → 仍 `append` 到末尾。
- **幂等保证**：`ebasecamp-model--legacy-groups-of` 每次返回快照的浅拷贝，`setcar` 只改本次基线列表的 cell，既不改快照内元素、也不改原始 reference plist → 连续调用结果稳定（既有 `materialize-is-idempotent` 用例守护）。
- **`sources` 只用于消息**：任何行为分支都不比较其字符串值（三种形态 `"旧 :groups"` / `"配置 X"` / `"另一份配置"` 共存）。
- docstring 已更新：补「旧写法兼容（A-I）」段，并把校验项「同项目同组已有引用（来自旧 :groups 或另一份配置）」改为「同项目同组已有**另一份配置**物化出的引用（旧 :groups 的引用可被接管，不算冲突）」。
- `AGENTS.md` 不变量 9 已整条替换为新口径（旧写法原位接管；仅两份以上组侧配置报 `ebasecamp-config-duplicate-group-ref`）。
- **用例①强化（原位断言）**：追加一条无配置的旧引用 `redis`（`:groups ((db) (redis))`），断言接管后 `db` 仍在首位、`redis` 仍在次位——覆盖计划任务 1.1 的「顺序仍在原位」验收点（若实现误改为 append，该断言即红）。

### 红灯证据（新增 4 项、删除 1 项既有用例之前）

```
FAILED  257/419  ebasecamp-model-test-legacy-reference-taken-over-by-config (0.000095 sec) at test/ebasecamp-model-tests.el:791
FAILED  283/419  ebasecamp-model-test-taken-over-then-second-config-conflicts (0.000210 sec) at test/ebasecamp-model-tests.el:823
Ran 419 tests, 417 results as expected, 2 unexpected
```

用例②（纯 2 份配置点名第一份）与④（旧 `:groups` 无组侧配置）为**天然绿的回归保护**——②早被既有 `materialize-errors-on-duplicate-configs-same-project` 守护，④是既有行为。

### 绿灯证据（`make check`，2026-10-24）

- `make check-parens` → `check-parens OK (26 files)`，exit 0
- `make compile` → exit 0，零 `Warning` / `Error` 行（`byte-compile-error-on-warn` 生效）
- `make test` → `Ran 418 tests, 418 results as expected, 0 unexpected`

### 与计划的偏差

- **计划原写「批次 1 +4 → 419」，实测净 +3 → 418**：既有用例 `materialize-errors-on-duplicate-group-reference`（旧断言：旧 `:groups` + 1 份配置 → 1 条错误、消息含「来源：旧 :groups」、槽保持 legacy 形态）与 A-I 语义**完全反转**，实现后必红。经用户裁决：**删除该用例**，由新增用例①顶替（覆盖同一语义且信息更全：零错误、接管后仍在原位、`:group` 保持、`:service-overrides` 取自配置）→ 415 − 1 + 4 = **418**；全链路终值随之 415 → **436**（批次 2 → 424 / 批次 3 → 428 / 批次 4 → 436）。
- 实现后**无其它**既有用例变红（除上述已裁决的 1 项）。
- 计划原文「用例②现在应红」不成立（②本就绿），红灯数实为 **2**；已在任务 1.1 验收行与本节改按实测口径写明。
- **教训**：行为反转类改动必须在计划阶段用 grep 找出既有测试中守护旧语义的用例并列入任务（本次到执行阶段才发现，靠用户裁决才定下「删 1 增 4」）。

## 批次 2 记录

### 实现要点（B-I `--project-directory`）

三处插入点（行号为 2026-10-24 实测，插入后 `test` 文件行号会随批次 3 变化）：

1. **`lisp/ebasecamp-command.el:348-357`** —— `ebasecamp-command-compose-args` 新增第 5 个可选参数 `&optional root`，头部改为
   `(append (list "compose" "-f" file) (when root (list "--project-directory" (expand-file-name root))) (list "-p" project-name))`：
   flag 落在 `-f FILE` 与 `-p NAME` **之间**（实测序列 `("compose" "-f" FILE "--project-directory" ROOT "-p" NAME <子命令> ...)`），
   子命令与 `-p` 之间无其它元素；root 为 nil 时 `when` 返回 nil，`append` 得历史序列（**无 nil 占位**）。
2. **`lisp/ebasecamp-command.el:430`（预校验）** —— `ebasecamp-command--preflight` 在 `while` 外 `let` 一次 `(root (ebasecamp-project-root object))`，
   逐分支调用 `(ebasecamp-docker-check-compose file root)`（原为单参 `file`）。
3. **`lisp/ebasecamp-command.el:537`（派发）** —— `ebasecamp-command--dispatch` 的 `launch` 内构造 args 时追加 `(ebasecamp-project-root object)`。
4. **`lisp/ebasecamp-docker.el:285-289`** —— `ebasecamp-docker-check-compose` 新增 `&optional root`，命令行改为
   `(append (list "compose" "-f" (expand-file-name file)) (when root (list "--project-directory" (expand-file-name root))) (list "config" "-q"))`。

- **shared 取 root 的代码位置**：`--preflight`（`:430`）与 `--dispatch` 的 `launch`（`:537`）都读同一个 `object` —— 即 `ebasecamp-command-run` 里
  `(ebasecamp-command--project project)` 得到的**触发本次操作的项目**，shared 分支由该 `object` 传入 preflight / dispatch，**未**从 shared 配置的 `:project` 反推。
- **预校验与派发同基准**：两处都取 `(ebasecamp-project-root object)`，同一对象、同一次 `run` 调用内取值（root 为 nil 时两处都退回「compose 文件所在目录」基准，不会一半带 flag 一半不带）。
- **root 绝对化**：两处都用 `expand-file-name`（`compose-args` / `check-compose` 各自展开），相对 root 不会原样进命令行。
- docstring 同步：`compose-args` 写明「flag 是根级、必须在子命令之前」与 nil 回退语义；`check-compose` 写明「必须与 `ebasecamp-command-compose-args` 同基准，否则校验过、启动炸」；`--preflight` / `--dispatch` 各补一段 root 来源说明。
- **未改动的文件**：`lisp/ebasecamp-compose.el`（渲染层保持相对路径原样，不变量 6）、`lisp/ebasecamp-export.el`、`lisp/ebasecamp-import.el`（导入读用户自身 compose 文件，基准本就正确；导出记 tech-debt）。
- **测试脚手架适配（唯一非新增改动）**：`test/ebasecamp-command-tests.el` 中 12 处 `ebasecamp-docker-check-compose` 的 `cl-letf` 替身由 `(lambda (_file) …)` / `(lambda (file) …)` 改为 `&rest _` 形式——`--preflight` 现在恒传两参（root 可为 nil），单参替身会 `wrong-number-of-arguments`。替身行为不变，既有断言零改动。

### 用例分摊（6 项，与 424 口径一致）

- `test/ebasecamp-command-tests.el` 新增 **5** 项：`…-compose-args-root-start` / `-stop` / `-restart` / `-down`（4 个动作各一根 deftest，每个**内含两条 should**：带 root 的整条序列位置断言 + 不带 root 与历史序列 `equal`）、`…-compose-args-root-expanded`（root 经 `expand-file-name` 绝对化，并逐位校验 index 3 = flag、4 = 绝对化 root）。
- `test/ebasecamp-docker-tests.el` 新增 **1** 项：`…-check-compose-project-directory`（打桩 `ebasecamp-docker--run-sync-function` 捕获 args，断言 `("compose" "-f" <abs-file> "--project-directory" <abs-root> "config" "-q")`；第二条 should 断言不传 root 时为 `("compose" "-f" <abs-file> "config" "-q")`）。

### 红灯证据（实现前）

```
Ran 424 tests, 418 results as expected, 6 unexpected
6 unexpected results:
   FAILED  ebasecamp-command-test-compose-args-root-down
   FAILED  ebasecamp-command-test-compose-args-root-expanded
   FAILED  ebasecamp-command-test-compose-args-root-restart
   FAILED  ebasecamp-command-test-compose-args-root-start
   FAILED  ebasecamp-command-test-compose-args-root-stop
   FAILED  ebasecamp-docker-test-check-compose-project-directory
```

既有 418 项**零回归**（红灯总额 6 = 新增数，符合任务 2.1 验收）。

### 绿灯证据（`make check`，2026-10-24）

- `make check-parens` → `check-parens OK (26 files)`，exit 0
- `make compile` → exit 0，零 `Warning` / `Error` 行（`byte-compile-error-on-warn` 生效）
- `make test` → `Ran 424 tests, 424 results as expected, 0 unexpected`

### 与计划的偏差

- **无功能偏差**：三处插入点、flag 位置、nil 回退语义、shared 取 root 的做法均与计划任务 2.2 / 「### B-I」小节一致。
- **测试文件有 12 处非新增改动**（见上「测试脚手架适配」）：计划未预见「`--preflight` 恒传两参会让既有单参替身报 arity 错」。选择改替身（而非在生产代码里按 root 是否为 nil 分两支调用）是为了让生产代码只有一条调用路径、基准不可能分叉。
- **既有 418 项零回归**：`run-args-per-branch` / `run-checks-shared-and-project` 等断言的测试项目均无 `:root`（`ebasecamp-define-project myapp :groups …`），root 为 nil → `compose-args` 序列与历史逐字节一致，故无需改动。
- **未覆盖点**：`--preflight` / `--dispatch` 层「真的把 root 传到下游」没有专门的单测（任务 2.1 只要求 `compose-args` 与 `check-compose` 两层）；该链路由批次 5.1 真实 docker 闭环目检（`docker compose config --format json` 看 `configs.<n>.file` 解析值）兜底。

## 批次 3 记录

（执行 2026-10-24。批次 3 = B-II：预校验顶层 configs / secrets 的 `file:` 存在性 + warning 透传。）

### 用例分摊（4 项，与 428 口径一致）

`test/ebasecamp-command-tests.el` 新增一节 `;;; 批次 3（B-II）预校验：顶层 configs / secrets 的 file 存在性`，含 2 个脚手架 + 4 个 deftest：

- `ebasecamp-command-test--file-config-project (root &optional file-configs)` —— 构造带 `:file-configs` 的项目；**`ebasecamp-define-project` 是宏（ARGS 整体被 quote、表达式不求值）**，root 为运行时值时须直接调 `ebasecamp-model--register-project` 传入求值后的 plist（先例：`test/ebasecamp-export-tests.el:91`）。
- `ebasecamp-command-test--with-root` —— 每次用例一个临时目录（带尾斜杠），结束时递归删除。
- ①`…-run-aborts-on-missing-top-level-file`：`:root` 指向不存在的目录 → `run` 返回 nil、`:results` 首个分支 `:failed t` / `:exit` nil / `:stderr` 含「顶层 config」「app_cfg」「conf/app.conf」「不存在（基准：」与基准路径；**`run-async` / `compose-write` / `check-compose` 三者全零调用**（存在性检查在写盘与 check-compose 之前）。
- ②`…-run-proceeds-when-top-level-file-exists`：`<root>/conf/app.conf` 真实存在 → `check-compose` 1 次、`run-async` 1 次、`:ok t`、`:preflight-warnings` 为 nil。
- ③`…-run-warns-when-root-missing`：`:root` 为 nil + 相对路径 → `:ok t`（不失败）、`:preflight-warnings` 恰 1 条且含「无 :root」「app_cfg」「conf/app.conf」、`:results` 无 `:failed` 分支。
- ④`…-run-skips-declarations-without-file`：`(("cfg1" ("external" . t)) ("cfg2" ("name" . "x")))` → `:ok t`、`:preflight-warnings` 为 nil（无假阳性）。

### 实现要点（落点行号为 2026-10-24 实测，插入后 `test` / `lisp` 行号会随批次 4 变化）

1. **`lisp/ebasecamp-command.el:420` `ebasecamp-command--file-declarations (object)`** —— 遍历 `(ebasecamp-project-file-configs object)` 与 `-file-secrets`，每条取 `(cdr (assoc "file" (cdr entry)))`，非字符串（`external: true` / 只有 `name`）跳过；返回 `(KIND NAME FILE)` 三元组（KIND 为 `"config"` / `"secret"`）。**只取本项目**，shared 分支不查（shared 生成物本就不输出顶层段）。
2. **`lisp/ebasecamp-command.el:439` `ebasecamp-command--missing-file-declarations (object root)`** —— 返回 `(MISSING . WARNINGS)`：绝对路径直接 `file-exists-p`；相对路径 + root 非 nil → `(expand-file-name file root)` 后判断；相对路径 + root 为 nil → **不判断**，产出一条 warning「项目 X 无 :root，无法校验顶层 config `app_cfg' 的 file `./conf/app.conf'」。MISSING 元素是 `(:kind :name :file :base)` plist（`:base` 为实际判定基准，供消息用）。
3. **`lisp/ebasecamp-command.el:468` `…--missing-file-message`** —— 拼「顶层 config `app_cfg' 的 file `./conf/app.conf' 不存在（基准：<绝对路径>）」，多条用换行拼接（`mapconcat`）。
4. **`lisp/ebasecamp-command.el:476` `…--project-branch-index (branches)`** —— 顶层段是**项目级**声明，失败必须落在 per-project 分支上：auto 补齐 shared 时分支顺序是 `(shared project)`，若硬用 index 0 会把错误归到 shared 批次。
5. **`lisp/ebasecamp-command.el:484` `…--preflight`** —— 在 `while` 逐分支循环**之前**取 `root` 与 `declarations`；MISSING 非空 → 直接构造 `(:index <project 分支下标> :result (:scope :exit nil :stderr 消息))` 的 `:failure`（与 `check-compose` 失败**同构**，故 `--preflight-report` / UI 零改动），循环因 `failure` 非 nil 一次都不进（零写盘、零校验）；返回值新增 `:preflight-warnings`（第 `:539` 行成功路径同样带上）。
6. **透传链路（实际字段名 `:preflight-warnings`，刻意不用 `:warnings` —— 后者是 `check-compose` 从 compose stderr 抽的 `level=warning` 行）**：
   - `ebasecamp-command-run` 成功分支（`command.el:729`）把 `(and preflight (plist-get preflight :preflight-warnings))` 作为**第 8 个实参**传给 `--dispatch`；
   - `--dispatch`（`command.el:567-569`）签名加 `&optional preflight-warnings`，`report()`（`:609-611`）把 `(and preflight-warnings (copy-sequence …))` 放进 on-complete plist 的 `:preflight-warnings`（无警告时为 nil）；
   - `ebasecamp-ui--report-result` 成功分支（`ui.el:1250`）在 detail 末尾按计数追加「（N 条预校验警告）」；**失败分支一字未动**。
7. **`--preflight-report` 未改**：它是失败路径专用，成功场景不经过它，warning 不在那里拼装。
8. **未改动的文件**：`lisp/ebasecamp-compose.el`（渲染层不碰路径语义）、`lisp/ebasecamp-docker.el`（文件存在性不是 `config -q` 的职责边界）。

### 红灯证据（实现前）

```
Ran 428 tests, 425 results as expected, 3 unexpected
3 unexpected results:
   FAILED  ebasecamp-command-test-run-aborts-on-missing-top-level-file
   FAILED  ebasecamp-command-test-run-warns-when-root-missing
   FAILED  ebasecamp-docker-test-run-sync-captures-streams
```

- ①的失败形状：`(should-not (ebasecamp-command-run …))` 得 `:value (fake-process)` —— 既有实现完全不查文件，一路派发。
- ③的失败形状：`(should (consp warnings)) :form (consp nil) :value nil` —— 结果 plist 里根本没有 `:preflight-warnings` 键。
- ②④ **天然绿**（既有实现不检查任何文件 → 「存在→放行」「无 `file:`→跳过」本就通过），作回归保护：实现后若被误判为失败会立刻红。
- `ebasecamp-docker-test-run-sync-captures-streams` 为**既有偶发抖动**（同批次复跑即过，与本次改动无关；该用例走真实子进程捕获流，0.003s 级）。

### 绿灯证据（`make check`，2026-10-24）

- `make check-parens` → `check-parens OK (26 files)`，exit 0
- `make compile` → exit 0，零 `Warning` / `Error` 行（`byte-compile-error-on-warn` 生效）
- `make test` → `Ran 428 tests, 428 results as expected, 0 unexpected`
- `make check` 整体 → exit 0（`/tmp/ebc-check.log`，651 行）
- **UI 成功分支的额外冒烟（无单测，见 5.2 技术债条目）**：`emacs -Q --batch -l` 脚本内 `cl-letf` 打桩 `ebasecamp-ui--set-notice` 后直接调 `ebasecamp-ui--report-result`，实测
  `(success "启动完成" "所有批次已执行完成（2 条预校验警告）")` / 无警告时 `"所有批次已执行完成"` / 自动补齐时 `"所有批次已执行完成；已自动启动 shared 服务（1 条预校验警告）"` / 失败分支仍为 `(error "启动失败" "boom")`（未掺警告文本）。
- **auto 补齐 + 缺文件的边界冒烟**：批处理直接调 `--preflight` + `--preflight-report`，分支顺序 `(shared project)`、root 下缺 `conf/app.conf` → `FAILURE-INDEX: 1`（落在 project 分支）、`RESULT-0` 为 `(:scope shared … :skipped t)`、`RESULT-1` 为 `:failed t` 且消息基准为 `<root>/conf/app.conf`、`:order` nil。

### 与计划的偏差

- **红灯数量 3 ≠ 任务 3.1 预估的 4**：②④ 是天然绿（见上），不是漏写 —— 它们的判别力在「实现后不得误报」方向。
- **消息里的引号形态**：计划写「顶层 config \`app_cfg\` 的 file …」，实现用 Emacs 惯用的 `` `app_cfg' ``（开反引号 + 闭单引号），关键词与结构不变；4 条用例均按关键词（`app_cfg` / `conf/app.conf` / `不存在（基准：` / `无 :root`）断言，不绑定引号形态。
- **`--preflight` 提前返回未复用 `check-compose` 的 `:warnings`**：符合计划「warning 集合刻意不叫 `:warnings`」。
- **无既有用例需调整**：`--dispatch` 的新参数是 `&optional` 且位于末尾，`report()` 新增的 `:preflight-warnings` 键既有断言全部按 `plist-get` 取键（无整 plist `equal`），故既有 424 项零回归、无需改断言。
- **未覆盖点**：`:file-secrets` 分支无独立用例（与 configs 同一代码路径），由批次 5.1/5.4 真实场景兜底。

## 批次 4 记录

（执行 2026-10-24。批次 4 = A-II：旧 `:groups` 写盘迁移，**须用户确认、绝不静默**。）

### 用例分摊（8 项，与 436 口径一致）

`test/ebasecamp-config-write-tests.el` 新增一节 `;;; 批次 4（A-II）：旧 :groups 写盘迁移`，含 3 个 fixture 常量 + 2 个 helper + 5 个 deftest：

- 常量：`--legacy-same-file`（`projects/x.el` 含组 db / cache + 项目 demo 的 `:groups ((db) (cache))`）、`--legacy-groups-file`（组 db 在 groups.el、`:configs nil`）、`--legacy-project-file`（项目 demo 的 `:groups ((db))`）；helper：`--write-legacy-across-files` / `--legacy-file-path`。
- ①`-migrate-legacy-within-file`：同文件 → 组侧 `:configs` 出现 cfg、项目侧 `:groups` 变 `((cache))`（另一条原位保留）、两个组定义都还在、重载零错误。
- ②`-migrate-legacy-across-files`：跨文件 → 组文件出现 `(cfg :project demo)`、项目文件**不含** `:groups` 字样、两文件都无 `.ebasecamp-*` 残留。
- ③`-migrate-legacy-rolls-back-first-transaction`：`cl-letf` 把 `ebasecamp-manifest--write-transaction` 换成「第二次调用 signal」的包装（第一次仍调原函数）→ `should-error :type 'error`，随后断言**两个文件都逐字节等于迁移前原文**、无备份残留、重载后组无配置且项目仍有 `:groups ((db))`。
- ④`-migrate-legacy-default-nil-keeps-project-file`：不传第 4 参 → 组文件写入、项目文件 `equal` 调用前（逐字节）。
- ⑤`-migrate-legacy-removes-empty-groups-key`：项目 `:groups ((db))` 只有一条 → 迁移后文本 `(should-not (string-match-p ":groups" text))`、`:root "/tmp/ebc-demo")` 结尾逐字节保留、重载零错误。

`test/ebasecamp-ui-tests.el` 新增一节 `;;; 批次 4（A-II）：旧 :groups 迁移的用户确认`，3 个 deftest（均打桩 `completing-read` / `y-or-n-p` / `--legacy-reference-file` / 写盘入口 / `ebasecamp-reload`）：

- ⑥`-x-new-config-asks-before-migrating-legacy`：查询顺序 `((myapp "mysql"))`（`(项目 组)`）、`y-or-n-p` 恰 1 次、文案含「项目 myapp」「组 mysql」「旧写法 :groups」「接管」「是否同时删掉」、写盘第 4 参非 nil。
- ⑦`-x-new-config-declines-migration`：答 no → 第 4 参 nil、notice 不是 `error`。
- ⑧`-e-editor-asks-before-migrating-legacy`：`E` 同样查询一次、问一次、`-update-config-project` 收到 `("mysql" dev myapp t)`。

**既有用例适配（1 处，arity）**：`ebasecamp-ui-test-x-menu-dispatch` 的 `-add-config` 替身由 `(lambda (group config project) …)` 改为 `&optional _migrate`（新增第 4 参后单 3 参替身会 `wrong-number-of-arguments`）。替身行为与既有断言零改动。

### 实现要点（落点行号为 2026-10-24 实测）

1. **`lisp/ebasecamp-config-write.el:441` `--edit-manifest (file editor &optional keep-backup)`** —— 把 `:keep-backup` 透传给 `ebasecamp-manifest--write-transaction`（`plist-get` 对 nil 等价于不传），因此默认调用点返回值形态与历史完全一致；非 nil 时返回 `(:result … :backup …)` 供跨文件补偿使用。
2. **`lisp/ebasecamp-config-write.el:565` `--head-end (text form)`** —— 通用「跳过 `(car NAME`」定位；`:579` 的 `--group-head-end` 改为委托它（组 form 与项目 form 同一形态，避免两处漂移；`--group-head-end` 的唯一调用方是 `--service-region`，行为零变化）。
3. **`:664` `--project-form-in (forms project)`** —— 单文件内按 `:kind 'project` + `:name` 匹配；**刻意不复用** `ebasecamp-manifest--locate-form`（计划约束 5）。
4. **`:672` `--groups-element-region (text form group)`** —— 两级区域扫描（与 `--service-region` 同模式）：先在 project form 内顺序读关键字/取值取 `:groups` 的值元素，再在其括号内顺序读引用元素、按 `car-safe` 匹配组名。返回 `(:start :end :key-start :key-end :value-end :sole)`（全部 1-based）。
5. **`:713` `--element-removal-bounds` / `:731` `--key-removal-bounds` / `:742` `--removal-form`** —— 约束 4 的落点：`:sole` 为真时删**整个 `:groups` 键**（key-start..value-end，并向前吃掉缩进与行首换行），否则只删元素（优先吃后随空格 → 后随换行 + 下一行缩进 → 前导空格）。`--removal-form` 把 region 的 1-based 位置 `1-` 换算成 0-based 再算边界，返回可直接进 `--replace-forms` 的 `(FORM . "")`。
6. **`:759` `--legacy-reference-file (project-name group-name)`** —— 约束 5 的落点：只扫 `ebasecamp-config--project-files`（字典序），返回 `(FILE . (:start :end :form-start :form-end :sole))`，无命中 nil；多文件命中按加载顺序返回第一个（docstring 写明不裁决重名项目）。
7. **`:794` `--remove-legacy-editor` / `:808` `--migrate-legacy`** —— 单次读写的「只删旧引用」入口（跨文件路径的第二段），内部走 `--edit-manifest` 的一次事务。
8. **`:825` `--migrate-across-files (group-file editor project group)`** —— 约束 2 跨文件路径：第一段 `--edit-manifest … t`（拿备份）→ 第二段 `--migrate-legacy` → 第二段失败时 `--restore-backup`（恢复组文件原文、删备份、重载）并 `signal (car err) (cdr err)`；两段都成功才删备份。新增配置与改 `:project` 共用本函数（只换 editor）。
9. **`:848` `--add-config-editor` / `:864` `--add-config-within-file-editor`** —— 约束 2 同文件路径：后者在**一份**全文上用 `--replace-forms` 做两处替换（组侧 `--render-group` + 项目侧 `--removal-form`），按 `:start` 降序应用 ⇒ 一次写盘、无中间态。
10. **`:892` `--update-config-project-editor` / `:919` `--update-config-project-within-file-editor`** —— 同一套分派；`:project` 与原值相同时组侧返回原文（不重渲染），但仍删项目侧旧引用。
11. **`:960` `ebasecamp-config-write-add-config (… &optional migrate-legacy)` / `:1008` `ebasecamp-config-write-update-config-project (… &optional migrate-legacy)`** —— **分派点**：`(null reference)` → 原单事务路径（逐字节不变）→ `(equal (expand-file-name (car reference)) group-file)` → 同文件一次事务 → 否则跨文件两段 + 补偿。`migrate-legacy` 默认 nil 时 `reference` 恒 nil，因此 `--legacy-reference-file` 连一次都不跑。
12. **`lisp/ebasecamp-ui.el:2049` `--legacy-reference-p` / `:2055` `--confirm-legacy-migration`** —— UI 确认落点：命中才 `y-or-n-p`（经 `--call-with-input` 适配事件上下文 / M-x / ERT 三态），文案照抄计划「项目 %s 的旧写法 :groups 仍引用组 %s；%s该旧引用将被组侧配置接管。是否同时删掉这条旧引用？」（ACTION = 「新建配置后」/「改配置后」）；答 yes 返回 t、答 no 返回 nil、未命中返回 nil。
13. **UI 接入**：`--manifest-menu` 的「新建配置」分支（`ui.el:2202` 起）与 `--open-config-editor`（`ui.el:2104` 起）把 `--confirm-legacy-migration` 的返回值作为写盘入口的第 4 参 —— **这是唯一能传 t 的地方**（脚本 / 测试调用默认 nil）。
14. **未改动**：`ebasecamp-config-write-move-config`（`M'` 首版不迁移，计划明确）、`lisp/ebasecamp-manifest.el`（写盘内核无需新能力）、`lisp/ebasecamp-compose.el`。

### 红灯证据（实现前）

```
Ran 436 tests, 429 results as expected, 7 unexpected
7 unexpected results:
   FAILED  ebasecamp-config-write-test-migrate-legacy-across-files
   FAILED  ebasecamp-config-write-test-migrate-legacy-removes-empty-groups-key
   FAILED  ebasecamp-config-write-test-migrate-legacy-rolls-back-first-transaction
   FAILED  ebasecamp-config-write-test-migrate-legacy-within-file
   FAILED  ebasecamp-ui-test-e-editor-asks-before-migrating-legacy
   FAILED  ebasecamp-ui-test-x-new-config-asks-before-migrating-legacy
   FAILED  ebasecamp-ui-test-x-new-config-declines-migration
```

- ④`-migrate-legacy-default-nil-keeps-project-file` 为**天然绿**：默认 nil 时走既有单事务路径（只写组文件），项目文件本就不动 → 它的判别力在「实现后不得误改项目文件」方向。
- 既有 428 项零回归（`ebasecamp-docker-test-run-sync-captures-streams` 本批次两次全量跑都未抖动）。

### 绿灯证据（`make check`，2026-10-24）

- `make check-parens` → `check-parens OK (26 files)`，exit 0
- `make compile` → exit 0，零 `Warning` / `Error` 行（`byte-compile-error-on-warn` 生效；日志里 48 行 `Warning (files): Missing ‘lexical-binding’ cookie` 全部指向 `/tmp` 下的**测试临时清单文件**，属既有运行时 load 噪音，与编译无关）
- `make test` → `Ran 436 tests, 436 results as expected, 0 unexpected`
- `make check` 整体 → exit 0（`/tmp/ebc-check-b4b.log`，658 行）

### L3 附加探针（`/tmp`，不进仓库）

- **`/tmp/ebc-probe-1.el`**（实现调试用）：打印同文件场景的扫描位置与删除区间，确认 region `(:start 411 :end 415)` → 删除 `[410,415)`（`(db) ` 含尾随空格）。
- **`/tmp/ebc-probe-2.el`**（真实示例清单副本，P1 形态：组 mysql shared / redis per-project 均无 `:configs`、项目 example 用 `:groups ((mysql) (redis))`）→ `add-config "redis" "cache" 'example t`：
  - `BEFORE-ERRORS: nil` / `AFTER-ERRORS: nil`；`REDIS-CONFIGS: (cache)`；`EXAMPLE-GROUPS: (mysql redis)`（redis 的引用由组侧配置物化接管，顺序不变）
  - `diff -u` 项目文件：**仅** `-  :groups ((mysql) (redis)))` / `+  :groups ((mysql)))` 一行变化 —— 注释、`:title "示例项目"`、`:root "~/Workspace/example"`（未展开的相对路径）逐字节保留
  - `diff -u` 组文件：`:services` 与 `:configs` 按组 form 内部规范化重渲染（既有 W3 行为），`:configs ((cache :project example))`
  - `LEFTOVERS: nil`
- **`/tmp/ebc-probe-3.el`**（`-update-config-project` 两条路径冒烟）：跨文件 → 项目文件 `:groups` 整键消失、配置 `:project` 改到 demo、零错误、无备份残留；同文件且 `:project` 未变 → 组 form **逐字节不变**（不重渲染）、项目 `:groups` 整键消失、零错误。

### 与计划的偏差

- **红灯数量 7 ≠ 任务 4.1 预估的 8**：④是天然绿（见上），不是漏写。
- **UI 测试打桩 `--legacy-reference-file`**：UI 测试的清单是内存定义（`ebasecamp-define-group'/`-project'`），磁盘上没有 `projects/*.el`，真实现必然返回 nil。打桩是为了让 UI 的「命中 → 确认 → 传参」逻辑本身可测（顺带断言查询参数顺序为 `(项目 组)`）；`--legacy-reference-file` 的真实行为由 ①–⑤ 的文件级用例覆盖。
- **新增 2 个内部函数名与计划措辞的差异**：计划写「`--legacy-reference-file` / `--migrate-legacy`」两个内部助手，实现时按「两条编排路径不合并」的要求额外抽出 `--add-config-editor`（原 `add-config` 的内联 editor）、`--add-config-within-file-editor`、`--update-config-project-editor`、`--update-config-project-within-file-editor` 与共用的 `--migrate-across-files`。`add-config` / `update-config-project` 的**公开签名与返回值语义不变**（只多一个默认 nil 的可选参数）。
- **同文件路径「`:project` 未变」的处理**：`-update-config-project-within-file-editor` 在 `:project` 与原值相同时不重渲染组 form（保持既有「无改动不写盘」语义），但仍执行项目侧删除 —— 用户确认了迁移就该清掉旧引用。
- **未覆盖点**：`-update-config-project` 的 `migrate-legacy` 写盘逻辑**无 ERT 用例**（计划 4.1 只列了 `add-config` 的 5 项），只由 L3 探针 3 的两条路径手工覆盖；建议在 5.2 的技术债条目里一并记「`E` 入口的迁移只由单测打桩覆盖」。`--legacy-reference-file` 的多文件命中分支（同项目重名定义）无专门用例（该形态本身是加载错误）。

## 批次 5 记录

### 5.1 真实 docker 闭环（2026-10-24 执行，PASS；仓库源文件零改动）

探针环境：`/tmp/ebc-v052-5/`，两个安全闸 `ebasecamp-config-directory` = `/tmp/ebc-v052-5/cfg/`、`ebasecamp-cache-directory` = `/tmp/ebc-v052-5/cache/`（现网 `~/.config/ebasecamp/` 经 `diff -r` 复核逐字节未变）。`orig/` = P1 形态原样副本；`cfg/` = 派生副本（`example` 的 `:root` → `/tmp/ebc-v052-5/project`、加 `:file-configs (("app_cfg" ("file" . "./conf/app.conf")))`、`:groups` 保留旧写法 `((mysql) (redis))`；`redis` 服务加 `:extra (("configs" . ("app_cfg")))` 让顶层声明被真实服务引用）。项目根文件 `/tmp/ebc-v052-5/project/conf/app.conf`。

**V1 迁移闭环（A-II，PASS）** — `/tmp/ebc-v052-5/v1-migrate.el`
- `(ebasecamp-config-write-add-config "redis" "probe" 'example t)` → 返回加载结果 plist、`:errors nil`；`(ebasecamp-group-configs (ebasecamp-model-group 'redis))` = `(probe)`；项目引用 `((mysql) (redis :scope per-project))`，redis 仍在第 2 位（原位接管）。
- `diff -u orig/projects/example.el cfg/projects/example.el`：仅 `:groups` 的 `(redis)` 元素被删（剩 `((mysql))`）；`diff -u` 组文件：追加 `:configs ((probe :project example))`，`:extra` 保留。
- 重载 `(ebasecamp-config-load)` → `errors=0`；`V1-LEFTOVERS: nil`（无 `.ebasecamp-*` 备份残留）。

**V2 `--project-directory` 生效（B-I，PASS）** — `v2-compose.el` + docker CLI
- `(ebasecamp-compose-write (ebasecamp-model-project 'example))` → `/tmp/ebc-v052-5/cache/example/compose.yaml`（含 `configs:\n  app_cfg:\n    file: ./conf/app.conf` 与 redis 的 `configs: - app_cfg`）。
- `docker compose -f …/cache/example/compose.yaml --project-directory /tmp/ebc-v052-5/project config --format json` → `configs.app_cfg.file = /tmp/ebc-v052-5/project/conf/app.conf`（exit 0）。
- 对照（不带 flag）→ `…/cache/example/conf/app.conf`（不存在）；两者 `config -q` 均 exit 0 → 复现探针 T2「`config -q` 不校验 configs/secrets 的 file」。

**V3 预校验拦截缺失文件（B-II，PASS）** — `v3-preflight-abort.el`（打桩计数）+ `v3b-realchain.el`（不打桩的真实链路）
- 删 `project/conf/app.conf` 后 `(ebasecamp-command-run 'start …)` → 返回 nil、`:ok nil`；project 分支 `:failed t` / `:exit nil`，stderr = ``顶层 config `app_cfg' 的 file `./conf/app.conf' 不存在（基准：/tmp/ebc-v052-5/project/conf/app.conf）``；shared 分支 `:skipped t`。
- 打桩计数 `run-async` 0 / `run-sync` 0 / `check-compose` 0；真实链路同场景 `sync` 0、`compose config` 0（连 `network inspect` 都未执行 → 文件检查在 write/check/ensure-network 之前）。
- `docker ps -a --filter label=com.docker.compose.project=ebc-example` 计数 0。

**V4 恢复后放行（B-I + B-II 全链路，PASS）** — `v4-dispatch.el`
- 放回文件后重跑：`check-compose` 的 `compose … config -q` 与 `network inspect ebasecamp` **真实执行**（只读），`network create` 被桩拦截（实测 0 次，因 network 已存在）；`run-async` 打桩仅记录参数。
- `on-complete` `:ok t`、无 `:failed`、`:preflight-warnings nil`，`run` 返回 2 个进程。
- 派发 args（两分支都带 flag，位置 `-f FILE` 之后、子命令之前）：`("compose" "-f" "/tmp/ebc-v052-5/cache/example/compose.yaml" "--project-directory" "/tmp/ebc-v052-5/project" "-p" "ebc-example" "up" "-d" "redis")`；shared 分支 `… "/cache/_shared/compose.yaml" "--project-directory" "/tmp/ebc-v052-5/project" "-p" "ebc-shared" "up" "-d" "mysql"`（shared 用**触发项目的 root**）。

**收尾与残留**：`docker ps -a`（`com.docker.compose.project=ebc-example`）0 / `ebasecamp.managed=true` 卷 0 / `docker network ls` 无新增；全程未执行 `create` / `up` / `down`。`make check` → `Ran 436 tests, 436 results as expected, 0 unexpected`、exit 0（基线未变）。

**与预期的偏差（如实记录）**
- 任务书的 `docker ps -a --filter label=ebasecamp.project=example` 实测为 **1** 而非 0：它是**探针前既存**的 `ebc-shared-mysql-1`（`docker inspect` → Created `2026-10-23T18:09:41Z`、`exited`，来源 `…/.local/cache/ebasecamp/_shared/compose.yaml`，该目录已不存在），与本次探针无关；按探针归属（`com.docker.compose.project=ebc-example`）计数为 0。
- 首版 V3 脚本漏调 `ebasecamp-config-load`（模型注册表空 → `wrong-type-argument ebasecamp-project nil`），补加载后通过——脚本问题，非代码缺陷。
- V1 删除后项目文件留 `:groups ((mysql))` 的缩进略偏（合法；`:groups` 键保留是因为 mysql 引用仍在，符合「只删该组元素」设计）。

### 5.2 文档批次（2026-10-24 执行，拆 4 个子批次 a–d）

子批次编号由执行侧编排，本记录按**文件职责**归组（a = 冻结层与决策，b = 用户与发布向文档，c = 缺口补齐，d = 过时表述清理与收口）。

**5.2a 冻结层与决策**（`AGENTS.md` + `docs/adr/0007-legacy-groups-and-project-directory.org` + `openspec/decisions.md`）
- `AGENTS.md`：复核不变量 9（1.2 已改口径）；新增不变量 15「生成物派发与预校验必须同用 `--project-directory <项目 root>`，且 flag 位于 `-f FILE` 之后、子命令之前」；「已知特性」补一行「派发时 docker 会额外读取 `<项目 root>/.env`」（附带成因与判别口诀）；当前状态与测试基线更新到 436。
- `docs/adr/0007-legacy-groups-and-project-directory.org`（新增，170 行）：决策 1 旧 `:groups` 原位接管（双簿记 `sources` / `legacy`，判据只认 `legacy`）、决策 2 `--project-directory` 统一路径基准（含 shared 取触发项目 root）、决策 3 预校验顶层 `configs`/`secrets` 文件存在性 + `:preflight-warnings` 透传；含否决项、`.env` 副作用、跨文件迁移「两次事务 + 备份补偿 = 部分退化」表述、不变量 9 修订依据、探针 T2–T7b 与补证 1–6。
- `openspec/decisions.md`：追加 3 条决策行（A-I 接管 / B-I 基准 / B-II 预校验）+ 1 条「修订不变量 9」行。

**5.2b 用户向与发布向文档**（`Readme.org` + `docs/user-guide.org` + `CHANGELOG.md` + `openspec/tech-debt.md`）
- `Readme.org`（+68/−3）：旧写法原位接管、新建配置时的迁移确认、路径基准与 `.env` 行为。
- `docs/user-guide.org`（+66）：同上用户视角（含 `--project-directory` 与 `.env` 说明）。
- `CHANGELOG.md`：`## [0.5.2] - 2026-10-24`；`Version: 0.5.2` 落到 13 个文件（`ebasecamp.el` + `lisp/*.el`）。
- `openspec/tech-debt.md`：新增 #35–#40（导出路径基准 / 相对 `volumes` source 未检查 / `-move-config` 不迁移 / A-II 测试覆盖不均 / `--legacy-reference-file` 多文件命中无用例 / 预校验警告展示无单测），并为 #20 补 2026-10-24 抖动实证。

**5.2c 补文档缺口 + 两处 docstring**（3 份 org + `lisp/ebasecamp-config-write.el` + `lisp/ebasecamp-command.el`）
- `docs/architecture.org`：不变量表第 12 条改准（写入口 = 界面表单 `S`/`E`/`M`/`X` 或 `e` 打开的**组定义实际所在**文件；跨文件定位 + 三档降级），表前出处句补「第 12 条由 v0.5.2 修订」。
- `docs/troubleshooting.org`：新增 3 节 —— 14 启动前预校验报「顶层 config 的 file 不存在」（含 `config -q` 恒 exit 0 / `up --dry-run` 测不出的对照表与判据）、15「（N 条预校验警告）」、16「重复引用组」只剩「两份以上组侧配置」一种成因。
- `docs/compose-generation.org`：新增顶层节「生成物的路径基准（`--project-directory`）」与子节「顶层 `configs` / `secrets`」；`** 输出结构` 段序补 `configs:` → `secrets:`；「bind 卷」一条措辞改准。
- docstring（**行为不变**）：`--legacy-reference-file` 的多文件命中顺序由「按 `ebasecamp-config--files` 的顺序」改为「按 `ebasecamp-config--project-files` 的字典序」——判断为**实现对、docstring 是笔误**（计划与实现都只扫 `projects/*.el`）；`ebasecamp-command-run` 的 on-complete 字段清单补 `:preflight-warnings`，并补一句「无法判定」警告不影响派发、透传到 on-complete plist。
- 首次 `make compile` 因「docstring wider than 80 characters」失败 1 次（新增行按 CJK 显示宽度超限，`byte-compile-error-on-warn` 生效），按 80 列重排后转绿。

**5.2d 清过时表述 + 收口**（同上 3 份 org + 本计划文件）
- `docs/architecture.org`：「编辑入口边界」第 2 条改写为 v0.5.1+ 实际语义（先 `--manifest-file-for-group` 跨文件定位，再在**该文件**里定位 `(ebasecamp-define-group <组名>`，三档降级）；文首版本标注「HEAD，v0.2 批次 C6 完成态」→「v0.5.2」。
- `docs/troubleshooting.org`：§2 修法改为「旧 `:groups` 与组侧配置共存**不再报错**（原位接管），只有两份以上组侧配置才报 `ebasecamp-config-duplicate-group-ref`」；§3「补充第 2 类」只留「两份以上组侧配置」成因，对应修法拆成两条（旧写法重复元素 / 多余配置）；§11 修法改为「`e` 打开**组定义所在的清单文件**」；§6 `env file … not found` 行补「导出/直接跑项目自身 compose vs 启动前预校验」两个基准。
- `docs/compose-generation.org`：文首版本标注 →「v0.5.2」。
- 计划文件本身：勾选 5.2；修复两处**既存的编辑损坏**（`## 批次 4 记录` 标题被吞进 5.1 验收行、`## 批次 5 记录」` 多出一个带 `」` 的重复标题、任务 5.2–5.4 被夹在批次记录之间），已恢复标题并把 5.2–5.4 移回「## 任务」节。

**`make check`（全批次终态，2026-10-24）**：`check-parens OK (26 files)` / `make compile` 零 warning（48 行 `Missing ‘lexical-binding’ cookie` 全指向 `/tmp` 下测试临时清单，属既有 load 噪音）/ `make test` **436 expected / 0 unexpected**；`make check` exit 0。org-lint（`emacs -Q --batch` + `(require 'org-lint nil t)`）：`architecture.org` 0、`troubleshooting.org` 0、`compose-generation.org` 3（**等于基线 3**，全部既有的 2×`yaml` 语言未注册 + 1×列表计数器）。

**教训（计划的「文档清单」漏项）**：本计划「## 文档清单」只列了 `AGENTS.md` / ADR-0007 / `decisions.md` / `Readme.org` / `user-guide.org` / `architecture.org` / `CHANGELOG.md` / `tech-debt.md`，**漏掉 `docs/compose-generation.org` 与 `docs/troubleshooting.org`** —— 前者承载渲染规则（本版本的路径基准、顶层 `configs`/`secrets` 都在这里），后者承载按症状排障（本版本新增 3 个失败模式）。两者最终由 5.2c 执行时「核对 Readme 文档索引 + 反查新增失败模式有无落点」才发现并补上。**做法修正**：计划阶段的文档清单不能只列「以往常改的那几份」，要按「本版本新增/改变的机制」逐条反查落点文档（渲染规则 → compose-generation；新失败模式 → troubleshooting；新不变量 → AGENTS + architecture）。

### 5.3 归档 v0.5.1 计划（2026-10-24 执行）

**归档动作**：`openspec/active/2026-10-23-manifest-locate-compose-configs.md` → `openspec/completed/2026-10-23-manifest-locate-compose-configs.md`（普通 `mv`；本批次禁止 git 写操作，故 git 侧呈现为 `D openspec/active/…` + `?? openspec/completed/…`，未自动识别为 rename）。

**归档文件的结论表述**（其「## 当前状态」整体改写为归档态，任务行只勾选 + 行尾追加）：
- 阶段「**已归档**（2026-10-24 移入 completed/）」；已确认「方案 ✅ + 计划 ✅（用户 2026-10-23）」。
- 结果：X0–X4.5 全部完成；**X4.6 用户目检未能按原计划执行**——现网清单实为 `create-sample-config` 示例清单，无 `datarush-go` 项目，诊断副本 `/tmp/ebc-diag` 已不存在；改以等价链路验证替代（写盘跨文件定位 / 预校验拒绝不合法生成物 / 重新导入修复往返 三链路在 `/tmp` 副本 + 真实 docker CLI 上 PASS，证据见本计划「探针记录」与「批次 5 记录」）。
- 视觉目检项并入本计划 5.4；「后续」指向本计划（承接 v0.5.1 暴露的两个新阻断缺陷）。
- `X4.6` 任务行由未勾选改为已勾选，**描述原文一字未改**，仅行尾追加「（2026-10-24 归档结论：现网无该清单，改以等价链路验证 PASS；视觉项并入 v0.5.2 5.4）」。

**`AGENTS.md` 同步点**（只改「## 当前状态」节）：
1. 「进行中计划」只留 v0.5.2，状态写「批次 1–5.3 已落地，**待 5.4 用户目检**」，并注明 `openspec/active/` 现只剩本计划；删除「v0.5.1 待 X4.6 目检」「批次 5.3 归档随后执行」等已成过去式的表述。
2. 「已归档」新增 v0.5.1（与 v0.2 / v0.3 / v0.4 / v0.5 / `ebasecamp-m1-m3.md` 并列），注明 2026-10-24 归档、X4.6 以等价链路验证替代 PASS、视觉项并入 v0.5.2 5.4。
3. 「测试基线」保持 **436**（415 → 418 → 424 → 428 → 436 的分解未变；本批次只改 markdown）。
4. 「下一步」改为「v0.5.2 5.4 用户目检（4 项）→ v0.5.3（project `:root` 可选）→ v0.6」，四项与任务 5.4 逐条一致。

**验证（2026-10-24 实测）**：`ls openspec/active/` 剩 1 个文件；`ls openspec/completed/` 6 个 `.md`（含 `ebasecamp-m1-m3.md`）；归档文件 `grep -c '^- \[ \]'` = **0**；`make check` → `check-parens OK (26 files)` / `make compile` 零 warning / `make test` **436 expected / 0 unexpected**。

### 5.4 用户目检（2026-10-24 执行，PASS）

用户在**真实 Emacs 环境**中按任务书逐项执行，4 项全部通过：

1. **①迁移确认 yes**：示例清单上 `X` → 新建配置关联 `example`，弹确认后选 yes → 新建成功；`projects/example.el` 里对应组的旧 `:groups` 引用被清掉。
2. **②迁移确认 no**：再新建一次配置选 no → 仍成功，且不再重复提示（旧引用已在①被清）。
3. **③启动**：`s` 启动成功。
4. **④缺文件拦截**：删掉一个 config 文件后再 `s` → 给出可读错误且不启动（B-II 预校验在真实界面链路上生效）。

至此 v0.5.2 全部批次（1 → 5.4）完成，计划归档至 `openspec/completed/`。
