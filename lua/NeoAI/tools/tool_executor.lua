-- NeoAI 工具执行器模块
-- 该模块负责安全地执行和管理各种工具，包括参数验证、错误处理、重试机制和历史记录
local M = {}

-- 导入依赖模块
local tool_registry = require("NeoAI.tools.tool_registry")
local tool_validator = require("NeoAI.tools.tool_validator")
local Events = require("NeoAI.core.events.event_constants")
local json = require("NeoAI.utils.json")
local thread_utils = require("NeoAI.utils.thread_utils")

-- 递归解析参数中的 JSON 字符串字段
-- 支持：
--   1. 整个 args 是 JSON 字符串
--   2. 某个字段值是 JSON 字符串（如 file = '{"filepath":"..."}'）
--   3. 嵌套表中的 JSON 字符串
--   4. 已经是表的保持不变
local function resolve_json_args(args)
  if args == nil then
    return args
  end

  -- 如果整个 args 是 JSON 字符串，直接解析
  if type(args) == "string" then
    local ok, decoded = pcall(json.decode, args)
    if ok and type(decoded) == "table" then
      return resolve_json_args(decoded)
    end
    return args
  end

  if type(args) ~= "table" then
    return args
  end

  local result = {}
  for k, v in pairs(args) do
    if type(v) == "string" then
      -- 尝试解析 JSON 字符串
      local ok, decoded = pcall(json.decode, v)
      if ok then
        -- 解析成功，递归处理解析结果
        result[k] = resolve_json_args(decoded)
      else
        -- 不是 JSON 字符串，保持原样
        result[k] = v
      end
    elseif type(v) == "table" then
      -- 递归处理子表
      result[k] = resolve_json_args(v)
    else
      result[k] = v
    end
  end
  return result
end

-- 检查 vim 模块是否可用，如果不可用则使用简单的深拷贝函数
local function deep_copy(obj, seen)
  -- 如果不是表，直接返回值
  if type(obj) ~= "table" then
    return obj
  end

  -- 如果已经拷贝过这个表，返回之前拷贝的结果（处理循环引用）
  if seen and seen[obj] then
    return seen[obj]
  end

  local s = seen or {}
  local res = {}
  s[obj] = res

  -- 递归拷贝表中的所有元素
  for k, v in pairs(obj) do
    -- 修复：键不需要深拷贝，保持原样
    res[k] = deep_copy(v, s)
  end

  return setmetatable(res, getmetatable(obj))
end

-- 使用 vim.deepcopy 如果可用，否则使用自定义的深拷贝函数
local vim_deepcopy = vim and vim.deepcopy or deep_copy

-- 跨平台睡眠函数
-- @param seconds number 睡眠的秒数
local function sleep(seconds)
  if package.config:sub(1, 1) == "\\" then
    -- Windows 系统
    os.execute("timeout /T " .. math.floor(seconds) .. " /NOBREAK > NUL 2>&1")
  else
    -- Unix/Linux/Mac 系统
    os.execute("sleep " .. seconds)
  end
end

-- 模块状态
local state = {
  initialized = false, -- 是否已初始化
  config = nil, -- 配置信息
  execution_history = {}, -- 执行历史记录
  max_history_size = 100, -- 历史记录最大数量
}

--- 初始化工具执行器
--- @param config table 配置表
function M.initialize(config)
  if state.initialized then
    return
  end

  state.config = config or {}
  state.max_history_size = config.max_history_size or 100
  state.execution_history = {}
  state.initialized = true
end

--- 执行工具（同步模式）
--- @param tool_name string 工具名称
--- @param args table 工具参数
--- @return any 执行结果
function M.execute(tool_name, args)
  if not state.initialized then
    print("[tool_executor] execute 失败: 未初始化")
    error("工具执行器未初始化，请先调用 M.initialize(config)")
  end

  if not tool_name then
    print("[tool_executor] execute 失败: 工具名称为空")
    error("工具名称是必需的")
  end

  print("[tool_executor] execute 开始: " .. tool_name)

  -- 获取工具定义
  local tool = tool_registry.get(tool_name)
  if not tool then
    local error_msg = "工具不存在: " .. tool_name
    print("[tool_executor] execute 失败: " .. error_msg)
    M._record_execution(tool_name, args, nil, error_msg)
    return error_msg
  end
  print("[tool_executor] 找到工具定义: " .. tool_name)

  -- 预处理：解析 JSON 字符串参数
  local resolved_args = resolve_json_args(args)

  -- 验证参数
  local valid, error_msg = M.validate_args(tool, resolved_args)
  if not valid then
    print("[tool_executor] 参数验证失败: " .. (error_msg or "未知错误"))
    M._record_execution(tool_name, args, nil, error_msg)
    -- 生成调用示例
    local example = M._generate_example(tool)
    if example then
      return error_msg .. "\n\n调用示例:\n" .. example
    end
    return error_msg
  end
  print("[tool_executor] 参数验证通过")

  -- 检查权限
  if tool.permissions then
    local has_permission, perm_error = tool_validator.check_permissions(tool)
    if not has_permission then
      print("[tool_executor] 权限检查失败: " .. (perm_error or "无权限"))
      M._record_execution(tool_name, args, nil, perm_error)
      return perm_error
    end
    print("[tool_executor] 权限检查通过")
  end

  -- 记录开始时间
  local start_time = os.time()

  -- 触发工具执行开始事件
  if vim and vim.api and vim.api.nvim_exec_autocmds then
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.TOOL_EXECUTION_STARTED,
      data = { tool_name = tool_name, args = args, start_time = start_time },
    })
  end

  -- 从配置获取重试参数
  local max_retries = state.config.max_retries or 0
  local retry_delay = state.config.retry_delay or 1

  print("[tool_executor] 调用 safe_call: max_retries=" .. max_retries .. ", retry_delay=" .. retry_delay)

  -- 安全调用工具函数（使用解析后的参数）
  local result, call_error = M.safe_call(tool.func, resolved_args, max_retries, retry_delay)
  local end_time = os.time()
  local duration = end_time - start_time

  print("[tool_executor] safe_call 返回: result=" .. tostring(result) .. ", error=" .. tostring(call_error))

  -- 触发工具执行完成事件
  if vim and vim.api and vim.api.nvim_exec_autocmds then
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.TOOL_EXECUTION_COMPLETED,
      data = { tool_name = tool_name, args = args, result = result, duration = duration },
    })
  end

  -- 处理执行结果
  if call_error and call_error ~= "" then
    local full_error_msg = "工具执行错误: " .. call_error
    print("[tool_executor] 执行错误: " .. full_error_msg)

    -- 触发工具执行错误事件
    if vim and vim.api and vim.api.nvim_exec_autocmds then
      vim.api.nvim_exec_autocmds("User", {
        pattern = Events.TOOL_EXECUTION_ERROR,
        data = { tool_name = tool_name, args = args, error_msg = full_error_msg, duration = duration },
      })
    end

    M._record_execution(tool_name, args, nil, full_error_msg, duration)
    return M.handle_error(full_error_msg)
  end

  -- 格式化结果
  local formatted_result = M.format_result(result)
  print("[tool_executor] 执行成功, 结果长度=" .. #tostring(formatted_result))

  -- 记录执行历史
  M._record_execution(tool_name, args, formatted_result, nil, duration)

  print("[tool_executor] execute 结束: " .. tool_name)
  return formatted_result
end

--- 在后台线程中执行工具（使用 jobstart）
--- @param tool_name string 工具名称
--- @param args table 工具参数
--- @param callback function|nil 回调函数，接收 (success, result_or_error)
--- @return string|nil 任务 ID，失败返回 nil
function M.execute_in_thread(tool_name, args, callback)
  if not state.initialized then
    print("[tool_executor] execute_in_thread 失败: 未初始化")
    error("工具执行器未初始化")
  end

  if not tool_name then
    print("[tool_executor] execute_in_thread 失败: 工具名称为空")
    error("工具名称是必需的")
  end

  print("[tool_executor] execute_in_thread 开始: " .. tool_name)

  -- 获取工具定义
  local tool = tool_registry.get(tool_name)
  if not tool then
    local error_msg = "工具不存在: " .. tool_name
    print("[tool_executor] execute_in_thread 失败: " .. error_msg)
    M._record_execution(tool_name, args, nil, error_msg)
    if callback then
      callback(false, error_msg)
    end
    return nil
  end

  -- 预处理：解析 JSON 字符串参数
  local resolved_args = resolve_json_args(args)

  -- 验证参数
  local valid, error_msg = M.validate_args(tool, resolved_args)
  if not valid then
    print("[tool_executor] 参数验证失败: " .. (error_msg or "未知错误"))
    M._record_execution(tool_name, args, nil, error_msg)
    if callback then
      callback(false, error_msg)
    end
    return nil
  end

  -- 检查权限
  if tool.permissions then
    local has_permission, perm_error = tool_validator.check_permissions(tool)
    if not has_permission then
      print("[tool_executor] 权限检查失败: " .. (perm_error or "无权限"))
      M._record_execution(tool_name, args, nil, perm_error)
      if callback then
        callback(false, perm_error)
      end
      return nil
    end
  end

  -- 记录开始时间
  local start_time = os.time()

  -- 触发工具执行开始事件
  if vim and vim.api and vim.api.nvim_exec_autocmds then
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.TOOL_EXECUTION_STARTED,
      data = { tool_name = tool_name, args = args, start_time = start_time },
    })
  end

  -- 生成任务 ID
  local task_id = "thread_" .. tool_name .. "_" .. os.time() .. "_" .. math.random(1000, 9999)

  -- 使用 thread_utils 在后台执行
  thread_utils.run_in_background(
    -- 后台任务函数
    function()
      local max_retries = state.config.max_retries or 0
      local retry_delay = state.config.retry_delay or 1
      return M.safe_call(tool.func, resolved_args, max_retries, retry_delay)
    end,
    -- 回调函数（在主线程执行）
    function(success, result, error_msg)
      local end_time = os.time()
      local duration = end_time - start_time

      if success then
        local formatted_result = M.format_result(result)
        print("[tool_executor] 线程执行成功: " .. tool_name)

        -- 触发工具执行完成事件
        if vim and vim.api and vim.api.nvim_exec_autocmds then
          vim.api.nvim_exec_autocmds("User", {
            pattern = Events.TOOL_EXECUTION_COMPLETED,
            data = { tool_name = tool_name, args = args, result = formatted_result, duration = duration },
          })
        end

        M._record_execution(tool_name, args, formatted_result, nil, duration)

        if callback then
          callback(true, formatted_result)
        end
      else
        local full_error_msg = "工具执行错误: " .. (error_msg or "未知错误")
        print("[tool_executor] 线程执行错误: " .. full_error_msg)

        -- 触发工具执行错误事件
        if vim and vim.api and vim.api.nvim_exec_autocmds then
          vim.api.nvim_exec_autocmds("User", {
            pattern = Events.TOOL_EXECUTION_ERROR,
            data = { tool_name = tool_name, args = args, error_msg = full_error_msg, duration = duration },
          })
        end

        M._record_execution(tool_name, args, nil, full_error_msg, duration)

        if callback then
          callback(false, M.handle_error(full_error_msg))
        end
      end
    end
  )

  print("[tool_executor] execute_in_thread 已提交: " .. tool_name)
  return task_id
end

--- 使用 jobstart 执行外部命令工具
--- @param cmd string|table 命令或命令列表
--- @param opts table 选项
--- @param callback function|nil 回调函数
--- @return number|nil job_id
function M.execute_command(cmd, opts, callback)
  opts = opts or {}

  -- 确保 cmd 是 table 格式
  if type(cmd) == "string" then
    cmd = vim.fn.split(cmd, " ")
  end

  local timeout = opts.timeout or 30000 -- 默认 30 秒超时
  local cwd = opts.cwd or vim.fn.getcwd()
  local env = opts.env or {}

  print("[tool_executor] execute_command: " .. table.concat(cmd, " "))

  local job_id = vim.fn.jobstart(cmd, {
    cwd = cwd,
    env = env,

    on_stdout = function(_, data)
      if opts.on_stdout then
        opts.on_stdout(data)
      end
    end,

    on_stderr = function(_, data)
      if opts.on_stderr then
        opts.on_stderr(data)
      end
    end,

    on_exit = function(_, exit_code)
      print("[tool_executor] 命令退出，代码: " .. exit_code)
      if callback then
        callback(exit_code == 0, exit_code)
      end
    end,
  })

  if job_id <= 0 then
    print("[tool_executor] 启动命令失败")
    if callback then
      callback(false, -1)
    end
    return nil
  end

  -- 设置超时
  if timeout > 0 then
    vim.defer_fn(function()
      local job_info = vim.fn.job_info(job_id)
      if job_info and job_info.status == "run" then
        print("[tool_executor] 命令超时，停止 job_id=" .. job_id)
        vim.fn.jobstop(job_id)
        if callback then
          callback(false, "timeout")
        end
      end
    end, timeout)
  end

  return job_id
end

--- 停止正在执行的命令
--- @param job_id number job ID
function M.stop_command(job_id)
  if not job_id then
    return
  end
  print("[tool_executor] 停止命令: job_id=" .. job_id)
  vim.fn.jobstop(job_id)
end

--- 执行工具（别名，用于兼容性）
--- @param tool_name string 工具名称
--- @param args table 参数
--- @return any 执行结果
function M.execute_tool(tool_name, args)
  return M.execute(tool_name, args)
end

--- 验证参数
--- @param tool table 工具定义
--- @param args table 参数
--- @return boolean, string|nil 是否有效，错误信息（成功时为nil）
function M.validate_args(tool, args)
  if not tool then
    print("[tool_executor] validate_args: 工具定义无效")
    return false, "工具定义无效"
  end

  -- 如果没有参数定义，接受任何参数
  if not tool.parameters then
    print("[tool_executor] validate_args: 无参数定义，接受任何参数")
    return true, ""
  end

  -- 使用工具验证器验证参数
  local valid, err = tool_validator.validate_parameters(tool.parameters, args)
  print("[tool_executor] validate_args: valid=" .. tostring(valid) .. ", err=" .. tostring(err))
  return valid, err
end

--- 格式化结果
--- @param result any 原始结果
--- @return string 格式化后的结果
function M.format_result(result)
  if result == nil then
    print("[tool_executor] format_result: nil -> 'null'")
    return "null"
  end

  local result_type = type(result)
  print("[tool_executor] format_result: type=" .. result_type)

  if result_type == "string" then
    print("[tool_executor] format_result: 字符串, 长度=" .. #result)
    return result
  elseif result_type == "number" or result_type == "boolean" then
    local str = tostring(result)
    print("[tool_executor] format_result: " .. result_type .. " -> " .. str)
    return str
  elseif result_type == "table" then
    -- 尝试转换为JSON
    local json_encode = vim and vim.json and vim.json.encode
    if json_encode then
      local ok, json = pcall(json_encode, result)
      if ok then
        print("[tool_executor] format_result: table -> JSON, 长度=" .. #json)
        return json
      end
    end

    -- 如果无法转换为JSON，使用简单的表格表示
    local str = M._table_to_string(result)
    print("[tool_executor] format_result: table -> string, 长度=" .. #str)
    return str
  else
    local str = tostring(result)
    print("[tool_executor] format_result: " .. result_type .. " -> " .. str)
    return str
  end
end

--- 将表格转换为字符串（内部使用）
--- @param tbl table 表格
--- @return string 字符串表示
function M._table_to_string(tbl)
  if not tbl or type(tbl) ~= "table" then
    return "{}"
  end

  local result = { "{" }
  for k, v in pairs(tbl) do
    local key_str = type(k) == "string" and '"' .. k .. '"' or tostring(k)
    local value_str

    if type(v) == "table" then
      value_str = M._table_to_string(v)
    elseif type(v) == "string" then
      value_str = '"' .. v .. '"'
    else
      value_str = tostring(v)
    end

    table.insert(result, "  " .. key_str .. ": " .. value_str)
  end

  table.insert(result, "}")
  return table.concat(result, "\n")
end

--- 处理错误
--- @param error_msg string 错误信息
--- @return string 格式化后的错误信息
function M.handle_error(error_msg)
  print("[tool_executor] handle_error: " .. error_msg)

  -- 分析错误类型
  local error_type = "未知错误"

  if string.find(error_msg, "参数") then
    error_type = "参数错误"
  elseif string.find(error_msg, "权限") then
    error_type = "权限错误"
  elseif string.find(error_msg, "不存在") or string.find(error_msg, "未找到") then
    error_type = "资源不存在错误"
  elseif string.find(error_msg, "超时") then
    error_type = "超时错误"
  elseif string.find(error_msg, "网络") then
    error_type = "网络错误"
  elseif string.find(error_msg, "内存") then
    error_type = "内存错误"
  end

  -- 构建详细的错误信息
  local detailed_error = string.format("[%s] %s\n时间: %s", error_type, error_msg, os.date("%Y-%m-%d %H:%M:%S"))

  -- 记录到日志（如果配置了日志）
  if state.config and state.config.log_errors then
    M._log_error(detailed_error)
  end

  print("[tool_executor] handle_error 返回: " .. detailed_error)
  return detailed_error
end

--- 记录错误日志
--- @param error_msg string 错误信息
function M._log_error(error_msg)
  -- 简单的日志记录实现
  -- 在实际项目中，可以集成到现有的日志系统中
  local log_file = state.config.error_log_file
    or (vim and vim.fn.stdpath("cache") .. "/neoai_tools_error.log" or "./neoai_tools_error.log")

  local file = io.open(log_file, "a")
  if file then
    file:write(error_msg .. "\n\n")
    file:close()
  end
end

--- 安全调用函数
--- @param func function 要调用的函数
--- @param args table 函数参数
--- @param max_retries number 最大重试次数
--- @param retry_delay number 重试延迟（秒）
--- @return any, string|nil 执行结果，错误信息（成功时为nil）
function M.safe_call(func, args, max_retries, retry_delay)
  if not func then
    print("[tool_executor] safe_call: 函数为空")
    return nil, "函数不能为空"
  end

  max_retries = max_retries or 0
  retry_delay = retry_delay or 1

  local last_error = nil

  for attempt = 0, max_retries do
    if attempt > 0 then
      print("[tool_executor] safe_call: 第 " .. attempt .. " 次重试...")
      -- 重试前等待
      sleep(retry_delay)
    end

    local start_time = os.time()
    print("[tool_executor] safe_call: 调用函数 (attempt=" .. attempt .. ")")
    -- 使用 select 捕获所有返回值，避免 pcall 只捕获第一个返回值
    local success, result, err_msg = pcall(func, args)
    -- 如果函数返回了多个值（如 return nil, "error msg"），pcall 只捕获前两个
    -- 但我们可以通过检查 result 是否为 nil 且函数约定返回 nil, err 来判断
    if not success then
      -- pcall 捕获到异常（函数内部抛出的 error）
      last_error = tostring(result)
      print("[tool_executor] safe_call: pcall 异常 - " .. last_error)
      if attempt < max_retries then
        local should_retry = M._should_retry_error(last_error)
        print("[tool_executor] safe_call: 是否重试? " .. tostring(should_retry))
        if not should_retry then
          break
        end
      end
    else
      -- 函数正常执行完毕
      -- 检查函数是否返回了错误（约定：返回 nil, error_msg）
      if result == nil and err_msg ~= nil then
        -- 函数返回了 nil, error_msg
        last_error = tostring(err_msg)
        print("[tool_executor] safe_call: 函数返回错误 - " .. last_error)
        if attempt < max_retries then
          local should_retry = M._should_retry_error(last_error)
          print("[tool_executor] safe_call: 是否重试? " .. tostring(should_retry))
          if not should_retry then
            break
          end
        end
      else
        -- 函数执行成功，返回结果
        print("[tool_executor] safe_call: 执行成功")
        return result, nil
      end
    end
    local end_time = os.time()
    local duration = end_time - start_time
  end

  print("[tool_executor] safe_call: 最终失败 - " .. (last_error or "未知错误"))
  return nil, "安全调用失败: " .. (last_error or "未知错误")
end

--- 判断错误是否应该重试
--- @param error_msg string 错误信息
--- @return boolean 是否应该重试
function M._should_retry_error(error_msg)
  -- 默认重试所有错误
  -- 可以在这里添加逻辑来过滤不应该重试的错误

  -- 不应该重试的错误示例：
  -- 1. 参数验证错误
  -- 2. 权限错误
  -- 3. 资源不存在错误

  local non_retryable_errors = {
    "参数",
    "权限",
    "不存在",
    "无效",
    "未找到",
    "未初始化",
  }

  for _, error_pattern in ipairs(non_retryable_errors) do
    if string.find(error_msg, error_pattern) then
      print("[tool_executor] _should_retry_error: 匹配到不可重试模式 '" .. error_pattern .. "'，不重试")
      return false
    end
  end

  print("[tool_executor] _should_retry_error: 可重试")
  return true
end

--- 清理资源
function M.cleanup()
  if not state.initialized then
    return
  end

  -- 清理执行历史
  if #state.execution_history > state.max_history_size then
    local excess = #state.execution_history - state.max_history_size
    print("[tool_executor] cleanup: 清理 " .. excess .. " 条旧记录")
    for i = 1, excess do
      table.remove(state.execution_history, 1)
    end
  end
end

--- 获取执行历史
--- @param limit number 限制数量
--- @return table 执行历史
function M.get_execution_history(limit)
  if not state.initialized then
    error("工具执行器未初始化")
  end

  limit = limit or state.max_history_size
  local start_index = math.max(1, #state.execution_history - limit + 1)
  local result = {}

  for i = start_index, #state.execution_history do
    table.insert(result, vim_deepcopy(state.execution_history[i]))
  end

  return result
end

--- 清空执行历史
function M.clear_history()
  if not state.initialized then
    error("工具执行器未初始化")
  end

  state.execution_history = {}
end

--- 获取最近执行
--- @param tool_name string|nil 工具名称（可选）
--- @return table|nil 最近执行记录
function M.get_recent_execution(tool_name)
  if not state.initialized then
    error("工具执行器未初始化")
  end

  for i = #state.execution_history, 1, -1 do
    local record = state.execution_history[i]
    if not tool_name or record.tool_name == tool_name then
      return vim_deepcopy(record)
    end
  end

  return nil
end

--- 获取工具执行统计
--- @param tool_name string|nil 工具名称（可选）
--- @return table 执行统计
function M.get_execution_stats(tool_name)
  if not state.initialized then
    error("工具执行器未初始化")
  end

  local stats = {
    total_executions = 0,
    successful_executions = 0,
    failed_executions = 0,
    total_duration = 0,
    avg_duration = 0,
  }

  for _, record in ipairs(state.execution_history) do
    if not tool_name or record.tool_name == tool_name then
      stats.total_executions = stats.total_executions + 1

      if record.success then
        stats.successful_executions = stats.successful_executions + 1
      else
        stats.failed_executions = stats.failed_executions + 1
      end

      if record.duration then
        stats.total_duration = stats.total_duration + record.duration
      end
    end
  end

  if stats.total_executions > 0 then
    stats.avg_duration = stats.total_duration / stats.total_executions
  end

  return stats
end

--- 记录执行（内部使用）
--- @param tool_name string 工具名称
--- @param args table 参数
--- @param result any 结果
--- @param error_msg string|nil 错误信息
--- @param duration number|nil 执行时长
function M._record_execution(tool_name, args, result, error_msg, duration)
  local success = error_msg == nil
  print(
    "[tool_executor] _record_execution: "
      .. tool_name
      .. ", success="
      .. tostring(success)
      .. ", duration="
      .. tostring(duration)
  )

  local record = {
    tool_name = tool_name,
    args = vim_deepcopy(args),
    result = result,
    error = error_msg,
    success = success,
    timestamp = os.time(),
    duration = duration or 0,
  }

  table.insert(state.execution_history, record)
  print("[tool_executor] 历史记录数: " .. #state.execution_history)

  -- 清理旧记录
  M.cleanup()
end

--- 批量执行工具
--- @param executions table 执行列表，格式为 {{tool_name, args}, ...}
--- @return table 执行结果列表
function M.batch_execute(executions)
  if not state.initialized then
    print("[tool_executor] batch_execute 失败: 未初始化")
    error("工具执行器未初始化")
  end

  print("[tool_executor] batch_execute: " .. #executions .. " 个任务")
  local results = {}

  for i, exec in ipairs(executions) do
    local tool_name = exec[1]
    local args = exec[2] or {}

    print("[tool_executor] batch_execute #" .. i .. ": " .. tool_name)
    local result = M.execute(tool_name, args)
    table.insert(results, {
      tool_name = tool_name,
      args = args,
      result = result,
    })
  end

  print("[tool_executor] batch_execute 完成")
  return results
end

--- 异步执行工具（使用 thread_utils 在后台执行）
--- @param tool_name string 工具名称
--- @param args table 参数
--- @param callback function 回调函数
function M.execute_async(tool_name, args, callback)
  if not state.initialized then
    print("[tool_executor] execute_async 失败: 未初始化")
    error("工具执行器未初始化")
  end

  if not callback or type(callback) ~= "function" then
    print("[tool_executor] execute_async 失败: 缺少回调函数")
    error("回调函数是必需的")
  end

  print("[tool_executor] execute_async: " .. tool_name)

  -- 使用 execute_in_thread 在后台执行
  M.execute_in_thread(tool_name, args, function(success, result)
    print("[tool_executor] execute_async 执行完成，调用回调")
    callback(result)
  end)
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    print("[tool_executor] update_config 跳过: 未初始化")
    return
  end

  print("[tool_executor] update_config")
  state.config = vim.tbl_extend("force", state.config, new_config or {})
  state.max_history_size = state.config.max_history_size or state.max_history_size
  print("[tool_executor] update_config 完成")
end

-- 测试函数
local function test_module()
  vim.notify("=== 测试 NeoAI 工具执行器模块 ===")

  -- 模拟工具注册表
  local mock_tool_registry = {
    get = function(name)
      if name == "test_tool" then
        return {
          name = "test_tool",
          func = function(args)
            vim.notify("执行测试工具，参数:", args and args.param1 or "无参数")
            return { success = true, message = "执行成功", data = args }
          end,
          parameters = {
            { name = "param1", type = "string", optional = false },
          },
        }
      end
      return nil
    end,
  }

  -- 模拟工具验证器
  local mock_tool_validator = {
    validate_parameters = function(params, args)
      if params and #params > 0 and (not args or not args.param1) then
        return false, "缺少必需参数: param1"
      end
      return true, nil
    end,
    check_permissions = function(tool)
      return true, nil
    end,
  }

  -- 替换依赖模块
  local original_registry = tool_registry
  local original_validator = tool_validator

  tool_registry = mock_tool_registry
  tool_validator = mock_tool_validator

  -- 测试1: 初始化
  M.initialize({
    max_history_size = 10,
    max_retries = 2,
    retry_delay = 0.1,
    log_errors = true,
  })

  vim.notify("1. 初始化成功")

  -- 测试2: 执行工具（成功）
  vim.notify("\n2. 执行工具（成功）:")
  local result1 = M.execute("test_tool", { param1 = "测试参数" })
  vim.notify("执行结果:", result1)

  -- 测试3: 执行工具（参数验证失败）
  vim.notify("\n3. 执行工具（参数验证失败）:")
  local result2 = M.execute("test_tool", { wrong_param = "错误参数" })
  vim.notify("执行结果:", result2)

  -- 测试4: 执行不存在的工具
  vim.notify("\n4. 执行不存在的工具:")
  local result3 = M.execute("non_existent_tool", {})
  vim.notify("执行结果:", result3)

  -- 测试5: 获取执行历史
  vim.notify("\n5. 获取执行历史:")
  local history = M.get_execution_history(10)
  vim.notify("历史记录数量:", #history)
  for i, record in ipairs(history) do
    vim.notify(string.format("  [%d] %s: %s", i, record.tool_name, record.success and "成功" or "失败"))
  end

  -- 测试6: 获取执行统计
  vim.notify("\n6. 获取执行统计:")
  local stats = M.get_execution_stats()
  vim.notify(string.format("  总执行次数: %d", stats.total_executions))
  vim.notify(string.format("  成功次数: %d", stats.successful_executions))
  vim.notify(string.format("  失败次数: %d", stats.failed_executions))
  vim.notify(string.format("  平均耗时: %.2f秒", stats.avg_duration))

  -- 恢复原始模块
  tool_registry = original_registry
  tool_validator = original_validator

  vim.notify("\n=== 测试完成 ===")
  return true
end

--- 根据工具定义生成调用示例
--- @param tool table 工具定义
--- @return string|nil 调用示例字符串
function M._generate_example(tool)
  if not tool or not tool.parameters or not tool.parameters.properties then
    return nil
  end

  local props = tool.parameters.properties
  local required = tool.parameters.required or {}
  local example = {}

  for _, req in ipairs(required) do
    local prop = props[req]
    if prop then
      if prop.type == "string" then
        example[req] = '"<" .. req .. ">"'
      elseif prop.type == "number" or prop.type == "integer" then
        example[req] = 0
      elseif prop.type == "boolean" then
        example[req] = false
      elseif prop.type == "array" then
        example[req] = {}
      elseif prop.type == "object" then
        example[req] = {}
      else
        example[req] = '"<" .. req .. ">"'
      end
    end
  end

  -- 如果有 file 或 files 字段，展示 JSON 字符串格式
  if example.file or example.files then
    local lines = {}
    table.insert(lines, tool.name .. "({")
    for k, v in pairs(example) do
      if k == "file" then
        table.insert(lines, '  file = \'{"filepath": "<文件路径>"}\',')
      elseif k == "files" then
        table.insert(lines, '  files = \'[{"filepath": "<文件路径>"}]\',')
      else
        local val_str = type(v) == "string" and v or tostring(v)
        table.insert(lines, "  " .. k .. " = " .. val_str .. ",")
      end
    end
    table.insert(lines, "})")
    return table.concat(lines, "\n")
  end

  -- 普通格式
  local lines = {}
  table.insert(lines, tool.name .. "({")
  for k, v in pairs(example) do
    local val_str = type(v) == "string" and v or tostring(v)
    table.insert(lines, "  " .. k .. " = " .. val_str .. ",")
  end
  table.insert(lines, "})")
  return table.concat(lines, "\n")
end

-- 导出测试函数
M.test = test_module

return M
