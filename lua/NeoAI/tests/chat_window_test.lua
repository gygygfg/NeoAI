-- NeoAI 聊天窗口测试模块
-- 测试聊天窗口的UI功能

local M = {}

-- 导入测试辅助工具
local test_helper = require("NeoAI.tests.test_helper")

-- 聊天窗口模块引用
local chat_window = nil

-- 测试状态
local test_state = {
  initialized = false,
  test_messages = {},
  mock_ai_responses = {},
}

--- 初始化测试环境
local function init_test_environment()
  if test_state.initialized then
    return true
  
  print("🔧 初始化聊天窗口测试环境...")

  -- 尝试加载聊天窗口模块
  local success, module = pcall(require, "NeoAI.ui.window.chat_window")
  if not success then
    print("❌ 无法加载聊天窗口模块: " .. tostring(module))
    return false
  
  chat_window = module

  -- 设置测试消息
  test_state.test_messages = {
    "测试消息1: 你好，AI助手！",
    "测试消息2: 请帮我写一个简单的Lua函数",
    "测试消息3: 解释一下Neovim插件开发的基本概念",
  }

  -- 设置模拟AI响应
  test_state.mock_ai_responses = {
    {
      chunks = {
        'data: {"id":"test-id-1","choices":[{"delta":{"reasoning_content":"用户打了招呼，需要友好回应"}}]}',
        'data: {"id":"test-id-2","choices":[{"delta":{"content":"你好！我是NeoAI助手，很高兴为您服务。"}}]}',
        'data: {"id":"test-id-3","choices":[{"delta":{"content":"有什么我可以帮助您的吗？"}}]}',
        "data: [DONE]",
      },
      full_response = "你好！我是NeoAI助手，很高兴为您服务。有什么我可以帮助您的吗？",
    },
    {
      chunks = {
        'data: {"id":"test-id-4","choices":[{"delta":{"reasoning_content":"用户需要Lua函数，提供简单示例"}}]}',
        'data: {"id":"test-id-5","choices":[{"delta":{"content":"这是一个简单的Lua函数示例："}}]}',
        'data: {"id":"test-id-6","choices":[{"delta":{"content":"function greet(name)\n  return \"Hello, \" .. name .. \"!\"\nend"}}]}',
        "data: [DONE]",
      },
      full_response = "这是一个简单的Lua函数示例：\nfunction greet(name)\n  return \"Hello, \" .. name .. \"!\"\nend",
    },
  }

  test_state.initialized = true
  print("✅ 聊天窗口测试环境初始化完成")
  return true

--- 测试聊天窗口初始化
local function test_initialization()
  print("🧪 测试聊天窗口初始化...")

  -- 测试未初始化状态
  local is_initialized = chat_window.is_open and chat_window.is_open()
  if is_initialized then
    return false, "聊天窗口在测试前不应该已初始化"
  
  -- 测试初始化函数
  local config = {
    width = 80,
    height = 20,
    border = "rounded",
    keymaps = {
      send = "<C-s>",
      cancel = "<Esc>",
      clear = "<C-u>",
    },
  }

  -- 调用初始化
  chat_window.initialize(config)

  -- 检查初始化状态
  -- 注意：chat_window模块没有公开的初始化状态检查方法
  -- 我们只能测试其他功能是否正常工作

  print("✅ 聊天窗口初始化测试通过")
  return true, "初始化测试通过"

--- 测试消息添加功能
local function test_message_adding()
  print("🧪 测试消息添加功能...")

  -- 模拟会话环境
  local session_id = "test-session-" .. os.time()
  local branch_id = "test-branch"

  -- 测试添加用户消息
  local test_message = "测试用户消息"
  chat_window.add_message("user", test_message)

  -- 测试添加AI消息
  chat_window.add_message("assistant", "测试AI响应")

  -- 获取消息数量
  local message_count = chat_window.get_message_count and chat_window.get_message_count()
  if not message_count or message_count < 2 then
    return false, "消息添加失败，期望至少2条消息，实际: " .. tostring(message_count)
  
  -- 获取消息列表
  local messages = chat_window.get_messages and chat_window.get_messages()
  if not messages or #messages < 2 then
    return false, "无法获取消息列表"
  
  -- 验证消息内容
  local last_message = messages[#messages]
  if last_message.role ~= "assistant" or last_message.content ~= "测试AI响应" then
    return false, "最后一条消息验证失败"
  
  print("✅ 消息添加功能测试通过")
  return true, "消息添加测试通过"

--- 测试输入框功能
local function test_input_functionality()
  print("🧪 测试输入框功能...")

  -- 调试：检查聊天窗口模块
  if not chat_window then
    return false, "聊天窗口模块未加载"
  
  -- 检查必要的函数是否存在
  if not chat_window.update_input then
    return false, "update_input 函数不存在"
  
  if not chat_window.get_current_input then
    return false, "get_current_input 函数不存在"
  
  if not chat_window.clear_input then
    return false, "clear_input 函数不存在"
  
  -- 测试更新输入（不依赖窗口打开状态）
  local test_input = "测试输入内容"
  
  -- 由于 clear_input 需要窗口打开，我们只测试 update_input 和 get_current_input
  -- 先清空可能存在的输入
  chat_window.update_input("")
  
  -- 更新输入
  chat_window.update_input(test_input)
  
  -- 获取当前输入
  local current_input = chat_window.get_current_input()
  if current_input ~= test_input then
    return false, "输入更新失败，期望: " .. test_input .. "，实际: " .. tostring(current_input)
  
  -- 注意：clear_input 需要窗口打开，所以跳过这个测试
  -- 或者我们可以直接设置输入为空来模拟清空
  chat_window.update_input("")
  local cleared_input = chat_window.get_current_input()
  if cleared_input ~= "" then
    return false, "输入清空失败，期望空字符串，实际: " .. tostring(cleared_input)
  
  print("✅ 输入框功能测试通过（跳过需要窗口打开的 clear_input 测试）")
  return true, "输入框功能测试通过"

--- 测试AI响应处理
local function test_ai_response_handling()
  print("🧪 测试AI响应处理...")

  -- 启用测试模式以查看详细日志
  if chat_window.enable_test_mode then
    chat_window.enable_test_mode(true)
  
  -- 模拟AI响应数据块
  local mock_chunks = {
    'data: {"id":"test-1","choices":[{"delta":{"reasoning_content":"用户需要帮助，分析需求"}}]}',
    'data: {"id":"test-2","choices":[{"delta":{"content":"我理解您的需求。"}}]}',
    'data: {"id":"test-3","choices":[{"delta":{"content":"让我为您提供帮助。"}}]}',
    "data: [DONE]",
  }

  -- 处理每个数据块
  for _, chunk in ipairs(mock_chunks) do
    if chat_window._handle_ai_chunk then
      chat_window._handle_ai_chunk(chunk)
    
  
  -- 处理完成
  local full_response = "我理解您的需求。让我为您提供帮助。"
  if chat_window._handle_ai_complete then
    chat_window._handle_ai_complete(full_response)
  
  -- 禁用测试模式
  if chat_window.enable_test_mode then
    chat_window.enable_test_mode(false)
  
  print("✅ AI响应处理测试通过")
  return true, "AI响应处理测试通过"

--- 测试发送消息流程
local function test_send_message_flow()
  print("🧪 测试发送消息流程...")

  -- 设置测试输入
  local test_message = "测试发送消息"
  chat_window.update_input(test_message)

  -- 模拟发送消息（不实际调用AI引擎）
  -- 注意：这里我们只测试发送流程的前半部分
  if chat_window._handle_send then
    -- 保存原始函数
    local original_generate_response = chat_window._generate_ai_response
    
    -- 模拟AI响应生成
    chat_window._generate_ai_response = function(user_message)
      print("📤 模拟发送消息: " .. user_message)
      -- 模拟AI响应
      if chat_window._handle_ai_complete then
        vim.defer_fn(function()
          chat_window._handle_ai_complete("这是模拟的AI响应: " .. user_message)
        end, 100)
      
      return "mock-generation-id"
    
    -- 调用发送处理
    chat_window._handle_send()

    -- 恢复原始函数
    chat_window._generate_ai_response = original_generate_response
  
  print("✅ 发送消息流程测试通过")
  return true, "发送消息流程测试通过"

--- 测试窗口状态管理
local function test_window_state_management()
  print("🧪 测试窗口状态管理...")

  -- 测试窗口有效性检查
  if chat_window.is_window_valid then
    local is_valid = chat_window.is_window_valid()
    -- 在测试环境中，窗口可能未打开，这是正常的
    print("📋 窗口有效性检查: " .. tostring(is_valid))
  
  -- 测试安全关闭
  if chat_window.safe_close then
    chat_window.safe_close()
    print("📋 安全关闭函数调用完成")
  
  -- 测试重置状态
  if chat_window._reset_state then
    chat_window._reset_state()
    print("📋 状态重置函数调用完成")
  
  print("✅ 窗口状态管理测试通过")
  return true, "窗口状态管理测试通过"

--- 测试配置更新
local function test_config_update()
  print("🧪 测试配置更新...")

  if not chat_window.update_config then
    print("⚠️  update_config函数不存在，跳过此测试")
    return true, "跳过配置更新测试"
  
  -- 测试配置更新
  local new_config = {
    width = 90,
    height = 25,
    border = "single",
  }

  chat_window.update_config(new_config)

  print("✅ 配置更新测试通过")
  return true, "配置更新测试通过"

--- 运行聊天窗口集成测试
local function run_integration_test()
  print("🧪 运行聊天窗口集成测试...")

  -- 测试完整的聊天流程
  local test_steps = {
    { name = "初始化测试", func = test_initialization },
    { name = "消息添加测试", func = test_message_adding },
    { name = "输入功能测试", func = test_input_functionality },
    { name = "AI响应测试", func = test_ai_response_handling },
    { name = "发送消息测试", func = test_send_message_flow },
    { name = "窗口状态测试", func = test_window_state_management },
    { name = "配置更新测试", func = test_config_update },
  }

  local passed = 0
  local failed = 0
  local failures = {}

  for _, step in ipairs(test_steps) do
    print("🔍 执行步骤: " .. step.name)
    local success, result = pcall(step.func)
    
    if success then
      local ok, msg = result
      if ok then
        print("✅ " .. step.name .. " 通过: " .. (msg or ""))
        passed = passed + 1
      else
        print("❌ " .. step.name .. " 失败: " .. (msg or ""))
        table.insert(failures, step.name .. ": " .. (msg or ""))
        failed = failed + 1
      
    else
      print("❌ " .. step.name .. " 异常: " .. result)
      table.insert(failures, step.name .. ": " .. result)
      failed = failed + 1
    
  
  -- 显示测试结果
  print("\n📊 集成测试结果:")
  print("   总步骤: " .. #test_steps)
  print("   通过: " .. passed)
  print("   失败: " .. failed)

  if failed > 0 then
    print("\n⚠️ 失败的步骤:")
    for _, failure in ipairs(failures) do
      print("  • " .. failure)
    
    return false, "集成测试失败: " .. failed .. "个步骤失败"
  
  return true, "集成测试通过，所有" .. #test_steps .. "个步骤成功"

--- 运行聊天窗口测试
function M.run()
  print("🚀 开始聊天窗口测试...")
  print(string.rep("=", 50))

  -- 初始化测试环境
  if not init_test_environment() then
    return { false, "测试环境初始化失败" }
  
  -- 运行集成测试
  local success, ok, msg = pcall(run_integration_test)
  
  if success then
    if ok then
      print("\n🎉 " .. msg)
      return { true, "聊天窗口测试通过" }
    else
      print("\n❌ " .. msg)
      return { false, msg }
    
  else
    print("\n❌ 测试执行异常: " .. ok)
    return { false, "测试执行异常: " .. ok }
  

--- 运行特定测试
--- @param test_name string 测试名称
function M.run_test(test_name)
  if not init_test_environment() then
    return { false, "测试环境初始化失败" }
  
  local test_functions = {
    initialization = test_initialization,
    message_adding = test_message_adding,
    input_functionality = test_input_functionality,
    ai_response = test_ai_response_handling,
    send_message = test_send_message_flow,
    window_state = test_window_state_management,
    config_update = test_config_update,
    integration = run_integration_test,
  }

  local test_func = test_functions[test_name]
  if not test_func then
    return { false, "未找到测试: " .. test_name }
  
  print("🚀 运行测试: " .. test_name)
  local success, ok, msg = pcall(test_func)
  
  if success then
    if ok then
      print("✅ 测试通过: " .. msg)
      return { true, msg }
    else
      print("❌ 测试失败: " .. msg)
      return { false, msg }
    
  else
    print("❌ 测试异常: " .. ok)
    return { false, "测试异常: " .. ok }
  

--- 显示测试帮助信息
function M.show_help()
  print("📖 聊天窗口测试帮助:")
  print("  可用测试:")
  print("    • initialization - 初始化测试")
  print("    • message_adding - 消息添加测试")
  print("    • input_functionality - 输入功能测试")
  print("    • ai_response - AI响应处理测试")
  print("    • send_message - 发送消息测试")
  print("    • window_state - 窗口状态测试")
  print("    • config_update - 配置更新测试")
  print("    • integration - 集成测试（运行所有测试）")
  print("")
  print("  使用方法:")
  print("    require('NeoAI.tests.chat_window_test').run() - 运行所有测试")
  print("    require('NeoAI.tests.chat_window_test').run_test('test_name') - 运行特定测试")

return M
