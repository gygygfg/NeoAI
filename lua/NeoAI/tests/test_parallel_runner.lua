--- 并行测试运行器专项测试
--- @module NeoAI.tests.test_parallel_runner
--- 通过注入假 spawner 验证分片均衡、聚合、失败与发现路径，不启动真实子进程。

local tests = require("NeoAI.tests")
local parallel = require("NeoAI.tests.parallel")

tests.suite("parallel_runner", function(_, it, before_each)
  before_each(function()
    parallel.reset()
  end)

  local function manifest_output(suites, load_errors)
    local lines = {}
    for _, s in ipairs(suites) do
      lines[#lines + 1] = ("SUITE %s %d"):format(s.name, s.cases)
    end
    for _, e in ipairs(load_errors or {}) do
      lines[#lines + 1] = "LOADFAIL:: " .. e
    end
    return table.concat(lines, "\n") .. "\n"
  end

  it("分片：LPT 贪心把最重套件独立成档", function(t)
    local suites = {
      { name = "a", cases = 10 }, { name = "b", cases = 1 },
      { name = "c", cases = 1 }, { name = "d", cases = 1 },
    }
    local bins, loads = parallel.shard(suites, 2)
    t.eq(2, #bins)
    local sizes = { #bins[1], #bins[2] }
    table.sort(sizes)
    t.deep_eq({ 1, 3 }, sizes, "重套件应独占一档")
    t.eq(10, math.max(loads[1], loads[2]), "最大负载等于最重套件")
  end)

  it("分片：结果可复现", function(t)
    local suites = {
      { name = "a", cases = 4 }, { name = "b", cases = 4 },
      { name = "c", cases = 2 }, { name = "d", cases = 1 },
    }
    local b1 = parallel.shard(suites, 3)
    local b2 = parallel.shard(suites, 3)
    t.deep_eq(vim.inspect(b1), vim.inspect(b2), "同一输入应得到同一分片")
  end)

  it("分片：workers 多于套件时产生空分片", function(t)
    local bins = parallel.shard({ { name = "x", cases = 1 } }, 4)
    t.eq(4, #bins)
    local empties = 0
    for _, b in ipairs(bins) do
      if #b == 0 then empties = empties + 1 end
    end
    t.eq(3, empties)
  end)

  it("分片：显式权重覆盖用例数", function(t)
    local suites = { { name = "fast", cases = 100 }, { name = "slow", cases = 1 } }
    local _, loads = parallel.shard(suites, 2, { fast = 1, slow = 1000 })
    t.eq(1000, math.max(loads[1], loads[2]), "应按实测权重而非用例数均衡")
  end)

  it("发现：解析 SUITE 与 LOADFAIL 行", function(t)
    parallel._set_spawner(function(_, o)
      o.on_done({ output = manifest_output({ { name = "alpha", cases = 3 }, { name = "beta", cases = 5 } },
        { "加载测试模块 x 失败" }), ok = false })
    end)
    local d = parallel._discover({ discovery_timeout_ms = 1000 })
    t.eq(2, #d.suites)
    t.eq("alpha", d.suites[1].name)
    t.eq(3, d.suites[1].cases)
    t.eq(1, #d.load_errors)
  end)

  it("发现：清单为空判定为错误", function(t)
    parallel._set_spawner(function(_, o)
      o.on_done({ output = "nothing here\n", ok = false })
    end)
    local d = parallel._discover({ discovery_timeout_ms = 1000 })
    t.not_nil(d.error, "空清单应返回 error")
  end)

  it("run：聚合各分片 passed/failed 并写入耗时缓存", function(t)
    local suites = { { name = "s1", cases = 5 }, { name = "s2", cases = 3 }, { name = "s3", cases = 1 } }
    local pass_by = { s1 = 5, s2 = 2, s3 = 1 }
    local fail_by = { s2 = 1 }
    parallel._set_spawner(function(req, o)
      if not req.names then
        o.on_done({ output = manifest_output(suites), ok = true })
        return
      end
      local pass, fail, errs = 0, 0, {}
      for _, n in ipairs(req.names) do
        pass = pass + (pass_by[n] or 0)
        fail = fail + (fail_by[n] or 0)
        if fail_by[n] then errs[#errs + 1] = n .. " :: boom" end
      end
      local lines = { ("SUMMARY passed=%d failed=%d"):format(pass, fail) }
      for _, n in ipairs(req.names) do lines[#lines + 1] = ("TIMING %s 12.5"):format(n) end
      o.on_done({
        output = table.concat(lines, "\n"),
        ok = fail == 0,
        passed = pass,
        failed = fail,
        errors = errs,
        exit_code = fail == 0 and 0 or 1,
      })
    end)
    local tp = vim.fn.tempname() .. "_timings.json"
    local r = parallel.run({ workers = 2, timings_path = tp })
    t.eq(8, r.passed, "8 个用例通过")
    t.eq(1, r.failed, "s2 有 1 个失败")
    t.eq(1, #r.errors)
    t.eq(2, #r.shards, "2 个 worker 应产生 2 个分片")
    -- 耗时缓存应落盘：12.5 四舍五入为 13
    local f = io.open(tp, "r")
    t.not_nil(f, "耗时缓存应已写入")
    if f then
      local data = vim.json.decode(f:read("*a"))
      f:close()
      t.eq(13, data.s1, "耗时按整数毫秒缓存")
      t.eq(13, data.s3)
    end
    vim.fn.delete(tp)
  end)

  it("run：仅运行指定套件", function(t)
    local suites = { { name = "s1", cases = 1 }, { name = "s2", cases = 1 } }
    local seen = {}
    parallel._set_spawner(function(req, o)
      if not req.names then
        o.on_done({ output = manifest_output(suites), ok = true })
        return
      end
      for _, n in ipairs(req.names) do seen[n] = true end
      o.on_done({ output = "SUMMARY passed=2 failed=0\n", ok = true, passed = 2, failed = 0, errors = {}, exit_code = 0 })
    end)
    local tp = vim.fn.tempname() .. "_timings.json"
    local r = parallel.run({ workers = 4, suites = { "s2" }, timings_path = tp })
    t.true_(seen.s2, "应运行指定套件")
    t.nil_(seen.s1, "不应运行未指定套件")
    t.eq(1, #r.shards, "过滤后仅一个分片")
    t.eq(0, r.failed)
    vim.fn.delete(tp)
  end)

  it("run：分片无 SUMMARY 计为失败并保留输出", function(t)
    local suites = { { name = "only", cases = 1 } }
    parallel._set_spawner(function(req, o)
      if not req.names then
        o.on_done({ output = manifest_output(suites), ok = true })
        return
      end
      o.on_done({ output = "panic: boom", ok = false, passed = 0, failed = 0, errors = {}, exit_code = 1 })
    end)
    local tp = vim.fn.tempname() .. "_timings.json"
    local r = parallel.run({ workers = 1, timings_path = tp })
    t.eq(1, r.failed, "异常退出分片计 1 个失败")
    t.eq(1, #r.shards)
    t.matches("panic", r.shards[1].output, "应保留分片原始输出")
    vim.fn.delete(tp)
  end)

  it("run：发现失败直接判定为失败", function(t)
    parallel._set_spawner(function(_, o)
      o.on_done({ output = "", ok = false })
    end)
    local tp = vim.fn.tempname() .. "_timings.json"
    local r = parallel.run({ wait = true, timings_path = tp })
    t.eq(1, r.failed)
    t.eq(0, r.passed)
    t.matches("未发现任何测试套件", r.errors[1])
    vim.fn.delete(tp)
  end)

  it("run：资源重套件走串行通道（单独子进程）", function(t)
    local suites = { { name = "sandbox_x", cases = 1 }, { name = "s1", cases = 1 } }
    local spawns = {}
    parallel._set_spawner(function(req, o)
      if not req.names then
        o.on_done({ output = manifest_output(suites), ok = true })
        return
      end
      spawns[#spawns + 1] = { names = req.names, serial = req.serial }
      local pass = #req.names
      o.on_done({ output = ("SUMMARY passed=%d failed=0\n"):format(pass), ok = true, passed = pass, failed = 0, errors = {}, exit_code = 0 })
    end)
    local tp = vim.fn.tempname() .. "_timings.json"
    local r = parallel.run({ workers = 4, timings_path = tp })
    t.eq(0, r.failed)
    local serial_seen = false
    for _, sp in ipairs(spawns) do
      if sp.serial then
        serial_seen = true
        t.eq(1, #sp.names, "串行通道每次只跑一个套件")
        t.eq("sandbox_x", sp.names[1])
      end
    end
    t.true_(serial_seen, "sandbox_x 应走串行通道")
    vim.fn.delete(tp)
  end)

  it("run：worker 数被套件数钳制", function(t)
    local suites = { { name = "s1", cases = 1 } }
    parallel._set_spawner(function(req, o)
      if not req.names then
        o.on_done({ output = manifest_output(suites), ok = true })
        return
      end
      o.on_done({ output = "SUMMARY passed=1 failed=0\n", ok = true, passed = 1, failed = 0, errors = {}, exit_code = 0 })
    end)
    local tp = vim.fn.tempname() .. "_timings.json"
    local r = parallel.run({ workers = 8, timings_path = tp })
    t.eq(1, r.workers, "套件数少于 worker 数时应钳制")
    vim.fn.delete(tp)
  end)

  it("reset 恢复默认 spawner", function(t)
    parallel._set_spawner(function() end)
    parallel.reset()
    t.eq(1, vim.fn.filereadable(tests._plugin_root() .. "/lua/NeoAI/tests/parallel.lua"),
      "插件根应可定位（回归定位能力）")
  end)
end)
