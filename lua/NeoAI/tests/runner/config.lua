--- NeoAI 测试运行器：配置常量与解析（纯函数，无副作用）
--- @module 'NeoAI.tests.runner.config'
--- 集中定义并行运行器的常量、worker/heavy 并发解析与「是否走 heavy 通道」判定。
--- 拆出后 parallel.lua 仅作门面委托，便于单测与复用。

local M = {}

-- ========== 常量 ==========

--- light 通道默认 worker 上限（多套件/进程的 LPT 分片数）
M.DEFAULT_MAX_WORKERS = 8
--- heavy 通道默认并发上限（一套件/进程）
M.DEFAULT_HEAVY_WORKERS = 2
--- heavy 并发硬上限（防止把核数全部吃满导致沙箱 137/SIGKILL）
M.DEFAULT_MAX_HEAVY = 4
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

-- ========== 解析函数 ==========

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

--- 解析 light 通道 worker 数：opts.workers > NEOAI_TEST_WORKERS > min(nproc, DEFAULT_MAX_WORKERS)
--- @param opts table
--- @return number
function M.resolve_workers(opts)
  local n = tonumber(opts and opts.workers)
  if not n or n < 1 then
    n = tonumber(vim.env.NEOAI_TEST_WORKERS)
  end
  if not n or n < 1 then
    n = math.min(M.cpu_count(), M.DEFAULT_MAX_WORKERS)
  end
  return math.max(1, math.floor(n))
end

--- 解析 heavy 通道并发上限：opts.heavy_workers > NEOAI_TEST_HEAVY_WORKERS > 默认 2；
--- 受 heavy 硬上限与「预留 light 核数」双重约束，且 NEOAI_TEST_HEAVY_WORKERS=1 等价旧串行通道。
--- @param opts table
--- @param light_workers number light 通道已占用的 worker 数
--- @return number
function M.resolve_heavy_workers(opts, light_workers)
  local n = tonumber(opts and opts.heavy_workers)
  if not n or n < 1 then
    n = tonumber(vim.env.NEOAI_TEST_HEAVY_WORKERS)
  end
  if not n or n < 1 then
    n = M.DEFAULT_HEAVY_WORKERS
  end
  n = math.max(1, math.floor(n))
  -- 硬上限
  n = math.min(n, M.DEFAULT_MAX_HEAVY)
  -- 预留 light 核数：W+H ≤ 核数（至少给 light 留 1 个核）
  local cores = M.cpu_count()
  local cap = math.max(1, cores - math.max(1, light_workers or 1))
  n = math.min(n, cap)
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
