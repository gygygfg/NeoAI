-- 文件工具测试
-- 测试NeoAI内置文件工具

local M = {}

-- 尝试导入测试初始化器，如果失败则使用模拟版本
local test_initializer = nil
local test_initializer_loaded, test_initializer_result = pcall(require, "NeoAI.tests.test_initializer")
if test_initializer_loaded then
    test_initializer = test_initializer_result
else
    -- 创建模拟的测试初始化器
    test_initializer = {
        initialize_test_environment = function()
            return {
                event_bus = {
                    emit = function() end,
                    on = function() end,
                    off = function() 
                },
                config = {
                    api_key = "test_key",
                    model = "test-model",
                    temperature = 0.7,
                    max_tokens = 1000,
                    save_path = "/tmp/neoa_test",
                    auto_save = false
                }
            }
        end,
        cleanup_test_environment = function()
            -- 什么都不做
        
    }
    print("⚠️  使用模拟的测试初始化器")

--- 测试文件工具加载和结构
local function test_file_tools_structure()
    print("📁 测试文件工具结构...")
    
    local loaded, file_tools = pcall(require, "NeoAI.tools.builtin.file_tools")
    if not loaded then
        return {false, "无法加载文件工具: " .. tostring(file_tools)}
    
    -- 检查模块结构
    if type(file_tools) ~= "table" then
        return {false, "文件工具不是table类型"}
    
    -- 检查工具列表
    local tools = file_tools.get_tools()
    if type(tools) ~= "table" then
        return {false, "文件工具列表不是table类型"}
    
    -- 检查是否有工具定义
    if #tools == 0 then
        return {false, "文件工具列表为空"}
    
    print("✅ 文件工具结构检查通过")
    
    -- 检查每个工具的结构
    for i, tool in ipairs(tools) do
        if type(tool) ~= "table" then
            return {false, "工具 #" .. i .. " 不是table类型"}
        
        if type(tool.name) ~= "string" then
            return {false, "工具 #" .. i .. " 缺少name字段"}
        
        if type(tool.description) ~= "string" then
            return {false, "工具 #" .. i .. " 缺少description字段"}
        
        if type(tool.parameters) ~= "table" then
            return {false, "工具 #" .. i .. " 缺少parameters字段"}
        
        if type(tool.func) ~= "function" then
            return {false, "工具 #" .. i .. " 缺少func字段"}
        
        print("   工具 #" .. i .. ": " .. tool.name .. " - " .. tool.description)
    
    print("✅ 所有文件工具结构正确")
    
    return {true, "文件工具结构测试通过"}

--- 测试读取文件工具
local function test_read_file_tool()
    print("📁 测试读取文件工具...")
    
    local loaded, file_tools = pcall(require, "NeoAI.tools.builtin.file_tools")
    if not loaded then
        return {false, "无法加载文件工具: " .. tostring(file_tools)}
    
    -- 获取工具列表
    local tools = file_tools.get_tools()
    
    -- 查找读取文件工具
    local read_tool = nil
    for _, tool in ipairs(tools) do
        if tool.name == "read_file" or string.find(tool.name:lower(), "read") then
            read_tool = tool
            break
        
    
    if not read_tool then
        return {false, "未找到读取文件工具"}
    
    print("✅ 找到读取文件工具: " .. read_tool.name)
    
    -- 创建测试文件
    local test_file = "/tmp/neoa_test_read.txt"
    local test_content = "测试文件内容\n第二行内容\n第三行内容"
    
    local file = io.open(test_file, "w")
    if not file then
        return {false, "无法创建测试文件"}
    
    file:write(test_content)
    file:close()
    
    -- 测试读取文件
    local result = read_tool.func({path = test_file})
    
    if not result then
        os.remove(test_file)
        return {false, "读取文件工具返回nil"}
    
    if type(result) ~= "string" then
        os.remove(test_file)
        return {false, "读取文件工具返回类型不是字符串"}
    
    if result ~= test_content then
        os.remove(test_file)
        return {false, "读取文件内容不正确"}
    
    -- 清理测试文件
    os.remove(test_file)
    
    print("✅ 读取文件工具测试通过")
    return {true, "读取文件工具测试通过"}

--- 测试写入文件工具
local function test_write_file_tool()
    print("📁 测试写入文件工具...")
    
    local loaded, file_tools = pcall(require, "NeoAI.tools.builtin.file_tools")
    if not loaded then
        return {false, "无法加载文件工具: " .. tostring(file_tools)}
    
    -- 获取工具列表
    local tools = file_tools.get_tools()
    
    -- 查找写入文件工具
    local write_tool = nil
    for _, tool in ipairs(tools) do
        if tool.name == "write_file" or string.find(tool.name:lower(), "write") then
            write_tool = tool
            break
        
    
    if not write_tool then
        return {false, "未找到写入文件工具"}
    
    print("✅ 找到写入文件工具: " .. write_tool.name)
    
    -- 创建测试文件路径
    local test_file = "/tmp/neoa_test_write.txt"
    local test_content = "测试写入文件内容\n多行内容测试"
    
    -- 测试写入文件
    local result = write_tool.func({path = test_file, content = test_content})
    
    if not result then
        return {false, "写入文件工具返回nil"}
    
    -- 验证文件是否创建
    local file = io.open(test_file, "r")
    if not file then
        return {false, "写入文件后无法打开文件"}
    
    local content = file:read("*a")
    file:close()
    
    if content ~= test_content then
        os.remove(test_file)
        return {false, "写入文件内容不正确"}
    
    -- 清理测试文件
    os.remove(test_file)
    
    print("✅ 写入文件工具测试通过")
    return {true, "写入文件工具测试通过"}

--- 运行所有文件工具测试
function M.run()
    print("📁 开始运行文件工具测试...")
    print(string.rep("=", 50))
    
    -- 初始化测试环境
    local test_env = test_initializer.initialize_test_environment()
    
    local tests = {
        { name = "文件工具结构", func = test_file_tools_structure },
        { name = "读取文件工具", func = test_read_file_tool },
        { name = "写入文件工具", func = test_write_file_tool }
    }
    
    local passed = 0
    local failed = 0
    
    for _, test in ipairs(tests) do
        print("📋 运行测试: " .. test.name)
        local success, result = pcall(test.func)
        
        if success then
            if result == true or (type(result) == "table" and result[1] == true) then
                print("✅ " .. test.name .. " 测试通过")
                passed = passed + 1
            else
                print("❌ " .. test.name .. " 测试失败: " .. tostring(result))
                failed = failed + 1
            
        else
            print("❌ " .. test.name .. " 测试异常: " .. tostring(result))
            failed = failed + 1
        
        print("")
    
    print(string.rep("=", 50))
    print("📊 文件工具测试总结:")
    print("   总测试数: " .. #tests)
    print("   通过: " .. passed)
    print("   失败: " .. failed)
    print("   通过率: " .. string.format("%.1f%%", (passed / #tests) * 100))
    
    -- 清理测试环境
    test_initializer.cleanup_test_environment()
    
    if passed == #tests then
        return {true, "所有文件工具测试通过"}
    else
        return {false, "有 " .. failed .. " 个文件工具测试失败"}
    

return M
