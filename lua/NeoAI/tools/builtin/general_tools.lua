-- Lua通用工具模块
-- 提供表格操作、字符串处理等常用工具函数
local M = {}

--- 获取所有可用的通用工具
--- 此函数返回一个表格，包含模块中定义的所有工具函数的元信息
--- 每个工具包含名称、描述、函数引用、参数定义、返回值定义、分类和权限信息
--- @return table 工具列表，每个工具是一个表格结构
function M.get_tools()
  return {
    {
      name = "merge_tables", -- 工具名称
      description = "合并多个表格", -- 工具功能描述
      func = M.merge_tables, -- 对应的函数引用
      parameters = { -- 参数定义（符合JSON Schema风格）
        type = "object", -- 参数类型为对象
        properties = { -- 属性定义
          tables = { -- tables参数
            type = "array", -- 类型为数组
            items = { -- 数组元素定义
              type = "object", -- 每个元素是表格对象
            },
            description = "要合并的表格数组", -- 参数描述
          },
          mode = { -- mode参数
            type = "string", -- 类型为字符串
            description = "合并模式：force（覆盖）或 keep（保留）", -- 参数描述
            enum = { "force", "keep" }, -- 枚举值限制
            default = "force", -- 默认值
          },
        }, -- 注意：这里修复了缺少的右大括号
        required = { "tables" }, -- 必填参数
      },
      returns = { -- 返回值定义
        type = "object", -- 返回类型为表格对象
        description = "合并后的表格", -- 返回值描述
      },
      category = "general", -- 工具分类
      permissions = {}, -- 所需权限（空表示不需要特殊权限）
    },
    {
      name = "table_contains", -- 工具名称
      description = "检查表格是否包含特定值", -- 工具功能描述
      func = M.table_contains, -- 对应的函数引用
      parameters = { -- 参数定义
        type = "object", -- 参数类型为对象
        properties = { -- 属性定义
          table = { -- table参数
            type = "object", -- 类型为对象（Lua表格）
            description = "要检查的表格", -- 参数描述
          },
          value = { -- value参数
            type = "string", -- 类型为字符串
            description = "要查找的值", -- 参数描述
          },
        },
        required = { "table", "value" }, -- 必填参数
      },
      returns = { -- 返回值定义
        type = "boolean", -- 返回类型为布尔值
        description = "是否包含该值", -- 返回值描述
      },
      category = "general", -- 工具分类
      permissions = {}, -- 所需权限
    },
    {
      name = "starts_with", -- 工具名称
      description = "检查字符串是否以指定前缀开头", -- 工具功能描述
      func = M.starts_with, -- 对应的函数引用
      parameters = { -- 参数定义
        type = "object", -- 参数类型为对象
        properties = { -- 属性定义
          str = { -- str参数
            type = "string", -- 类型为字符串
            description = "要检查的字符串", -- 参数描述
          },
          prefix = { -- prefix参数
            type = "string", -- 类型为字符串
            description = "前缀", -- 参数描述
          },
          case_sensitive = { -- case_sensitive参数
            type = "boolean", -- 类型为布尔值
            description = "是否区分大小写", -- 参数描述
            default = true, -- 默认值为true
          },
        },
        required = { "str", "prefix" }, -- 必填参数
      },
      returns = { -- 返回值定义
        type = "boolean", -- 返回类型为布尔值
        description = "是否以指定前缀开头", -- 返回值描述
      },
      category = "text", -- 工具分类
      permissions = {}, -- 所需权限
    },
  }
end

--- 合并多个表格
--- 此函数可以将多个表格合并为一个表格，支持两种合并模式
--- 1. force模式：后面的表格会覆盖前面表格中相同键的值
--- 2. keep模式：只添加前面表格中不存在的键值对
--- @param args table 包含合并参数的表格
---                tables: 要合并的表格数组
---                mode: 合并模式，可选值为"force"或"keep"，默认为"force"
--- @return table 合并后的表格，如果参数无效则返回空表格
function M.merge_tables(args)
  -- 参数验证：确保args存在且包含tables字段
  if not args or not args.tables then
    return {} -- 参数无效时返回空表格
  end

  local tables = args.tables -- 获取要合并的表格数组
  local mode = args.mode or "force" -- 获取合并模式，默认为"force"

  -- 边界情况处理：如果表格数组为空，直接返回空表格
  if #tables == 0 then
    return {}
  end

  local result = {} -- 初始化结果表格

  -- 遍历所有要合并的表格
  for i, tbl in ipairs(tables) do
    if type(tbl) == "table" then -- 确保当前元素是表格
      if mode == "force" then
        -- 覆盖模式：遍历当前表格的所有键值对
        for k, v in pairs(tbl) do
          result[k] = v -- 直接赋值，后面的会覆盖前面的
        end
      else
        -- 保留模式：只添加结果表格中不存在的键
        for k, v in pairs(tbl) do
          if result[k] == nil then -- 只有当键不存在时才添加
            result[k] = v
          end
        end
      end
    end
    -- 如果tbl不是表格类型，则跳过不处理
  end

  return result -- 返回合并后的表格
end

--- 检查表格是否包含特定值
--- 此函数会同时检查表格的数组部分和字典部分
--- 数组部分：遍历所有数值索引的值
--- 字典部分：遍历所有键值对的值
--- 注意：比较时会先将值转换为字符串再进行比较
--- @param args table 包含检查参数的表格
---                table: 要检查的表格
---                value: 要查找的值
--- @return boolean 如果表格包含该值则返回true，否则返回false
function M.table_contains(args)
  -- 参数验证：确保args存在且包含必要的字段
  if not args or not args.table or not args.value then
    return false -- 参数无效时返回false
  end

  local tbl = args.table -- 获取要检查的表格
  local value = args.value -- 获取要查找的值

  -- 参数类型验证：确保tbl是表格类型
  if type(tbl) ~= "table" then
    return false
  end

  -- 将查找值转换为字符串，用于后续比较
  local value_str = tostring(value)

  -- 检查表格的数组部分（数值索引）
  for _, v in ipairs(tbl) do
    if tostring(v) == value_str then
      return true -- 找到匹配值，返回true
    end
  end

  -- 检查表格的字典部分（所有键值对）
  for k, v in pairs(tbl) do
    if tostring(v) == value_str then
      return true -- 找到匹配值，返回true
    end
  end

  return false -- 遍历完所有值都未找到，返回false
end

--- 检查字符串是否以指定前缀开头
--- 此函数支持大小写敏感和不敏感两种模式
--- 默认情况下是大小写敏感的，可以通过case_sensitive参数控制
--- @param args table 包含检查参数的表格
---                str: 要检查的字符串
---                prefix: 要检查的前缀
---                case_sensitive: 是否区分大小写，默认为true
--- @return boolean 如果字符串以指定前缀开头则返回true，否则返回false
function M.starts_with(args)
  -- 参数验证：确保args存在且包含必要的字段
  if not args or not args.str or not args.prefix then
    return false -- 参数无效时返回false
  end

  local str = args.str -- 获取要检查的字符串
  local prefix = args.prefix -- 获取要检查的前缀
  -- 获取大小写敏感设置，默认值为true（当args.case_sensitive不为false时）
  local case_sensitive = args.case_sensitive ~= false

  -- 如果不需要区分大小写，将字符串和前缀都转换为小写
  if not case_sensitive then
    str = str:lower() -- 转换为小写
    prefix = prefix:lower() -- 转换为小写
  end

  -- 使用字符串的sub方法获取前n个字符，与前缀进行比较
  -- #prefix获取前缀的长度，str:sub(1, #prefix)获取字符串的前缀部分
  return str:sub(1, #prefix) == prefix
end

-- 测试代码
if arg and arg[0] and arg[0]:match("general_tools%.lua$") then
  print("=== 测试Lua通用工具模块 ===")

  -- 测试merge_tables函数
  print("\n1. 测试merge_tables函数:")
  local table1 = { a = 1, b = 2 }
  local table2 = { b = 20, c = 3 }
  local table3 = { c = 30, d = 4 }

  -- 测试force模式
  local merged_force = M.merge_tables({ tables = { table1, table2, table3 }, mode = "force" })
  print(
    "force模式合并结果: a="
      .. (merged_force.a or "nil")
      .. ", b="
      .. (merged_force.b or "nil")
      .. ", c="
      .. (merged_force.c or "nil")
      .. ", d="
      .. (merged_force.d or "nil")
  )

  -- 测试keep模式
  local merged_keep = M.merge_tables({ tables = { table1, table2, table3 }, mode = "keep" })
  print(
    "keep模式合并结果: a="
      .. (merged_keep.a or "nil")
      .. ", b="
      .. (merged_keep.b or "nil")
      .. ", c="
      .. (merged_keep.c or "nil")
      .. ", d="
      .. (merged_keep.d or "nil")
  )

  -- 测试table_contains函数
  print("\n2. 测试table_contains函数:")
  local test_table = { 1, 2, 3, name = "Lua", version = "5.4" }

  local contains_2 = M.table_contains({ table = test_table, value = 2 })
  print("表格是否包含数字2: " .. tostring(contains_2))

  local contains_lua = M.table_contains({ table = test_table, value = "Lua" })
  print("表格是否包含字符串'Lua': " .. tostring(contains_lua))

  local contains_5 = M.table_contains({ table = test_table, value = 5 })
  print("表格是否包含数字5: " .. tostring(contains_5))

  -- 测试starts_with函数
  print("\n3. 测试starts_with函数:")
  local test_str = "Hello, World!"

  local starts_hello = M.starts_with({ str = test_str, prefix = "Hello" })
  print("字符串是否以'Hello'开头（大小写敏感）: " .. tostring(starts_hello))

  local starts_hello_insensitive = M.starts_with({ str = test_str, prefix = "hello", case_sensitive = false })
  print("字符串是否以'hello'开头（不区分大小写）: " .. tostring(starts_hello_insensitive))

  local starts_world = M.starts_with({ str = test_str, prefix = "World" })
  print("字符串是否以'World'开头: " .. tostring(starts_world))

  -- 测试get_tools函数
  print("\n4. 测试get_tools函数:")
  local tools = M.get_tools()
  print("获取到的工具数量: " .. #tools)
  for i, tool in ipairs(tools) do
    print("工具" .. i .. ": " .. tool.name .. " - " .. tool.description)
  end

  print("\n=== 测试完成 ===")
end

-- 导出模块
return M
