--- 沙箱资源域（cgroup v2）
--- @module NeoAI.sandbox.cgroup
--- 每次尝试使用独立 cgroup v2 资源域，限制内存/PID/CPU（设计文档 §7.1）。
--- 能力缺失时返回明确错误，不静默降级；limits 全为 0 时不创建。

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
  f:write(content)
  f:close()
  return true
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
  -- 动态：内存取宿主总量的比例（受 memory_max_bytes 上限约束）
  if out.memory_bytes <= 0 then
    local total = _mem_total_bytes()
    local ratio = tonumber(cfg.memory_ratio) or 0.5
    local mb = math.floor(total * ratio)
    local cap = tonumber(cfg.memory_max_bytes) or 0
    if cap > 0 and (mb <= 0 or mb > cap) then mb = cap end
    if mb > 0 then out.memory_bytes = mb end
  end
  -- 动态：PID 上限
  if out.pids <= 0 then
    local pm = tonumber(cfg.pids_max) or 2048
    if pm > 0 then out.pids = pm end
  end
  -- 动态：CPU 配额取 min(宿主核数, cpu_cores_max) 个核
  if out.cpu_max <= 0 then
    local cores_max = tonumber(cfg.cpu_cores_max) or 4
    local cores = math.min(_nproc(), math.max(1, cores_max))
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
  return math.max(1, _nproc() - 1)
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
  local fstype = vim.fn.system("stat -fc %T /sys/fs/cgroup 2>/dev/null"):gsub("%s+$", "")
  if fstype == "cgroup2fs" then
    local controllers = _read_file("/sys/fs/cgroup/cgroup.controllers")
    if controllers then
      for c in controllers:gmatch("%S+") do caps.controllers[#caps.controllers + 1] = c end
    end
    caps.writable = vim.fn.filewritable("/sys/fs/cgroup/cgroup.procs") ~= 0
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
  -- 需要的控制器（root 允许同时有进程与 subtree_control）
  local wanted = {}
  if (limits.memory_bytes or 0) > 0 then wanted[#wanted + 1] = "memory" end
  if (limits.pids or 0) > 0 then wanted[#wanted + 1] = "pids" end
  if (limits.cpu_max or 0) > 0 then wanted[#wanted + 1] = "cpu" end
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
  if (limits.cpu_max or 0) > 0 then
    -- 父域 cpu.max = 全局预算：子域之和被限制在预算内，不再随并发数超卖。
    global_us = M.global_cpu_max() * 100000
    if global_us > 0 then
      pcall(_write_file, parent .. "/cpu.max", tostring(global_us) .. " 100000")
    end
  end
  local path = parent .. "/neoai_" .. _safe_id(attempt_id)
  vim.fn.mkdir(path, "p")
  if vim.fn.isdirectory(path) ~= 1 then
    return nil, "SANDBOX_CGROUP_CREATE_FAILED: " .. path
  end
  if (limits.memory_bytes or 0) > 0 then
    pcall(_write_file, path .. "/memory.max", tostring(limits.memory_bytes))
  end
  if (limits.pids or 0) > 0 then
    pcall(_write_file, path .. "/pids.max", tostring(limits.pids))
  end
  local child_cpu = M.effective_cpu_max(limits.cpu_max)
  if child_cpu > 0 then
    -- cpu.max 单位：quota period（微秒），如 "50000 100000" = 0.5 CPU
    pcall(_write_file, path .. "/cpu.max", tostring(child_cpu) .. " 100000")
  end
  local handle = {
    attempt_id = attempt_id,
    path = path,
    parent = parent,
    limits = vim.deepcopy(limits),
    cpu_max = child_cpu,
    global_cpu_max = global_us,
  }
  state.handles[attempt_id] = handle
  local diag = _diag()
  if diag.enabled then
    require("NeoAI.kernel.logger").debug(
      "[sandbox:diag] cgroup prepare attempt=%s mem=%s pids=%s cpu=%s path=%s",
      tostring(attempt_id), tostring(limits.memory_bytes or 0), tostring(limits.pids or 0),
      tostring(child_cpu), path)
  end
  return handle
end

--- 构造把进程加入资源域的 argv 前缀（先写 PID 再 exec 原命令）
--- @param handle table
--- @return table prefix
function M.join_prefix(handle)
  local procs = handle.path .. "/cgroup.procs"
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

return M
