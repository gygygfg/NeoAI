--- 测试: 历史管理模块
--- 合并了 test_history_manager, test_history_cache, test_history_persistence, test_history_saver
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_history ===")

  return test.run_tests({
    -- ========== manager ==========
    test_manager_initialize = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions", max_history_per_session = 100 } } })
      assert.is_true(hm.is_initialized(), "初始化后应返回 true")
    end,

    test_manager_create_session = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("测试会话", true, nil)
      assert.not_nil(id, "创建会话应返回 ID")
      assert.is_true(string.find(id, "^session_") ~= nil, "ID 应以 session_ 开头")
      local session = hm.get_session(id)
      assert.not_nil(session)
      assert.equal("测试会话", session.name)
    end,

    test_manager_create_session_with_parent = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local parent_id = hm.create_session("父会话", true, nil)
      local child_id = hm.create_session("子会话", false, parent_id)
      assert.contains(hm.get_session(parent_id).child_ids, child_id, "父会话应包含子会话 ID")
    end,

    test_manager_get_current_session = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("当前会话", true, nil)
      assert.equal(id, hm.get_current_session().id)
    end,

    test_manager_set_current_session = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id1 = hm.create_session("会话1", true, nil)
      local id2 = hm.create_session("会话2", true, nil)
      hm.set_current_session(id1)
      assert.equal(id1, hm.get_current_session().id)
      hm.set_current_session(id2)
      assert.equal(id2, hm.get_current_session().id)
    end,

    test_manager_get_or_create_current_session = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local session = hm.get_or_create_current_session("自动创建")
      assert.not_nil(session)
      assert.equal("自动创建", session.name)
      local session2 = hm.get_or_create_current_session("不应创建")
      assert.equal(session.id, session2.id)
    end,

    test_manager_add_round = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "用户消息", '{"content":"AI回复"}', { prompt_tokens = 10, completion_tokens = 20 })
      local session = hm.get_session(id)
      assert.equal("用户消息", session.user)
      assert.is_true(#session.assistant > 0)
    end,

    test_manager_get_messages = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "你好", '{"content":"你好！有什么可以帮助你的？"}')
      local msgs = hm.get_messages(id)
      assert.is_true(#msgs >= 2, "应有至少 2 条消息")
      assert.equal("user", msgs[1].role)
    end,

    test_manager_delete_session = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("待删除", true, nil)
      assert.not_nil(hm.get_session(id))
      assert.is_true(hm.delete_session(id), "删除应成功")
      assert.equal(nil, hm.get_session(id), "删除后应返回 nil")
    end,

    test_manager_rename_session = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("旧名称", true, nil)
      hm.rename_session(id, "新名称")
      assert.equal("新名称", hm.get_session(id).name)
    end,

    test_manager_get_root_sessions = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      hm.create_session("根1", true, nil)
      hm.create_session("根2", true, nil)
      assert.is_true(#hm.get_root_sessions() >= 2, "应有至少 2 个根会话")
    end,

    test_manager_list_sessions = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      hm.create_session("会话A", true, nil)
      hm.create_session("会话B", true, nil)
      local list = hm.list_sessions()
      assert.is_true(#list >= 2)
    end,

    test_manager_get_tree = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local root_id = hm.create_session("根", true, nil)
      hm.create_session("子", false, root_id)
      local tree = hm.get_tree()
      assert.is_true(#tree >= 1, "树应有根节点")
    end,

    test_manager_find_parent_session = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local parent_id = hm.create_session("父", true, nil)
      local child_id = hm.create_session("子", false, parent_id)
      assert.equal(parent_id, hm.find_parent_session(child_id), "应找到父会话 ID")
    end,

    test_manager_build_round_text = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "你好世界", '{"content":"你好！"}')
      local text = hm.build_round_text(hm.get_session(id))
      assert.is_true(type(text) == "string" and #text > 0, "轮次文本不应为空")
    end,

    test_manager_update_last_assistant = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "你好", '{"content":"回复1"}')
      hm.update_last_assistant(id, '{"content":"回复2"}')
      assert.equal(1, #hm.get_session(id).assistant, "update_last_assistant 应替换而不是追加")
    end,

    test_manager_add_assistant_entry = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "你好", '{"content":"回复1"}')
      hm.add_assistant_entry(id, '{"content":"回复2"}')
      assert.is_true(#hm.get_session(id).assistant >= 2)
    end,

    test_manager_add_tool_result = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "执行工具", '{"content":"好的"}')
      hm.add_tool_result(id, "test_tool", { arg1 = "val1" }, "执行成功")
      assert.is_true(#hm.get_session(id).assistant >= 2)
    end,

    test_manager_update_usage = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("测试", true, nil)
      hm.update_usage(id, { prompt_tokens = 100, completion_tokens = 200, total_tokens = 300 })
      assert.equal(100, hm.get_session(id).usage.prompt_tokens)
    end,

    test_manager_export_import = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local id = hm.create_session("导出测试", true, nil)
      hm.add_round(id, "测试消息", '{"content":"测试回复"}')
      local filepath = "/tmp/neoai_test_export.json"
      local ok, err = hm.export_sessions(filepath)
      assert.is_true(ok, "导出应成功: " .. tostring(err))
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local ok2, err2 = hm.import_sessions(filepath)
      assert.is_true(ok2, "导入应成功: " .. tostring(err2))
      assert.not_nil(hm.get_session(id), "导入后应能找到会话")
      os.remove(filepath)
    end,

    test_manager_delete_chain_to_branch = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local root = hm.create_session("根", true, nil)
      local child1 = hm.create_session("子1", false, root)
      local child2 = hm.create_session("子2", false, root)
      local grandchild = hm.create_session("孙", false, child2)
      assert.is_true(hm.delete_chain_to_branch(grandchild), "删除链应成功")
      assert.equal(nil, hm.get_session(child2))
      assert.equal(nil, hm.get_session(grandchild))
    end,

    test_manager_cleanup_orphans = function()
      local hm = require("NeoAI.core.history.manager")
      hm._test_reset()
      hm.initialize({ config = { session = { auto_save = false, save_path = "/tmp/neoai_test_sessions" } } })
      local root = hm.create_session("根", true, nil)
      local orphan = hm.create_session("孤儿", true, nil)
      hm.delete_session(orphan)
      hm.cleanup_orphans()
      assert.not_nil(hm.get_session(root), "根会话应保留")
    end,

    -- ========== cache ==========
    test_cache_initialize = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()
      local sessions = {}
      cache.initialize(function() return sessions end, function(s) return s.name or "" end)
    end,

    test_cache_get_list = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()
      local sessions = { session_1 = { id = "session_1", name = "会话1", created_at = 100, updated_at = 100, is_root = true, child_ids = {}, user = "你好" }, session_2 = { id = "session_2", name = "会话2", created_at = 200, updated_at = 200, is_root = true, child_ids = {}, user = "测试" } }
      cache.initialize(function() return sessions end, function(s) return s.name or "" end)
      local list = cache.get_list()
      assert.is_true(#list >= 2, "应有至少2个会话")
    end,

    test_cache_get_round_text = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()
      cache.initialize(function() return {} end, function(s) return "Round: " .. (s.name or "") end)
      local session = { id = "session_1", name = "测试会话" }
      assert.equal("Round: 测试会话", cache.get_round_text(session))
      assert.equal("Round: 测试会话", cache.get_round_text(session), "缓存命中")
    end,

    test_cache_invalidation = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()
      cache.initialize(function() return {} end, function(s) return "Round: " .. (s.name or "") end)
      local session = { id = "session_1", name = "旧名称" }
      assert.equal("Round: 旧名称", cache.get_round_text(session))
      cache.invalidate_round_text("session_1")
      session.name = "新名称"
      assert.equal("Round: 新名称", cache.get_round_text(session))
    end,

    test_cache_invalidate_all = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()
      cache.initialize(function() return {} end, function(s) return "" end)
      cache.invalidate_all()
      cache.invalidate_list()
      cache.invalidate_tree()
    end,

    -- ========== persistence ==========
    test_persistence_serialize = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()
      local sessions = { session_1 = { id = "session_1", name = "测试", user = "你好", assistant = {}, created_at = 100, updated_at = 100 } }
      local json = p.serialize(sessions)
      assert.is_true(type(json) == "string" and #json > 0, "序列化应返回非空字符串")
      assert.equal("[]", p.serialize({}), "空表应序列化为 []")
    end,

    test_persistence_deserialize = function()
      local p = require("NeoAI.core.history.persistence")
      local json = '[{"id":"session_1","name":"测试","user":"你好","assistant":[],"created_at":100,"updated_at":100}]'
      assert.equal("session_1", p.deserialize(json).session_1.id)
      assert.is_true(next(p.deserialize("[]")) == nil, "空 JSON 应返回空表")
      assert.is_true(next(p.deserialize("invalid")) == nil, "无效 JSON 应返回空表")
      assert.is_true(next(p.deserialize(nil)) == nil)
    end,

    test_persistence_roundtrip = function()
      local p = require("NeoAI.core.history.persistence")
      local sessions = { session_1 = { id = "session_1", name = "会话1", user = "你好", assistant = { { content = "回复" } }, created_at = 100, updated_at = 100, is_root = true, child_ids = {}, usage = { prompt_tokens = 10 } } }
      local restored = p.deserialize(p.serialize(sessions))
      assert.equal("会话1", restored.session_1.name)
      assert.equal(10, restored.session_1.usage.prompt_tokens)
    end,

    test_persistence_sync_save_load = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()
      p.initialize({ config = { session = { save_path = "/tmp/neoai_test_persist" } } })
      local sessions = { session_1 = { id = "session_1", name = "同步测试", user = "hello", assistant = {}, created_at = 100, updated_at = 100 } }
      local ok, err = p.sync_save(sessions)
      assert.is_true(ok, "同步保存应成功: " .. tostring(err))
      local loaded = p.load()
      assert.equal("同步测试", loaded.session_1.name)
      os.remove("/tmp/neoai_test_persist/sessions.json")
    end,

    test_persistence_enqueue_flush = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()
      p.initialize({ config = { session = { save_path = "/tmp/neoai_test_persist" } } })
      p.flush_queue()
      local id1 = p.enqueue_save("test", "content1")
      local id2 = p.enqueue_save("test", "content2")
      assert.is_true(id1 > 0, "应返回任务ID")
      assert.is_true(id2 > id1, "任务ID应递增")
      local count = p.flush_queue()
      assert.is_true(count >= 0, "flush_queue 应返回数字")
    end,

    test_persistence_shutting_down = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()
      assert.is_false(p.is_shutting_down(), "初始不应关闭")
      p.set_shutting_down()
      assert.is_true(p.is_shutting_down(), "设置后应为 true")
    end,

    -- ========== saver ==========
    test_saver_initialize = function()
      local saver = require("NeoAI.core.history.saver")
      saver._test_reset()
      saver.initialize(require("NeoAI.core.history.manager"))
      saver._test_reset()
    end,

    test_saver_flush_all = function()
      local saver = require("NeoAI.core.history.saver")
      saver._test_reset()
      saver.initialize(require("NeoAI.core.history.manager"))
      saver.flush_all()
      saver._test_reset()
    end,

    test_saver_flush_queue = function()
      local saver = require("NeoAI.core.history.saver")
      saver._test_reset()
      local count = saver.flush_queue()
      assert.is_true(type(count) == "number", "应返回数字")
    end,

    test_saver_shutdown = function()
      local saver = require("NeoAI.core.history.saver")
      saver._test_reset()
      saver.initialize(require("NeoAI.core.history.manager"))
      saver.shutdown()
      saver.shutdown_sync()
      saver._test_reset()
    end,
  })
end

-- 直接运行（仅在非 run_all 模式下）
if not _G._NEOAI_TEST_RUNNING and pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
