--- 测试: tools/init.lua
--- 测试工具系统的初始化、注册、执行、搜索等功能
local M = {}

local test

--- 创建一个测试工具定义
local function create_test_tool(name)
  return {
    name = name or "test_tool",
    description = "测试工具",
    func = function(args)
      return "执行结果: " .. (args and args.input or "无参数")
    end,
    parameters = {
      type = "object",
      properties = {
        input = {
          type = "string",
          description = "输入参数",
        },
      },
      required = {},
    },
  }
end

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_tools_init ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local tools = require("NeoAI.tools")
      tools.initialize({
        enabled = true,
        builtin = false, -- 不加载内置工具，避免依赖
      })

      local tool_list = tools.get_tools()
      assert.is_true(type(tool_list) == "table", "get_tools 应返回表")
    end,

    --- 测试 register_tool
    test_register_tool = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      local ok = tools.register_tool(create_test_tool("my_tool"))
      assert.is_true(ok, "注册工具应成功")

      local tool = tools.get_tool("my_tool")
      assert.not_nil(tool, "应能获取已注册的工具")
      assert.equal("my_tool", tool.name)
    end,

    --- 测试 register_tool 重复注册
    test_register_duplicate = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      tools.register_tool(create_test_tool("dup_tool"))
      local ok = tools.register_tool(create_test_tool("dup_tool"))
      assert.is_false(ok, "重复注册应返回 false")
    end,

    --- 测试 get_tools
    test_get_tools = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      tools.register_tool(create_test_tool("tool_a"))
      tools.register_tool(create_test_tool("tool_b"))

      local list = tools.get_tools()
      assert.is_true(#list >= 2, "应有至少 2 个工具")
    end,

    --- 测试 get_tool
    test_get_tool = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      tools.register_tool(create_test_tool("find_me"))
      local tool = tools.get_tool("find_me")
      assert.not_nil(tool)
      assert.equal("find_me", tool.name)

      -- 不存在的工具
      local missing = tools.get_tool("nonexistent")
      assert.equal(nil, missing)
    end,

    --- 测试 unregister_tool
    test_unregister_tool = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      tools.register_tool(create_test_tool("to_remove"))
      local ok = tools.unregister_tool("to_remove")
      assert.is_true(ok, "注销应成功")

      local tool = tools.get_tool("to_remove")
      assert.equal(nil, tool, "注销后应不存在")
    end,

    --- 测试 execute_tool
    test_execute_tool = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      tools.register_tool(create_test_tool("exec_tool"))
      local result = tools.execute_tool("exec_tool", { input = "hello" })
      assert.equal("执行结果: hello", result)
    end,

    --- 测试 validate_tool_args
    test_validate_tool_args = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      tools.register_tool(create_test_tool("valid_tool"))
      local valid, msg = tools.validate_tool_args("valid_tool", { input = "test" })
      assert.is_true(valid, "验证应通过: " .. tostring(msg))

      -- 不存在的工具
      local valid2, msg2 = tools.validate_tool_args("nonexistent", {})
      assert.is_false(valid2, "不存在的工具应验证失败")
    end,

    --- 测试 search_tools
    test_search_tools = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      tools.register_tool({
        name = "file_read",
        description = "读取文件内容",
        func = function() end,
        parameters = { type = "object", properties = {}, required = {} },
      })
      tools.register_tool({
        name = "file_write",
        description = "写入文件内容",
        func = function() end,
        parameters = { type = "object", properties = {}, required = {} },
      })

      local results = tools.search_tools("file")
      assert.is_true(#results >= 2, "应搜索到至少 2 个工具")
    end,

    --- 测试 get_tool_count
    test_get_tool_count = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      local count_before = tools.get_tool_count()
      tools.register_tool(create_test_tool("count_test"))
      local count_after = tools.get_tool_count()
      assert.equal(count_before + 1, count_after, "注册后计数应增加")
    end,

    --- 测试 reload_tools
    test_reload_tools = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      tools.register_tool(create_test_tool("before_reload"))
      tools.reload_tools()

      -- reload 后之前注册的工具应被清除
      local tool = tools.get_tool("before_reload")
      assert.equal(nil, tool, "reload 后工具应被清除")
    end,

    --- 测试 get_history_manager
    test_get_history_manager = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      local hm = tools.get_history_manager()
      assert.not_nil(hm, "应返回历史管理器")
    end,

    --- 测试 update_config
    test_update_config = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })

      -- update_config 不应崩溃
      tools.update_config({ enabled = true })
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

