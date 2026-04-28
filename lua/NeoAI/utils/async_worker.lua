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
-- 9. 多线程并行执行（使用 vim.fn.jobstart 启动子进程）

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

  -- 设置超时定时器（使用 vim.uv.new_timer，确保在 vim.wait 等待期间也能触发）
  if self.timeout_ms and self.timeout_ms > 0 then
    local timeout_timer = vim.uv.new_timer()
    timeout_timer:start(self.timeout_ms, 0, function()
      -- 这个回调在 libuv 事件循环中执行，需要用 vim.schedule 调度到主线程
      vim.schedule(function()
        if not state.workers[self.id] then
          return
        end
        if state.workers[self.id].status ~= "running" then
          return
        end

        self.timed_out = true
        self.status = "timeout"
        self.end_time = os.clock()
        self.duration = self.end_time - self.start_time
        self.error = "任务执行超时（" .. (self.timeout_ms / 1000) .. "秒）: " .. self.name
        state.workers[self.id] = nil

        -- 触发超时事件
        if self.events and self.events.error then
          vim.api.nvim_exec_autocmds("User", {
            pattern = self.events.error,
            data = vim.tbl_extend("keep", {
              worker_id = self.id,
              worker_name = self.name,
              error_msg = self.error,
              duration = self.duration,
            }, self.event_data),
          })
        end

        if self.callback then
          self.callback(false, nil, self.error, self:get_info())
        end
      end)
    end)
    -- 保存定时器引用，任务完成时取消
    self._timeout_timer = timeout_timer
  end

  -- 使用 vim.schedule 异步执行任务函数
  -- 这样不会阻塞主事件循环，多个工具可以并行执行
  vim.schedule(function()
    self:_run_task()
  end)

  return self.id
end

--- 内部：执行任务（通过 vim.schedule 异步执行）
-- 任务函数在 vim.schedule 回调中执行，不阻塞主事件循环。
-- 多个工具可以并行执行（每个工具一个 worker）。
--
-- 注意：工具函数内部不应使用 vim.wait 或 vim.uv.run('once') 同步等待，
-- 因为这些函数在 vim.schedule 回调中调用时会阻塞事件循环。
-- 工具函数应使用非阻塞方式（如 get_lsp_clients_nonblocking）立即返回结果或错误。
--
-- 超时保护：使用 vim.uv.new_timer 设置超时定时器，
-- 超时后标记 timed_out = true 并调用失败回调。
-- 注意：超时定时器无法中断正在执行的任务函数，
-- 但可以防止超时后回调仍然更新状态。
function Worker:_run_task()
  -- 再次检查是否已被取消或超时
  if not state.workers[self.id] then
    return
  end
  if self.status ~= "running" then
    return
  end

  -- 执行任务函数
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

    -- 触发完成事件
    if self.events and self.events.completed then
      vim.api.nvim_exec_autocmds("User", {
        pattern = self.events.completed,
        data = vim.tbl_extend("keep", {
          worker_id = self.id,
          worker_name = self.name,
          result = self.result,
          duration = self.duration,
        }, self.event_data),
      })
    end

    if self.callback then
      self.callback(true, self.result, nil, self:get_info())
    end
  else
    self.status = "failed"
    self.error = tostring(result_or_err)
    state.workers[self.id] = nil

    if self.events and self.events.error then
      vim.api.nvim_exec_autocmds("User", {
        pattern = self.events.error,
        data = vim.tbl_extend("keep", {
          worker_id = self.id,
          worker_name = self.name,
          error_msg = self.error,
          duration = self.duration,
        }, self.event_data),
      })
    end

    if self.callback then
      self.callback(false, nil, self.error, self:get_info())
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
  if result == nil then
    return ""
  end
  if type(result) == "string" then
    return result
  end
  if type(result) == "table" then
    local ok, e = pcall(vim.json.encode, result)
    if ok then
      return e
    end
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
    ids[i] = M.submit_task(t.name or ("batch_" .. i), t.task_func, t.callback, t.opts)
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

-- ========== thread_utils 内联函数 ==========
-- 以下函数从 thread_utils.lua 内联至此，提供更高级的线程操作工具

--- 安全地在后台执行CPU密集型任务
--- @param task_func function 任务函数（在后台执行）
--- @param callback function 回调函数（在主线程执行）
--- @param ... any 传递给任务函数的参数
function M.run_in_background(task_func, callback, ...)
  local args = { ... }

  vim.defer_fn(function()
    local success, result_or_error = pcall(task_func, unpack(args))

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
      if task_callback then
        task_callback(success, result, error_msg)
      end

      if success then
        results[i] = result
      else
        errors[i] = error_msg
      end

      completed_tasks = completed_tasks + 1

      if completed_tasks == total_tasks and final_callback then
        local all_success = #errors == 0
        final_callback(all_success, results, errors)
      end
    end)
  end
end

--- 创建线程安全的回调函数
--- @param callback function 原始回调函数
--- @return function|nil 线程安全的回调函数
function M.create_thread_safe_callback(callback)
  if not callback then
    return nil
  end

  return function(...)
    local args = { ... }
    vim.schedule(function()
      callback(unpack(args))
    end)
  end
end

--- 执行CPU密集型计算（等同于 submit_task 的简化封装）
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

-- ========== 多线程并行执行（使用 vim.fn.jobstart） ==========

--- 序列化任务函数为 Lua 代码字符串
--- 将工具函数及其参数序列化为可在子进程中执行的 Lua 代码
--- @param task_func function 任务函数
--- @param ... any 参数
--- @return string|nil, string|nil Lua 代码字符串或错误信息
local function _serialize_task(task_func, ...)
  local args = { ... }
  -- 获取函数的源代码
  local info = debug.getinfo(task_func, "uS")
  if not info then
    return nil, "无法获取函数信息"
  end

  -- 对于匿名函数，尝试获取其源代码
  local source = nil
  if info.linedefined and info.linedefined > 0 then
    -- 函数定义在文件中，读取源代码
    local filepath = info.source:match("^@(.+)$")
    if filepath then
      local fd = io.open(filepath, "r")
      if fd then
        local lines = {}
        for line in fd:lines() do
          table.insert(lines, line)
        end
        fd:close()
        -- 提取函数体（从 linedefined 到 lastlinedefined）
        local func_lines = {}
        for i = info.linedefined, info.lastlinedefined do
          table.insert(func_lines, lines[i] or "")
        end
        source = table.concat(func_lines, "\n")
      end
    end
  end

  if not source then
    -- 无法获取源代码，使用 C 函数或内联函数
    return nil, "无法序列化函数：仅支持 Lua 定义的函数"
  end

  -- 序列化参数
  local serialized_args = {}
  for _, arg in ipairs(args) do
    if type(arg) == "string" then
      table.insert(serialized_args, string.format("%q", arg))
    elseif type(arg) == "number" or type(arg) == "boolean" then
      table.insert(serialized_args, tostring(arg))
    elseif type(arg) == "table" then
      local ok, json = pcall(vim.json.encode, arg)
      if ok then
        table.insert(serialized_args, json)
      else
        table.insert(serialized_args, tostring(arg))
      end
    else
      table.insert(serialized_args, tostring(arg))
    end
  end

  -- 构建完整的 Lua 代码
  local code = string.format([[
local function task_func(...)
%s
end

local args = {%s}
local results = {pcall(task_func, unpack(args))}
if results[1] then
  -- 成功：返回序列化的结果
  local result = results[2]
  if type(result) == "table" then
    local ok, json = pcall(vim.json.encode, result)
    if ok then
      io.write("__RESULT__" .. json)
    else
      io.write("__RESULT__" .. tostring(result))
    end
  elseif type(result) == "string" then
    io.write("__RESULT__" .. result)
  else
    io.write("__RESULT__" .. tostring(result))
  end
else
  -- 失败
  io.write("__ERROR__" .. tostring(results[2]))
end
]], source, table.concat(serialized_args, ", "))

  return code, nil
end

--- 使用 vim.fn.jobstart 在子进程中并行执行工具
--- 适用于不依赖 Neovim API 的工具（文件读写、搜索等）
--- 依赖 Neovim API 的工具（LSP、缓冲区操作）应使用 submit_task
--- @param name string 任务名称
--- @param task_func function 任务函数（必须是纯 Lua 函数，不依赖 Neovim API）
--- @param callback function|nil 回调函数 (success, result, error_msg, worker_info)
--- @param opts table|nil 附加选项
---   timeout_ms: number - 超时时间（毫秒）
---   auto_serialize: boolean - 是否自动序列化结果（默认 true）
--- @return integer|nil 任务ID，失败返回 nil
function M.submit_parallel_task(name, task_func, callback, opts)
  _cleanup_completed()

  local active = _check_concurrency()
  if active >= state.max_workers then
    error(string.format("已达到最大工作器数量限制 (%d)", state.max_workers))
  end

  opts = opts or {}
  local timeout_ms = opts.timeout_ms or 30000

  -- 序列化任务函数
  local code, err = _serialize_task(task_func)
  if not code then
    logger.debug("[async_worker] submit_parallel_task: 无法序列化函数 " .. name .. ": " .. tostring(err))
    -- 回退到普通 submit_task
    return M.submit_task(name, task_func, callback, opts)
  end

  -- 创建临时 Lua 脚本文件
  local tmpfile = vim.fn.tempname() .. ".lua"
  local fd, open_err = vim.uv.fs_open(tmpfile, "w", 438)
  if not fd then
    logger.debug("[async_worker] submit_parallel_task: 无法创建临时文件: " .. tostring(open_err))
    return M.submit_task(name, task_func, callback, opts)
  end
  vim.uv.fs_write(fd, code, 0)
  vim.uv.fs_close(fd)

  local worker_id = state.next_worker_id
  state.next_worker_id = state.next_worker_id + 1

  local worker_info = {
    id = worker_id,
    name = name,
    status = "running",
    start_time = os.clock(),
    end_time = nil,
    duration = nil,
    result = nil,
    error = nil,
    timed_out = false,
    _tmpfile = tmpfile,
    _job_id = nil,
    _timeout_timer = nil,
  }
  state.workers[worker_id] = worker_info

  -- 构建命令：lua tmpfile.lua
  local lua_cmd = "lua"
  if vim.fn.executable("luajit") == 1 then
    lua_cmd = "luajit"
  end

  local stdout_data = {}
  local stderr_data = {}

  local job_id = vim.fn.jobstart({ lua_cmd, tmpfile }, {
    cwd = vim.fn.getcwd(),
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          table.insert(stdout_data, line)
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          table.insert(stderr_data, line)
        end
      end
    end,
    on_exit = function(_, exit_code)
      -- 清理临时文件
      pcall(vim.uv.fs_unlink, tmpfile)

      -- 检查是否已被取消或超时
      local w = state.workers[worker_id]
      if not w then
        return
      end
      if w.timed_out then
        return
      end
      if w.status ~= "running" then
        return
      end

      -- 取消超时定时器
      if w._timeout_timer then
        pcall(function()
          if not w._timeout_timer:is_closing() then
            w._timeout_timer:stop()
            w._timeout_timer:close()
          end
        end)
        w._timeout_timer = nil
      end

      w.end_time = os.clock()
      w.duration = w.end_time - w.start_time

      if exit_code == 0 then
        -- 解析 stdout
        local output = table.concat(stdout_data, "")
        local result_str = output:match("__RESULT__(.+)")
        if result_str then
          w.status = "completed"
          w.result = result_str
          state.workers[worker_id] = nil

          if callback then
            callback(true, result_str, nil, w)
          end
        else
          w.status = "failed"
          w.error = "子进程输出格式错误: " .. output
          state.workers[worker_id] = nil

          if callback then
            callback(false, nil, w.error, w)
          end
        end
      else
        w.status = "failed"
        w.error = table.concat(stderr_data, "")
        if w.error == "" then
          w.error = "子进程退出码: " .. exit_code
        end
        state.workers[worker_id] = nil

        if callback then
          callback(false, nil, w.error, w)
        end
      end
    end,
  })

  if job_id <= 0 then
    -- jobstart 失败，清理并回退
    pcall(vim.uv.fs_unlink, tmpfile)
    state.workers[worker_id] = nil
    logger.debug("[async_worker] submit_parallel_task: jobstart 失败，回退到 submit_task")
    return M.submit_task(name, task_func, callback, opts)
  end

  worker_info._job_id = job_id

  -- 设置超时定时器
  if timeout_ms and timeout_ms > 0 then
    local timeout_timer = vim.uv.new_timer()
    timeout_timer:start(timeout_ms, 0, function()
      vim.schedule(function()
        local w = state.workers[worker_id]
        if not w then
          return
        end
        if w.status ~= "running" then
          return
        end

        w.timed_out = true
        w.status = "timeout"
        w.end_time = os.clock()
        w.duration = w.end_time - w.start_time
        w.error = "任务执行超时（" .. (timeout_ms / 1000) .. "秒）: " .. name
        state.workers[worker_id] = nil

        -- 停止子进程
        if w._job_id then
          pcall(vim.fn.jobstop, w._job_id)
        end

        -- 清理临时文件
        pcall(vim.uv.fs_unlink, tmpfile)

        if callback then
          callback(false, nil, w.error, w)
        end
      end)
    end)
    worker_info._timeout_timer = timeout_timer
  end

  return worker_id
end

--- 批量提交并行任务
--- @param tasks table 任务列表，每个元素为 { name, task_func, callback, opts }
--- @return table 任务ID列表
function M.submit_parallel_batch(tasks)
  local ids = {}
  for i, t in ipairs(tasks) do
    ids[i] = M.submit_parallel_task(t.name or ("parallel_" .. i), t.task_func, t.callback, t.opts)
  end
  return ids
end

--- 检查是否支持并行执行（lua 或 luajit 是否可用）
--- @return boolean
function M.is_parallel_supported()
  return vim.fn.executable("lua") == 1 or vim.fn.executable("luajit") == 1
end

return M
