--- 健康检查与诊断测试
--- @module 'NeoAI.tests.test_health'

local tests = require("NeoAI.tests")

tests.suite("health", function(_, it)
  it("collect 返回结构化检查项，含必需项", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "deepseek",
        providers = {
          deepseek = { api_type = "openai", base_url = "http://d", api_key = "k" },
        },
      },
    })
    local h = require("NeoAI.health")
    local items = h.collect()
    t.true_(#items > 0)
    local names = {}
    for _, it2 in ipairs(items) do
      t.not_nil(it2.name)
      t.true_(it2.status == "ok" or it2.status == "warn" or it2.status == "error", "状态应为 ok/warn/error")
      t.not_nil(it2.info)
      names[it2.name] = it2.status
    end
    t.not_nil(names["Neovim 版本"], "应含 Neovim 版本检查")
    t.not_nil(names["API Key"], "应含 API Key 检查")
  end)

  it("无任何 api_key 时 API Key 项为 error", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ ai = { default_provider = "deepseek" } })
    -- 整体替换 providers，排除默认配置里由环境变量注入的 key（环境相关，需确定性）。
    config_store.set("ai.providers", {
      deepseek = { api_type = "openai", base_url = "http://d", api_key = "" },
    })
    local h = require("NeoAI.health")
    local status
    for _, it2 in ipairs(h.collect()) do
      if it2.name == "API Key" then status = it2.status end
    end
    t.eq("error", status, "无可用 key 应为 error")
  end)

  it("默认 provider 无 key 但其他有 key 时为 warn", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ ai = { default_provider = "deepseek" } })
    config_store.set("ai.providers", {
      deepseek = { api_type = "openai", base_url = "http://d", api_key = "" },
      openai = { api_type = "openai", base_url = "http://o", api_key = "ok" },
    })
    local h = require("NeoAI.health")
    local status
    for _, it2 in ipairs(h.collect()) do
      if it2.name == "API Key" then status = it2.status end
    end
    t.eq("warn", status, "默认 provider 缺 key 应为 warn")
  end)

  it("含沙箱网络同意诊断项，host_local_block=false 时为 warn", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.set("tools.sandbox.offline", false)
    config_store.set("tools.sandbox.network.gateway.enabled", false)
    config_store.set("tools.sandbox.network.host_local_block", false)
    local h = require("NeoAI.health")
    local found
    for _, it2 in ipairs(h.collect()) do
      if it2.name == "沙箱网络同意" then found = it2 end
    end
    t.not_nil(found, "应含沙箱网络同意检查")
    t.eq("warn", found.status, "host_local_block=false 应为 warn（网络不经同意门禁）")
  end)

  it("summary 为多行文本且含标题", function(t)
    local h = require("NeoAI.health")
    local s = h.summary()
    t.true_(s:find("NeoAI 诊断", 1, true) ~= nil)
  end)
end)
