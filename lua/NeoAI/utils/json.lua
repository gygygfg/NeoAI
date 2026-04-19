-- 纯 Lua JSON 编码/解码实现
-- 用于替代 cjson 模块

local M = {}

-- 转义特殊字符
local function escape_string(str)
  return str:gsub('[\\"/\b\f\n\r\t]', {
    ["\\"] = "\\\\",
    ['"'] = '\\"',
    ["/"] = "\\/",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
  })
end

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
      return "null"
    elseif value == -math.huge then
      return "null"
    end

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
      end

      if k > max_index then
        max_index = k
      end
    end

    -- 检查是否连续
    if is_array then
      for i = 1, max_index do
        if value[i] == nil then
          is_array = false
          break
        end
      end
    end

    if is_array then
      -- 编码为 JSON 数组
      local parts = {}
      for i = 1, max_index do
        parts[i] = M.encode(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      -- 编码为 JSON 对象
      local parts = {}
      for k, v in pairs(value) do
        if type(k) == "string" then
          table.insert(parts, '"' .. escape_string(k) .. '":' .. M.encode(v))
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  elseif t == "nil" then
    return "null"
  else
    error("无法编码类型: " .. t)
  end
end

-- 解码 JSON 字符串为 Lua 值（简化版）
function M.decode(json_str)
  -- 这是一个简化的解码器，仅处理基本结构
  -- 对于复杂的 JSON，建议使用完整的解析器
  local pos = 1

  local function skip_whitespace()
    while pos <= #json_str do
      local c = json_str:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then
        pos = pos + 1
      else
        break
      end
    end
  end

  local function parse_value()
    skip_whitespace()
    local c = json_str:sub(pos, pos)

    if c == '"' then
      -- 解析字符串
      pos = pos + 1
      local result = {}
      while pos <= #json_str do
        local c2 = json_str:sub(pos, pos)
        if c2 == '"' then
          pos = pos + 1
          return table.concat(result)
        elseif c2 == "\\" then
          pos = pos + 1
          local c3 = json_str:sub(pos, pos)
          if c3 == '"' then
            table.insert(result, '"')
          elseif c3 == "\\" then
            table.insert(result, "\\")
          elseif c3 == "/" then
            table.insert(result, "/")
          elseif c3 == "b" then
            table.insert(result, "\b")
          elseif c3 == "f" then
            table.insert(result, "\f")
          elseif c3 == "n" then
            table.insert(result, "\n")
          elseif c3 == "r" then
            table.insert(result, "\r")
          elseif c3 == "t" then
            table.insert(result, "\t")
          else
            -- 未知转义序列，保持原样
            table.insert(result, "\\" .. c3)
          end
          pos = pos + 1
        else
          table.insert(result, c2)
          pos = pos + 1
        end
      end
      error("未终止的字符串")
    elseif c == "{" then
      -- 解析对象
      pos = pos + 1
      skip_whitespace()
      local obj = {}

      if json_str:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end

      while true do
        skip_whitespace()
        if json_str:sub(pos, pos) ~= '"' then
          error("期望字符串键")
        end

        local key = parse_value()
        skip_whitespace()

        if json_str:sub(pos, pos) ~= ":" then
          error("期望冒号")
        end

        pos = pos + 1
        local value = parse_value()
        if key == nil then
          error("JSON对象键不能为null")
        end
        obj[key] = value

        skip_whitespace()
        local c2 = json_str:sub(pos, pos)
        if c2 == "}" then
          pos = pos + 1
          return obj
        elseif c2 == "," then
          pos = pos + 1
        else
          error("期望逗号或右大括号")
        end
      end
    elseif c == "[" then
      -- 解析数组
      pos = pos + 1
      skip_whitespace()
      local arr = {}

      if json_str:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end

      local index = 1
      while true do
        local value = parse_value()
        arr[index] = value
        index = index + 1

        skip_whitespace()
        local c2 = json_str:sub(pos, pos)
        if c2 == "]" then
          pos = pos + 1
          return arr
        elseif c2 == "," then
          pos = pos + 1
        else
          error("期望逗号或右方括号")
        end
      end
    elseif c == "t" then
      -- true
      if json_str:sub(pos, pos + 3) == "true" then
        pos = pos + 4
        return true
      else
        error("无效的JSON")
      end
    elseif c == "f" then
      -- false
      if json_str:sub(pos, pos + 4) == "false" then
        pos = pos + 5
        return false
      else
        error("无效的JSON")
      end
    elseif c == "n" then
      -- null
      if json_str:sub(pos, pos + 3) == "null" then
        pos = pos + 4
        return nil
      else
        error("无效的JSON")
      end
    elseif c:match("[0-9%-]") then
      -- 数字（简化版）
      local start = pos
      while pos <= #json_str do
        local c2 = json_str:sub(pos, pos)
        if not c2:match("[0-9%.eE%+%-]") then
          break
        end
        pos = pos + 1
      end
      local num_str = json_str:sub(start, pos - 1)
      return tonumber(num_str)
    else
      error("无效的JSON字符: " .. c)
    end
  end

  return parse_value()
end

return M

