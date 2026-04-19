-- 模块加载测试
-- 测试所有NeoAI模块的加载和初始化

local M = {}

-- 设置package.path以确保能找到模块
local current_dir = "/root/NeoAI/pack/plugins/start/NeoAI/lua"
package.path = package.path .. ";" .. current_dir .. "/?.lua"
package.path = package.path .. ";" .. current_dir .. "/?/init.lua"

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
                    session = {
                        save_path = "/tmp/neoa_test",
                        auto_save = false
                    }
                }
            }
        end,
        cleanup_test_environment = function()
            -- 什么都不做
        
    }
    print("⚠️  使用模拟的测试初始化器")

--- 测试模块加载
--- @param module_name string 模块名称
--- @return boolean, table|string 是否加载成功，模块实例或错误信息
local function test_module_loading(module_name)
    -- 首先尝试直接加载
    local loaded, module = pcall(require, module_name)
    if not loaded then
        -- 如果失败，尝试不同的路径
        local paths_to_try = {
            module_name,
            module_name:gsub("^NeoAI%.", ""),
            module_name:gsub("^NeoAI%.test%.", "test."),
            module_name:gsub("^NeoAI%.core%.", "core."),
            module_name:gsub("^NeoAI%.ui%.", "ui."),
            module_name:gsub("^NeoAI%.tools%.", "tools."),
            module_name:gsub("^NeoAI%.utils%.", "utils."),
        }
        
        for _, path in ipairs(paths_to_try) do
            loaded, module = pcall(require, path)
            if loaded then
                break
            
        
    
    if not loaded then
        -- 添加调试信息
        print("调试: 模块 " .. module_name .. " 加载失败，错误: " .. tostring(module))
        return false, "加载失败: " .. tostring(module)
    
    -- 更宽容的检查：只要加载成功就认为是有效的
    -- 模块可以是table、function或其他类型
    return true, module

--- 测试核心模块
local function test_core_modules()
    print("🔍 测试核心模块...")
    
    local core_modules = {
        "NeoAI.core",
        "NeoAI.core.config.config_manager",
        "NeoAI.core.config.keymap_manager",
        "NeoAI.core.session.session_manager",
        "NeoAI.core.ai.ai_engine",
        "NeoAI.core.events.event_bus",
        "NeoAI.core.history_manager",
    }
    
    local results = {}
    
    for _, module_name in ipairs(core_modules) do
        local success, result = test_module_loading(module_name)
        if success then
            table.insert(results, "✅ " .. module_name)
        else
            table.insert(results, "❌ " .. module_name .. ": " .. result)
        
    
    return results

--- 测试UI模块
local function test_ui_modules()
    print("🎨 测试UI模块...")
    
    local ui_modules = {
        "NeoAI.ui",
        "NeoAI.ui.window.chat_window",
        "NeoAI.ui.window.tree_window",
        "NeoAI.ui.window.window_manager",
        "NeoAI.ui.components.history_tree",
        "NeoAI.ui.components.input_handler",
        "NeoAI.ui.handlers.chat_handlers",
        "NeoAI.ui.handlers.tree_handlers",
    }
    
    local results = {}
    
    for _, module_name in ipairs(ui_modules) do
        local success, result = test_module_loading(module_name)
        if success then
            table.insert(results, "✅ " .. module_name)
        else
            table.insert(results, "❌ " .. module_name .. ": " .. result)
        
    
    return results

--- 测试工具模块
local function test_tool_modules()
    print("🔧 测试工具模块...")
    
    local tool_modules = {
        "NeoAI.tools",
        "NeoAI.tools.tool_executor",
        "NeoAI.tools.tool_registry",
        "NeoAI.tools.tool_validator",
        "NeoAI.tools.builtin.file_tools",
    }
    
    local results = {}
    
    for _, module_name in ipairs(tool_modules) do
        local success, result = test_module_loading(module_name)
        if success then
            table.insert(results, "✅ " .. module_name)
        else
            table.insert(results, "❌ " .. module_name .. ": " .. result)
        
    
    return results

--- 测试工具模块
local function test_utils_modules()
    print("📦 测试工具模块...")
    
    local utils_modules = {
        "NeoAI.utils",
        "NeoAI.utils.common",
        "NeoAI.utils.file_utils",
        "NeoAI.utils.logger",
        "NeoAI.utils.table_utils",
        "NeoAI.utils.text_utils",
    }
    
    local results = {}
    
    for _, module_name in ipairs(utils_modules) do
        local success, result = test_module_loading(module_name)
        if success then
            table.insert(results, "✅ " .. module_name)
        else
            table.insert(results, "❌ " .. module_name .. ": " .. result)
        
    
    return results

--- 测试AI模块
local function test_ai_modules()
    print("🤖 测试AI模块...")
    
    local ai_modules = {
        "NeoAI.core.ai.ai_engine",
        "NeoAI.core.ai.reasoning_manager",
        "NeoAI.core.ai.response_builder",
        "NeoAI.core.ai.stream_processor",
        "NeoAI.core.ai.tool_orchestrator",
    }
    
    local results = {}
    
    for _, module_name in ipairs(ai_modules) do
        local success, result = test_module_loading(module_name)
        if success then
            table.insert(results, "✅ " .. module_name)
        else
            table.insert(results, "❌ " .. module_name .. ": " .. result)
        
    
    return results

--- 测试会话模块
local function test_session_modules()
    print("💬 测试会话模块...")
    
    local session_modules = {
        "NeoAI.core.session.session_manager",
        "NeoAI.core.session.branch_manager",
        "NeoAI.core.session.data_operations",
        "NeoAI.core.session.message_manager",
    }
    
    local results = {}
    
    for _, module_name in ipairs(session_modules) do
        local success, result = test_module_loading(module_name)
        if success then
            table.insert(results, "✅ " .. module_name)
        else
            table.insert(results, "❌ " .. module_name .. ": " .. result)
        
    
    return results

--- 运行模块加载测试
function M.run()
    print("🚀 开始模块加载测试...")
    print(string.rep("=", 60))
    
    -- 初始化测试环境
    local test_env = test_initializer.initialize_test_environment()
    
    local all_results = {}
    
    -- 测试所有模块类别
    local test_categories = {
        { name = "核心模块", test_func = test_core_modules },
        { name = "UI模块", test_func = test_ui_modules },
        { name = "工具模块", test_func = test_tool_modules },
        { name = "工具模块", test_func = test_utils_modules },
        { name = "AI模块", test_func = test_ai_modules },
        { name = "会话模块", test_func = test_session_modules },
    }
    
    local total_tests = 0
    local passed_tests = 0
    local failed_tests = 0
    
    for _, category in ipairs(test_categories) do
        print("📋 " .. category.name .. ":")
        local results = category.test_func()
        
        for _, result in ipairs(results) do
            table.insert(all_results, result)
            -- 检查字符串是否以"✅"开头（需要检查前3个字节）
            if result:sub(1, 3) == "✅" then
                passed_tests = passed_tests + 1
            else
                failed_tests = failed_tests + 1
            
            total_tests = total_tests + 1
        
        print("")
    
    -- 显示总结
    print(string.rep("=", 60))
    print("📊 模块加载测试总结:")
    print("   总模块数: " .. total_tests)
    print("   加载成功: " .. passed_tests)
    print("   加载失败: " .. failed_tests)
    print("   成功率: " .. string.format("%.1f%%", (passed_tests / total_tests) * 100))
    
    if failed_tests == 0 then
        print("🎉 所有模块加载成功!")
        return {true, "所有模块加载成功"}
    else
        print("⚠️ 有 " .. failed_tests .. " 个模块加载失败")
        
        -- 显示失败的模块
        print("")
        print("❌ 失败的模块:")
        for _, result in ipairs(all_results) do
            if result:sub(1, 3) == "❌" then
                print("  " .. result)
            
        
        -- 清理测试环境
        test_initializer.cleanup_test_environment()
        
        return {false, "部分模块加载失败"}
    
    -- 清理测试环境
    test_initializer.cleanup_test_environment()
    
    return true

--- 快速测试：只测试主要模块
function M.quick_test()
    print("⚡ 快速模块加载测试...")
    
    local main_modules = {
        "NeoAI",
        "NeoAI.core",
        "NeoAI.ui",
        "NeoAI.tools",
        "NeoAI.utils",
    }
    
    local results = {}
    
    for _, module_name in ipairs(main_modules) do
        local success, result = test_module_loading(module_name)
        if success then
            table.insert(results, "✅ " .. module_name)
        else
            table.insert(results, "❌ " .. module_name .. ": " .. result)
        
    
    -- 显示结果
    print("=" * 40)
    for _, result in ipairs(results) do
        print(result)
    
    print("=" * 40)
    
    -- 检查是否有失败
    for _, result in ipairs(results) do
        if result:sub(1, 1) == "❌" then
            return false, "主要模块加载失败"
        
    
    return true

return M
