--- UI 组件专项测试：net_consent / sub_agent_dock / terminal_window / display_modes.chat
--- @module NeoAI.tests.test_ui_components
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
