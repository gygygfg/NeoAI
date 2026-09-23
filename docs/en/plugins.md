# NeoAI Plugin System (v1.0)

> [中文](../plugins.md) | **English**

NeoAI uses a **service locator + plugin host** architecture: business code never `require`s a
concrete service directly. Instead it obtains the implementation that is active under the current
configuration via `kernel.services.use()`. Every side effect (commands, keymaps, tools, event
subscriptions, MCP connections, statusline listeners, UI injection) is registered as a
startable/unloadable **plugin**.

- Host: `lua/NeoAI/kernel/plugins.lua`
- Service locator: `lua/NeoAI/kernel/services.lua`
- Default composition: `lua/NeoAI/plugins/catalog.lua`

## 1. Service Locator (kernel/services.lua)

| API | Description |
| --- | --- |
| `provide(name, impl)` | Register an implementation (same name overrides; used for replacement/hot reload) |
| `use(name)` | Return the current implementation; `nil` if absent/disabled (**never falls back to the default module**) |
| `has(name)` | Whether a service is provided |
| `revoke(name, expected?)` | Unregister (optionally only if the implementation matches) |
| `wait(name, cb)` | Invoke `cb` once the service is ready; returns a cancel function (dependency waiting) |
| `list()` / `reset()` | List service names / clear (tests) |

Usage:

```lua
local services = require("NeoAI.kernel.services")
local chat = services.use("services.chat_service")
if chat then
  chat.send_message("hi")
end
```

When a service is disabled `use()` returns `nil`; callers must degrade explicitly
(`if not chat then ... end`) and must not `require("NeoAI.services.chat_service")` as a fallback.

## 2. Plugin Host (kernel/plugins.lua)

### 2.1 Spec

```lua
{
  id = "services.model_service",          -- globally unique id
  deps = { "services.session" },          -- plugin ids started first
  service = "services.model_service",     -- optional: service name provided
  module = "NeoAI.services.model_service",-- optional: implementation module (config-replaceable)
  start = function(ctx) ... end,          -- optional: side-effect start, returns cleanup
  stop = function(ctx) ... end,           -- optional: extra teardown
}
```

- `ctx` exposes `{ id, plugins, services, on_cleanup }`; `ctx.on_cleanup(fn)` registers multiple cleanups.
- `start` may also return a single cleanup function or an array of them.

### 2.2 API

| API | Description |
| --- | --- |
| `register(spec)` / `register_many(specs)` | Register without starting |
| `start(id)` | Start the plugin and its deps; on failure roll back plugins newly started by this call |
| `stop(id)` | Run cleanups in reverse and revoke the service (idempotent) |
| `start_all()` | Start all in registration order; any failure rolls back the whole batch |
| `stop_all()` | Stop all in reverse order |
| `status(id)` / `is_started(id)` / `spec(id)` / `list()` | Query |
| `unregister(id)` / `reset()` | Unregister / clear (tests) |

### 2.3 Lifecycle and rollback

```
register → start (deps → provide service → run start) → started
                              ↘ failure: roll back newly started plugins, mark failed
stop: cleanups in reverse → revoke service → stopped
```

- Dependencies first; circular dependencies are detected and reported.
- Rollback: `start(id)` rolls back only plugins newly started by that call; `start_all()` rolls back the batch.
- Idempotent: repeated `start`/`stop` do not repeat side effects.

## 3. Default Composition (plugins/catalog.lua)

### 3.1 Service providers

| Plugin id | Provides | Lifecycle |
| --- | --- | --- |
| `services.session` | `NeoAI.core.session.session_store` | — |
| `services.agent` | `NeoAI.core.agent.agent` | — |
| `services.tools` | `NeoAI.tools` | apply approval config |
| `services.sandbox` | `NeoAI.sandbox` | probe runtime capabilities, prepare staging/candidate storage |
| `services.model_service` | `NeoAI.services.model_service` | — |
| `services.chat_service` | `NeoAI.services.chat_service` | — |
| `services.tool_service` | `NeoAI.services.tool_service` | — |
| `services.skills` | `NeoAI.services.skills` | — |
| `services.mcp` | `NeoAI.services.mcp` | — |
| `services.status` | `NeoAI.services.status` | — |
| `services.herder` | `NeoAI.services.herder` | — |

### 3.2 Side-effect plugins

| Plugin id | Effect | Cleanup |
| --- | --- | --- |
| `ui` | Register approval/ask-user/sub-agent UI | close windows + remove UI injection |
| `commands` | Register all `:NeoAI*` commands | delete commands |
| `keymaps` | Register global keymaps | delete keymaps |
| `model_prefetch` | Background model-list refresh | cancel scheduling |
| `mcp.connect` | Connect MCP servers | `mcp.shutdown()` |
| `skills.scan` | Scan skill directories | `skills.reset()` |
| `statusline` | Statusline subscriptions + lualine injection | `status.unwatch()` |
| `herder` | Herder state reporting | `herder.reset()` |
| `sandbox.session` | Agent lifecycle subscription: shared sandbox per loop, rotate + migrate staging at agentEnd | `sandbox.unwatch_sessions()` |

### 3.3 Tool plugins

Each builtin tool is its own plugin `tool.<name>` (e.g. `tool.shell`, `tool.file_ops`, `tool.skills`).
`start` registers the tool definitions (the skills tool also registers a prompt section); cleanup
removes the tools and releases the section. They depend on `services.tools` and `services.sandbox`.

The loader is the sandbox enforcement point: `catalog._tool_spec` passes `services.sandbox` into
`tools.load_module`, which calls `sandbox.attach` for every tool; `registry.register/update`
attach specs uniformly (covering dynamically registered MCP tools). At execution time
`tools.executor` routes every call through `services.sandbox.gate`, rejecting when the service is
missing and `fail_closed=true`. See [sandbox.md](sandbox.md).

## 4. Configuration (plugins)

```lua
require("NeoAI").setup({
  plugins = {
    builtin = true,                 -- false = do not register builtin plugins
    disabled = { "ui", "services.mcp" }, -- disabled plugin/service ids
    entries = {
      ["tool.shell"] = false,        -- disable a plugin
      ["services.model_service"] = { module = "my_model_provider" }, -- replace implementation
    },
  },
})
```

- Disabled plugins and their downstream dependents (dependency closure) are removed together.
- `entries[id] = false` disables; `entries[id] = { module = "..." }` replaces the service/tool
  implementation module (must be `require`-able with the same interface).
- `plugins.builtin = false` registers no builtin plugins, for hosts that compose their own set.

## 5. Cleanup Lifecycle

Every side effect must be unloadable and is invoked by the host on `stop`:

- Commands: `nvim_del_user_command`
- Global keymaps: `vim.keymap.del`
- Event subscriptions: cancel functions returned by `event_bus.on`
- Prompt sections: cancel functions returned by `prefix.register_section`
- MCP: `mcp.shutdown()`; tools: `registry.remove`
- Statusline: `status.unwatch()`; UI: `ui.reset()` removes `tool_service` / `ask_user` injection
- Herder: `herder.reset()`

`lifecycle.shutdown()` runs the cleanup function registered in `setup()` (which calls
`plugins.stop_all()`); `NeoAIReloadAll` / `reload_all` also call `plugins.stop_all()` before
clearing the module cache and reloading.

## 6. Hot Reload

The controlled reload in `reload_all`:

1. Snapshot the `NeoAI.*` module cache (for rollback);
2. Read the current config, session id;
3. `plugins.stop_all()` → `event_bus.clear_all()` → clear `NeoAI.*` cache → `setup()` again;
4. Rebuild the UI and restore the session; on failure restore the cache snapshot.

## 7. Testing Requirements

Plugin-specific tests live in `lua/NeoAI/tests/test_plugins.lua` and cover:

- dependency waiting, circular deps, repeated-start idempotency;
- service replacement, disable and dependency closure;
- start failure rollback (single plugin / whole batch);
- tool plugin unload and prompt-section release;
- a real message request (local `tests/http_server.lua` mock, offline reproducible);
- hot-reload recovery via `stop_all` then `start_all`.

New plugins must add corresponding tests and keep the full regression at `failed=0`.

## 8. Related Documents

- [styleGuide.en.md](../../styleGuide.en.md) — directory layout, module template, async/event conventions
- [configuration.md](configuration.md) — configuration reference
- [testing.md](testing.md) — testing guide
- [EVENTS.md](EVENTS.md) — event constants
