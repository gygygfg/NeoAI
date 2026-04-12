local M = {}

-- 配置文件默认路径
M.config_dir = vim.fn.stdpath('config') .. '/NeoAI'
M.config_file = M.config_dir .. '/sessions.json'

-- 会话管理
M.sessions = {}
M.current_session = nil
M.message_handlers = {}
M.editable_states = {}  -- 记录消息的可编辑状态

-- 消息结构
function M.create_message(role, content, timestamp, metadata)
    return {
        id = os.time() .. math.random(1000, 9999),
        role = role,  -- 'user', 'assistant', 'system'
        content = content,
        timestamp = timestamp or os.time(),
        metadata = metadata or {},
        editable = false,
        pending = false,  -- 是否正在处理
    }
end

-- 创建新会话
function M.new_session(name)
    local session_id = #M.sessions + 1
    local session = {
        id = session_id,
        name = name or ("会话" .. session_id),
        messages = {},
        created_at = os.time(),
        updated_at = os.time(),
        config = {
            auto_scroll = true,
            show_timestamps = true,
            max_history = 100,
        }
    }

    M.sessions[session_id] = session
    M.current_session = session_id

    -- 触发会话创建事件
    M.trigger_event('session_created', session)

    return session
end

-- 添加消息
function M.add_message(session_id, message)
    local session = M.sessions[session_id]
    if not session then return nil end

    table.insert(session.messages, message)
    session.updated_at = os.time()

    -- 限制历史长度
    if #session.messages > session.config.max_history then
        table.remove(session.messages, 1)
    end

    -- 触发消息事件
    M.trigger_event('message_added', {session_id = session_id, message = message})

    return message
end

-- 编辑消息
function M.edit_message(session_id, message_id, new_content)
    local session = M.sessions[session_id]
    if not session then return false end

    for i, msg in ipairs(session.messages) do
        if msg.id == message_id and msg.editable then
            msg.content = new_content
            msg.timestamp = os.time()
            session.updated_at = os.time()

            M.trigger_event('message_edited', {
                session_id = session_id,
                message_id = message_id,
                message = msg
            })
            return true
        end
    end

    return false
end

-- 删除消息
function M.delete_message(session_id, message_id)
    local session = M.sessions[session_id]
    if not session then return false end

    for i, msg in ipairs(session.messages) do
        if msg.id == message_id then
            table.remove(session.messages, i)
            session.updated_at = os.time()

            M.trigger_event('message_deleted', {
                session_id = session_id,
                message_id = message_id
            })
            return true
        end
    end

    return false
end

-- 设置消息可编辑状态
function M.set_editable(session_id, message_id, editable)
    local session = M.sessions[session_id]
    if not session then return false end

    for _, msg in ipairs(session.messages) do
        if msg.id == message_id then
            msg.editable = editable

            -- 保存到编辑状态记录
            M.editable_states[message_id] = editable

            M.trigger_event('editability_changed', {
                session_id = session_id,
                message_id = message_id,
                editable = editable
            })
            return true
        end
    end

    return false
end

-- 切换消息编辑状态
function M.toggle_editability(session_id, message_id)
    local session = M.sessions[session_id]
    if not session then return false end

    for _, msg in ipairs(session.messages) do
        if msg.id == message_id then
            local new_state = not msg.editable
            msg.editable = new_state
            M.editable_states[message_id] = new_state

            M.trigger_event('editability_changed', {
                session_id = session_id,
                message_id = message_id,
                editable = new_state
            })
            return new_state
        end
    end

    return false
end

-- 模拟AI回复
function M.simulate_ai_reply(session_id, user_message, callback)
    local session = M.sessions[session_id]
    if not session then return end

    -- 创建待处理消息
    local pending_msg = M.create_message('assistant', '思考中...', os.time(), {pending = true})
    pending_msg.pending = true
    M.add_message(session_id, pending_msg)

    -- 模拟AI思考延迟
    vim.defer_fn(function()
        local responses = {
            "这是一个模拟回复。在实际应用中，这里会连接到AI API。",
            "我理解你的问题。可以告诉我更多细节吗？",
            "根据我的分析，建议你尝试以下步骤...",
            "这是一个很好的问题！让我详细解释一下。",
            "我可能需要更多信息来给出准确的回答。"
        }

        local response = responses[math.random(#responses)]

        -- 更新消息
        for i, msg in ipairs(session.messages) do
            if msg.id == pending_msg.id then
                msg.content = response
                msg.pending = false
                msg.timestamp = os.time()
                break
            end
        end

        session.updated_at = os.time()

        if callback then
            callback(response)
        end

        M.trigger_event('ai_replied', {
            session_id = session_id,
            message = pending_msg
        })
    end, 1000 + math.random(500, 1500))
end

-- 发送消息
function M.send_message(session_id, content)
    local session = M.sessions[session_id]
    if not session or not content or content == '' then
        return
    end

    -- 用户消息
    local user_msg = M.create_message('user', content)
    M.add_message(session_id, user_msg)

    -- 模拟AI回复
    M.simulate_ai_reply(session_id, content, function(response)
        M.trigger_event('response_received', {
            session_id = session_id,
            response = response
        })
    end)

    return user_msg
end

-- 事件系统
function M.on(event, handler)
    M.message_handlers[event] = M.message_handlers[event] or {}
    table.insert(M.message_handlers[event], handler)
end

function M.trigger_event(event, data)
    local handlers = M.message_handlers[event] or {}
    for _, handler in ipairs(handlers) do
        handler(data)
    end
end

-- 导出会话到配置
function M.export_session(session_id, filepath, internal)
    local session = M.sessions[session_id]
    if not session then return false end

    -- 创建可序列化的副本
    local export_data = {
        id = session.id,
        name = session.name,
        messages = {},
        created_at = session.created_at,
        updated_at = session.updated_at,
        config = session.config,
        export_time = os.time()
    }

    -- 转换消息，移除临时字段
    for _, msg in ipairs(session.messages) do
        local export_msg = {
            id = msg.id,
            role = msg.role,
            content = msg.content,
            timestamp = msg.timestamp,
            metadata = msg.metadata,
            editable = M.editable_states[msg.id] or false
        }
        table.insert(export_data.messages, export_msg)
    end

    filepath = filepath or M.config_file

    -- 确保目录存在
    vim.fn.mkdir(M.config_dir, 'p')

    -- 读取现有数据
    local all_data = {}
    if vim.fn.filereadable(filepath) == 1 then
        local content = vim.fn.readfile(filepath)
        if #content > 0 then
            all_data = vim.fn.json_decode(table.concat(content, '\n')) or {}
        end
    end

    -- 更新或添加会话
    all_data[session.id] = export_data

    -- 写入文件
    local json_str = vim.fn.json_encode(all_data)
    vim.fn.writefile({json_str}, filepath)

    if not internal then
        M.trigger_event('session_exported', {
            session_id = session_id,
            filepath = filepath
        })
    end

    return true
end

-- 导出所有会话
function M.export_all(filepath)
    filepath = filepath or M.config_file
    vim.fn.mkdir(M.config_dir, 'p')

    local all_data = {}

    for id, session in pairs(M.sessions) do
        all_data[id] = {
            id = session.id,
            name = session.name,
            messages = session.messages,
            created_at = session.created_at,
            updated_at = session.updated_at,
            config = session.config,
        }
    end

    local json_str = vim.fn.json_encode(all_data)
    vim.fn.writefile({json_str}, filepath)

    return #M.sessions
end

-- 导入会话
function M.import_sessions(filepath)
    filepath = filepath or M.config_file

    if vim.fn.filereadable(filepath) ~= 1 then
        return {}
    end

    local content = vim.fn.readfile(filepath)
    if #content == 0 then
        return {}
    end

    local data = vim.fn.json_decode(table.concat(content, '\n')) or {}
    local imported = {}

    for _, session_data in pairs(data) do
        local session = {
            id = session_data.id,
            name = session_data.name,
            messages = {},
            created_at = session_data.created_at or os.time(),
            updated_at = session_data.updated_at or os.time(),
            config = session_data.config or {}
        }

        -- 导入消息
        for _, msg_data in ipairs(session_data.messages or {}) do
            local msg = M.create_message(
                msg_data.role,
                msg_data.content,
                msg_data.timestamp,
                msg_data.metadata
            )
            msg.id = msg_data.id
            msg.editable = msg_data.editable or false

            if msg.editable then
                M.editable_states[msg.id] = true
            end

            table.insert(session.messages, msg)
        end

        M.sessions[session.id] = session
        table.insert(imported, session.id)
    end

    M.trigger_event('sessions_imported', {count = #imported})
    return imported
end

-- 获取会话统计
function M.get_session_stats(session_id)
    local session = M.sessions[session_id]
    if not session then return {} end

    local stats = {
        total_messages = #session.messages,
        user_messages = 0,
        ai_messages = 0,
        system_messages = 0,
        editable_messages = 0,
        duration_minutes = math.floor((os.time() - session.created_at) / 60)
    }

    for _, msg in ipairs(session.messages) do
        if msg.role == 'user' then
            stats.user_messages = stats.user_messages + 1
        elseif msg.role == 'assistant' then
            stats.ai_messages = stats.ai_messages + 1
        elseif msg.role == 'system' then
            stats.system_messages = stats.system_messages + 1
        end

        if msg.editable then
            stats.editable_messages = stats.editable_messages + 1
        end
    end

    return stats
end

-- 初始化
function M.setup(config)
    config = config or {}

    M.config_dir = config.config_dir or M.config_dir
    M.config_file = config.config_file or M.config_file

    -- 加载现有会话
    M.import_sessions()

    -- 如果没有会话，创建一个默认的
    if #M.sessions == 0 then
        M.new_session("默认会话")
    end

    vim.print("[NeoAI] 后端已初始化")
end

return M
