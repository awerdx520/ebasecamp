# ebasecamp v0.2 — 组为中心的界面与「组内配置」模型

## 当前状态

- 阶段：Phase 3（Implement）· 批次 C 进行中（C0–C6 完成）
- 已确认：方案 V3 ✅（用户 2026-10-22）、计划 ✅（用户 2026-10-22 确认；plan-reviewer 三轮审查通过）
- 已完成：批次 A（加载修复）、批次 B（模型 + 物化 + 加载集成）、批次 D（导入/导出往返，含 D4 env_file 与 D5 渲染判据两个阻断缺陷修复）、C0（组为中心的会话与视图骨架）、C1/C2（`ebasecamp-data-group-instances` 组配置实例装配）、C3（段渲染：每份配置一个 `etaf-panel` + 服务表）、C4（段内派发：段内按钮按该段自己的 project 派发到 `ebasecamp-command-run`）、C5（底栏导入/导出/销毁 + 派发路径统一 + 旧项目视图接口迁移）、C6（删除 ETAF Data 适配层，`ebasecamp-data` 收敛为纯装配层）
- 测试基线：293 tests 全绿（C6 后 293，删 9 增 2；C5 后 300；C4 后 299）
- 下一步：C7 界面测试与真实目检（重写 `test/ebasecamp-ui-tests.el` + 用户新 Emacs 目检）
- 待用户：A4 重启 Emacs 后 `M-x ebasecamp` 目检


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
- **D6 物化（materialize）**：配置在组侧声明，加载完成后由 `ebasecamp-model-link-configs` 转换成**与 `ebasecamp-model--group-ref-from-spec` 完全同构**的组引用 plist，并入 `PROJECT.groups` 槽。
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

### 加载期物化算法（`ebasecamp-model-link-configs`）

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

- [x] B1 先写失败测试：`test/ebasecamp-model-tests.el` 新增 `:configs` 用例 —— 合法解析、配置名重复报错、`:project` 缺失报错、`:services` 覆盖格式复用、配置不允许 `:scope`（D9）、组内多配置顺序保持、`:configs` 非 proper-list 报错、配置名非 symbol 报错、`:configs` 缺省或空列表视为「无配置组」而非报错
      （依赖：无）验收：新增用例此时全部失败（红）
- [x] B2 实现 `:configs` 解析与访问器：`ebasecamp-group` 增加 configs 槽；`ebasecamp-model-group-configs`、`ebasecamp-model-config`（按 组+配置名 定位）、`ebasecamp-model-config-project`；`ebasecamp-define-group` 接受 `:configs` 并校验
      （依赖：B1）验收：B1 用例转绿；`make compile` 零 warning
- [x] B3 物化 + 交叉校验：实现 `ebasecamp-model-link-configs`（算法见「加载期物化算法」节），产物键名必须是 `:service-overrides`（D6 不变量）
      （依赖：B2）验收：ERT 覆盖 物化结果结构（含键名断言）、旧 `:groups` + 配置共存顺序（项目侧在前）、四类错误各自命中（缺 project / 项目不存在 / 同项目同组重复 / shared 多配置）；断言错误发生后其余项仍被加载
- [x] B4 旧写法兼容：`ebasecamp-define-project :groups` 保留；仅用旧写法的清单加载结果与 v0.1 完全一致
      （依赖：B3）验收：用现有测试夹具对照 `ebasecamp-model-projects` / `project-groups` 结果完全相等；先确认现有夹具中**没有**「同一项目重复引用同一组」的形态（D2 现已将其改为报错），若存在需先修夹具并在报告说明
      （完成：`legacy-groups-only-load-is-unchanged` / `legacy-and-configs-coexist` 锁定物化零副作用与「旧引用在前」；`legacy-duplicate-group-reference-is-error` 锁定 D2 行为变更，错误由 `ebasecamp-config--validate-projects` 报出、`:file` 指向项目文件。现有夹具无重复引用形态，无需改夹具）
- [x] B5 加载流程改造：`ebasecamp-config-load` 顺序改为「清空注册表 → 加载 groups.el → 加载 projects/*.el → link-configs → 汇总错误」；任一步错误收集不中断
      （依赖：B3）验收：ERT 覆盖 目录缺失、groups 语法错、项目引用未定义组、配置引用未定义项目、link 阶段错
      （完成：顺序为 文件加载 → `--validate-projects` → `--link-configs`，错误按定义期在前、物化期在后汇总；link 错误的 `:file` 统一补填 `<dir>/groups.el`）
- [x] B6 全量回归：`make check` 全绿；报告测试总数（新增项使基线高于 234，需在报告中给出新数字）
      （依赖：B1–B5）验收：退出码 0，无 unexpected
      （完成：`make check` 退出码 0，`check-parens OK (22 files)`，`make test` 267/267，`make compile` 零 warning）

### 批次 D：导入适配（前移到 C 之前）

- [x] D1 先写失败测试：`test/ebasecamp-import-tests.el` 增/改用例 —— 落盘文本含 `:configs`、含 `:project`、不含顶层 `:groups`；旧断言先红
      （依赖：B6）验收：新断言此时失败（红）
      （完成：新增 4 项 —— `apply-writes-configs`（含 `:configs ((`、`:project <项目名>`、`((probe-app :project probe-app))`）、`apply-does-not-write-project-groups`（项目定义段与全文均无 `:groups`）、`apply-roundtrip-loadable`（加载零错误 + groups 槽有带 `:service-overrides` 键的 ref + `:scope` 为 per-project）、`apply-keeps-var-references`（`${VAR}` 原文保留、无探针明文、无 `\$` 转义）。红阶段实测：271 项中 3 项 FAILED（writes-configs / does-not-write-project-groups / roundtrip-loadable），`apply-keeps-var-references` 在 v0.1 已成立故天然绿（作回归护栏））
- [x] D2 实现：`ebasecamp-import-apply` 落盘格式改为 `ebasecamp-define-group <组名> :configs ((<项目名> :project <项目名>))` + `ebasecamp-define-project`；保持「写后自校验 + 失败回滚」
      （依赖：D1）验收：D1 转绿；落盘文件可被 `ebasecamp-config-load` 加载且零错误
      （完成：`ebasecamp-import--group-form` 生成 `:title <组名>` + `:scope per-project` + `:services` + `:configs ((<组名> :project <组名>))`（配置名 = 组名 = 项目名，覆盖留空不写 `:services`）；`ebasecamp-import--project-form` 去掉 `:groups`（两处都写会命中 D2 的「同项目同组双引用」加载错误）；`ebasecamp-import--manifest-content` 注释头对齐 `ebasecamp-create-sample-config` 模板（`;;; <name>.el --- ...` + 来源 + 安全约定两行）；自校验新增「加载零错误 + 项目已注册 + groups 槽存在指向本组的 ref 且带 `:service-overrides` 键」，失败仍回滚；删除已无用的常量 `ebasecamp-import--imported-group-title`。`make check` 全绿（271/271），落盘示例见执行日志）
- [x] D3 往返：导入 → 加载 → 导出 → `docker compose config -q`（退出码 + stderr 双判据）
      （依赖：D2）验收：导出物通过校验；`${VAR}` 原样保留；无明文密钥
      （D3 实测结论（2026-10-23）：含 `env_file` 的服务导入成功、**导出失败** —— `未通过 compose 校验（退出码 1）：services.db.env_file must be a string`。根因三处：①`ebasecamp-import--env-file` 把 `env_file` 当 volumes 语义返回 `((:source PATH :type env) …)`；②该值经 `ebasecamp-import--extra` 进 `:extra` 的 `"env_file"`；③渲染层 `ebasecamp-compose--mapping-p` 判据 `(and (consp value) (consp (car value)))` 对「单元素 plist 列表」返回 t → 走映射分支 → 产出 `source:` / `":type"` 垃圾键。已拆出计划外任务 D4 修复导入层，`--mapping-p` 另记技术债（#21）。修后由下一轮重跑本任务）
      （D3 完成（2026-10-23，伴随 D5 重跑）：真实 docker 闭环 11/11 PASS —— `/tmp` 下造 compose（`ports: ["127.0.0.1:18097:80"]` + `env_file: [./db.env]` + `EBC_D5_SECRET=${EBC_D5_SECRET}`）→ 导入 → 加载零错误 → 导出到项目根 `<root>/docker-compose.ebasecamp.yaml` → `docker compose -f <导出> config -q` 退出码 0、stderr 仅 `level=warning`（未设变量的默认空串告警，非 error）、`--no-interpolate` 下保留 `${EBC_D5_SECRET}` 字面量、`config --format json` 退出码 0；导出物无 cons 垃圾键、无明文探针。D5 子任务记录了渲染层修复）
- [x] D4 修复 env_file 往返缺陷（计划外新增）：`ebasecamp-import--env-file` 归一为**相对路径字符串列表**，去掉 volumes 语义的 `:source` / `:type`
      （依赖：D3 实测）验收：新增 ERT 先红后绿；含 `env_file` 的项目导出文本为 `- ./<name>.env` 形态、段落 ≤5 行且不含 `source:` / `":type"`；导出经打桩校验可落盘
      （完成：`ebasecamp-import--env-file` 改为「字符串原样 / 对象取 `path` / 无 path 项丢弃、保持顺序」，返回如 `("./api.env")`；`ebasecamp-import--extra` 结构不变（仍放 `"env_file"` 键），渲染层走序列分支输出 `- ./api.env`（纯路径不触发引号）。**未改** `ebasecamp-compose--mapping-p`（影响所有渲染路径，风险大；该误判另记技术债 #21）。测试：新增 4 项（`env-file-maps-to-path-string-list`、`env-file-object-form-keeps-path`、`env-file-export-roundtrip-renders-string-list`、`env-file-export-passes-check`）+ 改写 1 项旧断言（`extra-env-file-and-unknown-fields` 由 `((:source "./api.env" :type env))` 改为 `("./api.env")` —— 旧断言固化的正是缺陷形态）。红阶段实测 5 项 FAILED（4 新 + 1 改写）；转绿后 `make test` 275/275、`make check` 退出码 0（check-parens OK 22 files、compile 零 warning）。残留：`ports` 的 `:extra` 载荷（非 tcp / 绑定宿主 IP 的端口）仍会被 `--mapping-p` 误判，见技术债 #21）
- [x] D5 修渲染层 mapping 判据（计划外新增，技术债 #21 阻断级）：`ebasecamp-compose--mapping-p` 判据由 `(and (consp value) (consp (car value)))` 收紧为 `(and (consp value) (consp (car value)) (stringp (caar value)))`
      （依赖：D3 实测 + D4）验收：新增 ERT 先红后绿；含绑定宿主 IP 端口的项目可导出、ports 段为合法长语法（`-\n  host_ip: …`）；`docker compose config -q` 退出码 0；现有 labels / environment / healthcheck / volumes / networks 渲染用例保持绿
      （完成：`lisp/ebasecamp-compose.el` 仅改判据一处（含 docstring 说明「键必须是字符串」）；`((alist))` 这类「元素为 alist 的列表」改走序列分支 → `-\n  host_ip: 127.0.0.1\n  published: "18097"\n  target: 80`（compose 长语法，`config -q` 通过）。判定表核查全部渲染路径：environment / labels（string alist → 映射，前后一致）、healthcheck（plist 走 `--healthcheck-body`，不经 `--yaml-value`，前后一致）、ports（service-body 先格式化为 `"p:t"` 字符串列表 → 序列，一致）、volumes 挂载串 / networks / depends_on（字符串列表 → 序列，一致）、`:extra` 标量值与嵌套 alist（→ 映射，一致）；**输出变化仅限**「元素为 alist 的列表」：`ports` / `volumes` 对象列表（原来渲染成 `(host_ip . 127.0.0.1):` 垃圾键，现为合法序列）与同类 list-of-alists 载荷（如 `logging: [{driver: json-file}]`，原来同样产出垃圾键）。测试：新增 3 项（`ebasecamp-compose-test-mapping-p-rejects-plist-list`、`ebasecamp-compose-test-yaml-renders-port-object-list-as-sequence`、`ebasecamp-export-test-render-host-ip-port-passes-config-q`）；红阶段实测 278 项中 3 项 FAILED（渲染实测输出 `((host_ip . 127.0.0.1) …): null`），转绿后 `make check` 278/278 全绿（check-parens OK 22 files、compile 零 warning）。真实 docker 闭环见 D3 完成说明）


### 批次 C：界面重写

- [x] C0 重写会话与视图骨架：重写 `ebasecamp-ui` 的 session（`state` ref、`selected-group` ref、`busy`、`notice`、`confirm`）；顶栏 + `etaf-splitter` + 左栏 `etaf-tree`（组 → 配置两级）+ 右栏占位 `column`；`ebasecamp-ui-refresh` 改为「快照状态 → 重算 state → 写 ref」。此时 `ebasecamp-data` 的 ETAF 适配仍在但已无调用点，不影响编译
      （依赖：D3）验收：`make check` 全绿；batch 中 `etaf-mount` 到临时 buffer，`buffer-substring-no-properties` 含全部组名与配置名
      （完成：session 槽位改为 `state` / `selected-group` / `expanded` / `busy` / `notice` / `confirm` / `confirm-action` / `notice-timer`（+ 保留 `selected-ref` 供未改动的 `ebasecamp-ui--run-action` 使用）；删除 `controller` 与 `project-ref`，连带删除 `ebasecamp-ui--select-project`、`--group-items`、`--project-running`、`--tab-items`；新增 `ebasecamp-ui--build-state`（组 / 配置 / scope / config-count / summary / empty-p，不做 running 统计）、`--tree-items`、`--tree-key-group`、`--select-key`、`--tree-view`、`--detail-placeholder`；视图 = 顶栏（`ebasecamp` + 统计 + 刷新）+ divider + `etaf-splitter`（ratio 0.32，slot first = `etaf-tree`，slot second = 占位）+ divider；`ebasecamp-ui-refresh` = 采集（可用 `:supplied-p` 跳过，避免轮询重复 `docker ps`）+ 重建 state + 写 ref；`ebasecamp-ui-close` 不再调 `etaf-data-stop`。测试：删除 5 项旧视图用例、改写 2 项、新增 5 项；`make check` 退出码 0，278/278 全绿（check-parens OK 22 files、compile 零 warning）。batch 实测 buffer 文本含 `MySQL  (2)` / `dev  → 示例项目` / `刷新` / `选择左侧的组`）
- [x] C1 先写失败测试：`test/ebasecamp-data-tests.el` 新增 `ebasecamp-data-group-instances` 用例 —— 组有 2 份配置返回 2 个实例、组无配置返回空列表、shared 组单实例且 scope 为 shared、每实例的服务记录与 `ebasecamp-data-project-records` 同源、shared 实例的状态按 scope+group 匹配（构造两个不同 `:project` 的 shared 状态记录，断言都能命中）
      （依赖：C0）验收：新增用例先红
      （完成：新增 7 项 —— `two-configs`（2 配置 → 2 实例，顺序与 `:project-title` 正确）、`no-configs`（组无配置与组不存在均 nil）、`shared-ignores-project`（shared 组配置指向 myapp，running 状态记录的 `:project` 是 other 仍命中；同组另一条 project 为 myapp 的 sentinel 记录命中 exited；对照组 `project-records` 的 redis 仍为 stopped，锁定 D8）、`per-project-filters-by-project`（同名组在 myapp/other 各有记录，各实例只看到自己项目）、`records-match-project-records`（实例 `:records` 与 `project-records` 同组子集逐条 `equal`）、`uses-overrides`（`6380:6379` 覆盖生效）、`defensive-without-link`（配置指向未注册项目且未调 link-configs 时不 signal，记录取组默认定义）。红阶段实测：285 项中 7 项 FAILED（恰为全部新增项）。另加辅助函数 `ebasecamp-data-test--record-of`）
- [x] C2 实现数据装配：新增 `ebasecamp-data-group-instances (group)`，返回 `((:config 名 :project 项目名 :scope S :records (...)) ...)`；shared 按 D8 匹配
      （依赖：C1）验收：C1 转绿；纯函数、无 IO
      （完成：返回项含 `:config` / `:project` / `:project-title` / `:scope` / `:records`，实例按配置定义顺序、记录按服务名升序；新增私有辅助 6 个 —— `--resolve-group`（对象/symbol/字符串 → 组对象）、`--config-ref`（优先项目 groups 槽里同组第一项，即含覆盖的物化 ref；未物化回退 `(:group G :scope S)`）、`--instance-indexes`（双索引：shared 键 `group/service` 只收 `:scope "shared"` 的记录，project 键 `project/group/service`）、`--instance-status`（按 scope 分流，D8）、`--instance-services`（项目未注册时用组默认定义副本）、`--instance-records`（单实例装配）。实测发现并修复一处缺陷：`--service-record` 不归一化 `:group`，把组名 symbol 直接传入会让记录 `:group` 为 symbol（与 `project-records` 的字符串形态不同源，`equal` 比较失败），改为先经 `--name-string` 归一。`make check` 退出码 0，285/285 全绿（check-parens OK 22 files、compile 零 warning）；batch 实测 `status-records-unchanged=t`（不修改 `ebasecamp-status--last-records`）、二次调用 `idempotent=t`、组无配置/组不存在均返回 nil）
- [x] C3 段渲染：每份配置一个 `etaf-panel`（header 槽手搓 row：配置名 → 项目 + scope 徽标 + running/total + 三个按钮）+ `etaf-table` 服务行（首列 checkbox）
      （依赖：C2）验收：batch 断言 段头文案、服务行数、状态文案；无配置组显示「尚未关联任何项目」
      （完成：`ebasecamp-ui.el` 新增段渲染层 —— `--running-count` / `--instance-state`（`:config`/`:project`/`:project-title`/`:scope`/`:running`/`:total`/`:records`）/ `--config-state`（改由实例派生，树节点获得计数）/ `--group-service-names` / `--group-state`（`:instances` + 逐级汇总 `:running`/`:total` + `:service-names`，每组建**只装配一次** `group-instances`，配置项由实例派生）；树文案 `--group-caption` → `"MySQL  (2 配置 · 3/4 running)"`（无服务时省略计数）、`--config-caption` → `"dev → 示例项目  (2/2)"`；新增 `--instance-key`（段内 key `"组名/服务名"`，docstring 写明「同组多实例服务同名 → 选中跨段共享」的第一期语义）、`--busy-p`、`--scope-badge`（per-project→info / shared→warning）、`--ratio-variant`（0/total=0→neutral、全 running→success、其余→warning）、`--instance-caption`、`--section-action`（**占位**，C4 实现派发）、`--section-button`（`:disabled` 由渲染期 busy 求值）、`--instance-header`、`--service-table`、`--instance-section`、`--group-header-row`、`--empty-configs-view`、`--detail-view`（未选中→占位 / 无配置→空态+组定义服务名 / 有配置→组标题行 + 每份配置一段）；`--select-cell` 与 `--columns` 改收 `group-name` 并改用 `--instance-key`（旧的 `ebasecamp-data--item-key` 不再被 UI 使用，函数保留给 data 层）；`--command-key` 兼容两段形态；服务表列宽改为「镜像 / 端口用 `(fr 2)` 抢剩余宽度」——实测 80 列 batch 下右栏约 48 列，定宽相加会把「健康」列挤出可视区。计划外调整两处：段头拆成两行（标题行 + 按钮行），否则窄面板下「停止选中 / 重启选中」被裁切；服务表列宽由 3/9/10/9/10/8 改为 3/9/(fr 2)/8/(fr 2)/5。测试：新增 6 项（`build-state-includes-instances-and-counts`、`render-sections-for-selected-group`、`render-empty-configs-placeholder`、`render-checkbox-writes-selection`、`render-no-selected-group-shows-placeholder`、`header-buttons-disabled-when-busy`）；红阶段实测 291 项中 5 项 FAILED（第 6 项在 C0 骨架下天然绿，作回归护栏），转绿后 `make check` 退出码 0、291/291 全绿（check-parens OK 22 files、compile 零 warning）。batch 实测渲染文本含 `dev → 示例项目`／`prod → 另一项目`／`2/2`／`1/2`／`启动选中 停止选中 重启选中`／`RUNNING`／`STOPPED`／`服务 镜像 状态 端口 健康`）
- [x] C4 段内派发：勾选服务 → 段内按钮 → `ebasecamp-command-run action project keys`；busy 期间该段按钮 `:disabled`；失败走既有 notice（stderr 首行 + 详情）
      （依赖：C3）验收：ERT 用 mock 断言派发的 project 与 keys 正确、双击只派发一次、busy 期间拒绝
      （完成：`--section-action` 由占位改为 `(action instance)`，判定顺序严格为 busy（info「操作进行中」）→ 实例 `:project` 为空（info「该项目未定义」）→ 选中集合为空（info「未选中服务」/「请先勾选要操作的服务」）→ `start` 才做 `ebasecamp-command-port-conflicts`（`duplicate`/`busy` → error「端口冲突」+ 摘要并拒绝；`unknown` → info「端口提示」+ 摘要后继续）→ 派发；keys 取 `ebasecamp-ui-selected-keys`（段内 `"组名/服务名"`），project 取该实例自己的 `:project`（字符串），不经 `ebasecamp-ui-current-project` 兼容层，故同组多实例不串段。新增 `--section-dispatch`（复用 `--on-complete` 完成回调：复位 busy → 刷新 → `--report-result`；派发前置 busy=t，任何 error（含命令层 `ebasecamp-command-busy`）→ 复位 busy + error「命令派发失败」，未复用旧的 `--dispatch`——旧路径把命令层 busy 提示为 info「操作进行中」，C5 合并两条路径时统一）。`--section-button` 签名改为 `(label action variant instance disabled)`，`:on-press` 为 `(lambda () (ebasecamp-ui--section-action action instance))`，`:disabled` 仍由 `--busy-p` 在渲染期求值为布尔。旧接口全部保留并加 docstring 标注「C5 将迁移到「选项目」语义；当前仅为旧调用点保留」：`ebasecamp-ui-run-action` / `ebasecamp-ui-confirm` / `--run-action` / `--confirm-dialog`（旧链路 `--action-button` / `--action-bar` 未改）；`ebasecamp-command-port-conflicts` 旧调用点标注「遗留调用点」。测试新增 8 项（`section-action-dispatches-with-instance-project`、`-uses-own-project-per-instance`、`-rejects-when-busy`、`-rejects-empty-selection`、`-blocks-on-port-conflict`、`-allows-soft-conflict`、`-double-click-dispatches-once`、`-resets-busy-on-dispatch-error`），并把 C3 的 `header-buttons-disabled-when-busy` 按钮打桩改为 5 参（记录 instance）；红阶段实测 299 项中 9 项 FAILED（8 个新用例 + 该打桩项因 arity 变更），转绿后 `make check` 退出码 0、299/299 全绿（check-parens OK 22 files、compile 零 warning）。真实 docker 一次未跑，命令层与端口检测全部 `cl-letf` 打桩）
- [x] C5 底栏：导入 compose（沿用现有链路）、导出 compose（`completing-read` 选项目）、销毁环境（选项目 + `etaf-dialog` 二次确认）
      （依赖：C4）验收：batch 断言三个入口存在；`M-x` 调用时取消 `completing-read` 静默返回 nil
      （完成：底栏为主视图 column 底部三按钮（`--footer-view`，ghost，`row :item-gap '(ch 2)`）：导入 compose / 导出 compose / 销毁环境；三者都不是生命周期动作，故不参与 `busy` 判定（销毁的危险性由二次确认承担）。导出与销毁都改为 `completing-read` 选项目（`--read-project`，候选为清单项目名的 `symbol-name`；清单无项目 → info「没有可用项目」+ nil；`quit` → 静默 nil）——`ebasecamp-ui-current-project` 兼容层因此无调用点并删除。导出仍绑 `ebasecamp-export--interactive` t（冲突三选一在事件回调里可用），成功 notice success「导出完成」+ 路径，失败走既有 error notice。新增 `ebasecamp-ui-destroy-environment`：选项目 → `confirm-action` = `(down . 项目名)` + `confirm` ref t → 确认框；`ebasecamp-ui-confirm` 取 `(动作 . 项目名)`、先清空确认状态，再 `(ebasecamp-ui--dispatch session 'down project nil)`（keys 为 nil = 全部服务）；确认文案「将停止并移除项目 <名> 的全部 per-project 容器，不会删除卷。shared 组不受影响。」。派发路径统一为一个 `ebasecamp-ui--dispatch`（段内 `--section-action` 与销毁确认都走它）：`ebasecamp-command-busy` → info「操作进行中」/「请等待当前命令完成」，其他 error → error「命令派发失败」+ 消息，均复位 busy；`--section-dispatch` 删除。删除清单（grep 确认无调用点）：`ebasecamp-ui--action-button`、`--action-bar`、`--bar-button`、`--run-action`、`ebasecamp-ui-run-action`、`ebasecamp-ui-current-project`、`--section-dispatch`；`--confirm-dialog` 由组件 `ebasecamp-ui-confirm-dialog` 取代（`:render` 读 `confirm` ref，否则文案会在父组件上次渲染时固化成「（未选择）」）。主视图 column 末尾追加 divider → 底栏 → notice → 确认框。测试：新增 9 项（`renders-footer-buttons`、`export-without-projects-notices`、`export-selects-project-via-completing-read`、`export-cancel-is-silent`、`destroy-requires-confirmation`、`destroy-confirm-dispatches-down`、`destroy-dialog-text-mentions-project`、`dispatch-busy-maps-to-info`、`dispatch-other-error-maps-to-error`），删除 8 项（`current-project-compat-shim`、6 个 `run-action-*`、`export-without-project`），改写 5 项（`close-stops-polling`、`on-complete-clears-busy`、`section-action-resets-busy-on-command-error`（原 `...-on-dispatch-error`，busy 语义变更）、`export-success`、`export-failure`）；红阶段 300 项中 8 项 FAILED（第 9 项 `dispatch-other-error-maps-to-error` 在旧 `--dispatch` 下天然绿，作回归护栏）。`destroy-dialog-text-mentions-project` 的 batch 断言改为「文案函数 + 组件已注册」——实测 `etaf-dialog` 走 root-layer 投影，挂载后 buffer 文本为空串。转绿后 `make check` 退出码 0、300/300 全绿（check-parens OK 22 files、compile 零 warning）。真实 docker 一次未跑，命令层全部 `cl-letf` 打桩）
- [x] C6 清理数据适配层（放在 UI 重写之后，避免 `make compile` 空窗）：删除 `ebasecamp-data` 中 ETAF Data 适配（`ebasecamp-data-source`、`-controller`、`-refresh`、`--load`、`--query-records`、`--slice`、`--filter`、`--field-equal`），保留纯装配函数（`--name-string`、`--service-ports`、`--item-key`、`--group-ref-scope`、`--record-lessp`、`--service-record`、`ebasecamp-data-project-records`、`--status-index`、`--resolve-project`）；同步删除 `test/ebasecamp-data-tests.el` 中 ETAF 适配相关用例，并在报告中列出「保留用例清单」（须含 `project-records` / `service-ports` / `record-lessp` / `item-key` 的用例）
      （依赖：C5）验收：`make check` 全绿；`grep -rn 'etaf-data' lisp/` 输出为空（0 行匹配）；报告删除用例数与新测试总数
      （完成：`lisp/ebasecamp-data.el` 421 → 300 行（−121）。删除 9 个定义 —— `ebasecamp-data-source`、`-controller`、`-refresh`、`--load`、`--query-records`、`--slice`、`--filter`、`--field-equal`，以及仅被 `--query-records` 使用的 `--all-records`（grep 确认无其他消费者）；连带删除 `(require 'etaf)` 与 Commentary 里的 ETAF Data 适配段落，改述为「纯装配层：不依赖任何 UI 框架、不做加载 / 查询 / 分页 / 轮询、不起定时器不持 buffer」。保留全部纯装配 API（`--name-string`、`--service-ports`、`--item-key`、`--status-index`、`--resolve-project`、`--group-ref-scope`、`--record-lessp`、`--service-record`、`ebasecamp-data-project-records`、`ebasecamp-data-group-instances` + 6 个实例辅助），其中 `--item-key` 因 `--status-index` 仍在调用而保留。测试：删除 9 项（`source-shape`、`load-all`、`load-project-string`、`load-project-symbol`、`load-plist-query`、`load-unknown-project`、`load-paging`、`controller-load`、`refresh-picks-new-snapshot`）、新增 2 项补覆盖（`group-ref-scope`、`resolve-project` 此前只有间接覆盖）、改写 5 项（`item-key` 改直调 `--item-key`；`manifest-only-services-are-stopped` / `one-running-one-stopped` / `group-instances-shared-ignores-project` / `group-instances-records-match-project-records` 中被删的 `--filter` 改用新测试辅助 `ebasecamp-data-test--by-group`），保留 12 项（`project-records` 4 项 = `manifest-only-services-are-stopped` / `one-running-one-stopped` / `desired-ports` / `project-records-order`，`item-key`，`group-ref-scope`，`resolve-project`，`group-instances` 7 项 = `two-configs` / `no-configs` / `shared-ignores-project` / `per-project-filters-by-project` / `records-match-project-records` / `uses-overrides` / `defensive-without-link`）。`make check` 退出码 0，300 → 293 全绿（check-parens OK 22 files、compile 零 warning）；`grep -rn 'etaf-data' lisp/` 与 `grep -n 'etaf' lisp/ebasecamp-data.el` 均 0 行。遗留：`docs/architecture.org:121-124` 的 `ebasecamp-data.el （4）` 清单仍列三个已删函数，由 E1 承接修正）
- [ ] C7 界面测试与真实目检：重写 `test/ebasecamp-ui-tests.el` 覆盖上述断言；由用户在新 Emacs 里目检一次
      （依赖：C6，且 A4 已完成）验收：`make test` 全绿并报告总数；用户确认界面可用

### 批次 E：文档与收尾

- [ ] E1 承接原计划 T5.2：写 `docs/architecture.org`、`docs/user-guide.org`、`docs/compose-generation.org`、`docs/troubleshooting.org`，全部按 v0.2 新模型描述
      （依赖：C7）验收：四份文档存在；compose-generation 的映射表与实现一致；troubleshooting 覆盖权限/端口冲突/config -q 失败/版本不符/「命令不存在」排查
      注意：`docs/architecture.org:147,149,185` 与 `Readme.org:180` 仍引用已删除的 `ebasecamp-ui-run-action` / `ebasecamp-ui-current-project`，E1/E2 必须同步修正
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

## 兼容性注意

本版有两处**破坏性变更**，升级 v0.1 清单时按此逐条核对：

1. **D2 · 同一项目重复引用同一组现在报错**：v0.1 里旧 `:groups` 重复引用同一组是**静默允许**的（`ebasecamp-command--selection` 与 `ebasecamp-compose-render` 都「取首个」，第二份的 `:service-overrides` 被静默丢弃）；v0.2 起**加载即报错** `ebasecamp-config-duplicate-group-ref`。修法：删掉重复项，把差异并入唯一那一项的 `:services` 覆盖。
2. **D4 · `env_file` 清单形态变更**：由 `((:source PATH :type env))`（volumes 语义）改为**路径字符串列表**（如 `("./api.env")`）。**D4 之前导入的清单需重新导入**，否则导出仍会失败（渲染层把旧形态写成非法 `env_file`，`docker compose config -q` 报 `services.<name>.env_file must be a string`）。

## 注意事项

- **物化的副作用**：`ebasecamp-project-groups` 在加载后返回「项目侧 :groups + 配置侧物化」的合并结果；测试里若有 `(setf (ebasecamp-project-groups …))` 需改为在加载前构造再 link
- **同项目同组双引用一律报错**（D2）：不做静默合并，因为 `command.el:176` 与 `compose.el:496` 都是「取首个」，合并语义会让覆盖来源不可预测
- **shared 状态匹配**：只能按 `:scope "shared"` + `:group`，按 project 过滤会漏（标签记的是发起项目）
- **D1 禁止回退**：shared 组配置若缺 `:project` 直接报加载错误，不允许静默落到某个默认项目
- **D9**：配置不提供 `:scope`，scope 恒等于组定义值
- **不要在 `config` 任务里跑 ERT/批量 flymake**；elisp 验证一律先 `set_task verify`（隔离实例），收尾 `set_task auto` + `iso_stop`
- **打印陷阱**：对 etaf 渲染 buffer 取 `buffer-string` 后 `prin1` 会 100% CPU 死循环（本轮实测），只用 `buffer-substring-no-properties` / `length`
- **禁止 UI 层拼 docker 命令**；禁止写回项目 compose（除显式 export）
