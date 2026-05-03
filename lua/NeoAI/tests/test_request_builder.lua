--- 测试: core/ai/request_builder.lua
--- 测试请求构建器的消息格式化、请求构建、token 估算等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_request_builder ===")

  return test.run_tests({
    --- 测试 format_messages 基本功能
    test_format_messages_basic = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local messages = {
        { role = "user", content = "你好" },
        { role = "assistant", content = "你好！" },
      }

      local result = rb.format_messages(messages)
      assert.is_true(#result >= 2, "应有至少2条消息")
      assert.equal("user", result[1].role)
      assert.equal("你好", result[1].content)
      assert.equal("assistant", result[2].role)
    end,

    --- 测试 format_messages 去重
    test_format_messages_dedup = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local messages = {
        { role = "user", content = "hello" },
        { role = "user", content = "hello" }, -- 重复
        { role = "assistant", content = "hi" },
      }

      local result = rb.format_messages(messages)
      -- 连续重复的 user 消息应被去重
      assert.equal(2, #result, "重复消息应被去重")
    end,

    --- 测试 format_messages 折叠文本过滤
    test_format_messages_fold_filter = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local messages = {
        { role = "user", content = "你好" },
        { role = "assistant", content = "{{{ 工具调用\n内容\n}}}" },
      }

      local result = rb.format_messages(messages)
      -- 折叠文本应被过滤掉
      assert.equal("", result[2].content, "折叠文本应被过滤")
    end,

    --- 测试 format_messages tool 消息处理
    test_format_messages_tool = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local messages = {
        { role = "assistant", content = "让我查一下", tool_calls = {
          { id = "call_1", type = "function", ["function"] = { name = "read_file", arguments = "{}" } },
        }},
        { role = "tool", tool_call_id = "call_1", content = "文件内容" },
      }

      local result = rb.format_messages(messages)
      assert.is_true(#result >= 2)
      -- tool 消息应保留 tool_call_id
      assert.equal("call_1", result[2].tool_call_id)
    end,

    --- 测试 format_messages 空消息
    test_format_messages_empty = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.format_messages(nil)
      assert.is_true(type(result) == "table" and #result == 0, "nil 应返回空表")

      local result2 = rb.format_messages({})
      assert.is_true(#result2 == 0, "空表应返回空表")
    end,

    --- 测试 build_tool_result_message
    test_build_tool_result_message = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local msg = rb.build_tool_result_message("call_1", "执行成功", "test_tool")
      assert.equal("tool", msg.role)
      assert.equal("call_1", msg.tool_call_id)
      assert.equal("执行成功", msg.content)
      assert.equal("test_tool", msg.name)

      -- 无 tool_call_id
      local msg2 = rb.build_tool_result_message(nil, "result")
      assert.equal("tool", msg2.role)
      assert.not_nil(msg2.tool_call_id, "应自动生成 tool_call_id")
    end,

    --- 测试 add_tool_call_to_history
    test_add_tool_call_to_history = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local messages = { { role = "user", content = "执行工具" } }
      local tool_call = { id = "call_1", type = "function", ["function"] = { name = "test_tool", arguments = "{}" } }

      local result = rb.add_tool_call_to_history(messages, tool_call, "成功")
      assert.is_true(#result >= 3, "应有至少3条消息")
      assert.equal("assistant", result[2].role)
      assert.is_true(#result[2].tool_calls > 0)
      assert.equal("tool", result[3].role)
    end,

    --- 测试 build_request 基本
    test_build_request_basic = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local request = rb.build_request({
        messages = { { role = "user", content = "hello" } },
        options = { model = "gpt-4", stream = true },
        session_id = "session_1",
      })

      assert.not_nil(request, "应返回请求")
      assert.equal("gpt-4", request.model)
      assert.is_true(request.stream)
      assert.not_nil(request.generation_id)
      assert.equal("session_1", request.session_id)
    end,

    --- 测试 build_request 思考模式
    test_build_request_reasoning = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local request = rb.build_request({
        messages = { { role = "user", content = "思考问题" } },
        options = { model = "deepseek-reasoner", reasoning_enabled = true },
      })

      assert.not_nil(request.extra_body, "应包含 extra_body")
      assert.equal("enabled", request.extra_body.thinking.type)
    end,

    --- 测试 build_request 禁用思考模式
    test_build_request_no_reasoning = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local request = rb.build_request({
        messages = { { role = "user", content = "简单问题" } },
        options = { model = "gpt-4", reasoning_enabled = false },
      })

      assert.not_nil(request.extra_body, "应包含 extra_body")
      assert.equal("disabled", request.extra_body.thinking.type)
    end,

    --- 测试 estimate_tokens
    test_estimate_tokens = function()
      local rb = require("NeoAI.core.ai.request_builder")

      assert.equal(0, rb.estimate_tokens(""))
      assert.equal(0, rb.estimate_tokens(nil))
      assert.is_true(rb.estimate_tokens("hello world") > 0)
      assert.is_true(rb.estimate_tokens("你好世界") > 0)
    end,

    --- 测试 estimate_message_tokens
    test_estimate_message_tokens = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local messages = {
        { role = "user", content = "hello" },
        { role = "assistant", content = "world" },
      }

      local tokens = rb.estimate_message_tokens(messages)
      assert.is_true(tokens > 0, "应估算出 token 数")

      -- nil
      assert.equal(0, rb.estimate_message_tokens(nil))
    end,

    --- 测试 estimate_request_tokens
    test_estimate_request_tokens = function()
      local rb = require("NeoAI.core.ai.request_builder")

      local request = {
        messages = { { role = "user", content = "hello" } },
      }

      local tokens = rb.estimate_request_tokens(request)
      assert.is_true(tokens > 0, "应估算出 token 数")

      -- nil
      assert.equal(0, rb.estimate_request_tokens(nil))
    end,

    --- 测试 reset_first_request
    test_reset_first_request = function()
      local rb = require("NeoAI.core.ai.request_builder")
      rb.reset_first_request()
      -- 不应崩溃
    end,

    --- 测试 set_tool_definitions
    test_set_tool_definitions = function()
      local rb = require("NeoAI.core.ai.request_builder")
      rb.set_tool_definitions({
        { type = "function", ["function"] = { name = "test_tool" } },
      })
      -- 不应崩溃
    end,

    --- 测试 format_messages 占位修复
    test_format_messages_placeholder = function()
      local rb = require("NeoAI.core.ai.request_builder")

      -- tool 消息的 tool_call_id 没有对应的 assistant tool_calls
      -- 且没有 tool_call_id 时，应转为 user 消息
      local messages = {
        { role = "tool", content = "无 tool_call_id 的工具结果" },
      }

      local result = rb.format_messages(messages)
      -- 无 tool_call_id 的 tool 消息应转为 user 消息
      assert.equal("user", result[1].role, "无 tool_call_id 的 tool 消息应转为 user")
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
