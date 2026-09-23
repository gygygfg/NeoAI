--- 沙箱网络访问同意服务
--- @module NeoAI.sandbox.net_consent
--- 沙箱内部创建的进程/绑定的服务端口，在沙箱内访问**免权限**（回环 + 内部端口登记表 +
--- `allow_localhost_ports` 白名单）；访问沙箱外部（宿主本机其他端口、宿主网卡、外部主机）
--- 弹窗请求用户同意。
---
--- UI 通过 `set_ui({ show = fn })` 注册（见 ui/components/net_consent）。`request` 返回 Deferred，
--- resolve 决策字符串：`allow_once` | `allow_session` | `deny`。headless 无 UI 时失败关闭（拒绝）。

local M = {}

-- ========== 私有状态 ==========

local state = {
  ui = nil,
  internal_ports = {}, -- port -> true（沙箱内部服务端口）
  session_allowed = {}, -- "host:port" -> true（本次会话内用户已同意）
  listen_negative = {}, -- port -> expire_ms（沙箱内监听探测的短负缓存）
}

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  local c = require("NeoAI.kernel.config_store").get("tools.sandbox.network")
  return type(c) == "table" and c or {}
end

local function _key(host, port)
  return tostring(host):lower() .. ":" .. tostring(port)
end

-- ========== 公开 API ==========

--- 注册/注销 UI（ui 组件 init/reset 调用）
--- @param ui table|nil { show = function(ctx, decide) }
function M.set_ui(ui)
  state.ui = ui
end

--- 访问策略：`ask`（弹窗同意，默认）| `allow`（直接放行）| `deny`（直接拒绝）
--- @return string
function M.policy()
  local p = _cfg().access
  if p ~= "allow" and p ~= "deny" then p = "ask" end
  return p
end

--- 是否可弹窗（策略为 ask 且有 UI）
--- @return boolean
function M.available()
  if M.policy() ~= "ask" then return false end
  return state.ui ~= nil and type(state.ui.show) == "function"
end

--- 登记沙箱内部服务端口（免权限）。供长驻服务/后台进程启动时调用。
--- @param port number|string
function M.register_internal_port(port)
  local p = tonumber(port)
  if p and p > 0 and p <= 65535 then state.internal_ports[p] = true end
end

--- 注销内部端口
--- @param port number|string
function M.unregister_internal_port(port)
  local p = tonumber(port)
  if p then state.internal_ports[p] = nil end
end

--- 端口是否为已登记的沙箱内部服务端口
--- @param port number|string
--- @return boolean
function M.is_internal_port(port)
  local p = tonumber(port)
  return p ~= nil and state.internal_ports[p] == true
end

--- 从命令/环境推断沙箱内部服务端口并登记（供长驻服务/后台进程启动时自动免权限）。
--- 仅识别明确端口声明，避免误放行：环境变量 `PORT` 等，及 `--port[= ]N` / `--listen-port` /
--- `--http-port` / `--server-port`。返回登记的端口数组。
--- @param command string|nil
--- @param env table|nil
--- @return table ports
function M.register_from_command(command, env)
  local found = {}
  local function add(v)
    local p = tonumber(v)
    if p and p > 0 and p <= 65535 then
      if not state.internal_ports[p] then
        state.internal_ports[p] = true
        found[#found + 1] = p
      end
    end
  end
  if type(env) == "table" then
    for _, k in ipairs({ "PORT", "port", "LISTEN_PORT", "HTTP_PORT", "SERVER_PORT", "APP_PORT" }) do
      if env[k] ~= nil then add(env[k]) end
    end
  end
  if type(command) == "string" then
    for v in command:gmatch("%-%-port[=%s]+(%d+)") do add(v) end
    for v in command:gmatch("%-%-listen%-port[=%s]+(%d+)") do add(v) end
    for v in command:gmatch("%-%-http%-port[=%s]+(%d+)") do add(v) end
    for v in command:gmatch("%-%-server%-port[=%s]+(%d+)") do add(v) end
  end
  return found
end

--- 注销一组内部端口
--- @param ports table|nil
function M.unregister_ports(ports)
  if type(ports) ~= "table" then return end
  for _, p in ipairs(ports) do M.unregister_internal_port(p) end
end

-- ========== 沙箱内监听端口自动登记 ==========
-- 修复「网络过滤层对 127.0.0.1 也一律拦截」的过度拦截：沙箱内命令启动的临时监听服务
-- （未走 service 模块、未声明 PORT/--port）在首次被沙箱内访问时自动识别并免权限。
-- 判定：/proc/net/tcp{,6} 的 LISTEN socket inode 由 /neoai/ cgroup 内的进程持有。
-- 共享 netns 下无法按地址区分宿主/沙箱，故以 cgroup 归属区分，仅放行沙箱自己监听的回环端口；
-- 宿主回环服务仍按 ask/deny 策略处理（SSRF 防护不削弱）。

--- 读取整个文件（失败返回 nil）
--- @param path string
--- @return string|nil
local function _read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local v = f:read("*a")
  f:close()
  return v
end

--- 解析 /proc/net/tcp(6) 文本，返回 LISTEN 端口的 inode→port 映射。
--- 字段：1=sl 2=local 3=rem 4=st 5=tx:rx 6=tr 7=retrnsmt 8=uid 9=timeout 10=inode。
--- @param text string|nil
--- @return table<string, number>
function M._parse_listen_inodes(text)
  local map = {}
  if type(text) ~= "string" then return map end
  for line in text:gmatch("[^\n]+") do
    local toks = {}
    for t in line:gmatch("%S+") do toks[#toks + 1] = t end
    if toks[4] == "0A" and toks[2] and toks[10] then
      local ph = toks[2]:match(":(%x+)$")
      local port = ph and tonumber(ph, 16)
      if port and port > 0 then map[toks[10]] = port end
    end
  end
  return map
end

--- /proc/<pid>/cgroup 文本是否表示沙箱域成员（路径含 /neoai/）。
--- @param text string|nil
--- @return boolean
function M._is_sandbox_cgroup(text)
  return type(text) == "string" and text:find("/neoai/", 1, true) ~= nil
end

--- 收集沙箱域内的 PID（有上限，避免遍历爆炸）。
--- @param max_pids number|nil
--- @return table pid 字符串数组
local function _sandbox_pids(max_pids)
  max_pids = max_pids or 4096
  local out = {}
  local it = vim.uv.fs_scandir("/proc")
  if not it then return out end
  while true do
    local name = vim.uv.fs_scandir_next(it)
    if not name then break end
    if name:match("^%d+$") and M._is_sandbox_cgroup(_read_all("/proc/" .. name .. "/cgroup")) then
      out[#out + 1] = name
      if #out >= max_pids then break end
    end
  end
  return out
end

--- 目标端口是否由沙箱内进程监听；是则登记为内部端口并返回 true。
--- @param port number|string
--- @return boolean
function M.is_sandbox_listening(port)
  local p = tonumber(port)
  if not p or p <= 0 or p > 65535 then return false end
  if state.internal_ports[p] then return true end
  -- 负缓存：宿主回环服务会反复命中此路径，避免每次连接都全量扫描 /proc。
  local now = vim.uv.hrtime() / 1e6
  local neg = state.listen_negative or {}
  if neg[p] and neg[p] > now then return false end
  local listen = {}
  for _, f in ipairs({ "/proc/net/tcp", "/proc/net/tcp6" }) do
    for ino, lp in pairs(M._parse_listen_inodes(_read_all(f))) do listen[ino] = lp end
  end
  local found = false
  if next(listen) then
    for _, pid in ipairs(_sandbox_pids()) do
      local fddir = "/proc/" .. pid .. "/fd"
      local fh = vim.uv.fs_scandir(fddir)
      if fh then
        while true do
          local fd = vim.uv.fs_scandir_next(fh)
          if not fd then break end
          local target = vim.uv.fs_readlink(fddir .. "/" .. fd)
          local ino = type(target) == "string" and target:match("^socket:%[(%d+)%]$")
          if ino and listen[ino] == p then found = true; break end
        end
      end
      if found then break end
    end
  end
  if found then
    state.internal_ports[p] = true
  else
    state.listen_negative = neg
    neg[p] = now + 3000
  end
  return found
end

--- 扫描并登记沙箱内全部监听端口（供诊断/主动预热）。
--- @return table 端口数组
function M.register_sandbox_listeners()
  local found = {}
  local listen = {}
  for _, f in ipairs({ "/proc/net/tcp", "/proc/net/tcp6" }) do
    for ino, lp in pairs(M._parse_listen_inodes(_read_all(f))) do listen[ino] = lp end
  end
  if not next(listen) then return found end
  for _, pid in ipairs(_sandbox_pids()) do
    local fddir = "/proc/" .. pid .. "/fd"
    local fh = vim.uv.fs_scandir(fddir)
    if fh then
      while true do
        local fd = vim.uv.fs_scandir_next(fh)
        if not fd then break end
        local target = vim.uv.fs_readlink(fddir .. "/" .. fd)
        local ino = type(target) == "string" and target:match("^socket:%[(%d+)%]$")
        local lp = ino and listen[ino]
        if lp and not state.internal_ports[lp] then
          state.internal_ports[lp] = true
          found[#found + 1] = lp
        end
      end
    end
  end
  return found
end

--- 本次会话内用户是否已同意访问该目标
--- @param host string
--- @param port number|string
--- @return boolean
function M.is_session_allowed(host, port)
  return state.session_allowed[_key(host, port)] == true
end

--- 记住本次会话对该目标的同意
--- @param host string
--- @param port number|string
function M.allow_session(host, port)
  state.session_allowed[_key(host, port)] = true
end

--- 请求用户同意。
--- @param ctx table { host, port, local_?, proto? }
--- @return Deferred resolve(decision: "allow_once"|"allow_session"|"deny")
function M.request(ctx)
  local async = require("NeoAI.utils.async")
  local d = async.Deferred.new()
  if not M.available() then
    -- headless / 无 UI / 非 ask 策略：失败关闭
    d:resolve("deny")
    return d
  end
  local done = false
  local function decide(decision)
    if done then return end
    done = true
    if decision ~= "allow_once" and decision ~= "allow_session" and decision ~= "deny" then
      decision = "deny"
    end
    d:resolve(decision)
  end
  local ok = pcall(state.ui.show, ctx or {}, decide)
  if not ok then
    decide("deny")
  end
  return d
end

--- 重置（测试用）
function M.reset()
  state.ui = nil
  state.internal_ports = {}
  state.session_allowed = {}
  state.listen_negative = {}
end

return M
