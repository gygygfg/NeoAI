--- JSON 编解码
--- @module 'NeoAI.utils.json'
--- 优先使用 vim.json（Neovim 内置），回退到轻量纯 Lua 实现。

local M = {}

local vim_json_available = vim and vim.json and vim.json.encode

local strx = require("NeoAI.utils.stringx")

-- ========== 二进制无损编解码（内部持久化用） ==========
-- `encode`/`encode_fast` 为兼容严格 JSON 会把非法 UTF-8 字节清洗为 U+FFFD——对文本没问题，
-- 但会**损坏二进制文件内容**（如 OpenPGP keyring）。持久化候选/待审/快照时改用
-- `encode_lossless`/`decode_lossless`：非法 UTF-8 字符串以 base64 哨兵表无损保存，解码还原。
-- 普通文本的编码结果与 `encode` 完全一致；仅含非法字节时才产生哨兵。

local BYTES_KEY = "__neoai_bytes_b64__"

-- 二进制哨兵键（暴露给工作线程：线程内解码候选时需同一键名识别哨兵表）
M.BYTES_KEY = BYTES_KEY

local function _b64encode(s)
  if vim.base64 and vim.base64.encode then return vim.base64.encode(s) end
  return require("NeoAI.utils.image").base64_encode(s)
end

local function _b64decode(s)
  if vim.base64 and vim.base64.decode then return vim.base64.decode(s) end
  return require("NeoAI.utils.image").base64_decode(s)
end

--- 递归打包：非法 UTF-8 字符串 → base64 哨兵表；表键仍做 UTF-8 清洗（JSON 键须为字符串）。
--- @param v any
--- @return any
local function _pack_binary(v)
  local t = type(v)
  if t == "string" then
    if strx.is_valid_utf8(v) then return v end
    return { [BYTES_KEY] = true, d = _b64encode(v) }
  end
  if t ~= "table" then return v end
  local out = nil
  for k, val in pairs(v) do
    local nv = _pack_binary(val)
    local nk = k
    if type(k) == "string" and not strx.is_valid_utf8(k) then nk = strx.sanitize_utf8(k) end
    ---@cast nk -nil
    if nv ~= val or nk ~= k then
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

--- 递归还原哨兵表为原始字节串。
--- @param v any
--- @return any
local function _unpack_binary(v)
  if type(v) ~= "table" then return v end
  if v[BYTES_KEY] == true and type(v.d) == "string" then
    local ok, decoded = pcall(_b64decode, v.d)
    if ok and type(decoded) == "string" then return decoded end
  end
  local out = nil
  for k, val in pairs(v) do
    local nv = _unpack_binary(val)
    if nv ~= val then
      if not out then
        out = {}
        for k2, v2 in pairs(v) do out[k2] = v2 end
      end
      out[k] = nv
    end
  end
  return out or v
end

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

--- 快速编码：直接使用 vim.json（C 实现），**跳过** `_sanitize_value` 的全表 UTF-8 深扫。
--- 适用于大体积结构（如沙箱候选含大量文件内容）：深扫是纯 Lua 逐字节扫描，是主线程卡顿源。
--- 调用方须自行保证输出为合法 UTF-8（沙箱落盘路径在 worker 里校验，非法时回退 `encode`）。
--- 无 vim.json 时退回 `encode`（保证正确性优先）。
--- @param value any
--- @return string
function M.encode_fast(value)
  if vim_json_available then
    local ok, encoded = pcall(vim.json.encode, value)
    if ok then return encoded end
  end
  return M.encode(value)
end

-- ========== 编码卸载（纯 Lua UTF-8 校验下沉线程池） ==========
--
-- 为什么只把「校验」而不是「编码」下沉：LuaJIT 2.1 的字符串哈希按 **Lua state** 随机播种，
-- 工作线程是独立 state，`vim.json.encode` 在同一张表上的 **键顺序与主线程不同**，且每个
-- worker state 之间也不同。请求体 JSON 的键顺序若逐轮变化，服务端（DeepSeek/OpenAI）
-- 的前缀缓存会从第一个变化的键起全部失效——这是不可接受的回归。因此：
--   * 编码 `/` 键顺序：仍留在主线程（同一 state 内对同构表逐字节稳定）；
--   * UTF-8 全量深扫（`_sanitize_value`，纯 Lua 逐字节循环，O(上下文)）：下沉线程池校验。
-- 纯 ASCII 输出必然合法，用 C 级 `string.find` 快速判定即可（无需线程往返）。

--- 线程内校验字符串是否为合法 UTF-8（与 `stringx.sanitize_utf8` 同口径，自包含）。
--- 返回 "\1" 合法 / "\0" 非法（`work.run` 只能回传原始类型，故用标记串）。
--- @param s string
--- @return string
local function _validate_utf8_worker(s)
  local i, n = 1, #s
  while i <= n do
    local b1 = s:byte(i)
    if b1 <= 0x7F then
      i = i + 1
    else
      local len, lo, hi = 1, 0, 0
      if b1 >= 0xC2 and b1 <= 0xDF then
        len = 2
      elseif b1 >= 0xE0 and b1 <= 0xEF then
        len = 3
        if b1 == 0xE0 then lo = 0xA0 elseif b1 == 0xED then hi = 0x9F end
      elseif b1 >= 0xF0 and b1 <= 0xF4 then
        len = 4
        if b1 == 0xF0 then lo = 0x90 elseif b1 == 0xF4 then hi = 0x8F end
      else
        return "\0"
      end
      if i + len - 1 > n then return "\0" end
      local b2 = s:byte(i + 1)
      if b2 < 0x80 or b2 > 0xBF then return "\0" end
      if lo > 0 and b2 < lo then return "\0" end
      if hi > 0 and b2 > hi then return "\0" end
      for k = 3, len do
        local b = s:byte(i + k - 1)
        if b < 0x80 or b > 0xBF then return "\0" end
      end
      i = i + len
    end
  end
  return "\1"
end

--- 估算结构化值的文本规模（字节数上限 `limit`）。
--- 只做一次有界遍历统计字符串长度，不做任何编码/拷贝，用于决定是否值得卸载到线程池。
--- @param value any
--- @param limit number|nil 达到该上限即提前返回（默认无上限）
--- @return number
function M.estimate_bytes(value, limit)
  local cap = tonumber(limit) or math.huge
  local function walk(v, depth, acc)
    local t = type(v)
    if t == "string" then return acc + #v + 3 end
    if t == "number" or t == "boolean" then return acc + 8 end
    if t ~= "table" or depth <= 0 then return acc end
    for k, val in pairs(v) do
      if acc >= cap then return acc end
      if type(k) == "string" then acc = acc + #k + 4 end
      acc = walk(val, depth - 1, acc)
    end
    return acc
  end
  return walk(value, 8, 0)
end

-- 异步编码阈值：低于该规模的请求体直接同步编码（避免线程往返与一次调度延迟）。
M.ENCODE_ASYNC_MIN_BYTES = 48 * 1024

--- 是否值得把该值的编码卸载到线程池
--- @param value any
--- @param min_bytes number|nil
--- @return boolean
function M.should_encode_async(value, min_bytes)
  local threshold = tonumber(min_bytes) or M.ENCODE_ASYNC_MIN_BYTES
  local work = require("NeoAI.utils.work")
  if not work.available() then return false end
  return M.estimate_bytes(value, threshold) >= threshold
end

--- 异步 JSON 编码：与 `M.encode` 输出逐字节一致，但把 O(上下文) 的非法 UTF-8 深扫
--- 下沉到 `utils/work` 线程池。流程：
---   1. 主线程 `encode_fast`（C 实现，键顺序确定 → 前缀缓存稳定）；
---   2. 纯 ASCII 输出必然合法（C 级 `string.find`），直接返回，无线程往返；
---   3. 含非 ASCII 时把输出的 UTF-8 合法性校验交给 worker；
---   4. 校验发现非法字节 → 主线程回退 `M.encode`（U+FFFD 清洗，与旧行为一致）。
--- 低于 `min_bytes` 或线程池不可用时直接同步 `M.encode`（行为完全不变）。
--- @param value any
--- @param opts table|nil { min_bytes?: number }
--- @return Deferred resolve(string) 编码后的 JSON 字符串
function M.encode_async(value, opts)
  opts = opts or {}
  local async = require("NeoAI.utils.async")
  local work = require("NeoAI.utils.work")
  local min_bytes = tonumber(opts.min_bytes) or M.ENCODE_ASYNC_MIN_BYTES
  if not work.available() or M.estimate_bytes(value, min_bytes) < min_bytes then
    return async.resolve(M.encode(value))
  end
  local encoded = M.encode_fast(value)
  -- 纯 ASCII：一定是合法 UTF-8，等价于 `M.encode` 的结果（无需清洗）
  if not encoded:find("[\128-\255]") then
    return async.resolve(encoded)
  end
  return work.run(_validate_utf8_worker, encoded):then_(function(valid)
    if valid == "\1" then return encoded end
    -- 含非法 UTF-8（二进制工具输出等）：回退清洗编码（罕见路径，保持旧语义）
    return M.encode(value)
  end, function()
    -- 线程池异常：不冒险直接发送可能非法的 JSON，回退同步清洗编码
    return M.encode(value)
  end)
end

--- 编码为 JSON 字符串（含非法 UTF-8 清洗，保证输出可被严格解析器接受）
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

--- 无损编码：非法 UTF-8 字符串以 base64 哨兵表保存（解码由 `decode_lossless` 还原），
--- 其余与 `encode` 一致。用于内部持久化含二进制内容的记录（候选/待审/快照），避免
--- `sanitize_utf8` 把二进制数据替换为 U+FFFD 而损坏文件。
--- @param value any
--- @return string
function M.encode_lossless(value)
  value = _pack_binary(value)
  if vim_json_available then
    local ok, encoded = pcall(vim.json.encode, value)
    if ok then return encoded end
  end
  return M.encode(value)
end

-- ========== 解码 ==========

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
        -- 运行时（LuaJIT）无全局 utf8；保留动态探测以便有 utf8 库时使用。
        ---@diagnostic disable-next-line: undefined-global
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

--- 无损解码：解析 JSON 并还原 `encode_lossless` 写入的 base64 哨兵表（原始二进制字节）。
--- 仅在字符串中确实出现哨兵键时才做递归还原（普通文本走快路径）。
--- @param s string
--- @return any|nil 解析失败返回 nil
function M.decode_lossless(s)
  if type(s) ~= "string" then return nil end
  local decoded
  if vim_json_available then
    local ok, res = pcall(vim.json.decode, s)
    if not ok then return nil end
    decoded = res
  else
    local ok, res = pcall(M.decode, s)
    if not ok then return nil end
    decoded = res
  end
  if s:find(BYTES_KEY, 1, true) then return _unpack_binary(decoded) end
  return decoded
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
