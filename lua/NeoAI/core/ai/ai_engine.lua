local M = {}

local stream_processor = require("NeoAI.core.ai.stream_processor")
local reasoning_manager = require("NeoAI.core.ai.reasoning_manager")
local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
local response_builder = require("NeoAI.core.ai.response_builder")

-- 模块状态
local state = {
    initialized = false,
    event_bus = nil,
    config = nil,
    session_manager = nil,
    is_generating = false,
    current_generation_id = nil,
    tools = nil
}

--- 初始化AI引擎
--- @param options table 选项
--- @return table AI引擎实例
function M.initialize(options)
    if state.initialized then
        return M
    end

    state.event_bus = options.event_bus
    state.config = options.config or {}
    state.session_manager = options.session_manager

    -- 初始化子模块
    stream_processor.initialize({
        event_bus = state.event_bus,
        config = state.config
    })

    reasoning_manager.initialize({
        event_bus = state.event_bus,
        config = state.config
    })

    tool_orchestrator.initialize({
        event_bus = state.event_bus,
        config = state.config,
        session_manager = state.session_manager
    })

    response_builder.initialize({
        event_bus = state.event_bus,
        config = state.config
    })

    state.initialized = true
    return M
end

--- 生成响应
--- @param messages table 消息列表
--- @param options table 选项
--- @return string 响应ID
function M.generate_response(messages, options)
    if not state.initialized then
        error("AI engine not initialized")
    end

    if state.is_generating then
        error("Already generating response")
    end

    state.is_generating = true
    local generation_id = "gen_" .. os.time() .. "_" .. math.random(1000, 9999)
    state.current_generation_id = generation_id

    -- 合并选项
    local merged_options = vim.tbl_extend("force", state.config, options or {})

    -- 构建消息
    local formatted_messages = response_builder.build_messages(messages, merged_options)

    -- 触发开始事件
    if state.event_bus then
        state.event_bus.emit("generation_started", generation_id, formatted_messages)
    end

    -- 异步生成响应
    vim.schedule(function()
        local success, result = pcall(function()
            return M._generate_response_async(generation_id, formatted_messages, merged_options)
        end)

        if not success then
            M._handle_generation_error(generation_id, result)
        end
    end)

    return generation_id
end

--- 流式响应
--- @param messages table 消息列表
--- @param options table 选项
--- @return function 流式处理器
function M.stream_response(messages, options)
    if not state.initialized then
        error("AI engine not initialized")
    end

    if state.is_generating then
        error("Already generating response")
    end

    state.is_generating = true
    local generation_id = "gen_" .. os.time() .. "_" .. math.random(1000, 9999)
    state.current_generation_id = generation_id

    -- 合并选项
    local merged_options = vim.tbl_extend("force", state.config, options or {})

    -- 构建消息
    local formatted_messages = response_builder.build_messages(messages, merged_options)

    -- 触发开始事件
    if state.event_bus then
        state.event_bus.emit("generation_started", generation_id, formatted_messages)
    end

    -- 创建流式处理器
    local stream_handler = function(chunk)
        stream_processor.process_chunk(chunk)
    end

    -- 异步流式生成
    vim.schedule(function()
        local success, result = pcall(function()
            return M._stream_response_async(generation_id, formatted_messages, merged_options, stream_handler)
        end)

        if not success then
            M._handle_generation_error(generation_id, result)
        end
    end)

    return stream_handler
end

--- 取消生成
function M.cancel_generation()
    if not state.is_generating then
        return
    end

    local generation_id = state.current_generation_id
    state.is_generating = false
    state.current_generation_id = nil

    -- 触发取消事件
    if state.event_bus then
        state.event_bus.emit("generation_cancelled", generation_id)
    end

    -- 清理流式处理器
    stream_processor.flush_buffer()
    reasoning_manager.clear_reasoning()
end

--- 是否正在生成
--- @return boolean 是否正在生成
function M.is_generating()
    return state.is_generating
end

--- 设置工具
--- @param tools table 工具列表
function M.set_tools(tools)
    state.tools = tools
    if tool_orchestrator then
        tool_orchestrator.set_tools(tools)
    end
end

--- 异步生成响应（内部使用）
--- @param generation_id string 生成ID
--- @param messages table 消息列表
--- @param options table 选项
function M._generate_response_async(generation_id, messages, options)
    -- 这里应该调用实际的AI API
    -- 目前返回模拟响应
    local response = "这是AI生成的响应。实际实现需要连接到AI服务。"

    -- 处理工具调用
    if options.tools and #options.tools > 0 then
        local tool_result = tool_orchestrator.execute_tool_loop(messages)
        if tool_result then
            response = tool_result
        end
    end

    -- 触发完成事件
    if state.event_bus then
        state.event_bus.emit("generation_completed", generation_id, response)
    end

    state.is_generating = false
    state.current_generation_id = nil

    return response
end

--- 异步流式响应（内部使用）
--- @param generation_id string 生成ID
--- @param messages table 消息列表
--- @param options table 选项
--- @param stream_handler function 流式处理器
function M._stream_response_async(generation_id, messages, options, stream_handler)
    -- 这里应该调用支持流式的AI API
    -- 目前返回模拟流式响应
    local chunks = {
        "这是",
        "AI生成的",
        "流式响应。",
        "实际实现需要",
        "连接到支持流式的AI服务。"
    }

    for _, chunk in ipairs(chunks) do
        if not state.is_generating then
            break
        end
        stream_handler(chunk)
        vim.wait(100) -- 模拟延迟
    end

    -- 处理工具调用（流式模式下）
    if options.tools and #options.tools > 0 then
        local tool_result = tool_orchestrator.execute_tool_loop(messages)
        if tool_result then
            stream_handler(tool_result)
        end
    end

    -- 触发完成事件
    if state.event_bus then
        state.event_bus.emit("generation_completed", generation_id, "stream_complete")
    end

    state.is_generating = false
    state.current_generation_id = nil
    stream_processor.flush_buffer()
end

--- 处理生成错误（内部使用）
--- @param generation_id string 生成ID
--- @param error_msg string 错误信息
function M._handle_generation_error(generation_id, error_msg)
    state.is_generating = false
    state.current_generation_id = nil

    -- 触发错误事件
    if state.event_bus then
        state.event_bus.emit("generation_error", generation_id, error_msg)
    end

    vim.notify("AI生成错误: " .. error_msg, vim.log.levels.ERROR)
end

return M