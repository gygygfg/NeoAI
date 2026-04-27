-- 工具验证模块
-- 提供工具定义验证、参数验证、权限检查等功能
local logger = require("NeoAI.utils.logger")
local M = {}

-- 模块状态
local state = {
  initialized = false, -- 是否已初始化
  config = nil, -- 配置信息
}

--- 初始化工具验证器
--- @param config table 配置表
--- @return boolean, string 是否成功，错误信息
function M.initialize(config)
  if state.initialized then
    return false, "验证器已初始化"
  end

  state.config = config or {}
  state.initialized = true

  return true, "初始化成功"
end

--- 检查类型是否有效（内部使用）
--- @param type_name string 类型名称
--- @return boolean 是否有效
function M._is_valid_type(type_name)
  local valid_types = {
    "string",
    "number",
    "integer",
    "boolean",
    "array",
    "object",
    "null",
    "function",
    "table",
  }

  for _, valid_type in ipairs(valid_types) do
    if valid_type == type_name then
      return true
    end
  end

  return false
end

--- 验证模式定义
--- @param schema table 模式定义
--- @return boolean, string|nil 是否有效，错误信息（成功时为nil）
function M.validate_schema(schema)
  if not schema then
    return true, nil -- 空模式是有效的
  end

  if type(schema) ~= "table" then
    return false, "模式必须是表"
  end

  -- 检查必需字段
  if schema.type and not M._is_valid_type(schema.type) then
    return false, "无效的类型: " .. tostring(schema.type)
  end

  -- 验证属性
  if schema.properties then
    if type(schema.properties) ~= "table" then
      return false, "属性必须是表"
    end

    for prop_name, prop_schema in pairs(schema.properties) do
      local valid, error_msg = M.validate_schema(prop_schema)
      if not valid then
        return false, "属性 '" .. prop_name .. "' 无效: " .. error_msg
      end
    end
  end

  -- 验证必需字段
  if schema.required then
    if type(schema.required) ~= "table" then
      return false, "必需字段必须是列表"
    end

    for _, req_field in ipairs(schema.required) do
      if type(req_field) ~= "string" then
        return false, "必需字段名称必须是字符串"
      end
    end
  end

  -- 验证项目（对于数组类型）
  if schema.items then
    local valid, error_msg = M.validate_schema(schema.items)
    if not valid then
      return false, "数组项目无效: " .. error_msg
    end
  end

  return true, nil
end

--- 验证值（内部使用）
--- @param value any 要验证的值
--- @param schema table 模式定义
--- @return boolean, string|nil 是否有效，错误信息（成功时为nil）
function M._validate_value(value, schema)
  if not schema then
    return true, nil -- 没有模式，接受任何值
  end

  -- 检查类型
  if schema.type then
    local type_valid, type_error = M.validate_return_type(schema.type, value)
    if not type_valid then
      return false, type_error
    end
  end

  -- 检查枚举值
  if schema.enum then
    if type(schema.enum) ~= "table" then
      return false, "枚举必须是列表"
    end

    local found = false
    for _, enum_value in ipairs(schema.enum) do
      if value == enum_value then
        found = true
        break
      end
    end

    if not found then
      return false, "值不在枚举中: " .. tostring(value)
    end
  end

  -- 检查最小值/最大值（对于数字）
  if type(value) == "number" then
    if schema.minimum and value < schema.minimum then
      return false, "值小于最小值: " .. tostring(value) .. " < " .. tostring(schema.minimum)
    end

    if schema.maximum and value > schema.maximum then
      return false, "值大于最大值: " .. tostring(value) .. " > " .. tostring(schema.maximum)
    end
  end

  -- 检查最小长度/最大长度（对于字符串和数组）
  if type(value) == "string" or (type(value) == "table" and schema.type == "array") then
    local length = type(value) == "string" and #value or #value

    if schema.minLength and length < schema.minLength then
      return false, "长度小于最小长度: " .. tostring(length) .. " < " .. tostring(schema.minLength)
    end

    if schema.maxLength and length > schema.maxLength then
      return false, "长度大于最大长度: " .. tostring(length) .. " > " .. tostring(schema.maxLength)
    end
  end

  -- 递归验证对象属性
  if type(value) == "table" and schema.type == "object" and schema.properties then
    for prop_name, prop_schema in pairs(schema.properties) do
      local prop_value = value[prop_name]

      if prop_value ~= nil then
        local valid, error_msg = M._validate_value(prop_value, prop_schema)
        if not valid then
          return false, "属性 '" .. prop_name .. "' 无效: " .. error_msg
        end
      elseif schema.required then
        -- 检查是否为必需属性
        for _, req_prop in ipairs(schema.required) do
          if req_prop == prop_name then
            return false, "缺少必需属性: " .. prop_name
          end
        end
      end
    end
  end

  -- 递归验证数组项目
  if type(value) == "table" and schema.type == "array" and schema.items then
    for i, item in ipairs(value) do
      local valid, error_msg = M._validate_value(item, schema.items)
      if not valid then
        return false, "数组项目 " .. i .. " 无效: " .. error_msg
      end
    end
  end

  return true, nil
end

--- 验证参数
--- @param schema table 模式定义
--- @param params table 参数
--- @return boolean, string|nil 是否有效，错误信息（成功时为nil）
function M.validate_parameters(schema, params)
  if not schema then
    logger.debug("[tool_validator] validate_parameters: 无模式定义，接受任何参数")
    return true, nil -- 没有模式，接受任何参数
  end

  if not params then
    params = {}
  end

  if type(params) ~= "table" then
    logger.debug("[tool_validator] validate_parameters: 参数不是表")
    return false, "参数必须是表"
  end

  logger.debug("[tool_validator] validate_parameters: 开始验证")

  -- 验证必需字段
  if schema.required then
    for _, req_field in ipairs(schema.required) do
      if params[req_field] == nil then
        logger.debug("[tool_validator] validate_parameters: 缺少必需字段 - " .. req_field)
        return false, "缺少必需字段: " .. req_field
      end
    end
  end

  -- 验证属性
  if schema.properties then
    for param_name, param_value in pairs(params) do
      local prop_schema = schema.properties[param_name]

      if prop_schema then
        -- 有模式定义，验证参数
        local valid, error_msg = M._validate_value(param_value, prop_schema)
        if not valid then
          logger.debug("[tool_validator] validate_parameters: 参数 '" .. param_name .. "' 无效: " .. error_msg)
          return false, "参数 '" .. param_name .. "' 无效: " .. error_msg
        end
      else
        -- 没有模式定义，检查是否允许额外属性
        if schema.additionalProperties == false then
          logger.debug("[tool_validator] validate_parameters: 不允许额外属性 - " .. param_name)
          return false, "不允许额外属性: " .. param_name
        end
      end
    end
  end

  logger.debug("[tool_validator] validate_parameters: 验证通过")
  return true, nil
end

--- 验证返回类型
--- @param expected_type string 期望的类型
--- @param value any 实际值
--- @return boolean, string|nil 是否匹配，错误信息（成功时为nil）
function M.validate_return_type(expected_type, value)
  if not expected_type then
    return true, nil -- 没有类型限制
  end

  local actual_type = type(value)

  -- 基本类型检查
  if expected_type == "string" and actual_type ~= "string" then
    return false, "期望字符串，得到 " .. actual_type
  elseif expected_type == "number" and actual_type ~= "number" then
    return false, "期望数字，得到 " .. actual_type
  elseif expected_type == "boolean" and actual_type ~= "boolean" then
    return false, "期望布尔值，得到 " .. actual_type
  elseif expected_type == "table" and actual_type ~= "table" then
    return false, "期望表，得到 " .. actual_type
  elseif expected_type == "array" then
    if actual_type ~= "table" then
      return false, "期望数组，得到 " .. actual_type
    end

    -- 简单检查：数组应该是连续的数字索引
    for k, _ in pairs(value) do
      if type(k) ~= "number" then
        return false, "数组包含非数字键: " .. tostring(k)
      end
    end
  elseif expected_type == "object" then
    if actual_type ~= "table" then
      return false, "期望对象，得到 " .. actual_type
    end
  elseif expected_type == "function" and actual_type ~= "function" then
    return false, "期望函数，得到 " .. actual_type
  elseif expected_type == "null" and value ~= nil then
    return false, "期望null，得到 " .. actual_type
  end

  return true, nil
end

--- 检查权限
--- @param tool table 工具定义
--- @return boolean, string|nil 是否有权限，错误信息（成功时为nil）
function M.check_permissions(tool)
  if not tool or not tool.permissions then
    logger.debug("[tool_validator] check_permissions: 无权限限制，通过")
    return true, nil -- 没有权限限制
  end

  logger.debug("[tool_validator] check_permissions: 检查工具权限")
  local permissions = tool.permissions

  -- 检查读取权限
  if permissions.read then
    if permissions.read == "restricted" then
      logger.debug("[tool_validator] check_permissions: 读取权限受限")
      return false, "没有读取权限"
    end
  end

  -- 检查写入权限
  if permissions.write then
    if permissions.write == "restricted" then
      logger.debug("[tool_validator] check_permissions: 写入权限受限")
      return false, "没有写入权限"
    end
  end

  -- 检查执行权限
  if permissions.execute then
    if permissions.execute == "restricted" then
      logger.debug("[tool_validator] check_permissions: 执行权限受限")
      return false, "没有执行权限"
    end
  end

  -- 检查网络权限
  if permissions.network then
    if permissions.network == "restricted" then
      logger.debug("[tool_validator] check_permissions: 网络权限受限")
      return false, "没有网络访问权限"
    end
  end

  -- 检查文件系统权限
  if permissions.filesystem then
    if permissions.filesystem == "restricted" then
      logger.debug("[tool_validator] check_permissions: 文件系统权限受限")
      return false, "没有文件系统访问权限"
    end
  end

  logger.debug("[tool_validator] check_permissions: 权限检查通过")
  return true, nil
end

--- 验证工具定义
--- @param tool table 工具定义
--- @return boolean, string|nil 是否有效，错误信息（成功时为nil）
function M.validate_tool(tool)
  if not tool then
    logger.debug("[tool_validator] validate_tool: 工具定义为空")
    return false, "工具定义不能为空"
  end

  -- 检查必需字段
  if not tool.name or type(tool.name) ~= "string" then
    logger.debug("[tool_validator] validate_tool: 名称无效")
    return false, "工具名称必须是字符串"
  end

  if not tool.func or type(tool.func) ~= "function" then
    logger.debug("[tool_validator] validate_tool: 函数无效")
    return false, "工具函数必须是函数"
  end

  -- 验证参数模式（如果存在）
  if tool.parameters then
    local valid, error_msg = M.validate_schema(tool.parameters)
    if not valid then
      logger.debug("[tool_validator] validate_tool: 参数模式无效 - " .. error_msg)
      return false, "参数模式无效: " .. error_msg
    end
  end

  -- 验证返回类型模式（如果存在）
  if tool.returns then
    local valid, error_msg = M.validate_schema(tool.returns)
    if not valid then
      logger.debug("[tool_validator] validate_tool: 返回类型模式无效 - " .. error_msg)
      return false, "返回类型模式无效: " .. error_msg
    end
  end

  -- 验证权限（如果存在）
  if tool.permissions then
    if type(tool.permissions) ~= "table" then
      logger.debug("[tool_validator] validate_tool: 权限类型无效")
      return false, "权限必须是表"
    end
  end

  return true, nil
end

--- 验证工具调用
--- @param tool_call table 工具调用对象
--- @param tool_registry table 工具注册表
--- @return table 验证结果 {valid = boolean, error = string}
function M.validate_tool_call(tool_call, tool_registry)
  if not tool_call or not tool_call.name then
    logger.debug("[tool_validator] validate_tool_call: 缺少工具名称")
    return { valid = false, error = "工具调用缺少名称" }
  end

  logger.debug("[tool_validator] validate_tool_call: " .. tool_call.name)

  -- 检查工具是否存在
  local tool = tool_registry[tool_call.name] or tool_registry.get_tool and tool_registry.get_tool(tool_call.name)
  if not tool then
    logger.debug("[tool_validator] validate_tool_call: 工具不存在 - " .. tool_call.name)
    return { valid = false, error = "工具不存在: " .. tool_call.name }
  end

  -- 检查参数
  local arguments = tool_call.arguments or {}

  -- 验证必需参数
  if tool.parameters and tool.parameters.required then
    for _, required_param in ipairs(tool.parameters.required) do
      if arguments[required_param] == nil then
        logger.debug("[tool_validator] validate_tool_call: 缺少必需参数 - " .. required_param)
        return { valid = false, error = "缺少必需参数: " .. required_param }
      end
    end
  end

  -- 验证参数类型
  if tool.parameters and tool.parameters.properties then
    for param_name, param_schema in pairs(tool.parameters.properties) do
      local value = arguments[param_name]
      if value ~= nil then
        -- 基本类型检查
        local param_type = param_schema.type
        if param_type == "string" and type(value) ~= "string" then
          logger.debug("[tool_validator] validate_tool_call: 参数类型错误 - " .. param_name)
          return { valid = false, error = "参数类型错误: " .. param_name .. " 应为字符串" }
        elseif param_type == "number" and type(value) ~= "number" then
          logger.debug("[tool_validator] validate_tool_call: 参数类型错误 - " .. param_name)
          return { valid = false, error = "参数类型错误: " .. param_name .. " 应为数字" }
        elseif param_type == "boolean" and type(value) ~= "boolean" then
          logger.debug("[tool_validator] validate_tool_call: 参数类型错误 - " .. param_name)
          return { valid = false, error = "参数类型错误: " .. param_name .. " 应为布尔值" }
        end

        -- 枚举值检查
        if param_schema.enum then
          local valid = false
          for _, enum_value in ipairs(param_schema.enum) do
            if value == enum_value then
              valid = true
              break
            end
          end

          if not valid then
            logger.debug("[tool_validator] validate_tool_call: 枚举值无效 - " .. param_name)
            return {
              valid = false,
              error = "参数值无效: " .. param_name .. " 应为 " .. table.concat(param_schema.enum, ", "),
            }
          end
        end
      end
    end
  end

  logger.debug("[tool_validator] validate_tool_call: 验证通过")
  return { valid = true }
end

--- 更新配置
--- @param new_config table 新配置
--- @return boolean, string|nil 是否成功，错误信息（成功时为nil）
function M.update_config(new_config)
  if not state.initialized then
    logger.debug("[tool_validator] update_config 失败: 未初始化")
    return false, "验证器未初始化"
  end

  if type(new_config) ~= "table" then
    logger.debug("[tool_validator] update_config 失败: 配置不是表")
    return false, "配置必须是表"
  end

  logger.debug("[tool_validator] update_config")
  -- 合并配置
  for k, v in pairs(new_config) do
    state.config[k] = v
  end

  logger.debug("[tool_validator] update_config 完成")
  return true, "配置更新成功"
end

--- 获取当前配置
--- @return table 当前配置
function M.get_config()
  return state.config
end

--- 检查验证器是否已初始化
--- @return boolean 是否已初始化
function M.is_initialized()
  return state.initialized
end

--- 重置验证器状态
--- @return boolean, string 是否成功，错误信息
function M.reset()
  state.initialized = false
  state.config = nil
  return true, "验证器已重置"
end

-- 测试用例
local function test()
  print("=== 开始测试工具验证模块 ===")

  -- 测试1: 初始化
  local ok, err = M.initialize({ debug = true })
  print("测试1 - 初始化:", ok, err or "成功")

  -- 测试2: 验证模式
  local schema = {
    type = "object",
    properties = {
      name = { type = "string", minLength = 2 },
      age = { type = "number", minimum = 0, maximum = 150 },
    },
    required = { "name" },
  }

  local valid, msg = M.validate_schema(schema)
  print("测试2 - 验证模式:", valid, msg or "成功")

  -- 测试3: 验证参数
  local params = { name = "张三", age = 25 }
  valid, msg = M.validate_parameters(schema, params)
  print("测试3 - 验证有效参数:", valid, msg or "成功")

  params = { name = "张", age = 200 } -- 年龄超出范围
  valid, msg = M.validate_parameters(schema, params)
  print("测试4 - 验证无效参数:", valid, msg or "成功")

  -- 测试5: 验证工具定义
  local tool = {
    name = "测试工具",
    func = function()
      return "测试结果"
    end,
    parameters = schema,
  }

  valid, msg = M.validate_tool(tool)
  print("测试5 - 验证工具定义:", valid, msg or "成功")

  -- 测试6: 验证工具调用
  local tool_registry = { ["测试工具"] = tool }
  local tool_call = {
    name = "测试工具",
    arguments = { name = "李四", age = 30 },
  }

  local result = M.validate_tool_call(tool_call, tool_registry)
  print("测试6 - 验证工具调用:", result.valid, result.error or "成功")

  print("=== 测试完成 ===")
end

-- 如果直接运行此文件，则执行测试
if arg and arg[0] and arg[0]:match("tool_validator%.lua$") then
  test()
end

return M
