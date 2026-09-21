--- 沙箱 systemctl 门面（方案 A）专项测试
--- @module NeoAI.tests.test_sandbox_systemd
--- 覆盖：命令解析与路由、unit 解析与类型门禁、依赖闭包、start/stop/status 门面行为、
--- 不支持语义明确报错、门禁拦截（不调用宿主 systemctl）。

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
  end)

  it("unit 解析：Environment 展开与不支持语义报错", function(t)
    local sd = require("NeoAI.sandbox.systemd")
    local u, err = sd.parse_unit(
      "[Unit]\nDescription=Demo\nAfter=network.target\n[Service]\nType=simple\n"
      .. "Environment=PORT=8080\nWorkingDirectory=/srv/app\nExecStart=/usr/bin/foo --port $PORT\n",
      "demo.service")
    t.not_nil(u, tostring(err))
    t.eq("simple", u.type)
    t.eq("8080", u.env.PORT)
    t.eq("/srv/app", u.workdir)
    t.eq("/usr/bin/foo", u.argv[1])
    t.eq("8080", u.argv[3])

    local _, e1 = sd.parse_unit("[Service]\nType=notify\nExecStart=/bin/x\n", "n.service")
    t.matches("不支持", e1 or "")
    local _, e2 = sd.parse_unit("[Service]\nType=forking\nExecStart=/bin/x\n", "f.service")
    t.matches("forking", e2 or "")
    local _, e3 = sd.parse_unit("[Service]\nUser=nobody\nExecStart=/bin/x\n", "u.service")
    t.matches("User", e3 or "")
    local _, e4 = sd.parse_unit("[Service]\nExecStart=/bin/x %n\n", "s.service")
    t.matches("说明符", e4 or "")
    local _, e5 = sd.parse_unit("[Service]\nType=simple\n", "m.service")
    t.matches("ExecStart", e5 or "")
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

  it("门面：start/status/is-active/stop 在沙箱内运行", function(t)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write_unit(dir, "demo.service",
      "[Unit]\nDescription=Demo\n[Service]\nType=simple\nWorkingDirectory=" .. dir
      .. "\nExecStart=/bin/sleep 30\n")
    write_unit(dir, "bad.service", "[Service]\nType=notify\nExecStart=/bin/true\n")

    with_config({ tools = { sandbox = systemd_config({ dir }) } }, function()
      require("NeoAI.sandbox").reset()
      local sd = require("NeoAI.sandbox.systemd")
      local svc = require("NeoAI.sandbox.service")

      local start = sd.parse_command("systemctl start demo.service")
      local text, err
      sd.handle(start):then_(function(v) text = v end, function(e) err = e end)
      t.true_(vim.wait(10000, function() return text or err end, 20), "start 应返回")
      t.eq(nil, err, tostring(err))
      t.matches("已启动", text or "")
      t.not_nil(svc.status("unit:demo.service"), "服务应已注册")

      local stat = sd.parse_command("systemctl status demo.service")
      local stext
      sd.handle(stat):then_(function(v) stext = v end, function() end)
      t.true_(vim.wait(3000, function() return stext end, 20))
      t.matches("active", stext or "")

      local active = sd.parse_command("systemctl is-active demo.service")
      local atext
      sd.handle(active):then_(function(v) atext = v end, function() end)
      t.true_(vim.wait(3000, function() return atext end, 20))
      t.eq("active", atext)

      local bad = sd.parse_command("systemctl start bad.service")
      local berr
      sd.handle(bad):then_(function() end, function(e) berr = e end)
      t.true_(vim.wait(3000, function() return berr end, 20))
      t.matches("不支持", berr or "")

      local stop = sd.parse_command("systemctl stop demo.service")
      local sdone
      sd.handle(stop):then_(function() sdone = true end, function() sdone = true end)
      t.true_(vim.wait(10000, function() return sdone end, 20), "stop 应返回")
      t.eq(nil, svc.status("unit:demo.service"), "停止后应移除")
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("门面：enable/reload 明确拒绝、不落到宿主机", function(t)
    local sd = require("NeoAI.sandbox.systemd")
    for _, verb in ipairs({ "enable", "disable", "reload", "mask" }) do
      local txt = sd.reject_text(verb)
      t.matches("不支持", txt)
    end
    -- enable/disable 明确声明不修改宿主机。
    t.matches("宿主机", sd.reject_text("enable"))
    t.matches("宿主机", sd.reject_text("disable"))
    -- 宿主电源/内核状态操作禁止执行。
    t.matches("禁止", sd.reject_text("poweroff"))
    t.matches("禁止", sd.reject_text("reboot"))
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
      t.matches("已启动", text or "")
      local svc = require("NeoAI.sandbox.service")
      t.not_nil(svc.status("unit:gate.service"), "服务应已注册")
      svc.stop_all({ timeout_ms = 10000 })
    end)
    vim.fn.delete(dir, "rf")
  end)
end)
