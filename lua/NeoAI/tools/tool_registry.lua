-- 工具注册表模块
-- 提供工具的注册、管理、查询等功能

local logger = require("NeoAI.utils.logger")
local approval_state = require("NeoAI.tools.approval_state")
local M = {}

local tools = {}
local tool_categories = {}
local state = { initialized = false, config = nil }

-- ========== 审批配置默认值 ==========
-- 注意：审批行为（auto_allow）由各工具在注册时自行设置，此处不设默认值
local DEFAULT_APPROVAL = {
  -- 允许的目录列表（相对于工作目录的路径模式）
  allowed_directories = {},
  -- 允许的参数组（参数名 -> 允许的值列表）
  allowed_param_groups = {},
}

local function guard()
  if not state.initialized then
    error("工具注册表未初始化，请先调用 M.initialize()")
  end
end

-- ========== 工作目录获取（优先通过 git 确定） ==========

--- 获取工作目录，优先通过 git 确定
--- @return string 工作目录路径
function M.get_work_dir()
  guard()
  -- 优先通过 git 获取工作目录
  local git_toplevel = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("%s+$", "")
  if git_toplevel and git_toplevel ~= "" and vim.v.shell_error == 0 then
    return git_toplevel
  end
  -- 回退到 Neovim 当前工作目录
  return vim.fn.getcwd()
end

-- ========== 审批配置管理 ==========

--- 获取工具的审批配置
--- 优先级：
---   1. approval_state 运行时配置（由 approval_config_editor 写入，所有模块共享）
---   2. 工具自身定义的审批设置（注册时的 approval 字段）
---   3. 全局默认配置
--- 工具注册时可通过 approval 字段自定义：
---   approval.auto_allow - true（自动允许）或 false（需要用户审批）
---   approval.allowed_directories - 允许的目录列表
---   approval.allowed_param_groups - 允许的参数组
--- @param tool_name string 工具名称
--- @return table 审批配置 { auto_allow, allowed_directories, allowed_param_groups }
function M.get_approval_config(tool_name)
  guard()

  -- 优先级1：approval_state 运行时配置（所有模块共享同一变量）
  local runtime_config = approval_state.get_tool_config(tool_name)
  if runtime_config then
    return vim.deepcopy(runtime_config)
  end

  local tool = tools[tool_name]
  if not tool then
    -- 工具不存在时，返回全局默认配置
    local config_approval = state.config.approval or {}
    local result = vim.deepcopy(DEFAULT_APPROVAL)
    if config_approval.default_auto_allow ~= nil then
      result.auto_allow = config_approval.default_auto_allow
    end
    if config_approval.allowed_directories then
      result.allowed_directories = config_approval.allowed_directories
    end
    if config_approval.allowed_param_groups then
      result.allowed_param_groups = config_approval.allowed_param_groups
    end
    return result
  end

  -- 优先级2：合并工具自定义审批配置和全局默认配置
  local tool_approval = tool.approval or {}
  local config_approval = state.config.approval or {}

  local result = {
    auto_allow = (tool_approval.auto_allow ~= nil) and tool_approval.auto_allow
      or config_approval.default_auto_allow,
    allowed_directories = tool_approval.allowed_directories
      or config_approval.allowed_directories
      or DEFAULT_APPROVAL.allowed_directories,
    allowed_param_groups = tool_approval.allowed_param_groups
      or config_approval.allowed_param_groups
      or DEFAULT_APPROVAL.allowed_param_groups,
  }

  return result
end

--- 设置全局审批配置
--- @param approval_config table 审批配置
---   approval_config.default_auto_allow - boolean
---   approval_config.allowed_directories - string[] 允许的目录列表
---   approval_config.allowed_param_groups - table 允许的参数组
function M.set_approval_config(approval_config)
  guard()
  if not state.config.approval then
    state.config.approval = {}
  end
  if approval_config.default_auto_allow ~= nil then
    state.config.approval.default_auto_allow = approval_config.default_auto_allow
  end
  if approval_config.allowed_directories then
    state.config.approval.allowed_directories = approval_config.allowed_directories
  end
  if approval_config.allowed_param_groups then
    state.config.approval.allowed_param_groups = approval_config.allowed_param_groups
  end
end

--- 从合并后的完整配置中应用审批配置
--- 遍历 tools.approval.tool_overrides，覆盖各工具的 approval 字段
--- 同时设置全局默认审批配置
--- @param full_config table 合并后的完整配置（来自 merger.process_config）
function M.apply_approval_config(full_config)
  guard()
  if not full_config or not full_config.tools or not full_config.tools.approval then
    return
  end

  local approval_cfg = full_config.tools.approval

  -- 设置全局默认审批配置
  local global_config = {}
  if approval_cfg.default_auto_allow ~= nil then
    global_config.default_auto_allow = approval_cfg.default_auto_allow
  end
  if approval_cfg.allowed_directories then
    global_config.allowed_directories = approval_cfg.allowed_directories
  end
  if approval_cfg.allowed_param_groups then
    global_config.allowed_param_groups = approval_cfg.allowed_param_groups
  end
  M.set_approval_config(global_config)

  -- 应用各工具单独覆盖配置
  local tool_overrides = approval_cfg.tool_overrides or {}
  for tool_name, override in pairs(tool_overrides) do
    if type(override) == "table" and tools[tool_name] then
      local tool = tools[tool_name]

      -- 合并覆盖配置到工具的 approval 字段
      if not tool.approval then
        tool.approval = {}
      end

      if override.auto_allow ~= nil then
        tool.approval.auto_allow = override.auto_allow
      end
      if override.allowed_directories ~= nil then
        tool.approval.allowed_directories = override.allowed_directories
      end
      if override.allowed_param_groups ~= nil then
        tool.approval.allowed_param_groups = override.allowed_param_groups
      end

      logger.debug(
        "[tool_registry] 应用工具 '%s' 的审批覆盖配置: auto_allow=%s",
        tool_name,
        tostring(tool.approval.auto_allow)
      )
    end
  end
end

function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = config or {}
  -- 初始化审批配置
  if not state.config.approval then
    state.config.approval = vim.deepcopy(DEFAULT_APPROVAL)
  end
  tools = {}
  tool_categories = {}
  state.initialized = true
end

function M.register(tool)
  guard()
  if not tool or not tool.name then
    return false
  end
  if tools[tool.name] then
    return false
  end

  local valid, error_msg = M.validate_tool(tool)
  if not valid then
    logger.debug("[tool_registry] ❌ 验证失败[" .. tool.name .. "]: " .. error_msg)
    return false
  end

  tools[tool.name] = vim.deepcopy(tool)
  local category = tool.category or "uncategorized"
  if not tool_categories[category] then
    tool_categories[category] = {}
  end
  table.insert(tool_categories[category], tool.name)
  return true
end

function M.unregister(tool_name)
  guard()
  if not tools[tool_name] then
    return false
  end

  local tool = tools[tool_name]
  local category = tool.category or "uncategorized"
  if tool_categories[category] then
    for i, name in ipairs(tool_categories[category]) do
      if name == tool_name then
        table.remove(tool_categories[category], i)
        break
      end
    end
    if #tool_categories[category] == 0 then
      tool_categories[category] = nil
    end
  end
  tools[tool_name] = nil
  return true
end

function M.get(tool_name)
  guard()
  local tool = tools[tool_name]
  return tool and vim.deepcopy(tool) or nil
end

function M.get_tool(tool_name)
  return M.get(tool_name)
end

function M.get_all_tools()
  guard()
  local result = {}
  for name, tool in pairs(tools) do
    result[name] = vim.deepcopy(tool)
  end
  return result
end

function M.list(category)
  guard()
  if category then
    local names = tool_categories[category] or {}
    local result = {}
    for _, name in ipairs(names) do
      table.insert(result, vim.deepcopy(tools[name]))
    end
    return result
  end
  local result = {}
  for _, tool in pairs(tools) do
    table.insert(result, vim.deepcopy(tool))
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

function M.validate_tool(tool)
  if not tool.name or type(tool.name) ~= "string" then
    return false, "工具名称必须是字符串"
  end
  if not tool.func or type(tool.func) ~= "function" then
    return false, "工具函数必须是函数"
  end
  if not tool.name:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
    return false, "工具名称只能包含字母、数字和下划线"
  end
  if tool.description and type(tool.description) ~= "string" then
    return false, "工具描述必须是字符串"
  end
  if tool.parameters and type(tool.parameters) ~= "table" then
    return false, "工具参数必须是表"
  end
  if tool.category and type(tool.category) ~= "string" then
    return false, "工具分类必须是字符串"
  end
  if tool.permissions and type(tool.permissions) ~= "table" then
    return false, "工具权限必须是表"
  end
  if tool.approval and type(tool.approval) ~= "table" then
    return false, "工具审批配置必须是表"
  end
  if tool.approval then
    if tool.approval.auto_allow ~= nil and type(tool.approval.auto_allow) ~= "boolean" then
      return false, "auto_allow 必须是布尔值"
    end
    if tool.approval.allowed_directories and type(tool.approval.allowed_directories) ~= "table" then
      return false, "允许目录必须是列表"
    end
    if tool.approval.allowed_param_groups and type(tool.approval.allowed_param_groups) ~= "table" then
      return false, "允许参数组必须是表"
    end
  end
  return true, ""
end

function M.get_categories()
  guard()
  local categories = {}
  for cat, _ in pairs(tool_categories) do
    table.insert(categories, cat)
  end
  table.sort(categories)
  return categories
end

function M.get_category_tool_count(category)
  guard()
  return tool_categories[category] and #tool_categories[category] or 0
end

function M.search(query, search_fields)
  guard()
  if not query or query == "" then
    return M.list()
  end
  query = query:lower()
  search_fields = search_fields or { "name", "description", "category" }
  local results = {}
  for _, tool in pairs(tools) do
    for _, field in ipairs(search_fields) do
      local value = tool[field]
      if value and type(value) == "string" and value:lower():find(query, 1, true) then
        table.insert(results, vim.deepcopy(tool))
        break
      end
    end
  end
  table.sort(results, function(a, b)
    return a.name < b.name
  end)
  return results
end

function M.clear()
  guard()
  tools = {}
  tool_categories = {}
end

function M.reset()
  state.initialized = false
  state.config = nil
  tools = {}
  tool_categories = {}
end

function M.exists(tool_name)
  guard()
  return tools[tool_name] ~= nil
end

function M.count()
  guard()
  local count = 0
  for _ in pairs(tools) do
    count = count + 1
  end
  return count
end

function M.export_tool(tool_name)
  guard()
  local tool = tools[tool_name]
  if not tool then
    return nil
  end
  return {
    name = tool.name,
    description = tool.description,
    parameters = tool.parameters,
    category = tool.category,
    permissions = tool.permissions,
    approval = tool.approval,
  }
end

function M.import_tool(tool_def, func)
  guard()
  if not tool_def or not tool_def.name then
    return false
  end
  local tool = vim.deepcopy(tool_def)
  tool.func = func
  return M.register(tool)
end

function M.update_config(new_config)
  if not state.initialized then
    return
  end
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
