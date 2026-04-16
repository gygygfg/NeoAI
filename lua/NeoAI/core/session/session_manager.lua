local M = {}

local branch_manager = require("NeoAI.core.session.branch_manager")
local message_manager = require("NeoAI.core.session.message_manager")
local data_operations = require("NeoAI.core.session.data_operations")

-- 会话存储
local sessions = {}
local current_session_id = nil
local session_counter = 0

-- 模块状态
local state = {
    initialized = false,
    event_bus = nil,
    config = nil
}

--- 初始化会话管理器
--- @param options table 选项
--- @return table 会话管理器实例
function M.initialize(options)
    if state.initialized then
        return M
    end

    state.event_bus = options.event_bus
    state.config = options.config or {}

    -- 初始化子模块
    branch_manager.initialize({
        event_bus = state.event_bus,
        config = state.config
    })

    message_manager.initialize({
        event_bus = state.event_bus,
        config = state.config
    })

    data_operations.initialize({
        event_bus = state.event_bus,
        config = state.config
    })

    -- 加载保存的会话
    if state.config.auto_save and state.config.save_path then
        M._load_sessions()
    end

    state.initialized = true
    return M
end

--- 内部函数：确保有当前会话
local function ensure_current_session()
    if not current_session_id then
        -- 创建默认会话
        session_counter = session_counter + 1
        current_session_id = "session_" .. session_counter
        
        -- 创建默认分支（使用简单的分支ID）
        local branch_id = "branch_main"
        
        sessions[current_session_id] = {
            id = current_session_id,
            name = "default",
            created_at = os.time(),
            updated_at = os.time(),
            branches = {[branch_id] = true},
            current_branch = branch_id
        }
        
        -- 触发事件
        if state.event_bus then
            state.event_bus.emit("session_created", current_session_id, sessions[current_session_id])
        end
    end
    return current_session_id
end

--- 创建会话
--- @param name string 会话名称
--- @return string 会话ID
function M.create_session(name)
    if not state.initialized then
        error("Session manager not initialized")
    end

    session_counter = session_counter + 1
    local session_id = "session_" .. session_counter

    local session = {
        id = session_id,
        name = name or ("Session " .. session_counter),
        created_at = os.time(),
        updated_at = os.time(),
        branches = {},
        current_branch = nil
    }

    sessions[session_id] = session
    current_session_id = session_id

    -- 创建默认分支
    local branch_id = branch_manager.create_branch(session_id, "main")
    session.current_branch = branch_id
    session.branches[branch_id] = true

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("session_created", session_id, session)
    end

    -- 自动保存
    if state.config.auto_save then
        M._save_sessions()
    end

    return session_id
end

--- 获取会话
--- @param session_id string 会话ID
--- @return table|nil 会话信息
function M.get_session(session_id)
    if not session_id then
        return nil
    end
    return vim.deepcopy(sessions[session_id])
end

--- 获取当前会话
--- @return table|nil 当前会话信息
function M.get_current_session()
    if not current_session_id then
        ensure_current_session()
    end
    return M.get_session(current_session_id)
end

--- 设置当前会话
--- @param session_id string 会话ID
function M.set_current_session(session_id)
    if not sessions[session_id] then
        error("Session not found: " .. session_id)
    end
    current_session_id = session_id

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("session_changed", session_id, sessions[session_id])
    end
end

--- 列出所有会话
--- @return table 会话列表
function M.list_sessions()
    local result = {}
    for id, session in pairs(sessions) do
        table.insert(result, {
            id = id,
            name = session.name,
            created_at = session.created_at,
            updated_at = session.updated_at,
            branch_count = #vim.tbl_keys(session.branches)
        })
    end
    return result
end

--- 删除会话
--- @param session_id string 会话ID
function M.delete_session(session_id)
    if not sessions[session_id] then
        return
    end

    -- 删除所有分支
    local session = sessions[session_id]
    for branch_id, _ in pairs(session.branches) do
        branch_manager.delete_branch(branch_id)
    end

    -- 删除会话
    sessions[session_id] = nil

    -- 如果删除的是当前会话，重置当前会话
    if current_session_id == session_id then
        current_session_id = nil
        local session_list = M.list_sessions()
        if #session_list > 0 then
            current_session_id = session_list[1].id
        end
    end

    -- 触发事件
    if state.event_bus then
        state.event_bus.emit("session_deleted", session_id)
    end

    -- 自动保存
    if state.config.auto_save then
        M._save_sessions()
    end
end

--- 获取分支管理器
--- @return table 分支管理器
function M.get_branch_manager()
    return branch_manager
end

--- 获取消息管理器
--- @return table 消息管理器
function M.get_message_manager()
    return message_manager
end

--- 获取数据操作模块
--- @return table 数据操作模块
function M.get_data_operations()
    return data_operations
end

--- 加载会话（内部使用）
function M._load_sessions()
    -- TODO: 实现从文件加载会话
    -- 目前返回空实现
end

--- 保存会话（内部使用）
function M._save_sessions()
    -- TODO: 实现保存会话到文件
    -- 目前返回空实现
end

return M