--- 测试: tools/tool_pack.lua
--- 测试工具包管理模块的初始化、注册、查询、分组等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_tool_pack ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local tp = require("NeoAI.tools.tool_pack")
      tp.initialize()
      -- 幂等初始化
      tp.initialize()
    end,

    --- 测试 register_pack
    test_register_pack = function()
      local tp = require("NeoAI.tools.tool_pack")

      local ok = tp.register_pack({
        name = "test_pack",
        display_name = "测试包",
        icon = "🧪",
        tools = { "tool_a", "tool_b" },
        order = 10,
      })
      assert.is_true(ok, "注册包应成功")

      -- 无效注册
      local ok2 = tp.register_pack(nil)
      assert.is_false(ok2, "nil 应注册失败")
    end,

    --- 测试 get_pack
    test_get_pack = function()
      local tp = require("NeoAI.tools.tool_pack")

      local pack = tp.get_pack("test_pack")
      assert.not_nil(pack, "应获取到包")
      assert.equal("测试包", pack.display_name)
      assert.equal("🧪", pack.icon)

      -- 不存在的包
      local missing = tp.get_pack("nonexistent")
      assert.equal(nil, missing)
    end,

    --- 测试 get_pack_for_tool
    test_get_pack_for_tool = function()
      local tp = require("NeoAI.tools.tool_pack")

      local pack_name = tp.get_pack_for_tool("tool_a")
      assert.equal("test_pack", pack_name)

      -- 不存在的工具
      local missing = tp.get_pack_for_tool("nonexistent_tool")
      assert.equal(nil, missing)
    end,

    --- 测试 get_all_packs
    test_get_all_packs = function()
      local tp = require("NeoAI.tools.tool_pack")

      local all = tp.get_all_packs()
      assert.is_true(#all > 0, "应有至少1个包")
    end,

    --- 测试 get_pack_display_name
    test_get_pack_display_name = function()
      local tp = require("NeoAI.tools.tool_pack")

      assert.equal("测试包", tp.get_pack_display_name("test_pack"))
      assert.equal("工具调用", tp.get_pack_display_name("_uncategorized"))
      assert.equal("test_pack", tp.get_pack_display_name("test_pack"))
    end,

    --- 测试 get_pack_icon
    test_get_pack_icon = function()
      local tp = require("NeoAI.tools.tool_pack")

      assert.equal("🧪", tp.get_pack_icon("test_pack"))
      assert.equal("🔧", tp.get_pack_icon("_uncategorized"))
      assert.equal("🔧", tp.get_pack_icon("nonexistent"))
    end,

    --- 测试 get_pack_tools
    test_get_pack_tools = function()
      local tp = require("NeoAI.tools.tool_pack")

      local tools = tp.get_pack_tools("test_pack")
      assert.is_true(#tools >= 2, "应有至少2个工具")
      assert.contains(tools, "tool_a")
    end,

    --- 测试 get_all_tool_names
    test_get_all_tool_names = function()
      local tp = require("NeoAI.tools.tool_pack")

      local names = tp.get_all_tool_names()
      assert.is_true(#names > 0, "应有工具名称")
    end,

    --- 测试 group_by_pack
    test_group_by_pack = function()
      local tp = require("NeoAI.tools.tool_pack")

      local tool_calls = {
        { name = "tool_a", func = { name = "tool_a" } },
        { name = "nonexistent_tool" },
      }

      local grouped = tp.group_by_pack(tool_calls)
      assert.not_nil(grouped.test_pack, "tool_a 应归入 test_pack")
      assert.not_nil(grouped._uncategorized, "未分类工具应归入 _uncategorized")
    end,

    --- 测试 get_pack_order
    test_get_pack_order = function()
      local tp = require("NeoAI.tools.tool_pack")

      assert.equal(10, tp.get_pack_order("test_pack"))
      assert.equal(99, tp.get_pack_order("nonexistent"))
    end,

    --- 测试 group_by_pack 空列表
    test_group_by_pack_empty = function()
      local tp = require("NeoAI.tools.tool_pack")
      local grouped = tp.group_by_pack({})
      assert.is_true(next(grouped) == nil, "空列表应返回空表")
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
