# NeoAI

> [中文](README.md) | **English**

> 🧠 **NeoAI** — a powerful Neovim AI coding assistant plugin that integrates multi-model AI chat, file operations, code analysis, and Shell command execution, with tree-based session management and sub-Agent collaboration.

---

## ✨ Features

- **Multi-provider AI support** — ships with 13+ AI providers, including DeepSeek, OpenAI, Anthropic, Google Gemini, Groq, Together AI, OpenRouter, SiliconFlow, Moonshot, Zhipu, Baidu, Alibaba Cloud, and StepFun
  - (Limited budget — only DeepSeek has been tested)
- **Automatic per-model adaptation** — request parameter formats and cache-hit accounting adapt to the model automatically: protocol-family codecs (OpenAI/Anthropic/Gemini messages · tools · images) + vendor dialects (`max_tokens`/`max_completion_tokens`, `reasoning_effort`/`thinking`/`enable_thinking`, etc.) + a model capability table (context window / output limit / cache mechanism) + explicit caching (Anthropic breakpoints / OpenAI explicit / Gemini `cachedContents`, falling back to implicit on failure), with a safe fallback for unknown models (see [docs/en/model_policy.md](docs/en/model_policy.md))
- **Scenario-based model configuration** — assign a different AI model and parameters to each scenario (chat, coding, thinking, tool execution, sub-Agent, window naming)
- **Streaming responses** — display AI output in real time as a stream, including reasoning traces
- **Tree-based session management** — manage multiple chat sessions as a branch tree, with branch creation, switching, and deletion
- **A rich set of built-in tools** — the AI can call 40+ tools for file operations, code analysis, LSP, Shell commands, and more
- **Tool approval system** — fine-grained control over tool execution permissions, supporting auto-allow / manual approval / argument-level allowlists
- **Plan mode (PLAN) and plan distillation** — toggle with `m` or `:NeoAIPlan`; the tool context retains only read-only / informational queries plus `ask_user` and `exit_plan_mode` (no mutating tools are exposed); after the AI researches and clarifies, it emits a formatted change plan and calls `exit_plan_mode`; once the user confirms, NeoAI switches to CHAT and executes the plan automatically, **distilling** the research context gathered during planning into a checkpoint that replaces the compacted range
- **Streaming context compaction** — as the context threshold approaches, old history is folded automatically and the folded range is **replaced** (not appended to) by a checkpoint, keeping the prefix cache reusable; in addition to turn boundaries, **a pressure check runs before every round of the tool loop** (after tool results are written back and before the next request), so long loops converge round by round; on overflow the request is compacted and retried automatically; the compaction / plan distillation process shows reasoning and content live in a floating window
- **Sub-Agent system** — the AI can spawn sub-Agents to run subtasks in parallel, with boundary review
- **Decoupled frontend/backend architecture** — an event-driven asynchronous architecture that separates the UI from business logic
- **Highly configurable** — full customization of keymaps, UI layout, log level, and more
- **Written purely in Lua** — no extra dependencies required
- **⚠️⚠️⚠️Requests are sent with curl** — if curl is not available in the environment, requests may fail
- **Pending message queue** — messages sent while the Agent is busy are queued automatically, a `待发N` ("N pending") badge appears in the statusline as a reminder, and the badge disappears once the messages are actually sent
- **Multimodal images** — the `read_image` tool loads PNG/JPEG/WebP/GIF and injects them into multimodal models (content-addressed attachment storage + request-time pixel/byte budget offload, automatically degrading to text when the model does not support images)
- **lualine statusline integration** — show model usage, cache-hit rate, and context capacity in real time inside the chat window via `nvim-lualine` (the model/usage/cache/capacity sections are customizable)
- **Herder status reporting** — report Agent state (working/idle/blocked) in real time inside the Herder pane, automatically aggregating multiple sessions, with a strictly increasing `--seq` to guard against concurrent rollback
- **Tool argument receiving panel** — while the model streams tool-call arguments, a "receiving arguments" floating window (`tool_args_panel`) opens in real time, appending each chunk incrementally and closing automatically once the arguments end, consistent with the reasoning floating window
- **MCP support** — connect to external MCP servers over stdio / Streamable HTTP and register remote `tools`/`resources`/`prompts` in the tool system (with pre-caching + failure-driven dynamic refresh, see [docs/en/mcp.md](docs/en/mcp.md))
- **Skills support** — scan SKILL.md skill directories and inject the list of available skills into the system prompt; the model loads the skill body with `load_skill` (Claude/opencode style, see [docs/en/skills.md](docs/en/skills.md))

---

## 📦 Installation

### Using lazy.nvim

```lua
{
  "gygygfg/NeoAI",
  config = function()
    require("NeoAI").setup({
      -- Optional configuration, see the "Configuration" section below
    })
  end,
}
```

### Using packer.nvim

```lua
use {
  "gygygfg/NeoAI",
  config = function()
    require("NeoAI").setup({})
  end,
}
```

### Using vim.pack

```lua

vim.pack.add({ gh("gygygfg/Neoai") })

require("NeoAI").setup({})

```

---

## 🚀 Quick Start

### 1. Set the API Key

Set your AI provider's API Key in an environment variable:

```bash
export DEEPSEEK_API_KEY="your-api-key"
# or
export OPENAI_API_KEY="your-api-key"
# or
export ANTHROPIC_API_KEY="your-api-key"
```

### 2. Initialize the plugin

```lua
require("NeoAI").setup({
  ai = {
    default_provider = "deepseek",
    providers = {
      deepseek = {
        api_key = os.getenv("DEEPSEEK_API_KEY"),
      },
    },
  },
})
```

### 3. Commands

| Command            | Description                                      |
| ------------------ | ------------------------------------------------ |
| `:NeoAIOpen`       | Open the main NeoAI UI                           |
| `:NeoAIChat`       | Open the chat UI                                 |
| `:NeoAITree`       | Open the session tree UI                         |
| `:NeoAIClose`      | Close all NeoAI windows                          |
| `:NeoAIKeymaps`    | Show the current keymap configuration            |
| `:NeoAITest`       | Run tests (all tests with no arguments, or a specific test with an argument) |
| `:NeoAIChatStatus` | Show the chat window status                      |
| `:NeoAICycleDisplay`| Cycle through chat display modes (chat/trace)   |
| `:NeoAIReloadDisplay`| Hot-reload the display mode plugin (reloads the current mode by default) |
| `:NeoAIPlan`       | Toggle plan mode (the tool context retains only read-only / informational queries + asking the user) |
| `:NeoAIAuto`       | Toggle AUTO mode (automatically allow all tool calls) |
| `:NeoAIApprovePlan`| Confirm the plan and switch to CHAT mode to execute it per the task list |
| `:NeoAIStatusline` | Preview the content of the current lualine statusline components |

### 4. Default Keymaps

| Keymap       | Description    |
| ------------ | -------------- |
| `<leader>aa` | Toggle UI visibility |
| `<leader>ac` | Open the chat UI   |
| `<leader>at` | Open the session tree UI |
| `<leader>aq` | Close all windows  |

---
## ⚙️ Configuration

<details>
<summary>Click to expand the full configuration structure</summary>

```lua
require("NeoAI").setup({
  -- ===== AI configuration =====
  ai = {
    default_provider = "deepseek",       -- default provider
    default_model = "auto",              -- "auto" = use the first available model in the registry

    -- Provider definitions (13+ AI service providers)
    providers = {
      deepseek = {
        api_type = "openai",             -- API type: openai / anthropic / google
        base_url = "https://api.deepseek.com",
        api_key = os.getenv("DEEPSEEK_API_KEY"),
        fetch_models = true,             -- whether to fetch the model list automatically (async background fetch)
        models_override = nil,           -- optional: specify models manually (overrides the API result)
      },
      openai = {
        api_type = "openai",
        base_url = "https://api.openai.com/v1",
        api_key = os.getenv("OPENAI_API_KEY"),
        fetch_models = true,
      },
      -- More providers: anthropic, google, groq, together, openrouter, siliconflow,
      -- moonshot, zhipu, baidu, aliyun, stepfun
    },

    model_refresh = {
      on_startup = true,                 -- fetch the model list automatically after startup
      interval_sec = 3600,               -- periodic refresh (0 = disabled)
      timeout_ms = 10000,                -- timeout for a single request
    },

    -- Configure the provider and model parameters separately per mode (CHAT / PLAN / AUTO);
    -- entering a mode applies its provider/model/temperature/stream, falling back to ai.default_provider by default.
    -- max_tokens is unset by default: the parameter is not sent with the request, and the default maximum output of the
    -- model/vendor applies; it is only sent when configured explicitly.
    modes = {
      chat = { provider = "deepseek", model = "auto", temperature = 0.7, stream = true },
      plan = { provider = "deepseek", model = "auto", temperature = 0.3, stream = true },
      auto = { provider = "deepseek", model = "auto", temperature = 0.7, stream = true },
    },

    -- Automatically continue when the output is truncated (finish_reason=length/max_tokens/MAX_TOKENS) and no tool
    -- call is pending: the continuation prompt is added to the request only and is never persisted; if the limit is
    -- reached and the output is still truncated, a visible notice is written (see docs/en/ai_engine.md 4.5).
    truncation = { enabled = true, max_continues = 3 },

    reasoning_enabled = true,            -- enable deep reasoning mode
    system_prompt = "You are an AI coding assistant that helps users solve programming problems.",
    timeout_ms = 60000,                  -- request timeout
    max_retries = 3,                     -- number of request retries

    -- Automatic per-model selection: capability table + vendor dialect + explicit cache (see docs/en/model_policy.md)
    model_policy = {
      enabled = true,                    -- master switch (when off, only the basic codecs for the three protocols remain)
      explicit_cache = {
        enabled = true,                  -- master switch for explicit caching
        openai = false,                  -- OpenAI explicit breakpoints are off by default (implicit caching is sufficient)
        -- anthropic = true, gemini = true, -- per-mechanism switches (follow the master switch by default)
      },
      -- overrides = {                    -- capability overrides (key = model id or provider name)
      --   ["deepseek-v4-flash"] = { window = 131072, max_output = 8192 },
      -- },
      -- dialects = {                     -- dialect overrides (key = provider name or model id)
      --   ["my-provider"] = { max_tokens_field = "max_completion_tokens", reasoning_kind = "effort" },
      -- },
    },

    -- Prefix cache identity consistency + automatic context compaction
    context_cache = {
      enabled = true,                    -- enable identity consistency + automatic compaction
      context_window = 64000,            -- fallback window: an explicit non-default user value wins, otherwise derived from the model capability table
      threshold_ratio = 0.8,             -- reaching this ratio triggers compaction
      warn_ratio = 0.85,                 -- the statusline changes color as the limit approaches
      retain_ratio = 0.16,               -- proportion of the most recent history to retain
      retain_min_tokens = 4096,          -- lower bound for the retained tail (tokens)
      compact_max_tokens = 8192,         -- output limit of the compaction summary
      min_shadow_messages = 2,           -- minimum number of messages to fold before compaction is worthwhile
      compaction_retries = 1,            -- number of retries when still above the threshold after summarization
      prune_enabled = true,              -- perform model-agnostic tool-result pruning before summarization
      prune_threshold_chars = 8192,      -- only tool results whose text exceeds this many code points are pruned
      prune_head_chars = 4096,           -- number of leading code points retained by pruning
      prune_tail_chars = 1024,           -- number of trailing code points retained by pruning
      include_identity = true,           -- whether the system prompt includes a fixed identity section (order position -100)
      identity = "You are an AI coding assistant powered by NeoAI.",
    },
  },

  -- ===== UI configuration =====
  ui = {
    default_view = "chat",               -- default view: tree / chat
    window_mode = "tab",                 -- window mode: float / tab / split
    window = { width = 80, height = 24, border = "rounded" },
    split = { size = 80, direction = "right" },
    colors = {                           -- highlight group linked by each element
      background = "Normal", border = "FloatBorder",
      user_message = "Comment", ai_message = "Normal",
      reasoning = "Type", title = "Title",
    },
    tree = {
      foldenable = false, foldmethod = "manual", foldcolumn = "0", foldlevel = 99,
      auto_close_on_select = true,       -- automatically close the tree window after opening chat from a session selected in the tree
    },
    input_box = {
      idle_height = 1,                   -- input box height when the cursor is in the main chat area
      min_height = 5,                    -- minimum height when the cursor is inside the input box (starting value)
      max_ratio = 0.8,                   -- upper limit as content grows (share of the main window height)
    },
    trajectory = {
      log_dir = vim.fn.stdpath("cache") .. "/NeoAI/logs", -- directory for saving trajectory logs
    },
  },

  -- ===== Keymap configuration =====
  keymaps = {
    global = {
      toggle_ui = { key = "<leader>aa", desc = "Toggle UI display" },
      open_chat = { key = "<leader>ac", desc = "Open the chat interface" },
      open_tree = { key = "<leader>at", desc = "Open the tree interface" },
      close_all = { key = "<leader>aq", desc = "Close all windows" },
    },
    tree = {
      quit = { key = "q", desc = "Close the session tree" },
      select = { key = "<CR>", desc = "Select a node/branch" },
      new_child = { key = "n", desc = "Create a child branch" },
      new_root = { key = "N", desc = "Create a root branch" },
      delete_dialog = { key = "d", desc = "Delete a conversation" },
      delete_branch = { key = "D", desc = "Delete a branch" },
      expand = { key = "o", desc = "Expand a node" },
      collapse = { key = "O", desc = "Collapse a node" },
    },
    chat = {
      insert = { key = "i", desc = "Enter insert mode" },
      quit = { key = "q", desc = "Close the chat window" },
      send = { insert = { key = "<C-s>" }, normal = { key = "<CR>" } },
      cancel = { key = "<Esc>", desc = "Cancel generation" },
      switch_model = { key = "M", desc = "Switch model" },
      toggle_reasoning = { key = "r", desc = "Toggle the display of the reasoning process" },
      cycle_mode = { key = "m", desc = "Cycle through modes (CHAT/PLAN/AUTO)" },
      cycle_display = {
        insert = { key = "<C-t>", desc = "Cycle display modes (chat/trajectory)" },
        normal = { key = "T", desc = "Cycle display modes (chat/trajectory)" },
      },
      reload_display = { key = "<F5>", desc = "Hot-reload the plugin of the current display mode" },
      tool_approval = { key = "<C-a>", desc = "Tool approval" },
      approval = {
        confirm = { key = "<CR>", desc = "Allow once" },
        confirm_all = { key = "A", desc = "Allow all" },
        cancel = { key = "<Esc>", desc = "Cancel" },
        cancel_with_reason = { key = "C", desc = "Cancel with a reason" },
      },
    },
  },

  -- ===== Session configuration =====
  session = {
    auto_save = true,
    auto_naming = true,
    save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    max_history_per_session = 1000,
    file = "sessions.jsonl",             -- append-only JSONL storage
  },

  -- ===== Tool configuration =====
  tools = {
    enabled = true,
    builtin = true,
    external = {},
    read_file = {
      outline_threshold_chars = 500,   -- with no line range, return a syntax tree outline when the file exceeds this many characters
      outline_max_nodes = 200,         -- maximum number of nodes emitted in the outline
      outline_max_depth = 4,           -- maximum recursion depth of the outline
      outline_preview_lines = 50,      -- number of preview lines when no parser is available
    },
    lsp = {
      timeout_ms = 10000,                -- LSP request timeout (fail fast when the server does not respond)
    },
    guard = {
      repeat_tool = {
        enabled = true,                  -- detect consecutive repeated tool calls and inject a reminder
        thresholds = { 3, 5, 8 },        -- increasing reminder thresholds
        messages = { [3] = "...", [5] = "...", [8] = "..." },
      },
    },
    todo = {
      enabled = true,                    -- to-do list tool + system prompt injection
    },
    plan_mode = {
      enabled = true,                    -- plan mode
      auto_execute_on_approve = true,    -- after the plan is approved, switch to CHAT automatically and execute it item by item
      distill_on_execute = true,         -- distill the research context from the planning phase into a checkpoint to replace compaction
      extra_safe_tools = {},             -- extensions to the plan mode allowlist
      -- mutating_tools = { ... },       -- mutating tools (the visible set in plan mode already covers this semantics)
    },
    approval = {
      mode = "prompt",                   -- prompt | auto_allow | strict
      default_auto_allow = false,
      timeout_ms = 60000,                -- approval dialog timeout (prevents an indefinite hang)
      allowed_directories = {},
      allowed_param_groups = {},
      per_tool = {
        read_file      = { auto_allow = true },
        edit_file      = { auto_allow = false },
        list_files     = { auto_allow = true },
        search_files   = { auto_allow = true },
        delete_file    = { auto_allow = false },
        run_command    = { auto_allow = false, allowed_directories = { "./" }, allowed_param_groups = { "ls", "grep" } },
        create_sub_agent = { auto_allow = false },
        -- more per-tool approval configuration...
      },
    },
  },

  -- ===== Log configuration =====
  log = {
    level = "WARN",                      -- DEBUG / INFO / WARN / ERROR / FATAL
    path = vim.fn.stdpath("cache") .. "/NeoAI/neoai.log",
    max_size = 10485760,
    max_backups = 5,
  },

  -- ===== MCP (Model Context Protocol) =====
  mcp = {
    enabled = true,                      -- whether to enable the MCP client
    timeout_ms = 60000,                  -- timeout for a single JSON-RPC request
    connect_timeout_ms = 20000,          -- connection/handshake timeout
    reconnect = true,                    -- reconnect after a failed or dropped connection
    cache_path = vim.fn.stdpath("cache") .. "/NeoAI/mcp_cache.json", -- pre-cache of tool descriptions
    servers = {
      -- [name] = {
      --   transport = "stdio" | "http",
      --   -- stdio:
      --   command = "npx",
      --   args = { "-y", "@modelcontextprotocol/server-filesystem", vim.fn.getcwd() },
      --   env = {},
      --   -- http:
      --   url = "https://example.com/mcp",
      --   headers = { ["Authorization"] = "Bearer ..." },
      --   -- common:
      --   expose = { tools = true, resources = true, prompts = true },
      --   approval = { auto_allow = false },  -- approval required by default (remote tools are untrusted)
      --   plan_safe = false,                   -- whether to allow it in plan mode
      -- }
    },
    resources = { max_result_bytes = 100 * 1024 },
  },

  -- ===== Skills (skill directories + SKILL.md) =====
  skills = {
    enabled = true,
    paths = {
      vim.fn.stdpath("config") .. "/skills",
      vim.fn.stdpath("data") .. "/neoai/skills",
      ".neoai/skills",
      ".claude/skills",
    },
    max_skills_in_prompt = 20,           -- maximum number of skills listed in the system prompt
    max_skill_bytes = 64 * 1024,         -- maximum content size of a single skill for load_skill
    inject_mode = "list",                -- list | full | none
    persist_loaded = false,              -- whether load_skill registers a persistent agent-level prompt section
    register_tools = true,               -- register list_skills / load_skill
  },

  -- ===== Herder terminal status signal =====
  herder = {
    enabled = true,                      -- whether to enable reporting (also requires HERDR_ENV=1 to take effect; a no-op outside a Herder environment)
    source = "custom:neoai",             -- stable, globally unique authoritative lifecycle identifier
    agent = "neoai",                     -- agent name (used for identification on the Herder side)
  },
})
```

### Multimodal (vision) configuration

NeoAI can inject images into multimodal models:

```lua
ai = {
  -- ...other configuration...
  attachments = {
    enabled = true, -- master switch for multimodal input
    path = vim.fn.stdpath("cache") .. "/NeoAI/attachments", -- content-addressed attachment storage directory
    vision_models = {
      "deepseek-v4-flash-vision-exp", -- model id or provider:model declared to support image input
    },
    vision_model_heuristics = { "vision", "-vl", "4o", "gemini" }, -- auto-detect vision models by id substring
    media_types = { "image/png", "image/jpeg", "image/webp", "image/gif" },
    limits = {
      max_image_bytes = 20 * 1024 * 1024,
      max_images_per_message = 16,
      max_message_image_bytes = 40 * 1024 * 1024,
      max_image_pixels = 50000000,
      max_image_dimension = 8000,
    },
    request_image = {
      max_pixels = 640000, -- per-request image pixel budget
      max_bytes = 1024 * 1024, -- per-request upper bound on encoded image bytes
      max_images_per_request = 8, -- maximum images retained per request (the oldest are dropped beyond this)
      max_request_bytes = 20 * 1024 * 1024,
    },
  },
}
```

> Image data is stored content-addressed under `attachments.path`, and session messages keep only immutable
> references, which are resolved into `image_url` (data URLs) only when a request is sent and then injected
> within the model route's pixel/byte budget, with the **oldest** overflow images replaced by text placeholders.
> When a model does not support images, NeoAI degrades gracefully without blocking the call.
### lualine statusline integration

NeoAI exposes information such as the current Agent's LLM usage, cache hit rate, and context capacity to `nvim-lualine`.
Two approaches are supported:

**Approach 1: automatic (recommended)** — no configuration needed. As long as nvim-lualine is detected, NeoAI
automatically injects the `neoai` extension into its configuration: if lualine is already past `setup()`, injection
happens during `NeoAI.setup()`; otherwise it is deferred until the chat window opens (at which point lualine is
guaranteed to be available).

**Approach 2: manual extension** — declare it explicitly in your lualine config (functionally identical, suited to
those who prefer explicit configuration):

```lua
require("lualine").setup({
  extensions = { "neoai" },
  -- ...the rest of your lualine config
})
```

The extension automatically replaces the default statusline with NeoAI's statusline in chat windows (where `filetype`
is `neoai` / `neoai_input` / `neoai_status`); changes to the extension code require re-running setup or a restart to
take effect.

**Approach 3: manual component** — keep your own statusline and simply slot NeoAI's information in as a segment in
any section:

```lua
require("lualine").setup({
  sections = {
    lualine_c = {
      { function() return require("NeoAI.services.status").component() end },
    },
  },
})
```

> If automatic injection didn't take effect because of startup order, you can manually call
> `NeoAI.enable_statusline()` or `require("NeoAI.services.status").ensure_lualine_extension()`.

Only the chat **main message window** is taken over (`filetype == neoai`); other windows such as the input box keep
your own lualine and are left untouched. The display is deliberately concise: cleanly split lines, no duplication,
no truncated blocks:

- **Line 1 (winbar)** identity: `[mode] model state`
- **Line 2 (statusline)** metrics: `↑prompt ↓completion cache-hit x% remaining-capacity y% pending N`

> `pending N`: while the Agent is busy (generating / tool_running / the generation slot is occupied), messages you
> send are queued first and this badge appears in the statusline as a reminder; once the message is actually sent,
> the badge disappears automatically (a zero count is not rendered).

Each segment links by default to a **vivid nvim highlight group**
(`Title`/`Type`/`Number`/`String`/`Statement`/`Function`/`Keyword`), identical for active and inactive, so an entire
line never turns gray (dims) when the window loses focus.

On multiple lines: a standalone `statusline` can only occupy a single line (Vim natively doesn't support line breaks).
NeoAI uses the `winbar` of the main message window as the second line, producing a clean two-line layout; all other
windows stay single-line. If you want just one line, set `ui.statusline.winbar = false`.

```lua
require("NeoAI").setup({
  ui = {
    statusline = {
      enabled = true,                                   -- false → the component returns an empty string
      winbar = true,                                    -- second line at the top of the main chat window (mode/model/state)
      parts = { "mode", "model", "usage", "cache", "capacity" }, -- order of the segments that component() joins
      separator = " ",                                  -- separator between segments
      colors = {                                        -- highlight group each segment links to (drop the drab palette)
        mode = "Title",        display = "Keyword",
        model = "Type",        usage = "Number",
        cache = "String",      capacity = "Statement",
        state = "Function",    brand = "Title",
      },
    },
  },
})
```

Related public APIs:

- `NeoAI.get_statusline_info()` — returns structured usage/cache/capacity data for the current Agent
- `NeoAI.get_statusline()` — returns the statusline text
- `require("NeoAI.services.status").segment(name)` — text of a single segment (mode/model/usage/cache/capacity/state/display/pending)
- `require("NeoAI.services.chat_service").pending_count()` — number of queued messages held while the current Agent is busy
- `:NeoAIStatusline` — previews the current statusline component content

### Herder terminal status integration

Inside a pane managed by **Herder**, NeoAI can report the AI Agent's real state (`working` / `idle` / `blocked`) to
Herder, so the Herder sidebar reflects the Agent's status in real time instead of relying on heuristics guessed from
screen output. This integration is only the **signal-generating side** — it translates the NeoAI Agent lifecycle into
Herder semantics and reports it; recognition/parsing on the Herder side is handled by Herder itself.

**Prerequisites** (all are required):

1. Running inside a pane with the Herder-injected environment (the environment variables `HERDR_ENV=1`,
   `HERDR_PANE_ID`, and `HERDER_BIN_PATH` are present);
2. `herder.enabled = true` (enabled by default).

Outside a Herder environment, this module is a complete no-op: it subscribes to no events and produces no side effects.

**State mapping**:

| NeoAI Agent state | Herder report |
|---|---|
| `generating` / `tool_running` | `working` |
| Tool approval wait / `ask_user` waiting for the user's answer | `blocked` |
| `idle` / `aborted` / `error` | `idle` |

**Multi-session aggregation**: a single Neovim pane may host multiple AI sessions (including sub-agents); NeoAI
aggregates them into one fixed `source` (default `custom:neoai`) and reports them uniformly, with an aggregation
priority of `blocked > working > idle`. Every report carries a strictly increasing `--seq`, so Herder ignores stale
packets from the same `source`, preventing status regressions caused by concurrent/asynchronous callbacks.

**Example reporting flow**:

```
# The user sends a message, the Agent starts generating
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state working --seq 1
# A tool needs approval / the user is asked a question and we wait for an answer (blocked)
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state blocked --seq 2
# Approval granted, still generating
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state working --seq 3
# This round of generation is done, waiting for input
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state idle --seq 4
# The chat window is closed and the last Agent is destroyed (releasing lifecycle authority)
herdr pane release-agent w1:p1 --source custom:neoai --agent neoai --seq 5
```

**Configuration**:

```lua
require("NeoAI").setup({
  herder = {
    enabled = true,           -- whether reporting is enabled (still requires HERDR_ENV=1 to actually take effect)
    source = "custom:neoai",  -- a stable, globally unique lifecycle authority identifier
    agent = "neoai",          -- agent name (used by Herder for identification)
  },
})
```

> Diagnostics: inside a Herder pane, use `herdr agent explain <pane-id>` to view the current Agent status source and
> recent reports.

</details>

---

## 🧰 Built-in Tools

NeoAI ships with 40+ built-in tools that the AI can call automatically during a conversation, covering the following
categories:

### 📁 File Operation Tools (operations that don't change code are auto-allowed by default)

| Tool name             | Description             | Default approval    |
| ------------------ | ---------------- | ----------- |
| `read_file`        | Read file contents (for large files, returns a syntax tree outline/preview by default; see below) | ✅ Auto-allowed |
| `edit_file`        | Edit file contents     | ❌ Needs approval   |
| `list_files`       | List directory files     | ✅ Auto-allowed |
| `search_files`     | Search file contents     | ✅ Auto-allowed |
| `create_directory` | Create a directory         | ❌ Needs approval   |
| `ensure_dir`       | Ensure a directory exists     | ❌ Needs approval   |
| `delete_file`      | Delete a file         | ❌ Needs approval   |
| `file_exists`      | Check whether a file exists | ✅ Auto-allowed |
| `read_image`       | Read an image file and inject the image into a multimodal model | ✅ Auto-allowed |

> **`read_file` large-file protection**: when `start_line`/`end_line` are not specified and the file exceeds the
> threshold (500 characters by default), the full text is not returned; instead the file's **tree-sitter syntax tree
> node outline** is returned (or a preview of the first few lines if there is no parser for that file type), so the AI
> doesn't exhaust its context by reading an overly large file in one go; in that case switch to `start_line`/`end_line`
> to read the range you need.
> The threshold and upper limit are configurable via `tools.read_file`.

### 🌳 Code Analysis Tools (Tree-sitter), natively supported by Neovim >= 0.6

| Tool name                 | Description               | Default approval    |
| ---------------------- | ------------------ | ----------- |
| `parse_file`           | Parse a file's syntax tree     | ✅ Auto-allowed |
| `query_tree`           | Query syntax tree nodes     | ✅ Auto-allowed |
| `get_node_at_position` | Get the node at a given position   | ✅ Auto-allowed |
| `get_node_type`        | Get a node's type       | ✅ Auto-allowed |
| `get_node_range`       | Get a node's range       | ✅ Auto-allowed |
| `is_named_node`        | Check whether it is a named node | ✅ Auto-allowed |
| `get_parent_node`      | Get the parent node         | ✅ Auto-allowed |
| `get_child_nodes`      | Get the list of child nodes     | ✅ Auto-allowed |
| `get_node_code`        | Get a node's source code     | ✅ Auto-allowed |
| `delete_node`          | Delete a syntax tree node     | ❌ Needs approval   |

### 🔧 LSP Tools, natively supported by Neovim >= 0.12

| Tool name                  | Description                | Default approval    |
| ----------------------- | ------------------- | ----------- |
| `lsp_hover`             | Get hover information        | ✅ Auto-allowed |
| `lsp_definition`        | Get the definition location        | ✅ Auto-allowed |
| `lsp_references`        | Get reference locations        | ✅ Auto-allowed |
| `lsp_implementation`    | Get the implementation location        | ✅ Auto-allowed |
| `lsp_declaration`       | Get the declaration location        | ✅ Auto-allowed |
| `lsp_document_symbols`  | Get document symbols        | ✅ Auto-allowed |
| `lsp_workspace_symbols` | Search workspace symbols      | ✅ Auto-allowed |
| `lsp_code_action`       | Get code action suggestions    | ✅ Auto-allowed |
| `lsp_rename`            | Rename symbol          | ❌ Needs approval   |
| `lsp_format`            | Format code          | ❌ Needs approval   |
| `lsp_diagnostics`       | Get diagnostics        | ✅ Auto-allowed |
| `lsp_client_info`       | Get LSP client information | ✅ Auto-allowed |
| `lsp_signature_help`    | Get the function signature        | ✅ Auto-allowed |
| `lsp_completion`        | Get completion suggestions        | ✅ Auto-allowed |
| `lsp_type_definition`   | Get type definitions        | ✅ Auto-allowed |
| `lsp_service_info`      | Get LSP service information   | ✅ Auto-allowed |

### 💻 Shell Tools — interactive shells are filled in automatically by the AI

| Tool name        | Description               | Default approval                    |
| ------------- | ------------------ | --------------------------- |
| `run_command` | Execute a Shell command (non-interactive, asynchronous jobstart) | ❌ Needs approval (supports an argument allowlist of `ls`/`wc`/`find`/`grep`/`pwd`) |

### 🔄 Git Tools

| Tool name                  | Description                     | Default approval    |
| ----------------------- | ------------------------ | ----------- |
| `git_status`            | View git status (--short) | ✅ Auto-allowed |
| `git_diff`              | View uncommitted changes           | ✅ Auto-allowed |
| `git_log`               | View commit history             | ✅ Auto-allowed |
| `git_commit_detail`     | View the details of a given commit         | ✅ Auto-allowed |
| `git_branch`            | View the branch list (-a)       | ✅ Auto-allowed |
| `git_file_history`      | View a file's history             | ✅ Auto-allowed |
| `git_rollback`          | Roll a file back to a given commit       | ❌ Needs approval   |
| `git_auto_commit_config`| View/set the auto-commit configuration    | ✅ Auto-allowed |

### 🤖 Sub-Agent Tools

| Tool name                 | Description                                                      | Default approval    |
| ---------------------- | --------------------------------------------------------- | ----------- |
| `create_sub_agent`     | Create a sub-agent to run a subtask (supports `foreground` to wait for the result in the foreground; `mode` optional, `boundaries` optional constraints) | ❌ Needs approval   |
| `wait_sub_agent`       | Wait for a sub-agent to finish and return the complete result (returns immediately if already finished)     | ❌ Needs approval   |
| `get_sub_agent_status` | Query a sub-agent's status and result                                   | ✅ Auto-allowed |
| `cancel_sub_agent`     | Cancel a sub-agent                                              | ✅ Auto-allowed |

### 📋 Todos and Plans

| Tool name            | Description                                           | Default approval    |
| ----------------- | ---------------------------------------------- | ----------- |
| `todo_write`      | Replace the whole task list (with an auto-injected system prompt)           | ✅ Auto-allowed |
| `todo_read`       | Read the current task list                               | ✅ Auto-allowed |
| `todo_clear`      | Clear the task list                                   | ✅ Auto-allowed |
| `enter_plan_mode` | Enter plan mode (the tool context switches to read-only/informational + questions)| ✅ Auto-allowed |
| `exit_plan_mode`  | After user confirmation, parse the plan into todos and switch to CHAT execution      | ⚠️ Needs approval   |

### 💬 Asking the User

| Tool name     | Description                                     | Default approval    |
| ---------- | ---------------------------------------- | ----------- |
| `ask_user` | Pause generation and ask the user a question; the answer is returned as the tool result | ✅ Auto-allowed |

> **PLAN MODE**: while active, the tool context **contains only read-only/informational query tools, `ask_user`, and `exit_plan_mode`**,
> and exposes no mutating tools whatsoever (edit/delete/create/write commands/git rollback, etc.); execution-time
> gating is tightened accordingly, and any tool outside the visible set is rejected. In this mode the AI investigates,
> asks clarifying questions,
> and produces a **clear, well-formatted change plan** (goals and background / list of changes / implementation steps / verification and rollback).
> Once the plan is complete, the AI calls `exit_plan_mode` (an approval window pops up for the user to confirm);
> after the user confirms, it **switches directly to CHAT mode**, the system parses the plan into a task list (todos),
> and execution starts automatically according to `tools.plan_mode.auto_execute_on_approve` (on by default).
> You can also run `:NeoAIApprovePlan` manually to perform the same confirmation.
> During generation, switching modes via `m` / `:NeoAIPlan` / `:NeoAIAuto` is **deferred until the current turn ends**,
> so an in-progress generation is never interrupted by a mid-flight change to the toolset / system policy / model.

### 🪵 Logging Tools

| Tool name           | Description             | Default approval    |
| ---------------- | ---------------- | ----------- |
| `log_message`    | Log a message     | ✅ Auto-allowed |
| `get_log_levels` | Get the available log levels | ✅ Auto-allowed |

### 🔌 MCP Tools (remote servers, enabled on demand)

Servers configured under `mcp.servers.<name>` register their capabilities as tools named `mcp__<server>__<tool>`.
Remote `tools/list` → one NeoAI tool per remote tool; `resources`/`prompts` → one browsing tool per server each.

| Tool name (example, `server` = config name) | Description | Default approval |
| ------------------------------ | ---- | -------- |
| `mcp__<server>__<remote-tool>`   | Call a remote tool on the MCP server | ❌ Needs approval (`approval.auto_allow`) |
| `mcp__<server>__list_resources` | List server resources (read-only) | ✅ Auto-allowed |
| `mcp__<server>__read_resource`  | Read a given resource (read-only) | ❌ Needs approval |
| `mcp__<server>__list_prompts`   | List prompt templates (read-only) | ✅ Auto-allowed |
| `mcp__<server>__get_prompt`     | Get the content of a prompt template | ❌ Needs approval |

> **Tool timing**: at startup, tools are registered from the `mcp_cache.json` pre-cache (visible before connecting); they
> are refreshed dynamically after connect/change notifications;
> if a remote call fails because the argument schema changed, the tool is marked stale, and before the next round it is
> refreshed automatically and the tool definition is rebound
> (the model retries with the latest schema). See [docs/en/mcp.md](docs/en/mcp.md).

### 🧩 Skill Tools (Skills)

| Tool name         | Description                           | Default approval    |
| -------------- | ------------------------------ | ----------- |
| `list_skills`  | List the available skills                   | ✅ Auto-allowed |
| `load_skill`   | Load a skill's body text into the model (SKILL.md)| ✅ Auto-allowed |

> The system prompt injects the list of "available skills" (`skills.inject_mode`), and the model can `load_skill` to load the body text.
> See [docs/en/skills.md](docs/en/skills.md).

---
## 🏗️ Architecture

Built on the v3.0 architecture guide (see [styleGuide.md](styleGuide.en.md)), following the **isolation, simplicity, async-first** design philosophy.

```
NeoAI/
├── init.lua                    # Main entry: extremely thin, only setup + command/keymap registration, business logic lazy-loaded
├── default_config.lua          # Default config (pure data, zero logic)
│
├── kernel/                     # Kernel layer (lowest level, zero business dependencies)
│   ├── events.lua             # Event constant registry (domain:verb naming)
│   ├── event_bus.lua          # Event bus (publish/subscribe)
│   ├── config_store.lua       # Config store (merge + validate + get + watch)
│   ├── logger.lua             # Leveled logging (file output + rotation)
│   └── lifecycle.lua          # Lifecycle (bootstrap/shutdown)
│
├── core/                       # Core business layer
│   ├── session/               # Session management
│   │   ├── session.lua        # Session object (pure data + fork branch)
│   │   ├── session_store.lua  # Session persistence (append-only JSONL + torn-line repair)
│   │   ├── context_builder.lua# Context building (system rendering + tool call protocol)
│   │   ├── tool_result_pruner.lua # Tool result pruning (head summary / marker / tail pruning)
│   │   ├── compactor.lua      # Context compaction (pairing-safe splitting + checkpoint replacement + auxiliary summary)
│   │   ├── plan_distill.lua   # Plan-phase distillation (research context → 8-part checkpoint)
│   │   └── runtime_context.lua# Runtime context (environment/time injection, etc.)
│   ├── model/                 # Model management
│   │   ├── registry.lua       # Model registry (runtime dynamic updates + live metadata)
│   │   ├── fetcher.lua        # Async model list fetcher (exponential backoff retry)
│   │   ├── adapter.lua        # Protocol encoding/decoding (openai/anthropic/google)
│   │   ├── profiles.lua       # Vendor/model dialects (parameter names / reasoning shape / auth headers)
│   │   ├── capabilities.lua   # Model capability table (window/output/caching mechanism/char coefficients)
│   │   ├── prompt_cache.lua   # Explicit caching (Anthropic breakpoints / OpenAI explicit / Gemini cachedContents)
│   │   ├── content.lua        # Multimodal message materialization (image reference → protocol-neutral block)
│   │   └── cache.lua          # Local model list cache
│   ├── attachment/            # Attachments (multimodal images)
│   │   └── attachment.lua     # Content-addressed attachment store + gating (vision support/type/limit)
│   └── agent/                 # Agent engine
│       ├── agent.lua          # Agent object (fresh instance per conversation + AbortSignal)
│       ├── runtime.lua        # Agent runtime (create/spawn/dispose/abort)
│       ├── request.lua        # Request building + sending + retry
│       ├── stream.lua         # Streaming response handling (SSE parsing + tool argument accumulation)
│       ├── tool_loop.lua      # Tool call loop
│       ├── prefix.lua         # Prefix cache identity consistency (ordered system prompt segments + tool canonical ordering)
│       ├── guard.lua          # Tool loop guard (consecutive repeated call reminders)
│       └── recovery.lua       # Context overflow recovery (resend after compaction)
│
├── services/                   # Service layer (connects core with ui/tools)
│   ├── chat_service.lua       # Chat service (send/attach/detach/approve_plan/cycle_mode)
│   ├── tool_service.lua       # Tool service (approval + scheduling + execution, serial approval queue)
│   ├── model_service.lua      # Model service (list/set_active/prefetch)
│   ├── status.lua             # Statusline service (lualine integration, segment composition + highlighting)
│   ├── herder.lua             # Herder terminal status reporting (working/idle/blocked)
│   ├── skills.lua             # Skills service (SKILL.md scanning + frontmatter parsing + indexing)
│   └── mcp/                   # MCP service (client + transport + cache + tool bridge)
│       ├── client.lua         # JSON-RPC 2.0 client (id correlation/timeout/notification/cancel)
│       ├── transports.lua     # Transport layer (stdio / Streamable HTTP)
│       ├── cache.lua          # Tool/resource/prompt pre-caching + pending/stale states
│       └── init.lua           # Manager (connect/register/dynamic refresh/failure-driven stale)
│
├── ui/                         # Presentation layer
│   ├── init.lua               # UI entry (registers approval/ask/sub-agent UI; open_*/close_all)
│   ├── window/                # Window management (float/tab/split)
│   │   ├── manager.lua        # Window manager
│   │   ├── chat_view.lua      # Chat view (events/streaming/folding/floating window/display mode host)
│   │   └── tree_view.lua      # Session tree view
│   ├── components/            # Reusable components
│   │   ├── input_box.lua      # Input box
│   │   ├── message_list.lua   # Message list rendering
│   │   ├── reasoning_panel.lua# Reasoning panel
│   │   ├── tool_args_panel.lua# Tool argument receiving floating window (streaming)
│   │   ├── float_stream_window.lua # Reusable streaming floating window (shared by reasoning/arguments/compaction/distillation)
│   │   ├── model_picker.lua   # Model picker (async loading)
│   │   ├── tool_approval.lua  # Tool approval dialog
│   │   ├── ask_user.lua       # Ask-user dialog
│   │   ├── sub_agent_dock.lua # Sub-agent monitoring
│   │   ├── fold.lua           # Folding (shared by reasoning/tool calls/results)
│   │   ├── display_modes/     # Display mode plugins (chat/trajectory)
│   │   └── markdown_view.lua  # Markdown renderer
│   └── keymap.lua             # Keymaps (centrally managed)
│
├── tools/                      # Tool system
│   ├── init.lua               # Tool system entry (init/get_tools/execute/reload_tools)
│   ├── registry.lua           # Tool registry
│   ├── executor.lua           # Tool executor (aliases/approval/timeout)
│   ├── validator.lua          # Argument validation + approval decisions
│   ├── packer.lua             # Tool grouping/packing
│   ├── environment.lua        # Tool environment probing (workspace/git, disabled if unavailable)
│   └── builtin/               # Built-in tools
│       ├── file_ops.lua       # File operations + confirm_file_change
│       ├── shell.lua          # Shell commands
│       ├── git_ops.lua        # Git operations
│       ├── lsp_ops.lua        # LSP tools
│       ├── tree_ops.lua       # Tree-sitter tools
│       ├── log_ops.lua        # Log tools
│       ├── plan.lua           # Sub-agent + boundary review
│       ├── todo.lua           # Todo list (todo_write/read/clear + prompt segment)
│       ├── plan_mode.lua      # Plan mode (enter_plan_mode/exit_plan_mode + tool filtering/gating)
│       ├── ask_user.lua       # Ask the user
│       ├── read_image.lua     # Image reading (multimodal)
│       ├── skills.lua         # Skills tools (list_skills/load_skill + prompt segment)
│       └── tool_helpers.lua   # Tool definition helpers
│
├── utils/                      # Pure utility library (zero business dependencies)
│   ├── async.lua             # Promise/Deferred/AbortSignal/retry
│   ├── json.lua              # JSON encoding/decoding
│   ├── http.lua              # Async HTTP client (curl jobstart, streaming SSE)
│   ├── fs.lua                # File operations (JSONL)
│   ├── work.lua              # Thread pool (blocking file I/O / image decoding run on the thread pool)
│   ├── timer.lua             # Pausable timer (tool active time, excluding waiting time)
│   ├── image.lua             # Image type detection/media type
│   └── stringx.lua           # String extensions
│
└── tests/                      # Tests (custom runner, :NeoAITest; 44 test_*.lua files total)
    ├── init.lua               # Assertions + runner
    ├── test_kernel.lua        # Kernel (config_store/event_bus/events/lifecycle)
    ├── test_session.lua       # Session (session/store/context_builder/compactor)
    ├── test_tool_result_pruner.lua # Tool result pruning
    ├── test_agent.lua         # Agent (agent/runtime)
    ├── test_guard.lua         # Tool loop guard
    ├── test_overflow.lua      # Context overflow recovery (pairing-safe splitting + pruning)
    ├── test_cache_strategy.lua# Prefix caching strategy
    ├── test_cache_usage.lua   # Cache hit usage statistics
    ├── test_prompt_cache.lua  # Explicit caching
    ├── test_model_registry.lua# Model registry
    ├── test_model_capabilities.lua # Model capability table
    ├── test_model_profiles.lua# Vendor/model dialects
    ├── test_model_metadata.lua# Live model metadata
    ├── test_protocol_adapter.lua # Protocol encoding/decoding
    ├── test_model_picker.lua  # Model picker
    ├── test_modes.lua         # Modes (CHAT/PLAN/AUTO)
    ├── test_multimodal.lua    # Multimodal images
    ├── test_runtime_context.lua # Runtime context
    ├── test_tools.lua         # Tool system
    ├── test_tool_pending.lua  # Tool pending/staging
    ├── test_pending_queue.lua # Pending message queue
    ├── test_services.lua      # Service layer (chat/tool/model/status)
    ├── test_status.lua        # Statusline service
    ├── test_herder.lua        # Herder status reporting
    ├── test_ask_user.lua      # Ask the user
    ├── test_plan_mode.lua     # Plan mode
    ├── test_plan_distill.lua  # Plan distillation
    ├── test_todo.lua          # Todo list
    ├── test_sub_agent_result.lua # Sub-agent results
    ├── test_skills.lua        # Skills (frontmatter/discovery/loading)
    ├── test_mcp_client.lua    # MCP JSON-RPC client
    ├── test_mcp_transport.lua # MCP transport layer (stdio/HTTP)
    ├── test_mcp_bridge.lua    # MCP manager bridge (init→register→invoke)
    ├── test_chat_ui.lua       # Chat UI
    ├── test_tree_ui.lua       # Session tree UI
    ├── test_chat_keys.lua     # Chat keymaps
    ├── test_display_modes.lua # Display mode plugins
    ├── test_fold.lua          # Folding
    ├── test_markdown.lua      # Markdown rendering
    ├── test_timer.lua         # Pausable timer
    ├── test_http.lua          # HTTP client
    └── test_integration.lua   # Integration tests (mock server)
```

### Design Highlights

- **Environment isolation**: Each time a chat window is opened → a brand-new Agent instance (empty message queue + independent AbortSignal), zero residue
- **Sub-agent sandbox**: `runtime.spawn()` creates a completely fresh environment, inheriting none of the parent Agent's messages/state
- **Unidirectional dependencies**: `utils → kernel → core → services → ui/tools`, no cross-layer penetration allowed
- **Async-first**: All I/O is asynchronous, startup does not block Neovim, model lists are fetched in the background
- **Cancellation signals**: AbortSignal cascading propagation (HTTP requests + tool calls), replacing global flags
- **Event-driven**: `event_bus` publishes/subscribes on top of nvim autocmd, with event names in the form `domain:verb`

---

## 📡 Event System

NeoAI implements an event-driven architecture on top of Neovim's native `User` autocmd. Event constants are defined in the `NeoAI.kernel.events` module (the event bus is `NeoAI.kernel.event_bus`, and the `NeoAI:` prefix is added automatically when triggered). Statistics by partition are as follows:

| Event Partition      | Count | Description                        |
| -------------------- | ----- | ---------------------------------- |
| Agent lifecycle      | 5     | Create, spawn, dispose, abort, state change |
| Generation/streaming | 8     | Generation start, complete, error, cancel, streaming |
| Reasoning            | 3     | Reasoning start, content arrival, complete |
| Message              | 7     | Add, update, edit, delete, send, enqueue, clear |
| Session              | 7     | Create, load, save, delete, switch, rename, branch |
| Branch/tree          | 3     | Branch create, delete, tree refresh |
| Tool                 | 13    | Tool loop, execution, approval, call detection, guard |
| Ask user             | 2     | Waiting for user answer start, answer/cancel end |
| Tool argument receiving | 2  | `tool:arg_chunk` / `tool:arg_completed` |
| Todo/plan mode       | 2     | Todo update, plan mode change      |
| Model                | 4     | Model update, switch, refresh start, refresh failure |
| UI/window            | 5     | Open, close, refresh, mode, display mode |
| Sub-agent            | 5     | Create, update, complete, error, result ready |
| Config/lifecycle     | 4     | Config load, change, initialization, shutdown |
| MCP                  | 5     | Connect, ready, error, disconnect, tool update |
| Skills               | 1     | Skill index hot reload             |
| Logging/context compaction | 4 | Log message, compaction start, compaction chunk, compaction complete |
| Plan distillation    | 3     | Distillation start, chunk arrival, complete |

See [docs/EVENTS.md](docs/en/EVENTS.md) for details (the single authoritative event document).

---

## 🧪 Testing

Run all tests:

```vim
:NeoAITest
```

Run specific tests:

```vim
:NeoAITest flow_config flow_tools
```

---

## 📄 Related Documentation

| Document                                                                   | Description      |
| -------------------------------------------------------------------------- | ---------------- |
| [styleGuide.en.md](styleGuide.en.md)                                       | Architecture design guide |
| [docs/EVENTS.md](docs/en/EVENTS.md)                                           | Event system documentation (sole authority) |
| [docs/overview.md](docs/en/overview.md)                                       | Plugin overview  |
| [docs/ai_engine.md](docs/en/ai_engine.md)                                     | Agent engine     |
| [docs/model_policy.md](docs/en/model_policy.md)                               | Automatic per-model selection (protocol dialects/capability table/explicit caching) |
| [docs/tool_system.md](docs/en/tool_system.md)                                 | Tool system      |
| [docs/ui_system.md](docs/en/ui_system.md)                                     | UI system        |
| [docs/sub_agent_system.md](docs/en/sub_agent_system.md)                       | Sub-agent system |
| [docs/history_manager.md](docs/en/history_manager.md)                         | Session system (branch/persistence/compaction) |
| [docs/configuration.md](docs/en/configuration.md)                             | Configuration system |
| [docs/chat_enhanced_usage.md](docs/en/chat_enhanced_usage.md)                 | Enhanced chat usage guide |
| [docs/mcp.md](docs/en/mcp.md)                                                 | MCP support (transport/tools/timing) |
| [docs/skills.md](docs/en/skills.md)                                           | Skills support (SKILL.md + load_skill) |
| [docs/utils.md](docs/en/utils.md)                                             | Utils library (async/http/fs/work/timer) |
| [docs/shutdown_flow.md](docs/en/shutdown_flow.md)                             | Lifecycle and shutdown flow |
| [docs/testing.md](docs/en/testing.md)                                         | Testing guide    |
| [README.md](README.md)                                                        | Chinese versions of all the above (中文版) |

---

## 🔧 Development

### Adding a New Tool

1. Create a new file under `tools/builtin/`
2. Define the tool using the `define_tool` helper
3. Implement the `get_tools()` function to return the list of tool definitions
4. Restart Neovim or call `:lua require("NeoAI.tools").reload_tools()`

### Adding a New AI Provider

1. Add the new provider under `ai.providers` in the config
2. If it uses a special API format, register an adapter in `core/model/adapter.lua`

### Running Tests

```vim
:NeoAITest           " run all tests
:NeoAITest flow_tools  " run specific tests
```

---

## 📝 License

[MIT](LICENSE)
