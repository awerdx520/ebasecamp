# ebasecamp v0.2 — 组为中心的界面与「组内配置」模型

## 当前状态

- 阶段：Phase 3（Implement）· 批次 A 完成，等待用户重启目检
- 已确认：方案 V3 ✅（用户 2026-10-22）、计划 ✅（用户 2026-10-22 确认；plan-reviewer 三轮审查通过）
- 已完成：A0–A3（recipe 指向本地仓库 + 真实构建树重建 + 临时 daemon 冒烟）、A5（tech-debt #18/#19）
- 下一步：A4 用户重启 Emacs 后目检 → 批次 B（模型层 TDD）

## 目标

1. 修复「`M-x ebasecamp` 打不开」——根因是运行中的 Emacs 里根本没有加载该包（straight recipe 指向远程上游，且 build 晚于 daemon 启动）。
2. 把主界面从「项目 → 组 → 服务」反转成「**组 → 配置 → 项目实例**」：组是全局第一等对象，不依赖任何项目即可见；一份配置手动关联一个项目。
3. 尽量复用既有渲染链，把模型变更的复杂度收敛在 model / config / ui 三个模块内。

## 非目标

- 不做同一项目对同一组的多实例（需新增容器标签维度，记 tech-debt）
- 不做 UI 内的清单编辑器（仍手工编辑 Elisp）
- 不做清单 ↔ 项目 compose 双向同步
- 不做远程 DOCKER_HOST / Kubernetes

## 设计决策

- **D1 shared 组**：至多 1 份配置，且 `:project` **必填**（作为宿主/发起项目）。理由：`ebasecamp-compose-render` 必须有 project 上下文（`--check-project` + 遍历 groups 槽），且全 shared 渲染的 compose 名恒为 `ebc-shared`，多宿主会互相覆盖生成物。界面段头显示「全局共用 · 宿主 <project>」，文案需强调「宿主仅作渲染与标签归属，非业务绑定」。
  - 修正记录：原方案曾考虑「`:project` 可省略」，因会迫使引入「虚拟项目」隐式概念而否决（plan-reviewer 认定此修正在自洽性上成立，且无更简单替代）。
- **D2**：同一项目 + 同一组只允许 **1 个引用**（容器标签无配置维度，服务名会撞）。该约束同时覆盖三种来源：配置侧同组多份、旧 `:groups` 与配置侧指向同组、旧 `:groups` 内重复引用同组 → **一律加载报错**，不做静默合并。
  - 依据：`ebasecamp-command--selection`（command.el:176）用 `cl-find … :group` 取**首个**引用，`ebasecamp-compose-render`（compose.el:496）渲染时同名服务「保留首个」——双引用会让后一份的 `:service-overrides` 静默丢失。
- **D3**：旧写法（项目侧 `:groups ((mysql) ...)`）保留兼容，视作「匿名配置」，配置名 = 组名；加载时先登记项目侧引用，再物化配置侧。
- **D4**：版本号 0.2.0（模型扩展，向后兼容旧写法）。
- **D5**：导出与销毁环境改为用 `completing-read` 选项目 + 确认，不再依赖「当前项目」。
- **D6 物化（materialize）**：配置在组侧声明，加载完成后由 `ebasecamp-model--link-configs` 转换成**与 `ebasecamp-model--group-ref-from-spec` 完全同构**的组引用 plist，并入 `PROJECT.groups` 槽。
  - **键名不变量（新增）**：物化产物必须是 `(:group SYMBOL :scope SCOPE :service-overrides ALIST)`，**不得**写 `:services`。依据：`ebasecamp-model.el:314` 产出 `:service-overrides`，`ebasecamp-model.el:498`（`resolve-services`）与 `ebasecamp-import.el:441` 均按该键读取；写错会导致覆盖静默丢失。
  - 下游因此零改动的读取点（已核实）：`ebasecamp-compose-render`（compose.el:478 经 `--group-refs`）、`ebasecamp-command--selection`（command.el:176）、`ebasecamp-data-project-records`（data.el:146）、`ebasecamp-export--per-project-refs`（export.el:105）、`ebasecamp-compose--ref-scope`（compose.el:202）。
- **D7 界面刷新**：单一 `state ref` + 3s 轮询写 ref；根函数视图读 ref → 整树 patch。段内行用 `etaf-table`（不绑 controller）；**不使用** `etaf-data-grid`（无分组能力，已实测）。
- **D8 shared 状态匹配**：shared 容器标签 `ebasecamp.project` 记的是发起项目，不是 `ebc-shared`；shared 段的状态必须按 `(:scope "shared" AND :group)` 匹配，**不得**按 project 过滤。
- **D9 配置不覆盖 scope**：配置允许键**仅** `:project` 与 `:services`；配置的 scope 恒等于组定义 scope（不提供 `:scope` 覆盖）。由此彻底消除「配置 scope 与组 scope 不一致」的歧义。
  - 表达力说明：ref 级 `:scope` 覆盖在旧写法（项目侧 `:groups`）中仍可用；因此「同一组在不同项目需要不同 scope」需走旧写法或拆成两个组。此不对称是有意取舍，须写入 ADR 0002，避免迁移时被当成能力倒退。

## 数据模型

```elisp
(ebasecamp-define-group mysql
  :title "MySQL"
  :scope per-project
  :services ((mysql :image "mysql:8.4"
                    :ports ((3306 . 3306))
                    :environment (("MYSQL_ROOT_PASSWORD"
                                   . "${EBASECAMP_MYSQL_ROOT_PASSWORD}"))))
  :configs ((dev  :project myapp :services ((mysql :ports ((3307 . 3306)))))
            (test :project other :services ((mysql :ports ((3308 . 3306)))))))

(ebasecamp-define-project myapp
  :title "示例项目"
  :root "~/Workspace/myapp")
```

- `:configs` 元素：`(配置名 . plist)`；plist 允许 `:project`（必填）与 `:services`（服务覆盖，格式与既有组引用的 `:services` 完全一致：`((服务名 :ports …) …)`）。
- 配置名须为 symbol 且组内唯一。
- 物化后每份配置产出一个 ref：`(:group 组名 :scope 组scope :service-overrides 归一化覆盖)`。

### 加载期物化算法（`ebasecamp-model--link-configs`）

1. 遍历全部组的全部配置，逐份解析 `:project`（symbol）→ 查项目对象。
2. 校验（任一命中即记入 `:errors`，**不中断**其余项）：
   - `:project` 缺失 → 「配置 <组>/<配置名> 缺少 :project」
   - 项目不存在 → 「配置 <组>/<配置名> 引用了未定义的项目 <name>」
   - 同项目 + 同组已有引用（来自旧 `:groups` 或另一份配置）→ 「项目 <p> 重复引用组 <g>（来源：…）」
   - shared 组配置份数 > 1 → 「shared 组 <g> 至多 1 份配置」
   - 配置的 `:services` 覆盖了组内不存在的服务 → 「配置 <组>/<配置名> 覆盖了不存在的服务 <name>」（提前到加载期校验，避免延迟到渲染/命令期才 signal）
3. 通过校验的配置转 ref 后 `append` 到对应 `PROJECT.groups` 末尾。

## 界面结构

| 区域 | 组件 | 内容 |
|---|---|---|
| 顶栏 | `row` | 「ebasecamp」+ 组数/配置数概览 + 刷新按钮 |
| 左栏 | `etaf-tree`（两级 children） | 组节点 `mysql  (2 配置 · 3/4 running)`；配置节点 `dev → myapp  (2/2)`；无配置组 `redis  (0 配置)` |
| 右栏 | `column` of `etaf-panel` | 选中组的每份配置一段；段头用 `header` 槽手搓 `row`（配置名 → 项目 + scope 徽标 + running/total + 启动/停止/重启） |
| 段内 | `etaf-table` | 服务 / 镜像 / 状态 / 端口 / 健康；首列 checkbox；`:on-row-press` 预留 |
| 底栏 | `row` | 导入 compose / 导出 compose（选项目）/ 销毁环境（选项目 + 二次确认） |
| 提示 | `etaf-alert` | 沿用现有 notice 机制 |

- 左栏选中组 → 右栏渲染该组全部配置段；未选中时默认选第一个组。
- 无配置的组：右栏显示「尚未关联任何项目」，服务只读（来自组默认定义）。
- 选中集合按「段」隔离：段内选择只影响该段的操作按钮，keys 形如 `"组名/服务名"`。

## 任务

### 批次 A：加载修复（先救命）

- [x] A0 安全点：在 `/home/thomas/thomas-emacs` 记录 `git status --porcelain`；把 `lisp/init-project.el` 备份到 `/tmp/init-project.el.bak-$(date +%s)`，并把现有 ebasecamp 的 `:straight` recipe 整段原文抄进执行日志（供回滚）
      （依赖：无）验收：备份文件存在且 `diff` 与原文件一致；日志含原 recipe 原文
- [x] A1 修改 `/home/thomas/thomas-emacs/lisp/init-project.el` 中 ebasecamp 的 `:straight` recipe 为 `(ebasecamp :type git :local-repo "/home/thomas/WorkSpace/ebasecamp" :files ("*.el" "lisp/*.el"))`；保留 `:defer t`、`:commands`、`:init`、`:general` 全部不变。改前先断言 `local-repo` 路径存在且含 `ebasecamp.el`
      （依赖：A0）验收：`git -C /home/thomas/thomas-emacs diff --stat` 仅 1 个文件；`grep -c ':local-repo'` 为 1
- [x] A2 重建包：删除 `/home/thomas/thomas-emacs/.local/straight/build-31.1/ebasecamp`，在新起实例中 `(straight-rebuild-package "ebasecamp")`（或 `straight-use-package` 重新求值）
      （依赖：A1）验收：新实例内 `(locate-library "ebasecamp")` 指向 `…/build-31.1/ebasecamp/ebasecamp.el`；`(fboundp 'ebasecamp)` 为 t
- [x] A3 冒烟：新起实例里 `(ebasecamp)` 不 signal；`*ebasecamp*` buffer 存在且 `buffer-size` > 0；只用 `buffer-substring-no-properties` 读取（禁止 `prin1`/直接打印带属性字符串）
      （依赖：A2）验收：无 error；文本含示例组名与项目名
- [ ] A4 回滚预案与用户重启：若 A2/A3 失败 → 用 A0 备份恢复 recipe、`straight-rebuild-package`、报告失败原因；成功则由用户重启 Emacs 后 `M-x ebasecamp` 目检
      （依赖：A2、A3）验收：用户确认界面可见；失败路径下 recipe 已恢复且 `git diff` 为空
- [x] A5 把 elisp MCP 桥的两个问题记入 `openspec/tech-debt.md`：① `-32603 启动失败` 三次即熔断，导致全部 `elisp-dev-mcp__*` 工具消失；② socket 缺失时 `emacsclient -s elisp-test` 会静默拉起没有 `--init-directory` 的「假隔离」实例
      （依赖：无，**可与任意批次并行**）验收：tech-debt 新增两条，含复现条件与影响

### 批次 B：模型层（TDD）

- [ ] B1 先写失败测试：`test/ebasecamp-model-tests.el` 新增 `:configs` 用例 —— 合法解析、配置名重复报错、`:project` 缺失报错、`:services` 覆盖格式复用、配置不允许 `:scope`（D9）、组内多配置顺序保持、`:configs` 非 proper-list 报错、配置名非 symbol 报错、`:configs` 缺省或空列表视为「无配置组」而非报错
      （依赖：无）验收：新增用例此时全部失败（红）
- [ ] B2 实现 `:configs` 解析与访问器：`ebasecamp-group` 增加 configs 槽；`ebasecamp-model-group-configs`、`ebasecamp-model-config`（按 组+配置名 定位）、`ebasecamp-model-config-project`；`ebasecamp-define-group` 接受 `:configs` 并校验
      （依赖：B1）验收：B1 用例转绿；`make compile` 零 warning
- [ ] B3 物化 + 交叉校验：实现 `ebasecamp-model--link-configs`（算法见「加载期物化算法」节），产物键名必须是 `:service-overrides`（D6 不变量）
      （依赖：B2）验收：ERT 覆盖 物化结果结构（含键名断言）、旧 `:groups` + 配置共存顺序（项目侧在前）、四类错误各自命中（缺 project / 项目不存在 / 同项目同组重复 / shared 多配置）；断言错误发生后其余项仍被加载
- [ ] B4 旧写法兼容：`ebasecamp-define-project :groups` 保留；仅用旧写法的清单加载结果与 v0.1 完全一致
      （依赖：B3）验收：用现有测试夹具对照 `ebasecamp-model-projects` / `project-groups` 结果完全相等；先确认现有夹具中**没有**「同一项目重复引用同一组」的形态（D2 现已将其改为报错），若存在需先修夹具并在报告说明
- [ ] B5 加载流程改造：`ebasecamp-config-load` 顺序改为「清空注册表 → 加载 groups.el → 加载 projects/*.el → link-configs → 汇总错误」；任一步错误收集不中断
      （依赖：B3）验收：ERT 覆盖 目录缺失、groups 语法错、项目引用未定义组、配置引用未定义项目、link 阶段错
- [ ] B6 全量回归：`make check` 全绿；报告测试总数（新增项使基线高于 234，需在报告中给出新数字）
      （依赖：B1–B5）验收：退出码 0，无 unexpected

### 批次 D：导入适配（前移到 C 之前）

- [ ] D1 先写失败测试：`test/ebasecamp-import-tests.el` 增/改用例 —— 落盘文本含 `:configs`、含 `:project`、不含顶层 `:groups`；旧断言先红
      （依赖：B6）验收：新断言此时失败（红）
- [ ] D2 实现：`ebasecamp-import-apply` 落盘格式改为 `ebasecamp-define-group <组名> :configs ((<项目名> :project <项目名>))` + `ebasecamp-define-project`；保持「写后自校验 + 失败回滚」
      （依赖：D1）验收：D1 转绿；落盘文件可被 `ebasecamp-config-load` 加载且零错误
- [ ] D3 往返：导入 → 加载 → 导出 → `docker compose config -q`（退出码 + stderr 双判据）
      （依赖：D2）验收：导出物通过校验；`${VAR}` 原样保留；无明文密钥

### 批次 C：界面重写

- [ ] C0 重写会话与视图骨架：重写 `ebasecamp-ui` 的 session（`state` ref、`selected-group` ref、`busy`、`notice`、`confirm`）；顶栏 + `etaf-splitter` + 左栏 `etaf-tree`（组 → 配置两级）+ 右栏占位 `column`；`ebasecamp-ui-refresh` 改为「快照状态 → 重算 state → 写 ref」。此时 `ebasecamp-data` 的 ETAF 适配仍在但已无调用点，不影响编译
      （依赖：D3）验收：`make check` 全绿；batch 中 `etaf-mount` 到临时 buffer，`buffer-substring-no-properties` 含全部组名与配置名
- [ ] C1 先写失败测试：`test/ebasecamp-data-tests.el` 新增 `ebasecamp-data-group-instances` 用例 —— 组有 2 份配置返回 2 个实例、组无配置返回空列表、shared 组单实例且 scope 为 shared、每实例的服务记录与 `ebasecamp-data-project-records` 同源、shared 实例的状态按 scope+group 匹配（构造两个不同 `:project` 的 shared 状态记录，断言都能命中）
      （依赖：C0）验收：新增用例先红
- [ ] C2 实现数据装配：新增 `ebasecamp-data-group-instances (group)`，返回 `((:config 名 :project 项目名 :scope S :records (...)) ...)`；shared 按 D8 匹配
      （依赖：C1）验收：C1 转绿；纯函数、无 IO
- [ ] C3 段渲染：每份配置一个 `etaf-panel`（header 槽手搓 row：配置名 → 项目 + scope 徽标 + running/total + 三个按钮）+ `etaf-table` 服务行（首列 checkbox）
      （依赖：C2）验收：batch 断言 段头文案、服务行数、状态文案；无配置组显示「尚未关联任何项目」
- [ ] C4 段内派发：勾选服务 → 段内按钮 → `ebasecamp-command-run action project keys`；busy 期间该段按钮 `:disabled`；失败走既有 notice（stderr 首行 + 详情）
      （依赖：C3）验收：ERT 用 mock 断言派发的 project 与 keys 正确、双击只派发一次、busy 期间拒绝
- [ ] C5 底栏：导入 compose（沿用现有链路）、导出 compose（`completing-read` 选项目）、销毁环境（选项目 + `etaf-dialog` 二次确认）
      （依赖：C4）验收：batch 断言三个入口存在；`M-x` 调用时取消 `completing-read` 静默返回 nil
- [ ] C6 清理数据适配层（放在 UI 重写之后，避免 `make compile` 空窗）：删除 `ebasecamp-data` 中 ETAF Data 适配（`ebasecamp-data-source`、`-controller`、`-refresh`、`--load`、`--query-records`、`--slice`、`--filter`、`--field-equal`），保留纯装配函数（`--name-string`、`--service-ports`、`--item-key`、`--group-ref-scope`、`--record-lessp`、`--service-record`、`ebasecamp-data-project-records`、`--status-index`、`--resolve-project`）；同步删除 `test/ebasecamp-data-tests.el` 中 ETAF 适配相关用例，并在报告中列出「保留用例清单」（须含 `project-records` / `service-ports` / `record-lessp` / `item-key` 的用例）
      （依赖：C5）验收：`make check` 全绿；`grep -rn 'etaf-data' lisp/` 输出为空（0 行匹配）；报告删除用例数与新测试总数
- [ ] C7 界面测试与真实目检：重写 `test/ebasecamp-ui-tests.el` 覆盖上述断言；由用户在新 Emacs 里目检一次
      （依赖：C6，且 A4 已完成）验收：`make test` 全绿并报告总数；用户确认界面可用

### 批次 E：文档与收尾

- [ ] E1 承接原计划 T5.2：写 `docs/architecture.org`、`docs/user-guide.org`、`docs/compose-generation.org`、`docs/troubleshooting.org`，全部按 v0.2 新模型描述
      （依赖：C7）验收：四份文档存在；compose-generation 的映射表与实现一致；troubleshooting 覆盖权限/端口冲突/config -q 失败/版本不符/「命令不存在」排查
- [ ] E2 `Readme.org`：清单示例换成组内 configs 写法，命令表补「加载不到包」排查；示例用具体命令实测：`emacs -Q --batch -L . -L lisp -L $(HOME)/thomas-emacs/.local/straight/build-31.1/etaf -L $(HOME)/thomas-emacs/.local/straight/build-31.1/etaf-ui -L $(HOME)/thomas-emacs/.local/straight/build-31.1/ebox -L $(HOME)/thomas-emacs/.local/straight/build-31.1/ecss -l /tmp/readme-manifest.el --eval '(progn (prin1 (length (ebasecamp-model-groups))) (terpri))'`
      （依赖：E1）验收：命令退出码 0 且输出的组数符合示例
- [ ] E3 `CHANGELOG.md` 追加 0.2.0：模型新增 `:configs`、界面改为组为中心、旧写法兼容、加载修复说明
      （依赖：E1）验收：条目按 Keep a Changelog 分类
- [ ] E4 `docs/adr/0002-group-configs.md` + `openspec/decisions.md`：记录「配置挂组侧 + 加载期物化」的决策与备选方案（虚拟项目、配置独立第三类清单）及否决理由
      （依赖：E1）验收：ADR 含 Context/Decision/Consequences
- [ ] E5 `openspec/tech-debt.md`：新增 shared 组多配置、同项目多实例、UI 无清单编辑器
      （依赖：E1）验收：三条均含影响与触发条件
- [ ] E6 归档：本计划移入 `openspec/completed/`；`openspec/active/ebasecamp-m1-m3.md` 的 T5.2 标注「由 v0.2 计划 E1 承接」并归档
      （依赖：E1–E5）验收：`openspec/active/` 为空；两个计划都在 `completed/`

## 依赖关系

- 批次顺序：**A → B → D → C → E**（D 只依赖模型，早于 UI 执行；C7 的人工目检依赖 A4）
- A5 与全部批次独立，可随时插入
- A 的失败**不阻塞** B/D 的 batch 验证（它们走 `emacs -Q --batch` + Makefile 的 `LOAD_PATH`，不依赖 straight recipe）；但 C7 目检必须在 A4 之后
- 批次内依赖见各任务「（依赖：…）」

## 文档清单

| 文档 | 本计划触发的更新 |
|---|---|
| `AGENTS.md` | 数据模型（组 → 配置 → 项目）、不变量补充：① 配置关联方向（组侧声明）② shared 单配置 ③ **物化产物键名必须为 `:service-overrides`** |
| `Readme.org` | 新清单写法示例、首次使用、「命令不存在」排查 |
| `docs/architecture.org` | 分层与物化机制 |
| `docs/user-guide.org` | 写清单、关联项目、界面操作 |
| `docs/compose-generation.org` | 导入映射表、导出规则（模型变更后复核） |
| `docs/troubleshooting.org` | 权限/端口冲突/config -q/版本/加载失败 |
| `CHANGELOG.md` | 0.2.0 条目 |
| `openspec/decisions.md` + `docs/adr/0002-group-configs.md` | 数据模型决策 |
| `openspec/tech-debt.md` | 桥问题、shared 多配置、多实例、无清单编辑器 |

## 验证标准

- **L1**：`make check-parens` + `make compile`（`byte-compile-error-on-warn`，零 warning）
- **L2**：`make test`（ERT 全绿；基线由 234 变动，每个批次报告当前总数）+ 生成物 `docker compose config -q`（退出码 + stderr 双判据）+ 导入导出往返语义等价
- **L3**：真实容器冒烟（alpine；启动 → 状态回读 → 停止 → down 清理），结束后 `docker ps -a --filter label=ebasecamp.managed=true` 为空
- **UI**：batch 中 `etaf-mount` + `buffer-substring-no-properties` 断言（禁止 `prin1`/直接打印带属性字符串，已知会把 Emacs 拖入死循环）+ 用户真实目检一次
- 每批次结束更新本文件「## 当前状态」区块

## 注意事项

- **物化的副作用**：`ebasecamp-project-groups` 在加载后返回「项目侧 :groups + 配置侧物化」的合并结果；测试里若有 `(setf (ebasecamp-project-groups …))` 需改为在加载前构造再 link
- **同项目同组双引用一律报错**（D2）：不做静默合并，因为 `command.el:176` 与 `compose.el:496` 都是「取首个」，合并语义会让覆盖来源不可预测
- **shared 状态匹配**：只能按 `:scope "shared"` + `:group`，按 project 过滤会漏（标签记的是发起项目）
- **D1 禁止回退**：shared 组配置若缺 `:project` 直接报加载错误，不允许静默落到某个默认项目
- **D9**：配置不提供 `:scope`，scope 恒等于组定义值
- **不要在 `config` 任务里跑 ERT/批量 flymake**；elisp 验证一律先 `set_task verify`（隔离实例），收尾 `set_task auto` + `iso_stop`
- **打印陷阱**：对 etaf 渲染 buffer 取 `buffer-string` 后 `prin1` 会 100% CPU 死循环（本轮实测），只用 `buffer-substring-no-properties` / `length`
- **禁止 UI 层拼 docker 命令**；禁止写回项目 compose（除显式 export）
