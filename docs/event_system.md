# Event System Reference

NeoAI uses Neovim's User autocommand mechanism for event-driven communication
between components. All events are defined as constants in core/events.lua.
Components emit events via `vim.api.nvim_exec_autocmds("User", { pattern, data })`
and listen via `vim.api.nvim_create_autocmd("User", { pattern, callback })`.

## Event Categories

### AI Generation Events

| Constant | Pattern |
|----------|---------|
| `GENERATION_STARTED` | `NeoAI:generation_started` |
| `GENERATION_COMPLETED` | `NeoAI:generation_completed` |
| `GENERATION_ERROR` | `NeoAI:generation_error` |
| `GENERATION_CANCELLED` | `NeoAI:generation_cancelled` |
| `GENERATION_RETRYING` | `NeoAI:generation_retrying` |
| `CANCEL_GENERATION` | `NeoAI:cancel_generation` |

### Stream Processing Events

| Constant | Pattern |
|----------|---------|
| `STREAM_STARTED` | `NeoAI:stream_started` |
| `STREAM_CHUNK` | `NeoAI:stream_chunk` |
| `STREAM_COMPLETED` | `NeoAI:stream_completed` |
| `STREAM_ERROR` | `NeoAI:stream_error` |

### Reasoning Events

| Constant | Pattern |
|----------|---------|
| `REASONING_CONTENT` | `NeoAI:reasoning_content` |
| `REASONING_STARTED` | `NeoAI:reasoning_started` |
| `REASONING_COMPLETED` | `NeoAI:reasoning_completed` |

### Tool System Events

| Constant | Pattern |
|----------|---------|
| `TOOL_LOOP_STARTED` | `NeoAI:tool_loop_started` |
| `TOOL_LOOP_FINISHED` | `NeoAI:tool_loop_finished` |
| `TOOL_EXECUTION_STARTED` | `NeoAI:tool_execution_started` |
| `TOOL_EXECUTION_COMPLETED` | `NeoAI:tool_execution_completed` |
| `TOOL_EXECUTION_ERROR` | `NeoAI:tool_execution_error` |
| `TOOL_EXECUTION_SUBSTEP` | `NeoAI:tool_execution_substep` |
| `TOOL_CALL_DETECTED` | `NeoAI:tool_call_detected` |
| `TOOL_RESULT_RECEIVED` | `NeoAI:tool_result_received` |
| `TOOL_DISPLAY_CLOSED` | `NeoAI:tool_display_closed` |
| `TOOL_DISPLAY_RESIZED` | `NeoAI:tool_display_resized` |
| `TOOL_APPROVED` | `NeoAI:tool_approved` |
| `TOOL_APPROVAL_CANCELLED` | `NeoAI:tool_approval_cancelled` |
| `TOOL_APPROVAL_CONFIG_CHANGED` | `NeoAI:tool_approval_config_changed` |

### Session Events

| Constant | Pattern |
|----------|---------|
| `SESSION_CREATED` | `NeoAI:session_created` |
| `SESSION_REUSED` | `NeoAI:session_reused` |
| `SESSION_LOADED` | `NeoAI:session_loaded` |
| `SESSION_SAVED` | `NeoAI:session_saved` |
| `SESSION_DELETED` | `NeoAI:session_deleted` |
| `SESSION_CHANGED` | `NeoAI:session_changed` |
| `SESSION_RENAMED` | `NeoAI:session_renamed` |

### Branch Events

| Constant | Pattern |
|----------|---------|
| `BRANCH_CREATED` | `NeoAI:branch_created` |
| `BRANCH_SWITCHED` | `NeoAI:branch_switched` |
| `BRANCH_DELETED` | `NeoAI:branch_deleted` |

### Tree Node Events

| Constant | Pattern |
|----------|---------|
| `ROOT_BRANCH_CREATED` | `NeoAI:root_branch_created` |
| `SUB_BRANCH_CREATED` | `NeoAI:sub_branch_created` |
| `CONVERSATION_ROUND_CREATED` | `NeoAI:conversation_round_created` |
| `MESSAGE_CREATED` | `NeoAI:message_created` |
| `NODE_DELETED` | `NeoAI:node_deleted` |
| `NODE_RENAMED` | `NeoAI:node_renamed` |
| `NODE_MOVED` | `NeoAI:node_moved` |

### Message Events

| Constant | Pattern |
|----------|---------|
| `MESSAGE_ADDED` | `NeoAI:message_added` |
| `MESSAGE_ADDING` | `NeoAI:message_adding` |
| `MESSAGE_EDITED` | `NeoAI:message_edited` |
| `MESSAGE_DELETED` | `NeoAI:message_deleted` |
| `MESSAGE_UPDATED` | `NeoAI:message_updated` |
| `MESSAGE_SENT` | `NeoAI:message_sent` |
| `MESSAGES_CLEARED` | `NeoAI:messages_cleared` |
| `MESSAGES_BUILT` | `NeoAI:messages_built` |
| `FORMATTED_MESSAGE_SENT` | `NeoAI:formatted_message_sent` |

### Window/UI Events

| Constant | Pattern |
|----------|---------|
| `CHAT_WINDOW_OPENED` | `NeoAI:chat_window_opened` |
| `CHAT_WINDOW_CLOSED` | `NeoAI:chat_window_closed` |
| `TREE_WINDOW_OPENED` | `NeoAI:tree_window_opened` |
| `TREE_WINDOW_CLOSED` | `NeoAI:tree_window_closed` |
| `WINDOW_MODE_CHANGED` | `NeoAI:window_mode_changed` |
| `WINDOW_OPENING` | `NeoAI:window_opening` |
| `WINDOW_OPENED` | `NeoAI:window_opened` |
| `WINDOW_CLOSING` | `NeoAI:window_closing` |
| `WINDOW_CLOSED` | `NeoAI:window_closed` |
| `CHAT_BOX_OPENED` | `NeoAI:chat_box_opened` |
| `CHAT_BOX_CLOSING` | `NeoAI:chat_box_closing` |
| `CHAT_BOX_CLOSED` | `NeoAI:chat_box_closed` |

### Rendering Events

| Constant | Pattern |
|----------|---------|
| `DIALOGUE_RENDERING_START` | `NeoAI:dialogue_rendering_start` |
| `DIALOGUE_RENDERING_COMPLETE` | `NeoAI:dialogue_rendering_complete` |
| `RENDERING_COMPLETE` | `NeoAI:rendering_complete` |
| `TREE_RENDERING_START` | `NeoAI:tree_rendering_start` |
| `TREE_RENDERING_COMPLETE` | `NeoAI:tree_rendering_complete` |

### Floating Text Events

| Constant | Pattern |
|----------|---------|
| `FLOATING_TEXT_SHOWING` | `NeoAI:floating_text_showing` |
| `FLOATING_TEXT_SHOWN` | `NeoAI:floating_text_shown` |
| `FLOATING_TEXT_CLOSING` | `NeoAI:floating_text_closing` |
| `FLOATING_TEXT_CLOSED` | `NeoAI:floating_text_closed` |

### Model Switch Events

| Constant | Pattern |
|----------|---------|
| `MODEL_SWITCHED` | `NeoAI:model_switched` |

### Config Events

| Constant | Pattern |
|----------|---------|
| `CONFIG_LOADED` | `NeoAI:config_loaded` |
| `CONFIG_CHANGED` | `NeoAI:config_changed` |

### Plugin State Events

| Constant | Pattern |
|----------|---------|
| `PLUGIN_INITIALIZED` | `NeoAI:plugin_initialized` |
| `PLUGIN_SHUTDOWN` | `NeoAI:plugin_shutdown` |

### Backup Events

| Constant | Pattern |
|----------|---------|
| `BACKUP_CREATED` | `NeoAI:backup_created` |
| `BACKUP_RESTORED` | `NeoAI:backup_restored` |

### Response/Request Events

| Constant | Pattern |
|----------|---------|
| `RESPONSE_BUILT` | `NeoAI:response_built` |
| `REQUEST_BUILT` | `NeoAI:request_built` |

### Log Events

| Constant | Pattern |
|----------|---------|
| `LOG_DEBUG` | `NeoAI:log_debug` |
| `LOG_INFO` | `NeoAI:log_info` |
| `LOG_WARN` | `NeoAI:log_warn` |
| `LOG_ERROR` | `NeoAI:log_error` |
| `AI_RESPONSE_CHUNK` | `NeoAI:ai_response_chunk` |
| `AI_RESPONSE_COMPLETE` | `NeoAI:ai_response_complete` |
| `AI_RESPONSE_ERROR` | `NeoAI:ai_response_error` |

### Command Events

| Constant | Pattern |
|----------|---------|
| `SEND_MESSAGE` | `NeoAI:send_message` |
| `CLOSE_WINDOW` | `NeoAI:close_window` |

### Chat Message Flow Events

| Constant | Pattern |
|----------|---------|
| `USER_MESSAGE_READY` | `NeoAI:user_message_ready` |
| `USER_MESSAGE_SENDING` | `NeoAI:user_message_sending` |
| `USER_MESSAGE_SENT` | `NeoAI:user_message_sent` |
| `AI_RESPONSE_READY` | `NeoAI:ai_response_ready` |
| `AI_RESPONSE_RECEIVED` | `NeoAI:ai_response_received` |
| `CHAT_INPUT_READY` | `NeoAI:chat_input_ready` |

### History Events

| Constant | Pattern |
|----------|---------|
| `ROUND_ADDED` | `NeoAI:round_added` |
| `ORPHANS_CLEANED` | `NeoAI:orphans_cleaned` |
| `HISTORY_SAVE_FINAL` | `NeoAI:history_save_final` |

### UI Internal Events

| Constant | Pattern |
|----------|---------|
| `UI_SESSION_UPDATED` | `NeoAI:ui_session_updated` |

## Event Data Structures

**GENERATION_STARTED:**

```lua
{ generation_id, formatted_messages, request, session_id, window_id, is_tool_loop?, is_final_round? }
```

**GENERATION_COMPLETED:**

```lua
{ generation_id, response, reasoning_text, usage, session_id, window_id, duration }
```

**GENERATION_ERROR:**

```lua
{ generation_id, error_msg, session_id, window_id }
```

**GENERATION_CANCELLED:**

```lua
{ generation_id, session_id, window_id, usage }
```

**GENERATION_RETRYING:**

```lua
{ generation_id, retry_count, max_retries, reason, session_id, window_id, layer? }
```

**STREAM_CHUNK:**

```lua
{ generation_id, chunk, session_id, window_id, is_final }
```

**STREAM_COMPLETED:**

```lua
{ generation_id, full_response, reasoning_text, usage, session_id, window_id }
```

**REASONING_CONTENT:**

```lua
{ generation_id, reasoning_content, session_id, window_id }
```

**TOOL_LOOP_STARTED:**

```lua
{ generation_id, tool_calls, tool_packs, pack_order, session_id, window_id, iteration }
```

**TOOL_EXECUTION_STARTED:**

```lua
{ tool_name, pack_name, args, start_time, session_id, window_id, generation_id }
```

**TOOL_EXECUTION_COMPLETED:**

```lua
{ tool_name, pack_name, args, result, duration, session_id }
```

**TOOL_EXECUTION_ERROR:**

```lua
{ tool_name, pack_name, args, error_msg, duration, session_id }
```

**TOOL_CALL_DETECTED:**

```lua
{ generation_id, tool_calls, tool_calls_delta?, session_id, window_id }
```

**TOOL_RESULT_RECEIVED:**

```lua
{ generation_id, tool_results, session_id, window_id, messages, options, model_index,
  ai_preset, is_final_round, accumulated_usage, last_reasoning, _sub_agent_id? }
```

**SESSION_CREATED:**

```lua
{ session_id, session }
```

**SESSION_LOADED:**

```lua
{ session_count, latest_session_id }
```

**SESSION_DELETED:**

```lua
{ session_id }
```

**SESSION_CHANGED:**

```lua
{ session_id }
```

**SESSION_RENAMED:**

```lua
{ session_id, name }
```

**MESSAGE_SENT:**

```lua
{ session_id, window_id, role, message }
```

**CHAT_WINDOW_OPENED / TREE_WINDOW_OPENED:**

```lua
{ session_id, branch_id }
```

**UI_SESSION_UPDATED:**

```lua
{ session_id }
```

## Event Flow Diagrams

### Generation Flow

```text
USER_MESSAGE_SENT
     |
GENERATION_STARTED
     |
STREAM_STARTED
     |
STREAM_CHUNK (repeated)
REASONING_CONTENT (throttled)
TOOL_CALL_DETECTED (if tool calls)
     |
STREAM_COMPLETED
     |
(if abnormal) GENERATION_RETRYING -> STREAM_STARTED
     |
(if tool calls) TOOL_LOOP_STARTED
     |
TOOL_EXECUTION_STARTED (per tool)
TOOL_EXECUTION_COMPLETED (per tool)
TOOL_EXECUTION_ERROR (on error)
     |
TOOL_LOOP_FINISHED
     |
TOOL_RESULT_RECEIVED -> GENERATION_STARTED (next iteration)
     |
(no tool calls) GENERATION_COMPLETED
```

### Cancel Flow

```text
CANCEL_GENERATION
     |
GENERATION_CANCELLED
     |
(cleanup) HTTP requests cancelled, tool loops stopped
```
