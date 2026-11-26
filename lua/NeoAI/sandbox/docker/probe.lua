--- 会话内 Docker 运行基底自动探测
--- @module 'NeoAI.sandbox.docker.probe'
---
--- 本模块只做**只读能力探测**：不连接宿主 docker daemon，不创建 socket，不启动进程。
--- 目标是根据当前机器实际能力自动选择最高安全档位：
---   * N0 = 没有可用的会话内 rootless runtime（docker API 不可用，podman 仍可在沙箱内直用）
---   * N1 = 当前 userns 内可启动 rootless podman / rootless dockerd
---   * N2 = N1 + microVM（Kata/Firecracker/QEMU/KVM）或 gVisor（更强/不同的内核边界）
---
--- 永不把宿主 dockerd 当作档位：把真 docker.sock 暴露给 Agent 等价宿主 root，
--- 且容器由宿主 daemon 在会话 namespace 之外创建，无法满足“容器天然在沙箱 ns 内”。
---
--- 探测结果缓存（默认 30s）；测试可经 `_set_override` 注入确定快照。

local M = {}

local CACHE_MS = 30000

local state = {
  cached = nil,
  cached_at = 0,
  override = nil,
}

-- ========== 私有函数 ==========

--- 可执行文件是否存在（不执行）
--- @param name string
--- @return boolean
local function _exe(name)
  return vim.fn.executable(name) == 1
end

--- 读取小文件（失败返回 nil）
--- @param path string
--- @return string|nil
local function _read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, data = pcall(f.read, f, "*a")
  f:close()
  if not ok or type(data) ~= "string" then return nil end
  return data
end

--- 判断虚拟化/隔离基底。只读取可稳定获得的文件，不依赖外部命令。
--- @return table { virt: string|nil, microvm: boolean, gvisor: boolean }
local function _virt()
  local hay = table.concat({
    _read("/proc/1/cgroup") or "",
    _read("/proc/version") or "",
    _read("/sys/class/dmi/id/product_name") or "",
    _read("/sys/class/dmi/id/sys_vendor") or "",
    _read("/run/systemd/container") or "",
  }, "\n"):lower()

  local function has(s) return hay:find(s, 1, true) ~= nil end

  -- gVisor：/proc/version 通常是 "gVisor"；runsc 的 sentry 也可能写入 cgroup。
  if has("gvisor") or has("runsc") then
    return { virt = "gvisor", microvm = false, gvisor = true }
  end
  -- Kata / Firecracker / Cloud Hypervisor / 常见 KVM 虚拟机。
  for _, name in ipairs({ "kata", "firecracker", "cloud-hypervisor", "cloud_hypervisor", "qemu", "kvm", "bhyve", "xen" }) do
    if has(name) then
      return { virt = name, microvm = true, gvisor = false }
    end
  end
  return { virt = nil, microvm = false, gvisor = false }
end

--- 非特权 userns 是否可用（读 sysctl；无法判定时按可用处理，由真正启动失败兜底）
--- @return boolean
local function _userns()
  local v = _read("/proc/sys/kernel/unprivileged_userns_clone")
  if v then
    return v:gsub("%s", "") ~= "0"
  end
  local a = _read("/proc/sys/kernel/apparmor_restrict_unprivileged_userns")
  if a then
    return a:gsub("%s", "") == "0"
  end
  return true
end

--- 组装一次完整探测快照
--- @return table
local function _snapshot()
  local virt = _virt()
  local has_podman = _exe("podman")
  local has_dockerd = _exe("dockerd") or _exe("dockerd-rootless.sh")
  local has_rootlesskit = _exe("rootlesskit")
  local has_uidmap = (_exe("newuidmap") and _exe("newgidmap")) or _exe("podman")
  local has_slirp = _exe("slirp4netns") or _exe("passt") or _exe("pasta")
  local userns = _userns()

  -- podman 无守护进程，rootless 只需 userns；dockerd 需要 rootlesskit + uidmap。
  local rootless_ok = userns and (
    has_podman or (has_dockerd and has_rootlesskit and has_uidmap)
  )
  local runtime_kind = nil
  if userns and has_podman then
    runtime_kind = "podman"
  elseif rootless_ok and has_dockerd then
    runtime_kind = "dockerd"
  end

  local tier = "N0"
  local reasons = {}
  if runtime_kind then
    tier = (virt.microvm or virt.gvisor) and "N2" or "N1"
  else
    reasons[#reasons + 1] = not userns and "USERNS_UNAVAILABLE" or "NO_ROOTLESS_RUNTIME"
  end

  return {
    tier = tier,
    runtime = runtime_kind,
    userns = userns,
    rootless = runtime_kind ~= nil,
    microvm = virt.microvm,
    gvisor = virt.gvisor,
    virt = virt.virt,
    bwrap = _exe("bwrap"),
    podman = has_podman,
    dockerd = has_dockerd,
    rootlesskit = has_rootlesskit,
    uidmap = _exe("newuidmap") and _exe("newgidmap"),
    slirp = has_slirp,
    setpriv = _exe("setpriv"),
    seccomp_filter = _exe("setpriv"),
    cgroup2 = (function()
      local ok, st = pcall(vim.uv.fs_stat, "/sys/fs/cgroup/cgroup.controllers")
      return ok and st ~= nil
    end)(),
    reasons = reasons,
    at = os.time(),
  }
end

-- ========== 公开 API ==========

--- 取得探测快照（带缓存；override 优先）。
--- @param opts table|nil { refresh: boolean }
--- @return table
function M.snapshot(opts)
  if state.override then return vim.deepcopy(state.override) end
  local now = vim.uv.now()
  if not (opts and opts.refresh) and state.cached and (now - state.cached_at) < CACHE_MS then
    return vim.deepcopy(state.cached)
  end
  local snap = _snapshot()
  state.cached = snap
  state.cached_at = now
  return vim.deepcopy(snap)
end

--- 当前自动档位（N0|N1|N2）。
--- @return string
function M.tier()
  return M.snapshot().tier
end

--- 是否存在可用的会话内 runtime。
--- @return boolean
function M.available()
  return M.tier() ~= "N0"
end

--- 只读状态摘要（供 :NeoAI SandboxCaps / Doctor / SandboxDocker 使用）。
--- @param snap table|nil
--- @return table
function M.status(snap)
  snap = snap or M.snapshot()
  return {
    tier = snap.tier,
    runtime = snap.runtime,
    userns = snap.userns,
    rootless = snap.rootless,
    microvm = snap.microvm,
    gvisor = snap.gvisor,
    virt = snap.virt,
    bwrap = snap.bwrap,
    podman = snap.podman,
    dockerd = snap.dockerd,
    rootlesskit = snap.rootlesskit,
    uidmap = snap.uidmap,
    slirp = snap.slirp,
    setpriv = snap.setpriv,
    cgroup2 = snap.cgroup2,
    reasons = snap.reasons,
  }
end

--- 测试钩子：注入固定快照（传 nil 清除）。
--- @param snap table|nil
function M._set_override(snap)
  state.override = snap and vim.deepcopy(snap) or nil
  state.cached = nil
  state.cached_at = 0
end

--- 清空缓存（测试/热重载）。
function M.reset()
  state.cached = nil
  state.cached_at = 0
end

return M
