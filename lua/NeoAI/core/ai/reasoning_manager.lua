local M = {}

-- 模块状态
local state = {
    initialized = false,
    event_bus = nil,
    config = nil,
    reasoning_active = false,
    reasoning_text = "",
    reasoning_start_time = nil,
    reasoning_chunks = {}
}

--- 初始化思考过程管理器
--- @param options table 选项
function M.initialize(options)
    if state.initialized then
        return
    end

    state.event_bus = options.event_bus
    state.config = options.config or {}
    state.initialized = true

    -- 监听思考事件
    if state.event_bus then
        state.event_bus.on("reasoning_content", function(content)
            M.append_reasoning(content)
        end)

        state.event_bus.on("reasoning_chunk", function(chunk)
            M.append_reasoning(chunk)
        end)
    end
end

--- 开始思考过程
function M.start_reasoning()
    if not state.initialized then
        return
    end

    if state.reasoning_active then
        return
    end

    state.reasoning_active = true
    state.reasoning_text = ""
    state.reasoning_start_time = os.time()
    state.reasoning_chunks = {}

    -- 触发开始事件
    if state.event_bus then
        state.event_bus.emit("reasoning_started")
    end
end

--- 追加思考内容
--- @param content string 思考内容
function M.append_reasoning(content)
    if not state.initialized then
        return
    end

    if not state.reasoning_active then
        M.start_reasoning()
    end

    -- 添加内容
    state.reasoning_text = state.reasoning_text .. content
    table.insert(state.reasoning_chunks, {
        content = content,
        timestamp = os.time()
    })

    -- 触发追加事件
    if state.event_bus then
        state.event_bus.emit("reasoning_appended", content, state.reasoning_text)
    end
end

--- 完成思考过程
function M.finish_reasoning()
    if not state.initialized then
        return
    end

    if not state.reasoning_active then
        return
    end

    local reasoning_duration = os.time() - (state.reasoning_start_time or os.time())
    state.reasoning_active = false

    -- 触发完成事件
    if state.event_bus then
        state.event_bus.emit("reasoning_finished", state.reasoning_text, reasoning_duration)
    end

    -- 清空思考内容
    M.clear_reasoning()
end

--- 获取思考文本
--- @return string 思考文本
function M.get_reasoning_text()
    return state.reasoning_text
end

--- 清空思考
function M.clear_reasoning()
    state.reasoning_text = ""
    state.reasoning_chunks = {}
    state.reasoning_start_time = nil
end

--- 获取思考状态
--- @return table 思考状态
function M.get_reasoning_state()
    return {
        active = state.reasoning_active,
        text = state.reasoning_text,
        start_time = state.reasoning_start_time,
        duration = state.reasoning_start_time and (os.time() - state.reasoning_start_time) or 0,
        chunk_count = #state.reasoning_chunks
    }
end

--- 获取思考块列表
--- @return table 思考块列表
function M.get_reasoning_chunks()
    return vim.deepcopy(state.reasoning_chunks)
end

--- 是否正在思考
--- @return boolean 是否正在思考
function M.is_reasoning_active()
    return state.reasoning_active
end

--- 获取思考摘要
--- @param max_length number 最大长度
--- @return string 思考摘要
function M.get_reasoning_summary(max_length)
    max_length = max_length or 200

    if #state.reasoning_text <= max_length then
        return state.reasoning_text
    end

    -- 简单截断
    local summary = state.reasoning_text:sub(1, max_length) .. "..."
    
    -- 尝试在句子边界截断
    local last_period = summary:reverse():find("%.")
    if last_period then
        summary = summary:sub(1, max_length - last_period + 1) .. "..."
    end

    return summary
end

--- 格式化思考内容为显示文本
--- @param include_timestamps boolean 是否包含时间戳
--- @return string 格式化后的文本
function M.format_reasoning(include_timestamps)
    if not state.reasoning_text or state.reasoning_text == "" then
        return ""
    end

    if not include_timestamps or #state.reasoning_chunks == 0 then
        return state.reasoning_text
    end

    local lines = {}
    table.insert(lines, "=== 思考过程 ===")
    table.insert(lines, "")

    local start_time = state.reasoning_start_time
    for i, chunk in ipairs(state.reasoning_chunks) do
        local time_offset = chunk.timestamp - start_time
        local time_str = string.format("[+%ds]", time_offset)
        table.insert(lines, time_str .. " " .. chunk.content)
    end

    table.insert(lines, "")
    table.insert(lines, "=== 思考结束 ===")

    return table.concat(lines, "\n")
end

return M