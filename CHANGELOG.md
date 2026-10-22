# 变更日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/) 与 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式。

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
