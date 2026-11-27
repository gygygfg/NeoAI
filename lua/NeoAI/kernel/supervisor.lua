--- 子进程总管理（supervisor）
--- @module 'NeoAI.kernel.supervisor'
---
--- 存在意义：本插件会拉起多个子进程（后台 worker、常驻沙箱命令服务器、会话内后台服务）。
--- 没有统一管理时，子进程崩溃要么把错误抛回主循环（表现为一次 Lua 异常/卡死），要么在
--- 隐藏的循环里无限重启（表现为「莫名其妙越来越慢/越来越吃内存」）。本模块是这些子进程
--- 的**单一状态源与重启策略**：
---
---   * 登记（register）：每个受管进程一个 id + 探测函数（probe）+ 停止函数（stop）；
---   * 崩溃上报（report_crash）：由进程适配器在「确认异常退出」时上报，本模块负责
---     **退避重启计数**与**熔断**（滑动窗口内崩溃过多 → 停止自动重启，进入 failed 并提示，
---     **绝不静默**）；
---   * 心跳（heartbeat）：只做**观测**（对自报进程不重复计崩溃），把状态变化发事件；
---   * 资源限额（apply_limits）：把子进程放进带 memory.max / pids.max 的委派 cgroup，
---     超限时由内核回收**子进程**，而不是宿主 OOM 杀掉 nvim；
---   * 状态（status）：供 `:NeoAI Status` / 诊断 / 测试消费。
---
--- 设计约束：
---   1. 只做策略不做实现：具体启动/停止/探测由适配器注入，本模块不 require 任何服务模块
---      （避免 kernel → services 的反向依赖）。
---   2. **崩溃不向上传导**：`report_crash` 永不抛错，返回值 `"restart"|"stop"` 供适配器决定
---      是否继续重启；熔断后调用方应把在途任务以结构化错误 reject，而不是让异常冒泡。
---   3. 副作用可卸载：`M.start()` 返回 stop（关闭心跳定时器、释放 cgroup）。

local M = {}

local MIB = 1024 * 1024

-- ========== 私有状态 ==========

local state = {
  started = false,
  timer = nil,
  procs = {}, -- id -> record
  order = {}, -- 登记顺序（确定性遍历/展示）
  degraded = false,
  avail_cache = nil, -- { at, avail, level }：压力模块关闭时回退读 /proc 的短缓存
}

-- ========== 私有函数 ==========

--- 取配置（缺失返回空表）
--- @return table
local function _cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("resources.supervisor")
  end)
  if ok and type(cfg) == "table" then return cfg end
  return {}
end

local function _now_ms()
  return math.floor(vim.uv.hrtime() / 1e6)
end

local function _log(level, fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  pcall(function()
    local logger = require("NeoAI.kernel.logger")
    local fn = logger[level] or logger.info
    fn("[supervisor] " .. msg)
  end)
end

--- 发布状态事件（失败不影响调用方）
--- @param rec table
--- @param prev string|nil
--- @param reason string|nil
local function _emit(rec, prev, reason)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(
      require("NeoAI.kernel.events").PROCESS_STATE,
      {
        id = rec.id,
        kind = rec.kind,
        state = rec.state,
        prev = prev,
        restarts = rec.restarts,
        crashes = #rec.crashes,
        reason = reason,
        breaker_open = rec.breaker_open == true,
        pid = rec.pid,
      }
    )
  end)
  if type(rec.on_state) == "function" then
    pcall(rec.on_state, rec.state, prev, rec)
  end
end

--- 状态迁移（幂等；只在变化时发事件）
--- @param rec table
--- @param next_state string
--- @param reason string|nil
local function _set_state(rec, next_state, reason)
  if rec.state == next_state then return end
  local prev = rec.state
  rec.state = next_state
  if next_state == "running" and not rec.pid and type(rec.pid_of) == "function" then
    local ok, pid = pcall(rec.pid_of)
    if ok and tonumber(pid) then rec.pid = tonumber(pid) end
  end
  _emit(rec, prev, reason)
  if next_state == "failed" then
    state.degraded = true
    local cfg = _cfg()
    if cfg.notify ~= false then
      pcall(function()
        vim.schedule(function()
          pcall(vim.notify,
            ("[NeoAI] 子进程 %s 反复崩溃，已停止自动重启（熔断）。\n"
              .. "相关后台能力暂时不可用；可执行 :NeoAI Recover 手动重置后再试。"):format(tostring(rec.kind or rec.id)),
            vim.log.levels.ERROR, { title = "NeoAI 进程守护" })
        end)
      end)
    end
  elseif next_state == "running" then
    -- 任一处恢复即退出降级（除非仍有 failed 进程）
    local any_failed = false
    for _, it in pairs(state.procs) do
      if it.state == "failed" then any_failed = true break end
    end
    state.degraded = any_failed
  end
end

--- 清理窗口外的崩溃记录
--- @param rec table
local function _prune_crashes(rec)
  local cfg = _cfg()
  local window = tonumber(cfg.breaker_window_ms) or 120000
  local now = _now_ms()
  local keep = {}
  for _, ts in ipairs(rec.crashes) do
    if now - ts <= window then keep[#keep + 1] = ts end
  end
  rec.crashes = keep
end

-- ========== 公开 API ==========

--- 登记一个受管子进程（幂等：同 id 再次登记会替换适配器但保留计数）。
--- spec 字段：
---   id        string  唯一标识（必填）
---   kind      string  人类可读类别（默认 id）
---   probe     function() -> boolean|nil  存活探测（nil = 未知，不判定）
---   stop      function()                停止实现（可选）
---   start     function() -> boolean     启动实现（可选，供 `M.ensure()`）
---   self_report boolean  已自带崩溃上报（心跳只观测、不重复计崩溃）
---   limits    table|nil  { memory_bytes, pids }
---   on_state  function(state, prev, rec) 状态变化回调
--- @param spec table
--- @return string id
function M.register(spec)
  if type(spec) ~= "table" or type(spec.id) ~= "string" or spec.id == "" then
    error("[supervisor] register 需要 spec.id", 2)
  end
  local rec = state.procs[spec.id]
  if not rec then
    rec = {
      id = spec.id,
      kind = spec.kind or spec.id,
      state = "stopped",
      restarts = 0,
      crashes = {}, -- 最近崩溃时刻（ms）
      breaker_open = false,
      handle = nil, -- cgroup 委派句柄
      pid = nil,
      seen_alive = false,
    }
    state.procs[spec.id] = rec
    state.order[#state.order + 1] = spec.id
  end
  rec.kind = spec.kind or rec.kind
  rec.probe = spec.probe
  rec.stop = spec.stop
  rec.start = spec.start
  rec.self_report = spec.self_report == true
  rec.pid_of = spec.pid_of
  rec.limits = spec.limits
  rec.on_state = spec.on_state
  return rec.id
end

--- 注销（幂等）。不停止进程本身（停止由持有者负责）。
--- @param id string
function M.unregister(id)
  local rec = state.procs[id]
  if not rec then return end
  state.procs[id] = nil
  for i, v in ipairs(state.order) do
    if v == id then table.remove(state.order, i) break end
  end
  if rec.handle then
    pcall(function()
      require("NeoAI.sandbox.execution.cgroup").release_delegated(rec.handle)
    end)
    rec.handle = nil
  end
end

--- 获取受管进程记录（只读副本，供诊断/测试）
--- @param id string
--- @return table|nil
function M.state(id)
  local rec = state.procs[id]
  if not rec then return nil end
  return {
    id = rec.id, kind = rec.kind, state = rec.state,
    restarts = rec.restarts, crashes = #rec.crashes,
    breaker_open = rec.breaker_open == true, pid = rec.pid,
    memory_limit = rec.memory_limit,
  }
end

--- 上报一次崩溃，返回是否应继续重启。
---
--- 策略：熔断窗口内崩溃次数 ≥ `breaker_threshold`，或连续重启 ≥ `max_restarts`
--- → 打开熔断，返回 `"stop"`；否则重启计数 +1，返回 `"restart"`（适配器按自己的退避
--- 策略重启；本模块负责计数与熔断）。
--- @param id string
--- @param reason string|nil
--- @return string "restart"|"stop"
function M.report_crash(id, reason)
  local ok, res = pcall(function()
    local rec = state.procs[id]
    if not rec then return "restart" end -- 未登记：不干预（保持旧行为）
    local cfg = _cfg()
    if cfg.enabled == false then return "restart" end
    if rec.breaker_open then return "stop" end
    rec.crashes[#rec.crashes + 1] = _now_ms()
    _prune_crashes(rec)
    rec.restarts = rec.restarts + 1
    local threshold = tonumber(cfg.breaker_threshold) or 5
    local max_restarts = tonumber(cfg.max_restarts) or 5
    if #rec.crashes >= threshold or rec.restarts > max_restarts then
      rec.breaker_open = true
      _log("warn", "%s 熔断：窗口内崩溃 %d 次、连续重启 %d 次（最后原因：%s）",
        tostring(rec.kind), #rec.crashes, rec.restarts, tostring(reason))
      _set_state(rec, "failed", reason or "breaker")
      return "stop"
    end
    _log("warn", "%s 崩溃（第 %d 次，原因：%s），按退避重启",
      tostring(rec.kind), rec.restarts, tostring(reason))
    _set_state(rec, "restarting", reason)
    return "restart"
  end)
  if ok and type(res) == "string" then return res end
  return "restart" -- 本模块自身异常绝不阻断进程重启
end

--- 上报一次正常/异常退出（不增加重启计数，仅更新状态）。
--- @param id string
--- @param reason string|nil
function M.report_exit(id, reason)
  local rec = state.procs[id]
  if not rec then return end
  pcall(function()
    if rec.state ~= "failed" then
      _set_state(rec, "stopped", reason)
    end
    rec.pid = nil
    rec.seen_alive = false
  end)
end

--- 标记为「已启动、待确认存活」（spawn 成功但握手/探测尚未完成）。
--- 与 `mark_running` 的区别：**不**把 `seen_alive` 置真——否则首次心跳在连接建立前探测到
--- false 会把状态错误地收敛成 stopped（随后被当成崩溃的前兆）。
--- @param id string
--- @param pid number|nil
--- @return boolean
function M.mark_spawned(id, pid)
  local rec = state.procs[id]
  if not rec then return false end
  rec.pid = tonumber(pid) or rec.pid
  rec.restarts = 0
  if rec.state ~= "starting" then _set_state(rec, "starting") end
  return true
end

--- 标记为运行中（适配器在成功启动后调用；幂等）
--- @param id string
--- @param pid number|nil
function M.mark_running(id, pid)
  local rec = state.procs[id]
  if not rec then return end
  rec.pid = pid
  rec.seen_alive = true
  rec.restarts = 0 -- 成功跑起来即清零连续重启计数（熔断窗口计数仍保留）
  _set_state(rec, "running")
end

--- 标记为已停止（用户主动停止，不触发重启/熔断）
--- @param id string
function M.mark_stopped(id)
  local rec = state.procs[id]
  if not rec then return end
  rec.pid = nil
  rec.seen_alive = false
  _set_state(rec, "stopped")
end

--- 重置熔断（`:NeoAI Recover`）：清空崩溃窗口与重启计数，允许重新拉起。
--- @param id string|nil nil = 全部
function M.reset_breaker(id)
  local function one(rec)
    rec.breaker_open = false
    rec.crashes = {}
    rec.restarts = 0
    if rec.state == "failed" then _set_state(rec, "stopped", "breaker_reset") end
  end
  if id then
    local rec = state.procs[id]
    if rec then one(rec) end
  else
    for _, rec in pairs(state.procs) do one(rec) end
  end
  state.degraded = false
  for _, rec in pairs(state.procs) do
    if rec.state == "failed" then state.degraded = true break end
  end
end

--- 是否处于降级（有熔断进程）
--- @return boolean
function M.degraded()
  return state.degraded == true
end

--- 确保受管进程已运行（调用 spec.start）。返回 ok, err。
--- @param id string
--- @return boolean ok
--- @return any err
function M.ensure(id)
  local rec = state.procs[id]
  if not rec then return false, "unknown process: " .. tostring(id) end
  if rec.breaker_open then return false, "breaker open: " .. tostring(id) end
  if type(rec.start) ~= "function" then return false, "no start adapter: " .. tostring(id) end
  local ok, err = pcall(rec.start, id)
  if not ok or err == false then
    _log("warn", "%s 启动失败: %s", tostring(rec.kind), tostring(err))
    return false, err
  end
  M.mark_running(id)
  return true
end

--- 停止受管进程（调用 spec.stop；失败隔离）
--- @param id string
--- @param opts table|nil
--- @return boolean ok
function M.stop(id, opts)
  local rec = state.procs[id]
  if not rec then return true end
  local ok = true
  if type(rec.stop) == "function" then
    local okc, err = pcall(rec.stop, opts or {})
    if not okc then
      ok = false
      _log("warn", "%s 停止失败: %s", tostring(rec.kind), tostring(err))
    end
  end
  M.mark_stopped(id)
  return ok
end

--- 当前可用内存与压力等级。
--- 优先用 `pressure.inspect()`（启用时有 TTL 缓存）；压力自适应被关闭时回退 `sample()`
--- 直读 /proc（2s 短缓存，避免每个受管进程各读一遍）——动态限额是保命语义，不依赖可选开关。
--- @return number|nil avail_bytes
--- @return string level
local function _avail_now()
  local avail, level = nil, "ok"
  pcall(function()
    local pressure = require("NeoAI.kernel.pressure")
    local snap = pressure.inspect()
    avail = tonumber(snap and snap.mem_available_bytes)
    level = (snap and snap.level) or "ok"
  end)
  if avail and avail > 0 then return avail, level end
  local now = vim.uv.hrtime()
  local cache = state.avail_cache
  if cache and (now - cache.at) < 2e9 then return cache.avail, cache.level end
  pcall(function()
    local raw = require("NeoAI.kernel.pressure").sample()
    avail = tonumber(raw and raw.mem_available_bytes)
  end)
  state.avail_cache = { at = now, avail = avail, level = level }
  return avail, level
end

--- 解析某个受管进程**当前生效**的内存上限（字节）。
---
--- 规则（与 `default_config.resources.supervisor` 注释一致）：
---   * `limits.dynamic == true`（或 `limits.memory == "auto"`）时按**剩余内存动态计算**：
---       cap = MemAvailable × memory_ratio（warn ×0.75、critical ×0.5）
---       再夹到 [memory_min_bytes, MemAvailable − memory_reserve_bytes]，最后与
---       `memory_max_bytes`（>0 时）取 min；
---   * 否则使用显式 `limits.memory_bytes` / 配置 `memory_max_bytes`（>0 才有值）。
--- 探测不到内存信息时退回上限值（绝不因探测失败放大限额）。
--- @param id string
--- @return number|nil bytes nil = 不限制
function M.limit_for(id)
  local rec = state.procs[id]
  local cfg = _cfg()
  local limits = (rec and rec.limits) or {}
  local abs = tonumber(limits.memory_bytes) or tonumber(cfg.memory_max_bytes) or 0
  local dynamic = limits.dynamic == true or limits.memory == "auto"
  if not dynamic or cfg.memory_auto == false then
    return abs > 0 and abs or nil
  end
  local avail, level = _avail_now()
  if not avail or avail <= 0 then return abs > 0 and abs or nil end
  local ratio = tonumber(cfg.memory_ratio) or 0.5
  if level == "warn" then
    ratio = ratio * 0.75
  elseif level == "critical" then
    ratio = ratio * 0.5
  end
  local cap = math.floor(avail * ratio)
  local floor = tonumber(cfg.memory_min_bytes) or 0
  if floor > 0 and cap < floor then cap = floor end
  local reserve = tonumber(cfg.memory_reserve_bytes) or 0
  local headroom = avail - reserve
  if headroom > 0 then
    cap = math.min(cap, headroom)
  else
    -- 可用内存已低于预留：最多给可用的一半，避免子进程一启动就被 OOM 回收
    cap = math.min(cap, math.max(math.floor(avail * 0.5), 64 * MIB))
  end
  if abs > 0 then cap = math.min(cap, abs) end
  if cap < 64 * MIB then cap = 64 * MIB end
  return cap
end

--- 写入（更新）某个受管进程当前 cgroup 的 memory.max。失败返回 false（不抛错）。
--- @param handle table
--- @param bytes number
--- @return boolean
local function _write_memory_max(handle, bytes)
  if type(handle) ~= "table" or not handle.limit_path then return false end
  local ok, f = pcall(io.open, handle.limit_path .. "/memory.max", "w")
  if not ok or not f then return false end
  local wok = f:write(tostring(math.floor(bytes)))
  f:close()
  return wok ~= nil
end

--- 测试钩子：注入/清除受管进程的 cgroup 句柄（让限额刷新逻辑可离线单测）。
--- @param id string
--- @param handle table|nil
function M._set_handle(id, handle)
  local rec = state.procs[id]
  if rec then
    rec.handle = handle
    if not handle then rec.memory_limit = nil end
  end
end

--- 诊断：受管进程当前 cgroup 限额文件路径（未套限额时返回 nil）。
--- @param id string
--- @return string|nil
function M.limit_path_for(id)
  local rec = state.procs[id]
  if rec and rec.handle and rec.handle.limit_path then
    return rec.handle.limit_path .. "/memory.max"
  end
  return nil
end

--- 按**当前剩余内存**刷新所有受管进程的内存上限（心跳周期调用）。
---
--- 改动策略（安全优先、避免抖动）：
---   * 上限**下降立即生效**（内存紧张时第一时间收紧）；
---   * 上限**上升**需超过当前值 20% 才更新（避免可用内存轻微波动导致反复写 cgroup）。
--- 没有 cgroup 句柄的进程只更新记录值（下次套限额时用新值）。
--- @return number changed 实际更新的进程数
function M.refresh_limits()
  local cfg = _cfg()
  if cfg.enabled == false then return 0 end
  local changed = 0
  for _, id in ipairs(state.order) do
    local rec = state.procs[id]
    if rec then
      local want = M.limit_for(id)
      if want ~= nil then
        local cur = rec.memory_limit
        local update
        if cur == nil then
          update = true
        elseif want < cur then
          update = true -- 收紧：立即
        else
          update = want > cur * 1.2 -- 放宽：需要明显改善才更新
        end
        if update then
          if rec.handle then
            if _write_memory_max(rec.handle, want) then
              rec.memory_limit = want
              changed = changed + 1
            end
          else
            rec.memory_limit = want
            changed = changed + 1
          end
        end
      end
    end
  end
  return changed
end

--- 子进程启动回调（适配器在 spawn 成功后调用）：标记运行态并立即套用动态限额。
--- @param id string
--- @param pid number
--- @return boolean ok
function M.on_child_spawn(id, pid)
  if not state.procs[id] then return false end
  M.mark_spawned(id, pid)
  return (M.apply_limits(id, pid))
end

--- 给子进程套上资源限额（best-effort；失败只记日志，绝不阻断启动）。
--- 限额生效时，超限由内核回收**子进程**，宿主（nvim）不会被 OOM 选中。
--- @param id string
--- @param pid number
--- @return boolean ok
--- @return string|nil err
function M.apply_limits(id, pid)
  local rec = state.procs[id]
  local cfg = _cfg()
  local limits = rec and rec.limits or {}
  local mem = M.limit_for(id) or 0
  local pids = tonumber(limits.pids) or tonumber(cfg.pids_max) or 0
  if mem <= 0 and pids <= 0 then return true, nil end
  if not pid or pid <= 0 then return false, "invalid pid" end
  -- 幂等：同一 pid 已有句柄时**只更新上限**，绝不重建——重建会 `cgroup.kill` 掉该域内
  -- 正在运行的子进程（spawn 回调 + 心跳补齐可能对同一进程各调用一次）。
  if rec and rec.handle and rec.pid == tonumber(pid) then
    if mem > 0 and _write_memory_max(rec.handle, mem) then
      rec.memory_limit = mem
    end
    return true, nil
  end
  local ok, cg = pcall(require, "NeoAI.sandbox.execution.cgroup")
  if not ok or type(cg) ~= "table" or type(cg.prepare_delegated) ~= "function" then
    _log("debug", "%s 限额跳过：cgroup 模块不可用", tostring(id))
    return false, "cg_unavailable"
  end
  local handle, err = cg.prepare_delegated("sv_" .. tostring(id), {
    memory_bytes = mem > 0 and mem or nil,
    pids = pids > 0 and pids or nil,
  })
  if not handle then
    _log("debug", "%s 限额跳过：%s", tostring(id), tostring(err))
    return false, err
  end
  local procs = handle.path .. "/cgroup.procs"
  local f = io.open(procs, "w")
  if not f then
    pcall(cg.release_delegated, handle)
    return false, "write cgroup.procs failed"
  end
  f:write(tostring(pid))
  f:close()
  if rec then
    if rec.handle then pcall(cg.release_delegated, rec.handle) end
    rec.handle = handle
    rec.memory_limit = mem > 0 and mem or nil
  end
  _log("info", "%s 已套用限额：memory=%s pids=%s", tostring(id),
    mem > 0 and (math.floor(mem / MIB) .. " MB") or "-", pids > 0 and tostring(pids) or "-")
  return true, nil
end

--- 心跳巡检一次（观测 + 状态收敛；不重复计崩溃）
--- @return table 状态摘要
function M.heartbeat_once()
  -- 先按当前剩余内存刷新限额（cgroup memory.max 可在线更新），再探测存活。
  pcall(M.refresh_limits)
  for _, id in ipairs(state.order) do
    local rec = state.procs[id]
    if rec and type(rec.probe) == "function" then
      local ok, alive = pcall(rec.probe)
      if ok and type(alive) == "boolean" then
        if alive then
          if not rec.seen_alive then
            rec.seen_alive = true
            if rec.state ~= "running" then _set_state(rec, "running") end
          end
          -- 已经跑起来但还没套限额（典型：后台 worker 在本插件启动前就被拉起，
          -- 或 spawn 回调缺失）：心跳补齐一次。失败只记日志，不影响探测。
          if not rec.handle and rec.state == "running" then
            local ok_pid, pid = false, nil
            if type(rec.pid_of) == "function" then ok_pid, pid = pcall(rec.pid_of) end
            if ok_pid and tonumber(pid) then
              rec.pid = tonumber(pid)
              pcall(M.apply_limits, id, rec.pid)
            end
          end
        elseif rec.seen_alive then
          rec.seen_alive = false
          if not rec.self_report and not rec.breaker_open then
            -- 外部进程（不自报）：心跳发现失活即按崩溃处理
            M.report_crash(id, "heartbeat")
          else
            -- 自报进程：交给适配器上报（避免重复计数），这里只收敛展示状态
            if rec.state == "running" or rec.state == "restarting" then
              _set_state(rec, "stopped", "heartbeat")
            end
          end
        end
      end
    end
  end
  return M.status()
end

--- 全部受管进程状态摘要
--- @return table { processes = table[], degraded = boolean }
function M.status()
  local list = {}
  for _, id in ipairs(state.order) do
    local rec = state.procs[id]
    if rec then
      list[#list + 1] = {
        id = rec.id, kind = rec.kind, state = rec.state,
        restarts = rec.restarts, crashes = #rec.crashes,
        breaker_open = rec.breaker_open == true, pid = rec.pid,
        memory_limit = rec.memory_limit,
      }
    end
  end
  return { processes = list, degraded = M.degraded() }
end

--- 人类可读摘要（Status/health 用）
--- @return string
function M.describe()
  local parts = {}
  for _, p in ipairs(M.status().processes) do
    local text = ("%s=%s"):format(tostring(p.kind), tostring(p.state))
    if p.restarts > 0 then text = text .. ("(重启%d)"):format(p.restarts) end
    if p.breaker_open then text = text .. "(熔断)" end
    if p.memory_limit then text = text .. ("(mem≤%dMB)"):format(math.floor(p.memory_limit / MIB)) end
    parts[#parts + 1] = text
  end
  if #parts == 0 then return "无受管进程" end
  return table.concat(parts, "，")
end

-- ========== 内置适配器 ==========

--- 登记内置适配器（后台 worker / 常驻沙箱服务器）。
--- 两者都**自报崩溃**（见 `utils/remote_work` 与 `sandbox/execution/resident`），
--- 心跳只做观测，避免一次崩溃被记两次。
local function _register_builtins()
  local ok_cfg, tools_cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("tools") or {}
  end)
  if ok_cfg and type(tools_cfg) == "table" and (tools_cfg.worker or {}).enabled ~= false then
    M.register({
      id = "worker",
      kind = "后台 worker",
      self_report = true,
      -- 后台 worker 是内存大户（捕获/冻结/哈希/编码）：按剩余内存动态限额。
      limits = { dynamic = true },
      probe = function()
        local ok, rw = pcall(require, "NeoAI.utils.remote_work")
        if not ok or type(rw) ~= "table" or type(rw.status) ~= "function" then return nil end
        local st = rw.status()
        return st and st.connected == true
      end,
      pid_of = function()
        local ok, rw = pcall(require, "NeoAI.utils.remote_work")
        if not ok or type(rw) ~= "table" or type(rw.status) ~= "function" then return nil end
        local st = rw.status()
        return st and st.pid or nil
      end,
      stop = function()
        local ok, rw = pcall(require, "NeoAI.utils.remote_work")
        if ok and type(rw) == "table" and type(rw.stop) == "function" then rw.stop(1000) end
      end,
    })
  end
  M.register({
    id = "sandbox.resident",
    kind = "常驻沙箱命令服务器",
    self_report = true,
    probe = function()
      local ok, res = pcall(require, "NeoAI.sandbox.execution.resident")
      if not ok or type(res) ~= "table" or type(res.active) ~= "function" then return nil end
      return res.active() ~= nil
    end,
    stop = function()
      local ok, res = pcall(require, "NeoAI.sandbox.execution.resident")
      if ok and type(res) == "table" and type(res.stop) == "function" then res.stop({ timeout_ms = 2000 }) end
    end,
  })
end

--- 启动总管理（幂等）：登记内置适配器 + 启动心跳。返回 stop 函数（插件卸载时调用）。
--- @return function stop
function M.start()
  local cfg = _cfg()
  if cfg.enabled == false then return function() end end
  if state.started then return function() M.shutdown() end end
  state.started = true
  _register_builtins()
  -- 追赶：内置适配器登记前 worker 可能已被别的插件拉起（如模型列表刷新触发 work 任务），
  -- 此时 spawn 回调已错过——立即按当前状态补标记与动态限额。
  vim.schedule(function()
    if not state.started then return end
    pcall(M.heartbeat_once)
  end)
  local interval = tonumber(cfg.heartbeat_ms) or 5000
  if interval > 0 then
    local timer = vim.uv.new_timer()
    state.timer = timer
    timer:start(interval, interval, vim.schedule_wrap(function()
      if not state.started then return end
      pcall(M.heartbeat_once)
    end))
  end
  return function() M.shutdown() end
end

--- 停止总管理（幂等）：关闭心跳；**不**主动停止受管进程（其持有者负责）。
--- 注意与 `M.stop(id)`（停止单个受管进程）区分。
function M.shutdown()
  state.started = false
  if state.timer then
    pcall(function() state.timer:stop() end)
    pcall(function() state.timer:close() end)
    state.timer = nil
  end
end

-- ========== 测试钩子 ==========

--- 清空全部状态（测试用）
function M.reset()
  M.shutdown()
  state.avail_cache = nil
  for id in pairs(state.procs) do M.unregister(id) end
  state.procs = {}
  state.order = {}
  state.degraded = false
  state.started = false
end

return M
