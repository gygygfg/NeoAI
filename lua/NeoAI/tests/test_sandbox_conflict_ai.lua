--- 合并冲突留待审 + 交给 AI 回归
--- @module NeoAI.tests.test_sandbox_conflict_ai
--- 覆盖：
--- 1) 三方合并冲突时 apply 返回 CONFLICT，条目保持 PENDING 并记录 merge_conflict；
--- 2) 冲突时真实文件零改动；
--- 3) has_merge_conflict 判定；
--- 4) notify_conflict_ai 组装冲突说明并经 chat_service 注入会话。

local tests = require("NeoAI.tests")

local function sha(content)
  return "sha256:" .. vim.fn.sha256(content or "")
end

tests.suite("sandbox_conflict_ai", function(_, it)
  local function setup()
    local store = require("NeoAI.sandbox.state.store")
    local review = require("NeoAI.sandbox.review.review")
    local fs = require("NeoAI.utils.fs")
    store.init(vim.fn.tempname())
    review.reset()
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    return store, review, fs, dir
  end

  local function make_conflict(store, review, fs, dir)
    local base = "a\nb\nc\n"
    local ours = "a\nX\nc\n"
    local theirs = "a\nY\nc\n"
    local base_file = dir .. "/.base.txt"
    fs.write_file(base_file, base)
    local p = dir .. "/conflict.txt"
    fs.write_file(p, theirs)
    local cand = {
      candidate_digest = "sha256:cfai_" .. tostring(os.time()) .. tostring(math.random(1, 1e6)),
      files = {
        {
          path = p, action = "modify", base_exists = true, base_type = "file",
          base_blob = base_file, before_hash = sha(base), after_hash = sha(ours),
          content = ours, mode = 420,
        },
      },
      created_at = 1, effect = "fs_write",
    }
    store.write_candidate(cand)
    local item = review.enqueue(cand, { tool = "edit_file" })
    return item, p, theirs
  end

  it("合并冲突：apply 返回 CONFLICT，条目待审且记录冲突", function(t)
    local store, review, fs, dir = setup()
    local item, p, theirs = make_conflict(store, review, fs, dir)
    local pub = review.apply(item.change_set_id, { auto_approve = true })
    t.false_(pub.ok, "应冲突")
    t.eq("CONFLICT", pub.state)
    t.matches("^MERGE_CONFLICT", pub.reason or "", "应为合并冲突")
    local after = review.get(item.change_set_id)
    t.eq(review.REVIEW.PENDING, after.review_state, "冲突条目应保持待审")
    t.eq(review.APPLY.CONFLICT, after.apply_state, "应标记为 CONFLICT")
    t.not_nil(after.merge_conflict, "应记录合并冲突")
    t.true_(review.has_merge_conflict(item.change_set_id), "has_merge_conflict 应为真")
    t.eq(theirs, fs.read_file(p), "冲突时真实文件不得改动")
    store.reset()
    review.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("notify_conflict_ai：组装冲突说明并注入会话", function(t)
    local store, review, fs, dir = setup()
    local item, p = make_conflict(store, review, fs, dir)
    review.apply(item.change_set_id, { auto_approve = true })

    local captured
    local cs = require("NeoAI.services.chat_service")
    local orig = cs.send_message
    cs.send_message = function(msg, opts) captured = { msg = msg, opts = opts }; return {} end
    local ok, err = review.notify_conflict_ai(item.change_set_id)
    cs.send_message = orig

    t.true_(ok, "应成功交给 AI: " .. tostring(err))
    t.not_nil(captured, "应向 chat_service 注入消息")
    t.true_(captured.msg:find(item.change_set_id, 1, true) ~= nil, "消息应含变更单元 id")
    t.true_(captured.msg:find(p, 1, true) ~= nil, "消息应含冲突文件路径")
    t.true_(captured.msg:find("重新读取", 1, true) ~= nil, "消息应含重做指引")
    store.reset()
    review.reset()
    vim.fn.delete(dir, "rf")
  end)
end)
