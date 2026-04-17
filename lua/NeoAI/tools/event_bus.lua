-- 事件总线模块
local M = {}

-- 模块状态
local state = {
    listeners = {},
    initialized = false
}

--- 初始化事件总线
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end
    
    state.config = config or {}
    state.listeners = {}
    state.initialized = true
end

--- 添加事件监听器
--- @param event string 事件名称
--- @param listener function 监听器函数
--- @return number 监听器ID
function M.add_listener(event, listener)
    if not state.listeners[event] then
        state.listeners[event] = {}
    end
    
    local listener_id = #state.listeners[event] + 1
    state.listeners[event][listener_id] = listener
    
    return listener_id
end

--- 移除事件监听器
--- @param event string 事件名称
--- @param listener_id number 监听器ID
--- @return boolean 是否移除成功
function M.remove_listener(event, listener_id)
    if not state.listeners[event] then
        return false
    end
    
    if state.listeners[event][listener_id] then
        state.listeners[event][listener_id] = nil
        
        -- 清理空的事件监听器数组
        local has_listeners = false
        for _, _ in pairs(state.listeners[event]) do
            has_listeners = true
            break
        end
        
        if not has_listeners then
            state.listeners[event] = nil
        end
        
        return true
    end
    
    return false
end

--- 触发事件
--- @param event string 事件名称
--- @param data any 事件数据
function M.emit(event, data)
    if not state.listeners[event] then
        return
    end
    
    for _, listener in pairs(state.listeners[event]) do
        local success, err = pcall(listener, data)
        if not success then
            print("事件监听器执行错误: " .. err)
        end
    end
end

--- 获取事件监听器数量
--- @param event string 事件名称
--- @return number 监听器数量
function M.get_listener_count(event)
    if not state.listeners[event] then
        return 0
    end
    
    local count = 0
    for _ in pairs(state.listeners[event]) do
        count = count + 1
    end
    
    return count
end

--- 清除所有事件监听器
function M.clear_all()
    state.listeners = {}
end

return M