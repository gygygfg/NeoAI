--- 子 Agent 工具与管理器测试
--- @module 'NeoAI.tests.test_sub_agent_result'

local tests = require("NeoAI.tests")

tests.suite("sub_agent_result", function(_, it)
  it("注册了整理后的调度类工具（无 wait）", function(t)
    local plan = require("NeoAI.tools.builtin.plan")
    local names = {}
    for _, tl in ipairs(plan.get_tools()) do
      names[tl.name] = true
    end
    t.true_(names["create_sub_agent"])
    t.true_(names["get_sub_agent_status"])
    t.true_(names["cancel_sub_agent"])
    t.true_(names["send_sub_agent_message"])
    t.nil_(names["wait_sub_agent"], "不应再提供等待工具")
  end)

  it("默认子 Agent 工具集为全部非 Agent 类工具", function(t)
    local plan = require("NeoAI.tools.builtin.plan")
    local tools = plan._allowed_tools(nil)
    t.not_nil(tools.run_command, "默认应包含 run_command")
    t.not_nil(tools.read_file, "默认应包含 read_file")
    -- Agent 类（category == "agent"）一律排除
    t.nil_(tools.create_sub_agent, "不得包含 create_sub_agent")
    t.nil_(tools.send_sub_agent_message, "不得包含 send_sub_agent_message")
    t.nil_(tools.cancel_sub_agent, "不得包含 cancel_sub_agent")
    t.nil_(tools.enter_plan_mode, "不得包含 enter_plan_mode")
    t.nil_(tools.todo_write, "不得包含 todo_write")
  end)

  it("显式 allowed_tools 仍排除 Agent 类工具", function(t)
    local plan = require("NeoAI.tools.builtin.plan")
    local tools = plan._allowed_tools({ "read_file", "create_sub_agent", "todo_write" })
    t.not_nil(tools.read_file)
    t.nil_(tools.create_sub_agent)
    t.nil_(tools.todo_write)
  end)

  it("子 Agent 工具子集排除调度类工具", function(t)
    local manager = require("NeoAI.core.agent.sub_agent")
    local runtime = require("NeoAI.core.agent.runtime")
    local session_store = require("NeoAI.core.session.session_store")
    local async = require("NeoAI.utils.async")
    manager.reset()

    local orig_spawn, orig_run, orig_create = runtime.spawn, runtime.run, session_store.create
    local captured = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    session_store.create = function() return { id = "sess_sub_test" } end
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.spawn = function(_, override)
      captured.session_id = override.session_id
      captured.child = { id = "child1", tools = {}, messages = {} }
      return captured.child
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.run = function(_, prompt)
      captured.prompt = prompt
      return async.resolve({ content = "SUM" })
    end

    local entry = manager.create({ id = "parent1", session_id = "sess_parent", cwd = "/tmp" }, {
      task = "调研 A",
      tools = { read_file = {}, create_sub_agent = {}, cancel_sub_agent = {} },
    })
    t.not_nil(entry)
    -- 子 Agent 工具子集排除调度类工具
    t.not_nil(captured.child.tools.read_file, "只读工具应保留")
    t.nil_(captured.child.tools.create_sub_agent, "不得下发 create_sub_agent")
    t.nil_(captured.child.tools.cancel_sub_agent, "不得下发 cancel_sub_agent")
    -- 提示自动追加收尾指令
    t.matches("最后请总结你的工作", captured.prompt or "")
    -- 会话创建 + 登记
    t.eq("sess_sub_test", entry.session_id)

    runtime.spawn, runtime.run, session_store.create = orig_spawn, orig_run, orig_create
    manager.reset()
  end)

  it("子 Agent 自然结束回传正文给主 Agent", function(t)
    local manager = require("NeoAI.core.agent.sub_agent")
    local runtime = require("NeoAI.core.agent.runtime")
    local session_store = require("NeoAI.core.session.session_store")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local async = require("NeoAI.utils.async")
    manager.reset()

    local orig_spawn, orig_run, orig_get, orig_create =
      runtime.spawn, runtime.run, runtime.get, session_store.create
    local child = { id = "child1", tools = {}, messages = { { role = "assistant", content = "FINAL-BODY" } } }
    ---@diagnostic disable-next-line: duplicate-set-field
    session_store.create = function() return { id = "sess_sub_test" } end
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.spawn = function() return child end
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.run = function() return async.resolve({ content = "FINAL-BODY" }) end
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.get = function(id) if id == "child1" then return child end return nil end

    local got = {}
    manager.set_dispatch(function(agent, text, fallback, meta)
      got.agent = agent
      got.text = text
      got.fallback = fallback
      got.meta = meta
    end)
    manager.set_persist(function() end)

    local entry = manager.create({ id = "parent1", session_id = "sess_parent", cwd = "/tmp" },
      { task = "调研 A", tools = { read_file = {} } })
    t.eq("running", entry.status)
    -- 循环自然结束 → GENERATION_COMPLETED 事件驱动回传
    event_bus.emit(events.GENERATION_COMPLETED, { agent_id = "child1" })
    vim.wait(200, function() return entry.status ~= "running" end)

    t.eq("completed", entry.status)
    t.eq("FINAL-BODY", entry.result_text)
    t.matches("FINAL%-BODY", got.text or "")
    t.eq("sess_parent", got.fallback)
    t.not_nil(got.meta and got.meta.sub_agent, "回传应带子 Agent 标记")
    t.eq("completed", got.meta.sub_agent.status)

    runtime.spawn, runtime.run, runtime.get, session_store.create = orig_spawn, orig_run, orig_get, orig_create
    manager.reset()
  end)

  it("cancel / send 委托到运行时", function(t)
    local manager = require("NeoAI.core.agent.sub_agent")
    local runtime = require("NeoAI.core.agent.runtime")
    manager.reset()

    local aborted, sent = false, nil
    local orig_get, orig_abort = runtime.get, runtime.abort
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.get = function(id) return { id = id } end
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.abort = function() aborted = true end

    manager._inject_for_test("sub_a", { agent_id = "childA", parent_agent_id = "p1" })
    manager.set_dispatch(function(_, content) sent = content end)

    t.true_(manager.cancel("sub_a"))
    t.true_(aborted)
    t.eq("cancelled", manager.get("sub_a").status)

    sent = nil
    t.true_(manager.send("sub_a", "继续"))
    t.eq("继续", sent)

    runtime.get, runtime.abort = orig_get, orig_abort
    manager.reset()
  end)

  it("list_for / count_for", function(t)
    local manager = require("NeoAI.core.agent.sub_agent")
    manager.reset()
    manager._inject_for_test("s1", { parent_agent_id = "p1", name = "甲" })
    manager._inject_for_test("s2", { parent_agent_id = "p1", name = "乙" })
    manager._inject_for_test("s3", { parent_agent_id = "p2", name = "丙" })
    t.eq(2, #manager.list_for("p1"))
    local running, total = manager.count_for("p1")
    t.eq(2, running)
    t.eq(2, total)
    manager.reset()
  end)

  it("重开子 Agent 会话：识别标记 + 只给非 Agent 类工具", function(t)
    local store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    store.reset()
    chat.reset()
    store.init()
    local sess = store.create({
      name = "subX",
      metadata = { tags = { "sub_agent" }, name = "subX" },
      messages = {
        { role = "user", content = "任务" },
        { role = "assistant", content = "结果" },
      },
    })
    local agent = chat.load_session(sess.id)
    t.true_(agent._sub_agent_session, "应识别为子 Agent 会话")
    t.nil_(agent.tools.create_sub_agent, "不得含 Agent 类工具")
    t.nil_(agent.tools.enter_plan_mode, "不得含 Agent 类工具")
    t.not_nil(agent.tools.read_file, "应含非 Agent 类工具")
    t.eq(2, #agent.messages, "只载入本会话消息（零继承）")
    chat.reset()
    store.reset()
  end)

  it("子 Agent 会话不在会话树中显示（避免与用户分支混排）", function(t)
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    tree.reset()
    store.reset()
    require("NeoAI.kernel.config_store").load({})
    store.init()
    local root = store.create({ messages = {
      { role = "user", content = "主问题" },
      { role = "assistant", content = "主回答" },
    } })
    local sub = store.create({
      parent_id = root.id,
      name = "探测器",
      metadata = { tags = { "sub_agent" }, name = "探测器" },
      messages = {
        { role = "user", content = "扫描仓库" },
        { role = "assistant", content = "完成扫描" },
      },
    })
    local opened = tree.open()
    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    t.not_nil(store.get(sub.id), "子 Agent 会话本身仍保存在会话存储中")
    t.false_(joined:find("探测器", 1, true) ~= nil, "子 Agent 会话名不应出现在会话树中")
    t.false_(joined:find("扫描仓库", 1, true) ~= nil, "子 Agent 会话内容不应出现在会话树中")
    t.matches("主问题", joined)
    -- 主会话节点仍按用户分支渲染，且不显示出额外子节点
    for _, l in ipairs(lines) do
      if l:find("主问题", 1, true) then
        t.true_(l:find("用户", 1, true) ~= nil, "主会话节点应标为用户")
        t.false_(l:find("子 Agent", 1, true) ~= nil, "主会话节点不应混入子 Agent 标记")
      end
    end
    tree.reset()
    store.reset()
  end)

  it("子 Agent 结果消息渲染为折叠块而非用户消息", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local fold = require("NeoAI.ui.components.fold")
    local buf = vim.api.nvim_create_buf(false, true)
    local msgs = {
      { role = "assistant", content = "正在派发" },
      {
        role = "user",
        content = '【子 Agent "探测器" 已完成】\n扫描结果：OK',
        sub_agent = { id = "sx", name = "探测器", status = "completed", task = "扫描仓库" },
      },
      { role = "assistant", content = "收到结果" },
    }
    ml.render_chat(buf, msgs, nil)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("子 Agent: 探测器", text)
    t.matches("任务: 扫描仓库", text)
    t.false_(text:find("👤 用户", 1, true) ~= nil, "不应渲染为用户消息")
    t.false_(text:find("【子 Agent", 1, true) ~= nil, "投递包装行应被剥离")

    local kind, status, name = fold.detect("✅ 子 Agent: 探测器")
    t.eq("sub_agent", kind)
    t.eq("success", status)
    t.eq("探测器", name)
    t.matches("子 Agent 探测器", fold.label("✅ 子 Agent: 探测器", 3, true))
    vim.api.nvim_buf_delete(buf, { force = true })
    ml.reset()
  end)

  it("旧数据（无标记）子 Agent 结果按折叠块渲染", function(t)
    local ml = require("NeoAI.ui.components.message_list")
    local buf = vim.api.nvim_create_buf(false, true)
    ml.render_chat(buf, {
      { role = "user", content = '【子 Agent "B" 已完成】\n旧正文' },
    }, nil)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("子 Agent: B", text)
    t.matches("旧正文", text)
    t.false_(text:find("👤 用户", 1, true) ~= nil, "旧数据也不应渲染为用户消息")
    vim.api.nvim_buf_delete(buf, { force = true })
    ml.reset()
  end)

  it("主会话中的子 Agent 结果不作为用户轮次显示", function(t)
    local store = require("NeoAI.core.session.session_store")
    local tree = require("NeoAI.ui.window.tree_view")
    tree.reset()
    store.reset()
    require("NeoAI.kernel.config_store").load({})
    store.init()
    store.create({ messages = {
      { role = "user", content = "主问题" },
      { role = "assistant", content = "派发子任务" },
      { role = "user", content = '【子 Agent "A" 已完成】\n结果', sub_agent = { id = "s", name = "A", status = "completed" } },
      { role = "assistant", content = "收到结果" },
    } })
    local opened = tree.open()
    local joined = table.concat(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false), "\n")
    t.matches("主问题", joined)
    t.false_(joined:find('子 Agent "A"', 1, true) ~= nil, "子 Agent 结果不应作为用户轮显示")
    tree.reset()
    store.reset()
  end)

  it("status 子 Agent 段：窄窗口折叠为「N个子agent正在运行」", function(t)
    local manager = require("NeoAI.core.agent.sub_agent")
    local status = require("NeoAI.services.status")
    local services = require("NeoAI.kernel.services")
    manager.reset()
    manager._inject_for_test("s1", { parent_agent_id = "agentX", name = "甲" })
    manager._inject_for_test("s2", { parent_agent_id = "agentX", name = "乙" })

    -- stub 当前 agent
    local chat_service = services.use("services.chat_service")
    t.not_nil(chat_service, "chat_service 应可用")
    local orig = chat_service.get_current_agent
    ---@diagnostic disable-next-line: duplicate-set-field
    chat_service.get_current_agent = function()
      return { id = "agentX", model = "m", state = "idle", config = { provider = "deepseek" } }
    end

    local wide = status.sub_agents_segment({ width = 200, prefix_parts = { "mode", "model", "state" } })
    t.matches("甲", wide)
    t.matches("乙", wide)

    local narrow = status.sub_agents_segment({ width = 10, prefix_parts = { "mode", "model", "state" } })
    t.matches("2个子agent正在运行", narrow)

    chat_service.get_current_agent = orig
    manager.reset()
  end)
end)
