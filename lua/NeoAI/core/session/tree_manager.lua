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
  save_debounce_timer = nil, -- 保存防抖定时器
}

--- 防抖保存（内部使用）
local function debounce_save()
  if not state.config or not state.config.save_path then
    return
  end
  if state.save_debounce_timer then
    state.save_debounce_timer:stop()
    state.save_debounce_timer:close()
    state.save_debounce_timer = nil
  end
  state.save_debounce_timer = vim.loop.new_timer()
  state.save_debounce_timer:start(500, 0, vim.schedule_wrap(function()
    if state.save_debounce_timer then
      state.save_debounce_timer:close()
      state.save_debounce_timer = nil
    end
    M._save_tree_data()
  end))
end

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

  -- 从配置中获取保存路径（支持 config.session.save_path 结构）
  local save_path = state.config.save_path
  if not save_path and state.config.session then
    save_path = state.config.session.save_path
  end
  
  -- 如果未提供 save_path，使用默认值
  if not save_path then
    save_path = vim.fn.stdpath("cache") .. "/NeoAI"
  end
  
  -- 确保 save_path 在配置中可用
  state.config.save_path = save_path

  -- 加载保存的树数据
  if state.config.save_path then
    M._load_tree_data()
  end
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
    type = "node",
    parent_id = "virtual_root",
    created_at = os.time(),
    children = {},
    metadata = {
      child_count = 0
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

  -- 自动保存
  debounce_save()

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

  -- 任何节点都可以有子节点，移除类型检查

  -- 确保父节点的元数据存在
  if not parent.metadata then
    parent.metadata = {}
  end
  -- 确保父节点的子节点列表存在
  if not parent.children then
    parent.children = {}
  end

  node_counter = node_counter + 1
  local node_id = "node_" .. node_counter

  local node = {
    id = node_id,
    name = name or ("节点-" .. node_counter),
    type = "node", -- 所有子节点统一为 node 类型
    parent_id = parent_id,
    created_at = os.time(),
    children = {},
    metadata = {
      child_count = 0
    }
  }

  tree_nodes[node_id] = node

  -- 添加到父节点的子节点
  table.insert(parent.children, node_id)

  -- 更新父节点元数据
  if not parent.metadata.child_count then
    parent.metadata.child_count = 0
  end
  parent.metadata.child_count = parent.metadata.child_count + 1

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:sub_branch_created", 
    data = { node_id, node, parent_id } 
  })

  -- 自动保存
  debounce_save()

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

  -- 任何节点都可以有 session 子节点，移除类型检查

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
  if parent.metadata.session_count == nil then
    parent.metadata.session_count = 0
  end
  parent.metadata.session_count = parent.metadata.session_count + 1

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:session_created", 
    data = { node_id, node, parent_id } 
  })

  -- 自动保存
  debounce_save()

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

  -- 需求1: 轮次节点名称直接显示问答摘要在一行，不创建子消息节点
  local user_short = user_message and user_message:gsub("\n", " "):sub(1, 30) or ""
  local ai_short = ai_message and ai_message:gsub("\n", " "):sub(1, 30) or ""
  if #user_short >= 30 then user_short = user_short .. "..." end
  if #ai_short >= 30 then ai_short = ai_short .. "..." end

  local node = {
    id = node_id,
    name = "第" .. round_number .. "轮: 👤" .. user_short .. " | 🤖" .. ai_short,
    type = NODE_TYPES.CONVERSATION_ROUND,
    parent_id = session_id,
    created_at = os.time(),
    children = {}, -- 不再创建子消息节点，问答绑定在一行
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

  -- 需求1: 不再创建消息子节点，问答绑定在一行显示

  -- 触发事件
  vim.api.nvim_exec_autocmds("User", { 
    pattern = "NeoAI:conversation_round_created", 
    data = { node_id, node, session_id } 
  })

  -- 自动保存
  debounce_save()

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

  -- 自动保存
  debounce_save()

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

  -- 自动保存
  debounce_save()
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

  -- 自动保存
  debounce_save()
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

  -- 任何节点都可以有子节点，移除类型检查

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

  -- 自动保存
  debounce_save()
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

--- 从会话管理器同步数据到树结构
--- 遍历 session_manager 中的所有会话，在树中创建对应的节点
function M.sync_from_session_manager()
  if not state.initialized then
    return
  end

  -- 获取会话管理器
  local session_mgr_loaded, session_mgr = pcall(require, "NeoAI.core.session.session_manager")
  if not session_mgr_loaded or not session_mgr or not session_mgr.is_initialized or not session_mgr.is_initialized() then
    return
  end

  -- 获取所有会话
  local sessions = session_mgr.list_sessions()
  if not sessions or #sessions == 0 then
    return
  end

  -- 确保虚拟根节点存在
  M._ensure_virtual_root()

  for _, session_info in ipairs(sessions) do
    local session_id = session_info.id
    
    -- 检查是否已存在对应的树节点
    local exists = false
    for _, child_id in ipairs(tree_nodes["virtual_root"].children) do
      if child_id == session_id then
        exists = true
        break
      end
    end

    if not exists then
      -- 创建树节点
      local node = {
        id = session_id,
        name = session_info.name or ("会话-" .. session_id),
        type = NODE_TYPES.SESSION,
        parent_id = "virtual_root",
        created_at = session_info.created_at or os.time(),
        children = {},
        metadata = {
          message_count = (session_info.metadata and session_info.metadata.message_count) or 0,
          last_updated = session_info.updated_at or os.time(),
          conversation_rounds = {},
        }
      }

      tree_nodes[session_id] = node
      table.insert(tree_nodes["virtual_root"].children, session_id)
      tree_nodes["virtual_root"].metadata.node_count = tree_nodes["virtual_root"].metadata.node_count + 1
    end

    -- 同步消息到对话轮次
    local session_data = session_mgr.get_session(session_id)
    if session_data and session_data.current_branch then
      local msg_mgr = session_mgr.get_message_manager()
      if msg_mgr then
        local messages = msg_mgr.get_messages(session_data.current_branch, 1000000)
        if messages and #messages > 0 then
          -- 按轮次分组（每两条消息为一轮：user + assistant）
          local round_number = 1
          for i = 1, #messages, 2 do
            local user_msg = messages[i]
            local ai_msg = messages[i + 1]
            
            local round_id = "round_" .. session_id .. "_" .. round_number
            
            -- 检查轮次节点是否已存在
            local round_exists = false
            for _, child_id in ipairs(tree_nodes[session_id].children) do
              if child_id == round_id then
                round_exists = true
                break
              end
            end

            if not round_exists then
              local user_preview = user_msg and user_msg.content and user_msg.content:sub(1, 20) or ""
              local ai_preview = ai_msg and ai_msg.content and ai_msg.content:sub(1, 20) or ""
              if #user_preview > 20 then user_preview = user_preview .. "..." end
              if #ai_preview > 20 then ai_preview = ai_preview .. "..." end

              -- 需求1: 轮次节点名称直接显示问答摘要在一行，不创建子消息节点
              local user_short = user_msg and user_msg.content and user_msg.content:gsub("\n", " "):sub(1, 30) or ""
              local ai_short = ai_msg and ai_msg.content and ai_msg.content:gsub("\n", " "):sub(1, 30) or ""
              if #user_short >= 30 then user_short = user_short .. "..." end
              if #ai_short >= 30 then ai_short = ai_short .. "..." end

              local round_node = {
                id = round_id,
                name = "第" .. round_number .. "轮: 👤" .. user_short .. " | 🤖" .. ai_short,
                type = NODE_TYPES.CONVERSATION_ROUND,
                parent_id = session_id,
                created_at = os.time(),
                children = {}, -- 不再创建子消息节点
                metadata = {
                  round_number = round_number,
                  user_message = user_msg and user_msg.content or "",
                  ai_message = ai_msg and ai_msg.content or "",
                  message_count = (user_msg and 1 or 0) + (ai_msg and 1 or 0),
                  timestamp = os.time(),
                }
              }

              tree_nodes[round_id] = round_node
              table.insert(tree_nodes[session_id].children, round_id)
              -- 不再创建消息子节点，问答绑定在一行显示

              -- 更新会话元数据
              if not tree_nodes[session_id].metadata.conversation_rounds then
                tree_nodes[session_id].metadata.conversation_rounds = {}
              end
              table.insert(tree_nodes[session_id].metadata.conversation_rounds, {
                round_number = round_number,
                timestamp = os.time(),
              })
              tree_nodes[session_id].metadata.message_count = (tree_nodes[session_id].metadata.message_count or 0) + (user_msg and 1 or 0) + (ai_msg and 1 or 0)
              tree_nodes[session_id].metadata.last_updated = os.time()
            end

            round_number = round_number + 1
          end
        end
      end
    end
  end
end

--- 保存树数据到文件（内部使用）
--- 将 tree_nodes 和 node_counter 保存到 sessions.json 的 _tree_graph 字段
function M._save_tree_data()
  if not state.config or not state.config.save_path then
    return
  end

  local save_path = state.config.save_path

  -- 确保目录存在
  if vim.fn.isdirectory(save_path) == 0 then
    vim.fn.mkdir(save_path, "p")
  end

  local sessions_file = save_path .. "/sessions.json"
  local all_data = {}

  -- 读取现有的 sessions.json
  if vim.fn.filereadable(sessions_file) == 1 then
    local content = vim.fn.readfile(sessions_file)
    if #content > 0 then
      local success, existing_data = pcall(vim.json.decode, table.concat(content, "\n"))
      if success and existing_data then
        all_data = existing_data
      end
    end
  end

  -- 构建树图数据
  local tree_graph = {
    node_counter = node_counter,
    nodes = {},
    virtual_root_children = {}, -- 单独保存虚拟根节点的子节点ID列表
  }

  -- 保存虚拟根节点的子节点ID列表
  if tree_nodes["virtual_root"] and tree_nodes["virtual_root"].children then
    tree_graph.virtual_root_children = vim.deepcopy(tree_nodes["virtual_root"].children)
  end

  -- 保存所有节点（跳过虚拟根节点，它会在初始化时重建）
  for node_id, node in pairs(tree_nodes) do
    if node_id ~= "virtual_root" then
      tree_graph.nodes[node_id] = {
        id = node.id,
        name = node.name,
        type = node.type,
        parent_id = node.parent_id,
        created_at = node.created_at,
        children = vim.deepcopy(node.children or {}),
        metadata = vim.deepcopy(node.metadata or {}),
      }
    end
  end

  -- 将树图数据写入 _tree_graph 字段
  all_data["_tree_graph"] = tree_graph

  -- 写回文件
  local json_str = vim.json.encode(all_data)
  vim.fn.writefile({ json_str }, sessions_file)
end

--- 从文件加载树数据（内部使用）
function M._load_tree_data()
  if not state.config or not state.config.save_path then
    return
  end

  local save_path = state.config.save_path
  local sessions_file = save_path .. "/sessions.json"

  if vim.fn.filereadable(sessions_file) ~= 1 then
    return
  end

  local content = vim.fn.readfile(sessions_file)
  if #content == 0 then
    return
  end

  local success, all_data = pcall(vim.json.decode, table.concat(content, "\n"))
  if not success or not all_data then
    return
  end

  local tree_graph = all_data["_tree_graph"]
  if not tree_graph or not tree_graph.nodes then
    return
  end

  -- 恢复节点计数器
  if tree_graph.node_counter then
    node_counter = tree_graph.node_counter
  end

  -- 确保虚拟根节点存在
  M._ensure_virtual_root()

  -- 恢复所有节点
  for node_id, node_data in pairs(tree_graph.nodes) do
    tree_nodes[node_id] = {
      id = node_data.id,
      name = node_data.name,
      type = node_data.type,
      parent_id = node_data.parent_id,
      created_at = node_data.created_at,
      children = vim.deepcopy(node_data.children or {}),
      metadata = vim.deepcopy(node_data.metadata or {}),
    }
  end

  -- 恢复虚拟根节点的子节点列表
  if tree_graph.virtual_root_children then
    tree_nodes["virtual_root"].children = vim.deepcopy(tree_graph.virtual_root_children)
    tree_nodes["virtual_root"].metadata.node_count = #tree_nodes["virtual_root"].children
  end
end

return M