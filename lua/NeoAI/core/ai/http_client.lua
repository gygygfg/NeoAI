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

--- 用 json.decode 验证并修复 JSON 字符串
-- json.encode 可能生成包含非法 unicode 码点的字符串（如 \uFFFE, \uFFFF），
-- 这些在 JSON 规范中不允许，会导致 API 服务器解析失败。
-- 此函数将 json.encode 的输出重新喂给 json.decode，
-- 由 json.lua 的解析器容忍/跳过非法字符，最大程度拼出有效 JSON，
-- 然后再用 json.encode 重新编码为干净的字符串。
--- 防御性修复：将调用了工具列表中没有的工具的 tool 消息转为 user 消息
--- 当会话历史中包含之前工具循环中使用的工具结果（tool 消息），
--- 但当前请求的工具列表中不包含该工具时，API 会报错。
--- 此函数将这类孤立的 tool 消息转为 user 消息，避免 API 报错。
--- @param request table 请求体（会被原地修改）
function M._repair_orphan_tool_messages(request)
  if not request or not request.messages or #request.messages == 0 then
    return
  end

  -- 收集当前请求中可用的工具名
  local available_tools = {}
  if request.tools then
    for _, td in ipairs(request.tools) do
      local func = td["function"] or td.func
      if func and func.name then
        available_tools[func.name] = true
      end
    end
  end

  -- 如果没有工具定义，不需要修复
  if not next(available_tools) then
    return
  end

  -- 收集所有 assistant 消息中声明的 tool_call_id
  local declared_tool_call_ids = {}
  for _, msg in ipairs(request.messages) do
    if msg.role == "assistant" and msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        local tc_id = tc.id or tc.tool_call_id
        if tc_id then
          declared_tool_call_ids[tc_id] = true
        end
      end
    end
  end

  local fixed_count = 0
  for _, msg in ipairs(request.messages) do
    if msg.role == "tool" then
      -- 检查 tool 消息的 tool_call_id 是否在 assistant 的 tool_calls 中声明过
      local is_orphan = false
      if msg.tool_call_id and msg.tool_call_id ~= "" then
        if not declared_tool_call_ids[msg.tool_call_id] then
          is_orphan = true
        end
      else
        -- 没有 tool_call_id 的 tool 消息也是孤立的
        is_orphan = true
      end

      -- 额外检查：如果 tool 消息有 name 字段，检查该工具是否在可用工具列表中
      if not is_orphan and msg.name and msg.name ~= "" then
        if not available_tools[msg.name] then
          -- tool_call_id 匹配但工具不在当前列表中，仍然视为孤立
          -- 这种情况通常发生在不同工具循环之间
          is_orphan = true
        end
      end

      if is_orphan then
        msg.role = "user"
        msg.tool_call_id = nil
        msg.name = nil
        fixed_count = fixed_count + 1
      end
    end
  end

  if fixed_count > 0 then
    logger.debug(
      "[http_client] 防御性修复: 将 %d 条孤立 tool 消息转为 user 消息",
      fixed_count
    )
  end
end

--- 将字符串中可能影响 JSON 解析的控制字符和非法 UTF-8 序列转义为 %%XX URL 编码
-- 转义范围：控制字符（\\x00-\\x1F 除 \\n、\\r、\\t）和非法 UTF-8 字节
-- @param str string 原始字符串
-- @return string 编码后的字符串
function M._encode_special_chars(str)
  if not str or str == "" then
    return str
  end
  local result = {}
  local i = 1
  while i <= #str do
    local byte = str:byte(i)
    if byte == 0x0A or byte == 0x0D or byte == 0x09 then
      -- 保留换行、回车、制表符
      result[#result + 1] = string.char(byte)
      i = i + 1
    elseif byte == 0x5C then
      -- 反斜杠 \\：URL 编码为 %5C
      result[#result + 1] = "%5C"
      i = i + 1
    elseif byte == 0x22 then
      -- 双引号 "：URL 编码为 %22
      result[#result + 1] = "%22"
      i = i + 1
    elseif byte < 0x20 then
      -- 控制字符（\\x00-\\x1F 除 \\n\\r\\t）：URL 编码
      result[#result + 1] = string.format("%%%02X", byte)
      i = i + 1
    elseif byte >= 0x80 then
      -- 可能是 UTF-8 多字节字符，验证其合法性
      local trailing = 0
      if byte >= 0xF0 and byte <= 0xF4 then
        trailing = 3
      elseif byte >= 0xE0 then
        trailing = 2
      elseif byte >= 0xC2 then
        trailing = 1
      else
        -- 非法首字节（0x80-0xBF 或 0xC0-0xC1 或 0xF5-0xFF）
        result[#result + 1] = string.format("%%%02X", byte)
        i = i + 1
        goto continue
      end
      -- 检查后续字节是否有效（10xxxxxx 格式）
      local valid = true
      for j = 1, trailing do
        local next_byte = str:byte(i + j)
        if not next_byte or next_byte < 0x80 or next_byte > 0xBF then
          valid = false
          break
        end
      end
      if valid then
        -- 完整有效的 UTF-8 字符，保留
        result[#result + 1] = str:sub(i, i + trailing)
        i = i + trailing + 1
      else
        -- 非法 UTF-8 序列：将每个无效字节单独编码
        for j = 1, trailing + 1 do
          local b = str:byte(i + j - 1)
          if b then
            result[#result + 1] = string.format("%%%02X", b)
          end
        end
        i = i + trailing + 1
      end
    else
      -- ASCII 可打印字符，保留
      result[#result + 1] = string.char(byte)
      i = i + 1
    end
    ::continue::
  end
  return table.concat(result)
end

--- 将 %%XX URL 编码的字符串解码回原始字符
-- @param str string URL 编码的字符串
-- @return string 解码后的字符串
function M._decode_special_chars(str)
  if not str or str == "" then
    return str
  end
  -- 解码 %%XX 格式的 URL 编码
  -- 在 Lua 字符串中 "%%" 表示一个字面量 % 字符
  -- 在 Lua 模式中 "%%" 匹配一个字面量 % 字符
  -- 所以 "%%(%x%x)" 匹配 %XX 格式
  local result = str:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return result
end

--- 递归遍历响应数据结构，对其中所有字符串字段进行特殊字符编码
-- 处理 choices[].delta.content、choices[].delta.reasoning_content、
-- choices[].delta.tool_calls[].function.arguments、
-- choices[].message.content、choices[].message.reasoning_content、
-- choices[].message.tool_calls[].function.arguments
-- @param data table|string 响应数据
-- @return table|string 编码后的数据
function M._encode_response_strings(data)
  if type(data) == "string" then
    return M._encode_special_chars(data)
  end
  if type(data) ~= "table" then
    return data
  end
  for k, v in pairs(data) do
    if type(v) == "string" then
      data[k] = M._encode_special_chars(v)
    elseif type(v) == "table" then
      M._encode_response_strings(v)
    end
  end
  return data
end

function M._sanitize_json_body(body)
  if not body or body == "" then
    return body
  end
  local ok, decoded = pcall(json.decode, body)
  if ok and decoded ~= nil then
    -- json.lua 成功解析，用 json.encode 重新编码得到干净的 JSON
    local ok2, reencoded = pcall(json.encode, decoded)
    if ok2 and reencoded then
      return reencoded
    end
  end
  -- 解析失败或重新编码失败，返回原始 body（后续 curl 会报错，但至少不丢数据）
  return body
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
  local shared = nil
  pcall(function()
    local sm = require("NeoAI.core.config.state")
    shared = sm.get_shared()
  end)
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or state.config.api_key
  local timeout = params.timeout or ai_preset.timeout or state.config.timeout or 60000
  local api_type = params.api_type or ai_preset.api_type or "openai"
  local provider_config = params.provider_config or ai_preset or {}

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
        logger.debug(
          "[http_client] 请求去重: 跳过重复的流式请求, generation_id=" .. tostring(generation_id)
        )
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
  local request_body = json.encode(transformed)
  request_body = M._sanitize_json_body(request_body)
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
    "--connect-timeout",
    tostring(math.floor(timeout / 1000)),
    "--max-time",
    tostring(math.floor(timeout / 1000) + 5), -- 总超时 = 连接超时 + 5秒
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
  if response.error then
    local err_msg = response.error.message or json.encode(response.error)
    logger.debug("[http_client] API 错误: " .. err_msg)

    -- 自动修复：如果错误包含 tool_choice 不支持，清除 tool_choice 后重试
    if err_msg and err_msg:find("does not support this tool_choice") then
      request.tool_choice = nil
      -- 重新构建请求体并重试
      local retry_transformed = request_adapter.transform_request(request, api_type, provider_config)
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
        "--connect-timeout",
        tostring(math.floor(timeout / 1000)),
        "--max-time",
        "0",
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
          local retry_unified = request_adapter.transform_response(retry_response, api_type)
          M._encode_response_strings(retry_unified)
          return retry_unified, nil
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

  local unified = request_adapter.transform_response(response, api_type)
  M._encode_response_strings(unified)
  return unified, nil
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
  local shared = nil
  pcall(function()
    local sm = require("NeoAI.core.config.state")
    shared = sm.get_shared()
  end)
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or state.config.api_key
  local timeout = params.timeout or ai_preset.timeout or state.config.timeout or 60000
  local api_type = params.api_type or ai_preset.api_type or "openai"
  local provider_config = params.provider_config or ai_preset or {}

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
        logger.debug(
          "[http_client] 请求去重: 跳过重复的流式请求, generation_id=" .. tostring(generation_id)
        )
        -- 注意：不调用 on_complete！直接返回 nil。
        -- on_complete 会触发 _handle_stream_end，而此时 processor 的 content_buffer 为空，
        -- 会导致 "空响应" 重试误判。去重意味着请求已在处理中，无需额外回调。
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
  local request_body = json.encode(transformed)
  request_body = M._sanitize_json_body(request_body)
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
    local dedup_key = generation_id .. "_" .. api_type .. "_stream"
    local body_for_hash = vim.json.encode(request or {})
    state._request_dedup[dedup_key] = {
      hash = vim.fn.sha256(body_for_hash),
      timestamp = os.time() * 1000,
    }
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
          "[http_client] 流式数据块: 大小=" .. #data_str .. " bytes, 累计=" .. total_received .. " bytes | " .. data_str:sub(1, 300) .. (data_str:len() > 300 and "...[truncated]" or "")
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
        local unified = request_adapter.transform_response(data, api_type)
        -- 对响应内容中的控制字符和非法 UTF-8 进行 URL 编码
        M._encode_response_strings(unified)
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
      logger.debug(string.format("[http_client] handle_complete: 处理残留 buffer, 大小=%d, 内容前100=%s", #req.buffer, req.buffer:sub(1, 100)))
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

  vim.list_extend(args, {
    "--connect-timeout",
    tostring(math.floor(timeout / 1000)),
    "--max-time",
    "0",
  })

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
  if not generation_id then
    return
  end
  -- 清除所有与该 generation_id 相关的去重缓存
  for key, _ in pairs(state._request_dedup) do
    if key:find(generation_id, 1, true) then
      state._request_dedup[key] = nil
    end
  end
end

function M.cancel_all_requests()
  for id, _ in pairs(state.active_requests) do
    M.cancel_request(id)
  end
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
    if on_complete then
      on_complete(nil, "HTTP client not initialized")
    end
    return nil
  end

  -- 优先从协程共享表读取参数
  local shared = nil
  pcall(function()
    local sm = require("NeoAI.core.config.state")
    shared = sm.get_shared()
  end)
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or state.config.api_key
  local timeout = params.timeout or ai_preset.timeout or state.config.timeout or 60000
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
    "--connect-timeout",
    tostring(math.floor(timeout / 1000)),
    "--max-time",
    "0",
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
              "--connect-timeout",
              tostring(math.floor(timeout / 1000)),
              "--max-time",
              "0",
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
                  local dedup_key = generation_id .. "_" .. api_type .. "_nonstream"
                  local body_for_hash = vim.json.encode(request or {})
                  state._request_dedup[dedup_key] = {
                    hash = vim.fn.sha256(body_for_hash),
                    timestamp = os.time() * 1000,
                  }
                end

                if on_complete then
                  local retry_unified = request_adapter.transform_response(retry_response, api_type)
                  M._encode_response_strings(retry_unified)
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
        local dedup_key = generation_id .. "_" .. api_type .. "_nonstream"
        local body_for_hash = vim.json.encode(request or {})
        state._request_dedup[dedup_key] = {
          hash = vim.fn.sha256(body_for_hash),
          timestamp = os.time() * 1000,
        }
      end

      if on_complete then
        local unified = request_adapter.transform_response(response, api_type)
        M._encode_response_strings(unified)
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
