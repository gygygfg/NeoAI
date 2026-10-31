--- 取消订阅（Signal）生命周期测试
--- @module 'NeoAI.tests.test_signal_unsub'
--- 回归：长生命周期 agent.signal 上的订阅必须在进程结算后反注册，否则同一会话内每次
--- exec/web_fetch/resident 调用都会向同一 signal 追加永不释放的监听器，导致内存无界增长。
--- 历史缺陷：exec._spawn / runtime.run / resident / web_fetch._run_bash_host 只 subscribe
--- 不保存返回的 unsub。

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

tests.suite("signal_unsub", function(_, it)
  local function wait_until(f, timeout_ms)
    local deadline = vim.uv.hrtime() / 1e6 + (timeout_ms or 3000)
    while not f() do
      if vim.uv.hrtime() / 1e6 > deadline then return false end
      vim.wait(15)
    end
    return true
  end

  --- 临时撤销 `services.sandbox`（强制无沙箱直执行分支），结束后（含断言失败）恢复原服务。
  --- 不恢复会让同分片后续套件全部出现「沙箱服务未初始化」的假失败。
  --- @param fn function
  local function with_sandbox_revoked(fn)
    local services = require("NeoAI.kernel.services")
    local prev = services.has("services.sandbox") and services.use("services.sandbox") or nil
    services.revoke("services.sandbox")
    local ok, err = pcall(fn)
    if prev then services.provide("services.sandbox", prev) end
    if not ok then error(err, 0) end
  end

  it("Signal:subscribe 返回的 unsub 能移除监听器", function(t)
    local s = async.create_signal()
    local un1 = s:subscribe(function() end)
    local un2 = s:subscribe(function() end)
    t.eq(2, #s._listeners)
    un1()
    t.eq(1, #s._listeners)
    un2()
    t.eq(0, #s._listeners)
    un2() -- 幂等：重复调用不报错、不误删
    t.eq(0, #s._listeners)
  end)

  it("exec._spawn 结算后反注册 signal 监听器", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1" },
      tools = { sandbox = { enabled = false } },
    })
    with_sandbox_revoked(function()
      local exec = require("NeoAI.sandbox.execution.exec")
      local signal = async.create_signal()
      t.eq(0, #signal._listeners)

      local done, res = false, nil
      exec.run({ "true" }, { signal = signal }):then_(function(r)
        res = r
        done = true
      end, function()
        done = true
      end)
      t.true_(wait_until(function() return done end), "进程应结束")
      t.not_nil(res)
      t.eq(0, #signal._listeners, "结算后监听器必须清空")
    end)
  end)

  it("多次调用不累积监听器", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1" },
      tools = { sandbox = { enabled = false } },
    })
    with_sandbox_revoked(function()
      local exec = require("NeoAI.sandbox.execution.exec")
      local signal = async.create_signal()
      for _ = 1, 3 do
        local done = false
        exec.run({ "true" }, { signal = signal }):then_(function() done = true end,
          function() done = true end)
        t.true_(wait_until(function() return done end))
        t.eq(0, #signal._listeners, "每轮结算后监听器必须清空")
      end
    end)
  end)
end)
