-- 请求构建器
-- 负责构建AI请求体，添加工具信息，格式化消息为模型可接受的格式
local M = {}

-- 导入工具
local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events.event_constants")

-- 模块内部状态
local state = {
  initialized = false,
  config = {},
  tools = {},
  tool_definitions = {}, -- 工具定义，用于构建工具列表
  tool_call_counter = 0, -- 添加计数器避免ID重复
}

--- 初始化请求构建器
--- @param options table 初始化选项
function M.initialize(options)
  if state.initialized then
    return M
  end

  state.config = options.config or {}
  state.initialized = true
  state.tool_call_counter = 0
  logger.debug("Request builder initialized")
  return M
end

--- 设置可用工具
--- @param tools table 工具函数表
function M.set_tools(tools)
  state.tools = tools or {}
  state.tool_definitions = {}

  for tool_name, tool_def in pairs(state.tools) do
    if tool_def.func then
      local tool_func = {
        name = tool_name,
        description = tool_def.description or ("执行 " .. tool_name .. " 操作"),
      }

      -- 处理参数定义
      -- 注意：Lua 的空表 {} 在 JSON 编码时会被编码为 []（空数组）而不是 {}（空对象）
      -- DeepSeek API 不接受空的 properties: {}，会报 "[] is not of type 'object'" 错误
      -- 解决方案：当 properties 为空时，不传递 parameters 字段
      local params = tool_def.parameters
      if params and type(params) == "table" then
        local has_properties = false
        if params.properties and type(params.properties) == "table" then
          -- 检查 properties 是否有实际字段
          for _, _ in pairs(params.properties) do
            has_properties = true
            break
          end
        end

        if has_properties then
          -- 有实际参数定义，传递完整的 parameters
          local clean_params = {
            type = params.type or "object",
            properties = params.properties,
          }
          if params.required and type(params.required) == "table" and #params.required > 0 then
            clean_params.required = params.required
          end
          tool_func.parameters = clean_params
        end
        -- 没有实际参数时，不传递 parameters 字段
      end

      local tool_definition = {
        type = "function",
        ["function"] = tool_func,
      }

      table.insert(state.tool_definitions, tool_definition)
    else
      -- 如果工具没有func，记录警告
      logger.warn(string.format("工具 '%s' 没有定义 func 函数，将被忽略", tool_name))
    end
  end

  logger.debug(string.format("Request builder tools updated: %d tools available", #state.tool_definitions))
end

--- 构建AI请求体
--- @param params table 请求参数
--- @return table 构建好的请求体
function M.build_request(params)
  if not state.initialized then
    error("Request builder not initialized")
  end

  local messages = params.messages or {}
  local options = params.options or {}
  local session_id = params.session_id

  -- 生成更可靠的唯一ID
  state.tool_call_counter = state.tool_call_counter + 1
  local generation_id = params.generation_id
    or tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. "_" .. tostring(state.tool_call_counter)

  -- 构建基础请求
  local request = {
    model = options.model or state.config.model or "gpt-4",
    messages = messages,
    max_tokens = options.max_tokens or state.config.max_tokens or 2000,
    stream = options.stream ~= false, -- 默认启用流式
  }

  -- 添加思考启用配置 - 修正格式
  local reasoning_enabled
  if options.reasoning_enabled ~= nil then
    reasoning_enabled = options.reasoning_enabled
  else
    reasoning_enabled = state.config.reasoning_enabled
  end

  -- DeepSeek Thinking Mode: 将 thinking 参数放入 extra_body
  -- 不支持参数：temperature、top_p、presence_penalty、frequency_penalty
  -- 设置这些参数不会报错，但也不会生效
  if reasoning_enabled then
    -- 映射 effort 级别
    -- low/medium -> high, xhigh -> max
    local raw_effort = options.reasoning_effort or state.config.reasoning_effort or "high"
    local effort_map = {
      low = "high",
      medium = "high",
      high = "high",
      xhigh = "max",
      max = "max",
    }
    local thinking_effort = effort_map[raw_effort] or "high"

    request.extra_body = {
      thinking = {
        enabled = true,
        effort = thinking_effort,
      },
    }
  else
    -- 非思考模式：可以设置 temperature 等参数
    request.temperature = options.temperature or state.config.temperature or 0.7
  end

  -- 添加工具定义（如果启用了工具）
  -- 优先级：options.tools_enabled > state.config.tools.enabled > state.config.tools_enabled
  local tools_enabled
  if options.tools_enabled ~= nil then
    tools_enabled = options.tools_enabled
  elseif state.config.tools and state.config.tools.enabled ~= nil then
    tools_enabled = state.config.tools.enabled
  else
    tools_enabled = state.config.tools_enabled
  end

  if tools_enabled and #state.tool_definitions > 0 then
    request.tools = state.tool_definitions
    request.tool_choice = "auto" -- 让模型自动选择工具
  end

  -- 添加会话上下文
  if session_id then
    request.session_id = session_id
  end

  -- 添加生成ID用于跟踪
  request.generation_id = generation_id

  -- 触发请求构建完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.REQUEST_BUILT,
    data = {
      generation_id = generation_id,
      request = request,
      has_tools = #state.tool_definitions > 0,
      tools_count = #state.tool_definitions,
      reasoning_enabled = reasoning_enabled,
    },
  })

  logger.debug(string.format(
    "Request built for generation %s with %d messages, %d tools",
    generation_id,
    #messages,
    #state.tool_definitions
  ))

  return request
end

--- 格式化消息为模型可接受的格式
--- @param messages table 原始消息列表
--- @return table 格式化后的消息列表
function M.format_messages(messages)
  if not messages or type(messages) ~= "table" then
    return {}
  end

  local formatted_messages = {}

  for _, msg in ipairs(messages) do
    local formatted_msg = {}

    -- 确保消息有role字段
    formatted_msg.role = msg.role or "user"

    -- 处理内容字段
    if msg.content then
      if type(msg.content) == "table" then
        -- 如果是复杂内容（如包含工具调用结果）
        formatted_msg.content = msg.content
      else
        -- 如果是简单文本内容
        formatted_msg.content = tostring(msg.content)
      end
    end

    -- 处理工具调用相关字段
    if msg.tool_calls then
      formatted_msg.tool_calls = msg.tool_calls
    end

    if msg.tool_call_id then
      formatted_msg.tool_call_id = msg.tool_call_id
    end

    if msg.name then
      formatted_msg.name = msg.name
    end

    -- DeepSeek Thinking Mode: 保留 reasoning_content 用于工具调用上下文链
    -- 当有工具调用时，后续请求必须完整回传 reasoning_content
    if msg.reasoning_content then
      formatted_msg.reasoning_content = msg.reasoning_content
    end

    table.insert(formatted_messages, formatted_msg)
  end

  return formatted_messages
end

--- 构建工具调用消息
--- @param tool_name string 工具名称
--- @param arguments table 工具参数
--- @param tool_call_id string 工具调用ID
--- @return table 工具调用消息
function M.build_tool_call_message(tool_name, arguments, tool_call_id)
  state.tool_call_counter = state.tool_call_counter + 1
  local id = tool_call_id
    or "call_"
      .. tostring(os.time())
      .. "_"
      .. tostring(state.tool_call_counter)
      .. "_"
      .. tostring(math.random(1000, 9999))

  return {
    role = "assistant",
    tool_calls = {
      {
        id = id,
        type = "function",
        ["function"] = {
          name = tool_name,
          arguments = vim.json.encode(arguments or {}),
        },
      },
    },
  }
end

--- 构建工具结果消息
--- @param tool_call_id string 工具调用ID
--- @param result any 工具执行结果
--- @param tool_name string 工具名称（可选）
--- @return table 工具结果消息
function M.build_tool_result_message(tool_call_id, result, tool_name)
  local message = {
    role = "tool",
    tool_call_id = tool_call_id,
  }

  -- 处理结果内容
  if type(result) == "string" then
    message.content = result
  elseif result ~= nil then
    message.content = tostring(result)
  else
    message.content = ""
  end

  if tool_name then
    message.name = tool_name
  end

  return message
end

--- 添加工具调用到消息历史
--- @param messages table 当前消息列表
--- @param tool_call table 工具调用
--- @param tool_result any 工具执行结果
--- @return table 更新后的消息列表
function M.add_tool_call_to_history(messages, tool_call, tool_result)
  local updated_messages = vim.deepcopy(messages or {})

  -- 确保工具调用是有效的
  -- 兼容两种字段名：function（OpenAI 标准）和 func（旧格式）
  local tool_func = tool_call["function"] or tool_call.func
  if not tool_call or not tool_call.id or not tool_func or not tool_func.name then
    logger.warn("无效的工具调用，无法添加到历史")
    return updated_messages
  end

  -- 添加工具调用消息
  table.insert(updated_messages, {
    role = "assistant",
    tool_calls = { tool_call },
  })

  -- 添加工具结果消息
  table.insert(updated_messages, M.build_tool_result_message(tool_call.id, tool_result, tool_func.name))

  return updated_messages
end

--- 估计请求的token数量
--- @param request table AI请求
--- @return number 估计的token数量
function M.estimate_request_tokens(request)
  if not request then
    return 0
  end

  local total_tokens = 0

  -- 估算消息token
  if request.messages then
    for _, msg in ipairs(request.messages) do
      if msg.content then
        if type(msg.content) == "string" then
          -- 更准确的估算：考虑中文和英文的不同token长度
          local content = msg.content
          local chinese_chars = 0
          local english_chars = 0

          -- 粗略统计中文字符
          for _ in content:gmatch("[\228-\233][\128-\191][\128-\191]") do
            chinese_chars = chinese_chars + 1
          end

          english_chars = #content - chinese_chars * 3

          -- 估算token：中文每个字符约1.5个token，英文每4个字符约1个token
          total_tokens = total_tokens + math.ceil(chinese_chars * 1.5) + math.ceil(english_chars / 4)
        elseif type(msg.content) == "table" then
          -- 对于复杂内容，估算JSON大小
          local success, json_str = pcall(vim.json.encode, msg.content)
          if success and json_str then
            total_tokens = total_tokens + math.ceil(#json_str / 4)
          else
            -- 如果编码失败，使用保守估计
            total_tokens = total_tokens + 100
          end
        end
      end
    end
  end

  -- 估算工具定义token
  if request.tools then
    for _, tool in ipairs(request.tools) do
      local success, tool_str = pcall(vim.json.encode, tool)
      if success and tool_str then
        total_tokens = total_tokens + math.ceil(#tool_str / 4)
      else
        total_tokens = total_tokens + 50
      end
    end
  end

  return total_tokens
end

--- 检查请求是否包含工具调用
--- @param request table AI请求
--- @return boolean 是否包含工具调用
function M.has_tool_calls(request)
  if not request or not request.messages then
    return false
  end

  for _, msg in ipairs(request.messages) do
    if msg.tool_calls and #msg.tool_calls > 0 then
      return true
    end
  end

  return false
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

--- 获取模块状态
--- @return table 状态信息
function M.get_status()
  return {
    initialized = state.initialized,
    tools_count = #state.tool_definitions,
    tools_available = #state.tool_definitions > 0,
    config = {
      model = state.config.model,
      temperature = state.config.temperature,
      max_tokens = state.config.max_tokens,
      tools_enabled = state.config.tools_enabled,
      reasoning_enabled = state.config.reasoning_enabled,
    },
  }
end

--- 重置模块状态
function M.reset()
  state.tools = {}
  state.tool_definitions = {}
  state.tool_call_counter = 0
  logger.debug("Request builder reset")
end

return M
