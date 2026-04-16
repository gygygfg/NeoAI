local M = {}

-- 模块状态
local state = {
    initialized = false,
    config = nil,
    sessions = {},
    current_session_id = nil,
    max_history_per_session = 100
}

-- 会话结构
local Session = {}
Session.__index = Session

--- 创建新会话
--- @param id string 会话ID
--- @param name string 会话名称
--- @param metadata table 元数据
function Session:new(id, name, metadata)
    local self = setmetatable({}, Session)
    self.id = id or vim.fn.strftime("%Y%m%d_%H%M%S")
    self.name = name or "新会话"
    self.metadata = metadata or {
        created_at = os.time(),
        message_count = 0,
        last_updated = os.time()
    }
    self.messages = {}
    self.branches = {}
    self.current_branch_id = nil
    return self
end

--- 添加消息
--- @param role string 角色（user/assistant）
--- @param content string 内容
--- @param metadata table 元数据
function Session:add_message(role, content, metadata)
    local message = {
        id = #self.messages + 1,
        role = role,
        content = content,
        timestamp = os.time(),
        metadata = metadata or {}
    }
    
    table.insert(self.messages, message)
    self.metadata.message_count = #self.messages
    self.metadata.last_updated = os.time()
    
    return message
end

--- 获取消息
--- @param limit number 限制数量
--- @return table 消息列表
function Session:get_messages(limit)
    limit = limit or self.metadata.message_count
    local start_index = math.max(1, #self.messages - limit + 1)
    local result = {}
    
    for i = start_index, #self.messages do
        table.insert(result, vim.deepcopy(self.messages[i]))
    end
    
    return result
end

--- 创建分支
--- @param name string 分支名称
--- @param from_message_id number 从哪个消息ID开始
--- @param metadata table 元数据
function Session:create_branch(name, from_message_id, metadata)
    local branch = {
        id = #self.branches + 1,
        name = name or "分支" .. (#self.branches + 1),
        from_message_id = from_message_id or #self.messages,
        created_at = os.time(),
        metadata = metadata or {},
        messages = {}
    }
    
    table.insert(self.branches, branch)
    return branch
end

--- 切换到分支
--- @param branch_id number 分支ID
function Session:switch_branch(branch_id)
    for _, branch in ipairs(self.branches) do
        if branch.id == branch_id then
            self.current_branch_id = branch_id
            return true
        end
    end
    return false
end

--- 保存会话到文件
--- @param filepath string 文件路径
function Session:save(filepath)
    local data = {
        id = self.id,
        name = self.name,
        metadata = self.metadata,
        messages = self.messages,
        branches = self.branches,
        current_branch_id = self.current_branch_id
    }
    
    local json_str = vim.json.encode(data)
    vim.fn.mkdir(vim.fn.fnamemodify(filepath, ":h"), "p")
    vim.fn.writefile({json_str}, filepath)
end

--- 从文件加载会话
--- @param filepath string 文件路径
--- @return Session|nil 加载的会话
function Session.load(filepath)
    if vim.fn.filereadable(filepath) == 0 then
        return nil
    end
    
    local content = vim.fn.readfile(filepath)
    if #content == 0 then
        return nil
    end
    
    local data = vim.json.decode(table.concat(content, "\n"))
    if not data then
        return nil
    end
    
    local session = Session:new(data.id, data.name, data.metadata)
    session.messages = data.messages or {}
    session.branches = data.branches or {}
    session.current_branch_id = data.current_branch_id
    
    return session
end

--- 初始化历史管理器
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end
    
    state.config = config or {}
    state.max_history_per_session = config.max_history_per_session or 100
    state.sessions = {}
    state.current_session_id = nil
    state.initialized = true
    
    -- 加载保存的会话
    M._load_sessions()
end

--- 创建新会话
--- @param name string 会话名称
--- @param metadata table 元数据
--- @return string 会话ID
function M.create_session(name, metadata)
    if not state.initialized then
        error("History manager not initialized")
    end
    
    local session = Session:new(nil, name, metadata)
    state.sessions[session.id] = session
    state.current_session_id = session.id
    
    -- 自动保存
    M._auto_save_session(session)
    
    return session.id
end

--- 获取当前会话
--- @return Session|nil 当前会话
function M.get_current_session()
    if not state.initialized or not state.current_session_id then
        return nil
    end
    
    return state.sessions[state.current_session_id]
end

--- 切换到会话
--- @param session_id string 会话ID
--- @return boolean 是否切换成功
function M.switch_session(session_id)
    if not state.initialized then
        error("History manager not initialized")
    end
    
    if not state.sessions[session_id] then
        return false
    end
    
    state.current_session_id = session_id
    return true
end

--- 添加消息到当前会话
--- @param role string 角色
--- @param content string 内容
--- @param metadata table 元数据
--- @return table|nil 添加的消息
function M.add_message(role, content, metadata)
    local session = M.get_current_session()
    if not session then
        return nil
    end
    
    local message = session:add_message(role, content, metadata)
    
    -- 自动保存
    M._auto_save_session(session)
    
    return message
end

--- 获取当前会话的消息
--- @param limit number 限制数量
--- @return table 消息列表
function M.get_messages(limit)
    local session = M.get_current_session()
    if not session then
        return {}
    end
    
    return session:get_messages(limit)
end

--- 获取所有会话
--- @return table 会话列表
function M.get_sessions()
    if not state.initialized then
        return {}
    end
    
    local sessions = {}
    for _, session in pairs(state.sessions) do
        table.insert(sessions, {
            id = session.id,
            name = session.name,
            metadata = session.metadata
        })
    end
    
    -- 按最后更新时间排序
    table.sort(sessions, function(a, b)
        return (a.metadata.last_updated or 0) > (b.metadata.last_updated or 0)
    end)
    
    return sessions
end

--- 删除会话
--- @param session_id string 会话ID
--- @return boolean 是否删除成功
function M.delete_session(session_id)
    if not state.initialized then
        error("History manager not initialized")
    end
    
    if not state.sessions[session_id] then
        return false
    end
    
    -- 如果是当前会话，清空当前会话ID
    if state.current_session_id == session_id then
        state.current_session_id = nil
    end
    
    -- 删除会话文件
    local filepath = M._get_session_filepath(session_id)
    if vim.fn.filereadable(filepath) == 1 then
        vim.fn.delete(filepath)
    end
    
    -- 从内存中删除
    state.sessions[session_id] = nil
    
    return true
end

--- 导出会话
--- @param session_id string 会话ID
--- @param export_path string 导出路径
--- @return boolean 是否导出成功
function M.export_session(session_id, export_path)
    if not state.initialized then
        error("History manager not initialized")
    end
    
    local session = state.sessions[session_id]
    if not session then
        return false
    end
    
    session:save(export_path)
    return true
end

--- 导入会话
--- @param import_path string 导入路径
--- @return string|nil 导入的会话ID
function M.import_session(import_path)
    if not state.initialized then
        error("History manager not initialized")
    end
    
    local session = Session.load(import_path)
    if not session then
        return nil
    end
    
    state.sessions[session.id] = session
    
    -- 自动保存到标准位置
    M._auto_save_session(session)
    
    return session.id
end

--- 清理旧消息
function M.cleanup()
    if not state.initialized then
        return
    end
    
    for _, session in pairs(state.sessions) do
        if #session.messages > state.max_history_per_session then
            local excess = #session.messages - state.max_history_per_session
            for i = 1, excess do
                table.remove(session.messages, 1)
            end
            session.metadata.message_count = #session.messages
            M._auto_save_session(session)
        end
    end
end

--- 获取会话文件路径（内部使用）
--- @param session_id string 会话ID
--- @return string 文件路径
function M._get_session_filepath(session_id)
    local save_path = state.config.save_path or vim.fn.stdpath("data") .. "/neoai_sessions"
    return save_path .. "/" .. session_id .. ".json"
end

--- 自动保存会话（内部使用）
--- @param session Session 会话对象
function M._auto_save_session(session)
    if not state.config.auto_save then
        return
    end
    
    local filepath = M._get_session_filepath(session.id)
    session:save(filepath)
end

--- 加载保存的会话（内部使用）
function M._load_sessions()
    if not state.config.auto_save then
        return
    end
    
    local save_path = state.config.save_path or vim.fn.stdpath("data") .. "/neoai_sessions"
    if vim.fn.isdirectory(save_path) == 0 then
        return
    end
    
    local files = vim.fn.glob(save_path .. "/*.json", false, true)
    for _, filepath in ipairs(files) do
        local session = Session.load(filepath)
        if session then
            state.sessions[session.id] = session
        end
    end
    
    -- 设置当前会话为最新的会话
    local sessions = M.get_sessions()
    if #sessions > 0 then
        state.current_session_id = sessions[1].id
    end
end

--- 获取配置
--- @return table 配置
function M.get_config()
    return vim.deepcopy(state.config)
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
    if not state.initialized then
        return
    end
    
    state.config = vim.tbl_extend("force", state.config, new_config or {})
    state.max_history_per_session = state.config.max_history_per_session or 100
end

return M