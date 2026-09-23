--- 沙箱网络访问同意专项测试
--- @module NeoAI.tests.test_net_consent
--- 覆盖：沙箱内部进程/端口免权限；访问沙箱外按策略 ask/allow/deny；ask 时弹窗决策；
--- 本次会话记住同意；headless 无 UI 失败关闭。

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
  return port, function()
    pcall(function() srv:close() end)
  end
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

tests.suite("net_consent", function(_, it)
  it("策略解析：默认 ask，配置 allow/deny 生效", function(t)
    local nc = require("NeoAI.sandbox.net_consent")
    nc.reset()
    t.eq("ask", nc.policy(), "默认策略应为 ask")
    with_config({ tools = { sandbox = { network = { access = "allow" } } } }, function()
      t.eq("allow", nc.policy(), "配置 allow 应生效")
    end)
    with_config({ tools = { sandbox = { network = { access = "deny" } } } }, function()
      t.eq("deny", nc.policy(), "配置 deny 应生效")
    end)
    nc.reset()
  end)

  it("内部端口登记：沙箱内服务端口免权限放行", function(t)
    local hp = require("NeoAI.sandbox.host_proxy")
    local nc = require("NeoAI.sandbox.net_consent")
    hp.reset()
    nc.reset()
    local port, close_srv = echo_server()
    nc.register_internal_port(port)
    t.true_(nc.is_internal_port(port), "登记后应判定为内部端口")
    local addr = hp.start("127.0.0.1", 0)
    local resp = tcp_exchange(addr.host, addr.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", resp, "内部端口应免权限放行")
    hp.stop()
    close_srv()
    hp.reset()
    nc.reset()
  end)

  it("headless 无 UI：沙箱外目标失败关闭", function(t)
    local hp = require("NeoAI.sandbox.host_proxy")
    local nc = require("NeoAI.sandbox.net_consent")
    hp.reset()
    nc.reset()
    local port, close_srv = echo_server()
    local addr = hp.start("127.0.0.1", 0)
    local resp = tcp_exchange(addr.host, addr.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("403", resp, "无 UI 时应失败关闭")
    t.matches("host_local_blocked", resp, "应标明本机拦截原因")
    hp.stop()
    close_srv()
    hp.reset()
    nc.reset()
  end)

  it("弹窗同意：allow_once 放行、deny 拒绝、allow_session 记住", function(t)
    local hp = require("NeoAI.sandbox.host_proxy")
    local nc = require("NeoAI.sandbox.net_consent")
    hp.reset()
    nc.reset()
    local port, close_srv = echo_server()

    -- allow_once
    nc.set_ui({ show = function(_, decide) decide("allow_once") end })
    local a1 = hp.start("127.0.0.1", 0)
    local r1 = tcp_exchange(a1.host, a1.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", r1, "同意后应放行")
    hp.stop()

    -- deny
    nc.set_ui({ show = function(_, decide) decide("deny") end })
    local a2 = hp.start("127.0.0.1", 0)
    local r2 = tcp_exchange(a2.host, a2.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("403", r2, "拒绝后应 403")
    hp.stop()

    -- allow_session 记住（随后即使无 UI 也放行）
    nc.set_ui({ show = function(_, decide) decide("allow_session") end })
    local a3 = hp.start("127.0.0.1", 0)
    local r3 = tcp_exchange(a3.host, a3.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", r3, "会话允许后应放行")
    hp.stop()
    nc.set_ui(nil)
    t.true_(nc.is_session_allowed("127.0.0.1", port), "应记住会话同意")
    local a4 = hp.start("127.0.0.1", 0)
    local r4 = tcp_exchange(a4.host, a4.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", r4, "会话内再次访问应免弹窗")
    hp.stop()
    close_srv()
    hp.reset()
    nc.reset()
  end)

  it("外部目标按策略处理：allow 放行、deny 拒绝", function(t)
    local hp = require("NeoAI.sandbox.host_proxy")
    local nc = require("NeoAI.sandbox.net_consent")
    hp.reset()
    nc.reset()
    local port, close_srv = echo_server()
    -- 覆盖判定为外部 + 显式 allow
    local addr = hp.start("127.0.0.1", 0,
      { host_local_fn = function() return false end, access = "allow" })
    local resp = tcp_exchange(addr.host, addr.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", resp, "策略 allow 应放行外部")
    hp.stop()
    local addr2 = hp.start("127.0.0.1", 0,
      { host_local_fn = function() return false end, access = "deny" })
    local resp2 = tcp_exchange(addr2.host, addr2.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("403", resp2, "策略 deny 应拒绝外部")
    t.matches("external_blocked", resp2, "应标明外部拦截原因")
    hp.stop()
    close_srv()
    hp.reset()
    nc.reset()
  end)

  it("软件源自动放行：镜像免弹窗，非软件源仍按策略，可关闭/扩展", function(t)
    local hp = require("NeoAI.sandbox.host_proxy")
    local nc = require("NeoAI.sandbox.net_consent")
    hp.reset()
    nc.reset()

    -- 内置匹配（含子域）
    t.true_(hp._is_package_source("pypi.org"), "pypi.org")
    t.true_(hp._is_package_source("files.pythonhosted.org"), "pythonhosted 子域")
    t.true_(hp._is_package_source("pypi.tuna.tsinghua.edu.cn"), "清华镜像子域")
    t.true_(hp._is_package_source("mirrors.aliyun.com"), "阿里镜像")
    t.true_(hp._is_package_source("registry.npmjs.org"), "npm")
    t.true_(hp._is_package_source("cache.npmmirror.com"), "npmmirror 子域")
    t.true_(hp._is_package_source("archive.ubuntu.com"), "apt")
    -- 边界：后缀/域名内嵌欺骗不匹配
    t.false_(hp._is_package_source("evilpypi.org"), "非子域后缀欺骗")
    t.false_(hp._is_package_source("pypi.org.evil.com"), "域名内嵌欺骗")
    t.false_(hp._is_package_source("example.com"), "普通外部")

    -- 门禁：外部软件源免弹窗（无 UI）放行
    local allowed, reason
    hp._gate(false, "pypi.tuna.tsinghua.edu.cn", 443, {}, "http",
      function(a, r) allowed, reason = a, r end)
    t.true_(allowed, "外部软件源应放行")
    t.eq("allow_source", reason)

    -- 非软件源外部目标：默认 ask + 无 UI → 失败关闭
    local allowed2, reason2, done = nil, nil, false
    hp._gate(false, "example.com", 443, {}, "http",
      function(a, r) allowed2, reason2 = a, r; done = true end)
    vim.wait(1000, function() return done end, 10)
    t.true_(done, "非软件源门禁应回调")
    t.false_(allowed2, "非软件源外部目标应失败关闭")
    t.eq("external_blocked", reason2)

    -- 本机目标即便域名像软件源也不放行（SSRF 防护）
    local allowed3, done3 = nil, false
    hp._gate(true, "pypi.org", 443, {}, "http",
      function(a) allowed3 = a; done3 = true end)
    vim.wait(1000, function() return done3 end, 10)
    t.false_(allowed3, "解析到本机不应放行")

    -- 关闭开关：不自动放行
    with_config({ tools = { sandbox = { network = { auto_allow_sources = false } } } }, function()
      t.false_(hp._is_package_source("pypi.org"), "关闭后不匹配软件源")
    end)

    -- 用户扩展源（精确 + 子域）
    with_config({ tools = { sandbox = { network = { extra_package_sources = { "pypi.mycorp.com" } } } } }, function()
      t.true_(hp._is_package_source("pypi.mycorp.com"), "扩展源精确匹配")
      t.true_(hp._is_package_source("sub.pypi.mycorp.com"), "扩展源子域匹配")
    end)

    hp.stop()
    hp.reset()
    nc.reset()
  end)
end)
