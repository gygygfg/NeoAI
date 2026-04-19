-- 测试助手模块
-- 提供统一的测试接口，支持模块化输出管理

local M = {}

-- 导入输出管理器和模块包装器
local output_manager_loaded, output_manager = pcall(require, "NeoAI.tests.output_manager")
local module_wrapper_loaded, module_wrapper = pcall(require, "NeoAI.tests.module_output_wrapper")

if not output_manager_loaded then
  -- 创建简单的输出管理器作为后备
  output_manager = {
    set_current_test = function() end,
    set_current_module = function() end,
    test_start = function(name) print("🧪 运行测试: " .. name) end,
    test_pass = function(name, msg) print("✅ " .. (msg or "测试通过")) end,
    test_fail = function(name, msg) print("❌ " .. msg) end,
    test_error = function(msg) print("💥 " .. msg) end,
    test_info = function(msg) print("📋 " .. msg) end,
    test_warn = function(msg) print("⚠️  " .. msg) end,
    test_debug = function(msg) print("🔍 " .. msg) end,
    test_log = function(msg) print("📝 " .. msg) end,
    test_summary = function(msg) print("📊 " .. msg) end,
    direct_print = print,
    clear_buffer = function() end,
    set_display_mode = function() end,
    print_all_outputs = function() end,
    print_module_stats = function() end,
  }
end

if not module_wrapper_loaded then
  -- 创建简单的模块包装器作为后备
  module_wrapper = {
    start_module = function(name) 
      output_manager.set_current_module(name)
      output_manager.test_log("开始测试模块: " .. name)
    end,
    end_module = function() 
      output_manager.set_current_module(nil)
    end,
    with_module = function(name, func)
      module_wrapper.start_module(name)
      local result = func()
      module_wrapper.end_module()
      return result
    end,
    log = function(msg) output_manager.test_log(msg) end,
    info = function(msg) output_manager.test_info(msg) end,
    debug = function(msg) output_manager.test_debug(msg) end,
    warn = function(msg) output_manager.test_warn(msg) end,
    error = function(msg) output_manager.test_error(msg) end,
    success = function(msg) output_manager.test_pass(nil, msg) end,
    fail = function(msg) output_manager.test_fail(nil, msg) end,
    create_submodule = function(name)
      return {
        log = function(msg) output_manager.test_log(msg) end,
        info = function(msg) output_manager.test_info(msg) end,
        debug = function(msg) output_manager.test_debug(msg) end,
        warn = function(msg) output_manager.test_warn(msg) end,
        error = function(msg) output_manager.test_error(msg) end,
        success = function(msg) output_manager.test_pass(nil, msg) end,
        fail = function(msg) output_manager.test_fail(nil, msg) end,
      }
    end,
    assert = function(cond, msg)
      if not cond then
        output_manager.test_fail(nil, msg or "断言失败")
        error(msg or "断言失败")
      else
        output_manager.test_pass(nil, msg or "断言通过")
      end
    end,
    assert_equal = function(expected, actual, msg)
      local success = expected == actual
      local message = msg or string.format("期望: %s, 实际: %s", 
        tostring(expected), tostring(actual))
      
      if not success then
        output_manager.test_fail(nil, message)
        error(message)
      else
        output_manager.test_pass(nil, message)
      end
    end,
    get_current_module = function() return nil end,
    reset_context = function() end,
  }
end

-- 导出模块包装器函数
M.start_module = module_wrapper.start_module
M.end_module = module_wrapper.end_module
M.with_module = module_wrapper.with_module
M.log = module_wrapper.log
M.info = module_wrapper.info
M.debug = module_wrapper.debug
M.warn = module_wrapper.warn
M.error = module_wrapper.error
M.success = module_wrapper.success
M.fail = module_wrapper.fail
M.create_submodule = module_wrapper.create_submodule
M.assert = module_wrapper.assert
M.assert_equal = module_wrapper.assert_equal
M.get_current_module = module_wrapper.get_current_module
M.reset_context = module_wrapper.reset_context

-- 测试开始
function M.test_start(test_name)
  output_manager.test_start(test_name)
end

-- 测试通过
function M.test_pass(message)
  output_manager.test_pass(output_manager.current_test_name, message)
end

-- 测试失败
function M.test_fail(message)
  output_manager.test_fail(output_manager.current_test_name, message)
end

-- 测试错误
function M.test_error(message)
  output_manager.test_error(message)
end

-- 测试信息
function M.test_info(message)
  output_manager.test_info(message)
end

-- 测试警告
function M.test_warn(message)
  output_manager.test_warn(message)
end

-- 测试调试
function M.test_debug(message)
  output_manager.test_debug(message)
end

-- 测试日志
function M.test_log(message)
  output_manager.test_log(message)
end

-- 测试总结
function M.test_summary(message)
  output_manager.test_summary(message)
end

-- 直接打印（用于特殊情况）
function M.print(message)
  output_manager.direct_print(message)
end

-- 设置显示模式
function M.set_display_mode(mode)
  output_manager.set_display_mode(mode)
end

-- 打印所有输出（智能过滤）
function M.print_all_outputs()
  output_manager.print_all_outputs()
end

-- 打印模块统计
function M.print_module_stats()
  output_manager.print_module_stats()
end

-- 断言函数（兼容旧版本）
function M.assert(condition, message)
  if not condition then
    M.test_fail(message or "断言失败")
    error(message or "断言失败")
  else
    M.test_pass(message or "断言通过")
  end
end

-- 断言相等（兼容旧版本）
function M.assert_equal(expected, actual, message)
  local success = expected == actual
  local msg = message or string.format("期望: %s, 实际: %s", 
    tostring(expected), tostring(actual))
  
  if not success then
    M.test_fail(msg)
    error(msg)
  else
    M.test_pass(msg)
  end
end

-- 断言不相等（兼容旧版本）
function M.assert_not_equal(expected, actual, message)
  local success = expected ~= actual
  local msg = message or string.format("期望不等于: %s, 实际: %s", 
    tostring(expected), tostring(actual))
  
  if not success then
    M.test_fail(msg)
    error(msg)
  else
    M.test_pass(msg)
  end
end

-- 设置当前测试
function M.set_current_test(name)
  output_manager.set_current_test(name)
end

-- 清空缓冲区
function M.clear_buffer()
  output_manager.clear_buffer()
end

-- 获取输出管理器
function M.get_output_manager()
  return output_manager
end

-- 获取模块包装器
function M.get_module_wrapper()
  return module_wrapper
end

return M
