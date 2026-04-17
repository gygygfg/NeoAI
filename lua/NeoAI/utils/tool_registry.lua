local M = {}

--- 注册文件工具
--- @return table 工具列表
function M.register_file_tools()
    local file_utils = require("NeoAI.utils.file_utils")
    
    local tools = {
        {
            name = "read_file",
            description = "读取文件内容",
            func = function(params)
                if not params or not params.path then
                    return nil, "缺少文件路径参数"
                end
                return file_utils.read_file(params.path)
            end
        },
        {
            name = "write_file",
            description = "写入文件内容",
            func = function(params)
                if not params or not params.path then
                    return nil, "缺少文件路径参数"
                end
                if params.content == nil then
                    return nil, "缺少内容参数"
                end
                return file_utils.write_file(params.path, params.content, params.append)
            end
        },
        {
            name = "list_files",
            description = "列出目录中的文件",
            func = function(params)
                if not params or not params.dir then
                    return nil, "缺少目录路径参数"
                end
                return file_utils.list_files(params.dir, params.pattern)
            end
        },
        {
            name = "search_files",
            description = "搜索文件",
            func = function(params)
                if not params or not params.dir then
                    return nil, "缺少目录路径参数"
                end
                return file_utils.search_files(params.dir, params.pattern, params.recursive)
            end
        },
        {
            name = "file_exists",
            description = "检查文件是否存在",
            func = function(params)
                if not params or not params.path then
                    return nil, "缺少路径参数"
                end
                return file_utils.file_exists(params.path)
            end
        },
        {
            name = "create_directory",
            description = "创建目录",
            func = function(params)
                if not params or not params.dir then
                    return nil, "缺少目录路径参数"
                end
                return file_utils.create_directory(params.dir)
            end
        }
    }
    
    return tools
end

--- 获取所有工具
--- @return table 工具列表
function M.get_all_tools()
    local all_tools = {}
    
    -- 添加文件工具
    local file_tools = M.register_file_tools()
    for _, tool in ipairs(file_tools) do
        table.insert(all_tools, tool)
    end
    
    return all_tools
end

--- 按名称获取工具
--- @param tool_name string 工具名称
--- @return table|nil 工具定义
function M.get_tool(tool_name)
    local tools = M.get_all_tools()
    for _, tool in ipairs(tools) do
        if tool.name == tool_name then
            return tool
        end
    end
    return nil
end

--- 检查工具是否存在
--- @param tool_name string 工具名称
--- @return boolean 是否存在
function M.has_tool(tool_name)
    return M.get_tool(tool_name) ~= nil
end

--- 执行工具
--- @param tool_name string 工具名称
--- @param params table 参数
--- @return any 执行结果
function M.execute_tool(tool_name, params)
    local tool = M.get_tool(tool_name)
    if not tool then
        return nil, "工具不存在: " .. tool_name
    end
    
    return tool.func(params)
end

return M