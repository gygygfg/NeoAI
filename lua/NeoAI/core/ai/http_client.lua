-- HTTP 客户端模块
-- 负责发送 HTTP 请求到 AI API 服务，支持流式和非流式请求
-- 支持多种 API 格式：openai、anthropic、google 等
local M = {}

local logger = require("NeoAI.utils.logger")
local json = require("NeoAI.utils.json")
local request_adapter = require("NeoAI.core.ai.request_adapter")

-- 模块状态
local state = {
  initialized = false,
  config = {},
  active_requests = {}, -- 活跃的请求，用于取消
  request_counter = 0,
}

--- 初始化 HTTP 客户端
--- @param options table 配置选项
function M.initialize(options)
  if state.initialized then
    return M
  end

  state.config = options.config or {}
  state.initialized = true

  logger.info("HTTP client initialized")
  return M
end

--- 发送非流式请求到 AI API
--- @param params table 请求参数
--- @return table|nil, string|nil 响应内容或错误信息
function M.send_request(params)
  if not state.initialized then
    return nil, "HTTP client not initialized"
  end

  local request = params.request
  local generation_id = params.generation_id
  local base_url = params.base_url or state.config.base_url
  local api_key = params.api_key or state.config.api_key
  local timeout = params.timeout or state.config.timeout or 60000
  local api_type = params.api_type or "openai"
  local provider_config = params.provider_config or {}

  if not api_key or api_key == "" then
    return nil, "API key not configured. Set DEEPSEEK_API_KEY environment variable or configure ai.api_key"
  end

  if not base_url or base_url == "" then
    return nil, "API base URL not configured"
  end

  -- 使用适配器转换请求体
  local transformed_request = request_adapter.transform_request(request, api_type, provider_config)
  local request_body = json.encode(transformed_request)
  local temp_file = vim.fn.tempname()

  -- 调试：打印工具信息
  -- if request.tools and #request.tools > 0 then
  --   local tool_names = {}
  --   for _, t in ipairs(request.tools) do
  --     if t["function"] then
  --       table.insert(tool_names, t["function"].name)
  --     end
  --   end
  --   print("[http_client] 非流式请求包含 " .. #request.tools .. " 个工具: " .. table.concat(tool_names, ", "))
  -- else
  --   print("[http_client] 非流式请求不包含工具定义")
  -- end

  -- 使用适配器获取请求头
  local headers = request_adapter.get_headers(api_key, api_type)

  -- 构建 curl 命令
  local curl_args = {
    "-s",
    "-X",
    "POST",
    base_url,
    "-H",
    "Content-Type: application/json",
  }

  -- 添加 API 特定的请求头
  for header_name, header_value in pairs(headers) do
    if header_name ~= "Content-Type" then
      table.insert(curl_args, "-H")
      table.insert(curl_args, header_name .. ": " .. header_value)
    end
  end

  vim.list_extend(curl_args, {
    "-d",
    request_body,
    "--connect-timeout",
    tostring(math.floor(timeout / 1000)),
    "--max-time",
    tostring(math.floor(timeout / 1000)),
    "-o",
    temp_file,
  })

  -- 记录请求信息
  logger.debug(
    string.format(
      "Sending request to %s (generation=%s, model=%s, stream=%s)",
      base_url,
      generation_id,
      request.model or "unknown",
      tostring(request.stream)
    )
  )

  -- 调试：打印工具信息
  -- if request.tools and #request.tools > 0 then
  --   local tool_names = {}
  --   for _, t in ipairs(request.tools) do
  --     if t["function"] then
  --       table.insert(tool_names, t["function"].name)
  --     end
  --   end
  --   print("[http_client] 流式请求包含 " .. #request.tools .. " 个工具: " .. table.concat(tool_names, ", "))
  -- else
  --   print("[http_client] 流式请求不包含工具定义")
  -- end

  -- 执行 curl 命令（使用列表形式避免 shell 转义问题）
  local curl_cmd = vim.list_extend({ "curl" }, curl_args)
  local ok, result = pcall(vim.fn.system, curl_cmd)
  local exit_code = vim.v.shell_error

  if not ok or exit_code ~= 0 then
    -- 清理临时文件
    pcall(vim.fn.delete, temp_file)
    local err_msg = "curl command failed with exit code: " .. tostring(exit_code)
    if not ok then
      err_msg = tostring(result)
    end
    logger.error(string.format("HTTP request failed (generation=%s): %s", generation_id, err_msg))
    return nil, err_msg
  end

  -- 读取响应
  local response_content = M._read_file(temp_file)
  pcall(vim.fn.delete, temp_file)

  if not response_content or response_content == "" then
    return nil, "Empty response from API"
  end

  -- 解析 JSON 响应
  local ok, response = pcall(json.decode, response_content)
  if not ok then
    logger.error(string.format("Failed to parse API response JSON (generation=%s)", generation_id))
    return nil, "Failed to parse API response: " .. tostring(response)
  end

  -- 检查 API 错误
  if response.error then
    local err_msg = response.error.message or json.encode(response.error)
    logger.error(string.format("API error (generation=%s): %s", generation_id, err_msg))
    return nil, err_msg
  end

  -- 使用适配器转换响应为统一格式
  local unified_response = request_adapter.transform_response(response, api_type)

  return unified_response, nil
end

--- 发送流式请求到 AI API
--- @param params table 请求参数
--- @param on_chunk function 数据块回调函数
--- @param on_complete function 完成回调函数
--- @param on_error function 错误回调函数
--- @return string|nil request_id 请求ID，可用于取消
function M.send_stream_request(params, on_chunk, on_complete, on_error)
  if not state.initialized then
    if on_error then
      on_error("HTTP client not initialized")
    end
    return nil
  end

  local request = params.request
  local generation_id = params.generation_id
  local base_url = params.base_url or state.config.base_url
  local api_key = params.api_key or state.config.api_key
  local timeout = params.timeout or state.config.timeout or 60000
  local api_type = params.api_type or "openai"
  local provider_config = params.provider_config or {}

  if not api_key or api_key == "" then
    if on_error then
      on_error("API key not configured")
    end
    return nil
  end

  if not base_url or base_url == "" then
    if on_error then
      on_error("API base URL not configured")
    end
    return nil
  end

  -- 确保请求启用流式
  request.stream = true

  -- 使用适配器转换请求体
  local transformed_request = request_adapter.transform_request(request, api_type, provider_config)
  local request_body = json.encode(transformed_request)
  local temp_file = vim.fn.tempname()
  state.request_counter = state.request_counter + 1
  local request_id = "req_" .. tostring(state.request_counter) .. "_" .. tostring(os.time())

  -- 存储请求信息以便取消
  state.active_requests[request_id] = {
    generation_id = generation_id,
    temp_file = temp_file,
    cancelled = false,
    has_error = false, -- API 错误标志
    buffer = "", -- SSE 行缓冲区，处理跨块的行
  }

  logger.debug(
    string.format("Sending stream request to %s (generation=%s, request_id=%s)", base_url, generation_id, request_id)
  )

  -- jobstart 的 on_stdout/on_stderr/on_exit 回调在 Neovim 主事件循环中运行
  -- 但 vim.api.nvim_exec_autocmds 不能在 jobstart 回调中直接调用
  -- 需要使用 vim.schedule 将事件触发推迟到主循环的下一个迭代

  -- 处理一行 SSE 数据
  local function process_sse_line(line)
    if line == "" then
      return
    end

    -- 处理 SSE 数据行
    if line:match("^data: ") then
      local data_str = line:gsub("^data: ", "")

      -- 检查是否为结束标记
      if data_str == "[DONE]" then
        return
      end

      -- 解析 JSON
      local ok, data = pcall(json.decode, data_str)
      if ok and data then
        -- 检查 API 错误
        if data.error then
          local err_msg = data.error.message or json.encode(data.error)
          -- 设置错误标志，防止 handle_complete 调用 on_complete
          local req = state.active_requests[request_id]
          if req then
            req.has_error = true
          end
          if on_error then
            on_error("API error: " .. err_msg)
          end
          return
        end
        -- 调试：检查工具调用
        -- if data.choices and data.choices[1] then
        --   local choice = data.choices[1]
        --   if choice.delta and choice.delta.tool_calls then
        --     print("[http_client] SSE 数据块包含 delta.tool_calls: " .. #choice.delta.tool_calls .. " 个")
        --   end
        --   if choice.message and choice.message.tool_calls then
        --     print("[http_client] SSE 数据块包含 message.tool_calls: " .. #choice.message.tool_calls .. " 个")
        --   end
        --   if choice.finish_reason then
        --     print("[http_client] SSE 数据块 finish_reason: " .. choice.finish_reason)
        --   end
        -- end
        -- 使用适配器转换流式响应块为统一格式
        local unified_data = request_adapter.transform_response(data, api_type)
        if on_chunk then
          -- 直接调用 on_chunk，on_chunk 内部会使用 vim.schedule 处理 nvim_exec_autocmds
          -- 避免在 process_sse_line 中嵌套 vim.schedule，确保数据块按顺序处理
          on_chunk(unified_data)
        end
      end
    elseif api_type == "anthropic" then
      -- Anthropic 流式格式：event: + data: 行
      -- 尝试解析纯 JSON 行（兼容处理）
      local ok, data = pcall(json.decode, line)
      if ok and data then
        -- 检查 API 错误
        if data.error then
          local err_msg = data.error.message or json.encode(data.error)
          local req = state.active_requests[request_id]
          if req then
            req.has_error = true
          end
          if on_error then
            on_error("API error: " .. err_msg)
          end
          return
        end
        local unified_data = request_adapter.transform_response(data, api_type)
        if on_chunk then
          on_chunk(unified_data)
        end
      end
    else
      -- 非 SSE 格式行：尝试解析为 JSON（可能是 API 错误响应）
      local ok, data = pcall(json.decode, line)
      if ok and data and data.error then
        local err_msg = data.error.message or json.encode(data.error)
        local req = state.active_requests[request_id]
        if req then
          req.has_error = true
        end
        if on_error then
          on_error("API error: " .. err_msg)
        end
      end
    end
  end

  -- 处理从 jobstart 收到的 stdout 数据块
  -- jobstart 的 on_stdout 回调传入的 data 是按 \n 分割的数组
  -- 如果数据以 \n 结尾，最后一个元素是空字符串 ""
  -- 如果数据不以 \n 结尾，最后一个元素是不完整的行
  -- 需要维护一个缓冲区来拼接跨块的完整行
  local function handle_stdout_data(data_lines)
    local req = state.active_requests[request_id]
    if not req or req.cancelled then
      return
    end

    local n = #data_lines
    if n == 0 then
      return
    end

    -- 判断最后一行是否为空（表示数据以 \n 结尾）
    local ends_with_newline = (data_lines[n] == "")

    -- 确定实际的行数（排除末尾的空字符串）
    local actual_line_count = ends_with_newline and (n - 1) or n

    for i = 1, actual_line_count do
      local line = data_lines[i]

      -- 如果是第一行，拼接缓冲区中上一块的不完整行
      if i == 1 and req.buffer ~= "" then
        line = req.buffer .. (line or "")
        req.buffer = ""
      end

      -- 处理完整的行
      process_sse_line(line or "")
    end

    -- 如果数据不以 \n 结尾，最后一部分是不完整的行，存入缓冲区
    if not ends_with_newline and n >= 1 then
      local last_part = data_lines[n]
      if last_part ~= nil and last_part ~= "" then
        req.buffer = (req.buffer or "") .. last_part
      end
    end
  end

  local function handle_complete()
    -- 处理缓冲区中剩余的数据
    local req = state.active_requests[request_id]
    if req and req.buffer ~= "" then
      process_sse_line(req.buffer)
    end

    -- 重新获取 req（process_sse_line 可能已经修改了它）
    req = state.active_requests[request_id]
    local has_error = req and req.has_error

    if req then
      state.active_requests[request_id] = nil
    end

    -- 如果有 API 错误，不调用 on_complete，避免空响应
    if has_error then
      return
    end

    -- on_complete 内部会使用 vim.schedule 触发事件，所以这里直接调用
    -- 避免双重 vim.schedule 嵌套导致延迟
    if on_complete then
      on_complete()
    end
  end

  local function handle_error(err_msg)
    local req = state.active_requests[request_id]
    if req then
      -- 如果请求已被取消，忽略错误
      if req.cancelled then
        state.active_requests[request_id] = nil
        return
      end
      state.active_requests[request_id] = nil
    else
      -- 请求已不存在（已被 cancel_request 移除），说明已被取消，忽略错误
      return
    end

    logger.error(string.format("Stream request error (generation=%s): %s", generation_id, err_msg))
    -- on_error 内部会使用 vim.schedule 触发事件，所以这里直接调用
    if on_error then
      on_error(err_msg)
    end
  end

  -- 使用适配器获取请求头
  local headers = request_adapter.get_headers(api_key, api_type)

  -- 构建 curl 参数
  local args = {
    "-sN", -- -s: silent, -N: no-buffer (streaming)
    "-X",
    "POST",
    base_url,
    "-H",
    "Content-Type: application/json",
  }

  -- 添加 API 特定的请求头
  for header_name, header_value in pairs(headers) do
    if header_name ~= "Content-Type" then
      table.insert(args, "-H")
      table.insert(args, header_name .. ": " .. header_value)
    end
  end

  vim.list_extend(args, {
    "-d",
    request_body,
    "--connect-timeout",
    tostring(math.floor(timeout / 1000)),
    "--max-time",
    tostring(math.floor(timeout / 1000)),
  })

  -- 使用 vim.fn.jobstart 进行异步流式请求
  -- vim.system 的 stdout:read 回调在 Neovim 中可能不实时触发流式数据
  -- vim.fn.jobstart 的 on_stdout 回调能可靠地处理流式 stdout 行
  local job_opts = {
    on_stdout = function(_, data)
      if data and #data > 0 then
        handle_stdout_data(data)
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        local err_msg = table.concat(data, "\n")
        if err_msg and err_msg ~= "" then
          handle_error(err_msg)
        end
      end
    end,
    on_exit = function(_, exit_code, _)
      if exit_code == 0 then
        handle_complete()
      else
        -- 检查请求是否已被取消（cancel_request 会从 active_requests 中移除）
        local req = state.active_requests[request_id]
        if not req then
          -- 请求已被取消或已不存在，忽略退出码错误
          return
        end
        if not req.cancelled then
          handle_error("Process exited with code: " .. tostring(exit_code))
        end
      end
    end,
  }

  local job_id = vim.fn.jobstart({ "curl", unpack(args) }, job_opts)
  state.active_requests[request_id].job_id = job_id

  return request_id
end

--- 取消请求
--- @param request_id string 请求ID
function M.cancel_request(request_id)
  if not request_id or not state.active_requests[request_id] then
    return
  end

  local req = state.active_requests[request_id]
  req.cancelled = true

  -- 尝试取消 job
  if req.job_id then
    pcall(vim.fn.jobstop, req.job_id)
  end

  state.active_requests[request_id] = nil
  logger.debug(string.format("Request cancelled: %s", request_id))
end

--- 取消所有活跃请求
function M.cancel_all_requests()
  for request_id, _ in pairs(state.active_requests) do
    M.cancel_request(request_id)
  end
  state.active_requests = {}
end

--- 获取模块状态
--- @return table 状态信息
function M.get_state()
  return {
    initialized = state.initialized,
    active_requests_count = vim.tbl_count(state.active_requests),
    config = {
      base_url = state.config.base_url,
      timeout = state.config.timeout,
      has_api_key = state.config.api_key and #state.config.api_key > 0,
    },
  }
end

--- 关闭 HTTP 客户端
function M.shutdown()
  M.cancel_all_requests()
  state.initialized = false
  logger.info("HTTP client shutdown")
end

-- ========== 内部辅助函数 ==========

--- 运行 shell 命令（内部函数）
--- @param cmd string 命令
--- @return boolean, number, string, string 成功标志, 退出码, stdout, stderr
function M._run_command(cmd)
  local ok, result = pcall(vim.fn.system, cmd)
  if not ok then
    return false, -1, "", tostring(result)
  end

  -- vim.fn.system 返回 stdout，退出码在 vim.v.shell_error 中
  local exit_code = vim.v.shell_error
  return exit_code == 0, exit_code, result, ""
end

--- 读取文件内容（内部函数）
--- @param filepath string 文件路径
--- @return string|nil 文件内容
function M._read_file(filepath)
  local ok, content = pcall(function()
    local file = io.open(filepath, "r")
    if not file then
      return nil
    end
    local data = file:read("*a")
    file:close()
    return data
  end)

  if ok then
    return content
  end
  return nil
end

return M
