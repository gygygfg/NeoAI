--- 测试: utils/json.lua
--- 测试 JSON 编码/解码功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_utils_json ===")

  return test.run_tests({
    --- 测试 encode - 基本类型
    test_encode_basic = function()
      local json = require("NeoAI.utils.json")

      assert.equal('"hello"', json.encode("hello"))
      assert.equal("42", json.encode(42))
      assert.equal("3.14", json.encode(3.14))
      assert.equal("true", json.encode(true))
      assert.equal("false", json.encode(false))
      assert.equal("null", json.encode(nil))
    end,

    --- 测试 encode - 数组
    test_encode_array = function()
      local json = require("NeoAI.utils.json")

      assert.equal("[1,2,3]", json.encode({ 1, 2, 3 }))
      assert.equal('["a","b","c"]', json.encode({ "a", "b", "c" }))
      assert.equal("[]", json.encode({}))
    end,

    --- 测试 encode - 对象
    test_encode_object = function()
      local json = require("NeoAI.utils.json")

      local result = json.encode({ a = 1, b = "hello" })
      assert.is_true(string.find(result, '"a":1') ~= nil)
      assert.is_true(string.find(result, '"b":"hello"') ~= nil)
    end,

    --- 测试 encode - 嵌套
    test_encode_nested = function()
      local json = require("NeoAI.utils.json")

      local data = {
        name = "test",
        items = { 1, 2, 3 },
        config = { enabled = true },
      }
      local result = json.encode(data)
      assert.is_true(type(result) == "string")
      assert.is_true(#result > 0)
    end,

    --- 测试 encode - 特殊字符
    test_encode_special_chars = function()
      local json = require("NeoAI.utils.json")

      assert.equal('"hello\\nworld"', json.encode("hello\nworld"))
      assert.equal('"tab\\there"', json.encode("tab\there"))
      assert.equal('"quote\\"here"', json.encode('quote"here'))
    end,

    --- 测试 decode - 基本类型
    test_decode_basic = function()
      local json = require("NeoAI.utils.json")

      assert.equal("hello", json.decode('"hello"'))
      assert.equal(42, json.decode("42"))
      assert.equal(true, json.decode("true"))
      assert.equal(false, json.decode("false"))
      assert.equal(nil, json.decode("null"))
    end,

    --- 测试 decode - 数组
    test_decode_array = function()
      local json = require("NeoAI.utils.json")

      local result = json.decode("[1,2,3]")
      assert.equal(1, result[1])
      assert.equal(2, result[2])
      assert.equal(3, result[3])

      local result2 = json.decode('["a","b"]')
      assert.equal("a", result2[1])
      assert.equal("b", result2[2])
    end,

    --- 测试 decode - 对象
    test_decode_object = function()
      local json = require("NeoAI.utils.json")

      local result = json.decode('{"a":1,"b":"hello"}')
      assert.equal(1, result.a)
      assert.equal("hello", result.b)
    end,

    --- 测试 decode - 嵌套
    test_decode_nested = function()
      local json = require("NeoAI.utils.json")

      local result = json.decode('{"name":"test","items":[1,2,3],"config":{"enabled":true}}')
      assert.equal("test", result.name)
      assert.equal(1, result.items[1])
      assert.equal(true, result.config.enabled)
    end,

    --- 测试 decode - 转义字符
    test_decode_escaped = function()
      local json = require("NeoAI.utils.json")

      assert.equal("hello\nworld", json.decode('"hello\\nworld"'))
      assert.equal('quote"here', json.decode('"quote\\"here"'))
    end,

    --- 测试 decode - 空值
    test_decode_empty = function()
      local json = require("NeoAI.utils.json")

      assert.equal(nil, json.decode(""))
      assert.equal(nil, json.decode(nil))
      assert.equal(nil, json.decode("   "))
    end,

    --- 测试 decode - SSE 格式
    test_decode_sse = function()
      local json = require("NeoAI.utils.json")

      -- data: 前缀
      local result = json.decode('data: {"content":"hello"}')
      assert.not_nil(result)
      assert.equal("hello", result.content)

      -- [DONE] 标记
      assert.equal(nil, json.decode("[DONE]"))
      assert.equal(nil, json.decode("data: [DONE]"))
    end,

    --- 测试 encode/decode 往返
    test_roundtrip = function()
      local json = require("NeoAI.utils.json")

      local data = {
        string = "hello",
        number = 42,
        boolean = true,
        array = { 1, 2, 3 },
        object = { nested = { key = "value" } },
        null_value = nil,
      }

      local encoded = json.encode(data)
      local decoded = json.decode(encoded)

      assert.equal("hello", decoded.string)
      assert.equal(42, decoded.number)
      assert.equal(true, decoded.boolean)
      assert.equal(1, decoded.array[1])
      assert.equal("value", decoded.object.nested.key)
    end,

    --- 测试 encode - 空数组和空对象
    test_encode_empty = function()
      local json = require("NeoAI.utils.json")

      assert.equal("[]", json.encode({}))
      assert.equal("{}", json.encode({}, true)) -- 空表默认是数组
    end,

    --- 测试 decode - unicode 转义
    test_decode_unicode = function()
      local json = require("NeoAI.utils.json")

      local result = json.decode('"\\u4e2d\\u6587"')
      assert.equal("中文", result)
    end,

    --- 测试 decode - 非法输入
    test_decode_invalid = function()
      local json = require("NeoAI.utils.json")

      assert.equal(nil, json.decode("{"))
      assert.equal(nil, json.decode("[1,2,"))
      assert.equal(nil, json.decode("undefined"))
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
