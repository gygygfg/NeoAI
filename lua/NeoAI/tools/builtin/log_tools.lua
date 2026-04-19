-- NeoAI 日志工具模块
-- 本模块提供日志记录功能，与NeoAI工具系统集成
-- 主要功能：记录日志消息、获取可用日志级别

local M = {}

--- 获取所有可用的日志工具
-- 此函数返回一个工具列表，每个工具都符合NeoAI工具系统的规范
-- 每个工具包含名称、描述、函数、参数定义、返回值和分类等信息
-- @return table 工具列表，包含log_message和get_log_levels两个工具
function M.get_tools()
  return {
    {
      name = "log_message", -- 工具名称
      description = "记录日志消息", -- 工具描述
      func = M.log_message, -- 工具函数
      parameters = { -- 参数定义
        type = "object", -- 参数类型为对象
        properties = { -- 对象属性定义
          message = { -- 消息参数
            type = "string", -- 字符串类型
            description = "日志消息", -- 参数描述
          },
          level = { -- 级别参数
            type = "string", -- 字符串类型
            description = "日志级别", -- 参数描述
            enum = { "info", "warn", "error", "debug" }, -- 枚举值
            default = "info", -- 默认值
          },
        },
        required = { "message" }, -- 必需参数
      },
      returns = { -- 返回值定义
        type = "boolean", -- 布尔类型
        description = "是否记录成功", -- 返回值描述
      },
      category = "log", -- 工具分类
      permissions = {}, -- 权限要求
    },
    {
      name = "get_log_levels", -- 工具名称
      description = "获取可用的日志级别", -- 工具描述
      func = M.get_log_levels, -- 工具函数
      parameters = { -- 参数定义
        type = "object", -- 参数类型为对象
        properties = {}, -- 无属性（不需要参数）
      },
      returns = { -- 返回值定义
        type = "array", -- 数组类型
        items = { -- 数组项定义
          type = "string", -- 字符串类型
        },
        description = "日志级别列表", -- 返回值描述
      },
      category = "log", -- 工具分类
      permissions = {}, -- 权限要求
    },
  }
end -- 修复：添加缺失的end关键字

--- 记录日志消息
-- 此函数接收消息和级别参数，通过vim.notify记录日志
-- 支持四种日志级别：info、warn、error、debug
-- @param args table 参数表，包含message和level字段
-- @return boolean 是否成功记录日志，参数无效时返回false
function M.log_message(args)
  -- 参数验证：确保args存在且包含message字段
  if not args or not args.message then
    return false
  end

  local message = args.message -- 日志消息内容
  local level = args.level or "info" -- 日志级别，默认为info

  -- 将字符串级别转换为vim.log.levels常量
  -- vim.notify需要vim.log.levels中的常量值
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

  -- 使用vim.notify记录日志，添加[NeoAI Tool]前缀便于识别
  vim.notify("[NeoAI Tool] " .. message, vim_level)
  return true
end

--- 获取可用的日志级别列表
-- 此函数返回支持的日志级别数组
-- 注意：虽然参数定义为args，但实际不需要任何参数
-- @param args table 参数表（为保持接口一致性而保留，实际不使用）
-- @return table 日志级别列表，包含"info", "warn", "error", "debug"
function M.get_log_levels(args)
  -- 返回固定的日志级别列表
  -- 这些级别与vim.log.levels常量对应
  return { "info", "warn", "error", "debug" }
end

-- 测试函数
-- 以下代码用于测试模块功能
local function test_log_module()
  print("=== 开始测试日志模块 ===")

  -- 测试1：获取工具列表
  print("\n1. 获取工具列表：")
  local tools = M.get_tools()
  print("  工具数量：" .. #tools)
  for i, tool in ipairs(tools) do
    print("  " .. i .. ". " .. tool.name .. " - " .. tool.description)
  end

  -- 测试2：记录不同级别的日志
  print("\n2. 记录日志消息测试：")
  local test_cases = {
    { message = "这是一条普通信息", level = "info" },
    { message = "这是一条警告信息", level = "warn" },
    { message = "这是一条错误信息", level = "error" },
    { message = "这是一条调试信息", level = "debug" },
    { message = "使用默认级别的信息" }, -- 不指定level，使用默认值
  }

  for i, test_case in ipairs(test_cases) do
    local success = M.log_message(test_case)
    print("  测试" .. i .. " (" .. (test_case.level or "default") .. "): " .. (success and "成功" or "失败"))
  end

  -- 测试3：无效参数测试
  print("\n3. 无效参数测试：")
  local invalid_result1 = M.log_message(nil)
  local invalid_result2 = M.log_message({})
  print("  无参数测试: " .. (invalid_result1 and "错误" or "正确（返回false）"))
  print("  空参数测试: " .. (invalid_result2 and "错误" or "正确（返回false）"))

  -- 测试4：获取日志级别
  print("\n4. 获取日志级别：")
  local levels = M.get_log_levels({})
  print("  支持的日志级别: " .. table.concat(levels, ", "))

  print("\n=== 测试完成 ===")
end

-- 当直接运行此文件时执行测试
if arg and arg[0] and arg[0]:match("log_tool.lua$") then
  test_log_module()
end

return M
