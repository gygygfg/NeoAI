--- 工具注册表
--- @module NeoAI.tools.registry
--- 集中管理工具定义。注册、查询、审批配置。

local M = {}

-- ========== 私有状态 ==========

local state = {
  tools = {}, -- name -> tool def
  approval_overrides = {}, -- name -> 覆盖配置
}

-- ========== 私有函数 ==========

--- 校验工具定义
--- @param tool table
--- @return boolean, string|nil
local function _validate(tool)
  if type(tool) ~= "table" then return false, "工具定义必须是 table" end
  if type(tool.name) ~= "string" or tool.name == "" then return false, "工具缺少 name" end
  if type(tool.func) ~= "function" and type(tool.execute) ~= "function" then
    return false, "工具缺少 func 或 execute"
  end
  return true
end

--- 为工具附加沙箱规格（所有注册路径统一，覆盖 MCP 动态注册）
--- @param tool table
--- @return table
local function _attach(tool)
  local ok, wrapper = pcall(require, "NeoAI.sandbox.wrapper")
  if ok and wrapper and wrapper.attach then wrapper.attach(tool) end
  return tool
end

-- ========== 公开 API ==========

--- 注册工具
--- @param tool table { name, description, parameters, func|execute, category, approval }
--- @return boolean, string|nil
function M.register(tool)
  local ok, err = _validate(tool)
  if not ok then return false, err end
  if state.tools[tool.name] then
    return false, "工具已存在: " .. tool.name
  end
  state.tools[tool.name] = _attach(tool)
  return true
end

--- 批量注册
--- @param tools table 数组
--- @return table { ok = 数量, errors = {...} }
function M.register_many(tools)
  local result = { ok = 0, errors = {} }
  for _, tool in ipairs(tools or {}) do
    local ok, err = M.register(tool)
    if ok then
      result.ok = result.ok + 1
    else
      result.errors[#result.errors + 1] = err
    end
  end
  return result
end

--- 更新工具定义（覆盖同名工具，用于 MCP 工具刷新等热更新场景）
--- @param tool table 工具定义（与 register 同构）
--- @return boolean, string|nil
function M.update(tool)
  local ok, err = _validate(tool)
  if not ok then return false, err end
  state.tools[tool.name] = _attach(tool)
  return true
end

--- 删除工具定义
--- @param name string
--- @return boolean
function M.remove(name)
  if state.tools[name] == nil then return false end
  state.tools[name] = nil
  state.approval_overrides[name] = nil
  return true
end

--- 获取工具定义
--- @param name string
--- @return table|nil
function M.get(name)
  return state.tools[name]
end

--- 列出工具
--- @param category string|nil 按类别过滤
--- @return table 数组
function M.list(category)
  local out = {}
  for name, tool in pairs(state.tools) do
    if not category or tool.category == category then
      out[#out + 1] = tool
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- 列出工具为 name -> def 映射（供 Agent 绑定）
--- @param category string|nil
--- @return table name -> tool
function M.list_as_map(category)
  local out = {}
  for name, tool in pairs(state.tools) do
    if not category or tool.category == category then
      out[name] = tool
    end
  end
  return out
end

--- 搜索工具
--- @param query string
--- @return table 数组
function M.search(query)
  local out = {}
  local q = query:lower()
  for name, tool in pairs(state.tools) do
    local desc = (tool.description or ""):lower()
    local cat = (tool.category or ""):lower()
    if name:lower():find(q, 1, true) or desc:find(q, 1, true) or cat:find(q, 1, true) then
      out[#out + 1] = tool
    end
  end
  return out
end

--- 按名称模糊匹配工具（支持别名）
--- @param raw_name string
--- @return string|nil 规范化工具名
function M.resolve_name(raw_name)
  if state.tools[raw_name] then return raw_name end
  -- 别名映射
  local aliases = {
    read = "read_file", cat = "read_file",
    write = "edit_file", edit = "edit_file",
    list = "list_files", ls = "list_files",
    search = "search_files", grep = "search_files",
    delete = "delete_file", rm = "delete_file",
    mkdir = "create_directory", cd = "run_command",
    cmd = "run_command", shell = "run_command",
    git = "run_command",
  }
  local alias = aliases[raw_name]
  if alias and state.tools[alias] then return alias end
  -- 前缀匹配
  for name in pairs(state.tools) do
    if name:find(raw_name, 1, true) then return name end
  end
  return nil
end

--- 是否注册
--- @param name string
--- @return boolean
function M.has(name)
  return state.tools[name] ~= nil
end

--- 工具数量
--- @return number
function M.count()
  local n = 0
  for _ in pairs(state.tools) do n = n + 1 end
  return n
end

--- 应用审批配置覆盖（来自 config_store）
--- @param overrides table per_tool 配置
function M.apply_approval_config(overrides)
  state.approval_overrides = vim.deepcopy(overrides or {})
end

--- 获取工具的审批配置
--- 合并顺序：全局默认（`tools.approval.allowed_directories` / `allowed_param_groups`
--- / `default_auto_allow`）→ 工具自身默认 → 用户 per_tool 覆盖。
--- 允许目录/命令组按**并集**合并：全局「工作区目录」一旦设置，其子目录对所有工具自动放行，
--- 工具自身与 per_tool 的条目只做追加，不会覆盖掉全局工作区。
--- @param name string
--- @return table { auto_allow, allowed_directories, allowed_param_groups }
function M.get_approval_config(name)
  local tool = state.tools[name]
  local global = require("NeoAI.kernel.config_store").get("tools.approval") or {}
  local base = {
    auto_allow = global.default_auto_allow == true,
    allowed_directories = vim.deepcopy(global.allowed_directories or {}),
    allowed_param_groups = vim.deepcopy(global.allowed_param_groups or {}),
  }
  local function add_dirs(list)
    for _, d in ipairs(list or {}) do base.allowed_directories[#base.allowed_directories + 1] = d end
  end
  local function add_groups(list)
    for _, g in ipairs(list or {}) do base.allowed_param_groups[#base.allowed_param_groups + 1] = g end
  end
  if tool and tool.approval then
    if tool.approval.auto_allow ~= nil then base.auto_allow = tool.approval.auto_allow end
    add_dirs(tool.approval.allowed_directories)
    add_groups(tool.approval.allowed_param_groups)
  end
  -- 用户 per_tool 覆盖：追加允许目录/命令组（不覆盖全局工作区），auto_allow 显式覆盖。
  local ov = state.approval_overrides[name]
  if ov then
    if ov.auto_allow ~= nil then base.auto_allow = ov.auto_allow end
    add_dirs(ov.allowed_directories)
    add_groups(ov.allowed_param_groups)
  end
  return base
end

--- 设置运行期审批配置
--- @param name string
--- @param config table
function M.set_runtime_approval(name, config)
  state.approval_overrides[name] = vim.deepcopy(config)
end

--- 运行期把目录并入某工具的 allowed_directories（审批弹窗「加入工作目录」用）。
--- 只记录新增目录；生效配置由 get_approval_config 与全局/工具默认做并集。
--- @param name string 工具名
--- @param dir string 目录路径（可为相对/带 ~）
--- @return boolean 是否新增（已包含或参数非法时返回 false）
function M.add_allowed_directory(name, dir)
  if type(name) ~= "string" or type(dir) ~= "string" or dir == "" then return false end
  local abs = vim.fn.fnamemodify(vim.fn.expand(dir), ":p"):gsub("/+$", "")
  if abs == "" then return false end
  -- 已生效（全局/工具默认/已有覆盖）的目录不重复添加
  for _, d in ipairs(M.get_approval_config(name).allowed_directories or {}) do
    if vim.fn.fnamemodify(vim.fn.expand(d), ":p"):gsub("/+$", "") == abs then return false end
  end
  local ov = vim.deepcopy(state.approval_overrides[name] or {})
  ov.allowed_directories = ov.allowed_directories or {}
  ov.allowed_directories[#ov.allowed_directories + 1] = abs
  state.approval_overrides[name] = ov
  return true
end

--- 清空（测试用）
function M.reset()
  state.tools = {}
  state.approval_overrides = {}
end

return M
