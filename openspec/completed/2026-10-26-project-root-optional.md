# ebasecamp v0.5.3 — 项目 `:root` 可选

## 当前状态

- 阶段：**已归档**（2026-10-26 移入 `openspec/completed/`）
- 已确认：方案 ✅ / 计划 ✅ / 独立审查 ✅（两轮，第 1 轮不通过，已按 7 项意见修订：B1 批次 3 用例②打桩缺陷 / I1 版本号 14 处 / I2 精确判定替代宽捕获 / I3 提示通道改为 prompt 文案 / S1 root 不存在时的不必要提示 / S2 互斥校验位置 / S3 文档补充）
- 结果：批次 1 / 2 / 3 / 4.1 / 4.3 / 5.1 / 5.2 完成；**任务 4.2 用户选择跳过**（保留未勾选，如实记录，见该任务行与下方「L3」）
- 测试基线：436 → **452**（批次 1 +6 / 批次 2 +5 / 批次 3 +3 / 批次 4.3 +2；`make check` 全绿：452 expected / 0 unexpected、`compile` 零 warning、`check-parens` 通过 26 files）
- L3：4.1 真实链路闭环通过（`/tmp` 隔离清单 + `emacs -Q --batch`，脚本退出码 0、**37 条断言 0 失败**，唯一真实 docker 调用是 `docker compose config -q`）；4.2 用户目检未执行（用户 2026-10-26 明确跳过），导出视觉项由 4.1 的 batch 闭环 + 批次 3 的 ERT 替代覆盖
- 目检驱动的额外修复：批次 4.3（界面把 scope 当字符串传给按符号校验的写盘层 → 「新建组 / 改组」必失败、`groups.el` 永远建不出来；属目检中暴露的**既有阻断级缺陷**，与 `:root` 主线无关，同批次修复）
- 回滚点：HEAD `0298c129e992fd7912966ef09df8237a3598a845`（本次全部改动未提交）
- 后续：v0.6（观测：按钮旁显示键 / `hjkl` / avy）或先处理 tech-debt #20（docker 测试竞态）/ #33（顶层 `content:` 多行不可表达，已实际触发）/ #41（生成物固定 `container_name` 与原生 compose 冲突）
- 已完成批次链（存档用）：批次 1 ✅（写盘层放开 `:root`，442/442）→ 批次 2 ✅（界面入口，447/447）→ 批次 3 ✅（导出入口：显式选路径 + 目录不一致提示，450/450）→ 4.1 ✅（L3 真实链路闭环）→ 4.3 ✅（界面 scope 传符号，452/452）→ 4.2 ⏭️（用户跳过）→ 5.1 ✅（文档沉淀 + 版本号 14 处，452/452）→ 5.2 ✅（归档）

## 目标

1. **写盘层放开 `:root` 必填**：`ebasecamp-config-write-add-project` 接受 nil root（不写 `:root` 键）；`-update-project` 新增 `clear-root` 参数把 `:root` 键**真正移除**；空串 / 纯空白继续拒绝。
2. **界面入口放开**：新建项目 root 可留空（提示后果）；改项目留空 = 清空 root，且须二次确认。
3. **导出入口补齐**：无 `:root` 也无 `:export-file` 的项目，交互式导出改用 `read-file-name` 让用户显式选路径（非交互仍 signal）；导出目标目录 ≠ 项目 root 时给一条可读提示。
4. **语义固化**：新增不变量 16 与 ADR-0008，写明「`root` 为 nil 时：不参与项目定位、不作路径基准、导出须显式选路径」。

## 非目标

- v0.6 观测能力（按钮旁显示键 / `hjkl` / avy）
- tech-debt #36（相对 `volumes` source 存在性检查）、#24 / #25 / #27（配置维度）、#29（`kill-buffer` 清理）、#30（定位与几何 ERT）
- 改 `:root` 的类型校验（仍是「nil 或字符串」，序列化形态不变）
- 改 `ebasecamp-manifest-project-form`（只服务导入，导入的 root 恒取自 compose 文件父目录）
- 导出校验改传项目 root（D2 已裁决保持导出目录基准）
- 界面内编辑 `:export-file` / 顶层 `configs`、`secrets`

## 设计决策

### A. 写盘层（`lisp/ebasecamp-config-write.el`）

- `ebasecamp-config-write--check-root (project root)`：判据由「非空字符串」改为「nil，或非空字符串」。docstring 写明「nil 是合法状态（无根目录项目），空串与纯空白仍拒」。
- `ebasecamp-config-write-add-project (name title root)`：改为 `(when root (ebasecamp-config-write--check-root project root))`；root 为 nil 时不写 `:root` 键 —— `--project-form`（`:1341`）已按 `--project-output-keys` 遍历且 `:root` 分支 `when root` 才 push，故渲染层零改动。
- `ebasecamp-config-write-update-project (name title root &optional clear-root)`：
  - `clear-root` 非 nil → 从 plist **真正移除** `:root` 键（`plist-remprop` 语义，索引一致；不得 `plist-put … nil`）；
  - `clear-root` nil 且 `root` 非 nil → 现状行为（`plist-put`）；
  - 两者都 nil → 不改 root（现状）；
  - `clear-root` 与 `root` 同时非 nil → `user-error`（参数互斥，避免静默偏向）。互斥校验与 `--check-root` **同置于 `ebasecamp-manifest--write-transaction` 之前**（不得放进事务 lambda：会先备份、写盘再 signal 回滚，多一次无谓写盘）。
  - 新增内部助手 `ebasecamp-config-write--plist-remove (plist key)`：返回去掉该键的新 plist（保持其余键顺序）。**实现前先搜仓库是否已有等价实现**（`plist-remprop` / `cl-remf` / `assoc-delete-all`）再决定新增（EE-4）。
- 写盘层仍然「只保存引用」（相对路径原样保留），root 为 nil 时不产生任何路径推导。

### B. 界面（`lisp/ebasecamp-ui.el`）

- 新增 `ebasecamp-ui--read-optional-path (prompt &optional initial)`：收集后 `string-trim`，空 → nil，非空 → 字符串（与 `--read-name` 的「空即 user-error」形成对照，docstring 互相引用）。
- 「新建项目」（`:2220` 附近）：root 改用 `--read-optional-path`，prompt 文案写成 `"项目根目录（可留空；留空则不参与目录定位、导出需显式选路径）： "` —— 后果说明**放在 prompt 文案里**（用户在输入前即可见），**不要**用 `message`：写操作后 `--after-write` 会先发 success notice 再 `ebasecamp-reload`，`message` 会被覆盖成一闪而过。
- 「改项目」（`:2231` 附近）：root 改用 `--read-optional-path`；若输入为空且项目**原本有** root → 先 `--confirm`：「清空项目 X 的 :root？清空后界面不再按目录定位当前项目、导出须显式选路径、相对路径校验降级为警告。」答 no → `user-error "已取消"`（`--confirm` 自带）；答 yes → 调 `update-project` 传 `clear-root` t。
  - 项目原本就无 root 且输入为空 → 不弹确认、`clear-root` 传 nil（幂等，避免无意义提示）。
- 不改 `--read-name`（其它实体名仍要求非空）。

### C. 导出（`lisp/ebasecamp-export.el`）

- 新增 `ebasecamp-export--target-or-prompt (project file)` —— **用精确前置判定，不用 `condition-case` 捕获 `ebasecamp-export-error`**（宽捕获会把将来 `default-file` 的任何新错误误判成「需要 prompt」）：
  1. `file` 非 nil → `(expand-file-name file)`；
  2. 项目有 `:root` 或有 `:export-file` → `(ebasecamp-export-default-file project)`（正常推导；万一它 signal 就让它 signal，文案不变）；
  3. 两者都无且 `(ebasecamp-export--prompt-p)` 为真 → `(expand-file-name (read-file-name "导出到文件：" (file-name-as-directory (expand-file-name default-directory)) nil ebasecamp-export--default-file-name))`；
  4. 其余（无 root、无 export-file、非交互）→ 仍调 `(ebasecamp-export-default-file project)`，由它 signal 原文案「既没有 :root 也没有 :export-file」。
  - **注意 `ebasecamp-export--prompt-p` 在 batch 下恒为 nil**（`(not noninteractive)` 恒假），ERT 要覆盖第 3 条必须 `cl-letf` 打桩该函数，绑 `ebasecamp-export--interactive` 无效。
- `ebasecamp-export-project` 用 `--target-or-prompt` 替换 `--target` 调用（`--target` 保留，供既有调用与测试）。
- 新增 `ebasecamp-export--relative-path-notice (project target)`：**先判 `(file-exists-p root)`** —— root 为 nil 或目录不存在时返回 nil（不提示：清单里的 root 可能指向尚未创建的目录，`file-truename` 对它只做尾部分规范化，与已 `make-directory` 的导出目录比较会恒判「不等价」而每次都误报）；root 存在则用 `file-truename` + `file-name-as-directory` 归一等价比较，不等价时返回提示串「导出目录 <dir> 不是项目 root <root>：生成物里的相对路径（env_file / bind 挂载）在部署时按导出目录解析，请确认相关文件随生成物一同部署。」`--write` 在 rename 成功后 `message` 一次；**返回值与成败不变**。
- **`--write` 的 `check-compose` 仍不传 root**（D2 裁决）：校验基准 = 文件所在目录 = 部署基准，避免「校验过、部署炸」。
- 不改 `ebasecamp-export-default-file` 的 signal 语义（它是「推导默认路径」的纯函数，仍 signal）。

### D. 文档与不变量

- `AGENTS.md` 新增不变量第 16 条；「当前状态」更新（v0.5.3 完成、基线）。
- 新增 `docs/adr/0008-project-root-optional.org`：决策（写盘 / UI / 导出三处放开语义）、否决项（① `update-project` 用 nil 表示清空；② 导出校验传项目 root 让校验通过）、后果（无 root 项目的三条降级）。
- `docs/troubleshooting.org:604` 那条「项目 `:root` 的可选性是 v0.5.3 的范围，本版只做回退 + warning」改写为「v0.5.3 起可选，写盘 / 界面 / 导出已支持」。

## 任务

### 批次 1：写盘层放开 `:root`

- [x] 1.1 红：`test/ebasecamp-config-write-tests.el` 新增 6 项 —— ①`add-project` root=nil → 成功、文件**不含** `:root`、加载零错误、`ebasecamp-project-root` 为 nil；②`add-project` root 为空串 / 纯空白 → `user-error` 且无文件残留（回归保护）；③`update-project` 传 `clear-root` t → 文件里 `:root` 键消失（`(should-not (plist-member plist :root))`）、model root 为 nil、`:title` 与无关键保留；④`update-project` 不传 `clear-root` 且 root 为 nil → 文件逐字节不变（回归保护）；⑤无 root 项目改 `:title` 后文件仍不含 `:root`（不得写出 `:root nil`）；⑥`update-project` 的 `root` 与 `clear-root` 同时非 nil → `user-error` 且文件逐字节不变
      （依赖：无）验收：**FAILED**（①③⑤⑥ 红：① 被 `--check-root` 拒、③⑥ 因第 4 参不存在报 arity 错、⑤ 依赖①；②④ 为天然绿回归保护），既有 436 项**零回归**
- [x] 1.2 实现 A（`--check-root` 放宽 / `add-project` 的 `when root` / `update-project` 的 `clear-root` + 互斥校验 + `--plist-remove`）
      （依赖：1.1）验收：**转绿 + `make check` 全绿（436 + 6 = 442 expected / 0 unexpected）**，docstring 同步

### 批次 2：界面入口

- [x] 2.1 红：`test/ebasecamp-ui-tests.el` 新增 5 项 —— ①`--read-optional-path` 空输入 → nil，带首尾空白的输入 → 去空白字符串；②「新建项目」root 输入为空时 `-add-project` 收到 nil，且传给 `--prompt` 的 prompt 串中**含「留空」的那一条**同时含「导出需显式选路径」（`name` / `title` / `root` 三次都经 `--prompt`，断言必须按「留空」筛选而非盲取第一条；`-add-project` 用 `cl-letf` 捕获实参）；③「改项目」root 输入为空且项目原有 root → `--confirm` 调用一次、`-update-project` 收到 `clear-root` 非 nil；④同上但确认答 no → `user-error`（文案含「取消」）且 `-update-project` **零调用**；⑤「改项目」项目原本无 root 且输入为空 → **不弹**确认、`clear-root` 为 nil
      （依赖：1.2）验收：**FAILED**（①②③④⑤ **全红**；计划字面写「⑤ 天然绿」不成立 —— 现状「改项目」用的是必填 `--read-name`，空输入直接 `user-error`，故 ⑤ 同样红。实际 `Ran 447 tests, 442 results as expected, 5 unexpected`），既有 442 项零回归
- [x] 2.2 实现 B（`--read-optional-path` + 两处菜单分支）
      （依赖：2.1）验收：**转绿 + `make check` 全绿（442 + 5 = 447 expected / 0 unexpected）**，compile 零 warning

### 批次 3：导出入口

- [x] 3.1 红：`test/ebasecamp-export-tests.el` 新增 3 项 —— ①无 root 无 `:export-file` + `file` 为 nil + `--prompt-p` 为假（batch 即天然为假）→ 仍 signal `ebasecamp-export-error`（消息含「既没有 :root 也没有 :export-file」，回归保护）；②同上但用 `cl-letf` **打桩 `ebasecamp-export--prompt-p` 返回 t**（绑 `ebasecamp-export--interactive` 无效：`(not noninteractive)` 恒假）并打桩 `read-file-name` 返回临时路径 → 文件被写出，且 `--write` 的 `check-compose` 第二参为 **nil**（`cl-letf` 捕获断言）；③**直接调纯函数 `ebasecamp-export--relative-path-notice` 断言返回值**（不做 `message` 打桩，三条 should 各自独立调用）：root 为**真实存在的目录**且导出目标目录 ≠ root → 返回值同时含「不是项目 root」与两个目录；目标目录 = root → nil；root 目录不存在 → nil（避免清单 root 指向尚未创建的目录时每次都误报）。另用一条 should：`--write` 成功路径经 `cl-letf` 打桩 `message`，断言该提示确实被发出一次
      （依赖：1.2 的写盘改动，用于构造无 root 项目）验收：**FAILED**（②③ 红，① 天然绿），既有 447 项零回归 —— 实测 `Ran 450 tests, 448 results as expected, 2 unexpected`，`project-without-root-signals` 天然绿
- [x] 3.2 实现 C（`--target-or-prompt` + `--relative-path-notice`）
      （依赖：3.1）验收：**转绿 + `make check` 全绿（447 + 3 = 450 expected / 0 unexpected）** —— 实测 450/450、compile 零 warning

### 批次 4：L3 闭环与目检

- [x] 4.1 `/tmp` 清单副本 + `emacs -Q --batch` 脚本闭环：建无 root 项目 → 加载零错误 → `ebasecamp-command-run 'start` 走预校验（含相对 `file:` 时 `:preflight-warnings` 恰 1 条、`:ok t`、派发 args **不含** `--project-directory`）→ 导出（显式路径）→ `docker compose config -q` exit 0（**若 `compose create` 必须事后 `compose down`**）
      （依赖：1.2–3.2）验收：**PASS**（2026-10-26 实测：脚本 `exit=0`、37 条断言 0 失败；未创建任何容器，唯一真实 docker 调用是 `docker compose … config -q`；命令与输出见「## 批次 4 记录 › 4.1 真实链路闭环」）
- [ ] 4.2 用户目检（真实 Emacs）：①界面新建无 root 项目成功，且 root 输入框的 prompt 文案可见「留空则不参与目录定位、导出需显式选路径」；②改项目留空 → 弹确认 → 确认后文件里 `:root` 消失、界面不再定位该项目；③无 root 项目导出 → 弹出 `read-file-name` 选路径、文件成功生成且 **`docker compose config -q` 通过**（无 root 时不存在可比较的基准，因此**不**出现「导出目录不是项目 root」提示 —— 该提示只在「有 root 且导出目录 ≠ root」时出现，由 4.1 的第 5 条覆盖）；④有 root 项目改 title 行为不变（用户 2026-10-26 明确选择跳过；原因与替代覆盖见「## 当前状态」）
      （依赖：4.1）验收：**用户确认 ✅**
- [x] 4.3 目检发现的**阻断级缺陷 A**（scope 类型不匹配）：`--scope-choices` 是字符串表、`--prompt` 经 `completing-read` 返回字符串，而 `--check-scope` 用 `(memq scope ebasecamp-model--scopes)` 比对**符号** → 恒 nil，报「组 scope 必须是 shared 或 per-project，得到 "per-project"」，发生在写盘之前，`groups.el` 永远建不出来（「新建组」「改组」两支都受影响，`lisp/ebasecamp-ui.el` 原 `:2271` / `:2285`）。红：2 项 ERT 断言写盘层收到的 scope 是**符号**；实现：新增 `ebasecamp-ui--read-scope`（`intern` + `require-match` 恒 t）并复用到两支
      （依赖：4.2 的目检反馈）验收：**转绿 + `make check` 全绿（450 + 2 = 452 expected / 0 unexpected）** —— 实测 452/452、compile 零 warning

### 批次 5：文档、版本与归档

- [x] 5.1 文档：`AGENTS.md`（不变量 16 + 当前状态 / 基线）、`docs/adr/0008-project-root-optional.org`、`openspec/decisions.md`、`Readme.org`、`docs/user-guide.org`、`docs/architecture.org`、`docs/troubleshooting.org`、`CHANGELOG.md`（`## [0.5.3]`）、`openspec/tech-debt.md`（#35 处置结论：保持导出目录基准 + 提示已实现）、**14 处** `Version: 0.5.2` → `0.5.3`（13 个 `.el` 文件头 + `AGENTS.md:19`）
      （依赖：4.2）验收：grep 命中各关键词；`make check` 仍全绿 —— **PASS**（2026-10-26：`make check` exit 0、452/452、compile 零 warning；版本号 14 处改完，`grep -rl "Version: 0.5.2" --include=*.el .` 与 `AGENTS.md` 均 0 命中。4.2 用户目检经用户确认跳过）
- [x] 5.2 归档：本计划移入 `openspec/completed/`，其「## 当前状态」写明完成与 L3 结论；`AGENTS.md` 当前状态同步
      （依赖：5.1）验收：`openspec/active/` 为空 —— **PASS**（2026-10-26：普通 `mv` 移入 `openspec/completed/2026-10-26-project-root-optional.md`，未用 `git mv`；`openspec/active/` 已空；`AGENTS.md` 进行中计划改为「无」、已归档列表追加 v0.5.3）

## 文档清单

| 文档 | 更新 |
|---|---|
| `AGENTS.md` | 不变量 16（`root` 可选语义）+ 当前状态 / 基线 / 下一步（v0.6） |
| `docs/adr/0008-project-root-optional.org` | 新 ADR（三处放开、两条否决项、无 root 的降级后果） |
| `openspec/decisions.md` | 追加决策行（含 D2 取舍） |
| `Readme.org` | 项目定义字段表：`:root` 可选 + 留空后果 |
| `docs/user-guide.org` | 「限制与注意事项」：无 root 项目的三条降级与导出行为；明确「无 `:root` 时预校验只给警告（`（N 条预校验警告）`），不是启动失败」以免误读为有问题 |
| `docs/architecture.org` | 路径基准推导（root 为 nil 时的三条回退） |
| `docs/troubleshooting.org` | 604 行那条「v0.5.3 范围」改为已实现 |
| `CHANGELOG.md` | `## [0.5.3]` |
| `openspec/tech-debt.md` | #35 处置结论 |
| 14 处 `Version:`（13 个 `.el` 文件头 + `AGENTS.md:19` 目录表） | `0.5.2` → `0.5.3` |

## 验证标准

- **L1**：`make check-parens` + `make compile`（零 warning）
- **L2**：`make test` 全绿，基线 436 → 450（批次 1 +6 / 批次 2 +5 / 批次 3 +3）
- **L3**：批次 4.1 批处理闭环 + 批次 4.2 用户目检 4 项
- 每批次更新「## 当前状态」

## 注意事项

- **清空 `:root` 必须让键消失**：用 `plist-remprop` / 等价手段，**不得** `plist-put … nil` —— `:root nil` 会让「键存在但值空」与「键不存在」两种形态并存，后续任何 `plist-member` 判定都会误判（v0.5.2 的 `:groups nil` 是同类坑）。
- **行为反转类改动先查既有用例**：v0.5.2 批次 1 的教训。Phase 1 已 grep 确认 `--check-root` 无测试引用、`add/update-project` 用例只传非空 root；实现前再 `grep -n "根目录必须" test/` 复核一次。
- **`clear-root` 与 `root` 互斥**：两者同时非 nil 必须 `user-error`，不得静默偏向任一方。
- **UI 确认必须在写盘前**：`--confirm` 答 no 时写盘零调用（`--confirm` 自带 `user-error "已取消"`）。
- **幂等**：项目原本无 root 且输入为空时不弹确认（避免每次改 title 都问一次）。
- **导出提示只提示**：不得改变 `ebasecamp-export-project` 的返回值、成败与 `check-compose` 的判定。
- **导出校验基准仍是导出目录**（D2）：不要给 `--write` 的 `check-compose` 传 root。
- **`ebasecamp-export--prompt-p` 在 `emacs -Q --batch` 下恒为 nil**（`(not noninteractive)` 恒假）：任何「交互式才走 prompt」的用例必须 `cl-letf` 打桩该函数，绑 `ebasecamp-export--interactive` 或 `called-interactively-p` 都无效。
- **不改 `ebasecamp-manifest-project-form`**：它只服务导入，导入的 root 恒非 nil。
- **无 root 但 `:export-file` 为相对路径时按 `default-directory` 展开**（`export.el` 既有语义，本期不改）：ADR-0008 与 `docs/user-guide.org` 各补一句说明，避免用户以为它按项目 root 展开。
- **版本号共 14 处**：13 个 `.el` 文件头（`ebasecamp.el` + `lisp/` 下 12 个）+ `AGENTS.md:19` 目录表里 `已建（包入口，Version: 0.5.2）` 这一处描述性引用。只改 `.el` 会漏掉 AGENTS.md，只按「13 个文件」计数会漏改一处。
- 同一文件的多次 edit **不得并行**（v0.5.1 曾因此损坏 Readme）。
- L3 用到 docker：`compose create` 必须事后 `compose down`，否则第二次 `create` 会静默假成功（v0.5.2 探针发现的坑）。

## 批次记录

（执行时按批次追加：用例分摊 / 实现要点与落点行号 / 红灯证据 / 绿灯证据 / 与计划的偏差。）

## 批次 1 记录

（执行 2026-10-26。批次 1 = A：写盘层放开项目 `:root`。基线 HEAD `0298c129e992fd7912966ef09df8237a3598a845`；工作区当时只有未跟踪的 `openspec/active/`，改动前状态干净。）

### 用例分摊（6 项，与 442 口径一致）

`test/ebasecamp-config-write-tests.el:1346` 新增一节 `;;; v0.5.3 批次 1：项目 :root 可选（写盘层）`，含 1 个 fixture 常量 + 6 个 deftest：

- `ebasecamp-config-write-test--no-key-project` —— 带 `:root` + `:shared-network nil` + `:export-file` 的项目文件内容，供清空 `:root` 时验证无关键被原样保留（`--write-flat` 写入 `projects/extra.el`）。
- ①`:1357 …-add-project-without-root`：`(add-project 'newproj "新项目" nil)` → 返回值 `:errors` nil、文件已创建、重新加载零错误、`(ebasecamp-project-root …)` 为 nil、**文件文本不含 `:root`**、无 `.ebasecamp-*` 残留。
- ②`:1380 …-add-project-rejects-blank-root`：root 为 `""` 与 `"   "` 各一次 → `user-error` 匹配「根目录」，且目标文件未创建（回归保护：nil 才算无根目录）。
- ③`:1393 …-update-project-clear-root`：对有 `:root` 的 `app` 调 `(update-project 'app "应用" nil t)` → 加载零错误、model root 为 nil、读回 plist `(should-not (plist-member plist :root))`（不是 `:root nil`）、`:title` 为新值；再对 `extra` 做同样操作断言 `:shared-network` / `:export-file` 保留。
- ④`:1432 …-update-project-nil-root-keeps-file`：同参数两次 `(update-project 'app "应用" nil)`（不传 `clear-root`）→ 第二次前后 `--hash` 相等（逐字节不变），且原 `:root` 仍在（nil ≠ 清空）。
- ⑤`:1453 …-update-project-title-keeps-root-absent`：先用 ① 的方式建无 root 项目，再 `(update-project 'newproj "改名" nil)` → 文件仍不含 `:root`（不得写出 `:root nil`）、`:title` 已改、重载零错误。
- ⑥`:1475 …-update-project-rejects-root-with-clear`：`(update-project 'app "应用" "/srv/app" t)` → `user-error` 匹配「互斥」，文件 `--hash` 前后相等。

### 实现要点（落点行号为 2026-10-26 实测，批次 2 起行号会变）

1. **`lisp/ebasecamp-config-write.el:1374` `ebasecamp-config-write--check-root (project root)`** —— 判据改为「nil，或去首尾空白后非空的字符串」：`(unless (or (null root) (and (stringp root) (not (string-empty-p (string-trim root))))) …)`；docstring 写明「nil 是合法状态（无根目录项目）」，并保留「不解析、不展开 `~`、不访问文件系统」的说明。消息由「必须是非空字符串」改为「必须是非空字符串或 nil」。
2. **`…:1386` 新增 `ebasecamp-config-write--plist-remove (plist key)`** —— 返回去掉 KEY 的**新** plist（按 cddr 步进、`append` 累积，保持其余键顺序，不改原 plist：`plist-remprop` 是破坏性的，而 `--form-plist` 的返回值会被「相等则不写盘」的比较复用）。**新增而非复用**：`grep -n "plist-remprop\|cl-remf\|assoc-delete-all\|plist-delete" lisp/ test/` 在 `lisp/` 零命中，`test/` 里的两处 `assoc-delete-all` 是 alist（`(KEY . VALUE)`）语义，不适用于 plist。
3. **`…:1399` `ebasecamp-config-write-add-project`** —— `let*` 的 `root` 绑定去掉 `--check-root`，改为函数体首行 `(when root (ebasecamp-config-write--check-root project root))`；docstring 写明 root 可为 nil 及其后果。`--project-form` **未改**（`:1356` 处 `:root` 分支本就 `when root` 才 push，渲染层零改动）。
4. **`…:1427` `ebasecamp-config-write-update-project`** —— 签名加 `&optional clear-root`；互斥校验 `(when (and root clear-root) (user-error "…根目录参数互斥…"))`（`:1451`）与 `(when root (--check-root …))`（`:1453`）都在 `ebasecamp-manifest--write-transaction`（`:1457`）**之前**，故参数错误连备份都不产生；事务内 title / root / clear-root 三支：`clear-root` 走 `(setq updated (ebasecamp-config-write--plist-remove updated :root))`（`:1470-1472`），`(equal plist updated)` 时仍返回原 text（不改则不写盘）。docstring 补 `CLEAR-ROOT` 语义、互斥规则与「键消失而非置 nil」的理由。

### 红灯证据（实现前）

```
Ran 442 tests, 438 results as expected, 4 unexpected (2026-10-26 14:55:48+0800, 5.573151 sec)

4 unexpected results:
   FAILED  ebasecamp-config-write-test-add-project-without-root
   FAILED  ebasecamp-config-write-test-update-project-clear-root
   FAILED  ebasecamp-config-write-test-update-project-rejects-root-with-clear
   FAILED  ebasecamp-config-write-test-update-project-title-keeps-root-absent
```

- ①的失败形状：`user-error "项目 newproj 的根目录必须是非空字符串，得到 nil"`（旧 `--check-root` 一刀切拒绝 nil）。
- ③⑥的失败形状：`wrong-number-of-arguments` —— 旧 `update-project` 只接受 3 个实参，第 4 个 `clear-root` 不存在（该错误不是 `user-error`，`--error-message` 的 handler 不吞它，直接穿出导致 ERT 记 unexpected）。
- ⑤依赖 ①（`add-project` 传 nil 被拒）。
- ②④ **天然绿**（②：旧 `--check-root` 本就拒空串 / 纯空白；④：root 传 nil 时旧实现跳过 `plist-put :root`，第二次同参数调用无改动 → 文件不变），作回归保护：实现后若被误判为「nil = 清空」会立刻红。

### 绿灯证据（`make check`，2026-10-26）

- `make check-parens` → `check-parens OK (26 files)`，exit 0
- `make compile` → exit 0，**零 warning**（`byte-compile-error-on-warn t` 生效，管道输出为空）
- `make test` → `Ran 442 tests, 442 results as expected, 0 unexpected (2026-10-26 14:56:28+0800, 5.058231 sec)`
- `make check` 整体 → exit 0（`/tmp/ebc-check.log`）
- 复跑一次 `make test` 亦 442/442 全绿；`ebasecamp-docker-test-run-sync-captures-streams` 未抖动（技术债 #20 未触发）

### 与计划的偏差

- **用例④拆成「两次同参数调用」**：任务 1.1 字面为 `(update-project 'app "应用" nil)` → 文件逐字节不变。但一次调用会把 `:title` 由 `"app"` 改成「应用」，文件必然变化，与「逐字节不变」断言冲突。实现取「首次调用完成 title 变更 → 取 hash → 同参数再调一次 → 比 hash」，语义收紧为「同参数重复调用必须零改动」，同时保留「nil root 不等于清空」的断言。
- **批次记录标题用 `##` 而非任务书写的 `###`**：completed 计划的同名小节均为 `## 批次 N 记录` + 其下 `### 用例分摊` 等，按「格式对齐已完成计划」优先。
- **红灯期留下一个未跟踪临时目录**：首轮红跑后在仓库根出现 `ebc-config-write-iQriLZ/`（`--with-directory` 用 `make-temp-file "ebc-config-write-"` 建在 `default-directory`）。成因是红阶段用例在写盘后抛出未捕获错误时 `unwind-protect` 的 `delete-directory` 被 `ignore-errors` 吞掉失败；已手工删除，实现后连续两次 `make test` 均无残留。既有脚手架（批次 3/4 沿用）在失败路径下的固有行为，非本批次引入，但值得后续把 `make-temp-file` 换到 `temporary-file-directory` 绝对路径（未在本批次实施，避免牵动其它用例）。
- **`AGENTS.md` 只改了「进行中计划」一行**（本批次范围），基线 / 下一步留待批次 5.1。

## 批次 2 记录

（执行 2026-10-26。批次 2 = B：界面入口放开项目 `:root`。基线 HEAD `0298c129e992fd7912966ef09df8237a3598a845`；起始工作区为批次 1 的三个 `M` + 未跟踪 `openspec/active/`。本批次只改 `lisp/ebasecamp-ui.el` 与 `test/ebasecamp-ui-tests.el` 两个文件，`AGENTS.md` 未动。）

### 用例分摊（5 项，与 447 口径一致）

`test/ebasecamp-ui-tests.el:3263` 新增一节 `;;; 批次 2（v0.5.3 计划 B 节）：项目 :root 可选的界面入口`，含 1 个打桩助手 + 5 个 deftest：

- `:3276 ebasecamp-ui-test--prompt-reply (prompt table)` —— 按 **prompt 文案**（有序 `(正则 . 值)`，`(t . 值)` 兜底）取答案；未命中即 `error`。存在的理由：`--read-name` 与 `--read-optional-path` 内部都调 `--prompt`，同一分支连续调 3 次（name / title / root），按调用序号盲取会随实现微调漂移；助手在未命中时**报错而非返回 nil**，避免打桩静默返回 nil 让用例误绿。
- ①`:3289 …-read-optional-path`：打桩 `--prompt` 依次返回 `""` / `"   "` / `"  /tmp/x  "` → 前两者 nil、第三者 `"/tmp/x"`；对照断言同一空输入走 `--read-name` 抛 `user-error`（实体名仍必填，这是本批次语义差异的判别点）。
- ②`:3307 …-x-new-project-allows-empty-root`：「新建项目」root 输入 `""` → `-add-project` 收到 `("myapp" "我的应用" nil)`（第 3 参 nil）；且**收集到的 prompt 串里含「留空」的那一条**同时含「不参与目录定位」「导出需显式选路径」（后果说明在输入前即可见）；末尾断言 notice `:kind` 为 `success`（确认提示通道是 `--after-write` 的 notice，不是会被 reload 覆盖的 `message`）。
- ③`:3346 …-x-edit-project-clears-root`：「改项目」、项目原本 `:root` = `"/srv/myapp"`（`setf` 写模型对象）、root 输入 `""` → `y-or-n-p` 被问 **1** 次，文案含「清空项目 myapp 的 :root」「不再按目录定位」「导出须显式选路径」「降级为警告」；答 yes → `-update-project` 收到 `(myapp "示例项目" nil t)`。
- ④`:3383 …-x-edit-project-clear-root-declined`：同上但 `y-or-n-p` 返回 nil → 问 1 次、`-update-project` **零调用**、notice `:kind` 为 `error` 且文案含「取消」。
- ⑤`:3421 …-x-edit-project-empty-root-stays-empty`：项目原本无 root、root 输入 `""` → `y-or-n-p` **零调用**、`-update-project` 收到 `(myapp "示例项目" nil nil)`（第 4 参 nil，不触发清空分支）。

### 实现要点（落点行号为 2026-10-26 实测）

1. **`lisp/ebasecamp-ui.el:2021` 新增 `ebasecamp-ui--read-optional-path (prompt &optional initial)`** —— 与 `--read-name` 同构但**不** `user-error`：`(let ((text (string-trim (--prompt prompt nil nil initial)))) (unless (string-empty-p text) text))`。空串与纯空白都返回 nil。docstring 三条要点：返回值语义（空 → nil / 非空 → trim 后字符串）、**不做 `expand-file-name`、不访问文件系统**（与写盘层「清单只保存引用」一致，相对路径原样保留、`~` 不展开）、与 `ebasecamp-ui--read-name` 互相引用（「空输入即 `user-error`」的对照），并点明调用方是 `--manifest-menu` 的两处项目分支。
2. **`…:2232`「新建项目」分支** —— root 改用 `--read-optional-path`，prompt 为 `"项目根目录（可留空；留空则不参与目录定位、导出需显式选路径）： "`（`concat` 两段拼接，避免超长单行；拼接结果与计划字面完全一致）。initial 仍为 `(directory-file-name default-directory)`。**未**新增任何 `message`：写成功后由 `--after-write` 发 success notice 再 `ebasecamp-reload`，`message` 会被覆盖成一闪而过。
3. **`…:2241`「改项目」分支** —— 新增 `current`（`(ebasecamp-project-root project)`，在 root 提问前取，避免被后续绑定遮住）与 `clear-root`：`(and (null root) current t)`。三支逻辑：
   - root 非 nil → `clear-root` 为 nil → `(update-project name title root nil)`（现状行为）；
   - root 为 nil 且 `current` 非 nil → `clear-root` = t → **先** `--confirm`（文案「清空项目 X 的 :root？清空后界面不再按目录定位当前项目、导出须显式选路径、相对路径校验降级为警告。」，`--confirm` 自带 `user-error "已取消"`），答 yes 后 `(update-project name title nil t)`；
   - root 为 nil 且 `current` 为 nil → `clear-root` 为 nil → `(update-project name title nil nil)`，**不弹确认**（幂等：否则每次改 title 都被问一次）。
   root 的 prompt 写成 `"新根目录（可留空；留空即清空 :root —— 之后界面不再按目录定位当前项目、导出须显式选路径、相对路径校验降级为警告）： "`，让用户在输入前就看得到后果。
4. **`ebasecamp-ui--read-name`（`:2012`）零改动** —— 其它实体名（配置名 / 组名 / 新标题）仍必填。

### 红灯证据（实现前）

```
Ran 447 tests, 442 results as expected, 5 unexpected (2026-10-26 15:00:22+0800, 6.162449 sec)

5 unexpected results:
   FAILED  ebasecamp-ui-test-read-optional-path
   FAILED  ebasecamp-ui-test-x-edit-project-clear-root-declined
   FAILED  ebasecamp-ui-test-x-edit-project-clears-root
   FAILED  ebasecamp-ui-test-x-edit-project-empty-root-stays-empty
   FAILED  ebasecamp-ui-test-x-new-project-allows-empty-root
```

- ①的失败形状：`void-function ebasecamp-ui--read-optional-path`（函数不存在）。
- ②③④⑤的失败形状统一为「写盘零调用」：旧分支用必填 `ebasecamp-ui--read-name` 收 root，打桩喂空串 → `user-error "…不能为空"` → 被 `--manifest-menu` 的 `condition-case` 转成 error notice（不向外抛）→ `calls` 为空。②`:3307` 的失败断言原文 `(should (= 1 (length calls))) :form (= 1 0) :value nil`。
- 既有 442 项**零回归**（`make test` 同一次运行内 442 expected）。

### 绿灯证据（`make check`，2026-10-26）

- `make check-parens` → `check-parens OK (26 files)`，exit 0
- `make compile` → exit 0，**零 warning**（`byte-compile-error-on-warn t` 生效，`make compile` 输出 0 行）。注：`make check` 合并日志里 `grep -c warning` 有 59 处命中，全部是**测试运行时**加载临时清单文件打印的 `Warning (files): Missing ‘lexical-binding’ cookie in "…/ebasecamp-config-test*/groups.el"`，属既有脚手架固有输出，不是字节编译告警（`make compile` 单独跑 0 行可证）。
- `make test` → `Ran 447 tests, 447 results as expected, 0 unexpected (2026-10-26 15:00:56+0800, 5.367584 sec)`
- `make check` 整体 → exit 0（`/tmp/ebc-check-b2.log`）
- 复跑 `make test` 亦 447/447 全绿；`ebasecamp-docker-test-run-sync-captures-streams` 未抖动（技术债 #20 未触发）
- 仓库根无残留临时目录（批次 1 记录提到的 `ebc-config-write-*` 类问题本批次未复现）

### 与计划的偏差

1. **⑤ 红灯 vs 计划写的「天然绿」** —— 计划任务 2.1 的验收写「①②③④ 红，⑤ 天然绿」。**实际 ⑤ 也红**，且这是正确判定：计划把 ⑤ 当成「现状已满足」（原本无 root + 空输入 → `clear-root` nil）来推断它是回归保护项，但现状「改项目」收 root 用的是**必填** `--read-name`，空输入在到达 `update-project` 之前就 `user-error` 了，所以「不弹确认 + 第 4 参 nil」这两条断言在旧实现下都不可达。计划字面的推断漏了「输入层比写盘层更严」这一层。已按实测把任务 2.1 的验收改写为「①②③④⑤ 全红」。②③④⑤ 仍**同时**具备回归保护价值：实现后若把「原本无 root + 空输入」误做成弹确认或传 `clear-root` t，⑤ 立刻红。
2. **④ 的断言落在 notice 而非 `should-error`** —— 任务书写「`--confirm` 打桩返回 nil → 抛 `user-error`（文案含「取消」）」。`--confirm` 确实抛 `user-error`，但 `ebasecamp-ui--manifest-menu` 顶层的 `condition-case` 把它转成 error notice（其 docstring 明写「写盘失败 → error notice」的契约），对外不抛。因此 ④ 断言「notice `:kind` = error 且文案含「取消」」+「`-update-project` 零调用」，等价覆盖「拒绝路径按取消收尾且不写盘」；`--confirm` 自身抛 `user-error` 的语义由既有用例与实现共同保证。
3. **打桩层次选 `--prompt` 而非 `completing-read`** —— 既有 `x-menu-dispatch` 打桩 `completing-read`（按调用序号 pop）。本批次刻意提高到 `--prompt` 一层：只有在这一层才能同时拿到**prompt 文案**（② 的断言对象）并忽略 `collection` / `initial` 差异。代价是两个 helper 内部行为（trim / 判空）必须真跑 —— 这恰好是 ① 要验证的东西。
4. **新增 1 个测试助手** `ebasecamp-ui-test--prompt-reply`（本文件既有风格：`--with-*` 宏与 `--notice` / `--editor` 等函数同级）。任务书说「新增 5 项」，助手不计入 5 项 ERT。
5. **prompt 文案用 `concat` 分两段写** —— 拼接结果与计划字面逐字符一致（② 的断言即验证「留空」「不参与目录定位」「导出需显式选路径」三段子串），分段的唯一目的是控制单行长度。

## 批次 3 记录

（执行 2026-10-26。批次 3 = C：导出入口 —— 无 root 时显式选路径 + 目录不一致提示。基线 HEAD `0298c129e992fd7912966ef09df8237a3598a845`（与批次 1/2 相同，均未提交）；起始工作区为批次 1/2 的五个 `M` + 未跟踪 `openspec/active/`。本批次只改 `lisp/ebasecamp-export.el` 与 `test/ebasecamp-export-tests.el` 两个文件，`AGENTS.md` 未动。）

### 步骤 0 现状摸底

- `ebasecamp-export--target` 的调用点：仓库内**只有 1 处** —— `lisp/ebasecamp-export.el:237`（当时行号）的 `ebasecamp-export-project`，`test/` 零引用。故替换为 `--target-or-prompt` 不影响任何其它调用方；`--target` 按要求原样保留（现为无调用方的私有函数，`byte-compile` 不对未使用 defun 报警）。
- `--prompt-p` = `(and (not noninteractive) (or ebasecamp-export--interactive (called-interactively-p 'any)))`：batch 下 `(not noninteractive)` 恒假 → 恒 nil，确认必须 `cl-letf` 打桩该函数。
- `ebasecamp-export-default-file` 的 signal 分支（原文案「既没有 :root 也没有 :export-file，无法推导导出路径；请设置 :root 或显式传入 :file」）**未改**。
- 既有导出测试脚手架：`--with-root`（`make-temp-file` 建临时 root + `ebasecamp-model-reset` + 清理）、`--with-fake-check`（lambda 只收 FILE，**拿不到第二参**，故用例②自写 `cl-letf` 的 `(lambda (file &optional root) …)`）。

### 用例分摊（3 项，与 450 口径一致）

`test/ebasecamp-export-tests.el:592` 新增一节 `;;; 13. v0.5.3 批次 3：无 :root 项目的导出入口（计划 C 节）`：

- ①`:598 …-project-without-root-signals`（**天然绿，回归保护**）：`(ebasecamp-export-test--define-world nil)`（root 传 nil = 无 `:root`、无 `:export-file`）→ 先断言 `(ebasecamp-export--prompt-p)` 为 nil（确认 batch 语义未被破坏，故本用例不打桩），再 `(should-error (ebasecamp-export-project project) :type 'ebasecamp-export-error)`，且 `(format "%s" (cdr error-data))` 含「既没有 :root 也没有 :export-file」。
- ②`:611 …-project-without-root-prompts-for-path`（红）：同一无 root 项目，`cl-letf` 打桩三处 —— `ebasecamp-export--prompt-p` → `(lambda () t)`、`read-file-name` → 返回 `<root-dir>/out.yaml`、`ebasecamp-docker-check-compose` → `(lambda (file &optional root) …)` 记录两参并返回 ok。断言：返回值 = target、文件存在、`checked-file` = `<target>.tmp`、**`checked-root` 为 nil**（D2：校验基准仍是导出目录）、内容含 `myapp/api:dev`。
- ③`:638 …-relative-path-notice`（红）：一条 deftest、四条 should —— 第一条直接调纯函数（`other-dir` 由 `make-temp-file "ebc-export-other-"` 另建）→ 返回字符串且含「不是项目 root」与两个目录（用 `file-truename` 归一后 `directory-file-name` 做 `regexp-quote` 子串匹配，提示里带不带尾斜杠都能命中）；第二条 target 就在 root 下 → nil；第三条 `--write` 成功路径打桩 `message` 捕获 → `messages` 长度恰 1 且含「不是项目 root」、返回值仍等于 target；第四条 root 指向 `<root-dir>/does-not-exist` → `(file-exists-p root)` 为 nil 且纯函数返回 nil。

### 实现要点（落点行号为 2026-10-26 实测）

1. **`lisp/ebasecamp-export.el:103` 新增 `ebasecamp-export--target-or-prompt (project file)`** —— 四支 `cond`，与计划 C 节逐条对应：`file` 非 nil → `expand-file-name`；有 `:root` 或有 `:export-file` → `ebasecamp-export-default-file`；两者都无且 `(ebasecamp-export--prompt-p)` → `(expand-file-name (read-file-name "导出到文件：" (file-name-as-directory (expand-file-name default-directory)) nil ebasecamp-export--default-file-name))`；其余 → 仍调 `default-file` 由它 signal 原文案。**未使用 `condition-case`** 捕获 `ebasecamp-export-error`（审查 I2 明确否决宽捕获）。docstring 写明四支顺序，并注明 `--prompt-p` 在 batch 下恒 nil、测试须打桩该函数（绑 `--interactive` / `called-interactively-p` 都无效）。
2. **`…:133` 新增 `ebasecamp-export--relative-path-notice (project target)`** —— `(let ((root (ebasecamp-project-root project))) (when (and root (file-exists-p root)) …))`：**先判 `file-exists-p`**（计划 S1），root 为 nil 或目录不存在直接 nil；存在则 `root-dir` / `target-dir` 各走 `(file-name-as-directory (file-truename (expand-file-name …)))`，`unless equal` 时 `format` 提示串「导出目录 %s 不是项目 root %s：生成物里的相对路径（env_file / bind 挂载）在部署时按导出目录解析，请确认相关文件随生成物一同部署。」。docstring 记「只负责生成文案，是否提示、何时提示由调用方决定」。
3. **`…:273-276` `ebasecamp-export--write`** —— `rename-file tmp target t` 之后 `(when-let* ((notice (ebasecamp-export--relative-path-notice project target))) (message "%s" notice))`；返回值仍是 `target`，`check-compose` 调用（`:268`）**仍未传 root**（D2）。docstring 补两段：提示不影响返回值与成败、校验基准始终是导出目录（校验通过即部署通过）。
4. **`…:306` `ebasecamp-export-project`** —— `--target` 换成 `--target-or-prompt`（`:97` 的 `--target` 原样保留）；docstring 补「无 `:root` 也无 `:export-file` 时交互式改用 `read-file-name`」与「导出目录 ≠ root 只 message 提示，不失败、不改返回值」。

### 红灯证据（实现前）

```
Ran 450 tests, 448 results as expected, 2 unexpected (2026-10-26 15:03:26+0800, 5.028867 sec)

2 unexpected results:
   FAILED  ebasecamp-export-test-project-without-root-prompts-for-path
   FAILED  ebasecamp-export-test-relative-path-notice
```

- ②的失败形状：`(ebasecamp-export-error "项目 shop 既没有 :root 也没有 :export-file，无法推导导出路径；请设置 :root 或显式传入 :file")` —— 旧 `--target` 无 prompt 分支（打桩的 `--prompt-p` 无人调用）。
- ③的失败形状：`(void-function ebasecamp-export--relative-path-notice)`。
- ①**天然绿**（`project-without-root-signals` 通过）：旧实现本来就 signal 该文案；实现后若有人把「无 root + 非交互」也接上 prompt，①立刻红。
- 既有 447 项**零回归**（同一次运行内 447 expected + 3 新增 = 450）。

### 绿灯证据（`make check`，2026-10-26）

- `make check-parens` → `check-parens OK (26 files)`，exit 0
- `make compile` → exit 0，**零 warning**（`make compile` 单独跑输出 0 行；`make check` 合并日志里 59 处 `Warning (files): Missing ‘lexical-binding’ cookie in "/tmp/ebasecamp-config-test*"` 与批次 2 记录同源，是测试加载临时清单的既有输出，不是字节编译告警）
- `make test` → `Ran 450 tests, 450 results as expected, 0 unexpected (2026-10-26 15:04:14+0800, 4.527584 sec)`
- `make check` 整体 → exit 0（`/tmp/ebc-check-b3.log`）
- 复跑 `make test` 亦 450/450 全绿；`ebasecamp-docker-test-run-sync-captures-streams` 未抖动（技术债 #20 未触发）
- 仓库根无残留临时目录（`ebc-export-test-*` / `ebc-export-other-*` 均已清理）

### 与计划的偏差

1. **`when-let` → `when-let*`** —— 计划 C 节的片段写 `(when-let ((notice …)) (message "%s" notice))`。Emacs 31.1 起 `when-let` 已 obsolete，`byte-compile-error-on-warn` 下编译直接失败（实测 `Error: ‘when-let’ is an obsolete macro (as of 31.1); use ‘when-let*’ or ‘and-let*’ instead.`）。改用 `when-let*`（与本仓库既有写法一致：`lisp/` 内 10+ 处均为 `when-let*`），单绑定语义等价。
2. **`(message "%s" notice)` 保留 `"%s"` 形态**（与计划字面一致）—— 不写成 `(message notice)`，避免将来文案里出现 `%` 被当格式指令。
3. **③ 的第 4 条 should（root 不存在 → nil）放到 deftest 末尾** —— 计划未规定次序；`--define-world` 会 `ebasecamp-model-reset`，若放中间会让后面「`--write` 打桩 `message`」那条找不到组。
4. **② 的三条断言写在 `cl-letf` 之外** —— `checked-file` / `checked-root` 在 `cl-letf` 内被 `setq`，出作用域后仍可读；断言失败时不会跳过 `--with-root` 的清理。`checked-root` 初值为 `'unspecified`，故 `(should (null checked-root))` 既能区分「传了 root」也能区分「根本没调 check-compose」。
5. **无新增测试助手** —— 复用 `--define-world`（root 传 nil）与 `--with-root`，`cl-letf` 就近内联（`--with-fake-check` 只捕获 FILE，拿不到第二参，无法表达 D2 的断言）。

## 批次 4 记录

（执行 2026-10-26。批次 4 = L3 闭环与目检：4.1 批处理闭环（本文件记录），4.2 用户目检**留给用户体验**、本批次未勾选。基线 HEAD `0298c129e992fd7912966ef09df8237a3598a845`；起始工作区为批次 1–3 的七个 `M` + 未跟踪 `openspec/active/`。本批次**零仓库改动**（探针脚本、清单、生成物、导出文件全部在 `/tmp/ebc-v053/`），未使用任何 `elisp-dev-mcp__*` 工具。）

### 4.1 真实链路闭环

**环境**：docker server `29.9.2`（daemon 可用）；镜像 `alpine:3`（本地已有，离线可用）；`ebasecamp` external network 早在 2026-10-23 20:24 已存在，故 `ebasecamp-command-ensure-network` 只 inspect 未 create。全程**未创建任何容器**（结束 `docker ps -a --filter name=ebc-` 计数 0），唯一真实 docker 调用是 `docker compose … config -q`。

**隔离布局**（全部在 `/tmp/ebc-v053/`，仓库零污染）：`manifest/`（`groups.el` + `projects/noroot.el`）、`cache/`（生成物）、`proj/`（项目 root，含 `conf/app.conf` 空文件）、`out/` / `out2/`（导出目录）、`probe.el`（脚本）、`probe.log`（输出）。脚本用 `let` 把 `ebasecamp-config-directory` 与 `ebasecamp-cache-directory` 绑到上述目录 —— 不读写 `~/.config/ebasecamp/`，也不往 `~/.cache/ebasecamp/` 落生成物（不变量 4 的位置语义不变，只换根目录）。

**运行命令**：

```
cd /home/thomas/Workspace/ebasecamp && SB=$HOME/thomas-emacs/.local/straight/build-31.1 \
  && emacs -Q --batch -L . -L lisp -L $SB/etaf -L $SB/etaf-ui -L $SB/ebox -L $SB/ecss \
     -l /tmp/ebc-v053/probe.el > /tmp/ebc-v053/probe.log 2>&1
```

结果：`exit=0`，`PASS` 37 条 / `FAIL` 0 条，末行 `== 汇总：0 条断言失败 ==`。（日志中的 `Warning (files): Missing ‘lexical-binding’ cookie in "/tmp/ebc-v053/manifest/*"` 是**被加载的清单文件**自身的警告，与既有测试脚手架的同类输出同源，不是脚本错误。）

**五条验证的关键输出原文**：

1. **写盘** —— `1.1 返回 :errors 为 nil => t`；`1.3 文件内容 => "(ebasecamp-define-project noroot\n  :title \"无根项目\")\n"`（**不含 `:root`**）；`1.5 重新加载零错误 => t`；`1.7 (ebasecamp-project-root …) 为 nil => t`；补充 `1.8/1.9`：加入组侧 `:configs ((main :project noroot))` 后加载仍零错误、项目 groups 物化为 `((:group cache :scope per-project :service-overrides nil))`。
2. **预校验降级为警告** —— 用 `setf` 给模型对象加 `:file-configs '(("app_cfg" ("file" . "./conf/app.conf")))`（不改文件）后跑 `run 'start`：`2.3 :ok 为 t => t`；`2.5 警告原文 => ("项目 noroot 无 :root，无法校验顶层 config 'app_cfg' 的 file './conf/app.conf'")`（**恰 1 条**，同时含「无 :root」与 `./conf/app.conf`）；`2.1 派发 args => ("compose" "-f" "/tmp/ebc-v053/cache/noroot/compose.yaml" "-p" "ebc-noroot" "up" "-d" "cache")` —— **不含 `--project-directory`**。
3. **派发参数对照（有 root）** —— `setf` 把 root 设为真实存在的 `/tmp/ebc-v053/proj`（并放空文件 `proj/conf/app.conf`）：`3.1 派发 args => ("compose" "-f" "…/compose.yaml" "--project-directory" "/tmp/ebc-v053/proj" "-p" "ebc-noroot" "up" "-d" "cache")`（flag 在 `-f FILE` 之后、`-p` 之前，符合不变量 15）；`3.2 run 结果 => (:ok t :warnings nil)`、`3.5 :preflight-warnings 为 nil => t`。
4. **导出（无 root，显式路径）** —— `(ebasecamp-export-project project :file "/tmp/ebc-v053/out/compose.yaml")` → `4.1 返回值 => "/tmp/ebc-v053/out/compose.yaml"`；文件存在；`4.6 … => (:ok t :exit 0 :stderr "" :warnings nil)`（`--write` 内部真实跑了 `docker compose -f <target>.tmp config -q`）；另用 CLI 独立复核 `docker compose -f /tmp/ebc-v053/out/compose.yaml config -q` → `exit=0`。内容含 `name: ebc-noroot` / `services: cache: image: alpine:3` / 五个 `ebasecamp.*` 标签 / `configs: app_cfg: file: ./conf/app.conf`，头注释带项目名与事实源路径。
5. **导出提示（有 root，导出到别处）** —— root 恢复为 `/tmp/ebc-v053/proj`、导出到 `/tmp/ebc-v053/out2/compose.yaml`：`5.1 捕获的 message => ("导出目录 /tmp/ebc-v053/out2 不是项目 root /tmp/ebc-v053/proj：生成物里的相对路径（env_file / bind 挂载）在部署时按导出目录解析，请确认相关文件随生成物一同部署。")`（**恰 1 条**含「不是项目 root」）；返回值等于目标路径、文件存在、`docker compose -f out2/compose.yaml config -q` → `exit=0`（提示不影响成败与返回值）。

**收尾状态**：`docker ps -a --filter name=ebc-` = 0（无容器）；未创建容器 / 网络 / 卷（`ebasecamp` 网络为 2026-10-23 既有）；`git status --short` 与批次 3 结束时逐行相同（七个 `M` + `?? openspec/active/`），无新增文件；`/tmp/ebc-v053/` 保留：`probe.el` / `probe.log` / `manifest/{groups.el,projects/noroot.el}` / `cache/noroot/compose.yaml` / `proj/conf/app.conf` / `out/compose.yaml` / `out2/compose.yaml`。

**与计划的偏差**：

1. **没有 `compose create`，「事后 `compose down`」随之不适用** —— 计划 4.1 字面预留了 create/down 的清理要求，但预校验只需 `config -q`，派发层用 `cl-letf` 打桩 `ebasecamp-docker-run-async`（记录 args、返回 `'fake-process` 并同步回调 `(:exit 0 :stderr "")`）即可拿到「派发 args 是否含 `--project-directory`」的完整证据。这既满足任务书的「不启动任何容器」，也避开 v0.5.2 探针发现的「第二次 `create` 静默假成功」坑。
2. **多做了第 3 条对照（有 root 才注入 flag）** —— 任务书要求、计划 4.1 未写。它的价值是让「不含 `--project-directory`」不再是打桩的副作用，而是**条件注入**的正向证据（同一项目、同一插桩，仅 root 不同）。
3. **多出 `1.8 / 1.9` 两条断言** —— 不在任务书 5 条内：`run 'start` 需要项目有物化后的服务，故必须先给组加 `:configs` 并验证加载零错误 + groups 物化，否则第 2/3 条跑不起来（断言顺带把「无 root 项目参与组侧配置」这条路径也钉住了）。
4. **生成物写在 `/tmp/ebc-v053/cache/`**（绑定 `ebasecamp-cache-directory`）而非默认 `~/.cache/ebasecamp/`：避免在用户缓存里留下 `noroot` 目录，同时保持不变量 4 的「生成物在缓存目录下可重建」语义。
5. **`setf` 修改模型槽而非改清单文件** —— 第 2 条的 `:file-configs` 与第 3/5 条的 `:root` 都是对 `ebasecamp-model-project` 返回对象的就地 `setf`（`cl-defstruct` 槽，setf 合法）。这样处理是因为：`noroot.el` 实际由 `add-project` 生成（证明「无 root 不写键」），而后续需要「同一项目」在三种 root 状态下跑，用槽操作比反复写盘更快、也不产生额外清单变体。
6. **4.2 未勾选** —— 用户目检交回 harspower 与用户；本批次只做到 4.1 闭环。

7. **4.2 目检③ 的期望已修正**：计划原写「无 root 导出成功后提示『导出目录不是项目 root』」，与实现矛盾 —— `ebasecamp-export--relative-path-notice` 在 root 为 nil 时返回 nil（无可比较基准），不提示。已把目检③改为「导出成功且 `config -q` 通过、无目录提示」，目录提示的覆盖由 4.1 第 5 条（有 root + 导出到别处）承担。

### 4.3 目检发现的缺陷 A（scope 类型不匹配）

（执行 2026-10-26。基线 HEAD `0298c129e992fd7912966ef09df8237a3598a845`；本批次只改 `test/ebasecamp-ui-tests.el` 与 `lisp/ebasecamp-ui.el` 两个文件，`AGENTS.md` 未动，未使用任何 `elisp-dev-mcp__*` 工具，验证只走 `make check`。）

**缺陷证据（用户目检，2026-10-26）**：界面「新建组」保存时报

```
组 scope 必须是 shared 或 per-project，得到 "per-project"
```

报错发生在**写盘之前**（`ebasecamp-config-write--check-scope` 抛 `user-error`），所以 `groups.el` 永远建不出来；「新建组」与「改组」两支同样命中。

**根因三行**：

1. `ebasecamp-ui--scope-choices` = `'("shared" "per-project")` —— **字符串**表（`completing-read` 只接受字符串，不能改成符号）；
2. `ebasecamp-ui--prompt` 经 `completing-read` 原样返回**字符串**；
3. 写盘层 `ebasecamp-config-write--check-scope` 用 `(memq scope ebasecamp-model--scopes)`，而 `ebasecamp-model--scopes` = `(shared per-project)` 是**符号** → `memq` 恒 nil。

结论：**界面是出错的一侧**（模型层 / 写盘层的契约是符号，且 `ebasecamp-model--check-scope` 同样用 `memq`），因此只改 UI，不改 `--check-scope`、不改 `--scope-choices` 的类型。

**修复方式**：新增界面助手 `ebasecamp-ui--read-scope (prompt &optional initial)`（`lisp/ebasecamp-ui.el:2197`）：

```elisp
(intern (ebasecamp-ui--prompt prompt ebasecamp-ui--scope-choices t initial))
```

`require-match` 恒为 t —— 把输入限制在 `--scope-choices` 内，否则 `intern` 会造出任意符号。两个调用点改用它：新建组（`:2280`）、改组（`:2291`，`initial` 仍是 `(symbol-name (ebasecamp-group-scope …))`）。

**2 项用例**（`test/ebasecamp-ui-tests.el`，均在 `--with-open-ui` + `--prompt-reply` 打桩下）：

| 用例 | 行号 | 断言要点 |
|---|---|---|
| `ebasecamp-ui-test-x-new-group-passes-symbol-scope` | `:3460` | 「新建组」打桩 `--prompt` 按文案应答（清单操作 / 新组名 / 组标题 / scope="shared"）→ `-add-group` 第 1、2 参仍是字符串、**第 3 参 `(eq 'shared …)` 且 `symbolp`**、notice 为 `success`（缺陷现象「写盘前报 scope 非法」消失） |
| `ebasecamp-ui-test-x-edit-group-passes-symbol-scope` | `:3493` | 「改组」对既有组 mysql 打桩返回 `"per-project"` → `-update-group` 第 3 参 `(eq 'per-project …)` 且 `symbolp`、notice 为 `success` |

**红灯证据（实现前）**：

```
Test ebasecamp-ui-test-x-new-group-passes-symbol-scope condition:
    (ert-test-failed
     ((should (eq 'shared (nth 2 ...))) :form (eq shared "shared") :value nil))
   FAILED  451/452  ebasecamp-ui-test-x-new-group-passes-symbol-scope

Ran 452 tests, 450 results as expected, 2 unexpected

2 unexpected results:
   FAILED  ebasecamp-ui-test-x-edit-group-passes-symbol-scope
   FAILED  ebasecamp-ui-test-x-new-group-passes-symbol-scope
```

红项与预期完全一致（450 → 452，多出的 2 项正是新用例，既有 450 项零回归）。

**绿灯证据（`make check`，2026-10-26）**：

- `make check-parens` → `check-parens OK (26 files)`，exit 0
- `make compile` → exit 0，输出 0 行（**零 warning**；此前先 `make clean` 避免旧 `.elc` 干扰）
- `make test` → `Ran 452 tests, 452 results as expected, 0 unexpected (2026-10-26 15:28:57+0800, 5.159701 sec)`
- `ebasecamp-docker-test-run-sync-captures-streams` 未抖动（技术债 #20 未触发）

**与计划的偏差**：

1. **`--read-scope` 放在 `--scope-choices` defconst 之后、`--manifest-menu` 之前**（`:2197`），而不是与 `--read-name` / `--read-optional-path` 并列（后者在 `:2007` 前后）。原因：`byte-compile-error-on-warn` 下前向引用同一文件后面才 `defconst` 的变量会触发「reference to free variable」→ compile 失败；放在 defconst 之后即消除。
2. **无其它偏差** —— 助手名、`require-match` t、两个调用点、不改 `--check-scope` / `--scope-choices` 类型，均按任务书字面执行；未新增其它测试助手（复用 `--prompt-reply` / `--with-open-ui` / `--notice`）。

## 批次 5 记录

（执行 2026-10-26。批次 5 = 文档、版本与归档：5.1 本记录，5.2 归档**未执行**（下一步）。基线 HEAD `0298c129e992fd7912966ef09df8237a3598a845`；起始工作区为批次 1–4 的七个 `M` + 未跟踪 `openspec/active/`。本批次 *只改文档与版本号*，**零 `lisp/` 零 `test/` 改动**，未使用任何 `elisp-dev-mcp__*` 工具。）

### 5.1 文档沉淀

**逐文档改动（文件 → 小节 → 内容）**：

| 文档 | 小节 / 落点 | 改动 |
|---|---|---|
| `AGENTS.md` | 不变量清单（第 15 条之后） | 新增 *不变量 16*「项目 `:root` 可选」：nil 时不参与定位、不作路径基准（派发不带 flag、预校验只给 warning）、导出须显式选路径；写盘 `add-project` 接受 nil、`update-project` 用 `clear-root` 显式清空（键真删，不留 `:root nil`），空串与纯空白仍拒 |
| `AGENTS.md` | 目录结构表 `ebasecamp.el` 行 | `Version: 0.5.2` → `0.5.3`（即「14 处」中的第 14 处） |
| `AGENTS.md` | 目录结构表 `docs/` 行 + 当前状态「架构决策」行 | 追加 ADR-0008 的路径与一句话结论（两处 ADR 清单都补齐，避免新 ADR 只存在于文件系统） |
| `AGENTS.md` | 当前状态 | ①「进行中计划」改为「批次 1–4（含 4.3 目检修复）与 5.1 已完成，待 5.2 归档」；②「测试基线」436 → **452**，写清 436 → 442（批次 1 +6）→ 447（批次 2 +5）→ 450（批次 3 +3）→ 452（批次 4.3 +2，目检驱动的缺陷修复）；③「下一步」改为 v0.6（观测）或先处理 tech-debt #20 / #33 / #41（按用户取舍），并指出 4.2 目检未执行（用户选择跳过，导出视觉项由批次 4.1 的真实 docker 闭环替代） |
| `AGENTS.md` | 已知特性表 | *未新增* —— 「界面新建组 / 改组必报 scope 错误」是缺陷且已修，不属于「已知特性」 |
| `docs/adr/0008-project-root-optional.org` | 全文（新建） | 背景（能力已在运行期下沉、三个入口未开）+ 决策 1 写盘（`--check-root` 判据、`add-project` 的 `when root`、`clear-root` 互斥且先于事务、`--plist-remove` 让键真消失）+ 决策 2 界面（`--read-optional-path`、后果进 prompt 文案而非 `message`、改项目留空的确认与幂等）+ 决策 3 导出（`--target-or-prompt` 四步精确前置判定、非交互仍 signal、校验基准保持导出目录）+ 否决项 ①② + 后果（三条降级 / 提示的三种不提示条件 / 相对 `:export-file` 按 `default-directory`）+ 已知边界 + 不变量 16 + 状态与引用（ADR-0004/0005/0006/0007/0001、技术债 #35/#36/#40） |
| `openspec/decisions.md` | 表格末行 | 追加 2026-10-26 一行：决策「项目 `:root` 可选（写盘 / 界面 / 导出三处放开）+ 界面 scope 类型修复」；理由「能力已在运行期下沉但入口未开；导出校验基准保持导出目录以免校验与部署基准分叉」；详见 `ADR-0008（新增不变量 16）` |
| `Readme.org` | 首行版本号 | `（版本 0.5.2）` → `（版本 0.5.3）`（描述性引用，不在「14 处」口径内） |
| `Readme.org` | 「ebasecamp 是什么」项目条目 | 补「`:root=` *可选*（留空即无根目录项目）」 |
| `Readme.org` | 「projects/example.el 示例」之后 | 新增三段：`:root=` 可选及界面留空的做法；*留空的三条后果*（不参与定位 / 不作路径基准 + 相对 `file:` 预校验降级为警告 / 导出须显式选路径）；*导入的项目通常自带 root*（导入层取 compose 文件父目录，恒非 nil），并提醒「不要为了填空写假路径 —— 它会成为派发基准」 |
| `Readme.org` | 「关键字表」 | 项目定义字段列表改为 `:root=`（*可选*） |
| `docs/user-guide.org` | 「限制与注意事项」表 | ①「导出的路径基准不由插件改写」行补 v0.5.3 的提示原文与「只提示、不改校验基准」；②*新增*「项目 `:root=` 可选（留空 = 无根目录项目）」行（三条降级 + 明确「`（N 条预校验警告）` *不是启动失败*」+ 改项目留空 = 清空并弹确认）；③*新增*「无 `:root=` 但写了 `:export-file=`」行（相对路径按 `default-directory=` 展开，既有语义未改）；④「老清单需重新导入一次」行补两点 —— 重导入会 `--force` 覆盖界面编辑、inline 多行 `content:=` 会被折成单行（技术债 #33）并建议改用 `file:=` 形态 |
| `docs/architecture.org` | 「不变量清单」表与编号注记 | 新增第 15 条（= AGENTS 不变量 16），注记由「那边 1–15、本表 1–14」改为「1–16 / 1–15」并补「第 15 条对应 AGENTS 第 16 条」 |
| `docs/architecture.org` | 「项目定位」小节 | `:root=` 为 *nil* 的情形并列进「跳过」条件（原只有空串 / 目录不存在） |
| `docs/architecture.org` | 「派发参数构造与路径基准」小节 | 新增「`:root=` 为 nil 时的三条回退」条目（派发不带 flag / 预校验 warning / 导出 prompt，指向 ADR-0008）；并把「不注入的两处」里导出那条改写为「v0.5.3 已按『保持导出目录基准 + 提示』处置（技术债 #35）」，去掉过时的 `:209` 行号 |
| `docs/troubleshooting.org` | 第 15 条「（N 条预校验警告）」的「修法」 | 原「项目 `:root` 的可选性是 v0.5.3 的范围，本版只做『回退 + warning』」→ 改为「v0.5.3 起可选：写盘 / 界面 / 导出均已支持，留空后果见 `docs/user-guide.org=`」，并点明「这条警告不再是『清单写错了』」 |
| `CHANGELOG.md` | `## [0.5.2]` 之上 | 插入 `## [0.5.3] - 2026-10-26`：摘要段 + **新增** 4 条（留空 `:root=` / 留空即清空 `:root=` / 无 root 无 `:export-file=` 交互式选路径 / 导出目录 ≠ root 的提示）+ **修复** 1 条（界面 scope 传符号致 `groups.el` 永远建不出来）+ **变更** 3 条（校验基准保持导出目录 / 相对 `:export-file=` 按 `default-directory=` / 基线 436 → 452）。每条都是「先说现象、再说做法」，与既有条目叙述风格一致 |
| `openspec/tech-debt.md` | #33 | 追加 **2026-10-26 实测证据**：`datarush-go` 三个 inline `content:=` 顶层 config 渲染后 `prometheus_config` 896B/35 行 → 762B/4 行、`grafana_clickhouse_datasource` 340B/14 → 282B/0、`grafana_prometheus_datasource` 159B/8 → 137B/0，三者 `config -q` **仍 exit 0**；状态列升级为「**待处理（已实际触发，2026-10-26）**」 |
| `openspec/tech-debt.md` | #35 | 状态列 `待处理` → **已处置（v0.5.3）**，处置计划末尾追加处置结论（保持导出目录基准 + 新增 `--relative-path-notice`、root 为 nil 或目录不存在时不提示、理由引 ADR-0008 否决项 ②） |
| `openspec/tech-debt.md` | 新增 #41 | 生成物固定 `container_name` 与原生 compose 起的同名容器冲突（实测 `clickhouse` / `grafana` / `datarush-mysql` 等 7 个，均不带 `ebasecamp.*` 标签）→ `up` 报 `Conflict. The container name "/x" is already in use`；影响「从原生 compose 迁移必须先停删旧容器且界面无提示」；处置计划两条（①启动前检测同名非托管容器并给可读错误，纯增量；②`container_name` 统一带 `ebc-` 前缀，破坏性变更需迁移路径 + `ebasecamp-prune`） |

**版本号（14 处）**：

```
grep -rl "Version: 0.5.2" --include=*.el . | wc -l     # 改前：13（ebasecamp.el + lisp/ 下 12 个）
grep -rl "Version: 0.5.2" --include=*.el . | xargs sed -i 's/Version: 0\.5\.2/Version: 0.5.3/'
grep -rl "Version: 0.5.2" --include=*.el . | wc -l     # 改后：0
grep -rn "Version: 0.5.3" --include=*.el . | wc -l     # 改后：13
```

- 13 个 `.el` 文件头：`ebasecamp.el`、`lisp/ebasecamp-{command,compose,config,config-write,data,docker,export,import,manifest,model,status,ui}.el`。
- 第 14 处：`AGENTS.md` 目录结构表 `ebasecamp.el` 行的 `已建（包入口，…）`。
- `openspec/completed/` 内的历史计划**未改**（按任务书）。
- 「0 命中」的**口径**：本文件里出现的 `Version: 0.5.2` 是 *计划写作时的历史引文*（记录当时仓库状态），不是漏改的仓库文件；残留检查只针对 `--include=*.el` 与 `AGENTS.md`（两者均 0 命中，见上）。

**grep 校验（关键词命中）**：

```
grep -c "不变量\|16\." AGENTS.md                       # 不变量 16 已写入
grep -n ":root= \*可选\|三条后果" Readme.org            # 命中
grep -n "无根目录项目\|不是启动失败" docs/user-guide.org  # 命中
grep -n "三条回退\|为 \*nil\*" docs/architecture.org      # 命中
grep -n "v0.5.3 起 =:root= 是可选字段" docs/troubleshooting.org  # 命中
grep -n "## \[0.5.3\] - 2026-10-26" CHANGELOG.md        # 命中
grep -n "^| 41 |" openspec/tech-debt.md                 # 命中（#33/#35/#41 三条落点见上表）
ls docs/adr/0008-project-root-optional.org               # 存在
```

**L1/L2 回归证据（`make check`，2026-10-26）**：

- `make check-parens` → `check-parens OK (26 files)`，exit 0
- `make compile` → exit 0，**输出 0 行**（零 warning；先 `make clean` 避免旧 `.elc`）
- `make test` → `Ran 452 tests, 452 results as expected, 0 unexpected (2026-10-26 15:37:45+0800, 5.249340 sec)`；全部文档／版本改动完成后的收尾复跑 → `Ran 452 tests, 452 results as expected, 0 unexpected (2026-10-26 15:39:56+0800, 5.817489 sec)`
- `make check` 整体 → exit 0（日志 `/tmp/ebc-check-b51.log` 与收尾复跑 `/tmp/ebc-check-b51-final.log`）；`ebasecamp-docker-test-run-sync-captures-streams` 未抖动（技术债 #20 未触发）
- 本批次 *不改代码*，452/452 与批次 4.3 结束时的基线一致，属回归确认。

**与计划的偏差**：

1. **`docs/architecture.org` 多做了一处（不变量表第 15 条 + 编号注记）** —— 任务书只要求「路径基准一节补三条回退、定位一节补 root 为 nil 跳过」。但该文件的「不变量清单」表是 AGENTS 不变量 1–15 的映射表，若新增不变量 16 而表不补，会出现「文档表说不变量只有 14 条、AGENTS 说有 16 条」的新分叉（该文件自己就有一段专门解释两表编号不等价的注记）。故一并补第 15 条 = AGENTS 第 16 条，并同步注记的「那边 1–15、本表 1–14」。
2. **`AGENTS.md` 多改两处 ADR 清单** —— 目录结构表 `docs/` 行与当前状态「架构决策」行都追加 ADR-0008。任务书未列，但这两处是 `docs/adr/` 的完整清单，不补则 ADR-0008 只存在于文件系统（渐进式披露的入口地图缺一条）。
3. **`Readme.org` 首行版本号 `0.5.2` → `0.5.3`** —— 任务书「14 处」口径只含 `Version:` 前缀（13 个 `.el` + AGENTS 一处），不含 Readme 的「（版本 0.5.2）」描述性引用。不改进则用户可见的版本号比包内版本号旧一版，故一并更新（属额外第 15 处，不计入 14 处口径）。
4. **grep 残留检查的口径**：`grep -rn "Version: 0.5.2"` 会命中**本计划文件自身**（「13 处 `Version: 0.5.2` → `0.5.3`」与文档清单表）—— 这是计划写作时的历史引文，不是漏改的仓库文件。验收口径应为「`grep --include=*.el` 与 `AGENTS.md` 零命中」，不要把历史引文一起清零（本次曾误改为「原 0.5.2」，已回退）。
5. **`4.2` 保持未勾选** —— 用户选择跳过目检，任务项本身未执行，故不勾 `[x]`；已在「当前状态」与 `AGENTS.md` 写明「未执行 + 跳过原因 + 替代覆盖（4.1 真实 docker 闭环）」。归档时（5.2）须原样带走这个结论。
6. **`tech-debt #41` 编号连续** —— 现有最大编号为 #40，新条目取 #41，无跳号；#33 保留原号（只追加证据与升级状态标记）、#35 保留原号（只改状态 + 追加结论），无重排。
7. **新建 ADR 跑过 `org-mode-write-format` 的格式化脚本** —— 按任务书「`=code=` 两侧留空格，含中文标点处也要留」，对 *仅由本批次新建* 的 `docs/adr/0008-project-root-optional.org` 执行了 `~/.agents/skills/org-mode-write-format/scripts/fix_org_markup_spacing.py`（幂等，只改定界符外侧），共 32 行间距微调。**未**对既有文档跑该脚本：那会带来 100–250 行/文件的无关重排（既有文件的 `=code=，` 风格本就不统一），与「增量更新、风格与现有结构一致」冲突；本批次对既有文档的改动一律沿用其各自既有写法。
8. **未改动 `lisp/` 与 `test/` 的任何代码** —— `git diff` 可验证：`ebasecamp.el` 与 `lisp/` 下 10 个本批次首次触碰的文件，非 `Version:` 的变更行数均为 **0**（另 3 个 `lisp/` 文件与 3 个 `test/` 文件的代码改动来自批次 1–4，本批次只在其文件头加了版本行）。

### 5.2 归档

（执行 2026-10-26。本批次 = 归档：回退 5.1 的一处误处理 + 计划移入 `openspec/completed/` + 两处文档状态同步。**零代码改动**。）

**① 回退「为让 grep 归零而改写计划自身」**

5.1 曾把 *本计划文件自身* 的两处 `Version: 0.5.2` 历史引文改写成「版本行（原 `0.5.2`）」形式，只为让 `grep -rn "Version: 0.5.2"` 归零。**这是错的**：那两处是计划写作时的历史引文（记录当时仓库状态：13 处 → 14 处），改写历史引文等于伪造记录。已全部恢复原文：

- 任务 5.1 字面 → 「**14 处** `Version: 0.5.2` → `0.5.3`（13 个 `.el` 文件头 + `AGENTS.md:19`）」；验收改为「`grep -rl "Version: 0.5.2" --include=*.el .` 与 `AGENTS.md` 均 0 命中」。
- 注意事项「版本号共 14 处」→ 恢复为「+ `AGENTS.md:19` 目录表里 `已建（包入口，Version: 0.5.2）` 这一处描述性引用」。
- 文档清单表行 → 恢复 `` `Version: 0.5.2` → `0.5.3`（即「14 处」中的第 14 处） ``。
- 「版本号（14 处）」代码块 → 恢复 `grep -rl "Version: 0.5.2" --include=*.el .` 原样（含改前/改后两行），并删掉原先解释「改写才 0 命中」的 bullet，改为口径说明（历史引文不算残留）。
- 5.1 的偏差第 4 条 → 替换为「grep 残留检查的口径」条目（见上）。

**② 归档动作**

- 用 *普通 `mv`*（未用 `git mv`）把计划文件从 `openspec/active/` 移到 `openspec/completed/`（文件名不变，仍为 `2026-10-26-project-root-optional.md`）。
- 「## 当前状态」改写为归档态（阶段 / 已确认 / 结果 / 基线 / L3 / 目检驱动修复 / 回滚点 / 后续 / 批次链，共 9 条）。
- 任务 5.2 勾选 `[x]`；**任务 4.2 保持 `[ ]`** 并在行末追加「（用户 2026-10-26 明确选择跳过；原因与替代覆盖见「## 当前状态」）」。
- 自引用检查：本计划 *正文内不含*「`openspec/active/` + 本文件名」形式的自引用（7 处 `openspec/active/` 均指 *目录* 的历史事实，如「工作区当时未跟踪的 `openspec/active/`」与 5.2 的验收判据，按「不改其它历史引文」原样保留）；外部引用两处已同步改为 `completed` 路径 —— `docs/adr/0008-project-root-optional.org` 的「实现记录见 …」与 `AGENTS.md` 的「已归档」条目。

**③ 验证**

```
ls -A openspec/active/            # 空
ls openspec/completed/ | tail -3  # …2026-10-24-…、2026-10-26-project-root-optional.md、ebasecamp-m1-m3.md
grep -rn "openspec/active/<本文件名>" --include=*.md --include=*.org .   # 无输出（占位符写法：把路径字面写全会让本行命中自身）
make check                        # exit 0；452/452；compile 零 warning；check-parens OK(26 files)
```

**与计划的偏差**

1. **4.2 未勾选的处置沿用了仓库既有归档惯例** —— 先例是 `openspec/completed/2026-10-23-manifest-write-crud.md`：其 W5.8（用户目检）同样保持 `- [ ]` 未勾选，并在「## 当前状态」写明「已归档：W5.8 目检发现的两处阻断缺陷由 v0.5.1 承接修复」，即 **不勾 × 不删 × 在当前状态解释去向**。本次同构：4.2 保留 `[ ]` + 行末一句说明 + 当前状态「L3」条解释跳过与替代覆盖。
2. **`docs/adr/0008` 的引用路径也改了** —— 用户只要求「计划正文里的自引用改成 completed」，但 ADR-0008 的「状态」节引用了本计划的 active 路径，若不改则第 3 步 grep 无法归零；改的是路径不是历史引文，故一并更新。
3. **无其它偏差** —— 未改任何 `lisp/` / `test/` 文件；未新增 commit；`openspec/active/` 未留占位文件。

### 5.3 代码审查后的收尾

（执行 2026-10-26。本批次 = code-reviewer 审查后的收尾清理：删除零调用死代码 `ebasecamp-export--target` + 修正 `docs/adr/0008` 的一处不实表述 + 技术债新增 #42。**除删除死代码外零生产代码改动、零测试改动**——本期无任何测试引用 `--target`，基线保持 452。）

**① 审查结论与 6 条建议的处置**

code-reviewer 结论：**通过**（无阻断项），另提 6 条建议，逐条处置：

| # | 处置 | 理由 |
|---|---|---|
| 1 | 不处理 | 该建议指向的路径在当前实现中**不可达**，无实际触发面 |
| 2 | 不处理，改记技术债 #42 | 「`root` 空白处理两处口径不一致」属实，但属**既有行为**（旧 `--check-root` 同样只校验不 trim），影响低；修复要动写盘层返回值契约与既有断言，超出「收尾清理」范围 |
| 3 | **采纳**：删除 `ebasecamp-export--target` | 仓库内**零调用、`test/` 零引用** → 死代码 |
| 4 | 不处理 | 影响**规模可忽略**，改动收益不抵风险 |
| 5 | 不处理 | 该处写法**刻意保留**，作为与 docstring 对照的示例 |
| 6 | 不处理 | 属**用户配置错误**范畴（清单写错导致），不是插件缺陷 |

**② 采纳建议 3：删除 `--target`，并修正记录**

- 删除前核对：`grep -rn "ebasecamp-export--target" --include=*.el .` 只有定义处 1 处（`lisp/ebasecamp-export.el:97`）+ 两处 `--target-or-prompt` 子串命中；`test/` 零引用。删除（连同 docstring）后，`grep -rn "ebasecamp-export--target\b" lisp/` 只剩 `--target-or-prompt` 的定义（`:97`）与 `export-project` 内的调用（`:300`）。
- **记录修正**：批次 3 记录与本计划 5.1 曾写「`--target` 按要求原样保留（现为无调用方的私有函数，`byte-compile` 不对未使用 defun 报警）」、ADR-0008 曾写「`--target` 保留（纯语义函数，供既有调用与测试）」—— **「供既有调用与测试」与事实不符**：当时 `--target` 已无任何调用方，测试也零引用。历史记录按原样保留（那是当时的决策描述，不改写）；当前事实文档 ADR-0008 已改正并附修订说明。
- 未动 `ebasecamp-export--target-or-prompt`（另一个函数，`export-project` 仍调用它）。

**③ 文档同步**

- `docs/adr/0008-project-root-optional.org`：决策 3 的「`--target` 保留」条改为「已被 `--target-or-prompt` 取代，批次 5.3 审查后删除（零调用、零测试引用）」+ 修订说明；两处行号引用随删除同步（`--target-or-prompt` `:103` → `:97`，`--relative-path-notice` `:133` → `:127`）。
- `openspec/tech-debt.md`：表格末尾新增 **#42**（`root` 空白处理两处口径不一致：`--check-root` 只校验不 trim、`--read-optional-path` 已 trim）。
- 本计划文件：**不改写历史记录**，只追加本节。

**④ 验证**

```
grep -rn "ebasecamp-export--target\b" lisp/ test/   # 仅 2 处 --target-or-prompt（定义 :97 + 调用 :300），无独立 --target 定义
make check                                           # exit 0；Ran 452 tests, 452 results as expected, 0 unexpected；compile 零 warning；check-parens OK(26 files)
```

**与计划的偏差**

无 —— 本批次为审查驱动的收尾，除「删除死代码」外不含新的功能改动；基线 **452** 不变（未新增/删除测试），`lisp/` 只删 1 个无人调用的 `defun`。


