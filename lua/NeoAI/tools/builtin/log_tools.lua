-- NeoAI 日志工具模块
-- 提供日志记录功能
-- 每个工具的定义（名称、描述、参数、实现）集中在一起，方便修改

local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- ============================================================================
-- 工具1: log_message - 记录日志消息
-- ============================================================================

local function _log_message(args)
  print("[log_tools] log_message 开始, level=" .. tostring(args and args.level or "info"))
  if not args or not args.message then
    print("[log_tools] log_message 结束: 缺少消息")
    return false
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
  print("[log_tools] log_message 结束: 成功")
  return true
end

M.log_message = define_tool({
  name = "log_message",
  description = "记录日志消息",
  func = _log_message,
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
-- 工具2: get_log_levels - 获取可用的日志级别
-- ============================================================================

local function _get_log_levels(args)
  print("[log_tools] get_log_levels")
  return { "info", "warn", "error", "debug" }
end

M.get_log_levels = define_tool({
  name = "get_log_levels",
  description = "获取可用的日志级别",
  func = _get_log_levels,
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

-- ============================================================================
-- get_tools() - 返回所有工具列表供注册
-- ============================================================================

function M.get_tools()
  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  table.sort(tools, function(a, b) return a.name < b.name end)
  return tools
end

-- 测试函数
local function test_log_module()
  print("=== 开始测试日志模块 ===")

  print("\n1. 获取工具列表：")
  local tools = M.get_tools()
  print("  工具数量：" .. #tools)
  for i, tool in ipairs(tools) do
    print("  " .. i .. ". " .. tool.name .. " - " .. tool.description)
  end

  print("\n2. 记录日志消息测试：")
  local test_cases = {
    { message = "这是一条普通信息", level = "info" },
    { message = "这是一条警告信息", level = "warn" },
    { message = "这是一条错误信息", level = "error" },
    { message = "这是一条调试信息", level = "debug" },
    { message = "使用默认级别的信息" },
  }
  for i, test_case in ipairs(test_cases) do
    local success = M.log_message.func(test_case)
    print("  测试" .. i .. " (" .. (test_case.level or "default") .. "): " .. (success and "成功" or "失败"))
  end

  print("\n3. 无效参数测试：")
  print("  无参数测试: " .. (M.log_message.func(nil) and "错误" or "正确（返回false）"))
  print("  空参数测试: " .. (M.log_message.func({}) and "错误" or "正确（返回false）"))

  print("\n4. 获取日志级别：")
  local levels = M.get_log_levels.func({})
  print("  支持的日志级别: " .. table.concat(levels, ", "))

  print("\n=== 测试完成 ===")
end

if arg and arg[0] and arg[0]:match("log_tool.lua$") then
  test_log_module()
end

return M
