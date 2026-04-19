-- 纯 Lua JSON 编码/解码实现
-- 用于替代 cjson 模块

local M = {}

-- 转义特殊字符
local function escape_string(str)
  return str:gsub('[\\"/\b\f\n\r\t]', {
    ['\\'] = '\\\\',
    ['"'] = '\\"',
    ['/'] = '\\/',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
  })

-- 编码 Lua 值为 JSON 字符串
function M.encode(value)
  local t = type(value)
  
  if t == "string" then
    return '"' .. escape_string(value) .. '"'
  elseif t == "number" then
    -- 处理 NaN 和 Infinity
    if value ~= value then
      return '"NaN"'
    elseif value == math.huge then
      return 'null'
    elseif value == -math.huge then
      return 'null'
    
    return tostring(value)
  elseif t == "boolean" then
    return value and "true" or "false"
  elseif t == "table" then
    -- 检查是否为数组（连续整数索引从1开始）
    local is_array = true
    local max_index = 0
    for k, _ in pairs(value) do
      if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
        is_array = false
        break
      
      if k > max_index then
        max_index = k
      
    
    -- 检查是否连续
    if is_array then
      for i = 1, max_index do
        if value[i] == nil then
          is_array = false
          break
        
      
    
    if is_array then
      -- 编码为 JSON 数组
      local parts = {}
      for i = 1, max_index do
        parts[i] = M.encode(value[i])
      
      return "[" .. table.concat(parts, ",") .. "]"
    else
      -- 编码为 JSON 对象
      local parts = {}
      for k, v in pairs(value) do
        if type(k) == "string" then
          table.insert(parts, '"' .. escape_string(k) .. '":' .. M.encode(v))
        
      
      return "{" .. table.concat(parts, ",") .. "}"
    
  elseif t == "nil" then
    return "null"
  else
    error("无法编码类型: " .. t)
  

-- 解码 JSON 字符串为 Lua 值（简化版）
function M.decode(json_str)
  -- 这是一个简化的解码器，仅处理基本结构
  -- 对于复杂的 JSON，建议使用完整的解析器
  local pos = 1
  
  local function skip_whitespace()
    while pos <= #json_str do
      local c = json_str:sub(pos, pos)
      if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
        pos = pos + 1
      else
        break
      
    
  
  local function parse_value()
    skip_whitespace()
    local c = json_str:sub(pos, pos)
    
    if c == '"' then
      -- 解析字符串
      pos = pos + 1
      local start = pos
      while pos <= #json_str do
        local c2 = json_str:sub(pos, pos)
        if c2 == '"' then
          local str = json_str:sub(start, pos - 1)
          pos = pos + 1
          -- 简单反转义
          str = str:gsub('\\"', '"')
          str = str:gsub('\\\\', '\\')
          str = str:gsub('\\/', '/')
          str = str:gsub('\\b', '\b')
          str = str:gsub('\\f', '\f')
          str = str:gsub('\\n', '\n')
          str = str:gsub('\\r', '\r')
          str = str:gsub('\\t', '\t')
          return str
        elseif c2 == '\\' then
          pos = pos + 2  -- 跳过转义字符和下一个字符
        else
          pos = pos + 1
        
      
      error("未终止的字符串")
    elseif c == '{' then
      -- 解析对象
      pos = pos + 1
      local obj = {}
      skip_whitespace()
      
      if json_str:sub(pos, pos) == '}' then
        pos = pos + 1
        return obj
      
      while true do
        skip_whitespace()
        local key = parse_value()
        skip_whitespace()
        
        if json_str:sub(pos, pos) ~= ':' then
          error("期望 ':'")
        
        pos = pos + 1
        
        local value = parse_value()
        obj[key] = value
        
        skip_whitespace()
        local next_char = json_str:sub(pos, pos)
        if next_char == '}' then
          pos = pos + 1
          break
        elseif next_char == ',' then
          pos = pos + 1
        else
          error("期望 ',' 或 '}'")
        
      
      return obj
    elseif c == '[' then
      -- 解析数组
      pos = pos + 1
      local arr = {}
      skip_whitespace()
      
      if json_str:sub(pos, pos) == ']' then
        pos = pos + 1
        return arr
      
      local index = 1
      while true do
        local value = parse_value()
        arr[index] = value
        index = index + 1
        
        skip_whitespace()
        local next_char = json_str:sub(pos, pos)
        if next_char == ']' then
          pos = pos + 1
          break
        elseif next_char == ',' then
          pos = pos + 1
        else
          error("期望 ',' 或 ']'")
        
      
      return arr
    elseif c == 't' and json_str:sub(pos, pos + 3) == 'true' then
      pos = pos + 4
      return true
    elseif c == 'f' and json_str:sub(pos, pos + 4) == 'false' then
      pos = pos + 5
      return false
    elseif c == 'n' and json_str:sub(pos, pos + 3) == 'null' then
      pos = pos + 4
      return nil
    elseif c == '-' or (c >= '0' and c <= '9') then
      -- 解析数字（简化版）
      local start = pos
      while pos <= #json_str do
        local c2 = json_str:sub(pos, pos)
        if (c2 >= '0' and c2 <= '9') or c2 == '.' or c2 == '-' or c2 == '+' or c2 == 'e' or c2 == 'E' then
          pos = pos + 1
        else
          break
        
      
      local num_str = json_str:sub(start, pos - 1)
      return tonumber(num_str)
    elseif (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') then
      -- 解析标识符（true, false, null）
      local start = pos
      while pos <= #json_str do
        local c2 = json_str:sub(pos, pos)
        if (c2 >= 'a' and c2 <= 'z') or (c2 >= 'A' and c2 <= 'Z') or c2 == '_' then
          pos = pos + 1
        else
          break
        
      
      local identifier = json_str:sub(start, pos - 1)
      
      if identifier == "true" then
        return true
      elseif identifier == "false" then
        return false
      elseif identifier == "null" then
        return nil
      else
        -- 处理未加引号的字符串标识符（如'data'）
        -- 这可能来自某些API的不规范JSON响应
        -- 为了兼容性，将其作为字符串返回
        return identifier
      
    else
      error("无法解析的字符: " .. c)
    
  
  return parse_value()

return M