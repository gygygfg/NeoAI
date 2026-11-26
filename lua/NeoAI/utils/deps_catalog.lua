--- 可选安全依赖目录（纯数据 + 只读探测）
--- @module 'NeoAI.utils.deps_catalog'
---
--- 供 `:NeoAI Deps` 与沙箱诊断共用：依赖 id、二进制、各发行版包名、作用、安装 argv。
--- 不执行安装；不读业务状态。

local M = {}

local state = {
  pm_override = nil,
}

local CATALOG = {
  {
    id = "bubblewrap", group = "会话隔离", label = "bubblewrap",
    bins = { "bwrap" },
    packages = { apt = "bubblewrap", dnf = "bubblewrap", pacman = "bubblewrap", apk = "bubblewrap", zypper = "bubblewrap", pkg = "bubblewrap" },
    why = "提供 mount/pid/net 命名空间与 overlay 暂存；缺失时沙箱会降级或不可用。",
    tier_hint = "N1",
  },
  {
    id = "util-linux", group = "会话隔离", label = "util-linux（unshare/setpriv）",
    bins = { "unshare", "setpriv" },
    packages = { apt = "util-linux", dnf = "util-linux", pacman = "util-linux", apk = "util-linux", zypper = "util-linux", pkg = "util-linux" },
    why = "无 bwrap 时的隔离后端；setpriv 用于 per-command seccomp 与降权。",
    tier_hint = "N1",
  },
  {
    id = "rootlesskit", group = "Rootless runtime", label = "rootlesskit",
    bins = { "rootlesskit" },
    packages = { apt = "rootlesskit", dnf = "rootlesskit", pacman = "rootlesskit", apk = "rootlesskit", zypper = "rootlesskit" },
    why = "在非 root 用户下建立 userns+mount+net 会话；rootless dockerd 需要。",
    tier_hint = "N1",
  },
  {
    id = "uidmap", group = "Rootless runtime", label = "uidmap（newuidmap/newgidmap）",
    bins = { "newuidmap", "newgidmap" },
    packages = { apt = "uidmap", dnf = "shadow-utils", pacman = "shadow", apk = "shadow", zypper = "shadow" },
    why = "为会话 userns 映射 root/agent 的 subuid/subgid，支持非 root Agent uid。",
    tier_hint = "N1",
  },
  {
    id = "slirp4netns", group = "Rootless runtime", label = "slirp4netns / passt",
    bins = { "slirp4netns", "passt", "pasta" },
    packages = { apt = "slirp4netns", dnf = "slirp4netns", pacman = "slirp4netns", apk = "slirp4netns", zypper = "slirp4netns" },
    why = "rootless 会话网络；缺失时 rootless runtime 只能使用 host 网络。",
    tier_hint = "N1",
  },
  {
    id = "socat", group = "网络隔离", label = "socat",
    bins = { "socat" },
    packages = { apt = "socat", dnf = "socat", pacman = "socat", apk = "socat", zypper = "socat" },
    why = "私有 netns 代理桥（沙箱内 TCP→Unix socket，宿主 Unix→TCP）。缺失时按 isolation_fail_closed 断网。",
    tier_hint = "N1",
  },
  {
    id = "iproute2", group = "网络隔离", label = "iproute2（ip）",
    bins = { "ip" },
    packages = { apt = "iproute2", dnf = "iproute", pacman = "iproute2", apk = "iproute2", zypper = "iproute2" },
    why = "root 模式创建/清理隔离 netns 并拉起 lo。",
    tier_hint = "N1",
  },
  {
    id = "podman", group = "无守护进程容器", label = "podman",
    bins = { "podman" },
    packages = { apt = "podman", dnf = "podman", pacman = "podman", apk = "podman", zypper = "podman" },
    why = "会话内 rootless runtime（podman system service 提供 Docker 兼容 API）。",
    tier_hint = "N1",
  },
  {
    id = "buildah", group = "无守护进程容器", label = "buildah",
    bins = { "buildah" },
    packages = { apt = "buildah", dnf = "buildah", pacman = "buildah", apk = "buildah", zypper = "buildah" },
    why = "可选：镜像构建/无守护进程工作流。",
    tier_hint = "N1",
  },
  {
    id = "fuse-overlayfs", group = "无守护进程容器", label = "fuse-overlayfs",
    bins = { "fuse-overlayfs" },
    packages = { apt = "fuse-overlayfs", dnf = "fuse-overlayfs", pacman = "fuse-overlayfs", apk = "fuse-overlayfs", zypper = "fuse-overlayfs" },
    why = "rootless overlay graph driver / overlay 兜底；缺失时退化为 vfs。",
    tier_hint = "N1",
  },
  {
    id = "strace", group = "观测与兜底", label = "strace",
    bins = { "strace" },
    packages = { apt = "strace", dnf = "strace", pacman = "strace", apk = "strace", zypper = "strace" },
    why = "行为观测兜底；缺失时只用 eBPF/procfs。",
    tier_hint = "N0",
  },
  {
    id = "bpftrace", group = "观测与兜底", label = "bpftrace",
    bins = { "bpftrace" },
    packages = { apt = "bpftrace", dnf = "bpftrace", pacman = "bpftrace", apk = "bpftrace", zypper = "bpftrace" },
    why = "eBPF 行为兜底（危险 syscall 命中后 cgroup.kill）。",
    tier_hint = "N0",
  },
  {
    id = "kata", group = "强隔离（手动）", label = "Kata Containers",
    bins = { "kata-runtime", "kata-qemu" }, manual = true,
    why = "microVM 基底：容器在 guest kernel 内，宿主 ns 不参与。请按发行版/官方文档安装。",
    tier_hint = "N2",
  },
  {
    id = "gvisor", group = "强隔离（手动）", label = "gVisor runsc",
    bins = { "runsc" }, manual = true,
    why = "用户态 Sentry 基底：runsc 维护自己的 ns 视图，Docker 只负责生命周期。",
    tier_hint = "N2",
  },
}

-- ========== 私有函数 ==========

local function _read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, data = pcall(f.read, f, "*a")
  f:close()
  if not ok then return nil end
  return data
end

--- 解析 OS ID
local function _os_id()
  local text = _read("/etc/os-release") or ""
  local vals = {}
  for k, v in text:gmatch("([%w_]+)=\"?([^\n\"]*)") do vals[k] = v end
  return ((vals.ID or "") .. " " .. (vals.ID_LIKE or "")):lower()
end

-- ========== 公开 API ==========

--- 依赖列表（深拷贝）。
--- @return table[]
function M.list()
  return vim.deepcopy(CATALOG)
end

--- 当前包管理器：apt/dnf/pacman/apk/zypper/pkg/generic
--- @return string
function M.pkg_manager()
  if state.pm_override then return state.pm_override end
  if type(vim.env.PREFIX) == "string" and vim.env.PREFIX:find("com.termux", 1, true) then
    return "pkg"
  end
  local id = _os_id()
  if id:find("debian", 1, true) or id:find("ubuntu", 1, true) then return "apt" end
  if id:find("fedora", 1, true) or id:find("rhel", 1, true) or id:find("centos", 1, true) then return "dnf" end
  if id:find("arch", 1, true) or id:find("manjaro", 1, true) then return "pacman" end
  if id:find("alpine", 1, true) then return "apk" end
  if id:find("suse", 1, true) then return "zypper" end
  for _, pm in ipairs({ "apt", "dnf", "pacman", "apk", "pkg", "zypper" }) do
    if vim.fn.executable(pm) == 1 then return pm end
  end
  return "generic"
end

--- 测试钩子
--- @param pm string|nil
function M._set_pkg_manager(pm)
  state.pm_override = pm
end

--- 依赖状态。
--- @param dep table
--- @return table { installed: boolean, missing_bins: string[] }
function M.dep_status(dep)
  local missing = {}
  for _, bin in ipairs(dep.bins or {}) do
    if vim.fn.executable(bin) ~= 1 then missing[#missing + 1] = bin end
  end
  return { installed = #missing == 0, missing_bins = missing }
end

--- 全部状态。
--- @return table[]
function M.status()
  local out = {}
  for _, dep in ipairs(CATALOG) do
    local st = M.dep_status(dep)
    out[#out + 1] = vim.tbl_extend("force", vim.deepcopy(dep), {
      installed = st.installed,
      missing_bins = st.missing_bins,
    })
  end
  return out
end

--- 生成安装计划（argv 数组；不经过 shell）。
--- @param ids string[]
--- @param opts table|nil { interactive?: boolean }
--- @return table|nil { argv: string[], packages: string[], pm: string, needs_sudo: boolean, interactive: boolean, manual: string[] }
--- @return string|nil err
function M.plan(ids, opts)
  opts = opts or {}
  local pm = M.pkg_manager()
  if pm == "generic" then return nil, "NO_PACKAGE_MANAGER" end
  local by_id = {}
  for _, dep in ipairs(CATALOG) do by_id[dep.id] = dep end
  local packages, manual = {}, {}
  for _, id in ipairs(ids or {}) do
    local dep = by_id[id]
    if not dep then return nil, "UNKNOWN_DEP:" .. tostring(id) end
    if dep.manual then
      manual[#manual + 1] = dep.label
    else
      local pkg = (dep.packages or {})[pm]
      if not pkg then return nil, "NO_PACKAGE_FOR:" .. tostring(id) .. ":" .. pm end
      packages[#packages + 1] = pkg
    end
  end
  if #packages == 0 and #manual > 0 then
    return nil, "MANUAL_ONLY:" .. table.concat(manual, ",")
  end

  local argv = {}
  if pm == "apt" then
    argv = { "apt", "install", "-y" }
  elseif pm == "dnf" then
    argv = { "dnf", "install", "-y" }
  elseif pm == "pacman" then
    argv = { "pacman", "-S", "--needed", "--noconfirm" }
  elseif pm == "apk" then
    argv = { "apk", "add" }
  elseif pm == "zypper" then
    argv = { "zypper", "--non-interactive", "install" }
  elseif pm == "pkg" then
    argv = { "pkg", "install", "-y" }
  else
    return nil, "NO_PACKAGE_MANAGER"
  end
  for _, p in ipairs(packages) do argv[#argv + 1] = p end

  local needs_sudo = false
  local interactive = false
  if vim.uv.getuid() ~= 0 then
    needs_sudo = true
    local ok = pcall(function()
      return vim.fn.system({ "sudo", "-n", "true" }) ~= nil and vim.v.shell_error == 0
    end)
    if not (ok and vim.v.shell_error == 0) then
      interactive = true
    end
    local full = { "sudo" }
    if not interactive then full[#full + 1] = "-n" end
    for _, v in ipairs(argv) do full[#full + 1] = v end
    argv = full
  end
  return {
    argv = argv,
    packages = packages,
    pm = pm,
    needs_sudo = needs_sudo,
    interactive = interactive,
    manual = manual,
  }, nil
end

--- 人类可读命令（展示用；执行仍用 argv）。
--- @param plan table
--- @return string
function M.command_string(plan)
  local out = {}
  for _, v in ipairs(plan.argv or {}) do out[#out + 1] = vim.fn.shellescape(v) end
  return table.concat(out, " ")
end

--- 重置测试钩子。
function M.reset()
  state.pm_override = nil
end

return M
