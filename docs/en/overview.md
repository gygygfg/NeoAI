# NeoAI Plugin Overview

> [中文](../overview.md) | **English**

NeoAI is an AI-powered chat plugin for Neovim that integrates AI assistants
directly into your editor. It features a dual-UI design (tree + chat),
multi-provider AI support, a comprehensive tool execution system, sub-agent
decomposition, and session history with branching.

The plugin is built on the v3.0 architecture described in styleGuide.md,
following the principles of isolation (each conversation gets a fresh Agent
instance), unidirectional dependency (utils → kernel → core → services → ui),
and async-by-default (all I/O non-blocking).

## Core Features

1. Dual UI Modes
   - Tree UI: Session tree with branching, expand/collapse, CRUD operations
   - Chat UI: AI conversation with streaming, reasoning display, tool display

2. Multi-Provider AI
   - DeepSeek, OpenAI, Anthropic, Google, Groq, Together, OpenRouter
   - Chinese providers: SiliconFlow, Moonshot, Zhipu, Baidu, Aliyun, StepFun
   - Scenario-based model selection (chat, code, reasoning, agent)

3. Model-Aware Policy (capabilities / profiles / prompt cache)
   - Protocol families: OpenAI / Anthropic / Gemini wire encoding
   - Vendor dialects: max_tokens / max_completion_tokens, reasoning_effort /
     thinking / enable_thinking, auth headers, usage fields
   - Capability table: context window, max output, cache kind, chars-per-token
     (live `/models` metadata preferred over built-in table)
   - Explicit cache (Anthropic breakpoints / OpenAI explicit / Gemini
     cachedContents), silent fallback to implicit; unknown models fall back safely
   - See docs/model_policy.md

4. Streaming Generation
   - Real-time content display
   - Reasoning content display (e.g., DeepSeek reasoning_content)
   - Tool-call argument streaming (tool_args_panel receives args live)
   - Cancel generation via AbortSignal

5. Tool System
   - Built-in tools: file ops, LSP, treesitter, shell, git, logging, todo,
     plan_mode, ask_user, read_image, web_fetch (disabled by default), sub-agent, skills
   - Tool approval workflow: the default `mode="async"` runs the tool in the sandbox immediately and
     freezes candidates, with real changes queued for confirmation via `:NeoAISandboxReview`; only
     `prompt`/`strict` use the serial single-slot approval dialog (auto-allow config, per-tool
     permission overrides, approval timeout)
   - Sandbox risk levels: L0-L3 map to auto/record/review/block, default `review` (pending review)
   - Plan mode: read-only/info tools + ask_user only; mutating tools gated
   - Plan distillation: on approve, distill plan-phase research context into a
     checkpoint replacing compaction
   - Guard: repetitive tool-call reminder (observe-and-enrich)
   - Environment probing: tools depending on unavailable workspace/git disabled

6. Sub-Agent System
   - Create sub-agents via `runtime.spawn()` (fresh environment, zero inheritance)
   - Boundary enforcement (allowed tools, directories, commands, max_tool_calls)
   - Independent tool loops per sub-agent
   - `foreground` mode: wait for complete result
   - Sub-agent dock UI monitors status

7. Session History
   - Branching session tree (fork)
   - Append-style JSONL persistence with `.bak` backup + torn-line repair
   - Streaming context compaction with prefix-cache-friendly checkpoint replacement
     (live reasoning + content shown in a floating window)
   - Reasoning content NOT fed back to history (keeps prefix cache stable)

8. Graceful Shutdown
   - `kernel/lifecycle`: bootstrap / on_shutdown / shutdown
   - AbortSignal cascading cancel (HTTP + tools)
   - Sync save on `VimLeavePre` (registered in lifecycle)

9. Herder Terminal State Reporting
   - Report Agent lifecycle state (working/idle/blocked) to Herder
   - Strict no-op outside a Herder environment (HERDR_ENV=1 guard)
   - Multi-session/sub-agent aggregation into one lifecycle authority
   - Strictly increasing --seq for concurrent/safe reporting

10. lualine Statusline Integration
   - Real-time usage/cache/capacity display in the chat window
   - winbar as a second line (mode/model/state)
   - Configurable parts + bright highlight groups

11. Tool Argument Receive Panel
   - Live floating window showing streaming tool-call arguments
   - Opens on `TOOL_ARG_CHUNK`, closes on `TOOL_ARG_COMPLETED`
   - Same UX as the reasoning panel; suppressed when cursor not following

12. MCP Support (client)
   - Connect external MCP servers over stdio / Streamable HTTP
   - Register remote tools / resources / prompts into the tool system
   - Pre-cache on startup + failure-driven dynamic refresh

13. Skills Support
   - Scan SKILL.md directories, inject the skill index into the system prompt
   - Model loads a skill body on demand via `load_skill`

14. Pending Message Queue
   - Messages sent while the Agent is busy are queued
   - `待发N` ("N pending") badge in the statusline; clears once actually sent

## Architecture Overview

Project structure:

```text
lua/NeoAI/
  init.lua                   -- Main module: setup, commands, keymaps
  default_config.lua         -- Default configuration (pure data)
  kernel/                    -- Kernel layer (no business deps)
    init.lua
    events.lua
    event_bus.lua
    config_store.lua
    logger.lua
    lifecycle.lua
  core/                      -- Core business layer
    session/                 -- Session (object, JSONL store, context builder, compactor,
                             -- plan_distill, runtime_context)
    model/                   -- Model (registry, fetcher, adapter, profiles, capabilities,
                             -- prompt_cache, content, cache)
    attachment/              -- Attachment (image content-addressed store)
    agent/                   -- Agent engine (agent, runtime, request, stream, tool_loop,
                             -- prefix, guard, recovery)
  services/                  -- Service layer (chat, tool, model, status, herder, skills, mcp/*)
  ui/                        -- Presentation layer
    init.lua                 -- Registers approval/ask_user/sub-agent dock UI
    window/                  -- Window manager, chat view, tree view
    components/              -- input_box, message_list, reasoning_panel, tool_args_panel,
                             -- float_stream_window, model_picker, tool_approval, ask_user,
                             -- sub_agent_dock, fold, display_modes, markdown_view
    keymap.lua               -- Unified keymap management
  tools/                     -- Tool system
    init.lua
    registry.lua
    executor.lua
    validator.lua
    packer.lua
    environment.lua          -- Tool environment probing (disable unavailable)
    builtin/                 -- file_ops, shell, git_ops, lsp_ops, tree_ops, log_ops,
                             -- plan, todo, plan_mode, ask_user, read_image, skills,
                             -- web_fetch (web fetch, disabled by default), tool_helpers
  utils/                     -- Utilities (async, json, http, fs, work, timer, image, stringx)
  tests/                     -- Test suite (:NeoAITest)
```

Key architectural principles:

- Environment isolation: Each conversation = fresh Agent instance (private
  message queue + independent AbortSignal). Zero state leakage.
- Unidirectional dependency: utils → kernel → core → services → ui/tools
- Async by default: All I/O non-blocking; model lists fetched in background;
  blocking file I/O runs on a thread pool (utils.work)
- Cancellation via AbortSignal: Cascading cancel propagation to HTTP + tools
- Event bus: `domain:verb` event naming over nvim User autocmds (`NeoAI:` prefix)
- Prefix-cache friendly: system prompt built from ordered sections; tool defs
  sorted by name; reasoning not fed back → stable byte identity

## Installation

Using lazy.nvim:

```lua
{
  "gygygfg/NeoAI",
  config = function()
    require("NeoAI").setup()
  end
}
```

> **Startup model (lazy by default, no configuration)**: `setup()` only loads the config,
> bootstraps the kernel, registers plugins, and installs placeholders for all `:NeoAI*`
> commands and global keymaps. The first trigger drives a **two-phase asynchronous start**
> via `NeoAI.ensure_phase1/ensure_started`: phase 1 (session/agent/model/chat/status/ui) opens
> the interface as soon as it is ready; phase 2 (tools/sandbox/tool_service/skills/mcp/herder
> and all `tool.*`) loads in the background frame-by-frame (`kernel.plugins.start_list_async`)
> without blocking the event loop. Read-only accessors never trigger startup.

## Quick Start

Basic usage:

```vim
:NeoAIOpen          " Open default UI (configured in ui.default_view)
:NeoAIChat          " Open chat interface
:NeoAITree          " Open tree interface
:NeoAIClose         " Close all NeoAI windows
:NeoAIKeymaps       " Show current keymap configuration
:NeoAITest          " Run tests (optionally pass test names)
:NeoAIChatStatus    " Show chat window status
:NeoAICycleDisplay  " Cycle display mode (chat / trajectory)
:NeoAIReloadDisplay " Hot-reload display mode plugin
:NeoAIPlan          " Toggle plan mode
:NeoAIApprovePlan   " Approve plan and switch to CHAT mode
:NeoAIStatusline    " Preview the lualine statusline component content
```

## Herder Terminal State Integration

NeoAI reports the real Agent lifecycle state (`working` / `idle` / `blocked`) to
Herder within Herder-managed panes, so Herder's sidebar can reflect Agent status in
real time instead of inferring it from screen output. This integration is
**signal-generation only** — it translates NeoAI's Agent lifecycle into Herder semantics
and reports it; the Herder-side recognition/parsing is handled by Herder itself.

**Requirements** (all must hold):

1. Running inside a Herder-injected pane (env `HERDR_ENV=1`, `HERDR_PANE_ID`, `HERDER_BIN_PATH`);
2. `herder.enabled = true` (default).

Outside a Herder environment the module is a strict no-op: it subscribes to no events and
has no side effects.

**State mapping**:

| NeoAI Agent state | Herder reported |
| ----------------- | --------------- |
| `generating` / `tool_running` | `working` |
| tool approval pending / `ask_user` awaiting reply | `blocked` |
| `idle` / `aborted` / `error` | `idle` |

**Multi-session aggregation**: a single Neovim pane may host several AI sessions
(including sub-agents). NeoAI aggregates them into one fixed `source` (default
`custom:neoai`) and reports a single pane state, with priority `blocked > working > idle`.
Every report carries a strictly increasing `--seq`, so Herder ignores stale packets for
the same `source` and avoids concurrent/async rollback.

**Report flow example**:

```
# User sends a message; Agent starts generating
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state working --seq 1
# Tool approval pending / asking the user for an answer (blocked)
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state blocked --seq 2
# Approval granted; still generating
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state working --seq 3
# Turn completed; waiting for input
herdr pane report-agent w1:p1 --source custom:neoai --agent neoai --state idle --seq 4
# Chat window closed; last Agent disposed (release lifecycle authority)
herdr pane release-agent w1:p1 --source custom:neoai --agent neoai --seq 5
```

**Configuration**:

```lua
require('NeoAI').setup({
  herder = {
    enabled = true,           -- enable reporting (also requires HERDR_ENV=1)
    source = 'custom:neoai',  -- stable, globally unique lifecycle authority identifier
    agent = 'neoai',          -- agent name (recognized by Herder)
  },
})
```

> Diagnostics: inside a Herder pane, run `herdr agent explain <pane-id>` to inspect the
> current Agent state source and recent reports.

## Commands

| Command | Description |
| --- | --- |
| `:NeoAIOpen` | Open default UI (configured in `ui.default_view`: chat or tree) |
| `:NeoAIChat` | Open chat interface directly |
| `:NeoAITree` | Open tree interface directly |
| `:NeoAIClose` | Close all NeoAI windows |
| `:NeoAIKeymaps` | Display current keymap configuration in floating window |
| `:NeoAITest [names...]` | Run tests (all, or specific by name) |
| `:NeoAIChatStatus` | Show chat window status |
| `:NeoAICycleDisplay` | Cycle chat display mode (chat / trajectory) |
| `:NeoAIReloadDisplay [name]` | Hot-reload a display mode plugin |
| `:NeoAIPlan` | Toggle plan mode (read-only/info tools + ask_user) |
| `:NeoAIApprovePlan` | Approve plan, switch to CHAT, execute task list |
| `:NeoAIStatusline` | Preview the lualine statusline component content |
