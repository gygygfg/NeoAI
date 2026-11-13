--- 沙箱 systemctl 门面测试：systemd-run --wait（等待单元结束）
--- @module 'NeoAI.tests.test_sandbox_systemd_wait'
--- `systemd-run --unit=… --wait` 临时单元：解析、启动并等待结束。
---
--- 拆分自原 `test_sandbox_systemd.lua`：systemd 用例含真实定时器/重启等待，单文件串行会把整轮
--- 测试拖成长尾；按主题拆分后由并行运行器（heavy lane）同时执行以压缩总时长。

local tests = require("NeoAI.tests")
local helpers = require("NeoAI.tests.sandbox_systemd_helpers")

local with_config = helpers.with_config
local write_unit = helpers.write_unit
local systemd_config = helpers.systemd_config
local run_plan = helpers.run_plan

tests.suite("sandbox_systemd_wait", function(_, it)
  it("systemd-run：解析与临时单元启动（--unit/--wait）", function(t)
    if tests.requires_sandbox() then return end
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local p = assert(sd.parse_command("systemd-run --unit=foo.service /bin/true --flag"))
    t.not_nil(p)
    t.eq("systemd-run", p.kind)
    t.eq("run", p.verb)
    t.eq("facade", p.route)
    t.eq("foo.service", p.units[1])
    t.eq("/bin/true", p.argv[1])
    t.eq("--flag", p.argv[2])
    local w = assert(sd.parse_command("systemd-run --wait -E A=B -- /bin/sh -c 'exit 3'"))
    t.not_nil(w)
    t.true_(w.wait == true, "应识别 --wait")
    t.eq("B", w.env.A)
    t.eq(3, #w.argv, "argv 应保留引号内空格为一个参数")

    with_config({ tools = { sandbox = systemd_config({}) } }, function()
      require("NeoAI.sandbox").reset()
      local svc = require("NeoAI.sandbox.execution.service")
      local r1 = run_plan(sd, sd.parse_command("systemd-run --unit=__probe_run.service /bin/sleep 30"), 10000)
      t.eq(0, r1.code, tostring(r1.stderr))
      t.matches("Running as unit: __probe_run%.service", r1.stdout or "")
      t.not_nil(svc.status("unit:__probe_run.service"), "临时单元应已启动")
      -- 临时单元在 list-units / is-active 中可见。
      local act = run_plan(sd, sd.parse_command("systemctl is-active __probe_run.service"), 2000)
      t.eq("active", (act.stdout or ""):gsub("%s+$", ""))

      local r2 = run_plan(sd, sd.parse_command("systemd-run --wait /bin/true"), 15000)
      t.eq(0, r2.code, tostring(r2.stderr))
      -- 退出码透传：--wait 下返回单元退出码。
      local r3 = run_plan(sd, sd.parse_command("systemd-run --wait /bin/sh -c 'exit 3'"), 15000)
      t.matches("Running as unit: run%-r%x+%.service", r3.stdout or "")
      t.eq(3, r3.code, "应透传临时单元退出码")
      svc.stop_all({ timeout_ms = 10000 })
    end)
  end)



end)
