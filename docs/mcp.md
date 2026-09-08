# NeoAI MCP 支持

> NeoAI 作为 MCP **客户端**，连接外部 MCP 服务器，把远端 `tools` / `resources` / `prompts`
> 注册进 NeoAI 工具系统，让模型直接调用。对应源码：`lua/NeoAI/services/mcp/*`。

## 1. 支持范围

- **传输**：`stdio`（jobstart 子进程，按行分隔 JSON-RPC 帧）与 `streamable HTTP`（POST + SSE/JSON）。
- **能力**：`tools`（注册为工具）、`resources`（浏览/读取）、`prompts`（列出/获取）。
- **协议版本**：默认 `2025-06-18`，握手时协商。

## 2. 配置

```lua
require("NeoAI").setup({
  mcp = {
    enabled = true,
    timeout_ms = 60000,
    connect_timeout_ms = 20000,
    reconnect = true,
    cache_path = vim.fn.stdpath("cache") .. "/NeoAI/mcp_cache.json",
    servers = {
      filesystem = {                     -- 本地 stdio 服务器
        transport = "stdio",
        command = "npx",
        args = { "-y", "@modelcontextprotocol/server-filesystem", vim.fn.getcwd() },
        env = {},
        expose = { tools = true, resources = true, prompts = true },
        approval = { auto_allow = false },  -- 每个远端工具默认需审批
        plan_safe = false,                  -- 计划模式下不暴露（默认）
      },
      remote = {                         -- 远端 streamable HTTP 服务器
        transport = "http",
        url = "https://example.com/mcp",
        headers = { ["Authorization"] = "Bearer ..." },
      },
    },
    resources = { max_result_bytes = 100 * 1024 },
  },
})
```

`expose.resources/prompts` 缺省开启；`approval.auto_allow` 默认 `false`（远端工具不可信，需审批）。
`plan_safe=true` 可在计划模式下放行该服务器的工具（仅当确认只读）。

## 3. 工具注册与命名

远端 `tools/list` 的每个工具 → 一个 NeoAI 工具，命名 `mcp__<server>__<tool>`（如 `mcp__filesystem__read_file`），
`category = "mcp"`、`source = "mcp"`，`parameters` 直接使用远端 `inputSchema`（原生兼容）。

`resources` / `prompts` 每服务器各注册一组浏览工具：

| 工具名 | 说明 |
| --- | --- |
| `mcp__<server>__list_resources` | 列出资源（只读） |
| `mcp__<server>__read_resource`   | 按 `uri` 读取资源（只读） |
| `mcp__<server>__list_prompts`    | 列出提示模板（只读） |
| `mcp__<server>__get_prompt`      | 获取模板内容，供拼接上下文 |

> 执行器对 `source == "mcp"` 的工具**跳过参数别名改写与路径展开**（`file→filepath`、`~` 展开等），
> 否则会破坏远端 schema、被服务器判为未知参数。

## 4. 工具时序：预缓存 + 动态更新 + 失败驱动

针对「服务器连接慢 / 工具签名变化」两类问题：

### 4.1 预缓存（连接前即可用）

`NeoAI.setup()` 同步执行 `mcp.init()`：

1. **先读 `mcp_cache.json`**，把上次的 `tools/list` 等结果注册进工具系统 —— 服务器尚未连接，工具就已可见、可被 Agent 绑定。
2. 再异步连接真实服务器；连接成功后拉最新列表，**覆盖**缓存并更新已注册定义。

> 无缓存时该服务器标记 `pending`，待连接后补齐。

### 4.2 动态更新

触发来源：连接成功、`notifications/tools/list_changed`、手动刷新、上一轮失败触发。
流程：重拉 `tools/list` → `registry.update` 覆盖定义 → 写回缓存 → 发 `MCP_TOOLS_UPDATED` →
`chat_service` 重绑定当前 Agent 的 `agent.tools`（`tool_loop._tool_definitions` 每轮从 `agent.tools` 读取，下一轮即生效）。

### 4.3 失败驱动（stale）刷新

当一次 `tools/call` 因参数/schema 不匹配失败（`isError` 且文案含 `unknown/invalid/not found`，或 JSON-RPC 错误码 `-32602`/`-32601`）：

- 该服务器标记 `stale`，错误结果回传给模型，并提示「已刷新，请按最新 schema 重试」。
- `tool_loop` 每轮 `_send_round` **之前**调用 `set_pre_round_refresh` 注册的钩子（由 `chat_service` 注册，
  core 不反向依赖 services）：先异步刷新 stale 服务器并就地更新 `agent.tools` 中已有 MCP 工具签名，
  再进入下一轮模型请求 —— **Turn N 失败 → Turn N+1 自动以最新 schema 重试**。

## 5. 执行与安全

- 审批沿用 `tool_service`（串行单槽位），MCP 工具默认需审批。
- 计划模式下 MCP 工具默认驳回（不在只读/信息查询白名单）；`plan_safe=true` 的服务器放行。
- 超时用可暂停计时器（等待审批不计入）；请求取消会发 `notifications/cancelled`。
- stdio 服务器在插件关闭（`PLUGIN_SHUTDOWN`）时：关 stdin → SIGTERM → SIGKILL 兜底。

## 6. 生命周期

- 连接惰性：首次需要某服务器时才真正建立；无服务器的环境完全 no-op。
- 重连：HTTP 404-with-session 或连接级失败时重新初始化一次；工具调用错误返回给模型，不静默重试。
- 清理：`mcp.shutdown()`（插件关闭调用）关闭子进程/会话。

---

## 事件

见 `NeoAI.kernel.events`：`MCP_CONNECTING` / `MCP_READY` / `MCP_ERROR` / `MCP_DISCONNECTED` / `MCP_TOOLS_UPDATED`，
以及 `tools` 相关（`TOOL_EXECUTION_*`、审批等）。

## 相关文档

- [tool_system.md](tool_system.md)：工具系统（审批/执行/分组）。
- [chat_enhanced_usage.md](chat_enhanced_usage.md)：聊天与工具循环。
