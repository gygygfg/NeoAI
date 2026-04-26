--- 聊天界面处理器
--- 基于新的 history_manager

local M = {}

local Events = require("NeoAI.core.events.event_constants")

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
    pattern = Events.MESSAGE_SENT,
    callback = function(args)
      M._trigger_ai_response(args.data or {})
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_COMPLETED,
    callback = function(args)
      M._handle_response_complete(args.data or {})
    end,
  })

  -- 监听工具调用结果事件，将工具调用结果写入历史文件
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
      -- 遍历所有待写入队列，清理空会话
      for sid, _ in pairs(state.pending_user_messages) do
        local session = hm.get_session(sid)
        if session and (not session.user or session.user == "") and (not session.assistant or #session.assistant == 0) then
          hm.delete_session(sid)
        end
      end
      -- 清空待写入队列
      state.pending_user_messages = {}
    end,
  })

  -- STREAM_CHUNK 和 STREAM_COMPLETED 由 chat_window.lua 统一处理 UI 渲染
  -- chat_handlers 只负责业务逻辑（写入历史），通过 GENERATION_COMPLETED 事件处理

  return true
end

function M._trigger_ai_response(data)
  local window_id = data.window_id
  local role = data.role or "user"
  if role ~= "user" then
    return
  end

  vim.defer_fn(function()
    local hm = get_hm()
    if not hm then
      return
    end
    local session = hm.get_current_session()
    if not session then
      return
    end

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

    if #messages == 0 then
      return
    end

    local core_loaded, core = pcall(require, "NeoAI.core")
    if not core_loaded or not core then
      return
    end
    local ai_engine = core.get_ai_engine()
    if not ai_engine then
      return
    end

    -- 获取当前聊天窗口使用的模型索引
    local model_index = 1
    local chat_window_ok, chat_window = pcall(require, "NeoAI.ui.window.chat_window")
    if chat_window_ok and chat_window.get_current_model_index then
      model_index = chat_window.get_current_model_index() or 1
    end

    -- 检查工具是否启用（从完整配置中读取）
    local tools_enabled = true
    local core_ok, core_mod = pcall(require, "NeoAI.core")
    if core_ok then
      local full_config = core_mod.get_config()
      if full_config and full_config.tools then
        tools_enabled = full_config.tools.enabled ~= false
      end
    end

    ai_engine.generate_response(messages, {
      session_id = session.id,
      window_id = window_id,
      model_index = model_index,
      stream = state.config and state.config.stream ~= false,
      options = {
        tools_enabled = tools_enabled,
      },
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
  -- 注意：如果已有工具调用条目（通过 add_tool_result 保存），必须保留它们
  -- 不能直接用 { assistant_content } 覆盖，否则工具调用数据会丢失
  local existing_session = hm.get_session(session_id)
  local existing_assistant = {}
  if existing_session and type(existing_session.assistant) == "table" and #existing_session.assistant > 0 then
    -- 保留已有的 assistant 条目（如工具调用结果），追加新的 AI 回复
    existing_assistant = vim.deepcopy(existing_session.assistant)
    table.insert(existing_assistant, assistant_content)
  else
    existing_assistant = { assistant_content }
  end
  hm.add_round(session_id, user_msg, existing_assistant, usage)
  -- 清理待写入队列
  state.pending_user_messages[session_id] = nil
end

--- 处理工具调用结果，将工具调用信息写入历史文件
--- @param data table 事件数据
function M._handle_tool_result(data)
  local generation_id = data.generation_id
  local tool_results = data.tool_results or {}
  local session_id = data.session_id
  local window_id = data.window_id

  if not session_id or #tool_results == 0 then
    return
  end

  local hm = get_hm()
  if not hm then return end

  -- 获取当前会话（如果没有 session_id，使用当前会话）
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

  -- 将每个工具调用结果写入历史
  for _, tr in ipairs(tool_results) do
    local tool_call = tr.tool_call or {}
    local result = tr.result or ""

    -- 兼容两种字段名：function（OpenAI 标准）和 func（旧格式）
    local tool_func = tool_call["function"] or tool_call.func or {}
    local tool_name = tool_func.name or "unknown"
    local arguments_str = tool_func.arguments or "{}"

    -- 解析参数
    local arguments = {}
    local ok, parsed = pcall(vim.json.decode, arguments_str)
    if ok and parsed then
      arguments = parsed
    end

    -- 将结果截断到合理长度，避免历史文件过大
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

  -- 如果有思考内容，将 content 和 reasoning_content 打包为 JSON 字符串
  if reasoning_text and reasoning_text ~= "" then
    local assistant_json = vim.json.encode({
      content = response_content,
      reasoning_content = reasoning_text,
    })
    response_content = assistant_json
  end

  -- 将用户消息和AI回复一起写入历史文件
  _flush_pending_round(session_id, response_content, usage)
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
    -- new_parent_id 由 get_context_and_new_parent 确定：
    -- - 如果选中会话有唯一子会话链，new_parent_id 是链尾
    -- - 如果选中会话有多个子会话（分支点），new_parent_id 是分支点
    -- - 如果选中会话无子会话（链尾），new_parent_id 是选中会话本身
    local new_id = hm.create_session("分支-" .. current_session.name, false, new_parent_id)
    hm.set_current_session(new_id)
    target_session_id = new_id
  end

  -- 不立即写入历史文件，先保存用户消息到待写入队列
  -- 等AI响应完成后，再将用户消息和AI回复一起写入
  state.pending_user_messages[target_session_id] = content

  -- 用户发送消息时触发自动保存
  local hm_module = require("NeoAI.core.history_manager")
  if hm_module and hm_module._save then
    hm_module._save()
  end

  -- 自动命名已移至 add_round 中，通过 config.auto_naming 控制

  local chat_window = require("NeoAI.ui.window.chat_window")
  if chat_window.is_available() then
    chat_window.add_message("user", content)
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.MESSAGE_SENT,
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
