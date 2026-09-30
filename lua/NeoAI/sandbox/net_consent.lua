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
  session_allowed = {}, -- "host:port@<svc>" -> true（按端口+服务进程颗粒度）
  session_ports = {}, -- host:port -> true（无服务身份时的端口粒度兼容键）
  session_service_ports = {}, -- host:port -> true（该端口存在服务粒度批准，供门禁决定是否解析进程）
  related = {}, -- "host:port" -> { svc = true } / "svc" -> { "host:port" = true }（相关批准提示）
  listen_negative = {}, -- port -> expire_ms（沙箱内监听探测的短负缓存）
  owner_cache = {}, -- port -> { at_ms, owner }（端口→宿主服务进程解析短缓存）
}

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  local c = require("NeoAI.kernel.config_store").get("tools.sandbox.network")
  return type(c) == "table" and c or {}
end

-- 是否启用「端口+服务进程」颗粒度（默认开）。关闭则退回纯 host:port 键与展示。
local function _granular()
  return _cfg().consent_process_granularity ~= false
end
-- 弹窗无响应超时（毫秒；0 = 不限）。
local function _timeout_ms()
  local v = tonumber(_cfg().consent_timeout_ms)
  if v == nil then v = 30000 end
  return v > 0 and v or 0
end

-- 端口→进程解析缓存 TTL（毫秒）。
local function _owner_ttl_ms()
  local v = tonumber(_cfg().consent_owner_ttl_ms)
  if v == nil then v = 2000 end
  return v > 0 and v or 0
end

--- 服务身份规范键：可执行路径优先（稳定），回退命令名 comm。
--- @param owner table|nil
--- @return string|nil
local function _svc_id(owner)
  if type(owner) ~= "table" then return nil end
  local exe = owner.exe
  if type(exe) == "string" and exe ~= "" then return exe end
  local comm = owner.comm
  if type(comm) == "string" and comm ~= "" then return comm end
  return nil
end

--- 白名单键：有服务身份时为 `host:port@<svc>`，否则回退 `host:port`。
--- @param host string
--- @param port number|string
--- @param svc string|nil
--- @return string
local function _key(host, port, svc)
  local base = tostring(host):lower() .. ":" .. tostring(port)
  if _granular() and type(svc) == "string" and svc ~= "" then
    return base .. "@" .. svc
  end
  return base
end

-- ========== 公开 API ==========

--- 注册/注销 UI（ui 组件 init/reset 调用）
--- @param ui table|nil { show = function(ctx, decide), hide? = function() }
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

--- 是否存在可交互的 Neovim UI（`--headless` 无 attached UI）。
--- @return boolean
local function _interactive()
  local ok, uis = pcall(vim.api.nvim_list_uis)
  return ok and type(uis) == "table" and #uis > 0
end

--- 是否可向用户呈现同意界面（独立弹窗或统一审批窗口任一可用，且确有可交互 UI）。
--- 无任何界面时（headless）直接失败关闭，且**不做**昂贵的端口→进程解析。
--- 独立弹窗（测试可注入 fake UI）不受 attached UI 限制；统一窗口需真实 UI 才能决策。
--- @return boolean
function M.can_prompt()
  if M.policy() ~= "ask" then return false end
  if M.available() then return true end
  local ok, hub = pcall(require, "NeoAI.sandbox.approval_hub")
  return ok and hub.available() == true and _interactive()
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

--- 端口→宿主监听进程解析（用于弹窗展示「端口 + 服务进程」，及按 (端口,进程) 记忆）。
--- 复用 `_parse_listen_inodes` 读 /proc/net/tcp{,6} 的 LISTEN 集，扫全 pid 域 fd 匹配
--- `socket:[inode]`；排除沙箱域（/neoai/ cgroup）进程，只返回**宿主**服务身份。
--- 结果按端口短 TTL 缓存（`consent_owner_ttl_ms`），支撑「每次连接重校验」不反复全扫。
--- @param port number|string
--- @return table|nil { pid:number, comm:string, exe:string|nil, cmdline:string|nil }
function M.port_owner(port)
  local p = tonumber(port)
  if not p or p <= 0 or p > 65535 then return nil end
  local now = vim.uv.hrtime() / 1e6
  local ttl = _owner_ttl_ms()
  local cached = state.owner_cache[p]
  if cached and ttl > 0 and (now - cached.at_ms) < ttl then return cached.owner end
  -- LISTEN socket inode -> port
  local listen = {}
  for _, f in ipairs({ "/proc/net/tcp", "/proc/net/tcp6" }) do
    for ino, lp in pairs(M._parse_listen_inodes(_read_all(f))) do listen[ino] = lp end
  end
  local owner = nil
  if next(listen) then
    local it = vim.uv.fs_scandir("/proc")
    local scanned = 0
    if it then
      while scanned < 8192 do
        local name = vim.uv.fs_scandir_next(it)
        if not name then break end
        if name:match("^%d+$") then
          scanned = scanned + 1
          local fddir = "/proc/" .. name .. "/fd"
          local fh = vim.uv.fs_scandir(fddir)
          if fh then
            while true do
              local fd = vim.uv.fs_scandir_next(fh)
              if not fd then break end
              local target = vim.uv.fs_readlink(fddir .. "/" .. fd)
              local ino = type(target) == "string" and target:match("^socket:%[(%d+)%]$")
              if ino and listen[ino] == p then
                -- 仅命中目标 inode 时才读 cgroup/comm/exe（避免逐 pid 额外 open）：
                -- 排除沙箱自身进程（/neoai/ cgroup 域），只解析宿主服务。
                if not M._is_sandbox_cgroup(_read_all("/proc/" .. name .. "/cgroup")) then
                  local comm = _read_all("/proc/" .. name .. "/comm")
                  local exe = vim.uv.fs_readlink("/proc/" .. name .. "/exe")
                  local raw = _read_all("/proc/" .. name .. "/cmdline")
                  local cmdline
                  if raw and raw ~= "" then
                    cmdline = raw:gsub("%z", " "):gsub("%s+$", "")
                  end
                  owner = {
                    pid = tonumber(name),
                    comm = (comm and comm:gsub("%s+$", "")) or "?",
                    exe = (type(exe) == "string" and exe ~= "") and exe or nil,
                    cmdline = cmdline,
                  }
                end
                break
              end
            end
          end
        end
        if owner then break end
      end
    end
  end
  state.owner_cache[p] = { at_ms = now, owner = owner }
  return owner
end

--- 本次会话内用户是否已同意访问该目标。
--- 有服务身份时按 (端口,进程) 颗粒度匹配（进程变化即视为未同意 → 重新询问）；
--- 无服务身份时退回纯端口粒度（旧行为）。
--- @param host string
--- @param port number|string
--- @param owner table|nil 服务进程身份（`port_owner` 结果）
--- @return boolean
function M.is_session_allowed(host, port, owner)
  local svc = _svc_id(owner)
  if _granular() and svc then
    return state.session_allowed[_key(host, port, svc)] == true
  end
  return state.session_ports[_key(host, port)] == true
end

--- 该目标是否存在「服务粒度」的会话批准（门禁据此决定是否需要解析端口→进程以重校验）。
--- @param host string
--- @param port number|string
--- @return boolean
function M.has_session_approval(host, port)
  local base = _key(host, port)
  return state.session_ports[base] == true or state.session_service_ports[base] == true
end

--- 记住本次会话对该目标的同意（按 (端口,进程) 颗粒度；无服务身份时退回端口粒度）。
--- @param host string
--- @param port number|string
--- @param owner table|nil
function M.allow_session(host, port, owner)
  local svc = _svc_id(owner)
  local base = _key(host, port)
  if _granular() and svc then
    state.session_allowed[_key(host, port, svc)] = true
    state.session_service_ports[base] = true
    local rel = state.related
    rel[base] = rel[base] or {}
    rel[base][svc] = true
    rel[svc] = rel[svc] or {}
    rel[svc][base] = true
  else
    state.session_ports[base] = true
  end
end

--- 本会话中与当前目标「相关」的历史批准（供弹窗提示：同进程的其它端口 / 同端口的其它进程）。
--- @param host string
--- @param port number|string
--- @param owner table|nil
--- @return table 形如 { ports = {"host:port", ...}, services = {svc, ...} }
function M.related_approvals(host, port, owner)
  local base = _key(host, port)
  local out = { ports = {}, services = {} }
  local svc = _svc_id(owner)
  local by_base = state.related[base]
  if by_base then
    for s in pairs(by_base) do out.services[#out.services + 1] = s end
  end
  if svc and state.related[svc] then
    for b in pairs(state.related[svc]) do
      if b ~= base then out.ports[#out.ports + 1] = b end
    end
  end
  table.sort(out.ports)
  table.sort(out.services)
  return out
end

--- 请求用户同意。
--- @param ctx table { host, port, local_?, proto?, owner? }
--- @return Deferred resolve(decision: "allow_once"|"allow_session"|"deny")
function M.request(ctx)
  local async = require("NeoAI.utils.async")
  local d = async.Deferred.new()
  ctx = ctx or {}
  -- 解析服务身份（宿主监听进程）：供展示与 (端口,进程) 颗粒度。
  -- 门禁（host_proxy）已解析时用其传入结果（owner_resolved=true），避免重复全扫 /proc；
  -- 无任何可呈现界面（headless）时不解析——直接失败关闭。
  if ctx.owner == nil and ctx.owner_resolved ~= true and ctx.local_ and M.can_prompt() then
    ctx.owner = M.port_owner(ctx.port)
  end
  local owner = ctx.owner
  ctx.service = owner and {
    pid = owner.pid, comm = owner.comm, exe = owner.exe, cmdline = owner.cmdline,
  } or nil
  ctx.related = M.related_approvals(ctx.host, ctx.port, owner)

  local done = false
  local hub_id
  local function decide(decision)
    if done then return end
    done = true
    if decision ~= "allow_once" and decision ~= "allow_session" and decision ~= "deny" then
      decision = "deny"
    end
    if hub_id then pcall(function() require("NeoAI.sandbox.approval_hub").clear(hub_id) end) end
    d:resolve(decision)
  end

  -- 无 UI（headless / 非 ask / 无窗口）：失败关闭。
  -- 统一窗口（approval_hub）需真实 attached UI 才能决策；headless 下不视为可用界面。
  local hub = require("NeoAI.sandbox.approval_hub")
  local standalone = M.available()
  local via_hub = hub.available() and _interactive()
  if not standalone and not via_hub then
    d:resolve("deny")
    return d
  end

  -- 镜像到审批分流中心「网络请求」页（窗口可决策；独立弹窗仍在时以先决策者为准）。
  hub_id = hub.submit("network", {
    title = string.format("%s:%s%s", tostring(ctx.host or "?"), tostring(ctx.port or "?"),
      owner and owner.comm and ("（" .. owner.comm .. (owner.pid and (" pid " .. owner.pid) or "") .. "）") or ""),
    detail = {},
    decisions = {
      { key = "<CR>", label = "仅本次允许", value = "allow_once" },
      { key = "S", label = "本次会话允许该服务", value = "allow_session" },
      { key = "<Esc>", label = "拒绝", value = "deny" },
    },
    on_decision = decide,
    meta = { host = ctx.host, port = ctx.port, local_ = ctx.local_, proto = ctx.proto, service = ctx.service },
  })

  -- 独立弹窗（即时阻塞响应）：存在时优先展示；决策后同步清理中心条目。
  if standalone then
    local ok = pcall(state.ui.show, ctx, decide)
    if not ok then decide("deny") end
  else
    -- 仅统一窗口可用：拉起窗口到「网络请求」页，由其决策。
    pcall(function() hub.open_page("network") end)
  end

  -- 超时兜底：用户长时间不响应时自动拒绝（fail-closed），避免连接永久悬挂。
  local tms = _timeout_ms()
  if tms > 0 then
    vim.defer_fn(function()
      if done then return end
      if state.ui and state.ui.hide then pcall(state.ui.hide) end
      decide("deny")
    end, tms)
  end
  return d
end

--- 重置（测试用）
function M.reset()
  state.ui = nil
  state.internal_ports = {}
  state.session_allowed = {}
  state.session_ports = {}
  state.session_service_ports = {}
  state.related = {}
  state.listen_negative = {}
  state.owner_cache = {}
end

return M
