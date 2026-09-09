--- NeoAI 事件常量注册表
--- @module NeoAI.kernel.events
--- 事件名规范：domain:verb（如 "agent:spawn"、"stream:chunk"）。
--- 所有模块通过引用常量触发/监听事件，禁止硬编码事件字符串。

local M = {}

-- ========== Agent 生命周期 ==========
M.AGENT_CREATED = "agent:created"
M.AGENT_SPAWNED = "agent:spawned"
M.AGENT_DISPOSED = "agent:disposed"
M.AGENT_ABORTED = "agent:aborted"
M.AGENT_STATE_CHANGED = "agent:state_changed"

-- ========== 生成 / 流式 ==========
M.GENERATION_STARTED = "generation:started"
M.GENERATION_COMPLETED = "generation:completed"
M.GENERATION_ERROR = "generation:error"
M.GENERATION_CANCELLED = "generation:cancelled"
M.STREAM_STARTED = "stream:started"
M.STREAM_CHUNK = "stream:chunk"
M.STREAM_COMPLETED = "stream:completed"
M.STREAM_ERROR = "stream:error"

-- ========== 推理 ==========
M.REASONING_STARTED = "reasoning:started"
M.REASONING_CHUNK = "reasoning:chunk"
M.REASONING_COMPLETED = "reasoning:completed"

-- ========== 消息 ==========
M.MESSAGE_ADDED = "message:added"
M.MESSAGE_UPDATED = "message:updated"
M.MESSAGE_EDITED = "message:edited"
M.MESSAGE_DELETED = "message:deleted"
M.MESSAGE_SENT = "message:sent"
M.MESSAGE_QUEUED = "message:queued"
M.MESSAGES_CLEARED = "messages:cleared"

-- ========== 会话 ==========
M.SESSION_CREATED = "session:created"
M.SESSION_LOADED = "session:loaded"
M.SESSION_SAVED = "session:saved"
M.SESSION_DELETED = "session:deleted"
M.SESSION_SWITCHED = "session:switched"
M.SESSION_RENAMED = "session:renamed"
M.SESSION_FORKED = "session:forked"

-- ========== 分支 / 树 ==========
M.BRANCH_CREATED = "branch:created"
M.BRANCH_DELETED = "branch:deleted"
M.TREE_REFRESHED = "tree:refreshed"

-- ========== 工具 ==========
M.TOOL_LOOP_STARTED = "tool_loop:started"
M.TOOL_LOOP_FINISHED = "tool_loop:finished"
M.TOOL_LOOP_LIMIT_REACHED = "tool_loop:limit_reached"
M.TOOL_EXECUTION_STARTED = "tool:execution_started"
M.TOOL_EXECUTION_COMPLETED = "tool:execution_completed"
M.TOOL_EXECUTION_ERROR = "tool:execution_error"
M.TOOL_CALL_DETECTED = "tool:call_detected"
M.TOOL_APPROVAL_REQUESTED = "tool:approval_requested"
M.TOOL_APPROVED = "tool:approved"
M.TOOL_APPROVAL_CANCELLED = "tool:approval_cancelled"
M.TOOL_RESULT_RECEIVED = "tool:result_received"
M.TOOL_LOOP_GUARD_REMINDER = "tool_loop:guard_reminder"
M.AUTO_MODE_CHANGED = "approval_mode:auto_changed"

-- ========== 用户提问（ask_user） ==========
-- 开始等待用户回答时触发（agent 处于 blocked 候选），回答/取消后触发 answered。
M.ASK_USER_WAITING = "ask_user:waiting"
M.ASK_USER_ANSWERED = "ask_user:answered"

-- ========== 工具参数接收（流式） ==========
-- 模型流式生成工具调用参数时逐片触发（携带当前累积的 tool_calls 快照），
-- 参数流结束触发 completed。UI 用它像推理悬浮窗一样实时展示"接收参数"悬浮窗。
M.TOOL_ARG_CHUNK = "tool:arg_chunk"
M.TOOL_ARG_COMPLETED = "tool:arg_completed"

-- ========== 待办 / 计划模式 ==========
M.TODO_UPDATED = "todo:updated"
M.PLAN_MODE_CHANGED = "plan_mode:changed"

-- ========== 模型 ==========
M.MODELS_UPDATED = "models:updated"
M.MODEL_SWITCHED = "model:switched"
M.MODEL_REFRESH_STARTED = "models:refresh_started"
M.MODEL_REFRESH_FAILED = "models:refresh_failed"

-- ========== UI / 窗口 ==========
M.WINDOW_OPENED = "window:opened"
M.WINDOW_CLOSED = "window:closed"
M.UI_REFRESHED = "ui:refreshed"
M.UI_MODE_CHANGED = "ui:mode_changed"
M.DISPLAY_MODE_CHANGED = "display:mode_changed"

-- ========== 子 Agent ==========
M.SUB_AGENT_CREATED = "sub_agent:created"
M.SUB_AGENT_UPDATED = "sub_agent:updated"
M.SUB_AGENT_COMPLETED = "sub_agent:completed"
M.SUB_AGENT_ERROR = "sub_agent:error"
M.SUB_AGENT_RESULT_READY = "sub_agent:result_ready"

-- ========== 配置 / 生命周期 ==========
M.CONFIG_LOADED = "config:loaded"
M.CONFIG_CHANGED = "config:changed"
M.PLUGIN_INITIALIZED = "plugin:initialized"
M.PLUGIN_SHUTDOWN = "plugin:shutdown"

-- ========== MCP ==========
M.MCP_CONNECTING = "mcp:connecting"
M.MCP_READY = "mcp:ready"
M.MCP_ERROR = "mcp:error"
M.MCP_DISCONNECTED = "mcp:disconnected"
M.MCP_TOOLS_UPDATED = "mcp:tools_updated"

-- ========== Skills ==========
M.SKILLS_UPDATED = "skills:updated"

-- ========== 日志 ==========
M.LOG_MESSAGE = "log:message"

-- ========== 上下文压缩 ==========
M.COMPACTION_STARTED = "compaction:started"
M.COMPACTION_COMPLETED = "compaction:completed"
M.PLAN_DISTILLED = "plan_distilled"

return M
