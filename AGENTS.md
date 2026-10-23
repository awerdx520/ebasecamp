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
| `ebasecamp.el` | 包入口：`defcustom` 组、autoload 的 `ebasecamp` 命令、引导空态 | 规划中（批次 2 / T2.4 产出） |
| `lisp/` | 实现模块：`ebasecamp-model.el`、`-config.el`、`-compose.el`、`-docker.el`、`-status.el`、`-data.el`、`-ui.el`、`-command.el`、`-import*.el`、`-export.el` | 已建，模块随批次 1–4 落地 |
| `test/` | ERT 测试套件 `*-tests.el` | 已建 |
| `test/fixtures/` | 测试用 fixture（实测的 docker / compose 输出片段） | 已建 |
| `docs/` | 文档与 ADR；`docs/adr/0001-architecture.org`（分层与同步模型）、`docs/adr/0002-group-configs.org`（组内配置与加载期物化）、`docs/adr/0003-ui-readonly-keymap.org`（UI buffer 只读化与 etaf Host 键位）、`docs/adr/0004-ui-layout-theme.org`（flex 三段式布局 / 主题两层 / 区域跳转 / 项目定位）为架构决策 | 已建 |
| `openspec/` | 计划工件：`active/`（进行中）、`completed/`（归档）、`decisions.md`（决策日志）、`tech-debt.md`（技术债） | 已建 |
| `Makefile` | 验证入口：`check-parens` / `compile` / `test` / `check` / `clean` | 已建 |
| `.gitignore` | 忽略字节编译产物与测试临时目录 | 已建 |
| `Readme.org` | 用户向说明（安装/快速开始/命令表） | 已建，内容待批次 5 完善 |

## 开发命令

| 命令 | 作用 |
|---|---|
| `make check` | 串联执行 `check-parens` + `compile` + `test`，任一失败即非零退出（提交前必跑） |
| `make check-parens` | 对 `*.el` 与 `lisp/*.el` 逐个做括号平衡检查 |
| `make compile` | 字节编译全部 `.el`，启用 `byte-compile-error-on-warn`（**零 warning 才算通过**） |
| `make test` | 用 ERT 运行 `test/*-tests.el`（`ert-run-tests-batch-and-exit t`） |
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
- 修改 `Makefile` 后至少跑一次 `make check`，确认三个子目标行为未变。

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
9. **组与项目的关联只在组侧声明**（`:configs` 的 `:project`）；项目文件不再写 `:groups` 关联（旧写法保留兼容，但同一项目对同一组重复引用一律加载报错 `ebasecamp-config-duplicate-group-ref`，不做静默合并）。
10. **shared 组至多 1 份配置，且该配置的 `:project` 必填**（宿主，仅作渲染上下文与容器标签归属，非业务绑定）；多份直接报加载错误。
11. **物化产物键名必须为 `:service-overrides`**（形态 `(:group SYMBOL :scope SCOPE :service-overrides ALIST)`）——写 `:services` 会导致覆盖被 `ebasecamp-model-resolve-services` / `ebasecamp-compose-render` / `ebasecamp-import` 静默丢弃。
12. **UI buffer 必须只读**（`ebasecamp-ui-mode`，派生 `special-mode` + `buffer-read-only t`），并以最外层 Host 的 `:key-scope 'local` 吞掉未绑定 printing key；写操作只允许经 `e` 打开的清单文件（`groups.el`）。
13. **UI 样式不得硬编码色值**——只允许出现在 palette / token 定义区（`ebasecamp-ui--palette-light` / `-palette-dark`）与 `defcustom` 默认值里，render 区一律走 `etaf-theme-token`；扫描范围由测试的 render 函数名清单界定（`render-region-has-no-literal-colors`）。

## 已知特性（勿当作缺陷）

| 现象 | 成因 | 判别口诀 |
|---|---|---|
| 界面内 `SPC` 等于 `RET`（checkbox 上勾选、按钮上按下） | `[32]` 属 `ebox--activation-keys`（节点级 char-property keymap，先于 etaf 键层），不是本插件绑定 | 想行级勾选用 `t`；`SPC` 是 ebox 的「激活当前控件」，不是勾选键 |
| 界面内未绑定的字母键无反应（含 `i`） | 最外层 Host 的 `:key-scope 'local` 在边界内吞掉未绑定 printing key（ADR-0003 决策 3） | 按 `?` 查键位；`C-x` / `M-x` / `C-g` / `ESC` 不受影响 |

## 当前状态

- 进行中计划：**无**。v0.2 `2026-10-22-group-centric-ui.md`（组为中心 UI）、v0.3 `2026-10-23-ui-readonly-keymap.md`（UI 只读 + 完整键位）、v0.4 `2026-10-23-ui-layout-theme-nav.md`（布局、主题与导航）三份计划已归档到 `openspec/completed/`（2026-10-23；三份计划的用户目检均由用户在 v0.4 期间的实机使用确认）。
- 已归档：`openspec/completed/` 现含上述三份 + `ebasecamp-m1-m3.md`（M1–M3 计划；T5.2 由 v0.2 的 E1 文档批次覆盖完成，计划关闭）。
- 测试基线：**358**（`make check` 全绿：`make test` 358 expected / 0 unexpected、`compile` 零 warning、`check-parens` 通过；357 → 358 来自代码审查修复新增用例 `ebasecamp-ui-test-split-ratio-defcustom-out-of-range-clamped`）。
- 下一步：v0.5（写操作）与 v0.6（观测）待规划；遗留技术债见 `openspec/tech-debt.md` #29 / #30。
- 决策日志：`openspec/decisions.md`
- 架构决策：`docs/adr/0001-architecture.org`（分层与同步模型）、`docs/adr/0002-group-configs.org`（组内配置与加载期物化）、`docs/adr/0003-ui-readonly-keymap.org`（UI buffer 只读化与 etaf Host 键位）、`docs/adr/0004-ui-layout-theme.org`（布局、主题与导航：flex 三段式 / 主题两层 / 宽度持久化 / 区域跳转 / 项目定位）
- 技术债：`openspec/tech-debt.md`

每批次完成必须更新计划文件的「## 当前状态」区块。

## 禁止行为

1. **UI 层直接拼 docker 命令**：UI 只能调用 `lisp/ebasecamp-command.el` 的接口，命令行拼接与进程管理只允许出现在 `ebasecamp-docker.el` / `ebasecamp-command.el`。
2. **写回项目 compose**：除用户显式触发的 `ebasecamp-export-compose` 外，插件不得修改项目仓库中的 compose 文件。
3. **把插值后的明文/绝对路径写入清单或生成物**：清单与生成物中只允许 `${VAR}` 引用与相对路径；导入时不得把 `--no-interpolate` 之外的输出写盘。
