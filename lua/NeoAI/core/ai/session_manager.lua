--- NeoAI 工具循环会话管理器
--- 职责：管理工具循环的会话状态（创建、注册、查询、清理）
--- 从 tool_orchestrator.lua 提取，减轻其负担

local logger = require("NeoAI.utils.logger")
local state_manager = require("NeoAI.core.config.state")

local M = {}

-- ========== 会话状态工厂 ==========

--- 创建会话状态对象
--- @param session_id string
--- @param window_id number|nil
--- @return table
function M.create_session_state(session_id, window_id)
  return {
    session_id = session_id,
    window_id = window_id,
    generation_id = nil,
    phase = "idle",
    _tools_complete_in_progress = false,
    _proceed_in_progress = false,
    active_tool_calls = {}
    current_iteration = 0,
    messages = {},
    options = {},
    model_index = 1,
    ai_preset = {},
    accumulated_usage = {},
    last_reasoning = nil,
    stop_requested = false,
    user_cancelled = false,
    _tool_retry_count = 0,
    on_complete = nil,
    autocmd_ids = {},
  }
end

--- 重置会话状态（保留 session_id 和 window_id）
--- @param ss table 会话状态
function M.reset_session_state(ss)
  ss.generation_id = nil
  ss.phase = "idle"
  ss._tools_complete_in_progress = false
  ss._proceed_in_progress = false
  ss.active_tool_calls = {}
  ss.current_iteration = 0
  ss.messages = {}
  ss.options = {}
  ss.model_index = 1
  ss.ai_preset = {}
  ss.accumulated_usage = {}
  ss.last_reasoning = nil
  ss.stop_requested = false
  ss.user_cancelled = false
  ss._tool_retry_count = 0
  ss.on_complete = nil
end

--- 检查会话是否处于执行状态
--- @param ss table 会话状态
--- @return boolean
function M.is_executing_phase(ss)
  return ss.phase == "waiting_tools" or ss.phase == "waiting_model"
end

--- 检查是否所有会话都空闲
--- @param sessions table<string, table> 所有会话
--- @return boolean
function M.all_idle(sessions)
  for _, s in pairs(sessions) do
    if s.phase ~= "idle" then
      return false
    end
  end
  return true
end

--- 从 shared 表同步 stop_requested 到会话状态
--- @param ss table 会话状态
function M.sync_stop_from_shared(ss)
  local shared = state_manager.get_shared()
  if shared and shared.stop_requested then
    ss.stop_requested = true
  end
end

return M
