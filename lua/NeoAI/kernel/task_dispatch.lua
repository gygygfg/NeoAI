--- 任务分发（dispatching）
--- @module 'NeoAI.kernel.task_dispatch'
---
--- 存在意义：把「用户正在等的重活」与「可以延后的后台活」分开调度，并为每个任务加
--- 超时 / 重试 / 取消 / 排队上限，使**单个任务的失败只让该任务失败**，不会把异常或
--- 内存压力向上传导到 nvim 主循环（历史上一条失控命令能把宿主吃进 27 GB 被内核杀掉）。
---
--- 通道（lane）：
---   interactive — 用户正在等待的任务（工具执行、审批后的落盘、恢复动作）
---   background  — 可延后的任务（预热、批量冻结、编码、回收）
---
--- 压力联动（`resources.pressure`）：
---   warn     → 暂停 background 通道（在途任务继续跑完）
---   critical → 拒绝一切新任务（只允许在途任务收尾）
---
--- 约定：
---   * `run(ctx)` 可返回普通值或 Deferred；抛错/拒绝一律转成结构化错误
---     `{ kind = item.kind, message = ..., timeout = bool, cancelled = bool }`。
---   * 本模块不实现任何具体工作，也不 require 服务模块（kernel 只依赖 kernel/utils）。
---   * 无副作用可卸载：不使用定时器/全局键位，`M.reset()` 即可完全清空。

local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有状态 ==========

-- 前向声明：_settle / _retry_or_fail 在定义顺序上先于调度函数引用它们。
local _pump
local _retry_or_fail

local state = {
  seq = 0,
  lanes = {
    interactive = { name = "interactive", active = 0, queue = {} },
    background = { name = "background", active = 0, queue = {} },
  },
  items = {}, -- id -> item（用于取消/诊断）
  counters = { submitted = 0, completed = 0, failed = 0, timeout = 0, cancelled = 0, rejected = 0 },
}

-- ========== 私有函数 ==========

--- 取配置（缺失返回空表）
--- @return table
local function _cfg()
  local ok, cfg = pcall(function()
    return require("NeoAI.kernel.config_store").get("resources.dispatch")
  end)
  if ok and type(cfg) == "table" then return cfg end
  return {}
end

--- 取通道配置的并发度
--- @param lane string
--- @return number
local function _parallel(lane)
  local cfg = _cfg()
  local n = tonumber(cfg[lane .. "_parallel"])
  if n == nil then n = (lane == "interactive") and 4 or 2 end
  return math.max(1, math.floor(n))
end

--- 当前是否允许在该通道提交/启动任务（压力联动）
--- @param lane string
--- @return boolean ok
--- @return string|nil reason
local function _admit(lane)
  local cfg = _cfg()
  if cfg.enabled == false then return true end
  local ok, pressure = pcall(require, "NeoAI.kernel.pressure")
  if not ok or type(pressure) ~= "table" or type(pressure.level) ~= "function" then
    return true
  end
  local lvl = pressure.level()
  if lvl == "critical" and cfg.pause_all_on_critical ~= false then
    return false, "pressure:critical"
  end
  if lane == "background" and lvl ~= "ok" and cfg.pause_background_on_warn ~= false then
    return false, "pressure:" .. tostring(lvl)
  end
  return true
end

--- 发布任务状态事件（失败不影响调度）
--- @param item table
--- @param st string
--- @param err any
local function _emit(item, st, err)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(
      require("NeoAI.kernel.events").TASK_STATE,
      {
        id = item.id, kind = item.kind, lane = item.lane, state = st,
        error = err and (type(err) == "table" and err.message or tostring(err)) or nil,
      }
    )
  end)
end

--- 统一错误文本
--- @param err any
--- @return string
local function _err_text(err)
  if type(err) == "table" then return tostring(err.message or err.kind or "task error") end
  return tostring(err)
end

--- 结束一个任务（幂等）：清定时器、出账、resolve/reject、回填队列
--- @param item table
--- @param ok boolean
--- @param value any
local function _settle(item, ok, value)
  if item.settled then return end
  item.settled = true
  local lane = state.lanes[item.lane]
  if item.timer then
    pcall(function() item.timer:stop() end)
    pcall(function() item.timer:close() end)
    item.timer = nil
  end
  state.items[item.id] = nil
  if lane then lane.active = math.max(0, lane.active - 1) end
  if ok then
    state.counters.completed = state.counters.completed + 1
    _emit(item, "completed")
    pcall(function() item.d:resolve(value) end)
  else
    local st = "failed"
    if type(value) == "table" and value.timeout then st = "timeout" end
    if type(value) == "table" and value.cancelled then st = "cancelled" end
    if st == "timeout" then
      state.counters.timeout = state.counters.timeout + 1
    elseif st == "cancelled" then
      state.counters.cancelled = state.counters.cancelled + 1
    else
      state.counters.failed = state.counters.failed + 1
    end
    _emit(item, st, value)
    pcall(function() item.d:reject(value) end)
  end
  _pump(item.lane)
end

--- 实际执行一个任务
--- @param item table
local function _run(item)
  local lane = state.lanes[item.lane]
  lane.active = lane.active + 1
  item.state = "running"
  _emit(item, "running")
  local cfg = _cfg()
  local timeout = tonumber(item.timeout_ms)
  if timeout == nil then timeout = tonumber(cfg.task_timeout_ms) or 120000 end
  if timeout > 0 then
    local timer = vim.uv.new_timer()
    item.timer = timer
    timer:start(timeout, 0, vim.schedule_wrap(function()
      if item.settled then return end
      item.cancelled = true
      if type(item.on_cancel) == "function" then pcall(item.on_cancel, "timeout") end
      _settle(item, false, {
        kind = item.kind, timeout = true,
        message = ("任务超时（%dms）：%s"):format(timeout, tostring(item.label or item.kind)),
      })
    end))
  end
  -- 上下文：调用方可据此检测取消（超时/主动取消），避免白做功
  local ctx = {
    id = item.id,
    lane = item.lane,
    cancelled = function() return item.cancelled == true end,
  }
  local ok, res = pcall(item.run, ctx)
  if not ok then
    -- 同步抛错：不再重试（重试只针对可重复的失败，由调用方显式开启）
    _settle(item, false, { kind = item.kind, message = _err_text(res), thrown = true })
    return
  end
  if type(res) == "table" and type(res.then_) == "function" then
    res:then_(function(v)
      _settle(item, true, v)
    end, function(err)
      _retry_or_fail(item, err)
    end)
    return
  end
  _settle(item, true, res)
end

--- 失败后按重试次数决定重排或结束
--- @param item table
--- @param err any
_retry_or_fail = function(item, err)
  if item.settled then return end
  if item.cancelled then
    _settle(item, false, { kind = item.kind, cancelled = true, message = "任务已取消" })
    return
  end
  if (tonumber(item.retries) or 0) > 0 then
    item.retries = item.retries - 1
    item.state = "queued"
    local lane = state.lanes[item.lane]
    if lane then
      lane.active = math.max(0, lane.active - 1)
      lane.queue[#lane.queue + 1] = item
    end
    if item.timer then
      pcall(function() item.timer:stop() end)
      pcall(function() item.timer:close() end)
      item.timer = nil
    end
    _emit(item, "queued", err)
    _pump(item.lane)
    return
  end
  _settle(item, false, { kind = item.kind, message = _err_text(err), cause = err })
end

--- 回填队列：在并发与准入允许时启动排队任务
--- @param lane_name string
_pump = function(lane_name)
  local lane = state.lanes[lane_name]
  if not lane then return end
  local cfg = _cfg()
  while #lane.queue > 0 and lane.active < _parallel(lane_name) do
    local admitted, reason = _admit(lane_name)
    if not admitted then
      -- 压力过高：保持排队（不丢弃），由下一次 settle 或外部 `M.pump()` 重试
      if not lane.paused_logged then
        lane.paused_logged = true
        pcall(function()
          require("NeoAI.kernel.logger").info(
            "[dispatch] %s 通道暂停：%s", lane_name, tostring(reason))
        end)
      end
      return
    end
    lane.paused_logged = false
    local item = table.remove(lane.queue, 1)
    if item and not item.settled and not item.cancelled then
      _run(item)
    end
  end
  if cfg.enabled == false then return end
end

-- ========== 公开 API ==========

--- 提交一个任务。返回 Deferred（不会抛错；失败以结构化错误 reject）。
--- spec 字段：
---   kind        string  任务类别（诊断/事件用）
---   label       string  人类可读描述（可选）
---   lane        string  "interactive"（默认）| "background"
---   run         function(ctx) -> value|Deferred  实际工作（必填）
---   timeout_ms  number  超时（默认 resources.dispatch.task_timeout_ms）
---   retries     number  失败重试次数（默认 0；仅幂等任务应开启）
---   on_cancel   function(reason)  超时/取消时的清理回调（可选）
--- @param spec table
--- @return table Deferred
function M.submit(spec)
  if type(spec) ~= "table" or type(spec.run) ~= "function" then
    return async.reject({ kind = "dispatch", message = "submit 需要 spec.run" })
  end
  local lane_name = spec.lane == "background" and "background" or "interactive"
  local lane = state.lanes[lane_name]
  local cfg = _cfg()
  if cfg.enabled == false then
    -- 关闭分发：等价「直通」，仍保证异常不冒泡
    local d = async.Deferred.new()
    local ok, res = pcall(spec.run, { cancelled = function() return false end })
    if not ok then
      d:reject({ kind = spec.kind or "task", message = _err_text(res), thrown = true })
    elseif type(res) == "table" and type(res.then_) == "function" then
      res:then_(function(v) d:resolve(v) end, function(e) d:reject(e) end)
    else
      d:resolve(res)
    end
    return d
  end
  local admitted, reason = _admit(lane_name)
  if not admitted then
    state.counters.rejected = state.counters.rejected + 1
    return async.reject({
      kind = spec.kind or "task", rejected = true, reason = reason,
      message = ("资源压力过高（%s），%s 通道暂不接受新任务"):format(tostring(reason), lane_name),
    })
  end
  local queue_max = tonumber(cfg.queue_max) or 64
  if queue_max > 0 and #lane.queue >= queue_max then
    state.counters.rejected = state.counters.rejected + 1
    return async.reject({
      kind = spec.kind or "task", rejected = true, reason = "queue_full",
      message = ("%s 通道排队已满（%d），拒绝新任务"):format(lane_name, queue_max),
    })
  end
  state.seq = state.seq + 1
  local item = {
    id = "task-" .. tostring(state.seq),
    kind = spec.kind or "task",
    label = spec.label,
    lane = lane_name,
    run = spec.run,
    retries = tonumber(spec.retries) or 0,
    timeout_ms = spec.timeout_ms,
    on_cancel = spec.on_cancel,
    state = "queued",
    d = async.Deferred.new(),
  }
  state.items[item.id] = item
  state.counters.submitted = state.counters.submitted + 1
  lane.queue[#lane.queue + 1] = item
  _emit(item, "queued")
  _pump(lane_name)
  -- 便于调用方取消（`:NeoAI` / 工具循环取消按钮）：Deferred 上带任务 id
  item.d._task_id = item.id
  return item.d
end

--- 取消一个任务（排队中直接移除；在途标记取消并调用 on_cancel，结果仍由 run 自行结束）
--- @param id string
--- @return boolean
function M.cancel(id)
  local item = state.items[id]
  if not item then return false end
  item.cancelled = true
  if type(item.on_cancel) == "function" then pcall(item.on_cancel, "cancel") end
  if item.state == "queued" then
    local lane = state.lanes[item.lane]
    if lane then
      for i, it in ipairs(lane.queue) do
        if it == item then
          table.remove(lane.queue, i)
          break
        end
      end
    end
    _settle(item, false, { kind = item.kind, cancelled = true, message = "任务已取消" })
    return true
  end
  return true
end

--- 主动回填（压力回落后可由调用方触发；也用于测试确定性）
function M.pump()
  _pump("interactive")
  _pump("background")
end

--- 统计（诊断/Status 用）
--- @return table
function M.stats()
  local out = {
    enabled = _cfg().enabled ~= false,
    counters = vim.deepcopy(state.counters),
    lanes = {},
    pending = vim.tbl_count(state.items),
  }
  for name, lane in pairs(state.lanes) do
    out.lanes[name] = { active = lane.active, queued = #lane.queue }
  end
  return out
end

--- 人类可读摘要
--- @return string
function M.describe()
  local s = M.stats()
  return ("交互 %d 在跑/%d 排队，后台 %d 在跑/%d 排队，累计 完成 %d/失败 %d/超时 %d/拒绝 %d")
    :format(s.lanes.interactive.active, s.lanes.interactive.queued,
      s.lanes.background.active, s.lanes.background.queued,
      s.counters.completed, s.counters.failed, s.counters.timeout, s.counters.rejected)
end

--- 清空（测试/卸载）：取消排队任务、标记在途任务为取消
function M.reset()
  for _, lane in pairs(state.lanes) do
    local q = lane.queue
    lane.queue = {}
    for _, item in ipairs(q) do
      item.cancelled = true
      _settle(item, false, { kind = item.kind, cancelled = true, message = "dispatch reset" })
    end
    lane.active = 0
    lane.paused_logged = nil
  end
  for id, item in pairs(state.items) do
    item.cancelled = true
    if not item.settled then
      _settle(item, false, { kind = item.kind, cancelled = true, message = "dispatch reset" })
    end
    state.items[id] = nil
  end
  state.counters = { submitted = 0, completed = 0, failed = 0, timeout = 0, cancelled = 0, rejected = 0 }
end

return M
