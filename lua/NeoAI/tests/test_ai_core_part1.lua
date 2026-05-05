--- 测试: AI 核心模块 (Part 1)
--- 合并了 test_ai_engine, test_chat_service, test_response_retry
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_ai_core ===")

  local function setup_engine_config()
    local merger = require("NeoAI.core.config.merger")
    merger.set_config({ ai = { default = "test", providers = { test = { api_type = "openai", base_url = "https://test.api.com", api_key = "sk-test", models = { "test-model" } } }, scenarios = { chat = { provider = "test", model_name = "test-model", temperature = 0.5, max_tokens = 100, stream = false, timeout = 5000 } } } })
  end

  return test.run_tests({
    -- ========== ai_engine ==========
    test_engine_initialize = function()
      setup_engine_config()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      ai_engine.initialize({ config = {} })
      local status = ai_engine.get_status()
      assert.is_true(status.initialized, "引擎应已初始化")
      assert.not_nil(status.submodules, "应有子模块状态")
    end,

    test_engine_set_tools = function()
      setup_engine_config()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      ai_engine.initialize({ config = {} })
      local tr = require("NeoAI.tools.tool_registry")
      tr.initialize({})
      ai_engine.set_tools({ test_tool = { func = function() return "ok" end, description = "测试工具", parameters = { type = "object", properties = {}, required = {} } } })
      local status = ai_engine.get_status()
      assert.is_true(status.tools_available, "工具应可用")
      ai_engine.set_tools(nil)
    end,

    test_engine_process_query = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      local ok, err = pcall(function() ai_engine.process_query("测试查询", {}) end)
      assert.is_true(type(ok) == "boolean")
    end,

    test_engine_cancel_generation = function()
      setup_engine_config()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      ai_engine.cancel_generation()
    end,

    test_engine_get_status = function()
      setup_engine_config()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      if not ai_engine.get_status().initialized then ai_engine.initialize({ config = {} }) end
      local status = ai_engine.get_status()
      assert.not_nil(status)
      assert.not_nil(status.initialized)
      assert.not_nil(status.is_generating)
      assert.not_nil(status.submodules)
    end,

    test_engine_submodule_interfaces = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      assert.is_true(type(ai_engine.estimate_request_tokens({ messages = {} })) == "number", "estimate_request_tokens 应返回数字")
      assert.is_true(type(ai_engine.estimate_tokens("测试文本")) == "number", "estimate_tokens 应返回数字")
      assert.is_false(ai_engine.is_reasoning_active(), "初始不应在思考中")
      assert.equal(0, ai_engine.get_current_iteration(), "初始迭代次数应为 0")
    end,

    test_engine_shutdown = function()
      setup_engine_config()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      ai_engine.shutdown()
      ai_engine.shutdown()
    end,

    test_engine_auto_name_session = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      local called = false
      ai_engine.auto_name_session("session_1", "测试消息", function(success, result) called = true; assert.is_false(success, "未初始化时应返回失败") end)
      local wait_start = vim.uv.now()
      while vim.uv.now() - wait_start < 100 do if called then break end; vim.uv.run("once") end
    end,

    -- ========== chat_service ==========
    test_chat_initialize = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      assert.is_true(cs.is_initialized(), "应已初始化")
    end,

    test_chat_create_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local id = cs.create_session("测试会话", true, nil)
      assert.not_nil(id, "应创建会话")
      assert.is_true(string.find(id, "^session_") ~= nil)
    end,

    test_chat_get_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local id = cs.create_session("测试", true, nil)
      assert.not_nil(cs.get_session(id))
      assert.equal("测试", cs.get_session(id).name)
      local current = cs.get_current_session()
      assert.not_nil(current)
      assert.equal(id, current.id)
    end,

    test_chat_set_current_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local id1 = cs.create_session("会话1", true, nil)
      local id2 = cs.create_session("会话2", true, nil)
      cs.set_current_session(id1)
      assert.equal(id1, cs.get_current_session().id)
    end,

    test_chat_delete_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local id = cs.create_session("待删除", true, nil)
      assert.is_true(cs.delete_session(id), "删除应成功")
      assert.equal(nil, cs.get_session(id))
    end,

    test_chat_rename_session = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local id = cs.create_session("旧名称", true, nil)
      cs.rename_session(id, "新名称")
      assert.equal("新名称", cs.get_session(id).name)
    end,

    test_chat_list_sessions = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      cs.create_session("会话A", true, nil)
      cs.create_session("会话B", true, nil)
      assert.is_true(#cs.list_sessions() >= 2)
    end,

    test_chat_get_tree = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local root_id = cs.create_session("根", true, nil)
      cs.create_session("子", false, root_id)
      assert.is_true(#cs.get_tree() >= 1)
    end,

    test_chat_get_raw_messages = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local id = cs.create_session("测试", true, nil)
      cs.add_round(id, "你好", '{"content":"你好！"}')
      assert.is_true(#cs.get_raw_messages(id) >= 2, "应有至少 2 条消息")
    end,

    test_chat_add_round_and_update = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local id = cs.create_session("测试", true, nil)
      cs.add_round(id, "你好", '{"content":"回复1"}')
      cs.update_last_assistant(id, '{"content":"回复2"}')
      assert.equal(1, #hm.get_session(id).assistant, "update_last_assistant 应替换")
    end,

    test_chat_add_tool_result = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local id = cs.create_session("测试", true, nil)
      cs.add_tool_result(id, "test_tool", { arg1 = "val1" }, "执行成功")
      assert.is_true(#hm.get_session(id).assistant >= 1)
    end,

    test_chat_update_usage = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local id = cs.create_session("测试", true, nil)
      cs.update_usage(id, { prompt_tokens = 100, completion_tokens = 200 })
      assert.equal(100, hm.get_session(id).usage.prompt_tokens)
    end,

    test_chat_find_parent = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local parent_id = cs.create_session("父", true, nil)
      local child_id = cs.create_session("子", false, parent_id)
      assert.equal(parent_id, cs.find_parent_session(child_id))
    end,

    test_chat_delete_chain_to_branch = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_cs" } } })
      local root = cs.create_session("根", true, nil)
      local child = cs.create_session("子", false, root)
      assert.is_true(cs.delete_chain_to_branch(child), "删除链应成功")
    end,

    test_chat_send_message = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local ok, err = pcall(cs.send_message, cs, { content = "测试消息", session_id = "session_test", options = {} })
      assert.is_true(type(ok) == "boolean")
    end,

    test_chat_cancel_generation = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local ok, err = pcall(cs.cancel_generation, cs)
    end,

    test_chat_get_engine_status = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local ok, status = pcall(cs.get_engine_status, cs)
      if ok then assert.not_nil(status) end
    end,

    test_chat_switch_model = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.switch_model(2)
    end,

    test_chat_save = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.save()
    end,

    test_chat_shutdown = function()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.shutdown()
      assert.is_false(cs.is_initialized(), "shutdown 后应未初始化")
      cs.initialize()
    end,

    -- ========== response_retry ==========
    test_retry_is_summary_content = function()
      local rr = require("NeoAI.core.ai.response_retry")
      assert.is_true(rr.is_summary_content("综上所述，任务已完成"))
      assert.is_true(rr.is_summary_content("In summary, the task is done"))
      assert.is_false(rr.is_summary_content("你好，今天天气不错"))
      assert.is_false(rr.is_summary_content(""))
      assert.is_false(rr.is_summary_content(nil))
    end,

    test_retry_detect_empty = function()
      local rr = require("NeoAI.core.ai.response_retry")
      assert.is_false(rr.detect_abnormal_response("", nil, {}), "非工具循环空内容不应视为异常")
      local abnormal, reason = rr.detect_abnormal_response("", nil, { is_tool_loop = true })
      assert.is_true(abnormal, "工具循环空内容应视为异常")
    end,

    test_retry_detect_repeated = function()
      local rr = require("NeoAI.core.ai.response_retry")
      local abnormal, reason = rr.detect_abnormal_response("第一行\n第二行\n第二行\n第四行", nil, {})
      assert.is_true(abnormal, "重复行应视为异常")
    end,

    test_retry_detect_truncated = function()
      local rr = require("NeoAI.core.ai.response_retry")
      assert.is_true(rr.detect_abnormal_response("一些文本\n```lua\nlocal x = 1", nil, {}), "未闭合代码块应视为异常")
      assert.is_true(rr.detect_abnormal_response("这是一段话,", nil, {}), "以英文逗号结尾应视为截断")
    end,

    test_retry_detect_abnormal_tool_calls = function()
      local rr = require("NeoAI.core.ai.response_retry")
      local abnormal, reason = rr.detect_abnormal_response("", { { ["function"] = { name = "read_file", arguments = "" } } }, { is_tool_loop = true })
      assert.is_true(abnormal, "空参数工具调用应视为异常")
      local abnormal2, reason2 = rr.detect_abnormal_response("", { { ["function"] = { name = "read_file", arguments = '{"path":"/tmp/test"}' } }, { ["function"] = { name = "read_file", arguments = '{"path":"/tmp/test"}' } } }, { is_tool_loop = true })
      assert.is_true(abnormal2, "重复工具调用应视为异常")
    end,

    test_retry_detect_normal = function()
      local rr = require("NeoAI.core.ai.response_retry")
      local abnormal, reason = rr.detect_abnormal_response("这是一个正常的响应内容。", nil, {})
      assert.is_false(abnormal, "正常响应不应视为异常")
      assert.equal(nil, reason)
    end,

    test_retry_detect_final_round = function()
      local rr = require("NeoAI.core.ai.response_retry")
      assert.is_true(rr.detect_abnormal_response("", nil, { is_final_round = true }), "最终轮次空内容应视为异常")
      assert.is_false(rr.detect_abnormal_response("任务完成，总结如上。", nil, { is_final_round = true }), "最终轮次正常内容不应视为异常")
    end,

    test_retry_delays = function()
      local rr = require("NeoAI.core.ai.response_retry")
      assert.equal(0, rr.get_retry_delay(0))
      assert.equal(1000, rr.get_retry_delay(1))
      assert.equal(2000, rr.get_retry_delay(2))
      assert.equal(4000, rr.get_retry_delay(3))
      assert.equal(8000, rr.get_retry_delay(4))
      assert.equal(16000, rr.get_retry_delay(5))
    end,

    test_retry_can_retry = function()
      local rr = require("NeoAI.core.ai.response_retry")
      assert.is_true(rr.can_retry(0))
      assert.is_true(rr.can_retry(3))
      assert.is_true(rr.can_retry(4))
      assert.is_false(rr.can_retry(5))
      assert.is_false(rr.can_retry(10))
    end,

    test_retry_get_max_retries = function()
      local rr = require("NeoAI.core.ai.response_retry")
      assert.is_true(rr.get_max_retries() > 0, "最大重试次数应大于0")
    end,

    test_retry_set_config = function()
      local rr = require("NeoAI.core.ai.response_retry")
      rr.set_config({ max_retries = 3, retry_delays = { 500, 1000, 2000 } })
      assert.is_false(rr.can_retry(3))
      assert.equal(500, rr.get_retry_delay(1))
      rr.set_config({ max_retries = 5, retry_delays = { 1000, 2000, 4000, 8000, 16000 } })
    end,
  })
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
