--- 沙箱网络网关（宿主侧，纯 Lua）
--- @module NeoAI.sandbox.gateway
--- 在独立网络命名空间（netns）内，沙箱进程只能到达本网关；网关对每个目标 `host:port`
--- 先做 TCP connect 探针判定「开放/关闭」，随后**不回传真实服务数据**，而是把结构化原因
--- （JSON）返回给客户端。用途：允许 AI 探测宿主有哪些端口在监听，但禁止实际使用这些服务。
---
--- 实现 HTTP 代理（`CONNECT host:port` 与绝对形式 `GET http://host:port/...`），
--- 因此 curl/wget/git/nmap --proxies 等「走代理的工具」可经网关探测并拿到原因；
--- 直接裸 TCP（不经代理）在隔离 netns 内无法到达宿主，故不生效。
---
--- 仅允许探测宿主本机地址（回环 + 宿主网卡地址）；外部地址一律拒绝并返回原因。

local M = {}

-- ========== 私有状态 ==========

local state = {
  server = nil,
  host = nil,
  port = nil,
  probes = {},      -- { host, port, open, reason, at }
  host_addrs = nil, -- 宿主本机地址集合（懒加载）
}

-- ========== 私有函数 ==========

--- 读取宿主本机地址集合（回环 + 各网卡 inet）
--- @return table ip -> true
local function _host_addrs()
  if state.host_addrs then return state.host_addrs end
  local set = { ["127.0.0.1"] = true, ["::1"] = true, ["0.0.0.0"] = true, ["localhost"] = true }
  local ok, lines = pcall(vim.fn.systemlist, { "ip", "-o", "addr", "show" })
  if ok and type(lines) == "table" then
    for _, line in ipairs(lines) do
      local ip = line:match("inet6? ([%da-fA-F:%.]+)/")
      if ip then set[ip] = true end
    end
  end
  state.host_addrs = set
  return set
end

--- 目标是否宿主本机地址
--- @param host string
--- @return boolean
local function _is_host_local(host)
  if type(host) ~= "string" or host == "" then return false end
  host = host:gsub("^%[", ""):gsub("%]$", "")
  return _host_addrs()[host] == true
end

--- 记录一次探测
--- @param host string
--- @param port number
--- @param open boolean
--- @param reason string
local function _record(host, port, open, reason)
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.network.gateway") or {}
  local max = tonumber(cfg.max_probes) or 4096
  if #state.probes >= max then table.remove(state.probes, 1) end
  state.probes[#state.probes + 1] = { host = host, port = port, open = open, reason = reason, at = os.time() }
end

--- TCP connect 探针：判定目标端口是否可连接（开放），不发送任何应用数据。
--- @param host string
--- @param port number
--- @param cb function(open: boolean, reason: string)
local function _probe(host, port, cb)
  local timeout_ms = (require("NeoAI.kernel.config_store").get("tools.sandbox.network.gateway") or {}).probe_timeout_ms
  timeout_ms = tonumber(timeout_ms) or 1000
  local tcp = vim.uv.new_tcp()
  local timer = vim.uv.new_timer()
  local done = false
  local function finish(open, reason)
    if done then return end
    done = true
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
    pcall(function() tcp:close() end)
    cb(open, reason)
  end
  timer:start(timeout_ms, 0, function() finish(false, "probe_timeout") end)
  local ok = pcall(function()
    tcp:connect(host, port, function(err)
      finish(err == nil, err and tostring(err) or "connected")
    end)
  end)
  if not ok then finish(false, "probe_error") end
end

--- JSON 响应体
--- @param target string
--- @param open boolean
--- @param reason string
--- @return string
local function _body(target, open, reason)
  local json = require("NeoAI.utils.json")
  return json.encode({
    neoai_gateway = "blocked",
    target = target,
    open = open,
    service_allowed = false,
    reason = reason,
  })
end

--- 写 HTTP 响应并关闭
--- @param client userdata
--- @param code number
--- @param status string
--- @param body string
local function _respond(client, code, status, body)
  local resp = table.concat({
    ("HTTP/1.1 %d %s"):format(code, status),
    "Content-Type: application/json",
    "Connection: close",
    ("Content-Length: %d"):format(#body),
    "", body,
  }, "\r\n")
  pcall(function() client:write(resp) end)
  pcall(function() client:close() end)
end

--- 解析代理请求首行，得到目标 host/port
--- @param line string
--- @return string|nil host
--- @return number|nil port
local function _parse_target(line)
  if type(line) ~= "string" then return nil end
  local method, target = line:match("^(%u+)%s+(%S+)")
  if not method or not target then return nil end
  if method == "CONNECT" then
    local h, p = target:match("^([^:]+):(%d+)$")
    if not h then h, p = target:match("^%[([^%]]+)%]:(%d+)$") end
    return h, tonumber(p)
  end
  -- 绝对形式：http://host:port/path
  local h, p = target:match("^https?://([^:/]+):(%d+)")
  if not h then h = target:match("^https?://([^:/]+)") end
  return h, p and tonumber(p) or 80
end

--- 处理一个代理连接：读取请求头 → 探针 → 返回原因
--- @param client userdata
local function _handle(client)
  local buf = ""
  client:read_start(function(err, data)
    if err or not data then
      pcall(function() client:close() end)
      return
    end
    buf = buf .. data
    local header = buf:match("^(.-)\r\n\r\n")
    if not header then return end -- 等待完整请求头
    local first = header:match("^([^\r\n]+)")
    local host, port = _parse_target(first)
    if not host or not port then
      _respond(client, 400, "Bad Request", _body("?", false, "malformed_proxy_request"))
      return
    end
    if not _is_host_local(host) then
      _record(host, port, false, "not_host_local")
      _respond(client, 403, "Forbidden", _body(host .. ":" .. port, false, "only_host_local_addresses_allowed"))
      return
    end
    local h = (host == "0.0.0.0") and "127.0.0.1" or host
    _probe(h, port, function(open, reason)
      if open then
        _record(host, port, true, "service_blocked")
        _respond(client, 403, "Forbidden",
          _body(host .. ":" .. port, true,
            "port_open_but_service_access_blocked_by_neoai_sandbox_gateway"))
      else
        _record(host, port, false, reason)
        _respond(client, 502, "Bad Gateway",
          _body(host .. ":" .. port, false, "port_not_open:" .. tostring(reason)))
      end
    end)
  end)
end

-- ========== 公开 API ==========

--- 启动网关，绑定 host:port（port=0 取随机端口）
--- @param host string
--- @param port number|nil
--- @return table|nil { host, port }
--- @return string|nil err
function M.start(host, port)
  M.stop()
  local server = vim.uv.new_tcp()
  local ok, err = pcall(function() server:bind(host, port or 0) end)
  if not ok then
    pcall(function() server:close() end)
    return nil, tostring(err)
  end
  local ok_listen = pcall(function()
    server:listen(128, function(lerr)
      if lerr then return end
      local client = vim.uv.new_tcp()
      local ok_acc = pcall(function() server:accept(client) end)
      if ok_acc then _handle(client) else pcall(function() client:close() end) end
    end)
  end)
  if not ok_listen then
    pcall(function() server:close() end)
    return nil, "listen_failed"
  end
  local name = server:getsockname()
  state.server = server
  state.host = name and name.ip or host
  state.port = name and name.port or port
  return { host = state.host, port = state.port }
end

--- 停止网关
function M.stop()
  if state.server then
    pcall(function() state.server:close() end)
    state.server = nil
  end
  state.host, state.port = nil, nil
end

--- 当前网关地址（未启动返回 nil）
--- @return table|nil { host, port }
function M.address()
  if not state.server then return nil end
  return { host = state.host, port = state.port }
end

--- 取出并清空探测记录（供工具把探测摘要回传给 AI）
--- @return table 数组 { host, port, open, reason, at }
function M.drain_probes()
  local out = state.probes
  state.probes = {}
  return out
end

--- 探测记录摘要（人类可读）
--- @return string|nil
function M.summary()
  local probes = M.drain_probes()
  if #probes == 0 then return nil end
  local parts = {}
  for _, p in ipairs(probes) do
    parts[#parts + 1] = ("%s:%d %s"):format(p.host, p.port, p.open and "开放(已拦截)" or "关闭")
  end
  return "[NeoAI] 网关端口探测：" .. table.concat(parts, "，")
    .. "。开放端口仅表明有服务监听；沙箱已拦截实际服务访问（原因：仅允许探测端口，不允许使用宿主服务）。"
end

--- 测试用：判定地址是否宿主本机
--- @param host string
--- @return boolean
function M._is_host_local(host)
  return _is_host_local(host)
end

--- 测试用：解析目标
--- @param line string
--- @return string|nil
--- @return number|nil
function M._parse_target(line)
  return _parse_target(line)
end

--- 重置（测试用）
function M.reset()
  M.stop()
  state.probes = {}
  state.host_addrs = nil
end

return M
