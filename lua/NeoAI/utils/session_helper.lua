--- 会话管理辅助模块
--- 提供统一的会话管理功能，确保 chat 界面和 tree 界面使用相同的会话管理机制

local M = {}

-- 模块状态
local state = {
  initialized = false,
  config = nil,
}

--- 初始化会话辅助模块
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end
  
  state.config = config or {}
  state.initialized = true
end

--- 确保会话管理器已初始化
--- @return boolean 是否成功
function M.ensure_session_manager()
  local session_mgr_loaded, session_mgr = pcall(require, "NeoAI.core.session.session_manager")
  if not session_mgr_loaded or not session_mgr then
    print("⚠️  无法加载会话管理器")
    return false
  end
  
  -- 检查是否已初始化
  if session_mgr.is_initialized and not session_mgr.is_initialized() then
    -- 使用默认配置初始化
    local config = state.config or {
      auto_save = true,
      save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    }
    
    session_mgr.initialize({
      event_bus = nil,
      config = config,
    })
    print("✓ 已初始化会话管理器")
  end
  
  return true
end

--- 确保树管理器已初始化
--- @return boolean 是否成功
function M.ensure_tree_manager()
  local tree_mgr_loaded, tree_mgr = pcall(require, "NeoAI.core.session.tree_manager")
  if not tree_mgr_loaded or not tree_mgr then
    print("⚠️  无法加载树管理器")
    return false
  end
  
  -- 检查是否已初始化
  if tree_mgr.is_initialized and not tree_mgr.is_initialized() then
    -- 使用默认配置初始化
    local config = state.config or {
      save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    }
    
    tree_mgr.initialize({
      event_bus = nil,
      config = config,
    })
    print("✓ 已初始化树管理器")
  end
  
  return true
end

--- 确保历史管理器已初始化
--- @return boolean 是否成功
function M.ensure_history_manager()
  local history_mgr_loaded, history_mgr = pcall(require, "NeoAI.core.history_manager")
  if not history_mgr_loaded or not history_mgr then
    print("⚠️  无法加载历史管理器")
    return false
  end
  
  -- 检查是否已初始化
  if not history_mgr.is_initialized or not history_mgr.is_initialized() then
    -- 使用默认配置初始化
    local config = state.config or {
      auto_save = true,
      save_path = vim.fn.stdpath("cache") .. "/NeoAI",
    }
    
    history_mgr.initialize({
      event_bus = nil,
      config = config,
    })
    print("✓ 已初始化历史管理器")
  end
  
  return true
end

--- 获取或创建当前会话
--- @param session_name string 会话名称（可选）
--- @return table|nil 当前会话，如果失败返回nil
function M.get_or_create_session(session_name)
  -- 确保会话管理器已初始化
  if not M.ensure_session_manager() then
    return nil
  end
  
  local session_mgr = require("NeoAI.core.session.session_manager")
  -- 使用新的 get_or_create_current_session 方法，仅在需要时创建
  local current_session = session_mgr.get_or_create_current_session(session_name or "聊天会话")
  
  return current_session
end

--- 保存消息到所有管理器
--- @param role string 角色 ('user' 或 'assistant')
--- @param content string 消息内容
--- @param metadata table 元数据（可选）
--- @return boolean 是否成功
function M.save_message_to_all(role, content, metadata)
  metadata = metadata or {}
  
  -- 确保所有管理器已初始化
  M.ensure_session_manager()
  M.ensure_tree_manager()
  M.ensure_history_manager()
  
  local success = true
  
  -- 1. 保存到会话管理器
  local session_mgr = require("NeoAI.core.session.session_manager")
  local current_session = M.get_or_create_session()
  
  if current_session and current_session.current_branch then
    local msg_mgr = session_mgr.get_message_manager()
    if msg_mgr then
      local ok, err = pcall(msg_mgr.add_message, current_session.current_branch, role, content, metadata)
      if ok then
        print("✓ 消息已保存到会话管理器")
      else
        print("⚠️  保存到会话管理器失败: " .. tostring(err))
        success = false
      end
    end
  end
  
  -- 2. 同步到树管理器
  local tree_mgr = require("NeoAI.core.session.tree_manager")
  if tree_mgr.sync_from_session_manager then
    pcall(tree_mgr.sync_from_session_manager)
    print("✓ 已同步到树管理器")
  end
  
  -- 3. 保存到历史管理器
  local history_mgr = require("NeoAI.core.history_manager")
  local history_session = history_mgr.get_current_session()
  if not history_session then
    pcall(history_mgr.create_session, "聊天会话")
  end
  
  local ok, err = pcall(history_mgr.add_message, role, content, metadata)
  if ok then
    print("✓ 消息已保存到历史管理器")
  else
    print("⚠️  保存到历史管理器失败: " .. tostring(err))
    success = false
  end
  
  -- 4. 触发自动保存
  if session_mgr._save_sessions then
    pcall(session_mgr._save_sessions)
    print("✓ 已触发自动保存")
  end
  
  return success
end

--- 从会话管理器加载消息
--- @param limit number 限制数量（可选，默认100）
--- @return table 消息列表
function M.load_messages_from_session(limit)
  limit = limit or 100
  
  -- 确保会话管理器已初始化
  if not M.ensure_session_manager() then
    return {}
  end
  
  local session_mgr = require("NeoAI.core.session.session_manager")
  local current_session = session_mgr.get_current_session()
  
  if not current_session or not current_session.current_branch then
    return {}
  end
  
  local msg_mgr = session_mgr.get_message_manager()
  if not msg_mgr then
    return {}
  end
  
  local messages = msg_mgr.get_messages(current_session.current_branch, limit) or {}
  
  -- 转换消息格式
  local formatted_messages = {}
  for _, msg in ipairs(messages) do
    table.insert(formatted_messages, {
      role = msg.role,
      content = msg.content,
      timestamp = msg.timestamp or os.time(),
    })
  end
  
  return formatted_messages
end

--- 从会话管理器加载消息（按指定会话ID）
--- @param session_id string 会话ID
--- @param limit number 限制数量（可选，默认100）
--- @return table 消息列表
function M.load_messages_from_session_by_id(session_id, limit)
  limit = limit or 100
  
  if not session_id then
    return {}
  end
  
  -- 确保会话管理器已初始化
  if not M.ensure_session_manager() then
    return {}
  end
  
  local session_mgr = require("NeoAI.core.session.session_manager")
  local session = session_mgr.get_session(session_id)
  
  if not session or not session.current_branch then
    return {}
  end
  
  local msg_mgr = session_mgr.get_message_manager()
  if not msg_mgr then
    return {}
  end
  
  local messages = msg_mgr.get_messages(session.current_branch, limit) or {}
  
  -- 转换消息格式
  local formatted_messages = {}
  for _, msg in ipairs(messages) do
    table.insert(formatted_messages, {
      role = msg.role,
      content = msg.content,
      timestamp = msg.timestamp or os.time(),
    })
  end
  
  return formatted_messages
end

--- 从历史管理器加载消息
--- @param limit number 限制数量（可选，默认100）
--- @return table 消息列表
function M.load_messages_from_history(limit)
  limit = limit or 100
  
  -- 确保历史管理器已初始化
  if not M.ensure_history_manager() then
    return {}
  end
  
  local history_mgr = require("NeoAI.core.history_manager")
  local messages = history_mgr.get_messages(limit) or {}
  
  -- 转换消息格式
  local formatted_messages = {}
  for _, msg in ipairs(messages) do
    table.insert(formatted_messages, {
      role = msg.role,
      content = msg.content,
      timestamp = msg.timestamp or os.time(),
    })
  end
  
  return formatted_messages
end

--- 获取当前会话ID
--- @return string|nil 会话ID
function M.get_current_session_id()
  -- 优先从会话管理器获取
  if M.ensure_session_manager() then
    local session_mgr = require("NeoAI.core.session.session_manager")
    local current_session = session_mgr.get_current_session()
    if current_session then
      return current_session.id
    end
  end
  
  -- 回退到历史管理器
  if M.ensure_history_manager() then
    local history_mgr = require("NeoAI.core.history_manager")
    local current_session = history_mgr.get_current_session()
    if current_session then
      return current_session.id
    end
  end
  
  return nil
end

--- 创建新会话
--- @param name string 会话名称
--- @return string|nil 会话ID
function M.create_session(name)
  -- 在会话管理器中创建
  if M.ensure_session_manager() then
    local session_mgr = require("NeoAI.core.session.session_manager")
    local session_id = session_mgr.create_session(name or "新会话")
    
    -- 同步到树管理器
    if M.ensure_tree_manager() then
      local tree_mgr = require("NeoAI.core.session.tree_manager")
      pcall(tree_mgr.sync_from_session_manager)
    end
    
    -- 在历史管理器中创建
    if M.ensure_history_manager() then
      local history_mgr = require("NeoAI.core.history_manager")
      pcall(history_mgr.create_session, name or "新会话")
    end
    
    return session_id
  end
  
  return nil
end

return M