--- 计划模式草稿（暂存但不入审批，退出丢弃）回归
--- @module 'NeoAI.tests.test_sandbox_plan_draft'

local tests = require("NeoAI.tests")

local function with_store(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(overrides or {})
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  merged.tools.sandbox.workspace_root = merged.tools.sandbox.workspace_root or (vim.fn.tempname() .. "/sb")
  merged.tools.sandbox.postprocess = merged.tools.sandbox.postprocess or "sync"
  merged.tools.sandbox.observe = merged.tools.sandbox.observe or { enabled = false }
  merged.tools.sandbox.single_view = merged.tools.sandbox.single_view ~= false
  if merged.tools.sandbox.ephemeral_roots == nil then merged.tools.sandbox.ephemeral_roots = {} end
  config_store.load(merged)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

local function sha(content)
  return "sha256:" .. vim.fn.sha256(content or "")
end

tests.suite("sandbox_plan_draft", function(_, it)
  it("草稿：登记后不产生候选/待审，丢弃恢复真实盘", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.sandbox.state.store")
    local review = require("NeoAI.sandbox.review.review")
    local pd = require("NeoAI.sandbox.execution.plan_draft")
    with_store({}, function()
      sandbox.reset()
      review.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local p = dir .. "/note.txt"
      fs.write_file(p, "base\n")
      local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a, assert(store.root()))
      local staged = assert(candidate.stage_path(a.attempt_id, p))
      fs.write_file(staged, "draft\n")

      local scope = "plan:test1"
      pd.begin(scope, "test1")
      local settled = pd.settle(scope, { files = { { path = p, action = "modify" } } },
        a, { plan_scope = scope }, "tool-ok")
      t.not_nil(settled and settled.ok)
      t.matches("PLAN_DRAFT", settled.value or "", "结果应告知模型这是计划草稿")
      t.eq(0, review.pending_count(), "草稿不得进入审批队列")
      t.eq(1, #vim.tbl_keys(pd.items(scope)), "应登记 1 个草稿路径")

      local stats = pd.discard(scope, "test")
      t.eq(1, stats.discarded)
      t.eq("base\n", fs.read_file(p), "真实盘不应被草稿修改")
      t.eq(nil, candidate.read_path(p), "丢弃后不应再有暂存视图")

      candidate.cleanup(a.attempt_id)
      vim.fn.chdir(prev)
      vim.fn.delete(dir, "rf")
      pd.reset()
    end)
  end)

  it("草稿覆盖有待审路径：丢弃时恢复旧待审内容而非真实盘", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.sandbox.state.store")
    local review = require("NeoAI.sandbox.review.review")
    local pd = require("NeoAI.sandbox.execution.plan_draft")
    with_store({}, function()
      sandbox.reset()
      review.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local p = dir .. "/pending.txt"
      fs.write_file(p, "base\n")
      local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a, assert(store.root()))
      local staged = assert(candidate.stage_path(a.attempt_id, p))
      fs.write_file(staged, "pending\n")

      local cand = {
        candidate_digest = "sha256:pd_pending",
        files = {
          {
            path = p, action = "modify", base_exists = true, base_type = "file",
            before_hash = sha("base\n"), after_hash = sha("pending\n"),
            content = "pending\n", mode = 420,
          },
        },
        write_set = { p },
        created_at = 1, effect = "fs_write",
      }
      store.write_candidate(cand)
      local item = assert(review.enqueue(vim.deepcopy(cand), { tool = "edit_file" }))
      candidate.merge_candidate(cand, {})
      t.eq("pending\n", fs.read_file(candidate.staged_path(p)), "旧待审内容应在视图里")

      -- 计划模式写入覆盖同一路径
      fs.write_file(staged, "draft\n")
      local scope = "plan:test2"
      pd.begin(scope, "test2")
      pd.register(scope, { files = { { path = p, action = "modify" } } })
      local stats = pd.discard(scope, "test")
      t.eq(1, stats.restored, "应恢复旧待审内容")
      t.eq("pending\n", fs.read_file(candidate.staged_path(p)), "旧待审内容应回到视图")
      t.eq("base\n", fs.read_file(p), "真实盘不应变化")
      local after = assert(review.get(item.change_set_id))
      t.eq(review.REVIEW.PENDING, after.review_state, "旧待审项仍应可审批")

      candidate.cleanup(a.attempt_id)
      vim.fn.chdir(prev)
      vim.fn.delete(dir, "rf")
      pd.reset()
    end)
  end)

  it("草稿期间路径被他人改动：丢弃跳过，不误删", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.sandbox.state.store")
    local pd = require("NeoAI.sandbox.execution.plan_draft")
    with_store({}, function()
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local p = dir .. "/race.txt"
      fs.write_file(p, "base\n")
      local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a, assert(store.root()))
      local staged = assert(candidate.stage_path(a.attempt_id, p))
      fs.write_file(staged, "draft\n")
      local scope = "plan:test3"
      pd.begin(scope, "test3")
      pd.register(scope, { files = { { path = p, action = "modify" } } })
      -- 模拟另一个 Agent 改成不同内容
      fs.write_file(staged, "other\n")
      local stats = pd.discard(scope, "test")
      t.eq(0, stats.discarded)
      t.eq(1, stats.skipped)
      t.eq("other\n", fs.read_file(staged), "他人改动应保留")
      candidate.cleanup(a.attempt_id)
      vim.fn.chdir(prev)
      vim.fn.delete(dir, "rf")
      pd.reset()
    end)
  end)

  it("结算晚于退出计划模式：立即丢弃，不补入审批", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local fs = require("NeoAI.utils.fs")
    local store = require("NeoAI.sandbox.state.store")
    local review = require("NeoAI.sandbox.review.review")
    local pd = require("NeoAI.sandbox.execution.plan_draft")
    with_store({}, function()
      sandbox.reset()
      review.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local p = dir .. "/late.txt"
      fs.write_file(p, "base\n")
      local a = control.new_attempt("edit_file", {}, {}, { effect = "fs_write" })
      candidate.begin(a, assert(store.root()))
      local staged = assert(candidate.stage_path(a.attempt_id, p))
      fs.write_file(staged, "late\n")
      local scope = "plan:late"
      pd.begin(scope, "late")
      pd.discard(scope, "exit") -- 用户在异步后处理完成前退出计划模式
      local settled = pd.settle(scope, { files = { { path = p, action = "modify" } } },
        a, { plan_scope = scope, _plan_draft_active = true }, "tool-ok")
      t.not_nil(settled and settled.ok, "晚到结算仍应被草稿逻辑接住")
      t.matches("DISCARDED", settled.value or "")
      t.eq(0, review.pending_count(), "不得补入审批")
      t.eq("base\n", fs.read_file(p), "真实盘不变")
      t.eq(nil, candidate.read_path(p), "晚到改动应被立即丢弃")
      candidate.cleanup(a.attempt_id)
      vim.fn.chdir(prev)
      vim.fn.delete(dir, "rf")
      pd.reset()
    end)
  end)
end)
