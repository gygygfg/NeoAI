--- NeoAI 统一状态管理器
--- 集中管理所有模块的共享状态，消除分散在各 init.lua 中的重复状态表
local M = {}

local logger = require("NeoAI.utils.logger")

local state = {
  initialized = false,
  config = nil,
}

--- 初始化状态
--- @param config table 合并后的完整配置
function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = config
  state.initialized = true
end

--- 获取配置
--- @return table 完整配置
function M.get_config()
  return state.config
end

--- 获取配置值（支持点号路径）
--- @param key string 配置键，如 "ai.scenarios.chat"
--- @param default any 默认值
--- @return any
function M.get_config_value(key, default)
  if not key then
    return state.config
  end
  local keys = vim.split(key, ".", { plain = true })
  local value = state.config
  for _, k in ipairs(keys) do
    if type(value) ~= "table" then
      return default
    end
    value = value[k]
  end
  if value == nil then
    return default
  end
  return value
end

--- 检查是否已初始化
--- @return boolean
function M.is_initialized()
  return state.initialized
end

--- 重置状态（测试用）
function M._test_reset()
  state.initialized = false
  state.config = nil
end

return M
