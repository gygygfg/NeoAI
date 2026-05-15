--- 用用户实际数据测试 build_connectors
local logger = require("NeoAI.utils.logger")
logger.initialize({
  level = "DEBUG",
  output_path = "/tmp/neoai_test_user_data.log",
  print_debug = false,
})

local function build_connectors(flat_items)
  if not flat_items or #flat_items == 0 then
    return {}
  end
  local n = #flat_items
  local prefixes = {}
  for i = 1, n do
    prefixes[i] = ""
  end
  local needs_line = {}
  for i = 1, n do
    local item = flat_items[i]
    local indent = item.indent or 0
    local parts = {}
    for level = 1, indent do
      if item.is_virtual then
        if needs_line[level] then
          table.insert(parts, "│  ")
        else
          table.insert(parts, "   ")
        end
      elseif level < indent then
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
    prefixes[i] = table.concat(parts)
    if not item.is_virtual then
      needs_line[indent] = not item.is_last_branch
    end
  end
  local first_virtual_root_idx = nil
  for i, item in ipairs(flat_items) do
    if item.is_virtual and item.indent == 0 then
      if first_virtual_root_idx == nil then
        first_virtual_root_idx = i
      else
        prefixes[i] = "│  "
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

-- 模拟用户的数据
local items = {
  { is_virtual = true, indent = 0 },
  { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = false, display_text = "👤你好 | 🤖你好！我是你的 AI 编程助…" },
  { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "👤给我讲一个笑话… | 🤖哈哈，没问…" },
  { is_virtual = true, indent = 0 },
  { is_virtual = false, indent = 1, is_last_session = false, is_last_branch = false, display_text = "👤嘿嘿 | 🤖嘿嘿！😊 有什么我可以帮你的…" },
  { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "👤给我讲一个笑话… | 🤖哈哈，好的…" },
  { is_virtual = true, indent = 1 },
  { is_virtual = false, indent = 2, is_last_session = true, is_last_branch = true, display_text = "👤嘿嘿嘿 | 🤖嘿嘿嘿～三连笑，看来心…" },
  { is_virtual = true, indent = 0 },
  { is_virtual = false, indent = 1, is_last_session = true, is_last_branch = true, display_text = "👤给我讲一个故事… | 🤖{\"c…" },
}
local prefixes = build_connectors(items)
local lines = render(items, prefixes)
for _, l in ipairs(lines) do
  logger.info(l)
end
