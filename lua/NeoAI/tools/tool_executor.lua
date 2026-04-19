local M = {}

local tool_registry = require("NeoAI.tools.tool_registry")
local tool_validator = require("NeoAI.tools.tool_validator")

-- 检查 vim 模块是否可用，如果不可用则使用简单的深拷贝函数
local function deep_copy(obj, seen)
    if type(obj) ~= "table" then return obj 
    if seen and seen[obj] then return seen[obj] 
    local s = seen or {}
    local res = {}
    s[obj] = res
    
    for k, v in pairs(obj) do
        res[deep_copy(k, s)] = deep_copy(v, s)
    
    return setmetatable(res, getmetatable(obj))

-- 使用 vim.deepcopy 如果可用，否则使用自定义的深拷贝函数
local vim_deepcopy = vim and vim.deepcopy or deep_copy

-- 跨平台睡眠函数
local function sleep(seconds)
    if package.config:sub(1,1) == "\\" then
        -- Windows
        os.execute("timeout /T " .. seconds .. " /NOBREAK > NUL 2>&1")
    else
        -- Unix/Linux/Mac
        os.execute("sleep " .. seconds)
    

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
    
    state.config = config or {}
    state.max_history_size = config.max_history_size or 100
    state.execution_history = {}
    state.initialized = true

--- 执行工具
--- @param tool_name string 工具名称
--- @param args table 参数
--- @return any 执行结果
function M.execute(tool_name, args)
    if not state.initialized then
        error("Tool executor not initialized")
    
    if not tool_name then
        error("Tool name is required")
    
    -- 获取工具定义
    local tool = tool_registry.get(tool_name)
    if not tool then
        local error_msg = "工具不存在: " .. tool_name
        M._record_execution(tool_name, args, nil, error_msg)
        return error_msg
    
    -- 验证参数
    local valid, error_msg = M.validate_args(tool, args)
    if not valid then
        M._record_execution(tool_name, args, nil, error_msg)
        return error_msg
    
    -- 检查权限
    if tool.permissions then
        local has_permission, perm_error = tool_validator.check_permissions(tool)
        if not has_permission then
            M._record_execution(tool_name, args, nil, perm_error)
            return perm_error
        
    
    -- 执行工具（使用安全调用）
    local start_time = os.time()
    
    -- 触发工具执行开始事件
    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:tool_execution_started",
        data = {tool_name, args, start_time}
    })
    
    -- 从配置获取重试参数
    local max_retries = state.config.max_retries or 0
    local retry_delay = state.config.retry_delay or 1
    
    local result, error_msg = M.safe_call(tool.func, args, max_retries, retry_delay)
    local end_time = os.time()
    local duration = end_time - start_time
    
    -- 触发工具执行完成事件
    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:tool_execution_completed",
        data = {tool_name, args, result, duration}
    })

    -- 处理执行结果
    if error_msg then
        local full_error_msg = "工具执行错误: " .. error_msg
        
        -- 触发工具执行错误事件
        vim.api.nvim_exec_autocmds("User", {
            pattern = "NeoAI:tool_execution_error",
            data = {tool_name, args, full_error_msg, duration}
        })
        
        M._record_execution(tool_name, args, nil, full_error_msg, duration)
        return M.handle_error(full_error_msg)
    
    -- 格式化结果
    local formatted_result = M.format_result(result)

    -- 记录执行历史
    M._record_execution(tool_name, args, formatted_result, nil, duration)

    return formatted_result

--- 执行工具（别名，用于兼容性）
--- @param tool_name string 工具名称
--- @param args table 参数
--- @return any 执行结果
function M.execute_tool(tool_name, args)
    return M.execute(tool_name, args)

--- 验证参数
--- @param tool table 工具定义
--- @param args table 参数
--- @return boolean, string 是否有效，错误信息
function M.validate_args(tool, args)
    if not tool then
        return false, "工具定义无效"
    
    -- 如果没有参数定义，接受任何参数
    if not tool.parameters then
        return true, nil
    
    -- 使用工具验证器验证参数
    return tool_validator.validate_parameters(tool.parameters, args)

--- 格式化结果
--- @param result any 原始结果
--- @return string 格式化后的结果
function M.format_result(result)
    if result == nil then
        return "null"
    
    local result_type = type(result)

    if result_type == "string" then
        return result
    elseif result_type == "number" or result_type == "boolean" then
        return tostring(result)
    elseif result_type == "table" then
        -- 尝试转换为JSON
        local json_encode = vim and vim.json and vim.json.encode
        if json_encode then
            local ok, json = pcall(json_encode, result)
            if ok then
                return json
            
        
        -- 如果无法转换为JSON，使用简单的表格表示
        return M._table_to_string(result)
    else
        return tostring(result)
    

--- 将表格转换为字符串（内部使用）
--- @param tbl table 表格
--- @return string 字符串表示
function M._table_to_string(tbl)
    local result = {"{"}
    for k, v in pairs(tbl) do
        local key_str = type(k) == "string" and "\"" .. k .. "\"" or tostring(k)
        local value_str
        
        if type(v) == "table" then
            value_str = M._table_to_string(v)
        elseif type(v) == "string" then
            value_str = "\"" .. v .. "\""
        else
            value_str = tostring(v)
        
        table.insert(result, "  " .. key_str .. ": " .. value_str)
    
    table.insert(result, "}")
    return table.concat(result, "\n")

--- 处理错误
--- @param error_msg string 错误信息
--- @return string 格式化后的错误信息
function M.handle_error(error_msg)
    -- 分析错误类型
    local error_type = "未知错误"
    
    if string.find(error_msg, "参数") then
        error_type = "参数错误"
    elseif string.find(error_msg, "权限") then
        error_type = "权限错误"
    elseif string.find(error_msg, "不存在") or string.find(error_msg, "未找到") then
        error_type = "资源不存在错误"
    elseif string.find(error_msg, "超时") then
        error_type = "超时错误"
    elseif string.find(error_msg, "网络") then
        error_type = "网络错误"
    elseif string.find(error_msg, "内存") then
        error_type = "内存错误"
    
    -- 构建详细的错误信息
    local detailed_error = string.format(
        "[%s] %s\n时间: %s",
        error_type,
        error_msg,
        os.date("%Y-%m-%d %H:%M:%S")
    )
    
    -- 记录到日志（如果配置了日志）
    if state.config and state.config.log_errors then
        M._log_error(detailed_error)
    
    return detailed_error

--- 记录错误日志
--- @param error_msg string 错误信息
function M._log_error(error_msg)
    -- 简单的日志记录实现
    -- 在实际项目中，可以集成到现有的日志系统中
    local log_file = state.config.error_log_file or vim.fn.stdpath("cache") .. "/neoai_tools_error.log"
    
    local file = io.open(log_file, "a")
    if file then
        file:write(error_msg .. "\n\n")
        file:close()
    

--- 安全调用函数
--- @param func function 要调用的函数
--- @param args table 函数参数
--- @param max_retries number 最大重试次数
--- @param retry_delay number 重试延迟（秒）
--- @return any, string 执行结果，错误信息
function M.safe_call(func, args, max_retries, retry_delay)
    if not func then
        return nil, "函数不能为空"
    
    max_retries = max_retries or 0
    retry_delay = retry_delay or 1
    
    local last_error = nil
    
    for attempt = 0, max_retries do
        if attempt > 0 then
            -- 重试前等待
            sleep(retry_delay)
            
            -- 记录重试信息
            M._record_execution("safe_call", args, nil, "重试尝试: " .. attempt, 0)
        
        local start_time = os.time()
        local success, result = pcall(func, args)
        local end_time = os.time()
        local duration = end_time - start_time
        
        if success then
            -- 成功执行
            if attempt > 0 then
                M._record_execution("safe_call", args, "重试成功", nil, duration)
            
            return result, nil
        else
            -- 执行失败
            last_error = result
            M._record_execution("safe_call", args, nil, "执行失败: " .. result, duration)
            
            -- 检查是否应该重试
            if attempt < max_retries then
                -- 分析错误类型，决定是否重试
                local should_retry = M._should_retry_error(result)
                if not should_retry then
                    break
                
            
        
    
    return nil, "安全调用失败: " .. (last_error or "未知错误")

--- 判断错误是否应该重试
--- @param error_msg string 错误信息
--- @return boolean 是否应该重试
function M._should_retry_error(error_msg)
    -- 默认重试所有错误
    -- 可以在这里添加逻辑来过滤不应该重试的错误
    
    -- 不应该重试的错误示例：
    -- 1. 参数验证错误
    -- 2. 权限错误
    -- 3. 资源不存在错误
    
    local non_retryable_errors = {
        "参数",
        "权限",
        "不存在",
        "无效",
        "未找到",
        "未初始化"
    }
    
    for _, error_pattern in ipairs(non_retryable_errors) do
        if string.find(error_msg, error_pattern) then
            return false
        
    
    return true

--- 清理资源
function M.cleanup()
    if not state.initialized then
        return
    
    -- 清理执行历史
    if #state.execution_history > state.max_history_size then
        local excess = #state.execution_history - state.max_history_size
        for i = 1, excess do
            table.remove(state.execution_history, 1)
        
    

--- 获取执行历史
--- @param limit number 限制数量
--- @return table 执行历史
function M.get_execution_history(limit)
    if not state.initialized then
        error("Tool executor not initialized")
    
    limit = limit or state.max_history_size
    local start_index = math.max(1, #state.execution_history - limit + 1)
    local result = {}

    for i = start_index, #state.execution_history do
        table.insert(result, vim.deepcopy(state.execution_history[i]))
    
    return result

--- 清空执行历史
function M.clear_history()
    if not state.initialized then
        error("Tool executor not initialized")
    
    state.execution_history = {}

--- 获取最近执行
--- @param tool_name string|nil 工具名称（可选）
--- @return table|nil 最近执行记录
function M.get_recent_execution(tool_name)
    if not state.initialized then
        error("Tool executor not initialized")
    
    for i = #state.execution_history, 1, -1 do
        local record = state.execution_history[i]
        if not tool_name or record.tool_name == tool_name then
            return vim.deepcopy(record)
        
    
    return nil

--- 获取工具执行统计
--- @param tool_name string|nil 工具名称（可选）
--- @return table 执行统计
function M.get_execution_stats(tool_name)
    if not state.initialized then
        error("Tool executor not initialized")
    
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
            
            if record.duration then
                stats.total_duration = stats.total_duration + record.duration
            
        
    
    if stats.total_executions > 0 then
        stats.avg_duration = stats.total_duration / stats.total_executions
    
    return stats

--- 记录执行（内部使用）
--- @param tool_name string 工具名称
--- @param args table 参数
--- @param result any 结果
--- @param error_msg string|nil 错误信息
--- @param duration number|nil 执行时长
function M._record_execution(tool_name, args, result, error_msg, duration)
    local record = {
        tool_name = tool_name,
        args = vim_deepcopy(args),
        result = result,
        error = error_msg,
        success = error_msg == nil,
        timestamp = os.time(),
        duration = duration or 0
    }

    table.insert(state.execution_history, record)

    -- 清理旧记录
    M.cleanup()

--- 批量执行工具
--- @param executions table 执行列表，格式为 {{tool_name, args}, ...}
--- @return table 执行结果列表
function M.batch_execute(executions)
    if not state.initialized then
        error("Tool executor not initialized")
    
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
    
    return results

--- 异步执行工具
--- @param tool_name string 工具名称
--- @param args table 参数
--- @param callback function 回调函数
function M.execute_async(tool_name, args, callback)
    if not state.initialized then
        error("Tool executor not initialized")
    
    if not callback or type(callback) ~= "function" then
        error("Callback function is required")
    
    -- 在后台执行
    vim.schedule(function()
        local result = M.execute(tool_name, args)
        callback(result)
    end)

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
    if not state.initialized then
        return
    
    state.config = vim.tbl_extend("force", state.config, new_config or {})
    state.max_history_size = state.config.max_history_size or state.max_history_size

return M