--- 会话内 rootless runtime 会话
--- @module 'NeoAI.sandbox.docker.session'
---
--- 会话目标：Agent 命令面与 rootless runtime 处于同一个会话 namespace；容器由 runtime 在
--- 该 namespace 内创建，退出时随 namespace 销毁，不做“拉进拉出”。
---
--- 实现分两层：
---   1) 本模块准备宿主可见的 socket 目录、broker socket、runtime boot 片段；
---   2) `sandbox/execution/resident.lua` 的常驻会话在 namespace 内执行 boot 片段，
---      启动 `podman system service`（或 rootless dockerd）并创建 runtime.sock。
---
--- 若环境不支持（无 podman/dockerd/userns），返回 nil，docker 自动不可用；绝不回退宿主 daemon。

local fs = require("NeoAI.utils.fs")
local events = require("NeoAI.kernel.events")
local probe = require("NeoAI.sandbox.docker.probe")
local broker = require("NeoAI.sandbox.docker.broker")

local M = {}

local state = {
  active = false,
  root = nil,
  socket_dir = nil,
  runtime_socket = nil,
  broker_socket = nil,
  kind = nil,
  error = nil,
  rebuild_scheduled = false,
  command_seccomp = nil,
  workspace_roots = {},
}

-- ========== 私有函数 ==========

local function _emit(name, payload)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(name, payload or {})
  end)
end

--- 生成 namespace 内启动 runtime 的 boot 片段。
--- @param kind string
--- @return string
local function _boot_script(kind)
  local lines = {
    -- 不要让 podman/dockerd 读取面向 Agent 的 DOCKER_HOST/CONTAINER_HOST；
    -- 否则 `podman system service <uri>` 会收到两个 URI（env + 位置参数）而失败。
    "unset DOCKER_HOST CONTAINER_HOST",
    "export XDG_RUNTIME_DIR=/run/neoai",
    "export XDG_DATA_HOME=/run/neoai/data",
    "export HOME=/run/neoai/home",
    "export TMPDIR=/run/neoai/tmp",
    "export STORAGE_DRIVER=vfs",
    "mkdir -p /run/neoai/data /run/neoai/home /run/neoai/tmp",
    "rm -f /run/neoai/runtime.sock",
  }
  if kind == "podman" then
    lines[#lines + 1] = "(podman system service --time=0 unix:///run/neoai/runtime.sock >/run/neoai/runtime.log 2>&1 &)"
  else
    -- rootless dockerd（若可用）；vfs + 无 iptables/bridge，网络由会话 netns 提供。
    lines[#lines + 1] = "(dockerd --host=unix:///run/neoai/runtime.sock --storage-driver=vfs --iptables=false --bridge=none --userland-proxy=false >/run/neoai/runtime.log 2>&1 &)"
  end
  lines[#lines + 1] = "for i in $(seq 1 120); do [ -S /run/neoai/runtime.sock ] && break; sleep 0.1; done"
  return table.concat(lines, "\n")
end

-- ========== 重建 ==========

local function _urlencode(s)
  return (tostring(s):gsub("([^%w%-%._~])", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function _rebuild_one(spec, cb, start)
  if type(spec) ~= "table" or not spec.spec_id then return cb(false, "BAD_SPEC") end
  if start == nil then start = spec.auto_start ~= false end
  local specs = require("NeoAI.sandbox.docker.specs")
  if specs.is_suspended(spec.spec_id) then
    return cb(false, "SUSPENDED")
  end
  local body = specs.to_create_body(spec)
  local okenc, encoded = pcall(vim.json.encode, body)
  if not okenc then return cb(false, "ENCODE_FAILED") end
  -- 重建也必须重新走当前策略（档位/路径可能变化），不能因为“历史上安全”就跳过。
  local policy = require("NeoAI.sandbox.docker.policy")
  local dec = policy.check({
    method = "POST", path = "/containers/create",
    headers = { ["content-type"] = "application/json" }, body = encoded,
  }, {
    workspace_roots = state.workspace_roots or {},
    session_netns = true,
    allow_binds = true,
    allow_exec = probe.snapshot().tier == "N2",
    allow_attach = true,
    allow_pull = true,
    labels = { ["neoai.sandbox.session"] = tostring(vim.uv.os_getpid()) },
  })
  if not dec.allow then return cb(false, "POLICY_" .. tostring(dec.reason)) end
  encoded = dec.request and dec.request.body or encoded
  local name = tostring(spec.name or ("neoai-" .. tostring(spec.spec_id):sub(1, 8)))
  local path = "/containers/create?name=" .. _urlencode(name)
  broker.request("POST", path, encoded, function(ok, status, resbody)
    if not ok or status ~= 201 then
      local suspended = specs.note_failure(spec.spec_id)
      _emit(events.SANDBOX_DOCKER_REBUILD_FAILED, { spec_id = spec.spec_id, status = status })
      if suspended then _emit(events.SANDBOX_DOCKER_REBUILD_SUSPENDED, { spec_id = spec.spec_id }) end
      return cb(false, "CREATE_FAILED")
    end
    local okdec, obj = false, nil
    if resbody then okdec, obj = pcall(vim.json.decode, resbody) end
    local id = okdec and type(obj) == "table" and obj.Id or nil
    if not id then
      specs.note_failure(spec.spec_id)
      return cb(false, "NO_CONTAINER_ID")
    end
    _emit(events.SANDBOX_DOCKER_REBUILD_STARTED, { spec_id = spec.spec_id, id = id, name = name })
    if start == false then
      -- 关闭的容器：只重建、不启动；终端打印重建命令与安全性。
      specs.print_hint(spec)
      _emit(events.SANDBOX_DOCKER_REBUILD_DONE, { spec_id = spec.spec_id, id = id, name = name, started = false })
      return cb(true, id)
    end
    broker.request("POST", "/containers/" .. _urlencode(id) .. "/start", "", function(ok2, status2)
      if not ok2 or (status2 ~= 204 and status2 ~= 304) then
        local suspended = specs.note_failure(spec.spec_id)
        _emit(events.SANDBOX_DOCKER_REBUILD_FAILED, { spec_id = spec.spec_id, status = status2 })
        if suspended then _emit(events.SANDBOX_DOCKER_REBUILD_SUSPENDED, { spec_id = spec.spec_id }) end
        return cb(false, "START_FAILED")
      end
      _emit(events.SANDBOX_DOCKER_REBUILD_DONE, { spec_id = spec.spec_id, id = id, name = name })
      cb(true, id)
    end)
  end)
end

--- 手动重建一个规格（供 `:NeoAI SandboxDocker approve` / 测试）。
--- @param spec_id string
--- @param cb function|nil
function M.rebuild_one(spec_id, cb, start)
  cb = cb or function() end
  if not state.active then return cb(false, "NO_SESSION") end
  local specs = require("NeoAI.sandbox.docker.specs")
  for _, spec in ipairs(specs.load_all()) do
    if spec.spec_id == spec_id then
      specs.approve(spec_id)
      return _rebuild_one(spec, cb, start == nil and true or start)
    end
  end
  cb(false, "NOT_FOUND")
end

--- 会话启动后重建：安全且运行中的自动；关闭/非安全的打印命令与安全性。
--- 只执行一次；等待 runtime.sock 就绪。
function M.rebuild_pending()
  if state.rebuild_scheduled or not state.active then return end
  state.rebuild_scheduled = true
  local specs = require("NeoAI.sandbox.docker.specs")
  local attempts = 0
  local function go()
    attempts = attempts + 1
    if not state.active then return end
    local st = vim.uv.fs_stat(state.runtime_socket or "")
    if not (st and st.type == "socket") then
      if attempts < 240 then vim.defer_fn(go, 250) end
      return
    end
    local function _in_workspace(spec)
      if not spec.workspace then return true end
      for _, root in ipairs(state.workspace_roots or {}) do
        local r = tostring(root or ""):gsub("/+$", "")
        local w = tostring(spec.workspace):gsub("/+$", "")
        if r ~= "" and (w == r or w:sub(1, #r + 1) == r .. "/") then return true end
      end
      return false
    end
    for _, spec in ipairs(specs.load_all()) do
      if not _in_workspace(spec) then
        -- 其它工作区的规格不在此会话重建（避免跨项目误建容器）。
      elseif spec.mode == "auto" then
        _rebuild_one(spec, function(ok, reason)
          if not ok then
            pcall(vim.notify, ("[NeoAI] 容器 %s 自动重建失败：%s"):format(tostring(spec.name), tostring(reason)),
              vim.log.levels.WARN)
          end
        end, spec.auto_start == true)
      else
        specs.print_hint(spec)
        _emit(events.SANDBOX_DOCKER_REBUILD_QUEUED, { spec_id = spec.spec_id, mode = spec.mode })
      end
    end
  end
  vim.defer_fn(go, 250)
end

-- ========== 公开 API ==========

--- 准备当前进程的会话 runtime（幂等）。
--- @param opts table|nil { root?: string }
--- @return table|nil descriptor { socket_dir, runtime_socket, broker_socket, kind, boot }
--- @return string|nil err
function M.prepare(opts)
  opts = opts or {}
  local snap = probe.snapshot()
  if snap.tier == "N0" or not snap.runtime then
    state.error = "NO_SESSION_RUNTIME"
    return nil, state.error
  end

  local root = opts.root
  if not root or root == "" then
    local okstore, store = pcall(require, "NeoAI.sandbox.state.store")
    local base = okstore and store and type(store.root) == "function" and store.root() or nil
    root = (base or ((vim.fn.stdpath("cache") or vim.fn.tempname()) .. "/NeoAI/sandbox"))
      .. "/docker/session"
  end
  local socket_dir = root .. "/sockets"
  fs.ensure_dir(socket_dir)
  pcall(vim.uv.fs_chmod, root, 448) -- 0700
  pcall(vim.uv.fs_chmod, socket_dir, 448)

  local runtime_socket = socket_dir .. "/runtime.sock"
  local broker_socket = socket_dir .. "/broker.sock"
  -- per-command seccomp：runtime 本身不能带基线（需要 mount/unshare），但 Agent 命令必须带。
  -- 把过滤器放进会话 socket 目录，resident 命令服务器用 setpriv 对每条 Agent 命令施加。
  local command_seccomp = nil
  pcall(function()
    local sec = require("NeoAI.sandbox.execution.seccomp")
    local filter = sec.ensure_filter()
    if filter then
      local dst = socket_dir .. "/seccomp.bpf"
      local raw = fs.read_file(filter)
      if raw then
        fs.write_file(dst, raw)
        command_seccomp = "/run/neoai/seccomp.bpf"
      end
    end
  end)
  local labels = vim.deepcopy(opts.labels or {})
  labels["neoai.sandbox.owner"] = labels["neoai.sandbox.owner"] or tostring(vim.env.USER or "unknown")
  labels["neoai.sandbox.session"] = labels["neoai.sandbox.session"] or tostring(vim.uv.os_getpid())
  labels["neoai.sandbox.agent"] = labels["neoai.sandbox.agent"] or ""

  local ok, err = broker.ensure({
    socket_path = broker_socket,
    upstream_path = runtime_socket,
    workspace_roots = opts.workspace_roots or {},
    session_netns = true,
    allow_binds = opts.allow_binds == true,
    allow_exec = opts.allow_exec == true or snap.tier == "N2",
    allow_attach = opts.allow_attach ~= false,
    allow_pull = opts.allow_pull ~= false,
    labels = labels,
    limits = opts.limits or {},
    monitor = true,
  })
  if not ok then
    state.error = err or "BROKER_READY_FAILED"
    return nil, state.error
  end

  state.active = true
  state.root = root
  state.socket_dir = socket_dir
  state.runtime_socket = runtime_socket
  state.broker_socket = broker_socket
  state.kind = snap.runtime
  state.command_seccomp = command_seccomp
  state.workspace_roots = vim.deepcopy(opts.workspace_roots or {})
  state.error = nil
  -- 规格重建在 runtime.sock 就绪后执行（不阻塞命令启动）。
  pcall(M.rebuild_pending)
  return {
    socket_dir = socket_dir,
    runtime_socket = runtime_socket,
    broker_socket = broker_socket,
    kind = snap.runtime,
    boot = _boot_script(snap.runtime),
    command_seccomp = command_seccomp,
  }
end

--- 是否已准备。
--- @return boolean
function M.active()
  return state.active == true
end

--- 当前描述符（未准备返回 nil）。
--- @return table|nil
function M.descriptor()
  if not state.active then return nil end
  return {
    socket_dir = state.socket_dir,
    runtime_socket = state.runtime_socket,
    broker_socket = state.broker_socket,
    kind = state.kind,
    boot = _boot_script(state.kind),
    command_seccomp = state.command_seccomp,
  }
end

--- 将会话 runtime 挂载/boot 描述应用到权限档位（原地修改）。
--- @param priv table
--- @param desc table
function M.apply(priv, desc)
  if type(priv) ~= "table" or type(desc) ~= "table" then return end
  priv.docker_session = true
  priv.container = true
  priv.seccomp = false
  priv.network = true
  priv.boot = desc.boot
  priv.command_seccomp = desc.command_seccomp
  -- 非 root 启动时由 RootlessKit 映射 subuid；Agent 命令用专用 uid 运行，broker 才是硬隔离。
  -- root 启动的 bwrap 单映射无法 setuid 到未映射 uid，保持 userns root（档位会标注）。
  if vim.uv.getuid() ~= 0 then
    priv.command_uid = 1000
    priv.rootless_session = true
  end
  priv.cap_add = priv.cap_add or {}
  if not vim.tbl_contains(priv.cap_add, "ALL") then
    priv.cap_add[#priv.cap_add + 1] = "ALL"
  end
  priv.mounts = priv.mounts or {}
  priv.mounts[#priv.mounts + 1] = { src = desc.socket_dir, dst = "/run/neoai", mode = "rw" }
  priv.env = priv.env or {}
  priv.env.DOCKER_HOST = "unix:///run/docker.sock"
  priv.env.CONTAINER_HOST = "unix:///run/docker.sock"
  priv.env.XDG_RUNTIME_DIR = "/run/neoai"
  priv.env.STORAGE_DRIVER = "vfs"
  priv.mounts[#priv.mounts + 1] = { src = desc.broker_socket, dst = "/run/docker.sock", mode = "rw" }
  priv.unmask = priv.unmask or {}
  for _, p in ipairs({ "/run/docker.sock", "/var/run/docker.sock", "/run/neoai" }) do
    if not vim.tbl_contains(priv.unmask, p) then
      priv.unmask[#priv.unmask + 1] = p
    end
  end
end

--- 停止会话 runtime / broker。
function M.stop()
  pcall(broker.stop)
  if state.root then pcall(vim.fn.delete, state.root, "rf") end
  state.active = false
  state.root = nil
  state.socket_dir = nil
  state.runtime_socket = nil
  state.broker_socket = nil
  state.kind = nil
  state.rebuild_scheduled = false
  state.command_seccomp = nil
  state.workspace_roots = {}
end

--- 状态。
--- @return table
function M.status()
  return {
    active = state.active,
    kind = state.kind,
    socket_dir = state.socket_dir,
    runtime_socket = state.runtime_socket,
    broker_socket = state.broker_socket,
    error = state.error,
    tier = probe.tier(),
    broker = broker.status(),
  }
end

--- 测试/热重载。
function M.reset()
  M.stop()
  state.error = nil
end

return M
