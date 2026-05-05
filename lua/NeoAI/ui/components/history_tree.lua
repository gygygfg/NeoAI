--- 历史树组件
--- 接收 history_manager 传来的扁平化数组，按深度优先排序，
--- 计算 is_last、缩进级别、连接符数组。
--- 输出可直接渲染的列表。

local M = {}

local state_manager = require("NeoAI.core.config.state")

local state = {
  initialized = false,
  config = nil,
  flat_items = {}, -- 最终渲染列表，每个元素是 { id, session_id, name, indent, connectors, is_last_session, is_last_branch, ... }
  selected_node_id = nil,
}

function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = config or {}
  state.initialized = true

  -- 注册状态切片
  state_manager.register_slice("history_tree", {
    config = state.config,
    flat_items = {},
    selected_node_id = nil,
  })
end

--- 引用 history_manager 的 build_round_text（带本地缓存）
local _round_text_cache = {}
local function build_round_text(session)
  if not session or not session.id then
    return ""
  end
  if _round_text_cache[session.id] ~= nil then
    return _round_text_cache[session.id]
  end
  local ok, hm = pcall(require, "NeoAI.core.history.manager")
  if ok and hm.build_round_text then
    local text = hm.build_round_text(session)
    _round_text_cache[session.id] = text
    return text
  end
  return ""
end

--- 清除本地 round_text 缓存
local function clear_round_text_cache()
  _round_text_cache = {}
end

--- 从 history_manager 获取扁平会话列表，构建渲染列表
function M.build_flat_items()
  -- 每次重建时清除缓存
  clear_round_text_cache()

  local ok, hm = pcall(require, "NeoAI.core.history.manager")
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

    -- 跳过既没有 user 内容也没有 assistant 内容的空会话
    -- 这些是 send_message 中创建但 AI 回复尚未完成的中间状态会话
    local has_user_content = session.user and session.user ~= ""
    local has_assistant_content = false
    if session.assistant and type(session.assistant) == "table" and #session.assistant > 0 then
      has_assistant_content = true
    elseif session.assistant and type(session.assistant) == "string" and session.assistant ~= "" then
      has_assistant_content = true
    end
    if not has_user_content and not has_assistant_content then
      -- 空会话：不渲染自身，但递归处理子会话（如果有的话）
      local child_ids = session.child_ids or {}
      if #child_ids > 0 then
        local child_ancestor_is_last = {}
        if ancestor_is_last then
          for i = 1, #ancestor_is_last do
            child_ancestor_is_last[i] = ancestor_is_last[i]
          end
        end
        child_ancestor_is_last[depth + 1] = (sibling_index == sibling_count)
        for i, cid in ipairs(child_ids) do
          dfs(cid, parent_indent, depth, i, #child_ids, child_ancestor_is_last)
        end
      end
      return
    end

    -- 缩进级别：父缩进 + 兄弟数 - 当前索引
    -- 单链时（sibling_count=1），子节点缩进 = 父缩进（同级别）
    -- 分支时，子节点缩进递增
    local indent
    if parent_indent == -1 then
      indent = 1
    else
      indent = parent_indent + sibling_count - sibling_index
    end

    local child_ids = session.child_ids or {}
    local has_children = #child_ids > 0
    local is_last_session = #child_ids == 0  -- child_ids 是否为空数组，决定 └─/├─
    local is_last_branch = (sibling_index == sibling_count)  -- 当前节点是否是兄弟中的最后一个（决定连接符 │）
    local sibling_is_last = is_last_branch

    -- 计算连接符数组
    -- 对于每个深度层级 i（1-based）：
    --   如果 i <= depth：根据 ancestor_is_last[i] 决定是 "   " 还是 "│  "
    --   如果 i > depth：根据 sibling_is_last 决定
    --     如果 sibling_is_last（最后一个兄弟），后面没有更多兄弟了，用 "   "
    --     否则用 "│  "（后面还有兄弟）
    -- 注意：connectors 数组长度至少为 depth（祖先层级数），不足部分用空格填充
    local connectors_len = math.max(indent, depth)
    local connectors = {}
    for i = 1, connectors_len do
      if i <= depth then
        if ancestor_is_last and ancestor_is_last[i] then
          connectors[i] = "   "
        else
          connectors[i] = "│  "
        end
      else
        -- i > depth：这些是当前节点之后的层级，根据 sibling_is_last 决定
        if sibling_is_last then
          connectors[i] = "   "
        else
          connectors[i] = "│  "
        end
      end
    end

    -- 判断节点类型
    -- has_content: user 有内容，或 assistant 中有工具调用/回复内容
    local has_user_content = session.user and session.user ~= ""
    local has_assistant_content = false
    if session.assistant and type(session.assistant) == "table" and #session.assistant > 0 then
      has_assistant_content = true
    elseif session.assistant and type(session.assistant) == "string" and session.assistant ~= "" then
      has_assistant_content = true
    end
    local has_content = has_user_content or has_assistant_content
    local is_branch = has_children and not has_content
    local is_multi_child = #(session.child_ids or {}) >= 2
    local display_type = is_branch and "branch" or "leaf"

    -- 构建显示文本
    -- 优先显示会话名称（如果不是默认名称且不为空），否则显示轮次预览
    local default_names = {"聊天会话", "新会话", "子会话", "分支", "会话"}
    local is_default_name = false
    if session.name and session.name ~= "" then
      for _, dn in ipairs(default_names) do
        if session.name == dn or session.name:find("^" .. dn) then
          is_default_name = true
          break
        end
      end
    end

    local display_text
    if is_branch then
      display_text = "聊天会话分支"
    elseif session.name and session.name ~= "" and not is_default_name then
      -- 有自定义名称且非默认，直接显示名称
      display_text = session.name
    else
      -- 默认名称或空名称，显示轮次预览
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
      is_last_session = is_last_session,
      is_last_branch = is_last_branch,
      indent = indent,
      connectors = connectors,
    }
    table.insert(flat_nodes, node)

    -- 在分支节点后面插入虚拟节点（与父节点同级）
    -- 当 child_ids 有多个（>=2）时，也插入虚拟节点
    if is_branch or is_multi_child then
      local virtual_connectors_len = math.max(indent, depth)
      local virtual_connectors = {}
      for i = 1, virtual_connectors_len do
        if i <= depth then
          if ancestor_is_last and ancestor_is_last[i] then
            virtual_connectors[i] = "   "
          else
            virtual_connectors[i] = "│  "
          end
        else
          -- i > depth：根据 sibling_is_last 决定
          if sibling_is_last then
            virtual_connectors[i] = "   "
          else
            virtual_connectors[i] = "│  "
          end
        end
      end
      local virtual_node = {
        is_virtual = true,
        indent = indent,
        connectors = virtual_connectors,
      }
      table.insert(flat_nodes, virtual_node)
    end

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
      child_ancestor_is_last[depth + 1] = sibling_is_last

      for i, cid in ipairs(child_ids) do
        dfs(cid, indent, depth + 1, i, #child_ids, child_ancestor_is_last)
      end
    end
  end

  -- 过滤掉空的根会话（既没有 user 也没有 assistant 内容）
  local non_empty_root_ids = {}
  for _, rid in ipairs(root_ids) do
    local session = session_map[rid]
    if session then
      local has_user = session.user and session.user ~= ""
      local has_assistant = false
      if session.assistant and type(session.assistant) == "table" and #session.assistant > 0 then
        has_assistant = true
      elseif session.assistant and type(session.assistant) == "string" and session.assistant ~= "" then
        has_assistant = true
      end
      if has_user or has_assistant or #(session.child_ids or {}) > 0 then
        table.insert(non_empty_root_ids, rid)
      end
    end
  end

  -- 遍历每个根会话
  for i, rid in ipairs(non_empty_root_ids) do
    -- 在根节点前面插入虚拟节点（indent=0）
    -- 第一个根虚拟节点前面不需要连接符（树的开始）
    -- 非最后一个根节点，虚拟节点前面需要 │  来连接后续的根节点
    local root_virtual_connectors = {}
    if i == 1 then
      -- 第一个根虚拟节点，前面不需要连接符
      root_virtual_connectors[1] = "   "
    elseif i == #non_empty_root_ids then
      -- 最后一个根虚拟节点，前面不需要连接符（下面没有更多根节点了）
      root_virtual_connectors[1] = "   "
    else
      -- 中间的根虚拟节点，前面需要 │  连接后续根节点
      root_virtual_connectors[1] = "│  "
    end
    local root_virtual_node = {
      is_virtual = true,
      indent = 0,
      connectors = root_virtual_connectors,
    }
    table.insert(flat_nodes, root_virtual_node)

    dfs(rid, -1, 0, i, #non_empty_root_ids, {})
  end

  state.flat_items = flat_nodes
  -- 同步到状态切片
  state_manager.set_state("history_tree", "flat_items", flat_nodes)
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
  state_manager.set_state("history_tree", "flat_items", {})
  state_manager.set_state("history_tree", "selected_node_id", nil)
end

--- 选中节点
function M.select_node(node_id)
  state.selected_node_id = node_id
  state_manager.set_state("history_tree", "selected_node_id", node_id)
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
