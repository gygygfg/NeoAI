--- 沙箱「跨命令视图持久性」回归
--- @module 'NeoAI.tests.test_sandbox_view_persistence'
--- 覆盖「命令产物在下一条命令丢失 / 内容回退」的三条已定位成因：
---   1) 会话轮换（每个 GENERATION_COMPLETED）迁移暂存时**丢失符号链接元信息**，并以跟随式
---      判定（filereadable/isdirectory）把相对链接误判为「暂存副本缺失」→ 物化成 whiteout。
---      典型受害者：venv `.venv/bin/python -> python3`、`.venv/lib64 -> lib`。
---   2) 物化把暂存符号链接当普通文件（读目标内容写入）→ 视图与真实语义分裂。
---   3) 写日志（eBPF journal）被当作穷举：漏记的路径被静默跳过 → 永不进入暂存视图。
---   4) 包/生成内容冻结曾调用不存在的工作区根 API（`base_dir`），使**所有包管理器命令**
---      （uv/pip/npm/apt…）的捕获链在冻结阶段抛错 → 本轮改动全部丢失。

local tests = require("NeoAI.tests")

local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(overrides or {})
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  if merged.tools.sandbox.ephemeral_roots == nil then
    merged.tools.sandbox.ephemeral_roots = {}
  end
  config_store.load(merged)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

--- 独立沙箱存储根，避免用例之间互相污染。
local function with_store(fn)
  with_config({
    tools = {
      sandbox = {
        workspace_root = vim.fn.tempname() .. "/sb",
        postprocess = "sync",
        observe = { enabled = false },
      },
    },
  }, fn)
end

local function await(d, timeout)
  local done, val, err = false, nil, nil
  d:then_(function(v) val = v; done = true end, function(e) err = e; done = true end)
  vim.wait(timeout or 20000, function() return done end, 10)
  return val, err
end

local function lstat(p)
  return vim.uv.fs_lstat(p)
end

tests.suite("sandbox_view_persistence", function(_, it)
  it("轮换保留暂存符号链接（venv bin/python、lib64）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_store(function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local link_path = dir .. "/.venv/bin/python"
      candidate.begin_session()
      candidate.merge_candidate({
        files = {
          { path = link_path, action = "create", link = "python3" },
          { path = dir .. "/.venv/lib64", action = "create", link = "lib" },
        },
      })
      local staged_before = candidate.read_path(link_path)
      t.not_nil(staged_before, "轮换前应有暂存副本")
      t.eq("link", (lstat(staged_before) or {}).type, "轮换前暂存副本应为符号链接")

      candidate.rotate_session()
      -- workspace_overrides 会等待在途迁移完成
      local by_real = {}
      for _, o in ipairs(candidate.workspace_overrides()) do by_real[o.real] = o end
      local o = by_real[link_path]
      t.not_nil(o, "轮换后条目不应消失")
      t.eq(false, o.deleted, "轮换后不得被误判为删除态（否则物化成 whiteout）")
      t.eq("python3", tostring(o.link), "轮换后应保留链接目标")
      local st = lstat(o.staged)
      t.eq("link", (st or {}).type, "轮换后暂存副本仍应为符号链接（不得解引用成普通文件）")
      t.eq("python3", tostring(vim.uv.fs_readlink(o.staged)), "链接目标应一致")
      local o2 = by_real[dir .. "/.venv/lib64"]
      t.eq(false, o2 and o2.deleted, "指向目录的链接同样不得被误判为删除")
      t.eq("lib", tostring(o2 and o2.link), "指向目录的链接目标应保留")

      sandbox.reset()
      vim.fn.delete(dir, "rf")
    end)
  end)

  it("物化把暂存符号链接重建为链接（不把目标内容写成普通文件）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    with_store(function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      local bind = vim.fn.tempname() .. "/view"
      fs.ensure_dir(dir)
      fs.ensure_dir(bind)
      local real = dir .. "/bin/python"
      candidate.begin_session()
      candidate.merge_candidate({ files = { { path = real, action = "create", link = "python3" } } })
      local conflicts = candidate.materialize_overlay({ { root = dir, bind = bind, mode = "bind" } })
      t.eq(0, #(conflicts or {}), "不应产生类型冲突")
      local dest = bind .. "/bin/python"
      t.eq("link", (lstat(dest) or {}).type, "物化结果应为符号链接")
      t.eq("python3", tostring(vim.uv.fs_readlink(dest)), "物化链接目标应一致")
      sandbox.reset()
      vim.fn.delete(dir, "rf")
      vim.fn.delete(vim.fn.fnamemodify(bind, ":h"), "rf")
    end)
  end)

  it("capture：写日志漏掉的路径必须由全量兜底捕获（hint 不是穷举）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    with_store(function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      local base = vim.fn.tempname()
      local upper = base .. "/upper"
      fs.ensure_dir(dir)
      fs.ensure_dir(upper)
      -- 模拟「命令原子保存」：目标路径只出现在 upper 里，但写日志里没有它（rename 目标丢失/
      -- 事件丢弃等），同时写日志里有一个无关路径（使 hw+nd>0，不会自然走「空日志回退」）。
      fs.write_file(upper .. "/saved.docx", "ATOMIC-SAVE-PAYLOAD\n")
      fs.write_file(upper .. "/journaled.txt", "x\n")
      local a = control.new_attempt("run_command", { command = "true" }, {}, { effect = "process" })
      candidate.begin(a, assert(store.root()))
      local hint = { writes = { [dir .. "/journaled.txt"] = true }, deletes = {} }
      local _, err = await(candidate.capture_overlay_async(a.attempt_id, dir, upper, hint,
        { since = os.time() }))
      t.eq(nil, err, "捕获应完成")
      local m = candidate.mapping(a.attempt_id)
      t.not_nil(m[dir .. "/saved.docx"], "写日志未覆盖的路径也必须被捕获")
      t.not_nil(m[dir .. "/journaled.txt"], "写日志覆盖的路径照常捕获")
      candidate.cleanup(a.attempt_id)
      vim.fn.delete(dir, "rf")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("包候选冻结：工作区根解析失败不得中断冻结（uv/pip/npm 全链）", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local control = require("NeoAI.sandbox.execution.control")
    local store = require("NeoAI.sandbox.state.store")
    with_store(function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local real = dir .. "/.venv/pyvenv.cfg"
      local a = control.new_attempt("run_command", { command = "uv sync" }, {}, { effect = "process" })
      a.package = true
      candidate.begin(a, assert(store.root()))
      local staged = candidate.stage_path(a.attempt_id, real)
      fs.ensure_dir(vim.fn.fnamemodify(staged, ":h"))
      fs.write_file(staged, "home = /usr/bin\n")
      -- classify=true 即包/生成内容路径（曾在此抛 `base_dir` 空调用）。
      local cand, err = await(candidate.finish_async(a.attempt_id, { blob = true, classify = true }), 30000)
      t.eq(nil, err, "包候选冻结不得抛错")
      t.not_nil(cand, "应产出候选")
      t.eq(1, #(cand and cand.files or {}), "候选应包含该文件")
      candidate.cleanup(a.attempt_id)
      vim.fn.delete(dir, "rf")
    end)
  end)

  -- ========== 重资源（真实 bwrap）：跨命令 + 跨轮换的端到端可见性 ==========

  it("后处理卡死时搭建屏障有界（绝不永久阻塞后续命令）", function(t)
    local H = require("NeoAI.tests.sandbox_boundary_helpers")
    if not H.bwrap() then return end
    local fs = require("NeoAI.utils.fs")
    local async = require("NeoAI.utils.async")
    local tools = require("NeoAI.tools")
    local sandbox = require("NeoAI.sandbox")
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    H.with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = {
          enabled = true, fail_closed = true, postprocess = "async",
          attach_await_ms = 300, workspace_root = vim.fn.tempname() .. "/sb",
        },
      },
    }, function()
      sandbox.reset()
      -- 注入一个永不完成的「上一条命令后处理」：旧实现会无限等待 → 后续命令永不返回。
      wrapper._set_postprocess_pending(async.Deferred.new())
      local t0 = vim.uv.hrtime()
      local d = tools.execute("run_command",
        { command = "true", description = "t", timeout_ms = 60000 }, {})
      local _, err = await(d, 60000)
      local ms = (vim.uv.hrtime() - t0) / 1e6
      wrapper._reset_postprocess()
      t.eq(nil, err, "命令应完成（屏障有界）")
      t.true_(ms < 20000, ("卡死的后处理不得让命令永久阻塞（实际 %.0fms）"):format(ms))
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)

  it("[opt-in] 背靠背命令 + 会话轮换：venv 链接与原子保存产物必须存活", function(t)
    if os.getenv("NEOAI_TEST_HEAVY") ~= "1" then return end
    local H = require("NeoAI.tests.sandbox_boundary_helpers")
    if not H.bwrap() then return end
    local fs = require("NeoAI.utils.fs")
    local tools = require("NeoAI.tools")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.execution.candidate")
    local wrapper = require("NeoAI.sandbox.execution.wrapper")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local prev = vim.fn.getcwd()
    vim.fn.chdir(dir)
    H.with_config({
      tools = {
        approval = { mode = "async" },
        sandbox = {
          enabled = true, fail_closed = true, mode = "dry_run", review = { enabled = true },
          postprocess = "async", workspace_root = vim.fn.tempname() .. "/sb",
        },
      },
    }, function()
      sandbox.reset()
      local function run(command)
        local d = tools.execute("run_command", { command = command, description = "v", timeout_ms = 120000 }, {})
        local v, err = await(d, 180000)
        return tostring(v or err), err
      end
      -- A：造 app.py + .venv 风格链接 + 原子保存的 docx
      local out_a = run([[
mkdir -p .venv/bin && printf 'v' > .venv/bin/python && ln -sf python .venv/bin/python3 \
  && printf 'DOCX-PAYLOAD' > .tmp && mv .tmp report.docx && printf 'A-OK'
]])
      t.matches("A%-OK", out_a, "A 应成功: " .. out_a)
      -- 轮换（模拟一轮生成结束）
      wrapper.await_postprocess(20000)
      candidate.rotate_session()
      -- B：必须看到 A 的产物与链接语义
      local out_b = run([[
printf 'PY=%s\n' "$(cat .venv/bin/python)"; \
printf 'DOCX=%s\n' "$(cat report.docx 2>/dev/null || echo MISSING)"; \
printf 'LINK=%s\n' "$(readlink .venv/bin/python3 2>/dev/null || echo MISSING)"
]])
      t.matches("PY=v", out_b, "下一条命令必须看到 A 写的文件: " .. out_b)
      t.matches("DOCX=DOCX%-PAYLOAD", out_b, "原子保存产物必须存活: " .. out_b)
      t.matches("LINK=python", out_b, "符号链接必须保持链接语义: " .. out_b)
      wrapper.await_postprocess(20000)
    end)
    vim.fn.chdir(prev)
    vim.fn.delete(dir, "rf")
  end)
end)
