--- 上下文溢出恢复测试
--- @module NeoAI.tests.test_overflow

local tests = require("NeoAI.tests")

tests.suite("overflow", function(_, it)
  it("识别上下文溢出错误", function(t)
    local request = require("NeoAI.core.agent.request")
    t.true_(request.is_context_overflow({
      kind = "http", status = 400,
      body = '{"error":{"message":"This model maximum context length is 128000 tokens."}}',
    }))
    t.true_(request.is_context_overflow({ kind = "http", status = 400, message = "prompt is too long" }))
    t.true_(request.is_context_overflow({ kind = "http", status = 413, body = "request too large" }))
    t.false_(request.is_context_overflow({ kind = "http", status = 401, message = "unauthorized" }))
    t.false_(request.is_context_overflow({ kind = "http", status = 500, message = "server error" }))
    t.false_(request.is_context_overflow({ kind = "aborted" }))
    t.false_(request.is_context_overflow("string error"))
  end)

  it("force_compact：无可折叠内容时返回 false（不触发 API）", function(t)
    local compactor = require("NeoAI.core.session.compactor")
    local agent = { id = "c1", state = "idle", messages = {}, cache = {}, config = {} }
    local done = false
    local result
    compactor.force_compact(agent):then_(function(r) done = true; result = r end, function() done = true; result = false end)
    vim.wait(1500, function() return done end)
    t.true_(done)
    t.false_(result)
  end)

  it("recovery：上下文溢出时压缩后重试请求", function(t)
    local async = require("NeoAI.utils.async")
    local calls = { 0 }
    local compacted = { false }
    local request_stub = {
      is_context_overflow = function() return true end,
      send_stream = function()
        calls[1] = calls[1] + 1
        if calls[1] == 1 then
          return async.reject({ kind = "http", status = 400, message = "context window exceeded" })
        end
        return async.resolve({ content = "ok", tool_calls = nil, usage = nil })
      end,
    }
    local compactor_stub = {
      force_compact = function() compacted[1] = true; return async.resolve(true) end,
    }
    local prev_req = package.loaded["NeoAI.core.agent.request"]
    local prev_comp = package.loaded["NeoAI.core.session.compactor"]
    package.loaded["NeoAI.core.agent.request"] = request_stub
    package.loaded["NeoAI.core.session.compactor"] = compactor_stub

    local recovery = require("NeoAI.core.agent.recovery")
    local agent = {
      id = "r1", messages = {}, tools = nil,
      config = {}, model = "m", signal = async.create_signal(), cache = {},
    }
    local done = false
    local result
    recovery.send_stream(agent, { agent_config = agent.config, model = agent.model, signal = agent.signal }):then_(
      function(r) done = true; result = r end,
      function(e) done = true; result = e end)
    vim.wait(2000, function() return done end)

    package.loaded["NeoAI.core.agent.request"] = prev_req
    package.loaded["NeoAI.core.session.compactor"] = prev_comp

    t.true_(done)
    t.true_(compacted[1])
    t.eq(2, calls[1])
    t.eq("ok", result and result.content)
  end)

  it("recovery：非溢出错误原样抛出，不压缩", function(t)
    local async = require("NeoAI.utils.async")
    local compacted = { false }
    local request_stub = {
      is_context_overflow = function() return false end,
      send_stream = function()
        return async.reject({ kind = "http", status = 500, message = "boom" })
      end,
    }
    local compactor_stub = {
      force_compact = function() compacted[1] = true; return async.resolve(true) end,
    }
    local prev_req = package.loaded["NeoAI.core.agent.request"]
    local prev_comp = package.loaded["NeoAI.core.session.compactor"]
    package.loaded["NeoAI.core.agent.request"] = request_stub
    package.loaded["NeoAI.core.session.compactor"] = compactor_stub

    local recovery = require("NeoAI.core.agent.recovery")
    local agent = {
      id = "r2", messages = {}, tools = nil,
      config = {}, model = "m", signal = async.create_signal(), cache = {},
    }
    local done = false
    local err
    recovery.send_stream(agent, { agent_config = agent.config, model = agent.model, signal = agent.signal }):then_(
      function() done = true end,
      function(e) done = true; err = e end)
    vim.wait(2000, function() return done end)

    package.loaded["NeoAI.core.agent.request"] = prev_req
    package.loaded["NeoAI.core.session.compactor"] = prev_comp

    t.true_(done)
    t.false_(compacted[1])
    t.eq(500, err and err.status)
  end)
end)
