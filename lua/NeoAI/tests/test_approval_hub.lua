--- 审批分流中心（approval_hub）测试
--- @module NeoAI.tests.test_approval_hub
--- 覆盖：阻塞类条目提交/列举/决策/清理；页面计数；观测类 provider；UI 刷新回调与 open_page；
--- 决策幂等；未知页面拒绝。

local tests = require("NeoAI.tests")

tests.suite("approval_hub", function(_, it)
  it("提交/列举/决策/清理阻塞类条目", function(t)
    local hub = require("NeoAI.sandbox.approval_hub")
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

  it("clear 移除条目不触发决策回调", function(t)
    local hub = require("NeoAI.sandbox.approval_hub")
    hub.reset()
    local called = false
    local id = hub.submit("behavior", { title = "x", on_decision = function() called = true end })
    hub.clear(id)
    t.eq(0, hub.pending_count(), "clear 后应移除")
    t.false_(called, "clear 不应触发决策")
    hub.reset()
  end)

  it("未知页面被拒绝", function(t)
    local hub = require("NeoAI.sandbox.approval_hub")
    hub.reset()
    t.throws(function() hub.submit("nope", { title = "x" }) end)
    hub.reset()
  end)

  it("观测类 provider 列举与降级", function(t)
    local hub = require("NeoAI.sandbox.approval_hub")
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
    local hub = require("NeoAI.sandbox.approval_hub")
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
    local hub = require("NeoAI.sandbox.approval_hub")
    local ids = {}
    for _, p in ipairs(hub.PAGES) do ids[#ids + 1] = p.id end
    t.deep_eq({ "files", "behavior", "resource", "network", "anomaly" }, ids)
  end)
end)
