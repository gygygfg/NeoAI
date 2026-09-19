--- 计划模式测试
--- @module NeoAI.tests.test_plan_mode

local tests = require("NeoAI.tests")

tests.suite("plan_mode", function(_, it)
  it("enter/exit/toggle 与计划模式状态（系统提示段废弃，改运行时快照）", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local agent = { id = "p1", config = {}, cache = {} }
    t.false_(pm.is_active(agent))
    t.true_(#pm.policy_text() > 0, "policy_text 供运行时上下文快照复用")
    t.true_(pm.enter(agent))
    t.true_(pm.is_active(agent))
    t.nil_(agent._plan_section, "不再注册系统提示段")
    pm.exit(agent)
    t.false_(pm.is_active(agent))
    t.nil_(agent._plan_section)
    t.true_(pm.toggle(agent))
    t.false_(pm.toggle(agent))
    pm.cleanup(agent)
    t.nil_(agent._plan_section)
  end)

  it("计划模式屏蔽可见集之外的任何工具", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local agent = { id = "p2" }
    -- 非计划模式：全部放行
    t.true_(pm.check_tool(agent, "edit_file"))
    t.true_(pm.check_tool(agent, "run_command"))
    pm.enter(agent)
    -- 修改类 / 系统命令 / 子 Agent 调度：计划模式下全部驳回
    local ok2, reason2 = pm.check_tool(agent, "edit_file")
    t.false_(ok2)
    t.matches("计划模式", reason2 or "")
    t.true_(pm.check_tool(agent, "run_command"), "计划模式放行 run_command（只读调研）")
    t.false_(pm.check_tool(agent, "create_sub_agent"))
    t.false_(pm.check_tool(agent, "todo_write"))
    -- 只读/信息查询 + ask_user：放行；模式切换工具不提供给 AI
    t.true_(pm.check_tool(agent, "read_file"))
    t.true_(pm.check_tool(agent, "git_status"))
    t.true_(pm.check_tool(agent, "ask_user"))
    t.false_(pm.check_tool(agent, "exit_plan_mode"), "计划模式不向 AI 提供模式切换工具")
    pm.exit(agent)
    t.true_(pm.check_tool(agent, "edit_file"))
  end)

  it("计划模式工具上下文只保留只读/信息查询 + run_command + ask_user", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local registry = require("NeoAI.tools.registry")
    local agent = { id = "p5" }
    local tools = registry.list_as_map()
    if not tools.edit_file then
      -- 注册表未初始化（无 setup 环境）：跳过
      t.true_(true)
      return
    end
    local full = pm.apply_tool_filter(agent, tools)
    t.not_nil(full.edit_file, "非计划模式不限制工具上下文")
    pm.enter(agent)
    local filtered = pm.apply_tool_filter(agent, tools)
    t.nil_(filtered.edit_file, "计划模式不暴露 edit_file")
    t.not_nil(filtered.run_command, "计划模式保留 run_command（只读调研）")
    t.nil_(filtered.create_sub_agent, "计划模式不暴露 create_sub_agent")
    t.nil_(filtered.delete_file, "计划模式不暴露 delete_file")
    t.nil_(filtered.lsp_rename, "计划模式不暴露 lsp_rename")
    t.not_nil(filtered.read_file, "计划模式保留 read_file")
    t.not_nil(filtered.ask_user, "计划模式保留 ask_user")
    t.nil_(filtered.exit_plan_mode, "计划模式不向 AI 提供模式切换工具")
    t.not_nil(filtered.git_status, "计划模式保留 git_status")
    t.not_nil(filtered.lsp_diagnostics, "计划模式保留 lsp_diagnostics")
    pm.exit(agent)
    local restored = pm.apply_tool_filter(agent, tools)
    t.not_nil(restored.edit_file, "退出计划模式后恢复完整工具上下文")
  end)

  it("restore 还原计划模式状态", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local agent = { id = "p3" }
    pm.restore(agent, { active = true, plan = "执行计划" })
    t.true_(pm.is_active(agent))
    t.eq("执行计划", agent.plan)
    t.nil_(agent._plan_section, "不再注册系统提示段")
    t.true_(#pm.policy_text() > 0)
    pm.cleanup(agent)
  end)

  it("plan_to_todos 解析格式化计划为任务清单", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local items = pm.plan_to_todos([[
# 修改计划
## 目标
修复登录 bug
## 步骤
- [ ] 定位问题
- 修改 auth.lua
1. 补充测试
2. 运行测试
]])
    t.eq(4, #items)
    t.eq("定位问题", items[1].content)
    t.eq("修改 auth.lua", items[2].content)
    t.eq("补充测试", items[3].content)
    t.eq("运行测试", items[4].content)
    -- 无列表项时回退到 Markdown 标题
    local items2 = pm.plan_to_todos("## 第一步\n## 第二步")
    t.eq(2, #items2)
    -- 纯文本压缩为一项
    local items3 = pm.plan_to_todos("随便一段没有结构的文字")
    t.eq(1, #items3)
    t.eq(0, #pm.plan_to_todos(""))
    t.eq(0, #pm.plan_to_todos(nil))
  end)

  it("approve_plan 确认后直接转入 CHAT 并建立任务清单", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      tools = {
        approval = { mode = "prompt", per_tool = {} },
        plan_mode = { auto_execute_on_approve = false },
      },
    })
    local chat_service = require("NeoAI.services.chat_service")
    local tool_service = require("NeoAI.services.tool_service")
    local todo = require("NeoAI.tools.builtin.todo")
    local pm = require("NeoAI.tools.builtin.plan_mode")
    chat_service.reset()
    tool_service.reset()
    todo.reset()

    local agent = chat_service.new_session({})
    t.true_(pm.enter(agent))
    -- 模拟 AI 在计划模式下输出的格式化计划（最后一条 assistant 消息）
    local plan_message = "- 步骤一：修改 core/init.lua\n- 步骤二：更新测试\n- 步骤三：运行验证"
    agent:add_message("assistant", plan_message)

    local result = chat_service.approve_plan({ auto_execute = false })
    t.true_(result.approved, "应确认成功")
    t.eq(3, result.todo_count)
    t.true_(result.plan:find("步骤一", 1, true) ~= nil)
    -- 直接转入 CHAT 模式
    t.false_(pm.is_active(agent))
    t.eq("chat", chat_service.get_mode())
    t.eq(plan_message, agent.plan)
    -- 任务清单已建立
    local items = todo.get(agent.session_id)
    t.not_nil(items)
    t.eq(3, #items)
    t.eq("pending", items[1].status)
    chat_service.reset()
    tool_service.reset()
    todo.reset()
  end)

  it("不向 AI 注册模式切换工具（exit_plan_mode）", function(t)
    local pm = require("NeoAI.tools.builtin.plan_mode")
    for _, tl in ipairs(pm.get_tools()) do
      t.ne("exit_plan_mode", tl.name, "不应再向 AI 暴露 exit_plan_mode 工具")
    end
    -- 注册表（AI 实际工具上下文）中同样不存在
    local registry = require("NeoAI.tools.registry")
    t.nil_(registry.get("exit_plan_mode"), "注册表中不应存在 exit_plan_mode")
  end)

  it("approve_plan 无计划 / 非计划模式下失败", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      tools = {
        approval = { mode = "prompt", per_tool = {} },
        plan_mode = { auto_execute_on_approve = false },
      },
    })
    local chat_service = require("NeoAI.services.chat_service")
    local tool_service = require("NeoAI.services.tool_service")
    local todo = require("NeoAI.tools.builtin.todo")
    chat_service.reset()
    tool_service.reset()
    todo.reset()

    -- 非计划模式：拒绝
    local agent = chat_service.new_session({})
    local r1 = chat_service.approve_plan({ auto_execute = false })
    t.false_(r1.approved)
    t.matches("计划模式", r1.error or "")
    -- 计划模式但 AI 尚未输出计划：拒绝
    require("NeoAI.tools.builtin.plan_mode").enter(agent)
    local r2 = chat_service.approve_plan({ auto_execute = false })
    t.false_(r2.approved)
    t.matches("计划", r2.error or "")
    chat_service.reset()
    tool_service.reset()
    todo.reset()
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

  it("生成中切换模式延迟到本轮结束后应用，不打断当前回合", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local chat_service = require("NeoAI.services.chat_service")
    local tool_service = require("NeoAI.services.tool_service")
    local pm = require("NeoAI.tools.builtin.plan_mode")
    chat_service.reset()
    tool_service.reset()

    local agent = chat_service.new_session({})
    -- 模拟正在生成（generating）
    agent.state = "generating"
    t.false_(pm.is_active(agent))

    local target = chat_service.cycle_mode()
    t.eq("plan", target, "生成中切模式应立即返回目标模式")
    t.eq("plan", chat_service.get_mode(), "get_mode 应反映目标模式")
    t.true_(chat_service.has_pending_mode(), "生成中应暂存模式切换")
    t.false_(pm.is_active(agent), "生成中不得立即改工具集/模式，以免打断当前回合")

    -- 本轮结束：Agent 回到 idle，触发状态事件后应用暂存模式
    agent:set_state("idle")
    t.true_(pm.is_active(agent), "空闲后应应用暂存的计划模式")
    t.false_(chat_service.has_pending_mode(), "应用后应清空暂存")
    t.eq("plan", chat_service.get_mode())

    chat_service.reset()
    tool_service.reset()
  end)

  it("生成中切到 AUTO 立即生效并自动批准当前待审批项", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local chat_service = require("NeoAI.services.chat_service")
    local tool_service = require("NeoAI.services.tool_service")
    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    local todo = require("NeoAI.tools.builtin.todo")
    chat_service.reset()
    tool_service.reset()
    todo.reset()

    registry.register(helpers.define_tool(
      "auto_now_tool", "自动", { type = "object", properties = {}, required = {} },
      function(args, on_success) on_success("ran") end
    ))

    -- 审批 UI：记录弹窗是否被展示（切 AUTO 后不应再弹）
    local showed = false
    tool_service.set_approval_ui({
      show = function() showed = true end,
      hide = function() end,
    })

    local agent = chat_service.new_session({})
    agent.state = "generating" -- 模拟生成中

    -- 生成中发起一个需要审批的工具调用：应弹窗等待
    local done, err = false, nil
    tool_service.execute(agent, "auto_now_tool", { description = "生成中审批" }, nil, {}):then_(
      function() done = true end,
      function(e) err = e; done = true end
    )
    t.true_(showed, "prompt 模式下应先弹审批窗")
    t.true_(tool_service.has_pending_approval(), "应存在待审批项")

    -- 生成中切到 AUTO：应立即生效并自动批准当前待审批项，而不是等到本轮结束
    local target = chat_service.cycle_mode()
    t.eq("plan", target, "CHAT -> PLAN（生成中）")
    target = chat_service.cycle_mode()
    t.eq("auto", target, "PLAN -> AUTO")
    t.true_(tool_service.is_auto_mode(), "生成中切到 AUTO 应立即生效（auto_mode=true）")
    t.true_(chat_service.has_pending_mode(), "工具集/模型切换仍应暂存到本轮结束")
    t.false_(tool_service.has_pending_approval(), "AUTO 开启后待审批项应被自动批准")

    -- 被暂存的审批项已批准并执行
    local waited = vim.wait(1000, function() return done end)
    t.true_(waited, "待审批工具应在 AUTO 后立即执行完毕")
    t.nil_(err, "自动批准后不应报错: " .. tostring(err and err.message or err))

    chat_service.reset()
    tool_service.reset()
    todo.reset()
  end)

  it("AUTO 模式下 enter_plan_mode 自动退出 AUTO 并转入 PLAN", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local chat_service = require("NeoAI.services.chat_service")
    local tool_service = require("NeoAI.services.tool_service")
    local pm = require("NeoAI.tools.builtin.plan_mode")
    chat_service.reset()
    tool_service.reset()

    local agent = chat_service.new_session({})
    -- 先切到 AUTO 模式
    tool_service.set_auto_mode(true)
    t.true_(tool_service.is_auto_mode())
    t.eq("auto", chat_service.get_mode())

    -- AI 在 AUTO 模式下调用 enter_plan_mode 工具
    local tool
    for _, tl in ipairs(pm.get_tools()) do
      if tl.name == "enter_plan_mode" then tool = tl end
    end
    t.not_nil(tool, "应注册 enter_plan_mode 工具")
    local out = {}
    tool.func({}, function(m) out.msg = m end, function(e) out.err = e end, { agent = agent })

    t.nil_(out.err)
    t.true_(pm.is_active(agent), "应进入计划模式")
    t.false_(tool_service.is_auto_mode(), "进入计划模式必须关闭 AUTO")
    t.eq("plan", chat_service.get_mode(), "状态栏应反映 PLAN 而非 AUTO")

    chat_service.reset()
    tool_service.reset()
  end)
end)
