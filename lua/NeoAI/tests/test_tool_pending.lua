--- 工具循环期间用户消息的轮末注入测试（端到端）
--- @module NeoAI.tests.test_tool_pending
--- 验证：agent 忙碌期间发送的用户消息被暂存后，在工具循环中途（本轮工具结果记录完、
--- 下次模型调用之前）被注入对话，供下一轮模型感知；循环结束后不再另开一轮。
--- 通过桩掉 recovery.send_stream 与 tool_service.execute 控制多轮循环。

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

tests.suite("tool_pending", function(_, it)
  local function init_chat()
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1" },
      session = { save_path = "/tmp/neoai_test_tool_pending", file = "s.jsonl" },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_tool_pending/s.jsonl")
    session_store.init()
    return chat
  end

  it("多轮工具循环中注入，循环结束后不再开新轮", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent.config = { temperature = 0, max_tokens = 100, stream = true, provider = "mock", model = "m1" }

    -- 桩 recovery.send_stream：控制每一轮模型调用返回 工具调用 还是 纯文本
    local snapshots = {}
    local call = 0
    local original_recovery = package.loaded["NeoAI.core.agent.recovery"]
    package.loaded["NeoAI.core.agent.recovery"] = {
      send_stream = function(ag, _opts, on_chunk)
        call = call + 1
        local roles = {}
        for _, m in ipairs(ag.messages) do
          roles[#roles + 1] = m.role .. ":" .. tostring(m.content or "")
        end
        snapshots[#snapshots + 1] = { call = call, roles = roles }
        if call == 1 then
          on_chunk({ tool_calls = {
            { index = 0, id = "c1", type = "function", ["function"] = { name = "tool2", arguments = "{}" } },
          } })
        else
          on_chunk({ content = "最终回答" })
        end
        return async.resolve({})
      end,
    }
    local tool_service = {
      execute = function() return async.resolve("工具结果") end,
    }

    -- 用户在 agent 忙碌时发送后续消息 -> 暂存
    agent:set_state("tool_running")
    local d = chat.send_message("用户后续指令")
    t.true_(d:is_pending(), "busy 时用户消息应暂存")

    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local initial_tool_calls = {
      { id = "t1", type = "function", ["function"] = { name = "tool1", arguments = "{}" } },
    }
    local result = tool_loop.run(agent, initial_tool_calls, tool_service, {})
    local resolved = vim.wait(5000, function() return result:is_resolved() end)
    package.loaded["NeoAI.core.agent.recovery"] = original_recovery

    t.true_(resolved, "tool_loop.run 应 resolve")

    -- 用户消息被注入对话、且只出现一次（不产生重复/另开一轮）
    local injected_index = nil
    for i, m in ipairs(agent.messages) do
      if m.role == "user" and m.content == "用户后续指令" then
        injected_index = injected_index or i
        t.false_(injected_index ~= i and true, "用户消息不应重复出现（否则说明另开一轮重发）")
      end
    end
    t.not_nil(injected_index, "用户消息应被注入对话")
    t.true_(injected_index > 1, "注入不应是第一条消息")

    -- 注入发生在上一轮工具结果之后（round 边界），而非循环末尾追加后另开一轮
    local before_tool = false
    local next_assistant = false
    for i, m in ipairs(agent.messages) do
      if i < injected_index and m.role == "tool" then before_tool = true end
      if i > injected_index and m.role == "assistant" then next_assistant = true end
    end
    t.true_(before_tool, "注入前应已有工具结果（上一轮循环边界）")
    t.true_(next_assistant, "注入后应紧接下一轮 assistant")
    t.true_(injected_index < #agent.messages, "注入消息不应是末条（否则是追加到循环末尾后另开一轮）")

    -- 循环继续而非另开一轮：最终回答仍是最后一条
    t.eq("最终回答", agent.messages[#agent.messages].content, "最终回答应是循环最后一条消息")

    -- 下一次模型调用（第二轮）应携带注入消息，证明它是"下个 Turn 之前"被感知的
    local saw = false
    for _, s in ipairs(snapshots) do
      for _, r in ipairs(s.roles) do
        if s.call > 1 and r:find("用户后续指令", 1, true) then saw = true end
      end
    end
    t.true_(saw, "循环内的后续模型调用应看到注入的用户消息")

    -- 暂存 Deferred 已 resolve，不会另开一轮
    t.true_(d:is_resolved(), "注入后用户消息 Deferred 应 resolve")
  end)
end)
