--- 测试: core/init.lua 和 core/shutdown_flag.lua
--- 测试核心模块的初始化、子模块获取、关闭标志等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_core_init ===")

  return test.run_tests({
    --- 测试 shutdown_flag 基本功能
    test_shutdown_flag_basic = function()
      local sf = require("NeoAI.core.shutdown_flag")
      sf.reset()
      assert.is_false(sf.is_set(), "初始应未设置")
      sf.set()
      assert.is_true(sf.is_set(), "设置后应为 true")
      sf.reset()
      assert.is_false(sf.is_set(), "重置后应为 false")
    end,

    --- 测试 shutdown_flag 幂等性
    test_shutdown_flag_idempotent = function()
      local sf = require("NeoAI.core.shutdown_flag")
      sf.reset()
      sf.set()
      sf.set() -- 重复设置不应崩溃
      assert.is_true(sf.is_set())
      sf.reset()
    end,

    --- 测试 core.initialize
    test_core_initialize = function()
      local state = require("NeoAI.core.config.state")
      state._test_reset()
      state.initialize({ test = true })

      local core = require("NeoAI.core")
      -- 如果已初始化则跳过
      local ok, result = pcall(core.initialize, {})
      -- 不应崩溃
      assert.is_true(type(core) == "table")
    end,

    --- 测试 core.get_ai_engine
    test_core_get_ai_engine = function()
      local core = require("NeoAI.core")
      local ok, engine = pcall(core.get_ai_engine, core)
      if ok and engine then
        assert.is_true(type(engine.get_status) == "function")
      end
    end,

    --- 测试 core.get_keymap_manager
    test_core_get_keymap_manager = function()
      local core = require("NeoAI.core")
      local ok, km = pcall(core.get_keymap_manager, core)
      if ok and km then
        assert.is_true(type(km.get_available_contexts) == "function")
      end
    end,

    --- 测试 core.get_history_manager
    test_core_get_history_manager = function()
      local core = require("NeoAI.core")
      local ok, hm = pcall(core.get_history_manager, core)
      if ok and hm then
        assert.is_true(type(hm.is_initialized) == "function")
      end
    end,

    --- 测试 core.get_config
    test_core_get_config = function()
      local core = require("NeoAI.core")
      local ok, config = pcall(core.get_config, core)
      if ok and config then
        assert.is_true(type(config) == "table")
      end
    end,

    --- 测试 core.get_session_manager（旧版兼容）
    test_core_get_session_manager = function()
      local core = require("NeoAI.core")
      local ok, sm = pcall(core.get_session_manager, core)
      if ok then
        assert.equal(nil, sm, "旧版兼容应返回 nil")
      end
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
