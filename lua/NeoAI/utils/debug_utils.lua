-- 调试工具模块
-- 提供条件输出函数，不覆盖原生函数

local M = {}

-- 模块状态
local state = {
  config = nil,
  initialized = false,
}

--- 初始化调试工具
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end
  
  state.config = config or {}
  state.initialized = true
end

--- 检查是否启用详细输出
--- @return boolean 是否启用详细输出
function M.is_verbose_enabled()
  if not state.initialized or not state.config then
    return false
  end
  
  -- 检查 test.verbose 配置
  if state.config.test and state.config.test.verbose then
    return true
  end
  
  return false
end

--- 检查是否启用调试打印
--- @return boolean 是否启用调试打印
function M.is_print_debug_enabled()
  if not state.initialized or not state.config then
    return false
  end
  
  -- 检查 test.print_debug 配置
  if state.config.test and state.config.test.print_debug then
    return true
  end
  
  return false
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
  
  -- 构建输出字符串
  local args = {...}
  local output = {}
  
  for i, arg in ipairs(args) do
    if type(arg) == "table" then
      table.insert(output, vim.inspect(arg))
    else
      table.insert(output, tostring(arg))
    end
  end
  
  -- 输出到控制台
  print("[NeoAI Debug]", table.concat(output, " "))
end

--- 获取调试状态信息
--- @return table 调试状态
function M.get_status()
  return {
    initialized = state.initialized,
    verbose_enabled = M.is_verbose_enabled(),
    print_debug_enabled = M.is_print_debug_enabled(),
    config = state.config and {
      test = state.config.test
    }
  }
end

return M