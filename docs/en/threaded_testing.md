# NeoAI Test Framework (v3.0)

> [中文](../threaded_testing.md) | **English**

> NeoAI ships with a **lightweight custom test framework** (no external dependencies, run via `:NeoAITest`).
> All test files live under `lua/NeoAI/tests/`. The `thread_worker.lua` /
> `thread_scheduler.lua` / `threaded_runner.lua` files and the `:NeoAITestAll` command mentioned in older
> docs **do not exist**. The corresponding source is `lua/NeoAI/tests/init.lua`.

## 1. How to Run

```vim
:NeoAITest              " Run all tests
:NeoAITest flow_tools   " Run a specific suite (by name)
:NeoAITest test_agent test_herder  " Run multiple suites
```

`run_all(...)` dynamically loads `lua/NeoAI/tests/test_*.lua` (idempotently), collects all `suite`
definitions, and executes them. Filtering by name is supported (`requested` matches the suite name).

## 2. Test Framework API (tests/init.lua)

### 2.1 Defining Suites

```lua
local tests = require("NeoAI.tests")

tests.suite("flow_tools", function(describe, it, before_each)
  before_each(function()
    -- Setup before each test case (optional)
  end)
  it("should ...", function(t)
    t.eq(1, 1)
  end)
end)
```

- `suite(name, fn)`: defines a test suite, `fn(describe, it, before_each)`.
- `it(name, fn)`: defines a test case, `fn(t)` receives the assertion helper table `t`.

### 2.2 Assertion Helpers

The test case callback parameter `t` passed to `it` contains all assertion helpers:

| Helper | Description |
| --- | --- |
| `t.eq(expected, actual, msg?)` | Equal |
| `t.ne(expected, actual, msg?)` / `t.not_eq(...)` | Not equal |
| `t.true_(value, msg?)` | Is true |
| `t.false_(value, msg?)` | Is false |
| `t.nil_(value, msg?)` / `t.not_nil(value, msg?)` | nil / not nil |
| `t.matches(pattern, value, msg?)` | String match |
| `t.ok(value, msg?)` | Truthy |
| `t.deep_eq(expected, actual, msg?)` | Deep comparison (`vim.inspect`) |
| `t.sleep(ms)` | Asynchronous wait (returns a Deferred) |
| `t.throws(fn)` | Catches errors (returns ok, err) |

### 2.3 Runner

`run_all(...)` does the following:

1. **Session isolation**: redirects the default session path to a temporary directory (`~/.cache/NeoAI-test`),
   cleans up afterward, and restores the real in-memory session, preventing tests from polluting real history.
2. Dynamically loads all `test_*.lua` files.
3. Runs each test case with `xpcall` (with `debug.traceback`), tallying `passed / failed / errors`.
4. Returns `{ passed, failed, errors }`.

## 3. List of Test Files

Under `lua/NeoAI/tests/`, tests are organized by module/feature:

`lua/NeoAI/tests/` contains **41** `test_*.lua` files in total (plus `init.lua` as the runner), organized by module/feature:

| File | Coverage |
| --- | --- |
| `test_kernel.lua` | Kernel (config_store / event_bus / events / lifecycle) |
| `test_session.lua` | Session (session / session_store / context_builder / compactor) |
| `test_agent.lua` | Agent (agent / runtime) |
| `test_guard.lua` | Tool loop guardrails |
| `test_overflow.lua` | Context overflow recovery |
| `test_runtime_context.lua` | Runtime context |
| `test_model_registry.lua` | Model registry |
| `test_model_capabilities.lua` | Model capabilities table |
| `test_model_profiles.lua` | Provider/model dialects |
| `test_model_metadata.lua` | Live model metadata |
| `test_protocol_adapter.lua` | Protocol encoding/decoding |
| `test_prompt_cache.lua` | Explicit caching |
| `test_cache_strategy.lua` | Prefix caching strategy |
| `test_cache_usage.lua` | Cache hit usage statistics |
| `test_model_picker.lua` | Model picker |
| `test_modes.lua` | Modes (CHAT/PLAN) |
| `test_multimodal.lua` | Multimodal images |
| `test_tools.lua` | Tool system |
| `test_tool_pending.lua` | Pending/staged tools |
| `test_pending_queue.lua` | Pending message queue |
| `test_services.lua` | Service layer (chat / tool / model / status) |
| `test_status.lua` | Status line service |
| `test_ask_user.lua` | Asking the user |
| `test_herder.lua` | Herder status reporting |
| `test_plan_mode.lua` | Plan mode |
| `test_plan_distill.lua` | Plan distillation |
| `test_todo.lua` | Todo list |
| `test_sub_agent_result.lua` | Sub-agent results |
| `test_skills.lua` | Skills (frontmatter/discovery/loading) |
| `test_mcp_client.lua` | MCP JSON-RPC client |
| `test_mcp_transport.lua` | MCP transport layer (stdio/HTTP) |
| `test_mcp_bridge.lua` | MCP manager bridge |
| `test_chat_ui.lua` | Chat UI |
| `test_tree_ui.lua` | Session tree UI |
| `test_chat_keys.lua` | Chat keymaps |
| `test_display_modes.lua` | Display mode plugin |
| `test_fold.lua` | Folding |
| `test_markdown.lua` | Markdown rendering |
| `test_timer.lua` | Pausable timer |
| `test_http.lua` | HTTP client |
| `test_integration.lua` | Integration tests (mock server) |

## 4. Running headless

Tests can run in headless mode (no GUI required):

```bash
nvim --headless "+lua require('NeoAI.tests').run_all()" +q
```

> See `lua/NeoAI/tests/nvim_test.py` and `lua/NeoAI/tests/nvim/*.yaml` (if present) for the concrete integration scripts.

## 5. Related Documentation

- [testing.md](testing.md): testing methodology and assertions.
- [threaded_testing notes]: this framework is a lightweight single-threaded runner and **has no** multithreaded testing components.
