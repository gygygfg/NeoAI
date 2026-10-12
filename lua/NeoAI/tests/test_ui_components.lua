--- UI 组件专项测试：net_consent / sub_agent_dock / terminal_window / display_modes.chat
--- @module 'NeoAI.tests.test_ui_components'
local tests = require("NeoAI.tests")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

tests.suite("ui_components", function(_, it)
  local function win_title(w)
    local cfg = vim.api.nvim_win_get_config(w)
    local title = cfg.title
    if type(title) == "string" then return title end
    if type(title) == "table" then
      local parts = {}
      for _, chunk in ipairs(title) do
        if type(chunk) == "string" then parts[#parts + 1] = chunk
        elseif type(chunk) == "table" then parts[#parts + 1] = tostring(chunk[1] or "") end
      end
      return table.concat(parts)
    end
    return nil
  end

  local function find_win_by_title(title)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" and win_title(w) == title then return w end
    end
    return nil
  end

  it("mason_hl：存在 Mason 高亮组时链接复用，否则用兜底配色", function(t)
    local m = require("NeoAI.ui.mason_hl")
    -- 定义假 Mason 组
    vim.api.nvim_set_hl(0, "MasonHeader", { fg = "#123456", bg = "#abcdef", bold = true })
    vim.api.nvim_set_hl(0, "NeoAITestLinkTarget", {})
    m.def("NeoAITestLinkTarget", "MasonHeader", { fg = "#ffffff" })
    local hl = vim.api.nvim_get_hl(0, { name = "NeoAITestLinkTarget", link = false })
    t.eq("#123456", hl.fg and string.format("#%06x", hl.fg) or hl.fg, "应链接 MasonHeader 的 fg")
    -- 不存在时用兜底
    m.def("NeoAITestFallback", "MasonNotExistXYZ", { fg = "#ff0000", bold = true })
    local hl2 = vim.api.nvim_get_hl(0, { name = "NeoAITestFallback", link = false })
    t.eq("#ff0000", hl2.fg and string.format("#%06x", hl2.fg) or hl2.fg, "应使用兜底 fg")
    t.true_(hl2.bold == true, "应 bold")
    -- 清理
    vim.api.nvim_set_hl(0, "MasonHeader", {})
    vim.api.nvim_set_hl(0, "NeoAITestLinkTarget", {})
    vim.api.nvim_set_hl(0, "NeoAITestFallback", {})
  end)

  it("focus：识别并广播 NeoAI 界面焦点跳变", function(t)
    local focus = require("NeoAI.ui.focus")
    focus.reset()
    focus._set_force_ui(true) -- headless 下模拟 attached UI，使焦点语义生效
    local seen = {}
    local unsub = event_bus.on(events.UI_FOCUS_CHANGED, function(p) seen[#seen + 1] = p.focused end)
    focus.install()
    -- 普通 buffer → 未聚焦
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(plain)
    focus.refresh()
    t.false_(focus.is_focused(), "普通缓冲区应视为未聚焦")
    -- NeoAI 界面 buffer → 聚焦
    local neo = vim.api.nvim_create_buf(false, true)
    vim.bo[neo].filetype = "neoai_sandbox_review"
    vim.api.nvim_set_current_buf(neo)
    focus.refresh()
    t.true_(focus.is_focused(), "NeoAI 界面缓冲区应视为聚焦")
    t.true_(#seen >= 1, "焦点变化应广播 UI_FOCUS_CHANGED")
    vim.api.nvim_buf_delete(plain, { force = true })
    vim.api.nvim_buf_delete(neo, { force = true })
    unsub()
    focus.reset()
  end)

  it("ask_user：应用有焦点即弹（不受当前窗口是否 NeoAI 界面影响），仅失焦时暂存", function(t)
    local au = require("NeoAI.ui.components.ask_user")
    local focus = require("NeoAI.ui.focus")
    local function show()
      au.show({
        batch_id = "ui_components_focus",
        questions = { { question = "Q?", options = { "A" }, multi_select = false } },
        active = 1,
        mode = "tab",
        require_confirm = true,
        on_submit = function() end,
        on_cancel = function() end,
      })
    end
    au.reset()
    focus.reset()
    focus._set_force_ui(true) -- headless 下模拟 attached UI，使焦点门控生效
    focus.install()
    -- 当前为普通 buffer（非 NeoAI 界面），但应用仍有焦点
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(plain)
    focus.refresh()
    t.false_(focus.is_focused(), "普通缓冲区 is_focused 仍为 false")
    show()
    t.not_nil(au.get_buf(), "应用有焦点时应立即弹窗（不再因窗口非 NeoAI 而延迟）")
    t.false_(au.has_deferred(), "应用有焦点时不应暂存")
    au.reset()
    -- 应用失焦 → 暂存待展示
    focus._set_app_focused(false)
    show()
    t.nil_(au.get_buf(), "应用失焦时不应建窗")
    t.true_(au.has_deferred(), "应用失焦时应暂存待展示")
    -- 恢复焦点（切回/回焦）：广播聚焦 → 真正弹出
    focus._set_app_focused(true)
    event_bus.emit(events.UI_FOCUS_CHANGED, { focused = true })
    t.not_nil(au.get_buf(), "回焦后应弹出提问窗")
    t.false_(au.has_deferred(), "弹出后应清除暂存")
    vim.api.nvim_buf_delete(plain, { force = true })
    au.reset()
    focus.reset()
  end)

  it("tool_approval：聊天界面在前台即弹，否则暂存（切回再弹）", function(t)
    local ta = require("NeoAI.ui.components.tool_approval")
    local focus = require("NeoAI.ui.focus")
    ta.reset()
    focus.reset()
    focus._set_force_ui(true)
    focus.install()
    -- NeoAI 界面在前台：立即弹出
    local nbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[nbuf].filetype = "neoai_input"
    vim.api.nvim_set_current_buf(nbuf)
    focus.refresh()
    ta.show({ text = "工具: run_command", tool_name = "run_command",
      on_confirm = function() end, on_cancel = function() end })
    t.not_nil(find_win_by_title("🔒 工具审批: run_command"), "NeoAI 界面在前台应立即可弹")
    ta.reset()
    -- 切到非 NeoAI 窗口：暂存
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(plain)
    focus.refresh()
    ta.show({ text = "工具: run_command", tool_name = "run_command",
      on_confirm = function() end, on_cancel = function() end })
    t.nil_(find_win_by_title("🔒 工具审批: run_command"), "非 NeoAI 窗口时应暂存")
    -- 切回 NeoAI 界面：弹出
    event_bus.emit(events.UI_FOCUS_CHANGED, { focused = true })
    t.not_nil(find_win_by_title("🔒 工具审批: run_command"), "切回后应弹出审批窗")
    vim.api.nvim_buf_delete(plain, { force = true })
    vim.api.nvim_buf_delete(nbuf, { force = true })
    ta.reset()
    focus.reset()
  end)

  it("net_consent：聊天界面在前台即弹，否则暂存（切回再弹）", function(t)
    local nc = require("NeoAI.ui.components.net_consent")
    local focus = require("NeoAI.ui.focus")
    nc.reset()
    focus.reset()
    focus._set_force_ui(true)
    focus.install()
    local nbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[nbuf].filetype = "neoai_input"
    vim.api.nvim_set_current_buf(nbuf)
    focus.refresh()
    nc.show({ host = "example.com", port = 443 }, function() end)
    t.not_nil(find_win_by_title("🌐 沙箱网络访问"), "NeoAI 界面在前台应立即可弹")
    nc.reset()
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(plain)
    focus.refresh()
    nc.show({ host = "example.com", port = 443 }, function() end)
    t.nil_(find_win_by_title("🌐 沙箱网络访问"), "非 NeoAI 窗口时应暂存")
    event_bus.emit(events.UI_FOCUS_CHANGED, { focused = true })
    t.not_nil(find_win_by_title("🌐 沙箱网络访问"), "切回后应弹出网络同意窗")
    vim.api.nvim_buf_delete(plain, { force = true })
    vim.api.nvim_buf_delete(nbuf, { force = true })
    nc.reset()
    focus.reset()
  end)

  it("secret_alert：焦点不在 NeoAI 界面时延迟弹出，切回后弹出", function(t)
    local sa = require("NeoAI.ui.components.secret_alert")
    local focus = require("NeoAI.ui.focus")
    sa.reset()
    focus.reset()
    focus._set_force_ui(true)
    focus.install()
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(plain)
    focus.refresh()
    sa.show({ kind = "tool", tool = "run_command", secret = "sk-REAL" }, function() end)
    t.nil_(find_win_by_title("🔑 密钥告警"), "未聚焦时不应建窗")
    event_bus.emit(events.UI_FOCUS_CHANGED, { focused = true })
    t.not_nil(find_win_by_title("🔑 密钥告警"), "切回后应弹出密钥告警窗")
    vim.api.nvim_buf_delete(plain, { force = true })
    sa.reset()
    focus.reset()
  end)

  it("net_consent：show 打开弹窗、hide 关闭", function(t)
    local nc = require("NeoAI.ui.components.net_consent")
    nc.reset()
    nc.show({ host = "example.com", port = 443, local_ = false, proto = "tcp" }, function() end)
    local win = find_win_by_title("🌐 沙箱网络访问")
    t.not_nil(win, "应打开同意弹窗")
    if win then
      local buf = vim.api.nvim_win_get_buf(win)
      t.eq("neoai_net_consent", vim.bo[buf].filetype)
      t.eq(false, vim.bo[buf].modifiable, "弹窗内容应只读")
    end
    nc.hide()
    t.nil_(find_win_by_title("🌐 沙箱网络访问"), "hide 应关闭弹窗")
    nc.reset()
  end)

  it("net_consent：回车确认回调 allow_once", function(t)
    local nc = require("NeoAI.ui.components.net_consent")
    nc.reset()
    local decision
    nc.show({ host = "h", port = 1 }, function(d) decision = d end)
    local win = find_win_by_title("🌐 沙箱网络访问")
    t.not_nil(win)
    local buf = vim.api.nvim_win_get_buf(win)
    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "<CR>" then cb = m.callback end
    end
    t.not_nil(cb, "应注册 <CR> 回调")
    if cb then cb() end
    t.eq("allow_once", decision)
    t.nil_(find_win_by_title("🌐 沙箱网络访问"), "确认后应关闭")
    nc.reset()
  end)

  it("device_consent：聊天界面在前台即弹，否则暂存（切回再弹）", function(t)
    local dc = require("NeoAI.ui.components.device_consent")
    local focus = require("NeoAI.ui.focus")
    dc.reset()
    focus.reset()
    focus._set_force_ui(true)
    focus.install()
    local nbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[nbuf].filetype = "neoai_input"
    vim.api.nvim_set_current_buf(nbuf)
    focus.refresh()
    dc.show({ devices = { "/dev/kvm" } }, function() end)
    t.not_nil(find_win_by_title("🔌 沙箱设备访问"), "NeoAI 界面在前台应立即可弹")
    dc.reset()
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(plain)
    focus.refresh()
    dc.show({ devices = { "/dev/kvm" } }, function() end)
    t.nil_(find_win_by_title("🔌 沙箱设备访问"), "非 NeoAI 窗口时应暂存")
    event_bus.emit(events.UI_FOCUS_CHANGED, { focused = true })
    t.not_nil(find_win_by_title("🔌 沙箱设备访问"), "切回后应弹出设备同意窗")
    vim.api.nvim_buf_delete(plain, { force = true })
    vim.api.nvim_buf_delete(nbuf, { force = true })
    dc.reset()
    focus.reset()
  end)

  it("device_consent：show/hide 与 <CR> 回调 allow_once", function(t)
    local dc = require("NeoAI.ui.components.device_consent")
    dc.reset()
    local decision
    dc.show({ devices = { "/dev/kvm", "/dev/net/tun" } }, function(d) decision = d end)
    local win = find_win_by_title("🔌 沙箱设备访问")
    t.not_nil(win, "应打开设备同意弹窗")
    if win then
      local buf = vim.api.nvim_win_get_buf(win)
      t.eq("neoai_device_consent", vim.bo[buf].filetype)
      t.eq(false, vim.bo[buf].modifiable, "弹窗内容应只读")
      local cb
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == "<CR>" then cb = m.callback end
      end
      t.not_nil(cb, "应注册 <CR> 回调")
      if cb then cb() end
      t.eq("allow_once", decision)
      t.nil_(find_win_by_title("🔌 沙箱设备访问"), "确认后应关闭")
    end
    dc.show({ devices = { "/dev/kvm" } }, function() end)
    t.not_nil(find_win_by_title("🔌 沙箱设备访问"))
    dc.hide()
    t.nil_(find_win_by_title("🔌 沙箱设备访问"), "hide 应关闭弹窗")
    dc.reset()
  end)

  it("policy_consent：聊天界面在前台即弹 + show/hide 与 <CR> 回调", function(t)
    local pc = require("NeoAI.ui.components.policy_consent")
    local focus = require("NeoAI.ui.focus")
    pc.reset()
    focus.reset()
    focus._set_force_ui(true)
    focus.install()
    local nbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[nbuf].filetype = "neoai_input"
    vim.api.nvim_set_current_buf(nbuf)
    focus.refresh()
    local decision
    pc.show({
      title = "代理规避确认：命令清除/绕过代理，将绕过宿主本机访问过滤。是否允许？",
      detail = { "触发原因: PROXY_EVASION:unset", "工具: web_fetch", "目标: https://example.com/中文", "命令: unset http_proxy; 中文命令" },
    }, function(d) decision = d end)
    local win = find_win_by_title("⚠ 沙箱策略确认")
    t.not_nil(win, "NeoAI 界面在前台应立即可弹")
    if win then
      local buf = vim.api.nvim_win_get_buf(win)
      t.eq("neoai_policy_consent", vim.bo[buf].filetype)
      t.eq(false, vim.bo[buf].modifiable, "弹窗内容应只读")
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      t.matches("工具: web_fetch", text, "应展示工具")
      t.matches("目标: https://example.com/中文", text, "应展示目标且中文不乱码")
      t.matches("命令: unset http_proxy", text, "应展示命令")
      -- UTF-8 完整性：不应出现被字节切分的乱码（乱码字符在 nvim 中表现为无效字节）
      t.true_(vim.fn.strchars(text) > 0, "内容应为有效 UTF-8")
      t.true_(text:find("<e5>", 1, true) == nil, "不应有被切分的 UTF-8 字节")
      local cb
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == "<CR>" then cb = m.callback end
      end
      t.not_nil(cb, "应注册 <CR> 回调")
      if cb then cb() end
      t.eq("allow_once", decision)
      t.nil_(find_win_by_title("⚠ 沙箱策略确认"), "确认后应关闭")
    end
    -- 切到非 NeoAI 窗口：暂存；切回：弹出
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(plain)
    focus.refresh()
    pc.show({ title = "t" }, function() end)
    t.nil_(find_win_by_title("⚠ 沙箱策略确认"), "非 NeoAI 窗口时应暂存")
    event_bus.emit(events.UI_FOCUS_CHANGED, { focused = true })
    t.not_nil(find_win_by_title("⚠ 沙箱策略确认"), "切回后应弹出策略确认窗")
    pc.hide()
    t.nil_(find_win_by_title("⚠ 沙箱策略确认"), "hide 应关闭弹窗")
    vim.api.nvim_buf_delete(plain, { force = true })
    vim.api.nvim_buf_delete(nbuf, { force = true })
    pc.reset()
    focus.reset()
  end)

  it("sub_agent_dock：open 渲染、事件更新、reset 清理", function(t)
    local dock = require("NeoAI.ui.components.sub_agent_dock")
    dock.reset()
    dock.open()
    dock.init()
    local win = find_win_by_title("子 Agent")
    t.not_nil(win, "应打开监控面板")
    local buf = vim.api.nvim_win_get_buf(win)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("无运行中的子 Agent", text)
    event_bus.emit(events.SUB_AGENT_CREATED, { sub_agent_id = "sa1", task = "扫描代码" })
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("sa1", text)
    t.matches("扫描代码", text)
    event_bus.emit(events.SUB_AGENT_COMPLETED, { sub_agent_id = "sa1" })
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.matches("completed", text)
    dock.reset()
    t.nil_(find_win_by_title("子 Agent"), "reset 应关闭面板")
  end)

  it("sub_agent_list：打开/渲染/进入/reset", function(t)
    local sub_agent_list = require("NeoAI.ui.components.sub_agent_list")
    local manager = require("NeoAI.core.agent.sub_agent")
    local chat_service = require("NeoAI.services.chat_service")
    sub_agent_list.reset()
    manager.reset()

    -- 造一个聊天主窗口（filetype=neoai）作为定位基准
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "neoai"
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    local orig = chat_service.get_agent_for_buffer
    ---@diagnostic disable-next-line: duplicate-set-field
    chat_service.get_agent_for_buffer = function() return { id = "agentX" } end
    manager._inject_for_test("sx", { parent_agent_id = "agentX", name = "探测器", session_id = "sess_sx" })

    local w = sub_agent_list.open()
    t.not_nil(w, "应打开列表浮窗")
    t.true_(sub_agent_list.is_open())
    local lb = vim.api.nvim_win_get_buf(w)
    local text = table.concat(vim.api.nvim_buf_get_lines(lb, 0, -1, false), "\n")
    t.matches("探测器", text)

    sub_agent_list.close()
    t.false_(sub_agent_list.is_open())

    chat_service.get_agent_for_buffer = orig
    manager.reset()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("terminal_window：headless 无 UI 时为安全 no-op", function(t)
    local tw = require("NeoAI.ui.components.terminal_window")
    tw.reset()
    t.nil_(tw.open({ id = "s1" }, "t"), "无 UI 时 open 返回 nil")
    t.eq(0, tw.count())
    t.false_(tw.is_open("s1"))
    local ok = pcall(function()
      tw.feed("s1", "data")
      tw.set_title("s1", "x")
      tw.close("s1")
      tw.close_all()
    end)
    t.true_(ok, "无 UI 时各接口不应抛错")
    tw.reset()
  end)

  it("terminal_window：折叠几何贴右上角，展开/折叠可切换", function(t)
    local tw = require("NeoAI.ui.components.terminal_window")
    tw.reset()
    local cols, lines = vim.o.columns, vim.o.lines
    local g = tw._collapsed_geom()
    local exp_w = math.max(8, math.min(30, cols - 4))
    t.eq(exp_w, g.width, "折叠宽应为 min(30, cols-4) 且不少于 8")
    t.eq(math.min(3, lines), g.height, "折叠高应为 3（受屏高约束）")
    t.eq(math.max(0, cols - exp_w - 2), g.col, "折叠列应贴右（cols-width-2）")
    t.eq(math.max(0, math.min(2, lines - g.height)), g.row, "折叠行应为 2（带上界兜底）")

    tw._set_force_ui(true)
    local handle = assert(tw.open({ id = "s1" }, "T1"))
    t.not_nil(handle, "有 UI 时 open 应返回句柄")
    t.true_(tw.is_collapsed("s1"), "open 应默认折叠（缩在右上角）")
    local cfg = vim.api.nvim_win_get_config(handle.win)
    t.eq(g.width, cfg.width, "开窗应为折叠宽")
    t.eq(g.height, cfg.height, "开窗应为折叠高")
    t.eq(g.col, cfg.col, "开窗应在右上角（列）")
    t.eq(g.row, cfg.row, "开窗应在右上角（行）")

    tw.expand("s1")
    t.false_(tw.is_collapsed("s1"), "expand 后应展开")
    local ce = vim.api.nvim_win_get_config(handle.win)
    t.true_(ce.width > g.width, "展开应比折叠更宽")

    tw.collapse("s1")
    t.true_(tw.is_collapsed("s1"), "collapse 后应折叠")
    local cc = vim.api.nvim_win_get_config(handle.win)
    t.eq(g.width, cc.width, "折叠应回到右上角小窗宽")
    tw.reset()
  end)

  it("terminal_window：焦点进入展开、移出折叠（WinEnter 联动）", function(t)
    local tw = require("NeoAI.ui.components.terminal_window")
    tw.reset()
    tw._set_force_ui(true)
    local handle = assert(tw.open({ id = "s1" }, "T1"))
    t.not_nil(handle)
    t.true_(tw.is_collapsed("s1"), "初始应折叠")
    local orig = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(handle.win) -- WinEnter（终端窗）→ 展开
    t.false_(tw.is_collapsed("s1"), "焦点进入终端窗应展开")
    vim.api.nvim_set_current_win(orig) -- WinEnter（非终端窗）→ 折叠其余终端窗
    t.true_(tw.is_collapsed("s1"), "焦点移出应折叠")
    tw.reset()
  end)

  it("display_modes.chat：注册、load/unload 调用 host", function(t)
    local manager = require("NeoAI.ui.components.display_modes")
    manager.reset()
    local chat = require("NeoAI.ui.components.display_modes.chat")
    t.eq("chat", chat.name)
    t.not_nil(manager.get("chat"), "chat 模式应可获取")
    local calls = {}
    local host = {
      set_foldexpr = function(v) calls.fold = v end,
      set_foldtext = function(v) calls.text = v end,
    }
    chat.load(host)
    t.true_(calls.fold == nil and calls.text == nil, "load 应清除折叠覆盖并已调用 host")
    calls = {}
    chat.unload(host)
    t.true_(calls.fold == nil and calls.text == nil, "unload 应清除折叠覆盖并已调用 host")
    manager.reset()
  end)

  it("display_modes.chat：render 委托 message_list（空消息安全）", function(t)
    local chat = require("NeoAI.ui.components.display_modes.chat")
    local buf = vim.api.nvim_create_buf(false, true)
    local ok = pcall(chat.render, buf, {}, nil)
    t.true_(ok, "render 空消息不应抛错")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
