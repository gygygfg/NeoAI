--- 测试: default_config.lua
--- 测试默认配置的定义、结构完整性、字段类型等
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_default_config ===")

  return test.run_tests({
    --- 测试 get_default_config 返回完整配置
    test_get_default_config = function()
      local default_config = require("NeoAI.default_config")
      local config = default_config.get_default_config()
      assert.not_nil(config, "应返回配置")
      assert.has_key(config, "ai", "应包含 ai")
      assert.has_key(config, "ui", "应包含 ui")
      assert.has_key(config, "session", "应包含 session")
      assert.has_key(config, "keymaps", "应包含 keymaps")
      assert.has_key(config, "tools", "应包含 tools")
      assert.has_key(config, "log", "应包含 log")
    end,

    --- 测试默认配置的结构完整性
    test_config_structure = function()
      local default_config = require("NeoAI.default_config")
      local config = default_config.get_default_config()

      -- AI 配置
      assert.not_nil(config.ai.providers, "应有 providers")
      assert.not_nil(config.ai.scenarios, "应有 scenarios")
      assert.not_nil(config.ai.default, "应有 default")
      assert.not_nil(config.ai.system_prompt, "应有 system_prompt")

      -- UI 配置
      assert.not_nil(config.ui.default_ui, "应有 default_ui")
      assert.not_nil(config.ui.window_mode, "应有 window_mode")
      assert.not_nil(config.ui.window, "应有 window")

      -- 键位配置
      assert.not_nil(config.keymaps.global, "应有 global 键位")
      assert.not_nil(config.keymaps.tree, "应有 tree 键位")
      assert.not_nil(config.keymaps.chat, "应有 chat 键位")

      -- 会话配置
      assert.not_nil(config.session.auto_save, "应有 auto_save")
      assert.not_nil(config.session.save_path, "应有 save_path")

      -- 工具配置
      assert.not_nil(config.tools.enabled, "应有 enabled")
      assert.not_nil(config.tools.builtin, "应有 builtin")
    end,

    --- 测试默认值正确
    test_default_values = function()
      local default_config = require("NeoAI.default_config")
      local config = default_config.get_default_config()

      assert.equal("tree", config.ui.default_ui, "默认 default_ui 应为 tree")
      assert.equal("tab", config.ui.window_mode, "默认 window_mode 应为 tab")
      assert.equal(80, config.ui.window.width, "默认宽度应为 80")
      assert.equal(20, config.ui.window.height, "默认高度应为 20")
      assert.equal("rounded", config.ui.window.border, "默认边框应为 rounded")
    end,

    --- 测试 AI 提供商配置
    test_ai_providers = function()
      local default_config = require("NeoAI.default_config")
      local config = default_config.get_default_config()

      assert.not_nil(config.ai.providers.deepseek, "应有 deepseek 提供商")
      assert.not_nil(config.ai.providers.openai, "应有 openai 提供商")
      assert.not_nil(config.ai.providers.anthropic, "应有 anthropic 提供商")
      assert.not_nil(config.ai.providers.google, "应有 google 提供商")

      -- 验证提供商结构
      local deepseek = config.ai.providers.deepseek
      assert.equal("openai", deepseek.api_type)
      assert.is_true(#deepseek.models > 0, "应有模型列表")
    end,

    --- 测试 AI 场景配置
    test_ai_scenarios = function()
      local default_config = require("NeoAI.default_config")
      local config = default_config.get_default_config()

      local scenarios = config.ai.scenarios
      assert.not_nil(scenarios.naming, "应有 naming 场景")
      assert.not_nil(scenarios.chat, "应有 chat 场景")
      assert.not_nil(scenarios.reasoning, "应有 reasoning 场景")
      assert.not_nil(scenarios.coding, "应有 coding 场景")
      assert.not_nil(scenarios.tools, "应有 tools 场景")
      assert.not_nil(scenarios.agent, "应有 agent 场景")

      -- 每个场景应有配置数组
      for name, entry in pairs(scenarios) do
        assert.is_true(type(entry) == "table", string.format("场景 %s 应为表", name))
        assert.is_true(#entry > 0, string.format("场景 %s 应有候选", name))
        assert.not_nil(entry[1].provider, string.format("场景 %s 应有 provider", name))
        assert.not_nil(entry[1].model_name, string.format("场景 %s 应有 model_name", name))
      end
    end,

    --- 测试键位配置完整性
    test_keymaps_completeness = function()
      local default_config = require("NeoAI.default_config")
      local config = default_config.get_default_config()

      -- global 键位
      assert.not_nil(config.keymaps.global.open_tree)
      assert.not_nil(config.keymaps.global.open_chat)
      assert.not_nil(config.keymaps.global.close_all)
      assert.not_nil(config.keymaps.global.toggle_ui)

      -- tree 键位
      assert.not_nil(config.keymaps.tree.select)
      assert.not_nil(config.keymaps.tree.new_child)
      assert.not_nil(config.keymaps.tree.new_root)
      assert.not_nil(config.keymaps.tree.delete_dialog)
      assert.not_nil(config.keymaps.tree.delete_branch)

      -- chat 键位
      assert.not_nil(config.keymaps.chat.insert)
      assert.not_nil(config.keymaps.chat.quit)
      assert.not_nil(config.keymaps.chat.send)
      assert.not_nil(config.keymaps.chat.cancel)
    end,

    --- 测试 get_default_config 返回深拷贝
    test_get_default_config_deepcopy = function()
      local default_config = require("NeoAI.default_config")
      local config1 = default_config.get_default_config()
      local config2 = default_config.get_default_config()

      -- 修改 config1 不应影响 config2
      config1.ui.default_ui = "chat"
      assert.equal("tree", config2.ui.default_ui, "深拷贝应互不影响")

      config1.ai.providers.deepseek.api_key = "modified"
      assert.not_equal("modified", config2.ai.providers.deepseek.api_key, "嵌套深拷贝应互不影响")
    end,

    --- 测试日志配置
    test_log_config = function()
      local default_config = require("NeoAI.default_config")
      local config = default_config.get_default_config()

      assert.equal("WARN", config.log.level, "默认日志级别应为 WARN")
      assert.equal(10485760, config.log.max_file_size, "默认最大文件大小应为 10MB")
      assert.equal(5, config.log.max_backups, "默认备份数应为 5")
    end,

    --- 测试测试配置
    test_test_config = function()
      local default_config = require("NeoAI.default_config")
      local config = default_config.get_default_config()

      assert.is_false(config.test.auto_test, "默认 auto_test 应为 false")
      assert.equal(1500, config.test.delay_ms, "默认 delay_ms 应为 1500")
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
