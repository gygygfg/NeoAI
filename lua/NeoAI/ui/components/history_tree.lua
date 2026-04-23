--- @class HistoryTreeModule
--- @field build_tree fun(session_id: string?): table
--- @field build_tree_async fun(session_id: string?, callback: fun(data: table)): nil
--- @field get_tree_data fun(): table
--- @field set_tree_data fun(data: table): nil
--- @field clear_tree_data fun(): nil
--- @field get_expanded_nodes fun(): table
--- @field set_expanded_nodes fun(nodes: table): nil
--- @field get_selected_node_id fun(): string?
--- @field set_selected_node_id fun(node_id: string?): nil
--- @field initialize fun(config: table): nil
--- @field is_initialized fun(): boolean

local M = {}

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  tree_data = {},
  expanded_nodes = {},
  selected_node_id = nil,
}

--- 初始化历史树组件
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end

  state.config = config or {}
  state.initialized = true
end

--- 渲染历史树
--- @param session_id string 会话ID
function M.render(session_id)
  if not state.initialized then
    return nil
  end

  -- 加载树数据
  M._load_tree_data(session_id)

  -- 这里应该返回渲染后的树数据
  -- 目前只是返回树数据
  return state.tree_data
end

--- 展开节点
--- @param node_id string 节点ID
function M.expand_node(node_id)
  if not state.initialized then
    return
  end

  state.expanded_nodes[node_id] = true
end

--- 折叠节点
--- @param node_id string 节点ID
function M.collapse_node(node_id)
  if not state.initialized then
    return
  end

  state.expanded_nodes[node_id] = nil
end

--- 更新历史树
--- @param session_id string 会话ID
--- @param new_data table 新数据
function M.update(session_id, new_data)
  if not state.initialized then
    return
  end

  -- 更新树数据
  state.tree_data = new_data or {}

  -- 触发更新事件
  if state.config.on_update then
    state.config.on_update(session_id, state.tree_data)
  end
end

--- 获取选中的项目
--- @return table|nil 选中的节点
function M.get_selected_item()
  if not state.initialized or not state.selected_node_id then
    return nil
  end

  -- 在树数据中查找选中的节点
  local function find_node(nodes, node_id)
    for _, node in ipairs(nodes) do
      if node.id == node_id then
        return node
      end

      if node.children then
        local found = find_node(node.children, node_id)
        if found then
          return found
        end
      end
    end

    return nil
  end

  return find_node(state.tree_data, state.selected_node_id)
end

--- 选择节点
--- @param node_id string 节点ID
function M.select_node(node_id)
  if not state.initialized then
    return
  end

  state.selected_node_id = node_id
end

--- 更新节点
--- @param node_id string 节点ID
--- @param data table 节点数据
function M.update_node(node_id, data)
  if not state.initialized then
    return
  end

  -- 查找并更新节点
  local function update_node_recursive(nodes)
    for _, node in ipairs(nodes) do
      if node.id == node_id then
        for k, v in pairs(data) do
          node[k] = v
        end
        return true
      end

      if node.children and #node.children > 0 then
        if update_node_recursive(node.children) then
          return true
        end
      end
    end

    return false
  end

  update_node_recursive(state.tree_data)
end

--- 获取选中节点
--- @return string|nil 选中节点ID
function M.get_selected_node()
  return state.selected_node_id
end

--- 获取树数据
--- @return table 树数据
function M.get_tree_data()
  -- 使用vim.deepcopy进行深拷贝
  if vim and vim.deepcopy then
    return vim.deepcopy(state.tree_data)
  else
    -- 简单的深拷贝实现（用于测试）
    local function deepcopy(orig)
      local orig_type = type(orig)
      local copy
      if orig_type == "table" then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
          copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig)))
      else
        copy = orig
      end
      return copy
    end
    return deepcopy(state.tree_data)
  end
end

--- 获取展开的节点
--- @return table 展开的节点ID列表
function M.get_expanded_nodes()
  local nodes = {}
  for node_id, _ in pairs(state.expanded_nodes) do
    table.insert(nodes, node_id)
  end
  return nodes
end

--- 清空树数据
function M.clear()
  state.tree_data = {}
  state.expanded_nodes = {}
  state.selected_node_id = nil
end

--- 查找节点
--- @param predicate function 谓词函数
--- @return table|nil 找到的节点
function M.find_node(predicate)
  if not state.initialized or type(predicate) ~= "function" then
    return nil
  end

  local function find_recursive(nodes)
    for _, node in ipairs(nodes) do
      if predicate(node) then
        return node
      end

      if node.children and #node.children > 0 then
        local found = find_recursive(node.children)
        if found then
          return found
        end
      end
    end

    return nil
  end

  return find_recursive(state.tree_data)
end

--- 获取节点路径
--- @param node_id string 节点ID
--- @return table 节点路径
function M.get_node_path(node_id)
  if not state.initialized then
    return {}
  end

  local path = {}

  local function find_path_recursive(nodes, current_path)
    for _, node in ipairs(nodes) do
      local new_path = {}
      for _, v in ipairs(current_path) do
        table.insert(new_path, v)
      end
      table.insert(new_path, node.id)

      if node.id == node_id then
        return new_path
      end

      if node.children and #node.children > 0 then
        local found = find_path_recursive(node.children, new_path)
        if found then
          return found
        end
      end
    end

    return nil
  end

  return find_path_recursive(state.tree_data, {}) or {}
end

--- 获取子节点
--- @param node_id string 节点ID
--- @return table 子节点列表
function M.get_children(node_id)
  if not state.initialized then
    return {}
  end

  local node = M.find_node(function(n)
    return n.id == node_id
  end)

  if node and node.children then
    -- 深拷贝子节点
    if vim and vim.deepcopy then
      return vim.deepcopy(node.children)
    else
      local copy = {}
      for i, child in ipairs(node.children) do
        copy[i] = { id = child.id, name = child.name, type = child.type }
        if child.children then
          copy[i].children = {}
          for j, grandchild in ipairs(child.children) do
            copy[i].children[j] = { id = grandchild.id, name = grandchild.name, type = grandchild.type }
          end
        end
      end
      return copy
    end
  end

  return {}
end

--- 获取父节点
--- @param node_id string 节点ID
--- @return table|nil 父节点
function M.get_parent(node_id)
  if not state.initialized then
    return nil
  end

  local function find_parent_recursive(nodes, parent)
    for _, node in ipairs(nodes) do
      if node.id == node_id then
        return parent
      end

      if node.children and #node.children > 0 then
        local found = find_parent_recursive(node.children, node)
        if found then
          return found
        end
      end
    end

    return nil
  end

  return find_parent_recursive(state.tree_data, nil)
end

--- 构建树
--- @param session_id string 会话ID
--- @return table 构建的树数据
function M.build_tree(session_id)
  if not state.initialized then
    return {}
  end

  -- 加载树数据
  M._load_tree_data(session_id)

  -- 返回构建的树数据
  return M.get_tree_data()
end

--- 刷新树
--- @param session_id string 会话ID
function M.refresh(session_id)
  if not state.initialized then
    return
  end

  -- 重新加载树数据
  M._load_tree_data(session_id)

  -- 触发更新事件
  if state.config.on_update then
    state.config.on_update(session_id, state.tree_data)
  end

  -- vim.notify("历史树已刷新", vim.log.levels.INFO)
end

--- 获取指定行的节点
--- @param line_number number 行号（1-based）
--- @return table|nil 节点数据
function M.get_node_at_line(line_number)
  if not state.initialized then
    return nil
  end

  -- 这里需要根据实际的树渲染逻辑来获取节点
  -- 由于我们不知道具体的渲染实现，这里返回一个模拟节点
  if line_number > 0 and line_number <= #state.tree_data then
    if vim and vim.deepcopy then
      return vim.deepcopy(state.tree_data[line_number])
    else
      local node = state.tree_data[line_number]
      return { id = node.id, name = node.name, type = node.type }
    end
  end

  return nil
end

--- 查找节点的父节点
--- @param node_id string 节点ID
--- @return table|nil 父节点，如果找不到返回nil
function M.find_parent(node_id)
  if not state.initialized then
    return nil
  end

  local function find_parent_recursive(nodes, parent)
    for _, node in ipairs(nodes) do
      if node.id == node_id then
        return parent
      end

      if node.children and #node.children > 0 then
        local found = find_parent_recursive(node.children, node)
        if found then
          return found
        end
      end
    end

    return nil
  end

  return find_parent_recursive(state.tree_data, nil)
end

--- 添加节点
--- @param parent_id string|nil 父节点ID
--- @param node_data table 节点数据
--- @return boolean 是否添加成功
function M.add_node(parent_id, node_data)
  if not state.initialized or not node_data or not node_data.id then
    return false
  end

  if not parent_id then
    -- 添加到根节点
    table.insert(state.tree_data, node_data)
    return true
  end

  local parent = M.find_node(function(n)
    return n.id == parent_id
  end)

  if not parent then
    return false
  end

  if not parent.children then
    parent.children = {}
  end

  table.insert(parent.children, node_data)
  return true
end

--- 删除节点
--- @param node_id string 节点ID
--- @return boolean 是否删除成功
function M.delete_node(node_id)
  if not state.initialized then
    return false
  end

  local function delete_recursive(nodes)
    for i, node in ipairs(nodes) do
      if node.id == node_id then
        table.remove(nodes, i)

        -- 从展开节点中移除
        state.expanded_nodes[node_id] = nil

        -- 如果删除的是选中节点，清空选中
        if state.selected_node_id == node_id then
          state.selected_node_id = nil
        end

        return true
      end

      if node.children and #node.children > 0 then
        if delete_recursive(node.children) then
          return true
        end
      end
    end

    return false
  end

  return delete_recursive(state.tree_data)
end

--- 移动节点
--- @param node_id string 节点ID
--- @param new_parent_id string 新父节点ID
--- @return boolean 是否移动成功
function M.move_node(node_id, new_parent_id)
  if not state.initialized then
    return false
  end

  -- 查找节点
  local node_to_move = nil
  local old_parent_nodes = nil
  local node_index = nil

  local function find_node_recursive(nodes, parent_nodes)
    for i, node in ipairs(nodes) do
      if node.id == node_id then
        node_to_move = node
        old_parent_nodes = parent_nodes or nodes
        node_index = i
        return true
      end

      if node.children and #node.children > 0 then
        if find_node_recursive(node.children, node.children) then
          return true
        end
      end
    end

    return false
  end

  if not find_node_recursive(state.tree_data) then
    return false
  end

  -- 从原位置移除
  if old_parent_nodes and node_index then
    table.remove(old_parent_nodes, node_index)
  else
    return false
  end

  -- 添加到新位置
  if not new_parent_id then
    -- 移动到根节点
    table.insert(state.tree_data, node_to_move)
  else
    local new_parent = M.find_node(function(n)
      return n.id == new_parent_id
    end)

    if not new_parent then
      -- 如果找不到新父节点，回滚
      if old_parent_nodes and node_index then
        table.insert(old_parent_nodes, node_index, node_to_move)
      end
      return false
    end

    if not new_parent.children then
      new_parent.children = {}
    end

    table.insert(new_parent.children, node_to_move)
  end

  return true
end

--- 加载树数据（内部使用）
--- @param session_id string 会话ID
function M._load_tree_data(session_id)
  -- 清空现有数据
  state.tree_data = {}

  -- 加载树状结构数据
  M._load_tree_structure(session_id)

  -- 如果没有数据，保持空数据
  if #state.tree_data == 0 then
    print("调试：树数据为空，无可用数据", vim.log.levels.WARN)
  end

  -- 默认展开虚拟根节点
  if #state.tree_data > 0 and state.tree_data[1].type == "virtual_root" then
    state.expanded_nodes[state.tree_data[1].id] = true
  end

  -- 调试：打印最终加载的树数据
  print("调试：最终树数据根节点数量: " .. #state.tree_data, vim.log.levels.INFO)
  for i, node in ipairs(state.tree_data) do
    print(
      "调试：最终根节点 "
        .. i
        .. ": "
        .. (node.name or "未命名")
        .. " (类型: "
        .. (node.type or "未知")
        .. ")",
      vim.log.levels.INFO
    )
    if node.children then
      print("调试：  子节点数量: " .. #node.children, vim.log.levels.INFO)
    end
  end
end

--- 加载树状结构数据（内部使用）
--- @param session_id string 会话ID
function M._load_tree_structure(session_id)
  print("调试：开始加载树状结构数据", vim.log.levels.INFO)

  -- 尝试从树管理器加载数据
  local tree_manager_loaded, tree_manager = pcall(require, "NeoAI.core.session.tree_manager")
  if tree_manager_loaded and tree_manager then
    print("调试：成功加载树管理器模块", vim.log.levels.INFO)

    -- 确保树管理器已初始化
    if tree_manager.is_initialized and not tree_manager.is_initialized() then
      print("调试：初始化树管理器", vim.log.levels.INFO)
      local config = state.config or {}
      tree_manager.initialize({
        event_bus = nil, -- 暂时不需要事件总线
        config = config,
      })
    else
      print("调试：树管理器已初始化", vim.log.levels.INFO)
    end

    -- 获取树状结构
    print("调试：调用 tree_manager.get_tree()", vim.log.levels.INFO)
    local tree_structure = tree_manager.get_tree()

    if tree_structure and #tree_structure > 0 then
      print("调试：从树管理器获取到树结构，节点数量: " .. #tree_structure, vim.log.levels.INFO)

      -- 检查虚拟根节点是否有实际子节点
      local has_real_nodes = false
      for _, node in ipairs(tree_structure) do
        if node.type == "virtual_root" then
          -- 检查虚拟根节点的子节点数量
          if node.children and #node.children > 0 then
            has_real_nodes = true
            print("调试：虚拟根节点有 " .. #node.children .. " 个子节点", vim.log.levels.INFO)
          else
            print("调试：虚拟根节点没有子节点", vim.log.levels.INFO)
          end
        else
          -- 如果有非虚拟根节点的节点，也视为有实际数据
          has_real_nodes = true
          print("调试：发现非虚拟根节点: " .. node.type, vim.log.levels.INFO)
        end
      end

      if has_real_nodes then
        -- 转换树管理器节点为历史树节点
        state.tree_data = M._convert_tree_manager_nodes(tree_structure, session_id)
        print("调试：转换后的树数据根节点数量: " .. #state.tree_data, vim.log.levels.INFO)
        return
      else
        print("调试：树管理器只有虚拟根节点，没有实际数据", vim.log.levels.WARN)
      end
    else
      print("调试：树管理器返回空结构或nil", vim.log.levels.WARN)
    end
  else
    print("调试：无法加载树管理器模块: " .. tostring(tree_manager_loaded), vim.log.levels.WARN)
  end

  -- 如果树管理器没有数据，尝试从 session_manager 同步数据到树管理器
  print("调试：树管理器没有数据，尝试从 session_manager 同步", vim.log.levels.INFO)

  -- 调用 tree_manager.sync_from_session_manager() 同步数据
  if tree_manager.sync_from_session_manager then
    pcall(tree_manager.sync_from_session_manager)

    -- 重新获取树结构
    local retry_structure = tree_manager.get_tree()
    if retry_structure and #retry_structure > 0 then
      local has_real_nodes = false
      for _, node in ipairs(retry_structure) do
        if node.type == "virtual_root" and node.children and #node.children > 0 then
          has_real_nodes = true
          break
        end
      end

      if has_real_nodes then
        print("调试：同步后树管理器有数据了", vim.log.levels.INFO)
        state.tree_data = M._convert_tree_manager_nodes(retry_structure, session_id)
        return
      end
    end
  end

  -- 如果仍然没有数据，返回空
  print("调试：树管理器没有数据，返回空", vim.log.levels.INFO)
  state.tree_data = {}
end

--- 转换树管理器节点为历史树节点（内部使用）
--- @param tree_nodes table 树管理器节点列表
--- @param session_id string 会话ID
--- @return table 历史树节点列表
function M._convert_tree_manager_nodes(tree_nodes, session_id)
  print("调试：开始转换树管理器节点，输入节点数量: " .. #tree_nodes, vim.log.levels.INFO)

  local result = {}

  for i, node in ipairs(tree_nodes) do
    print(
      "调试：转换节点 " .. i .. ": " .. (node.id or "未知ID") .. " (类型: " .. (node.type or "未知") .. ")",
      vim.log.levels.INFO
    )

    local converted_node = {
      id = node.id,
      name = node.name,
      type = node.type,
      metadata = {},
      children = {},
      raw_data = node,
    }

    -- 复制元数据
    if node.metadata then
      converted_node.metadata = vim.deepcopy(node.metadata)
    end

    -- 设置元数据
    if not converted_node.metadata.created_at then
      converted_node.metadata.created_at = node.created_at or os.time()
    end
    if not converted_node.metadata.last_updated then
      converted_node.metadata.last_updated = node.created_at or os.time()
    end

    -- 递归转换子节点
    if node.children and #node.children > 0 then
      print("调试：节点 " .. node.id .. " 有 " .. #node.children .. " 个子节点", vim.log.levels.INFO)
      converted_node.children = M._convert_tree_manager_nodes(node.children, session_id)
    else
      print("调试：节点 " .. node.id .. " 没有子节点", vim.log.levels.INFO)
    end

    table.insert(result, converted_node)
    print("调试：已添加节点 " .. node.id .. " 到结果中", vim.log.levels.INFO)

    -- 默认展开虚拟根节点
    if converted_node.type == "virtual_root" then
      print("调试：设置虚拟根节点展开状态: " .. converted_node.id, vim.log.levels.INFO)
      state.expanded_nodes[converted_node.id] = true
    end
  end

  print("调试：节点转换完成，结果节点数量: " .. #result, vim.log.levels.INFO)
  return result
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

--- 异步构建树
--- @param session_id string 会话ID
--- @param callback function 回调函数
function M.build_tree_async(session_id, callback)
  if not state.initialized then
    if callback then
      callback({})
    end
    return
  end

  -- 使用异步工作器
  local async_worker = require("NeoAI.utils.async_worker")

  async_worker.submit_task("build_history_tree", function()
    -- 在后台线程中加载树数据
    M._load_tree_data(session_id)

    -- 返回构建的树数据
    return M.get_tree_data()
  end, function(success, tree_data, error_msg)
    if callback then
      if success then
        callback(tree_data)
      else
        -- 如果异步失败，回退到同步版本
        local fallback_data = M.build_tree(session_id)
        callback(fallback_data)
      end
    end
  end)
end

--- 检查是否已初始化
--- @return boolean 是否已初始化
function M.is_initialized()
  return state.initialized
end

return M
