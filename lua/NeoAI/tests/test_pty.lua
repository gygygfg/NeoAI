--- 交互式 PTY 会话服务测试
--- @module NeoAI.tests.test_pty

local tests = require("NeoAI.tests")
local config_store = require("NeoAI.kernel.config_store")
local async = require("NeoAI.utils.async")

tests.suite("pty", function(_, it, before_each)
  before_each(function()
    local pty = require("NeoAI.services.pty")
    pcall(pty.reset)
  end)

  it("key_bytes 映射常见按键", function(t)
    local pty = require("NeoAI.services.pty")
    t.eq("\r", pty.key_bytes("Enter"))
    t.eq("\r", pty.key_bytes("<CR>"))
    t.eq("\t", pty.key_bytes("Tab"))
    t.eq("\27", pty.key_bytes("Escape"))
    t.eq("\27[A", pty.key_bytes("Up"))
    t.eq("\3", pty.key_bytes("Ctrl-C"))
    t.eq("\3", pty.key_bytes("<C-c>"))
    t.eq("\4", pty.key_bytes("C-d"))
    t.eq("y", pty.key_bytes("y"))
    t.nil_(pty.key_bytes("NotAKeyName"))
    t.eq("\t\r", pty.keys_bytes({ "Tab", "Enter" }))
  end)

  it("检测等待输入并由判官注入答案（无沙箱 argv）", function(t)
    local pty = require("NeoAI.services.pty")
    local old_enabled = config_store.get("tools.run_command.interactive.enabled")
    config_store.set("tools.run_command.interactive.enabled", true)
    config_store.set("tools.run_command.interactive.poll_ms", 40)

    -- 判官：依次回答 one / two
    local answers = { "one", "two" }
    local idx = 1
    pty.set_judge(function(session)
      if idx <= #answers then
        local a = answers[idx]
        idx = idx + 1
        pcall(pty.send_text, session.id, a)
      end
      return async.resolve(true)
    end)

    local session = pty.open({
      argv = { "bash", "-c",
        "read -r a; echo GOT1:$a; read -r b; echo GOT2:$b" },
      description = "测试：依次读入两行",
      command = "read a; read b",
    })
    t.not_nil(session, "会话应创建成功")

    local result = t.await(pty.await(session), 20000)
    t.eq(0, result.code)
    t.matches("GOT1:one", result.output)
    t.matches("GOT2:two", result.output)

    pty.set_judge(nil)
    pcall(pty.reset)
    config_store.set("tools.run_command.interactive.enabled", old_enabled)
  end)

  it("terminal_send_text 工具向活动会话注入文本", function(t)
    local pty = require("NeoAI.services.pty")
    local old_enabled = config_store.get("tools.run_command.interactive.enabled")
    local old_judge = config_store.get("tools.run_command.interactive.judge.enabled")
    config_store.set("tools.run_command.interactive.enabled", true)
    config_store.set("tools.run_command.interactive.judge.enabled", false)
    pty.set_judge(nil)

    local session = pty.open({
      argv = { "bash", "-c", "read -r a; echo GOT:$a" },
      description = "测试工具注入",
    })
    t.not_nil(session)

    -- 等待检测到等待输入（最多 5s）
    local waited = vim.wait(5000, function()
      return session.waiting == true
    end, 30)
    t.true_(waited, "应检测到等待输入")

    local term_tool
    for _, x in ipairs(require("NeoAI.tools.builtin.terminal").get_tools()) do
      if x.name == "terminal_send_text" then term_tool = x end
    end
    t.not_nil(term_tool)
    local ok_send, send_err
    term_tool.func({ text = "hello", description = "注入一行" }, function() ok_send = true end,
      function(e) send_err = e end)
    t.true_(ok_send, "工具应成功注入: " .. tostring(send_err))

    local result = t.await(pty.await(session), 15000)
    t.eq(0, result.code)
    t.matches("GOT:hello", result.output)

    config_store.set("tools.run_command.interactive.enabled", old_enabled)
    config_store.set("tools.run_command.interactive.judge.enabled", old_judge)
    pcall(pty.reset)
  end)

  it("run_command 经门禁以 PTY 运行并自动应答", function(t)
    local pty = require("NeoAI.services.pty")
    local old_enabled = config_store.get("tools.run_command.interactive.enabled")
    local old_judge = config_store.get("tools.run_command.interactive.judge.enabled")
    config_store.set("tools.run_command.interactive.enabled", true)
    config_store.set("tools.run_command.interactive.poll_ms", 50)
    config_store.set("tools.run_command.interactive.judge.enabled", true)
    pty.set_judge(function(session)
      pcall(pty.send_text, session.id, "world")
      return async.resolve(true)
    end)

    local tools = require("NeoAI.tools")
    local d = tools.execute("run_command", {
      command = "read -r a; echo GOT:$a",
      description = "交互式集成测试",
    }, {})
    local text = t.await(d, 60000)
    t.matches("GOT:world", tostring(text))

    pty.set_judge(nil)
    pcall(pty.reset)
    config_store.set("tools.run_command.interactive.enabled", old_enabled)
    config_store.set("tools.run_command.interactive.judge.enabled", old_judge)
  end)

  it("悬浮终端仅在光标跟随时弹出", function(t)
    local pty = require("NeoAI.services.pty")
    local cfg = config_store
    local old = cfg.get("tools.run_command.interactive.show_window")
    local saved = package.loaded["NeoAI.ui.window.chat_view"]
    -- 本用例只验证「光标跟随」维度：固定焦点为「聚焦 NeoAI 界面」，隔离焦点门控变量。
    local focus_saved = package.loaded["NeoAI.ui.focus"]
    package.loaded["NeoAI.ui.focus"] = { is_focused = function() return true end }

    cfg.set("tools.run_command.interactive.show_window", "on_wait")
    package.loaded["NeoAI.ui.window.chat_view"] = { is_following = function() return false end }
    t.false_(pty._should_show_window({}, "delay"), "不跟随时 on_wait 不应弹出")
    package.loaded["NeoAI.ui.window.chat_view"] = { is_following = function() return true end }
    t.true_(pty._should_show_window({}, "delay"), "跟随且 on_wait 超时后应弹出")
    t.false_(pty._should_show_window({}, "start"), "on_wait 在会话启动时不弹")

    cfg.set("tools.run_command.interactive.show_window", "always")
    package.loaded["NeoAI.ui.window.chat_view"] = { is_following = function() return false end }
    t.false_(pty._should_show_window({}, "start"), "不跟随时 always 也不弹")
    package.loaded["NeoAI.ui.window.chat_view"] = { is_following = function() return true end }
    t.true_(pty._should_show_window({}, "start"), "跟随且 always 启动即弹")
    t.false_(pty._should_show_window({}, "delay"), "always 不走 delay 触发")

    -- session.window 只是「曾打开」标记：真打开（组件 is_open 为 true）时不重复弹
    local tw_saved = package.loaded["NeoAI.ui.components.terminal_window"]
    pcall(pty.reset)
    cfg.set("tools.run_command.interactive.show_window", "on_wait")
    package.loaded["NeoAI.ui.components.terminal_window"] = {
      is_open = function(id) return id == "s1" end,
    }
    t.false_(pty._should_show_window({ id = "s1", window = {} }, "delay"), "已打开不应重复弹")
    -- 句柄失效（组件 is_open 为 false，如用户手动关窗）→ 视为未打开，可再次弹出并清除 stale 句柄
    local stale = { id = "s2", window = {} }
    t.true_(pty._should_show_window(stale, "delay"), "句柄失效后应可再次弹出")
    t.nil_(stale.window, "失效句柄应被清除")
    package.loaded["NeoAI.ui.components.terminal_window"] = tw_saved
    pcall(pty.reset)

    cfg.set("tools.run_command.interactive.show_window", "never")
    t.false_(pty._should_show_window({}, "delay"), "never 不弹")

    package.loaded["NeoAI.ui.window.chat_view"] = saved
    package.loaded["NeoAI.ui.focus"] = focus_saved
    cfg.set("tools.run_command.interactive.show_window", old)
  end)

  it("悬浮终端句柄失效后仍能再次弹出（回归“不是每次都弹出”）", function(t)
    local pty = require("NeoAI.services.pty")
    local cfg = config_store
    local old_sw = cfg.get("tools.run_command.interactive.show_window")
    local tw_saved = package.loaded["NeoAI.ui.components.terminal_window"]
    local cv_saved = package.loaded["NeoAI.ui.window.chat_view"]
    local focus_saved = package.loaded["NeoAI.ui.focus"]
    package.loaded["NeoAI.ui.focus"] = { is_focused = function() return true end }
    pcall(pty.reset)

    local opened = true
    package.loaded["NeoAI.ui.components.terminal_window"] = {
      is_open = function() return opened end,
    }
    package.loaded["NeoAI.ui.window.chat_view"] = { is_following = function() return true end }
    pty._set_force_ui(true)
    cfg.set("tools.run_command.interactive.show_window", "on_wait")

    -- 窗口打开：判定已打开，不重复弹
    local session = { id = "ptyS", window = {} }
    t.false_(pty._should_show_window(session, "delay"), "窗口打开时不重复弹")

    -- 用户手动关闭（<C-q>）/窗口被关：组件 is_open 变 false，但 session.window 句柄仍残留。
    -- 修复前会据此永久判定「已打开」而不再弹（伪终端“不是每次都弹出”的根因）。
    opened = false
    t.true_(pty._should_show_window(session, "delay"), "句柄失效后应可再次弹出")
    t.nil_(session.window, "失效句柄应被清除")

    pty._set_force_ui(false)
    pcall(pty.reset)
    package.loaded["NeoAI.ui.components.terminal_window"] = tw_saved
    package.loaded["NeoAI.ui.window.chat_view"] = cv_saved
    package.loaded["NeoAI.ui.focus"] = focus_saved
    cfg.set("tools.run_command.interactive.show_window", old_sw)
  end)

  it("跟随跳变时隐藏/重弹悬浮终端窗", function(t)
    local pty = require("NeoAI.services.pty")
    local cfg = config_store
    local old_sw = cfg.get("tools.run_command.interactive.show_window")
    local tw_saved = package.loaded["NeoAI.ui.components.terminal_window"]
    local cv_saved = package.loaded["NeoAI.ui.window.chat_view"]
    local focus_saved = package.loaded["NeoAI.ui.focus"]
    package.loaded["NeoAI.ui.focus"] = { is_focused = function() return true end }
    pcall(pty.reset)

    local opens = {}
    package.loaded["NeoAI.ui.components.terminal_window"] = {
      open = function(session) opens[session.id] = true; return { id = session.id } end,
      close = function(id) opens[id] = nil end,
      is_open = function(id) return opens[id] == true end,
      reset = function() opens = {} end,
    }
    package.loaded["NeoAI.ui.window.chat_view"] = { is_following = function() return true end }
    pty._set_force_ui(true)
    cfg.set("tools.run_command.interactive.show_window", "on_wait")

    -- 已达弹出阈值（window_eligible）的会话：隐藏 → 重弹
    local session = { id = "ptyA", window_eligible = true, window = { id = "ptyA" } }
    opens["ptyA"] = true
    pty._inject_session(session)
    pty._hide_all_windows()
    t.nil_(session.window, "隐藏后应清除窗口句柄")
    t.nil_(opens["ptyA"], "隐藏后组件窗口应关闭")
    t.true_(session.window_hidden == true, "应标记为已隐藏")
    pty._restore_pending_windows()
    t.not_nil(session.window, "重弹后应重新打开窗口")
    t.true_(opens["ptyA"] == true, "重弹后组件窗口应打开")

    -- on_wait 下未达弹出阈值的会话不重弹
    local idle = { id = "ptyB", window_eligible = false, window = { id = "ptyB" } }
    opens["ptyB"] = true
    pty._inject_session(idle)
    pty._hide_all_windows()
    t.nil_(opens["ptyB"], "隐藏后 idle 窗口应关闭")
    pty._restore_pending_windows()
    t.nil_(opens["ptyB"], "on_wait 下未达阈值的会话不应重弹")

    -- always 下未结束会话一律重弹
    cfg.set("tools.run_command.interactive.show_window", "always")
    local s2 = { id = "ptyC", window_eligible = false, window = { id = "ptyC" } }
    opens["ptyC"] = true
    pty._inject_session(s2)
    pty._hide_all_windows()
    t.nil_(opens["ptyC"], "隐藏后应关闭")
    pty._restore_pending_windows()
    t.true_(opens["ptyC"] == true, "always 下未结束会话应重弹")

    pty._set_force_ui(false)
    pcall(pty.reset)
    package.loaded["NeoAI.ui.components.terminal_window"] = tw_saved
    package.loaded["NeoAI.ui.window.chat_view"] = cv_saved
    package.loaded["NeoAI.ui.focus"] = focus_saved
    cfg.set("tools.run_command.interactive.show_window", old_sw)
  end)

  it("焦点不在 NeoAI 界面时悬浮终端不弹（进入等待）", function(t)
    local pty = require("NeoAI.services.pty")
    local focus = require("NeoAI.ui.focus")
    local cfg = config_store
    local old_sw = cfg.get("tools.run_command.interactive.show_window")
    local tw_saved = package.loaded["NeoAI.ui.components.terminal_window"]
    local cv_saved = package.loaded["NeoAI.ui.window.chat_view"]
    pcall(pty.reset)
    focus.reset()

    package.loaded["NeoAI.ui.components.terminal_window"] = { is_open = function() return false end }
    package.loaded["NeoAI.ui.window.chat_view"] = { is_following = function() return true end }
    pty._set_force_ui(true)
    cfg.set("tools.run_command.interactive.show_window", "on_wait")

    focus.install()
    focus._set_force_ui(true) -- headless 下模拟 attached UI，使焦点门控生效
    -- 当前窗口为普通 buffer → 未聚焦 → 即使光标跟随也不弹
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(plain)
    focus.refresh()
    t.false_(focus.is_focused())
    t.false_(pty._should_show_window({}, "delay"), "未聚焦时不应弹出（进入等待）")

    -- 切到 NeoAI 界面 buffer → 聚焦 → 可弹
    local neo = vim.api.nvim_create_buf(false, true)
    vim.bo[neo].filetype = "neoai_sandbox_review"
    vim.api.nvim_set_current_buf(neo)
    focus.refresh()
    t.true_(focus.is_focused())
    t.true_(pty._should_show_window({}, "delay"), "聚焦且跟随时应可弹出")

    vim.api.nvim_buf_delete(plain, { force = true })
    vim.api.nvim_buf_delete(neo, { force = true })
    pty._set_force_ui(false)
    focus.reset()
    pcall(pty.reset)
    package.loaded["NeoAI.ui.components.terminal_window"] = tw_saved
    package.loaded["NeoAI.ui.window.chat_view"] = cv_saved
    cfg.set("tools.run_command.interactive.show_window", old_sw)
  end)

  it("重开悬浮终端应重放已有输出（隐藏→重弹后窗口非空白）", function(t)
    local pty = require("NeoAI.services.pty")
    local cfg = config_store
    local old_sw = cfg.get("tools.run_command.interactive.show_window")
    local tw_saved = package.loaded["NeoAI.ui.components.terminal_window"]
    local cv_saved = package.loaded["NeoAI.ui.window.chat_view"]
    pcall(pty.reset)

    -- 组件：每次 open 都用新的空通道（模拟 nvim_open_term），只有 feed 过才有内容
    local opens, fed = {}, {}
    package.loaded["NeoAI.ui.components.terminal_window"] = {
      open = function(session)
        opens[session.id] = true
        fed[session.id] = "" -- 新通道为空
        return { id = session.id }
      end,
      close = function(id) opens[id] = nil; fed[id] = nil end,
      is_open = function(id) return opens[id] == true end,
      feed = function(id, text) fed[id] = (fed[id] or "") .. text end,
      reset = function() opens, fed = {}, {} end,
    }
    package.loaded["NeoAI.ui.window.chat_view"] = { is_following = function() return true end }
    pty._set_force_ui(true)
    cfg.set("tools.run_command.interactive.show_window", "on_wait")

    -- 会话在窗口弹出前已有累计输出（如 on_wait 延迟期间命令已产出）
    local session = {
      id = "ptyR", window_eligible = true, output = "line-1\nline-2\n",
    }
    pty._inject_session(session)

    -- 打开：即使此前从未开过窗口，也应把累计输出重放进新通道（否则首个窗口就是空白）
    pty._restore_pending_windows()
    t.true_(opens["ptyR"] == true, "应打开窗口")
    t.matches("line%-1", fed["ptyR"] or "", "重开时应重放已有输出")

    -- 跟随→非跟随隐藏 → 非跟随→跟随重弹：新通道仍应重放全部累计输出
    pty._hide_all_windows()
    t.nil_(opens["ptyR"], "隐藏后窗口应关闭")
    pty._restore_pending_windows()
    t.true_(opens["ptyR"] == true, "重弹后窗口应重新打开")
    t.matches("line%-1", fed["ptyR"] or "", "重弹后应重放已有输出（非空白）")
    t.matches("line%-2", fed["ptyR"] or "", "重弹后应包含全部输出行")

    pty._set_force_ui(false)
    pcall(pty.reset)
    package.loaded["NeoAI.ui.components.terminal_window"] = tw_saved
    package.loaded["NeoAI.ui.window.chat_view"] = cv_saved
    cfg.set("tools.run_command.interactive.show_window", old_sw)
  end)

  it("run_command 工具描述标明可交互并含目标/操作", function(t)
    local shell = require("NeoAI.tools.builtin.shell")
    local old = config_store.get("tools.run_command.interactive.enabled")

    local function desc()
      for _, x in ipairs(shell.get_tools()) do
        if x.name == "run_command" then return x.description end
      end
      return nil
    end

    config_store.set("tools.run_command.interactive.enabled", true)
    local d_on = desc()
    t.not_nil(d_on)
    t.matches("交互式 PTY", d_on)
    t.matches("目标", d_on)
    t.matches("如何操作", d_on)
    t.matches("description", d_on)

    config_store.set("tools.run_command.interactive.enabled", false)
    local d_off = desc()
    t.not_nil(d_off)
    t.true_(d_off:find("交互式 PTY", 1, true) == nil, "非交互时不应标交互式 PTY")

    config_store.set("tools.run_command.interactive.enabled", old)
    shell.get_tools()
  end)

  it("判官决策解析：裸 JSON / 代码块 / 前后说明 / 纯文本", function(t)
    local pty = require("NeoAI.services.pty")
    local d = pty._extract_decision('{"action":"text","text":"y"}')
    t.eq("y", d and d.text)
    local d2 = pty._extract_decision('```json\n{"action":"kill"}\n```')
    t.eq("kill", d2 and d2.action)
    local d3 = pty._extract_decision('好的：{"action":"keys","keys":["Ctrl-C"]} 完成')
    t.true_(type(d3) == "table" and type(d3.keys) == "table", "应容忍前后说明")
    t.nil_(pty._extract_decision("just some text"), "纯文本无 JSON 应返回 nil")
  end)

  it("慢判官：第二轮等待在判官结束后仍被触发", function(t)
    local pty = require("NeoAI.services.pty")
    local old_enabled = config_store.get("tools.run_command.interactive.enabled")
    local old_judge = config_store.get("tools.run_command.interactive.judge.enabled")
    config_store.set("tools.run_command.interactive.enabled", true)
    config_store.set("tools.run_command.interactive.poll_ms", 40)
    config_store.set("tools.run_command.interactive.judge.enabled", true)

    local answers = { "first", "second" }
    local idx = 1
    pty.set_judge(function(session)
      local a = answers[idx]
      idx = idx + 1
      if a then
        -- 立即投递答案，但占住 judging 一段时间（模拟真实 LLM 判官仍在生成）
        pcall(pty.send_text, session.id, a)
      end
      return async.sleep(500):then_(function() return true end)
    end)

    local session = pty.open({
      argv = { "bash", "-c", "read -r a; echo GOT1:$a; read -r b; echo GOT2:$b" },
      description = "慢判官两轮",
    })
    t.not_nil(session)
    local result = t.await(pty.await(session), 20000)
    t.eq(0, result.code)
    t.matches("GOT1:first", result.output)
    t.matches("GOT2:second", result.output)

    pty.set_judge(nil)
    pcall(pty.reset)
    config_store.set("tools.run_command.interactive.enabled", old_enabled)
    config_store.set("tools.run_command.interactive.judge.enabled", old_judge)
  end)

  it("on_wait：运行超过 show_window_delay_ms 且光标跟随时才弹出", function(t)
    local pty = require("NeoAI.services.pty")
    local cfg = config_store
    local old_sw = cfg.get("tools.run_command.interactive.show_window")
    local old_delay = cfg.get("tools.run_command.interactive.show_window_delay_ms")
    local old_poll = cfg.get("tools.run_command.interactive.poll_ms")
    local tw_saved = package.loaded["NeoAI.ui.components.terminal_window"]
    local cv_saved = package.loaded["NeoAI.ui.window.chat_view"]
    pcall(pty.reset)

    local opens = {}
    package.loaded["NeoAI.ui.components.terminal_window"] = {
      open = function(session) opens[session.id] = true; return { id = session.id } end,
      close = function(id) opens[id] = nil end,
      is_open = function(id) return opens[id] == true end,
      reset = function() opens = {} end,
    }
    local following = true
    package.loaded["NeoAI.ui.window.chat_view"] = {
      is_following = function() return following end,
    }
    pty._set_force_ui(true)
    pty.set_judge(function() return async.sleep(10000) end)
    cfg.set("tools.run_command.interactive.enabled", true)
    cfg.set("tools.run_command.interactive.poll_ms", 40)
    cfg.set("tools.run_command.interactive.show_window", "on_wait")
    cfg.set("tools.run_command.interactive.show_window_delay_ms", 300)

    -- 短命令（阈值内结束）：不弹
    local short = pty.open({ argv = { "bash", "-c", "true" }, description = "短命令" })
    t.await(async.sleep(800))
    t.nil_(opens[short.id], "阈值内结束不应弹出")

    -- 长命令（运行 3s > 0.3s 阈值）且跟随：达阈值后弹出
    local long = pty.open({ argv = { "bash", "-c", "sleep 3" }, description = "长命令" })
    t.await(async.sleep(800))
    t.true_(opens[long.id] == true, "运行超过阈值且跟随时应弹出")

    -- 长命令但不跟随：不弹（用户正在回看上方）
    following = false
    local idle = pty.open({ argv = { "bash", "-c", "sleep 3" }, description = "长命令不跟随" })
    t.await(async.sleep(800))
    t.nil_(opens[idle.id], "不跟随时不应弹出")

    pty.set_judge(nil)
    pty._set_force_ui(false)
    pcall(pty.reset)
    package.loaded["NeoAI.ui.components.terminal_window"] = tw_saved
    package.loaded["NeoAI.ui.window.chat_view"] = cv_saved
    cfg.set("tools.run_command.interactive.show_window", old_sw)
    cfg.set("tools.run_command.interactive.show_window_delay_ms", old_delay)
    cfg.set("tools.run_command.interactive.poll_ms", old_poll)
  end)

  it("默认 show_window_delay_ms 为 2000", function(t)
    local default_config = require("NeoAI.default_config")
    local cfg = default_config.get_default_config()
    t.eq(2000, cfg.tools.run_command.interactive.show_window_delay_ms)
  end)

  it("引擎不可用（interactive 关闭）时 available 为假", function(t)
    local pty = require("NeoAI.services.pty")
    local old = config_store.get("tools.run_command.interactive.enabled")
    config_store.set("tools.run_command.interactive.enabled", false)
    local ok = pty.available()
    t.false_(ok)
    config_store.set("tools.run_command.interactive.enabled", old)
  end)
end)
