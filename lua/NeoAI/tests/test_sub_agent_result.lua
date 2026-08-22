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

  it("create_sub_agent 不因 _allowed_tools 全局缺失而崩溃（回归）", function(t)
    local plan = require("NeoAI.tools.builtin.plan")
    local runtime = require("NeoAI.core.agent.runtime")
    local async = require("NeoAI.utils.async")
    plan.reset()
    -- stub runtime.spawn/run 避免真实启动子 Agent
    local orig_spawn, orig_run = runtime.spawn, runtime.run
    runtime.spawn = function(_, opts)
      return { id = "fake_sub", tools = {}, messages = {} }
    end
    runtime.run = function(_, _)
      return async.resolve({ content = "done" })
    end

    local tool
    for _, tl in ipairs(plan.get_tools()) do
      if tl.name == "create_sub_agent" then tool = tl break end
    end
    t.not_nil(tool, "应注册 create_sub_agent 工具")

    local out = {}
    local ok, err = pcall(tool.func, { task = "t", mode = "background" },
      function(m) out.msg = m end, function(e) out.err = e end,
      { agent = { id = "parent" } })
    t.true_(ok, "create_sub_agent 不应抛错（此前调用全局 _allowed_tools 崩溃），实际: " .. tostring(err))
    t.nil_(out.err, "create_sub_agent 不应返回错误")
    t.matches("已创建", out.msg or "")

    -- 前台模式同样不崩溃
    local out2 = {}
    local ok2, err2 = pcall(tool.func, { task = "fg", mode = "foreground" },
      function(m) out2.msg = m end, function(e) out2.err = e end,
      { agent = { id = "parent" } })
    t.true_(ok2, "前台模式 create_sub_agent 不应抛错，实际: " .. tostring(err2))
    t.nil_(out2.err, "前台模式 create_sub_agent 不应返回错误")

    runtime.spawn, runtime.run = orig_spawn, orig_run
    plan.reset()
  end)
end)
