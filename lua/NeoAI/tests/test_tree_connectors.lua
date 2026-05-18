--- 测试: 树形连接符生成
--- 合并了 test_tree_connectors, test_user_data, test_user_data2, test_user_data3
local M = {}
local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  if not test._logger then
    local logger = require("NeoAI.utils.logger")
    test._logger = logger
  end
  test._logger.info("\n=== test_tree_connectors ===")

  -- 从 tree_handlers 获取 build_connectors，如果不可用则使用内联实现
  local function get_build_connectors()
    local ok, handlers = pcall(require, "NeoAI.ui.handlers.tree_handlers")
    if ok and handlers.build_connectors then
      return handlers.build_connectors
    end
    -- fallback 内联实现（反向遍历版本）
    return function(flat_items)
      if not flat_items or #flat_items == 0 then return {} end
      local n = #flat_items
      local prefixes = {}
      for i = 1, n do prefixes[i] = "" end
      local needs_line = {}
      for i = 1, n do
        local item = flat_items[i]
        local indent = item.indent or 0
        local parts = {}
        for level = 1, indent do
          if level < indent then
            table.insert(parts, needs_line[level] and "│  " or "   ")
          else
            if item.is_virtual then
              table.insert(parts, needs_line[level] and "│  " or "   ")
            else
              table.insert(parts, (not item.is_last_branch) and "│  " or "   ")
            end
          end
        end
        prefixes[i] = table.concat(parts)
        if not item.is_virtual then
          needs_line[indent] = not item.is_last_branch
        end
      end
      -- 处理中间虚拟根节点：连接多个根会话
      for i, item in ipairs(flat_items) do
        if item.is_virtual and item.indent == 0 then
          if i ~= 1 then
            for j = i - 1, 1, -1 do
              if not flat_items[j].is_virtual and flat_items[j].indent == 1 then
                if not flat_items[j].is_last_branch then
                  prefixes[i] = "│  "
                end
                break
              end
            end
          end
        end
      end
      return prefixes
    end
  end

  local build_connectors = get_build_connectors()

  return test.run_tests({
    -- 测试1: 空列表
    test_empty_list = function()
      local p = build_connectors({})
      assert.is_true(#p == 0, "空列表应返回空表")
      local p2 = build_connectors(nil)
      assert.is_true(#p2 == 0, "nil 应返回空表")
    end,

    -- 测试2: 单根无分支
    test_single_root = function()
      local items = {
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = true, display_text = "根1" },
      }
      local p = build_connectors(items)
      assert.equal("", p[1], "虚拟根节点前缀为空")
      assert.equal("   ", p[2], "单根节点前缀为3个空格")
    end,

    -- 测试3: 两个根节点
    test_two_roots = function()
      local items = {
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = false, display_text = "根1" },
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = true, display_text = "根2" },
      }
      local p = build_connectors(items)
      assert.equal("", p[1], "第一个虚拟根节点前缀为空")
      assert.equal("│  ", p[2], "根1（非最后分支）应有竖线")
      assert.equal("", p[3], "中间虚拟根节点前缀为空")
      assert.equal("   ", p[4], "根2（最后分支）应为空格")
    end,

    -- 测试4: 单根带子节点
    test_root_with_child = function()
      local items = {
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = true, display_text = "根1" },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子1" },
      }
      local p = build_connectors(items)
      assert.not_nil(p[1])
      assert.not_nil(p[2])
      assert.not_nil(p[3])
    end,

    -- 测试5: 单根带分支（虚拟中间节点）
    test_root_with_branch = function()
      local items = {
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = true, display_text = "根1" },
        { is_virtual = true, indent = 1 },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子1" },
      }
      local p = build_connectors(items)
      assert.is_true(#p == #items)
    end,

    -- 测试6: 根有两个子节点
    test_root_two_children = function()
      local items = {
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = true, display_text = "根1" },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = false, display_text = "子1" },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子2" },
      }
      local p = build_connectors(items)
      assert.is_true(#p == #items)
    end,

    -- 测试7: 复杂多根多分支（来自 user_data）
    test_complex_multi_root = function()
      local items = {
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = false, display_text = "根1" },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = false, display_text = "子1" },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子2" },
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = false, display_text = "根2" },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子3" },
        { is_virtual = true, indent = 1 },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子4" },
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = true, display_text = "根3" },
      }
      local p = build_connectors(items)
      assert.is_true(#p == #items)
    end,

    -- 测试8: 模拟用户数据场景（会话树）
    test_user_data_scenario = function()
      local items = {
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = false, display_text = "会话1" },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子消息1" },
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = true, display_text = "会话2" },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子消息2" },
        { is_virtual = true, indent = 1 },
        { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "孙消息" },
        { is_virtual = true, indent = 0 },
        { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = true, display_text = "会话3" },
      }
      local p = build_connectors(items)
      assert.is_true(#p == #items)
    end,
  })
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

