--- NeoAI 审批配置共享状态
--- 所有模块通过此模块读写同一份审批配置
--- 底层存储使用 state.lua 的全局共享表，实现跨协程共享

local M = {}

local state_manager = require("NeoAI.core.config.state")
local GLOBAL_KEY = "__approval_state__"
local GLOBAL_DEFAULT_KEY = "__approval_global__"
local INITIALIZED_KEY = "__initialized__"

--- 获取底层存储表
local function _store()
  local shared = state_manager.get_global_shared()
  if not shared[GLOBAL_KEY] then
    shared[GLOBAL_KEY] = {}
  end
  return shared[GLOBAL_KEY]
end

--- 获取全局默认配置
--- @return table { default_auto_allow, allowed_directories, allowed_param_groups }
function M.get_global_config()
  local store = _store()
  return store[GLOBAL_DEFAULT_KEY] or {}
end

--- 设置全局默认审批配置
--- @param config table { default_auto_allow?, allowed_directories?, allowed_param_groups? }
function M.set_global_config(config)
  local store = _store()
  store[GLOBAL_DEFAULT_KEY] = config or {}
end

--- 初始化审批状态（从合并后的完整配置中提取 tools.approval）
--- 幂等：仅在首次初始化时写入静态配置，后续调用不覆盖已有数据
--- 这样用户通过 approval_config_editor 的运行时修改不会被新协程覆盖
--- @param full_config table 合并后的完整配置
function M.initialize_from_config(full_config)
  if not full_config or not full_config.tools or not full_config.tools.approval then
    return
  end

  local store = _store()

  -- 幂等保护：已初始化过的不再覆盖
  if store[INITIALIZED_KEY] then
    return
  end
  store[INITIALIZED_KEY] = true

  local approval_cfg = full_config.tools.approval

  -- 设置全局默认配置
  local global = {}
  if approval_cfg.default_auto_allow ~= nil then
    global.default_auto_allow = approval_cfg.default_auto_allow
  end
  if approval_cfg.allowed_directories then
    global.allowed_directories = vim.deepcopy(approval_cfg.allowed_directories)
  end
  if approval_cfg.allowed_param_groups then
    global.allowed_param_groups = vim.deepcopy(approval_cfg.allowed_param_groups)
  end
  if next(global) then
    store[GLOBAL_DEFAULT_KEY] = global
  end

  -- 应用各工具单独覆盖配置
  -- 注意：tool_overrides 中的 enable 字段由 tools/init.lua 的 register_tool 消费，
  -- 用于控制工具是否注册到工具列表，此处不处理 enable 字段
  local tool_overrides = approval_cfg.tool_overrides or {}
  for tool_name, override in pairs(tool_overrides) do
    if type(override) == "table" then
      local config = {}
      if override.auto_allow ~= nil then
        config.auto_allow = override.auto_allow
      end
      if override.allowed_directories ~= nil then
        config.allowed_directories = vim.deepcopy(override.allowed_directories)
      end
      if override.allowed_param_groups ~= nil then
        config.allowed_param_groups = vim.deepcopy(override.allowed_param_groups)
      end
      if next(config) then
        store[tool_name] = config
      end
    end
  end
end

--- 获取工具的审批配置
--- 优先级：
---   1. 工具级配置（由 initialize_from_config 或 approval_config_editor 写入）
---   2. 全局默认配置
--- @param tool_name string 工具名称
--- @return table|nil { auto_allow?, allowed_directories?, allowed_param_groups? }
function M.get_tool_config(tool_name)
  local store = _store()
  local tool_cfg = store[tool_name]
  if tool_cfg then
    return tool_cfg
  end
  return store[GLOBAL_DEFAULT_KEY]
end

--- 设置工具的审批配置
--- @param tool_name string 工具名称
--- @param config table 审批配置
function M.set_tool_config(tool_name, config)
  local store = _store()
  store[tool_name] = config
end

--- 获取所有工具的审批配置
--- @return table
function M.get_all_tool_configs()
  return _store()
end

--- 清除所有工具的审批配置
function M.clear_tool_configs()
  local store = _store()
  for k, _ in pairs(store) do
    store[k] = nil
  end
end

--- 设置工具允许全部通过（跳过审批）
--- @param tool_name string 工具名称
function M.set_allow_all(tool_name)
  local store = _store()
  if not store[tool_name] then
    store[tool_name] = {}
  end
  store[tool_name].allow_all = true
end

--- 检查工具是否已设置允许全部通过
--- @param tool_name string 工具名称
--- @return boolean
function M.is_allow_all(tool_name)
  local store = _store()
  local config = store[tool_name]
  return config and config.allow_all == true
end

--- 清除工具的允许全部标志
--- @param tool_name string 工具名称
function M.clear_allow_all(tool_name)
  local store = _store()
  if store[tool_name] then
    store[tool_name].allow_all = nil
  end
end

--- 重置所有状态
function M.reset()
  local store = _store()
  for k, _ in pairs(store) do
    store[k] = nil
  end
end

--- 清除初始化标记，允许下次 initialize_from_config 重新写入
--- 在工具重新加载（reload_tools）时调用
function M.clear_initialized()
  local store = _store()
  store[INITIALIZED_KEY] = nil
end

return M
