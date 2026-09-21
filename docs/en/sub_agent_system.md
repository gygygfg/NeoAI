# NeoAI Sub-Agent System (v3.0)

> [中文](../sub_agent_system.md) | **English**

> Sub-agents let the AI use `create_sub_agent` to offload complex tasks to an isolated sandbox. Every sub-agent runs in a
> **brand-new environment with zero inheritance**, with its own AbortSignal and tool subset, operating within boundary
> constraints (allowed_tools / allowed_directories / max_tool_calls, etc.).
> Corresponding source: `lua/NeoAI/core/agent/runtime.lua`, `lua/NeoAI/tools/builtin/plan.lua`,
> `lua/NeoAI/ui/components/sub_agent_dock.lua`.

## 1. Module Structure

| Module | Responsibility |
| --- | --- |
| `core/agent/runtime.lua` | Agent runtime. `spawn(parent, override)` spawns a sub-agent (brand-new environment). |
| `tools/builtin/plan.lua` | Sub-agent tools: `create_sub_agent` / `wait_sub_agent` / `get_sub_agent_status` / `cancel_sub_agent`; boundary review, call counting, foreground waiting. |
| `services/tool_service.lua` | Boundary review for sub-agent tool calls (`plan.review_tool_call`). |
| `ui/components/sub_agent_dock.lua` | Sub-agent status monitoring (dock). |

## 2. Sub-Agent Lifecycle

### 2.1 Creation (create_sub_agent)

```lua
plan_tools.create_sub_agent = helpers.define_tool(
  "create_sub_agent",
  "Create a sub-agent to run an independent subtask. task is required; mode is optional, either 'background' (default, returns immediately) or 'foreground' (waits for the sub-agent to finish, then returns the full result); boundaries is an optional set of constraints.",
  ...)
```

Flow:

1. Generate a `sub_id` (`sub_<time>_<rand>`) and record it in `state.sub_agents[sub_id]`.
2. Call `runtime.spawn(parent_agent, { task, model, scenario="agent" })` to create a brand-new sub-agent.
3. **Boundary constraints**: `boundaries.allowed_tools` determines the tool subset (`_allowed_tools`); when unspecified, it defaults to read-only tools.
4. Emit `SUB_AGENT_CREATED`.
5. `runtime.run(sub_agent, task)` starts execution; on completion/failure it emits
   `SUB_AGENT_COMPLETED` / `SUB_AGENT_ERROR` + `SUB_AGENT_RESULT_READY` respectively.
6. `mode == "foreground"`: call `M.wait(sub_id)` to wait for and return the full result; otherwise return "created" immediately.

### 2.2 Execution

A sub-agent goes through `runtime.run(sub_agent, task)` and follows the same generation flow as the main agent (including the `tool_loop`).
Each sub-agent has its own AbortSignal (`child.signal = async.create_signal()`) and does not inherit the parent's signal.

### 2.3 Tool Subset (_allowed_tools)

```lua
function M._allowed_tools(allowed_tools)
  if allowed_tools and #allowed_tools > 0 then
    -- Use the allowlist (definitions are fetched from the registry)
  else
    -- Default read-only tools: read_file / list_files / search_files / file_exists /
    -- log_message / get_log_levels / git_status / git_diff / git_log /
    -- lsp_diagnostics / parse_file / get_node_code
  end
end
```

### 2.4 Boundary Review (review_tool_call)

Every tool call from a sub-agent passes through `services/tool_service._review_sub_agent` → `plan.review_tool_call`:

- If `boundaries.allowed_tools` exists and does not contain that tool → reject with `"[dispatcher agent rejection] the call to tool 'x' was denied"`.
- If `boundaries.max_tool_calls` has been reached → reject with `"maximum number of tool calls reached"`.
- Otherwise it passes and `plan.track_tool_call(sub_id)` increments the counter.

### 2.5 Foreground Waiting (wait)

`M.wait(sub_id)` returns a Deferred: if the sub-agent is already in a terminal state (completed/error/cancelled), it resolves immediately;
otherwise it subscribes to the `SUB_AGENT_COMPLETED` / `SUB_AGENT_ERROR` / `SUB_AGENT_UPDATED(cancelled)` events and waits.
The `wait_sub_agent` tool is a wrapper around exactly that semantics (foreground waiting for the full result).

### 2.6 Cancellation (cancel_sub_agent)

`runtime.abort(sub, "user_cancelled")` cancels the sub-agent, sets its status to `cancelled`, and emits `SUB_AGENT_UPDATED`.

## 3. Tool List

| Tool | Description | Parameters |
| --- | --- | --- |
| `create_sub_agent` | Creates a sub-agent | `task` (required) subtask description; `mode` (optional, `background` default / `foreground`); `model` (optional); `boundaries` (optional) `{allowed_tools, allowed_directories, allowed_commands, max_tool_calls, max_iterations}`; `context` (optional) extra context |
| `wait_sub_agent` | Waits for the sub-agent to finish and returns the full result; if it has already finished, returns immediately | `sub_agent_id` (required) |
| `get_sub_agent_status` | Queries sub-agent status and result | `sub_agent_id` (required) |
| `cancel_sub_agent` | Cancels the sub-agent | `sub_agent_id` (required) |

> With the default asynchronous approval (`tools.approval.mode = "async"`) there is no pre-execution blocking approval; whether
> a sub-agent tool call enters the review queue is decided by the sandbox risk level.
> `tools.approval.per_tool.create_sub_agent.auto_allow = false` only takes effect in non-async modes (`prompt`/`strict`);
> when there is no `timeout`, it falls back to `tools.executor.timeout_ms` (`create_sub_agent` sets `timeout = -1`, meaning unlimited).

## 4. Sub-Agent State and Events

`state.sub_agents[sub_id]` records `{ id, agent_id, task, boundaries, status, started_at, tool_calls, context }`,
where `status` is one of: `running` / `completed` / `error` / `cancelled`.

Sub-agent events (see [EVENTS.md](EVENTS.md) for details):

| Event | Trigger |
| --- | --- |
| `SUB_AGENT_CREATED` | Sub-agent created |
| `SUB_AGENT_UPDATED` | Sub-agent status updated (e.g., cancelled) |
| `SUB_AGENT_COMPLETED` | Sub-agent completed |
| `SUB_AGENT_ERROR` | Sub-agent errored |
| `SUB_AGENT_RESULT_READY` | Result ready (for delivery back to the main agent) |

## 5. UI Monitoring (sub_agent_dock)

Sub-agent status is monitored through `sub_agent_dock` (`ui/init.lua` calls `sub_agent_dock.init()`), showing each
sub-agent's in-progress/completed/errored status in the UI.

## 6. Example

```lua
-- Have the AI initiate this in a conversation: background sub-agent
create_sub_agent({
  task = "Analyze the architecture tree of README.md",
  mode = "background",
  boundaries = { allowed_tools = { "read_file", "list_files", "search_files" } },
})

-- Wait for the result in the foreground (blocks until the sub-agent finishes)
wait_sub_agent({ sub_agent_id = "sub_abc" })

-- Query status
get_sub_agent_status({ sub_agent_id = "sub_abc" })

-- Cancel
cancel_sub_agent({ sub_agent_id = "sub_abc" })
```

## 7. Related Documentation

- [ai_engine.md](ai_engine.md): `runtime.spawn` / `runtime.run` generation flow.
- [tool_system.md](tool_system.md): tool boundary review, `boundaries` constraints.
- [EVENTS.md](EVENTS.md): sub-agent events.
