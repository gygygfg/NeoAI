--- 测试: utils/common.lua
--- 测试公共工具函数的深拷贝、合并、防抖、节流、重试等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_utils_common ===")

  return test.run_tests({
    --- 测试 deep_copy
    test_deep_copy = function()
      local utils = require("NeoAI.utils")

      local original = { a = 1, b = { c = 2, d = { e = 3 } } }
      local copy = utils.deep_copy(original)

      assert.equal(original.a, copy.a)
      assert.equal(original.b.c, copy.b.c)
      assert.equal(original.b.d.e, copy.b.d.e)

      -- 修改副本不应影响原表
      copy.b.c = 100
      assert.equal(2, original.b.c)

      -- 非表类型
      assert.equal(42, utils.deep_copy(42))
      assert.equal("hello", utils.deep_copy("hello"))
    end,

    --- 测试 deep_merge
    test_deep_merge = function()
      local utils = require("NeoAI.utils")

      local t1 = { a = 1, b = { c = 2 } }
      local t2 = { b = { d = 3 }, e = 4 }

      local merged = utils.deep_merge(t1, t2)
      assert.equal(1, merged.a)
      assert.equal(2, merged.b.c)
      assert.equal(3, merged.b.d)
      assert.equal(4, merged.e)

      -- 非表参数
      assert.equal(42, utils.deep_merge(nil, 42))
      assert.equal("hello", utils.deep_merge("hello", nil))
    end,

    --- 测试 safe_call
    test_safe_call = function()
      local utils = require("NeoAI.utils")

      local result, err = utils.safe_call(function(a, b) return a + b end, 3, 4)
      assert.equal(7, result)
      assert.equal(nil, err)

      local result2, err2 = utils.safe_call(function() error("出错了") end)
      assert.equal(nil, result2)
      assert.not_nil(err2)

      -- 非函数
      local result3, err3 = utils.safe_call("not_a_function")
      assert.equal(nil, result3)
      assert.not_nil(err3)
    end,

    --- 测试 unique_id
    test_unique_id = function()
      local utils = require("NeoAI.utils")

      local id1 = utils.unique_id("test")
      local id2 = utils.unique_id("test")
      assert.not_equal(id1, id2, "两次生成的 ID 应不同")
      assert.is_true(string.find(id1, "^test_") ~= nil, "ID 应以前缀开头")

      -- 默认前缀
      local id3 = utils.unique_id()
      assert.is_true(string.find(id3, "^id_") ~= nil)
    end,

    --- 测试 is_empty
    test_is_empty = function()
      local utils = require("NeoAI.utils")

      assert.is_true(utils.is_empty(nil))
      assert.is_true(utils.is_empty(""))
      assert.is_true(utils.is_empty({}))
      assert.is_false(utils.is_empty("hello"))
      assert.is_false(utils.is_empty({ 1 }))
      assert.is_false(utils.is_empty(0))
    end,

    --- 测试 default
    test_default = function()
      local utils = require("NeoAI.utils")

      assert.equal("default", utils.default(nil, "default"))
      assert.equal("default", utils.default("", "default"))
      assert.equal("hello", utils.default("hello", "default"))
      assert.equal(42, utils.default(42, 0))
    end,

    --- 测试 random_string
    test_random_string = function()
      local utils = require("NeoAI.utils")

      local s1 = utils.random_string(10)
      local s2 = utils.random_string(10)
      assert.equal(10, #s1)
      assert.equal(10, #s2)
      -- 两次生成的字符串可能不同
    end,

    --- 测试 check_type
    test_check_type = function()
      local utils = require("NeoAI.utils")

      assert.is_true(utils.check_type("hello", "string"))
      assert.is_true(utils.check_type(42, "number"))
      assert.is_true(utils.check_type(true, "boolean"))
      assert.is_true(utils.check_type({ 1, 2 }, "array"))
      assert.is_true(utils.check_type({ a = 1 }, "object"))

      assert.is_false(utils.check_type(42, "string"))
      assert.is_false(utils.check_type({}, "array"))
    end,

    --- 测试 measure_time
    test_measure_time = function()
      local utils = require("NeoAI.utils")

      local result, duration = utils.measure_time(function(a, b) return a * b end, 6, 7)
      assert.equal(42, result)
      assert.is_true(duration >= 0, "执行时间应 >= 0")
    end,

    --- 测试 cache
    test_cache = function()
      local utils = require("NeoAI.utils")

      local call_count = 0
      local cached_fn = utils.cache(function(x)
        call_count = call_count + 1
        return x * 2
      end, 1) -- 1秒 TTL

      assert.equal(10, cached_fn(5))
      assert.equal(1, call_count, "第一次调用应执行函数")

      assert.equal(10, cached_fn(5))
      assert.equal(1, call_count, "第二次调用应命中缓存")
    end,

    --- 测试 merge_tables
    test_merge_tables = function()
      local utils = require("NeoAI.utils")

      local merged = utils.merge_tables({ a = 1 }, { b = 2 })
      assert.equal(1, merged.a)
      assert.equal(2, merged.b)
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
