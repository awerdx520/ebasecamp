# 变更日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/) 与 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式。

## [0.6.0] - 2026-10-26

界面从「功能都在，但看不见也走不到」补齐到可发现、可达：按钮上直接显示键、vim 手感的方向导航、按一个键跳到任意可见的组 / 配置 / 服务行。三处改动都 *没有* 引入新的强制依赖（avy 是可选依赖，未装时自动降级）。

### 新增

- **底栏与段头按钮直接显示键提示**：`导入 compose` / `导出 compose` / `销毁环境` 变成 `[I] 导入 compose` / `[o] 导出 compose` / `[D] 销毁环境` ，段头三个按钮变成 `[s] 启动选中` / `[x] 停止选中` / `[r] 重启选中` 。提示与 `?` 帮助 *同源*：键位的唯一事实源仍是根级 / 段级两张键表，新增的 `ebasecamp-ui--button-key-hints` 只作渲染索引，测试断言「键必须存在于键表」+「键表 LABEL 按序包含按钮文案」。
- **`j` / `k` 移动焦点、`h` / `l` 在树内折叠展开**：`j` / `k` 只移动焦点，*选中组不变*（换组仍是 `n` / `p` ）；`h` / `l` 走 `etaf-tree` 既有的 `:on-direction` 折叠逻辑，到边界才落回焦点左移 / 右移。四个键都以零参命令转交 etaf 的方向链路（不设 `etaf-set-direction-scheme 'vim` 那个全局方案）。
- **`f` 跳转到组 / 配置 / 服务行**：有 avy 时按提示字母选；未装 avy 时降级 `completing-read` 列表。只跳 *可见* 目标（视口外、未展开的条目不在候选里，全不可见时只提示不移动）。跳转期间暂停 3 秒状态轮询、跳完恢复（只在原本运行中时恢复），`f` 只搬焦点、不改选中组、不切换勾选。

### 修复

- **勾选列定位改用 ref 自校验**：测试助手原先用裸 `search-forward "["` 找勾选列，键提示引入 `[s]` / `[x]` 之后会先命中段头按钮提示，`--checkbox-ref-at-point` 解出 nil（既有用例 `checkbox-refs-are-stable` / `spc-activates-checkbox` 变红）。只认 mark 字形也不行 —— `[x]` 同时是勾选态 mark 与「停止选中」的键提示。现在逐个尝试 `[ ]` / `[x]` 候选并用 ref 自校验，与按钮文案彻底解耦。
- **`f` 的跳转类型判别改用事实源，不再猜 key 前缀**：`--target-position` 原按 `group/` / `config/` 前缀判断「树 key 还是服务行 key」，而组名只受 `[a-z0-9_-]` 约束、没有保留字 —— 组名叫 `group` 或 `config` 时，它的服务行 key（如 `config/redis`）会被误判成树 key，跳转静默失效。改为「key 是否属于当前可见树 key 集合」，并从行 ref 定位里抽出 `--target-row-position` 使两条路径各自可测。

### 变更

- **测试基线 468 → 481**（批次 1 按钮键提示 +4 / 批次 2 hjkl +2 / 批次 3 avy 跳转 +5 / 批次 4.4 补测 +2）。`root-keys-complete` / `root-keys-final-set` 的精确集合与长度随批次同步 16 → 20 → 21，未放宽成「包含」断言。
- **文档**：新增 `docs/adr/0010-ui-observability.org`；`Readme.org` / `docs/user-guide.org` 键位表补 `f` / `j` / `k` / `h` / `l` 与按钮方括号提示；`docs/architecture.org` 补「键位来源：事实源 → 渲染索引 → 按钮文案」与勾选列 ref 自校验；`docs/troubleshooting.org` 同步陈旧计数与吞键说明。

## [0.5.4] - 2026-10-26

修掉一处**静默改配置内容**的缺陷：顶层 `configs` / `secrets` 的 inline 多行 `content:` 经「导入 → 渲染」后被折叠成单行，而 `docker compose config -q` 照样 exit 0 —— 校验通过但内容已变，直到容器启动读到被压平的 nginx.conf / 私钥片段才暴露。多行字符串现在走 YAML 块标量保真往返。

### 修复

- **顶层 `configs` / `secrets` 的 inline 多行 `content:` 经「导入 → 渲染」被折叠成单行**（实测 `prometheus_config` 896B / 35 行 → 762B / 4 行、`grafana_clickhouse_datasource` 340B / 14 行 → 282B / 0 行），而 `docker compose config -q` 仍 exit 0 —— 静默改配置内容，容器启动时才暴露。现在多行字符串走 YAML 块标量（`|-` / `|` / `|+` 按末尾换行数 chomping），双引号标量转义 `\n` / `\r`（字面两字符，否则 flow scalar 仍折叠），flow 序列内的多行值同样保真。
- **`|+`（末尾 ≥2 换行）在同层还有其它键时多算 1 个空行**：块标量自带尾换行，`mapconcat` 又补了一个分隔符，于是 `"x\ny\n\n"` 回读成 `"x\ny\n\n\n"`。改为 `--yaml-join`（前项已以换行结尾则不补）。`|` / `|-` 此前「看起来没问题」只是 clip 恰好吞掉空行，属偶然而非正确。

### 变更

- **多行标量在 block 上下文渲染为块标量**：覆盖走 `--yaml-value` 的位置（顶层 `content:`、服务级 `environment` / `labels`）；`command` 等经 `--service-body` 的字段仍走双引号转义（它们不经 `--yaml-value`，加块标量会改变命令语义）。含 `\r` 的字符串（CRLF）**不走**块标量 —— 一律双引号 + 转义保真，不把 `\r\n` 静默改写成 `\n`。
- **判据**：`config -q` 只校验语法与 schema，不校验 `content=` 的内容。判定往返保真必须用 `config --no-interpolate --no-env-resolution --no-path-resolution --format json` 取回字符串做等值比较。
- **测试基线 452 → 468**（批次 1 +10、批次 2.3 +2、批次 3.3 补测 +4；补测覆盖 code-reviewer 建议的字面反斜线转义、序列分支块标量、首行为空白行、CRLF 走引号路径）。

## [0.5.3] - 2026-10-26

把 v0.5.2 已经下沉到运行期的能力补齐到入口：项目 `:root` 变成真正可选的字段（写盘 / 界面 / 导出三处一起放开），并修掉目检暴露的「界面新建组 / 改组必失败」。

### 新增

- **界面新建项目可留空 `:root`**（无根目录项目）：写盘层接受 nil 且不写 `:root` 键，界面 prompt 直接写明后果「留空则不参与目录定位、导出需显式选路径」。无根目录项目的三条降级是：界面不按目录定位（站在项目目录里打开也不会自动选中）、派发不带 `--project-directory` 且相对 `file:` 的预校验只给警告（成功提示末尾「（N 条预校验警告）」，**不是启动失败**）、导出必须显式选路径。
- **界面改项目时把根目录留空即清空 `:root`**：会先弹一次确认（「清空项目 X 的 :root？…」），答 yes 才写盘；写盘层 `update-project` 新增互斥的 `clear-root` 参数，`:root` 键被**真正删除**而非置 nil（`plist-put … nil` 会让「键存在但值空」与「键不存在」两种形态并存，后续任何 `plist-member` 判定都会误判）。项目原本就无 root 时留空不弹确认（幂等，否则每次只改 `:title` 都要被问一次）。
- **无 `:root` 且无 `:export-file` 的项目可以交互式导出**：导出入口新增 `ebasecamp-export--target-or-prompt`，这种情形下弹 `read-file-name` 让用户当场选路径（非交互调用仍 signal 原文案，脚本须自己传 `:file`）。判定用四步**精确前置事实**而非 `condition-case` 捕获导出错误 —— 宽捕获会把将来任何导出错误都误判成「需要 prompt」。
- **导出到「不是项目 root」的目录时给一条提示**：`ebasecamp-export--relative-path-notice` 在 root 真实存在且导出目录 ≠ root 时 `message` 一次（「生成物里的相对路径（env_file / bind 挂载）在部署时按导出目录解析，请确认相关文件随生成物一同部署」），返回值与成败都不变；root 为 nil 或目录不存在时不提示（清单 root 可能指向尚未创建的目录，否则会每次都误报）。

### 修复

- **界面「新建组 / 改组」必然失败**：界面把 scope 当字符串传给写盘层（`"per-project"`），写盘层按符号用 `memq` 校验 → 恒报「组 scope 必须是 shared 或 per-project，得到 "per-project"」，`groups.el` 永远建不出来（现网清单只有 `projects/` 就是此因）。新增 `ebasecamp-ui--read-scope` 统一 `intern` 成符号并复用到新建 / 改组两支。

### 变更

- **导出校验基准保持「导出文件所在目录」**：不改传项目 root。校验基准必须等于部署基准，否则重现 v0.5.2 刚修掉的「校验通过、启动炸」（技术债 #35 按此结论处置）。
- **无 `:root` 但 `:export-file` 为相对路径时按 `default-directory` 展开**：既有语义，本期未改；文档补说明，避免误以为按项目 root 展开。
- **测试基线 436 → 452**（批次 1 写盘层 +6 / 批次 2 界面入口 +5 / 批次 3 导出入口 +3 / 批次 4.3 界面 scope 修复 +2）。

## [0.5.2] - 2026-10-24

修两处「老清单越用越坏」的阻断级缺陷：项目仍用旧 `:groups` 时界面新建配置必然回滚；生成物在缓存目录导致清单里的相对路径失效。另把 compose 顶层 `configs` / `secrets` 的文件存在性纳入启动前预校验。

### 修复

- **界面新建配置在「项目仍用旧 `:groups`」时必然失败**：同一组同时被项目侧旧 `:groups` 与组侧 `:configs` 引用时，加载层原先一律报 `ebasecamp-config-duplicate-group-ref`，写盘事务因此回滚（实测原文：`写入 …/groups.el 后清单新增 1 个错误，已回滚：项目 example 重复引用组 redis（来源：旧 :groups）`）—— 而示例清单正是这种形态，等于任何新建配置都做不成。现在 `ebasecamp-model-link-configs` 用**双簿记**（`sources` 只承载错误消息来源、`legacy` 只标记「可被接管」）判定：旧引用由组侧配置**原位接管**（列表位置不变，`:scope` / `:service-overrides` 取配置值、不报错），只有**两份以上组侧配置**指向同一项目同一组才报错并点名第一份配置。接管用 `setcar` 改引用 cell，不动 reference plist，基线快照与幂等不受影响（不变量 9 相应修订）。
- **生成物在缓存目录导致顶层 `configs` / `secrets` 的相对 `file:` 失效**：清单里的相对路径（顶层 `configs`/`secrets` 的 `file:`、以 `./` 开头的 `volumes` 源、`env_file`）属于项目根，而 docker 默认按生成物所在的 `~/.cache/ebasecamp/<project>/` 解析，缺失只在容器创建阶段以 `bind source path does not exist` 暴露（`config -q` 照样 exit 0）。现在派发与预校验统一注入根级 flag `--project-directory <项目 root>`（`compose -f FILE --project-directory ROOT -p NAME <subcmd>`），预校验与 `up` / `stop` 用同一基准，不再出现「校验通过、启动炸」。
- **预校验对顶层 `configs` / `secrets` 的 `file:` 缺失无感知**：`docker compose config -q` 只校验 `env_file`，不校验这一层。现在 `ebasecamp-command--preflight` 在逐分支写盘与 `check-compose` **之前**由 Elisp 侧按项目 root 逐条检查 `file:`（绝对路径直接判，相对路径判 `<root>/<file>`，`external: true` / 纯 `name:` 跳过），缺失时给出可读错误并中止（消息形如「顶层 config `app_cfg` 的 file `./conf/app.conf` 不存在（基准：/home/me/proj/conf/app.conf）」）：一个生成物都不写、一个 docker 进程都不派发。

### 变更

- **项目 `:root` 现在决定相对路径基准**：不再只是「在项目中打开」的定位依据与导出落点。项目没写 `:root` 时退回旧行为（按生成物目录解析），此时相对 `file:` 无法校验，预校验只给警告、不阻塞启动。
- **docker 会读取 `<项目 root>/.env`**：`--project-directory` 的 compose 默认行为，其中变量参与生成物解析。插件既不读取也不改写该文件。
- **新建 / 改配置时询问是否清理旧 `:groups` 引用**：界面检测到同项目同组的旧写法引用时弹 `y-or-n-p`（「…旧引用将被组侧配置接管。是否同时删掉这条旧引用？」）。答 yes 才迁移 —— 同文件情形在一次事务内完成，跨文件情形两次事务 + 备份补偿；该组是 `:groups` 唯一元素时整条键移除（不留 `:groups nil`）。答 no 写盘仍成功（走接管兼容），下次再问。写盘层 `migrate-legacy` 默认 `nil`，脚本 / 测试调用零行为变更，绝不静默改写项目文件。`M`（移动配置）不做迁移。
- **成功提示在存在预校验警告时追加「（N 条预校验警告）」**：警告集合刻意命名 `:preflight-warnings`（区别于 `check-compose` 从 compose stderr 抽出的 `:warnings`），经 `run` → `dispatch` → `report` → UI 成功分支透传；警告不改变成败。
- **测试基线 415 → 436**（净新增 21 项；其中 1 项既有用例因语义反转被新增用例顶替）。

## [0.5.1] - 2026-10-23

修复两处阻断级缺陷：清单没有 `groups.el` 时界面写操作全部失败；服务引用 compose 顶层 `configs` / `secrets` 时启动失败。另把 compose 校验前置到启动之前。

### 修复

- **「新建配置 / 改服务字段」在清单没有 `groups.el` 时报错**：写盘层原先把目标文件固定为 `<清单目录>/groups.el`，而导入层把「组 + 项目」一起写进 `projects/<name>.el` —— 于是合法清单上 `-add-config` / `-update-service-fields` / `-update-config-project` / `-remove-config` / `-move-config` / `-update-group` / `-remove-group` 全部报「清单文件 …/groups.el 不存在」。改为 `ebasecamp-config-write--manifest-file-for-group` 按组名跨文件定位（`groups.el` 存在时优先 → `projects/*.el` 字典序），写回组真正所在的那个文件；`e`（`ebasecamp-ui-edit-manifest`）同样定位真实文件，定位失败时降级为打开文件头 + 提示、不阻断。
- **服务引用 compose 顶层 `configs` / `secrets` 时启动失败**：导入把顶层段静默丢弃、渲染层也不输出顶层段，生成物里「引用存在、定义缺失」，`docker compose up` 报 `service "x" refers to undefined config …`。现在 `ebasecamp-project` 新增 `:file-configs` / `:file-secrets` 槽（nil 或键为字符串的 alist，递归校验），导入保留顶层段（未知顶层键经 `ebasecamp-import-warnings` 提示、不阻断导入），per-project 生成物渲染顶层段（段序 `name → services → networks → volumes → configs → secrets`），真实 docker 闭环 `config -q` 退出码 0。v0.5.1 之前导入的清单需对原 compose **重新导入一次** 才能补齐这两个槽（插件不自动改清单）。

### 变更

- **启动前做 compose 预校验**：`ebasecamp-command-run` 在创建 external network 之前 *逐分支*（shared 与 per-project）写生成物并用 `config -q` 校验，全部通过才派发 `up`；任一生效物不合法时零副作用（不建网络、不启动任何容器）并显示 stderr 首行的可读错误。只有 `start` / `restart` 校验，`stop` / `down` 不校验。
- **同名组在多文件定义时写操作拒绝**：同名组在加载层是硬错误（后加载文件整体回滚，其中项目不会出现在界面中），因此写操作对「>1 文件命中」直接 `user-error` 并列出文件，不再静默取第一个；`add-group` 写前扫全清单查重。
- **跨文件移动配置 = 两次事务 + 备份补偿**：源文件移除用 `:keep-backup t` 保留备份，目标文件写入失败时用该备份恢复源文件原文（非单事务原子，见 ADR-0006）。

## [0.5.0] - 2026-10-23

界面内清单写操作：服务 6 个字段的编辑、配置 / 项目 / 组的增删改、配置跨组移动，全部经同一个写盘事务内核（备份 → 原子写 → 错误集差分回滚 → 外部修改检测）。界面 buffer 仍然只读。

### 新增

- **界面内编辑 container 配置（`S`）**：`etaf-dialog` 表单预填 6 个字段 —— `image` / `ports` / `environment` / `volumes` / `command` / `restart`，各字段有独立解析器与带行号的错误提示；保存只提交 *改动过* 的字段，其余字段从清单原文保真带回（`healthcheck` / `labels` / `networks` / `extra` / `entrypoint` / `working-dir` / `user` / `depends-on` 原样保留，`command` 原为 shell 字符串则保持字符串）；某字段被清空 = 删除该键。解析失败时表单不关闭、不写盘。
- **配置操作**：`E` 改配置的 `:project`（`completing-read` 选项目）；`M` 把配置移动到其他组的其他项目（两级选择，写盘在一次事务内完成「源组移除 + 目标组追加」，配置自带的 `:services` 覆盖随之搬走）。
- **配置 / 项目 / 组 CRUD（`X` 清单操作菜单）**：`completing-read` 里 8 项 —— 新建 / 删除配置、项目的新建 / 改 / 删、组的新建 / 改 / 删。新增配置校验「配置名组内唯一」与 D2（同一项目同一组只允许 1 个引用）；新增 / 改项目写 `projects/<name>.el`；新增 / 改组写 `groups.el` 的组 form。
- **新模块 `lisp/ebasecamp-manifest.el`**（纯文本层，无 UI 依赖）：`--scan-forms` / `--scan-text-forms` / `--scan-forms-in-region`（顶层与两级区域 form 定位）、`--locate-form` / `--replace-form` / `--replace-forms` / `--append-form` / `--remove-form`、`--write-transaction` / `--write-new-file` / `--backup` / `--write-file`、以及 `service-form` / `group-form` / `group-form-from-plist` / `config-form` / `project-form` 五个生成器。
- **新模块 `lisp/ebasecamp-config-write.el`**：6 个字段的双向映射纯函数（`ports` / `environment` / `volumes` / `command` / `restart` / `image`，解析失败 `user-error` 带行号）+ 11 个实体操作（`-update-service-fields` / `-add-config` / `-update-config-project` / `-remove-config` / `-move-config` / `-add-project` / `-update-project` / `-remove-project` / `-add-group` / `-update-group` / `-remove-group`）+ 两处引用扫描（`--config-references` / `--legacy-group-references`）。
- **`ebasecamp-config-error-messages`**（`lisp/ebasecamp-config.el`）：取加载结果 `:errors` 的 `:message` 列表，供写盘事务做错误集差分。
- **删除的引用保护与影响提示**：删 *项目* 前扫所有组 `:configs` 的 `:project`，被引用则拒绝并列出「组/配置」；删 *组* 前扫 `projects/*.el` 的旧写法 `:groups`，被引用则拒绝并列出项目名。确认框统一写明「只删清单定义，容器需用 `D` 销毁」。

### 变更

- **写盘走「form 定位 + 事务 + 错误集差分」**：定位只替换目标 form，文件头 / 块间注释 / 兄弟组 / 尾随 form 逐字节不变；写盘七步为「快照错误集 → 内存一次改完 → mtime+size 检测 → 备份 → 同目录临时文件 + `rename-file` 原子写 → 重新加载取新错误集 → 仅新增错误才回滚」，成功删备份，回滚 `signal 'ebasecamp-config-write-error` 并给原文件 / 备份路径。外部修改过清单文件时写入被拒绝并提示 `g` 重载。
- **配置 / 项目 / 组操作带引用保护与写前校验**：D2 冲突、实体不存在、名字非法、scope 非法、项目文件已存在都在写盘 *之前* 用 `user-error` 拒绝，选在清单原文 plist 上校验而非 model 对象。
- **根级键位 12 → 16 条**：新增 `S` / `E` / `M` / `X`，全部带中文 LABEL 并通过 `etaf--keys-validate`。
- **`ebasecamp-import.el` 的三个生成器下沉为 thin wrapper**：`--service-form` / `--group-form` / `--project-form` 调用 `ebasecamp-manifest-service-form` / `-group-form` / `-project-form`，`--literal` 等辅助函数移入 manifest 成为唯一实现，避免两处格式漂移（生成结果字节一致）。同时修正 `--read-forms` docstring 里「`read` 不认 `;` 注释」的错误论断（实测 Emacs 31.1 会跳过）。
- **`volumes` 写回必须是 plist**：`(:source … :target … :type bind|volume [:read-only t])`；`ports` 单段 `N` 解析为 `((N . N))` 且输出恒写两段；`command` 只支持 exec 形式。

### 修复

- **修复批次内的兄弟组丢失缺陷（未发布，仅内部）**：`-add-config` / `-update-config-project` / `-remove-config` / 同组 `-move-config` 原先把组 form 的 *渲染片段* 当作写盘事务的「整份新全文」返回，等于把 `groups.el` 覆盖成单个组（兄弟组、文件头、注释全部丢失）。改为 `--replace-group`（用 `--replace-form` 包住渲染结果）后四处调用点统一修正，并给 `add-config` 用例补「兄弟组与文件头逐字节保留」的回归断言。

## [0.4.0] - 2026-10-23

界面骨架重构：根布局改为 flex 三段式（底栏常驻、左右两栏各自内部滚动）、配色改为跟随 Emacs 主题、左栏宽度可拖动并跨会话记住、新增 `1` / `2` / `3` 区域跳转、在项目目录内打开时自动定位到该项目的配置。

### 新增

- **底栏常驻 + 区域独立滚动**：`导入 compose` / `导出 compose` / `销毁环境` 与提示区固定在窗口底部；左树与右栏各包一层 `:overflow 'scroll'` 的限高容器，配置多时只滚当前区域，顶栏与底栏几何不变（滚动到底后底栏几何与滚动前完全一致），整窗不再滚动。
- **区域跳转 `1` / `2` / `3`**：分别跳到左栏 / 右栏 / 底栏的首个停靠点（根级键从 9 条扩到 12 条）。实现走 `etaf-focus-within` + 三个零参命令（`ebasecamp-ui--focus-tree` / `-detail` / `-footer`），`etaf-focus-within` 的 nil COUNT 即「子树第一个停靠点」。
- **主题跟随**：基础色（前景 / 背景 / 面板 / 边框，9 个）从 Emacs face 取，状态色（26 个）走内置明暗两套 palette，按 `background-mode` 选择，合计 35 个 `:ui-*` token；`M-x load-theme` 后即时生效（属性级刷新，不重挂载）。新增 `defcustom ebasecamp-ui-theme`（默认 `nil` = 完全跟随；plist = 按 token 覆盖，未覆盖的键仍按「face → 内置 palette」生成）。
- **左栏宽度可拖动并跨会话记住**：`etaf-splitter` 的 `:on-change` 接管鼠标 / 键盘拖动，比例钳制在 `[0.15, 0.55]`，持久化到 `<ebasecamp-cache-directory>/ui-state.el`（只存 `(:split-ratio FLOAT)`，`make-temp-file` + `rename-file` 原子覆盖；读取拒绝含 `#.` 的文本、只接受单一形态、越界钳制）。该文件是运行时状态缓存，不是清单。
- **在项目目录内打开自动定位**：`ebasecamp-ui--project-for-directory` 按最长 `:root` 前缀匹配当前 `default-directory`（`file-truename` 双归一、只匹配整段目录、大小写敏感），选中该项目「第一份配置」（组顺序 × `:configs` 顺序首个 `:project` 命中者）所属组；无匹配时保持「未选中组」态。

### 变更

- **界面根布局改为 flex 三段式**：根 `flex :flex-direction 'column :height 'stretch`，顶栏与底栏各 `:flex-shrink 0`，中间区 `box :flex-grow 1 :min-height '(lh 0)` 承担全部收缩。`column` / `row` 不走 flex 算法（子节点的 `:flex-*` 被忽略），因此根必须是 `flex`；`flex` 只接受 `:row-gap` / `:column-gap`。
- **左栏默认宽度 0.38 → 0.26**：`ebasecamp-ui--split-ratio` 改为 `defcustom`（默认 0.26），新增 `--split-ratio-min` / `-max`（0.15 / 0.55）同时作为 splitter 的 `:min-ratio` / `:max-ratio`；会话里真正生效的值由 `split-ratio` 槽位的 `etaf-ref` 承载（只重渲染 splitter，不重建整棵树）。
- **render 区色值全部改用 theme token**：`lisp/ebasecamp-ui.el` 的 render 函数区不再含任何色值字面量（含根 Host 原先硬编码的 `#F8F5EE` / `#252A2E`），色值只允许出现在 `--palette-light` / `--palette-dark` 与 `defcustom` 默认值里，由测试的函数名清单扫描机械守护。
- **主题钩子与界面生命周期绑定**：`ebasecamp-ui-open` 在 `etaf-mount` 之前挂 `enable-theme-functions` / `disable-theme-functions` 并重算一次配色，`ebasecamp-ui-close` 第一行移除（严格对称）；`etaf-theme-provide` 只能在 `:setup` 调用（render 期会被 `etaf--assert-not-rendering` 拒绝）。
- **文档与决策**：新增 ADR-0004（布局、主题与导航，含 6 条否决备选）、`openspec/decisions.md` 五行决策、`AGENTS.md` 不变量第 13 条与当前状态；`Readme.org` / `docs/user-guide.org` / `docs/architecture.org` 分别新增「界面布局」「主题」「在项目中打开」「布局与导航」「布局与主题」节。

### 修复

- **底栏需滚到底才能看到**：底栏原先排在内容之后且没有固定约束，容器一多就掉出视口。现在中间区 flex 撑满剩余高度、底栏 `:flex-shrink 0`，根高恒等于视口高。
- **暗色主题下 badge / alert 是浅色块**：根因是界面从未 `etaf-theme-provide` 过 token，etaf-ui 的语义 palette 只有一套浅色值，整体回退。现在 provide 35 个 token，状态色按明暗切换（`theme-plist-dark-differs` 守护）。
- **左栏过宽**：默认 0.38 挤占右栏服务表格，改为 0.26 并可拖动。

## [0.3.0] - 2026-10-23

界面只读化与完整键位：`*ebasecamp*` 有了 buffer 身份（`ebasecamp-ui-mode` + `buffer-read-only`），键位集中到 etaf Host 的 `:keys`，写入口收敛到 `e`。

### 新增

- **根级键位（9 条）**：`q` 关闭界面（卸载运行时 / 停轮询 / 销毁会话）、`g` 重载清单并刷新、`n` / `p` 下一个 / 上一个组、`e` 编辑当前组清单、`t` 切换当前行勾选、`I` 导入 compose、`o` 导出 compose、`D` 销毁环境。键表单一来源 `ebasecamp-ui--root-keys`，渲染与测试共用。
- **段级键位（5 条）**：`s` / `x` / `r` 启动 / 停止 / 重启该段选中服务，`a` / `A` 全选 / 全不选该段服务（`ebasecamp-ui--section-keys`，捕获该段自己的 instance，同组多实例不串段）。
- **`t` 行级勾选**：point 在服务行内任意单元格都能切换该行勾选；在按钮上是 no-op（不会误触段级动作）。行 ref 与 checkbox ref 由 `组名/服务名` 派生，重渲染后身份不变。
- **`e` 编辑当前组清单**（`ebasecamp-ui-edit-manifest`）：打开 `<dir>/groups.el` 并把 point 定位到 `(ebasecamp-define-group <组名>` —— 界面唯一的写入口。无选中组 / 文件不存在时 `user-error`；组定义找不到时回 `point-min` 并 `message`（不 signal）。
- **`?` 快捷键帮助**：每条键位都带中文 LABEL，`etaf-help` 按 point 所在键链列出根级 9 条 + 段内 5 条；无 LABEL 的条目会被框架静默跳过，故 LABEL 覆盖率由测试守护。

### 变更

- **`*ebasecamp*` 改为 `ebasecamp-ui-mode` 且只读**：`special-mode` 派生 + `buffer-read-only t`，mode 在 `etaf-mount` **之前**启用（反过来做会让 `special-mode` 的 `kill-all-local-variables` 清掉 ebox 的挂载状态，报 `No mounted Ebox tree`）。`q` / `g` 在 mode map 里保留兜底绑定（printing key 实际由 etaf 键层接管）。
- **`q` 关闭界面、`g` 重载清单并刷新**：`q` 是 `ebasecamp-ui-close`（不是 `quit-window`），`g` = `ebasecamp-reload`（内部已刷新，不再二次 `docker ps`）。
- **服务行可聚焦**：`etaf-table` 传 `:on-row-press` 后行 Host 带 `:tab-index 0`，点击行或焦点在行上按 `RET` 切换该行勾选；代价是 `TAB` 停靠点增加。
- **`SPC` = `RET`（ebox 激活语义，不再是勾选键）**：`[32]` 属 `ebox--activation-keys`（节点级 char-property keymap 先于 etaf 键层），无法用 `:keys` 重绑；`SPC` 保持「激活当前控件」（checkbox 上勾选、按钮上按下），行级勾选改绑 `t`。
- **未绑定 printing key 一律被吞**：最外层 Host 加 `:key-scope 'local`，`i` 不再落到 evil 的 insert state；`C-x` / `M-x` / `C-g` / `ESC` 不受影响。
- **文档与决策**：新增 ADR-0003（UI buffer 只读化与 etaf Host 键位，含 6 条否决备选）、`openspec/decisions.md` 两行决策、`AGENTS.md` 不变量第 12 条与「已知特性」表、`docs/troubleshooting.org` 第 11–13 条；`Readme.org` / `docs/user-guide.org` / `docs/architecture.org` 分别新增「界面键位」「界面操作与键位」「UI buffer 身份与键位分层」节。

### 修复

- **界面能进入 insert state / 能打字**：UI buffer 原先没有 major mode、没有只读、根 Host 没有 `:key-scope 'local`，`i` 一路落到 evil。现在只读 + local 边界，打字无处可去。
- **键盘无法切换选中组**：`etaf-tree` 分支节点的 `:on-press` 只做展开 / 收起、`on-select` 只对叶子调用，组节点按 `RET` 只能折叠；新增 `n` / `p` 按 `:groups` 顺序循环切换（含回绕）。
- **无段级动作键**：配置段的启动 / 停止 / 重启原先只有鼠标可点，新增 `s` / `x` / `r` 与全选 `a` / 全不选 `A`。
- **无编辑清单入口**：此前只能自己找路径打开 `groups.el`，新增 `e` 定位到当前组定义。

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
- **`M-x ebasecamp` 只出回执、主界面从不显示**：消息区正常打印「ebasecamp：N 组 · M 配置」，`*ebasecamp*` buffer 也确实创建并 `etaf-mount` 成功（`*Messages*` 无报错、buffer 为 `fundamental-mode` 的未修改状态），但从不显示到任何窗口。根因是 `ebasecamp-ui-open` 把 `pop-to-buffer` 放在 `(called-interactively-p 'any)` 门控内，而 `M-x ebasecamp` 经 `ebasecamp` 命令**普通函数调用**进入，`called-interactively-p` 不跨帧传播、恒为 nil → 永不 pop。现在显示无条件执行（新增 `ebasecamp-ui--display-buffer`：已显示则 `select-window` 复用，否则 `display-buffer-same-window` 替换当前 window，不拆分、不删除其它 window），顺序改为「先显示、后 `etaf-mount`」—— `ebox` 首次即测量到真实窗口宽度（`ebox-refit` 只在尺寸变化时被动触发），`etaf-mount` 失败时恢复原 window buffer 并原样 re-signal；`called-interactively-p` 只保留给回执，故 `M-x ebasecamp` 与 `M-x ebasecamp-ui-open` 两条入口各仍只发一条。附带实测：`(display-buffer-reuse-window display-buffer-same-window)` 组合在无可复用窗口时会 split 出第二个窗口（原 buffer 留在拆出的窗口里），与「不动其它 window」相反，故不采用。

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
