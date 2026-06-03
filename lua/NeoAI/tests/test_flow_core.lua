--- 流程测试: core 模块链
--- 调用链: shutdown_flag → events → history.manager → core.init
--- 验证核心模块之间的协作

local M = {}

function M.run(test_module)
  local assert = test_module.assert
  local logger = test_module._logger or require("NeoAI.utils.logger")

  local tests = {

    -- ============================================================
    -- 流程 1: shutdown_flag 生命周期
    -- ============================================================
    flow_shutdown_flag = function()
      local sf = require("NeoAI.core.shutdown_flag")

      -- 步骤 1: 初始状态应为未关闭
      assert.is_false(sf.is_set(), "初始状态 should not be shutting down")

      -- 步骤 2: 设置关闭标志
      sf.set()
      assert.is_true(sf.is_set(), "设置后应为 shutting down")

      -- 步骤 3: 重置
      sf.reset()
      assert.is_false(sf.is_set(), "重置后应为 false")
    end,

    -- ============================================================
    -- 流程 2: events 事件定义链
    -- ============================================================
    flow_events_definitions = function()
      local Events = require("NeoAI.core.events")

      -- 步骤 1: 验证事件常量定义
      assert.not_nil(Events, "Events 模块应可加载")

      -- 步骤 2: 验证关键事件
      assert.not_nil(Events.GENERATION_STARTED, "应有 GENERATION_STARTED 事件")
      assert.not_nil(Events.GENERATION_COMPLETED, "应有 GENERATION_COMPLETED 事件")
      assert.not_nil(Events.GENERATION_CANCELLED, "应有 GENERATION_CANCELLED 事件")
      assert.not_nil(Events.STREAM_CHUNK, "应有 STREAM_CHUNK 事件")
      assert.not_nil(Events.TOOL_CALLS_READY, "应有 TOOL_CALLS_READY 事件")
      assert.not_nil(Events.TOOL_RESULT_RECEIVED, "应有 TOOL_RESULT_RECEIVED 事件")
      assert.not_nil(Events.ERROR, "应有 ERROR 事件")

      -- 步骤 3: 验证事件是 User autocmd 模式
      assert.is_true(string.find(Events.GENERATION_STARTED, "^NeoAI:"),
        "事件应以 NeoAI: 开头")
    end,

    -- ============================================================
    -- 流程 3: history.manager 初始化链
    -- ============================================================
    flow_history_manager_init = function()
      local hm = require("NeoAI.core.history.manager")
      local dc = require("NeoAI.default_config")

      -- 步骤 1: 用默认配置初始化
      local config = dc.get_default_config()
      hm.initialize({ config = config })
      assert.is_true(hm.is_initialized(), "初始化后应标记为已初始化")

      -- 步骤 2: 获取会话列表
      local list = hm.list_sessions()
      assert.type_eq("table", list, "list_sessions 应返回表")

      -- 步骤 3: 获取树结构
      local tree = hm.get_tree()
      assert.type_eq("table", tree, "get_tree 应返回表")
    end,

    -- ============================================================
    -- 流程 4: history.manager 会话生命周期链
    -- ============================================================
    flow_history_session_lifecycle = function()
      local hm = require("NeoAI.core.history.manager")

      -- 验证已初始化
      if not hm.is_initialized() then
        local dc = require("NeoAI.default_config")
        hm.initialize({ config = dc.get_default_config() })
      end

      -- 步骤 1: 创建会话
      local session_id = hm.create_session("流程测试会话", true)
      assert.not_nil(session_id, "create_session 应返回会话 ID")
      assert.is_true(#session_id > 0, "会话 ID 不应为空")

      -- 步骤 2: 获取会话
      local session = hm.get_session(session_id)
      assert.not_nil(session, "get_session 应返回会话对象")
      assert.equal("流程测试会话", session.name, "会话名称应匹配")
      assert.is_true(session.is_root, "应为根会话")

      -- 步骤 3: 设置当前会话
      hm.set_current_session(session_id)
      local current = hm.get_current_session()
      assert.not_nil(current, "get_current_session 应返回当前会话")
      assert.equal(session_id, current.id, "当前会话 ID 应匹配")

      -- 步骤 4: 添加一轮对话
      local round = hm.add_round(session_id, "你好，AI", "你好，用户", {
        prompt_tokens = 10,
        completion_tokens = 20,
        total_tokens = 30,
      })
      assert.not_nil(round, "add_round 应返回会话对象")

      -- 步骤 5: 获取消息
      local messages = hm.get_messages(session_id)
      assert.type_eq("table", messages, "get_messages 应返回表")
      assert.is_true(#messages >= 1, "应有至少 1 条消息")

      -- 步骤 6: 重命名会话
      local renamed = hm.rename_session(session_id, "重命名测试会话")
      assert.is_true(renamed, "rename_session 应返回 true")
      local updated = hm.get_session(session_id)
      assert.equal("重命名测试会话", updated.name, "重命名后名称应更新")

      -- 步骤 7: 删除会话
      local deleted = hm.delete_session(session_id)
      assert.is_true(deleted, "delete_session 应返回 true")
      assert.is_nil(hm.get_session(session_id), "删除后 get_session 应返回 nil")
    end,

    -- ============================================================
    -- 流程 5: history.manager 消息导出链
    -- ============================================================
    flow_history_messages = function()
      local hm = require("NeoAI.core.history.manager")

      if not hm.is_initialized() then
        local dc = require("NeoAI.default_config")
        hm.initialize({ config = dc.get_default_config() })
      end

      -- 步骤 1: 创建测试会话
      local sid = hm.create_session("消息导出测试")
      hm.add_round(sid, "用户消息", "AI 回复")

      -- 步骤 2: 获取消息列表
      local messages = hm.get_messages(sid)
      assert.is_true(#messages >= 1, "应有至少 1 条消息")

      -- 步骤 3: 验证消息结构
      local found_user = false
      local found_assistant = false
      for _, msg in ipairs(messages) do
        if msg.role == "user" then found_user = true end
        if msg.role == "assistant" then found_assistant = true end
      end
      assert.is_true(found_user, "应有 user 角色消息")
      assert.is_true(found_assistant, "应有 assistant 角色消息")

      -- 步骤 4: 获取 round_text
      local session = hm.get_session(sid)
      local text = hm.build_round_text(session)
      if text then
        assert.type_eq("string", text, "build_round_text 应返回字符串")
      end

      -- 清理
      hm.delete_session(sid)
    end,

    -- ============================================================
    -- 流程 6: history.manager 根会话管理
    -- ============================================================
    flow_history_root_sessions = function()
      local hm = require("NeoAI.core.history.manager")

      if not hm.is_initialized() then
        local dc = require("NeoAI.default_config")
        hm.initialize({ config = dc.get_default_config() })
      end

      -- 步骤 1: 创建多个根会话
      local id1 = hm.create_session("根会话1")
      local id2 = hm.create_session("根会话2")
      local id3 = hm.create_session("子会话", false, id1)

      -- 步骤 2: 获取根会话列表
      local roots = hm.get_root_sessions()
      assert.type_eq("table", roots, "get_root_sessions 应返回表")
      -- id1 和 id2 应为根，id3 不是
      local found_id1 = false
      local found_id2 = false
      local found_id3 = false
      for _, s in ipairs(roots) do
        if s.id == id1 then found_id1 = true end
        if s.id == id2 then found_id2 = true end
        if s.id == id3 then found_id3 = true end
      end
      assert.is_true(found_id1, "id1 应在根列表")
      assert.is_true(found_id2, "id2 应在根列表")
      assert.is_false(found_id3, "id3 不应在根列表")

      -- 清理
      hm.delete_session(id3)
      hm.delete_session(id2)
      hm.delete_session(id1)
    end,

    -- ============================================================
    -- 流程 7: history.manager 自动命名
    -- ============================================================
    flow_history_auto_naming = function()
      local hm = require("NeoAI.core.history.manager")

      if not hm.is_initialized() then
        local dc = require("NeoAI.default_config")
        hm.initialize({ config = dc.get_default_config() })
      end

      -- 步骤 1: 创建不传 name 的会话（依赖 auto_naming）
      local sid = hm.create_session()
      assert.not_nil(sid, "create_session 不传 name 应成功")
      local session = hm.get_session(sid)
      -- 可能是默认名或 nil
      if session.name then
        assert.type_eq("string", session.name, "会话名称应为字符串")
      end

      -- 步骤 2: 添加对话后触发自动命名
      hm.add_round(sid, "今天天气如何？", "今天天气晴朗，温度适宜。")
      local updated = hm.get_session(sid)
      -- 自动命名不一定有回调立即完成，但会话结构应保持完整
      assert.not_nil(updated.user, "会话应有 user 字段")

      hm.delete_session(sid)
    end,

    -- ============================================================
    -- 流程 8: history.manager 状态查询
    -- ============================================================
    flow_history_state = function()
      local hm = require("NeoAI.core.history.manager")

      -- 验证状态查询函数
      local initialized = hm.is_initialized()
      assert.type_eq("boolean", initialized, "is_initialized 应返回布尔值")

      if initialized then
        local list = hm.list_sessions()
        assert.type_eq("table", list, "list_sessions 应返回表")

        local tree = hm.get_tree()
        assert.type_eq("table", tree, "get_tree 应返回表")
      end
    end,

    -- ============================================================
    -- 流程 9: core/init.lua 入口模块
    -- ============================================================
    flow_core_init = function()
      local ok, core = pcall(require, "NeoAI.core")
      assert.is_true(ok, "NeoAI.core 入口应能加载")

      if ok and core then
        -- 验证导出（与实际 core/init.lua 的 API 一致）
        assert.type_eq("function", core.initialize, "core.initialize 应为函数")
        assert.type_eq("function", core.get_engine, "core.get_engine 应为函数")
        assert.type_eq("function", core.get_keymap_manager, "core.get_keymap_manager 应为函数")
        assert.type_eq("function", core.get_history_manager, "core.get_history_manager 应为函数")
        assert.type_eq("function", core.get_config, "core.get_config 应为函数")
        assert.type_eq("function", core.get_session_manager, "core.get_session_manager 应为函数")
      end
    end,
  }

  return test_module.run_tests(tests)
end

return M
