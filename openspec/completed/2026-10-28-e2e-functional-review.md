# 全插件端到端功能审查（v0.6 基线）

## 当前状态

- 阶段：Phase 4（Review & Document）· 已完成
- 方案：✅ 已确认（用户 2026-10-28）
- 计划：✅ 已确认（两轮独立审查通过）
- 进度：T0–T10 全部完成（11 个探针批次 + 1 次只读静态深审）
- 结论：blocking 1（可降级）/ major 2 / minor 8 / 已知 7 / nit 1；报告见 `docs/reports/2026-10-28-e2e-functional-review.org`
- 已归档：本文件（`openspec/completed/2026-10-28-e2e-functional-review.md`）

## 目标

对 ebasecamp v0.6 的**用户可见功能**做一次端到端正确性审查，猎捕两类问题：

1. **测试绿但功能错**：ERT 已覆盖、断言却是弱约束（文案按序包含、打桩替身与真实现漂移）导致的静默偏差。
2. **无覆盖的静默失败**：真实 docker 链路、真实 etaf 键层、写盘回滚、项目定位边界等处，历史上缺陷的集中产地。

产出：一份分等级的问题清单（blocking / major / minor / 已知）+ 可复核证据（命令、文件:行、期望 vs 实际）。**本计划不修实现代码。**

## 设计

### 判据来源（唯一事实源，按优先级）

1. `AGENTS.md` 的 16 条不变量；
2. `docs/architecture.org` 的分层约束、物化算法、刷新链路、写盘事务七步、派发参数构造、预校验语义、布局与主题机制、15 条不变量表；
3. `Readme.org` 的用户可见承诺（16 个命令、键位表、五区布局、写盘语义、预校验语义、已知限制）；
4. `docs/adr/0001`–`0010` 的决策与「已知边界」；
5. `openspec/tech-debt.md` 的 45 条（区分「待处理」「已修复」「已关闭」）。

代码与文档冲突时：**记录冲突**，按「哪一方更像 bug」分级，不擅自判定哪边权威。

### 问题分级标准

每条问题必须落进以下四档之一，档位定义如下（可操作、可判定）：

| 档位 | 判定条件（满足任一即是） |
|---|---|
| **blocking** | ① 违反 `AGENTS.md` 不变量 1–16 或 `architecture.org` 不变量 1–15，且后果是数据丢失 / 密钥或明文泄漏 / 容器误操作（起停错集合、误删）/ 界面打不开 / 静默错误（校验通过但内容或语义已变）；② 用户可见功能与 Readme 承诺实质不符（不是措辞差异）；③ 基线 L1 不成立 |
| **major** | 违反不变量但影响面受限（边界场景、特定配置组合）；或文档与实现不一致但行为本身安全；或技术债已登记但**实测退化**（表现比登记更严重）；或写盘 / 导入导出存在可恢复的数据偏差 |
| **minor** | 用户不可见的内部细节、措辞与文案、非关键路径的弱约束、代码整洁度 |
| **已知** | 已登记在 `openspec/tech-debt.md` 且本次实测**与登记一致**；报告里只标条目号 + 「复现」，不新增条目、不重复计入问题数 |

判定冲突时按「就高不就低」：疑似 blocking 与 major 之间先记 blocking，附「若确认影响面有限可降级」说明。

### 八个功能面 × 手段

| 面 | 内容 | 手段 | 批次 |
|---|---|---|---|
| F1 | 清单加载与加载期物化 | batch 探针（临时清单） | T1 |
| F2 | compose 渲染与生成物 | 探针 + 真实 `docker compose config -q` / `config --format json` | T2 |
| F3 | 预校验与派发参数 | 探针 + 打桩捕获 argv 与 `ensure-network` 计数 | T3 |
| F4 | 状态采集与聚合 | fixture 解析 + 一个真实带标签临时容器 | T4 |
| F5 | 界面渲染与键位 | 真实 etaf 渲染 + `execute-kbd-macro` 逐键 | T5 |
| F6 | 清单写盘事务 | 探针（临时清单落盘，比对字节） | T6 |
| F7 | 导入 → 导出往返 | 真实 compose 文件 + `config --format json` 比对 | T7 |
| F8 | 生命周期 / 主题 / 持久化 / 项目定位 | 探针（open/close/reopen、kill-buffer、load-theme、ui-state、symlink 边界） | T8 |

### 隔离与副作用

- 每个探针独立 `HOME=$(mktemp -d)` + 独立临时清单目录 + `unwind-protect` 清理；**不触碰** `~/.config/ebasecamp` 与 `~/.cache/ebasecamp`。
- 真实 docker：只读校验（`config -q` / `config --format json`）无需额外批准；起容器仅限 T4，且必须 ① 带全套 `ebasecamp.*` 标签 ② 轻量镜像（`alpine sleep 60` 级）③ 探针结束立即 `docker rm -f` ④ 报告记录容器 ID 与清理结果。
- 全程禁止 `docker compose up` / `down` / `rm` 作用于任何非探针创建的容器。
- **清理兜底**：T4 若 `rm -f` 失败，立即用 `docker ps -a --filter name=ebc-review-probe --no-trunc` 取证并把容器名/ID 写进报告，**停止后续所有批次**，由 harspower 报用户手工处理；不得继续跑 T5–T8（避免叠加副作用）。
- 并行批次互不干扰的保证：各批次的临时 HOME、清单目录、生成物目录前缀互不重叠，探针文件路径按批次编号分目录（`/tmp/ebcreview/T<N>/`）。

### 强制执行的安全护栏（OOM）

依据 `docs/reports/2026-10-26-etaf-props-print-oom.org`：

1. **打印面（全清单，缺一即判本批次失败）**：以下任何一种输出都必须包在 `(let ((print-circle t) (print-level 4) (print-length 20)) …)` 内 —— `message` 带 `%S`、`format "%S"`、`prin1`、`prin1-to-string`、`pp`、`pp-to-string`、`princ` 打印列表结构、`describe-variable` / `describe-function` / `documentation` 的返回值、`condition-case` 里对 `err`（signal data）的打印、`ert` 断言失败时作为实参传入的大结构。
2. **禁止面**：不得打印 `etaf--keys-props` 返回值、etaf props plist、ebox 节点、`byte-code-function`、闭包环境；不得把 etaf/ebox 结构作为 `signal` 的 data 或 `ert` 断言实参。查看结构只允许 `(type-of v)`、`(etaf-host N M)` 形态的 ref、`:aria-label`、字面量文案。
3. **资源**：`bash -c 'ulimit -v 3000000; timeout -s KILL <N> emacs -Q --batch … > /tmp/<name>.log 2>&1'`。**不要**把输出接 `grep` / `head`（管道缓冲会丢爆前最后几条）；排错一律读日志文件。若首跑出现 `Memory exhausted`，先上调到 `4000000`（4 GB）再复跑一次，并在报告里记录该事实。
4. **观测**：探针统一输出 `RESULT <id> <PASS|FAIL> <单行摘要>` 行。由**委派的 general 子代理**在批次内只读过滤 `^RESULT ` 写入阶段报告（不让全量日志进上下文），harspower 负责汇总判定。`FAIL` 行必须带「期望 vs 实际」。

### 执行编排

- T0 先行（基线），不通过则停止全部后续批次。
- T1–T8 **每个任务单独一个批次**（不再合并）：单批步骤数控制在 25 步以内、单批目标时长 30 秒–2 分钟。
- 并行策略：轻探针两两并行（T1+T6、T3+T8），重探针串行（T2、T4、T5、T7）；T9（静态映射 + code-reviewer 深审）从第一批起即并行委派（只读，不写仓库文件）。
- 每批返回后立即输出「📋 阶段报告」；`FAIL` 项当场登记进问题清单草案（含分级），不等全部跑完。

### 需实测才能判定的条目（执行时必须确认并回写）

1. `execute-kbd-macro` 在 `emacs -Q --batch` 下能否逐键驱动 etaf 键层（此前只有 v0.6 批次 3 的一次探针覆盖）。若不可靠，F5 降级为「ref 层直接调命令函数 + 记录无法按键验证的诚实说明」。
2. `ulimit -v 3000000` 对重夹具是否够用（OOM 报告只验证过 props 打印场景）。不够则按护栏第 3 条上调并记录。
3. T6④ 制造「M 第二段失败」的确定性打桩点是否存在（架构未描述两段之间的注入边界）。可行方案：`cl-letf` 打桩 `ebasecamp-manifest--write-transaction` 并在第 2 次调用时 `(error "injected")`；若该打桩会破坏第一段，改用「目标文件路径不可写（chmod 0444）」注入。
4. T4 的 `docker-ps-managed.jsonl` fixture 是否含 `scope=shared` 样本；若无，shared 匹配语义只能由真实容器样本证明。

## 任务

- [x] **T0 基线复核（L1）**：`emacs --version`、`docker --version`、`docker compose version`、确认 `STRAIGHT_BUILD` 四个包目录存在；跑 `make check` 并把完整输出重定向到 `/tmp/ebcreview/T0/check.log`。验收：`check-parens` 通过（记录文件数）、`compile` 零 warning、`ert` 481 expected / 0 unexpected；若出现 unexpected，**先复跑一次**排除技术债 #20 抖动，仍不符即报 blocking 并停止后续批次。命令须带 `ulimit -v 3000000` 与 `timeout -s KILL 900`。（依赖：无）

- [x] **T1 F1 清单加载与物化**：探针 P1 构造 8 个场景 —— ①正常 1 组 1 配置；②配置指向未定义项目（期望 `:undefined-project`）；③同项目同组两份组侧配置（期望 `ebasecamp-config-duplicate-group-ref`，消息点名第一份配置）；④shared 组两份配置（期望整组跳过 + `:shared-multiple-configs`）；⑤覆盖组内不存在服务（期望 `:unknown-service`）；⑥旧 `:groups` + 组侧 1 份配置（期望原位接管、列表位置不变、取配置值、不报错）；⑦连续调用 `ebasecamp-model-link-configs` 两次（期望结果 `equal`）；⑧`groups.el` 合法 + 一个 `projects/*.el` 报错（期望该文件整体回滚、其余文件仍加载、错误项不中断）。断言：`:errors` 的 `:condition` 与条数、接管后 `:service-overrides` 值、两次物化 `equal`。（依赖：T0）

- [x] **T2 F2 渲染与生成物**：探针 P2 用临时清单渲染 shared 与 per-project 两份生成物，再对每份跑真实 `docker compose -f <file> --project-directory <root> config -q` 与 `config --no-interpolate --format json`。验收（全部满足才 PASS）：①`config -q` 退出码 0 **且** stderr 不含 `level=error`；②项目名 `ebc-shared` / `ebc-<project>`；③五项 `ebasecamp.*` 标签齐全；④顶层 external network `ebasecamp`；⑤**多行 `content:` 经 `config --no-interpolate --format json` 取回后与原 `content` 字符串 `equal`**（`config -q` 不作为内容保真判据，见技术债 #33）；⑥混合 ports/volumes 只产出一个 `ports:` / `volumes:` 键。（依赖：T0）

- [x] **T3 F3 预校验与派发**：探针 P3 以 `cl-letf` 打桩 `ebasecamp-docker-run-async` 捕获 argv、打桩 `ebasecamp-command-ensure-network` 计数、打桩 `ebasecamp-command--port-free-p` 控制冲突。断言：①`-f` 的下标 < `--project-directory` 的下标 < 子命令下标；②预校验与被派发命令的 root 相同；③项目 `:root` 为 nil 时不带该 flag 且相对 `file:` 只产生 warning、不阻塞；④顶层 `configs.file:` 缺失时 `run-async` 计数为 0 **且** `ensure-network` 计数为 0（零副作用）；⑤构造「shared 分支合法 + per-project 分支非法」，断言 per-project 失败时 shared 分支也**未派发**，`stop` / `down` 路径**不调用** `ebasecamp-docker-check-compose`（打桩为计数，非 error）；⑥端口被占用时启动前提示冲突且不派发。（依赖：T0）

- [x] **T4 F4 状态采集**：探针 P4 先用 `test/fixtures/docker-ps-managed.jsonl` 验证解析与归一（`HealthStatus "none"` → nil、Labels 前缀过滤）；再起真实容器（起之前先跑 `docker ps -a --no-trunc --filter name=ebc-review-probe`，若命中残留则先 `docker rm -f` 清理，避免 `name already in use`）`docker run -d --name ebc-review-probe --label ebasecamp.managed=true --label ebasecamp.project=probe --label ebasecamp.group=probe-g --label ebasecamp.service=probe-s --label ebasecamp.scope=shared alpine sleep 60`，跑真实 `docker ps -a --no-trunc --filter label=ebasecamp.managed=true --format '{{json .}}'` 并断言归一命中；验证 shared 匹配按 `scope+group` 忽略 project。收尾：`docker rm -f ebc-review-probe` + 复跑 ps 确认无残留；失败按「隔离与副作用」的清理兜底处理。（依赖：T0）

- [x] **T5 F5 界面渲染与键位**：探针 P5 打开真实界面（临时清单），用 `execute-kbd-macro`（**先 `ebasecamp-ui-open` 落到选中 window**）逐键验证，每条断言必须可判定：

  - 焦点断言统一用 `ebasecamp-ui-test--focused-ref`（返回 `(etaf-host N M)` 普通列表，OOM 报告 §3.4 已验证安全），禁止读 props。
  - `j` / `k`：`focused-ref` 改变而 `session` 的 `selected-group` 不变；`k` 为反向。
  - `h` / `l`：先展开目标组分支，`h` → 该组 `expanded-p` 变 nil 且 `focused-ref` 不变；再按 `h`（已折叠）→ `focused-ref` 改变（落回焦点左移）。`l` 反向同理。
  - `f`：打桩 `avy-available-p` → nil（走 `completing-read` 降级）+ 打桩 `completing-read` 捕获 collection 并返回首项；断言 ① collection 只含可见目标（先折叠某组，其配置不在候选）② 跳转期间 `ebasecamp-status-stop` 计数 +1、结束后 `ebasecamp-status-start` +1（原本运行中时）③ `selected-group` 与勾选集合均不变。
  - `t`：point 在服务行时勾选集合变化 ±1；point 在非行区域 no-op。
  - 段级 `s` / `x` / `r`：打桩 `ebasecamp-command-run` 捕获 `(:action :project keys)`，断言 project 是该段自己的项目（同组多实例不串段）。
  - `a` / `A`：勾选集合 = 该段服务全集 / 空集。
  - `1` / `2` / `3`：`focused-ref` 落入对应区域子树（用 `etaf-focus-within` 返回值判定）。
  - `n` / `p`：`selected-group` 在组序列中前后移动，右栏重渲染。
  - `e`：打开 buffer 的文件名 = 该组定义实际所在文件，point 行匹配 `(ebasecamp-define-group <组名>`；三档降级各验一次（无选中组 → `user-error`；组定位失败 → 打开降级文件 + `message`；文件内搜不到定义 → 退 `point-min` 且不 signal）。
  - `I` / `o` / `D`：走 UI 入口（不是 `ebasecamp-import-file`）；`D` 断言 ① 二次确认前不派发 ② 确认后 `command-run` 的 action = `down` 且 argv **不含** `-v` ③ 只作用于 per-project 项目。
  - `ebasecamp-ui-confirm` / `-dismiss-confirm`：确认执行待确认动作、dismiss 丢弃且无副作用。
  - 五区与空态：空清单与「有组无配置」清单各渲染一次，断言顶栏统计、左栏未关联组、右栏「选择左侧的组」/「尚未关联任何项目」、提示区 alert、底栏三按钮均出现（渲染文本断言允许，禁止 `prin1` 带属性字符串）。
  - 刷新链路：打桩 `ebasecamp-docker-ps` 计数，断言一次 `ebasecamp-ui-refresh` 只调用一次。
  - `g` / `?` / `q` / `SPC`：`g` 触发重载；`?` 帮助 surface 出现，且断言 `ebasecamp-ui--root-keys` / `ebasecamp-ui--section-keys` 两张键表的键名与 LABEL 组合覆盖全部已绑键（以事实源判定，不读 props）；`q` 关闭后 buffer 被杀、session 为 nil、轮询停；`SPC` 在勾选框上 = 勾选、在按钮上 = 派发（验证 ebox 激活语义而非本插件勾选键）。
（依赖：T0）

- [x] **T6 F6 清单写盘事务**：探针 P6 对临时清单逐项断言：①`S` 表单只改 1 个字段 → 该字段值变化、其余键逐字节不变；②清空字段 = 删除该键（`read` 后 `plist-member` 为 nil，不是空串）；③mtime/size 被外部改动 → 写入被 `user-error` 拒绝且磁盘内容不变；④`M` 跨文件移动第二段失败（`cl-letf` 打桩 `ebasecamp-manifest--write-transaction` 第 2 次调用 `(error "injected")`，若破坏第一段则改目标文件 chmod 0444）→ 源文件恢复原文、无 `.ebasecamp-backup-*` 残留；⑤`update-project` 的 `clear-root` → `:root` 键真删（`plist-member` 为 nil）；⑥`X` 菜单 8 项 CRUD：删项目被引用即 `user-error` 且磁盘不动、删组被旧 `:groups` 引用即拒绝、同名组/项目拒绝、组名/项目名非法字符拒绝；⑦旧 `:groups` 迁移确认：答 yes → 同批事务删引用（唯一元素整键移除）、答 no → 磁盘不变；⑧`E` 改配置关联项目的跨文件迁移写盘（技术债 #38 无 ERT 项）→ 组文件出现新 `:project`、项目文件 `:groups` 消失、两文件均无备份残留；⑨`add-project` 传带首尾空白 root → 记录落盘是否 trim（技术债 #42 预期「仍不 trim」，按「已知」档记录，不判 FAIL）。（依赖：T0）

- [x] **T7 F7 导入导出往返**：探针 P7 用一份覆盖多形态的真实 compose（多行 `content:`、`env_file`、udp 与宿主 IP 端口、tmpfs 卷、`container_name`、`${VAR}` 引用）走导入 → 导出 → `config --format json` 取回比对。断言：①多行 `content` 字符串 `equal`；②相对路径未被绝对化；③**密钥场景**：environment 写 `("MYSQL_ROOT_PASSWORD" . "${EBASECAMP_X}")` 并在探针进程内设 `EBASECAMP_X` 为可识别哨兵值，断言清单与导出物中只出现 `${EBASECAMP_X}`、**不出现**该哨兵值明文（不打印哨兵值本身，只报「命中/未命中」）；④`container_name` 导入导出后保留（技术债 #41 现状，按「已知」档记录）。（依赖：T0）

- [x] **T8 F8 生命周期 / 主题 / 持久化 / 定位**：探针 P8 断言：①`open → close → open`：`enable-theme-functions` / `disable-theme-functions` 钩子数量不增长、轮询已停、session 重建、项目定位**重新计算**（技术债 #29 关联点）；②直接 `kill-buffer` 后钩子 / session 是否残留（验证 #29 是否仍存在，按实测归档）；③`load-theme` 切换后 token 值变化且界面不重挂载；④`ui-state.el` 非法内容回退默认、越界 ratio 钳制到 [0.15,0.55]；⑤项目定位边界（技术债 #30）：临时目录 + `make-symbolic-link` 覆盖「同名前缀（`/a/myapp` 不匹配 `/a/myapp2`）」「symlink」「`default-directory` 以 `/` 结尾」三种输入，另验「最长 root 胜出」与「大小写敏感」。（依赖：T0）

- [x] **T9 静态承诺映射 + 深审**：①把 `Readme.org` 的 16 个命令、键位表（根级 / 段级）、五区布局、写盘语义、预校验语义、已知限制逐条映射到「实现函数 + 现有覆盖证据（ERT 用例名或探针编号）」，输出缺口表；②委派 `code-reviewer` 对 `ebasecamp-model.el` / `ebasecamp-config.el` / `ebasecamp-compose.el` / `ebasecamp-manifest.el` / `ebasecamp-config-write.el` / **`ebasecamp-ui.el`** 做系统化只读审查，重点：不变量 9/10/11/12/13/14/15、`compose` 对 `resolve-services` 结果只读（禁止 `setcar` / `plist-put` 就地改共享结构）、写盘事务七步顺序与「错误集差分」回滚判据、`ebasecamp-ui.el` 的 render 区色值字面量扫描（复用 `render-region-has-no-literal-colors` 的 render 函数名清单）与打印安全。（依赖：可与 T1–T8 并行）

- [x] **T10 报告与沉淀**：写 `docs/reports/2026-10-28-e2e-functional-review.org`（审查矩阵结果、分级问题清单含证据、假设复盘 A1–A7、需实测条目结论、未验证点）；把**新**发现问题登记 `openspec/tech-debt.md`；更新已登记条目的实测状态；更新 `AGENTS.md`「当前状态」（进行中计划指向本计划）；在报告里列出「建议固化的 ERT 用例清单」（**不落盘**，补 ERT 属另立计划）。（依赖：T1–T9）

## 文档清单

| 文档 | 动作 | 触发条件 |
|---|---|---|
| `docs/reports/2026-10-28-e2e-functional-review.org` | 新建 | 必做 |
| `openspec/tech-debt.md` | 修改 | 有新发现问题 或 已登记项状态变化 |
| `AGENTS.md` | 修改 | 必做（「当前状态」：进行中计划 = 本计划；审查结束后再改回） |
| `CHANGELOG.md` | 修改 | 仅当用户批准修复后（本计划默认不修） |
| `docs/architecture.org` / `Readme.org` | 修改 | 发现文档与实现不一致（先报，由用户决定改哪边） |
| `openspec/decisions.md` | 修改 | 审查推翻某条既有设计假设 |
| `openspec/completed/2026-10-28-e2e-functional-review.md` | 归档到 `completed/` | 已归档（2026-10-28） |

## 验证标准

- L1：T0 的 `make check` 三子目标全绿（check-parens 通过、compile 零 warning、test 481 expected / 0 unexpected）。
- L2：每个探针的 `RESULT` 行 100% 有明确 PASS/FAIL，FAIL 附「期望 vs 实际」。
- L3：真实链路证据 —— 至少 1 次真实 `docker compose config -q` 通过、1 次真实 `config --format json` 内容等值比对、1 次真实容器被 `docker ps --no-trunc` 正确归一、1 次真实 `execute-kbd-macro` 按键落到界面 buffer。
- 分级一致性：所有 FAIL 项必须落到「问题分级标准」四档之一，blocking 项必须附可复核证据；不允许出现「有 FAIL 无分级」。
- 不变量守卫：报告必须逐条覆盖 `AGENTS.md` 16 条不变量（适用/不适用 + 证据），不得留空。

## 注意事项

- **测试禁止真实 docker/bind**（`test/README.md` 第 3 条）——探针是一次性审查工具，**不得**把真实 docker 用例写进 `test/*-tests.el`。
- `execute-kbd-macro` 在 batch 下作用于 selected window 的 buffer，必须 `ebasecamp-ui-open` 之后才按键；`ebasecamp-export--prompt-p` 在 batch 下恒为 nil，交互路径测试须 `cl-letf` 打桩该判定函数本身。
- 打印任何 etaf/ebox 结构前先读 `docs/reports/2026-10-26-etaf-props-print-oom.org` 第 8 节，遵守护栏四条；探针里出现裸 `%S` 即判本批次失败。
- 状态采集测试（T4）的最后一步必须是清理容器并复查；清理失败立即停止后续批次并报告。
- 技术债 #20 会让「0 unexpected」判读失真：任何红灯先单独复跑该用例。
- 写盘类断言必须比对**字节**（`buffer-string` / 文件原文），不要只比对 model 对象 —— 既有缺陷多次出现在「模型对、磁盘错」。
- 发现文档与实现不一致时**不要**就地改文档或代码；登记为问题项，Phase 4 由用户决定。
- 本计划不改实现代码；补 ERT 亦属另立计划，本计划只输出建议清单。
- 批次返回后若 `RESULT` 行缺失（探针崩了），先按护栏第 3 条读日志定位，不要直接判 PASS。
