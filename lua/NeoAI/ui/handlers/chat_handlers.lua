--- 聊天界面处理器（前端）
--- 前后端分离架构中的前端处理器
--- 通过 chat_service（后端）与 AI 引擎交互
--- 职责：
---   1. 接收用户输入，调用后端 chat_service.send_message()
---   2. 监听后端事件，更新前端状态
---   3. 管理待写入队列（等 AI 响应完成后一并写入历史）

local M = {}

local Events = require("NeoAI.core.events")

local state = {
  initialized = false,
  config = nil,
  -- 存储待写入的用户消息，key=session_id, value=user_message
  pending_user_messages = {},
}

--- 获取后端聊天服务
local function get_chat_service()
  local ok, chat_service = pcall(require, "NeoAI.core.ai.chat_service")
  if ok and chat_service then
    return chat_service
  end
  return nil
end

--- 获取历史管理器（仅用于读取操作）
local function get_hm()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if ok and hm.is_initialized() then return hm end
  return nil
end

function M.initialize(config)
  if state.initialized then return true end
  state.config = config or {}
  state.initialized = true

  -- 监听生成完成事件，写入历史
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_COMPLETED,
    callback = function(args)
      M._handle_response_complete(args.data or {})
    end,
  })

  -- 监听工具调用结果事件，写入历史
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_RESULT_RECEIVED,
    callback = function(args)
      M._handle_tool_result(args.data or {})
    end,
  })

  -- 监听取消生成事件，清理待写入队列和空会话
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_CANCELLED,
    callback = function()
      local hm = get_hm()
      if not hm then return end
      for sid, _ in pairs(state.pending_user_messages) do
        local session = hm.get_session(sid)
        if session and (not session.user or session.user == "") and (not session.assistant or #session.assistant == 0) then
          hm.delete_session(sid)
        end
      end
      state.pending_user_messages = {}
    end,
  })

  return true
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
    local session = hm.get_session(session_id)
    if session then
      hm.update_last_assistant(session_id, assistant_content)
      if usage and next(usage) then
        hm.update_usage(session_id, usage)
      end
    end
    return
  end

  local existing_session = hm.get_session(session_id)
  local existing_assistant = {}
  if existing_session and type(existing_session.assistant) == "table" and #existing_session.assistant > 0 then
    existing_assistant = vim.deepcopy(existing_session.assistant)
    table.insert(existing_assistant, assistant_content)
  else
    existing_assistant = { assistant_content }
  end
  hm.add_round(session_id, user_msg, existing_assistant, usage)
  state.pending_user_messages[session_id] = nil
end

--- 处理工具调用结果，写入历史
--- @param data table 事件数据
function M._handle_tool_result(data)
  local tool_results = data.tool_results or {}
  local session_id = data.session_id

  if not session_id or #tool_results == 0 then
    return
  end

  local hm = get_hm()
  if not hm then return end

  local target_session_id = session_id
  local session = hm.get_session(target_session_id)
  if not session then
    local current = hm.get_current_session()
    if current then
      target_session_id = current.id
    else
      return
    end
  end

  for _, tr in ipairs(tool_results) do
    local tool_call = tr.tool_call or {}
    local result = tr.result or ""

    local tool_func = tool_call["function"] or tool_call.func or {}
    local tool_name = tool_func.name or "unknown"
    local arguments_str = tool_func.arguments or "{}"

    local arguments = {}
    local ok, parsed = pcall(vim.json.decode, arguments_str)
    if ok and parsed then
      arguments = parsed
    end

    local result_str = tostring(result or "")
    if #result_str > 500 then
      result_str = result_str:sub(1, 500) .. "\n... [truncated, total " .. #result_str .. " chars]"
    end

    hm.add_tool_result(target_session_id, tool_name, arguments, result_str)
  end
end

function M._handle_response_complete(data)
  local response = data.response
  local session_id = data.session_id
  local usage = data.usage or {}
  local reasoning_text = data.reasoning_text or ""

  local response_content = ""
  if type(response) == "string" then
    response_content = response
  elseif type(response) == "table" and response.content then
    response_content = response.content
  else
    response_content = tostring(response)
  end

  if response_content == "" then return end

  -- 优先使用 chat_window 中构建的 final_content（包含折叠文本如 {{{ }}}）
  -- chat_window 的 GENERATION_COMPLETED 回调先执行，已将折叠文本保存到 state.messages
  -- 这里读取它以确保历史中保存的是包含折叠文本的完整内容
  local chat_window_ok, chat_window = pcall(require, "NeoAI.ui.window.chat_window")
  local final_content = nil
  if chat_window_ok and chat_window.get_last_assistant_content then
    final_content = chat_window.get_last_assistant_content()
  end

  if final_content and final_content ~= "" then
    -- 使用 chat_window 构建的包含折叠文本的内容
    _flush_pending_round(session_id, final_content, usage)
  elseif reasoning_text and reasoning_text ~= "" then
    local assistant_json = vim.json.encode({
      content = response_content,
      reasoning_content = reasoning_text,
    })
    _flush_pending_round(session_id, assistant_json, usage)
  else
    _flush_pending_round(session_id, response_content, usage)
  end
end

--- 发送消息（前端入口）
--- 通过后端 chat_service 发送消息
--- @param content string 消息内容
--- @param session_id string|nil 会话ID
--- @param branch_id string|nil 分支ID（兼容旧版本）
--- @param window_id string|nil 窗口ID
--- @param format boolean|nil 格式（兼容旧版本）
--- @param callback function|nil 回调函数
--- @return boolean, string|nil
function M.send_message(content, session_id, branch_id, window_id, format, callback)
  if not state.initialized then
    if callback then callback(false, "聊天处理器未初始化") end
    return false, "聊天处理器未初始化"
  end
  if not content or vim.trim(content) == "" then
    if callback then callback(false, "消息内容不能为空") end
    return false, "消息内容不能为空"
  end

  local chat_service = get_chat_service()
  if not chat_service then
    if callback then callback(false, "后端聊天服务不可用") end
    return false, "后端聊天服务不可用"
  end

  -- 1. 获取或创建会话（前端管理待写入队列）
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
    local new_id = hm.create_session("分支-" .. current_session.name, false, new_parent_id)
    hm.set_current_session(new_id)
    target_session_id = new_id
  end

  -- 2. 保存用户消息到待写入队列
  state.pending_user_messages[target_session_id] = content

  -- 3. 触发自动保存
  local hm_module = require("NeoAI.core.history_manager")
  if hm_module and hm_module._save then
    hm_module._save()
  end

  -- 4. 通知 chat_window 添加用户消息
  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_available() then
    chat_window.add_message("user", content)
  end

  -- 5. 调用后端服务发送消息
  local success, result = chat_service.send_message({
    content = content,
    session_id = target_session_id,
    window_id = window_id,
    options = {
      model_index = chat_window.get_current_model_index and chat_window.get_current_model_index() or 1,
    },
  })

  if callback then
    callback(success, result)
  end

  return success, result
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
