local M = {}

-- 模块状态
local state = {
    initialized = false,
    event_bus = nil,
    config = nil
}

--- 初始化响应构建器
--- @param options table 选项
function M.initialize(options)
    if state.initialized then
        return
    end

    state.event_bus = options.event_bus
    state.config = options.config or {}
    state.initialized = true
end

--- 构建消息列表
--- @param history table 历史消息
--- @param query string|table 查询内容
--- @param options table 选项
--- @return table 构建的消息列表
function M.build_messages(history, query, options)
    if not state.initialized then
        error("Response builder not initialized")
    end

    local messages = {}

    -- 添加系统提示（如果有）
    if options and options.system_prompt then
        table.insert(messages, {
            role = "system",
            content = options.system_prompt
        })
    elseif state.config.system_prompt then
        table.insert(messages, {
            role = "system",
            content = state.config.system_prompt
        })
    end

    -- 添加历史消息
    if history and #history > 0 then
        -- 应用历史限制
        local max_history = options and options.max_history or state.config.max_history or 20
        local start_index = math.max(1, #history - max_history + 1)
        
        for i = start_index, #history do
            local msg = history[i]
            if msg and msg.role and msg.content then
                table.insert(messages, {
                    role = msg.role,
                    content = msg.content,
                    name = msg.name,
                    tool_call_id = msg.tool_call_id
                })
            end
        end
    end

    -- 添加当前查询
    if query then
        local query_content
        if type(query) == "table" then
            query_content = query.content or vim.json.encode(query)
        else
            query_content = query
        end

        table.insert(messages, {
            role = "user",
            content = query_content
        })
    end

    -- 触发消息构建完成事件
    if state.event_bus then
        state.event_bus.emit("messages_built", messages, #history or 0)
    end

    return messages
end

--- 格式化工具结果
--- @param result string|table 工具结果
--- @return string 格式化后的结果
function M.format_tool_result(result)
    if not result then
        return ""
    end

    local formatted_result

    if type(result) == "table" then
        -- 尝试美化JSON
        local ok, json = pcall(vim.json.encode, result)
        if ok then
            formatted_result = json
        else
            formatted_result = tostring(result)
        end
    else
        formatted_result = tostring(result)
    end

    -- 如果结果太长，进行截断
    local max_length = state.config.max_tool_result_length or 1000
    if #formatted_result > max_length then
        formatted_result = formatted_result:sub(1, max_length) .. "... [结果已截断]"
    end

    return formatted_result
end

--- 创建摘要
--- @param messages table 消息列表
--- @param max_length number 最大长度
--- @return string 摘要
function M.create_summary(messages, max_length)
    if not messages or #messages == 0 then
        return "无消息"
    end

    max_length = max_length or 100

    local summary_parts = {}
    local total_length = 0

    for i, msg in ipairs(messages) do
        if total_length >= max_length then
            break
        end

        local role_symbol = msg.role == "user" and "👤" or msg.role == "assistant" and "🤖" or "🛠️"
        local content_preview
        
        if type(msg.content) == "string" then
            content_preview = msg.content:gsub("\n", " "):sub(1, 50)
            if #msg.content > 50 then
                content_preview = content_preview .. "..."
            end
        else
            content_preview = "[非文本内容]"
        end

        local line = string.format("%s %s: %s", role_symbol, msg.role, content_preview)
        table.insert(summary_parts, line)
        
        total_length = total_length + #line
    end

    if #messages > #summary_parts then
        table.insert(summary_parts, string.format("... 还有 %d 条消息", #messages - #summary_parts))
    end

    return table.concat(summary_parts, "\n")
end

--- 压缩上下文
--- @param messages table 消息列表
--- @param max_tokens number 最大token数
--- @return table 压缩后的消息列表
function M.compact_context(messages, max_tokens)
    if not messages or #messages == 0 then
        return {}
    end

    max_tokens = max_tokens or 4000

    -- 简单实现：保留最近的N条消息
    -- 实际实现应该考虑token计数和重要性
    local max_messages = math.floor(max_tokens / 100) -- 假设每条消息约100个token
    max_messages = math.max(1, math.min(max_messages, #messages))

    local compressed = {}
    local start_index = #messages - max_messages + 1

    for i = start_index, #messages do
        table.insert(compressed, messages[i])
    end

    -- 如果压缩了上下文，添加系统消息说明
    if #compressed < #messages then
        table.insert(compressed, 1, {
            role = "system",
            content = string.format("注意：由于上下文长度限制，只显示了最近的 %d 条消息（共 %d 条）。", #compressed, #messages)
        })
    end

    return compressed
end

--- 构建工具调用消息
--- @param tool_name string 工具名称
--- @param arguments table 参数
--- @param tool_call_id string 工具调用ID
--- @return table 工具调用消息
function M.build_tool_call_message(tool_name, arguments, tool_call_id)
    return {
        role = "assistant",
        content = nil,
        tool_calls = {
            {
                id = tool_call_id or "call_" .. os.time() .. "_" .. math.random(1000, 9999),
                type = "function",
                ["function"] = {
                    name = tool_name,
                    arguments = arguments
                }
            }
        }
    }
end

--- 构建工具结果消息
--- @param tool_call_id string 工具调用ID
--- @param result string 工具结果
--- @param tool_name string 工具名称
--- @return table 工具结果消息
function M.build_tool_result_message(tool_call_id, result, tool_name)
    return {
        role = "tool",
        tool_call_id = tool_call_id,
        name = tool_name,
        content = result
    }
end

--- 估算token数量
--- @param text string 文本
--- @return number 估算的token数量
function M.estimate_tokens(text)
    if not text then
        return 0
    end

    -- 简单估算：英文约4个字符一个token，中文约2个字符一个token
    local chinese_chars = #text:match("[%z\1-\127\194-\244][\128-\191]*") or 0
    local total_chars = #text
    local other_chars = total_chars - chinese_chars

    return math.ceil(chinese_chars / 2 + other_chars / 4)
end

--- 估算消息列表的token数量
--- @param messages table 消息列表
--- @return number 总token数量
function M.estimate_message_tokens(messages)
    if not messages then
        return 0
    end

    local total_tokens = 0
    for _, msg in ipairs(messages) do
        if msg.content then
            total_tokens = total_tokens + M.estimate_tokens(tostring(msg.content))
        end
        -- 为角色和其他字段添加一些token
        total_tokens = total_tokens + 10
    end

    return total_tokens
end

--- 构建最终响应
--- @param params table 参数
--- @param params.original_messages table 原始消息列表
--- @param params.ai_response table AI响应
--- @param params.tool_results table 工具结果列表
--- @return table 最终响应
function M.build_response(params)
    if not params then
        return {content = "无响应"}
    end

    local response = {
        content = ""
    }

    -- 如果有AI响应内容，添加它
    if params.ai_response and params.ai_response.content then
        response.content = params.ai_response.content
    end

    -- 如果有工具结果，添加到响应中
    if params.tool_results and #params.tool_results > 0 then
        if response.content and #response.content > 0 then
            response.content = response.content .. "\n\n工具调用结果:\n"
        else
            response.content = "工具调用结果:\n"
        end

        for i, result in ipairs(params.tool_results) do
            response.content = response.content .. string.format("%d. %s\n", i, M.format_tool_result(result))
        end
    end

    -- 如果有推理内容，也添加到响应中
    if params.ai_response and params.ai_response.reasoning then
        if response.content and #response.content > 0 then
            response.content = response.content .. "\n\n推理过程:\n" .. params.ai_response.reasoning
        else
            response.content = "推理过程:\n" .. params.ai_response.reasoning
        end
    end

    return response
end

return M