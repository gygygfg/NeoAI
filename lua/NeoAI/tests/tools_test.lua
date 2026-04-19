-- 工具系统测试
-- 测试NeoAI工具执行器、注册表和验证器

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
          off = function() end,
        },
        config = {
          api_key = "test_key",
          model = "test-model",
          temperature = 0.7,
          max_tokens = 1000,
          save_path = "/tmp/neoa_test",
          auto_save = false,
        },
      }
    end,
    cleanup_test_environment = function()
      -- 什么都不做
    end,
  }
  print("⚠️  使用模拟的测试初始化器")

--- 测试工具注册表
local function test_tool_registry()
  print("🔧 测试工具注册表...")

  local loaded, tool_registry = pcall(require, "NeoAI.tools.tool_registry")
  if not loaded then
    return { false, "无法加载工具注册表: " .. tostring(tool_registry) }
  
  -- 在测试环境中模拟 vim 模块
  if not vim then
    vim = {
      notify = function(msg, level)
        print("vim.notify: " .. msg)
      end,
      log = {
        levels = {
          ERROR = 4,
          WARN = 3,
          INFO = 2,
        },
      },
    }
  
  -- 初始化工具注册表
  tool_registry.initialize({})

  -- 测试注册工具
  local test_tool = {
    name = "test_tool",
    description = "测试工具",
    parameters = {
      type = "object",
      properties = {
        message = {
          type = "string",
          description = "测试消息",
        },
      },
      required = { "message" },
    },
    func = function(params)
      return "测试工具执行成功: " .. params.message
    end,
  }

  -- 注册测试工具
  local success, err = pcall(tool_registry.register, test_tool)
  if not success then
    return { false, "注册工具失败: " .. tostring(err) }
  
  -- 获取工具
  local tool = tool_registry.get("test_tool")
  if not tool then
    return { false, "无法获取已注册的工具" }
  
  -- 获取所有工具
  local all_tools = tool_registry.get_all_tools()
  if not all_tools or not all_tools["test_tool"] then
    return { false, "获取所有工具失败" }
  
  -- 清理测试工具
  tool_registry.unregister("test_tool")

  return { true, "工具注册表测试通过" }

--- 测试工具验证器
local function test_tool_validator()
  print("🔍 测试工具验证器...")

  local loaded, tool_validator = pcall(require, "NeoAI.tools.tool_validator")
  if not loaded then
    return { false, "无法加载工具验证器: " .. tostring(tool_validator) }
  
  -- 初始化工具验证器
  tool_validator.initialize({})

  -- 测试有效的工具定义
  local valid_tool = {
    name = "valid_tool",
    description = "有效工具",
    parameters = {
      type = "object",
      properties = {
        input = {
          type = "string",
          description = "输入参数",
        },
      },
      required = { "input" },
    },
    func = function(params)
      return "执行成功"
    end,
  }

  local is_valid, validation_error = tool_validator.validate_schema(valid_tool.parameters)
  if not is_valid then
    return { false, "有效工具验证失败: " .. tostring(validation_error) }
  
  -- 测试无效的工具定义（缺少必需字段）
  local invalid_tool = {
    name = "invalid_tool",
    -- 缺少description字段
    parameters = {
      type = "object",
      properties = {},
    },
    -- 缺少execute函数
  }

  local is_valid, invalid_error = tool_validator.validate_tool(invalid_tool)
  if is_valid then
    return { false, "无效工具应该验证失败" }
  
  -- 测试参数验证
  local tool_with_params = {
    name = "param_tool",
    description = "参数工具",
    parameters = {
      type = "object",
      properties = {
        count = {
          type = "number",
          description = "数量",
          minimum = 1,
          maximum = 10,
        },
        enabled = {
          type = "boolean",
          description = "是否启用",
        },
      },
      required = { "count" },
    },
    func = function(params)
      return "参数验证通过"
    end,
  }

  -- 验证有效参数
  local valid_params = { count = 5, enabled = true }
  local params_valid, params_error = tool_validator.validate_parameters(tool_with_params.parameters, valid_params)
  if not params_valid then
    return { false, "有效参数验证失败: " .. tostring(params_error) }
  
  -- 验证无效参数（超出范围）
  local invalid_params = { count = 15, enabled = true }
  local is_valid, invalid_params_error = tool_validator.validate_parameters(tool_with_params.parameters, invalid_params)
  if is_valid then
    return { false, "无效参数应该验证失败" }
  
  return { true, "工具验证器测试通过" }

--- 测试工具执行器
local function test_tool_executor()
  print("⚡ 测试工具执行器...")

  local loaded, tool_executor = pcall(require, "NeoAI.tools.tool_executor")
  if not loaded then
    return { false, "无法加载工具执行器: " .. tostring(tool_executor) }
  
  -- 初始化工具验证器
  local tool_validator = require("NeoAI.tools.tool_validator")
  tool_validator.initialize({})

  -- 初始化工具执行器
  tool_executor.initialize({})

  -- 创建测试工具
  local test_tool = {
    name = "echo_tool",
    description = "回显工具",
    parameters = {
      type = "object",
      properties = {
        text = {
          type = "string",
          description = "要回显的文本",
        },
        message = {
          type = "string",
          description = "要回显的消息",
        },
      },
      required = {},
    },
    func = function(params)
      local input = params.text or params.message
      if not input then
        return "错误: 请提供 text 或 message 参数"
      
      return "回显: " .. input
    end,
  }

  -- 注册测试工具
  local tool_registry = require("NeoAI.tools.tool_registry")
  tool_registry.initialize({})
  tool_registry.register(test_tool)

  -- 测试同步执行
  local result = tool_executor.execute("echo_tool", { text = "Hello World" })
  if result ~= "回显: Hello World" then
    return { false, "工具执行结果不正确: " .. tostring(result) }
  
  -- 测试异步执行（如果支持）
  if tool_executor.execute_tool_async then
    local async_success, async_result = pcall(function()
      return tool_executor.execute_tool_async(test_tool, { text = "Async Test" })
    end)

    if async_success and async_result then
      print("✅ 异步工具执行测试通过")
    
  
  -- 测试错误处理
  local error_tool = {
    name = "error_tool",
    description = "错误工具",
    parameters = {
      type = "object",
      properties = {},
    },
    func = function(params)
      error("故意抛出错误")
    end,
  }

  -- 注册错误工具
  tool_registry.register(error_tool)

  -- 注意：tool_executor.execute 返回错误消息而不是抛出异常
  -- 所以我们需要检查返回的结果是否包含错误
  local result = tool_executor.execute("error_tool", {})
  if not result or not string.find(result, "错误") then
    return { false, "错误工具应该返回错误消息，实际返回: " .. tostring(result) }
  
  return { true, "工具执行器测试通过" }

--- 测试内置文件工具
local function test_builtin_file_tools()
  print("📁 测试内置文件工具...")

  local loaded, file_tools = pcall(require, "NeoAI.tools.builtin.file_tools")
  if not loaded then
    return { false, "无法加载文件工具: " .. tostring(file_tools) }
  
  -- 检查工具列表
  local tools = file_tools.get_tools()
  if not tools or type(tools) ~= "table" then
    return { false, "文件工具列表不存在或不是table" }
  
  -- 检查是否有read_file工具
  local has_read_file = false
  for _, tool in ipairs(tools) do
    if tool.name == "read_file" then
      has_read_file = true
      break
    
  
  if not has_read_file then
    return { false, "缺少read_file工具" }
  
  -- 检查是否有write_file工具
  local has_write_file = false
  for _, tool in ipairs(tools) do
    if tool.name == "write_file" then
      has_write_file = true
      break
    
  
  if not has_write_file then
    return { false, "缺少write_file工具" }
  
  return { true, "内置文件工具测试通过" }

--- 运行所有工具测试
function M.run()
  print("🔧 开始运行工具系统测试...")
  print(string.rep("=", 50))

  -- 初始化测试环境
  local test_env = test_initializer.initialize_test_environment()

  local tests = {
    { name = "工具注册表", func = test_tool_registry },
    { name = "工具验证器", func = test_tool_validator },
    { name = "工具执行器", func = test_tool_executor },
    { name = "内置文件工具", func = test_builtin_file_tools },
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
  print("📊 工具系统测试总结:")
  print("   总测试数: " .. #tests)
  print("   通过: " .. passed)
  print("   失败: " .. failed)
  print("   通过率: " .. string.format("%.1f%%", (passed / #tests) * 100))

  -- 清理测试环境
  test_initializer.cleanup_test_environment()

  if passed == #tests then
    return { true, "所有工具系统测试通过" }
  else
    return { false, "有 " .. failed .. " 个工具系统测试失败" }
  

return M

