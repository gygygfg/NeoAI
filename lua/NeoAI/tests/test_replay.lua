--- 沙箱策略回放（replay）专项测试
--- @module 'NeoAI.tests.test_replay'
local tests = require("NeoAI.tests")

tests.suite("replay", function(_, it, before_each)
  local replay, policy, evidence, store, root
  before_each(function()
    replay = require("NeoAI.sandbox.review.replay")
    policy = require("NeoAI.sandbox.review.policy")
    evidence = require("NeoAI.sandbox.review.evidence")
    store = require("NeoAI.sandbox.state.store")
    store.reset()
    root = vim.fn.tempname() .. "-neoai_replay"
    vim.fn.mkdir(root, "p")
    store.init(root)
    evidence.reset()
  end)

  local function cleanup()
    store.reset()
    vim.fn.delete(root, "rf")
  end

  it("记录后回放：同规则同事实裁决可复现", function(t)
    local facts = { tool = "edit_file", effect = "fs_write", args = {} }
    local verdict = policy.evaluate(facts)
    local id = replay.record(facts, verdict, { tool = "edit_file" })
    t.not_nil(id)
    local r = replay.replay(id)
    t.true_(r.ok, "回放应成功")
    t.true_(r.same, "同规则事实应得到一致裁决")
    t.eq(verdict.decision, r.actual.decision)
    cleanup()
  end)

  it("被篡改的裁决：same 为 false", function(t)
    local facts = { tool = "edit_file", effect = "fs_write", args = {} }
    local id = evidence.add("decision", {
      facts = facts,
      verdict = { decision = "DENY", reason_codes = { "TAMPERED" } },
      policy_version = "1",
    })
    local r = replay.replay(id)
    t.true_(r.ok)
    t.false_(r.same, "与事实不符的裁决应判定不一致")
    cleanup()
  end)

  it("策略版本漂移：标记 version_mismatch", function(t)
    local facts = { tool = "edit_file", effect = "fs_write", args = {} }
    local verdict = policy.evaluate(facts)
    local id = evidence.add("decision", {
      facts = facts,
      verdict = { decision = verdict.decision, reason_codes = verdict.reason_codes },
      policy_version = "999",
    })
    local r = replay.replay(id)
    t.true_(r.ok)
    t.true_(r.version_mismatch, "版本不同应标记 mismatch")
    t.eq("999", r.recorded_policy_version)
    cleanup()
  end)

  it("缺少事实：FACTS_MISSING", function(t)
    local id = evidence.add("decision", { verdict = { decision = "ALLOW", reason_codes = {} } })
    local r = replay.replay(id)
    t.false_(r.ok)
    t.eq("FACTS_MISSING", r.reason)
    cleanup()
  end)

  it("非裁决证据：DECISION_EVIDENCE_NOT_FOUND", function(t)
    local id = evidence.add("observation", { kind = "outside_access", path = "/root/x" })
    local r = replay.replay(id)
    t.false_(r.ok)
    t.eq("DECISION_EVIDENCE_NOT_FOUND", r.reason)
    cleanup()
  end)

  it("不存在的证据 id：DECISION_EVIDENCE_NOT_FOUND", function(t)
    local r = replay.replay("no_such_evidence_id")
    t.false_(r.ok)
    t.eq("DECISION_EVIDENCE_NOT_FOUND", r.reason)
    cleanup()
  end)
end)
