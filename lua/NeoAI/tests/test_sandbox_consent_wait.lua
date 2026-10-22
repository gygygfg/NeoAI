--- 同步审批模式下同意窗等待不计入工具超时
--- @module 'NeoAI.tests.test_sandbox_consent_wait'
--- 覆盖：
--- 1. `timer.begin_wait/end_wait`：等待期间不累计活跃耗时、不消耗超时预算；
--- 2. `timer.await`：以 Deferred 结算为驱动，等待时长同样不计入；
--- 3. 嵌套等待（深度计数）只在最内层结束后恢复；
--- 4. 对照：不暂停地等待必然触发超时（确认测试本身有效）；
--- 5. 同意模块的 `request` 已接入该机制（设备/策略/网络/密钥告警）。
---
--- 存在意义：无动态强制层时沙箱退回**同步事前审批**，人看弹窗的时间远长于命令的
--- `timeout_ms`。若等待计入预算，用户还没读完弹窗命令就被判超时——这会让"同步审批"
--- 事实上不可用，并诱导用户调大超时或改用 async（先执行后审批）。

local tests = require("NeoAI.tests")

--- 等待 ms 毫秒（纯阻塞，模拟人看弹窗）
local function sleep(ms)
  vim.wait(ms, function() return false end)
end

tests.suite("sandbox_consent_wait", function(_, it)
  it("等待期间不累计耗时、不触发超时", function(t)
    local timer = require("NeoAI.utils.timer")
    local tm = timer.create()
    local fired = false
    tm.on_timeout = function() fired = true end
    tm:start(300)

    timer.begin_wait()
    sleep(600) -- 远超 300ms 预算
    t.eq(0, math.floor(tm:elapsed()), "等待期间活跃耗时应为 0")
    t.eq(false, fired, "等待期间不得触发超时")
    timer.end_wait()

    sleep(150) -- 恢复后正常累计
    t.ok(tm:elapsed() >= 100, "恢复后应继续累计耗时")
    t.eq(false, fired, "预算内仍不得触发超时")
    tm:stop()
  end)

  it("对照：不暂停时等待 600ms 必超时（确认用例有效）", function(t)
    local timer = require("NeoAI.utils.timer")
    local tm = timer.create()
    local fired = false
    tm.on_timeout = function() fired = true end
    tm:start(300)
    vim.wait(600, function() return fired end)
    t.eq(true, fired, "不暂停的等待应触发超时")
    tm:stop()
  end)

  it("嵌套等待：只在最深一层结束后恢复计时", function(t)
    local timer = require("NeoAI.utils.timer")
    local tm = timer.create()
    tm.on_timeout = function() end
    tm:start(300)

    timer.begin_wait()
    sleep(120)
    timer.begin_wait() -- 嵌套（同意窗内再触发子流程）
    sleep(120)
    timer.end_wait()   -- 外层仍在等待：不得恢复
    sleep(120)
    t.eq(0, math.floor(tm:elapsed()), "外层仍在等待时不得恢复累计")
    timer.end_wait()
    sleep(120)
    t.ok(tm:elapsed() >= 80, "全部结束后应恢复累计")
    tm:stop()
  end)

  it("timer.await：以结算为驱动，等待时长不计入预算", function(t)
    local timer = require("NeoAI.utils.timer")
    local async = require("NeoAI.utils.async")
    local tm = timer.create()
    local fired = false
    tm.on_timeout = function() fired = true end
    tm:start(300)

    local inner = async.Deferred.new()
    local wrapped = timer.await(inner)
    local got = nil
    wrapped:then_(function(v) got = v end)

    sleep(450) -- 超过预算的等待
    t.eq(false, fired, "await 等待期间不得触发超时")
    t.eq(0, math.floor(tm:elapsed()), "await 等待期间活跃耗时应为 0")

    inner:resolve("ok")
    vim.wait(200, function() return got ~= nil end) -- 回调经微任务/调度派发，需让循环跑一轮
    t.eq("ok", got, "结算值应原样透传")
    t.eq(false, fired, "结算后不得补触发超时")
    tm:stop()
  end)

  it("timer.await：拒绝路径同样恢复计时（不泄漏暂停状态）", function(t)
    local timer = require("NeoAI.utils.timer")
    local async = require("NeoAI.utils.async")
    local tm = timer.create()
    tm.on_timeout = function() end
    tm:start(300)

    local inner = async.Deferred.new()
    local wrapped = timer.await(inner)
    local err = nil
    wrapped:then_(function() end, function(e) err = e end)
    inner:reject({ kind = "denied" })
    vim.wait(200, function() return err ~= nil end)
    t.not_nil(err, "错误应原样透传")

    sleep(120)
    t.ok(tm:elapsed() >= 80, "拒绝后应恢复累计（无残留暂停）")
    tm:stop()
  end)

  it("同意模块的 request 均已接入等待暂停机制", function(t)
    --- 各模块 `request` 被包装为返回 `timer.await(...)` 的结果；无 UI 时立即结算，
    --- 此处只校验接入存在（源码断言），避免依赖真实弹窗。
    --- 路径必须绝对化：多套件并行时 cwd 不保证是仓库根（相对路径会 E484）。
    local mods = {
      "NeoAI.sandbox.review.device_consent",
      "NeoAI.sandbox.review.policy_consent",
      "NeoAI.sandbox.net.net_consent",
      "NeoAI.sandbox.secret.secret_alert",
    }
    for _, m in ipairs(mods) do
      local mod = require(m)
      local info = debug.getinfo(mod.request, "S")
      local path = info and info.source and info.source:gsub("^@", "") or nil
      t.not_nil(path, "应能定位模块源文件: " .. m)
      local content = table.concat(vim.fn.readfile(path), "\n")
      t.ok(content:find("timer", 1, true) ~= nil and
        content:find("await(_request(", 1, true) ~= nil,
        m .. " 的 request 应包装为等待不计入超时")
    end
  end)
end)
