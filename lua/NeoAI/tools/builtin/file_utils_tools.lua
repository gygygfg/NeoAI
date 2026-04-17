local M = {}

--- 获取文件工具
--- @return table 工具列表
function M.get_tools()
    return {
        {
            name = "ensure_dir",
            description = "确保目录存在，如果不存在则创建",
            func = M.ensure_dir,
            parameters = {
                type = "object",
                properties = {
                    path = {
                        type = "string",
                        description = "目录路径"
                    },
                    parents = {
                        type = "boolean",
                        description = "是否创建父目录",
                        default = true
                    }
                },
                required = { "path" }
            },
            returns = {
                type = "boolean",
                description = "是否成功"
            },
            category = "file",
            permissions = {
                write = true
            }
        }
    }
end

--- 确保目录存在
--- @param args table 参数
--- @return boolean 是否成功
function M.ensure_dir(args)
    if not args or not args.path then
        return false
    end

    local path = args.path
    local parents = args.parents ~= false -- 默认为true

    -- 移除末尾的斜杠
    path = path:gsub("/+$", "")

    -- 检查目录是否已存在
    local cmd = '[ -d "' .. path .. '" ] && echo "exists"'
    local handle = io.popen(cmd)
    if handle then
        local result = handle:read("*a")
        handle:close()
        if result:find("exists") then
            return true
        end
    end

    -- 创建目录
    local mkdir_cmd
    if parents then
        mkdir_cmd = 'mkdir -p "' .. path .. '" 2>/dev/null'
    else
        mkdir_cmd = 'mkdir "' .. path .. '" 2>/dev/null'
    end

    local result = os.execute(mkdir_cmd)
    return result == 0 or result == true
end

return M