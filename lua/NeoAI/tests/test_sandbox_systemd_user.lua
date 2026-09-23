--- 伪造 systemd 用户解析器专项测试
--- @module NeoAI.tests.test_sandbox_systemd_user
--- 覆盖：`systemctl --user` 由门面内的伪造解析器处理（无需真实 systemd/dbus）；
--- 简单 start/stop/is-active 在沙箱内生效；单元文件不落宿主机。

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

tests.suite("sandbox_systemd_user", function(_, it)
  it("伪造 systemd --user：解析器处理 start/is-active/stop，且不落宿主机", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    if runtime.backend() ~= "bwrap" then return end
    local fs = require("NeoAI.utils.fs")
    local sandbox = require("NeoAI.sandbox")
    with_config({
      tools = {
        approval = { mode = "auto_allow" },
        sandbox = {
          enabled = true, fail_closed = true, mode = "dry_run",
          ephemeral_roots = {},
          resident = { enabled = true },
          systemd = { enabled = true, user = { enabled = true } },
        },
      },
    }, function()
      local sduser = require("NeoAI.sandbox.systemd_user")
      t.true_(sduser.available(), "伪造 systemd --user 应可用（无需 dbus/systemd 二进制）")
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local unit_name = "neoai-sdtest.service"
      local unit_host = vim.fn.expand("~/.config/systemd/user/" .. unit_name)
      vim.fn.delete(unit_host)
      local tools = require("NeoAI.tools")
      local write_cmd = table.concat({
        "mkdir -p \"$HOME/.config/systemd/user\"",
        "cat > \"$HOME/.config/systemd/user/" .. unit_name .. "\" <<'UNIT'",
        "[Unit]",
        "Description=NeoAI fake systemd test",
        "[Service]",
        "Type=simple",
        "ExecStart=/bin/sleep 30",
        "UNIT",
      }, "\n")
      local done = false
      tools.execute("run_command", { command = write_cmd, description = "t" }, {})
        :then_(function()
          return tools.execute("run_command",
            { command = "systemctl --user start " .. unit_name, description = "t" }, {})
        end):then_(function(r)
          t.eq("", tostring(r), "伪造解析器应静默启动用户单元（真实 systemctl 行为）")
          return tools.execute("run_command",
            { command = "systemctl --user is-active " .. unit_name, description = "t" }, {})
        end):then_(function(r)
          t.matches("active", tostring(r), "is-active 应报告 active")
          return tools.execute("run_command",
            { command = "systemctl --user stop " .. unit_name, description = "t" }, {})
        end):then_(function(r)
          t.eq("", tostring(r), "伪造解析器应静默停止用户单元")
          t.true_(vim.uv.fs_stat(unit_host) == nil, "单元文件不应落宿主机")
          done = true
        end, function(e)
          t.true_(false, "不应失败: " .. tostring(e and (e.message or e)))
          done = true
        end)
      t.true_(vim.wait(60000, function() return done end, 100), "命令应完成")
      vim.fn.chdir(prev)
      require("NeoAI.sandbox.resident").stop({ timeout_ms = 3000 })
    end)
  end)

  it("systemctl --user 由伪造解析器处理（route=facade, scope=user）", function(t)
    local systemd = require("NeoAI.sandbox.systemd")
    local plan = systemd.parse_command("systemctl --user status foo")
    t.not_nil(plan, "应解析")
    t.eq("facade", plan.route, "--user 应走伪造门面")
    t.eq("user", plan.scope, "--user 应标记 user scope")
    local plan2 = systemd.parse_command("systemctl --user start foo.service")
    t.eq("facade", plan2.route)
    t.eq("user", plan2.scope)
    local plan3 = systemd.parse_command("systemctl start foo.service")
    t.eq("facade", plan3.route)
    t.eq("system", plan3.scope, "系统级应为 system scope")
  end)
end)
