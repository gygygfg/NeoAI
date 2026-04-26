-- NeoAI 工具系统主模块
local M = {}

local tool_registry = require("NeoAI.tools.tool_registry")
local tool_executor = require("NeoAI.tools.tool_executor")
local tool_validator = require("NeoAI.tools.tool_validator")
local tool_history_manager = require("NeoAI.tools.tool_history_manager")

local initialized = false
local builtin_tools_loaded = false

--- 初始化工具系统
--- @param tools_config table 工具配置表
--- @return table 工具系统实例
function M.initialize(tools_config)
  if initialized then
    return M
  end

  local config = tools_config or {}

  tool_registry.initialize(config)
  tool_executor.initialize(config)
  tool_validator.initialize(config)
  tool_history_manager.initialize(config)

  if config.builtin ~= false then
    M._load_builtin_tools()
  end

  if config.external and #config.external > 0 then
    M._load_external_tools(config.external)
  end

  initialized = true
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
function M.get_tools()
  if not initialized then error("工具系统未初始化") end
  return tool_registry.list()
end

--- 执行指定工具
function M.execute_tool(tool_name, args)
  if not initialized then error("工具系统未初始化") end
  return tool_executor.execute(tool_name, args)
end

--- 注销指定工具
function M.unregister_tool(tool_name)
  if not initialized then error("工具系统未初始化") end
  return tool_registry.unregister(tool_name)
end

--- 获取指定工具的定义
function M.get_tool(tool_name)
  if not initialized then error("工具系统未初始化") end
  return tool_registry.get(tool_name)
end

--- 验证工具参数
function M.validate_tool_args(tool_name, args)
  if not initialized then error("工具系统未初始化") end
  local tool = tool_registry.get(tool_name)
  if not tool then
    return false, "工具不存在: " .. tool_name
  end
  return tool_validator.validate_parameters(tool.parameters, args)
end

--- 重新加载所有工具
function M.reload_tools()
  if not initialized then error("工具系统未初始化") end
  tool_registry.clear()
  builtin_tools_loaded = false
  local config = require("NeoAI.core.state").get_config()
  local tools_config = (config and config.tools) or {}
  if tools_config.builtin ~= false then
    M._load_builtin_tools()
  end
  if tools_config.external and #tools_config.external > 0 then
    M._load_external_tools(tools_config.external)
  end
  vim.notify("工具重新加载完成", vim.log.levels.INFO)
end

--- 获取已注册工具的数量
function M.get_tool_count()
  if not initialized then error("工具系统未初始化") end
  return #tool_registry.list()
end

--- 搜索工具
function M.search_tools(query)
  if not initialized then error("工具系统未初始化") end
  local all_tools = tool_registry.list()
  local results = {}
  query = query:lower()
  for _, tool in ipairs(all_tools) do
    if tool.name:lower():find(query, 1, true)
      or (tool.description and tool.description:lower():find(query, 1, true)) then
      table.insert(results, tool)
    end
  end
  return results
end

--- 加载内置工具（内部使用）
function M._load_builtin_tools()
  if builtin_tools_loaded then
    return
  end

  local modules = {
    "NeoAI.tools.builtin.file_tools",
    "NeoAI.tools.builtin.general_tools",
    "NeoAI.tools.builtin.log_tools",
  }

  for _, mod_path in ipairs(modules) do
    local ok, mod = pcall(require, mod_path)
    if ok and mod and mod.get_tools then
      local tools = mod.get_tools()
      for _, tool in ipairs(tools) do
        M.register_tool(tool)
      end
    end
  end

  builtin_tools_loaded = true
end

--- 加载外部工具（内部使用）
function M._load_external_tools(external_tools)
  for _, tool_config in ipairs(external_tools) do
    if tool_config.path then
      local ok, tool_module = pcall(require, tool_config.path)
      if ok and tool_module and tool_module.get_tools then
        local tools = tool_module.get_tools()
        for _, tool in ipairs(tools) do
          M.register_tool(tool)
        end
      end
    elseif tool_config.definition then
      M.register_tool(tool_config.definition)
    end
  end
end

--- 更新工具系统配置
function M.update_config(new_config)
  if not initialized then return end
  local config = require("NeoAI.core.state").get_config()
  local tools_config = (config and config.tools) or {}
  local merged = vim.tbl_extend("force", tools_config, new_config or {})
  tool_registry.update_config(merged)
  tool_executor.update_config(merged)
  tool_validator.update_config(merged)
  tool_history_manager.update_config(merged)
end

--- 获取历史管理器实例
function M.get_history_manager()
  if not initialized then error("工具系统未初始化") end
  return tool_history_manager
end

return M
