--- 子 Agent 结果回传测试
--- @module NeoAI.tests.test_sub_agent_result

local tests = require("NeoAI.tests")

tests.suite("sub_agent_result", function(_, it)
  it("注册了 wait_sub_agent 工具", function(t)
    local plan = require("NeoAI.tools.builtin.plan")
    local names = {}
    for _, tl in ipairs(plan.get_tools()) do
      names[tl.name] = true
    end
    t.true_(names["wait_sub_agent"])
    t.true_(names["create_sub_agent"])
    t.true_(names["get_sub_agent_status"])
  end)

  it("wait 对不存在的子 Agent 立即拒绝", function(t)
    local plan = require("NeoAI.tools.builtin.plan")
    local done = false
    local err
    plan.wait("nope_123"):then_(function() done = true end, function(e) done = true; err = e end)
    vim.wait(1000, function() return done end)
    t.true_(done)
    t.matches("不存在", err and err.message or "")
  end)

  it("wait 在完成事件后 resolve", function(t)
    local plan = require("NeoAI.tools.builtin.plan")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    plan._allow_tools_for_test("sub_test_1", { "read_file" })

    local done = false
    local entry
    plan.wait("sub_test_1"):then_(function(e) done = true; entry = e end, function() done = true end)
    vim.wait(500, function() return done end)
    t.false_(done) -- 尚未完成，应仍挂起

    event_bus.emit(events.SUB_AGENT_COMPLETED, { sub_agent_id = "sub_test_1" })
    vim.wait(1000, function() return done end)
    t.true_(done)
    t.not_nil(entry)
    t.eq("sub_test_1", entry.id)
  end)

  it("get_sub_agent_status 返回结果文本", function(t)
    local plan = require("NeoAI.tools.builtin.plan")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    plan._allow_tools_for_test("sub_test_2", { "read_file" })
    -- 标记完成并写入结果
    event_bus.emit(events.SUB_AGENT_COMPLETED, { sub_agent_id = "sub_test_2" })

    local out = {}
    for _, tl in ipairs(plan.get_tools()) do
      if tl.name == "get_sub_agent_status" then
        tl.func({ sub_agent_id = "sub_test_2" }, function(m) out.msg = m end, function(e) out.err = e end)
      end
    end
    t.nil_(out.err)
    t.matches("状态", out.msg or "")
    t.matches("工具调用", out.msg or "")
  end)
end)
