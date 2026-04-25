-- NeoAI 事件常量定义
-- 所有事件统一在此定义，各模块通过引用常量使用，禁止硬编码事件字符串
-- 命名规范：按功能分组，常量名 = 事件用途（大写+下划线）

local M = {}

-- ==================== AI 生成事件 ====================
-- 使用位置: ai_engine.lua, chat_window.lua, chat_handlers.lua
M.GENERATION_STARTED = "NeoAI:generation_started" -- AI 开始生成响应
M.GENERATION_COMPLETED = "NeoAI:generation_completed" -- AI 生成完成（含完整响应）
M.GENERATION_ERROR = "NeoAI:generation_error" -- AI 生成出错
M.GENERATION_CANCELLED = "NeoAI:generation_cancelled" -- AI 生成被取消
M.CANCEL_GENERATION = "NeoAI:cancel_generation" -- 请求取消当前生成

-- ==================== 流式处理事件 ====================
-- 使用位置: ai_engine.lua, chat_window.lua, chat_handlers.lua
M.STREAM_STARTED = "NeoAI:stream_started" -- 流式请求开始
M.STREAM_CHUNK = "NeoAI:stream_chunk" -- 流式数据块到达
M.STREAM_COMPLETED = "NeoAI:stream_completed" -- 流式处理完成
M.STREAM_ERROR = "NeoAI:stream_error" -- 流式处理出错（当前未使用）

-- ==================== 推理/思考事件 ====================
-- 使用位置: ai_engine.lua, reasoning_manager.lua, chat_window.lua
M.REASONING_CONTENT = "NeoAI:reasoning_content" -- 思考内容到达
M.REASONING_STARTED = "NeoAI:reasoning_started" -- 思考过程开始
M.REASONING_COMPLETED = "NeoAI:reasoning_completed" -- 思考过程完成

-- ==================== 工具相关事件 ====================
-- 使用位置: ai_engine.lua, tool_orchestrator.lua, tool_executor.lua
M.TOOL_LOOP_STARTED = "NeoAI:tool_loop_started" -- 工具循环开始
M.TOOL_LOOP_FINISHED = "NeoAI:tool_loop_finished" -- 工具循环结束
M.TOOL_EXECUTION_STARTED = "NeoAI:tool_execution_started" -- 单个工具开始执行
M.TOOL_EXECUTION_COMPLETED = "NeoAI:tool_execution_completed" -- 单个工具执行完成
M.TOOL_EXECUTION_ERROR = "NeoAI:tool_execution_error" -- 单个工具执行出错
M.TOOL_CALL_DETECTED = "NeoAI:tool_call_detected" -- 检测到工具调用
M.TOOL_RESULT_RECEIVED = "NeoAI:tool_result_received" -- 工具结果已接收

-- ==================== 会话事件 ====================
-- 使用位置: session_manager.lua, history_manager.lua, ui/init.lua
M.SESSION_CREATED = "NeoAI:session_created" -- 会话创建
M.SESSION_REUSED = "NeoAI:session_reused" -- 会话复用
M.SESSION_LOADED = "NeoAI:session_loaded" -- 会话加载
M.SESSION_SAVED = "NeoAI:session_saved" -- 会话保存
M.SESSION_DELETED = "NeoAI:session_deleted" -- 会话删除
M.SESSION_CHANGED = "NeoAI:session_changed" -- 当前会话切换
M.SESSION_RENAMED = "NeoAI:session_renamed" -- 会话重命名

-- ==================== 分支事件 ====================
-- 使用位置: ui/init.lua, branch_manager.lua
M.BRANCH_CREATED = "NeoAI:branch_created" -- 分支创建
M.BRANCH_SWITCHED = "NeoAI:branch_switched" -- 分支切换
M.BRANCH_DELETED = "NeoAI:branch_deleted" -- 分支删除

-- ==================== 树节点事件 ====================
-- 使用位置: tree_manager.lua
M.ROOT_BRANCH_CREATED = "NeoAI:root_branch_created" -- 根分支创建
M.SUB_BRANCH_CREATED = "NeoAI:sub_branch_created" -- 子分支创建
M.CONVERSATION_ROUND_CREATED = "NeoAI:conversation_round_created" -- 对话轮次创建
M.MESSAGE_CREATED = "NeoAI:message_created" -- 消息节点创建
M.NODE_DELETED = "NeoAI:node_deleted" -- 节点删除
M.NODE_RENAMED = "NeoAI:node_renamed" -- 节点重命名
M.NODE_MOVED = "NeoAI:node_moved" -- 节点移动

-- ==================== 消息事件 ====================
-- 使用位置: message_manager.lua, chat_window.lua, session_manager.lua, reasoning_manager.lua
M.MESSAGE_ADDED = "NeoAI:message_added" -- 消息已添加
M.MESSAGE_ADDING = "NeoAI:message_adding" -- 消息正在添加（chat_window.lua）
M.MESSAGE_EDITED = "NeoAI:message_edited" -- 消息已编辑
M.MESSAGE_DELETED = "NeoAI:message_deleted" -- 消息已删除
M.MESSAGE_UPDATED = "NeoAI:message_updated" -- 消息已更新
M.MESSAGE_SENT = "NeoAI:message_sent" -- 消息已发送
M.MESSAGES_CLEARED = "NeoAI:messages_cleared" -- 消息已清空
M.MESSAGES_BUILT = "NeoAI:messages_built" -- 消息已构建（当前未使用）
M.FORMATTED_MESSAGE_SENT = "NeoAI:formatted_message_sent" -- 格式化消息已发送（当前未使用）

-- ==================== 窗口/UI 事件 ====================
-- 使用位置: chat_window.lua, ui/init.lua, window_manager.lua
M.CHAT_WINDOW_OPENED = "NeoAI:chat_window_opened" -- 聊天窗口打开
M.CHAT_WINDOW_CLOSED = "NeoAI:chat_window_closed" -- 聊天窗口关闭
M.TREE_WINDOW_OPENED = "NeoAI:tree_window_opened" -- 树窗口打开
M.TREE_WINDOW_CLOSED = "NeoAI:tree_window_closed" -- 树窗口关闭
M.WINDOW_MODE_CHANGED = "NeoAI:window_mode_changed" -- 窗口模式切换（当前未使用）
M.WINDOW_OPENING = "NeoAI:window_opening" -- 窗口正在打开（chat_window.lua）
M.WINDOW_OPENED = "NeoAI:window_opened" -- 窗口已打开（chat_window.lua）
M.WINDOW_CLOSING = "NeoAI:window_closing" -- 窗口正在关闭（chat_window.lua）
M.WINDOW_CLOSED = "NeoAI:window_closed" -- 窗口已关闭（chat_window.lua）
M.CHAT_BOX_OPENED = "NeoAI:chat_box_opened" -- 聊天框已打开（chat_window.lua）
M.CHAT_BOX_CLOSING = "NeoAI:chat_box_closing" -- 聊天框正在关闭（chat_window.lua）
M.CHAT_BOX_CLOSED = "NeoAI:chat_box_closed" -- 聊天框已关闭（chat_window.lua）

-- ==================== 渲染事件 ====================
-- 使用位置: chat_window.lua, tree_window.lua
M.DIALOGUE_RENDERING_START = "NeoAI:dialogue_rendering_start" -- 对话渲染开始
M.DIALOGUE_RENDERING_COMPLETE = "NeoAI:dialogue_rendering_complete" -- 对话渲染完成
M.RENDERING_COMPLETE = "NeoAI:rendering_complete" -- 渲染完成
M.TREE_RENDERING_START = "NeoAI:tree_rendering_start" -- 树渲染开始
M.TREE_RENDERING_COMPLETE = "NeoAI:tree_rendering_complete" -- 树渲染完成

-- ==================== 悬浮文本事件 ====================
-- 使用位置: chat_window.lua
M.FLOATING_TEXT_SHOWING = "NeoAI:floating_text_showing" -- 悬浮文本正在显示
M.FLOATING_TEXT_SHOWN = "NeoAI:floating_text_shown" -- 悬浮文本已显示
M.FLOATING_TEXT_CLOSING = "NeoAI:floating_text_closing" -- 悬浮文本正在关闭
M.FLOATING_TEXT_CLOSED = "NeoAI:floating_text_closed" -- 悬浮文本已关闭

-- ==================== 模型切换事件 ====================
-- 使用位置: chat_window.lua, chat_handlers.lua
M.MODEL_SWITCHED = "NeoAI:model_switched" -- 模型已切换

-- ==================== 配置事件 ====================
-- 使用位置: reasoning_manager.lua
M.CONFIG_LOADED = "NeoAI:config_loaded" -- 配置已加载
M.CONFIG_CHANGED = "NeoAI:config_changed" -- 配置已变更（当前未使用）

-- ==================== 插件状态事件 ====================
-- 使用位置: ai_engine.lua, reasoning_manager.lua
M.PLUGIN_INITIALIZED = "NeoAI:plugin_initialized" -- 插件初始化完成
M.PLUGIN_SHUTDOWN = "NeoAI:plugin_shutdown" -- 插件关闭

-- ==================== 备份事件 ====================
-- 当前未使用
M.BACKUP_CREATED = "NeoAI:backup_created" -- 备份已创建
M.BACKUP_RESTORED = "NeoAI:backup_restored" -- 备份已恢复

-- ==================== 响应构建事件 ====================
-- 使用位置: response_builder.lua
M.RESPONSE_BUILT = "NeoAI:response_built" -- 响应构建完成

-- ==================== 请求构建事件 ====================
-- 使用位置: request_builder.lua
M.REQUEST_BUILT = "NeoAI:request_built" -- 请求构建完成

-- ==================== 日志事件 ====================
-- 使用位置: reasoning_manager.lua
M.LOG_DEBUG = "NeoAI:log_debug" -- 调试日志（当前未使用）
M.LOG_INFO = "NeoAI:log_info" -- 信息日志
M.LOG_WARN = "NeoAI:log_warn" -- 警告日志（当前未使用）
M.LOG_ERROR = "NeoAI:log_error" -- 错误日志（当前未使用）
M.AI_RESPONSE_CHUNK = "NeoAI:ai_response_chunk" -- AI 响应块（兼容旧事件流）
M.AI_RESPONSE_COMPLETE = "NeoAI:ai_response_complete" -- AI 响应完成（当前未使用）
M.AI_RESPONSE_ERROR = "NeoAI:ai_response_error" -- AI 响应错误（当前未使用）

-- ==================== 自定义/命令事件 ====================
-- 使用位置: ai_engine.lua
M.SEND_MESSAGE = "NeoAI:send_message" -- 发送消息命令
M.CLOSE_WINDOW = "NeoAI:close_window" -- 关闭窗口命令（当前未使用）

-- ==================== 聊天消息流事件 ====================
-- 用于解耦 UI 和业务逻辑
-- 使用位置: ai_engine.lua, input_handler.lua
M.USER_MESSAGE_READY = "NeoAI:user_message_ready" -- 用户消息已准备好发送（当前未使用）
M.USER_MESSAGE_SENDING = "NeoAI:user_message_sending" -- 用户消息开始发送（当前未使用）
M.USER_MESSAGE_SENT = "NeoAI:user_message_sent" -- 用户消息已发送到业务层
M.AI_RESPONSE_READY = "NeoAI:ai_response_ready" -- AI 响应已准备好显示（当前未使用）
M.AI_RESPONSE_RECEIVED = "NeoAI:ai_response_received" -- AI 响应已接收到（当前未使用）
M.CHAT_INPUT_READY = "NeoAI:chat_input_ready" -- 聊天输入已准备好

-- ==================== 历史管理器事件 ====================
-- 使用位置: history_manager.lua
M.ROUND_ADDED = "NeoAI:round_added" -- 对话轮次已添加
M.ORPHANS_CLEANED = "NeoAI:orphans_cleaned" -- 孤儿会话已清理

-- ==================== UI 内部事件 ====================
-- 使用位置: ui/init.lua
M.UI_SESSION_UPDATED = "NeoAI:ui_session_updated" -- UI 会话ID已更新

return M
