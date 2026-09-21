# NeoAI Event System (Single Source of Truth)

> [中文](../EVENTS.md) | **English**

> This document is the **single authoritative source** for the NeoAI event system. It merges content
> that was previously spread across three documents: `docs/event_system.md`, `docs/NATIVE_EVENTS.md`,
> and `docs/IMPLEMENTED_EVENTS.md`.

## 1. Overview

NeoAI uses an **event-driven asynchronous architecture**. All modules communicate through the event bus, decoupling the UI from business logic.

- **Event naming convention**: `domain:verb` (e.g. `generation:started`, `stream:chunk`).
- **Propagation mechanism**: built on Neovim's native `User` autocmd (`nvim_exec_autocmds`).
- **Prefix**: a `NeoAI:` prefix is added automatically when an event fires (`generation:started` → `NeoAI:generation:started`),
  which avoids conflicts with events from other plugins.
- **Constant registry**: the `NeoAI.kernel.events` module defines all event constants in one place. **Hard-coding event strings is forbidden**;
  always trigger/subscribe by referencing constants.

## 2. Event Bus API

The event bus is implemented in `NeoAI.kernel.event_bus` and provides publish/subscribe/one-shot subscribe/clear-all.

```lua
local event_bus = require("NeoAI.kernel.event_bus")
local events    = require("NeoAI.kernel.events")

-- Subscribe to an event (the first callback argument is payload = args.data)
local unsub = event_bus.on(events.GENERATION_STARTED, function(data)
  print("generation started:", data.agent_id)
end)

-- Emit an event
event_bus.emit(events.GENERATION_STARTED, { agent_id = "agent_xxx" })

-- Subscribe once (automatically unsubscribed after firing)
event_bus.once(events.SESSION_CREATED, function(data) print("first session created") end)

-- Unsubscribe
unsub()

-- Clear all subscriptions (plugin unload/testing)
event_bus.clear_all()
```

You can also use a native autocmd directly (which is exactly what the event bus does internally):

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "NeoAI:generation:started",
  callback = function(args) print(vim.inspect(args.data)) end,
})
```

> **Convention**: `emit(event, payload)` places the payload in `args.data`;
> the subscriber callback signature is `function(data, args) ... end`, where `data` is `args.data`.
> Exceptions raised inside a subscriber callback are caught by the event bus and logged; they do not interrupt other subscribers.

## 3. Event Constant Table

All event constants are defined in `NeoAI.kernel.events`. They are listed below by section.

### Agent Lifecycle

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `AGENT_CREATED` | `agent:created` | Agent created | `{ agent }` |
| `AGENT_SPAWNED` | `agent:spawned` | Sub-agent spawned | `{ parent, agent }` |
| `AGENT_DISPOSED` | `agent:disposed` | Agent disposed | `{ agent_id }` |
| `AGENT_ABORTED` | `agent:aborted` | Agent aborted | `{ agent_id, reason }` |
| `AGENT_STATE_CHANGED` | `agent:state_changed` | State change (idle/generating/tool_running/aborted/error) | `{ agent_id, old, new }` |

### Generation / Streaming

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `GENERATION_STARTED` | `generation:started` | Generation starts | `{ agent_id }` |
| `GENERATION_COMPLETED` | `generation:completed` | Generation completes | `{ agent_id, message }` |
| `GENERATION_ERROR` | `generation:error` | Generation errors | `{ agent_id, error }` |
| `GENERATION_CANCELLED` | `generation:cancelled` | Generation cancelled | `{ agent_id }` |
| `STREAM_STARTED` | `stream:started` | Streaming starts | — |
| `STREAM_CHUNK` | `stream:chunk` | Streaming content chunk | `{ agent_id }` |
| `STREAM_COMPLETED` | `stream:completed` | Streaming completes | — |
| `STREAM_ERROR` | `stream:error` | Streaming errors | — |

### Reasoning

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `REASONING_STARTED` | `reasoning:started` | Reasoning starts | `{ agent_id }` |
| `REASONING_CHUNK` | `reasoning:chunk` | Reasoning content chunk | `{ agent_id, chunk, reasoning }` |
| `REASONING_COMPLETED` | `reasoning:completed` | Reasoning completes | `{ agent_id }` |

### Messages

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `MESSAGE_ADDED` | `message:added` | Message added | `{ agent_id, message }` |
| `MESSAGE_UPDATED` | `message:updated` | Message updated | `{ agent_id, message }` |
| `MESSAGE_EDITED` | `message:edited` | Message edited | `{ agent_id, message }` |
| `MESSAGE_DELETED` | `message:deleted` | Message deleted | `{ agent_id, message }` |
| `MESSAGE_SENT` | `message:sent` | User sends a message | `{ agent_id, content }` |
| `MESSAGE_QUEUED` | `message:queued` | Message entered the staging queue (while the Agent is busy) | `{ agent_id, content }` |
| `MESSAGES_CLEARED` | `messages:cleared` | Messages cleared | — |

### Sessions

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `SESSION_CREATED` | `session:created` | Session created | `{ session }` |
| `SESSION_LOADED` | `session:loaded` | Session loaded | `{ session_id }` |
| `SESSION_SAVED` | `session:saved` | Session saved | `{ count }` |
| `SESSION_DELETED` | `session:deleted` | Session deleted | `{ session_id, deleted }` |
| `SESSION_SWITCHED` | `session:switched` | Session switched | `{ session_id }` |
| `SESSION_RENAMED` | `session:renamed` | Session renamed | `{ session_id }` |
| `SESSION_FORKED` | `session:forked` | Session forked | `{ parent_id, child }` |

### Branches / Tree

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `BRANCH_CREATED` | `branch:created` | Branch created | `{ session_id }` |
| `BRANCH_DELETED` | `branch:deleted` | Branch deleted | `{ session_id }` |
| `TREE_REFRESHED` | `tree:refreshed` | Session tree refreshed | — |

### Tools

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `TOOL_LOOP_STARTED` | `tool_loop:started` | Tool loop starts | `{ agent_id, tool_calls }` |
| `TOOL_LOOP_FINISHED` | `tool_loop:finished` | Tool loop ends | `{ agent_id, rounds }` |
| `TOOL_LOOP_LIMIT_REACHED` | `tool_loop:limit_reached` | Maximum rounds reached (1000) | `{ agent_id, rounds }` |
| `TOOL_LOOP_GUARD_REMINDER` | `tool_loop:guard_reminder` | Guardrail injects a repeated-call reminder | `{ agent_id, repeats }` |
| `TOOL_EXECUTION_STARTED` | `tool:execution_started` | A single tool starts executing | `{ agent_id, name, args, tool_call_id }` |
| `TOOL_EXECUTION_COMPLETED` | `tool:execution_completed` | A single tool completes | `{ agent_id, name, result, tool_call_id, duration_ms }` |
| `TOOL_EXECUTION_ERROR` | `tool:execution_error` | A single tool errors | `{ agent_id, name, error, tool_call_id, duration_ms }` |
| `TOOL_CALL_DETECTED` | `tool:call_detected` | Tool call detected | `{ agent_id, tool_calls }` |
| `TOOL_RESULT_RECEIVED` | `tool:result_received` | Tool result received | `{ agent_id, message }` |
| `TOOL_RESULT_PRUNED` | `tool:result_pruned` | Oversized tool results truncated before compaction | `{ agent_id, tool_name, chars_before, chars_after }` |
| `TOOL_APPROVAL_REQUESTED` | `tool:approval_requested` | Tool approval initiated (enqueued) | `{ tool_name, args, agent_id }` |
| `TOOL_APPROVED` | `tool:approved` | Approval granted | `{ tool_name, agent_id }` |
| `TOOL_APPROVAL_CANCELLED` | `tool:approval_cancelled` | Approval cancelled/rejected | `{ tool_name, reason, agent_id }` |
| `AUTO_MODE_CHANGED` | `approval_mode:auto_changed` | AUTO mode (auto-allow) toggled | `{ active }` |

> Approval events carry `agent_id` so subscribers such as Herder can distinguish the blocked state of different Agents.
> The value of `AUTO_MODE_CHANGED` is `approval_mode:auto_changed` (note that it does not match the name; this is an existing convention).

### User Prompts (ask_user)

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `ASK_USER_WAITING` | `ask_user:waiting` | Starts waiting for a user answer (the Agent becomes a blocked candidate) | `{ agent_id }` |
| `ASK_USER_ANSWERED` | `ask_user:answered` | User answers or cancels the prompt | `{ agent_id }` |

### Tool Argument Reception (Streaming)

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `TOOL_ARG_CHUNK` | `tool:arg_chunk` | Fires chunk by chunk while the model streams tool-call arguments | `{ agent_id, tool_calls }` (a snapshot of the `tool_calls` accumulated so far) |
| `TOOL_ARG_COMPLETED` | `tool:arg_completed` | Argument stream ends | `{ agent_id }` |

> Through these two events, the UI displays a "receiving arguments" floating window (`tool_args_panel`) in real time, just like the reasoning-process floating window.

### To-dos / Plan Mode

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `TODO_UPDATED` | `todo:updated` | To-do list updated | `{ session_id, count, counts }` |
| `PLAN_MODE_CHANGED` | `plan_mode:changed` | Plan mode toggled | `{ agent_id, active }` |

### MCP

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `MCP_CONNECTING` | `mcp:connecting` | Starts connecting to a server | `{ server }` |
| `MCP_READY` | `mcp:ready` | Server handshake and registration complete | `{ server, tools }` |
| `MCP_ERROR` | `mcp:error` | Connection/initialization failed | `{ server, error }` |
| `MCP_DISCONNECTED` | `mcp:disconnected` | Server disconnected | `{ server }` |
| `MCP_TOOLS_UPDATED` | `mcp:tools_updated` | Tools/resources/prompts re-registered after a refresh | `{ server }` (chat_service rebinds the current Agent's toolset based on this) |

### Skills

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `SKILLS_UPDATED` | `skills:updated` | Skill index hot-reloaded | `{ count }` |

### Models

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `MODELS_UPDATED` | `models:updated` | Model list updated | `{ models }` |
| `MODEL_SWITCHED` | `model:switched` | Model switched | `{ agent_id, model }` |
| `MODEL_REFRESH_STARTED` | `models:refresh_started` | Model refresh starts | `{ provider }` |
| `MODEL_REFRESH_FAILED` | `models:refresh_failed` | Model refresh failed | `{ provider, error }` |

### UI / Windows

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `WINDOW_OPENED` | `window:opened` | Window opened | `{ win_id }` |
| `WINDOW_CLOSED` | `window:closed` | Window closed | `{ win_id }` |
| `UI_REFRESHED` | `ui:refreshed` | UI refreshed | — |
| `UI_MODE_CHANGED` | `ui:mode_changed` | UI mode toggled | `{ mode }` |
| `DISPLAY_MODE_CHANGED` | `display:mode_changed` | Display mode toggled | `{ name }` |

### Sub-agents

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `SUB_AGENT_CREATED` | `sub_agent:created` | Sub-agent created | `{ sub_agent_id, task }` |
| `SUB_AGENT_UPDATED` | `sub_agent:updated` | Sub-agent updated | `{ sub_agent_id, status }` |
| `SUB_AGENT_COMPLETED` | `sub_agent:completed` | Sub-agent completed | `{ sub_agent_id }` |
| `SUB_AGENT_ERROR` | `sub_agent:error` | Sub-agent errored | `{ sub_agent_id, error }` |
| `SUB_AGENT_RESULT_READY` | `sub_agent:result_ready` | Sub-agent result ready | `{ sub_agent_id }` |

### Config / Lifecycle

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `CONFIG_LOADED` | `config:loaded` | Config loaded | `{ config }` |
| `CONFIG_CHANGED` | `config:changed` | Config changed | `{ path, old, new }` |
| `PLUGIN_INITIALIZED` | `plugin:initialized` | Plugin initialized (currently only defined, never actually emitted) | — |
| `PLUGIN_SHUTDOWN` | `plugin:shutdown` | Plugin shut down | — |

### Logging

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `LOG_MESSAGE` | `log:message` | Log message recorded | `{ level, message }` |

### Context Compaction

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `COMPACTION_STARTED` | `compaction:started` | (reserved; no longer emitted by background compaction) | `{ agent_id, estimated_tokens }` |
| `COMPACTION_CHUNK` | `compaction:chunk` | (reserved; no longer emitted by background compaction) | `{ agent_id, reasoning, content }` |
| `COMPACTION_COMPLETED` | `compaction:completed` | Background compaction completes (writes the overlay) | `{ agent_id, replaced, summary }` |

### Plan Distillation

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `PLAN_DISTILL_STARTED` | `plan_distill:started` | Plan-stage distillation starts | `{ agent_id }` |
| `PLAN_DISTILL_CHUNK` | `plan_distill:chunk` | A streamed categorized-summary chunk arrives | `{ agent_id, reasoning, content }` |
| `PLAN_DISTILLED` | `plan_distilled` | Distillation completes | `{ agent_id, replaced, summary }` |

> Context compaction is **asynchronous in the background and opens no window**: it no longer emits `COMPACTION_STARTED` / `COMPACTION_CHUNK` (constants reserved),
> only `COMPACTION_COMPLETED`. Plan distillation still opens the "🧬 Plan Distillation" floating window and emits `PLAN_DISTILL_STARTED` / `PLAN_DISTILL_CHUNK`.

### Sandbox

| Constant | Value | When it fires | Key payload fields |
| --- | --- | --- | --- |
| `SANDBOX_SYSTEMD_ROUTED` | `sandbox:systemd_routed` | A systemctl/journalctl call is routed by the facade to a long-lived sandbox service | `{ verb, units, ok, command_id }` |
| `SANDBOX_SYSTEMD_UNSUPPORTED` | `sandbox:systemd_unsupported` | The facade explicitly rejects unsupported systemd semantics (never touches the host) | `{ verb, units, command_id }` |
| `SANDBOX_CONTAINER_PLANNED` | `sandbox:container_planned` | Container control plan (namespace sharing / controlled socket) | `{ manager, mode, share_namespace, reason, command_id }` |
| `SANDBOX_CONTAINER_UNSUPPORTED` | `sandbox:container_unsupported` | Container facade rejects host-daemon/remote/host subcommands | `{ manager, sub, reason, command_id }` |
| `SANDBOX_BACKGROUND_ROUTED` | `sandbox:background_routed` | A `run_command` background command (`&`/nohup/setsid) is routed by the facade to a long-lived service | `{ name, service_id, kind, command_id }` |

## 4. Event Subscription Best Practices

1. **Always reference constants**: trigger and subscribe through the constants in `NeoAI.kernel.events`; do not hard-code strings.
2. **Clean up promptly**: `event_bus.on(...)` returns an unsubscribe function; call it when a window closes or an agent is disposed to prevent leaks.
3. **Avoid blocking**: event callbacks run in the autocmd context, so do not perform time-consuming I/O; defer expensive work with `vim.schedule`.
4. **Isolate errors**: exceptions thrown by a callback are caught by event_bus and logged without interrupting other subscribers (but it is still best to `pcall` yourself).
5. **Payload is shallow**: the payload passed to `emit` is deep-copied by `nvim_exec_autocmds`, so **do not rely on object metatables/methods**.
   When you need to pass the original object (such as a timer or an Agent instance), pass it directly via a closure or a module-level reference instead of stuffing it into the event payload.

## 5. Event Subscription Examples

```lua
local event_bus = require("NeoAI.kernel.event_bus")
local events    = require("NeoAI.kernel.events")

-- Subscribe to generation completion and render
event_bus.on(events.GENERATION_COMPLETED, function(data)
  print("Agent", data.agent_id, "finished generating")
end)

-- Subscribe to tool approval (used by Herder: mark as blocked)
event_bus.on(events.TOOL_APPROVAL_REQUESTED, function(data)
  -- data.agent_id
end)

-- Subscribe to the tool argument stream (used by the UI: open the receiving-arguments floating window)
event_bus.on(events.TOOL_ARG_CHUNK, function(data)
  -- data.tool_calls → tool_args_panel.show(...)
end)
```
