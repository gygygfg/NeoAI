-- NeoAI 工具系统主模块

local M = {}

local logger = require("NeoAI.utils.logger")
local tool_registry = require("NeoAI.tools.tool_registry")
local tool_executor = require("NeoAI.tools.tool_executor")
local tool_validator = require("NeoAI.tools.tool_validator")

local initialized = false
local builtin_tools_loaded = false
local full_config = {}  -- 合并后的完整配置

--- 获取完整配置（供子模块使用，如 approval_handler 获取 keymaps）
--- @return table
function M.get_full_config()
  return full_config
end

function M.initialize(config)
  if initialized then return M end
  full_config = config or {}
  local tools_config = config.tools or {}
  tool_registry.initialize(tools_config)
  tool_executor.initialize(tools_config)
  tool_validator.initialize(tools_config)
  initialized = true
  -- 内置工具同步加载（ensure_tools 在首次使用时才调用，用户已等待）
  if tools_config.builtin ~= false then
    M._load_builtin_tools()
  end
  -- 外部工具通过 tool_registry 统一加载（从 merger.lua 合并后的完整配置）
  tool_registry.load_external_tools_from_config(config)
  return M
end
--- 检查工具系统是否已初始化
--- @return boolean
function M.is_initialized()
  return initialized
end

function M.register_tool(tool_def)
  -- 检查工具是否被禁用（通过 tool_overrides 中的 enable 字段）
  local tools_config = full_config.tools or {}
  local approval_cfg = tools_config.approval or {}
  local tool_overrides = approval_cfg.tool_overrides or {}
  local override = tool_overrides[tool_def.name]
  if override and override.enable == false then
    local logger = require("NeoAI.utils.logger")
    logger.debug("[tools.init] 工具已被禁用，跳过注册: " .. tool_def.name)
    return false
  end

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
  -- 清除审批配置初始化标记，允许重新写入
  local approval_state = require("NeoAI.tools.approval_state")
  approval_state.clear_initialized()
  tool_registry.clear()
  builtin_tools_loaded = false
  local tools_config = full_config.tools or {}
  if tools_config.builtin ~= false then M._load_builtin_tools() end
  -- 外部工具通过 tool_registry 统一加载
  tool_registry.load_external_tools_from_config(full_config)
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
  if not script_path then
    -- 回退：当 debug.getinfo 不可用时（如打包环境），使用 stdpath
    script_path = vim.fn.stdpath("data") .. "/lazy/NeoAI/lua/NeoAI/tools/init.lua"
  end
  local builtin_dir = script_path:match("^(.+/)lua/NeoAI/tools/init%.lua$")
    and script_path:match("^(.+/)lua/NeoAI/tools/init%.lua$") .. "lua/NeoAI/tools/builtin"
    or nil
  if not builtin_dir then
    -- 回退：尝试从 runtimepath 查找
    for _, rt in ipairs(vim.api.nvim_list_runtime_paths()) do
      local candidate = rt .. "/lua/NeoAI/tools/builtin"
      if vim.uv.fs_stat(candidate) then
        builtin_dir = candidate
        break
      end
    end
  end
  if not builtin_dir then builtin_tools_loaded = true; return end

  local handle = vim.uv.fs_scandir(builtin_dir)
  if not handle then builtin_tools_loaded = true; return end

  while true do
    local name, file_type = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if file_type == "file" and name:match("%.lua$") then
      local mod_name = name:gsub("%.lua$", "")
      local ok, mod = pcall(require, "NeoAI.tools.builtin." .. mod_name)
      if ok and type(mod) == "table" then
        local tools = tool_registry.extract_tools_from_module(mod)
        for _, tool in ipairs(tools) do
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

  -- 重新应用审批配置覆盖
  -- 此时所有内置工具均已注册，确保用户配置的 tool_overrides 生效
  if full_config and full_config.tools and full_config.tools.approval then
    local tr = require("NeoAI.tools.tool_registry")
    pcall(tr.apply_approval_config, full_config)
  end
end

-- ========== 配置 ==========

function M.update_config(new_config)
  if not initialized then return end
  local tools_config = full_config.tools or {}
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
