-- HTTP 客户端模块
-- 负责发送 HTTP 请求到 AI API 服务，支持流式和非流式请求
local M = {}

local logger = require("NeoAI.utils.logger")
local json = require("NeoAI.utils.json")
local request_adapter = require("NeoAI.core.ai.request_adapter")

local state = {
  initialized = false,
  config = {},
  active_requests = {},
  request_counter = 0,

  -- 请求去重缓存：key = generation_id, value = { body_hash, timestamp }
  -- 防止同一 generation_id 的相同请求体被重复发送
  _request_dedup = {},
  _dedup_ttl_ms = 3000, -- 3 秒内相同的请求视为重复
}

function M.initialize(options)
  if state.initialized then return M end
  state.config = options.config or {}
  state.initialized = true
  return M
end

--- 发送非流式请求
function M.send_request(params)
  if not state.initialized then return nil, "HTTP client not initialized" end

  local request = params.request
  local generation_id = params.generation_id
  local base_url = params.base_url or state.config.base_url
  local api_key = params.api_key or state.config.api_key
  local timeout = params.timeout or state.config.timeout or 60000
  local api_type = params.api_type or "openai"
  local provider_config = params.provider_config or {}

  -- 请求去重：检查同一 generation_id 的相同请求体是否已被发送
  if generation_id then
    local now = os.time() * 1000
    local dedup_key = generation_id .. "_" .. api_type
    local cached = state._request_dedup[dedup_key]
    if cached then
      -- 计算当前请求体的哈希
      local body_for_hash = vim.json.encode(request or {})
      local current_hash = vim.fn.sha256(body_for_hash)
      if cached.hash == current_hash and (now - cached.timestamp) < state._dedup_ttl_ms then
        logger.debug("[http_client] 请求去重: 跳过重复的流式请求, generation_id=" .. tostring(generation_id))
        if on_complete then on_complete() end
        return nil
      end
    end
  end

  if not api_key or api_key == "" then
    return nil, "API key not configured"
  end
  if not base_url or base_url == "" then
    return nil, "API base URL not configured"
  end

  local transformed = request_adapter.transform_request(request, api_type, provider_config)
  local request_body = json.encode(transformed)
  logger.debug("[http_client] 非流式请求: " .. base_url .. " | body=" .. request_body:sub(1, 2000) .. (request_body:len() > 2000 and "...[truncated]" or ""))
  local temp_file = vim.fn.tempname()
  local headers = request_adapter.get_headers(api_key, api_type)

  local curl_args = { "-s", "-X", "POST", base_url, "-H", "Content-Type: application/json" }
  for k, v in pairs(headers) do
    if k ~= "Content-Type" then
      table.insert(curl_args, "-H"); table.insert(curl_args, k .. ": " .. v)
    end
  end
  vim.list_extend(curl_args, {
    "-d", request_body,
    "--connect-timeout", tostring(math.floor(timeout / 1000)),
    "--max-time", "0", "-o", temp_file,
  })

  local cmd = vim.list_extend({ "curl" }, curl_args)
  local ok, result = pcall(vim.fn.system, cmd)
  local exit_code = vim.v.shell_error

  if not ok or exit_code ~= 0 then
    pcall(vim.fn.delete, temp_file)
    return nil, "curl failed: " .. (ok and "exit " .. exit_code or tostring(result))
  end

  local content = M._read_file(temp_file)
  pcall(vim.fn.delete, temp_file)
  if not content or content == "" then return nil, "Empty response" end

  logger.debug("[http_client] 非流式响应: " .. base_url .. " | body=" .. content:sub(1, 2000) .. (content:len() > 2000 and "...[truncated]" or ""))

  local ok, response = pcall(json.decode, content)
  if not ok then
    logger.debug("[http_client] JSON 解析失败: " .. (content:sub(1, 500)))
    return nil, "JSON parse failed"
  end
  if response.error then
    logger.debug("[http_client] API 错误: " .. (response.error.message or json.encode(response.error)))
    return nil, response.error.message or json.encode(response.error)
  end

  -- 更新去重缓存
  if generation_id then
    local dedup_key = generation_id .. "_" .. api_type .. "_nonstream"
    local body_for_hash = vim.json.encode(request or {})
    state._request_dedup[dedup_key] = {
      hash = vim.fn.sha256(body_for_hash),
      timestamp = os.time() * 1000,
    }
  end

  return request_adapter.transform_response(response, api_type), nil
end

--- 发送流式请求
function M.send_stream_request(params, on_chunk, on_complete, on_error)
  if not state.initialized then
    if on_error then on_error("HTTP client not initialized") end; return nil
  end

  local request = params.request
  local generation_id = params.generation_id
  local base_url = params.base_url or state.config.base_url
  local api_key = params.api_key or state.config.api_key
  local timeout = params.timeout or state.config.timeout or 60000
  local api_type = params.api_type or "openai"
  local provider_config = params.provider_config or {}

  if not api_key or api_key == "" then
    return nil, "API key not configured"
  end
  if not base_url or base_url == "" then
    return nil, "API base URL not configured"
  end

  -- 请求去重：检查同一 generation_id 的相同请求体是否已被发送
  if generation_id then
    local now = os.time() * 1000
    local dedup_key = generation_id .. "_" .. api_type .. "_stream"
    local cached = state._request_dedup[dedup_key]
    if cached then
      local body_for_hash = vim.json.encode(request or {})
      local current_hash = vim.fn.sha256(body_for_hash)
      if cached.hash == current_hash and (now - cached.timestamp) < state._dedup_ttl_ms then
        logger.debug("[http_client] 请求去重: 跳过重复的流式请求, generation_id=" .. tostring(generation_id))
        if on_complete then on_complete() end
        return nil
      end
    end
  end

  request.stream = true
  local transformed = request_adapter.transform_request(request, api_type, provider_config)
  local request_body = json.encode(transformed)
  logger.debug("[http_client] 流式请求: " .. base_url .. " | body=" .. request_body:sub(1, 2000) .. (request_body:len() > 2000 and "...[truncated]" or ""))
  -- 对短请求体（< 8KB）使用 --data-raw 避免临时文件 I/O
  local use_temp_file = #request_body > 8192
  local temp_file = use_temp_file and vim.fn.tempname() or nil
  state.request_counter = state.request_counter + 1
  local request_id = "req_" .. state.request_counter .. "_" .. os.time()

  state.active_requests[request_id] = {
    generation_id = generation_id, temp_file = temp_file,
    cancelled = false, has_error = false, buffer = "",
  }

  -- 更新去重缓存
  if generation_id then
    local dedup_key = generation_id .. "_" .. api_type .. "_stream"
    local body_for_hash = vim.json.encode(request or {})
    state._request_dedup[dedup_key] = {
      hash = vim.fn.sha256(body_for_hash),
      timestamp = os.time() * 1000,
    }
  end

  local function process_sse_line(line)
    if line == "" then return end
    local data_str = line:match("^data: (.*)")
    if data_str then
      if data_str == "[DONE]" then return end
      local ok, data = pcall(json.decode, data_str)
      if ok and data then
        logger.debug("[http_client] 流式数据块: " .. data_str:sub(1, 500) .. (data_str:len() > 500 and "...[truncated]" or ""))
        if data.error then
          local req = state.active_requests[request_id]
          if req then req.has_error = true end
          if on_error then on_error("API error: " .. (data.error.message or json.encode(data.error))) end
          return
        end
        local unified = request_adapter.transform_response(data, api_type)
        if on_chunk then on_chunk(unified) end
      end
    else
      local ok, data = pcall(json.decode, line)
      if ok and data and data.error then
        local req = state.active_requests[request_id]
        if req then req.has_error = true end
        if on_error then on_error("API error: " .. (data.error.message or json.encode(data.error))) end
      end
    end
  end

  local function handle_stdout(data_lines)
    local req = state.active_requests[request_id]
    if not req or req.cancelled then return end
    local n = #data_lines
    if n == 0 then return end
    local ends_with_newline = data_lines[n] == ""
    local count = ends_with_newline and n - 1 or n
    for i = 1, count do
      local line = data_lines[i]
      if i == 1 and req.buffer ~= "" then
        line = req.buffer .. (line or ""); req.buffer = ""
      end
      process_sse_line(line or "")
    end
    if not ends_with_newline and n >= 1 then
      local last = data_lines[n]
      if last ~= nil and last ~= "" then req.buffer = (req.buffer or "") .. last end
    end
  end

  local function handle_complete()
    local req = state.active_requests[request_id]
    if not req then
      -- 请求已被取消（cancel_request 已清理），不再触发回调
      logger.debug("[http_client] 流式请求完成但已被取消，跳过回调")
      return
    end
    if req.cancelled then
      state.active_requests[request_id] = nil
      return
    end
    if req.buffer ~= "" then process_sse_line(req.buffer) end
    local has_error = req and req.has_error
    if req then state.active_requests[request_id] = nil end
    logger.debug("[http_client] 流式请求完成: " .. base_url .. " | has_error=" .. tostring(has_error))
    if not has_error and on_complete then on_complete() end
  end

  local function handle_error(err_msg)
    local req = state.active_requests[request_id]
    if req then
      if req.cancelled then state.active_requests[request_id] = nil; return end
      state.active_requests[request_id] = nil
    else return end
    logger.debug("[http_client] 流式请求错误: " .. base_url .. " | error=" .. err_msg)
    if on_error then on_error(err_msg) end
  end

  local headers = request_adapter.get_headers(api_key, api_type)
  local args = { "-sN", "-X", "POST", base_url, "-H", "Content-Type: application/json" }
  for k, v in pairs(headers) do
    if k ~= "Content-Type" then table.insert(args, "-H"); table.insert(args, k .. ": " .. v) end
  end

  if use_temp_file then
    local ok, _ = pcall(function()
      local r = vim.fn.writefile({ request_body }, temp_file)
      if r == -1 then error("write failed") end
    end)
    if not ok then
      state.active_requests[request_id] = nil
      if on_error then on_error("Failed to write temp file") end; return nil
    end
    vim.list_extend(args, { "--data-binary", "@" .. temp_file })
  else
    -- 短请求体直接通过 --data-raw 传递，避免临时文件 I/O
    vim.list_extend(args, { "--data-raw", request_body })
  end

  vim.list_extend(args, {
    "--connect-timeout", tostring(math.floor(timeout / 1000)), "--max-time", "0",
  })

  local job_id = vim.fn.jobstart({ "curl", unpack(args) }, {
    on_stdout = function(_, data) if data and #data > 0 then handle_stdout(data) end end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        local err = table.concat(data, "\n")
        if err ~= "" then handle_error(err) end
      end
    end,
    on_exit = function(_, exit_code, _)
      if temp_file then pcall(vim.fn.delete, temp_file) end
      -- 检查请求是否已被取消（按 ESC 时），避免已取消的请求继续触发回调
      local req = state.active_requests[request_id]
      if req and req.cancelled then
        state.active_requests[request_id] = nil
        return
      end
      if exit_code == 0 then handle_complete()
      else
        if req and not req.cancelled then handle_error("exit: " .. exit_code) end
      end
    end,
  })
  if state.active_requests[request_id] then state.active_requests[request_id].job_id = job_id end
  return request_id
end

function M.cancel_request(request_id)
  local req = state.active_requests[request_id]
  if not req then return end
  req.cancelled = true
  if req.temp_file then pcall(vim.fn.delete, req.temp_file) end
  if req.job_id then pcall(vim.fn.jobstop, req.job_id) end
  state.active_requests[request_id] = nil
end

function M.cancel_all_requests()
  for id, _ in pairs(state.active_requests) do M.cancel_request(id) end
  state.active_requests = {}
  -- 清理去重缓存
  state._request_dedup = {}
end

function M.get_state()
  return { initialized = state.initialized, active_requests_count = vim.tbl_count(state.active_requests) }
end

function M.shutdown()
  M.cancel_all_requests(); state.initialized = false
end

function M._read_file(filepath)
  local ok, content = pcall(function()
    local f = io.open(filepath, "r"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
  end)
  return ok and content or nil
end

return M
