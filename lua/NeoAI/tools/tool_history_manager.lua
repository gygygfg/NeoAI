-- 历史管理器模块
-- 用于管理 Neovim 插件中的会话历史记录
local M = {}

-- 模块状态存储
-- 使用 local 变量确保模块状态私有化
local state = {
  sessions = {}, -- 存储所有会话的数组
  config = {}, -- 配置信息
  initialized = false, -- 模块是否已初始化
  max_sessions = 50, -- 最大会话数限制
}

--- 初始化历史管理器
--- @param config table 配置表，可选参数
--- 配置可包含：
---   - max_sessions: 最大会话数，默认 50
---   - api_key: API密钥，默认为空字符串
---   - max_tokens: 最大token数，默认 1000
---   - temperature: 温度参数，默认 0.7
---   - model: 模型名称，默认 "gpt-3.5-turbo"
function M.initialize(config)
  -- 如果已经初始化，直接返回避免重复初始化
  if state.initialized then
    return
  end

  -- 设置配置，如果传入nil则使用空表
  state.config = config or {}
  state.sessions = {}
  state.max_sessions = config.max_sessions or 50
  state.initialized = true

  -- 加载默认配置
  M._load_default_config()
end

--- 加载默认配置
-- 内部函数，确保配置中包含所有必需的字段
function M._load_default_config()
  -- 默认配置定义
  local default_config = {
    api_key = "", -- API密钥，默认为空
    max_tokens = 1000, -- 最大token数
    temperature = 0.7, -- 温度参数，控制生成随机性
    model = "gpt-3.5-turbo", -- 使用的模型
  }

  -- 合并配置：如果用户配置中没有某个字段，则使用默认值
  for key, value in pairs(default_config) do
    if state.config[key] == nil then
      state.config[key] = value
    end
  end
end

--- 添加新会话
--- @param session table 会话数据表
--- @return number 返回新会话在列表中的索引（位置）
function M.add_session(session)
  -- 如果会话没有ID，生成一个唯一ID
  if not session.id then
    session.id = "session_" .. os.time() .. "_" .. math.random(1000, 9999)
  end

  -- 设置时间戳
  session.created_at = os.time() -- 创建时间
  session.updated_at = os.time() -- 更新时间

  -- 将会话添加到列表
  table.insert(state.sessions, session)

  -- 清理旧会话，确保不超过最大数量限制
  M._cleanup_sessions()

  -- 返回新会话的索引
  return #state.sessions
end

--- 获取所有会话的副本
--- @return table 返回会话列表的深拷贝副本
function M.get_sessions()
  -- 使用深拷贝防止外部修改影响内部状态
  return vim.deepcopy(state.sessions)
end

--- 获取当前会话数量
--- @return number 返回会话总数
function M.get_session_count()
  return #state.sessions
end

--- 根据会话ID查找会话
--- @param session_id string 会话的唯一标识符
--- @return table|nil 找到则返回会话的副本，否则返回nil
function M.get_session(session_id)
  -- 遍历所有会话查找匹配的ID
  for _, session in ipairs(state.sessions) do
    if session.id == session_id then
      -- 返回深拷贝，防止外部修改
      return vim.deepcopy(session)
    end
  end

  -- 未找到返回nil
  return nil
end

--- 更新指定会话
--- @param session_id string 要更新的会话ID
--- @param updates table 包含更新字段的表
--- @return boolean 成功返回true，失败返回false
function M.update_session(session_id, updates)
  -- 遍历查找目标会话
  for _, session in ipairs(state.sessions) do
    if session.id == session_id then
      -- 更新所有提供的字段
      for key, value in pairs(updates) do
        session[key] = value
      end

      -- 更新修改时间
      session.updated_at = os.time()
      return true -- 更新成功
    end
  end

  return false -- 未找到会话，更新失败
end

--- 删除指定会话
--- @param session_id string 要删除的会话ID
--- @return boolean 成功删除返回true，否则返回false
function M.delete_session(session_id)
  -- 遍历查找目标会话
  for i, session in ipairs(state.sessions) do
    if session.id == session_id then
      -- 从数组中移除该会话
      table.remove(state.sessions, i)
      return true -- 删除成功
    end
  end

  return false -- 未找到会话，删除失败
end

--- 更新配置项
--- @param key string 配置键名
--- @param value any 配置值
function M.update_config(key, value)
  state.config[key] = value
end

--- 获取指定配置项的值
--- @param key string 配置键名
--- @return any 返回配置值，如果键不存在则返回nil
function M.get_config(key)
  return state.config[key]
end

--- 获取所有配置的副本
--- @return table 返回所有配置的深拷贝
function M.get_all_config()
  return vim.deepcopy(state.config)
end

--- 清理旧会话（内部函数）
-- 当会话数量超过最大限制时，按创建时间删除最旧的会话
function M._cleanup_sessions()
  -- 如果当前会话数未超过限制，直接返回
  if #state.sessions <= state.max_sessions then
    return
  end

  -- 按创建时间升序排序（最早的在前）
  table.sort(state.sessions, function(a, b)
    return a.created_at < b.created_at
  end)

  -- 删除最旧的会话，直到数量符合限制
  while #state.sessions > state.max_sessions do
    table.remove(state.sessions, 1)
  end
end

--- 导出所有会话历史到文件
--- @param filepath string 导出文件路径
--- @return boolean 导出是否成功
--- @return string|nil 如果失败，返回错误信息
function M.export_sessions(filepath)
  -- 准备导出数据
  local data = {
    sessions = state.sessions, -- 会话数据
    config = state.config, -- 配置数据
    export_time = os.time(), -- 导出时间戳
  }

  -- 将数据转换为JSON格式
  local content = vim.json.encode(data)

  -- 使用pcall安全地执行文件操作
  local success, err = pcall(function()
    local file = io.open(filepath, "w")
    if not file then
      error("无法打开文件: " .. filepath)
    end

    file:write(content)
    file:close()
  end)

  -- 返回操作结果
  if success then
    return true
  else
    return false, err
  end
end

--- 从文件导入会话历史
--- @param filepath string 导入文件路径
--- @return boolean 导入是否成功
--- @return string|nil 如果失败，返回错误信息
function M.import_sessions(filepath)
  -- 使用pcall安全地读取和解析文件
  local success, data = pcall(function()
    local file = io.open(filepath, "r")
    if not file then
      error("无法打开文件: " .. filepath)
    end

    local content = file:read("*a")
    file:close()
    return vim.json.decode(content)
  end)

  -- 如果文件读取或解析失败，返回错误
  if not success then
    return false, data
  end

  -- 导入会话数据
  if data.sessions then
    state.sessions = data.sessions
  end

  -- 导入配置数据（合并到现有配置）
  if data.config then
    for key, value in pairs(data.config) do
      state.config[key] = value
    end
  end

  -- 导入成功
  return true, nil
end

-- 导出模块
return M
