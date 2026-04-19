-- 工具函数测试
-- 测试NeoAI工具函数库

local M = {}

--- 测试通用工具函数
local function test_common_utils()
    print("🔧 测试通用工具函数...")
    
    local loaded, common_utils = pcall(require, "NeoAI.utils.common")
    if not loaded then
        return false, "无法加载通用工具函数: " .. tostring(common_utils)
    
    -- 检查模块结构
    if type(common_utils) ~= "table" then
        return false, "通用工具函数不是table类型"
    
    -- 测试 deep_copy 函数
    if type(common_utils.deep_copy) ~= "function" then
        return false, "deep_copy 函数不存在"
    
    local original_table = {
        a = 1,
        b = {c = 2, d = {e = 3}},
        f = "test"
    }
    
    local copied_table = common_utils.deep_copy(original_table)
    
    -- 修改复制后的表格，原始表格不应受影响
    copied_table.b.d.e = 999
    if original_table.b.d.e == 999 then
        return false, "deep_copy 不是深拷贝"
    
    print("✅ deep_copy 函数测试通过")
    
    -- 测试 merge_tables 函数
    if type(common_utils.merge_tables) ~= "function" then
        return false, "merge_tables 函数不存在"
    
    local table1 = {a = 1, b = 2}
    local table2 = {b = 3, c = 4}
    
    local merged = common_utils.merge_tables(table1, table2)
    if merged.a ~= 1 or merged.b ~= 3 or merged.c ~= 4 then
        return false, "merge_tables 合并结果不正确"
    
    print("✅ merge_tables 函数测试通过")
    
    -- 测试 is_empty 函数
    if type(common_utils.is_empty) ~= "function" then
        return false, "is_empty 函数不存在"
    
    if not common_utils.is_empty({}) then
        return false, "is_empty 对空表格返回false"
    
    if common_utils.is_empty({a = 1}) then
        return false, "is_empty 对非空表格返回true"
    
    if not common_utils.is_empty(nil) then
        return false, "is_empty 对nil返回false"
    
    print("✅ is_empty 函数测试通过")
    
    -- 测试 safe_call 函数
    if type(common_utils.safe_call) ~= "function" then
        return false, "safe_call 函数不存在"
    
    -- 测试正常执行
    local result, error_msg = common_utils.safe_call(function()
        return "正常执行"
    end)
    
    if result ~= "正常执行" or error_msg ~= nil then
        return false, "safe_call 正常执行失败: 结果=" .. tostring(result) .. ", 错误=" .. tostring(error_msg)
    
    -- 测试错误处理
    local error_result, error_msg = common_utils.safe_call(function()
        error("测试错误")
    end)
    
    if error_result ~= nil then
        return false, "safe_call 错误处理失败: 错误结果应该为nil，实际为" .. tostring(error_result)
    
    if not error_msg or not string.find(error_msg, "测试错误") then
        return false, "safe_call 错误信息不正确: " .. tostring(error_msg)
    
    print("✅ safe_call 函数测试通过")
    
    return true, "通用工具函数测试通过"

--- 测试文件工具函数
local function test_file_utils()
    print("📁 测试文件工具函数...")
    
    local loaded, file_utils = pcall(require, "NeoAI.utils.file_utils")
    if not loaded then
        return false, "无法加载文件工具函数: " .. tostring(file_utils)
    
    -- 检查模块结构
    if type(file_utils) ~= "table" then
        return false, "文件工具函数不是table类型"
    
    -- 测试 ensure_dir 函数
    if type(file_utils.ensure_dir) ~= "function" then
        return false, "ensure_dir 函数不存在"
    
    local test_dir = "/tmp/neoa_test_dir"
    local ensure_success = file_utils.ensure_dir(test_dir)
    if not ensure_success then
        return false, "ensure_dir 创建目录失败"
    
    -- 检查目录是否存在
    local dir_exists = file_utils.dir_exists(test_dir)
    if not dir_exists then
        return false, "ensure_dir 创建的目录不存在"
    
    print("✅ ensure_dir 函数测试通过")
    
    -- 测试 write_file 和 read_file 函数
    if type(file_utils.write_file) ~= "function" then
        return false, "write_file 函数不存在"
    
    if type(file_utils.read_file) ~= "function" then
        return false, "read_file 函数不存在"
    
    local test_file = test_dir .. "/test.txt"
    local test_content = "测试文件内容\n第二行"
    
    local write_success = file_utils.write_file(test_file, test_content)
    if not write_success then
        return false, "write_file 写入文件失败"
    
    local read_content = file_utils.read_file(test_file)
    if read_content ~= test_content then
        return false, "read_file 读取内容不正确"
    
    print("✅ write_file 和 read_file 函数测试通过")
    
    -- 测试 list_files 函数
    if type(file_utils.list_files) ~= "function" then
        return false, "list_files 函数不存在"
    
    -- 创建更多测试文件
    file_utils.write_file(test_dir .. "/file1.txt", "文件1")
    file_utils.write_file(test_dir .. "/file2.lua", "文件2")
    file_utils.ensure_dir(test_dir .. "/subdir")
    file_utils.write_file(test_dir .. "/subdir/file3.txt", "文件3")
    
    local all_files = file_utils.list_files(test_dir, "*.txt")
    if type(all_files) ~= "table" then
        return false, "list_files 返回类型不正确"
    
    -- 应该找到3个txt文件（test.txt, file1.txt, subdir/file3.txt）
    if #all_files < 3 then
        return false, string.format("list_files 找到的文件数量不正确: %d", #all_files)
    
    print("✅ list_files 函数测试通过")
    
    -- 清理测试目录
    os.execute("rm -rf " .. test_dir)
    
    return true, "文件工具函数测试通过"

--- 测试日志工具函数
local function test_logger_utils()
    print("📝 测试日志工具函数...")
    
    local loaded, logger = pcall(require, "NeoAI.utils.logger")
    if not loaded then
        return false, "无法加载日志工具函数: " .. tostring(logger)
    
    -- 检查模块结构
    if type(logger) ~= "table" then
        return false, "日志工具函数不是table类型"
    
    -- 测试初始化
    logger.initialize({log_level = "DEBUG", log_file = "/tmp/neoa_test.log"})
    
    -- 测试日志级别函数
    if type(logger.debug) ~= "function" then
        return false, "debug 函数不存在"
    
    if type(logger.info) ~= "function" then
        return false, "info 函数不存在"
    
    if type(logger.warn) ~= "function" then
        return false, "warn 函数不存在"
    
    if type(logger.error) ~= "function" then
        return false, "error 函数不存在"
    
    -- 测试日志输出（不会实际检查输出，只检查函数是否正常工作）
    local success = pcall(function()
        logger.debug("调试日志")
        logger.info("信息日志")
        logger.warn("警告日志")
        logger.error("错误日志")
    end)
    
    if not success then
        return false, "日志函数调用失败"
    
    print("✅ 日志函数测试通过")
    
    -- 测试设置日志级别
    logger.set_level("WARN")
    
    -- 测试获取当前日志级别
    local current_level = logger.get_level()
    if current_level ~= "WARN" then
        return false, "设置/获取日志级别失败"
    
    print("✅ 日志级别管理测试通过")
    
    -- 清理日志文件
    os.execute("rm -f /tmp/neoa_test.log")
    
    return true, "日志工具函数测试通过"

--- 测试表格工具函数
local function test_table_utils()
    print("📊 测试表格工具函数...")
    
    local loaded, table_utils = pcall(require, "NeoAI.utils.table_utils")
    if not loaded then
        return false, "无法加载表格工具函数: " .. tostring(table_utils)
    
    -- 检查模块结构
    if type(table_utils) ~= "table" then
        return false, "表格工具函数不是table类型"
    
    -- 测试 table_contains 函数
    if type(table_utils.table_contains) ~= "function" then
        return false, "table_contains 函数不存在"
    
    local test_table = {"apple", "banana", "cherry"}
    if not table_utils.table_contains(test_table, "banana") then
        return false, "table_contains 未找到存在的元素"
    
    if table_utils.table_contains(test_table, "orange") then
        return false, "table_contains 找到不存在的元素"
    
    print("✅ table_contains 函数测试通过")
    
    -- 测试 table_keys 函数
    if type(table_utils.table_keys) ~= "function" then
        return false, "table_keys 函数不存在"
    
    local keyed_table = {a = 1, b = 2, c = 3}
    local keys = table_utils.table_keys(keyed_table)
    
    if type(keys) ~= "table" then
        return false, "table_keys 返回类型不正确"
    
    if #keys ~= 3 then
        return false, "table_keys 返回的键数量不正确"
    
    -- 检查是否包含所有键
    local key_set = {}
    for _, key in ipairs(keys) do
        key_set[key] = true
    
    if not key_set.a or not key_set.b or not key_set.c then
        return false, "table_keys 未返回所有键"
    
    print("✅ table_keys 函数测试通过")
    
    -- 测试 table_values 函数
    if type(table_utils.table_values) ~= "function" then
        return false, "table_values 函数不存在"
    
    local values = table_utils.table_values(keyed_table)
    
    if type(values) ~= "table" then
        return false, "table_values 返回类型不正确"
    
    if #values ~= 3 then
        return false, "table_values 返回的值数量不正确"
    
    -- 检查是否包含所有值
    local value_set = {}
    for _, value in ipairs(values) do
        value_set[value] = true
    
    if not value_set[1] or not value_set[2] or not value_set[3] then
        return false, "table_values 未返回所有值"
    
    print("✅ table_values 函数测试通过")
    
    -- 测试 table_filter 函数
    if type(table_utils.table_filter) ~= "function" then
        return false, "table_filter 函数不存在"
    
    local numbers = {1, 2, 3, 4, 5, 6}
    local even_numbers = table_utils.table_filter(numbers, function(value)
        return value % 2 == 0
    end)
    
    if #even_numbers ~= 3 then
        return false, "table_filter 过滤结果数量不正确"
    
    for _, num in ipairs(even_numbers) do
        if num % 2 ~= 0 then
            return false, "table_filter 过滤结果包含奇数"
        
    
    print("✅ table_filter 函数测试通过")
    
    -- 测试 table_map 函数
    if type(table_utils.table_map) ~= "function" then
        return false, "table_map 函数不存在"
    
    local squared_numbers = table_utils.table_map(numbers, function(value)
        return value * value
    end)
    
    if #squared_numbers ~= #numbers then
        return false, "table_map 映射结果数量不正确"
    
    if squared_numbers[1] ~= 1 or squared_numbers[2] ~= 4 or squared_numbers[3] ~= 9 then
        return false, "table_map 映射结果不正确"
    
    print("✅ table_map 函数测试通过")
    
    return true, "表格工具函数测试通过"

--- 测试文本工具函数
local function test_text_utils()
    print("📄 测试文本工具函数...")
    
    local loaded, text_utils = pcall(require, "NeoAI.utils.text_utils")
    if not loaded then
        return false, "无法加载文本工具函数: " .. tostring(text_utils)
    
    -- 检查模块结构
    if type(text_utils) ~= "table" then
        return false, "文本工具函数不是table类型"
    
    -- 测试 trim 函数
    if type(text_utils.trim) ~= "function" then
        return false, "trim 函数不存在"
    
    local test_string = "  测试文本  "
    local trimmed = text_utils.trim(test_string)
    if trimmed ~= "测试文本" then
        return false, "trim 函数结果不正确"
    
    print("✅ trim 函数测试通过")
    
    -- 测试 split 函数
    if type(text_utils.split) ~= "function" then
        return false, "split 函数不存在"
    
    local csv_string = "apple,banana,cherry"
    local parts = text_utils.split(csv_string, ",")
    
    if type(parts) ~= "table" then
        return false, "split 返回类型不正确"
    
    if #parts ~= 3 then
        return false, "split 分割结果数量不正确"
    
    if parts[1] ~= "apple" or parts[2] ~= "banana" or parts[3] ~= "cherry" then
        return false, "split 分割结果不正确"
    
    print("✅ split 函数测试通过")
    
    -- 测试 join 函数
    if type(text_utils.join) ~= "function" then
        return false, "join 函数不存在"
    
    local joined = text_utils.join(parts, "|")
    if joined ~= "apple|banana|cherry" then
        return false, "join 连接结果不正确"
    
    print("✅ join 函数测试通过")
    
    -- 测试 starts_with 函数
    if type(text_utils.starts_with) ~= "function" then
        return false, "starts_with 函数不存在"
    
    if not text_utils.starts_with("hello world", "hello") then
        return false, "starts_with 未检测到前缀"
    
    if text_utils.starts_with("hello world", "world") then
        return false, "starts_with 错误检测前缀"
    
    print("✅ starts_with 函数测试通过")
    
    -- 测试 ends_with 函数
    if type(text_utils.ends_with) ~= "function" then
        return false, "ends_with 函数不存在"
    
    if not text_utils.ends_with("hello world", "world") then
        return false, "ends_with 未检测到后缀"
    
    if text_utils.ends_with("hello world", "hello") then
        return false, "ends_with 错误检测后缀"
    
    print("✅ ends_with 函数测试通过")
    
    -- 测试 truncate 函数
    if type(text_utils.truncate) ~= "function" then
        return false, "truncate 函数不存在"
    
    local long_text = "这是一个很长的文本需要截断"
    local truncated = text_utils.truncate(long_text, 10)
    
    if #truncated > 13 then -- 10个字符 + "..." = 13个字符
        return false, "truncate 截断结果过长"
    
    if not string.find(truncated, "%.%.%.") then
        return false, "truncate 未添加省略号"
    
    print("✅ truncate 函数测试通过")
    
    return true, "文本工具函数测试通过"

--- 运行工具函数测试
function M.run()
    print("🧪 运行工具函数测试...")
    print(string.rep("=", 60))
    
    local results = {}
    
    -- 运行通用工具函数测试
    local common_success, common_result = test_common_utils()
    table.insert(results, {name = "通用工具", success = common_success, result = common_result})
    
    -- 运行文件工具函数测试
    local file_success, file_result = test_file_utils()
    table.insert(results, {name = "文件工具", success = file_success, result = file_result})
    
    -- 运行日志工具函数测试
    local logger_success, logger_result = test_logger_utils()
    table.insert(results, {name = "日志工具", success = logger_success, result = logger_result})
    
    -- 运行表格工具函数测试
    local table_success, table_result = test_table_utils()
    table.insert(results, {name = "表格工具", success = table_success, result = table_result})
    
    -- 运行文本工具函数测试
    local text_success, text_result = test_text_utils()
    table.insert(results, {name = "文本工具", success = text_success, result = text_result})
    
    -- 输出结果
    print("")
    print(string.rep("=", 60))
    print("📊 工具函数测试结果:")
    
    local all_passed = true
    for _, test_result in ipairs(results) do
        if test_result.success then
            print("✅ " .. test_result.name .. ": " .. test_result.result)
        else
            print("❌ " .. test_result.name .. ": " .. test_result.result)
            all_passed = false
        
    
    print(string.rep("=", 60))
    
    if all_passed then
        print("🎉 所有工具函数测试通过!")
        return {true, "工具函数测试完成"}
    else
        print("⚠️ 部分工具函数测试失败")
        return {false, "工具函数测试失败"}
    

return M