--- 沙箱 systemctl 门面测试：systemd-run --pipe/-P（输出与退出码）
--- @module 'NeoAI.tests.test_sandbox_systemd_pipe'
--- `systemd-run --pipe/-P` 回传单元输出与退出码（不再报不支持）。
---
--- 拆分自原 `test_sandbox_systemd.lua`：systemd 用例含真实定时器/重启等待，单文件串行会把整轮
--- 测试拖成长尾；按主题拆分后由并行运行器（heavy lane）同时执行以压缩总时长。

local tests = require("NeoAI.tests")
local helpers = require("NeoAI.tests.sandbox_systemd_helpers")

local with_config = helpers.with_config
local write_unit = helpers.write_unit
local systemd_config = helpers.systemd_config
local run_plan = helpers.run_plan

tests.suite("sandbox_systemd_pipe", function(_, it)
  it("systemd-run --pipe/-P：回传输出与退出码（不再报不支持）", function(t)
    if tests.requires_sandbox() then return end
    with_config({ tools = { sandbox = systemd_config({}) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local p = assert(sd.parse_command("systemd-run --pipe /bin/echo PIPED"))
      t.not_nil(p)
      t.true_(p.pipe == true, "应识别 --pipe")
      local r = run_plan(sd, p, 15000)
      t.eq(0, r.code, tostring(r.stderr))
      t.matches("PIPED", r.stdout or "")
      t.true_(not tostring(r.stdout):find("Running as unit", 1, true), "pipe 不应打印 Running as unit")
      local q = assert(sd.parse_command("systemd-run -P /bin/sh -c 'exit 4'"))
      t.true_(q.pipe == true)
      local r2 = run_plan(sd, q, 15000)
      t.eq(4, r2.code, "应透传退出码")
      require("NeoAI.sandbox.execution.service").stop_all({ timeout_ms = 5000 })
    end)
  end)


end)
