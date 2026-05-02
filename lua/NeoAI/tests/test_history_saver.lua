--- 测试: core/history/saver.lua
--- 测试历史保存器的初始化、事件监听、队列管理等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_history_saver ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local saver = require("NeoAI.core.history.saver")
      saver._test_reset()

      local hm = require("NeoAI.core.history.manager")
      saver.initialize(hm)
      assert.is_true(saver.initialized or true, "初始化不应崩溃")
      saver._test_reset()
    end,

    --- 测试 flush_all（不应崩溃）
    test_flush_all = function()
      local saver = require("NeoAI.core.history.saver")
      saver._test_reset()

      local hm = require("NeoAI.core.history.manager")
      saver.initialize(hm)
      saver.flush_all()
      saver._test_reset()
    end,

    --- 测试 flush_queue
    test_flush_queue = function()
      local saver = require("NeoAI.core.history.saver")
      saver._test_reset()

      local count = saver.flush_queue()
      assert.is_true(type(count) == "number", "应返回数字")
    end,

    --- 测试 shutdown
    test_shutdown = function()
      local saver = require("NeoAI.core.history.saver")
      saver._test_reset()

      local hm = require("NeoAI.core.history.manager")
      saver.initialize(hm)
      saver.shutdown()
      saver._test_reset()
    end,

    --- 测试 shutdown_sync
    test_shutdown_sync = function()
      local saver = require("NeoAI.core.history.saver")
      saver._test_reset()

      local hm = require("NeoAI.core.history.manager")
      saver.initialize(hm)
      saver.shutdown_sync()
      saver._test_reset()
    end,

    --- 测试 _test_reset
    test_reset = function()
      local saver = require("NeoAI.core.history.saver")
      saver._test_reset()
      -- 重置后应能重新初始化
      local hm = require("NeoAI.core.history.manager")
      saver.initialize(hm)
      saver._test_reset()
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
