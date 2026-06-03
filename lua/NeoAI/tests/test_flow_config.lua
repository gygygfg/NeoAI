--- 流程测试: config 模块链
--- 调用链: default_config → merger → state → keymap_manager
--- 验证配置数据在各模块间正确流转

local M = {}

function M.run(test_module)
  local assert = test_module.assert

  local tests = {

    -- ============================================================
    -- 流程 1: default_config → merger 完整配置合并链
    -- ============================================================
    flow_default_to_merger = function()
      -- 步骤 1: 加载默认配置
      local dc = require("NeoAI.default_config")
      local default = dc.get_default_config()
      assert.not_nil(default, "默认配置不应为 nil")

      -- 验证关键段
      assert.not_nil(default.ai, "默认配置应有 ai 段")
      assert.not_nil(default.ai.providers, "ai 段应有 providers")
      assert.not_nil(default.ui, "默认配置应有 ui 段")
      assert.not_nil(default.session, "默认配置应有 session 段")
      assert.not_nil(default.log, "默认配置应有 log 段")
      assert.not_nil(default.keymaps, "默认配置应有 keymaps 段")
      assert.not_nil(default.tools, "默认配置应有 tools 段")

      -- 步骤 2: 通过 merger 合并用户配置
      local merger = require("NeoAI.core.config.merger")
      local user_config = {
        ai = { default = "fast" },
        ui = { window_mode = "float" },
        session = { auto_save = true },
        log = { level = "WARN" },
      }
      local merged = merger.process_config(user_config)
      assert.not_nil(merged, "合并配置不应为 nil")

      -- 步骤 3: 验证用户配置生效
      assert.equal("fast", merged.ai.default, "ai.default 应被用户覆盖")
      assert.equal("float", merged.ui.window_mode, "ui.window_mode 应被用户覆盖")

      -- 步骤 4: 验证未覆盖字段保留默认值
      assert.not_nil(merged.ai.providers, "未覆盖的 providers 应保留默认值")
      assert.not_nil(merged.ui.position, "未覆盖的 position 应保留默认值")
    end,

    -- ============================================================
    -- 流程 2: merger 场景候选项链
    -- ============================================================
    flow_merger_scenarios = function()
      local merger = require("NeoAI.core.config.merger")
      local dc = require("NeoAI.default_config")

      -- 步骤 1: 初始化 merger（空配置）
      merger.process_config({})

      -- 步骤 2: 获取 chat 场景候选项
      local candidates = merger.get_scenario_candidates("chat")
      assert.not_nil(candidates, "get_scenario_candidates 应返回非 nil")

      -- 步骤 3: 验证候选项结构
      if #candidates > 0 then
        local first = candidates[1]
        assert.not_nil(first.provider, "候选项应有 provider 字段")
        assert.not_nil(first.model_name, "候选项应有 model_name 字段")
      end

      -- 步骤 4: 获取所有可用模型
      local models = merger.get_all_available_models("chat")
      assert.not_nil(models, "get_all_available_models 应返回非 nil")
      assert.is_true(#models > 0, "应有至少一个可用模型")

      -- 步骤 5: 测试 get_preset
      local preset = merger.get_preset("chat")
      if preset then
        assert.type_eq("table", preset, "preset 应为表")
      end
    end,

    -- ============================================================
    -- 流程 3: merger → state 协程上下文链
    -- ============================================================
    flow_merger_to_state = function()
      local merger = require("NeoAI.core.config.merger")
      local sm = require("NeoAI.core.config.state")

      -- 步骤 1: 创建合并配置
      local config = merger.process_config({
        ai = { default = "chat" },
      })

      -- 步骤 2: 创建协程上下文，注入配置
      local ctx = sm.create_context({
        config = config,
        session_id = "flow_test_session",
        generation_id = "flow_test_gen",
      })
      assert.not_nil(ctx, "create_context 应返回上下文")

      -- 步骤 3: 在上下文中读写共享表
      sm.with_context(ctx, function()
        local shared = sm.get_shared()
        assert.not_nil(shared, "get_shared 应返回非 nil")
        assert.equal("chat", shared.config.ai.default, "shared 应包含配置数据")
        assert.equal("flow_test_session", shared.session_id, "shared 应包含 session_id")

        -- 写入新值
        sm.set_shared("test_key", "test_value")
        assert.equal("test_value", sm.get_shared_value("test_key"), "set_shared 写入应可读取")
      end)

      -- 步骤 4: 全局共享表独立于上下文
      sm.set_global("global_key", "global_value")
      assert.equal("global_value", sm.get_global("global_key"), "全局共享表应独立工作")
      assert.equal("default_fallback", sm.get_global("nonexistent", "default_fallback"),
        "不存在时应返回默认值")
    end,

    -- ============================================================
    -- 流程 4: state 嵌套上下文链
    -- ============================================================
    flow_state_nested = function()
      local sm = require("NeoAI.core.config.state")

      -- 步骤 1: 创建父上下文
      local parent = sm.create_context({ level = "parent", data = "parent_data" })
      sm.with_context(parent, function()
        sm.set_shared("parent_key", "parent_value")

        -- 步骤 2: 在父上下文中创建子上下文
        local child = parent:child()
        assert.not_nil(child, "子上下文应创建成功")

        sm.with_context(child, function()
          local shared = sm.get_shared()

          -- 子上下文应能读取父上下文的数据
          assert.equal("parent_value", shared.parent_key, "子应能读父的键")
          assert.equal("parent", shared.level, "子应能读父的 level")

          -- 子上下文写入新值
          sm.set_shared("child_key", "child_value")
          assert.equal("child_value", shared.child_key, "子应能写入")

          -- 子上下文不应覆盖父的值（同一共享表）
          assert.equal("parent_value", shared.parent_key, "父的键不应被子覆盖")
        end)

        -- 步骤 3: 回到父上下文
        local shared = sm.get_shared()
        assert.equal("child_value", shared.child_key, "父应能读取子写入的键")
      end)

      sm._test_reset()
    end,

    -- ============================================================
    -- 流程 5: state fire_event 链
    -- ============================================================
    flow_state_events = function()
      local sm = require("NeoAI.core.config.state")

      -- fire_event 在任何情况下都不应抛出异常
      local ok1 = pcall(sm.fire_event, "NeoAI:TestEvent", { key = "value" })
      assert.is_true(ok1, "fire_event 正常数据不应报错")

      local ok2 = pcall(sm.fire_event, "NeoAI:TestEvent", nil)
      assert.is_true(ok2, "fire_event nil 数据不应报错")

      local ok3 = pcall(sm.fire_event, nil, {})
      assert.is_true(ok3, "fire_event nil 事件名不应报错")
    end,

    -- ============================================================
    -- 流程 6: keymap_manager 完整生命周期（init → get → set → reset → save）
    -- ============================================================
    flow_keymap_lifecycle = function()
      local km = require("NeoAI.core.config.keymap_manager")
      local dc = require("NeoAI.default_config")

      -- 步骤 1: 用默认配置初始化
      local config = dc.get_default_config()
      km.initialize(config)

      -- 步骤 2: 获取可用上下文
      local contexts = km.get_available_contexts()
      assert.type_eq("table", contexts, "get_available_contexts 应返回表")
      -- 至少应有 global 上下文
      assert.contains(contexts, "global", "应有 global 上下文")

      -- 步骤 3: 获取上下文中的所有动作
      local actions = km.get_available_actions("global")
      assert.type_eq("table", actions, "get_available_actions 应返回表")

      -- 步骤 4: 获取单个键位
      if #actions > 0 then
        local action = actions[1]
        local keymap = km.get_keymap("global", action)
        assert.not_nil(keymap, "get_keymap 应返回非 nil")
        assert.not_nil(keymap.key, "键位应包含 key 字段")
        assert.not_nil(keymap.desc, "键位应包含 desc 字段")
      end

      -- 步骤 5: 设置自定义键位
      if #actions > 0 then
        local action = actions[1]
        local ok = km.set_keymap("global", action, "<leader>zz", "自定义测试键位")
        assert.is_true(ok, "set_keymap 应返回 true")

        -- 验证设置成功
        local keymap = km.get_keymap("global", action)
        assert.equal("<leader>zz", keymap.key, "自定义键位应生效")
      end

      -- 步骤 6: 重置键位
      if #actions > 0 then
        local action = actions[1]
        local ok = km.reset_keymap("global", action)
        assert.is_true(ok, "reset_keymap 应返回 true")
      end

      -- 步骤 7: 列出所有键位
      local all = km.list_keymaps()
      assert.type_eq("table", all, "list_keymaps 应返回表")

      -- 步骤 8: 列出特定上下文
      local global_keymaps = km.list_keymaps("global")
      assert.type_eq("table", global_keymaps, "list_keymaps('global') 应返回表")
    end,

    -- ============================================================
    -- 流程 7: keymap_manager 导入/导出一致性
    -- ============================================================
    flow_keymap_export_import = function()
      local km = require("NeoAI.core.config.keymap_manager")
      local dc = require("NeoAI.default_config")

      -- 步骤 1: 初始化
      km.initialize(dc.get_default_config())

      -- 步骤 2: 导出格式化键位
      local formatted = km.export_formatted()
      assert.type_eq("string", formatted, "export_formatted 应返回字符串")
      assert.is_true(#formatted > 0, "导出结果不应为空")
      assert.is_true(formatted:find("键位配置", 1, true) ~= nil, "导出应包含标题")

      -- 步骤 3: 获取默认键位（测试兼容性格式）
      local defaults = km.get_default_keymaps()
      assert.type_eq("table", defaults, "get_default_keymaps 应返回表")
    end,

    -- ============================================================
    -- 流程 8: config/init.lua 入口模块
    -- ============================================================
    flow_config_init = function()
      local ok, ci = pcall(require, "NeoAI.core.config")
      assert.is_true(ok, "NeoAI.core.config 入口应能加载")

      if ok and ci then
        -- 验证导出
        assert.not_nil(ci.keymap_manager, "应导出 keymap_manager")
        assert.not_nil(ci.merger, "应导出 merger")
        assert.not_nil(ci.state, "应导出 state")

        -- 验证 initialize 不报错
        local dc = require("NeoAI.default_config")
        local ok_init = pcall(ci.initialize, ci, dc.get_default_config())
        assert.is_true(ok_init, "config.initialize 不应报错")
      end
    end,

    -- ============================================================
    -- 流程 9: merger 无效值回退链
    -- ============================================================
    flow_merger_invalid_fallback = function()
      local merger = require("NeoAI.core.config.merger")

      -- 步骤 1: 传入无效的 ui.window_mode
      local config = merger.process_config({
        ui = { window_mode = "invalid_xxx" },
        ai = { default = "invalid_scenario" },
      })

      -- 步骤 2: 验证无效值被回退到有效默认值
      assert.not_nil(config.ui.window_mode, "无效值后 window_mode 不应为 nil")
      -- 有效值应为 window / float / tab 之一
      local valid_modes = { window = true, float = true, tab = true }
      assert.is_true(valid_modes[config.ui.window_mode],
        "window_mode 应回退到有效值，实际: " .. tostring(config.ui.window_mode))

      -- 步骤 3: 验证 ai.default 回退
      assert.not_nil(config.ai.default, "无效值后 ai.default 不应为 nil")
      assert.not_equal("invalid_scenario", config.ai.default,
        "ai.default 不应保持无效值")
    end,
  }

  return test_module.run_tests(tests)
end

return M
