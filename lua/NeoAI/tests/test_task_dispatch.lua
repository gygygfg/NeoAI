--- 任务分发（task_dispatch）
--- @module 'NeoAI.tests.test_task_dispatch'
--- 覆盖：同步/异步任务、同步抛错转结构化错误、超时 + on_cancel、并发上限与排队、
---       排队上限拒绝、取消、压力准入（background 暂停 / critical 全停）、reset。
--- 说明：全部使用内存中的假任务，无 IO；超时用例用短超时 + vim.wait。

local tests = require("NeoAI.tests")

local function with_cfg(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local dispatch = require("NeoAI.kernel.task_dispatch")
  local pressure = require("NeoAI.kernel.pressure")
  local saved = config_store.get_all()
  config_store.load(overrides or {})
  dispatch.reset()
  pressure.reset()
  local ok, err = pcall(fn)
  dispatch.reset()
  pressure.reset()
  config_store.load(saved)
  dispatch.reset()
  pressure.reset()
  if not ok then error(err, 0) end
end

--- 等待 Deferred 落定（不抛错），返回 ok, value
--- @param d table
--- @param ms number|nil
--- @return boolean, any
local function settle(d, ms)
  local done, ok, val = false, nil, nil
  d:then_(function(v) ok, val, done = true, v, true end,
    function(e) ok, val, done = false, e, true end)
  vim.wait(ms or 2000, function() return done == true end, 5)
  return ok, val
end

tests.suite("task_dispatch", function(_, it)
  local dispatch = require("NeoAI.kernel.task_dispatch")

  it("同步任务：返回值透传 + 统计", function(t)
    with_cfg({ resources = { dispatch = { enabled = true } } }, function()
      local ok, v = settle(dispatch.submit({ kind = "t", run = function() return 42 end }))
      t.true_(ok)
      t.eq(42, v)
      local stats = dispatch.stats()
      t.eq(1, stats.counters.submitted)
      t.eq(1, stats.counters.completed)
    end)
  end)

  it("异步任务：Deferred 结果透传", function(t)
    with_cfg({ resources = { dispatch = { enabled = true } } }, function()
      local async = require("NeoAI.utils.async")
      local ok, v = settle(dispatch.submit({
        kind = "t", run = function()
          local d = async.Deferred.new()
          vim.defer_fn(function() d:resolve("async-ok") end, 10)
          return d
        end,
      }))
      t.true_(ok)
      t.eq("async-ok", v)
    end)
  end)

  it("同步抛错 → 结构化错误 reject（不冒泡到调用方）", function(t)
    with_cfg({ resources = { dispatch = { enabled = true } } }, function()
      local ok, err = settle(dispatch.submit({
        kind = "boom", run = function() error("kaboom") end,
      }))
      t.false_(ok)
      t.eq("boom", err.kind)
      t.matches("kaboom", err.message)
      t.true_(err.thrown == true)
      t.eq(1, dispatch.stats().counters.failed)
    end)
  end)

  it("超时：reject(timeout) 并调用 on_cancel", function(t)
    with_cfg({ resources = { dispatch = { enabled = true, task_timeout_ms = 50 } } }, function()
      local async = require("NeoAI.utils.async")
      local cancelled = nil
      local ok, err = settle(dispatch.submit({
        kind = "slow",
        run = function() return async.Deferred.new() end, -- 永不完成
        on_cancel = function(reason) cancelled = reason end,
      }), 500)
      t.false_(ok)
      t.true_(err.timeout == true, "应标记 timeout")
      t.eq("timeout", cancelled)
      t.eq(1, dispatch.stats().counters.timeout)
    end)
  end)

  it("并发上限：超出并发的任务排队，不并行执行", function(t)
    with_cfg({ resources = { dispatch = { enabled = true, interactive_parallel = 1 } } }, function()
      local async = require("NeoAI.utils.async")
      local running, max_running = 0, 0
      local tasks = {}
      for i = 1, 3 do
        tasks[i] = dispatch.submit({
          kind = "c" .. i,
          run = function()
            running = running + 1
            max_running = math.max(max_running, running)
            local d = async.Deferred.new()
            vim.defer_fn(function()
              running = running - 1
              d:resolve(i)
            end, 20)
            return d
          end,
        })
      end
      for i = 1, 3 do
        local ok = settle(tasks[i], 2000)
        t.true_(ok)
      end
      t.eq(1, max_running, "并发上限为 1 时不得并行")
      t.eq(3, dispatch.stats().counters.completed)
    end)
  end)

  it("排队上限：超过 queue_max 直接拒绝（带量错误、不抛）", function(t)
    with_cfg({ resources = { dispatch = {
      enabled = true, interactive_parallel = 1, queue_max = 1,
    } } }, function()
      local async = require("NeoAI.utils.async")
      dispatch.submit({ kind = "hold", run = function() return async.Deferred.new() end })
      dispatch.submit({ kind = "q", run = function() return 1 end })
      local ok, err = settle(dispatch.submit({ kind = "over", run = function() return 1 end }))
      t.false_(ok)
      t.true_(err.rejected == true)
      t.eq("queue_full", err.reason)
      dispatch.reset()
    end)
  end)

  it("压力准入：warn 暂停 background，critical 拒绝全部新任务", function(t)
    with_cfg({ resources = {
      pressure = { enabled = true, simulate = "warn" },
      dispatch = { enabled = true, pause_background_on_warn = true, pause_all_on_critical = true },
    } }, function()
      local ok_bg, err_bg = settle(dispatch.submit({
        kind = "bg", lane = "background", run = function() return 1 end,
      }))
      t.false_(ok_bg, "warn 时后台任务应被拒绝")
      t.eq("pressure:warn", err_bg.reason)
      local ok_fg = settle(dispatch.submit({ kind = "fg", run = function() return 2 end }))
      t.true_(ok_fg, "warn 时交互任务仍可执行")
    end)
    with_cfg({ resources = {
      pressure = { enabled = true, simulate = "critical" },
      dispatch = { enabled = true, pause_all_on_critical = true },
    } }, function()
      local ok, err = settle(dispatch.submit({ kind = "fg", run = function() return 1 end }))
      t.false_(ok)
      t.eq("pressure:critical", err.reason)
    end)
  end)

  it("取消：排队中的任务被移除且以 cancelled 结束", function(t)
    with_cfg({ resources = { dispatch = { enabled = true, interactive_parallel = 1 } } }, function()
      local async = require("NeoAI.utils.async")
      dispatch.submit({ kind = "hold", run = function() return async.Deferred.new() end })
      local d = dispatch.submit({ kind = "wait", run = function() return 1 end })
      t.not_nil(d._task_id, "Deferred 应带任务 id")
      t.eq(1, dispatch.stats().lanes.interactive.queued, "第二个任务应排队")
      dispatch.cancel(d._task_id)
      local ok, err = settle(d)
      t.false_(ok)
      t.true_(err.cancelled == true)
      t.eq(0, dispatch.stats().lanes.interactive.queued)
    end)
  end)

  it("dispatch disabled：直通执行且异常仍不冒泡", function(t)
    with_cfg({ resources = { dispatch = { enabled = false } } }, function()
      local ok, v = settle(dispatch.submit({ kind = "t", run = function() return "direct" end }))
      t.true_(ok)
      t.eq("direct", v)
      local ok2, err = settle(dispatch.submit({ kind = "t", run = function() error("x") end }))
      t.false_(ok2)
      t.matches("x", err.message)
    end)
  end)
end)
