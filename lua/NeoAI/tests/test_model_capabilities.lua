--- 模型能力表测试
--- @module NeoAI.tests.test_model_capabilities

local tests = require("NeoAI.tests")

tests.suite("model_capabilities", function(_, it)
  local function load(extra)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load(vim.tbl_deep_extend("force", {
      ai = {
        default_provider = "deepseek",
        providers = {
          deepseek = { api_type = "openai", base_url = "http://x", api_key = "k" },
          anthropic = { api_type = "anthropic", base_url = "http://a", api_key = "k" },
          google = { api_type = "google", base_url = "http://g", api_key = "k" },
        },
      },
    }, extra or {}))
  end

  it("内置 pattern 命中：窗口/输出/缓存机制", function(t)
    load()
    local caps = require("NeoAI.core.model.capabilities")
    local d = caps.resolve("deepseek-v4-flash", "deepseek")
    t.eq(131072, d.context_window)
    t.eq("openai", d.cache_kind)
    t.false_(d.explicit_cache)

    local c = caps.resolve("claude-sonnet-4-20250514", "anthropic")
    t.eq(200000, c.context_window)
    t.eq("anthropic", c.cache_kind)
    t.true_(c.explicit_cache)
    t.eq(4, c.max_breakpoints)

    local g = caps.resolve("gemini-2.0-flash", "google")
    t.eq(1048576, g.context_window)
    t.eq("gemini", g.cache_kind)
    t.eq(2048, g.min_cacheable)
  end)

  it("未知模型回退协议族默认 / 兜底", function(t)
    load()
    local caps = require("NeoAI.core.model.capabilities")
    local u = caps.resolve("some-unknown-model", "deepseek")
    t.eq("openai", u.cache_kind)
    t.eq(128000, u.context_window) -- openai 协议默认
    t.nil_(u.matched)
  end)

  it("用户覆盖优先于内置 pattern", function(t)
    load({ ai = { model_policy = { overrides = {
      ["deepseek-v4-flash"] = { window = 131072, max_output = 8192 },
    } } } })
    local caps = require("NeoAI.core.model.capabilities")
    local d = caps.resolve("deepseek-v4-flash", "deepseek")
    t.eq(131072, d.context_window)
    t.eq(8192, d.max_output)
    t.true_(caps.has_override("deepseek-v4-flash", "deepseek"))
  end)

  it("resolve_window：显式配置优先，默认 64000 不屏蔽模型窗口", function(t)
    load()
    local caps = require("NeoAI.core.model.capabilities")
    -- 默认 64000 == 兜底值 → 视为未显式配置，按模型推导
    t.eq(131072, caps.resolve_window(64000, "deepseek-v4-flash", "deepseek"))
    -- 显式 99999 → 优先
    t.eq(99999, caps.resolve_window(99999, "deepseek-v4-flash", "deepseek"))
    -- nil → 模型推导
    t.eq(1048576, caps.resolve_window(nil, "gemini-2.0-flash", "google"))
  end)

  it("model_policy.enabled=false 回退默认窗口", function(t)
    load({ ai = { model_policy = { enabled = false } } })
    local caps = require("NeoAI.core.model.capabilities")
    t.eq(64000, caps.resolve_window(nil, "gemini-2.0-flash", "google"))
  end)
end)
