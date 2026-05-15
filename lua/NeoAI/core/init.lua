--- NeoAI 核心模块入口
--- 职责：初始化并统一导出核心子模块（AI引擎、历史管理器、聊天服务、键位管理器）
--- 闭包内私有状态：initialized

local logger = require("NeoAI.utils.logger")
local engine = require("NeoAI.core.ai.engine")
local history_manager = require("NeoAI.core.history.manager")
-- ========== 闭包内私有状态 ==========
local initialized = false
local _config = nil

-- ========== 公共接口 ==========
local M = {}

--- 初始化核心模块
--- @param config table 完整配置
--- @return table 核心模块实例
function M.initialize(config)
  if initialized then return M end

  _config = config

  -- 初始化配置模块（含键位配置管理器）
  local config_module = require("NeoAI.core.config")
  config_module.initialize(config)

  -- 初始化 AI 引擎（各子模块自行从 state_manager 读取配置）
  engine.initialize({})

  -- 初始化历史管理器（唯一数据源，幂等）
  history_manager.initialize({ config = config })

  -- 初始化聊天服务（前后端分离的后端入口，幂等）
  local chat_service = require("NeoAI.core.ai.chat_service")
  chat_service.initialize()

  initialized = true
  return M
end

--- 获取 AI 引擎
function M.get_engine()
  if not initialized then error("Core not initialized") end
  return engine
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

--- 获取配置
function M.get_config()
  if not initialized then error("Core not initialized") end
  return _config
end

--- 获取会话管理器（旧版兼容）
function M.get_session_manager()
  if not initialized then error("Core not initialized") end
  return nil
end

return M
