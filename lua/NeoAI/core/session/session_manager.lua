local M = {}

local logger = require("NeoAI.utils.logger")
local branch_manager = require("NeoAI.core.session.branch_manager")
local message_manager = require("NeoAI.core.session.message_manager")
local data_operations = require("NeoAI.core.session.data_operations")
local Events = require("NeoAI.core.events.event_constants")

-- 会话存储
local sessions = {}
local current_session_id = nil
local session_counter = 0

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  save_debounce_timer = nil, -- 保存防抖定时器
  autocmd_ids = {}, -- 自动命令ID列表
}

--- 防抖保存（内部使用）
--- 需求4: 确保修改后自动保存，使用防抖避免频繁写入
local function debounce_save()
  if not state.config.auto_save or not state.config.save_path then
    return
  end
  if state.save_debounce_timer then
    state.save_debounce_timer:stop()
    state.save_debounce_timer:close()
    state.save_debounce_timer = nil
  end
  state.save_debounce_timer = vim.loop.new_timer()
  state.save_debounce_timer:start(500, 0, vim.schedule_wrap(function()
    if state.save_debounce_timer then
      state.save_debounce_timer:close()
      state.save_debounce_timer = nil
    end
    M._save_sessions()
  end))
end

--- 初始化会话管理器
--- @param options table 选项
--- @return table 会话管理器实例
function M.initialize(options)
  if state.initialized then
    return M
  end

  state.config = options.config or {}
  
  -- 处理 session 配置
  if state.config.session then
    -- 将 session 配置合并到根配置中，以便向后兼容
    for key, value in pairs(state.config.session) do
      if state.config[key] == nil then
        state.config[key] = value
      end
    end
  end

  -- 初始化子模块
  branch_manager.initialize({
    config = state.config,
  })

  message_manager.initialize({
    config = state.config,
  })

  data_operations.initialize({
    config = state.config,
  })

  -- 加载保存的会话
  if state.config.auto_save and state.config.save_path then
    M._load_sessions()
  end

  -- 监听高级事件，触发自动保存
  -- 只在用户发送、工具完成、AI生成完成/取消时触发保存
  state.autocmd_ids = {}
  
  local autocmd_patterns = {
    Events.GENERATION_COMPLETED,
    Events.GENERATION_CANCELLED,
    Events.GENERATION_ERROR,
    Events.TOOL_RESULT_RECEIVED,
  }
  
  for _, pattern in ipairs(autocmd_patterns) do
    local autocmd_id = vim.api.nvim_create_autocmd("User", {
      pattern = pattern,
      callback = function(args)
        if state.config.auto_save then
          debounce_save()
        end
      end,
    })
    table.insert(state.autocmd_ids, autocmd_id)
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
        { pattern = Events.SESSION_REUSED, data = { session_id = current_session_id, session = empty_session } }
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
        { pattern = Events.SESSION_CREATED, data = { session_id = current_session_id, session = sessions[current_session_id] } }
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

  -- 在分支管理器中创建分支（无父分支）
  local branch_id = branch_manager.create_branch("", "main")

  session.current_branch = branch_id
  session.branches[branch_id] = true

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { pattern = Events.SESSION_CREATED, data = { session_id = session_id, session = session } })

  -- 自动保存
  debounce_save()


  -- 同步到 tree_manager
  pcall(function()
    local tree_mgr = require("NeoAI.core.session.tree_manager")
    if tree_mgr.is_initialized and tree_mgr.is_initialized() then
      tree_mgr.sync_from_session_manager()
    end
  end)

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
  vim.api.nvim_exec_autocmds("User", { pattern = Events.SESSION_CHANGED, data = { session_id = session_id, session = sessions[session_id] } })
end

--- 获取或创建当前会话（仅在需要时创建）
--- @param session_name string 会话名称（可选）
--- @return table 当前会话
function M.get_or_create_current_session(session_name)
  if current_session_id and sessions[current_session_id] then
    return M.get_session(current_session_id)
  end

  -- 没有当前会话，创建一个
  local session_id = M.create_session(session_name or "default")
  return M.get_session(session_id)
end

--- 列出所有会话
--- @return table 会话列表
function M.list_sessions()
  local result = {}
  for id, session in pairs(sessions) do
    -- 计算消息数量
    local message_count = 0
    if session.messages then
      message_count = #session.messages
    elseif session.metadata and session.metadata.message_count then
      message_count = session.metadata.message_count
    end
    
    table.insert(result, {
      id = id,
      name = session.name,
      created_at = session.created_at,
      updated_at = session.updated_at,
      branch_count = #vim.tbl_keys(session.branches),
      metadata = {
        message_count = message_count,
      },
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
  vim.api.nvim_exec_autocmds("User", { pattern = Events.SESSION_DELETED, data = { session_id = session_id } })

  -- 自动保存
  debounce_save()


  -- 同步到 tree_manager
  pcall(function()
    local tree_mgr = require("NeoAI.core.session.tree_manager")
    if tree_mgr.is_initialized and tree_mgr.is_initialized() then
      -- 删除 tree_manager 中的对应节点
      pcall(tree_mgr.delete_node, session_id)
    end
  end)

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

--- 从 sessions.json 加载单个会话（内部使用）
--- @param session_id_str string 会话ID字符串
--- @param session_data table 会话数据
--- @param sessions_file string 文件路径
local function load_session_from_json(session_id_str, session_data, sessions_file)
  local session_id = "session_" .. session_id_str
  local session = {
    id = session_id,
    name = session_data.name or ("会话 " .. session_id_str),
    created_at = session_data.created_at or os.time(),
    updated_at = session_data.updated_at or os.time(),
    messages = {},
    branches = {},
    current_branch = nil,
    metadata = { message_count = #(session_data.messages or {}) },
  }

  local branch_id = session_data.current_branch_id
  if not branch_id or not session_data.branches or not session_data.branches[branch_id] then
    if session_data.branches then
      for bid, _ in pairs(session_data.branches) do
        branch_id = bid
        break
      end
    end
  end

  -- 修复：为每个 session 创建独立的分支，避免多个 session 共享同一个分支
  -- 如果分支不存在（如重置后），创建新分支并更新消息的 branch_id
  if not branch_id then
    branch_id = branch_manager.create_branch("", "main")
  else
    local existing_branch = branch_manager.get_branch(branch_id)
    if not existing_branch then
      -- 分支不存在，创建新分支
      local new_branch_id = branch_manager.create_branch("", "main")
      -- 更新消息中的 branch_id 为新分支
      for _, msg in ipairs(session_data.messages or {}) do
        msg.branch_id = new_branch_id
      end
      branch_id = new_branch_id
    end
  end

  session.branches = { [branch_id] = true }
  session.current_branch = branch_id

  for _, msg in ipairs(session_data.messages or {}) do
    local msg_branch_id = msg.branch_id or branch_id
    message_manager.add_message(
      msg_branch_id, msg.role or "user", msg.content or "",
      type(msg.metadata) == "table" and msg.metadata or {}
    )
  end

  sessions[session_id] = session

  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.SESSION_LOADED,
    data = { new_session_id = session_id, filepath = sessions_file, session = session }
  })

  local session_num = tonumber(session_id_str)
  if session_num and session_num > session_counter then
    session_counter = session_num
  end
end

--- 同步到 tree_manager（内部使用）
local function sync_tree_manager()
  pcall(function()
    local tree_mgr = require("NeoAI.core.session.tree_manager")
    if tree_mgr.is_initialized and tree_mgr.is_initialized() then
      local tree_data = tree_mgr.get_tree()
      local has_real_nodes = false
      if tree_data then
        for _, node in ipairs(tree_data) do
          if node.type == "virtual_root" and node.children and #node.children > 0 then
            has_real_nodes = true
            break
          end
        end
      end
      if not has_real_nodes then
        tree_mgr.sync_from_session_manager()
      end
    end
  end)
end

--- 设置最新会话为当前会话（内部使用）
local function set_latest_session_as_current()
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
end

--- 加载会话（内部使用）
function M._load_sessions()
  if not state.config.auto_save or not state.config.save_path then
    return
  end

  local save_path = state.config.save_path
  if vim.fn.isdirectory(save_path) == 0 then
    vim.fn.mkdir(save_path, "p")
    return
  end

  -- 加载 sessions.json（新格式）
  local sessions_file = save_path .. "/sessions.json"
  if vim.fn.filereadable(sessions_file) == 1 then
    local content = vim.fn.readfile(sessions_file)
    if #content > 0 then
      local success, all_sessions = pcall(vim.json.decode, table.concat(content, "\n"))
      if success and all_sessions then
        for session_id_str, session_data in pairs(all_sessions) do
          if session_id_str ~= "_graph" and type(session_data) == "table" and session_data.messages ~= nil then
            load_session_from_json(session_id_str, session_data, sessions_file)
          end
        end
        sync_tree_manager()
        return
      end
    end
  end

  -- 向后兼容：加载单独的会话文件（旧格式）
  local files = vim.fn.glob(save_path .. "/*.json", false, true)
  for _, filepath in ipairs(files) do
    if not filepath:match("sessions%.json$") then
      local content = vim.fn.readfile(filepath)
      if #content > 0 then
        local data = vim.json.decode(table.concat(content, "\n"))
        if data and data.id then
          for _, msg in ipairs(data.messages or {}) do
            message_manager.add_message(
              msg.branch_id, msg.role or "user", msg.content or "",
              type(msg.metadata) == "table" and msg.metadata or {}
            )
          end
          data.messages = nil
          sessions[data.id] = data
          vim.api.nvim_exec_autocmds("User", {
            pattern = Events.SESSION_LOADED,
            data = { new_session_id = data.id, filepath = filepath, session = data }
          })
          local session_num = tonumber(data.id:match("session_(%d+)"))
          if session_num and session_num > session_counter then
            session_counter = session_num
          end
        end
      end
    end
  end

  sync_tree_manager()
  set_latest_session_as_current()
end

--- 检查是否已初始化
--- @return boolean 是否已初始化
function M.is_initialized()
  return state.initialized
end

--- 重置会话管理器（主要用于测试）
function M.reset()
  sessions = {}
  current_session_id = nil
  session_counter = 0
  state.initialized = false
  state.config = nil
  if state.save_debounce_timer then
    state.save_debounce_timer:stop()
    state.save_debounce_timer:close()
    state.save_debounce_timer = nil
  end

  -- 清理自动命令
  if state.autocmd_ids then
    for _, autocmd_id in ipairs(state.autocmd_ids) do
      pcall(vim.api.nvim_del_autocmd, autocmd_id)
    end
    state.autocmd_ids = {}
  end

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

  -- 构建 sessions.json 格式的数据
  -- 格式：{ "1": { id: 1, name: "...", messages: [...], ... }, "2": { ... } }
  local sessions_json_data = {}

  -- 保存所有会话到统一的 sessions.json
  for session_id, session in pairs(sessions) do
    -- 收集消息数据
    local messages = {}
    for branch_id, _ in pairs(session.branches) do
      local branch_msgs = message_manager.get_messages(branch_id, 1000000)
      for _, msg in ipairs(branch_msgs) do
        table.insert(messages, msg)
      end
    end

    -- 构建 sessions.json 格式的数据
    local session_num = session_id:match("session_(%d+)")
    if session_num then
      sessions_json_data[session_num] = {
        id = tonumber(session_num),
        name = session.name or ("会话 " .. session_num),
        created_at = session.created_at or os.time(),
        updated_at = os.time(),
        messages = messages,
        config = {
          max_history = 100,
          auto_scroll = true,
          show_timestamps = true,
        },
        branches = session.branches,
        current_branch_id = session.current_branch,
      }
    end

    -- 触发会话保存事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.SESSION_SAVED,
      data = {
        session_id = session_id,
        filepath = save_path .. "/sessions.json",
        session = session
      }
    })
  end

  -- 保存 sessions.json
  if next(sessions_json_data) then
    local sessions_json_path = save_path .. "/sessions.json"
    local json_str = vim.json.encode(sessions_json_data)
    vim.fn.writefile({ json_str }, sessions_json_path)
  end
end

return M

