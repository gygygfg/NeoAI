local M = {}

local session_manager = require("NeoAI.core.session.session_manager")
local ai_engine = require("NeoAI.core.ai.ai_engine")
local history_manager = require("NeoAI.core.history_manager")

-- 模块状态（不维护 config，直接使用主 init.lua 传入的合并后配置）
local state = {
  initialized = false,
  config = nil,
  session_mgr = nil,
  ai_engine = nil,
  event_bus = nil,
  keymap_mgr = nil,
}

-- 保存主 init.lua 传入的合并后配置引用
local merged_config = nil

--- 初始化核心模块
--- @param core_config table 核心配置
--- @return table 核心模块实例
function M.initialize(core_config)
  if state.initialized then
    return M
  end

  -- 不再使用event_bus兼容层，直接使用Neovim原生事件系统
  state.event_bus = nil

  -- 初始化键位配置管理器（按需加载，避免模块加载时过早创建实例）
  local keymap_manager = require("NeoAI.core.config.keymap_manager")
  state.keymap_mgr = keymap_manager

  -- 直接传入完整配置，各子模块自己取需要的部分
  state.keymap_mgr.initialize(core_config)

  -- 初始化会话管理器
  state.session_mgr = session_manager.initialize({
    config = core_config,
  })

  -- 初始化AI引擎
  state.ai_engine = ai_engine.initialize({
    config = core_config,
    session_manager = state.session_mgr,
  })

  -- 初始化历史管理器
  history_manager.initialize({
    config = core_config,
  })

  -- 保存合并后配置的引用（由主 init.lua 传入，已合并用户配置）
  merged_config = core_config
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

--- 获取合并后的完整配置
--- 直接返回主 init.lua 传入的合并后配置引用
--- @return table 合并后的完整配置
function M.get_config()
  if not state.initialized then
    error("Core not initialized")
  end
  return merged_config
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
