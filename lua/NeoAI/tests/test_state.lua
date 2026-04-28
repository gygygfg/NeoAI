--- 测试: core/config/state.lua
--- 测试统一状态管理器的初始化、配置获取、重置等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_state ===")

  return test.run_tests({
    --- 测试 initialize 和 is_initialized
    test_initialize = function()
      local state = require("NeoAI.core.config.state")
      state._test_reset()

      assert.is_false(state.is_initialized(), "重置后应未初始化")
      state.initialize({ test_key = "test_value" })
      assert.is_true(state.is_initialized(), "初始化后应返回 true")
    end,

    --- 测试 get_config
    test_get_config = function()
      local state = require("NeoAI.core.config.state")
      state._test_reset()

      state.initialize({ key1 = "val1", key2 = { nested = true } })
      local config = state.get_config()
      assert.equal("val1", config.key1)
      assert.is_true(config.key2.nested)
    end,

    --- 测试 get_config_value（点号路径）
    test_get_config_value = function()
      local state = require("NeoAI.core.config.state")
      state._test_reset()

      state.initialize({
        ai = {
          providers = {
            deepseek = { api_key = "sk-test" },
          },
        },
      })

      local val = state.get_config_value("ai.providers.deepseek.api_key")
      assert.equal("sk-test", val, "点号路径应能获取嵌套值")

      -- 不存在的路径
      local missing = state.get_config_value("ai.providers.nonexistent")
      assert.equal(nil, missing, "不存在的路径应返回 nil")

      -- 带默认值
      local with_default = state.get_config_value("ai.providers.nonexistent", "default")
      assert.equal("default", with_default, "应返回默认值")
    end,

    --- 测试重复初始化
    test_double_initialize = function()
      local state = require("NeoAI.core.config.state")
      state._test_reset()

      state.initialize({ version = 1 })
      state.initialize({ version = 2 }) -- 第二次应被忽略
      local config = state.get_config()
      assert.equal(1, config.version, "第二次初始化应被忽略")
    end,

    --- 测试 _test_reset
    test_reset = function()
      local state = require("NeoAI.core.config.state")
      state._test_reset()

      assert.is_false(state.is_initialized())
      assert.equal(nil, state.get_config())
    end,

    --- 测试 get_config_value 返回完整配置
    test_get_config_value_no_key = function()
      local state = require("NeoAI.core.config.state")
      state._test_reset()

      state.initialize({ foo = "bar" })
      local full = state.get_config_value(nil)
      assert.equal("bar", full.foo, "不传 key 应返回完整配置")
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

