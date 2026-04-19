-- 测试输出管理器
-- 集中管理所有测试输出，支持按模块智能过滤

local M = {}

-- 输出缓冲区
M.output_buffer = {}
M.current_test_name = nil
M.current_module_name = nil
M.display_mode = "structured" -- 默认显示模式

-- 模块输出跟踪
M.module_outputs = {} -- 按模块存储输出
M.module_severity = {} -- 按模块存储最高严重级别

-- 显示模式
M.display_modes = {
  VERBOSE = "verbose", -- 显示所有测试详情
  SUMMARY = "summary", -- 只显示总结
  FAILURES_ONLY = "failures_only", -- 只显示失败的测试
  STRUCTURED = "structured", -- 按项目结构显示，智能过滤
}

-- 严重级别定义（从高到低）
M.severity_levels = {
  error = 5,
  failure = 4,
  warning = 3,
  debug = 2,
  info = 1,
  log = 1,
  success = 0,
  start = 0,
  summary = 0,
}

-- 设置当前测试名称
function M.set_current_test(name)
  M.current_test_name = name
  M.current_module_name = nil -- 重置模块名
end

-- 设置当前模块名称
function M.set_current_module(module_name)
  M.current_module_name = module_name
  
  -- 初始化模块输出跟踪
  if not M.module_outputs[module_name] then
    M.module_outputs[module_name] = {}
    M.module_severity[module_name] = 0
  end
end

-- 设置显示模式
function M.set_display_mode(mode)
  M.display_mode = mode
end

-- 更新模块严重级别
function M._update_module_severity(module_name, level)
  local level_value = M.severity_levels[level] or 0
  local current_value = M.module_severity[module_name] or 0
  
  if level_value > current_value then
    M.module_severity[module_name] = level_value
  end
end

-- 检查模块是否需要显示
function M._should_display_module(module_name)
  local severity = M.module_severity[module_name] or 0
  
  -- 如果模块包含warning、error、debug或failure级别，需要显示
  if severity >= M.severity_levels.warning then
    return true
  end
  
  -- 如果只有log和info级别，不显示
  if severity <= M.severity_levels.info then
    return false
  end
  
  -- 其他情况根据显示模式决定
  if M.display_mode == M.display_modes.VERBOSE then
    return true
  elseif M.display_mode == M.display_modes.FAILURES_ONLY then
    return severity >= M.severity_levels.failure
  else
    return false
  end
end

-- 添加输出到缓冲区
function M.add_output(level, message)
  local module_name = M.current_module_name or "unknown"
  
  -- 创建输出记录
  local output = {
    test_name = M.current_test_name,
    module_name = module_name,
    level = level,
    message = message,
    timestamp = os.time(),
  }
  
  -- 添加到全局缓冲区
  table.insert(M.output_buffer, output)
  
  -- 添加到模块缓冲区
  if not M.module_outputs[module_name] then
    M.module_outputs[module_name] = {}
  end
  table.insert(M.module_outputs[module_name], output)
  
  -- 更新模块严重级别
  M._update_module_severity(module_name, level)
  
  -- 根据显示模式决定是否立即输出
  if M.display_mode == M.display_modes.VERBOSE then
    M._print_output_immediate(output)
  elseif level == "failure" or level == "error" then
    M._print_output_immediate(output)
  end
end

-- 立即输出（用于错误和verbose模式）
function M._print_output_immediate(output)
  local prefix = M._get_prefix(output.level)
  print(prefix .. output.message)
end

-- 获取级别前缀
function M._get_prefix(level)
  if level == "success" then
    return "✅ "
  elseif level == "failure" then
    return "❌ "
  elseif level == "error" then
    return "💥 "
  elseif level == "warning" then
    return "⚠️  "
  elseif level == "debug" then
    return "🔍 "
  elseif level == "info" then
    return "📋 "
  elseif level == "log" then
    return "📝 "
  elseif level == "summary" then
    return "📊 "
  elseif level == "start" then
    return "🚀 "
  else
    return ""
  end
end

-- 直接输出（用于测试初始化等特殊情况）
function M.direct_print(message)
  print(message)
end

-- 测试开始输出
function M.test_start(test_name)
  M.direct_print("🧪 运行测试: " .. test_name)
  M.direct_print(string.rep("=", 60))
  M.add_output("start", "开始测试: " .. test_name)
end

-- 测试通过输出
function M.test_pass(test_name, message)
  M.add_output("success", message or "测试通过")
end

-- 测试失败输出
function M.test_fail(test_name, message)
  M.add_output("failure", message)
end

-- 测试错误输出
function M.test_error(message)
  M.add_output("error", message)
end

-- 测试信息输出
function M.test_info(message)
  M.add_output("info", message)
end

-- 测试警告输出
function M.test_warn(message)
  M.add_output("warning", message)
end

-- 测试调试输出
function M.test_debug(message)
  M.add_output("debug", message)
end

-- 测试日志输出
function M.test_log(message)
  M.add_output("log", message)
end

-- 测试总结输出
function M.test_summary(message)
  M.add_output("summary", message)
end

-- 清空输出缓冲区
function M.clear_buffer()
  M.output_buffer = {}
  M.module_outputs = {}
  M.module_severity = {}
end

-- 获取输出缓冲区内容
function M.get_buffer()
  return M.output_buffer
end

-- 按测试名称过滤输出
function M.get_output_by_test(test_name)
  local filtered = {}
  for _, output in ipairs(M.output_buffer) do
    if output.test_name == test_name then
      table.insert(filtered, output)
    end
  end
  return filtered
end

-- 按模块名称过滤输出
function M.get_output_by_module(module_name)
  return M.module_outputs[module_name] or {}
end

-- 格式化输出为字符串
function M.format_output(output)
  local prefix = M._get_prefix(output.level)
  return prefix .. output.message
end

-- 打印所有缓冲的输出（智能过滤）
function M.print_all_outputs()
  -- 收集需要显示的模块
  local modules_to_display = {}
  
  for module_name, _ in pairs(M.module_outputs) do
    if M._should_display_module(module_name) then
      table.insert(modules_to_display, module_name)
    end
  end
  
  -- 如果没有需要显示的模块，显示总结信息
  if #modules_to_display == 0 then
    print("📊 所有测试模块运行正常，无警告或错误")
    return
  end
  
  -- 按字母顺序排序模块
  table.sort(modules_to_display)
  
  -- 打印每个需要显示的模块的输出
  for _, module_name in ipairs(modules_to_display) do
    print("\n📦 模块: " .. module_name)
    print(string.rep("-", 40))
    
    local outputs = M.module_outputs[module_name] or {}
    for _, output in ipairs(outputs) do
      print(M.format_output(output))
    end
  end
end

-- 按测试分组打印输出
function M.print_outputs_by_test()
  local tests_outputs = {}

  -- 按测试分组
  for _, output in ipairs(M.output_buffer) do
    if not tests_outputs[output.test_name] then
      tests_outputs[output.test_name] = {}
    end
    table.insert(tests_outputs[output.test_name], output)
  end

  -- 打印每个测试的输出
  for test_name, outputs in pairs(tests_outputs) do
    print("\n🧪 测试: " .. test_name)
    print(string.rep("-", 40))
    for _, output in ipairs(outputs) do
      print(M.format_output(output))
    end
  end
end

-- 获取模块统计信息
function M.get_module_stats()
  local stats = {
    total_modules = 0,
    modules_with_warnings = 0,
    modules_with_errors = 0,
    modules_with_debug = 0,
    modules_only_log_info = 0,
  }
  
  for module_name, severity in pairs(M.module_severity) do
    stats.total_modules = stats.total_modules + 1
    
    if severity >= M.severity_levels.error then
      stats.modules_with_errors = stats.modules_with_errors + 1
    elseif severity >= M.severity_levels.warning then
      stats.modules_with_warnings = stats.modules_with_warnings + 1
    elseif severity >= M.severity_levels.debug then
      stats.modules_with_debug = stats.modules_with_debug + 1
    else
      stats.modules_only_log_info = stats.modules_only_log_info + 1
    end
  end
  
  return stats
end

-- 打印模块统计
function M.print_module_stats()
  local stats = M.get_module_stats()
  
  print("\n📊 模块统计:")
  print(string.rep("=", 40))
  print(string.format("总模块数: %d", stats.total_modules))
  print(string.format("包含错误的模块: %d", stats.modules_with_errors))
  print(string.format("包含警告的模块: %d", stats.modules_with_warnings))
  print(string.format("包含调试信息的模块: %d", stats.modules_with_debug))
  print(string.format("仅包含日志/信息的模块: %d", stats.modules_only_log_info))
end

return M
