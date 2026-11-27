--- 自身内存看门狗（保命层）
--- @module 'NeoAI.kernel.self_guard'
---
--- 存在意义：沙箱/工具循环在**本进程内**做重活时，一旦内存无界增长，内核会直接 OOM
--- 杀掉 nvim（2026-11-27 实测：anon-rss 27.2 GB + swap 4.4 GB → SIGKILL），整个交互面
--- 消失，连保存错误日志的机会都没有。本模块在到达内核红线之前主动收敛：
---
---   ok   → 无动作
---   soft → 触发已注册的回收器（释放可释放缓存）+ 强制 GC，允许继续
---   hard → 回收 + GC 后重新采样仍超限：通知注册的中止器结束当前回合（会话已按轮落盘），
---          并进入 cooldown（期间拒绝新回合），直到回落
---
--- 设计约束（重要）：
---   1. 采样只读 `/proc/self/status`（VmRSS/VmHWM）与一次 `collectgarbage("count")`，
---      内存总量复用 `kernel.pressure` 的 TTL 缓存；热路径只读本模块缓存，绝不重复读 /proc。
---   2. **绝不主动退出 nvim**，也绝不直接 require 服务/沙箱实现：回收器与中止器都经
---      注册表注入（由各自插件在自己的 start/stop 里注册/注销），保持卸载可逆。
---   3. 探测不到 `/proc`（Android/裁剪容器）时一律视为 ok——探测不到绝不误伤。
---   4. 本模块与「沙箱安全强制层」无关：任何等级下 seccomp/capability/命名空间都不降级。
---
--- 用法：
---   local guard = require("NeoAI.kernel.self_guard")
---   local stop = guard.start()               -- 定时巡检（插件 start 返回 stop）
---   local unregister = guard.register_reclaimer("sandbox_cache", fn)
---   guard.set_abort_handler(function(reason, snap) ... end)

local M = {}

-- ========== 私有常量 ==========

local MIB = 1024 * 1024

--- 等级排序（数值越大越危险）
local RANK = { ok = 0, soft = 1, hard = 2 }

-- ========== 私有状态 ==========

local state = {
  cached = nil, -- 最近一次快照
  cached_at = 0, -- 快照时刻（hrtime 纳秒）
  level = nil, -- 最近一次对外发布的等级
  cooldown_until = 0, -- hard 触发后的冷静期截止时刻（hrtime 纳秒）
  reclaimed_at = nil, -- 本等级内回收器最近一次执行时刻（避免软阈值反复触发）
  notified = {}, -- level -> true：本次进入该等级是否已提示
  reclaimers = {}, -- 有序数组 { name, fn }
  abort_handler = nil, -- function(reason: string, snap: table)
  listeners = {}, -- on_change 回调
  timer = nil, -- uv timer
  sampler = nil, -- 测试注入的采样函数
  started = false,
}

-- ========== 私有函数 ==========

--- 读取整份文本文件（失败返回 nil，绝不抛错）
--- @param path string
--- @return string|nil
local function _read(path)
  local ok, f = pcall(io.open, path, "r")
  if not ok or not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

--- 取当前配置（缺失时返回空表，模块可独立使用）
--- @return table
local function _cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("resources.self_guard")
  end)
  if ok and type(cfg) == "table" then return cfg end
  return {}
end

--- 宿主内存总量（字节）。复用压力模块的 TTL 缓存；不可用返回 nil。
--- @return number|nil
local function _mem_total()
  local ok, p = pcall(require, "NeoAI.kernel.pressure")
  if not ok or type(p) ~= "table" then return nil end
  local ok2, snap = pcall(p.inspect)
  if not ok2 or type(snap) ~= "table" then return nil end
  local total = tonumber(snap.mem_total_bytes)
  if total and total > 0 then return total end
  return nil
end

--- 真实采样：本进程 RSS/峰值 + Lua 堆 + 宿主内存总量。
--- @return table|nil
local function _sample_real()
  local data = _read("/proc/self/status")
  if not data then return nil end
  local function kb(field)
    local v = data:match(field .. ":%s*(%d+)")
    return v and tonumber(v) * 1024 or nil
  end
  local rss = kb("VmRSS")
  if not rss then return nil end
  local lua_kb = 0
  pcall(function() lua_kb = collectgarbage("count") or 0 end)
  return {
    rss_bytes = rss,
    peak_bytes = kb("VmHWM") or rss,
    lua_bytes = math.floor((tonumber(lua_kb) or 0) * 1024),
    mem_total_bytes = _mem_total(),
    at = vim.uv.hrtime(),
  }
end

--- 阈值（配置优先；取「绝对值」与「MemTotal × 比例」中的**较小者**）。
--- 取较小者的理由：绝对值（默认 soft 2 GB / hard 4 GB）在小内存机上远高于可用内存，若取
--- 较大者则永远不会在 OOM 之前触发；比例在大内存机上给出更大的余量。两者取小可同时满足
--- 「小机器提前收敛」与「大机器不因绝对值过早中止」。大内存机上行 4 GB 已属病态，需要更
--- 宽松可在配置里调大 `hard_mb`。
--- @param cfg table
--- @param sample table
--- @param kind string "soft"|"hard"
--- @return number
local function _threshold(cfg, sample, kind)
  local abs = tonumber(cfg[kind .. "_mb"]) or (kind == "hard" and 4096 or 2048)
  local ratio = tonumber(cfg[kind .. "_ratio"])
  if ratio == nil then ratio = (kind == "hard") and 0.40 or 0.25 end
  local bytes = abs * MIB
  local total = tonumber(sample.mem_total_bytes) or 0
  if ratio > 0 and total > 0 then
    bytes = math.min(bytes, total * ratio)
  end
  return bytes
end

--- 发布等级变化（事件 + 监听器；提示仅每次进入该等级一次）
--- @param snap table
local function _publish(snap)
  local prev = state.level
  state.level = snap.level
  if prev == snap.level then return end
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(
      require("NeoAI.kernel.events").SELF_GUARD,
      {
        level = snap.level,
        prev = prev,
        rss_bytes = snap.rss_bytes,
        peak_bytes = snap.peak_bytes,
        lua_bytes = snap.lua_bytes,
        mem_total_bytes = snap.mem_total_bytes,
        actions = snap.actions or {},
      }
    )
  end)
  for _, cb in ipairs(state.listeners) do pcall(cb, snap.level, prev, snap) end
  if snap.level == "ok" then
    state.notified = {}
    return
  end
  if state.notified[snap.level] then return end
  state.notified[snap.level] = true
  local cfg = _cfg()
  if cfg.notify == false then return end
  pcall(function()
    vim.schedule(function()
      local text
      if snap.level == "hard" then
        text = ("[NeoAI] 本进程内存过高（RSS %d MB，峰值 %d MB），已请求结束当前回合以保住编辑器。\n"
          .. "会话已按轮落盘；内存回落后可继续对话。若反复出现，请用 :NeoAI Status 查看内存与进程状态。")
          :format(math.floor((snap.rss_bytes or 0) / MIB), math.floor((snap.peak_bytes or 0) / MIB))
      else
        text = ("[NeoAI] 本进程内存偏高（RSS %d MB），已释放可释放缓存并回收 Lua 堆。")
          :format(math.floor((snap.rss_bytes or 0) / MIB))
      end
      pcall(vim.notify, text, vim.log.levels.WARN, { title = "NeoAI 内存看门狗" })
    end)
  end)
end

--- 依次调用回收器（失败不影响后续；失败记日志）
--- @param reason string
--- @return string[] ran
local function _run_reclaimers(reason)
  local ran = {}
  for _, item in ipairs(state.reclaimers) do
    local ok, freed = pcall(item.fn, reason)
    if ok then
      ran[#ran + 1] = item.name
    else
      pcall(function()
        require("NeoAI.kernel.logger").warn(
          "[self_guard] 回收器 %s 失败: %s", tostring(item.name), tostring(freed))
      end)
    end
  end
  pcall(collectgarbage, "collect")
  return ran
end

--- 采样（TTL 缓存；`force=true` 时绕过缓存）
--- @param force boolean
--- @return table
local function _snapshot(force)
  local cfg = _cfg()
  local ttl = tonumber(cfg.sample_ttl_ms) or 1000
  local now = vim.uv.hrtime()
  if not force and state.cached and (now - state.cached_at) < ttl * 1e6 then
    return state.cached
  end
  -- 注意：不能写 `state.sampler and state.sampler() or _sample_real()`——采样函数返回 nil
  -- （探测不可用）时 `or` 会回退到真实采样，破坏「探测不到即 ok」的约定。
  local sample
  if type(state.sampler) == "function" then
    sample = state.sampler()
  else
    sample = _sample_real()
  end
  if type(sample) ~= "table" then
    -- 探测不可用：一律视为 ok，且不缓存（下次再试）
    return { level = "ok", unavailable = true, at = now }
  end
  local snap = {
    level = M.classify(sample, cfg),
    rss_bytes = sample.rss_bytes,
    peak_bytes = sample.peak_bytes,
    lua_bytes = sample.lua_bytes,
    mem_total_bytes = sample.mem_total_bytes,
    at = now,
  }
  state.cached = snap
  state.cached_at = now
  return snap
end

-- ========== 公开 API ==========

--- 采样本进程内存（**不做缓存**，消费方请用 `M.status()`；诊断/测试用）
--- @return table|nil { rss_bytes, peak_bytes, lua_bytes, mem_total_bytes, at }
function M.sample()
  return _sample_real()
end

--- 依采样值与配置判定等级（纯函数：不读文件系统，便于阈值边界单测）
--- 判定顺序：先 hard 后 soft；采样缺失视为 ok（探测不到绝不误伤）。
--- @param sample table|nil
--- @param cfg table|nil
--- @return string "ok"|"soft"|"hard"
function M.classify(sample, cfg)
  cfg = cfg or _cfg()
  if type(sample) ~= "table" then return "ok" end
  local rss = tonumber(sample.rss_bytes) or 0
  if rss <= 0 then return "ok" end
  if rss >= _threshold(cfg, sample, "hard") then return "hard" end
  local lua_limit = tonumber(cfg.lua_heap_mb)
  if lua_limit and lua_limit > 0 and (tonumber(sample.lua_bytes) or 0) >= lua_limit * MIB then
    return "soft"
  end
  if rss >= _threshold(cfg, sample, "soft") then return "soft" end
  return "ok"
end

--- 当前快照（TTL 缓存）。
--- @return table { level, rss_bytes?, peak_bytes?, lua_bytes?, mem_total_bytes?, unavailable? }
function M.status()
  return _snapshot(false)
end

--- 当前等级
--- @return string "ok"|"soft"|"hard"
function M.level()
  return M.status().level or "ok"
end

--- 执行一次巡检（定时器与工具边界都会调用；有 TTL 缓存，可安全高频调用）
---
--- 行为：soft/hard 先跑回收器 + GC；hard 回收后**重新采样**，仍超限才调用中止器并进入
--- cooldown。返回 `level`（巡检结论）、`snap`（快照）、`actions`（已执行动作名数组）、
--- `still_hard`（硬阈值回收后仍超限）。
--- @param opts table|nil { force?: boolean, reason?: string, abort?: boolean }
--- @return string level
--- @return table snap
--- @return string[] actions
--- @return boolean still_hard
function M.check(opts)
  opts = opts or {}
  local cfg = _cfg()
  if cfg.enabled == false then
    return "ok", { level = "ok", disabled = true }, {}, false
  end
  local snap = _snapshot(opts.force == true)
  local level = snap.level or "ok"
  local actions = {}
  if level ~= "ok" then
    actions = _run_reclaimers(opts.reason or "self_guard")
    state.reclaimed_at = vim.uv.hrtime()
    pcall(function()
      require("NeoAI.sandbox.review.evidence").add("self_guard_" .. tostring(level), {
        rss_bytes = snap.rss_bytes, peak_bytes = snap.peak_bytes,
        lua_bytes = snap.lua_bytes, reason = tostring(opts.reason or "self_guard"),
      })
    end)
  end
  if level == "hard" then
    snap = _snapshot(true)
    level = snap.level or "ok"
    if level == "hard" and opts.abort ~= false then
      local reason = opts.reason or "self_guard"
      local handled = false
      if type(state.abort_handler) == "function" then
        local ok, res = pcall(state.abort_handler, reason, snap)
        handled = ok and res == true
      end
      -- 仅当**确实中止了在途工作**才进入冷静期：若当前没有回合在跑，超限多来自可回收缓存，
      -- 此时拒绝新回合既无益又会让用户摸不着头脑（回收器 + GC 已执行，交给下一次巡检观察）。
      if handled then
        local cool = tonumber(cfg.cooldown_ms) or 15000
        state.cooldown_until = vim.uv.hrtime() + math.max(0, cool) * 1e6
        actions[#actions + 1] = "abort"
      else
        actions[#actions + 1] = "over_limit"
      end
      pcall(function()
        require("NeoAI.sandbox.review.evidence").add("self_guard_hard", {
          rss_bytes = snap.rss_bytes, peak_bytes = snap.peak_bytes,
          lua_bytes = snap.lua_bytes, handled = handled == true, reason = tostring(reason),
        })
      end)
      pcall(function()
        require("NeoAI.kernel.logger").warn(
          "[self_guard] 内存超硬阈值（RSS %d MB / 峰值 %d MB，Lua 堆 %d MB）：%s",
          math.floor((snap.rss_bytes or 0) / MIB),
          math.floor((snap.peak_bytes or 0) / MIB),
          math.floor((snap.lua_bytes or 0) / MIB),
          handled and "已中止当前回合" or "中止器不可用，进入冷静期")
      end)
      snap.actions = actions
      _publish(snap)
      return level, snap, actions, true
    end
  end
  snap.actions = actions
  _publish(snap)
  return level, snap, actions, false
end

--- 是否允许开始新回合（hard 触发后的 cooldown 内为 false）
--- @return boolean
function M.allow_start()
  local cfg = _cfg()
  if cfg.enabled == false then return true end
  if vim.uv.hrtime() < state.cooldown_until then return false end
  -- 冷静期已过但内存仍超硬阈值：先做一次（带缓存的）巡检，仍超限则继续拒绝
  local level = M.level()
  if level == "hard" then
    local _, _, _, still = M.check({ force = false, reason = "allow_start", abort = false })
    if still then
      local cool = tonumber(cfg.cooldown_ms) or 15000
      state.cooldown_until = vim.uv.hrtime() + math.max(0, cool) * 1e6
      return false
    end
  end
  return true
end

--- 注册缓存回收器（返回注销函数）。回收器应**只释放可释放的内存**（渲染缓存、候选缓存、
--- 缓冲区副本等），不得影响正确性；抛错会被隔离。
--- @param name string 诊断名
--- @param fn function(reason: string)
--- @return function unregister
function M.register_reclaimer(name, fn)
  if type(name) ~= "string" or type(fn) ~= "function" then return function() end end
  local item = { name = name, fn = fn }
  state.reclaimers[#state.reclaimers + 1] = item
  local removed = false
  return function()
    if removed then return end
    removed = true
    for i, it in ipairs(state.reclaimers) do
      if it == item then
        table.remove(state.reclaimers, i)
        break
      end
    end
  end
end

--- 设置中止器（结束当前回合；返回 true 表示确实中止了在途工作）。返回注销函数。
--- @param fn function(reason: string, snap: table): boolean
--- @return function unregister
function M.set_abort_handler(fn)
  state.abort_handler = type(fn) == "function" and fn or nil
  local mine = state.abort_handler
  return function()
    if state.abort_handler == mine then state.abort_handler = nil end
  end
end

--- 注册等级变化回调（返回注销函数）
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

--- 人类可读的一行描述（Status/health 用）
--- @return string
function M.describe()
  local snap = M.status()
  if snap.disabled then return "自身内存看门狗已关闭（resources.self_guard.enabled=false）" end
  if snap.unavailable then return "自身内存看门狗：/proc 不可用（视为 ok）" end
  return ("等级=%s，RSS=%d MB，峰值=%d MB，Lua 堆=%d MB")
    :format(tostring(snap.level),
      math.floor((snap.rss_bytes or 0) / MIB),
      math.floor((snap.peak_bytes or 0) / MIB),
      math.floor((snap.lua_bytes or 0) / MIB))
end

--- 启动定时巡检（幂等）。返回 stop 函数（插件卸载时调用）。
--- @return function stop
function M.start()
  local cfg = _cfg()
  if cfg.enabled == false then return function() end end
  if state.started then
    return function() M.stop() end
  end
  state.started = true
  local interval = math.max(500, tonumber(cfg.sample_ttl_ms) or 1000)
  local timer = vim.uv.new_timer()
  state.timer = timer
  timer:start(interval, interval, vim.schedule_wrap(function()
    if not state.started then return end
    pcall(M.check, { reason = "timer" })
  end))
  -- 冷启动先采样一次（带缓存后续复用），尽早发现「上一轮遗留的高占用」
  pcall(M.check, { reason = "start" })
  return function() M.stop() end
end

--- 停止定时巡检（幂等）
function M.stop()
  state.started = false
  if state.timer then
    pcall(function() state.timer:stop() end)
    pcall(function() state.timer:close() end)
    state.timer = nil
  end
end

-- ========== 测试钩子 ==========

--- 注入自定义采样函数（测试用；传 nil 恢复真实采样）
--- @param fn function|nil
function M._set_sampler(fn)
  state.sampler = fn
  M.reset()
end

--- 清空缓存与等级状态（**不**清空已注册的回收器/中止器/监听器）
function M.reset()
  state.cached = nil
  state.cached_at = 0
  state.level = nil
  state.cooldown_until = 0
  state.reclaimed_at = nil
  state.notified = {}
end

return M
