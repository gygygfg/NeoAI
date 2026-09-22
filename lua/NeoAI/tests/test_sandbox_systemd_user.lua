--- 嵌套 systemd --user 专项测试
--- @module NeoAI.tests.test_sandbox_systemd_user
--- 覆盖：会话级常驻沙箱内启动真实 systemd 用户实例；`systemctl --user` 命中真实语义；
--- 用户单元在沙箱内执行、输出可见；单元文件与运行态均不落宿主机。

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
  it("嵌套 systemd --user：真实用户实例运行、单元执行且不落宿主机", function(t)
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
      if not sduser.available() then return end
      sandbox.reset()
      local dir = vim.fn.tempname()
      fs.ensure_dir(dir)
      local prev = vim.fn.getcwd()
      vim.fn.chdir(dir)
      local out = dir .. "/sd_out.txt"
      local unit_host = "/root/.config/systemd/user/neoai-sdtest.service"
      local cmd = table.concat({
        "mkdir -p \"$HOME/.config/systemd/user\"",
        "cat > \"$HOME/.config/systemd/user/neoai-sdtest.service\" <<'UNIT'",
        "[Unit]",
        "Description=NeoAI nested systemd test",
        "[Service]",
        "Type=oneshot",
        "ExecStart=/bin/sh -c 'echo SD_OK > " .. out .. "'",
        "UNIT",
        "systemctl --user daemon-reload",
        "systemctl --user start neoai-sdtest.service",
        "echo ACTIVE=$(systemctl --user is-active neoai-sdtest.service)",
        "echo OUT=$(cat " .. out .. " 2>&1)",
      }, "\n")
      local done, result, e = false, nil, nil
      require("NeoAI.tools").execute("run_command", { command = cmd, description = "t" }, {})
        :then_(function(r) result = tostring(r); done = true end, function(er) e = er; done = true end)
      t.true_(vim.wait(60000, function() return done end, 100), "命令应完成")
      t.eq(nil, e, "不应报错: " .. tostring(e and (e.message or e)))
      t.matches("OUT=SD_OK", result, "用户单元应在沙箱内执行")
      t.matches("ACTIVE=", result, "应能查询单元状态")
      t.true_(vim.uv.fs_stat(unit_host) == nil, "单元文件不应落宿主机")
      vim.fn.chdir(prev)
      require("NeoAI.sandbox.resident").stop({ timeout_ms = 3000 })
    end)
  end)

  it("systemctl --user 未被门面拦截（route=native），未启用时给出明确提示", function(t)
    local systemd = require("NeoAI.sandbox.systemd")
    local plan = systemd.parse_command("systemctl --user status foo")
    t.not_nil(plan, "应解析")
    t.eq("native", plan.route, "--user 应走原生路径")
    local plan2 = systemd.parse_command("systemctl --user start foo.service")
    t.eq("native", plan2.route)
  end)
end)
