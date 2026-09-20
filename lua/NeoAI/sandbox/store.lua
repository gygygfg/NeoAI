--- 沙箱持久化存储：候选与发布回执
--- @module NeoAI.sandbox.store
--- 状态与文件系统不共享事务，通过可查询回执对账（设计文档 §4.5/§6.3）。

local json = require("NeoAI.utils.json")
local fs = require("NeoAI.utils.fs")
local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有状态 ==========

local state = {
  root = nil,
}

-- 快照读缓存：`list_saved` 每次刷新都为每个已保存项读盘 + JSON 解码；待审/已保存
-- 堆积时是主线程热点。写入/删除快照时失效，reset 清空。
local snapshot_cache = {}

-- 异步落盘（write-behind）：候选/待审体积大（含文件内容），主线程 JSON 编码 + fsync 写入
-- 会在大候选时卡顿。这里把**文件写入**移到线程池，主线程只做编码；写入按路径串行化
-- （同路径后写覆盖先写），并以 `mem` 缓存保证「刚写入即可读回」的语义。
local write_state = {
  mem = {},       -- path -> encoded（最新请求内容，供同步读取命中）
  pending = {},   -- path -> encoded（等待写入的最新内容）
  running = {},   -- path -> true（正在写）
  cancelled = {}, -- path -> true（写入期间被删除，完成后清理）
  gen = 0,        -- 代次：reset 后使在途完成回调失效
}

local function _candidates_dir()
  return state.root .. "/candidates"
end

local function _receipts_dir()
  return state.root .. "/receipts"
end

local function _reviews_dir()
  return state.root .. "/reviews"
end

local function _evidence_dir()
  return state.root .. "/evidence"
end

local function _host_ops_dir()
  return state.root .. "/host_ops"
end

local function _snapshots_dir()
  return state.root .. "/snapshots"
end

--- @return boolean ok
local function _ensure_dirs()
  if not state.root then return false end
  fs.ensure_dir(_candidates_dir())
  fs.ensure_dir(_receipts_dir())
  fs.ensure_dir(_reviews_dir())
  fs.ensure_dir(_evidence_dir())
  fs.ensure_dir(_host_ops_dir())
  fs.ensure_dir(_snapshots_dir())
  -- 存储根与子目录收紧到 0700：候选/证据含未发布内容与命令详情，避免同机其他用户枚举/读取。
  -- （同 uid 的本地进程属信任边界之外，无法靠权限或摘要防住——见 docs/sandbox.md。）
  for _, d in ipairs({ state.root, _candidates_dir(), _receipts_dir(), _reviews_dir(), _evidence_dir(), _host_ops_dir(), _snapshots_dir() }) do
    pcall(vim.uv.fs_chmod, d, 448) -- 0700
  end
  return true
end

-- ========== 公开 API ==========

--- @param digest string
--- @return string 安全文件名
local function _safe_name(digest)
  return (digest or "unknown"):gsub("[^%w_%-]", "_")
end

-- ========== 异步落盘（write-behind） ==========

--- 线程内原子写：同目录 mkstemp + write + rename（无需 fsync；候选/待审是缓存性质，
--- 崩溃丢失最后一笔由启动重新物化/对账兜底）。返回 "\1" 成功 / "\0<err>" 失败。
--- @param path string
--- @param encoded string
--- @return string
local function _atomic_write_worker(path, encoded)
  local uv = vim.uv
  local fd, tmp = uv.fs_mkstemp(path .. ".tmp.XXXXXX")
  if not fd then return "\0" .. tostring(tmp) end
  local offset = 0
  while offset < #encoded do
    local n, err = uv.fs_write(fd, encoded:sub(offset + 1), offset)
    if not n or n == 0 then
      uv.fs_close(fd); uv.fs_unlink(tmp)
      return "\0" .. tostring(err)
    end
    offset = offset + n
  end
  uv.fs_close(fd)
  local ok, err = uv.fs_rename(tmp, path)
  if not ok then uv.fs_unlink(tmp); return "\0" .. tostring(err) end
  return "\1"
end

--- 写入队列推进：同路径串行；完成后若有更新内容则继续写最新一份。
--- @param path string
local function _drain(path)
  if write_state.running[path] then return end
  local encoded = write_state.pending[path]
  if encoded == nil then return end
  write_state.pending[path] = nil
  write_state.running[path] = true
  local gen = write_state.gen
  local function done()
    write_state.running[path] = nil
    if write_state.gen ~= gen or write_state.cancelled[path] then
      -- reset/删除后到达的写入：清理，避免污染新实例存储。
      pcall(fs.delete_file, path)
      write_state.cancelled[path] = nil
      write_state.mem[path] = nil
    elseif write_state.pending[path] ~= nil then
      _drain(path)
    else
      -- 已落盘：丢弃缓存，避免长时间会话内存无界增长（读取回退磁盘）。
      write_state.mem[path] = nil
    end
  end
  local work = require("NeoAI.utils.work")
  if not work.available() then
    pcall(_atomic_write_worker, path, encoded)
    done()
    return
  end
  work.run(_atomic_write_worker, path, encoded):then_(done, done)
end

--- 请求异步写入（最新内容覆盖旧请求），并缓存供同步读取命中。
--- @param path string
--- @param encoded string
local function _async_write(path, encoded)
  write_state.mem[path] = encoded
  write_state.pending[path] = encoded
  _drain(path)
end

--- 取消某路径的待写/缓存，并标记在途写入完成后清理（删除后不被迟到的写入复活）。
--- @param path string
local function _cancel_write(path)
  write_state.mem[path] = nil
  write_state.pending[path] = nil
  if write_state.running[path] then write_state.cancelled[path] = true end
end

--- 读取 JSON：优先命中异步写缓存，其次读盘。
--- @param path string
--- @return table|nil
local function _read_json(path)
  local encoded = write_state.mem[path]
  if encoded == nil then encoded = fs.read_file(path) end
  if not encoded then return nil end
  local ok, decoded = pcall(json.decode, encoded)
  if not ok then return nil end
  return decoded
end

--- 列出 dir 下的 JSON 条目：以磁盘为准，但**异步写缓存（最新）覆盖**同路径的旧磁盘内容，
--- 避免「刚更新（如 REJECTED）但尚未落盘」时读到旧版本（如 PENDING）。
--- @param dir string
--- @return table 数组
local function _list_json_dir(dir)
  local by_path = {}
  local handle = vim.uv.fs_scandir(dir)
  if handle then
    while true do
      local name = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if name:sub(-5) == ".json" then
        local path = dir .. "/" .. name
        local content = fs.read_file(path)
        if content then
          local ok, decoded = pcall(json.decode, content)
          if ok and decoded then by_path[path] = decoded end
        end
      end
    end
  end
  for path, encoded in pairs(write_state.mem) do
    if path:sub(1, #dir + 1) == dir .. "/" then
      local ok, decoded = pcall(json.decode, encoded)
      if ok and decoded then by_path[path] = decoded end
    end
  end
  local out = {}
  for _, v in pairs(by_path) do out[#out + 1] = v end
  return out
end

--- 等待所有异步写入落盘（测试/关闭/reset 前调用，保证不丢数据、不被迟到写入污染）。
--- @param timeout_ms number|nil
--- @return boolean 是否已清空
function M.flush(timeout_ms)
  local deadline = vim.uv.hrtime() + (timeout_ms or 5000) * 1e6
  while true do
    local busy = false
    for _ in pairs(write_state.running) do busy = true; break end
    if not busy then
      for _ in pairs(write_state.pending) do busy = true; break end
    end
    if not busy then return true end
    if vim.uv.hrtime() > deadline then return false end
    vim.wait(10, function() return false end)
  end
end

--- 初始化存储根目录
--- @param root string
function M.init(root)
  state.root = root
  _ensure_dirs()
end

--- @return string|nil
function M.root()
  return state.root
end

--- 写入候选（冻结）
--- @param candidate table
--- @return boolean ok
function M.write_candidate(candidate)
  if require("NeoAI.sandbox.fault").hit("store") then return false, "injected store failure" end
  if not _ensure_dirs() then return false end
  local path = _candidates_dir() .. "/" .. _safe_name(candidate.candidate_digest) .. ".json"
  local ok, err = fs.write_file_atomic(path, json.encode(candidate))
  if not ok then return false, err end
  return true
end

--- 异步写入候选：编码在主线程（vim.json 为 C 实现），文件写入移入线程池，
--- 大候选不再阻塞主线程等待 fsync/磁盘。写入后立即可经 `read_candidate` 读回（内存缓存）。
--- @param candidate table
--- @return Deferred resolve(boolean)
function M.write_candidate_async(candidate)
  if require("NeoAI.sandbox.fault").hit("store") then
    return async.reject({ kind = "store", message = "injected store failure" })
  end
  if not _ensure_dirs() then return async.resolve(false) end
  local path = _candidates_dir() .. "/" .. _safe_name(candidate.candidate_digest) .. ".json"
  _async_write(path, json.encode(candidate))
  return async.resolve(true)
end

--- 读取候选
--- @param digest string
--- @return table|nil
function M.read_candidate(digest)
  if not state.root then return nil end
  return _read_json(_candidates_dir() .. "/" .. _safe_name(digest) .. ".json")
end

--- 列出候选（按创建时间倒序）
--- @return table 数组
function M.list_candidates()
  if not state.root then return {} end
  local out = _list_json_dir(_candidates_dir())
  table.sort(out, function(a, b) return (a.created_at or 0) > (b.created_at or 0) end)
  return out
end

--- 删除候选
--- @param digest string
--- @return boolean
function M.discard_candidate(digest)
  if not state.root then return false end
  local path = _candidates_dir() .. "/" .. _safe_name(digest) .. ".json"
  _cancel_write(path)
  return fs.delete_file(path)
end

--- 写入发布回执（按 operation_id 可查询，重启后返回同一结果）
--- @param receipt table
--- @return boolean ok
function M.write_receipt(receipt)
  if not _ensure_dirs() then return false end
  local path = _receipts_dir() .. "/" .. _safe_name(receipt.operation_id) .. ".json"
  return fs.write_file_atomic(path, json.encode(receipt))
end

--- 读取发布回执
--- @param operation_id string
--- @return table|nil
function M.read_receipt(operation_id)
  if not state.root then return nil end
  local path = _receipts_dir() .. "/" .. _safe_name(operation_id) .. ".json"
  local content = fs.read_file(path)
  if not content then return nil end
  local ok, decoded = pcall(json.decode, content)
  if not ok then return nil end
  return decoded
end

--- 写入变更单元（异步审批）
--- @param item table
--- @return boolean ok
function M.write_review(item)
  if not _ensure_dirs() then return false end
  local path = _reviews_dir() .. "/" .. _safe_name(item.change_set_id) .. ".json"
  return fs.write_file_atomic(path, json.encode(item))
end

--- 异步写入变更单元：文件写入移入线程池，写入后立即可读回（内存缓存）。
--- @param item table
--- @return Deferred resolve(boolean)
function M.write_review_async(item)
  if not _ensure_dirs() then return async.resolve(false) end
  local path = _reviews_dir() .. "/" .. _safe_name(item.change_set_id) .. ".json"
  _async_write(path, json.encode(item))
  return async.resolve(true)
end

--- 读取变更单元
--- @param change_set_id string
--- @return table|nil
function M.read_review(change_set_id)
  if not state.root then return nil end
  return _read_json(_reviews_dir() .. "/" .. _safe_name(change_set_id) .. ".json")
end

--- 列出全部变更单元
--- @return table 数组
function M.list_reviews()
  if not state.root then return {} end
  local out = _list_json_dir(_reviews_dir())
  table.sort(out, function(a, b) return (a.created_at or 0) < (b.created_at or 0) end)
  return out
end

--- 删除变更单元
--- @param change_set_id string
--- @return boolean
function M.delete_review(change_set_id)
  if not state.root then return false end
  local path = _reviews_dir() .. "/" .. _safe_name(change_set_id) .. ".json"
  _cancel_write(path)
  return fs.delete_file(path)
end

--- 写入证据记录
--- @param record table { evidence_id }
--- @return boolean ok
function M.write_evidence(record)
  if not _ensure_dirs() then return false end
  local path = _evidence_dir() .. "/" .. _safe_name(record.evidence_id) .. ".json"
  return fs.write_file_atomic(path, json.encode(record))
end

--- 读取证据记录
--- @param evidence_id string
--- @return table|nil
function M.read_evidence(evidence_id)
  if not state.root then return nil end
  local path = _evidence_dir() .. "/" .. _safe_name(evidence_id) .. ".json"
  local content = fs.read_file(path)
  if not content then return nil end
  local ok, decoded = pcall(json.decode, content)
  if not ok then return nil end
  return decoded
end

--- 列出全部证据记录（按创建时间）
--- @return table 数组
function M.list_evidence()  if not state.root then return {} end
  local out = {}
  local dir = _evidence_dir()
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return out end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if name:sub(-5) == ".json" then
      local content = fs.read_file(dir .. "/" .. name)
      if content then
        local ok, decoded = pcall(json.decode, content)
        if ok and decoded then out[#out + 1] = decoded end
      end
    end
  end
  table.sort(out, function(a, b) return (a.created_at or 0) < (b.created_at or 0) end)
  return out
end

--- 删除证据记录
--- @param evidence_id string
--- @return boolean
function M.delete_evidence(evidence_id)
  if not state.root then return false end
  local path = _evidence_dir() .. "/" .. _safe_name(evidence_id) .. ".json"
  return fs.delete_file(path)
end

--- 写入主机操作提案（T2 主机效果，待异步审批后 replay）
--- @param record table { host_op_id }
--- @return boolean ok
function M.write_host_op(record)
  if not _ensure_dirs() then return false end
  local path = _host_ops_dir() .. "/" .. _safe_name(record.host_op_id) .. ".json"
  return fs.write_file_atomic(path, json.encode(record))
end

--- 读取主机操作提案
--- @param host_op_id string
--- @return table|nil
function M.read_host_op(host_op_id)
  if not state.root then return nil end
  local path = _host_ops_dir() .. "/" .. _safe_name(host_op_id) .. ".json"
  local content = fs.read_file(path)
  if not content then return nil end
  local ok, decoded = pcall(json.decode, content)
  if not ok then return nil end
  return decoded
end

--- 列出主机操作提案（按创建时间）
--- @return table 数组
function M.list_host_ops()
  if not state.root then return {} end
  local out = {}
  local dir = _host_ops_dir()
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return out end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if name:sub(-5) == ".json" then
      local content = fs.read_file(dir .. "/" .. name)
      if content then
        local ok, decoded = pcall(json.decode, content)
        if ok and decoded then out[#out + 1] = decoded end
      end
    end
  end
  table.sort(out, function(a, b) return (a.created_at or 0) < (b.created_at or 0) end)
  return out
end

--- 删除主机操作提案
--- @param host_op_id string
--- @return boolean
function M.delete_host_op(host_op_id)
  if not state.root then return false end
  local path = _host_ops_dir() .. "/" .. _safe_name(host_op_id) .. ".json"
  return fs.delete_file(path)
end

--- 写入应用快照（保存时保留原文件版本，供撤销保存时交换）
--- @param record table { snapshot_id }
--- @return boolean ok
function M.write_snapshot(record)
  if not _ensure_dirs() then return false end
  local path = _snapshots_dir() .. "/" .. _safe_name(record.snapshot_id) .. ".json"
  local ok = fs.write_file_atomic(path, json.encode(record))
  if ok then snapshot_cache[record.snapshot_id] = nil end
  return ok
end

--- 读取应用快照
--- @param snapshot_id string
--- @return table|nil
function M.read_snapshot(snapshot_id)
  if not state.root then return nil end
  local cached = snapshot_cache[snapshot_id]
  if cached ~= nil then return cached or nil end
  local path = _snapshots_dir() .. "/" .. _safe_name(snapshot_id) .. ".json"
  local content = fs.read_file(path)
  if not content then
    snapshot_cache[snapshot_id] = false -- 负缓存：避免重复读不存在的快照
    return nil
  end
  local ok, decoded = pcall(json.decode, content)
  if not ok or not decoded then return nil end
  snapshot_cache[snapshot_id] = decoded
  return decoded
end

--- 删除应用快照
--- @param snapshot_id string
--- @return boolean
function M.delete_snapshot(snapshot_id)
  if not state.root then return false end
  snapshot_cache[snapshot_id] = nil
  local path = _snapshots_dir() .. "/" .. _safe_name(snapshot_id) .. ".json"
  return fs.delete_file(path)
end

--- 列出全部应用快照
--- @return table 数组
function M.list_snapshots()
  if not state.root then return {} end
  local out = {}
  local dir = _snapshots_dir()
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return out end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if name:sub(-5) == ".json" then
      local content = fs.read_file(dir .. "/" .. name)
      if content then
        local ok, decoded = pcall(json.decode, content)
        if ok and decoded then out[#out + 1] = decoded end
      end
    end
  end
  table.sort(out, function(a, b) return (a.created_at or 0) < (b.created_at or 0) end)
  return out
end

--- 重置（测试用）：清理落盘候选/回执/变更单元/证据/快照并清空根目录
function M.reset()
  -- 先等异步写入落盘：否则 reset 后迟到的写入会重建文件、污染后续用例/实例。
  pcall(M.flush, 5000)
  write_state.gen = write_state.gen + 1
  write_state.mem = {}
  write_state.pending = {}
  write_state.running = {}
  write_state.cancelled = {}
  snapshot_cache = {}
  if state.root then
    pcall(vim.fn.delete, _candidates_dir(), "rf")
    pcall(vim.fn.delete, _receipts_dir(), "rf")
    pcall(vim.fn.delete, _reviews_dir(), "rf")
    pcall(vim.fn.delete, _evidence_dir(), "rf")
    pcall(vim.fn.delete, _host_ops_dir(), "rf")
    pcall(vim.fn.delete, _snapshots_dir(), "rf")
  end
  state.root = nil
end

return M
