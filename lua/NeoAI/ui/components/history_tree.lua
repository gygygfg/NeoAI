--- 历史树组件
--- 接收 history_manager 传来的扁平化数组，按深度优先排序，
--- 计算 is_last、缩进级别、连接符数组。
--- 输出可直接渲染的列表。

local M = {}

local state = {
  initialized = false,
  config = nil,
  flat_items = {}, -- 最终渲染列表，每个元素是 { id, session_id, name, indent, connectors, is_last, ... }
  selected_node_id = nil,
}

function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = config or {}
  state.initialized = true
end

--- 构建轮次预览文本
local function build_round_text(session)
  if not session then
    return ""
  end
  local text = ""
  if session.user and session.user ~= "" then
    local user_preview = session.user:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #user_preview > 20 then
      user_preview = user_preview:sub(1, 20) .. "…"
    end
    text = "👤" .. user_preview
  end
  if
    session.assistant
    and (
      (type(session.assistant) == "table" and #session.assistant > 0)
      or (type(session.assistant) == "string" and session.assistant ~= "")
    )
  then
    local ai_text = ""
    local last_entry = session.assistant
    if type(session.assistant) == "table" and #session.assistant > 0 then
      last_entry = session.assistant[#session.assistant]
    end
    -- 尝试解析 JSON 字符串
    if type(last_entry) == "string" then
      local ok2, parsed = pcall(vim.json.decode, last_entry)
      if ok2 and type(parsed) == "table" then
        -- 可能是 {content="..."} 或 [{content="..."}, ...]
        if parsed.content then
          ai_text = parsed.content
        elseif #parsed > 0 and type(parsed[1]) == "table" and parsed[1].content then
          ai_text = parsed[1].content
        else
          ai_text = last_entry
        end
      else
        -- 不是 JSON，直接使用字符串
        ai_text = last_entry
      end
    elseif type(last_entry) == "table" and last_entry.content then
      ai_text = last_entry.content
    end
    local ai_preview = ai_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #ai_preview > 20 then
      ai_preview = ai_preview:sub(1, 20) .. "…"
    end
    if text ~= "" then
      text = text .. " | 🤖" .. ai_preview
    else
      text = "🤖" .. ai_preview
    end
  end
  return text
end

--- 从 history_manager 获取扁平会话列表，构建渲染列表
function M.build_flat_items()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if not ok or not hm.is_initialized() then
    state.flat_items = {}
    return {}
  end

  local sessions = hm.list_sessions() or {}
  if #sessions == 0 then
    state.flat_items = {}
    return {}
  end

  -- 构建 id -> 完整会话 映射
  local session_map = {}
  for _, s in ipairs(sessions) do
    local full = hm.get_session(s.id)
    if full then
      session_map[s.id] = full
    end
  end

  -- 获取根会话（按 created_at 排序）
  local root_ids = {}
  for _, s in ipairs(sessions) do
    if s.is_root then
      table.insert(root_ids, s.id)
    end
  end
  table.sort(root_ids, function(a, b)
    local sa = session_map[a]
    local sb = session_map[b]
    return (sa and sa.created_at or 0) < (sb and sb.created_at or 0)
  end)

  -- 深度优先遍历，收集扁平节点
  local flat_nodes = {}

  --- 深度优先遍历
  --- @param session_id string 当前会话ID
  --- @param parent_indent number 父节点的缩进级别
  --- @param depth number 当前深度（从0开始，根节点深度为0）
  --- @param sibling_index number 当前节点在兄弟中的序号（从1开始）
  --- @param sibling_count number 兄弟节点总数
  --- @param ancestor_is_last table 每个深度层级是否是最后一个兄弟
  ---   索引从1开始，ancestor_is_last[1] 表示深度0（根层级）是否是最后
  local function dfs(session_id, parent_indent, depth, sibling_index, sibling_count, ancestor_is_last)
    local session = session_map[session_id]
    if not session then
      return
    end

    -- 缩进级别：父缩进 + 兄弟数 - 当前索引
    -- 单链时（sibling_count=1），子节点缩进 = 父缩进（同级别）
    -- 分支时，子节点缩进递增
    local indent
    if parent_indent == -1 then
      indent = 0
    else
      indent = parent_indent + sibling_count - sibling_index
    end

    local is_last = (sibling_index == sibling_count)
    local has_children = #(session.child_ids or {}) > 0

    -- 计算连接符数组
    -- 前 depth 个元素基于 ancestor_is_last 决定是 "│  " 还是 "   "
    -- 从 depth+1 到 indent 的元素用 "   "
    local connectors = {}
    for i = 1, indent do
      if i <= depth then
        if ancestor_is_last and ancestor_is_last[i] then
          connectors[i] = "   "
        else
          connectors[i] = "│  "
        end
      else
        connectors[i] = "   "
      end
    end

    -- 判断节点类型
    local has_content = session.user and session.user ~= ""
    local is_branch = has_children and not has_content
    local display_type = is_branch and "branch" or "leaf"

    -- 构建显示文本
    local display_text
    if is_branch then
      display_text = "聊天会话分支"
    else
      display_text = build_round_text(session)
      if display_text == "" then
        display_text = session.name or "未命名"
      end
    end

    local node = {
      id = session.id,
      session_id = session.id,
      display_type = display_type,
      display_text = display_text,
      is_virtual = false,
      is_separator = false,
      is_last = is_last,
      indent = indent,
      connectors = connectors,
    }
    table.insert(flat_nodes, node)

    -- 递归处理子会话
    local child_ids = session.child_ids or {}
    if #child_ids > 0 then
      -- 构建子节点的 ancestor_is_last
      local child_ancestor_is_last = {}
      if ancestor_is_last then
        for i = 1, #ancestor_is_last do
          child_ancestor_is_last[i] = ancestor_is_last[i]
        end
      end
      child_ancestor_is_last[depth + 1] = is_last

      for i, cid in ipairs(child_ids) do
        dfs(cid, indent, depth + 1, i, #child_ids, child_ancestor_is_last)
      end
    end
  end

  -- 遍历每个根会话
  for i, rid in ipairs(root_ids) do
    dfs(rid, -1, 0, i, #root_ids, {})

    -- 在根会话之间插入空行分隔
    if i < #root_ids then
      local separator = {
        id = "__sep_" .. rid,
        session_id = nil,
        display_type = "separator",
        display_text = "",
        is_virtual = true,
        is_separator = true,
        is_last = true,
        indent = 0,
        connectors = {},
      }
      table.insert(flat_nodes, separator)
    end
  end

  state.flat_items = flat_nodes
  return flat_nodes
end

--- 获取渲染列表
function M.get_flat_items()
  return state.flat_items
end

--- 刷新
function M.refresh(session_id)
  M.build_flat_items()
  if state.config.on_update then
    state.config.on_update(session_id, state.flat_items)
  end
end

--- 清空
function M.clear()
  state.flat_items = {}
  state.selected_node_id = nil
end

--- 选中节点
function M.select_node(node_id)
  state.selected_node_id = node_id
end

--- 获取选中节点ID
function M.get_selected_node()
  return state.selected_node_id
end

--- 获取选中节点完整信息
function M.get_selected_item()
  if not state.selected_node_id then
    return nil
  end
  for _, item in ipairs(state.flat_items) do
    if item.id == state.selected_node_id then
      return item
    end
  end
  return nil
end

--- 查找节点
function M.find_node(predicate)
  for _, item in ipairs(state.flat_items) do
    if predicate(item) then
      return item
    end
  end
  return nil
end

--- 获取节点路径（所有祖先节点ID列表）
function M.get_node_path(node_id)
  local target = nil
  local target_idx = nil
  for i, item in ipairs(state.flat_items) do
    if item.id == node_id then
      target = item
      target_idx = i
      break
    end
  end
  if not target or not target_idx then
    return {}
  end

  local path = {}
  local target_indent = target.indent
  for i = target_idx, 1, -1 do
    local item = state.flat_items[i]
    if item.is_separator then
      break
    end
    if item.indent <= target_indent then
      table.insert(path, 1, item.id)
      target_indent = item.indent - 1
    end
  end
  return path
end

--- 获取子节点
function M.get_children(node_id)
  local item = nil
  for _, it in ipairs(state.flat_items) do
    if it.id == node_id then
      item = it
      break
    end
  end
  if not item then
    return {}
  end

  local found = false
  local children = {}
  local start_indent = item.indent
  for _, it in ipairs(state.flat_items) do
    if it.id == node_id then
      found = true
    elseif found then
      if it.indent <= start_indent then
        break
      end
      table.insert(children, it)
    end
  end
  return children
end

--- 获取父节点
function M.get_parent(node_id)
  local target_idx = nil
  for i, item in ipairs(state.flat_items) do
    if item.id == node_id then
      target_idx = i
      break
    end
  end
  if not target_idx then
    return nil
  end

  local target = state.flat_items[target_idx]
  for i = target_idx - 1, 1, -1 do
    local item = state.flat_items[i]
    if item.is_separator then
      return nil
    end
    if item.indent < target.indent then
      return item
    end
  end
  return nil
end

--- 构建树（兼容旧接口）
function M.build_tree(session_id)
  M.build_flat_items()
  return M.get_flat_items()
end

--- 异步构建
function M.build_tree_async(session_id, callback)
  local async_worker = require("NeoAI.utils.async_worker")
  async_worker.submit_task("build_history_tree", function()
    M.build_flat_items()
    return M.get_flat_items()
  end, function(success, data)
    if callback then
      callback(success and data or {})
    end
  end)
end

function M.update_config(new_config)
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

function M.is_initialized()
  return state.initialized
end

return M
