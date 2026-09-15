--- 参数校验
--- @module NeoAI.tools.validator
--- 校验工具定义结构、参数 schema、审批决策。

local M = {}

-- ========== 参数校验 ==========

--- 归一化 required 字段：规范要求为字符串数组；容忍字符串写法但不崩溃。
--- @param required any
--- @return table
local function _required_list(required)
  if type(required) == "string" then return { required } end
  if type(required) ~= "table" then return {} end
  local out = {}
  for _, v in ipairs(required) do
    if type(v) == "string" then out[#out + 1] = v end
  end
  return out
end

--- 校验基础类型（含 enum 约束）
--- @param spec table schema
--- @param value any
--- @param key string 参数名（用于错误信息）
--- @return boolean, string|nil
local function _check_scalar(spec, value, key)
  local expected = spec.type
  if expected == "number" and type(value) ~= "number" then
    return false, string.format("参数 %s 应为 number，得到 %s", key, type(value))
  end
  if expected == "integer" and (type(value) ~= "number" or value % 1 ~= 0) then
    return false, string.format("参数 %s 应为 integer", key)
  end
  if expected == "string" and type(value) ~= "string" then
    return false, string.format("参数 %s 应为 string，得到 %s", key, type(value))
  end
  if expected == "boolean" and type(value) ~= "boolean" then
    return false, string.format("参数 %s 应为 boolean", key)
  end
  if type(spec.enum) == "table" and #spec.enum > 0 then
    local found = false
    for _, allowed in ipairs(spec.enum) do
      if value == allowed then found = true break end
    end
    if not found then
      local names = {}
      for _, allowed in ipairs(spec.enum) do names[#names + 1] = tostring(allowed) end
      return false, string.format("参数 %s 取值非法（允许: %s）", key, table.concat(names, ", "))
    end
  end
  return true
end

--- 递归校验参数是否符合 schema（支持嵌套 object 与 array.items）
--- @param parameters table { type="object", properties, required }
--- @param args table
--- @param prefix string|nil 嵌套路径前缀（用于错误信息）
--- @return boolean, string|nil 是否有效, 错误信息
function M.validate_parameters(parameters, args, prefix)
  if not parameters then return true end
  if parameters.type and parameters.type ~= "object" then
    return _check_scalar(parameters, args, prefix or "参数")
  end
  args = args or {}
  if type(args) ~= "table" then return false, "参数必须是对象" end
  local required = _required_list(parameters.required)
  for _, key in ipairs(required) do
    if args[key] == nil then
      return false, "缺少必填参数: " .. key
    end
  end
  local props = parameters.properties or {}
  for key, spec in pairs(props) do
    local value = args[key]
    if value ~= nil then
      local path = prefix and (prefix .. "." .. key) or key
      local ok, err = _check_scalar(spec, value, path)
      if not ok then return false, err end
      if spec.type == "array" then
        if type(value) ~= "table" then
          return false, string.format("参数 %s 应为 array", path)
        end
        if spec.items then
          for i, item in ipairs(value) do
            local item_path = string.format("%s[%d]", path, i)
            if spec.items.type == "object" then
              if type(item) ~= "table" then
                return false, string.format("参数 %s 应为 object", item_path)
              end
              local item_ok, item_err = M.validate_parameters(spec.items, item, item_path)
              if not item_ok then return false, item_err end
            else
              local item_ok, item_err = _check_scalar(spec.items, item, item_path)
              if not item_ok then return false, item_err end
            end
          end
        end
      elseif spec.type == "object" then
        if type(value) ~= "table" then
          return false, string.format("参数 %s 应为 object，得到 %s", path, type(value))
        end
        local sub_ok, sub_err = M.validate_parameters(spec, value, path)
        if not sub_ok then return false, sub_err end
      end
    end
  end
  return true
end

-- ========== 审批决策 ==========

--- 规范化绝对路径（消除末尾斜杠，供前缀边界比较）
--- @param path string
--- @return string
local function _normalize_abs(path)
  local abs = vim.fn.simplify(vim.fn.fnamemodify(path, ":p"))
  if abs ~= "/" then abs = abs:gsub("/+$", "") end
  return abs
end

--- 判断路径是否在允许目录内（按路径段边界比较，避免 /tmp/abc 放行 /tmp/abc-evil）
--- @param filepath string
--- @param allowed_dirs table
--- @return boolean
function M.is_path_allowed(filepath, allowed_dirs)
  if not allowed_dirs or #allowed_dirs == 0 then return false end
  local abs = _normalize_abs(filepath)
  for _, dir in ipairs(allowed_dirs) do
    if dir == "" then return true end
    local abs_dir = _normalize_abs(dir)
    if abs_dir == "/" then
      if abs:sub(1, 1) == "/" then return true end
    elseif abs == abs_dir or abs:sub(1, #abs_dir + 1) == abs_dir .. "/" then
      return true
    end
  end
  return false
end

-- 命令中的 shell 控制/重定向/替换字符：白名单只放行简单命令，出现即视为不安全。
local DANGEROUS_SHELL = "[;&|`$<>(){}%[%]\\\n\r]"

--- 判断参数是否在安全组内（拒绝含 shell 元字符的注入型命令）
--- @param args table
--- @param groups table 命令前缀数组（如 { "ls", "grep" }）
--- @return boolean
function M.is_params_safe(args, groups)
  if not groups or #groups == 0 then return false end
  local command = args.command or args.cmd or args[1]
  if type(command) ~= "string" then return false end
  -- 只要含分号、管道、重定向、命令替换等元字符，一律不放行，避免 ls; rm -rf / 绕过。
  if command:find(DANGEROUS_SHELL) then return false end
  local first_word = command:match("^%s*([%w%-_%./]+)")
  if not first_word then return false end
  for _, g in ipairs(groups) do
    if type(g) == "string" and first_word == g then return true end
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
  local command = args.command or args.cmd or args[1]
  local path_safe = not filepath or M.is_path_allowed(filepath, approval_config.allowed_directories)
  -- 无命令参数（纯文件/进程内工具）：命令白名单不适用，只看路径是否落在允许目录内。
  -- 否则空 allowed_param_groups 会让「路径已允许」的文件工具仍被强制审批。
  local params_safe = (command == nil) or M.is_params_safe(args, approval_config.allowed_param_groups)
  -- 无路径且无命令时按 auto_allow 决定
  if not filepath and command == nil then
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
