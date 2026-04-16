local M = {}

-- 日志级别
local LOG_LEVELS = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    FATAL = 5
}

local LOG_LEVEL_NAMES = {
    [1] = "DEBUG",
    [2] = "INFO",
    [3] = "WARN",
    [4] = "ERROR",
    [5] = "FATAL"
}

-- 模块状态
local state = {
    initialized = false,
    level = LOG_LEVELS.INFO,
    output = nil, -- 文件句柄或函数
    output_path = nil,
    format = "[{time}] [{level}] {message}",
    max_file_size = 10485760, -- 10MB
    max_backups = 5
}

--- 初始化日志器
--- @param config table 配置
function M.initialize(config)
    if state.initialized then
        return
    end

    config = config or {}
    
    -- 设置日志级别
    if config.level then
        local level_name = config.level:upper()
        state.level = LOG_LEVELS[level_name] or LOG_LEVELS.INFO
    end

    -- 设置输出路径
    if config.output_path then
        M.set_output(config.output_path)
    end

    -- 设置格式
    if config.format then
        state.format = config.format
    end

    -- 设置文件大小限制
    if config.max_file_size then
        state.max_file_size = config.max_file_size
    end

    -- 设置备份数量
    if config.max_backups then
        state.max_backups = config.max_backups
    end

    state.initialized = true
end

--- 记录日志
--- @param level number 日志级别
--- @param message string 消息
--- @param ... any 额外参数
function M.log(level, message, ...)
    if not state.initialized then
        M.initialize()
    end

    -- 检查日志级别
    if level < state.level then
        return
    end

    -- 格式化消息
    if select("#", ...) > 0 then
        message = string.format(message, ...)
    end

    -- 构建日志条目
    local entry = M._format_entry(level, message)

    -- 输出日志
    M._write_entry(entry)
end

--- 设置日志级别
--- @param level string 日志级别 ('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')
function M.set_level(level)
    if not level then
        return
    end

    local level_name = level:upper()
    state.level = LOG_LEVELS[level_name] or LOG_LEVELS.INFO
end

--- 设置输出路径
--- @param path string 输出文件路径
function M.set_output(path)
    if not path then
        return
    end

    -- 关闭现有输出
    if state.output and state.output_path then
        M._close_output()
    end

    state.output_path = path

    -- 打开新输出文件
    local ok, file = pcall(io.open, path, "a")
    if ok and file then
        state.output = file
    else
        -- 如果无法打开文件，回退到标准输出
        state.output = nil
        state.output_path = nil
        M.error("无法打开日志文件: " .. path)
    end
end

--- 调试日志
--- @param message string 消息
--- @param ... any 额外参数
function M.debug(message, ...)
    M.log(LOG_LEVELS.DEBUG, message, ...)
end

--- 信息日志
--- @param message string 消息
--- @param ... any 额外参数
function M.info(message, ...)
    M.log(LOG_LEVELS.INFO, message, ...)
end

--- 警告日志
--- @param message string 消息
--- @param ... any 额外参数
function M.warn(message, ...)
    M.log(LOG_LEVELS.WARN, message, ...)
end

--- 错误日志
--- @param message string 消息
--- @param ... any 额外参数
function M.error(message, ...)
    M.log(LOG_LEVELS.ERROR, message, ...)
end

--- 致命错误日志
--- @param message string 消息
--- @param ... any 额外参数
function M.fatal(message, ...)
    M.log(LOG_LEVELS.FATAL, message, ...)
end

--- 获取当前日志级别
--- @return string 日志级别名称
function M.get_level()
    return LOG_LEVEL_NAMES[state.level] or "INFO"
end

--- 获取输出路径
--- @return string|nil 输出路径
function M.get_output_path()
    return state.output_path
end

--- 轮转日志文件
function M.rotate()
    if not state.output_path or not state.output then
        return
    end

    -- 检查文件大小
    local file = state.output
    local current_pos = file:seek("cur")
    local size = file:seek("end")
    file:seek("set", current_pos)

    if size < state.max_file_size then
        return
    end

    -- 关闭当前文件
    M._close_output()

    -- 轮转文件
    for i = state.max_backups - 1, 1, -1 do
        local old_name = state.output_path .. "." .. i
        local new_name = state.output_path .. "." .. (i + 1)
        
        if M._file_exists(old_name) then
            os.rename(old_name, new_name)
        end
    end

    -- 重命名当前文件
    if M._file_exists(state.output_path) then
        os.rename(state.output_path, state.output_path .. ".1")
    end

    -- 重新打开文件
    M.set_output(state.output_path)
end

--- 清空日志文件
function M.clear()
    if not state.output_path then
        return
    end

    -- 关闭现有输出
    if state.output then
        M._close_output()
    end

    -- 清空文件
    local file, err = io.open(state.output_path, "w")
    if file then
        file:close()
    end

    -- 重新打开文件
    M.set_output(state.output_path)
end

--- 格式化日志条目（内部使用）
--- @param level number 日志级别
--- @param message string 消息
--- @return string 格式化后的条目
function M._format_entry(level, message)
    local level_name = LOG_LEVEL_NAMES[level] or "UNKNOWN"
    local time_str = os.date("%Y-%m-%d %H:%M:%S")

    local entry = state.format
        :gsub("{time}", time_str)
        :gsub("{level}", level_name)
        :gsub("{message}", message)

    return entry
end

--- 写入日志条目（内部使用）
--- @param entry string 日志条目
function M._write_entry(entry)
    -- 输出到文件
    if state.output then
        state.output:write(entry .. "\n")
        state.output:flush()
    else
        -- 输出到标准输出
        local level = entry:match("%[([A-Z]+)%]")
        if level == "ERROR" or level == "FATAL" then
            vim.notify(entry, vim.log.levels.ERROR)
        elseif level == "WARN" then
            vim.notify(entry, vim.log.levels.WARN)
        else
            vim.notify(entry, vim.log.levels.INFO)
        end
    end
end

--- 关闭输出（内部使用）
function M._close_output()
    if state.output then
        state.output:close()
        state.output = nil
    end
end

--- 检查文件是否存在（内部使用）
--- @param path string 路径
--- @return boolean 是否存在
function M._file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

--- 设置自定义输出函数
--- @param output_func function 输出函数
function M.set_custom_output(output_func)
    if type(output_func) ~= "function" then
        return
    end

    -- 关闭现有输出
    if state.output then
        M._close_output()
    end

    state.output = output_func
    state.output_path = nil
end

--- 获取日志统计
--- @return table 统计信息
function M.get_stats()
    local stats = {
        level = M.get_level(),
        output_path = state.output_path,
        format = state.format,
        max_file_size = state.max_file_size,
        max_backups = state.max_backups
    }

    if state.output_path and M._file_exists(state.output_path) then
        local file = io.open(state.output_path, "r")
        if file then
            local size = file:seek("end")
            file:close()
            stats.file_size = size
            stats.needs_rotation = size >= state.max_file_size
        end
    end

    return stats
end

--- 创建子日志器
--- @param prefix string 前缀
--- @return table 子日志器
function M.create_child(prefix)
    local child = {}

    for level_name, level_num in pairs(LOG_LEVELS) do
        child[level_name:lower()] = function(message, ...)
            local full_message = "[" .. prefix .. "] " .. message
            M.log(level_num, full_message, ...)
        end
    end

    child.log = function(level, message, ...)
        local full_message = "[" .. prefix .. "] " .. message
        M.log(level, full_message, ...)
    end

    return child
end

--- 记录异常
--- @param err any 异常
--- @param context string 上下文信息
function M.exception(err, context)
    local err_msg
    if type(err) == "table" then
        err_msg = vim.inspect(err)
    else
        err_msg = tostring(err)
    end

    local message = context and (context .. ": " .. err_msg) or err_msg
    M.error(message)
    
    -- 记录堆栈跟踪
    local trace = debug.traceback()
    M.debug("堆栈跟踪:\n" .. trace)
end

-- 自动初始化
M.initialize()

return M