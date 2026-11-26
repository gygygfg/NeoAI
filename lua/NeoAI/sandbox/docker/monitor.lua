--- 会话内容器资源监测
--- @module 'NeoAI.sandbox.docker.monitor'
---
--- 安全参数的容器**不拒绝网络**，只监测 CPU / 内存 / PIDs / OOM 临近；持续超限后由 broker
--- 自动 `kill`，并把原因写入待报告队列，由 `run_command` 结果回传给 Agent。
---
--- 本模块的判定是纯函数（输入 docker stats + 限制），轮询/API 调用由 broker 负责。

local M = {}

local DEFAULTS = {
  interval_ms = 2000,
  sustain_samples = 15,     -- 2s * 15 ≈ 30s
  grace_ms = 30000,
  mem_ratio = 0.85,
  mem_limit_ratio = 0.95,
  cpu_ratio = 0.90,
  pids_ratio = 0.80,
  pids_abs = 4096,
  oom_ratio = 0.95,
  oom_samples = 5,
  max_notices = 200,
}

local state = {
  notices = {}, -- [agent_id] = { text... }
  totals = 0,
  killed = 0,
}

-- ========== 私有函数 ==========

--- 读宿主内存总量（bytes）。
--- @return number|nil
local function _host_memory()
  local f = io.open("/proc/meminfo", "r")
  if not f then return nil end
  local text = f:read("*a") or ""
  f:close()
  local kb = tonumber(text:match("MemTotal:%s*(%d+)"))
  if not kb then return nil end
  return kb * 1024
end

--- 读宿主 CPU 数。
--- @return number
local function _host_cpus()
  local ok, n = pcall(vim.uv.available_parallelism)
  if ok and type(n) == "number" and n > 0 then return n end
  return 1
end

--- 容器内存工作集（扣除 inactive file cache）。
--- @param stats table
--- @return number|nil
local function _mem_usage(stats)
  local ms = type(stats.memory_stats) == "table" and stats.memory_stats or {}
  local usage = tonumber(ms.usage)
  if not usage then return nil end
  local detail = type(ms.stats) == "table" and ms.stats or {}
  local inactive = tonumber(detail.total_inactive_file) or tonumber(detail.inactive_file) or 0
  return math.max(0, usage - inactive)
end

--- 容器 CPU 使用率（占**分配额度**的比例；无限制时占宿主比例）。
--- @param stats table
--- @param nano_cpus number|nil
--- @return number|nil
local function _cpu_ratio(stats, nano_cpus)
  local cs = type(stats.cpu_stats) == "table" and stats.cpu_stats or {}
  local pre = type(stats.precpu_stats) == "table" and stats.precpu_stats or {}
  local total = tonumber(cs.cpu_usage and cs.cpu_usage.total_usage)
  local pre_total = tonumber(pre.cpu_usage and pre.cpu_usage.total_usage)
  local sys = tonumber(cs.system_cpu_usage)
  local pre_sys = tonumber(pre.system_cpu_usage)
  if not total or not pre_total or not sys or not pre_sys then return nil end
  local delta = total - pre_total
  local sys_delta = sys - pre_sys
  if delta < 0 or sys_delta <= 0 then return nil end
  local cpus = tonumber(cs.online_cpus) or _host_cpus()
  local pct = (delta / sys_delta) * cpus
  local quota = tonumber(nano_cpus)
  if quota and quota > 0 then
    return pct / (quota / 1e9)
  end
  return pct / cpus
end

--- 归一化 stats，便于判定与展示。
--- @param stats table
--- @param ctx table
--- @return table
function M.normalize(stats, ctx)
  ctx = ctx or {}
  local mem = _mem_usage(stats) or 0
  local mem_limit = tonumber(ctx.memory_limit)
  local host_mem = tonumber(ctx.host_memory) or _host_memory() or 0
  local cpu = _cpu_ratio(stats, ctx.nano_cpus) or 0
  local pids = 0
  if type(stats.pids_stats) == "table" then pids = tonumber(stats.pids_stats.current) or 0 end
  local pids_limit = tonumber(ctx.pids_limit) or 0
  local oom = false
  if type(stats.memory_stats) == "table" and type(stats.memory_stats.stats) == "table" then
    oom = (tonumber(stats.memory_stats.stats.oom_kill) or 0) > 0
  end
  return {
    mem_bytes = mem,
    mem_limit = mem_limit and mem_limit > 0 and mem_limit or nil,
    host_memory = host_mem,
    mem_ratio = (mem_limit and mem_limit > 0) and (mem / mem_limit) or (host_mem > 0 and mem / host_mem or 0),
    cpu_ratio = cpu,
    pids = pids,
    pids_limit = pids_limit > 0 and pids_limit or nil,
    oom = oom,
  }
end

-- ========== 公开 API ==========

--- 新人监测状态。
--- @param now_ms number|nil
--- @return table
function M.new_state(now_ms)
  return {
    started_ms = tonumber(now_ms) or (vim.uv.now and vim.uv.now() or os.time() * 1000),
    mem_hits = 0,
    cpu_hits = 0,
    pids_hits = 0,
    oom_hits = 0,
    last = nil,
    warnings = 0,
  }
end

--- 观察一次 stats；返回是否应 kill/warn。
--- @param st table monitor state（M.new_state）
--- @param stats table docker stats
--- @param ctx table { memory_limit, pids_limit, nano_cpus, host_memory, now_ms, grace_ms?, limits? }
--- @return table { kill=boolean, warn=boolean, reason=string|nil, snapshot=table }
function M.observe(st, stats, ctx)
  ctx = ctx or {}
  st = st or M.new_state(ctx.now_ms)
  local limits = vim.tbl_extend("force", DEFAULTS, ctx.limits or {})
  local snap = M.normalize(stats, ctx)
  st.last = snap

  local now = tonumber(ctx.now_ms) or (vim.uv.now and vim.uv.now() or os.time() * 1000)
  if st.started_ms and (now - st.started_ms) < (tonumber(limits.grace_ms) or DEFAULTS.grace_ms) then
    return { kill = false, warn = false, snapshot = snap }
  end

  local function hit(key, cond, samples)
    if cond then st[key] = (st[key] or 0) + 1 else st[key] = 0 end
    return (st[key] or 0) >= (samples or limits.sustain_samples)
  end

  local mem_hit = hit("mem_hits",
    (snap.mem_limit and snap.mem_ratio >= limits.mem_limit_ratio)
      or (not snap.mem_limit and snap.mem_ratio >= limits.mem_ratio))
  local cpu_hit = hit("cpu_hits", snap.cpu_ratio >= limits.cpu_ratio)
  local pids_hit = hit("pids_hits",
    (snap.pids_limit and (snap.pids / snap.pids_limit) >= limits.pids_ratio)
      or (snap.pids >= limits.pids_abs))
  local oom_hit = hit("oom_hits", snap.oom == true, limits.oom_samples)

  local reason = nil
  if oom_hit then reason = "OOM_NEAR"
  elseif mem_hit then reason = "MEMORY_EXCEEDED"
  elseif pids_hit then reason = "PIDS_EXCEEDED"
  elseif cpu_hit then reason = "CPU_EXCEEDED" end

  if reason then
    return { kill = true, warn = true, reason = reason, snapshot = snap }
  end
  local warn = snap.mem_ratio >= (limits.mem_ratio - 0.05)
    or snap.cpu_ratio >= (limits.cpu_ratio - 0.05)
  if warn then st.warnings = (st.warnings or 0) + 1 end
  return { kill = false, warn = warn, snapshot = snap }
end

--- 记录一条待报告给 Agent 的通知。
--- @param agent_id string|nil
--- @param text string
function M.push_notice(agent_id, text)
  local key = tostring(agent_id or "")
  local list = state.notices[key]
  if not list then list = {}; state.notices[key] = list end
  list[#list + 1] = tostring(text)
  if #list > DEFAULTS.max_notices then table.remove(list, 1) end
  state.totals = state.totals + 1
end

--- 取出并清空指定 Agent 的通知。
--- @param agent_id string|nil
--- @return string[]
function M.drain(agent_id)
  local key = tostring(agent_id or "")
  local list = state.notices[key]
  if not list or #list == 0 then return {} end
  state.notices[key] = nil
  return list
end

--- 记录一次 kill（指标/测试）。
function M.mark_killed()
  state.killed = state.killed + 1
end

--- 指标。
--- @return table
function M.metrics()
  return { notices = state.totals, killed = state.killed }
end

--- 阈值（供 UI 展示）。
--- @return table
function M.thresholds()
  return vim.deepcopy(DEFAULTS)
end

--- 格式化 kill 报告。
--- @param name string
--- @param reason string
--- @param snap table
--- @return string
function M.kill_text(name, reason, snap)
  snap = snap or {}
  local function mib(n) return string.format("%.1fMiB", (tonumber(n) or 0) / 1024 / 1024) end
  if reason == "MEMORY_EXCEEDED" or reason == "OOM_NEAR" then
    return string.format("[NeoAI] 容器 %s 因内存持续超限已被自动终止（%s / 限制 %s，%s）。",
      tostring(name or "?"), mib(snap.mem_bytes), mib(snap.mem_limit or snap.host_memory), tostring(reason))
  elseif reason == "PIDS_EXCEEDED" then
    return string.format("[NeoAI] 容器 %s 因进程数持续超限已被自动终止（%d / 限制 %s）。",
      tostring(name or "?"), tonumber(snap.pids) or 0, tostring(snap.pids_limit or DEFAULTS.pids_abs))
  elseif reason == "CPU_EXCEEDED" then
    return string.format("[NeoAI] 容器 %s 因 CPU 持续超限已被自动终止（%.0f%%）。",
      tostring(name or "?"), (tonumber(snap.cpu_ratio) or 0) * 100)
  end
  return string.format("[NeoAI] 容器 %s 因资源超限已被自动终止（%s）。", tostring(name or "?"), tostring(reason or "?"))
end

--- 测试/会话结束。
function M.reset()
  state.notices = {}
  state.totals = 0
  state.killed = 0
end

M.DEFAULTS = DEFAULTS

return M
