--- 测试: 配置模块
--- 合并了 test_default_config, test_config_merger, test_state
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
  test._logger.info("\n=== test_config ===")

  local function setup_merger_state()
    local merger = require("NeoAI.core.config.merger")
    merger.set_config({ ai = { providers = { test_provider = { api_type = "openai", base_url = "https://test.api.com", api_key = "sk-test", models = { "test-model" } } }, scenarios = { chat = { provider = "test_provider", model_name = "test-model", temperature = 0.5 } } } })
  end

  return test.run_tests({
    -- ========== default_config ==========
    test_default_config_get = function()
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

    test_default_config_structure = function()
      local config = require("NeoAI.default_config").get_default_config()
      assert.not_nil(config.ai.providers, "应有 providers")
      assert.not_nil(config.ai.scenarios, "应有 scenarios")
      assert.not_nil(config.ai.default, "应有 default")
      assert.not_nil(config.ui.default_ui, "应有 default_ui")
      assert.not_nil(config.ui.window_mode, "应有 window_mode")
      assert.not_nil(config.ui.window, "应有 window")
      assert.not_nil(config.keymaps.global, "应有 global 键位")
      assert.not_nil(config.session.auto_save, "应有 auto_save")
      assert.not_nil(config.tools.enabled, "应有 enabled")
    end,

    test_default_config_values = function()
      local config = require("NeoAI.default_config").get_default_config()
      assert.equal("tree", config.ui.default_ui, "默认 default_ui 应为 tree")
      assert.equal("tab", config.ui.window_mode, "默认 window_mode 应为 tab")
      assert.equal(80, config.ui.window.width, "默认宽度应为 80")
      assert.equal(20, config.ui.window.height, "默认高度应为 20")
      assert.equal("rounded", config.ui.window.border, "默认边框应为 rounded")
    end,

    test_default_config_providers = function()
      local config = require("NeoAI.default_config").get_default_config()
      assert.not_nil(config.ai.providers.deepseek, "应有 deepseek 提供商")
      assert.not_nil(config.ai.providers.openai, "应有 openai 提供商")
      assert.not_nil(config.ai.providers.anthropic, "应有 anthropic 提供商")
      assert.not_nil(config.ai.providers.google, "应有 google 提供商")
      assert.equal("openai", config.ai.providers.deepseek.api_type)
      assert.is_true(#config.ai.providers.deepseek.models > 0, "应有模型列表")
    end,

    test_default_config_scenarios = function()
      local config = require("NeoAI.default_config").get_default_config()
      local scenarios = config.ai.scenarios
      assert.not_nil(scenarios.naming, "应有 naming 场景")
      assert.not_nil(scenarios.chat, "应有 chat 场景")
      assert.not_nil(scenarios.reasoning, "应有 reasoning 场景")
      assert.not_nil(scenarios.coding, "应有 coding 场景")
      assert.not_nil(scenarios.tools, "应有 tools 场景")
      assert.not_nil(scenarios.agent, "应有 agent 场景")
      for name, entry in pairs(scenarios) do
        assert.is_true(type(entry) == "table", string.format("场景 %s 应为表", name))
        assert.is_true(#entry > 0, string.format("场景 %s 应有候选", name))
        assert.not_nil(entry[1].provider, string.format("场景 %s 应有 provider", name))
        assert.not_nil(entry[1].model_name, string.format("场景 %s 应有 model_name", name))
      end
    end,

    test_default_config_deepcopy = function()
      local default_config = require("NeoAI.default_config")
      local config1 = default_config.get_default_config()
      local config2 = default_config.get_default_config()
      config1.ui.default_ui = "chat"
      assert.equal("tree", config2.ui.default_ui, "深拷贝应互不影响")
      config1.ai.providers.deepseek.api_key = "modified"
      assert.not_equal("modified", config2.ai.providers.deepseek.api_key, "嵌套深拷贝应互不影响")
    end,

    test_default_config_log = function()
      local config = require("NeoAI.default_config").get_default_config()
      assert.equal("WARN", config.log.level, "默认日志级别应为 WARN")
      assert.equal(10485760, config.log.max_file_size, "默认最大文件大小应为 10MB")
      assert.equal(5, config.log.max_backups, "默认备份数应为 5")
    end,

    -- ========== state（协程上下文） ==========
    test_state_reset = function()
      local state = require("NeoAI.core.config.state")
      state._test_reset()
      -- 重置后 get_shared 应返回空表
      local shared = state.get_shared()
      assert.not_nil(shared, "get_shared 应返回表")
    end,

    -- ========== merger ==========
    test_merger_process_config_basic = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({ ui = { default_ui = "chat" } })
      assert.not_nil(result, "应返回配置")
      assert.equal("chat", result.ui.default_ui)
      assert.not_nil(result.ai, "AI 配置应保留")
      assert.not_nil(result.keymaps, "键位配置应保留")
    end,

    test_merger_process_config_empty = function()
      local merger = require("NeoAI.core.config.merger")
      assert.not_nil(merger.process_config({}), "空配置应返回默认配置")
      assert.not_nil(merger.process_config(nil), "nil 应返回默认配置")
    end,

    test_merger_partial_override = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({ ui = { default_ui = "chat" } })
      assert.equal("chat", result.ui.default_ui, "用户配置应覆盖 default_ui")
      assert.equal("tab", result.ui.window_mode, "未覆盖的 window_mode 应保留默认值")
      assert.equal(80, result.ui.window.width, "未覆盖的 window.width 应保留默认值")
    end,

    test_merger_invalid_type_uses_default = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({ ui = { default_ui = 123 }, session = { max_history_per_session = "invalid" } })
      assert.equal("tree", result.ui.default_ui, "无效类型应使用默认值")
      assert.equal(1000, result.session.max_history_per_session, "无效类型应使用默认值")
    end,

    test_merger_invalid_enum_uses_default = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({ ui = { default_ui = "invalid_ui", window_mode = "invalid_mode" } })
      assert.equal("tree", result.ui.default_ui, "无效枚举值应使用默认值")
      assert.equal("tab", result.ui.window_mode, "无效枚举值应使用默认值")
    end,

    test_merger_numeric_min_validation = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({ ui = { window = { width = 5, height = 2 } }, session = { max_history_per_session = 0 } })
      assert.equal(80, result.ui.window.width, "过小的 width 应使用默认值")
      assert.equal(20, result.ui.window.height, "过小的 height 应使用默认值")
      assert.equal(1000, result.session.max_history_per_session, "过小的 max_history_per_session 应使用默认值")
    end,

    test_merger_log_level_validation = function()
      local merger = require("NeoAI.core.config.merger")
      assert.equal("WARN", merger.process_config({ log = { level = "INVALID" } }).log.level, "无效日志级别应使用默认值")
      assert.equal("WARN", merger.process_config({ log = { level = "debug" } }).log.level, "小写日志级别应使用默认值")
    end,

    test_merger_unknown_field_ignored = function()
      local merger = require("NeoAI.core.config.merger")
      assert.equal(nil, merger.process_config({ ui = { non_existent_field = "test" } }).ui.non_existent_field, "未知字段不应被合并")
    end,

    test_merger_providers_free_form = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({ ai = { providers = { custom_provider = { api_type = "openai", base_url = "https://custom.api.com", api_key = "sk-custom", models = { "custom-model" } } } } })
      assert.not_nil(result.ai.providers.custom_provider, "自定义 provider 应被保留")
      assert.equal("sk-custom", result.ai.providers.custom_provider.api_key)
      assert.not_nil(result.ai.providers.deepseek, "默认 provider 应保留")
    end,

    test_merger_scenarios_free_form = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({ ai = { scenarios = { chat = { provider = "deepseek", model_name = "deepseek-v4-flash", temperature = 0.5 } } } })
      assert.equal("deepseek-v4-flash", result.ai.scenarios.chat.model_name)
    end,

    test_merger_keymaps_free_form = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({ keymaps = { global = { custom_action = { key = "<leader>xx", desc = "自定义动作" } } } })
      assert.not_nil(result.keymaps.global.custom_action, "自定义键位应被保留")
      assert.not_nil(result.keymaps.global.open_tree, "默认键位应保留")
    end,

    test_merger_get_scenario_candidates = function()
      setup_merger_state()
      local merger = require("NeoAI.core.config.merger")
      local candidates = merger.get_scenario_candidates("chat")
      assert.is_true(#candidates > 0, "chat 场景应有候选")
      assert.not_nil(candidates[1].base_url, "候选应有 base_url")
    end,

    test_merger_get_preset = function()
      setup_merger_state()
      local merger = require("NeoAI.core.config.merger")
      local preset = merger.get_preset("chat")
      assert.not_nil(preset, "应返回预设")
      assert.not_nil(preset.base_url)
    end,

    test_merger_get_available_models = function()
      setup_merger_state()
      local merger = require("NeoAI.core.config.merger")
      local models = merger.get_available_models("chat")
      assert.is_true(#models > 0, "应有可用模型")
      assert.equal("test-model", models[1].model_name)
    end,

    test_merger_multiple_errors = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({ ui = { default_ui = "invalid", window_mode = "also_invalid", window = { width = 1, height = 1 } }, session = { max_history_per_session = -5 }, log = { level = "NONEXISTENT" } })
      assert.equal("tree", result.ui.default_ui)
      assert.equal("tab", result.ui.window_mode)
      assert.equal(80, result.ui.window.width)
      assert.equal(20, result.ui.window.height)
      assert.equal(1000, result.session.max_history_per_session)
      assert.equal("WARN", result.log.level)
    end,
  })
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
