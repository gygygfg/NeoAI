local M = {}

--- 获取日志工具
--- @return table 工具列表
function M.get_tools()
    return {
        {
            name = "log_message",
            description = "记录日志消息",
            func = M.log_message,
            parameters = {
                type = "object",
                properties = {
                    message = {
                        type = "string",
                        description = "日志消息"
                    },
                    level = {
                        type = "string",
                        description = "日志级别",
                        enum = { "info", "warn", "error", "debug" },
                        default = "info"
                    }
                },
                required = { "message" }
            },
            returns = {
                type = "boolean",
                description = "是否记录成功"
            },
            category = "log",
            permissions = {}
        },
        {
            name = "get_log_levels",
            description = "获取可用的日志级别",
            func = M.get_log_levels,
            parameters = {
                type = "object",
                properties = {}
            },
            returns = {
                type = "array",
                items = {
                    type = "string"
                },
                description = "日志级别列表"
            },
            category = "log",
            permissions = {}
        }
    }
end

--- 记录日志消息
--- @param args table 参数
--- @return boolean 是否成功
function M.log_message(args)
    if not args or not args.message then
        return false
    end

    local message = args.message
    local level = args.level or "info"

    -- 将日志级别转换为 vim.log.levels 常量
    local vim_level
    if level == "error" then
        vim_level = vim.log.levels.ERROR
    elseif level == "warn" then
        vim_level = vim.log.levels.WARN
    elseif level == "debug" then
        vim_level = vim.log.levels.DEBUG
    else
        vim_level = vim.log.levels.INFO
    end

    -- 记录日志
    vim.notify("[NeoAI Tool] " .. message, vim_level)
    return true
end

--- 获取日志级别
--- @param args table 参数
--- @return table 日志级别列表
function M.get_log_levels(args)
    return { "info", "warn", "error", "debug" }
end

return M