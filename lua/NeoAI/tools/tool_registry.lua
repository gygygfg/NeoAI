-- 工具注册表模块
-- 提供工具的注册、管理、查询等功能

local logger = require("NeoAI.utils.logger")
local approval_state = require("NeoAI.tools.approval_state")
local M = {}

local tools = {}
local tool_categories = {}
local state = { initialized = false, config = nil }

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
  local git_toplevel = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("%s+$", "")
  if git_toplevel and git_toplevel ~= "" and vim.v.shell_error == 0 then
    return git_toplevel
  end
  return vim.fn.getcwd()
end

-- ========== 审批配置管理 ==========

--- 获取工具的审批配置
--- 统一从 approval_state 读取（静态配置 + 运行时修改均存储于此）
--- 优先级：
---   1. 工具级配置（由 approval_state.initialize_from_config 或 approval_config_editor 写入）
---   2. 全局默认配置
---   3. 工具注册时的 approval 字段（兜底）
--- @param tool_name string 工具名称
--- @return table { auto_allow?, allowed_directories?, allowed_param_groups? }
function M.get_approval_config(tool_name)
  guard()

  -- 从 approval_state 获取（已包含工具级和全局默认配置的合并）
  local config = approval_state.get_tool_config(tool_name)
  if config then
    return vim.deepcopy(config)
  end

  -- 兜底：工具注册时的 approval 字段
  local tool = tools[tool_name]
  if tool and tool.approval then
    return vim.deepcopy(tool.approval)
  end

  return {}
end

--- 从合并后的完整配置中初始化审批配置
--- 委托给 approval_state.initialize_from_config
--- @param full_config table 合并后的完整配置（来自 merger.process_config）
function M.apply_approval_config(full_config)
  guard()
  approval_state.initialize_from_config(full_config)
end

function M.initialize(config)
  if state.initialized then
    return
  end
  state.config = config or {}
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
