--- 前缀管理与上下文缓存策略测试
--- @module NeoAI.tests.test_cache_strategy
--- 覆盖 deepseek-harness 对齐的缓存身份一致性、上下文压缩、prompt 排序。

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

--- 添加消息（agent_mod.add_message 需事件总线，简单包装）
local function agent_mod_add(agent, role, content)
  local agent_mod = require("NeoAI.core.agent.agent")
  agent_mod.add_message(agent, role, content)
end

tests.suite("cache_strategy", function(_, it)
  it("系统提示按有序段渲染（身份 -100 / persona 0 / 工具指引 100+）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        system_prompt = "persona",
        context_cache = { include_identity = true, identity = "IDENTITY" },
      },
    })
    local prefix = require("NeoAI.core.agent.prefix")
    prefix.reset_sections()
    local dispose = prefix.register_section("tool:bash", 100, "tool guidance")
    local agent = require("NeoAI.core.agent.agent").create({ config = { system_prompt = "persona" } })
    local text = prefix.build_system_prompt(agent)
    -- 身份在最前，persona 次之，工具指引在后
    t.eq(1, text:find("IDENTITY", 1, true))
    t.true_(text:find("persona", 1, true) > text:find("IDENTITY", 1, true))
    t.true_(text:find("tool guidance", 1, true) > text:find("persona", 1, true))
    dispose()
    prefix.reset_sections()
  end)

  it("agent 级段遮蔽同名全局段", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ ai = { system_prompt = "persona" } })
    local prefix = require("NeoAI.core.agent.prefix")
    prefix.reset_sections()
    prefix.register_section("shared", 10, "global text")
    local agent = require("NeoAI.core.agent.agent").create({ config = { system_prompt = "persona" } })
    local child = require("NeoAI.core.agent.agent").create({ config = { system_prompt = "persona" } })
    local d2 = prefix.register_agent_section(child, "shared", 10, "scoped text")
    t.true_(prefix.build_system_prompt(agent):find("global text", 1, true) ~= nil)
    t.true_(prefix.build_system_prompt(child):find("scoped text", 1, true) ~= nil)
    t.nil_(prefix.build_system_prompt(child):find("global text", 1, true))
    d2()
    prefix.reset_sections()
  end)

  it("工具定义确定性排序（前缀缓存友好）", function(t)
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local agent = {
      tools = {
        z_tool = { description = "zzz", parameters = { type = "object", properties = { a = { type = "string" } } } },
        a_tool = { description = "aaa" },
        m_tool = { description = "mmm" },
      },
    }
    local defs1 = tool_loop._tool_definitions(agent)
    local names = {}
    for _, d in ipairs(defs1) do names[#names + 1] = d["function"].name end
    t.deep_eq({ "a_tool", "m_tool", "z_tool" }, names)
    -- 同工具集重复渲染逐字节一致
    local defs2 = tool_loop._tool_definitions(agent)
    t.deep_eq(defs1, defs2)
  end)

  it("空 properties 不输出该字段（避免 JSON 编码为 [] 被 DeepSeek 拒绝）", function(t)
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local json = require("NeoAI.utils.json")
    local agent = {
      tools = {
        no_params = { description = "无参数工具" },
        empty_props = { description = "空属性", parameters = { type = "object", properties = {} } },
        with_params = { description = "有参数", parameters = { type = "object", properties = { a = { type = "string" } }, required = { "a" } } },
      },
    }
    local defs = tool_loop._tool_definitions(agent)
    for _, d in ipairs(defs) do
      local fn = d["function"]
      local body = json.encode(d)
      if fn.name == "empty_props" then
        t.true_(body:find("properties", 1, true) == nil, "空 properties 应省略: " .. body)
      elseif fn.name == "no_params" then
        t.true_(body:find("parameters", 1, true) == nil, "无参数工具不应输出 parameters: " .. body)
      elseif fn.name == "with_params" then
        t.true_(body:find('"properties":{"a"', 1, true) ~= nil)
        t.true_(body:find('"required":["a"]', 1, true) ~= nil)
      end
    end
  end)

  it("前缀缓存身份稳定且可检测变更", function(t)
    local prefix = require("NeoAI.core.agent.prefix")
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local system = "SYSTEM"
    local agent = { tools = { b = { description = "b" }, a = { description = "a" } } }
    local defs = tool_loop._tool_definitions(agent)
    local id1 = prefix.prefix_id(system, defs)
    local id2 = prefix.prefix_id(system, defs)
    t.eq(id1, id2)
    t.ne(id1, prefix.prefix_id(system .. "x", defs))
    -- verify_cache_identity 记录变更
    local a = require("NeoAI.core.agent.agent").create({})
    prefix.verify_cache_identity(a, { { role = "system", content = "S1" } }, defs)
    t.eq(0, a.cache.identity_changes)
    prefix.verify_cache_identity(a, { { role = "system", content = "S2" } }, defs)
    t.eq(1, a.cache.identity_changes)
  end)

  it("缓存用量解析（prompt_cache_hit_tokens / cached_tokens）", function(t)
    local prefix = require("NeoAI.core.agent.prefix")
    local cu1 = prefix.parse_cache_usage({ prompt_tokens = 300, prompt_cache_hit_tokens = 256 })
    t.eq(256, cu1.cache_read)
    t.eq(44, cu1.cache_miss)
    t.true_(math.abs(cu1.ratio - 256 / 300) < 1e-6)
    local cu2 = prefix.parse_cache_usage({ prompt_tokens = 300, prompt_tokens_details = { cached_tokens = 200 } })
    t.eq(200, cu2.cache_read)
    local cu3 = prefix.parse_cache_usage({ prompt_tokens = 300 })
    t.eq(0, cu3.cache_read)
    t.nil_(prefix.parse_cache_usage(nil))
  end)

  it("agent usage 累加缓存 token", function(t)
    local agent_mod = require("NeoAI.core.agent.agent")
    local a = agent_mod.create({})
    agent_mod.add_usage(a, { prompt_tokens = 300, completion_tokens = 50, prompt_cache_hit_tokens = 200 })
    t.eq(200, a.usage.cache_read)
    t.eq(100, a.usage.cache_miss)
    t.eq(1, a.usage.requests)
    agent_mod.add_usage(a, { prompt_tokens = 100, completion_tokens = 10, prompt_cache_hit_tokens = 100 })
    t.eq(300, a.usage.cache_read)
    t.eq(2, a.usage.requests)
  end)

  it("压缩范围选择：折叠最早段，保留最近尾部", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        context_cache = {
          context_window = 100,
          retain_ratio = 0.2, -- 尾部保留 20 token
          retain_min_tokens = 4,
          min_shadow_messages = 2,
        },
      },
    })
    local compactor = require("NeoAI.core.session.compactor")
    local agent = require("NeoAI.core.agent.agent").create({})
    local long = ("x"):rep(160) -- ~40 token
    local short = ("y"):rep(20) -- ~5 token
    for _, content in ipairs({ long, short, short, short }) do
      agent_mod_add(agent, "user", content)
    end
    local cfg = { context_window = 100, retain_ratio = 0.1, retain_min_tokens = 4, min_shadow_messages = 2 }
    local shadow = compactor._select_shadow_range(agent, cfg)
    -- 尾部预算 10 token：第一条（40）与第二条（5）超预算被折叠；其余两条保留
    t.eq(2, #shadow)
    t.eq(long, shadow[1].content)
    t.eq(short, shadow[2].content)
    t.eq(2, #agent.messages - #shadow)
  end)

  it("检查点消息帧", function(t)
    local compactor = require("NeoAI.core.session.compactor")
    local m = compactor.checkpoint_message("summary text")
    t.eq("user", m.role)
    t.true_(m.checkpoint)
    t.true_(m.content:find("<compacted-summary>", 1, true) ~= nil)
    t.true_(m.content:find("</compacted-summary>", 1, true) ~= nil)
    t.true_(m.content:find("summary text", 1, true) ~= nil)
  end)

  it("maybe_compact 低于阈值不动", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { context_cache = { enabled = true, context_window = 100000, threshold_ratio = 0.9 } },
    })
    local compactor = require("NeoAI.core.session.compactor")
    local agent = require("NeoAI.core.agent.agent").create({})
    agent_mod_add(agent, "user", "hi")
    local done = false
    local value = nil
    compactor.maybe_compact(agent):then_(function(compacted)
      value = compacted
      done = true
    end)
    local ok = vim.wait(2000, function() return done end)
    t.true_(ok, "异步未完成")
    t.eq(false, value)
  end)

  it("maybe_compact 回放前缀 + 压缩指令，并替换被折叠区间", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "p1",
        providers = { p1 = { api_type = "openai", base_url = "http://x", api_key = "k" } },
        context_cache = {
          enabled = true,
          context_window = 100,
          threshold_ratio = 0.5,
          retain_ratio = 0.1,
          retain_min_tokens = 4,
          min_shadow_messages = 2,
          compact_max_tokens = 512,
          include_identity = false, -- 仅 persona，便于断言
        },
      },
    })
    local compactor = require("NeoAI.core.session.compactor")
    local request_mod = require("NeoAI.core.agent.request")
    local context_builder = require("NeoAI.core.session.context_builder")
    local agent = require("NeoAI.core.agent.agent").create({ config = { system_prompt = "persona" } })

    local long = ("x"):rep(160)
    local short = ("y"):rep(20)
    for _, content in ipairs({ long, short, short, short }) do
      agent_mod_add(agent, "user", content)
    end

    local captured = nil
    local orig_send = request_mod.send
    request_mod.send = function(messages, opts)
      captured = { messages = messages, opts = opts }
      return async.resolve({ content = "## Primary Request and Intent\n- resume", usage = { prompt_tokens = 60, prompt_cache_hit_tokens = 55 } })
    end

    local done = false
    local value = nil
    local ok = false
    compactor.maybe_compact(agent):then_(function(compacted)
      value = compacted
      done = true
    end)
    local wait_ok = vim.wait(3000, function() return done end)
    ok = wait_ok and value == true
    request_mod.send = orig_send

    t.true_(ok, "压缩应发生")
    t.not_nil(captured, "应调用摘要请求")
    -- 回放前缀：系统 + 被折叠消息（两条）+ 压缩指令 = 4 条
    t.eq("system", captured.messages[1].role)
    t.eq("persona", captured.messages[1].content)
    t.eq(4, #captured.messages)
    -- 折叠区消息逐字节回放
    t.eq(long, captured.messages[2].content)
    t.eq(short, captured.messages[3].content)
    -- 压缩指令为最后一条 user 消息（前缀缓存复用）
    local last = captured.messages[#captured.messages]
    t.eq("user", last.role)
    t.true_(last.content:find("compaction engine", 1, true) ~= nil)
    -- 摘要请求带上工具定义
    t.not_nil(captured.opts.tools)
    -- 替换：首条为检查点，原被折叠的两条消失，最近两条保留
    t.eq(3, #agent.messages)
    t.eq("user", agent.messages[1].role)
    t.true_(agent.messages[1].checkpoint)
    t.true_(agent.messages[1].content:find("resume", 1, true) ~= nil)
  end)
end)
