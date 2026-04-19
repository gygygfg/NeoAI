-- 测试工具模块
-- 提供测试环境所需的通用工具函数

local M = {}

--- 清理所有测试目录
-- 清理测试过程中创建的临时目录和文件
-- 注意：这个函数会清理所有匹配的测试目录，可能会影响正在运行的测试
-- 建议在测试开始时调用，而不是在测试过程中调用
function M.cleanup_all_test_dirs()
    print("🧹 清理所有测试目录...")
    
    -- 获取缓存目录
    local cache_dir = vim.fn.stdpath("cache")
    
    -- 定义要清理的测试目录模式
    local test_dirs = {
        cache_dir .. "/neoai_test_*",
        cache_dir .. "/neoai_sessions_test",
        cache_dir .. "/neoai_temp_*"
    }
    
    -- 清理每个目录
    for _, dir_pattern in ipairs(test_dirs) do
        local dirs = vim.fn.glob(dir_pattern, true, true)
        for _, dir in ipairs(dirs) do
            if vim.fn.isdirectory(dir) == 1 then
                -- 使用系统命令删除目录
                local cmd = string.format("rm -rf %s", vim.fn.shellescape(dir))
                os.execute(cmd)
                print("  删除目录: " .. dir)
            
        
    
    -- 清理测试文件
    local test_files = {
        cache_dir .. "/test_*.lua",
        cache_dir .. "/test_*.json",
        cache_dir .. "/test_*.txt"
    }
    
    for _, file_pattern in ipairs(test_files) do
        local files = vim.fn.glob(file_pattern, true, true)
        for _, file in ipairs(files) do
            if vim.fn.filereadable(file) == 1 then
                os.remove(file)
                print("  删除文件: " .. file)
            
        
    
    print("✅ 所有测试目录清理完成")

--- 安全清理测试目录
-- 只清理特定的测试目录，避免影响其他测试
-- @param dir_path string 要清理的目录路径
function M.safe_cleanup_test_dir(dir_path)
    if dir_path and vim.fn.isdirectory(dir_path) == 1 then
        -- 检查是否是测试目录（避免误删重要目录）
        if dir_path:match("/neoai_test_") or dir_path:match("/neoa_test_") then
            -- 使用系统命令删除目录
            local cmd = string.format("rm -rf %s", vim.fn.shellescape(dir_path))
            os.execute(cmd)
            print("🧹 安全清理测试目录: " .. dir_path)
        else
            print("⚠️  跳过非测试目录: " .. dir_path)
        
    

--- 清理单个临时目录
-- @param dir_path string 要清理的目录路径
function M.cleanup_temp_dir(dir_path)
    if dir_path and vim.fn.isdirectory(dir_path) == 1 then
        -- 使用系统命令删除目录
        local cmd = string.format("rm -rf %s", vim.fn.shellescape(dir_path))
        os.execute(cmd)
        print("🧹 清理临时目录: " .. dir_path)
    

--- 创建临时测试目录
-- @param prefix string 目录前缀
-- @return string 创建的目录路径
function M.create_temp_test_dir(prefix)
    local cache_dir = vim.fn.stdpath("cache")
    local timestamp = os.time()
    local random_suffix = math.random(1000, 9999)
    local dir_name = string.format("%s_test_%s_%d", prefix or "neoai", timestamp, random_suffix)
    local dir_path = cache_dir .. "/" .. dir_name
    
    -- 创建目录
    vim.fn.mkdir(dir_path, "p")
    
    return dir_path

--- 创建临时测试文件
-- @param dir_path string 目录路径
-- @param filename string 文件名
-- @param content string 文件内容
-- @return string 文件完整路径
function M.create_temp_test_file(dir_path, filename, content)
    local file_path = dir_path .. "/" .. filename
    local file = io.open(file_path, "w")
    if file then
        file:write(content or "")
        file:close()
        return file_path
    
    return nil

--- 断言函数
-- @param condition boolean 条件
-- @param message string 错误信息
function M.assert(condition, message)
    if not condition then
        error("断言失败: " .. (message or "未知错误"))
    

--- 断言相等
-- @param expected any 期望值
-- @param actual any 实际值
-- @param message string 错误信息
function M.assert_equal(expected, actual, message)
    if expected ~= actual then
        error(string.format("断言失败: 期望 %s, 实际 %s. %s", 
            tostring(expected), tostring(actual), message or ""))
    

--- 断言表格相等（浅比较）
-- @param expected table 期望表格
-- @param actual table 实际表格
-- @param message string 错误信息
function M.assert_table_equal(expected, actual, message)
    for k, v in pairs(expected) do
        if actual[k] ~= v then
            error(string.format("表格断言失败: 键 %s 期望 %s, 实际 %s. %s",
                tostring(k), tostring(v), tostring(actual[k]), message or ""))
        
    
    for k, v in pairs(actual) do
        if expected[k] == nil then
            error(string.format("表格断言失败: 键 %s 在期望表格中不存在, 实际值为 %s. %s",
                tostring(k), tostring(v), message or ""))
        
    

--- 模拟函数调用
-- @param func function 要模拟的函数
-- @param returns table 返回值列表
-- @return function 模拟函数
function M.mock_function(func, returns)
    local call_count = 0
    local call_args = {}
    
    local mock = function(...)
        call_count = call_count + 1
        call_args[call_count] = {...}
        
        if returns then
            local result = returns[call_count] or returns[#returns]
            if type(result) == "function" then
                return result(...)
            else
                return unpack(result or {})
            
        
        return nil
    
    mock.get_call_count = function() return call_count 
    mock.get_call_args = function(index) 
        if index then
            return call_args[index]
        
        return call_args
    
    return mock

--- 运行测试套件
-- @param tests table 测试函数列表
-- @param setup function 可选设置函数
-- @param teardown function 可选清理函数
function M.run_test_suite(tests, setup, teardown)
    local passed = 0
    local failed = 0
    
    for name, test_func in pairs(tests) do
        print("🧪 运行测试: " .. name)
        
        -- 执行设置函数
        if setup then
            pcall(setup)
        
        -- 执行测试
        local success, err = pcall(test_func)
        
        -- 执行清理函数
        if teardown then
            pcall(teardown)
        
        if success then
            print("✅ 测试通过: " .. name)
            passed = passed + 1
        else
            print("❌ 测试失败: " .. name)
            print("   错误: " .. tostring(err))
            failed = failed + 1
        
    
    print(string.format("📊 测试结果: %d 通过, %d 失败", passed, failed))
    
    return passed, failed

--- 获取测试配置
-- @return table 测试配置
function M.get_test_config()
    return {
        ai = {
            api_key = "test_key",
            model = "test-model",
            temperature = 0.7,
            max_tokens = 1000
        },
        session = {
            auto_save = true,
            max_history_per_session = 50,
            save_path = vim.fn.stdpath("cache") .. "/neoai_sessions_test"
        },
        ui = {
            window = {
                width = 80,
                height = 20
            }
        },
        _debug_source = "test_utils",
        _debug_timestamp = os.time()
    }

return M