-- NeoAI 线程工具模块
-- 提供安全的线程操作工具函数

local M = {}

--- 安全地在后台执行CPU密集型任务
--- @param task_func function 任务函数（在后台执行）
--- @param callback function 回调函数（在主线程执行）
--- @param ... any 传递给任务函数的参数
function M.run_in_background(task_func, callback, ...)
  local args = {...}
  
  -- 使用vim.defer_fn在后台执行
  vim.defer_fn(function()
    -- 在后台执行任务
    local success, result_or_error = pcall(task_func, unpack(args))
    
    -- 在主线程中执行回调
    if callback then
      if success then
        callback(true, result_or_error)
      else
        callback(false, nil, result_or_error)
      end
    end
  end, 0)
end

--- 批量执行多个后台任务
--- @param tasks table 任务列表，每个元素为{func, args, callback}
--- @param final_callback function 所有任务完成后的回调
function M.run_batch_tasks(tasks, final_callback)
  local total_tasks = #tasks
  local completed_tasks = 0
  local results = {}
  local errors = {}
  
  if total_tasks == 0 then
    if final_callback then
      final_callback(true, results, errors)
    end
    return
  end
  
  for i, task in ipairs(tasks) do
    local task_func = task.func
    local task_args = task.args or {}
    local task_callback = task.callback
    
    M.run_in_background(function()
      return task_func(unpack(task_args))
    end, function(success, result, error_msg)
      -- 执行任务特定的回调
      if task_callback then
        task_callback(success, result, error_msg)
      end
      
      -- 记录结果
      if success then
        results[i] = result
      else
        errors[i] = error_msg
      end
      
      completed_tasks = completed_tasks + 1
      
      -- 所有任务完成
      if completed_tasks == total_tasks and final_callback then
        local all_success = #errors == 0
        final_callback(all_success, results, errors)
      end
    end)
  end
end

--- 创建线程安全的回调函数
--- @param callback function 原始回调函数
--- @return function 线程安全的回调函数
function M.create_thread_safe_callback(callback)
  if not callback then
    return nil
  end
  
  return function(...)
    local args = {...}
    vim.schedule(function()
      callback(unpack(args))
    end)
  end
end

--- 执行CPU密集型计算
--- @param compute_func function 计算函数
--- @param callback function 回调函数
function M.compute_heavy_task(compute_func, callback)
  M.run_in_background(compute_func, callback)
end

--- 延迟执行UI更新
--- @param update_func function UI更新函数
--- @param delay number 延迟时间（毫秒，默认为0）
function M.schedule_ui_update(update_func, delay)
  delay = delay or 0
  vim.defer_fn(function()
    vim.schedule(update_func)
  end, delay)
end

--- 批量UI更新
--- @param updates table UI更新函数列表
function M.batch_ui_updates(updates)
  vim.schedule(function()
    for _, update_func in ipairs(updates) do
      update_func()
    end
  end)
end

return M