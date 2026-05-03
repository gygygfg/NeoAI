--- 测试: core/ai/stream_processor.lua
--- 测试流式处理器的创建、数据块处理、工具调用收集、reasoning 节流等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_stream_processor ===")

  return test.run_tests({
    --- 测试 create_processor
    test_create_processor = function()
      local sp = require("NeoAI.core.ai.stream_processor")

      local processor = sp.create_processor("gen_1", "session_1", 1001)
      assert.not_nil(processor, "应创建处理器")
      assert.equal("gen_1", processor.generation_id)
      assert.equal("session_1", processor.session_id)
      assert.equal(1001, processor.window_id)
      assert.equal("", processor.content_buffer)
      assert.equal("", processor.reasoning_buffer)
      assert.is_true(type(processor.tool_calls) == "table")
      assert.is_false(processor.is_finished)
    end,

    --- 测试 process_chunk - 文本内容
    test_process_chunk_content = function()
      local sp = require("NeoAI.core.ai.stream_processor")

      local processor = sp.create_processor("gen_1", "session_1", 1001)

      local data = {
        choices = {
          {
            delta = { content = "Hello" },
          },
        },
      }

      local result = sp.process_chunk(processor, data)
      assert.not_nil(result)
      assert.equal("Hello", result.content)
      assert.equal("Hello", processor.content_buffer)
    end,

    --- 测试 process_chunk - reasoning 内容
    test_process_chunk_reasoning = function()
      local sp = require("NeoAI.core.ai.stream_processor")

      local processor = sp.create_processor("gen_1", "session_1", 1001)

      local data = {
        choices = {
          {
            delta = { reasoning_content = "思考中..." },
          },
        },
      }

      local result = sp.process_chunk(processor, data)
      assert.not_nil(result)
      assert.equal("思考中...", result.reasoning_content)
      assert.equal("思考中...", processor.reasoning_buffer)
    end,

    --- 测试 process_chunk - 工具调用
    test_process_chunk_tool_calls = function()
      local sp = require("NeoAI.core.ai.stream_processor")

      local processor = sp.create_processor("gen_1", "session_1", 1001)

      -- 第一次 chunk：工具调用开始
      local data1 = {
        choices = {
          {
            delta = {
              tool_calls = {
                { index = 0, id = "call_1", type = "function", ["function"] = { name = "read_file", arguments = '{"path"' } },
              },
            },
          },
        },
      }

      local result1 = sp.process_chunk(processor, data1)
      assert.not_nil(result1)
      assert.is_true(#result1.tool_calls > 0, "应有工具调用")

      -- 第二次 chunk：工具调用续流
      local data2 = {
        choices = {
          {
            delta = {
              tool_calls = {
                { index = 0, ["function"] = { arguments = ':"/tmp/test"}' } },
              },
            },
          },
        },
      }

      local result2 = sp.process_chunk(processor, data2)
      assert.not_nil(result2)
      assert.equal('{"path":"/tmp/test"}', processor.tool_calls[1]["function"].arguments)
    end,

    --- 测试 process_chunk - finish_reason
    test_process_chunk_finish = function()
      local sp = require("NeoAI.core.ai.stream_processor")

      local processor = sp.create_processor("gen_1", "session_1", 1001)

      local data = {
        choices = {
          {
            delta = { content = "完成" },
            finish_reason = "stop",
          },
        },
      }

      local result = sp.process_chunk(processor, data)
      assert.is_true(result.is_final, "应标记为最终")
      assert.is_true(processor.is_finished, "处理器应标记为完成")
    end,

    --- 测试 process_chunk - usage
    test_process_chunk_usage = function()
      local sp = require("NeoAI.core.ai.stream_processor")

      local processor = sp.create_processor("gen_1", "session_1", 1001)

      local data = {
        choices = {
          { delta = { content = "done" }, finish_reason = "stop" },
        },
        usage = { prompt_tokens = 10, completion_tokens = 20, total_tokens = 30 },
      }

      local result = sp.process_chunk(processor, data)
      assert.not_nil(result.usage)
      assert.equal(10, result.usage.prompt_tokens)
      assert.equal(20, processor.usage.completion_tokens)
    end,

    --- 测试 process_chunk - 已完成处理器
    test_process_chunk_finished = function()
      local sp = require("NeoAI.core.ai.stream_processor")

      local processor = sp.create_processor("gen_1", "session_1", 1001)
      processor.is_finished = true

      local result = sp.process_chunk(processor, { choices = { { delta = { content = "extra" } } } })
      assert.equal(nil, result, "已完成的处理器应返回 nil")
    end,

    --- 测试 process_chunk - message 级别工具调用
    test_process_chunk_message_tool_calls = function()
      local sp = require("NeoAI.core.ai.stream_processor")

      local processor = sp.create_processor("gen_1", "session_1", 1001)

      local data = {
        choices = {
          {
            message = {
              tool_calls = {
                { index = 0, id = "call_msg", type = "function", ["function"] = { name = "test", arguments = "{}" } },
              },
            },
          },
        },
      }

      local result = sp.process_chunk(processor, data)
      assert.not_nil(result)
      assert.is_true(#result.tool_calls > 0)
    end,

    --- 测试 filter_valid_tool_calls
    test_filter_valid_tool_calls = function()
      local sp = require("NeoAI.core.ai.stream_processor")

      local tool_calls = {
        { ["function"] = { name = "valid_tool", arguments = "{}" } },
        { ["function"] = { name = "", arguments = "{}" } }, -- 空名称
        { ["function"] = { name = "valid_tool2", arguments = "" } }, -- 空参数
        { ["function"] = { name = "valid_tool3", arguments = nil } }, -- nil 参数
      }

      local valid = sp.filter_valid_tool_calls(tool_calls)
      assert.equal(1, #valid, "应只保留 1 个有效工具调用")
      assert.equal("valid_tool", valid[1]["function"].name)
    end,

    --- 测试 filter_valid_tool_calls 空列表
    test_filter_valid_tool_calls_empty = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local valid = sp.filter_valid_tool_calls({})
      assert.is_true(#valid == 0, "空列表应返回空表")
    end,

    --- 测试 push_reasoning_content / clear_reasoning_throttle
    test_reasoning_throttle = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      sp.clear_reasoning_throttle()

      local processor = sp.create_processor("gen_2", "session_2", 1002)

      -- 推送 reasoning 内容（带节流）
      sp.push_reasoning_content("gen_2", "思考", processor, {})
      sp.push_reasoning_content("gen_2", "过程", processor, {})

      -- 清理节流
      sp.clear_reasoning_throttle()
      -- 不应崩溃
    end,

    --- 测试 clear_reasoning_throttle 多次
    test_clear_reasoning_throttle_multiple = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      sp.clear_reasoning_throttle()
      sp.clear_reasoning_throttle() -- 第二次不应崩溃
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
