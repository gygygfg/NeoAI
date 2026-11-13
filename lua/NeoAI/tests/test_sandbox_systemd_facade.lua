--- 沙箱 systemctl 门面测试：门面 start/stop/status 与 enable/disable 视图
--- @module 'NeoAI.tests.test_sandbox_systemd_facade'
--- 门面 start/stop/status/is-active、基线系统单元、enable/mask/power 错误、
--- enable/disable 待审虚拟视图。
---
--- 拆分自原 `test_sandbox_systemd.lua`：systemd 用例含真实定时器/重启等待，单文件串行会把整轮
--- 测试拖成长尾；按主题拆分后由并行运行器（heavy lane）同时执行以压缩总时长。

local tests = require("NeoAI.tests")
local helpers = require("NeoAI.tests.sandbox_systemd_helpers")

local with_config = helpers.with_config
local write_unit = helpers.write_unit
local systemd_config = helpers.systemd_config
local run_plan = helpers.run_plan

tests.suite("sandbox_systemd_facade", function(_, it)
  it("门面：start 静默成功、status/is-active 合成真实输出、stop 移除服务", function(t)
    if tests.requires_sandbox() then return end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "demo.service",
      "[Unit]\nDescription=Demo\n[Service]\nType=simple\nWorkingDirectory=" .. dir
      .. "\nExecStart=/bin/sleep 30\n")
    write_unit(dir, "bad.service", "[Service]\nType=simple\n")

    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local svc = require("NeoAI.sandbox.execution.service")

      local sres = run_plan(sd, sd.parse_command("systemctl start demo.service"), 10000)
      t.eq(0, sres.code, tostring(sres.stderr))
      t.eq("", sres.stdout, "start 成功应静默（真实 systemctl 行为）")
      t.not_nil(svc.status("unit:demo.service"), "服务应已注册")

      local stext = run_plan(sd, sd.parse_command("systemctl status demo.service"))
      t.matches("active", stext.stdout or "")
      t.eq(0, stext.code)

      local atext = run_plan(sd, sd.parse_command("systemctl is-active demo.service"))
      t.eq("active", (atext.stdout or ""):gsub("%s+$", ""))
      t.eq(0, atext.code)

      local bres = run_plan(sd, sd.parse_command("systemctl start bad.service"))
      t.true_((bres.code or 0) ~= 0, "无效单元应非零退出")
      t.matches("ExecStart", tostring(bres.stderr or ""), "应透传真实原因（而非笼统权限错误）")
      t.true_(not tostring(bres.stderr or ""):find("沙箱", 1, true), "错误不应暴露沙箱")

      local sdone
      sd.handle(assert(sd.parse_command("systemctl stop demo.service"))):then_(
        function() sdone = true end, function() sdone = true end)
      t.true_(vim.wait(10000, function() return sdone end, 20), "stop 应返回")
      t.eq(nil, svc.status("unit:demo.service"), "停止后应移除")
    end)
    vim.fn.delete(dir, "rf")
  end)



  it("门面：enable/reload/mask/power 返回真实错误（不暴露沙箱）", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local function run(argv)
      local res
      sd.exec(argv):then_(function(v) res = v end, function(e) res = { err = e } end)
      t.true_(vim.wait(3000, function() return res end, 10))
      return res
    end
    local en = run({ "systemctl", "enable", "nosuch.service" })
    t.true_((en.code or 0) ~= 0)
    t.matches("does not exist", en.stderr or "")
    local rl = run({ "systemctl", "reload", "foo.service" })
    t.true_((rl.code or 0) ~= 0)
    t.matches("reload", rl.stderr or "")
    local pw = run({ "systemctl", "poweroff" })
    t.matches("Access denied", pw.stderr or "")
    for _, r in ipairs({ en, rl, pw }) do
      t.true_(not tostring(r.stdout or ""):find("沙箱", 1, true))
      t.true_(not tostring(r.stderr or ""):find("沙箱", 1, true))
    end
  end)



  it("systemctl：基线系统单元 start/stop/restart 幂等成功（不再权限拒绝）", function(t)
    with_config({ tools = { sandbox = systemd_config({}) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local rr = run_plan(sd, sd.parse_command("systemctl restart systemd-journald.service"), 2000)
      t.eq(0, rr.code, tostring(rr.stderr))
      t.eq("", rr.stdout or "", "restart 成功应静默")
      local stop = run_plan(sd, sd.parse_command("systemctl stop systemd-journald.service"), 2000)
      t.eq(0, stop.code)
      local off = run_plan(sd, sd.parse_command("systemctl is-active systemd-journald.service"), 2000)
      t.eq("inactive", (off.stdout or ""):gsub("%s+$", ""))
      local start = run_plan(sd, sd.parse_command("systemctl start systemd-journald.service"), 2000)
      t.eq(0, start.code)
      local on = run_plan(sd, sd.parse_command("systemctl is-active systemd-journald.service"), 2000)
      t.eq("active", (on.stdout or ""):gsub("%s+$", ""))
    end)
  end)



  it("enable/disable 待审虚拟视图：is-enabled 在审批前即反映 enable/disable", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "pend.service",
      "[Unit]\nDescription=Pend\n[Install]\nWantedBy=multi-user.target\n[Service]\nExecStart=/bin/true\n")
    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local before = run_plan(sd, sd.parse_command("systemctl is-enabled pend.service"), 2000)
      t.eq("disabled", (before.stdout or ""):gsub("%s+$", ""))
      local en = run_plan(sd, sd.parse_command("systemctl enable pend.service"), 2000)
      t.eq(0, en.code, tostring(en.stderr))
      t.matches("Created symlink", en.stdout or "")
      local after = run_plan(sd, sd.parse_command("systemctl is-enabled pend.service"), 2000)
      t.eq("enabled", (after.stdout or ""):gsub("%s+$", ""))
      t.eq(0, after.code)
      local lf = run_plan(sd, sd.parse_command("systemctl list-unit-files --type=service"), 2000)
      t.matches("pend%.service%s+enabled", lf.stdout or "")
      local dis = run_plan(sd, sd.parse_command("systemctl disable pend.service"), 2000)
      t.eq(0, dis.code, tostring(dis.stderr))
      local off = run_plan(sd, sd.parse_command("systemctl is-enabled pend.service"), 2000)
      t.eq("disabled", (off.stdout or ""):gsub("%s+$", ""))
    end)
    vim.fn.delete(dir, "rf")
  end)

end)
