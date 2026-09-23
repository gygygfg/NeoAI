--- 沙箱 systemctl 门面（方案 A）专项测试
--- @module NeoAI.tests.test_sandbox_systemd
--- 覆盖：命令解析与路由、unit 解析与类型门禁、依赖闭包、start/stop/status 门面行为、
--- 真实 systemd 风格错误与退出码、门禁拦截（不调用宿主 systemctl）。

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

local function write_unit(dir, name, body)
  local path = dir .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write(body)
  f:close()
  return path
end

local function systemd_config(unit_roots, extra)
  local base = {
    enabled = true, fail_closed = true, mode = "dry_run", ephemeral_roots = {},
    service = { enabled = true },
    systemd = { enabled = true, mode = "facade", unit_roots = unit_roots, max_deps = 32 },
  }
  for k, v in pairs(extra or {}) do base[k] = v end
  return base
end

--- 执行一个门面计划并等待 {stdout, stderr, code}。
local function run_plan(sd, plan, timeout)
  local res
  sd.handle(plan):then_(function(v) res = v end, function(e) res = { err = e } end)
  vim.wait(timeout or 3000, function() return res ~= nil end, 20)
  return res
end

tests.suite("sandbox_systemd", function(_, it)
  it("解析：独立 systemctl/journalctl 调用与路由", function(t)
    local sd = require("NeoAI.sandbox.systemd")
    local p = sd.parse_command("systemctl restart nginx")
    t.not_nil(p)
    t.eq("facade", p.route)
    t.eq("restart", p.verb)
    t.eq("nginx", p.units[1])

    p = sd.parse_command("sudo systemctl status nginx.service")
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

    local j = sd.parse_command("journalctl -u demo.service -n 100")
    t.not_nil(j)
    t.eq("journalctl", j.kind)
    t.eq("logs", j.verb)
    t.eq(100, j.tail)
    t.eq("facade", j.route)
    -- 无单元的 journalctl 现也由门面合成（不再落到宿主真实 journalctl）。
    t.not_nil(sd.parse_command("journalctl -n 3"))
  end)

  it("unit 解析：Environment/说明符展开、User 兼容、未知类型报错", function(t)
    local sd = require("NeoAI.sandbox.systemd")
    local u, err = sd.parse_unit(
      "[Unit]\nDescription=Demo\nAfter=network.target\n[Service]\nType=simple\n"
      .. "Environment=PORT=8080\nWorkingDirectory=/srv/app\nExecStart=/usr/bin/foo --port ${PORT} $PORT\n",
      "demo.service")
    t.not_nil(u, tostring(err))
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
    t.eq("/usr/bin/foo", us.argv[1])
    t.eq("demo.service", us.argv[2])
    t.eq("demo", us.argv[3])
    t.eq("demo", us.argv[4])
    t.eq("100%", us.argv[5])
    local ui = sd.parse_unit("[Service]\nExecStart=/bin/x@%i/\n", "tpl@inst.service")
    t.not_nil(ui)
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
    t.eq("/bin/b", um.argv[1])

    -- oneshot 多条 ExecStart：顺序保留。
    local uo = sd.parse_unit(
      "[Service]\nType=oneshot\nExecStart=/bin/a\nExecStart=/bin/b\n", "o.service")
    t.not_nil(uo)
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
      local sd = require("NeoAI.sandbox.systemd")
      local ordered, units = sd.resolve_closure({ "a.service" }, 32)
      t.not_nil(ordered, "闭包应解析成功")
      t.eq("b.service", ordered[1])
      t.eq("a.service", ordered[2])
      t.not_nil(units["a.service"])
      t.not_nil(units["b.service"])

      -- Wants 缺失被忽略，Requires 仍解析（c 先于 want）。
      local w_ordered = sd.resolve_closure({ "want.service" }, 32)
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

  it("门面：start 静默成功、status/is-active 合成真实输出、stop 移除服务", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "demo.service",
      "[Unit]\nDescription=Demo\n[Service]\nType=simple\nWorkingDirectory=" .. dir
      .. "\nExecStart=/bin/sleep 30\n")
    write_unit(dir, "bad.service", "[Service]\nType=simple\n")

    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd")
      local svc = require("NeoAI.sandbox.service")

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
      sd.handle(sd.parse_command("systemctl stop demo.service")):then_(
        function() sdone = true end, function() sdone = true end)
      t.true_(vim.wait(10000, function() return sdone end, 20), "stop 应返回")
      t.eq(nil, svc.status("unit:demo.service"), "停止后应移除")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("门面：enable/reload/mask/power 返回真实错误（不暴露沙箱）", function(t)
    local sd = require("NeoAI.sandbox.systemd")
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

  it("门禁：run_command 的 systemctl 被路由到沙箱服务", function(t)
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
      local svc = require("NeoAI.sandbox.service")
      t.not_nil(svc.status("unit:gate.service"), "服务应已注册")
      svc.stop_all({ timeout_ms = 10000 })
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("外观：is-system-running / is-failed / 无单元 status 输出真实 systemd 风格", function(t)
    local sd = require("NeoAI.sandbox.systemd")
    local function run(cmd)
      local plan = sd.parse_command(cmd)
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
      local sd = require("NeoAI.sandbox.systemd")
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
    local sd = require("NeoAI.sandbox.systemd")
    local res = run_plan(sd, sd.parse_command("journalctl -n 3"), 2000)
    t.eq(nil, res.err, tostring(res.err))
    local seen, distinct = {}, 0
    for hms in tostring(res.stdout or ""):gmatch("(%d%d:%d%d:%d%d)") do
      if not seen[hms] then seen[hms] = true; distinct = distinct + 1 end
    end
    t.true_(distinct >= 2, "各日志行时间戳应不同，实际: " .. tostring(res.stdout))
  end)

  it("门禁：查询类动词非零退出不包装为工具失败（ok:false）", function(t)
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

  it("systemd-run：解析与临时单元启动（--unit/--wait）", function(t)
    local sd = require("NeoAI.sandbox.systemd")
    local p = sd.parse_command("systemd-run --unit=foo.service /bin/true --flag")
    t.not_nil(p)
    t.eq("systemd-run", p.kind)
    t.eq("run", p.verb)
    t.eq("facade", p.route)
    t.eq("foo.service", p.units[1])
    t.eq("/bin/true", p.argv[1])
    t.eq("--flag", p.argv[2])
    local w = sd.parse_command("systemd-run --wait -E A=B -- /bin/sh -c 'exit 3'")
    t.not_nil(w)
    t.true_(w.wait == true, "应识别 --wait")
    t.eq("B", w.env.A)
    t.eq(3, #w.argv, "argv 应保留引号内空格为一个参数")

    with_config({ tools = { sandbox = systemd_config({}) } }, function()
      require("NeoAI.sandbox").reset()
      local svc = require("NeoAI.sandbox.service")
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

  it("systemctl：基线系统单元 start/stop/restart 幂等成功（不再权限拒绝）", function(t)
    with_config({ tools = { sandbox = systemd_config({}) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd")
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

  it("systemctl --failed：无动词默认 list-units，--failed 过滤生效", function(t)
    local sd = require("NeoAI.sandbox.systemd")
    local p = sd.parse_command("systemctl --failed")
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
    local sd = require("NeoAI.sandbox.systemd")
    local p = sd.parse_command("systemd-analyze time")
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

  it("systemd-run 瞬态单元：status/cat/show/is-enabled/stop/restart 一致", function(t)
    with_config({ tools = { sandbox = systemd_config({}) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd")
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
      require("NeoAI.sandbox.service").stop_all({ timeout_ms = 5000 })
    end)
  end)

  it("systemctl reset-failed：幂等成功（不再 Unknown command verb）", function(t)
    local sd = require("NeoAI.sandbox.systemd")
    local p = sd.parse_command("systemctl reset-failed")
    t.eq("facade", p.route)
    local r = run_plan(sd, p, 2000)
    t.eq(0, r.code)
    t.eq("", r.stdout or "")
    local r2 = run_plan(sd, sd.parse_command("systemctl reset-failed foo.service"), 2000)
    t.eq(0, r2.code)
  end)

  it("hostnamectl/timedatectl/dmesg：门面合成（不再连 bus/EPERM）", function(t)
    local sd = require("NeoAI.sandbox.systemd")
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

  it("门面读取沙箱私有视图：/run/systemd/system 会话目录中的单元可见", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local host = runtime.host_tmp_dir("/run") .. "/systemd/system/__probe_view.service"
    vim.fn.mkdir(vim.fn.fnamemodify(host, ":h"), "p")
    local f = assert(io.open(host, "w"))
    f:write("[Unit]\nDescription=View Probe\n[Service]\nType=oneshot\nExecStart=/bin/true\n")
    f:close()
    local ok, err = pcall(function()
      local sd = require("NeoAI.sandbox.systemd")
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

  it("systemctl：get-default/list-timers/list-sockets/list-jobs/show-environment 可识别", function(t)
    local sd = require("NeoAI.sandbox.systemd")
    local function txt(cmd)
      local p = sd.parse_command(cmd)
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

  it("systemd-run --pipe/-P：回传输出与退出码（不再报不支持）", function(t)
    with_config({ tools = { sandbox = systemd_config({}) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd")
      local p = sd.parse_command("systemd-run --pipe /bin/echo PIPED")
      t.not_nil(p)
      t.true_(p.pipe == true, "应识别 --pipe")
      local r = run_plan(sd, p, 15000)
      t.eq(0, r.code, tostring(r.stderr))
      t.matches("PIPED", r.stdout or "")
      t.true_(not tostring(r.stdout):find("Running as unit", 1, true), "pipe 不应打印 Running as unit")
      local q = sd.parse_command("systemd-run -P /bin/sh -c 'exit 4'")
      t.true_(q.pipe == true)
      local r2 = run_plan(sd, q, 15000)
      t.eq(4, r2.code, "应透传退出码")
      require("NeoAI.sandbox.service").stop_all({ timeout_ms = 5000 })
    end)
  end)

  it("oneshot：start 等待结束并按退出码返回", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "ok.service", "[Service]\nType=oneshot\nExecStart=/bin/true\n")
    write_unit(dir, "bad.service", "[Service]\nType=oneshot\nExecStart=/bin/sh -c 'exit 3'\n")
    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd")
      local ok = run_plan(sd, sd.parse_command("systemctl start ok.service"), 15000)
      t.eq(0, ok.code, tostring(ok.stderr))
      local bad = run_plan(sd, sd.parse_command("systemctl start bad.service"), 15000)
      t.true_((bad.code or 0) ~= 0, "失败的 oneshot 应非零退出")
      t.matches("failed", tostring(bad.stderr or "") .. tostring(bad.stdout or ""))
      require("NeoAI.sandbox.service").stop_all({ timeout_ms = 5000 })
    end)
    vim.fn.delete(dir, "rf")
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
