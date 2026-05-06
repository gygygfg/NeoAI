--- NeoAI 审批配置共享状态
--- 所有模块通过此模块读写同一份审批配置
--- 使用模块级表，不依赖协程上下文

local M = {}

-- ========== 共享状态表 ==========
-- 所有配置都在同一个表里：
--   tool_name -> { auto_allow, allowed_directories, allowed_param_groups, allow_all }

local _state = {}

--- 设置工具的运行时审批配置
--- @param tool_name string 工具名称
--- @param config table 审批配置
function M.set_tool_config(tool_name, config)
  _state[tool_name] = config
end

--- 获取工具的运行时审批配置
--- @param tool_name string 工具名称
--- @return table|nil
function M.get_tool_config(tool_name)
  return _state[tool_name]
end

--- 获取所有工具的运行时审批配置
--- @return table
function M.get_all_tool_configs()
  return _state
end

--- 清除所有工具的运行时审批配置
function M.clear_tool_configs()
  _state = {}
end

--- 设置工具允许全部通过（跳过审批）
--- @param tool_name string 工具名称
function M.set_allow_all(tool_name)
  if not _state[tool_name] then
    _state[tool_name] = {}
  end
  _state[tool_name].allow_all = true
end

--- 检查工具是否已设置允许全部通过
--- @param tool_name string 工具名称
--- @return boolean
function M.is_allow_all(tool_name)
  local config = _state[tool_name]
  return config and config.allow_all == true
end

--- 清除工具的允许全部标志
--- @param tool_name string 工具名称
function M.clear_allow_all(tool_name)
  if _state[tool_name] then
    _state[tool_name].allow_all = nil
  end
end

--- 重置所有状态
function M.reset()
  _state = {}
end

return M
