--- 测试: core/config/keymap_manager.lua
--- 测试键位管理器的初始化、获取、设置、重置、保存/加载等功能
local M = {}

local test

--- 创建一个测试配置
local function create_test_config()
  return {
    keymaps = {
      global = {
        open_tree = { key = "<leader>at", desc = "打开树界面" },
        open_chat = { key = "<leader>ac", desc = "打开聊天界面" },
        close_all = { key = "<leader>aq", desc = "关闭所有窗口" },
      },
      tree = {
        select = { key = "<CR>", desc = "选择节点" },
        new_child = { key = "n", desc = "新建子分支" },
      },
      chat = {
        send = {
          insert = { key = "<CR>", desc = "发送消息" },
          normal = { key = "<CR>", desc = "发送消息" },
        },
        cancel = { key = "<Esc>", desc = "取消生成" },
      },
    },
  }
end

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_keymap_manager ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())

      local contexts = km.get_available_contexts()
      assert.is_true(#contexts > 0, "应有可用上下文")
      assert.contains(contexts, "global")
      assert.contains(contexts, "tree")
      assert.contains(contexts, "chat")
    end,

    --- 测试 get_keymap
    test_get_keymap = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())
      -- 重置为默认，避免之前测试的污染
      km.load_default_keymaps()

      local keymap = km.get_keymap("global", "open_tree")
      assert.not_nil(keymap, "应获取到键位")
      assert.equal("<leader>at", keymap.key)
      assert.equal("打开树界面", keymap.desc)

      -- 不存在的上下文
      local missing = km.get_keymap("nonexistent", "action")
      assert.equal(nil, missing, "不存在的上下文应返回 nil")

      -- 不存在的动作
      local missing_action = km.get_keymap("global", "nonexistent")
      assert.equal(nil, missing_action, "不存在的动作应返回 nil")
    end,

    --- 测试 get_context_keymaps
    test_get_context_keymaps = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())

      local global_keymaps = km.get_context_keymaps("global")
      assert.not_nil(global_keymaps)
      assert.not_nil(global_keymaps.open_tree)
      assert.not_nil(global_keymaps.open_chat)
      assert.not_nil(global_keymaps.close_all)

      -- 不存在的上下文
      local missing = km.get_context_keymaps("nonexistent")
      assert.is_true(type(missing) == "table", "不存在的上下文应返回空表")
    end,

    --- 测试 set_keymap
    test_set_keymap = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())

      local ok = km.set_keymap("global", "open_tree", "<leader>tt", "自定义打开树")
      assert.is_true(ok, "设置键位应成功")

      local keymap = km.get_keymap("global", "open_tree")
      assert.equal("<leader>tt", keymap.key)
      assert.equal("自定义打开树", keymap.desc)
    end,

    --- 测试 reset_keymap
    test_reset_keymap = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())

      -- 先修改再重置
      km.set_keymap("global", "open_tree", "<leader>xx")
      km.reset_keymap("global", "open_tree")

      local keymap = km.get_keymap("global", "open_tree")
      assert.equal("<leader>at", keymap.key, "重置后应恢复默认")
    end,

    --- 测试 validate_key
    test_validate_key = function()
      local km = require("NeoAI.core.config.keymap_manager")

      assert.is_true(km.validate_key("<leader>at"), "有效键位")
      assert.is_true(km.validate_key("<CR>"), "有效键位")
      assert.is_true(km.validate_key("n"), "有效键位")
      assert.is_false(km.validate_key(""), "空字符串无效")
      assert.is_false(km.validate_key(123), "非字符串无效")
    end,

    --- 测试 list_keymaps
    test_list_keymaps = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())

      local all = km.list_keymaps()
      assert.not_nil(all.global)
      assert.not_nil(all.tree)
      assert.not_nil(all.chat)

      local tree_only = km.list_keymaps("tree")
      assert.not_nil(tree_only.select)
      assert.equal(nil, tree_only.open_tree, "tree 上下文不应有 global 的键位")
    end,

    --- 测试 get_available_actions
    test_get_available_actions = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())

      local actions = km.get_available_actions("global")
      assert.contains(actions, "open_tree")
      assert.contains(actions, "open_chat")

      -- 不存在的上下文
      local missing = km.get_available_actions("nonexistent")
      assert.is_true(#missing == 0, "不存在的上下文应返回空表")
    end,

    --- 测试 export_formatted
    test_export_formatted = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())

      local formatted = km.export_formatted()
      assert.is_true(type(formatted) == "string")
      assert.is_true(#formatted > 0)
      assert.is_true(string.find(formatted, "open_tree") ~= nil)
    end,

    --- 测试 save 和 load
    test_save_load = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())

      -- 修改键位并保存
      km.set_keymap("global", "open_tree", "<leader>tt")
      local ok = km.save_keymaps()
      assert.is_true(ok, "保存应成功")

      -- 重置并加载
      km.reset_keymap("global", "open_tree")
      assert.equal("<leader>at", km.get_keymap("global", "open_tree").key, "重置后应恢复默认")

      km.load_keymaps()
      assert.equal("<leader>tt", km.get_keymap("global", "open_tree").key, "加载后应恢复保存的键位")
    end,

    --- 测试 get_default_keymaps
    test_get_default_keymaps = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())

      local defaults = km.get_default_keymaps()
      assert.is_true(#defaults > 0, "应有默认键位")
      assert.not_nil(defaults[1].mode)
      assert.not_nil(defaults[1].key)
      assert.not_nil(defaults[1].action)
    end,

    --- 测试 register_keymap 和 apply_keymaps
    test_register_and_apply = function()
      local km = require("NeoAI.core.config.keymap_manager")
      km.initialize(create_test_config())

      local ok = km.register_keymap({
        mode = "n",
        key = "<leader>tt",
        action = function() end,
        desc = "测试键位",
      })
      assert.is_true(ok, "注册键位应成功")

      assert.is_true(km.apply_keymaps(), "应用键位应成功")
      assert.is_true(km.cleanup_keymaps(), "清理键位应成功")
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

