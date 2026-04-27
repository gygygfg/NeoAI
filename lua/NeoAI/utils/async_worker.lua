-- NeoAI 异步工作器模块
-- 轻量级后台任务调度，使用 vim.defer_fn 分片执行，避免阻塞主线程
-- 注意：工具函数本身仍运行在主线程，但通过分片调度让 UI 有机会响应
-- 对于真正的后台执行，工具应使用 vim.fn.jobstart（如 http_client.lua）

local M = {}

local state = {
  workers = {},
  next_worker_id = 1,
  max_workers = 5,
}

local Worker = {}
Worker.__index = Worker

function Worker.new(name, task_func, callback)
  return setmetatable({
    id = state.next_worker_id,
    name = name or ("worker_" .. state.next_worker_id),
    task_func = task_func,
    callback = callback,
    status = "idle",
    result = nil,
    error = nil,
    start_time = nil,
    end_time = nil,
    duration = nil,
  }, Worker)
end

function Worker:execute()
  state.next_worker_id = state.next_worker_id + 1
  self.status = "running"
  self.start_time = os.clock()
  state.workers[self.id] = self

  local function done(success, result, error_msg)
    self.end_time = os.clock()
    self.duration = self.end_time - self.start_time
    self.status = success and "completed" or "failed"
    self.result = success and result or nil
    self.error = success and nil or error_msg
    state.workers[self.id] = nil
    if self.callback then
      self.callback(success, result, error_msg, self)
    end
  end

  local wrapped_done = vim.schedule_wrap(done)

  -- 使用 vim.defer_fn 延迟执行，让当前事件循环先处理 UI 事件
  vim.defer_fn(function()
    local ok, result_or_err = pcall(self.task_func)
    if ok then
      wrapped_done(true, result_or_err, nil)
    else
      wrapped_done(false, nil, tostring(result_or_err))
    end
  end, 0)

  return self.id
end

function Worker:get_info()
  return {
    id = self.id,
    name = self.name,
    status = self.status,
    duration = self.duration,
    result = self.result,
    error = self.error,
  }
end

--- 提交异步任务
--- @param name string 任务名称
--- @param task_func function 任务函数
--- @param callback function 回调函数
--- @return integer 任务ID
function M.submit_task(name, task_func, callback)
  -- 快速清理已完成的工作器
  for id, w in pairs(state.workers) do
    if w.status ~= "running" then
      state.workers[id] = nil
    end
  end

  -- 检查并发限制
  local active = 0
  for _, w in pairs(state.workers) do
    if w.status == "running" then
      active = active + 1
    end
  end

  if active >= state.max_workers then
    error(string.format("已达到最大工作器数量限制 (%d)", state.max_workers))
  end

  local worker = Worker.new(name, task_func, callback)
  return worker:execute()
end

--- 批量提交任务
function M.submit_batch(tasks)
  local ids = {}
  for i, t in ipairs(tasks) do
    ids[i] = M.submit_task(t.name or ("batch_" .. i), t.task_func, t.callback)
  end
  return ids
end

--- 获取工作器状态
function M.get_worker_status(worker_id)
  local w = state.workers[worker_id]
  return w and w:get_info() or nil
end

--- 获取所有工作器状态
function M.get_all_worker_status()
  local list = {}
  for _, w in pairs(state.workers) do
    table.insert(list, w:get_info())
  end
  return list
end

--- 取消工作器（仅标记，无法真正终止 Lua 线程）
function M.cancel_worker(worker_id)
  local w = state.workers[worker_id]
  if w and w.status == "running" then
    w.status = "cancelled"
    return true
  end
  return false
end

--- 清理已完成的工作器
function M.cleanup_completed()
  for id, w in pairs(state.workers) do
    if w.status ~= "running" then
      state.workers[id] = nil
    end
  end
end

--- 设置最大工作器数量
function M.set_max_workers(max)
  if max > 0 then
    state.max_workers = max
  end
end

--- 获取当前活动工作器数量
function M.get_active_count()
  local count = 0
  for _, w in pairs(state.workers) do
    if w.status == "running" then
      count = count + 1
    end
  end
  return count
end

return M
