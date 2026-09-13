--- 沙箱影响模型
--- @module NeoAI.sandbox.impact
--- 统一影响分为 fs / process / network，每条标注 source / estimated|observed / coverage / evidence_id。
--- 字段缺失或未知用 null 表达，禁止以 0 代表未知（设计文档 §8）。

local M = {}

-- ========== 私有函数 ==========

local function _count(tbl)
  local n = 0
  for _ in pairs(tbl) do n = n + 1 end
  return n
end

-- ========== 公开 API ==========

--- 从候选生成 fs 影响记录
--- @param cand table
--- @param meta table { command_id?, attempt_id?, evidence_id? }
--- @return table 数组
function M.from_candidate(cand, meta)
  meta = meta or {}
  local out = {}
  for _, f in ipairs(cand.files or {}) do
    out[#out + 1] = {
      type = "fs",
      action = f.action,
      path = f.path,
      before_hash = f.before_hash,
      after_hash = f.after_hash,
      source = "observed",
      coverage = "partial",
      evidence_id = meta.evidence_id,
    }
  end
  return out
end

--- 生成 process 影响记录
--- @param info table { command?, code?, timed_out?, aborted?, attempt_id?, evidence_id? }
--- @return table
function M.process(info)
  info = info or {}
  return {
    type = "process",
    command = info.command,
    exit_code = info.code,
    timed_out = info.timed_out or false,
    aborted = info.aborted or false,
    source = "observed",
    coverage = "partial",
    evidence_id = info.evidence_id,
  }
end

--- 生成 network 影响记录（阶段一默认离线：仅记录拒绝事件）
--- @param info table
--- @return table
function M.network(info)
  info = info or {}
  return {
    type = "network",
    endpoint = info.endpoint,
    allowed = info.allowed or false,
    tx_bytes = info.tx_bytes,
    rx_bytes = info.rx_bytes,
    denied = info.denied or false,
    source = info.source or "observed",
    coverage = "partial",
    evidence_id = info.evidence_id,
  }
end

--- 汇总紧凑统计（未知用 null，不用 0 冒充）
--- @param impacts table 数组
--- @return table
function M.stats(impacts)
  local fs = { observed_creates = 0, observed_writes = 0, observed_deletes = 0, observed_mkdirs = 0 }
  local process = { observed_processes = 0, observed_peak_pids = nil }
  local network = { observed_tx_bytes = nil, estimated_tx_bytes = nil, denied = 0 }
  for _, i in ipairs(impacts or {}) do
    if i.type == "fs" then
      if i.action == "create" then fs.observed_creates = fs.observed_creates + 1
      elseif i.action == "modify" then fs.observed_writes = fs.observed_writes + 1
      elseif i.action == "delete" then fs.observed_deletes = fs.observed_deletes + 1
      elseif i.action == "mkdir" then fs.observed_mkdirs = fs.observed_mkdirs + 1
      end
    elseif i.type == "process" then
      process.observed_processes = process.observed_processes + 1
    elseif i.type == "network" then
      if i.denied then network.denied = network.denied + 1 end
      if i.tx_bytes then network.observed_tx_bytes = (network.observed_tx_bytes or 0) + i.tx_bytes end
      if i.rx_bytes then network.observed_tx_bytes = (network.observed_tx_bytes or 0) + i.rx_bytes end
    end
  end
  return { fs = fs, process = process, network = network }
end

--- 计数（测试/诊断）
--- @param impacts table
--- @return table type -> count
function M.count_by_type(impacts)
  local out = {}
  for _, i in ipairs(impacts or {}) do out[i.type] = (out[i.type] or 0) + 1 end
  return out
end

M._count = _count

return M
