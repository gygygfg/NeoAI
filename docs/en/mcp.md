# NeoAI MCP Support

> [中文](../mcp.md) | **English**

> NeoAI acts as an MCP **client**, connecting to external MCP servers and registering remote `tools` / `resources` / `prompts`
> into the NeoAI tool system so the model can call them directly. Corresponding source: `lua/NeoAI/services/mcp/*`.

## 1. Scope

- **Transport**: `stdio` (jobstart subprocess, line-delimited JSON-RPC frames) and `streamable HTTP` (POST + SSE/JSON).
- **Capabilities**: `tools` (registered as tools), `resources` (browse/read), `prompts` (list/get).
- **Protocol version**: defaults to `2025-06-18`, negotiated during the handshake.

## 2. Configuration

```lua
require("NeoAI").setup({
  mcp = {
    enabled = true,
    timeout_ms = 60000,
    connect_timeout_ms = 20000,
    reconnect = true,
    cache_path = vim.fn.stdpath("cache") .. "/NeoAI/mcp_cache.json",
    servers = {
      filesystem = {                     -- local stdio server
        transport = "stdio",
        command = "npx",
        args = { "-y", "@modelcontextprotocol/server-filesystem", vim.fn.getcwd() },
        env = {},
        expose = { tools = true, resources = true, prompts = true },
        approval = { auto_allow = false },  -- every remote tool is non-auto-allowable by default (effective in non-async modes)
        plan_safe = false,                  -- not exposed in plan mode (default)
      },
      remote = {                         -- remote streamable HTTP server
        transport = "http",
        url = "https://example.com/mcp",
        headers = { ["Authorization"] = "Bearer ..." },
      },
    },
    resources = { max_result_bytes = 100 * 1024 },
  },
})
```

`expose.resources/prompts` are enabled by default; `approval.auto_allow` defaults to `false` (remote tools are untrusted, so they may never be auto-allowed).
With the default `tools.approval.mode = "async"` there is no pre-execution blocking approval; the sandbox risk level decides the action:
MCP tool calls follow `sandbox.approval.default` (default `review`) and enter the **review queue**, applied after confirmation via `:NeoAISandboxReview`.
Setting `plan_safe=true` allows that server's tools in plan mode (only when read-only behavior is confirmed).

## 3. Tool Registration and Naming

Each tool in the remote `tools/list` → one NeoAI tool, named `mcp__<server>__<tool>` (e.g. `mcp__filesystem__read_file`),
with `category = "mcp"`, `source = "mcp"`, and `parameters` taken directly from the remote `inputSchema` (native compatibility).

`resources` / `prompts` each register one set of browsing tools per server:

| Tool name | Description |
| --- | --- |
| `mcp__<server>__list_resources` | List resources (read-only) |
| `mcp__<server>__read_resource`   | Read a resource by `uri` (read-only) |
| `mcp__<server>__list_prompts`    | List prompt templates (read-only) |
| `mcp__<server>__get_prompt`      | Get template content for context assembly |

> For tools with `source == "mcp"`, the executor **skips parameter alias rewriting and path expansion**
> (`file→filepath`, `~` expansion, etc.), otherwise it would break the remote schema and be rejected by the server as unknown parameters.

## 4. Tool Timing: Pre-caching + Dynamic Updates + Failure-driven

Addressing the two problems of "slow server connection / changing tool signatures":

### 4.1 Pre-caching (usable before connecting)

`NeoAI.setup()` runs `mcp.init()` synchronously:

1. **Read `mcp_cache.json` first**, registering the previous `tools/list` and other results into the tool system —— before the server is connected, the tools are already visible and can be bound by the Agent.
2. Then connect to the real server asynchronously; once connected, fetch the latest list, **overwriting** the cache and updating the already-registered definitions.

> If there is no cache, the server is marked `pending` and filled in after connecting.

### 4.2 Dynamic Updates

Triggers: successful connection, `notifications/tools/list_changed`, manual refresh, previous-round failure.
Flow: re-fetch `tools/list` → `registry.update` overwrites the definitions → write back to cache → emit `MCP_TOOLS_UPDATED` →
`chat_service` rebinds the current Agent's `agent.tools` (`tool_loop._tool_definitions` reads from `agent.tools` every round, taking effect on the next round).

### 4.3 Failure-driven (stale) Refresh

When a `tools/call` fails due to a parameter/schema mismatch (`isError` and the message contains `unknown/invalid/not found`, or a JSON-RPC error code of `-32602`/`-32601`):

- That server is marked `stale`; the error result is returned to the model along with a hint to "already refreshed, please retry with the latest schema".
- Before each round's `_send_round`, `tool_loop` calls the hook registered via `set_pre_round_refresh` (registered by `chat_service`;
  core does not depend on services in reverse): it first asynchronously refreshes the stale server and updates the existing MCP tool signatures in `agent.tools` in place,
  then proceeds to the next round of model requests —— **Turn N fails → Turn N+1 automatically retries with the latest schema**.

## 5. Execution and Safety

- Execution always goes through the sandbox (`sandbox.gate`); MCP tool calls enter the **review queue** by default per risk level
  (`sandbox.approval.default = "review"`) and are applied after async confirmation via `:NeoAISandboxReview` (only in non-async modes does
  the pre-execution approval dialog in `tool_service` apply).
- In plan mode, MCP tools are rejected by default (not in the read-only/information-query allowlist); servers with `plan_safe=true` are allowed.
- Timeouts use a pausable timer (time waiting for approval is not counted); a request cancellation sends `notifications/cancelled`.
- On plugin shutdown (`PLUGIN_SHUTDOWN`), stdio servers: close stdin → SIGTERM → SIGKILL as a fallback.

## 6. Lifecycle

- Lazy connection: a server is only actually established when first needed; environments with no servers are completely no-op.
- Reconnect: re-initialize once on HTTP 404-with-session or connection-level failure; tool call errors are returned to the model with no silent retry.
- Cleanup: `mcp.shutdown()` (called on plugin shutdown) closes subprocesses/sessions.

---

## Events

See `NeoAI.kernel.events`: `MCP_CONNECTING` / `MCP_READY` / `MCP_ERROR` / `MCP_DISCONNECTED` / `MCP_TOOLS_UPDATED`,
plus `tools`-related events (`TOOL_EXECUTION_*`, approval, etc.).

## Related Docs

- [tool_system.md](tool_system.md): Tool system (approval/execution/grouping).
- [chat_enhanced_usage.md](chat_enhanced_usage.md): Chat and tool loop.
