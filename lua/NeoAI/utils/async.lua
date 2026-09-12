--- 异步原语库
--- @module NeoAI.utils.async
--- 提供 Promise / Deferred / AbortSignal（取消信号）/ 并发 / 重试 / 延迟。
--- 完全基于 Neovim 主循环（vim.schedule / vim.defer_fn），无第三方依赖。

local M = {}

-- ========== Deferred（可手动 resolve/reject 的 Promise 执行器） ==========

local Deferred = {}
Deferred.__index = Deferred

--- 创建一个已挂起的 Deferred
--- @return Deferred
function Deferred.new()
  local self = setmetatable({}, Deferred)
  self._state = "pending" -- pending | resolved | rejected
  self._value = nil
  self._error = nil
  self._on_fulfilled = {}
  self._on_rejected = {}
  self._signal = nil
  return self
end

function Deferred:resolve(value)
  if self._state ~= "pending" then return self end
  self._state = "resolved"
  self._value = value
  local callbacks = self._on_fulfilled
  self._on_fulfilled = {}
  self._on_rejected = {}
  for _, cb in ipairs(callbacks) do
    vim.schedule(function()
      local ok, err = pcall(cb, value)
      if not ok then
        vim.notify("[NeoAI.async] Promise 回调异常: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
  end
  return self
end

function Deferred:reject(err)
  if self._state ~= "pending" then return self end
  self._state = "rejected"
  self._error = err
  local callbacks = self._on_rejected
  self._on_fulfilled = {}
  self._on_rejected = {}
  for _, cb in ipairs(callbacks) do
    vim.schedule(function()
      local ok, perr = pcall(cb, err)
      if not ok then
        vim.notify("[NeoAI.async] Promise 错误回调异常: " .. tostring(perr), vim.log.levels.ERROR)
      end
    end)
  end
  return self
end

--- then 链式调用
--- @param on_fulfilled function|nil
--- @param on_rejected function|nil
--- @return Deferred 新 Deferred
function Deferred:then_(on_fulfilled, on_rejected)
  local next = Deferred.new()

  local function _settle(target, value, err)
    -- 若回调返回的是 Deferred，则链接到它
    if type(value) == "table" and value.then_ and err == nil then
      value:then_(function(v) target:resolve(v) end, function(e) target:reject(e) end)
      return
    end
    if err ~= nil then
      target:reject(err)
    else
      target:resolve(value)
    end
  end

  local function _fulfilled(value)
    local cb = on_fulfilled
    if not cb then
      next:resolve(value)
      return
    end
    local ok, res = pcall(cb, value)
    if not ok then
      next:reject(res)
    else
      _settle(next, res)
    end
  end

  local function _rejected(err)
    local cb = on_rejected
    if not cb then
      next:reject(err)
      return
    end
    local ok, res = pcall(cb, err)
    if not ok then
      next:reject(res)
    else
      _settle(next, res)
    end
  end

  if self._state == "resolved" then
    vim.schedule(function() _fulfilled(self._value) end)
  elseif self._state == "rejected" then
    vim.schedule(function() _rejected(self._error) end)
  else
    self._on_fulfilled[#self._on_fulfilled + 1] = _fulfilled
    self._on_rejected[#self._on_rejected + 1] = _rejected
  end
  return next
end

--- 错误处理快捷方式
--- @param on_rejected function
--- @return Deferred
function Deferred:catch(on_rejected)
  return self:then_(nil, on_rejected)
end

--- 无论如何都会执行
--- @param cb function
--- @return Deferred
function Deferred:finally(cb)
  local function cleanup(continue)
    -- then_ 负责捕获同步异常；异步清理必须完成后才恢复原始结果。
    local result = cb()
    if type(result) == "table" and type(result.then_) == "function" then
      return result:then_(continue)
    end
    return continue()
  end
  return self:then_(
    function(value)
      return cleanup(function() return value end)
    end,
    function(err)
      return cleanup(function() return M.reject(err) end)
    end
  )
end

--- 判断是否仍挂起
function Deferred:is_pending()
  return self._state == "pending"
end

--- 判断是否成功
function Deferred:is_resolved()
  return self._state == "resolved"
end

M.Deferred = Deferred

-- ========== Promise（异步执行器风格） ==========

--- 创建一个 Promise
--- executor(resolve, reject) 会同步调用；内部操作应是非阻塞的
--- @param executor function
--- @return Deferred
function M.new(executor)
  local d = Deferred.new()
  local ok, err = pcall(executor, function(v) d:resolve(v) end, function(e) d:reject(e) end)
  if not ok then
    d:reject(err)
  end
  return d
end

--- 立即 resolve
--- @param value any
--- @return Deferred
function M.resolve(value)
  local d = Deferred.new()
  vim.schedule(function() d:resolve(value) end)
  return d
end

--- 立即 reject
--- @param err any
--- @return Deferred
function M.reject(err)
  local d = Deferred.new()
  vim.schedule(function() d:reject(err) end)
  return d
end

--- 延迟指定毫秒后 resolve
--- @param ms number
--- @param value any
--- @return Deferred
function M.sleep(ms, value)
  local d = Deferred.new()
  vim.defer_fn(function() d:resolve(value) end, ms)
  return d
end

--- 并发执行多个 Promise，全部完成后 resolve 数组
--- @param promises table 数组
--- @return Deferred
function M.all(promises)
  local d = Deferred.new()
  if #promises == 0 then
    vim.schedule(function() d:resolve({}) end)
    return d
  end
  local results = {}
  local remaining = #promises
  local settled = false
  for i, p in ipairs(promises) do
    p:then_(function(value)
      if settled then return end
      results[i] = { ok = true, value = value }
      remaining = remaining - 1
      if remaining == 0 then
        settled = true
        local out = {}
        for j = 1, #results do out[j] = results[j].value end
        d:resolve(out)
      end
    end, function(err)
      if settled then return end
      settled = true
      d:reject(err)
    end)
  end
  return d
end

--- 竞速：第一个 settle 的结果胜出
--- @param promises table
--- @return Deferred
function M.race(promises)
  local d = Deferred.new()
  local settled = false
  for _, p in ipairs(promises) do
    p:then_(function(v)
      if settled then return end
      settled = true
      d:resolve(v)
    end, function(e)
      if settled then return end
      settled = true
      d:reject(e)
    end)
  end
  return d
end

--- 带重试的异步操作
--- @param fn function 返回 Deferred
--- @param opts table|nil { retries=3, delay_ms=1000, backoff=2, signal=signal, should_retry=fun(err):boolean }
--- @return Deferred
function M.retry(fn, opts)
  opts = opts or {}
  local retries = opts.retries or 3
  local delay_ms = opts.delay_ms or 1000
  local backoff = opts.backoff or 2
  local signal = opts.signal
  local should_retry = opts.should_retry or function() return true end

  local function attempt(n)
    if signal and signal:aborted() then
      return M.reject({ kind = "aborted", message = "operation aborted" })
    end
    local p = fn()
    return p:then_(function(v) return v end, function(err)
      if n >= retries then
        return M.reject(err)
      end
      if should_retry and not should_retry(err) then
        return M.reject(err)
      end
      return M.sleep(delay_ms * (backoff ^ (n - 1))):then_(function() return attempt(n + 1) end)
    end)
  end
  return attempt(1)
end

-- ========== AbortSignal（取消信号） ==========

local Signal = {}
Signal.__index = Signal

--- 创建一个取消信号
--- signal:abort(reason) 级联取消；signal:aborted() 检查状态
--- @return Signal
function Signal.new()
  return setmetatable({ _aborted = false, _reason = nil, _listeners = {} }, Signal)
end

function Signal:abort(reason)
  if self._aborted then return self end
  self._aborted = true
  self._reason = reason or "aborted"
  local listeners = self._listeners
  self._listeners = {}
  for _, cb in ipairs(listeners) do
    local ok, err = pcall(cb, self._reason)
    if not ok then
      vim.notify("[NeoAI.async] abort 监听器异常: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  return self
end

--- 是否已取消
function Signal:aborted()
  return self._aborted
end

--- 取消原因
function Signal:reason()
  return self._reason
end

--- 监听取消事件（立即返回取消函数）
--- @param cb function
--- @return function 取消订阅
function Signal:subscribe(cb)
  if self._aborted then
    vim.schedule(function() cb(self._reason) end)
    return function() end
  end
  self._listeners[#self._listeners + 1] = cb
  local removed = false
  return function()
    if removed then return end
    removed = true
    for i, l in ipairs(self._listeners) do
      if l == cb then
        table.remove(self._listeners, i)
        break
      end
    end
  end
end

--- 把信号绑定到一个 Deferred：abort 时 reject 它
--- @param signal Signal
--- @param d Deferred
--- @param reason any|nil
function Signal:bind_deferred(d, reason)
  return self:subscribe(function(r) d:reject({ kind = "aborted", message = reason or r }) end)
end

M.Signal = Signal

--- 创建取消信号（等价于 Signal.new）
--- @return Signal
function M.create_signal()
  return Signal.new()
end

-- ========== 任务调度 ==========

--- 串行执行异步任务队列（一次一个）
--- @param tasks table 数组 of function 返回 Deferred
--- @return Deferred
function M.serial(tasks)
  local d = Deferred.new()
  local i = 1
  local results = {}
  local function next_task()
    if i > #tasks then
      d:resolve(results)
      return
    end
    local task = tasks[i]
    i = i + 1
    task():then_(function(v)
      results[#results + 1] = v
      next_task()
    end, function(e)
      d:reject(e)
    end)
  end
  vim.schedule(next_task)
  return d
end

--- 将一个回调函数包装为返回 Deferred 的版本
--- @param fn function(args..., cb)
--- @return function(...): Deferred
function M.promisify(fn)
  return function(...)
    local args = { ... }
    local d = Deferred.new()
    local called = false
    local function cb(err, ...)
      if called then return end
      called = true
      if err then
        d:reject(err)
      else
        d:resolve({ ... })
      end
    end
    local ok, ferr = pcall(fn, unpack(args, 1, args.n), cb)
    if not ok then
      d:reject(ferr)
    end
    return d
  end
end

return M
