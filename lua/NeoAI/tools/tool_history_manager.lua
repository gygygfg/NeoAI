-- 历史管理器模块
local M = {}

-- 模块状态
local state = {
    sessions = {},
    config = {},
    initialized = false,
    max_sessions = 50
}

--- 初始化历史管理器
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    
    state.config = config or {}
    state.sessions = {}
    state.max_sessions = config.max_sessions or 50
    state.initialized = true
    
    -- 加载默认配置
    M._load_default_config()

--- 加载默认配置
function M._load_default_config()
    -- 确保配置包含必需字段
    local default_config = {
        api_key = "",
        max_tokens = 1000,
        temperature = 0.7,
        model = "gpt-3.5-turbo"
    }
    
    -- 合并配置
    for key, value in pairs(default_config) do
        if state.config[key] == nil then
            state.config[key] = value
        
    

--- 添加会话
--- @param session table 会话数据
--- @return number 会话ID
function M.add_session(session)
    if not session.id then
        session.id = "session_" .. os.time() .. "_" .. math.random(1000, 9999)
    
    session.created_at = os.time()
    session.updated_at = os.time()
    
    table.insert(state.sessions, session)
    
    -- 清理旧会话
    M._cleanup_sessions()
    
    return #state.sessions

--- 获取会话列表
--- @return table 会话列表
function M.get_sessions()
    return vim.deepcopy(state.sessions)

--- 获取会话数量
--- @return number 会话数量
function M.get_session_count()
    return #state.sessions

--- 获取会话
--- @param session_id string 会话ID
--- @return table|nil 会话数据
function M.get_session(session_id)
    for _, session in ipairs(state.sessions) do
        if session.id == session_id then
            return vim.deepcopy(session)
        
    
    return nil

--- 更新会话
--- @param session_id string 会话ID
--- @param updates table 更新数据
--- @return boolean 是否更新成功
function M.update_session(session_id, updates)
    for _, session in ipairs(state.sessions) do
        if session.id == session_id then
            for key, value in pairs(updates) do
                session[key] = value
            
            session.updated_at = os.time()
            return true
        
    
    return false

--- 删除会话
--- @param session_id string 会话ID
--- @return boolean 是否删除成功
function M.delete_session(session_id)
    for i, session in ipairs(state.sessions) do
        if session.id == session_id then
            table.remove(state.sessions, i)
            return true
        
    
    return false

--- 更新配置
--- @param key string 配置键
--- @param value any 配置值
function M.update_config(key, value)
    state.config[key] = value

--- 获取配置
--- @param key string 配置键
--- @return any 配置值
function M.get_config(key)
    return state.config[key]

--- 获取所有配置
--- @return table 所有配置
function M.get_all_config()
    return vim.deepcopy(state.config)

--- 清理旧会话
function M._cleanup_sessions()
    if #state.sessions <= state.max_sessions then
        return
    
    -- 按创建时间排序
    table.sort(state.sessions, function(a, b)
        return a.created_at < b.created_at
    end)
    
    -- 删除最旧的会话
    while #state.sessions > state.max_sessions do
        table.remove(state.sessions, 1)
    

--- 导出会话历史
--- @param filepath string 文件路径
--- @return boolean 是否导出成功
function M.export_sessions(filepath)
    local data = {
        sessions = state.sessions,
        config = state.config,
        export_time = os.time(})
    }
    
    local content = vim.json.encode(data)
    
    local success, err = pcall(function()
        local file = io.open(filepath, "w")
        if not file then
            error("无法打开文件: " .. filepath)
        
        file:write(content)
        file:close()
    end)
    
    return success, err

--- 导入会话历史
--- @param filepath string 文件路径
--- @return boolean 是否导入成功
function M.import_sessions(filepath)
    local success, data = pcall(function()
        local file = io.open(filepath, "r")
        if not file then
            error("无法打开文件: " .. filepath)
        
        local content = file:read("*a")
        file:close()
        return vim.json.decode(content)
    end)
    
    if not success then
        return false, data
    
    if data.sessions then
        state.sessions = data.sessions
    
    if data.config then
        for key, value in pairs(data.config) do
            state.config[key] = value
        
    
    return true

return M