--- 字符串扩展
--- @module NeoAI.utils.stringx
--- 纯函数，无状态。

local M = {}

--- 去除首尾空白
--- @param s string
--- @return string
function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 按分隔符切分字符串
--- @param s string
--- @param sep string 分隔符（plain）
--- @return table 数组
function M.split(s, sep)
  if not s then return {} end
  if not sep or sep == "" then return { s } end
  local out = {}
  local pattern = "([^" .. sep:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "]+)"
  for part in s:gmatch(pattern) do
    out[#out + 1] = part
  end
  return out
end

--- 是否以指定前缀开头
--- @param s string
--- @param prefix string
--- @return boolean
function M.startswith(s, prefix)
  return s:sub(1, #prefix) == prefix
end

--- 是否以指定后缀结尾
--- @param s string
--- @param suffix string
--- @return boolean
function M.endswith(s, suffix)
  return s:sub(-#suffix) == suffix
end

--- 简单模板替换：{key} 替换为 params[key]
--- @param tmpl string
--- @param params table
--- @return string
function M.template(tmpl, params)
  return (tmpl:gsub("%{([%w_]+)%}", function(key)
    local v = params[key]
    if v == nil then return "" end
    return tostring(v)
  end))
end

--- 全局替换
--- @param s string
--- @param from string  plain 字符串
--- @param to string
--- @return string
function M.replace(s, from, to)
  return (s:gsub(from:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"), to))
end

--- 截断到指定长度并加省略号
--- @param s string
--- @param max_len number
--- @return string
function M.truncate(s, max_len)
  if #s <= max_len then return s end
  return s:sub(1, max_len - 3) .. "..."
end

--- 大写首字母
--- @param s string
--- @return string
function M.capitalize(s)
  return s:sub(1, 1):upper() .. s:sub(2)
end

--- 生成唯一 ID
--- @param prefix string|nil
--- @return string
function M.uuid(prefix)
  prefix = prefix or "id"
  local t = os.time()
  local n = math.random(1, 2 ^ 31)
  return string.format("%s_%x_%x", prefix, t, n)
end

--- 判断字符串是否为空或全空白
--- @param s string|nil
--- @return boolean
function M.is_blank(s)
  return s == nil or s == "" or s:match("^%s*$") ~= nil
end

--- glob 转 Lua pattern（用于文件匹配）
--- 支持 * ? 和 {a,b} 花括号
--- @param glob string
--- @return string pattern
function M.glob_to_pattern(glob)
  local out = ""
  local i = 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == "*" then
      out = out .. ".*"
    elseif c == "?" then
      out = out .. "."
    elseif c == "{" then
      local close = glob:find("}", i)
      if close then
        local inner = glob:sub(i + 1, close - 1)
        local alts = {}
        for alt in inner:gmatch("[^,]+") do
          alts[#alts + 1] = M.glob_to_pattern(alt)
        end
        out = out .. "(" .. table.concat(alts, "|") .. ")"
        i = close
      else
        out = out .. "%{"
      end
    elseif c == "." then
      out = out .. "%."
    elseif c:match("%w") then
      out = out .. c
    else
      out = out .. "%" .. c
    end
    i = i + 1
  end
  return "^" .. out .. "$"
end

--- 判断 glob 是否匹配路径
--- @param glob string
--- @param path string
--- @return boolean
function M.glob_match(glob, path)
  local pattern = M.glob_to_pattern(glob)
  return path:match(pattern) ~= nil
end

--- 简单 Markdown 段落清洗（去除过多空行）
--- @param s string
--- @return string
function M.clean_text(s)
  return (s:gsub("\n[ \t]*\n+", "\n\n"):gsub("%s+$", ""))
end

--- 判定指定位置是否存在合法 UTF-8 序列，返回其长度；非法则返回 0
--- @param s string
--- @param i number 起始字节位置（1 索引）
--- @return number
local function _utf8_sequence_len(s, i)
  local b1 = s:byte(i)
  if not b1 then return 0 end
  if b1 <= 0x7F then return 1 end
  local len = 1
  local lo, hi = 0, 0
  if b1 >= 0xC2 and b1 <= 0xDF then
    len = 2
  elseif b1 >= 0xE0 and b1 <= 0xEF then
    len = 3
    if b1 == 0xE0 then lo = 0xA0
    elseif b1 == 0xED then hi = 0x9F end
  elseif b1 >= 0xF0 and b1 <= 0xF4 then
    len = 4
    if b1 == 0xF0 then lo = 0x90
    elseif b1 == 0xF4 then hi = 0x8F end
  else
    return 0 -- 非法首字节（0x80-0xC1、0xF5-0xFF）
  end
  if i + len - 1 > #s then return 0 end
  local b2 = s:byte(i + 1)
  if b2 < 0x80 or b2 > 0xBF then return 0 end
  if lo > 0 and b2 < lo then return 0 end
  if hi > 0 and b2 > hi then return 0 end
  for k = 3, len do
    local b = s:byte(i + k - 1)
    if b < 0x80 or b > 0xBF then return 0 end
  end
  return len
end

--- 将字符串修复为合法 UTF-8：非法字节序替换为 U+FFFD（替换字符）
--- vim.json.encode 会把非法 UTF-8 字节原样透传进 JSON 输出，导致对方严格 JSON
--- 解析器报 "invalid unicode code point"。本函数在编码前清洗，保持合法内容不变。
--- @param s string|nil
--- @return string|nil
function M.sanitize_utf8(s)
  if not s or s == "" then return s end
  local i, n = 1, #s
  local changed = false
  while i <= n do
    local len = _utf8_sequence_len(s, i)
    if len == 0 then
      changed = true
      i = i + 1
    else
      i = i + len
    end
  end
  if not changed then return s end
  local buf = {}
  i = 1
  while i <= n do
    local len = _utf8_sequence_len(s, i)
    if len == 0 then
      buf[#buf + 1] = "\xef\xbf\xbd" -- U+FFFD
      i = i + 1
    else
      buf[#buf + 1] = s:sub(i, i + len - 1)
      i = i + len
    end
  end
  return table.concat(buf)
end

return M
