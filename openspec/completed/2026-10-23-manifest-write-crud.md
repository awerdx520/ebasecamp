# ebasecamp v0.5 — 清单写操作（编辑 container 配置 / 移动配置 / CRUD）

## 当前状态

- 已归档（2026-10-23）：W5.8 目检发现的两处阻断缺陷（写盘固定 groups.el、compose 顶层 configs 丢失）由 v0.5.1 承接修复；W0–W5.7 全部完成。
- 阶段：**批次 W5 文档完成（待 W5.8 目检）**（W0 探针 + W1 manifest 内核 + W2 字段映射 + W3.1–W3.4 实体操作 + W4.1/W4.2 UI 表单与键位 + **W5.1–W5.7 文档与版本号**已落地；剩 W5.8 用户目检）
- 已确认：方案 ✅（用户 2026-10-23 选择「按推荐范围」：服务 6 字段 + 配置 CRUD 与移动 + 项目 CRUD + 组 CRUD；不做服务增删改名）
- 已确认：计划 ✅（已通过独立审查；Phase 3 按批次 W0 → W5 执行）
- 已落地：W0 探针 3 项；W1 内核——`lisp/ebasecamp-manifest.el`（扫描 / 定位 / 替换 / 追加 / 删除 / 生成器 / 写盘事务 / 新文件写入）+ `ebasecamp-config-error-messages` + import 三个生成器改 thin wrapper；W2 字段映射——`lisp/ebasecamp-config-write.el`（ports / environment / volumes / command / restart / image 六字段双向纯函数，解析失败 `user-error` 带行号）；**W3.1/W3.2 实体操作——`-update-service-fields` / `-add-config` / `-update-config-project` / `-remove-config` / `-move-config`，manifest 侧新增 `--scan-text-forms` / `--scan-forms-in-region` / `--replace-forms` / `group-form-from-plist` / `config-form`**；**W3.3/W3.4 项目与组 CRUD——`-add-project` / `-update-project` / `-remove-project` / `-add-group` / `-update-group` / `-remove-group`，manifest 侧新增 `--write-new-file`，config-write 侧新增 `--replace-group`（修 W3.2 整文件覆盖缺陷）、`--delete-file-transaction`、`--config-references` / `--legacy-group-references` 两处引用扫描**；**W4.1/W4.2 UI 表单与键位——`lisp/ebasecamp-ui.el` 新增服务编辑 dialog（6 字段 ref + error ref + 保存/取消）、配置编辑与移动（`completing-read` 选项目/组）、`X` 清单操作菜单（8 项 dispatch）、root keys 12 → 16（`S`/`E`/`M`/`X`）**
- 已落地（W5）：**W5.1–W5.7 文档与版本号**——`Readme.org`（两节 + 键位 4 行 + 事务说明）、`docs/user-guide.org`（在界面里改配置）、`docs/architecture.org`（清单写盘 74 行 + API 表 + 入口边界改写）、`docs/adr/0005-manifest-write.org`（新 ADR，85 行）+ ADR-0003 superseded 注记 + `openspec/decisions.md` 修订行、`CHANGELOG.md` 0.5.0、13 个 `;; Version:` 全部 0.5.0、`AGENTS.md` 不变量 12 改写 + 14 新增 + 基线 392、`openspec/tech-debt.md` #26 关闭 + #31 新增
- 测试基线：**392**（W4 新增 6 项用例 + 同步 3 条既有键位测试；W5 仅文档与版本号，用例数不变；`make check` 全绿：`make test` 392 expected / 0 unexpected、`compile` 零 warning、`check-parens` 26 文件通过）
- 下一步：**W5.8 用户目检**（6 项：改端口 → `docker compose config -q`；配置增删；移动配置；项目 CRUD；删组看影响提示；恶意输入被拦）；通过后归档本计划到 `openspec/completed/`
- W4 执行中触发 step-limit，收尾由后续任务补完；实现与测试均已全绿
- 前置：v0.2 / v0.3 / v0.4 已完成并归档；工作区基线提交 `5a6afd1`
- 回滚点：新增 `lisp/ebasecamp-manifest.el`、`lisp/ebasecamp-config-write.el`（W3）与 UI 表单（W4）；不触碰 compose 渲染 / docker / command 层
- 执行要求：每批次前建 git 安全点（`git status --porcelain` + 备份涉及文件到 `/tmp/ebc-uibak-<ts>/`）；失败先回滚再报告

## 目标

1. **写盘内核**：在 `groups.el` / `projects/*.el` 里按实体（组 / 配置 / 项目 / 服务）做**局部**修改并写回——定位 form、替换/追加/删除、写后校验、失败回滚、外部修改检测。
2. **编辑 container 配置**：界面内表单编辑服务的 `image` / `ports` / `environment` / `volumes` / `command` / `restart`，其余字段原样保留。
3. **配置操作**：新增（选项目）、改 `:project`、删除、移动到其他组的其他 project。
4. **项目 / 组 CRUD**：新增、改、删除，带引用完整性与影响提示。

## 非目标

- 服务增删与改名（既有容器会变孤儿；需先有配置维度，见 tech-debt #16 / #25）
- `healthcheck` / `labels` / `networks` / `extra` / `entrypoint` / `working-dir` / `user` / `depends-on` 的表单编辑（写回时原样保留）
- 配置 `:services` 覆盖的表单编辑（第一版只读展示）
- 界面内自由编辑 Elisp（继续用 `e` 打开文件）
- 写回项目 compose（AGENTS 禁止）
- 删除组/项目时自动清理容器（只删清单 + 提示）

## 现状与根因

| 现象 | 根因 |
|---|---|
| 界面上只能启停，不能改配置 | 写路径只有「手工编辑文件」与「一次性导入（整份生成）」；没有「按实体局部修改」的能力（`ebasecamp-import-apply` 只写整份新文件） |
| 想改一个容器端口必须离开界面 | 服务字段 ↔ 表单值的映射不存在；`--service-form` 只用于导入落盘 |
| 新增/删除配置、项目、组全靠手写 Elisp | 无 form 定位/替换内核，也无引用完整性检查（删除项目后被配置引用会加载报错） |

已核实的可复用资产（不要重复造）：

- `lisp/ebasecamp-import.el`：`--service-form`（`538`）、`--group-form`（`553`）、`--project-form`（`577`）、`--manifest-content`（`587`）、`--read-forms`（`604`）、`--restore-file`（`627`）、`--literal`（`512`）——文本生成与写后校验/回滚模式已存在。
- `lisp/ebasecamp-model.el`：服务 plist 键为 `:image :command :entrypoint :environment :labels :ports :volumes :healthcheck :depends-on :networks :working-dir :user :restart :extra`；端口为 `((HOST . CONTAINER))`、environment 为 `(("K" . "V"))`、volumes 为字符串列表或对象；`:configs` 元素为 `(配置名 . plist)`（`:project` 必填、`:services` 覆盖可选）。
- `lisp/ebasecamp-config.el`：`ebasecamp-config-load`（校验入口）、`ebasecamp-config-project-file`、`ebasecamp-config-directory`。
- etaf 表单能力（已实测核实）：`etaf-dialog` + `etaf-text-input`（`:rows` 多行**保留换行**，`rows>1` 时 RET 不提交、`C-c C-c` 提交）+ `etaf-select` + `etaf-button`；**无**字段级 `:error` 属性（用 `etaf-label :variant 'danger` 自实现）；按钮回调内可同步写盘与 `config-load`，重活需 `etaf-next-tick`；dialog 不能同步返回用户输入。
- 本仓库既有 `ebasecamp-ui-confirm-dialog`（`lisp/ebasecamp-ui.el:1372`）可作 dialog 模板。

## 设计决策

- **M1 新模块 `ebasecamp-manifest.el`**（纯文本层，无 UI 依赖）：承载 `-service-form` / `-group-form` / `-project-form` / `-list-forms` / `-locate-form` / `-replace-form` / `-append-form` / `-remove-form` / `-write-transaction`。`ebasecamp-import.el` 的三个私有生成器改为 thin wrapper 调用它（保持原签名与行为，测试不变），避免两处格式漂移。
- **M2 form 定位（复用既有扫描方式，不自己写扫描器）**：新增 `ebasecamp-manifest--scan-forms`（**不改** `ebasecamp-import--read-forms` 的返回值形状，避免波及 import 侧调用点）：`(with-syntax-table emacs-lisp-mode-syntax-table (forward-comment (point-max)))` 逐段跳过空白/注释，再 `read` 顶层 form，用读前后 point 记录 `[start, end]` 与 `(kind . name)`；匹配 `(ebasecamp-define-group NAME …)` / `(ebasecamp-define-project NAME …)`。
  - **实测事实（Emacs 31.1，已复核）**：`read` 本身**会**跳过 `;` 行注释（`--read-forms` docstring 里「read 不认 `;` 注释」的论断不成立，W1.2 顺带修正该 docstring）；但 `#| … |#` 块注释会 `invalid-read-syntax`，扫描器需 `condition-case` 处理（跳过并记录，或直接报「不支持块注释」）。
  - `forward-comment` 保留（与既有实现一致、无害），但它不是「否则必失败」的前置条件。
- **M3 写盘事务**（`-write-transaction FILE WRITE-FN`）：
  1. 读原文 + 记录 `(file-attributes)` 的 mtime+size；快照当前 `ebasecamp-config-load` 的**错误集**（`:errors` 的 message 列表）。
  2. 调用 WRITE-FN 得到新全文（WRITE-FN 必须在**内存里一次**完成全部编辑，例如移动配置的「源移除 + 目标追加」，不得分两次写盘）。
  3. **写前再次 stat**，mtime 或 size 任一变化 → `user-error`「文件已被外部修改，先 `g` 重载」。
  4. 备份原文到临时文件 → 写新全文（**同目录临时文件 + `rename-file` 原子覆盖**）。
  5. 重新 `ebasecamp-config-load`，取新错误集；**仅当出现「写前没有的新错误」时回滚**（新错误集减去旧错误集后非空），避免用户其它文件的既有错误永久阻断写盘。
  6. 回滚 = 用备份恢复原文并 `signal 'ebasecamp-config-write-error`（data 含新错误摘要、原文件路径、备份路径）；恢复失败时同样 signal，并在 message 里给出手工恢复路径。
  7. 成功则删除备份；返回写入后的 model 结果。
- **M4 实体操作语义**（`ebasecamp-config-write.el`，依赖 manifest + model）：
  - 服务字段更新：**不经 model 对象重建**——用 `read` 取该组 form 的原始 `:services` plist（保留用户原值形态，例如 `:command` 原为字符串就仍是字符串），只把 6 个被编辑键替换为新值，其余键值原样带回，再生成该**服务子 form**文本并替换组 form 内对应的 `(服务名 …)` 子 form。未编辑键的**值**因此保真；但服务子 form 内部的注释/排版会被规范化（计划承认此边界）；表单值未改动的字段直接跳过重写。
  - 新增配置：目标组 `:configs` 追加 `(配置名 :project 项目)`；配置名组内唯一、同项目同组不得重复（D2，冲突即 `user-error`）。
  - 改配置 `:project`：只改该配置的 `:project`；同样校验 D2。
  - 删除配置：从组 `:configs` 移除；组内最后一份配置移除后仍保留组（变成无配置组）。
  - 移动配置：**一次事务**内「源组移除 + 目标组追加」，目标校验同新增配置；源组与目标组可能是同一文件（groups.el）——用单次全文改写保证原子性。
  - 新增/改项目：写 `projects/<name>.el`（`ebasecamp-config-project-file`）；新增时文件已存在 → `user-error`。
  - 删除项目：先扫描所有组 `:configs`，若被引用 → `user-error` 并列出「组/配置」清单；否则删除该文件（删除前确认文件属于 `projects/` 目录）。
  - 新增组：向 `groups.el` 追加 `(ebasecamp-define-group NAME :title … :scope … :services nil)`。
  - 改组：只改 `:title` / `:scope`（改 scope 的语义影响由二次确认提示）。
  - 删除组：先扫描所有 `projects/*.el` 的旧写法 `:groups`，若有项目引用该组 → `user-error` 并列出项目名（否则删组后这些项目会「引用未定义组」加载报错）；再二次确认（文案列出「该组 N 份配置、M 个服务；只删清单定义，不删容器」）→ 从 `groups.el` 移除组 form。
- **M5 表单字段映射**（`ebasecamp-config-write.el` 的纯函数，双向）：
  - `ports`：文本每行 `HOST:CONTAINER`（或 `CONTAINER`）↔ `((HOST . CONTAINER))`；非法行报行号。
  - `environment`：每行 `KEY=VALUE` ↔ `(("KEY" . "VALUE"))`；`${VAR}` 原样保留；键重复报错。
  - `volumes`：每行 `SRC:DST[:ro]` ↔ **plist 形态** `(:source SRC :target DST :type bind [:read-only t])`（model 只接受 plist，字符串列表会被 `config-load` 拒绝）；单段 `DST` → `(:target DST :type volume)`；`SRC` 以 `.` 或 `/` 开头视为 bind，否则视为命名卷 `:type volume`；`ro` → `:read-only t`；其它形态（`tmpfs`、多段）不在此表单编辑、保持原值。
  - `command`：多行（每行一个参数）↔ 字符串列表；**首版只支持 exec 形式**，含空格参数必须用多行（每行一个参数），单行输入按空白切分并在 dialog 里提示该边界；原值为字符串（shell 形式）且用户未改动时**跳过重写**，不强制转成列表。
  - `restart`：select（`no` / `always` / `on-failure` / `unless-stopped` / 自定义…）↔ 字符串；选「自定义…」时走 `etaf-call-with-input` + `read-string`，保留 `"on-failure:5"` 这类 free-form 值；打开时若原值不在 4 个枚举内，select 自动落到「自定义」并显示原值。
  - `image`：单行非空字符串（必填）。
- **M6 UI 形态**：`etaf-dialog` + 字段 `etaf-ref`（在组件 `:setup`/`bindings` 里创建）；打开时 `etaf-batch` 预填并置 `open`；保存时先本地解析 + 校验，错误用 `etaf-label :variant 'danger` 显示且**不关闭**；通过后 `etaf-next-tick` 调写盘（让「保存中」先渲染），成功后刷新界面并关闭。
- **M7 键位**（root keys 12 → 16 条）：`S` 编辑 point 所在服务（用 `--ref-at-point` 定位，见注意事项）、`E` 编辑当前配置、`M` 移动当前配置、`X` 清单操作菜单（新建/删除配置、项目 CRUD、组 CRUD 统一收在 `completing-read` 里；在 etaf 键回调内走 `etaf-call-with-input` + `completing-read`，与既有 `I`/`o`/`e` 的 minibuffer 用法一致）。新增四条键需通过 `etaf--keys-validate` 断言（不与框架保留键冲突），并同步三条既有键位测试。
- **M8 每个写操作后**：`ebasecamp-reload`（重载清单）+ `ebasecamp-ui-refresh`，并保留当前选中组与展开状态。
- **M9 安全**：清单只保存 `${VAR}` 引用与相对路径；表单回写不做任何插值；不读取、不打印密钥。

## 数据映射

| 服务字段 | 表单控件 | 文本形态 | 结构形态 |
|---|---|---|---|
| `image` | `etaf-text-input`（单行，必填） | `mysql:8` | 字符串 |
| `ports` | `etaf-text-input :rows 4` | 每行 `3307:3306` | `((3307 . 3306))` |
| `environment` | `etaf-text-input :rows 4` | 每行 `KEY=VALUE` | `(("KEY" . "VALUE"))` |
| `volumes` | `etaf-text-input :rows 4` | 每行 `./data:/var/lib/mysql:ro` | `((:source "./data" :target "/var/lib/mysql" :type bind :read-only t))` |
| `command` | `etaf-text-input :rows 3` | 每行一个参数 | `("mysqld" "--defaults-file=/etc/my.cnf")` |
| `restart` | `etaf-select` | `always` | 字符串 |

## 任务

### 批次 W0：探针（与 form 定位/事务相关的真实行为）

- [x] W0.1 探针：在 `/tmp` 造一个多行 `groups.el`（含**首行 `;;; -*- lexical-binding -*-`**、两个组、字符串里带括号 `"a(b)c"`、`#'` 引用、块间注释、**尾随 `(provide 'x)`**），按 M2 的方式（`forward-comment` + `emacs-lisp-mode-syntax-table` + `read`）扫描顶层 form，断言能准确取到每个 `(ebasecamp-define-group NAME …)` 的 `[start,end]` 与 `(kind . name)`；替换第一个组后，第二个组、注释与尾随 form 字节级不变
      （依赖：无）验收：PASS；输出实际 `[start,end]` 与替换前后 diff 摘要
      **实测记录（PASS）**：扫描返回 `(:start :end :kind :name)`，位置是 **1-based** 的 `read` 前后 `(point)`，字符串切片必须 `(1- pos)`。W1 复测（`/tmp/ebc-w1-probe-scan/groups.el`，3 个顶层 form）：alpha `start=57 end=239`、beta `start=266 end=407`、尾随 `(provide 'probe)` `start=409 end=425`；字符串内括号 `"echo a(b)c"` 与 `#'ignore` 不影响位置准确性。`read` 自身会跳过 `;` 行注释；`#| |#` 块注释 `forward-comment` 不认，`search-forward "|#"` 跳过并记 note（本次位置 241）。替换 alpha 后 beta / 块注释 / 尾随 form 逐字节不变（由 W1.2 的 `--replace-form` 用例断言）。
- [x] W0.2 探针：事务回滚——写一个语法错误的 form → `ebasecamp-config-load` 报错 → 恢复原文后文件与原文逐字节一致；并发检测——写入前人为改 mtime，断言触发 `user-error`
      （依赖：W0.1）验收：PASS
      **实测记录（PASS）**：追加 `(ebasecamp-define-group delta :scope bogus)` 后新增 1 条错误 → signal `ebasecamp-config-write-error`，文件 sha256 复原（`0ac1eaf99a0a6191…` 前后一致），备份被删除（目录内无 `.ebasecamp-*` 残留）。判据必须是**错误 message 差集**：语法错一次产生 **2 条**错误，所以既不能硬编码条数，也不能用「`:errors` 为空」。mtime 检测用 `(file-attribute-modification-time (file-attributes f))` + size 双判据、`equal` 比较；写前改 mtime → `user-error`。原子写 = 同目录 `make-temp-file` + `rename-file`。
- [x] W0.3 探针：`etaf-dialog` + 6 字段（含 3 个多行 text-input）+ 错误 label + 取消/保存按钮，在 batch 下挂载、预填、改一个多行字段值、点保存（打桩写盘函数），断言回调收到正确文本且 dialog 关闭
      （依赖：无）验收：PASS；若 dialog 内多行字段有异常（Tab/ESC/值丢失），记录并给替代方案（改用 minibuffer `read-string`）
      **实测记录（PASS）**：`etaf-dialog` + `etaf-text-input :rows` 多行可用（`rows>1` 时 RET 不提交、`C-c C-c` 提交，换行保留）。两条边界：① dialog 的文本**不含**用户输入内容，值只能经 `etaf-ref` 读回；② `:ref` 只接受 symbol / function / nil。dialog 不能同步返回输入，需要同步输入时仍用 `etaf-call-with-input` + minibuffer（既有 `I`/`o`/`e` 的用法）。

### 批次 W1：manifest 内核

- [x] W1.1 红：`ebasecamp-manifest-locate-form`（找到/找不到两种）、`-replace-form`（只替换目标块、其余字节不变）、`-append-form`（追加到文件末尾、保留结尾换行）、`-remove-form`（删除块及其独占空行）
      （依赖：W0.1）验收：4 项 FAILED
      **红阶段实测**：`test/ebasecamp-manifest-tests.el` 落地后先建占位 `lisp/ebasecamp-manifest.el`（仅 `provide`），`make test` = **368 tests / 359 expected / 9 unexpected**，9 项全 `void-function`（含 W1.3 的 3 项与第 9 项 symlink 断言）。用例：`scan-forms` / `replace-form` / `append-form` / `remove-form`（4 项按 W1.1 验收）。
- [x] W1.2 实现 `ebasecamp-manifest.el` 的定位与替换工具（`ebasecamp-manifest--scan-forms`：`forward-comment` + syntax table + `read` + point 记录；`condition-case` 处理 `#| |#`）；`ebasecamp-import.el` 的三个生成器改为 wrapper，并**修正 `--read-forms` docstring 里「read 不认 `;` 注释」的错误论断**（实测 Emacs 31.1 会跳过；改为「块注释 `#| |#` 不支持」）；`make test` 全绿（359 不变）
      （依赖：W1.1）验收：W1.1 转绿；原有 359 项无回归
      **实测记录**：扫描返回 `((:start N :end N :kind SYM :name SYM) ...)`（kind 取 `group`/`project`，其余 form 两者 nil）；切片一律 `(1- pos)`。块注释策略 = 方案 A（`search-forward "|#"` + note + 未闭合 `user-error`），实现踩坑一处：`looking-at-p` **不设置 match data**，须用 `looking-at` 再取 `match-end`。import 三个生成器改为 thin wrapper（`ebasecamp-manifest-service-form` / `-group-form` / `-project-form`），`--literal` / `--service-output-keys` 移入 manifest 成为唯一实现；**字节一致性验证**：同一 services alist 分别用改造前（`/tmp/ebc-uibak-1792753788/ebasecamp-import.el`）与改造后实现生成 `--manifest-content`，`diff` 为空、sha256 同为 `ead61b48d9628b619…`、969 字节。原有 359 项无回归。
- [x] W1.3 红：`-write-transaction`（成功路径 / 校验失败恢复 / mtime 冲突拒绝）
      （依赖：W0.2）验收：3 项 FAILED
      **红阶段实测**：含在 W1.1 的同一次红运行里（`write-transaction-success` / `-rollback` / `-stale` 3 项 FAILED，另加 `-existing-errors` 与 `-symlink` 两项覆盖「既有错误不阻断」与原子写边界，共 9 项红）。
- [x] W1.4 实现 `-write-transaction`
      （依赖：W1.3）验收：转绿
      **实测记录**：7 步全部落在 `ebasecamp-manifest--write-transaction`：① 读原文 + `(mtime . size)` 快照 + `ebasecamp-config-error-messages` 快照；② `WRITE-FN` 得新全文（与原文相同则不写盘）；③ 写前再 stat，mtime 或 size 变化 → `user-error`「已被外部修改，先 `g` 重载」；④ `--backup`（同目录 `.ebasecamp-backup-*` 隐藏文件，不带 `.el` 后缀以免被加载器读到）；⑤ `--write-file` 原子写（同目录 `make-temp-file` + `rename-file`，沿用原文件权限位）；⑥ 重新加载取新错误集，`cl-set-difference` 出新增 message；⑦ 成功删备份并返回加载结果，回滚 = 恢复原文 + 删备份 + 重新加载 + `signal 'ebasecamp-config-write-error`（恢复本身失败时保留备份并在 message 给出路径）。附带：`ebasecamp-config-error-messages`（`lisp/ebasecamp-config.el`，取 `:errors` 的 `:message` 列表）；symlink 目标在事务开始时即拒绝（`rename-file` 会替换链接本身）。

### 批次 W2：字段映射（纯函数）

- [x] W2.1 红：`-ports-to-text` / `-text-to-ports` / `-environment-*` / `-volumes-*` / `-command-*` 往返 + 非法输入（端口非数字、env 缺 `=`、volumes 缺冒号、command 空行）+ `${VAR}` 原样保留
      （依赖：无）验收：全部 FAILED
      **红阶段实测**：`test/ebasecamp-config-write-tests.el`（7 项：ports / environment / volumes / command / restart / image / var-refs 各 1 项，非法输入作为同用例内断言）+ 只有 `provide` 的占位 `lisp/ebasecamp-config-write.el` → `make test` = **375 tests / 368 expected / 7 unexpected**，7 项全 `void-function`；原有 368 项无回归。
- [x] W2.2 实现 6 个字段的双向映射（解析失败 `user-error` 带行号）
      （依赖：W2.1）验收：转绿
      **实测记录**：`lisp/ebasecamp-config-write.el`（纯函数，无 IO，`require 'ebasecamp-manifest` 仅为复用父错误 `ebasecamp-config-write-error`，不重定义）。踩坑/决策四处：① 复用 `signal`/`user-error` 分工——解析失败（文本 → 结构）用 `user-error` 带行号，结构 → 文本 的非法输入用不带行号的 `user-error`；② 行号 1-based 且**空行占行号**（空行本身忽略），因此「第 2 行」指向用户看到的第 2 行；③ `split-string` 默认不省略空段（`":/x"` → `("" "/x")`），据此判「空段」而非拼正则；④ `command` 的行为分支按「文本是否含换行」判定（含换行 = 每行一个参数、空格保留；不含换行 = 按空白切分），保证多行参数带空格不被误切。

**W2 映射口径（实现定案，W4 表单直接照此实现）**

| 字段 | 文本 → 结构 | 结构 → 文本 | 边界 |
|---|---|---|---|
| `ports` | 每行 `HOST:CONTAINER`；**单段 `N` → `((N . N))`**（仅容器端口） | **恒写两段**（`((80 . 80))` → `"80:80"`，不折叠） | 非整数 / 负号 / 缺一段 / 多冒号 → `user-error` 带行号 |
| `environment` | 每行 `KEY=VALUE`，按**首个** `=` 切分 | `KEY=VALUE` 逐行 | 缺 `=` / 空键 / 重复键 → `user-error`（重复键附首次出现行号）；`${VAR}` 原样 |
| `volumes` | `SRC:DST[:ro]`；**源以 `.` 或 `/` 开头 → `:type bind`，否则 `:type volume`**；单段 `DST` → `(:target DST :type volume)` | 有 `:source` 写 `SRC:DST[:ro]`，缺源只写 `DST` | 段数 > 3 / 空段 / 第三段非 `ro` → `user-error` 带行号（`tmpfs`、`:rw` 不改写、直接报错） |
| `command` | 含换行 → 每行一个参数（行内空格保留）；**不含换行 → 按空白切分** | 每行一个参数 | **只支持 exec 形式**；shell 形式原值由调用方在「用户未改动」时跳过重写（本模块不转换） |
| `restart` | `string-trim` 后空 → nil | 原样（nil → `""`） | 4 枚举外 free-form（`"on-failure:5"`）原值往返，不报错 |
| `image` | `string-trim`，空即 `user-error`「镜像（image）不能为空」 | —（单行） | 必填，无行号概念 |

错误消息格式统一为 `"第 N 行：<说明>，得到 \"<原文>\""`（`user-error`；N 为 1-based 行号、空行占号但不参与解析）。

### 批次 W3：实体操作

- [x] W3.1 红（服务与配置）：`-update-service-fields`（只改 6 键、未编辑键按原文 plist 保留、未改动字段跳过重写）、`-add-config`（含 D2 冲突拒绝）、`-update-config-project`、`-remove-config`、`-move-config`（跨组跨项目，**同一 in-memory 全文一次改两处**）
      （依赖：W1.4、W2.2）验收：5 项 FAILED
      **红阶段实测**：`test/ebasecamp-config-write-tests.el` 追加 5 项（临时清单目录脚手架 + `ebasecamp-config-directory` 动态绑定）→ `make test` = **380 tests / 375 expected / 5 unexpected**，5 项全 `void-function`；原有 375 项无回归。用例：`update-service-fields` / `update-service-unchanged-skips` / `add-config` / `update-and-remove-config` / `move-config`。
- [x] W3.2 实现服务与配置操作
      （依赖：W3.1）验收：转绿
      **实测记录**：`make test` = **380 tests / 380 expected / 0 unexpected**；`make check-parens` 26 文件通过、`make compile` 零 warning、`make check` 退出码 0。
      **实现要点（四问四答）**：
      ① **服务子 form 区域定位方式**：新增 `ebasecamp-manifest--scan-forms-in-region (text start end)`（两级区域扫描，复用 `read`，不写自定义扫描器）——先跳过 `(ebasecamp-define-group NAME` 头部（`--group-head-end`），在组 form 内部顺序读**元素**（关键字与取值，如 `:services` 与其后的服务列表），再在服务列表括号内部顺序读**服务子 form**，按 `(car value)` 匹配服务名。为此把 `--scan-forms` 的扫描逻辑下沉为 `--scan-text-forms (text &optional label)`（公开形状不变，`--scan-forms` 变成「读文件 + 委托」的薄壳）——写盘路径必须在**同一份内存全文**上定位，不能重新读盘（否则 mtime 快照与原子性失效）。
      ② **组 form 重渲染的规范化边界**：新增 `ebasecamp-manifest-group-form-from-plist (name plist)`（保留 `:title` / `:scope` / `:services` / `:configs` 全部键值，与导入模板 `-group-form` 分工不混用）+ `ebasecamp-manifest-config-form`（配置项按 `prin1` 单行渲染，`${VAR}` 原样）。规范化**只发生在组 form 内部**：键序固定 title → scope → services → configs，服务子 form 与配置项各占一行，服务子 form 内部注释丢失；组 form **之外**（文件头、块间注释、其它组、尾随 form）逐字节保留（由 `--replace-form` 保证，测试用「前缀 + 后缀」真值断言）。服务字段更新**不重渲染整组**：只替换 `(服务名 …)` 子 form，并用 `--column-at` + `--indent-text` 把生成器的相对缩进对齐到原列（其余字节不动）。
      ③ **D2 校验落点**：`ebasecamp-config-write--check-project-conflict (group-name configs project &optional ignore)`，在**写盘之前**（事务的 WRITE-FN 内部）对**从原文 `read` 出的 `:configs`** 做检查，`user-error`「项目 X 已引用组 Y（来源：配置 Z）；同一项目同一组只允许 1 个引用」；`ignore` 参数在改 `:project` 与组内移动时排除自身。选在原文 plist 而非 model 对象上校验：写前就能判定，避免「先写盘再靠错误差集回滚」把冲突变成一次无谓的写盘 + 恢复。model 侧的 D2（`--validate-projects` 项目重复引用组、`link-configs` 的 `:duplicate-group`）仍作为兜底，写后出现新错误时事务照常回滚。
      ④ **移动配置的原子性实现**：新增 `ebasecamp-manifest--replace-forms (text replacements)`（按 `:start` **降序**应用多处替换，前面替换的长度变化不影响后面位置）；`-move-config` 在一次 `--write-transaction` 的 WRITE-FN 里对同一份原文算两段新文本（源组 `:configs` 去掉该配置、目标组追加 `(配置名 :project 项目)`），所以不存在「源组已删、目标组没加」的中间态；D2 冲突/组不存在/配置不存在都在写盘前 `user-error`，文件 sha256 与两组 `:configs` 逐字节不变（测试断言）。配置原有 `:services` 覆盖随配置搬走（目标组无同名服务 → 写后新错误 → 事务回滚，不静默丢数据）；源组删掉最后一份配置后写 `:configs nil`，组保留。
- [x] W3.3 红（项目与组）：`-add-project`（文件已存在拒绝）、`-update-project`、`-remove-project`（被 `:configs` 引用拒绝并列出）、`-add-group`、`-update-group`、`-remove-group`（被项目侧旧 `:groups` 引用拒绝并列出）
      （依赖：W3.2）验收：6 项 FAILED
      **红阶段实测**：`test/ebasecamp-config-write-tests.el` 追加 6 项（`add-project` / `update-project` / `remove-project` / `add-group` / `update-group` / `remove-group`）+ 3 个新脚手架（`--project-file` / `--all-project-hashes` / `--legacy-project` 常量）→ `make test` = **386 tests / 380 expected / 6 unexpected**，6 项全 `void-function`；原有 380 项无回归。
- [x] W3.4 实现项目与组操作；`make check` 全绿
      （依赖：W3.3）验收：转绿
      **实测记录**：`make test` = **386 tests / 386 expected / 0 unexpected**；`make check-parens` 26 文件通过、`make compile` 零 warning、`make check` 退出码 0。
      **实现要点（四问四答）**：
      ① **新文件的写入路径**：`ebasecamp-manifest--write-new-file (file text)`（manifest 侧唯一新增，`lisp/ebasecamp-manifest.el:113`）——`make-directory` 递归建父目录（新增项目时 `projects/` 可能还不存在）、文件已存在即 `user-error`、落地复用 `--write-file`（同目录临时文件 + `rename-file` 原子覆盖）。`groups.el` 不存在时也走它（写入文件头 `;;; -*- lexical-binding: t; -*-`）；存在时走 `--edit-manifest` 的写盘事务 + `--append-form`（前面补一个空行）。
      ② **删除的引用扫描实现（两处不可混用）**：删除**项目**前用 `--config-references` 读 groups.el 原文、按组 form 的 `:configs` 逐项比 `:project`，返回「组/配置」字符串（如 `alpha/dev`）；删除**组**前用 `--legacy-group-references` 遍历 `ebasecamp-config--project-files`，`read` 每个项目 form 的 `:groups` 旧写法、按引用项 `car` 比组名。两处都**读原文而不看 model**（model 可能因既有加载错误缺定义，引用判断必须看磁盘真实内容）。
      ③ **删除的事务语义（无「原文替换」可用）**：`--delete-file-transaction` = 校验路径归属（`--check-project-path`：父目录必须等于当前清单目录的 `projects/`、文件名必须等于 `<PROJECT>.el`）→ 记录原文与权限位 → `delete-file` → 重新加载 → **仅新增错误**时用 `--write-file` 写回原文 + `set-file-modes` 恢复权限位并 signal `ebasecamp-config-write-error`（回滚本身失败则在消息里给出文件路径求人工介入）。符号链接直接拒绝（删除移除链接、恢复会造普通文件）。删除组不需要它：组是 groups.el 里的 form，走 `--remove-form` + 写盘事务即可。
      ④ **错误文案**（界面层直接展示）：`项目 a 被以下组配置引用：alpha/dev；先删除这些配置或改其 :project 再删项目`；`组 beta 被以下项目的旧写法 :groups 引用：legacy；先删掉项目里的引用再删组`；`项目 app 已存在（文件 …），改项目请用更新操作`；`清单 … 里已有组 gamma`；`组 scope 必须是 shared 或 per-project，得到 bogus`；`项目名 "Bad Name" 非法：只允许小写字母、数字、下划线与连字符`（复用 `ebasecamp-import--normalize-name` 的规则，`ebasecamp-import-error` 统一转 `user-error`）。
      **项目渲染边界**：`ebasecamp-config-write--project-form` 固定键序 title → root → shared-network → export-file → groups，保留 `:shared-network` / `:export-file` / 手写的 `:groups`（`ebasecamp-manifest-project-form` 只服务导入：title 恒等于项目名且不写无关键）；新增项目一律不写 `:groups`（AGENTS 不变量 9）。
      **顺带修复 W3.2 的真实缺陷（数据丢失）**：`-add-config` / `-update-config-project` / `-remove-config` / 同组 `-move-config` 原先直接把 `--render-group` 的**渲染片段**当作写盘事务的「整份新全文」返回，效果是把 groups.el 覆盖成单个组（兄弟组、文件头、注释全部丢失；原 W3.2 测试只断言目标组，未断言兄弟组因而没暴露）。修法：新增 `ebasecamp-config-write--replace-group (text form plist)` = `--replace-form` 包住渲染结果，四处调用点统一改用它；并给 W3.2 的 `add-config` 用例补「兄弟组与文件头逐字节保留」的回归断言（本次共 6 项新用例 + 1 处回归断言）。

### 批次 W4：UI 表单与键位

- [x] W4.1 红：服务编辑 dialog（预填 6 字段 / 保存调用写盘 / 解析失败不关闭且显示错误）、配置编辑 dialog（选项目）、移动配置（completing-read 选目标组+项目）、`X` 菜单（新增/删除配置、项目与组 CRUD 的 dispatch）、root keys 12 → 16 条（同步改 `root-keys-complete` / `root-keys-final-set` / `help-data-includes-labels`）
      （依赖：W3.2、W0.3）验收：FAILED
      **红阶段实测**：`test/ebasecamp-ui-tests.el` 新增第 19 节「清单写操作（W4：服务编辑 dialog + `E` / `M` / `X`）」共 **6 项**用例——`-service-dialog-prefills` / `-service-dialog-save-writes` / `-service-dialog-invalid-keeps-open` / `-x-menu-dispatch` / `-move-config-prompts` / `-write-keys-bound`；同时**同步 3 条既有键位测试**：`root-keys-complete`（键集合断言加 `S`/`E`/`M`/`X`）、`root-keys-final-set`（`12` → `16` 条 + 排序集合断言）、`help-data-includes-labels`（收集到的根级 LABEL 由 12 条变 16 条）。红阶段全部因 `void-function` 失败，`make test` 报 unexpected。
- [x] W4.2 实现 UI 层（只改 `lisp/ebasecamp-ui.el`）：dialog 组件、字段 refs、键位、菜单 dispatch、写后 reload+refresh
      （依赖：W4.1）验收：转绿；`make check` 全绿
      **实测记录（PASS）**：`make test` = **392 tests / 392 expected / 0 unexpected**；`make compile` 零 warning；`make check-parens` 通过；`make check` 退出码 0（W3.4 的 386 → 392，+6 即本批新增用例，无回归）。
      **落地内容（`lisp/ebasecamp-ui.el`，+584 行）**：
      ① **服务编辑 dialog**：`--service-editor-new` / `--service-field-text`（6 字段文本预填，走 W2 的 `-*-to-text` 纯函数）/ `--restart-options`（4 枚举外自动落「自定义…」并显示原值）/ `--service-dialog-error-view`（`etaf-label :variant 'danger` 自实现字段级错误）/ `--open-service-editor` / `--service-dialog-save`（先本地解析校验，失败只更新 error ref、**不关闭** dialog；通过后 `etaf-next-tick` 调 `ebasecamp-config-write-update-service-fields`，写后 `--after-write` 做 reload + refresh）。point 定位走 `--row-key-at-point` + `--split-instance-key`（按**首个** `/` 切分，剥 `ebasecamp-ui-row-` 前缀）。
      ② **配置编辑**：`--open-config-editor`（`--choose-config` 选配置 + `--require-project` 用 `completing-read` 选项目 → `-update-config-project`）。**措辞说明**：计划里写的「配置编辑 dialog」与实际实现（`completing-read` 选项目后直接写盘，无 etaf dialog）不一致——用户已裁决：**正确形态就是 `completing-read`**，文档在 W5 统一，本批不改实现。
      ③ **移动配置**：`--move-config`（目标组 + 目标项目两级 `completing-read` → `-move-config`），`E`/`M` 的配置选择走 `--choose-config`：**组内 1 份配置时不提问、多份时先选配置**（用户已裁决接受——多配置组会多一次提示）。
      ④ **`X` 清单操作菜单**：`--manifest-menu` + `--manifest-menu-items`（8 项：新建/删除配置、新建/改/删除项目、新建/改/删除组），统一 dispatch 到 W3 的实体操作；删除类先 `y-or-n-p` 二次确认（用户已裁决**保留**），文案写明「只删清单定义，容器需用 `D` 销毁」；`--scope-choices` 复用 model 的 `shared` / `per-project`；取消静默返回、写盘失败转 error notice。
      ⑤ **键位**：`--root-keys` 12 → **16 条**，新增 `S`（编辑服务）/ `E`（编辑配置）/ `M`（移动配置）/ `X`（清单操作），全部带非空 LABEL 且通过 `etaf--keys-validate`（不与框架保留键冲突）。
      **测试断言边界**：`etaf-dialog` 的文本不含控件内容，dialog 只能在 **ref 层**断言（预填后读 6 个字段 ref 的值、非法保存后读 error ref 非空且 dialog 未关闭），不能断言渲染出的可见文本——这与 W0.3 探针的结论一致。
      **`--service-field-changes` 的语义确认**：只提交**改动**字段；某字段被清空 → 传 `nil` 删除该键（而非写空串）。用户已裁决为**正确语义，保留**（由 `-update-service-fields` 的「`nil` 删除键、未提及键保持原值」实现）。
      **执行过程说明**：W4 实现与测试在上一轮已全部落地并通过 `make check`，但该轮在执行收尾时**触发 step-limit 中断**，计划勾选、状态更新、`git status` 采集、`set_task auto` 收尾与 L2 的两项补充验证（batch 端到端探针、真实 docker 闭环）未完成。本轮为恢复任务：补齐勾选与状态、定位探针脚本 bug（非实现问题）、跑真实 docker 闭环，不改实现、不改测试。
      **收尾补验（本轮，PASS）**：
      ① **真实 docker 闭环**（L2 强制项）：`/tmp` 清单 1 组 1 服务（`alpine:3.20`、`ports ((18099 . 80))`）→ `ebasecamp-config-write-update-service-fields` 改成 `((18100 . 80))`（groups.el 实际写入 `:ports ((18100 . 80))`）→ `ebasecamp-config-load` 错误 nil（无新增）→ `ebasecamp-export-project` 导出到项目根 `docker-compose.ebasecamp.yaml` → `docker compose -f … config -q` **退出码 0、stderr 为空**（`level=warning` 也不需要豁免）；`docker compose config` 解析结果为 `target: 80 / published: "18100"`，证明改动端到端生效。docker 版本 29.9.1。
      ② **batch 端到端探针（`S` 编辑框）**：合法清单下加载 / 打开界面 / 定位服务行（`--row-key-at-point` = `"mysql/write-svc"`）/ 打开编辑框 / 6 个字段 ref 预填值 / 非法端口保存（error ref = 「第 1 行：端口必须写成 `HOST:CONTAINER` 或 `CONTAINER`（十进制整数），得到 \"abc\"」、`open` 仍为 t）/ 合法端口保存（真实写盘，`open` 变 nil）全部通过。**上一轮空态的成因是探针脚本自身**（清单内容不合 model 校验 → 组未注册 → `:empty-p` 为 t），非实现问题；对照实验：清单合法但**未选中组**时同样取不到服务行（`--select-key` 必需），这是第二个探针侧坑。

### 批次 W5：文档与目检

- [x] W5.1 `Readme.org`：新增「编辑 container 配置」「配置/项目/组操作」两节 + 键位表补 `S`/`E`/`M`/`X`
      （依赖：W4.2）验收：grep 含「编辑 container 配置」「移动到其他组」「清单操作」
      **实测记录（PASS）**：`Readme.org` 437 行（原 386）。①「特性」加两条 bullet（界面内编辑 container 配置 / 配置·项目·组增删改）；②新增 `** 编辑 container 配置`（L309–330，22 行：6 字段书写规则表 + 只提交改动字段 / 清空=删键 / 表单外字段保真 / 写前校验四条语义）；③新增 `** 配置与项目、组操作`（L331–350，19 行：`E`/`M`/`X` 键表 + `X` 菜单 8 项 + 引用保护与影响提示 + 新建类约束 + 事务段落）；④根级键位表补 `S`/`E`/`M`/`X` 四行；⑤「界面键位」intro 改写为「表单与手写两条路共用同一事务内核」；⑥「编辑清单的流程」改为「表单覆盖不到时才手写」；⑦命令表 `ebasecamp-ui-edit-manifest` 描述同步；⑧已知限制「界面不做清单编辑」→「服务增删改名仍不支持」。grep：编辑 container 配置 2 / 移动到其他组 1 / 清单操作 3 / 事务 3。
- [x] W5.2 `docs/user-guide.org`：操作流程（改端口 → 保存 → `g`、移动配置、删除组的影响提示）
      （依赖：W5.1）验收：grep 含「移动到其他组」「保存」「只删清单」
      **实测记录（PASS）**：`docs/user-guide.org` 588 行（原 520）。①新增 `** 在界面里改配置：S / E / M / X`（L341–407，67 行，含 4 个 `***` 子节）：键分工表 → `*** 改端口、环境变量、卷：S`（四步流程 + 三字段写法表 + 带行号错误「第 1 行：端口必须写成…」且表单不关闭 + 保存后自动重载 / 何时才需按 `g`）→ `*** 移动配置到其他组的其他项目：M`（两级选择 + 一次事务 + 两条拒绝条件）→ `*** 新增、删除配置：X` → `*** 项目与组的新增、改、删（含影响提示）：X`（六项菜单表 + 引用保护）+「*只删清单，不删容器*」单独成段；②原 `** 编辑配置：唯一写入口是 =e=` 改名为 `** 手工编辑清单：=e=` 并改写首句；③「已知边界」表把「界面内没有清单编辑器」替换为两行（服务增删改名不支持 / 组 form 重渲染规范化）；④「限制与注意事项」表同步该行。grep：只删清单 1 / 错误 9 / 移动到其他组 1。
- [x] W5.3 `docs/architecture.org`：新增「清单写盘」节（form 定位、事务、并发检测、引用完整性、字段映射、UI 表单边界）
      （依赖：W5.2）验收：含关键词「form 定位」「事务」「mtime」「引用完整性」
      **实测记录（PASS）**：`docs/architecture.org` 473 行（原 391）。①新增 `* 清单写盘`（L343–416，74 行，6 个 `**` 子节）：`** form 定位`（syntax-table + forward-comment + read + point、1-based 切片必须 `1-`、`read` 自身跳 `;` 注释、`#| |#` 不被 `load` 认可因此写入绝不生成、`--replace-forms` 按 start 降序）→ `** 写盘事务`（七步 + 错误集差分不是「零错误」+ TOCTOU 窗口 + 实体操作写前校验）→ `** 引用完整性`（删项目扫 `:configs` 的 `:project` / 删组扫旧 `:groups`，两处不可混用，均读原文）→ `** 字段映射`（六字段双向表 + volumes 必须 plist + ports 单段→`((N . N))` 输出恒两段 + command exec-only + 服务字段从原文 plist 保真）→ `** UI 表单边界`（root-layer 文本不含内容、ref 在 `:bindings` 建、`:ref` 只接受 symbol/function/nil、slot footer 必须是直接子项、`etaf-next-tick`）→ `** 已知边界`；②`** 编辑入口边界` 改写为「表单 + 手写两条路共用同一事务内核」并声明 ADR-0003 决策 6 被 ADR-0005 扩展；③模块公开 API 表补 `ebasecamp-manifest.el`（5）/ `ebasecamp-config-write.el`（23）两行、`ebasecamp-config.el` 3 → 4（`-error-messages`）、合计 72 → 100；④「相关文档」加 ADR-0005 链接。grep：form 定位 1 / 错误集 4 / mtime 5 / 引用完整性 1 / volumes 6 / root-layer 1。
- [x] W5.4 `docs/adr/0005-manifest-write.org` + `openspec/decisions.md` + **修订 ADR-0003**：
      ① 新建 ADR-0005（否决备选：整份重写清单 / 界面内自由编辑 Elisp / 引入 yaml 或数据库式存储）；
      ② 在 `docs/adr/0003-ui-readonly-keymap.org` 的「唯一写入口 = `e`」决策处加 **superseded 注记**（v0.5 起写操作可经界面表单 `S`/`E`/`M`/`X`，但一律走同一写盘事务内核；界面 buffer 仍只读）；
      ③ `openspec/decisions.md` 追加一行修订记录（「ADR-0003 决策 6 被 ADR-0005 扩展」）。
      （依赖：W5.3）验收：ADR-0005 存在且含三条否决；ADR-0003 含 superseded 注记；decisions.md 含修订行
      **实测记录（PASS）**：①`docs/adr/0005-manifest-write.org` 新建 85 行 —— `#+status: 已接受（Accepted）`、`#+date: 2026-10-23`，节次：背景（4 条现象 + 核心矛盾）→ 决策（4 条：局部写盘 / 事务 / 表单边界 / volumes plist）→ 后果（正面 6 条 / 负面 4 条 / 已知边界 4 条）→ 备选方案与否决理由（A 整份重写清单、B 界面内自由编辑 Elisp、C 引入 YAML 或数据库式存储，三条均含具体否决理由）→ 状态（引用 ADR-0001/0002/0003 与 tech-debt #16/#25/#26/#29/#30）；②ADR-0003 决策 6 段尾加 `*Superseded 注记（2026-10-23，v0.5）*`（grep `Superseded` = 1，含 `0005-manifest-write.org` 链接）；③`openspec/decisions.md` 从 24 → 31 行，追加 8 行：4 条 ADR-0005 决策（局部写盘 / 事务 / 表单边界 / volumes 并入决策行的写法见文件）+ 1 条「ADR-0003 决策 6 被 ADR-0005 扩展」修订行 + 3 条否决备选。
- [x] W5.5 `CHANGELOG.md` 0.5.0 + 全部 `Version:` 同步 0.5.0
      （依赖：W5.4）验收：`grep -c '0.5.0'` ≥ 12
      **实测记录（PASS）**：①`## [0.5.0] - 2026-10-23` 段插入（含 新增 7 条 / 变更 5 条 / 修复 1 条），CHANGELOG 145 → 171 行；②`grep -c '0.5.0' CHANGELOG.md` = **1**（只有段标题含版本号；正文按 Keep a Changelog 不重复版本串）—— 与计划里「≥ 12」的旧口径不一致，本轮按任务书的口径（≥ 1）验收；③`sed -i 's/^;; Version: 0\.4\.0$/;; Version: 0.5.0/' ebasecamp.el lisp/*.el` → `grep -rn '^;; Version:'` 13 个文件**全部 0.5.0**（原 11 + `ebasecamp-manifest.el` + `ebasecamp-config-write.el`）。
- [x] W5.6 `AGENTS.md`：
      ① **改写不变量第 12 条**为「UI buffer 保持只读；写操作经界面表单（`S`/`E`/`M`/`X`）或 `e` 打开的清单文件，均须走 `ebasecamp-manifest--write-transaction`」；
      ② 新增第 14 条「清单写盘必须经 `ebasecamp-manifest--write-transaction`（备份 → 原子写 → 仅新增错误才回滚 → 先检测外部修改）」；
      ③ 当前状态：测试基线对齐（旧值 358 → `make test` 实际值）、v0.5 完成、下一步 v0.6。
      （依赖：W5.5）验收：不变量 12 改写完成、14 存在、基线数字与 `make test` 一致
      **实测记录（PASS）**：①不变量 12 改为「UI buffer 保持只读（`ebasecamp-ui-mode` 派生 `special-mode` + `buffer-read-only t`），并以最外层 Host 的 `:key-scope 'local` 吞掉未绑定 printing key；写操作经界面表单（`S` / `E` / `M` / `X`）或 `e` 打开的清单文件，均须走 `ebasecamp-manifest--write-transaction`」；②新增第 14 条（含「回滚判据是错误集差分，不是零错误也不是条数」）；③目录结构 `lisp/` 行补两个新模块、`docs/` 行补 `0005-manifest-write.org`；④当前状态：进行中计划改为 v0.5（W5 文档完成待 W5.8 目检）、基线 **358 → 392**（无 358 残留）、下一步 W5.8 → v0.6、架构决策列补 ADR-0005。
- [x] W5.7 `openspec/tech-debt.md`：#26 标记关闭（界面内最小编辑能力已提供）；新增「服务增删/改名仍不支持（容器孤儿风险）」一条
      （依赖：W5.6）验收：tech-debt 命中
      **实测记录（PASS）**：①#26 处置计划列尾追加「**已关闭（0.5.0）**：界面内已提供最小编辑能力（服务 6 字段 + 配置 / 项目 / 组 CRUD + 移动配置）；仍不做全量编辑器（不编辑组服务定义本身、不做服务增删改名、配置的 `:services` 覆盖只读展示）」；②新增 #31「服务增删与改名仍不支持」——影响写明三条（删除 → 容器孤儿且无入口清理；改名 → 标签与容器命名含服务名，等于删+加；新增 → 与配置覆盖耦合），处置计划与 #16 / #25 同源（需 `ebasecamp-prune` 先能识别并清理孤儿容器）；③#29 / #30 原样保留（tech-debt 34 → 35 行）。grep：已关闭（0.5.0）1 / 服务增删与改名 1 / `\| 29 \|` / `\| 30 \|` / `\| 31 \|` 各 1。
- [ ] W5.8 用户目检（L3）：①改一个服务端口 → 保存 → 界面刷新 → `docker compose config -q` 通过；②新增/删除配置；③移动配置到其他组的其他项目；④新增项目 / 改 root；⑤删除组时看到影响提示；⑥恶意输入（非法端口/env）被拦住且 dialog 不关闭
      （依赖：W5.7）验收：用户确认

## 文档清单

| 文档 | 本计划触发的更新 |
|---|---|
| `Readme.org` | 编辑 container 配置、配置/项目/组操作、键位 |
| `docs/user-guide.org` | 写操作流程与影响提示 |
| `docs/architecture.org` | 新增「清单写盘」节 |
| `docs/adr/0005-manifest-write.org` | 新 ADR |
| `openspec/decisions.md` | 追加决策与否决备选 |
| `AGENTS.md` | 不变量第 14 条、当前状态 |
| `CHANGELOG.md` | 0.5.0 |
| `openspec/tech-debt.md` | #26 关闭；新增服务增删/改名限制 |

## 验证标准

- **L1**：`make check-parens` + `make compile`（零 warning）
- **L2**：`make test` 全绿（基线 359；预计新增 ≥ 30 项）；**强制**一条真实 docker 闭环测试：改服务端口 → 保存 → `docker compose config -q` 退出码 0 且 stderr 无 error（复用 v0.2 D3/D6 的闭环写法）
- **L3**：用户目检 6 项（见 W5.8）
- 每批次完成更新本文件「## 当前状态」

## 注意事项

- **不改 `groups.el` 的版式**：只替换目标 form，块外注释、空行、顺序原样保留；不重排文件。
- **服务字段更新必须保留未编辑字段**：从**原文 plist** 取值（不经 model 对象重建），把 `:healthcheck` / `:labels` / `:networks` / `:extra` / `:entrypoint` / `:working-dir` / `:user` / `:depends-on` 原样带回，否则会静默丢字段。
- **`--literal` 的转义**：`prin1-to-string` 会转义引号与反斜杠，`${VAR}` 原样；写回多行字符串时绑定 `print-escape-newlines t`（复用 import 的做法）。
- **事务必须先备份再写**：回滚判据是「写前错误集 → 写后新增错误」，不是「零错误」；恢复失败要 `signal` 并给出原文件路径与备份路径，不能静默。
- **原子写**：写盘用同目录 `make-temp-file` + `rename-file` 覆盖；mtime+size 检测与写入之间仍有 TOCTOU 窗口，接受该窗口（单用户编辑器场景）。
- **未编辑字段保真**：服务字段更新从**原文 plist** 取值（不经 model 归一化），`command` / `entrypoint` 原为字符串则保持字符串；未改动字段跳过重写。服务子 form 内部注释与排版会被规范化，这是本计划的已知边界。
- **volumes 必须是 plist**（`(:source … :target … :type bind|volume [:read-only t])`）；字符串列表会被 `ebasecamp-config-load` 拒绝。
- **并发检测**用 `(file-attributes)` 的 mtime + size 双判据（mtime 精度在某些文件系统上为 1s，size 兜底）。
- **D2 不变量**：同一项目 + 同一组只允许 1 个引用；新增/移动/改 project 时都要校验，冲突时报出「项目 X 已引用组 Y（来源：配置 Z）」。
- **两处引用扫描归属**：删除**项目**前扫所有组 `:configs` 的 `:project`；删除**组**前扫所有 `projects/*.el` 的旧写法 `:groups`。两者不可混用。
- **错误集差分**只比较**消息文本**（去掉行号/位置），避免同一旧错误行号漂移被误判为「新错误」而触发回滚。
- **`S` 的 ref 解析**：用**首个 `/`** 切分（组名在前），不要用 `split-string` 默认按所有 `/` 切分。
- **原子写的符号链接边界**：`rename-file` 覆盖会替换链接本身而非目标；本仓库清单为普通文件，W1.4 补一条断言（目标为 symlink 时明确报错或按「覆盖链接」处理并记录）。
- **`S` 的定位**：用 `--ref-at-point` 取行 ref（`ebasecamp-ui-row-<组名>/<服务名>`），剥前缀后按 `/` 切出组名与服务名；point 不在服务行时 `user-error`「请把光标移到服务行」。
- **`:configs` 与旧 `:groups` 写入**：新增/移动配置只写组侧 `:configs`（AGENTS 不变量 9）；不写项目侧 `:groups`。
- **UI 表单**：字段 ref 必须在组件 `:setup` / `:bindings` 创建（不能在 `:render`）；保存失败时 dialog 不关闭、错误用 `etaf-label :variant 'danger`；dialog 不能同步返回，需要同步输入时用 `etaf-call-with-input`（minibuffer）。
- **`etaf-next-tick`**：写盘 + reload 是重活，放 `etaf-next-tick` 里执行，让「保存中」状态先渲染。
- **键位集合断言**：root keys 12 → 16，需同步改 `root-keys-complete` / `root-keys-final-set` / `help-data-includes-labels` 三条测试。
- **不触碰**：compose 渲染、docker 层、command 层、导入导出行为（除 import 的生成器改为 wrapper）。
- **删除语义**：只删清单定义与文件，不删容器；文案必须写明「容器需用 `D` 销毁」。
- **位置是 1-based**：`read` 前后 `(point)` 得到的是 buffer 位置，做字符串切片必须 `(1- pos)`；扫描器返回的 `:start`/`:end` 一律按位置使用，不预先转成下标。
- **`read` 自身会跳过 `;` 行注释**（实测 Emacs 31.1）：`forward-comment` 保留只为与既有实现口径一致，不是「否则必失败」的前置条件；`--read-forms` 里「read 不认 `;` 注释」的旧论断已修正。
- **`#| |#` 块注释走方案 A**：`forward-comment` 与 `read` 都不认（`invalid-read-syntax`），扫描器用 `search-forward "|#"` 跳过并记一条 note，`#|` 未闭合时 `user-error`。另注实测事实：**`load` 本身也不认块注释**，所以带块注释的清单 `ebasecamp-config-load` 会直接报错——扫描器的跳过是防御性能力，写入路径**不得生成**块注释。
- **事务判据 = 错误 message 差集**：语法错一次产生 2 条错误，因此不能硬编码条数、也不能用「`:errors` 为空」；差分只比较 `:message` 文本（`ebasecamp-config-error-messages`），避免既有错误因路径/行号漂移被误判为新增。
- **`etaf-dialog` 的文本不含内容**，值只能经 `etaf-ref` 读取；`:ref` 只接受 symbol / function / nil。dialog 不能同步返回输入，需要同步输入时用 `etaf-call-with-input`。

## 后续计划

- **v0.6 观测**：project 监控（默认不显示、快捷键唤出；CPU/内存）、日志查看（`docker logs --tail N`，follow 作为可选项）。
- **v0.5.1（候选）**：配置 `:services` 覆盖的表单编辑、`healthcheck` / `labels` / `networks` / `extra` 表单、服务增删（需先解决容器孤儿与配置维度，见 tech-debt #16 / #25）。
