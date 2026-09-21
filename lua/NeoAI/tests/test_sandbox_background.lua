--- 沙箱后台命令门面测试
--- @module NeoAI.tests.test_sandbox_background
--- 覆盖：`&`/nohup/setsid 识别（保守，避免误判 &&/重定向/中段 &）；run_command 后台命令自动
--- 转为长驻服务（跨调用存活）并可从注册表管理与停止；非后台命令保持一次性执行。

local tests = require("NeoAI.tests")

local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  local merged = vim.deepcopy(overrides or {})
  merged.tools = merged.tools or {}
  merged.tools.sandbox = merged.tools.sandbox or {}
  if merged.tools.sandbox.ephemeral_roots == nil then
    merged.tools.sandbox.ephemeral_roots = {}
  end
  config_store.load(merged)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

tests.suite("sandbox_background", function(_, it)
  it("background.parse：识别 & / nohup / setsid，排除 && / 重定向 / 中段 &", function(t)
    local bg = require("NeoAI.sandbox.background")
    local a = bg.parse("sleep 30 &")
    t.not_nil(a, "终止 & 应识别")
    t.eq("amp", a.kind)
    t.eq("sleep 30", a.command)

    local b = bg.parse("nohup server > /tmp/log 2>&1")
    t.not_nil(b, "前导 nohup 应识别")
    t.eq("nohup", b.kind)
    t.matches("server", b.command)

    local c = bg.parse("setsid /usr/bin/server &")
    t.not_nil(c, "setsid + & 应识别")
    t.eq("amp", c.kind)
    t.matches("server", c.command)

    t.eq(nil, bg.parse("echo a && echo b"), "&& 不应识别")
    t.eq(nil, bg.parse("echo a 2>&1"), "2>&1 不应识别")
    t.eq(nil, bg.parse("echo a & echo b"), "中段 & 不应识别")
    t.eq(nil, bg.parse("echo 'a &'"), "引号内 & 不应识别")
    t.eq(nil, bg.parse(""), "空命令不应识别")
  end)

  it("run_command：后台命令自动转为长驻服务并可停止", function(t)
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = {
          enabled = true, fail_closed = true, mode = "dry_run",
          ephemeral_roots = {}, service = { enabled = true, auto_background = true },
        },
      },
    }, function()
      require("NeoAI.sandbox").reset()
      local svc_mod = require("NeoAI.sandbox.service")
      local result, err
      local done = false
      require("NeoAI.tools").execute("run_command",
        { command = "sleep 30 &", description = "t" }, {})
        :then_(function(v) result = v; done = true end, function(e) err = e; done = true end)
      t.true_(vim.wait(15000, function() return done end, 50), "应返回")
      t.eq(nil, err, "不应报错: " .. tostring(err and (err.message or err)))
      t.eq("string", type(result), "结果应为文本")
      t.matches("长驻服务", result)
      local list = svc_mod.list()
      t.eq(1, #list, "应注册一个长驻服务")
      t.matches("^bg_", list[1].name, "服务名应以 bg_ 前缀")
      svc_mod.stop_all({ timeout_ms = 10000 })
      t.eq(0, #svc_mod.list(), "stop_all 后应清空")
    end)
  end)

  it("run_command：非后台命令保持一次性执行，不注册服务", function(t)
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = {
          enabled = true, fail_closed = true, mode = "dry_run",
          ephemeral_roots = {}, service = { enabled = true, auto_background = true },
        },
      },
    }, function()
      require("NeoAI.sandbox").reset()
      local svc_mod = require("NeoAI.sandbox.service")
      local result, err
      local done = false
      require("NeoAI.tools").execute("run_command",
        { command = "echo a && echo b", description = "t" }, {})
        :then_(function(v) result = v; done = true end, function(e) err = e; done = true end)
      t.true_(vim.wait(15000, function() return done end, 50), "应返回")
      t.eq(nil, err, "不应报错: " .. tostring(err and (err.message or err)))
      t.matches("b", tostring(result), "应执行并返回输出")
      t.eq(0, #svc_mod.list(), "非后台命令不应注册服务")
    end)
  end)

  it("run_command：auto_background=false 时后台命令仍一次性执行（保持旧行为）", function(t)
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = {
          enabled = true, fail_closed = true, mode = "dry_run",
          ephemeral_roots = {}, service = { enabled = true, auto_background = false },
        },
      },
    }, function()
      require("NeoAI.sandbox").reset()
      local svc_mod = require("NeoAI.sandbox.service")
      local done = false
      require("NeoAI.tools").execute("run_command",
        { command = "sleep 30 &", description = "t" }, {})
        :then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(15000, function() return done end, 50), "应返回")
      t.eq(0, #svc_mod.list(), "关闭自动提升时不应注册服务")
    end)
  end)
end)
