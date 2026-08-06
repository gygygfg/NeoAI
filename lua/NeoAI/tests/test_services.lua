--- 服务层测试
--- @module NeoAI.tests.test_services

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
    local active = model_service.get_active()
    t.eq("m1", active.model)
    t.eq("p1", active.provider)
  end)

  it("tool_service allow_all 快捷", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ tools = { approval = { mode = "prompt", per_tool = {} } } })
    local tool_service = require("NeoAI.services.tool_service")
    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool("fast_tool", "快", nil, function(args, on_success) on_success("fast") end))
    tool_service.reset()
    tool_service.set_allow_all("fast_tool", true)
    local shown = false
    tool_service.set_approval_ui({ show = function() shown = true end, hide = function() end })
    local agent = { id = "a" }
    tool_service.execute(agent, "fast_tool", {}, nil, {}):then_(function(r)
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
end)
