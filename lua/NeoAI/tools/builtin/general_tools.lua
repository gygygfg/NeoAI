-- Lua通用工具模块
-- 提供表格操作、字符串处理等常用工具函数
-- 每个工具的定义（名称、描述、参数、实现）集中在一起，方便修改
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- ============================================================================
-- 工具1: merge_tables - 合并多个表格
-- ============================================================================

local function _merge_tables(args)
  print("[general_tools] merge_tables 开始")
  if not args or not args.tables then
    print("[general_tools] merge_tables 结束: 无参数")
    return {}
  end

  local tables = args.tables
  local mode = args.mode or "force"

  if #tables == 0 then
    print("[general_tools] merge_tables 结束: 空表")
    return {}
  end

  print("[general_tools] merge_tables: " .. #tables .. " 个表, mode=" .. mode)
  local result = {}
  for i, tbl in ipairs(tables) do
    if type(tbl) == "table" then
      if mode == "force" then
        for k, v in pairs(tbl) do
          result[k] = v
        end
      else
        for k, v in pairs(tbl) do
          if result[k] == nil then
            result[k] = v
          end
        end
      end
    end
  end

  print("[general_tools] merge_tables 结束")
  return result
end

M.merge_tables = define_tool({
  name = "merge_tables",
  description = "合并多个表格",
  func = _merge_tables,
  parameters = {
    type = "object",
    properties = {
      tables = {
        type = "array",
        items = { type = "object" },
        description = "要合并的表格数组",
      },
      mode = {
        type = "string",
        description = "合并模式：force（覆盖）或 keep（保留）",
        enum = { "force", "keep" },
        default = "force",
      },
    },
    required = { "tables" },
  },
  returns = { type = "object", description = "合并后的表格" },
  category = "general",
  permissions = {},
})

-- ============================================================================
-- 工具2: table_contains - 检查表格是否包含特定值
-- ============================================================================

local function _table_contains(args)
  print("[general_tools] table_contains 开始")
  if not args or not args.table or not args.value then
    print("[general_tools] table_contains 结束: 缺少参数")
    return false
  end

  local tbl = args.table
  local value = args.value

  if type(tbl) ~= "table" then
    print("[general_tools] table_contains 结束: 不是表")
    return false
  end

  local value_str = tostring(value)
  print("[general_tools] table_contains: 查找 " .. value_str)

  for _, v in ipairs(tbl) do
    if tostring(v) == value_str then
      print("[general_tools] table_contains: 找到")
      return true
    end
  end

  for k, v in pairs(tbl) do
    if tostring(v) == value_str then
      print("[general_tools] table_contains: 找到")
      return true
    end
  end

  print("[general_tools] table_contains: 未找到")
  return false
end

M.table_contains = define_tool({
  name = "table_contains",
  description = "检查表格是否包含特定值",
  func = _table_contains,
  parameters = {
    type = "object",
    properties = {
      table = { type = "object", description = "要检查的表格" },
      value = { type = "string", description = "要查找的值" },
    },
    required = { "table", "value" },
  },
  returns = { type = "boolean", description = "是否包含该值" },
  category = "general",
  permissions = {},
})

-- ============================================================================
-- 工具3: starts_with - 检查字符串是否以指定前缀开头
-- ============================================================================

local function _starts_with(args)
  print("[general_tools] starts_with 开始")
  if not args or not args.str or not args.prefix then
    print("[general_tools] starts_with 结束: 缺少参数")
    return false
  end

  local str = args.str
  local prefix = args.prefix
  local case_sensitive = args.case_sensitive ~= false

  if not case_sensitive then
    str = str:lower()
    prefix = prefix:lower()
  end

  local result = str:sub(1, #prefix) == prefix
  print("[general_tools] starts_with 结束: " .. tostring(result))
  return result
end

M.starts_with = define_tool({
  name = "starts_with",
  description = "检查字符串是否以指定前缀开头",
  func = _starts_with,
  parameters = {
    type = "object",
    properties = {
      str = { type = "string", description = "要检查的字符串" },
      prefix = { type = "string", description = "前缀" },
      case_sensitive = { type = "boolean", description = "是否区分大小写", default = true },
    },
    required = { "str", "prefix" },
  },
  returns = { type = "boolean", description = "是否以指定前缀开头" },
  category = "text",
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

-- 测试代码
if arg and arg[0] and arg[0]:match("general_tools%.lua$") then
  print("=== 测试Lua通用工具模块 ===")

  print("\n1. 测试merge_tables函数:")
  local table1 = { a = 1, b = 2 }
  local table2 = { b = 20, c = 3 }
  local table3 = { c = 30, d = 4 }

  local merged_force = M.merge_tables.func({ tables = { table1, table2, table3 }, mode = "force" })
  print("force模式合并结果: a=" .. (merged_force.a or "nil") .. ", b=" .. (merged_force.b or "nil") .. ", c=" .. (merged_force.c or "nil") .. ", d=" .. (merged_force.d or "nil"))

  local merged_keep = M.merge_tables.func({ tables = { table1, table2, table3 }, mode = "keep" })
  print("keep模式合并结果: a=" .. (merged_keep.a or "nil") .. ", b=" .. (merged_keep.b or "nil") .. ", c=" .. (merged_keep.c or "nil") .. ", d=" .. (merged_keep.d or "nil"))

  print("\n2. 测试table_contains函数:")
  local test_table = { 1, 2, 3, name = "Lua", version = "5.4" }
  print("表格是否包含数字2: " .. tostring(M.table_contains.func({ table = test_table, value = 2 })))
  print("表格是否包含字符串'Lua': " .. tostring(M.table_contains.func({ table = test_table, value = "Lua" })))
  print("表格是否包含数字5: " .. tostring(M.table_contains.func({ table = test_table, value = 5 })))

  print("\n3. 测试starts_with函数:")
  local test_str = "Hello, World!"
  print("字符串是否以'Hello'开头（大小写敏感）: " .. tostring(M.starts_with.func({ str = test_str, prefix = "Hello" })))
  print("字符串是否以'hello'开头（不区分大小写）: " .. tostring(M.starts_with.func({ str = test_str, prefix = "hello", case_sensitive = false })))
  print("字符串是否以'World'开头: " .. tostring(M.starts_with.func({ str = test_str, prefix = "World" })))

  print("\n4. 测试get_tools函数:")
  local tools = M.get_tools()
  print("获取到的工具数量: " .. #tools)
  for i, tool in ipairs(tools) do
    print("工具" .. i .. ": " .. tool.name .. " - " .. tool.description)
  end

  print("\n=== 测试完成 ===")
end

return M
