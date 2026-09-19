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
    -- deepseek-v4-flash 命中能力表 window=131072（用户未显式覆盖 context_window）
    t.eq(131072, info.capacity.total)
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

  it("沙箱待审徽标使用醒目的自定义高亮组并已定义", function(t)
    init_chat()
    local status = require("NeoAI.services.status")
    t.eq("NeoAISandboxPending", status.colors().sandbox, "sandbox 段应链接醒目高亮组")
    t.eq(1, vim.fn.hlexists("NeoAISandboxPending"), "自定义高亮组应已定义")
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

  it("正忙排队时 segment(pending) 显示待发N，发送后清零", function(t)
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    local agent = chat.new_session({})
    t.eq(0, chat.pending_count(), "空闲时无待发消息")
    t.eq("", status.segment("pending"), "无敌徽标不渲染")

    -- agent 正忙时发送 → 入队
    agent:set_state("tool_running")
    chat.send_message("第一条")
    chat.send_message("第二条")
    t.eq(2, chat.pending_count(), "排队数应反映暂存消息")
    t.eq("待发2", status.segment("pending"), "正忙时显示待发N徽标")

    -- 轮末注入（模拟 tool_loop 注入器，等价于发送/清除）
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    tool_loop.inject_pending(agent)
    t.eq(0, chat.pending_count(), "注入后队列应清空")
    t.eq("", status.segment("pending"), "发送后徽标应消失")
  end)

  it("沙箱待审时 segment(sandbox) 显示待审N，清零后消失", function(t)
    init_chat()
    local status = require("NeoAI.services.status")
    local services = require("NeoAI.kernel.services")
    local saved = services.use("services.sandbox")
    services.provide("services.sandbox", { pending_count = function() return 3 end })
    t.eq("待审3", status.segment("sandbox"), "有待审时应显示待审N")
    t.true_(status.has("sandbox"))
    services.provide("services.sandbox", { pending_count = function() return 0 end })
    t.eq("", status.segment("sandbox"), "无待审时徽标不渲染")
    services.provide("services.sandbox", saved)
  end)

  it("沙箱待审含 L3 时显示红色危险高亮与 ⚠危险 标记", function(t)
    init_chat()
    local status = require("NeoAI.services.status")
    local services = require("NeoAI.kernel.services")
    local saved = services.use("services.sandbox")
    t.eq("NeoAISandboxDanger", status.colors().sandbox_danger, "应链接红色危险高亮组")
    t.eq(1, vim.fn.hlexists("NeoAISandboxDanger"), "危险高亮组应已定义")
    services.provide("services.sandbox", {
      pending_summary = function() return { count = 2, max_level = 3 } end,
    })
    t.eq("待审2 ⚠危险", status.segment("sandbox"), "L3 待审应带危险标记")
    t.eq(3, status.sandbox_level(), "应报告最高级别 L3")
    services.provide("services.sandbox", {
      pending_summary = function() return { count = 1, max_level = 2 } end,
    })
    t.eq("待审1", status.segment("sandbox"), "非 L3 不应带危险标记")
    t.eq(2, status.sandbox_level(), "应报告 L2")
    services.provide("services.sandbox", saved)
  end)

  it("越界留痕点亮 sandbox 徽标并显示越界N", function(t)
    init_chat()
    local status = require("NeoAI.services.status")
    local services = require("NeoAI.kernel.services")
    local saved = services.use("services.sandbox")
    services.provide("services.sandbox", {
      pending_count = function() return 0 end,
      trace_count = function() return 2 end,
    })
    t.eq("越界2", status.segment("sandbox"), "仅有越界留痕时应显示越界N")
    t.true_(status.has("sandbox"), "有越界留痕时徽标应渲染")
    services.provide("services.sandbox", {
      pending_summary = function() return { count = 1, max_level = 1 } end,
      trace_count = function() return 3 end,
    })
    t.eq("待审1 越界3", status.segment("sandbox"), "待审与越界应并列显示")
    services.provide("services.sandbox", saved)
  end)

  it("capacity 优先用 API 最近一次用量并分级告警", function(t)
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    local agent = chat.new_session({})
    agent.model = "deepseek-v4-flash"
    agent.messages = {}
    agent.usage = { prompt = 100, completion = 10, last_prompt = 120000, last_completion = 20 }
    local cap = status.capacity_for(agent)
    t.eq(120000, cap.used)
    t.eq("api", cap.source)
    t.eq("warn", cap.level, "120000/131072 ≈ 0.92 应为 warn")
    t.matches("↑120k", status.segment("usage"), "usage 段显示最近一次请求")

    agent.usage.last_prompt = 140000
    t.eq("over", status.capacity_for(agent).level)
    t.eq("上下文超限", status.segment("capacity"))
  end)

  it("check_pressure 按级别提示且同级去重", function(t)
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    local agent = chat.new_session({})
    agent.model = "deepseek-v4-flash"
    agent.messages = {}
    agent.usage = { last_prompt = 120000, last_completion = 1 }
    local calls = {}
    local orig = vim.notify
    vim.notify = function(msg, lvl) calls[#calls + 1] = { msg = msg, lvl = lvl } end
    local ok, err = pcall(function()
      t.eq("warn", status.check_pressure(agent))
      t.eq(1, #calls, "warn 首次应提示")
      t.eq("warn", status.check_pressure(agent))
      t.eq(1, #calls, "同级别去重")
      agent.usage.last_prompt = 140000
      t.eq("over", status.check_pressure(agent))
      t.eq(2, #calls, "升级到 over 应再提示")
      t.eq(vim.log.levels.ERROR, calls[2].lvl)
      t.eq(vim.log.levels.WARN, calls[1].lvl)
    end)
    vim.notify = orig
    if not ok then error(err) end
  end)
end)
