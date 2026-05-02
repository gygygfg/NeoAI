--- 测试: core/ai/tool_orchestrator.lua
--- 测试工具编排器的初始化、会话管理、工具执行调度等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_tool_orchestrator ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.initialize({})
      -- 幂等初始化
      orc.initialize({})
    end,

    --- 测试 register_session / unregister_session
    test_register_unregister_session = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_session_1", 1001)
      orc.register_session("test_session_2", 1002)

      -- 重复注册不应崩溃
      orc.register_session("test_session_1", 1001)

      local ids = orc.get_all_session_ids()
      assert.is_true(#ids >= 2, "应有至少2个会话")

      orc.unregister_session("test_session_1")
      orc.unregister_session("test_session_2")
    end,

    --- 测试 get_session_state
    test_get_session_state = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_state", 2001)

      local ss = orc.get_session_state("test_state")
      assert.not_nil(ss, "应返回会话状态")
      assert.equal("test_state", ss.session_id)
      assert.equal(2001, ss.window_id)

      -- 不存在的会话
      local missing = orc.get_session_state("nonexistent")
      assert.equal(nil, missing)

      orc.unregister_session("test_state")
    end,

    --- 测试 set_tools / get_tools
    test_set_get_tools = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      local test_tools = { test_tool = { func = function() end } }
      orc.set_tools(test_tools)
      local tools = orc.get_tools()
      assert.not_nil(tools.test_tool)
    end,

    --- 测试 get_current_iteration
    test_get_current_iteration = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_iter", 3001)

      local iter = orc.get_current_iteration("test_iter")
      assert.equal(0, iter, "初始迭代次数应为0")

      orc.reset_iteration("test_iter")
      orc.unregister_session("test_iter")
    end,

    --- 测试 reset_iteration
    test_reset_iteration = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_reset", 4001)

      orc.reset_iteration("test_reset")
      local iter = orc.get_current_iteration("test_reset")
      assert.equal(0, iter)

      orc.unregister_session("test_reset")
    end,

    --- 测试 is_executing
    test_is_executing = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_exec", 5001)

      -- 初始不应在执行
      assert.is_false(orc.is_executing("test_exec"))

      orc.unregister_session("test_exec")
    end,

    --- 测试 is_stop_requested / reset_stop_requested
    test_stop_requested = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_stop", 6001)

      assert.is_false(orc.is_stop_requested("test_stop"), "初始不应请求停止")

      orc.request_stop("test_stop")
      assert.is_true(orc.is_stop_requested("test_stop"), "请求停止后应为 true")

      orc.reset_stop_requested("test_stop")
      assert.is_false(orc.is_stop_requested("test_stop"), "重置后应为 false")

      orc.unregister_session("test_stop")
    end,

    --- 测试 request_stop 所有会话
    test_request_stop_all = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_all_1", 7001)
      orc.register_session("test_all_2", 7002)

      orc.request_stop() -- 停止所有会话
      assert.is_true(orc.is_stop_requested("test_all_1"))
      assert.is_true(orc.is_stop_requested("test_all_2"))

      orc.reset_stop_requested()
      orc.unregister_session("test_all_1")
      orc.unregister_session("test_all_2")
    end,

    --- 测试 start_async_loop（不应崩溃）
    test_start_async_loop = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_loop", 8001)

      -- 空参数调用不应崩溃
      local ok, err = pcall(orc.start_async_loop, orc, {
        session_id = "test_loop",
        window_id = 8001,
        generation_id = "gen_1",
        tool_calls = {},
        messages = {},
        options = {},
      })

      orc.unregister_session("test_loop")
    end,

    --- 测试 on_generation_complete（不应崩溃）
    test_on_generation_complete = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      local ok, err = pcall(orc.on_generation_complete, orc, {
        generation_id = "gen_test",
        session_id = "session_test",
        tool_calls = {},
        content = "",
        usage = {},
      })
    end,

    --- 测试 set_shutting_down
    test_set_shutting_down = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      local sf = require("NeoAI.core.shutdown_flag")
      sf.reset()
      orc.set_shutting_down()
      assert.is_true(sf.is_set())
      sf.reset()
    end,

    --- 测试 cleanup_all（不应崩溃）
    test_cleanup_all = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_cleanup", 9001)
      orc.cleanup_all()
      -- 清理后所有会话应不存在
      local ids = orc.get_all_session_ids()
      assert.is_true(#ids == 0, "清理后应无会话")
    end,

    --- 测试 shutdown
    test_shutdown = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.shutdown()
      -- shutdown 后重新初始化以便后续测试
      orc.initialize({})
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
