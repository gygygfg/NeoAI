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
    t.eq("expr", vim.wo[opened.win_id].foldmethod, "chat 窗口应使用 expr 折叠（每块独立，无需分隔行）")
    t.eq("v:lua.NeoAIFoldExpr()", vim.wo[opened.win_id].foldexpr,
      "chat 窗口应使用 components.fold 的 foldexpr")
    t.eq("v:lua.require'NeoAI.ui.components.fold'.foldtext()", vim.wo[opened.win_id].foldtext,
      "chat 窗口应使用 components.fold 的折叠文本")
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

  it("打开已加载会话时主界面光标先定位到消息底部再聚焦输入框", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local fs = require("NeoAI.utils.fs")
    local session_store = require("NeoAI.core.session.session_store")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    config_store.load({ session = { save_path = "/tmp/neoai_chat_cursor_test", file = "sessions.jsonl" } })
    chat_view.reset()
    chat_service.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_chat_cursor_test/sessions.jsonl")
    session_store.init()

    local session = session_store.create({
      messages = {
        { role = "user", content = "问题" },
        { role = "assistant", content = "回答" },
      },
    })
    local opened = chat_view.open({ session_id = session.id })

    -- 打开后焦点虽在输入框，主界面光标应已定位到消息最底部
    local line_count = vim.api.nvim_buf_line_count(opened.buf)
    local cur = vim.api.nvim_win_get_cursor(opened.win_id)
    t.eq(line_count, cur[1], "主界面光标应位于最后一行")

    chat_view.reset()
    chat_service.reset()
    session_store.reset()
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
    chat_view.flush()
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
    chat_view.flush()
    t.true_(reasoning_panel.is_open(), "后续推理分片仍应打开悬浮窗")

    event_bus.emit(events.MESSAGE_UPDATED, {
      agent_id = agent.id,
      message = { role = "assistant", content = "answer" },
    })
    chat_view.flush()
    t.false_(reasoning_panel.is_open(), "正文开始输出时应关闭悬浮窗")

    chat_view.reset()
    chat_service.reset()
  end)

  it("接收工具参数时打开悬浮窗并在参数流结束关闭", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local tool_args_panel = require("NeoAI.ui.components.tool_args_panel")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()
    tool_args_panel.reset()

    chat_view.open()
    local agent = chat_service.get_current_agent()
    local mk = function(name, args)
      local c = { index = 0, type = "function" }
      c["function"] = { name = name, arguments = args }
      return c
    end
    event_bus.emit(events.TOOL_ARG_CHUNK, { agent_id = agent.id, tool_calls = {
      mk("bash", '{"cmd":'),
    } })
    event_bus.emit(events.TOOL_ARG_CHUNK, { agent_id = agent.id, tool_calls = {
      mk("bash", '{"cmd":"ls"}'),
    } })
    chat_view.flush()
    t.true_(tool_args_panel.is_open(), "收到工具参数分片时应打开悬浮窗")
    t.true_(tool_args_panel.get_content():find("bash", 1, true) ~= nil, "悬浮窗应展示工具名")
    t.true_(tool_args_panel.get_content():find('"cmd"', 1, true) ~= nil, "悬浮窗应展示接收到的参数")

    event_bus.emit(events.TOOL_ARG_COMPLETED, { agent_id = agent.id })
    t.false_(tool_args_panel.is_open(), "工具参数流结束时应关闭悬浮窗")

    event_bus.emit(events.TOOL_ARG_CHUNK, { agent_id = agent.id, tool_calls = {
      mk("bash", '{"cmd":"ls"}'),
    } })
    chat_view.flush()
    t.true_(tool_args_panel.is_open(), "后续工具参数分片仍应打开悬浮窗")

    event_bus.emit(events.GENERATION_COMPLETED, { agent_id = agent.id })
    t.false_(tool_args_panel.is_open(), "生成结束时应关闭悬浮窗")

    chat_view.reset()
    chat_service.reset()
    tool_args_panel.reset()
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
    t.eq("  🤔 思考过程 1 行", vim.fn.foldtextresult(2), "单行推理应显示折叠文本（无占位行）")

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

  it("发送后焦点切到主窗口（普通模式），Agent 结束后回到输入框（插入模式）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local input_box = require("NeoAI.ui.components.input_box")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local async = require("NeoAI.utils.async")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local input_win = input_box.get_win()
    t.true_(input_win ~= nil and vim.api.nvim_win_is_valid(input_win), "应创建输入窗口")

    -- 打桩 send_message，避免真实网络请求
    local orig_send = chat_service.send_message
    chat_service.send_message = function() return async.resolve({}) end

    -- headless 下 feedkeys 的 typeahead 不会在测试期间被处理，无法直接断言插入模式；
    -- 用 spy 验证 Agent 结束后确实调用了 input_box.focus（即进入插入模式的标准入口）
    local focus_calls = 0
    local orig_focus = input_box.focus
    input_box.focus = function()
      focus_calls = focus_calls + 1
      return orig_focus()
    end

    -- 触发提交（等价于在输入框按回车/发送）
    local buf = input_box.get_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
    local cb = input_box.get_enter_callback()
    cb()

    t.eq(opened.win_id, vim.api.nvim_get_current_win(), "发送后焦点应切到主窗口")
    t.eq("n", vim.api.nvim_get_mode().mode, "发送后应处于普通模式")
    t.eq(0, focus_calls, "发送过程不应调用 input_box.focus")

    -- Agent 生成结束：应调用 input_box.focus 并把光标移回输入框
    local agent = chat_service.get_current_agent()
    event_bus.emit(events.GENERATION_COMPLETED, { agent_id = agent.id })
    t.eq(1, focus_calls, "Agent 结束后应调用 input_box.focus 以进入插入模式")
    t.eq(input_win, vim.api.nvim_get_current_win(), "Agent 结束后焦点应回到输入框")

    input_box.focus = orig_focus
    chat_service.send_message = orig_send
    chat_view.reset()
    chat_service.reset()
  end)

  it("子 Agent 完成不触发主界面光标回输入框（仅主 Agent 生效）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local input_box = require("NeoAI.ui.components.input_box")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    t.true_(opened.win_id and vim.api.nvim_win_is_valid(opened.win_id), "应创建聊天窗口")

    local focus_calls = 0
    local orig_focus = input_box.focus
    input_box.focus = function()
      focus_calls = focus_calls + 1
      return orig_focus()
    end

    -- 子 Agent 完成（agent_id 与主 Agent 不同）：不应把光标拽回输入框
    event_bus.emit(events.GENERATION_COMPLETED, { agent_id = "sub_agent_xyz" })
    event_bus.emit(events.GENERATION_ERROR, { agent_id = "sub_agent_xyz", error = "boom" })
    event_bus.emit(events.AGENT_ABORTED, { agent_id = "sub_agent_xyz" })
    t.eq(0, focus_calls, "子 Agent 完成/失败/取消不应调用 input_box.focus")

    -- 主 Agent 完成：才应把光标移回输入框
    event_bus.emit(events.GENERATION_COMPLETED, { agent_id = agent.id })
    t.eq(1, focus_calls, "仅主 Agent 完成应调用 input_box.focus")

    input_box.focus = orig_focus
    chat_view.reset()
    chat_service.reset()
  end)

  it("聊天窗口失去焦点时收起输入框，返回时恢复且内容保留", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local input_box = require("NeoAI.ui.components.input_box")
    chat_view.reset()
    chat_service.reset()

    -- 先建一个普通代码窗口（非 neoai buffer），模拟用户编辑代码的窗口
    vim.cmd("vsplit")
    local code_win = vim.api.nvim_get_current_win()
    local code_buf = vim.api.nvim_get_current_buf()
    vim.bo[code_buf].filetype = "lua"

    local opened = chat_view.open()
    local input_win = input_box.get_win()
    t.true_(input_win ~= nil and vim.api.nvim_win_is_valid(input_win), "打开后应创建输入窗口")

    -- 在输入框写点内容，验证收起-恢复后草稿内容保留
    vim.api.nvim_buf_set_lines(input_box.get_buf(), 0, -1, false, { "draft text" })

    -- 焦点切到代码窗口（聊天界面进入后台）→ 收起
    vim.api.nvim_set_current_win(code_win)
    t.eq(code_win, vim.api.nvim_get_current_win(), "焦点应切到代码窗口")
    local collapsed_win = input_box.get_win()
    t.true_(collapsed_win == nil or not vim.api.nvim_win_is_valid(collapsed_win), "离开聊天后输入窗口应收起")

    -- 焦点切回聊天主窗口 → 恢复
    vim.api.nvim_set_current_win(opened.win_id)
    local restored_win = input_box.get_win()
    t.true_(restored_win ~= nil and vim.api.nvim_win_is_valid(restored_win), "回到聊天后应重建输入窗口")
    local input_buf = input_box.get_buf()
    local n = 0
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == input_buf then n = n + 1 end
    end
    t.eq(1, n, "恢复后应只有一个输入框")
    t.eq("draft text", vim.api.nvim_buf_get_lines(input_box.get_buf(), 0, -1, false)[1], "输入内容应保留")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    chat_view.reset()
    chat_service.reset()
  end)

  it("关闭其它窗口触发 WinEnter 恢复输入框时不报 E242", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local input_box = require("NeoAI.ui.components.input_box")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local main = opened.win_id
    t.true_(vim.api.nvim_win_is_valid(input_box.get_win()), "打开后应有输入窗口")

    -- 在聊天标签页内从主窗口分出一个非聊天窗口，聚焦它使输入框收起
    vim.api.nvim_set_current_win(main)
    vim.cmd("vsplit")
    local side = vim.api.nvim_get_current_win()
    local side_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[side_buf].filetype = "lua"
    vim.api.nvim_win_set_buf(side, side_buf)
    vim.api.nvim_set_current_win(main)
    vim.api.nvim_set_current_win(side)
    local cw = input_box.get_win()
    t.true_(cw == nil or not vim.api.nvim_win_is_valid(cw), "离开聊天后输入框应已收起")

    -- 关闭 side 窗口：关闭过程中会对聊天主窗口触发 WinEnter，此时同步 :split
    -- 会报 E242 "Can't split a window while closing another"，不应抛出。
    local ok = pcall(vim.api.nvim_win_close, side, true)
    t.true_(ok, "关闭窗口不应因恢复输入框而报错")
    t.true_(vim.wait(300, function()
      local w = input_box.get_win()
      return w ~= nil and vim.api.nvim_win_is_valid(w)
    end), "随后应延迟恢复输入窗口")

    -- 不得重复创建：恰好一个窗口显示输入 buffer
    local input_buf = input_box.get_buf()
    local n = 0
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == input_buf then n = n + 1 end
    end
    t.eq(1, n, "恢复后应只有一个输入框")

    pcall(vim.api.nvim_buf_delete, side_buf, { force = true })
    chat_view.reset()
    chat_service.reset()
  end)

  it("输入框多行缩进内容不被误折叠为思考过程", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local input_box = require("NeoAI.ui.components.input_box")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local input_win = input_box.get_win()
    t.true_(input_win ~= nil and vim.api.nvim_win_is_valid(input_win), "应创建输入窗口")

    -- 输入窗口由 :belowright split 从聊天主窗口分裂而来，会继承其 expr 折叠。
    -- 输入框内缩进的多行内容不应被误判为推理/工具折叠块（「🤔 思考过程」）。
    t.false_(vim.wo[input_win].foldenable, "输入窗口应禁用折叠")

    vim.api.nvim_buf_set_lines(input_box.get_buf(), 0, -1, false, {
      "第一行",
      "  缩进的第二行",
      "第四行",
    })

    -- 光标留在输入窗口，折叠重算后各行均应顶格显示（无折叠）
    vim.api.nvim_set_current_win(input_win)
    local total = vim.api.nvim_buf_line_count(input_box.get_buf())
    for ln = 1, total do
      t.eq(0, vim.fn.foldlevel(ln), "输入框第 " .. ln .. " 行不应被折叠")
      t.eq(-1, vim.fn.foldclosed(ln), "输入框第 " .. ln .. " 行不应处于折叠块内")
      t.eq("", vim.fn.foldtextresult(ln), "输入框第 " .. ln .. " 行不应显示思考过程折叠文本")
    end
    -- 缩进内容本身应保留（不被折叠隐藏）
    local lines = vim.api.nvim_buf_get_lines(input_box.get_buf(), 0, -1, false)
    t.eq("  缩进的第二行", lines[2], "输入框缩进内容应原样保留")

    chat_view.reset()
    chat_service.reset()
  end)

  it("聊天主窗口被 :bnext 切到别的 buffer 时收起输入框，切回聊天 buffer 时恢复", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local input_box = require("NeoAI.ui.components.input_box")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    t.true_(vim.api.nvim_win_is_valid(input_box.get_win()), "打开后应创建输入窗口")

    -- 焦点在主聊天窗口，模拟用户在聊天窗口里 :bnext 切到别的文件
    vim.api.nvim_set_current_win(opened.win_id)
    local fb = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(fb, 0, -1, false, { "FILE" })
    vim.api.nvim_win_set_buf(opened.win_id, fb)
    local collapsed_win = input_box.get_win()
    t.true_(collapsed_win == nil or not vim.api.nvim_win_is_valid(collapsed_win), "主窗口切走应收起输入框")

    -- :bprev 切回聊天 buffer → 恢复
    vim.api.nvim_win_set_buf(opened.win_id, opened.buf)
    t.true_(input_box.get_win() ~= nil and vim.api.nvim_win_is_valid(input_box.get_win()), "切回聊天 buffer 应恢复输入窗口")

    pcall(vim.api.nvim_buf_delete, fb, { force = true })
    chat_view.reset()
    chat_service.reset()
  end)

  it("多行工具结果可渲染且不中断聊天窗口", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    message_list.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 模拟工具返回多行结果（如 shell 输出），此前会导致 nvim_buf_set_lines 抛错、界面卡住
    agent.messages = {
      { role = "user", content = "跑一下命令" },
      { role = "assistant", content = "", tool_calls = { { ["function"] = { name = "run_command", arguments = "{}" } } } },
      { role = "tool", tool_call_id = "call_1", tool_name = "run_command", content = "line1\nline2\nline3" },
      { role = "assistant", content = "命令执行完成" },
    }

    -- render 不应抛错
    local ok = pcall(chat_view.refresh)
    t.true_(ok, "多行工具结果不应导致渲染异常")

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local found_line1, found_line2, found_line3 = false, false, false
    for _, l in ipairs(lines) do
      if l == "  line1" then found_line1 = true end
      if l == "  line2" then found_line2 = true end
      if l == "  line3" then found_line3 = true end
      t.false_(l:find("\n") ~= nil, "buffer 行内不应包含换行符")
      t.false_(l:match("^```") ~= nil, "工具结果不应再渲染字面 ``` 围栏")
    end
    t.true_(found_line1 and found_line2 and found_line3, "工具结果应缩进逐行渲染")

    chat_view.reset()
    chat_service.reset()
  end)

  it("布尔/标量工具结果可渲染且不再卡在 ⏳", function(t)
    local message_list = require("NeoAI.ui.components.message_list")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    message_list.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- is_named_node 返回 tostring(node:named()) = "true"/"false"：此前 _tool_result_failed
    -- 对布尔 JSON 直接 index decoded.error 抛错，render 中断，工具块永远停在 ⏳
    agent.messages = {
      { role = "user", content = "检查一下" },
      { role = "assistant", content = "", tool_calls = { { id = "call_1", ["function"] = { name = "is_named_node", arguments = "{}" } } } },
      { role = "tool", tool_call_id = "call_1", tool_name = "is_named_node", content = "true", duration_ms = 250 },
    }

    local ok = pcall(chat_view.refresh)
    t.true_(ok, "布尔工具结果不应导致渲染异常")

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local found_done = false
    for _, l in ipairs(lines) do
      if l:find("工具: is_named_node", 1, true) then
        found_done = true
        t.matches("✅", l, "布尔结果应渲染为成功状态")
        t.matches("250ms", l, "应显示总耗时")
      end
    end
    t.true_(found_done, "工具块应渲染完成状态而非停留在 ⏳")

    chat_view.reset()
    chat_service.reset()
  end)

  it("工具调用与工具结果按缩进折叠（同推理）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "user", content = "查一下" },
      { role = "assistant", content = "", tool_calls = {
        { ["function"] = { name = "lsp_service_info", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "call_1", tool_name = "lsp_service_info", content = "1  root=-  name=GitHub Copilot" },
      { role = "assistant", content = "查完了" },
    }
    chat_view.refresh()

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local tool_call_indented, tool_content_indented = false, false
    local tool_heading = false
    local tool_sep_right_after = false
    for i, l in ipairs(lines) do
      if l == "  ✅ 工具: lsp_service_info" then tool_call_indented = true end
      if l == "  1  root=-  name=GitHub Copilot" then tool_content_indented = true end
      if l == "### 🔧 工具" then tool_heading = true end
      -- 工具结果块后应紧跟空行与下一消息头，不再有角色头/分隔线噪音
      if l == "  1  root=-  name=GitHub Copilot" and lines[i + 1] == "────────────────────" then
        tool_sep_right_after = true
      end
    end
    t.true_(tool_call_indented, "工具结果首行应缩进 2 格（可折叠）")
    t.true_(tool_content_indented, "工具结果内容应缩进 2 格（可折叠）")
    t.false_(tool_heading, "工具结果不应渲染 ### 🔧 工具 角色头")
    t.false_(tool_sep_right_after, "工具结果块后不应紧跟分隔线")

    -- 工具结果块：无角色头，折叠从首个缩进行开始，默认收起
    vim.api.nvim_set_current_win(opened.win_id)
    local tool_row_line = 0
    for i, l in ipairs(lines) do
      if l == "  ✅ 工具: lsp_service_info" then tool_row_line = i break end
    end
    t.true_(tool_row_line > 0, "应找到工具结果折叠起点")
    local folded = vim.fn.foldclosed(tool_row_line)
    t.true_(folded > 0, "工具结果应默认折叠")
    local summary = vim.fn.foldtextresult(tool_row_line)
    t.true_(summary:match("🔧 lsp_service_info ✅") ~= nil,
      "工具折叠占位应为 🔧 工具名 ✅，实际 " .. summary)

    chat_view.reset()
    chat_service.reset()
  end)

  it("并发工具调用：每个工具一个折叠块（调用+结果），轮内无分割线", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 一轮 turn：用户消息 → 推理 + 2 个工具调用 → 2 个工具结果 → 最终正文
    agent.messages = {
      { role = "user", content = "查一下" },
      { role = "assistant", content = "", reasoning = "先想想", tool_calls = {
        { id = "c1", ["function"] = { name = "git_status", arguments = "{}" } },
        { id = "c2", ["function"] = { name = "run_command", arguments = "{\"cmd\":\"ls\"}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "git_status", content = "M f1" },
      { role = "tool", tool_call_id = "c2", tool_name = "run_command", content = "out1" },
      { role = "assistant", content = "查完了" },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)

    -- 工具调用/结果行都应缩进渲染
    local call1, call2 = false, false
    for _, l in ipairs(lines) do
      if l:find("✅ 工具: git_status", 1, true) then call1 = true end
      if l:find("✅ 工具: run_command", 1, true) then call2 = true end
    end
    t.true_(call1 and call2, "两个工具结果首行都应渲染为缩进行")

    -- 每个工具 = 一个折叠块（调用+结果）：2 个工具 → 2 个独立折叠
    local fold_starts = {}
    for i, l in ipairs(lines) do
      if l:find("✅ 工具: git_status", 1, true)
        or l:find("✅ 工具: run_command", 1, true) then
        local fc = vim.fn.foldclosed(i)
        t.true_(fc > 0, "工具首行应处于折叠内，实际 foldclosed=" .. tostring(fc))
        fold_starts[#fold_starts + 1] = fc
      end
    end
    t.eq(2, #fold_starts, "两个工具应各自独立成折叠（每个含调用+结果）")
    local unique = {}
    for _, s in ipairs(fold_starts) do unique[s] = true end
    local n = 0
    for _ in pairs(unique) do n = n + 1 end
    t.eq(2, n, "两个工具折叠不应被合并进同一个折叠")

    -- 每个折叠占位文本带成功状态与工具名；一个折叠同时包含调用与结果
    local joined = ""
    for _, s in ipairs(fold_starts) do
      joined = joined .. "|" .. vim.fn.foldtextresult(s)
    end
    t.true_(joined:find("🔧 git_status ✅", 1, true) ~= nil, "git_status 应有独立折叠行，实际 " .. joined)
    t.true_(joined:find("🔧 run_command ✅", 1, true) ~= nil, "run_command 应有独立折叠行，实际 " .. joined)

    -- 两个折叠之间不应有分隔空行（折叠块相邻，无 ⠀ / 空行）
    local blank_between = false
    for i, l in ipairs(lines) do
      -- git_status 结果块的最后一行（M f1）后应紧跟 run_command 工具首行
      if l == "  M f1" and lines[i + 1] == "  ✅ 工具: run_command" then
        blank_between = true
      end
    end
    t.true_(blank_between, "两个工具折叠之间应直接相邻（无分隔空行）")

    -- 一轮 turn 内（用户消息与最终回复之间）不应有分割线：
    -- 整轮只应有 2 条分割线（用户消息后 + 最终答复后），折叠文本与正文之间没有
    local seps = 0
    for _, l in ipairs(lines) do
      if l == "────────────────────" then seps = seps + 1 end
    end
    t.eq(2, seps, "一轮内不应出现分割线，实际 " .. seps .. " 条")

    chat_view.reset()
    chat_service.reset()
  end)

  it("流式更新时仅在光标位于最后 5 行内才跟随滚动", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 预置足够长的内容，使 buffer 行数超过 5
    agent.messages = {
      { role = "user", content = "q1" },
      { role = "assistant", content = "第一行\n第二行\n第三行\n第四行\n第五行\n第六行" },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    local total_before = vim.api.nvim_buf_line_count(opened.buf)
    t.true_(total_before > 5, "前置条件：buffer 应超过 5 行，实际 " .. total_before)

    -- 光标放在第 2 行（远离最后 5 行）：流式添加内容时不应移动光标（不跟随）
    vim.api.nvim_win_set_cursor(opened.win_id, { 2, 0 })
    local last = agent.messages[#agent.messages]
    last.content = last.content .. "\n流式新内容"
    event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = last })
    chat_view.flush()

    local cur_after = vim.api.nvim_win_get_cursor(opened.win_id)
    t.eq(2, cur_after[1], "光标不在最后 5 行时流式更新不应移动光标")
    local total_after = vim.api.nvim_buf_line_count(opened.buf)
    t.true_(total_after > total_before, "流式内容应已写入 buffer")

    -- 光标贴近底部（最后 5 行内）：流式更新应跟随滚动到底部
    vim.api.nvim_win_set_cursor(opened.win_id, { total_after, 0 })
    last.content = last.content .. "\n更多内容"
    event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = last })
    chat_view.flush()

    local final_total = vim.api.nvim_buf_line_count(opened.buf)
    local final_cur = vim.api.nvim_win_get_cursor(opened.win_id)
    t.eq(final_total, final_cur[1], "光标在最后 5 行内时流式更新应跟随到底部")

    chat_view.reset()
    chat_service.reset()
  end)

  it("一次添加多行折叠文本后光标仍跟随到底部", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 工具结果为空：底部仅一个单行折叠块
    agent.messages = {
      { role = "user", content = "q1" },
      { role = "assistant", content = "前置正文", tool_calls = { { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } } } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = "" },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    -- 光标停在底部（正在跟随流式输出）
    local total = vim.api.nvim_buf_line_count(opened.buf)
    vim.api.nvim_win_set_cursor(opened.win_id, { total, 0 })

    -- 工具结果整块一次到达（一次添加多行折叠文本）：此前 zxzM 收起折叠会把光标
    -- 拽到折叠首行，导致重新判断"最后 5 行"时判定为不跟随，光标停在半途
    local result = agent.messages[3]
    local ls = {}
    for i = 1, 15 do ls[#ls + 1] = "结果行 " .. i end
    result.content = table.concat(ls, "\n")
    event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = result })
    chat_view.flush()

    local cur = vim.api.nvim_win_get_cursor(opened.win_id)
    local line_count = vim.api.nvim_buf_line_count(opened.buf)
    t.true_(line_count > total, "工具结果应已写入 buffer（多行折叠块）")
    t.eq(line_count, cur[1], "一次添加多行折叠文本后光标应仍跟随到底部，实际 " .. cur[1] .. "/" .. line_count)
    local fold_start = 0
    for i, l in ipairs(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)) do
      if l:find("✅ 工具: run_command", 1, true) then fold_start = i break end
    end
    t.true_(fold_start > 0, "应找到工具调用折叠起点")
    t.true_(vim.fn.foldclosed(fold_start) > 0, "工具结果块应处于折叠状态")

    chat_view.reset()
    chat_service.reset()
  end)

  it("同一 tick 内先调度 keep_view 渲染再到达内容更新时仍跟随到底部", function(t)
    -- 回归：_schedule_render 曾在"同一 tick 已有待渲染"时直接 return，导致后到的
    -- 内容更新被吞掉。当窗口重排（VimResized）/ 工具耗时 tick 的 keep_view 渲染先被
    -- 调度时，该次渲染会写入新折叠文本却跳过滚动，光标滞留在旧底部；下一次
    -- _cursor_within_follow_margin() 便判定"不在最后 5 行内"，跟随永久丢失。
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    local body = {}
    for i = 1, 100 do body[#body + 1] = "正文 " .. i end
    agent.messages = {
      { role = "user", content = "q1" },
      { role = "assistant", content = table.concat(body, "\n") },
      { role = "assistant", content = "", tool_calls = { { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } } } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = "" },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)
    local total = vim.api.nvim_buf_line_count(opened.buf)
    vim.api.nvim_win_set_cursor(opened.win_id, { total, 0 })

    local saved_cols = vim.o.columns
    -- 同一 tick 内：先触发窗口重排（keep_view 渲染），再让大块折叠文本到达。
    vim.o.columns = math.max(40, saved_cols - 20)
    vim.cmd("doautocmd VimResized")
    local res = {}
    for i = 1, 90 do res[#res + 1] = "结果行 " .. i end
    local last = agent.messages[#agent.messages]
    last.content = table.concat(res, "\n")
    event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = last })
    chat_view.flush()
    vim.o.columns = saved_cols

    local line_count = vim.api.nvim_buf_line_count(opened.buf)
    local cur = vim.api.nvim_win_get_cursor(opened.win_id)
    t.true_(line_count > total, "折叠文本应已写入 buffer")
    t.eq(line_count, cur[1],
      "同一 tick keep_view 与内容更新合并后光标应仍跟随到底部，实际 " .. cur[1] .. "/" .. line_count)

    chat_view.reset()
    chat_service.reset()
  end)

  it("工具调用消息的正文不因工具落地而消失", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 模型在调用工具前先输出一段正文：流式期间正文可见，工具调用落地后也不应消失
    agent.messages = {
      { role = "user", content = "第一轮问题" },
      { role = "assistant", content = "我来帮你查看一下", reasoning = "需要查资料", tool_calls = {
        { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = "输出" },
      { role = "assistant", content = "第一轮最终答复" },
      { role = "user", content = "第二轮问题" },
      { role = "assistant", content = "第二轮答案" },
    }
    chat_view.refresh()

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    t.true_(joined:find("我来帮你查看一下", 1, true) ~= nil, "工具调用消息的正文应保留，实际:\n" .. joined)
    t.true_(joined:find("第一轮最终答复", 1, true) ~= nil, "工具轮次后的最终答复应保留")
    t.true_(joined:find("第二轮问题", 1, true) ~= nil, "下一轮用户消息不应被消费丢弃")
    t.true_(joined:find("第二轮答案", 1, true) ~= nil, "下一轮回复应保留")

    chat_view.reset()
    chat_service.reset()
  end)

  it("工具结果缺失时不下一条消息被消费丢弃", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 两个并行工具调用，但只返回了 1 个结果：第二个调用位置处不是工具消息，
    -- 不应把后面的内容（下一轮用户消息）当作结果位置消费掉
    agent.messages = {
      { role = "user", content = "查一下" },
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "git_status", arguments = "{}" } },
        { id = "c2", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "git_status", content = "M f1" },
      { role = "user", content = "继续" },
      { role = "assistant", content = "好的继续" },
    }
    chat_view.refresh()

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    t.true_(joined:find("M f1", 1, true) ~= nil, "已有工具结果应渲染")
    t.true_(joined:find("继续", 1, true) ~= nil, "缺失结果时下一轮用户消息不应被消费丢弃，实际:\n" .. joined)
    t.true_(joined:find("好的继续", 1, true) ~= nil, "后续回复应保留")

    chat_view.reset()
    chat_service.reset()
  end)

  it("聊天 buffer 不挂载任何 LSP server（含 Copilot）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local buf = opened.buf
    -- 默认对话模式：聊天 buffer 应为 nofile（native LSP 自动启用会跳过；:w 报原生 E382）
    t.eq("nofile", vim.bo[buf].buftype, "对话模式下聊天 buffer 应为 nofile")
    t.true_(vim.b[buf].copilot_disabled, "应设置 copilot.vim 的 b:copilot_disabled")
    t.true_(vim.b[buf].copilot_disable, "应设置 copilot.lua 的 b:copilot_disable")
    local ok, clients = pcall(vim.lsp.get_clients, { bufnr = buf })
    t.true_(ok, "查询 LSP 客户端不应抛错")
    t.eq(0, #(ok and clients or {}), "聊天 buffer 不应挂载任何 LSP 客户端")

    -- 会话树窗口同样不应挂载 LSP
    local wm = require("NeoAI.ui.window.manager")
    local created = wm.create("tree", { mode = "tab", title = "NeoAI Sessions" })
    local tbuf = created.buf
    t.eq("nofile", vim.bo[tbuf].buftype, "树窗口 buffer 应为 nofile")
    t.true_(vim.b[tbuf].copilot_disabled, "树窗口 buffer 应设置 copilot 禁用标记")

    chat_view.reset()
    chat_service.reset()
  end)

  it("工具折叠文本按执行状态显示 ⏳（执行中）/ ✅（成功）/ ❌（失败）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()

    -- 执行中：工具调用已发出但结果未到达 → 折叠文本应显示 ⏳
    agent.messages = {
      { role = "user", content = "查一下" },
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)
    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local running_line = 0
    for i, l in ipairs(lines) do
      if l:find("⏳ 调用工具: run_command", 1, true) then running_line = i break end
    end
    t.true_(running_line > 0, "执行中应显示 ⏳ 调用工具 行，实际:\n" .. table.concat(lines, "\n"))
    t.true_(vim.fn.foldtextresult(running_line):match("🔧 run_command ⏳") ~= nil,
      "执行中折叠文本应为 🔧 run_command ⏳，实际 " .. vim.fn.foldtextresult(running_line))

    -- 成功：结果正常返回 → 折叠文本应显示 ✅
    agent.messages[#agent.messages + 1] = { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = "pwd" }
    chat_view.refresh()
    lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local success_line = 0
    for i, l in ipairs(lines) do
      if l:find("✅ 工具: run_command", 1, true) then success_line = i break end
    end
    t.true_(success_line > 0, "成功后应显示 ✅ 工具 行，实际:\n" .. table.concat(lines, "\n"))
    t.true_(vim.fn.foldtextresult(success_line):match("🔧 run_command ✅") ~= nil,
      "成功折叠文本应为 🔧 run_command ✅，实际 " .. vim.fn.foldtextresult(success_line))

    -- 失败：结果带 error 字段 → 折叠文本应显示 ❌
    agent.messages = {
      { role = "user", content = "查一下" },
      { role = "assistant", content = "", tool_calls = {
        { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = '{"error": "命令执行失败", "tool": "run_command"}' },
    }
    chat_view.refresh()
    lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local failure_line = 0
    for i, l in ipairs(lines) do
      if l:find("❌ 工具: run_command", 1, true) then failure_line = i break end
    end
    t.true_(failure_line > 0, "失败后应显示 ❌ 工具 行，实际:\n" .. table.concat(lines, "\n"))
    t.true_(vim.fn.foldtextresult(failure_line):match("🔧 run_command ❌") ~= nil,
      "失败折叠文本应为 🔧 run_command ❌，实际 " .. vim.fn.foldtextresult(failure_line))

    chat_view.reset()
    chat_service.reset()
  end)

  it("审批悬浮窗显示按键提示", function(t)
    local tool_approval = require("NeoAI.ui.components.tool_approval")
    tool_approval.reset()
    tool_approval.show({
      text = "工具: run_command\n描述: 执行命令\n参数: {}",
      tool_name = "run_command",
      on_confirm = function() end,
      on_cancel = function() end,
      on_confirm_all = function() end,
    })
    local found = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "neoai_approval" then
        found = true
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        t.true_(text:find("快捷键", 1, true) ~= nil, "应包含快捷键提示行")
        t.true_(text:find("回车", 1, true) ~= nil, "应提示回车允许一次")
        t.true_(text:find("允许所有", 1, true) ~= nil, "应提示允许所有")
        t.true_(text:find("Esc", 1, true) ~= nil, "应提示 Esc 取消")
        break
      end
    end
    t.true_(found, "应创建审批悬浮窗")
    tool_approval.reset()
  end)

  it("审批悬浮窗强制普通模式且快捷键可用（含插入模式）", function(t)
    local tool_approval = require("NeoAI.ui.components.tool_approval")
    tool_approval.reset()

    local confirmed_all = false
    local confirmed = false
    local cancelled = false

    -- 模拟用户在输入框打字（插入模式）时弹窗打开：此前会延续插入模式导致按键失效、审批卡住
    vim.cmd("startinsert")
    tool_approval.show({
      text = "工具: run_command",
      tool_name = "run_command",
      on_confirm = function() confirmed = true end,
      on_cancel = function() cancelled = true end,
      on_confirm_all = function() confirmed_all = true end,
    })

    local buf = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      if vim.bo[b].filetype == "neoai_approval" then buf = b break end
    end
    t.not_nil(buf, "应创建审批悬浮窗")
    t.eq("n", vim.api.nvim_get_mode().mode, "弹窗打开后应强制回到普通模式")
    t.false_(vim.bo[buf].modifiable, "弹窗应为只读，防止误编辑")

    -- 普通模式：A = 允许所有，应回调并关闭弹窗
    local map_a = vim.fn.maparg("A", "n", false, true)
    t.not_nil(map_a.callback, "普通模式应注册 A 映射")
    map_a.callback()
    t.true_(confirmed_all, "按 A 应触发允许所有")
    local still_open = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neoai_approval" then still_open = true break end
    end
    t.false_(still_open, "确认后弹窗应关闭")

    -- 插入模式也应绑定同一套快捷键（兜底，防止模式异常时再次卡住）
    tool_approval.show({
      text = "工具: run_command",
      tool_name = "run_command",
      on_confirm = function() confirmed = true end,
      on_cancel = function() cancelled = true end,
      on_confirm_all = function() confirmed_all = true end,
    })
    confirmed_all = false
    local map_a_i = vim.fn.maparg("A", "i", false, true)
    t.not_nil(map_a_i.callback, "插入模式也应注册 A 映射")
    map_a_i.callback()
    t.true_(confirmed_all, "插入模式下按 A 也应允许所有")

    -- Esc = 取消
    tool_approval.show({
      text = "工具: run_command",
      tool_name = "run_command",
      on_confirm = function() confirmed = true end,
      on_cancel = function() cancelled = true end,
      on_confirm_all = function() confirmed_all = true end,
    })
    cancelled = false
    local map_esc = vim.fn.maparg("<Esc>", "n", false, true)
    t.not_nil(map_esc.callback, "普通模式应注册 Esc 映射")
    map_esc.callback()
    t.true_(cancelled, "按 Esc 应取消")

    tool_approval.reset()
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

  it("焦点跳到别的 buffer 时流式文本与折叠文本仍写入聊天 buffer", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    -- 模拟用户焦点跳到别的 buffer：把聊天消息窗口切到另一个 buffer（等价于 :bnext 后停留在别的 buffer）
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { "FILE-MARKER" })
    vim.api.nvim_win_set_buf(opened.win_id, other)
    t.eq(other, vim.api.nvim_win_get_buf(opened.win_id), "前置条件：聊天窗口已显示别的 buffer")

    local agent = chat_service.get_current_agent()
    agent.messages = { { role = "assistant", content = "streamed answer", reasoning = "folded thought" } }
    event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = agent.messages[1] })
    chat_view.flush()

    -- 聊天 buffer 应收到流式文本与推理折叠块
    local chat_text = table.concat(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false), "\n")
    t.true_(chat_text:find("streamed answer", 1, true) ~= nil, "流式文本应写入聊天 buffer")
    t.true_(chat_text:find("  folded thought", 1, true) ~= nil, "推理折叠内容应写入聊天 buffer")
    -- 焦点所在的另一个 buffer 必须保持原样，不能被写入聊天内容
    local other_text = table.concat(vim.api.nvim_buf_get_lines(other, 0, -1, false), "\n")
    t.eq("FILE-MARKER", other_text, "焦点所在的别的 buffer 不应收到聊天内容")

    -- 重新打开聊天时，即使窗口曾被切走，也应把聊天 buffer 绑回聊天窗口
    chat_view.open()
    t.eq(opened.buf, vim.api.nvim_win_get_buf(opened.win_id), "重新打开聊天时应把聊天 buffer 绑回聊天窗口")

    chat_view.reset()
    chat_service.reset()
  end)

  it("工具执行中折叠文本实时刷新耗时（回归 timer_start 竞态）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "user", content = "跑命令" },
      { role = "assistant", content = "", tool_calls = {
        { id = "c_tick_1", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
    }
    chat_view.refresh()
    event_bus.emit(events.TOOL_EXECUTION_STARTED, {
      agent_id = agent.id, name = "run_command", tool_call_id = "c_tick_1",
    })
    chat_view.flush()

    local function tool_time()
      for _, l in ipairs(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)) do
        -- 执行中为 "⏳ 调用工具: run_command(...) · X"，完成后为 "✅ 工具: run_command · X"
        if l:find("run_command", 1, true) and l:find("工具", 1, true) then
          return l:match("· ([%d%.]+%a*)")
        end
      end
      return nil
    end

    local tm0 = tool_time()
    t.not_nil(tm0, "开始执行时应显示耗时（可为 0ms）")

    -- 等待超过一个 tick 间隔（1000ms）：此前 timer_start(..., {}) 传入空 Lua 表
    -- 被转成 vim 列表触发 E1206，tick 静默失败，耗时停留在 0ms 不实时更新。
    local done, refreshed = false, false
    vim.defer_fn(function() done = true end, 1300)
    vim.wait(4000, function()
      if done then
        local tm = tool_time()
        if tm and tm ~= tm0 and tm ~= "0ms" then
          refreshed = true
        end
        return true
      end
      return false
    end)
    t.true_(refreshed, "工具执行中折叠文本应实时刷新耗时（而非停留在 0ms）")

    event_bus.emit(events.TOOL_EXECUTION_COMPLETED, {
      agent_id = agent.id, name = "run_command", tool_call_id = "c_tick_1", duration_ms = 1500,
    })
    chat_view.flush()
    t.matches("1%.5s", tool_time() or "", "完成后折叠文本应显示总耗时")

    chat_view.reset()
    chat_service.reset()
  end)

  it("工具折叠文本含结构化调用参数与执行结果（成功/失败均展示）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "user", content = "跑命令" },
      { role = "assistant", content = "", tool_calls = {
        { id = "c_ok", ["function"] = { name = "run_command", arguments = '{"cmd": "ls", "dirs": "/tmp"}' } },
        { id = "c_err", ["function"] = { name = "read_file", arguments = '{"filepath": "/nope.txt"}' } },
      } },
      { role = "tool", tool_call_id = "c_ok", tool_name = "run_command", content = "file1\nfile2" },
      { role = "tool", tool_call_id = "c_err", tool_name = "read_file", content = '{"error": "文件不存在", "tool": "read_file"}' },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    local joined = table.concat(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false), "\n")
    -- 成功工具：含参数 + 结果标签，参数剔除 description 样板并结构化展示
    t.true_(joined:find("参数:", 1, true) ~= nil, "折叠内应有参数标签")
    t.true_(joined:find('"cmd": "ls"', 1, true) ~= nil, "成功工具应展示调用参数 cmd")
    t.true_(joined:find('"dirs": "/tmp"', 1, true) ~= nil, "成功工具应展示调用参数 dirs")
    t.true_(joined:find("结果:", 1, true) ~= nil, "折叠内应有结果标签")
    t.true_(joined:find("file1", 1, true) ~= nil, "成功工具应展示执行结果")
    -- 失败工具：同样有结构化参数与结构化（JSON）错误结果
    t.true_(joined:find('"filepath": "/nope.txt"', 1, true) ~= nil, "失败工具也应展示调用参数")
    t.true_(joined:find('"error": "文件不存在"', 1, true) ~= nil, "失败工具应结构化展示错误结果")
    t.true_(joined:find("❌ 工具: read_file", 1, true) ~= nil, "失败工具首行应为 ❌ 状态")
    -- 参数里不应重复展示 description 样板字段
    t.true_(joined:find('"description"', 1, true) == nil, "参数区不应重复展示 description 字段")

    chat_view.reset()
    chat_service.reset()
  end)

  it("思考悬浮窗禁用折叠（不被全局 fold 收起内容）", function(t)
    local reasoning_panel = require("NeoAI.ui.components.reasoning_panel")
    reasoning_panel.reset()
    -- 模拟用户全局开启折叠：minimal 浮窗会继承 foldenable/foldmethod
    local prev_foldenable, prev_foldmethod = vim.o.foldenable, vim.o.foldmethod
    vim.o.foldenable = true
    vim.o.foldmethod = "indent"

    reasoning_panel.show("  step one\n  step two")
    local found = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "neoai_reasoning" then
        found = true
        t.false_(vim.wo[win].foldenable, "思考悬浮窗应关闭 foldenable")
        t.eq("manual", vim.wo[win].foldmethod, "思考悬浮窗 foldmethod 应为 manual")
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        t.eq("  step one", lines[1], "推理内容应完整可见（不被折叠收起）")
        t.eq("  step two", lines[2], "推理内容应完整可见（不被折叠收起）")
        break
      end
    end
    t.true_(found, "应创建思考悬浮窗")

    vim.o.foldenable, vim.o.foldmethod = prev_foldenable, prev_foldmethod
    reasoning_panel.reset()
  end)

  it("提问悬浮窗禁用折叠（不被全局 fold 收起内容）", function(t)
    local ask_user_ui = require("NeoAI.ui.components.ask_user")
    ask_user_ui.reset()
    -- 模拟用户全局开启折叠：minimal 浮窗会继承 foldenable/foldmethod
    local prev_foldenable, prev_foldmethod = vim.o.foldenable, vim.o.foldmethod
    vim.o.foldenable = true
    vim.o.foldmethod = "indent"

    ask_user_ui.show({
      question = "要继续吗？",
      options = { "是", "否" },
      on_answer = function() end,
      on_cancel = function() end,
    })
    local found = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "neoai_ask_user" then
        found = true
        t.false_(vim.wo[win].foldenable, "提问悬浮窗应关闭 foldenable")
        t.eq("manual", vim.wo[win].foldmethod, "提问悬浮窗 foldmethod 应为 manual")
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        t.true_(lines[1]:find("要继续吗", 1, true) ~= nil, "问题应完整可见（不被折叠收起）")
        local joined = table.concat(lines, "\n")
        t.true_(joined:find("选项", 1, true) ~= nil, "选项内容应完整可见（不被折叠收起）")
        break
      end
    end
    t.true_(found, "应创建提问悬浮窗")

    vim.o.foldenable, vim.o.foldmethod = prev_foldenable, prev_foldmethod
    ask_user_ui.reset()
  end)

  it("提问选项拆分简介与描述并高亮", function(t)
    local ask_user_ui = require("NeoAI.ui.components.ask_user")
    ask_user_ui.reset()

    local answered = nil
    ask_user_ui.show({
      question = "选择生成方式？",
      options = {
        { label = "快速生成", description = "直接用当前上下文" },
        { label = "计划模式", description = "先调研再生成" },
      },
      on_answer = function(a) answered = a end,
      on_cancel = function() end,
    })

    local buf
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].filetype == "neoai_ask_user" then
        buf = b
        break
      end
    end
    t.not_nil(buf, "应创建提问悬浮窗")

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    t.true_(joined:find("快速生成", 1, true) ~= nil, "应展示选项简介（短标签）")
    t.true_(joined:find("直接用当前上下文", 1, true) ~= nil, "应展示选项描述")

    -- 高亮：附加了选项简介/描述的高亮标记
    local hl_ns = vim.api.nvim_create_namespace("neoai_ask_user_hi")
    local marks = vim.api.nvim_buf_get_extmarks(buf, hl_ns, 0, -1, {})
    t.true_(#marks > 0, "应附加选项高亮标记")

    ask_user_ui.reset()
  end)

  it("每个工具完成即各自更新状态（并发工具不互相等待）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "user", content = "查一下" },
      { role = "assistant", content = "", tool_calls = {
        { id = "a", ["function"] = { name = "lsp_type_definition", arguments = "{}" } },
        { id = "b", ["function"] = { name = "lsp_implementation", arguments = "{}" } },
      } },
    }
    chat_view.refresh()

    local function status_of(name)
      for _, l in ipairs(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)) do
        if l:find(name, 1, true) and l:find("工具", 1, true) then
          if l:find("✅", 1, true) then return "success" end
          if l:find("❌", 1, true) then return "failure" end
          return "running"
        end
      end
      return nil
    end

    event_bus.emit(events.TOOL_EXECUTION_STARTED, { agent_id = agent.id, tool_call_id = "a" })
    event_bus.emit(events.TOOL_EXECUTION_STARTED, { agent_id = agent.id, tool_call_id = "b" })
    chat_view.flush()
    t.eq("running", status_of("lsp_type_definition"), "刚启动时应为执行中")
    t.eq("running", status_of("lsp_implementation"), "刚启动时应为执行中")

    -- 只完成 a：a 应立即更新为 ✅，b 仍为 ⏳（此前 a 会一直停在 ⏳ 等整批结果落库）
    event_bus.emit(events.TOOL_EXECUTION_COMPLETED, { agent_id = agent.id, tool_call_id = "a", duration_ms = 89 })
    chat_view.flush()
    t.eq("success", status_of("lsp_type_definition"), "单个工具完成应立即更新为 ✅")
    t.matches("89ms", table.concat(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false), "\n"),
      "已完成工具应锁定总耗时")
    t.eq("running", status_of("lsp_implementation"), "未完成的工具应保持 ⏳")

    -- b 失败：应立即更新为 ❌
    event_bus.emit(events.TOOL_EXECUTION_ERROR, { agent_id = agent.id, tool_call_id = "b", error = "timeout", duration_ms = 500 })
    chat_view.flush()
    t.eq("failure", status_of("lsp_implementation"), "单个工具失败应立即更新为 ❌")

    chat_view.reset()
    chat_service.reset()
  end)

  it("光标不跟随时不弹出思考悬浮窗（agent loop）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local reasoning_panel = require("NeoAI.ui.components.reasoning_panel")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()
    reasoning_panel.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 预置足够长的内容，使 buffer 行数超过 5
    agent.messages = {
      { role = "user", content = "q1" },
      { role = "assistant", content = "第一行\n第二行\n第三行\n第四行\n第五行\n第六行" },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    -- 光标放在第 2 行（不在最后 5 行内）：先触发一次渲染把 following 记为不跟随
    vim.api.nvim_win_set_cursor(opened.win_id, { 2, 0 })
    local last = agent.messages[#agent.messages]
    event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = last })
    chat_view.flush()

    -- 推理分片到达：此前会直接弹出思考悬浮窗；现在光标不跟随时应抑制
    event_bus.emit(events.REASONING_CHUNK, { agent_id = agent.id, chunk = "思考一 ", reasoning = "思考一" })
    chat_view.flush()
    t.false_(reasoning_panel.is_open(), "光标不跟随时不应弹出思考悬浮窗")
    event_bus.emit(events.REASONING_CHUNK, { agent_id = agent.id, chunk = "思考二", reasoning = "思考一思考二" })
    chat_view.flush()
    t.false_(reasoning_panel.is_open(), "后续推理分片也不应弹出思考悬浮窗")

    -- 光标回到底部（跟随）：推理分片应恢复正常弹出
    local total = vim.api.nvim_buf_line_count(opened.buf)
    vim.api.nvim_win_set_cursor(opened.win_id, { total, 0 })
    event_bus.emit(events.REASONING_CHUNK, { agent_id = agent.id, chunk = "思考三", reasoning = "思考三" })
    chat_view.flush()
    t.true_(reasoning_panel.is_open(), "光标回到底部跟随时应恢复弹出思考悬浮窗")

    chat_view.reset()
    chat_service.reset()
    reasoning_panel.reset()
  end)

  it("光标不跟随时不重新折叠已展开的折叠文本（agent loop）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 多轮内容：推理折叠 + 工具折叠 + 长正文，使 buffer 行数超过 5
    agent.messages = {
      { role = "user", content = "q1" },
      { role = "assistant", content = "正文1", reasoning = "思考过程内容", tool_calls = {
        { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = "out1" },
      { role = "assistant", content = "正文2\n正文3\n正文4\n正文5" },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    -- 找到推理折叠并展开（模拟用户正在查看）
    local reason_line = 0
    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find("思考过程内容", 1, true) then reason_line = i break end
    end
    t.true_(reason_line > 0, "应找到推理折叠内容行")
    vim.api.nvim_win_set_cursor(opened.win_id, { reason_line, 0 })
    local fold_start = vim.fn.foldclosed(reason_line)
    t.true_(fold_start > 0, "推理折叠应默认收起")
    vim.cmd("normal! zo")
    t.eq(-1, vim.fn.foldclosed(reason_line), "zo 后推理折叠应展开")

    -- 光标放在第 2 行（不跟随），流式更新触发渲染：不应把展开的折叠重新收起
    vim.api.nvim_win_set_cursor(opened.win_id, { 2, 0 })
    local last = agent.messages[#agent.messages]
    last.content = last.content .. "\n流式新内容"
    event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = last })
    chat_view.flush()

    -- 重新定位：buffer 已重写，需按内容重新找到推理行，再断言折叠状态未被强制收起
    local lines2 = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local reason_line2 = 0
    for i, l in ipairs(lines2) do
      if l:find("思考过程内容", 1, true) then reason_line2 = i break end
    end
    t.true_(reason_line2 > 0, "流式更新后推理内容仍在 buffer")
    t.eq(-1, vim.fn.foldclosed(reason_line2), "光标不跟随时不应把已展开的折叠重新收起")

    chat_view.reset()
    chat_service.reset()
  end)

  it("跟随模式折叠后光标可视化回到窗口底部（而非被拽到窗口上面）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 足够多非缩进的普通行，使窗口显示高度有限，折叠块位于正文末尾
    local plain = {}
    for i = 1, 40 do plain[#plain + 1] = "普通行 " .. i end
    agent.messages = {
      { role = "user", content = "q1" },
      { role = "assistant", content = table.concat(plain, "\n"), tool_calls = {
        { id = "c1", ["function"] = { name = "run_command", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "run_command", content = "" },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    -- 光标停在底部（跟随流式输出），关闭本地 scrolloff 使 zb 能贴到底
    local total = vim.api.nvim_buf_line_count(opened.buf)
    vim.wo[opened.win_id].scrolloff = 0
    vim.api.nvim_win_set_cursor(opened.win_id, { total, 0 })

    -- 折叠块一次到达多行：此前 _render 里 zM 收起折叠后，_scroll_to_end 只 set_cursor
    -- 到最后一行，nvim 把可视化光标放到折叠首行，导致 winline 接近窗口顶部（光标"跳到窗口上面"）。
    -- 修复后在 set_cursor 后追加 zb 把光标行平移到窗口底部。
    local result = agent.messages[3]
    local ls = {}
    for i = 1, 25 do ls[#ls + 1] = "结果行 " .. i end
    result.content = table.concat(ls, "\n")
    event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = result })
    chat_view.flush()

    local cur = vim.api.nvim_win_get_cursor(opened.win_id)
    local line_count = vim.api.nvim_buf_line_count(opened.buf)
    local winh = vim.fn.winheight(0)
    t.eq(line_count, cur[1], "光标逻辑行应跟随到最后一行")
    local winline = vim.fn.winline()
    t.true_(winline >= winh - 1,
      string.format("折叠后光标视窗行应贴到窗口底部（winline=%d/winheight=%d），而非跳到窗口上面", winline, winh))

    chat_view.reset()
    chat_service.reset()
  end)

  it("上下文压缩期间打开悬浮窗并流式显示摘要，完成后关闭", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local float_window = require("NeoAI.ui.components.float_stream_window")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()
    float_window.reset()

    chat_view.open()
    local agent = chat_service.get_current_agent()
    event_bus.emit(events.COMPACTION_STARTED, { agent_id = agent.id, estimated_tokens = 100 })
    chat_view.flush()
    t.true_(float_window.is_open(), "开始压缩时应打开悬浮窗")
    t.matches("正在压缩", float_window.get_text(), "压缩开始时应显示占位提示")

    event_bus.emit(events.COMPACTION_CHUNK, { agent_id = agent.id, reasoning = "思考中", content = "发生了一次压缩" })
    chat_view.flush()
    t.true_(float_window.is_open(), "压缩分片应保持悬浮窗打开")
    t.matches("思考中", float_window.get_text(), "悬浮窗应展示接收到的推理")
    t.matches("压缩", float_window.get_text(), "悬浮窗应展示接收到的摘要正文")

    event_bus.emit(events.COMPACTION_COMPLETED, { agent_id = agent.id, replaced = 2, summary = "摘要" })
    t.false_(float_window.is_open(), "压缩完成时应关闭悬浮窗")

    chat_view.reset()
    chat_service.reset()
    float_window.reset()
  end)

  it("计划蒸馏期间打开悬浮窗，完成后关闭", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local float_window = require("NeoAI.ui.components.float_stream_window")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()
    float_window.reset()

    chat_view.open()
    local agent = chat_service.get_current_agent()
    event_bus.emit(events.PLAN_DISTILL_STARTED, { agent_id = agent.id })
    chat_view.flush()
    t.true_(float_window.is_open(), "开始蒸馏时应打开悬浮窗")
    t.matches("蒸馏", float_window.get_text(), "蒸馏开始时应显示占位提示")

    event_bus.emit(events.PLAN_DISTILL_CHUNK, { agent_id = agent.id, reasoning = nil, content = "蒸馏后的上下文" })
    chat_view.flush()
    t.matches("蒸馏后的上下文", float_window.get_text(), "悬浮窗应展示蒸馏时接收到的正文")

    event_bus.emit(events.PLAN_DISTILLED, { agent_id = agent.id, replaced = 2, summary = "蒸馏摘要" })
    t.false_(float_window.is_open(), "蒸馏完成时应关闭悬浮窗")

    chat_view.reset()
    chat_service.reset()
    float_window.reset()
  end)

  it("光标不跟随时不打开上下文压缩悬浮窗（与推理一致）", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local float_window = require("NeoAI.ui.components.float_stream_window")
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    chat_view.reset()
    chat_service.reset()
    float_window.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 预置足够长的内容，使 buffer 行数超过 5
    agent.messages = {
      { role = "user", content = "q1" },
      { role = "assistant", content = "第一行\n第二行\n第三行\n第四行\n第五行\n第六行" },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    -- 光标移到顶部（不在最后 5 行内），模拟用户回看上方内容
    vim.api.nvim_win_set_cursor(opened.win_id, { 1, 0 })

    event_bus.emit(events.COMPACTION_STARTED, { agent_id = agent.id, estimated_tokens = 100 })
    event_bus.emit(events.COMPACTION_CHUNK, { agent_id = agent.id, reasoning = "", content = "不应显示" })
    chat_view.flush()
    t.false_(float_window.is_open(), "光标不跟随时不弹出压缩悬浮窗")

    chat_view.reset()
    chat_service.reset()
    float_window.reset()
  end)

  it("接收参数悬浮窗按分片增量追加原始参数并始终滚到底", function(t)
    local tool_args_panel = require("NeoAI.ui.components.tool_args_panel")
    tool_args_panel.reset()

    local function tc(name, args)
      local c = { index = 0, type = "function" }
      c["function"] = { name = name, arguments = args }
      return c
    end

    local function count_heads(s)
      local _, n = s:gsub("正在接收参数: ", "")
      return n
    end

    -- 模拟模型分片生成参数（残缺 JSON 逐片累积）：面板应增量追加（终端式增长，
    -- 与思考面板一致），工具头只出现一次，不因分片而整段重复渲染。
    tool_args_panel.show({ tc("run_command", '{"cmd":') })
    t.true_(tool_args_panel.is_open(), "应打开接收参数悬浮窗")
    local c1 = tool_args_panel.get_content()
    t.true_(c1:find("正在接收参数: run_command", 1, true) ~= nil, "应展示工具头")
    t.true_(c1:find('{"cmd":', 1, true) ~= nil, "应展示原始参数分片")

    tool_args_panel.show({ tc("run_command", '{"cmd":"ls') })
    tool_args_panel.show({ tc("run_command", '{"cmd":"ls"}') })
    local c2 = tool_args_panel.get_content()
    t.true_(c2:find('{"cmd":"ls"}', 1, true) ~= nil, "参数应增量拼接为完整 JSON")
    t.eq(1, count_heads(c2), "工具头应只出现一次（增量追加不重复渲染整段）")

    -- 位置不变但参数被替换（不再以已见内容为前缀）：回退整段重建，仍只有一处工具头
    tool_args_panel.show({ tc("run_command", '{"other":1}') })
    local c3 = tool_args_panel.get_content()
    t.true_(c3:find('{"other":1}', 1, true) ~= nil, "替换后应展示新参数")
    t.true_(c3:find('{"cmd"', 1, true) == nil, "替换后不应残留旧参数片段")
    t.eq(1, count_heads(c3), "替换重建后仍只有一处工具头")

    local win_id
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "neoai_tool_args" then win_id = w break end
    end
    t.not_nil(win_id, "应创建接收参数悬浮窗")

    local function last_buf_line()
      return vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win_id))
    end

    -- 追加超长单行（wrap 折成多屏幕行）：滚动到底应把光标移到内容末尾（末行末列），
    -- 否则 wrap 下只显示长行开头（看不到尾部）。列 > 0 证明光标进入了末行内部。
    local big = string.rep("段", 400)
    tool_args_panel.show({ tc("run_command", '{"cmd":"' .. big .. '"}') })
    local cur = vim.api.nvim_win_get_cursor(win_id)
    t.eq(last_buf_line(), cur[1], "超长单行内容时光标仍应位于最后一行")
    t.true_(cur[2] > 0, "超长单行时光标应移到内容末尾（列>0），而非停留在行首")
    -- 末行应为参数结构收尾（闭合括号），说明已滚过超长参数行到末尾
    local last_line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win_id),
      last_buf_line() - 1, last_buf_line(), false)[1]
    t.true_(last_line:find("}", 1, true) ~= nil, "末行应为结构收尾（}），表明已滚到内容末尾")

    -- 两个并发工具调用：应出现两处工具头（各自独立增长）
    tool_args_panel.show({ tc("git_status", "1"), tc("run_command", "2") })
    t.eq(2, count_heads(tool_args_panel.get_content()), "并发工具应各自出现一处工具头")

    tool_args_panel.reset()
  end)

  it("主界面鼠标滚轮平滑滚动且末行下方留白不超上限", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    -- 预置足够长的内容（远超窗口高度），使视口需要滚动
    local body = {}
    for i = 1, 200 do body[#body + 1] = "content line " .. i end
    agent.messages = {
      { role = "user", content = "q1" },
      { role = "assistant", content = table.concat(body, "\n") },
    }
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    local total = vim.api.nvim_buf_line_count(opened.buf)
    local win_h = vim.api.nvim_win_get_height(opened.win_id)
    local wb = vim.wo[opened.win_id].winbar
    local avail = win_h - ((wb ~= nil and wb ~= "") and 1 or 0)
    t.true_(total > avail + 5, "前置条件：buffer 应远超窗口高度，实际 " .. total .. "/" .. avail)

    -- 滚轮映射应存在
    local fwd = vim.fn.maparg("<ScrollWheelDown>", "n", false, true)
    local back = vim.fn.maparg("<ScrollWheelUp>", "n", false, true)
    t.not_nil(fwd.callback, "主界面应注册 <ScrollWheelDown> 映射")
    t.not_nil(back.callback, "主界面应注册 <ScrollWheelUp> 映射")

    -- 顶部连续向下滚：中间过程应真的滚动视口（不再是"光标撞边才动"），
    -- 且最终停在底部（末行可见）
    vim.api.nvim_win_set_cursor(opened.win_id, { 1, 0 })
    local toplines = {}
    for _ = 1, 150 do
      fwd.callback()
      toplines[#toplines + 1] = vim.api.nvim_win_call(opened.win_id, function() return vim.fn.line("w0") end)
    end
    t.true_(toplines[1] > 1 or toplines[2] > toplines[1],
      "向下滚应平滑移动视口（而不是只在光标撞边时跳动）")
    local topline_end = vim.api.nvim_win_call(opened.win_id, function() return vim.fn.line("w0") end)
    t.true_(topline_end > 1, "连续向下滚后视口应已下移")

    -- 末行可见，且下方留白不超过配置上限（默认 3）
    local ws_end = vim.api.nvim_win_call(opened.win_id, function()
      return { w0 = vim.fn.line("w0"), wd = vim.fn.line("w$") }
    end)
    t.eq(total, ws_end.wd, "连续向下滚后应停在 buffer 末行（末行可见）")
    local blank = vim.api.nvim_win_call(opened.win_id, function()
      local topline = vim.fn.winsaveview().topline
      local h = vim.api.nvim_win_text_height(opened.win_id, {
        start_row = topline - 1, end_row = total - 1,
      })
      return avail - h.all
    end)
    t.true_(blank >= 0 and blank <= 3,
      "末行下方留白应被钳制在 [0, 3] 行内，实际 " .. blank)

    -- 继续向下滚不应让留白增长（不应越滚越白）
    for _ = 1, 10 do fwd.callback() end
    local blank2 = vim.api.nvim_win_call(opened.win_id, function()
      local topline = vim.fn.winsaveview().topline
      local h = vim.api.nvim_win_text_height(opened.win_id, {
        start_row = topline - 1, end_row = total - 1,
      })
      return avail - h.all
    end)
    t.true_(blank2 <= 3, "持续向下滚时留白不应突破上限，实际 " .. blank2)

    -- 向上滚：视口平滑上移，光标跟到视口首行附近
    local before_up = vim.api.nvim_win_call(opened.win_id, function() return vim.fn.line("w0") end)
    back.callback()
    local after_up = vim.api.nvim_win_call(opened.win_id, function() return vim.fn.line("w0") end)
    t.true_(after_up < before_up, "向上滚应把视口首行上移（平滑滚动）")

    -- 向上回看时视为"不跟随"：流式新内容到达后视口不应被拽回底部
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local last = agent.messages[#agent.messages]
    last.content = last.content .. "\n流式追加行"
    event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = last })
    chat_view.flush()
    local topline_after_stream = vim.api.nvim_win_call(opened.win_id, function() return vim.fn.line("w0") end)
    t.true_(topline_after_stream < vim.api.nvim_buf_line_count(opened.buf),
      "向上回看时流式更新不应把视口拽到底部（topline=" .. topline_after_stream .. "）")

    -- 连续向上滚不越界（topline >= 1）
    for _ = 1, 200 do back.callback() end
    local topline_top = vim.api.nvim_win_call(opened.win_id, function() return vim.fn.line("w0") end)
    t.eq(1, topline_top, "连续向上滚应停在 buffer 首行（视口首行 = 1）")

    chat_view.reset()
    chat_service.reset()
  end)

  it("聊天主窗口注册 <leader>ap 快捷键触发沙箱待审审批", function(t)
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local found = nil
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(opened.buf, "n")) do
      if (m.desc or ""):find("沙箱", 1, true) then found = m break end
    end
    t.not_nil(found, "主窗口普通模式应注册沙箱待审审批快捷键（<leader>ap）")
    t.true_(found.lhs:sub(-2) == "ap", "沙箱待审审批快捷键应以 ap 结尾，实际: " .. tostring(found.lhs))

    chat_view.reset()
    chat_service.reset()
  end)

end)
