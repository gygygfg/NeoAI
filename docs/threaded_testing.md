# NeoAI 测试框架（v3.0）

> [English](en/threaded_testing.md) | **中文**

> NeoAI 自带**轻量自定义测试框架**（无外部依赖，`:NeoAITest` 运行）。
> 所有测试文件位于 `lua/NeoAI/tests/`。旧版文档中提到的 `thread_worker.lua` /
> `thread_scheduler.lua` / `threaded_runner.lua` 及 `:NeoAITestAll` 命令均**不存在**。
> 对应源码：`lua/NeoAI/tests/init.lua`。

## 1. 运行方式

```vim
:NeoAITest              " 运行全部测试
:NeoAITest flow_tools   " 运行指定套件（按名字）
:NeoAITest test_agent test_herder  " 运行多个套件
```

`run_all(...)` 动态加载 `lua/NeoAI/tests/test_*.lua`（幂等），收集所有 `suite` 并执行。
支持按名字过滤（`requested` 匹配套件名）。

## 2. 测试框架 API（tests/init.lua）

### 2.1 套件定义

```lua
local tests = require("NeoAI.tests")

tests.suite("flow_tools", function(describe, it, before_each)
  before_each(function()
    -- 每个用例前的初始化（可选）
  end)
  it("should ...", function(t)
    t.eq(1, 1)
  end)
end)
```

- `suite(name, fn)`：定义测试套件，`fn(describe, it, before_each)`。
- `it(name, fn)`：定义用例，`fn(t)` 收到断言辅助表 `t`。

### 2.2 断言辅助

`it` 的用例回调参数 `t` 包含全部断言辅助：

| 辅助 | 说明 |
| --- | --- |
| `t.eq(expected, actual, msg?)` | 相等 |
| `t.ne(expected, actual, msg?)` / `t.not_eq(...)` | 不等 |
| `t.true_(value, msg?)` | 为真 |
| `t.false_(value, msg?)` | 为假 |
| `t.nil_(value, msg?)` / `t.not_nil(value, msg?)` | nil / 非 nil |
| `t.matches(pattern, value, msg?)` | 字符串匹配 |
| `t.ok(value, msg?)` | 真值 |
| `t.deep_eq(expected, actual, msg?)` | 深比较（`vim.inspect`） |
| `t.sleep(ms)` | 异步等待（返回 Deferred） |
| `t.throws(fn)` | 捕获错误（返回 ok, err） |

### 2.3 运行器

`run_all(...)` 会：

1. **会话隔离**：把会话默认路径重定向到临时目录（`~/.cache/NeoAI-test`），结束后清理并
   恢复内存中的真实会话，防止测试污染真实历史。
2. 动态加载 `test_*.lua`（子进程可用 `NEOAI_TEST_MODULES` **按分片只加载本分片模块**）。
3. 用 `xpcall` 逐个运行用例（带 `debug.traceback`），统计 `passed / failed / errors`。
   首个套件在 fresh worker 上跳过冗余的 `config_store.load` + `plugins.start_all` +
   `tools.reload_tools` 全量重置；默认仅打印失败用例 + 套件摘要（`NEOAI_TEST_VERBOSE=1` 还原明细）。
4. 返回 `{ passed, failed, errors, timings }`；隔离子进程另把结果写入 **sidecar**（小 JSON）。

### 2.4 并行运行器结构（门面 + 子模块）

`parallel.lua` 退化为**薄门面**（保留 `run / shard / _discover / _set_spawner / reset / _abort_all`
签名），并发编排与结果处理拆分为 `lua/NeoAI/tests/runner/` 子模块：

| 子模块 | 职责 |
| --- | --- |
| `runner/config.lua` | 常量、worker/heavy 并发解析、heavy 判定 |
| `runner/timings.lua` | 耗时缓存读写与 `TIMING` 解析 |
| `runner/shard.lua` | LPT 分片、发现清单解析（含 name→module） |
| `runner/spawn.lua` | 子进程执行：日志落盘 + 结果 sidecar、进程树清理 |
| `runner/scheduler.lua` | 有界并发池（trampoline 防重入）与双 lane 编排 |
| `runner/report.lua` | 结果聚合、失败分片懒读日志尾部、报告 |

双 lane：light（多套件/进程，W 路）与 heavy（`sandbox*`/`pty` 一套件/进程，H 路）**重叠执行**，
约束 `#light≤W`、`#heavy≤H`、`W+H≤核数`；`NEOAI_TEST_HEAVY_WORKERS=1` 回退为旧串行通道。

## 3. 测试文件清单

`lua/NeoAI/tests/` 下共 **126** 个 `test_*.lua`（另 `init.lua` 为运行器、`parallel.lua` 为并行运行器、`http_server.lua` / `sandbox_stub.lua` / `sandbox_boundary_helpers.lua` 为测试辅助），按类别划分：

> **权威来源**：下为速览索引，实际清单以 `ls lua/NeoAI/tests/test_*.lua` 为准（新增套件无需回改本文）。

| 类别 | 套件（`test_*.lua`，省略 `test_` 前缀与 `.lua`） |
| --- | --- |
| 内核 / 插件 / 服务 / 运行时 | `kernel`、`plugins`、`services`、`service_tool`、`lazy_plugin`、`lazy_startup`、`commands_plugin`、`keymaps_plugin`、`reload_all`、`lock`、`trace_retention` |
| 会话 / Agent / 上下文 / 模式 | `session`、`session_store`、`session_progress`、`agent`、`runtime_context`、`guard`、`overflow`、`loop_compaction`、`compaction_overlay`、`truncation`、`max_tokens`、`pending_queue`、`sub_agent_result`、`abort_tools`、`modes` |
| 模型 / 协议 / 缓存 | `model_registry`、`model_capabilities`、`model_profiles`、`model_metadata`、`model_picker`、`protocol_adapter`、`prompt_cache`、`cache_strategy`、`cache_usage` |
| 工具系统 | `tools`、`tool_pending`、`tool_result_pruner`、`output_guard`、`approval_hub`、`plan_mode`、`plan_distill`、`todo`、`ask_user`、`read_image`、`web_fetch`、`multimodal` |
| 文件 / Shell / LSP / 文本 | `fs_io`、`guest_fs`、`git_ops`、`lsp_check`、`lsp_guard`、`pty`、`ansi`、`stringx`、`textmetrics`、`sha256`、`merge3` |
| UI | `chat_ui`、`tree_ui`、`chat_keys`、`display_modes`、`fold`、`markdown`、`ui_components`、`geometry`、`incremental`、`stream_batching`、`status` |
| MCP | `mcp_client`、`mcp_transport`、`mcp_bridge`、`mcp_cache` |
| Skills / Herder | `skills`、`herder`、`herder_install` |
| 沙箱（含授权 / 回放 / 观测 / 网络同意） | `sandbox_ai_audit`、`sandbox_background`、`sandbox_boundary_consistency`、`sandbox_boundary_escape`、`sandbox_boundary_net`、`sandbox_conflict_ai`、`sandbox_core`、`sandbox_governance`、`sandbox_hardening`、`sandbox_instance`、`sandbox_loss_audit`、`sandbox_lost_update`、`sandbox_lsp`、`sandbox_maintscript`、`sandbox_merge`、`sandbox_mountview`、`sandbox_namespace`、`sandbox_ops`、`sandbox_overlay_invalidate`、`sandbox_package_signature`、`sandbox_privdrop`、`sandbox_privilege`、`sandbox_publish_async`、`sandbox_review`、`sandbox_script_scan`、`sandbox_secret`、`sandbox_service`、`sandbox_session`、`sandbox_shims`、`sandbox_staging`、`sandbox_symlink`、`sandbox_systemd`、`sandbox_systemd_user`、`sandbox_view`、`grant`、`replay`、`observer`、`review_cache`、`net_consent`、`gateway` |
| 密钥防护 | `secret_async`、`secret_fake`、`secret_highlight`、`secret_provenance` |
| 测试框架 / 基础设施 | `test_runner`、`parallel_runner`、`integration`、`http`、`async`、`timer`、`work_codec` |

## 4. headless 运行

测试可在 headless 模式运行（无需 GUI）：

```bash
nvim --headless "+lua require('NeoAI.tests').run_all()" +q
```

> 具体集成脚本见 `lua/NeoAI/tests/nvim_test.py` 与 `lua/NeoAI/tests/nvim/*.yaml`（若存在）。

## 5. 相关文档

- [testing.md](testing.md)：测试方法与断言。
- [threaded_testing 说明]：本框架为轻量单线程运行器，**没有**多线程测试组件。
