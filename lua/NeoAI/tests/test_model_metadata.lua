--- 模型实时元数据贯通测试
--- @module NeoAI.tests.test_model_metadata
--- 覆盖：各协议 parse_models 的数值提取、registry 保存/查询、capabilities 实时优先、
--- 缓存落盘与旧格式兼容、用户覆盖最高优先级。

local tests = require("NeoAI.tests")

tests.suite("model_metadata", function(_, it)
  local function load(extra)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load(vim.tbl_deep_extend("force", {
      ai = {
        default_provider = "deepseek",
        providers = {
          deepseek = { api_type = "openai", base_url = "http://x", api_key = "k" },
          groq = { api_type = "openai", base_url = "http://q", api_key = "k" },
          anthropic = { api_type = "anthropic", base_url = "http://a", api_key = "k" },
          google = { api_type = "google", base_url = "http://g", api_key = "k" },
        },
      },
    }, extra or {}))
  end

  --- 每次用例后清空 registry，避免污染后续套件（如 status 依赖内置窗口）
  local function reset_registry()
    require("NeoAI.core.model.registry").reset()
  end

  it("OpenAI 兼容元数据：context_window / context_length / top_provider", function(t)
    local adapter = require("NeoAI.core.model.adapter")
    local a = adapter.get("openai")
    local models = a.parse_models([[{"data":[
      {"id":"llama-3.3-70b","context_window":131072},
      {"id":"some/model","context_length":200000,"top_provider":{"max_completion_tokens":16384}}
    ]}]])
    t.eq(2, #models)
    t.eq(131072, models[1].context_window)
    t.nil_(models[1].max_output)
    t.eq(200000, models[2].context_window)
    t.eq(16384, models[2].max_output)
  end)

  it("Google 元数据：inputTokenLimit / outputTokenLimit", function(t)
    local adapter = require("NeoAI.core.model.adapter")
    local g = adapter.get("google")
    local models = g.parse_models([[{"models":[
      {"name":"models/gemini-2.5-pro","inputTokenLimit":1048576,"outputTokenLimit":65536}
    ]}]])
    t.eq("gemini-2.5-pro", models[1].id)
    t.eq(1048576, models[1].context_window)
    t.eq(65536, models[1].max_output)
  end)

  it("Anthropic 元数据：无限制字段时全为 nil（回退内置）", function(t)
    local adapter = require("NeoAI.core.model.adapter")
    local a = adapter.get("anthropic")
    local models = a.parse_models('{"data":[{"id":"claude-3-5-sonnet","display_name":"Sonnet"}]}')
    t.eq("claude-3-5-sonnet", models[1].id)
    t.nil_(models[1].context_window)
    t.nil_(models[1].max_output)
  end)

  it("model_ids 兼容 string[] / object[]", function(t)
    local adapter = require("NeoAI.core.model.adapter")
    t.deep_eq({ "a", "b" }, adapter.model_ids({ "a", "b" }))
    t.deep_eq({ "a", "b" }, adapter.model_ids({ { id = "a" }, { id = "b" } }))
  end)

  it("registry 规范化：存元数据 + meta 可查询", function(t)
    load()
    reset_registry()
    local registry = require("NeoAI.core.model.registry")
    registry.update("groq", {
      { id = "llama-3.3-70b", context_window = 131072, max_output = 32768 },
      "plain-model",
    })
    local meta = registry.meta("llama-3.3-70b", "groq")
    t.not_nil(meta)
    t.eq(131072, meta.context_window)
    t.eq(32768, meta.max_output)
    -- 无元数据的模型返回 nil
    t.nil_(registry.meta("plain-model", "groq"))
    t.nil_(registry.meta("nope", "groq"))
    reset_registry()
  end)

  it("capabilities：实时元数据优先于内置表", function(t)
    load()
    reset_registry()
    local registry = require("NeoAI.core.model.registry")
    -- 内置 deepseek-v4-flash 窗口 131072；实时回传 200000
    registry.update("deepseek", {
      { id = "deepseek-v4-flash", context_window = 200000, max_output = 12345 },
    })
    local caps = require("NeoAI.core.model.capabilities")
    local d = caps.resolve("deepseek-v4-flash", "deepseek")
    t.eq(200000, d.context_window)
    t.eq(12345, d.max_output)
    t.eq("live", d.source.window)
    t.eq("live", d.source.max_output)
    -- 窗口推导同样吃实时值（用户未显式覆盖）
    t.eq(200000, caps.resolve_window(nil, "deepseek-v4-flash", "deepseek"))
    reset_registry()
  end)

  it("capabilities：无实时数据回退内置表并标注来源", function(t)
    load()
    reset_registry()
    local caps = require("NeoAI.core.model.capabilities")
    local d = caps.resolve("deepseek-v4-flash", "deepseek")
    t.eq(131072, d.context_window)
    t.eq("builtin", d.source.window)
  end)

  it("capabilities：用户覆盖优先级最高", function(t)
    load({ ai = { model_policy = { overrides = {
      ["deepseek-v4-flash"] = { window = 999, max_output = 111 },
    } } } })
    reset_registry()
    local registry = require("NeoAI.core.model.registry")
    registry.update("deepseek", {
      { id = "deepseek-v4-flash", context_window = 131072, max_output = 12345 },
    })
    local caps = require("NeoAI.core.model.capabilities")
    local d = caps.resolve("deepseek-v4-flash", "deepseek")
    t.eq(999, d.context_window)
    t.eq(111, d.max_output)
    t.eq("user", d.source.window)
    t.eq("user", d.source.max_output)
    reset_registry()
  end)

  it("capabilities：model_policy.enabled=false 忽略实时元数据", function(t)
    load({ ai = { model_policy = { enabled = false } } })
    reset_registry()
    local registry = require("NeoAI.core.model.registry")
    registry.update("deepseek", {
      { id = "deepseek-v4-flash", context_window = 131072, max_output = 12345 },
    })
    local caps = require("NeoAI.core.model.capabilities")
    local d = caps.resolve("deepseek-v4-flash", "deepseek")
    t.eq("builtin", d.source.window)
    t.eq(64000, caps.resolve_window(nil, "deepseek-v4-flash", "deepseek"))
    reset_registry()
  end)

  it("cache：对象数组落盘并读回", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ ai = { model_refresh = { cache_path = "/tmp/neoai_test_meta" } } })
    local cache = require("NeoAI.core.model.cache")
    cache.write("groq", { { id = "llama", context_window = 131072 } })
    local data = cache.read("groq")
    t.eq(1, #data.models)
    t.eq("llama", data.models[1].id)
    t.eq(131072, data.models[1].context_window)
    cache.clear("groq")
  end)

  it("cache：兼容旧版字符串数组，经 registry 规范化", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ ai = { model_refresh = { cache_path = "/tmp/neoai_test_meta2" } } })
    local fs = require("NeoAI.utils.fs")
    local json = require("NeoAI.utils.json")
    fs.ensure_dir("/tmp/neoai_test_meta2")
    fs.write_file("/tmp/neoai_test_meta2/legacy.json",
      json.encode({ updated_at = os.time(), provider = "legacy", models = { "a", "b" } }))
    local cache = require("NeoAI.core.model.cache")
    local registry = require("NeoAI.core.model.registry")
    registry.reset()
    registry.update("legacy", cache.read("legacy").models)
    registry.list("legacy"):then_(function(list)
      t.eq(2, #list)
      t.eq("a", list[1].id)
    end)
    cache.clear("legacy")
    registry.reset()
  end)
end)
