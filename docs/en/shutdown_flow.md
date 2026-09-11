# NeoAI Lifecycle and Shutdown (v3.0)

> [中文](../shutdown_flow.md) | **English**

> Lifecycle management is handled by `kernel/lifecycle.lua`: `bootstrap` / `on_shutdown` / `shutdown`.
> Cancellation is propagated as a cascade through **AbortSignal** (replacing the old `shutdown_flag`).
> Corresponding sources: `lua/NeoAI/kernel/lifecycle.lua`, `lua/NeoAI/kernel/init.lua`,
> `lua/NeoAI/init.lua` (setup).

## 1. Kernel Bootstrap (kernel/init.lua)

`kernel.bootstrap()` is the kernel-layer entry point, and it performs the following in order:

1. Initialize logging (`logger.init(config_store.get("log"))`).
2. Register the `VimLeavePre` autocmd (`NeoAILifecycle` group): calls `M.shutdown()` on exit.
3. `schedule` a background refresh of the model list after a 100 ms delay (`model_service.prefetch`, non-blocking at startup).

## 2. Lifecycle (kernel/lifecycle.lua)

### 2.1 bootstrap

`M.bootstrap()` is idempotent. It initializes logging, registers the `VimLeavePre` cleanup autocmd, and refreshes models in the background.
Although the `PLUGIN_INITIALIZED` event constant is defined in `kernel/events.lua`, **the current code never actually emits it** (it is a reserved constant), so bootstrap does not trigger it.

### 2.2 on_shutdown

`M.on_shutdown(fn)` registers a cleanup function (run on VimLeave) and returns a cancel function. Multiple cleanup functions run in registration order,
but at shutdown they run in **reverse** order (the one registered last is cleaned up first).

### 2.3 shutdown

`M.shutdown()` is idempotent:

1. Set `shutting_down = true` (to prevent re-entry).
2. Run all cleanup functions in reverse order (wrapped in `pcall`, so an exception does not interrupt).
3. Emit the `PLUGIN_SHUTDOWN` event.
4. Log `"NeoAI shutdown complete"`.

## 3. setup Flow (NeoAI.init)

`NeoAI.setup(user_config)` is the plugin entry point, and it is extremely thin:

```
config_store.load(user_config)      -- pure function: merge + validate
kernel.bootstrap()                  -- kernel bootstrap (logging, VimLeavePre, background model refresh)
herder.init()                       -- Herder terminal status signal (lazy environment detection, no-op)
tools.init()                        -- initialize the tool system (registers built-in tools synchronously)
skills.init()                       -- scan the skills directory and populate the index
mcp.init()                          -- pre-cache registration + asynchronously connect to MCP servers
lifecycle.on_shutdown(mcp.shutdown) -- close MCP child processes/sessions on shutdown
_register_commands()                -- register user commands (lazy-loads business modules)
_register_global_keymaps()          -- register global keymaps
status.ensure_lualine_extension()   -- inject the lualine extension (if already loaded)
```

Command registration always lazy-loads the corresponding business module (`require(...)` runs only when the command is invoked).

## 4. AbortSignal Cascade Cancellation

The cancellation mechanism is based on the AbortSignal from `async.create_signal()`:

- Each Agent holds its own `signal`.
- `runtime.abort(agent, reason)` → `agent.signal:abort(reason)` + status set to `aborted` + emits `AGENT_ABORTED`.
- Cancellation cascades to HTTP requests (`utils.http` listens to the signal) and tool calls (`tools.executor` checks `signal:aborted()`).
- **Cancellation is a normal stop, not an error**: the error callback of `runtime._run_generation` distinguishes `aborted/cancelled`,
  resets the status to `idle`, rejects with `{kind="cancelled"}`, and does not show a "send failed" prompt.

## 5. Shutdown Paths

### 5.1 Vim Exit (VimLeavePre)

`lifecycle.shutdown()` runs the cleanup functions in reverse order, saving unpersisted sessions and shutting down async tasks. It then calls `event_bus.emit(PLUGIN_SHUTDOWN)`.

### 5.2 Window Close

`chat_view.close()` → `chat_service.detach_window(win_id)`:

- Persist Agent messages to the session (`_persist_agent`).
- `runtime.dispose(agent)` (release resources, `agent:signal:abort("disposed")`).
- `todo_mod.cleanup(agent)` (clean up todo state and the system prompt section).
- Reject staged messages that are still waiting when the window closes (`_flush_pending`), avoiding a permanent hang.
- `tool_service.clear_approval()`: reject all tools awaiting approval in the queue and release the serial approval slot (otherwise a leftover `approval_showing`
  of true would make subsequent approvals hang).

### 5.3 Cancel Generation

`chat_service.cancel_generation()` → `runtime.abort(agent, "user_cancelled")` + `tool_service.clear_approval()`.

## 6. Related Documents

- [ai_engine.md](ai_engine.md): Agent state machine and `runtime.run`.
- [EVENTS.md](EVENTS.md): `PLUGIN_INITIALIZED` / `PLUGIN_SHUTDOWN` / `AGENT_*`.
- [configuration.md](configuration.md): `log` / `herder` configuration.
