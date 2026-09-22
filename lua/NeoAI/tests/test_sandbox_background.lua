--- 沙箱后台进程（会话级常驻实例）测试
--- @module NeoAI.tests.test_sandbox_background
--- 覆盖：`&`/nohup/setsid 识别（保守，避免误判 &&/重定向/中段 &）；会话级常驻沙箱实例使
--- `run_command` 的后台进程跨工具调用存活（同一命名空间内 `ps` 可见）；非后台命令正常返回。

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

local function resident_sandbox_config(extra)
  local base = {
    enabled = true, fail_closed = true, mode = "dry_run",
    ephemeral_roots = {}, resident = { enabled = true },
  }
  for k, v in pairs(extra or {}) do base[k] = v end
  return base
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

  it("run_command：后台进程跨调用存活（会话级常驻沙箱）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local resident = require("NeoAI.sandbox.resident")
    if not resident.available() then return end
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = resident_sandbox_config() },
    }, function()
      require("NeoAI.sandbox").reset()
      local tools = require("NeoAI.tools")
      local done, err = false, nil
      tools.execute("run_command",
        { command = "sleep 30 & echo started", description = "t" }, {})
        :then_(function() done = true end, function(e) err = e; done = true end)
      t.true_(vim.wait(15000, function() return done end, 50), "应返回")
      t.eq(nil, err, "不应报错: " .. tostring(err and (err.message or err)))
      t.not_nil(resident.active(), "应存在常驻实例")
      -- 第二条命令在同一命名空间内应能看到上一条启动的后台进程。
      local out, done2 = nil, false
      tools.execute("run_command",
        { command = "ps -e -o args 2>/dev/null | grep '[s]leep 30' | wc -l", description = "t" }, {})
        :then_(function(v) out = v; done2 = true end, function() done2 = true end)
      t.true_(vim.wait(15000, function() return done2 end, 50), "应返回")
      t.matches("[1-9]", tostring(out), "后台进程应跨调用存活")
      resident.stop({ timeout_ms = 5000 })
    end)
  end)

  it("run_command：非后台命令正常返回输出", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = resident_sandbox_config() },
    }, function()
      require("NeoAI.sandbox").reset()
      local result, err, done = nil, nil, false
      require("NeoAI.tools").execute("run_command",
        { command = "echo a && echo b", description = "t" }, {})
        :then_(function(v) result = v; done = true end, function(e) err = e; done = true end)
      t.true_(vim.wait(15000, function() return done end, 50), "应返回")
      t.eq(nil, err, "不应报错: " .. tostring(err and (err.message or err)))
      t.matches("b", tostring(result), "应执行并返回输出")
      require("NeoAI.sandbox.resident").stop({ timeout_ms = 5000 })
    end)
  end)
end)
