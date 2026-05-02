--- 测试: utils/table_utils.lua
--- 测试表操作工具库的 keys、values、filter、map、reduce 等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_utils_table_utils ===")

  return test.run_tests({
    --- 测试 keys
    test_keys = function()
      local tu = require("NeoAI.utils.table_utils")
      local result = tu.keys({ a = 1, b = 2, c = 3 })
      table.sort(result)
      assert.equal("a", result[1])
      assert.equal("b", result[2])
      assert.equal("c", result[3])

      -- 非表
      assert.is_true(#tu.keys(nil) == 0)
      assert.is_true(#tu.keys("string") == 0)
    end,

    --- 测试 values
    test_values = function()
      local tu = require("NeoAI.utils.table_utils")
      local result = tu.values({ a = 1, b = 2, c = 3 })
      table.sort(result)
      assert.equal(1, result[1])
      assert.equal(2, result[2])
      assert.equal(3, result[3])
    end,

    --- 测试 filter
    test_filter = function()
      local tu = require("NeoAI.utils.table_utils")

      -- 数组
      local result = tu.filter({ 1, 2, 3, 4, 5 }, function(v) return v % 2 == 0 end)
      assert.equal(2, result[1])
      assert.equal(4, result[2])

      -- 字典
      local result2 = tu.filter({ a = 1, b = 2, c = 3 }, function(v) return v > 1 end)
      assert.equal(2, result2.b)
      assert.equal(3, result2.c)
      assert.equal(nil, result2.a)
    end,

    --- 测试 map
    test_map = function()
      local tu = require("NeoAI.utils.table_utils")

      local result = tu.map({ 1, 2, 3 }, function(v) return v * 2 end)
      assert.equal(2, result[1])
      assert.equal(4, result[2])
      assert.equal(6, result[3])
    end,

    --- 测试 reduce
    test_reduce = function()
      local tu = require("NeoAI.utils.table_utils")

      local sum = tu.reduce({ 1, 2, 3, 4, 5 }, function(acc, v) return acc + v end, 0)
      assert.equal(15, sum)

      -- 无初始值
      local product = tu.reduce({ 2, 3, 4 }, function(acc, v) return acc * v end)
      assert.equal(24, product)
    end,

    --- 测试 length
    test_length = function()
      local tu = require("NeoAI.utils.table_utils")

      assert.equal(3, tu.length({ a = 1, b = 2, c = 3 }))
      assert.equal(0, tu.length({}))
      assert.equal(0, tu.length(nil))
    end,

    --- 测试 is_empty
    test_is_empty = function()
      local tu = require("NeoAI.utils.table_utils")

      assert.is_true(tu.is_empty({}))
      assert.is_false(tu.is_empty({ 1 }))
      assert.is_true(tu.is_empty(nil))
    end,

    --- 测试 merge
    test_merge = function()
      local tu = require("NeoAI.utils.table_utils")

      local result = tu.merge({ a = 1 }, { b = 2 }, { c = 3 })
      assert.equal(1, result.a)
      assert.equal(2, result.b)
      assert.equal(3, result.c)
    end,

    --- 测试 contains
    test_contains = function()
      local tu = require("NeoAI.utils.table_utils")

      assert.is_true(tu.contains({ 1, 2, 3 }, 2))
      assert.is_false(tu.contains({ 1, 2, 3 }, 4))
      assert.is_false(tu.contains(nil, 1))
    end,

    --- 测试 has_key
    test_has_key = function()
      local tu = require("NeoAI.utils.table_utils")

      assert.is_true(tu.has_key({ a = 1 }, "a"))
      assert.is_false(tu.has_key({ a = 1 }, "b"))
    end,

    --- 测试 deep_equal
    test_deep_equal = function()
      local tu = require("NeoAI.utils.table_utils")

      assert.is_true(tu.deep_equal({ a = 1, b = { c = 2 } }, { a = 1, b = { c = 2 } }))
      assert.is_false(tu.deep_equal({ a = 1 }, { a = 2 }))
      assert.is_false(tu.deep_equal({ a = 1 }, { a = 1, b = 2 }))
    end,

    --- 测试 clone
    test_clone = function()
      local tu = require("NeoAI.utils.table_utils")

      local original = { a = 1, b = { c = 2 } }
      local cloned = tu.clone(original)
      cloned.a = 100
      assert.equal(1, original.a)
    end,

    --- 测试 pick / omit
    test_pick_omit = function()
      local tu = require("NeoAI.utils.table_utils")

      local picked = tu.pick({ a = 1, b = 2, c = 3 }, { "a", "c" })
      assert.equal(1, picked.a)
      assert.equal(3, picked.c)
      assert.equal(nil, picked.b)

      local omitted = tu.omit({ a = 1, b = 2, c = 3 }, { "b" })
      assert.equal(1, omitted.a)
      assert.equal(3, omitted.c)
      assert.equal(nil, omitted.b)
    end,

    --- 测试 find
    test_find = function()
      local tu = require("NeoAI.utils.table_utils")

      local val, key = tu.find({ a = 1, b = 2, c = 3 }, function(v) return v == 2 end)
      assert.equal(2, val)
      assert.equal("b", key)

      local val2, key2 = tu.find({ a = 1, b = 2 }, function(v) return v == 99 end)
      assert.equal(nil, val2)
    end,

    --- 测试 group_by
    test_group_by = function()
      local tu = require("NeoAI.utils.table_utils")

      local items = {
        { type = "fruit", name = "apple" },
        { type = "fruit", name = "banana" },
        { type = "veg", name = "carrot" },
      }

      local grouped = tu.group_by(items, function(item) return item.type end)
      assert.equal(2, #grouped.fruit)
      assert.equal(1, #grouped.veg)
    end,

    --- 测试 unique
    test_unique = function()
      local tu = require("NeoAI.utils.table_utils")

      local result = tu.unique({ 1, 2, 2, 3, 3, 3 })
      assert.equal(3, #result)
      assert.equal(1, result[1])
      assert.equal(2, result[2])
      assert.equal(3, result[3])
    end,

    --- 测试 reverse / slice
    test_reverse_slice = function()
      local tu = require("NeoAI.utils.table_utils")

      local reversed = tu.reverse({ 1, 2, 3 })
      assert.equal(3, reversed[1])
      assert.equal(2, reversed[2])
      assert.equal(1, reversed[3])

      local sliced = tu.slice({ 1, 2, 3, 4, 5 }, 2, 4)
      assert.equal(2, sliced[1])
      assert.equal(3, sliced[2])
      assert.equal(4, sliced[3])
    end,

    --- 测试 flatten
    test_flatten = function()
      local tu = require("NeoAI.utils.table_utils")

      local result = tu.flatten({ 1, { 2, 3 }, { 4, { 5, 6 } } }, 1)
      assert.equal(1, result[1])
      assert.equal(2, result[2])
      assert.equal(3, result[3])
      assert.equal(4, result[4])
    end,

    --- 测试 to_pairs / from_pairs
    test_pairs = function()
      local tu = require("NeoAI.utils.table_utils")

      local pairs = tu.to_pairs({ a = 1, b = 2 })
      assert.equal(2, #pairs)

      local result = tu.from_pairs(pairs)
      assert.equal(1, result.a)
      assert.equal(2, result.b)
    end,

    --- 测试 deep_copy
    test_deep_copy = function()
      local tu = require("NeoAI.utils.table_utils")

      local original = { a = 1, b = { c = 2 } }
      local copy = tu.deep_copy(original)
      copy.b.c = 100
      assert.equal(2, original.b.c)
    end,

    --- 测试 deep_merge
    test_deep_merge = function()
      local tu = require("NeoAI.utils.table_utils")

      local merged = tu.deep_merge({ a = 1, b = { c = 2 } }, { b = { d = 3 } })
      assert.equal(1, merged.a)
      assert.equal(2, merged.b.c)
      assert.equal(3, merged.b.d)
    end,

    --- 测试 sort
    test_sort = function()
      local tu = require("NeoAI.utils.table_utils")

      local result = tu.sort({ 3, 1, 4, 1, 5, 9, 2, 6 })
      assert.equal(1, result[1])
      assert.equal(1, result[2])
      assert.equal(2, result[3])
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
