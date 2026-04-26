-- 工具调用编排器
-- 负责管理 AI 工具调用的循环执行，支持多轮工具调用和结果整合
local M = {}

-- 导入工具
local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events.event_constants")

-- 模块状态
local state = {
  initialized = false, -- 模块是否已初始化
  config = nil, -- 配置表
  session_manager = nil, -- 会话管理器
  tools = {}, -- 注册的工具表，键为工具名，值为工具定义
  max_iterations = 10, -- 最大工具调用迭代次数
  current_iteration = 0, -- 当前迭代次数
}

--- 初始化工具编排器
--- @param options table 初始化选项
function M.initialize(options)
  if state.initialized then
    return M
  end

  state.config = options.config or {}
  state.session_manager = options.session_manager
  state.max_iterations = options.max_iterations or 10
  state.initialized = true

  logger.info("Tool orchestrator initialized")
  return M
end

--- 执行工具调用循环
--- @param params table 参数，包含generation_id、tool_calls等
--- @return table|nil 工具结果列表
function M.execute_tool_loop(params)
  if not state.initialized then
    error("Tool orchestrator not initialized")
  end

  if not next(state.tools) then
    return nil
  end

  local generation_id = params.generation_id
  local tool_calls = params.tool_calls or {}
  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}

  if #tool_calls == 0 then
    return nil
  end

  state.current_iteration = 0
  local tool_results = {}

  -- 触发工具循环开始事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_STARTED,
    data = {
      generation_id = generation_id,
      tool_calls = tool_calls,
      session_id = session_id,
      window_id = window_id,
      is_reasoning_model = params.is_reasoning_model or false,
    },
  })

  -- logger.info(string.format("Tool loop started for generation %s: %d tool calls", generation_id, #tool_calls))

  -- 执行每个工具调用
  for _, tool_call in ipairs(tool_calls) do
    local result = M.execute_tool({
      generation_id = generation_id,
      tool_call = tool_call,
      session_id = session_id,
      window_id = window_id,
    })

    if result then
      table.insert(tool_results, {
        tool_call = tool_call,
        result = result,
      })
    end
  end

  -- 触发工具循环结束事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_FINISHED,
    data = {
      generation_id = generation_id,
      tool_results = tool_results,
      iteration_count = state.current_iteration,
      session_id = session_id,
      window_id = window_id,
    },
  })

  -- logger.info(string.format("Tool loop finished for generation %s: %d results", generation_id, #tool_results))

  return tool_results
end

--- 执行单个工具
--- @param params table 参数
--- @return any 工具执行结果
function M.execute_tool(params)
  local generation_id = params.generation_id
  local tool_call = params.tool_call
  local session_id = params.session_id
  local window_id = params.window_id

  -- 兼容两种字段名：function（OpenAI 标准）和 func（旧格式）
  local tool_func = tool_call["function"] or tool_call.func
  if not tool_call or not tool_func then
    logger.warn(string.format("Invalid tool call for generation %s", generation_id))
    return nil
  end

  local tool_name = tool_func.name
  local arguments_str = tool_func.arguments

  -- 解析参数
  local arguments = {}
  if arguments_str then
    local ok, parsed = pcall(vim.json.decode, arguments_str)
    if ok and parsed then
      arguments = parsed
    else
      logger.warn(string.format("Failed to parse arguments for tool %s: %s", tool_name, arguments_str))
    end
  end

  -- 触发工具执行开始事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_EXECUTION_STARTED,
    data = {
      generation_id = generation_id,
      tool_call = tool_call,
      tool_name = tool_name,
      arguments = arguments,
      session_id = session_id,
      window_id = window_id,
      start_time = os.time(),
    },
  })

  logger.debug(string.format("Executing tool %s for generation %s", tool_name, generation_id))

  -- 查找并执行工具
  local tool_def = state.tools[tool_name]
  local result = nil
  local error_msg = nil
  local start_time = os.time()

  if tool_def and tool_def.func then
    local success, tool_result = pcall(tool_def.func, arguments)

    if success then
      result = tool_result
    else
      error_msg = tostring(tool_result)
      logger.error(string.format("Tool execution error for %s: %s", tool_name, error_msg))
    end
  else
    error_msg = string.format("Tool not found: %s", tool_name)
    logger.warn(error_msg)
  end

  local duration = os.time() - start_time

  -- 触发工具执行完成事件
  if error_msg then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_EXECUTION_ERROR,
      data = {
        generation_id = generation_id,
        tool_call = tool_call,
        tool_name = tool_name,
        arguments = arguments,
        error_msg = error_msg,
        session_id = session_id,
        window_id = window_id,
        duration = duration,
      },
    })
  else
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_EXECUTION_COMPLETED,
      data = {
        generation_id = generation_id,
        tool_call = tool_call,
        tool_name = tool_name,
        arguments = arguments,
        result = result,
        session_id = session_id,
        window_id = window_id,
        duration = duration,
      },
    })
  end

  local final_result = result or error_msg
  if type(final_result) ~= "string" then
    if type(final_result) == "table" then
      local ok, encoded = pcall(vim.json.encode, final_result)
      if ok then
        final_result = encoded
      else
        final_result = vim.inspect(final_result)
      end
    else
      final_result = tostring(final_result)
    end
  end
  return final_result
end

--- 设置工具
--- @param tools table 工具表
function M.set_tools(tools)
  state.tools = tools or {}
  logger.debug(string.format("Tool orchestrator tools set: %d tools available", vim.tbl_count(state.tools)))
end

--- 从响应中提取工具调用
--- @param response table AI响应
--- @return table 工具调用列表
function M.extract_tool_calls(response)
  if not response or not response.choices or #response.choices == 0 then
    return {}
  end

  local tool_calls = {}
  local choice = response.choices[1]

  if choice.message and choice.message.tool_calls then
    for _, tool_call in ipairs(choice.message.tool_calls) do
      -- 兼容两种字段名：function（OpenAI 标准）和 func（旧格式）
      local tool_func = tool_call["function"] or tool_call.func
      table.insert(tool_calls, {
        id = tool_call.id,
        type = tool_call.type,
        ["function"] = {
          name = tool_func and tool_func.name or "",
          arguments = tool_func and tool_func.arguments or "",
        },
      })
    end
  end

  return tool_calls
end

--- 构建工具调用上下文
--- @param tool_results table 工具结果列表
--- @return table 上下文消息
function M.build_context(tool_results)
  if not tool_results or #tool_results == 0 then
    return {}
  end

  local context_messages = {}

  for _, result in ipairs(tool_results) do
    if result.tool_call and result.result then
      table.insert(context_messages, {
        role = "assistant",
        tool_calls = { result.tool_call },
      })

      -- 确保 tool_call.id 存在，避免 API 验证错误
      local safe_id = result.tool_call.id
      if not safe_id or safe_id == "" then
        safe_id = "call_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))
        logger.warn(string.format("build_context: tool_call.id is nil or empty, generated fallback: %s", safe_id))
      end

      table.insert(context_messages, {
        role = "tool",
        tool_call_id = safe_id,
        content = M.format_tool_result(result.result) or "",
      })
    end
  end

  return context_messages
end

--- 格式化工具结果
--- @param result any 工具执行结果
--- @return string 格式化后的结果
function M.format_tool_result(result)
  if type(result) == "string" then
    return result
  elseif type(result) == "table" then
    return vim.json.encode(result)
  else
    return tostring(result)
  end
end

--- 检查是否应该继续工具调用
--- @param tool_results table 工具结果列表
--- @return boolean 是否继续
function M.should_continue(tool_results)
  -- 简单实现：如果有工具结果就继续
  return tool_results and #tool_results > 0
end

--- 获取当前迭代次数
--- @return number 当前迭代次数
function M.get_current_iteration()
  return state.current_iteration
end

--- 获取可用工具
--- @return table 工具表
function M.get_tools()
  return state.tools
end

--- 验证工具使用
--- @param tool_call table 工具调用
--- @return boolean 是否有效
function M.validate_tool_use(tool_call)
  -- 兼容两种字段名：function（OpenAI 标准）和 func（旧格式）
  local tool_func = tool_call["function"] or tool_call.func
  if not tool_call or not tool_func then
    return false
  end

  local tool_name = tool_func.name
  return state.tools[tool_name] ~= nil
end

--- 选择工具
--- @param query string 查询
--- @param available_tools table 可用工具
--- @return table 选择的工具
function M.select_tools(query, available_tools)
  -- 简单实现：返回所有可用工具
  return available_tools or state.tools
end

--- 合并结果
--- @param results table 结果列表
--- @return any 合并后的结果
function M.merge_results(results)
  if not results or #results == 0 then
    return nil
  end

  if #results == 1 then
    return results[1]
  end

  -- 合并多个结果为字符串
  local merged = ""
  for i, result in ipairs(results) do
    merged = merged .. string.format("Result %d: %s\n", i, tostring(result))
  end

  return merged
end

--- 执行工具（兼容接口）
--- @param tool_call table 工具调用
--- @return any 工具执行结果
function M.execute_tools(tool_call)
  return M.execute_tool({
    generation_id = "compat_" .. tostring(os.time()),
    tool_call = tool_call,
  })
end

--- 获取模块状态
--- @return table 状态信息
function M.get_state()
  return {
    initialized = state.initialized,
    tools_count = vim.tbl_count(state.tools),
    current_iteration = state.current_iteration,
    max_iterations = state.max_iterations,
    config = state.config,
  }
end

--- 关闭工具编排器
function M.shutdown()
  if not state.initialized then
    return
  end

  -- 清理工具
  state.tools = {}

  -- 重置状态
  state.initialized = false
  state.current_iteration = 0

  logger.info("Tool orchestrator shutdown")
end

--- 导出模块
return M
