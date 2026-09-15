# NeoAI Agent Engine (v3.0)

> [中文](../ai_engine.md) | **English**

> This document describes the NeoAI Agent engine: the complete pipeline from building
> context out of a session, sending requests, and handling streaming responses,
> to running the tool loop, context compaction, and overflow recovery.
> Corresponding source: `lua/NeoAI/core/agent/*`.

## 1. Module Structure

Each module under `core/agent/` has a single responsibility, with one-way dependencies (`agent → runtime → request/stream/tool_loop`).

| Module | Responsibility |
| --- | --- |
| `agent.lua` | The Agent object (pure data + methods, no I/O). State machine `idle → generating → tool_running → idle` (or `aborted`/`error`). Private message queue, tool set, independent AbortSignal. |
| `runtime.lua` | Agent runtime: `create` / `spawn` (derive) / `dispose` / `abort` / `run`. Resolves scenario configuration, binds tools, orchestrates the generation flow. |
| `request.lua` | Request construction (via adapter) + sending (streaming/non-streaming) + exponential backoff retries + context overflow detection. |
| `stream.lua` | Streaming response handling: accumulates the incremental `tool_calls` of the OpenAI chunked format into complete tool_calls, and emits `TOOL_ARG_CHUNK`/`TOOL_ARG_COMPLETED` in real time. |
| `tool_loop.lua` | Tool call loop: run tools in parallel → ask the AI to continue → until there are no more tool calls. |
| `prefix.lua` | Prefix cache identity consistency: system prompt concatenated from ordered sections, tools output in lexicographic order, fingerprint comparison, maximizing the cache hit rate; cache-hit parsing is dispatched by model mechanism (normalizing OpenAI/DeepSeek/Anthropic/Gemini fields). |
| `guard.lua` | Tool loop guardrail: detects consecutive repeated tool calls and injects a reminder (observe-and-enrich). |
| `recovery.lua` | Context overflow recovery: automatically compacts history and resends when a request returns context window exceeded. |

## 2. Core Concepts

### 2.0 Automatic Selection by Model (capabilities / profiles / adapter)

The entire pipeline resolves one set of "model policy" per request:

- `core/model/profiles.lua` → **Dialect**: vendor/model overrides within a protocol family (`max_tokens` / `max_completion_tokens` /
  `maxOutputTokens`; `reasoning_effort` / `enable_thinking` / `thinking` / `thinkingConfig`; auth headers;
  usage fields; `reasoning_echo`). A model pattern overrides the provider profile only when the protocol and `api_type` match.
- `core/model/capabilities.lua` → **Capabilities**: context window, max output, cache mechanism (`openai`/`anthropic`/`gemini`),
  minimum cacheable tokens, explicit cache TTL/breakpoint limit, character/token coefficients. Value resolution order: user override → **live API metadata
  (`inputTokenLimit` / `context_length`, etc. returned by `/models`)** → built-in pattern → `api_type` default → fallback
  (`caps.source` marks the source). `max_tokens` sending policy: it is sent only when explicitly configured by the user, and is not sent when unconfigured
  (determined by the model/vendor default max output; for protocols where it is required, such as Anthropic, the capability table's `max_output` is used as a fallback).
- `core/model/adapter.lua` → **Protocol encoding/decoding**: encodes/decodes the internal canonical form (OpenAI-shaped messages + unified responses) into
  each protocol's wire shape (`encode_messages` / `encode_tools`; Anthropic `system` at the top level + `tool_use`/`tool_result`
  + `input_schema` + `source.base64`; Gemini `contents` + `functionDeclarations` (uppercase types, trimmed schema)
  + `inlineData`).
- `core/model/prompt_cache.lua` → **Explicit caching**: Anthropic `cache_control` breakpoints / OpenAI explicit /
  Gemini `cachedContents` lifecycle; on failure it automatically degrades to implicit.

The request parameter format and the cache-hit computation scheme are therefore **selected automatically per model**, with a safe fallback for unknown models. See
[model_policy.md](model_policy.md) for details.

### 2.1 Agent Object (a brand-new instance for every conversation)

Each session corresponds to a **brand-new Agent instance**, with zero state leakage:

- `id`: globally unique (`stringx.uuid("agent")`).
- `session_id`: the id of the session it belongs to.
- `parent`: the parent Agent id of a sub-agent.
- `messages`: private message queue (`{ role, content, reasoning?, tool_calls?, ts }`).
- `tools`: the subset of visible tools (`name -> tool def`).
- `signal`: an independent AbortSignal (cancellation signal).
- `state`: the current value of the state machine.
- `cache`: prefix cache identity fingerprint and hit statistics.

The state machine is defined by `agent.lua`:

```
idle → generating → tool_running → idle
            ↓              ↓
         aborted          error
```

### 2.2 Scenario-based Configuration Resolution

`runtime._resolve_agent_config` resolves the model configuration by `scenario`, with the priority: `scenario provider/preset → preset → user override`.
Scenario values: `chat` / `coding` / `reasoning` / `agent`. When `model = "auto"`, the default model is resolved from `core.model.registry`.

## 3. Generation Flow (runtime.run)

`runtime.run(agent, content)` is the main entry point:

1. **Busy check**: `agent_mod.is_busy(agent)` (generating / tool_running) → returns `reject({kind="busy"})`.
2. **Signal reset**: if the previous run was cancelled (`signal:aborted()`), replace it with a brand-new AbortSignal (otherwise the next request round fails immediately).
3. **Context compaction check**: `compactor.maybe_compact(agent)` — once the pressure threshold is reached, fold the old history first so the prefix cache can be reused.
4. **Guardrail reset**: `guard.reset(agent)` — a new user input resets the repeated-call counter.
5. **Add user message**: `agent:add_message("user", content)`, emitting `MESSAGE_SENT`.
6. **Generate**: `_run_generation(agent, {})` (see below).

### 3.1 Generation (_run_generation)

```
_runtime._run_generation(agent, opts)
  → stream.create(agent) creates the stream processor
  → agent:set_state("generating") + GENERATION_STARTED
  → recovery.send_stream(agent, { agent_config, model, signal }, on_chunk)
      ├─ per chunk → proc.process(chunk) (content/reasoning/tool-call deltas written into the agent)
      ├─ success → accumulate usage + proc.finish() to obtain tool calls
      │    ├─ has tool calls → tool_loop.run(agent, tool_calls, tool_service)
      │    └─ no tool calls → write EMPTY_RESPONSE_MESSAGE if the response is empty → wind down to idle
      └─ failure (cancelled) → reset state to idle, reject({kind="cancelled"})
                    (ordinary error) → state error + GENERATION_ERROR
```

### 3.2 Streaming (stream.lua)

`stream.create(agent)` returns a `processor`, and `processor.process(parsed)` handles each parsed chunk:

- **Reasoning**: `REASONING_STARTED` → `agent:append_reasoning(chunk)` (`REASONING_CHUNK`).
- **Content**: `agent:append_content(chunk)`.
- **Tool calls**: `_accumulate_tool_calls` accumulates deltas by `index` (concatenating name/argument strings),
  and emits `TOOL_ARG_CHUNK { agent_id, tool_calls = current accumulated snapshot }` in real time.

`processor.finish()` ends the stream: it finalizes the accumulated tool_calls into the agent (`set_tool_calls`,
emitting `TOOL_CALL_DETECTED`) and emits `TOOL_ARG_COMPLETED`.

> `TOOL_ARG_CHUNK` / `TOOL_ARG_COMPLETED` are new events that let the UI display the "receiving arguments" floating
> window (`tool_args_panel`) in real time, with behavior consistent with the thinking-process floating window.

### 3.3 Context Construction (core/session/context_builder)

`context_builder.build_from_agent(agent)` builds the API context from the Agent's message queue:

- The first system message is rendered by `prefix.build_system_prompt(agent)` (ordered section concatenation).
- The tool call protocol requires: for an assistant message with `tool_calls`, `content` must be `null` (or omitted).
- **Reasoning content (reasoning_content) is not sent back with the history**: this avoids resending the whole chain of thought on every request,
  which would make DeepSeek's prefix cache byte-inconsistent from that assistant message onward and thus invalidate it. The internal `message.reasoning`
  is still kept for rendering.

## 4. Tool Call Loop (tool_loop.lua)

`tool_loop.run(agent, tool_calls, tool_service, opts)` is the tool loop's main loop.

### 4.1 Loop Structure

```
_run() each round:
  1. abort check → reject({kind="aborted"})
  2. increment the rounds counter; if it exceeds MAX_ROUNDS(1000) → write LOOP_LIMIT_MESSAGE + TOOL_LOOP_LIMIT_REACHED
  3. no tool calls → resolve({response, rounds})
  4. set_state("tool_running") + TOOL_LOOP_STARTED
  5. run all tools in parallel (_execute_single, promises[i])
  6. async.all(...) → results written back to the message queue uniformly in the original order (add_tool_result)
  7. guardrail check_round (inject repeated-call reminders)
  8. set_state("generating") + TOOL_LOOP_FINISHED
  9. _send_round(agent) requests the next round
     ├─ round-boundary compaction: maybe_compact({allow_busy=true}) (tool results already written back, before the next request)
     ├─ pre-round refresh (MCP stale schema)
     ├─ has tool calls → return to step 1 of the loop
     ├─ no tool calls but truncated → _drain_truncation auto-continues (see 4.5)
     └─ no tool calls → if the last message is a tool message, write EMPTY_RESPONSE_MESSAGE → end
```

> **Round-boundary compaction**: `_send_round` calls `compactor.maybe_compact(agent, { allow_busy = true })` before actually sending.
> At this moment the previous round's tool results have been written back and the next round's request has not yet been sent, so there are no concurrent writes and
> folding history is safe; a long tool loop therefore converges its context round by round. When compaction is a no-op (below the threshold/nothing foldable) it does not
> block the send, and a compaction error also falls back to the original send path.

### 4.5 Truncation Continuation (_drain_truncation)

When the model output is truncated by the output limit (`finish_reason` is `length` / `max_tokens` / `MAX_TOKENS`, see
`tool_loop.is_truncated`) and there are no tool calls in the current round, if `ai.truncation` is enabled and `max_continues` has not been reached,
a round is automatically resent with a continuation nudge (`ai.truncation.nudge`) attached as `extra_user`:

- The nudge **only goes into the request wire and is not persisted** (the `extra_user` of `context_builder.build_from_agent`); the continued content is
  appended via `append_content` into the **same** assistant message, producing no empty assistant history or chat noise.
- If the continuation yields tool calls → return to step 1 of the loop; if it yields body text / is not truncated → end normally; if the continuation limit is reached and the output is still truncated →
  write `TRUNCATED_MESSAGE` (a visible notice) and then end, so the loop does not exit silently.
- The first round (generated directly by the runtime, with no tool calls) is likewise handled by `_drain_truncation`; if the continuation yields
  tool calls, it enters the tool loop.
- The counter `agent._truncation_continues` is reset on every user input (inside `runtime.run`).

### 4.2 Tool Definition Output (_tool_definitions)

- Tools are output in lexicographic order by name: deterministic → an identical tool set is byte-for-byte identical across requests, which is prefix-cache friendly.
- An empty `properties` omits that field (DeepSeek rejects `[]` schemas).
- Environment probing comes first (`tools.environment.filter_tools`): related tools are disabled when the workspace/git directory cannot be obtained.
- Plan mode (`plan_mode.apply_tool_filter`): keep only read-only/information-query tools + `run_command` (read-only research) + `ask_user`.

### 4.3 Single Tool Execution (_execute_single)

`tool_service.execute(agent, name, args, tool_call_id, opts)`:

- Each tool creates a **pausable timer** (`utils.timer.create`): timing starts only when execution actually begins (approval granted/direct execution),
  and is paused while waiting for user approval or for an ask_user answer, so elapsed time and timeouts do not count the wait.
- Results/errors emit `TOOL_EXECUTION_STARTED` / `TOOL_EXECUTION_COMPLETED` / `TOOL_EXECUTION_ERROR`
  (all carrying `duration_ms`, so the collapsed text can show the elapsed time in real time).

### 4.4 Parallel Execution and Ordered Write-back

Tool calls are **executed in parallel** (`vim.schedule`), but their results are **written back to the
message queue uniformly in the original call order** after `async.all` completes (`_execute_single` does not write directly). This guarantees that the order of the tool messages matches the assistant's `tool_calls`,
keeping the API compatible and the prefix cache deterministic.

## 5. Prefix Cache (prefix.lua)

The strategy aligns with the context caching practices of deepseek-harness:

1. **The system prompt is concatenated from ordered sections**: `identity(-100) / persona(0) / tool guidance(100+)`, rendered byte-stable.
   Any change to an ordering slot or to the text invalidates the prefix cache from the first changed token onward.
2. **Tool definitions are output in lexicographic order by name** (deterministic).
3. **Cache identity (fingerprint)**: an `_fnv1a` stable hash, compared across requests. A change in identity means the prefix cache is invalidated; it is used for diagnosis and statistics.
4. **Cache usage parsing**: parses `prompt_cache_hit_tokens` / `cached_tokens`, etc. from the provider usage,
   and computes the hit rate.

System prompt sections can be registered:

- Global: `prefix.register_section(name, order, text)`.
- Agent-level: `prefix.register_agent_section(agent, name, order, text)` (shadows a global section with the same name).
  The `todo` module registers `deployment:todos` (order=100), and `plan_mode` registers `deployment:plan_policy` (order=100),
  injecting the current task list / plan policy into the system prompt respectively.

## 6. Context Compaction (core/session/compactor)

Compaction is **asynchronous in the background and non-blocking**: once the token pressure threshold is reached it starts summary generation and returns
immediately, while the agent keeps running with the current (original) request view; when the summary completes it writes a **compaction overlay**, and
subsequent requests and further compactions use the compacted replacement. It opens no floating window (it does not emit `COMPACTION_STARTED` / `COMPACTION_CHUNK`).

Triggers (all still threshold-driven):

- **Turn boundary**: `runtime.run` calls `compactor.start_background(agent, { allow_busy = true })` after appending the user message.
- **Inside the tool loop**: `tool_loop._send_round` calls `start_background(agent, { allow_busy = true })` before each round's send —
  the previous round's tool results have already been written back and the next round's request has not yet been sent. A long loop thus converges round by round.

The gate `_can_compact(agent, opts)`: invalid agent / `_compacting` / signal already aborted → refuse;
when `allow_busy` is true, the `idle` requirement is relaxed (compaction is allowed while in `generating`/`tool_running`).

Once the `context_window * threshold_ratio` threshold is reached, it first performs model-independent tool-result pruning (`tool_result_pruner`);
if pruning already gets back within the threshold, summarization is skipped. Otherwise it **folds the first round through the second-to-last round**
(keeping the last round intact); `_select_round_shadow` uses the last non-runtime `user` message as the start of the last round.
`context_window` is by default derived from the model capability table (an explicit non-default user configuration takes precedence), and models with
explicit caching automatically use a more conservative threshold/retain ratio. For concrete models, refer to [model_policy.md](model_policy.md).

- **Auxiliary summarization call**: `_summarize` replays the request-view prefix byte-for-byte (the same system prompt, tool schema, and folded-region messages),
  then appends the compaction instruction as the last user message → reusing the provider's warm prefix cache.
- **Compaction overlay**: `_apply_overlay` records `agent.compaction = { checkpoint, replaced }` — the checkpoint message and the number of replaced
  "non-runtime-snapshot" messages — and **does not modify `agent.messages`**. The checkpoint carries the `<compacted-summary>` tag.
  `context_builder.request_view(agent)` builds the request view (checkpoint + un-replaced tail) from it; `context_builder.build_from_agent` uses that view.
  On success it emits `COMPACTION_COMPLETED`.
- **Rendering and persistence still use the original context**: `agent.messages` is always the full original history and the chat UI renders it;
  `session.messages` is also the original history. The overlay lives separately in `session.metadata.compaction` and is restored by
  `chat_service.load_session`, so a reopened session still sends requests using the compacted replacement.

`maybe_compact` is kept as an awaitable version (for tests/direct calls). `force_compact` (used for overflow recovery) still **blocks and awaits**,
skipping the pressure threshold check; **it defaults to `allow_busy = true`**, ensuring that overflow recovery can actually compact both in the first
round of a turn and midway through the tool loop (`generating`/`tool_running`) — it trims first, and if trimming is already enough to get back within the
window it does not summarize; otherwise it performs one maximized balanced head reduction (retain 0, keeping only the newest indivisible unit).

## 7. Overflow Recovery (recovery.lua)

`recovery.send_stream(agent, opts, on_chunk)` wraps `request.send_stream` and is shared by the first round of a turn
(`runtime._run_generation`) and every round of the tool loop (`tool_loop._send_round`):

- When a request returns `context window exceeded` (`request.is_context_overflow`), it first calls `force_compact(agent, { allow_busy = true })`
  to compact the history, then re-requests it (the `attempt()` retry). `allow_busy = true` is key: the request has already failed due to overflow and the
  agent is still in `generating`/`tool_running`, so without relaxing the `idle` guard, compaction would be refused and the overflow error thrown directly.
- Each round of requests triggers at most one compaction recovery; on success it resets `agent._overflow_recovered = false`, allowing recovery again later.
- When there is nothing foldable, the overflow error is rethrown as-is.

## 8. Requests and Retries (request.lua)

`request.send` / `request.send_stream`:

- **Multimodal materialization**: `_prepare_messages` resolves image references in the session into protocol-neutral image blocks (`core.model.content.materialize`);
  when the model does not support images, they remain text as-is.
- **Request body construction**: via `core.model.adapter` (openai/anthropic/google) + `core.model.profiles` dialect adaptation;
  after encoding, `prompt_cache.apply_async` injects explicit caching (degrading to implicit on failure).
- **Streaming enforcement**: `send_stream` forces `stream = true`; OpenAI-compatible endpoints automatically add `stream_options.include_usage`
  (otherwise usage is unavailable and cache hits cannot be counted).
- **Retries**: `async.retry` with exponential backoff (`delay_ms=1000, backoff=2`), `max_retries` defaulting to 3.
  4xx is not retried, and abort is not retried.
- **Context overflow detection**: `_is_context_overflow` matches various provider wordings (`context_length`,
  `prompt is too long`, `too many tokens`, etc.), mainly keying on 400/413/429.

## 9. Related Documents

- [EVENTS.md](EVENTS.md): event constants and data.
- [tool_system.md](tool_system.md): the tool system (`tool_loop` depends on `tool_service`).
- [sub_agent_system.md](sub_agent_system.md): sub-agents (`runtime.spawn`).
- [configuration.md](configuration.md): configuration such as `ai.context_cache` / `ai.reasoning_enabled`.
- [model_policy.md](model_policy.md): automatic selection by model (protocol dialect / capability table / explicit caching / token-saving techniques).
