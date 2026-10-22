--- 可暂停的工具执行计时器
--- @module 'NeoAI.utils.timer'
--- 跟踪"活跃执行时间"（剔除等待人类交互的暂停时长），并基于活跃时间执行超时。
--- 工具执行期间若需等待用户交互（审批、ask_user 回答、设备/策略/网络同意窗）则 pause()，
--- 交互结束后 resume()，从而等待时间不计入工具执行耗时，也不会消耗超时预算。
--- 对于拿不到 `ctx.timer` 的交互窗口（如沙箱内部在命令执行途中弹出的同意窗），走
--- `await()`：它按「活跃计时器登记」暂停当前所有正在计时的工具计时器，交互结算后恢复。

local M = {}

local function _now_ms()
  return vim.uv.hrtime() / 1e6
end

-- ========== 活跃计时器登记 ==========
-- start() 登记、stop()/_fire() 注销；供无 ctx 的交互窗口批量暂停/恢复。
-- 交互窗口可能嵌套（同意窗里再触发子流程），故用深度计数：只在 0→1 暂停、1→0 恢复。
local _active = {}      -- 数组：正在计时的工具计时器
local _wait_depth = 0   -- 当前嵌套的交互等待层数

--- 登记活跃计时器（幂等）
--- @param t table
--- @return table
function M._register(t)
  for _, v in ipairs(_active) do
    if v == t then return t end
  end
  _active[#_active + 1] = t
  -- 进入等待中时新登记（极少见）：立即暂停，保持「等待期间不累计」。
  if _wait_depth > 0 and t.running then pcall(M.pause, t) end
  return t
end

--- 注销活跃计时器（幂等）
--- @param t table
--- @return table
function M._unregister(t)
  for i = #_active, 1, -1 do
    if _active[i] == t then table.remove(_active, i) end
  end
  return t
end

--- 进入交互等待：暂停所有正在计时的工具计时器（嵌套安全）。
--- @return boolean 本次调用是否真正完成了 0→1 的暂停（用于配对 resume）
function M.begin_wait()
  _wait_depth = _wait_depth + 1
  if _wait_depth > 1 then return false end
  for _, t in ipairs(_active) do
    if t.running then pcall(M.pause, t) end
  end
  return true
end

--- 结束交互等待：恢复计时（仅在深度回到 0 时真正恢复）。
function M.end_wait()
  if _wait_depth <= 0 then return end
  _wait_depth = _wait_depth - 1
  if _wait_depth > 0 then return end
  for _, t in ipairs(_active) do
    if not t.settled and not t.running then pcall(M.resume, t) end
  end
end

--- 包装一个「等待人类交互」的 Deferred：等待期间不累计耗时、不消耗超时预算。
--- 结算值/错误原样透传。无 vim.schedule 依赖，纯回调挂载。
--- @param d table Deferred（async.Deferred）
--- @return table 包装后的 Deferred
function M.await(d)
  if type(d) ~= "table" or type(d.then_) ~= "function" then return d end
  local async = require("NeoAI.utils.async")
  local out = async.Deferred.new()
  M.begin_wait()
  d:then_(function(v)
    M.end_wait()
    out:resolve(v)
  end, function(e)
    M.end_wait()
    out:reject(e)
  end)
  return out
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
  M._register(t)
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
  M._unregister(t)
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
  M._unregister(t)
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
