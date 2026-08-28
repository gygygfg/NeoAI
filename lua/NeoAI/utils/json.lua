--- JSON 编解码
--- @module NeoAI.utils.json
--- 优先使用 vim.json（Neovim 内置），回退到轻量纯 Lua 实现。

local M = {}

local vim_json_available = vim and vim.json and vim.json.encode

local strx = require("NeoAI.utils.stringx")

--- 递归清洗结构中所有字符串为合法 UTF-8（仅在有非法字节时复制/替换）
--- @param v any
--- @return any
local function _sanitize_value(v)
  local t = type(v)
  if t == "string" then
    return strx.sanitize_utf8(v)
  end
  if t ~= "table" then return v end
  local out = nil
  for k, val in pairs(v) do
    local nk = type(k) == "string" and strx.sanitize_utf8(k) or k
    local nv = _sanitize_value(val)
    if nk ~= k or nv ~= val then
      if not out then
        out = {}
        for k2, v2 in pairs(v) do out[k2] = v2 end
      end
      out[nk] = nv
      if nk ~= k then out[k] = nil end
    end
  end
  return out or v
end

-- ========== 编码 ==========

--- 编码为 JSON 字符串
--- @param value any
--- @return string
function M.encode(value)
  value = _sanitize_value(value)
  if vim_json_available then
    return vim.json.encode(value)
  end
  -- 回退实现
  local function _enc(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
      if v ~= v or v == math.huge or v == -math.huge then return "null" end
      return tostring(v)
    end
    if t == "string" then
      return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    end
    if t == "table" then
      local is_array = #v > 0
      if is_array then
        local parts = {}
        for i = 1, #v do parts[i] = _enc(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
      else
        local parts = {}
        for k, val in pairs(v) do
          if type(k) == "string" then
            parts[#parts + 1] = _enc(k) .. ":" .. _enc(val)
          end
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
    end
    return "null"
  end
  return _enc(value)
end

-- ========== 解码 ==========

local function _trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _decode_string(s, i)
  local quote = i
  i = i + 1
  local out = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local nxt = s:sub(i + 1, i + 1)
      local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
      if map[nxt] then
        out[#out + 1] = map[nxt]
        i = i + 2
      elseif nxt == "u" then
        local hex = s:sub(i + 2, i + 5)
        out[#out + 1] = utf8 and utf8.char(tonumber(hex, 16)) or ("u" .. hex)
        i = i + 6
      else
        out[#out + 1] = nxt
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  error("Unterminated string in JSON at position " .. quote)
end

local function _decode_number(s, i)
  local j = i
  while j <= #s and s:sub(j, j):match("[%d%+%-%.eE]") do j = j + 1 end
  local str = s:sub(i, j - 1)
  local n = tonumber(str)
  if not n then error("Invalid number in JSON: " .. str) end
  return n, j
end

--- 解码 JSON 字符串
--- @param s string
--- @return any 解析结果
function M.decode(s)
  if vim_json_available then
    return vim.json.decode(s)
  end
  if type(s) ~= "string" then return nil end
  local i = 1
  local function _skip_ws()
    while i <= #s and s:sub(i, i):match("%s") do i = i + 1 end
  end
  local function _value()
    _skip_ws()
    local c = s:sub(i, i)
    if c == "{" then
      i = i + 1
      local obj = {}
      _skip_ws()
      if s:sub(i, i) == "}" then i = i + 1 return obj end
      while true do
        _skip_ws()
        local key, ni = _decode_string(s, i)
        i = ni
        _skip_ws()
        if s:sub(i, i) ~= ":" then error("Expected ':' in JSON object") end
        i = i + 1
        obj[key] = _value()
        _skip_ws()
        local sep = s:sub(i, i)
        if sep == "," then i = i + 1
        elseif sep == "}" then i = i + 1 return obj
        else error("Expected ',' or '}' in JSON object") end
      end
    elseif c == "[" then
      i = i + 1
      local arr = {}
      _skip_ws()
      if s:sub(i, i) == "]" then i = i + 1 return arr end
      while true do
        arr[#arr + 1] = _value()
        _skip_ws()
        local sep = s:sub(i, i)
        if sep == "," then i = i + 1
        elseif sep == "]" then i = i + 1 return arr
        else error("Expected ',' or ']' in JSON array") end
      end
    elseif c == '"' then
      return _decode_string(s, i)
    elseif c == "t" then
      if s:sub(i, i + 3) == "true" then i = i + 4 return true end
      error("Invalid JSON literal")
    elseif c == "f" then
      if s:sub(i, i + 4) == "false" then i = i + 5 return false end
      error("Invalid JSON literal")
    elseif c == "n" then
      if s:sub(i, i + 3) == "null" then i = i + 4 return nil end
      error("Invalid JSON literal")
    elseif c:match("[%d%-]") then
      local n, ni = _decode_number(s, i)
      i = ni
      return n
    else
      error("Unexpected character in JSON: " .. c)
    end
  end
  return _value()
end

--- 安全解码，出错返回 nil + err
--- @param s string
--- @return any, string|nil
function M.decode_or_nil(s)
  if vim_json_available then
    local ok, res = pcall(vim.json.decode, s)
    if ok then return res end
    return nil, res
  end
  local ok, res = pcall(M.decode, s)
  if ok then return res end
  return nil, res
end

--- 每行 JSON 解析（JSONL）
--- @param line string
--- @return any|nil 解析失败返回 nil
function M.decode_line(line)
  if not line or line == "" then return nil end
  local ok, res = pcall(M.decode, line)
  if ok then return res end
  return nil
end

return M
