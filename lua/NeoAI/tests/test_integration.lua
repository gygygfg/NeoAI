--- 端到端集成测试
--- 测试流程：setup → HTTP请求 → 工具循环 → 会话管理 → 自动命名 → shutdown
local M = {}
local test

local function clean_package_cache()
  local patterns = { "^NeoAI%.", "^NeoAI$" }
  for modname, _ in pairs(package.loaded) do
    for _, p in ipairs(patterns) do
      if modname:match(p) then package.loaded[modname] = nil; break end
    end
  end
end

local function is_headless()
  return vim.env.NVIM_HEADLESS or #vim.api.nvim_list_uis() == 0
end

local function safe_wait(timeout_ms, cond)
  if is_headless() then return vim.wait(timeout_ms, cond, 50) end
  local deadline = vim.uv.now() + timeout_ms
  while vim.uv.now() < deadline do
    if cond() then return true end
    vim.uv.run("once")
  end
  return false
end

local function make_config()
  return {
    ai = {
      default = "chat",
      providers = {
        deepseek = {
          api_type = "openai",
          base_url = "https://api.deepseek.com/chat/completions",
          api_key = os.getenv("DEEPSEEK_API_KEY") or "sk-test-placeholder",
          models = { "deepseek-chat" },
        },
      },
      scenarios = {
        chat = { provider = "deepseek", model_name = "deepseek-chat", temperature = 0.7, max_tokens = 100, stream = false, timeout = 30000 },
        tools = { provider = "deepseek", model_name = "deepseek-chat", temperature = 0.1, max_tokens = 500, stream = false, timeout = 60000 },
        naming = { provider = "deepseek", model_name = "deepseek-chat", temperature = 0.3, max_tokens = 50, stream = false, timeout = 10000 },
      },
    },
    ui = { default_ui = "chat", window_mode = "float", window = { width = 80, height = 20, border = "rounded" } },
    session = { auto_save = false, auto_naming = false, save_path = "/tmp/neoai_test_integration", max_history_per_session = 100 },
    tools = { enabled = true, builtin = false, approval = { default_auto_allow = true } },
    keymaps = { global = { open_tree = { key = "<leader>tt" }, open_chat = { key = "<leader>cc" } } },
    log = { level = "ERROR" },
  }
end

function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  test._logger.info("\n=== test_integration ===")

  local has_api_key = false
  local api_key = os.getenv("DEEPSEEK_API_KEY")
  if api_key and api_key ~= "" and not api_key:find("sk%-test") then has_api_key = true end

  return test.run_tests({
    -- 1. 完整初始化 + 命令 + 模块验证
    test_01_setup_and_verify = function()
      clean_package_cache()
      local neoai = require("NeoAI")
      neoai.setup(make_config())

      local config = require("NeoAI.core").get_config()
      assert.not_nil(config)
      assert.equal("deepseek-chat", config.ai.scenarios.chat.model_name)

      local cmds = vim.api.nvim_get_commands({})
      for _, name in ipairs({ "NeoAIOpen", "NeoAIClose", "NeoAITree", "NeoAIChat", "NeoAIKeymaps", "NeoAIChatStatus" }) do
        assert.not_nil(cmds[name], name .. " 命令应已注册")
      end

      local status = neoai.get_ai_engine().get_status()
      assert.is_true(status.initialized)
      assert.is_true(require("NeoAI.core.ai.chat_service").is_initialized())
      assert.not_nil(neoai.get_keymap_manager())
      assert.not_nil(neoai.get_tools())
    end,

    -- 2. 工具注册 + 执行 + 引擎注入 + 编排器
    test_02_tool_operations = function()
      local neoai = require("NeoAI")
      local tools = neoai.get_tools()
      local tr = require("NeoAI.tools.tool_registry")
      if tr.exists("integration_test_tool") then tr.unregister("integration_test_tool") end

      local ok = tools.register_tool({
        name = "integration_test_tool", description = "集成测试工具",
        func = function(args) return "工具执行成功，输入为: " .. (args and args.input or "") end,
        parameters = { type = "object", properties = { input = { type = "string", description = "输入文本" } }, required = {} },
        category = "test", approval = { auto_allow = true },
      })
      assert.is_true(ok)
      assert.equal("integration_test_tool", tools.get_tool("integration_test_tool").name)
      assert.equal("工具执行成功，输入为: hello", tools.execute_tool("integration_test_tool", { input = "hello" }))
      assert.is_true(tools.get_tool_count() >= 1)

      neoai.get_ai_engine().set_tools({
        integration_test_tool = {
          func = function(args) return "工具执行成功，输入为: " .. (args and args.input or "") end,
          description = "集成测试工具",
          parameters = { type = "object", properties = { input = { type = "string", description = "输入文本" } }, required = {} },
        },
      })

      local tool_orch = require("NeoAI.core.ai.tool_orchestrator")
      local sid = "session_orch_" .. os.time()
      tool_orch.register_session(sid, nil)
      assert.not_nil(tool_orch.get_session_state(sid))
      assert.is_false(tool_orch.is_executing(sid))
      assert.equal(0, tool_orch.get_current_iteration(sid))
      tool_orch.request_stop(sid)
      assert.is_true(tool_orch.is_stop_requested(sid))
      tool_orch.reset_stop_requested(sid)
      assert.is_false(tool_orch.is_stop_requested(sid))
      tool_orch.unregister_session(sid)
      assert.is_nil(tool_orch.get_session_state(sid))
    end,

    -- 3. AI 引擎非流式消息
    test_03_ai_engine_message = function()
      if not has_api_key then test._logger.warn("  ⚠ 跳过：未设置 DEEPSEEK_API_KEY"); return end
      local engine = require("NeoAI").get_ai_engine()
      local cs = require("NeoAI.core.ai.chat_service")
      local sid = cs.create_session("集成测试", true, nil)
      assert.not_nil(sid)

      local done, result = false, nil
      local id = vim.api.nvim_create_autocmd("User", {
        pattern = "NeoAI:generation_completed",
        callback = function(args) done = true; result = args.data end,
      })

      engine.generate_response({ { role = "user", content = "请用一句话回答：中国的首都是哪个城市？" } }, {
        session_id = sid, options = { stream = false, temperature = 0.1, max_tokens = 50 },
      })
      safe_wait(30000, function() return done end)
      pcall(vim.api.nvim_del_autocmd, id)

      assert.is_true(done, "生成应在超时前完成")
      assert.not_nil(result)
      assert.not_nil(result.response)
      assert.is_true(#result.response > 0)
      assert.is_true(result.response:find("北京") ~= nil, "响应应包含'北京'，实际: " .. result.response:sub(1, 200))
      assert.not_nil(result.usage)
      test._logger.info("  ✓ AI 引擎消息成功，响应: " .. result.response:sub(1, 100))
    end,

    -- 4. 工具循环（流式 + 工具调用）
    test_04_tool_loop = function()
      if not has_api_key then test._logger.warn("  ⚠ 跳过：未设置 DEEPSEEK_API_KEY"); return end
      local engine = require("NeoAI").get_ai_engine()
      local cs = require("NeoAI.core.ai.chat_service")
      cs.initialize()
      engine.set_tools({
        integration_test_tool = {
          func = function(args) return "工具执行成功，输入为: " .. (args and args.input or "") end,
          description = "集成测试工具",
          parameters = { type = "object", properties = { input = { type = "string", description = "输入文本" } }, required = { "input" } },
        },
      })

      local sid = cs.create_session("工具循环测试", true, nil)
      assert.not_nil(sid)

      local events, ids = {}, {}
      for _, name in ipairs({ "NeoAI:generation_completed", "NeoAI:generation_error",
        "NeoAI:tool_loop_started", "NeoAI:tool_execution_completed" }) do
        local id = vim.api.nvim_create_autocmd("User", {
          pattern = name, callback = function() events[name] = (events[name] or 0) + 1 end,
        })
        table.insert(ids, id)
      end

      engine.generate_response({
        { role = "system", content = "你是一个测试助手。当用户说'调用工具'时，必须使用 integration_test_tool 工具。input 参数设为用户消息内容。" },
        { role = "user", content = "调用工具，帮我处理这条消息：Hello World" },
      }, { session_id = sid, options = { stream = true, temperature = 0.1, max_tokens = 300 } })

      safe_wait(90000, function()
        return (events["NeoAI:generation_completed"] or 0) > 0
            or (events["NeoAI:generation_error"] or 0) > 0
      end)
      for _, id in ipairs(ids) do pcall(vim.api.nvim_del_autocmd, id) end

      local gen_ok = (events["NeoAI:generation_completed"] or 0) > 0
      local gen_err = (events["NeoAI:generation_error"] or 0) > 0
      assert.is_true(gen_ok or gen_err, "应至少触发完成或错误事件")

      if (events["NeoAI:tool_loop_started"] or 0) > 0 then
        assert.is_true((events["NeoAI:tool_execution_completed"] or 0) > 0, "工具循环开始后应有工具执行完成事件")
        test._logger.info("  ✓ 工具循环正常，工具执行次数: " .. (events["NeoAI:tool_execution_completed"] or 0))
      end
    end,

    -- 5. 取消生成
    test_05_cancel_generation = function()
      local engine = require("NeoAI").get_ai_engine()
      engine.cancel_generation()
      assert.is_false(engine.get_status().is_generating)
      engine.cancel_generation()
      assert.is_false(engine.get_status().is_generating)
    end,

    -- 6. 会话管理
    test_06_session_management = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")
      local root = cs.create_session("根会话", true, nil)
      assert.not_nil(root)
      local child = cs.create_session("子会话", false, root)
      assert.not_nil(child)
      assert.equal(root, cs.find_parent_session(child))
      cs.add_round(root, "你好", '{"content":"你好！"}')
      assert.is_true(#cs.get_raw_messages(root) >= 2)
      cs.update_usage(root, { prompt_tokens = 50, completion_tokens = 100 })
      assert.equal(50, hm.get_session(root).usage.prompt_tokens)
      cs.rename_session(root, "重命名根会话")
      assert.equal("重命名根会话", cs.get_session(root).name)
      assert.is_true(#cs.list_sessions() >= 2)
      assert.is_true(#cs.get_tree() >= 1)
      assert.is_true(cs.delete_session(child))
      assert.is_nil(cs.get_session(child))
    end,

    -- 7. 自动命名
    test_07_auto_naming = function()
      if not has_api_key then test._logger.warn("  ⚠ 跳过：未设置 DEEPSEEK_API_KEY"); return end
      local engine = require("NeoAI.core.ai.ai_engine")
      local done, result = false, nil
      engine.auto_name_session("session_test_naming", "今天天气怎么样？", function(success, name)
        done = true; result = { success = success, name = name }
      end)
      safe_wait(15000, function() return done end)
      assert.is_true(done, "命名应在超时前完成")
      assert.is_true(result.success, "命名应成功: " .. tostring(result.name))
      assert.is_true(#result.name > 0)
      test._logger.info("  ✓ 自动命名成功，名称: " .. result.name)
    end,

    -- 8. 完整 shutdown
    test_08_shutdown = function()
      local neoai = require("NeoAI")
      local engine = neoai.get_ai_engine()
      engine.shutdown()
      assert.is_false(engine.get_status().initialized)
      require("NeoAI.core.ai.tool_orchestrator").shutdown()
      local hc = require("NeoAI.core.ai.http_client")
      hc.shutdown()
      assert.is_false(hc.get_state().initialized)
      local cs = require("NeoAI.core.ai.chat_service")
      cs.shutdown()
      assert.is_false(cs.is_initialized())
    end,
  })
end

return M
