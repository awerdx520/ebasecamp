# AGENTS.md — ebasecamp 仓库地图

## 项目概述

ebasecamp 是 Emacs 的 Docker 环境分组管理插件：定义可复用的基础组件组（**组**），在组内为具体项目声明一份**配置**（可覆盖端口/环境变量/卷），把配置关联到**项目**，在界面中按服务多选启动/停止/重启，并与项目 compose 文件做单向导入/导出。

三层结构：**组 → 配置 → 项目**。组是全局第一等对象（不依赖任何项目即可见）；配置挂在组侧、关联一个项目；项目文件只描述项目自身。

- UI 层使用 **etaf / etaf-ui**（Elisp UI 框架，在 Emacs buffer 内渲染）。
- 清单（组与项目定义）以 **Elisp** 形式持久化在 `~/.config/ebasecamp/`：`groups.el` 用 `:configs` 声明「本组给了哪些项目」（元素 `(配置名 :project 项目名 :services 覆盖)`），`projects/*.el` 只写 `:title` / `:root`，不写 `:groups`。
- 加载期物化：`ebasecamp-model-link-configs` 把每份配置转成 `(:group SYMBOL :scope SCOPE :service-overrides ALIST)` 组引用并入项目的 `groups` 槽，下游模块按既有 ref 语义读取。
- 清单是唯一事实源，compose 文件是由清单派生的生成物。
- 零外部依赖（除 etaf / etaf-ui）；YAML 只写不解析。

## 目录结构

| 路径 | 职责 | 状态 |
|---|---|---|
| `ebasecamp.el` | 包入口：`defcustom` 组、autoload 的 `ebasecamp` 命令、引导空态 | 已建（包入口，`Version: 0.6.0`） |
| `lisp/` | 实现模块：`ebasecamp-model.el`、`-config.el`、`-compose.el`、`-docker.el`、`-status.el`、`-data.el`、`-ui.el`、`-command.el`、`-import*.el`、`-export.el`、`ebasecamp-manifest.el`（清单文本层：form 定位 / 替换 / 生成器 / 写盘事务）、`ebasecamp-config-write.el`（字段映射 + 实体操作 + 引用扫描） | 已建，模块随批次 1–4 落地 |
| `test/` | ERT 测试套件 `*-tests.el` | 已建 |
| `test/fixtures/` | 测试用 fixture（实测的 docker / compose 输出片段） | 已建 |
| `docs/` | 文档与 ADR；`docs/adr/0001-architecture.org`（分层与同步模型）、`docs/adr/0002-group-configs.org`（组内配置与加载期物化）、`docs/adr/0003-ui-readonly-keymap.org`（UI buffer 只读化与 etaf Host 键位）、`docs/adr/0004-ui-layout-theme.org`（flex 三段式布局 / 主题两层 / 区域跳转 / 项目定位）、`docs/adr/0005-manifest-write.org`（清单写盘：局部写 + 事务 + 表单边界；扩展 ADR-0003 决策 6）、`docs/adr/0006-manifest-locate-compose-configs.org`（写盘跨文件定位 + compose 顶层 configs/secrets + 启动前预校验；扩展 ADR-0005 决策 1）、`docs/adr/0007-legacy-groups-and-project-directory.org`（旧 `:groups` 原位接管 + 迁移须用户确认 + compose 路径基准 `--project-directory` + 预校验文件存在性；修订不变量 9、扩展 ADR-0006 决策 3）、`docs/adr/0008-project-root-optional.org`（项目 `:root` 可选：写盘 / 界面 / 导出三处放开 + 无 root 的三条降级；新增不变量 16）、`docs/adr/0009-yaml-block-scalar.org`（多行字符串的 YAML 标量渲染：块标量 / 双引号转义 / 裸标量三层策略 + chomping 按末尾换行数）、`docs/adr/0010-ui-observability.org`（界面观测能力：按钮显示键 + hjkl 焦点移动 / 折叠 + `f` 按字母跳转，avy 为可选依赖）、`docs/adr/0011-session-teardown.org`（会话收尾：幂等 `--teardown-session` / `close` 顺序写死 / `--save-ui-state` 快照参数 / `on-unmounted` 单一路径）为架构决策 | 已建 |
| `openspec/` | 计划工件：`active/`（进行中）、`completed/`（归档）、`decisions.md`（决策日志）、`tech-debt.md`（技术债） | 已建 |
| `Makefile` | 验证入口：`check-parens` / `compile` / `test` / `test-avy` / `check` / `clean` | 已建 |
| `.gitignore` | 忽略字节编译产物与测试临时目录 | 已建 |
| `Readme.org` | 用户向说明（安装/快速开始/命令表） | 已建，内容待批次 5 完善 |

## 开发命令

| 命令 | 作用 |
|---|---|
| `make check` | 串联执行 `check-parens` + `compile` + `test`，任一失败即非零退出（提交前必跑） |
| `make check-parens` | 对 `*.el` 与 `lisp/*.el` 逐个做括号平衡检查 |
| `make compile` | 字节编译全部 `.el`，启用 `byte-compile-error-on-warn`（**零 warning 才算通过**） |
| `make test` | 用 ERT 运行 `test/*-tests.el`（`ert-run-tests-batch-and-exit t`） |
| `make test-avy` | 同 `make test`，load-path 追加 `-L $(STRAIGHT_BUILD)/avy` 后跑全量 ERT；2 条真实 avy 用例由 `skip-unless` 控制（`make test` 下 skip、本目标下真实执行） |
| `make clean` | 删除与 `.el` 同名的 `.elc` |

`ELPA_LOAD_PATH` 指向 straight 的 build 目录，使 batch 模式下能 `require` etaf 系列包：

```
STRAIGHT_BUILD    = $(HOME)/thomas-emacs/.local/straight/build-31.1
ELPA_LOAD_PATH    = -L $(STRAIGHT_BUILD)/etaf -L $(STRAIGHT_BUILD)/etaf-ui \
                    -L $(STRAIGHT_BUILD)/ebox -L $(STRAIGHT_BUILD)/ecss
LOAD_PATH         = -L . -L lisp $(ELPA_LOAD_PATH)
```

- `-L lisp` 让 `ebasecamp.el` 能直接 `require` `lisp/` 下的模块。
- 单跑 ERT 时先 `(setq load-prefer-newer t)`（或 `make clean`），否则会加载目录里残留的旧 `.elc`，看到的是上一次编译的代码。
- 所有验证均走 `emacs -Q --batch`，**不加载用户 init**；需要换 Emacs 版本或路径时用变量覆盖：`make check EMACS=/path/to/emacs STRAIGHT_BUILD=/path/to/build-XX.X`。
- 修改 `Makefile` 后至少跑一次 `make check`，确认四个子目标行为未变。
- **提交前跑 `make check && make test-avy`**：`make check` 是语法 / 编译 / 常规 ERT 门禁；`make test-avy` 补上 2 条真实 avy 用例（`make test` 下被 `skip-unless` 跳过，只有本目标才真正执行）。当前基线：`make test` = `Ran 495 tests, 493 results as expected, 0 unexpected, 2 skipped`；`make test-avy` = `Ran 495 tests, 495 results as expected, 0 unexpected`。

## 不变量清单

以下为**可机械检查的硬约束**，违反即视为缺陷（不是风格偏好）：

1. **compose 项目名**：shared 组固定 `ebc-shared`，per-project 固定 `ebc-<project>`；项目名与组名仅允许 `[a-z0-9_-]`。
2. **容器标签**：所有托管容器必须注入 `ebasecamp.managed=true`、`ebasecamp.project`、`ebasecamp.group`、`ebasecamp.service`、`ebasecamp.scope`；状态采集只认这些标签。
3. **网络**：所有容器加入 external network `ebasecamp`（shared 与 per-project 服务据此互通）。
4. **生成物位置**：compose 生成物位于 `~/.cache/ebasecamp/<project>/compose.yaml`，属可随时重建的派生产物，不得手工编辑。
5. **读取项目 compose 的唯一合法方式**：`docker compose config --no-interpolate --no-env-resolution --no-path-resolution --format json`。缺任一 flag 即违反——分别导致密钥明文展开或静默置空、`env_file` 内容被合并、相对路径被绝对化。
6. **清单只保存引用**：`${VAR}` 引用与相对路径原样保留；插件不读取、不打印、不落盘任何密钥值。
7. **`docker ps` 解析必须带 `--no-trunc`**：否则容器 ID 被截断，标签与状态归属判定失效。
8. **`config -q` 校验须同时检查退出码与 stderr**：退出码 0 不足以判定通过（存在 stderr 有输出但退出码为 0 的情形）。
9. **组与项目的关联只在组侧声明**（`:configs` 的 `:project`）；项目文件不再写 `:groups` 关联。旧写法保留兼容：当旧 `:groups` 与组侧 `:configs` 指向**同一项目同一组**时，以**组侧配置**为准原位接管（不报错，`:service-overrides` 取配置的值）；只有**两份以上组侧配置**指向同一项目同一组时才报 `ebasecamp-config-duplicate-group-ref`（容器标签无配置维度，服务名会撞），不做静默合并。
10. **shared 组至多 1 份配置，且该配置的 `:project` 必填**（宿主，仅作渲染上下文与容器标签归属，非业务绑定）；多份直接报加载错误。
11. **物化产物键名必须为 `:service-overrides`**（形态 `(:group SYMBOL :scope SCOPE :service-overrides ALIST)`）——写 `:services` 会导致覆盖被 `ebasecamp-model-resolve-services` / `ebasecamp-compose-render` / `ebasecamp-import` 静默丢弃。
12. **UI buffer 保持只读**（`ebasecamp-ui-mode`，派生 `special-mode` + `buffer-read-only t`），并以最外层 Host 的 `:key-scope 'local` 吞掉未绑定 printing key；写操作经界面表单（`S` / `E` / `M` / `X`）或 `e` 打开的清单文件，均须走 `ebasecamp-manifest--write-transaction`。
13. **UI 样式不得硬编码色值**——只允许出现在 palette / token 定义区（`ebasecamp-ui--palette-light` / `-palette-dark`）与 `defcustom` 默认值里，render 区一律走 `etaf-theme-token`；扫描范围由测试的 render 函数名清单界定（`render-region-has-no-literal-colors`）。
14. **清单写盘必须经 `ebasecamp-manifest--write-transaction`**（备份 → 原子写 → 仅新增错误才回滚 → 先检测外部修改）；回滚判据是**错误集差分**（`ebasecamp-config-error-messages` 的 `:message` 差集），不是「零错误」也不是条数；新增 / 删除项目走等价的差集回滚路径。
15. **生成物派发与预校验必须同用 `--project-directory <项目root>`**：`ebasecamp-command-compose-args` / `ebasecamp-docker-check-compose` 必须传同一个 root（shared 生成物取触发项目的 root），且 flag 位于 `-f FILE` 之后、子命令之前；任一缺失即「校验通过但启动炸」。
16. **项目 `:root` 可选**：为 nil 时不得参与项目定位（`ebasecamp-ui--project-for-directory` 跳过）、不得作为路径基准（派发不带 `--project-directory`，预校验对相对 `file:` 只给 warning 不失败）、导出必须显式选路径（无 `:root` 且无 `:export-file` 时交互式弹 `read-file-name`，非交互仍报错）。写盘层 `add-project` 接受 nil、`update-project` 用 `clear-root` 显式清空（`:root` 键真删，不得留 `:root nil`），空串与纯空白仍拒。

## 已知特性（勿当作缺陷）

| 现象 | 成因 | 判别口诀 |
|---|---|---|
| 界面内 `SPC` 等于 `RET`（checkbox 上勾选、按钮上按下） | `[32]` 属 `ebox--activation-keys`（节点级 char-property keymap，先于 etaf 键层），不是本插件绑定 | 想行级勾选用 `t`；`SPC` 是 ebox 的「激活当前控件」，不是勾选键 |
| 界面内未绑定的字母键无反应（含 `i`） | 最外层 Host 的 `:key-scope 'local` 在边界内吞掉未绑定 printing key（ADR-0003 决策 3） | 按 `?` 查键位；`C-x` / `M-x` / `C-g` / `ESC` 不受影响 |
| 派发时 docker 会额外读取 `<项目 root>/.env` | 派发与预校验统一注入 `--project-directory <项目 root>`（不变量 15），docker 因此把项目 root 当作 compose 项目目录，一并读取其 `.env` 参与插值（ADR-0007 决策 2，探针补证 5 实测） | 这是 docker 的既定行为，不是插件 bug；插件仍不读取、不打印、不落盘任何密钥值（不变量 6）。项目 root 下有 `.env` 时插值结果可能与加 flag 前不同 |

## 当前状态

- 进行中计划：**无**（`openspec/active/` 为空）
- 已归档：`openspec/completed/` 现含 v0.2 `2026-10-22-group-centric-ui.md`（组为中心 UI）、v0.3 `2026-10-23-ui-readonly-keymap.md`（UI 只读 + 完整键位）、v0.4 `2026-10-23-ui-layout-theme-nav.md`（布局、主题与导航）、v0.5 `2026-10-23-manifest-write-crud.md`（清单写操作）、v0.5.1 `2026-10-23-manifest-locate-compose-configs.md`（写盘跨文件定位 + compose 顶层 configs/secrets + 启动前预校验；X4.6 目检因现网清单无 `datarush-go` 未能按原计划执行，改以等价链路验证替代 PASS）、v0.5.2 `2026-10-24-legacy-groups-and-project-directory.md`（旧 `:groups` 原位接管 + 用户确认式写盘迁移 + `--project-directory` 路径基准 + 顶层 `configs`/`secrets` 文件存在性预校验；2026-10-24 全部批次完成，L3 目检 4 项通过）、**v0.5.3 `2026-10-26-project-root-optional.md`（项目 `:root` 可选：写盘层 `clear-root` / 界面 `--read-optional-path` / 导出 `--target-or-prompt` 三处放开 + ADR-0008 + 不变量 16；附带修复目检暴露的界面 scope 类型缺陷；**任务 4.2 用户目检由用户 2026-10-26 明确跳过**，导出视觉项由批次 4.1 的真实 docker 闭环 + 批次 3 的 ERT 替代覆盖；基线 436 → 452）**、**v0.5.4 `2026-10-26-yaml-block-scalar.md`（YAML 块标量：多行 `content:` 保真往返 + `|+` 拼接修复；基线 452 → 468；ADR-0009；技术债 #33 关闭）**、**v0.6 `2026-10-26-ui-observability.md`（界面观测能力：按钮显示键 + `hjkl` 焦点移动 / 树折叠 + `f` 按字母跳转（avy 可选依赖，未装降级 `completing-read`）；基线 468 → 479；ADR-0010；技术债 #43 / #44 / #45；**任务 4.2 用户目检由用户 2026-10-26 明确跳过**，交互正确性由 479/479 测试 + 批次 3 真实界面探针替代覆盖）** 与 **v0.6 端到端功能审查 `2026-10-28-e2e-functional-review.md`（11 个探针批次 + 1 次只读静态深审；blocking 1 可降级 / major 2 / minor 8 / 已知 7；报告 `docs/reports/2026-10-28-e2e-functional-review.org`）**、**v0.7 `2026-10-28-v0.7-review-fixes.md`（审查结论落地：B1 文档止血 5 处 + #47 失败路径透传 / #42 `:root` trim / #46 丢弃 compose 派生 `name:` / #29 幂等 teardown 四条修复 + #30/#38/#44 回归防线；基线 481 → 495，双口径 `make test` = 495/493 + 2 skipped、`make test-avy` = 495/495；ADR-0011；技术债 #42/#46/#47/#48 关闭，#29/#44 修复，#30/#38 部分修复，新增 #49–#53）**、`ebasecamp-m1-m3.md`（M1–M3 计划；T5.2 由 v0.2 的 E1 文档批次覆盖完成，计划关闭）。
- 测试基线：**495**（双口径 —— `make test` = `Ran 495 tests, 493 results as expected, 0 unexpected, 2 skipped`；`make test-avy` = `Ran 495 tests, 495 results as expected, 0 unexpected`；`compile` 零 warning、`check-parens` 通过 26 files）。演进：452 → 468（v0.5.4）→ 472（v0.6 批次 1 按钮键提示 +4）→ 474（批次 2 hjkl +2）→ 479（批次 3 avy 跳转 +5）→ 481（批次 4.4 补测 +2）→ **495（v0.7 +14：B1 +1 / B2 +2 / B3 +1 / B4 +4（3 条功能 + 1 条 code-review 守护）/ B5 +2 / B6 +2 / B7 +2）**；更早的 436 → 452 见 v0.5.3（批次 1 +6 / 批次 2 +5 / 批次 3 +3 / 批次 4.3 +2）。偶发抖动：`ebasecamp-docker-test-run-sync-captures-streams` 会偶发失败（真实子进程流捕获时序），判读「0 unexpected」前先复跑（技术债 #20）。
- 下一步：按 `docs/reports/2026-10-28-e2e-functional-review.org` 的分级清单取舍 —— **blocking 1 条（可降级）**：段级键 `s`/`x`/`r` 按焦点解析、失效时无提示，而 Readme 写的是 point 语义；**major 2 条**：导入持久化 compose 注入的 `name:`、预校验失败路径丢 `:preflight-warnings`；其余 minor 与已知项见报告与技术债 #46–#48。
- 决策日志：`openspec/decisions.md`
- 架构决策：`docs/adr/0001-architecture.org`（分层与同步模型）、`docs/adr/0002-group-configs.org`（组内配置与加载期物化）、`docs/adr/0003-ui-readonly-keymap.org`（UI buffer 只读化与 etaf Host 键位）、`docs/adr/0004-ui-layout-theme.org`（布局、主题与导航：flex 三段式 / 主题两层 / 宽度持久化 / 区域跳转 / 项目定位）、`docs/adr/0005-manifest-write.org`（清单写盘：局部写 + 事务 + 表单边界；扩展 ADR-0003 决策 6）、`docs/adr/0006-manifest-locate-compose-configs.org`（写盘跨文件定位 + compose 顶层 configs/secrets + 启动前预校验；扩展 ADR-0005 决策 1，并标注 ADR-0003 决策 6 中「`e` → groups.el」已过时）、`docs/adr/0007-legacy-groups-and-project-directory.org`（旧 `:groups` 与组侧 `:configs` 共存时原位接管 + 清理须用户确认 + compose 路径基准 `--project-directory` + 预校验顶层 `configs`/`secrets` 文件存在性；修订不变量 9、扩展 ADR-0006 决策 3，并记「跨文件迁移 = 两次事务 + 显式备份补偿，非单事务原子」）、`docs/adr/0008-project-root-optional.org`（项目 `:root` 可选：写盘层 `clear-root` / 界面 `--read-optional-path` / 导出 `--target-or-prompt` 三处放开，否决「`root = nil` 表示清空」与「导出校验改传项目 root」，新增不变量 16）、`docs/adr/0009-yaml-block-scalar.org`（多行字符串的 YAML 标量渲染：块标量 / 双引号转义 / 裸标量三层策略，chomping 按末尾换行数取 strip / clip / keep，否决「拒绝建模」「引入 YAML 库」「CRLF 改写为 LF」；补齐 ADR-0006 决策 3 的 `content:` 多行形态）、`docs/adr/0010-ui-observability.org`（界面观测能力：按钮显示键（`--button-key-hints` 只作渲染索引，键位事实源仍是 `--root-keys` / `--section-keys`）+ `j` / `k` 焦点移动 + `h` / `l` 树内折叠 + `f` 按字母跳转（avy 可选依赖，未装降级 `completing-read`）；否决 `etaf-set-direction-scheme 'vim`、为树条目改 etaf-ui 组件、把 `f` 做成写操作）、`docs/adr/0011-session-teardown.org`（会话收尾：幂等 `--teardown-session` / `close` 顺序写死 / `--save-ui-state` 快照参数 / `on-unmounted` 单一路径；补充 ADR-0003 决策 1 的收尾语义，并勘误 ADR-0007 决策 3 的 message/detail 笔误）
- 技术债：`openspec/tech-debt.md`

每批次完成必须更新计划文件的「## 当前状态」区块。

## 禁止行为

1. **UI 层直接拼 docker 命令**：UI 只能调用 `lisp/ebasecamp-command.el` 的接口，命令行拼接与进程管理只允许出现在 `ebasecamp-docker.el` / `ebasecamp-command.el`。
2. **写回项目 compose**：除用户显式触发的 `ebasecamp-export-compose` 外，插件不得修改项目仓库中的 compose 文件。
3. **把插值后的明文/绝对路径写入清单或生成物**：清单与生成物中只允许 `${VAR}` 引用与相对路径；导入时不得把 `--no-interpolate` 之外的输出写盘。
