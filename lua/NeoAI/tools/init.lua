-- NeoAI 工具系统主模块
-- 负责管理工具系统的初始化、注册、执行和生命周期管理
local M = {}

-- 导入依赖模块
local tool_registry = require("NeoAI.tools.tool_registry")
local tool_executor = require("NeoAI.tools.tool_executor")
local tool_validator = require("NeoAI.tools.tool_validator")
local tool_history_manager = require("NeoAI.tools.tool_history_manager")
-- 注意：event_bus 已被移除，使用 core/events 系统替代
-- 注意：config 模块不再直接导入，配置由主 init 传入

-- 模块内部状态
local state = {
  initialized = false, -- 系统是否已初始化
  config = nil, -- 工具系统配置
  builtin_tools_loaded = false, -- 内置工具是否已加载
}

--- 初始化工具系统
--- @param tools_config table 工具配置表
--- @return table 工具系统实例
function M.initialize(tools_config)
  -- 如果已初始化，直接返回实例避免重复初始化
  if state.initialized then
    return M
  end

  -- 保存配置，如果未提供配置则使用空表
  state.config = tools_config or {}

  -- 初始化各个子模块
  tool_registry.initialize(state.config)
  tool_executor.initialize(state.config)
  tool_validator.initialize(state.config)

  -- 初始化历史管理器
  tool_history_manager.initialize(state.config)
  
  -- 初始化配置（如果需要的话）
  -- 注意：tools_config 应该是已经处理好的配置，所以这里不需要再次初始化

  -- 加载内置工具（如果配置允许）
  if state.config.builtin ~= false then
    M._load_builtin_tools()
  end

  -- 加载外部工具（如果配置中存在）
  if state.config.external and #state.config.external > 0 then
    M._load_external_tools(state.config.external)
  end

  -- 标记系统已初始化
  state.initialized = true
  return M
end

--- 注册一个新工具
--- @param tool_def table 工具定义表，包含工具名称、描述、参数等信息
--- @return boolean 是否注册成功
function M.register_tool(tool_def)
  -- 注意：在初始化过程中也可以调用此函数

  -- 验证工具定义的合法性
  local valid, error_msg = tool_validator.validate_tool(tool_def)
  if not valid then
    local error_level = vim.log.levels and vim.log.levels.ERROR or "ERROR"
    vim.notify("工具验证失败: " .. error_msg, error_level)
    return false
  end

  -- 使用pcall安全地调用注册函数，捕获可能的异常
  local success, reg_result = pcall(function()
    return tool_registry.register(tool_def)
  end)

  -- 处理注册结果
  if not success then
    -- 注册过程中发生异常
    local error_level = vim.log.levels and vim.log.levels.ERROR or "ERROR"
    vim.notify("工具注册异常: " .. reg_result, error_level)
    return false
  elseif reg_result == false then
    -- 注册失败但没有抛出异常（例如工具已存在等情况）
    local warn_level = vim.log.levels and vim.log.levels.WARN or "WARN"
    vim.notify("工具注册失败: " .. tool_def.name, warn_level)
    return false
  end

  -- 注册成功
  return true
end

--- 获取所有已注册的工具列表
--- @return table 工具列表
function M.get_tools()
  if not state.initialized then
    error("工具系统未初始化")
  end

  return tool_registry.list()
end

--- 执行指定工具
--- @param tool_name string 要执行的工具名称
--- @param args table 执行工具所需的参数
--- @return any 工具执行结果
function M.execute_tool(tool_name, args)
  if not state.initialized then
    error("工具系统未初始化")
  end

  return tool_executor.execute(tool_name, args)
end

--- 注销指定工具
--- @param tool_name string 要注销的工具名称
--- @return boolean 是否注销成功
function M.unregister_tool(tool_name)
  if not state.initialized then
    error("工具系统未初始化")
  end

  return tool_registry.unregister(tool_name)
end

--- 获取指定工具的定义
--- @param tool_name string 工具名称
--- @return table|nil 工具定义表，如果不存在则返回nil
function M.get_tool(tool_name)
  if not state.initialized then
    error("工具系统未初始化")
  end

  return tool_registry.get(tool_name)
end

--- 验证工具参数是否合法
--- @param tool_name string 工具名称
--- @param args table 要验证的参数
--- @return boolean, string 是否有效，错误信息
function M.validate_tool_args(tool_name, args)
  if not state.initialized then
    error("工具系统未初始化")
  end

  -- 先检查工具是否存在
  local tool = tool_registry.get(tool_name)
  if not tool then
    return false, "工具不存在: " .. tool_name
  end

  -- 验证参数
  return tool_validator.validate_parameters(tool.parameters, args)
end

--- 重新加载所有工具
--- 先清空注册表，然后重新加载内置和外部工具
function M.reload_tools()
  if not state.initialized then
    error("工具系统未初始化")
  end

  -- 清空注册表
  tool_registry.clear()

  -- 重置内置工具加载状态
  state.builtin_tools_loaded = false

  -- 重新加载工具
  if state.config.builtin ~= false then
    M._load_builtin_tools()
  end

  if state.config.external and #state.config.external > 0 then
    M._load_external_tools(state.config.external)
  end

  local info_level = vim.log.levels and vim.log.levels.INFO or "INFO"
  vim.notify("工具重新加载完成", info_level)
end

--- 获取已注册工具的数量
--- @return number 工具数量
function M.get_tool_count()
  if not state.initialized then
    error("工具系统未初始化")
  end

  local tools = tool_registry.list()
  return #tools
end

--- 根据查询条件搜索工具
--- @param query string 搜索关键词
--- @return table 匹配的工具列表
function M.search_tools(query)
  if not state.initialized then
    error("工具系统未初始化")
  end

  local all_tools = tool_registry.list()
  local results = {}

  -- 将查询转换为小写进行不区分大小写的搜索
  query = query:lower()

  -- 遍历所有工具，匹配名称或描述
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
  -- 避免重复加载
  if state.builtin_tools_loaded then
    return
  end

  -- 加载文件操作工具
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

  -- 加载文件工具（确保目录存在）
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
--- @param external_tools table 外部工具配置列表
function M._load_external_tools(external_tools)
  for _, tool_config in ipairs(external_tools) do
    if tool_config.path then
      -- 从Lua模块文件加载
      local ok, tool_module = pcall(require, tool_config.path)
      if ok and tool_module and tool_module.get_tools then
        local tools = tool_module.get_tools()
        for _, tool in ipairs(tools) do
          M.register_tool(tool)
        end
      end
    elseif tool_config.definition then
      -- 直接使用内联的工具定义
      M.register_tool(tool_config.definition)
    end
  end
end

--- 更新工具系统配置
--- @param new_config table 新的配置表
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  -- 合并新配置到现有配置
  state.config = vim.tbl_extend("force", state.config, new_config or {})

  -- 更新各个子模块的配置
  tool_registry.update_config(state.config)
  tool_executor.update_config(state.config)
  tool_validator.update_config(state.config)

  -- 更新历史管理器配置
  tool_history_manager.update_config(state.config)
end

--- 获取历史管理器实例
--- @return table 历史管理器实例
function M.get_history_manager()
  if not state.initialized then
    error("工具系统未初始化")
  end

  return tool_history_manager
end

--- 获取配置管理器实例
--- 直接使用 default_config.lua 的 API
--- @return table 配置管理器实例
function M.get_config_manager()
  if not state.initialized then
    error("工具系统未初始化")
  end
  return require("NeoAI.default_config")
end

-- 导出模块
return M
