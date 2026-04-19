-- 工具函数测试套件
-- 测试NeoAI工具函数库

local M = {}

-- 注册测试套件
function M.register_tests(test_runner)
    local suite = test_runner.register_suite("工具函数测试")
    
    -- 测试通用工具函数
    suite:add_test("通用工具函数加载", function()
        local loaded, common_utils = pcall(require, "NeoAI.utils.common")
        test_runner.assert(loaded, "应该能加载通用工具函数: " .. tostring(common_utils))
        test_runner.assert_type(common_utils, "table", "通用工具函数应该是table类型")
    end, "测试通用工具函数的基本加载")
    
    suite:add_test("深拷贝函数测试", function()
        local common_utils = require("NeoAI.utils.common")
        
        test_runner.assert_type(common_utils.deep_copy, "function", "应该有deep_copy函数")
        
        -- 创建测试表格
        local original_table = {
            a = 1,
            b = {c = 2, d = {e = 3}},
            f = "test",
            g = function() return "function" end
        }
        
        -- 执行深拷贝
        local copied_table = common_utils.deep_copy(original_table)
        
        -- 验证基本属性
        test_runner.assert_equal(copied_table.a, 1, "基本属性应该被复制")
        test_runner.assert_equal(copied_table.f, "test", "字符串属性应该被复制")
        
        -- 验证嵌套表格是独立的
        copied_table.b.d.e = 999
        test_runner.assert_not_equal(original_table.b.d.e, 999, 
            "修改拷贝后的嵌套表格不应该影响原始表格")
        test_runner.assert_equal(original_table.b.d.e, 3, 
            "原始表格的嵌套值应该保持不变")
        
        -- 验证函数引用
        test_runner.assert_type(copied_table.g, "function", "函数引用应该被保留")
        test_runner.assert_equal(copied_table.g(), "function", "函数应该能正常调用")
    end, "测试深拷贝功能")
    
    suite:add_test("表格合并函数测试", function()
        local common_utils = require("NeoAI.utils.common")
        
        test_runner.assert_type(common_utils.merge_tables, "function", "应该有merge_tables函数")
        
        -- 测试简单合并
        local table1 = {a = 1, b = 2}
        local table2 = {b = 3, c = 4}
        
        local merged = common_utils.merge_tables(table1, table2)
        
        test_runner.assert_equal(merged.a, 1, "第一个表格的属性应该被保留")
        test_runner.assert_equal(merged.b, 3, "第二个表格的属性应该覆盖第一个")
        test_runner.assert_equal(merged.c, 4, "第二个表格的新属性应该被添加")
        
        -- 测试嵌套合并
        local nested1 = {a = {b = 1, c = 2}}
        local nested2 = {a = {c = 3, d = 4}, e = 5}
        
        local nested_merged = common_utils.merge_tables(nested1, nested2)
        
        test_runner.assert_type(nested_merged.a, "table", "嵌套表格应该被合并")
        test_runner.assert_equal(nested_merged.a.b, 1, "嵌套表格的第一个属性应该被保留")
        test_runner.assert_equal(nested_merged.a.c, 3, "嵌套表格的第二个属性应该被覆盖")
        test_runner.assert_equal(nested_merged.a.d, 4, "嵌套表格的新属性应该被添加")
        test_runner.assert_equal(nested_merged.e, 5, "顶层新属性应该被添加")
    end, "测试表格合并功能")
    
    suite:add_test("空值检查函数测试", function()
        local common_utils = require("NeoAI.utils.common")
        
        test_runner.assert_type(common_utils.is_empty, "function", "应该有is_empty函数")
        
        -- 测试各种空值情况
        test_runner.assert(common_utils.is_empty(nil), "nil应该被认为是空的")
        test_runner.assert(common_utils.is_empty({}), "空表应该被认为是空的")
        test_runner.assert(common_utils.is_empty(""), "空字符串应该被认为是空的")
        
        -- 测试非空情况
        test_runner.assert_not(common_utils.is_empty({a = 1}), "非空表不应该被认为是空的")
        test_runner.assert_not(common_utils.is_empty("test"), "非空字符串不应该被认为是空的")
        test_runner.assert_not(common_utils.is_empty(0), "数字0不应该被认为是空的")
        test_runner.assert_not(common_utils.is_empty(false), "布尔值false不应该被认为是空的")
    end, "测试空值检查功能")
    
    suite:add_test("文件工具函数测试", function()
        local loaded, file_utils = pcall(require, "NeoAI.utils.file_utils")
        
        if not loaded then
            print("  ⏭️  文件工具函数模块不存在，跳过测试")
            return
        end
        
        test_runner.assert_type(file_utils, "table", "文件工具函数应该是table类型")
        
        -- 检查必要的函数
        test_runner.assert_type(file_utils.read_file, "function", "应该有read_file函数")
        test_runner.assert_type(file_utils.write_file, "function", "应该有write_file函数")
        test_runner.assert_type(file_utils.file_exists, "function", "应该有file_exists函数")
        
        -- 创建测试文件
        local test_file = "/tmp/neoa_test_file.txt"
        local test_content = "Hello, NeoAI Test!"
        
        -- 测试文件写入
        local success = file_utils.write_file(test_file, test_content)
        test_runner.assert(success, "应该能成功写入文件")
        
        -- 测试文件存在检查
        local exists = file_utils.file_exists(test_file)
        test_runner.assert(exists, "文件应该存在")
        
        -- 测试文件读取
        local content, err = file_utils.read_file(test_file)
        test_runner.assert_nil(err, "读取文件不应该有错误: " .. tostring(err))
        test_runner.assert_equal(content, test_content, "读取的内容应该与写入的内容一致")
        
        -- 清理测试文件
        os.remove(test_file)
    end, "测试文件工具函数")
    
    suite:add_test("JSON工具函数测试", function()
        local loaded, json_utils = pcall(require, "NeoAI.utils.json")
        
        if not loaded then
            print("  ⏭️  JSON工具函数模块不存在，跳过测试")
            return
        end
        
        test_runner.assert_type(json_utils, "table", "JSON工具函数应该是table类型")
        
        -- 检查必要的函数
        test_runner.assert_type(json_utils.encode, "function", "应该有encode函数")
        test_runner.assert_type(json_utils.decode, "function", "应该有decode函数")
        
        -- 测试编码
        local test_table = {
            name = "NeoAI",
            version = "1.0",
            features = {"AI", "Testing", "Tools"},
            enabled = true
        }
        
        local json_str = json_utils.encode(test_table)
        test_runner.assert_type(json_str, "string", "编码结果应该是字符串")
        test_runner.assert_not_equal(json_str, "", "编码结果不应该为空")
        
        -- 测试解码
        local decoded_table, err = json_utils.decode(json_str)
        test_runner.assert_nil(err, "解码不应该有错误: " .. tostring(err))
        test_runner.assert_type(decoded_table, "table", "解码结果应该是table类型")
        test_runner.assert_equal(decoded_table.name, "NeoAI", "解码后的name应该匹配")
        test_runner.assert_equal(decoded_table.version, "1.0", "解码后的version应该匹配")
        test_runner.assert_equal(decoded_table.enabled, true, "解码后的enabled应该匹配")
        
        -- 测试无效JSON解码
        local invalid_json = "{invalid json}"
        local result, invalid_err = json_utils.decode(invalid_json)
        test_runner.assert_nil(result, "无效JSON应该返回nil")
        test_runner.assert_not_nil(invalid_err, "无效JSON应该返回错误信息")
    end, "测试JSON编码和解码功能")
end

-- 导出模块
return M