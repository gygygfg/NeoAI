local M = {}

--- 深拷贝表
--- @param tbl table 要拷贝的表
--- @return table 深拷贝后的表
function M.deep_copy(tbl)
    if type(tbl) ~= "table" then
        return tbl
    end

    local result = {}
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            result[k] = M.deep_copy(v)
        else
            result[k] = v
        end
    end

    return result
end

--- 深度合并表
--- @param t1 table 目标表
--- @param t2 table 源表
--- @return table 合并后的表
function M.deep_merge(t1, t2)
    if type(t1) ~= "table" or type(t2) ~= "table" then
        return t2 or t1
    end

    local result = M.deep_copy(t1)
    
    for k, v in pairs(t2) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = M.deep_merge(result[k], v)
        else
            result[k] = v
        end
    end

    return result
end

--- 安全调用函数
--- @param func function 要调用的函数
--- @param ... any 函数参数
--- @return any 函数返回值
function M.safe_call(func, ...)
    if type(func) ~= "function" then
        return nil, "不是函数"
    end

    local ok, result = pcall(func, ...)
    if ok then
        return result
    else
        return nil, result
    end
end

--- 防抖函数
--- @param func function 要防抖的函数
--- @param delay number 延迟时间（毫秒）
--- @return function 防抖后的函数
function M.debounce(func, delay)
    local timer = nil
    delay = delay or 300

    return function(...)
        local args = { ... }
        
        if timer then
            timer:close()
        end

        timer = vim.defer_fn(function()
            func(unpack(args))
        end, delay)
    end
end

--- 节流函数
--- @param func function 要节流的函数
--- @param limit number 限制时间（毫秒）
--- @return function 节流后的函数
function M.throttle(func, limit)
    local last_call = 0
    local timer = nil
    limit = limit or 300

    return function(...)
        local now = vim.loop.now()
        local args = { ... }

        if now - last_call >= limit then
            last_call = now
            return func(unpack(args))
        else
            -- 如果已经有定时器，取消它
            if timer then
                timer:close()
            end

            -- 设置新的定时器
            timer = vim.defer_fn(function()
                last_call = vim.loop.now()
                func(unpack(args))
            end, limit - (now - last_call))
        end
    end
end

--- 生成唯一ID
--- @param prefix string 前缀
--- @return string 唯一ID
function M.unique_id(prefix)
    prefix = prefix or "id"
    local time = os.time()
    local random = math.random(1000, 9999)
    return string.format("%s_%d_%d", prefix, time, random)
end

--- 检查值是否为空
--- @param value any 要检查的值
--- @return boolean 是否为空
function M.is_empty(value)
    if value == nil then
        return true
    end

    if type(value) == "string" then
        return value == ""
    end

    if type(value) == "table" then
        return next(value) == nil
    end

    return false
end

--- 默认值
--- @param value any 值
--- @param default any 默认值
--- @return any 值或默认值
function M.default(value, default)
    if value == nil or (type(value) == "string" and value == "") then
        return default
    end
    return value
end

--- 等待一段时间
--- @param ms number 毫秒数
function M.sleep(ms)
    local start = vim.loop.now()
    while vim.loop.now() - start < ms do
        -- 空循环
    end
end

--- 异步等待
--- @param ms number 毫秒数
--- @param callback function 回调函数
function M.sleep_async(ms, callback)
    vim.defer_fn(callback, ms)
end

--- 重试函数
--- @param func function 要重试的函数
--- @param max_attempts number 最大尝试次数
--- @param delay number 重试延迟（毫秒）
--- @return any 函数返回值
function M.retry(func, max_attempts, delay)
    max_attempts = max_attempts or 3
    delay = delay or 1000

    local last_error = nil

    for attempt = 1, max_attempts do
        local ok, result = pcall(func)
        if ok then
            return result
        else
            last_error = result
            if attempt < max_attempts then
                M.sleep(delay)
            end
        end
    end

    error("重试失败: " .. tostring(last_error))
end

--- 测量函数执行时间
--- @param func function 要测量的函数
--- @param ... any 函数参数
--- @return any, number 函数返回值和执行时间（毫秒）
function M.measure_time(func, ...)
    local start_time = vim.loop.hrtime()
    local result = { pcall(func, ...) }
    local end_time = vim.loop.hrtime()
    
    local duration_ms = (end_time - start_time) / 1000000
    
    if result[1] then
        return unpack(result, 2), duration_ms
    else
        error(result[2])
    end
end

--- 创建缓存函数
--- @param func function 要缓存的函数
--- @param ttl number 缓存时间（秒）
--- @return function 缓存函数
function M.cache(func, ttl)
    local cache = {}
    ttl = ttl or 300 -- 默认5分钟

    return function(...)
        local key = vim.json.encode({ ... })
        local cached = cache[key]

        if cached and os.time() - cached.timestamp < ttl then
            return cached.value
        end

        local value = func(...)
        cache[key] = {
            value = value,
            timestamp = os.time()
        }

        return value
    end
end

--- 清空缓存
--- @param cache_func function 缓存函数
function M.clear_cache(cache_func)
    -- 这个函数需要缓存函数有特定的实现
    -- 目前是占位符
end

--- 生成随机字符串
--- @param length number 长度
--- @return string 随机字符串
function M.random_string(length)
    length = length or 8
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local result = ""
    
    for i = 1, length do
        local rand = math.random(1, #chars)
        result = result .. chars:sub(rand, rand)
    end
    
    return result
end

--- 检查类型
--- @param value any 值
--- @param expected_type string 期望的类型
--- @return boolean 类型是否匹配
function M.check_type(value, expected_type)
    local actual_type = type(value)
    
    if expected_type == "array" then
        return actual_type == "table" and #value > 0
    elseif expected_type == "object" then
        return actual_type == "table" and not (#value > 0)
    else
        return actual_type == expected_type
    end
end

return M