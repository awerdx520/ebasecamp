# 变更日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/) 与 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式。

## [0.2.0] - 2026-10-23

组为中心的界面与「组内配置」模型：关联方向由「项目 → 组」反转为「组 → 配置 → 项目」，旧写法继续可用。

### 新增

- **组内配置模型（`:configs`）**：`ebasecamp-define-group` 新增 `:configs` 槽，每项 `(配置名 :project 项目名 [:services 覆盖...])`；配置名组内唯一、`:project` 必填、配置的 scope 恒等于组定义 scope（不提供 `:scope` 覆盖）。配套访问器 `ebasecamp-model-group-configs` / `ebasecamp-model-config` / `ebasecamp-model-config-project`，`ebasecamp-group` 增加 `configs` 槽。
- **加载期物化**：`ebasecamp-model-link-configs` 把组侧配置转换成与旧写法同构的组引用 `(:group SYMBOL :scope SCOPE :service-overrides ALIST)` 并入项目的 groups 槽，渲染 / 命令 / 数据 / 导出 / 界面五个读取点零改动。加载顺序固定为「清空注册表 → `groups.el` → `projects/*.el` → 项目引用校验 → 物化 → 汇总错误」。
- **物化期校验**：`:project` 缺失、指向未定义项目、同项目同组多引用、shared 组多份配置、覆盖了组内不存在的服务 —— 五类错误在加载期报出，逐项记录且不中断其余配置。
- **组为中心的主界面**：顶栏（标题 + 「N 组 · M 配置」统计 + 刷新）、左栏 `etaf-tree`（组 → 配置两级，无配置组显示「0 配置」）、右栏每份配置一段 `etaf-panel`（段头两行 = `配置名 → 项目` + scope 徽标 + running/total 徽标，第二行 = 启动/停止/重启三按钮；段体 = `etaf-table` 服务表，首列勾选框）、底栏三按钮、`etaf-alert` 提示区。组是全局对象，不依赖任何项目即可见。
- **`ebasecamp-data-group-instances`**：按组装配「组 × 项目实例」（`:config` / `:project` / `:project-title` / `:scope` / `:records`），shared 实例的状态按 `(:scope "shared" AND :group)` 匹配 —— 容器标签记的是发起项目，按 project 过滤会漏。
- **段内派发**：段内按钮只对*该段自己的* `:project` 派发到 `ebasecamp-command-run`，同组多实例不串段；`busy` 期间按钮在渲染期求值为禁用，函数层重复派发也被拒绝。
- **底栏与选项目**：底栏 = 导入 compose / 导出 compose / 销毁环境三个 ghost 按钮；导出与销毁改为 `completing-read` 选项目，销毁加 `etaf-dialog` 二次确认（文案点名项目、说明不删卷、shared 不受影响），确认后走 `docker compose down`（不带 `-v`）。新增交互命令 `ebasecamp-ui-destroy-environment`。
- **导入落盘改用组内配置写法**（D1–D2）：生成的清单为「一份 `ebasecamp-define-group`（`:services` + `:configs ((<名> :project <名>))`）+ 一份 `ebasecamp-define-project`（`:title` / `:root`，不写 `:groups`）」，注释头对齐 `ebasecamp-create-sample-config` 模板；写后自校验新增「加载零错误 + 项目已注册 + 组内配置已物化出带 `:service-overrides` 的引用」，失败仍回滚。
- **新清单示例与文档批次**：`docs/architecture.org` / `docs/user-guide.org` / `docs/compose-generation.org` 按 v0.2 重写，新建 `docs/troubleshooting.org`（十条按「现象 / 原因 / 排查命令 / 修法」四段式）。

### 变更

- **清单关联方向反转**：项目归属写在组侧 `:configs`，项目定义不再需要 `:groups`（旧写法仍兼容，视作匿名配置、配置名 = 组名）。
- **界面骨架**：由「项目 tabs / 组列表 / 服务表 / 操作条」四区改为「顶栏 / 左栏组树 / 右栏配置段 / 底栏 / 提示区」；删除项目 tab、操作条与「当前项目」兼容层；勾选状态按「组名/服务名」记录并在段间共享。
- **导出与销毁环境**：从依赖「当前项目」改为 `completing-read` 选项目。
- **`ebasecamp-data` 收敛为纯装配层**（C6）：删除 `ebasecamp-data-source` / `-controller` / `-refresh` / `--load` / `--query-records` / `--slice` / `--filter` / `--field-equal` / `--all-records` 共 9 个 ETAF Data 适配定义，模块不再 `require etaf`、不做加载/查询/分页/轮询；`ebasecamp-data-project-records` / `ebasecamp-data-group-instances` 等纯装配 API 保留（文件 421 → 300 行）。
- **YAML 映射判据收紧**（D5）：`ebasecamp-compose--mapping-p` 由 `(and (consp value) (consp (car value)))` 收紧为额外要求 `(stringp (caar value))`，修复「元素为 alist 的列表」被误判走映射分支。
- **入口文件注释与版本号**：`ebasecamp.el` 版本 0.1.0 → 0.2.0，Commentary 由「项目 → 组 → 服务」改述为「组 → 配置 → 项目」，`ebasecamp-ui.el` 的 Commentary 与行内注释同步删除已删符号（`ebasecamp-ui-run-action` / `ebasecamp-ui-current-project` / 操作条 / 项目 tab / `etaf-data-grid`）的叙述。

### 修复

- **导出含绑定宿主 IP 的端口失败**（D5，技术债 #21 阻断级）：`127.0.0.1:18097:80` 这类端口导入后进 `:extra` 的 ports 桶，渲染被误判为映射而产出 `host_ip:` 垃圾键，`config -q` 报错；收紧判据后输出合法长语法（`- host_ip: … / published: … / target: …`）。
- **`env_file` 往返失败**（D4，技术债 #21 同源）：清单里 `env_file` 为 volumes 语义（`((:source PATH :type env))`）时导出被 compose 拒绝（`services.<name>.env_file must be a string`）；`ebasecamp-import--env-file` 归一为路径字符串列表（`("./api.env")`）后往返通过。
- **`ports:` / `volumes:` 重复键**（D6，技术债 #23 阻断级）：同一服务既有可表达端口又有 `:extra` ports 桶（或既有 bind 卷又有 tmpfs 卷）时渲染出两个同名键，`docker compose config -q` 报 `mapping key "ports" already defined`；`ebasecamp-compose--service-body` 改为合并 `:extra` 同名桶与显式项、每类只输出一个键。
- **旧清单里同一项目重复引用同一组被静默取首个**：改为加载期报 `ebasecamp-config-duplicate-group-ref`（见「兼容性」）。
- **v0.1 清单在组视图里完全不可见（C8）**：`ebasecamp-data-group-instances` 原先只在组侧有 `:configs` 时返回实例，v0.1 清单（关联只写在项目侧 `:groups`）因此渲染出「N 组 · 0 配置」的空壳，且打开界面时没有任何 `message`，容易被误判为命令失灵。现在组无 `:configs` 时按项目名升序回退装配「旧写法实例」（`:legacy` t、`:config` nil，记录仍与 `ebasecamp-data-project-records` 同源）：组节点显示 `MySQL  (旧 · 1 项目)`、右栏段头显示 `（旧写法）→ 项目` 并在组标题下给出迁移提示，既无配置也无关联时显示 `(未关联)`；`ebasecamp` 命令与 `M-x ebasecamp-ui-open` 打开界面时用 `message` 回报「N 组 · M 配置（K 个旧写法关联）」，据此可区分「清单是旧写法」与「命令没生效」。
- **`M-x ebasecamp` 报「命令不存在」**（批次 A）：根因是运行中的 Emacs 里没有加载该包 —— straight recipe 指向远程上游且 build 目录晚于 daemon 启动生成。recipe 改指本地仓库（`:local-repo` + `:files ("*.el" "lisp/*.el")`）并重建 build 后恢复可用。

### 移除

- 项目 tab、操作条（生命周期一行 + 导入导出一行）及其按钮构造函数。
- 旧项目视图接口：`ebasecamp-ui-run-action`、`ebasecamp-ui-current-project`、`--run-action`、`--action-button`、`--action-bar`、`--bar-button`、`--section-dispatch`、`--select-project`、`--group-items`、`--project-running`、`--tab-items`，以及会话的 `controller` 与 `project-ref` 槽。
- `ebasecamp-data` 的 ETAF Data 适配层（9 个定义）与对应的 `(require 'etaf)`。
- `ebasecamp-import--imported-group-title`（导入组标题改为按名生成）。

### 兼容性

- **旧 `:groups` 写法可用**：视作匿名配置（配置名 = 组名），引用级 `:scope` / `:services` 覆盖语义不变；新旧写法可以共存。
- **重复引用同组改为报错**：同一项目在 `:groups` 里重复引用同一组、或 `:groups` 与组侧 `:configs` 指向同一项目，现在加载即报 `ebasecamp-config-duplicate-group-ref`（v0.1 是静默取首个、第二份的 `:service-overrides` 被丢弃）。修法：删掉重复项，把差异并入唯一那一项的 `:services` 覆盖。
- **D4 之前导入的清单需重新导入**：`env_file` 清单形态已由 `((:source PATH :type env))` 改为路径字符串列表（`("./db.env")`）；旧清单继续导出会报 `services.<name>.env_file must be a string`。手工改法是就地改成字符串列表，或直接重跑 `M-x ebasecamp-import-file`。
- **同一项目同一组只能 1 份配置**：容器标签没有配置维度，同名服务会撞；需要「同组在同一项目两套」时目前无解（记技术债）。
- **shared 组至多 1 份配置且 `:project` 必填**：多宿主会互相覆盖 `_shared/compose.yaml` 与 `ebc-shared` 容器集合，缺 `:project` 直接加载报错。
- **配置不覆盖 scope**：同一组在不同项目需要不同 scope 时，拆成两个组或改用旧写法（引用级 `:scope` 仍可用）。
- **`:groups` 之外的入口不变**：`ebasecamp-create-sample-config` 生成的示例清单仍是旧写法（可以直接加载），要体验组内配置写法需手工改造。

## [0.1.0] - 2026-10-22

首版：M1–M3 全部落地（数据层与界面、生命周期、导入导出）。

### 新增

- **清单数据模型**：三个 record（service / group / project）与 `ebasecamp-define-group`、`ebasecamp-define-project` 两个定义宏，注册表按定义顺序保存组与项目。
- **项目级覆盖合并**：项目可覆盖组的 `:scope`，并按服务名覆盖字段；`environment`、`labels`、`:extra` 按键合并，`image`、`command`、`entrypoint`、`ports`、`volumes`、`healthcheck`、`depends-on`、`networks`、`working-dir`、`user`、`restart` 整体替换。
- **清单加载与错误收集**：按 `groups.el` + `projects/*.el`（文件名字典序）加载，单个文件出错只记入 `:errors` 不中断后续文件；失败文件用「重置 + 重放已成功文件」回滚，避免残留定义；加载后校验项目对组的引用。
- **compose 渲染**：清单到 compose YAML 的唯一写入入口，注入 `ebasecamp.managed` / `.project` / `.group` / `.service` / `.scope` 五项托管标签，`ebasecamp` 作为 external network 在顶层声明，命名卷与 `${VAR}` 引用原样保留。
- **docker CLI 适配**：异步进程封装、`docker ps --no-trunc` 解析、`docker compose config -q` 双判据校验、`docker compose version` 版本检测与不匹配告警。
- **状态归一与轮询**：按容器标签把 `docker ps` 输出归一为服务状态记录，默认 3 秒轮询（仅界面可见时），无健康检查的 `"none"` 归一为 nil；刷新失败保留上一次成功记录供界面继续显示。
- **ETAF 只读主界面**：项目 tabs / 组列表 / 服务表 / 操作条四区布局，服务级多选、状态徽章、清单为空时的空态页；操作条分两行（生命周期一行、导入导出一行），避免 80 列终端下按钮溢出裁切。
- **生命周期命令**：start / stop / restart / down，按 scope 拆批执行（shared 进 `ebc-shared`、per-project 进 `ebc-<project>`）；`start` 时按跨 scope `depends_on` 自动先启动 shared 批次，并在完成回调暴露 `:auto-started-shared` 与 `:order`。
- **端口冲突检测**：执行前比对宿主端口占用，区分 `duplicate` / `busy` / `unknown`，前两者拒绝执行，仅 `unknown` 时放行并提示。
- **错误链路与反馈**：会话级 `notice`（error / warning / success / info）配 `etaf-alert` 展示，成功与信息类提示超时自动清除；命令执行中置 `busy` 禁用生命周期按钮，`down` 走确认框。
- **导入（compose → 清单）**：经 `docker compose config --no-interpolate --no-env-resolution --no-path-resolution --format json` 读取，映射为组 + 项目清单文件落盘；组名取项目名，写后自校验并在失败时回滚。
- **导出（清单 → 部署 compose）**：只渲染 per-project 组，项目副本关闭 `shared-network`，原子写（tmp → `config -q` 校验 → rename）。
- **示例清单**：`M-x ebasecamp-create-sample-config` 生成 `groups.el`（mysql / redis）与 `projects/example.el`，`C-u` 强制覆盖。

### 变更

- **操作条布局**：六个按钮由一行改为两行，实测 80 列终端下同行会溢出并裁切标签。
- **提示组件**：不用 `etaf-toast`（实测要求 `:anchor` 必填，batch 下只画标题、正文不可见），改用以 `notice` 驱动的 `etaf-alert`。
- **导入不预设项目根目录**：项目 `:root` 取 compose 文件父目录，不再单独提问；「预览服务列表」步骤未实现（`etaf-dialog` 无法在事件回调里同步返回用户输入）。
- **`ebasecamp-import-file` / `ebasecamp-export-compose` 加 autoload cookie**，`ebasecamp.el` 补充导入导出模块 require。

### 修复

- **stale `.elc` 加载陷阱**：batch 测试在源码更新后仍加载旧字节码，导致改动不生效；验证入口统一 `load-prefer-newer t`。
- **`make check-parens` 不覆盖测试文件**：`test/*.el` 括号错漏时会静默吞掉用例却显示全绿，`PARENS_FILES` 现包含 `TEST_FILES`。
- **跨 scope `depends_on` 报「undefined service」**：按 scope 渲染时剔除指向本次未渲染服务的依赖（`ebasecamp-compose--filtered-depends-on`），并在 `start` 时由 shared 批次补齐；全量渲染（预览 / 导出）行为不变。
- **导入自校验假绿**：写后自校验原先会被注释行干扰，临时 buffer 读回时显式 `forward-comment` 跳注释，名字校验关闭 `case-fold-search`。
- **无健康检查容器的状态显示**：`HealthStatus` 为 `"none"` 而非空串，状态归一化统一把两者都转成 nil，避免界面出现 `none`。
- **`config -q` 单看退出码误判**：改为同时检查退出码与 stderr。
