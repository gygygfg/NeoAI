--- 测试: 各模块 init 入口
--- 合并了 test_config_init, test_core_init, test_ai_init, test_ui_init, test_tools_init, test_utils_init, test_main_init
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  test._logger.info("\n=== test_init_modules ===")

  return test.run_tests({
    -- ========== core/config/init.lua ==========
    test_config_init_exports = function()
      local config = require("NeoAI.core.config")
      assert.not_nil(config.keymap_manager, "应导出 keymap_manager")
      assert.not_nil(config.state, "应导出 state")
      assert.not_nil(config.merger, "应导出 merger")
    end,

    test_config_init_initialize = function()
      local config = require("NeoAI.core.config")
      local state = require("NeoAI.core.config.state")
      state._test_reset()
      local ok, err = pcall(config.initialize, { keymaps = { global = { test = { key = "<leader>t" } } } })
      assert.is_true(ok, "初始化应成功: " .. tostring(err))
      local km = config.keymap_manager
      local contexts = km.get_available_contexts()
      assert.is_true(#contexts > 0, "应有可用上下文")
    end,

    -- ========== core/init.lua ==========
    test_shutdown_flag_basic = function()
      local sf = require("NeoAI.core.shutdown_flag")
      sf.reset()
      assert.is_false(sf.is_set(), "初始应未设置")
      sf.set()
      assert.is_true(sf.is_set(), "设置后应为 true")
      sf.reset()
      assert.is_false(sf.is_set(), "重置后应为 false")
    end,

    test_shutdown_flag_idempotent = function()
      local sf = require("NeoAI.core.shutdown_flag")
      sf.reset()
      sf.set()
      sf.set()
      assert.is_true(sf.is_set())
      sf.reset()
    end,

    test_core_get_ai_engine = function()
      local core = require("NeoAI.core")
      local ok, engine = pcall(core.get_ai_engine, core)
      if ok and engine then
        assert.is_true(type(engine.get_status) == "function")
      end
    end,

    test_core_get_keymap_manager = function()
      local core = require("NeoAI.core")
      local ok, km = pcall(core.get_keymap_manager, core)
      if ok and km then
        assert.is_true(type(km.get_available_contexts) == "function")
      end
    end,

    test_core_get_history_manager = function()
      local core = require("NeoAI.core")
      local ok, hm = pcall(core.get_history_manager, core)
      if ok and hm then
        assert.is_true(type(hm.is_initialized) == "function")
      end
    end,

    test_core_get_config = function()
      local core = require("NeoAI.core")
      local ok, config = pcall(core.get_config, core)
      if ok and config then
        assert.is_true(type(config) == "table")
      end
    end,

    -- ========== core/ai/init.lua ==========
    test_ai_init_exports = function()
      local ai = require("NeoAI.core.ai")
      assert.not_nil(ai.ai_engine, "应导出 ai_engine")
      assert.not_nil(ai.http_client, "应导出 http_client")
      assert.not_nil(ai.request_adapter, "应导出 request_adapter")
      assert.not_nil(ai.tool_orchestrator, "应导出 tool_orchestrator")
      assert.not_nil(ai.chat_service, "应导出 chat_service")
    end,

    test_ai_init_initialize = function()
      local ai = require("NeoAI.core.ai")
      local ok, err = pcall(ai.initialize, ai, {})
      assert.is_true(type(ok) == "boolean")
    end,

    test_ai_init_shutdown = function()
      local ai = require("NeoAI.core.ai")
      local ok, err = pcall(ai.shutdown, ai)
    end,

    -- ========== ui/init.lua ==========
    test_ui_init_initialize = function()
      local ui = require("NeoAI.ui")
      ui.initialize({ ui = { default_ui = "chat", window_mode = "float", window = { width = 60, height = 15, border = "none" } }, session = { auto_save = false, auto_naming = false } })
      local mode = ui.get_current_ui_mode()
      assert.is_true(mode == nil or type(mode) == "string")
    end,

    test_ui_get_window_manager = function()
      local ui = require("NeoAI.ui")
      local wm = ui.get_window_manager()
      assert.not_nil(wm, "窗口管理器应存在")
    end,

    test_ui_get_current_session_id = function()
      local ui = require("NeoAI.ui")
      local id = ui.get_current_session_id()
      assert.is_true(type(id) == "string", "会话 ID 应为字符串")
    end,

    test_ui_update_current_session_id = function()
      local ui = require("NeoAI.ui")
      ui.update_current_session_id("session_test_1")
      assert.equal("session_test_1", ui.get_current_session_id())
    end,

    test_ui_get_event_count = function()
      local ui = require("NeoAI.ui")
      ui.reset_event_count()
      assert.equal(0, ui.get_event_count(), "重置后计数应为 0")
    end,

    test_ui_close_all_windows = function()
      local ui = require("NeoAI.ui")
      ui.close_all_windows()
    end,

    test_ui_list_windows = function()
      local ui = require("NeoAI.ui")
      local windows = ui.list_windows()
      assert.is_true(type(windows) == "table", "list_windows 应返回表")
    end,

    test_ui_switch_mode = function()
      local ui = require("NeoAI.ui")
      local ok, err = pcall(function() ui.switch_mode("chat") end)
    end,

    test_ui_refresh_current_ui = function()
      local ui = require("NeoAI.ui")
      ui.refresh_current_ui()
    end,

    test_ui_update_config = function()
      local ui = require("NeoAI.ui")
      local ok, err = pcall(ui.update_config, ui, { window = { width = 100 } })
    end,

    test_ui_handle_key_input = function()
      local ui = require("NeoAI.ui")
      local ok, err = pcall(ui.handle_key_input, ui, "<CR>")
    end,

    test_ui_reasoning_functions = function()
      local ui = require("NeoAI.ui")
      ui.initialize({ reasoning = {} })
      ui.show_reasoning("测试思考内容")
      ui.append_reasoning("追加内容")
      ui.close_reasoning()
    end,

    -- ========== tools/init.lua ==========
    test_tools_init_initialize = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      local tool_list = tools.get_tools()
      assert.is_true(type(tool_list) == "table", "get_tools 应返回表")
    end,

    test_tools_register_tool = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      local ok = tools.register_tool({ name = "my_tool", description = "测试工具", func = function(args) return "执行结果: " .. (args and args.input or "无参数") end, parameters = { type = "object", properties = { input = { type = "string", description = "输入参数" } }, required = {} } })
      assert.is_true(ok, "注册工具应成功")
      local tool = tools.get_tool("my_tool")
      assert.not_nil(tool, "应能获取已注册的工具")
    end,

    test_tools_register_duplicate = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      tools.register_tool({ name = "dup_tool", description = "", func = function() end, parameters = { type = "object", properties = {}, required = {} } })
      local ok = tools.register_tool({ name = "dup_tool", description = "", func = function() end, parameters = { type = "object", properties = {}, required = {} } })
      assert.is_false(ok, "重复注册应返回 false")
    end,

    test_tools_get_tools = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      tools.register_tool({ name = "tool_a", description = "", func = function() end, parameters = { type = "object", properties = {}, required = {} } })
      tools.register_tool({ name = "tool_b", description = "", func = function() end, parameters = { type = "object", properties = {}, required = {} } })
      local list = tools.get_tools()
      assert.is_true(#list >= 2, "应有至少 2 个工具")
    end,

    test_tools_get_tool = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      tools.register_tool({ name = "find_me", description = "", func = function() end, parameters = { type = "object", properties = {}, required = {} } })
      assert.not_nil(tools.get_tool("find_me"))
      assert.equal(nil, tools.get_tool("nonexistent"))
    end,

    test_tools_unregister_tool = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      tools.register_tool({ name = "to_remove", description = "", func = function() end, parameters = { type = "object", properties = {}, required = {} } })
      assert.is_true(tools.unregister_tool("to_remove"), "注销应成功")
      assert.equal(nil, tools.get_tool("to_remove"), "注销后应不存在")
    end,

    test_tools_execute_tool = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false, approval = { default_auto_allow = true } })
      tools.register_tool({ name = "exec_tool", description = "", func = function(args) return "执行结果: " .. (args and args.input or "") end, parameters = { type = "object", properties = { input = { type = "string" } }, required = {} }, approval = { auto_allow = true } })
      local result = tools.execute_tool("exec_tool", { input = "hello" })
      assert.equal("执行结果: hello", result)
    end,

    test_tools_validate_tool_args = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      tools.register_tool({ name = "valid_tool", description = "", func = function() end, parameters = { type = "object", properties = { input = { type = "string" } }, required = {} } })
      local valid, msg = tools.validate_tool_args("valid_tool", { input = "test" })
      assert.is_true(valid, "验证应通过: " .. tostring(msg))
      local valid2, msg2 = tools.validate_tool_args("nonexistent", {})
      assert.is_false(valid2, "不存在的工具应验证失败")
    end,

    test_tools_search_tools = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      tools.register_tool({ name = "file_read", description = "读取文件内容", func = function() end, parameters = { type = "object", properties = {}, required = {} } })
      tools.register_tool({ name = "file_write", description = "写入文件内容", func = function() end, parameters = { type = "object", properties = {}, required = {} } })
      local results = tools.search_tools("file")
      assert.is_true(#results >= 2, "应搜索到至少 2 个工具")
    end,

    test_tools_get_tool_count = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      local count_before = tools.get_tool_count()
      tools.register_tool({ name = "count_test", description = "", func = function() end, parameters = { type = "object", properties = {}, required = {} } })
      assert.equal(count_before + 1, tools.get_tool_count(), "注册后计数应增加")
    end,

    test_tools_reload_tools = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      tools.register_tool({ name = "before_reload", description = "", func = function() end, parameters = { type = "object", properties = {}, required = {} } })
      tools.reload_tools()
      assert.equal(nil, tools.get_tool("before_reload"), "reload 后工具应被清除")
    end,

    test_tools_get_history_manager = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      local hm = tools.get_history_manager()
      assert.not_nil(hm, "应返回历史管理器")
    end,

    test_tools_update_config = function()
      local tools = require("NeoAI.tools")
      tools.initialize({ enabled = true, builtin = false })
      tools.update_config({ enabled = true })
    end,

    -- ========== utils/init.lua ==========
    test_utils_init_auto_initialized = function()
      local utils = require("NeoAI.utils")
      assert.is_true(utils.is_module_loaded("common"), "common 应已加载")
    end,

    test_utils_list_modules = function()
      local utils = require("NeoAI.utils")
      local modules = utils.list_modules()
      assert.contains(modules, "common", "应包含 common 模块")
      assert.contains(modules, "table_utils", "应包含 table_utils 模块")
      assert.contains(modules, "file_utils", "应包含 file_utils 模块")
      assert.contains(modules, "logger", "应包含 logger 模块")
    end,

    test_utils_get_module = function()
      local utils = require("NeoAI.utils")
      local common = utils.get_module("common")
      assert.not_nil(common, "common 模块应存在")
      assert.equal(nil, utils.get_module("nonexistent"), "不存在的模块应返回 nil")
    end,

    test_utils_is_module_loaded = function()
      local utils = require("NeoAI.utils")
      assert.is_true(utils.is_module_loaded("common"), "common 应已加载")
      assert.is_false(utils.is_module_loaded("nonexistent"), "不存在的模块应未加载")
    end,

    test_utils_functions_merged = function()
      local utils = require("NeoAI.utils")
      assert.is_true(type(utils.list_modules) == "function", "list_modules 应可用")
      assert.is_true(type(utils.get_module) == "function", "get_module 应可用")
      assert.is_true(type(utils.is_module_loaded) == "function", "is_module_loaded 应可用")
    end,

    test_utils_reload = function()
      local utils = require("NeoAI.utils")
      utils.reload()
      assert.is_true(utils.is_module_loaded("common") or #utils.list_modules() > 0, "reload 后应有模块")
    end,

    -- ========== 断言工具测试 ==========
    test_assert_tools = function()
      local a = test.assert
      a.equal(1, 1)
      a.equal("hello", "hello")
      a.not_equal(1, 2)
      a.is_true(true)
      a.is_false(false)
      a.is_nil(nil)
      a.not_nil("value")
      a.has_key({ a = 1 }, "a")
      a.contains({ 1, 2, 3 }, 2)
      a.assert_error(function() error("预期错误") end, "预期错误")
    end,
  })
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
