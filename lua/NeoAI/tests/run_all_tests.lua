#!/usr/bin/env lua

-- NeoAI 完整测试套件运行器
-- 运行所有测试并生成报告

print("🚀 NeoAI 完整测试套件")
print(string.rep("=", 60))

-- 设置包路径
local current_dir = debug.getinfo(1).source:match("@?(.*/)")
if current_dir then
    -- 添加当前目录
    package.path = package.path .. ";" .. current_dir .. "?.lua;" .. current_dir .. "?/init.lua"
    -- 添加父目录（NeoAI目录）
    local parent_dir = current_dir:match("(.*)/")
    if parent_dir then
        package.path = package.path .. ";" .. parent_dir .. "/?.lua;" .. parent_dir .. "/?/init.lua"
        -- 添加项目根目录
        local project_root = parent_dir:match("(.*)/")
        if project_root then
            package.path = package.path .. ";" .. project_root .. "/?.lua;" .. project_root .. "/?/init.lua"
        
    

-- 调试：打印包路径
-- print("调试: package.path = " .. package.path)

-- 加载测试初始化器
local test_init_loaded, test_init = pcall(require, "test.init")
if not test_init_loaded then
    print("❌ 无法加载测试初始化器: " .. tostring(test_init))
    os.exit(1)

-- 运行所有测试
print("📋 开始运行所有测试...")
print("")

local start_time = os.clock()
test_init.run_all_tests()
local end_time = os.clock()

print("")
print(string.rep("=", 60))
print(string.format("⏱️  总测试时间: %.2f 秒", end_time - start_time))
print("🎉 测试套件运行完成!")
print(string.rep("=", 60))

-- 提供使用说明
print("")
print("📖 使用说明:")
print("1. 在Neovim中运行测试:")
print("   :NeoAITestAll                    # 运行所有测试")
print("   :NeoAITest <测试名称>            # 运行指定测试")
print("")
print("2. 在命令行中运行测试:")
print("   lua test/run_all_tests.lua       # 运行所有测试")
print("")
print("3. 可用测试命令:")