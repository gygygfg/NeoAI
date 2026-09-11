--- 输出截断续写测试
--- @module NeoAI.tests.test_truncation
--- 验证：模型输出被截断（finish_reason=length/max_tokens/MAX_TOKENS）且本轮无工具调用时，
--- 自动附加续写提示重发（提示只进请求 wire、不落库），直到获得正文/工具调用或达到次数
--- 上限；仍被截断则写入可见提示，避免工具循环静默退出。

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

tests.suite("truncation", function(_, it)
  local function init()
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "deepseek",
        default_model = "m1",
        truncation = { enabled = true, max_continues = 3 },
      },
      session = { save_path = "/tmp/neoai_test_truncation", file = "s.jsonl" },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_truncation/s.jsonl")
    session_store.init()
    return chat
  end

  it("is_truncated 识别各协议截断原因", function(t)
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    t.true_(tool_loop.is_truncated("length"))
    t.true_(tool_loop.is_truncated("max_tokens"))
    t.true_(tool_loop.is_truncated("MAX_TOKENS"))
    t.false_(tool_loop.is_truncated("stop"))
    t.false_(tool_loop.is_truncated("tool_calls"))
    t.false_(tool_loop.is_truncated(nil))
  end)

  it("工具循环截断后自动续写（提示不落库）", function(t)
    local chat = init()
    local agent = chat.new_session({})
    agent.config = { temperature = 0, stream = true, provider = "mock", model = "m1" }

    local calls = 0
    local nudges = {}
    local original = package.loaded["NeoAI.core.agent.recovery"]
    package.loaded["NeoAI.core.agent.recovery"] = {
      send_stream = function(_, opts, on_chunk)
        calls = calls + 1
        nudges[calls] = opts and opts.extra_user
        if calls == 1 then
          return async.resolve({ finish_reason = "length" })
        end
        on_chunk({ content = "续写内容" })
        return async.resolve({ finish_reason = "stop" })
      end,
    }
    local tool_service = { execute = function() return async.resolve("工具结果") end }

    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local d = tool_loop.run(agent, {
      { id = "t1", type = "function", ["function"] = { name = "tool1", arguments = "{}" } },
    }, tool_service, {})
    vim.wait(5000, function() return not d:is_pending() end)
    package.loaded["NeoAI.core.agent.recovery"] = original

    t.eq(2, calls, "应在截断后自动续写一次")
    t.not_nil(nudges[2], "续写请求应携带 extra_user 提示")
    t.eq(1, agent._truncation_continues, "续写计数应为 1")
    t.eq("续写内容", agent.messages[#agent.messages].content, "最终应为续写正文")
    for _, m in ipairs(agent.messages) do
      t.false_(m.role == "user" and m.content == nudges[2], "续写提示不应落库")
    end
  end)

  it("续写达到上限后写可见截断提示", function(t)
    local chat = init()
    local agent = chat.new_session({})
    agent.config = { temperature = 0, stream = true, provider = "mock", model = "m1" }

    local calls = 0
    local original = package.loaded["NeoAI.core.agent.recovery"]
    package.loaded["NeoAI.core.agent.recovery"] = {
      send_stream = function()
        calls = calls + 1
        return async.resolve({ finish_reason = "length" })
      end,
    }
    local tool_service = { execute = function() return async.resolve("工具结果") end }

    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local d = tool_loop.run(agent, {
      { id = "t1", type = "function", ["function"] = { name = "tool1", arguments = "{}" } },
    }, tool_service, {})
    vim.wait(5000, function() return not d:is_pending() end)
    package.loaded["NeoAI.core.agent.recovery"] = original

    t.eq(4, calls, "首轮 + 最多 3 次续写")
    t.eq(3, agent._truncation_continues)
    local last = agent.messages[#agent.messages]
    t.eq(tool_loop.TRUNCATED_MESSAGE, last.content, "应写可见截断提示")
  end)

  it("非截断空响应不触发续写", function(t)
    local chat = init()
    local agent = chat.new_session({})
    agent.config = { temperature = 0, stream = true, provider = "mock", model = "m1" }

    local calls = 0
    local original = package.loaded["NeoAI.core.agent.recovery"]
    package.loaded["NeoAI.core.agent.recovery"] = {
      send_stream = function()
        calls = calls + 1
        return async.resolve({ finish_reason = "stop" })
      end,
    }
    local tool_service = { execute = function() return async.resolve("工具结果") end }

    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local d = tool_loop.run(agent, {
      { id = "t1", type = "function", ["function"] = { name = "tool1", arguments = "{}" } },
    }, tool_service, {})
    vim.wait(5000, function() return not d:is_pending() end)
    package.loaded["NeoAI.core.agent.recovery"] = original

    t.eq(1, calls, "非截断不应续写")
    t.eq(0, agent._truncation_continues, "非截断不应消耗续写预算")
  end)
end)
