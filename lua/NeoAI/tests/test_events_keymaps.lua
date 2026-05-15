--- 测试: 事件常量和键位管理器
--- 合并了 test_event_constants, test_keymap_manager
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  -- 确保 _logger 可用（直接 dofile 运行时可能为 nil）
  if not test._logger then
    local logger = require("NeoAI.utils.logger")
    test._logger = logger
  end
  test._logger.info("\n=== test_events_keymaps ===")

  local function init_km()
    -- 删除保存的 keymap 文件，避免影响测试
    local config_file = vim.fn.stdpath("config") .. "/neoai_keymaps.json"
    local f = io.open(config_file, "r")
    if f then f:close(); os.remove(config_file) end
    local km = require("NeoAI.core.config.keymap_manager")
    km.initialize({ keymaps = { global = { open_tree = { key = "<leader>at", desc = "打开树界面" }, open_chat = { key = "<leader>ac", desc = "打开聊天界面" }, close_all = { key = "<leader>aq", desc = "关闭所有窗口" } }, tree = { select = { key = "<CR>", desc = "选择节点" }, new_child = { key = "n", desc = "新建子分支" } }, chat = { send = { insert = { key = "<CR>", desc = "发送消息" }, normal = { key = "<CR>", desc = "发送消息" } }, cancel = { key = "<Esc>", desc = "取消生成" } } } })
    return km
  end

  return test.run_tests({
    -- ========== event_constants ==========
    test_events_all_constants_are_strings = function()
      local Events = require("NeoAI.core.events")
      for name, value in pairs(Events) do
        assert.is_true(type(value) == "string", string.format("常量 %s 应为字符串, 实际为 %s", name, type(value)))
      end
    end,

    test_events_all_have_prefix = function()
      local Events = require("NeoAI.core.events")
      for name, value in pairs(Events) do
        assert.is_true(string.find(value, "^NeoAI:") ~= nil, string.format("常量 %s 的值 '%s' 应以 'NeoAI:' 开头", name, value))
      end
    end,

    test_events_no_duplicates = function()
      local Events = require("NeoAI.core.events")
      local seen = {}
      for name, value in pairs(Events) do
        if seen[value] then
          error(string.format("重复的事件值: %s (已由 %s 定义, 又由 %s 定义)", value, seen[value], name))
        end
        seen[value] = name
      end
    end,

    test_events_key_constants_exist = function()
      local Events = require("NeoAI.core.events")
      local required = { "GENERATION_STARTED", "GENERATION_COMPLETED", "GENERATION_ERROR", "STREAM_STARTED", "STREAM_CHUNK", "STREAM_COMPLETED", "REASONING_CONTENT", "REASONING_STARTED", "REASONING_COMPLETED", "TOOL_CALL_DETECTED", "TOOL_RESULT_RECEIVED", "SESSION_CREATED", "SESSION_DELETED", "SESSION_CHANGED", "MESSAGE_ADDED", "MESSAGE_SENT", "CHAT_WINDOW_OPENED", "TREE_WINDOW_OPENED", "SEND_MESSAGE", "CANCEL_GENERATION", "PLUGIN_INITIALIZED" }
      for _, name in ipairs(required) do
        assert.not_nil(Events[name], string.format("必需常量 %s 不存在", name))
      end
    end,

    test_events_naming_convention = function()
      local Events = require("NeoAI.core.events")
      for name, _ in pairs(Events) do
        assert.is_true(string.match(name, "^[A-Z][A-Z0-9_]*$") ~= nil, string.format("常量名 '%s' 不符合大写+下划线规范", name))
      end
    end,

    test_events_constant_count = function()
      local Events = require("NeoAI.core.events")
      local count = 0
      for _ in pairs(Events) do count = count + 1 end
      assert.is_true(count > 50, string.format("应有 50+ 个常量, 实际 %d 个", count))
    end,

    -- ========== keymap_manager ==========
    test_keymap_initialize = function()
      local km = init_km()
      local contexts = km.get_available_contexts()
      assert.is_true(#contexts > 0, "应有可用上下文")
      assert.contains(contexts, "global")
      assert.contains(contexts, "tree")
      assert.contains(contexts, "chat")
    end,

    test_keymap_get_keymap = function()
      local km = init_km()
      local keymap = km.get_keymap("global", "open_tree")
      assert.not_nil(keymap, "应获取到键位")
      assert.equal("<leader>at", keymap.key)
      assert.equal(nil, km.get_keymap("nonexistent", "action"), "不存在的上下文应返回 nil")
      assert.equal(nil, km.get_keymap("global", "nonexistent"), "不存在的动作应返回 nil")
    end,

    test_keymap_get_context_keymaps = function()
      local km = init_km()
      local global_keymaps = km.get_context_keymaps("global")
      assert.not_nil(global_keymaps)
      assert.not_nil(global_keymaps.open_tree)
      assert.not_nil(global_keymaps.open_chat)
      assert.is_true(type(km.get_context_keymaps("nonexistent")) == "table", "不存在的上下文应返回空表")
    end,

    test_keymap_set_keymap = function()
      local km = init_km()
      local ok = km.set_keymap("global", "open_tree", "<leader>tt", "自定义打开树")
      assert.is_true(ok, "设置键位应成功")
      local keymap = km.get_keymap("global", "open_tree")
      assert.equal("<leader>tt", keymap.key)
      assert.equal("自定义打开树", keymap.desc)
    end,

    test_keymap_reset_keymap = function()
      local km = init_km()
      km.set_keymap("global", "open_tree", "<leader>xx")
      km.reset_keymap("global", "open_tree")
      assert.equal("<leader>at", km.get_keymap("global", "open_tree").key, "重置后应恢复默认")
    end,

    test_keymap_validate_key = function()
      local km = require("NeoAI.core.config.keymap_manager")
      assert.is_true(km.validate_key("<leader>at"), "有效键位")
      assert.is_true(km.validate_key("<CR>"), "有效键位")
      assert.is_true(km.validate_key("n"), "有效键位")
      assert.is_false(km.validate_key(""), "空字符串无效")
      assert.is_false(km.validate_key(123), "非字符串无效")
    end,

    test_keymap_list_keymaps = function()
      local km = init_km()
      local all = km.list_keymaps()
      assert.not_nil(all.global)
      assert.not_nil(all.tree)
      assert.not_nil(all.chat)
      local tree_only = km.list_keymaps("tree")
      assert.not_nil(tree_only.select)
      assert.equal(nil, tree_only.open_tree, "tree 上下文不应有 global 的键位")
    end,

    test_keymap_get_available_actions = function()
      local km = init_km()
      local actions = km.get_available_actions("global")
      assert.contains(actions, "open_tree")
      assert.contains(actions, "open_chat")
      assert.is_true(#km.get_available_actions("nonexistent") == 0, "不存在的上下文应返回空表")
    end,

    test_keymap_export_formatted = function()
      local km = init_km()
      local formatted = km.export_formatted()
      assert.is_true(type(formatted) == "string" and #formatted > 0)
    end,

    test_keymap_save_load = function()
      local km = init_km()
      km.set_keymap("global", "open_tree", "<leader>tt")
      local ok = km.save_keymaps()
      assert.is_true(ok, "保存应成功")
      km.reset_keymap("global", "open_tree")
      assert.equal("<leader>at", km.get_keymap("global", "open_tree").key, "重置后应恢复默认")
      km.load_keymaps()
      assert.equal("<leader>tt", km.get_keymap("global", "open_tree").key, "加载后应恢复保存的键位")
    end,

    test_keymap_get_default_keymaps = function()
      local km = init_km()
      local defaults = km.get_default_keymaps()
      assert.is_true(#defaults > 0, "应有默认键位")
      assert.not_nil(defaults[1].mode)
      assert.not_nil(defaults[1].key)
      assert.not_nil(defaults[1].action)
    end,

    test_keymap_register_and_apply = function()
      local km = init_km()
      local ok = km.register_keymap({ mode = "n", key = "<leader>tt", action = function() end, desc = "测试键位" })
      assert.is_true(ok, "注册键位应成功")
      assert.is_true(km.apply_keymaps(), "应用键位应成功")
      assert.is_true(km.cleanup_keymaps(), "清理键位应成功")
    end,
  })
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
