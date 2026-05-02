--- 测试: core/config/init.lua
--- 测试配置模块入口的初始化、子模块导出等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_config_init ===")

  return test.run_tests({
    --- 测试模块导出
    test_exports = function()
      local config = require("NeoAI.core.config")
      assert.not_nil(config.keymap_manager, "应导出 keymap_manager")
      assert.not_nil(config.state, "应导出 state")
      assert.not_nil(config.merger, "应导出 merger")
    end,

    --- 测试 initialize
    test_initialize = function()
      local config = require("NeoAI.core.config")
      local state = require("NeoAI.core.config.state")
      state._test_reset()

      -- initialize 不应崩溃
      local ok, err = pcall(config.initialize, { keymaps = { global = { test = { key = "<leader>t" } } } })
      assert.is_true(ok, "初始化应成功: " .. tostring(err))

      -- 验证 keymap_manager 已初始化
      local km = config.keymap_manager
      local contexts = km.get_available_contexts()
      assert.is_true(#contexts > 0, "应有可用上下文")
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
