--- 沙箱证据服务
--- @module NeoAI.sandbox.evidence
--- 保存事实、回执与过程观测；证据与裁决分离，按需分页读取（设计文档 §8/§10）。
--- 证据只描述观测，不代替裁决；写入前对秘密字段脱敏，限制单条大小。

local json = require("NeoAI.utils.json")
local store = require("NeoAI.sandbox.store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  seq = 0,
}

-- 需要脱敏的字段名（小写匹配）
local SECRET_KEYS = {
  ["api_key"] = true, ["apikey"] = true, ["token"] = true, ["secret"] = true,
  ["password"] = true, ["passwd"] = true, ["authorization"] = true, ["bearer"] = true,
  ["private_key"] = true, ["access_key"] = true, ["client_secret"] = true,
}

-- 单条证据最大字节（超出截断）
local MAX_BYTES = 64 * 1024

-- 单条证据最多保留的文件条目数（超出仅保留前 N 条并标注总数）。
-- 避免大候选（包安装/构建产物上千文件）在证据里做无意义的巨量 JSON 编码。
local MAX_FILES = 500

-- ========== 私有函数 ==========

--- 浅拷贝并截断 payload.files，避免对超大数组做深拷贝（内容本就不应进入证据）。
--- @param payload any
--- @return any
local function _cap_payload(payload)
  if type(payload) ~= "table" then return payload end
  local files = payload.files
  if type(files) ~= "table" or #files <= MAX_FILES then return payload end
  local out = {}
  for k, v in pairs(payload) do out[k] = v end
  local kept = {}
  for i = 1, MAX_FILES do kept[i] = files[i] end
  out.files = kept
  out.files_total = #files
  out.files_truncated = true
  return out
end

--- 递归脱敏
--- @param value any
--- @param depth number
--- @return any
local function _redact(value, depth)
  depth = depth or 0
  if depth > 8 then return "[depth-limit]" end
  local t = type(value)
  if t == "table" then
    local out = {}
    for k, v in pairs(value) do
      local key = tostring(k):lower()
      if SECRET_KEYS[key] then
        out[k] = "[redacted]"
      else
        out[k] = _redact(v, depth + 1)
      end
    end
    return out
  end
  if t == "string" then
    -- 低熵秘密不通过裸哈希暴露；这里仅做长度截断
    if #value > 4096 then return value:sub(1, 4096) .. "…[truncated]" end
    return value
  end
  return value
end

-- ========== 公开 API ==========

--- 记录一条证据
--- @param kind string "fs" | "process" | "network" | "decision" | "observation"
--- @param payload table
--- @param meta table|nil { command_id?, attempt_id?, change_set_id?, tool?, source?, coverage? }
--- @return string evidence_id
function M.add(kind, payload, meta)
  meta = meta or {}
  state.seq = state.seq + 1
  local id = string.format("evidence_%d_%s", state.seq, tostring(os.time()))
  local record = {
    evidence_id = id,
    kind = kind,
    source = meta.source or "observed",
    coverage = meta.coverage or "partial",
    command_id = meta.command_id,
    attempt_id = meta.attempt_id,
    change_set_id = meta.change_set_id,
    tool = meta.tool,
    created_at = os.time(),
    payload = _redact(_cap_payload(payload)),
  }
  local encoded = json.encode(record)
  if #encoded > MAX_BYTES then
    record.payload = { truncated = true, preview = encoded:sub(1, MAX_BYTES) }
  end
  pcall(store.write_evidence, record)
  return id
end

--- 读取证据
--- @param evidence_id string
--- @return table|nil
function M.get(evidence_id)
  return store.read_evidence(evidence_id)
end

--- 分页读取证据
--- @param opts table|nil { kind?, after_id?, limit? }
--- @return table { items, next_cursor, total }
function M.page(opts)
  opts = opts or {}
  local limit = opts.limit or 10
  local all = store.list_evidence()
  local items = {}
  local seen = false
  local start = not opts.after_id
  for _, rec in ipairs(all) do
    if start and (not opts.kind or rec.kind == opts.kind) then
      items[#items + 1] = rec
    end
    if rec.evidence_id == opts.after_id then start = true end
  end
  local total = #items
  local page = {}
  for i = 1, math.min(limit, #items) do page[i] = items[i] end
  local next_cursor = nil
  if #items > limit then next_cursor = page[#page].evidence_id end
  return { items = page, next_cursor = next_cursor, total = total }
end

--- 按保留期清理证据（默认保留裁决记录，供策略回放）
--- @param days number
--- @param opts table|nil { keep_kinds? }
--- @return number removed
function M.prune(days, opts)
  opts = opts or {}
  local keep = {}
  for _, k in ipairs(opts.keep_kinds or { "decision" }) do keep[k] = true end
  local cutoff = os.time() - (days or 7) * 86400
  local removed = 0
  for _, rec in ipairs(store.list_evidence()) do
    if (rec.created_at or 0) < cutoff and not keep[rec.kind] then
      if store.delete_evidence(rec.evidence_id) then removed = removed + 1 end
    end
  end
  return removed
end

--- 重置（测试用）
function M.reset()
  state.seq = 0
end

return M
