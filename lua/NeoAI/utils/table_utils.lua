local M = {}

--- 获取表的所有键
--- @param tbl table 表
--- @return table 键列表
function M.keys(tbl)
    if type(tbl) ~= "table" then
        return {}
    
    local result = {}
    for k, _ in pairs(tbl) do
        table.insert(result, k)
    
    return result

--- 获取表的所有值
--- @param tbl table 表
--- @return table 值列表
function M.values(tbl)
    if type(tbl) ~= "table" then
        return {}
    
    local result = {}
    for _, v in pairs(tbl) do
        table.insert(result, v)
    
    return result

--- 过滤表
--- @param tbl table 表
--- @param predicate function 谓词函数
--- @return table 过滤后的表
function M.filter(tbl, predicate)
    if type(tbl) ~= "table" then
        return {}
    
    if type(predicate) ~= "function" then
        return tbl
    
    local result = {}
    local is_array = true
    
    -- 检查是否是数组表
    for k in pairs(tbl) do
        if type(k) ~= "number" or k < 1 or k > #tbl then
            is_array = false
            break
        
    
    if is_array then
        -- 数组表：创建连续索引
        local index = 1
        for i = 1, #tbl do
            if predicate(tbl[i], i) then
                result[index] = tbl[i]
                index = index + 1
            
        
    else
        -- 字典表：保留原始键
        for k, v in pairs(tbl) do
            if predicate(v, k) then
                result[k] = v
            
        
    
    return result

--- 映射表
--- @param tbl table 表
--- @param func function 映射函数
--- @return table 映射后的表
function M.map(tbl, func)
    if type(tbl) ~= "table" then
        return {}
    
    if type(func) ~= "function" then
        return tbl
    
    local result = {}
    for k, v in pairs(tbl) do
        result[k] = func(v, k)
    
    return result

--- 归约表
--- @param tbl table 表
--- @param func function 归约函数
--- @param initial any 初始值
--- @return any 归约结果
function M.reduce(tbl, func, initial)
    if type(tbl) ~= "table" then
        return initial
    
    if type(func) ~= "function" then
        return initial
    
    local accumulator = initial
    local is_first = initial == nil

    for k, v in pairs(tbl) do
        if is_first then
            accumulator = v
            is_first = false
        else
            accumulator = func(accumulator, v, k)
        
    
    return accumulator

--- 表长度
--- @param tbl table 表
--- @return number 长度
function M.length(tbl)
    if type(tbl) ~= "table" then
        return 0
    
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    
    return count

--- 表是否为空
--- @param tbl table 表
--- @return boolean 是否为空
function M.is_empty(tbl)
    if type(tbl) ~= "table" then
        return true
    
    return next(tbl) == nil

--- 合并多个表
--- @param ... table 要合并的表
--- @return table 合并后的表
function M.merge(...)
    local result = {}
    local tables = { ... }

    for _, tbl in ipairs(tables) do
        if type(tbl) == "table" then
            for k, v in pairs(tbl) do
                result[k] = v
            
        
    
    return result

--- 扁平化表
--- @param tbl table 表
--- @param depth number 深度
--- @return table 扁平化后的表
function M.flatten(tbl, depth)
    if type(tbl) ~= "table" then
        return { tbl }
    
    depth = depth or math.huge
    local result = {}

    local function flatten_helper(sub_tbl, current_depth)
        if current_depth > depth then
            table.insert(result, sub_tbl)
            return
        
        for _, v in ipairs(sub_tbl) do
            if type(v) == "table" then
                flatten_helper(v, current_depth + 1)
            else
                table.insert(result, v)
            
        
    
    flatten_helper(tbl, 1)
    return result

--- 反转表
--- @param tbl table 表
--- @return table 反转后的表
function M.reverse(tbl)
    if type(tbl) ~= "table" then
        return {}
    
    local result = {}
    local len = #tbl

    for i = len, 1, -1 do
        table.insert(result, tbl[i])
    
    return result

--- 切片表
--- @param tbl table 表
--- @param start number 起始索引
--- @param finish number 结束索引
--- @return table 切片后的表
function M.slice(tbl, start, finish)
    if type(tbl) ~= "table" then
        return {}
    
    start = start or 1
    finish = finish or #tbl

    if start < 1 then
        start = 1
    
    if finish > #tbl then
        finish = #tbl
    
    local result = {}
    for i = start, finish do
        table.insert(result, tbl[i])
    
    return result

--- 去重表
--- @param tbl table 表
--- @return table 去重后的表
function M.unique(tbl)
    if type(tbl) ~= "table" then
        return {}
    
    local seen = {}
    local result = {}

    for _, v in ipairs(tbl) do
        local key = tostring(v)
        if not seen[key] then
            seen[key] = true
            table.insert(result, v)
        
    
    return result

--- 排序表
--- @param tbl table 表
--- @param comparator function 比较函数
--- @return table 排序后的表
function M.sort(tbl, comparator)
    if type(tbl) ~= "table" then
        return {}
    
    local result = {}
    for _, v in ipairs(tbl) do
        table.insert(result, v)
    
    if comparator and type(comparator) == "function" then
        table.sort(result, comparator)
    else
        table.sort(result)
    
    return result

--- 分组表
--- @param tbl table 表
--- @param key_func function 键函数
--- @return table 分组后的表
function M.group_by(tbl, key_func)
    if type(tbl) ~= "table" then
        return {}
    
    if type(key_func) ~= "function" then
        return { tbl }
    
    local result = {}

    for _, v in ipairs(tbl) do
        local key = key_func(v)
        if not result[key] then
            result[key] = {}
        
        table.insert(result[key], v)
    
    return result

--- 查找元素
--- @param tbl table 表
--- @param predicate function 谓词函数
--- @return any 找到的元素
function M.find(tbl, predicate)
    if type(tbl) ~= "table" then
        return nil
    
    if type(predicate) ~= "function" then
        return nil
    
    for k, v in pairs(tbl) do
        if predicate(v, k) then
            return v, k
        
    
    return nil

--- 检查表是否包含值
--- @param tbl table 表
--- @param value any 值
--- @return boolean 是否包含
function M.contains(tbl, value)
    if type(tbl) ~= "table" then
        return false
    
    for _, v in pairs(tbl) do
        if v == value then
            return true
        
    
    return false

--- 检查表是否包含键
--- @param tbl table 表
--- @param key any 键
--- @return boolean 是否包含
function M.has_key(tbl, key)
    if type(tbl) ~= "table" then
        return false
    
    return tbl[key] ~= nil

--- 转换表为键值对列表
--- @param tbl table 表
--- @return table 键值对列表
function M.to_pairs(tbl)
    if type(tbl) ~= "table" then
        return {}
    
    local result = {}
    for k, v in pairs(tbl) do
        table.insert(result, { key = k, value = v })
    
    return result

--- 从键值对列表创建表
--- @param pairs table 键值对列表
--- @return table 表
function M.from_pairs(pairs)
    if type(pairs) ~= "table" then
        return {}
    
    local result = {}
    for _, pair in ipairs(pairs) do
        if type(pair) == "table" and pair.key ~= nil then
            result[pair.key] = pair.value
        
    
    return result

--- 深比较两个表
--- @param t1 table 表1
--- @param t2 table 表2
--- @return boolean 是否相等
function M.deep_equal(t1, t2)
    if type(t1) ~= type(t2) then
        return false
    
    if type(t1) ~= "table" then
        return t1 == t2
    
    -- 检查键的数量
    local t1_keys = M.keys(t1)
    local t2_keys = M.keys(t2)

    if #t1_keys ~= #t2_keys then
        return false
    
    -- 检查每个键值对
    for _, key in ipairs(t1_keys) do
        if not M.deep_equal(t1[key], t2[key]) then
            return false
        
    
    return true

--- 克隆表（浅拷贝）
--- @param tbl table 表
--- @return table 克隆的表
function M.clone(tbl)
    if type(tbl) ~= "table" then
        return {}
    
    local result = {}
    for k, v in pairs(tbl) do
        result[k] = v
    
    return result

--- 获取表的子集
--- @param tbl table 表
--- @param keys table 键列表
--- @return table 子集
function M.pick(tbl, keys)
    if type(tbl) ~= "table" then
        return {}
    
    if type(keys) ~= "table" then
        return {}
    
    local result = {}
    for _, key in ipairs(keys) do
        if tbl[key] ~= nil then
            result[key] = tbl[key]
        
    
    return result

--- 排除表的某些键
--- @param tbl table 表
--- @param keys table 要排除的键列表
--- @return table 排除后的表
function M.omit(tbl, keys)
    if type(tbl) ~= "table" then
        return {}
    
    if type(keys) ~= "table" then
        return tbl
    
    local key_set = {}
    for _, key in ipairs(keys) do
        key_set[key] = true
    
    local result = {}
    for k, v in pairs(tbl) do
        if not key_set[k] then
            result[k] = v
        
    
    return result

--- 检查表是否包含值（table_contains 是 contains 的别名）
--- @param tbl table 表
--- @param value any 值
--- @return boolean 是否包含
function M.table_contains(tbl, value)
    return M.contains(tbl, value)

--- 获取表的所有键（table_keys 是 keys 的别名）
--- @param tbl table 表
--- @return table 键列表
function M.table_keys(tbl)
    return M.keys(tbl)

--- 获取表的所有值（table_values 是 values 的别名）
--- @param tbl table 表
--- @return table 值列表
function M.table_values(tbl)
    return M.values(tbl)

--- 过滤表（table_filter 是 filter 的别名）
--- @param tbl table 表
--- @param predicate function 谓词函数
--- @return table 过滤后的表
function M.table_filter(tbl, predicate)
    return M.filter(tbl, predicate)

--- 映射表（table_map 是 map 的别名）
--- @param tbl table 表
--- @param func function 映射函数
--- @return table 映射后的表
function M.table_map(tbl, func)
    return M.map(tbl, func)

return M