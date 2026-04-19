-- 工具编排器模块
-- 该模块用于管理 AI 工具调用的循环执行，支持多轮工具调用和结果整合
local M = {}

-- 模块状态
local state = {
  initialized = false, -- 模块是否已初始化
  event_bus = nil, -- 事件总线，用于发布事件
  config = nil, -- 配置表
  session_manager = nil, -- 会话管理器
  tools = {}, -- 注册的工具表，键为工具名，值为工具定义
  max_iterations = 10, -- 最大工具调用迭代次数
  current_iteration = 0, -- 当前迭代次数
}

--- 初始化工具编排器
--- 此函数用于初始化模块，必须在调用其他功能前执行
--- @param options table 初始化选项
---   - event_bus: 事件总线对象
---   - config: 配置表（可选）
---   - session_manager: 会话管理器（可选）
---   - max_iterations: 最大迭代次数，默认 10（可选）
function M.initialize(options)
  if state.initialized then
    return
  end

  state.event_bus = options.event_bus
  state.config = options.config or {}
  state.session_manager = options.session_manager
  state.max_iterations = options.max_iterations or 10
  state.initialized = true
end

--- 执行工具调用循环
--- 这是核心函数，会循环调用 AI 并执行工具，直到满足停止条件
--- @param messages table 消息列表，作为 AI 对话的上下文
--- @return string|nil 最终结果，可能是 AI 的直接响应，也可能是工具调用结果的整合
function M.execute_tool_loop(messages)
  if not state.initialized then
    error("Tool orchestrator not initialized")
  end

  if #state.tools == 0 then
    return nil
  end

  state.current_iteration = 0
  local current_messages = vim.deepcopy(messages)
  local final_result = nil

  -- 触发循环开始事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:tool_loop_started", data = { current_messages } })

  while state.current_iteration < state.max_iterations do
    state.current_iteration = state.current_iteration + 1

    -- 调用AI生成响应（可能包含工具调用）
    local response = M._call_ai_with_tools(current_messages)

    -- 解析响应中的工具调用
    local tool_calls = M.parse_tool_call(response)

    if tool_calls and #tool_calls > 0 then
      -- 执行工具调用
      local tool_results = {} -- 修复 BUG: 明确声明局部变量
      for _, tool_call in ipairs(tool_calls) do
        local result = M.execute_tool(tool_call)
        if result then
          table.insert(tool_results, result)

          -- 构建工具响应消息
          local tool_message = {
            role = "tool",
            content = result,
            tool_call_id = tool_call.id,
            name = tool_call.name,
          }

          table.insert(current_messages, tool_message)
        end
      end

      -- 检查是否应该继续
      if not M.should_continue(tool_results) then
        final_result = M.build_context(tool_results)
        break
      end
    else
      -- 没有工具调用，返回AI响应
      final_result = response
      break
    end
  end -- 修复 BUG: 添加循环结束标记

  -- 触发循环结束事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tool_loop_finished", data = { final_result, state.current_iteration } }
  )

  return final_result
end

--- 解析工具调用
--- 从 AI 响应中提取工具调用信息
--- @param response string|table AI响应，可能是字符串或 Lua 表
--- @return table|nil 工具调用列表，每个元素包含 id、name、arguments 等字段
function M.parse_tool_call(response)
  -- 调用 extract_tool_calls 函数实现工具调用解析
  return M.extract_tool_calls(response)
end

--- 执行工具（别名函数）
--- 此函数是 execute_tool_loop 的别名，提供向后兼容性
--- @param messages_or_tool_calls table 消息列表或工具调用列表
--- @return string|nil 执行结果
function M.execute_tools(messages_or_tool_calls)
  if not messages_or_tool_calls then
    return nil
  end

  -- 检查参数类型
  if type(messages_or_tool_calls[1]) == "table" and messages_or_tool_calls[1].name then
    -- 看起来是工具调用列表（包含 name 字段）
    local results = {}
    for _, tool_call in ipairs(messages_or_tool_calls) do
      local result = M.execute_tool(tool_call)
      table.insert(results, result)
    end

    return M.merge_results(results)
  else
    -- 假设是消息列表
    return M.execute_tool_loop(messages_or_tool_calls)
  end
end

--- 选择工具
--- 根据查询内容从可用工具中选择合适的工具
--- @param query string 查询内容
--- @param available_tools table|nil 可用工具列表（可选，默认使用 state.tools）
--- @return table 选择的工具列表
function M.select_tools(query, available_tools)
  local tools_to_use = available_tools or state.tools

  if not tools_to_use or #tools_to_use == 0 then
    return {}
  end

  -- 简单的工具选择逻辑：返回所有工具
  -- 实际实现中应根据查询内容进行智能选择
  return tools_to_use
end

--- 合并结果
--- 将多个工具执行结果合并为一个字符串
--- @param results table 结果列表
--- @return string 合并后的结果
function M.merge_results(results)
  if not results or #results == 0 then
    return ""
  end

  local merged = {}
  for i, result in ipairs(results) do
    table.insert(merged, "结果 " .. i .. ": " .. tostring(result))
  end

  return table.concat(merged, "\n\n")
end

--- 验证工具使用
--- 检查工具调用是否有效（工具是否存在）
--- @param tool_call table 工具调用
--- @return boolean 是否有效
function M.validate_tool_use(tool_call)
  if not tool_call or not tool_call.name then
    return false
  end

  -- 检查工具是否存在
  for _, tool in ipairs(state.tools) do
    if tool.name == tool_call.name then
      return true
    end
  end

  return false
end

--- 从AI响应中提取工具调用
--- 支持新旧两种格式的工具调用响应
--- @param response string|table AI响应
--- @return table|nil 工具调用列表
function M.extract_tool_calls(response)
  if not response then
    return nil
  end

  -- 如果响应是字符串，尝试解析为JSON
  local response_data
  if type(response) == "string" then
    local ok, parsed = pcall(vim.json.decode, response)
    if ok then
      response_data = parsed
    else
      -- 尝试提取JSON部分
      local json_match = response:match('%{%s*"tool_calls"%s*:%s*%[.-%]%s*%}')
      if json_match then
        local ok2, parsed2 = pcall(vim.json.decode, json_match)
        if ok2 then
          response_data = parsed2
        end
      end
    end
  else
    response_data = response
  end

  if not response_data then
    return nil
  end

  -- 提取工具调用
  local tool_calls = {}

  if response_data.tool_calls then
    for _, tool_call in ipairs(response_data.tool_calls) do
      table.insert(tool_calls, {
        id = tool_call.id or ("tool_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))),
        name = tool_call.name,
        arguments = tool_call.arguments or {},
        type = "function",
      })
    end
  elseif response_data.function_call then
    -- 旧格式支持（OpenAI 旧版 function_call）
    table.insert(tool_calls, {
      id = "tool_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
      name = response_data.function_call.name,
      arguments = response_data.function_call.arguments or {},
      type = "function",
    })
  end

  return #tool_calls > 0 and tool_calls or nil
end

--- 执行单个工具
--- 查找并执行指定的工具
--- @param tool_call table 工具调用
--- @return string|nil 工具执行结果（字符串格式）
function M.execute_tool(tool_call)
  if not tool_call or not tool_call.name then
    return nil
  end

  -- 查找工具
  local tool = state.tools[tool_call.name]
  if not tool then
    local error_msg = "Tool not found: " .. tool_call.name
    vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:tool_error", data = { tool_call, error_msg } })
    return error_msg
  end

  -- 触发工具执行开始事件
  vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:tool_execution_started", data = { tool_call } })

  -- 执行工具
  local success, result = pcall(function()
    local args = tool_call.arguments or {}
    if type(args) == "string" then
      local ok, parsed = pcall(vim.json.decode, args)
      if ok then
        args = parsed
      end
    end
    return tool.func(args)
  end)

  -- 处理执行结果
  if not success then
    local error_msg = "Tool execution error: " .. result
    vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:tool_error", data = { tool_call, error_msg } })
    return error_msg
  end

  -- 格式化结果
  local formatted_result
  if type(result) == "table" then
    formatted_result = vim.json.encode(result)
  else
    formatted_result = tostring(result)
  end

  -- 触发工具执行完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "NeoAI:tool_execution_completed", data = { tool_call, formatted_result } }
  )

  return formatted_result
end

--- 构建上下文
--- 将工具调用结果整合为字符串上下文
--- @param tool_results table 工具结果列表
--- @return string 构建的上下文字符串
function M.build_context(tool_results)
  if not tool_results or #tool_results == 0 then
    return ""
  end

  local context_parts = {}
  table.insert(context_parts, "=== 工具调用结果 ===")
  table.insert(context_parts, "")

  for i, result in ipairs(tool_results) do
    table.insert(context_parts, string.format("工具调用 %d:", i))
    table.insert(context_parts, result)
    table.insert(context_parts, "")
  end

  table.insert(context_parts, "=== 上下文结束 ===")

  return table.concat(context_parts, "\n")
end

--- 判断是否继续调用
--- 根据工具结果决定是否继续下一轮工具调用
--- @param tool_results table 工具结果列表
--- @return boolean 是否继续
function M.should_continue(tool_results)
  if not tool_results or #tool_results == 0 then
    return false
  end

  -- 检查是否达到最大迭代次数
  if state.current_iteration >= state.max_iterations then
    return false
  end

  -- 检查工具结果是否表明需要继续
  for _, result in ipairs(tool_results) do
    if type(result) == "string" then
      -- 简单启发式：如果结果包含特定标记，可能需要继续
      if result:match("需要更多信息") or result:match("请继续") or result:match("下一步") then
        return true
      end
    end
  end

  -- 默认情况下，如果有工具结果且未达到最大迭代次数，继续
  return true
end

--- 设置工具
--- 注册可用的工具
--- @param tools table 工具列表，键为工具名，值为工具定义（必须包含 func 函数）
function M.set_tools(tools)
  state.tools = {}
  for name, tool_def in pairs(tools) do
    if tool_def.func and type(tool_def.func) == "function" then
      state.tools[name] = tool_def
    end
  end
end

--- 获取当前迭代次数
--- @return number 当前迭代次数
function M.get_current_iteration()
  return state.current_iteration
end

--- 获取工具列表
--- @return table 工具列表的深拷贝
function M.get_tools()
  return vim.deepcopy(state.tools)
end

--- 调用AI并传递工具定义（内部使用）
--- 模拟函数，实际应调用 AI API
--- @param messages table 消息列表
--- @return string AI响应
function M._call_ai_with_tools(messages)
  -- 这里应该调用实际的AI API，并传递工具定义
  -- 目前返回模拟响应

  local tool_definitions = {}
  for name, tool in pairs(state.tools) do
    table.insert(tool_definitions, {
      type = "function",
      ["function"] = {
        name = name,
        description = tool.description or "No description",
        parameters = tool.parameters or {},
      },
    })
  end

  -- 模拟AI响应（随机决定是否调用工具）
  if math.random() > 0.5 and #tool_definitions > 0 then
    local random_tool = tool_definitions[math.random(#tool_definitions)]
    return vim.json.encode({
      tool_calls = {
        id = "call_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
        name = random_tool["function"].name,
        arguments = { query = "示例查询" },
      },
    })
  else
    return "这是AI的直接响应，没有调用工具。"
  end
end

return M
