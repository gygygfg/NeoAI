--- 聊天界面处理器（前端）
--- 前后端分离架构中的前端处理器
--- 通过 chat_service（后端）与 AI 引擎交互
--- 职责：
---   1. 接收用户输入，调用后端 chat_service.send_message()
---   2. 监听后端事件，更新前端状态
---   3. 每轮对话实时保存到历史文件（用户消息发送时立即保存，AI 回复流式更新时实时保存）

local M = {}

local Events = require("NeoAI.core.events")

local state = {
  initialized = false,
  config = nil,
}

--- 获取后端聊天服务
local function get_chat_service()
  local ok, chat_service = pcall(require, "NeoAI.core.ai.chat_service")
  if ok and chat_service then
    return chat_service
  end
  return nil
end

--- 获取历史管理器
local function get_hm()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if ok and hm.is_initialized() then return hm end
  return nil
end

--- 构建 assistant 内容（合并 reasoning 和正文）
--- @param content_text string 正文内容
--- @param reasoning_text string|nil 思考过程
--- @return string
local function build_assistant_content(content_text, reasoning_text)
  if reasoning_text and reasoning_text ~= "" then
    return vim.json.encode({
      content = content_text or "",
      reasoning_content = reasoning_text,
    })
  end
  return content_text or ""
end

function M.initialize(config)
  if state.initialized then return true end
  state.config = config or {}
  state.initialized = true

  -- 监听生成完成事件，更新历史中的 AI 回复（最终完整内容）
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

  -- 监听取消生成事件：保存已生成的内容到历史文件
  -- 注意：chat_window 的 GENERATION_CANCELLED 回调先执行，会调用 reset_streaming_state() 清空流式缓冲区
  -- 所以这里改为从 chat_window.state.messages 中获取最后一条 assistant 消息的内容
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_CANCELLED,
    callback = function()
      local hm = get_hm()
      if not hm then return end

      -- 从 chat_window 的 state.messages 中获取最后一条 assistant 消息的内容
      -- chat_window 的 GENERATION_CANCELLED 回调已先执行，流式缓冲区已被清空
      -- 但 state.messages 中的内容还在（reset_streaming_state 不清除 messages）
      local chat_window_ok, chat_window = pcall(require, "NeoAI.ui.window.chat_window")
      local assistant_content = nil
      if chat_window_ok and chat_window.get_last_assistant_content then
        assistant_content = chat_window.get_last_assistant_content()
      end

      if assistant_content and assistant_content ~= "" then
        local session = hm.get_current_session()
        if session then
          hm.update_last_assistant(session.id, assistant_content)
          hm._save()
        end
      end
    end,
  })

  return true
end

--- 处理工具调用结果，写入历史
--- @param data table 事件数据
function M._handle_tool_result(data)
  local tool_results = data.tool_results or {}
  local session_id = data.session_id

  if not session_id or #tool_results == 0 then
    return
  end

  -- 工具结果持久化已由 tool_executor 统一处理
  -- 此处不再重复保存到 history_manager
  -- 此函数仅保留用于兼容旧的事件处理逻辑
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

  local hm = get_hm()
  if not hm then return end

  -- 由 chat_window.lua 的 _save_final_content_to_history 统一保存
  -- 该函数在 GENERATION_COMPLETED 回调中后执行，使用原始 data 构建含 reasoning 的 JSON
  -- 这里不再重复保存，避免竞态覆盖
end

--- 发送消息（前端入口）
--- 用户消息发送时立即写入历史文件，确保每轮对话实时保存
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

  -- 1. 获取或创建会话
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

  -- 2. 用户消息立即写入历史文件（不再使用待写入队列）
  -- 使用空字符串作为占位 assistant 内容，后续 AI 回复会通过 update_last_assistant 更新
  hm.add_round(target_session_id, content, {}, {})
  hm._save()

  -- 3. 通知 chat_window 添加用户消息
  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_available() then
    chat_window.add_message("user", content)
  end

  -- 4. 调用后端服务发送消息
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

return M
