--- 测试新算法：反向遍历，从 └ 往上拉线到父节点
local function build_connectors(flat_items)
  if not flat_items or #flat_items == 0 then
    return {}
  end

  local n = #flat_items
  local prefixes = {}
  for i = 1, n do
    prefixes[i] = ""
  end

  -- needs_line[level] = 该层级是否需要画 │
  local needs_line = {}

  -- 第一遍反向遍历：从 └ 节点往上拉线到父节点
  -- 记录每个缩进层级需要拉线的区间
  -- pull_ranges[level] = { start_line, end_line } 表示从 start_line 到 end_line 需要画 │
  local pull_ranges = {}

  for i = n, 1, -1 do
    local item = flat_items[i]
    if not item.is_virtual and item.is_last_session then
      -- 找到最近的父节点（indent 更小的上一个非虚拟节点）
      local parent_indent = item.indent - 1
      if parent_indent >= 1 then
        -- 从当前行往上找父节点
        for j = i - 1, 1, -1 do
          local pitem = flat_items[j]
          if not pitem.is_virtual and pitem.indent == parent_indent then
            -- 从父节点到当前节点之间，parent_indent 层级画 │
            if not pull_ranges[parent_indent] or j < pull_ranges[parent_indent][1] then
              pull_ranges[parent_indent] = { j, i }
            end
            break
          end
        end
      end
    end
  end

  -- 第二遍正向遍历：构建前缀
  for i = 1, n do
    local item = flat_items[i]
    local indent = item.indent or 0

    local parts = {}
    for level = 1, indent do
      local draw_line = false
      if pull_ranges[level] then
        local start_line, end_line = pull_ranges[level][1], pull_ranges[level][2]
        if i >= start_line and i <= end_line then
          draw_line = true
        end
      end
      if draw_line then
        table.insert(parts, "│  ")
      else
        table.insert(parts, "   ")
      end
    end
    prefixes[i] = table.concat(parts)
  end

  -- 规则4：第一个和最后一个虚拟根节点之间的第一列空格都换成 │
  local virtual_root_indices = {}
  for i, item in ipairs(flat_items) do
    if item.is_virtual and item.indent == 0 then
      table.insert(virtual_root_indices, i)
    end
  end
  if #virtual_root_indices >= 3 then
    for idx = 2, #virtual_root_indices - 1 do
      local vi = virtual_root_indices[idx]
      prefixes[vi] = "│  "
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

-- 用户数据
local items = {
  { is_virtual = true, indent = 0 },
  { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = false, display_text = "👤你好 | 🤖你好！我是你的 AI 编程助…" },
  { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "👤给我讲一个笑话… | 🤖哈哈，没问…" },
  { is_virtual = true, indent = 0 },
  { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = false, display_text = "👤嘿嘿 | 🤖嘿嘿！😊 有什么我可以帮你的…" },
  { is_virtual = false, indent = 2, is_last_session = false, is_last_branch = false, display_text = "👤给我讲一个笑话… | 🤖哈哈，好的…" },
  { is_virtual = true, indent = 1 },
  { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "👤嘿嘿嘿 | 🤖嘿嘿嘿～三连笑，看来心…" },
  { is_virtual = true, indent = 0 },
  { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = true, display_text = "👤给我讲一个故事… | 🤖{\"c…" },
}
local prefixes = build_connectors(items)
local lines = render(items, prefixes)
for _, l in ipairs(lines) do
  print(l)
end
