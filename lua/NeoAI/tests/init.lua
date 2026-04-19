-- NeoAI 测试模块
-- 统一的测试框架入口，所有功能整合在一个文件中

local M = {}

-- ============================================================================
-- 第一部分：环境检测和兼容性
-- ============================================================================

--- 检测是否在Neovim环境中运行
local function is_neovim_environment()
  return type(vim) == "table" and type(vim.api) == "table" and type(vim.api.nvim_create_user_command) == "function"
end

--- 获取安全模块（用于非Neovim环境）
local function get_safe_module()
  return {
    run_all = function()
      print("❌ 无法在非Neovim环境中运行测试")
    end,
    run_suite = function()
      print("❌ 无法在非Neovim环境中运行测试")
    end,
    register_commands = function()
      print("❌ 无法在非Neovim环境中注册命令")
    end,
  }
end

-- 如果不是Neovim环境，返回一个安全的空模块
if not is_neovim_environment() then
  print("⚠️  警告：测试框架只能在Neovim环境中运行")
  print("   请使用以下命令运行测试：")
  print("   nvim --headless -c 'lua require(\"NeoAI.tests\").run_all()'")
  print("   或者在Neovim中使用 :NeoAITest 命令")

  return get_safe_module()
end

-- ============================================================================
-- 第二部分：测试结果枚举和结构定义
-- ============================================================================

M.TestResult = {
  PASS = "PASS",
  FAIL = "FAIL",
  SKIP = "SKIP",
  ERROR = "ERROR",
}

-- 测试用例结构
local TestCase = {}
TestCase.__index = TestCase

function TestCase.new(name, func, description)
  local self = setmetatable({}, TestCase)
  self.name = name
  self.func = func
  self.description = description or ""
  self.result = M.TestResult.SKIP
  self.error_message = nil
  self.duration = 0
  return self
end

-- 测试套件结构
local TestSuite = {}
TestSuite.__index = TestSuite

function TestSuite.new(name)
  local self = setmetatable({}, TestSuite)
  self.name = name
  self.tests = {}
  self.before_each = nil
  self.after_each = nil
  self.before_all = nil
  self.after_all = nil
  return self
end

function TestSuite:add_test(name, func, description)
  table.insert(self.tests, TestCase.new(name, func, description))
end

function TestSuite:run()
  local results = {
    total = 0,
    passed = 0,
    failed = 0,
    skipped = 0,
    errored = 0,
    tests = {},
  }

  -- 运行 before_all 钩子
  if self.before_all then
    local success, err = pcall(self.before_all)
    if not success then
      print("❌ 测试套件 " .. self.name .. " 的 before_all 钩子失败: " .. err)
    end
  end

  -- 运行所有测试
  for _, test in ipairs(self.tests) do
    results.total = results.total + 1

    -- 运行 before_each 钩子
    if self.before_each then
      local success, err = pcall(self.before_each)
      if not success then
        test.result = M.TestResult.ERROR
        test.error_message = "before_each 钩子失败: " .. err
        results.errored = results.errored + 1
        table.insert(results.tests, test)
        goto continue
      end
    end

    -- 运行测试
    local start_time = os.clock()
    local success, err = pcall(test.func)
    test.duration = os.clock() - start_time

    if success then
      test.result = M.TestResult.PASS
      results.passed = results.passed + 1
    else
      test.result = M.TestResult.FAIL
      test.error_message = err
      results.failed = results.failed + 1
    end

    -- 运行 after_each 钩子
    if self.after_each then
      local success, err = pcall(self.after_each)
      if not success then
        print("⚠️  测试 " .. test.name .. " 的 after_each 钩子失败: " .. err)
      end
    end

    table.insert(results.tests, test)
    ::continue::
  end

  -- 运行 after_all 钩子
  if self.after_all then
    local success, err = pcall(self.after_all)
    if not success then
      print("❌ 测试套件 " .. self.name .. " 的 after_all 钩子失败: " .. err)
    end
  end

  return results
end

-- ============================================================================
-- 第三部分：测试运行器功能
-- ============================================================================

M.test_suites = {}

--- 注册测试套件
function M.register_suite(name)
  local suite = TestSuite.new(name)
  M.test_suites[name] = suite
  return suite
end

--- 获取测试套件
function M.get_suite(name)
  return M.test_suites[name]
end

-- ============================================================================
-- 第四部分：断言函数
-- ============================================================================

--- 基础断言
function M.assert(condition, message)
  if not condition then
    error(message or "断言失败")
  end
end

--- 相等断言
function M.assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: 期望 %s，实际 %s", message or "断言失败", tostring(expected), tostring(actual)))
  end
end

--- 不等断言
function M.assert_not_equal(actual, expected, message)
  if actual == expected then
    error(string.format("%s: 值不应相等，实际 %s", message or "断言失败", tostring(actual)))
  end
end

--- nil断言
function M.assert_nil(value, message)
  if value ~= nil then
    error(string.format("%s: 期望 nil，实际 %s", message or "断言失败", tostring(value)))
  end
end

--- 非nil断言
function M.assert_not_nil(value, message)
  if value == nil then
    error(message or "断言失败: 值不应为 nil")
  end
end

--- 类型断言
function M.assert_type(value, expected_type, message)
  if type(value) ~= expected_type then
    error(string.format("%s: 期望类型 %s，实际类型 %s", message or "断言失败", expected_type, type(value)))
  end
end

--- 否定断言
function M.assert_not(condition, message)
  if condition then
    error(message or "断言失败: 条件不应该为真")
  end
end

--- 表格包含断言
function M.assert_table_contains(table, key, message)
  if table[key] == nil then
    error(string.format("%s: 表中缺少键 %s", message or "断言失败", tostring(key)))
  end
end

--- 表格相等断言（浅比较）
function M.assert_table_equal(expected, actual, message)
  for k, v in pairs(expected) do
    if actual[k] ~= v then
      error(
        string.format(
          "表格断言失败: 键 %s 期望 %s, 实际 %s. %s",
          tostring(k),
          tostring(v),
          tostring(actual[k]),
          message or ""
        )
      )
    end
  end

  for k, v in pairs(actual) do
    if expected[k] == nil then
      error(
        string.format(
          "表格断言失败: 键 %s 在期望表格中不存在, 实际值为 %s. %s",
          tostring(k),
          tostring(v),
          message or ""
        )
      )
    end
  end
end

-- ============================================================================
-- 第五部分：测试辅助函数
-- ============================================================================

--- 模拟函数
function M.mock_function(original, mock)
  return function(...)
    return mock(...)
  end
end

--- 增强版模拟函数
function M.mock_function_advanced(func, returns)
  local call_count = 0
  local call_args = {}

  local mock_func = function(...)
    call_count = call_count + 1
    call_args[call_count] = { ... }

    if returns then
      local result = returns[call_count] or returns[#returns]
      if type(result) == "function" then
        return result(...)
      else
        return unpack(result or {})
      end
    end

    return nil
  end

  -- 创建一个表来包装函数和它的方法
  local mock = {
    func = mock_func,
    get_call_count = function()
      return call_count
    end,
    get_call_args = function(index)
      if index then
        return call_args[index]
      end
      return call_args
    end
  }

  -- 设置元表，使mock表可以像函数一样被调用
  setmetatable(mock, {
    __call = function(self, ...)
      return self.func(...)
    end
  })

  return mock
end

--- 间谍函数
function M.spy_on(obj, method_name)
  local original = obj[method_name]
  local call_count = 0
  local last_args = nil
  local last_return = nil

  obj[method_name] = function(...)
    call_count = call_count + 1
    last_args = { ... }
    last_return = original(...)
    return last_return
  end

  return {
    get_call_count = function()
      return call_count
    end,
    get_last_args = function()
      return last_args
    end,
    get_last_return = function()
      return last_return
    end,
    restore = function()
      obj[method_name] = original
    end,
  }
end

-- ============================================================================
-- 第六部分：测试环境工具
-- ============================================================================

--- 清理所有测试目录
function M.cleanup_all_test_dirs()
  print("🧹 清理所有测试目录...")

  -- 获取缓存目录
  local cache_dir = vim.fn.stdpath("cache")

  -- 定义要清理的测试目录模式
  local test_dirs = {
    cache_dir .. "/neoai_test_*",
    cache_dir .. "/neoai_sessions_test",
    cache_dir .. "/neoai_temp_*",
  }

  -- 清理每个目录
  for _, dir_pattern in ipairs(test_dirs) do
    local dirs = vim.fn.glob(dir_pattern, true, true)
    for _, dir in ipairs(dirs) do
      if vim.fn.isdirectory(dir) == 1 then
        -- 使用系统命令删除目录
        local cmd = string.format("rm -rf %s", vim.fn.shellescape(dir))
        os.execute(cmd)
        print("  删除目录: " .. dir)
      end
    end
  end

  -- 清理测试文件
  local test_files = {
    cache_dir .. "/test_*.lua",
    cache_dir .. "/test_*.json",
    cache_dir .. "/test_*.txt",
  }

  for _, file_pattern in ipairs(test_files) do
    local files = vim.fn.glob(file_pattern, true, true)
    for _, file in ipairs(files) do
      if vim.fn.filereadable(file) == 1 then
        os.remove(file)
        print("  删除文件: " .. file)
      end
    end
  end

  print("✅ 所有测试目录清理完成")
end

--- 安全清理测试目录
function M.safe_cleanup_test_dir(dir_path)
  if dir_path and vim.fn.isdirectory(dir_path) == 1 then
    -- 检查是否是测试目录（避免误删重要目录）
    if dir_path:match("/neoai_test_") or dir_path:match("/neoa_test_") then
      -- 使用系统命令删除目录
      local cmd = string.format("rm -rf %s", vim.fn.shellescape(dir_path))
      os.execute(cmd)
      print("🧹 安全清理测试目录: " .. dir_path)
    else
      print("⚠️  跳过非测试目录: " .. dir_path)
    end
  end
end

--- 清理单个临时目录
function M.cleanup_temp_dir(dir_path)
  if dir_path and vim.fn.isdirectory(dir_path) == 1 then
    -- 使用系统命令删除目录
    local cmd = string.format("rm -rf %s", vim.fn.shellescape(dir_path))
    os.execute(cmd)
    print("🧹 清理临时目录: " .. dir_path)
  end
end

--- 创建临时测试目录
function M.create_temp_test_dir(prefix)
  local cache_dir = vim.fn.stdpath("cache")
  local timestamp = os.time()
  local random_suffix = math.random(1000, 9999)
  local dir_name = string.format("%s_test_%s_%d", prefix or "neoai", timestamp, random_suffix)
  local dir_path = cache_dir .. "/" .. dir_name

  -- 创建目录
  vim.fn.mkdir(dir_path, "p")

  return dir_path
end

--- 创建临时测试文件
function M.create_temp_test_file(dir_path, filename, content)
  local file_path = dir_path .. "/" .. filename
  local file = io.open(file_path, "w")
  if file then
    file:write(content or "")
    file:close()
    return file_path
  end

  return nil
end

--- 运行测试套件（简化版）
function M.run_test_suite(tests, setup, teardown)
  local passed = 0
  local failed = 0

  for name, test_func in pairs(tests) do
    print("🧪 运行测试: " .. name)

    -- 执行设置函数
    if setup then
      pcall(setup)
    end

    -- 执行测试
    local success, err = pcall(test_func)

    -- 执行清理函数
    if teardown then
      pcall(teardown)
    end

    if success then
      print("✅ 测试通过: " .. name)
      passed = passed + 1
    else
      print("❌ 测试失败: " .. name)
      print("   错误: " .. tostring(err))
      failed = failed + 1
    end
  end

  print(string.format("📊 测试结果: %d 通过, %d 失败", passed, failed))

  return passed, failed
end

--- 获取测试配置
function M.get_test_config()
  return {
    ai = {
      api_key = "test_key",
      model = "test-model",
      temperature = 0.7,
      max_tokens = 1000,
    },
    session = {
      auto_save = true,
      max_history_per_session = 50,
      save_path = vim.fn.stdpath("cache") .. "/neoai_sessions_test",
    },
    ui = {
      window = {
        width = 80,
        height = 20,
      },
    },
    _debug_source = "NeoAI.tests.init",
    _debug_timestamp = os.time(),
  }
end

-- ============================================================================
-- 第七部分：Neovim 模拟环境
-- ============================================================================

--- 设置 Neovim 模拟环境
function M.setup_mock_neovim()
  print("🔧 设置Neovim模拟环境")

  -- 模拟 vim 全局变量
  if not vim then
    _G.vim = {}
  end

  -- 模拟 vim.api
  if not vim.api then
    vim.api = {}
  end

  -- 模拟 vim.api.nvim_create_user_command
  vim.api.nvim_create_user_command = function(name, command, opts)
    print(string.format("[模拟] 创建用户命令: %s", name))
    return 1 -- 返回命令ID
  end

  -- 模拟 vim.fn
  if not vim.fn then
    vim.fn = {}
  end

  -- 模拟 vim.fn.stdpath
  vim.fn.stdpath = function(what)
    local paths = {
      cache = "/tmp/neovim_cache",
      config = "/tmp/neovim_config",
      data = "/tmp/neovim_data",
      state = "/tmp/neovim_state",
    }
    return paths[what] or "/tmp"
  end

  -- 模拟 vim.fn.glob
  vim.fn.glob = function(pattern, nosuf, list)
    -- 简单的模拟，返回空列表
    return {}
  end

  -- 模拟 vim.fn.isdirectory
  vim.fn.isdirectory = function(path)
    -- 简单的模拟，总是返回false
    return 0
  end

  -- 模拟 vim.fn.filereadable
  vim.fn.filereadable = function(path)
    -- 简单的模拟，总是返回false
    return 0
  end

  -- 模拟 vim.fn.fnamemodify
  vim.fn.fnamemodify = function(filename, mods)
    -- 简单的模拟，处理常见的修改符
    if mods == ":t:r" then
      -- 返回不带路径和扩展名的文件名
      local name = filename:match("([^/]+)$") or filename
      return name:match("^(.+)%..+$") or name
    end
    return filename
  end

  -- 模拟 vim.split
  vim.split = function(str, pattern, opts)
    local result = {}
    local plain = opts and opts.plain

    if plain then
      -- 简单分割
      local start = 1
      while true do
        local pos = str:find(pattern, start, true)
        if not pos then
          table.insert(result, str:sub(start))
          break
        end
        table.insert(result, str:sub(start, pos - 1))
        start = pos + #pattern
      end
    else
      -- 使用模式匹配
      for part in str:gmatch("[^" .. pattern .. "]+") do
        table.insert(result, part)
      end
    end

    return result
  end

  -- 模拟 vim.fn.shellescape
  vim.fn.shellescape = function(str)
    -- 简单的模拟，返回带引号的字符串
    return "'" .. str .. "'"
  end

  -- 模拟 vim.tbl_deep_extend
  if not vim.tbl_deep_extend then
    vim.tbl_deep_extend = function(behavior, ...)
      local result = {}
      local tables = { ... }

      for _, t in ipairs(tables) do
        if type(t) == "table" then
          for k, v in pairs(t) do
            if behavior == "force" then
              result[k] = v
            elseif result[k] == nil then
              result[k] = v
            end
          end
        end
      end

      return result
    end
  end

  -- 模拟 vim.keymap.set
  if not vim.keymap then
    vim.keymap = {}
  end
  vim.keymap.set = function(mode, lhs, rhs, opts)
    print(string.format("[模拟] 设置键位映射: %s -> %s", lhs, tostring(rhs)))
  end

  -- 确保全局变量已设置
  if not _G.vim then
    _G.vim = vim
  end

  return true
end

-- ============================================================================
-- 第八部分：测试套件自动注册
-- ============================================================================

--- 自动注册所有测试套件
function M.auto_register_test_suites()
  -- 查找所有测试套件文件
  local test_files = vim.fn.glob("/root/NeoAI/pack/plugins/start/NeoAI/lua/NeoAI/tests/*_test.lua", true, true)

  for _, file in ipairs(test_files) do
    local module_name = vim.fn.fnamemodify(file, ":t:r")
    local require_path = "NeoAI.tests." .. module_name

    local success, module = pcall(require, require_path)
    if success and type(module) == "table" and type(module.register_tests) == "function" then
      print("📋 注册测试套件: " .. module_name)
      module.register_tests(M)
    end
  end
end

-- ============================================================================
-- 第九部分：Neovim命令注册
-- ============================================================================

--- 注册Neovim测试命令
function M.register_commands()
  vim.api.nvim_create_user_command("NeoAITest", function()
    M.run_all()
  end, {
    desc = "运行所有NeoAI测试",
  })

  vim.api.nvim_create_user_command("NeoAITestSuite", function(opts)
    if opts.args and opts.args ~= "" then
      M.run_suite(opts.args)
    else
      print("❌ 请指定测试套件名称")
    end
  end, {
    desc = "运行特定测试套件",
    nargs = 1,
    complete = function()
      local suites = {}
      for name, _ in pairs(M.test_suites) do
        table.insert(suites, name)
      end
      return suites
    end,
  })

  print("✅ 已注册测试命令:")
  print("   :NeoAITest - 运行所有测试")
  print("   :NeoAITestSuite <name> - 运行特定测试套件")
end

-- ============================================================================
-- 第十部分：主运行函数
-- ============================================================================

--- 运行所有测试套件的内部函数
local function run_all_test_suites()
  local total_results = {
    total = 0,
    passed = 0,
    failed = 0,
    skipped = 0,
    errored = 0,
    suites = {},
  }

  print("🧪 开始运行所有测试套件")
  print(string.rep("=", 60))

  for suite_name, suite in pairs(M.test_suites) do
    print("\n📦 测试套件: " .. suite_name)
    print(string.rep("-", 40))

    local results = suite:run()
    table.insert(total_results.suites, {
      name = suite_name,
      results = results,
    })

    total_results.total = total_results.total + results.total
    total_results.passed = total_results.passed + results.passed
    total_results.failed = total_results.failed + results.failed
    total_results.skipped = total_results.skipped + results.skipped
    total_results.errored = total_results.errored + results.errored

    -- 打印套件结果
    for _, test in ipairs(results.tests) do
      local icon = "❓"
      if test.result == M.TestResult.PASS then
        icon = "✅"
      elseif test.result == M.TestResult.FAIL then
        icon = "❌"
      elseif test.result == M.TestResult.ERROR then
        icon = "💥"
      elseif test.result == M.TestResult.SKIP then
        icon = "⏭️"
      end

      local duration_str = string.format("(%.3fs)", test.duration)
      print(string.format("  %s %s %s", icon, test.name, duration_str))

      if test.error_message then
        print("    错误: " .. test.error_message)
      end
    end

    print(string.format("  📊 结果: %d/%d 通过", results.passed, results.total))
  end

  -- 打印总结果
  print("\n" .. string.rep("=", 60))
  print("📊 测试总览")
  print(string.rep("-", 40))

  local pass_rate = total_results.total > 0 and (total_results.passed / total_results.total) * 100 or 0
  print(string.format("✅ 通过: %d", total_results.passed))
  print(string.format("❌ 失败: %d", total_results.failed))
  print(string.format("💥 错误: %d", total_results.errored))
  print(string.format("⏭️  跳过: %d", total_results.skipped))
  print(string.format("📈 通过率: %.1f%%", pass_rate))

  if total_results.failed == 0 and total_results.errored == 0 then
    print("\n🎉 所有测试通过！")
  else
    print("\n⚠️  有测试失败或错误，请检查")
  end

  return total_results
end

--- 运行所有测试（主入口函数）
function M.run_all()
  print("🚀 开始自动注册测试套件...")
  M.auto_register_test_suites()

  if next(M.test_suites) == nil then
    print("⚠️  没有找到任何测试套件")
    return
  end

  return run_all_test_suites()
end

--- 异步运行所有测试
--- @param callback function 回调函数
function M.run_all_async(callback)
  print("🚀 开始异步注册测试套件...")
  M.auto_register_test_suites()

  if next(M.test_suites) == nil then
    print("⚠️  没有找到任何测试套件")
    if callback then
      callback({total = 0, passed = 0, failed = 0, errored = 0, skipped = 0, suites = {}})
    end
    return
  end

  -- 使用异步工作器运行测试
  local async_worker = require("NeoAI.utils.async_worker")
  
  -- 为每个测试套件创建异步任务
  local tasks = {}
  local suite_results = {}
  local completed_suites = 0
  local total_suites = 0
  
  for suite_name, suite in pairs(M.test_suites) do
    total_suites = total_suites + 1
    
    table.insert(tasks, {
      name = "test_suite_" .. suite_name,
      task_func = function()
        return suite:run()
      end,
      callback = function(success, results)
        completed_suites = completed_suites + 1
        
        if success then
          suite_results[suite_name] = results
          print(string.format("✅ 测试套件完成: %s (%d/%d 通过)", suite_name, results.passed, results.total))
        else
          print(string.format("❌ 测试套件失败: %s", suite_name))
          suite_results[suite_name] = {
            total = 0,
            passed = 0,
            failed = 0,
            errored = 1,
            skipped = 0,
            tests = {},
          }
        end
        
        -- 所有套件完成后执行回调
        if completed_suites >= total_suites and callback then
          local total_results = {
            total = 0,
            passed = 0,
            failed = 0,
            errored = 0,
            skipped = 0,
            suites = {},
          }
          
          for name, results in pairs(suite_results) do
            total_results.total = total_results.total + results.total
            total_results.passed = total_results.passed + results.passed
            total_results.failed = total_results.failed + results.failed
            total_results.errored = total_results.errored + results.errored
            total_results.skipped = total_results.skipped + results.skipped
            
            table.insert(total_results.suites, {
              name = name,
              results = results,
            })
          end
          
          callback(total_results)
        end
      end,
    })
  end
  
  -- 批量提交任务
  async_worker.submit_batch(tasks)
end

--- 运行单个测试套件（异步版）
--- @param suite_name string 测试套件名称
--- @param callback function 回调函数
function M.run_suite_async(suite_name, callback)
  local suite = M.get_suite(suite_name)
  if not suite then
    print("❌ 未找到测试套件: " .. suite_name)
    if callback then
      callback(nil)
    end
    return
  end
  
  local async_worker = require("NeoAI.utils.async_worker")
  
  async_worker.submit_task("test_suite_" .. suite_name, function()
    return suite:run()
  end, function(success, results)
    if callback then
      callback(success and results or nil)
    end
  end)
end

--- 运行特定测试套件
function M.run_suite(suite_name)
  local suite = M.get_suite(suite_name)
  if not suite then
    print("❌ 找不到测试套件: " .. suite_name)
    return
  end

  print("🚀 运行测试套件: " .. suite_name)
  return suite:run()
end

-- ============================================================================
-- 第十一部分：模块导出
-- ============================================================================

return M
