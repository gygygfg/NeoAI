-- Lua日志模块
-- 提供可配置的日志记录功能，支持多种日志级别、文件输出、日志轮转等

local M = {}

-- 日志级别定义
-- 从低到高：DEBUG < INFO < WARN < ERROR < FATAL
local LOG_LEVELS = {
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
  FATAL = 5,
}

-- 日志级别名称映射
-- 用于将级别数值转换为可读的字符串
local LOG_LEVEL_NAMES = {
  [1] = "DEBUG",
  [2] = "INFO",
  [3] = "WARN",
  [4] = "ERROR",
  [5] = "FATAL",
}

-- 模块状态
-- 存储日志模块的配置和状态信息
local state = {
  initialized = false, -- 是否已初始化
  level = LOG_LEVELS.INFO, -- 当前日志级别
  output = nil, -- 输出目标：文件句柄或函数
  output_path = nil, -- 输出文件路径
  format = "[{time}] [{level}] {message}", -- 日志格式
  max_file_size = 10485760, -- 最大文件大小：10MB
  max_backups = 5, -- 最大备份文件数量
}

--- 初始化日志器
-- 在首次使用日志功能时自动调用，也可手动调用以应用配置
-- @param config table 配置表，可包含以下字段：
--   level: 日志级别字符串（'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'）
--   output_path: 输出文件路径
--   format: 日志格式字符串
--   max_file_size: 最大文件大小（字节）
--   max_backups: 最大备份文件数量
function M.initialize(config)
  -- 如果已经初始化，直接返回
  if state.initialized then
    return
  end

  config = config or {}

  -- 设置日志级别
  if config.level then
    local level_name = config.level:upper()
    state.level = LOG_LEVELS[level_name] or LOG_LEVELS.INFO
  end

  -- 设置输出路径
  if config.output_path then
    M.set_output(config.output_path)
  end

  -- 设置日志格式
  if config.format then
    state.format = config.format
  end

  -- 设置文件大小限制
  if config.max_file_size then
    state.max_file_size = config.max_file_size
  end

  -- 设置备份数量
  if config.max_backups then
    state.max_backups = config.max_backups
  end

  state.initialized = true
end

--- 记录日志
-- 核心日志记录函数，所有其他日志函数最终调用此函数
-- @param level number 日志级别数值
-- @param message string 日志消息
-- @param ... any 格式化参数（可选）
function M.log(level, message, ...)
  -- 如果没有初始化，使用默认配置初始化
  if not state.initialized then
    M.initialize()
  end

  -- 检查日志级别：如果当前日志级别高于要记录的级别，则不记录
  if level < state.level then
    return
  end

  -- 格式化消息：如果有额外的格式化参数，使用string.format
  if select("#", ...) > 0 then
    message = string.format(message, ...)
  end

  -- 检查日志轮转（修复：在写入前检查文件大小）
  M.rotate()

  -- 构建日志条目
  local entry = M._format_entry(level, message)

  -- 输出日志条目
  M._write_entry(entry)
end

--- 设置日志级别
-- @param level string 日志级别字符串（'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'）
function M.set_level(level)
  if not level then
    return
  end

  local level_name = level:upper()
  state.level = LOG_LEVELS[level_name] or LOG_LEVELS.INFO
end

--- 设置输出路径
-- @param path string 输出文件路径，如果为nil则输出到标准输出
function M.set_output(path)
  if not path then
    -- 关闭现有文件输出
    if state.output and state.output_path then
      M._close_output()
    end

    state.output = nil
    state.output_path = nil
    return
  end

  -- 关闭现有输出
  if state.output and state.output_path then
    M._close_output()
  end

  state.output_path = path

  -- 以追加模式打开文件
  local ok, file = pcall(io.open, path, "a")
  if ok and file then
    state.output = file
  else
    -- 如果无法打开文件，回退到标准输出
    state.output = nil
    state.output_path = nil
    M.error("无法打开日志文件: " .. tostring(path))
  end
end

--- 调试级别日志
-- @param message string 日志消息
-- @param ... any 格式化参数（可选）
function M.debug(message, ...)
  M.log(LOG_LEVELS.DEBUG, message, ...)
end

--- 信息级别日志
-- @param message string 日志消息
-- @param ... any 格式化参数（可选）
function M.info(message, ...)
  M.log(LOG_LEVELS.INFO, message, ...)
end

--- 警告级别日志
-- @param message string 日志消息
-- @param ... any 格式化参数（可选）
function M.warn(message, ...)
  M.log(LOG_LEVELS.WARN, message, ...)
end

--- 错误级别日志
-- @param message string 日志消息
-- @param ... any 格式化参数（可选）
function M.error(message, ...)
  M.log(LOG_LEVELS.ERROR, message, ...)
end

--- 致命错误级别日志
-- @param message string 日志消息
-- @param ... any 格式化参数（可选）
function M.fatal(message, ...)
  M.log(LOG_LEVELS.FATAL, message, ...)
end

--- 获取当前日志级别
-- @return string 当前日志级别名称
function M.get_level()
  return LOG_LEVEL_NAMES[state.level] or "INFO"
end

--- 获取输出路径
-- @return string|nil 输出文件路径，如果输出到标准输出则返回nil
function M.get_output_path()
  return state.output_path
end

--- 轮转日志文件
-- 当日志文件达到最大大小时，自动轮转文件
function M.rotate()
  -- 如果没有设置输出路径或输出目标，不执行轮转
  if not state.output_path or not state.output then
    return
  end

  -- 检查文件大小
  local file = state.output
  local current_pos = file:seek("cur") -- 保存当前位置
  local size = file:seek("end") -- 获取文件大小
  file:seek("set", current_pos) -- 恢复位置

  -- 如果文件大小未达到限制，不执行轮转
  if size < state.max_file_size then
    return
  end

  -- 关闭当前文件
  M._close_output()

  -- 轮转备份文件
  -- 从最旧的备份开始，依次重命名
  for i = state.max_backups - 1, 1, -1 do
    local old_name = state.output_path .. "." .. i
    local new_name = state.output_path .. "." .. (i + 1)

    if M._file_exists(old_name) then
      os.rename(old_name, new_name)
    end
  end

  -- 重命名当前日志文件为第一个备份
  if M._file_exists(state.output_path) then
    os.rename(state.output_path, state.output_path .. ".1")
  end

  -- 重新打开日志文件
  M.set_output(state.output_path)
end

--- 清空日志文件
-- 清空当前日志文件的所有内容
function M.clear()
  if not state.output_path then
    return
  end

  -- 关闭现有输出
  if state.output then
    M._close_output()
  end

  -- 以写入模式打开文件（会清空文件内容）
  local file, err = io.open(state.output_path, "w")
  if file then
    file:close()
  end

  -- 重新以追加模式打开文件
  M.set_output(state.output_path)
end

--- 格式化日志条目（内部函数）
-- 将日志级别、时间和消息格式化为字符串
-- @param level number 日志级别数值
-- @param message string 日志消息
-- @return string 格式化后的日志条目
function M._format_entry(level, message)
  local level_name = LOG_LEVEL_NAMES[level] or "UNKNOWN"
  local time_str = os.date("%Y-%m-%d %H:%M:%S")

  -- 替换格式字符串中的占位符
  local entry = state.format:gsub("{time}", time_str):gsub("{level}", level_name):gsub("{message}", message)

  return entry
end

--- 写入日志条目（内部函数）
-- 将格式化后的日志条目写入输出目标
-- @param entry string 格式化后的日志条目
function M._write_entry(entry)
  -- 检查日志轮转（确保写入前文件大小合适）
  M.rotate()

  -- 输出到文件
  if state.output then
    state.output:write(entry .. "\n")
    state.output:flush()
  else
    -- 输出到标准输出
    -- 修复：检查vim是否可用，如果不使用print输出
    if vim and vim.notify then
      local level = entry:match("%[([A-Z]+)%]")
      if level == "ERROR" or level == "FATAL" then
        vim.notify(entry, vim.log.levels.ERROR)
      elseif level == "WARN" then
        vim.notify(entry, vim.log.levels.WARN)
      else
        vim.notify(entry, vim.log.levels.INFO)
      end
    else
      -- 如果没有vim，使用print输出到控制台
      print(entry)
    end
  end
end

--- 关闭输出（内部函数）
-- 安全关闭文件输出
function M._close_output()
  if state.output and type(state.output) == "userdata" then
    state.output:close()
  end
  state.output = nil
end

--- 检查文件是否存在（内部函数）
-- @param path string 文件路径
-- @return boolean 文件是否存在
function M._file_exists(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return true
  end
  return false
end

--- 设置自定义输出函数
-- @param output_func function 自定义输出函数，接收一个字符串参数
function M.set_custom_output(output_func)
  if type(output_func) ~= "function" then
    return
  end

  -- 关闭现有输出
  if state.output and type(state.output) == "userdata" then
    M._close_output()
  end

  state.output = output_func
  state.output_path = nil
end

--- 获取日志统计信息
-- @return table 包含日志模块统计信息的表
function M.get_stats()
  local stats = {
    level = M.get_level(),
    output_path = state.output_path,
    format = state.format,
    max_file_size = state.max_file_size,
    max_backups = state.max_backups,
    initialized = state.initialized,
  }

  -- 如果输出到文件，获取文件大小
  if state.output_path and M._file_exists(state.output_path) then
    local file = io.open(state.output_path, "r")
    if file then
      local size = file:seek("end")
      file:close()
      stats.file_size = size
      stats.needs_rotation = size >= state.max_file_size
    end
  end

  return stats
end

--- 创建子日志器
-- 创建一个带有前缀的子日志器，用于模块化日志记录
-- @param prefix string 日志前缀
-- @return table 子日志器对象
function M.create_child(prefix)
  local child = {}

  -- 为每个日志级别创建方法
  for level_name, level_num in pairs(LOG_LEVELS) do
    child[level_name:lower()] = function(message, ...)
      local full_message = "[" .. prefix .. "] " .. message
      M.log(level_num, full_message, ...)
    end
  end

  -- 添加通用的log方法
  child.log = function(level, message, ...)
    local full_message = "[" .. prefix .. "] " .. message
    M.log(level, full_message, ...)
  end

  -- 添加其他工具方法
  child.get_level = M.get_level
  child.set_level = M.set_level
  child.get_output_path = M.get_output_path
  child.set_output = M.set_output
  child.rotate = M.rotate
  child.clear = M.clear
  child.get_stats = M.get_stats

  return child
end

--- 记录异常
-- 专门用于记录异常信息的函数
-- @param err any 异常对象或字符串
-- @param context string 异常上下文信息（可选）
function M.exception(err, context)
  local err_msg
  if type(err) == "table" then
    -- 修复：检查vim.inspect是否可用
    if vim and vim.inspect then
      err_msg = vim.inspect(err)
    else
      err_msg = tostring(err)
    end
  else
    err_msg = tostring(err)
  end

  local message = context and (context .. ": " .. err_msg) or err_msg
  M.error(message)

  -- 记录堆栈跟踪
  local trace = debug.traceback()
  M.debug("堆栈跟踪:\n" .. trace)
end

-- 测试用例
local function test_logger()
  print("=== 开始测试日志模块 ===")

  -- 初始化日志器
  M.initialize({
    level = "DEBUG",
    output_path = "test.log",
    format = "[{time}] [{level}] - {message}",
    max_file_size = 1024, -- 1KB，便于测试轮转
    max_backups = 3,
  })

  -- 测试各种日志级别
  M.debug("这是一条调试信息")
  M.info("这是一条信息")
  M.warn("这是一条警告")
  M.error("这是一条错误信息")
  M.fatal("这是一条致命错误")

  -- 测试带格式化的日志
  M.info("用户 %s 在 %s 登录", "张三", os.date("%H:%M:%S"))

  -- 测试获取统计信息
  local stats = M.get_stats()
  print("当前日志级别:", stats.level)
  print("输出路径:", stats.output_path or "标准输出")
  print("文件大小:", stats.file_size or "N/A")

  -- 测试子日志器
  local child_logger = M.create_child("UserModule")
  child_logger.info("子日志器测试")
  child_logger.error("子日志器错误测试")

  -- 测试异常记录
  local success, err = pcall(function()
    error("测试异常")
  end)
  if not success then
    M.exception(err, "测试异常捕获")
  end

  -- 测试日志轮转
  for i = 1, 20 do
    M.info("测试日志轮转，消息编号: " .. i)
  end

  -- 测试清空日志
  M.clear()
  M.info("日志已清空，这是清空后的第一条日志")

  -- 测试修改日志级别
  M.set_level("WARN")
  M.debug("这条调试日志不应该被记录（级别太低）")
  M.warn("这条警告日志应该被记录")

  -- 测试设置输出路径为nil（输出到标准输出）
  M.set_output(nil)
  M.info("这条日志将输出到标准输出")

  print("=== 测试完成 ===")
end

-- ============================================================
-- 以下功能从 debug_utils.lua 合并而来
-- ============================================================

--- 检查是否启用详细输出
--- @return boolean 是否启用详细输出
function M.is_verbose_enabled()
  return state.config and state.config.verbose == true
end

--- 检查是否启用调试打印
--- @return boolean 是否启用调试打印
function M.is_print_debug_enabled()
  return state.config and state.config.print_debug == true
end

--- 条件输出函数 - 只在详细模式启用时输出
--- @param message string 消息内容
--- @param level string|number 日志级别（可选）
function M.verbose(message, level)
  if not M.is_verbose_enabled() then
    return
  end
  local log_level = level or vim.log.levels.INFO
  vim.notify("[NeoAI] " .. message, log_level)
end

--- 条件打印函数 - 只在调试打印启用时输出到控制台
--- @param ... any 要打印的内容
function M.debug_print(...)
  if not M.is_print_debug_enabled() then
    return
  end
  local args = { ... }
  local output = {}
  for i, arg in ipairs(args) do
    if type(arg) == "table" then
      table.insert(output, vim.inspect(arg))
    else
      table.insert(output, tostring(arg))
    end
  end
  print("[NeoAI Debug]", table.concat(output, " "))
end

-- 如果直接运行此文件，执行测试
if arg and arg[0] and arg[0]:match("logger%.lua$") then
  test_logger()
end

return M
