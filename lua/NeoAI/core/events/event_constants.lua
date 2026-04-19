-- NeoAI 事件常量定义
-- 直接使用 Neovim 原生事件系统

local M = {}

-- AI 生成事件
M.GENERATION_STARTED = "NeoAI:generation_started"
M.GENERATION_COMPLETED = "NeoAI:generation_completed"
M.GENERATION_ERROR = "NeoAI:generation_error"
M.GENERATION_CANCELLED = "NeoAI:generation_cancelled"

-- 流式处理事件
M.STREAM_CHUNK = "NeoAI:stream_chunk"
M.STREAM_STARTED = "NeoAI:stream_started"
M.STREAM_COMPLETED = "NeoAI:stream_completed"
M.STREAM_ERROR = "NeoAI:stream_error"

-- 推理事件
M.REASONING_CONTENT = "NeoAI:reasoning_content"
M.REASONING_STARTED = "NeoAI:reasoning_started"
M.REASONING_COMPLETED = "NeoAI:reasoning_completed"

-- 工具相关事件
M.TOOL_LOOP_STARTED = "NeoAI:tool_loop_started"
M.TOOL_LOOP_FINISHED = "NeoAI:tool_loop_finished"
M.TOOL_EXECUTION_STARTED = "NeoAI:tool_execution_started"
M.TOOL_EXECUTION_COMPLETED = "NeoAI:tool_execution_completed"
M.TOOL_EXECUTION_ERROR = "NeoAI:tool_execution_error"
M.TOOL_CALL_DETECTED = "NeoAI:tool_call_detected"
M.TOOL_RESULT_RECEIVED = "NeoAI:tool_result_received"

-- 会话事件
M.SESSION_CREATED = "NeoAI:session_created"
M.SESSION_REUSED = "NeoAI:session_reused"
M.SESSION_LOADED = "NeoAI:session_loaded"
M.SESSION_SAVED = "NeoAI:session_saved"
M.SESSION_DELETED = "NeoAI:session_deleted"
M.SESSION_CHANGED = "NeoAI:session_changed"

-- 分支事件
M.BRANCH_CREATED = "NeoAI:branch_created"
M.BRANCH_SWITCHED = "NeoAI:branch_switched"
M.BRANCH_DELETED = "NeoAI:branch_deleted"

-- 消息事件
M.MESSAGE_ADDED = "NeoAI:message_added"
M.MESSAGE_EDITED = "NeoAI:message_edited"
M.MESSAGE_DELETED = "NeoAI:message_deleted"
M.MESSAGE_UPDATED = "NeoAI:message_updated"

-- UI 事件
M.CHAT_WINDOW_OPENED = "NeoAI:chat_window_opened"
M.CHAT_WINDOW_CLOSED = "NeoAI:chat_window_closed"
M.TREE_WINDOW_OPENED = "NeoAI:tree_window_opened"
M.TREE_WINDOW_CLOSED = "NeoAI:tree_window_closed"
M.WINDOW_MODE_CHANGED = "NeoAI:window_mode_changed"

-- 配置事件
M.CONFIG_LOADED = "NeoAI:config_loaded"
M.CONFIG_CHANGED = "NeoAI:config_changed"

-- 状态事件
M.PLUGIN_INITIALIZED = "NeoAI:plugin_initialized"
M.PLUGIN_SHUTDOWN = "NeoAI:plugin_shutdown"

-- 备份事件
M.BACKUP_CREATED = "NeoAI:backup_created"
M.BACKUP_RESTORED = "NeoAI:backup_restored"

-- 响应构建事件
M.RESPONSE_BUILT = "NeoAI:response_built"

-- 日志事件
M.LOG_DEBUG = "NeoAI:log_debug"
M.LOG_INFO = "NeoAI:log_info"
M.LOG_WARN = "NeoAI:log_warn"
M.LOG_ERROR = "NeoAI:log_error"
M.AI_RESPONSE_CHUNK = "NeoAI:ai_response_chunk"
M.AI_RESPONSE_COMPLETE = "NeoAI:ai_response_complete"
M.AI_RESPONSE_ERROR = "NeoAI:ai_response_error"

-- 自定义事件
M.SEND_MESSAGE = "NeoAI:send_message"
M.CLOSE_WINDOW = "NeoAI:close_window"

-- 消息事件（补充）
M.MESSAGES_CLEARED = "NeoAI:messages_cleared"
M.MESSAGES_BUILT = "NeoAI:messages_built"

return M

