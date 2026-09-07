--- 可暂停的工具执行计时器
--- @module NeoAI.utils.timer
--- 跟踪"活跃执行时间"（剔除等待人类交互的暂停时长），并基于活跃时间执行超时。
--- 工具执行期间若需等待用户交互（审批、ask_user 回答）则 pause()，交互结束后 resume()，
--- 从而等待时间不计入工具执行耗时，也不会消耗超时预算。

local M = {}

local function _now_ms()
  return vim.uv.hrtime() / 1e6
end

--- 创建可暂停计时器
--- @return table
function M.create()
  local t = {
    running = false,   -- 当前是否在累计
    settled = false,   -- 是否已结束（stop / 超时）
    active = 0,        -- 累计活跃毫秒（剔除暂停期间）
    _last = nil,       -- 最近一次开始/恢复时刻
    budget = nil,      -- 超时预算（毫秒；nil / <0 = 无超时）
    timer = nil,       -- 超时定时器句柄
    on_timeout = nil,  -- 超时回调
  }
  setmetatable(t, { __index = M })
  return t
end

--- 开始计时（幂等）。timeout_ms 指定超时预算（nil / <0 = 无超时）。
--- @param t table
--- @param timeout_ms number|nil
--- @return table
function M.start(t, timeout_ms)
  if t.running then return t end
  t.budget = timeout_ms
  t.settled = false
  t.running = true
  t._last = _now_ms()
  t:_arm()
  return t
end

--- 暂停计时（等待用户交互）。暂停期间不累计耗时、不消耗超时预算。
--- @param t table
--- @return table
function M.pause(t)
  if not t.running then return t end
  t.active = t.active + (_now_ms() - t._last)
  t.running = false
  if t.timer then
    vim.fn.timer_stop(t.timer)
    t.timer = nil
  end
  return t
end

--- 恢复计时（用户交互结束）。
--- @param t table
--- @return table
function M.resume(t)
  if t.settled or t.running then return t end
  t.running = true
  t._last = _now_ms()
  t:_arm()
  return t
end

--- 结束计时（工具执行完毕）。停止超时与追踪。
--- @param t table
--- @return table
function M.stop(t)
  t.settled = true
  if t.running then
    t.active = t.active + (_now_ms() - t._last)
    t.running = false
  end
  if t.timer then
    vim.fn.timer_stop(t.timer)
    t.timer = nil
  end
  return t
end

--- 当前活跃耗时（毫秒，剔除暂停期间）。未暂停时实时累计。
--- @param t table
--- @return number
function M.elapsed(t)
  if t.running then
    return t.active + (_now_ms() - t._last)
  end
  return t.active
end

--- ========== 私有 ==========

--- 基于剩余预算重新挂起超时
function M._arm(t)
  if t.timer then
    vim.fn.timer_stop(t.timer)
    t.timer = nil
  end
  if not t.budget or t.budget < 0 then return end
  local remaining = t.budget - t.active
  if remaining <= 0 then
    t:_fire()
    return
  end
  -- 用 timer_start（返回数字句柄）而非 defer_fn（返回 Timer 对象）：
  -- pause/stop 需要 vim.fn.timer_stop 传入数字句柄。
  -- remaining 是浮点（hrtime 换算而来），timer_start 要求整数毫秒。
  local ms = math.floor(remaining)
  if ms < 1 then ms = 1 end
  t.timer = vim.fn.timer_start(ms, function()
    t.timer = nil
    if t.running and not t.settled then
      t:_fire()
    end
  end, vim.empty_dict())
end

function M._fire(t)
  if t.settled then return end
  t.settled = true
  if t.running then
    t.active = t.active + (_now_ms() - t._last)
    t.running = false
  end
  if t.timer then
    vim.fn.timer_stop(t.timer)
    t.timer = nil
  end
  if t.on_timeout then
    t.on_timeout()
  end
end

return M
