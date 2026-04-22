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
  save_debounce_timer = nil, -- 保存防抖定时器
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
        { pattern = "NeoAI:session_reused", data = { session_id = current_session_id, session = empty_session } }
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
        { pattern = "NeoAI:session_created", data = { session_id = current_session_id, session = sessions[current_session_id] } }
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
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:session_created", data = { session_id = session_id, session = session } })

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
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:session_changed", data = { session_id = session_id, session = sessions[session_id] } })
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
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:session_deleted", data = { session_id = session_id } })

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
            -- 使用一致的会话ID格式：session_<数字>
            local session_id = "session_" .. session_id_str
            local session = {
              id = session_id,
name = session_data.name or ("会话 " .. session_id_str),
              created_at = session_data.created_at or os.time(),
              updated_at = session_data.updated_at or os.time(),
              messages = {},
              branches = {},
              current_branch = nil,
              metadata = {
                message_count = #(session_data.messages or {}),
              },
            }
            
            -- 使用保存时的分支ID，确保与消息中的 branch_id 一致
            -- 优先使用保存的 current_branch_id
            local branch_id = session_data.current_branch_id
            if not branch_id or not session_data.branches or not session_data.branches[branch_id] then
              -- 如果保存的分支ID无效，使用第一个可用的分支ID
              if session_data.branches then
                for bid, _ in pairs(session_data.branches) do
                  branch_id = bid
                  break
                end
              end
            end
            if not branch_id then
              -- 创建默认分支
              branch_id = branch_manager.create_branch("", "main")
            else
              -- 检查分支是否已在 branch_manager 中存在
              local existing_branch = branch_manager.get_branch(branch_id)
              if not existing_branch then
                -- 分支不存在，直接创建（不通过 branch_manager.create_branch 以避免ID自增不匹配）
                -- 手动在 branch_manager 中注册这个分支
                local bm = branch_manager
                -- 直接操作 branch_manager 的内部状态来创建分支
                -- 由于 branch_manager 没有提供指定ID的API，我们通过 create_branch 创建
                -- 然后重命名ID（这不太优雅，但能工作）
                -- 更好的方式：直接使用保存的分支ID，不依赖 branch_manager 的计数器
                local new_id = branch_manager.create_branch("", "main")
                -- 如果新创建的ID与保存的ID不同，我们需要调整
                -- 但消息的 branch_id 是保存时的值，所以消息会使用保存的 branch_id
                -- 而会话的 current_branch 也使用保存的 branch_id
                -- 所以这里我们直接使用保存的 branch_id，消息也会使用保存的 branch_id
                -- 这样即使 branch_manager 中注册的分支ID不同，也不影响消息的存取
                -- 因为 message_manager 是按 branch_id 存取消息的
                branch_id = session_data.current_branch_id or new_id
              end
            end
            session.branches = { [branch_id] = true }
            session.current_branch = branch_id
            
            -- 恢复消息到 message_manager，使用保存时的 branch_id
            for _, msg in ipairs(session_data.messages or {}) do
              local msg_branch_id = msg.branch_id or branch_id
              message_manager.add_message(
                msg_branch_id,
                msg.role or "user",
                msg.content or "",
                type(msg.metadata) == "table" and msg.metadata or {}
              )
            end
            
            sessions[session_id] = session
            
            -- 触发会话加载事件
            vim.api.nvim_exec_autocmds("User", {
              pattern = "NeoAI:session_loaded",
              data = {
                new_session_id = session_id,
                filepath = sessions_file,
                session = session
              }
            })
            
            -- 更新会话计数器
            local session_num = tonumber(session_id_str)
            if session_num and session_num > session_counter then
              session_counter = session_num
            end
          end
        end
        
        -- 如果成功加载了 sessions.json，就不需要加载单独的会话文件了
        -- 但仍然需要同步到 tree_manager
        pcall(function()
          local tree_mgr = require("NeoAI.core.session.tree_manager")
          if tree_mgr.is_initialized and tree_mgr.is_initialized() then
            tree_mgr.sync_from_session_manager()
          end
        end)
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
          -- 恢复消息到 message_manager
          if data.messages then
            for _, msg in ipairs(data.messages) do
              message_manager.add_message(msg.branch_id, msg.role, msg.content, msg.metadata)
            end
          end
          -- 清除 messages 字段避免冗余
          data.messages = nil
          
          sessions[data.id] = data
          
          -- 触发会话加载事件（旧格式）
          vim.api.nvim_exec_autocmds("User", {
            pattern = "NeoAI:session_loaded",
            data = {
              new_session_id = data.id,
              filepath = filepath,
              session = data
            }
          })

          -- 更新会话计数器
          local session_num = tonumber(data.id:match("session_(%d+)"))
          if session_num and session_num > session_counter then
            session_counter = session_num
          end
        end
      end
    end
  end

  -- 加载完成后同步到 tree_manager
  pcall(function()
    local tree_mgr = require("NeoAI.core.session.tree_manager")
    if tree_mgr.is_initialized and tree_mgr.is_initialized() then
      tree_mgr.sync_from_session_manager()
    end
  end)

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
  state.event_bus = nil
  state.config = nil
  if state.save_debounce_timer then
    state.save_debounce_timer:stop()
    state.save_debounce_timer:close()
    state.save_debounce_timer = nil
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
      pattern = "NeoAI:session_saved",
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

