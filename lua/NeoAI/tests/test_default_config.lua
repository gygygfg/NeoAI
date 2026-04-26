--- 测试: default_config.lua
--- 测试配置的初始化、验证、合并、获取场景候选等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_default_config ===")

  return test.run_tests({
    --- 测试 initialize 和 get_all
    test_initialize_and_get_all = function()
      local default_config = require("NeoAI.default_config")
      default_config.initialize()
      local all = default_config.get_all()
      assert.not_nil(all, "get_all() 应返回配置")
      assert.has_key(all, "ai")
      assert.has_key(all, "ui")
      assert.has_key(all, "session")
      assert.has_key(all, "keymaps")
      assert.has_key(all, "tools")
    end,

    --- 测试 get 和 set
    test_get_and_set = function()
      local default_config = require("NeoAI.default_config")
      default_config.reset()
      default_config.initialize()

      -- get 默认值
      local val = default_config.get("ui.default_ui")
      assert.equal("tree", val, "默认 default_ui 应为 tree")

      -- set 并 get
      default_config.set("ui.default_ui", "chat")
      assert.equal("chat", default_config.get("ui.default_ui"), "set 后应返回 chat")

      -- 不存在的键返回默认值
      assert.equal(nil, default_config.get("nonexistent.key"))
      assert.equal("fallback", default_config.get("nonexistent.key", "fallback"))

      -- 重置
      default_config.reset()
      assert.equal("tree", default_config.get("ui.default_ui"), "reset 后应恢复默认")
    end,

    --- 测试 set_many
    test_set_many = function()
      local default_config = require("NeoAI.default_config")
      default_config.reset()
      default_config.initialize()
      default_config.set_many({
        ["ui.default_ui"] = "chat",
        ["ui.window_mode"] = "float",
        ["session.auto_save"] = false,
      })
      assert.equal("chat", default_config.get("ui.default_ui"))
      assert.equal("float", default_config.get("ui.window_mode"))
      assert.equal(false, default_config.get("session.auto_save"))
      default_config.reset()
    end,

    --- 测试 validate
    test_validate = function()
      local default_config = require("NeoAI.default_config")
      default_config.initialize()
      local valid, msg = default_config.validate()
      assert.is_true(valid, "默认配置应通过验证: " .. tostring(msg))
    end,

    --- 测试 process_config
    test_process_config = function()
      local default_config = require("NeoAI.default_config")
      -- 重置状态
      default_config.reset()

      local result = default_config.process_config({
        ui = { default_ui = "chat" },
      })
      assert.equal("chat", result.ui.default_ui, "process_config 应合并用户配置")
      assert.equal("tab", result.ui.window_mode, "未覆盖的字段应保留默认值")
    end,

    --- 测试 get_scenario_candidates
    test_get_scenario_candidates = function()
      local default_config = require("NeoAI.default_config")
      default_config.initialize()

      local candidates = default_config.get_scenario_candidates("chat")
      assert.is_true(#candidates > 0, "chat 场景应有候选")
      assert.not_nil(candidates[1].base_url, "候选应有 base_url")
      assert.not_nil(candidates[1].api_key, "候选应有 api_key")
      assert.not_nil(candidates[1].model_name, "候选应有 model_name")
    end,

    --- 测试 get_preset
    test_get_preset = function()
      local default_config = require("NeoAI.default_config")
      default_config.initialize()

      local preset = default_config.get_preset("chat")
      assert.not_nil(preset, "get_preset 应返回配置")
      assert.not_nil(preset.base_url)
      assert.not_nil(preset.api_key)
    end,

    --- 测试 get_available_scenarios
    test_get_available_scenarios = function()
      local default_config = require("NeoAI.default_config")
      default_config.initialize()

      local scenarios = default_config.get_available_scenarios()
      assert.is_true(#scenarios > 0, "应有可用场景")
      -- 验证排序: chat 应在第一位
      assert.equal("chat", scenarios[1].name, "chat 场景应在第一位")
    end,

    --- 测试 get_available_models
    test_get_available_models = function()
      local default_config = require("NeoAI.default_config")
      default_config.initialize()

      local models = default_config.get_available_models("chat")
      -- 注意: 如果没有设置 API key，可能返回空
      -- 这里只验证函数不崩溃
      assert.is_true(type(models) == "table", "应返回表")
    end,

    --- 测试 get_summary
    test_get_summary = function()
      local default_config = require("NeoAI.default_config")
      default_config.initialize()

      local summary = default_config.get_summary()
      assert.is_true(type(summary) == "string", "摘要应为字符串")
      assert.is_true(#summary > 0, "摘要不应为空")
    end,

    --- 测试 is_complete
    test_is_complete = function()
      local default_config = require("NeoAI.default_config")
      default_config.initialize()

      assert.is_true(default_config.is_complete(), "默认配置应完整")
    end,

    --- 测试 export 和 import
    test_export_import = function()
      local default_config = require("NeoAI.default_config")
      default_config.reset()
      default_config.initialize()

      local filepath = "/tmp/neoai_test_config.json"
      local ok, msg = default_config.export(filepath)
      assert.is_true(ok, "导出应成功: " .. tostring(msg))

      -- 修改配置
      default_config.set("ui.default_ui", "chat")
      assert.equal("chat", default_config.get("ui.default_ui"))

      -- 导入恢复
      local ok2, msg2 = default_config.import(filepath)
      assert.is_true(ok2, "导入应成功: " .. tostring(msg2))
      assert.equal("tree", default_config.get("ui.default_ui"), "导入后应恢复")

      -- 清理
      os.remove(filepath)
    end,

    --- 测试 _validate_and_clean
    test_validate_and_clean = function()
      local default_config = require("NeoAI.default_config")

      -- 无效的 UI 模式
      local cleaned = default_config._validate_and_clean({
        ui = { window_mode = "invalid_mode" },
      })
      assert.equal(nil, cleaned.ui.window_mode, "无效模式应被清理")

      -- 有效的 UI 模式
      local cleaned2 = default_config._validate_and_clean({
        ui = { window_mode = "float" },
      })
      assert.equal("float", cleaned2.ui.window_mode, "有效模式应保留")
    end,

    --- 测试 _merge_with_defaults
    test_merge_with_defaults = function()
      local default_config = require("NeoAI.default_config")

      local merged = default_config._merge_with_defaults({
        ui = { default_ui = "chat" },
      })
      assert.equal("chat", merged.ui.default_ui, "用户配置应覆盖")
      assert.equal("tab", merged.ui.window_mode, "未覆盖的应保留默认")
      assert.not_nil(merged.ai, "AI 配置应保留")
    end,

    --- 测试 get_default_config
    test_get_default_config = function()
      local default_config = require("NeoAI.default_config")
      local defaults = default_config.get_default_config()
      assert.not_nil(defaults)
      assert.has_key(defaults, "ai")
      assert.has_key(defaults, "ui")
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

