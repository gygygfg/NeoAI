--- 聊天界面处理器
--- 基于新的 history_manager

local M = {}

local state = {
  initialized = false,
  config = nil,
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
    if #context_msgs == 0 then return end

    local messages = {}
    for _, msg in ipairs(context_msgs) do
      table.insert(messages, { role = msg.role, content = msg.content })
    end

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

function M._handle_response_complete(data)
  local response = data.response
  local session_id = data.session_id

  local response_content = ""
  if type(response) == "string" then
    response_content = response
  elseif type(response) == "table" and response.content then
    response_content = response.content
  else
    response_content = tostring(response)
  end

  if response_content == "" then return end

  local hm = get_hm()
  if hm and session_id then
    local session = hm.get_session(session_id)
    if session and #session.rounds > 0 then
      local last_round = session.rounds[#session.rounds]
      if last_round.assistant == "" or last_round.assistant == nil then
        hm.update_last_assistant(session_id, response_content)
      else
        hm.add_round(session_id, "", response_content)
      end
    end
  end

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

  local hm = get_hm()
  if hm and session_id and full_response then
    local session = hm.get_session(session_id)
    if session and #session.rounds > 0 then
      local last_round = session.rounds[#session.rounds]
      if last_round.assistant == "" or last_round.assistant == nil then
        hm.update_last_assistant(session_id, full_response)
      end
    end
  end
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
  if current_session and #(current_session.child_ids or {}) > 0 then
    local new_id = hm.create_session("分支-" .. current_session.name, false, session.id)
    hm.set_current_session(new_id)
    target_session_id = new_id
  end

  hm.add_round(target_session_id, content, "")

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
  return #(session.rounds or {}) * 2
end

function M.update_config(new_config)
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
