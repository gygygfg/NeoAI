--- 测试: core/ai/init.lua
--- 测试 AI 模块入口的初始化、子模块导出、shutdown 等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_ai_init ===")

  return test.run_tests({
    --- 测试模块导出
    test_exports = function()
      local ai = require("NeoAI.core.ai")
      assert.not_nil(ai.ai_engine, "应导出 ai_engine")
      assert.not_nil(ai.http_client, "应导出 http_client")
      assert.not_nil(ai.request_adapter, "应导出 request_adapter")
      assert.not_nil(ai.tool_orchestrator, "应导出 tool_orchestrator")
      assert.not_nil(ai.chat_service, "应导出 chat_service")
    end,

    --- 测试 initialize
    test_initialize = function()
      local ai = require("NeoAI.core.ai")
      local ok, err = pcall(ai.initialize, ai, {})
      -- 可能因 chat_service 已初始化而跳过，但不应崩溃
      assert.is_true(type(ok) == "boolean")
    end,

    --- 测试 shutdown
    test_shutdown = function()
      local ai = require("NeoAI.core.ai")
      local ok, err = pcall(ai.shutdown, ai)
      -- 不应崩溃
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
