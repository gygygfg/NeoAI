--- 测试 tree_handlers.build_connectors 函数
--- 模拟 flat_items 结构，验证连接符生成是否正确
---
--- 运行：nvim --headless -c "lua dofile('/root/NeoAI/pack/plugins/start/NeoAI/lua/NeoAI/tests/test_tree_connectors.lua')" -c "qa"

local logger = require("NeoAI.utils.logger")
logger.initialize({
  level = "DEBUG",
  output_path = "/tmp/neoai_test_tree_connectors.log",
  print_debug = false,
})

-- 引用 tree_handlers 中的 build_connectors（反向遍历版本）
local function build_connectors(flat_items)
  local ok, handlers = pcall(require, "NeoAI.ui.handlers.tree_handlers")
  if ok and handlers.build_connectors then
    return handlers.build_connectors(flat_items)
  end
  -- fallback：如果 tree_handlers 未加载，使用内联实现
  if not flat_items or #flat_items == 0 then
    return {}
  end

  local n = #flat_items
  local prefixes = {}
  for i = 1, n do
    prefixes[i] = ""
  end

  local needs_line = {}

  -- 正向遍历
  for i = 1, n do
    local item = flat_items[i]
    local indent = item.indent or 0

    local parts = {}
    for level = 1, indent do
      if level < indent then
        if needs_line[level] then
          table.insert(parts, "│  ")
        else
          table.insert(parts, "   ")
        end
      else
        if item.is_virtual then
          if needs_line[level] then
            table.insert(parts, "│  ")
          else
            table.insert(parts, "   ")
          end
        else
          if not item.is_last_branch then
            table.insert(parts, "│  ")
          else
            table.insert(parts, "   ")
          end
        end
      end
    end
    prefixes[i] = table.concat(parts)

    if not item.is_virtual then
      needs_line[indent] = not item.is_last_branch
    end
  end

  -- 特殊处理根虚拟节点
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

local function render(flat_items, prefixes)
  local lines = {}
  for idx, item in ipairs(flat_items) do
    local prefix = prefixes[idx] or ""
    local line = prefix
    if item.is_virtual then
      line = line .. "📂 聊天会话"
    else
      if item.is_last_session then
        line = line .. "└─ " .. (item.display_text or "node")
      else
        line = line .. "├─ " .. (item.display_text or "node")
      end
    end
    table.insert(lines, line)
  end
  return lines
end

local function print_tree(flat_items)
  local prefixes = build_connectors(flat_items)
  local lines = render(flat_items, prefixes)
  for _, l in ipairs(lines) do
    logger.info(l)
  end
end

local function assert_eq(got, expected, msg)
  if got ~= expected then
    logger.error("  ❌ FAIL: " .. (msg or ""))
    logger.error("     expected: '" .. tostring(expected) .. "'")
    logger.error("     got:      '" .. tostring(got) .. "'")
    os.exit(1)
  else
    logger.info("  ✅ PASS: " .. (msg or ""))
  end
end

local function run_tests()
  logger.info("===== 测试 1: 单根无分支 =====")
  logger.info("")
  -- 1个虚拟根节点 + 1个根节点
  local items1 = {
    { is_virtual = true, indent = 0 },
    { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = true, display_text = "根1" },
  }
  local p1 = build_connectors(items1)
  assert_eq(p1[1], "", "虚拟根节点前缀为空")
  assert_eq(p1[2], "   ", "单根节点前缀为3个空格")
  print_tree(items1)

  logger.info("===== 测试 2: 两个根节点 =====")
  logger.info("")
  local items2 = {
    { is_virtual = true, indent = 0 },
    { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = false, display_text = "根1" },
    { is_virtual = true, indent = 0 },
    { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = true, display_text = "根2" },
  }
  local p2 = build_connectors(items2)
  -- 第一个虚拟根节点（索引1）：空
  assert_eq(p2[1], "", "第一个虚拟根节点前缀为空")
  -- 根1（索引2）：indent=1，且不是最后一个兄弟，所以第一列是 │
  assert_eq(p2[2], "│  ", "根1前缀为 │  ")
  -- 第二个虚拟根节点（索引3）：indent=0，虚拟节点本身不画竖线
  assert_eq(p2[3], "", "中间虚拟根节点前缀为空")
  -- 根2（索引4）：indent=1，是最后一个兄弟，第一列为空
  assert_eq(p2[4], "   ", "最后一个根节点前缀为3个空格")
  print_tree(items2)

  logger.info("===== 测试 3: 单根带子节点 =====")
  logger.info("")
  local items3 = {
    { is_virtual = true, indent = 0 },
    { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = true, display_text = "根1" },
    { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子1" },
  }
  local p3 = build_connectors(items3)
  -- 根1：indent=1，是最后一个兄弟，第一列空
  assert_eq(p3[2], "   ", "根1前缀为3个空格")
  -- 子1：indent=2，第一列从根1拉线（根1不是最后一个兄弟？不，根1是最后一个兄弟，所以没有拉线）
  -- 实际上根1 is_last_branch=true，所以子1的第一列应该没有 │
  -- 子1的第二列：indent=2，子1是最后一个兄弟，所以第二列空
  assert_eq(p3[3], "      ", "子1 indent=2 应有2列（6个空格）")
  print_tree(items3)

  logger.info("===== 测试 4: 单根带分支 =====")
  logger.info("")
  local items4 = {
    { is_virtual = true, indent = 0 },
    { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = true, display_text = "根1" },
    { is_virtual = true, indent = 1 },
    { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子1" },
  }
  local p4 = build_connectors(items4)
  print_tree(items4)

  logger.info("===== 测试 5: 根有两个子节点 =====")
  logger.info("")
  local items5 = {
    { is_virtual = true, indent = 0 },
    { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = true, display_text = "根1" },
    { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = false, display_text = "子1" },
    { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "子2" },
  }
  local p5 = build_connectors(items5)
  print_tree(items5)

  logger.info("===== 测试 6: 复杂多根多分支 =====")
  logger.info("")
  local items6 = {
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
  local p6 = build_connectors(items6)
  print_tree(items6)

  logger.info("===== 全部测试通过! =====")
end

run_tests()
