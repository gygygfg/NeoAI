--- 审批「已拒绝 → 恢复为待审」回归
--- @module 'NeoAI.tests.test_sandbox_restore'
--- 覆盖三类回归：
---   1) `hostop.restore` 曾**不存在**：`review.restore` 用 `pcall` 判断成功，导致主机提案的
---      「恢复」永远失败（且错误被吞成 `HOST_OP_RESTORE_FAILED`）。
---   2) 清单层 `sandbox.list_rejected` / `sandbox.restore` 曾**不存在**：审批界面
---      （`ui/components/sandbox_review.lua` 的 `u` 与「已拒绝」区）静默 no-op。
---   3) 恢复必须只对 REJECTED 生效：已 APPLIED/FAILED 的 host_op 恢复后再次审批会在主机
---      **重复执行**同一条命令，必须拒绝。

local tests = require("NeoAI.tests")

local function sha(content)
  return "sha256:" .. vim.fn.sha256(content or "")
end

local function setup()
  local store = require("NeoAI.sandbox.state.store")
  local review = require("NeoAI.sandbox.review.review")
  store.init(vim.fn.tempname())
  require("NeoAI.sandbox.execution.hostop").reset()
  review.reset()
  return store, review
end

local function mk_cand(f, base, content, digest)
  return {
    candidate_digest = digest,
    files = {
      { path = f, action = "modify", content = content, before_hash = sha(base), mode = 420 },
    },
    effect = "fs_write",
  }
end

local function find_host_item(review, host_op_id)
  for _, item in ipairs(review.list({ review_state = "PENDING" })) do
    if item.kind == "host_op" and item.host_op_id == host_op_id then return item end
  end
  return nil
end

tests.suite("sandbox_restore", function(_, it)
  it("host_op：拒绝后可恢复为待审（提案与清单双向一致）", function(t)
    local _store, review = setup()
    local hostop = require("NeoAI.sandbox.execution.hostop")
    local rec = assert(hostop.freeze(
      { tool_name = "run_command", command_id = "c1", attempt_id = "a1" },
      { command = "echo RESTORE_ME" }, { tier = 2 }, { reason = "test" }))
    local item = assert(find_host_item(review, rec.host_op_id), "提案应进入待审队列")

    review.reject(item.change_set_id, "no")
    t.eq("REJECTED", assert(hostop.get(rec.host_op_id)).state, "拒绝后提案应为 REJECTED")
    t.eq(1, #review.list_rejected(), "已拒绝列表应含该提案（可恢复）")

    local res = review.restore(item.change_set_id)
    t.true_(res.ok, "恢复应成功: " .. tostring(res.reason))
    t.eq("PENDING", res.state, "恢复后清单状态应为 PENDING")
    local rec2 = assert(hostop.get(rec.host_op_id))
    t.eq("PENDING", rec2.state, "恢复后提案状态应为 PENDING")
    t.eq(nil, rec2.reject_reason, "恢复后应清除拒绝原因")
    t.eq(0, #review.list_rejected(), "恢复后不再出现在「已拒绝」列表")
    t.eq("PENDING", (review.get(item.change_set_id) or {}).review_state, "清单项应回到待审")
  end)

  it("host_op：已 APPLIED/FAILED 的提案不可恢复（防主机重复执行）", function(t)
    local store, _review = setup()
    local hostop = require("NeoAI.sandbox.execution.hostop")
    for _, st in ipairs({ "APPLIED", "FAILED" }) do
      store.write_host_op({
        host_op_id = "ho_" .. st, command = "echo X", tool = "run_command",
        command_id = "c", attempt_id = "a", tier = 2, state = st, created_at = os.time(),
      })
      local ok, err = hostop.restore("ho_" .. st)
      t.false_(ok, st .. " 提案不应可恢复")
      t.matches("HOST_OP_NOT_RESTORABLE", tostring(err), "应给出不可恢复原因")
      t.eq(st, (hostop.get("ho_" .. st) or {}).state, "状态不得被改写")
    end
    local ok2, err2 = hostop.restore("ho_missing")
    t.false_(ok2, "不存在的提案不应可恢复")
    t.matches("HOST_OP_NOT_FOUND", tostring(err2), "应给出未找到原因")
  end)

  it("普通候选：拒绝后经 sandbox.restore 恢复可再次应用", function(t)
    local store, review = setup()
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local f = dir .. "/f.txt"
    fs.write_file(f, "base\n")
    local cand = mk_cand(f, "base\n", "base\nEDIT\n", "sha256:restoreA")
    store.write_candidate(cand)
    local item = assert(review.enqueue(cand))
    review.reject(item.change_set_id, "no")
    t.eq(1, #sandbox.list_rejected(), "清单层应能列出可恢复项（此前该 API 缺失）")

    local res = sandbox.restore(item.change_set_id)
    t.true_(res.ok, "sandbox.restore 应成功: " .. tostring(res.reason))
    t.not_nil(store.read_candidate_raw(cand.candidate_digest), "候选内容应被重建")

    local ap = review.apply(item.change_set_id, { auto_approve = true })
    t.true_(ap and ap.ok, "恢复后应能正常应用: " .. tostring(ap and ap.reason))
    t.matches("EDIT", fs.read_file(f) or "", "应用后内容应为编辑结果")
    vim.fn.delete(dir, "rf")
  end)

  it("未拒绝的变更单元不可 restore", function(t)
    local store, review = setup()
    local cand = mk_cand("/tmp/neoai_restore_notrej.txt", "b", "c", "sha256:restoreB")
    store.write_candidate(cand)
    local item = assert(review.enqueue(cand))
    local res = review.restore(item.change_set_id)
    t.false_(res.ok, "未拒绝项不应恢复")
    t.eq("NOT_REJECTED", res.state, "应报告 NOT_REJECTED")
  end)
end)
