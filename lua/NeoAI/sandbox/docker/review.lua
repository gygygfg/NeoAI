--- 会话内容器安全审查（基于 inspect JSON，不依赖命令行文本）
--- @module 'NeoAI.sandbox.docker.review'
---
--- 审查目标不是“容器属于谁”，而是“容器配置是否安全、是否含敏感数据”。
--- AI 可以操作任何通过审查的容器；blocked 容器不可被批准，避免把危险配置重新引入。
---
--- 等级：
---   blocked   = 有宿主根挂载/特权/危险能力/宿主命名空间/设备/发布端口等，永不允许
---   sensitive = 配置安全但含敏感 env / 非 workspace 挂载 / 无资源限制；操作需分级
---   safe      = 无 blocked/sensitive 项；可直接 observe + 生命周期
---   approved  = 用户在审查面板显式批准（按 container id + config digest + TTL）
---
--- 本模块除审批缓存外无 I/O；审批缓存仅进程内、可撤销。

local M = {}

local APPROVAL_TTL = 8 * 3600

local state = {
  approvals = {}, -- [container_id] = { digest = ..., expires = ... }
}

local DANGEROUS_CAPS = {
  CAP_SYS_ADMIN = true, CAP_SYS_PTRACE = true, CAP_NET_ADMIN = true,
  CAP_SYS_MODULE = true, CAP_DAC_READ_SEARCH = true, CAP_SYS_RAWIO = true,
  CAP_SYS_BOOT = true, CAP_MAC_ADMIN = true, CAP_MAC_OVERRIDE = true,
  CAP_AUDIT_CONTROL = true, CAP_SYSLOG = true, CAP_SYS_TIME = true,
  CAP_BPF = true, CAP_PERFMON = true, CAP_CHECKPOINT_RESTORE = true,
}

local DANGEROUS_HOST_PATHS = {
  ["/"] = true, ["/etc"] = true, ["/root"] = true, ["/home"] = true,
  ["/var"] = true, ["/var/run"] = true, ["/run"] = true, ["/proc"] = true,
  ["/sys"] = true, ["/dev"] = true, ["/boot"] = true, ["/usr"] = true,
  ["/var/run/docker.sock"] = true, ["/run/docker.sock"] = true,
}

local SECRET_KEY = {
  PASSWORD = true, PASSWD = true, SECRET = true, TOKEN = true, API_KEY = true,
  APIKEY = true, ACCESS_KEY = true, PRIVATE_KEY = true, CREDENTIAL = true,
  AUTH = true, COOKIE = true, SESSION = true, DSN = true,
}

-- ========== 私有函数 ==========

--- 取 HostConfig（兼容 inspect 的 Config/HostConfig 结构）。
--- @param insp table
--- @return table
local function _hc(insp)
  return type(insp.HostConfig) == "table" and insp.HostConfig or {}
end

--- 路径是否危险（宿主根/系统路径/docker socket）。
--- @param p string
--- @return boolean
local function _dangerous_path(p)
  local path = tostring(p or ""):gsub("/+$", "")
  if path == "" then return true end
  if DANGEROUS_HOST_PATHS[path] then return true end
  if path:match("^/etc/") or path:match("^/proc/") or path:match("^/sys/")
    or path:match("^/dev/") or path:match("^/var/run/") or path:match("^/run/") then
    return true
  end
  if path:match("docker%.sock$") then return true end
  return false
end

--- 路径是否在 workspace 根下。
--- @param p string
--- @param roots table
--- @return boolean
local function _under(p, roots)
  local path = tostring(p or ""):gsub("/+$", "")
  for _, root in ipairs(roots or {}) do
    local r = tostring(root or ""):gsub("/+$", "")
    if r ~= "" and (path == r or path:sub(1, #r + 1) == r .. "/") then return true end
  end
  return false
end

--- env key 是否敏感。
--- @param key string
--- @return boolean
local function _secret_key(key)
  local k = tostring(key or ""):upper()
  for needle in pairs(SECRET_KEY) do
    if k:find(needle, 1, true) then return true end
  end
  return false
end

--- 把 bind 字符串拆成源/目标。
--- @param spec string
--- @return string|nil source
--- @return string|nil target
local function _bind_parts(spec)
  local parts = {}
  for p in (tostring(spec) .. ":"):gmatch("(.-):") do parts[#parts + 1] = p end
  if #parts < 2 then return nil, nil end
  return parts[1], parts[2]
end

-- ========== 公开 API ==========

--- 审查一个容器 inspect 结果。
--- @param insp table
--- @param ctx table|nil { workspace_roots?: string[], session_netns?: boolean, runtimes?: table }
--- @return table { level="blocked"|"sensitive"|"safe", reasons=string[], digest=string }
function M.evaluate(insp, ctx)
  ctx = ctx or {}
  if type(insp) ~= "table" then
    return { level = "blocked", reasons = { "BAD_INSPECT" }, digest = "bad" }
  end
  local hc = _hc(insp)
  local cfg = type(insp.Config) == "table" and insp.Config or {}
  local reasons = {}
  local sensitive = {}
  local function block(r) reasons[#reasons + 1] = r end
  local function soft(r) sensitive[#sensitive + 1] = r end

  if hc.Privileged == true then block("PRIVILEGED") end

  if type(hc.CapAdd) == "table" then
    for _, cap in ipairs(hc.CapAdd) do
      local c = tostring(cap):upper()
      if DANGEROUS_CAPS[c] then block("DANGEROUS_CAP:" .. c)
      elseif c ~= "" then soft("CAP_ADD:" .. c) end
    end
  end
  if type(hc.CapDrop) == "table" and #hc.CapDrop == 0 then
    soft("NO_CAP_DROP")
  end

  for _, k in ipairs({ "PidMode", "IpcMode", "UTSMode", "UsernsMode", "CgroupnsMode" }) do
    local v = hc[k]
    if type(v) == "string" and v ~= "" and v ~= "private" then
      block(k .. ":" .. v)
    end
  end

  local nm = type(hc.NetworkMode) == "string" and hc.NetworkMode or ""
  if nm == "host" and ctx.session_netns ~= true then
    block("NETWORK_HOST")
  elseif nm ~= "" and nm ~= "default" and nm ~= "bridge" and nm ~= "none" and nm ~= "host" then
    soft("NETWORK:" .. nm)
  end

  if type(hc.PortBindings) == "table" and next(hc.PortBindings) ~= nil then
    block("PORT_BINDINGS")
  end
  if hc.PublishAllPorts == true then block("PUBLISH_ALL_PORTS") end

  if type(hc.Devices) == "table" and #hc.Devices > 0 then block("DEVICES") end
  if type(hc.DeviceRequests) == "table" and #hc.DeviceRequests > 0 then block("DEVICE_REQUESTS") end

  if type(hc.SecurityOpt) == "table" then
    for _, opt in ipairs(hc.SecurityOpt) do
      local s = tostring(opt):lower()
      if s:find("seccomp=unconfined", 1, true) or s:find("apparmor=unconfined", 1, true)
        or s:find("label=disable", 1, true) then
        block("UNCONFINED_SECURITY_OPT")
      end
    end
  end

  local runtime = hc.Runtime
  if type(runtime) == "string" and runtime ~= "" then
    local allowed = ctx.runtimes or { runc = true, crun = true, runsc = true, kata = true, ["kata-runtime"] = true }
    if not allowed[runtime] then block("RUNTIME:" .. runtime) end
  end

  local logcfg = hc.LogConfig
  if type(logcfg) == "table" and type(logcfg.Driver) == "string" then
    local drv = logcfg.Driver:lower()
    if drv ~= "" and drv ~= "none" and drv ~= "json-file" and drv ~= "local" then
      block("LOG_DRIVER:" .. drv)
    end
  end

  -- Binds
  if type(hc.Binds) == "table" then
    for _, spec in ipairs(hc.Binds) do
      local src = _bind_parts(spec)
      if not src or _dangerous_path(src) then
        block("DANGEROUS_BIND")
      elseif not _under(src, ctx.workspace_roots or {}) then
        soft("BIND_OUTSIDE_WORKSPACE")
      end
    end
  end

  -- Mounts
  if type(hc.Mounts) == "table" then
    for _, m in ipairs(hc.Mounts) do
      if type(m) == "table" then
        local typ = tostring(m.Type or ""):lower()
        local src = tostring(m.Source or "")
        if typ ~= "bind" then
          soft("MOUNT_TYPE:" .. typ)
        elseif _dangerous_path(src) then
          block("DANGEROUS_MOUNT")
        elseif not _under(src, ctx.workspace_roots or {}) then
          soft("MOUNT_OUTSIDE_WORKSPACE")
        end
      end
    end
  end

  -- 资源限制缺失：不是立即危险，但需要监测/审批。
  local mem = tonumber(hc.Memory) or 0
  local pids = tonumber(hc.PidsLimit) or 0
  if mem <= 0 then soft("NO_MEMORY_LIMIT") end
  if pids <= 0 then soft("NO_PIDS_LIMIT") end

  -- 敏感 env（只看 key；不读取/不记录 value）。
  if type(cfg.Env) == "table" then
    for _, item in ipairs(cfg.Env) do
      local key = tostring(item):match("^([^=]+)=")
      if key and _secret_key(key) then
        soft("SECRET_ENV:" .. key)
        break
      end
    end
  end

  -- 命名卷可能承载数据；不是宿主路径，但属于 sensitive。
  if type(hc.Mounts) == "table" then
    for _, m in ipairs(hc.Mounts) do
      if type(m) == "table" and tostring(m.Type or ""):lower() == "volume" then
        soft("NAMED_VOLUME")
      end
    end
  end

  local level = #reasons > 0 and "blocked" or (#sensitive > 0 and "sensitive" or "safe")
  local all = {}
  for _, r in ipairs(reasons) do all[#all + 1] = r end
  for _, r in ipairs(sensitive) do all[#all + 1] = r end

  return {
    level = level,
    reasons = all,
    digest = M.digest(insp),
  }
end

--- 安全字段的稳定摘要（容器配置变化即失效）。
--- @param insp table
--- @return string
function M.digest(insp)
  if type(insp) ~= "table" then return "bad" end
  local hc = _hc(insp)
  local cfg = type(insp.Config) == "table" and insp.Config or {}
  local env_keys = {}
  if type(cfg.Env) == "table" then
    for _, item in ipairs(cfg.Env) do
      local k = tostring(item):match("^([^=]+)=")
      if k then env_keys[#env_keys + 1] = k end
    end
    table.sort(env_keys)
  end
  local parts = {
    "image=" .. tostring(cfg.Image or ""),
    "user=" .. tostring(cfg.User or ""),
    "privileged=" .. tostring(hc.Privileged == true),
    "network=" .. tostring(hc.NetworkMode or ""),
    "pid=" .. tostring(hc.PidMode or ""),
    "ipc=" .. tostring(hc.IpcMode or ""),
    "uts=" .. tostring(hc.UTSMode or ""),
    "userns=" .. tostring(hc.UsernsMode or ""),
    "cgroupns=" .. tostring(hc.CgroupnsMode or ""),
    "mem=" .. tostring(hc.Memory or 0),
    "pids=" .. tostring(hc.PidsLimit or 0),
    "caps=" .. table.concat(hc.CapAdd or {}, ","),
    "sec=" .. table.concat(hc.SecurityOpt or {}, ","),
    "runtime=" .. tostring(hc.Runtime or ""),
    "env=" .. table.concat(env_keys, ","),
  }
  if type(hc.Binds) == "table" then
    local b = {}
    for _, x in ipairs(hc.Binds) do b[#b + 1] = tostring(x) end
    table.sort(b)
    parts[#parts + 1] = "binds=" .. table.concat(b, ";")
  end
  if type(hc.Mounts) == "table" then
    local m = {}
    for _, x in ipairs(hc.Mounts) do
      if type(x) == "table" then
        m[#m + 1] = table.concat({ tostring(x.Type or ""), tostring(x.Source or ""), tostring(x.Target or "") }, ":")
      end
    end
    table.sort(m)
    parts[#parts + 1] = "mounts=" .. table.concat(m, ";")
  end
  local ok, sum = pcall(vim.fn.sha256, table.concat(parts, "\n"))
  if ok and type(sum) == "string" then return sum end
  return table.concat(parts, "\n")
end

--- 返回给 AI 的脱敏 inspect：隐藏 env 值、宿主 mount 源、registry auth 等。
--- @param insp table
--- @return table
function M.redact_inspect(insp)
  if type(insp) ~= "table" then return insp end
  local out = vim.deepcopy(insp)
  if type(out.Config) == "table" and type(out.Config.Env) == "table" then
    local keys = {}
    for _, item in ipairs(out.Config.Env) do
      local k = tostring(item):match("^([^=]+)=")
      if k then keys[#keys + 1] = k .. "=<redacted>" end
    end
    out.Config.Env = keys
  end
  if type(out.HostConfig) == "table" and type(out.HostConfig.Binds) == "table" then
    local binds = {}
    for _, spec in ipairs(out.HostConfig.Binds) do
      local src, dst = _bind_parts(spec)
      binds[#binds + 1] = "<redacted>:" .. tostring(dst or "?")
    end
    out.HostConfig.Binds = binds
  end
  if type(out.Mounts) == "table" then
    for _, m in ipairs(out.Mounts) do
      if type(m) == "table" then m.Source = "<redacted>" end
    end
  end
  if type(out.NetworkSettings) == "table" then
    out.NetworkSettings.Networks = nil
    out.NetworkSettings.IPAddress = nil
    out.NetworkSettings.GlobalIPv6Address = nil
  end
  return out
end

--- 审批缓存。
--- @param id string
--- @param digest string
--- @param ttl number|nil
function M.approve(id, digest, ttl)
  if type(id) ~= "string" or id == "" or type(digest) ~= "string" then return false end
  state.approvals[id] = { digest = digest, expires = os.time() + (tonumber(ttl) or APPROVAL_TTL) }
  return true
end

--- 撤销审批。
--- @param id string
function M.revoke(id)
  if type(id) ~= "string" or state.approvals[id] == nil then return false end
  state.approvals[id] = nil
  return true
end

--- 是否已批准且 digest 未变化。
--- @param id string
--- @param digest string
--- @return boolean
function M.is_approved(id, digest)
  local a = state.approvals[id]
  if not a then return false end
  if a.expires and a.expires < os.time() then
    state.approvals[id] = nil
    return false
  end
  return a.digest == digest
end

--- 列表（调试/UI）。
--- @return table
function M.approvals()
  local out = {}
  for id, a in pairs(state.approvals) do
    out[#out + 1] = { id = id, digest = a.digest, expires = a.expires }
  end
  table.sort(out, function(x, y) return x.id < y.id end)
  return out
end

--- 操作矩阵。
--- @param level string
--- @param op string observe|lifecycle|logs|exec|destructive
--- @param opts table|nil { approved?: boolean, owned?: boolean }
--- @return boolean
function M.operation_allowed(level, op, opts)
  opts = opts or {}
  if level == "blocked" then return false end
  if op == "inspect" then return true end
  if level == "safe" then
    if op == "observe" or op == "lifecycle" then return true end
    if op == "logs" then return true end
    if op == "exec" then return opts.tier == "N2" or opts.approved == true end
    if op == "destructive" then return opts.owned == true or opts.approved == true end
    return false
  end
  if level == "sensitive" then
    if op == "observe" or op == "lifecycle" then return true end
    if op == "logs" or op == "exec" or op == "destructive" then return opts.approved == true end
    return false
  end
  return false
end

--- 清空审批（测试/会话结束）。
function M.reset()
  state.approvals = {}
end

return M
