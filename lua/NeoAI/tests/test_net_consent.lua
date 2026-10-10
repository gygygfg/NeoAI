--- 沙箱网络访问同意专项测试
--- @module 'NeoAI.tests.test_net_consent'
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
    local nc = require("NeoAI.sandbox.net.net_consent")
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
    local hp = require("NeoAI.sandbox.net.host_proxy")
    local nc = require("NeoAI.sandbox.net.net_consent")
    hp.reset()
    nc.reset()
    local port, close_srv = echo_server()
    nc.register_internal_port(port)
    t.true_(nc.is_internal_port(port), "登记后应判定为内部端口")
    local addr = assert(hp.start("127.0.0.1", 0))
    local resp = tcp_exchange(addr.host, addr.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", resp, "内部端口应免权限放行")
    hp.stop()
    close_srv()
    hp.reset()
    nc.reset()
  end)

  it("headless 无 UI：沙箱外目标失败关闭", function(t)
    local hp = require("NeoAI.sandbox.net.host_proxy")
    local nc = require("NeoAI.sandbox.net.net_consent")
    hp.reset()
    nc.reset()
    local port, close_srv = echo_server()
    local addr = assert(hp.start("127.0.0.1", 0))
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
    local hp = require("NeoAI.sandbox.net.host_proxy")
    local nc = require("NeoAI.sandbox.net.net_consent")
    hp.reset()
    nc.reset()
    local port, close_srv = echo_server()

    -- allow_once
    nc.set_ui({ show = function(_, decide) decide("allow_once") end })
    local a1 = assert(hp.start("127.0.0.1", 0))
    local r1 = tcp_exchange(a1.host, a1.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", r1, "同意后应放行")
    hp.stop()

    -- deny
    nc.set_ui({ show = function(_, decide) decide("deny") end })
    local a2 = assert(hp.start("127.0.0.1", 0))
    local r2 = tcp_exchange(a2.host, a2.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("403", r2, "拒绝后应 403")
    hp.stop()

    -- allow_session 记住（随后即使无 UI 也放行）——按 (端口, 服务进程) 颗粒度记忆
    local seen_owner
    nc.set_ui({ show = function(ctx, decide) seen_owner = ctx.owner; decide("allow_session") end })
    local a3 = assert(hp.start("127.0.0.1", 0))
    local r3 = tcp_exchange(a3.host, a3.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", r3, "会话允许后应放行")
    hp.stop()
    nc.set_ui(nil)
    t.true_(nc.is_session_allowed("127.0.0.1", port, seen_owner), "应记住会话同意（端口+进程）")
    local a4 = assert(hp.start("127.0.0.1", 0))
    local r4 = tcp_exchange(a4.host, a4.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", r4, "会话内再次访问应免弹窗")
    hp.stop()
    close_srv()
    hp.reset()
    nc.reset()
  end)

  it("同意弹窗在沙箱服务晚于 UI 就绪时仍注册（与其它审批弹窗一致）", function(t)
    local services = require("NeoAI.kernel.services")
    local ui = require("NeoAI.ui.components.net_consent")
    local saved = services.use("services.sandbox")
    services.revoke("services.sandbox")
    ui.reset()
    ---@type any
    local captured = nil
    ui.init() -- 沙箱服务尚未就绪（phase 2 晚于 ui phase 1）
    t.eq(nil, captured, "沙箱未就绪时无目标可注册")
    services.provide("services.sandbox", { set_net_consent_ui = function(u) captured = u end })
    t.not_nil(captured, "沙箱服务就绪后应自动注册弹窗 UI")
    t.eq("function", type(captured.show), "应注册 show 回调")
    ui.reset()
    services.provide("services.sandbox", saved)
  end)

  it("外部目标按策略处理：allow 放行、deny 拒绝", function(t)
    local hp = require("NeoAI.sandbox.net.host_proxy")
    local nc = require("NeoAI.sandbox.net.net_consent")
    hp.reset()
    nc.reset()
    local port, close_srv = echo_server()
    -- 覆盖判定为外部 + 显式 allow
    local addr = assert(hp.start("127.0.0.1", 0,
      { host_local_fn = function() return false end, access = "allow" }))
    local resp = tcp_exchange(addr.host, addr.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", resp, "策略 allow 应放行外部")
    hp.stop()
    local addr2 = assert(hp.start("127.0.0.1", 0,
      { host_local_fn = function() return false end, access = "deny" }))
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
    local hp = require("NeoAI.sandbox.net.host_proxy")
    local nc = require("NeoAI.sandbox.net.net_consent")
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

  it("网络访问摘要：仅回传拦截/失败，软件源等放行不回传", function(t)
    local hp = require("NeoAI.sandbox.net.host_proxy")
    hp.reset()
    -- 只有自动放行：无摘要（不显示「…[http]放行」）
    hp._record_for_test("pypi.tuna.tsinghua.edu.cn", 443, "http", "allow_source")
    hp._record_for_test("registry.npmjs.org", 443, "http", "allow_source")
    t.nil_(hp.summary(), "仅自动放行时应无摘要")
    -- 混合：只回传拦截
    hp._record_for_test("pypi.tuna.tsinghua.edu.cn", 443, "http", "allow_source")
    hp._record_for_test("evil.example.com", 443, "http", "block")
    local s = assert(hp.summary())
    t.not_nil(s, "有拦截时应返回摘要")
    t.true_(s:find("evil.example.com:443", 1, true) ~= nil, "应含被拦截目标")
    t.true_(s:find("已拦截", 1, true) ~= nil, "应标注已拦截")
    t.true_(s:find("pypi.tuna", 1, true) == nil, "自动放行不应出现在摘要")
    hp.reset()
  end)

  it("端口→宿主进程解析：真实监听进程（pid+comm）", function(t)
    local nc = require("NeoAI.sandbox.net.net_consent")
    nc.reset()
    local port, close_srv = echo_server()
    local owner = assert(nc.port_owner(port))
    t.not_nil(owner, "应解析出宿主监听进程")
    t.eq(vim.uv.os_getpid(), owner.pid, "监听进程应为本测试进程")
    t.not_nil(owner.comm, "应含进程名")
    -- 非同端口的端口无监听者
    t.nil_(nc.port_owner(port + 1), "未监听端口应解析为 nil")
    close_srv()
    nc.reset()
  end)

  it("服务粒度会话记忆：同端口换进程视为未同意", function(t)
    local nc = require("NeoAI.sandbox.net.net_consent")
    nc.reset()
    local ownerA = { pid = 1, comm = "postgres", exe = "/usr/lib/postgresql/16/bin/postgres" }
    local ownerB = { pid = 2, comm = "evil", exe = "/tmp/evil" }
    nc.allow_session("127.0.0.1", 5432, ownerA)
    t.true_(nc.is_session_allowed("127.0.0.1", 5432, ownerA), "同进程应免弹窗")
    t.false_(nc.is_session_allowed("127.0.0.1", 5432, ownerB), "换进程应重新询问")
    t.true_(nc.has_session_approval("127.0.0.1", 5432), "端口应存在服务粒度批准标记")
    t.false_(nc.has_session_approval("127.0.0.1", 5433), "其它端口无标记")
    nc.reset()
  end)

  it("相关批准提示：同进程其它端口 / 同端口其它进程", function(t)
    local nc = require("NeoAI.sandbox.net.net_consent")
    nc.reset()
    local pg = { comm = "postgres", exe = "/usr/bin/postgres" }
    local other = { comm = "redis", exe = "/usr/bin/redis-server" }
    nc.allow_session("127.0.0.1", 5432, pg)
    nc.allow_session("127.0.0.1", 5433, pg)
    nc.allow_session("127.0.0.1", 5432, other)
    local rel = nc.related_approvals("127.0.0.1", 5432, pg)
    local has_port, has_svc = false, false
    for _, p in ipairs(rel.ports) do if p == "127.0.0.1:5433" then has_port = true end end
    for _, s in ipairs(rel.services) do if s == other.exe then has_svc = true end end
    t.true_(has_port, "应提示同进程的其它端口")
    t.true_(has_svc, "应提示同端口的其它进程")
    nc.reset()
  end)

  it("弹窗无响应超时自动拒绝（fail-closed）", function(t)
    local nc = require("NeoAI.sandbox.net.net_consent")
    nc.reset()
    nc.set_ui({ show = function() end }) -- 永不决策
    with_config({ tools = { sandbox = { network = { consent_timeout_ms = 100 } } } }, function()
      local decision
      local d = nc.request({ host = "127.0.0.1", port = 1, local_ = true })
      d:then_(function(v) decision = v end)
      vim.wait(1500, function() return decision ~= nil end, 20)
      t.eq("deny", decision, "超时应自动拒绝")
    end)
    nc.set_ui(nil)
    nc.reset()
  end)

  it("端口→进程解析带 TTL 缓存（重复调用复用）", function(t)
    local nc = require("NeoAI.sandbox.net.net_consent")
    nc.reset()
    local port, close_srv = echo_server()
    local a = nc.port_owner(port)
    local b = nc.port_owner(port)
    t.eq(a and a.pid, b and b.pid, "TTL 内应复用缓存结果")
    close_srv()
    nc.reset()
  end)
end)
