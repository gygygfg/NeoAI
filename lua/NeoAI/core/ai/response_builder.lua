-- 响应构建器模块
-- 提供构建消息、格式化结果、估算token等功能
local M = {}

-- 模块状态
local state = {
  initialized = false, -- 是否已初始化
  config = nil, -- 配置
}

--- 初始化响应构建器
--- @param options table 初始化选项
---   - config: table 配置表，可选
---     - system_prompt: string 系统提示词
---     - max_history: number 最大历史消息数
---     - max_tool_result_length: number 最大工具结果长度
function M.initialize(options)
  if state.initialized then
    vim.notify("警告: 响应构建器已初始化，跳过重复初始化")
    return
  end

  options = options or {}
  state.config = options.config or {}
  state.initialized = true

  -- vim.notify("响应构建器初始化成功")
end

--- 构建消息列表
--- 将历史消息、系统提示和当前查询组合成完整的消息列表
--- @param history table 历史消息数组
--- @param query string|table 当前查询内容
--- @param options table 选项
---   - system_prompt: string 系统提示词，覆盖全局配置
---   - max_history: number 最大历史消息数，覆盖全局配置
--- @return table 构建完成的消息列表
function M.build_messages(history, query, options)
  if not state.initialized then
    error("响应构建器未初始化，请先调用M.initialize()")
  end

  local messages = {}
  options = options or {}

  -- 添加系统提示（优先使用options中的配置，其次使用全局配置）
  local system_prompt = options.system_prompt or state.config.system_prompt
  if system_prompt then
    table.insert(messages, {
      role = "system",
      content = system_prompt,
    })
  end

  -- 添加历史消息
  if history and #history > 0 then
    -- 应用历史限制
    local max_history = options.max_history or state.config.max_history or 20
    local start_index = math.max(1, #history - max_history + 1)

    for i = start_index, #history do
      local msg = history[i]
      if msg and msg.role and msg.content then
        table.insert(messages, {
          role = msg.role,
          content = msg.content,
          name = msg.name,
          tool_call_id = msg.tool_call_id,
        })
      end
    end
  end

  -- 添加当前查询
  if query then
    local query_content
    if type(query) == "table" then
      query_content = query.content or vim.json.encode(query)
    else
      query_content = tostring(query)
    end

    table.insert(messages, {
      role = "user",
      content = query_content,
    })
  end

  -- 触发消息构建完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:messages_built",
    data = {
      messages = messages,
      history_count = #history or 0,
    },
  })

  return messages
end

--- 格式化工具结果
--- 将工具返回的结果转换为可读的字符串格式
--- @param result string|table 工具返回的结果
--- @return string 格式化后的结果字符串
function M.format_tool_result(result)
  if not result then
    return ""
  end

  local formatted_result

  if type(result) == "table" then
    -- 尝试将表格转换为格式化的JSON字符串
    local ok, json = pcall(vim.json.encode, result)
    if ok then
      formatted_result = json
    else
      -- 如果JSON编码失败，回退到字符串表示
      formatted_result = tostring(result)
    end
  else
    formatted_result = tostring(result)
  end

  -- 如果结果太长，进行截断
  local max_length = state.config.max_tool_result_length or 1000
  if #formatted_result > max_length then
    formatted_result = formatted_result:sub(1, max_length) .. "... [结果已截断]"
  end

  return formatted_result
end

--- 创建消息摘要
--- 为消息列表生成简短的文本摘要，便于日志记录和调试
--- @param messages table 消息列表
--- @param max_length number 最大长度限制，可选
--- @return string 摘要字符串
function M.create_summary(messages, max_length)
  if not messages or #messages == 0 then
    return "无消息"
  end

  max_length = max_length or 100

  local summary_parts = {}
  local total_length = 0

  for i, msg in ipairs(messages) do
    if total_length >= max_length then
      break
    end

    -- 为不同角色选择不同的图标
    local role_symbol
    if msg.role == "user" then
      role_symbol = "👤"
    elseif msg.role == "assistant" then
      role_symbol = "🤖"
    else
      role_symbol = "🛠️"
    end

    -- 处理内容预览
    local content_preview
    if type(msg.content) == "string" then
      -- 移除换行符，限制长度
      content_preview = msg.content:gsub("\n", " "):sub(1, 50)
      if #msg.content > 50 then
        content_preview = content_preview .. "..."
      end
    else
      content_preview = "[非文本内容]"
    end

    local line = string.format("%s %s: %s", role_symbol, msg.role, content_preview)
    table.insert(summary_parts, line)

    total_length = total_length + #line
  end

  -- 如果有消息被截断，添加提示
  if #messages > #summary_parts then
    table.insert(summary_parts, string.format("... 还有 %d 条消息", #messages - #summary_parts))
  end

  return table.concat(summary_parts, "\n")
end

--- 压缩上下文
--- 根据token限制压缩消息列表，保留最重要的消息
--- @param messages table 原始消息列表
--- @param max_tokens number 最大token数，默认4000
--- @return table 压缩后的消息列表
function M.compact_context(messages, max_tokens)
  if not messages or #messages == 0 then
    return {}
  end

  max_tokens = max_tokens or 4000

  -- 简单实现：保留最近的N条消息
  -- 注意：这里使用固定比例估算，实际项目中应考虑精确的token计数
  local max_messages = math.floor(max_tokens / 100) -- 假设每条消息约100个token
  max_messages = math.max(1, math.min(max_messages, #messages))

  local compressed = {}
  local start_index = #messages - max_messages + 1

  for i = start_index, #messages do
    table.insert(compressed, messages[i])
  end

  -- 如果压缩了上下文，添加系统消息说明
  if #compressed < #messages then
    table.insert(compressed, 1, {
      role = "system",
      content = string.format(
        "注意：由于上下文长度限制，只显示了最近的 %d 条消息（共 %d 条）。",
        #compressed,
        #messages
      ),
    })
  end

  return compressed
end

--- 构建工具调用消息
--- 创建用于工具调用的消息结构
--- @param tool_name string 工具名称
--- @param arguments table 工具调用参数
--- @param tool_call_id string 工具调用ID，可选
--- @return table 工具调用消息
function M.build_tool_call_message(tool_name, arguments, tool_call_id)
  -- 如果未提供tool_call_id，生成一个唯一的ID
  if not tool_call_id then
    math.randomseed(os.time())
    tool_call_id = "call_" .. os.time() .. "_" .. math.random(1000, 9999)
  end

  return {
    role = "assistant",
    content = nil,
    tool_calls = {
      {
        id = tool_call_id,
        type = "function",
        ["function"] = {
          name = tool_name,
          arguments = arguments,
        },
      },
    },
  }
end

--- 构建工具结果消息
--- 创建工具执行结果的返回消息
--- @param tool_call_id string 对应的工具调用ID
--- @param result string 工具执行结果
--- @param tool_name string 工具名称
--- @return table 工具结果消息
function M.build_tool_result_message(tool_call_id, result, tool_name)
  if not tool_call_id then
    error("工具调用ID不能为空")
  end

  return {
    role = "tool",
    tool_call_id = tool_call_id,
    name = tool_name,
    content = result,
  }
end

--- 估算文本的token数量
--- 使用简化的估算方法：中文约2字符/token，英文约4字符/token
--- @param text string 输入文本
--- @return number 估算的token数量
function M.estimate_tokens(text)
  if not text or text == "" then
    return 0
  end

  text = tostring(text)

  -- 统计中文字符数（UTF-8中文字符范围）
  local chinese_chars = 0
  for _ in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chinese_chars = chinese_chars + 1
  end

  local total_chars = #text
  local other_chars = total_chars - chinese_chars

  -- 估算公式：中文字符/2 + 其他字符/4
  return math.ceil(chinese_chars / 2 + other_chars / 4)
end

--- 估算消息列表的token总数
--- @param messages table 消息列表
--- @return number 总token数量
function M.estimate_message_tokens(messages)
  if not messages then
    return 0
  end

  local total_tokens = 0
  for _, msg in ipairs(messages) do
    if msg.content then
      total_tokens = total_tokens + M.estimate_tokens(tostring(msg.content))
    end

    -- 为角色名称、元数据等添加固定开销
    total_tokens = total_tokens + 10
  end

  return total_tokens
end

--- 构建最终响应
--- 将AI响应、工具结果等组合成最终的用户响应
--- @param params table 参数表
---   - original_messages: table 原始消息列表
---   - ai_response: table AI响应
---   - tool_results: table 工具结果列表
--- @return table 最终响应
function M.build_response(params)
  if not params then
    return { content = "无响应" }
  end

  local response = {
    content = "",
  }

  -- 如果有AI响应内容，添加它
  if params.ai_response and params.ai_response.content then
    response.content = params.ai_response.content
  end

  -- 如果有工具结果，格式化后添加到响应中
  if params.tool_results and #params.tool_results > 0 then
    if response.content and #response.content > 0 then
      response.content = response.content .. "\n\n工具调用结果:\n"
    else
      response.content = "工具调用结果:\n"
    end

    for i, result in ipairs(params.tool_results) do
      response.content = response.content .. string.format("%d. %s\n", i, M.format_tool_result(result))
    end
  end

  -- 如果有推理内容，也添加到响应中
  if params.ai_response and params.ai_response.reasoning then
    if response.content and #response.content > 0 then
      response.content = response.content .. "\n\n推理过程:\n" .. params.ai_response.reasoning
    else
      response.content = "推理过程:\n" .. params.ai_response.reasoning
    end
  end

  return response
end

--- 重置模块状态（用于测试和重新初始化）
function M.reset()
  state.initialized = false
  state.config = nil
  vim.notify("响应构建器已重置")
end

--- 获取模块状态（用于调试）
--- @return table 当前模块状态
function M.get_state()
  return {
    initialized = state.initialized,
    config = state.config,
  }
end

-- 测试函数
local function test()
  vim.notify("=== 开始测试响应构建器 ===")

  -- 初始化模块
  M.initialize({
    config = {
      system_prompt = "你是一个有用的AI助手",
      max_history = 5,
      max_tool_result_length = 500,
    },
  })

  -- 测试1: 构建消息
  local history = {
    { role = "user", content = "你好" },
    { role = "assistant", content = "你好！有什么可以帮助你的吗？" },
  }

  local messages = M.build_messages(history, "今天的天气怎么样？")
  vim.notify("构建的消息数量:", #messages)
  vim.notify("消息摘要:", M.create_summary(messages))

  -- 测试2: 估算token
  local text = "这是一个测试文本，包含中文和English。"
  local tokens = M.estimate_tokens(text)
  vim.notify("文本token估算:", tokens)

  -- 测试3: 格式化工具结果
  local tool_result = { temperature = 25, condition = "sunny", city = "北京" }
  local formatted = M.format_tool_result(tool_result)
  vim.notify("格式化工具结果:", formatted)

  -- 测试4: 构建工具调用消息
  local tool_call_msg = M.build_tool_call_message("get_weather", { city = "北京" })
  vim.notify("工具调用消息:", vim.inspect(tool_call_msg))

  -- 测试5: 压缩上下文
  local long_messages = {}
  for i = 1, 10 do
    table.insert(long_messages, { role = "user", content = "消息" .. i })
  end
  local compressed = M.compact_context(long_messages, 500)
  vim.notify("压缩后消息数量:", #compressed)

  vim.notify("=== 测试完成 ===")
end

-- 如果直接运行此文件，执行测试
if arg and arg[0] and arg[0]:match("response_builder.lua") then
  test()
end

return M
