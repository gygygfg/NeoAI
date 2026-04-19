local M = {}

-- 工具存储
local tools = {}
local tool_categories = {}

-- 模块状态
local state = {
  initialized = false,
  config = nil,
}

--- 初始化工具注册表
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  
  state.config = config or {}
  tools = {}
  tool_categories = {}
  state.initialized = true

--- 注册工具
--- @param tool table 工具定义
--- @return boolean 是否注册成功
function M.register(tool)
  if not state.initialized then
    error("Tool registry not initialized")
  
  if not tool or not tool.name then
    -- vim.notify("工具定义无效: 缺少名称", vim.log.levels.ERROR)
    print("❌ 工具定义无效: 缺少名称")
    return false
  
  if tools[tool.name] then
    -- vim.notify("工具已存在: " .. tool.name, vim.log.levels.WARN)
    print("⚠️  工具已存在: " .. tool.name)
    return false
  
  -- 验证工具定义
  local valid, error_msg = M.validate_tool(tool)
  if not valid then
    -- vim.notify("工具验证失败[ " .. tool.name .. "]: " .. error_msg, vim.log.levels.ERROR)
    print("❌ 工具验证失败[ " .. tool.name .. "]: " .. error_msg)
    return false
  
  -- 存储工具
  tools[tool.name] = vim.deepcopy(tool)

  -- 添加到分类
  local category = tool.category or "uncategorized"
  if not tool_categories[category] then
    tool_categories[category] = {}
  
  table.insert(tool_categories[category], tool.name)

  -- vim.notify("[NeoAI] 工具注册成功: " .. tool.name, vim.log.levels.INFO)
  return true

--- 注销工具
--- @param tool_name string 工具名称
--- @return boolean 是否注销成功
function M.unregister(tool_name)
  if not state.initialized then
    error("Tool registry not initialized")
  
  if not tools[tool_name] then
    return false
  
  -- 从分类中移除
  local tool = tools[tool_name]
  local category = tool.category or "uncategorized"
  if tool_categories[category] then
    for i, name in ipairs(tool_categories[category]) do
      if name == tool_name then
        table.remove(tool_categories[category], i)
        break
      
    
    -- 如果分类为空，删除分类
    if #tool_categories[category] == 0 then
      tool_categories[category] = nil
    
  
  -- 从工具存储中移除
  tools[tool_name] = nil

  return true

--- 获取工具定义
--- @param tool_name string 工具名称
--- @return table|nil 工具定义
function M.get(tool_name)
  if not state.initialized then
    error("Tool registry not initialized")
  
  return vim.deepcopy(tools[tool_name])

--- 获取工具（别名，用于兼容性）
--- @param tool_name string 工具名称
--- @return table|nil 工具定义
function M.get_tool(tool_name)
  return M.get(tool_name)

--- 获取所有工具（以名称为键的表）
--- @return table 所有工具的表
function M.get_all_tools()
  if not state.initialized then
    error("Tool registry not initialized")
  
  local result = {}
  for name, tool in pairs(tools) do
    result[name] = vim.deepcopy(tool)
  
  return result

--- 列出所有工具
--- @param category string|nil 分类（可选）
--- @return table 工具列表
function M.list(category)
  if not state.initialized then
    error("Tool registry not initialized")
  
  if category then
    -- 返回特定分类的工具
    local category_tools = tool_categories[category] or {}
    local result = {}
    for _, tool_name in ipairs(category_tools) do
      table.insert(result, vim.deepcopy(tools[tool_name]))
    
    return result
  else
    -- 返回所有工具
    local result = {}
    for _, tool in pairs(tools) do
      table.insert(result, vim.deepcopy(tool))
    
    -- 按名称排序
    table.sort(result, function(a, b)
      return a.name < b.name
    end)
    return result
  

--- 验证工具定义
--- @param tool table 工具定义
--- @return boolean, string 是否有效，错误信息
function M.validate_tool(tool)
  -- 检查必需字段
  if not tool.name or type(tool.name) ~= "string" then
    return false, "工具名称必须是字符串"
  
  if not tool.func or type(tool.func) ~= "function" then
    return false, "工具函数必须是函数"
  
  -- 检查名称格式
  if not tool.name:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
    return false,
      "工具名称只能包含字母、数字和下划线，且不能以数字开头。当前名称: '"
        .. tool.name
        .. "'"
  
  -- 检查描述（可选但推荐）
  if tool.description and type(tool.description) ~= "string" then
    return false, "工具描述必须是字符串"
  
  -- 检查参数模式（可选）
  if tool.parameters and type(tool.parameters) ~= "table" then
    return false, "工具参数必须是表"
  
  -- 检查分类（可选）
  if tool.category and type(tool.category) ~= "string" then
    return false, "工具分类必须是字符串"
  
  -- 检查权限（可选）
  if tool.permissions and type(tool.permissions) ~= "table" then
    return false, "工具权限必须是表"
  
  return true, nil

--- 获取所有分类
--- @return table 分类列表
function M.get_categories()
  if not state.initialized then
    error("Tool registry not initialized")
  
  local categories = {}
  for category, _ in pairs(tool_categories) do
    table.insert(categories, category)
  
  table.sort(categories)
  return categories

--- 获取分类中的工具数量
--- @param category string 分类
--- @return number 工具数量
function M.get_category_tool_count(category)
  if not state.initialized then
    error("Tool registry not initialized")
  
  local category_tools = tool_categories[category]
  return category_tools and #category_tools or 0

--- 搜索工具
--- @param query string 搜索查询
--- @param search_fields table 搜索字段（可选）
--- @return table 匹配的工具列表
function M.search(query, search_fields)
  if not state.initialized then
    error("Tool registry not initialized")
  
  if not query or query == "" then
    return M.list()
  
  query = query:lower()
  search_fields = search_fields or { "name", "description", "category" }

  local results = {}
  for _, tool in pairs(tools) do
    local matched = false

    for _, field in ipairs(search_fields) do
      local value = tool[field]
      if value and type(value) == "string" and value:lower():find(query, 1, true) then
        matched = true
        break
      
    
    if matched then
      table.insert(results, vim.deepcopy(tool))
    
  
  -- 按名称排序
  table.sort(results, function(a, b)
    return a.name < b.name
  end)

  return results

--- 清空注册表
function M.clear()
  if not state.initialized then
    error("Tool registry not initialized")
  
  tools = {}
  tool_categories = {}

--- 重置注册表（用于测试）
--- 这会重置所有状态，允许重新初始化
function M.reset()
  state.initialized = false
  state.config = nil
  tools = {}
  tool_categories = {}

--- 检查工具是否存在
--- @param tool_name string 工具名称
--- @return boolean 是否存在
function M.exists(tool_name)
  if not state.initialized then
    error("Tool registry not initialized")
  
  return tools[tool_name] ~= nil

--- 获取工具数量
--- @return number 工具数量
function M.count()
  if not state.initialized then
    error("Tool registry not initialized")
  
  local count = 0
  for _ in pairs(tools) do
    count = count + 1
  
  return count

--- 导出工具定义
--- @param tool_name string 工具名称
--- @return table|nil 工具定义（可序列化）
function M.export_tool(tool_name)
  if not state.initialized then
    error("Tool registry not initialized")
  
  local tool = tools[tool_name]
  if not tool then
    return nil
  
  -- 创建可序列化的副本（排除函数）
  local exported = {
    name = tool.name,
    description = tool.description,
    parameters = tool.parameters,
    category = tool.category,
    permissions = tool.permissions,
  }

  return exported

--- 导入工具定义
--- @param tool_def table 工具定义
--- @param func function 工具函数
--- @return boolean 是否导入成功
function M.import_tool(tool_def, func)
  if not state.initialized then
    error("Tool registry not initialized")
  
  if not tool_def or not tool_def.name then
    return false
  
  -- 创建完整的工具定义
  local tool = vim.deepcopy(tool_def)
  tool.func = func

  return M.register(tool)

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  
  state.config = vim.tbl_extend("force", state.config, new_config or {})

return M

