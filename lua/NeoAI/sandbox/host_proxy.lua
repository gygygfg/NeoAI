--- 宿主侧请求过滤代理（HTTP CONNECT + 绝对形式 + SOCKS5）
--- @module NeoAI.sandbox.host_proxy
---
--- 共享网络命名空间下为沙箱外部命令提供应用层代理：
---   * 拦截向宿主本机（回环 127/8、::1、宿主各网卡 IP、链路本地 169.254/16 与 fe80::/10、
---     云元数据 169.254.169.254）的访问；
---   * 放行其余外部目标并逐条记录。
---
--- 边界（见 docs/sandbox.md）：这是**应用层**过滤。不认代理的裸 TCP（nc/ssh/数据库客户端等）
--- 不经代理即可直连，不受拦截——共享 netns 下无法在内核层按目的地过滤（那需要 iptables/nft
--- 或无 root 的 slirp4netns/passt）。本模块只覆盖走 HTTP(S)_PROXY / ALL_PROXY 的工具。
---
--- 仅使用 Neovim 内置 luv（无第三方依赖）。

local M = {}

-- ========== 私有状态 ==========

local state = {
  server = nil,
  host = nil,
  port = nil,
  records = {},
  host_addrs = nil, -- 宿主本机地址集合（懒加载）
  opts = {},
}

local MAX_RECORDS = 4096

--- 内置软件源域名后缀（包管理器索引/镜像）。这些是**外部**包源，非本机 SSRF 目标，免弹窗
--- 放行不削弱本机防护；解析到本机或解析失败仍按本机拒绝（见 `_gate` 的 `not local_` 前置条件）。
local PACKAGE_SOURCE_SUFFIXES = {
  -- Python / PyPI
  "pypi.org", "pythonhosted.org", "pypi.python.org",
  -- npm / Node
  "registry.npmjs.org", "registry.yarnpkg.com", "npmmirror.com", "npm.taobao.org",
  -- Go
  "proxy.golang.org", "sum.golang.org", "goproxy.cn", "goproxy.io",
  -- Rust / Cargo
  "crates.io", "static.crates.io", "index.crates.io", "static.rust-lang.org",
  -- Maven / Java
  "repo.maven.apache.org", "repo1.maven.org", "maven.aliyun.com",
  -- 系统包源（Debian/Ubuntu/Alpine/Docker/nodesource）
  "deb.debian.org", "security.debian.org", "archive.ubuntu.com", "security.ubuntu.com",
  "ports.ubuntu.com", "mirrors.ubuntu.com", "dl-cdn.alpinelinux.org",
  "download.docker.com", "deb.nodesource.com",
  -- 国内公共镜像（覆盖其下全部子域/路径）
  "tuna.tsinghua.edu.cn", "mirrors.aliyun.com", "mirrors.ustc.edu.cn",
  "mirror.sjtu.edu.cn", "mirrors.zju.edu.cn", "mirrors.huaweicloud.com",
  "mirrors.cloud.tencent.com", "mirrors.bfsu.edu.cn",
  -- Conda / Ruby / PHP
  "repo.anaconda.com", "conda.anaconda.org", "rubygems.org", "repo.packagist.org",
}

-- ========== 地址判定 ==========

local function _strip_zone(ip)
  return (tostring(ip):gsub("%%.*$", ""))
end

--- 将 IPv4-mapped IPv6（`::ffff:a.b.c.d`）归一为 IPv4，便于按数值判定。
--- 内核把 v4-mapped 地址当 IPv4 处理，若只做字符串比较会漏判本机（`::ffff:127.0.0.1`）。
--- @param ip string
--- @return string
local function _unmap_v4(ip)
  local v4 = ip:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
  return v4 or ip
end

--- 规范化单个 IP 字面量：去 zone、小写、展开 v4-mapped。
--- @param ip string
--- @return string
local function _canon_ip(ip)
  return _unmap_v4(_strip_zone(ip):lower())
end

--- IPv4 字符串 -> 32 位整数；非法返回 nil
--- @param ip string
--- @return number|nil
local function _ipv4_to_num(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

--- IPv6 首个 hextet 数值（用于 fe80::/10 前缀判定）；无则 nil
--- @param ip string
--- @return number|nil
local function _ipv6_first_hextet(ip)
  local first = ip:match("^([0-9a-f]+)")
  if not first then return nil end
  return tonumber(first, 16)
end

--- 宿主各网卡地址集合（回环 + inet/inet6），键为规范化形式
--- @return table ip -> true
local function _host_addrs()
  if state.host_addrs then return state.host_addrs end
  local set = {}
  local ok, lines = pcall(vim.fn.systemlist, { "ip", "-o", "addr", "show" })
  if ok and type(lines) == "table" then
    for _, line in ipairs(lines) do
      local ip = line:match("inet6? ([%da-fA-F:%.]+)/")
      if ip then set[_canon_ip(ip)] = true end
    end
  end
  state.host_addrs = set
  return set
end

--- IP 是否属于宿主本机 / 链路本地 / 元数据（数值判定，含 v4-mapped）
--- @param ip string
--- @return boolean
local function _ip_is_host_local(ip)
  if type(ip) ~= "string" or ip == "" then return false end
  ip = _canon_ip(ip)
  local n = _ipv4_to_num(ip)
  if n then
    if n == 0 then return true end -- 0.0.0.0（connect 即 loopback）
    if math.floor(n / 0x1000000) == 127 then return true end -- 127/8
    if math.floor(n / 0x10000) == 0xA9FE then return true end -- 169.254/16（含云元数据）
  else
    if ip == "::" or ip == "::1" then return true end
    local h = _ipv6_first_hextet(ip)
    if h and h >= 0xfe80 and h <= 0xfebf then return true end -- fe80::/10
  end
  if _host_addrs()[ip] then return true end
  return false
end

--- 回环地址（127/8 或 ::1）——端口白名单只放行回环，不放行宿主网卡 IP/元数据/链路本地。
--- @param ip string
--- @return boolean
local function _is_loopback(ip)
  ip = _canon_ip(ip)
  local n = _ipv4_to_num(ip)
  if n then return math.floor(n / 0x1000000) == 127 end
  return ip == "::1"
end

--- 本机端口白名单（如沙箱内启动的 DB/Redis 自测）：`tools.sandbox.network.allow_localhost_ports`。
--- @return table 端口数组
local function _allow_local_ports()
  if state.opts.allow_localhost_ports ~= nil then return state.opts.allow_localhost_ports end
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.sandbox.network") or {}
  end)
  return (ok and cfg.allow_localhost_ports) or {}
end

--- 端口是否在白名单
--- @param port number|string
--- @return boolean
local function _port_allowed(port)
  local list = _allow_local_ports()
  if type(list) ~= "table" then return false end
  local p = tonumber(port)
  if not p then return false end
  for _, v in ipairs(list) do
    if tonumber(v) == p then return true end
  end
  return false
end

--- 是否放行该本机目标：仅「回环地址 + 白名单端口」。宿主网卡 IP/元数据/链路本地永不放行。
--- @param host string
--- @param port number|string
--- @param ips table|nil 已解析 IP（可空）
--- @return boolean
local function _allow_local(host, port, ips)
  if not _port_allowed(port) then return false end
  local lower = tostring(host or ""):lower():gsub("^%[", ""):gsub("%]$", "")
  if lower == "localhost" or lower:sub(-10) == ".localhost" then return true end
  if type(ips) == "table" and #ips > 0 then
    for _, ip in ipairs(ips) do
      if _is_loopback(ip) then return true end
    end
    return false
  end
  return _is_loopback(lower)
end

--- 网络访问策略：`ask`（默认）| `allow` | `deny`。`state.opts.access` 优先（测试/内部注入）。
--- @return string
local function _access_policy()
  local p = state.opts.access
  if p ~= "allow" and p ~= "deny" and p ~= "ask" then
    local ok, cfg = pcall(function()
      return require("NeoAI.kernel.config_store").get("tools.sandbox.network")
    end)
    p = (ok and type(cfg) == "table" and cfg.access) or "ask"
  end
  if p ~= "allow" and p ~= "deny" then p = "ask" end
  return p
end

--- 软件源自动放行配置：`state.opts` 优先（测试/内部注入），否则读 config。
--- @return boolean enabled
--- @return table|nil extra 额外域名后缀数组
local function _sources_config()
  if state.opts.auto_allow_sources ~= nil or state.opts.package_sources ~= nil then
    return state.opts.auto_allow_sources ~= false, state.opts.package_sources
  end
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools.sandbox.network")
  end)
  cfg = (ok and type(cfg) == "table") and cfg or {}
  return cfg.auto_allow_sources ~= false, cfg.extra_package_sources
end

--- 主机名是否属于已知软件源（内置后缀 + 用户扩展；子域自动匹配）。
--- @param host string
--- @return boolean
local function _is_package_source(host)
  if type(host) ~= "string" or host == "" then return false end
  local enabled, extra = _sources_config()
  if not enabled then return false end
  local h = host:lower():gsub("%.$", "")
  local function matches(pat)
    pat = tostring(pat):lower()
    return pat ~= "" and (h == pat or h:sub(-(#pat + 1)) == "." .. pat)
  end
  for _, pat in ipairs(PACKAGE_SOURCE_SUFFIXES) do
    if matches(pat) then return true end
  end
  if type(extra) == "table" then
    for _, pat in ipairs(extra) do
      if type(pat) == "string" and matches(pat) then return true end
    end
  end
  return false
end

--- 端口是否为已登记的沙箱内部服务端口
--- @param port number
--- @return boolean
local function _internal_port(port)
  local ok, nc = pcall(require, "NeoAI.sandbox.net_consent")
  return ok and nc.is_internal_port(port) or false
end

--- 访问门禁：沙箱内部（回环白名单/内部端口）免权限；其余按策略 ask/allow/deny。
--- 异步（ask 时弹窗），回调 `cb(allow: boolean, reason: string)`。
--- @param local_ boolean
--- @param host string
--- @param port number
--- @param ips table|nil
--- @param proto string
--- @param cb function(allow: boolean, reason: string)
local function _gate(local_, host, port, ips, proto, cb)
  local block_reason = local_ and "host_local_blocked" or "external_blocked"
  if local_ then
    if _allow_local(host, port, ips) or _internal_port(port) then
      return cb(true, "allow_local")
    end
    -- 自动登记沙箱内命令启动的临时监听端口：共享 netns 下无法按地址区分宿主/沙箱，
    -- 故按 cgroup 归属识别 LISTEN socket 持有者。沙箱自己监听的回环端口免权限，
    -- 宿主回环服务仍走 ask/deny（SSRF 防护不削弱），修复对 127.0.0.1 的过度拦截。
    local oknc, nc = pcall(require, "NeoAI.sandbox.net_consent")
    if oknc and nc and type(nc.is_sandbox_listening) == "function" then
      local okv, is_sb = pcall(nc.is_sandbox_listening, port)
      if okv and is_sb then return cb(true, "allow_local") end
      -- 首次判定可能命中短负缓存（服务刚启动、探测发生在监听之前）：强制重新扫描一次
      -- 沙箱域监听端口，避免把沙箱自己的服务误判为宿主回环而弹窗/拒绝（headless 下直接 deny）。
      if type(nc.register_sandbox_listeners) == "function" then
        local okr, ports = pcall(nc.register_sandbox_listeners)
        if okr and type(ports) == "table" then
          for _, p in ipairs(ports) do
            if tonumber(p) == tonumber(port) then return cb(true, "allow_local") end
          end
        end
      end
    end
  end
  local policy = _access_policy()
  -- 软件源自动放行：外部包源（非本机）免弹窗，避免 pip/uv/npm/apt 安装被同意门禁拦截。
  -- 本机目标（含 DNS 解析到本机）不走此分支，SSRF 防护不削弱；access="deny" 时仍拒绝。
  if not local_ and policy ~= "deny" and _is_package_source(host) then
    return cb(true, "allow_source")
  end
  if policy == "allow" then return cb(true, local_ and "allow_local" or "allow") end
  if policy == "deny" then return cb(false, block_reason) end
  local ok, nc = pcall(require, "NeoAI.sandbox.net_consent")
  if not ok then return cb(false, block_reason) end
  if nc.is_session_allowed(host, port) then
    return cb(true, local_ and "allow_local" or "allow")
  end
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(
      require("NeoAI.kernel.events").SANDBOX_NET_CONSENT_REQUESTED,
      { host = host, port = port, local_ = local_, proto = proto })
  end)
  nc.request({ host = host, port = port, local_ = local_, proto = proto }):then_(function(decision)
    if decision == "deny" then return cb(false, block_reason) end
    if decision == "allow_session" then nc.allow_session(host, port) end
    cb(true, local_ and "allow_local" or "allow")
  end, function()
    cb(false, block_reason)
  end)
end

--- 解析主机名为规范化 IP 列表（同步，含 IP 字面量）。
--- 统一经 getaddrinfo：它把八进制/十六进制/短式 IPv4 与全展开 IPv6 全部规范化为标准形式，
--- 避免「字面量字符串比较」与「连接时内核解析」不一致造成的绕过。
--- @param host string
--- @return table ip 字符串数组
local function _resolve(host)
  local out = {}
  local ok, res = pcall(vim.uv.getaddrinfo, host, nil, { socktype = "stream" })
  if ok and type(res) == "table" then
    for _, a in ipairs(res) do
      if a.addr then out[#out + 1] = _strip_zone(a.addr) end
    end
  end
  return out
end

--- 判定目标并返回已解析 IP（**只解析一次**，连接复用同一批 IP，防 DNS rebinding）。
--- 无法解析（含字面量解析失败）时按 fail-closed 视为本机拒绝。
--- @param host string
--- @return boolean is_host_local
--- @return table ips 规范化 IP 数组（本地/解析失败时可能为空）
local function _classify(host)
  if type(host) ~= "string" or host == "" then return true, {} end
  host = host:gsub("^%[", ""):gsub("%]$", "")
  local lower = host:lower()
  if lower == "localhost" or lower:sub(-10) == ".localhost" then return true, {} end
  if state.opts.host_local_fn then return state.opts.host_local_fn(host) == true, {} end
  local ips = _resolve(host)
  if #ips == 0 then return true, {} end -- 解析失败：无法证明非本机，fail-closed
  for _, ip in ipairs(ips) do
    if _ip_is_host_local(ip) then return true, ips end
  end
  return false, ips
end

--- 异步解析（回调式 `vim.uv.getaddrinfo`）：DNS 在 libuv 线程池完成，**不阻塞主线程**。
--- 无回调的 `vim.uv.getaddrinfo` 是同步调用，`uv pip install` 等并发联网命令每条请求都
--- 会阻塞主线程解析 DNS（慢解析时界面冻结），故请求路径统一走本函数。
--- @param host string
--- @param cb function(ips: table)
local function _resolve_async(host, cb)
  local ok, req = pcall(vim.uv.getaddrinfo, host, nil, { socktype = "stream" }, function(err, res)
    local out = {}
    if not err and type(res) == "table" then
      for _, a in ipairs(res) do
        if a.addr then out[#out + 1] = _strip_zone(a.addr) end
      end
    end
    cb(out)
  end)
  if not ok then cb({}) end
end

--- 异步版 `_classify`：回调式返回 `(is_host_local, ips)`，不阻塞主线程。
--- @param host string
--- @param cb function(is_host_local: boolean, ips: table)
local function _classify_async(host, cb)
  if type(host) ~= "string" or host == "" then return cb(true, {}) end
  host = host:gsub("^%[", ""):gsub("%]$", "")
  local lower = host:lower()
  if lower == "localhost" or lower:sub(-10) == ".localhost" then return cb(true, {}) end
  if state.opts.host_local_fn then return cb(state.opts.host_local_fn(host) == true, {}) end
  _resolve_async(host, function(ips)
    if #ips == 0 then return cb(true, {}) end -- 解析失败：fail-closed
    for _, ip in ipairs(ips) do
      if _ip_is_host_local(ip) then return cb(true, ips) end
    end
    cb(false, ips)
  end)
end

--- 目标是否宿主本机
--- @param host string
--- @return boolean
local function _is_host_local(host)
  return (_classify(host))
end


-- ========== 记录 ==========

local function _record(host, port, proto, decision)
  if #state.records >= MAX_RECORDS then table.remove(state.records, 1) end
  state.records[#state.records + 1] = {
    host = host, port = port, proto = proto, decision = decision, at = os.time(),
  }
end

-- ========== 连接与转发 ==========

local function _close(c)
  if c then pcall(function() c:close() end) end
end

--- 向上游建连。连接**已校验过的 IP**（由 `_classify` 单次解析返回），不再重复解析，
--- 避免 DNS rebinding 在校验与连接之间切换答案。
--- @param host string 原始主机名（无 IP 时兜底）
--- @param ips table 已校验的规范化 IP 数组
--- @param port number
--- @param on_ok function(up userdata)
--- @param on_err function()
local function _open_upstream(host, ips, port, on_ok, on_err)
  local up = vim.uv.new_tcp()
  local done = false
  local target = (#ips > 0) and ips[1] or host
  local ok = pcall(function()
    up:connect(target, port, function(err)
      if done then return end
      done = true
      if err then _close(up); on_err() else on_ok(up) end
    end)
  end)
  if not ok then
    done = true
    _close(up)
    on_err()
  end
end

--- 建立双向转发：客户端读回调由调用方主循环处理（ctx.piping），此处只挂上游→客户端方向。
--- @param ctx table
--- @param client userdata
local function _read_upstream(ctx, client)
  ctx.up:read_start(function(err, data)
    if err or not data then
      _close(ctx.up); _close(client)
      return
    end
    pcall(function() client:write(data) end)
  end)
end

local function _start_piping(ctx, client, up, flush_to_up)
  ctx.piping = true
  ctx.up = up
  -- 建连期间可能又有客户端数据到达（累积在 ctx.buf），一并冲入上游，避免丢失。
  local extra = flush_to_up or ""
  if #ctx.buf > 0 then extra = extra .. ctx.buf; ctx.buf = "" end
  if #extra > 0 then
    pcall(function() up:write(extra) end)
  end
  _read_upstream(ctx, client)
end

-- ========== HTTP 响应 ==========

local function _respond(client, code, status, reason)
  local body = ('{"neoai_host_proxy":"blocked","reason":"%s"}'):format(tostring(reason))
  local resp = table.concat({
    ("HTTP/1.1 %d %s"):format(code, status),
    "Content-Type: application/json",
    "Connection: close",
    ("Content-Length: %d"):format(#body),
    "", body,
  }, "\r\n")
  pcall(function()
    client:write(resp, function() _close(client) end)
  end)
end

-- ========== HTTP 处理 ==========

--- @param ctx table
--- @param client userdata
--- @param header string 请求头（不含结尾 CRLFCRLF）
--- @param rest string 头之后的余量
local function _handle_http(ctx, client, header, rest)
  local first = header:match("^([^\r\n]+)")
  local method, target
  if first then method, target = first:match("^(%u+)%s+(%S+)") end
  if not method or not target then
    _respond(client, 400, "Bad Request", "malformed_request")
    return
  end

  if method == "CONNECT" then
    local h, p = target:match("^([^:]+):(%d+)$")
    if not h then h, p = target:match("^%[([^%]]+)%]:(%d+)$") end
    if not h or not p then
      _respond(client, 400, "Bad Request", "bad_connect_target")
      return
    end
    p = tonumber(p)
    ctx.state = "resolving"
    _classify_async(h, function(local_, ips)
      _gate(local_, h, p, ips, "http", function(allow, reason)
        if not allow then
          _record(h, p, "http", "block")
          _respond(client, 403, "Forbidden", reason)
          return
        end
        ctx.state = "connecting"
        _open_upstream(h, ips, p, function(up)
          _record(h, p, "http", reason)
          pcall(function() client:write("HTTP/1.1 200 Connection Established\r\n\r\n") end)
          _start_piping(ctx, client, up, rest)
        end, function()
          _record(h, p, "http", "error")
          _respond(client, 502, "Bad Gateway", "upstream_connect_failed")
        end)
      end)
    end)
    return
  end

  -- 绝对形式：GET http://host[:port]/path HTTP/1.1
  local h, p = target:match("^https?://([^:/]+):(%d+)")
  if not h then h = target:match("^https?://([^:/]+)") end
  p = p and tonumber(p) or 80
  if not h then
    _respond(client, 400, "Bad Request", "not_a_proxy_request")
    return
  end
  -- 请求行改写为 origin-form，便于普通源站处理
  local path = target:match("^https?://[^/]+(.*)$") or "/"
  if path == "" then path = "/" end
  local rewritten = header:gsub("^([^\r\n]+)", method .. " " .. path .. " HTTP/1.1", 1)
  ctx.state = "resolving"
  _classify_async(h, function(local_, ips)
    _gate(local_, h, p, ips, "http", function(allow, reason)
      if not allow then
        _record(h, p, "http", "block")
        _respond(client, 403, "Forbidden", reason)
        return
      end
      ctx.state = "connecting"
      _open_upstream(h, ips, p, function(up)
        _record(h, p, "http", reason)
        pcall(function() up:write(rewritten .. "\r\n\r\n") end)
        _start_piping(ctx, client, up, rest)
      end, function()
        _record(h, p, "http", "error")
        _respond(client, 502, "Bad Gateway", "upstream_connect_failed")
      end)
    end)
  end)
end

-- ========== SOCKS5 处理 ==========

local function _socks_reply(client, code)
  pcall(function() client:write(string.char(5, code, 0, 1, 0, 0, 0, 0, 0, 0)) end)
end

--- 消费 ctx.buf 推进 SOCKS5 状态机
--- @param ctx table
--- @param client userdata
local function _process_socks(ctx, client)
  local buf = ctx.buf
  local stage = ctx.socks.stage

  if stage == "greeting" then
    if #buf < 2 then return end
    local n = buf:byte(2)
    if #buf < 2 + n then return end
    local methods = buf:sub(3, 2 + n)
    ctx.buf = buf:sub(3 + n)
    if methods:find("\0", 1, true) then
      pcall(function() client:write(string.char(5, 0)) end)
      ctx.socks.stage = "request"
    else
      pcall(function() client:write(string.char(5, 255)) end)
      _close(client)
      return
    end
    buf = ctx.buf
    stage = "request"
  end

  if stage == "request" then
    if #buf < 4 then return end
    local ver, cmd, atyp = buf:byte(1), buf:byte(2), buf:byte(4)
    if ver ~= 5 or cmd ~= 1 then
      _socks_reply(client, 7) -- command not supported
      _close(client)
      return
    end
    local host, port, consumed
    if atyp == 1 then
      if #buf < 10 then return end
      host = ("%d.%d.%d.%d"):format(buf:byte(5), buf:byte(6), buf:byte(7), buf:byte(8))
      port = buf:byte(9) * 256 + buf:byte(10)
      consumed = 10
    elseif atyp == 3 then
      if #buf < 5 then return end
      local len = buf:byte(5)
      if #buf < 5 + len + 2 then return end
      host = buf:sub(6, 5 + len)
      port = buf:byte(6 + len) * 256 + buf:byte(7 + len)
      consumed = 5 + len + 2
    elseif atyp == 4 then
      if #buf < 22 then return end
      local parts = {}
      for i = 0, 7 do
        parts[#parts + 1] = ("%x"):format(buf:byte(5 + i * 2) * 256 + buf:byte(6 + i * 2))
      end
      host = table.concat(parts, ":")
      port = buf:byte(21) * 256 + buf:byte(22)
      consumed = 22
    else
      _socks_reply(client, 8) -- address type not supported
      _close(client)
      return
    end
    ctx.buf = buf:sub(consumed + 1)
    local rest = ctx.buf
    ctx.buf = ""

    ctx.state = "resolving"
    _classify_async(host, function(local_, ips)
      _gate(local_, host, port, ips, "socks5", function(allow, reason)
        if not allow then
          _record(host, port, "socks5", "block")
          _socks_reply(client, 2) -- connection not allowed by ruleset
          _close(client)
          return
        end
        ctx.state = "connecting"
        _open_upstream(host, ips, port, function(up)
          _record(host, port, "socks5", reason)
          _socks_reply(client, 0)
          _start_piping(ctx, client, up, rest)
        end, function()
          _record(host, port, "socks5", "error")
          _socks_reply(client, 5) -- connection refused
          _close(client)
        end)
      end)
    end)
  end
end

-- ========== 连接主循环 ==========

--- @param ctx table
--- @param client userdata
local function _process(ctx, client)
  -- resolving（异步 DNS）或 connecting（建连）期间只累积数据，由回调冲入上游/继续状态机。
  if ctx.state then return end
  if ctx.proto == nil then
    if #ctx.buf < 1 then return end
    ctx.proto = (ctx.buf:byte(1) == 0x05) and "socks" or "http"
  end
  if ctx.proto == "http" then
    local idx = ctx.buf:find("\r\n\r\n", 1, true)
    if not idx then return end
    local header = ctx.buf:sub(1, idx - 1)
    local rest = ctx.buf:sub(idx + 4)
    ctx.buf = ""
    _handle_http(ctx, client, header, rest)
  else
    _process_socks(ctx, client)
  end
end

local function _accept(client)
  local ctx = { buf = "", proto = nil, socks = { stage = "greeting" }, piping = false }
  client:read_start(function(err, data)
    if err or not data then
      if ctx.up then _close(ctx.up) end
      _close(client)
      return
    end
    if ctx.piping then
      pcall(function() ctx.up:write(data) end)
      return
    end
    ctx.buf = ctx.buf .. data
    local ok, e = pcall(_process, ctx, client)
    if not ok then
      pcall(function() require("NeoAI.kernel.logger").warn("host_proxy: " .. tostring(e)) end)
      _close(client)
    end
  end)
end

-- ========== 公开 API ==========

--- 启动代理（port=0 取随机端口）
--- @param host string|nil 默认 127.0.0.1
--- @param port number|nil
--- @param opts table|nil { host_local_fn? }
--- @return table|nil { host, port }
--- @return string|nil err
function M.start(host, port, opts)
  M.stop()
  state.opts = opts or {}
  local server = vim.uv.new_tcp()
  local ok, err = pcall(function() server:bind(host or "127.0.0.1", port or 0) end)
  if not ok then
    _close(server)
    return nil, tostring(err)
  end
  local ok_listen = pcall(function()
    server:listen(128, function(lerr)
      if lerr then return end
      local client = vim.uv.new_tcp()
      local ok_acc = pcall(function() server:accept(client) end)
      if ok_acc then _accept(client) else _close(client) end
    end)
  end)
  if not ok_listen then
    _close(server)
    return nil, "listen_failed"
  end
  local name = server:getsockname()
  state.server = server
  state.host = name and name.ip or (host or "127.0.0.1")
  state.port = name and name.port or port
  return { host = state.host, port = state.port }
end

--- 幂等启动（按配置 host_local_block）。未启用返回 nil。
--- @return table|nil { host, port }
function M.ensure()
  if state.server then return { host = state.host, port = state.port } end
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.network") or {}
  if cfg.host_local_block == false then return nil end
  local port = tonumber(cfg.host_local_proxy_port) or 0
  local addr, err = M.start("127.0.0.1", port)
  if not addr then
    pcall(function() require("NeoAI.kernel.logger").warn("host_proxy 启动失败: " .. tostring(err)) end)
    return nil
  end
  return addr
end

--- 停止代理
function M.stop()
  if state.server then
    _close(state.server)
    state.server = nil
  end
  state.host, state.port = nil, nil
end

--- 当前地址（未启动返回 nil）
--- @return table|nil { host, port }
function M.address()
  if not state.server then return nil end
  return { host = state.host, port = state.port }
end

--- 取出并清空记录
--- @return table
function M.drain_records()
  local out = state.records
  state.records = {}
  return out
end

--- 记录摘要（人类可读）。仅回传真正需要关注的事件（**拦截** / 上游连接失败）：软件源自动放行
--- （`allow_source`）、本机白名单/内部端口（`allow_local`）与用户已同意/策略放行（`allow`）不再
--- 回传，避免 `pip`/`uv`/`npm` 等大量正常连接把「…[http]放行」刷进命令结果。
--- @return string|nil
function M.summary()
  local recs = M.drain_records()
  if #recs == 0 then return nil end
  local parts = {}
  for _, r in ipairs(recs) do
    if r.decision == "block" then
      parts[#parts + 1] = ("%s:%d[%s]已拦截"):format(r.host, r.port, r.proto)
    elseif r.decision == "error" then
      parts[#parts + 1] = ("%s:%d[%s]连接失败"):format(r.host, r.port, r.proto)
    end
  end
  if #parts == 0 then return nil end
  return "[NeoAI] 网络访问过滤：" .. table.concat(parts, "，")
    .. "（本机地址经代理拦截；裸 TCP 不经代理不受此层约束）"
end

--- 测试/内部：宿主本机判定
function M._is_host_local(host)
  return _is_host_local(host)
end

--- 测试/内部：异步本机判定（不阻塞主线程）
function M._classify_async(host, cb)
  return _classify_async(host, cb)
end

--- 测试/内部：软件源判定
function M._is_package_source(host)
  return _is_package_source(host)
end

--- 测试/内部：写入一条访问记录（仅用于验证摘要过滤）
function M._record_for_test(host, port, proto, decision)
  _record(host, port, proto, decision)
end

--- 测试/内部：访问门禁（异步回调 allow/reason）
function M._gate(local_, host, port, ips, proto, cb)
  return _gate(local_, host, port, ips, proto, cb)
end

--- 重置（测试用）
function M.reset()
  M.stop()
  state.records = {}
  state.host_addrs = nil
  state.opts = {}
end

return M
