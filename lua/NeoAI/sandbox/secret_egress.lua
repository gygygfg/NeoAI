--- 密钥出网守卫：向非白名单地址**发送密钥**时弹窗阻止并警告；白名单地址（含自动信任的
--- 模型供应商）不弹窗也不警告。headless 无 UI 时失败关闭（拒绝发送）。
--- @module NeoAI.sandbox.secret_egress
--- 覆盖：`utils/http`（程序化 HTTP：模型/MCP-HTTP）、沙箱子进程（curl/wget/nc 等）、
--- run_command。目标主机不可判定时按「非白名单」处理，需用户确认。

local M = {}

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  local c = require("NeoAI.kernel.config_store").get("tools.sandbox.secrets")
  return type(c) == "table" and c or {}
end

--- 是否启用出网守卫
--- @return boolean
function M.enabled()
  return _cfg().enabled ~= false
end

--- 从 URL / endpoint 解析主机名
--- @param s string|nil
--- @return string|nil
function M.host_of(s)
  if type(s) ~= "string" or s == "" then return nil end
  local host = s:match("^%a[%w+.-]*://([^/%?#]+)")
  if not host then
    -- 无 scheme：取首个 `host:port` 或裸主机
    host = s:match("^([%w%._%-]+:%d+)") or s:match("^([%w%._%-]+)")
  end
  if not host then return nil end
  host = host:gsub("^%[", ""):gsub("%]$", "")
  host = host:gsub(":%d+$", "")
  if host == "" then return nil end
  return host:lower()
end

--- IPv4 → 32 位整数
--- @param ip string
--- @return number|nil
local function _ip_to_int(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

--- 主机是否匹配 CIDR
--- @param host string
--- @param cidr string
--- @return boolean
local function _cidr_match(host, cidr)
  local net, bits = cidr:match("^(.+)/(%d+)$")
  bits = tonumber(bits)
  if not net or not bits or bits < 0 or bits > 32 then return false end
  local hi, lo = _ip_to_int(host), _ip_to_int(net)
  if not hi or not lo then return false end
  if bits == 0 then return true end
  local divisor = 2 ^ (32 - bits)
  return math.floor(hi / divisor) == math.floor(lo / divisor)
end

--- 主机是否匹配单个白名单模式（精确 / `*.suffix` / CIDR）
--- @param host string
--- @param pat string
--- @return boolean
local function _host_matches(host, pat)
  if type(pat) ~= "string" or pat == "" then return false end
  pat = pat:lower():gsub("^%a[%w+.-]*://", ""):gsub("/.*$", ""):gsub(":%d+$", "")
  if pat == host then return true end
  if pat:sub(1, 2) == "*." then
    local suffix = pat:sub(2)
    return #host > #suffix and host:sub(-#suffix) == suffix
  end
  if pat:find("/", 1, true) then return _cidr_match(host, pat) end
  return false
end

--- 主机是否可信（白名单 + 自动信任的模型供应商）
--- @param host string|nil
--- @return boolean
function M.trusted(host)
  if type(host) ~= "string" or host == "" then return false end
  host = host:lower()
  for _, pat in ipairs(_cfg().trusted_services or {}) do
    if _host_matches(host, pat) then return true end
  end
  if _cfg().auto_trust_providers ~= false then
    local providers = require("NeoAI.kernel.config_store").get("ai.providers") or {}
    for _, p in pairs(providers) do
      if type(p) == "table" and type(p.base_url) == "string" then
        local h = M.host_of(p.base_url)
        if h and h == host then return true end
      end
    end
  end
  return false
end

--- 把主机加入白名单（内存配置；用户经弹窗选择「加入白名单」时调用）
--- @param host string
function M.add_trusted(host)
  if type(host) ~= "string" or host == "" then return end
  host = host:lower()
  local cfg = _cfg()
  local list = {}
  for _, p in ipairs(cfg.trusted_services or {}) do list[#list + 1] = p end
  for _, p in ipairs(list) do
    if type(p) == "string" and _host_matches(host, p) then return end
  end
  list[#list + 1] = host
  pcall(function()
    require("NeoAI.kernel.config_store").set("tools.sandbox.secrets.trusted_services", list)
  end)
end

--- 检测 payload 中是否含密钥（真实值或将被还原的假密钥）
--- @param payload string
--- @return string|nil 命中的原始密钥；或 "fake"
local function _payload_secret(payload)
  if type(payload) ~= "string" or payload == "" then return nil end
  local secret = require("NeoAI.sandbox.secret")
  local real = secret.find_real_secret and secret.find_real_secret(payload)
  if real then return real end
  if secret.has_token and secret.has_token(payload) then return "fake" end
  return nil
end

--- 检查一次出网：可信目标直接放行；含密钥的非可信目标需用户确认（headless 拒绝）。
--- @param dest string 目标（URL/主机/描述）
--- @param payload string 将被发送的内容（命令/headers/body/env 拼接）
--- @param meta table|nil { tool?, agent? }
--- @return Deferred resolve(true 允许) / reject(err 阻止)
function M.check(dest, payload, meta)
  local async = require("NeoAI.utils.async")
  if not M.enabled() then return async.resolve(true) end
  local host = M.host_of(dest) or dest
  if M.trusted(host) then return async.resolve(true) end
  local hit = _payload_secret(payload)
  if not hit then return async.resolve(true) end
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(require("NeoAI.kernel.events").SANDBOX_SECRET_EGRESS, {
      dest = dest, tool = meta and meta.tool, agent_id = meta and meta.agent and meta.agent.id,
    })
  end)
  local err = {
    kind = "secret",
    message = "SANDBOX_SECRET_EGRESS_BLOCKED: 向非白名单地址发送密钥被阻止: " .. tostring(dest),
  }
  local alert = require("NeoAI.sandbox.secret_alert")
  if not alert.available() then return async.reject(err) end
  return alert.request({
    kind = "egress", dest = dest, agent = meta and meta.agent,
    command = meta and meta.command or dest,
    secret = (hit ~= "fake") and hit or nil,
    secret_preview = (hit ~= "fake") and (tostring(hit):sub(1, 6) .. "…") or "假密钥",
  }):then_(function(decision)
    if decision == "stop" then return async.reject(err) end
    if decision == "whitelist" and host then M.add_trusted(host) end
    return true
  end)
end

-- ========== 出网路径守卫 ==========

--- HTTP 请求守卫（utils/http 通过 set_guard 注册）。
--- @param opts table { base_url, path?, headers?, body?, query? }
--- @return Deferred|nil
function M.guard_http(opts)
  if not M.enabled() then return nil end
  local host = M.host_of(opts.base_url)
  if M.trusted(host) then return nil end
  local parts = { tostring(opts.path or "") }
  if opts.query then parts[#parts + 1] = tostring(opts.query) end
  if opts.headers then
    for k, v in pairs(opts.headers) do parts[#parts + 1] = tostring(k) .. ": " .. tostring(v) end
  end
  if opts.body ~= nil then
    if type(opts.body) == "string" then
      parts[#parts + 1] = opts.body
    else
      local ok, enc = pcall(require("NeoAI.utils.json").encode, opts.body)
      parts[#parts + 1] = ok and enc or tostring(opts.body)
    end
  end
  local payload = table.concat(parts, "\n")
  if not _payload_secret(payload) then return nil end
  return M.check(opts.base_url, payload, { tool = "http" })
end

-- 网络类命令（用于判定命令是否可能出网）
local NETWORK_BINS = {
  curl = true, wget = true, nc = true, ncat = true, netcat = true, socat = true,
  telnet = true, ssh = true, scp = true, sftp = true, rsync = true, ftp = true,
  dig = true, nslookup = true, host = true, ping = true, git = true, pip = true,
  pip3 = true, npm = true, npx = true, python = true, python3 = true, node = true,
  ruby = true, php = true, go = true, cargo = true, docker = true, kubectl = true,
}

--- 命令是否可能出网
--- @param command string
--- @return boolean
local function _may_egress(command)
  if type(command) ~= "string" then return false end
  for tok in command:gmatch("[%w_%./%-]+") do
    local base = tok:match("[^/]+$") or tok
    if NETWORK_BINS[base] then return true end
  end
  return false
end

--- 从命令中提取候选目标主机
--- @param command string
--- @return table 主机数组
local function _extract_hosts(command)
  local hosts, seen = {}, {}
  local function add(h)
    if h and h ~= "" and not seen[h] then seen[h] = true; hosts[#hosts + 1] = h end
  end
  for url in command:gmatch("%a[%w+.-]*://[^%s'\"]+") do add(M.host_of(url)) end
  -- 裸主机/IP（含 user@host:port）
  for h in command:gmatch("[@%s]([%w][%w%._%-]*%.[%w][%w%._%-]*)") do
    if not h:find("%.", 1, true) or h:match("%.%d") or h:match("%a%.") then add(h:lower()) end
  end
  for ip in command:gmatch("(%d+%.%d+%.%d+%.%d+)") do add(ip) end
  return hosts
end

--- 沙箱子进程 / run_command 出网守卫。
--- @param command string 即将执行的命令
--- @param env table|nil 进程环境（可含假密钥，将在沙箱内还原）
--- @param meta table|nil { tool?, agent? }
--- @return Deferred|nil nil=放行；Deferred=需确认（resolve 继续 / reject 阻止）
function M.guard_process(command, env, meta)
  if not M.enabled() then return nil end
  if not _may_egress(command) then return nil end
  local payload = tostring(command)
  local has = _payload_secret(payload) ~= nil
  -- 仅当命令**引用了**某环境变量名时才检查其值：沙箱进程环境本就被注入了真实密钥，
  -- 若对所有 env 值无差别检查，任何命令都会被误判为「发送密钥」。
  if env then
    for k, v in pairs(env) do
      if type(v) == "string" and type(k) == "string"
        and (command:find(k, 1, true) or command:find("$" .. k, 1, true))
        and _payload_secret(v) then
        has = true
        payload = payload .. "\n" .. tostring(k) .. "=" .. v
      end
    end
  end
  if not has then return nil end
  local hosts = _extract_hosts(command)
  local m = vim.tbl_extend("keep", meta or {}, { command = command })
  if #hosts == 0 then
    return M.check("(未知目标)", payload, m)
  end
  for _, h in ipairs(hosts) do
    if not M.trusted(h) then return M.check(h, payload, m) end
  end
  return nil
end

--- 重置（测试用）
function M.reset() end

return M
