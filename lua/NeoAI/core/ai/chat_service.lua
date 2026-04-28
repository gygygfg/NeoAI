--- NeoAI 聊天服务（后端）
--- 前后端分离架构中的后端服务层
--- 职责：会话管理、消息历史管理、AI 生成请求调度、事件分发

local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local ai_engine = require("NeoAI.core.ai.ai_engine")
local history_manager = require("NeoAI.core.history_manager")

-- ========== 状态 ==========

local state = {
  initialized = false,
  config = nil,
  pending_user_messages = {},
}

-- ========== 守卫 ==========

local function guard()
  if not state.initialized then
    logger.error("[chat_service] 服务未初始化")
    return false
  end
  return true
end

-- ========== 初始化 ==========

function M.initialize(options)
  if state.initialized then return M end
  state.config = options.config or {}
  M._setup_event_listeners()
  state.initialized = true
  logger.info("[chat_service] 聊天服务初始化完成")
  return M
end

-- ========== 事件监听 ==========

function M._setup_event_listeners()
  vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.GENERATION_COMPLETED,
    callback = function(args)
      local data = args.data or {}
      logger.debug("[chat_service] 生成完成: session=" .. tostring(data.session_id))
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.GENERATION_ERROR,
    callback = function(args)
      local data = args.data or {}
      logger.warn("[chat_service] 生成错误: session=" .. tostring(data.session_id) .. ", error=" .. tostring(data.error_msg))
    end,
  })
  -- 监听取消生成事件，确保停止传播到所有子模块
  vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.CANCEL_GENERATION,
    callback = function(args)
      local data = args.data or {}
      local session_id = data.session_id
      logger.debug("[chat_service] 收到取消生成事件: session=" .. tostring(session_id))
      -- 确保 AI 引擎和工具编排器都收到停止信号
      ai_engine.cancel_generation()
      -- 通知工具编排器停止所有工具调用
      local ok, tool_orc = pcall(require, "NeoAI.core.ai.tool_orchestrator")
      if ok and tool_orc then
        tool_orc.request_stop(session_id)
      end
    end,
  })
end

-- ========== 会话管理 ==========

function M.create_session(name, is_root, parent_id)
  if not guard() then return nil end
  return history_manager.create_session(name, is_root, parent_id)
end

function M.get_or_create_current_session(name)
  if not guard() then return nil end
  return history_manager.get_or_create_current_session(name)
end

function M.get_session(session_id)
  if not guard() then return nil end
  return history_manager.get_session(session_id)
end

function M.get_current_session()
  if not guard() then return nil end
  return history_manager.get_current_session()
end

function M.set_current_session(session_id)
  if not guard() then return false end
  return history_manager.set_current_session(session_id)
end

function M.delete_session(session_id)
  if not guard() then return false end
  return history_manager.delete_session(session_id)
end

function M.rename_session(session_id, new_name)
  if not guard() then return false end
  return history_manager.rename_session(session_id, new_name)
end

function M.list_sessions()
  if not guard() then return {} end
  return history_manager.list_sessions()
end

function M.get_tree()
  if not guard() then return {} end
  return history_manager.get_tree()
end

-- ========== 消息管理 ==========

function M.get_context(session_id)
  if not guard() then return {}, nil end
  return history_manager.get_context_and_new_parent(session_id)
end

function M.get_raw_messages(session_id)
  if not guard() then return {} end

  local hm = history_manager
  local session = hm.get_session(session_id)
  if not session then return {} end

  -- 从当前会话向上回溯到根，收集路径上的所有会话ID
  local path_ids = {}
  local current = session
  for _ = 1, 100 do
    table.insert(path_ids, 1, current.id)
    local parent_id = hm.find_parent_session(current.id)
    if not parent_id then break end
    current = hm.get_session(parent_id)
    if not current then break end
  end

  -- 按从根到当前的顺序收集消息
  local messages = {}
  local tool_call_buffer = {}

  local function flush_tool_calls()
    if #tool_call_buffer == 0 then return end
    local text = "{{{ 🔧 工具调用"
    for _, tc in ipairs(tool_call_buffer) do
      local args_str = vim.inspect(tc.arguments or {})
      if #args_str > 100 then args_str = args_str:sub(1, 100) .. "..." end
      local result_str = type(tc.result) == "table"
        and (pcall(vim.json.encode, tc.result) and vim.json.encode(tc.result) or vim.inspect(tc.result))
        or tostring(tc.result or "")
      if #result_str > 200 then
        result_str = result_str:sub(1, 200) .. "\n    ... [truncated, total " .. #result_str .. " chars]"
      end
      result_str = result_str:gsub("\n", "\n    ")
      text = text .. "\n  🔧 " .. (tc.tool_name or "unknown")
        .. "\n    参数: " .. args_str
        .. "\n    结果: " .. result_str
    end
    text = text .. "\n}}}"
    table.insert(messages, { role = "assistant", content = text })
    tool_call_buffer = {}
  end

  for _, pid in ipairs(path_ids) do
    local s = hm.get_session(pid)
    if not s then break end
    if s.user and s.user ~= "" then
      table.insert(messages, { role = "user", content = s.user })
    end
    local assistant_list = s.assistant
    if type(assistant_list) ~= "table" then
      assistant_list = (assistant_list and assistant_list ~= "") and { assistant_list } or {}
    end
    for _, entry in ipairs(assistant_list) do
      local ok, parsed = pcall(vim.json.decode, entry)
      if ok and type(parsed) == "table" and parsed.type == "tool_call" then
        table.insert(tool_call_buffer, parsed)
      else
        flush_tool_calls()
        table.insert(messages, { role = "assistant", content = entry })
      end
    end
    flush_tool_calls()
  end

  return messages
end

function M.add_round(session_id, user_msg, assistant_msg, usage)
  if not guard() then return nil end
  return history_manager.add_round(session_id, user_msg, assistant_msg, usage)
end

function M.update_last_assistant(session_id, content)
  if not guard() then return end
  history_manager.update_last_assistant(session_id, content)
end

function M.add_tool_result(session_id, tool_name, arguments, result)
  if not guard() then return false end
  return history_manager.add_tool_result(session_id, tool_name, arguments, result)
end

function M.update_usage(session_id, usage)
  if not guard() then return end
  history_manager.update_usage(session_id, usage)
end

function M.find_parent_session(session_id)
  if not guard() then return nil end
  return history_manager.find_parent_session(session_id)
end

function M.find_nearest_branch_parent(session_id)
  if not guard() then return nil end
  return history_manager.find_nearest_branch_parent(session_id)
end

function M.delete_chain_to_branch(session_id)
  if not guard() then return false end
  return history_manager.delete_chain_to_branch(session_id)
end

-- ========== AI 生成 ==========

function M.send_message(params)
  if not guard() then return false, "聊天服务未初始化" end

  local content = params.content
  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}

  if not content or vim.trim(content) == "" then
    return false, "消息内容不能为空"
  end

  -- 获取或创建会话
  local hm = history_manager
  local session = hm.get_or_create_current_session("聊天会话")
  if not session then return false, "无法创建会话" end

  local target_session_id = session.id

  -- 如果当前会话已有内容，创建新分支会话
  if session.user ~= nil and session.user ~= "" then
    local _, new_parent_id = hm.get_context_and_new_parent(session.id)
    local new_id = hm.create_session("分支-" .. (session.name or "会话"), false, new_parent_id)
    hm.set_current_session(new_id)
    target_session_id = new_id
  end

  -- 保存用户消息到待写入队列
  state.pending_user_messages[target_session_id] = content

  -- 获取上下文消息
  local context_msgs, _ = hm.get_context_and_new_parent(target_session_id)
  local messages = {}
  for _, msg in ipairs(context_msgs) do
    table.insert(messages, { role = msg.role, content = msg.content })
  end

  -- 去重：检查最后一条消息是否与当前消息相同
  local last_msg = messages[#messages]
  if not (last_msg and last_msg.role == "user" and last_msg.content == content) then
    table.insert(messages, { role = "user", content = content })
  end

  if #messages == 0 then return false, "上下文消息为空" end

  -- 检查工具是否启用
  local tools_enabled = true
  local core_ok, core_mod = pcall(require, "NeoAI.core")
  if core_ok then
    local full_config = core_mod.get_config()
    if full_config and full_config.tools then
      tools_enabled = full_config.tools.enabled ~= false
    end
  end

  -- 调用 AI 引擎生成响应
  ai_engine.generate_response(messages, {
    session_id = target_session_id,
    window_id = window_id,
    model_index = options.model_index or 1,
    stream = options.stream ~= false,
    options = { tools_enabled = tools_enabled },
  })

  -- 触发消息发送事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.MESSAGE_SENT,
    data = {
      session_id = target_session_id, window_id = window_id,
      role = "user", message = content,
    },
  })

  return true, "消息已发送"
end

function M.cancel_generation()
  if not guard() then return end
  -- 从 history_manager 获取当前 session_id
  local current_session = history_manager.get_current_session()
  local session_id = current_session and current_session.id or nil
  -- 先触发取消事件，让所有监听器（包括 chat_service 自身的）都能响应
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.CANCEL_GENERATION,
    data = { session_id = session_id },
  })
  -- 再直接调用 ai_engine 取消
  ai_engine.cancel_generation()
  -- 通知工具编排器停止所有工具调用
  local ok, tool_orc = pcall(require, "NeoAI.core.ai.tool_orchestrator")
  if ok and tool_orc then
    tool_orc.request_stop(session_id)
  end
end

function M.get_engine_status()
  if not guard() then return { initialized = false } end
  return ai_engine.get_status()
end

function M.switch_model(model_index)
  if not guard() then return end
  logger.info("[chat_service] 模型切换: index=" .. tostring(model_index))
end

-- ========== 历史持久化 ==========

function M.save()
  if not guard() then return end
  history_manager._save()
end

-- ========== 清理 ==========

function M.shutdown()
  if not guard() then return end
  state.initialized = false
  state.pending_user_messages = {}
  logger.info("[chat_service] 聊天服务已关闭")
end

return M
