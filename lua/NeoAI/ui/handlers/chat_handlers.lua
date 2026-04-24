--- 聊天界面处理器
--- 基于新的 history_manager

local M = {}

local state = {
  initialized = false,
  config = nil,
  -- 存储待写入的用户消息，key=session_id, value=user_message
  pending_user_messages = {},
}

local function get_hm()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if ok and hm.is_initialized() then return hm end
  return nil
end

function M.initialize(config)
  if state.initialized then return true end
  state.config = config or {}
  state.initialized = true

  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:message_sent",
    callback = function(args)
      M._trigger_ai_response(args.data or {})
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:ai_response_complete",
    callback = function(args)
      M._handle_response_complete(args.data or {})
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:stream_chunk",
    callback = function(args)
      M._handle_stream_chunk(args.data or {})
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "NeoAI:stream_completed",
    callback = function(args)
      M._handle_stream_complete(args.data or {})
    end,
  })

  return true
end

function M._trigger_ai_response(data)
  local window_id = data.window_id
  local role = data.role or "user"
  if role ~= "user" then return end

  vim.defer_fn(function()
    local hm = get_hm()
    if not hm then return end
    local session = hm.get_current_session()
    if not session then return end

    local context_msgs, _ = hm.get_context_and_new_parent(session.id)

    local messages = {}
    for _, msg in ipairs(context_msgs) do
      table.insert(messages, { role = msg.role, content = msg.content })
    end

    -- 将待写入的用户消息追加到上下文中（尚未写入历史文件）
    local pending_msg = state.pending_user_messages[session.id]
    if pending_msg then
      table.insert(messages, { role = "user", content = pending_msg })
    end

    if #messages == 0 then return end

    local core_loaded, core = pcall(require, "NeoAI.core")
    if not core_loaded or not core then return end
    local ai_engine = core.get_ai_engine()
    if not ai_engine then return end

    ai_engine.generate_response(messages, {
      session_id = session.id,
      window_id = window_id,
      stream = state.config and state.config.stream ~= false,
    })
  end, 500)
end

--- 将待写入的用户消息和AI回复一起写入历史文件
--- @param session_id string 会话ID
--- @param assistant_content string AI回复内容
--- @param usage table|nil token用量
local function _flush_pending_round(session_id, assistant_content, usage)
  local hm = get_hm()
  if not hm then return end

  local user_msg = state.pending_user_messages[session_id]
  if not user_msg then
    -- 没有待写入的用户消息，直接更新AI回复
    local session = hm.get_session(session_id)
    if session then
      hm.update_last_assistant(session_id, assistant_content)
      if usage and next(usage) then
        hm.update_usage(session_id, usage)
      end
    end
    return
  end

  -- 将用户消息和AI回复一起写入历史文件
  -- assistant 字段为数组，每个元素是一轮 AI 回复
  hm.add_round(session_id, user_msg, { assistant_content }, usage)
  -- 清理待写入队列
  state.pending_user_messages[session_id] = nil
end

function M._handle_response_complete(data)
  local response = data.response
  local session_id = data.session_id
  local usage = data.usage or {}

  local response_content = ""
  if type(response) == "string" then
    response_content = response
  elseif type(response) == "table" and response.content then
    response_content = response.content
  else
    response_content = tostring(response)
  end

  if response_content == "" then return end

  -- 将用户消息和AI回复一起写入历史文件
  _flush_pending_round(session_id, response_content, usage)

  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_available() then
    local messages = chat_window.get_messages()
    if messages and #messages > 0 then
      local last_ai_idx = nil
      for i = #messages, 1, -1 do
        if messages[i].role == "assistant" then
          last_ai_idx = i
          break
        end
      end
      if last_ai_idx then
        messages[last_ai_idx].content = response_content
        chat_window.set_messages(messages)
        chat_window.render_chat()
      else
        chat_window.add_message("assistant", response_content)
      end
    else
      chat_window.add_message("assistant", response_content)
    end
  end
end

function M._handle_stream_chunk(data)
  local chunk = data.chunk
  local window_id = data.window_id

  local chunk_content = ""
  if type(chunk) == "string" then
    chunk_content = chunk
  elseif type(chunk) == "table" and chunk.content then
    chunk_content = chunk.content
  elseif type(chunk) == "table" and chunk.delta then
    chunk_content = chunk.delta
  else
    chunk_content = tostring(chunk)
  end

  if chunk_content == "" then return end

  local chat_window = require("NeoAI.ui.window.chat_window")
  if not chat_window.is_available() then return end

  chat_window._append_stream_chunk_to_buffer(chunk_content)
end

function M._handle_stream_complete(data)
  local full_response = data.full_response
  local reasoning_text = data.reasoning_text
  local session_id = data.session_id
  local usage = data.usage or {}

  if not session_id or not full_response then return end

  -- 将 content 和 reasoning_content 打包为 JSON 字符串
  local assistant_json = vim.json.encode({
    content = full_response,
    reasoning_content = reasoning_text or "",
  })

  -- 将用户消息和AI回复一起写入历史文件
  -- assistant 字段为数组，传入包含一个元素的数组
  _flush_pending_round(session_id, assistant_json, usage)
end

function M.send_message(content, session_id, branch_id, window_id, format, callback)
  if not state.initialized then
    if callback then callback(false, "聊天处理器未初始化") end
    return false, "聊天处理器未初始化"
  end
  if not content or vim.trim(content) == "" then
    if callback then callback(false, "消息内容不能为空") end
    return false, "消息内容不能为空"
  end

  local hm = get_hm()
  if not hm then
    if callback then callback(false, "历史管理器未初始化") end
    return false, "历史管理器未初始化"
  end

  local session = hm.get_or_create_current_session("聊天会话")
  if not session then
    if callback then callback(false, "无法创建会话") end
    return false, "无法创建会话"
  end

  local context_msgs, new_parent_id = hm.get_context_and_new_parent(session.id)

  local target_session_id = session.id
  local current_session = hm.get_session(session.id)
  if current_session and current_session.user ~= nil and current_session.user ~= "" then
    -- 当前会话已有内容，创建新会话保存新的一轮
    -- 新会话应该和当前会话同级（挂在同一个父会话下），而不是作为当前会话的子会话
    -- 这样多个分支才能同级显示
    local parent_id = hm.find_parent_session(session.id)
    local new_id
    if parent_id then
      -- 新会话挂在父会话下（和当前会话同级）
      new_id = hm.create_session("分支-" .. current_session.name, false, parent_id)
    else
      -- 没有父会话（当前会话是根会话），挂在当前会话下
      new_id = hm.create_session("分支-" .. current_session.name, false, session.id)
    end
    hm.set_current_session(new_id)
    target_session_id = new_id
  end

  -- 不立即写入历史文件，先保存用户消息到待写入队列
  -- 等AI响应完成后，再将用户消息和AI回复一起写入
  state.pending_user_messages[target_session_id] = content

  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_available() then
    chat_window.add_message("user", content)
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:message_sent",
    data = {
      session_id = target_session_id,
      window_id = window_id,
      role = "user",
      message = content,
    },
  })

  if callback then callback(true, "消息已发送") end
  return true, "消息已发送"
end

function M.send_message_sync(content, session_id, branch_id, window_id, format)
  return M.send_message(content, session_id, branch_id, window_id, format)
end

function M.get_message_count()
  local hm = get_hm()
  if not hm then return 0 end
  local session = hm.get_current_session()
  if not session then return 0 end
  local count = 0
  if session.user and session.user ~= "" then count = count + 1 end
  if session.assistant and session.assistant ~= "" then count = count + 1 end
  return count
end

function M.update_config(new_config)
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
