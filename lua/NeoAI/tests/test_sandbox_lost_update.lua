--- 沙箱「丢更新 / 代码被静默回滚」回归
--- @module 'NeoAI.tests.test_sandbox_lost_update'
--- 覆盖审批阶段的并发发布竞态：APPLYING 在途时的二次 apply、以及同一路径两候选近同时
--- apply_async。二者都会让两次发布都以同一基线通过 CAS 后互相覆盖，静默丢一个候选
--- （表现为「已允许的修改被回滚」）。

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

--- @return table store, table review, table fs, string dir
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

--- 构造一个同路径 modify 候选。
local function mk_cand(f, base, content, digest)
  return {
    candidate_digest = digest,
    files = {
      { path = f, action = "modify", content = content, before_hash = sha(base), mode = 420 },
    },
    effect = "fs_write",
  }
end

tests.suite("sandbox_lost_update", function(_, it)
  it("[opt-in] 编辑与紧随的同文件命令并发：编辑不得被命令物化回滚", function(t)
    if os.getenv("NEOAI_TEST_HEAVY") ~= "1" then return end
    local H = require("NeoAI.tests.sandbox_boundary_helpers")
    if not H.bwrap() then return end
    local fs = require("NeoAI.utils.fs")
    local tools = require("NeoAI.tools")
    local sandbox = require("NeoAI.sandbox")
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local dir = vim.fn.tempname(); fs.ensure_dir(dir)
    local prev = vim.fn.getcwd(); vim.fn.chdir(dir)
    H.with_config({ tools = { approval = { mode = "async" },
      sandbox = { enabled = true, fail_closed = true, mode = "dry_run", review = { enabled = true } } } }, function()
      local lost = 0
      for i = 1, 12 do
        sandbox.reset()
        local f = dir .. "/race" .. i .. ".txt"
        fs.write_file(f, "base\n")
        local done1, done2 = false, false
        local d1 = tools.execute("edit_file",
          { file_path = f, old_text = "base", new_text = "base\nEDIT\n", description = "e" }, {})
        local d2 = tools.execute("run_command",
          { command = "echo CMD >> " .. f, description = "c" }, {})
        d1:then_(function() done1 = true end, function() done1 = true end)
        d2:then_(function() done2 = true end, function() done2 = true end)
        vim.wait(20000, function() return done1 and done2 end, 20)
        wrapper.await_postprocess(10000); sandbox.await_postprocess(10000)
        local content = fs.read_file(f) or ""
        local staged = require("NeoAI.sandbox.execution.candidate").read_path(f)
        local view = (staged and fs.read_file(staged)) or content
        if not (view:find("EDIT", 1, true)) then lost = lost + 1 end
      end
      t.eq(0, lost, "并发下编辑被命令回滚的次数（应 0），实际 " .. lost)
    end)
    vim.fn.chdir(prev); vim.fn.delete(dir, "rf")
  end)

  it("APPLYING 在途时再次 apply 应被拒绝（防重叠发布）", function(t)
    local store, review, fs, dir = setup()
    local f = dir .. "/f.txt"
    fs.write_file(f, "base\n")
    local cand = mk_cand(f, "base\n", "A\n", "sha256:candA")
    store.write_candidate(cand)
    local A = assert(review.enqueue(cand))
    local item = assert(review.get(A.change_set_id))
    -- 模拟已有一次异步发布在途（apply_state=APPLYING）。
    item.apply_state = review.APPLY.APPLYING
    local res = review.apply(A.change_set_id, { auto_approve = true })
    t.false_(res and res.ok,
      "在途（APPLYING）时再次 apply 不应发布（会与在途写入重叠→静默丢一个）："
        .. tostring(res and res.reason or res and res.ok))
    t.eq("base\n", fs.read_file(f), "被拒的二次 apply 不应改动真实文件")
    vim.fn.delete(dir, "rf")
  end)

  it("真实盘写入 fail-closed：buffer 含密钥 token 时 persist_buffer 拒绝（防假化写回损坏）", function(t)
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    local store = require("NeoAI.sandbox.state.store")
    local review = require("NeoAI.sandbox.review.review")
    store.init(vim.fn.tempname())
    review.reset()
    require("NeoAI.sandbox").reset() -- 确保无激活尝试 → persist_target 返回 nil（真实盘路径）
    local fs = require("NeoAI.utils.fs")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local p = dir .. "/x.txt"
    fs.write_file(p, "REAL\n")
    local bufnr = assert(helpers.ensure_buffer(p))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "NEOKEY_abc123def456" })
    vim.bo[bufnr].modified = true
    helpers.mark_edited(bufnr)
    local ok, err = helpers.persist_buffer(bufnr)
    t.false_(ok, "含密钥 token 的 buffer 不应写真实盘（实际: " .. tostring(ok) .. "/" .. tostring(err) .. "）")
    t.eq("REAL\n", fs.read_file(p), "真实内容不应被 token 覆盖")
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  it("同路径两候选近同时 apply_async：最多一个成功，绝不静默覆盖", function(t)
    local store, review, fs, dir = setup()
    local f = dir .. "/f.txt"
    fs.write_file(f, "base\n")
    local ca = mk_cand(f, "base\n", "A\n", "sha256:candA2")
    local cb = mk_cand(f, "base\n", "B\n", "sha256:candB2")
    store.write_candidate(ca)
    store.write_candidate(cb)
    local A = assert(review.enqueue(ca))
    local B = assert(review.enqueue(cb))
    local dA = review.apply_async(A.change_set_id, { auto_approve = true })
    local dB = review.apply_async(B.change_set_id, { auto_approve = true })
    local ra = await(dA)
    local rb = await(dB)
    local ok_count = 0
    if ra and ra.ok then ok_count = ok_count + 1 end
    if rb and rb.ok then ok_count = ok_count + 1 end
    t.true_(ok_count <= 1,
      ("同路径两候选不应同时报成功（必静默丢一个）：ra=%s rb=%s final=%q")
        :format(tostring(ra and ra.ok), tostring(rb and rb.ok), tostring(fs.read_file(f))))
    local final = fs.read_file(f)
    t.true_(final == "A\n" or final == "B\n", "最终内容应为其中一个候选，实际: " .. tostring(final))
    vim.fn.delete(dir, "rf")
  end)
end)
