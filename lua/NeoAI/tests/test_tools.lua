--- 测试: 工具模块
--- 合并了 test_tool_registry, test_tool_executor, test_tool_validator, test_tool_pack
local M = {}

local test

local function create_tool(name)
  return { name = name or "test_tool", description = "测试工具", func = function(args) return "ok" end, parameters = { type = "object", properties = { input = { type = "string", description = "输入" } }, required = {} }, category = "test_category" }
end

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_tools ===")

  return test.run_tests({
    -- ========== tool_registry ==========
    test_registry_initialize = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
    end,

    test_registry_register_and_get = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      assert.is_true(tr.register(create_tool("my_tool")), "注册应成功")
      assert.not_nil(tr.get("my_tool"), "应能获取已注册的工具")
      assert.is_false(tr.register(create_tool("my_tool")), "重复注册应返回 false")
    end,

    test_registry_register_invalid = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      assert.is_false(tr.register({ func = function() end }), "无名称应注册失败")
      assert.is_false(tr.register({ name = "no_func" }), "无函数应注册失败")
    end,

    test_registry_unregister = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register(create_tool("to_remove"))
      assert.is_true(tr.unregister("to_remove"), "注销应成功")
      assert.equal(nil, tr.get("to_remove"), "注销后应不存在")
      assert.is_false(tr.unregister("nonexistent"), "不存在的工具注销应返回 false")
    end,

    test_registry_list = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register(create_tool("tool_a"))
      tr.register(create_tool("tool_b"))
      assert.is_true(#tr.list() >= 2, "应有至少2个工具")
    end,

    test_registry_list_by_category = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register(create_tool("cat_tool"))
      assert.is_true(#tr.list("test_category") >= 1)
    end,

    test_registry_search = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register({ name = "file_read", description = "读取文件内容", func = function() end, parameters = { type = "object", properties = {}, required = {} }, category = "file" })
      tr.register({ name = "file_write", description = "写入文件内容", func = function() end, parameters = { type = "object", properties = {}, required = {} }, category = "file" })
      assert.is_true(#tr.search("file") >= 2, "应搜索到至少2个工具")
      assert.is_true(type(tr.search("")) == "table")
    end,

    test_registry_categories = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register(create_tool("cat_test"))
      assert.contains(tr.get_categories(), "test_category")
      assert.is_true(tr.get_category_tool_count("test_category") >= 1)
    end,

    test_registry_exists_count = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register(create_tool("exists_test"))
      assert.is_true(tr.exists("exists_test"))
      assert.is_false(tr.exists("nonexistent"))
      local before = tr.count()
      tr.register(create_tool("count_tool"))
      assert.equal(before + 1, tr.count(), "注册后计数应增加")
    end,

    test_registry_clear = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register(create_tool("clear_test"))
      tr.clear()
      assert.equal(nil, tr.get("clear_test"), "clear 后应不存在")
    end,

    test_registry_export_import = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register(create_tool("export_test"))
      local exported = tr.export_tool("export_test")
      assert.not_nil(exported, "导出应成功")
      tr.clear()
      tr.initialize({})
      assert.is_true(tr.import_tool(exported, function() return "imported" end), "导入应成功")
    end,

    test_registry_get_all_tools = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register(create_tool("all_test"))
      assert.not_nil(tr.get_all_tools().all_test)
      assert.not_nil(tr.get_tool("all_test"))
    end,

    test_registry_update_config = function()
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.update_config({ new_key = "value" })
    end,

    -- ========== tool_executor ==========
    test_executor_initialize = function()
      local te = require("NeoAI.tools.tool_executor")
      te.initialize({})
      te.initialize({})
    end,

    test_executor_format_result = function()
      local te = require("NeoAI.tools.tool_executor")
      assert.equal("null", te.format_result(nil))
      assert.equal("hello", te.format_result("hello"))
      assert.equal("42", te.format_result(42))
      assert.equal("true", te.format_result(true))
      assert.is_true(type(te.format_result({ key = "value" })) == "string")
    end,

    test_executor_handle_error = function()
      local te = require("NeoAI.tools.tool_executor")
      local result = te.handle_error("参数错误")
      assert.is_true(type(result) == "string" and #result > 0)
    end,

    test_executor_history = function()
      local te = require("NeoAI.tools.tool_executor")
      te.clear_history()
      te._record_execution("test_tool", { arg1 = "val1" }, "result", nil, 100)
      te._record_execution("error_tool", { arg2 = "val2" }, nil, "出错了", 50)
      local history = te.get_execution_history()
      assert.is_true(#history >= 2, "应有至少2条历史记录")
      assert.is_true(history[1].success)
      assert.is_false(history[2].success)
    end,

    test_executor_clear_history = function()
      local te = require("NeoAI.tools.tool_executor")
      te.clear_history()
      assert.is_true(#te.get_execution_history() == 0, "清空后应为0条")
    end,

    test_executor_cleanup = function()
      local te = require("NeoAI.tools.tool_executor")
      te.cleanup()
      te.update_config({ max_history_size = 50 })
    end,

    test_executor_generate_example = function()
      local te = require("NeoAI.tools.tool_executor")
      local tool = { name = "test_tool", parameters = { type = "object", properties = { filepath = { type = "string", description = "文件路径" }, count = { type = "number", description = "数量" } }, required = { "filepath" } } }
      local example = te._generate_example(tool)
      assert.not_nil(example, "应生成示例")
      assert.is_true(string.find(example, "test_tool") ~= nil)
      assert.equal(nil, te._generate_example({ name = "simple_tool" }), "无参数工具应返回 nil")
    end,

    test_executor_async = function()
      local te = require("NeoAI.tools.tool_executor")
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register({ name = "async_test_tool", description = "异步测试", func = function(args) return "executed: " .. (args.input or "") end, parameters = { type = "object", properties = { input = { type = "string" } }, required = {} } })
      local result = nil
      te.execute_async("async_test_tool", { input = "hello" }, function(res) result = res end, function(err) result = "error: " .. err end)
      vim.wait(500, function() return result ~= nil end)
      assert.not_nil(result, "异步执行应返回结果")
    end,

    test_executor_async_missing_tool = function()
      local te = require("NeoAI.tools.tool_executor")
      local result = nil
      te.execute_async("nonexistent_tool", {}, function(res) result = res end, function(err) result = "error: " .. err end)
      vim.wait(500, function() return result ~= nil end)
      assert.not_nil(result, "不存在的工具应返回提示信息")
    end,

    test_executor_batch_async = function()
      local te = require("NeoAI.tools.tool_executor")
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register({ name = "batch_tool", func = function() return "batch_ok" end, parameters = { type = "object", properties = {}, required = {} } })
      te.batch_execute_async({ { "batch_tool", {}, function() end, function() end } })
    end,

    -- ========== tool_validator ==========
    test_validator_initialize = function()
      local tv = require("NeoAI.tools.tool_validator")
      tv.reset()
      local ok, msg = tv.initialize({})
      assert.is_true(ok, "初始化应成功: " .. tostring(msg))
    end,

    test_validator_validate_schema = function()
      local tv = require("NeoAI.tools.tool_validator")
      local valid, msg = tv.validate_schema({ type = "object", properties = { name = { type = "string" }, age = { type = "number" } }, required = { "name" } })
      assert.is_true(valid, "有效 schema 应通过: " .. tostring(msg))
      assert.is_false(tv.validate_schema({ type = "invalid_type" }), "无效类型应失败")
      assert.is_true(tv.validate_schema(nil), "nil schema 应通过")
    end,

    test_validator_validate_parameters = function()
      local tv = require("NeoAI.tools.tool_validator")
      local schema = { type = "object", properties = { name = { type = "string" }, age = { type = "number", minimum = 0, maximum = 150 }, active = { type = "boolean" } }, required = { "name" } }
      assert.is_true(tv.validate_parameters(schema, { name = "张三", age = 25, active = true }), "有效参数应通过")
      assert.is_false(tv.validate_parameters(schema, { age = 25 }), "缺少必需字段应失败")
      assert.is_false(tv.validate_parameters(schema, { name = "张三", age = "二十五" }), "类型错误应失败")
      assert.is_false(tv.validate_parameters(schema, { name = "张三", age = 200 }), "超出范围应失败")
      assert.is_true(tv.validate_parameters(nil, { a = 1 }), "nil schema 应通过")
    end,

    test_validator_validate_parameters_enum = function()
      local tv = require("NeoAI.tools.tool_validator")
      local schema = { type = "object", properties = { color = { type = "string", enum = { "red", "green", "blue" } } }, required = { "color" } }
      assert.is_true(tv.validate_parameters(schema, { color = "red" }), "枚举内值应通过")
      assert.is_false(tv.validate_parameters(schema, { color = "yellow" }), "枚举外值应失败")
    end,

    test_validator_validate_parameters_nested = function()
      local tv = require("NeoAI.tools.tool_validator")
      local schema = { type = "object", properties = { config = { type = "object", properties = { host = { type = "string" }, port = { type = "number" } }, required = { "host" } } }, required = { "config" } }
      assert.is_true(tv.validate_parameters(schema, { config = { host = "localhost", port = 8080 } }), "嵌套对象应通过")
      assert.is_false(tv.validate_parameters(schema, { config = { port = 8080 } }), "嵌套对象缺少必需字段应失败")
    end,

    test_validator_validate_return_type = function()
      local tv = require("NeoAI.tools.tool_validator")
      assert.is_true(tv.validate_return_type("string", "hello"))
      assert.is_true(tv.validate_return_type("number", 42))
      assert.is_true(tv.validate_return_type("boolean", true))
      assert.is_true(tv.validate_return_type("array", { 1, 2, 3 }))
      assert.is_true(tv.validate_return_type("object", { a = 1 }))
      assert.is_true(tv.validate_return_type("null", nil))
      assert.is_false(tv.validate_return_type("string", 42))
    end,

    test_validator_check_permissions = function()
      local tv = require("NeoAI.tools.tool_validator")
      assert.is_true(tv.check_permissions({}))
      assert.is_true(tv.check_permissions({ permissions = { read = "allowed" } }))
      local valid, msg = tv.check_permissions({ permissions = { read = "restricted" } })
      assert.is_false(valid, "受限权限应失败")
    end,

    test_validator_validate_tool = function()
      local tv = require("NeoAI.tools.tool_validator")
      assert.is_true(tv.validate_tool({ name = "test_tool", func = function() end, parameters = { type = "object", properties = {} } }), "有效工具应通过")
      assert.is_false(tv.validate_tool({ func = function() end }), "无名称应失败")
      assert.is_false(tv.validate_tool({ name = "no_func" }), "无函数应失败")
      assert.is_false(tv.validate_tool(nil), "nil 应失败")
    end,

    test_validator_validate_tool_call = function()
      local tv = require("NeoAI.tools.tool_validator")
      local tr = require("NeoAI.tools.tool_registry")
      tr.reset()
      tr.initialize({})
      tr.register({ name = "test_tool", func = function() end, parameters = { type = "object", properties = { input = { type = "string" } }, required = { "input" } } })
      assert.is_true(tv.validate_tool_call({ name = "test_tool", arguments = { input = "hello" } }, tr).valid, "有效调用应通过")
      assert.is_false(tv.validate_tool_call({ arguments = {} }, tr).valid)
      assert.is_false(tv.validate_tool_call({ name = "nonexistent", arguments = {} }, tr).valid)
      assert.is_false(tv.validate_tool_call({ name = "test_tool", arguments = {} }, tr).valid)
    end,

    test_validator_config = function()
      local tv = require("NeoAI.tools.tool_validator")
      tv.update_config({ custom_key = "custom_value" })
      assert.equal("custom_value", tv.get_config().custom_key)
      assert.is_true(tv.is_initialized())
      tv.reset()
      assert.is_false(tv.is_initialized(), "重置后应未初始化")
      tv.initialize({})
    end,

    -- ========== tool_pack ==========
    test_pack_initialize = function()
      local tp = require("NeoAI.tools.tool_pack")
      tp.initialize()
      tp.initialize()
    end,

    test_pack_register_and_get = function()
      local tp = require("NeoAI.tools.tool_pack")
      local ok = tp.register_pack({ name = "test_pack", display_name = "测试包", icon = "🧪", tools = { "tool_a", "tool_b" }, order = 10 })
      assert.is_true(ok, "注册包应成功")
      assert.is_false(tp.register_pack(nil), "nil 应注册失败")
      local pack = tp.get_pack("test_pack")
      assert.not_nil(pack, "应获取到包")
      assert.equal("测试包", pack.display_name)
      assert.equal(nil, tp.get_pack("nonexistent"))
    end,

    test_pack_get_pack_for_tool = function()
      local tp = require("NeoAI.tools.tool_pack")
      tp.register_pack({ name = "test_pack_find", display_name = "查找测试", icon = "🔍", tools = { "find_me_tool" }, order = 1 })
      assert.equal("test_pack_find", tp.get_pack_for_tool("find_me_tool"))
      assert.equal(nil, tp.get_pack_for_tool("nonexistent_tool"))
    end,

    test_pack_get_all_packs = function()
      local tp = require("NeoAI.tools.tool_pack")
      tp.register_pack({ name = "test_all_packs", display_name = "所有包测试", icon = "📦", tools = {}, order = 1 })
      assert.is_true(#tp.get_all_packs() > 0, "应有至少1个包")
    end,

    test_pack_display_name_and_icon = function()
      local tp = require("NeoAI.tools.tool_pack")
      tp.register_pack({ name = "test_pack_display", display_name = "测试显示", icon = "📦", tools = {}, order = 1 })
      assert.equal("测试显示", tp.get_pack_display_name("test_pack_display"))
      assert.equal("工具调用", tp.get_pack_display_name("_uncategorized"))
      assert.equal("📦", tp.get_pack_icon("test_pack_display"))
      assert.equal("🔧", tp.get_pack_icon("_uncategorized"))
      assert.equal("🔧", tp.get_pack_icon("nonexistent"))
    end,

    test_pack_tools = function()
      local tp = require("NeoAI.tools.tool_pack")
      tp.register_pack({ name = "test_pack_tools", display_name = "测试工具列表", icon = "🔧", tools = { "tool_x", "tool_y", "tool_z" }, order = 1 })
      local tools = tp.get_pack_tools("test_pack_tools")
      assert.is_true(#tools >= 2, "应有至少2个工具")
      assert.contains(tools, "tool_x")
      assert.is_true(#tp.get_all_tool_names() > 0, "应有工具名称")
    end,

    test_pack_group_by_pack = function()
      local tp = require("NeoAI.tools.tool_pack")
      tp.register_pack({ name = "test_pack_group", display_name = "分组测试", icon = "📦", tools = { "group_tool" }, order = 1 })
      local grouped = tp.group_by_pack({ { name = "group_tool", func = { name = "group_tool" } }, { name = "nonexistent_tool" } })
      assert.not_nil(grouped.test_pack_group, "group_tool 应归入 test_pack_group")
      assert.not_nil(grouped._uncategorized, "未分类工具应归入 _uncategorized")
      assert.is_true(next(tp.group_by_pack({})) == nil, "空列表应返回空表")
    end,

    test_pack_order = function()
      local tp = require("NeoAI.tools.tool_pack")
      tp.register_pack({ name = "order_test", display_name = "排序测试", icon = "🔢", tools = {}, order = 10 })
      assert.equal(10, tp.get_pack_order("order_test"))
      assert.equal(99, tp.get_pack_order("nonexistent"))
    end,
  })
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
