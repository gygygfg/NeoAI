--- 沙箱资源域（cgroup v2）
--- @module NeoAI.sandbox.cgroup
--- 每次尝试使用独立 cgroup v2 资源域，限制内存/PID/CPU（设计文档 §7.1）。
--- 能力缺失时返回明确错误，不静默降级；limits 全为 0 时不创建。

local M = {}

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
  -- 在根开启需要的控制器（root 允许同时有进程与 subtree_control）
  local wanted = {}
  if (limits.memory_bytes or 0) > 0 then wanted[#wanted + 1] = "memory" end
  if (limits.pids or 0) > 0 then wanted[#wanted + 1] = "pids" end
  if (limits.cpu_max or 0) > 0 then wanted[#wanted + 1] = "cpu" end
  if #wanted > 0 then
    pcall(_write_file, base .. "/cgroup.subtree_control", "+" .. table.concat(wanted, " +"))
  end
  local path = base .. "/neoai_" .. _safe_id(attempt_id)
  vim.fn.mkdir(path, "p")
  if not vim.fn.isdirectory(path) then
    return nil, "SANDBOX_CGROUP_CREATE_FAILED: " .. path
  end
  if (limits.memory_bytes or 0) > 0 then
    pcall(_write_file, path .. "/memory.max", tostring(limits.memory_bytes))
  end
  if (limits.pids or 0) > 0 then
    pcall(_write_file, path .. "/pids.max", tostring(limits.pids))
  end
  if (limits.cpu_max or 0) > 0 then
    -- cpu.max 单位：quota period（微秒），如 "50000 100000" = 0.5 CPU
    pcall(_write_file, path .. "/cpu.max", tostring(limits.cpu_max) .. " 100000")
  end
  local handle = { attempt_id = attempt_id, path = path, limits = vim.deepcopy(limits) }
  state.handles[attempt_id] = handle
  return handle
end

--- 构造把进程加入资源域的 argv 前缀（先写 PID 再 exec 原命令）
--- @param handle table
--- @return table prefix
function M.join_prefix(handle)
  local procs = handle.path .. "/cgroup.procs"
  return { "sh", "-c", "echo $$ > '" .. procs .. "'; exec \"$@\"", "sh" }
end

--- 释放资源域：杀掉残留进程并删除
--- @param handle table
function M.release(handle)
  if not handle then return end
  pcall(_write_file, handle.path .. "/cgroup.kill", "1")
  for _ = 1, 50 do
    if vim.fn.isdirectory(handle.path) == 0 then break end
    pcall(vim.fn.delete, handle.path, "d")
    vim.wait(10)
  end
  state.handles[handle.attempt_id] = nil
end

--- 重置（测试用）
function M.reset()
  for _, h in pairs(state.handles) do
    pcall(_write_file, h.path .. "/cgroup.kill", "1")
    vim.fn.delete(h.path, "d")
  end
  state.handles = {}
  state.caps = nil
end

M._safe_id = _safe_id

return M
