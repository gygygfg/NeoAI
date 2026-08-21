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

    local cur_after = vim.api.nvim_win_get_cursor(opened.win_id)
    t.eq(2, cur_after[1], "光标不在最后 5 行时流式更新不应移动光标")
    local total_after = vim.api.nvim_buf_line_count(opened.buf)
    t.true_(total_after > total_before, "流式内容应已写入 buffer")

    -- 光标贴近底部（最后 5 行内）：流式更新应跟随滚动到底部
    vim.api.nvim_win_set_cursor(opened.win_id, { total_after, 0 })
    last.content = last.content .. "\n更多内容"
    event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = last })

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
    t.eq("nofile", vim.bo[buf].buftype, "聊天 buffer 应为 nofile（native LSP 自动启用会跳过）")
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

end)
