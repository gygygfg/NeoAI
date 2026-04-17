local M = {}

local stream_processor = require("NeoAI.core.ai.stream_processor")
local reasoning_manager = require("NeoAI.core.ai.reasoning_manager")
local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
local response_builder = require("NeoAI.core.ai.response_builder")

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

  if state.is_generating then
    error("Already generating response")
  end

  state.is_generating = true
  local generation_id = "gen_" .. os.time() .. "_" .. math.random(1000, 9999)
  state.current_generation_id = generation_id

  -- 合并选项
  local merged_options = vim.tbl_extend("force", state.config, options or {})

  -- 构建消息
  local formatted_messages = response_builder.build_messages(messages, merged_options)

  -- 触发开始事件
  if state.event_bus then
    state.event_bus.emit("generation_started", generation_id, formatted_messages)
  end

  -- 异步生成响应
  vim.schedule(function()
    local success, result = pcall(function()
      return M._generate_response_async(generation_id, formatted_messages, merged_options, options)
    end)

    if not success then
      M._handle_generation_error(generation_id, result, options)
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

  if state.is_generating then
    error("Already generating response")
  end

  state.is_generating = true
  local generation_id = "gen_" .. os.time() .. "_" .. math.random(1000, 9999)
  state.current_generation_id = generation_id

  -- 合并选项
  local merged_options = vim.tbl_extend("force", state.config, options or {})

  -- 构建消息
  local formatted_messages = response_builder.build_messages(messages, merged_options)

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
      M._handle_generation_error(generation_id, result)
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

  -- 构建请求数据
  local request_data = {
    model = state.config.model or "deepseek-reasoner",
    messages = messages,
    temperature = state.config.temperature or 0.7,
    max_tokens = state.config.max_tokens or 4096,
    stream = options.stream or false,
  }

  -- 添加工具调用（如果有）
  if options.tools and #options.tools > 0 then
    request_data.tools = options.tools
  end

  -- 发送HTTP请求（使用兼容的HTTP客户端）
  local json = require("NeoAI.utils.json")

  local request_url = state.config.base_url or "https://api.deepseek.com/chat/completions"

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
              M._handle_generation_error(generation_id, "HTTP请求超时（" .. (timeout_ms/1000) .. "秒）", callbacks)
            end
          elseif system_obj.pid and type(system_obj.pid) == "number" then
            -- pid 是数字属性
            os.execute("kill -9 " .. system_obj.pid .. " 2>/dev/null")
            M._handle_generation_error(generation_id, "HTTP请求超时（" .. (timeout_ms/1000) .. "秒）", callbacks)
          end
        elseif type(system_obj) == "number" then
          -- 如果是进程ID，使用系统命令终止
          os.execute("kill -9 " .. system_obj .. " 2>/dev/null")
          M._handle_generation_error(generation_id, "HTTP请求超时（" .. (timeout_ms/1000) .. "秒）", callbacks)
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
      args = {"-c", cmd_str},
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
          M._handle_generation_error(generation_id, "HTTP请求超时（" .. (timeout_ms/1000) .. "秒）", callbacks)
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
  
  local json = require("NeoAI.utils.json")
  
  -- 检查响应文本是否有效
  if not response_text or response_text == "" then
    local error_msg = "API响应为空"
    M._handle_generation_error(generation_id, error_msg, callbacks)
    return
  end
  
  -- 解析响应
  local success, response_data = pcall(json.decode, response_text)
  if not success then
    local error_msg = "API响应JSON解析失败: " .. tostring(response_data)
    M._handle_generation_error(generation_id, error_msg, callbacks)
    return
  end

  if not response_data or not response_data.choices or #response_data.choices == 0 then
    local error_msg = "API响应格式错误"
    M._handle_generation_error(generation_id, error_msg, callbacks)
    return
  end

  local response = response_data.choices[1].message.content

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

  return response
end

--- 处理流式数据块
--- @param chunk string 数据块
--- @param generation_id string 生成ID
function M._process_stream_chunk(chunk, generation_id)
  if not chunk or chunk == "" then
    return
  end

  -- 使用流处理器处理数据块
  if stream_processor then
    stream_processor.process_chunk(chunk)
  end

  -- 触发数据块事件
  if state.event_bus then
    state.event_bus.emit("stream_chunk", generation_id, chunk)
  end
end

--- 异步流式响应（内部使用）
--- @param generation_id string 生成ID
--- @param messages table 消息列表
--- @param options table 选项
--- @param stream_handler function 流式处理器
function M._stream_response_async(generation_id, messages, options, stream_handler)
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
  local json = require("cjson")

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

            -- 将数据块传递给流处理器
            if stream_handler then
              stream_handler(chunk)
            end

            -- 处理流式数据
            M._process_stream_chunk(chunk, generation_id)

            -- 尝试从SSE格式中提取内容
            if chunk:match("^data: ") then
              local json_str = chunk:match("^data: (.+)$")
              if json_str and json_str ~= "[DONE]" then
                local ok, data_chunk = pcall(json.decode, json_str)
                if ok and data_chunk and data_chunk.choices and #data_chunk.choices > 0 then
                  local delta = data_chunk.choices[1].delta
                  if delta and delta.content then
                    full_response = full_response .. delta.content
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
        M._handle_generation_error(generation_id, error_msg)
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

  -- 模拟流式响应
  local words = {}
  for word in full_response:gmatch("%S+") do
    table.insert(words, word)
  end

  for i, word in ipairs(words) do
    if not state.is_generating then
      break
    end
    stream_handler(word .. " ")
    vim.wait(50) -- 模拟延迟
  end

  -- 处理工具调用（流式模式下）
  if options.tools and #options.tools > 0 then
    local tool_result = tool_orchestrator.execute_tool_loop(messages)
    if tool_result then
      stream_handler(tool_result)
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

return M

