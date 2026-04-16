local M = {}

local tool_registry = require("NeoAI.tools.tool_registry")
local tool_validator = require("NeoAI.tools.tool_validator")

-- 模块状态
local state = {
    initialized = false,
    config = nil,
    execution_history = {},
    max_history_size = 100
}

--- 初始化工具执行器
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end

    state.config = config or {}
    state.max_history_size = config.max_history_size or 100
    state.execution_history = {}
    state.initialized = true
end

--- 执行工具
--- @param tool_name string 工具名称
--- @param args table 参数
--- @return any 执行结果
function M.execute(tool_name, args)
    if not state.initialized then
        error("Tool executor not initialized")
    end

    if not tool_name then
        error("Tool name is required")
    end

    -- 获取工具定义
    local tool = tool_registry.get(tool_name)
    if not tool then
        local error_msg = "工具不存在: " .. tool_name
        M._record_execution(tool_name, args, nil, error_msg)
        return error_msg
    end

    -- 验证参数
    local valid, error_msg = M.validate_args(tool, args)
    if not valid then
        M._record_execution(tool_name, args, nil, error_msg)
        return error_msg
    end

    -- 检查权限
    if tool.permissions then
        local has_permission, perm_error = tool_validator.check_permissions(tool)
        if not has_permission then
            M._record_execution(tool_name, args, nil, perm_error)
            return perm_error
        end
    end

    -- 执行工具
    local start_time = os.time()
    local success, result = pcall(tool.func, args)
    local end_time = os.time()
    local duration = end_time - start_time

    -- 处理执行结果
    if not success then
        local error_msg = "工具执行错误: " .. result
        M._record_execution(tool_name, args, nil, error_msg, duration)
        return M.handle_error(error_msg)
    end

    -- 格式化结果
    local formatted_result = M.format_result(result)

    -- 记录执行历史
    M._record_execution(tool_name, args, formatted_result, nil, duration)

    return formatted_result
end

--- 验证参数
--- @param tool table 工具定义
--- @param args table 参数
--- @return boolean, string 是否有效，错误信息
function M.validate_args(tool, args)
    if not tool then
        return false, "工具定义无效"
    end

    -- 如果没有参数定义，接受任何参数
    if not tool.parameters then
        return true, nil
    end

    -- 使用工具验证器验证参数
    return tool_validator.validate_parameters(tool.parameters, args)
end

--- 格式化结果
--- @param result any 原始结果
--- @return string 格式化后的结果
function M.format_result(result)
    if result == nil then
        return "null"
    end

    local result_type = type(result)

    if result_type == "string" then
        return result
    elseif result_type == "number" or result_type == "boolean" then
        return tostring(result)
    elseif result_type == "table" then
        -- 尝试转换为JSON
        local ok, json = pcall(vim.json.encode, result)
        if ok then
            return json
        else
            -- 如果无法转换为JSON，使用tostring
            return tostring(result)
        end
    else
        return tostring(result)
    end
end

--- 处理错误
--- @param error_msg string 错误信息
--- @return string 格式化后的错误信息
function M.handle_error(error_msg)
    -- 这里可以添加错误处理逻辑，如日志记录、重试等
    -- 目前只是返回错误信息
    return "错误: " .. error_msg
end

--- 清理资源
function M.cleanup()
    if not state.initialized then
        return
    end

    -- 清理执行历史
    if #state.execution_history > state.max_history_size then
        local excess = #state.execution_history - state.max_history_size
        for i = 1, excess do
            table.remove(state.execution_history, 1)
        end
    end
end

--- 获取执行历史
--- @param limit number 限制数量
--- @return table 执行历史
function M.get_execution_history(limit)
    if not state.initialized then
        error("Tool executor not initialized")
    end

    limit = limit or state.max_history_size
    local start_index = math.max(1, #state.execution_history - limit + 1)
    local result = {}

    for i = start_index, #state.execution_history do
        table.insert(result, vim.deepcopy(state.execution_history[i]))
    end

    return result
end

--- 清空执行历史
function M.clear_history()
    if not state.initialized then
        error("Tool executor not initialized")
    end

    state.execution_history = {}
end

--- 获取最近执行
--- @param tool_name string|nil 工具名称（可选）
--- @return table|nil 最近执行记录
function M.get_recent_execution(tool_name)
    if not state.initialized then
        error("Tool executor not initialized")
    end

    for i = #state.execution_history, 1, -1 do
        local record = state.execution_history[i]
        if not tool_name or record.tool_name == tool_name then
            return vim.deepcopy(record)
        end
    end

    return nil
end

--- 获取工具执行统计
--- @param tool_name string|nil 工具名称（可选）
--- @return table 执行统计
function M.get_execution_stats(tool_name)
    if not state.initialized then
        error("Tool executor not initialized")
    end

    local stats = {
        total_executions = 0,
        successful_executions = 0,
        failed_executions = 0,
        total_duration = 0,
        avg_duration = 0
    }

    for _, record in ipairs(state.execution_history) do
        if not tool_name or record.tool_name == tool_name then
            stats.total_executions = stats.total_executions + 1
            
            if record.success then
                stats.successful_executions = stats.successful_executions + 1
            else
                stats.failed_executions = stats.failed_executions + 1
            end
            
            if record.duration then
                stats.total_duration = stats.total_duration + record.duration
            end
        end
    end

    if stats.total_executions > 0 then
        stats.avg_duration = stats.total_duration / stats.total_executions
    end

    return stats
end

--- 记录执行（内部使用）
--- @param tool_name string 工具名称
--- @param args table 参数
--- @param result any 结果
--- @param error_msg string|nil 错误信息
--- @param duration number|nil 执行时长
function M._record_execution(tool_name, args, result, error_msg, duration)
    local record = {
        tool_name = tool_name,
        args = vim.deepcopy(args),
        result = result,
        error = error_msg,
        success = error_msg == nil,
        timestamp = os.time(),
        duration = duration or 0
    }

    table.insert(state.execution_history, record)

    -- 清理旧记录
    M.cleanup()
end

--- 批量执行工具
--- @param executions table 执行列表，格式为 {{tool_name, args}, ...}
--- @return table 执行结果列表
function M.batch_execute(executions)
    if not state.initialized then
        error("Tool executor not initialized")
    end

    local results = {}

    for _, exec in ipairs(executions) do
        local tool_name = exec[1]
        local args = exec[2] or {}
        
        local result = M.execute(tool_name, args)
        table.insert(results, {
            tool_name = tool_name,
            args = args,
            result = result
        })
    end

    return results
end

--- 异步执行工具
--- @param tool_name string 工具名称
--- @param args table 参数
--- @param callback function 回调函数
function M.execute_async(tool_name, args, callback)
    if not state.initialized then
        error("Tool executor not initialized")
    end

    if not callback or type(callback) ~= "function" then
        error("Callback function is required")
    end

    -- 在后台执行
    vim.schedule(function()
        local result = M.execute(tool_name, args)
        callback(result)
    end)
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
    if not state.initialized then
        return
    end

    state.config = vim.tbl_extend("force", state.config, new_config or {})
    state.max_history_size = state.config.max_history_size or state.max_history_size
end

return M