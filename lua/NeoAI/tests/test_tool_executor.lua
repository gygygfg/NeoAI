--- 测试: tools/tool_executor.lua
--- 测试工具执行器的初始化、同步/异步执行、参数验证、格式化等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_tool_executor ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local te = require("NeoAI.tools.tool_executor")
      te.initialize({})
      -- 幂等初始化
      te.initialize({})
    end,

    --- 测试 format_result
    test_format_result = function()
      local te = require("NeoAI.tools.tool_executor")

      -- nil
      assert.equal("null", te.format_result(nil))

      -- 字符串
      assert.equal("hello", te.format_result("hello"))

      -- 数字
      assert.equal("42", te.format_result(42))

      -- 布尔
      assert.equal("true", te.format_result(true))

      -- 表
      local result = te.format_result({ key = "value" })
      assert.is_true(type(result) == "string")
      assert.is_true(#result > 0)
    end,

    --- 测试 handle_error
    test_handle_error = function()
      local te = require("NeoAI.tools.tool_executor")

      local result = te.handle_error("参数错误")
      assert.is_true(type(result) == "string")
      assert.is_true(#result > 0)
      assert.is_true(string.find(result, "参数错误") ~= nil)
    end,

    --- 测试 _record_execution / get_execution_history
    test_execution_history = function()
      local te = require("NeoAI.tools.tool_executor")
      te.clear_history()

      te._record_execution("test_tool", { arg1 = "val1" }, "result", nil, 100)
      te._record_execution("error_tool", { arg2 = "val2" }, nil, "出错了", 50)

      local history = te.get_execution_history()
      assert.is_true(#history >= 2, "应有至少2条历史记录")
      assert.equal("test_tool", history[1].tool_name)
      assert.is_true(history[1].success)
      assert.is_false(history[2].success)
    end,

    --- 测试 clear_history
    test_clear_history = function()
      local te = require("NeoAI.tools.tool_executor")
      te.clear_history()
      local history = te.get_execution_history()
      assert.is_true(#history == 0, "清空后应为0条")
    end,

    --- 测试 cleanup
    test_cleanup = function()
      local te = require("NeoAI.tools.tool_executor")
      -- cleanup 不应崩溃
      te.cleanup()
    end,

    --- 测试 update_config
    test_update_config = function()
      local te = require("NeoAI.tools.tool_executor")
      te.update_config({ max_history_size = 50 })
    end,

    --- 测试 _generate_example
    test_generate_example = function()
      local te = require("NeoAI.tools.tool_executor")

      local tool = {
        name = "test_tool",
        parameters = {
          type = "object",
          properties = {
            filepath = { type = "string", description = "文件路径" },
            count = { type = "number", description = "数量" },
          },
          required = { "filepath" },
        },
      }

      local example = te._generate_example(tool)
      assert.not_nil(example, "应生成示例")
      assert.is_true(string.find(example, "test_tool") ~= nil)
      assert.is_true(string.find(example, "filepath") ~= nil)
    end,

    --- 测试 _generate_example 无参数
    test_generate_example_no_params = function()
      local te = require("NeoAI.tools.tool_executor")
      local tool = { name = "simple_tool" }
      local example = te._generate_example(tool)
      assert.equal(nil, example, "无参数工具应返回 nil")
    end,

    --- 测试 execute_async（不应崩溃）
    test_execute_async = function()
      local te = require("NeoAI.tools.tool_executor")
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register({
        name = "async_test_tool",
        description = "异步测试",
        func = function(args) return "executed: " .. (args.input or "") end,
        parameters = { type = "object", properties = { input = { type = "string" } }, required = {} },
      })

      local result = nil
      te.execute_async("async_test_tool", { input = "hello" }, function(res)
        result = res
      end, function(err)
        result = "error: " .. err
      end)

      -- 等待异步执行完成
      vim.wait(500, function() return result ~= nil end)
      assert.not_nil(result, "异步执行应返回结果")
    end,

    --- 测试 execute_async 不存在的工具
    test_execute_async_missing_tool = function()
      local te = require("NeoAI.tools.tool_executor")
      local result = nil
      te.execute_async("nonexistent_tool", {}, function(res)
        result = res
      end, function(err)
        result = "error: " .. err
      end)

      vim.wait(500, function() return result ~= nil end)
      assert.not_nil(result, "不存在的工具应返回提示信息")
    end,

    --- 测试 batch_execute_async
    test_batch_execute_async = function()
      local te = require("NeoAI.tools.tool_executor")
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register({
        name = "batch_tool",
        func = function() return "batch_ok" end,
        parameters = { type = "object", properties = {}, required = {} },
      })

      te.batch_execute_async({
        { "batch_tool", {}, function() end, function() end },
      })
      -- 不应崩溃
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
