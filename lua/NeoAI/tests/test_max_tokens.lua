--- max_tokens 发送策略测试
--- @module NeoAI.tests.test_max_tokens
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
    local body = capture_body("deepseek", { provider = "deepseek", model = "m1", temperature = 0.5 })
    t.not_nil(body, "请求体应被捕获")
    t.nil_(body.max_tokens, "未配置不应发送 max_tokens")
  end)

  it("显式配置 max_tokens 时按值发送", function(t)
    local body = capture_body("deepseek", { provider = "deepseek", model = "m1", temperature = 0.5, max_tokens = 1234 })
    t.eq(1234, body.max_tokens, "显式值应原样发送")
  end)

  it("Anthropic 必填协议未配置时用能力表兜底", function(t)
    local body = capture_body("anthropic", { provider = "anthropic", model = "m1", temperature = 0.5 })
    t.not_nil(body.max_tokens, "Anthropic max_tokens 必填，应有兜底值")
    t.true_(body.max_tokens > 0, "兜底值应为正数")
  end)
end)
