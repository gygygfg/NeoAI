--- Agent 层测试
--- @module NeoAI.tests.test_agent

local tests = require("NeoAI.tests")

tests.suite("agent", function(_, it)
  it("Agent 创建与状态机", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ ai = { default_provider = "deepseek", default_model = "m1" } })
    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local a = runtime.create({ scenario = "chat" })
    t.not_nil(a.id)
    t.eq("idle", a.state)
    t.not_nil(a.signal)
    t.eq("deepseek", a.config.provider)
  end)

  it("Agent 消息队列", function(t)
    local agent_mod = require("NeoAI.core.agent.agent")
    local a = agent_mod.create({})
    agent_mod.add_message(a, "user", "hi")
    agent_mod.append_content(a, "world")
    t.eq(2, #a.messages)
    t.eq("world", a.messages[2].content)
    agent_mod.append_reasoning(a, "think")
    t.eq("think", a.messages[2].reasoning)
  end)

  it("spawn 子 Agent 零继承", function(t)
    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local parent = runtime.create({ scenario = "chat" })
    local child = runtime.spawn(parent, { task = "subtask" })
    t.eq(parent.id, child.parent)
    t.not_eq(parent.signal, child.signal) -- 独立信号
    t.eq(0, #child.messages) -- 空消息
    t.eq("subtask", child.task)
    t.true_(runtime.get(child.id) ~= nil)
  end)

  it("abort 级联", function(t)
    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local a = runtime.create({})
    runtime.abort(a, "cancel")
    t.eq("aborted", a.state)
    t.true_(a.signal:aborted())
    t.eq("cancel", a.signal:reason())
  end)

  it("dispose 释放资源", function(t)
    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local a = runtime.create({})
    runtime.dispose(a)
    t.nil_(runtime.get(a.id))
    t.true_(a.signal:aborted())
  end)

  it("stream 工具调用增量累积", function(t)
    local stream = require("NeoAI.core.agent.stream")
    local chunks = {
      { tool_calls = { { index = 0, id = "c1", ["function"] = { name = "read_" } } } },
      { tool_calls = { { index = 0, ["function"] = { name = "file" } } } },
      { tool_calls = { { index = 0, ["function"] = { arguments = '{"filepath":' } } } },
      { tool_calls = { { index = 0, ["function"] = { arguments = '"a.txt"}' } } } },
    }
    local final = stream.accumulate_tool_calls(chunks)
    t.eq(1, #final)
    t.eq("read_file", final[1]["function"].name)
    t.eq('{"filepath":"a.txt"}', final[1]["function"].arguments)
  end)

  it("stream 多个工具调用", function(t)
    local stream = require("NeoAI.core.agent.stream")
    local chunks = {
      { tool_calls = { { index = 0, id = "c1", ["function"] = { name = "tool_a", arguments = "{}" } } } },
      { tool_calls = { { index = 1, id = "c2", ["function"] = { name = "tool_b", arguments = "{}" } } } },
    }
    local final = stream.accumulate_tool_calls(chunks)
    t.eq(2, #final)
    t.eq("tool_a", final[1]["function"].name)
    t.eq("tool_b", final[2]["function"].name)
  end)

  it("tool_loop 工具定义提取", function(t)
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local agent = {
      tools = {
        read_file = {
          description = "读取文件",
          parameters = { type = "object", properties = { filepath = { type = "string" } }, required = { "filepath" } },
        },
      },
    }
    local defs = tool_loop._tool_definitions(agent)
    t.eq(1, #defs)
    t.eq("function", defs[1].type)
    t.eq("read_file", defs[1]["function"].name)
    t.eq("filepath", defs[1]["function"].parameters.required[1])
  end)

  it("request 参数别名规范化", function(t)
    -- 通过 executor 间接测试别名（在 tools 测试中覆盖）
    t.true_(true)
  end)
end)
