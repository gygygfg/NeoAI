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
  config = nil,
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
    config = state.config,
  })

  message_manager.initialize({
    event_bus = state.event_bus,
    config = state.config,
  })

  data_operations.initialize({
    event_bus = state.event_bus,
    config = state.config,
  })

  -- 加载保存的会话
  if state.config.auto_save and state.config.save_path then
    M._load_sessions()
  end

  state.initialized = true
  return M
end

--- 内部函数：查找空会话
local function find_empty_session()
  for session_id, session in pairs(sessions) do
    -- 检查会话是否为空（没有消息）
    local branch_id = session.current_branch

    if branch_id then
      local message_count = message_manager.get_message_count(branch_id)
      if message_count == 0 then
        -- 这是一个空会话
        return session_id, session
      end
    end
  end

  return nil, nil
end

--- 内部函数：确保有当前会话
local function ensure_current_session()
  if not current_session_id then
    -- 首先检查是否有空会话可用
    local empty_session_id, empty_session = find_empty_session()

    if empty_session_id then
      -- 使用现有的空会话
      current_session_id = empty_session_id

      -- 触发事件
      vim.api.nvim_exec_autocmds(
        "User",
        { pattern = "NeoAI:session_reused", data = { current_session_id, empty_session } }
      )
    else
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
        branches = { [branch_id] = true },
        current_branch = branch_id,
      }

      -- 触发事件
      vim.api.nvim_exec_autocmds(
        "User",
        { pattern = "NeoAI:session_created", data = { current_session_id, sessions[current_session_id] } }
      )
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
    current_branch = nil,
  }

  sessions[session_id] = session
  current_session_id = session_id

  -- 创建默认分支
  -- 注意：分支ID需要包含会话ID前缀以避免冲突
  local branch_id = "session_" .. session_counter .. "_branch_main"

  -- 在分支管理器中创建分支（无父分支）
  local created_branch_id = branch_manager.create_branch("", "main")

  -- 使用我们生成的ID，但确保分支管理器中的ID匹配
  -- 这里我们假设分支管理器会使用我们提供的ID
  session.current_branch = branch_id
  session.branches[branch_id] = true

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:session_created", data = { session_id, session } })

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

  if not current_session_id then
    return nil
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
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:session_changed", data = { session_id, sessions[session_id] } })
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
      branch_count = #vim.tbl_keys(session.branches),
    })
  end

  return result
end

--- 删除会话
--- @param session_id string 会话ID
--- @return boolean 是否成功删除
function M.delete_session(session_id)
  if not sessions[session_id] then
    return false
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
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:session_deleted", data = { session_id } })

  -- 自动保存
  if state.config.auto_save then
    M._save_sessions()
  end

  return true
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
  if not state.config.auto_save or not state.config.save_path then
    return
  end

  local save_path = state.config.save_path

  -- 确保目录存在
  if vim.fn.isdirectory(save_path) == 0 then
    vim.fn.mkdir(save_path, "p")
    return
  end

  -- 首先尝试加载 sessions.json 文件（新格式）
  local sessions_file = save_path .. "/sessions.json"
  if vim.fn.filereadable(sessions_file) == 1 then
    local content = vim.fn.readfile(sessions_file)
    if #content > 0 then
      local success, all_sessions = pcall(vim.json.decode, table.concat(content, "\n"))
      if success and all_sessions then
        -- 加载所有会话
        for session_id_str, session_data in pairs(all_sessions) do
          -- 跳过 _graph 等非会话数据
          if session_id_str ~= "_graph" and type(session_data) == "table" and session_data.messages ~= nil then
            -- 转换会话数据格式
            local session = {
              id = session_id_str,
              name = session_data.name or "会话 " .. session_id_str,
              created_at = session_data.created_at or os.time(),
              updated_at = session_data.updated_at or os.time(),
              messages = {},
              branches = {},
              current_branch = nil,
              metadata = {
                message_count = #(session_data.messages or {}),
              },
            }
            
            -- 创建默认分支
            local branch_id = "branch_main"
            session.branches = { [branch_id] = true }
            session.current_branch = branch_id
            
            -- 转换消息格式
            for _, msg in ipairs(session_data.messages or {}) do
              table.insert(session.messages, {
                id = tostring(msg.id or #session.messages + 1),
                role = msg.role or "user",
                content = msg.content or "",
                timestamp = msg.timestamp or os.time(),
                metadata = type(msg.metadata) == "table" and msg.metadata or {},
              })
            end
            
            sessions[session.id] = session
            
            -- 更新会话计数器
            local session_num = tonumber(session_id_str)
            if session_num and session_num > session_counter then
              session_counter = session_num
            end
          end
        end
        
        -- 如果成功加载了 sessions.json，就不需要加载单独的会话文件了
        return
      end
    end
  end

  -- 向后兼容：加载单独的会话文件（旧格式）
  local files = vim.fn.glob(save_path .. "/*.json", false, true)

  for _, filepath in ipairs(files) do
    -- 跳过 sessions.json 文件，因为我们已经处理过了
    if not filepath:match("sessions%.json$") then
      local content = vim.fn.readfile(filepath)
      if #content > 0 then
        local data = vim.json.decode(table.concat(content, "\n"))
        if data and data.id then
          sessions[data.id] = data

          -- 更新会话计数器
          local session_num = tonumber(data.id:match("session_(%d+)"))
          if session_num and session_num > session_counter then
            session_counter = session_num
          end
        end
      end
    end
  end
end

-- 设置当前会话为最新的会话
local latest_session = nil
local latest_time = 0

for session_id, session in pairs(sessions) do
  if session.updated_at and session.updated_at > latest_time then
    latest_time = session.updated_at
    latest_session = session_id
  end
end

if latest_session then
  current_session_id = latest_session
end

--- 重置会话管理器（主要用于测试）
function M.reset()
  sessions = {}
  current_session_id = nil
  session_counter = 0
  state.initialized = false
  state.event_bus = nil
  state.config = nil

  -- 重置子模块
  branch_manager.reset()
  message_manager.reset()
  data_operations.reset()

  return true
end

--- 保存会话（内部使用）
function M._save_sessions()
  if not state.config.auto_save or not state.config.save_path then
    return
  end

  local save_path = state.config.save_path

  -- 确保目录存在
  if vim.fn.isdirectory(save_path) == 0 then
    vim.fn.mkdir(save_path, "p")
  end

  -- 保存所有会话
  for session_id, session in pairs(sessions) do
    local filepath = save_path .. "/" .. session_id .. ".json"
    local data = vim.deepcopy(session)

    -- 确保数据格式正确
    data.id = session_id
    data.updated_at = os.time()

    local json_str = vim.json.encode(data)
    vim.fn.writefile({ json_str }, filepath)
  end
end

return M

