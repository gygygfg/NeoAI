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
        -- send_request 是非流式请求，没有 on_complete 回调
        -- 直接返回 nil 表示去重跳过
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

  -- 支持通过 params.tool_choice 覆盖 request 中的 tool_choice
  -- 注意：params.tool_choice 为 nil 时不覆盖（保持 request 中的值）
  -- 如需清除 tool_choice，设置 params._clear_tool_choice = true
  if params._clear_tool_choice then
    request.tool_choice = nil
  elseif params.tool_choice ~= nil then
    request.tool_choice = params.tool_choice
  end

  -- 支持禁用思考模式：清除 extra_body 中的 thinking 字段
  -- 用于 send_input 等简单工具调用，不需要推理过程
  -- 注意：不清除 tool_choice，因为 send_input 需要强制工具调用
  if params._disable_reasoning then
    if request.extra_body then
      request.extra_body.thinking = nil
      request.extra_body.reasoning_effort = nil
      -- 如果 extra_body 为空则删除
      if not next(request.extra_body) then
        request.extra_body = nil
      end
    end
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
    local err_msg = response.error.message or json.encode(response.error)
    logger.debug("[http_client] API 错误: " .. err_msg)

    -- 自动修复：如果错误包含 tool_choice 不支持，清除 tool_choice 后重试
    if err_msg and err_msg:find("does not support this tool_choice") then
      request.tool_choice = nil
      -- 重新构建请求体并重试
      local retry_transformed = request_adapter.transform_request(request, api_type, provider_config)
      local retry_body = json.encode(retry_transformed)
      local retry_temp = vim.fn.tempname()
      local retry_args = { "-s", "-X", "POST", base_url, "-H", "Content-Type: application/json" }
      for k, v in pairs(headers) do
        if k ~= "Content-Type" then
          table.insert(retry_args, "-H"); table.insert(retry_args, k .. ": " .. v)
        end
      end
      vim.list_extend(retry_args, { "-d", retry_body, "--connect-timeout", tostring(math.floor(timeout / 1000)), "--max-time", "0", "-o", retry_temp })
      local retry_cmd = vim.list_extend({ "curl" }, retry_args)
      local retry_ok, retry_result = pcall(vim.fn.system, retry_cmd)
      local retry_exit = vim.v.shell_error
      if not retry_ok or retry_exit ~= 0 then
        pcall(vim.fn.delete, retry_temp)
        return nil, "curl failed on retry: " .. (retry_ok and "exit " .. retry_exit or tostring(retry_result))
      end
      local retry_content = M._read_file(retry_temp)
      pcall(vim.fn.delete, retry_temp)
      if retry_content and retry_content ~= "" then
        local retry_ok2, retry_response = pcall(json.decode, retry_content)
        if retry_ok2 and retry_response then
          if retry_response.error then
            return nil, retry_response.error.message or json.encode(retry_response.error)
          end
          return request_adapter.transform_response(retry_response, api_type), nil
        end
      end
      return nil, "retry failed"
    end

    return nil, err_msg
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

  -- 支持通过 params.tool_choice 覆盖 request 中的 tool_choice
  -- 注意：params.tool_choice 为 nil 时不覆盖（保持 request 中的值）
  -- 如需清除 tool_choice，设置 params._clear_tool_choice = true
  if params._clear_tool_choice then
    request.tool_choice = nil
  elseif params.tool_choice ~= nil then
    request.tool_choice = params.tool_choice
  end

  -- 支持禁用思考模式
  -- 注意：不清除 tool_choice，因为 send_input 需要强制工具调用
  if params._disable_reasoning then
    if request.extra_body then
      request.extra_body.thinking = nil
      request.extra_body.reasoning_effort = nil
      if not next(request.extra_body) then
        request.extra_body = nil
      end
    end
  end

  request.stream = true
  local transformed = request_adapter.transform_request(request, api_type, provider_config)
  local request_body = json.encode(transformed)
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

--- 异步非流式请求（使用 vim.fn.jobstart，不阻塞主线程）
--- 用于 execute_single_tool_request 等需要非阻塞的场景
--- @param params table 与 send_request 相同的参数
--- @param on_complete function(response, err) 回调函数
--- @return string|nil request_id
function M.send_request_async(params, on_complete)
  if not state.initialized then
    if on_complete then on_complete(nil, "HTTP client not initialized") end
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
    if on_complete then on_complete(nil, "API key not configured") end
    return nil
  end
  if not base_url or base_url == "" then
    if on_complete then on_complete(nil, "API base URL not configured") end
    return nil
  end

  -- 支持通过 params.tool_choice 覆盖
  if params._clear_tool_choice then
    request.tool_choice = nil
  elseif params.tool_choice ~= nil then
    request.tool_choice = params.tool_choice
  end

  -- 支持禁用思考模式
  if params._disable_reasoning then
    if request.extra_body then
      request.extra_body.thinking = nil
      request.extra_body.reasoning_effort = nil
      if not next(request.extra_body) then
        request.extra_body = nil
      end
    end
    request.tool_choice = nil
  end

  local transformed = request_adapter.transform_request(request, api_type, provider_config)
  local request_body = json.encode(transformed)
  logger.debug("[http_client] 异步非流式请求: " .. base_url .. " | body=" .. request_body:sub(1, 2000) .. (request_body:len() > 2000 and "...[truncated]" or ""))

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

  state.request_counter = state.request_counter + 1
  local request_id = "req_async_" .. state.request_counter .. "_" .. os.time()

  state.active_requests[request_id] = {
    generation_id = generation_id,
    temp_file = temp_file,
    cancelled = false,
    has_error = false,
  }

  local job_id = vim.fn.jobstart({ "curl", unpack(curl_args) }, {
    on_stderr = function(_, data)
      if data and #data > 0 then
        local err = table.concat(data, "\n")
        if err ~= "" then
          logger.debug("[http_client] 异步请求 stderr: " .. err)
        end
      end
    end,
    on_exit = function(_, exit_code, _)
      local req = state.active_requests[request_id]
      if not req then
        -- 请求已被取消
        pcall(vim.fn.delete, temp_file)
        return
      end
      if req.cancelled then
        state.active_requests[request_id] = nil
        pcall(vim.fn.delete, temp_file)
        return
      end

      state.active_requests[request_id] = nil

      if exit_code ~= 0 then
        pcall(vim.fn.delete, temp_file)
        if on_complete then
          vim.schedule(function()
            on_complete(nil, "curl exit: " .. exit_code)
          end)
        end
        return
      end

      -- 读取临时文件
      local content = M._read_file(temp_file)
      pcall(vim.fn.delete, temp_file)

      if not content or content == "" then
        if on_complete then
          vim.schedule(function()
            on_complete(nil, "Empty response")
          end)
        end
        return
      end

      logger.debug("[http_client] 异步非流式响应: " .. base_url .. " | body=" .. content:sub(1, 2000) .. (content:len() > 2000 and "...[truncated]" or ""))

      local ok, response = pcall(json.decode, content)
      if not ok then
        if on_complete then
          vim.schedule(function()
            on_complete(nil, "JSON parse failed")
          end)
        end
        return
      end

      if response.error then
        local err_msg = response.error.message or json.encode(response.error)
        if on_complete then
          vim.schedule(function()
            on_complete(nil, err_msg)
          end)
        end
        return
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

      if on_complete then
        vim.schedule(function()
          on_complete(request_adapter.transform_response(response, api_type), nil)
        end)
      end
    end,
  })

  if state.active_requests[request_id] then
    state.active_requests[request_id].job_id = job_id
  end

  return request_id
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
