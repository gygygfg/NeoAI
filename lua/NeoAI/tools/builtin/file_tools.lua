local M = {}

local file_utils = require("NeoAI.utils.file_utils")

--- 获取内置文件工具
--- @return table 工具列表
function M.get_tools()
    return {
        {
            name = "read_file",
            description = "读取文件内容",
            func = M.read_file,
            parameters = {
                type = "object",
                properties = {
                    path = {
                        type = "string",
                        description = "文件路径"
                    }
                },
                required = { "path" }
            },
            returns = {
                type = "string",
                description = "文件内容"
            },
            category = "file",
            permissions = {
                read = true
            }
        },
        {
            name = "write_file",
            description = "写入文件内容",
            func = M.write_file,
            parameters = {
                type = "object",
                properties = {
                    path = {
                        type = "string",
                        description = "文件路径"
                    },
                    content = {
                        type = "string",
                        description = "要写入的内容"
                    },
                    append = {
                        type = "boolean",
                        description = "是否追加模式",
                        default = false
                    }
                },
                required = { "path", "content" }
            },
            returns = {
                type = "boolean",
                description = "是否写入成功"
            },
            category = "file",
            permissions = {
                write = true
            }
        },
        {
            name = "list_files",
            description = "列出目录中的文件",
            func = M.list_files,
            parameters = {
                type = "object",
                properties = {
                    dir = {
                        type = "string",
                        description = "目录路径",
                        default = "."
                    },
                    pattern = {
                        type = "string",
                        description = "文件模式（如 *.lua）",
                        default = "*"
                    },
                    recursive = {
                        type = "boolean",
                        description = "是否递归查找",
                        default = false
                    }
                }
            },
            returns = {
                type = "array",
                items = {
                    type = "string"
                },
                description = "文件路径列表"
            },
            category = "file",
            permissions = {
                read = true
            }
        },
        {
            name = "search_files",
            description = "搜索文件内容",
            func = M.search_files,
            parameters = {
                type = "object",
                properties = {
                    pattern = {
                        type = "string",
                        description = "搜索模式"
                    },
                    dir = {
                        type = "string",
                        description = "搜索目录",
                        default = "."
                    },
                    file_pattern = {
                        type = "string",
                        description = "文件模式（如 *.lua）",
                        default = "*"
                    },
                    case_sensitive = {
                        type = "boolean",
                        description = "是否区分大小写",
                        default = false
                    }
                },
                required = { "pattern" }
            },
            returns = {
                type = "array",
                items = {
                    type = "object",
                    properties = {
                        file = { type = "string" },
                        line = { type = "number" },
                        content = { type = "string" }
                    }
                },
                description = "匹配结果列表"
            },
            category = "file",
            permissions = {
                read = true
            }
        },
        {
            name = "file_exists",
            description = "检查文件或目录是否存在",
            func = M.file_exists,
            parameters = {
                type = "object",
                properties = {
                    path = {
                        type = "string",
                        description = "路径"
                    }
                },
                required = { "path" }
            },
            returns = {
                type = "boolean",
                description = "是否存在"
            },
            category = "file",
            permissions = {
                read = true
            }
        },
        {
            name = "create_directory",
            description = "创建目录",
            func = M.create_directory,
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
                description = "是否创建成功"
            },
            category = "file",
            permissions = {
                write = true
            }
        }
    }
end

--- 读取文件
--- @param args table 参数
--- @return string 文件内容
function M.read_file(args)
    if not args or not args.path then
        return "错误: 需要文件路径"
    end

    local path = args.path
    local content, error_msg = file_utils.read_file(path)

    if content then
        return content
    else
        return "错误: " .. (error_msg or "无法读取文件")
    end
end

--- 写入文件
--- @param args table 参数
--- @return boolean 是否成功
function M.write_file(args)
    if not args or not args.path or not args.content then
        return false
    end

    local path = args.path
    local content = args.content
    local append = args.append or false

    local success, error_msg = file_utils.write_file(path, content, append)

    if success then
        return true
    else
        -- 返回错误信息作为字符串
        error("写入失败: " .. (error_msg or "未知错误"))
    end
end

--- 列出文件
--- @param args table 参数
--- @return table 文件列表
function M.list_files(args)
    local dir = args.dir or "."
    local pattern = args.pattern or "*"
    local recursive = args.recursive or false

    -- 构建查找模式
    local search_pattern
    if recursive then
        search_pattern = dir .. "/**/" .. pattern
    else
        search_pattern = dir .. "/" .. pattern
    end

    -- 获取文件列表
    local files = {}
    local handle = io.popen('find "' .. dir .. '" -name "' .. pattern .. '" -type f 2>/dev/null | head -100')
    if handle then
        for line in handle:lines() do
            table.insert(files, line)
        end
        handle:close()
    end

    return files
end

--- 搜索文件内容
--- @param args table 参数
--- @return table 搜索结果
function M.search_files(args)
    if not args or not args.pattern then
        return {}
    end

    local pattern = args.pattern
    local dir = args.dir or "."
    local file_pattern = args.file_pattern or "*"
    local case_sensitive = args.case_sensitive or false

    local results = {}

    -- 构建grep命令
    local grep_cmd = "grep -n"
    if not case_sensitive then
        grep_cmd = grep_cmd .. " -i"
    end
    grep_cmd = grep_cmd .. " -- '" .. pattern:gsub("'", "'\"'\"'") .. "' "
    
    -- 查找文件并搜索
    local find_cmd = 'find "' .. dir .. '" -type f -name "' .. file_pattern .. '" 2>/dev/null | head -50'
    local handle = io.popen(find_cmd)
    
    if handle then
        for file in handle:lines() do
            local search_handle = io.popen(grep_cmd .. '"' .. file .. '" 2>/dev/null')
            if search_handle then
                for line in search_handle:lines() do
                    local line_num, content = line:match("^(%d+):(.+)$")
                    if line_num and content then
                        table.insert(results, {
                            file = file,
                            line = tonumber(line_num),
                            content = content
                        })
                    end
                end
                search_handle:close()
            end
        end
        handle:close()
    end

    return results
end

--- 检查文件是否存在
--- @param args table 参数
--- @return boolean 是否存在
function M.file_exists(args)
    if not args or not args.path then
        return false
    end

    return file_utils.exists(args.path)
end

--- 创建目录
--- @param args table 参数
--- @return boolean 是否成功
function M.create_directory(args)
    if not args or not args.path then
        return false
    end

    local path = args.path
    local parents = args.parents ~= false -- 默认为true

    if parents then
        -- 创建父目录
        local success, error_msg = file_utils.mkdir(path)
        return success
    else
        -- 只创建最后一级目录
        local cmd = 'mkdir "' .. path .. '" 2>/dev/null'
        local result = os.execute(cmd)
        return result == 0 or result == true
    end
end

return M