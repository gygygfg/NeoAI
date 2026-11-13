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
     freezes candidates, with real changes queued for confirmation via `:NeoAI SandboxReview`; only
     `prompt`/`strict` use the serial single-slot approval dialog (auto-allow config, per-tool
     permission overrides, approval timeout)
   - Sandbox risk levels: L0-L3 map to auto/record/review/block, default `review` (pending review)
   - Plan mode: read-only/info tools + ask_user only; mutating tools gated
   - Plan distillation: on approve, distill plan-phase research context into a
     checkpoint replacing compaction
   - Guard: repetitive tool-call reminder (observe-and-enrich)
   - Environment probing: tools depending on unavailable workspace/git disabled

6. Sub-Agent System
   - Create sub-agents via `sub_agent.create()` → `runtime.spawn()` (fresh environment, zero inheritance + persistent child session)
   - Boundary enforcement (allowed tools, directories, commands, max_tool_calls); sub-agents get no dispatch tools
   - Independent tool loops per sub-agent
   - No wait tool: when the loop ends naturally the final body is delivered back to the main agent (auto-wake when idle)
   - Winbar shows sub-agent names (collapsed to `N个子agent正在运行` when too wide); `switch_sub_agent` opens one in a new window
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
    live_metrics.lua         -- Live metrics bridge (core→ui)
    ui_hooks.lua             -- UI hook registry (ui↔tools)
    llm_bridge.lua           -- LLM send bridge (sandbox→core)
    sandbox_bridge.lua       -- Sandbox capability bridge (core→sandbox)
    core_bridge.lua          -- Core capability bridge (tools→core)
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
  tests/                     -- Test suite (:NeoAI Test)
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

**Prerequisites**: Neovim >= 0.10 (0.13+ recommended; uses the `vim.uv` multithreading API) and
`curl` (the only HTTP transport — without it no model request can be sent). Optional dependencies by
feature: `git`, `node`/`npm` (`web_fetch`), and sandbox-related ones (`bwrap` (bubblewrap) or
`unshare` + unprivileged user namespaces; seccomp needs `setpriv --seccomp-filter` from
`util-linux` >= 2.32; observation uses `bpftrace`/`strace`; the container facade uses `podman` only).
When none of the isolation backends is available the sandbox is disabled and falls back to approval
mode. The full list (per-distro install commands and the Android/Termux limitation) is in
[README "Prerequisites (dependencies)"](../README.en.md#-prerequisites-dependencies). After
installing, run `:NeoAI Doctor` or `:checkhealth NeoAI` for a one-stop self-check.

Using lazy.nvim:

```lua
{
  "gygygfg/NeoAI",
  config = function()
    require("NeoAI").setup()
  end
}
```

### Configure the API Key

Set at least one provider's key in an environment variable:

```bash
export DEEPSEEK_API_KEY="your-api-key"   # or OPENAI_API_KEY / ANTHROPIC_API_KEY / ...
```

```lua
require("NeoAI").setup({
  ai = {
    default_provider = "deepseek",
    providers = { deepseek = { api_key = os.getenv("DEEPSEEK_API_KEY") } },
  },
})
```

> A one-time hint is shown at startup when no key is configured; `ai.auto_select_provider = true`
> auto-falls back to a configured provider when the default one has no key.

> **Startup model (lazy by default, no configuration)**: `setup()` only loads the config,
> bootstraps the kernel, registers plugins, and installs placeholders for the aggregated
> `:NeoAI <subcommand>` command and global keymaps. The first trigger drives a **two-phase asynchronous start**
> via `NeoAI.ensure_phase1/ensure_started`: phase 1 (session/agent/model/chat/status/ui) opens
> the interface as soon as it is ready; phase 2 (tools/sandbox/tool_service/skills/mcp/herder
> and all `tool.*`) loads in the background frame-by-frame (`kernel.plugins.start_list_async`)
> without blocking the event loop. Read-only accessors never trigger startup.

## Quick Start

Basic usage:

```vim
:NeoAI Open          " Open default UI (configured in ui.default_view)
:NeoAI Chat          " Open chat interface
:NeoAI Tree          " Open tree interface
:NeoAI Close         " Close all NeoAI windows
:NeoAI Keymaps       " Show current keymap configuration
:NeoAI Test          " Run tests (optionally pass test names)
:NeoAI ChatStatus    " Show chat window status
:NeoAI CycleDisplay  " Cycle display mode (chat / trajectory)
:NeoAI ReloadDisplay " Hot-reload display mode plugin
:NeoAI Plan          " Toggle plan mode
:NeoAI ApprovePlan   " Approve plan and switch to CHAT mode
:NeoAI Statusline    " Preview the lualine statusline component content
```

## Herder Terminal State Integration

NeoAI reports the real Agent lifecycle state (`working` / `idle` / `blocked`) to
Herder within Herder-managed panes, so Herder's sidebar can reflect Agent status in
real time instead of inferring it from screen output. This integration is
**signal-generation only** — it translates NeoAI's Agent lifecycle into Herder semantics
and reports it; the Herder-side recognition/parsing is handled by Herder itself.

**Requirements** (all must hold):

1. Running inside a Herder-injected pane (env `HERDR_ENV=1`, `HERDR_PANE_ID`; the `herdr` binary is resolved from `HERDER_BIN_PATH`/`HERDR_BIN_PATH`, falling back to `herdr` on PATH);
2. `herder.enabled = true` (default).

Outside a Herder environment the module is a strict no-op: it subscribes to no events and
has no side effects.

**Recognition**: Herdr's agent identities are a compile-time fixed set, and a local detection manifest can only
**override an existing** agent, never add a new one; NeoAI therefore uses Herdr's **proactive reporting** channel
(`pane report-agent` / `pane report-metadata`). On authority takeover it also sends one `report-metadata`, so the
sidebar shows `display_agent = "NeoAI"` with localized state labels.

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
the same `source` and avoids concurrent/async rollback. The seq is seeded from the wall clock
(microseconds) rather than restarted at 1, so after a plugin hot-reload or reopening nvim in the
same pane the sequence never regresses (otherwise Herder would drop the new reports as stale).

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
    display_agent = 'NeoAI',  -- sidebar/border display name (report-metadata)
    report_metadata = true,   -- report display metadata on authority takeover
    auto_install = true,      -- auto-install the display-enhancement snippet on startup inside Herder (async/silent/idempotent)
    state_labels = { working = '生成中', blocked = '等待确认', idle = '就绪' }, -- false = no override
    title = nil,              -- optional display title
  },
})
```

> Diagnostics: inside a Herder pane, run `herdr agent explain <pane-id>` to inspect the
> current Agent state source and recent reports.

## Commands

| Command | Description |
| --- | --- |
| `:NeoAI Open` | Open default UI (configured in `ui.default_view`: chat or tree) |
| `:NeoAI Chat` | Open chat interface directly |
| `:NeoAI Tree` | Open tree interface directly |
| `:NeoAI Close` | Close all NeoAI windows |
| `:NeoAI Keymaps` | Display current keymap configuration in floating window |
| `:NeoAI Test [names...]` | Run tests (all, or specific by name) |
| `:NeoAI ChatStatus` | Show chat window status |
| `:NeoAI CycleDisplay` | Cycle chat display mode (chat / trajectory) |
| `:NeoAI WindowMode [tab\|float\|split]` | Switch the window mode of the **current chat window**: only that window is rebuilt (config untouched, later windows still follow `ui.window_mode`); it also works while the Agent is generating or running tools (the Agent is preserved, so the current turn continues); no arg prints the current mode |
| `:NeoAI Compact` | Manually compact the current session context (ignores the pressure threshold, keeps the latest round) |
| `:NeoAI ReloadDisplay [name]` | Hot-reload a display mode plugin |
| `:NeoAI Plan` | Toggle plan mode (read-only/info tools + ask_user) |
| `:NeoAI ApprovePlan` | Approve plan, switch to CHAT, execute task list |
| `:NeoAI ReloadAll` | Hot-reload the whole NeoAI plugin (isolated subprocess pre-check first; cancel on failure) |
| `:NeoAI SandboxReview` | List and apply pending sandbox changes (highlighted by path level) |
| `:NeoAI SandboxCommit` | Apply a sandbox candidate to the real workspace (CAS publish; arg = candidate digest) |
| `:NeoAI SandboxDiscard` | Discard a sandbox candidate |
| `:NeoAI SandboxList` / `:NeoAI SandboxShow` | List / inspect pending sandbox candidates |
| `:NeoAI SandboxCaps` / `:NeoAI SandboxDiag` | Sandbox runtime capability probe / resource-domain load diagnostics (137/OOM attribution) |
| `:NeoAI SandboxApprove` / `:NeoAI SandboxReject` | Approve (no apply) / reject & discard a change set |
| `:NeoAI SandboxApply` / `:NeoAI SandboxApplyAll` | Approve and apply one / all pending change sets |
| `:NeoAI SandboxGrant` / `:NeoAI SandboxRevoke` | Create a narrow task grant / revoke a grant |
| `:NeoAI SandboxPrune` / `:NeoAI SandboxMetrics` | Prune expired candidates by retention / show sandbox metrics |
| `:NeoAI SandboxPublish` / `:NeoAI SandboxReplay` | Publish multiple change sets together / replay a recorded policy decision |
| `:NeoAI SandboxAudit` / `:NeoAI SandboxAutoApprove` | Sandbox behavior audit & risk assessment / set auto-approval for new sessions (off by default) |
| `:NeoAI HerderStatus` | Show Herder integration status |
| `:NeoAI HerderConfig [show\|install\|uninstall]` | View / install / uninstall the Herder display-enhancement config snippet |
| `:NeoAI Statusline` | Preview the lualine statusline component content |
