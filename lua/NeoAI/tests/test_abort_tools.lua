--- 工具执行中取消（ESC）后的运行态一致性测试
--- @module NeoAI.tests.test_abort_tools
--- 回归：工具在途时取消，Agent 必须回到 idle 并释放生成占用；后续消息直接开启新轮，
--- 而不是被吞进 pending_queue 永远“待发”。此前的缺陷是工具循环在成功分支里把 abort 的
--- aborted 状态覆写回 generating，随后发生在本链内部的拒绝绕过了 runtime 的错误回调。

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

tests.suite("abort_tools", function(_, it)
  local function init_chat()
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1" },
      session = { save_path = "/tmp/neoai_test_abort_tools", file = "s.jsonl" },
      tools = { approval = { mode = "auto_allow" } },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_abort_tools/s.jsonl")
    session_store.init()
    return chat
  end

  it("工具在途时取消：终态 idle、占用释放、后续消息不再排队", function(t)
    local chat = init_chat()
    local services = require("NeoAI.kernel.services")
    local runtime = require("NeoAI.core.agent.runtime")
    local agent = chat.new_session({})
    agent.config = { temperature = 0, max_tokens = 100, stream = true, provider = "mock", model = "m1" }

    local saved_ts = services.use("services.tool_service")
    local tool_gate = async.Deferred.new()
    local executed = false
    services.provide("services.tool_service", {
      execute = function()
        executed = true
        return tool_gate:then_(function() return "工具结果" end)
      end,
    })

    local orig_recovery = package.loaded["NeoAI.core.agent.recovery"]
    local rounds = 0
    package.loaded["NeoAI.core.agent.recovery"] = {
      send_stream = function(_, _opts, on_chunk)
        rounds = rounds + 1
        if rounds == 1 then
          on_chunk({ tool_calls = {
            { index = 0, id = "c1", type = "function", ["function"] = { name = "read_file", arguments = "{}" } },
          } })
          return async.resolve({})
        end
        on_chunk({ content = "后续回答" })
        return async.resolve({})
      end,
    }

    local d = runtime.run(agent, "go")
    t.true_(vim.wait(2000, function() return executed end), "工具应被调用")
    t.eq("tool_running", agent.state, "工具执行中状态应为 tool_running")

    -- 工具在途时取消，随后工具成功返回（模拟 ESC 后进程被终止并按 aborted 结果落库）
    runtime.abort(agent, "user_cancelled")
    tool_gate:resolve(true)

    local settled = vim.wait(3000, function() return not d:is_pending() end)
    t.true_(settled, "run 应结束")
    t.eq("idle", agent.state, "取消后应回到 idle（不得卡在 generating）")
    t.nil_(agent._turn_claim, "取消后生成占用应释放")
    t.false_(chat.has_pending_work(), "取消后不应被判为仍有工作")

    -- 后续消息应直接开始新轮（不为 busy），而不是被暂存
    local d2 = chat.send_message("下一条")
    t.eq(0, chat.pending_count(), "取消后新消息不应再入待发队列")
    vim.wait(2000, function() return not d2:is_pending() end)

    package.loaded["NeoAI.core.agent.recovery"] = orig_recovery
    services.provide("services.tool_service", saved_ts)
    runtime.reset()
    chat.reset()
  end)

  it("工具调用附带 agent.signal，取消可传播到执行层", function(t)
    local agent_mod = require("NeoAI.core.agent.agent")
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local agent = agent_mod.create({ config = {} })
    local captured = nil
    local ts = {
      execute = function(_, _, _, _, opts)
        captured = opts and opts.signal
        agent.signal:abort("user_cancelled")
        return async.resolve("r")
      end,
    }
    local calls = { { id = "a", type = "function", ["function"] = { name = "read_file", arguments = "{}" } } }
    local d = tool_loop.run(agent, calls, ts, {})
    t.true_(vim.wait(2000, function() return not d:is_pending() end), "工具循环应 settle")
    t.eq(agent.signal, captured, "exec_opts.signal 应为 agent.signal")
    t.eq("rejected", d._state, "取消后工具循环应 reject")
  end)
end)
