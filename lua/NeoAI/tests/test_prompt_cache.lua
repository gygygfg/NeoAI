--- 显式缓存管理器测试（注入 / 降级 / Gemini 生命周期）
--- @module NeoAI.tests.test_prompt_cache

local tests = require("NeoAI.tests")

tests.suite("prompt_cache", function(_, it)
  local function wait_until(f, timeout_ms)
    local deadline = vim.uv.hrtime() / 1e6 + (timeout_ms or 3000)
    while not f() do
      if vim.uv.hrtime() / 1e6 > deadline then return false end
      vim.wait(15)
    end
    return true
  end

  local function load(extra)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load(vim.tbl_deep_extend("force", {
      ai = {
        default_provider = "anthropic",
        providers = {
          anthropic = { api_type = "anthropic", base_url = "http://a", api_key = "ka" },
          google = { api_type = "google", base_url = "http://g", api_key = "kg" },
          openai = { api_type = "openai", base_url = "http://o", api_key = "ko" },
        },
      },
    }, extra or {}))
  end

  it("Anthropic：system + 最后一个工具注入 cache_control", function(t)
    load()
    local capabilities = require("NeoAI.core.model.capabilities")
    local cache = require("NeoAI.core.model.prompt_cache")
    cache.reset()
    local caps = capabilities.resolve("claude-sonnet-4", "anthropic")
    local body = { model = "claude", system = "SYS", tools = { { name = "a" }, { name = "b" } } }
    local done, ok = false, nil
    cache.apply_async({ body = body, caps = caps, provider_name = "anthropic", model = "claude", system = "SYS", tools = body.tools }):then_(function(r) ok = r done = true end)
    t.true_(wait_until(function() return done end))
    t.true_(ok)
    t.eq("text", body.system[1].type)
    t.not_nil(body.system[1].cache_control)
    t.nil_(body.tools[1].cache_control)
    t.not_nil(body.tools[2].cache_control)
  end)

  it("OpenAI：显式断点默认关闭，显式开启后注入", function(t)
    load()
    local capabilities = require("NeoAI.core.model.capabilities")
    local cache = require("NeoAI.core.model.prompt_cache")
    cache.reset()
    local caps = capabilities.resolve("gpt-5.6", "openai")
    -- 默认 openai=false → 不注入
    local b1 = { model = "m", messages = { { role = "user", content = "x" } } }
    local d1 = false
    cache.apply_async({ body = b1, caps = caps, provider_name = "openai", model = "gpt-5.6" }):then_(function() d1 = true end)
    t.true_(wait_until(function() return d1 end))
    t.nil_(b1.prompt_cache_options)

    -- 显式开启
    require("NeoAI.kernel.config_store").set("ai.model_policy.explicit_cache.openai", true)
    local b2 = { model = "m", messages = { { role = "user", content = "x" } } }
    local d2 = false
    cache.apply_async({ body = b2, caps = caps, provider_name = "openai", model = "gpt-5.6" }):then_(function() d2 = true end)
    t.true_(wait_until(function() return d2 end))
    t.eq("explicit", b2.prompt_cache_options.mode)
    t.not_nil(b2.messages[1].content[1].prompt_cache_breakpoint)
    require("NeoAI.kernel.config_store").set("ai.model_policy.explicit_cache.openai", false)
  end)

  it("Gemini：创建缓存对象 + 复用 + 失效删除", function(t)
    load()
    local capabilities = require("NeoAI.core.model.capabilities")
    local cache = require("NeoAI.core.model.prompt_cache")
    cache.reset()
    local calls = {}
    cache._set_transport(function(o)
      calls[#calls + 1] = o
      if o.method == "DELETE" then
        return require("NeoAI.utils.async").resolve("{}")
      end
      return require("NeoAI.utils.async").resolve(
        require("NeoAI.utils.json").encode({ name = "cachedContents/abc" }))
    end)

    local caps = capabilities.resolve("gemini-2.0-flash", "google")
    local system = { { text = string.rep("x", 9000) } }
    local tools = { { functionDeclarations = { { name = "f" } } } }

    local b1 = { model = "gemini-2.0-flash" }
    local done1 = false
    cache.apply_async({ body = b1, caps = caps, provider = { base_url = "http://g", api_key = "kg" }, provider_name = "google", model = "gemini-2.0-flash", system = system, tools = tools }):then_(function() done1 = true end)
    t.true_(wait_until(function() return done1 end))
    t.eq("cachedContents/abc", b1.cachedContent)
    t.nil_(b1.systemInstruction) -- 命中缓存后前缀由缓存承载
    t.eq(1, #calls) -- 一次 POST 创建

    -- 第二次相同前缀：复用，不再创建
    local b2 = { model = "gemini-2.0-flash" }
    local done2 = false
    cache.apply_async({ body = b2, caps = caps, provider = { base_url = "http://g", api_key = "kg" }, provider_name = "google", model = "gemini-2.0-flash", system = system, tools = tools }):then_(function() done2 = true end)
    t.true_(wait_until(function() return done2 end))
    t.eq("cachedContents/abc", b2.cachedContent)
    t.eq(1, #calls) -- 未新增请求

    -- 前缀变化（tools 变）→ 重建并删除旧对象
    local tools2 = { { functionDeclarations = { { name = "g" } } } }
    local b3 = { model = "gemini-2.0-flash" }
    local done3 = false
    cache.apply_async({ body = b3, caps = caps, provider = { base_url = "http://g", api_key = "kg" }, provider_name = "google", model = "gemini-2.0-flash", system = system, tools = tools2 }):then_(function() done3 = true end)
    t.true_(wait_until(function() return done3 end))
    local has_delete = false
    for _, c in ipairs(calls) do if c.method == "DELETE" then has_delete = true end end
    t.true_(has_delete, "前缀变化应删除旧缓存对象")

    -- dispose 删除
    cache.dispose("google", "gemini-2.0-flash")
    t.nil_(cache._entry("google", "gemini-2.0-flash"))
  end)

  it("显式缓存总开关关闭时不注入", function(t)
    load({ ai = { model_policy = { explicit_cache = { enabled = false } } } })
    local capabilities = require("NeoAI.core.model.capabilities")
    local cache = require("NeoAI.core.model.prompt_cache")
    cache.reset()
    local caps = capabilities.resolve("claude-sonnet-4", "anthropic")
    local body = { system = "SYS" }
    local done = false
    cache.apply_async({ body = body, caps = caps, provider_name = "anthropic", model = "claude" }):then_(function() done = true end)
    t.true_(wait_until(function() return done end))
    t.eq("SYS", body.system) -- 未注入 cache_control
  end)
end)
