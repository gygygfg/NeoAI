-- NeoAI 异步工作器模块
-- 提供后台线程处理，避免阻塞主线程

local M = {}

-- 工作器状态
local state = {
  workers = {},
  next_worker_id = 1,
  max_workers = 5, -- 最大并发工作器数量
}

--- 工作器类
local Worker = {}
Worker.__index = Worker

--- 创建新工作器
--- @param name string 工作器名称
--- @param task_func function 任务函数
--- @param callback function 回调函数
function Worker.new(name, task_func, callback)
  local self = setmetatable({}, Worker)
  self.id = state.next_worker_id
  state.next_worker_id = state.next_worker_id + 1
  self.name = name or ("worker_" .. self.id)
  self.task_func = task_func
  self.callback = callback
  self.status = "idle" -- idle, running, completed, failed
  self.result = nil
  self.error = nil
  self.start_time = nil
  self.end_time = nil
  return self
end

--- 在工作器中执行任务
function Worker:execute()
  self.status = "running"
  self.start_time = os.clock()
  
  -- 使用vim.schedule_wrap确保回调在合适的时机执行
  local wrapped_callback = vim.schedule_wrap(function(success, result, error_msg)
    self.end_time = os.clock()
    self.duration = self.end_time - self.start_time
    
    if success then
      self.status = "completed"
      self.result = result
      self.error = nil
    else
      self.status = "failed"
      self.result = nil
      self.error = error_msg
    end
    
    -- 执行回调
    if self.callback then
      self.callback(success, result, error_msg, self)
    end
    
    -- 从活动工作器列表中移除
    state.workers[self.id] = nil
  end)
  
  -- 使用vim.defer_fn在后台线程执行任务
  vim.defer_fn(function()
    local success, result_or_error = pcall(self.task_func)
    wrapped_callback(success, result_or_error, not success and result_or_error or nil)
  end, 0)
  
  -- 添加到活动工作器列表
  state.workers[self.id] = self
  
  return self.id
end

--- 获取工作器信息
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
  -- 检查是否达到最大工作器限制
  local active_count = 0
  for _, worker in pairs(state.workers) do
    if worker.status == "running" then
      active_count = active_count + 1
    end
  end
  
  if active_count >= state.max_workers then
    error(string.format("已达到最大工作器数量限制 (%d)", state.max_workers))
  end
  
  local worker = Worker.new(name, task_func, callback)
  return worker:execute()
end

--- 批量提交任务
--- @param tasks table 任务列表，每个元素为 {name, task_func, callback}
--- @return table 任务ID列表
function M.submit_batch(tasks)
  local task_ids = {}
  
  for i, task in ipairs(tasks) do
    local task_id = M.submit_task(
      task.name or ("batch_task_" .. i),
      task.task_func,
      task.callback
    )
    table.insert(task_ids, task_id)
  end
  
  return task_ids
end

--- 等待所有任务完成
--- @param timeout number|nil 超时时间（秒），nil表示无限等待
--- @return boolean 是否所有任务都完成
function M.wait_all(timeout)
  local start_time = os.clock()
  
  while true do
    -- 检查是否所有工作器都已完成
    local all_completed = true
    for _, worker in pairs(state.workers) do
      if worker.status == "running" then
        all_completed = false
        break
      end
    end
    
    if all_completed then
      return true
    end
    
    -- 检查超时
    if timeout and (os.clock() - start_time) > timeout then
      return false
    end
    
    -- 短暂等待后继续检查
    vim.wait(100, function() return false end)
  end
end

--- 获取工作器状态
--- @param worker_id integer 工作器ID
--- @return table|nil 工作器状态信息
function M.get_worker_status(worker_id)
  local worker = state.workers[worker_id]
  if worker then
    return worker:get_info()
  end
  return nil
end

--- 获取所有工作器状态
--- @return table 所有工作器状态列表
function M.get_all_worker_status()
  local status_list = {}
  
  for _, worker in pairs(state.workers) do
    table.insert(status_list, worker:get_info())
  end
  
  return status_list
end

--- 取消工作器
--- @param worker_id integer 工作器ID
--- @return boolean 是否成功取消
function M.cancel_worker(worker_id)
  -- 注意：在Lua/Neovim中无法真正取消正在运行的线程
  -- 这里只是标记工作器为取消状态
  local worker = state.workers[worker_id]
  if worker and worker.status == "running" then
    worker.status = "cancelled"
    return true
  end
  return false
end

--- 清理已完成的工作器
function M.cleanup_completed()
  local to_remove = {}
  
  for id, worker in pairs(state.workers) do
    if worker.status == "completed" or worker.status == "failed" or worker.status == "cancelled" then
      table.insert(to_remove, id)
    end
  end
  
  for _, id in ipairs(to_remove) do
    state.workers[id] = nil
  end
end

--- 设置最大工作器数量
--- @param max number 最大工作器数量
function M.set_max_workers(max)
  if max > 0 then
    state.max_workers = max
  end
end

--- 获取当前活动工作器数量
--- @return integer 活动工作器数量
function M.get_active_count()
  local count = 0
  for _, worker in pairs(state.workers) do
    if worker.status == "running" then
      count = count + 1
    end
  end
  return count
end

--- 异步测试运行器
--- @param test_suite table 测试套件
--- @param callback function 回调函数
function M.run_tests_async(test_suite, callback)
  local test_results = {
    total = 0,
    passed = 0,
    failed = 0,
    errored = 0,
    tests = {},
  }
  
  local completed_tests = 0
  local total_tests = #test_suite.tests
  
  -- 为每个测试创建异步任务
  local tasks = {}
  
  for i, test in ipairs(test_suite.tests) do
    table.insert(tasks, {
      name = "test_" .. test.name,
      task_func = function()
        local start_time = os.clock()
        local success, err = pcall(test.func)
        local duration = os.clock() - start_time
        
        return {
          name = test.name,
          success = success,
          error = not success and err or nil,
          duration = duration,
        }
      end,
      callback = function(success, result)
        completed_tests = completed_tests + 1
        
        if success then
          test_results.total = test_results.total + 1
          
          if result.success then
            test_results.passed = test_results.passed + 1
            result.status = "PASS"
          else
            test_results.failed = test_results.failed + 1
            result.status = "FAIL"
          end
        else
          test_results.total = test_results.total + 1
          test_results.errored = test_results.errored + 1
          result = {
            name = "unknown",
            status = "ERROR",
            error = result, -- 这里result是错误信息
            duration = 0,
          }
        end
        
        table.insert(test_results.tests, result)
        
        -- 所有测试完成后执行回调
        if completed_tests >= total_tests then
          if callback then
            callback(test_results)
          end
        end
      end,
    })
  end
  
  -- 批量提交任务
  return M.submit_batch(tasks)
end

--- 异步渲染任务
--- @param render_func function 渲染函数
--- @param callback function 回调函数
--- @return integer 任务ID
function M.render_async(render_func, callback)
  return M.submit_task("render_task", render_func, callback)
end

--- 初始化异步工作器
function M.initialize()
  -- 定期清理已完成的工作器
  vim.defer_fn(function()
    M.cleanup_completed()
    
    -- 每30秒清理一次
    vim.defer_fn(function()
      M.cleanup_completed()
    end, 30000)
  end, 30000)
  
  print("✅ 异步工作器已初始化")
end

return M