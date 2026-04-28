-- NeoAI 日志工具模块（回调模式）
-- 提供日志记录功能
-- 工具函数签名：func(args, on_success, on_error)

local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- ============================================================================
-- 工具1: log_message - 记录日志消息（回调模式）
-- ============================================================================

local function _log_message(args, on_success, on_error)
  if not args or not args.message then
    if on_error then on_error("缺少消息参数") end
    return
  end

  local message = args.message
  local level = args.level or "info"

  local vim_level
  if level == "error" then
    vim_level = vim.log.levels.ERROR
  elseif level == "warn" then
    vim_level = vim.log.levels.WARN
  elseif level == "debug" then
    vim_level = vim.log.levels.DEBUG
  else
    vim_level = vim.log.levels.INFO
  end

  vim.notify("[NeoAI Tool] " .. message, vim_level)

  if on_success then on_success(true) end
end

M.log_message = define_tool({
  name = "log_message",
  description = "记录日志消息",
  func = _log_message,
  async = true,
  parameters = {
    type = "object",
    properties = {
      message = { type = "string", description = "日志消息" },
      level = {
        type = "string",
        description = "日志级别",
        enum = { "info", "warn", "error", "debug" },
        default = "info",
      },
    },
    required = { "message" },
  },
  returns = { type = "boolean", description = "是否记录成功" },
  category = "log",
  permissions = {},
})

-- ============================================================================
-- 工具2: get_log_levels - 获取可用的日志级别（回调模式）
-- ============================================================================

local function _get_log_levels(args, on_success, on_error)
  if on_success then on_success({ "info", "warn", "error", "debug" }) end
end

M.get_log_levels = define_tool({
  name = "get_log_levels",
  description = "获取可用的日志级别",
  func = _get_log_levels,
  async = true,
  parameters = {
    type = "object",
    properties = {},
  },
  returns = {
    type = "array",
    items = { type = "string" },
    description = "日志级别列表",
  },
  category = "log",
  permissions = {},
})

-- get_tools() - 返回所有工具列表供注册
function M.get_tools()
  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  table.sort(tools, function(a, b)
    return a.name < b.name
  end)
  return tools
end

return M
