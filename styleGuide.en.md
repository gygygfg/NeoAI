# NeoAI Architecture Design Guide

> [中文](styleGuide.md) | **English**

> Version: 3.0 | Design philosophy: **isolation, simplicity, async-first, cache-friendly**

---

## 1. Design Philosophy

### Core Principles

1. **Isolation First**
   - Opening a chat window always creates a brand-new session context, with zero residue
   - Every sub-agent runs in its own sandbox and inherits no runtime state from its parent Agent
   - Modules communicate through **immutable data**; shared mutable global state is forbidden

2. **Unidirectional Dependency**
   - The dependency hierarchy is strictly one-way: `utils → kernel → core → services → ui/tools`
   - No circular dependencies and no cross-layer pass-through calls
   - Modules expose only **interfaces** and hide implementation details

3. **Async by Default**
   - All I/O operations (network, files, model list fetching) are asynchronous
   - Startup never blocks Neovim; all external resources are lazily loaded and fetched in the background
   - Model lists are fetched asynchronously from the official API; local config serves only as cache and fallback

4. **Replaceability**
   - Every module defines a clear interface contract, and its implementation can be replaced independently
   - No binding to a specific LLM vendor; a unified adapter layer provides the abstraction

5. **Cache-Friendly Prefix**
   - The system prompt is assembled from ordered segments (identity / persona / tool guidance) and rendered byte-stable
   - Tool definitions are emitted in lexicographic order by name, so the same tool set is byte-identical across requests
   - Context compaction uses "byte-for-byte replay + checkpoint replacement" to reuse the cache of unchanged prefixes

---

## 2. Directory Structure

```
NeoAI/
├── init.lua                      # Main entry point: extremely thin, only setup + routing
├── NeoAI.lua                     # Plugin root (require entry point) *
├── default_config.lua            # Default config (pure data, zero logic)
├── styleGuide.md                 # This file
│
├── kernel/                       # Kernel layer (lowest level, zero business dependencies)
│   ├── init.lua                  # Kernel init + submodule reference orchestration
│   ├── events.lua                # Event constant registry (domain:verb)
│   ├── event_bus.lua             # Event bus (built on Neovim User autocmd)
│   ├── lifecycle.lua             # Lifecycle management (startup/shutdown/cleanup functions)
│   ├── config_store.lua          # Config store (merge + validate + watch)
│   └── logger.lua                # Logging
│
├── core/                         # Core business layer
│   ├── init.lua                  # Core module orchestration
│   ├── session/                  # Session management
│   │   ├── session.lua           # Session object (pure data structure + methods)
│   │   ├── session_store.lua     # Session persistence (CRUD + JSONL + .bak)
│   │   ├── context_builder.lua   # Context building (system section + API message conversion)
│   │   └── compactor.lua         # Context compaction (token pressure + overflow recovery)
│   │
│   ├── model/                    # Model management layer
│   │   ├── registry.lua          # Model registry (updated dynamically at runtime)
│   │   ├── fetcher.lua           # Async model list fetcher (concurrency + retries)
│   │   ├── adapter.lua           # Multi-provider protocol adapters (openai/anthropic/google)
│   │   └── cache.lua             # Local model list cache
│   │
│   └── agent/                    # Agent engine
│       ├── agent.lua             # Agent object (new instance per conversation)
│       ├── runtime.lua           # Agent runtime (lifecycle + state machine)
│       ├── request.lua           # Request building + sending + retries
│       ├── stream.lua            # Streaming response handling (incremental tool_calls accumulation)
│       ├── tool_loop.lua         # Tool call loop (parallel execution + guardrails)
│       ├── prefix.lua            # Prefix management and cache identity fingerprint
│       ├── guard.lua             # Tool loop guardrail (repeated-call reminders)
│       └── recovery.lua          # Context overflow recovery (resend after compaction)
│
├── services/                     # Service layer (bridges core and ui/tools)
│   ├── chat_service.lua          # Chat service (frontend/backend bridge + session sync)
│   ├── tool_service.lua          # Tool service (approval + scheduling + execution)
│   └── model_service.lua         # Model service (for UI model selection/switching)
│
├── ui/                           # Presentation layer
│   ├── init.lua                  # UI orchestration (approval UI + sub-agent monitoring)
│   ├── window/                   # Window management
│   │   ├── manager.lua           # Window manager (float/tab/split)
│   │   ├── chat_view.lua         # Chat view
│   │   └── tree_view.lua         # Session tree view
│   ├── components/               # Reusable components
│   │   ├── input_box.lua         # Input box
│   │   ├── message_list.lua      # Message list rendering
│   │   ├── reasoning_panel.lua   # Reasoning panel
│   │   ├── model_picker.lua      # Model picker (async list loading)
│   │   ├── tool_approval.lua     # Tool approval dialog
│   │   ├── sub_agent_dock.lua    # Sub-agent monitoring panel
│   │   ├── markdown_view.lua     # Markdown renderer
│   │   └── fold.lua              # Fold/collapse component
│   └── keymap.lua                # Keymaps (single config entry point)
│
├── tools/                        # Tool system
│   ├── init.lua                  # Tool system entry point (loads built-in tools)
│   ├── registry.lua              # Tool registry (register/query/alias/approval config)
│   ├── executor.lua              # Tool executor
│   ├── validator.lua             # Argument validation
│   ├── packer.lua                # Tool grouping and packing
│   └── builtin/                  # Built-in tools (each file standalone, no cross-references)
│       ├── file_ops.lua          # File read/write/list/search/delete
│       ├── shell.lua             # run_command command execution
│       ├── git_ops.lua           # Git status/diff/log/rollback/commit
│       ├── lsp_ops.lua           # LSP hover/jump/diagnostics/rename/format
│       ├── tree_ops.lua          # treesitter parse/query/delete nodes
│       ├── log_ops.lua           # Log read/write tools
│       ├── plan.lua              # Sub-agent create/monitor/cancel (with boundary review)
│       ├── plan_mode.lua         # Plan mode (read-only tool context + formatted plan + confirm to switch to CHAT)
│       ├── ask_user.lua          # Ask-user tool (UI seam)
│       ├── todo.lua              # Todo list (whole-table replacement semantics)
│       └── tool_helpers.lua      # define_tool helper functions
│
├── utils/                        # Pure utility library (no business dependencies)
│   ├── init.lua
│   ├── async.lua                 # Async primitives (Promise/Future/Deferred/Signal)
│   ├── json.lua
│   ├── http.lua                  # HTTP client (streaming/non-streaming + cancellation signal)
│   ├── fs.lua                    # Filesystem operations (JSONL + .bak + repair)
│   └── stringx.lua               # String extensions (uuid/truncate, etc.)
│
├── tests/                        # Tests (custom lightweight framework, no external dependencies)
│   ├── init.lua                  # Test runner + assertion API
│   ├── test_kernel.lua
│   ├── test_session.lua
│   ├── test_model_registry.lua
│   ├── test_agent.lua
│   ├── test_tools.lua
│   ├── test_services.lua
│   ├── test_integration.lua
│   ├── test_http.lua
│   ├── test_cache_strategy.lua
│   ├── test_overflow.lua
│   ├── test_guard.lua
│   ├── test_todo.lua
│   ├── test_plan_mode.lua
│   ├── test_sub_agent_result.lua
│   ├── test_fold.lua
│   ├── test_tree_ui.lua
│   ├── test_chat_ui.lua
│   └── test_chat_keys.lua
│
├── doc/                          # Design docs
├── docs/                         # Developer docs
├── autoload/                     # Vim autoload entry
└── after/plugin/                 # Plugin load script
```

> `*` Note: `NeoAI.lua` lives in the repository root (it is one of the entries under `runtimepath` that Neovim resolves as `require("NeoAI")`, complementing `init.lua`).

---
## 3. Startup Flow

```
setup(user_config)
  │
  ▼
config_store.load(user_config)         ← Pure function: merge + validate, returns an immutable config
  │
  ▼
kernel.bootstrap()                    ← Initialize event constants, logging, lifecycle (registers VimLeavePre)
  │
  ▼
tools.init()                          ← Synchronously register built-in tools (definitions only, no I/O)
  │
  ▼
Register commands + global keymaps (that's all)
  │
  ▼
Return (model list refreshed in the background after a 100ms delay, triggered by lifecycle)
```

**Key change**: `setup()` does not initialize any business modules (core/services/ui). All heavy work is lazily loaded on first use; the model list refresh is scheduled with a delay after startup by `kernel.lifecycle` and does not block Neovim.

---

## 4. Key Architecture Decisions

### Decision 1: Each Conversation = a Fresh Agent Instance

**Problem with the old architecture**: Coroutine contexts, closure state, shared tables, active_generations... nested layer upon layer, with a very high risk of state leakage and fragile cancel/retry logic.

**New architecture**:

```
Open chat window
  │
  ▼
agent_runtime.create(config)           ← Create a fresh Agent instance
  │
  ├── Assign a unique agent_id
  ├── Create an independent message queue (empty)
  ├── Bind an independent tool scope
  ├── Bind an independent abort signal (AbortSignal)
  └── Register with runtime state
  │
  ▼
agent lifecycle = window lifecycle
  │
  ├── Window closed → agent.dispose() → release all resources
  ├── User cancels → agent.abort() → abort signal propagates to HTTP + tools
  └── Normal completion → agent.idle() → wait for the next input
```

**Agent instance structure**:

```lua
-- Each Agent is an independent closure environment
-- There is no global is_generating, active_generations, or other shared state
{
  id = "agent_xxx",
  session_id = "session_xxx",
  parent = nil | parent_agent_id,   -- sub-agent points to its parent Agent
  config = {...},             -- config snapshot in effect for this Agent (after scenario resolution)
  messages = {...},           -- this Agent's private message list
  tools = {...},              -- the subset of tools visible to this Agent (name -> def)
  model = "deepseek-v4-pro",  -- this Agent's model
  signal = abort_signal,      -- abort signal (replaces the global stop_requested flag)
  state = "idle|generating|tool_running|aborted|error",
  iterations = 0,             -- tool loop iteration count
  usage = { prompt, completion, cache_read, cache_write, ... },
  cache = {
    last_prefix_id = nil,     -- prefix cache identity fingerprint of the previous request
    identity_changes = 0,     -- number of cache identity changes
    compaction_usage = nil,   -- cache usage of the most recent compaction summary call
  },
  plan_mode = false,          -- plan mode state (per-agent)
  plan = nil,                 -- plan content
  guard = nil,                -- tool loop guard counter chain (attached to the agent)
}
```

**Sub-agent creation**:

```
Main Agent decides to create a sub-agent (create_sub_agent tool)
  │
  ▼
agent_runtime.spawn(parent_agent, override)
  │
  ├── Create a fresh Agent instance (empty message queue, independent signal)
  ├── Only pass from parent: task + restricted tool set (read-only tools by default)
  ├── Sub-agent inherits none of the parent's message history
  ├── When the sub-agent finishes, only the final result is returned to the parent
  └── Sub-agent dispose → all resources fully released
```

- Sub-agent boundary validation: `tool_service`, together with `plan.lua`, checks whether a tool is within `allowed_tools` and whether the `max_tool_calls` limit has been reached.
- Execution mode: `background` (default, returns immediately) or `foreground` (waits for completion).

### Decision 2: Asynchronous Model List Fetching

**Problem with the old architecture**: Model names were hard-coded in the config file, so adding or removing models required manually updating the config.

**New architecture**:

```
After startup (vim.schedule delayed)
  │
  ▼
model_fetcher.prefetch()               ← Asynchronously fetch the model lists of all configured providers in the background
  │
  ├── Concurrently request each provider's /models endpoint
  │   ├── GET https://api.deepseek.com/models
  │   ├── GET https://api.openai.com/v1/models
  │   └── ...
  │
  ├── Success → cache.write + registry.update → emit the MODELS_UPDATED event
  ├── Failure → use the local cache in cache.lua
  └── No cache → use the adapter's static fallback list
  │
  ▼
UI layer listens for the MODELS_UPDATED event → automatically refreshes the model selector
  │
  ▼
User switches model → model_service.set_active(model_id) → update the current Agent's config
```

**Model registry interface**:

```lua
model_registry.list(provider?)        -- get available models (returns a Promise asynchronously, merging the fallback chain)
model_registry.get(model_id, provider?) -- get details for a single model
model_registry.subscribe(callback)   -- subscribe to model list changes
model_registry.prefetch(provider?)   -- manually trigger a refresh (delegated to the fetcher)
model_registry.resolve_default(provider) -- resolve "auto" to the first available model
model_registry.update(provider, models) -- the fetcher writes the new list and notifies
```

**Config changes**: The `models` field is no longer required from users; it is now an optional override:

```lua
providers = {
  deepseek = {
    api_type = "openai",
    base_url = "https://api.deepseek.com",
    api_key = os.getenv("DEEPSEEK_API_KEY"),
    fetch_models = true,              -- whether to fetch automatically
    -- models_override: manual override/ordering only; if set, no network request is made
    models_override = { "deepseek-reasoner" },
  },
}
```

**Multi-provider adaptation**: `core/model/adapter.lua` unifies three protocols (openai/anthropic/google), with each provider selecting its adapter via `api_type`. Adding a new vendor only requires `adapter.register(api_type, adapter)`.

### Decision 3: Separating Event Constants from the Event Bus

The event system is split into two layers:

- **`kernel/events.lua`** — Event constant registry. It only declares constants in the `domain:verb` form (such as `agent:spawn`, `stream:chunk`); all modules emit and listen by referencing constants, and hard-coded event strings are forbidden.
- **`kernel/event_bus.lua`** — Event bus implementation. Built on Neovim's native `User` autocmd, it uniformly prefixes names with `NeoAI:` to avoid conflicts, and the same event shares one augroup.

```lua
-- emit
event_bus.emit(events.AGENT_SPAWNED, { parent = parent.id, agent = child })

-- subscribe (returns an unsubscribe function)
local unsub = event_bus.on(events.MODELS_UPDATED, function(payload) ... end)
local once   = event_bus.once(events.PLUGIN_SHUTDOWN, function() ... end)

-- event name normalization: enforces "domain:verb" and automatically adds the "NeoAI:" prefix
```

Event constant (domain) groups: Agent lifecycle / generation and streaming / reasoning / messages / sessions / branch tree / tools / todos and plan mode / models / UI windows / sub-agent / config and lifecycle / logging / context compaction.

### Decision 4: Flattening Dependencies

**Old architecture dependency graph** (simplified):

```
ui ──→ chat_service ──→ engine ──→ request_handler ──→ http_client
  │         │               │            │
  │         │               └──→ tool_cycle ──→ approval_handler ──→ approval_state
  │         │                              │
  │         └──→ history_manager ──→ cache/persistence/saver/message_builder
  │                                    │
  └──→ keymap_manager ←── config_merger ←── default_config
                                          │
                                     shutdown_flag
                                     state_manager (coroutine context)
```

**New architecture dependency graph**:

```
┌───────────────────────────────────────────────────────────────────────┐
│  ui/                                                                  │
│  window/ + components/ + keymap.lua                                   │
│  Depends only on services/ interfaces; never touches core/ directly   │
└──────────────────┬────────────────────────────────────────────────────┘
                   │ call service interfaces
                   ▼
┌───────────────────────────────────────────────────────────────────────┐
│  services/                                                            │
│  chat_service │ tool_service │ model_service                          │
│  Orchestrates core/ modules, exposing a simple API upward             │
└──────────────────┬────────────────────────────────────────────────────┘
                   │
                   ▼
┌───────────────────────────────────────────────────────────────────────┐
│  core/                                                                │
│  session/ (data) │ model/ (model) │ agent/ (engine)                   │
│  Each submodule depends only on kernel/ + utils/                      │
└──────────────────┬────────────────────────────────────────────────────┘
                   │
                   ▼
┌───────────────────────────────────────────────────────────────────────┐
│  kernel/ (event constants + event bus + lifecycle + config + logging) │
│  utils/ (pure-function utility library)                               │
└───────────────────────────────────────────────────────────────────────┘
```

> Note: `tools/` belongs to the tool system layer; its `builtin/*` files are mutually independent and never reference one another, and they may be called from core (tool_loop) and services (tool_service). A tool definition that writes back Agent state must do so through the `ctx.agent` context, keeping boundaries clean.

**Dependency rules**:
- `ui/` → may only call the public methods of `services/`
- `services/` → may only call the public methods of `core/` + `kernel/` events + `tools/` execution
- `core/` → may only call `kernel/` + `utils/` (agent submodules may reference one another)
- `tools/` → may only call `kernel/` + `utils/` (builtins are independent and never reference one another)
- `kernel/` → may only call `utils/`
- `utils/` → depends on no project modules
- No reverse dependencies, no cross-layer penetration, no same-level circular references

### Decision 5: Abort Signals Instead of Global Flags

**Old architecture**: `shutdown_flag.is_set()` scattered across 20+ callbacks, the `_cancel_processed` idempotency flag, the shared `stop_requested` variable...

**New architecture**: the AbortSignal pattern (borrowed from the Web API).

```lua
-- utils/async.lua
local signal = async.create_signal()

-- bind the signal when the Agent is created
agent.signal = signal

-- on cancel: a single call, cascading propagation
signal.abort("user_cancelled")
  ├── Cancel in-flight HTTP requests (the http client passes the signal through)
  ├── Cancel pending tool calls
  ├── Reject unfinished Promises
  └── Emit the "agent:aborted" event

-- check at the start of any async operation
if signal:aborted() then return end
```

Sub-agents have their own independent signal (`child.signal = async.create_signal()` in `runtime.spawn`) and do not inherit the parent's signal.

### Decision 6: Context Compaction + Overflow Recovery (Cache-Friendly)

This solves the problem of very long sessions hitting the model's context window, aligned with deepseek-harness's compaction strategy:

**Trigger points** (two paths):
1. **Pressure pre-check**: before each step, `runtime.run` calls `compactor.maybe_compact`, collapsing old history first once `threshold_ratio` is reached.
2. **Overflow recovery**: when a request returns `context window exceeded` (400/413/429), `recovery.send_stream` calls `compactor.force_compact` and resends (triggered at most once per request round).

**Compaction strategy**:
- First perform **model-agnostic tool result trimming**: overly long `read_file`/`run_command` output is trimmed to a "head + omission marker + tail" form, which in most cases brings it back under the threshold without needing a summary.
- Collapse the earliest whole messages and retain the most recent tail (budgeted by `retain_ratio`/`retain_min_tokens`); the cut point preserves **tool pairing balance** so that an `assistant.tool_calls` is never separated from its `tool` result.
- The auxiliary summary call "replays byte-for-byte" the system prompt + tool schema + messages in the collapsed region, with the compaction instruction appended as the final user message → reusing the warm prefix cache.
- **Replace** the collapsed span with a checkpoint user message tagged `<compacted-summary>` (replace only; it does not produce a second copy of the history).
- If it is still above the threshold after summarization, retry according to `compaction_retries`; overflow recovery falls back to maximized balanced head reduction.

**Prefix identity consistency** (`core/agent/prefix.lua`):
- The system prompt is assembled from ordered segments (identity `-100` / persona `0` / tool guidance `100+`), byte-for-byte stable across requests.
- Tool definitions are emitted in lexicographic order by name, byte-for-byte identical across requests for the same tool set.
- The cache identity fingerprint (FNV-1a) is compared across requests; an identity change means the prefix cache is invalidated, and this is used for diagnostics and statistics.
- Cache hit/miss tokens are parsed from provider usage (`prompt_cache_hit_tokens` / `cached_tokens`).

---
## 5. Core Module Responsibilities

### `init.lua` — Main entry point

- `setup(config)` — load config → kernel bootstrap → tool system initialization → register commands/keymaps
- Does not initialize the core/services/ui business modules
- Triggers the lazy-load chain when a window is first opened
- Registers user commands: `NeoAIOpen` / `NeoAIChat` / `NeoAITree` / `NeoAIClose` / `NeoAIKeymaps` / `NeoAITest` / `NeoAIChatStatus` / `NeoAIPlan`

### `kernel/events.lua` — Event constant registry

- Only declares `domain:verb` event constants for uniform reference; hardcoded strings are forbidden.

### `kernel/event_bus.lua` — Event bus

- Publish/subscribe built on Neovim `User` autocmds (`emit` / `on` / `once` / `clear_all`).
- Event names automatically get the `NeoAI:` prefix; the same event shares an augroup; callback exceptions are caught and logged.

### `kernel/lifecycle.lua` — Lifecycle

- `bootstrap()` — initialize logging, register `VimLeavePre` cleanup, and schedule a deferred model refresh.
- `on_shutdown(fn)` — register cleanup functions (executed in reverse order); `shutdown()` runs them all and emits `PLUGIN_SHUTDOWN`.

### `kernel/config_store.lua` — Config store

- `load(user_config)` — deep merge + validation + returns an immutable config table.
- `get(path)` — read by dot-separated path (e.g. `"ui.window.width"`).
- `set(path, value)` — hot update at runtime (triggers watch + `CONFIG_CHANGED`).
- `watch(path, cb)` — watch for config changes.
- No longer split across the three files merger/validator/state.

### `core/session/session.lua` — Session object

- A pure data structure with no side effects and no I/O.
- Fields: `id / parent_id / root_id / created_at / updated_at / model / messages / metadata`.
- `create()` / `serialize()` / `deserialize()` / `add_message()` / `fork()` / `trim_messages()`.
- The complex path algorithm `get_context_and_new_parent` is gone — replaced by an explicit `fork()` operation.

### `core/session/session_store.lua` — Session persistence

- Append-only JSONL storage + torn-line repair + `.bak` backup (`_rewrite_all` writes `.bak` first, then the real file, rolling back on failure).
- CRUD: `create` / `get` / `update` / `delete` (cascades to descendants) / `persist` / `save_all`.
- Tree queries: `get_children` / `get_roots` / `get_descendants` (BFS).

### `core/session/context_builder.lua` — Context building

- Builds the API message array from a session/Agent (system section + message conversion + history truncation).
- `_to_api_message`: for assistant messages that carry tool_calls and empty content, the content field is omitted (strictly compatible with OpenAI/DeepSeek).
- `estimate_tokens`: rough token estimate as characters/4 (used to judge compaction pressure).
- `build_prefix`: builds the compaction replay prefix (byte-identical, reusing the prefix cache).

### `core/session/compactor.lua` — Context compaction

- `maybe_compact(agent)` — once the token pressure threshold is reached, prune tool results first and fold history if needed (runs only when idle).
- `force_compact(agent)` — skips the threshold check, used for overflow recovery (maximally balanced head reduction).
- `_select_shadow_range` — folds the earliest whole segment while keeping the recent tail; the cut point keeps tool pairing balanced.
- `checkpoint_message(summary)` — generates the `<compacted-summary>` checkpoint message.

### `core/session/tool_result_pruner.lua` — Tool result pruning

- `prune_agent(agent, opts)` — before summarization, trims over-budget tool results into "head + omission marker + tail".
- `prune_content(content, cfg)` / `measure_content(content)` — trimming and code-point measurement for a single content item.
- Tool results that contain image references are skipped, so trimming cannot break the embedded JSON or block image injection.

### `core/model/registry.lua` — Model registry

- Updated dynamically at runtime; subscribe/notify mechanism; supports manual overrides + auto-discovery.
- Fallback chain: dynamic API results → static `models_override`/`models` → adapter default list.

### `core/model/fetcher.lua` — Model list fetcher

- Fetches model lists from all providers concurrently and asynchronously.
- Exponential backoff retries (3 attempts: 1s/2s/4s).
- On success → `cache.write` + `registry.update`; on failure → cache → current registry value → static fallback.

### `core/model/adapter.lua` — Multi-provider protocol adaptation

- Unified request construction, streaming/non-streaming response parsing, and models list parsing for the openai / anthropic / google protocols.
- `get(api_type)` / `register(api_type, adapter)` / `get_fallback_models(provider)` / `can_fetch(provider)`.

### `core/agent/agent.lua` — Agent object

- A new instance is created for every conversation; it holds a private message queue, tool set, and cancel signal.
- State machine: `idle → generating → tool_running → idle` (or `aborted` / `error`).
- Message operations, cancellation, and usage accumulation (compatible with both openai usage shapes + cache usage).

### `core/agent/runtime.lua` — Agent runtime

- `create(config)` — creates an Agent (including scenario config parsing).
- `spawn(parent, override)` — creates a sub-agent (fresh environment, independent signal).
- `dispose(agent)` / `abort(agent)` — destroy/cancel.
- `run(agent, content)` — user message → compaction precheck → guard reset → generation (including the tool loop).

### `core/agent/request.lua` — Request construction and sending

- `send` (non-streaming) / `send_stream` (streaming, forces `stream=true`).
- Exponential backoff retries; `_should_retry` (no retry on 4xx); `is_context_overflow` overflow detection.

### `core/agent/stream.lua` — Streaming response handling

- Accumulates chunked tool_calls (OpenAI format) into complete tool_calls; syncs streaming deltas into Agent messages; reasoning/content switch events.

### `core/agent/tool_loop.lua` — Tool call loop

- Executes tool calls in parallel; results are written back in the original call order (API compatibility + deterministic prefix caching).
- Round limit of 1000; guard reminders are injected; a closing note for empty responses.

### `core/agent/prefix.lua` — Prefix and cache identity

- `build_system_prompt` — renders the system prompt from ordered sections.
- `register_section` / `register_agent_section` — register global/agent-level prompt sections.
- `prefix_id` — FNV-1a cache identity fingerprint; `verify_cache_identity` — identity consistency check; `parse_cache_usage` — cache usage parsing.

### `core/agent/guard.lua` — Tool loop guard

- Detects consecutive duplicate calls (same tool + same arguments) and injects a reminder at the threshold (observe-and-enrich, never vetoes).
- `reset` (reset on new user input) / `check_round` (checked every round).

### `core/agent/recovery.lua` — Overflow recovery

- `send_stream` — when a request returns an overflow error → `compactor.force_compact` and resend; triggered at most once per request round.

### `services/chat_service.lua` — Chat service

- `send_message(content)` — sends a message (creating or reusing the current Agent).
- `attach_window` / `detach_window` — bind/unbind a window (persist + clear approvals on close).
- `new_session` / `load_session` — create/load a session (restores plan mode and the todo list).
- `toggle_plan_mode` / `toggle_auto_mode` / `cycle_mode` / `approve_plan` / `get_mode` / `cancel_generation` / `switch_model` / `get_todos`.

### `services/tool_service.lua` — Tool service

- `execute(agent, name, args, ...)` — sub-agent boundary check + plan mode gate + execution.
- `approve_and_execute(...)` — approval + execution (serial single-slot approval queue + timeout fallback).
- `clear_approval` / `set_allow_all` / `set_approval_ui` / `has_pending_approval`.

### `services/model_service.lua` — Model service

- `list()` — asynchronously returns all available models (grouped by provider).
- `set_active(model_id, provider)` / `get_active()` — switch/get the current model.
- `prefetch(provider)` / `subscribe(cb)` / `start_background_refresh()`.

### `ui/keymap.lua` — Unified keymap management

- Replaces the old `keymap_manager` plus the `set_keymaps` scattered across the various windows.
- Defines all keymaps in one place; grouped by context (global/tree/chat); supports dynamic registration/unregistration at runtime.

---
## 6. Key Flows

### 1. Opening the Chat Window

```
User presses the shortcut key / runs the command
  │
  ▼
ui.open_chat()
  │
  ├── ui.init() (register approval UI + sub-agent monitoring)
  ├── chat_view.open()
  ├── agent_runtime.create(config)        ← brand-new Agent instance (lazy)
  ├── chat_service.attach_window(win_id, agent)
  ├── model_service.prefetch()            ← refresh the model list in the background
  └── render the empty chat UI (the tree window stays open so sessions can be browsed at the same time)
```

### 2. Sending a Message

```
User presses Enter in the input box
  │
  ▼
input_box.submit(content)
  │
  ▼
chat_service.send_message(content)
  │
  ├── _get_or_create_agent (reuse the current Agent or create a new Session + Agent)
  ├── runtime.run(agent, content)
  │     │
  │     ├── compactor.maybe_compact (pressure pre-check)
  │     ├── guard.reset (reset the guard counter chain)
  │     ├── agent.add_message("user", content)
  │     └── _run_generation
  │           ├── recovery.send_stream (overflow recovery wrapper)
  │           ├── request.send_stream()   ← async send (with cancellation signal)
  │           ├── stream.process()        ← streaming processing
  │           └── tool_loop.run()         ← if there are tool calls
  │
  └── event-driven UI updates
        agent:on("message:chunk", update_ui)
        agent:on("generation:complete", finalize_ui)
```

### 3. Creating a Sub-Agent

```
The main Agent calls the create_sub_agent tool
  │
  ▼
runtime.spawn(parent_agent, {
  task = "search for and analyze the relevant code",
  model = "deepseek-v4-flash",         -- a different model can be specified
  boundaries = { allowed_tools = {...}, max_tool_calls = n },
})
  │
  ├── create a brand-new Agent (empty message queue, independent signal)
  ├── inherit none of the parent's messages/state
  ├── receive only task_description as the initial input
  │
  ├── the sub-agent executes the task (fully independent, read-only tool set by default)
  │
  └── when finished → return the result to parent → dispose itself
```

### 4. Loading the Model List

```
After startup (lifecycle vim.schedule)
  │
  ▼
model_fetcher.prefetch()
  │
  ├── read all providers in config_store
  ├── concurrently request each provider's /models endpoint
  │
  ├── success → cache.write + registry.update() → event notifies the UI
  ├── partial failure → update the successful ones, use the cache for the failed ones
  └── total failure → the adapter's static fallback list
  │
  ▼
when model_picker opens
  │
  ├── prefer showing the live list from registry
  ├── annotate each model's status (available/unknown/deprecated)
  └── after the user makes a selection → model_service.set_active()
```

### 5. Canceling Generation

```
User presses Esc
  │
  ▼
chat_service.cancel_generation() → agent.abort()
  │
  ├── signal.abort("user_cancelled")
  ├── cancel the in-flight HTTP request
  ├── reject incomplete tool calls
  ├── clean up pending approvals (release the serial approval slot)
  ├── fire the "agent:aborted" event
  └── UI receives the event → updates state
  │
  ▼
agent.state = "aborted" (returns to idle before the next round of input)
```

### 6. Context Compaction

```
(Path A: pre-step check)
runtime.run → compactor.maybe_compact(agent)
  ├── est >= context_window * threshold_ratio?
  └── yes → _compact (replay + summary + checkpoint replacement)

(Path B: overflow recovery)
request returns a 400/413/429 overflow error
  ▼
recovery.send_stream catches is_context_overflow
  ▼
compactor.force_compact → attempt() resends after compaction
```

### 7. Closing the Window

```
User closes the window
  │
  ▼
chat_service.detach_window(win_id)
  │
  ├── _persist_agent (sync messages + state to session)
  ├── agent.dispose()                    ← release all Agent resources
  │     ├── plan_mode.cleanup (unregister the prompt segment)
  │     ├── cancel in-progress tasks
  │     ├── clear the message queue
  │     └── remove from the runtime registry
  ├── todo.cleanup(session_id)
  ├── tool_service.clear_approval()      ← release the serial approval slot
  └── session_store.persist()            ← persist session data
```

---

## 7. Session Data Structures

### Storage Format

Uses **append-only JSONL** (one JSON object per line), replacing the old JSON array:

```
sessions.jsonl
─────────────────────────────────────────
{"id":"s1","parent_id":null,"root_id":"s1",...}
{"id":"s2","parent_id":"s1","root_id":"s1",...}
{"id":"s3","parent_id":"s1","root_id":"s1",...}
```

**Benefits**:
- Appending requires no parsing of the entire file
- Natively handles large files (not loaded into memory all at once)
- Crash recovery is simple (the last line may be incomplete; `fs.repair_jsonl` simply truncates it)
- Rewrites write a `.bak` first and then the real file, rolling back automatically on failure

### Session Object

```json
{
  "id": "sess_xxx",
  "parent_id": null,
  "root_id": "sess_xxx",
  "created_at": 1234567890,
  "updated_at": 1234567890,
  "model": "deepseek-v4-pro",
  "messages": [
    {"role": "user", "content": "...", "ts": 1234, "id": "msg_xxx"},
    {"role": "assistant", "content": "...", "reasoning": "...", "ts": 1235}
  ],
  "metadata": {
    "name": "auto-naming",
    "tags": [],
    "usage": {"prompt": 24, "completion": 770},
    "todos": [...],
    "plan": {"active": false, "plan": null}
  }
}
```

> `metadata.todos` and `metadata.plan` are used to restore the todo list and plan mode state across sessions.

### Branch Strategy

There is no longer a complex `get_context_and_new_parent` path algorithm.

```
User creates a new branch under session A
  │
  ▼
session.fork(parent_id, { copy_messages = true })
  │
  ├── create a new session B with parent_id = A, root_id = A.root_id
  ├── optional: copy A's message history as context
  ├── B has its own independent message queue
  └── return a reference to B
```

---

## 8. Configuration Reference

(For the complete defaults see `default_config.lua`; the highlights are summarized below)

```lua
require("NeoAI").setup({
  ai = {
    default_provider = "deepseek",
    default_model = "auto",          -- "auto" = the first available model in registry
    providers = {
      deepseek = { api_type = "openai", base_url = "...", api_key = "...", fetch_models = true },
      openai   = { api_type = "openai", ... },
      anthropic= { api_type = "anthropic", ... },
      google   = { api_type = "google", ... },
      groq / together / openrouter / siliconflow / moonshot / zhipu / baidu / aliyun / stepfun,
      -- 13 built-in providers in total, all of which can be overridden manually with models_override
    },
    model_refresh = { on_startup = true, interval_sec = 3600, timeout_ms = 10000 },
    modes = {          -- configure provider/model/temperature/max_tokens/stream separately per mode (CHAT/PLAN/AUTO)
      chat = { provider = "deepseek", model = "auto", temperature = 0.7, max_tokens = 4096, stream = true },
      plan = { provider = "deepseek", model = "auto", temperature = 0.3, max_tokens = 8192, stream = true },
      auto = { provider = "deepseek", model = "auto", temperature = 0.7, max_tokens = 8192, stream = true },
    },
    reasoning_enabled = true,
    system_prompt = "You are an AI programming assistant...",
    timeout_ms = 60000,
    max_retries = 3,
    context_cache = {            -- prefix cache identity consistency + context compaction
      enabled = true,
      context_window = 64000,
      threshold_ratio = 0.8,
      retain_ratio = 0.16,
      retain_min_tokens = 4096,
      compact_max_tokens = 8192,
      min_shadow_messages = 2,
      include_identity = true,
      identity = "You are an AI programming assistant powered by NeoAI.",
    },
  },

  ui = {
    default_view = "chat",
    window_mode = "tab",
    window = { width = 80, height = 24, border = "rounded" },
    split = { size = 80, direction = "right" },
    colors = { background, border, user_message, ai_message, reasoning, title },
    tree = { foldenable, auto_close_on_select, ... },
  },

  keymaps = {
    global = { toggle_ui, open_chat, open_tree, close_all },
    tree = { quit, select, new_child, new_root, delete_dialog, delete_branch, expand, collapse },
    chat = { insert, quit, send, cancel, toggle_reasoning, switch_model, cycle_mode, tool_approval, approval },
  },

  session = {
    auto_save = true,
    auto_naming = true,
    save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    max_history_per_session = 1000,
    file = "sessions.jsonl",
  },

  tools = {
    enabled = true,
    builtin = true,
    external = {},
    guard = { repeat_tool = { enabled, thresholds = {3,5,8}, messages } },
    todo = { enabled = true },
    plan_mode = { enabled = true, auto_execute_on_approve = true, extra_safe_tools = {}, mutating_tools = {...} },
    approval = {
      mode = "prompt",             -- prompt | auto_allow | strict
      default_auto_allow = false,
      timeout_ms = 60000,
      allowed_directories = {},
      allowed_param_groups = {},
      per_tool = { read_file = { auto_allow = true }, edit_file = { auto_allow = false }, ... },
    },
  },

  log = {
    level = "WARN",
    path = vim.fn.stdpath("cache") .. "/NeoAI/neoai.log",
    max_size = 10485760,
    max_backups = 5,
    format = "[{time}] [{level}] {message}",
    verbose = false,
  },
})
```

---

## 9. Error Handling

| Error type     | Handling strategy                                       |
| ------------ | ---------------------------------------------- |
| Network error     | Exponential backoff retry (1s/2s/4s); error out after 3 attempts          |
| Context overflow   | Automatically compact history and resend (at most once per request round)         |
| Model unavailable   | Automatically fall back to the next available model from the same provider    |
| Tool execution error | The error result is returned to the Agent, which decides whether to retry or give up      |
| Stuck tool loop | Max 1000 rounds, approval timeout fallback, wrap-up explanation for empty responses   |
| Repeated tool call | guard injects a reminder (observe-and-enrich, no veto)  |
| Configuration error     | Report all errors at once on startup, fall back to defaults         |
| Cancellation     | AbortSignal cascades, all waiting operations exit immediately |
| Serialization failure   | Write a `.bak` file so no existing data is lost                |

---

## 10. Code Style

### Module Template

```lua
--- One-line module description
--- @module NeoAI.module_name

local M = {}
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local async = require("NeoAI.utils.async")

-- ========== Private state ==========

local state = { initialized = false }

-- ========== Private functions ==========

local function _internal_helper() end

-- ========== Public API ==========

function M.init(config)
  if state.initialized then return M end
  state.initialized = true
  return M
end

return M
```

### Naming Conventions

| Type       | Convention          | Example                    |
| ---------- | ------------- | ----------------------- |
| Module export   | `M`           | `local M = {}`          |
| Public function   | camelCase     | `M.sendMessage()`       |
| Private function   | `_camelCase`  | `local _buildReq`       |
| Local variable   | snake_case    | `local agent_id`        |
| Constant       | UPPER_SNAKE   | `MAX_RETRIES`           |
| State constant   | UPPER_SNAKE   | `STATES.IDLE`           |
| Event name     | `domain:verb` | `"agent:spawn"`         |
| Boolean function   | `is/has/can`  | `isActive()`, `hasTool()`|

### Async Patterns

```lua
-- Use Promise style instead of raw callbacks
async.new(function(resolve, reject)
  http.get(url, function(err, data)
    if err then reject(err) else resolve(data) end
  end)
end)
  :then_(function(data) ... end)
  :catch(function(err) ... end)
  :finally(function() ... end)

-- Retry (exponential backoff)
async.retry(fn, { retries = 3, delay_ms = 1000, backoff = 2, signal = sig, should_retry = fn })

-- Wait for all concurrently
async.all({ deferred1, deferred2 })
```

### Event-Driven Conventions

- Event names must always be referenced through the constants in `kernel/events.lua`; hard-coded strings are forbidden.
- Emit: `event_bus.emit(events.X, payload)`; subscribe: `event_bus.on(events.X, cb)` (returns a cancel function).
- payload uses a table and is immutable when passed across modules.

---

## 11. Testing Strategy

**Test framework**: a custom lightweight framework (`tests/init.lua`), no external dependencies, runnable headless.

- How to run: `:NeoAITest [suite_name ...]` (no arguments runs everything).
- Assertion API: `eq / ne / not_eq / true_ / false_ / nil_ / not_nil / matches / ok / deep_eq / sleep / throws`.
- Organization: `suite(name, fn)` defines a suite, `it(name, fn)` defines a case, plus the `before_each` hook.
- Dynamic loading: `run_all` automatically loads `tests/test_*.lua` via glob.

| Layer     | Scope                       | Tool                  |
| -------- | -------------------------- | --------------------- |
| Unit tests | Pure functions, no I/O             | Custom framework            |
| Integration tests | Cross-module collaboration (mocked I/O)     | Custom framework            |
| UI tests  | Tree/chat view interactions            | Custom framework + nvim     |
| E2E tests | Full flows (real API optional)  | Manual + record/replay       |
| Contract tests | Event payload schema validation   | Custom assertions            |

**Testing principles**:
- Pure logic in `kernel/` and `utils/` is testable without the Neovim runtime
- Agent tests use a mocked AbortSignal and HTTP client
- Event tests verify that payloads conform to the schema
- Every module exposes `reset()` (for tests) to clean up module-level state

---

## 12. Refactoring and Migration Guide

(v2.0 → v3.0 is complete; historical decision notes are retained)

### Completed Refactors

| Old module                       | Current state                                     |
| ---------------------------- | ---------------------------------------- |
| `core/config/state.lua`      | The coroutine context mechanism was removed entirely; configuration was merged into config_store |
| `core/config/merger.lua`     | Merged into `kernel/config_store`             |
| `core/events.lua`            | Split: `kernel/events` (constants) + `kernel/event_bus` (implementation) |
| `core/shutdown_flag.lua`     | Replaced by AbortSignal (utils/async)        |
| `core/ai/engine.lua`         | Split into multiple files under `agent/`                 |
| `core/ai/request_handler.lua`| Split into `agent/request` + `agent/stream`  |
| `core/ai/tool_cycle.lua`     | Split into `agent/tool_loop`                 |
| `core/ai/phase_manager.lua`  | Logic consolidated into `agent/runtime`               |
| `core/history/*` (5 files)  | Merged into `core/session/` (4 files)       |
| `tools/approval_state.lua`   | Merged into `services/tool_service`           |
| `ui/ui_events.lua`           | Event listening unified in `services/`               |

### New Modules in v3.0

| New module                       | Responsibility                                     |
| ---------------------------- | ---------------------------------------- |
| `kernel/event_bus.lua`       | Event bus (implemented with Neovim User autocmd)     |
| `core/session/compactor.lua` | Context compaction (token pressure + overflow recovery)      |
| `core/agent/prefix.lua`      | Prefix management and cache identity fingerprint                   |
| `core/agent/guard.lua`       | Tool loop guard (repeated call reminders)             |
| `core/agent/recovery.lua`    | Context overflow recovery (resend after compaction)            |
| `tools/builtin/tree_ops.lua` | treesitter parse/query/delete node            |
| `tools/builtin/log_ops.lua`  | Log read/write tools                             |
| `tools/builtin/plan.lua`     | Sub-agent creation/monitoring/cancellation (including boundary review)    |
| `tools/builtin/plan_mode.lua`| Plan mode (read-only tool context + formatted plan + confirm to switch to CHAT)|
| `tools/builtin/ask_user.lua` | Ask-the-user tool (UI seam + vim.ui.input fallback)      |
| `tools/builtin/todo.lua`     | Todo list (whole-table replacement semantics + system prompt injection)  |
| `ui/components/fold.lua`     | Fold component                                 |

---

## 13. Built-in Tools Reference

| File | Tool |
| ---- | ---- |
| `file_ops.lua` | `read_file` / `edit_file` / `list_files` / `search_files` / `file_exists` / `create_directory` / `ensure_dir` / `delete_file` / `confirm_file_change` |
| `shell.lua`    | `run_command` |
| `git_ops.lua`  | `git_status` / `git_diff` / `git_log` / `git_commit_detail` / `git_branch` / `git_file_history` / `git_rollback` / `git_auto_commit_config` |
| `lsp_ops.lua`  | `lsp_hover` / `lsp_definition` / `lsp_references` / `lsp_document_symbols` / `lsp_workspace_symbols` / `lsp_diagnostics` / `lsp_client_info` / `lsp_code_action` / `lsp_rename` / `lsp_format` / `lsp_signature_help` / `lsp_completion` / `lsp_type_definition` / `lsp_declaration` / `lsp_implementation` / `lsp_service_info` |
| `tree_ops.lua` | `parse_file` / `get_node_at_position` / `get_node_type` / `get_node_range` / `is_named_node` / `get_parent_node` / `get_child_nodes` / `get_node_code` / `query_tree` / `delete_node` |
| `log_ops.lua`  | `log_message` / `get_log_levels` |
| `plan.lua`     | `create_sub_agent` / `get_sub_agent_status` / `wait_sub_agent` / `cancel_sub_agent` |
| `plan_mode.lua`| `enter_plan_mode` (switches the tool context to read-only/informational + asking questions) |
| `ask_user.lua` | `ask_user` |
| `todo.lua`     | `todo_write` / `todo_read` / `todo_clear` |
