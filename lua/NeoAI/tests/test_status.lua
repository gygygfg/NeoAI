--- 状态栏服务测试
--- @module NeoAI.tests.test_status

local tests = require("NeoAI.tests")

tests.suite("status", function(_, it)
  local function init_chat()
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "deepseek",
        default_model = "m9",
        context_cache = { context_window = 64000 },
      },
      session = { save_path = "/tmp/neoai_test_status", file = "s.jsonl" },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_status/s.jsonl")
    session_store.init()
    return chat
  end

  it("无 Agent 时 get_info available=false 且 component 为空", function(t)
    init_chat()
    local status = require("NeoAI.services.status")
    status.setup(nil)
    local info = status.get_info()
    t.false_(info.available)
    t.eq("chat", info.mode)
    t.eq("", status.component(), "无激活 Agent 且默认模式时不应输出")
  end)

  it("有 Agent 时 get_info 汇总 usage/cache/容量", function(t)
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    status.setup(nil)
    local agent = chat.new_session({})
    agent.model = "deepseek-v4-flash"
    agent.usage = {
      prompt = 30000, completion = 5000,
      cache_read = 25000, cache_miss = 5000,
      requests = 3, prompt_cache_total = 25000, prompt_total = 30000,
      cache_ratio = 25000 / 30000,
    }
    agent.messages = {}
    local agent_mod = require("NeoAI.core.agent.agent")
    agent_mod.add_message(agent, "user", string.rep("a", 4000))

    local info = status.get_info()
    t.true_(info.available)
    t.eq("deepseek-v4-flash", info.model)
    t.eq(30000, info.usage.prompt)
    t.eq(5000, info.usage.completion)
    t.eq(25000, info.usage.cache_read)
    local ratio_ok = math.abs(info.usage.cache_ratio - (25000 / 30000)) < 1e-6
    t.true_(ratio_ok, "缓存命中率")
    t.not_nil(info.capacity)
    t.eq(64000, info.capacity.total)
    t.true_(info.capacity.used > 0, "容量估算应>0")

    local c = status.component()
    t.true_(c:find("deepseek", 1, true) ~= nil, "component 含模型")
    t.matches("↑30%.0k", c, "component 含 prompt 用量")
    t.matches("缓存命中83%%", c, "component 含缓存命中率")
    t.matches("剩余容量", c, "component 含剩余容量")
  end)

  it("segment 按段输出", function(t)
    init_chat()
    local status = require("NeoAI.services.status")
    local chat = require("NeoAI.services.chat_service")
    local agent = chat.new_session({})
    agent.usage = { prompt = 1000, completion = 200 }
    t.matches("^%[CHAT%]$", status.segment("mode"))
    t.matches("↑1.0k", status.segment("usage"))
  end)

  it("ui.statusline.enabled=false 时 component 为空", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local chat = init_chat()
    config_store.set("ui.statusline.enabled", false)
    local status = require("NeoAI.services.status")
    chat.new_session({})
    t.eq("", status.component())
    config_store.set("ui.statusline.enabled", true)
  end)

  it("colors 默认不为空且可被配置覆盖", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    init_chat()
    local status = require("NeoAI.services.status")
    local colors = status.colors()
    t.true_(#colors.model > 0, "model 应有默认高亮组")
    t.true_(#colors.usage > 0)
    config_store.set("ui.statusline.colors", { model = "Identifier" })
    t.eq("Identifier", status.colors().model, "配置可覆盖高亮组")
    config_store.set("ui.statusline.colors", {})
  end)

  it("winbar 默认启用，配置为 false 时关闭", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    init_chat()
    local status = require("NeoAI.services.status")
    t.true_(status.winbar_enabled(), "默认应启用第二行")
    config_store.set("ui.statusline.winbar", false)
    t.false_(status.winbar_enabled(), "关闭后不应启用")
    config_store.set("ui.statusline.winbar", true)
  end)

  it("扩展只接管主消息窗口（neoai）", function(t)
    init_chat()
    local ext = require("lualine.extensions.neoai")
    t.deep_eq({ "neoai" }, ext.filetypes, "扩展 filetypes 应只含 neoai")
  end)
end)
