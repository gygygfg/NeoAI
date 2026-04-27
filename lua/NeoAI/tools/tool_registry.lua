-- 工具注册表模块
-- 提供工具的注册、管理、查询等功能
local logger = require("NeoAI.utils.logger")
local M = {}

-- 工具存储
local tools = {} -- 以工具名称为键，工具定义为值的表
local tool_categories = {} -- 以分类名称为键，工具名称列表为值的表

-- 模块状态
local state = {
  initialized = false, -- 模块是否已初始化
  config = nil, -- 模块配置
}

--- 初始化工具注册表
--- @param config table 配置表
function M.initialize(config)
  -- 如果已经初始化，则直接返回
  if state.initialized then
    return
  end

  -- 存储配置，如果config为nil则使用空表
  state.config = config or {}
  tools = {} -- 清空工具存储
  tool_categories = {} -- 清空分类存储
  state.initialized = true -- 标记为已初始化
end

--- 注册工具
--- @param tool table 工具定义，必须包含name和func字段
--- @return boolean 注册是否成功
function M.register(tool)
  -- 检查模块是否已初始化
  if not state.initialized then
    logger.debug("[tool_registry] register 失败: 未初始化")
    error("工具注册表未初始化，请先调用M.initialize()")
  end

  -- 检查工具定义是否有效
  if not tool or not tool.name then
    logger.debug("[tool_registry] ❌ 工具定义无效: 缺少名称")
    return false
  end

  -- 检查工具是否已存在
  if tools[tool.name] then
    logger.debug("[tool_registry] ⚠️ 工具已存在: " .. tool.name)
    return false
  end

  -- 验证工具定义
  local valid, error_msg = M.validate_tool(tool)
  if not valid then
    logger.debug("[tool_registry] ❌ 工具验证失败[" .. tool.name .. "]: " .. error_msg)
    return false
  end

  -- 存储工具（深拷贝避免外部修改影响内部数据）
  tools[tool.name] = vim.deepcopy(tool)

  -- 将工具添加到对应分类
  local category = tool.category or "uncategorized" -- 默认分类为"未分类"
  if not tool_categories[category] then
    tool_categories[category] = {} -- 如果分类不存在，则创建
  end

  table.insert(tool_categories[category], tool.name)

  -- logger.debug("[tool_registry] ✅ 工具注册成功: " .. tool.name .. " (分类: " .. category .. ")")
  return true
end

--- 注销工具
--- @param tool_name string 要注销的工具名称
--- @return boolean 是否注销成功
function M.unregister(tool_name)
  if not state.initialized then
    logger.debug("[tool_registry] unregister 失败: 未初始化")
    error("工具注册表未初始化")
  end

  logger.debug("[tool_registry] unregister: " .. tool_name)

  -- 检查工具是否存在
  if not tools[tool_name] then
    logger.debug("[tool_registry] unregister: 工具不存在 - " .. tool_name)
    return false
  end

  -- 从分类中移除工具
  local tool = tools[tool_name]
  local category = tool.category or "uncategorized"
  if tool_categories[category] then
    for i, name in ipairs(tool_categories[category]) do
      if name == tool_name then
        table.remove(tool_categories[category], i) -- 找到并移除
        break
      end
    end

    -- 如果分类为空，则删除该分类
    if #tool_categories[category] == 0 then
      tool_categories[category] = nil
    end
  end

  -- 从工具存储中移除
  tools[tool_name] = nil

  logger.debug("[tool_registry] unregister 成功: " .. tool_name)
  return true
end

--- 获取工具定义
--- @param tool_name string 工具名称
--- @return table|nil 工具定义的深拷贝，如果不存在则返回nil
function M.get(tool_name)
  if not state.initialized then
    logger.debug("[tool_registry] get 失败: 未初始化")
    error("工具注册表未初始化")
  end

  local tool = tools[tool_name]
  logger.debug("[tool_registry] get: " .. tool_name .. " -> " .. (tool and "找到" or "未找到"))
  return vim.deepcopy(tool) -- 返回深拷贝防止外部修改
end

--- 获取工具（别名，用于兼容性）
--- @param tool_name string 工具名称
--- @return table|nil 工具定义
function M.get_tool(tool_name)
  return M.get(tool_name)
end

--- 获取所有工具（以名称为键的表）
--- @return table 所有工具的深拷贝表
function M.get_all_tools()
  if not state.initialized then
    error("工具注册表未初始化")
  end

  local result = {}
  for name, tool in pairs(tools) do
    result[name] = vim.deepcopy(tool) -- 深拷贝每个工具
  end

  return result
end

--- 列出所有工具
--- @param category string|nil 分类名称（可选，如果提供则返回该分类下的工具）
--- @return table 工具列表（数组）
function M.list(category)
  if not state.initialized then
    logger.debug("[tool_registry] list 失败: 未初始化")
    error("工具注册表未初始化")
  end

  if category then
    -- 返回特定分类的工具
    local category_tools = tool_categories[category] or {}
    logger.debug("[tool_registry] list 分类 '" .. category .. "': " .. #category_tools .. " 个工具")
    local result = {}
    for _, tool_name in ipairs(category_tools) do
      table.insert(result, vim.deepcopy(tools[tool_name]))
    end
    return result
  else
    -- 返回所有工具
    local result = {}
    for _, tool in pairs(tools) do
      table.insert(result, vim.deepcopy(tool))
    end

    -- 按名称排序
    table.sort(result, function(a, b)
      return a.name < b.name
    end)
    return result
  end
end

--- 验证工具定义
--- @param tool table 要验证的工具定义
--- @return boolean, string 是否有效，错误信息
function M.validate_tool(tool)
  -- 检查必需字段
  if not tool.name or type(tool.name) ~= "string" then
    return false, "工具名称必须是字符串"
  end

  if not tool.func or type(tool.func) ~= "function" then
    return false, "工具函数必须是函数"
  end

  -- 检查名称格式（只允许字母、数字、下划线，且不能以数字开头）
  if not tool.name:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
    return false,
      "工具名称只能包含字母、数字和下划线，且不能以数字开头。当前名称: '"
        .. tool.name
        .. "'"
  end

  -- 检查描述（可选但推荐）
  if tool.description and type(tool.description) ~= "string" then
    return false, "工具描述必须是字符串"
  end

  -- 检查参数模式（可选）
  if tool.parameters and type(tool.parameters) ~= "table" then
    return false, "工具参数必须是表"
  end

  -- 检查分类（可选）
  if tool.category and type(tool.category) ~= "string" then
    return false, "工具分类必须是字符串"
  end

  -- 检查权限（可选）
  if tool.permissions and type(tool.permissions) ~= "table" then
    return false, "工具权限必须是表"
  end

  return true, ""
end

--- 获取所有分类
--- @return table 分类名称列表（已排序）
function M.get_categories()
  if not state.initialized then
    error("工具注册表未初始化")
  end

  local categories = {}
  for category, _ in pairs(tool_categories) do
    table.insert(categories, category)
  end

  table.sort(categories) -- 按字母顺序排序
  return categories
end

--- 获取分类中的工具数量
--- @param category string 分类名称
--- @return number 该分类下的工具数量
function M.get_category_tool_count(category)
  if not state.initialized then
    error("工具注册表未初始化")
  end

  local category_tools = tool_categories[category]
  return category_tools and #category_tools or 0
end

--- 搜索工具
--- @param query string 搜索查询字符串
--- @param search_fields table 搜索字段列表（可选，默认搜索名称、描述、分类）
--- @return table 匹配的工具列表
function M.search(query, search_fields)
  if not state.initialized then
    logger.debug("[tool_registry] search 失败: 未初始化")
    error("工具注册表未初始化")
  end

  -- 如果查询为空，则返回所有工具
  if not query or query == "" then
    logger.debug("[tool_registry] search: 查询为空，返回所有工具")
    return M.list()
  end

  query = query:lower() -- 转换为小写进行不区分大小写的搜索
  search_fields = search_fields or { "name", "description", "category" }

  logger.debug("[tool_registry] search: '" .. query .. "' 在 " .. #search_fields .. " 个字段中搜索")

  local results = {}
  for _, tool in pairs(tools) do
    local matched = false

    -- 在所有指定的字段中搜索
    for _, field in ipairs(search_fields) do
      local value = tool[field]
      if value and type(value) == "string" and value:lower():find(query, 1, true) then
        matched = true
        break
      end
    end

    if matched then
      table.insert(results, vim.deepcopy(tool))
    end
  end

  -- 按名称排序
  table.sort(results, function(a, b)
    return a.name < b.name
  end)

  logger.debug("[tool_registry] search 结果: " .. #results .. " 个匹配")
  return results
end

--- 清空注册表（保留初始化状态）
function M.clear()
  if not state.initialized then
    logger.debug("[tool_registry] clear 失败: 未初始化")
    error("工具注册表未初始化")
  end

  local count = 0
  for _ in pairs(tools) do
    count = count + 1
  end
  logger.debug("[tool_registry] clear: 清空 " .. count .. " 个工具")
  tools = {}
  tool_categories = {}
  logger.debug("[tool_registry] clear 完成")
end

--- 重置注册表（用于测试）
-- 这会重置所有状态，允许重新初始化
function M.reset()
  state.initialized = false
  state.config = nil
  tools = {}
  tool_categories = {}
end

--- 检查工具是否存在
--- @param tool_name string 工具名称
--- @return boolean 是否存在
function M.exists(tool_name)
  if not state.initialized then
    logger.debug("[tool_registry] exists 失败: 未初始化")
    error("工具注册表未初始化")
  end

  local found = tools[tool_name] ~= nil
  logger.debug("[tool_registry] exists: " .. tool_name .. " -> " .. tostring(found))
  return found
end

--- 获取工具数量
--- @return number 工具总数
function M.count()
  if not state.initialized then
    logger.debug("[tool_registry] count 失败: 未初始化")
    error("工具注册表未初始化")
  end

  local count = 0
  for _ in pairs(tools) do
    count = count + 1
  end

  logger.debug("[tool_registry] count: " .. count)
  return count
end

--- 导出工具定义（创建可序列化的副本）
--- @param tool_name string 工具名称
--- @return table|nil 工具定义（不包含函数，可序列化）
function M.export_tool(tool_name)
  if not state.initialized then
    error("工具注册表未初始化")
  end

  local tool = tools[tool_name]
  if not tool then
    return nil
  end

  -- 创建可序列化的副本（排除函数，因为函数不可序列化）
  local exported = {
    name = tool.name,
    description = tool.description,
    parameters = tool.parameters,
    category = tool.category,
    permissions = tool.permissions,
  }

  return exported
end

--- 导入工具定义
--- @param tool_def table 工具定义（不包含函数）
--- @param func function 工具函数
--- @return boolean 是否导入成功
function M.import_tool(tool_def, func)
  if not state.initialized then
    error("工具注册表未初始化")
  end

  if not tool_def or not tool_def.name then
    return false
  end

  -- 创建完整的工具定义
  local tool = vim.deepcopy(tool_def)
  tool.func = func

  return M.register(tool)
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  -- 合并配置
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
