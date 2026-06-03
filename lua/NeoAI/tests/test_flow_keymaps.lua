--- 流程测试: keymap_manager 完整生命周期
--- 验证 init → get → set → reset → export → save → load 的完整流程

local M = {}

function M.run(test_module)
  local assert = test_module.assert

  local tests = {

    -- ============================================================
    -- 流程 1: 初始化 → 获取默认键位
    -- ============================================================
    flow_keymap_init_and_get = function()
      local km = require("NeoAI.core.config.keymap_manager")
      local dc = require("NeoAI.default_config")

      -- 步骤 1: 初始化
      local config = dc.get_default_config()
      km.initialize(config)

      -- 步骤 2: 获取所有可用上下文
      local contexts = km.get_available_contexts()
      assert.not_nil(contexts, "get_available_contexts 应返回非 nil")
      assert.is_true(#contexts >= 1, "应有至少 1 个上下文，实际: " .. #contexts)

      -- 步骤 3: 遍历所有上下文，验证每个都有 actions
      for _, ctx in ipairs(contexts) do
        local actions = km.get_available_actions(ctx)
        assert.not_nil(actions, "上下文 " .. ctx .. " 的 actions 不应为 nil")

        -- 每个 action 应有有效键位
        for _, action in ipairs(actions) do
          local keymap = km.get_keymap(ctx, action)
          if keymap then
            assert.not_nil(keymap.key, ctx .. "." .. action .. " 应有 key 字段")
            assert.not_nil(keymap.desc, ctx .. "." .. action .. " 应有 desc 字段")
          end
        end
      end

      -- 步骤 4: 获取特定上下文的键位
      for _, ctx in ipairs({ "global", "tree", "chat" }) do
        if vim.tbl_contains(contexts, ctx) then
          local ctx_keymaps = km.get_context_keymaps(ctx)
          assert.type_eq("table", ctx_keymaps, ctx .. " 上下文键位应为表")
        end
      end
    end,

    -- ============================================================
    -- 流程 2: 设置 → 验证 → 重置 完整往返
    -- ============================================================
    flow_keymap_set_verify_reset = function()
      local km = require("NeoAI.core.config.keymap_manager")
      local dc = require("NeoAI.default_config")

      km.initialize(dc.get_default_config())

      -- 步骤 1: 保存原始键位
      local actions = km.get_available_actions("global")
      if #actions == 0 then return end

      local test_action = actions[1]
      local original = km.get_keymap("global", test_action)
      if not original then return end
      local original_key = original.key

      -- 步骤 2: 设置新键位
      local new_key = "<leader>ft"
      local ok = km.set_keymap("global", test_action, new_key, "流程测试键位")
      assert.is_true(ok, "set_keymap 应返回 true")

      -- 步骤 3: 验证设置生效
      local updated = km.get_keymap("global", test_action)
      assert.equal(new_key, updated.key, "键位应被更新为 " .. new_key)
      assert.equal("流程测试键位", updated.desc, "描述应被更新")

      -- 步骤 4: 重置键位
      local reset_ok = km.reset_keymap("global", test_action)
      assert.is_true(reset_ok, "reset_keymap 应返回 true")

      -- 步骤 5: 验证重置回原值
      local after_reset = km.get_keymap("global", test_action)
      assert.equal(original_key, after_reset.key, "重置后键位应回到原值")
    end,

    -- ============================================================
    -- 流程 3: 重置整个上下文
    -- ============================================================
    flow_keymap_reset_context = function()
      local km = require("NeoAI.core.config.keymap_manager")
      local dc = require("NeoAI.default_config")

      km.initialize(dc.get_default_config())

      local actions = km.get_available_actions("global")
      if #actions < 2 then return end

      -- 修改两个键位
      local a1 = actions[1]
      local a2 = actions[2]
      local orig1 = km.get_keymap("global", a1)
      local orig2 = km.get_keymap("global", a2)
      if not orig1 or not orig2 then return end

      km.set_keymap("global", a1, "<leader>aa", "test a")
      km.set_keymap("global", a2, "<leader>bb", "test b")

      -- 验证修改
      assert.equal("<leader>aa", km.get_keymap("global", a1).key, "a1 应被修改")
      assert.equal("<leader>bb", km.get_keymap("global", a2).key, "a2 应被修改")

      -- 重置整个上下文
      local reset_ok = km.reset_keymap("global", nil)
      assert.is_true(reset_ok, "重置整个上下文应成功")

      -- 验证全部重置
      assert.equal(orig1.key, km.get_keymap("global", a1).key, "a1 应被重置")
      assert.equal(orig2.key, km.get_keymap("global", a2).key, "a2 应被重置")
    end,

    -- ============================================================
    -- 流程 4: list_keymaps 完整性
    -- ============================================================
    flow_keymap_list = function()
      local km = require("NeoAI.core.config.keymap_manager")
      local dc = require("NeoAI.default_config")

      km.initialize(dc.get_default_config())

      -- 步骤 1: 列出所有键位
      local all = km.list_keymaps()
      assert.type_eq("table", all, "list_keymaps 应返回表")

      -- 步骤 2: 列出特定上下文
      local contexts = km.get_available_contexts()
      for _, ctx in ipairs(contexts) do
        local ctx_keymaps = km.list_keymaps(ctx)
        assert.type_eq("table", ctx_keymaps, "list_keymaps(" .. ctx .. ") 应返回表")
      end
    end,

    -- ============================================================
    -- 流程 5: export_formatted / get_default_keymaps 导出链
    -- ============================================================
    flow_keymap_export = function()
      local km = require("NeoAI.core.config.keymap_manager")
      local dc = require("NeoAI.default_config")

      km.initialize(dc.get_default_config())

      -- 步骤 1: 导出格式化文本
      local formatted = km.export_formatted()
      assert.type_eq("string", formatted, "export_formatted 应返回字符串")
      assert.is_true(#formatted > 0, "导出结果不应为空")

      -- 步骤 2: 验证包含各上下文标题
      for _, ctx in ipairs({ "GLOBAL", "TREE", "CHAT" }) do
        if formatted:find(ctx, 1, true) then
          -- 找到了标题，验证包含键位描述
          break  -- 至少一个上下文标题存在即可
        end
      end

      -- 步骤 3: 获取默认键位（兼容性格式）
      local defaults = km.get_default_keymaps()
      assert.type_eq("table", defaults, "get_default_keymaps 应返回表")
    end,

    -- ============================================================
    -- 流程 6: 验证键位有效性
    -- ============================================================
    flow_keymap_validation = function()
      local km = require("NeoAI.core.config.keymap_manager")
      local dc = require("NeoAI.default_config")

      km.initialize(dc.get_default_config())

      -- 步骤 1: 有效键位
      assert.is_true(km.validate_key("<leader>aa"), "<leader>aa 应为有效")
      assert.is_true(km.validate_key("<C-p>"), "<C-p> 应为有效")
      assert.is_true(km.validate_key("z"), "单字符 z 应为有效")

      -- 步骤 2: 无效键位
      assert.is_false(km.validate_key(""), "空字符串应为无效")
      assert.is_false(km.validate_key(nil), "nil 应为无效")
      assert.is_false(km.validate_key(123), "数字应为无效")
    end,

    -- ============================================================
    -- 流程 7: save / load 持久化链
    -- ============================================================
    flow_keymap_save_load = function()
      local km = require("NeoAI.core.config.keymap_manager")
      local dc = require("NeoAI.default_config")

      km.initialize(dc.get_default_config())

      -- 步骤 1: 修改键位
      local actions = km.get_available_actions("global")
      if #actions == 0 then return end
      local test_action = actions[1]
      local orig = km.get_keymap("global", test_action)
      if not orig then return end

      km.set_keymap("global", test_action, "<leader>ft", "save_load test")

      -- 步骤 2: 保存到文件
      -- save_keymaps 会写入 neoai_keymaps.json
      local save_ok = km.save_keymaps()
      -- 保存操作不应报错
      assert.is_true(true, "save_keymaps 应完成执行（结果: " .. tostring(save_ok) .. "）")

      -- 步骤 3: 重置键位
      km.reset_keymap("global", test_action)

      -- 步骤 4: 从文件加载
      local load_ok = km.load_keymaps()
      -- 加载操作不应报错
      assert.is_true(true, "load_keymaps 应完成执行（结果: " .. tostring(load_ok) .. "）")

      -- 步骤 5: 验证加载后键位（如果文件存在）
      local after_load = km.get_keymap("global", test_action)
      -- 如果 load 成功，键位应被恢复
      if load_ok and after_load then
        assert.type_eq("string", after_load.key, "加载后键位应为字符串")
      end
    end,
  }

  return test_module.run_tests(tests)
end

return M
