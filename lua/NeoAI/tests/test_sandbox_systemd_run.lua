--- 沙箱 systemctl 门面测试：oneshot 与 Restart=always 重启
--- @module 'NeoAI.tests.test_sandbox_systemd_run'
--- oneshot 等待退出码、kill + Restart=always 自动重启（含真实等待）。
---
--- 拆分自原 `test_sandbox_systemd.lua`：systemd 用例含真实定时器/重启等待，单文件串行会把整轮
--- 测试拖成长尾；按主题拆分后由并行运行器（heavy lane）同时执行以压缩总时长。

local tests = require("NeoAI.tests")
local helpers = require("NeoAI.tests.sandbox_systemd_helpers")

local with_config = helpers.with_config
local write_unit = helpers.write_unit
local systemd_config = helpers.systemd_config
local run_plan = helpers.run_plan

tests.suite("sandbox_systemd_run", function(_, it)
  it("oneshot：start 等待结束并按退出码返回", function(t)
    if tests.requires_sandbox() then return end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "ok.service", "[Service]\nType=oneshot\nExecStart=/bin/true\n")
    write_unit(dir, "bad.service", "[Service]\nType=oneshot\nExecStart=/bin/sh -c 'exit 3'\n")
    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local ok = run_plan(sd, sd.parse_command("systemctl start ok.service"), 15000)
      t.eq(0, ok.code, tostring(ok.stderr))
      local bad = run_plan(sd, sd.parse_command("systemctl start bad.service"), 15000)
      t.true_((bad.code or 0) ~= 0, "失败的 oneshot 应非零退出")
      t.matches("failed", tostring(bad.stderr or "") .. tostring(bad.stdout or ""))
      require("NeoAI.sandbox.execution.service").stop_all({ timeout_ms = 5000 })
    end)
    vim.fn.delete(dir, "rf")
  end)


  it("kill + Restart=always：SIGKILL 后按策略自动重启，NRestarts 累加", function(t)
    if tests.requires_sandbox() then return end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "loop.service",
      "[Service]\nType=simple\nRestart=always\nRestartSec=1\nWorkingDirectory=" .. dir
      .. "\nExecStart=/bin/sleep 30\n")
    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local s = run_plan(sd, sd.parse_command("systemctl start loop.service"), 10000)
      t.eq(0, s.code, tostring(s.stderr))
      local k = run_plan(sd, sd.parse_command("systemctl kill -s SIGKILL loop.service"), 5000)
      t.eq(0, k.code, tostring(k.stderr))
      vim.wait(3000, function() return false end, 50)
      local sh = run_plan(sd, sd.parse_command("systemctl show loop.service -p NRestarts -p ActiveState -p Restart"), 2000)
      t.matches("Restart=always", sh.stdout or "")
      t.matches("ActiveState=active", sh.stdout or "")
      local n = tonumber(tostring(sh.stdout):match("NRestarts=(%d+)"))
      t.true_((n or 0) >= 1, "NRestarts 应 >=1，实际 " .. tostring(n))
      local act = run_plan(sd, sd.parse_command("systemctl is-active loop.service"), 2000)
      t.eq("active", (act.stdout or ""):gsub("%s+$", ""))
      require("NeoAI.sandbox.execution.service").stop_all({ timeout_ms = 10000 })
    end)
    vim.fn.delete(dir, "rf")
  end)

end)
