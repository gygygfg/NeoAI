--- 测试: AI 核心模块 (Part 2)
--- 合并了 test_tool_orchestrator, test_request_adapter, test_request_builder, test_stream_processor
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_ai_core (cont.) ===")

  return test.run_tests({
    -- ========== tool_orchestrator ==========
    test_orchestrator_initialize = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc._test_reset()
      orc.initialize({})
      orc.initialize({})
    end,

    test_orchestrator_register_unregister_session = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_session_1", 1001)
      orc.register_session("test_session_2", 1002)
      orc.register_session("test_session_1", 1001)
      assert.is_true(#orc.get_all_session_ids() >= 2, "应有至少2个会话")
      orc.unregister_session("test_session_1")
      orc.unregister_session("test_session_2")
    end,

    test_orchestrator_get_session_state = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_state", 2001)
      local ss = orc.get_session_state("test_state")
      assert.not_nil(ss, "应返回会话状态")
      assert.equal("test_state", ss.session_id)
      assert.equal(2001, ss.window_id)
      assert.equal(nil, orc.get_session_state("nonexistent"))
      orc.unregister_session("test_state")
    end,

    test_orchestrator_set_get_tools = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.set_tools({ test_tool = { func = function() end } })
      assert.not_nil(orc.get_tools().test_tool)
    end,

    test_orchestrator_iteration = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_iter", 3001)
      assert.equal(0, orc.get_current_iteration("test_iter"), "初始迭代次数应为0")
      orc.reset_iteration("test_iter")
      orc.unregister_session("test_iter")
    end,

    test_orchestrator_executing = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_exec", 5001)
      assert.is_false(orc.is_executing("test_exec"))
      orc.unregister_session("test_exec")
    end,

    test_orchestrator_stop_requested = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_stop", 6001)
      assert.is_false(orc.is_stop_requested("test_stop"))
      orc.request_stop("test_stop")
      assert.is_true(orc.is_stop_requested("test_stop"))
      orc.reset_stop_requested("test_stop")
      assert.is_false(orc.is_stop_requested("test_stop"))
      orc.unregister_session("test_stop")
    end,

    test_orchestrator_request_stop_all = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_all_1", 7001)
      orc.register_session("test_all_2", 7002)
      orc.request_stop()
      assert.is_true(orc.is_stop_requested("test_all_1"))
      assert.is_true(orc.is_stop_requested("test_all_2"))
      orc.reset_stop_requested()
      orc.unregister_session("test_all_1")
      orc.unregister_session("test_all_2")
    end,

    test_orchestrator_start_async_loop = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_loop", 8001)
      local ok, err = pcall(orc.start_async_loop, orc, { session_id = "test_loop", window_id = 8001, generation_id = "gen_1", tool_calls = {}, messages = {}, options = {} })
      orc.unregister_session("test_loop")
    end,

    test_orchestrator_on_generation_complete = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      local ok, err = pcall(orc.on_generation_complete, orc, { generation_id = "gen_test", session_id = "session_test", tool_calls = {}, content = "", usage = {} })
    end,

    test_orchestrator_set_shutting_down = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      local sf = require("NeoAI.core.shutdown_flag")
      sf.reset()
      orc.set_shutting_down()
      assert.is_true(sf.is_set())
      sf.reset()
    end,

    test_orchestrator_cleanup_all = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_cleanup", 9001)
      orc.cleanup_all()
      assert.is_true(#orc.get_all_session_ids() == 0, "清理后应无会话")
    end,

    test_orchestrator_shutdown = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.shutdown()
      orc.initialize({})
    end,

    -- ========== request_adapter ==========
    test_adapter_default_adapters = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local types = ra.get_available_types()
      assert.contains(types, "openai", "应包含 openai 适配器")
      assert.contains(types, "anthropic", "应包含 anthropic 适配器")
      assert.contains(types, "google", "应包含 google 适配器")
    end,

    test_adapter_get_adapter = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      assert.not_nil(ra.get_adapter("openai"), "应获取到 openai 适配器")
      assert.not_nil(ra.get_adapter("anthropic"), "应获取到 anthropic 适配器")
      assert.not_nil(ra.get_adapter("google"), "应获取到 google 适配器")
      assert.equal(nil, ra.get_adapter("nonexistent"))
    end,

    test_adapter_get_adapter_name = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      assert.equal("OpenAI 兼容格式", ra.get_adapter_name("openai"))
      assert.equal("Unknown", ra.get_adapter_name("nonexistent"))
    end,

    test_adapter_openai_transform_request = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_request({ model = "gpt-4", messages = { { role = "user", content = "hello" } }, stream = true, extra_body = { thinking = { type = "enabled" } } }, "openai", {})
      assert.equal("gpt-4", result.model)
      assert.equal("enabled", result.thinking.type)
    end,

    test_adapter_openai_transform_response = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local response = { id = "chatcmpl-123", choices = { { index = 0, message = { role = "assistant", content = "Hello!" }, finish_reason = "stop" } }, usage = { prompt_tokens = 10, completion_tokens = 20 } }
      assert.equal(response, ra.transform_response(response, "openai"))
    end,

    test_adapter_openai_get_headers = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local headers = ra.get_headers("sk-test", "openai")
      assert.equal("Bearer sk-test", headers["Authorization"])
      assert.equal("application/json", headers["Content-Type"])
    end,

    test_adapter_anthropic_transform_request = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_request({ model = "claude-sonnet-4-20250514", messages = { { role = "system", content = "You are a helpful assistant." }, { role = "user", content = "Hello" }, { role = "assistant", content = "Hi!" } }, max_tokens = 4096, stream = true, temperature = 0.7 }, "anthropic", {})
      assert.equal("claude-sonnet-4-20250514", result.model)
      assert.equal("You are a helpful assistant.", result.system)
      assert.equal(2, #result.messages)
    end,

    test_adapter_anthropic_transform_request_with_tools = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_request({ model = "claude-sonnet-4-20250514", messages = { { role = "user", content = "Read file" }, { role = "assistant", content = "Sure", tool_calls = { { id = "call_1", type = "function", ["function"] = { name = "read_file", arguments = '{"path":"/tmp/test"}' } } } }, { role = "tool", tool_call_id = "call_1", content = "file content" } }, tools = { { type = "function", ["function"] = { name = "read_file", description = "Read a file", parameters = { type = "object", properties = {} } } } } }, "anthropic", {})
      assert.not_nil(result.tools, "应包含工具定义")
      assert.equal("read_file", result.tools[1].name)
    end,

    test_adapter_anthropic_transform_response = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_response({ id = "msg_123", model = "claude-sonnet-4-20250514", stop_reason = "end_turn", content = { { type = "text", text = "Hello!" } }, usage = { input_tokens = 10, output_tokens = 20 } }, "anthropic")
      assert.equal("Hello!", result.choices[1].message.content)
      assert.equal(10, result.usage.prompt_tokens)
    end,

    test_adapter_anthropic_transform_response_with_tools = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_response({ id = "msg_456", model = "claude-sonnet-4-20250514", stop_reason = "tool_use", content = { { type = "text", text = "Let me read that file." }, { type = "tool_use", id = "toolu_1", name = "read_file", input = { path = "/tmp/test" } } } }, "anthropic")
      assert.equal("tool_calls", result.choices[1].finish_reason)
      assert.is_true(#result.choices[1].message.tool_calls > 0)
    end,

    test_adapter_anthropic_transform_response_with_thinking = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_response({ id = "msg_789", model = "claude-sonnet-4-20250514", stop_reason = "end_turn", content = { { type = "thinking", thinking = "I need to think about this..." }, { type = "text", text = "Here is my answer." } } }, "anthropic")
      assert.equal("Here is my answer.", result.choices[1].message.content)
      assert.equal("I need to think about this...", result.choices[1].message.reasoning_content)
    end,

    test_adapter_anthropic_get_headers = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local headers = ra.get_headers("sk-ant-test", "anthropic")
      assert.equal("sk-ant-test", headers["x-api-key"])
      assert.equal("2023-06-01", headers["anthropic-version"])
    end,

    test_adapter_google_transform_request = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_request({ model = "gemini-2.0-flash", messages = { { role = "system", content = "You are a helpful assistant." }, { role = "user", content = "Hello" } }, temperature = 0.5, max_tokens = 100 }, "google", {})
      assert.not_nil(result.contents)
      assert.not_nil(result.system_instruction)
      assert.not_nil(result.generation_config)
    end,

    test_adapter_google_transform_response = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_response({ model = "gemini-2.0-flash", candidates = { { content = { parts = { { text = "Hello!" } } }, finishReason = "STOP" } }, usageMetadata = { promptTokenCount = 10, candidatesTokenCount = 20 } }, "google")
      assert.equal("Hello!", result.choices[1].message.content)
      assert.equal(10, result.usage.prompt_tokens)
    end,

    test_adapter_google_transform_response_with_function = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_response({ model = "gemini-2.0-flash", candidates = { { content = { parts = { { functionCall = { name = "read_file", args = { path = "/tmp/test" } } } } }, finishReason = "FUNCTION_CALL" } } }, "google")
      assert.equal("tool_calls", result.choices[1].finish_reason)
      assert.is_true(#result.choices[1].message.tool_calls > 0)
    end,

    test_adapter_google_get_headers = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local headers = ra.get_headers("AIza-test", "google")
      assert.equal("AIza-test", headers["x-goog-api-key"])
    end,

    test_adapter_fallback = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local request = { model = "test", messages = { { role = "user", content = "hi" } } }
      assert.equal("test", ra.transform_request(request, "nonexistent_type", {}).model)
      local response = { id = "test" }
      assert.equal(response, ra.transform_response(response, "nonexistent_type"))
      assert.equal("Bearer sk-test", ra.get_headers("sk-test", "nonexistent_type")["Authorization"])
    end,

    test_adapter_register_adapter = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      ra.register_adapter("custom", { name = "Custom Adapter", transform_request = function(request) return request end, transform_response = function(response) return response end, get_headers = function(api_key) return { ["Authorization"] = "Custom " .. api_key } end })
      assert.equal("Custom Adapter", ra.get_adapter("custom").name)
      assert.equal("Custom test-key", ra.get_headers("test-key", "custom")["Authorization"])
    end,

    -- ========== request_builder ==========
    test_builder_format_messages_basic = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.format_messages({ { role = "user", content = "你好" }, { role = "assistant", content = "你好！" } })
      assert.is_true(#result >= 2)
      assert.equal("user", result[1].role)
    end,

    test_builder_format_messages_dedup = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.format_messages({ { role = "user", content = "hello" }, { role = "user", content = "hello" }, { role = "assistant", content = "hi" } })
      assert.equal(2, #result, "重复消息应被去重")
    end,

    test_builder_format_messages_fold_filter = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.format_messages({ { role = "user", content = "你好" }, { role = "assistant", content = "{{{ 工具调用\n内容\n}}}" } })
      assert.equal("", result[2].content, "折叠文本应被过滤")
    end,

    test_builder_format_messages_tool = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.format_messages({ { role = "assistant", content = "让我查一下", tool_calls = { { id = "call_1", type = "function", ["function"] = { name = "read_file", arguments = "{}" } } } }, { role = "tool", tool_call_id = "call_1", content = "文件内容" } })
      assert.is_true(#result >= 2)
    end,

    test_builder_format_messages_empty = function()
      local rb = require("NeoAI.core.ai.request_builder")
      assert.is_true(#rb.format_messages(nil) == 0, "nil 应返回空表")
      assert.is_true(#rb.format_messages({}) == 0, "空表应返回空表")
    end,

    test_builder_build_tool_result_message = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local msg = rb.build_tool_result_message("call_1", "执行成功", "test_tool")
      assert.equal("tool", msg.role)
      assert.equal("call_1", msg.tool_call_id)
      local msg2 = rb.build_tool_result_message(nil, "result")
      assert.not_nil(msg2.tool_call_id, "应自动生成 tool_call_id")
    end,

    test_builder_add_tool_call_to_history = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.add_tool_call_to_history({ { role = "user", content = "执行工具" } }, { id = "call_1", type = "function", ["function"] = { name = "test_tool", arguments = "{}" } }, "成功")
      assert.is_true(#result >= 3)
    end,

    test_builder_build_request_basic = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local request = rb.build_request({ messages = { { role = "user", content = "hello" } }, options = { model = "gpt-4", stream = true }, session_id = "session_1" })
      assert.not_nil(request)
      assert.equal("gpt-4", request.model)
      assert.is_true(request.stream)
    end,

    test_builder_build_request_reasoning = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local request = rb.build_request({ messages = { { role = "user", content = "思考问题" } }, options = { model = "deepseek-reasoner", reasoning_enabled = true } })
      assert.equal("enabled", request.extra_body.thinking.type)
      local request2 = rb.build_request({ messages = { { role = "user", content = "简单问题" } }, options = { model = "gpt-4", reasoning_enabled = false } })
      assert.equal("disabled", request2.extra_body.thinking.type)
    end,

    test_builder_estimate_tokens = function()
      local rb = require("NeoAI.core.ai.request_builder")
      assert.equal(0, rb.estimate_tokens(""))
      assert.equal(0, rb.estimate_tokens(nil))
      assert.is_true(rb.estimate_tokens("hello world") > 0)
    end,

    test_builder_estimate_message_tokens = function()
      local rb = require("NeoAI.core.ai.request_builder")
      assert.is_true(rb.estimate_message_tokens({ { role = "user", content = "hello" }, { role = "assistant", content = "world" } }) > 0)
      assert.equal(0, rb.estimate_message_tokens(nil))
    end,

    test_builder_estimate_request_tokens = function()
      local rb = require("NeoAI.core.ai.request_builder")
      assert.is_true(rb.estimate_request_tokens({ messages = { { role = "user", content = "hello" } } }) > 0)
      assert.equal(0, rb.estimate_request_tokens(nil))
    end,

    test_builder_reset_first_request = function()
      local rb = require("NeoAI.core.ai.request_builder")
      rb.reset_first_request()
      rb.set_tool_definitions({ { type = "function", ["function"] = { name = "test_tool" } } })
    end,

    test_builder_format_messages_placeholder = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.format_messages({ { role = "tool", content = "无 tool_call_id 的工具结果" } })
      assert.equal("user", result[1].role, "无 tool_call_id 的 tool 消息应转为 user")
    end,

    -- ========== stream_processor ==========
    test_stream_create_processor = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      assert.not_nil(processor)
      assert.equal("gen_1", processor.generation_id)
      assert.equal("", processor.content_buffer)
      assert.is_false(processor.is_finished)
    end,

    test_stream_process_chunk_content = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local result = sp.process_chunk(processor, { choices = { { delta = { content = "Hello" } } } })
      assert.equal("Hello", result.content)
      assert.equal("Hello", processor.content_buffer)
    end,

    test_stream_process_chunk_reasoning = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local result = sp.process_chunk(processor, { choices = { { delta = { reasoning_content = "思考中..." } } } })
      assert.equal("思考中...", result.reasoning_content)
    end,

    test_stream_process_chunk_tool_calls = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local chunk1 = { choices = { { delta = { tool_calls = { { index = 0, id = "call_1", type = "function" } } } } } }
      chunk1.choices[1].delta.tool_calls[1]["function"] = { name = "read_file", arguments = '{"path"' }
      sp.process_chunk(processor, chunk1)
      local chunk2 = { choices = { { delta = { tool_calls = { { index = 0 } } } } } }
      chunk2.choices[1].delta.tool_calls[1]["function"] = { arguments = ':"/tmp/test"}' }
      local result2 = sp.process_chunk(processor, chunk2)
      assert.equal('{"path":"/tmp/test"}', processor.tool_calls[1]["function"].arguments)
    end,

    test_stream_process_chunk_finish = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local result = sp.process_chunk(processor, { choices = { { delta = { content = "完成" }, finish_reason = "stop" } } })
      assert.is_true(result.is_final, "应标记为最终")
      assert.is_true(processor.is_finished, "处理器应标记为完成")
    end,

    test_stream_process_chunk_usage = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local result = sp.process_chunk(processor, { choices = { { delta = { content = "done" }, finish_reason = "stop" } }, usage = { prompt_tokens = 10, completion_tokens = 20, total_tokens = 30 } })
      assert.equal(10, result.usage.prompt_tokens)
    end,

    test_stream_process_chunk_finished = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      processor.is_finished = true
      assert.equal(nil, sp.process_chunk(processor, { choices = { { delta = { content = "extra" } } } }), "已完成的处理器应返回 nil")
    end,

    test_stream_process_chunk_message_tool_calls = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local result = sp.process_chunk(processor, { choices = { { message = { tool_calls = { { index = 0, id = "call_msg", type = "function", ["function"] = { name = "test", arguments = "{}" } } } } } } })
      assert.is_true(#result.tool_calls > 0)
    end,

    test_stream_filter_valid_tool_calls = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local valid = sp.filter_valid_tool_calls({ { ["function"] = { name = "valid_tool", arguments = "{}" } }, { ["function"] = { name = "", arguments = "{}" } }, { ["function"] = { name = "valid_tool2", arguments = "" } } })
      assert.equal(1, #valid, "应只保留 1 个有效工具调用")
      assert.is_true(#sp.filter_valid_tool_calls({}) == 0, "空列表应返回空表")
    end,

    test_stream_reasoning_throttle = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      sp.clear_reasoning_throttle()
      local processor = sp.create_processor("gen_2", "session_2", 1002)
      sp.push_reasoning_content("gen_2", "思考", processor, {})
      sp.push_reasoning_content("gen_2", "过程", processor, {})
      sp.clear_reasoning_throttle()
      sp.clear_reasoning_throttle()
    end,
  })
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
