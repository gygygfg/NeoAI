--- 沙箱网络网关测试
--- @module NeoAI.tests.test_gateway
--- 覆盖：代理请求解析、宿主本机地址判定、端口探针 + 服务拦截原因（HTTP 代理响应）。
--- 不依赖真实外部网络；使用本地 127.0.0.1 监听/关闭端口验证。

local tests = require("NeoAI.tests")

local function with_config(overrides, fn)
  local config_store = require("NeoAI.kernel.config_store")
  local saved = config_store.get_all()
  config_store.load(overrides)
  local ok, err = pcall(fn)
  config_store.load(saved)
  if not ok then error(err, 0) end
end

--- 启动一个本地 TCP 监听，返回 port 与关闭函数
local function listen_local()
  local srv = vim.uv.new_tcp()
  srv:bind("127.0.0.1", 0)
  srv:listen(16, function() end)
  local name = srv:getsockname()
  return name.port, function() pcall(function() srv:close() end) end
end

--- 启动一个回显 TCP 服务，返回 port 与关闭函数
local function echo_server()
  local srv = vim.uv.new_tcp()
  srv:bind("127.0.0.1", 0)
  srv:listen(16, function()
    local c = vim.uv.new_tcp()
    local ok = pcall(function() srv:accept(c) end)
    if not ok then return end
    c:read_start(function(err, data)
      if err or not data then pcall(function() c:close() end); return end
      c:write(data)
    end)
  end)
  return srv:getsockname().port, function() pcall(function() srv:close() end) end
end

--- 向 host:port 发送 payload，读取全部响应直到连接关闭
local function tcp_exchange(host, port, payload, timeout_ms)
  local cli = vim.uv.new_tcp()
  local chunks, done = {}, false
  cli:connect(host, port, function(err)
    if err then done = true; return end
    cli:write(payload)
    cli:read_start(function(rerr, data)
      if data and #data > 0 then chunks[#chunks + 1] = data end
      if rerr or not data then done = true; pcall(function() cli:close() end) end
    end)
  end)
  vim.wait(timeout_ms or 3000, function() return done end)
  pcall(function() cli:close() end)
  return table.concat(chunks)
end

--- 向网关发一个 HTTP 请求，返回响应文本
local function proxy_request(host, port, request, timeout_ms)
  local cli = vim.uv.new_tcp()
  local chunks = {}
  local done = false
  cli:connect(host, port, function(err)
    if err then done = true; return end
    cli:write(request)
    cli:read_start(function(rerr, data)
      if data and #data > 0 then chunks[#chunks + 1] = data end
      if rerr or not data then done = true; pcall(function() cli:close() end) end
    end)
  end)
  vim.wait(timeout_ms or 3000, function() return done end)
  pcall(function() cli:close() end)
  return table.concat(chunks)
end

tests.suite("gateway", function(_, it)
  it("解析代理目标（CONNECT 与绝对形式 URL）", function(t)
    local gw = require("NeoAI.sandbox.gateway")
    local h, p = gw._parse_target("CONNECT 127.0.0.1:22 HTTP/1.1")
    t.eq("127.0.0.1", h)
    t.eq(22, p)
    local h2, p2 = gw._parse_target("GET http://localhost:8080/x HTTP/1.1")
    t.eq("localhost", h2)
    t.eq(8080, p2)
    local h3, p3 = gw._parse_target("GET http://example.com/ HTTP/1.1")
    t.eq("example.com", h3)
    t.eq(80, p3)
  end)

  it("仅允许宿主本机地址", function(t)
    local gw = require("NeoAI.sandbox.gateway")
    t.true_(gw._is_host_local("127.0.0.1"), "回环应允许")
    t.true_(gw._is_host_local("localhost"), "localhost 应允许")
    t.false_(gw._is_host_local("8.8.8.8"), "外部地址应拒绝")
  end)

  it("开放端口：探针判定开放，但服务被拦截并返回原因", function(t)
    local gw = require("NeoAI.sandbox.gateway")
    gw.reset()
    local open_port, close_srv = listen_local()
    local addr = gw.start("127.0.0.1", 0)
    t.not_nil(addr, "网关应能启动")
    local resp = proxy_request(addr.host, addr.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(open_port, open_port))
    close_srv()
    t.matches("403", resp, "开放端口应返回 403（服务被拦截）")
    t.matches('"open":true', resp, "响应应标明端口开放")
    t.matches("service_access_blocked", resp, "响应应包含拦截原因")
    gw.stop()
  end)

  it("关闭端口：探针判定关闭", function(t)
    local gw = require("NeoAI.sandbox.gateway")
    gw.reset()
    local addr = gw.start("127.0.0.1", 0)
    t.not_nil(addr, "网关应能启动")
    local resp = proxy_request(addr.host, addr.port,
      "CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n")
    t.matches("502", resp, "关闭端口应返回 502")
    t.matches('"open":false', resp, "响应应标明端口关闭")
    gw.stop()
  end)

  it("外部地址被拒绝并返回原因", function(t)
    local gw = require("NeoAI.sandbox.gateway")
    gw.reset()
    local addr = gw.start("127.0.0.1", 0)
    local resp = proxy_request(addr.host, addr.port,
      "CONNECT 8.8.8.8:53 HTTP/1.1\r\nHost: 8.8.8.8:53\r\n\r\n")
    t.matches("403", resp, "外部地址应 403")
    t.matches("only_host_local_addresses_allowed", resp, "应给出仅允许本机地址的原因")
    gw.stop()
  end)

  it("探测摘要回传开放/关闭端口", function(t)
    local gw = require("NeoAI.sandbox.gateway")
    gw.reset()
    local open_port, close_srv = listen_local()
    local addr = gw.start("127.0.0.1", 0)
    proxy_request(addr.host, addr.port, ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(open_port))
    close_srv()
    local s = gw.summary()
    t.not_nil(s, "应有探测摘要")
    t.matches("开放", s)
    t.matches("拦截", s)
    gw.stop()
  end)

  it("net_gateway：不可用时 fail-closed（非 root 或缺少 ip）", function(t)
    local ng = require("NeoAI.sandbox.net_gateway")
    ng.reset()
    with_config({ tools = { sandbox = { network = { gateway = { enabled = true } } } } }, function()
      local ok, err = ng.available()
      if ok then
        -- 环境具备条件：确保创建/清理可用
        local info, gerr = ng.ensure()
        t.not_nil(info, "应能创建 netns 网关: " .. tostring(gerr))
        if info then
          t.true_(ng.exec_prefix()[1] == "ip", "应有 ip netns exec 前缀")
          local env = ng.env()
          t.matches("http://", tostring(env.http_proxy), "应注入代理环境")
          ng.teardown()
        end
      else
        t.matches("GATEWAY_", tostring(err), "不可用时应返回明确原因")
      end
    end)
  end)

  it("宿主过滤代理：本机判定与 HTTP CONNECT 拦截/放行", function(t)
    local hp = require("NeoAI.sandbox.host_proxy")
    hp.reset()
    t.true_(hp._is_host_local("127.0.0.1"), "回环应为本机")
    t.true_(hp._is_host_local("localhost"), "localhost 应为本机")
    t.true_(hp._is_host_local("169.254.169.254"), "云元数据应为本机")
    t.false_(hp._is_host_local("8.8.8.8"), "外部地址不应为本机")
    -- 非规范字面量：旧实现按字符串比较会漏判，getaddrinfo 规范化后应命中本机
    t.true_(hp._is_host_local("::ffff:127.0.0.1"), "IPv4-mapped 回环应为本机")
    t.true_(hp._is_host_local("::ffff:169.254.169.254"), "mapped 云元数据应为本机")
    t.true_(hp._is_host_local("0:0:0:0:0:0:0:1"), "全展开 ::1 应为本机")
    t.true_(hp._is_host_local("0177.0.0.1"), "八进制回环应为本机")
    t.true_(hp._is_host_local("fea0::1"), "fe80::/10 范围内应为本机")

    local echo_port, close_srv = echo_server()
    -- 把 127.0.0.1 视为外部（覆盖判定），验证转发路径
    local addr = hp.start("127.0.0.1", 0, { host_local_fn = function() return false end })
    t.not_nil(addr, "代理应能启动")
    local cli = vim.uv.new_tcp()
    local got, done, phase = {}, false, "header"
    cli:connect(addr.host, addr.port, function(err)
      if err then done = true; return end
      cli:write(("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(echo_port))
      cli:read_start(function(rerr, data)
        if rerr or not data then done = true; return end
        if #data > 0 then got[#got + 1] = data end
        local all = table.concat(got)
        if phase == "header" and all:find("\r\n\r\n", 1, true) then
          phase = "body"
          cli:write("ping")
        elseif phase == "body" and all:find("ping", 1, true) then
          done = true
        end
      end)
    end)
    vim.wait(3000, function() return done end)
    local out = table.concat(got)
    t.matches("200 Connection Established", out, "应建立隧道")
    t.true_(out:find("ping", 1, true) ~= nil, "隧道应回显数据")
    pcall(function() cli:close() end)
    close_srv()
    hp.stop()

    -- 默认判定：本机目标被拦截
    local addr2 = hp.start("127.0.0.1", 0)
    local resp = tcp_exchange(addr2.host, addr2.port,
      ("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n"):format(echo_port))
    t.matches("403", resp, "本机目标应 403")
    t.matches("host_local_blocked", resp, "应标明本机拦截原因")
    hp.stop()
    hp.reset()
  end)

  it("宿主过滤代理：DNS 解析异步执行（不阻塞主线程）", function(t)
    local hp = require("NeoAI.sandbox.host_proxy")
    hp.reset()
    -- 同步 `vim.uv.getaddrinfo`（无回调）会阻塞主线程；请求路径必须走异步解析：
    -- 调用立即返回、回调在事件循环中稍后触发。
    local called = false
    hp._classify_async("example.invalid", function() called = true end)
    t.false_(called, "回调不应在调用栈内同步触发（否则解析会阻塞主线程）")
    t.true_(vim.wait(5000, function() return called end, 10), "异步回调应触发")
    hp.reset()
  end)

  it("宿主过滤代理：SOCKS5 本机拦截与放行", function(t)
    local hp = require("NeoAI.sandbox.host_proxy")
    hp.reset()
    local echo_port, close_srv = echo_server()
    local addr = hp.start("127.0.0.1", 0, { host_local_fn = function() return false end })
    -- 目标 127.0.0.1（判定覆盖为外部）
    local ip = { 127, 0, 0, 1 }
    local req = string.char(5, 1, 0) -- greeting
      .. string.char(5, 1, 0, 1, ip[1], ip[2], ip[3], ip[4],
        math.floor(echo_port / 256), echo_port % 256)
    -- 客户端把 greeting+request 合并发送，服务端会回「方法选择(2B) + 请求应答(10B)」
    local resp = tcp_exchange(addr.host, addr.port, req, 1500)
    t.true_(#resp >= 12, "应收到 SOCKS5 应答，实际: " .. vim.inspect(resp))
    t.eq(0, resp:byte(2), "方法选择应为 no-auth")
    t.eq(0, resp:byte(4), "放行应返回 0x00")
    hp.stop()

    -- 默认判定：本机目标返回 0x02（ruleset 拒绝）
    local addr2 = hp.start("127.0.0.1", 0)
    local resp2 = tcp_exchange(addr2.host, addr2.port, req, 1500)
    t.true_(#resp2 >= 12, "应收到 SOCKS5 应答")
    t.eq(2, resp2:byte(4), "本机目标应返回 0x02")
    hp.stop()
    close_srv()
    hp.reset()
  end)

  it("宿主过滤代理：启用时注入代理环境且不被 strip 清除", function(t)
    local runtime = require("NeoAI.sandbox.runtime")
    local hp = require("NeoAI.sandbox.host_proxy")
    hp.reset()
    with_config({ tools = { sandbox = { network = { host_local_block = true }, offline = false } } }, function()
      local env = runtime.sandbox_env(nil)
      t.matches("127%.0%.0%.1", tostring(env.HTTP_PROXY), "应注入 HTTP_PROXY")
      t.matches("socks5h://", tostring(env.ALL_PROXY), "应注入 SOCKS5 ALL_PROXY")
      t.eq("", env.NO_PROXY, "NO_PROXY 应为空使本机也走代理")
      -- 代理变量不被清除（走注入的宿主代理），但 SSH agent 变量始终清除。
      local snip = runtime.proxy_unset_snippet()
      t.not_nil(snip, "应始终生成 SSH agent 变量清除片段")
      t.matches("SSH_AUTH_SOCK", snip, "应清除 SSH_AUTH_SOCK")
      t.true_(snip:find("HTTP_PROXY", 1, true) == nil, "启用拦截时不应清除代理变量")
    end)
    with_config({ tools = { sandbox = { network = { host_local_block = false } } } }, function()
      local env = runtime.sandbox_env(nil)
      t.eq(nil, env.HTTP_PROXY, "关闭拦截时不注入代理")
      t.not_nil(runtime.proxy_unset_snippet(), "关闭拦截时应恢复 strip 清除")
    end)
    hp.stop()
    hp.reset()
  end)

  it("端到端：隔离 netns 内经网关探测宿主开放端口并返回拦截原因", function(t)
    local ng = require("NeoAI.sandbox.net_gateway")
    local runtime = require("NeoAI.sandbox.runtime")
    local ok_env = ng.available()
    if not ok_env or runtime.backend() ~= "bwrap" or vim.fn.executable("curl") ~= 1 then return end
    -- 清理前序用例可能遗留的网关/netns 状态，保证端到端隔离。
    ng.reset()
    require("NeoAI.sandbox.gateway").reset()
    local srv = vim.uv.new_tcp()
    srv:bind("127.0.0.1", 0)
    srv:listen(16, function() end)
    local port = srv:getsockname().port
    local sandbox = require("NeoAI.sandbox")
    with_config({ tools = {
      approval = { mode = "auto_allow" },
      sandbox = { mode = "dry_run", review = { enabled = true }, network = { gateway = { enabled = true } } },
    } }, function()
      sandbox.reset()
      local done = false
      require("NeoAI.tools").execute("run_command", {
        command = ("curl -s -w '\\nHTTP_CODE:%%{http_code}' http://127.0.0.1:%d/"):format(port),
        description = "t",
      }, {}):then_(function(r)
        local s = tostring(r)
        t.matches("HTTP_CODE:403", s, "开放端口应返回 403（服务被拦截）")
        t.matches('"open":true', s, "响应应标明端口开放")
        t.matches("blocked", s, "应包含拦截原因")
        done = true
      end, function(e)
        t.true_(false, "网关命令失败: " .. tostring(e and e.message or e))
        done = true
      end)
      t.true_(vim.wait(30000, function() return done end), "应完成")
    end)
    srv:close()
    ng.teardown()
  end)
end)
