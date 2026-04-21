local M = {}

-- 节点类型
local NODE_TYPES = {
  ROOT_BRANCH = "root_branch",
  SUB_BRANCH = "sub_branch",
  SESSION = "session",
  CONVERSATION_ROUND = "conversation_round",
  MESSAGE = "message"
}

-- 树节点存储
local tree_nodes = {}
local node_counter = 0

-- 模块状态
local state = {
  initialized = false,
  event_bus = nil,
  config = nil,
}

--- 初始化树管理器
--- @param options table 选项
function M.initialize(options)
  if state.initialized then
    return
  end

  state.event_bus = options.event_bus
  state.config = options.config or {}
  state.initialized = true
  
  -- 初始化虚拟根节点
  M._ensure_virtual_root()
end

--- 确保虚拟根节点存在（内部使用）
function M._ensure_virtual_root()
  if not tree_nodes["virtual_root"] then
    tree_nodes["virtual_root"] = {
      id = "virtual_root",
      name = "所有会话",
      type = "virtual_root",
      parent_id = nil,
      created_at = os.time(),
      children = {},
      metadata = {
        node_count = 0,
        is_virtual = true
      }
    }
  end
end

--- 创建根分支
--- @param name string 根分支名称
--- @return string 节点ID
function M.create_root_branch(name)
  if not state.initialized then
    error("Tree manager not initialized")
  end

  node_counter = node_counter + 1
  local node_id = "root_" .. node_counter

  local node = {
    id = node_id,
    name = name or ("根节点-" .. node_counter),
    type = NODE_TYPES.ROOT_BRANCH,
    parent_id = "virtual_root",
    created_at = os.time(),
    children = {},
    metadata = {
      session_count = 0,
      sub_branch_count = 0
    }
  }

  tree_nodes[node_id] = node
  
  -- 添加到虚拟根节点的子节点
  table.insert(tree_nodes["virtual_root"].children, node_id)
  tree_nodes["virtual_root"].metadata.node_count = tree_nodes["virtual_root"].metadata.node_count + 1

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:root_branch_created", 
    data = { node_id, node } 
  })

  return node_id
end

--- 创建子分支
--- @param parent_id string 父节点ID
--- @param name string 子分支名称
--- @return string 节点ID
function M.create_sub_branch(parent_id, name)
  if not state.initialized then
    error("Tree manager not initialized")
  end

  local parent = tree_nodes[parent_id]
  if not parent then
    error("Parent node not found: " .. parent_id)
  end

  -- 检查父节点类型
  if parent.type ~= NODE_TYPES.ROOT_BRANCH and parent.type ~= NODE_TYPES.SUB_BRANCH then
    error("Cannot create sub-branch under node type: " .. parent.type)
  end

  -- 确保父节点的元数据存在
  if not parent.metadata then
    parent.metadata = {}
  end
  -- 确保父节点的子分支计数字段存在
  if parent.metadata.sub_branch_count == nil then
    parent.metadata.sub_branch_count = 0
  end

  node_counter = node_counter + 1
  local node_id = "sub_" .. node_counter

  local node = {
    id = node_id,
    name = name or ("子节点" .. M._get_node_path_string(parent_id) .. "-" .. (parent.metadata.sub_branch_count + 1)),
    type = NODE_TYPES.SUB_BRANCH,
    parent_id = parent_id,
    created_at = os.time(),
    children = {},
    metadata = {
      session_count = 0,
      sub_branch_count = 0  -- 子分支也可以有子分支
    }
  }

  tree_nodes[node_id] = node

  -- 添加到父节点的子节点
  table.insert(parent.children, node_id)

  -- 更新父节点元数据
  parent.metadata.sub_branch_count = parent.metadata.sub_branch_count + 1

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:sub_branch_created", 
    data = { node_id, node, parent_id } 
  })

  return node_id
end

--- 获取节点路径字符串（内部使用）
--- @param node_id string 节点ID
--- @return string 路径字符串
function M._get_node_path_string(node_id)
  local node = tree_nodes[node_id]
  if not node then
    return ""
  end
  
  local path_parts = {}
  local current = node
  
  while current and current.parent_id and current.parent_id ~= "virtual_root" do
    local parent = tree_nodes[current.parent_id]
    if parent then
      -- 提取节点编号
      local node_num = current.name:match("%d+")
      if node_num then
        table.insert(path_parts, 1, node_num)
      end
      current = parent
    else
      break
    end
  end
  
  return table.concat(path_parts, "-")
end

--- 创建会话
--- @param parent_id string 父节点ID
--- @param name string 会话名称
--- @param metadata table 元数据
--- @return string 节点ID
function M.create_session(parent_id, name, metadata)
  if not state.initialized then
    error("Tree manager not initialized")
  end

  local parent = tree_nodes[parent_id]
  if not parent then
    error("Parent node not found: " .. parent_id)
  end

  -- 检查父节点类型
  if parent.type ~= NODE_TYPES.ROOT_BRANCH and parent.type ~= NODE_TYPES.SUB_BRANCH then
    error("Cannot create session under node type: " .. parent.type)
  end

  node_counter = node_counter + 1
  local node_id = "session_" .. node_counter

  local node = {
    id = node_id,
    name = name or ("会话-" .. node_counter),
    type = NODE_TYPES.SESSION,
    parent_id = parent_id,
    created_at = os.time(),
    children = {}, -- 会话可以有对话轮次作为子节点
    metadata = metadata or {
      message_count = 0,
      last_updated = os.time(),
      conversation_rounds = {}
    }
  }

  tree_nodes[node_id] = node

  -- 添加到父节点的子节点
  table.insert(parent.children, node_id)

  -- 更新父节点元数据
  parent.metadata.session_count = parent.metadata.session_count + 1

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:session_created", 
    data = { node_id, node, parent_id } 
  })

  return node_id
end

--- 创建对话轮次
--- @param session_id string 会话ID
--- @param round_number number 轮次编号
--- @param user_message string 用户消息
--- @param ai_message string AI回复
--- @return string 节点ID
function M.create_conversation_round(session_id, round_number, user_message, ai_message)
  if not state.initialized then
    error("Tree manager not initialized")
  end

  local session = tree_nodes[session_id]
  if not session then
    error("Session not found: " .. session_id)
  end

  if session.type ~= NODE_TYPES.SESSION then
    error("Cannot create conversation round under node type: " .. session.type)
  end

  node_counter = node_counter + 1
  local node_id = "round_" .. session_id .. "_" .. round_number

  -- 提取前几个字作为预览
  local user_preview = user_message and user_message:sub(1, 20) or ""
  local ai_preview = ai_message and ai_message:sub(1, 20) or ""
  
  if user_preview:len() > 20 then
    user_preview = user_preview .. "..."
  end
  if ai_preview:len() > 20 then
    ai_preview = ai_preview .. "..."
  end

  local node = {
    id = node_id,
    name = "第" .. round_number .. "轮会话: 用户:" .. user_preview .. " AI:" .. ai_preview,
    type = NODE_TYPES.CONVERSATION_ROUND,
    parent_id = session_id,
    created_at = os.time(),
    children = {}, -- 对话轮次可以有消息作为子节点
    metadata = {
      round_number = round_number,
      user_message = user_message,
      ai_message = ai_message,
      message_count = 2, -- 用户和AI各一条
      timestamp = os.time()
    }
  }

  tree_nodes[node_id] = node

  -- 添加到会话的子节点
  table.insert(session.children, node_id)

  -- 更新会话元数据
  if not session.metadata.conversation_rounds then
    session.metadata.conversation_rounds = {}
  end
  table.insert(session.metadata.conversation_rounds, {
    round_number = round_number,
    timestamp = os.time()
  })
  session.metadata.message_count = (session.metadata.message_count or 0) + 2
  session.metadata.last_updated = os.time()

  -- 创建消息子节点
  if user_message then
    M.create_message(node_id, "user", user_message, round_number, 1)
  end
  
  if ai_message then
    M.create_message(node_id, "assistant", ai_message, round_number, 2)
  end

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:conversation_round_created", 
    data = { node_id, node, session_id } 
  })

  return node_id
end

--- 创建消息
--- @param round_id string 对话轮次ID
--- @param role string 角色（user/assistant）
--- @param content string 消息内容
--- @param round_number number 轮次编号
--- @param message_index number 消息索引
--- @return string 节点ID
function M.create_message(round_id, role, content, round_number, message_index)
  if not state.initialized then
    error("Tree manager not initialized")
  end

  local round = tree_nodes[round_id]
  if not round then
    error("Conversation round not found: " .. round_id)
  end

  if round.type ~= NODE_TYPES.CONVERSATION_ROUND then
    error("Cannot create message under node type: " .. round.type)
  end

  node_counter = node_counter + 1
  local node_id = "msg_" .. round_id .. "_" .. message_index

  -- 提取前几个字作为预览
  local content_preview = content and content:sub(1, 30) or ""
  if content_preview:len() > 30 then
    content_preview = content_preview .. "..."
  end

  local node = {
    id = node_id,
    name = "[" .. role .. "] " .. content_preview,
    type = NODE_TYPES.MESSAGE,
    parent_id = round_id,
    created_at = os.time(),
    children = nil, -- 消息没有子节点
    metadata = {
      role = role,
      content = content,
      round_number = round_number,
      message_index = message_index,
      timestamp = os.time()
    }
  }

  tree_nodes[node_id] = node

  -- 添加到对话轮次的子节点
  table.insert(round.children, node_id)

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:message_created", 
    data = { node_id, node, round_id } 
  })

  return node_id
end

--- 获取树状结构
--- @return table 树状结构
function M.get_tree()
  M._ensure_virtual_root()
  
  -- 从虚拟根节点开始构建树
  local virtual_root = tree_nodes["virtual_root"]
  if not virtual_root then
    return {}
  end
  
  return { M._build_tree_node("virtual_root") }
end

--- 构建树节点（内部使用）
--- @param node_id string 节点ID
--- @return table 树节点
function M._build_tree_node(node_id)
  local node = tree_nodes[node_id]
  if not node then
    return nil
  end

  local tree_node = {
    id = node.id,
    name = node.name,
    type = node.type,
    created_at = node.created_at,
    metadata = vim.deepcopy(node.metadata),
    children = {}
  }

  -- 递归构建子节点
  if node.children then
    for _, child_id in ipairs(node.children) do
      local child_node = M._build_tree_node(child_id)
      if child_node then
        table.insert(tree_node.children, child_node)
      end
    end
  end

  return tree_node
end

--- 获取节点信息
--- @param node_id string 节点ID
--- @return table|nil 节点信息
function M.get_node(node_id)
  return vim.deepcopy(tree_nodes[node_id])
end

--- 删除节点
--- @param node_id string 节点ID
function M.delete_node(node_id)
  local node = tree_nodes[node_id]
  if not node then
    return
  end

  -- 递归删除子节点
  if node.children then
    for _, child_id in ipairs(node.children) do
      M.delete_node(child_id)
    end
  end

  -- 从父节点中移除
  if node.parent_id and tree_nodes[node.parent_id] then
    local parent = tree_nodes[node.parent_id]
    for i, child_id in ipairs(parent.children) do
      if child_id == node_id then
        table.remove(parent.children, i)
        
        -- 更新父节点元数据
        if node.type == NODE_TYPES.SESSION then
          parent.metadata.session_count = math.max(0, parent.metadata.session_count - 1)
        elseif node.type == NODE_TYPES.SUB_BRANCH then
          parent.metadata.sub_branch_count = math.max(0, parent.metadata.sub_branch_count - 1)
        elseif node.type == NODE_TYPES.CONVERSATION_ROUND then
          -- 从会话的对话轮次列表中移除
          if parent.metadata.conversation_rounds then
            for j, round in ipairs(parent.metadata.conversation_rounds) do
              if round.round_number == node.metadata.round_number then
                table.remove(parent.metadata.conversation_rounds, j)
                break
              end
            end
          end
          parent.metadata.message_count = math.max(0, (parent.metadata.message_count or 0) - (node.metadata.message_count or 0))
        end
        
        break
      end
    end
  end

  -- 删除节点
  tree_nodes[node_id] = nil

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:node_deleted", 
    data = { node_id, node.type } 
  })
end

--- 重命名节点
--- @param node_id string 节点ID
--- @param new_name string 新名称
function M.rename_node(node_id, new_name)
  local node = tree_nodes[node_id]
  if not node then
    error("Node not found: " .. node_id)
  end

  local old_name = node.name
  node.name = new_name

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:node_renamed", 
    data = { node_id, old_name, new_name } 
  })
end

--- 移动节点
--- @param node_id string 节点ID
--- @param new_parent_id string 新的父节点ID
function M.move_node(node_id, new_parent_id)
  local node = tree_nodes[node_id]
  if not node then
    error("Node not found: " .. node_id)
  end

  local new_parent = tree_nodes[new_parent_id]
  if not new_parent then
    error("New parent node not found: " .. new_parent_id)
  end

  -- 检查移动是否有效
  if node.type == NODE_TYPES.ROOT_BRANCH then
    error("Cannot move root branch")
  end

  if new_parent.type == NODE_TYPES.SESSION or new_parent.type == NODE_TYPES.CONVERSATION_ROUND or new_parent.type == NODE_TYPES.MESSAGE then
    error("Cannot move node under " .. new_parent.type)
  end

  -- 从原父节点中移除
  if node.parent_id and tree_nodes[node.parent_id] then
    local old_parent = tree_nodes[node.parent_id]
    for i, child_id in ipairs(old_parent.children) do
      if child_id == node_id then
        table.remove(old_parent.children, i)
        
        -- 更新原父节点元数据
        if node.type == NODE_TYPES.SESSION then
          old_parent.metadata.session_count = math.max(0, old_parent.metadata.session_count - 1)
        elseif node.type == NODE_TYPES.SUB_BRANCH then
          old_parent.metadata.sub_branch_count = math.max(0, old_parent.metadata.sub_branch_count - 1)
        end
        
        break
      end
    end
  end

  -- 添加到新父节点
  node.parent_id = new_parent_id
  table.insert(new_parent.children, node_id)

  -- 更新新父节点元数据
  if node.type == NODE_TYPES.SESSION then
    new_parent.metadata.session_count = (new_parent.metadata.session_count or 0) + 1
  elseif node.type == NODE_TYPES.SUB_BRANCH then
    new_parent.metadata.sub_branch_count = (new_parent.metadata.sub_branch_count or 0) + 1
  end

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:node_moved", 
    data = { node_id, node.parent_id, new_parent_id } 
  })
end

--- 重置树管理器（主要用于测试）
function M.reset()
  tree_nodes = {}
  node_counter = 0
  state.initialized = false
  state.event_bus = nil
  state.config = nil
end

--- 获取节点类型
--- @return table 节点类型常量
function M.get_node_types()
  return vim.deepcopy(NODE_TYPES)
end

--- 检查是否已初始化
--- @return boolean 是否已初始化
function M.is_initialized()
  return state.initialized
end

--- 生成示例树（用于测试）
--- @return table 示例树
function M.generate_example_tree()
  M.reset()
  M.initialize({ event_bus = nil, config = {} })
  
  -- 创建根节点1
  local root1 = M.create_root_branch("根节点-1")
  
  -- 创建子节点1-1
  local sub1_1 = M.create_sub_branch(root1, "子节点1-1")
  
  -- 创建会话1
  local session1 = M.create_session(sub1_1, "会话1")
  
  -- 创建对话轮次
  M.create_conversation_round(session1, 1, "你好，我想了解NeoAI的功能", "NeoAI是一个强大的AI助手，可以帮助您完成各种任务。")
  M.create_conversation_round(session1, 2, "它能做什么？", "NeoAI可以回答问题、编写代码、分析文档、协助调试等。")
  
  -- 创建子节点1-1-1（在第二轮会话下）
  local sub1_1_1 = M.create_sub_branch(sub1_1, "子节点1-1-1")
  
  -- 创建子节点1-2
  local sub1_2 = M.create_sub_branch(root1, "子节点1-2")
  
  -- 创建根节点2
  local root2 = M.create_root_branch("根节点-2")
  
  return M.get_tree()
end

return M