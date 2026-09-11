--- 协议族 + 厂商方言层测试
--- @module NeoAI.tests.test_model_profiles

local tests = require("NeoAI.tests")

tests.suite("model_profiles", function(_, it)
  local function load(providers, extra)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load(vim.tbl_deep_extend("force", {
      ai = { default_provider = "deepseek", providers = providers or {} },
    }, extra or {}))
  end

  it("OpenAI 推理模型：max_completion_tokens + effort + 无 temperature", function(t)
    load({ openai = { api_type = "openai", base_url = "http://x", api_key = "k" } })
    local profiles = require("NeoAI.core.model.profiles")
    local d = profiles.resolve("openai", { api_type = "openai" }, "gpt-5")
    t.eq("max_completion_tokens", d.max_tokens_field)
    t.eq("effort", d.reasoning_kind)
    t.false_(d.temperature_supported)
  end)

  it("DeepSeek：openai 协议 + max_tokens", function(t)
    load({ deepseek = { api_type = "openai", base_url = "http://x", api_key = "k" } })
    local profiles = require("NeoAI.core.model.profiles")
    local d = profiles.resolve("deepseek", { api_type = "openai" }, "deepseek-v4-flash")
    t.eq("openai", d.protocol)
    t.eq("max_tokens", d.max_tokens_field)
    t.eq("none", d.reasoning_kind)
  end)

  it("Anthropic / Gemini 协议默认", function(t)
    load({
      anthropic = { api_type = "anthropic", base_url = "http://a", api_key = "k" },
      google = { api_type = "google", base_url = "http://g", api_key = "k" },
    })
    local profiles = require("NeoAI.core.model.profiles")
    local a = profiles.resolve("anthropic", { api_type = "anthropic" }, "claude-x")
    t.eq("anthropic", a.protocol)
    t.eq("budget", a.reasoning_kind)
    t.true_(a.max_tokens_required) -- Anthropic max_tokens 必填
    local g = profiles.resolve("google", { api_type = "google" }, "gemini-x")
    t.eq("google", g.protocol)
    t.eq("maxOutputTokens", g.max_tokens_field)
    t.false_(g.max_tokens_required)
  end)

  it("OpenAI 协议 max_tokens 非必填", function(t)
    load({ deepseek = { api_type = "openai", base_url = "http://x", api_key = "k" } })
    local profiles = require("NeoAI.core.model.profiles")
    t.false_(profiles.resolve("deepseek", { api_type = "openai" }, "deepseek-v4").max_tokens_required)
  end)

  it("第三方 OpenAI 兼容方言（enable_thinking / thinking 对象）", function(t)
    load({
      siliconflow = { api_type = "openai", base_url = "http://s", api_key = "k" },
      zhipu = { api_type = "openai", base_url = "http://z", api_key = "k" },
      openrouter = { api_type = "openai", base_url = "http://o", api_key = "k" },
    })
    local profiles = require("NeoAI.core.model.profiles")
    t.eq("enable_thinking", profiles.resolve("siliconflow", { api_type = "openai" }, "m").reasoning_kind)
    t.eq("thinking_object", profiles.resolve("zhipu", { api_type = "openai" }, "glm-4").reasoning_kind)
    t.eq("openrouter_object", profiles.resolve("openrouter", { api_type = "openai" }, "m").reasoning_kind)
  end)

  it("用户方言覆盖 + enabled=false 回退协议默认", function(t)
    load({ deepseek = { api_type = "openai", base_url = "http://x", api_key = "k" } }, {
      ai = { model_policy = { dialects = { ["deepseek"] = { extra_headers = { ["X-Test"] = "1" } } } } },
    })
    local profiles = require("NeoAI.core.model.profiles")
    local d = profiles.resolve("deepseek", { api_type = "openai" }, "deepseek-v4")
    t.eq("1", d.extra_headers["X-Test"])

    load({ deepseek = { api_type = "openai", base_url = "http://x", api_key = "k" } }, {
      ai = { model_policy = { enabled = false } },
    })
    local off = profiles.resolve("deepseek", { api_type = "openai" }, "gpt-5")
    t.true_(off.temperature_supported) -- 回退协议默认（openai 支持 temperature）
  end)
end)
