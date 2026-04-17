local M = {}

--- 获取通用工具
--- @return table 工具列表
function M.get_tools()
    return {
        {
            name = "merge_tables",
            description = "合并多个表格",
            func = M.merge_tables,
            parameters = {
                type = "object",
                properties = {
                    tables = {
                        type = "array",
                        items = {
                            type = "object"
                        },
                        description = "要合并的表格数组"
                    },
                    mode = {
                        type = "string",
                        description = "合并模式：force（覆盖）或 keep（保留）",
                        enum = { "force", "keep" },
                        default = "force"
                    }
                },
                required = { "tables" }
            },
            returns = {
                type = "object",
                description = "合并后的表格"
            },
            category = "general",
            permissions = {}
        },
        {
            name = "table_contains",
            description = "检查表格是否包含特定值",
            func = M.table_contains,
            parameters = {
                type = "object",
                properties = {
                    table = {
                        type = "object",
                        description = "要检查的表格"
                    },
                    value = {
                        type = "string",
                        description = "要查找的值"
                    }
                },
                required = { "table", "value" }
            },
            returns = {
                type = "boolean",
                description = "是否包含该值"
            },
            category = "general",
            permissions = {}
        },
        {
            name = "starts_with",
            description = "检查字符串是否以指定前缀开头",
            func = M.starts_with,
            parameters = {
                type = "object",
                properties = {
                    str = {
                        type = "string",
                        description = "要检查的字符串"
                    },
                    prefix = {
                        type = "string",
                        description = "前缀"
                    },
                    case_sensitive = {
                        type = "boolean",
                        description = "是否区分大小写",
                        default = true
                    }
                },
                required = { "str", "prefix" }
            },
            returns = {
                type = "boolean",
                description = "是否以指定前缀开头"
            },
            category = "text",
            permissions = {}
        }
    }
end

--- 合并表格
--- @param args table 参数
--- @return table 合并后的表格
function M.merge_tables(args)
    if not args or not args.tables then
        return {}
    end

    local tables = args.tables
    local mode = args.mode or "force"

    if #tables == 0 then
        return {}
    end

    local result = {}

    for i, tbl in ipairs(tables) do
        if type(tbl) == "table" then
            if mode == "force" then
                -- 覆盖模式：后面的表格覆盖前面的
                for k, v in pairs(tbl) do
                    result[k] = v
                end
            else
                -- 保留模式：只添加不存在的键
                for k, v in pairs(tbl) do
                    if result[k] == nil then
                        result[k] = v
                    end
                end
            end
        end
    end

    return result
end

--- 检查表格是否包含值
--- @param args table 参数
--- @return boolean 是否包含
function M.table_contains(args)
    if not args or not args.table or not args.value then
        return false
    end

    local tbl = args.table
    local value = args.value

    if type(tbl) ~= "table" then
        return false
    end

    -- 检查数组部分
    for _, v in ipairs(tbl) do
        if tostring(v) == tostring(value) then
            return true
        end
    end

    -- 检查字典部分
    for k, v in pairs(tbl) do
        if tostring(v) == tostring(value) then
            return true
        end
    end

    return false
end

--- 检查字符串是否以指定前缀开头
--- @param args table 参数
--- @return boolean 是否以指定前缀开头
function M.starts_with(args)
    if not args or not args.str or not args.prefix then
        return false
    end

    local str = args.str
    local prefix = args.prefix
    local case_sensitive = args.case_sensitive ~= false -- 默认为true

    if not case_sensitive then
        str = str:lower()
        prefix = prefix:lower()
    end

    return str:sub(1, #prefix) == prefix
end

return M