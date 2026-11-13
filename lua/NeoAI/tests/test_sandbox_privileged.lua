--- 沙箱高权限模式测试
--- @module 'NeoAI.tests.test_sandbox_privileged'
--- 验证高权限模式对沙箱底层策略的影响：网络仅记录不拦截、容器门面旁路、
--- docker socket 挂载/unmask、podman 容器能力注入，以及退出后完全恢复。

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

local function set_privileged(on)
  local sp = require("NeoAI.sandbox.privileged")
  sp.mark("priv_test_agent", on ~= false)
  sp.set_current(on ~= false and "priv_test_agent" or nil)
end

local function reset_privileged()
  require("NeoAI.sandbox.privileged").reset()
  require("NeoAI.sandbox.net.net_consent").reset()
  require("NeoAI.sandbox.net.host_proxy").reset()
end

local function echo_server()
  local srv = vim.uv.new_tcp()
  srv:bind("127.0.0.1", 0)
  srv:listen(16, function(err)
    if err then return end
    local cli = vim.uv.new_tcp()
    srv:accept(cli)
    cli:read_start(function(rerr, data)
      if rerr or not data then
        pcall(function() cli:close() end)
        return
      end
      pcall(function() cli:write(data) end)
    end)
  end)
  local port = srv:getsockname().port
  return port, function() pcall(function() srv:close() end) end
end

local function tcp_exchange(host, port, payload, timeout)
  local cli = vim.uv.new_tcp()
  local got, done = {}, false
  cli:connect(host, port, function(err)
    if err then done = true; return end
    cli:write(payload)
    cli:read_start(function(rerr, data)
      if rerr or not data then done = true; return end
      if #data > 0 then got[#got + 1] = data end
    end)
  end)
  vim.wait(timeout or 3000, function() return done end)
  pcall(function() cli:close() end)
  return table.concat(got)
end

tests.suite("sandbox_privileged", function(_, it)
  it("网络策略：高权限放行 access=deny 并记录目标", function(t)
    with_config({ tools = { sandbox = { network = { access = "deny" } } } }, function()
      reset_privileged()
      local nc = require("NeoAI.sandbox.net.net_consent")
      local hp = require("NeoAI.sandbox.net.host_proxy")
      local sp = require("NeoAI.sandbox.privileged")
      t.eq("deny", nc.policy(), "高权限关闭时应遵循配置")
      set_privileged(true)
      t.eq("allow", nc.policy(), "高权限应覆盖 deny")

      local port, close_srv = echo_server()
      local addr = hp.start("127.0.0.1", 0)
      local resp = tcp_exchange(addr.host, addr.port,
        ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
      t.matches("200 Connection Established", resp, "高权限应直接放行")
      local recs = hp.recent(10)
      t.true_(#recs > 0, "应记录网络目标")
      t.eq(port, tonumber(recs[1].port), "记录应包含端口")
      t.true_(#sp.records(10) > 0, "高权限记录环形缓冲也应有条目")
      hp.stop()
      close_srv()
      reset_privileged()
    end)
  end)

  it("网络策略：进程内任一 PRIV 会话即放行并记录，焦点切换不影响", function(t)
    with_config({ tools = { sandbox = { network = { access = "deny" } } } }, function()
      reset_privileged()
      local nc = require("NeoAI.sandbox.net.net_consent")
      local hp = require("NeoAI.sandbox.net.host_proxy")
      local sp = require("NeoAI.sandbox.privileged")
      set_privileged(true)
      -- 模拟 UI 焦点切到另一个窗口/新建会话：current 指向别的（非 PRIV）Agent。
      sp.set_current("other_agent")
      t.eq("allow", nc.policy(), "存在 PRIV 会话即放行，不随焦点/current 漂移")

      local port, close_srv = echo_server()
      local addr = hp.start("127.0.0.1", 0)
      local resp = tcp_exchange(addr.host, addr.port,
        ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
      t.matches("200 Connection Established", resp, "焦点在别处时仍应放行")
      t.true_(#hp.recent(10) > 0, "host_proxy 应记录目标")
      t.true_(#sp.records(10) > 0, "PRIV 环形记录应写入")
      hp.stop()
      close_srv()
      reset_privileged()
    end)
  end)

  it("网络策略：退出最后一个 PRIV 会话后恢复配置", function(t)
    with_config({ tools = { sandbox = { network = { access = "deny" } } } }, function()
      reset_privileged()
      local nc = require("NeoAI.sandbox.net.net_consent")
      local sp = require("NeoAI.sandbox.privileged")
      set_privileged(true)
      t.eq("allow", nc.policy())
      sp.set_current("other_agent")
      sp.mark("priv_test_agent", false)
      t.eq("deny", nc.policy(), "无 PRIV 会话时应遵循配置")
      reset_privileged()
    end)
  end)

  it("策略：offline=true 时非 current 的 PRIV 会话仍放行网络类工具", function(t)
    with_config({ tools = { sandbox = { offline = true } } }, function()
      reset_privileged()
      local policy = require("NeoAI.sandbox.review.policy")
      local sp = require("NeoAI.sandbox.privileged")
      set_privileged(true)
      sp.set_current("other_agent")
      local res = policy.evaluate({ tool = "web_fetch", effect = "network", args = { url = "https://x" } })
      t.eq("ALLOW", res.decision, "存在 PRIV 会话时应解除 offline 拒绝")
      sp.mark("priv_test_agent", false)
      local after = policy.evaluate({ tool = "web_fetch", effect = "network", args = { url = "https://x" } })
      t.eq("DENY", after.decision, "无 PRIV 会话时 offline 仍硬拒绝")
      reset_privileged()
    end)
  end)

  it("网络代理：高权限即使 host_local_block=false 也启动以记录", function(t)
    with_config({ tools = { sandbox = { network = { host_local_block = false } } } }, function()
      reset_privileged()
      local hp = require("NeoAI.sandbox.net.host_proxy")
      t.nil_(hp.ensure(), "非高权限且关闭 host_local_block 时不启动代理")
      set_privileged(true)
      local addr = hp.ensure()
      t.not_nil(addr, "高权限下应启动代理用于记录")
      hp.stop()
      reset_privileged()
    end)
  end)

  it("网络策略：offline=true 时高权限仍放行网络类工具", function(t)
    with_config({ tools = { sandbox = { offline = true } } }, function()
      reset_privileged()
      local policy = require("NeoAI.sandbox.review.policy")
      local before = policy.evaluate({ tool = "web_fetch", effect = "network", args = { url = "https://x" } })
      t.eq("DENY", before.decision, "非高权限时 offline 应硬拒绝")
      set_privileged(true)
      local after = policy.evaluate({ tool = "web_fetch", effect = "network", args = { url = "https://x" } })
      t.eq("ALLOW", after.decision, "高权限应解除 offline 拒绝")
      reset_privileged()
    end)
  end)

  it("容器门面：高权限完全旁路（不改写、不生成入口桩）", function(t)
    with_config({ tools = { sandbox = { container = { enabled = true } } } }, function()
      reset_privileged()
      local container = require("NeoAI.sandbox.execution.container")
      local runtime = require("NeoAI.sandbox.execution.runtime")
      t.not_nil(container.facade("docker run ubuntu true"), "非高权限时门面接管")
      set_privileged(true)
      t.nil_(container.facade("docker run ubuntu true"), "高权限时门面返回 nil")
      t.nil_(container.plan("podman run ubuntu true"), "高权限时不注入共享命名空间标志")
      t.nil_(runtime._container_stubs(), "高权限时不生成 docker→podman 入口桩")
      reset_privileged()
    end)
  end)

  it("docker：高权限进程命令挂载宿主 socket 并解除遮蔽", function(t)
    local fs = require("NeoAI.utils.fs")
    local dir = vim.fn.tempname()
    fs.ensure_dir(dir)
    local sock = dir .. "/docker.sock"
    fs.write_file(sock, "")
    with_config({
      tools = {
        sandbox = { privilege = { max_tier = 2 } },
        privileged_mode = { docker_socket = sock },
      },
    }, function()
      reset_privileged()
      local privilege = require("NeoAI.sandbox.execution.privilege")
      local plain = privilege.resolve(1, { tier = 1, docker = true, network = true }, { process = true })
      t.eq(nil, plain.privileges.env.DOCKER_HOST, "非高权限不注入 DOCKER_HOST")
      t.false_(plain.privileges.privileged == true, "非高权限不应标记 privileged")
      set_privileged(true)
      local res = privilege.resolve(1, { tier = 1, docker = true, network = true },
        { process = true, agent_id = "priv_test_agent" })
      t.true_(res.ok)
      t.true_(res.privileges.privileged == true, "高权限应标记 privileged（入口桩按执行 Agent 跳过）")
      t.eq("unix:///run/docker.sock", res.privileges.env.DOCKER_HOST, "应注入 DOCKER_HOST")
      local mounted = false
      for _, m in ipairs(res.privileges.mounts) do
        if m.dst == "/run/docker.sock" and m.src == sock then mounted = true end
      end
      t.true_(mounted, "应挂载配置的 docker socket")
      t.true_(vim.tbl_contains(res.privileges.unmask, "/run/docker.sock"), "应解除遮蔽")
      reset_privileged()
    end)
    vim.fn.delete(dir, "rf")
  end)

  it("SSH：高权限不遮蔽 ~/.ssh（可用 unmask_ssh_keys=false 关闭）", function(t)
    with_config({ tools = { sandbox = { privilege = { max_tier = 2 } } } }, function()
      reset_privileged()
      local privilege = require("NeoAI.sandbox.execution.privilege")
      local sp = require("NeoAI.sandbox.privileged")
      local ssh_dir = vim.fn.expand("~/.ssh")
      local plain = privilege.resolve(0, { tier = 0 }, { process = true })
      t.false_(vim.tbl_contains(plain.privileges.unmask, ssh_dir), "非高权限仍遮蔽 SSH")
      set_privileged(true)
      local res = privilege.resolve(0, { tier = 0 },
        { process = true, agent_id = "priv_test_agent" })
      t.true_(vim.tbl_contains(res.privileges.unmask, ssh_dir), "高权限应解除 ~/.ssh 遮蔽")
      t.true_(sp.is_ssh_path(ssh_dir .. "/id_ed25519"), "应识别 SSH 密钥子路径")
      t.false_(sp.is_ssh_path("/etc/passwd"), "非 SSH 路径不应命中")
      reset_privileged()
    end)

    with_config({
      tools = {
        sandbox = { privilege = { max_tier = 2 } },
        privileged_mode = { unmask_ssh_keys = false },
      },
    }, function()
      reset_privileged()
      local privilege = require("NeoAI.sandbox.execution.privilege")
      set_privileged(true)
      local res = privilege.resolve(0, { tier = 0 },
        { process = true, agent_id = "priv_test_agent" })
      t.false_(vim.tbl_contains(res.privileges.unmask, vim.fn.expand("~/.ssh")),
        "unmask_ssh_keys=false 时应保留 SSH 遮蔽")
      reset_privileged()
    end)
  end)

  it("podman：高权限即使门面关闭也注入容器能力/vfs/seccomp 例外", function(t)
    with_config({ tools = { sandbox = { container = { enabled = false } } } }, function()
      reset_privileged()
      local privilege = require("NeoAI.sandbox.execution.privilege")
      local plain = privilege.resolve(0, { tier = 0, container = true, network = true },
        { process = true, agent_id = "priv_test_agent" })
      t.eq(nil, plain.privileges.env.STORAGE_DRIVER, "非高权限不改写存储驱动")
      set_privileged(true)
      local res = privilege.resolve(0, { tier = 0, container = true, network = true },
        { process = true, agent_id = "priv_test_agent" })
      t.eq("vfs", res.privileges.env.STORAGE_DRIVER, "高权限 podman 应注入 vfs")
      t.true_(vim.tbl_contains(res.privileges.cap_add, "ALL"), "应授予容器运行时能力")
      t.eq(false, res.privileges.seccomp, "容器命令应关闭 seccomp 基线")
      reset_privileged()
    end)
  end)

  it("reset 清理高权限状态", function(t)
    local sp = require("NeoAI.sandbox.privileged")
    sp.reset()
    set_privileged(true)
    t.true_(sp.active())
    sp.record({ host = "example.com", port = 443, proto = "http", decision = "allow" })
    t.eq(1, #sp.records(10))
    sp.reset()
    t.false_(sp.active())
    t.eq(0, #sp.records(10))
  end)
end)
