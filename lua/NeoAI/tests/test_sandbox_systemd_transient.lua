--- 沙箱 systemctl 门面测试：systemd-run 瞬态单元（status/cat/show/stop/restart）
--- @module 'NeoAI.tests.test_sandbox_systemd_transient'
--- 瞬态单元建立后 status/cat/show/is-enabled/stop/restart 的行为一致性。
---
--- 拆分自原 `test_sandbox_systemd.lua`：systemd 用例含真实定时器/重启等待，单文件串行会把整轮
--- 测试拖成长尾；按主题拆分后由并行运行器（heavy lane）同时执行以压缩总时长。

local tests = require("NeoAI.tests")
local helpers = require("NeoAI.tests.sandbox_systemd_helpers")

local with_config = helpers.with_config
local write_unit = helpers.write_unit
local systemd_config = helpers.systemd_config
local run_plan = helpers.run_plan

tests.suite("sandbox_systemd_transient", function(_, it)
  it("systemd-run 瞬态单元：status/cat/show/is-enabled/stop/restart 一致", function(t)
    if tests.requires_sandbox() then return end
    with_config({ tools = { sandbox = systemd_config({}) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local r1 = run_plan(sd, sd.parse_command("systemd-run --unit=__probe_tx.service /bin/sleep 30"), 10000)
      t.eq(0, r1.code, tostring(r1.stderr))
      local st = run_plan(sd, sd.parse_command("systemctl status __probe_tx.service"), 2000)
      t.eq(0, st.code, tostring(st.stderr))
      t.matches("active", st.stdout or "")
      t.true_(not tostring(st.stderr):find("could not be found", 1, true))
      local cat = run_plan(sd, sd.parse_command("systemctl cat __probe_tx.service"), 2000)
      t.eq(0, cat.code, tostring(cat.stderr))
      t.matches("transient", cat.stdout or "")
      local show = run_plan(sd, sd.parse_command("systemctl show __probe_tx.service"), 2000)
      t.matches("ActiveState=active", show.stdout or "")
      t.matches("Transient=yes", show.stdout or "")
      local en = run_plan(sd, sd.parse_command("systemctl is-enabled __probe_tx.service"), 2000)
      t.eq("generated", (en.stdout or ""):gsub("%s+$", ""))
      local re = run_plan(sd, sd.parse_command("systemctl restart __probe_tx.service"), 8000)
      t.eq(0, re.code, tostring(re.stderr))
      local on = run_plan(sd, sd.parse_command("systemctl is-active __probe_tx.service"), 2000)
      t.eq("active", (on.stdout or ""):gsub("%s+$", ""))
      local stop = run_plan(sd, sd.parse_command("systemctl stop __probe_tx.service"), 8000)
      t.eq(0, stop.code, tostring(stop.stderr))
      local off = run_plan(sd, sd.parse_command("systemctl is-active __probe_tx.service"), 2000)
      t.eq("inactive", (off.stdout or ""):gsub("%s+$", ""))
      require("NeoAI.sandbox.execution.service").stop_all({ timeout_ms = 5000 })
    end)
  end)



end)
