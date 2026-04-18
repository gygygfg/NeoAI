local M = {}

local stream_processor = require("NeoAI.core.ai.stream_processor")
local reasoning_manager = require("NeoAI.core.ai.reasoning_manager")
local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
local response_builder = require("NeoAI.core.ai.response_builder")
local json = require("NeoAI.utils.json")
local text_utils = require("NeoAI.utils.text_utils")

-- 模块状态
local state = {
  initialized = false,
  event_bus = nil,
  config = nil,
  session_manager = nil,
  is_generating = false,
  current_generation_id = nil,
  tools = nil,
}

--- 初始化AI引擎
--- @param options table 选项
--- @return table AI引擎实例
function M.initialize(options)
  if state.initialized then
    return M
  end

  state.event_bus = options.event_bus
  state.config = options.config or {}
  state.session_manager = options.session_manager

  -- 初始化子模块
  stream_processor.initialize({
    event_bus = state.event_bus,
    config = state.config,
  })

  reasoning_manager.initialize({
    event_bus = state.event_bus,
    config = state.config,
  })

  tool_orchestrator.initialize({
    event_bus = state.event_bus,
    config = state.config,
    session_manager = state.session_manager,
  })

  response_builder.initialize({
    event_bus = state.event_bus,
    config = state.config,
  })

  state.initialized = true
  return M
end

--- 生成响应
--- @param messages table 消息列表
--- @param options table 选项
--- @return string 响应ID
function M.generate_response(messages, options)
  if not state.initialized then
    error("AI engine not initialized")
  end

  -- 安全检查：如果正在生成，先尝试重置状态
  if state.is_generating then
    print("⚠️  检测到未完成的生成，正在重置状态...")
    state.is_generating = false
    state.current_generation_id = nil
  end

  state.is_generating = true
  local generation_id = "gen_" .. os.time() .. "_" .. math.random(1000, 9999)
  state.current_generation_id = generation_id

  -- 记录生成开始时间（用于检测卡住）
  M._set_generation_start_time()

  -- 合并选项
  local merged_options = vim.tbl_extend("force", state.config, options or {})

  -- 将消息列表拆分为历史消息和当前查询
  local history = {}
  local current_query = nil

  if messages and #messages > 0 then
    -- 查找最后一个用户消息作为当前查询
    for i = #messages, 1, -1 do
      local msg = messages[i]
      if msg and msg.role == "user" then
        current_query = msg.content
        -- 当前查询之前的所有消息作为历史
        for j = 1, i - 1 do
          table.insert(history, messages[j])
        end
        break
      end
    end

    -- 如果没有找到用户消息，使用所有消息作为历史
    if not current_query then
      history = messages
    end
  end

  -- 构建消息
  local formatted_messages = response_builder.build_messages(history, current_query, merged_options)

  -- 触发开始事件
  if state.event_bus then
    state.event_bus.emit("generation_started", generation_id, formatted_messages)
  end

  -- 异步生成响应（带安全包装）
  vim.schedule(function()
    local success, result = pcall(function()
      return M._generate_response_async(generation_id, formatted_messages, merged_options, options)
    end)

    if not success then
      -- 确保错误处理一定会重置状态
      pcall(function()
        M._handle_generation_error(generation_id, result, options)
      end)

      -- 额外的安全重置
      state.is_generating = false
      state.current_generation_id = nil
    end
  end)

  return generation_id
end

--- 流式响应
--- @param messages table 消息列表
--- @param options table 选项
--- @return function 流式处理器
function M.stream_response(messages, options)
  if not state.initialized then
    error("AI engine not initialized")
  end

  -- 安全检查：如果正在生成，先尝试重置状态
  if state.is_generating then
    print("⚠️  检测到未完成的生成，正在重置状态...")
    state.is_generating = false
    state.current_generation_id = nil
  end

  state.is_generating = true
  local generation_id = "gen_" .. os.time() .. "_" .. math.random(1000, 9999)
  state.current_generation_id = generation_id

  -- 记录生成开始时间（用于检测卡住）
  M._set_generation_start_time()

  -- 合并选项
  local merged_options = vim.tbl_extend("force", state.config, options or {})

  -- 将消息列表拆分为历史消息和当前查询
  local history = {}
  local current_query = nil

  if messages and #messages > 0 then
    -- 查找最后一个用户消息作为当前查询
    for i = #messages, 1, -1 do
      local msg = messages[i]
      if msg and msg.role == "user" then
        current_query = msg.content
        -- 当前查询之前的所有消息作为历史
        for j = 1, i - 1 do
          table.insert(history, messages[j])
        end
        break
      end
    end

    -- 如果没有找到用户消息，使用所有消息作为历史
    if not current_query then
      history = messages
    end
  end

  -- 构建消息
  local formatted_messages = response_builder.build_messages(history, current_query, merged_options)

  -- 触发开始事件
  if state.event_bus then
    state.event_bus.emit("generation_started", generation_id, formatted_messages)
  end

  -- 创建流式处理器
  local stream_handler = function(chunk)
    stream_processor.process_chunk(chunk)
  end

  -- 异步流式生成
  vim.schedule(function()
    local success, result = pcall(function()
      return M._stream_response_async(generation_id, formatted_messages, merged_options, stream_handler)
    end)

    if not success then
      -- 确保错误处理一定会重置状态
      pcall(function()
        M._handle_generation_error(generation_id, result)
      end)

      -- 额外的安全重置
      state.is_generating = false
      state.current_generation_id = nil
    end
  end)

  return stream_handler
end

--- 取消生成
function M.cancel_generation()
  if not state.is_generating then
    return
  end

  local generation_id = state.current_generation_id
  state.is_generating = false
  state.current_generation_id = nil

  -- 触发取消事件
  if state.event_bus then
    state.event_bus.emit("generation_cancelled", generation_id)
  end

  -- 清理流式处理器
  stream_processor.flush_buffer()
  reasoning_manager.clear_reasoning()
end

--- 是否正在生成
--- @return boolean 是否正在生成
function M.is_generating()
  return state.is_generating
end

--- 设置工具
--- @param tools table 工具列表
function M.set_tools(tools)
  state.tools = tools
  if tool_orchestrator then
    tool_orchestrator.set_tools(tools)
  end
end

--- 处理查询
--- @param query string 查询内容
--- @param options table 选项
--- @return string 响应ID
function M.process_query(query, options)
  if not state.initialized then
    error("AI engine not initialized")
  end

  -- 构建消息
  local messages = {}
  table.insert(messages, {
    role = "user",
    content = query,
  })

  -- 生成响应
  return M.generate_response(messages, options)
end

--- 获取引擎状态
--- @return table 状态信息
function M.get_status()
  return {
    initialized = state.initialized,
    is_generating = state.is_generating,
    current_generation_id = state.current_generation_id,
    tools_available = state.tools and #state.tools > 0,
  }
end

--- 异步生成响应（内部使用）
--- @param generation_id string 生成ID
--- @param messages table 消息列表
--- @param options table 选项
--- @param callbacks table 回调函数
function M._generate_response_async(generation_id, messages, options, callbacks)
  -- 提取回调函数
  local on_chunk = callbacks and callbacks.on_chunk
  local on_complete = callbacks and callbacks.on_complete
  local on_error = callbacks and callbacks.on_error

  -- 检查API密钥
  local api_key = state.config.api_key
  if not api_key or api_key == "" then
    local error_msg = "API密钥未设置。请设置DEEPSEEK_API_KEY环境变量或在配置中设置api_key。"
    M._handle_generation_error(generation_id, error_msg, callbacks)
    return
  end

  -- 检查是否为测试环境（使用test_key或其他测试标识）
  local is_test_environment = api_key == "test_key"
    or api_key:match("^test_")
    or api_key:match("^mock_")
    or api_key:match("^demo_")

  if is_test_environment then
    -- 测试环境：返回模拟响应
    print("🔧 [TEST] 测试环境检测到，返回模拟响应")

    -- 模拟延迟
    vim.defer_fn(function()
      -- 构建模拟响应
      local mock_response = {
        choices = {
          {
            message = {
              content = "这是一个模拟的AI响应（测试环境）",
            },
          },
        },
      }

      -- 处理响应
      M._process_http_response(generation_id, json.encode(mock_response), messages, options, callbacks)
    end, 100) -- 100ms延迟模拟网络请求

    return
  end

  -- 构建请求数据
  local request_data = {
    model = state.config.model or "deepseek-reasoner",
    messages = messages,
    temperature = state.config.temperature or 0.7,
    max_tokens = state.config.max_tokens or 4096,
    stream = options.stream or false,
  }

  local request_url = state.config.base_url or "https://api.deepseek.com/chat/completions"

  -- 调试：打印请求信息
  print("🔍 [DEBUG] AI请求信息:")
  print("  - 模型: " .. (request_data.model or "未设置"))
  print("  - 消息数量: " .. #messages)
  print("  - 温度: " .. tostring(request_data.temperature))
  print("  - 最大token数: " .. tostring(request_data.max_tokens))
  print("  - 流式: " .. tostring(request_data.stream))
  print("  - API密钥长度: " .. (api_key and #api_key or 0))
  print("  - API密钥前10位: " .. (api_key and string.sub(api_key, 1, 10) .. "..." or "未设置"))
  print("  - 请求URL: " .. request_url)

  -- 打印完整的请求数据（调试用）
  print("🔍 [DEBUG] 完整请求数据:")
  local request_json = json.encode(request_data)
  print("  - 请求JSON长度: " .. #request_json)
  print("  - 请求JSON前500字符: " .. string.sub(request_json, 1, 500))

  -- 添加工具调用（如果有）
  if options.tools and #options.tools > 0 then
    request_data.tools = options.tools
  end

  -- 发送HTTP请求（使用兼容的HTTP客户端）

  -- 检查是否为流式请求
  if request_data.stream then
    -- 流式请求：使用专门的流式处理函数
    local stream_handler = function(chunk)
      -- 处理流式数据块
      if on_chunk then
        on_chunk(chunk)
      end

      -- 注意：不再直接调用stream_processor.process_chunk
      -- 因为_stream_response_async会通过_process_stream_chunk处理数据块
    end

    -- 调用流式响应函数，传递完整的callbacks
    M._stream_response_async(generation_id, messages, options, stream_handler, callbacks)
    return
  end

  -- 非流式请求：继续原有逻辑
  -- 编码请求数据
  local request_body = json.encode(request_data)

  -- 构建curl命令
  local curl_cmd = {
    "curl",
    "-s",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Authorization: Bearer " .. api_key,
    "-H",
    "Accept: application/json",
    "-d",
    request_body,
    request_url,
  }

  local response_text = ""

  -- 检查vim.system是否可用（Neovim 0.10+）
  if vim.system then
    -- 使用vim.system的异步模式执行curl命令
    -- 创建闭包以捕获messages变量
    local process_response = function(result)
      -- 在回调中处理响应
      vim.schedule(function()
        if result.code ~= 0 then
          local error_msg = "HTTP请求失败: curl退出码 " .. tostring(result.code)
          if result.stderr and #result.stderr > 0 then
            error_msg = error_msg .. ": " .. result.stderr
          end
          M._handle_generation_error(generation_id, error_msg, callbacks)
          return
        end

        local response_text = result.stdout
        M._process_http_response(generation_id, response_text, messages, options, callbacks)
      end)
    end

    local system_obj = vim.system(curl_cmd, {
      text = true,
    }, process_response)

    -- 设置超时（从配置获取，默认60秒）
    local timeout_ms = state.config.timeout or 60000
    vim.defer_fn(function()
      if system_obj then
        -- 检查 system_obj 的类型
        if type(system_obj) == "table" then
          -- Neovim 0.10+ 返回对象，可能有 pid 方法
          if system_obj.pid and type(system_obj.pid) == "function" then
            local pid = system_obj:pid()
            if pid then
              system_obj:kill(9) -- 强制终止进程
              M._handle_generation_error(
                generation_id,
                "HTTP请求超时（" .. (timeout_ms / 1000) .. "秒）",
                callbacks
              )
            end
          elseif system_obj.pid and type(system_obj.pid) == "number" then
            -- pid 是数字属性
            os.execute("kill -9 " .. system_obj.pid .. " 2>/dev/null")
            M._handle_generation_error(
              generation_id,
              "HTTP请求超时（" .. (timeout_ms / 1000) .. "秒）",
              callbacks
            )
          end
        elseif type(system_obj) == "number" then
          -- 如果是进程ID，使用系统命令终止
          os.execute("kill -9 " .. system_obj .. " 2>/dev/null")
          M._handle_generation_error(generation_id, "HTTP请求超时（" .. (timeout_ms / 1000) .. "秒）", callbacks)
        end
      end
    end, timeout_ms)

    return -- 立即返回，不等待HTTP请求完成
  else
    -- 回退到vim.fn.system（旧版本Neovim）- 使用vim.loop.spawn实现异步
    local cmd_str = table.concat(curl_cmd, " ")

    -- 使用vim.loop.spawn实现异步执行
    local handle
    local stdout_data = {}
    local stderr_data = {}

    -- 创建闭包以捕获messages变量
    local spawn_callback = function(code, signal)
      vim.schedule(function()
        if code ~= 0 then
          local error_msg = "HTTP请求失败: 退出码 " .. tostring(code)
          if #stderr_data > 0 then
            error_msg = error_msg .. ": " .. table.concat(stderr_data, " ")
          end
          M._handle_generation_error(generation_id, error_msg, callbacks)
          return
        end

        local response_text = table.concat(stdout_data, "")
        M._process_http_response(generation_id, response_text, messages, options, callbacks)
      end)
    end

    handle = vim.loop.spawn("sh", {
      args = { "-c", cmd_str },
    }, spawn_callback)

    if handle then
      -- 读取stdout
      vim.loop.read_start(handle, function(err, data)
        if data then
          table.insert(stdout_data, data)
        end
      end)

      -- 读取stderr
      vim.loop.read_start(handle, function(err, data)
        if data then
          table.insert(stderr_data, data)
        end
      end)

      -- 设置超时（从配置获取，默认60秒）
      local timeout_ms = state.config.timeout or 60000
      vim.defer_fn(function()
        if handle and handle:is_active() then
          handle:kill(9) -- 强制终止进程
          M._handle_generation_error(generation_id, "HTTP请求超时（" .. (timeout_ms / 1000) .. "秒）", callbacks)
        end
      end, timeout_ms)
    else
      M._handle_generation_error(generation_id, "无法启动HTTP请求进程", callbacks)
    end

    return -- 立即返回，不等待HTTP请求完成
  end

  -- 注意：这个函数现在会在HTTP请求完成后被异步调用
  -- 实际的响应处理逻辑已经移到_process_http_response函数中

  -- 函数立即返回，不等待HTTP请求完成
  return nil
end

--- 处理HTTP响应（异步回调）
--- @param generation_id string 生成ID
--- @param response_text string 响应文本
--- @param messages table 消息列表
--- @param options table 选项
--- @param callbacks table 回调函数
function M._process_http_response(generation_id, response_text, messages, options, callbacks)
  -- 提取回调函数
  local on_chunk = callbacks and callbacks.on_chunk
  local on_complete = callbacks and callbacks.on_complete

  -- 调试：打印响应信息
  print("🔍 [DEBUG] AI响应信息:")
  print("  - 响应长度: " .. (response_text and #response_text or 0))
  print("  - 响应前500字符: " .. (response_text and string.sub(response_text, 1, 500) or "无响应"))

  -- 检查响应文本是否有效
  if not response_text or response_text == "" then
    local error_msg = "API响应为空"
    M._handle_generation_error(generation_id, error_msg, callbacks)
    return
  end

  -- 解析响应
  local success, response_data = pcall(json.decode, response_text)
  if not success then
    print("🔍 [DEBUG] JSON解析失败详情:")
    print("  - 错误信息: " .. tostring(response_data))
    print("  - 原始响应: " .. response_text)

    local error_msg = "API响应JSON解析失败: " .. tostring(response_data)
    M._handle_generation_error(generation_id, error_msg, callbacks)
    return
  end

  if not response_data or not response_data.choices or #response_data.choices == 0 then
    print("🔍 [DEBUG] 响应格式错误详情:")
    print("  - response_data类型: " .. type(response_data))
    if response_data then
      print("  - response_data键: " .. table.concat(vim.tbl_keys(response_data), ", "))
      print("  - response_data内容: " .. vim.inspect(response_data))
    end

    local error_msg = "API响应格式错误"
    M._handle_generation_error(generation_id, error_msg, callbacks)
    return
  end

  local response = response_data.choices[1].message.content

  -- 检查是否有推理内容
  local reasoning_content = nil
  if response_data.choices[1].message.reasoning_content then
    reasoning_content = response_data.choices[1].message.reasoning_content
    -- 触发推理内容事件
    if state.event_bus then
      state.event_bus.emit("reasoning_content", reasoning_content)
    end
  end

  -- 处理工具调用
  if options.tools and #options.tools > 0 then
    -- 延迟加载tool_orchestrator
    local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
    -- 现在可以使用传递的messages参数
    local tool_result = tool_orchestrator.execute_tool_loop(messages)
    if tool_result then
      response = tool_result
    end
  end

  -- 处理流式响应（如果启用了流式）
  if options.stream and on_chunk then
    -- 对于流式响应，我们需要使用不同的处理方式
    -- 这里我们仍然使用非流式响应，但可以模拟流式
    -- 实际实现需要使用支持流式的HTTP客户端

    -- 将响应拆分为多个数据块（模拟流式）
    local words = {}
    for word in response:gmatch("%S+") do
      table.insert(words, word)
    end

    for i, word in ipairs(words) do
      vim.defer_fn(function()
        if on_chunk then
          on_chunk(word .. " ")
        end
      end, 50 * i) -- 递增延迟
    end
  end

  -- 触发完成事件
  if state.event_bus then
    state.event_bus.emit("generation_completed", generation_id, response)
  end

  -- 调用完成回调
  if on_complete then
    vim.defer_fn(function()
      on_complete(response)
    end, 800) -- 在流式响应后调用
  end

  -- 重置生成状态
  state.is_generating = false
  state.current_generation_id = nil
  state.generation_start_time = nil

  return response
end

--- 处理流式数据块
--- @param chunk string 数据块
--- @param generation_id string 生成ID
function M._process_stream_chunk(chunk, generation_id)
  -- 使用新的去重处理函数
  M._process_and_deduplicate_chunk(chunk, generation_id)
end

--- 清理流式数据块（内部使用）
--- @param chunk string 原始数据块
--- @return string 清理后的数据块
function M._clean_stream_chunk(chunk)
  if not chunk or chunk == "" then
    return ""
  end

  -- 首先检查是否是调试信息
  if chunk:match("^%[DEBUG%]") or chunk:match("^%[INFO%]") then
    -- 尝试提取调试信息后的内容
    local content = chunk:match("^%[%a+%]%s*(.+)")
    if content then
      -- 检查是否是AI响应数据块的调试信息
      if content:match("^收到AI响应数据块:") then
        -- 这是调试信息，返回空
        return ""
      end
      -- 对于其他调试信息，移除末尾的数字标记
      content = content:gsub("%s+%d+$", "")
      return content
    end
    return ""
  end

  -- 检查是否是其他调试信息（没有方括号前缀）
  if chunk:match("^收到AI响应数据块:") then
    -- 这是调试信息，返回空
    return ""
  end

  -- 检查是否是SSE格式（data: {...}）
  if chunk:match("^data: ") then
    -- 这是SSE格式，直接返回
    return chunk
  end

  -- 对于其他内容，移除行尾的数字标记和多余空格
  local cleaned = chunk:gsub("%s+%d+$", "")
  cleaned = cleaned:gsub("%s+", " ")
  cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")

  return cleaned
end

--- 异步流式响应（内部使用）
--- @param generation_id string 生成ID
--- @param messages table 消息列表
--- @param options table 选项
--- @param stream_handler function 流式处理器
--- @param callbacks table 回调函数
function M._stream_response_async(generation_id, messages, options, stream_handler, callbacks)
  -- 检查API密钥
  local api_key = state.config.api_key
  if not api_key or api_key == "" then
    local error_msg = "API密钥未设置。请设置DEEPSEEK_API_KEY环境变量或在配置中设置api_key。"
    M._handle_generation_error(generation_id, error_msg)
    return
  end

  -- 构建请求数据
  local request_data = {
    model = state.config.model or "deepseek-reasoner",
    messages = messages,
    temperature = state.config.temperature or 0.7,
    max_tokens = state.config.max_tokens or 4096,
    stream = true, -- 强制启用流式
  }

  -- 添加工具调用（如果有）
  if options.tools and #options.tools > 0 then
    request_data.tools = options.tools
  end

  -- 使用vim.fn.jobstart实现流式HTTP客户端
  -- 注意：json变量已在文件开头导入，不需要重新require
  local request_url = state.config.base_url or "https://api.deepseek.com/chat/completions"

  -- 编码请求数据
  local request_body = json.encode(request_data)

  -- 创建临时文件保存请求体
  local temp_file = os.tmpname()
  local temp_file_handle = io.open(temp_file, "w")
  if temp_file_handle then
    temp_file_handle:write(request_body)
    temp_file_handle:close()
  else
    local error_msg = "无法创建临时文件"
    M._handle_generation_error(generation_id, error_msg)
    return
  end

  -- 构建curl命令用于流式请求
  local curl_cmd = {
    "curl",
    "-s",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Authorization: Bearer " .. api_key,
    "-H",
    "Accept: text/event-stream",
    "--data-binary",
    "@" .. temp_file,
    request_url,
  }

  -- 收集所有响应数据
  local all_response_data = {}
  local full_response = ""

  -- 使用jobstart执行流式请求
  local job_id = vim.fn.jobstart(curl_cmd, {
    on_stdout = function(_, data, _)
      if data and #data > 0 then
        for _, chunk in ipairs(data) do
          if chunk and #chunk > 0 then
            table.insert(all_response_data, chunk)

            -- 处理流式数据（只处理一次）
            M._process_stream_chunk(chunk, generation_id)

            -- 调用stream_handler传递数据块给聊天窗口回调
            if stream_handler then
              stream_handler(chunk)
            end

            -- 尝试从SSE格式中提取内容
            if chunk:match("^data: ") then
              -- 先清理数据块（移除行号等）
              local cleaned_chunk = M._clean_stream_chunk(chunk)
              if cleaned_chunk and cleaned_chunk ~= "" then
                local json_str = cleaned_chunk:match("^data: (.+)$")
                if json_str and json_str ~= "[DONE]" then
                  local ok, data_chunk = pcall(json.decode, json_str)
                  if ok and data_chunk and data_chunk.choices and #data_chunk.choices > 0 then
                    local delta = data_chunk.choices[1].delta
                    if delta and delta.content then
                      full_response = full_response .. delta.content
                    end
                    -- 提取推理内容（如果有）
                    if delta and delta.reasoning_content then
                      -- 推理内容会通过 stream_processor 处理
                      -- 这里只需要确保它被传递给 stream_processor
                    end
                  end
                end
              end
            end
          end
        end
      end
    end,
    on_stderr = function(_, data, _)
      if data and #data > 0 then
        local error_msg = "流式请求错误: " .. table.concat(data, " ")
        M._handle_generation_error(generation_id, error_msg)
      end
    end,
    on_exit = function(_, exit_code, _)
      -- 清理临时文件
      os.remove(temp_file)

      if exit_code ~= 0 then
        local error_msg = "流式请求失败，退出码: " .. tostring(exit_code)
        M._handle_generation_error(generation_id, error_msg, callbacks)
      else
        -- 流式响应成功完成，调用on_complete回调
        local on_complete = callbacks and callbacks.on_complete
        if on_complete and full_response ~= "" then
          vim.schedule(function()
            on_complete(full_response)
          end)
        end
      end
    end,
  })

  -- 等待作业完成
  vim.fn.jobwait({ job_id })

  -- 如果没有获取到完整响应，尝试从收集的数据中构建
  if full_response == "" and #all_response_data > 0 then
    local response_text = table.concat(all_response_data, "")
    local ok, response_data = pcall(json.decode, response_text)
    if ok and response_data and response_data.choices and #response_data.choices > 0 then
      full_response = response_data.choices[1].message.content or ""
    end
  end

  -- 注意：不再需要模拟流式响应，因为真正的SSE响应已经在on_stdout回调中处理了
  -- 流式数据已经通过stream_handler传递给聊天窗口回调

  -- 处理工具调用（流式模式下）
  if options.tools and #options.tools > 0 then
    local tool_result = tool_orchestrator.execute_tool_loop(messages)
    if tool_result then
      -- 工具调用结果也需要通过stream_handler传递
      if stream_handler then
        stream_handler(tool_result)
      end
    end
  end

  -- 触发完成事件
  if state.event_bus then
    state.event_bus.emit("generation_completed", generation_id, full_response)
  end

  state.is_generating = false
  state.current_generation_id = nil
  stream_processor.flush_buffer()
end

--- 处理生成错误（内部使用）
--- @param generation_id string 生成ID
--- @param error_msg string 错误信息
--- @param callbacks table 回调函数
function M._handle_generation_error(generation_id, error_msg, callbacks)
  state.is_generating = false
  state.current_generation_id = nil
  state.generation_start_time = nil

  -- 触发错误事件
  if state.event_bus then
    state.event_bus.emit("generation_error", generation_id, error_msg)
  end

  -- 调用错误回调
  if callbacks and callbacks.on_error then
    callbacks.on_error(error_msg)
  end

  vim.notify("AI生成错误: " .. error_msg, vim.log.levels.ERROR)
end

--- 重置引擎状态（主要用于测试）
function M.reset_state()
  state.is_generating = false
  state.current_generation_id = nil
  print("🔄 AI引擎状态已重置")
end

--- 安全重置生成状态（防止卡住）
--- 如果检测到正在生成但可能已经卡住，自动重置状态
function M.safe_reset_if_stuck()
  if state.is_generating then
    -- 检查是否已经卡住超过30秒
    local current_time = os.time()
    local generation_start_time = state.generation_start_time or 0

    if current_time - generation_start_time > 30 then
      print("⚠️  检测到可能卡住的生成（超过30秒），正在重置状态...")
      state.is_generating = false
      state.current_generation_id = nil
      state.generation_start_time = nil
      return true
    end
  end
  return false
end

--- 设置生成开始时间（内部使用）
function M._set_generation_start_time()
  state.generation_start_time = os.time()
end

--- 测试流式数据清理（用于调试）
--- @param test_chunk string 测试数据块
--- @return string 清理后的数据
function M.test_stream_cleanup(test_chunk)
  return M._clean_stream_chunk(test_chunk)
end

--- 应用智能去重到AI响应
--- @param text string AI响应文本
--- @return string 去重后的文本
function M.apply_deduplication(text)
  if not text or type(text) ~= "string" then
    return ""
  end
  
  -- 使用text_utils的智能去重函数
  return text_utils.deduplicate_ai_response(text)
end

--- 智能拼接并去重（核心去重逻辑）
--- @param existing_text string 已有文本
--- @param new_chunk string 新数据块
--- @return string 处理后的文本
function M.smart_concat_and_deduplicate(existing_text, new_chunk)
  if not existing_text or existing_text == "" then
    return new_chunk or ""
  end
  
  if not new_chunk or new_chunk == "" then
    return existing_text
  end
  
  -- 首先进行智能拼接，移除重叠部分
  local concatenated = text_utils.smart_concat(existing_text, new_chunk, 3)
  
  -- 然后应用AI响应去重
  return text_utils.deduplicate_ai_response(concatenated)
end

--- 处理并去重流式数据块（统一入口）
--- @param chunk string 原始数据块
--- @param generation_id string 生成ID
function M._process_and_deduplicate_chunk(chunk, generation_id)
  if not chunk or chunk == "" then
    return
  end
  
  -- 清理数据块
  local cleaned_chunk = M._clean_stream_chunk(chunk)
  
  if cleaned_chunk == "" then
    return
  end
  
  -- 如果是SSE格式数据，提取内容并去重
  if cleaned_chunk:match("^data: ") then
    local json_str = cleaned_chunk:match("^data: (.+)$")
    if json_str and json_str ~= "[DONE]" then
      local ok, data = pcall(json.decode, json_str)
      if ok and data and data.choices and #data.choices > 0 then
        local delta = data.choices[1].delta
        if delta and delta.content then
          -- 应用去重到内容
          local deduplicated_content = text_utils.deduplicate_ai_response(delta.content)
          if deduplicated_content ~= delta.content then
            -- 如果内容有变化，更新delta
            delta.content = deduplicated_content
            -- 重新编码为JSON
            cleaned_chunk = "data: " .. json.encode(data)
          end
        end
      end
    end
  end
  
  -- 传递给流处理器
  if stream_processor then
    stream_processor.process_chunk(cleaned_chunk)
  end
  
  -- 触发数据块事件
  if state.event_bus then
    state.event_bus.emit("stream_chunk", generation_id, cleaned_chunk)
  end
end

return M
