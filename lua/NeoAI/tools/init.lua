-- NeoAI 工具系统主模块
local M = {}

local tool_registry = require("NeoAI.tools.tool_registry")
local tool_executor = require("NeoAI.tools.tool_executor")
local tool_validator = require("NeoAI.tools.tool_validator")

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

  -- print("[NeoAI.tools.init] register_tool 开始: " .. (tool_def and tool_def.name or "nil"))

  -- 验证工具定义的合法性
  local valid, error_msg = tool_validator.validate_tool(tool_def)
  if not valid then
    local error_level = vim.log.levels and vim.log.levels.ERROR or "ERROR"
    print("[NeoAI.tools.init] 工具验证失败: " .. tool_def.name .. " - " .. error_msg)
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
    print("[NeoAI.tools.init] 工具注册异常: " .. tool_def.name .. " - " .. tostring(reg_result))
    vim.notify("工具注册异常: " .. reg_result, error_level)
    return false
  elseif reg_result == false then
    -- 注册失败但没有抛出异常（例如工具已存在等情况）
    local warn_level = vim.log.levels and vim.log.levels.WARN or "WARN"
    print("[NeoAI.tools.init] 工具注册失败（已存在）: " .. tool_def.name)
    vim.notify("工具注册失败: " .. tool_def.name, warn_level)
    return false
  end

  -- 注册成功
  -- print("[NeoAI.tools.init] 工具注册成功: " .. tool_def.name)
  return true
end

--- 获取所有已注册的工具列表
function M.get_tools()
  if not initialized then
    error("工具系统未初始化")
  end
  return tool_registry.list()
end

--- 执行指定工具
function M.execute_tool(tool_name, args)
  if not initialized then
    print("[NeoAI.tools.init] execute_tool 失败: 工具系统未初始化")
    error("工具系统未初始化")
  end
  local result = tool_executor.execute(tool_name, args)
  print("[NeoAI.tools.init] execute_tool 结束: " .. tool_name)
  return result
end

--- 注销指定工具
function M.unregister_tool(tool_name)
  if not initialized then
    print("[NeoAI.tools.init] unregister_tool 失败: 工具系统未初始化")
    error("工具系统未初始化")
  end
  print("[NeoAI.tools.init] unregister_tool: " .. tool_name)
  local result = tool_registry.unregister(tool_name)
  print("[NeoAI.tools.init] unregister_tool 结果: " .. tostring(result))
  return result
end

--- 获取指定工具的定义
function M.get_tool(tool_name)
  if not initialized then
    print("[NeoAI.tools.init] get_tool 失败: 工具系统未初始化")
    error("工具系统未初始化")
  end
  print("[NeoAI.tools.init] get_tool: " .. tool_name)
  local tool = tool_registry.get(tool_name)
  print("[NeoAI.tools.init] get_tool 结果: " .. (tool and "找到" or "未找到"))
  return tool
end

--- 验证工具参数
function M.validate_tool_args(tool_name, args)
  if not initialized then
    print("[NeoAI.tools.init] validate_tool_args 失败: 工具系统未初始化")
    error("工具系统未初始化")
  end
  print("[NeoAI.tools.init] validate_tool_args: " .. tool_name)
  local tool = tool_registry.get(tool_name)
  if not tool then
    print("[NeoAI.tools.init] validate_tool_args: 工具不存在 - " .. tool_name)
    return false, "工具不存在: " .. tool_name
  end
  local valid, err = tool_validator.validate_parameters(tool.parameters, args)
  print("[NeoAI.tools.init] validate_tool_args 结果: valid=" .. tostring(valid) .. ", err=" .. tostring(err))
  return valid, err
end

--- 重新加载所有工具
function M.reload_tools()
  if not initialized then
    print("[NeoAI.tools.init] reload_tools 失败: 工具系统未初始化")
    error("工具系统未初始化")
  end
  print("[NeoAI.tools.init] 开始重新加载所有工具...")
  tool_registry.clear()
  builtin_tools_loaded = false
  local config = require("NeoAI.core.state").get_config()
  local tools_config = (config and config.tools) or {}
  if tools_config.builtin ~= false then
    print("[NeoAI.tools.init] 重新加载内置工具")
    M._load_builtin_tools()
  end
  if tools_config.external and #tools_config.external > 0 then
    print("[NeoAI.tools.init] 重新加载外部工具")
    M._load_external_tools(tools_config.external)
  end
  print("[NeoAI.tools.init] 工具重新加载完成")
  vim.notify("工具重新加载完成", vim.log.levels.INFO)
end

--- 获取已注册工具的数量
function M.get_tool_count()
  if not initialized then
    error("工具系统未初始化")
  end
  return #tool_registry.list()
end

--- 搜索工具
function M.search_tools(query)
  if not initialized then
    error("工具系统未初始化")
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
  if builtin_tools_loaded then
    print("[NeoAI.tools.init] 内置工具已加载，跳过")
    return
  end

  -- 根据当前脚本路径动态计算 builtin 目录
  -- debug.getinfo(1).source 返回 @/path/to/init.lua
  local script_path = debug.getinfo(1).source:match("^@(.+)$")
  if not script_path then
    print("[NeoAI.tools.init] 无法获取脚本路径")
    builtin_tools_loaded = true
    return
  end
  local builtin_dir = script_path:match("^(.+/)lua/NeoAI/tools/init%.lua$")
      and script_path:match("^(.+/)lua/NeoAI/tools/init%.lua$") .. "lua/NeoAI/tools/builtin"
    or nil

  if not builtin_dir then
    print("[NeoAI.tools.init] 无法计算 builtin 目录路径")
    builtin_tools_loaded = true
    return
  end

  local handle = vim.loop.fs_scandir(builtin_dir)
  if not handle then
    print("[NeoAI.tools.init] 无法打开 builtin 目录: " .. builtin_dir)
    builtin_tools_loaded = true
    return
  end

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    if type == "file" and name:match("%.lua$") then
      local mod_name = name:gsub("%.lua$", "")
      local ok, mod = pcall(require, "NeoAI.tools.builtin." .. mod_name)
      if ok and mod and mod.get_tools then
        local tools = mod.get_tools()
        for _, tool in ipairs(tools) do
          M.register_tool(tool)
        end
      end
      -- 没有 get_tools 的模块（如 tool_helpers.lua）直接跳过，不报错
    end
  end

  builtin_tools_loaded = true
end

--- 加载外部工具（内部使用）
function M._load_external_tools(external_tools)
  for i, tool_config in ipairs(external_tools) do
    if tool_config.path then
      local ok, tool_module = pcall(require, tool_config.path)
      if ok and tool_module and tool_module.get_tools then
        local tools = tool_module.get_tools()
        for _, tool in ipairs(tools) do
          M.register_tool(tool)
        end
      else
        print("[NeoAI.tools.init] 外部模块加载失败: " .. tostring(tool_config.path))
      end
    elseif tool_config.definition then
      print("[NeoAI.tools.init] 注册外部工具定义: " .. (tool_config.definition.name or "unnamed"))
      M.register_tool(tool_config.definition)
    end
  end
end

--- 更新工具系统配置
function M.update_config(new_config)
  if not initialized then
    print("[NeoAI.tools.init] update_config 跳过: 未初始化")
    return
  end
  local config = require("NeoAI.core.state").get_config()
  local tools_config = (config and config.tools) or {}
  local merged = vim.tbl_extend("force", tools_config, new_config or {})
  tool_registry.update_config(merged)
  tool_executor.update_config(merged)
  tool_validator.update_config(merged)
end

--- 获取历史管理器实例（委托给 core.history_manager）
function M.get_history_manager()
  if not initialized then
    error("工具系统未初始化")
  end
  return require("NeoAI.core.history_manager")
end

return M
