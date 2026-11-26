--- 会话内 Docker API 策略（endpoint 白名单 + HostConfig/NetworkingConfig 检查）
--- @module 'NeoAI.sandbox.docker.policy'
---
--- 输入是**解析后的 HTTP 请求 + JSON body**，不是命令行文本。所有拒绝都基于结构化字段：
--- endpoint、method、HostConfig、Mounts、NetworkMode、CapAdd、SecurityOpt 等。
--- 命令行/镜像名/标签最多用于风险提示，绝不作为拒绝依据（AGENTS.md #9）。
---
--- 本模块无 I/O，便于离线单测。

local http = require("NeoAI.sandbox.docker.http")

local M = {}

local DEFAULT_RUNTIMES = { runc = true, crun = true, runsc = true, kata = true, ["kata-runtime"] = true }
local DEFAULT_REGISTRIES = {
  ["docker.io"] = true, ["registry-1.docker.io"] = true, ["ghcr.io"] = true,
  ["quay.io"] = true, ["gcr.io"] = true, ["mcr.microsoft.com"] = true,
}
local DANGEROUS_DEST = {
  ["/"] = true, ["/etc"] = true, ["/root"] = true, ["/home"] = true, ["/var"] = true,
  ["/run"] = true, ["/proc"] = true, ["/sys"] = true, ["/dev"] = true, ["/boot"] = true,
  ["/usr"] = true,
}

-- ========== 私有函数 ==========

--- 规范化宿主路径（仅做字符串规范化；realpath 由调用方完成）。
--- @param p string
--- @return string|nil
local function _clean_path(p)
  if type(p) ~= "string" or p == "" or p:sub(1, 1) ~= "/" then return nil end
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == "." then
      -- skip
    elseif seg == ".." then
      if #parts == 0 then return nil end
      table.remove(parts)
    else
      parts[#parts + 1] = seg
    end
  end
  return "/" .. table.concat(parts, "/")
end

--- 路径是否位于允许根之下（按目录边界，不接受 `/work2` 命中 `/work`）。
--- @param path string
--- @param roots table
--- @return boolean
local function _under(path, roots)
  for _, root in ipairs(roots or {}) do
    if type(root) == "string" and root ~= "" then
      local r = root:gsub("/+$", "")
      if r == "" then r = "/" end
      if path == r or path:sub(1, #r + 1) == r .. "/" then return true end
    end
  end
  return false
end

--- 解析 `src:dst[:ro|rw]`，按 Docker 语义只允许简单形式；含 `:` 的源路径拒绝。
--- @param spec string
--- @return table|nil { source, target, mode }
local function _parse_bind(spec)
  if type(spec) ~= "string" or spec == "" then return nil end
  local parts = {}
  for p in (spec .. ":"):gmatch("(.-):") do parts[#parts + 1] = p end
  if #parts < 2 or #parts > 3 then return nil end
  local source, target, mode = parts[1], parts[2], parts[3]
  if source == "" or target == "" then return nil end
  if mode == nil or mode == "" then mode = "rw" end
  if mode ~= "ro" and mode ~= "rw" and mode ~= "z" and mode ~= "Z" then return nil end
  return { source = source, target = target, mode = mode }
end

--- 校验 bind 源：规范化后必须位于 workspace 根；容器目标不得是敏感路径。
--- @param source string
--- @param target string
--- @param ctx table
--- @return boolean ok
--- @return string|nil reason
local function _check_bind(source, target, ctx)
  local src = _clean_path(source)
  if not src then return false, "BIND_BAD_SOURCE" end
  local roots = ctx.workspace_roots or {}
  if not _under(src, roots) then return false, "BIND_OUTSIDE_WORKSPACE" end
  local dst = _clean_path(target)
  if not dst then return false, "BIND_BAD_TARGET" end
  if DANGEROUS_DEST[dst] or dst:match("^/etc/") or dst:match("^/proc/")
    or dst:match("^/sys/") or dst:match("^/dev/") or dst:match("^/var/run/") then
    return false, "BIND_SENSITIVE_TARGET"
  end
  if dst == "/run/docker.sock" or dst == "/var/run/docker.sock" then
    return false, "BIND_DOCKER_SOCKET"
  end
  return true, nil
end

--- 检查一个 Mounts 条目。
--- @param mount table
--- @param ctx table
--- @return boolean ok
--- @return string|nil reason
local function _check_mount(mount, ctx)
  if type(mount) ~= "table" then return false, "MOUNT_BAD" end
  local typ = tostring(mount.Type or ""):lower()
  if typ ~= "bind" then return false, "MOUNT_TYPE_" .. typ:upper() end
  return _check_bind(tostring(mount.Source or ""), tostring(mount.Target or ""), ctx)
end

--- 取镜像 registry（Docker 语义：首段含 `.`/`:` 或 localhost 才是 registry）。
--- @param image string
--- @return string
local function _registry(image)
  local first = tostring(image):match("^([^/]+)/")
  if not first then return "docker.io" end
  if first:find("%.") or first:find(":") or first == "localhost" then return first end
  return "docker.io"
end

--- 合并 label：用户不能覆盖 NeoAI 自己的标签。
--- @param labels table|nil
--- @param injected table|nil
--- @return table
local function _merge_labels(labels, injected)
  local out = {}
  if type(labels) == "table" then
    for k, v in pairs(labels) do
      if type(k) == "string" and not k:match("^neoai%.sandbox%.") then out[k] = v end
    end
  end
  for k, v in pairs(injected or {}) do out[k] = v end
  return out
end

--- 应用资源默认值（只补缺，不覆盖用户更严格的限制）。
--- @param hc table
--- @param limits table|nil
local function _apply_limits(hc, limits)
  limits = limits or {}
  local mem = tonumber(limits.memory_bytes) or (2 * 1024 * 1024 * 1024)
  local pids = tonumber(limits.pids) or 512
  local cpus = tonumber(limits.nano_cpus) or 1000000000

  local function _num(v)
    local n = tonumber(v)
    if not n or n <= 0 then return nil end
    return n
  end
  hc.Memory = _num(hc.Memory) or mem
  hc.PidsLimit = _num(hc.PidsLimit) or pids
  hc.NanoCpus = _num(hc.NanoCpus) or cpus
  hc.OomKillDisable = false
end

-- ========== 端点判定 ==========

--- 解析并判定 endpoint（不检查容器归属；归属由 broker/review 处理）。
--- @param req table
--- @param info table normalize_path 结果
--- @param ctx table
--- @return table { allow, status?, reason? }
local function _endpoint(req, info, ctx)
  local seg = info.segments
  local m = req.method
  local function allow() return { allow = true } end
  local function deny(reason, status)
    return { allow = false, status = status or 403, reason = reason }
  end

  if #seg == 1 and (seg[1] == "_ping" or seg[1] == "version" or seg[1] == "info") then
    if m == "GET" or m == "HEAD" then return allow() end
    return deny("METHOD_NOT_ALLOWED", 405)
  end

  if seg[1] == "containers" then
    if #seg == 2 and seg[2] == "json" then
      if m == "GET" then return allow() end
      return deny("METHOD_NOT_ALLOWED", 405)
    end
    if #seg == 2 and seg[2] == "create" then
      if m == "POST" then return allow() end
      return deny("METHOD_NOT_ALLOWED", 405)
    end
    if #seg >= 3 then
      local id, action = seg[2], seg[3]
      if id == "" or id == ".." then return deny("BAD_CONTAINER_ID") end
      if #seg == 3 and (m == "GET" or m == "DELETE") then return allow() end
      if #seg == 3 and m == "POST" then return deny("CONTAINER_POST_NOT_ALLOWED") end
      if #seg == 4 then
        if action == "start" or action == "stop" or action == "restart"
          or action == "kill" or action == "wait" or action == "resize" then
          return (m == "POST") and allow() or deny("METHOD_NOT_ALLOWED", 405)
        end
        if action == "logs" or action == "stats" then
          return (m == "GET") and allow() or deny("METHOD_NOT_ALLOWED", 405)
        end
        if action == "attach" then
          if ctx.allow_attach == false then return deny("ATTACH_DISABLED") end
          return (m == "POST") and allow() or deny("METHOD_NOT_ALLOWED", 405)
        end
        if action == "exec" then
          if ctx.allow_exec ~= true then return deny("EXEC_DISABLED") end
          return (m == "POST") and allow() or deny("METHOD_NOT_ALLOWED", 405)
        end
        return deny("CONTAINER_ACTION_DENIED")
      end
    end
    return deny("CONTAINER_ENDPOINT_DENIED")
  end

  if seg[1] == "exec" then
    if #seg >= 3 and seg[3] == "start" then
      if ctx.allow_exec ~= true then return deny("EXEC_DISABLED") end
      return (m == "POST") and allow() or deny("METHOD_NOT_ALLOWED", 405)
    end
    return deny("EXEC_ENDPOINT_DENIED")
  end

  if seg[1] == "images" then
    if #seg == 2 and seg[2] == "json" then
      return (m == "GET") and allow() or deny("METHOD_NOT_ALLOWED", 405)
    end
    if #seg == 2 and seg[2] == "create" then
      if m ~= "POST" then return deny("METHOD_NOT_ALLOWED", 405) end
      if ctx.allow_pull == false then return deny("PULL_DISABLED") end
      return allow()
    end
    -- /images/<name...>/json：只允许 inspect；push/load/get/tag 一律拒绝。
    if #seg >= 3 then
      local last = seg[#seg]
      if last == "json" and m == "GET" then return allow() end
      if last == "push" or last == "load" or last == "get" or last == "history" then
        return deny("IMAGE_ACTION_DENIED")
      end
    end
    return deny("IMAGE_ENDPOINT_DENIED")
  end

  return deny("ENDPOINT_DENIED")
end

-- ========== 公开 API ==========

--- 判定一次 API 请求。返回的 request 可能被改写（body 重新编码）。
--- @param req table { method, path, headers, body }
--- @param ctx table {
---   workspace_roots: string[], tier: string,
---   allow_binds?: boolean, allow_exec?: boolean, allow_attach?: boolean,
---   allow_pull?: boolean, session_netns?: boolean, registries?: table,
---   runtimes?: table, limits?: table, labels?: table,
--- }
--- @return table { allow, status?, reason?, request? }
function M.check(req, ctx)
  ctx = ctx or {}
  if type(req) ~= "table" or type(req.method) ~= "string" then
    return { allow = false, status = 400, reason = "BAD_REQUEST" }
  end
  local info, perr = http.normalize_path(req.path)
  if not info then return { allow = false, status = 400, reason = perr or "BAD_PATH" } end

  local decision = _endpoint(req, info, ctx)
  if not decision.allow then return decision end

  local seg = info.segments

  -- 镜像拉取：限制 registry / 禁止 fromSrc / 禁止私有 registry 凭据。
  if #seg == 2 and seg[1] == "images" and seg[2] == "create" then
    local q = info.query or ""
    if q:find("fromSrc=", 1, true) then
      return { allow = false, status = 403, reason = "IMAGE_FROM_SRC_DENIED" }
    end
    local from_image = q:match("[?&]fromImage=([^&]+)")
    if not from_image or from_image == "" then
      return { allow = false, status = 400, reason = "IMAGE_FROM_REQUIRED" }
    end
    from_image = from_image:gsub("%%2F", "/"):gsub("%%3A", ":")
    local reg = _registry(from_image)
    local allowed = ctx.registries or DEFAULT_REGISTRIES
    if not allowed[reg] then
      return { allow = false, status = 403, reason = "REGISTRY_DENIED:" .. reg }
    end
  end

  -- 容器创建：校验并改写 HostConfig。
  if #seg == 2 and seg[1] == "containers" and seg[2] == "create" then
    local body, berr = http.decode_json(req.body)
    if not body then return { allow = false, status = 400, reason = berr } end

    local hc = body.HostConfig
    if hc == nil then hc = {}; body.HostConfig = hc end
    if type(hc) ~= "table" then return { allow = false, status = 400, reason = "BAD_HOSTCONFIG" } end

    if hc.Privileged == true then
      return { allow = false, status = 403, reason = "PRIVILEGED_DENIED" }
    end
    hc.Privileged = false

    if type(hc.CapAdd) == "table" and #hc.CapAdd > 0 then
      return { allow = false, status = 403, reason = "CAP_ADD_DENIED" }
    end
    hc.CapAdd = {}
    hc.CapDrop = { "ALL" }

    if type(hc.VolumesFrom) == "table" and #hc.VolumesFrom > 0 then
      return { allow = false, status = 403, reason = "VOLUMES_FROM_DENIED" }
    end
    hc.VolumesFrom = {}

    if type(hc.Devices) == "table" and #hc.Devices > 0 then
      return { allow = false, status = 403, reason = "DEVICES_DENIED" }
    end
    if type(hc.DeviceRequests) == "table" and #hc.DeviceRequests > 0 then
      return { allow = false, status = 403, reason = "DEVICE_REQUESTS_DENIED" }
    end

    for _, k in ipairs({ "PidMode", "IpcMode", "UTSMode", "UsernsMode", "CgroupnsMode" }) do
      local v = hc[k]
      if type(v) == "string" and v ~= "" and v ~= "private" then
        return { allow = false, status = 403, reason = k:upper() .. "_DENIED" }
      end
    end

    local nm = type(hc.NetworkMode) == "string" and hc.NetworkMode or ""
    if nm == "" or nm == "default" or nm == "bridge" or nm == "none" then
      -- ok
    elseif nm == "host" and ctx.session_netns == true then
      -- 会话 netns 的 host 不是宿主；仍限制在会话内。
    else
      return { allow = false, status = 403, reason = "NETWORK_MODE_DENIED:" .. nm }
    end

    if type(hc.PortBindings) == "table" and next(hc.PortBindings) ~= nil then
      return { allow = false, status = 403, reason = "PORT_BINDINGS_DENIED" }
    end
    if hc.PublishAllPorts == true then
      return { allow = false, status = 403, reason = "PUBLISH_ALL_DENIED" }
    end
    -- Go 侧 PortBindings 是 map[string][]PortBinding：空 Lua table 会被编码成 []，
    -- 导致 decode 失败；清空时置 nil。
    hc.PortBindings = nil
    hc.PublishAllPorts = false

    if type(hc.ExtraHosts) == "table" and #hc.ExtraHosts > 0 then
      return { allow = false, status = 403, reason = "EXTRA_HOSTS_DENIED" }
    end

    local binds = hc.Binds
    if type(binds) == "table" and #binds > 0 then
      if ctx.allow_binds ~= true then
        return { allow = false, status = 403, reason = "BINDS_DISABLED" }
      end
      for _, spec in ipairs(binds) do
        local parsed = _parse_bind(spec)
        if not parsed then return { allow = false, status = 400, reason = "BAD_BIND" } end
        local ok, reason = _check_bind(parsed.source, parsed.target, ctx)
        if not ok then return { allow = false, status = 403, reason = reason } end
      end
    end

    local mounts = hc.Mounts
    if type(mounts) == "table" and #mounts > 0 then
      if ctx.allow_binds ~= true then
        return { allow = false, status = 403, reason = "MOUNTS_DISABLED" }
      end
      for _, mount in ipairs(mounts) do
        local ok, reason = _check_mount(mount, ctx)
        if not ok then return { allow = false, status = 403, reason = reason } end
      end
    end

    if type(hc.SecurityOpt) == "table" then
      local out = {}
      for _, opt in ipairs(hc.SecurityOpt) do
        local s = tostring(opt)
        if s:match("^no%-new%-privileges") then
          out[#out + 1] = "no-new-privileges:true"
        else
          return { allow = false, status = 403, reason = "SECURITY_OPT_DENIED:" .. s }
        end
      end
      out[#out + 1] = "no-new-privileges:true"
      hc.SecurityOpt = out
    else
      hc.SecurityOpt = { "no-new-privileges:true" }
    end

    if type(hc.Sysctls) == "table" and next(hc.Sysctls) ~= nil then
      return { allow = false, status = 403, reason = "SYSCTLS_DENIED" }
    end
    hc.Sysctls = nil

    local runtime = hc.Runtime
    local runtimes = ctx.runtimes or DEFAULT_RUNTIMES
    if type(runtime) == "string" and runtime ~= "" and not runtimes[runtime] then
      return { allow = false, status = 403, reason = "RUNTIME_DENIED:" .. runtime }
    end

    local logcfg = hc.LogConfig
    if type(logcfg) == "table" and type(logcfg.Driver) == "string" and logcfg.Driver ~= "" then
      local drv = logcfg.Driver:lower()
      if drv ~= "none" and drv ~= "json-file" and drv ~= "local" then
        return { allow = false, status = 403, reason = "LOG_DRIVER_DENIED:" .. drv }
      end
    end

    if type(hc.CgroupParent) == "string" and hc.CgroupParent ~= "" then
      return { allow = false, status = 403, reason = "CGROUP_PARENT_DENIED" }
    end

    _apply_limits(hc, ctx.limits)

    -- NetworkingConfig 只允许空/默认；自定义网络会绕过会话网络边界。
    if type(body.NetworkingConfig) == "table" then
      local eps = body.NetworkingConfig.EndpointsConfig
      if type(eps) == "table" and next(eps) ~= nil then
        return { allow = false, status = 403, reason = "NETWORKING_CONFIG_DENIED" }
      end
    end

    local merged_labels = _merge_labels(body.Labels, ctx.labels)
    body.Labels = next(merged_labels) ~= nil and merged_labels or nil

    -- 重新编码 body：下游只看到策略改写后的 HostConfig。
    req.body = vim.json.encode(body)
    req.headers = req.headers or {}
    req.headers["content-type"] = "application/json"
    req.headers["content-length"] = tostring(#req.body)
    return { allow = true, request = req }
  end

  return { allow = true, request = req }
end

--- 默认注入的容器标签。
--- @param owner string|nil
--- @param session string|nil
--- @param agent string|nil
--- @return table
function M.labels(owner, session, agent)
  return {
    ["neoai.sandbox.owner"] = tostring(owner or "unknown"),
    ["neoai.sandbox.session"] = tostring(session or ""),
    ["neoai.sandbox.agent"] = tostring(agent or ""),
    ["neoai.sandbox.managed"] = "true",
    ["neoai.sandbox.created"] = tostring(os.time()),
  }
end

M.DEFAULT_REGISTRIES = DEFAULT_REGISTRIES
M.DEFAULT_RUNTIMES = DEFAULT_RUNTIMES

return M
