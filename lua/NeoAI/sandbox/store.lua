--- 沙箱持久化存储：候选与发布回执
--- @module NeoAI.sandbox.store
--- 状态与文件系统不共享事务，通过可查询回执对账（设计文档 §4.5/§6.3）。

local json = require("NeoAI.utils.json")
local fs = require("NeoAI.utils.fs")

local M = {}

-- ========== 私有状态 ==========

local state = {
  root = nil,
}

-- ========== 私有函数 ==========

--- @param digest string
--- @return string 安全文件名
local function _safe_name(digest)
  return (digest or "unknown"):gsub("[^%w_%-]", "_")
end

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

--- 读取候选
--- @param digest string
--- @return table|nil
function M.read_candidate(digest)
  if not state.root then return nil end
  local path = _candidates_dir() .. "/" .. _safe_name(digest) .. ".json"
  local content = fs.read_file(path)
  if not content then return nil end
  local ok, decoded = pcall(json.decode, content)
  if not ok then return nil end
  return decoded
end

--- 列出候选（按创建时间倒序）
--- @return table 数组
function M.list_candidates()
  if not state.root then return {} end
  local out = {}
  local dir = _candidates_dir()
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
  table.sort(out, function(a, b) return (a.created_at or 0) > (b.created_at or 0) end)
  return out
end

--- 删除候选
--- @param digest string
--- @return boolean
function M.discard_candidate(digest)
  if not state.root then return false end
  local path = _candidates_dir() .. "/" .. _safe_name(digest) .. ".json"
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

--- 读取变更单元
--- @param change_set_id string
--- @return table|nil
function M.read_review(change_set_id)
  if not state.root then return nil end
  local path = _reviews_dir() .. "/" .. _safe_name(change_set_id) .. ".json"
  local content = fs.read_file(path)
  if not content then return nil end
  local ok, decoded = pcall(json.decode, content)
  if not ok then return nil end
  return decoded
end

--- 列出全部变更单元
--- @return table 数组
function M.list_reviews()
  if not state.root then return {} end
  local out = {}
  local dir = _reviews_dir()
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

--- 删除变更单元
--- @param change_set_id string
--- @return boolean
function M.delete_review(change_set_id)
  if not state.root then return false end
  local path = _reviews_dir() .. "/" .. _safe_name(change_set_id) .. ".json"
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
  return fs.write_file_atomic(path, json.encode(record))
end

--- 读取应用快照
--- @param snapshot_id string
--- @return table|nil
function M.read_snapshot(snapshot_id)
  if not state.root then return nil end
  local path = _snapshots_dir() .. "/" .. _safe_name(snapshot_id) .. ".json"
  local content = fs.read_file(path)
  if not content then return nil end
  local ok, decoded = pcall(json.decode, content)
  if not ok then return nil end
  return decoded
end

--- 删除应用快照
--- @param snapshot_id string
--- @return boolean
function M.delete_snapshot(snapshot_id)
  if not state.root then return false end
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
