-- 工具验证模块
-- 提供工具定义验证、参数验证、权限检查等功能

local logger = require("NeoAI.utils.logger")
local M = {}

local state = { initialized = false, config = nil }

local VALID_TYPES = {
  "string", "number", "integer", "boolean", "array", "object", "null", "function", "table",
}

function M.initialize(config)
  if state.initialized then return false, "验证器已初始化" end
  state.config = config or {}
  state.initialized = true
  return true, "初始化成功"
end

-- ========== 模式验证 ==========

function M.validate_schema(schema)
  if not schema then return true end
  if type(schema) ~= "table" then return false, "模式必须是表" end
  if schema.type and not vim.tbl_contains(VALID_TYPES, schema.type) then
    return false, "无效的类型: " .. tostring(schema.type)
  end
  if schema.properties then
    if type(schema.properties) ~= "table" then return false, "属性必须是表" end
    for prop_name, prop_schema in pairs(schema.properties) do
      local valid, err = M.validate_schema(prop_schema)
      if not valid then return false, "属性 '" .. prop_name .. "' 无效: " .. err end
    end
  end
  if schema.required then
    if type(schema.required) ~= "table" then return false, "必需字段必须是列表" end
    for _, req in ipairs(schema.required) do
      if type(req) ~= "string" then return false, "必需字段名称必须是字符串" end
    end
  end
  if schema.items then
    local valid, err = M.validate_schema(schema.items)
    if not valid then return false, "数组项目无效: " .. err end
  end
  return true
end

-- ========== 参数验证 ==========

function M.validate_parameters(schema, params)
  if not schema then return true end
  if not params then params = {} end
  if type(params) ~= "table" then return false, "参数必须是表" end

  if schema.required then
    for _, req in ipairs(schema.required) do
      if params[req] == nil then return false, "缺少必需字段: " .. req end
    end
  end

  if schema.properties then
    for param_name, param_value in pairs(params) do
      local prop_schema = schema.properties[param_name]
      if prop_schema then
        local valid, err = M._validate_value(param_value, prop_schema)
        if not valid then return false, "参数 '" .. param_name .. "' 无效: " .. err end
      elseif schema.additionalProperties == false then
        return false, "不允许额外属性: " .. param_name
      end
    end
  end
  return true
end

function M._validate_value(value, schema)
  if not schema then return true end

  if schema.type then
    local type_valid, type_err = M.validate_return_type(schema.type, value)
    if not type_valid then return false, type_err end
  end

  if schema.enum then
    local found = false
    for _, ev in ipairs(schema.enum) do
      if value == ev then found = true; break end
    end
    if not found then return false, "值不在枚举中: " .. tostring(value) end
  end

  if type(value) == "number" then
    if schema.minimum and value < schema.minimum then
      return false, "值小于最小值: " .. tostring(value) .. " < " .. tostring(schema.minimum)
    end
    if schema.maximum and value > schema.maximum then
      return false, "值大于最大值: " .. tostring(value) .. " > " .. tostring(schema.maximum)
    end
  end

  if type(value) == "string" or (type(value) == "table" and schema.type == "array") then
    local len = type(value) == "string" and #value or #value
    if schema.minLength and len < schema.minLength then
      return false, "长度小于最小长度: " .. tostring(len) .. " < " .. tostring(schema.minLength)
    end
    if schema.maxLength and len > schema.maxLength then
      return false, "长度大于最大长度: " .. tostring(len) .. " > " .. tostring(schema.maxLength)
    end
  end

  if type(value) == "table" and schema.type == "object" and schema.properties then
    for prop_name, prop_schema in pairs(schema.properties) do
      local pv = value[prop_name]
      if pv ~= nil then
        local valid, err = M._validate_value(pv, prop_schema)
        if not valid then return false, "属性 '" .. prop_name .. "' 无效: " .. err end
      elseif schema.required then
        for _, req in ipairs(schema.required) do
          if req == prop_name then return false, "缺少必需属性: " .. prop_name end
        end
      end
    end
  end

  if type(value) == "table" and schema.type == "array" and schema.items then
    for i, item in ipairs(value) do
      local valid, err = M._validate_value(item, schema.items)
      if not valid then return false, "数组项目 " .. i .. " 无效: " .. err end
    end
  end

  return true
end

-- ========== 类型验证 ==========

function M.validate_return_type(expected_type, value)
  if not expected_type then return true end
  local actual_type = type(value)

  if expected_type == "array" then
    if actual_type ~= "table" then return false, "期望数组，得到 " .. actual_type end
    for k, _ in pairs(value) do
      if type(k) ~= "number" then return false, "数组包含非数字键: " .. tostring(k) end
    end
    return true
  end
  if expected_type == "null" then
    if value ~= nil then return false, "期望null，得到 " .. actual_type end
    return true
  end
  if expected_type == "object" then
    if actual_type ~= "table" then return false, "期望对象，得到 " .. actual_type end
    return true
  end
  if actual_type ~= expected_type then
    return false, "期望 " .. expected_type .. "，得到 " .. actual_type
  end
  return true
end

-- ========== 权限检查 ==========

function M.check_permissions(tool)
  if not tool or not tool.permissions then return true end
  local perms = tool.permissions
  for _, key in ipairs({ "read", "write", "execute", "network", "filesystem" }) do
    if perms[key] == "restricted" then
      local names = { read = "读取", write = "写入", execute = "执行", network = "网络", filesystem = "文件系统" }
      return false, "没有" .. (names[key] or key) .. "权限"
    end
  end
  return true
end

-- ========== 工具定义验证 ==========

function M.validate_tool(tool)
  if not tool then return false, "工具定义不能为空" end
  if not tool.name or type(tool.name) ~= "string" then
    return false, "工具名称必须是字符串"
  end
  if not tool.func or type(tool.func) ~= "function" then
    return false, "工具函数必须是函数"
  end
  if tool.parameters then
    local valid, err = M.validate_schema(tool.parameters)
    if not valid then return false, "参数模式无效: " .. err end
  end
  if tool.returns then
    local valid, err = M.validate_schema(tool.returns)
    if not valid then return false, "返回类型模式无效: " .. err end
  end
  if tool.permissions and type(tool.permissions) ~= "table" then
    return false, "权限必须是表"
  end
  return true
end

function M.validate_tool_call(tool_call, tool_registry)
  if not tool_call or not tool_call.name then
    return { valid = false, error = "工具调用缺少名称" }
  end

  local tool = type(tool_registry) == "table" and (tool_registry[tool_call.name] or (tool_registry.get_tool and tool_registry.get_tool(tool_call.name))) or nil
  if not tool then
    return { valid = false, error = "工具不存在: " .. tool_call.name }
  end

  local arguments = tool_call.arguments or {}
  if tool.parameters and tool.parameters.required then
    for _, req in ipairs(tool.parameters.required) do
      if arguments[req] == nil then
        return { valid = false, error = "缺少必需参数: " .. req }
      end
    end
  end

  if tool.parameters and tool.parameters.properties then
    for param_name, param_schema in pairs(tool.parameters.properties) do
      local value = arguments[param_name]
      if value ~= nil then
        local param_type = param_schema.type
        if param_type == "string" and type(value) ~= "string" then
          return { valid = false, error = "参数类型错误: " .. param_name .. " 应为字符串" }
        elseif param_type == "number" and type(value) ~= "number" then
          return { valid = false, error = "参数类型错误: " .. param_name .. " 应为数字" }
        elseif param_type == "boolean" and type(value) ~= "boolean" then
          return { valid = false, error = "参数类型错误: " .. param_name .. " 应为布尔值" }
        end
        if param_schema.enum then
          local found = false
          for _, ev in ipairs(param_schema.enum) do
            if value == ev then found = true; break end
          end
          if not found then
            return { valid = false, error = "参数值无效: " .. param_name .. " 应为 " .. table.concat(param_schema.enum, ", ") }
          end
        end
      end
    end
  end

  return { valid = true }
end

-- ========== 配置管理 ==========

function M.update_config(new_config)
  if not state.initialized then return false, "验证器未初始化" end
  if type(new_config) ~= "table" then return false, "配置必须是表" end
  for k, v in pairs(new_config) do
    state.config[k] = v
  end
  return true, "配置更新成功"
end

function M.get_config()
  return state.config
end

function M.is_initialized()
  return state.initialized
end

function M.reset()
  state.initialized = false
  state.config = nil
  return true, "验证器已重置"
end

return M
