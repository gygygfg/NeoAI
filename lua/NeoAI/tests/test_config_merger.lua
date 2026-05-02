--- 测试: core/config/merger.lua
--- 测试配置合并器的验证、合并、场景候选等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_config_merger ===")

  return test.run_tests({
    --- 测试 process_config 基本功能
    test_process_config_basic = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({
        ui = { default_ui = "chat" },
      })
      assert.not_nil(result, "应返回配置")
      assert.equal("chat", result.ui.default_ui)
      assert.not_nil(result.ai, "AI 配置应保留")
      assert.not_nil(result.keymaps, "键位配置应保留")
    end,

    --- 测试 process_config 空配置
    test_process_config_empty = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config({})
      assert.not_nil(result, "空配置应返回默认配置")
    end,

    --- 测试 process_config nil
    test_process_config_nil = function()
      local merger = require("NeoAI.core.config.merger")
      local result = merger.process_config(nil)
      assert.not_nil(result, "nil 应返回默认配置")
    end,

    --- 测试 _validate_and_clean
    test_validate_and_clean = function()
      local merger = require("NeoAI.core.config.merger")

      -- 无效的 UI 模式
      local cleaned = merger._validate_and_clean({
        ui = { window_mode = "invalid_mode" },
      })
      assert.equal(nil, cleaned.ui.window_mode, "无效模式应被清理")

      -- 有效的 UI 模式
      local cleaned2 = merger._validate_and_clean({
        ui = { window_mode = "float" },
      })
      assert.equal("float", cleaned2.ui.window_mode, "有效模式应保留")
    end,

    --- 测试 _validate_ui_config
    test_validate_ui_config = function()
      local merger = require("NeoAI.core.config.merger")

      -- 无效 default_ui
      local ui = { default_ui = "invalid" }
      merger._validate_ui_config(ui)
      assert.equal(nil, ui.default_ui, "无效 default_ui 应被清理")

      -- 有效 default_ui
      local ui2 = { default_ui = "chat" }
      merger._validate_ui_config(ui2)
      assert.equal("chat", ui2.default_ui)

      -- 无效 window 尺寸
      local ui3 = { window = { width = 5, height = 2 } }
      merger._validate_ui_config(ui3)
      assert.equal(nil, ui3.window.width, "过小的 width 应被清理")
      assert.equal(nil, ui3.window.height, "过小的 height 应被清理")
    end,

    --- 测试 _validate_ai_config
    test_validate_ai_config = function()
      local merger = require("NeoAI.core.config.merger")

      -- 无效 providers
      local ai = { providers = "not_a_table" }
      merger._validate_ai_config(ai)
      assert.equal(nil, ai.providers, "非表 providers 应被清理")

      -- 无效 scenarios
      local ai2 = { scenarios = "not_a_table" }
      merger._validate_ai_config(ai2)
      assert.equal(nil, ai2.scenarios, "非表 scenarios 应被清理")

      -- 无效 scenario 名称
      local ai3 = { scenarios = { invalid_scenario = {} } }
      merger._validate_ai_config(ai3)
      assert.equal(nil, ai3.scenarios.invalid_scenario, "无效场景名应被清理")
    end,

    --- 测试 _validate_keymap_config
    test_validate_keymap_config = function()
      local merger = require("NeoAI.core.config.merger")

      -- 无效上下文
      local km = { invalid_context = { test = { key = "<leader>t" } } }
      merger._validate_keymap_config(km)
      assert.equal(nil, km.invalid_context, "无效上下文应被清理")

      -- 有效上下文
      local km2 = { global = { test = { key = "<leader>t" } } }
      merger._validate_keymap_config(km2)
      assert.not_nil(km2.global)
    end,

    --- 测试 _validate_log_config
    test_validate_log_config = function()
      local merger = require("NeoAI.core.config.merger")

      -- 无效级别
      local log = { level = "INVALID" }
      merger._validate_log_config(log)
      assert.equal(nil, log.level, "无效级别应被清理")

      -- 有效级别
      local log2 = { level = "DEBUG" }
      merger._validate_log_config(log2)
      assert.equal("DEBUG", log2.level)

      -- 无效 max_file_size
      local log3 = { max_file_size = 100 }
      merger._validate_log_config(log3)
      assert.equal(nil, log3.max_file_size, "过小的 max_file_size 应被清理")
    end,

    --- 测试 _merge_with_defaults
    test_merge_with_defaults = function()
      local merger = require("NeoAI.core.config.merger")

      local merged = merger._merge_with_defaults({
        ui = { default_ui = "chat" },
      })
      assert.equal("chat", merged.ui.default_ui, "用户配置应覆盖")
      assert.not_nil(merged.ui.window_mode, "未覆盖的应保留默认")
      assert.not_nil(merged.ai, "AI 配置应保留")
    end,

    --- 测试 get_scenario_candidates
    test_get_scenario_candidates = function()
      local merger = require("NeoAI.core.config.merger")
      local state = require("NeoAI.core.config.state")
      state._test_reset()
      state.initialize({
        ai = {
          providers = {
            test_provider = {
              api_type = "openai",
              base_url = "https://test.api.com",
              api_key = "sk-test",
              models = { "test-model" },
            },
          },
          scenarios = {
            chat = {
              provider = "test_provider",
              model_name = "test-model",
              temperature = 0.5,
            },
          },
        },
      })

      local candidates = merger.get_scenario_candidates("chat")
      assert.is_true(#candidates > 0, "chat 场景应有候选")
      assert.not_nil(candidates[1].base_url, "候选应有 base_url")
      assert.not_nil(candidates[1].api_key, "候选应有 api_key")
    end,

    --- 测试 get_preset
    test_get_preset = function()
      local merger = require("NeoAI.core.config.merger")
      local state = require("NeoAI.core.config.state")
      state._test_reset()
      state.initialize({
        ai = {
          providers = {
            test_provider = {
              api_type = "openai",
              base_url = "https://test.api.com",
              api_key = "sk-test",
            },
          },
          scenarios = {
            chat = {
              provider = "test_provider",
              model_name = "test-model",
            },
          },
        },
      })

      local preset = merger.get_preset("chat")
      assert.not_nil(preset, "应返回预设")
      assert.not_nil(preset.base_url)
      assert.not_nil(preset.api_key)
    end,

    --- 测试 get_available_models
    test_get_available_models = function()
      local merger = require("NeoAI.core.config.merger")
      local state = require("NeoAI.core.config.state")
      state._test_reset()
      state.initialize({
        ai = {
          providers = {
            test_provider = {
              api_type = "openai",
              base_url = "https://test.api.com",
              api_key = "sk-test",
              models = { "model-a", "model-b" },
            },
          },
        },
      })

      local models = merger.get_available_models("chat")
      assert.is_true(#models > 0, "应有可用模型")
      assert.equal("model-a", models[1].model_name)
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
