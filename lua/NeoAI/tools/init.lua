local M = {}

local tool_registry = require("NeoAI.tools.tool_registry")
local tool_executor = require("NeoAI.tools.tool_executor")
local tool_validator = require("NeoAI.tools.tool_validator")
local event_bus = require("NeoAI.tools.event_bus")
local history_manager = require("NeoAI.tools.history_manager")
local config_manager = require("NeoAI.tools.config_manager")

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  builtin_tools_loaded = false,
}

--- 初始化工具系统
--- @param tools_config table 工具配置
--- @return table 工具系统实例
function M.initialize(tools_config)
  if state.initialized then
    return M
  end

  state.config = tools_config or {}

  -- 初始化子模块
  tool_registry.initialize(state.config)
  tool_executor.initialize(state.config)
  tool_validator.initialize(state.config)

  -- 初始化新模块
  event_bus.initialize(state.config)
  history_manager.initialize(state.config)
  config_manager.initialize(state.config)

  -- 加载内置工具
  if state.config.builtin ~= false then
    M._load_builtin_tools()
  end

  -- 加载外部工具
  if state.config.external and #state.config.external > 0 then
    M._load_external_tools(state.config.external)
  end

  state.initialized = true
  return M
end

--- 注册工具
--- @param tool_def table 工具定义
--- @return boolean 是否注册成功
function M.register_tool(tool_def)
  -- 注意：在初始化过程中也可以调用此函数

  -- 验证工具定义
  local valid, error_msg = tool_validator.validate_tool(tool_def)
  if not valid then
    vim.notify("工具验证失败: " .. error_msg, vim.log.levels.ERROR)
    return false
  end

  -- 注册工具
  local success, reg_error = pcall(function()
    return tool_registry.register(tool_def)
  end)

  if not success then
    vim.notify("工具注册异常: " .. reg_error, vim.log.levels.ERROR)
    return false
  elseif reg_error == false then
    -- 注册失败但没有异常
    vim.notify("工具注册失败: " .. tool_def.name, vim.log.levels.WARN)
    return false
  end

  -- vim.notify("[NeoAI] 工具注册成功: " .. tool_def.name, vim.log.levels.INFO)
  return true
end

--- 获取所有工具
--- @return table 工具列表
function M.get_tools()
  if not state.initialized then
    error("Tools system not initialized")
  end

  return tool_registry.list()
end

--- 执行工具
--- @param tool_name string 工具名称
--- @param args table 参数
--- @return any 执行结果
function M.execute_tool(tool_name, args)
  if not state.initialized then
    error("Tools system not initialized")
  end

  return tool_executor.execute(tool_name, args)
end

--- 注销工具
--- @param tool_name string 工具名称
--- @return boolean 是否注销成功
function M.unregister_tool(tool_name)
  if not state.initialized then
    error("Tools system not initialized")
  end

  return tool_registry.unregister(tool_name)
end

--- 获取工具定义
--- @param tool_name string 工具名称
--- @return table|nil 工具定义
function M.get_tool(tool_name)
  if not state.initialized then
    error("Tools system not initialized")
  end

  return tool_registry.get(tool_name)
end

--- 验证工具参数
--- @param tool_name string 工具名称
--- @param args table 参数
--- @return boolean, string 是否有效，错误信息
function M.validate_tool_args(tool_name, args)
  if not state.initialized then
    error("Tools system not initialized")
  end

  local tool = tool_registry.get(tool_name)
  if not tool then
    return false, "工具不存在: " .. tool_name
  end

  return tool_validator.validate_parameters(tool.parameters, args)
end

--- 重新加载工具
function M.reload_tools()
  if not state.initialized then
    error("Tools system not initialized")
  end

  -- 清空注册表
  tool_registry.clear()

  -- 重新加载工具
  if state.config.builtin ~= false then
    M._load_builtin_tools()
  end

  if state.config.external and #state.config.external > 0 then
    M._load_external_tools(state.config.external)
  end

  vim.notify("工具重新加载完成", vim.log.levels.INFO)
end

--- 获取工具数量
--- @return number 工具数量
function M.get_tool_count()
  if not state.initialized then
    error("Tools system not initialized")
  end

  local tools = tool_registry.list()
  return #tools
end

--- 搜索工具
--- @param query string 搜索查询
--- @return table 匹配的工具列表
function M.search_tools(query)
  if not state.initialized then
    error("Tools system not initialized")
  end

  local all_tools = tool_registry.list()
  local results = {}

  query = query:lower()
  for _, tool in ipairs(all_tools) do
    if
      tool.name:lower():find(query, 1, true)
      or (tool.description and tool.description:lower():find(query, 1, true))
    then
      table.insert(results, tool)
    end
  end

  return results
end

--- 加载内置工具（内部使用）
function M._load_builtin_tools()
  if state.builtin_tools_loaded then
    return
  end

  -- 加载文件工具
  local file_tools = require("NeoAI.tools.builtin.file_tools")
  if file_tools and file_tools.get_tools then
    local tools = file_tools.get_tools()
    for _, tool in ipairs(tools) do
      M.register_tool(tool)
    end
  end

  -- 加载通用工具
  local general_tools = require("NeoAI.tools.builtin.general_tools")
  if general_tools and general_tools.get_tools then
    local tools = general_tools.get_tools()
    for _, tool in ipairs(tools) do
      M.register_tool(tool)
    end
  end

  -- 加载文件工具（确保目录）
  local file_utils_tools = require("NeoAI.tools.builtin.file_utils_tools")
  if file_utils_tools and file_utils_tools.get_tools then
    local tools = file_utils_tools.get_tools()
    for _, tool in ipairs(tools) do
      M.register_tool(tool)
    end
  end

  -- 加载日志工具
  local log_tools = require("NeoAI.tools.builtin.log_tools")
  if log_tools and log_tools.get_tools then
    local tools = log_tools.get_tools()
    for _, tool in ipairs(tools) do
      M.register_tool(tool)
    end
  end

  state.builtin_tools_loaded = true
end

--- 加载外部工具（内部使用）
--- @param external_tools table 外部工具配置
function M._load_external_tools(external_tools)
  for _, tool_config in ipairs(external_tools) do
    if tool_config.path then
      -- 从文件加载
      local ok, tool_module = pcall(require, tool_config.path)
      if ok and tool_module and tool_module.get_tools then
        local tools = tool_module.get_tools()
        for _, tool in ipairs(tools) do
          M.register_tool(tool)
        end
      end
    elseif tool_config.definition then
      -- 直接使用定义
      M.register_tool(tool_config.definition)
    end
  end
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  state.config = vim.tbl_extend("force", state.config, new_config or {})

  -- 更新子模块配置
  tool_registry.update_config(state.config)
  tool_executor.update_config(state.config)
  tool_validator.update_config(state.config)

  -- 更新新模块配置
  event_bus.initialize(state.config)
  history_manager.initialize(state.config)
  config_manager.initialize(state.config)
end

--- 获取事件总线实例
--- @return table 事件总线实例
function M.get_event_bus()
  if not state.initialized then
    error("Tools system not initialized")
  end

  return event_bus
end

--- 获取历史管理器实例
--- @return table 历史管理器实例
function M.get_history_manager()
  if not state.initialized then
    error("Tools system not initialized")
  end

  return history_manager
end

--- 获取配置管理器实例
--- @return table 配置管理器实例
function M.get_config_manager()
  if not state.initialized then
    error("Tools system not initialized")
  end

  return config_manager
end

return M
