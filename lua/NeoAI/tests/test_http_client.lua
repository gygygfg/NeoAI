--- 测试: core/ai/http_client.lua
--- 测试 HTTP 客户端的初始化、请求构建、状态管理等功能
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

-- 安全的等待函数：使用 vim.uv.run('once') 处理事件循环
local function safe_wait(timeout_ms, cond)
  local deadline = vim.uv.now() + timeout_ms
  while vim.uv.now() < deadline do
    if cond() then
      return true
    end
    vim.uv.run("once")
  end
  return false
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
  -- 清除 http_client 模块缓存，确保加载最新代码
  package.loaded["NeoAI.core.ai.http_client"] = nil
  local logger = require("NeoAI.utils.logger")
  logger.initialize({ level = "ERROR" })
  logger.info("\n=== test_http_client ===")

  local tests = {
    --- 测试 initialize
    test_aaa_initialize = function()
      local hc = require("NeoAI.core.ai.http_client")
      hc.initialize({ config = {} })
      -- 幂等初始化
      hc.initialize({ config = {} })
    end,

    --- 测试 get_state
    test_get_state = function()
      local hc = require("NeoAI.core.ai.http_client")
      local state = hc.get_state()
      assert.not_nil(state, "应返回状态")
      assert.not_nil(state.initialized)
      assert.not_nil(state.active_requests_count)
      assert.is_true(state.initialized, "应已初始化")
    end,

    --- 测试 _sanitize_json_body
    test_sanitize_json_body = function()
      local hc = require("NeoAI.core.ai.http_client")

      -- 有效 JSON
      local result = hc._sanitize_json_body('{"key":"value"}')
      assert.equal('{"key":"value"}', result)

      -- 空字符串
      local result2 = hc._sanitize_json_body("")
      assert.equal("", result2)

      -- nil
      local result3 = hc._sanitize_json_body(nil)
      assert.equal(nil, result3)
    end,

    --- 测试 clear_request_dedup
    test_clear_request_dedup = function()
      local hc = require("NeoAI.core.ai.http_client")

      -- nil generation_id
      hc.clear_request_dedup(nil)

      -- 有效 generation_id
      hc.clear_request_dedup("test_gen_1")
    end,

    --- 测试 cancel_all_requests
    test_cancel_all_requests = function()
      local hc = require("NeoAI.core.ai.http_client")
      hc.cancel_all_requests()
      -- 不应崩溃
    end,

    --- 测试 send_request（无 API key 应返回错误）
    test_send_request_no_key = function()
      local hc = require("NeoAI.core.ai.http_client")

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
      local hc = require("NeoAI.core.ai.http_client")

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
      local hc = require("NeoAI.core.ai.http_client")

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
      local hc = require("NeoAI.core.ai.http_client")
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
      local hc = require("NeoAI.core.ai.http_client")

      -- 不存在的文件
      local content = hc._read_file("/tmp/nonexistent_http_test_file.txt")
      assert.equal(nil, content)

      -- 存在的文件
      local test_path = "/tmp/neoai_http_test.txt"
      local f = io.open(test_path, "w")
      if f then
        f:write("test content")
        f:close()
      end

      local content2 = hc._read_file(test_path)
      assert.equal("test content", content2)

      os.remove(test_path)
    end,

    --- 测试 cancel_request
    test_cancel_request = function()
      local hc = require("NeoAI.core.ai.http_client")

      -- 取消不存在的请求不应崩溃
      hc.cancel_request("nonexistent_request_id")
    end,

    --- 测试 shutdown
    test_shutdown = function()
      local hc = require("NeoAI.core.ai.http_client")
      hc.shutdown()

      local state = hc.get_state()
      assert.is_false(state.initialized, "shutdown 后应未初始化")

      -- 重新初始化
      hc.initialize({ config = {} })
    end,

    --- 测试 _encode_special_chars / _decode_special_chars 编解码一致性
    test_encode_decode_roundtrip = function()
      local hc = require("NeoAI.core.ai.http_client")

      -- 1. 普通 ASCII 文本（不含特殊字符，编码后应不变）
      local original = "Hello, World!"
      local encoded = hc._encode_special_chars(original)
      assert.equal(original, encoded, "纯 ASCII 不应被编码")
      local decoded = hc._decode_special_chars(encoded)
      assert.equal(original, decoded, "编解码往返应一致")

      -- 2. 包含反斜杠和双引号（编码后应变化，但往返应一致）
      -- 注意：在 Lua 长字符串 [[...]] 中，\ 是字面量反斜杠
      local original2 = [[path\to\file and "quoted" text]]
      local encoded2 = hc._encode_special_chars(original2)
      -- 验证反斜杠和双引号被编码
      assert.is_true(encoded2:find("%%5C") ~= nil, "反斜杠应编码为 %5C")
      assert.is_true(encoded2:find("%%22") ~= nil, "双引号应编码为 %22")
      local decoded2 = hc._decode_special_chars(encoded2)
      assert.equal(original2, decoded2, "含 \\ 和 \" 的编解码往返应一致")

      -- 3. 控制字符
      local original3 = "text\x00with\x01control\x1Fchars"
      local encoded3 = hc._encode_special_chars(original3)
      assert.is_true(encoded3:find("%%00") ~= nil, "\\x00 应编码为 %00")
      assert.is_true(encoded3:find("%%01") ~= nil, "\\x01 应编码为 %01")
      assert.is_true(encoded3:find("%%1F") ~= nil, "\\x1F 应编码为 %1F")
      local decoded3 = hc._decode_special_chars(encoded3)
      assert.equal(original3, decoded3, "含控制字符的编解码往返应一致")

      -- 4. 换行/回车/制表符应编码为 %0A %0D %09
      local original4 = "line1\nline2\rline3\tindented"
      local encoded4 = hc._encode_special_chars(original4)
      assert.is_true(encoded4:find("%%0A") ~= nil, "\\n 应编码为 %0A")
      assert.is_true(encoded4:find("%%0D") ~= nil, "\\r 应编码为 %0D")
      assert.is_true(encoded4:find("%%09") ~= nil, "\\t 应编码为 %09")
      local decoded4 = hc._decode_special_chars(encoded4)
      assert.equal(original4, decoded4, "含 \\n\\r\\t 的编解码往返应一致")

      -- 5. 有效 UTF-8 中文
      local original5 = "你好，世界！"
      local encoded5 = hc._encode_special_chars(original5)
      assert.equal(original5, encoded5, "有效 UTF-8 中文应保留不变")
      local decoded5 = hc._decode_special_chars(encoded5)
      assert.equal(original5, decoded5, "中文编解码往返应一致")

      -- 6. 混合场景
      local original6 = "path\\to\\file\"with\"ctrl\x00chars\nnewline\ttab\x1Fsep和中文"
      local encoded6 = hc._encode_special_chars(original6)
      assert.is_true(encoded6:find("%%5C") ~= nil, "混合场景中反斜杠应编码")
      assert.is_true(encoded6:find("%%22") ~= nil, "混合场景中双引号应编码")
      assert.is_true(encoded6:find("%%00") ~= nil, "混合场景中 \\x00 应编码")
      assert.is_true(encoded6:find("%%1F") ~= nil, "混合场景中 \\x1F 应编码")
      assert.is_true(encoded6:find("%%0A") ~= nil, "混合场景中 \\n 应编码为 %0A")
      assert.is_true(encoded6:find("%%09") ~= nil, "混合场景中 \\t 应编码为 %09")
      assert.is_true(encoded6:find("和中文") ~= nil, "混合场景中中文应保留")
      local decoded6 = hc._decode_special_chars(encoded6)
      assert.equal(original6, decoded6, "混合场景编解码往返应一致")

      -- 7. 空字符串和 nil
      assert.equal("", hc._encode_special_chars(""), "空字符串编码应返回空")
      assert.equal(nil, hc._encode_special_chars(nil), "nil 编码应返回 nil")
      assert.equal("", hc._decode_special_chars(""), "空字符串解码应返回空")
      assert.equal(nil, hc._decode_special_chars(nil), "nil 解码应返回 nil")
    end,

    --- 测试 _encode_response_strings 递归编码
    test_encode_response_strings = function()
      local hc = require("NeoAI.core.ai.http_client")

      -- 模拟流式响应结构
      local stream_response = {
        choices = {
          {
            delta = {
              content = "hello \"world\" and path\\to\\file",
              reasoning_content = "思考\x00过程",
              tool_calls = {
                {
                  index = 0,
                  id = "call_1",
                  type = "function",
                  ["function"] = {
                    name = "test_tool",
                    arguments = '{"key":"value\\with\\backslash"}',
                  },
                },
              },
            },
          },
        },
      }

      hc._encode_response_strings(stream_response)

      -- 验证 content 中的双引号和反斜杠被编码
      local content = stream_response.choices[1].delta.content
      assert.is_true(content:find("%%22") ~= nil, "content 中的双引号应编码")
      assert.is_true(content:find("%%5C") ~= nil, "content 中的反斜杠应编码")

      -- 验证 reasoning_content 中的控制字符被编码
      local reasoning = stream_response.choices[1].delta.reasoning_content
      assert.is_true(reasoning:find("%%00") ~= nil, "reasoning 中的 \\x00 应编码")

      -- 验证 tool_calls arguments 中的反斜杠被编码
      local args = stream_response.choices[1].delta.tool_calls[1]["function"].arguments
      assert.is_true(args:find("%%5C") ~= nil, "arguments 中的反斜杠应编码")

      -- 验证解码后还原
      local decoded_content = hc._decode_special_chars(content)
      assert.equal("hello \"world\" and path\\to\\file", decoded_content)

      local decoded_reasoning = hc._decode_special_chars(reasoning)
      assert.equal("思考\x00过程", decoded_reasoning)

      local decoded_args = hc._decode_special_chars(args)
      assert.equal('{"key":"value\\with\\backslash"}', decoded_args)
    end,

    --- 测试完整流程：模拟 API 响应 → 编码 → 存储 → 解码发送 → 解码渲染
    test_full_flow_simulation = function()
      local hc = require("NeoAI.core.ai.http_client")

      -- 1. 模拟 API 原始响应（包含会影响 JSON 的特殊字符）
      local raw_api_response = {
        id = "chatcmpl-123",
        object = "chat.completion.chunk",
        created = 1234567890,
        model = "test-model",
        choices = {
          {
            index = 0,
            delta = {
              content = "这是包含反斜杠\\和双引号\"以及控制字符\x00\x01的文本\n第二行\t制表符",
              reasoning_content = "思考过程包含\x00空字符",
            },
            finish_reason = nil,
          },
        },
      }

      -- 2. 模拟 http_client 收到响应后的编码步骤
      hc._encode_response_strings(raw_api_response)

      -- 验证编码结果
      local encoded_content = raw_api_response.choices[1].delta.content
      assert.is_true(encoded_content:find("%%5C") ~= nil, "反斜杠应编码为 %5C")
      assert.is_true(encoded_content:find("%%22") ~= nil, "双引号应编码为 %22")
      assert.is_true(encoded_content:find("%%00") ~= nil, "\\x00 应编码为 %00")
      assert.is_true(encoded_content:find("%%01") ~= nil, "\\x01 应编码为 %01")
      assert.is_true(encoded_content:find("%%0A") ~= nil, "\\n 应编码为 %0A")
      assert.is_true(encoded_content:find("%%09") ~= nil, "\\t 应编码为 %09")
      assert.is_true(encoded_content:find("文本") ~= nil, "中文应保留")

      -- 3. 模拟存储到 history_manager（编码后的内容存入持久化）
      local stored_content = encoded_content
      local stored_reasoning = raw_api_response.choices[1].delta.reasoning_content

      -- 4. 模拟发送给 API 时解码（build_request 中的逻辑）
      local decoded_for_send = hc._decode_special_chars(stored_content)
      local expected_original = "这是包含反斜杠\\和双引号\"以及控制字符\x00\x01的文本\n第二行\t制表符"
      assert.equal(expected_original, decoded_for_send, "发送时解码应还原原始内容")

      -- 5. 模拟渲染时解码（_render_single_message 中的逻辑）
      local decoded_for_render = hc._decode_special_chars(stored_content)
      assert.equal(expected_original, decoded_for_render, "渲染时解码应还原原始内容")

      -- 6. 验证 reasoning 的编解码
      local decoded_reasoning = hc._decode_special_chars(stored_reasoning)
      assert.equal("思考过程包含\x00空字符", decoded_reasoning, "reasoning 编解码应一致")

      -- 7. 验证编码后的内容可以安全嵌入 JSON（不会破坏 JSON 结构）
      -- 因为 \ 和 " 已被编码为 %5C 和 %22，控制字符已被编码为 %XX
      -- 所以可以直接嵌入 JSON 字符串值中，无需额外转义
      local safe_for_json = '{"content":"' .. stored_content .. '"}'
      local ok, parsed = pcall(vim.json.decode, safe_for_json)
      assert.is_true(ok, "编码后的内容应能安全嵌入 JSON")
      assert.not_nil(parsed, "JSON 解析结果不应为 nil")
      if ok and parsed then
        -- JSON 解码后得到的是原始内容（因为 vim.json.decode 会解析转义）
        -- 验证 JSON 中的内容与编码前一致
        assert.equal(stored_content, parsed.content, "JSON 中的内容应与编码后一致")
      end

      -- 8. 验证包含反斜杠的 tool_calls.arguments 也能安全嵌入 JSON
      local raw_arguments = '{"file":"C:\\\\Users\\\\test","query":"hello\"world"}'
      local encoded_arguments = hc._encode_special_chars(raw_arguments)
      local json_with_args = '{"arguments":"' .. encoded_arguments .. '"}'
      local ok2, parsed2 = pcall(vim.json.decode, json_with_args)
      assert.is_true(ok2, "编码后的 arguments 应能安全嵌入 JSON")
      if ok2 and parsed2 then
        local decoded_args = hc._decode_special_chars(parsed2.arguments)
        assert.equal(raw_arguments, decoded_args, "arguments 编解码往返应一致")
      end
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
