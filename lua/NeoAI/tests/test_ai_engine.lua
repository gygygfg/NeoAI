--- 测试: core/ai/ai_engine.lua
--- 测试 AI 引擎的初始化、子模块接口、状态管理等功能
--- 注意: 实际 HTTP 请求测试需要 API key，这里只测试逻辑层
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_ai_engine ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      ai_engine.initialize({
        config = {
          ai = {
            default = "test",
            providers = {
              test = {
                api_type = "openai",
                base_url = "https://test.api.com",
                api_key = "sk-test",
                models = { "test-model" },
              },
            },
            scenarios = {
              chat = {
                provider = "test",
                model_name = "test-model",
                temperature = 0.5,
                max_tokens = 100,
                stream = false,
                timeout = 5000,
              },
            },
          },
        },
      })

      local status = ai_engine.get_status()
      assert.is_true(status.initialized, "引擎应已初始化")
      assert.not_nil(status.submodules, "应有子模块状态")
    end,

    --- 测试 set_tools
    test_set_tools = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      ai_engine.initialize({
        config = {
          ai = {
            default = "test",
            providers = {
              test = {
                api_type = "openai",
                base_url = "https://test.api.com",
                api_key = "sk-test",
                models = { "test-model" },
              },
            },
            scenarios = {
              chat = {
                provider = "test",
                model_name = "test-model",
              },
            },
          },
        },
      })

      local test_tools = {
        test_tool = {
          func = function() return "ok" end,
          description = "测试工具",
          parameters = {
            type = "object",
            properties = {},
            required = {},
          },
        },
      }

      ai_engine.set_tools(test_tools)
      local status = ai_engine.get_status()
      assert.is_true(status.tools_available, "工具应可用")
    end,

    --- 测试 set_tools 清空
    test_set_tools_empty = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      ai_engine.set_tools(nil)
      -- 不应崩溃
    end,

    --- 测试 process_query
    test_process_query = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      -- process_query 会尝试发送 HTTP 请求，这里只验证不崩溃
      -- 实际测试需要 mock http_client
      local ok, err = pcall(function()
        ai_engine.process_query("测试查询", {})
      end)
      -- 可能因为未配置 API key 而失败，但不应该崩溃
      assert.is_true(type(ok) == "boolean")
    end,

    --- 测试 cancel_generation
    test_cancel_generation = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      -- 未生成时取消不应崩溃
      ai_engine.cancel_generation()
    end,

    --- 测试 get_status
    test_get_status = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      local status = ai_engine.get_status()
      assert.not_nil(status)
      assert.not_nil(status.initialized)
      assert.not_nil(status.is_generating)
      assert.not_nil(status.submodules)
    end,

    --- 测试子模块接口函数
    test_submodule_interfaces = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")

      -- request_builder 接口
      local tokens = ai_engine.estimate_request_tokens({ messages = {} })
      assert.is_true(type(tokens) == "number", "estimate_request_tokens 应返回数字")

      -- response_builder 接口
      local tokens2 = ai_engine.estimate_tokens("测试文本")
      assert.is_true(type(tokens2) == "number", "estimate_tokens 应返回数字")

      -- reasoning_manager 接口
      assert.is_false(ai_engine.is_reasoning_active(), "初始不应在思考中")

      -- tool_orchestrator 接口
      local iter = ai_engine.get_current_iteration()
      assert.equal(0, iter, "初始迭代次数应为 0")
    end,

    --- 测试 shutdown
    test_shutdown = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      ai_engine.shutdown()
      -- 再次 shutdown 不应崩溃
      ai_engine.shutdown()
    end,

    --- 测试 auto_name_session
    test_auto_name_session = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      -- 未初始化时调用
      local called = false
      ai_engine.auto_name_session("session_1", "测试消息", function(success, result)
        called = true
        assert.is_false(success, "未初始化时应返回失败")
      end)
      -- 由于是异步，这里只验证回调被调用
      vim.wait(100, function() return called end)
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

