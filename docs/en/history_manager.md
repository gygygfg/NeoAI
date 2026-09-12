# NeoAI Session System (v3.0)

> [中文](../history_manager.md) | **English**

> The session system manages conversation history and supports **branch trees**, **append-only JSONL persistence**, **context building**, and **context compaction**.
> Corresponding source: `lua/NeoAI/core/session/*`.

## 1. Module Structure

| Module | Responsibility |
| --- | --- |
| `core/session/session.lua` | Session object (pure data + methods), with fields `id / parent_id / root_id / created_at / updated_at / model / messages / metadata`. Forks branches. |
| `core/session/session_store.lua` | Session persistence: append-only JSONL + `.bak` backup + torn-line repair; CRUD + chain traversal via get_chain/get_downstream. |
| `core/session/context_builder.lua` | Builds the context messages sent to the model from a session/Agent (including system rendering and tool-call protocol handling). |
| `core/session/tool_result_pruner.lua` | Model-agnostic tool-result pruning: before summarization, trims oversized tool results into a "head + omission marker + tail" form. |
| `core/session/compactor.lua` | Context compaction: collapses old history when the pressure threshold is reached, helper summarization (prefix-cache reuse), checkpoint replacement. |

## 2. Session Object (session.lua)

A session is a pure data structure with no side effects and no I/O:

```
{ id, parent_id, root_id, created_at, updated_at, model,
  messages = { { role, content, reasoning?, tool_calls?, tool_call_id?, ts, checkpoint? } },
  metadata = { name?, tags?, usage? } }
```

- `parent_id`: the parent session id (nil for a root session).
- `root_id`: the root session id (when a child session does not specify one explicitly, the parent is used as the root).
- `fork(session, {copy_messages})`: derives a new session (`parent_id = session.id`).
- Message operations: `add_message` / `get_message` / `update_message` / `delete_message` / `trim_messages` /
  `clear_messages`.
- `add_usage`: accumulates usage (prompt/completion).

## 3. Session Persistence (session_store.lua)

**Append-only JSONL**: each write appends a single line of JSON, with no need to parse the entire file; crash recovery only requires truncating the last incomplete line.

- `_session_path()`: `session.save_path / session.file` (default `~/.cache/NeoAI/sessions.jsonl`).
- **init**: reads JSONL line by line, repairs its tail (`fs.repair_jsonl`), and deserializes only the latest snapshot of each session.
- **persist(session)** / **update(session)**: append one session snapshot, returning `true` or `false, err`; compact redundant snapshots when thresholds are reached.
- **save_all()**: writes a same-directory temporary file, fsyncs it, backs up the old file to `.bak`, then renames the temporary file over the destination. Returns `false, err` on failure without truncating the destination.
- **delete(session_id)**: deletes the target and its direct children. Deeper descendants are reparented to the nearest surviving ancestor, or promoted to roots, with subtree `root_id` values updated. Memory changes and deletion events are committed only after saving succeeds; failure returns `{}, err`.
- **get_chain(session_id)**: the ancestor chain from the root to the specified session (including itself, root first).
- **get_downstream(session_id)**: the single-child chain descending through the session tree. It only continues deeper when there is exactly one child session;
  it stops at a split branch (multiple child sessions) or at the end. Used to reconstruct the full linear conversation.

### 3.1 Torn-Line Recovery

`fs.repair_jsonl` repairs a truncated/torn last line before reading, ensuring the next startup after a crash loads correctly.
If a complete JSON record lacks its final newline, the separator is restored before further appends. Chat messages are marked `_synced` only after saving succeeds; failed saves retain their in-memory content for retry.

### 3.2 Log Compaction

```lua
session = {
  log_compaction = {
    enabled = true,
    max_redundant_records = 64,
    min_bytes = 8 * 1024 * 1024,
  },
}
```

Once there are 64 redundant snapshots, or the log reaches 8 MiB and is at least twice the total size of the latest snapshots, it is atomically rewritten to one snapshot per session.
Compaction failure preserves the successfully appended records and retries on a subsequent persist. This reclaims old disk versions without compressing or deleting conversation messages.

## 4. Context Building (context_builder.lua)

`context_builder.build(session)` / `build_from_agent(agent)`:

- The first message is system (rendered by `prefix.build_system_prompt`).
- History truncation: keeps the most recent `session.max_history_per_session` (default 1000) non-system messages.
- **Tool-call protocol**: for an assistant message with `tool_calls`, `content` must be `null` (or omitted);
  sending `content:""` is treated as a malformed format by models that enforce strict validation.
- **Reasoning content is not sent back with history**: `reasoning_content` is not written into API messages; the internal `message.reasoning` is used only for rendering.
  This avoids re-sending the entire chain of thought and invalidating the DeepSeek prefix cache starting from that assistant message.
- `build_prefix(agent, range_messages)`: builds the compaction replay prefix (system + the specified range), so that helper summarization calls can reuse the prefix cache.
- `build_fork_context(session, task)`: the initial context for a child session derived from a parent session.
- `estimate_tokens(messages)`: rough token estimate (characters/4).

## 5. Context Compaction (compactor.lua)

The strategy aligns with deepseek-harness compaction:

1. **Triggering**: in two places.
   - **Turn boundary**: `runtime.run` calls `maybe_compact(agent)` before a new step (requires `idle`).
   - **Inside the tool loop**: `tool_loop._send_round` calls `maybe_compact(agent, { allow_busy = true })` before sending each round;
     overflow recovery (`recovery`) calls `force_compact(agent, { allow_busy = true })`. Both relax the `idle` requirement,
     because at that moment the previous round's tool results have already been written back and the next request has not been sent yet (or the request has already failed due to overflow), so there are no concurrent writes.
   Compaction occurs when the estimated token count reaches the `context_window * threshold_ratio` threshold.
2. **Model-agnostic pruning**: first `tool_result_pruner.prune_agent` trims oversized tool results into a
   "head + omission marker + tail" form (`prune_threshold_chars` / `prune_head_chars` / `prune_tail_chars`);
   results containing image references are skipped. If after pruning the count is already back within the threshold, it ends directly without a summarization call; if any pruning occurred, stale API usage is invalidated.
3. **Selecting the collapse range**: `_select_shadow_range` collapses the earliest contiguous block of history, keeping a recent tail (`retain_ratio` budget,
   with a floor of `retain_min_tokens` and at least `min_shadow_messages` messages). The cut point must maintain **tool pairing balance**:
   move the cut point forward until it no longer splits an `assistant.tool_calls` from its `tool` results, otherwise the post-compaction request will be rejected by the API.
4. **Helper summarization**: `_summarize` replays the session prefix byte-for-byte (the same system prompt, tool schema, and messages in the collapsed region),
   then appends the compaction instruction as the last user message → reusing the provider's hot prefix cache.
5. **Checkpoint replacement**: generates a checkpoint user message tagged with `<compacted-summary>` that **replaces the collapsed range**
   (`_replace_with_checkpoint`), and records:
   - `replaced_count`: the number of replaced messages (for display/statistics);
   - `replaced_synced_count`: the number among them that are **already persisted (`_synced`)**. At a turn-boundary compaction the two are equal;
     when compacting mid-tool-loop, the messages added during the current turn have not been persisted yet, so this value is smaller than `replaced_count`.

   `chat_service._persist_agent` uses **`replaced_synced_count`** (falling back to `replaced_count` when absent, for compatibility
   with old data) to remove synced old messages from the head/tail of the durable surface, **ensuring that the previous turn's history is not deleted by mistake**.
6. **Convergence retries**: when the count is still above the threshold after summarization, it continues collapsing earlier ranges according to `compaction_retries`.

`force_compact` (used for overflow recovery) skips the pressure-threshold check, and **defaults to `allow_busy = true`**; it prunes first, and if pruning is already enough to get back within
the window it does not summarize again; otherwise it performs a single maximally aggressive balanced head reduction (retain 0, keeping only the newest indivisible unit).

## 6. Session Tree and Branching

Sessions express their tree structure through `parent_id` / `root_id`. When a session is opened from the tree UI, `chat_service.load_session`
extends upward along `get_chain` (ancestors) to the first turn, then downward along `get_downstream` (the single-child chain) to a split branch or the end,
assembling the full linear conversation (`_build_chain_messages`), so that opening only the selected session does not lose branch context.

## 7. Related Documents

- [configuration.md](configuration.md): `session.*` configuration (save_path / max_history_per_session / file).
- [ai_engine.md](ai_engine.md): the role of `context_builder` / `compactor` in the generation flow.
- [EVENTS.md](EVENTS.md): session events (`SESSION_*`).
