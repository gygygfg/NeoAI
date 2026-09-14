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

-- ========== 地址判定 ==========

local function _strip_zone(ip)
  return (tostring(ip):gsub("%%.*$", ""))
end

--- 宿主各网卡地址集合（回环 + inet/inet6）
--- @return table ip -> true
local function _host_addrs()
  if state.host_addrs then return state.host_addrs end
  local set = {}
  local ok, lines = pcall(vim.fn.systemlist, { "ip", "-o", "addr", "show" })
  if ok and type(lines) == "table" then
    for _, line in ipairs(lines) do
      local ip = line:match("inet6? ([%da-fA-F:%.]+)/")
      if ip then set[_strip_zone(ip)] = true end
    end
  end
  state.host_addrs = set
  return set
end

--- IP 是否属于宿主本机 / 链路本地 / 元数据
--- @param ip string
--- @return boolean
local function _ip_is_host_local(ip)
  if type(ip) ~= "string" or ip == "" then return false end
  ip = _strip_zone(ip)
  local lower = ip:lower()
  if ip == "0.0.0.0" or lower == "::" then return true end
  if ip:sub(1, 4) == "127." then return true end
  if lower == "::1" then return true end
  if ip:sub(1, 8) == "169.254." then return true end
  if lower:sub(1, 5) == "fe80:" then return true end
  if _host_addrs()[ip] then return true end
  return false
end

--- @param host string
--- @return boolean
local function _is_ip_literal(host)
  if host:match("^%d+%.%d+%.%d+%.%d+$") then return true end
  if host:find(":", 1, true) then return true end
  return false
end

--- 解析主机名（同步）。IP 字面量直接返回自身。
--- @param host string
--- @return table ip 字符串数组
local function _resolve(host)
  local out = {}
  if _is_ip_literal(host) then out[1] = host; return out end
  local ok, res = pcall(vim.uv.getaddrinfo, host, nil, { socktype = "stream" })
  if ok and type(res) == "table" then
    for _, a in ipairs(res) do
      if a.addr then out[#out + 1] = _strip_zone(a.addr) end
    end
  end
  return out
end

--- 目标是否宿主本机（域名会先解析，防 DNS rebinding 到本机）
--- @param host string
--- @return boolean
local function _is_host_local(host)
  if type(host) ~= "string" or host == "" then return false end
  host = host:gsub("^%[", ""):gsub("%]$", "")
  local lower = host:lower()
  if lower == "localhost" or lower:sub(-10) == ".localhost" then return true end
  if state.opts.host_local_fn then return state.opts.host_local_fn(host) == true end
  if _is_ip_literal(host) then return _ip_is_host_local(host) end
  for _, ip in ipairs(_resolve(host)) do
    if _ip_is_host_local(ip) then return true end
  end
  return false
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

--- 向上游建连（域名先解析）
--- @param host string
--- @param port number
--- @param on_ok function(up userdata)
--- @param on_err function()
local function _open_upstream(host, port, on_ok, on_err)
  local up = vim.uv.new_tcp()
  local done = false
  local ips = _resolve(host)
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
    if _is_host_local(h) then
      _record(h, p, "http", "block")
      _respond(client, 403, "Forbidden", "host_local_blocked")
      return
    end
    ctx.state = "connecting"
    _open_upstream(h, p, function(up)
      _record(h, p, "http", "allow")
      pcall(function() client:write("HTTP/1.1 200 Connection Established\r\n\r\n") end)
      _start_piping(ctx, client, up, rest)
    end, function()
      _record(h, p, "http", "error")
      _respond(client, 502, "Bad Gateway", "upstream_connect_failed")
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
  if _is_host_local(h) then
    _record(h, p, "http", "block")
    _respond(client, 403, "Forbidden", "host_local_blocked")
    return
  end
  -- 请求行改写为 origin-form，便于普通源站处理
  local path = target:match("^https?://[^/]+(.*)$") or "/"
  if path == "" then path = "/" end
  local rewritten = header:gsub("^([^\r\n]+)", method .. " " .. path .. " HTTP/1.1", 1)
  ctx.state = "connecting"
  _open_upstream(h, p, function(up)
    _record(h, p, "http", "allow")
    pcall(function() up:write(rewritten .. "\r\n\r\n") end)
    _start_piping(ctx, client, up, rest)
  end, function()
    _record(h, p, "http", "error")
    _respond(client, 502, "Bad Gateway", "upstream_connect_failed")
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

    if _is_host_local(host) then
      _record(host, port, "socks5", "block")
      _socks_reply(client, 2) -- connection not allowed by ruleset
      _close(client)
      return
    end
    ctx.state = "connecting"
    _open_upstream(host, port, function(up)
      _record(host, port, "socks5", "allow")
      _socks_reply(client, 0)
      _start_piping(ctx, client, up, rest)
    end, function()
      _record(host, port, "socks5", "error")
      _socks_reply(client, 5) -- connection refused
      _close(client)
    end)
  end
end

-- ========== 连接主循环 ==========

--- @param ctx table
--- @param client userdata
local function _process(ctx, client)
  if ctx.state == "connecting" then return end -- 建连期间只累积，由 _start_piping 冲入上游
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

--- 记录摘要（人类可读）
--- @return string|nil
function M.summary()
  local recs = M.drain_records()
  if #recs == 0 then return nil end
  local parts = {}
  for _, r in ipairs(recs) do
    parts[#parts + 1] = ("%s:%d[%s]%s"):format(
      r.host, r.port, r.proto, r.decision == "block" and "已拦截" or "放行")
  end
  return "[NeoAI] 网络访问过滤：" .. table.concat(parts, "，")
    .. "（本机地址经代理拦截；裸 TCP 不经代理不受此层约束）"
end

--- 测试/内部：宿主本机判定
function M._is_host_local(host)
  return _is_host_local(host)
end

--- 重置（测试用）
function M.reset()
  M.stop()
  state.records = {}
  state.host_addrs = nil
  state.opts = {}
end

return M
