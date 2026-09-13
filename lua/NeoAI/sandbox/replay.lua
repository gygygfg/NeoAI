--- 沙箱策略回放
--- @module NeoAI.sandbox.replay
--- 用同一版规则与同一事实重放，验证裁决可复现（设计文档 §10）。
--- 事实来自证据记录，不保存可直接重放的有效授权 bearer token。

local evidence = require("NeoAI.sandbox.evidence")
local policy = require("NeoAI.sandbox.policy")

local M = {}

-- ========== 私有函数 ==========

local function _policy_version()
  return require("NeoAI.kernel.config_store").get("tools.sandbox.policy.version") or "1"
end

local function _sorted_codes(codes)
  local out = {}
  for _, c in ipairs(codes or {}) do out[#out + 1] = tostring(c) end
  table.sort(out)
  return out
end

local function _same_codes(a, b)
  local x, y = _sorted_codes(a), _sorted_codes(b)
  if #x ~= #y then return false end
  for i = 1, #x do
    if x[i] ~= y[i] then return false end
  end
  return true
end

-- ========== 公开 API ==========

--- 记录一次裁决（含事实与策略版本）为证据
--- @param facts table
--- @param verdict table
--- @param meta table|nil
--- @return string evidence_id
function M.record(facts, verdict, meta)
  meta = meta or {}
  return evidence.add("decision", {
    facts = facts,
    verdict = { decision = verdict.decision, reason_codes = verdict.reason_codes or {} },
    policy_version = _policy_version(),
  }, meta)
end

--- 回放一条已记录的裁决
--- @param evidence_id string
--- @param opts table|nil { rules? }
--- @return table { ok, same, expected, actual, policy_version, version_mismatch }
function M.replay(evidence_id, opts)
  opts = opts or {}
  local rec = evidence.get(evidence_id)
  if not rec or rec.kind ~= "decision" then
    return { ok = false, same = false, reason = "DECISION_EVIDENCE_NOT_FOUND" }
  end
  local payload = rec.payload or {}
  local facts = payload.facts
  if type(facts) ~= "table" then
    return { ok = false, same = false, reason = "FACTS_MISSING" }
  end
  local current_version = _policy_version()
  local version_mismatch = payload.policy_version ~= nil and payload.policy_version ~= current_version

  local actual = policy.evaluate(facts)
  local expected = payload.verdict or {}
  local same = expected.decision == actual.decision and _same_codes(expected.reason_codes, actual.reason_codes)
  return {
    ok = true,
    same = same,
    expected = expected,
    actual = { decision = actual.decision, reason_codes = actual.reason_codes },
    policy_version = current_version,
    recorded_policy_version = payload.policy_version,
    version_mismatch = version_mismatch,
  }
end

return M
