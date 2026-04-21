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

  -- 加载树状结构数据
  M._load_tree_structure(session_id)

  -- 如果没有数据，使用模拟数据作为后备
  if #state.tree_data == 0 then
    M._load_fallback_data()
  end

  -- 默认展开虚拟根节点
  if #state.tree_data > 0 and state.tree_data[1].type == "virtual_root" then
    state.expanded_nodes[state.tree_data[1].id] = true
  end
end

--- 加载树状结构数据（内部使用）
--- @param session_id string 会话ID
function M._load_tree_structure(session_id)
  -- 尝试从树管理器加载数据
  local tree_manager_loaded, tree_manager = pcall(require, "NeoAI.core.session.tree_manager")
  if tree_manager_loaded and tree_manager then
    -- 确保树管理器已初始化
    if not tree_manager.is_initialized or not tree_manager.is_initialized() then
      local config = state.config or {}
      tree_manager.initialize({
        event_bus = nil, -- 暂时不需要事件总线
        config = config,
      })
    end

    -- 获取树状结构
    local tree_structure = tree_manager.get_tree()
    if tree_structure and #tree_structure > 0 then
      -- 转换树管理器节点为历史树节点
      state.tree_data = M._convert_tree_manager_nodes(tree_structure, session_id)
      return
    end
  end

  -- 如果树管理器没有数据，生成示例数据
  M._load_example_data()
end

--- 转换树管理器节点为历史树节点（内部使用）
--- @param tree_nodes table 树管理器节点列表
--- @param session_id string 会话ID
--- @return table 历史树节点列表
function M._convert_tree_manager_nodes(tree_nodes, session_id)
  local result = {}

  for _, node in ipairs(tree_nodes) do
    local converted_node = {
      id = node.id,
      name = node.name,
      type = node.type,
      metadata = vim.deepcopy(node.metadata) or {},
      children = {},
      raw_data = node,
    }

    -- 设置元数据
    if not converted_node.metadata.created_at then
      converted_node.metadata.created_at = node.created_at or os.time()
    end
    if not converted_node.metadata.last_updated then
      converted_node.metadata.last_updated = node.created_at or os.time()
    end

    -- 递归转换子节点
    if node.children and #node.children > 0 then
      converted_node.children = M._convert_tree_manager_nodes(node.children, session_id)
    end

    table.insert(result, converted_node)

    -- 默认展开虚拟根节点
    if converted_node.type == "virtual_root" then
      state.expanded_nodes[converted_node.id] = true
    end
  end

  return result
end

--- 加载示例数据（内部使用）
function M._load_example_data()
  -- 尝试从树管理器生成示例树
  local tree_manager_loaded, tree_manager = pcall(require, "NeoAI.core.session.tree_manager")
  if tree_manager_loaded and tree_manager then
    -- 生成示例树
    local example_tree = tree_manager.generate_example_tree()
    if example_tree and #example_tree > 0 then
      state.tree_data = M._convert_tree_manager_nodes(example_tree, nil)
      return
    end
  end

  -- 如果无法生成示例树，使用硬编码的示例数据
  M._load_fallback_data()
end

--- 加载后备数据（模拟数据）
function M._load_fallback_data()
  state.tree_data = {
    {
      id = "virtual_root",
      name = "所有会话",
      type = "virtual_root",
      metadata = {
        node_count = 2,
        created_at = os.time(),
        last_updated = os.time(),
        is_virtual = true
      },
      children = {
        {
          id = "root_1",
          name = "根节点-1",
          type = "root_branch",
          metadata = {
            session_count = 1,
            sub_branch_count = 2,
            created_at = os.time() - 86400,
            last_updated = os.time() - 43200
          },
          children = {
            {
              id = "sub_1_1",
              name = "子节点1-1",
              type = "sub_branch",
              metadata = {
                session_count = 1,
                sub_branch_count = 1,
                created_at = os.time() - 43200,
                last_updated = os.time() - 21600
              },
              children = {
                {
                  id = "session_1",
                  name = "会话1",
                  type = "session",
                  metadata = {
                    message_count = 4,
                    created_at = os.time() - 21600,
                    last_updated = os.time() - 10800,
                    conversation_rounds = {
                      { round_number = 1, timestamp = os.time() - 21600 },
                      { round_number = 2, timestamp = os.time() - 10800 }
                    }
                  },
                  children = {
                    {
                      id = "round_session_1_1",
                      name = "第1轮会话: 用户:你好，我想了解NeoAI的功能 AI:NeoAI是一个强大的AI助手",
                      type = "conversation_round",
                      metadata = {
                        round_number = 1,
                        message_count = 2,
                        timestamp = os.time() - 21600,
                        user_message = "你好，我想了解NeoAI的功能",
                        ai_message = "NeoAI是一个强大的AI助手，可以帮助您完成各种任务。"
                      },
                      children = {
                        {
                          id = "msg_round_session_1_1_1",
                          name = "[user] 你好，我想了解NeoAI的功能",
                          type = "message",
                          metadata = {
                            role = "user",
                            content = "你好，我想了解NeoAI的功能",
                            round_number = 1,
                            message_index = 1,
                            timestamp = os.time() - 21600
                          },
                          children = nil
                        },
                        {
                          id = "msg_round_session_1_1_2",
                          name = "[assistant] NeoAI是一个强大的AI助手，可以帮助您完成各种任务。",
                          type = "message",
                          metadata = {
                            role = "assistant",
                            content = "NeoAI是一个强大的AI助手，可以帮助您完成各种任务。",
                            round_number = 1,
                            message_index = 2,
                            timestamp = os.time() - 21500
                          },
                          children = nil
                        }
                      }
                    },
                    {
                      id = "round_session_1_2",
                      name = "第2轮会话: 用户:它能做什么？ AI:NeoAI可以回答问题、编写代码",
                      type = "conversation_round",
                      metadata = {
                        round_number = 2,
                        message_count = 2,
                        timestamp = os.time() - 10800,
                        user_message = "它能做什么？",
                        ai_message = "NeoAI可以回答问题、编写代码、分析文档、协助调试等。"
                      },
                      children = {
                        {
                          id = "msg_round_session_1_2_1",
                          name = "[user] 它能做什么？",
                          type = "message",
                          metadata = {
                            role = "user",
                            content = "它能做什么？",
                            round_number = 2,
                            message_index = 1,
                            timestamp = os.time() - 10800
                          },
                          children = nil
                        },
                        {
                          id = "msg_round_session_1_2_2",
                          name = "[assistant] NeoAI可以回答问题、编写代码、分析文档、协助调试等。",
                          type = "message",
                          metadata = {
                            role = "assistant",
                            content = "NeoAI可以回答问题、编写代码、分析文档、协助调试等。",
                            round_number = 2,
                            message_index = 2,
                            timestamp = os.time() - 10700
                          },
                          children = nil
                        }
                      }
                    }
                  }
                },
                {
                  id = "sub_1_1_1",
                  name = "子节点1-1-1",
                  type = "sub_branch",
                  metadata = {
                    session_count = 0,
                    sub_branch_count = 0,
                    created_at = os.time() - 5400,
                    last_updated = os.time() - 5400
                  },
                  children = {}
                }
              }
            },
            {
              id = "sub_1_2",
              name = "子节点1-2",
              type = "sub_branch",
              metadata = {
                session_count = 0,
                sub_branch_count = 0,
                created_at = os.time() - 7200,
                last_updated = os.time() - 7200
              },
              children = {}
            }
          }
        },
        {
          id = "root_2",
          name = "根节点-2",
          type = "root_branch",
          metadata = {
            session_count = 0,
            sub_branch_count = 0,
            created_at = os.time() - 3600,
            last_updated = os.time() - 3600
          },
          children = {}
        }
      }
    }
  }

  -- 默认展开虚拟根节点
  state.expanded_nodes["virtual_root"] = true
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
