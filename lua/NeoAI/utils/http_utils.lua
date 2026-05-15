--- NeoAI HTTP 工具函数
--- 职责：提供 HTTP 客户端模块共用的工具函数
---   - JSON 处理、URL 编码/解码、请求去重
---   - curl 调用（同步/异步/流式）
---   - SSE 行解析
---   - 流式数据块拼接（content/reasoning/tool_calls）
---   - JSON 深度追踪与工具调用最终化

local logger = require("NeoAI.utils.logger")
local json = require("NeoAI.utils.json")
local request_handler = require("NeoAI.core.ai.request_handler")
local state_manager = require("NeoAI.core.config.state")

local M = {}

-- ========== 请求去重 ==========

--- @type table<string, { hash: string, timestamp: number }>
local request_dedup = {}

--- 检查请求是否重复
--- @param generation_id string
--- @param suffix string 后缀（如 "_stream"、"_nonstream"）
--- @param body table 请求体
--- @param ttl_ms number TTL 毫秒
--- @return boolean 是否重复
function M.check_dedup(generation_id, suffix, body, ttl_ms)
  ttl_ms = ttl_ms or 3000
  local dedup_key = generation_id .. "_" .. suffix
  local cached = request_dedup[dedup_key]
  if cached then
    local body_str = vim.json.encode(body or {})
    local current_hash = vim.fn.sha256(body_str)
    local now = os.time() * 1000
    if cached.hash == current_hash and (now - cached.timestamp) < ttl_ms then
      logger.debug("[http_utils] 请求去重: 跳过重复请求, key=%s", dedup_key)
      return true
    end
  end
  return false
end

--- 更新去重缓存
--- @param generation_id string
--- @param suffix string
--- @param body table 请求体
function M.update_dedup(generation_id, suffix, body)
  local dedup_key = generation_id .. "_" .. suffix
  local body_str = vim.json.encode(body or {})
  request_dedup[dedup_key] = {
    hash = vim.fn.sha256(body_str),
    timestamp = os.time() * 1000,
  }
end

--- 清除指定 generation_id 的去重缓存
--- @param generation_id string
function M.clear_dedup(generation_id)
  if not generation_id or generation_id == "" then return end
  for key, _ in pairs(request_dedup) do
    if key:find(generation_id, 1, true) then
      request_dedup[key] = nil
    end
  end
end

--- 清除所有去重缓存
function M.clear_all_dedup()
  request_dedup = {}
end

-- ========== URL 编码/解码 ==========

--- 将字符串中可能影响 JSON 解析的字符转义为 %%XX URL 编码
--- 编码范围：控制字符(<0x20)、反斜杠(0x5C)、双引号(0x22)、非法 UTF-8
--- 这样编码后的字符串可直接嵌入 JSON 字符串值中，无需额外转义
--- @param str string
--- @return string
function M.encode_special_chars(str)
  if not str or str == "" then return str end
  local result = {}
  local i = 1
  while i <= #str do
    local byte = str:byte(i)
    if byte == 0x22 or byte == 0x5C then
      result[#result + 1] = string.format("%%%02X", byte)
      i = i + 1
    elseif byte < 0x20 then
      result[#result + 1] = string.format("%%%02X", byte)
      i = i + 1
    elseif byte >= 0x80 then
      local trailing = 0
      if byte >= 0xF0 and byte <= 0xF4 then trailing = 3
      elseif byte >= 0xE0 then trailing = 2
      elseif byte >= 0xC2 then trailing = 1
      else
        result[#result + 1] = string.format("%%%02X", byte)
        i = i + 1
        goto continue
      end
      local valid = true
      for j = 1, trailing do
        local next_byte = str:byte(i + j)
        if not next_byte or next_byte < 0x80 or next_byte > 0xBF then valid = false; break end
      end
      if valid then
        result[#result + 1] = str:sub(i, i + trailing)
        i = i + trailing + 1
      else
        for j = 1, trailing + 1 do
          local b = str:byte(i + j - 1)
          if b then result[#result + 1] = string.format("%%%02X", b) end
        end
        i = i + trailing + 1
      end
    else
      result[#result + 1] = string.char(byte)
      i = i + 1
    end
    ::continue::
  end
  return table.concat(result)
end

--- 解析 tool_calls 中的 arguments 字段（从 JSON 字符串转为 Lua table）
--- 在 json.decode 后立即调用，确保后续代码直接操作 Lua 表
--- @param tool_calls table|nil 工具调用列表
--- @return table 处理后的工具调用列表
function M.parse_tool_call_arguments(tool_calls)
  if not tool_calls or #tool_calls == 0 then return tool_calls or {} end
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.arguments and type(func.arguments) == "string" then
      local ok, parsed = pcall(vim.json.decode, func.arguments)
      if ok and type(parsed) == "table" then
        func.arguments = parsed
      end
    end
  end
  return tool_calls
end

--- 解析响应中所有 tool_calls 的 arguments（递归处理 choices）
--- @param response table 已解码的响应
--- @return table 处理后的响应
function M.parse_response_tool_calls(response)
  if not response or type(response) ~= "table" then return response end
  if response.choices then
    for _, choice in ipairs(response.choices) do
      if choice.delta and choice.delta.tool_calls then
        M.parse_tool_call_arguments(choice.delta.tool_calls)
      end
      if choice.message and choice.message.tool_calls then
        M.parse_tool_call_arguments(choice.message.tool_calls)
      end
    end
  end
  -- 处理顶层 tool_calls（某些非标准响应）
  if response.tool_calls then
    M.parse_tool_call_arguments(response.tool_calls)
  end
  return response
end

-- ========== JSON 清理 ==========

--- 清理 JSON 请求体（验证 + 重新编码）
--- @param body string
--- @return string
function M.sanitize_json_body(body)
  if not body or body == "" then return body end
  local ok, decoded = pcall(json.decode, body)
  if ok and decoded ~= nil then
    local ok2, reencoded = pcall(json.encode, decoded)
    if ok2 and reencoded then return reencoded end
  end
  return body
end

-- ========== 防御性修复 ==========

--- 将调用了工具列表中没有的工具的 tool 消息转为 user 消息
--- @param request table 请求体（会被原地修改）
function M.repair_orphan_tool_messages(request)
  if not request or not request.messages or #request.messages == 0 then return end

  local available_tools = {}
  if request.tools then
    for _, td in ipairs(request.tools) do
      local func = td["function"] or td.func
      if func and func.name then available_tools[func.name] = true end
    end
  end
  if not next(available_tools) then return end

  local declared_ids = {}
  for _, msg in ipairs(request.messages) do
    if msg.role == "assistant" and msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        local tc_id = tc.id or tc.tool_call_id
        if tc_id then declared_ids[tc_id] = true end
      end
    end
  end

  local fixed = 0
  for _, msg in ipairs(request.messages) do
    if msg.role == "tool" then
      local is_orphan = false
      if msg.tool_call_id and msg.tool_call_id ~= "" then
        if not declared_ids[msg.tool_call_id] then is_orphan = true end
      else
        is_orphan = true
      end
      if not is_orphan and msg.name and msg.name ~= "" then
        if not available_tools[msg.name] then is_orphan = true end
      end
      if is_orphan then
        msg.role = "user"
        msg.tool_call_id = nil
        msg.name = nil
        fixed = fixed + 1
      end
    end
  end
  if fixed > 0 then
    logger.debug("[http_utils] 防御性修复: 将 %d 条孤立 tool 消息转为 user 消息", fixed)
  end
end

-- ========== 文件读取 ==========

--- 读取文件内容
--- @param filepath string
--- @return string|nil
function M.read_file(filepath)
  local ok, content = pcall(function()
    local f = io.open(filepath, "r")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
  end)
  return ok and content or nil
end

-- =====================================================================
-- curl 调用
-- =====================================================================

--- 构建 curl 参数列表
--- @param opts { url: string, method: string, headers: table, body: string }
--- @return table curl 参数列表
function M.build_curl_args(opts)
  local args = { "-s", "-X", opts.method or "POST", opts.url, "-H", "Content-Type: application/json" }
  for k, v in pairs(opts.headers or {}) do
    if k ~= "Content-Type" then
      table.insert(args, "-H")
      table.insert(args, k .. ": " .. v)
    end
  end
  if opts.body then
    vim.list_extend(args, { "-d", opts.body })
  end
  return args
end

--- 执行同步 curl 请求（vim.fn.system），返回响应内容
--- @param opts { url: string, method?: string, headers: table, body: string }
--- @return string|nil content, string|nil err
function M.execute_curl(opts)
  local args = M.build_curl_args(opts)
  local temp_file = vim.fn.tempname()
  vim.list_extend(args, { "-o", temp_file })

  local cmd = vim.list_extend({ "curl" }, args)
  local ok, result = pcall(vim.fn.system, cmd)
  local exit_code = vim.v.shell_error

  if not ok or exit_code ~= 0 then
    pcall(vim.fn.delete, temp_file)
    return nil, "curl failed: " .. (ok and "exit " .. exit_code or tostring(result))
  end

  local content = M.read_file(temp_file)
  pcall(vim.fn.delete, temp_file)
  if not content or content == "" then
    return nil, "Empty response"
  end
  return content, nil
end

--- 执行异步非流式 curl 请求（vim.fn.jobstart）
--- @param opts { url: string, method?: string, headers: table, body: string, temp_file: string }
--- @param callbacks { on_complete: function(content, err), on_stderr?: function(data) }
--- @return integer|nil job_id, string temp_file
function M.execute_curl_async(opts, callbacks)
  local args = M.build_curl_args(opts)
  local temp_file = opts.temp_file or vim.fn.tempname()
  vim.list_extend(args, { "-o", temp_file })

  local job_id = vim.fn.jobstart({ "curl", unpack(args) }, {
    on_stderr = function(_, data)
      if data and #data > 0 and callbacks.on_stderr then
        callbacks.on_stderr(data)
      end
    end,
    on_exit = function(_, exit_code, _)
      if exit_code ~= 0 then
        pcall(vim.fn.delete, temp_file)
        if callbacks.on_complete then
          vim.schedule(function()
            callbacks.on_complete(nil, "curl exit: " .. exit_code)
          end)
        end
        return
      end

      local content = M.read_file(temp_file)
      pcall(vim.fn.delete, temp_file)

      if callbacks.on_complete then
        vim.schedule(function()
          callbacks.on_complete(content, not content and "Empty response" or nil)
        end)
      end
    end,
  })

  return job_id, temp_file
end

-- =====================================================================
-- SSE 行解析
-- =====================================================================

--- 解析单行 SSE 数据
--- @param line string SSE 行
--- @return table|nil 解析后的数据，nil 表示跳过（空行或 [DONE]）
function M.parse_sse_line(line)
  if not line or line == "" then return nil end
  local data_str = line:match("^data:%s*(.*)")
  if data_str then
    if data_str == "[DONE]" then return nil end
    local ok, data = pcall(json.decode, data_str)
    if ok and type(data) == "table" then
      return data
    end
  end
  -- 尝试直接解析整行（某些非标准 SSE）
  local ok, data = pcall(json.decode, line)
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

-- =====================================================================
-- 流式处理器（数据拼接）
-- =====================================================================

--- 创建流式处理器实例
--- 用于在流式接收过程中累积 content、reasoning_content 和 tool_calls
--- @param generation_id string
--- @param session_id string|nil
--- @param window_id integer|nil
--- @param is_tool_loop boolean|nil
--- @return table processor
function M.create_stream_processor(generation_id, session_id, window_id, is_tool_loop)
  return {
    generation_id = generation_id,
    content_buffer = "",
    reasoning_buffer = "",
    tool_calls = {},
    usage = {},
    session_id = session_id,
    window_id = window_id,
    is_tool_loop = is_tool_loop or false,
    start_time = os.time(),
    is_finished = false,
    -- 工具调用累积状态（用于调试和完整性检查）
    _json_depth = 0,           -- 当前 JSON 嵌套深度（{+1, }-1）
    _json_depth_changed = false, -- 深度是否曾发生过变化
  }
end

--- 更新 JSON 深度计数器
--- 统计字符串中的 { (+1) 和 } (-1)，用于判断 JSON 是否完整
--- @param processor table 流式处理器实例
--- @param str string 新增的字符串片段
function M._update_json_depth(processor, str)
  if not processor or not str or type(str) ~= "string" then return end
  local changed = false
  for i = 1, #str do
    local c = str:sub(i, i)
    if c == "{" then
      processor._json_depth = processor._json_depth + 1
      changed = true
    elseif c == "}" then
      processor._json_depth = processor._json_depth - 1
      changed = true
    end
  end
  if changed then
    processor._json_depth_changed = true
  end
end

--- 检查 JSON 深度是否为 0
--- 深度为 0 表示所有 { 都已闭合，JSON 可能完整
--- @param processor table 流式处理器实例
--- @return boolean
function M._check_json_depth_zero(processor)
  if not processor then return false end
  return processor._json_depth == 0
end

--- 处理流式数据块
--- 注意：tool_calls 中的 arguments 字段在 http_client 中已解析为 Lua table
--- 流式场景中，每个数据块的 arguments 是部分 table，需要逐块合并
--- @param processor table 流式处理器实例
--- @param data table 已解析的流式数据块
--- @return { content: string|nil, reasoning_content: string|nil, tool_calls: table|nil, tool_calls_delta: table|nil, is_final: boolean, usage: table|nil }
function M.process_stream_chunk(processor, data)
  local result = { content = nil, reasoning_content = nil, tool_calls = nil, tool_calls_delta = nil, is_final = false }

  -- 如果已标记完成，只处理 usage 数据（某些 API 在 finish_reason 后发送 usage）
  if processor.is_finished then
    if data.usage then
      processor.usage = data.usage
      result.usage = data.usage
    end
    return result
  end

  if data.choices and #data.choices > 0 then
    local choice = data.choices[1]
    if choice.delta then
      local delta = choice.delta
      if delta.reasoning_content ~= nil and delta.reasoning_content ~= "" then
        processor.reasoning_buffer = processor.reasoning_buffer .. delta.reasoning_content
        result.reasoning_content = delta.reasoning_content
      end
      if delta.content ~= nil and delta.content ~= "" then
        processor.content_buffer = processor.content_buffer .. delta.content
        result.content = delta.content
      end
      if delta.tool_calls then
        -- tool_calls_delta：当前 chunk 的原始增量数据（arguments 是原始片段）
        result.tool_calls_delta = delta.tool_calls
        for _, tc in ipairs(delta.tool_calls) do
          local idx = tc.index or 0
          if not processor.tool_calls[idx + 1] then
            local safe_id = tc.id or ("call_" .. os.time() .. "_" .. idx)
            processor.tool_calls[idx + 1] = {
              id = safe_id, type = tc.type or "function",
              ["function"] = { name = "", arguments = {} },
            }
          end
          local e = processor.tool_calls[idx + 1]
          if tc.id then e.id = tc.id end
          if tc.type then e.type = tc.type end
          if tc["function"] then
            if tc["function"].name then e["function"].name = e["function"].name .. tc["function"].name end
            if tc["function"].arguments ~= nil then
              if type(tc["function"].arguments) == "string" then
                if type(e["function"].arguments) == "table" then
                  e["function"].arguments = tc["function"].arguments
                  M._update_json_depth(processor, tc["function"].arguments)
                elseif type(e["function"].arguments) == "string" then
                  M._update_json_depth(processor, tc["function"].arguments)
                  e["function"].arguments = e["function"].arguments .. tc["function"].arguments
                end
              elseif type(tc["function"].arguments) == "table" then
                e["function"].arguments = tc["function"].arguments
              end
            end
          end
        end
        if #processor.tool_calls > 0 then result.tool_calls = vim.deepcopy(processor.tool_calls) end
      end
    end
    if choice.message and choice.message.tool_calls then
      for _, tc in ipairs(choice.message.tool_calls) do
        local idx = tc.index or 0
        if not processor.tool_calls[idx + 1] then
          local safe_id = tc.id or ("call_" .. os.time() .. "_" .. idx)
          processor.tool_calls[idx + 1] = {
            id = safe_id, type = tc.type or "function",
            ["function"] = { name = "", arguments = {} },
          }
        end
        local e = processor.tool_calls[idx + 1]
        if tc.id then e.id = tc.id end
        if tc.type then e.type = tc.type end
        if tc["function"] then
          if tc["function"].name then e["function"].name = tc["function"].name end
          if tc["function"].arguments ~= nil then
            if type(tc["function"].arguments) == "string" then
              if type(e["function"].arguments) == "table" then
                e["function"].arguments = tc["function"].arguments
                M._update_json_depth(processor, tc["function"].arguments)
              elseif type(e["function"].arguments) == "string" then
                M._update_json_depth(processor, tc["function"].arguments)
                e["function"].arguments = e["function"].arguments .. tc["function"].arguments
              end
            elseif type(tc["function"].arguments) == "table" then
              e["function"].arguments = tc["function"].arguments
            end
          end
        end
      end
      if #processor.tool_calls > 0 then result.tool_calls = vim.deepcopy(processor.tool_calls) end
    end
    if choice.finish_reason then
      result.is_final = true
      processor.is_finished = true
    end
  end
  if data.usage then
    processor.usage = data.usage
    result.usage = data.usage
  end

  -- ===== 工具调用累积日志（仅调试用，不打断流式接收） =====
  if result.tool_calls_delta and #result.tool_calls_delta > 0 then
    if M._check_json_depth_zero(processor) and processor._json_depth_changed then
      logger.debug("[http_utils] 工具调用 JSON 深度为0，等待 finish_reason")
    end
  end

  return result
end

--- 过滤无效工具调用（流式截断导致 name 为空或 arguments 为空）
--- 同时将流式累积的字符串 arguments 解析为 Lua table
--- @param tool_calls table
--- @return table
function M.filter_valid_tool_calls(tool_calls)
  local valid = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name and func.name ~= "" then
      local args = func.arguments
      -- 将流式累积的字符串 arguments 解析为 Lua table
      if type(args) == "string" and args ~= "" then
        local ok, parsed = pcall(vim.json.decode, args)
        if ok and type(parsed) == "table" then
          func.arguments = parsed
          args = parsed
        end
      end
      if args ~= nil and args ~= "" then
        table.insert(valid, tc)
      end
    end
  end
  return valid
end

--- 尝试格式化当前累积的工具调用 arguments
--- 在流式结束后调用：将所有工具调用的 arguments 从字符串解析为 Lua table
--- @param processor table 流式处理器实例
--- @return table|nil 格式化成功的 tool_calls，或 nil
function M.try_finalize_tool_calls(processor)
  if not processor or not processor.tool_calls or #processor.tool_calls == 0 then
    return nil
  end

  local finalized = {}
  for _, tc in ipairs(processor.tool_calls) do
    local func = tc["function"] or tc.func
    if not func or not func.name or func.name == "" then
      logger.debug("[http_utils] try_finalize_tool_calls: 跳过名称为空的工具调用")
      return nil
    end

    local args = func.arguments
    if type(args) == "string" and args ~= "" then
      local ok, parsed = pcall(vim.json.decode, args)
      if ok and type(parsed) == "table" then
        func.arguments = parsed
        args = parsed
      else
        logger.debug("[http_utils] try_finalize_tool_calls: 工具 '%s' 的 arguments JSON 不完整: %s",
          func.name, args:sub(1, 200))
        return nil
      end
    end

    if args == nil then
      logger.debug("[http_utils] try_finalize_tool_calls: 工具 '%s' 的 arguments 为 nil", func.name)
      return nil
    end

    table.insert(finalized, tc)
  end

  if #finalized > 0 then
    logger.debug("[http_utils] try_finalize_tool_calls: 成功格式化 %d 个工具调用", #finalized)
    return finalized
  end
  return nil
end

--- 清理处理器中的工具调用状态
--- @param processor table|nil 流式处理器实例
function M.clear_dual_trigger_state(processor)
  if not processor then return end
  processor._json_depth = 0
  processor._json_depth_changed = false
end

-- =====================================================================
-- reasoning 节流（原 stream_processor.lua 迁移）
-- =====================================================================

local _reasoning_throttle = {
  timer = nil,
  pending_content = "",
  generation_id = nil,
  processor = nil,
  params = nil,
  interval_ms = 80,
}

--- 推送 reasoning 内容（带节流）
function M.push_reasoning_content(generation_id, content, processor, params)
  _reasoning_throttle.pending_content = _reasoning_throttle.pending_content .. (content or "")
  _reasoning_throttle.generation_id = generation_id
  _reasoning_throttle.processor = processor
  _reasoning_throttle.params = params

  if not _reasoning_throttle.timer then
    _reasoning_throttle.timer = vim.defer_fn(function()
      local content = _reasoning_throttle.pending_content
      local gid = _reasoning_throttle.generation_id
      local proc = _reasoning_throttle.processor
      _reasoning_throttle.pending_content = ""
      _reasoning_throttle.timer = nil

      if content ~= "" then
        local shared = require("NeoAI.core.config.state").get_shared()
        local sid = shared and shared.session_id or (proc and proc.session_id)
        local wid = shared and shared.window_id or (proc and proc.window_id)
        vim.api.nvim_exec_autocmds("User", {
          pattern = require("NeoAI.core.events").REASONING_CONTENT,
          data = {
            generation_id = gid,
            reasoning_content = content,
            session_id = sid,
            window_id = wid,
          },
        })
      end
    end, _reasoning_throttle.interval_ms)
  end
end

--- 清理 reasoning 节流状态
function M.clear_reasoning_throttle()
  if _reasoning_throttle.timer then
    local timer = _reasoning_throttle.timer
    pcall(function()
      if timer:is_active() then timer:stop() end
      if not timer:is_closing() then timer:close() end
    end)
    _reasoning_throttle.timer = nil
  end
  _reasoning_throttle.pending_content = ""
  _reasoning_throttle.generation_id = nil
  _reasoning_throttle.processor = nil
  _reasoning_throttle.params = nil
end

--- 检查处理器是否已完成（兼容接口）
--- @param processor table 流式处理器实例
--- @return boolean
function M.is_tool_calls_ready(processor)
  return processor and processor.is_finished
end


-- =====================================================================
-- HTTP 客户端状态管理（从 http_client.lua 迁移）
-- =====================================================================

local _http_state = {
  initialized = false,
  config = {},
  active_requests = {},
  request_counter = 0,
}

function M.encode_tool_call_arguments(body)
  if not body or type(body) ~= "table" then
    return
  end
  if not body.messages then
    return
  end
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
  if _http_state.initialized then
    return M
  end
  _http_state.config = options.config or {}
  _http_state.initialized = true
  return M
end

--- 发送非流式请求
function M.send_request(params)
  if not _http_state.initialized then
    _http_state.initialized = true
  end

  -- 优先从协程共享表读取参数
  local shared = state_manager.get_shared()
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or _http_state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or _http_state.config.api_key
  local api_type = params.api_type or ai_preset.api_type or "openai"
  local provider_config = params.provider_config or ai_preset or {}

  -- 请求去重
  if generation_id and M.check_dedup(generation_id, api_type, request) then
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
  M.repair_orphan_tool_messages(request)

  local transformed = request_handler.transform_request(request, api_type, provider_config)
  -- 将 tool_calls.arguments 从 Lua table 编码为 JSON 字符串（API 要求字符串格式）
  M.encode_tool_call_arguments(transformed)
  local request_body = json.encode(transformed)
  request_body = M.sanitize_json_body(request_body)
  logger.debug(
    string.format(
      "[http_client] 原始请求数据: generation_id=%s, api_type=%s, base_url=%s, body_len=%d",
      tostring(generation_id),
      tostring(api_type),
      tostring(base_url),
      #request_body
    )
  )
  logger.debug(
    "[http_client] 原始请求体: "
      .. request_body:sub(1, 3000)
      .. (request_body:len() > 3000 and "...[truncated]" or "")
  )
  -- 调试：打印请求体中的 model 字段
  local ok_body, decoded_body = pcall(json.decode, request_body)
  if ok_body and decoded_body and decoded_body.model then
    logger.debug(string.format("[http_client] 非流式请求 model=%s", tostring(decoded_body.model)))
  end
  logger.debug(
    "[http_client] 非流式请求: "
      .. base_url
      .. " | body="
      .. request_body:sub(1, 2000)
      .. (request_body:len() > 2000 and "...[truncated]" or "")
  )
  local temp_file = vim.fn.tempname()
  local headers = request_handler.get_headers(api_key, api_type)

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

  local content = M.read_file(temp_file)
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
    M.parse_response_tool_calls(response)
  end
  if response.error then
    local err_msg = response.error.message or json.encode(response.error)
    logger.debug("[http_client] API 错误: " .. err_msg)

    -- 自动修复：如果错误包含 tool_choice 不支持，清除 tool_choice 后重试
    if err_msg and err_msg:find("does not support this tool_choice") then
      request.tool_choice = nil
      -- 重新构建请求体并重试
      local retry_transformed = request_handler.transform_request(request, api_type, provider_config)
      M.encode_tool_call_arguments(retry_transformed)
      local retry_body = json.encode(retry_transformed)
      retry_body = M.sanitize_json_body(retry_body)
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
      local retry_content = M.read_file(retry_temp)
      pcall(vim.fn.delete, retry_temp)
      if retry_content and retry_content ~= "" then
        local retry_ok2, retry_response = pcall(json.decode, retry_content)
        if retry_ok2 and retry_response then
          if retry_response.error then
            return nil, retry_response.error.message or json.encode(retry_response.error)
          end
          if type(retry_response) == "table" then
            M.parse_response_tool_calls(retry_response)
          end
          local retry_unified = request_handler.transform_response(retry_response, api_type)
          return retry_unified, nil
        end
      end
      return nil, "retry failed"
    end

    return nil, err_msg
  end

  -- 更新去重缓存
  if generation_id then
    M.update_dedup(generation_id, api_type .. "_nonstream", request)
  end

  local unified = request_handler.transform_response(response, api_type)
  return unified, nil
end

--- 发送非流式请求（内部重试用，带 generation_id 保护）
function M.send_request_retry(params, on_complete)
  if not _http_state.initialized then
    _http_state.initialized = true
  end

  local shared = state_manager.get_shared()
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or _http_state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or _http_state.config.api_key
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

  -- 参数检查
  if not request.messages or #request.messages == 0 then
    logger.warn("[http_client] send_request_retry: request.messages 为空或不存在")
  end
  if not request.model or request.model == "" then
    logger.warn("[http_client] send_request_retry: request.model 未设置")
  end

  -- 防御性修复
  M.repair_orphan_tool_messages(request)

  local transformed = request_handler.transform_request(request, api_type, provider_config)
  M.encode_tool_call_arguments(transformed)
  local request_body = json.encode(transformed)
  request_body = M.sanitize_json_body(request_body)
  logger.debug(
    string.format(
      "[http_client] 原始请求数据(send_request_retry): generation_id=%s, api_type=%s, base_url=%s, body_len=%d",
      tostring(generation_id),
      tostring(api_type),
      tostring(base_url),
      #request_body
    )
  )
  logger.debug(
    "[http_client] 原始请求体(send_request_retry): "
      .. request_body:sub(1, 3000)
      .. (request_body:len() > 3000 and "...[truncated]" or "")
  )

  local temp_file = vim.fn.tempname()
  local headers = request_handler.get_headers(api_key, api_type)

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
    if on_complete then
      on_complete(nil, "curl failed: " .. (ok and "exit " .. exit_code or tostring(result)))
    end
    return nil
  end

  local content = M.read_file(temp_file)
  pcall(vim.fn.delete, temp_file)
  if not content or content == "" then
    if on_complete then
      on_complete(nil, "Empty response")
    end
    return nil
  end

  local ok, response = pcall(json.decode, content)
  if not ok or type(response) ~= "table" then
    if on_complete then
      on_complete(nil, "JSON parse failed")
    end
    return nil
  end

  -- 立即解析 tool_calls 中的 arguments 为 Lua table
  M.parse_response_tool_calls(response)

  if response.error then
    local err_msg = response.error.message or json.encode(response.error)
    if on_complete then
      on_complete(nil, err_msg)
    end
    return nil
  end

  -- 更新去重缓存（带 nil 保护）
  if generation_id then
    M.update_dedup(generation_id, api_type .. "_nonstream", request)
  end

  local unified = request_handler.transform_response(response, api_type)
  if on_complete then
    on_complete(unified, nil)
  end
  return nil
end

--- 发送流式请求
function M.send_stream_request(params, on_chunk, on_complete, on_error)
  if not _http_state.initialized then
    _http_state.initialized = true
  end

  -- 优先从协程共享表读取参数
  local shared = state_manager.get_shared()
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or _http_state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or _http_state.config.api_key
  local api_type = params.api_type or ai_preset.api_type or "openai"
  local provider_config = params.provider_config or ai_preset or {}

  if not api_key or api_key == "" then
    return nil, "API key not configured"
  end
  if not base_url or base_url == "" then
    return nil, "API base URL not configured"
  end

  -- 请求去重
  if generation_id and M.check_dedup(generation_id, api_type .. "_stream", request) then
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
  local transformed = request_handler.transform_request(request, api_type, provider_config)
  -- 将 tool_calls.arguments 从 Lua table 编码为 JSON 字符串（API 要求字符串格式）
  M.encode_tool_call_arguments(transformed)
  local request_body = json.encode(transformed)
  request_body = M.sanitize_json_body(request_body)
  logger.debug(
    string.format(
      "[http_client] 原始请求数据(send_stream_request): generation_id=%s, api_type=%s, base_url=%s, body_len=%d",
      tostring(generation_id),
      tostring(api_type),
      tostring(base_url),
      #request_body
    )
  )
  logger.debug(
    "[http_client] 原始请求体(send_stream_request): "
      .. request_body:sub(1, 3000)
      .. (request_body:len() > 3000 and "...[truncated]" or "")
  )
  -- 调试：打印请求体中的 model 字段
  local ok_body, decoded_body = pcall(json.decode, request_body)
  if ok_body and decoded_body and decoded_body.model then
    logger.debug(string.format("[http_client] 流式请求 model=%s", tostring(decoded_body.model)))
  end
  logger.debug(
    string.format(
      "[http_client] 流式请求体大小: generation_id=%s, 大小=%d bytes",
      tostring(generation_id),
      #request_body
    )
  )
  -- 对短请求体（< 8KB）使用 --data-raw 避免临时文件 I/O
  local use_temp_file = #request_body > 8192
  local temp_file = use_temp_file and vim.fn.tempname() or nil
  _http_state.request_counter = _http_state.request_counter + 1
  local request_id = "req_" .. _http_state.request_counter .. "_" .. os.time()

  -- 累计接收数据量
  local total_received = 0

  -- 空闲超时检测：30 秒无数据时尝试格式化工具调用
  -- 如果格式化成功则视为传输完成，否则触发重试
  local IDLE_TIMEOUT_MS = 30000
  local idle_timer = nil
  -- 引用自身模块的函数（stream_processor 功能已合并到此模块）

  -- 将 idle_timer 存入 active_requests，方便 cancel_request 清理
  local function set_idle_timer(timer)
    local r = _http_state.active_requests[request_id]
    if r then
      r.idle_timer = timer
    end
  end

  local function reset_idle_timer()
    if idle_timer then
      idle_timer:stop()
      idle_timer:close()
      idle_timer = nil
    end
  end

  local function start_idle_timer()
    reset_idle_timer()
    idle_timer = vim.uv.new_timer()
    set_idle_timer(idle_timer)
    idle_timer:start(
      IDLE_TIMEOUT_MS,
      0,
      vim.schedule_wrap(function()
        local req = _http_state.active_requests[request_id]
        if not req or req.cancelled or req.has_error then
          return
        end

        -- 检查是否已有 tool_calls 在累积中
        -- 通过 on_chunk 回调获取 processor 状态
        logger.debug(
          "[http_client] 流式请求空闲超时 (%dms): request_id=%s, generation_id=%s",
          IDLE_TIMEOUT_MS,
          request_id,
          tostring(generation_id)
        )

        -- 尝试通过 on_chunk 传递的 processor 获取当前 tool_calls 状态
        -- 由于 processor 在 ai_engine 中管理，这里无法直接访问
        -- 但我们可以利用 stream_processor 的 try_finalize_tool_calls
        -- 注意：这里无法直接获取 processor，因为它在 ai_engine 中创建
        -- 所以我们需要通过另一种方式：检查是否有 tool_calls_delta 累积

        -- 实际上，我们需要在 ai_engine 层面处理这个问题
        -- 在 http_client 层面，我们只能触发一个特殊回调
        -- 让上层（ai_engine）决定是完成还是重试

        -- 方案：触发一个特殊的空闲超时回调
        -- 如果 on_chunk 回调存在，发送一个标记数据让上层处理
        if on_chunk then
          -- 发送一个特殊的空闲超时标记
          local timeout_marker = {
            _idle_timeout = true,
            generation_id = generation_id,
          }
          on_chunk(timeout_marker)
        end

        -- 注意：不在这里清理请求，让上层决定如何处理
        -- 如果上层决定完成，会调用 on_complete
        -- 如果上层决定重试，会调用 on_error
      end)
    )
  end

  _http_state.active_requests[request_id] = {
    generation_id = generation_id,
    temp_file = temp_file,
    cancelled = false,
    has_error = false,
    buffer = "",
    idle_timer = nil,
  }

  -- 更新去重缓存
  if generation_id then
    M.update_dedup(generation_id, api_type .. "_stream", request)
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
          "[http_client] 流式数据块: 大小="
            .. #data_str
            .. " bytes, 累计="
            .. total_received
            .. " bytes | "
            .. data_str:sub(1, 1000)
            .. (data_str:len() > 1000 and "...[truncated]" or "")
        )
        if data.error then
          local req = _http_state.active_requests[request_id]
          if req then
            req.has_error = true
          end
          if on_error then
            on_error("API error: " .. (data.error.message or json.encode(data.error)))
          end
          return
        end
        -- 立即解析 tool_calls 中的 arguments 为 Lua table
        M.parse_response_tool_calls(data)
        local unified = request_handler.transform_response(data, api_type)
        if on_chunk then
          on_chunk(unified)
        end
      end
    else
      local ok, data = pcall(json.decode, line)
      if ok and type(data) == "table" and data.error then
        local req = _http_state.active_requests[request_id]
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
    local req = _http_state.active_requests[request_id]
    if not req or req.cancelled then
      return
    end
    local n = #data_lines
    if n == 0 then
      return
    end
    -- 收到数据时重置空闲超时定时器
    start_idle_timer()
    -- 计算本次回调的数据总大小
    local lines_size = 0
    for _, line in ipairs(data_lines) do
      lines_size = lines_size + #(line or "")
    end
    logger.debug(
      string.format(
        "[http_client] handle_stdout: 行数=%d, 本次大小=%d bytes, buffer大小=%d bytes",
        n,
        lines_size,
        #(req.buffer or "")
      )
    )
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
    -- 清理空闲超时定时器
    reset_idle_timer()
    local req = _http_state.active_requests[request_id]
    if not req then
      -- 请求已被取消（cancel_request 已清理），不再触发回调
      logger.debug("[http_client] 流式请求完成但已被取消，跳过回调")
      return
    end
    if req.cancelled then
      _http_state.active_requests[request_id] = nil
      return
    end
    if req.buffer ~= "" then
      logger.debug(
        string.format(
          "[http_client] handle_complete: 处理残留 buffer, 大小=%d, 内容前500=%s",
          #req.buffer,
          req.buffer:sub(1, 500)
        )
      )
      process_sse_line(req.buffer)
    end
    local has_error = req and req.has_error
    if req then
      _http_state.active_requests[request_id] = nil
    end
    logger.debug(
      string.format(
        "[http_client] 流式请求完成: %s | has_error=%s | 总接收数据=%d bytes",
        base_url,
        tostring(has_error),
        total_received
      )
    )
    if not has_error and on_complete then
      on_complete()
    end
  end

  local function handle_error(err_msg)
    -- 清理空闲超时定时器
    reset_idle_timer()
    local req = _http_state.active_requests[request_id]
    if req then
      if req.cancelled then
        _http_state.active_requests[request_id] = nil
        return
      end
      _http_state.active_requests[request_id] = nil
    else
      return
    end
    logger.debug("[http_client] 流式请求错误: " .. base_url .. " | error=" .. err_msg)
    if on_error then
      on_error(err_msg)
    end
  end

  local headers = request_handler.get_headers(api_key, api_type)
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
      _http_state.active_requests[request_id] = nil
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
      local req = _http_state.active_requests[request_id]
      if req and req.cancelled then
        -- 清理空闲超时定时器
        if req.idle_timer then
          pcall(function()
            req.idle_timer:stop()
            req.idle_timer:close()
          end)
          req.idle_timer = nil
        end
        _http_state.active_requests[request_id] = nil
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
  if _http_state.active_requests[request_id] then
    _http_state.active_requests[request_id].job_id = job_id
  end
  return request_id
end

function M.cancel_request(request_id)
  local req = _http_state.active_requests[request_id]
  if not req then
    return
  end
  req.cancelled = true
  -- 清理空闲超时定时器
  if req.idle_timer then
    pcall(function()
      req.idle_timer:stop()
      req.idle_timer:close()
    end)
    req.idle_timer = nil
  end
  if req.temp_file then
    pcall(vim.fn.delete, req.temp_file)
  end
  if req.job_id then
    pcall(vim.fn.jobstop, req.job_id)
  end
  _http_state.active_requests[request_id] = nil
end

--- 清除指定 generation_id 的请求去重缓存
--- 用于重试场景：防止重试请求因请求体相同被去重机制拦截
--- @param generation_id string
--- 取消指定 generation_id 的所有活跃请求
--- 用于双触发机制：Trigger A 触发后取消仍在进行的 HTTP 请求
--- @param generation_id string
function M.cancel_request_by_generation(generation_id)
  if not generation_id then
    return
  end
  local ids_to_cancel = {}
  for request_id, req in pairs(_http_state.active_requests) do
    if req.generation_id == generation_id then
      table.insert(ids_to_cancel, request_id)
    end
  end
  for _, request_id in ipairs(ids_to_cancel) do
    M.cancel_request(request_id)
  end
end

function M.clear_request_dedup(generation_id)
  M.clear_dedup(generation_id)
end

function M.cancel_all_requests()
  for id, _ in pairs(_http_state.active_requests) do
    M.cancel_request(id)
  end
  _http_state.active_requests = {}
  M.clear_all_dedup()
end

function M.get_state()
  return { initialized = _http_state.initialized, active_requests_count = vim.tbl_count(_http_state.active_requests) }
end

--- 异步非流式请求（使用 vim.fn.jobstart，不阻塞主线程）
--- 用于 execute_single_tool_request 等需要非阻塞的场景
--- @param params table 与 send_request 相同的参数
--- @param on_complete function(response, err) 回调函数
--- @return string|nil request_id
function M.send_request_async(params, on_complete)
  if not _http_state.initialized then
    _http_state.initialized = true
  end

  -- 优先从协程共享表读取参数
  local shared = state_manager.get_shared()
  local ai_preset = shared and shared.ai_preset or {}

  local request = params.request
  local generation_id = params.generation_id or (shared and shared.generation_id)
  local base_url = params.base_url or ai_preset.base_url or _http_state.config.base_url
  local api_key = params.api_key or ai_preset.api_key or _http_state.config.api_key
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
  M.repair_orphan_tool_messages(request)

  local transformed = request_handler.transform_request(request, api_type, provider_config)
  M.encode_tool_call_arguments(transformed)
  local ok_encode, request_body = pcall(json.encode, transformed)
  if ok_encode and request_body then
    request_body = M.sanitize_json_body(request_body)
    logger.debug(
      string.format(
        "[http_client] 原始请求数据(send_request_async): generation_id=%s, api_type=%s, base_url=%s, body_len=%d",
        tostring(generation_id),
        tostring(api_type),
        tostring(base_url),
        #request_body
      )
    )
    logger.debug(
      "[http_client] 原始请求体(send_request_async): "
        .. request_body:sub(1, 3000)
        .. (request_body:len() > 3000 and "...[truncated]" or "")
    )
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
  local headers = request_handler.get_headers(api_key, api_type)

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

  _http_state.request_counter = _http_state.request_counter + 1
  local request_id = "req_async_" .. _http_state.request_counter .. "_" .. os.time()

  _http_state.active_requests[request_id] = {
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
      local req = _http_state.active_requests[request_id]
      if not req then
        -- 请求已被取消
        pcall(vim.fn.delete, temp_file)
        return
      end
      if req.cancelled then
        _http_state.active_requests[request_id] = nil
        pcall(vim.fn.delete, temp_file)
        return
      end

      _http_state.active_requests[request_id] = nil

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
      local content = M.read_file(temp_file)
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
          local retry_transformed = request_handler.transform_request(request, api_type, provider_config)
          M.encode_tool_call_arguments(retry_transformed)
          local retry_ok_encode, retry_body = pcall(json.encode, retry_transformed)
          if retry_ok_encode and retry_body then
            retry_body = M.sanitize_json_body(retry_body)
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

                local retry_content = M.read_file(retry_temp)
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
                  M.update_dedup(generation_id, api_type .. "_nonstream", request)
                end

                if on_complete then
                  local retry_unified = request_handler.transform_response(retry_response, api_type)
                  -- 解析 tool_calls 中的 arguments（从 JSON 字符串转为 Lua table）
                  M.parse_response_tool_calls(retry_unified)
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
        M.update_dedup(generation_id, api_type .. "_nonstream", request)
      end

      if on_complete then
        local unified = request_handler.transform_response(response, api_type)
        -- 解析 tool_calls 中的 arguments（从 JSON 字符串转为 Lua table）
        M.parse_response_tool_calls(unified)
        vim.schedule(function()
          on_complete(unified, nil)
        end)
      end
    end,
  })

  if _http_state.active_requests[request_id] then
    _http_state.active_requests[request_id].job_id = job_id
  end

  -- 如果 jobstart 失败（返回 0 或 -1），立即触发回调
  if not job_id or job_id <= 0 then
    _http_state.active_requests[request_id] = nil
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
  _http_state.initialized = false
end


return M
