--- 会话管理辅助模块
--- 基于新的 history_manager

local M = {}

local state = {
  initialized = false,
  config = nil,
}

function M.initialize(config)
  if state.initialized then return end
  state.config = config or {}
  state.initialized = true
end

local function get_hm()
  local ok, hm = pcall(require, "NeoAI.core.history_manager")
  if ok and hm.is_initialized() then return hm end
  return nil
end

function M.ensure_session_manager()
  local hm = get_hm()
  if hm then return true end
  local ok, hm_mod = pcall(require, "NeoAI.core.history_manager")
  if ok then
    hm_mod.initialize({ config = state.config or {} })
    return true
  end
  return false
end

function M.ensure_tree_manager()
  return M.ensure_session_manager()
end

function M.ensure_history_manager()
  return M.ensure_session_manager()
end

function M.get_or_create_session(session_name)
  local hm = get_hm()
  if not hm then return nil end
  return hm.get_or_create_current_session(session_name or "聊天会话")
end

function M.save_message_to_all(role, content, metadata)
  local hm = get_hm()
  if not hm then return false end
  local session = hm.get_current_session()
  if not session then return false end
  if role == "user" then
    hm.add_round(session.id, content, "")
  elseif role == "assistant" then
    hm.update_last_assistant(session.id, content)
  end
  return true
end

function M.load_messages_from_session(limit)
  local hm = get_hm()
  if not hm then return {} end
  local session = hm.get_current_session()
  if not session then return {} end
  local context_msgs, _ = hm.get_context_and_new_parent(session.id)
  return context_msgs
end

function M.load_messages_from_session_by_id(session_id, limit)
  local hm = get_hm()
  if not hm then return {} end
  local context_msgs, _ = hm.get_context_and_new_parent(session_id)
  return context_msgs
end

function M.load_messages_from_history(limit)
  local hm = get_hm()
  if not hm then return {} end
  local session = hm.get_current_session()
  if not session then return {} end
  return hm.get_messages(session.id)
end

function M.get_current_session_id()
  local hm = get_hm()
  if not hm then return nil end
  local session = hm.get_current_session()
  return session and session.id or nil
end

function M.create_session(name)
  local hm = get_hm()
  if not hm then return nil end
  return hm.create_session(name or "新会话", true, nil)
end

return M
