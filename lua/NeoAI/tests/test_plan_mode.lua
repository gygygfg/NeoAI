--- 计划模式测试
--- @module NeoAI.tests.test_plan_mode

local tests = require("NeoAI.tests")

tests.suite("plan_mode", function(_, it)
  it("enter/exit/toggle 与提示段生命周期", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local agent = { id = "p1", config = {}, cache = {} }
    t.false_(pm.is_active(agent))
    t.true_(pm.enter(agent))
    t.true_(pm.is_active(agent))
    t.not_nil(agent._plan_section)
    pm.exit(agent)
    t.false_(pm.is_active(agent))
    t.nil_(agent._plan_section)
    t.true_(pm.toggle(agent))
    t.false_(pm.toggle(agent))
    pm.cleanup(agent)
    t.nil_(agent._plan_section)
  end)

  it("计划模式屏蔽修改类工具", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local agent = { id = "p2" }
    local ok = pm.check_tool(agent, "edit_file")
    t.true_(ok)
    pm.enter(agent)
    local ok2, reason2 = pm.check_tool(agent, "edit_file")
    t.false_(ok2)
    t.matches("计划模式", reason2 or "")
    local ok3, reason3 = pm.check_tool(agent, "read_file")
    t.true_(ok3)
    pm.exit(agent)
  end)

  it("restore 还原计划模式状态", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local agent = { id = "p3" }
    pm.restore(agent, { active = true, plan = "执行计划" })
    t.true_(pm.is_active(agent))
    t.eq("执行计划", agent.plan)
    t.not_nil(agent._plan_section)
    pm.cleanup(agent)
  end)

  it("present_plan 批准后退出计划模式", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local agent = { id = "p4" }
    pm.enter(agent)
    local out = {}
    for _, tl in ipairs(pm.get_tools()) do
      if tl.name == "present_plan" then
        tl.func(
          { plan = "P", approved = true },
          function(m) out.msg = m end,
          function(e) out.err = e end,
          { agent = agent })
      end
    end
    t.nil_(out.err)
    t.false_(pm.is_active(agent))
    t.eq("P", agent.plan)
    t.matches("批准", out.msg or "")
  end)

  it("cycle_mode 单键循环 CHAT -> PLAN -> AUTO -> CHAT", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local chat_service = require("NeoAI.services.chat_service")
    local tool_service = require("NeoAI.services.tool_service")
    local pm = require("NeoAI.tools.builtin.plan_mode")
    chat_service.reset()
    tool_service.reset()
    t.eq("chat", chat_service.get_mode(), "初始应为 CHAT")
    t.eq("plan", chat_service.cycle_mode(), "第一次切到 PLAN")
    t.true_(pm.is_active(chat_service.get_current_agent()))
    t.false_(tool_service.is_auto_mode())
    t.eq("auto", chat_service.cycle_mode(), "第二次切到 AUTO")
    t.false_(pm.is_active(chat_service.get_current_agent()))
    t.true_(tool_service.is_auto_mode())
    t.eq("chat", chat_service.cycle_mode(), "第三次回到 CHAT")
    t.false_(pm.is_active(chat_service.get_current_agent()))
    t.false_(tool_service.is_auto_mode())
    chat_service.reset()
    tool_service.reset()
  end)
end)
