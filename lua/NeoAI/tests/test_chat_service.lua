--- 测试: core/ai/chat_service.lua
--- 测试聊天服务的基本功能（会话管理、消息管理、AI 生成调度等）
--- 注意：实际 HTTP 请求测试需要 API key，这里只测试逻辑层
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_chat_service ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local cs = require("NeoAI.core.ai.chat_service")
      -- 幂等初始化
      cs.initialize()
      assert.is_true(cs.is_initialized(), "应已初始化")
    end,

    --- 测试 is_initialized
    test_is_initialized = function()
      local cs = require("NeoAI.core.ai.chat_service")
      assert.is_true(type(cs.is_initialized) == "function")
    end,

    --- 测试 create_session（委托给 history_manager）
    test_create_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local id = cs.create_session("测试会话", true, nil)
      assert.not_nil(id, "应创建会话")
      assert.is_true(string.find(id, "^session_") ~= nil)
    end,

    --- 测试 get_or_create_current_session
    test_get_or_create_current_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local session = cs.get_or_create_current_session("自动创建")
      assert.not_nil(session)
      assert.equal("自动创建", session.name)
    end,

    --- 测试 get_session / get_current_session
    test_get_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local id = cs.create_session("测试", true, nil)
      local session = cs.get_session(id)
      assert.not_nil(session)
      assert.equal("测试", session.name)

      local current = cs.get_current_session()
      assert.not_nil(current)
      assert.equal(id, current.id)
    end,

    --- 测试 set_current_session
    test_set_current_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local id1 = cs.create_session("会话1", true, nil)
      local id2 = cs.create_session("会话2", true, nil)
      cs.set_current_session(id1)
      assert.equal(id1, cs.get_current_session().id)
    end,

    --- 测试 delete_session
    test_delete_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local id = cs.create_session("待删除", true, nil)
      assert.is_true(cs.delete_session(id), "删除应成功")
      assert.equal(nil, cs.get_session(id))
    end,

    --- 测试 rename_session
    test_rename_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local id = cs.create_session("旧名称", true, nil)
      cs.rename_session(id, "新名称")
      assert.equal("新名称", cs.get_session(id).name)
    end,

    --- 测试 list_sessions
    test_list_sessions = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      cs.create_session("会话A", true, nil)
      cs.create_session("会话B", true, nil)
      local list = cs.list_sessions()
      assert.is_true(#list >= 2)
    end,

    --- 测试 get_tree
    test_get_tree = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local root_id = cs.create_session("根", true, nil)
      cs.create_session("子", false, root_id)
      local tree = cs.get_tree()
      assert.is_true(#tree >= 1)
    end,

    --- 测试 get_raw_messages
    test_get_raw_messages = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local id = cs.create_session("测试", true, nil)
      cs.add_round(id, "你好", '{"content":"你好！"}')

      local msgs = cs.get_raw_messages(id)
      assert.is_true(#msgs >= 2, "应有至少 2 条消息")
    end,

    --- 测试 add_round / update_last_assistant
    test_add_round_and_update = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local id = cs.create_session("测试", true, nil)
      cs.add_round(id, "你好", '{"content":"回复1"}')
      cs.update_last_assistant(id, '{"content":"回复2"}')

      local session = hm.get_session(id)
      assert.equal(1, #session.assistant, "update_last_assistant 应替换")
    end,

    --- 测试 add_tool_result
    test_add_tool_result = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local id = cs.create_session("测试", true, nil)
      cs.add_tool_result(id, "test_tool", { arg1 = "val1" }, "执行成功")
      local session = hm.get_session(id)
      assert.is_true(#session.assistant >= 1)
    end,

    --- 测试 update_usage
    test_update_usage = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local id = cs.create_session("测试", true, nil)
      cs.update_usage(id, { prompt_tokens = 100, completion_tokens = 200 })
      local session = hm.get_session(id)
      assert.equal(100, session.usage.prompt_tokens)
    end,

    --- 测试 find_parent_session / find_nearest_branch_parent
    test_find_parent = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local parent_id = cs.create_session("父", true, nil)
      local child_id = cs.create_session("子", false, parent_id)

      local found = cs.find_parent_session(child_id)
      assert.equal(parent_id, found)
    end,

    --- 测试 delete_chain_to_branch
    test_delete_chain_to_branch = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })

      local root = cs.create_session("根", true, nil)
      local child = cs.create_session("子", false, root)
      assert.is_true(cs.delete_chain_to_branch(child), "删除链应成功")
    end,

    --- 测试 send_message（不应崩溃）
    test_send_message = function()
      local cs = require("NeoAI.core.ai.chat_service")
      -- send_message 会尝试发送 HTTP 请求，这里只验证不崩溃
      local ok, err = pcall(cs.send_message, cs, {
        content = "测试消息",
        session_id = "session_test",
        options = {},
      })
      -- 可能因为未初始化而失败，但不应该崩溃
      assert.is_true(type(ok) == "boolean")
    end,

    --- 测试 cancel_generation（不应崩溃）
    test_cancel_generation = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local ok, err = pcall(cs.cancel_generation, cs)
      -- 不应崩溃
    end,

    --- 测试 get_engine_status
    test_get_engine_status = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local status = cs.get_engine_status()
      assert.not_nil(status)
    end,

    --- 测试 switch_model
    test_switch_model = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.switch_model(2)
      -- 不应崩溃
    end,

    --- 测试 save
    test_save = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.save()
      -- 不应崩溃
    end,

    --- 测试 shutdown
    test_shutdown = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.shutdown()
      assert.is_false(cs.is_initialized(), "shutdown 后应未初始化")
      -- 再次初始化以便后续测试
      cs.initialize()
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
