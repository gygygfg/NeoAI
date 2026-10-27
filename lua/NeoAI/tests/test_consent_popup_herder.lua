--- 同意/告警类浮窗 → Herder 状态联动端到端回归
--- @module 'NeoAI.tests.test_consent_popup_herder'
---
--- 覆盖用户报告的现象：密钥 / 网络等阻塞审批浮窗交互完成后，Herder 的 pane 状态没有回到
--- 「运行中」（停留在 `blocked`）。用**真实浮窗组件**驱动，捕获 herder 上报的 argv（不真正
--- 调用 herdr），断言 blocked 之后必然出现 working，且审批中心条目归零、Deferred 全部结算。

local tests = require("NeoAI.tests")

-- 捕获的上报 argv（覆盖 herder 的 job 运行器，避免真正调用 herdr）
local captured = {}

local function reset_herder_env()
  local orig = {
    HERDR_ENV = vim.env.HERDR_ENV,
    HERDER_BIN_PATH = vim.env.HERDER_BIN_PATH,
    HERDR_BIN_PATH = vim.env.HERDR_BIN_PATH,
    HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
    HERDR_CONFIG_PATH = vim.env.HERDR_CONFIG_PATH,
  }
  vim.env.HERDR_ENV = "1"
  vim.env.HERDER_BIN_PATH = "/usr/local/bin/herdr"
  vim.env.HERDR_BIN_PATH = "/usr/local/bin/herdr"
  vim.env.HERDR_PANE_ID = "w1:p1"
  vim.env.HERDR_CONFIG_PATH = vim.fn.tempname() .. "-neoai-consent-cfg/config.toml"
  return orig
end

local function restore_env(orig)
  vim.env.HERDR_ENV = orig.HERDR_ENV
  vim.env.HERDER_BIN_PATH = orig.HERDER_BIN_PATH
  vim.env.HERDR_BIN_PATH = orig.HERDR_BIN_PATH
  vim.env.HERDR_PANE_ID = orig.HERDR_PANE_ID
  vim.env.HERDR_CONFIG_PATH = orig.HERDR_CONFIG_PATH
end

--- 初始化 herder（关闭自动安装，捕获 argv）
local function init_herder()
  local config_store = require("NeoAI.kernel.config_store")
  config_store.load({ herder = { auto_install = false } })
  local herder = require("NeoAI.services.herder")
  herder.reset()
  captured = {}
  herder.set_job(function(argv) captured[#captured + 1] = argv end)
  herder.init()
  return herder
end

--- report-agent 的 --state 序列
local function report_states()
  local out = {}
  for _, argv in ipairs(captured) do
    if argv[3] == "report-agent" then
      for i, a in ipairs(argv) do
        if a == "--state" then out[#out + 1] = argv[i + 1] end
      end
    end
  end
  return out
end

--- 最后一个上报状态
local function last_state()
  local s = report_states()
  return s[#s]
end

--- 是否有 blocked 之后出现非 blocked（working/idle）的上报
local function recovered_after_blocked()
  local seen_blocked, recovered = false, false
  for _, st in ipairs(report_states()) do
    if st == "blocked" then seen_blocked = true
    elseif seen_blocked then recovered = true end
  end
  return seen_blocked and recovered
end

--- 伪造 attached UI（真实浮窗组件在 headless 下需要它才被视为可交互）
local function stub_ui()
  local orig = vim.api.nvim_list_uis
  vim.api.nvim_list_uis = function() return { { chan = 1 } } end
  return function() vim.api.nvim_list_uis = orig end
end

--- 当前显示的同意类浮窗（按 filetype 识别）
local CONSENT_FILETYPES = {
  neoai_net_consent = true,
  neoai_secret_alert = true,
  neoai_device_consent = true,
  neoai_policy_consent = true,
}

--- @return number[] win_ids
local function consent_windows()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and CONSENT_FILETYPES[vim.bo[buf].filetype] then
      out[#out + 1] = win
    end
  end
  return out
end

--- 当前同意浮窗的窗口 id（无则 nil）
local function consent_win()
  return consent_windows()[1]
end

--- 当前同意浮窗文本（无窗口返回 ""）
local function consent_text()
  local win = consent_win()
  if not win then return "" end
  local buf = vim.api.nvim_win_get_buf(win)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- 读取当前同意浮窗 buffer 的普通模式映射回调
local function keymap_callback(lhs)
  local win = consent_win()
  if not win then return nil end
  local buf = vim.api.nvim_win_get_buf(win)
  local map = vim.api.nvim_buf_get_keymap(buf, "n")
  for _, m in ipairs(map) do
    if m.lhs == lhs then return m.callback end
  end
  return nil
end

--- 在当前同意浮窗上按键（调用其 buffer-local 映射回调，等价于用户按该键）
local function press(lhs)
  local cb = keymap_callback(lhs)
  if not cb then return false end
  local ok = pcall(cb)
  return ok
end

--- 模拟 agent 创建并进入生成态（使 herder 接管权威、参与状态聚合）
local function start_agent(agent_id)
  local eb = require("NeoAI.kernel.event_bus")
  local ev = require("NeoAI.kernel.events")
  eb.emit(ev.AGENT_CREATED, { agent = { id = agent_id, state = "idle" } })
  eb.emit(ev.AGENT_STATE_CHANGED, { agent_id = agent_id, new = "generating" })
end

--- 重置参与本次端到端的模块
local function reset_all()
  local hub = require("NeoAI.sandbox.review.approval_hub")
  hub.set_ui(nil)
  hub.reset()
  require("NeoAI.ui.consent_slot").reset()
  -- 关闭焦点门控抑制：headless 下没有「切回 NeoAI 界面」的动作，若 focus 监听已安装且
  -- 判定为未聚焦，弹窗会一直暂存不展示（本套件要验证的是「弹窗展示 → 决策 → 状态回退」）。
  pcall(function() require("NeoAI.ui.focus").uninstall() end)
  require("NeoAI.ui.components.net_consent").reset()
  require("NeoAI.ui.components.secret_alert").reset()
  require("NeoAI.ui.components.device_consent").reset()
  require("NeoAI.ui.components.policy_consent").reset()
  require("NeoAI.sandbox.net.net_consent").reset()
  require("NeoAI.sandbox.secret.secret_alert").reset()
  require("NeoAI.sandbox").reset()
end

--- 让审批中心可用（有 refresh/open_page 即可提交条目）
local function enable_hub()
  local hub = require("NeoAI.sandbox.review.approval_hub")
  hub.set_ui({ refresh = function() end, open_page = function() end })
  return hub
end

--- 把真实浮窗组件注册为沙箱侧的同意 UI
local function wire_real_ui()
  local net = require("NeoAI.ui.components.net_consent")
  local secret = require("NeoAI.ui.components.secret_alert")
  require("NeoAI.sandbox.net.net_consent").set_ui({
    show = net.show, hide = net.hide, is_open = net.is_open,
  })
  require("NeoAI.sandbox.secret.secret_alert").set_ui({
    show = secret.show, hide = secret.hide, is_open = secret.is_open,
  })
  return net, secret
end

tests.suite("consent_popup_herder", function(_, it)
  it("密钥与网络同时到达只弹一个窗，逐个决策后 Herder 回到 working", function(t)
    local orig = reset_herder_env()
    local unrestore = stub_ui()
    reset_all()
    local herder = init_herder()
    local hub = enable_hub()
    local net, secret = wire_real_ui()
    start_agent("a1")
    t.eq("working", last_state(), "生成中应上报 working")

    -- 密钥告警 + 网络同意同时到达：单槽位串行，只展示一个浮窗
    local secret_decision, net_decision
    require("NeoAI.sandbox.secret.secret_alert")
      .request({ kind = "context", preview = "sk-FAKE-PREVIEW" }):then_(function(v) secret_decision = v end)
    require("NeoAI.sandbox.net.net_consent")
      .request({ host = "a.example", port = 1111, local_ = false }):then_(function(v) net_decision = v end)
    t.eq(1, #consent_windows(), "同一时刻只应有一个同意类浮窗（旧实现会叠两个窗）")
    t.eq("blocked", last_state(), "存在阻塞弹窗时应上报 blocked")

    -- 决策第一个（密钥）：允许本次
    t.true_(press("<CR>"), "密钥浮窗应有 <CR> 决策键")
    t.true_(vim.wait(1000, function() return secret_decision ~= nil end, 10), "密钥告警应结算")
    t.eq("allow_once", secret_decision, "密钥告警应结算为允许")
    t.eq(1, #consent_windows(), "决策后应展示排队中的网络请求（仍是单个浮窗）")
    t.eq("blocked", last_state(), "仍有待决策弹窗时保持 blocked")

    -- 决策第二个（网络）：允许本次
    t.true_(press("<CR>"), "网络浮窗应有 <CR> 决策键")
    t.true_(vim.wait(1000, function() return net_decision ~= nil end, 10), "网络请求应结算")
    t.eq("allow_once", net_decision, "网络请求应结算为允许")
    t.eq(0, #consent_windows(), "全部决策后不应残留浮窗")
    t.eq(0, hub.pending_count(), "审批中心条目应全部清空")
    t.true_(recovered_after_blocked(), "blocked 之后必须出现 working（否则 pane 停在等待确认）")
    t.eq("working", last_state(), "交互完成后应回到 working")

    -- 状态残留检查
    t.eq(0, require("NeoAI.ui.consent_slot").pending_count(), "槽位队列应为空")
    t.eq(nil, require("NeoAI.ui.consent_slot").current(), "槽位不应被占用")
    t.true_(herder.is_available(), "herder 应可用")
    t.eq("working", herder.get_state(), "聚合状态不应再停留在 blocked")

    net.reset()
    secret.reset()
    reset_all()
    herder.shutdown()
    restore_env(orig)
    unrestore()
  end)

  it("根因1 回归：一个请求超时只关自己的窗，不误关排队中的另一个请求", function(t)
    local orig = reset_herder_env()
    local unrestore = stub_ui()
    reset_all()
    local herder = init_herder()
    local config_store = require("NeoAI.kernel.config_store")
    -- 弹窗无响应超时缩短到 300ms（仅本用例；须在 init_herder 之后 load，避免被其覆盖）
    config_store.load({
      herder = { auto_install = false },
      tools = { sandbox = { network = { consent_timeout_ms = 300 } } },
    })
    local hub = enable_hub()
    local net = wire_real_ui()
    start_agent("a2")

    local dec_a, dec_b
    local nc = require("NeoAI.sandbox.net.net_consent")
    nc.request({ host = "first.example", port = 2222, local_ = false }):then_(function(v) dec_a = v end)
    nc.request({ host = "second.example", port = 3333, local_ = false }):then_(function(v) dec_b = v end)
    t.eq(1, #consent_windows(), "第二个请求应排队而不是叠窗")
    t.matches("first%.example:2222", consent_text(), "先展示第一个请求的浮窗")

    -- 等第一个请求超时自动拒绝（fail-closed）
    t.true_(vim.wait(3000, function() return dec_a ~= nil end, 10), "第一个请求应超时结算")
    t.eq("deny", dec_a, "超时应自动拒绝")
    -- 关键：第二个请求的窗口不能被上一步的 hide 误关，且它自己仍在等待用户
    t.eq(nil, dec_b, "第二个请求不应被误结算")
    t.eq(1, #consent_windows(), "第一个超时后应展示第二个请求的浮窗")
    t.matches("second%.example:3333", consent_text(), "当前浮窗应是第二个请求的")

    -- 用户回答第二个请求：应正常放行（旧实现此时窗口已被误关、Deferred 永挂）
    t.true_(press("<CR>"), "第二个浮窗应可决策")
    t.true_(vim.wait(1000, function() return dec_b ~= nil end, 10), "第二个请求应结算")
    t.eq("allow_once", dec_b, "第二个请求应结算为允许")
    t.eq(0, hub.pending_count("network"), "网络页条目应清空")
    t.true_(recovered_after_blocked(), "blocked 之后必须出现 working")
    t.eq("working", last_state(), "全部结算后应回到 working")

    net.reset()
    reset_all()
    herder.shutdown()
    restore_env(orig)
    unrestore()
  end)

  it("外部关窗（:q / <C-w>c）：按安全默认拒绝结算并让 Herder 回到 working", function(t)
    local orig = reset_herder_env()
    local unrestore = stub_ui()
    reset_all()
    local herder = init_herder()
    local hub = enable_hub()
    local net = wire_real_ui()
    start_agent("a3")

    local decision
    require("NeoAI.sandbox.net.net_consent")
      .request({ host = "close.example", port = 4444, local_ = false }):then_(function(v) decision = v end)
    local win = consent_win()
    t.not_nil(win, "应已展示浮动窗口")
    t.eq("blocked", last_state(), "等待确认时应上报 blocked")

    -- 模拟用户用 :q 关掉浮窗（外部关窗，不走按键决策）
    vim.api.nvim_win_close(win, true)
    t.true_(vim.wait(2000, function() return decision ~= nil end, 10), "外部关窗应按安全默认结算")
    t.eq("deny", decision, "外部关窗应视为拒绝（安全默认）")
    t.eq(0, hub.pending_count("network"), "审批中心条目应被清理")
    t.eq(0, #consent_windows(), "不应残留浮窗")
    t.true_(recovered_after_blocked(), "blocked 之后必须出现 working")
    t.eq("working", last_state(), "外部关窗后也应回到 working")

    net.reset()
    reset_all()
    herder.shutdown()
    restore_env(orig)
    unrestore()
  end)
end)
