-- 表操作工具库
-- 提供一系列用于操作Lua表的实用函数
local M = {}

--- 获取表的所有键
-- 遍历表，收集所有键到新表中
-- @param tbl table 输入的表
-- @return table 包含所有键的列表
function M.keys(tbl)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  local result = {}
  for k, _ in pairs(tbl) do
    table.insert(result, k)
  end
  return result
end

--- 获取表的所有值
-- 遍历表，收集所有值到新表中
-- @param tbl table 输入的表
-- @return table 包含所有值的列表
function M.values(tbl)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  local result = {}
  for _, v in pairs(tbl) do
    table.insert(result, v)
  end
  return result
end

--- 过滤表
-- 根据谓词函数过滤表中的元素
-- @param tbl table 要过滤的表
-- @param predicate function 谓词函数，接收值和键，返回布尔值
-- @return table 过滤后的新表
function M.filter(tbl, predicate)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  if type(predicate) ~= "function" then
    return tbl -- 非函数类型返回原表
  end
  local result = {}
  local is_array = true
  -- 检查是否是连续数字索引的数组表
  for k in pairs(tbl) do
    if type(k) ~= "number" or k < 1 or k > #tbl then
      is_array = false
      break
    end
  end
  if is_array then
    -- 处理数组表：创建连续索引的新表
    local index = 1
    for i = 1, #tbl do
      if predicate(tbl[i], i) then
        result[index] = tbl[i]
        index = index + 1
      end
    end
  else
    -- 处理字典表：保留原始键
    for k, v in pairs(tbl) do
      if predicate(v, k) then
        result[k] = v
      end
    end
  end
  return result
end

--- 映射表
-- 对表中的每个元素应用映射函数
-- @param tbl table 要映射的表
-- @param func function 映射函数，接收值和键，返回新值
-- @return table 映射后的新表
function M.map(tbl, func)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  if type(func) ~= "function" then
    return tbl -- 非函数类型返回原表
  end
  local result = {}
  for k, v in pairs(tbl) do
    result[k] = func(v, k)
  end
  return result
end

--- 归约表
-- 将表归约为单个值
-- @param tbl table 要归约的表
-- @param func function 归约函数，接收累加器、当前值和键，返回新累加器
-- @param initial any 初始累加器值
-- @return any 归约结果
function M.reduce(tbl, func, initial)
  if type(tbl) ~= "table" then
    return initial -- 非表类型返回初始值
  end
  if type(func) ~= "function" then
    return initial -- 非函数类型返回初始值
  end
  local acc = initial
  local is_first = initial == nil
  for k, v in pairs(tbl) do
    if is_first then
      acc = v
      is_first = false
    else
      acc = func(acc, v, k)
    end
  end
  return acc
end

--- 计算表长度
-- 统计表中键值对的数量
-- @param tbl table 要计算长度的表
-- @return number 表中元素的数量
function M.length(tbl)
  if type(tbl) ~= "table" then
    return 0 -- 非表类型返回0
  end
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

--- 检查表是否为空
-- 判断表是否不包含任何元素
-- @param tbl table 要检查的表
-- @return boolean 表是否为空
function M.is_empty(tbl)
  if type(tbl) ~= "table" then
    return true -- 非表类型视为空
  end
  return next(tbl) == nil
end

--- 合并多个表
-- 将多个表合并为一个表，后面的表会覆盖前面表的相同键
-- @param ... table 要合并的表
-- @return table 合并后的新表
function M.merge(...)
  local result = {}
  local tables = { ... }
  for _, tbl in ipairs(tables) do
    if type(tbl) == "table" then
      for k, v in pairs(tbl) do
        result[k] = v
      end
    end
  end
  return result
end

--- 扁平化表
-- 将嵌套的表扁平化为一维表
-- @param tbl table 要扁平化的表
-- @param depth number 扁平化深度，默认为无限深度
-- @return table 扁平化后的新表
function M.flatten(tbl, depth)
  if type(tbl) ~= "table" then
    return { tbl } -- 非表类型包装为表返回
  end
  depth = depth or math.huge
  local result = {}
  local function flatten_helper(sub_tbl, current_depth)
    if current_depth > depth then
      table.insert(result, sub_tbl)
      return
    end
    for _, v in pairs(sub_tbl) do
      if type(v) == "table" then
        flatten_helper(v, current_depth + 1)
      else
        table.insert(result, v)
      end
    end
  end
  flatten_helper(tbl, 1)
  return result
end

--- 反转表
-- 反转数组表的顺序
-- @param tbl table 要反转的数组表
-- @return table 反转后的新表
function M.reverse(tbl)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  local result = {}
  local len = #tbl
  for i = len, 1, -1 do
    table.insert(result, tbl[i])
  end
  return result
end

--- 切片表
-- 获取数组表的切片
-- @param tbl table 要切片的数组表
-- @param start number 起始索引，默认为1
-- @param finish number 结束索引，默认为表长度
-- @return table 切片后的新表
function M.slice(tbl, start, finish)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  start = start or 1
  finish = finish or #tbl
  if start < 1 then
    start = 1
  end
  if finish > #tbl then
    finish = #tbl
  end
  local result = {}
  for i = start, finish do
    table.insert(result, tbl[i])
  end
  return result
end

--- 去重表
-- 移除数组表中的重复元素
-- @param tbl table 要去重的数组表
-- @return table 去重后的新表
function M.unique(tbl)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  local seen = {}
  local result = {}
  for _, v in ipairs(tbl) do
    -- 使用序列化作为键，以处理非字符串/数字类型的值
    local key
    if type(v) == "table" then
      key = "table:" .. tostring(v) -- 简单处理，复杂表可能需要深度序列化
    else
      key = tostring(v)
    end
    if not seen[key] then
      seen[key] = true
      table.insert(result, v)
    end
  end
  return result
end

--- 排序表
-- 对数组表进行排序
-- @param tbl table 要排序的数组表
-- @param comparator function 可选的比较函数
-- @return table 排序后的新表
function M.sort(tbl, comparator)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  local result = {}
  for _, v in ipairs(tbl) do
    table.insert(result, v)
  end
  if comparator and type(comparator) == "function" then
    table.sort(result, comparator)
  else
    table.sort(result)
  end
  return result
end

--- 分组表
-- 根据键函数对数组表进行分组
-- @param tbl table 要分组的数组表
-- @param key_func function 键函数，接收元素返回分组键
-- @return table 分组后的表，键为分组键，值为分组数组
function M.group_by(tbl, key_func)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  if type(key_func) ~= "function" then
    return { tbl } -- 非函数类型返回原表包装
  end
  local result = {}
  for _, v in ipairs(tbl) do
    local key = key_func(v)
    if not result[key] then
      result[key] = {}
    end
    table.insert(result[key], v)
  end
  return result
end

--- 查找元素
-- 查找表中满足谓词函数的第一个元素
-- @param tbl table 要查找的表
-- @param predicate function 谓词函数，接收值和键，返回布尔值
-- @return any, any 找到的元素和其键，未找到返回nil
function M.find(tbl, predicate)
  if type(tbl) ~= "table" then
    return nil -- 非表类型返回nil
  end
  if type(predicate) ~= "function" then
    return nil -- 非函数类型返回nil
  end
  for k, v in pairs(tbl) do
    if predicate(v, k) then
      return v, k
    end
  end
  return nil
end

--- 检查表是否包含值
-- 判断表中是否包含指定值
-- @param tbl table 要检查的表
-- @param value any 要查找的值
-- @return boolean 是否包含该值
function M.contains(tbl, value)
  if type(tbl) ~= "table" then
    return false -- 非表类型返回false
  end
  for _, v in pairs(tbl) do
    if v == value then
      return true
    end
  end
  return false
end

--- 检查表是否包含键
-- 判断表中是否包含指定键
-- @param tbl table 要检查的表
-- @param key any 要查找的键
-- @return boolean 是否包含该键
function M.has_key(tbl, key)
  if type(tbl) ~= "table" then
    return false -- 非表类型返回false
  end
  return tbl[key] ~= nil
end

--- 转换表为键值对列表
-- 将表转换为键值对数组
-- @param tbl table 要转换的表
-- @return table 键值对列表，每个元素是{key=键, value=值}
function M.to_pairs(tbl)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  local result = {}
  for k, v in pairs(tbl) do
    table.insert(result, { key = k, value = v })
  end
  return result
end

--- 从键值对列表创建表
-- 从键值对数组创建表
-- @param pairs table 键值对列表
-- @return table 创建的新表
function M.from_pairs(pairs)
  if type(pairs) ~= "table" then
    return {} -- 非表类型返回空表
  end
  local result = {}
  for _, pair in ipairs(pairs) do
    if type(pair) == "table" and pair.key ~= nil then
      result[pair.key] = pair.value
    end
  end
  return result
end

--- 深比较两个表
-- 递归比较两个表是否深度相等
-- @param t1 table 第一个表
-- @param t2 table 第二个表
-- @return boolean 两个表是否深度相等
function M.deep_equal(t1, t2)
  if type(t1) ~= type(t2) then
    return false
  end
  if type(t1) ~= "table" then
    return t1 == t2
  end

  -- 比较元表
  if getmetatable(t1) ~= getmetatable(t2) then
    return false
  end

  -- 检查键的数量
  local count1, count2 = 0, 0
  for _ in pairs(t1) do
    count1 = count1 + 1
  end
  for _ in pairs(t2) do
    count2 = count2 + 1
  end
  if count1 ~= count2 then
    return false
  end

  -- 检查每个键值对
  for k, v1 in pairs(t1) do
    local v2 = t2[k]
    if not M.deep_equal(v1, v2) then
      return false
    end
  end
  return true
end

--- 克隆表（浅拷贝）
-- 创建表的浅拷贝
-- @param tbl table 要克隆的表
-- @return table 克隆的新表
function M.clone(tbl)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  local result = {}
  for k, v in pairs(tbl) do
    result[k] = v
  end
  return result
end

--- 获取表的子集
-- 从表中选择指定的键创建新表
-- @param tbl table 原表
-- @param keys table 要选择的键列表
-- @return table 包含指定键的新表
function M.pick(tbl, keys)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  if type(keys) ~= "table" then
    return {} -- 非表类型返回空表
  end
  local result = {}
  for _, key in ipairs(keys) do
    if tbl[key] ~= nil then
      result[key] = tbl[key]
    end
  end
  return result
end

--- 排除表的某些键
-- 从表中排除指定的键创建新表
-- @param tbl table 原表
-- @param keys table 要排除的键列表
-- @return table 排除指定键后的新表
function M.omit(tbl, keys)
  if type(tbl) ~= "table" then
    return {} -- 非表类型返回空表
  end
  if type(keys) ~= "table" then
    return tbl -- 非表类型返回原表
  end
  local key_set = {}
  for _, key in ipairs(keys) do
    key_set[key] = true
  end
  local result = {}
  for k, v in pairs(tbl) do
    if not key_set[k] then
      result[k] = v
    end
  end
  return result
end

--- 检查表是否包含值（table_contains 是 contains 的别名）
-- @param tbl table 要检查的表
-- @param value any 要查找的值
-- @return boolean 是否包含该值
function M.table_contains(tbl, value)
  return M.contains(tbl, value)
end

--- 获取表的所有键（table_keys 是 keys 的别名）
-- @param tbl table 输入的表
-- @return table 包含所有键的列表
function M.table_keys(tbl)
  return M.keys(tbl)
end

--- 获取表的所有值（table_values 是 values 的别名）
-- @param tbl table 输入的表
-- @return table 包含所有值的列表
function M.table_values(tbl)
  return M.values(tbl)
end

--- 过滤表（table_filter 是 filter 的别名）
-- @param tbl table 要过滤的表
-- @param predicate function 谓词函数
-- @return table 过滤后的新表
function M.table_filter(tbl, predicate)
  return M.filter(tbl, predicate)
end

--- 映射表（table_map 是 map 的别名）
-- @param tbl table 要映射的表
-- @param func function 映射函数
-- @return table 映射后的新表
function M.table_map(tbl, func)
  return M.map(tbl, func)
end

-- 测试代码
local function run_tests()
  print("=== 测试表操作工具库 ===")

  -- 测试数据
  local test_table = { a = 1, b = 2, c = 3 }
  local test_array = { 1, 2, 3, 4, 5 }
  local nested_table = { 1, { 2, 3 }, { 4, { 5, 6 } } }
  local dict_table = { x = 10, y = 20, z = 30 }

  -- 测试 keys
  local keys_result = M.keys(test_table)
  table.sort(keys_result)
  print("1. keys test: " .. table.concat(keys_result, ", "))

  -- 测试 values
  local values_result = M.values(test_table)
  table.sort(values_result)
  print("2. values test: " .. table.concat(values_result, ", "))

  -- 测试 filter (数组)
  local filtered_array = M.filter(test_array, function(v)
    return v % 2 == 0
  end)
  print("3. filter 数组偶数: " .. table.concat(filtered_array, ", "))

  -- 测试 filter (字典)
  local filtered_dict = M.filter(dict_table, function(v, k)
    return v > 15
  end)
  print("4. filter 字典值>15: " .. #M.keys(filtered_dict) .. " 个元素")

  -- 测试 map
  local mapped = M.map(test_array, function(v)
    return v * 2
  end)
  print("5. map 乘2: " .. table.concat(mapped, ", "))

  -- 测试 reduce
  local sum = M.reduce(test_array, function(acc, v)
    return acc + v
  end, 0)
  print("6. reduce 求和: " .. tostring(sum))

  -- 测试 length
  print("7. length test_table: " .. M.length(test_table))
  print("   length test_array: " .. M.length(test_array))

  -- 测试 is_empty
  print("8. is_empty {}: " .. tostring(M.is_empty({})))
  print("   is_empty test_table: " .. tostring(M.is_empty(test_table)))

  -- 测试 merge
  local merged = M.merge({ a = 1 }, { b = 2 }, { c = 3 })
  print("9. merge 数量: " .. M.length(merged))

  -- 测试 flatten
  local flattened = M.flatten(nested_table, 2)
  print("10. flatten depth=2: " .. table.concat(flattened, ", "))

  -- 测试 reverse
  local reversed = M.reverse(test_array)
  print("11. reverse: " .. table.concat(reversed, ", "))

  -- 测试 slice
  local sliced = M.slice(test_array, 2, 4)
  print("12. slice 2-4: " .. table.concat(sliced, ", "))

  -- 测试 unique
  local with_dups = { 1, 2, 2, 3, 3, 3, "a", "a" }
  local unique = M.unique(with_dups)
  print("13. unique: " .. table.concat(unique, ", "))

  -- 测试 sort
  local unsorted = { 5, 3, 1, 4, 2 }
  local sorted = M.sort(unsorted)
  print("14. sort: " .. table.concat(sorted, ", "))

  -- 测试 group_by
  local items = {
    { type = "fruit", name = "apple" },
    { type = "fruit", name = "banana" },
    { type = "vegetable", name = "carrot" },
  }
  local grouped = M.group_by(items, function(item)
    return item.type
  end)
  print("15. group_by fruit 数量: " .. #grouped.fruit)
  print("   group_by vegetable 数量: " .. #grouped.vegetable)

  -- 测试 contains
  print("16. contains 3: " .. tostring(M.contains(test_array, 3)))
  print("   contains 6: " .. tostring(M.contains(test_array, 6)))

  -- 测试 has_key
  print("17. has_key 'a': " .. tostring(M.has_key(test_table, "a")))
  print("   has_key 'd': " .. tostring(M.has_key(test_table, "d")))

  -- 测试 clone
  local cloned = M.clone(test_table)
  cloned.d = 4
  print("18. clone 测试:")
  print("   原表a: " .. test_table.a .. ", 克隆表a: " .. cloned.a)
  print("   克隆表d: " .. tostring(cloned.d) .. ", 原表d: " .. tostring(test_table.d))

  -- 测试 deep_equal
  local t1 = { a = 1, b = { c = 2, d = { 3, 4 } } }
  local t2 = { a = 1, b = { c = 2, d = { 3, 4 } } }
  local t3 = { a = 1, b = { c = 2, d = { 3, 5 } } }
  print("19. deep_equal 相同: " .. tostring(M.deep_equal(t1, t2)))
  print("   deep_equal 不同: " .. tostring(M.deep_equal(t1, t3)))

  -- 测试 find
  local found_val, found_key = M.find(test_table, function(v, k)
    return v == 2
  end)
  print("20. find 值=2: 值=" .. tostring(found_val) .. ", 键=" .. tostring(found_key))

  -- 测试 pick
  local picked = M.pick(test_table, { "a", "c", "e" })
  print("21. pick a,c,e: 数量=" .. M.length(picked))

  -- 测试 omit
  local omitted = M.omit(test_table, { "b" })
  print("22. omit b: 数量=" .. M.length(omitted))

  -- 测试 to_pairs / from_pairs
  local pairs_list = M.to_pairs(test_table)
  local from_pairs = M.from_pairs(pairs_list)
  print("23. to_pairs/from_pairs: 转换后表长度=" .. M.length(from_pairs))

  print("=== 测试完成 ===")
end

-- 如果直接运行此文件，则执行测试
if arg and arg[0]:match("table_utils%.lua$") then
  run_tests()
end

return M
