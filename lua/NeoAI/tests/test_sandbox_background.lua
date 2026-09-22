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

  it("resident：输出含控制字节/NUL 不破坏帧定界（base64 承载）", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local resident = require("NeoAI.sandbox.resident")
    if not resident.available() then return end
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = resident_sandbox_config() },
    }, function()
      require("NeoAI.sandbox").reset()
      local out, done = nil, false
      -- 输出同时包含帧定界控制字节（\x1e/\x1f）、NUL 与伪造 END 标记。
      require("NeoAI.tools").execute("run_command",
        { command = "printf 'A\\036END 1 0\\037B\\000C'", description = "t" }, {})
        :then_(function(v) out = tostring(v); done = true end, function() done = true end)
      t.true_(vim.wait(20000, function() return done end, 50), "应返回")
      t.not_nil(out, "应有输出")
      t.true_(out:find("A\30END 1 0\31B\0C", 1, true) ~= nil,
        "控制字节与 NUL 应原样保留（base64 帧），实际: " .. vim.inspect(out))
      resident.stop({ timeout_ms = 5000 })
    end)
  end)

  it("resident：服务器意外退出后自动重建实例并执行命令", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local resident = require("NeoAI.sandbox.resident")
    if not resident.available() then return end
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = resident_sandbox_config() },
    }, function()
      require("NeoAI.sandbox").reset()
      local tools = require("NeoAI.tools")
      -- 先建实例
      local d0 = false
      tools.execute("run_command", { command = "echo WARM", description = "t" }, {})
        :then_(function() d0 = true end, function() d0 = true end)
      t.true_(vim.wait(20000, function() return d0 end, 50), "预热应返回")
      local inst = resident.active()
      t.not_nil(inst, "应存在常驻实例")
      -- 直接杀掉服务器（模拟外层 OOM/信号），不调用 stop（保留 ensure_opts）。
      vim.fn.jobstop(inst.job)
      t.true_(vim.wait(5000, function() return not inst.alive end, 20), "服务器应退出")
      t.eq(nil, resident.active(), "已退出的实例不应为 active")
      -- 下一次 exec 应据 ensure_opts 自动重建并成功执行。
      local out, done = nil, false
      resident.exec("echo RECOVERED", {}):then_(
        function(r) out = r; done = true end, function(e) out = { err = e }; done = true end)
      t.true_(vim.wait(20000, function() return done end, 50), "重试应返回")
      t.not_nil(out and out.code, "应有结果")
      t.eq(0, out.code)
      t.true_(tostring(out.stdout):find("RECOVERED", 1, true) ~= nil, "应执行成功")
      resident.stop({ timeout_ms = 5000 })
    end)
  end)

  it("resident：大文件物化走收件箱复制（不内嵌内容）且命令可见", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local resident = require("NeoAI.sandbox.resident")
    if not resident.available() then return end
    -- 极小上限：用 200KB 文件即触发「大文件」路径，测试保持快速。
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = resident_sandbox_config({ max_file_bytes = 65536 }),
      },
    }, function()
      require("NeoAI.sandbox").reset()
      local tools = require("NeoAI.tools")
      local big = (vim.fn.stdpath("cache") .. "/NeoAI/tests_resident_big.bin"):gsub("/+$", "")
      pcall(os.remove, big)
      local d1 = false
      tools.execute("run_command",
        { command = "dd if=/dev/zero of=" .. big .. " bs=1024 count=200 2>/dev/null; echo made", description = "t" }, {})
        :then_(function() d1 = true end, function() d1 = true end)
      t.true_(vim.wait(20000, function() return d1 end, 50), "生成大文件应返回")
      t.not_nil(resident.active(), "应存在常驻实例")
      -- 第二条命令：常驻物化必须把该大文件送进沙箱视图（走 c 复制），命令应读到完整字节数。
      local out, d2 = nil, false
      tools.execute("run_command",
        { command = "wc -c < " .. big, description = "t" }, {})
        :then_(function(v) out = v; d2 = true end, function() d2 = true end)
      t.true_(vim.wait(20000, function() return d2 end, 50), "读取大文件应返回")
      t.matches("204800", tostring(out), "大文件应经收件箱复制后在沙箱内可见")
      resident.stop({ timeout_ms = 5000 })
      pcall(os.remove, big)
    end)
  end)

  it("run_command：非常驻（resident 关闭）时后台意图给出 UI 提示", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = resident_sandbox_config({ resident = { enabled = false } }),
      },
    }, function()
      require("NeoAI.sandbox").reset()
      local ctx = {}
      local done = false
      require("NeoAI.tools").execute("run_command",
        { command = "sleep 1 &", description = "t" }, ctx)
        :then_(function() done = true end, function() done = true end)
      t.true_(vim.wait(20000, function() return done end, 50), "应返回")
      t.not_nil(ctx.ui_notice, "应给出后台进程不存活的 UI 提示")
      t.matches("后台", ctx.ui_notice)
    end)
  end)
end)
