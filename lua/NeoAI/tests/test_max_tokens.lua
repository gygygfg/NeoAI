--- max_tokens 发送策略测试
--- @module 'NeoAI.tests.test_max_tokens'
--- 验证：仅用户显式配置 max_tokens 时才下发；未配置则不发送该字段（由模型/厂商默认最大
--- 输出决定）；协议必填（Anthropic）用能力表 max_output 兜底。

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

tests.suite("max_tokens_policy", function(_, it)
  local http = require("NeoAI.utils.http")

  local function load_cfg(provider)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = provider,
        default_model = "m1",
        providers = {
          deepseek = { api_type = "openai", base_url = "http://127.0.0.1:1", api_key = "k" },
          anthropic = { api_type = "anthropic", base_url = "http://127.0.0.1:1", api_key = "k" },
        },
        modes = { chat = { provider = provider, model = "m1", temperature = 0.5, stream = false } },
        model_policy = { enabled = false },
      },
    })
  end

  --- 发送一次非流式请求，返回捕获到的请求体
  --- @param provider string
  --- @param agent_config table
  --- @return table|nil
  local function capture_body(provider, agent_config)
    load_cfg(provider)
    local request = require("NeoAI.core.agent.request")
    local captured = nil
    local original = http.request
    ---@diagnostic disable-next-line: duplicate-set-field
    http.request = function(opts)
      captured = opts.body
      return async.resolve(vim.json.encode({
        choices = { { message = { role = "assistant", content = "ok" }, finish_reason = "stop" } },
      }))
    end
    local d = request.send({ { role = "user", content = "hi" } }, {
      agent_config = agent_config, model = "m1",
    })
    vim.wait(3000, function() return not d:is_pending() end)
    http.request = original
    return captured
  end

  it("未配置 max_tokens 时请求体不发送该字段", function(t)
    local body = assert(capture_body("deepseek", { provider = "deepseek", model = "m1", temperature = 0.5 }))
    t.not_nil(body, "请求体应被捕获")
    t.nil_(body.max_tokens, "未配置不应发送 max_tokens")
  end)

  it("显式配置 max_tokens 时按值发送", function(t)
    local body = assert(capture_body("deepseek", { provider = "deepseek", model = "m1", temperature = 0.5, max_tokens = 1234 }))
    t.eq(1234, body.max_tokens, "显式值应原样发送")
  end)

  it("Anthropic 必填协议未配置时用能力表兜底", function(t)
    local body = assert(capture_body("anthropic", { provider = "anthropic", model = "m1", temperature = 0.5 }))
    t.not_nil(body.max_tokens, "Anthropic max_tokens 必填，应有兜底值")
    t.true_(body.max_tokens > 0, "兜底值应为正数")
  end)

  -- ===== 推理强度 / thinking 开关（DeepSeek 两种协议） =====

  local DS_OPENAI = { api_type = "openai", base_url = "http://127.0.0.1:1", api_key = "k" }
  local DS_ANTHROPIC = { api_type = "anthropic", base_url = "http://127.0.0.1:1", api_key = "k" }

  --- 捕获指定 provider/model 的 wire body
  --- @param provider string
  --- @param provider_cfg table
  --- @param model string
  --- @param opts table
  --- @param ai_extra table|nil
  --- @return table|nil
  local function capture_reasoning(provider, provider_cfg, model, opts, ai_extra)
    local config_store = require("NeoAI.kernel.config_store")
    local ai = {
      default_provider = provider,
      default_model = model,
      providers = { [provider] = provider_cfg },
      model_policy = { enabled = true },
    }
    for k, v in pairs(ai_extra or {}) do ai[k] = v end
    config_store.load({ ai = ai })

    local request = require("NeoAI.core.agent.request")
    local captured = nil
    local original = http.request
    ---@diagnostic disable-next-line: duplicate-set-field
    http.request = function(o)
      captured = o.body
      local payload = provider_cfg.api_type == "anthropic"
        and { content = { { type = "text", text = "ok" } }, stop_reason = "end_turn" }
        or { choices = { { message = { role = "assistant", content = "ok" }, finish_reason = "stop" } } }
      return async.resolve(vim.json.encode(payload))
    end
    local d = request.send({ { role = "user", content = "hi" } }, vim.tbl_extend("force", {
      agent_config = { provider = provider, model = model },
      model = model,
    }, opts or {}))
    vim.wait(3000, function() return not d:is_pending() end)
    http.request = original
    return captured
  end

  it("DeepSeek OpenAI：reasoning_effort + thinking enabled", function(t)
    -- 只配全局 ai.reasoning_effort，验证配置解析链路
    local body = assert(capture_reasoning("deepseek", DS_OPENAI, "deepseek-flash", {}, { reasoning_effort = "max" }))
    t.eq("max", body.reasoning_effort)
    t.eq("enabled", body.thinking.type)
  end)

  it("DeepSeek OpenAI：辅助调用 reasoning_enabled=false 显式关思考", function(t)
    local body = assert(capture_reasoning("deepseek", DS_OPENAI, "deepseek-flash", { reasoning_enabled = false }))
    t.nil_(body.reasoning_effort)
    t.eq("disabled", body.thinking.type)
  end)

  it("DeepSeek Anthropic：output_config.effort（budget 被忽略）", function(t)
    local body = assert(capture_reasoning("ds-anthropic", DS_ANTHROPIC, "deepseek-flash", {}, { reasoning_effort = "low" }))
    t.eq("low", body.output_config.effort)
    t.nil_(body.thinking)
    t.eq(1, body.temperature)
  end)

  it("DeepSeek Anthropic：reasoning_enabled=false 关闭思考", function(t)
    local body = assert(capture_reasoning("ds-anthropic", DS_ANTHROPIC, "deepseek-flash", { reasoning_enabled = false, temperature = 0.3 }))
    t.eq("disabled", body.thinking.type)
    t.nil_(body.output_config)
    t.eq(0.3, body.temperature)
  end)

  it("原生 Anthropic：仍使用 budget_tokens（不回归）", function(t)
    local body = assert(capture_reasoning("anthropic", DS_ANTHROPIC, "claude-x", { reasoning_budget = 1024 }))
    t.eq("enabled", body.thinking.type)
    t.eq(1024, body.thinking.budget_tokens)
    t.nil_(body.output_config)
  end)
end)
