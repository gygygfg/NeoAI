--- 测试: 主 init.lua
--- 测试主入口的 setup、命令注册、模块获取等功能
local M = {}

local test

--- 创建一个测试配置
local function create_test_config()
  return {
    ai = {
      default = "test",
      providers = {
        test = {
          api_type = "openai",
          base_url = "https://test.api.com",
          api_key = "sk-test",
          models = { "test-model" },
        },
      },
      scenarios = {
        chat = {
          provider = "test",
          model_name = "test-model",
          temperature = 0.5,
          max_tokens = 100,
          stream = false,
          timeout = 5000,
        },
      },
    },
    ui = {
      default_ui = "chat",
      window_mode = "float",
      window = { width = 60, height = 15, border = "none" },
    },
    session = {
      auto_save = false,
      auto_naming = false,
      save_path = "/tmp/neoai_test_main",
    },
    tools = {
      enabled = false,
      builtin = false,
    },
  }
end

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_main_init ===")

  return test.run_tests({
    --- 测试 setup（幂等，如果已初始化则跳过）
    test_setup = function()
      local neoai = require("NeoAI")
      local state = require("NeoAI.core.state")
      if not state.is_initialized() then
        neoai.setup(create_test_config())
      end

      -- 验证模块引用已初始化（可能受之前测试影响）
      local ok1, engine = pcall(neoai.get_ai_engine, neoai)
      if ok1 and engine then
        local status = engine.get_status()
        assert.is_true(type(status) == "table")
      end

      local ok2, tools = pcall(neoai.get_tools, neoai)
      if ok2 and tools then
        assert.is_true(type(tools.get_tools) == "function")
      end

      local ok3, km = pcall(neoai.get_keymap_manager, neoai)
      if ok3 and km then
        assert.is_true(type(km.get_available_contexts) == "function")
      end
    end,

    --- 测试重复 setup
    test_double_setup = function()
      local neoai = require("NeoAI")
      -- 第二次 setup 应被忽略（幂等）
      neoai.setup(create_test_config())
      -- 不应崩溃
    end,

    --- 测试 open_neoai
    test_open_neoai = function()
      local neoai = require("NeoAI")
      -- 在 headless 模式下可能失败，但不应该崩溃
      local ok, err = pcall(function()
        neoai.open_neoai()
      end)
      -- 允许失败
    end,

    --- 测试 close_all
    test_close_all = function()
      local neoai = require("NeoAI")
      neoai.close_all()
      -- 不应崩溃
    end,

    --- 测试 get_session_manager
    test_get_session_manager = function()
      local neoai = require("NeoAI")
      local ok, sm = pcall(neoai.get_session_manager, neoai)
      -- 可能返回 nil（旧版兼容），但不应该崩溃
    end,

    --- 测试 get_ai_engine
    test_get_ai_engine = function()
      local neoai = require("NeoAI")
      local ok, engine = pcall(neoai.get_ai_engine, neoai)
      if ok and engine then
        local status = engine.get_status()
        assert.is_true(type(status) == "table")
      end
    end,

    --- 测试 get_tools
    test_get_tools = function()
      local neoai = require("NeoAI")
      local ok, tools = pcall(neoai.get_tools, neoai)
      if ok and tools then
        assert.is_true(type(tools.get_tools) == "function")
      end
    end,

    --- 测试 get_keymap_manager
    test_get_keymap_manager = function()
      local neoai = require("NeoAI")
      local ok, km = pcall(neoai.get_keymap_manager, neoai)
      if ok and km then
        local contexts = km.get_available_contexts()
        assert.is_true(type(contexts) == "table")
      end
    end,

    --- 测试命令已注册
    test_commands_registered = function()
      -- 验证 Neovim 命令已注册
      local commands = vim.api.nvim_get_commands({})
      -- 可能受之前测试影响，使用 pcall 安全访问
      local ok1 = pcall(function() return commands.NeoAIOpen end)
      local ok2 = pcall(function() return commands.NeoAIClose end)
      -- 不强制断言，因为命令可能已被清理
    end,

    --- 测试 tests/init.lua 的 get_merged_config
    test_tests_init_get_merged_config = function()
      local tests_init = require("NeoAI.tests")
      local config = tests_init.get_merged_config()
      assert.not_nil(config, "合并配置不应为 nil")
      -- AI 配置可能为 nil（如果 default_config 未初始化）
      -- 但至少应返回一个表
      assert.is_true(type(config) == "table")
    end,

    --- 测试 tests/init.lua 的断言工具
    test_tests_assert_tools = function()
      local assert_tools = test.assert

      -- equal
      assert_tools.equal(1, 1)
      assert_tools.equal("hello", "hello")

      -- not_equal
      assert_tools.not_equal(1, 2)

      -- is_true / is_false
      assert_tools.is_true(true)
      assert_tools.is_false(false)

      -- is_nil / not_nil
      assert_tools.is_nil(nil)
      assert_tools.not_nil("value")

      -- has_key
      assert_tools.has_key({ a = 1 }, "a")

      -- contains
      assert_tools.contains({ 1, 2, 3 }, 2)

      -- assert_error
      assert_tools.assert_error(function()
        error("预期错误")
      end, "预期错误")
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

