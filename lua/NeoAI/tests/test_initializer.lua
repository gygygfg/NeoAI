-- 测试初始化器
-- 为测试环境初始化所有NeoAI模块

local test_utils = require("NeoAI.tests.test_utils")
local M = {}

--- 初始化测试环境
--- @param config table|nil 可选配置，如果为nil则使用默认配置
function M.initialize_test_environment(config)
    print("🔧 初始化测试环境...")
    
    -- 创建模拟事件总线
    local mock_event_bus = {
        listeners = {}
    }
    
    -- 定义事件总线方法（使用闭包访问 mock_event_bus）
    function mock_event_bus.emit(event, ...)
        -- 模拟事件触发
        local listeners = mock_event_bus.listeners[event] or {}
        for _, listener in ipairs(listeners) do
            pcall(listener, ...)
        
    
    function mock_vim.api.nvim_create_autocmd("User", {pattern = event, callback)
        if not mock_event_bus.listeners[event] then
            mock_event_bus.listeners[event] = {})
        
        table.insert(mock_event_bus.listeners[event], callback)
    
    function mock_event_bus.off(event, callback)
        if mock_event_bus.listeners[event] then
            for i, listener in ipairs(mock_event_bus.listeners[event]) do
                if listener == callback then
                    table.remove(mock_event_bus.listeners[event], i)
                    break
                
            
        
    
    -- 使用传入的配置或默认配置
    local default_config_module = require("NeoAI.default_config")
    
    -- 首先验证和合并配置，确保与主 init.lua 使用相同的逻辑
    local validated_config = default_config_module.validate_config(config or {})
    local merged_config = default_config_module.merge_defaults(validated_config)
    local sanitized_config = default_config_module.sanitize_config(merged_config)
    
    -- 使用完整的配置结构，确保与主 init.lua 一致
    local test_config = vim.deepcopy(sanitized_config)
    
    -- 覆盖测试特定的配置
    test_config.ai = test_config.ai or {}
    test_config.ai.api_key = "test_key"
    test_config.ai.model = "test-model"
    test_config.ai.temperature = 0.7
    test_config.ai.max_tokens = 1000
    
    -- 确保会话配置存在
    test_config.session = test_config.session or {}
    test_config.session.auto_save = false  -- 测试中默认关闭自动保存
    test_config.session.max_history_per_session = test_config.session.max_history_per_session or 50
    
    -- 使用主配置合并后的配置，不自定义临时目录
    -- 测试环境使用默认的 save_path 配置
    -- 如果需要隔离测试数据，可以在测试前清理目录
    if test_config.session and test_config.session.save_path then
        -- 确保目录存在
        if not vim.fn.isdirectory(test_config.session.save_path) then
            vim.fn.mkdir(test_config.session.save_path, "p")
        
    
    -- 标记为测试配置
    test_config._is_test_config = true
    
    -- 添加调试信息，标记配置来源
    test_config._debug_source = "test_initializer"
    test_config._debug_timestamp = os.time()
    
    -- 保存配置的保存路径
    M._last_config_save_path = test_config.session.save_path
    
    -- 使用模拟事件总线（因为实际模块可能不存在）
    local event_bus = mock_event_bus
    
    -- 创建模拟会话管理器
    local session_manager = {
        initialize = function() return true end,
        create_session = function() return { id = "test_session" } end,
        get_session = function() return { id = "test_session" } 
    }
    
    -- 创建模拟工具系统
    local tool_registry = {
        initialize = function() return true end,
        register_tool = function() return true 
    }
    
    local tool_validator = {
        initialize = function() return true end,
        validate_tool = function() return true 
    }
    
    local tool_executor = {
        initialize = function() return true end,
        execute_tool = function() return { success = true } 
    }
    
    -- 创建模拟AI引擎
    local ai_engine = {
        initialize = function() return true end,
        reset_state = function() return true end,
        generate_response = function() 
            -- 返回正确的JSON格式响应
            return {
                choices = {
                    {
                        message = {
                            content = "这是一个模拟的AI响应"
                        }
                    }
                }
            }
        
    }
    
    -- 创建模拟UI组件
    local window_manager = {
        initialize = function() return true end,
        create_window = function() return { id = "test_window" } 
    }
    
    -- 创建模拟UI模块
    local ui_module = {
        _state = {
            initialized = true,
            config = test_config,
            windows = {},
            current_ui_mode = nil,
            event_count = 0
        },
        initialize = function(config)
            ui_module._state.config = config or {}
            ui_module._state.initialized = true
            return ui_module
        end,
        open_chat = function()
            return { success = true, window_id = "test_chat_window" }
        end,
        open_tree = function()
            return { success = true, window_id = "test_tree_window" }
        end,
        close_all = function()
            return { success = true }
        
    }
    
    print("✅ 测试环境初始化完成")
    
    return {
        event_bus = event_bus,
        config = test_config,
        session_manager = session_manager,
        ai_engine = ai_engine,
        ui = ui_module
    }

--- 清理测试环境
function M.cleanup_test_environment()
    print("🧹 清理测试环境...")
    
    -- 注意：不再自动清理测试目录
    -- 每个测试应该自己负责清理它创建的临时目录
    -- 这样可以避免在验证持久化之前就清理目录的问题
    
    -- 只清理标记为测试配置的目录
    if M._last_config_save_path and M._last_config_save_path:match("/neoai_sessions$") then
        print("⚠️  注意：测试使用了主配置的会话目录: " .. M._last_config_save_path)
        print("   如果需要清理测试数据，请手动删除该目录")
    
    print("✅ 测试环境清理完成（不自动清理临时目录）")

--- 运行测试初始化器测试
function M.run()
    print("🔧 测试初始化器功能...")
    
    -- 测试环境初始化
    local env = M.initialize_test_environment()
    if not env then
        return {false, "测试环境初始化失败"}
    
    -- 检查环境结构
    if not env.event_bus or not env.config then
        return {false, "测试环境结构不完整"}
    
    -- 清理测试环境
    M.cleanup_test_environment()
    
    return {true, "测试初始化器功能正常"}

return M
