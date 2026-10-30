--- 工具调用参数的紧凑预览
--- @module 'NeoAI.sandbox.review.args_preview'
---
--- 审批悬浮窗「调用参数」区只展示脱敏、限长的参数摘要：
---   * 大文本字段（content/old_string/new_string/patch/diff）只记录字节数，不落大内容；
---   * 展示值走密钥破坏性脱敏（`secret.redact`），避免把 token 写进 review JSON；
---   * 总量受 `max_chars` 约束，超出标记 truncated。
---
--- 输出结构（可直接持久化）：
---   { fields = { { key = "path", value = "..." }, ... },
---     omitted = { { key = "content", bytes = 1234 }, ... },
---     truncated = false }

local M = {}

-- 大文本参数：只记字节数（内容已在 diff / 候选里，无需重复展示/落盘）。
local LARGE_KEYS = {
  content = true,
  old_string = true,
  new_string = true,
  patch = true,
  diff = true,
  text = true,
  body = true,
}

-- 单值展示上限（字符）
local VALUE_MAX = 240
-- 表/数组参数编码后超过该长度即视为大值
local TABLE_MAX = 300

--- 单行化（预览不能含换行）
--- @param s any
--- @return string
local function _one_line(s)
  if s == nil then return "" end
  return (tostring(s):gsub("\r\n", "⏎"):gsub("[\r\n]", "⏎"))
end

--- 破坏性脱敏（密钥 → [REDACTED:*]）；secret 不可用时原样返回。
--- @param s string
--- @return string
local function _redact(s)
  if type(s) ~= "string" or s == "" then return s end
  local ok, secret = pcall(require, "NeoAI.sandbox.secret.secret")
  if ok and secret and type(secret.redact) == "function" then
    local ok2, out = pcall(secret.redact, s)
    if ok2 and type(out) == "string" then return out end
  end
  return s
end

--- 截断展示值
--- @param s string
--- @return string
local function _clip(s)
  if #s <= VALUE_MAX then return s end
  return s:sub(1, VALUE_MAX) .. "…"
end

--- 编码表参数
--- @param v any
--- @return string|nil
local function _encode(v)
  local ok, json = pcall(require, "NeoAI.utils.json")
  if not ok or not json or type(json.encode) ~= "function" then return nil end
  local ok2, s = pcall(function() return json.encode(v) end)
  if ok2 and type(s) == "string" then return s end
  return nil
end

--- 构建参数预览
--- @param args table|nil 工具调用参数
--- @param opts table|nil { max_chars?: number }
--- @return table|nil { fields, omitted, truncated }
function M.build(args, opts)
  if type(args) ~= "table" then return nil end
  local max_chars = tonumber(opts and opts.max_chars) or 2000
  if max_chars < 0 then max_chars = 0 end

  local keys = {}
  for k in pairs(args) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local fields, omitted = {}, {}
  local used, truncated = 0, false
  local function _add_field(key, value)
    local entry = { key = key, value = value }
    local size = #key + #value + 4
    if used + size > max_chars then
      truncated = true
      return false
    end
    used = used + size
    fields[#fields + 1] = entry
    return true
  end

  for _, raw_key in ipairs(keys) do
    local key = tostring(raw_key)
    local v = args[raw_key]
    if v ~= nil then
      local tv = type(v)
      if tv == "string" then
        if LARGE_KEYS[key] or #v > 512 then
          omitted[#omitted + 1] = { key = key, bytes = #v }
        elseif not _add_field(key, _clip(_redact(_one_line(v)))) then
          break
        end
      elseif tv == "number" or tv == "boolean" then
        if not _add_field(key, tostring(v)) then break end
      elseif tv == "table" then
        local js = _encode(v)
        if not js or #js > TABLE_MAX then
          omitted[#omitted + 1] = { key = key, bytes = #(js or ""), table = true }
        elseif not _add_field(key, _clip(_redact(_one_line(js)))) then
          break
        end
      else
        if not _add_field(key, _clip(_redact(_one_line(v)))) then break end
      end
    end
  end

  if #fields == 0 and #omitted == 0 then return nil end
  return { fields = fields, omitted = omitted, truncated = truncated }
end

--- 预览总项数（fields + omitted）
--- @param preview table|nil
--- @return number
function M.count(preview)
  if type(preview) ~= "table" then return 0 end
  return #(preview.fields or {}) + #(preview.omitted or {})
end

return M
