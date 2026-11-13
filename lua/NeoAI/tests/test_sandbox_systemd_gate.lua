--- 沙箱 systemctl 门面测试：门禁路由（run_command → 沙箱服务）
--- @module 'NeoAI.tests.test_sandbox_systemd_gate'
--- run_command 的 systemctl/systemd-analyze 路由、查询类动词退出码、沙箱私��视图
--- （/run/systemd/system、/etc/systemd/system 写入对门面可见）。
---
--- 拆分自原 `test_sandbox_systemd.lua`：systemd 用例含真实定时器/重启等待，单文件串行会把整轮
--- 测试拖成长尾；按主题拆分后由并行运行器（heavy lane）同时执行以压缩总时长。

local tests = require("NeoAI.tests")
local helpers = require("NeoAI.tests.sandbox_systemd_helpers")

local with_config = helpers.with_config
local write_unit = helpers.write_unit
local systemd_config = helpers.systemd_config
local run_plan = helpers.run_plan

tests.suite("sandbox_systemd_gate", function(_, it)
  it("门禁：run_command 的 systemctl 被路由到沙箱服务", function(t)
    if tests.requires_sandbox() then return end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "gate.service",
      "[Service]\nType=simple\nWorkingDirectory=" .. dir .. "\nExecStart=/bin/sleep 30\n")
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = systemd_config({ dir }),
      },
    }, function()
      require("NeoAI.sandbox").reset()
      local done, err, text
      require("NeoAI.tools").execute("run_command",
        { command = "systemctl start gate.service", description = "t" }, {})
        :then_(function(v) text = v; done = true end, function(e) err = e; done = true end)
      t.true_(vim.wait(15000, function() return done end, 50), "应返回")
      t.eq(nil, err, tostring(err and (err.message or err)))
      t.eq("", tostring(text or ""), "start 成功应静默")
      local svc = require("NeoAI.sandbox.execution.service")
      t.not_nil(svc.status("unit:gate.service"), "服务应已注册")
      svc.stop_all({ timeout_ms = 10000 })
    end)
    vim.fn.delete(dir, "rf")
  end)


  it("门禁：查询类动词非零退出不包装为工具失败（ok:false）", function(t)
    if tests.requires_sandbox() then return end
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = systemd_config({}) },
    }, function()
      require("NeoAI.sandbox").reset()
      local done, text, err = false, nil, nil
      require("NeoAI.tools").execute("run_command",
        { command = "systemctl is-active nosuch.service", description = "t" }, {})
        :then_(function(v) text = v; done = true end, function(e) err = e; done = true end)
      t.true_(vim.wait(15000, function() return done end, 50), "应返回")
      t.eq(nil, err, tostring(err and (err.message or err)))
      t.true_(not tostring(text):find('"ok":false', 1, true),
        "is-active 非零退出不应被当作工具失败: " .. tostring(text))
      t.matches("inactive", tostring(text))
    end)
  end)


  it("门禁：systemd-analyze 经门面返回合成数据（不报无法连接总线）", function(t)
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = systemd_config({}) },
    }, function()
      require("NeoAI.sandbox").reset()
      local done, text, err = false, nil, nil
      require("NeoAI.tools").execute("run_command",
        { command = "systemd-analyze time", description = "t" }, {})
        :then_(function(v) text = v; done = true end, function(e) err = e; done = true end)
      t.true_(vim.wait(15000, function() return done end, 50), "应返回")
      t.eq(nil, err, tostring(err and err.message))
      t.matches("Startup finished in", tostring(text))
      t.true_(not tostring(text):find("connect to", 1, true), "不应报总线连接失败")
    end)
  end)


  it("门面读取沙箱私有视图：/run/systemd/system 会话目录中的单元可见", function(t)
    local runtime = require("NeoAI.sandbox.execution.runtime")
    local host = runtime.host_tmp_dir("/run") .. "/systemd/system/__probe_view.service"
    vim.fn.mkdir(vim.fn.fnamemodify(host, ":h"), "p")
    local f = assert(io.open(host, "w"))
    f:write("[Unit]\nDescription=View Probe\n[Service]\nType=oneshot\nExecStart=/bin/true\n")
    f:close()
    local ok, err = pcall(function()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local cat = run_plan(sd, sd.parse_command("systemctl cat __probe_view.service"), 2000)
      t.eq(0, cat.code, tostring(cat.stderr))
      t.matches("View Probe", cat.stdout or "")
      t.eq("facade", sd.parse_command("systemctl start __probe_view.service").route)
    end)
    os.remove(host)
    if not ok then error(err, 0) end
  end)


  it("门禁：沙箱内写入 /run/systemd/system 的单元对 systemctl 可见", function(t)
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = systemd_config({}) },
    }, function()
      require("NeoAI.sandbox").reset()
      local tools = require("NeoAI.tools")
      local function run(cmd)
        local out, done = nil, false
        tools.execute("run_command", { command = cmd, description = "t", timeout_ms = 20000 }, {}):then_(
          function(v) out = tostring(v); done = true end,
          function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
        vim.wait(25000, function() return done end, 50)
        return out
      end
      run("printf '[Unit]\\nDescription=Run Unit View\\n[Service]\\nType=oneshot\\nExecStart=/bin/true\\n'"
        .. " > /run/systemd/system/__probe_run_unit.service")
      t.matches("Run Unit View", run("systemctl cat __probe_run_unit.service"))
      t.matches("rc=0", run("systemctl start __probe_run_unit.service; echo rc=$?"))
    end)
  end)


  it("门禁：沙箱内写入 /etc/systemd/system 的单元对 systemctl 可见", function(t)
    with_config({
      tools = { approval = { mode = "auto_allow" }, sandbox = systemd_config({}) },
    }, function()
      require("NeoAI.sandbox").reset()
      local tools = require("NeoAI.tools")
      local function run(cmd)
        local out, done = nil, false
        tools.execute("run_command", { command = cmd, description = "t", timeout_ms = 20000 }, {}):then_(
          function(v) out = tostring(v); done = true end,
          function(e) out = "ERR:" .. tostring(e and e.message or e); done = true end)
        vim.wait(25000, function() return done end, 50)
        return out
      end
      local w = run("printf '[Unit]\\nDescription=Etc Unit\\n[Service]\\nType=oneshot\\nExecStart=/bin/true\\n'"
        .. " > /etc/systemd/system/__probe_etc_unit.service 2>&1 && echo WROTE")
      if not tostring(w):find("WROTE", 1, true) then return end -- 环境无整机可写 overlay：跳过
      t.matches("Etc Unit", run("systemctl cat __probe_etc_unit.service"))
    end)
  end)

end)
