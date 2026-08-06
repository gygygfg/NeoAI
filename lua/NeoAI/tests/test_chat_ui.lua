local tests = require("NeoAI.tests")

tests.suite("chat_ui", function(_, it)
  it("推理内容按缩进自动折叠", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    message_list.reset()
    chat_view.reset()
    chat_service.reset()

    -- 模拟用户全局关闭折叠
    local prev_foldenable = vim.o.foldenable
    vim.o.foldenable = false

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = { { role = "assistant", content = "answer", reasoning = "step 1\nstep 2" } }
    chat_view.refresh()

    t.true_(vim.wo[opened.win_id].foldenable, "chat 窗口应强制开启 foldenable")
    t.eq("indent", vim.wo[opened.win_id].foldmethod, "chat 窗口应使用缩进折叠")
    t.eq("v:lua.require'NeoAI.ui.window.chat_view'.foldtext()", vim.wo[opened.win_id].foldtext,
      "chat 窗口应使用自定义折叠文本")
    t.eq(2, vim.bo[opened.buf].shiftwidth, "chat 窗口应以两个空格作为折叠缩进")

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local has_marker, indent_found = false, false
    for _, l in ipairs(lines) do
      if l:match("{{{") or l:match("}}}") then has_marker = true end
      if l == "  step 1" then indent_found = true end
    end
    t.false_(has_marker, "不应在聊天内容中显示折叠标记")
    t.true_(indent_found, "推理内容应缩进 2 格")

    -- 折叠可创建并可开关
    vim.api.nvim_set_current_win(opened.win_id)
    vim.api.nvim_win_set_cursor(opened.win_id, { 2, 0 })
    t.eq(2, vim.fn.foldclosed(2), "推理块应默认折叠")
    t.eq("  🤔 思考过程 2 行", vim.fn.foldtextresult(2), "推理块应显示单行摘要")
    vim.cmd("normal! zo")
    t.eq(-1, vim.fn.foldclosed(2), "zo 应展开推理块")
    vim.cmd("normal! zc")
    t.eq(2, vim.fn.foldclosed(2), "zc 应重新折叠推理块")

    -- 重渲染会替换整个 buffer，推理块仍应自动收起。
    vim.cmd("normal! zo")
    t.eq(-1, vim.fn.foldclosed(2), "推理块应已展开")
    chat_view.refresh()
    t.eq(2, vim.fn.foldclosed(2), "重渲染后推理块应自动折叠")

    vim.o.foldenable = prev_foldenable
    chat_view.reset()
    chat_service.reset()
  end)

  it("流式推理显示悬浮窗并在完成或正文开始时关闭", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local reasoning_panel = require("NeoAI.ui.components.reasoning_panel")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()
    reasoning_panel.reset()

    chat_view.open()
    local agent = chat_service.get_current_agent()
    event_bus.emit(events.REASONING_CHUNK, { agent_id = agent.id, chunk = "first ", reasoning = "first " })
    event_bus.emit(events.REASONING_CHUNK, { agent_id = agent.id, chunk = "step", reasoning = "first step" })
    t.true_(reasoning_panel.is_open(), "收到推理分片时应打开悬浮窗")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "neoai_reasoning" then
        t.eq("first step", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "推理分片应连续追加")
        break
      end
    end

    event_bus.emit(events.REASONING_COMPLETED, { agent_id = agent.id })
    t.false_(reasoning_panel.is_open(), "推理完成时应关闭悬浮窗")

    event_bus.emit(events.REASONING_CHUNK, { agent_id = agent.id, chunk = "second step", reasoning = "second step" })
    t.true_(reasoning_panel.is_open(), "后续推理分片仍应打开悬浮窗")

    event_bus.emit(events.MESSAGE_UPDATED, {
      agent_id = agent.id,
      message = { role = "assistant", content = "answer" },
    })
    t.false_(reasoning_panel.is_open(), "正文开始输出时应关闭悬浮窗")

    chat_view.reset()
    chat_service.reset()
  end)

  it("单行推理也显示折叠文本", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = { { role = "assistant", content = "answer", reasoning = "brief thought" } }
    chat_view.refresh()

    vim.api.nvim_set_current_win(opened.win_id)
    vim.api.nvim_win_set_cursor(opened.win_id, { 2, 0 })
    t.eq(2, vim.fn.foldclosed(2), "单行推理应自动折叠")
    t.eq("  🤔 思考过程 2 行", vim.fn.foldtextresult(2), "单行推理应显示折叠文本")

    chat_view.reset()
    chat_service.reset()
  end)

  it("已打开聊天窗口时从 Tree 切换会话", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local session_store = require("NeoAI.core.session.session_store")
    chat_view.reset()
    chat_service.reset()
    session_store.init()

    local first = session_store.create({
      messages = { { role = "user", content = "first question" }, { role = "assistant", content = "first answer" } },
    })
    local second = session_store.create({
      messages = { { role = "user", content = "second question" }, { role = "assistant", content = "second answer" } },
    })

    local opened = chat_view.open({ session_id = first.id })
    chat_view.open({ session_id = second.id })

    t.eq(second.id, chat_service.get_current_session_id(), "应加载 Tree 选中的会话")
    local rendered = table.concat(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false), "\n")
    t.true_(rendered:find("second question", 1, true) ~= nil, "应显示完整的新会话消息")
    t.true_(rendered:find("second answer", 1, true) ~= nil, "应显示新会话的回复")
    t.true_(rendered:find("first question", 1, true) == nil, "不应保留旧会话内容")

    chat_view.reset()
    chat_service.reset()
  end)

  it("思考悬浮窗刷新后滚动到底部", function(t)
    local reasoning_panel = require("NeoAI.ui.components.reasoning_panel")
    reasoning_panel.reset()

    reasoning_panel.show("1\n2\n3\n4\n5\n6")
    local found = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "neoai_reasoning" then
        found = true
        t.eq(6, vim.api.nvim_win_get_cursor(win)[1], "悬浮窗应定位到最后一行")
        break
      end
    end
    t.true_(found, "应创建思考悬浮窗")

    reasoning_panel.reset()
  end)
end)
