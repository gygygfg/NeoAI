--- 包/生成内容候选的「签名模式」回归
--- @module NeoAI.tests.test_sandbox_package_signature
--- 覆盖：
--- 1) 包捕获：现有 base 用 stat 签名（`sig:`）代替内容哈希，且不读真实盘内容；
--- 2) 包冻结：内容磁盘化为 blob，after_hash 用 stat 签名（不做纯 Lua SHA）；
--- 3) 包发布：blob + stat 签名 CAS 通过并完整落盘，外部改动可检出冲突；
--- 4) 遮蔽/git/级别判定移入工作线程（主线程不再逐文件 resolve），遮蔽命中被剔除；
--- 5) 非包候选仍走内容哈希。

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

local function await(d, timeout)
  local done, val, err = false, nil, nil
  d:then_(function(v) val = v; done = true end, function(e) err = e; done = true end)
  vim.wait(timeout or 20000, function() return done end, 10)
  return val, err
end

tests.suite("sandbox_package_signature", function(_, it)
  it("包捕获：base 用 stat 签名（sig:）、不读内容；非包仍内容哈希", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local base = vim.fn.tempname()
      local upper = base .. "/upper"
      fs.ensure_dir(upper)
      fs.write_file(dir .. "/existing.txt", "base-content\n")
      fs.write_file(upper .. "/existing.txt", "changed-content\n")
      fs.write_file(upper .. "/new.txt", "new\n")

      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, store.root())
      local _, err = await(candidate.capture_overlay_async(a.attempt_id, dir, upper, nil, { package = true }))
      t.eq(nil, err, "包捕获应完成")
      local m = candidate.mapping(a.attempt_id)
      local ex = m[dir .. "/existing.txt"]
      t.not_nil(ex, "已存在文件应登记")
      t.eq(nil, ex.base_hash, "包候选不应做 base 内容哈希")
      t.matches("^sig:", ex.base_sig or "", "base 应用 stat 签名")
      t.eq(nil, (m[dir .. "/new.txt"] or {}).base_hash, "新建文件无 base 哈希")
      candidate.cleanup(a.attempt_id)

      -- 非包捕获：换一个独立 upper（避免物化增量记录跳过），应得到内容哈希。
      local upper2 = base .. "/upper2"
      fs.ensure_dir(upper2)
      fs.write_file(upper2 .. "/existing.txt", "changed-content-2\n")
      local a2 = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a2, store.root())
      local _, err2 = await(candidate.capture_overlay_async(a2.attempt_id, dir, upper2, nil))
      t.eq(nil, err2, "非包捕获应完成")
      local ex2 = candidate.mapping(a2.attempt_id)[dir .. "/existing.txt"]
      t.matches("^sha256:", (ex2 or {}).base_hash or "", "非包候选应用内容哈希")
      candidate.cleanup(a2.attempt_id)
      vim.fn.delete(dir, "rf")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("包冻结+发布：内容磁盘化为 blob、after_hash 为 stat 签名，CAS 落盘且可检出冲突", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local base = vim.fn.tempname()
      local upper = base .. "/upper"
      fs.ensure_dir(upper)
      fs.write_file(dir .. "/existing.txt", "base-content\n")
      fs.write_file(upper .. "/existing.txt", "changed-content\n")
      fs.write_file(upper .. "/new.txt", "brand-new\n")

      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, store.root())
      await(candidate.capture_overlay_async(a.attempt_id, dir, upper, nil, { package = true }))
      local cand, ferr = await(candidate.finish_async(a.attempt_id, { blob = true, classify = true }))
      t.not_nil(cand, "冻结应产出候选: " .. tostring(ferr))
      local by = {}
      for _, f in ipairs(cand.files) do by[f.path] = f end
      local ex = by[dir .. "/existing.txt"]
      local nw = by[dir .. "/new.txt"]
      t.not_nil(ex, "修改文件应在候选内")
      t.not_nil(nw, "新建文件应在候选内")
      t.eq(nil, ex.content, "包候选不应内嵌内容")
      t.not_nil(ex.blob, "包候选内容应磁盘化为 blob")
      t.matches("^sig:", ex.after_hash or "", "after_hash 应用 stat 签名")
      t.matches("^sig:", ex.before_sig or "", "修改项应记录 before_sig")
      t.eq(nil, ex.before_hash, "签名模式下 before_hash 应为空")
      t.matches("^sig:", nw.after_hash or "", "新建项 after_hash 应用 stat 签名")

      local levels = candidate.levels_for(cand)
      t.not_nil(levels, "应提供分类级别映射")
      t.eq("number", type(levels[dir .. "/new.txt"]), "每个路径应有数值级别")

      local res = candidate.publish(cand, {})
      t.true_(res.ok, "包候选应发布成功: " .. tostring(res.reason))
      t.eq("changed-content\n", fs.read_file(dir .. "/existing.txt") or "")
      t.eq("brand-new\n", fs.read_file(dir .. "/new.txt") or "")

      fs.write_file(dir .. "/existing.txt", "externally-changed\n")
      local res2 = candidate.publish(cand, {})
      t.true_(not res2.ok, "基线变化应报冲突")
      t.eq("CONFLICT", res2.state, "应为 CONFLICT")
      candidate.cleanup(a.attempt_id)
      vim.fn.delete(dir, "rf")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("包分类：遮蔽/git 判定移入工作线程，主线程不逐文件 resolve", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    with_config({ tools = { sandbox = { workspace_root = vim.fn.tempname() .. "/sb" } } }, function()
      sandbox.reset()
      local dir = fs.canonical(vim.fn.tempname())
      fs.ensure_dir(dir)
      local base = vim.fn.tempname()
      local upper = base .. "/upper"
      fs.ensure_dir(upper)
      fs.write_file(upper .. "/plain.txt", "plain\n")
      fs.ensure_dir(upper .. "/.git/objects/ab")
      fs.write_file(upper .. "/.git/objects/ab/cd", "obj")
      fs.write_file(upper .. "/.git/index.lock", "lock")

      local runtime = require("NeoAI.sandbox.runtime")
      local orig = runtime.is_masked_path
      local calls = 0
      runtime.is_masked_path = function(...) calls = calls + 1; return orig(...) end
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, store.root())
      await(candidate.capture_overlay_async(a.attempt_id, dir, upper, nil, { package = true }))
      local cand = await(candidate.finish_async(a.attempt_id, { blob = true, classify = true }))
      runtime.is_masked_path = orig
      t.eq(0, calls, "包候选分类不应在主线程调用 is_masked_path")
      local by = {}
      for _, f in ipairs(cand.files) do by[f.path] = f end
      t.not_nil(by[dir .. "/plain.txt"], "普通文件应保留")
      t.eq("object", (by[dir .. "/.git/objects/ab/cd"] or {}).git_class, "git 对象应分类为 object")
      t.eq(nil, by[dir .. "/.git/index.lock"], ".git 瞬态文件应被剔除")
      candidate.cleanup(a.attempt_id)
      vim.fn.delete(dir, "rf")
      vim.fn.delete(base, "rf")
    end)
  end)

  it("包分类：命中遮蔽的文件被剔除", function(t)
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    local candidate = require("NeoAI.sandbox.candidate")
    local control = require("NeoAI.sandbox.control")
    local store = require("NeoAI.sandbox.store")
    local dir = fs.canonical(vim.fn.tempname())
    fs.ensure_dir(dir)
    local base = vim.fn.tempname()
    local upper = base .. "/upper"
    fs.ensure_dir(upper)
    fs.write_file(upper .. "/secret.txt", "s\n")
    with_config({ tools = { sandbox = {
      workspace_root = vim.fn.tempname() .. "/sb",
      mask_paths = { dir },
    } } }, function()
      sandbox.reset()
      local a = control.new_attempt("run_command", {}, {}, { effect = "process" })
      candidate.begin(a, store.root())
      await(candidate.capture_overlay_async(a.attempt_id, dir, upper, nil, { package = true }))
      local cand = await(candidate.finish_async(a.attempt_id, { blob = true, classify = true }))
      for _, f in ipairs(cand.files or {}) do
        t.true_(f.path ~= dir .. "/secret.txt", "遮蔽路径不应进入候选")
      end
      t.not_nil(cand.dropped, "应记录剔除统计")
      t.true_((cand.dropped.masked or 0) >= 1, "应有遮蔽剔除")
      candidate.cleanup(a.attempt_id)
    end)
    vim.fn.delete(dir, "rf")
    vim.fn.delete(base, "rf")
  end)

  it("大候选影响聚合：超过阈值合并为单条，统计仍正确", function(t)
    local observe = require("NeoAI.sandbox.observe")
    local files = {}
    for i = 1, 10 do files[i] = { path = "/tmp/agg/" .. i, action = "create" } end
    local agg = observe.from_candidate({ files = files }, {}, { sample = 3 })
    t.eq(1, #agg, "应聚合为单条")
    t.eq("aggregate", agg[1].action, "应为聚合记录")
    t.eq(10, agg[1].file_count, "应记录文件总数")
    t.eq(10, agg[1].counts.create, "应记录动作计数")
    t.eq(3, #agg[1].sample_paths, "应保留前 N 条采样路径")
    local stats = observe.stats(agg)
    t.eq(10, stats.fs.observed_creates, "统计应含聚合计数")
    local detail = observe.from_candidate({ files = files }, {}, { sample = 20 })
    t.eq(10, #detail, "未超阈值应逐条产出")
  end)
end)
