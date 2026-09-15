--- 沙箱观测（合并原 impact + envelope）
--- @module NeoAI.sandbox.observe
--- 影响模型（fs/process/network，未知用 null）与裁决信封（decision/severity/stats/asks/evidence）。
--- 原 `sandbox/impact` 与 `sandbox/envelope` 保留为兼容 shim（转指本模块）。

local M = {}

-- ========== 影响模型（原 sandbox/impact） ==========

local function _count(tbl)
  local n = 0
  for _ in pairs(tbl) do n = n + 1 end
  return n
end

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

-- ========== 裁决信封（原 sandbox/envelope） ==========

local SCHEMA_VERSION = "2.0"
local MAX_ASKS = 5
local MAX_EVIDENCE = 10

local function _valid_decision(d)
  return d == "ALLOW" or d == "DENY" or d == "NEEDS_CONFIRMATION"
end

local function _valid_severity(s)
  return s == "INFO" or s == "LOW" or s == "HIGH" or s == "CRITICAL"
end

--- 构建裁决信封
--- @param opts table
--- @return table
function M.build(opts)
  opts = opts or {}
  local decision = _valid_decision(opts.decision) and opts.decision or "NEEDS_CONFIRMATION"
  local severity = _valid_severity(opts.severity) and opts.severity or "LOW"
  local asks = opts.asks or {}
  local evidence = opts.evidence or {}
  local truncated = #asks > MAX_ASKS or #evidence > MAX_EVIDENCE
  local asks_page = {}
  for i = 1, math.min(#asks, MAX_ASKS) do asks_page[i] = asks[i] end
  local evidence_page = {}
  for i = 1, math.min(#evidence, MAX_EVIDENCE) do evidence_page[i] = evidence[i] end

  return {
    schema_version = SCHEMA_VERSION,
    command_id = opts.command_id,
    attempt_id = opts.attempt_id,
    state = opts.state,
    decision = decision,
    severity = severity,
    prediction_status = opts.prediction_status or "partial",
    reason_codes = opts.reason_codes or {},
    candidate_digest = opts.candidate_digest,
    stats = opts.stats or {},
    asks = asks_page,
    asks_total = #asks,
    truncated = truncated,
    evidence = evidence_page,
    result_payload = opts.result_payload or { trust = "untrusted", text_preview = "", truncated = false, cursor = nil },
    retryable = opts.retryable == true,
    next_action = opts.next_action or "none",
  }
end

--- 将信封渲染为附加到工具结果的紧凑文本
--- @param env table
--- @return string
function M.to_text(env)
  local parts = { string.format("[沙箱] decision=%s severity=%s state=%s", env.decision, env.severity, tostring(env.state)) }
  if env.candidate_digest then parts[#parts + 1] = "candidate=" .. env.candidate_digest end
  if env.reason_codes and #env.reason_codes > 0 then
    parts[#parts + 1] = "reasons=" .. table.concat(env.reason_codes, ",")
  end
  if env.asks_total and env.asks_total > 0 then
    local id = env.asks[1] and env.asks[1].id or "?"
    parts[#parts + 1] = string.format("asks=%d (首个 %s)", env.asks_total, tostring(id))
  end
  if env.next_action and env.next_action ~= "none" then parts[#parts + 1] = "next=" .. env.next_action end
  return table.concat(parts, " ")
end

M.SCHEMA_VERSION = SCHEMA_VERSION
M.MAX_ASKS = MAX_ASKS
M.MAX_EVIDENCE = MAX_EVIDENCE

return M
