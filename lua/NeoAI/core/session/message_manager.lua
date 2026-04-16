local M = {}

-- 消息存储
local messages = {}
local message_counter = 0

-- 模块状态
local state = {
    initialized = false,
    event_bus = nil,
    config = nil
}

--- 初始化消息管理器
--- @param options table 选项
function M.initialize(options)
    if state.initialized then
        return
    end

    state.event_bus = options.event_bus
    state.config = options.config or {}
    state.initialized = true
end

--- 添加消息
--- @param branch_id string 分支ID
--- @param role string 角色（user/assistant/tool）
--- @param content string|table 消息内容
--- @param metadata table 元数据
--- @return string 消息ID
function M.add_message(branch_id, role, content, metadata)
    if not state.initialized then
        error("Message manager not initialized")
    end

    if not branch_id then
        error("Branch ID is required")
    end

    if not role or not (role == "user" or role == "assistant" or role == "tool") then
        error("Role must be 'user', 'assistant', or 'tool'")
    end

    message_counter = message_counter + 1
    local message_id = "msg_" .. message_counter

    local message = {
        id = message_id,
        branch_id = branch_id,
        role = role,
        content = content,
        metadata = metadata or {},
        created_at = os.time(),
        updated_at = os.time()
    }

    messages[message_id] = message

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("message_added", message_id, message)
    end

    return message_id
end

--- 获取消息
--- @param branch_id string 分支ID
--- @param limit number 限制数量
--- @return table 消息列表
function M.get_messages(branch_id, limit)
    if not branch_id then
        return {}
    end

    local result = {}
    local count = 0

    -- 按创建时间排序的消息ID列表
    local message_ids = {}
    for id, msg in pairs(messages) do
        if msg.branch_id == branch_id then
            table.insert(message_ids, { id = id, created_at = msg.created_at })
        end
    end

    -- 按时间排序
    table.sort(message_ids, function(a, b)
        return a.created_at < b.created_at
    end)

    -- 应用限制
    for _, item in ipairs(message_ids) do
        if limit and count >= limit then
            break
        end
        table.insert(result, vim.deepcopy(messages[item.id]))
        count = count + 1
    end

    return result
end

--- 编辑消息
--- @param message_id string 消息ID
--- @param content string|table 新内容
function M.edit_message(message_id, content)
    if not messages[message_id] then
        error("Message not found: " .. message_id)
    end

    local old_content = messages[message_id].content
    messages[message_id].content = content
    messages[message_id].updated_at = os.time()

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("message_edited", message_id, old_content, content)
    end
end

--- 删除消息
--- @param message_id string 消息ID
function M.delete_message(message_id)
    if not messages[message_id] then
        return
    end

    local message = messages[message_id]
    messages[message_id] = nil

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("message_deleted", message_id, message)
    end
end

--- 清空消息
--- @param branch_id string 分支ID
function M.clear_messages(branch_id)
    if not branch_id then
        return
    end

    local deleted_ids = {}
    for id, msg in pairs(messages) do
        if msg.branch_id == branch_id then
            messages[id] = nil
            table.insert(deleted_ids, id)
        end
    end

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("messages_cleared", branch_id, deleted_ids)
    end
end

--- 获取消息数量
--- @param branch_id string 分支ID
--- @return number 消息数量
function M.get_message_count(branch_id)
    if not branch_id then
        return 0
    end

    local count = 0
    for _, msg in pairs(messages) do
        if msg.branch_id == branch_id then
            count = count + 1
        end
    end

    return count
end

--- 获取最新消息
--- @param branch_id string 分支ID
--- @return table|nil 最新消息
function M.get_latest_message(branch_id)
    if not branch_id then
        return nil
    end

    local latest_msg = nil
    for _, msg in pairs(messages) do
        if msg.branch_id == branch_id then
            if not latest_msg or msg.created_at > latest_msg.created_at then
                latest_msg = msg
            end
        end
    end

    return vim.deepcopy(latest_msg)
end

return M