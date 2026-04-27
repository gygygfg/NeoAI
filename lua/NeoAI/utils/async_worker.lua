-- NeoAI 异步工作器模块
-- 轻量级后台任务调度引擎，使用 vim.defer_fn 分片执行，避免阻塞主线程
--
-- 功能：
-- 1. 异步任务提交与执行（vim.defer_fn 分片调度）
-- 2. 并发限制（max_workers）
-- 3. 超时保护（可配置超时时间）
-- 4. 取消机制（cancel_sequence_id，防止回调竞态）
-- 5. 结果序列化（自动 JSON encode）
-- 6. 事件触发（可选 User autocommands）
-- 7. 批量提交
-- 8. Worker 状态查询

local M = {}

local logger = require("NeoAI.utils.logger")

local state = {
  workers = {},
  next_worker_id = 1,
  max_workers = 10,
}

-- ========== Worker 对象 ==========

local Worker = {}
Worker.__index = Worker

--- 创建 Worker 实例
--- @param opts table
---   name: string - 任务名称
---   task_func: function - 任务函数
---   callback: function|nil - 完成回调 (success, result, error_msg, worker_info)
---   timeout_ms: number|nil - 超时时间（毫秒），默认无超时
---   auto_serialize: boolean|nil - 是否自动序列化结果（默认 true）
---   events: table|nil - 事件配置 { started, completed, error } 事件名称
---   event_data: table|nil - 事件附加数据
--- @return table Worker 实例
function Worker.new(opts)
  opts = opts or {}
  return setmetatable({
    id = state.next_worker_id,
    name = opts.name or ("worker_" .. state.next_worker_id),
    task_func = opts.task_func,
    callback = opts.callback,
    timeout_ms = opts.timeout_ms,
    auto_serialize = opts.auto_serialize ~= false, -- 默认 true
    events = opts.events,
    event_data = opts.event_data or {},
    status = "idle",
    result = nil,
    error = nil,
    start_time = nil,
    end_time = nil,
    duration = nil,
    timed_out = false,
  }, Worker)
end

--- 执行 Worker
--- @return integer worker_id
function Worker:execute()
  state.next_worker_id = state.next_worker_id + 1
  self.status = "running"
  self.start_time = os.clock()
  state.workers[self.id] = self

  -- 触发开始事件
  if self.events and self.events.started then
    vim.api.nvim_exec_autocmds("User", {
      pattern = self.events.started,
      data = vim.tbl_extend("keep", {
        worker_id = self.id,
        worker_name = self.name,
        start_time = self.start_time,
      }, self.event_data),
    })
  end

  -- 设置超时定时器
  if self.timeout_ms and self.timeout_ms > 0 then
    local timeout_timer = vim.defer_fn(function()
      if not state.workers[self.id] then return end
      if state.workers[self.id].status ~= "running" then return end

      self.timed_out = true
      self.status = "timeout"
      self.end_time = os.clock()
      self.duration = self.end_time - self.start_time
      self.error = "任务执行超时（" .. (self.timeout_ms / 1000) .. "秒）: " .. self.name
      state.workers[self.id] = nil

      -- 触发超时事件（通过 vim.schedule 延迟执行）
      if self.events and self.events.error then
        vim.schedule(function()
          vim.api.nvim_exec_autocmds("User", {
            pattern = self.events.error,
            data = vim.tbl_extend("keep", {
              worker_id = self.id,
              worker_name = self.name,
              error_msg = self.error,
              duration = self.duration,
            }, self.event_data),
          })
        end)
      end

      if self.callback then
        vim.schedule(function()
          self.callback(false, nil, self.error, self:get_info())
        end)
      end
    end, self.timeout_ms)

    -- 保存定时器引用，任务完成时取消
    self._timeout_timer = timeout_timer
  end

  -- 使用 vim.schedule 延迟执行，确保在事件循环恢复后立即执行
  -- 注意：vim.defer_fn 在 vim.wait 阻塞期间可能无法执行
  vim.schedule(function()
    self:_run_task()
  end)

  return self.id
end

--- 内部：执行任务
function Worker:_run_task()
  -- 再次检查是否已被取消或超时
  if not state.workers[self.id] then return end
  if self.status ~= "running" then return end

  local ok, result_or_err = pcall(self.task_func)

  -- 如果已超时，忽略结果
  if self.timed_out then
    logger.debug("[async_worker] 任务 " .. self.name .. " 已完成但已超时，忽略结果")
    return
  end

  -- 如果已被取消，忽略结果
  if not state.workers[self.id] or self.status ~= "running" then
    logger.debug("[async_worker] 任务 " .. self.name .. " 已被取消，忽略结果")
    return
  end

  -- 取消超时定时器
  if self._timeout_timer then
    pcall(function()
      if not self._timeout_timer:is_closing() then
        self._timeout_timer:stop()
        self._timeout_timer:close()
      end
    end)
    self._timeout_timer = nil
  end

  self.end_time = os.clock()
  self.duration = self.end_time - self.start_time

  if ok then
    self.status = "completed"
    self.result = self.auto_serialize and M._serialize_result(result_or_err) or result_or_err
    state.workers[self.id] = nil

    -- 触发完成事件（通过 vim.schedule 延迟执行）
    if self.events and self.events.completed then
      vim.schedule(function()
        vim.api.nvim_exec_autocmds("User", {
          pattern = self.events.completed,
          data = vim.tbl_extend("keep", {
            worker_id = self.id,
            worker_name = self.name,
            result = self.result,
            duration = self.duration,
          }, self.event_data),
        })
      end)
    end

    -- 通过 vim.schedule 确保回调在主事件循环中执行
    -- 避免同步工具在 vim.defer_fn 上下文中直接调用回调导致事件循环阻塞
    if self.callback then
      vim.schedule(function()
        self.callback(true, self.result, nil, self:get_info())
      end)
    end
  else
    self.status = "failed"
    self.error = tostring(result_or_err)
    state.workers[self.id] = nil

    -- 触发错误事件（通过 vim.schedule 延迟执行）
    if self.events and self.events.error then
      vim.schedule(function()
        vim.api.nvim_exec_autocmds("User", {
          pattern = self.events.error,
          data = vim.tbl_extend("keep", {
            worker_id = self.id,
            worker_name = self.name,
            error_msg = self.error,
            duration = self.duration,
          }, self.event_data),
        })
      end)
    end

    if self.callback then
      vim.schedule(function()
        self.callback(false, nil, self.error, self:get_info())
      end)
    end
  end
end

--- 获取 Worker 信息
function Worker:get_info()
  return {
    id = self.id,
    name = self.name,
    status = self.status,
    duration = self.duration,
    result = self.result,
    error = self.error,
    start_time = self.start_time,
    end_time = self.end_time,
  }
end

-- ========== 内部工具函数 ==========

--- 序列化结果
function M._serialize_result(result)
  if result == nil then return "" end
  if type(result) == "string" then return result end
  if type(result) == "table" then
    local ok, e = pcall(vim.json.encode, result)
    if ok then return e end
    local ok2, e2 = pcall(vim.inspect, result)
    return ok2 and e2 or tostring(result)
  end
  return tostring(result)
end

--- 快速清理已完成/已取消的工作器
local function _cleanup_completed()
  for id, w in pairs(state.workers) do
    if w.status ~= "running" then
      state.workers[id] = nil
    end
  end
end

--- 检查并发限制
local function _check_concurrency()
  local active = 0
  for _, w in pairs(state.workers) do
    if w.status == "running" then
      active = active + 1
    end
  end
  return active
end

-- ========== 公共 API ==========

--- 提交异步任务
--- @param name string 任务名称
--- @param task_func function 任务函数
--- @param callback function|nil 回调函数 (success, result, error_msg, worker_info)
--- @param opts table|nil 附加选项
---   timeout_ms: number - 超时时间（毫秒）
---   auto_serialize: boolean - 是否自动序列化结果（默认 true）
---   events: table - 事件配置 { started, completed, error }
---   event_data: table - 事件附加数据
--- @return integer 任务ID
function M.submit_task(name, task_func, callback, opts)
  _cleanup_completed()

  local active = _check_concurrency()
  if active >= state.max_workers then
    error(string.format("已达到最大工作器数量限制 (%d)", state.max_workers))
  end

  opts = opts or {}
  local worker = Worker.new({
    name = name,
    task_func = task_func,
    callback = callback,
    timeout_ms = opts.timeout_ms,
    auto_serialize = opts.auto_serialize,
    events = opts.events,
    event_data = opts.event_data,
  })
  return worker:execute()
end

--- 批量提交任务
--- @param tasks table 任务列表，每个元素为 { name, task_func, callback, opts }
--- @return table 任务ID列表
function M.submit_batch(tasks)
  local ids = {}
  for i, t in ipairs(tasks) do
    ids[i] = M.submit_task(
      t.name or ("batch_" .. i),
      t.task_func,
      t.callback,
      t.opts
    )
  end
  return ids
end

--- 获取工作器状态
--- @param worker_id integer
--- @return table|nil
function M.get_worker_status(worker_id)
  local w = state.workers[worker_id]
  return w and w:get_info() or nil
end

--- 获取所有工作器状态
--- @return table
function M.get_all_worker_status()
  local list = {}
  for _, w in pairs(state.workers) do
    table.insert(list, w:get_info())
  end
  return list
end

--- 取消工作器（仅标记，无法真正终止 Lua 线程）
--- @param worker_id integer
--- @return boolean
function M.cancel_worker(worker_id)
  local w = state.workers[worker_id]
  if w and w.status == "running" then
    w.status = "cancelled"
    state.workers[worker_id] = nil
    return true
  end
  return false
end

--- 取消所有运行中的工作器
--- @return table 被取消的工作器ID列表
function M.cancel_all_workers()
  local cancelled = {}
  for id, w in pairs(state.workers) do
    if w.status == "running" then
      w.status = "cancelled"
      table.insert(cancelled, id)
    end
    state.workers[id] = nil
  end
  return cancelled
end

--- 清理已完成的工作器
function M.cleanup_completed()
  _cleanup_completed()
end

--- 设置最大工作器数量
--- @param max integer
function M.set_max_workers(max)
  if max > 0 then
    state.max_workers = max
  end
end

--- 获取当前活动工作器数量
--- @return integer
function M.get_active_count()
  return _check_concurrency()
end

--- 获取工作器总数（包括已完成但未清理的）
--- @return integer
function M.get_total_count()
  local count = 0
  for _ in pairs(state.workers) do
    count = count + 1
  end
  return count
end

--- 重置模块状态（主要用于测试和 shutdown）
function M.reset()
  state.workers = {}
  state.next_worker_id = 1
  state.max_workers = 10
end

return M
