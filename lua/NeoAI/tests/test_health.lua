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

  it("沙箱内核能力项与 runtime.backend() 同源：有后端 ok，无后端 warn 且点名缺 bwrap", function(t)
    local h = require("NeoAI.health")
    local item
    for _, it2 in ipairs(h.collect()) do
      if it2.name == "沙箱内核能力" then item = it2 end
    end
    t.not_nil(item, "应含沙箱内核能力检查")
    t.true_(item.status == "ok" or item.status == "warn", "状态应为 ok/warn（无 error）")
    local text = table.concat(item.info, "\n")
    t.matches("bwrap", text, "文案应点名 bwrap（不再是笼统的「不可用」）")
    t.true_(text:find("详见 :NeoAISandboxCaps", 1, true) ~= nil, "应保留诊断入口")
    -- docker 不参与隔离后端：无论是否安装都不应作为能力列出
    t.true_(text:find("可用工具: ", 1, true) == nil, "不应再输出「可用工具: docker」式的笼统列表")

    local runtime = require("NeoAI.sandbox.execution.runtime")
    local available = runtime.isolation_available()
    if not available then
      t.eq("warn", item.status, "无隔离后端时应为 warn")
      t.matches("退回审批", text, "无后端时应说明退回审批模式")
    else
      t.eq("ok", item.status, "有隔离后端时应为 ok")
    end
  end)
end)
