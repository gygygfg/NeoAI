--- 沙箱 systemctl 门面测试：定时器（OnActiveSec / --on-active）
--- @module 'NeoAI.tests.test_sandbox_systemd_timer'
--- `.timer` OnActiveSec 到点激活、`systemd-run --on-active` 瞬态定时器
--- （含真实等待，单独成片以免阻塞其它 systemd 用例）。
---
--- 拆分自原 `test_sandbox_systemd.lua`：systemd 用例含真实定时器/重启等待，单文件串行会把整轮
--- 测试拖成长尾；按主题拆分后由并行运行器（heavy lane）同时执行以压缩总时长。

local tests = require("NeoAI.tests")
local helpers = require("NeoAI.tests.sandbox_systemd_helpers")

local with_config = helpers.with_config
local write_unit = helpers.write_unit
local systemd_config = helpers.systemd_config
local run_plan = helpers.run_plan

tests.suite("sandbox_systemd_timer", function(_, it)
  it(".timer：OnActiveSec 到点激活被触发单元，status/list-timers 可见", function(t)
    if tests.requires_sandbox() then return end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "tick.service",
      "[Unit]\nDescription=Tick\n[Service]\nType=oneshot\nExecStart=/bin/echo TIMER_FIRED_MARKER\n")
    write_unit(dir, "tick.timer", "[Unit]\nDescription=TickTimer\n[Timer]\nOnActiveSec=1\nUnit=tick.service\n")
    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local ts = run_plan(sd, sd.parse_command("systemctl start tick.timer"), 5000)
      t.eq(0, ts.code, tostring(ts.stderr))
      local waiting = run_plan(sd, sd.parse_command("systemctl status tick.timer"), 2000)
      t.matches("waiting", waiting.stdout or "")
      local lt = run_plan(sd, sd.parse_command("systemctl list-timers"), 2000)
      t.matches("tick%.timer", lt.stdout or "")
      t.matches("tick%.service", lt.stdout or "")
      t.matches("1 timers listed", lt.stdout or "")
      vim.wait(3000, function() return false end, 50)
      local j = run_plan(sd, sd.parse_command("journalctl -u tick.service"), 2000)
      t.matches("TIMER_FIRED_MARKER", j.stdout or "")
      local stopped = run_plan(sd, sd.parse_command("systemctl stop tick.timer"), 5000)
      t.eq(0, stopped.code)
      local off = run_plan(sd, sd.parse_command("systemctl is-active tick.timer"), 2000)
      t.eq("inactive", (off.stdout or ""):gsub("%s+$", ""))
      require("NeoAI.sandbox.execution.service").stop_all({ timeout_ms = 5000 })
    end)
    vim.fn.delete(dir, "rf")
  end)


  it("systemd-run --on-active：建立瞬态定时器，到点执行命令", function(t)
    if tests.requires_sandbox() then return end
    with_config({ tools = { sandbox = systemd_config({}) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local p = assert(sd.parse_command("systemd-run --on-active=1 --unit=__probe_timer.timer /bin/echo RUN_TIMER_MARKER"))
      t.not_nil(p)
      t.eq("run", p.verb)
      t.not_nil(p.on_active)
      local r = run_plan(sd, p, 8000)
      t.eq(0, r.code, tostring(r.stderr))
      t.matches("Running timer as unit: __probe_timer%.timer", r.stdout or "")
      vim.wait(4000, function() return false end, 50)
      local j = run_plan(sd, sd.parse_command("journalctl -u __probe_timer.service"), 2000)
      t.matches("RUN_TIMER_MARKER", j.stdout or "")
      t.matches("__probe_timer%.timer",
        run_plan(sd, sd.parse_command("systemctl list-timers --all"), 2000).stdout or "")
      require("NeoAI.sandbox.execution.service").stop_all({ timeout_ms = 5000 })
    end)
  end)
end)
