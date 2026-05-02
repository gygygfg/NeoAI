--- 测试: 特殊字符编解码（独立测试，不依赖测试框架）
--- 测试 http_client 中 _encode_special_chars / _decode_special_chars
--- 以及 _encode_response_strings 的完整流程
---
--- 运行: nvim --headless -c "lua dofile('/path/to/test_special_chars_encoding.lua')" -c "qa!"

-- 内联断言
local assert = {}
function assert.equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("断言失败: %s\n  期望: %s\n  实际: %s",
      msg or "值不相等", vim.inspect(expected), vim.inspect(actual)))
  end
end
function assert.is_true(value, msg)
  if not value then
    error(string.format("断言失败: %s\n  期望为真, 实际为假", msg or "值应为真"))
  end
end
function assert.not_nil(value, msg)
  if value == nil then
    error(string.format("断言失败: %s\n  值不应为 nil", msg or "值不应为 nil"))
  end
end

-- 清除缓存并加载最新模块
package.loaded["NeoAI.core.ai.http_client"] = nil
local hc = require("NeoAI.core.ai.http_client")

local tests_passed = 0
local tests_failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print(string.format("  ✓ %s", name))
    tests_passed = tests_passed + 1
  else
    print(string.format("  ✗ %s: %s", name, tostring(err)))
    tests_failed = tests_failed + 1
  end
end

print("\n=== test_special_chars_encoding ===")

-- ========== 1. 编解码单元测试 ==========

test("纯 ASCII 文本不应被编码", function()
  local original = "Hello, World! 123"
  local encoded = hc._encode_special_chars(original)
  assert.equal(original, encoded)
  local decoded = hc._decode_special_chars(encoded)
  assert.equal(original, decoded)
end)

test("反斜杠应编码为 %5C 并正确解码", function()
  local original = [[path\to\file]]
  local encoded = hc._encode_special_chars(original)
  assert.is_true(encoded:find("%%5C") ~= nil, "反斜杠应编码为 %5C")
  local decoded = hc._decode_special_chars(encoded)
  assert.equal(original, decoded)
end)

test("双引号应编码为 %22 并正确解码", function()
  local original = [[he said "hello" world]]
  local encoded = hc._encode_special_chars(original)
  assert.is_true(encoded:find("%%22") ~= nil, "双引号应编码为 %22")
  local decoded = hc._decode_special_chars(encoded)
  assert.equal(original, decoded)
end)

test("控制字符应编码为 %XX 并正确解码", function()
  local original = "text\x00with\x01control\x1Fchars"
  local encoded = hc._encode_special_chars(original)
  assert.is_true(encoded:find("%%00") ~= nil, "\\x00 应编码为 %00")
  assert.is_true(encoded:find("%%01") ~= nil, "\\x01 应编码为 %01")
  assert.is_true(encoded:find("%%1F") ~= nil, "\\x1F 应编码为 %1F")
  local decoded = hc._decode_special_chars(encoded)
  assert.equal(original, decoded)
end)

test("换行/回车/制表符应保留不变", function()
  local original = "line1\nline2\rline3\tindented"
  local encoded = hc._encode_special_chars(original)
  assert.equal(original, encoded)
  local decoded = hc._decode_special_chars(encoded)
  assert.equal(original, decoded)
end)

test("有效 UTF-8 中文应保留不变", function()
  local original = "你好，世界！"
  local encoded = hc._encode_special_chars(original)
  assert.equal(original, encoded)
  local decoded = hc._decode_special_chars(encoded)
  assert.equal(original, decoded)
end)

test("混合场景编解码往返应一致", function()
  local original = "path\\to\\file\"with\"ctrl\x00chars\nnewline\ttab\x1Fsep和中文"
  local encoded = hc._encode_special_chars(original)
  assert.is_true(encoded:find("%%5C") ~= nil, "反斜杠应编码")
  assert.is_true(encoded:find("%%22") ~= nil, "双引号应编码")
  assert.is_true(encoded:find("%%00") ~= nil, "\\x00 应编码")
  assert.is_true(encoded:find("%%1F") ~= nil, "\\x1F 应编码")
  assert.is_true(encoded:find("\n") ~= nil, "\\n 应保留")
  assert.is_true(encoded:find("\t") ~= nil, "\\t 应保留")
  assert.is_true(encoded:find("和中文") ~= nil, "中文应保留")
  local decoded = hc._decode_special_chars(encoded)
  assert.equal(original, decoded)
end)

test("空字符串和 nil 处理", function()
  assert.equal("", hc._encode_special_chars(""))
  assert.equal(nil, hc._encode_special_chars(nil))
  assert.equal("", hc._decode_special_chars(""))
  assert.equal(nil, hc._decode_special_chars(nil))
end)

-- ========== 2. _encode_response_strings 递归编码测试 ==========

test("_encode_response_strings 递归编码流式响应", function()
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

  -- 验证 content
  local content = stream_response.choices[1].delta.content
  assert.is_true(content:find("%%22") ~= nil, "content 中的双引号应编码")
  assert.is_true(content:find("%%5C") ~= nil, "content 中的反斜杠应编码")
  assert.equal("hello %22world%22 and path%5Cto%5Cfile", content)

  -- 验证 reasoning_content
  local reasoning = stream_response.choices[1].delta.reasoning_content
  assert.is_true(reasoning:find("%%00") ~= nil, "reasoning 中的 \\x00 应编码")
  assert.equal("思考%00过程", reasoning)

  -- 验证 tool_calls arguments
  local args = stream_response.choices[1].delta.tool_calls[1]["function"].arguments
  assert.is_true(args:find("%%5C") ~= nil, "arguments 中的反斜杠应编码")

  -- 验证解码后还原
  assert.equal("hello \"world\" and path\\to\\file", hc._decode_special_chars(content))
  assert.equal("思考\x00过程", hc._decode_special_chars(reasoning))
  assert.equal('{"key":"value\\with\\backslash"}', hc._decode_special_chars(args))
end)

-- ========== 3. 完整流程模拟测试 ==========

test("完整流程：API 响应 → 编码 → 存储 → 解码发送 → 解码渲染", function()
  -- 1. 模拟 API 原始响应
  local raw_response = {
    choices = {
      {
        delta = {
          content = "包含反斜杠\\和双引号\"以及控制字符\x00\x01的文本\n第二行\t制表符",
          reasoning_content = "思考过程包含\x00空字符",
        },
      },
    },
  }

  -- 2. 编码
  hc._encode_response_strings(raw_response)
  local encoded_content = raw_response.choices[1].delta.content
  local encoded_reasoning = raw_response.choices[1].delta.reasoning_content

  -- 验证编码
  assert.is_true(encoded_content:find("%%5C") ~= nil, "反斜杠应编码")
  assert.is_true(encoded_content:find("%%22") ~= nil, "双引号应编码")
  assert.is_true(encoded_content:find("%%00") ~= nil, "\\x00 应编码")
  assert.is_true(encoded_content:find("%%01") ~= nil, "\\x01 应编码")
  assert.is_true(encoded_content:find("\n") ~= nil, "\\n 应保留")
  assert.is_true(encoded_content:find("\t") ~= nil, "\\t 应保留")
  assert.is_true(encoded_content:find("文本") ~= nil, "中文应保留")

  -- 3. 模拟存储（编码后的内容存入持久化）
  local stored_content = encoded_content
  local stored_reasoning = encoded_reasoning

  -- 4. 模拟发送给 API 时解码
  local decoded_for_send = hc._decode_special_chars(stored_content)
  local expected = "包含反斜杠\\和双引号\"以及控制字符\x00\x01的文本\n第二行\t制表符"
  assert.equal(expected, decoded_for_send, "发送时解码应还原原始内容")

  -- 5. 模拟渲染时解码
  local decoded_for_render = hc._decode_special_chars(stored_content)
  assert.equal(expected, decoded_for_render, "渲染时解码应还原原始内容")

  -- 6. 验证 reasoning 编解码
  assert.equal("思考过程包含\x00空字符", hc._decode_special_chars(stored_reasoning))

  -- 7. 验证编码后的内容可以安全嵌入 JSON
  local safe_json = '{"content":"' .. stored_content .. '"}'
  local ok, parsed = pcall(vim.json.decode, safe_json)
  assert.is_true(ok, "编码后的内容应能安全嵌入 JSON")
  assert.not_nil(parsed, "JSON 解析结果不应为 nil")
  if ok and parsed then
    assert.equal(stored_content, parsed.content, "JSON 中的内容应与编码后一致")
  end

  -- 8. 验证包含反斜杠的 tool_calls.arguments 也能安全嵌入 JSON
  local raw_args = '{"file":"C:\\\\Users\\\\test","query":"hello\"world"}'
  local encoded_args = hc._encode_special_chars(raw_args)
  local json_with_args = '{"arguments":"' .. encoded_args .. '"}'
  local ok2, parsed2 = pcall(vim.json.decode, json_with_args)
  assert.is_true(ok2, "编码后的 arguments 应能安全嵌入 JSON")
  if ok2 and parsed2 then
    assert.equal(raw_args, hc._decode_special_chars(parsed2.arguments))
  end
end)

-- ========== 结果汇总 ==========
print(string.format("\n测试结果: %d 通过, %d 失败", tests_passed, tests_failed))
if tests_failed > 0 then
  os.exit(1)
end
