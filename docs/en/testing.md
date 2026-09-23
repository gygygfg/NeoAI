# NeoAI Testing Guide (v3.0)

> [中文](../testing.md) | **English**

> NeoAI uses a **lightweight custom test framework** (`lua/NeoAI/tests/init.lua`, no external dependencies).
> Tests are organized with `suite` / `it`, assertions use `t.<assertion>`, and `:NeoAITest` runs them.
> Combined with mocks, it enables isolated unit and integration tests for HTTP, models, the file system, and more.

## 1. Running

```vim
:NeoAITest          " run all suites
:NeoAITest flow_tools  " run a specific suite (by name)
```

Running headless:

```bash
nvim --headless -u NONE --cmd 'set rtp+=.' \
  -c 'lua local r=require("NeoAI.tests").run_all(); vim.cmd(r.failed>0 and "cquit 1" or "qa!")'
```

## 2. Test Organization

```lua
local tests = require("NeoAI.tests")

tests.suite("flow_config", function(describe, it, before_each)
  before_each(function()
    require("NeoAI.kernel.config_store").reset()
  end)

  it("merge user overrides default", function(t)
    local cs = require("NeoAI.kernel.config_store")
    cs.load({ ai = { default_provider = "openai" } })
    t.eq(cs.get("ai.default_provider"), "openai")
  end)

  it("reads dotted path", function(t)
    local cs = require("NeoAI.kernel.config_store")
    cs.load({})
    t.eq(cs.get("ui.window.width"), 80)
  end)
end)
```

## 3. Assertion Helpers

The test callback receives `t` (the assertion helper table):

| Assertion | Description |
| --- | --- |
| `t.eq(a, b)` | Equal |
| `t.ne(a, b)` / `t.not_eq(a, b)` | Not equal |
| `t.true_(v)` / `t.false_(v)` | True / false |
| `t.nil_(v)` / `t.not_nil(v)` | nil / not nil |
| `t.matches(pattern, v)` | String match |
| `t.ok(v)` | Truthy |
| `t.deep_eq(a, b)` | Deep comparison |
| `t.sleep(ms)` | Async wait (returns a Deferred) |
| `t.await(promise, timeout_ms?)` | Wait and propagate rejection; defaults to a 10-second timeout |
| `t.throws(fn)` | Catch errors |

Async tests must return their final Deferred chain or use `t.await()` so the runner can wait and count asynchronous assertion failures.
Starting detached callbacks cannot reliably attribute their results. Module loading failures, unknown suites, and runner/cleanup errors all contribute to both `failed` and `errors`.

## 4. Mock Strategies

### 4.1 Session / File Isolation

The test runner redirects the default session path to a unique temporary directory (`vim.fn.tempname()`) for each run, then cleans up and restores the real in-memory sessions. The `kernel.*` and `core.session.*` modules provide a `reset()` method (config_store / event_bus / lifecycle / session_store / registry / tool_service, etc.) to make isolation easy.

### 4.2 HTTP / AI Mock

HTTP requests are mocked to simulate both streaming and non-streaming LLM responses:

- Override the request layer of `utils.http` when needed, or inject a mock server.
- `test_http.lua` uses the real loopback TCP server in `tests/http_server.lua` on random ports to cover fragmentation, cancellation/process exit, and error-body limits, without Python or external networking.
- `test_integration.lua` uses a mock server; `test_fs_io.lua` covers atomic writes and disk-full errors, while `test_session_store.lua` covers reparenting, log compaction, and recovery.

### 4.3 Tool Mock

You can call tool definitions directly, or override `registry` (for example, call `registry.reset()` and then use `register` to inject a mock tool).
`test_tools.lua` and `test_sub_agent_result.lua` cover tools and sub-agent results.

### 4.4 Event / State Isolation

Each module's `reset()` (`event_bus.clear_all`, `herder.reset`, `chat_service.reset`, `status.reset`, etc.)
ensures there are no leftover subscriptions or state between tests.

## 5. Test Coverage Topics

| File | Coverage |
| --- | --- |
| `test_kernel` | Kernel: config merging, event bus, lifecycle |
| `test_work_codec` | `vim.mpack` structured offload, binary round-trip and error propagation |
| `test_stream_batching` | Streaming chunk accumulation (small content immediately visible; large content and the 8KB boundary lossless after finalize) |
| `test_incremental` | Incremental rendering (line diff, block cache, block-descriptor reuse, in-place tool-result growth rebuild; incremental output matches full rebuild line-by-line) |
| `test_session` | Session object, JSONL storage, context building, compaction |
| `test_tool_result_pruner` | Tool result pruning (code point accounting, head/marker/tail, image skipping) |
| `test_agent / test_guard / test_overflow` | Agent state machine, guardrails, overflow recovery, pairing-safe splitting |
| `test_runtime_context` | Runtime context injection |
| `test_model_registry / test_model_capabilities / test_model_profiles / test_model_metadata` | Model registry, capability table, dialects, live metadata |
| `test_protocol_adapter` | Protocol encoding and decoding |
| `test_prompt_cache / test_cache_strategy / test_cache_usage` | Explicit cache, prefix cache strategy, cache hit usage |
| `test_model_picker` | Model picker |
| `test_modes` | Modes (CHAT/PLAN) |
| `test_multimodal` | Multimodal images |
| `test_tools / test_tool_pending` | Tool execution, pending/staged tools |
| `test_max_tokens / test_truncation` | max_tokens sending strategy, output truncation and continuation |
| `test_sub_agent_result` | Sub-agent results |
| `test_pending_queue` | Pending message queue |
| `test_services / test_status` | Service layer (chat/tool/model/status), status line |
| `test_ask_user / test_herder` | Asking questions, Herder reporting |
| `test_plan_mode / test_plan_distill / test_todo` | Plan mode, plan distillation, todos |
| `test_skills` | Skills (frontmatter/discovery/loading) |
| `test_mcp_client / test_mcp_transport / test_mcp_bridge` | MCP client, transport layer, bridge |
| `test_chat_ui / test_tree_ui / test_chat_keys` | Chat/tree UI, chat keymaps |
| `test_display_modes / test_fold / test_markdown` | Display modes, folding, Markdown |
| `test_timer / test_http / test_integration` | Pausable timer, HTTP client, integration (mock server) |
| `test_sha256` | Pure-Lua SHA-256 cross-checked against `vim.fn.sha256` (including worker `load(source)` equivalence) |
| `test_secret_async` | Async secret tokenization: worker result equals sync, detokenize round-trip, pass-through when disabled |
| `test_lsp_guard` | LSP isolation for NeoAI UI buffers: neoai* disables LSP/Copilot, acwrite preserved, idempotent install/uninstall |
| `test_plugins` | Plugin protocol: dependency waiting, replacement, disable, failure rollback, real message request, repeated start, tool/prompt-section release, hot reload |
| `test_sandbox` | Tool sandbox: loader spec attachment, fail-closed, state machine/idempotency/fencing, policy aggregation and restricted rules, dry-run no-write, CAS publish and conflict, buffer write redirection, runtime probe and isolated process, async review enqueue/apply/reject, selective apply, save/undo-save (original-file/snapshot swap with CAS conflict refusal), run_command overlay candidate capture, impact model, evidence redaction/paging, task grants auto-apply/scope, constraint aggregation, decision envelope, retention and metrics, controlled network gateway, broker idempotency/reconcile, dependency closure, composed publish and path conflict, policy replay, evidence retention, cgroup resource domain and PID limit, seccomp baseline enforcement and gate, content-addressed cache, fault injection (publish/backend/freeze), performance benchmarks, revision derivation, raw-secret (tool args / AI context) abort and token-operation escalation without abort, env-var name references / bare env-var secret values not registered and not aborting, staging backend on-disk by default / switchable to shm, disk-cap gate |
| `test_sandbox_instance` | Sandbox per-process instance isolation: instance store roots mutually invisible, hot reload keeps this instance's pending queue, `init` does not block on runtime probe (lazy), dead-instance directory reclamation |
| `test_sandbox_service` | Long-lived services/mirrors/diagnostics: service start/logs/status/stop and registry cleanup, capturing service changes back into staging on stop, graceful stop (SIGTERM graceful exit / SIGKILL on timeout / `stop_all`), `long_lived` gate branch, pip/npm/maven mirror injection (incl. settings.xml), cgroup event snapshot and OOM detection |
| `test_sandbox_background` | Background processes / session-resident instance: `&`/nohup/setsid detection (excluding `&&`/redirection/mid-command `&`), with `resident` enabled `run_command` background processes survive across tool calls (visible to `ps` in the same namespace), non-background commands return normally |
| `test_sandbox_systemd_user` | Fake `systemd --user` parser: `systemctl --user` is handled by the facade (start/stop/is-active), user units run in-sandbox with unit files/runtime state not landing on the host; `--user` parses to facade+scope=user |
| `test_sandbox_symlink` | Symlink candidates: `stage_link` → finish → merge → publish creates the real symlink; `systemctl --user enable` and the system-level facade `systemctl enable` symlinks are captured as candidates without landing on the host (returns real `Created symlink …` text) |
| `test_sandbox_systemd` | systemctl facade (option A): standalone-call parsing and routing, unit parsing and type gating, dependency closure (Requires/Wants/After, missing deps), silent `start` success, real-style `status`/`is-active`/`is-system-running`/`is-failed` output and exit codes, unsupported verbs return real errors (no sandbox leakage), gate interception without calling host systemctl |
| `test_sandbox_maintscript` | systemd facade entry: `process_prefix` binds the thin entry over the real binary paths (no more PATH-prepended `/tmp/.dynbin`), package installs inject policy-rc.d, and the entry forwards over file IPC to the Lua facade (stdout/stderr/exit code match real systemctl) |
| `test_net_consent` | Sandbox network consent: ask/allow/deny policy, internal-port registration is permission-free, headless fail-closed, prompt allow_once/deny/allow_session memory, external targets handled per policy |
| `test_sandbox_overlay_invalidate` | Overlay view sync: after publish/reject `resident.sync_real` makes commands read the new real content (no stale materialization; view-split fix); permission-bit changes trigger re-materialization |

### 5.1 Sandbox Escape / Info-leak Audit (`scripts/sandbox_audit.lua`)

Runs an attack battery inside the real sandbox (writing dangerous global sysctls, reading host
credentials/sockets, magic sysrq, `mount`/`unshare`/`nsenter`, `/proc/net` and `ip` info leaks,
raw TCP vs proxy interception, ...) and prints a structured report for human confirmation:

```bash
nvim --headless --clean -u NONE --cmd "set rtp+=$PWD" -c "luafile scripts/sandbox_audit.lua"
```

Reading it: every `write_*` must be `READONLY`; `socket AF_VSOCK`/`AF_PACKET`/`AF_ALG` must be
`EPERM`, `clone_NEWUSER` `EPERM`, `clone3` `ENOSYS`, `sysctl(2)` `ENOSYS`;
`raw_tcp_host=RAW_REACHED` and non-empty `proc_net_*`/`ip_*`/`host_info_leaks` are **known
residual boundaries** (inherent to the shared netns / global procfs, see
[sandbox.md](sandbox.md) §6.1). Regressions are guarded by the `test_sandbox` cases
"mandatory dangerous-sysctl masking", "cannot write core_pattern", "clone namespace filtering",
"socket address-family allowlist", "read_file /proc redaction" and
"masked-path symlink / `/proc/<pid>/root` resolution".

### 5.2 Plugin Testing Conventions

- Use unique plugin ids and service names; `unregister` / `revoke` at the end so running builtin plugins are not polluted.
- Tests that change configuration save and restore `config_store.get_all()`.
- Tests that stop/start builtin plugins restore `plugins.start_all()` before asserting, so a failure cannot affect later suites.
- Real message requests use the local `tests/http_server.lua` mock and stay offline reproducible.

## 6. Related Docs

- [threaded_testing.md](threaded_testing.md): Test framework structure and runner.
- [utils.md](utils.md): `utils.async` (Deferred/sleep, etc. used in tests).
- [plugins.md](plugins.md): plugin system and cleanup/replacement testing requirements.
