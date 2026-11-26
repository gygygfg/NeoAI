--- 宿主侧 SSH 能力（别名 / 命令模板 / 待审提案）
--- @module 'NeoAI.tests.test_sandbox_ssh'
--- 覆盖：别名解析、固定命令模板（不接受 AI 传入的 host/端口/-o）、指纹钉死、隧道仅 loopback、
--- 以及工具只入队「主机操作提案」而不在沙箱内执行。

local tests = require("NeoAI.tests")

tests.suite("sandbox_ssh", function(_, it)
  local config_store = require("NeoAI.kernel.config_store")
  local broker = require("NeoAI.sandbox.ssh.broker")
  local pre = require("NeoAI.sandbox.protected.preauthorize")

  --- 生成临时私钥文件与其指纹
  --- @return string path
  --- @return string fingerprint
  local function mkkey()
    local p = vim.fn.tempname()
    vim.fn.writefile({
      "-----BEGIN OPENSSH PRIVATE KEY-----", "AAAA", "-----END OPENSSH PRIVATE KEY-----",
    }, p)
    return p, pre.fingerprint_file(p)
  end

  --- 以给定配置执行并恢复
  --- @param cfg table
  --- @param fn function
  local function with_cfg(cfg, fn)
    local saved = config_store.get("tools.sandbox.ssh")
    config_store.set("tools.sandbox.ssh", cfg)
    broker.reset()
    local ok, err = pcall(fn)
    config_store.set("tools.sandbox.ssh", saved or {})
    broker.reset()
    if not ok then error(err, 0) end
  end

  --- 构造一个合法别名配置
  --- @param key string
  --- @param fp string
  --- @param extra table|nil
  --- @return table
  local function cfg_for(key, fp, extra)
    local alias = {
      host = "prod.example.com", user = "deploy", port = 2222,
      key = key, fingerprint = fp, accept_new = true,
      allow = { "exec", "tunnel" },
      tunnel = { local_ports = { 10000, 10099 }, remote_hosts = { "db.internal", "*.svc.internal" } },
    }
    for k, v in pairs(extra or {}) do alias[k] = v end
    return { enabled = true, aliases = { prod = alias } }
  end

  it("默认关闭：未启用时拒绝并说明原因", function(t)
    with_cfg({ enabled = false, aliases = {} }, function()
      local cmd, err = broker.build_exec_command("prod", "uptime")
      t.nil_(cmd)
      t.matches("SSH_DISABLED", tostring(err))
    end)
  end)

  it("exec：固定模板，AI 无法传 host/端口/-o", function(t)
    local key, fp = mkkey()
    with_cfg(cfg_for(key, fp), function()
      local cmd, err = broker.build_exec_command("prod", "uptime")
      t.not_nil(cmd, tostring(err))
      t.true_(cmd:find("-F", 1, true) ~= nil and cmd:find("/dev/null", 1, true) ~= nil, cmd)
      t.true_(cmd:find("IdentitiesOnly=yes", 1, true) ~= nil, cmd)
      t.true_(cmd:find("BatchMode=yes", 1, true) ~= nil, cmd)
      t.true_(cmd:find("PermitLocalCommand=no", 1, true) ~= nil, cmd)
      t.true_(cmd:find("ForwardAgent=no", 1, true) ~= nil, cmd)
      t.true_(cmd:find("StrictHostKeyChecking=accept-new", 1, true) ~= nil, cmd)
      t.true_(cmd:find(vim.fn.shellescape(key), 1, true) ~= nil, cmd)
      t.true_(cmd:find("'deploy'", 1, true) ~= nil, cmd)
      t.true_(cmd:find("'2222'", 1, true) ~= nil, cmd)
      t.true_(cmd:find("'prod.example.com'", 1, true) ~= nil, cmd)
      t.true_(cmd:find("'prod.example.com' 'uptime'", 1, true) ~= nil,
        "远端命令应作为 host 之后的单个参数: " .. cmd)
    end)
    vim.fn.delete(key)
  end)

  it("别名校验：拒绝选项注入 / 未知别名 / 未授权动作", function(t)
    local key, fp = mkkey()
    with_cfg(cfg_for(key, fp, { host = "-oProxyCommand=/bin/sh" }), function()
      local _, err = broker.build_exec_command("prod", "uptime")
      t.matches("SSH_ALIAS_INVALID", tostring(err))
    end)
    with_cfg(cfg_for(key, fp, { allow = { "tunnel" } }), function()
      local _, err = broker.build_exec_command("prod", "uptime")
      t.matches("SSH_ALIAS_FORBIDDEN", tostring(err))
    end)
    with_cfg(cfg_for(key, fp), function()
      local _, err = broker.build_exec_command("nope", "uptime")
      t.matches("SSH_ALIAS_UNKNOWN", tostring(err))
    end)
    vim.fn.delete(key)
  end)

  it("指纹钉死：换钥匙/改名后绑定立即失效", function(t)
    local key, fp = mkkey()
    with_cfg(cfg_for(key, fp), function()
      t.not_nil(broker.build_exec_command("prod", "uptime"))
      -- 原地替换密钥内容（模拟「批准一次后换成另一把」）
      vim.fn.writefile({ "-----BEGIN OPENSSH PRIVATE KEY-----", "BBBB", "-----END OPENSSH PRIVATE KEY-----" }, key)
      local cmd, err = broker.build_exec_command("prod", "uptime")
      t.nil_(cmd, "指纹不符必须拒绝")
      t.matches("SSH_ALIAS_KEY_CHANGED", tostring(err))
    end)
    with_cfg(cfg_for(key, nil), function()
      local _, err = broker.build_exec_command("prod", "uptime")
      t.matches("SSH_ALIAS_NO_FINGERPRINT", tostring(err))
    end)
    vim.fn.delete(key)
  end)

  it("隧道：只允许 loopback + 白名单对端 + 端口范围", function(t)
    local key, fp = mkkey()
    with_cfg(cfg_for(key, fp), function()
      local cmd, err = broker.build_tunnel_open_command("prod", {
        local_port = 10050, remote_host = "db.internal", remote_port = 5432,
      })
      t.not_nil(cmd, tostring(err))
      t.true_(cmd:find("127.0.0.1:10050:db.internal:5432", 1, true) ~= nil, cmd)
      t.true_(cmd:find("'-f'", 1, true) ~= nil, "应后台化（-f）")
      t.true_(cmd:find("'-N'", 1, true) ~= nil, "不应执行远端命令（-N）")
      t.true_(cmd:find("ExitOnForwardFailure=yes", 1, true) ~= nil, cmd)
      t.true_(cmd:find("GatewayPorts=no", 1, true) ~= nil, cmd)
      t.true_(cmd:find("'-R'", 1, true) == nil, "不得提供远端转发 -R")
      t.true_(cmd:find("'-D'", 1, true) == nil, "不得提供动态代理 -D")

      local _, e1 = broker.build_tunnel_open_command("prod", {
        local_port = 100, remote_host = "db.internal", remote_port = 5432,
      })
      t.matches("SSH_TUNNEL_PORT_FORBIDDEN", tostring(e1))
      local _, e2 = broker.build_tunnel_open_command("prod", {
        local_port = 10050, remote_host = "evil.example", remote_port = 5432,
      })
      t.matches("SSH_TUNNEL_TARGET_FORBIDDEN", tostring(e2))
      local _, e3 = broker.build_tunnel_open_command("prod", {
        local_port = 10050, remote_host = "x.svc.internal", remote_port = 0,
      })
      t.matches("SSH_TUNNEL_INVALID", tostring(e3))

      local close, cerr = broker.build_tunnel_close_command("prod", 10050)
      t.not_nil(close, tostring(cerr))
      t.true_(close:find("'-O'", 1, true) ~= nil and close:find("'exit'", 1, true) ~= nil, close)
    end)
    vim.fn.delete(key)
  end)

  it("隧道并发上限：达到 max_tunnels 后拒绝新开", function(t)
    local key, fp = mkkey()
    local cfg = cfg_for(key, fp)
    cfg.max_tunnels = 1
    with_cfg(cfg, function()
      local fake = broker.tunnel_dir() .. "/prod-10077.sock"
      vim.fn.writefile({ "" }, fake)
      local cmd, err = broker.build_tunnel_open_command("prod", {
        local_port = 10050, remote_host = "db.internal", remote_port = 5432,
      })
      vim.fn.delete(fake)
      t.nil_(cmd)
      t.matches("SSH_TUNNEL_LIMIT", tostring(err))
    end)
    vim.fn.delete(key)
  end)

  it("工具：ssh_run 只冻结主机操作提案，不执行进程", function(t)
    local key, fp = mkkey()
    with_cfg(cfg_for(key, fp), function()
      local sandbox = require("NeoAI.sandbox")
      sandbox.reset()
      local mod = require("NeoAI.tools.builtin.ssh")
      local run, result_tool
      for _, tl in ipairs(mod.get_tools()) do
        if tl.name == "ssh_run" then run = tl end
        if tl.name == "ssh_result" then result_tool = tl end
      end
      t.not_nil(run)
      t.not_nil(result_tool)
      t.eq("in_process", require("NeoAI.sandbox.execution.tool_spec").get("ssh_run").effect,
        "ssh_run 不应在沙箱内执行进程")

      local out, err
      run.func({ alias = "prod", command = "uptime" }, function(v) out = v end, function(e) err = e end)
      t.nil_(err, tostring(err))
      t.true_(type(out) == "string" and out:find("STAGED host_op=", 1, true) ~= nil, tostring(out))
      local id = out and out:match("host_op=([%w_]+)")
      t.not_nil(id, tostring(out))
      local rec = require("NeoAI.sandbox.execution.hostop").get(id)
      t.not_nil(rec, "应写入主机操作提案")
      t.eq("PENDING", rec.state)
      t.eq("ssh_run", rec.tool)
      t.true_(rec.no_sudo == true, "应使用当前用户执行（不用 root 的 ~/.ssh）")
      t.true_(tostring(rec.command):find("uptime", 1, true) ~= nil)

      local sres, serr
      result_tool.func({ host_op_id = id }, function(v) sres = v end, function(e) serr = e end)
      t.nil_(serr, tostring(serr))
      t.true_(type(sres) == "string" and sres:find("state=PENDING", 1, true) ~= nil, tostring(sres))

      local _, bad = nil, nil
      result_tool.func({ host_op_id = "ho_999_0" }, function() end, function(e) bad = e end)
      t.not_nil(bad, "未知提案应报错")
    end)
    vim.fn.delete(key)
  end)

  it("预授权绑定：可列出使用次数并撤销", function(t)
    local saved = config_store.get("tools.sandbox.protected.preauthorized")
    pre.reset()
    local fp = pre.fingerprint("KEY-A")
    config_store.set("tools.sandbox.protected.preauthorized", {
      { fingerprint = fp, resource = "/tmp/a", consumers = { "egress" }, targets = { "a.example" } },
      { fingerprint = pre.fingerprint("KEY-B"), resource = "/tmp/b", consumers = { "egress" } },
    })
    t.true_(pre.allow({ secret = "KEY-A", consumers = { "egress" }, target = "a.example" }))
    t.eq(1, pre.usage()[1], "应记录使用次数")
    local ok, err = pre.revoke(1)
    t.true_(ok, tostring(err))
    local list = pre.list()
    t.eq(1, #list, "撤销后只剩一条")
    t.eq("/tmp/b", list[1].resource)
    local _, bad = pre.revoke(9)
    t.matches("PREAUTH_INDEX_INVALID", tostring(bad))
    config_store.set("tools.sandbox.protected.preauthorized", saved or {})
    pre.reset()
  end)
end)
