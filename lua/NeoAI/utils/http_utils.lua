--- NeoAI HTTP 工具函数
--- 职责：提供 HTTP 客户端模块共用的工具函数（JSON 处理、URL 编码/解码、请求去重）
--- 从 http_client.lua 提取公共函数，减少重复代码

local logger = require("NeoAI.utils.logger")
local json = require("NeoAI.utils.json")

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
      -- 编码双引号(")和反斜杠(\)，确保可安全嵌入 JSON
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
      -- 如果解析失败，保留原始字符串
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

return M
