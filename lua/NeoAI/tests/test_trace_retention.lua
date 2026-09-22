--- 轨迹 wire 数据有界保留 + 事件轻量 payload 测试
--- @module NeoAI.tests.test_trace_retention

local tests = require("NeoAI.tests")

--- 构造一轮 wire 元数据（完整形态）
--- @param i number
--- @return table
local function make_round(i)
  return {
    request = {
      model = "m" .. i,
      provider = "p",
      body = {
        stream = true,
        temperature = 0.7,
        messages = { { role = "system" }, { role = "user" } },
        tools = {
          { ["function"] = { name = "t1" } },
          { ["function"] = { name = "t2" } },
          { ["function"] = { name = "t3" } },
        },
      },
    },
    response = {
      finish_reason = "stop",
      usage = { prompt_tokens = 1 },
      ttft_ms = 1,
      total_ms = 2,
      status = "ok",
      raw_chunks = { "a", "b", "c" },
    },
  }
end

tests.suite("trace_retention", function(_, it)
  it("只保留最近 max_rounds 轮完整 wire 数据，旧轮降级为摘要", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ ai = { trace = { max_rounds = 3 } } })
    local runtime = require("NeoAI.core.agent.runtime")
    local agent = runtime.create({ session_id = "trace1" })
    local msgs = {}
    for i = 1, 6 do
      msgs[i] = agent:add_message("assistant", "ok" .. i)
      agent:attach_round(make_round(i))
    end
    t.eq(3, #agent._trace_rounds, "保留窗口应受 max_rounds 约束")
    for i = 4, 6 do
      t.eq("m" .. i, msgs[i].request.model)
      t.eq("table", type(msgs[i].request.body.messages), "最近轮保留完整消息数组")
      t.not_nil(msgs[i].response.raw_chunks, "最近轮保留原始 SSE 分片")
    end
    for i = 1, 3 do
      t.eq("m" .. i, msgs[i].request.model, "摘要保留模型")
      t.eq(2, msgs[i].request.body.message_count, "摘要消息数")
      t.eq(3, msgs[i].request.body.tool_count, "摘要工具数")
      t.nil_(msgs[i].request.body.messages, "摘要不含完整消息数组")
      t.nil_(msgs[i].response.raw_chunks, "摘要不含原始分片")
      t.true_(msgs[i].response.raw_truncated, "摘要标记已截断")
    end
    runtime.dispose(agent)
    t.nil_(agent._trace_rounds, "dispose 后释放保留窗口")
    config_store.load({})
  end)

  it("capture=false 时不保留完整 wire 数据", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ ai = { trace = { capture = false } } })
    local runtime = require("NeoAI.core.agent.runtime")
    local agent = runtime.create({ session_id = "trace2" })
    local m = agent:add_message("assistant", "x")
    agent:attach_round(make_round(1))
    t.nil_(m.request.body.messages, "capture=false 立即摘要")
    t.nil_(m.response.raw_chunks, "capture=false 不保留原始分片")
    t.nil_(agent._trace_rounds, "capture=false 不维护保留窗口")
    runtime.dispose(agent)
    config_store.load({})
  end)

  it("同一 assistant 消息多次 attach（截断续写）不重复占用保留窗口", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ ai = { trace = { max_rounds = 2 } } })
    local runtime = require("NeoAI.core.agent.runtime")
    local agent = runtime.create({ session_id = "trace3" })
    agent:add_message("assistant", "x")
    agent:attach_round(make_round(1))
    agent:attach_round(make_round(2))
    t.eq(1, #agent._trace_rounds, "同一条消息只登记一次")
    runtime.dispose(agent)
    config_store.load({})
  end)

  it("MESSAGE_UPDATED 事件为轻量视图，不携带完整正文", function(t)
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local runtime = require("NeoAI.core.agent.runtime")
    local agent = runtime.create({ session_id = "trace4" })
    local captured = nil
    local unsub = event_bus.on(events.MESSAGE_UPDATED, function(data) captured = data end)
    agent:append_content("hello world")
    unsub()
    t.not_nil(captured)
    t.not_nil(captured.message)
    t.nil_(captured.message.content, "payload 不含正文")
    t.true_(captured.message.has_content, "以 has_content 标志表示正文开始")
    runtime.dispose(agent)
  end)
end)
