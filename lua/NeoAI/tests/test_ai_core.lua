--- 测试: AI 核心模块 (Part 1)
--- 合并了 test_ai_engine, test_chat_service, test_response_retry
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  test._logger.info("\n=== test_ai_core ===")

  local function setup_engine_config()
    local merger = require("NeoAI.core.config.merger")
    merger.set_config({
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
    })
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
      ai_engine.set_tools({
        test_tool = {
          func = function()
            return "ok"
          end,
          description = "测试工具",
          parameters = { type = "object", properties = {}, required = {} },
        },
      })
      local status = ai_engine.get_status()
      assert.is_true(status.tools_available, "工具应可用")
      ai_engine.set_tools(nil)
    end,

    test_engine_process_query = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      local ok, err = pcall(function()
        ai_engine.process_query("测试查询", {})
      end)
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
      if not ai_engine.get_status().initialized then
        ai_engine.initialize({ config = {} })
      end
      local status = ai_engine.get_status()
      assert.not_nil(status)
      assert.not_nil(status.initialized)
      assert.not_nil(status.is_generating)
      assert.not_nil(status.submodules)
    end,

    test_engine_submodule_interfaces = function()
      local ai_engine = require("NeoAI.core.ai.ai_engine")
      assert.is_true(
        type(ai_engine.estimate_request_tokens({ messages = {} })) == "number",
        "estimate_request_tokens 应返回数字"
      )
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
      ai_engine.auto_name_session("session_1", "测试消息", function(success, result)
        called = true
        assert.is_false(success, "未初始化时应返回失败")
      end)
      local wait_start = vim.uv.now()
      while vim.uv.now() - wait_start < 100 do
        if called then
          break
        end
        vim.uv.run("once")
      end
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
      local ok, err =
        pcall(cs.send_message, cs, { content = "测试消息", session_id = "session_test", options = {} })
      assert.is_true(type(ok) == "boolean")
    end,

    test_chat_cancel_generation = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local ok, err = pcall(cs.cancel_generation, cs)
    end,

    test_chat_get_engine_status = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local ok, status = pcall(cs.get_engine_status, cs)
      if ok then
        assert.not_nil(status)
      end
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
      assert.is_true(
        rr.detect_abnormal_response("一些文本\n```lua\nlocal x = 1", nil, {}),
        "未闭合代码块应视为异常"
      )
      assert.is_true(rr.detect_abnormal_response("这是一段话,", nil, {}), "以英文逗号结尾应视为截断")
    end,

    test_retry_detect_abnormal_tool_calls = function()
      local rr = require("NeoAI.core.ai.response_retry")
      local abnormal, reason = rr.detect_abnormal_response(
        "",
        { { ["function"] = { name = "read_file", arguments = "" } } },
        { is_tool_loop = true }
      )
      assert.is_true(abnormal, "空参数工具调用应视为异常")
      local abnormal2, reason2 = rr.detect_abnormal_response("", {
        { ["function"] = { name = "read_file", arguments = '{"path":"/tmp/test"}' } },
        { ["function"] = { name = "read_file", arguments = '{"path":"/tmp/test"}' } },
      }, { is_tool_loop = true })
      assert.is_true(abnormal2, "重复工具调用应视为异常")
    end,

    test_retry_detect_normal = function()
      local rr = require("NeoAI.core.ai.response_retry")
      local abnormal, reason = rr.detect_abnormal_response("这是一个正常的响应内容。", nil, {})
      assert.is_false(abnormal, "正常响应不应视为异常")
      assert.equal(nil, reason)
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

    -- ========== tool_orchestrator ==========
    test_orchestrator_initialize = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc._test_reset()
      orc.initialize({})
      orc.initialize({})
    end,

    test_orchestrator_register_unregister_session = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_session_1", 1001)
      orc.register_session("test_session_2", 1002)
      orc.register_session("test_session_1", 1001)
      assert.is_true(#orc.get_all_session_ids() >= 2, "应有至少2个会话")
      orc.unregister_session("test_session_1")
      orc.unregister_session("test_session_2")
    end,

    test_orchestrator_get_session_state = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_state", 2001)
      local ss = orc.get_session_state("test_state")
      assert.not_nil(ss, "应返回会话状态")
      assert.equal("test_state", ss.session_id)
      assert.equal(2001, ss.window_id)
      assert.equal(nil, orc.get_session_state("nonexistent"))
      orc.unregister_session("test_state")
    end,

    test_orchestrator_set_get_tools = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.set_tools({ test_tool = { func = function() end } })
      assert.not_nil(orc.get_tools().test_tool)
    end,

    test_orchestrator_iteration = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_iter", 3001)
      assert.equal(0, orc.get_current_iteration("test_iter"), "初始迭代次数应为0")
      orc.reset_iteration("test_iter")
      orc.unregister_session("test_iter")
    end,

    test_orchestrator_executing = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_exec", 5001)
      assert.is_false(orc.is_executing("test_exec"))
      orc.unregister_session("test_exec")
    end,

    test_orchestrator_stop_requested = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_stop", 6001)
      assert.is_false(orc.is_stop_requested("test_stop"))
      orc.request_stop("test_stop")
      assert.is_true(orc.is_stop_requested("test_stop"))
      orc.reset_stop_requested("test_stop")
      assert.is_false(orc.is_stop_requested("test_stop"))
      orc.unregister_session("test_stop")
    end,

    test_orchestrator_request_stop_all = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_all_1", 7001)
      orc.register_session("test_all_2", 7002)
      orc.request_stop()
      assert.is_true(orc.is_stop_requested("test_all_1"))
      assert.is_true(orc.is_stop_requested("test_all_2"))
      orc.reset_stop_requested()
      orc.unregister_session("test_all_1")
      orc.unregister_session("test_all_2")
    end,

    test_orchestrator_start_async_loop = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_loop", 8001)
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

    test_orchestrator_on_generation_complete = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      local ok, err = pcall(
        orc.on_generation_complete,
        orc,
        { generation_id = "gen_test", session_id = "session_test", tool_calls = {}, content = "", usage = {} }
      )
    end,

    test_orchestrator_set_shutting_down = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      local sf = require("NeoAI.core.shutdown_flag")
      sf.reset()
      orc.set_shutting_down()
      assert.is_true(sf.is_set())
      sf.reset()
    end,

    test_orchestrator_cleanup_all = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.register_session("test_cleanup", 9001)
      orc.cleanup_all()
      assert.is_true(#orc.get_all_session_ids() == 0, "清理后应无会话")
    end,

    test_orchestrator_shutdown = function()
      local orc = require("NeoAI.core.ai.tool_orchestrator")
      orc.shutdown()
      orc.initialize({})
    end,

    -- ========== request_adapter ==========
    test_adapter_default_adapters = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local types = ra.get_available_types()
      assert.contains(types, "openai", "应包含 openai 适配器")
      assert.contains(types, "anthropic", "应包含 anthropic 适配器")
      assert.contains(types, "google", "应包含 google 适配器")
    end,

    test_adapter_get_adapter = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      assert.not_nil(ra.get_adapter("openai"), "应获取到 openai 适配器")
      assert.not_nil(ra.get_adapter("anthropic"), "应获取到 anthropic 适配器")
      assert.not_nil(ra.get_adapter("google"), "应获取到 google 适配器")
      assert.equal(nil, ra.get_adapter("nonexistent"))
    end,

    test_adapter_get_adapter_name = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      assert.equal("OpenAI 兼容格式", ra.get_adapter_name("openai"))
      assert.equal("Unknown", ra.get_adapter_name("nonexistent"))
    end,

    test_adapter_openai_transform_request = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_request({
        model = "gpt-4",
        messages = { { role = "user", content = "hello" } },
        stream = true,
        extra_body = { thinking = { type = "enabled" } },
      }, "openai", {})
      assert.equal("gpt-4", result.model)
      assert.equal("enabled", result.thinking.type)
    end,

    test_adapter_openai_transform_response = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local response = {
        id = "chatcmpl-123",
        choices = { { index = 0, message = { role = "assistant", content = "Hello!" }, finish_reason = "stop" } },
        usage = { prompt_tokens = 10, completion_tokens = 20 },
      }
      assert.equal(response, ra.transform_response(response, "openai"))
    end,

    test_adapter_openai_get_headers = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local headers = ra.get_headers("sk-test", "openai")
      assert.equal("Bearer sk-test", headers["Authorization"])
      assert.equal("application/json", headers["Content-Type"])
    end,

    test_adapter_anthropic_transform_request = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_request({
        model = "claude-sonnet-4-20250514",
        messages = {
          { role = "system", content = "You are a helpful assistant." },
          { role = "user", content = "Hello" },
          { role = "assistant", content = "Hi!" },
        },
        max_tokens = 4096,
        stream = true,
        temperature = 0.7,
      }, "anthropic", {})
      assert.equal("claude-sonnet-4-20250514", result.model)
      assert.equal("You are a helpful assistant.", result.system)
      assert.equal(2, #result.messages)
    end,

    test_adapter_anthropic_transform_request_with_tools = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_request({
        model = "claude-sonnet-4-20250514",
        messages = {
          { role = "user", content = "Read file" },
          {
            role = "assistant",
            content = "Sure",
            tool_calls = {
              {
                id = "call_1",
                type = "function",
                ["function"] = { name = "read_file", arguments = '{"path":"/tmp/test"}' },
              },
            },
          },
          { role = "tool", tool_call_id = "call_1", content = "file content" },
        },
        tools = {
          {
            type = "function",
            ["function"] = {
              name = "read_file",
              description = "Read a file",
              parameters = { type = "object", properties = {} },
            },
          },
        },
      }, "anthropic", {})
      assert.not_nil(result.tools, "应包含工具定义")
      assert.equal("read_file", result.tools[1].name)
    end,

    test_adapter_anthropic_transform_response = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_response({
        id = "msg_123",
        model = "claude-sonnet-4-20250514",
        stop_reason = "end_turn",
        content = { { type = "text", text = "Hello!" } },
        usage = { input_tokens = 10, output_tokens = 20 },
      }, "anthropic")
      assert.equal("Hello!", result.choices[1].message.content)
      assert.equal(10, result.usage.prompt_tokens)
    end,

    test_adapter_anthropic_transform_response_with_tools = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_response({
        id = "msg_456",
        model = "claude-sonnet-4-20250514",
        stop_reason = "tool_use",
        content = {
          { type = "text", text = "Let me read that file." },
          { type = "tool_use", id = "toolu_1", name = "read_file", input = { path = "/tmp/test" } },
        },
      }, "anthropic")
      assert.equal("tool_calls", result.choices[1].finish_reason)
      assert.is_true(#result.choices[1].message.tool_calls > 0)
    end,

    test_adapter_anthropic_transform_response_with_thinking = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_response({
        id = "msg_789",
        model = "claude-sonnet-4-20250514",
        stop_reason = "end_turn",
        content = {
          { type = "thinking", thinking = "I need to think about this..." },
          { type = "text", text = "Here is my answer." },
        },
      }, "anthropic")
      assert.equal("Here is my answer.", result.choices[1].message.content)
      assert.equal("I need to think about this...", result.choices[1].message.reasoning_content)
    end,

    test_adapter_anthropic_get_headers = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local headers = ra.get_headers("sk-ant-test", "anthropic")
      assert.equal("sk-ant-test", headers["x-api-key"])
      assert.equal("2023-06-01", headers["anthropic-version"])
    end,

    test_adapter_google_transform_request = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_request({
        model = "gemini-2.0-flash",
        messages = {
          { role = "system", content = "You are a helpful assistant." },
          { role = "user", content = "Hello" },
        },
        temperature = 0.5,
        max_tokens = 100,
      }, "google", {})
      assert.not_nil(result.contents)
      assert.not_nil(result.system_instruction)
      assert.not_nil(result.generation_config)
    end,

    test_adapter_google_transform_response = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_response({
        model = "gemini-2.0-flash",
        candidates = { { content = { parts = { { text = "Hello!" } } }, finishReason = "STOP" } },
        usageMetadata = { promptTokenCount = 10, candidatesTokenCount = 20 },
      }, "google")
      assert.equal("Hello!", result.choices[1].message.content)
      assert.equal(10, result.usage.prompt_tokens)
    end,

    test_adapter_google_transform_response_with_function = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local result = ra.transform_response({
        model = "gemini-2.0-flash",
        candidates = {
          {
            content = { parts = { { functionCall = { name = "read_file", args = { path = "/tmp/test" } } } } },
            finishReason = "FUNCTION_CALL",
          },
        },
      }, "google")
      assert.equal("tool_calls", result.choices[1].finish_reason)
      assert.is_true(#result.choices[1].message.tool_calls > 0)
    end,

    test_adapter_google_get_headers = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local headers = ra.get_headers("AIza-test", "google")
      assert.equal("AIza-test", headers["x-goog-api-key"])
    end,

    test_adapter_fallback = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      local request = { model = "test", messages = { { role = "user", content = "hi" } } }
      assert.equal("test", ra.transform_request(request, "nonexistent_type", {}).model)
      local response = { id = "test" }
      assert.equal(response, ra.transform_response(response, "nonexistent_type"))
      assert.equal("Bearer sk-test", ra.get_headers("sk-test", "nonexistent_type")["Authorization"])
    end,

    test_adapter_register_adapter = function()
      local ra = require("NeoAI.core.ai.request_adapter")
      ra.register_adapter("custom", {
        name = "Custom Adapter",
        transform_request = function(request)
          return request
        end,
        transform_response = function(response)
          return response
        end,
        get_headers = function(api_key)
          return { ["Authorization"] = "Custom " .. api_key }
        end,
      })
      assert.equal("Custom Adapter", ra.get_adapter("custom").name)
      assert.equal("Custom test-key", ra.get_headers("test-key", "custom")["Authorization"])
    end,

    -- ========== request_builder ==========
    test_builder_format_messages_basic = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result =
        rb.format_messages({ { role = "user", content = "你好" }, { role = "assistant", content = "你好！" } })
      assert.is_true(#result >= 2)
      assert.equal("user", result[1].role)
    end,

    test_builder_format_messages_dedup = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.format_messages({
        { role = "user", content = "hello" },
        { role = "user", content = "hello" },
        { role = "assistant", content = "hi" },
      })
      assert.equal(2, #result, "重复消息应被去重")
    end,

    test_builder_format_messages_fold_filter = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.format_messages({
        { role = "user", content = "你好" },
        { role = "assistant", content = "{{{ 工具调用\n内容\n}}}" },
      })
      assert.equal("", result[2].content, "折叠文本应被过滤")
    end,

    test_builder_format_messages_tool = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.format_messages({
        {
          role = "assistant",
          content = "让我查一下",
          tool_calls = { { id = "call_1", type = "function", ["function"] = { name = "read_file", arguments = "{}" } } },
        },
        { role = "tool", tool_call_id = "call_1", content = "文件内容" },
      })
      assert.is_true(#result >= 2)
    end,

    test_builder_format_messages_empty = function()
      local rb = require("NeoAI.core.ai.request_builder")
      assert.is_true(#rb.format_messages(nil) == 0, "nil 应返回空表")
      assert.is_true(#rb.format_messages({}) == 0, "空表应返回空表")
    end,

    test_builder_build_tool_result_message = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local msg = rb.build_tool_result_message("call_1", "执行成功", "test_tool")
      assert.equal("tool", msg.role)
      assert.equal("call_1", msg.tool_call_id)
      local msg2 = rb.build_tool_result_message(nil, "result")
      assert.not_nil(msg2.tool_call_id, "应自动生成 tool_call_id")
    end,

    test_builder_add_tool_call_to_history = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.add_tool_call_to_history(
        { { role = "user", content = "执行工具" } },
        { id = "call_1", type = "function", ["function"] = { name = "test_tool", arguments = "{}" } },
        "成功"
      )
      assert.is_true(#result >= 3)
    end,

    test_builder_build_request_basic = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local request = rb.build_request({
        messages = { { role = "user", content = "hello" } },
        options = { model = "gpt-4", stream = true, tools_enabled = false },
        session_id = "session_1",
      })
      assert.not_nil(request)
      assert.equal("gpt-4", request.model)
      assert.is_true(request.stream)
    end,

    test_builder_build_request_reasoning = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local request = rb.build_request({
        messages = { { role = "user", content = "思考问题" } },
        options = { model = "deepseek-reasoner", reasoning_enabled = true, tools_enabled = false },
      })
      assert.equal("enabled", request.extra_body.thinking.type)
      local request2 = rb.build_request({
        messages = { { role = "user", content = "简单问题" } },
        options = { model = "gpt-4", reasoning_enabled = false, tools_enabled = false },
      })
      assert.equal("disabled", request2.extra_body.thinking.type)
    end,

    test_builder_estimate_tokens = function()
      local rb = require("NeoAI.core.ai.request_builder")
      assert.equal(0, rb.estimate_tokens(""))
      assert.equal(0, rb.estimate_tokens(nil))
      assert.is_true(rb.estimate_tokens("hello world") > 0)
    end,

    test_builder_estimate_message_tokens = function()
      local rb = require("NeoAI.core.ai.request_builder")
      assert.is_true(
        rb.estimate_message_tokens({ { role = "user", content = "hello" }, { role = "assistant", content = "world" } })
          > 0
      )
      assert.equal(0, rb.estimate_message_tokens(nil))
    end,

    test_builder_estimate_request_tokens = function()
      local rb = require("NeoAI.core.ai.request_builder")
      assert.is_true(rb.estimate_request_tokens({ messages = { { role = "user", content = "hello" } } }) > 0)
      assert.equal(0, rb.estimate_request_tokens(nil))
    end,

    test_builder_reset_first_request = function()
      local rb = require("NeoAI.core.ai.request_builder")
      rb.reset_first_request()
      rb.set_tool_definitions({ { type = "function", ["function"] = { name = "test_tool" } } })
    end,

    test_builder_format_messages_placeholder = function()
      local rb = require("NeoAI.core.ai.request_builder")
      local result = rb.format_messages({ { role = "tool", content = "无 tool_call_id 的工具结果" } })
      assert.equal("user", result[1].role, "无 tool_call_id 的 tool 消息应转为 user")
    end,

    -- ========== stream_processor ==========
    test_stream_create_processor = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      assert.not_nil(processor)
      assert.equal("gen_1", processor.generation_id)
      assert.equal("", processor.content_buffer)
      assert.is_false(processor.is_finished)
    end,

    test_stream_process_chunk_content = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local result = sp.process_chunk(processor, { choices = { { delta = { content = "Hello" } } } })
      assert.equal("Hello", result.content)
      assert.equal("Hello", processor.content_buffer)
    end,

    test_stream_process_chunk_reasoning = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local result = sp.process_chunk(processor, { choices = { { delta = { reasoning_content = "思考中..." } } } })
      assert.equal("思考中...", result.reasoning_content)
    end,

    test_stream_process_chunk_tool_calls = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local chunk1 = { choices = { { delta = { tool_calls = { { index = 0, id = "call_1", type = "function" } } } } } }
      chunk1.choices[1].delta.tool_calls[1]["function"] = { name = "read_file", arguments = '{"path"' }
      sp.process_chunk(processor, chunk1)
      local chunk2 = { choices = { { delta = { tool_calls = { { index = 0 } } } } } }
      chunk2.choices[1].delta.tool_calls[1]["function"] = { arguments = ':"/tmp/test"}' }
      local result2 = sp.process_chunk(processor, chunk2)
      assert.equal('{"path":"/tmp/test"}', processor.tool_calls[1]["function"].arguments)
    end,

    test_stream_process_chunk_finish = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local result =
        sp.process_chunk(processor, { choices = { { delta = { content = "完成" }, finish_reason = "stop" } } })
      assert.is_true(result.is_final, "应标记为最终")
      assert.is_true(processor.is_finished, "处理器应标记为完成")
    end,

    test_stream_process_chunk_usage = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local result = sp.process_chunk(processor, {
        choices = { { delta = { content = "done" }, finish_reason = "stop" } },
        usage = { prompt_tokens = 10, completion_tokens = 20, total_tokens = 30 },
      })
      assert.equal(10, result.usage.prompt_tokens)
    end,

    test_stream_process_chunk_finished = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      processor.is_finished = true
      assert.equal(
        nil,
        sp.process_chunk(processor, { choices = { { delta = { content = "extra" } } } }),
        "已完成的处理器应返回 nil"
      )
    end,

    test_stream_process_chunk_message_tool_calls = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local processor = sp.create_processor("gen_1", "session_1", 1001)
      local result = sp.process_chunk(processor, {
        choices = {
          {
            message = {
              tool_calls = {
                { index = 0, id = "call_msg", type = "function", ["function"] = { name = "test", arguments = "{}" } },
              },
            },
          },
        },
      })
      assert.is_true(#result.tool_calls > 0)
    end,

    test_stream_filter_valid_tool_calls = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      local valid = sp.filter_valid_tool_calls({
        { ["function"] = { name = "valid_tool", arguments = "{}" } },
        { ["function"] = { name = "", arguments = "{}" } },
        { ["function"] = { name = "valid_tool2", arguments = "" } },
      })
      assert.equal(1, #valid, "应只保留 1 个有效工具调用")
      assert.is_true(#sp.filter_valid_tool_calls({}) == 0, "空列表应返回空表")
    end,

    test_stream_reasoning_throttle = function()
      local sp = require("NeoAI.core.ai.stream_processor")
      sp.clear_reasoning_throttle()
      local processor = sp.create_processor("gen_2", "session_2", 1002)
      sp.push_reasoning_content("gen_2", "思考", processor, {})
      sp.push_reasoning_content("gen_2", "过程", processor, {})
      sp.clear_reasoning_throttle()
      sp.clear_reasoning_throttle()
    end,
  })
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
