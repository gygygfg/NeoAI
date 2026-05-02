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

      -- 先注册测试包
      tp.register_pack({
        name = "test_get_pack",
        display_name = "获取测试包",
        icon = "📦",
        tools = {},
        order = 1,
      })

      local pack = tp.get_pack("test_get_pack")
      assert.not_nil(pack, "应获取到包")
      assert.equal("获取测试包", pack.display_name)
      assert.equal("📦", pack.icon)

      -- 不存在的包
      local missing = tp.get_pack("nonexistent")
      assert.equal(nil, missing)
    end,

    -- 测试 get_pack_for_tool
    test_get_pack_for_tool = function()
      local tp = require("NeoAI.tools.tool_pack")

      -- 先注册测试包
      tp.register_pack({
        name = "test_pack_find",
        display_name = "查找测试",
        icon = "🔍",
        tools = { "find_me_tool" },
        order = 1,
      })

      local pack_name = tp.get_pack_for_tool("find_me_tool")
      assert.equal("test_pack_find", pack_name)

      -- 不存在的工具
      local missing = tp.get_pack_for_tool("nonexistent_tool")
      assert.equal(nil, missing)
    end,

    --- 测试 get_all_packs
    test_get_all_packs = function()
      local tp = require("NeoAI.tools.tool_pack")

      -- 先注册测试包
      tp.register_pack({
        name = "test_all_packs",
        display_name = "所有包测试",
        icon = "📦",
        tools = {},
        order = 1,
      })

      local all = tp.get_all_packs()
      assert.is_true(#all > 0, "应有至少1个包")
    end,

    -- 测试 get_pack_display_name
    test_get_pack_display_name = function()
      local tp = require("NeoAI.tools.tool_pack")
      tp.initialize()

      -- 先注册测试包
      local pack_name = "display_test_" .. tostring(os.time())
      local ok = tp.register_pack({
        name = pack_name,
        display_name = "测试显示",
        icon = "📦",
        tools = {},
        order = 1,
      })
      assert.is_true(ok, "注册包应成功")
      local dn = tp.get_pack_display_name(pack_name)
      assert.equal("测试显示", dn)
      assert.equal("工具调用", tp.get_pack_display_name("_uncategorized"))
      -- 当包存在时，get_pack_display_name 返回 display_name，不是包名
      assert.equal("测试显示", tp.get_pack_display_name(pack_name))
    end,

    -- 测试 get_pack_icon
    test_get_pack_icon = function()
      local tp = require("NeoAI.tools.tool_pack")

      -- 先注册测试包
      tp.register_pack({
        name = "test_pack_icon",
        display_name = "测试图标",
        icon = "🎯",
        tools = {},
        order = 1,
      })
      assert.equal("🎯", tp.get_pack_icon("test_pack_icon"))
      assert.equal("🔧", tp.get_pack_icon("_uncategorized"))
      assert.equal("🔧", tp.get_pack_icon("nonexistent"))
    end,

    -- 测试 get_pack_tools
    test_get_pack_tools = function()
      local tp = require("NeoAI.tools.tool_pack")

      -- 先注册测试包
      tp.register_pack({
        name = "test_pack_tools",
        display_name = "测试工具列表",
        icon = "🔧",
        tools = { "tool_x", "tool_y", "tool_z" },
        order = 1,
      })
      local tools = tp.get_pack_tools("test_pack_tools")
      assert.is_true(#tools >= 2, "应有至少2个工具")
      assert.contains(tools, "tool_x")
    end,

    --- 测试 get_all_tool_names
    test_get_all_tool_names = function()
      local tp = require("NeoAI.tools.tool_pack")

      -- 先注册测试包
      tp.register_pack({
        name = "test_all_names",
        display_name = "名称测试",
        icon = "📛",
        tools = { "name_tool_a", "name_tool_b" },
        order = 1,
      })

      local names = tp.get_all_tool_names()
      assert.is_true(#names > 0, "应有工具名称")
    end,

    -- 测试 group_by_pack
    test_group_by_pack = function()
      local tp = require("NeoAI.tools.tool_pack")

      -- 先注册测试包
      tp.register_pack({
        name = "test_pack_group",
        display_name = "分组测试",
        icon = "📦",
        tools = { "group_tool" },
        order = 1,
      })

      local tool_calls = {
        { name = "group_tool", func = { name = "group_tool" } },
        { name = "nonexistent_tool" },
      }

      local grouped = tp.group_by_pack(tool_calls)
      assert.not_nil(grouped.test_pack_group, "group_tool 应归入 test_pack_group")
      assert.not_nil(grouped._uncategorized, "未分类工具应归入 _uncategorized")
    end,

    --- 测试 get_pack_order
    test_get_pack_order = function()
      local tp = require("NeoAI.tools.tool_pack")

      -- 先注册测试包
      local pack_name = "order_test_" .. tostring(os.time())
      tp.register_pack({
        name = pack_name,
        display_name = "排序测试",
        icon = "🔢",
        tools = {},
        order = 10,
      })
      assert.equal(10, tp.get_pack_order(pack_name))
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
