-- pipeline_agent.lua
-- 单个 AI agent 的循环执行器
-- 管理一个 AI 的工具调用循环，直到 AI 返回纯文本回复
-- 替代旧 tool_cycle 的单循环功能，但更简洁

local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local shutdown_flag = require("NeoAI.core.shutdown_flag")
local state_manager = require("NeoAI.core.config.state")

-- 延迟加载的模块
local _http_utils = nil
local _tool_executor = nil
local _tool_registry = nil
local _request_handler = nil

local function _get_http_utils()
  if not _http_utils then
    _http_utils = require("NeoAI.utils.http_utils")
  end
  return _http_utils
end

local function _get_tool_executor()
  if not _tool_executor then
    _tool_executor = require("NeoAI.tools.tool_executor")
  end
  return _tool_executor
end

local function _get_tool_registry()
  if not _tool_registry then
    _tool_registry = require("NeoAI.tools.tool_registry")
  end
  return _tool_registry
end

local function _get_request_handler()
  if not _request_handler then
    _request_handler = require("NeoAI.core.ai.request_handler")
  end
  return _request_handler
end

-- ========== Agent 会话状态 ==========

local _agent_sessions = {}

-- ========== 创建会话 ==========

--- 创建 agent 会话
--- @param params table
--- @return table session
local function _create_session(params)
  return {
    session_id = params.session_id,
    parent_session_id = params.parent_session_id,
    window_id = params.window_id,
    messages = params.messages or {},
    options = params.options or {},
    model_index = params.model_index or 1,
    ai_preset = params.ai_preset or {},
    allowed_tools = params.allowed_tools or {},
    stage = params.stage,
    on_summary = params.on_summary,
    on_error = params.on_error,
    generation_id = nil,
    current_iteration = 0,
    max_iterations = params.max_iterations or 20,
    stop_requested = false,
    accumulated_usage = {},
    active_tool_calls = {},
    _generation_completed = false,
    _tools_all_completed = false,
    _executed_tool_call_ids = {},
  }
end

-- ========== 启动 Agent 循环 ==========

--- 启动 agent 循环
--- @param params table
function M.start_agent_loop(params)
  if not params or not params.session_id then
    if params and params.on_error then
      params.on_error("缺少必要参数: session_id")
    end
    return
  end

  local session = _create_session(params)
  _agent_sessions[session.session_id] = session

  -- 生成 generation_id
  local gen_id = "agent_" .. session.session_id .. "_" .. os.time() .. "_" .. math.random(10000, 99999)
  session.generation_id = gen_id

  -- 构建请求并发送
  _send_ai_request(session)
end

-- ========== 发送 AI 请求 ==========

--- 发送 AI 请求
--- @param session table
local function _send_ai_request(session)
  if session.stop_requested or shutdown_flag.is_set() then
    return
  end

  local request_handler = _get_request_handler()
  local http_utils = _get_http_utils()

  -- 格式化消息
  local formatted = request_handler.format_messages(session.messages)

  -- 构建请求
  local request = request_handler.build_request({
    messages = formatted,
    options = vim.tbl_extend("force", session.options, {
      model = session.ai_preset.model_name or session.options.model,
      stream = true,
    }),
    session_id = session.session_id,
    generation_id = session.generation_id,
  })

  -- 设置工具定义（仅允许的工具）
  if session.allowed_tools and #session.allowed_tools > 0 then
    local all_defs = request_handler.get_tool_definitions() or {}
    local filtered = {}
    for _, def in ipairs(all_defs) do
      local def_name = (def["function"] and def["function"].name) or def.name or ""
      for _, allowed in ipairs(session.allowed_tools) do
        if def_name == allowed then
          table.insert(filtered, def)
          break
        end
      end
    end
    request.tools = filtered
    request.tool_choice = "auto"
  end

  -- 发送流式请求
  http_utils.send_stream_request({
    request = request,
    generation_id = session.generation_id,
    base_url = session.ai_preset.base_url,
    api_key = session.ai_preset.api_key,
    timeout = session.ai_preset.timeout,
    api_type = session.ai_preset.api_type or "openai",
    provider_config = session.ai_preset,
  }, function(data)
    _handle_stream_chunk(session, data)
  end, function()
    _handle_stream_end(session)
  end, function(err)
    _handle_stream_error(session, err)
  end)
end

-- ========== 流式处理 ==========

--- 处理流式数据块
--- @param session table
--- @param data table
local function _handle_stream_chunk(session, data)
  -- 流式数据由 http_utils 处理，此处只需要关注流结束
end

--- 处理流式结束
--- @param session table
local function _handle_stream_end(session)
  if session.stop_requested then
    return
  end

  -- 获取处理器中的完整响应
  local http_utils = _get_http_utils()
  local processor = http_utils.get_stream_processor(session.generation_id)
  if not processor then
    _handle_ai_response(session, "", {}, {})
    return
  end

  local content = processor.content_buffer or ""
  local reasoning = processor.reasoning_buffer or ""
  local usage = processor.usage or {}
  local tool_calls = http_utils.filter_valid_tool_calls(processor.tool_calls or {})

  -- 累积 usage
  if usage and next(usage) then
    local acc = session.accumulated_usage
    acc.prompt_tokens = (acc.prompt_tokens or 0) + (usage.prompt_tokens or usage.input_tokens or 0)
    acc.completion_tokens = (acc.completion_tokens or 0) + (usage.completion_tokens or usage.output_tokens or 0)
    acc.total_tokens = (acc.total_tokens or 0) + (usage.total_tokens or 0)
  end

  _handle_ai_response(session, content, tool_calls, usage)
end

--- 处理流式错误
--- @param session table
--- @param err string
local function _handle_stream_error(session, err)
  if session.stop_requested then
    return
  end

  logger.warn("[pipeline_agent] 流式请求失败: session=%s, err=%s", session.session_id, tostring(err))

  -- 重试
  if session.current_iteration < 3 then
    session.current_iteration = session.current_iteration + 1
    vim.defer_fn(function()
      _send_ai_request(session)
    end, 1000)
  else
    if session.on_error then
      session.on_error("AI 请求失败: " .. tostring(err))
    end
    _cleanup_session(session)
  end
end

-- ========== AI 响应处理 ==========

--- 处理 AI 响应
--- @param session table
--- @param content string
--- @param tool_calls table
--- @param usage table
local function _handle_ai_response(session, content, tool_calls, usage)
  if session.stop_requested then
    return
  end

  session.current_iteration = session.current_iteration + 1

  -- 检查迭代上限
  if session.current_iteration > session.max_iterations then
    local summary = content or "达到最大迭代轮次，未返回总结"
    if session.on_summary then
      session.on_summary(summary, session.accumulated_usage)
    end
    _cleanup_session(session)
    return
  end

  -- 如果有工具调用，执行工具
  if tool_calls and #tool_calls > 0 then
    -- 添加 assistant 消息
    local assistant_msg = {
      role = "assistant",
      content = content or "",
      tool_calls = tool_calls,
      timestamp = os.time(),
    }
    table.insert(session.messages, assistant_msg)

    -- 执行工具
    _execute_tools(session, tool_calls)
    return
  end

  -- 无工具调用：AI 返回纯文本，视为总结
  if content and content ~= "" then
    -- 添加 assistant 消息
    local assistant_msg = {
      role = "assistant",
      content = content,
      timestamp = os.time(),
    }
    table.insert(session.messages, assistant_msg)

    -- 回调总结
    if session.on_summary then
      session.on_summary(content, session.accumulated_usage)
    end
  else
    -- 空响应
    if session.on_summary then
      session.on_summary("", session.accumulated_usage)
    end
  end

  _cleanup_session(session)
end

-- ========== 工具执行 ==========

--- 执行工具调用
--- @param session table
--- @param tool_calls table
local function _execute_tools(session, tool_calls)
  if session.stop_requested or #tool_calls == 0 then
    return
  end

  local tool_executor = _get_tool_executor()
  local tool_registry = _get_tool_registry()
  local pending = #tool_calls

  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if not func or not func.name then
      pending = pending - 1
      if pending <= 0 then
        _on_tools_complete(session)
      end
      goto continue
    end

    local tool_name = func.name
    local args = func.arguments or {}
    local tool_call_id = tc.id or ("call_" .. os.time() .. "_" .. math.random(10000, 99999))

    -- 检查工具是否在允许列表中
    local allowed = false
    for _, allowed_name in ipairs(session.allowed_tools) do
      if tool_name == allowed_name then
        allowed = true
        break
      end
    end

    if not allowed then
      -- 不允许的工具，返回错误
      local result_str = string.format("[工具被禁止] 工具 '%s' 不在当前阶段的允许列表中。", tool_name)
      _add_tool_result(session, tool_call_id, tool_name, result_str)
      pending = pending - 1
      if pending <= 0 then
        _on_tools_complete(session)
      end
      goto continue
    end

    -- 获取工具定义
    local tool_def = tool_registry.get(tool_name)
    if not tool_def or not tool_def.func then
      local result_str = string.format("[工具未找到] 工具 '%s' 未注册。", tool_name)
      _add_tool_result(session, tool_call_id, tool_name, result_str)
      pending = pending - 1
      if pending <= 0 then
        _on_tools_complete(session)
      end
      goto continue
    end

    -- 执行工具
    if tool_def.async then
      -- 异步工具
      tool_def.func(args, function(result)
        if session.stop_requested then return end
        local result_str = type(result) == "string" and result or vim.json.encode(result) or ""
        _add_tool_result(session, tool_call_id, tool_name, result_str)
        pending = pending - 1
        if pending <= 0 then
          _on_tools_complete(session)
        end
      end, function(err)
        if session.stop_requested then return end
        local result_str = "[执行失败] " .. tostring(err)
        _add_tool_result(session, tool_call_id, tool_name, result_str)
        pending = pending - 1
        if pending <= 0 then
          _on_tools_complete(session)
        end
      end)
    else
      -- 同步工具
      local ok, result = pcall(tool_def.func, args)
      local result_str = ""
      if ok then
        result_str = type(result) == "string" and result or vim.json.encode(result) or ""
      else
        result_str = "[执行失败] " .. tostring(result)
      end
      _add_tool_result(session, tool_call_id, tool_name, result_str)
      pending = pending - 1
      if pending <= 0 then
        _on_tools_complete(session)
      end
    end

    ::continue::
  end
end

--- 添加工具结果到消息
--- @param session table
--- @param tool_call_id string
--- @param tool_name string
--- @param result string
local function _add_tool_result(session, tool_call_id, tool_name, result)
  table.insert(session.messages, {
    role = "tool",
    tool_call_id = tool_call_id,
    name = tool_name,
    content = result,
    timestamp = os.time(),
  })
end

--- 工具全部完成
--- @param session table
local function _on_tools_complete(session)
  if session.stop_requested then
    return
  end

  -- 发送下一轮 AI 请求
  vim.defer_fn(function()
    if session.stop_requested then
      return
    end
    _send_ai_request(session)
  end, 50)
end

-- ========== 停止控制 ==========

--- 请求停止 agent
--- @param session_id string
function M.request_stop(session_id)
  local session = _agent_sessions[session_id]
  if session then
    session.stop_requested = true
  end
end

-- ========== 清理 ==========

--- 清理会话
--- @param session table
local function _cleanup_session(session)
  _agent_sessions[session.session_id] = nil
end

--- 获取会话状态
--- @param session_id string
--- @return table|nil
function M.get_session(session_id)
  return _agent_sessions[session_id]
end

--- 清理所有会话
function M.cleanup_all()
  for session_id, session in pairs(_agent_sessions) do
    session.stop_requested = true
  end
  _agent_sessions = {}
end

return M
