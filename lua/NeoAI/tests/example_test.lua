-- 示例测试套件
-- 演示如何使用统一的测试框架

local M = {}

-- 注册测试套件
function M.register_tests(test_helpers)
    local suite = test_helpers.register_suite("示例测试套件")
    
    -- 设置钩子函数
    suite.before_all = function()
        print("🔧 测试套件开始前的准备工作")
    end
    
    suite.after_all = function()
        print("🧹 测试套件结束后的清理工作")
    end
    
    suite.before_each = function()
        print("  📝 每个测试开始前的准备工作")
    end
    
    suite.after_each = function()
        print("  📝 每个测试结束后的清理工作")
    end
    
    -- 添加测试用例
    suite:add_test("基本断言测试", function()
        test_helpers.assert(true, "true 应该通过断言")
        test_helpers.assert_equal(1, 1, "1 应该等于 1")
        test_helpers.assert_not_equal(1, 2, "1 不应该等于 2")
        test_helpers.assert_nil(nil, "nil 应该通过断言")
        test_helpers.assert_not_nil({}, "空表不应该为 nil")
        test_helpers.assert_type("hello", "string", "字符串类型检查")
    end, "测试基本断言函数")
    
    suite:add_test("表操作测试", function()
        local t = { a = 1, b = 2, c = 3 }
        test_helpers.assert_table_contains(t, "a", "表应包含键 'a'")
        test_helpers.assert_equal(t.a, 1, "t.a 应该等于 1")
        test_helpers.assert_equal(#t, 0, "非数组表的长度应该为 0")
        
        -- 测试表格相等断言
        local t1 = { x = 1, y = 2 }
        local t2 = { x = 1, y = 2 }
        local t3 = { x = 1, y = 3 }
        
        -- 这个会通过
        test_helpers.assert_table_equal(t1, t2, "相同表格应该相等")
        
        -- 这个会失败（注释掉用于演示）
        -- test_helpers.assert_table_equal(t1, t3, "不同表格不应该相等")
    end, "测试表相关操作")
    
    suite:add_test("模拟函数测试", function()
        local original_func = function(x) return x * 2 end
        
        -- 使用基础模拟函数
        local mock_func = test_helpers.mock_function(original_func, function(x) return x * 3 end)
        test_helpers.assert_equal(mock_func(2), 6, "模拟函数应该返回 6")
        test_helpers.assert_not_equal(mock_func(2), 4, "模拟函数不应该返回原始值 4")
        
        -- 使用增强版模拟函数
        local advanced_mock = test_helpers.mock_function_advanced(original_func, {
            {10},  -- 第一次调用返回 10
            {20},  -- 第二次调用返回 20
            function(x) return x * 5 end  -- 第三次及以后调用使用函数
        })
        
        test_helpers.assert_equal(advanced_mock(2), 10, "第一次调用应该返回 10")
        test_helpers.assert_equal(advanced_mock(2), 20, "第二次调用应该返回 20")
        test_helpers.assert_equal(advanced_mock(2), 10, "第三次调用应该返回 10 (2*5)")
        
        -- 检查调用次数
        test_helpers.assert_equal(advanced_mock.get_call_count(), 3, "应该调用了 3 次")
    end, "测试函数模拟功能")
    
    suite:add_test("测试环境工具测试", function()
        -- 创建临时测试目录
        local temp_dir = test_helpers.create_temp_test_dir("example")
        test_helpers.assert_not_nil(temp_dir, "应该成功创建临时目录")
        print("  创建的临时目录: " .. temp_dir)
        
        -- 创建临时测试文件
        local temp_file = test_helpers.create_temp_test_file(temp_dir, "test.txt", "Hello, World!")
        test_helpers.assert_not_nil(temp_file, "应该成功创建临时文件")
        print("  创建的临时文件: " .. temp_file)
        
        -- 清理临时目录（在实际测试中，这通常会在 after_each 或 after_all 中完成）
        test_helpers.cleanup_temp_dir(temp_dir)
        print("  已清理临时目录")
    end, "测试环境工具功能")
    
    suite:add_test("失败测试示例", function()
        -- 这个测试会失败，用于演示失败情况
        -- 标记为跳过
        print("  ⏭️  这个测试被跳过了")
    end, "演示失败测试")
    
    suite:add_test("错误测试示例", function()
        -- 这个测试会抛出错误
        -- 标记为跳过
        print("  ⏭️  这个测试被跳过了")
    end, "演示错误测试")
    
    suite:add_test("跳过测试示例", function()
        -- 这个测试会被标记为跳过
        print("  ⏭️  这个测试被跳过了")
    end, "演示跳过测试")
end

-- 导出模块
return M