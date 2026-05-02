-- 测试: tools/tool_registry.lua
-- 测试工具注册表的注册、注销、查询、搜索、分类等功能
local M = {}

local test

-- 创建一个测试工具定义
local function create_test_tool(name)
  return {
    name = name or "test_tool",
    description = "测试工具",
    func = function(args) return "ok" end,
    parameters = {
      type = "object",
      properties = {
        input = { type = "string", description = "输入" },
      },
      required = {},
    },
    category = "test_category",
  }
end

-- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_tool_registry ===")

  return test.run_tests({
    -- 测试 initialize
    test_initialize = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
    end,

    -- 测试 register / get
    test_register_and_get = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      local ok = tr.register(create_test_tool("my_tool"))
      assert.is_true(ok, "注册应成功")

      local tool = tr.get("my_tool")
      assert.not_nil(tool, "应能获取已注册的工具")
      assert.equal("my_tool", tool.name)
    end,

    -- 测试 register 重复
    test_register_duplicate = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("dup_tool"))
      local ok = tr.register(create_test_tool("dup_tool"))
      assert.is_false(ok, "重复注册应返回 false")
    end,

    -- 测试 register 无效工具
    test_register_invalid = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      -- 无名称
      local ok1 = tr.register({ func = function() end })
      assert.is_false(ok1, "无名称应注册失败")

      -- 无函数
      local ok2 = tr.register({ name = "no_func" })
      assert.is_false(ok2, "无函数应注册失败")
    end,

    -- 测试 unregister
    test_unregister = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("to_remove"))
      local ok = tr.unregister("to_remove")
      assert.is_true(ok, "注销应成功")

      local tool = tr.get("to_remove")
      assert.equal(nil, tool, "注销后应不存在")

      -- 不存在的工具
      local ok2 = tr.unregister("nonexistent")
      assert.is_false(ok2, "不存在的工具注销应返回 false")
    end,

    -- 测试 list
    test_list = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("tool_a"))
      tr.register(create_test_tool("tool_b"))

      local list = tr.list()
      assert.is_true(#list >= 2, "应有至少2个工具")
    end,

    -- 测试 list 按分类
    test_list_by_category = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("cat_tool"))

      local list = tr.list("test_category")
      assert.is_true(#list >= 1, "应有至少1个工具")
    end,

    -- 测试 search
    test_search = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register({
        name = "file_read",
        description = "读取文件内容",
        func = function() end,
        parameters = { type = "object", properties = {}, required = {} },
        category = "file",
      })
      tr.register({
        name = "file_write",
        description = "写入文件内容",
        func = function() end,
        parameters = { type = "object", properties = {}, required = {} },
        category = "file",
      })

      local results = tr.search("file")
      assert.is_true(#results >= 2, "应搜索到至少2个工具")
    end,

    -- 测试 search 空查询
    test_search_empty = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      local results = tr.search("")
      assert.is_true(type(results) == "table")
    end,

    -- 测试 get_categories
    test_get_categories = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("cat_test"))
      local cats = tr.get_categories()
      assert.contains(cats, "test_category")
    end,

    -- 测试 get_category_tool_count
    test_get_category_tool_count = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("count_test"))
      local count = tr.get_category_tool_count("test_category")
      assert.is_true(count >= 1)
    end,

    -- 测试 exists
    test_exists = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("exists_test"))
      assert.is_true(tr.exists("exists_test"))
      assert.is_false(tr.exists("nonexistent"))
    end,

    -- 测试 count
    test_count = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      local before = tr.count()
      tr.register(create_test_tool("count_tool"))
      local after = tr.count()
      assert.equal(before + 1, after, "注册后计数应增加")
    end,

    -- 测试 clear
    test_clear = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("clear_test"))
      tr.clear()
      assert.equal(nil, tr.get("clear_test"), "clear 后应不存在")
    end,

    -- 测试 export_tool / import_tool
    test_export_import = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("export_test"))
      local exported = tr.export_tool("export_test")
      assert.not_nil(exported, "导出应成功")
      assert.equal("export_test", exported.name)

      -- 导入（import_tool 内部调用 register，register 会检查工具名是否已存在）
      -- 先清空已注册的工具，避免名称冲突
      tr.clear()
      tr.initialize({})
      local ok = tr.import_tool(exported, function() return "imported" end)
      assert.is_true(ok, "导入应成功")
    end,

    -- 测试 get_all_tools
    test_get_all_tools = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("all_test"))
      local all = tr.get_all_tools()
      assert.not_nil(all.all_test)
    end,

    -- 测试 get_tool（别名）
    test_get_tool_alias = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.register(create_test_tool("alias_test"))
      local tool = tr.get_tool("alias_test")
      assert.not_nil(tool)
    end,

    -- 测试 update_config
    test_update_config = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})

      tr.update_config({ new_key = "value" })
      -- 不应崩溃
    end,

    -- 测试 reset
    test_reset = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      -- 重置后应能重新初始化
      tr.initialize({})
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
