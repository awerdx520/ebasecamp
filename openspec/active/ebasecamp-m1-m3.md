# ebasecamp — Emacs Docker 环境分组管理插件（M1–M3）

## 当前状态

- 阶段：Phase 3（Implement）· 批次 4 进行中
- 已确认：方案 V2 ✅（用户 2026-10-22 确认）、计划 ✅（用户 2026-10-22 确认）
- 已完成：批次 0、批次 1、批次 2、批次 3（T3.1–T3.6）、T4.1（导入映射）
- 下一步：T4.2 导入落盘语义
- 待用户确认：真实 Emacs 中目检 `M-x ebasecamp` 界面（T2.3 验收项）
- 修订记录：第一轮修 B1/B2 + M1–M5 + m1–m7；第二轮修导入落盘语义并实证三个 compose flag；T1.1 细化 volumes 为 plist；批次 1 修复 stale .elc 陷阱；T2.3 修正 data 层语义、check-parens 覆盖 test/*.el；T3.1 补强跨 scope 依赖；T3.4 toast 降级为 alert；T4.1 落地导入映射（JSON 走 hash-table 解析、不可表达端口进 extra）

## 目标

在 Emacs 中用 etaf 提供 Docker 分组管理能力：定义可复用基础组件组，把组绑定到项目（可覆盖端口/环境变量/卷），在界面中按服务多选启动/停止/重启，并与项目 compose 文件做单向导入/导出。

## 非目标

- 不做清单 ↔ 项目 compose 的双向同步
- 不做镜像构建/推送、Kubernetes、远程 `DOCKER_HOST`、容器内 exec（M4 及以后）
- 不做图形化清单编辑器（直接编辑 Elisp 清单文件）

## 设计决策

1. 分层：`model`/`config` → `compose`/`import`/`export` → `docker` → `command`/`status` → `ui`（详见 ADR-0001）
2. 清单是唯一事实源，compose 是派生产物，生成于 `~/.cache/ebasecamp/<project>/compose.yaml`
3. 零外部依赖（除 etaf 0.2.3 / etaf-ui 0.1.3）；YAML 只写不解析，读取走 `docker compose config --no-interpolate --no-env-resolution --no-path-resolution --format json`
4. 复用语义由组定义 `:scope shared | per-project` 声明；shared 组固定项目名 `ebc-shared`
5. 所有托管容器注入 `ebasecamp.*` 标签，状态采集据此归属
6. 状态采集：`docker ps -a --no-trunc --filter label=ebasecamp.managed=true --format '{{json .}}'`
7. 校验：`docker compose config -q`，判据为「退出码 + stderr」双条件
8. 单向同步：`ebasecamp-import-compose`（迁移）与 `ebasecamp-export-compose`（部署），导出默认不覆盖已有文件
9. **安全硬约束**：读取任何项目 compose 必须用 `--no-interpolate --no-env-resolution --no-path-resolution`，否则分别导致：`${SECRET}` 被替换为明文或静默空串（退出码仍 0）、env_file 内容合并进输出、相对路径被绝对化

## 数据模型（实现约定）

```elisp
(cl-defstruct ebasecamp-service name image command entrypoint environment
  labels ports volumes healthcheck depends-on networks working-dir user
  restart extra)
(cl-defstruct ebasecamp-group name title scope services)
(cl-defstruct ebasecamp-project name title root groups shared-network export-file)
```

- `ports` 元素：`(PUBLISHED . TARGET)`，均为整数
- `environment`/`labels` 为 alist，值中的 `${VAR}` **原样保留**
- `volumes` 元素：plist `(:source S :target T :type volume|bind [:read-only t])`
- 未识别字段进 `extra`，导出时原样回写

## 导入映射规则（T4.1 的前置 spec）

读取命令固定为：

```
docker compose -f <file> config --no-interpolate --no-env-resolution --no-path-resolution --format json
```

| compose JSON 字段 | 映射到清单 | 规则 |
|---|---|---|
| 顶层 `name` | 忽略 | 执行时以 `-p ebc-<project>` 显式指定 |
| `services.<name>.image` | `:image` | 原样 |
| `services.<name>.command` | `:command` | 数组 → 列表 |
| `services.<name>.entrypoint` | `:entrypoint` | 值为 null 时忽略；数组 → 列表 |
| `services.<name>.environment` | `:environment` | map → alist；`${VAR}` 原样保留（依赖 `--no-interpolate`） |
| `services.<name>.labels` | `:labels` | map → alist；剔除 `ebasecamp.*` 与 `com.docker.compose.*` |
| `services.<name>.ports` | `:ports` | `{target: 整数, published: 字符串}` → `(string-to-number published . target)` |
| `services.<name>.volumes` | `:volumes` | `type=bind` → 宿主路径 + `:bind t`；`type=volume` → 命名卷 |
| `services.<name>.networks` | `:networks` | 保留原网络名 |
| `services.<name>.healthcheck` | `:healthcheck` | 存在时保留 |
| `services.<name>.depends_on` | `:depends-on` | 两种形态（列表/对象）归一为服务名列表 |
| 其余未识别字段 | `:extra` | 原样保存供导出回写 |

**字段可缺省**：`--no-interpolate` 输出的模型比常规 `config` 缺省更多字段（实测无 `command: null`、`entrypoint: null`、`ipam: {}`）。导入层必须按「字段可缺省」处理，不得把缺失当成语义差异。

导入结果：所有服务落入该项目的 `app` 组（per-project scope），用户可后续在清单中重组成可复用组。

## 任务

### 批次 0：仓库基础设施

- [x] T0.1 创建目录骨架 `lisp/`、`test/`、`docs/adr/`、`openspec/active/`、`openspec/completed/`
      （依赖：无）验收：目录存在，本计划位于 `openspec/active/`
- [x] T0.2 `.gitignore`：`*.elc`、`.cask/`、`.eask/`、`*~`、`.#*`
      （依赖：无）验收：`git status --porcelain` 不显示 .elc
- [x] T0.3 `Makefile`：`check-parens`、`compile`（`byte-compile-error-on-warn`）、`test`（ERT）、`check`（串联三者）
      （依赖：T0.5（产出 `ELPA_LOAD_PATH` 值））验收：`make check` 可运行并在失败时非零退出
- [x] T0.4 `AGENTS.md` 仓库地图：目录职责、开发命令、不变量清单（命名/标签/网络/生成物/安全约束）
      （依赖：无）验收：引用的路径全部真实存在
- [x] T0.5 探测 `etaf`/`etaf-ui` 的 batch 加载路径写入 `Makefile` 的 `ELPA_LOAD_PATH`
      （依赖：无）验收：`emacs -Q --batch` 下 `(require 'etaf)` 与 `(require 'etaf-ui)` 均成功

### 批次 1：M1 数据层与 compose 生成

- [x] T1.1 `lisp/ebasecamp-model.el`：三个 struct、`ebasecamp-define-group`/`-project` 宏、字段校验、项目覆盖合并
      （依赖：无）验收：ERT 覆盖 合法定义、未知字段拒绝、scope 非法值拒绝、覆盖合并结果
- [x] T1.2 `lisp/ebasecamp-config.el`：从 `ebasecamp-config-directory` 加载 `groups.el` 与 `projects/*.el`；目录不存在时**不自动创建**，返回空清单并置 `bootstrap-needed` 标记；语法错/重复组名收集为错误列表不中断
      （依赖：T1.1）验收：ERT 覆盖 目录缺失、语法错、重复组名、加载顺序、bootstrap 标记
- [x] T1.3 `lisp/ebasecamp-compose.el`：服务视图（组 + 项目覆盖）→ compose plist → YAML 文本；项目命名（`ebc-<p>` / `ebc-shared`）、标签注入、external network 附加
      （依赖：T1.1）验收：ERT 快照覆盖 单服务/多服务/端口覆盖/`${VAR}` 原样保留/标签注入；生成物通过 `docker compose config -q`（L2）
- [x] T1.4 `lisp/ebasecamp-docker.el`：`make-process` 异步封装（回调 + 超时 + kill）；`config -q` 校验（退出码 + stderr 双判据）；`ps --no-trunc` JSON 行解析（Labels 逗号串按 `ebasecamp.*`/`com.docker.compose.*` 前缀解析）；错误归一化（含 `ebasecamp-docker-permission`）；`docker compose version` 启动检测与版本警告
      （依赖：无）验收：ERT 用 fixture 覆盖 ps 解析（截断防护、多标签）、校验失败归类、权限错误归类、版本不符警告
- [x] T1.5 ERT 测试套件落地：`test/ebasecamp-model-tests.el`、`test/ebasecamp-config-tests.el`、`test/ebasecamp-compose-tests.el`、`test/ebasecamp-docker-tests.el` + `test/fixtures/`
      （依赖：T1.1–T1.4）验收：`make test` 全绿，fixture 为实测输出
- [x] T1.6 L2：生成含 alpine 服务的 compose 并 `docker compose config -q` 通过（不起容器）；同时验证生成物中 `${VAR}` 未被插值
      （依赖：T1.3、T1.4）验收：命令输出为零 stderr、退出码 0；并断言生成物文本中含 `${VAR}` 字面量（未被插值）

### 批次 2：M1 只读界面

- [x] T2.1 `lisp/ebasecamp-status.el`：3s 轮询（`ebasecamp-status-refresh-interval` defcustom）、状态归一化为 `(project group service state health ports)`、仅在 UI 挂载时启停定时器
      （依赖：T1.4）验收：ERT 覆盖状态聚合与定时器生命周期（mock docker 层）
- [x] T2.2 `lisp/ebasecamp-data.el`：把状态层适配为 ETAF Data 层 —— `etaf-data-source` 的 `:load` 返回状态快照，`etaf-data-controller` 由 UI 持有，轮询后 `etaf-data-load`，卸载时 `etaf-data-stop`
      （依赖：T2.1）验收：ERT 覆盖 load 返回结构、reload 语义、stop 清理
- [x] T2.3 `lisp/ebasecamp-ui.el`：etaf 主界面 —— 项目 `etaf-tabs`；组用**扁平** `etaf-tree`（叶子即组，聚合状态）；服务 `etaf-data-grid`（`etaf-checkbox` 多选、`etaf-badge` 状态、`etaf-empty` 空态；加载态用 `etaf-data-grid` 的 `:loading-label`）；写操作反馈（toast）推迟到 T3.4 错误链路一并实现
      （依赖：T2.2）验收：batch 中 `etaf-mount` 到临时 buffer 后断言 `buffer-string` 含预期项目名/服务名/状态文案（可机械验证），并在真实 Emacs 中人工目检一次
- [x] T2.4 `ebasecamp.el`：包入口、`defcustom` 组（`ebasecamp-config-directory`、`ebasecamp-cache-directory`、`ebasecamp-status-refresh-interval`）、autoload `ebasecamp`；配置目录缺失时 UI 显示引导空态 + `ebasecamp-create-sample-config` 命令
      （依赖：T2.3）验收：`make compile` 零 warning；目录缺失场景 ERT 断言引导文案；`ebasecamp-create-sample-config` 在临时目录实际生成可被 T1.2 加载的示例清单
- [x] T2.5 L3：真实容器（alpine）只读展示，UI 状态与 `docker ps` 一致；结束后无残留
      （依赖：T2.4）验收：实际对比容器列表与 UI 行数/状态

### 批次 3：M2 生命周期

- [x] T3.1 `lisp/ebasecamp-command.el`：`start`/`stop`/`restart`/`down`，接收服务集合；shared 组路由到 `_shared` 生成物与 `ebc-shared`；`down` 不带 `-v`
      （依赖：T1.6）验收：ERT 用 mock 断言命令行、目标项目名、服务集合顺序
- [x] T3.2 并发与操作态：每个项目同时只允许一个生命周期进程（in-flight ref/锁），操作进行中 UI 操作条 `:disabled`，完成或失败后恢复；重复点击不得起第二个进程
      （依赖：T3.1、T2.3）验收：ERT 模拟双击断言仅一次 dispatch；UI 中操作期间按钮不可激活
- [x] T3.3 端口冲突检测：启动前对选中服务的 `ports` 做两类检查 —— ①清单/项目内重复；②宿主端口占用（`(make-network-process :server t)` bind 探测，可注入 fake binder 测试）；冲突时不启动并给出具名提示
      （依赖：T3.1）验收：ERT 覆盖 冲突命中/不冲突/探测失败降级（告警但允许继续）
- [x] T3.4 错误链路：命令失败时 stderr 归一化进 `ebasecamp-docker-error`，UI 用 `etaf-alert` 展示可展开详情；权限错误（docker socket）单独归类并给出修复提示
      （依赖：T1.4、T3.1）验收：ERT 断言 4 类错误的分类结果；UI batch 断言 alert 文案出现
- [x] T3.5 L3 起停冒烟：真实起停 alpine 组（启动→状态回读→停止→`down`），结束后无残留容器/网络
      （依赖：T3.1–T3.4）验收：`docker ps -a --filter label=ebasecamp.managed=true` 在清理后为空
- [x] T3.6 L3 shared ↔ per-project 网络互通：建一个 shared 组（alpine 常驻）与一个 per-project 服务，从 per-project 容器内通过服务名解析并连通 shared 服务（`getent hosts` + TCP 连接或 `nc`）
      （依赖：T3.5）验收：从容器内成功解析并连通；失败即视为 shared 语义不可用，必须修复后重跑

### 批次 4：M3 导入导出

- [x] T4.1 `lisp/ebasecamp-import.el`（纯映射，无 IO）：把 `config --no-interpolate --no-env-resolution --no-path-resolution --format json` 的输出转成 `ebasecamp-project` 结构，按「导入映射规则」实现；`env_file` 保留为相对路径引用，不读取其内容
      （依赖：T1.5）验收：ERT 用实测 JSON fixture 断言全部映射规则 + 字段缺省容忍 + `${VAR}` 原样保留 + `env_file` 仅留相对路径
      （已完成：API 为 `ebasecamp-import-parse` / `-parse-json` / `-suggest-name` 与访问器 `-service-plists` / `-service-plist`；服务定义暂存于组引用 `app` 的 `:service-overrides`，供 T4.2 物化；fixture 为 `test/fixtures/compose-config-noint.{yaml,json}`，ERT 23 项）
- [ ] T4.2 `lisp/ebasecamp-import-apply.el`（落盘语义）：把 T4.1 的项目结构写成 `ebasecamp-define-project` 形式的文件 `~/.config/ebasecamp/projects/<name>.el`；项目名默认取 compose 顶层 `name`，缺失时取 compose 文件父目录名，交互式可编辑；项目名须匹配 `[a-z0-9_-]+` 否则拒绝；目标已存在时非交互直接报错、交互式 `y-or-n-p` 确认后才覆盖；写入后必须能被 T1.2 成功加载
      （依赖：T4.1、T1.2）验收：ERT 覆盖 默认名推导（含缺失回退）、非法名拒绝、已存在拒绝、确认后覆盖、写后可加载
- [ ] T4.3 `lisp/ebasecamp-export.el`：清单 → 项目 compose 文件（默认 `<project-root>/docker-compose.ebasecamp.yaml`，可由项目 `:export-file` 覆盖），带生成头注释（事实源路径 + 重新生成命令）；目标存在时非交互报错、交互式提示「换路径 / 覆盖（二次确认） / 取消」；落盘前 `config -q` 自校验
      （依赖：T1.6）验收：ERT 覆盖 默认文件名、`:export-file` 覆盖、已存在时三种分支、导出往返（export → `config --no-interpolate --no-env-resolution --no-path-resolution --format json` → 逐字段语义等价）、导出物不含明文密钥
- [ ] T4.4 UI 入口：导入向导（选文件 → 预览服务列表 → 编辑项目名 → 落盘 → 反馈）与导出按钮（选项目 → 目标路径 → 冲突提示 → 反馈）
      （依赖：T2.3、T4.2、T4.3）验收：batch 渲染断言入口存在；真实 Emacs 中完成一次导入与一次导出，并断言 `~/.config/ebasecamp/projects/` 下落盘文件存在且可加载
- [ ] T4.5 ERT 安全断言：导入含 `${FAKE_SECRET}` 与 `env_file` 的 fixture，断言清单保留引用、不出现明文、`env_file` 为相对路径；导出物同样不含明文
      （依赖：T4.1、T4.3）验收：断言匹配 `${FAKE_SECRET}`、不含探针值、`env_file` 路径不以 `/` 开头
- [ ] T4.6 L3 闭环：真实项目 compose → 导入（项目名交互）→ 启动 → 停止 → 导出 → `config -q` 通过
      （依赖：T4.1–T4.5）验收：全链路成功；`~/.config/ebasecamp/projects/<name>.el` 存在且可加载；清理干净

### 批次 5：文档

- [ ] T5.1 `Readme.org`：安装（straight/load-path）、快速开始、命令表、清单示例
      （依赖：T4.6）
- [ ] T5.2 `docs/architecture.org`、`docs/user-guide.org`、`docs/compose-generation.org`、`docs/troubleshooting.org`
      （依赖：T4.6）验收：`compose-generation.org` 的映射规则与本计划一致；`troubleshooting.org` 覆盖权限/端口冲突/`config -q` 失败/版本不符
- [ ] T5.3 `CHANGELOG.md` 首版条目（依赖：T5.1、T5.2）

## 依赖关系

- 批次 0 → 1 → 2 → 3 → 4 → 5 严格串行；批次内依赖见各任务 `（依赖：…）`；批次 4 的任务编号为 T4.1–T4.6
- T4.1 的 spec 已内置于本计划「导入映射规则」节，不再依赖批次 5 文档

## 文档清单

| 文档 | 本计划触发的更新 |
|---|---|
| `Readme.org` | 安装、首次使用、命令表、清单示例 |
| `docs/architecture.org` | 分层、不变量（命名/标签/网络/生成物位置/安全约束） |
| `docs/user-guide.org` | 清单字段语义、导入/导出工作流、首次配置引导 |
| `docs/compose-generation.org` | 导入映射表、导出规则、Compose 5.6.0 实测约束 |
| `docs/troubleshooting.org` | 权限错误、端口冲突、`config -q` 失败、版本不符 |
| `CHANGELOG.md` | 用户可感知变更 |
| `openspec/decisions.md` + `docs/adr/0001-architecture.org` | 架构决策 |
| `AGENTS.md` | 仓库地图与开发命令（T0.4） |

## 验证标准

- **L1**：`make check-parens` + `make compile`（`byte-compile-error-on-warn`，零 warning）
- **L2**：`make test`（ERT 全绿）+ 生成物 `docker compose config -q` 通过（含 stderr 检查）+ 导入导出往返语义等价
- **L3**：真实容器冒烟（alpine、shared 互通、导入导出闭环），每批次结束执行并清理
- UI 验证：batch 中 `etaf-mount` + `buffer-string` 断言（可机械验证）为主，人工目检为辅
- 容器优先：仓库若引入 `make test-in-docker`，L2 优先走容器

## 注意事项

- Compose 版本 **5.6.0**（实测）：`--no-interpolate` 支持的模型字段比常规 `config` 更少；`published` 为字符串；常规输出 `entrypoint: null` 恒出现（`--no-interpolate` 下不出现）
- **禁止**用缺少 `--no-interpolate` / `--no-env-resolution` / `--no-path-resolution` 任一参数的 `config` 读取项目 compose（分别导致密钥明文展开或静默置空、env_file 内容合并、相对路径绝对化）
- `docker ps` 解析必须 `--no-trunc`；`Labels` 是逗号串，按已知前缀解析
- `config -q` 退出码不足以判错，必须同时检查 stderr
- `up -d --dry-run` 输出为成功语态，不能作为「已执行」判据
- 密钥安全：清单只允许 `${VAR}` 引用；插件不读取、不打印、不落盘任何密钥值
- 每次批次完成必须更新本文件「当前状态」区块
- 禁止 UI 层直接拼 docker 命令；禁止写回项目 compose（除显式 export）
