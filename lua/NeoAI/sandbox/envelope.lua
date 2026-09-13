--- 沙箱裁决信封
--- @module NeoAI.sandbox.envelope
--- 构建紧凑返回结构（设计文档 §8.1）：decision_envelope + result_payload + stats。
--- decision 仅 ALLOW / DENY / NEEDS_CONFIRMATION；severity 仅 INFO / LOW / HIGH / CRITICAL。

local M = {}

local SCHEMA_VERSION = "2.0"
local MAX_ASKS = 5
local MAX_EVIDENCE = 10

-- ========== 私有函数 ==========

local function _valid_decision(d)
  return d == "ALLOW" or d == "DENY" or d == "NEEDS_CONFIRMATION"
end

local function _valid_severity(s)
  return s == "INFO" or s == "LOW" or s == "HIGH" or s == "CRITICAL"
end

-- ========== 公开 API ==========

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
