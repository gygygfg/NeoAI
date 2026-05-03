--- 测试: core/ai/request_adapter.lua
--- 测试请求适配器的注册、转换、响应处理等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_request_adapter ===")

  return test.run_tests({
    --- 测试默认适配器已注册
    test_default_adapters = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local types = ra.get_available_types()
      assert.contains(types, "openai", "应包含 openai 适配器")
      assert.contains(types, "anthropic", "应包含 anthropic 适配器")
      assert.contains(types, "google", "应包含 google 适配器")
    end,

    --- 测试 get_adapter
    test_get_adapter = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local openai = ra.get_adapter("openai")
      assert.not_nil(openai, "应获取到 openai 适配器")
      assert.equal("OpenAI 兼容格式", openai.name)

      local anthropic = ra.get_adapter("anthropic")
      assert.not_nil(anthropic, "应获取到 anthropic 适配器")

      local google = ra.get_adapter("google")
      assert.not_nil(google, "应获取到 google 适配器")

      -- 不存在的适配器
      local missing = ra.get_adapter("nonexistent")
      assert.equal(nil, missing)
    end,

    --- 测试 get_adapter_name
    test_get_adapter_name = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      assert.equal("OpenAI 兼容格式", ra.get_adapter_name("openai"))
      assert.equal("Unknown", ra.get_adapter_name("nonexistent"))
    end,

    --- 测试 OpenAI transform_request
    test_openai_transform_request = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local request = {
        model = "gpt-4",
        messages = { { role = "user", content = "hello" } },
        stream = true,
        extra_body = { thinking = { type = "enabled" } },
      }

      local result = ra.transform_request(request, "openai", {})
      assert.equal("gpt-4", result.model)
      assert.equal("hello", result.messages[1].content)
      -- extra_body 应合并到顶层
      assert.not_nil(result.thinking, "extra_body 应合并到顶层")
      assert.equal("enabled", result.thinking.type)
    end,

    --- 测试 OpenAI transform_response
    test_openai_transform_response = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local response = {
        id = "chatcmpl-123",
        choices = {
          {
            index = 0,
            message = { role = "assistant", content = "Hello!" },
            finish_reason = "stop",
          },
        },
        usage = { prompt_tokens = 10, completion_tokens = 20 },
      }

      local result = ra.transform_response(response, "openai")
      assert.equal(response, result, "OpenAI 响应应原样返回")
    end,

    --- 测试 OpenAI get_headers
    test_openai_get_headers = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local headers = ra.get_headers("sk-test", "openai")
      assert.equal("Bearer sk-test", headers["Authorization"])
      assert.equal("application/json", headers["Content-Type"])
    end,

    --- 测试 Anthropic transform_request
    test_anthropic_transform_request = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local request = {
        model = "claude-sonnet-4-20250514",
        messages = {
          { role = "system", content = "You are a helpful assistant." },
          { role = "user", content = "Hello" },
          { role = "assistant", content = "Hi!" },
        },
        max_tokens = 4096,
        stream = true,
        temperature = 0.7,
      }

      local result = ra.transform_request(request, "anthropic", {})
      assert.equal("claude-sonnet-4-20250514", result.model)
      assert.equal("You are a helpful assistant.", result.system)
      assert.equal(2, #result.messages, "system 消息不应在 messages 中")
      assert.equal("user", result.messages[1].role)
      assert.equal("assistant", result.messages[2].role)
    end,

    --- 测试 Anthropic transform_request 带工具调用
    test_anthropic_transform_request_with_tools = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local request = {
        model = "claude-sonnet-4-20250514",
        messages = {
          { role = "user", content = "Read file" },
          { role = "assistant", content = "Sure", tool_calls = {
            { id = "call_1", type = "function", ["function"] = { name = "read_file", arguments = '{"path":"/tmp/test"}' } },
          }},
          { role = "tool", tool_call_id = "call_1", content = "file content" },
        },
        tools = {
          { type = "function", ["function"] = { name = "read_file", description = "Read a file", parameters = { type = "object", properties = {} } } },
        },
      }

      local result = ra.transform_request(request, "anthropic", {})
      assert.not_nil(result.tools, "应包含工具定义")
      assert.equal("read_file", result.tools[1].name)

      -- 验证 assistant 消息中的 tool_use
      local assistant_msg = result.messages[2]
      assert.equal("assistant", assistant_msg.role)
      assert.is_true(type(assistant_msg.content) == "table", "带工具调用的 assistant 消息 content 应为 table")

      -- 验证 tool 消息转为 tool_result
      local tool_msg = result.messages[3]
      assert.equal("user", tool_msg.role, "tool 消息应转为 user 角色")
      assert.is_true(type(tool_msg.content) == "table", "tool_result content 应为 table")
    end,

    --- 测试 Anthropic transform_response
    test_anthropic_transform_response = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local response = {
        id = "msg_123",
        model = "claude-sonnet-4-20250514",
        stop_reason = "end_turn",
        content = {
          { type = "text", text = "Hello!" },
        },
        usage = { input_tokens = 10, output_tokens = 20 },
      }

      local result = ra.transform_response(response, "anthropic")
      assert.equal("msg_123", result.id)
      assert.equal("chat.completion", result.object)
      assert.equal(1, #result.choices)
      assert.equal("Hello!", result.choices[1].message.content)
      assert.equal("stop", result.choices[1].finish_reason)
      assert.equal(10, result.usage.prompt_tokens)
      assert.equal(20, result.usage.completion_tokens)
    end,

    --- 测试 Anthropic transform_response 带 tool_use
    test_anthropic_transform_response_with_tools = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local response = {
        id = "msg_456",
        model = "claude-sonnet-4-20250514",
        stop_reason = "tool_use",
        content = {
          { type = "text", text = "Let me read that file." },
          { type = "tool_use", id = "toolu_1", name = "read_file", input = { path = "/tmp/test" } },
        },
      }

      local result = ra.transform_response(response, "anthropic")
      assert.equal("tool_calls", result.choices[1].finish_reason)
      assert.equal("Let me read that file.", result.choices[1].message.content)
      assert.is_true(#result.choices[1].message.tool_calls > 0, "应有工具调用")
      assert.equal("read_file", result.choices[1].message.tool_calls[1]["function"].name)
    end,

    --- 测试 Anthropic transform_response 带 thinking
    test_anthropic_transform_response_with_thinking = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local response = {
        id = "msg_789",
        model = "claude-sonnet-4-20250514",
        stop_reason = "end_turn",
        content = {
          { type = "thinking", thinking = "I need to think about this..." },
          { type = "text", text = "Here is my answer." },
        },
      }

      local result = ra.transform_response(response, "anthropic")
      assert.equal("Here is my answer.", result.choices[1].message.content)
      assert.equal("I need to think about this...", result.choices[1].message.reasoning_content)
    end,

    --- 测试 Anthropic get_headers
    test_anthropic_get_headers = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local headers = ra.get_headers("sk-ant-test", "anthropic")
      assert.equal("sk-ant-test", headers["x-api-key"])
      assert.equal("2023-06-01", headers["anthropic-version"])
    end,

    --- 测试 Google transform_request
    test_google_transform_request = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local request = {
        model = "gemini-2.0-flash",
        messages = {
          { role = "system", content = "You are a helpful assistant." },
          { role = "user", content = "Hello" },
        },
        temperature = 0.5,
        max_tokens = 100,
      }

      local result = ra.transform_request(request, "google", {})
      assert.not_nil(result.contents, "应包含 contents")
      assert.not_nil(result.system_instruction, "应包含 system_instruction")
      assert.equal("Hello", result.contents[1].parts[1].text)
      assert.not_nil(result.generation_config, "应包含 generation_config")
      assert.equal(0.5, result.generation_config.temperature)
      assert.equal(100, result.generation_config.max_output_tokens)
    end,

    --- 测试 Google transform_response
    test_google_transform_response = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local response = {
        model = "gemini-2.0-flash",
        candidates = {
          {
            content = {
              parts = {
                { text = "Hello!" },
              },
            },
            finishReason = "STOP",
          },
        },
        usageMetadata = {
          promptTokenCount = 10,
          candidatesTokenCount = 20,
        },
      }

      local result = ra.transform_response(response, "google")
      assert.equal(1, #result.choices)
      assert.equal("Hello!", result.choices[1].message.content)
      assert.equal("stop", result.choices[1].finish_reason)
      assert.equal(10, result.usage.prompt_tokens)
      assert.equal(20, result.usage.completion_tokens)
    end,

    --- 测试 Google transform_response 带 functionCall
    test_google_transform_response_with_function = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local response = {
        model = "gemini-2.0-flash",
        candidates = {
          {
            content = {
              parts = {
                { functionCall = { name = "read_file", args = { path = "/tmp/test" } } },
              },
            },
            finishReason = "FUNCTION_CALL",
          },
        },
      }

      local result = ra.transform_response(response, "google")
      assert.equal("tool_calls", result.choices[1].finish_reason)
      assert.is_true(#result.choices[1].message.tool_calls > 0, "应有工具调用")
      assert.equal("read_file", result.choices[1].message.tool_calls[1]["function"].name)
    end,

    --- 测试 Google get_headers
    test_google_get_headers = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local headers = ra.get_headers("AIza-test", "google")
      assert.equal("AIza-test", headers["x-goog-api-key"])
    end,

    --- 测试 transform_request 回退到 openai
    test_transform_request_fallback = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local request = { model = "test", messages = { { role = "user", content = "hi" } } }
      local result = ra.transform_request(request, "nonexistent_type", {})
      -- 应回退到 openai
      assert.equal("test", result.model)
      assert.equal("hi", result.messages[1].content)
    end,

    --- 测试 transform_response 回退
    test_transform_response_fallback = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      local response = { id = "test" }
      local result = ra.transform_response(response, "nonexistent_type")
      -- 应原样返回
      assert.equal(response, result)
    end,

    --- 测试 get_headers 回退
    test_get_headers_fallback = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local headers = ra.get_headers("sk-test", "nonexistent_type")
      -- 应回退到 Bearer token
      assert.equal("Bearer sk-test", headers["Authorization"])
    end,

    --- 测试 register_adapter
    test_register_adapter = function()
      local ra = require("NeoAI.core.ai.request_adapter")

      ra.register_adapter("custom", {
        name = "Custom Adapter",
        transform_request = function(request) return request end,
        transform_response = function(response) return response end,
        get_headers = function(api_key) return { ["Authorization"] = "Custom " .. api_key } end,
      })

      local adapter = ra.get_adapter("custom")
      assert.not_nil(adapter)
      assert.equal("Custom Adapter", adapter.name)

      local headers = ra.get_headers("test-key", "custom")
      assert.equal("Custom test-key", headers["Authorization"])
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
