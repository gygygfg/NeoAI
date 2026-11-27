# NeoAI Sub-Agent System (v4.0)

> [中文](../sub_agent_system.md) | **English**

> Sub-agents let the main agent use `create_sub_agent` to offload complex tasks to an isolated session. Every sub-agent runs
> in a **brand-new environment with zero inheritance**, with its own AbortSignal, its own persistent child session, and a
> constrained tool subset. **There is no wait tool**: when a sub-agent's loop ends naturally, its final body is delivered back
> to the main agent automatically.
> Corresponding source: `lua/NeoAI/core/agent/sub_agent.lua`, `lua/NeoAI/tools/builtin/plan.lua`,
> `lua/NeoAI/services/chat_service.lua`, `lua/NeoAI/ui/components/sub_agent_dock.lua`.

## 1. Module Structure

| Module | Responsibility |
| --- | --- |
| `core/agent/sub_agent.lua` | Single source of truth for sub-agents: registry + lifecycle + result delivery + boundary review. |
| `tools/builtin/plan.lua` | Dispatch tools: `create_sub_agent` / `get_sub_agent_status` / `cancel_sub_agent` / `send_sub_agent_message` (delegates to the manager via `kernel.core_bridge`). |
| `services/chat_service.lua` | Injects dispatch/persist hooks; delivers sub-agent results back to the main agent; registers child sessions for switching. |
| `services/tool_service.lua` | Boundary review for sub-agent tool calls (`sub_agent.review_tool_call`). |
| `ui/components/sub_agent_dock.lua` | Sub-agent status monitoring (dock). |

## 2. Lifecycle

### 2.1 Creation (create_sub_agent)

1. Generate a `sub_id` (`sub_<time>_<rand>`) and create a **persistent child session**
   (`parent_id = main session`, `metadata.tags = {"sub_agent"}`, `metadata.name = name`).
2. `runtime.spawn(parent, { session_id, model, cwd, tools })` creates a brand-new sub-agent (independent signal, zero inheritance).
3. The tool subset is built by `tools/builtin/plan.lua`: **all main-agent tools by default, excluding only "Agent-class"
   tools** (`category == "agent"`: dispatch tools `create_sub_agent`/`get_sub_agent_status`/`cancel_sub_agent`/
   `send_sub_agent_message`, `enter_plan_mode`, `todo_*`). **`ask_user` is the exception** — a sub-agent's question
   is relayed to the main agent (see §2.5).
   When `boundaries.allowed_tools` is given it takes precedence (also excluding Agent-class tools; list `ask_user`
   explicitly if the sub-agent should be able to ask).
4. Emit `SUB_AGENT_CREATED`; `chat_service` registers the child-session → agent mapping (so switching reuses a running agent).
5. `runtime.run(child, task .. "\n\n" .. final_instruction)` starts execution.
   `final_instruction` comes from `tools.sub_agent.final_instruction` (defaults to a "summarize your work at the end" instruction).

### 2.2 Result Delivery (no wait tool)

When the sub-agent's loop ends naturally (no more tool calls):

1. Set status `completed` and record `result_text` (the final body).
2. Persist the child session and emit `SUB_AGENT_COMPLETED` + `SUB_AGENT_RESULT_READY`.
3. Via the dispatch hook injected by `chat_service`, deliver the result to the main agent:
   - Main agent idle → inject a message and **auto-wake** the main agent (start a generation turn);
   - Main agent busy → enqueue into pending, injected at the next round boundary or after the current turn;
   - Main agent disposed (window closed) → write back to the main-session archive, visible when reopened.

The main agent therefore never polls/waits: it keeps working, and the result comes back automatically.

### 2.3 Boundary Review (review_tool_call)

Every sub-agent tool call goes through `tool_service._review_sub_agent` → `sub_agent.review_tool_call`:

- Dispatch tools are always rejected.
- If `boundaries.allowed_tools` exists and does not contain the tool → reject.
- If `boundaries.max_tool_calls` is reached → reject.
- Otherwise it passes and `sub_agent.track_tool_call` increments the counter.

> Sub-agents run their tool loop with `is_sub_agent = true` (set by `runtime._run_generation`).
> **Approval routing**: in `async` mode (default) a sub-agent executes directly in the sandbox (boundary/cross-mount
> cases fail-closed); in non-async modes (`prompt`/`strict`) a sub-agent's tool approval request is **routed to the
> main agent** — the `approval_agent` attributes it to the main agent and the user decides via the approval UI;
> actual execution still uses the sub-agent's cwd/sandbox domain (`tool_service.execute` resolves the
> `sub_agent_id` → parent agent).

### 2.4 Cancel / Send Message

- `cancel_sub_agent` → `sub_agent.cancel`: `runtime.abort(child)`, set `cancelled`, emit `SUB_AGENT_UPDATED`, persist;
  pending questions are voided too.
- `send_sub_agent_message` → `sub_agent.send` is the **only agent-to-agent conversation channel**:
  - sub-agent has a **pending question** → this message is the answer (FIFO, current question); the sub-agent's
    `ask_user` tool result becomes `主 Agent 回答: …` and no extra round is injected;
  - running with no pending question → injected into its next round;
  - completed → resumes it for one more round.

### 2.5 Sub-agent Questions (ask_user relayed to the main agent)

Sub-agents **can** call `ask_user` (`_build_tools` special-cases it), but it never shows a popup:

1. `ask_user` detects `ctx.is_sub_agent` → `sub_agent.ask_parent(sub_id, req)`: pauses the sub-agent's active timer
   (**no timeout**), registers the question, emits `SUB_AGENT_QUESTION`.
2. The question is wrapped as a `role=user` message (marker `sub_agent_question`, with `question_id`/task/question/options)
   and delivered to the main agent: idle → starts a turn; busy → queued for the next round boundary. Only **one question
   per sub-agent** is in flight; further questions queue in order.
3. The main agent decides:
   - answer directly: `send_sub_agent_message(sub_agent_id, …)`;
   - ask the user first: `ask_user`, then reply with `send_sub_agent_message`.
4. The manager settles the question; the sub-agent's `ask_user` tool result is `主 Agent 回答: …`; if another question is
   queued it is delivered immediately.
5. Lifecycle: cancel/finish of the sub-agent, parent disposal, session deletion, or manager reset voids all
   pending/queued questions with an error — the sub-agent never hangs forever.

> The sub-agent tool subset **excludes** `send/cancel/get_status/create` (only the main agent dispatches);
> an agent cannot answer another agent's question (`send` validates `parent_agent_id`).
> The `ask_user` popup only serves the main agent; sub-agent questions never occupy it.

## 3. Tool List (main agent)

| Tool | Description | Parameters |
| --- | --- | --- |
| `create_sub_agent` | Creates a sub-agent (runs in background, returns immediately; **no polling/waiting needed** — the final body is delivered automatically) | `task` (required); `name` (optional short label); `model` (optional); `boundaries` (optional) `{allowed_tools, allowed_directories, allowed_commands, max_tool_calls, max_iterations}`; `context` (optional) |
| `get_sub_agent_status` | Queries status, task and result (**normally not needed**; only to confirm whether it is still running / stuck; includes a pending-question summary) | `sub_agent_id` (required) |
| `cancel_sub_agent` | Cancels the sub-agent | `sub_agent_id` (required) |
| `send_sub_agent_message` | Sends a message to a sub-agent / **answers its question** (the only agent conversation channel) | `sub_agent_id`, `message` (both required) |

> `wait_sub_agent` has been removed: there is no wait tool; results are delivered automatically.
> Sub-agents **never receive** any of the above dispatch tools; they only get `ask_user` as the upward channel.
> With the default asynchronous approval (`tools.approval.mode = "async"`), `create_sub_agent` executes immediately in the sandbox.

> **Plan mode**: in async-sandbox draft mode a spawned sub-agent inherits the parent's plan scope, so its file writes are
> drafts too and are discarded with the parent scope; the same capability ceiling applies (SSH/host privilege/long-lived
> services/untrusted MCP or external tools).

## 4. State and Events

`state.subs[sub_id]` records `{ id, name, task, agent_id, session_id, parent_agent_id,
parent_session_id, boundaries, status, result_text, error, started_at, tool_calls, pending_questions }`,
where `status` is one of: `running` / `completed` / `error` / `cancelled`.

| Event | Trigger |
| --- | --- |
| `SUB_AGENT_CREATED` | Sub-agent created (includes name/agent_id/session_id) |
| `SUB_AGENT_UPDATED` | Status updated (cancelled / resumed) |
| `SUB_AGENT_COMPLETED` | Completed |
| `SUB_AGENT_ERROR` | Errored |
| `SUB_AGENT_RESULT_READY` | Result ready (for delivery) |
| `SUB_AGENT_QUESTION` | Sub-agent question relayed to the main agent |
| `SUB_AGENT_QUESTION_ANSWERED` | Sub-agent question settled (answered/voided) |

## 5. UI: Statusline and Switching

- **winbar** (top of the main chat window): the identity row renders `[CHAT] <model> <state> <sub-agent names>`.
  Names are laid out flat; if the joined text **exceeds the chat window width**, it collapses to
  `N个子agent正在运行` (`services/status.sub_agents_segment`, width-adaptive).
- **Statusline usage**: `↑`/`↓` and the parenthesized cumulative hit rate cover the **main session +
  all direct sub-agent sessions** (live sub-agents in real time; completed ones, or after reopening
  the session, from their persisted sub-session usage; sub-agents under forked branches are excluded).
  The cumulative hit rate is token-weighted; the single-request value is the most recent request
  across the main and sub agents.
- **Keybinding** `keymaps.chat.switch_sub_agent` (default `<leader>as`): cycles and opens a sub-agent session
  **in a new window** (a running sub-agent reuses the live agent, so you watch it in real time).
- **List popup** `keymaps.chat.sub_agent_list` (default `<leader>al`): opens a **borderless** floating list at
  the top of the chat window (where the winbar shows sub-agent names); `↑/↓` (k/j) move the cursor, `<CR>` enters
  that sub-agent session in a new window, `q`/`<Esc>` closes. The float is positioned relative to the chat window
  and recomputes its geometry on window resize.
- `sub_agent_dock`: an event-driven running-status panel.
- **Session tree**: sub-agent sessions (`metadata.tags` contains `sub_agent`) are labelled `🤖 子 Agent：<name>`
  and are **not marked as "user"**; on reopen they are recognized by the tag (agent marked `_sub_agent_session`,
  given only non-Agent-class tools, and loaded with their own messages only — no ancestor chain).
- **Chat view**: a delivered sub-agent result is **not rendered as a user message**; it renders as a collapsible
  block like a tool call (first line `✅ 子 Agent: <name>`, plus task and body) and is persisted with the session.

## 6. Example

```lua
-- Main agent initiates (background, no waiting needed)
create_sub_agent({ task = "Analyze the architecture tree of README.md", name = "README arch" })

-- Query status
get_sub_agent_status({ sub_agent_id = "sub_abc" })

-- Follow-up / extra instruction
send_sub_agent_message({ sub_agent_id = "sub_abc", message = "Also cover dependencies" })

-- Cancel
cancel_sub_agent({ sub_agent_id = "sub_abc" })
```

## 7. Related Documentation

- [ai_engine.md](ai_engine.md): `runtime.spawn` / `runtime.run` generation flow.
- [tool_system.md](tool_system.md): tool boundary review, `boundaries` constraints.
- [EVENTS.md](EVENTS.md): sub-agent events.
- [configuration.md](configuration.md): `tools.sub_agent.final_instruction`, `keymaps.chat.switch_sub_agent`.
