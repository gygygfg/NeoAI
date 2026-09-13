--- 沙箱运行时后端
--- @module NeoAI.sandbox.runtime
--- 外部隔离后端探测与进程前缀构造。优先 bwrap，其次 unshare。
--- 关键能力缺失时返回明确错误，不静默降级（设计文档 §7.1）。
---
--- 注意：进程内工具（LSP/treesitter 等）无法经 namespace 隔离，由 wrapper 以
--- 「只读默认 + 写入暂存」约束，本模块只负责外部进程的隔离边界。

local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有状态 ==========

local state = {
  caps = nil,
}

-- ========== 私有函数 ==========

local function _executable(name)
  return vim.fn.executable(name) == 1
end

--- 探测内核/工具能力
--- @return table
local function _probe()
  local caps = {
    bwrap = _executable("bwrap"),
    unshare = _executable("unshare"),
    userns = false,
    cgroup2 = false,
    overlayfs = false,
    seccomp = false,
    checked_at = os.time(),
  }
  -- 非特权 user namespace
  local f = io.open("/proc/sys/kernel/unprivileged_userns_clone", "r")
  if f then
    local v = f:read("*a")
    f:close()
    caps.userns = v:gsub("%s", "") == "1"
  else
    caps.userns = caps.unshare
  end
  -- cgroup v2
  local cf = io.open("/sys/fs/cgroup/cgroup.controllers", "r")
  if cf then
    caps.cgroup2 = true
    cf:close()
  end
  -- overlayfs（内核支持，可通过 /proc/filesystems 粗判）
  local pf = io.open("/proc/filesystems", "r")
  if pf then
    local content = pf:read("*a") or ""
    pf:close()
    caps.overlayfs = content:find("overlay", 1, true) ~= nil
  end
  -- seccomp（内核编译支持）
  local sf = io.open("/proc/sys/kernel/seccomp/actions_avail", "r")
  if sf then
    caps.seccomp = true
    sf:close()
  end
  return caps
end

-- ========== 公开 API ==========

--- 探测并缓存能力
--- @return table
function M.probe()
  state.caps = _probe()
  return state.caps
end

--- @return table
function M.capabilities()
  if not state.caps then return M.probe() end
  return state.caps
end

--- 选择可用后端
--- @return string|nil "bwrap" | "unshare"
function M.backend()
  local caps = M.capabilities()
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.backend") or "auto"
  if cfg == "bwrap" then
    return caps.bwrap and "bwrap" or nil
  elseif cfg == "unshare" then
    return (caps.unshare and caps.userns) and "unshare" or nil
  end
  if caps.bwrap then return "bwrap" end
  if caps.unshare and caps.userns then return "unshare" end
  return nil
end

--- 构造外部进程 argv 前缀
--- @param opts table { cwd?: string, upper?: string, work?: string, fallback_cwd?: string, network?: boolean }
--- @return table|nil prefix
--- @return string|nil err
--- @return string|nil effective_cwd 隔离环境内应使用的工作目录
function M.process_prefix(opts)
  opts = opts or {}
  local backend = M.backend()
  if not backend then
    return nil, "SANDBOX_BACKEND_UNAVAILABLE: 既无 bwrap 也无可用的 unshare/userns"
  end
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox") or {}
  local offline = cfg.offline ~= false
  if backend == "bwrap" then
    local argv = {
      "bwrap", "--unshare-all", "--die-with-parent", "--new-session",
      "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
    }
    if opts.cwd then
      if opts.upper and opts.work then
        -- overlayfs：真实 cwd 作为只读 lower，写入落到私有 upper，命令看到可写工作区
        table.insert(argv, "--overlay-src"); table.insert(argv, opts.cwd)
        table.insert(argv, "--overlay"); table.insert(argv, opts.upper)
        table.insert(argv, opts.work); table.insert(argv, opts.cwd)
      end
      table.insert(argv, "--chdir")
      table.insert(argv, opts.cwd)
    end
    if not offline and opts.network then
      return nil, "SANDBOX_NETWORK_GATEWAY_UNAVAILABLE"
    end
    -- seccomp 基线：bwrap 在载荷 exec 前装载过滤器；用 shell 打开过滤器 fd 后 exec bwrap
    local seccomp = require("NeoAI.sandbox.seccomp")
    if seccomp.enabled() then
      local filter, ferr = seccomp.ensure_filter()
      if not filter then
        return nil, ferr or "SANDBOX_SECCOMP_UNAVAILABLE"
      end
      table.insert(argv, "--seccomp")
      table.insert(argv, "3")
      local wrapper = { "sh", "-c", "exec 3<'" .. filter .. "'; exec \"$@\"", "sh" }
      local full = {}
      for _, v in ipairs(wrapper) do full[#full + 1] = v end
      for _, v in ipairs(argv) do full[#full + 1] = v end
      return full, nil, opts.cwd
    end
    return argv, nil, opts.cwd
  end
  -- unshare 后端：无 overlay 支持，退化为空暂存 cwd（仍隔离 net/pid/ipc/uts/user）
  if require("NeoAI.sandbox.seccomp").enabled() then
    return nil, "SANDBOX_SECCOMP_UNAVAILABLE: unshare 后端不支持 seccomp 基线"
  end
  local argv = { "unshare", "--user", "--map-root-user", "--mount", "--pid", "--fork",
    "--ipc", "--uts", "--mount-proc" }
  if offline then
    table.insert(argv, "--net")
  elseif not opts.network then
    table.insert(argv, "--net")
  else
    return nil, "SANDBOX_NETWORK_GATEWAY_UNAVAILABLE"
  end
  return argv, nil, (opts.fallback_cwd or opts.cwd)
end

--- 判断某 effect 是否可在当前环境隔离执行
--- @return boolean ok
--- @return string|nil err
function M.check_available()
  if require("NeoAI.sandbox.fault").hit("backend") then
    return false, "SANDBOX_BACKEND_UNAVAILABLE: injected"
  end
  local backend = M.backend()
  if not backend then
    return false, "SANDBOX_BACKEND_UNAVAILABLE: 既无 bwrap 也无可用的 unshare/userns"
  end
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox") or {}
  if cfg.require_seccomp then
    local seccomp = require("NeoAI.sandbox.seccomp")
    if backend ~= "bwrap" then
      return false, "SANDBOX_SECCOMP_UNAVAILABLE: 仅 bwrap 后端支持 seccomp 基线"
    end
    if not seccomp.available() then
      return false, "SANDBOX_SECCOMP_UNAVAILABLE: 需要 seccomp 过滤器但未提供"
    end
  end
  return true
end

--- 运行外部进程（受隔离）
--- @param argv table 完整命令（未含前缀）
--- @param opts table { cwd?, timeout_ms?, signal?, network? }
--- @return Deferred resolve({ code, stdout, stderr })
function M.run(argv, opts)
  opts = opts or {}
  local prefix, err = M.process_prefix(opts)
  if not prefix then
    return async.reject({ kind = "sandbox", message = err })
  end
  local full = {}
  for _, v in ipairs(prefix) do full[#full + 1] = v end
  for _, v in ipairs(argv) do full[#full + 1] = v end

  local d = async.Deferred.new()
  local stdout, stderr = {}, {}
  local done = false
  local job
  local function settle(res)
    if done then return end
    done = true
    d:resolve(res)
  end
  if opts.signal then
    opts.signal:subscribe(function()
      if job then pcall(vim.fn.jobstop, job) end
      settle({ code = -1, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n"), aborted = true })
    end)
  end
  if opts.timeout_ms and opts.timeout_ms > 0 then
    vim.defer_fn(function()
      if done then return end
      if job then pcall(vim.fn.jobstop, job) end
      settle({ code = -1, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n"), timed_out = true })
    end, opts.timeout_ms)
  end
  job = vim.fn.jobstart(full, {
    cwd = opts.cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do stdout[#stdout + 1] = line end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do stderr[#stderr + 1] = line end
    end,
    on_exit = function(_, code)
      settle({ code = code, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n") })
    end,
  })
  if job <= 0 then
    return async.reject({ kind = "sandbox", message = "无法启动隔离进程" })
  end
  return d
end

--- 重置（测试用）
function M.reset()
  state.caps = nil
end

return M
