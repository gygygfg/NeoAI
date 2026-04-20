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

  if vim and vim.notify then
    vim.notify("历史树已刷新", vim.log.levels.INFO)
  end
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
  
  -- 尝试从历史管理器加载会话数据
  local history_manager = require("NeoAI.core.history_manager")
  local sessions = history_manager.get_sessions()
  
  if not sessions or #sessions == 0 then
    -- 如果没有会话数据，尝试从会话管理器加载
    local session_manager = require("NeoAI.core.session.session_manager")
    sessions = session_manager.list_sessions()
    
    if not sessions or #sessions == 0 then
      -- 如果还是没有数据，尝试从文件系统加载
      sessions = M._load_sessions_from_file()
    end
  end
  
  -- 转换会话数据为树节点
  for _, session in ipairs(sessions) do
    local session_node = {
      id = "session_" .. session.id,
      name = session.name or "未命名会话",
      type = "session",
      metadata = {
        message_count = session.metadata and session.metadata.message_count or 0,
        created_at = session.metadata and session.metadata.created_at or os.time(),
        last_updated = session.metadata and session.metadata.last_updated or os.time(),
      },
      children = {},
      raw_data = session, -- 保存原始数据供后续使用
    }
    
    -- 如果这是当前会话，添加标记
    if session_id and tostring(session.id) == tostring(session_id) then
      session_node.name = session_node.name .. " (当前)"
      session_node.metadata.is_current = true
    end
    
    -- 尝试加载会话的消息作为子节点
    M._load_session_messages(session, session_node)
    
    table.insert(state.tree_data, session_node)
    
    -- 默认展开当前会话
    if session_node.metadata.is_current then
      state.expanded_nodes[session_node.id] = true
    end
  end
  
  -- 如果没有数据，使用模拟数据作为后备
  if #state.tree_data == 0 then
    M._load_fallback_data()
  end
  
  -- 按最后更新时间排序
  table.sort(state.tree_data, function(a, b)
    return (a.metadata.last_updated or 0) > (b.metadata.last_updated or 0)
  end)
end

--- 从文件系统加载会话数据
--- @return table 会话列表
function M._load_sessions_from_file()
  local sessions = {}
  
  -- 获取保存路径
  local config = state.config or {}
  local save_path = config.save_path or os.getenv("HOME") .. "/.cache/nvim/NeoAI"
  local sessions_file = save_path .. "/sessions.json"
  
  -- 检查文件是否存在
  if vim.fn.filereadable(sessions_file) == 1 then
    local content = vim.fn.readfile(sessions_file)
    if #content > 0 then
      local success, data = pcall(vim.json.decode, table.concat(content, "\n"))
      if success and data then
        -- 转换数据格式
        for session_id, session_data in pairs(data) do
          if type(session_data) == "table" and session_data.id then
            table.insert(sessions, {
              id = session_id,
              name = session_data.name or "会话 " .. session_id,
              metadata = {
                message_count = #(session_data.messages or {}),
                created_at = session_data.created_at or os.time(),
                last_updated = session_data.updated_at or os.time(),
              },
              messages = session_data.messages or {},
            })
          end
        end
      end
    end
  end
  
  return sessions
end

--- 加载会话消息作为子节点
--- @param session table 会话数据
--- @param session_node table 会话节点
function M._load_session_messages(session, session_node)
  if not session or not session_node then
    return
  end
  
  -- 获取消息数据
  local messages = session.messages or {}
  
  -- 如果没有消息数据，尝试从其他来源获取
  if #messages == 0 and session.raw_data and session.raw_data.messages then
    messages = session.raw_data.messages
  end
  
  -- 限制显示的消息数量
  local max_messages = state.config and state.config.max_messages_per_session or 10
  local display_messages = {}
  
  for i = math.max(1, #messages - max_messages + 1), #messages do
    table.insert(display_messages, messages[i])
  end
  
  -- 创建消息节点
  for i, msg in ipairs(display_messages) do
    local msg_content = msg.content or ""
    local truncated_content = msg_content
    
    -- 截断过长的内容
    if #truncated_content > 50 then
      truncated_content = truncated_content:sub(1, 47) .. "..."
    end
    
    local msg_node = {
      id = "msg_" .. session.id .. "_" .. (msg.id or i),
      name = "[" .. (msg.role or "unknown") .. "] " .. truncated_content,
      type = "message",
      metadata = {
        role = msg.role,
        timestamp = msg.timestamp or os.time(),
        full_content = msg_content,
        message_id = msg.id,
      },
      children = {},
      raw_data = msg,
    }
    
    table.insert(session_node.children, msg_node)
  end
  
  -- 更新消息计数
  session_node.metadata.message_count = #messages
end

--- 加载后备数据（模拟数据）
function M._load_fallback_data()
  state.tree_data = {
    {
      id = "session_1",
      name = "示例会话",
      type = "session",
      metadata = {
        message_count = 2,
        created_at = os.time() - 3600,
        last_updated = os.time() - 1800,
      },
      children = {
        {
          id = "msg_1_1",
          name = "[user] 你好",
          type = "message",
          metadata = {
            role = "user",
            timestamp = os.time() - 3600,
            full_content = "你好",
          },
          children = {},
        },
        {
          id = "msg_1_2",
          name = "[assistant] 你好！有什么可以帮助你的？",
          type = "message",
          metadata = {
            role = "assistant",
            timestamp = os.time() - 1800,
            full_content = "你好！有什么可以帮助你的？",
          },
          children = {},
        },
      },
    },
  }
  
  -- 默认展开根节点
  for _, root_node in ipairs(state.tree_data) do
    state.expanded_nodes[root_node.id] = true
  end
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

-- 测试函数
local function test_module()
  print("=== 测试历史树模块 ===")

  -- 初始化模块
  M.initialize({
    on_update = function(session_id, data)
      print("配置更新回调: 会话ID=" .. (session_id or "nil") .. ", 数据节点数=" .. #data)
    end,
  })

  -- 构建树
  local tree_data = M.build_tree("test_session")
  print("树数据加载完成，根节点数: " .. #tree_data)

  -- 展开节点
  M.expand_node("branch_1")
  print("已展开节点: branch_1")

  -- 选择节点
  M.select_node("branch_2")
  print("已选择节点: " .. (M.get_selected_node() or "nil"))

  -- 获取选中项目
  local selected = M.get_selected_item()
  if selected then
    print("选中节点名称: " .. selected.name)
  end

  -- 获取展开节点
  local expanded = M.get_expanded_nodes()
  print("展开节点数: " .. #expanded)

  -- 添加新节点
  local new_node = {
    id = "new_node_1",
    name = "新节点",
    type = "message",
    content = "测试消息",
  }

  local added = M.add_node("branch_2", new_node)
  print("添加节点结果: " .. tostring(added))

  -- 查找节点
  local found = M.find_node(function(node)
    return node.name == "新节点"
  end)

  if found then
    print("找到节点: " .. found.id)
  end

  -- 获取父节点
  local parent = M.get_parent("new_node_1")
  if parent then
    print("父节点: " .. parent.name)
  end

  -- 删除节点
  local deleted = M.delete_node("new_node_1")
  print("删除节点结果: " .. tostring(deleted))

  -- 移动节点
  local moved = M.move_node("branch_2", "session_2")
  print("移动节点结果: " .. tostring(moved))

  -- 刷新树
  M.refresh("test_session")

  print("=== 测试完成 ===")
end

-- 运行测试
if not vim then
  -- 非Neovim环境下运行测试
  test_module()
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

  return M
