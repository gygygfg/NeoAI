--- 可暂停工具计时器测试
--- @module NeoAI.tests.test_timer
--- 覆盖：暂停期间不累计耗时、暂停期间不触发超时（等待审批/ask_user 的场景）、
--- 恢复后按剩余活跃预算触发超时、stop 后 elapsed 为累计活跃耗时。

local tests = require("NeoAI.tests")

local timer_mod = require("NeoAI.utils.timer")

tests.suite("timer", function(_, it)
  it("elapsed 剔除暂停时间，stop 固化活跃耗时", function(t)
    local tr = timer_mod.create()
    tr:start(100000) -- 大预算，不触发超时

    local snap = {}
    vim.defer_fn(function()
      tr:pause()
      snap.pause_elapsed = tr:elapsed()
      -- 暂停 200ms：elapsed 不应显著增长
      vim.defer_fn(function()
        snap.after_idle_elapsed = tr:elapsed()
        tr:resume()
        -- 再运行约 60ms
        vim.defer_fn(function()
          tr:stop()
          snap.stopped_elapsed = tr:elapsed()
          snap.done = true
        end, 60)
      end, 200)
    end, 80)

    vim.wait(3000, function() return snap.done end)
    t.true_(snap.done, "计时器应在限定时间内完成")
    t.true_(snap.pause_elapsed >= 60, "暂停前应累计约 80ms: " .. tostring(snap.pause_elapsed))
    t.true_(snap.after_idle_elapsed - snap.pause_elapsed < 30,
      "暂停期间 elapsed 不应增长: " .. tostring(snap.after_idle_elapsed - snap.pause_elapsed))
    t.true_(snap.stopped_elapsed - snap.after_idle_elapsed >= 40,
      "恢复后应继续累计: " .. tostring(snap.stopped_elapsed - snap.after_idle_elapsed))
    tr:stop()
  end)

  it("暂停期间超过预算也不触发超时；恢复后按剩余预算超时", function(t)
    local tr = timer_mod.create()
    local fired = false
    local snap = {}
    tr.on_timeout = function() fired = true end
    tr:start(100) -- 100ms 预算

    vim.defer_fn(function()
      tr:pause() -- ~30ms 后暂停
      -- 暂停远超预算（400ms）：不应超时
      vim.defer_fn(function()
        local paused_elapsed = tr:elapsed()
        local still_ok = not fired
        tr:resume()
        -- 剩余活跃预算约 70ms，恢复后应在预算内触发超时；
        -- 155ms 后（超过剩余预算）取值，此时超时必已发生。
        vim.defer_fn(function()
          snap.fired_after = fired
          snap.still_ok = still_ok
          snap.paused_elapsed = paused_elapsed
          snap.final_elapsed = tr:elapsed()
          snap.done = true
        end, 155)
      end, 400)
    end, 30)

    vim.wait(4000, function() return snap.done end)
    t.true_(snap.done, "计时器应在限定时间内完成")
    t.true_(snap.fired_after, "恢复后累计活跃达预算应触发超时")
    t.ok(snap.still_ok, "暂停期间不应触发超时")
    t.true_(snap.paused_elapsed < 150, "暂停期间 elapsed 应很小: " .. tostring(snap.paused_elapsed))
    -- 允许 floor 毫秒取整带来的少许偏差（剩余预算 ~70ms 被向下取整）
    t.true_(snap.final_elapsed >= 90, "超时后活跃耗时应接近预算: " .. tostring(snap.final_elapsed))
  end)

  it("executor: 等待用户交互的工具耗时剔除等待时间", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "auto_allow", per_tool = {} }, executor = { timeout_ms = 100 } } })
    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")

    -- 交互式工具：600ms 后自动"回答"，远超 100ms 超时预算；工具应成功且耗时接近 0
    registry.register(helpers.define_tool(
      "wait_ui_tool", "等待用户", { type = "object", properties = {}, required = {} },
      function(args, on_success, on_error, ctx)
        if ctx and ctx.timer and ctx.timer.pause then pcall(ctx.timer.pause, ctx.timer) end
        vim.defer_fn(function()
          if ctx and ctx.timer and ctx.timer.resume then pcall(ctx.timer.resume, ctx.timer) end
          on_success("answered")
        end, 600)
      end,
      { category = "system" }
    ))

    local async = require("NeoAI.utils.async")
    local exec = require("NeoAI.tools.executor")
    local tr = timer_mod.create()
    local agent = { id = "wait-agent" }
    local outcome = {}
    exec.execute("wait_ui_tool", { description = "测试等待" }, {
      timer = tr, agent = agent, signal = async.create_signal(),
    }):then_(function(r)
      outcome.result = r
      outcome.active = tr:elapsed()
      outcome.done = true
    end, function(e)
      outcome.error = e and e.message or e
      outcome.done = true
    end)

    vim.wait(4000, function() return outcome.done end)
    t.eq("answered", outcome.result, "等待后工具应成功返回")
    t.true_(outcome.active < 200, "等待用户的时间不应计入耗时，实际 " .. tostring(outcome.active))
    t.nil_(outcome.error, "不应因超时而失败")
  end)
end)
