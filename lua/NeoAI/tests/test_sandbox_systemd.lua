--- 沙箱 systemctl 门面测试：解析/外观/纯合成输出
--- @module 'NeoAI.tests.test_sandbox_systemd'
--- 命令解析、unit 解析、依赖闭包，以及 is-system-running / list-units / journalctl / analyze /
--- show 属性等纯合成输出用例（不启动真实服务，执行快）。
---
--- 拆分自原 `test_sandbox_systemd.lua`：systemd 用例含真实定时器/重启等待，单文件串行会把整轮
--- 测试拖成长尾；按主题拆分后由并行运行器（heavy lane）同时执行以压缩总时长。

local tests = require("NeoAI.tests")
local helpers = require("NeoAI.tests.sandbox_systemd_helpers")

local with_config = helpers.with_config
local write_unit = helpers.write_unit
local systemd_config = helpers.systemd_config
local run_plan = helpers.run_plan

tests.suite("sandbox_systemd", function(_, it)
  it("解析：独立 systemctl/journalctl 调用与路由", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local p = assert(sd.parse_command("systemctl restart nginx"))
    t.not_nil(p)
    t.eq("facade", p.route)
    t.eq("restart", p.verb)
    t.eq("nginx", p.units[1])

    p = assert(sd.parse_command("sudo systemctl status nginx.service"))
    t.eq("facade", p.route)
    t.eq("status", p.verb)

    t.eq("reject", sd.parse_command("systemctl enable foo").route)
    t.eq("reject", sd.parse_command("systemctl reload foo").route)
    t.eq("reject", sd.parse_command("systemctl poweroff").route)
    t.eq("hostop", sd.parse_command("systemctl freeze foo").route)
    t.eq("hostop", sd.parse_command("systemctl -H host restart foo").route)

    t.eq(nil, sd.parse_command("ls -la"))
    t.eq(nil, sd.parse_command("echo x && systemctl restart y"))
    t.eq(nil, sd.parse_command("systemctl restart y | cat"))
    t.eq(nil, sd.parse_command("systemctl"))

    local j = assert(sd.parse_command("journalctl -u demo.service -n 100"))
    t.not_nil(j)
    t.eq("journalctl", j.kind)
    t.eq("logs", j.verb)
    t.eq(100, j.tail)
    t.eq("facade", j.route)
    -- 无单元的 journalctl 现也由门面合成（不再落到宿主真实 journalctl）。
    t.not_nil(sd.parse_command("journalctl -n 3"))
  end)


  it("unit 解析：Environment/说明符展开、User 兼容、未知类型报错", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local u, err = sd.parse_unit(
      "[Unit]\nDescription=Demo\nAfter=network.target\n[Service]\nType=simple\n"
      .. "Environment=PORT=8080\nWorkingDirectory=/srv/app\nExecStart=/usr/bin/foo --port ${PORT} $PORT\n",
      "demo.service")
    t.not_nil(u, tostring(err))
    assert(u)
    t.eq("simple", u.type)
    t.eq("8080", u.env.PORT)
    t.eq("/srv/app", u.workdir)
    t.eq("/usr/bin/foo", u.argv[1])
    t.eq("8080", u.argv[3])
    t.eq("$PORT", u.argv[4], "systemd 只展开 ${VAR}；裸 $PORT 原样保留")

    -- 说明符展开：%%→%，%n→全名、%N→去后缀、%p→前缀、%i→实例（非模板为空）。
    local us = sd.parse_unit(
      "[Service]\nExecStart=/usr/bin/foo %n %N %p 100%%\n", "demo.service")
    t.not_nil(us, tostring(us and us.err))
    assert(us)
    t.eq("/usr/bin/foo", us.argv[1])
    t.eq("demo.service", us.argv[2])
    t.eq("demo", us.argv[3])
    t.eq("demo", us.argv[4])
    t.eq("100%", us.argv[5])
    local ui = sd.parse_unit("[Service]\nExecStart=/bin/x@%i/\n", "tpl@inst.service")
    t.not_nil(ui)
    assert(ui)
    t.eq("/bin/x@inst/", ui.argv[1])

    -- User=/Group= 兼容（沙箱以固定身份运行，不再拒绝）。
    local uu, uerr = sd.parse_unit("[Service]\nUser=nobody\nGroup=nogroup\nExecStart=/bin/x\n", "u.service")
    t.not_nil(uu, tostring(uerr))

    -- notify/forking/dbus/idle 以 simple 语义 best-effort 执行（不再明确拒绝）。
    for _, typ in ipairs({ "notify", "notify-reload", "forking", "dbus", "idle", "oneshot-notify" }) do
      local ut = sd.parse_unit("[Service]\nType=" .. typ .. "\nExecStart=/bin/x\n", typ .. ".service")
      t.not_nil(ut, typ .. " 应可解析")
    end

    -- 非 oneshot 多条 ExecStart：后写覆盖（取最后一条）。
    local um = sd.parse_unit("[Service]\nExecStart=/bin/a\nExecStart=/bin/b\n", "m.service")
    t.not_nil(um)
    assert(um)
    t.eq("/bin/b", um.argv[1])

    -- oneshot 多条 ExecStart：顺序保留。
    local uo = sd.parse_unit(
      "[Service]\nType=oneshot\nExecStart=/bin/a\nExecStart=/bin/b\n", "o.service")
    t.not_nil(uo)
    assert(uo)
    t.eq(2, #uo.argv_list)
    t.eq("/bin/a", uo.argv_list[1][1])
    t.eq("/bin/b", uo.argv_list[2][1])
    -- 空 `ExecStart=` 重置列表。
    local _, ue = sd.parse_unit("[Service]\nExecStart=/bin/a\nExecStart=\n", "e.service")
    t.matches("ExecStart", ue or "")

    local _, e5 = sd.parse_unit("[Service]\nType=simple\n", "m.service")
    t.matches("ExecStart", e5 or "")
    local _, e6 = sd.parse_unit("[Service]\nType=banana\nExecStart=/bin/x\n", "b.service")
    t.matches("Type", e6 or "")
  end)


  it("依赖闭包：Requires/Wants + After 排序、缺失依赖报错", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "a.service", "[Unit]\nRequires=b.service\nAfter=b.service\n[Service]\nExecStart=/bin/true\n")
    write_unit(dir, "b.service", "[Service]\nExecStart=/bin/true\n")
    write_unit(dir, "c.service", "[Service]\nExecStart=/bin/true\n")
    write_unit(dir, "bad.service", "[Unit]\nRequires=missing.service\n[Service]\nExecStart=/bin/true\n")
    write_unit(dir, "want.service", "[Unit]\nWants=missing.service\nRequires=c.service\n[Service]\nExecStart=/bin/true\n")
    write_unit(dir, "sock.socket", "[Socket]\nListenStream=80\n")
    write_unit(dir, "tpl@.service", "[Service]\nExecStart=/bin/true\n")

    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local ordered, units = assert(sd.resolve_closure({ "a.service" }, 32))
      t.not_nil(ordered, "闭包应解析成功")
      t.eq("b.service", ordered[1])
      t.eq("a.service", ordered[2])
      t.not_nil(units["a.service"])
      t.not_nil(units["b.service"])

      -- Wants 缺失被忽略，Requires 仍解析（c 先于 want）。
      local w_ordered = assert(sd.resolve_closure({ "want.service" }, 32))
      t.not_nil(w_ordered, "Wants 缺失不应阻断")
      t.eq("c.service", w_ordered[1])
      t.eq("want.service", w_ordered[2])

      local _, _, e1 = sd.resolve_closure({ "bad.service" }, 32)
      t.matches("not found", e1 or "")

      local _, _, e2 = sd.resolve_closure({ "sock.socket" }, 32)
      t.matches("不支持", e2 or "")

      local _, _, e3 = sd.resolve_closure({ "tpl@.service" }, 32)
      t.matches("模板", e3 or "")
    end)
    vim.fn.delete(dir, "rf")
  end)


  it("外观：is-system-running / is-failed / 无单元 status 输出真实 systemd 风格", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local function run(cmd)
      local plan = assert(sd.parse_command(cmd))
      t.not_nil(plan, "应识别: " .. cmd)
      t.eq("facade", plan.route, cmd .. " 应路由到门面")
      local res = run_plan(sd, plan, 2000)
      t.eq(nil, res.err, tostring(res.err))
      return res
    end
    local running = run("systemctl is-system-running")
    t.matches("^%a+$", (running.stdout or ""):gsub("%s+$", ""), "应输出运行态状态词")
    t.true_(running.code == 0 or running.code == 1, "运行态退出码应为 0/1")

    local failed = run("systemctl is-failed")
    t.matches("^%a+$", (failed.stdout or ""):gsub("%s+$", ""))

    local status = run("systemctl status")
    t.matches("State:", status.stdout or "")
    t.matches("Jobs:", status.stdout or "")
    -- 门面自身状态：无失败单元时应为 running（不查宿主，避免泄漏宿主 degraded）。
    t.eq("running", (running.stdout or ""):gsub("%s+$", ""))
    t.eq(0, running.code)
    t.eq("running", (failed.stdout or ""):gsub("%s+$", ""))
    t.eq(1, failed.code, "非 failed 的 is-failed 应退出 1")
  end)


  it("list-units：默认隐藏 inactive，--failed/--state/--type/--all 过滤生效", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "__probe_idle.service",
      "[Unit]\nDescription=Probe Idle\n[Service]\nType=simple\nExecStart=/bin/sleep 1\n")
    write_unit(dir, "__probe_idle.target", "[Unit]\nDescription=Probe Target\n")
    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local function text_of(cmd)
        local res = run_plan(sd, sd.parse_command(cmd), 3000)
        t.eq(nil, res.err, tostring(res.err))
        return tostring(res.stdout or "")
      end
      do
        local d = text_of("systemctl list-units --type=service")
        t.true_(not d:find("__probe_idle.service", 1, true), "默认不应列出 inactive 单元")
      end
      t.matches("__probe_idle%.service", text_of("systemctl list-units --type=service --all"),
        "--all 应列出 inactive 单元")
      t.matches("__probe_idle%.service", text_of("systemctl list-units --type=service --state=inactive"),
        "--state=inactive 应命中")
      t.true_(not text_of("systemctl list-units --failed"):find("__probe_idle", 1, true),
        "--failed 不应列出非失败单元")
      local running = text_of("systemctl list-units --type=service --state=running")
      t.true_(not running:find("__probe_idle", 1, true), "--state=running 不应列出 inactive 单元")
      -- 基线运行单元：--state=running 应含核心服务；默认列表也应非空。
      t.matches("systemd%-journald%.service", running, "--state=running 应含基线运行单元")
      t.matches("systemd%-journald%.service", text_of("systemctl list-units --type=service"),
        "默认 list-units 应含基线运行单元（非空）")
      -- --type 过滤：target 列表不含 service。
      t.true_(not text_of("systemctl list-units --type=target --all"):find("__probe_idle.service", 1, true),
        "--type=target 不应含 .service")
      t.matches("__probe_idle%.target", text_of("systemctl list-units --type=target --all"),
        "--type=target 应含 .target")
      -- 基线单元的 is-active/status 与列表一致。
      local ja = run_plan(sd, sd.parse_command("systemctl is-active systemd-journald.service"), 2000)
      t.eq("active", (ja.stdout or ""):gsub("%s+$", ""))
      t.eq(0, ja.code)
      local js = run_plan(sd, sd.parse_command("systemctl status systemd-journald.service"), 2000)
      t.matches("active", js.stdout or "")
      t.eq(0, js.code)
    end)
    vim.fn.delete(dir, "rf")
  end)


  it("journalctl：合成日志各行时间戳不同（不再是单一时间点）", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local res = run_plan(sd, sd.parse_command("journalctl -n 3"), 2000)
    t.eq(nil, res.err, tostring(res.err))
    local seen, distinct = {}, 0
    for hms in tostring(res.stdout or ""):gmatch("(%d%d:%d%d:%d%d)") do
      if not seen[hms] then seen[hms] = true; distinct = distinct + 1 end
    end
    t.true_(distinct >= 2, "各日志行时间戳应不同，实际: " .. tostring(res.stdout))
  end)


  it("systemctl --failed：无动词默认 list-units，--failed 过滤生效", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local p = assert(sd.parse_command("systemctl --failed"))
    t.not_nil(p, "--failed 应被识别（默认动词 list-units）")
    t.eq("list-units", p.verb)
    t.eq("facade", p.route)
    local res = run_plan(sd, p, 2000)
    t.eq(0, res.code)
    t.matches("0 loaded units listed", res.stdout or "")
    t.true_(not tostring(res.stdout):find("systemd-journald", 1, true), "--failed 不应列出 active 基线单元")
    -- 与 list-units --state=failed 等价；exec(argv) 路径同样过滤（此前会落到默认列表）。
    local eq = run_plan(sd, sd.parse_command("systemctl list-units --state=failed"), 2000)
    t.eq("0 loaded units listed", (tostring(eq.stdout):match("(%d+ loaded units listed)")))
    local r2
    sd.exec({ "systemctl", "--failed" }):then_(function(v) r2 = v end, function() end)
    t.true_(vim.wait(2000, function() return r2 ~= nil end, 20))
    t.eq("0 loaded units listed", (tostring(r2.stdout):match("(%d+ loaded units listed)")))
  end)


  it("systemd-analyze：合成 time/blame/--version（不再连 bus）", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local p = assert(sd.parse_command("systemd-analyze time"))
    t.not_nil(p)
    t.eq("systemd-analyze", p.kind)
    t.eq("time", p.verb)
    t.eq("time", sd.parse_command("systemd-analyze").verb, "无动词默认 time")
    local tm = run_plan(sd, p, 2000)
    t.eq(0, tm.code)
    t.matches("Startup finished in", tm.stdout or "")
    t.matches("reached after", tm.stdout or "")
    local bl = run_plan(sd, sd.parse_command("systemd-analyze blame"), 2000)
    t.eq(0, bl.code)
    t.matches("systemd%-journald%.service", bl.stdout or "")
    local ver = run_plan(sd, sd.parse_command("systemd-analyze --version"), 2000)
    t.eq(0, ver.code)
    t.matches("systemd", ver.stdout or "")
  end)


  it("systemctl reset-failed：幂等成功（不再 Unknown command verb）", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local p = assert(sd.parse_command("systemctl reset-failed"))
    t.eq("facade", p.route)
    local r = run_plan(sd, p, 2000)
    t.eq(0, r.code)
    t.eq("", r.stdout or "")
    local r2 = run_plan(sd, sd.parse_command("systemctl reset-failed foo.service"), 2000)
    t.eq(0, r2.code)
  end)


  it("hostnamectl/timedatectl/dmesg：门面合成（不再连 bus/EPERM）", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local h = run_plan(sd, sd.parse_command("hostnamectl"), 2000)
    t.eq(0, h.code)
    t.matches("Static hostname:", h.stdout or "")
    t.matches("Machine ID:", h.stdout or "")
    local td = run_plan(sd, sd.parse_command("timedatectl"), 2000)
    t.eq(0, td.code)
    t.matches("Time zone:", td.stdout or "")
    local d = run_plan(sd, sd.parse_command("dmesg"), 2000)
    t.eq(0, d.code)
    t.matches("Linux version", d.stdout or "")
    local dt = run_plan(sd, sd.parse_command("dmesg -T"), 2000)
    t.eq(0, dt.code)
    t.matches("%[%a%a%a ", dt.stdout or "")
    local sh = run_plan(sd, sd.parse_command("hostnamectl set-hostname x"), 2000)
    t.true_((sh.code or 0) ~= 0, "set-hostname 应拒绝（不修改宿主）")
    t.matches("Access denied", sh.stderr or "")
  end)


  it("systemctl：get-default/list-timers/list-sockets/list-jobs/show-environment 可识别", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local function txt(cmd)
      local p = assert(sd.parse_command(cmd))
      t.not_nil(p, cmd)
      t.eq("facade", p.route, cmd)
      local r = run_plan(sd, p, 2000)
      t.true_((r.code or 0) == 0, cmd .. " rc=" .. tostring(r.code) .. " " .. tostring(r.stderr))
      return tostring(r.stdout or "")
    end
    t.matches("target", txt("systemctl get-default"))
    t.matches("timers listed", txt("systemctl list-timers"))
    t.matches("sockets listed", txt("systemctl list-sockets"))
    t.matches("No jobs", txt("systemctl list-jobs"))
    t.eq("", txt("systemctl show-environment"):gsub("%s+$", ""))
    local p = sd.parse_command("systemctl set-default multi-user.target")
    t.eq(0, run_plan(sd, p, 2000).code)
  end)


  it("Service 属性：Restart/RestartSec/MemoryMax/CPUQuota 解析并进入 show（--property 过滤）", function(t)
    local sd = require("NeoAI.sandbox.systemd.systemd")
    local u = assert(sd.parse_unit(
      "[Unit]\nDescription=Props\n[Service]\nType=simple\nRestart=always\nRestartSec=5\n"
      .. "MemoryMax=64M\nMemoryHigh=32M\nCPUQuota=50%\nExecStart=/bin/sleep 30\n", "props.service"))
    t.eq("always", u.restart)
    t.eq(5, u.restart_sec)
    t.eq(64 * 1024 * 1024, u.memory_max)
    t.eq(32 * 1024 * 1024, u.memory_high)
    t.eq(50, u.cpu_quota)

    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "props.service",
      "[Unit]\nDescription=Props\n[Service]\nType=simple\nRestart=always\nRestartSec=5\n"
      .. "MemoryMax=64M\nCPUQuota=50%\nExecStart=/bin/sleep 30\n")
    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sh = run_plan(sd, sd.parse_command(
        "systemctl show props.service --property=Restart,RestartUSec,MemoryMax,CPUQuota,NRestarts"), 2000)
      t.eq(0, sh.code, tostring(sh.stderr))
      t.matches("Restart=always", sh.stdout or "")
      t.matches("MemoryMax=67108864", sh.stdout or "")
      t.matches("CPUQuota=50%%", sh.stdout or "")
      t.true_(not tostring(sh.stdout):find("Description=", 1, true), "应只输出请求的属性")
      local val = run_plan(sd, sd.parse_command("systemctl show props.service -p Restart --value"), 2000)
      t.eq("always", (val.stdout or ""):gsub("%s+$", ""))
    end)
    vim.fn.delete(dir, "rf")
  end)


  it("reset-failed：清除失败态（--failed/degraded 恢复，状态不再粘滞）", function(t)
    if require("NeoAI.sandbox.execution.runtime").backend() == nil then return end -- 无命名空间隔离后端时沙箱禁用（退回审批）；systemd 门面/单元启动依赖沙箱进程前缀，不经此路径
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "fail.service", "[Service]\nType=oneshot\nExecStart=/bin/sh -c 'exit 3'\n")
    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd.systemd")
      local bad = run_plan(sd, sd.parse_command("systemctl start fail.service"), 15000)
      t.true_((bad.code or 0) ~= 0, "失败 oneshot 应非零退出")
      t.eq("degraded", (run_plan(sd, sd.parse_command("systemctl is-system-running"), 2000).stdout or ""):gsub("%s+$", ""))
      t.matches("fail%.service", run_plan(sd, sd.parse_command("systemctl --failed"), 2000).stdout or "")
      local rf = run_plan(sd, sd.parse_command("systemctl reset-failed fail.service"), 2000)
      t.eq(0, rf.code)
      t.eq("running", (run_plan(sd, sd.parse_command("systemctl is-system-running"), 2000).stdout or ""):gsub("%s+$", ""))
      t.true_(not tostring(run_plan(sd, sd.parse_command("systemctl --failed"), 2000).stdout):find("fail.service", 1, true),
        "reset-failed 后 --failed 不应再列出")
      t.eq("inactive", (run_plan(sd, sd.parse_command("systemctl is-active fail.service"), 2000).stdout or ""):gsub("%s+$", ""))
      require("NeoAI.sandbox.execution.service").stop_all({ timeout_ms = 5000 })
    end)
    vim.fn.delete(dir, "rf")
  end)

end)
