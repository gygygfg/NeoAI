--- NeoAI 测试入口
--- 通过主 init.lua 导入，拿到合并后的测试配置
--- 用法:
---   nvim --headless -c "lua dofile('/path/to/NeoAI/lua/NeoAI/tests/init.lua')"
---
--- 或运行单个测试文件:
---   nvim --headless -c "lua dofile('/path/to/NeoAI/lua/NeoAI/tests/test_default_config.lua')"

local M = {}

-- 测试配置（合并到默认配置上）
M.test_config = {
  ai = {
    default = "test",
    providers = {
      test_provider = {
        api_type = "openai",
        base_url = "https://test.api.example.com/v1/chat/completions",
        api_key = "test-api-key",
        models = { "test-model-v1", "test-model-v2" },
      },
    },
    scenarios = {
      chat = {
        provider = "test_provider",
        model_name = "test-model-v1",
        temperature = 0.5,
        max_tokens = 100,
        stream = false,
        timeout = 5000,
      },
      coding = {
        provider = "test_provider",
        model_name = "test-model-v2",
        temperature = 0.2,
        max_tokens = 200,
        stream = false,
        timeout = 5000,
      },
    },
  },
  ui = {
    default_ui = "chat",
    window_mode = "float",
    window = {
      width = 60,
      height = 15,
      border = "none",
    },
  },
  session = {
    auto_save = false,
    auto_naming = false,
    save_path = "/tmp/neoai_test_sessions",
    max_history_per_session = 50,
  },
  tools = {
    enabled = false,
    builtin = false,
  },
  keymaps = {
    global = {
      open_tree = { key = "<leader>tt", desc = "测试打开树" },
      open_chat = { key = "<leader>cc", desc = "测试打开聊天" },
    },
  },
}

--- 获取合并后的完整配置
--- 先加载主 init.lua 的 setup 流程，再覆盖测试配置
--- @return table 合并后的完整配置
function M.get_merged_config()
  -- 加载主模块
  local ok, neoai = pcall(require, "NeoAI")
  if not ok then
    -- 如果主模块加载失败（如无 Neovim 环境），直接使用 default_config
    local default_config = require("NeoAI.default_config")
    return default_config.process_config(M.test_config)
  end

  -- 调用主模块的 setup（会合并配置）
  neoai.setup(M.test_config)

  -- 获取合并后的配置
  local state = require("NeoAI.core.state")
  return state.get_config()
end

--- 运行所有测试
function M.run_all()
  local tests = {
    "test_default_config",
    "test_state",
    "test_event_constants",
    "test_keymap_manager",
    "test_history_manager",
    "test_ai_engine",
    "test_utils_init",
    "test_tools_init",
    "test_ui_init",
    "test_main_init",
  }

  local results = { passed = 0, failed = 0, errors = {} }

  -- 获取当前脚本所在目录
  local info = debug.getinfo(1, "S")
  local base_dir = info.source:match("^@?(.*/)") or "."
  for _, name in ipairs(tests) do
    local ok, err = pcall(function()
      -- 使用 dofile 避免 require 的循环依赖
      local filepath = base_dir .. "/" .. name .. ".lua"
      local test_mod = dofile(filepath)
      if test_mod and test_mod.run then
        local r = test_mod.run(M)
        if r then
          results.passed = results.passed + (r.passed or 0)
          results.failed = results.failed + (r.failed or 0)
          if r.errors then
            for _, e in ipairs(r.errors) do
              table.insert(results.errors, "[" .. name .. "] " .. e)
            end
          end
        end
      end
    end)
    if not ok then
      results.failed = results.failed + 1
      table.insert(results.errors, "[" .. name .. "] " .. tostring(err))
    end
  end

  return results
end

--- 简单的断言工具
M.assert = {
  --- 断言相等
  --- @param expected any
  --- @param actual any
  --- @param msg string|nil
  equal = function(expected, actual, msg)
    if expected ~= actual then
      error(string.format(
        "断言失败: %s\n  期望: %s\n  实际: %s",
        msg or "值不相等",
        vim.inspect(expected),
        vim.inspect(actual)
      ))
    end
  end,

  --- 断言不相等
  not_equal = function(expected, actual, msg)
    if expected == actual then
      error(string.format(
        "断言失败: %s\n  期望不等于: %s",
        msg or "值不应相等",
        vim.inspect(expected)
      ))
    end
  end,

  --- 断言为真
  is_true = function(value, msg)
    if not value then
      error(string.format("断言失败: %s\n  期望为真, 实际为假", msg or "值应为真"))
    end
  end,

  --- 断言为假
  is_false = function(value, msg)
    if value then
      error(string.format("断言失败: %s\n  期望为假, 实际为真", msg or "值应为假"))
    end
  end,

  --- 断言为 nil
  is_nil = function(value, msg)
    if value ~= nil then
      error(string.format("断言失败: %s\n  期望为 nil, 实际为 %s", msg or "值应为 nil", vim.inspect(value)))
    end
  end,

  --- 断言不为 nil
  not_nil = function(value, msg)
    if value == nil then
      error(string.format("断言失败: %s\n  值不应为 nil", msg or "值不应为 nil"))
    end
  end,

  --- 断言表包含键
  has_key = function(tbl, key, msg)
    if tbl == nil or tbl[key] == nil then
      error(string.format("断言失败: %s\n  表不包含键: %s", msg or "表应包含键", tostring(key)))
    end
  end,

  --- 断言表包含值
  contains = function(tbl, value, msg)
    if type(tbl) ~= "table" then
      error(string.format("断言失败: %s\n  期望为表, 实际为 %s", msg or "值应为表", type(tbl)))
    end
    for _, v in ipairs(tbl) do
      if v == value then
        return
      end
    end
    error(string.format("断言失败: %s\n  表不包含值: %s", msg or "表应包含值", vim.inspect(value)))
  end,

  --- 断言抛出错误
  assert_error = function(fn, expected_msg, msg)
    local ok, err = pcall(fn)
    if ok then
      error(string.format("断言失败: %s\n  期望抛出错误, 但未抛出", msg or "应抛出错误"))
    end
    if expected_msg and not string.find(tostring(err), expected_msg, 1, true) then
      error(string.format(
        "断言失败: %s\n  期望错误包含: %s\n  实际错误: %s",
        msg or "错误消息不匹配",
        expected_msg,
        tostring(err)
      ))
    end
  end,
}

--- 运行单个测试函数并返回结果
--- @param name string 测试名称
--- @param fn function 测试函数
--- @return boolean 是否通过
function M.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print(string.format("  ✓ %s", name))
    return true
  else
    print(string.format("  ✗ %s: %s", name, tostring(err)))
    return false
  end
end

--- 运行一组测试
--- @param tests table { name = function, ... }
--- @return table { passed, failed, errors }
function M.run_tests(tests)
  local results = { passed = 0, failed = 0, errors = {} }
  for name, fn in pairs(tests) do
    if M.test(name, fn) then
      results.passed = results.passed + 1
    else
      results.failed = results.failed + 1
      table.insert(results.errors, name)
    end
  end
  return results
end

-- 如果直接运行此文件，执行所有测试
if pcall(vim.api.nvim_buf_get_name, 0) then
  local results = M.run_all()
  print(string.format("\n测试结果: %d 通过, %d 失败", results.passed, results.failed))
  if #results.errors > 0 then
    print("失败的测试:")
    for _, e in ipairs(results.errors) do
      print("  " .. e)
    end
  end
end

return M

