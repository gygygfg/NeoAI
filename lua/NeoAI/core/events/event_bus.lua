local M = {}

-- 事件监听器存储
local listeners = {}

--- 监听事件
--- @param event string 事件名称
--- @param callback function 回调函数
--- @return function 取消监听函数
function M.on(event, callback)
    if not event or type(event) ~= "string" then
        error("Event name must be a string")
    end

    if not callback or type(callback) ~= "function" then
        error("Callback must be a function")
    end

    -- 初始化事件监听器列表
    if not listeners[event] then
        listeners[event] = {}
    end

    -- 添加监听器
    table.insert(listeners[event], callback)

    -- 返回取消监听函数
    return function()
        M.off(event, callback)
    end
end

--- 触发事件
--- @param event string 事件名称
--- @param ... any 事件参数
function M.emit(event, ...)
    if not event or type(event) ~= "string" then
        error("Event name must be a string")
    end

    -- 获取事件监听器
    local event_listeners = listeners[event]
    if not event_listeners or #event_listeners == 0 then
        return
    end

    -- 调用所有监听器
    for _, callback in ipairs(event_listeners) do
        local ok, err = pcall(callback, ...)
        if not ok then
            vim.notify(string.format("Event handler error for '%s': %s", event, err), vim.log.levels.ERROR)
        end
    end
end

--- 取消监听事件
--- @param event string 事件名称
--- @param callback function 回调函数
function M.off(event, callback)
    if not event or not listeners[event] then
        return
    end

    if not callback then
        -- 如果没有指定回调，清除所有监听器
        listeners[event] = nil
        return
    end

    -- 移除指定的监听器
    local event_listeners = listeners[event]
    for i, cb in ipairs(event_listeners) do
        if cb == callback then
            table.remove(event_listeners, i)
            break
        end
    end

    -- 如果监听器列表为空，删除事件
    if #event_listeners == 0 then
        listeners[event] = nil
    end
end

--- 清除事件的所有监听器
--- @param event string 事件名称
function M.clear_listeners(event)
    if not event then
        -- 清除所有事件
        listeners = {}
    else
        listeners[event] = nil
    end
end

--- 获取事件监听器数量
--- @param event string 事件名称
--- @return number 监听器数量
function M.listener_count(event)
    if not event then
        local total = 0
        for _, event_listeners in pairs(listeners) do
            total = total + #event_listeners
        end
        return total
    end

    local event_listeners = listeners[event]
    return event_listeners and #event_listeners or 0
end

--- 获取所有事件名称
--- @return table 事件名称列表
function M.get_event_names()
    local names = {}
    for event, _ in pairs(listeners) do
        table.insert(names, event)
    end
    table.sort(names)
    return names
end

--- 一次性监听器（只触发一次）
--- @param event string 事件名称
--- @param callback function 回调函数
--- @return function 取消监听函数
function M.once(event, callback)
    if not event or not callback then
        error("Event and callback are required")
    end

    local wrapped_callback = function(...)
        -- 先取消监听
        M.off(event, wrapped_callback)
        -- 再调用回调
        callback(...)
    end

    return M.on(event, wrapped_callback)
end

--- 等待事件
--- @param event string 事件名称
--- @param timeout number 超时时间（毫秒）
--- @return table|nil 事件参数
function M.wait_for(event, timeout)
    timeout = timeout or 5000 -- 默认5秒

    local event_fired = false
    local event_args = {}

    local unsubscribe = M.once(event, function(...)
        event_fired = true
        event_args = { ... }
    end)

    -- 等待事件或超时
    local start_time = vim.loop.now()
    while not event_fired and (vim.loop.now() - start_time) < timeout do
        vim.wait(10) -- 每10毫秒检查一次
    end

    -- 取消监听（如果还没触发）
    unsubscribe()

    if event_fired then
        return unpack(event_args)
    end

    return nil
end

--- 批量监听事件
--- @param events table 事件列表，格式为 {event1 = callback1, event2 = callback2, ...}
--- @return table 取消监听函数列表
function M.on_many(events)
    if type(events) ~= "table" then
        error("Events must be a table")
    end

    local unsubscribers = {}

    for event, callback in pairs(events) do
        if type(event) == "string" and type(callback) == "function" then
            local unsubscribe = M.on(event, callback)
            table.insert(unsubscribers, unsubscribe)
        end
    end

    -- 返回批量取消函数
    return function()
        for _, unsubscribe in ipairs(unsubscribers) do
            unsubscribe()
        end
    end
end

--- 触发事件并等待所有监听器完成
--- @param event string 事件名称
--- @param ... any 事件参数
function M.emit_and_wait(event, ...)
    if not event then
        return
    end

    local event_listeners = listeners[event]
    if not event_listeners or #event_listeners == 0 then
        return
    end

    -- 收集所有监听器的结果
    local results = {}

    for i, callback in ipairs(event_listeners) do
        local ok, result = pcall(callback, ...)
        if ok then
            results[i] = result
        else
            results[i] = { error = result }
            vim.notify(string.format("Event handler error for '%s': %s", event, result), vim.log.levels.ERROR)
        end
    end

    return results
end

return M