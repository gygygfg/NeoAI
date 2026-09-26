--- 命令插件（plugins.builtin.commands）专项测试
--- @module NeoAI.tests.test_commands_plugin
--- 覆盖命令注册/卸载清理契约（AGENTS 约定 2）与服务缺失降级。
local tests = require("NeoAI.tests")

tests.suite("commands_plugin", function(_, it)
  local commands = require("NeoAI.plugins.builtin.commands")
  local services = require("NeoAI.kernel.services")

  local function exists(name)
    return vim.fn.exists(":" .. name) == 2
  end

  it("NAMES 非空且无重复", function(t)
    t.ok(#commands.NAMES > 20, "应登记全部 NeoAI 命令")
    local seen = {}
    for _, n in ipairs(commands.NAMES) do
      t.nil_(seen[n], "命令名重复: " .. n)
      seen[n] = true
    end
  end)

  it("start 注册全部命令，cleanup 全部删除", function(t)
    local cleanup = commands.start()
    for _, n in ipairs(commands.NAMES) do t.true_(exists(n), n .. " 应已注册") end
    cleanup()
    for _, n in ipairs(commands.NAMES) do t.false_(exists(n), n .. " 应已删除") end
    commands.start() -- 恢复供后续用例/套件使用
  end)

  it("start 幂等：重复调用与重复清理均安全", function(t)
    local c1 = commands.start()
    local c2 = commands.start()
    for _, n in ipairs(commands.NAMES) do t.true_(exists(n)) end
    c1()
    c2() -- 已删除后再次删除应静默
    commands.start()
    t.true_(exists("NeoAITest"))
  end)

  it("服务缺失时命令静默降级不抛错", function(t)
    local saved = services.use("services.ui")
    services.revoke("services.ui")
    local ok1 = pcall(vim.cmd, "NeoAIChatStatus")
    local ok2 = pcall(vim.cmd, "NeoAITree")
    if saved then services.provide("services.ui", saved) else services.revoke("services.ui") end
    t.true_(ok1, "缺 ui 服务时 NeoAIChatStatus 不应抛错")
    t.true_(ok2, "缺 ui 服务时 NeoAITree 不应抛错")
  end)
end)
