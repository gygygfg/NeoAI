--- 代码/内容丢失全面审计
--- @module 'NeoAI.tests.test_sandbox_loss_audit'
--- 对已知/可疑的「内容静默丢失」路径逐一施加场景并断言内容不丢：
---   会话轮换（暂存/pending）、候选取代（同路径/无关路径/子集）、选择性应用回队、
---   丢弃候选可恢复、密钥假化写回、命令物化覆盖编辑（重资源，opt-in）、
---   编辑→命令→轮换→读全链路。
--- 重资源（真实 bwrap）用例 opt-in（NEOAI_TEST_HEAVY=1）。

local tests = require("NeoAI.tests")

local function await(d, timeout)
  local done, val, err = false, nil, nil
  d:then_(function(v) val = v; done = true end, function(e) err = e; done = true end)
  vim.wait(timeout or 8000, function() return done end, 10)
  return val, err
end

local function sha(content)
  return "sha256:" .. vim.fn.sha256(content or "")
end

local function setup_review()
  local store = require("NeoAI.sandbox.state.store")
  local review = require("NeoAI.sandbox.review.review")
  store.init(vim.fn.tempname())
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

tests.suite("sandbox_loss_audit", function(_, it)
  -- ================= A. 会话轮换 =================

  it("A1 暂存内容在会话轮换后保留（读回一致）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local fs = require("NeoAI.utils.fs")
    sandbox.reset()
    candidate.begin_session()
    local dir = vim.fn.tempname(); fs.ensure_dir(dir)
    local f = dir .. "/f.txt"
    fs.write_file(f, "base\n")
    candidate.merge_candidate({ files = { { path = f, action = "create", content = "HELLO\n" } } })
    t.eq("HELLO\n", fs.read_file(candidate.read_path(f)), "轮换前暂存内容")
    candidate.rotate_session()
    local staged = candidate.read_path(f)
    t.not_nil(staged, "轮换后暂存副本仍应存在")
    t.eq("HELLO\n", fs.read_file(staged), "轮换后暂存内容不得丢失")
    sandbox.reset()
    vim.fn.delete(dir, "rf")
  end)

  it("A2 pending 候选在会话轮换后可正常应用（候选不依赖会话目录）", function(t)
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local store, review = setup_review()
    local fs = require("NeoAI.utils.fs")
    sandbox.reset()
    candidate.begin_session()
    local dir = fs.canonical(vim.fn.tempname()); fs.ensure_dir(dir)
    local f = dir .. "/f.txt"
    fs.write_file(f, "base\n")
    local cand = mk_cand(f, "base\n", "base\nEDIT\n", "sha256:rotA")
    store.write_candidate(cand)
    local item = assert(review.enqueue(cand))
    candidate.rotate_session()
    local res = review.apply(item.change_set_id, { auto_approve = true })
    t.true_(res and res.ok, "轮换后应用应成功: " .. tostring(res and res.reason))
    t.eq("base\nEDIT\n", fs.read_file(f), "应用后真实内容应为编辑结果")
    sandbox.reset()
    vim.fn.delete(dir, "rf")
  end)

  -- ================= B. 候选取代 =================

  it("B1 取代：新候选包含旧编辑时，两者内容都保留", function(t)
    local store, review = setup_review()
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname()); fs.ensure_dir(dir)
    local f = dir .. "/f.txt"
    fs.write_file(f, "base\n")
    local a = mk_cand(f, "base\n", "base\nAAA\n", "sha256:supA")
    store.write_candidate(a)
    local ia = assert(review.enqueue(a))
    -- 新候选（同路径）已包含 A 的编辑：这是「读到最新暂存视图后再次编辑」的正常情形。
    local b = mk_cand(f, "base\nAAA\n", "base\nAAA\nBBB\n", "sha256:supB")
    -- 真实盘仍是 base（A 只在暂存），故 before_hash 用 base 亦可；此处用 A 的结果作基线模拟
    b.files[1].before_hash = sha("base\n")
    store.write_candidate(b)
    local ib = assert(review.enqueue(b))
    review.supersede_by_paths({ f }, ib.change_set_id)
    local res = review.apply(ib.change_set_id, { auto_approve = true })
    t.true_(res and res.ok, "应用 B 应成功: " .. tostring(res and res.reason))
    t.matches("AAA", fs.read_file(f) or "", "A 的编辑不应丢失")
    t.matches("BBB", fs.read_file(f) or "", "B 的编辑应在")
    t.not_nil(review.get(ia.change_set_id), "A 项应仍可查询")
    vim.fn.delete(dir, "rf")
  end)

  it("B2 取代只影响重叠路径，不误伤无关路径的 pending", function(t)
    local store, review = setup_review()
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname()); fs.ensure_dir(dir)
    local f1, f2 = dir .. "/a.txt", dir .. "/b.txt"
    fs.write_file(f1, "a\n"); fs.write_file(f2, "b\n")
    local a = mk_cand(f1, "a\n", "a\nAA\n", "sha256:supF1")
    store.write_candidate(a)
    local ia = assert(review.enqueue(a))
    local b = mk_cand(f2, "b\n", "b\nBB\n", "sha256:supF2")
    store.write_candidate(b)
    local ib = assert(review.enqueue(b))
    review.supersede_by_paths({ f2 }, ib.change_set_id)
    local item_a = assert(review.get(ia.change_set_id))
    t.eq(review.REVIEW.PENDING, item_a.review_state, "无重叠路径的 pending 不应被取代")
    vim.fn.delete(dir, "rf")
  end)

  -- ================= C. 选择性应用 / 丢弃可恢复 =================

  it("C1 选择性应用后其余文件回队为 pending 且内容可读", function(t)
    local store, review = setup_review()
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname()); fs.ensure_dir(dir)
    local f1, f2 = dir .. "/a.txt", dir .. "/b.txt"
    fs.write_file(f1, "a\n"); fs.write_file(f2, "b\n")
    local cand = {
      candidate_digest = "sha256:sel",
      files = {
        { path = f1, action = "modify", content = "a1\n", before_hash = sha("a\n"), mode = 420 },
        { path = f2, action = "modify", content = "b1\n", before_hash = sha("b\n"), mode = 420 },
      },
      effect = "fs_write",
    }
    store.write_candidate(cand)
    local item = assert(review.enqueue(cand))
    local res = review.apply(item.change_set_id, { auto_approve = true, files = { f1 } })
    t.true_(res and res.ok, "选择性应用应成功")
    t.eq("a1\n", fs.read_file(f1), "选中文件应应用")
    t.eq("b\n", fs.read_file(f2), "未选文件不应改动")
    local pending = require("NeoAI.sandbox").list_reviews({ review_state = "PENDING" })
    local found = false
    for _, p in ipairs(pending) do
      for _, ff in ipairs(p.files or {}) do if ff.path == f2 then found = true end end
    end
    t.true_(found, "未选文件应回队为待审（内容不丢）")
    vim.fn.delete(dir, "rf")
  end)

  it("C2 丢弃候选后 pending 变为可恢复的 REJECTED（非静默丢失）", function(t)
    local store, review = setup_review()
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname()); fs.ensure_dir(dir)
    local f = dir .. "/f.txt"
    fs.write_file(f, "base\n")
    local cand = mk_cand(f, "base\n", "base\nX\n", "sha256:rej")
    store.write_candidate(cand)
    local item = assert(review.enqueue(cand))
    review.discard_by_digest("sha256:rej", "TEST")
    local got = assert(review.get(item.change_set_id))
    t.eq(review.REVIEW.REJECTED, got.review_state, "丢弃应落 REJECTED 终态")
    vim.fn.delete(dir, "rf")
  end)

  it("C3 应用后可撤销：真实盘恢复原内容", function(t)
    local store, review = setup_review()
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname()); fs.ensure_dir(dir)
    local f = dir .. "/f.txt"
    fs.write_file(f, "base\n")
    local cand = mk_cand(f, "base\n", "base\nNEW\n", "sha256:undo")
    store.write_candidate(cand)
    local item = assert(review.enqueue(cand))
    local res = review.apply(item.change_set_id, { auto_approve = true })
    t.true_(res and res.ok, "应用应成功")
    t.eq("base\nNEW\n", fs.read_file(f), "应用后应为新内容")
    local ures = review.undo(item.change_set_id)
    t.true_(ures and ures.ok, "撤销应成功: " .. tostring(ures and ures.reason))
    t.eq("base\n", fs.read_file(f), "撤销后应恢复原内容（不丢原文件）")
    vim.fn.delete(dir, "rf")
  end)

  -- ================= D. 密钥假化写回 =================

  it("D1 含密钥 token 的 buffer 拒绝写真实盘", function(t)
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    local store, review = setup_review()
    require("NeoAI.sandbox").reset()
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname()); fs.ensure_dir(dir)
    local p = dir .. "/x.txt"
    fs.write_file(p, "REAL\n")
    local bufnr = assert(helpers.ensure_buffer(p))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "NEOKEY_abc123def456" })
    vim.bo[bufnr].modified = true
    helpers.mark_edited(bufnr)
    local ok = helpers.persist_buffer(bufnr)
    t.false_(ok, "含 token 的 buffer 不应写真实盘")
    t.eq("REAL\n", fs.read_file(p), "真实内容不应被覆盖")
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  -- ================= E. 重资源：编辑↔命令↔轮换全链路 =================

  it("[opt-in] E1 编辑→命令→轮换→读：全程内容不丢", function(t)
    if os.getenv("NEOAI_TEST_HEAVY") ~= "1" then return end
    local H = require("NeoAI.tests.sandbox_boundary_helpers")
    if not H.bwrap() then return end
    local fs = require("NeoAI.utils.fs")
    local tools = require("NeoAI.tools")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local dir = vim.fn.tempname(); fs.ensure_dir(dir)
    local prev = vim.fn.getcwd(); vim.fn.chdir(dir)
    H.with_config({ tools = { approval = { mode = "async" },
      sandbox = { enabled = true, fail_closed = true, mode = "dry_run", review = { enabled = true } } } }, function()
      local lost = 0
      for i = 1, 10 do
        sandbox.reset()
        local f = dir .. "/life" .. i .. ".txt"
        fs.write_file(f, "base\n")
        -- 1) 编辑 2) 命令追加 3) 轮换 4) 读回
        local d1 = tools.execute("edit_file",
          { file_path = f, old_text = "base", new_text = "base\nEDIT\n", description = "e" }, {})
        local d2 = tools.execute("run_command",
          { command = "echo CMD >> " .. f, description = "c" }, {})
        local done1, done2 = false, false
        d1:then_(function() done1 = true end, function() done1 = true end)
        d2:then_(function() done2 = true end, function() done2 = true end)
        vim.wait(20000, function() return done1 and done2 end, 20)
        wrapper.await_postprocess(10000); sandbox.await_postprocess(10000)
        candidate.rotate_session()
        wrapper.await_postprocess(10000); sandbox.await_postprocess(10000)
        local staged = candidate.read_path(f)
        local view = (staged and fs.read_file(staged)) or (fs.read_file(f) or "")
        if not (view:find("EDIT", 1, true) and view:find("CMD", 1, true)) then lost = lost + 1 end
      end
      t.eq(0, lost, "编辑→命令→轮换全链路丢失次数（应 0），实际 " .. lost)
    end)
    vim.fn.chdir(prev); vim.fn.delete(dir, "rf")
  end)

  it("[opt-in] E2 轮换不丢 pending 与暂存（真实 sandbox 端到端）", function(t)
    if os.getenv("NEOAI_TEST_HEAVY") ~= "1" then return end
    local H = require("NeoAI.tests.sandbox_boundary_helpers")
    if not H.bwrap() then return end
    local fs = require("NeoAI.utils.fs")
    local tools = require("NeoAI.tools")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local dir = vim.fn.tempname(); fs.ensure_dir(dir)
    local prev = vim.fn.getcwd(); vim.fn.chdir(dir)
    H.with_config({ tools = { approval = { mode = "async" },
      sandbox = { enabled = true, fail_closed = true, mode = "dry_run", review = { enabled = true } } } }, function()
      sandbox.reset()
      local f = dir .. "/persist.txt"
      fs.write_file(f, "base\n")
      local done = false
      tools.execute("edit_file",
        { file_path = f, old_text = "base", new_text = "base\nKEEP\n", description = "e" }, {})
        :then_(function() done = true end, function() done = true end)
      vim.wait(20000, function() return done end, 20)
      wrapper.await_postprocess(10000); sandbox.await_postprocess(10000)
      candidate.rotate_session()
      wrapper.await_postprocess(10000); sandbox.await_postprocess(10000)
      -- 轮换后暂存仍应含编辑，且可应用落盘
      local pending = sandbox.list_reviews({ review_state = "PENDING" })
      local item
      for _, p in ipairs(pending) do
        for _, ff in ipairs(p.files or {}) do if ff.path == f then item = p end end
      end
      t.not_nil(item, "轮换后 pending 应仍在")
      local res = sandbox.apply(item.change_set_id, { auto_approve = true })
      if res and res.then_ then res = await(res, 20000) end
      t.true_(res and res.ok, "轮换后应用应成功: " .. tostring(res and res.reason))
      t.matches("KEEP", fs.read_file(f) or "", "应用后内容应为编辑结果")
    end)
    vim.fn.chdir(prev); vim.fn.delete(dir, "rf")
  end)
end)
