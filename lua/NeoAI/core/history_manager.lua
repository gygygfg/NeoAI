local M = {}

local SkipList = require("NeoAI.utils.skiplist")

-- 模块状态
local state = {
  initialized = false,
  event_bus = nil,
  config = nil,
  -- 会话跳表：按最后更新时间排序
  -- key = 时间戳键（os.time() * 1000000 + 计数器）
  -- value = Session 对象
  -- 不同层级 forward[i] 代表不同方向，高层快速定位最新会话
  sessions_skiplist = nil,
  -- 会话ID到跳表key的映射（O(1) 查找）
  session_id_map = {},
  current_session_id = nil,
  max_history_per_session = 100,
}

--- @class Session
--- @field id string 会话ID
--- @field name string 会话名称
--- @field metadata table 元数据
--- @field messages table[] 消息列表
--- @field branches table[] 分支列表
--- @field current_branch_id string|nil 当前分支ID

local Session = {}
Session.__index = Session

--- 生成跳表时间戳键
local function generate_skiplist_key()
  return os.time() * 1000000 + math.random(1, 999999)
end

--- 更新会话在跳表中的位置（会话更新后重新插入，保持排序）
local function update_session_in_skiplist(session)
  if not state.sessions_skiplist then return end
  local old_key = state.session_id_map[session.id]
  if old_key then
    state.sessions_skiplist:delete(old_key)
  end
  local new_key = generate_skiplist_key()
  state.sessions_skiplist:insert(new_key, session)
  state.session_id_map[session.id] = new_key
end

--- 创建新会话
--- @param id string|nil 会话ID
--- @param name string|nil 会话名称
--- @param metadata table|nil 元数据
--- @return Session
function Session:new(id, name, metadata)
  local obj = setmetatable({}, Session)
  obj.id = id or (tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)))
  obj.name = name or "新会话"
  obj.metadata = metadata or {
    created_at = os.time(),
    message_count = 0,
    last_updated = os.time(),
  }
  obj.messages = {}
  obj.branches = {}
  obj.current_branch_id = nil

  -- 创建默认分支
  obj:create_branch("主分支", nil, {
    created_at = os.time(),
    branch_id = "default",
    parent_branch_id = nil,
    is_default = true,
  })
  obj.current_branch_id = "default"

  return obj
end

--- 添加消息
function Session:add_message(role, content, metadata)
  local message = {
    id = #self.messages + 1,
    role = role,
    content = content,
    timestamp = os.time(),
    metadata = metadata or {},
  }
  table.insert(self.messages, message)
  self.metadata.message_count = #self.messages
  self.metadata.last_updated = os.time()
  update_session_in_skiplist(self)
  return message
end

--- 获取消息
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
function Session:create_branch(name, from_message_id, metadata)
  local branch = {
    id = #self.branches + 1,
    name = name or ("分支" .. tostring(#self.branches + 1)),
    from_message_id = from_message_id or #self.messages,
    created_at = os.time(),
    metadata = metadata or {},
    messages = {},
  }
  table.insert(self.branches, branch)
  return branch
end

--- 切换到分支
function Session:switch_branch(branch_id)
  for _, branch in ipairs(self.branches) do
    if branch.id == branch_id then
      self.current_branch_id = branch_id
      return true
    end
  end
  return false
end

--- 触发事件
local function trigger_event(event_name, data)
  if state.event_bus then
    state.event_bus.trigger(event_name, data)
  else
    vim.api.nvim_exec_autocmds("User", { pattern = event_name, data = data })
  end
end

--- 初始化历史管理器
function M.initialize(options)
  if state.initialized then return end

  options = options or {}
  state.event_bus = options.event_bus

  local input_config = options.config or options
  state.config = vim.deepcopy(input_config)

  if state.config.session and type(state.config.session) == "table" then
    for k, v in pairs(state.config.session) do
      state.config[k] = v
    end
    state.config.session = nil
  end

  state.config.auto_save = state.config.auto_save ~= false
  state.max_history_per_session = state.config.max_history_per_session
    or state.config.max_history or 100
  state.config.max_history = nil

  -- 初始化会话跳表
  state.sessions_skiplist = SkipList:new({
    max_level = 16,
    probability = 0.5,
    unique = true,
  })
  state.session_id_map = {}
  state.current_session_id = nil
  state.initialized = true
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

  local skiplist_key = generate_skiplist_key()
  state.sessions_skiplist:insert(skiplist_key, session)
  state.session_id_map[session.id] = skiplist_key
  state.current_session_id = session.id

  trigger_event("NeoAI:session_created", {
    session_id = session.id,
    session = {
      id = session.id,
      name = session.name,
      metadata = session.metadata,
      message_count = #session.messages,
    }
  })

  return session.id
end

--- 获取当前会话
--- @return Session|nil
function M.get_current_session()
  if not state.initialized or not state.current_session_id then
    return nil
  end
  local skiplist_key = state.session_id_map[state.current_session_id]
  if not skiplist_key then return nil end
  return state.sessions_skiplist:search(skiplist_key)
end

--- 切换到会话
--- @param session_id string 会话ID
--- @return boolean
function M.switch_session(session_id)
  if not state.initialized then
    error("History manager not initialized")
  end
  if not state.session_id_map[session_id] then
    return false
  end

  state.current_session_id = session_id

  trigger_event("NeoAI:session_changed", {
    session_id = session_id,
  })

  return true
end

--- 添加消息到当前会话
--- @param role string 角色
--- @param content string 内容
--- @param metadata table 元数据
--- @return table|nil
function M.add_message(role, content, metadata)
  local session = M.get_current_session()
  if not session then return nil end

  local message = session:add_message(role, content, metadata)

  trigger_event("NeoAI:message_added", {
    message_id = message.id,
    message = {
      id = message.id,
      role = message.role,
      content = message.content,
      timestamp = message.timestamp,
      metadata = message.metadata,
    }
  })

  return message
end

--- 获取当前会话的消息
--- @param limit number 限制数量
--- @return table
function M.get_messages(limit)
  local session = M.get_current_session()
  if not session then return {} end
  return session:get_messages(limit)
end

--- 获取所有会话（按最后更新时间逆序，最新的在前）
--- 利用跳表高层方向快速定位最新会话
--- @return table
function M.get_sessions()
  if not state.initialized then return {} end

  local sessions = {}
  for _, session in state.sessions_skiplist:iter(true) do
    table.insert(sessions, {
      id = session.id,
      name = session.name,
      metadata = session.metadata,
    })
  end
  return sessions
end

--- 删除会话
--- @param session_id string 会话ID
--- @return boolean
function M.delete_session(session_id)
  if not state.initialized then
    error("History manager not initialized")
  end

  local skiplist_key = state.session_id_map[session_id]
  if not skiplist_key then return false end

  if state.current_session_id == session_id then
    state.current_session_id = nil
  end

  state.sessions_skiplist:delete(skiplist_key)
  state.session_id_map[session_id] = nil

  trigger_event("NeoAI:session_deleted", {
    session_id = session_id
  })

  return true
end

--- 获取历史记录条目
--- @param session_id string 会话ID
--- @param branch_id number|nil 分支ID
--- @return table
function M.get_entries(session_id, branch_id)
  if not state.initialized then return {} end

  local skiplist_key = state.session_id_map[session_id]
  if not skiplist_key then return {} end

  local session = state.sessions_skiplist:search(skiplist_key)
  if not session then return {} end

  if branch_id then
    for _, branch in ipairs(session.branches) do
      if branch.id == branch_id then
        return vim.deepcopy(branch.messages or {})
      end
    end
    return {}
  end

  return session:get_messages()
end

--- 添加消息到指定会话和分支
--- @param session_id string 会话ID
--- @param branch_id number 分支ID
--- @param role string 角色
--- @param content string 内容
--- @param metadata table 元数据
--- @return table|nil
function M.add_message_to_branch(session_id, branch_id, role, content, metadata)
  local skiplist_key = state.session_id_map[session_id]
  if not skiplist_key then return nil end

  local session = state.sessions_skiplist:search(skiplist_key)
  if not session then return nil end

  local target_branch = nil
  for _, branch in ipairs(session.branches) do
    if branch.id == branch_id then
      target_branch = branch
      break
    end
  end
  if not target_branch then return nil end

  local message = {
    id = #(target_branch.messages or {}) + 1,
    role = role,
    content = content,
    timestamp = os.time(),
    metadata = metadata or {},
  }

  if not target_branch.messages then
    target_branch.messages = {}
  end
  table.insert(target_branch.messages, message)

  update_session_in_skiplist(session)

  return message
end

--- 清理旧消息
function M.cleanup()
  if not state.initialized then return end

  for _, session in state.sessions_skiplist:iter() do
    if #session.messages > state.max_history_per_session then
      local excess = #session.messages - state.max_history_per_session
      for i = 1, excess do
        table.remove(session.messages, 1)
      end
      session.metadata.message_count = #session.messages
    end
  end
end

--- 获取配置
--- @return table
function M.get_config()
  return vim.deepcopy(state.config or {})
end

--- 更新配置
function M.update_config(new_config)
  if not state.initialized then return end

  local config_to_merge = vim.deepcopy(new_config or {})
  if config_to_merge.session and type(config_to_merge.session) == "table" then
    for k, v in pairs(config_to_merge.session) do
      config_to_merge[k] = v
    end
    config_to_merge.session = nil
  end

  state.config = vim.tbl_extend("force", state.config, config_to_merge)
  state.max_history_per_session = state.config.max_history_per_session or 100
end

--- 重置（仅用于测试）
function M._test_reset()
  state.initialized = false
  state.event_bus = nil
  state.config = nil
  state.sessions_skiplist = nil
  state.session_id_map = {}
  state.current_session_id = nil
  state.max_history_per_session = 100
end

return M
