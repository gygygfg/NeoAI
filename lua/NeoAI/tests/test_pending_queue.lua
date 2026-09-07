--- 消息暂存 / 轮末注入测试
--- @module NeoAI.tests.test_pending_queue
--- 覆盖：agent 忙碌（tool_running/generating）期间用户发送的消息被 pending_queue
--- 暂存，不会立刻写进对话；工具循环轮末（工具结果记录后、下次模型调用前）由
--- chat_service 注册的注入器把暂存消息插入对话，供下一轮模型感知。

local tests = require("NeoAI.tests")

tests.suite("pending_queue", function(_, it)
  local function init_chat()
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1" },
      session = { save_path = "/tmp/neoai_test_pending", file = "s.jsonl" },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_pending/s.jsonl")
    session_store.init()
    return chat
  end

  it("busy 期间暂存，round 边界才注入对话", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent:set_state("tool_running")
    local d = chat.send_message("用户后续消息")
    -- 忙碌期间消息只暂存，不应写进对话
    t.eq(0, #agent.messages, "busy 时不应立即写入对话")
    t.true_(d:is_pending(), "暂存消息的 Deferred 应仍挂起")

    -- 模拟工具循环轮末（_loop 在下次 _send_round 前调用 inject_pending）
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    tool_loop.inject_pending(agent)

    t.eq(1, #agent.messages, "轮末应把暂存消息注入对话")
    t.eq("user", agent.messages[1].role)
    t.eq("用户后续消息", agent.messages[1].content)
    t.true_(d:is_resolved(), "注入后 Deferred 应 resolve")
  end)

  it("无暂存消息时注入为 no-op", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    tool_loop.inject_pending(agent)
    t.eq(0, #agent.messages, "无暂存时不应注入任何消息")
  end)

  it("多次暂存按顺序全部注入", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent:set_state("generating")
    chat.send_message("第一条")
    chat.send_message("第二条")
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    tool_loop.inject_pending(agent)
    t.eq(2, #agent.messages)
    t.eq("第一条", agent.messages[1].content)
    t.eq("第二条", agent.messages[2].content)
  end)

  it("reset 后清空暂存并注销注入器", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent:set_state("tool_running")
    chat.send_message("将被取消")
    chat.reset()
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    tool_loop.inject_pending(agent)
    t.eq(0, #agent.messages, "reset 后暂存已清空，不应再注入")
  end)
end)
