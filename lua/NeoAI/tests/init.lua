--- NeoAI 测试运行器
--- @module NeoAI.tests
--- 轻量自定义测试框架（无外部依赖）。
--- 断言 API：eq/ne/true/false/nil/not_nil/matches/ok
--- 运行器：describe/it，按文件收集，headless 可跑。

local M = {}

-- ========== 测试注册表 ==========

local state = {
  suites = {}, -- { { name, tests = { { name, fn } }, before_each = fn } }
  current_suite = nil,
}

--- 定义测试套件
--- @param name string
--- @param fn function(describe, it, before_each)
function M.suite(name, fn)
  local tests = {}
  local before_each = nil
  state.current_suite = { name = name, tests = tests, before_each = before_each }
  state.suites[#state.suites + 1] = state.current_suite
  local function describe(desc) end
  local function it(test_name, test_fn)
    tests[#tests + 1] = { name = test_name, fn = test_fn }
  end
  local function before_each_fn(f)
    before_each = f
    state.current_suite.before_each = f
  end
  fn(describe, it, before_each_fn)
  state.current_suite = nil
end

-- ========== 断言 ==========

local AssertError = {}
AssertError.__index = AssertError

local function _fail(msg)
  error(setmetatable({ message = msg }, AssertError), 2)
end

--- 格式化错误（提取断言消息）
local function _fmt_err(err)
  if type(err) == "table" and err.message then
    return err.message
  end
  return tostring(err)
end

local function _type_str(v)
  if v == nil then return "nil" end
  if type(v) == "table" then
    return "table: " .. vim.inspect(v)
  end
  return string.format("%q (%s)", tostring(v), type(v))
end

local assert_helpers = {}

function assert_helpers.eq(expected, actual, msg)
  if expected ~= actual then
    _fail(string.format("%s期望 %s，实际 %s", msg and (msg .. ": ") or "", _type_str(expected), _type_str(actual)))
  end
  return true
end

function assert_helpers.ne(expected, actual, msg)
  if expected == actual then
    _fail(string.format("%s不应等于 %s", msg and (msg .. ": ") or "", _type_str(actual)))
  end
  return true
end

function assert_helpers.not_eq(expected, actual, msg)
  if expected == actual then
    _fail(string.format("%s期望不相等: %s", msg and (msg .. ": ") or "", _type_str(actual)))
  end
  return true
end

function assert_helpers.true_(value, msg)
  if value ~= true then
    _fail(string.format("%s期望 true，实际 %s", msg and (msg .. ": ") or "", _type_str(value)))
  end
  return true
end

function assert_helpers.false_(value, msg)
  if value ~= false then
    _fail(string.format("%s期望 false，实际 %s", msg and (msg .. ": ") or "", _type_str(value)))
  end
  return true
end

function assert_helpers.nil_(value, msg)
  if value ~= nil then
    _fail(string.format("%s期望 nil，实际 %s", msg and (msg .. ": ") or "", _type_str(value)))
  end
  return true
end

function assert_helpers.not_nil(value, msg)
  if value == nil then
    _fail(string.format("%s期望非 nil", msg or ""))
  end
  return true
end

function assert_helpers.matches(pattern, value, msg)
  if type(value) ~= "string" or not value:match(pattern) then
    _fail(string.format("%s字符串 %s 不匹配模式 %s", msg and (msg .. ": ") or "", _type_str(value), pattern))
  end
  return true
end

function assert_helpers.ok(value, msg)
  if not value then
    _fail(string.format("%s期望为真值", msg or ""))
  end
  return true
end

function assert_helpers.deep_eq(expected, actual, msg)
  local encoded_e = vim.inspect(expected)
  local encoded_a = vim.inspect(actual)
  if encoded_e ~= encoded_a then
    _fail(string.format("%s深比较失败\n期望: %s\n实际: %s", msg and (msg .. "\n") or "", encoded_e, encoded_a))
  end
  return true
end

--- 异步等待
--- @param ms number
--- @return Deferred
function assert_helpers.sleep(ms)
  local async = require("NeoAI.utils.async")
  return async.sleep(ms)
end

--- 捕获错误
--- @param fn function
--- @return boolean, string
function assert_helpers.throws(fn)
  local ok, err = pcall(fn)
  return ok, err
end

-- ========== 运行器 ==========

local function _run_suite(suite)
  local passed, failed = 0, 0
  local errors = {}
  for _, test in ipairs(suite.tests) do
    local ok, err = xpcall(function()
      if suite.before_each then
        suite.before_each()
      end
      local t = {}
      for k, v in pairs(assert_helpers) do t[k] = v end
      test.fn(t)
    end, debug.traceback)
    if ok then
      passed = passed + 1
      print(("  ✓ %s"):format(test.name))
    else
      failed = failed + 1
      local err_str = _fmt_err(err)
      errors[#errors + 1] = ("%s :: %s\n%s"):format(suite.name, test.name, err_str)
      print(("  ✗ %s\n    %s"):format(test.name, err_str:gsub("\n", "\n    ")))
    end
  end
  return passed, failed, errors
end

--- 运行指定套件
--- @param names ... string 套件名（可选；空则全部）
--- @return table { passed, failed, errors }
function M.run_all(...)
  local requested = { ... }
  local total_passed, total_failed = 0, 0
  local all_errors = {}
  local loaded = false

  -- 会话隔离：防止测试把会话写入真实历史（~/.cache/nvim/NeoAI/sessions.jsonl）。
  -- 测试期间把“默认路径”会话重定向到临时目录，结束后清理并恢复内存中的真实会话。
  local session_store = require("NeoAI.core.session.session_store")
  local real_sessions = {}
  for id, s in pairs(session_store.get_all()) do
    real_sessions[id] = s
  end
  local test_session_dir = vim.fn.stdpath("cache") .. "/NeoAI-test"
  session_store.set_default_path_redirect(test_session_dir)

  local function _cleanup()
    session_store.set_default_path_redirect(nil)
    session_store.restore(real_sessions)
    vim.fn.delete(test_session_dir, "rf") -- 清理临时会话目录
  end

  -- 动态加载所有 test_*.lua 文件（幂等）
  local src = debug.getinfo(1, "S").source
  local test_dir = src:match("^@(.+)[/\\][^/\\]+$")
  if not test_dir then
    test_dir = "/root/NeoAI/lua/NeoAI/tests"
  end
  local files = vim.fn.glob(test_dir .. "/test_*.lua", false, true)
  for _, file in ipairs(files) do
    local mod_name = "NeoAI.tests." .. vim.fn.fnamemodify(file, ":t:r")
    if vim.fn.fnamemodify(file, ":t") ~= "init.lua" then
      local ok, err = pcall(require, mod_name)
      if not ok then
        all_errors[#all_errors + 1] = ("加载测试模块 %s 失败: %s"):format(mod_name, tostring(err))
      end
      loaded = true
    end
  end

  local suites_to_run = {}
  if #requested > 0 then
    for _, name in ipairs(requested) do
      for _, suite in ipairs(state.suites) do
        if suite.name == name then
          suites_to_run[#suites_to_run + 1] = suite
        end
      end
    end
  else
    suites_to_run = state.suites
  end

  local ok_run, run_err = xpcall(function()
    print(string.format("\n=== NeoAI 测试 (%d 套件) ===", #suites_to_run))
    for _, suite in ipairs(suites_to_run) do
      print("▶ " .. suite.name)
      local p, f, errs = _run_suite(suite)
      total_passed = total_passed + p
      total_failed = total_failed + f
      for _, e in ipairs(errs) do all_errors[#all_errors + 1] = e end
    end
  end, debug.traceback)
  if not ok_run then
    all_errors[#all_errors + 1] = tostring(run_err)
  end

  _cleanup()

  print(string.format("\n=== 结果: %d 通过, %d 失败 ===", total_passed, total_failed))
  return { passed = total_passed, failed = total_failed, errors = all_errors }
end

--- 重置（测试用）
function M.reset()
  state.suites = {}
  state.current_suite = nil
end

return M
