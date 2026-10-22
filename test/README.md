# test/ 测试说明

ERT 测试套件，每个模块一个 `*-tests.el`：`ebasecamp-model` / `ebasecamp-config` /
`ebasecamp-compose` / `ebasecamp-docker` / `ebasecamp-status` / `ebasecamp-data` /
`ebasecamp-ui` / `ebasecamp-command`，外加包入口的 `ebasecamp-tests.el`。

## 运行

```
make test      # 只跑测试
make check     # check-parens + compile + test（提交前必跑）
```

均走 `emacs -Q --batch`，不加载用户 init；`-L lisp` 提供模块，`-L $(STRAIGHT_BUILD)/*`
提供 etaf 系列依赖。`Makefile` 在所有 recipe 里设了 `load-prefer-newer t`——
否则改完 `.el` 后跑测试可能加载到更旧的 `.elc`，得到假结果。

## fixture

`fixtures/` 只放**实测输出原文**，不放手工编造的数据。命名统一为
`<domain>-<desc>.<ext>`，供测试直接读取（`ebasecamp-docker-test--fixture-lines`
按文件名读取并切成非空行列表）。

| 文件 | 用途 | 引用测试 |
|---|---|---|
| `docker-ps-managed.jsonl` | Docker 29.9.1 `docker ps -a --no-trunc --format '{{json .}}'` 两行实测输出（各 16 键） | `ebasecamp-docker-tests.el` 的 `parse-ps-output-*` 系列 |

## 新增测试

1. 在对应 `*-tests.el` 末尾按 `;;; N. 主题` 分节追加 `ert-deftest`，名字沿用
   `ebasecamp-<module>-test-<行为>`。
2. 需要落盘/加载的测试用文件中已有的 `--with-dir` / `--clean` 宏，保证临时目录
   在 `unwind-protect` 中清理，不污染 `~/.config/ebasecamp` 与 `~/.cache/ebasecamp`。
3. 需要 docker 输出的测试用 `ebasecamp-docker--run-sync-function` 注入点伪造结果，
   不要依赖真实守护进程；确实要真调 docker 的测试必须先探测可用性并在缺失时跳过。
   command 层用 `cl-letf` mock `ebasecamp-docker-run-async` / `ebasecamp-docker-run-sync` /
   `ebasecamp-compose-write`；端口探测用 `ebasecamp-command--port-free-p` 注入替身，
   **禁止真实 bind 或真实 docker**。
4. fixture 文件若来自新的实测命令，在 `docker-ps-managed.jsonl` 同目录按
   `<domain>-<desc>.<ext>` 命名，并在上表补一行（含引用它的测试）。
5. `make check` 全绿才算完成；`compile` 目标启用了 `byte-compile-error-on-warn`，
   任何 warning 都算失败。
