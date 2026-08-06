--- 参数校验
--- @module NeoAI.tools.validator
--- 校验工具定义结构、参数 schema、审批决策。

local M = {}

-- ========== 参数校验 ==========

--- 校验参数是否符合 schema
--- @param parameters table { type="object", properties, required }
--- @param args table
--- @return boolean, string|nil 是否有效, 错误信息
function M.validate_parameters(parameters, args)
  if not parameters then return true end
  args = args or {}
  if type(args) ~= "table" then return false, "参数必须是对象" end
  local required = parameters.required or {}
  for _, key in ipairs(required) do
    if args[key] == nil then
      return false, "缺少必填参数: " .. key
    end
  end
  -- 类型检查
  local props = parameters.properties or {}
  for key, spec in pairs(props) do
    if args[key] ~= nil then
      local expected = spec.type
      if expected == "number" and type(args[key]) ~= "number" then
        return false, string.format("参数 %s 应为 number，得到 %s", key, type(args[key]))
      end
      if expected == "integer" and (type(args[key]) ~= "number" or args[key] % 1 ~= 0) then
        return false, string.format("参数 %s 应为 integer", key)
      end
      if expected == "string" and type(args[key]) ~= "string" then
        return false, string.format("参数 %s 应为 string，得到 %s", key, type(args[key]))
      end
      if expected == "boolean" and type(args[key]) ~= "boolean" then
        return false, string.format("参数 %s 应为 boolean", key)
      end
      if expected == "array" and type(args[key]) ~= "table" then
        return false, string.format("参数 %s 应为 array", key)
      end
    end
  end
  return true
end

-- ========== 审批决策 ==========

--- 判断路径是否在允许目录内
--- @param filepath string
--- @param allowed_dirs table
--- @return boolean
function M.is_path_allowed(filepath, allowed_dirs)
  if not allowed_dirs or #allowed_dirs == 0 then return false end
  local fs = require("NeoAI.utils.fs")
  local abs = vim.fn.fnamemodify(filepath, ":p")
  for _, dir in ipairs(allowed_dirs) do
    if dir == "" then return true end
    local abs_dir = vim.fn.fnamemodify(dir, ":p")
    if abs:sub(1, #abs_dir) == abs_dir then return true end
  end
  return false
end

--- 判断参数是否在安全组内
--- @param args table
--- @param groups table 命令前缀数组（如 { "ls", "grep" }）
--- @return boolean
function M.is_params_safe(args, groups)
  if not groups or #groups == 0 then return false end
  local command = args.command or args.cmd or args[1]
  if type(command) ~= "string" then return false end
  local first_word = command:match("^%s*([%w%-_%./]+)")
  if not first_word then return false end
  for _, g in ipairs(groups) do
    if first_word == g or first_word:find("^" .. g .. "%s") then return true end
  end
  return false
end

--- 审批决策
--- @param tool_name string
--- @param args table
--- @param approval_config table { auto_allow, allowed_directories, allowed_param_groups }
--- @param mode string "prompt" | "auto_allow" | "strict"
--- @return boolean 是否需要审批
function M.check_approval(tool_name, args, approval_config, mode)
  if mode == "auto_allow" then return false end
  if mode == "strict" then return true end
  if approval_config.auto_allow then return false end

  -- 路径安全检查 + 参数安全检查
  local filepath = args.filepath or args.path or args.file
  local path_safe = not filepath or M.is_path_allowed(filepath, approval_config.allowed_directories)
  local params_safe = M.is_params_safe(args, approval_config.allowed_param_groups)
  -- 无路径且无命令时按 auto_allow 决定
  if not filepath and not (args.command or args.cmd) then
    return approval_config.auto_allow == false
  end
  if path_safe and params_safe then return false end
  return true
end

--- 校验工具定义结构
--- @param tool table
--- @return boolean, string|nil
function M.validate_tool(tool)
  if type(tool) ~= "table" then return false, "工具必须是 table" end
  if type(tool.name) ~= "string" or tool.name == "" then return false, "工具缺少 name" end
  if not tool.func and not tool.execute then return false, "工具缺少 func/execute" end
  if tool.parameters and tool.parameters.type ~= "object" then
    return false, "parameters.type 应为 object"
  end
  return true
end

return M
