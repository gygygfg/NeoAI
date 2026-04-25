-- 响应构建器模块
-- 负责处理 AI 响应、构建消息、格式化工具结果等

local M = {}

-- 导入工具
local logger = require("NeoAI.utils.logger")
local Events = require("NeoAI.core.events.event_constants")

-- 模块内部状态
local state = {
  initialized = false,
  config = {},
  session_manager = nil,
}

--- 初始化响应构建器
--- @param options table 初始化选项
function M.initialize(options)
  if state.initialized then
    return M
  end

  state.config = options.config or {}
  state.session_manager = options.session_manager
  state.initialized = true

  logger.info("Response builder initialized")
  return M
end

--- 处理 AI 响应（非流式）
--- 从真正的 API 响应中提取内容、工具调用和 usage 信息
--- @param response_data table 响应数据
--- @return table 处理后的响应
function M.process_response(response_data)
  if not state.initialized then
    logger.warn("Response builder not initialized")
    return response_data
  end

  local response = response_data.response
  local generation_id = response_data.generation_id
  local session_id = response_data.session_id
  local window_id = response_data.window_id
  local options = response_data.options or {}

  logger.debug(string.format("Processing response for generation: %s", generation_id))

  -- 从 API 响应中提取内容
  local response_content = ""
  local reasoning_content = nil
  local tool_calls = {}
  local usage = {}

  if type(response) == "table" then
    -- 标准 OpenAI/DeepSeek API 格式
    if response.choices and #response.choices > 0 then
      local choice = response.choices[1]

      if choice.message then
        response_content = choice.message.content or ""
        reasoning_content = choice.message.reasoning_content

        if choice.message.tool_calls then
          tool_calls = choice.message.tool_calls
        end
      end

      if choice.finish_reason then
        logger.debug(string.format(
          "Response finish reason (generation=%s): %s",
          generation_id, choice.finish_reason
        ))
      end
    end

    -- 提取 usage 信息
    if response.usage then
      usage = response.usage
      logger.debug(string.format(
        "Token usage (generation=%s): prompt=%d, completion=%d, total=%d",
        generation_id,
        usage.prompt_tokens or 0,
        usage.completion_tokens or 0,
        usage.total_tokens or 0
      ))
    end

    -- 处理模型信息
    if response.model then
      logger.debug(string.format("Model used (generation=%s): %s", generation_id, response.model))
    end
  elseif type(response) == "string" then
    response_content = response
  else
    response_content = tostring(response)
  end

  -- 触发响应构建完成事件
vim.api.nvim_exec_autocmds("User", {
    pattern = Events.RESPONSE_BUILT,
    data = {
      generation_id = generation_id,
      content = response_content,
      reasoning_content = reasoning_content,
      tool_calls = tool_calls,
      usage = usage,
      session_id = session_id,
      window_id = window_id,
    },
  })

  -- 返回处理后的响应
  return {
    content = response_content,
    reasoning_content = reasoning_content,
    tool_calls = tool_calls,
    usage = usage,
    generation_id = generation_id,
    session_id = session_id,
    window_id = window_id,
    processed = true,
    timestamp = os.time(),
  }
end

--- 获取响应构建器状态
--- @return table 状态信息
function M.get_state()
  return {
    initialized = state.initialized,
    config = state.config,
    session_manager = state.session_manager ~= nil,
  }
end

--- 构建消息
--- @param history table 历史消息
--- @param query string 查询内容
--- @param options table 选项
--- @return table 构建的消息
function M.build_messages(history, query, options)
  if not state.initialized then
    logger.warn("Response builder not initialized")
    return {}
  end

  options = options or {}
  local messages = {}

  -- 添加系统消息（如果有）
  if options.system_message then
    table.insert(messages, {
      role = "system",
      content = options.system_message,
    })
  end

  -- 添加历史消息
  if history and #history > 0 then
    for _, msg in ipairs(history) do
      table.insert(messages, {
        role = msg.role or "user",
        content = msg.content or "",
      })
    end
  end

  -- 添加当前查询
  if query then
    table.insert(messages, {
      role = "user",
      content = query,
    })
  end

  logger.debug("Built messages count:", #messages)
  return messages
end

--- 格式化工具结果
--- @param result table 工具执行结果
--- @return table 格式化后的结果
function M.format_tool_result(result)
  if not result then
    return { content = "No result" }
  end

  -- 根据结果类型进行格式化
  if type(result) == "string" then
    return { content = result }
  elseif type(result) == "table" then
    -- 尝试转换为字符串
    local success, formatted = pcall(vim.json.encode, result)
    if success then
      return { content = formatted }
    else
      return { content = tostring(result) }
    end
  else
    return { content = tostring(result) }
  end
end

--- 创建消息摘要
--- @param messages table 消息列表
--- @param max_length number 最大长度
--- @return string 摘要文本
function M.create_summary(messages, max_length)
  if not messages or #messages == 0 then
    return ""
  end

  max_length = max_length or 100

  local summary = ""
  for i, msg in ipairs(messages) do
    if i > 3 then -- 只取前3条消息
      break
    end

    local role = msg.role or "unknown"
    local content = msg.content or ""
    local preview = string.sub(content, 1, 50)
    if #content > 50 then
      preview = preview .. "..."
    end

    summary = summary .. string.format("[%s]: %s\n", role, preview)
  end

  -- 截断到最大长度
  if #summary > max_length then
    summary = string.sub(summary, 1, max_length) .. "..."
  end

  return summary
end

--- 压缩上下文
--- @param messages table 消息列表
--- @param max_tokens number 最大令牌数
--- @return table 压缩后的消息
function M.compact_context(messages, max_tokens)
  if not messages or #messages == 0 then
    return {}
  end

  max_tokens = max_tokens or 1000

  -- 简单的压缩策略：保留系统消息和最近的几条消息
  local compressed = {}
  local estimated_tokens = 0

  -- 首先添加系统消息（如果有）
  for _, msg in ipairs(messages) do
    if msg.role == "system" then
      table.insert(compressed, msg)
      estimated_tokens = estimated_tokens + M.estimate_message_tokens({msg})
    end
  end

  -- 然后从后往前添加用户/助手消息，直到达到令牌限制
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if msg.role ~= "system" then
      local msg_tokens = M.estimate_message_tokens({msg})
      if estimated_tokens + msg_tokens <= max_tokens then
        table.insert(compressed, 1, msg) -- 插入到开头以保持顺序
        estimated_tokens = estimated_tokens + msg_tokens
      else
        break
      end
    end
  end

  logger.debug("Compressed context:", #compressed, "messages, estimated tokens:", estimated_tokens)
  return compressed
end

--- 估算文本的令牌数
--- @param text string 文本
--- @return number 估算的令牌数
function M.estimate_tokens(text)
  if not text or text == "" then
    return 0
  end

  -- 简单的估算：4个字符大约等于1个token
  -- 这是一个粗略的估算，实际值取决于具体的分词器
  return math.ceil(#text / 4)
end

--- 估算消息的令牌数
--- @param messages table 消息列表
--- @return number 估算的令牌数
function M.estimate_message_tokens(messages)
  if not messages or #messages == 0 then
    return 0
  end

  local total_tokens = 0
  for _, msg in ipairs(messages) do
    -- 消息格式的额外令牌
    total_tokens = total_tokens + 3 -- 每个消息的开销

    -- 内容令牌
    if msg.content then
      total_tokens = total_tokens + M.estimate_tokens(msg.content)
    end

    -- 角色令牌
    if msg.role then
      total_tokens = total_tokens + M.estimate_tokens(msg.role)
    end

    -- 名称令牌（如果有）
    if msg.name then
      total_tokens = total_tokens + M.estimate_tokens(msg.name)
    end
  end

  return total_tokens
end

--- 导出模块
return M