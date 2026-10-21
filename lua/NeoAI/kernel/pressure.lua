--- 资源压力自适应层（内存 / PSI / 负载）
--- @module 'NeoAI.kernel.pressure'
---
--- 存在意义：本插件在「内存余量充足」的假设下决定了很多开销（沙箱单任务内存上限、eBPF
--- 观测预热、线程池并行度、UI 渲染节流、PTY 轮询频率）。在小内存云主机（如 2 核 / 1.6 GB /
--- 无 swap）上，这些默认值会把整机推到内存枯竭：sshd 连 SSH banner 都返回不了，表现为
--- 「nvim 卡顿」+「无法登录」。本模块提供**零主线程热路径开销**的资源压力分级，
--- 让各消费方按 ok / warn / critical 三级自动收敛非必要开销。
---
--- 设计约束（重要）：
---   1. 采样仅 3~4 次 io.open 读 /proc，结果按 `sample_ttl_ms`（默认 2000ms）缓存；
---      所有消费方（渲染热路径、每条命令）只读缓存，**禁止**重复采样。
---   2. 探测不到 /proc/meminfo（Android/Termux、裁剪容器）时一律视为 ok，
---      绝不因「探测不到」而误降级；缺 MemAvailable（内核 < 3.14）时回退 MemFree+Buffers+Cached。
---   3. **安全强制层永不因资源压力降级**：seccomp 基线、eBPF 行为兜底（第 2 层）、权限档位
---      均由其它模块直接决定，本模块只被「观测是否启动」类判定消费（见
---      `sandbox/observe/observer.observation_allowed`），绝不参与 `observer.backend()` /
---      `observer.backstop_available()` 的判定。
---   4. `M.classify` 为纯函数（不读文件系统），便于阈值边界单测。

local M = {}

-- ========== 私有常量 ==========

--- 等级排序：数值越大压力越高
local RANK = { ok = 0, warn = 1, critical = 2 }

--- MiB（阈值默认值用）
local MIB = 1024 * 1024

--- warn / critical 的默认阈值（`resources.pressure.*` 未提供某项时兜底）
--- 与 default_config.lua 的同名项保持一致；此处内置一份，使 `M.classify` 在传入空配置
--- 时仍可用（纯函数可单测，不依赖配置模块已加载）。
local DEFAULT_WARN = {
  mem_ratio = 0.15,
  mem_bytes = 256 * MIB,
  psi_avg10 = 10,
  load_factor = 2,
}
local DEFAULT_CRITICAL = {
  mem_ratio = 0.05,
  mem_bytes = 96 * MIB,
  psi_avg10 = 40,
  mem_ratio_no_swap = 0.08,
}

--- 取阈值：配置优先，缺失时用内置默认
--- @param t table|nil 用户配置段
--- @param base table 默认值
--- @param key string
--- @return number|nil
local function _thr(t, base, key)
  local v = type(t) == "table" and tonumber(t[key]) or nil
  if v == nil then v = base[key] end
  return v
end

-- ========== 私有状态 ==========

local state = {
  cached = nil,        -- 最近一次对外快照（TTL 内复用）
  cached_at = 0,       -- 快照生成时刻（hrtime 纳秒）
  last_level = nil,    -- 上一次对外发布的等级（用于变更检测）
  sampler = nil,       -- 测试注入的采样函数（nil = 读真实 /proc）
  listeners = {},      -- on_change 注册的回调
  critical_notified = false, -- 是否已为「首次进入 critical」提示过
}

-- ========== 私有函数 ==========

--- 读取整份文本文件（失败返回 nil，绝不抛错）
--- @param path string
--- @return string|nil
local function _read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local ok, data = pcall(f.read, f, "*a")
  f:close()
  if not ok or type(data) ~= "string" then return nil end
  return data
end

--- 读取 PSI 文件的 `some avg10=` 值（/proc/pressure/*；内核 < 4.20 或无 PSI 时返回 nil）
--- @param path string
--- @return number|nil
local function _psi_some_avg10(path)
  local data = _read(path)
  if not data then return nil end
  local v = data:match("some%s+avg10=([%d%.]+)")
  return tonumber(v)
end

--- 读取 /proc/meminfo 为 { 字段名 = 字节数 }
--- 注：meminfo 的数值单位是 kB，统一换算为字节，避免调用方各自乘 1024 出错。
--- @return table|nil
local function _meminfo_bytes()
  local data = _read("/proc/meminfo")
  if not data then return nil end
  local out = {}
  for key, val in data:gmatch("([%w_%(%)]+):%s*(%d+)") do
    out[key] = tonumber(val) * 1024
  end
  if not out.MemTotal or out.MemTotal <= 0 then return nil end
  return out
end

--- 取当前资源配置（缺省返回空表，模块可独立使用）
--- @return table
local function _cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("resources.pressure")
  end)
  if ok and type(cfg) == "table" then return cfg end
  return {}
end

--- 读取当前有效等级
--- @return string "ok"|"warn"|"critical"
local function _level_now()
  local snap = M.snapshot()
  return snap.level or "ok"
end

--- 发布一次等级（变更检测 → 事件 + 首次 critical 提示）
--- @param snap table 新快照
local function _publish(snap)
  local prev = state.last_level
  state.last_level = snap.level
  if prev == snap.level then return end
  -- 等级变化事件：payload 带前后等级与关键采样值，供日志/状态栏/测试消费
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(
      require("NeoAI.kernel.events").RESOURCE_PRESSURE,
      {
        level = snap.level,
        prev = prev,
        mem_total_bytes = snap.mem_total_bytes,
        mem_available_bytes = snap.mem_available_bytes,
        psi_memory_avg10 = snap.psi_memory_avg10,
        load1 = snap.load1,
        cores = snap.cores,
      }
    )
  end)
  for _, cb in ipairs(state.listeners) do pcall(cb, snap.level, prev, snap) end
  -- 仅在**首次**进入 critical 时提示一次（用户可能在无感知的情况下被降级）
  if snap.level == "critical" and not state.critical_notified then
    state.critical_notified = true
    local cfg = _cfg()
    if cfg.notify ~= false then
      pcall(function()
        vim.schedule(function()
          pcall(vim.notify,
            "[NeoAI] 系统资源紧张（内存余量不足），已自动降低观测/并行/渲染开销以保住整机响应。\n"
              .. M.describe(),
            vim.log.levels.WARN, { title = "NeoAI 资源压力" })
        end)
      end)
    end
  elseif snap.level == "ok" then
    -- 恢复后复位，使下一次临界仍能提示一次
    state.critical_notified = false
  end
  pcall(function()
    require("NeoAI.kernel.logger").debug(
      "[pressure] 等级 %s → %s（可用 %d MB / 共 %d MB, PSI mem avg10=%s, load1=%s）",
      tostring(prev), tostring(snap.level),
      math.floor((snap.mem_available_bytes or 0) / MIB),
      math.floor((snap.mem_total_bytes or 0) / MIB),
      tostring(snap.psi_memory_avg10), tostring(snap.load1))
  end)
end

-- ========== 采样（公开，便于测试与诊断直接取原始值） ==========

--- 从已解析的 meminfo（字段名 → 字节数）取「可用内存」
--- 缺 MemAvailable（内核 < 3.14）时回退 MemFree + Buffers + Cached，与 `free` 的估算同源。
--- 拆成纯函数以便单测回退分支（无需伪造 /proc）。
--- @param mi table 字段名 → 字节数
--- @return number
function M._meminfo_available(mi)
  if type(mi) ~= "table" then return 0 end
  local avail = mi.MemAvailable
  if avail then return avail end
  return (mi.MemFree or 0) + (mi.Buffers or 0) + (mi.Cached or 0)
end

--- 采集一次宿主资源快照（**不做缓存**，消费方请用 `M.snapshot()`）
--- 探测失败（无 /proc、裁剪容器、Android 早期内核）返回 nil，调用方须视为 ok。
--- @return table|nil { mem_total_bytes, mem_available_bytes, swap_total_bytes,
---   psi_memory_avg10, psi_cpu_avg10, load1, cores }
function M.sample()
  local mi = _meminfo_bytes()
  if not mi then return nil end
  local avail = M._meminfo_available(mi)
  local load1 = nil
  local la = _read("/proc/loadavg")
  if la then load1 = tonumber(la:match("^([%d%.]+)")) end
  local cores = 1
  pcall(function() cores = require("NeoAI.utils.host").cores() end)
  return {
    mem_total_bytes = mi.MemTotal,
    mem_available_bytes = avail,
    swap_total_bytes = mi.SwapTotal or 0,
    psi_memory_avg10 = _psi_some_avg10("/proc/pressure/memory"),
    psi_cpu_avg10 = _psi_some_avg10("/proc/pressure/cpu"),
    load1 = load1,
    cores = cores,
  }
end

-- ========== 分级（纯函数） ==========

--- 依采样值与配置判定压力等级（纯函数：不读文件系统，便于阈值边界单测）
---
--- 判定顺序：先 critical 后 warn（同一采样可能同时满足两档，取更严者）。
--- 采样缺失（nil）或 MemTotal 不可用 → "ok"（探测不到绝不误降级）。
--- @param sample table|nil `M.sample()` 的返回值
--- @param cfg table|nil resources.pressure 配置
--- @return string "ok"|"warn"|"critical"
function M.classify(sample, cfg)
  cfg = cfg or _cfg()
  if type(sample) ~= "table" then return "ok" end
  local total = tonumber(sample.mem_total_bytes) or 0
  if total <= 0 then return "ok" end
  local avail = tonumber(sample.mem_available_bytes) or total
  local cw = cfg.warn
  local cc = cfg.critical

  -- critical：可用内存跌破「绝对值 + 比例」双阈值中的较高者
  local c_bytes = math.max(_thr(cc, DEFAULT_CRITICAL, "mem_bytes"), total * _thr(cc, DEFAULT_CRITICAL, "mem_ratio"))
  if avail < c_bytes then return "critical" end
  -- critical：无 swap 时缺少缓冲，可用内存低于 total × mem_ratio_no_swap 即视为临界
  local c_noswap = _thr(cc, DEFAULT_CRITICAL, "mem_ratio_no_swap")
  if (tonumber(sample.swap_total_bytes) or 0) <= 0 and avail < total * c_noswap then
    return "critical"
  end
  -- critical：内存压力停顿（PSI some avg10 高 = 进程已在等内存回收）
  local cpsi = _thr(cc, DEFAULT_CRITICAL, "psi_avg10")
  if sample.psi_memory_avg10 and sample.psi_memory_avg10 >= cpsi then
    return "critical"
  end

  -- warn
  local w_bytes = math.max(_thr(cw, DEFAULT_WARN, "mem_bytes"), total * _thr(cw, DEFAULT_WARN, "mem_ratio"))
  if avail < w_bytes then return "warn" end
  local wpsi = _thr(cw, DEFAULT_WARN, "psi_avg10")
  if sample.psi_memory_avg10 and sample.psi_memory_avg10 >= wpsi then
    return "warn"
  end
  -- warn：CPU 侧已排队（load1 / 核数 ≥ 阈值 = 每个核上都有 2 个以上可运行任务）
  local wlf = _thr(cw, DEFAULT_WARN, "load_factor")
  local cores = tonumber(sample.cores) or 0
  if wlf and sample.load1 and cores > 0 and (sample.load1 / cores) >= wlf then
    return "warn"
  end
  return "ok"
end

-- ========== 快照（带 TTL 缓存，热路径唯一入口） ==========

--- 构建快照（`publish=false` 时不发事件、不提示，供 health/diag 等只读探查使用）
--- @param publish boolean
--- @return table
local function _build_snapshot(publish)
  local cfg = _cfg()
  if cfg.enabled == false then
    return { level = "ok", disabled = true }
  end
  local ttl = tonumber(cfg.sample_ttl_ms) or 2000
  local now = vim.uv.hrtime()
  if state.cached and (now - state.cached_at) < ttl * 1e6 then
    -- 命中缓存：仍可能需要在首次发布时补齐事件（仅在 publish 且等级未发布过时）
    if publish then _publish(state.cached) end
    return state.cached
  end

  local sample = state.sampler and state.sampler() or M.sample()
  local level
  -- simulate 用于无需真实施压即可复现降级路径（调试 / 远程验证 / 测试）
  local sim = cfg.simulate
  if sim == "ok" or sim == "warn" or sim == "critical" then
    level = sim
  else
    level = M.classify(sample, cfg)
  end
  local s = sample or {}
  local snap = {
    level = level,
    mem_total_bytes = s.mem_total_bytes,
    mem_available_bytes = s.mem_available_bytes,
    swap_total_bytes = s.swap_total_bytes,
    psi_memory_avg10 = s.psi_memory_avg10,
    psi_cpu_avg10 = s.psi_cpu_avg10,
    load1 = s.load1,
    cores = s.cores,
    at = now,
  }
  state.cached = snap
  state.cached_at = now
  if publish then _publish(snap) end
  return snap
end

--- 当前资源压力快照（TTL 缓存：`sample_ttl_ms` 内复用，热路径只读缓存）
--- @return table { level, mem_total_bytes, mem_available_bytes, psi_memory_avg10,
---   load1, cores, disabled }
function M.snapshot()
  return _build_snapshot(true)
end

--- 只读快照（**不**发事件、**不**提示）：供 :checkhealth / 诊断命令等要求无副作用的路径使用。
--- @return table 同 `M.snapshot()`
function M.inspect()
  return _build_snapshot(false)
end

--- 当前等级（热路径友好：一次 hrtime + 缓存读 + 字段比较）
--- @return string "ok"|"warn"|"critical"
function M.level()
  return M.snapshot().level or "ok"
end

--- 当前等级是否达到（含）目标等级
--- @param target string "warn"|"critical"
--- @return boolean
function M.at_least(target)
  local cur = RANK[M.level()] or 0
  return cur >= (RANK[target] or 0)
end

--- 分项降级开关是否启用（`resources.pressure.degrade.<name> = false` 可单点关闭）
--- @param name string 分项名（sandbox_memory / observe_prewarm / observe_kernel /
---   thread_pool / ui_throttle / pty_poll）
--- @return boolean
function M.degrade_enabled(name)
  local cfg = _cfg()
  local d = cfg.degrade
  if type(d) == "table" and d[name] == false then return false end
  return true
end

--- 内核观测是否允许启动（**只门控「观测」，不影响「强制」**）
--- critical 时关闭 eBPF/strace 观测，回退既有命令解析启发式，以省下探针的常驻内存与 CPU。
--- 注意：本函数绝不被 `observer.backend()` / `observer.backstop_available()` 使用——
--- seccomp 基线、eBPF 行为兜底、权限档位在任何等级下都不降级。
--- @return boolean allowed
--- @return string|nil reason
function M.observation_allowed()
  if not M.degrade_enabled("observe_kernel") then return true end
  if M.at_least("critical") then return false, "pressure:critical" end
  return true
end

--- 按压力放大一个时间间隔基数（节流/轮询间隔用）
--- ok ×1、warn ×2、critical ×4（下限恒为 1）
--- @param base_ms number 基准毫秒数
--- @return number
function M.scaled_ms(base_ms)
  local base = tonumber(base_ms) or 1
  if base < 1 then base = 1 end
  if not M.degrade_enabled("ui_throttle") then return base end
  local lvl = M.level()
  if lvl == "critical" then return base * 4 end
  if lvl == "warn" then return base * 2 end
  return base
end

--- 沙箱单任务内存上限的「可用内存封顶值」
--- 目的：消除「MemTotal × memory_ratio」在低内存机上远超真实余量的打爆点。
--- ok 时返回 nil（不封顶，沿用原动态上限）；warn / critical 时按可用内存折算。
--- @return number|nil bytes
--- @return string level
function M.sandbox_memory_cap()
  if not M.degrade_enabled("sandbox_memory") then return nil, "ok" end
  local snap = M.inspect()
  local lvl = snap.level or "ok"
  if lvl == "ok" then return nil, lvl end
  local avail = tonumber(snap.mem_available_bytes)
  if not avail or avail <= 0 then return nil, lvl end
  local cfg = _cfg()
  local ratio = tonumber(cfg.sandbox_available_ratio) or 0.6
  if lvl == "critical" then
    ratio = tonumber(cfg.sandbox_available_ratio_critical) or 0.4
  end
  return math.floor(avail * ratio), lvl
end

--- 当前生效的降级项列表（供 health / diag / 命令展示）
--- @return string[]
function M.degradations()
  local out = {}
  local snap = M.inspect()
  local lvl = snap.level or "ok"
  if lvl == "ok" then return out end
  local function add(cond, text)
    if cond then out[#out + 1] = text end
  end
  local cap = M.sandbox_memory_cap()
  if cap then
    add(true, ("沙箱单任务内存上限按可用内存封顶为 %d MB"):format(math.floor(cap / MIB)))
  end
  add(M.degrade_enabled("observe_prewarm"), "关闭 eBPF 观测预热")
  add(not M.observation_allowed(), "关闭内核观测探针（回退 heuristic 解析）")
  add(M.degrade_enabled("thread_pool"), "收敛工作线程并行度")
  add(M.degrade_enabled("ui_throttle"), "放大 UI 渲染节流间隔")
  add(M.degrade_enabled("pty_poll"), "降低 PTY 输入检测轮询频率")
  return out
end

--- 人类可读的一行描述（health / doctor / diag 用）
--- @return string
function M.describe()
  local snap = M.inspect()
  if snap.disabled then return "资源压力自适应已关闭（resources.pressure.enabled=false）" end
  local parts = { "等级=" .. tostring(snap.level) }
  if snap.mem_total_bytes then
    parts[#parts + 1] = ("可用内存=%d MB/%d MB"):format(
      math.floor((snap.mem_available_bytes or 0) / MIB),
      math.floor(snap.mem_total_bytes / MIB))
  else
    parts[#parts + 1] = "可用内存=探测不可用（视为 ok）"
  end
  if snap.swap_total_bytes then
    parts[#parts + 1] = ("swap=%d MB"):format(math.floor(snap.swap_total_bytes / MIB))
  end
  if snap.psi_memory_avg10 then parts[#parts + 1] = "PSI(mem some avg10)=" .. tostring(snap.psi_memory_avg10) end
  if snap.load1 then parts[#parts + 1] = ("load1=%s/%s核"):format(tostring(snap.load1), tostring(snap.cores)) end
  return table.concat(parts, "，")
end

--- 注册等级变化回调（返回取消函数）
--- @param cb function(level: string, prev: string|nil, snap: table)
--- @return function unregister
function M.on_change(cb)
  if type(cb) ~= "function" then return function() end end
  table.insert(state.listeners, cb)
  local removed = false
  return function()
    if removed then return end
    removed = true
    for i, f in ipairs(state.listeners) do
      if f == cb then
        table.remove(state.listeners, i)
        break
      end
    end
  end
end

-- ========== 测试钩子 ==========

--- 注入自定义采样函数（测试用；传 nil 恢复真实采样）
--- @param fn function|nil -> table|nil
function M._set_sampler(fn)
  state.sampler = fn
  M.reset()
end

--- 清空缓存与状态（测试用）
function M.reset()
  state.cached = nil
  state.cached_at = 0
  state.last_level = nil
  state.critical_notified = false
end

return M
