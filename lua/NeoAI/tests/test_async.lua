local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

tests.suite("async_finally", function(_, it)
  it("finally 保留成功值和原始拒绝对象", function(t)
    local calls = 0
    local value = {}
    t.eq(value, t.await(async.resolve(value):finally(function() calls = calls + 1 end)))
    local original = { kind = "aborted" }
    local failure
    local result = async.reject(original):finally(function() calls = calls + 1 end)
    t.await(result:catch(function(e) failure = e end))
    t.eq(original, failure)
    t.eq("rejected", result._state)
    t.eq(2, calls)
  end)

  it("finally 等待异步清理，并传播清理失败", function(t)
    local gate = async.Deferred.new()
    local result = async.resolve("ok"):finally(function() return gate end)
    vim.wait(30, function() return false end)
    t.true_(result:is_pending())
    gate:resolve("ignored")
    t.eq("ok", t.await(result))
    local error_value = { kind = "cleanup" }
    for _, promise in ipairs({ async.resolve("ok"), async.reject("original") }) do
      local failure
      t.await(promise:finally(function() return async.reject(error_value) end):catch(function(e) failure = e end))
      t.eq(error_value, failure)
    end
    local failure
    t.await(async.resolve("ok"):finally(function() error("cleanup threw") end):catch(function(e) failure = e end))
    t.matches("cleanup threw", failure)
  end)

  it("Agent 运行失败穿过 finally 保持 rejected 并释放占用", function(t)
    local runtime = require("NeoAI.core.agent.runtime")
    local recovery = require("NeoAI.core.agent.recovery")
    local compactor = require("NeoAI.core.session.compactor")
    local send, compact = recovery.send_stream, compactor.maybe_compact
    local expected = { kind = "http", status = 401, message = "unauthorized" }
    recovery.send_stream = function() return async.reject(expected) end
    compactor.maybe_compact = function() return async.resolve(false) end
    local agent = runtime.create({ model = "test" })
    local ok, err = xpcall(function()
      local failure
      local result = runtime.run(agent, "hello")
      t.await(result:catch(function(e) failure = e end))
      t.eq(expected, failure)
      t.eq("rejected", result._state)
      t.nil_(agent._turn_claim)
    end, function(e) return e end)
    recovery.send_stream, compactor.maybe_compact = send, compact
    runtime.dispose(agent)
    if not ok then error(err, 0) end
  end)
end)
