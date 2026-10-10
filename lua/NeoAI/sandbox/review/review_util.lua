--- 异步审批纯助手
--- @module NeoAI.sandbox.review.review_util
--- 从 review.lua 抽出的无状态纯函数（不引用模块状态；内部相互调用保持原样）。

local function _content_limit()
  local n = tonumber(require("NeoAI.kernel.config_store").get(
    "tools.sandbox.review.content_cache_max"))
  if n == nil then n = 64 end
  return math.max(0, n)
end

local function _emit(event, payload)
  local event_bus = require("NeoAI.kernel.event_bus")
  event_bus.emit(event, payload or {})
end

--- 落盘后剥离内存 item 的文件内容：候选已单独落盘（`read_candidate` 可读回），
--- 长期持有 content 会让暂存上千文件时内存翻倍。diff 预览经 `M.content_for` 按需读取。
--- @param item table
local function _strip_content(item)
  if type(item) ~= "table" or type(item.files) ~= "table" then return end
  for _, f in ipairs(item.files) do
    if type(f) == "table" and f.content ~= nil then f.content = nil end
  end
end

--- 部分取代增量中被覆盖的路径数量。
--- @param item table
--- @return number
local function _superseded_count(item)
  local sup = item and item.superseded_paths
  if type(sup) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(sup) do n = n + 1 end
  return n
end

--- 大文件 stat 签名（与 candidate 同口径）：不读取内容做 CAS，避免读取数百 MB。
--- @param st table|nil
--- @return string|nil
local function _stat_sig(st)
  if not (st and st.type == "file" and st.mtime) then return nil end
  return string.format("sig:%s:%s:%s",
    tostring(st.mtime.sec), tostring(st.mtime.nsec), tostring(st.size))
end

--- 读取文件内容（不存在返回 nil）
--- @param path string
--- @return string|nil
local function _read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

--- 快照单文件内容上限（与候选同源配置，避免删除大文件时读入/落盘巨量内容）
--- @return number
local function _snapshot_cap()
  local n = tonumber(require("NeoAI.kernel.config_store").get("tools.sandbox.max_file_bytes"))
  if n == nil then return 8 * 1024 * 1024 end
  return n
end

--- 快照撤销 CAS 模式："sig"（默认，mtime/size 签名，省去逐文件读取+哈希）| "hash"（最强一致性）。
--- @return string
local function _snapshot_cas_mode()
  local m = require("NeoAI.kernel.config_store").get("tools.sandbox.review.snapshot_cas")
  if m == "hash" then return "hash" end
  return "sig"
end

--- 从候选构造写集合（供展示与选择性应用）
--- @param cand table
--- @return table 数组
local function _write_set(cand)
  local out = {}
  for _, f in ipairs(cand.files or {}) do out[#out + 1] = f.path end
  return out
end

--- 去重合并两个字符串数组（保留首次出现顺序）
--- @param a table|nil
--- @param b table|nil
--- @return table
local function _union(a, b)
  local out, seen = {}, {}
  for _, list in ipairs({ a or {}, b or {} }) do
    for _, v in ipairs(list) do
      if type(v) == "string" and not seen[v] then seen[v] = true; out[#out + 1] = v end
    end
  end
  return out
end

return {
  content_limit = _content_limit,
  emit = _emit,
  strip_content = _strip_content,
  superseded_count = _superseded_count,
  stat_sig = _stat_sig,
  read_file = _read_file,
  snapshot_cap = _snapshot_cap,
  snapshot_cas_mode = _snapshot_cas_mode,
  write_set = _write_set,
  union = _union,
}
