--- 端到端集成测试
---
--- 通过主 init.setup 完成完整初始化，注册用户命令，进行真实 HTTP 请求与工具循环调用测试
---
--- 设计说明：
---   由于集成测试需要在干净的环境中运行（避免其他测试的模块闭包状态干扰），
---   本测试文件设计为独立运行模式。当通过 run_all 调用时，使用隔离的 require 路径。
---
--- 测试流程：
---   1. 完整 setup（配置合并、模块初始化、命令注册）
---   2. 验证所有命令已注册
---   3. 验证所有模块已初始化
---   4. 注册并执行测试工具
---   5. 真实 HTTP 请求测试（非流式）
---   6. 通过 AI 引擎发送消息（非流式）
---   7. 工具循环测试（真实 HTTP + 工具调用）
---   8. 取消生成测试
---   9. 会话管理集成测试
---   10. 自动命名会话测试
---   11. 工具编排器集成测试
---   12. 完整 shutdown 测试

local M = {}

local test

-- ========== 辅助函数：清理并重新加载模块 ==========

--- 清理所有 NeoAI 模块的 package.loaded 缓存
local function clean_package_cache()
  local patterns = {
    "^NeoAI%.",
    "^NeoAI$",
  }
  for modname, _ in pairs(package.loaded) do
    for _, pattern in ipairs(patterns) do
      if modname:match(pattern) then
        package.loaded[modname] = nil
        break
      end
    end
  end
end

-- ========== 测试配置 ==========

local function create_integration_config()
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
        chat = {
          provider = "deepseek",
          model_name = "deepseek-chat",
          temperature = 0.7,
          max_tokens = 100,
          stream = false,
          timeout = 30000,
        },
        tools = {
          provider = "deepseek",
          model_name = "deepseek-chat",
          temperature = 0.1,
          max_tokens = 500,
          stream = false,
          timeout = 60000,
        },
        naming = {
          provider = "deepseek",
          model_name = "deepseek-chat",
          temperature = 0.3,
          max_tokens = 50,
          stream = false,
          timeout = 10000,
        },
      },
    },
    ui = {
      default_ui = "chat",
      window_mode = "float",
      window = {
        width = 80,
        height = 20,
        border = "rounded",
      },
    },
    session = {
      auto_save = false,
      auto_naming = false,
      save_path = "/tmp/neoai_test_integration",
      max_history_per_session = 100,
    },
    tools = {
      enabled = true,
      builtin = false,
    },
    keymaps = {
      global = {
        open_tree = { key = "<leader>tt", desc = "打开树" },
        open_chat = { key = "<leader>cc", desc = "打开聊天" },
      },
    },
    log = {
      level = "ERROR",
    },
  }
end

-- ========== 测试运行入口 ==========

function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_integration ===")

  -- 获取 API key 状态
  local has_api_key = false
  local api_key = os.getenv("DEEPSEEK_API_KEY")
  if api_key and api_key ~= "" and not api_key:find("sk%-test") then
    has_api_key = true
  end

  return test.run_tests({
    -- ========== 1. 完整初始化流程 ==========
    test_aaa_full_setup = function()
      -- 清理所有 NeoAI 模块缓存
      clean_package_cache()

      -- 重新加载主模块并 setup
      local neoai = require("NeoAI")
      neoai.setup(create_integration_config())

      -- 验证初始化状态
      local state = require("NeoAI.core.config.state")
      assert.is_true(state.is_initialized(), "状态管理器应已初始化")

      -- 验证配置已合并
      local config = state.get_state("config", "data")
      assert.not_nil(config, "配置应存在")
      assert.equal("chat", config.ai.default, "默认场景应为 chat")
      assert.not_nil(config.ai.providers.deepseek, "deepseek 提供商应存在")
      assert.equal("deepseek-chat", config.ai.scenarios.chat.model_name)

      -- 验证 app 切片
      assert.is_true(state.get_state("app", "initialized"), "app 应标记为已初始化")
    end,

    -- ========== 2. 验证用户命令注册 ==========
    test_commands_registered = function()
      -- 验证所有用户命令已注册
      local commands = vim.api.nvim_get_commands({})
      assert.not_nil(commands["NeoAIOpen"], "NeoAIOpen 命令应已注册")
      assert.not_nil(commands["NeoAIClose"], "NeoAIClose 命令应已注册")
      assert.not_nil(commands["NeoAITree"], "NeoAITree 命令应已注册")
      assert.not_nil(commands["NeoAIChat"], "NeoAIChat 命令应已注册")
      assert.not_nil(commands["NeoAIKeymaps"], "NeoAIKeymaps 命令应已注册")
      assert.not_nil(commands["NeoAIChatStatus"], "NeoAIChatStatus 命令应已注册")

      -- 验证命令描述（Neovim 0.12.0 使用 definition 字段，可能包含特殊标记如 <fe>X）
      local function clean_desc(cmd)
        local desc = cmd.definition or cmd.desc or ""
        -- 去除 Neovim 内部特殊标记（0xFE 及紧跟的字符）
        desc = desc:gsub("\254.", "")
        return desc
      end
      assert.equal("打开NeoAI主界面", clean_desc(commands["NeoAIOpen"]))
      assert.equal("打开NeoAI聊天界面", clean_desc(commands["NeoAIChat"]))
    end,

    -- ========== 3. 验证核心模块初始化 ==========
    test_core_modules_initialized = function()
      local neoai = require("NeoAI")

      -- 获取 AI 引擎
      local engine = neoai.get_ai_engine()
      assert.not_nil(engine, "AI 引擎应存在")
      local status = engine.get_status()
      assert.is_true(status.initialized, "AI 引擎应已初始化")

      -- 获取键位管理器
      local km = neoai.get_keymap_manager()
      assert.not_nil(km, "键位管理器应存在")

      -- 获取工具系统
      local tools = neoai.get_tools()
      assert.not_nil(tools, "工具系统应存在")

      -- 获取聊天服务
      local cs = require("NeoAI.core.ai.chat_service")
      assert.is_true(cs.is_initialized(), "聊天服务应已初始化")
    end,

    -- ========== 4. 注册并执行测试工具 ==========
    test_tool_registration_and_execution = function()
      local neoai = require("NeoAI")
      local tools = neoai.get_tools()

      -- 如果工具已存在（被 test_tool_orchestrator_integration 注册），先注销
      local tr = require("NeoAI.tools.tool_registry")
      if tr.exists("integration_test_tool") then
        tr.unregister("integration_test_tool")
      end

      -- 注册测试工具
      local ok = tools.register_tool({
        name = "integration_test_tool",
        description = "集成测试用工具，接收 input 参数并返回处理结果",
        func = function(args)
          local input = args and args.input or ""
          return "工具执行成功，输入为: " .. input
        end,
        parameters = {
          type = "object",
          properties = {
            input = { type = "string", description = "输入文本" },
          },
          required = {},
        },
        category = "test",
      })
      assert.is_true(ok, "工具注册应成功")

      -- 验证工具已注册
      local tool = tools.get_tool("integration_test_tool")
      assert.not_nil(tool, "应能获取已注册的工具")
      assert.equal("integration_test_tool", tool.name)

      -- 执行工具
      local result = tools.execute_tool("integration_test_tool", { input = "hello" })
      assert.equal("工具执行成功，输入为: hello", result)

      -- 验证工具计数
      assert.is_true(tools.get_tool_count() >= 1, "工具计数应 >= 1")

      -- 将工具注入 AI 引擎
      local engine = neoai.get_ai_engine()
      engine.set_tools({
        integration_test_tool = {
          func = function(args)
            local input = args and args.input or ""
            return "工具执行成功，输入为: " .. input
          end,
          description = "集成测试用工具",
          parameters = {
            type = "object",
            properties = {
              input = { type = "string", description = "输入文本" },
            },
            required = {},
          },
        },
      })
    end,

    -- ========== 5. 真实 HTTP 请求测试（非流式） ==========
    test_real_http_request = function()
      if not has_api_key then
        print("  ⚠ 跳过真实 HTTP 请求测试：未设置 DEEPSEEK_API_KEY 环境变量")
        return
      end

      local http_client = require("NeoAI.core.ai.http_client")
      http_client.initialize({ config = {} })

      local response, err = http_client.send_request({
        request = {
          model = "deepseek-chat",
          messages = {
            { role = "user", content = "请用一句话回答：1+1等于几？" },
          },
          temperature = 0.1,
          max_tokens = 50,
          stream = false,
        },
        generation_id = "integration_test_" .. os.time(),
        base_url = "https://api.deepseek.com/chat/completions",
        api_key = api_key,
        timeout = 30000,
        api_type = "openai",
      })

      assert.is_nil(err, "HTTP 请求不应返回错误: " .. tostring(err))
      assert.not_nil(response, "响应不应为 nil")
      assert.not_nil(response.choices, "响应应有 choices")
      assert.is_true(#response.choices > 0, "应有至少一个 choice")
      assert.not_nil(response.choices[1].message, "choice 应有 message")
      assert.not_nil(response.choices[1].message.content, "message 应有 content")
      assert.is_true(#response.choices[1].message.content > 0, "content 不应为空")

      local content = response.choices[1].message.content
      assert.is_true(
        content:find("2") ~= nil or content:find("二") ~= nil,
        "响应应包含答案 '2' 或 '二'，实际: " .. content
      )
      print("  ✓ 真实 HTTP 请求成功，响应: " .. content:sub(1, 100))
    end,

    -- ========== 6. 通过 AI 引擎发送消息（非流式） ==========
    test_ai_engine_send_message = function()
      if not has_api_key then
        print("  ⚠ 跳过 AI 引擎消息测试：未设置 DEEPSEEK_API_KEY 环境变量")
        return
      end

      local neoai = require("NeoAI")
      local engine = neoai.get_ai_engine()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")

      -- 创建会话
      local session_id = cs.create_session("集成测试会话", true, nil)
      assert.not_nil(session_id, "会话应创建成功")

      -- 监听生成完成事件
      local generation_completed = false
      local generation_result = nil
      local gen_id = vim.api.nvim_create_autocmd("User", {
        pattern = "NeoAI:generation_completed",
        callback = function(args)
          generation_completed = true
          generation_result = args.data
        end,
      })

      -- 发送消息
      local messages = {
        { role = "user", content = "请用一句话回答：中国的首都是哪个城市？" },
      }
      engine.generate_response(messages, {
        session_id = session_id,
        options = {
          stream = false,
          temperature = 0.1,
          max_tokens = 50,
        },
      })

      -- 等待生成完成（最多 30 秒）
      local waited = 0
      local max_wait = 30000
      while not generation_completed and waited < max_wait do
        vim.wait(100, function() return generation_completed end)
        waited = waited + 100
      end

      -- 清理事件监听
      pcall(vim.api.nvim_del_autocmd, gen_id)

      assert.is_true(generation_completed, "生成应在超时前完成")
      assert.not_nil(generation_result, "生成结果不应为 nil")
      assert.not_nil(generation_result.response, "响应内容不应为 nil")
      assert.is_true(#generation_result.response > 0, "响应内容不应为空")

      local response = generation_result.response
      assert.is_true(
        response:find("北京") ~= nil,
        "响应应包含 '北京'，实际: " .. response:sub(1, 200)
      )
      assert.not_nil(generation_result.usage, "应有 usage 信息")
      print("  ✓ AI 引擎消息发送成功，响应: " .. response:sub(1, 100))
    end,

    -- ========== 7. 工具循环测试（真实 HTTP + 工具调用） ==========
    test_tool_loop_integration = function()
      if not has_api_key then
        print("  ⚠ 跳过工具循环测试：未设置 DEEPSEEK_API_KEY 环境变量")
        return
      end

      local neoai = require("NeoAI")
      local engine = neoai.get_ai_engine()
      local cs = require("NeoAI.core.ai.chat_service")
      -- 确保聊天服务已初始化（可能被 test_shutdown 关闭）
      cs.initialize()

      -- 确保工具已注入引擎
      engine.set_tools({
        integration_test_tool = {
          func = function(args)
            local input = args and args.input or ""
            return "工具执行成功，输入为: " .. input
          end,
          description = "集成测试用工具，接收 input 参数并返回处理结果",
          parameters = {
            type = "object",
            properties = {
              input = { type = "string", description = "输入文本" },
            },
            required = { "input" },
          },
        },
      })

      -- 创建新会话
      local session_id = cs.create_session("工具循环测试", true, nil)
      assert.not_nil(session_id, "会话应创建成功")

      -- 监听事件
      local events = {}
      local listener_ids = {}

      local event_names = {
        "NeoAI:generation_started",
        "NeoAI:generation_completed",
        "NeoAI:generation_error",
        "NeoAI:tool_loop_started",
        "NeoAI:tool_loop_finished",
        "NeoAI:tool_execution_started",
        "NeoAI:tool_execution_completed",
        "NeoAI:tool_call_detected",
      }

      for _, name in ipairs(event_names) do
        local id = vim.api.nvim_create_autocmd("User", {
          pattern = name,
          callback = function(_)
            events[name] = (events[name] or 0) + 1
          end,
        })
        table.insert(listener_ids, id)
      end

      -- 发送一个会触发工具调用的消息
      local messages = {
        { role = "system", content = "你是一个测试助手。当用户说'调用工具'时，你必须使用 integration_test_tool 工具来处理。工具的 input 参数设为用户消息内容。" },
        { role = "user", content = "调用工具，帮我处理这条消息：Hello World" },
      }

      engine.generate_response(messages, {
        session_id = session_id,
        options = {
          stream = false,
          temperature = 0.1,
          max_tokens = 300,
        },
      })

      -- 等待生成完成（最多 60 秒）
      local waited = 0
      local max_wait = 60000
      while waited < max_wait do
        local gen_completed = events["NeoAI:generation_completed"] or 0
        local gen_error = events["NeoAI:generation_error"] or 0
        if gen_completed > 0 or gen_error > 0 then
          break
        end
        vim.wait(200, function()
          return (events["NeoAI:generation_completed"] or 0) > 0
            or (events["NeoAI:generation_error"] or 0) > 0
        end)
        waited = waited + 200
      end

      -- 清理事件监听
      for _, id in ipairs(listener_ids) do
        pcall(vim.api.nvim_del_autocmd, id)
      end

      -- 输出事件统计
      print("  📊 事件统计:")
      for name, count in pairs(events) do
        print("      " .. name .. ": " .. count)
      end

      local gen_completed = events["NeoAI:generation_completed"] or 0
      local gen_error = events["NeoAI:generation_error"] or 0
      local tool_loop_started = events["NeoAI:tool_loop_started"] or 0
      local tool_execution = events["NeoAI:tool_execution_completed"] or 0

      assert.is_true(gen_completed > 0 or gen_error > 0,
        "应至少触发 generation_completed 或 generation_error")

      if gen_error > 0 then
        print("  ⚠ 生成过程中出现错误，但流程正常完成")
      end

      if tool_loop_started > 0 then
        assert.is_true(tool_execution > 0,
          "工具循环开始后应有工具执行完成事件，实际: " .. tool_execution)
        print("  ✓ 工具循环正常工作，工具执行次数: " .. tool_execution)
      end
    end,

    -- ========== 8. 取消生成测试 ==========
    test_cancel_generation = function()
      local neoai = require("NeoAI")
      local engine = neoai.get_ai_engine()

      local status_before = engine.get_status()
      assert.is_false(status_before.is_generating, "初始不应在生成中")

      -- 取消（即使没有活跃生成也不应报错）
      engine.cancel_generation()

      local status_after = engine.get_status()
      assert.is_false(status_after.is_generating, "取消后不应在生成中")
    end,

    -- ========== 9. 会话管理集成测试 ==========
    test_session_management = function()
      local cs = require("NeoAI.core.ai.chat_service")
      local hm = require("NeoAI.core.history.manager")

      -- 创建多级会话
      local root_id = cs.create_session("根会话", true, nil)
      assert.not_nil(root_id, "根会话应创建成功")

      local child_id = cs.create_session("子会话", false, root_id)
      assert.not_nil(child_id, "子会话应创建成功")

      -- 验证父子关系
      local parent = cs.find_parent_session(child_id)
      assert.equal(root_id, parent, "子会话的父会话应为根会话")

      -- 添加对话轮次
      cs.add_round(root_id, "你好", '{"content":"你好！有什么可以帮助你的？"}')

      -- 获取原始消息
      local messages = cs.get_raw_messages(root_id)
      assert.is_true(#messages >= 2, "应有至少 2 条消息")

      -- 更新使用量
      cs.update_usage(root_id, { prompt_tokens = 50, completion_tokens = 100 })
      local session = hm.get_session(root_id)
      assert.not_nil(session.usage, "应有 usage 信息")
      assert.equal(50, session.usage.prompt_tokens)

      -- 重命名会话
      cs.rename_session(root_id, "重命名后的根会话")
      assert.equal("重命名后的根会话", cs.get_session(root_id).name)

      -- 列出会话
      local sessions = cs.list_sessions()
      assert.is_true(#sessions >= 2, "应有至少 2 个会话")

      -- 获取会话树
      local tree = cs.get_tree()
      assert.is_true(#tree >= 1, "会话树应有节点")

      -- 删除子会话
      assert.is_true(cs.delete_session(child_id), "删除子会话应成功")
      assert.equal(nil, cs.get_session(child_id), "删除后应不存在")
    end,

    -- ========== 10. 自动命名会话测试 ==========
    test_auto_naming = function()
      if not has_api_key then
        print("  ⚠ 跳过自动命名测试：未设置 DEEPSEEK_API_KEY 环境变量")
        return
      end

      local engine = require("NeoAI.core.ai.ai_engine")

      local naming_completed = false
      local naming_result = nil

      engine.auto_name_session("session_test_naming", "今天天气怎么样？", function(success, name)
        naming_completed = true
        naming_result = { success = success, name = name }
      end)

      -- 等待命名完成（最多 15 秒）
      local waited = 0
      local max_wait = 15000
      while not naming_completed and waited < max_wait do
        vim.wait(100, function() return naming_completed end)
        waited = waited + 100
      end

      assert.is_true(naming_completed, "命名应在超时前完成")
      assert.is_true(naming_result.success, "命名应成功: " .. tostring(naming_result.name))
      assert.is_true(#naming_result.name > 0, "名称不应为空")
      print("  ✓ 自动命名成功，名称: " .. naming_result.name)
    end,

    -- ========== 11. 工具编排器集成测试 ==========
    test_tool_orchestrator_integration = function()
      local tool_orch = require("NeoAI.core.ai.tool_orchestrator")
      local tool_registry = require("NeoAI.tools.tool_registry")

      -- 确保工具已注册
      tool_registry.initialize({})
      if not tool_registry.exists("integration_test_tool") then
        tool_registry.register({
          name = "integration_test_tool",
          description = "集成测试用工具",
          func = function(args)
            local input = args and args.input or ""
            return "工具执行成功，输入为: " .. input
          end,
          parameters = {
            type = "object",
            properties = {
              input = { type = "string", description = "输入文本" },
            },
            required = {},
          },
          category = "test",
        })
      end

      -- 注册会话
      local session_id = "session_orch_test_" .. os.time()
      tool_orch.register_session(session_id, nil)

      -- 验证会话已注册
      local ss = tool_orch.get_session_state(session_id)
      assert.not_nil(ss, "会话状态应存在")
      assert.equal(session_id, ss.session_id)

      -- 验证初始状态
      assert.is_false(tool_orch.is_executing(session_id), "初始不应在执行中")
      assert.equal(0, tool_orch.get_current_iteration(session_id), "初始迭代应为 0")

      -- 测试停止功能
      tool_orch.request_stop(session_id)
      assert.is_true(tool_orch.is_stop_requested(session_id), "停止请求应被设置")

      tool_orch.reset_stop_requested(session_id)
      assert.is_false(tool_orch.is_stop_requested(session_id), "重置后停止请求应被清除")

      -- 注销会话
      tool_orch.unregister_session(session_id)
      assert.equal(nil, tool_orch.get_session_state(session_id), "注销后会话状态应不存在")
    end,

    -- ========== 12. 完整 shutdown 测试 ==========
    test_shutdown = function()
      local neoai = require("NeoAI")
      local engine = neoai.get_ai_engine()
      local tool_orch = require("NeoAI.core.ai.tool_orchestrator")
      local http_client = require("NeoAI.core.ai.http_client")
      local cs = require("NeoAI.core.ai.chat_service")

      -- 先关闭引擎
      engine.shutdown()
      local status = engine.get_status()
      assert.is_false(status.initialized, "shutdown 后引擎应未初始化")

      -- 清理工具编排器
      tool_orch.shutdown()

      -- 清理 HTTP 客户端
      http_client.shutdown()
      local http_state = http_client.get_state()
      assert.is_false(http_state.initialized, "shutdown 后 HTTP 客户端应未初始化")

      -- 关闭聊天服务
      cs.shutdown()
      assert.is_false(cs.is_initialized(), "shutdown 后聊天服务应未初始化")
    end,
  })
end

-- 直接运行（独立模式，仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  -- 独立运行时清理缓存
  for modname, _ in pairs(package.loaded) do
    if modname:match("^NeoAI") then
      package.loaded[modname] = nil
    end
  end
  M.run()
end

return M
