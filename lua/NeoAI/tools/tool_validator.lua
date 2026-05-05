-- 工具验证模块
-- 提供工具定义验证、参数验证、权限检查、审批检查等功能

local logger = require("NeoAI.utils.logger")
local M = {}

local state = { initialized = false, config = nil }

local VALID_TYPES = {
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

function M.initialize(config)
  if state.initialized then
    return false, "验证器已初始化"
  end
  state.config = config or {}
  state.initialized = true
  return true, "初始化成功"
end

-- ========== 审批检查 ==========

--- 检查工具调用是否需要用户审批
--- 返回审批结果，包含是否需要用户确认、以及审批原因
---
--- 审批流程：
---   1. 获取工具的审批配置（来自 tool_registry.get_approval_config）
---   2. 检查工具是否属于获取信息类（auto_approve）
---   3. 检查参数是否在允许的参数组内
---   4. 检查文件路径是否在允许的目录内
---   5. 根据默认行为决定是否需要用户确认
---
--- @param tool_name string 工具名称
--- @param args table 工具参数
--- @param tool_registry table 工具注册表实例
--- @return table { approved: boolean, reason: string, behavior: string }
function M.check_approval(tool_name, args, tool_registry)
  if not state.initialized then
    return { approved = true, reason = "验证器未初始化，默认通过", behavior = "auto_approve" }
  end

  if not tool_name then
    return { approved = true, reason = "工具名称为空，默认通过", behavior = "auto_approve" }
  end

  -- 获取审批配置
  -- 使用 pcall 保护，防止 tool_registry 未初始化时抛出错误
  -- 注意：必须使用匿名函数包装，不能直接 pcall(fn, self, args)，
  -- 因为 get_approval_config 不是用 self 方式定义的，直接传 self 会覆盖 tool_name 参数
  local approval_config = nil
  if tool_registry and tool_registry.get_approval_config then
    local ok_config, config_result = pcall(function()
      return tool_registry.get_approval_config(tool_name)
    end)
    if ok_config then
      approval_config = config_result
    else
      logger.warn("[tool_validator] check_approval: get_approval_config 失败: %s", tostring(config_result))
    end
  end

  if not approval_config then
    -- 没有审批配置，默认通过
    return { approved = true, reason = "无审批配置，默认通过", behavior = "auto_approve" }
  end

  local behavior = approval_config.behavior or "auto_approve"
  local allowed_dirs = approval_config.allowed_directories or {}
  local allowed_param_groups = approval_config.allowed_param_groups or {}

  -- 如果行为是 auto_approve，直接通过
  if behavior == "auto_approve" then
    return { approved = true, reason = "工具配置为自动批准", behavior = "auto_approve" }
  end

  -- 获取工具定义，用于检查参数 schema
  local tool = nil
  if tool_registry and tool_registry.get then
    tool = tool_registry.get(tool_name)
  end

  -- 检查文件路径参数是否在允许的目录内
  if tool and tool.parameters and tool.parameters.properties then
    for param_name, param_schema in pairs(tool.parameters.properties) do
      -- 检查文件路径类型的参数
      if
        param_schema.type == "string"
        and (param_name:match("file") or param_name:match("dir") or param_name:match("path"))
      then
        local param_value = args and args[param_name]
        if param_value and type(param_value) == "string" then
          if not M._is_path_in_allowed_dirs(param_value, allowed_dirs, tool_registry) then
            return {
              approved = false,
              reason = string.format("参数 '%s' 的值 '%s' 不在允许的目录内", param_name, param_value),
              behavior = "require_user",
            }
          end
        end
      end

      -- 检查 files 数组参数中的 filepath 字段
      if param_schema.type == "array" and param_schema.items and param_schema.items.properties then
        local param_value = args and args[param_name]
        if param_value and type(param_value) == "table" then
          for _, item in ipairs(param_value) do
            if type(item) == "table" then
              local filepath = item.filepath or item.dir or item.path
              if filepath and type(filepath) == "string" then
                if not M._is_path_in_allowed_dirs(filepath, allowed_dirs, tool_registry) then
                  return {
                    approved = false,
                    reason = string.format(
                      "参数 '%s' 中的路径 '%s' 不在允许的目录内",
                      param_name,
                      filepath
                    ),
                    behavior = "require_user",
                  }
                end
              end
            end
          end
        end
      end
    end
  end

  -- 检查参数是否在允许的参数组内
  if args and next(allowed_param_groups) then
    for param_name, param_value in pairs(args) do
      if allowed_param_groups[param_name] then
        local allowed_values = allowed_param_groups[param_name]
        if type(allowed_values) == "table" and not vim.tbl_contains(allowed_values, param_value) then
          return {
            approved = false,
            reason = string.format(
              "参数 '%s' 的值 '%s' 不在允许的值列表中",
              param_name,
              tostring(param_value)
            ),
            behavior = "require_user",
          }
        end
      end
    end
  end

  -- 所有检查通过，但行为是 require_user，需要用户确认
  -- 注意：approved=true 表示参数检查通过，behavior=require_user 表示需要用户交互确认
  return {
    approved = true,
    reason = string.format("工具 '%s' 配置为需要用户审批", tool_name),
    behavior = "require_user",
  }
end

--- 检查路径是否在允许的目录内
--- @param path string 要检查的路径
--- @param allowed_dirs table 允许的目录列表（支持 glob 模式）
--- @param tool_registry table 工具注册表实例
--- @return boolean
function M._is_path_in_allowed_dirs(path, allowed_dirs, tool_registry)
  if not path or #allowed_dirs == 0 then
    -- 没有配置允许目录，默认允许（由 behavior 控制）
    return true
  end

  -- 获取工作目录
  local work_dir = nil
  if tool_registry and tool_registry.get_work_dir then
    work_dir = tool_registry.get_work_dir()
  end
  work_dir = work_dir or vim.fn.getcwd()

  -- 规范化路径
  local normalized_path = vim.fn.fnamemodify(path, ":p")

  for _, allowed_dir in ipairs(allowed_dirs) do
    -- 支持相对路径（相对于工作目录）和绝对路径
    local full_allowed = allowed_dir
    if not vim.startswith(allowed_dir, "/") then
      full_allowed = work_dir .. "/" .. allowed_dir
    end
    full_allowed = vim.fn.fnamemodify(full_allowed, ":p")

    -- 检查路径是否在允许目录下
    if vim.startswith(normalized_path, full_allowed) then
      return true
    end
  end

  return false
end

-- ========== 协程内审批配置管理 ==========

--- 设置协程内工具的审批配置
--- 每个工具的审批配置存储在协程共享变量的 approval_configs 表中
--- 通过 state.get_shared() 读写，协程内所有模块共享
--- @param tool_name string 工具名称
--- @param config table 审批配置 { behavior, allowed_directories, allowed_param_groups }
function M.set_tool_approval_config(tool_name, config)
  local state = require("NeoAI.core.config.state")
  local shared = state.get_shared()
  if not shared.approval_configs then
    shared.approval_configs = {}
  end
  shared.approval_configs[tool_name] = config
end

--- 获取协程内工具的审批配置
--- @param tool_name string 工具名称
--- @return table|nil 审批配置
function M.get_tool_approval_config(tool_name)
  local state = require("NeoAI.core.config.state")
  local shared = state.get_shared()
  if not shared or not shared.approval_configs then
    return nil
  end
  return shared.approval_configs[tool_name]
end

--- 获取所有协程内工具的审批配置
--- @return table
function M.get_all_tool_approval_configs()
  local state = require("NeoAI.core.config.state")
  local shared = state.get_shared()
  if not shared or not shared.approval_configs then
    return {}
  end
  return shared.approval_configs
end

--- 清除协程内所有工具的审批配置
function M.clear_tool_approval_configs()
  local state = require("NeoAI.core.config.state")
  local shared = state.get_shared()
  if shared then
    shared.approval_configs = nil
  end
end

-- ========== 模式验证 ==========

function M.validate_schema(schema)
  if not schema then
    return true
  end
  if type(schema) ~= "table" then
    return false, "模式必须是表"
  end
  if schema.type and not vim.tbl_contains(VALID_TYPES, schema.type) then
    return false, "无效的类型: " .. tostring(schema.type)
  end
  if schema.properties then
    if type(schema.properties) ~= "table" then
      return false, "属性必须是表"
    end
    for prop_name, prop_schema in pairs(schema.properties) do
      local valid, err = M.validate_schema(prop_schema)
      if not valid then
        return false, "属性 '" .. prop_name .. "' 无效: " .. err
      end
    end
  end
  if schema.required then
    if type(schema.required) ~= "table" then
      return false, "必需字段必须是列表"
    end
    for _, req in ipairs(schema.required) do
      if type(req) ~= "string" then
        return false, "必需字段名称必须是字符串"
      end
    end
  end
  if schema.items then
    local valid, err = M.validate_schema(schema.items)
    if not valid then
      return false, "数组项目无效: " .. err
    end
  end
  return true
end

-- ========== 参数验证 ==========

function M.validate_parameters(schema, params)
  if not schema then
    return true
  end
  if not params then
    params = {}
  end
  if type(params) ~= "table" then
    return false, "参数必须是表"
  end

  if schema.required then
    for _, req in ipairs(schema.required) do
      if params[req] == nil then
        return false, "缺少必需字段: " .. req
      end
    end
  end

  if schema.properties then
    for param_name, param_value in pairs(params) do
      local prop_schema = schema.properties[param_name]
      if prop_schema then
        local valid, err = M._validate_value(param_value, prop_schema)
        if not valid then
          return false, "参数 '" .. param_name .. "' 无效: " .. err
        end
      elseif schema.additionalProperties == false then
        return false, "不允许额外属性: " .. param_name
      end
    end
  end
  return true
end

function M._validate_value(value, schema)
  if not schema then
    return true
  end

  if schema.type then
    local type_valid, type_err = M.validate_return_type(schema.type, value)
    if not type_valid then
      return false, type_err
    end
  end

  if schema.enum then
    local found = false
    for _, ev in ipairs(schema.enum) do
      if value == ev then
        found = true
        break
      end
    end
    if not found then
      return false, "值不在枚举中: " .. tostring(value)
    end
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
        if not valid then
          return false, "属性 '" .. prop_name .. "' 无效: " .. err
        end
      elseif schema.required then
        for _, req in ipairs(schema.required) do
          if req == prop_name then
            return false, "缺少必需属性: " .. prop_name
          end
        end
      end
    end
  end

  if type(value) == "table" and schema.type == "array" and schema.items then
    for i, item in ipairs(value) do
      local valid, err = M._validate_value(item, schema.items)
      if not valid then
        return false, "数组项目 " .. i .. " 无效: " .. err
      end
    end
  end

  return true
end

-- ========== 类型验证 ==========

function M.validate_return_type(expected_type, value)
  if not expected_type then
    return true
  end
  local actual_type = type(value)

  if expected_type == "array" then
    if actual_type ~= "table" then
      return false, "期望数组，得到 " .. actual_type
    end
    for k, _ in pairs(value) do
      if type(k) ~= "number" then
        return false, "数组包含非数字键: " .. tostring(k)
      end
    end
    return true
  end
  if expected_type == "null" then
    if value ~= nil then
      return false, "期望null，得到 " .. actual_type
    end
    return true
  end
  if expected_type == "object" then
    if actual_type ~= "table" then
      return false, "期望对象，得到 " .. actual_type
    end
    return true
  end
  if actual_type ~= expected_type then
    return false, "期望 " .. expected_type .. "，得到 " .. actual_type
  end
  return true
end

-- ========== 权限检查 ==========

function M.check_permissions(tool)
  if not tool or not tool.permissions then
    return true
  end
  local perms = tool.permissions
  for _, key in ipairs({ "read", "write", "execute", "network", "filesystem" }) do
    if perms[key] == "restricted" then
      local names =
        { read = "读取", write = "写入", execute = "执行", network = "网络", filesystem = "文件系统" }
      return false, "没有" .. (names[key] or key) .. "权限"
    end
  end
  return true
end

-- ========== 工具定义验证 ==========

function M.validate_tool(tool)
  if not tool then
    return false, "工具定义不能为空"
  end
  if not tool.name or type(tool.name) ~= "string" then
    return false, "工具名称必须是字符串"
  end
  if not tool.func or type(tool.func) ~= "function" then
    return false, "工具函数必须是函数"
  end
  if tool.parameters then
    local valid, err = M.validate_schema(tool.parameters)
    if not valid then
      return false, "参数模式无效: " .. err
    end
  end
  if tool.returns then
    local valid, err = M.validate_schema(tool.returns)
    if not valid then
      return false, "返回类型模式无效: " .. err
    end
  end
  if tool.permissions and type(tool.permissions) ~= "table" then
    return false, "权限必须是表"
  end
  if tool.approval and type(tool.approval) ~= "table" then
    return false, "审批配置必须是表"
  end
  if tool.approval then
    if tool.approval.behavior and not vim.tbl_contains({ "auto_approve", "require_user" }, tool.approval.behavior) then
      return false, "审批行为必须是 'auto_approve' 或 'require_user'"
    end
    if tool.approval.allowed_directories and type(tool.approval.allowed_directories) ~= "table" then
      return false, "允许目录必须是列表"
    end
    if tool.approval.allowed_param_groups and type(tool.approval.allowed_param_groups) ~= "table" then
      return false, "允许参数组必须是表"
    end
  end
  return true
end

function M.validate_tool_call(tool_call, tool_registry)
  if not tool_call or not tool_call.name then
    return { valid = false, error = "工具调用缺少名称" }
  end

  local tool = type(tool_registry) == "table"
      and (tool_registry[tool_call.name] or (tool_registry.get_tool and tool_registry.get_tool(tool_call.name)))
    or nil
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
            if value == ev then
              found = true
              break
            end
          end
          if not found then
            return {
              valid = false,
              error = "参数值无效: " .. param_name .. " 应为 " .. table.concat(param_schema.enum, ", "),
            }
          end
        end
      end
    end
  end

  return { valid = true }
end

-- ========== 配置管理 ==========

function M.update_config(new_config)
  if not state.initialized then
    return false, "验证器未初始化"
  end
  if type(new_config) ~= "table" then
    return false, "配置必须是表"
  end
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
