local M = {}

-- 模块状态
local state = {
  initialized = false,
  event_bus = nil,
  config = nil,
  sessions = {},
  current_session_id = nil,
  max_history_per_session = 100,
}

--- @class Session
--- @field id string 会话ID
--- @field name string 会话名称
--- @field metadata table 元数据
--- @field messages table[] 消息列表
--- @field branches table[] 分支列表
--- @field current_branch_id number|nil 当前分支ID
--- @field add_message fun(self: Session, role: string, content: string, metadata: table|nil): table 添加消息
--- @field get_messages fun(self: Session, limit: number|nil): table[] 获取消息
--- @field create_branch fun(self: Session, name: string|nil, from_message_id: number|nil, metadata: table|nil): table 创建分支
--- @field switch_branch fun(self: Session, branch_id: number): boolean 切换到分支
--- @field save fun(self: Session, filepath: string, config: table|nil): nil 保存会话到文件

-- 会话结构
local Session = {}
Session.__index = Session

--- 创建新会话
--- @param id string|nil 会话ID（可选）
--- @param name string|nil 会话名称（可选）
--- @param metadata table|nil 元数据（可选）
--- @return Session 新会话对象
function Session:new(id, name, metadata)
  local obj = setmetatable({}, Session)

  -- 生成与 sessions.json 格式兼容的 ID
  if id then
    obj.id = id
  else
    -- 生成基于时间戳的ID，确保唯一性
    -- 使用时间戳和随机数组合
    local timestamp = os.time()
    local random_num = math.random(1000, 9999)
    obj.id = tostring(timestamp) .. "_" .. tostring(random_num)
  end

  obj.name = name or "新会话"
  obj.metadata = metadata or {
    created_at = os.time(),
    message_count = 0,
    last_updated = os.time(),
  }
  obj.messages = {}
  obj.branches = {}
  obj.current_branch_id = nil
  return obj
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
    metadata = metadata or {},
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

-- 文件操作辅助函数
local function ensure_directory(dir)
  -- 检查 vim.fn 是否可用
  if vim and vim.fn and vim.fn.mkdir then
    return vim.fn.mkdir(dir, "p") == 1
  else
    -- 使用纯 Lua 实现，支持跨平台
    local success, err
    if package.config:sub(1, 1) == "\\" then
      -- Windows
      success = os.execute(string.format('if not exist "%s" mkdir "%s"', dir, dir)) == 0
    else
      -- Unix-like
      success = os.execute(string.format("mkdir -p '%s' 2>/dev/null", dir)) == 0
    end
    return success
  end
end

local function write_file(filepath, content)
  -- 检查 vim.fn 是否可用
  if vim and vim.fn and vim.fn.writefile then
    return vim.fn.writefile({ content }, filepath) == 0
  else
    -- 使用纯 Lua 实现
    local success, err = pcall(function()
      local file = io.open(filepath, "w")
      if not file then
        return false
      end
      file:write(content)
      file:close()
      return true
    end)
    return success
  end
end

--- 保存会话到文件
--- @param filepath string 文件路径
--- @param config table|nil 可选配置，用于备用目录
function Session:save(filepath, config)
  -- 转换会话数据为 sessions.json 格式
  -- 为 sessions.json 生成或查找数字ID
  local session_num_id = nil

  -- 首先检查这个会话是否已经存在于文件中
  if vim.fn.filereadable(filepath) == 1 then
    local content = vim.fn.readfile(filepath)
    if #content > 0 then
      local success, existing_sessions = pcall(vim.json.decode, table.concat(content, "\n"))
      if success and existing_sessions then
        -- 尝试通过名称和创建时间匹配现有会话
        for key, existing_session in pairs(existing_sessions) do
          if
            existing_session.name == self.name
            and existing_session.created_at == (self.metadata.created_at or os.time())
          then
            -- 找到匹配的会话，使用文件中的ID
            session_num_id = existing_session.id
            break
          end
        end

        -- 如果没有找到匹配的会话，生成新的ID
        if not session_num_id then
          local max_id = 0
          for key, _ in pairs(existing_sessions) do
            local num = tonumber(key)
            if num and num > max_id then
              max_id = num
            end
          end
          session_num_id = max_id + 1
        end
      end
    end
  end

  -- 如果文件不存在或读取失败，使用默认ID
  if not session_num_id then
    session_num_id = 1
  end

  local session_data = {
    messages = self.messages,
    export_time = os.time(),
    updated_at = self.metadata.last_updated or os.time(),
    name = self.name,
    id = session_num_id,
    created_at = self.metadata.created_at or os.time(),
    graph_relations = { children = {} },
    config = {
      max_history = state.max_history_per_session or 100,
      auto_scroll = true,
      show_timestamps = true,
    },
  }

  -- 获取目录路径
  local dir = filepath:match("(.*)/")
  if not dir then
    dir = "." -- 当前目录
  end

  -- 确保目录存在
  if not ensure_directory(dir) then
    -- 目录创建失败，尝试使用备用目录
    local backup_dir = nil

    -- 优先使用传入的配置中的保存路径
    if config and config.save_path then
      backup_dir = config.save_path
    else
      -- 使用默认的备用目录
      local home_dir = os.getenv("HOME") or "/tmp"
      backup_dir = home_dir .. "/.cache/nvim/NeoAI/"
    end

    if dir ~= backup_dir then
      filepath = backup_dir .. "sessions.json"
      dir = backup_dir
      ensure_directory(dir)
    end
  end

  -- 读取现有的 sessions.json 文件（如果存在）
  local all_sessions = {}
  if vim.fn.filereadable(filepath) == 1 then
    local content = vim.fn.readfile(filepath)
    if #content > 0 then
      local success, data = pcall(vim.json.decode, table.concat(content, "\n"))
      if success and data then
        all_sessions = data
      end
    end
  end

  -- 更新或添加当前会话
  all_sessions[tostring(session_data.id)] = session_data

  -- 更新内存中的会话ID以匹配保存的ID
  local old_id = self.id
  self.id = tostring(session_data.id)

  -- 如果ID改变了，需要更新state.sessions中的引用
  if old_id ~= self.id then
    -- 从旧的ID位置移除
    state.sessions[old_id] = nil
    -- 添加到新的ID位置
    state.sessions[self.id] = self

    -- 如果这是当前会话，更新current_session_id
    if state.current_session_id == old_id then
      state.current_session_id = self.id
    end
  end

  -- 写入文件
  local json_str = vim.json.encode(all_sessions)
  if not write_file(filepath, json_str) then
    -- 写入失败，尝试使用临时文件
    local temp_file = os.tmpname()
    if write_file(temp_file, json_str) then
      local cmd
      if package.config:sub(1, 1) == "\\" then
        cmd = string.format('move /Y "%s" "%s"', temp_file, filepath)
      else
        cmd = string.format("mv '%s' '%s' 2>/dev/null || cp '%s' '%s'", temp_file, filepath, temp_file, filepath)
      end
      os.execute(cmd)
    end
  end
end

--- 从文件加载会话
--- @param filepath string 文件路径
--- @param session_id string|nil 会话ID（仅当从 sessions.json 加载时需要）
--- @return Session|nil 加载的会话
function Session.load(filepath, session_id)
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

  -- 检查是否是 sessions.json 格式（包含多个会话）
  if data["1"] or data["2"] or data["3"] then
    -- 这是 sessions.json 格式，需要根据 session_id 获取特定会话
    if not session_id then
      -- 如果没有指定 session_id，返回第一个会话
      for key, session_data in pairs(data) do
        if key ~= "_graph" and type(session_data) == "table" and session_data.messages then
          -- 确保使用正确的会话ID
          local session_id_to_use = nil
          if session_data.id then
            session_id_to_use = tostring(session_data.id)
          else
            session_id_to_use = key
          end
          return Session._from_sessions_json_format(session_data, session_id_to_use)
        end
      end
      return nil
    else
      -- 查找指定 ID 的会话
      local session_data = data[tostring(session_id)]
      if session_data then
        -- 确保使用正确的会话ID
        local session_id_to_use = nil
        if session_data.id then
          session_id_to_use = tostring(session_data.id)
        else
          session_id_to_use = tostring(session_id)
        end
        return Session._from_sessions_json_format(session_data, session_id_to_use)
      end
      return nil
    end
  else
    -- 这是旧的单个会话文件格式
    local session = Session:new(data.id, data.name, data.metadata)
    session.messages = data.messages or {}
    session.branches = data.branches or {}
    session.current_branch_id = data.current_branch_id
    return session
  end
end

--- 从 sessions.json 格式转换会话数据
--- @param session_data table sessions.json 格式的会话数据
--- @param session_id string 会话ID
--- @return Session 转换后的会话对象
function Session._from_sessions_json_format(session_data, session_id)
  -- 转换 metadata
  local metadata = {
    created_at = session_data.created_at or os.time(),
    message_count = #(session_data.messages or {}),
    last_updated = session_data.updated_at or os.time(),
  }

  -- 创建会话对象
  local session = Session:new(session_id, session_data.name or "", metadata)

  -- 处理消息数据，确保格式正确
  local messages = {}

  for _, msg in ipairs(session_data.messages or {}) do
    -- 确保 metadata 是表而不是数组
    local msg_metadata = msg.metadata or {}
    if type(msg_metadata) == "table" and #msg_metadata > 0 then
      -- 如果是数组，转换为表
      local new_metadata = {}
      for i, v in ipairs(msg_metadata) do
        new_metadata[tostring(i)] = v
      end
      msg_metadata = new_metadata
    end

    -- 确保 id 是字符串（兼容数字和字符串ID）
    local msg_id = msg.id
    if type(msg_id) == "number" then
      msg_id = tostring(msg_id)
    end

    table.insert(messages, {
      id = msg_id or tostring(#messages + 1),
      role = msg.role or "user",
      content = msg.content or "",
      timestamp = msg.timestamp or os.time(),
      metadata = msg_metadata,
      editable = msg.editable or false,
    })
  end

  session.messages = messages
  session.branches = {} -- sessions.json 格式不支持分支
  session.current_branch_id = nil

  return session
end

--- 触发事件（内部使用）
--- @param event_name string 事件名称
--- @param data table 事件数据
local function trigger_event(event_name, data)
  if not state.event_bus then
    -- 如果没有事件总线，使用 Neovim 原生事件系统
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_name,
      data = data,
    })
  else
    -- 使用事件总线
    state.event_bus.trigger(event_name, data)
  end
end

--- 初始化历史管理器
--- @param options table 选项，包含 event_bus 和 config
function M.initialize(options)
  if state.initialized then
    return
  end

  options = options or {}
  state.event_bus = options.event_bus

  -- 注意：options 可能直接就是配置表，也可能包含在 config 字段中
  -- 为了兼容性，我们检查 options 是否有 config 字段
  local input_config = nil
  if options.config then
    input_config = options.config or {}
  else
    input_config = options or {}
  end

  -- 创建配置的副本，避免修改传入的配置表
  state.config = vim.deepcopy(input_config)

  -- 处理嵌套的 session 配置
  -- 如果配置中有 session 表，将其扁平化到顶层
  if state.config.session and type(state.config.session) == "table" then
    -- 将 session 表中的配置提取到顶层
    for key, value in pairs(state.config.session) do
      state.config[key] = value
    end
    -- 移除嵌套的 session 表，避免配置冲突
    state.config.session = nil
  end

  -- 确保配置有默认值
  local original_save_path = state.config.save_path
  state.config.save_path = state.config.save_path or vim.fn.stdpath("cache") .. "/neoai_sessions"

  state.config.auto_save = state.config.auto_save ~= false -- 默认开启自动保存
  state.config.auto_load = state.config.auto_load ~= false -- 默认开启自动加载

  -- 处理历史记录限制配置（支持两种字段名：max_history_per_session 和 max_history）
  local max_history_value = state.config.max_history_per_session or state.config.max_history
  state.config.max_history_per_session = max_history_value or 100

  -- 清理旧的字段名
  state.config.max_history = nil

  state.max_history_per_session = state.config.max_history_per_session
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

  -- 触发会话创建事件
  trigger_event("NeoAI:session_created", {
    session_id = session.id,
    session = {
      id = session.id,
      name = session.name,
      metadata = session.metadata,
      message_count = #session.messages,
    }
  })

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

  local old_session_id = state.current_session_id
  state.current_session_id = session_id
  
  -- 触发会话变更事件
  trigger_event("NeoAI:session_changed", {
    session_id = session_id,
    session = {
      id = session_id,
      name = state.sessions[session_id].name,
      metadata = state.sessions[session_id].metadata,
      message_count = #state.sessions[session_id].messages,
    }
  })
  
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
  
  -- 触发消息添加事件
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
      metadata = session.metadata,
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

  -- 从 sessions.json 文件中删除会话
  local filepath = M._get_session_filepath(session_id)
  if vim.fn.filereadable(filepath) == 1 then
    local content = vim.fn.readfile(filepath)
    if #content > 0 then
      local success, all_sessions = pcall(vim.json.decode, table.concat(content, "\n"))
      if success and all_sessions then
        -- 删除指定会话
        all_sessions[tostring(session_id)] = nil

        -- 保存更新后的文件
        local json_str = vim.json.encode(all_sessions)
        write_file(filepath, json_str)
      end
    end
  end

  -- 从内存中删除
  state.sessions[session_id] = nil
  
  -- 触发会话删除事件
  trigger_event("NeoAI:session_deleted", {
    session_id = session_id
  })

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

  session:save(export_path, state.config)
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

--- 获取历史记录条目
--- @param session_id string 会话ID
--- @param branch_id number|nil 分支ID
--- @return table 历史记录条目列表
function M.get_entries(session_id, branch_id)
  if not state.initialized then
    return {}
  end

  local session = state.sessions[session_id]
  if not session then
    return {}
  end

  -- 如果指定了分支ID，返回分支消息
  if branch_id then
    for _, branch in ipairs(session.branches) do
      if branch.id == branch_id then
        return vim.deepcopy(branch.messages or {})
      end
    end
    return {}
  end

  -- 否则返回会话的所有消息
  return session:get_messages()
end

--- 添加消息到指定会话和分支
--- @param session_id string 会话ID
--- @param branch_id number 分支ID
--- @param role string 角色
--- @param content string 内容
--- @param metadata table 元数据
--- @return table|nil 添加的消息
function M.add_message_to_branch(session_id, branch_id, role, content, metadata)
  local session = state.sessions[session_id]
  if not session then
    return nil
  end

  -- 查找分支
  local target_branch = nil
  for _, branch in ipairs(session.branches) do
    if branch.id == branch_id then
      target_branch = branch
      break
    end
  end

  if not target_branch then
    return nil
  end

  -- 创建消息
  local message = {
    id = #(target_branch.messages or {}) + 1,
    role = role,
    content = content,
    timestamp = os.time(),
    metadata = metadata or {},
  }

  -- 添加到分支消息列表
  if not target_branch.messages then
    target_branch.messages = {}
  end

  table.insert(target_branch.messages, message)

  -- 自动保存
  M._auto_save_session(session)

  return message
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
  local save_path = state.config.save_path or vim.fn.stdpath("cache") .. "/NeoAI"
  return save_path .. "/sessions.json"
end

--- 自动保存会话（内部使用）
--- @param session Session 会话对象
function M._auto_save_session(session)
  if not state.config.auto_save then
    return
  end

  local filepath = M._get_session_filepath(session.id)
  session:save(filepath, state.config)
  
  -- 触发会话保存事件
  trigger_event("NeoAI:session_saved", {
    session_id = session.id,
    filepath = filepath,
    session = {
      id = session.id,
      name = session.name,
      metadata = session.metadata,
      message_count = #session.messages,
    }
  })
end

--- 加载保存的会话（内部使用）
function M._load_sessions()
  -- 检查是否启用自动加载
  if not state.config.auto_load then
    return
  end

  local save_path = state.config.save_path or vim.fn.stdpath("cache") .. "/NeoAI"
  local sessions_file = save_path .. "/sessions.json"

  -- 如果目录不存在，创建它
  if vim.fn.isdirectory(save_path) == 0 then
    ensure_directory(save_path)
  end

  -- 检查 sessions.json 文件是否存在
  if vim.fn.filereadable(sessions_file) == 1 then
    -- 从 sessions.json 加载所有会话
    local content = vim.fn.readfile(sessions_file)
    if #content > 0 then
      local success, all_sessions = pcall(vim.json.decode, table.concat(content, "\n"))
      if success and all_sessions then
        -- 加载所有会话
        for session_id_str, session_data in pairs(all_sessions) do
          -- 跳过 _graph 等非会话数据
          if session_id_str ~= "_graph" and type(session_data) == "table" and session_data.messages ~= nil then
            -- 确保使用正确的会话ID
            -- 优先使用 session_data.id（数字），如果不存在则使用 session_id_str（字符串）
            local session_id_to_use = nil
            if session_data.id then
              session_id_to_use = tostring(session_data.id)
            else
              session_id_to_use = session_id_str
            end

            local session = Session._from_sessions_json_format(session_data, session_id_to_use)
            if session then
              state.sessions[session.id] = session
              
              -- 触发会话加载事件
              trigger_event("NeoAI:session_loaded", {
                new_session_id = session.id,
                filepath = sessions_file,
                session = {
                  id = session.id,
                  name = session.name,
                  metadata = session.metadata,
                  message_count = #session.messages,
                }
              })
            end
          end
        end
      end
    end
  else
    -- 向后兼容：尝试从旧的单个文件格式加载
    local old_save_path = vim.fn.stdpath("cache") .. "/neoai_sessions"
    if vim.fn.isdirectory(old_save_path) == 1 then
      local files = vim.fn.glob(old_save_path .. "/*.json", false, true)
      for _, filepath in ipairs(files) do
        local session = Session.load(filepath)
        if session then
          state.sessions[session.id] = session
        end
      end
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
  return vim.deepcopy(state.config or {})
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  -- 处理嵌套的 session 配置
  local config_to_merge = vim.deepcopy(new_config or {})

  -- 如果新配置中有 session 表，将其扁平化到顶层
  if config_to_merge.session and type(config_to_merge.session) == "table" then
    -- 将 session 表中的配置提取到顶层
    for key, value in pairs(config_to_merge.session) do
      config_to_merge[key] = value
    end
    -- 移除嵌套的 session 表，避免与顶层配置冲突
    config_to_merge.session = nil
  end

  state.config = vim.tbl_extend("force", state.config, config_to_merge)
  state.max_history_per_session = state.config.max_history_per_session or 100
end

--- 重置历史管理器状态（仅用于测试）
function M._test_reset()
  state.initialized = false
  state.event_bus = nil
  state.config = nil
  state.sessions = {}
  state.current_session_id = nil
  state.max_history_per_session = 100
end

return M
