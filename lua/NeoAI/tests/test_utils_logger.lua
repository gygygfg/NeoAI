--- 测试: utils/logger.lua
--- 测试日志模块的初始化、日志级别、文件输出、轮转、子日志器等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_utils_logger ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local logger = require("NeoAI.utils.logger")
      logger.initialize({ level = "DEBUG" })
    end,

    --- 测试 set_level / get_level
    test_level = function()
      local logger = require("NeoAI.utils.logger")

      logger.set_level("DEBUG")
      assert.equal("DEBUG", logger.get_level())

      logger.set_level("INFO")
      assert.equal("INFO", logger.get_level())

      logger.set_level("WARN")
      assert.equal("WARN", logger.get_level())

      -- 无效级别
      logger.set_level("INVALID")
      assert.equal("INFO", logger.get_level(), "无效级别应回退到 INFO")
    end,

    --- 测试 debug / info / warn / error / fatal
    test_log_methods = function()
      local logger = require("NeoAI.utils.logger")
      logger.set_level("DEBUG")

      -- 这些不应崩溃
      logger.debug("调试消息")
      logger.info("信息消息")
      logger.warn("警告消息")
      logger.error("错误消息")
      logger.fatal("致命错误")
    end,

    --- 测试带格式化的日志
    test_formatted_log = function()
      local logger = require("NeoAI.utils.logger")
      logger.info("用户 %s 登录", "张三")
      logger.warn("重试 %d/%d", 1, 3)
    end,

    --- 测试 set_output / get_output_path
    test_output = function()
      local logger = require("NeoAI.utils.logger")
      local test_path = "/tmp/neoai_test_log.log"

      logger.set_output(test_path)
      assert.equal(test_path, logger.get_output_path())

      logger.info("测试写入文件")
      logger.set_output(nil)
      assert.equal(nil, logger.get_output_path())
    end,

    --- 测试 clear
    test_clear = function()
      local logger = require("NeoAI.utils.logger")
      local test_path = "/tmp/neoai_test_clear.log"
      logger.set_output(test_path)
      logger.info("待清空的消息")
      logger.clear()
      logger.info("清空后的消息")
      logger.set_output(nil)
    end,

    --- 测试 get_stats
    test_get_stats = function()
      local logger = require("NeoAI.utils.logger")
      local stats = logger.get_stats()
      assert.not_nil(stats)
      assert.not_nil(stats.level)
      assert.not_nil(stats.initialized)
    end,

    --- 测试 create_child
    test_create_child = function()
      local logger = require("NeoAI.utils.logger")

      local child = logger.create_child("TestModule")
      assert.not_nil(child)
      assert.is_true(type(child.info) == "function")
      assert.is_true(type(child.debug) == "function")
      assert.is_true(type(child.warn) == "function")
      assert.is_true(type(child.error) == "function")
      assert.is_true(type(child.get_level) == "function")

      child.info("子日志器测试")
      child.error("子日志器错误测试")
    end,

    --- 测试 exception
    test_exception = function()
      local logger = require("NeoAI.utils.logger")
      logger.exception("测试异常信息", "测试上下文")
    end,

    --- 测试 is_verbose_enabled / is_print_debug_enabled
    test_verbose_and_debug = function()
      local logger = require("NeoAI.utils.logger")

      logger.initialize({ verbose = true, print_debug = true })
      assert.is_true(logger.is_verbose_enabled())
      assert.is_true(logger.is_print_debug_enabled())

      logger.initialize({ verbose = false, print_debug = false })
      assert.is_false(logger.is_verbose_enabled())
      assert.is_false(logger.is_print_debug_enabled())
    end,

    --- 测试 verbose / debug_print
    test_verbose_and_debug_print = function()
      local logger = require("NeoAI.utils.logger")
      logger.initialize({ verbose = true, print_debug = true })
      logger.verbose("详细消息")
      logger.debug_print("调试", "打印")
      logger.initialize({ verbose = false, print_debug = false })
    end,

    --- 测试 set_custom_output
    test_custom_output = function()
      local logger = require("NeoAI.utils.logger")
      local last_message = nil
      logger.set_custom_output(function(msg)
        last_message = msg
      end)
      logger.info("自定义输出测试")
      logger.set_output(nil)
    end,

    --- 测试 rotate
    test_rotate = function()
      local logger = require("NeoAI.utils.logger")
      local test_path = "/tmp/neoai_test_rotate.log"
      logger.set_output(test_path)
      logger.initialize({
        level = "DEBUG",
        output_path = test_path,
        max_file_size = 100,
        max_backups = 2,
      })
      -- 写入大量数据触发轮转
      for i = 1, 50 do
        logger.info("测试轮转消息 #" .. i)
      end
      logger.set_output(nil)
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
