local M = {}

local config_manager = require("NeoAI.core.config.config_manager")
local keymap_manager = require("NeoAI.core.config.keymap_manager")
local session_manager = require("NeoAI.core.session.session_manager")
local ai_engine = require("NeoAI.core.ai.ai_engine")
local event_bus = require("NeoAI.core.events.event_bus")

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

  -- 初始化事件总线
  state.event_bus = event_bus
  state.event_bus.initialize()

  -- 初始化配置管理器
  config_manager.initialize(core_config or {})

  -- 初始化键位配置管理器
  state.keymap_mgr = keymap_manager

  -- 从配置管理器获取键位配置
  local user_keymaps = config_manager.get("keymaps") or {}

  -- 直接使用传入的配置中的键位配置
  local default_keymaps = {}
  if core_config and core_config.keymaps then
    default_keymaps = core_config.keymaps
  end

  -- 初始化键位管理器，传递默认配置和用户配置
  state.keymap_mgr.initialize(default_keymaps, user_keymaps)

  -- 初始化会话管理器
  state.session_mgr = session_manager.initialize({
    event_bus = state.event_bus,
    config = config_manager.get("session") or {},
  })

  -- 初始化AI引擎
  state.ai_engine = ai_engine.initialize({
    event_bus = state.event_bus,
    config = config_manager.get("ai") or {},
    session_manager = state.session_mgr,
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

--- 获取事件总线
--- @return table 事件总线
function M.get_event_bus()
  if not state.initialized then
    error("Core not initialized")
  end
  return state.event_bus
end

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

return M
