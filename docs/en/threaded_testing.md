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
2. Dynamically loads `test_*.lua` (a child may load **only its shard's modules** via `NEOAI_TEST_MODULES`).
3. Runs each test case with `xpcall` (with `debug.traceback`), tallying `passed / failed / errors`.
   The first suite on a fresh worker skips the redundant `config_store.load` + `plugins.start_all` +
   `tools.reload_tools` full reset; by default only failures + suite summaries are printed
   (`NEOAI_TEST_VERBOSE=1` restores per-case detail).
4. Returns `{ passed, failed, errors, timings }`; an isolated child also writes a **sidecar** (small JSON).

### 2.4 Parallel runner structure (facade + submodules)

`parallel.lua` is a **thin facade** (keeping the `run / shard / _discover / _set_spawner / reset /
_abort_all` signatures); concurrency orchestration and result handling are split into
`lua/NeoAI/tests/runner/` submodules:

| Submodule | Responsibility |
| --- | --- |
| `runner/config.lua` | Constants, worker/heavy concurrency resolution, heavy classification |
| `runner/timings.lua` | Timing-cache read/write and `TIMING` parsing |
| `runner/shard.lua` | LPT sharding, discovery-manifest parsing (incl. name→module) |
| `runner/spawn.lua` | Child execution: log-to-disk + result sidecar, process-tree cleanup |
| `runner/scheduler.lua` | Bounded-concurrency pool (re-entrancy-safe trampoline) + dual-lane orchestration |
| `runner/report.lua` | Result aggregation, lazy log-tail for failed shards, reporting |

Dual lane: light (many suites/process, W lanes) and heavy (`sandbox*`/`pty`, one suite/process, H lanes)
run **overlapped**, constrained by `#light<=W`, `#heavy<=H`, `W+H<=cores`; `NEOAI_TEST_HEAVY_WORKERS=1`
falls back to the old serial channel.

## 3. List of Test Files

`lua/NeoAI/tests/` contains **126** `test_*.lua` files in total (plus `init.lua` as the runner, `parallel.lua` as the parallel runner, and `http_server.lua` / `sandbox_stub.lua` / `sandbox_boundary_helpers.lua` as test helpers), organized by category:

> **Authoritative source**: the list below is a quick index; the actual set is always `ls lua/NeoAI/tests/test_*.lua` (new suites need no doc change here).

| Category | Suites (`test_*.lua`, prefix `test_` and `.lua` omitted) |
| --- | --- |
| Kernel / plugins / services / runtime | `kernel`, `plugins`, `services`, `service_tool`, `lazy_plugin`, `lazy_startup`, `commands_plugin`, `keymaps_plugin`, `reload_all`, `lock`, `trace_retention` |
| Session / agent / context / modes | `session`, `session_store`, `session_progress`, `agent`, `runtime_context`, `guard`, `overflow`, `loop_compaction`, `compaction_overlay`, `truncation`, `max_tokens`, `pending_queue`, `sub_agent_result`, `abort_tools`, `modes` |
| Model / protocol / cache | `model_registry`, `model_capabilities`, `model_profiles`, `model_metadata`, `model_picker`, `protocol_adapter`, `prompt_cache`, `cache_strategy`, `cache_usage` |
| Tool system | `tools`, `tool_pending`, `tool_result_pruner`, `output_guard`, `approval_hub`, `plan_mode`, `plan_distill`, `todo`, `ask_user`, `read_image`, `web_fetch`, `multimodal` |
| Files / shell / LSP / text | `fs_io`, `guest_fs`, `git_ops`, `lsp_check`, `lsp_guard`, `pty`, `ansi`, `stringx`, `textmetrics`, `sha256`, `merge3` |
| UI | `chat_ui`, `tree_ui`, `chat_keys`, `display_modes`, `fold`, `markdown`, `ui_components`, `geometry`, `incremental`, `stream_batching`, `status` |
| MCP | `mcp_client`, `mcp_transport`, `mcp_bridge`, `mcp_cache` |
| Skills / Herder | `skills`, `herder`, `herder_install` |
| Sandbox (incl. grants / replay / observation / network consent) | `sandbox_ai_audit`, `sandbox_background`, `sandbox_boundary_consistency`, `sandbox_boundary_escape`, `sandbox_boundary_net`, `sandbox_conflict_ai`, `sandbox_core`, `sandbox_governance`, `sandbox_hardening`, `sandbox_instance`, `sandbox_loss_audit`, `sandbox_lost_update`, `sandbox_lsp`, `sandbox_maintscript`, `sandbox_merge`, `sandbox_mountview`, `sandbox_namespace`, `sandbox_ops`, `sandbox_overlay_invalidate`, `sandbox_package_signature`, `sandbox_privdrop`, `sandbox_privilege`, `sandbox_publish_async`, `sandbox_review`, `sandbox_script_scan`, `sandbox_secret`, `sandbox_service`, `sandbox_session`, `sandbox_shims`, `sandbox_staging`, `sandbox_symlink`, `sandbox_systemd`, `sandbox_systemd_user`, `sandbox_view`, `grant`, `replay`, `observer`, `review_cache`, `net_consent`, `gateway` |
| Secret guard | `secret_async`, `secret_fake`, `secret_highlight`, `secret_provenance` |
| Test framework / infrastructure | `test_runner`, `parallel_runner`, `integration`, `http`, `async`, `timer`, `work_codec` |

## 4. Running headless

Tests can run in headless mode (no GUI required):

```bash
nvim --headless "+lua require('NeoAI.tests').run_all()" +q
```

> See `lua/NeoAI/tests/nvim_test.py` and `lua/NeoAI/tests/nvim/*.yaml` (if present) for the concrete integration scripts.

## 5. Related Documentation

- [testing.md](testing.md): testing methodology and assertions.
- [threaded_testing notes]: this framework is a lightweight single-threaded runner and **has no** multithreaded testing components.
