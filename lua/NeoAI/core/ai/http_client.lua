-- HTTP 客户端模块
-- 负责发送 HTTP 请求到 AI API 服务，支持流式和非流式请求
local M = {}

local logger = require("NeoAI.utils.logger")
local json = require("NeoAI.utils.json")

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

  if not api_key or api_key == "" then
    return nil, "API key not configured. Set DEEPSEEK_API_KEY environment variable or configure ai.api_key"
  end

  if not base_url or base_url == "" then
    return nil, "API base URL not configured"
  end

  -- 构建 curl 命令
  local request_body = json.encode(request)
  local temp_file = vim.fn.tempname()

  local curl_args = {
    "-s",
    "-X", "POST",
    base_url,
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. api_key,
    "-d", request_body,
    "--connect-timeout", tostring(math.floor(timeout / 1000)),
    "--max-time", tostring(math.floor(timeout / 1000)),
    "-o", temp_file,
  }

  -- 记录请求信息
  logger.debug(string.format(
    "Sending request to %s (generation=%s, model=%s, stream=%s)",
    base_url, generation_id, request.model or "unknown", tostring(request.stream)
  ))

  -- 执行 curl 命令
  local cmd = "curl " .. table.concat(curl_args, " ")
  local ok, exit_code, stdout, stderr = M._run_command(cmd)

  if not ok or exit_code ~= 0 then
    -- 清理临时文件
    pcall(vim.fn.delete, temp_file)
    local err_msg = stderr or "curl command failed with exit code: " .. tostring(exit_code)
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

  return response, nil
end

--- 发送流式请求到 AI API
--- @param params table 请求参数
--- @param on_chunk function 数据块回调函数
--- @param on_complete function 完成回调函数
--- @param on_error function 错误回调函数
--- @return string|nil request_id 请求ID，可用于取消
function M.send_stream_request(params, on_chunk, on_complete, on_error)
  if not state.initialized then
    if on_error then on_error("HTTP client not initialized") end
    return nil
  end

  local request = params.request
  local generation_id = params.generation_id
  local base_url = params.base_url or state.config.base_url
  local api_key = params.api_key or state.config.api_key
  local timeout = params.timeout or state.config.timeout or 60000

  if not api_key or api_key == "" then
    if on_error then on_error("API key not configured") end
    return nil
  end

  if not base_url or base_url == "" then
    if on_error then on_error("API base URL not configured") end
    return nil
  end

  -- 确保请求启用流式
  request.stream = true

  local request_body = json.encode(request)
  local temp_file = vim.fn.tempname()
  state.request_counter = state.request_counter + 1
  local request_id = "req_" .. tostring(state.request_counter) .. "_" .. tostring(os.time())

  -- 存储请求信息以便取消
  state.active_requests[request_id] = {
    generation_id = generation_id,
    temp_file = temp_file,
    cancelled = false,
  }

  logger.debug(string.format(
    "Sending stream request to %s (generation=%s, request_id=%s)",
    base_url, generation_id, request_id
  ))

  -- 使用 vim.fn.jobstart 或 vim.system 进行异步请求
  -- 优先使用 vim.system (Neovim 0.10+)
  local job_id

  -- 使用 vim.schedule 包装回调，避免在 fast event context 中触发事件
  local function safe_on_chunk(data)
    if on_chunk then
      vim.schedule(function()
        on_chunk(data)
      end)
    end
  end

  local function safe_on_complete()
    if on_complete then
      vim.schedule(function()
        on_complete()
      end)
    end
  end

  local function safe_on_error(err_msg)
    if on_error then
      vim.schedule(function()
        on_error(err_msg)
      end)
    end
  end

  local function handle_stdout_line(line)
    if state.active_requests[request_id] and state.active_requests[request_id].cancelled then
      return
    end

    if line and line ~= "" then
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
          safe_on_chunk(data)
        end
      end
    end
  end

  local function handle_complete()
    if state.active_requests[request_id] then
      state.active_requests[request_id] = nil
    end

    safe_on_complete()
  end

  local function handle_error(err_msg)
    if state.active_requests[request_id] then
      state.active_requests[request_id] = nil
    end

    logger.error(string.format("Stream request error (generation=%s): %s", generation_id, err_msg))
    safe_on_error(err_msg)
  end

  -- 构建 curl 参数
  local args = {
    "-sN",  -- -s: silent, -N: no-buffer (streaming)
    "-X", "POST",
    base_url,
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. api_key,
    "-d", request_body,
    "--connect-timeout", tostring(math.floor(timeout / 1000)),
    "--max-time", tostring(math.floor(timeout / 1000)),
  }

  -- 使用 vim.fn.jobstart 进行异步流式请求
  -- vim.system 的 stdout:read 回调在 Neovim 中可能不实时触发流式数据
  -- vim.fn.jobstart 的 on_stdout 回调能可靠地处理流式 stdout 行
  local job_opts = {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          handle_stdout_line(line)
        end
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
      elseif not state.active_requests[request_id] or not state.active_requests[request_id].cancelled then
        handle_error("Process exited with code: " .. tostring(exit_code))
      end
    end,
  }

  local job_id = vim.fn.jobstart({"curl", unpack(args)}, job_opts)
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
    if not file then return nil end
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
