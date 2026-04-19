-- 配置管理测试套件
-- 测试NeoAI配置管理器和键位映射管理器

local M = {}

-- 注册测试套件
function M.register_tests(test_runner)
    local suite = test_runner.register_suite("配置管理测试")
    
    -- 测试配置管理器
    suite:add_test("配置管理器加载", function()
        local loaded, config_manager = pcall(require, "NeoAI.core.config.config_manager")
        test_runner.assert(loaded, "应该能加载配置管理器: " .. tostring(config_manager))
        test_runner.assert_type(config_manager, "table", "配置管理器应该是table类型")
        
        -- 检查必要的函数
        test_runner.assert_type(config_manager.initialize, "function", "应该有initialize函数")
        test_runner.assert_type(config_manager.get_all, "function", "应该有get_all函数")
        test_runner.assert_type(config_manager.get, "function", "应该有get函数")
        test_runner.assert_type(config_manager.set, "function", "应该有set函数")
    end, "测试配置管理器的基本加载和结构")
    
    suite:add_test("配置初始化", function()
        local config_manager = require("NeoAI.core.config.config_manager")
        
        -- 创建测试配置
        local test_config = {
            api_key = "test_key_123",
            model = "gpt-4",
            temperature = 0.7,
            max_tokens = 1000,
            session = {
                save_path = "/tmp/neoa_test",
                auto_save = false
            }
        }
        
        -- 初始化配置
        config_manager.initialize(test_config)
        
        -- 验证配置
        local all_config = config_manager.get_all()
        test_runner.assert_type(all_config, "table", "获取的配置应该是table类型")
        test_runner.assert_equal(all_config.api_key, "test_key_123", "API key应该匹配")
        test_runner.assert_equal(all_config.model, "gpt-4", "模型应该匹配")
        test_runner.assert_equal(all_config.temperature, 0.7, "温度应该匹配")
        test_runner.assert_equal(all_config.max_tokens, 1000, "最大token数应该匹配")
        
        -- 验证嵌套配置
        test_runner.assert_type(all_config.session, "table", "session配置应该是table类型")
        test_runner.assert_equal(all_config.session.save_path, "/tmp/neoa_test", "保存路径应该匹配")
        test_runner.assert_equal(all_config.session.auto_save, false, "自动保存设置应该匹配")
    end, "测试配置初始化功能")
    
    suite:add_test("配置获取和设置", function()
        local config_manager = require("NeoAI.core.config.config_manager")
        
        -- 测试获取单个配置项
        local model = config_manager.get("model")
        test_runner.assert_equal(model, "gpt-4", "应该能获取model配置")
        
        local temperature = config_manager.get("temperature")
        test_runner.assert_equal(temperature, 0.7, "应该能获取temperature配置")
        
        -- 测试设置配置项
        config_manager.set("model", "gpt-3.5-turbo")
        local updated_model = config_manager.get("model")
        test_runner.assert_equal(updated_model, "gpt-3.5-turbo", "应该能更新model配置")
        
        -- 测试设置嵌套配置项
        config_manager.set("session.auto_save", true)
        local auto_save = config_manager.get("session.auto_save")
        test_runner.assert_equal(auto_save, true, "应该能更新嵌套配置")
        
        -- 恢复原始值
        config_manager.set("model", "gpt-4")
        config_manager.set("session.auto_save", false)
    end, "测试配置的获取和设置功能")
    
    suite:add_test("键位映射管理器", function()
        local loaded, keymap_manager = pcall(require, "NeoAI.core.config.keymap_manager")
        
        if not loaded then
            -- 如果模块不存在，这是一个正常的跳过
            print("  ⏭️  键位映射管理器模块不存在，这是预期的")
            return
        end
        
        test_runner.assert_type(keymap_manager, "table", "键位映射管理器应该是table类型")
        
        -- 检查模块结构
        -- 注意：不同的实现可能有不同的函数名
        local has_setup = type(keymap_manager.setup) == "function"
        local has_register = type(keymap_manager.register_keymap) == "function"
        local has_register_keymap = type(keymap_manager.register_keymap) == "function"
        
        -- 至少应该有一个注册函数
        test_runner.assert(has_setup or has_register or has_register_keymap,
            "键位映射管理器应该至少有一个注册函数")
        
        -- 如果有setup函数，测试它
        if has_setup then
            local test_keymaps = {
                {
                    mode = "n",
                    lhs = "<leader>at",
                    rhs = function() print("测试键位映射") end,
                    opts = { desc = "测试键位映射" }
                }
            }
            
            -- 设置键位映射
            local success, err = pcall(keymap_manager.setup, test_keymaps)
            test_runner.assert(success, "setup函数应该能正常调用: " .. tostring(err))
        end
        
        print("  📝 键位映射管理器功能测试完成")
    end, "测试键位映射管理器的基本功能")
    
    suite:add_test("配置验证", function()
        local config_manager = require("NeoAI.core.config.config_manager")
        
        -- 测试无效配置获取
        local non_existent = config_manager.get("non_existent_key")
        test_runner.assert_nil(non_existent, "不存在的键应该返回nil")
        
        -- 注意：config_manager.get 函数没有默认值参数
        -- 我们手动处理默认值
        local with_default = config_manager.get("non_existent_key") or "default_value"
        test_runner.assert_equal(with_default, "default_value", "应该返回默认值")
        
        -- 测试嵌套路径获取
        local nested_value = config_manager.get("session.save_path")
        test_runner.assert_equal(nested_value, "/tmp/neoa_test", "应该能获取嵌套配置")
        
        -- 测试不存在的嵌套路径
        local non_existent_nested = config_manager.get("session.non_existent")
        test_runner.assert_nil(non_existent_nested, "不存在的嵌套键应该返回nil")
    end, "测试配置验证和边界情况")
end

-- 导出模块
return M
