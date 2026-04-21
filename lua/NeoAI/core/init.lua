local M = {}

local config_manager = require("NeoAI.core.config.config_manager")
local keymap_manager = require("NeoAI.core.config.keymap_manager")
local session_manager = require("NeoAI.core.session.session_manager")
local ai_engine = require("NeoAI.core.ai.ai_engine")
local history_manager = require("NeoAI.core.history_manager")

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  session_mgr = nil,
  ai_engine = nil,
  event_bus = nil,
  keymap_mgr = nil,
}

--- 初始化核心模块
--- @param core_config table 核心配置
--- @return table 核心模块实例
function M.initialize(core_config)
  if state.initialized then
    return M
  end

  -- 不再使用event_bus兼容层，直接使用Neovim原生事件系统
  state.event_bus = nil

  -- 初始化配置管理器
  config_manager.initialize(core_config or {})

  -- 初始化键位配置管理器
  state.keymap_mgr = keymap_manager

  -- 从配置管理器获取键位配置
  local user_keymaps = config_manager.get("keymaps") or {}

  -- 获取默认键位配置
  local default_config_module = require("NeoAI.default_config")
  local default_config = default_config_module.get_default_config()
  local default_keymaps = default_config.keymaps

  -- 初始化键位管理器，传递默认配置和用户配置
  state.keymap_mgr.initialize(default_keymaps, user_keymaps)

  -- 初始化会话管理器
  state.session_mgr = session_manager.initialize({
    config = config_manager.get("session") or {},
  })

  -- 初始化AI引擎
  state.ai_engine = ai_engine.initialize({
    config = config_manager.get("ai") or {},
    session_manager = state.session_mgr,
  })

  -- 初始化历史管理器
  history_manager.initialize({
    config = config_manager.get("session") or {},
  })

  state.config = core_config
  state.initialized = true

  return M
end

--- 获取会话管理器
--- @return table 会话管理器
function M.get_session_manager()
  if not state.initialized then
    error("Core not initialized")
  end

  return state.session_mgr
end

--- 获取AI引擎
--- @return table AI引擎
function M.get_ai_engine()
  if not state.initialized then
    error("Core not initialized")
  end

  return state.ai_engine
end

-- 注意：get_event_bus函数已被移除，请直接使用Neovim原生事件系统

--- 获取配置管理器
--- @return table 配置管理器
function M.get_config_manager()
  return config_manager
end

--- 获取键位配置管理器
--- @return table 键位配置管理器
function M.get_keymap_manager()
  if not state.initialized then
    error("Core not initialized")
  end

  return state.keymap_mgr
end

--- 获取历史管理器
--- @return table 历史管理器
function M.get_history_manager()
  if not state.initialized then
    error("Core not initialized")
  end

  return history_manager
end

return M
