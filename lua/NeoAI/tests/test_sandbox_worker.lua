--- 后台 worker（posix_spawn + 并行任务槽）回归
--- @module 'NeoAI.tests.test_sandbox_worker'
--- 覆盖：posix_spawn 回收、单 worker 并行、按需启动、空闲回收、停止清理。
--- 默认测试禁用远程 worker；本套件显式 NEOAI_TEST_WORKER=1，结束后恢复。

local tests = require("NeoAI.tests")

local function await(d, timeout)
  local done, val, err = false, nil, nil
  d:then_(function(v) val = v; done = true end, function(e) err = e; done = true end)
  vim.wait(timeout or 10000, function() return done end, 20)
  return val, err
end

local function wait_until(fn, timeout)
  local ok = vim.wait(timeout or 5000, fn, 20)
  return ok == true and fn() == true
end

tests.suite("sandbox_worker", function(_, it)
  local function setup()
    vim.env.NEOAI_TEST_WORKER = "1"
    local work = require("NeoAI.utils.work")
    local rw = require("NeoAI.utils.remote_work")
    rw.reset()
    vim.wait(300, function() return false end, 20)
    return work, rw
  end

  local function teardown(rw)
    rw.stop(500)
    wait_until(function() return rw.status().pid == nil and not rw.status().connected end, 3000)
    rw.reset()
    vim.env.NEOAI_TEST_WORKER = nil
    vim.env.NEOAI_WORKER_IDLE_TTL_MS = nil
  end

  it("posix_spawn：启动并非阻塞回收子进程", function(t)
    local ps = require("NeoAI.utils.posix_spawn")
    t.true_(ps.available(), "posix_spawn 应可用")
    local pid, err = ps.spawn({ "/bin/true" }, {})
    t.not_nil(pid, "应启动子进程: " .. tostring(err))
    t.true_(wait_until(function()
      local r = ps.reap(pid)
      return r ~= nil
    end, 3000), "应可回收")
    t.false_(ps.alive(pid), "回收后进程不应存活")
  end)

  it("work.run_codec：任务在 worker 进程执行，主进程 pid 不同", function(t)
    local work, rw = setup()
    local main_pid = vim.uv.os_getpid()
    local res, err = await(work.run_codec(function(data)
      return { value = data.value * 2, pid = vim.uv.os_getpid() }
    end, { value = 21 }), 15000)
    t.true_(err == nil, "不应失败: " .. tostring(err and (err.message or err) or ""))
    t.eq(42, res and res.value, "结果应由 worker 返回")
    t.not_nil(rw.status().pid, "应记录 worker pid")
    t.true_((res and res.pid) ~= main_pid, "任务必须在独立 worker 进程执行")
    teardown(rw)
  end)

  it("按任务并行：多个任务在同一个 worker 内并行完成", function(t)
    local work, rw = setup()
    local pending, results = 4, {}
    local t0 = vim.uv.hrtime()
    for i = 1, 4 do
      work.run(function(ms)
        vim.uv.sleep(ms)
        return "ok"
      end, 250):then_(function(v)
        results[i] = v
        pending = pending - 1
      end, function(e)
        results[i] = tostring(e and (e.message or e) or e)
        pending = pending - 1
      end)
    end
    wait_until(function() return pending == 0 end, 8000)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    t.eq(0, pending, "所有任务应完成")
    for i = 1, 4 do t.eq("ok", results[i], "任务 " .. i .. " 应成功") end
    t.true_(ms < 900, ("4×250ms 应并行完成（实测 %.0fms）"):format(ms))
    local jobs = rw.status()
    t.eq(1, jobs.pid and 1 or 0, "只应有一个 worker 进程")
    teardown(rw)
  end)

  it("空闲回收：idle TTL 后退出，下次任务重新拉起", function(t)
    vim.env.NEOAI_WORKER_IDLE_TTL_MS = "300"
    local work, rw = setup()
    local r1 = await(work.run_codec(function(d) return { v = d.v } end, { v = 1 }), 15000)
    t.eq(1, r1 and r1.v)
    local pid1 = rw.status().pid
    t.not_nil(pid1)
    t.true_(wait_until(function() return not rw.status().connected end, 6000),
      "空闲后应断开/回收")
    t.true_(wait_until(function() return rw.status().pid == nil end, 3000),
      "空闲后应清空 worker pid")
    local r2 = await(work.run_codec(function(d) return { v = d.v } end, { v = 2 }), 15000)
    t.eq(2, r2 and r2.v, "下一次任务应重新拉起 worker")
    local pid2 = rw.status().pid
    t.not_nil(pid2)
    t.true_(pid2 ~= pid1, "应使用新的 worker 进程")
    teardown(rw)
  end)
end)
