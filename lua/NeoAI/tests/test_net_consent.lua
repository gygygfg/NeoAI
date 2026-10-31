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

--- 最小 HTTP CONNECT 代理（mock）：把 CONNECT 隧道接到给定上游，用于验证链式出网。
local function mock_connect_proxy(upstream_host, upstream_port)
  local srv = vim.uv.new_tcp()
  srv:bind("127.0.0.1", 0)
  srv:listen(16, function(err)
    if err then return end
    local cli = vim.uv.new_tcp()
    srv:accept(cli)
    local buf = ""
    cli:read_start(function(rerr, data)
      if rerr or not data then pcall(function() cli:close() end); return end
      buf = buf .. data
      local idx = buf:find("\r\n\r\n", 1, true)
      if not idx then return end
      cli:read_stop()
      local up = vim.uv.new_tcp()
      up:connect(upstream_host, upstream_port, function(e)
        if e then pcall(function() cli:close() end); return end
        cli:write("HTTP/1.1 200 Connection Established\r\n\r\n")
        up:read_start(function(_, d) if d then cli:write(d) end end)
        cli:read_start(function(_, d) if d then up:write(d) end end)
        local rest = buf:sub(idx + 4)
        if #rest > 0 then up:write(rest) end
      end)
    end)
  end)
  return srv:getsockname().port, function() pcall(function() srv:close() end) end
end

--- 最小 SOCKS5 代理（mock，无认证/域名字段）：把连接接到给定上游。
local function mock_socks5_proxy(upstream_host, upstream_port)
  local srv = vim.uv.new_tcp()
  srv:bind("127.0.0.1", 0)
  srv:listen(16, function(err)
    if err then return end
    local cli = vim.uv.new_tcp()
    srv:accept(cli)
    local stage, buf = "greet", ""
    cli:read_start(function(rerr, data)
      if rerr or not data then pcall(function() cli:close() end); return end
      buf = buf .. data
      if stage == "greet" then
        if #buf < 3 then return end
        cli:write(string.char(5, 0))
        buf = buf:sub(4)
        stage = "req"
      end
      if stage == "req" then
        if #buf < 5 then return end
        local atyp = buf:byte(4)
        local need, rest
        if atyp == 3 then
          need = 5 + buf:byte(5) + 2
          if #buf < need then return end
        elseif atyp == 1 then
          need = 10
          if #buf < need then return end
        else return end
        rest = buf:sub(need + 1)
        local up = vim.uv.new_tcp()
        up:connect(upstream_host, upstream_port, function(e)
          if e then pcall(function() cli:close() end); return end
          cli:write(string.char(5, 0, 0, 1, 0, 0, 0, 0, 0, 0))
          up:read_start(function(_, d) if d then cli:write(d) end end)
          cli:read_start(function(_, d) if d then up:write(d) end end)
          if #rest > 0 then up:write(rest) end
        end)
      end
    end)
  end)
  return srv:getsockname().port, function() pcall(function() srv:close() end) end
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
    local hp = require("NeoAI.sandbox.net.host_proxy")
    local nc = require("NeoAI.sandbox.net.net_consent")
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
    local hp = require("NeoAI.sandbox.net.host_proxy")
    local nc = require("NeoAI.sandbox.net.net_consent")
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

    -- allow_session 记住（随后即使无 UI 也放行）——按 (端口, 服务进程) 颗粒度记忆
    local seen_owner
    nc.set_ui({ show = function(ctx, decide) seen_owner = ctx.owner; decide("allow_session") end })
    local a3 = hp.start("127.0.0.1", 0)
    local r3 = tcp_exchange(a3.host, a3.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", r3, "会话允许后应放行")
    hp.stop()
    nc.set_ui(nil)
    t.true_(nc.is_session_allowed("127.0.0.1", port, seen_owner), "应记住会话同意（端口+进程）")
    local a4 = hp.start("127.0.0.1", 0)
    local r4 = tcp_exchange(a4.host, a4.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(port))
    t.matches("200 Connection Established", r4, "会话内再次访问应免弹窗")
    hp.stop()
    close_srv()
    hp.reset()
    nc.reset()
  end)

  it("弹窗选择会话允许：决策内同步记账并广播（窗口立即可见，不依赖调用方）", function(t)
    local nc = require("NeoAI.sandbox.net.net_consent")
    local hub = require("NeoAI.sandbox.review.approval_hub")
    local bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    nc.reset()
    hub.reset()
    hub.set_ui({ refresh = function() end })
    local changes = 0
    local seen_at_event = nil
    local un = bus.on(events.SANDBOX_APPROVAL_CHANGED, function(p)
      if p and p.page == "network" then
        changes = changes + 1
        -- 关键回归：窗口刷新由该事件触发，事件到达时「本会话已允许」必须已经可见。
        seen_at_event = #nc.list_allowances()
      end
    end)
    nc.set_ui({ show = function(_, decide) decide("allow_session") end })
    local owner = { comm = "postgres", pid = 4242, exe = "/usr/bin/postgres" }
    local decision
    nc.request({ host = "127.0.0.1", port = 5432, local_ = true, owner = owner, owner_resolved = true })
      :then_(function(v) decision = v end)
    t.true_(vim.wait(1000, function() return decision ~= nil end), "请求应 resolve")
    -- 决策内已记账：无需调用方（host_proxy 的延迟回调）再调 allow_session。
    local allow = nc.list_allowances()
    t.eq(1, #allow, "会话允许应立即出现在「本会话已允许」")
    t.matches("127%.0%.0%.1:5432", allow[1].key, "key 应含目标")
    t.true_(nc.is_session_allowed("127.0.0.1", 5432, owner), "应记住会话允许")
    t.true_(changes >= 1, "应广播 SANDBOX_APPROVAL_CHANGED(page=network) 触发窗口重绘")
    t.eq(1, seen_at_event, "广播时「本会话已允许」应已含该条目（重绘不会读到空列表）")
    un()
    nc.set_ui(nil)
    nc.reset()
    hub.set_ui(nil)
    hub.reset()
  end)

  it("决策历史与本会话允许可撤销", function(t)
    local nc = require("NeoAI.sandbox.net.net_consent")
    nc.reset()
    -- 单次允许：入历史，不入允许列表
    nc.set_ui({ show = function(_, decide) decide("allow_once") end })
    local r1
    nc.request({ host = "example.com", port = 443, local_ = false, proto = "tcp" })
      :then_(function(v) r1 = v end)
    t.true_(vim.wait(1000, function() return r1 ~= nil end), "请求应 resolve")
    t.eq("allow_once", r1)
    local hist = nc.list_history()
    t.eq(1, #hist, "单次允许应入历史")
    t.eq("allow_once", hist[1].decision)
    t.eq("example.com", hist[1].host)
    t.eq(0, #nc.list_allowances(), "单次允许不入会话允许列表")

    -- 拒绝：入历史
    nc.set_ui({ show = function(_, decide) decide("deny") end })
    local r2
    nc.request({ host = "deny.example", port = 80, local_ = false })
      :then_(function(v) r2 = v end)
    t.true_(vim.wait(1000, function() return r2 ~= nil end), "请求应 resolve")
    t.eq("deny", r2)
    hist = nc.list_history()
    t.eq(2, #hist, "拒绝应入历史")
    t.eq("deny", hist[1].decision, "新记录在最前")

    -- 会话允许：入允许列表，不入历史（host_proxy 在决策后调用 allow_session）
    local owner = { comm = "postgres", pid = 4242, exe = "/usr/bin/postgres" }
    nc.set_ui({ show = function(_, decide) decide("allow_session") end })
    local r3
    nc.request({ host = "127.0.0.1", port = 5432, local_ = true, owner = owner, owner_resolved = true })
      :then_(function(v) r3 = v end)
    t.true_(vim.wait(1000, function() return r3 ~= nil end), "请求应 resolve")
    t.eq("allow_session", r3)
    nc.allow_session("127.0.0.1", 5432, owner)
    local allow = nc.list_allowances()
    t.eq(1, #allow, "会话允许应入允许列表")
    t.matches("127%.0%.0%.1:5432", allow[1].key, "key 应含目标")
    t.eq("postgres", allow[1].comm, "应含服务身份")
    t.true_(nc.is_session_allowed("127.0.0.1", 5432, owner), "应记住会话允许")
    t.eq(2, #nc.list_history(), "会话允许不入历史")

    -- 撤销：移除允许 + 追加「已撤销」历史
    t.true_(nc.revoke_allowance(allow[1].key), "应能撤销")
    t.false_(nc.is_session_allowed("127.0.0.1", 5432, owner), "撤销后不再免弹窗")
    t.eq(0, #nc.list_allowances(), "撤销后允许列表为空")
    local hist2 = nc.list_history()
    t.eq(3, #hist2, "撤销应追加历史")
    t.eq("revoked", hist2[1].decision)
    t.false_(nc.revoke_allowance("不存在"), "撤销不存在的 key 应为 false")
    nc.set_ui(nil)
    nc.reset()
  end)

  it("外部目标按策略处理：allow 放行、deny 拒绝", function(t)
    local hp = require("NeoAI.sandbox.net.host_proxy")
    local nc = require("NeoAI.sandbox.net.net_consent")
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
    -- 代码托管：GitHub 及其子域 / raw 域静默放行
    t.true_(hp._is_package_source("github.com"), "github.com")
    t.true_(hp._is_package_source("codeload.github.com"), "github 子域")
    t.true_(hp._is_package_source("raw.githubusercontent.com"), "githubusercontent 子域")
    -- 边界：后缀/域名内嵌欺骗不匹配
    t.false_(hp._is_package_source("evilpypi.org"), "非子域后缀欺骗")
    t.false_(hp._is_package_source("pypi.org.evil.com"), "域名内嵌欺骗")
    t.false_(hp._is_package_source("example.com"), "普通外部")
    t.false_(hp._is_package_source("notgithub.com"), "非 github 子域")

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
    local s = hp.summary()
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
    local owner = nc.port_owner(port)
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

  it("历史按目标去重，且超时自动拒绝条目可重新允许（补救）", function(t)
    local nc = require("NeoAI.sandbox.net.net_consent")
    nc.reset()
    local owner = { comm = "postgres", pid = 77, exe = "/usr/bin/postgres" }
    -- 同一目标两次拒绝（其中一次超时）；另一目标一次单次允许
    with_config({ tools = { sandbox = { network = { consent_timeout_ms = 100 } } } }, function()
      nc.set_ui({ show = function() end }) -- 永不决策 → 超时自动拒绝
      local d1
      nc.request({ host = "127.0.0.1", port = 5432, local_ = true, owner = owner, owner_resolved = true })
        :then_(function(v) d1 = v end)
      t.true_(vim.wait(1500, function() return d1 ~= nil end, 20), "超时后应 resolve")
      t.eq("deny", d1)
    end)
    nc.set_ui({ show = function(_, decide) decide("allow_once") end })
    local d2
    nc.request({ host = "127.0.0.1", port = 5432, local_ = true, owner = owner, owner_resolved = true })
      :then_(function(v) d2 = v end)
    t.true_(vim.wait(1000, function() return d2 ~= nil end), "单次允许应 resolve")
    local d3
    nc.request({ host = "example.com", port = 443, local_ = false })
      :then_(function(v) d3 = v end)
    t.true_(vim.wait(1000, function() return d3 ~= nil end), "外部目标应 resolve")

    local hist = nc.list_history()
    t.eq(2, #hist, "同目标应合并为一条")
    local local_rec
    for _, h in ipairs(hist) do
      if h.host == "127.0.0.1" and h.port == 5432 then local_rec = h end
    end
    t.not_nil(local_rec, "应含 127.0.0.1:5432")
    t.eq(2, local_rec.count, "应累计同目标次数")
    t.eq("allow_once", local_rec.decision, "取最近一次决策")
    t.true_(local_rec.timed_out, "同目标仍存在未补救的超时拒绝")
    t.not_nil(local_rec.key, "应提供目标键")
    -- 超时拒绝条目被历史合并后仍可按键补救
    t.true_(nc.allow_from_history(local_rec.key), "应能重新允许")
    t.true_(nc.is_session_allowed("127.0.0.1", 5432, owner), "重新允许后应本会话免弹窗")
    local after = nc.list_history()
    local rec2
    for _, h in ipairs(after) do
      if h.key == local_rec.key then rec2 = h end
    end
    t.true_(rec2.remedied, "应标记为已补救")
    t.false_(rec2.timed_out, "补救后不再提示重新允许")
    t.false_(nc.allow_from_history(local_rec.key), "重复补救应返回 false")
    t.false_(nc.allow_from_history("不存在"), "未知键应返回 false")
    -- 单次允许（非超时）不可补救
    local ext
    for _, h in ipairs(after) do
      if h.host == "example.com" then ext = h end
    end
    t.false_(nc.allow_from_history(ext.key), "非超时拒绝不可重新允许")
    nc.set_ui(nil)
    nc.reset()
  end)

  it("并发同目标请求在审批中心合并为一条，一次决策全部生效", function(t)
    local nc = require("NeoAI.sandbox.net.net_consent")
    local hub = require("NeoAI.sandbox.review.approval_hub")
    nc.reset()
    hub.reset()
    local owner = { comm = "postgres", pid = 9, exe = "/usr/bin/postgres" }
    with_config({ tools = { sandbox = { network = { consent_timeout_ms = 0 } } } }, function()
      nc.set_ui({ show = function() end }) -- 独立弹窗不决策，留给中心决策
      local got = {}
      for i = 1, 2 do
        nc.request({ host = "127.0.0.1", port = 5432, local_ = true, owner = owner, owner_resolved = true })
          :then_(function(v) got[i] = v end)
      end
      local list = hub.list("network")
      t.eq(1, #list, "同目标应合并为一条待批准")
      t.eq(2, list[1].count, "合并计数应为 2")
      t.eq(1, hub.pending_count("network"), "待批准计数按去重后计")
      t.true_(hub.resolve(list[1].id, "allow_session"), "应能决策")
      vim.wait(1000, function() return got[1] ~= nil and got[2] ~= nil end, 10)
      t.eq("allow_session", got[1], "第 1 个请求应结算")
      t.eq("allow_session", got[2], "第 2 个请求应结算")
      t.eq(0, hub.pending_count("network"), "决策后条目应移除")
    end)
    nc.set_ui(nil)
    nc.reset()
    hub.reset()
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
