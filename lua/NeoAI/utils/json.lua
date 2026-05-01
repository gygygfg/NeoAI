-- 纯 Lua JSON 编码/解码实现
-- 用于替代 cjson 模块
-- 支持 AI 流式数据格式（自动去除 data: 前缀、空行、[DONE] 标记）

local M = {}

local logger = nil
local function get_logger()
  if not logger then
    local ok, mod = pcall(require, "NeoAI.utils.logger")
    if ok then
      logger = mod
    else
      logger = { debug = function() end, warn = function() end, error = function() end }
    end
  end
  return logger
end

-- 转义特殊字符
local function escape_string(str)
  local result = str:gsub('[\\"/\b\f\n\r\t]', {
    ["\\"] = "\\\\",
    ['"'] = '\\"',
    ["/"] = "\\/",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
  })
  local bytes = { result:byte(1, -1) }
  local parts = {}
  for _, byte in ipairs(bytes) do
    if byte < 0x20 and byte ~= 0x09 and byte ~= 0x0a and byte ~= 0x0d then
      table.insert(parts, string.format("\\u%04x", byte))
    else
      table.insert(parts, string.char(byte))
    end
  end
  return table.concat(parts)
end

-- 编码 Lua 值为 JSON 字符串
function M.encode(value)
  local t = type(value)

  if t == "string" then
    return '"' .. escape_string(value) .. '"'
  elseif t == "number" then
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
    if is_array then
      for i = 1, max_index do
        if value[i] == nil then
          is_array = false
          break
        end
      end
    end
    if is_array then
      local parts = {}
      for i = 1, max_index do
        local ok, encoded = pcall(M.encode, value[i])
        parts[i] = ok and encoded or "null"
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(value) do
        if type(k) == "string" then
          local ok, encoded = pcall(M.encode, v)
          table.insert(parts, '"' .. escape_string(k) .. '":' .. (ok and encoded or "null"))
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  elseif t == "nil" then
    return "null"
  elseif t == "userdata" or t == "thread" or t == "function" then
    return "null"
  else
    return "null"
  end
end

-- 解码 JSON 字符串为 Lua 值（迭代版，避免栈溢出）
-- 自动处理 AI 流式数据格式：
--   - 去除 "data: " 前缀
--   - 忽略空行和多余空白
--   - 忽略 "[DONE]" 标记
function M.decode(json_str)
  if type(json_str) ~= "string" then
    return nil
  end

  -- 清理 AI 流式数据格式
  local cleaned = json_str

  -- 去除 BOM
  if cleaned:byte(1) == 0xEF and cleaned:byte(2) == 0xBB and cleaned:byte(3) == 0xBF then
    cleaned = cleaned:sub(4)
  end

  -- 检查是否为 JSON 空字符串 ""（必须在去除空白之前检查，否则 "" 会被误判为空）
  if cleaned == '""' then
    return ""
  end

  -- 去除首尾空白
  cleaned = cleaned:match("^%s*(.-)%s*$") or cleaned

  if cleaned == "" then
    return nil
  end

  -- 处理 "data: [DONE]" 标记
  if cleaned == "[DONE]" or cleaned:match("^data:%s*%[DONE%]") then
    return nil
  end

  -- 去除 "data: " 前缀（AI 流式 SSE 格式）
  cleaned = cleaned:match("^data:%s*(.*)$") or cleaned

  -- 再次去除首尾空白
  cleaned = cleaned:match("^%s*(.-)%s*$") or cleaned

  if cleaned == "" then
    return nil
  end

  -- 迭代解析
  local pos = 1
  local len = #cleaned

  local function skip_whitespace()
    while pos <= len do
      local c = cleaned:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then
        pos = pos + 1
      else
        break
      end
    end
  end

  local function safe_char(...)
    local ok, ch = pcall(string.char, ...)
    if ok then
      return ch
    end
    return ""
  end

  local function parse_string()
    pos = pos + 1
    local result = {}
    while pos <= len do
      local c2 = cleaned:sub(pos, pos)
      if c2 == '"' then
        pos = pos + 1
        return table.concat(result)
      elseif c2 == "\\" then
        pos = pos + 1
        local c3 = cleaned:sub(pos, pos)
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
        elseif c3 == "u" then
          local hex_str = cleaned:sub(pos + 1, pos + 4)
          if #hex_str == 4 and hex_str:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
            local code_point = tonumber(hex_str, 16)
            local handled = false
            if code_point then
              -- 处理代理对（surrogate pair）：high surrogate + low surrogate
              if code_point >= 0xD800 and code_point <= 0xDBFF then
                local next_pos = pos + 5
                local next_chars = cleaned:sub(next_pos, next_pos + 5)
                if next_chars:match("^\\u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
                  local low_hex = next_chars:sub(3, 6)
                  local low_surrogate = tonumber(low_hex, 16)
                  if low_surrogate and low_surrogate >= 0xDC00 and low_surrogate <= 0xDFFF then
                    local full_code = 0x10000 + (code_point - 0xD800) * 0x400 + (low_surrogate - 0xDC00)
                    local ch = safe_char(
                      0xF0 + bit.rshift(full_code, 18),
                      0x80 + bit.band(bit.rshift(full_code, 12), 0x3F),
                      0x80 + bit.band(bit.rshift(full_code, 6), 0x3F),
                      0x80 + bit.band(full_code, 0x3F)
                    )
                    if ch ~= "" then
                      table.insert(result, ch)
                    end
                    pos = pos + 10
                    handled = true
                  end
                end
              end
              if not handled then
                local ch = ""
                if code_point <= 0x7F then
                  ch = safe_char(code_point)
                elseif code_point <= 0x7FF then
                  ch = safe_char(0xC0 + bit.rshift(code_point, 6), 0x80 + bit.band(code_point, 0x3F))
                elseif code_point <= 0xFFFF then
                  ch = safe_char(
                    0xE0 + bit.rshift(code_point, 12),
                    0x80 + bit.band(bit.rshift(code_point, 6), 0x3F),
                    0x80 + bit.band(code_point, 0x3F)
                  )
                else
                  ch = safe_char(
                    0xF0 + bit.rshift(code_point, 18),
                    0x80 + bit.band(bit.rshift(code_point, 12), 0x3F),
                    0x80 + bit.band(bit.rshift(code_point, 6), 0x3F),
                    0x80 + bit.band(code_point, 0x3F)
                  )
                end
                if ch ~= "" then
                  table.insert(result, ch)
                end
              end
            end
            if not handled then
              pos = pos + 4
            end
          else
            table.insert(result, "\\u")
          end
        else
          table.insert(result, "\\" .. c3)
        end
        pos = pos + 1
      else
        table.insert(result, c2)
        pos = pos + 1
      end
    end
    -- 未终止的字符串：跳过并记录日志
    return table.concat(result)
  end

  local function parse_number()
    local start = pos
    while pos <= len do
      local c2 = cleaned:sub(pos, pos)
      if not c2:match("[0-9%.eE%+%-]") then
        break
      end
      pos = pos + 1
    end
    local num_str = cleaned:sub(start, pos - 1)
    return tonumber(num_str)
  end

  local function parse_literal()
    local c = cleaned:sub(pos, pos)
    if c == "t" then
      if cleaned:sub(pos, pos + 3) == "true" then
        pos = pos + 4
        return true
      end
    elseif c == "f" then
      if cleaned:sub(pos, pos + 4) == "false" then
        pos = pos + 5
        return false
      end
    elseif c == "n" then
      if cleaned:sub(pos, pos + 3) == "null" then
        pos = pos + 4
        return nil
      end
    end
    -- 无法识别的字面量：跳过当前字符并返回 nil
    pos = pos + 1
    return nil
  end

  -- 显式栈模拟递归
  local stack = {}
  local root = nil

  -- 将值赋给当前帧（object 或 array）
  local function assign_value(val)
    local frame = stack[#stack]
    if frame.type == "object" then
      frame.container[frame.key] = val
      frame.key = nil
      frame.state = 3
    else
      table.insert(frame.container, val)
      frame.state = 1
    end
  end

  while true do
    skip_whitespace()
    if pos > len then
      if #stack == 0 then
        return nil
      end
      break
    end

    local c = cleaned:sub(pos, pos)

    if c == '"' then
      local str_val = parse_string()
      if #stack == 0 then
        return str_val
      end
      local frame = stack[#stack]
      if frame.type == "object" then
        if frame.state == 0 then
          frame.key = str_val
          frame.state = 1
        elseif frame.state == 2 then
          assign_value(str_val)
        end
        -- else: 跳过意外的字符串
      else
        assign_value(str_val)
      end
    elseif c == "{" or c == "[" then
      local new_container = {}
      local container_type = (c == "{") and "object" or "array"
      pos = pos + 1

      if #stack == 0 then
        root = new_container
        table.insert(stack, { type = container_type, container = new_container, key = nil, state = 0 })
      else
        local parent = stack[#stack]
        if parent.type == "object" then
          if parent.state == 2 then
            parent.container[parent.key] = new_container
            parent.key = nil
            parent.state = 3
          end
          -- else: 跳过意外的 '{' 或 '['
        else
          table.insert(parent.container, new_container)
          parent.state = 1
        end
        table.insert(stack, { type = container_type, container = new_container, key = nil, state = 0 })
      end
    elseif c == "}" or c == "]" then
      if #stack == 0 then
        pos = pos + 1
        goto continue
      end
      local frame = stack[#stack]
      if (c == "}" and frame.type ~= "object") or (c == "]" and frame.type ~= "array") then
        pos = pos + 1
        goto continue
      end
      if frame.type == "object" and frame.state ~= 0 and frame.state ~= 3 then
        pos = pos + 1
        goto continue
      end
      if frame.type == "array" and frame.state ~= 0 and frame.state ~= 1 then
        pos = pos + 1
        goto continue
      end
      pos = pos + 1
      table.remove(stack)

      if #stack == 0 then
        return root
      end
      local parent = stack[#stack]
      if parent.type == "object" and parent.state == 2 then
        parent.state = 3
      end
    elseif c == ":" then
      if #stack == 0 then
        pos = pos + 1
        goto continue
      end
      local frame = stack[#stack]
      if frame.type == "object" and frame.state == 1 then
        pos = pos + 1
        frame.state = 2
      else
        pos = pos + 1
      end
      goto continue
    elseif c == "," then
      if #stack == 0 then
        pos = pos + 1
        goto continue
      end
      local frame = stack[#stack]
      if frame.type == "object" then
        if frame.state == 3 then
          frame.state = 0
        end
      else
        if frame.state == 1 then
          frame.state = 0
        end
      end
      pos = pos + 1
    elseif c == "t" or c == "f" or c == "n" then
      local val = parse_literal()
      if #stack == 0 then
        return val
      end
      local frame = stack[#stack]
      if frame.type == "object" then
        if frame.state == 2 then
          assign_value(val)
        end
      else
        assign_value(val)
      end
    elseif c:match("[0-9%-]") then
      local num = parse_number()
      if #stack == 0 then
        return num
      end
      local frame = stack[#stack]
      if frame.type == "object" then
        if frame.state == 2 then
          assign_value(num)
        end
      else
        assign_value(num)
      end
      goto continue
    else
      -- 无法识别的字符：跳过
      pos = pos + 1
    end
    ::continue::
  end

  return root
end

return M
