local M = {}

local logger = require("NeoAI.utils.logger")
local ai_engine = require("NeoAI.core.ai.ai_engine")
local history_manager = require("NeoAI.core.history.manager")
local state_manager = require("NeoAI.core.config.state")

local initialized = false

--- 初始化核心模块
--- @param config table 完整配置
--- @return table 核心模块实例
function M.initialize(config)
  if initialized then
    return M
  end

  -- 初始化配置模块（含键位配置管理器和状态管理器）
  local config_module = require("NeoAI.core.config")
  config_module.initialize(config)

  -- 初始化 AI 引擎
  ai_engine.initialize({
    config = config,
    session_manager = nil, -- 旧版 session_manager 已废弃，使用 history_manager
  })

  -- 初始化历史管理器（唯一数据源）
  history_manager.initialize({ config = config })

  -- 初始化聊天服务（前后端分离的后端入口）
  local chat_service = require("NeoAI.core.ai.chat_service")
  chat_service.initialize({ config = config })

  initialized = true
  return M
end

--- 获取 AI 引擎
function M.get_ai_engine()
  if not initialized then error("Core not initialized") end
  return ai_engine
end

--- 获取键位配置管理器
function M.get_keymap_manager()
  if not initialized then error("Core not initialized") end
  return require("NeoAI.core.config.keymap_manager")
end

--- 获取历史管理器
function M.get_history_manager()
  if not initialized then error("Core not initialized") end
  return history_manager
end

--- 获取配置（从 state_manager）
function M.get_config()
  if not initialized then error("Core not initialized") end
  return state_manager.get_config()
end

--- 获取会话管理器（旧版兼容）
function M.get_session_manager()
  if not initialized then error("Core not initialized") end
  return nil
end

return M
