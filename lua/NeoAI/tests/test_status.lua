--- 状态栏服务测试
--- @module 'NeoAI.tests.test_status'

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
    t.matches("↑30%.0k", c, "component 含累计 prompt 用量")
    t.matches("↓5%.0k", c, "component 含累计 completion 用量")
    t.matches("命中83%.33%%", c, "component 含累计缓存命中率（两位小数）")
    t.matches("占用", c, "component 含上下文占用比")
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

  it("usage 段展示累计用量（不随最近一次请求跳变）", function(t)
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    local agent = chat.new_session({})
    agent.usage = { prompt = 30000, completion = 5000, last_prompt = 120000, last_completion = 20 }
    -- 即便存在 last_prompt/last_completion，也应展示累计口径
    t.eq("↑30.0k ↓5.0k", status.segment("usage"), "usage 应为累计而非最近一次")
  end)

  it("命中段展示累计命中率且保留两位小数", function(t)
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    local agent = chat.new_session({})
    agent.usage = { requests = 3, cache_ratio = 0.9532 }
    -- segment 为 statusline 安全会转义 %（%%），断言按转义后文本
    t.eq("命中95.32%%", status.segment("cache"), "缓存命中率应为累计且两位小数")
  end)

  it("命中段默认同时展示单次与总计累计", function(t)
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    local agent = chat.new_session({})
    agent.usage = {
      requests = 35,
      cache_ratio = 0.9455,
      last_prompt = 36143,
      last_cache_read = 35968,
    }
    t.eq("命中99.52%%(总计94.55%%)", status.segment("cache"))
  end)

  it("缓存段 cache_mode 可控：latest 只显示单次，cumulative 只显示累计", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    local agent = chat.new_session({})
    agent.usage = {
      requests = 35, cache_ratio = 0.9455,
      last_prompt = 36143, last_cache_read = 35968,
    }
    config_store.set("ui.statusline.cache_mode", "latest")
    t.eq("命中99.52%%", status.segment("cache"))
    config_store.set("ui.statusline.cache_mode", "cumulative")
    t.eq("命中94.55%%", status.segment("cache"))
    config_store.set("ui.statusline.cache_mode", "both")
  end)

  it("缓存段无单次数据时回退累计口径", function(t)
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    local agent = chat.new_session({})
    agent.usage = { requests = 3, cache_ratio = 0.9532 }
    t.eq("命中95.32%%", status.segment("cache"))
  end)

  it("usage/cache 聚合主会话与全部直接子 Agent 会话（实时 + 持久化）", function(t)
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    local store = require("NeoAI.core.session.session_store")
    local runtime = require("NeoAI.core.agent.runtime")
    local manager = require("NeoAI.core.agent.sub_agent")
    manager.reset()

    local main = chat.new_session({})
    main.usage = {
      prompt = 1000, completion = 100, requests = 1,
      cache_read = 1000, prompt_total = 6000, prompt_cache_total = 1000,
      cache_ratio = 1000 / 6000,
      last_prompt = 1000, last_cache_read = 999, last_completion = 10,
    }
    main._last_usage_at = 1

    -- 运行中的子 Agent（实时 usage，最新一次请求应压过主 Agent）
    local live_sess = store.create({
      parent_id = main.session_id,
      name = "sub-live",
      metadata = { tags = { "sub_agent" }, name = "sub-live" },
    })
    local child = runtime.spawn(main, { session_id = live_sess.id })
    child.usage = {
      prompt = 500, completion = 50, requests = 1,
      cache_read = 1500, prompt_total = 2000, prompt_cache_total = 1500,
      cache_ratio = 1500 / 2000,
      last_prompt = 1000, last_cache_read = 500, last_completion = 5,
    }
    child._last_usage_at = 2
    manager._inject_for_test("s-live", {
      parent_agent_id = main.id, agent_id = child.id, session_id = live_sess.id,
    })
    -- 同一子会话的持久化数据不得与实时 usage 重复累加
    live_sess.metadata.usage = {
      prompt = 99999, completion = 99999, requests = 999,
      cache_read = 99999, prompt_total = 99999, prompt_cache_total = 99999,
    }

    -- 已完成（或重开会话后）的子 Agent：取子会话持久化 metadata.usage
    store.create({
      parent_id = main.session_id,
      name = "sub-hist",
      metadata = {
        tags = { "sub_agent" }, name = "sub-hist",
        usage = {
          prompt = 300, completion = 30, requests = 1,
          cache_read = 500, prompt_total = 2000, prompt_cache_total = 500,
          cache_ratio = 500 / 2000,
        },
      },
    })
    -- 用户 fork 分支下的子 Agent 不属于当前会话树，不得计入
    local fork = store.create({ parent_id = main.session_id, name = "fork" })
    store.create({
      parent_id = fork.id,
      name = "fork-sub",
      metadata = {
        tags = { "sub_agent" }, name = "fork-sub",
        usage = { prompt = 77777, completion = 77777, requests = 99, prompt_total = 77777 },
      },
    })

    local info = status.get_info()
    t.eq(1800, info.usage.prompt, "输入应为主会话 + 运行中子 Agent + 历史子会话之和")
    t.eq(180, info.usage.completion, "输出应聚合")
    t.eq(3, info.usage.requests, "请求数应聚合")
    t.eq(2, info.usage.sub_agent_sessions, "仅计入直接子 Agent 会话（实时 + 历史各一）")
    -- 加权命中率 = (1000+1500+500)/(6000+2000+2000) = 30%，不是各 Agent 比率的平均
    local ratio_ok = math.abs(info.usage.cache_ratio - 0.30) < 1e-6
    t.true_(ratio_ok, "累计命中率应按 token 加权")
    t.eq("↑1.8k ↓180", status.segment("usage"))
    t.eq("命中50.00%%(总计30.00%%)", status.segment("cache"),
      "单次取主/子中最新的请求，累计按整棵会话树加权")
    manager.reset()
  end)

  it("单次命中率无请求序号时回退主 Agent；capacity 不随子 Agent 聚合", function(t)
    local chat = init_chat()
    local status = require("NeoAI.services.status")
    local store = require("NeoAI.core.session.session_store")
    local runtime = require("NeoAI.core.agent.runtime")
    local manager = require("NeoAI.core.agent.sub_agent")
    manager.reset()

    local main = chat.new_session({})
    main.model = "deepseek-v4-flash"
    main.messages = {}
    main.usage = {
      prompt = 100, completion = 10, requests = 1,
      cache_read = 400, prompt_total = 500, prompt_cache_total = 400,
      cache_ratio = 400 / 500,
      last_prompt = 1000, last_cache_read = 800,
    }
    local live_sess = store.create({
      parent_id = main.session_id,
      metadata = { tags = { "sub_agent" }, name = "sub" },
    })
    local child = runtime.spawn(main, { session_id = live_sess.id })
    child.usage = {
      prompt = 50, completion = 5, requests = 1,
      cache_read = 50, prompt_total = 100, prompt_cache_total = 50,
      cache_ratio = 0.5,
      last_prompt = 1000, last_cache_read = 100,
    }
    manager._inject_for_test("s-noat", {
      parent_agent_id = main.id, agent_id = child.id, session_id = live_sess.id,
    })

    -- 无 _last_usage_at：保留先加入的主 Agent 口径（80%），不被子 Agent 的 10% 覆盖
    t.eq("命中80.00%%(总计75.00%%)", status.segment("cache"))
    -- capacity 仍按主 Agent 的 last_prompt 计算（1000），不因聚合而改变
    local cap = assert(status.capacity_for(main))
    t.eq(1000, cap.used)
    manager.reset()
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
    local cap = assert(status.capacity_for(agent))
    t.eq(120000, cap.used)
    t.eq("api", cap.source)
    t.eq("warn", cap.level, "120000/131072 ≈ 0.92 应为 warn")
    t.matches("↑100", status.segment("usage"), "usage 段显示累计用量（容量另走 last_prompt）")
    -- 占用比从 0% 起算（旧实现显示「剩余容量」，起点是 100%）
    t.eq("占用92%%", status.segment("capacity"), "容量段应显示已用占比")

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
    ---@diagnostic disable-next-line: duplicate-set-field
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
