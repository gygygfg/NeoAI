-- NeoAI 后端模块
-- 负责会话管理、消息 CRUD、数据持久化（导入/导出）以及 AI 回复模拟
local M = {}
local config = require("NeoAI.config")

-- 模块状态变量
M.config_dir = nil          -- 配置目录路径
M.config_file = nil         -- 会话数据文件路径
M.sessions = {}             -- 所有会话列表
M.current_session = nil     -- 当前活跃会话 ID
M.message_handlers = {}     -- 消息事件处理器映射表
M.editable_states = {}      -- 消息可编辑状态缓存

--- 创建一条新消息
-- @param role 角色类型 (user/assistant/system)
-- @param content 消息内容
-- @param timestamp 时间戳（可选，默认为当前时间）
-- @param metadata 附加元数据（可选）
-- @return table 消息对象
function M.create_message(role, content, timestamp, metadata)
  return {
    id = os.time() .. math.random(1000, 9999),  -- 唯一 ID
    role = role,
    content = content,
    timestamp = timestamp or os.time(),
    metadata = metadata or {},
    editable = false,   -- 是否可编辑
    pending = false,    -- 是否正在等待 AI 回复
  }
end

--- 自动同步指定会话数据到文件
-- @param session_id 会话 ID
function M._auto_sync(session_id)
  M.export_session(session_id, M.config_file, true)
end

--- 触发指定类型的事件，通知所有注册的处理器
-- @param event 事件名称
-- @param data 事件数据
function M._trigger(event, data)
  local handlers = M.message_handlers[event] or {}
  for _, handler in ipairs(handlers) do
    handler(data)
  end
end

--- 创建一个新的会话
-- @param name 会话名称（可选）
-- @return table 新创建的会话对象
function M.new_session(name)
  local session_id = #M.sessions + 1
  local session = {
    id = session_id,
    name = name or ("会话" .. session_id),
    messages = {},        -- 消息列表
    created_at = os.time(),
    updated_at = os.time(),
    config = {
      auto_scroll = config.defaults.ui.auto_scroll,
      show_timestamps = config.defaults.ui.show_timestamps,
      max_history = config.defaults.background.max_history,
    },
  }

  M.sessions[session_id] = session
  M.current_session = session_id
  M._auto_sync(session_id)            -- 自动持久化到文件
  M._trigger("session_created", session)

  return session
end

--- 向指定会话添加一条消息
-- @param session_id 会话 ID
-- @param message 消息对象
-- @return table|nil 添加的消息对象，或失败时返回 nil
function M.add_message(session_id, message)
  local session = M.sessions[session_id]
  if not session then
    return nil
  end

  table.insert(session.messages, message)
  session.updated_at = os.time()

  -- 如果消息数超出最大历史限制，删除最早的消息
  if session.config.max_history > 0 and #session.messages > session.config.max_history then
    table.remove(session.messages, 1)
  end

  M._auto_sync(session_id)
  M._trigger("message_added", { session_id = session_id, message = message })

  return message
end

--- 编辑指定会话中的某条消息
-- @param session_id 会话 ID
-- @param message_id 消息 ID
-- @param new_content 新的消息内容
-- @return boolean 是否编辑成功
function M.edit_message(session_id, message_id, new_content)
  local session = M.sessions[session_id]
  if not session then
    return false
  end

  for i, msg in ipairs(session.messages) do
    if tostring(msg.id) == tostring(message_id) then
      local old_content = msg.content
      msg.content = new_content
      msg.timestamp = os.time()
      session.updated_at = os.time()
      M._auto_sync(session_id)
      M._trigger("message_edited", {
        session_id = session_id,
        message_id = message_id,
        message = msg,
        old_content = old_content,
      })
      return true
    end
  end

  return false
end

--- 从缓冲区读取并保存编辑的消息（UI 层调用此接口）
-- 根据行号从缓冲区读取完整消息内容（支持多行/换行），然后调用 edit_message 保存
-- @param session_id 会话 ID
-- @param message_id 消息 ID
-- @param buf 缓冲区句柄
-- @param start_line 消息内容起始行（0-indexed）
-- @param end_line 消息内容结束行（0-indexed，不包含）
-- @return boolean, string? 是否成功, 失败原因（可选）
function M.save_buffer_edit(session_id, message_id, buf, start_line, end_line)
  -- 参数校验
  local session = M.sessions[session_id]
  if not session then
    return false, "会话不存在"
  end

  local target_msg = nil
  for _, msg in ipairs(session.messages) do
    if tostring(msg.id) == tostring(message_id) then
      target_msg = msg
      break
    end
  end

  if not target_msg then
    return false, "消息不存在"
  end

  -- 从缓冲区读取编辑后的内容
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
  if not lines or #lines == 0 then
    return false, "缓冲区内容为空"
  end

  local content = table.concat(lines, "\n")
  content = vim.trim(content)

  if content == "" then
    return false, "内容为空，未保存"
  end

  if content == target_msg.content then
    return false, "内容未修改"
  end

  -- 调用 edit_message 保存
  local success = M.edit_message(session_id, message_id, content)
  if success then
    local preview = string.sub(content, 1, 50)
    if #content > 50 then
      preview = preview .. "..."
    end
    return true, preview
  end

  return false, "保存失败"
end

--- 查找缓冲区中某行所属的消息对象
-- 根据当前缓冲区的内容行，重新计算行号到消息的映射，返回指定行对应的消息信息
-- @param session 会话对象
-- @param buf 缓冲区句柄
-- @param target_line 目标行号（0-indexed）
-- @return table? 消息信息 {session_id, message_id, start_line, end_line}，找不到返回 nil
function M.find_message_at_line(session, buf, target_line)
  if not session or not session.messages then
    return nil
  end

  local current_line = 0
  for i, msg in ipairs(session.messages) do
    -- 标题行（不可编辑）
    current_line = current_line + 1

    -- 计算内容行（wrap_message_content 模拟 UI 的换行逻辑）
    local wrap_width = 60 - 4
    local content_text = msg.content or ""
    local content_line_count = 0
    for line in content_text:gmatch("[^\r\n]+") do
      -- 每一行按 wrap_width 换行
      local remaining = line
      while #remaining > 0 do
        content_line_count = content_line_count + 1
        if #remaining <= wrap_width then
          break
        end
        remaining = remaining:sub(wrap_width + 1)
      end
    end
    if content_text == "" then
      content_line_count = 1
    end

    local msg_start = current_line
    local msg_end = current_line + content_line_count

    -- 检查目标行是否在当前消息的内容范围内
    if target_line >= msg_start and target_line < msg_end then
      return {
        session_id = session.id,
        message_id = msg.id,
        start_line = msg_start,
        end_line = msg_end,
      }
    end

    current_line = msg_end

    -- 消息间的空行
    if i < #session.messages then
      current_line = current_line + 1
    end
  end

  return nil
end

--- 删除指定会话中的某条消息
-- @param session_id 会话 ID
-- @param message_id 消息 ID
-- @return boolean 是否删除成功
function M.delete_message(session_id, message_id)
  local session = M.sessions[session_id]
  if not session then
    return false
  end

  for i, msg in ipairs(session.messages) do
    if msg.id == message_id then
      table.remove(session.messages, i)
      session.updated_at = os.time()
      M._auto_sync(session_id)
      M._trigger("message_deleted", { session_id = session_id, message_id = message_id })
      return true
    end
  end

  return false
end

--- 设置消息的可编辑状态
-- @param session_id 会话 ID
-- @param message_id 消息 ID
-- @param editable 是否可编辑
-- @return boolean 是否设置成功
function M.set_editable(session_id, message_id, editable)
  local session = M.sessions[session_id]
  if not session then
    return false
  end

  for _, msg in ipairs(session.messages) do
    if msg.id == message_id then
      msg.editable = editable
      M.editable_states[message_id] = editable
      M._trigger("editability_changed", { session_id = session_id, message_id = message_id, editable = editable })
      return true
    end
  end

  return false
end

--- 切换消息的可编辑状态
-- @param session_id 会话 ID
-- @param message_id 消息 ID
-- @return boolean|nil 新的可编辑状态，或失败时返回 nil
function M.toggle_editability(session_id, message_id)
  local session = M.sessions[session_id]
  if not session then
    return false
  end

  for _, msg in ipairs(session.messages) do
    if msg.id == message_id then
      local new_state = not msg.editable
      msg.editable = new_state
      M.editable_states[message_id] = new_state
      M._trigger("editability_changed", { session_id = session_id, message_id = message_id, editable = new_state })
      return new_state
    end
  end

  return false
end

--- 模拟 AI 回复（用于演示/测试）
-- 会先显示"思考中..."的占位消息，延迟后替换为真实回复
-- @param session_id 会话 ID
-- @param user_message 用户消息内容
-- @param callback 回复完成后的回调函数（可选）
function M.simulate_ai_reply(session_id, user_message, callback)
  local session = M.sessions[session_id]
  if not session then
    return
  end

  -- 创建 pending 状态的占位消息
  local pending_msg = M.create_message("assistant", "思考中...", os.time(), { pending = true })
  pending_msg.pending = true
  M.add_message(session_id, pending_msg)

  -- 延迟模拟 AI 回复
  vim.defer_fn(function()
    -- 预定义的回复模板
    local responses = {
      "这是一个模拟回复。在实际应用中，这里会连接到AI API。",
      "我理解你的问题。可以告诉我更多细节吗？",
      "根据我的分析，建议你尝试以下步骤...",
      "这是一个很好的问题！让我详细解释一下。",
      "我可能需要更多信息来给出准确的回答。",
    }

    local response = responses[math.random(#responses)]

    -- 更新占位消息为真实回复
    for i, msg in ipairs(session.messages) do
      if msg.id == pending_msg.id then
        msg.content = response
        msg.pending = false
        msg.timestamp = os.time()
        break
      end
    end

    session.updated_at = os.time()
    M._auto_sync(session_id)

    if callback then
      callback(response)
    end

    M._trigger("ai_replied", { session_id = session_id, message = pending_msg })
  end, 1000 + math.random(500, 1500))  -- 1~2.5 秒随机延迟
end

--- 发送消息（用户消息 + 触发 AI 回复）
-- @param session_id 会话 ID 或消息内容（若为内容则使用当前会话）
-- @param content 消息内容
-- @return table|nil 发送的用户消息对象，或失败时返回 nil
function M.send_message(session_id, content)
  -- 兼容参数顺序：若 content 为空，则第一个参数就是内容
  if content == nil then
    content = session_id
    session_id = M.current_session
  end

  local session = M.sessions[session_id]
  if not session or not content or content == "" then
    return nil
  end

  -- 创建并添加用户消息
  local user_msg = M.create_message("user", content)
  M.add_message(session_id, user_msg)

  -- 触发 AI 模拟回复
  M.simulate_ai_reply(session_id, content, function(response)
    M._trigger("response_received", { session_id = session_id, response = response })
  end)

  return user_msg
end

--- 注册事件监听器
-- @param event 事件名称
-- @param handler 回调函数
function M.on(event, handler)
  M.message_handlers[event] = M.message_handlers[event] or {}
  table.insert(M.message_handlers[event], handler)
end

--- 同步指定（或全部）会话数据到文件
-- @param session_id 会话 ID（可选，为空时同步所有会话）
-- @return boolean 是否成功
function M.sync_data(session_id)
  if session_id then
    local session = M.sessions[session_id]
    if session then
      M.export_session(session_id, M.config_file, true)
      return true
    end
  else
    -- 同步所有会话
    for id, _ in pairs(M.sessions) do
      M.export_session(id, M.config_file, true)
    end
    return true
  end
  return false
end

--- 防抖同步：延迟指定时间后执行 sync_data，期间重复调用会重置计时器
-- @param session_id 会话 ID
-- @param delay_ms 延迟时间（毫秒），默认 500
local debounce_sync_timer = nil
function M.debounce_sync(session_id, delay_ms)
  delay_ms = delay_ms or 500

  -- 停止旧的计时器
  if debounce_sync_timer then
    debounce_sync_timer:stop()
    if not debounce_sync_timer:is_closing() then
      debounce_sync_timer:close()
    end
  end

  -- 创建新的计时器
  debounce_sync_timer = vim.loop.new_timer()
  if debounce_sync_timer then
    debounce_sync_timer:start(delay_ms, 0, function()
      vim.schedule(function()
        M.sync_data(session_id)
      end)
    end)
  end
end

--- 导出指定会话到 JSON 文件
-- @param session_id 会话 ID
-- @param filepath 导出文件路径（可选，默认使用 config_file）
-- @param internal 是否为内部调用（为 true 时不触发事件）
-- @return boolean 是否导出成功
function M.export_session(session_id, filepath, internal)
  local session = M.sessions[session_id]
  if not session then
    return false
  end

  -- 构建导出数据结构
  local export_data = {
    id = session.id,
    name = session.name,
    messages = {},
    created_at = session.created_at,
    updated_at = session.updated_at,
    config = session.config,
    export_time = os.time(),
  }

  -- 序列化消息
  for _, msg in ipairs(session.messages) do
    table.insert(export_data.messages, {
      id = msg.id,
      role = msg.role,
      content = msg.content,
      timestamp = msg.timestamp,
      metadata = msg.metadata,
      editable = M.editable_states[msg.id] or false,
    })
  end

  filepath = filepath or M.config_file
  vim.fn.mkdir(M.config_dir, "p")  -- 确保目录存在

  -- 读取已有的数据（合并模式）
  local all_data = {}
  if vim.fn.filereadable(filepath) == 1 then
    local content = vim.fn.readfile(filepath)
    if #content > 0 then
      all_data = vim.fn.json_decode(table.concat(content, "\n")) or {}
    end
  end

  -- 更新指定会话的数据
  all_data[session.id] = export_data
  vim.fn.writefile({ vim.fn.json_encode(all_data) }, filepath)

  if not internal then
    M._trigger("session_exported", { session_id = session_id, filepath = filepath })
  end

  return true
end

--- 导出所有会话到 JSON 文件
-- @param filepath 导出文件路径（可选）
-- @return number 导出的会话数量
function M.export_all(filepath)
  filepath = filepath or M.config_file
  vim.fn.mkdir(M.config_dir, "p")

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

  vim.fn.writefile({ vim.fn.json_encode(all_data) }, filepath)
  return #M.sessions
end

--- 从 JSON 文件导入会话数据
-- @param filepath 导入文件路径（可选）
-- @return table 导入的会话 ID 列表
function M.import_sessions(filepath)
  filepath = filepath or M.config_file

  if vim.fn.filereadable(filepath) ~= 1 then
    return {}
  end

  local content = vim.fn.readfile(filepath)
  if #content == 0 then
    return {}
  end

  local data = vim.fn.json_decode(table.concat(content, "\n")) or {}
  local imported = {}

  for _, session_data in pairs(data) do
    local session = {
      id = session_data.id,
      name = session_data.name,
      messages = {},
      created_at = session_data.created_at or os.time(),
      updated_at = session_data.updated_at or os.time(),
      config = session_data.config or {},
    }

    -- 重建消息对象
    for _, msg_data in ipairs(session_data.messages or {}) do
      local msg = M.create_message(msg_data.role, msg_data.content, msg_data.timestamp, msg_data.metadata)
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

  M._trigger("sessions_imported", { count = #imported })
  return imported
end

--- 获取指定会话的统计信息
-- @param session_id 会话 ID
-- @return table 统计数据表
function M.get_session_stats(session_id)
  local session = M.sessions[session_id]
  if not session then
    return {}
  end

  local stats = {
    total_messages = #session.messages,
    user_messages = 0,
    ai_messages = 0,
    system_messages = 0,
    editable_messages = 0,
    duration_minutes = math.floor((os.time() - session.created_at) / 60),
  }

  -- 按角色分类统计
  for _, msg in ipairs(session.messages) do
    if msg.role == "user" then
      stats.user_messages = stats.user_messages + 1
    elseif msg.role == "assistant" then
      stats.ai_messages = stats.ai_messages + 1
    elseif msg.role == "system" then
      stats.system_messages = stats.system_messages + 1
    end
    if msg.editable then
      stats.editable_messages = stats.editable_messages + 1
    end
  end

  return stats
end

--- 后端模块初始化
-- 读取配置、导入已有数据、创建默认会话
-- @param user_config 用户配置（可选）
function M.setup(user_config)
  user_config = user_config or {}
  M.config_dir = user_config.config_dir or config.defaults.background.config_dir
  M.config_file = user_config.config_file or (M.config_dir .. "/sessions.json")

  -- 尝试导入已有的会话数据
  M.import_sessions()

  -- 如果没有任何会话，创建默认会话
  local has_sessions = false
  for _, _ in pairs(M.sessions) do
    has_sessions = true
    break
  end

  if not has_sessions then
    M.new_session("默认会话")
  end

  -- 设置当前活跃会话
  if not M.current_session then
    for id, _ in pairs(M.sessions) do
      M.current_session = id
      break
    end
  end

  vim.notify("[NeoAI] 后端已初始化，当前会话: " .. (M.sessions[M.current_session] and M.sessions[M.current_session].name or "无"))
end

return M
