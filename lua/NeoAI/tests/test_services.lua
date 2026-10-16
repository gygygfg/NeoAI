--- 服务层测试
--- @module 'NeoAI.tests.test_services'

local tests = require("NeoAI.tests")

tests.suite("services", function(_, it)
  it("model_service list 分组", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "p1",
        providers = {
          p1 = { api_type = "openai", base_url = "http://x", api_key = "k" },
          p2 = { api_type = "openai", base_url = "http://y", api_key = "k" },
        },
      },
    })
    local registry = require("NeoAI.core.model.registry")
    registry.reset()
    registry.update("p1", { "m1", "m2" })
    registry.update("p2", { "m3" })
    local model_service = require("NeoAI.services.model_service")
    model_service.reset()
    model_service.list():then_(function(groups)
      t.eq(2, #groups)
      t.eq("p1", groups[1].provider)
      t.eq(2, #groups[1].models)
      print("  model list done")
    end)
  end)

  it("model_service set_active + get_active", function(t)
    local model_service = require("NeoAI.services.model_service")
    model_service.reset()
    model_service.set_active("m1", "p1")
    local active = assert(model_service.get_active())
    t.eq("m1", active.model)
    t.eq("p1", active.provider)
  end)

  it("tool_service allow_all 快捷", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local tool_service = require("NeoAI.services.tool_service")
    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool("fast_tool", "快", nil, function(_, on_success) on_success("fast") end))
    tool_service.reset()
    tool_service.set_allow_all("fast_tool", true)
    local shown = false
    tool_service.set_approval_ui({ show = function() shown = true end, hide = function() end })
    local agent = { id = "a" }
    tool_service.execute(agent, "fast_tool", { description = "测试快捷允许" }, nil, {}):then_(function(r)
      t.eq("fast", r)
      t.false_(shown) -- 未走审批
      print("  allow_all done")
    end):catch(function(e) t.true_(false, tostring(e)) end)
  end)

  it("chat_service new_session 创建会话", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1" },
      session = { save_path = "/tmp/neoai_test_svc", file = "s.jsonl" },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    chat.reset()
    session_store.reset()
    -- 清理磁盘残留
    local fs = require("NeoAI.utils.fs")
    fs.delete_file("/tmp/neoai_test_svc/s.jsonl")
    session_store.init()
    local agent = chat.new_session({})
    t.not_nil(agent.id)
    t.not_nil(chat.get_current_session_id())
    t.eq(1, session_store.count())
  end)

  it("chat_service send_message 挂载", function(t)
    -- 需要 mock HTTP，已在集成测试覆盖
    t.true_(true)
  end)

  it("chat_service load_session 载入历史", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1" },
      session = { save_path = "/tmp/neoai_test_svc2", file = "s.jsonl" },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local session_mod = require("NeoAI.core.session.session")
    local fs = require("NeoAI.utils.fs")
    local chat = require("NeoAI.services.chat_service")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_svc2/s.jsonl")
    session_store.init()
    local s = session_store.create({ metadata = { name = "已有" } })
    session_mod.add_message(s, { role = "user", content = "历史消息" })
    session_store.update(s)

    local agent = chat.load_session(s.id)
    t.not_nil(agent)
    t.eq(1, #agent.messages)
    t.eq("历史消息", agent.messages[1].content)
    t.eq(s.id, chat.get_current_session_id())
  end)

  it("chat_service load_session 载入祖先链与下游单子链", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1" },
      session = { save_path = "/tmp/neoai_test_svc3", file = "s.jsonl" },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local fs = require("NeoAI.utils.fs")
    local chat = require("NeoAI.services.chat_service")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_svc3/s.jsonl")
    session_store.init()

    local function msgs(ms)
      local out = {}
      for _, content in ipairs(ms) do
        out[#out + 1] = { role = "user", content = content }
        out[#out + 1] = { role = "assistant", content = "回复:" .. content }
      end
      return out
    end

    local a = session_store.create({ messages = msgs({ "A1", "A2" }) })
    local b = session_store.create({ parent_id = a.id, messages = msgs({ "B1", "B2" }) })
    local d = session_store.create({ parent_id = b.id, messages = msgs({ "D1" }) })
    session_store.create({ parent_id = a.id, messages = msgs({ "C1" }) })

    local chain = session_store.get_chain(b.id)
    t.eq(a.id, chain[1].id)
    t.eq(b.id, chain[2].id)

    local down = session_store.get_downstream(b.id)
    t.eq(1, #down)
    t.eq(d.id, down[1].id)
    t.eq(0, #session_store.get_downstream(d.id), "末尾无子会话应返回空")

    -- 选中 B：祖先 A 全部 + B 全部 + 下游 D 全部 = 4 + 4 + 2 = 10 条
    local agent = chat.load_session(b.id)
    t.eq(10, #agent.messages)
    t.eq(b.id, chat.get_current_session_id(), "当前会话仍为选中的 B")
    local contents = {}
    for _, m in ipairs(agent.messages) do contents[#contents + 1] = m.content end
    t.deep_eq(
      { "A1", "回复:A1", "A2", "回复:A2", "B1", "回复:B1", "B2", "回复:B2", "D1", "回复:D1" },
      contents,
      "祖先/选中/下游消息应按顺序拼接"
    )
    for _, m in ipairs(agent.messages) do
      t.eq(true, m._synced, "链上消息必须标记已同步，避免写入选中会话")
    end

    -- 选中 B 的轮次 1：B 只保留到本轮，下游仍全部 = 4 + 2 + 2 = 8 条
    chat.reset()
    agent = chat.load_session(b.id, { round = 1 })
    t.eq(8, #agent.messages)
    t.eq("B1", agent.messages[5].content)
    t.eq("D1", agent.messages[7].content)

    -- 选中根 A 且其下有分裂分支：A 全部，下游为空
    chat.reset()
    agent = chat.load_session(a.id)
    t.eq(4, #agent.messages)
    chat.reset()
    agent = chat.load_session(a.id, { round = 2 })
    t.eq(4, #agent.messages)
  end)

  it("tool_service 会话允许自动放行队列中同名工具，不再重复弹窗", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local tool_service = require("NeoAI.services.tool_service")
    local async = require("NeoAI.utils.async")
    tool_service.reset()
    local show_calls, pending = 0, nil
    tool_service.set_approval_ui({
      show = function(cfg) show_calls = show_calls + 1; pending = cfg end,
      hide = function() end,
    })
    local ctx = { agent = { id = "a" }, approval_mode = "prompt" }
    local function ok_run()
      return function()
        local d = async.Deferred.new()
        d:resolve("ok")
        return d
      end
    end
    local r1, r2
    tool_service.approve_and_execute("dup_tool", { description = "x" }, ctx, ok_run())
      :then_(function(v) r1 = v end)
    tool_service.approve_and_execute("dup_tool", { description = "x" }, ctx, ok_run())
      :then_(function(v) r2 = v end)
    t.eq(1, show_calls, "并行发起同一工具应只弹第一次（第二个入队）")
    t.not_nil(pending, "应展示审批弹窗")
    -- 用户在第一个弹窗选「允许所有（本次会话）」
    pending.on_confirm_all()
    t.true_(tool_service.get_allow_all("dup_tool"), "应置本次会话允许")
    vim.wait(1000, function() return r1 ~= nil and r2 ~= nil end)
    t.eq("ok", r1, "第一个应放行执行")
    t.eq("ok", r2, "队列中同名工具应被自动放行（不再弹窗）")
    t.eq(1, show_calls, "第二个不应再触发弹窗")
    t.false_(tool_service.has_pending_approval(), "队列应已清空")
    tool_service.reset()
    config_store.load({})
  end)

  it("tool_service 弹窗决策清除审批中心镜像条目（正向联动）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local hub = require("NeoAI.sandbox.review.approval_hub")
    hub.reset()
    hub.set_ui({ refresh = function() end })
    local tool_service = require("NeoAI.services.tool_service")
    local async = require("NeoAI.utils.async")
    tool_service.reset()
    local pending
    tool_service.set_approval_ui({ show = function(cfg) pending = cfg end, hide = function() end })
    local ctx = { agent = { id = "a" }, approval_mode = "prompt" }
    local out
    tool_service.approve_and_execute("mirror_tool", { description = "x" }, ctx, function()
      local d = async.Deferred.new(); d:resolve("ok"); return d
    end):then_(function(v) out = v end)
    t.eq(1, hub.pending_count(), "应镜像一条到审批中心")
    t.eq(1, hub.pending_count("behavior"), "工具行为页应有 1 条待批准")
    pending.on_confirm()
    t.eq(0, hub.pending_count(), "弹窗决策后镜像条目应立即清除（不再滞留待批准）")
    vim.wait(1000, function() return out ~= nil end)
    t.eq("ok", out, "应放行执行")
    tool_service.reset()
    hub.reset()
    config_store.load({})
  end)

  it("tool_service 审批中心决策反向联动关闭弹窗并结算", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local hub = require("NeoAI.sandbox.review.approval_hub")
    hub.reset()
    hub.set_ui({ refresh = function() end })
    local tool_service = require("NeoAI.services.tool_service")
    local async = require("NeoAI.utils.async")
    tool_service.reset()
    local hidden = false
    tool_service.set_approval_ui({ show = function() end, hide = function() hidden = true end })
    local ctx = { agent = { id = "a" }, approval_mode = "prompt" }
    local err
    tool_service.approve_and_execute("hub_tool", { description = "x" }, ctx, function()
      local d = async.Deferred.new(); d:resolve("ok"); return d
    end):catch(function(e) err = e end)
    local entries = hub.list("behavior")
    t.eq(1, #entries, "应有镜像条目可供悬浮窗决策")
    hub.resolve(entries[1].id, "deny")
    vim.wait(1000, function() return err ~= nil end)
    t.eq("approval", err and err.kind, "悬浮窗拒绝应以 approval 错误结算 Deferred")
    t.true_(hidden, "反向决策应关闭独立弹窗")
    t.eq(0, hub.pending_count(), "决策后条目应清除")
    -- 幂等：重复决策不应再次结算
    local again = hub.resolve(entries[1].id, "deny")
    t.false_(again, "重复决策应返回 false（幂等）")
    tool_service.reset()
    hub.reset()
    config_store.load({})
  end)
end)
