# 技术债

| # | 条目 | 影响 | 处置计划 |
|---|---|---|---|
| 1 | 本机为 Compose **5.6.0**（新大版本），主版本语义与 v2.x 不同，`config --format json` 的键集可能变化 | 导入映射与生成物校验可能随版本漂移 | 已落地：T1.4 增加 `docker compose version` 检测与不匹配警告；JSON 结构差异收敛在 `ebasecamp-import.el` / `ebasecamp-docker.el` |
| 2 | etaf 0.2.3 / etaf-ui 0.1.3 处于快速演进期（Commentary 即公开 API 契约） | 升级可能破坏 UI | UI 逻辑集中在 `ebasecamp-ui.el` 单点；只用 Commentary 列出的公开符号 |
| 3 | 自写 YAML 序列化器只覆盖清单用到的字段 | 清单出现新字段时导出会丢字段 | 未识别字段存入 `:extra` 并原样回写；新增字段必须补 ERT 往返测试 |
| 4 | 容器状态采用 3s 轮询（仅 UI 可见时） | 状态延迟最多 3s，每次轮询起一个 docker 进程 | 轮询间隔做成 defcustom；后续评估 `docker events` 流 |
| 5 | `docker ps --format '{{json .}}'` 默认截断长字段、`Labels` 为逗号串 | 解析易丢关键标签 | 强制 `--no-trunc`；labels 按 `ebasecamp.*` / `com.docker.compose.*` 已知前缀解析 |
| 6 | `--no-interpolate` 输出的模型比常规 `config` 缺省更多字段（实测无 `command: null`、`entrypoint: null`、`ipam: {}`），且 `env_file` 条目形态随参数变化（无 `--no-interpolate` 时仅 `path`，有时含 `required: true`） | 导入解析若把「字段缺失 / 形态差异」当语义差异会误判 | 导入层按「字段可缺省、`env_file` 按路径列表归一」实现；ERT 用实测输出作 fixture |
