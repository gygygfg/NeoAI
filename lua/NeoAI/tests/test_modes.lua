--- 模式化模型配置测试
--- @module NeoAI.tests.test_modes
--- 验证：ai.scenarios / ai.presets 已重构为按模式（CHAT/PLAN/AUTO）的 ai.modes，
--- agent 创建与模式切换时按当前模式应用 provider/model/temperature/max_tokens/stream。

local tests = require("NeoAI.tests")

tests.suite("modes", function(_, it)
  local function load_cfg(overrides)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load(vim.tbl_deep_extend("force", {
      ai = {
        default_provider = "deepseek",
        default_model = "auto",
        providers = {
          deepseek = { api_type = "openai", base_url = "https://api.deepseek.com", api_key = "k" },
          other = { api_type = "openai", base_url = "https://other", api_key = "k" },
        },
        modes = {
          chat = { provider = "deepseek", model = "chat-model", temperature = 0.7, max_tokens = 4096, stream = true },
          plan = { provider = "deepseek", model = "plan-model", temperature = 0.3, max_tokens = 8192, stream = true },
          auto = { provider = "other", model = "auto-model", temperature = 0.9, max_tokens = 1024, stream = true },
        },
      },
    }, overrides or {}))
  end

  it("runtime.create 按模式解析 provider/model/温度/token", function(t)
    load_cfg()
    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local a = runtime.create({ mode = "chat" })
    t.eq("chat-model", a.model)
    t.eq("deepseek", a.config.provider)
    t.eq(0.7, a.config.temperature)
    t.eq(4096, a.config.max_tokens)
    local b = runtime.create({ mode = "auto" })
    t.eq("auto-model", b.model)
    t.eq("other", b.config.provider)
    t.eq(1024, b.config.max_tokens)
  end)

  it("apply_mode 切换 provider/model 等", function(t)
    load_cfg()
    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local a = runtime.create({ mode = "chat" })
    runtime.apply_mode(a, "plan")
    t.eq("plan-model", a.model)
    t.eq(0.3, a.config.temperature)
    t.eq(8192, a.config.max_tokens)
    runtime.apply_mode(a, "auto")
    t.eq("auto-model", a.model)
    t.eq("other", a.config.provider)
    t.eq(0.9, a.config.temperature)
  end)

  it("模式缺失时回退默认 provider 与默认温度", function(t)
    load_cfg({ ai = { modes = { chat = { model = "m1" } } } })
    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local a = runtime.create({ mode = "chat" })
    t.eq("m1", a.model)
    t.eq("deepseek", a.config.provider, "provider 缺失回退 default_provider")
    t.eq(0.7, a.config.temperature)
  end)

  it("new_session 默认 CHAT 模式", function(t)
    load_cfg({ session = { save_path = "/tmp/neoai_test_modes", file = "s.jsonl" } })
    local session_store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_modes/s.jsonl")
    session_store.init()
    local agent = chat.new_session({})
    t.eq("chat-model", agent.model, "新会话默认 chat 模式模型")
  end)

  it("cycle_mode 切换时应用对应模式配置", function(t)
    load_cfg({ session = { save_path = "/tmp/neoai_test_modes2", file = "s.jsonl" } })
    local session_store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_modes2/s.jsonl")
    session_store.init()
    local agent = chat.new_session({})
    t.eq("chat-model", agent.model)
    local mode = chat.cycle_mode()
    t.eq("plan", mode)
    t.eq("plan-model", agent.model, "进入 plan 模式应用 plan 模型")
    t.eq(8192, agent.config.max_tokens)
    mode = chat.cycle_mode()
    t.eq("auto", mode)
    t.eq("auto-model", agent.model, "进入 auto 模式应用 auto 模型")
    t.eq("other", agent.config.provider)
    mode = chat.cycle_mode()
    t.eq("chat", mode)
    t.eq("chat-model", agent.model, "回到 chat 应用 chat 模型")
  end)
end)
