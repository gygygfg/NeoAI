--- 同意/告警类浮窗的单槽位调度
--- @module 'NeoAI.ui.consent_slot'
---
--- 密钥告警（`secret_alert`）、网络同意（`net_consent`）、设备同意（`device_consent`）、
--- 策略确认（`policy_consent`）四类**阻塞**浮窗共用一个展示槽位：
---   - **跨组件互斥**：任一时刻全局至多一个同意类浮窗，其余排队逐个展示。此前各组件各自
---     建窗、几何相同而互相遮挡，用户只答了可见的那个，另一个的决策回调永久丢失 → 审批
---     中心条目残留 pending → Herder pane 一直停留在 `blocked`。
---   - **票据（ticket）**：每次请求持有一张票据，`hide/is_open` 按票据生效——A 请求超时只
---     关 A 自己的窗，不会误关 B 的窗（旧实现用全局 `ui.is_open()` + 无参 `ui.hide()`）。
---   - **同 key+dedupe 在途抑制**：同一目标（如网络同端口+同服务进程）的重复请求不再排队，
---     返回 `suppressed` 票据；其结算由在途票据经审批中心合并代表（中心按 `dedupe_key`
---     合并条目并让所有挂起请求一起结算），避免同一目标刷出多个浮窗。
---
--- 槽位推进语义：决策（`release`）、取消（`cancel`）、展示失败都会让出槽位并立刻尝试展示
--- 队首票据。`open` 用 `pcall` 包裹，异常时自动让位并记日志——槽位卡死会让后续请求永久
--- pending（表现为 Herder pane 永不回 `working`），因此这里不允许任何路径吞掉让位。

local M = {}

-- ========== 私有状态 ==========

local state = {
  seq = 0, -- 票据自增序号（用于生成稳定 id / 焦点门控 key）
  current = nil, -- 当前占用槽位的票据
  queue = {}, -- 排队中的票据（先到先展示）
  pumping = false, -- 防重入：open 内部同步 release 时不再递归推进
}

--- 记日志（槽位异常不应中断调用方流程）
--- @param fmt string
--- @param ... any
local function _warn(fmt, ...)
  local args = { n = select("#", ...), ... }
  pcall(function()
    require("NeoAI.kernel.logger").warn(fmt, unpack(args, 1, args.n))
  end)
end

--- 生成票据 id
--- @return string
local function _next_id()
  state.seq = state.seq + 1
  return string.format("cs%d", state.seq)
end

--- 从队列移除票据
--- @param ticket table
--- @return boolean removed
local function _dequeue(ticket)
  for i, t in ipairs(state.queue) do
    if t == ticket then
      table.remove(state.queue, i)
      return true
    end
  end
  return false
end

--- 查找同 key + 同 dedupe 的在途票据（当前展示或排队中；被抑制的票据不计）
--- @param key string
--- @param dedupe string
--- @return table|nil
local function _find_inflight(key, dedupe)
  local cur = state.current
  if cur and cur.key == key and cur.dedupe == dedupe and not cur.suppressed then return cur end
  for _, t in ipairs(state.queue) do
    if t.key == key and t.dedupe == dedupe and not t.suppressed then return t end
  end
  return nil
end

--- 推进槽位：空闲时逐个取出队首票据并展示（open 失败自动让位）。
local function _pump()
  if state.pumping then return end
  state.pumping = true
  while state.current == nil do
    local t = table.remove(state.queue, 1)
    if not t then break end
    state.current = t
    t.phase = "current"
    local ok, err = pcall(t.open, t)
    if not ok and state.current == t then
      -- 展示失败：让位并继续尝试队首，否则槽位卡死、后续请求永久排队。
      state.current = nil
      t.phase = "failed"
      t.presented = false
      _warn("[consent_slot] 同意浮窗展示失败（key=%s id=%s）：%s",
        tostring(t.key), tostring(t.id), tostring(err))
    end
  end
  state.pumping = false
end

-- ========== 公开 API ==========

--- 申请展示槽位。
--- 槽位空闲时**立即**调用 `spec.open(ticket)` 展示；否则排队，待前一张票据让位后展示。
--- @param spec table {
---   key: string,                  -- 组件标识（net_consent / secret_alert / ...）
---   dedupe: string|nil,           -- 同 key 同 dedupe 的在途请求不再排队（返回 suppressed 票据）
---   open: function(ticket),       -- 展示函数（内部可经 focus.gate 暂存，展示后调 mark_presented）
---   close: function(ticket)|nil,  -- 关窗函数（cancel/reset 时调用：关窗 + 取消焦点门控暂存）
--- }
--- @return table ticket 票据（始终返回对象；被去重抑制时 `ticket.suppressed == true`）
function M.acquire(spec)
  spec = type(spec) == "table" and spec or {}
  local key = tostring(spec.key or "consent")
  local dedupe = type(spec.dedupe) == "string" and spec.dedupe ~= "" and spec.dedupe or nil
  if dedupe then
    local owner = _find_inflight(key, dedupe)
    if owner then
      -- 去重抑制：不占用槽位、不建窗；结算由在途票据 + 审批中心合并条目代表。
      return {
        id = _next_id(),
        key = key,
        dedupe = dedupe,
        suppressed = true,
        owner = owner,
        phase = "suppressed",
        presented = false,
      }
    end
  end
  local ticket = {
    id = _next_id(),
    key = key,
    dedupe = dedupe,
    open = spec.open,
    close = spec.close,
    suppressed = false,
    presented = false,
    phase = "queued",
  }
  state.queue[#state.queue + 1] = ticket
  _pump()
  return ticket
end

--- 标记票据的窗口已呈现（仅当前票据有效）。
--- @param ticket table
--- @return boolean
function M.mark_presented(ticket)
  if type(ticket) ~= "table" or ticket.suppressed then return false end
  if state.current ~= ticket then return false end
  ticket.presented = true
  return true
end

--- 票据对应窗口是否已呈现（被抑制的票据跟随其代表票据）。
--- @param ticket table
--- @return boolean
function M.is_presented(ticket)
  if type(ticket) ~= "table" then return false end
  if ticket.suppressed then
    local owner = ticket.owner
    return owner ~= nil and owner.presented == true
  end
  return ticket.presented == true and state.current == ticket
end

--- 让位（决策完成时调用：窗口由调用方自行关闭，这里只释放槽位并推进队列）。
--- @param ticket table
--- @return boolean handled
function M.release(ticket)
  if type(ticket) ~= "table" or ticket.suppressed then return false end
  ticket.presented = false
  if state.current == ticket then
    state.current = nil
    ticket.phase = "released"
    _pump()
    return true
  end
  if _dequeue(ticket) then
    ticket.phase = "released"
    return true
  end
  return false
end

--- 取消（超时 / 隐藏 / 外部关窗时调用：出队或关窗并让位）。
--- @param ticket table
--- @return boolean handled
function M.cancel(ticket)
  if type(ticket) ~= "table" or ticket.suppressed then return false end
  ticket.presented = false
  if state.current == ticket then
    state.current = nil
    ticket.phase = "cancelled"
    if type(ticket.close) == "function" then pcall(ticket.close, ticket) end
    _pump()
    return true
  end
  if _dequeue(ticket) then
    ticket.phase = "cancelled"
    return true
  end
  return false
end

--- 当前占用槽位的票据（无则 nil）
--- @return table|nil
function M.current()
  return state.current
end

--- 排队中的票据数（不含当前展示）
--- @return number
function M.pending_count()
  return #state.queue
end

--- 是否存在在途票据（展示中或排队中）
--- @return boolean
function M.has_inflight()
  return state.current ~= nil or #state.queue > 0
end

--- 清空槽位与队列（组件 reset / 测试用）。
function M.reset()
  local cur = state.current
  state.current = nil
  state.queue = {}
  state.pumping = false
  if cur then
    cur.presented = false
    cur.phase = "reset"
    if type(cur.close) == "function" then pcall(cur.close, cur) end
  end
end

return M
