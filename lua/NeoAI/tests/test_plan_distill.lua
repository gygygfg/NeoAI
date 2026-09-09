--- 计划蒸馏测试
--- @module NeoAI.tests.test_plan_distill

local tests = require("NeoAI.tests")

tests.suite("plan_distill", function(_, it)
  it("_window 按进入计划模式的边界切分 front/window", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local msgs = {
      { role = "user", content = "a" },
      { role = "assistant", content = "b" },
      { role = "user", content = "c" },
      { role = "assistant", content = "d" },
    }
    local window, front = p._window({ messages = msgs, _plan_enter_index = 2 })
    t.eq(2, #front, "plan 入口之前的消息归入 front")
    t.eq(2, #window, "plan 入口之后的调研消息归入 window")
    t.eq("a", front[1].content)
    t.eq("c", window[1].content)
  end)

  it("_window 无 _plan_enter_index 时窗口为全部消息、front 为空", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local msgs = { { role = "user", content = "a" }, { role = "assistant", content = "b" } }
    local window, front = p._window({ messages = msgs })
    t.eq(0, #front)
    t.eq(2, #window)
  end)

  it("_chunk 按编号拆分正文/推理/工具调用/工具结果且不重复", function(t)
    local p = require("NeoAI.core.session.plan_distill")
    local msgs = {
      { role = "assistant", reasoning = "思考", content = "正文" },
      { role = "assistant", tool_calls = { { ["function"] = { name = "read_file", arguments = "{}" } } } },
      { role = "tool", name = "read_file", content = "result" },
    }
    local c = p._chunk(msgs)
    t.eq(4, #c)
    t.eq(1, c[1].n); t.matches("正文", c[1].label)
    t.eq(2, c[2].n); t.matches("推理", c[2].label)
    t.eq(3, c[3].n); t.matches("read_file", c[3].label)
    t.eq(4, c[4].n); t.matches("read_file", c[4].label)
    t.eq("result", c[4].text, "工具结果只标一次，不重复正文")
  end)

  it("plan_mode.enter 记录 _plan_enter_index 并重置 _plan_distilled", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local agent = { messages = { { role = "user", content = "a" }, { role = "assistant", content = "b" } } }
    agent._plan_distilled = true
    pm.enter(agent)
    t.eq(2, agent._plan_enter_index)
    t.false_(agent._plan_distilled, "进入计划模式应重置「已蒸馏」标记")
  end)

  it("run: distill_on_execute=false 时 no-op，不改动历史", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = false } } })
    local p = require("NeoAI.core.session.plan_distill")
    local agent = { messages = { { role = "user", content = "a" }, { role = "assistant", content = "p" } }, _plan_enter_index = 1 }
    local ok, done = nil, false
    p.run(agent):then_(function(r) ok = r; done = true end)
    vim.wait(2000, function() return done end, 5)
    t.false_(ok, "蒸馏关闭时应返回 false")
    t.eq(2, #agent.messages, "历史不被改动")
  end)

  it("run: 窗口分块过小时 no-op，不触发分类", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { plan_mode = { distill_on_execute = true, auto_execute_on_approve = true } } })
    local p = require("NeoAI.core.session.plan_distill")
    local agent = { messages = { { role = "user", content = "a" } }, _plan_enter_index = 0 }
    local ok, done = nil, false
    p.run(agent, { min_chunks = 10 }):then_(function(r) ok = r; done = true end)
    vim.wait(2000, function() return done end, 5)
    t.false_(ok, "分块过少应 no-op")
    t.eq(1, #agent.messages)
  end)
end)
