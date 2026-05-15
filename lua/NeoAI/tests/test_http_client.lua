--- 测试: utils/http_utils.lua
--- 测试 HTTP 工具函数的初始化、请求构建、状态管理、特殊字符编解码等功能
--- 注意：实际 HTTP 请求测试需要 API key 和网络连接，这里只测试逻辑层
local M = {}

-- 检测是否为 headless 模式
local function is_headless()
  if vim.env.NVIM_HEADLESS then
    return true
  end
  if vim.fn.has("nvim-0.5") == 1 and vim.g.colors_name == nil and vim.o.termguicolors == false then
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

-- 内联断言工具（避免依赖测试框架导致的循环依赖）
local assert = {}
function assert.equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("断言失败: %s\n  期望: %s\n  实际: %s",
      msg or "值不相等", vim.inspect(expected), vim.inspect(actual)))
  end
end
function assert.not_equal(expected, actual, msg)
  if expected == actual then
    error(string.format("断言失败: %s\n  期望不等于: %s", msg or "值不应相等", vim.inspect(expected)))
  end
end
function assert.is_true(value, msg)
  if not value then
    error(string.format("断言失败: %s\n  期望为真, 实际为假", msg or "值应为真"))
  end
end
function assert.is_false(value, msg)
  if value then
    error(string.format("断言失败: %s\n  期望为假, 实际为真", msg or "值应为假"))
  end
end
function assert.not_nil(value, msg)
  if value == nil then
    error(string.format("断言失败: %s\n  值不应为 nil", msg or "值不应为 nil"))
  end
end
function assert.is_nil(value, msg)
  if value ~= nil then
    error(string.format("断言失败: %s\n  期望为 nil, 实际为 %s", msg or "值应为 nil", vim.inspect(value)))
  end
end

--- 运行所有测试
function M.run()
  -- 清除 http_utils 模块缓存，确保加载最新代码
  package.loaded["NeoAI.utils.http_utils"] = nil
  local logger = require("NeoAI.utils.logger")
  logger.initialize({ level = "ERROR" })
  logger.info("\n=== test_http_client ===")

  local tests = {
    --- 测试 initialize
    test_aaa_initialize = function()
      local hc = require("NeoAI.utils.http_utils")
      hc.initialize({ config = {} })
      -- 幂等初始化
      hc.initialize({ config = {} })
    end,

    --- 测试 get_state
    test_get_state = function()
      local hc = require("NeoAI.utils.http_utils")
      local state = hc.get_state()
      assert.not_nil(state, "应返回状态")
      assert.not_nil(state.initialized)
      assert.not_nil(state.active_requests_count)
      assert.is_true(state.initialized, "应已初始化")
    end,

    --- 测试 _sanitize_json_body
    test_sanitize_json_body = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 有效 JSON
      local result = hc.sanitize_json_body('{"key":"value"}')
      assert.equal('{"key":"value"}', result)

      -- 空字符串
      local result2 = hc.sanitize_json_body("")
      assert.equal("", result2)

      -- nil
      local result3 = hc.sanitize_json_body(nil)
      assert.equal(nil, result3)
    end,

    --- 测试 clear_request_dedup
    test_clear_request_dedup = function()
      local hc = require("NeoAI.utils.http_utils")

      -- nil generation_id
      hc.clear_request_dedup(nil)

      -- 有效 generation_id
      hc.clear_request_dedup("test_gen_1")
    end,

    --- 测试 cancel_all_requests
    test_cancel_all_requests = function()
      local hc = require("NeoAI.utils.http_utils")
      hc.cancel_all_requests()
      -- 不应崩溃
    end,

    --- 测试 send_request（无 API key 应返回错误）
    test_send_request_no_key = function()
      local hc = require("NeoAI.utils.http_utils")

      local response, err = hc.send_request({
        request = { model = "test", messages = {} },
        generation_id = "test_gen",
        base_url = "https://test.api.com",
        api_key = "",
        timeout = 5000,
      })

      assert.equal(nil, response, "无 API key 应返回 nil")
      assert.not_nil(err, "应返回错误信息")
    end,

    --- 测试 send_request 无 base_url
    test_send_request_no_url = function()
      local hc = require("NeoAI.utils.http_utils")

      local response, err = hc.send_request({
        request = { model = "test", messages = {} },
        generation_id = "test_gen",
        base_url = "",
        api_key = "sk-test",
        timeout = 5000,
      })

      assert.equal(nil, response, "无 base_url 应返回 nil")
      assert.not_nil(err, "应返回错误信息")
    end,

    --- 测试 send_request_async（无 API key 应返回错误）
    test_send_request_async_no_key = function()
      local hc = require("NeoAI.utils.http_utils")

      local called = false
      local request_id = hc.send_request_async({
        request = { model = "test", messages = {} },
        generation_id = "test_gen_async",
        base_url = "https://test.api.com",
        api_key = "",
        timeout = 5000,
      }, function(response, err)
        called = true
        assert.equal(nil, response)
        assert.not_nil(err)
      end)

      safe_wait(500, function() return called end)
    end,

    --- 测试 send_stream_request（无 API key 应返回错误）
    test_send_stream_request_no_key = function()
      local hc = require("NeoAI.utils.http_utils")
      -- 确保已初始化（headless 模式兼容）
      hc.initialize({ config = {} })

      local request_id, err = hc.send_stream_request({
        request = { model = "test", messages = {}, stream = true },
        generation_id = "test_gen_stream",
        base_url = "https://test.api.com",
        api_key = "",
        timeout = 5000,
      }, function(data) end, function() end, function(err) end)

      assert.equal(nil, request_id)
      assert.not_nil(err)
    end,

    --- 测试 _read_file
    test_read_file = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 不存在的文件
      local content = hc.read_file("/tmp/nonexistent_http_test_file.txt")
      assert.equal(nil, content)

      -- 存在的文件
      local test_path = "/tmp/neoai_http_test.txt"
      local f = io.open(test_path, "w")
      if f then
        f:write("test content")
        f:close()
      end

      local content2 = hc.read_file(test_path)
      assert.equal("test content", content2)

      os.remove(test_path)
    end,

    --- 测试 cancel_request
    test_cancel_request = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 取消不存在的请求不应崩溃
      hc.cancel_request("nonexistent_request_id")
    end,

    --- 测试 shutdown
    test_shutdown = function()
      local hc = require("NeoAI.utils.http_utils")
      hc.shutdown()

      local state = hc.get_state()
      assert.is_false(state.initialized, "shutdown 后应未初始化")

      -- 重新初始化
      hc.initialize({ config = {} })
    end,

    --- 测试 encode_special_chars 编码功能
    test_encode_special_chars = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 1. 普通 ASCII 文本（不含特殊字符，编码后应不变）
      local original = "Hello, World!"
      local encoded = hc.encode_special_chars(original)
      assert.equal(original, encoded, "纯 ASCII 不应被编码")

      -- 2. 包含反斜杠和双引号
      local original2 = "path\\to\\file and \"quoted\" text"
      local encoded2 = hc.encode_special_chars(original2)
      assert.is_true(encoded2:find("%%5C") ~= nil, "反斜杠应编码为 %5C")
      assert.is_true(encoded2:find("%%22") ~= nil, "双引号应编码为 %22")

      -- 3. 控制字符
      local original3 = "text\x00with\x01control\x1Fchars"
      local encoded3 = hc.encode_special_chars(original3)
      assert.is_true(encoded3:find("%%00") ~= nil, "\\x00 应编码为 %00")
      assert.is_true(encoded3:find("%%01") ~= nil, "\\x01 应编码为 %01")
      assert.is_true(encoded3:find("%%1F") ~= nil, "\\x1F 应编码为 %1F")

      -- 4. 换行/回车/制表符应编码为 %0A %0D %09
      local original4 = "line1\nline2\rline3\tindented"
      local encoded4 = hc.encode_special_chars(original4)
      assert.is_true(encoded4:find("%%0A") ~= nil, "\\n 应编码为 %0A")
      assert.is_true(encoded4:find("%%0D") ~= nil, "\\r 应编码为 %0D")
      assert.is_true(encoded4:find("%%09") ~= nil, "\\t 应编码为 %09")

      -- 5. 有效 UTF-8 中文
      local original5 = "你好，世界！"
      local encoded5 = hc.encode_special_chars(original5)
      assert.equal(original5, encoded5, "有效 UTF-8 中文应保留不变")

      -- 6. 混合场景
      local original6 = "path\\to\\file\"with\"ctrl\x00chars\nnewline\ttab\x1Fsep和中文"
      local encoded6 = hc.encode_special_chars(original6)
      assert.is_true(encoded6:find("%%5C") ~= nil, "混合场景中反斜杠应编码")
      assert.is_true(encoded6:find("%%22") ~= nil, "混合场景中双引号应编码")
      assert.is_true(encoded6:find("%%00") ~= nil, "混合场景中 \\x00 应编码")
      assert.is_true(encoded6:find("%%1F") ~= nil, "混合场景中 \\x1F 应编码")
      assert.is_true(encoded6:find("%%0A") ~= nil, "混合场景中 \\n 应编码为 %0A")
      assert.is_true(encoded6:find("%%09") ~= nil, "混合场景中 \\t 应编码为 %09")
      assert.is_true(encoded6:find("和中文") ~= nil, "混合场景中中文应保留")

      -- 7. 空字符串和 nil
      assert.equal("", hc.encode_special_chars(""), "空字符串编码应返回空")
      assert.equal(nil, hc.encode_special_chars(nil), "nil 编码应返回 nil")
    end,

    --- 测试 parse_tool_call_arguments 工具调用参数解析
    test_parse_tool_call_arguments = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 1. 有效工具调用
      local tool_calls = {
        {
          id = "call_1",
          type = "function",
          ["function"] = {
            name = "read_file",
            arguments = '{"filepath":"/tmp/test.txt"}',
          },
        },
      }
      local result = hc.parse_tool_call_arguments(tool_calls)
      assert.equal("table", type(result[1]["function"].arguments), "arguments 应解析为 table")
      assert.equal("/tmp/test.txt", result[1]["function"].arguments.filepath)

      -- 2. 空列表
      assert.is_true(#hc.parse_tool_call_arguments({}) == 0, "空列表应返回空表")
      assert.is_true(#hc.parse_tool_call_arguments(nil) == 0, "nil 应返回空表")
    end,

    --- 测试 parse_response_tool_calls 响应工具调用解析
    test_parse_response_tool_calls = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 1. 带 choices 的响应
      local response = {
        choices = {
          {
            message = {
              tool_calls = {
                {
                  id = "call_1",
                  type = "function",
                  ["function"] = {
                    name = "test_tool",
                    arguments = '{"key":"value"}',
                  },
                },
              },
            },
          },
        },
      }
      local result = hc.parse_response_tool_calls(response)
      assert.equal("table", type(result.choices[1].message.tool_calls[1]["function"].arguments))

      -- 2. 无 choices 的响应
      assert.equal(nil, hc.parse_response_tool_calls(nil))
    end,

    --- 测试 repair_orphan_tool_messages 防御性修复
    test_repair_orphan_tool_messages = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 1. 无孤立消息
      local request = {
        messages = {
          { role = "user", content = "hello" },
        },
      }
      hc.repair_orphan_tool_messages(request)
      assert.equal("user", request.messages[1].role)

      -- 2. 空请求
      hc.repair_orphan_tool_messages({})
      hc.repair_orphan_tool_messages(nil)

      -- 3. 无 tools 定义时不修改
      local request2 = {
        messages = {
          { role = "tool", tool_call_id = "orphan_1", content = "result" },
        },
      }
      hc.repair_orphan_tool_messages(request2)
      assert.equal("tool", request2.messages[1].role, "无 tools 定义时不修改")
    end,

    --- 测试 encode_tool_call_arguments 工具调用参数编码
    test_encode_tool_call_arguments = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 1. 有效参数
      local body = {
        messages = {
          {
            tool_calls = {
              {
                ["function"] = {
                  name = "test_tool",
                  arguments = { key = "value" },
                },
              },
            },
          },
        },
      }
      hc.encode_tool_call_arguments(body)
      assert.equal("string", type(body.messages[1].tool_calls[1]["function"].arguments))

      -- 2. nil 和空表
      hc.encode_tool_call_arguments(nil)
      hc.encode_tool_call_arguments({})
    end,

    --- 测试 create_stream_processor 流式处理器创建
    test_create_stream_processor = function()
      local hc = require("NeoAI.utils.http_utils")
      local processor = hc.create_stream_processor("gen_1", "session_1", 1001)
      assert.not_nil(processor)
      assert.equal("gen_1", processor.generation_id)
      assert.equal("", processor.content_buffer)
      assert.is_false(processor.is_finished)

      -- 带 is_tool_loop 参数
      local processor2 = hc.create_stream_processor("gen_2", "session_2", 1002, true)
      assert.is_true(processor2.is_tool_loop)
    end,

    --- 测试 process_stream_chunk 流式数据块处理
    test_process_stream_chunk = function()
      local hc = require("NeoAI.utils.http_utils")
      local processor = hc.create_stream_processor("gen_1", "session_1", 1001)

      -- 1. 内容块
      local result = hc.process_stream_chunk(processor, { choices = { { delta = { content = "Hello" } } } })
      assert.equal("Hello", result.content)
      assert.equal("Hello", processor.content_buffer)

      -- 2. 已完成处理器
      processor.is_finished = true
      local result2 = hc.process_stream_chunk(processor, { choices = { { delta = { content = "extra" } } } })
      assert.is_nil(result2.content, "已完成处理器应忽略内容")
      processor.is_finished = false

      -- 3. 工具调用块
      local processor2 = hc.create_stream_processor("gen_2", "session_2", 1002)
      local chunk = { choices = { { delta = { tool_calls = { { index = 0, id = "call_1", type = "function", ["function"] = { name = "read_file", arguments = '{"path":"/tmp/test"}' } } } } } } }
      local result3 = hc.process_stream_chunk(processor2, chunk)
      assert.is_true(#result3.tool_calls > 0)

      -- 4. finish_reason
      local result4 = hc.process_stream_chunk(processor2, { choices = { { delta = {}, finish_reason = "stop" } } })
      assert.is_true(result4.is_final)
      assert.is_true(processor2.is_finished)

      -- 5. usage
      local result5 = hc.process_stream_chunk(processor2, { usage = { prompt_tokens = 10, completion_tokens = 20 } })
      assert.equal(10, result5.usage.prompt_tokens)
    end,

    --- 测试 filter_valid_tool_calls 工具调用过滤
    test_filter_valid_tool_calls = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 1. 有效工具调用
      local valid = hc.filter_valid_tool_calls({
        { ["function"] = { name = "valid_tool", arguments = { key = "value" } } },
        { ["function"] = { name = "", arguments = {} } },
        { ["function"] = { name = "valid_tool2", arguments = {} } },
      })
      assert.equal(2, #valid, "应保留 2 个有效工具调用")

      -- 2. 空列表
      assert.is_true(#hc.filter_valid_tool_calls({}) == 0)
    end,

    --- 测试 try_finalize_tool_calls 工具调用最终化
    test_try_finalize_tool_calls = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 1. 完整工具调用
      local processor = hc.create_stream_processor("gen_1", "session_1", 1001)
      processor.tool_calls = {
        {
          id = "call_1",
          type = "function",
          ["function"] = {
            name = "test_tool",
            arguments = '{"key":"value"}',
          },
        },
      }
      local result = hc.try_finalize_tool_calls(processor)
      assert.not_nil(result, "完整工具调用应最终化成功")
      assert.equal("table", type(result[1]["function"].arguments))

      -- 2. 空处理器
      assert.is_nil(hc.try_finalize_tool_calls(hc.create_stream_processor("gen_2", "s", 1002)))

      -- 3. 名称为空的工具调用
      local processor2 = hc.create_stream_processor("gen_3", "s", 1003)
      processor2.tool_calls = {
        { id = "call_2", type = "function", ["function"] = { name = "", arguments = "{}" } },
      }
      assert.is_nil(hc.try_finalize_tool_calls(processor2))
    end,

    --- 测试 reasoning 节流功能
    test_reasoning_throttle = function()
      local hc = require("NeoAI.utils.http_utils")
      hc.clear_reasoning_throttle()
      local processor = hc.create_stream_processor("gen_1", "session_1", 1001)
      hc.push_reasoning_content("gen_1", "思考", processor, {})
      hc.push_reasoning_content("gen_1", "过程", processor, {})
      hc.clear_reasoning_throttle()
      hc.clear_reasoning_throttle()  -- 幂等
    end,

    --- 测试 is_tool_calls_ready
    test_is_tool_calls_ready = function()
      local hc = require("NeoAI.utils.http_utils")
      local processor = hc.create_stream_processor("gen_1", "s", 1001)
      assert.is_false(hc.is_tool_calls_ready(processor))
      processor.is_finished = true
      assert.is_true(hc.is_tool_calls_ready(processor))
      assert.is_false(hc.is_tool_calls_ready(nil))
    end,

    --- 测试 clear_dual_trigger_state
    test_clear_dual_trigger_state = function()
      local hc = require("NeoAI.utils.http_utils")
      local processor = hc.create_stream_processor("gen_1", "s", 1001)
      processor._json_depth = 5
      hc.clear_dual_trigger_state(processor)
      assert.equal(0, processor._json_depth)
      hc.clear_dual_trigger_state(nil)  -- 不应崩溃
    end,

    --- 测试 build_curl_args
    test_build_curl_args = function()
      local hc = require("NeoAI.utils.http_utils")
      local args = hc.build_curl_args({
        url = "https://api.test.com",
        method = "POST",
        headers = { ["Authorization"] = "Bearer test" },
        body = '{"key":"value"}',
      })
      assert.is_true(#args > 0)
      local has_url = false
      for _, a in ipairs(args) do
        if a == "https://api.test.com" then has_url = true; break end
      end
      assert.is_true(has_url, "curl args 应包含 URL")
    end,

    --- 测试 parse_sse_line
    test_parse_sse_line = function()
      local hc = require("NeoAI.utils.http_utils")

      -- 1. 有效 SSE 行
      local data = hc.parse_sse_line("data: {\"key\":\"value\"}")
      assert.not_nil(data)
      assert.equal("value", data.key)

      -- 2. [DONE] 标记
      assert.is_nil(hc.parse_sse_line("data: [DONE]"))

      -- 3. 空行
      assert.is_nil(hc.parse_sse_line(""))
      assert.is_nil(hc.parse_sse_line(nil))
    end,
  }

  local passed, failed = 0, 0
  -- 按名称排序执行，保证顺序一致
  local ordered_names = {}
  for name, _ in pairs(tests) do
    table.insert(ordered_names, name)
  end
  table.sort(ordered_names)
  for _, name in ipairs(ordered_names) do
    local fn = tests[name]
    local ok, err = pcall(fn)
    if ok then
      logger.info(string.format("  ✓ %s", name))
      passed = passed + 1
    else
      logger.error(string.format("  ✗ %s: %s", name, tostring(err)))
      failed = failed + 1
    end
  end
  logger.info(string.format("\n测试结果: %d 通过, %d 失败", passed, failed))
  return { passed = passed, failed = failed }
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
