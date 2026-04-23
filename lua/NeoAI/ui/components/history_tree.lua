--- 历史树组件
--- 基于新的 history_manager 树结构渲染
--- 树结构: 根会话 -> 子会话（多个子会话时自动生成虚拟分支节点）

local M = {}

local state = {
  initialized = false,
  config = nil,
  tree_data = {},
  expanded_nodes = {},
  selected_node_id = nil,
}

function M.initialize(config)
  if state.initialized then return end
  state.config = config or {}
  state.initialized = true
end

function M._load_tree_data()
  local ok, history_mgr = pcall(require, "NeoAI.core.history_manager")
  if not ok or not history_mgr.is_initialized() then
    state.tree_data = {}
    return
  end
  state.tree_data = history_mgr.get_tree() or {}
  local function expand_all(nodes)
    for _, node in ipairs(nodes) do
      state.expanded_nodes[node.id] = true
      if node.children and #node.children > 0 then
        expand_all(node.children)
      end
    end
  end
  expand_all(state.tree_data)
end

function M.refresh(session_id)
  M._load_tree_data()
  if state.config.on_update then
    state.config.on_update(session_id, state.tree_data)
  end
end

function M.get_tree_data()
  if vim.deepcopy then
    return vim.deepcopy(state.tree_data)
  end
  return state.tree_data
end

function M.set_tree_data(data)
  state.tree_data = data or {}
end

function M.clear()
  state.tree_data = {}
  state.expanded_nodes = {}
  state.selected_node_id = nil
end

function M.expand_node(node_id)
  state.expanded_nodes[node_id] = true
end

function M.collapse_node(node_id)
  state.expanded_nodes[node_id] = nil
end

function M.get_expanded_nodes()
  local nodes = {}
  for id, _ in pairs(state.expanded_nodes) do
    table.insert(nodes, id)
  end
  return nodes
end

function M.set_expanded_nodes(nodes)
  state.expanded_nodes = {}
  for _, id in ipairs(nodes) do
    state.expanded_nodes[id] = true
  end
end

function M.select_node(node_id)
  state.selected_node_id = node_id
end

function M.get_selected_node()
  return state.selected_node_id
end

function M.get_selected_item()
  if not state.selected_node_id then return nil end
  local function find(nodes)
    for _, node in ipairs(nodes) do
      if node.id == state.selected_node_id then return node end
      if node.children then
        local found = find(node.children)
        if found then return found end
      end
    end
    return nil
  end
  return find(state.tree_data)
end

function M.find_node(predicate)
  local function find(nodes)
    for _, node in ipairs(nodes) do
      if predicate(node) then return node end
      if node.children then
        local found = find(node.children)
        if found then return found end
      end
    end
    return nil
  end
  return find(state.tree_data)
end

function M.get_node_path(node_id)
  local path = {}
  local function find(nodes, current_path)
    for _, node in ipairs(nodes) do
      local new_path = vim.deepcopy(current_path)
      table.insert(new_path, node.id)
      if node.id == node_id then return new_path end
      if node.children then
        local found = find(node.children, new_path)
        if found then return found end
      end
    end
    return nil
  end
  return find(state.tree_data, {}) or {}
end

function M.get_children(node_id)
  local node = M.find_node(function(n) return n.id == node_id end)
  return node and node.children or {}
end

function M.get_parent(node_id)
  local function find(nodes, parent)
    for _, node in ipairs(nodes) do
      if node.id == node_id then return parent end
      if node.children then
        local found = find(node.children, node)
        if found then return found end
      end
    end
    return nil
  end
  return find(state.tree_data, nil)
end

function M.build_tree(session_id)
  M._load_tree_data()
  return M.get_tree_data()
end

function M.build_tree_async(session_id, callback)
  local async_worker = require("NeoAI.utils.async_worker")
  async_worker.submit_task("build_history_tree", function()
    M._load_tree_data()
    return M.get_tree_data()
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
