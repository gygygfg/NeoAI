--- 沙箱资源域（cgroup v2）
--- @module NeoAI.sandbox.cgroup
--- 每次尝试使用独立 cgroup v2 资源域，限制内存/PID/CPU（设计文档 §7.1）。
--- 能力缺失时返回明确错误，不静默降级；limits 全为 0 时不创建。
--- 控制器按 `cgroup.controllers` 实际可用集合逐项启用：缺失或写入失败的限制记入
--- `handle.unavailable` 并经 `M.applied(handle)` 暴露，避免把「意图」当作「已生效」。

local M = {}

-- 共享父域名称：所有并发沙箱任务挂在同一父域下，父域持有全局 CPU 预算，
-- 子域持有单任务配额，从而保证「并发任务 CPU 配额之和」不超过宿主可用核数。
local PARENT_NAME = "neoai"

-- ========== 私有状态 ==========

local state = {
  caps = nil,
  handles = {}, -- attempt_id -> handle
}

-- ========== 私有函数 ==========

local function _base()
  return require("NeoAI.kernel.config_store").get("tools.sandbox.limits.cgroup_base") or "/sys/fs/cgroup"
end

local function _write_file(path, content)
  local f = io.open(path, "w")
  if not f then return false end
  local ok = f:write(content)
  f:close()
  -- f:write 成功返回 file handle，失败返回 nil+err；必须校验，否则 EINVAL/EBUSY 被吞掉。
  return ok ~= nil
end

--- 控制器可用集合（来自 cgroup.controllers）。
--- @param caps table
--- @return table<string, boolean>
local function _controller_set(caps)
  local set = {}
  for _, c in ipairs((caps and caps.controllers) or {}) do set[c] = true end
  return set
end

--- 资源域实际生效的限制（供诊断：区分「意图」与「内核已应用」）。
--- @param handle table
--- @return table { memory?, pids?, cpu? } 各键为 boolean（true=已写入成功）
function M.applied(handle)
  return (handle and handle.applied) or {}
end

--- 因控制器不可用/写入失败而未生效的限制名列表。
--- @param handle table
--- @return table 字符串数组
function M.unavailable(handle)
  return (handle and handle.unavailable) or {}
end

local function _read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local v = f:read("*a")
  f:close()
  return v
end

local function _safe_id(id)
  return tostring(id):gsub("[^%w_%-]", "_")
end

--- 诊断配置（默认关）。开启后仅在 logger 记录，不改变行为。
--- @return table
local function _diag()
  return require("NeoAI.kernel.config_store").get("tools.sandbox.diagnostics") or {}
end

--- 读取资源域的 memory/pids 事件计数（用于 OOM / 进程终止归因）。
--- @param path string 资源域目录
--- @return table { memory_events?, pids_events?, memory_peak?, memory_max?, pids_max? }
function M.events_snapshot(path)
  if type(path) ~= "string" or path == "" then return {} end
  local out = {}
  local files = {
    memory_events = "memory.events",
    pids_events = "pids.events",
    memory_peak = "memory.peak",
    memory_max = "memory.max",
    pids_max = "pids.max",
    cpu_max = "cpu.max",
  }
  for key, name in pairs(files) do
    local raw = _read_file(path .. "/" .. name)
    if raw then out[key] = (raw:gsub("%s+$", "")) end
  end
  return out
end

--- 是否为「疑似 OOM 终止」：资源域 memory.events 出现 oom_kill/oom_group_kill > 0。
--- @param snap table M.events_snapshot 结果
--- @return boolean
function M.snapshot_oom(snap)
  local ev = snap and snap.memory_events or ""
  for _, k in ipairs({ "oom_kill", "oom_group_kill" }) do
    local n = tonumber(ev:match(k .. "%s+(%d+)"))
    if n and n > 0 then return true end
  end
  return false
end

--- 从 memory.events 文本累加 oom_kill/oom_group_kill 计数。
--- @param ev string|nil
--- @return number
local function _oom_count(ev)
  if type(ev) ~= "string" then return 0 end
  local total = 0
  for _, k in ipairs({ "oom_kill", "oom_group_kill" }) do
    local n = tonumber(ev:match(k .. "%s+(%d+)"))
    if n then total = total + n end
  end
  return total
end

--- 从资源域目录向上构造到 cgroup 根的链（含子域与根）。
--- @param path string
--- @param base string
--- @return table
local function _cgroup_chain(path, base)
  local chain = {}
  local p = tostring(path or ""):gsub("/+$", "")
  while p ~= "" and #chain < 64 do
    chain[#chain + 1] = p
    if p == base then break end
    local parent = p:match("^(.*)/[^/]+$")
    if not parent or parent == "" or parent == p then break end
    p = parent
  end
  return chain
end

--- 采集资源域及其祖先（父域/容器根）的 OOM 计数基线。
--- 用于命令结束后做差分，避免把「命令开始前已存在的祖先 OOM 计数」误判为本次 OOM。
--- @param path string 子域目录
--- @param opts table|nil { base?, reader? }
--- @return table map[dir] = count
function M.oom_baseline(path, opts)
  opts = opts or {}
  local base = (opts.base or _base()):gsub("/+$", "")
  local read = opts.reader or _read_file
  local out = {}
  for _, dir in ipairs(_cgroup_chain(path, base)) do
    out[dir] = _oom_count(read(dir .. "/memory.events"))
  end
  return out
end

--- 归因 OOM：沿子域 → 父域 → 容器根查 memory.events 的 oom_kill 增量。
--- 子域优先（命令自身的资源域）；子域无记录时再看祖先（容器/宿主 OOM）。
--- @param path string 子域目录
--- @param opts table|nil { baseline?, base?, reader? }
--- @return table { oom=boolean, level?, path?, oom_kill? }
function M.oom_attribution(path, opts)
  opts = opts or {}
  if type(path) ~= "string" or path == "" then return { oom = false } end
  local base = (opts.base or _base()):gsub("/+$", "")
  local read = opts.reader or _read_file
  local baseline = opts.baseline or {}
  local chain = _cgroup_chain(path, base)
  for i, dir in ipairs(chain) do
    local ev = read(dir .. "/memory.events")
    if ev then
      local n = _oom_count(ev)
      local b = tonumber(baseline[dir]) or 0
      if n > b then
        return {
          oom = true,
          level = (i == 1) and "sandbox" or "ancestor",
          path = dir,
          oom_kill = n - b,
        }
      end
    end
  end
  return { oom = false }
end

--- 共享父域路径（承载全局 CPU 预算）
--- @return string
local function _parent_path()
  return _base() .. "/" .. PARENT_NAME
end

--- 宿主逻辑 CPU 数（用于动态 CPU 配额）
--- @return number
local function _nproc()
  local ok, cpus = pcall(vim.uv.cpus)
  if ok and type(cpus) == "table" and #cpus > 0 then return #cpus end
  local raw = vim.fn.system("nproc 2>/dev/null") or ""
  local n = tonumber((raw:gsub("%s+$", "")))
  return (n and n > 0) and n or 1
end

--- 宿主物理内存总量（字节；读取 /proc/meminfo）
--- @return number
local function _mem_total_bytes()
  local f = io.open("/proc/meminfo", "r")
  if not f then return 0 end
  local total = 0
  for line in f:lines() do
    local kb = line:match("^MemTotal:%s*(%d+)%s*kB")
    if kb then total = tonumber(kb) * 1024 break end
  end
  f:close()
  return total or 0
end

--- 当前进程所在 cgroup v2 路径（相对 cgroup 根，如 "/docker/abc"）。无法解析返回 nil。
--- 容器内 `/proc/meminfo` 的 MemTotal 通常是**宿主**总量，故需据此向上找容器实际配额。
--- @return string|nil
local function _self_cgroup_path()
  local f = io.open("/proc/self/cgroup", "r")
  if not f then return nil end
  local out = nil
  for line in f:lines() do
    -- cgroup v2 统一层级： "0::/path"
    local p = line:match("^0::(.*)$")
    if p then out = p break end
  end
  f:close()
  return out
end

--- 容器/宿主 cgroup 实际可用配额：沿当前 cgroup 向上找最近的有限 memory.max / cpu.max。
--- 宿主直接运行（cgroup 无限制）时返回 {}。用于避免在容器内按宿主资源高估限额。
--- @param opts table|nil { rel?, base?, reader? }（测试注入用；缺省读真实 /proc 与 cgroup）
--- @return table { memory_bytes?, cpu_cores? }
local function _cgroup_quota(opts)
  opts = opts or {}
  local rel = opts.rel
  if rel == nil then rel = _self_cgroup_path() end
  if not rel then return {} end
  local base = (opts.base or _base()):gsub("/+$", "")
  local read = opts.reader or _read_file
  local p = rel:gsub("/+$", "")
  -- 构造从当前 cgroup 到根的路径链（含根）。
  local chain = {}
  while true do
    chain[#chain + 1] = (p == "" or p == "/") and base or (base .. p)
    if p == "" or p == "/" then break end
    p = p:match("^(.*)/[^/]+$") or ""
    p = p:gsub("/+$", "")
  end
  local out = {}
  for _, dir in ipairs(chain) do
    if out.memory_bytes == nil then
      local raw = read(dir .. "/memory.max")
      if raw then
        local v = raw:gsub("%s+$", "")
        if v ~= "max" then
          local n = tonumber(v)
          if n and n > 0 then out.memory_bytes = n end
        end
      end
    end
    if out.cpu_cores == nil then
      local raw = read(dir .. "/cpu.max")
      if raw then
        local quota, period = raw:match("^(%S+)%s+(%d+)")
        if quota and quota ~= "max" then
          local q, pr = tonumber(quota), tonumber(period)
          if q and pr and pr > 0 then out.cpu_cores = math.max(1, math.floor(q / pr)) end
        end
      end
    end
    if out.memory_bytes and out.cpu_cores then break end
  end
  return out
end

--- 解析实际生效的资源限制：静态显式值优先，未设置时按宿主资源动态推导。
--- @return table { memory_bytes, pids, cpu_max }
function M.resolve_limits()
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.limits") or {}
  local out = {
    memory_bytes = tonumber(cfg.memory_bytes) or 0,
    pids = tonumber(cfg.pids) or 0,
    cpu_max = tonumber(cfg.cpu_max) or 0,
  }
  if cfg.dynamic == false then return out end
  -- 容器/宿主 cgroup 实际配额：容器内 /proc/meminfo 与 nproc 常反映宿主资源，
  -- 故限额须再与容器实际可用取 min，避免 memory.max 设得比容器还高（形同虚设、
  -- OOM 由外层容器触发而子域 memory.events 无记录）。
  local quota = _cgroup_quota()
  -- 动态：内存取宿主总量的比例（受 memory_max_bytes 上限约束），且不超容器配额
  if out.memory_bytes <= 0 then
    local total = _mem_total_bytes()
    local ratio = tonumber(cfg.memory_ratio) or 0.5
    local mb = math.floor(total * ratio)
    local cap = tonumber(cfg.memory_max_bytes) or 0
    if cap > 0 and (mb <= 0 or mb > cap) then mb = cap end
    if quota.memory_bytes and (mb <= 0 or quota.memory_bytes < mb) then mb = quota.memory_bytes end
    if mb > 0 then out.memory_bytes = mb end
  end
  -- 动态：PID 上限
  if out.pids <= 0 then
    local pm = tonumber(cfg.pids_max) or 2048
    if pm > 0 then out.pids = pm end
  end
  -- 动态：CPU 配额取 min(宿主核数, cpu_cores_max, 容器配额) 个核
  if out.cpu_max <= 0 then
    local cores_max = tonumber(cfg.cpu_cores_max) or 4
    local cores = math.min(_nproc(), math.max(1, cores_max))
    if quota.cpu_cores then cores = math.min(cores, quota.cpu_cores) end
    if cores > 0 then out.cpu_max = cores * 100000 end
  end
  return out
end

--- 全局 CPU 预算（核）：静态 `cpu_global_max>0` 优先，否则 `max(1, 核数 - 1)`。
--- 保留 1 个核给 nvim/UI，避免沙箱并发任务吃满整机导致界面卡顿（计时器无法刷新）。
--- 父域 `cpu.max` 用该预算，子域配额再按 `cpu_cores_max` 细分，保证总量不超卖。
--- @return number 核数
function M.global_cpu_max()
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.limits") or {}
  local explicit = tonumber(cfg.cpu_global_max) or 0
  if explicit > 0 then return explicit end
  local n = _nproc()
  local quota = _cgroup_quota()
  if quota.cpu_cores then n = math.min(n, quota.cpu_cores) end
  return math.max(1, n - 1)
end

--- 单个子域实际生效的 CPU 配额（微秒/100ms）：不超过全局预算。
--- @param cpu_max number 期望的单任务配额
--- @return number 生效配额（0 = 不限制）
function M.effective_cpu_max(cpu_max)
  cpu_max = tonumber(cpu_max) or 0
  if cpu_max <= 0 then return 0 end
  local global_us = M.global_cpu_max() * 100000
  if global_us > 0 and cpu_max > global_us then return global_us end
  return cpu_max
end

-- ========== 公开 API ==========

--- 探测 cgroup v2 能力
--- @return table
function M.probe()
  local caps = { available = false, base = _base(), controllers = {}, writable = false }
  local base = caps.base
  local fstype = vim.fn.system("stat -fc %T " .. vim.fn.shellescape(base) .. " 2>/dev/null"):gsub("%s+$", "")
  if fstype == "cgroup2fs" then
    local controllers = _read_file(base .. "/cgroup.controllers")
    if controllers then
      for c in controllers:gmatch("%S+") do caps.controllers[#caps.controllers + 1] = c end
    end
    caps.writable = vim.fn.filewritable(base .. "/cgroup.procs") ~= 0
    caps.available = caps.writable
  end
  state.caps = caps
  return caps
end

--- @return table
function M.capabilities()
  if not state.caps then return M.probe() end
  return state.caps
end

--- 是否应在沙箱内暴露可写委派 cgroup 子树（`limits.delegate_cgroup`，默认开）。
--- 需 cgroup v2 可写；不可用时返回 false（调用方静默跳过）。
--- @return boolean
function M.delegation_enabled()
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.limits") or {}
  if cfg.delegate_cgroup == false then return false end
  return M.capabilities().available == true
end

--- 是否启用资源限制（动态默认开启；或任一静态限制 > 0）
--- @return boolean
function M.limits_configured()
  local limits = require("NeoAI.kernel.config_store").get("tools.sandbox.limits") or {}
  if limits.dynamic ~= false then return true end
  return (limits.memory_bytes or 0) > 0 or (limits.pids or 0) > 0 or (limits.cpu_max or 0) > 0
end

--- 准备资源域并写入限制
--- @param attempt_id string
--- @param limits table { memory_bytes?, pids?, cpu_max? }
--- @return table|nil handle
--- @return string|nil err
function M.prepare(attempt_id, limits)
  limits = limits or M.resolve_limits()
  local caps = M.capabilities()
  if not caps.available then
    return nil, "SANDBOX_CGROUP_UNAVAILABLE"
  end
  local base = caps.base
  local ctrls = _controller_set(caps)
  -- 需要的控制器：仅当内核在 cgroup.controllers 中实际暴露时才请求（否则写 subtree_control
  -- 会失败，且写 cpu.max 会 EINVAL）。缺失的控制器记入 unavailable，不虚报已限制。
  local wanted = {}
  if (limits.memory_bytes or 0) > 0 and ctrls.memory then wanted[#wanted + 1] = "memory" end
  if (limits.pids or 0) > 0 and ctrls.pids then wanted[#wanted + 1] = "pids" end
  if (limits.cpu_max or 0) > 0 and ctrls.cpu then wanted[#wanted + 1] = "cpu" end
  local spec = #wanted > 0 and ("+" .. table.concat(wanted, " +")) or nil
  -- 共享父域：所有并发任务挂其下。父域持有全局 CPU 预算，把控制器委派给子域；
  -- 父域自身不驻留进程（进程只在叶子子域），满足 cgroup v2「无内部进程」约束。
  local parent = _parent_path()
  vim.fn.mkdir(parent, "p")
  if vim.fn.isdirectory(parent) ~= 1 then
    return nil, "SANDBOX_CGROUP_CREATE_FAILED: " .. parent
  end
  if spec then
    pcall(_write_file, base .. "/cgroup.subtree_control", spec)
    pcall(_write_file, parent .. "/cgroup.subtree_control", spec)
  end
  local global_us = 0
  if (limits.cpu_max or 0) > 0 and ctrls.cpu then
    -- 父域 cpu.max = 全局预算：子域之和被限制在预算内，不再随并发数超卖。
    global_us = M.global_cpu_max() * 100000
    if global_us > 0 then
      _write_file(parent .. "/cpu.max", tostring(global_us) .. " 100000")
    end
  end
  local path = parent .. "/neoai_" .. _safe_id(attempt_id)
  vim.fn.mkdir(path, "p")
  if vim.fn.isdirectory(path) ~= 1 then
    return nil, "SANDBOX_CGROUP_CREATE_FAILED: " .. path
  end
  local applied = { memory = false, pids = false, cpu = false }
  local unavailable = {}
  if (limits.memory_bytes or 0) > 0 then
    if ctrls.memory then
      applied.memory = _write_file(path .. "/memory.max", tostring(limits.memory_bytes))
    end
    if not applied.memory then unavailable[#unavailable + 1] = "memory" end
  end
  if (limits.pids or 0) > 0 then
    if ctrls.pids then
      applied.pids = _write_file(path .. "/pids.max", tostring(limits.pids))
    end
    if not applied.pids then unavailable[#unavailable + 1] = "pids" end
  end
  local child_cpu = M.effective_cpu_max(limits.cpu_max)
  if child_cpu > 0 and ctrls.cpu then
    -- cpu.max 单位：quota period（微秒），如 "50000 100000" = 0.5 CPU
    applied.cpu = _write_file(path .. "/cpu.max", tostring(child_cpu) .. " 100000")
  end
  if (limits.cpu_max or 0) > 0 and not applied.cpu then unavailable[#unavailable + 1] = "cpu" end
  local handle = {
    attempt_id = attempt_id,
    path = path,
    parent = parent,
    limits = vim.deepcopy(limits),
    cpu_max = child_cpu,
    global_cpu_max = global_us,
    applied = applied,
    unavailable = unavailable,
  }
  state.handles[attempt_id] = handle
  if #unavailable > 0 then
    require("NeoAI.kernel.logger").warn(
      "[sandbox:cgroup] 控制器不可用或写入失败，以下限制未生效: %s (path=%s)",
      table.concat(unavailable, ","), path)
  end
  local diag = _diag()
  if diag.enabled then
    require("NeoAI.kernel.logger").debug(
      "[sandbox:diag] cgroup prepare attempt=%s mem=%s pids=%s cpu=%s applied=%s unavailable=%s path=%s",
      tostring(attempt_id), tostring(limits.memory_bytes or 0), tostring(limits.pids or 0),
      tostring(child_cpu), vim.inspect(applied), table.concat(unavailable, ","), path)
  end
  return handle
end

--- 构造把进程加入资源域的 argv 前缀（先写 PID 再 exec 原命令）
--- @param handle table
--- @return table prefix
function M.join_prefix(handle)
  local target = handle.path
  -- cgroup v2 的 no-internal-process 约束：启用了 subtree_control 的 cgroup 是「内部节点」，
  -- 不能再容纳进程，直接写其 cgroup.procs 会返回 EBUSY（Device or resource busy）。委派给
  -- 沙箱的可写叶子正是这种内部节点（供 systemd/AI 创建子 cgroup）。此时在其下建一个进程
  -- 承载子域，把载荷放进去；上层层级限额仍然物理封顶。
  local ctrl = _read_file(target .. "/cgroup.subtree_control")
  if ctrl and ctrl:gsub("%s", "") ~= "" then
    local child = target .. "/payload"
    if vim.fn.isdirectory(child) ~= 1 then pcall(vim.fn.mkdir, child, "p") end
    if vim.fn.isdirectory(child) == 1 then target = child end
  end
  local procs = target .. "/cgroup.procs"
  return { "sh", "-c", "echo $$ > '" .. procs .. "'; exec \"$@\"", "sh" }
end

--- 认领一个预热资源域到指定 attempt：更新索引与 handle.attempt_id，使 release 正常。
--- 供观测预热复用（预热时以占位 id 创建，命令到来时改挂到真实 attempt）。
--- @param handle table
--- @param attempt_id string
function M.adopt(handle, attempt_id)
  if not handle or not attempt_id then return end
  state.handles[handle.attempt_id] = nil
  handle.attempt_id = attempt_id
  state.handles[attempt_id] = handle
end

--- 向资源域内载荷进程发送 SIGTERM（优雅停止；不删除目录，幂等）。
--- 跳过 bwrap 监视进程：bwrap 载荷在独立 pid 命名空间内运行，对 bwrap 发 SIGTERM 会立即
--- 触发命名空间销毁，载荷来不及执行 SIGTERM trap（实测 trap 不生效）。只对载荷进程发
--- SIGTERM，让真正的服务/命令有机会清理并退出；到时仍存活由调用方 `cgroup.kill` 兜底。
--- @param handle table
--- @return number 已发送信号的进程数
function M.term(handle)
  if not handle or not handle.path then return 0 end
  local raw = _read_file(handle.path .. "/cgroup.procs")
  if not raw then return 0 end
  local n = 0
  for pid in raw:gmatch("%d+") do
    local comm = _read_file("/proc/" .. pid .. "/comm")
    if not (comm and comm:match("^bwrap")) then
      local ok = pcall(vim.uv.kill, tonumber(pid), 15)
      if ok then n = n + 1 end
    end
  end
  return n
end

--- 立即终止资源域内所有进程（不删除目录，幂等）。
--- 供命令取消/超时/输出截断时真正杀掉整个进程树：bwrap 载荷运行在独立 pid 命名空间内，
--- `jobstop` 只杀外层 bwrap，载荷可能继续存活并占住 cgroup；`cgroup.kill` 按域精确终止。
--- @param handle table
function M.kill(handle)
  if not handle or not handle.path then return end
  local diag = _diag()
  if diag.enabled then
    local caller = diag.log_kill_caller and ("\n" .. debug.traceback("", 2)) or ""
    local snap = diag.dump_cgroup_events and M.events_snapshot(handle.path) or nil
    require("NeoAI.kernel.logger").warn(
      "[sandbox:diag] cgroup.kill attempt=%s path=%s%s%s",
      tostring(handle.attempt_id), handle.path, caller,
      snap and (" events=" .. vim.inspect(snap)) or "")
  end
  pcall(_write_file, handle.path .. "/cgroup.kill", "1")
end

--- 释放资源域：杀掉残留进程并删除子域（共享父域保留，供后续任务复用）。
--- @param handle table
function M.release(handle)
  if not handle then return end
  M.kill(handle)
  for _ = 1, 50 do
    if vim.fn.isdirectory(handle.path) == 0 then break end
    pcall(vim.fn.delete, handle.path, "d")
    vim.wait(10)
  end
  state.handles[handle.attempt_id] = nil
end

--- 创建一个可向下委派控制器的 cgroup（供沙箱内 systemd --user 管理其子域）。
--- 该 cgroup 本身不驻留进程（cgroup v2「无内部进程」约束），控制器经
--- `cgroup.subtree_control` 委派给沙箱内的 user manager；沙箱将其以可写方式 bind 到
--- `/sys/fs/cgroup`，systemd 只能在本子树内创建/移动 cgroup，不污染宿主其它 cgroup。
--- @param id string
--- @param limits table|nil
--- @return table|nil handle { path, parent, limits }
--- @return string|nil err
function M.prepare_delegated(id, limits)
  limits = limits or M.resolve_limits()
  local caps = M.capabilities()
  if not caps.available then return nil, "SANDBOX_CGROUP_UNAVAILABLE" end
  local parent = _parent_path()
  vim.fn.mkdir(parent, "p")
  if vim.fn.isdirectory(parent) ~= 1 then
    return nil, "SANDBOX_CGROUP_CREATE_FAILED: " .. parent
  end
  local avail = _controller_set(caps)
  local ctrls = {}
  if (limits.memory_bytes or 0) > 0 and avail.memory then ctrls[#ctrls + 1] = "memory" end
  if (limits.pids or 0) > 0 and avail.pids then ctrls[#ctrls + 1] = "pids" end
  if (limits.cpu_max or 0) > 0 and avail.cpu then ctrls[#ctrls + 1] = "cpu" end
  local spec = #ctrls > 0 and ("+" .. table.concat(ctrls, " +")) or nil
  if spec then
    pcall(_write_file, caps.base .. "/cgroup.subtree_control", spec)
    pcall(_write_file, parent .. "/cgroup.subtree_control", spec)
  end
  local path = parent .. "/neoai_deleg_" .. _safe_id(id)
  vim.fn.mkdir(path, "p")
  if vim.fn.isdirectory(path) ~= 1 then
    return nil, "SANDBOX_CGROUP_CREATE_FAILED: " .. path
  end
  -- 父域全局 CPU 预算（与一次性路径一致）：委派子域之和受此物理封顶，避免「记账封顶但
  -- 物理分配不受控」——此前 prepare_delegated 只设子域 cpu.max，未设父域预算。
  if (limits.cpu_max or 0) > 0 and avail.cpu then
    local global_us = M.global_cpu_max() * 100000
    if global_us > 0 then _write_file(parent .. "/cpu.max", tostring(global_us) .. " 100000") end
  end
  -- 限额写在 path 上（path **不暴露**给沙箱）：沙箱只看到可写叶子 leaf，即便抬升 leaf 的
  -- memory.max/cpu.max，path 的限额仍按层级物理封顶（cgroup v2 层级限制）。
  local applied = { memory = false, pids = false, cpu = false }
  local unavailable = {}
  if (limits.memory_bytes or 0) > 0 then
    if avail.memory then
      applied.memory = _write_file(path .. "/memory.max", tostring(limits.memory_bytes))
    end
    if not applied.memory then unavailable[#unavailable + 1] = "memory" end
  end
  if (limits.pids or 0) > 0 then
    if avail.pids then
      applied.pids = _write_file(path .. "/pids.max", tostring(limits.pids))
    end
    if not applied.pids then unavailable[#unavailable + 1] = "pids" end
  end
  local child_cpu = M.effective_cpu_max(limits.cpu_max)
  if child_cpu > 0 and avail.cpu then
    applied.cpu = _write_file(path .. "/cpu.max", tostring(child_cpu) .. " 100000")
  end
  if (limits.cpu_max or 0) > 0 and not applied.cpu then unavailable[#unavailable + 1] = "cpu" end
  if #unavailable > 0 then
    require("NeoAI.kernel.logger").warn(
      "[sandbox:cgroup] 委派域控制器不可用或写入失败，以下限制未生效: %s (path=%s)",
      table.concat(unavailable, ","), path)
  end
  -- 暴露给沙箱的可写叶子：path 委派控制器给 leaf；leaf 再向下委派，供 systemd/AI 建子 cgroup。
  local leaf = path .. "/leaf"
  if spec then pcall(_write_file, path .. "/cgroup.subtree_control", spec) end
  vim.fn.mkdir(leaf, "p")
  if vim.fn.isdirectory(leaf) ~= 1 then
    return nil, "SANDBOX_CGROUP_CREATE_FAILED: " .. leaf
  end
  if spec then pcall(_write_file, leaf .. "/cgroup.subtree_control", spec) end
  return {
    path = leaf, limit_path = path, parent = parent,
    limits = vim.deepcopy(limits), applied = applied, unavailable = unavailable,
  }
end

--- 递归删除空的 cgroup 目录树（best-effort；调用前应先 kill 并等进程退出）。
--- @param path string
local function _rmdir_tree(path)
  local handle = vim.uv.fs_scandir(path)
  if handle then
    while true do
      local name, t = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if t == "directory" then _rmdir_tree(path .. "/" .. name) end
    end
  end
  pcall(vim.fn.delete, path, "d")
end

--- 释放委派 cgroup：kill 残留进程后递归删除子树。
--- @param handle table|nil
function M.release_delegated(handle)
  if not handle or not handle.path then return end
  -- 从限额层（未暴露）递归删除，连同可写叶子 leaf 一并清理。
  local root = handle.limit_path or handle.path
  pcall(_write_file, root .. "/cgroup.kill", "1")
  local deadline = vim.uv.hrtime() + 500 * 1e6
  while vim.uv.hrtime() < deadline do
    local raw = _read_file(root .. "/cgroup.procs")
    if not raw or raw:gsub("%s", "") == "" then break end
    vim.wait(20)
  end
  _rmdir_tree(root)
end

--- 重置（测试用）
function M.reset()
  local parent = _parent_path()
  pcall(_write_file, parent .. "/cgroup.kill", "1")
  for _, h in pairs(state.handles) do
    pcall(_write_file, h.path .. "/cgroup.kill", "1")
    vim.fn.delete(h.path, "d")
  end
  state.handles = {}
  -- 子域清空后删除共享父域（cgroupfs 目录须为空才能 rmdir）
  vim.fn.delete(parent, "d")
  state.caps = nil
end

M._safe_id = _safe_id
M._parent_path = _parent_path
M.cgroup_quota = _cgroup_quota

return M
