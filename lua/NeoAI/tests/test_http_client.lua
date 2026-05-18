--- 测试: utils/http_utils.lua
--- 测试 HTTP 工具函数的初始化、请求构建、状态管理、特殊字符编解码等功能
--- 注意：实际 HTTP 请求测试需要 API key 和网络连接，这里只测试逻辑层
local M = {}

local test

-- 检测是否为 headless 模式
local function is_headless()
  if vim.env.NVIM_HEADLESS then
    return true
  end
  local uis = vim.api.nvim_list_uis()
  if #uis == 0 then
    return true
  end
  return false
end

-- 安全的等待函数：使用 vim.wait 处理事件循环
-- vim.wait 可以同时处理 vim.schedule 和 vim.defer_fn 回调
-- 注意：vim.uv.run('once') 不能处理 vim.defer_fn 回调
local function safe_wait(timeout_ms, cond)
  return vim.wait(timeout_ms, cond, 1)
end

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  -- 确保 _logger 可用（直接 dofile 运行时可能为 nil）
  if not test._logger then
    local logger = require("NeoAI.utils.logger")
    test._logger = logger
  end
  -- 清除 http_utils 模块缓存，确保加载最新代码
  package.loaded["NeoAI.utils.http_utils"] = nil
  local logger = require("NeoAI.utils.logger")
  logger.initialize({ level = "ERROR" })
  test._logger.info("\n=== test_http_client ===")

  return test.run_tests({

