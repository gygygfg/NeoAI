local M = {}

--- 注册文件工具
--- @return table 工具列表
function M.register_file_tools()
    local ok, file_utils = pcall(require, "NeoAI.utils.file_utils")
    if not ok then
        vim.notify("无法加载 file_utils 模块: " .. (file_utils or "未知错误"), vim.log.levels.ERROR)
        return {}
    
    local tools = {
        {
            name = "read_file",
            description = "读取文件内容",
            func = function(params)
                if not params or not params.path then
                    return nil, "缺少文件路径参数"
                
                return file_utils.read_file(params.path)
            
        },
        {
            name = "write_file",
            description = "写入文件内容",
            func = function(params)
                if not params or not params.path then
                    return nil, "缺少文件路径参数"
                
                if params.content == nil then
                    return nil, "缺少内容参数"
                
                return file_utils.write_file(params.path, params.content, params.append)
            
        },
        {
            name = "list_files",
            description = "列出目录中的文件",
            func = function(params)
                if not params or not params.dir then
                    return nil, "缺少目录路径参数"
                
                return file_utils.list_files(params.dir, params.pattern)
            
        },
        {
            name = "search_files",
            description = "搜索文件",
            func = function(params)
                if not params or not params.dir then
                    return nil, "缺少目录路径参数"
                
                return file_utils.search_files(params.dir, params.pattern, params.recursive)
            
        },
        {
            name = "file_exists",
            description = "检查文件是否存在",
            func = function(params)
                if not params or not params.path then
                    return nil, "缺少路径参数"
                
                return file_utils.file_exists(params.path)
            
        },
        {
            name = "create_directory",
            description = "创建目录",
            func = function(params)
                if not params or not params.dir then
                    return nil, "缺少目录路径参数"
                
                return file_utils.create_directory(params.dir)
            
        }
    }
    
    return tools

--- 获取所有工具
--- @return table 工具列表
function M.get_all_tools()
    local all_tools = {}
    
    -- 添加文件工具
    local file_tools = M.register_file_tools()
    if type(file_tools) == "table" then
        for _, tool in ipairs(file_tools) do
            table.insert(all_tools, tool)
        
    else
        vim.notify("file_tools 不是table类型: " .. type(file_tools), vim.log.levels.WARN)
    
    return all_tools

--- 按名称获取工具
--- @param tool_name string 工具名称
--- @return table|nil 工具定义
function M.get_tool(tool_name)
    local tools = M.get_all_tools()
    for _, tool in ipairs(tools) do
        if tool.name == tool_name then
            return tool
        
    
    return nil

--- 检查工具是否存在
--- @param tool_name string 工具名称
--- @return boolean 是否存在
function M.has_tool(tool_name)
    return M.get_tool(tool_name) ~= nil

--- 执行工具
--- @param tool_name string 工具名称
--- @param params table 参数
--- @return any 执行结果
function M.execute_tool(tool_name, params)
    local tool = M.get_tool(tool_name)
    if not tool then
        return nil, "工具不存在: " .. tool_name
    
    return tool.func(params)

return M