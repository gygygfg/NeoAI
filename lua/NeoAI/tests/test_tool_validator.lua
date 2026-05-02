--- 测试: tools/tool_validator.lua
--- 测试工具验证器的初始化、模式验证、参数验证、类型验证、权限检查等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_tool_validator ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local tv = require("NeoAI.tools.tool_validator")
      tv.reset()
      local ok, msg = tv.initialize({})
      assert.is_true(ok, "初始化应成功: " .. tostring(msg))
    end,

    --- 测试 validate_schema
    test_validate_schema = function()
      local tv = require("NeoAI.tools.tool_validator")

      -- 有效 schema
      local valid, msg = tv.validate_schema({
        type = "object",
        properties = {
          name = { type = "string" },
          age = { type = "number" },
        },
        required = { "name" },
      })
      assert.is_true(valid, "有效 schema 应通过: " .. tostring(msg))

      -- 无效类型
      local valid2, msg2 = tv.validate_schema({ type = "invalid_type" })
      assert.is_false(valid2, "无效类型应失败")

      -- nil schema
      local valid3, msg3 = tv.validate_schema(nil)
      assert.is_true(valid3, "nil schema 应通过")
    end,

    --- 测试 validate_parameters
    test_validate_parameters = function()
      local tv = require("NeoAI.tools.tool_validator")

      local schema = {
        type = "object",
        properties = {
          name = { type = "string" },
          age = { type = "number", minimum = 0, maximum = 150 },
          active = { type = "boolean" },
        },
        required = { "name" },
      }

      -- 有效参数
      local valid, msg = tv.validate_parameters(schema, { name = "张三", age = 25, active = true })
      assert.is_true(valid, "有效参数应通过: " .. tostring(msg))

      -- 缺少必需字段
      local valid2, msg2 = tv.validate_parameters(schema, { age = 25 })
      assert.is_false(valid2, "缺少必需字段应失败")

      -- 类型错误
      local valid3, msg3 = tv.validate_parameters(schema, { name = "张三", age = "二十五" })
      assert.is_false(valid3, "类型错误应失败")

      -- 超出范围
      local valid4, msg4 = tv.validate_parameters(schema, { name = "张三", age = 200 })
      assert.is_false(valid4, "超出范围应失败")

      -- nil schema
      local valid5, msg5 = tv.validate_parameters(nil, { a = 1 })
      assert.is_true(valid5, "nil schema 应通过")
    end,

    --- 测试 validate_parameters - 枚举
    test_validate_parameters_enum = function()
      local tv = require("NeoAI.tools.tool_validator")

      local schema = {
        type = "object",
        properties = {
          color = { type = "string", enum = { "red", "green", "blue" } },
        },
        required = { "color" },
      }

      local valid, msg = tv.validate_parameters(schema, { color = "red" })
      assert.is_true(valid, "枚举内值应通过")

      local valid2, msg2 = tv.validate_parameters(schema, { color = "yellow" })
      assert.is_false(valid2, "枚举外值应失败")
    end,

    --- 测试 validate_parameters - 嵌套对象
    test_validate_parameters_nested = function()
      local tv = require("NeoAI.tools.tool_validator")

      local schema = {
        type = "object",
        properties = {
          config = {
            type = "object",
            properties = {
              host = { type = "string" },
              port = { type = "number" },
            },
            required = { "host" },
          },
        },
        required = { "config" },
      }

      local valid, msg = tv.validate_parameters(schema, { config = { host = "localhost", port = 8080 } })
      assert.is_true(valid, "嵌套对象应通过: " .. tostring(msg))

      local valid2, msg2 = tv.validate_parameters(schema, { config = { port = 8080 } })
      assert.is_false(valid2, "嵌套对象缺少必需字段应失败")
    end,

    --- 测试 validate_return_type
    test_validate_return_type = function()
      local tv = require("NeoAI.tools.tool_validator")

      assert.is_true(tv.validate_return_type("string", "hello"))
      assert.is_true(tv.validate_return_type("number", 42))
      assert.is_true(tv.validate_return_type("boolean", true))
      assert.is_true(tv.validate_return_type("array", { 1, 2, 3 }))
      assert.is_true(tv.validate_return_type("object", { a = 1 }))
      assert.is_true(tv.validate_return_type("null", nil))

      assert.is_false(tv.validate_return_type("string", 42))
      assert.is_false(tv.validate_return_type("number", "hello"))
      assert.is_false(tv.validate_return_type("array", "not_array"))
    end,

    --- 测试 check_permissions
    test_check_permissions = function()
      local tv = require("NeoAI.tools.tool_validator")

      -- 无权限配置
      assert.is_true(tv.check_permissions({}))

      -- 有权限但未限制
      assert.is_true(tv.check_permissions({ permissions = { read = "allowed" } }))

      -- 权限受限
      local valid, msg = tv.check_permissions({ permissions = { read = "restricted" } })
      assert.is_false(valid, "受限权限应失败")
      assert.not_nil(msg)
    end,

    --- 测试 validate_tool
    test_validate_tool = function()
      local tv = require("NeoAI.tools.tool_validator")

      -- 有效工具
      local valid, msg = tv.validate_tool({
        name = "test_tool",
        func = function() end,
        parameters = { type = "object", properties = {} },
      })
      assert.is_true(valid, "有效工具应通过: " .. tostring(msg))

      -- 无名称
      local valid2, msg2 = tv.validate_tool({ func = function() end })
      assert.is_false(valid2, "无名称应失败")

      -- 无函数
      local valid3, msg3 = tv.validate_tool({ name = "no_func" })
      assert.is_false(valid3, "无函数应失败")

      -- nil
      local valid4, msg4 = tv.validate_tool(nil)
      assert.is_false(valid4, "nil 应失败")
    end,

    --- 测试 validate_tool_call
    test_validate_tool_call = function()
      local tv = require("NeoAI.tools.tool_validator")
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register({
        name = "test_tool",
        func = function() end,
        parameters = {
          type = "object",
          properties = {
            input = { type = "string" },
          },
          required = { "input" },
        },
      })

      -- 有效调用
      local result = tv.validate_tool_call({ name = "test_tool", arguments = { input = "hello" } }, tr)
      assert.is_true(result.valid, "有效调用应通过")

      -- 缺少名称
      local result2 = tv.validate_tool_call({ arguments = {} }, tr)
      assert.is_false(result2.valid)

      -- 不存在的工具
      local result3 = tv.validate_tool_call({ name = "nonexistent", arguments = {} }, tr)
      assert.is_false(result3.valid)

      -- 缺少必需参数
      local result4 = tv.validate_tool_call({ name = "test_tool", arguments = {} }, tr)
      assert.is_false(result4.valid)
    end,

    --- 测试 update_config / get_config
    test_config = function()
      local tv = require("NeoAI.tools.tool_validator")
      tv.update_config({ custom_key = "custom_value" })
      local config = tv.get_config()
      assert.equal("custom_value", config.custom_key)
    end,

    --- 测试 is_initialized
    test_is_initialized = function()
      local tv = require("NeoAI.tools.tool_validator")
      assert.is_true(tv.is_initialized())
    end,

    --- 测试 reset
    test_reset = function()
      local tv = require("NeoAI.tools.tool_validator")
      tv.reset()
      assert.is_false(tv.is_initialized(), "重置后应未初始化")
      -- 重新初始化
      tv.initialize({})
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
