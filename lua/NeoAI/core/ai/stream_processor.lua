local M = {}

-- 模块状态
local state = {
    initialized = false,
    event_bus = nil,
    config = nil,
    buffer = "",
    reasoning_buffer = "",
    in_reasoning = false
}

--- 初始化流式处理器
--- @param options table 选项
function M.initialize(options)
    if state.initialized then
        return
    end

    state.event_bus = options.event_bus
    state.config = options.config or {}
    state.initialized = true
end

--- 处理流式数据块
--- @param chunk string 数据块
function M.process_chunk(chunk)
    if not state.initialized then
        return
    end

    if not chunk or chunk == "" then
        return
    end

    -- 添加到缓冲区
    state.buffer = state.buffer .. chunk

    -- 尝试解析DeepSeek API格式
    if chunk:match("^data: ") then
        M._parse_deepseek_stream(chunk)
    -- 尝试解析特殊标记
    elseif chunk:match("^<reasoning>") or state.in_reasoning then
        M._handle_reasoning_chunk(chunk)
    elseif chunk:match("^<tool_call>") then
        M._handle_tool_call_chunk(chunk)
    else
        M._handle_content_chunk(chunk)
    end
end

--- 解析DeepSeek流式响应
--- @param chunk string 数据块
function M._parse_deepseek_stream(chunk)
    -- 移除 "data: " 前缀
    local json_str = chunk:gsub("^data: ", "")
    
    -- 跳过 [DONE] 消息
    if json_str == "[DONE]" then
        return
    end
    
    -- 解析JSON
    local ok, data = pcall(vim.json.decode, json_str)
    if not ok or not data then
        return
    end
    
    -- 检查是否有思考内容
    if data.choices and data.choices[1] and data.choices[1].delta then
        local delta = data.choices[1].delta
        
        if delta.reasoning_content then
            -- 思考内容
            M.handle_reasoning(delta.reasoning_content)
        elseif delta.content then
            -- 普通内容
            M.handle_content(delta.content)
        elseif delta.tool_calls then
            -- 工具调用
            M.handle_tool_call(delta.tool_calls)
        end
        
        -- 检查是否结束
        if data.choices[1].finish_reason then
            M.complete_stream()
        end
    end
end

--- 处理思考内容
--- @param content string 思考内容
function M.handle_reasoning(content)
    if not state.initialized then
        return
    end

    -- 触发思考事件
    if state.event_bus then
        state.event_bus.emit("reasoning_content", content)
    end

    -- 如果思考缓冲区不为空，先刷新
    if state.reasoning_buffer ~= "" then
        M._flush_reasoning_buffer()
    end

    -- 直接发送思考内容
    if state.event_bus then
        state.event_bus.emit("reasoning_chunk", content)
    end
end

--- 处理内容输出
--- @param content string 内容
function M.handle_content(content)
    if not state.initialized then
        return
    end

    -- 触发内容事件
    if state.event_bus then
        state.event_bus.emit("content_chunk", content)
    end
end

--- 处理工具调用
--- @param tool_call table 工具调用
function M.handle_tool_call(tool_call)
    if not state.initialized then
        return
    end

    -- 触发工具调用事件
    if state.event_bus then
        state.event_bus.emit("tool_call", tool_call)
    end
end

--- 刷新缓冲区
function M.flush_buffer()
    if not state.initialized then
        return
    end

    -- 刷新内容缓冲区
    if state.buffer ~= "" then
        M.handle_content(state.buffer)
        state.buffer = ""
    end

    -- 刷新思考缓冲区
    if state.reasoning_buffer ~= "" then
        M._flush_reasoning_buffer()
    end
end

--- 处理流式数据（别名函数）
--- @param stream_data string|table 流式数据或session_id
--- @param data_chunks table|nil 数据块列表（可选）
function M.process_stream(stream_data, data_chunks)
    if type(stream_data) == "string" and data_chunks == nil then
        -- 单个数据块
        M.process_chunk(stream_data)
    elseif type(stream_data) == "string" and type(data_chunks) == "table" then
        -- session_id + 数据块列表
        for _, chunk in ipairs(data_chunks) do
            M.process_chunk(chunk)
        end
    elseif type(stream_data) == "table" then
        -- 数据块列表
        for _, chunk in ipairs(stream_data) do
            M.process_chunk(chunk)
        end
    end
end

--- 处理数据块（别名函数）
--- @param chunk string 数据块
function M.handle_chunk(chunk)
    M.process_chunk(chunk)
end

--- 完成流处理
--- @param session_id string|nil 会话ID（可选）
function M.complete_stream(session_id)
    M.flush_buffer()
    
    -- 触发流完成事件
    if state.event_bus then
        state.event_bus.emit("stream_completed", session_id)
    end
end

--- 获取缓冲区内容
--- @param session_id string|nil 会话ID（可选）
--- @return string 缓冲区内容
function M.get_buffer(session_id)
    -- 忽略session_id参数，返回当前缓冲区
    return state.buffer
end

--- 处理思考数据块（内部使用）
--- @param chunk string 数据块
function M._handle_reasoning_chunk(chunk)
    -- 检查是否开始思考
    if chunk:match("^<reasoning>") then
        state.in_reasoning = true
        chunk = chunk:gsub("^<reasoning>", "")
    end

    -- 检查是否结束思考
    if chunk:match("</reasoning>$") then
        state.in_reasoning = false
        chunk = chunk:gsub("</reasoning>$", "")
    end

    -- 添加到思考缓冲区
    state.reasoning_buffer = state.reasoning_buffer .. chunk

    -- 如果不在思考模式中，刷新缓冲区
    if not state.in_reasoning then
        M._flush_reasoning_buffer()
    end
end

--- 处理工具调用数据块（内部使用）
--- @param chunk string 数据块
function M._handle_tool_call_chunk(chunk)
    -- 提取工具调用内容
    local tool_call_content = chunk:gsub("^<tool_call>", ""):gsub("</tool_call>$", "")
    
    -- 尝试解析为JSON
    local ok, tool_call = pcall(vim.json.decode, tool_call_content)
    if ok and tool_call then
        M.handle_tool_call(tool_call)
    else
        -- 如果不是JSON，作为普通内容处理
        M._handle_content_chunk(chunk)
    end
end

--- 处理内容数据块（内部使用）
--- @param chunk string 数据块
function M._handle_content_chunk(chunk)
    -- 简单处理：直接发送内容
    M.handle_content(chunk)
end

--- 刷新思考缓冲区（内部使用）
function M._flush_reasoning_buffer()
    if state.reasoning_buffer == "" then
        return
    end

    M.handle_reasoning(state.reasoning_buffer)
    state.reasoning_buffer = ""
end

--- 刷新内容缓冲区（内部使用）
function M._flush_content_buffer()
    if state.buffer == "" then
        return
    end

    M.handle_content(state.buffer)
    state.buffer = ""
end

--- 获取缓冲区状态
--- @return table 缓冲区状态
function M.get_buffer_state()
    return {
        buffer = state.buffer,
        reasoning_buffer = state.reasoning_buffer,
        in_reasoning = state.in_reasoning
    }
end

--- 清空缓冲区
function M.clear_buffer()
    state.buffer = ""
    state.reasoning_buffer = ""
    state.in_reasoning = false
end

return M