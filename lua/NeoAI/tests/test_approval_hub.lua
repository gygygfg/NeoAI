--- 审批分流中心（approval_hub）测试
--- @module 'NeoAI.tests.test_approval_hub'
--- 覆盖：阻塞类条目提交/列举/决策/清理；页面计数；观测类 provider；UI 刷新回调与 open_page；
--- 决策幂等；未知页面拒绝。

local tests = require("NeoAI.tests")

tests.suite("approval_hub", function(_, it)
  it("提交/列举/决策/清理阻塞类条目", function(t)
    local hub = require("NeoAI.sandbox.review.approval_hub")
    hub.reset()
    local decisions = {}
    local id = hub.submit("network", {
      title = "127.0.0.1:9999",
      detail = { "服务: mockd (pid 42)" },
      on_decision = function(v) decisions[#decisions + 1] = v end,
    })
    t.not_nil(id, "应返回条目 id")
    local list = hub.list("network")
    t.eq(1, #list, "应列举 1 条")
    t.eq("127.0.0.1:9999", list[1].title)
    t.eq(1, hub.pending_count("network"))
    t.eq(1, hub.pending_count())
    t.true_(hub.resolve(id, "allow_once"), "决策应命中条目")
    t.eq("allow_once", decisions[1], "on_decision 应收到决策值")
    t.eq(0, hub.pending_count("network"), "决策后应移除")
    t.false_(hub.resolve(id, "deny"), "重复决策应返回 false")
    t.eq(1, #decisions, "重复决策不应再次回调")
    hub.reset()
  end)

  it("dedupe_key：同键在途条目合并，一次决策回调全部", function(t)
    local hub = require("NeoAI.sandbox.review.approval_hub")
    hub.reset()
    local got = {}
    local id1 = hub.submit("network", { title = "a", dedupe_key = "k1",
      on_decision = function(v) got[1] = v end })
    local id2 = hub.submit("network", { title = "a", dedupe_key = "k1",
      on_decision = function(v) got[2] = v end })
    t.eq(id1, id2, "同页同键应复用同一 id")
    t.eq(1, hub.pending_count("network"), "只保留一条待处理")
    t.eq(2, hub.list("network")[1].count, "计数应累加")
    -- 不同键 / 不同页不合并
    local other = hub.submit("network", { title = "b", dedupe_key = "k2" })
    t.true_(other ~= id1, "不同键应新建")
    hub.submit("behavior", { title = "c", dedupe_key = "k1" })
    t.eq(2, hub.pending_count("network"), "跨页不合并")
    t.true_(hub.resolve(id1, "allow_once"), "应能决策合并条目")
    t.eq("allow_once", got[1], "第 1 个决策者应回调")
    t.eq("allow_once", got[2], "合并的决策者均应回调")
    t.eq(0, hub.get(id1) and 1 or 0, "决策后条目应移除")
    -- 已结算后同键再次提交应新建
    local id3 = hub.submit("network", { title = "a", dedupe_key = "k1" })
    t.true_(id3 ~= id1, "已结算后同键应新建条目")
    hub.reset()
  end)

  it("clear 移除条目不触发决策回调", function(t)
    local hub = require("NeoAI.sandbox.review.approval_hub")
    hub.reset()
    local called = false
    local id = hub.submit("behavior", { title = "x", on_decision = function() called = true end })
    hub.clear(id)
    t.eq(0, hub.pending_count(), "clear 后应移除")
    t.false_(called, "clear 不应触发决策")
    hub.reset()
  end)

  it("未知页面被拒绝", function(t)
    local hub = require("NeoAI.sandbox.review.approval_hub")
    hub.reset()
    t.throws(function() hub.submit("nope", { title = "x" }) end)
    hub.reset()
  end)

  it("阻塞审批条目广播 opened/closed（Herder blocked 联动）", function(t)
    local hub = require("NeoAI.sandbox.review.approval_hub")
    local eb = require("NeoAI.kernel.event_bus")
    local ev = require("NeoAI.kernel.events")
    hub.reset()
    local opened, closed = {}, {}
    local u1 = eb.on(ev.SANDBOX_APPROVAL_BLOCKING_OPENED, function(d) opened[#opened + 1] = d end)
    local u2 = eb.on(ev.SANDBOX_APPROVAL_BLOCKING_CLOSED, function(d) closed[#closed + 1] = d end)

    local id = hub.submit("network", { title = "example.com:443" })
    t.eq(1, #opened, "阻塞条目提交应广播 opened")
    t.eq(id, opened[1].id)
    t.eq("network", opened[1].page)
    hub.resolve(id, "allow_once")
    t.eq(1, #closed, "决策后应广播 closed")
    t.eq(id, closed[1].id)

    local id2 = hub.submit("behavior", { title = "secret" })
    hub.clear(id2)
    t.eq(2, #closed, "clear 也应广播 closed")

    u1(); u2()
    hub.reset()
  end)

  it("观测类 provider 列举与降级", function(t)
    local hub = require("NeoAI.sandbox.review.approval_hub")
    hub.reset()
    hub.register_provider("anomaly", function() return { { a = 1 }, { b = 2 } } end)
    t.eq(2, #hub.observe("anomaly"), "应返回 provider 结果")
    hub.register_provider("anomaly", function() error("boom") end)
    t.eq(0, #hub.observe("anomaly"), "provider 出错应降级为空")
    hub.register_provider("anomaly", nil)
    t.eq(0, #hub.observe("anomaly"), "无 provider 应为空")
    hub.reset()
  end)

  it("UI 刷新回调与 open_page", function(t)
    local hub = require("NeoAI.sandbox.review.approval_hub")
    hub.reset()
    local refreshes, opened = 0, nil
    hub.set_ui({
      refresh = function() refreshes = refreshes + 1 end,
      open_page = function(page) opened = page end,
    })
    t.true_(hub.available(), "注册后应可用")
    hub.submit("resource", { title = "t" })
    t.true_(refreshes >= 1, "提交应触发刷新")
    hub.open_page("network")
    t.eq("network", opened, "open_page 应转发页面")
    hub.set_ui(nil)
    t.false_(hub.available(), "注销后不可用")
    hub.reset()
  end)

  it("PAGES 顺序与页面 id 稳定", function(t)
    local hub = require("NeoAI.sandbox.review.approval_hub")
    local ids = {}
    for _, p in ipairs(hub.PAGES) do ids[#ids + 1] = p.id end
    t.deep_eq({ "files", "behavior", "resource", "network", "anomaly" }, ids)
  end)

  it("统一运行时请求事件：consent.emit 按 page 区分广播", function(t)
    local bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local got = {}
    local un = bus.on(events.SANDBOX_CONSENT_REQUESTED, function(p) got[#got + 1] = p end)
    local consent = require("NeoAI.sandbox.review.consent")
    consent.emit("network", { host = "h", port = 1 })
    consent.emit("behavior", { kind = "device" })
    consent.emit("resource", { tool = "read_file" })
    un()
    t.eq(3, #got, "应广播 3 次（同一事件）")
    t.eq("network", got[1].page)
    t.eq("h", got[1].host)
    t.eq("behavior", got[2].page)
    t.eq("device", got[2].kind)
    t.eq("resource", got[3].page)
    t.eq("read_file", got[3].tool)
  end)

  it("三类请求模块广播同一事件且 page 正确（network/behavior）", function(t)
    local bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local hub = require("NeoAI.sandbox.review.approval_hub")
    local orig_uis = vim.api.nvim_list_uis
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_list_uis = function() return { {} } end
    hub.reset()
    hub.set_ui({ refresh = function() end })
    local pages = {}
    local un = bus.on(events.SANDBOX_CONSENT_REQUESTED, function(p) pages[#pages + 1] = p.page end)
    -- 危险设备访问（behavior）
    local dc = require("NeoAI.sandbox.review.device_consent")
    dc.reset()
    dc.set_ui({ show = function() end })
    dc.request({ "/dev/kvm" })
    -- 代理规避/策略确认（behavior）
    local pc = require("NeoAI.sandbox.review.policy_consent")
    pc.reset()
    pc.set_ui({ show = function() end })
    pc.request("proxy_evasion", { title = "t" })
    -- 网络请求（network）
    local nc = require("NeoAI.sandbox.net.net_consent")
    nc.reset()
    nc.set_ui({ show = function() end })
    nc.request({ host = "example.com", port = 443, local_ = false, proto = "tcp" })
    un()
    t.true_(vim.tbl_contains(pages, "behavior"), "设备/策略应广播 behavior")
    t.true_(vim.tbl_contains(pages, "network"), "网络同意应广播 network")
    nc.reset()
    pc.reset()
    dc.reset()
    hub.set_ui(nil)
    hub.reset()
    vim.api.nvim_list_uis = orig_uis
  end)
end)
