# 架构决策日志

| 日期 | 决策 | 理由 | 详见 |
|---|---|---|---|
| 2026-10-22 | 采用「自有 Elisp 清单 + 生成 compose 执行」模型，而非直接扫描项目 compose 或自拼 docker 命令 | 需要表达「可复用基础组件 → 多项目绑定」的模板复用语义，纯 compose 与纯 CLI 都无法表达 | ADR-0001 |
| 2026-10-22 | 基础组件实例语义由组定义 `:scope shared / per-project` 声明，两种都支持 | 真实场景同时存在「全机共用一份 mysql」与「每项目独立 redis」 | ADR-0001 |
| 2026-10-22 | 清单用 Elisp 数据文件存于 `~/.config/ebasecamp/`，零外部依赖 | 用户已确认；避免引入 yaml.el，且 Elisp 可表达条件与覆盖逻辑 | ADR-0001 |
| 2026-10-22 | 与项目 compose 的同步为**单向**：导入（一次性迁移）+ 导出（部署用），不做双向回写 | 双向合并需保留注释/格式且冲突语义复杂，与确定性和零依赖目标冲突 | ADR-0001 |
| 2026-10-22 | 不引入 YAML 解析器：读取 YAML 一律走 `docker compose config --no-interpolate --no-env-resolution --no-path-resolution --format json` | 本机实测 Compose 5.6.0 支持，docker 即解析器，零依赖且语义权威；三个 flag 保证不泄漏变量值、env_file 内容与绝对路径 | ADR-0001 |
| 2026-10-22 | 统一 external network `ebasecamp`，shared 组以固定项目名 `ebc-shared` 运行 | 跨 compose 项目容器互通必须共享同一 network | ADR-0001 |
| 2026-10-22 | 导入项目 compose 必须使用 `docker compose config --no-interpolate --no-env-resolution --no-path-resolution --format json` | 实测：常规 `config` 会插值环境变量（`${SECRET}` → 明文或静默空串，退出码仍 0）、合并 env_file 内容、把相对路径绝对化；三个 flag 分别阻断这三类污染 | ADR-0001 |
| 2026-10-22 | `docs/` 下用户文档统一使用 `.org`；`openspec/` 下按工作流规则固定 `.md` | 用户以 org-mode 为主，避免同一目录格式混用 | ADR-0001 |
