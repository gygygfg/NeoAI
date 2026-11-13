--- 命令插件（plugins.builtin.commands）专项测试
--- @module 'NeoAI.tests.test_commands_plugin'
--- 覆盖聚合命令 `:NeoAI <子命令>` 的注册/卸载清理契约（AGENTS 约定 2）、
--- 子命令补全行为与服务缺失降级。
local tests = require("NeoAI.tests")

tests.suite("commands_plugin", function(_, it)
  local commands = require("NeoAI.plugins.builtin.commands")
  local services = require("NeoAI.kernel.services")

  local function exists(name)
    return vim.fn.exists(":" .. name) == 2
  end

  it("SUBCOMMANDS 非空且无重复，且都带说明", function(t)
    t.true_(#commands.SUBCOMMANDS > 20, "应登记全部 NeoAI 子命令")
    local seen = {}
    for _, spec in ipairs(commands.SUBCOMMANDS) do
      t.eq("string", type(spec.name), "子命令名必须是字符串")
      t.true_(#spec.name > 0)
      t.nil_(seen[spec.name], "子命令名重复: " .. tostring(spec.name))
      t.eq("function", type(spec.handler), "子命令缺少 handler: " .. tostring(spec.name))
      t.eq("string", type(spec.desc), "子命令缺少 desc: " .. tostring(spec.name))
      seen[spec.name] = true
    end
  end)

  it("NAMES 与 SUBCOMMANDS 同步，subcommand_descs 覆盖全部子命令", function(t)
    t.eq(#commands.SUBCOMMANDS, #commands.NAMES)
    local descs = commands.subcommand_descs()
    for _, n in ipairs(commands.NAMES) do
      t.true_(descs[n] ~= nil, n .. " 缺少说明")
    end
  end)

  it("start 只注册单条 :NeoAI 命令，cleanup 删除", function(t)
    local cleanup = commands.start()
    t.true_(exists("NeoAI"), ":NeoAI 应已注册")
    -- 旧的平铺命令不再注册
    t.false_(exists("NeoAIOpen"), ":NeoAI Open 不应再注册")
    t.false_(exists("NeoAISandboxList"), ":NeoAI SandboxList 不应再注册")
    cleanup()
    t.false_(exists("NeoAI"), ":NeoAI 应已删除")
    commands.start() -- 恢复供后续用例/套件使用
  end)

  it("start 幂等：重复调用与重复清理均安全", function(t)
    local c1 = commands.start()
    local c2 = commands.start()
    t.true_(exists("NeoAI"))
    c1()
    c2() -- 已删除后再次删除应静默
    commands.start()
    t.true_(exists("NeoAI"))
  end)

  it("complete 按 arglead 前缀过滤，且只补全第一个参数", function(t)
    local all = commands.complete("", "NeoAI ", 7)
    t.eq(#commands.SUBCOMMANDS, #all, "空 arglead 应返回全部子命令")

    local s = commands.complete("Sandbox", "NeoAI Sandbox", 14)
    t.true_(#s > 0, "应匹配 Sandbox* 前缀")
    for _, name in ipairs(s) do
      t.eq("Sandbox", name:sub(1, 7), "候选应全部以 Sandbox 开头: " .. name)
    end

    local exact = commands.complete("Open", "NeoAI Open", 11)
    t.eq(1, #exact)
    t.eq("Open", exact[1])

    -- 已在输入第二个参数时不再补全子命令
    local second = commands.complete("Sandbox", "NeoAI Open Sandbox", 18)
    t.eq(0, #second, "补全第二个参数时不应返回子命令")

    -- 无匹配前缀返回空
    local none = commands.complete("Zzz", "NeoAI Zzz", 10)
    t.eq(0, #none)
  end)

  it("WindowMode 第二个参数补全 tab/float/split", function(t)
    local full = "NeoAI WindowMode "
    t.eq(3, #commands.complete("", full, #full), "空 arglead 应返回全部模式")
    local f = commands.complete("f", full .. "f", #full + 1)
    t.eq(1, #f, "前缀过滤")
    t.eq("float", f[1])
    local none = commands.complete("z", full .. "z", #full + 1)
    t.eq(0, #none, "无匹配前缀返回空")
    -- 其它子命令的第二参数仍不补全
    local other = "NeoAI Open z"
    t.eq(0, #commands.complete("z", other, #other))
  end)

  it("分发未知子命令给出用法提示且不抛错", function(t)
    local notified = nil
    local orig = vim.notify
    vim.notify = function(msg) notified = msg end
    local ok = pcall(vim.cmd, "NeoAI NoSuchSubCommand")
    vim.notify = orig
    t.true_(ok, "未知子命令不应抛错")
    t.true_(type(notified) == "string" and notified:find("未知子命令", 1, true) ~= nil,
      "应提示未知子命令")
  end)

  it("服务缺失时子命令静默降级不抛错", function(t)
    local saved = services.use("services.ui")
    services.revoke("services.ui")
    local ok1 = pcall(vim.cmd, "NeoAI ChatStatus")
    local ok2 = pcall(vim.cmd, "NeoAI Tree")
    if saved then services.provide("services.ui", saved) else services.revoke("services.ui") end
    t.true_(ok1, "缺 ui 服务时 :NeoAI ChatStatus 不应抛错")
    t.true_(ok2, "缺 ui 服务时 :NeoAI Tree 不应抛错")
  end)
end)
