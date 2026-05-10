-- HTTP 客户端模块
-- 负责发送 HTTP 请求到 AI API 服务，支持流式和非流式请求

local M = {}

local logger = require("NeoAI.utils.logger")
local json = require("NeoAI.utils.json")
local request_adapter = require("NeoAI.core.ai.request_adapter")
local http_utils = require("NeoAI.utils.http_utils")
local state_manager = require("NeoAI.core.config.state")

local state = {
  initialized = false,
  config = {},
  active_requests = {},
  request_counter = 0,
}

-- 委托给 http_utils 的函数
M._sanitize_json_body = http_utils.sanitize_json_body
M._repair_orphan_tool_messages = http_utils.repair_orphan_tool_messages
M._read_file = http_utils.read_file
M._parse_response_tool_calls = http_utils.parse_response_tool_calls

--- 将请求体中所有 tool_calls 的 arguments 从 Lua table 编码为 JSON 字符串
--- 系统内部使用 Lua table 操作数据，发送给 API 前需要将 arguments 转为 JSON 字符串
--- @param body table 请求体（会被原地修改）
function M._encode_tool_call_arguments(body)
  if not body or type(body) ~= "table" then return end
  if not body.messages then return end
  for _, msg in ipairs(body.messages) do
    if msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        local func = tc["function"] or tc.func
        if func and func.arguments and type(func.arguments) == "table" then
          local ok, encoded = pcall(vim.json.encode, func.arguments)
          if ok then
            func.arguments = encoded
          end
        end
      end
    end
  end
end

function M.initialize(options)
  if state.initialized then
    return M
  end
  state.config = options.config or {}
  state.initialized = true
  return M
end

--- 发送非流式请求
function M.send_request(params)
  if not state.initialized then
    return nil, "HTTP client not initialized"
  end

  -- 优先从协程共享表读取参数
  local shared = state_manager.get_shared()
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or state.config.api_key
  local api_type = params.api_type or ai_preset.api_type or "openai"
  local provider_config = params.provider_config or ai_preset or {}

  -- 请求去重
  if generation_id and http_utils.check_dedup(generation_id, api_type, request) then
    return nil
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

  -- 防御性检查：如果指定了强制工具调用（tool_choice 为 function 类型），
  -- 自动禁用思考模式。DeepSeek 等 API 在思考模式下不支持强制工具调用。
  -- 注意：tool_choice 为 "auto" 或 "none" 时不处理，只处理 { type = "function", function = { name = "..." } }
  if request.tool_choice and type(request.tool_choice) == "table" and request.tool_choice.type == "function" then
    if request.extra_body and request.extra_body.thinking then
      -- logger.warn("[http_client] 检测到强制工具调用与思考模式冲突，自动禁用思考模式")
      request.extra_body.thinking = nil
      request.extra_body.reasoning_effort = nil
      if not next(request.extra_body) then
        request.extra_body = nil
      end
    end
  end

  -- 支持禁用思考模式：清除 extra_body 中的 thinking 字段
  -- 用于 send_input 等简单工具调用，不需要推理过程
  -- 注意：不清除 tool_choice，因为 send_input 需要强制工具调用
  if params._disable_reasoning then
    if request.extra_body then
      if request.extra_body.thinking then
        logger.debug("[http_client] 按调用方要求禁用思考模式")
      end
      request.extra_body.thinking = nil
      request.extra_body.reasoning_effort = nil
      -- 如果 extra_body 为空则删除
      if not next(request.extra_body) then
        request.extra_body = nil
      end
    end
  end

  -- 参数检查：验证 request 结构完整性
  -- 检查 messages 是否存在且不为空
  if not request.messages or #request.messages == 0 then
    logger.warn("[http_client] send_request: request.messages 为空或不存在")
  end
  -- 检查 model 是否设置
  if not request.model or request.model == "" then
    logger.warn("[http_client] send_request: request.model 未设置，将使用 API 默认模型")
  end
  -- 检查 tools 和 tool_choice 的一致性
  if request.tool_choice and request.tool_choice ~= "none" then
    if not request.tools or #request.tools == 0 then
      logger.warn("[http_client] send_request: 设置了 tool_choice 但未提供 tools 定义，API 可能报错")
    end
  end

  -- 防御性修复：将调用了工具列表中没有的工具的 tool 消息转为 user 消息
  -- 避免 API 报错 'tool message without matching tool_calls' 或工具名不匹配
  M._repair_orphan_tool_messages(request)

  local transformed = request_adapter.transform_request(request, api_type, provider_config)
  -- 将 tool_calls.arguments 从 Lua table 编码为 JSON 字符串（API 要求字符串格式）
  M._encode_tool_call_arguments(transformed)
  local request_body = json.encode(transformed)
  request_body = M._sanitize_json_body(request_body)
  -- 调试：打印请求体中的 model 字段
  local ok_body, decoded_body = pcall(json.decode, request_body)
  if ok_body and decoded_body and decoded_body.model then
    logger.debug(string.format(
      "[http_client] 非流式请求 model=%s",
      tostring(decoded_body.model)
    ))
  end
  logger.debug(
    "[http_client] 非流式请求: "
      .. base_url
      .. " | body="
      .. request_body:sub(1, 2000)
      .. (request_body:len() > 2000 and "...[truncated]" or "")
  )
  local temp_file = vim.fn.tempname()
  local headers = request_adapter.get_headers(api_key, api_type)

  local curl_args = { "-s", "-X", "POST", base_url, "-H", "Content-Type: application/json" }
  for k, v in pairs(headers) do
    if k ~= "Content-Type" then
      table.insert(curl_args, "-H")
      table.insert(curl_args, k .. ": " .. v)
    end
  end
  vim.list_extend(curl_args, {
    "-d",
    request_body,
    "-o",
    temp_file,
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
  if not content or content == "" then
    return nil, "Empty response"
  end

  logger.debug(
    "[http_client] 非流式响应: "
      .. base_url
      .. " | body="
      .. content:sub(1, 2000)
      .. (content:len() > 2000 and "...[truncated]" or "")
  )

  local ok, response = pcall(json.decode, content)
  if not ok then
    logger.debug("[http_client] JSON 解析失败: " .. (content:sub(1, 500)))
    return nil, "JSON parse failed"
  end
  -- 立即解析 tool_calls 中的 arguments 为 Lua table
  if type(response) == "table" then
    M._parse_response_tool_calls(response)
  end
  if response.error then
    local err_msg = response.error.message or json.encode(response.error)
    logger.debug("[http_client] API 错误: " .. err_msg)

    -- 自动修复：如果错误包含 tool_choice 不支持，清除 tool_choice 后重试
    if err_msg and err_msg:find("does not support this tool_choice") then
      request.tool_choice = nil
      -- 重新构建请求体并重试
      local retry_transformed = request_adapter.transform_request(request, api_type, provider_config)
      M._encode_tool_call_arguments(retry_transformed)
      local retry_body = json.encode(retry_transformed)
      retry_body = M._sanitize_json_body(retry_body)
      local retry_temp = vim.fn.tempname()
      local retry_args = { "-s", "-X", "POST", base_url, "-H", "Content-Type: application/json" }
      for k, v in pairs(headers) do
        if k ~= "Content-Type" then
          table.insert(retry_args, "-H")
          table.insert(retry_args, k .. ": " .. v)
        end
      end
      vim.list_extend(retry_args, {
        "-d",
        retry_body,
        "-o",
        retry_temp,
      })
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
          if type(retry_response) == "table" then
            M._parse_response_tool_calls(retry_response)
          end
          local retry_unified = request_adapter.transform_response(retry_response, api_type)
          return retry_unified, nil
        end
      end
      return nil, "retry failed"
    end

    return nil, err_msg
  end

  -- 更新去重缓存
  if generation_id then
    http_utils.update_dedup(generation_id, api_type .. "_nonstream", request)
  end

  local unified = request_adapter.transform_response(response, api_type)
  return unified, nil
end

--- 发送非流式请求（内部重试用，带 generation_id 保护）
function M.send_request_retry(params, on_complete)
  if not state.initialized then
    if on_complete then on_complete(nil, "HTTP client not initialized") end
    return nil
  end

  local shared = state_manager.get_shared()
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or state.config.api_key
  local api_type = params.api_type or ai_preset.api_type or "openai"
  local provider_config = params.provider_config or ai_preset or {}

  if not api_key or api_key == "" then
    if on_complete then on_complete(nil, "API key not configured") end
    return nil
  end
  if not base_url or base_url == "" then
    if on_complete then on_complete(nil, "API base URL not configured") end
    return nil
  end

  -- 参数检查
  if not request.messages or #request.messages == 0 then
    logger.warn("[http_client] send_request_retry: request.messages 为空或不存在")
  end
  if not request.model or request.model == "" then
    logger.warn("[http_client] send_request_retry: request.model 未设置")
  end

  -- 防御性修复
  M._repair_orphan_tool_messages(request)

  local transformed = request_adapter.transform_request(request, api_type, provider_config)
  M._encode_tool_call_arguments(transformed)
  local request_body = json.encode(transformed)
  request_body = M._sanitize_json_body(request_body)

  local temp_file = vim.fn.tempname()
  local headers = request_adapter.get_headers(api_key, api_type)

  local curl_args = { "-s", "-X", "POST", base_url, "-H", "Content-Type: application/json" }
  for k, v in pairs(headers) do
    if k ~= "Content-Type" then
      table.insert(curl_args, "-H")
      table.insert(curl_args, k .. ": " .. v)
    end
  end
  vim.list_extend(curl_args, {
    "-d", request_body,
    "-o", temp_file,
  })

  local cmd = vim.list_extend({ "curl" }, curl_args)
  local ok, result = pcall(vim.fn.system, cmd)
  local exit_code = vim.v.shell_error

  if not ok or exit_code ~= 0 then
    pcall(vim.fn.delete, temp_file)
    if on_complete then on_complete(nil, "curl failed: " .. (ok and "exit " .. exit_code or tostring(result))) end
    return nil
  end

  local content = M._read_file(temp_file)
  pcall(vim.fn.delete, temp_file)
  if not content or content == "" then
    if on_complete then on_complete(nil, "Empty response") end
    return nil
  end

  local ok, response = pcall(json.decode, content)
  if not ok or type(response) ~= "table" then
    if on_complete then on_complete(nil, "JSON parse failed") end
    return nil
  end

  -- 立即解析 tool_calls 中的 arguments 为 Lua table
  M._parse_response_tool_calls(response)

  if response.error then
    local err_msg = response.error.message or json.encode(response.error)
    if on_complete then on_complete(nil, err_msg) end
    return nil
  end

  -- 更新去重缓存（带 nil 保护）
  if generation_id then
    http_utils.update_dedup(generation_id, api_type .. "_nonstream", request)
  end

  local unified = request_adapter.transform_response(response, api_type)
  if on_complete then on_complete(unified, nil) end
  return nil
end

--- 发送流式请求
function M.send_stream_request(params, on_chunk, on_complete, on_error)
  if not state.initialized then
    if on_error then
      on_error("HTTP client not initialized")
    end
    return nil
  end

  -- 优先从协程共享表读取参数
  local shared = state_manager.get_shared()
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or state.config.api_key
  local api_type = params.api_type or ai_preset.api_type or "openai"
  local provider_config = params.provider_config or ai_preset or {}

  if not api_key or api_key == "" then
    return nil, "API key not configured"
  end
  if not base_url or base_url == "" then
    return nil, "API base URL not configured"
  end

  -- 请求去重
  if generation_id and http_utils.check_dedup(generation_id, api_type .. "_stream", request) then
    return nil
  end

  -- 支持通过 params.tool_choice 覆盖 request 中的 tool_choice
  -- 注意：params.tool_choice 为 nil 时不覆盖（保持 request 中的值）
  -- 如需清除 tool_choice，设置 params._clear_tool_choice = true
  if params._clear_tool_choice then
    request.tool_choice = nil
  elseif params.tool_choice ~= nil then
    request.tool_choice = params.tool_choice
  end

  -- 防御性检查：如果指定了强制工具调用（tool_choice 为 function 类型），
  -- 自动禁用思考模式。DeepSeek 等 API 在思考模式下不支持强制工具调用。
  if request.tool_choice and type(request.tool_choice) == "table" and request.tool_choice.type == "function" then
    if request.extra_body and request.extra_body.thinking then
      local thinking_type = type(request.extra_body.thinking) == "table" and request.extra_body.thinking.type or ""
      if thinking_type == "enabled" then
        -- logger.warn("[http_client] 检测到强制工具调用与思考模式冲突，自动禁用思考模式")
        request.extra_body.thinking.type = "disabled"
        request.extra_body.reasoning_effort = nil
      end
    end
  end

  -- 支持禁用思考模式
  -- 注意：不清除 tool_choice，因为 send_input 需要强制工具调用
  if params._disable_reasoning then
    if not request.extra_body then
      request.extra_body = {}
    end
    if not request.extra_body.thinking then
      request.extra_body.thinking = {}
    end
    if type(request.extra_body.thinking) == "table" then
      request.extra_body.thinking.type = "disabled"
    end
    request.extra_body.reasoning_effort = nil
  end

  -- 参数检查：验证 request 结构完整性
  if not request.messages or #request.messages == 0 then
    logger.warn("[http_client] send_stream_request: request.messages 为空或不存在")
  end
  if not request.model or request.model == "" then
    logger.warn("[http_client] send_stream_request: request.model 未设置，将使用 API 默认模型")
  end
  if request.tool_choice and request.tool_choice ~= "none" then
    if not request.tools or #request.tools == 0 then
      logger.warn(
        "[http_client] send_stream_request: 设置了 tool_choice 但未提供 tools 定义，API 可能报错"
      )
    end
  end

  request.stream = true
  local transformed = request_adapter.transform_request(request, api_type, provider_config)
  -- 将 tool_calls.arguments 从 Lua table 编码为 JSON 字符串（API 要求字符串格式）
  M._encode_tool_call_arguments(transformed)
  local request_body = json.encode(transformed)
  request_body = M._sanitize_json_body(request_body)
  -- 调试：打印请求体中的 model 字段
  local ok_body, decoded_body = pcall(json.decode, request_body)
  if ok_body and decoded_body and decoded_body.model then
    logger.debug(string.format(
      "[http_client] 流式请求 model=%s",
      tostring(decoded_body.model)
    ))
  end
  logger.debug(string.format(
    "[http_client] 流式请求体大小: generation_id=%s, 大小=%d bytes",
    tostring(generation_id), #request_body
  ))
  -- 对短请求体（< 8KB）使用 --data-raw 避免临时文件 I/O
  local use_temp_file = #request_body > 8192
  local temp_file = use_temp_file and vim.fn.tempname() or nil
  state.request_counter = state.request_counter + 1
  local request_id = "req_" .. state.request_counter .. "_" .. os.time()

  -- 累计接收数据量
  local total_received = 0

  state.active_requests[request_id] = {
    generation_id = generation_id,
    temp_file = temp_file,
    cancelled = false,
    has_error = false,
    buffer = "",
  }

  -- 更新去重缓存
  if generation_id then
    http_utils.update_dedup(generation_id, api_type .. "_stream", request)
  end

  local function process_sse_line(line)
    if line == "" then
      return
    end
    local data_str = line:match("^data:%s*(.*)")
    if data_str then
      if data_str == "[DONE]" then
        return
      end
      local ok, data = pcall(json.decode, data_str)
      if ok and type(data) == "table" then
        total_received = total_received + #data_str
        logger.debug(
          "[http_client] 流式数据块: 大小=" .. #data_str .. " bytes, 累计=" .. total_received .. " bytes | " .. data_str:sub(1, 1000) .. (data_str:len() > 1000 and "...[truncated]" or "")
        )
        if data.error then
          local req = state.active_requests[request_id]
          if req then
            req.has_error = true
          end
          if on_error then
            on_error("API error: " .. (data.error.message or json.encode(data.error)))
          end
          return
        end
        -- 立即解析 tool_calls 中的 arguments 为 Lua table
        M._parse_response_tool_calls(data)
        local unified = request_adapter.transform_response(data, api_type)
        if on_chunk then
          on_chunk(unified)
        end
      end
    else
      local ok, data = pcall(json.decode, line)
      if ok and type(data) == "table" and data.error then
        local req = state.active_requests[request_id]
        if req then
          req.has_error = true
        end
        if on_error then
          on_error("API error: " .. (data.error.message or json.encode(data.error)))
        end
      end
    end
  end

  local function handle_stdout(data_lines)
    local req = state.active_requests[request_id]
    if not req or req.cancelled then
      return
    end
    local n = #data_lines
    if n == 0 then
      return
    end
    -- 计算本次回调的数据总大小
    local lines_size = 0
    for _, line in ipairs(data_lines) do
      lines_size = lines_size + #(line or "")
    end
    logger.debug(string.format(
      "[http_client] handle_stdout: 行数=%d, 本次大小=%d bytes, buffer大小=%d bytes",
      n, lines_size, #(req.buffer or "")
    ))
    local ends_with_newline = data_lines[n] == ""
    local count = ends_with_newline and n - 1 or n
    for i = 1, count do
      local line = data_lines[i]
      if i == 1 and req.buffer ~= "" then
        line = req.buffer .. (line or "")
        req.buffer = ""
      end
      process_sse_line(line or "")
    end
    if not ends_with_newline and n >= 1 then
      local last = data_lines[n]
      if last ~= nil and last ~= "" then
        req.buffer = (req.buffer or "") .. last
      end
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
    if req.buffer ~= "" then
      logger.debug(string.format("[http_client] handle_complete: 处理残留 buffer, 大小=%d, 内容前500=%s", #req.buffer, req.buffer:sub(1, 500)))
      process_sse_line(req.buffer)
    end
    local has_error = req and req.has_error
    if req then
      state.active_requests[request_id] = nil
    end
    logger.debug(string.format(
      "[http_client] 流式请求完成: %s | has_error=%s | 总接收数据=%d bytes",
      base_url, tostring(has_error), total_received
    ))
    if not has_error and on_complete then
      on_complete()
    end
  end

  local function handle_error(err_msg)
    local req = state.active_requests[request_id]
    if req then
      if req.cancelled then
        state.active_requests[request_id] = nil
        return
      end
      state.active_requests[request_id] = nil
    else
      return
    end
    logger.debug("[http_client] 流式请求错误: " .. base_url .. " | error=" .. err_msg)
    if on_error then
      on_error(err_msg)
    end
  end

  local headers = request_adapter.get_headers(api_key, api_type)
  local args = { "-sN", "-X", "POST", base_url, "-H", "Content-Type: application/json" }
  for k, v in pairs(headers) do
    if k ~= "Content-Type" then
      table.insert(args, "-H")
      table.insert(args, k .. ": " .. v)
    end
  end

  if use_temp_file then
    local ok, _ = pcall(function()
      local r = vim.fn.writefile({ request_body }, temp_file)
      if r == -1 then
        error("write failed")
      end
    end)
    if not ok then
      state.active_requests[request_id] = nil
      if on_error then
        on_error("Failed to write temp file")
      end
      return nil
    end
    vim.list_extend(args, { "--data-binary", "@" .. temp_file })
  else
    -- 短请求体直接通过 --data-raw 传递，避免临时文件 I/O
    vim.list_extend(args, { "--data-raw", request_body })
  end

  -- 不设置 curl 超时，由系统网络栈控制

  local job_id = vim.fn.jobstart({ "curl", unpack(args) }, {
    on_stdout = function(_, data)
      if data and #data > 0 then
        handle_stdout(data)
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        local err = table.concat(data, "\n")
        if err ~= "" then
          handle_error(err)
        end
      end
    end,
    on_exit = function(_, exit_code, _)
      if temp_file then
        pcall(vim.fn.delete, temp_file)
      end
      -- 检查请求是否已被取消（按 ESC 时），避免已取消的请求继续触发回调
      local req = state.active_requests[request_id]
      if req and req.cancelled then
        state.active_requests[request_id] = nil
        return
      end
      if exit_code == 0 then
        handle_complete()
      else
        if req and not req.cancelled then
          handle_error("exit: " .. exit_code)
        end
      end
    end,
  })
  if state.active_requests[request_id] then
    state.active_requests[request_id].job_id = job_id
  end
  return request_id
end

function M.cancel_request(request_id)
  local req = state.active_requests[request_id]
  if not req then
    return
  end
  req.cancelled = true
  if req.temp_file then
    pcall(vim.fn.delete, req.temp_file)
  end
  if req.job_id then
    pcall(vim.fn.jobstop, req.job_id)
  end
  state.active_requests[request_id] = nil
end

--- 清除指定 generation_id 的请求去重缓存
--- 用于重试场景：防止重试请求因请求体相同被去重机制拦截
--- @param generation_id string
function M.clear_request_dedup(generation_id)
  http_utils.clear_dedup(generation_id)
end

function M.cancel_all_requests()
  for id, _ in pairs(state.active_requests) do
    M.cancel_request(id)
  end
  state.active_requests = {}
  http_utils.clear_all_dedup()
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
    if on_complete then
      on_complete(nil, "HTTP client not initialized")
    end
    return nil
  end

  -- 优先从协程共享表读取参数
  local shared = state_manager.get_shared()
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or state.config.api_key
  local api_type = params.api_type or ai_preset.api_type or "openai"
  local provider_config = params.provider_config or ai_preset or {}

  if not api_key or api_key == "" then
    if on_complete then
      on_complete(nil, "API key not configured")
    end
    return nil
  end
  if not base_url or base_url == "" then
    if on_complete then
      on_complete(nil, "API base URL not configured")
    end
    return nil
  end

  -- 支持通过 params.tool_choice 覆盖
  if params._clear_tool_choice then
    request.tool_choice = nil
  elseif params.tool_choice ~= nil then
    request.tool_choice = params.tool_choice
  end

  -- 防御性检查：如果指定了强制工具调用（tool_choice 为 function 类型），
  -- 自动禁用思考模式。DeepSeek 等 API 在思考模式下不支持强制工具调用。
  if request.tool_choice and type(request.tool_choice) == "table" and request.tool_choice.type == "function" then
    -- deepseek-reasoner 是思考模式的模型名，不支持 tool_choice
    -- 需要切换为对应的非思考模式模型名 deepseek-chat
    if request.model and type(request.model) == "string" then
      local model_lower = request.model:lower()
      if model_lower:find("reasoner") then
        local new_model = request.model:gsub("reasoner", "chat"):gsub("re$", "")
        if new_model == request.model then
          new_model = "deepseek-chat"
        end
        -- logger.warn("[http_client] 强制工具调用不支持 deepseek-reasoner 模型，自动切换为 %s", new_model)
        request.model = new_model
      end
    end

    -- 禁用思考模式
    if request.extra_body and request.extra_body.thinking then
      local thinking_type = type(request.extra_body.thinking) == "table" and request.extra_body.thinking.type or ""
      if thinking_type == "enabled" then
        -- logger.warn("[http_client] 检测到强制工具调用与思考模式冲突，自动禁用思考模式")
        request.extra_body.thinking.type = "disabled"
      end
      request.extra_body.reasoning_effort = nil
    else
      if not request.extra_body then
        request.extra_body = {}
      end
      if not request.extra_body.thinking then
        request.extra_body.thinking = { type = "disabled" }
      end
    end
  end

  -- 支持禁用思考模式
  -- 注意：不清除 tool_choice，因为 send_input 需要强制工具调用
  if params._disable_reasoning then
    if not request.extra_body then
      request.extra_body = {}
    end
    if not request.extra_body.thinking then
      request.extra_body.thinking = {}
    end
    if type(request.extra_body.thinking) == "table" then
      request.extra_body.thinking.type = "disabled"
    end
    request.extra_body.reasoning_effort = nil
  end

  -- 参数检查：验证 request 结构完整性
  if not request.messages or #request.messages == 0 then
    logger.warn("[http_client] send_request_async: request.messages 为空或不存在")
  end
  if not request.model or request.model == "" then
    logger.warn("[http_client] send_request_async: request.model 未设置，将使用 API 默认模型")
  end
  if request.tool_choice and request.tool_choice ~= "none" then
    if not request.tools or #request.tools == 0 then
      logger.warn(
        "[http_client] send_request_async: 设置了 tool_choice 但未提供 tools 定义，API 可能报错"
      )
    end
  end

  -- 防御性修复：将调用了工具列表中没有的工具的 tool 消息转为 user 消息
  -- 避免 API 报错 'tool message without matching tool_calls' 或工具名不匹配
  M._repair_orphan_tool_messages(request)

  local transformed = request_adapter.transform_request(request, api_type, provider_config)
  M._encode_tool_call_arguments(transformed)
  local ok_encode, request_body = pcall(json.encode, transformed)
  if ok_encode and request_body then
    request_body = M._sanitize_json_body(request_body)
  end
  if not ok_encode then
    if on_complete then
      vim.schedule(function()
        on_complete(nil, "JSON encode failed: " .. tostring(request_body))
      end)
    end
    return nil
  end
  logger.debug(
    "[http_client] 异步非流式请求: "
      .. base_url
      .. " | body="
      .. request_body:sub(1, 2000)
      .. (request_body:len() > 2000 and "...[truncated]" or "")
  )

  local temp_file = vim.fn.tempname()
  local headers = request_adapter.get_headers(api_key, api_type)

  local curl_args = { "-s", "-X", "POST", base_url, "-H", "Content-Type: application/json" }
  for k, v in pairs(headers) do
    if k ~= "Content-Type" then
      table.insert(curl_args, "-H")
      table.insert(curl_args, k .. ": " .. v)
    end
  end
  vim.list_extend(curl_args, {
    "-d",
    request_body,
    "-o",
    temp_file,
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
          logger.warn("[http_client] 异步请求 stderr: " .. err)
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

      logger.debug(
        "[http_client] 异步非流式响应: "
          .. base_url
          .. " | body="
          .. content:sub(1, 2000)
          .. (content:len() > 2000 and "...[truncated]" or "")
      )

      local ok, response = pcall(json.decode, content)
      if not ok then
        if on_complete then
          vim.schedule(function()
            on_complete(nil, "JSON parse failed")
          end)
        end
        return
      end

      if response == nil then
        -- JSON 解码返回 nil，直接视为解析失败
        -- 输出完整原始数据以便排查
        local raw_data_for_log = content:sub(1, 2000)
        if #content > 2000 then
          raw_data_for_log = raw_data_for_log .. "...[truncated, total=" .. #content .. "]"
        end
        logger.warn(
          "[http_client] 异步请求返回非JSON内容，视为解析失败: content=%s (len=%d) | raw_data=%s",
          content:sub(1, 500),
          #content,
          raw_data_for_log
        )
        if on_complete then
          vim.schedule(function()
            on_complete(nil, "JSON parse failed: " .. content:sub(1, 200))
          end)
        end
        return
      end

      if response.error then
        local err_msg = response.error.message or json.encode(response.error)

        -- 自动修复：如果错误包含 tool_choice 不支持，清除 tool_choice 后重试
        if err_msg and err_msg:find("does not support this tool_choice") then
          logger.warn("[http_client] 异步请求 tool_choice 不被支持，清除后重试: %s", err_msg)
          request.tool_choice = nil
          -- 重新构建请求体并重试
          local retry_transformed = request_adapter.transform_request(request, api_type, provider_config)
          M._encode_tool_call_arguments(retry_transformed)
          local retry_ok_encode, retry_body = pcall(json.encode, retry_transformed)
          if retry_ok_encode and retry_body then
            retry_body = M._sanitize_json_body(retry_body)
          end
          if retry_ok_encode then
            local retry_temp = vim.fn.tempname()
            local retry_args = { "-s", "-X", "POST", base_url, "-H", "Content-Type: application/json" }
            for k, v in pairs(headers) do
              if k ~= "Content-Type" then
                table.insert(retry_args, "-H")
                table.insert(retry_args, k .. ": " .. v)
              end
            end
            vim.list_extend(retry_args, {
              "-d",
              retry_body,
              "-o",
              retry_temp,
            })

            local retry_job_id = vim.fn.jobstart({ "curl", unpack(retry_args) }, {
              on_stderr = function(_, data)
                if data and #data > 0 then
                  local err = table.concat(data, "\n")
                  if err ~= "" then
                    logger.debug("[http_client] 异步重试请求 stderr: " .. err)
                  end
                end
              end,
              on_exit = function(_, retry_exit_code, _)
                if retry_exit_code ~= 0 then
                  pcall(vim.fn.delete, retry_temp)
                  if on_complete then
                    vim.schedule(function()
                      on_complete(nil, "curl retry exit: " .. retry_exit_code)
                    end)
                  end
                  return
                end

                local retry_content = M._read_file(retry_temp)
                pcall(vim.fn.delete, retry_temp)

                if not retry_content or retry_content == "" then
                  if on_complete then
                    vim.schedule(function()
                      on_complete(nil, "Empty retry response")
                    end)
                  end
                  return
                end

                local retry_ok2, retry_response = pcall(json.decode, retry_content)
                if not retry_ok2 or not retry_response then
                  if on_complete then
                    vim.schedule(function()
                      on_complete(nil, "Retry JSON parse failed")
                    end)
                  end
                  return
                end

                if retry_response.error then
                  if on_complete then
                    vim.schedule(function()
                      on_complete(nil, retry_response.error.message or json.encode(retry_response.error))
                    end)
                  end
                  return
                end

                -- 更新去重缓存
                if generation_id then
                  http_utils.update_dedup(generation_id, api_type .. "_nonstream", request)
                end

                if on_complete then
                  local retry_unified = request_adapter.transform_response(retry_response, api_type)
                  -- 解析 tool_calls 中的 arguments（从 JSON 字符串转为 Lua table）
                  M._parse_response_tool_calls(retry_unified)
                  vim.schedule(function()
                    on_complete(retry_unified, nil)
                  end)
                end
              end,
            })
            return
          end
        end

        if on_complete then
          vim.schedule(function()
            on_complete(nil, err_msg)
          end)
        end
        return
      end

      -- 更新去重缓存
      if generation_id then
        http_utils.update_dedup(generation_id, api_type .. "_nonstream", request)
      end

      if on_complete then
        local unified = request_adapter.transform_response(response, api_type)
        -- 解析 tool_calls 中的 arguments（从 JSON 字符串转为 Lua table）
        M._parse_response_tool_calls(unified)
        vim.schedule(function()
          on_complete(unified, nil)
        end)
      end
    end,
  })

  if state.active_requests[request_id] then
    state.active_requests[request_id].job_id = job_id
  end

  -- 如果 jobstart 失败（返回 0 或 -1），立即触发回调
  if not job_id or job_id <= 0 then
    state.active_requests[request_id] = nil
    pcall(vim.fn.delete, temp_file)
    if on_complete then
      vim.schedule(function()
        on_complete(nil, "curl jobstart failed")
      end)
    end
    return nil
  end

  return request_id
end

function M.shutdown()
  M.cancel_all_requests()
  state.initialized = false
end

function M._read_file(filepath)
  local ok, content = pcall(function()
    local f = io.open(filepath, "r")
    if not f then
      return nil
    end
    local d = f:read("*a")
    f:close()
    return d
  end)
  return ok and content or nil
end

return M
