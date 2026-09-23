# NeoAI Tool Loop Engine Deep Dive (v3.0)

> [中文](../../analysis/tool_cycle_memory_analysis.md) | **English**

> This document analyzes the v3.0 tool call loop (`core/agent/tool_loop.lua`) and its interaction with approval, guardrails, and timeouts.
> The legacy `core/ai/tool_cycle.lua` / `tool_executor.lua` / `approval_handler.lua` etc. have been removed,
> and their responsibilities are inherited by `core/agent/tool_loop.lua` + `services/tool_service.lua` + `tools/*`.

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Core Flow](#2-core-flow)
3. [CPU Usage and Performance](#3-cpu-usage-and-performance)
4. [Memory and State Management](#4-memory-and-state-management)
5. [Interaction Between Approval and the Tool Loop](#5-interaction-between-approval-and-the-tool-loop)
6. [Potential Issues and Design Trade-offs](#6-potential-issues-and-design-trade-offs)

---

## 1. Architecture Overview

### File Structure (v3.0)

```
lua/NeoAI/
├── core/agent/
│   ├── agent.lua          # Agent object (state machine + private message queue + AbortSignal)
│   ├── runtime.lua        # Runtime (create/spawn/dispose/abort/run)
│   ├── tool_loop.lua      # Tool call loop (the subject of this analysis)
│   ├── stream.lua         # Streaming (including streaming accumulation of tool arguments)
│   ├── prefix.lua         # Prefix cache identity consistency
│   ├── guard.lua          # Tool loop guard (repeated call reminders)
│   └── request.lua        # Request building/sending/retry
├── services/
│   └── tool_service.lua   # Approval (serial single slot) + scheduling + execution
├── tools/
│   ├── executor.lua       # Argument normalization/validation/approval decision/execution + timeout
│   ├── registry.lua       # Tool registry
│   └── builtin/*          # Built-in tools
└── utils/
    ├── async.lua          # Promise/Deferred/AbortSignal
    ├── timer.lua          # Pausable timer
    └── work.lua           # Thread pool (blocking I/O)
```

### Event-Driven Architecture

```
TOOL_LOOP_STARTED (tool_loop.run)
      │
      ├─ Run _execute_single in parallel (one Deferred per tool)
      │      ├─ TOOL_EXECUTION_STARTED
      │      ├─ tool_service.execute → executor.execute
      │      │      ├─ alias resolution → argument normalization → path expansion → schema validation
      │      │      ├─ approval decision (validator.check_approval, non-async modes only)
      │      │      │      ├─ approval required → approve_and_execute (serial popup)
      │      │      │      └─ direct execution → _execute_tool (pausable timer timeout)
      │      │      └─ sandbox gate sandbox.gate (async default: execute and freeze candidate)
      │      └─ TOOL_EXECUTION_COMPLETED / _ERROR
      │
      ├─ async.all(promises) all complete
      │      └─ write back to the message queue via add_tool_result in original order
      │             └─ TOOL_RESULT_RECEIVED
      │
      ├─ guard.check_round (repeated call reminders)
      │      └─ reminder present → add_message("user", reminder) + TOOL_LOOP_GUARD_REMINDER
      │
      ├─ set_state("generating") + TOOL_LOOP_FINISHED
      │
      └─ _send_round (request the next round, persistent stream handler)
             ├─ tool calls present → loop
             └─ no tool calls → if the last entry is a tool, write EMPTY_RESPONSE_MESSAGE → finish
```

---

## 2. Core Flow

### 2.1 Tool Loop Entry Point (tool_loop.run)

`tool_loop.run(agent, tool_calls, tool_service, opts)` main loop `_loop()`:

- Each round checks `signal:aborted()` → the loop is cancelled.
- When the round count exceeds `MAX_ROUNDS(1000)` → write `LOOP_LIMIT_MESSAGE` (no notify popup; it becomes directly visible via `MESSAGE_ADDED`)
  + emit `TOOL_LOOP_LIMIT_REACHED`, then finish.
- No tool calls → resolve.
- `set_state("tool_running")` + `TOOL_LOOP_STARTED`.

### 2.2 Single Tool Execution (_execute_single)

```lua
local function _execute_single(agent, tool_call, tool_service, opts)
  -- 1. Parse the arguments JSON of tool_call (attempt to repair incomplete JSON)
  -- 2. Create a pausable timer (utils.timer)
  -- 3. Register it with fold using the original object (set_live_timer, so the UI can read live elapsed time)
  -- 4. TOOL_EXECUTION_STARTED
  -- 5. tool_service.execute(...) → Deferred
  -- 6. Success/failure → TOOL_EXECUTION_COMPLETED/_ERROR (including duration_ms)
end
```

Tool calls are **executed in parallel** (one Deferred each), but the results are **written back to the
message queue in original order, all at once** after `async.all` completes (`_execute_single` does not
write directly), ensuring that the tool message order matches the assistant's `tool_calls`.

### 2.3 Tool Definition Output (_tool_definitions)

- Output in **lexicographic order** by name (deterministic, prefix-cache friendly).
- Empty `properties` are not emitted (DeepSeek rejects `[]` schemas).
- Environment probing comes first (`tools.environment.filter_tools`), disabling tools whose environment dependencies are unavailable.
- In plan mode only read-only/information-query tools plus `ask_user` are kept (`plan_mode.apply_tool_filter`).

---

## 3. CPU Usage and Performance

### 3.1 Render Coalescing (chat_view Side)

`chat_view` coalesces multiple chunks/events within the same tick into a single render (`_schedule_render`),
avoiding a full re-render per chunk plus `zxzM` fold recomputation that blocks the main thread. During tool
execution it refreshes the folded elapsed time once per second (`TOOL_TICK_MS=1000`).

### 3.2 Async Scheduling Inside the Tool Loop

Tools are executed via `tool_service.execute`, and blocking I/O runs on the `utils.work` thread pool (without
occupying the main thread). Approval is **serialized** inside `tool_service` (a single popup slot, with the rest
queued), so concurrent startup cannot cause popups to overwrite each other.

### 3.3 Folded Elapsed Time Refresh

During tool execution `chat_view` re-renders the folded text once per second so the elapsed time ticks in real
time. When `fold.has_running()` is false, refreshing stops. The elapsed time is based on the
**active time** of `utils.timer` (excluding approval/question waiting).

---

## 4. Memory and State Management

### 4.1 Agent Private Message Queue

Each Agent holds its own private `messages`. Tool results are not written directly in `_execute_single`;
instead, after `async.all` completes they are added via `add_tool_result` in original order. `agent.messages`
accumulates over the lifetime of the session.

### 4.2 Context Compaction

`runtime.run` calls `compactor.maybe_compact` before each new step (at turn boundaries, requiring idle);
`tool_loop._send_round` calls `maybe_compact({ allow_busy = true })` before sending on **every round of the
tool loop** (at that point the previous round's tool results have been written back and the next request has
not yet been sent, so there are no concurrent writes and compaction is safe). Both paths: once the pressure
threshold (`context_window * threshold_ratio`) is reached, `tool_result_pruner` first trims overly long tool
results (head/marker/tail); if it is still above the threshold after trimming, the earliest full blocks of
history are folded (keeping the cut point balanced with respect to tool pairings), the most recent tail is
retained (retain budget), and the rest is replaced with a checkpoint (replace only, never append).

`force_compact` is used for overflow recovery: it trims first, and if necessary performs a maximized balanced
head reduction (retain 0); it **defaults to `allow_busy = true`**, ensuring that overflow recovery can actually
compact both on the first round of a turn and mid-way through the tool loop (generating/tool_running)
(otherwise it would be rejected by the idle guard and the overflow error would be thrown directly).

A checkpoint records both `replaced_count` (number of entries replaced) and `replaced_synced_count` (number of
entries already persisted to disk): at turn boundaries the two are equal; when compacting mid-loop, the current
turn's messages have not yet been persisted, so the durable surface deletes only the already-synced entries,
avoiding accidental deletion of the previous turn's history.

### 4.3 Prefix Cache Identity

`prefix.verify_cache_identity` compares the fingerprint across requests; an identity change means the prefix
cache is invalidated (used for diagnostics and statistics). `context_builder` does not write
`reasoning_content` back into history, avoiding invalidating the DeepSeek prefix cache starting from that
assistant message.

### 4.4 Session/Sub-Agent Cleanup

`runtime.dispose(agent)` releases resources (`signal:abort("disposed")`), `plan_mode.cleanup` clears the
agent-level prompt section, and `todo.cleanup` clears todo state. `chat_service.detach_window` persists and
cleans up when a window closes, plus `tool_service.clear_approval` (releasing the serial approval slot).

---

## 5. Interaction Between Approval and the Tool Loop

> Under the default `tools.approval.mode = "async"` there is **no pre-execution blocking approval**;
> this section describes the popup-approval behavior under `prompt`/`strict` modes (or compatibility
> cases such as masked-directory hits).

### 5.1 Timing During Approval

Each tool creates a **pausable timer** (`utils.timer`) in `tool_loop._execute_single`. Timing starts only when
the tool actually begins executing (approval granted/direct execution); while waiting for user approval or an
`ask_user` answer, `timer:pause()` is called, and `resume()` follows afterward. Waiting time is neither counted
toward elapsed time nor consumed from the timeout budget.

### 5.2 Serial Approval Queue

`tool_service` is a **serial single slot**: only one approval popup is shown at a time and the rest are queued
in `approval_queue`, so they never overwrite each other. Tool execution itself is parallel, but "popup
confirmation" is serialized.

- **Approval timeout fallback**: `tools.approval.timeout_ms` defaults to 60s; on timeout the tool is rejected
  rather than hanging forever; once a decision is made (`item.d = nil`), the timeout no longer applies.
- **Popup failure tolerance**: when showing fails (`pcall`), the serial slot is released and that entry is
  rejected; the tool finishes with an error result and the loop continues, so it never deadlocks due to
  `approval_showing` being left true.

### 5.3 Plan Mode Gate

`tool_service.execute` first calls `plan_mode.check_tool(agent, tool_name)`: in plan mode, calling any tool
outside the visible set is rejected (defense in depth; `tool_loop._tool_definitions` has already filtered).

---

## 6. Potential Issues and Design Trade-offs

### 6.1 Tool Loop Termination Conditions

- **Guardrail** (`guard`): observe-and-enrich; it detects consecutive repeated tool calls and injects a
  reminder, but does not veto them. New user input (`guard.reset` in `runtime.run`) resets the counting chain.
  Thresholds are 3/5/8 and configurable.
- **Round limit**: `MAX_ROUNDS(1000)` is a defensive cap; reaching it stops the loop and writes an explanation.

### 6.2 Empty Response Handling

On the second round of the tool loop, or when the model returns no content (no tool calls, no text), it writes
`EMPTY_RESPONSE_MESSAGE` as an assistant closing message, preventing the chat from "appearing stuck".

### 6.3 Overflow Recovery

When a request returns a context overflow, `recovery.send_stream` first calls
`force_compact(agent, { allow_busy = true })` to compact history and then retries, at most once per round,
resetting the flag on success. When there is nothing to fold, the overflow error is rethrown as-is.
`allow_busy = true` ensures recovery also takes effect under generating/tool_running (both the first round of a
turn and mid-way through the tool loop follow this path).

### 6.4 Known Trade-offs

- Parallel tool execution + sequential write-back: guarantees API compatibility and deterministic prefix
  caching, but `async.all` must wait for the slowest tool.
- Serial approval: sacrifices popup concurrency to avoid overwriting each other, but approval waiting is
  excluded via the pausable timer so it does not time out.

---

## Appendix: Key Data Flow (Write Tool + Approval)

```
1. The model returns edit_file(file_path, description, edits)
2. _execute_single → tool_service.execute
3. executor.execute:
   resolve_name → alias resolution → path expansion → schema validation
   → approval decision (edit_file auto_allow=false → approval required)
4. approve_and_execute → enqueue into the serial approval queue
5. The user presses <CR> to confirm → TOOL_APPROVED → continue_fn resumes execution
6. continue_fn → _execute_tool (pausable timer start)
   → edit_file modifies disk via the utils.work thread pool + reload_buffers_for
7. TOOL_EXECUTION_COMPLETED (including duration_ms)
8. async.all → add_tool_result (in original order)
9. guard.check_round → _send_round → the model continues writing
```
