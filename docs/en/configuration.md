# NeoAI Configuration System (v3.0)

> [中文](../configuration.md) | **English**

> Configuration is provided as immutable defaults by `default_config.lua` (pure data, zero logic),
> merged and read by `kernel/config_store.lua` (merge + validate + get + watch),
> and the kernel bootstrap is handled by `kernel/lifecycle.lua` (bootstrap/shutdown).
> Corresponding source: `lua/NeoAI/default_config.lua`, `lua/NeoAI/kernel/config_store.lua`.

## 1. Configuration Storage (kernel/config_store.lua)

Replaces the old `merger.lua` + `state.lua` hybrid and manages no business state.

| API | Description |
| --- | --- |
| `load(user_config)` | Deep-merges user overrides onto default → validate → produce immutable config; emits `CONFIG_LOADED`. |
| `get(path, default)` | Reads by dot-separated path (e.g. `ui.window.width`). |
| `get_all()` | Returns the complete configuration. |
| `watch(path, cb)` | Watches config changes (path-prefix match) and returns an unsubscribe function. |
| `set(path, value)` | Hot-updates at runtime, emitting `watch` + `CONFIG_CHANGED`. |
| `reset()` | Reset (for tests). |

`load` validation logic: checks `ai.default_provider`, the `base_url` of each provider in `ai.providers`,
and the `ai.modes` structure, collecting errors and logging them (without blocking).

## 2. Configuration Structure

See `lua/NeoAI/default_config.lua` for the full configuration. The main sections are below.

### 2.1 `ai`

| Key | Default | Description |
| --- | --- | --- |
| `default_provider` | `"deepseek"` | Default provider |
| `default_model` | `"auto"` | "auto" = resolve the default model via the registry |
| `providers` | 13+ providers | Provider definitions: `api_type` (openai/anthropic/google), `base_url`, `api_key`, `fetch_models`, `models_override` |
| `model_refresh` | `{on_startup=true, interval_sec=3600, timeout_ms=10000}` | Model list refresh |
| `modes` | `{chat, plan, auto}` | Per mode → `{provider, model, temperature, stream}` (optional `max_tokens`); applied when entering that mode. If `max_tokens` is not configured, nothing is sent |
| `truncation` | `{enabled=true, max_continues=3}` | Auto-continues when output is truncated with no tool call (the prompt is not stored), and writes a visible notice once the limit is exceeded |
| `reasoning_enabled` | `true` | Enables deep thinking (reasoning_content) |
| `system_prompt` | Default Chinese prompt | persona section |
| `timeout_ms` | `60000` | Request timeout |
| `max_retries` | `3` | Number of request retries |
| `attachments` | See below | Multimodal image configuration |
| `model_policy` | See below | Automatic per-model selection: capability table + vendor dialect + explicit cache |
| `context_cache` | See below | Prefix-cache identity + automatic context compaction |

**attachments (multimodal)**:

```lua
attachments = {
  enabled = true,               -- Master switch for multimodal
  path = ".../NeoAI/attachments", -- Content-addressed attachment storage directory
  vision_models = { "deepseek-v4-flash-vision-exp", "deepseek-vl" },
  vision_model_heuristics = { "vision", "-vl", "4o", "gemini" },
  media_types = { "image/png", "image/jpeg", "image/webp", "image/gif" },
  limits = { maxImageBytes=20MB, maxImagesPerMessage=16, maxMessageImageBytes=40MB,
             maxImagePixels=50M, maxImageDimension=8000 },
  request_image = { maxPixels=640000, maxBytes=1MB, maxImagesPerRequest=8,
                    maxRequestBytes=20MB, maxRequestImages=600 },
}
```

**model_policy (automatic per-model selection)**:

```lua
model_policy = {
  enabled = true,                 -- Master switch
  explicit_cache = {
    enabled = true,               -- Master switch for explicit caching
    openai = false,               -- OpenAI explicit breakpoints are disabled by default
    -- anthropic = true, gemini = true,  -- Per-mechanism switches (default to following the master switch)
  },
  overrides = {                   -- Capability overrides (key = model id or provider name)
    -- ["deepseek-v4-flash"] = { window = 131072, max_output = 8192 },
  },
  dialects = {                    -- Dialect overrides (key = provider name or model id)
    -- ["my-provider"] = { max_tokens_field = "max_completion_tokens", reasoning_kind = "effort" },
  },
}
```

The capability table provides the context window, max output, cache mechanism (`openai`/`anthropic`/`gemini`),
the minimum cacheable tokens, explicit-cache TTL/breakpoint limits, and character/token coefficients; the dialect
table provides provider/model request parameter names, reasoning parameter shapes, auth headers, and
usage fields. See [model_policy.md](model_policy.md) for details.

**Live value retrieval**: the context window / max output are preferably fetched **live** from each vendor's
`/models` endpoint (Google's `inputTokenLimit`/`outputTokenLimit`, OpenRouter's
`context_length`/`top_provider.max_completion_tokens`, Groq's `context_window`, etc.); only when that fails does
it fall back to the built-in table. Value precedence: **user `overrides` → live metadata →
built-in pattern → `api_type` default → fallback** (`caps.source` records the source).
`max_tokens` sending policy: only explicitly configured values (via `opts.max_tokens` or `modes.*.max_tokens`) are
sent; if not configured, it is **not sent**, and the model/vendor default max output applies (live values /
`overrides.max_output` are no longer sent automatically, and are used only for capping and capacity display);
Anthropic `max_tokens` is required, and falls back to the capability table's `max_output`.

**context_cache (prefix caching + compaction)**:

```lua
context_cache = {
  enabled = true,
  context_window = 64000,       -- Context window fallback: an explicit non-default user value wins, otherwise it is derived from the model capability table
  threshold_ratio = 0.8,        -- Reaching this ratio triggers compaction (explicit-cache models automatically use a more conservative value)
  retain_ratio = 0.16,          -- Proportion of recent history to retain
  retain_min_tokens = 4096,     -- Lower bound for the retained tail
  compact_max_tokens = 8192,    -- Max output for the compaction summary
  min_shadow_messages = 2,      -- Minimum number of messages to collapse before compaction is worthwhile
  compaction_retries = 1,       -- Retries when the result is still above the threshold after summarization
  prune_enabled = true,         -- Perform model-agnostic tool-result pruning before summarization
  prune_threshold_chars = 8192, -- Only tool results whose text code points exceed this value are pruned
  prune_head_chars = 4096,      -- Number of head code points kept when pruning
  prune_tail_chars = 1024,      -- Number of tail code points kept when pruning
  include_identity = true,      -- Whether the system prompt includes the fixed identity section (order position -100)
  identity = "You are an AI programming assistant powered by NeoAI.",
}
```

### 2.2 `ui`

| Key | Default | Description |
| --- | --- | --- |
| `default_view` | `"chat"` | Default view (chat/tree) |
| `window_mode` | `"tab"` | Window mode (float/tab/split) |
| `window` | `{width=80, height=24, border="rounded"}` | float window |
| `split` | `{size=80, direction="right"}` | split window |
| `colors` | Per-segment highlights | User/AI/reasoning/title colors |
| `tree` | `{foldenable=false, ...auto_close_on_select=true}` | Session tree folding/auto-close |
| `input_box` | `{idle_height=1, min_height=5, max_ratio=0.8}` | Input box height (idle/focused/growth cap) |
| `chat` | `{mousescroll_max_blank=3}` | Max blank lines allowed below the last line when the wheel reaches the bottom (0 = strictly bottom-aligned) |
| `trajectory` | `{log_dir=".../NeoAI/logs"}` | Log directory for the trajectory display mode |
| `statusline` | `{enabled=true, winbar=true, parts={mode,model,usage,cache,capacity}, separator=" ", colors=...}` | lualine statusline |

### 2.3 `keymaps`

| Section | Description |
| --- | --- |
| `global` | `toggle_ui`(<leader>aa), `open_chat`(<leader>ac), `open_tree`(<leader>at), `close_all`(<leader>aq) |
| `tree` | `quit`(q), `select`(<CR>), `new_child`(n), `new_root`(N), `delete_dialog`(d), `delete_branch`(D), `expand`(o), `collapse`(O) |
| `chat` | `insert`(i), `quit`(q), `send`, `cancel`(<Esc>), `toggle_reasoning`(r), `switch_model`(M), `cycle_mode`(m), `cycle_display`(<C-t>/T), `reload_display`(<F5>), `tool_approval`(<C-a>), `approval.*` |

### 2.4 `session`

```lua
session = {
  auto_save = true,
  auto_naming = true,
  save_path = ".../NeoAI",
  max_history_per_session = 1000,
  file = "sessions.jsonl",   -- Append-only JSONL
}
```

### 2.5 `tools`

| Key | Default | Description |
| --- | --- | --- |
| `enabled` | `true` | Master switch for the tool system |
| `builtin` | `true` | Load built-in tools |
| `external` | `{}` | External tools |
| `read_file` | `{outline_threshold_chars=500, outline_max_nodes=200, outline_max_depth=4, outline_preview_lines=50}` | read_file large-file protection: when no line range is specified and the threshold is exceeded, return a syntax-tree outline (or a truncated preview if no parser is available) |
| `lsp` | `{timeout_ms=10000}` | LSP request timeout (fail fast when the server does not respond) |
| `guard.repeat_tool` | `{enabled=true, thresholds={3,5,8}, messages=...}` | Reminder for consecutive repeated tool calls |
| `todo.enabled` | `true` | Todo tool + system prompt injection |
| `plan_mode` | `{enabled=true, auto_execute_on_approve=true, extra_safe_tools={}, mutating_tools=...}` | Plan mode |
| `approval` | See below | Tool approval |

**approval (tool approval)**:

```lua
approval = {
  mode = "prompt",             -- prompt | auto_allow | strict
  default_auto_allow = false,
  timeout_ms = 60000,          -- Approval dialog timeout (prevents hanging forever)
  allowed_directories = {},
  allowed_param_groups = {},
  per_tool = {
    read_file      = { auto_allow = true },
    edit_file      = { auto_allow = false },
    list_files     = { auto_allow = true },
    search_files   = { auto_allow = true },
    file_exists    = { auto_allow = true },
    create_directory= { auto_allow = false },
    ensure_dir     = { auto_allow = false },
    delete_file    = { auto_allow = false },
    run_command    = { auto_allow = false, allowed_directories = { "./" },
                       allowed_param_groups = { "ls", "wc", "find", "grep", "pwd" } },
    create_sub_agent    = { auto_allow = false },
    get_sub_agent_status= { auto_allow = true },
    cancel_sub_agent    = { auto_allow = true },
    git_diff / git_log / git_status / git_commit_detail /
    git_file_history / git_branch / git_auto_commit_config = { auto_allow = true },
    git_rollback = { auto_allow = false },
    log_message / get_log_levels = { auto_allow = true },
    lsp_rename / lsp_format / delete_node = { auto_allow = false },
  },
}
```

> **Approval decisions**: `mode=auto_allow` → no approval; `mode=strict` → always approve;
> a tool with `auto_allow=true` → no approval; a path inside an allowed directory + the command's first word in an
> allowed parameter group → no approval.

### 2.6 `herder`

```lua
herder = {
  enabled = true,          -- Whether to enable reporting (also requires HERDR_ENV=1 to take effect)
  source = "custom:neoai", -- Stable and globally unique lifecycle authority identifier
  agent = "neoai",         -- Agent name (used for identification on the Herder side)
}
```

### 2.7 `log`

```lua
log = {
  level = "WARN",
  path = ".../NeoAI/neoai.log",
  max_size = 10485760,
  max_backups = 5,
  format = "[{time}] [{level}] {message}",
  verbose = false,
}
```

### 2.8 `mcp`

```lua
mcp = {
  enabled = true,
  timeout_ms = 60000,
  connect_timeout_ms = 20000,
  reconnect = true,
  cache_path = ".../NeoAI/mcp_cache.json",
  servers = { /* see docs/mcp.md */ },
  resources = { max_result_bytes = 100 * 1024 },
}
```

### 2.9 `skills`

```lua
skills = {
  enabled = true,
  paths = { vim.fn.stdpath("config") .. "/skills", ".neoai/skills", ".claude/skills" },
  max_skills_in_prompt = 20,
  max_skill_bytes = 64 * 1024,
  inject_mode = "list",       -- list | full | none
  persist_loaded = false,
  register_tools = true,
}
```

## 3. Plan Mode (tools/plan_mode)

Plan mode is a **per-agent state** (`agent.plan_mode`); when active:

1. **Injects the plan-policy system prompt section** (`deployment:plan_policy`, order=100): requires a clear, formatted modification plan as output.
2. **Keeps only read-only/informational tools in the tool context, plus `ask_user` + `exit_plan_mode`** (the `PLAN_SAFE_TOOLS` allowlist), exposing no mutating tools.
3. **Tightens the execution-time gate accordingly** (`plan_mode.check_tool`): in plan mode, any tool outside the visible set is rejected.

**Plan confirmation**: the AI calls `exit_plan_mode` (the approval dialog is confirmed by the user) or the user runs `:NeoAIApprovePlan`;
`chat_service.approve_plan` then parses the plan into a task list (todo) → exits plan mode (switching to CHAT)
→ automatically starts execution according to `auto_execute_on_approve` (enabled by default).

The state is persisted in `session.metadata.plan` and restored when the session is resumed (`plan_mode.restore`).

## 4. Related Documentation

- [README configuration section](../../README.en.md): full configuration example.
- [tool_system.md](tool_system.md): runtime behavior of the `tools.*` tool/approval configuration.
- [ai_engine.md](ai_engine.md): engine-side behavior of `ai.context_cache` / `ai.reasoning_enabled`.
- [model_policy.md](model_policy.md): automatic per-model selection (protocol dialect / capability table / explicit cache).
