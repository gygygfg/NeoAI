--- 缓存命中计算（按模型机制分派）测试
--- @module NeoAI.tests.test_cache_usage

local tests = require("NeoAI.tests")

tests.suite("cache_usage", function(_, it)
  local function load()
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "anthropic",
        providers = {
          anthropic = { api_type = "anthropic", base_url = "http://a", api_key = "k" },
          google = { api_type = "google", base_url = "http://g", api_key = "k" },
          deepseek = { api_type = "openai", base_url = "http://d", api_key = "k" },
        },
      },
    })
  end

  it("OpenAI/DeepSeek：prompt_cache_hit_tokens / cached_tokens", function(t)
    load()
    local prefix = require("NeoAI.core.agent.prefix")
    local cu = prefix.parse_cache_usage({ prompt_tokens = 300, prompt_cache_hit_tokens = 256 }, "deepseek-v4-flash", "deepseek")
    t.eq(256, cu.cache_read)
    t.eq(44, cu.cache_miss)
    t.true_(math.abs(cu.ratio - 256 / 300) < 1e-6)
    local cu2 = prefix.parse_cache_usage({ prompt_tokens = 300, prompt_tokens_details = { cached_tokens = 200 } }, "deepseek-v4-flash", "deepseek")
    t.eq(200, cu2.cache_read)
  end)

  it("Anthropic：cache_read_input_tokens / cache_creation_input_tokens", function(t)
    load()
    local prefix = require("NeoAI.core.agent.prefix")
    local cu = prefix.parse_cache_usage({
      input_tokens = 100, cache_read_input_tokens = 900, cache_creation_input_tokens = 200,
    }, "claude-sonnet-4", "anthropic")
    t.eq(900, cu.cache_read)
    t.eq(200, cu.cache_write)
    -- 总量 = input(100) + read(900) + write(200) = 1200；未命中 = 300
    t.eq(300, cu.cache_miss)
    t.true_(math.abs(cu.ratio - 900 / 1200) < 1e-6)
  end)

  it("Gemini：cachedContentTokenCount / promptTokenCount", function(t)
    load()
    local prefix = require("NeoAI.core.agent.prefix")
    local cu = prefix.parse_cache_usage({
      usageMetadata = { promptTokenCount = 1000, cachedContentTokenCount = 400, candidatesTokenCount = 50 },
    }, "gemini-2.0-flash", "google")
    t.eq(400, cu.cache_read)
    t.eq(600, cu.cache_miss)
    t.true_(math.abs(cu.ratio - 0.4) < 1e-6)
  end)

  it("agent.add_usage 按模型分派：Anthropic 不重复计输入", function(t)
    load()
    local agent_mod = require("NeoAI.core.agent.agent")
    local a = agent_mod.create({ model = "claude-sonnet-4", config = { provider = "anthropic" } })
    agent_mod.add_usage(a, { input_tokens = 100, cache_read_input_tokens = 900, output_tokens = 50 })
    -- 未缓存输入 = 100（input_tokens），命中 = 900
    t.eq(100, a.usage.prompt)
    t.eq(900, a.usage.cache_read)
    t.eq(50, a.usage.completion)
    t.eq(1, a.usage.requests)
    t.true_(math.abs(a.usage.cache_ratio - 900 / 1000) < 1e-6)
    -- 最近一次 API 用量：last_prompt 含缓存命中（真实上下文规模），供容量计算
    t.eq(1000, a.usage.last_prompt)
    t.eq(100, a.usage.last_prompt_uncached)
    t.eq(50, a.usage.last_completion)

    local g = agent_mod.create({ model = "gemini-2.0-flash", config = { provider = "google" } })
    agent_mod.add_usage(g, { usageMetadata = { promptTokenCount = 1000, cachedContentTokenCount = 400, candidatesTokenCount = 10 } })
    t.eq(600, g.usage.prompt)
    t.eq(400, g.usage.cache_read)
    t.eq(10, g.usage.completion)
    t.eq(1000, g.usage.last_prompt)
    t.eq(600, g.usage.last_prompt_uncached)
  end)

  it("used_tokens：优先 API 最近用量，缺失回退完整请求估算", function(t)
    load()
    local agent_mod = require("NeoAI.core.agent.agent")
    local context_builder = require("NeoAI.core.session.context_builder")
    local a = agent_mod.create({ model = "deepseek-v4-flash", config = { provider = "deepseek" } })
    agent_mod.add_message(a, "user", string.rep("a", 400))
    -- 无 API 用量：回退估算（含系统提示）
    local est, src = context_builder.used_tokens(a)
    t.eq("estimate", src)
    t.true_(est > 0)
    -- 有 API 用量：直接采用
    a.usage.last_prompt = 12345
    local used, src2 = context_builder.used_tokens(a)
    t.eq(12345, used)
    t.eq("api", src2)
  end)
end)
