--- NeoAI 测试运行器：配置常量与并发计划（纯函数，无副作用）
--- @module 'NeoAI.tests.runner.config'
--- 集中定义并行运行器的常量、**按实际核数与可用内存动态分配** light/heavy 并发，
--- 以及「是否走 heavy 通道」判定。拆出后 parallel.lua 仅作门面委托，便于单测与复用。
---
--- 分配口径（未显式覆盖时）：
---   * 总并发硬上限 = 核数 - 2（预留两核给系统/编辑器，核数很少时至少 2 路）；
---   * heavy（一套件一子进程）：目标 核数/2，受总上限与内存约束；
---   * light（LPT 分片）：总上限余量（另上限 16）；
---   * 内存：heavy 每路预留 HEAVY_MEM_BUDGET_MB、light 每路 LIGHT_MEM_BUDGET_MB，
---     可用内存不足时从 heavy 让位（heavy 至少 1 路）并压缩 light，保证至少 1 路 light；
---   * 自动推导时保证 W+H ≤ 核数。环境变量 NEOAI_TEST_WORKERS / NEOAI_TEST_HEAVY_WORKERS
---     可显式覆盖；运行期另由 `runner.memguard` 在每次启动分片前做内存许可（动态再收敛）。

local M = {}

-- ========== 常量 ==========

--- light 通道 worker 上限（自动推导时的上限；显式覆盖不受此限）
M.DEFAULT_MAX_WORKERS = 16
--- 自动推导 heavy 并发的下限（核数再少也保留 2 路，避免 heavy 通道退化为串行）
M.MIN_HEAVY_WORKERS = 2
--- 为系统/编辑器预留的核数：并发总数硬上限 = 核数 - RESERVED_CORES（避免吃满整机）
M.RESERVED_CORES = 2
--- 并发总数硬上限的下限（核数很少时仍允许 heavy + light 各 1 路）
M.MIN_TOTAL_WORKERS = 2
--- 每个 heavy worker 的内存预算（MB）
M.HEAVY_MEM_BUDGET_MB = 1536
--- 每个 light worker 的内存预算（MB）
M.LIGHT_MEM_BUDGET_MB = 512
--- 单分片默认超时：15 分钟
M.DEFAULT_TIMEOUT_MS = 900000
--- 发现阶段默认超时
M.DEFAULT_DISCOVERY_TIMEOUT_MS = 120000
--- 耗时缓存文件名（仓库根，CI 可跨运行复用；gitignored）
M.TIMINGS_FILE = ".neoai_test_timings.json"

-- 默认视为「资源重/时序敏感、需走 heavy 通道」的套件名模式：sandbox* 启动
-- bwrap/unshare/cgroup 与常驻进程，无界并发会互相争抢内存/CPU（137/SIGKILL、超时）；
-- pty 依赖 PTY 交互时序，并发度需受限。这些套件一套件一子进程，受 heavy 并发上限约束。
M.SERIAL_PATTERNS = { "^sandbox", "^pty$" }

-- ========== 资源探测 ==========

--- 本机 CPU 数（用于默认 worker 数）
--- @return number
function M.cpu_count()
  local ok, cpus = pcall(vim.uv.cpus)
  if ok and type(cpus) == "table" and #cpus > 0 then
    return #cpus
  end
  local out = vim.fn.system("nproc")
  local n = tonumber((out or ""):match("%d+"))
  return n or 4
end

--- 读取整型文本（失败/不存在返回 nil）
--- @param path string
--- @return number|nil
local function _read_num(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  local n = line and line:match("^%s*(%d+)")
  return tonumber(n)
end

--- 进程实际可用内存（字节）。优先 libuv `get_available_memory()`（新版本已计入 cgroup/容器
--- 约束），其次 cgroup v2/v1「限额 - 当前用量」，最后 `/proc/meminfo` 的 MemAvailable。
--- @return number|nil
function M.available_memory_bytes()
  local uv = vim.uv or vim.loop
  if uv and type(uv.get_available_memory) == "function" then
    local ok, v = pcall(uv.get_available_memory)
    v = ok and tonumber(v) or nil
    if v and v > 0 then return v end
  end
  -- cgroup v2（容器/嵌套 cgroup）
  local limit = _read_num("/sys/fs/cgroup/memory.max")
  local used = _read_num("/sys/fs/cgroup/memory.current")
  if limit and used and limit > 0 then return math.max(0, limit - used) end
  -- cgroup v1
  local v1_limit = _read_num("/sys/fs/cgroup/memory/memory.limit_in_bytes")
  local v1_used = _read_num("/sys/fs/cgroup/memory/memory.usage_in_bytes")
  if v1_limit and v1_used and v1_limit > 0 and v1_limit < 1e15 then
    return math.max(0, v1_limit - v1_used)
  end
  -- /proc/meminfo MemAvailable
  local f = io.open("/proc/meminfo", "r")
  if not f then return nil end
  local bytes
  for line in f:lines() do
    local kb = line:match("^MemAvailable:%s*(%d+)%s*kB")
    if kb then
      bytes = tonumber(kb) * 1024
      break
    end
  end
  f:close()
  return bytes
end

--- 进程实际可用内存（GB，便于阅读/诊断）；不可用返回 nil
--- @return number|nil
function M.mem_available_gb()
  local b = M.available_memory_bytes()
  if not b then return nil end
  return b / (1024 * 1024 * 1024)
end

--- 并发总数硬上限：最多占用 `核数 - RESERVED_CORES` 个 worker（给系统/编辑器留 2 核），
--- 核数很少时至少 2 路（heavy + light 各 1），且不超过核数。
--- @param cores number|nil
--- @return number
function M.total_capacity(cores)
  cores = math.max(1, math.floor(tonumber(cores) or M.cpu_count()))
  return math.max(1, math.min(cores,
    math.max(M.MIN_TOTAL_WORKERS, cores - M.RESERVED_CORES)))
end

-- ========== 并发计划 ==========

--- 计算 light/heavy 并发计划：显式覆盖（opts/env）优先，其余按核数与**可用内存**动态推导。
--- @param opts table|nil { workers?, heavy_workers?, cores?, mem_mb? }（cores/mem_mb 供测试注入）
--- @param cores number|nil 兼容旧签名（等价 opts.cores）
--- @param mem_mb number|nil 兼容旧签名（等价 opts.mem_mb）
--- @return table { light, heavy, cores, mem_mb }
function M.plan(opts, cores, mem_mb)
  opts = opts or {}
  cores = math.max(1, math.floor(tonumber(cores) or tonumber(opts.cores) or M.cpu_count()))
  mem_mb = tonumber(mem_mb) or tonumber(opts.mem_mb)
  if not mem_mb then mem_mb = tonumber(vim.env.NEOAI_TEST_MEM_MB) end
  if not mem_mb then
    local bytes = M.available_memory_bytes()
    mem_mb = bytes and (bytes / (1024 * 1024)) or nil
  end

  local heavy_override = tonumber(opts.heavy_workers) or tonumber(vim.env.NEOAI_TEST_HEAVY_WORKERS)
  local light_override = tonumber(opts.workers) or tonumber(vim.env.NEOAI_TEST_WORKERS)
  if not heavy_override or heavy_override < 1 then heavy_override = nil end
  if not light_override or light_override < 1 then light_override = nil end

  -- 1) 核数目标：总并发硬上限 = 核数 - RESERVED_CORES（预留 2 核给系统/编辑器）；
  --    heavy ≈ 核数/2，再受总上限约束。
  local total_cap = M.total_capacity(cores)
  local heavy = heavy_override and math.floor(heavy_override)
    or math.max(M.MIN_HEAVY_WORKERS, math.floor(cores / 2))
  heavy = math.max(1, math.min(heavy, total_cap))

  -- 2) 内存目标：heavy 每路 HEAVY_MEM_BUDGET_MB；不足时从 heavy 让位（至少保留 1 路），
  --    并尽量给 light 留下 ≥2 路的预算（避免单路 light 成为新的长尾）。
  if mem_mb and mem_mb > 0 then
    local by_mem = math.floor(mem_mb / M.HEAVY_MEM_BUDGET_MB)
    heavy = math.min(heavy, math.max(1, by_mem))
    while heavy > 1
      and (mem_mb - heavy * M.HEAVY_MEM_BUDGET_MB) < M.LIGHT_MEM_BUDGET_MB do
      heavy = heavy - 1
    end
    -- 保证 light 至少 2 路（否则单路 light 会吞掉全部 light 套件，成为新的长尾）。
    local function light_fit(h)
      return math.floor(math.max(0, mem_mb - h * M.HEAVY_MEM_BUDGET_MB) / M.LIGHT_MEM_BUDGET_MB)
    end
    while heavy > 2 and light_fit(heavy) < 2 do
      heavy = heavy - 1
    end
  end

  -- 3) light：总并发余量（核数 - 预留 - heavy）+ 剩余内存（未显式覆盖时）。
  local light
  if light_override then
    light = math.floor(light_override)
  else
    light = math.min(M.DEFAULT_MAX_WORKERS, math.max(1, total_cap - heavy))
    if mem_mb and mem_mb > 0 then
      local left = mem_mb - heavy * M.HEAVY_MEM_BUDGET_MB
      local by_mem = math.floor(math.max(0, left) / M.LIGHT_MEM_BUDGET_MB)
      light = math.min(light, math.max(1, by_mem))
    end
  end
  light = math.max(1, light)

  -- 4) 自动推导时守住 W+H ≤ 核数-2（显式 light 覆盖视为用户选择，不再压 heavy）。
  if not light_override then
    light = math.min(light, math.max(1, total_cap - heavy))
    heavy = math.min(heavy, math.max(1, total_cap - light))
    light = math.max(1, math.min(light, total_cap - heavy))
  end

  return { light = light, heavy = heavy, cores = cores, mem_mb = mem_mb,
    total_cap = total_cap }
end

--- 解析 light 通道 worker 数（兼容旧接口，等于 `plan().light`）。
--- @param opts table
--- @param cores number|nil
--- @param mem_gb number|nil
--- @return number
function M.resolve_workers(opts, cores, mem_gb)
  local mem_mb = tonumber(mem_gb) and tonumber(mem_gb) * 1024 or nil
  return M.plan(opts, cores, mem_mb).light
end

--- 解析 heavy 通道并发上限（兼容旧接口：在 `plan().heavy` 基础上再按 light 占用收敛）。
--- @param opts table
--- @param light_workers number light 通道已占用的 worker 数
--- @param cores number|nil
--- @param mem_gb number|nil
--- @return number
function M.resolve_heavy_workers(opts, light_workers, cores, mem_gb)
  local mem_mb = tonumber(mem_gb) and tonumber(mem_gb) * 1024 or nil
  local plan = M.plan(opts, cores, mem_mb)
  local n = math.min(plan.heavy, math.max(1, plan.total_cap - math.max(1, light_workers or 1)))
  return math.max(1, n)
end

--- 判断套件是否走 heavy（资源重）通道。
--- @param name string
--- @param opts table
--- @return boolean
function M.is_serial(name, opts)
  local pats = opts and opts.serial_suites
  if pats == nil then pats = M.SERIAL_PATTERNS end
  if type(pats) == "function" then return pats(name) == true end
  for _, pat in ipairs(pats) do
    if tostring(name):find(pat) then return true end
  end
  return false
end

return M
