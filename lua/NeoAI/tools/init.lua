-- NeoAI 工具系统主模块

local M = {}

local logger = require("NeoAI.utils.logger")
local tool_registry = require("NeoAI.tools.tool_registry")
local tool_executor = require("NeoAI.tools.tool_executor")
local tool_validator = require("NeoAI.tools.tool_validator")

local initialized = false
local builtin_tools_loaded = false

function M.initialize(tools_config)
  if initialized then return M end
  local config = tools_config or {}
  tool_registry.initialize(config)
  tool_executor.initialize(config)
  tool_validator.initialize(config)
  initialized = true
  -- 延迟加载内置工具，不阻塞初始化流程
  if config.builtin ~= false then
    vim.schedule(function()
      M._load_builtin_tools()
    end)
  end
  if config.external and #config.external > 0 then M._load_external_tools(config.external) end
  return M
end

function M.register_tool(tool_def)
  local valid, error_msg = tool_validator.validate_tool(tool_def)
  if not valid then
    vim.notify("工具验证失败: " .. error_msg, vim.log.levels.ERROR)
    return false
  end
  local success, reg_result = pcall(function() return tool_registry.register(tool_def) end)
  if not success then
    vim.notify("工具注册异常: " .. tostring(reg_result), vim.log.levels.ERROR)
    return false
  elseif reg_result == false then
    vim.notify("工具注册失败（已存在）: " .. tool_def.name, vim.log.levels.WARN)
    return false
  end
  return true
end

function M.get_tools()
  if not initialized then error("工具系统未初始化") end
  return tool_registry.list()
end

function M.execute_tool(tool_name, args)
  if not initialized then error("工具系统未初始化") end
  return tool_executor.execute(tool_name, args)
end

function M.unregister_tool(tool_name)
  if not initialized then error("工具系统未初始化") end
  return tool_registry.unregister(tool_name)
end

function M.get_tool(tool_name)
  if not initialized then error("工具系统未初始化") end
  return tool_registry.get(tool_name)
end

function M.validate_tool_args(tool_name, args)
  if not initialized then error("工具系统未初始化") end
  local tool = tool_registry.get(tool_name)
  if not tool then return false, "工具不存在: " .. tool_name end
  return tool_validator.validate_parameters(tool.parameters, args)
end

function M.reload_tools()
  if not initialized then error("工具系统未初始化") end
  tool_registry.clear()
  builtin_tools_loaded = false
  local config = require("NeoAI.core.config.state").get_config()
  local tools_config = (config and config.tools) or {}
  if tools_config.builtin ~= false then M._load_builtin_tools() end
  if tools_config.external and #tools_config.external > 0 then M._load_external_tools(tools_config.external) end
  vim.notify("工具重新加载完成", vim.log.levels.INFO)
end

function M.get_tool_count()
  if not initialized then error("工具系统未初始化") end
  return #tool_registry.list()
end

function M.search_tools(query)
  if not initialized then error("工具系统未初始化") end
  return tool_registry.search(query)
end

-- ========== 内置工具加载 ==========

function M._load_builtin_tools()
  if builtin_tools_loaded then return end

  local script_path = debug.getinfo(1).source:match("^@(.+)$")
  if not script_path then builtin_tools_loaded = true; return end

  local builtin_dir = script_path:match("^(.+/)lua/NeoAI/tools/init%.lua$")
    and script_path:match("^(.+/)lua/NeoAI/tools/init%.lua$") .. "lua/NeoAI/tools/builtin"
    or nil
  if not builtin_dir then builtin_tools_loaded = true; return end

  local handle = vim.loop.fs_scandir(builtin_dir)
  if not handle then builtin_tools_loaded = true; return end

  while true do
    local name, file_type = vim.loop.fs_scandir_next(handle)
    if not name then break end
    if file_type == "file" and name:match("%.lua$") then
      local mod_name = name:gsub("%.lua$", "")
      local ok, mod = pcall(require, "NeoAI.tools.builtin." .. mod_name)
      if ok and type(mod) == "table" and mod.get_tools then
        for _, tool in ipairs(mod.get_tools()) do
          M.register_tool(tool)
        end
      end
    end
  end

  builtin_tools_loaded = true

  -- 内置工具加载完成后，刷新 tool_pack 的工具包分组
  local tp_ok, tp = pcall(require, "NeoAI.tools.tool_pack")
  if tp_ok and tp.initialize then
    tp.initialize()
  end
end

function M._load_external_tools(external_tools)
  for _, tool_config in ipairs(external_tools) do
    if tool_config.path then
      local ok, mod = pcall(require, tool_config.path)
      if ok and mod and mod.get_tools then
        for _, tool in ipairs(mod.get_tools()) do
          M.register_tool(tool)
        end
      end
    elseif tool_config.definition then
      M.register_tool(tool_config.definition)
    end
  end
end

-- ========== 配置 ==========

function M.update_config(new_config)
  if not initialized then return end
  local config = require("NeoAI.core.config.state").get_config()
  local tools_config = (config and config.tools) or {}
  local merged = vim.tbl_extend("force", tools_config, new_config or {})
  tool_registry.update_config(merged)
  tool_executor.update_config(merged)
  tool_validator.update_config(merged)
end

function M.get_history_manager()
  if not initialized then error("工具系统未初始化") end
  return require("NeoAI.core.history.manager")
end

return M
