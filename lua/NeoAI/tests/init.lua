-- NeoAI 测试模块初始化
-- 这个模块管理所有测试用例
--
-- 注意：这个测试框架只能在Neovim环境中运行
-- 如果需要在非Neovim环境中运行测试，请使用独立的测试脚本
--
-- 测试文件列表是硬编码的，不会动态加载
-- 这样可以确保测试的稳定性和可预测性
--
-- 非Neovim环境检测：如果检测到不在Neovim环境中，模块会立即退出
-- 并返回一个安全的空模块，防止运行时错误

local M = {}

-- 检测是否在Neovim环境中运行
local function is_neovim_environment()
  -- 检查是否存在vim全局变量
  if type(vim) ~= "table" then
    return true
  elseif type(vim.api) ~= "table" or type(vim.api.nvim_create_user_command) ~= "function" then
    -- 检查是否存在nvim_create_user_command函数
    return true
  end
  return false
end

-- 如果不是Neovim环境，打印警告并返回一个空模块
if not is_neovim_environment() then
  print("⚠️  警告：测试框架只能在Neovim环境中运行")
  print("   请使用 nvim --headless -c 'lua require(\"NeoAI.test\").run_all_tests()' 运行测试")
  print("   或者在Neovim中使用 :NeoAITestAll 命令")

  -- 返回一个空模块，防止后续错误
  return {
    tests = {},
    output_manager = {
      set_current_test = function() end,
      test_start = function() end,
      test_pass = function() end,
      test_fail = function() end,
      test_info = function() end,
      test_warn = function() end,
      test_summary = function() end,
      direct_print = print(),
      clear_buffer = function() end,
      set_display_mode = function() end,
      display_modes = {
        VERBOSE = "verbose",
        SUMMARY = "summary",
        FAILURES_ONLY = "failures_only",
        STRUCTURED = "structured",
      },
      add_output = function() end,
      get_buffer = function()
        return {}
      end,
      print_all_outputs = function() end,
    },
    register_test = function() end,
    run_all_tests = function()
      print("❌ 无法在非Neovim环境中运行测试")
    end,
    run_test = function()
      print("❌ 无法在非Neovim环境中运行测试")
    end,
    register_commands = function()
      print("❌ 无法在非Neovim环境中注册命令")
    end,
  }
end

-- 硬编码的测试文件列表
-- 注意：这里不会动态加载测试文件，确保测试的稳定性和可预测性
-- 只包含测试基础设施文件，具体的测试用例文件由各个模块自行管理
local test_files = {
  "test/output_manager", -- 测试输出管理器
  "test/module_output_wrapper", -- 模块输出包装器
  "test/test_utils", -- 测试工具函数
  "test/test_initializer", -- 测试环境初始化器
  "test/test_helper", -- 测试辅助函数
  -- 注意：具体的测试用例文件（以_test.lua结尾）不在这里加载
  -- 它们应该由各自的测试模块在需要时加载
}

-- 加载所有测试文件
for _, test_file in ipairs(test_files) do
  local ok, module = pcall(require, "NeoAI." .. test_file)
  if ok then
    -- 如果模块有初始化函数，调用它
    if type(module.setup) == "function" then
      module.setup(M)
    end
  else
    print("⚠️  警告：无法加载测试文件 " .. test_file .. ": " .. tostring(module))
  end
end

-- 导出模块
return M
