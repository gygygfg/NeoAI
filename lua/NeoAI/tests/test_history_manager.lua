--- 测试: core/history_manager.lua
--- 测试会话历史管理器的创建、读取、更新、删除、树结构等功能
local M = {}

local test

--- 创建一个测试配置
local function create_test_config()
  return {
    session = {
      auto_save = false,
      auto_naming = false,
      save_path = "/tmp/neoai_test_sessions",
      max_history_per_session = 100,
    },
  }
end

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_history_manager ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()

      hm.initialize(create_test_config())
      assert.is_true(hm.is_initialized(), "初始化后应返回 true")
    end,

    --- 测试 create_session
    test_create_session = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("测试会话", true, nil)
      assert.not_nil(id, "创建会话应返回 ID")
      assert.is_true(string.find(id, "^session_") ~= nil, "ID 应以 session_ 开头")

      local session = hm.get_session(id)
      assert.not_nil(session)
      assert.equal("测试会话", session.name)
      assert.is_true(session.is_root)
    end,

    --- 测试 create_session 带父节点
    test_create_session_with_parent = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local parent_id = hm.create_session("父会话", true, nil)
      local child_id = hm.create_session("子会话", false, parent_id)

      local parent = hm.get_session(parent_id)
      assert.contains(parent.child_ids, child_id, "父会话应包含子会话 ID")
    end,

    --- 测试 get_current_session
    test_get_current_session = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      -- 创建会话后应自动设为当前
      local id = hm.create_session("当前会话", true, nil)
      local current = hm.get_current_session()
      assert.not_nil(current)
      assert.equal(id, current.id)
    end,

    --- 测试 set_current_session
    test_set_current_session = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id1 = hm.create_session("会话1", true, nil)
      local id2 = hm.create_session("会话2", true, nil)

      hm.set_current_session(id1)
      assert.equal(id1, hm.get_current_session().id)

      hm.set_current_session(id2)
      assert.equal(id2, hm.get_current_session().id)
    end,

    --- 测试 get_or_create_current_session
    test_get_or_create_current_session = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      -- 首次调用应创建新会话
      local session = hm.get_or_create_current_session("自动创建")
      assert.not_nil(session)
      assert.equal("自动创建", session.name)

      -- 再次调用应返回同一会话
      local session2 = hm.get_or_create_current_session("不应创建")
      assert.equal(session.id, session2.id)
    end,

    --- 测试 add_round
    test_add_round = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("测试", true, nil)
      local result = hm.add_round(id, "用户消息", '{"content":"AI回复"}', { prompt_tokens = 10, completion_tokens = 20 })

      assert.not_nil(result)
      local session = hm.get_session(id)
      assert.equal("用户消息", session.user)
      assert.is_true(#session.assistant > 0)
    end,

    --- 测试 get_messages
    test_get_messages = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "你好", '{"content":"你好！有什么可以帮助你的？"}')

      local msgs = hm.get_messages(id)
      assert.is_true(#msgs >= 2, "应有至少 2 条消息")
      assert.equal("user", msgs[1].role)
      assert.equal("你好", msgs[1].content)
    end,

    --- 测试 delete_session
    test_delete_session = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("待删除", true, nil)
      assert.not_nil(hm.get_session(id))

      local ok = hm.delete_session(id)
      assert.is_true(ok, "删除应成功")
      assert.equal(nil, hm.get_session(id), "删除后应返回 nil")
    end,

    --- 测试 rename_session
    test_rename_session = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("旧名称", true, nil)
      hm.rename_session(id, "新名称")

      local session = hm.get_session(id)
      assert.equal("新名称", session.name)
    end,

    --- 测试 get_root_sessions
    test_get_root_sessions = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      hm.create_session("根1", true, nil)
      hm.create_session("根2", true, nil)

      local roots = hm.get_root_sessions()
      assert.is_true(#roots >= 2, "应有至少 2 个根会话")
    end,

    --- 测试 list_sessions
    test_list_sessions = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      hm.create_session("会话A", true, nil)
      hm.create_session("会话B", true, nil)

      local list = hm.list_sessions()
      assert.is_true(#list >= 2)
      assert.not_nil(list[1].id)
      assert.not_nil(list[1].name)
    end,

    --- 测试 get_tree
    test_get_tree = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local root_id = hm.create_session("根", true, nil)
      hm.create_session("子", false, root_id)

      local tree = hm.get_tree()
      assert.is_true(#tree >= 1, "树应有根节点")
      assert.equal("根", tree[1].name)
    end,

    --- 测试 find_parent_session
    test_find_parent_session = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local parent_id = hm.create_session("父", true, nil)
      local child_id = hm.create_session("子", false, parent_id)

      local found = hm.find_parent_session(child_id)
      assert.equal(parent_id, found, "应找到父会话 ID")
    end,

    --- 测试 build_round_text
    test_build_round_text = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "你好世界", '{"content":"你好！"}')

      local session = hm.get_session(id)
      local text = hm.build_round_text(session)
      assert.is_true(type(text) == "string")
      assert.is_true(#text > 0, "轮次文本不应为空")
    end,

    --- 测试 update_last_assistant（替换语义：更新最后一条，而不是追加）
    test_update_last_assistant = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "你好", '{"content":"回复1"}')
      hm.update_last_assistant(id, '{"content":"回复2"}')

      local session = hm.get_session(id)
      -- update_last_assistant 替换最后一条，所以 assistant 应该只有 1 条
      assert.equal(1, #session.assistant, "update_last_assistant 应替换而不是追加")
      -- 且内容应为更新后的值（现在存储为原生 table）
      assert.is_true(type(session.assistant[1]) == "table", "assistant 应为原生 table")
      if type(session.assistant[1]) == "table" then
        assert.equal("回复2", session.assistant[1].content, "assistant 内容应被更新")
      end
    end,

    --- 测试 add_assistant_entry
    test_add_assistant_entry = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "你好", '{"content":"回复1"}')
      hm.add_assistant_entry(id, '{"content":"回复2"}')

      local session = hm.get_session(id)
      assert.is_true(#session.assistant >= 2)
    end,

    --- 测试 add_tool_result
    test_add_tool_result = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("测试", true, nil)
      hm.add_round(id, "执行工具", '{"content":"好的"}')
      hm.add_tool_result(id, "test_tool", { arg1 = "val1" }, "执行成功")

      local session = hm.get_session(id)
      assert.is_true(#session.assistant >= 2)
    end,

    --- 测试 update_usage
    test_update_usage = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("测试", true, nil)
      hm.update_usage(id, { prompt_tokens = 100, completion_tokens = 200, total_tokens = 300 })

      local session = hm.get_session(id)
      assert.equal(100, session.usage.prompt_tokens)
      assert.equal(300, session.usage.total_tokens)
    end,

    --- 测试 export_sessions 和 import_sessions
    test_export_import = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local id = hm.create_session("导出测试", true, nil)
      hm.add_round(id, "测试消息", '{"content":"测试回复"}')

      local filepath = "/tmp/neoai_test_export.json"
      local ok, err = hm.export_sessions(filepath)
      assert.is_true(ok, "导出应成功: " .. tostring(err))

      -- 清空并导入
      hm._test_reset()
      hm.initialize(create_test_config())

      local ok2, err2 = hm.import_sessions(filepath)
      assert.is_true(ok2, "导入应成功: " .. tostring(err2))

      local session = hm.get_session(id)
      assert.not_nil(session, "导入后应能找到会话")
      assert.equal("导出测试", session.name)

      os.remove(filepath)
    end,

    --- 测试 delete_chain_to_branch
    test_delete_chain_to_branch = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local root = hm.create_session("根", true, nil)
      local child1 = hm.create_session("子1", false, root)
      local child2 = hm.create_session("子2", false, root) -- 分支点
      local grandchild = hm.create_session("孙", false, child2)

      -- 删除子2链
      local ok = hm.delete_chain_to_branch(grandchild)
      assert.is_true(ok, "删除链应成功")

      -- 子2和孙应被删除
      assert.equal(nil, hm.get_session(child2))
      assert.equal(nil, hm.get_session(grandchild))
    end,

    --- 测试 cleanup_orphans
    test_cleanup_orphans = function()
      local hm = require("NeoAI.core.history_manager")
      hm._test_reset()
      hm.initialize(create_test_config())

      local root = hm.create_session("根", true, nil)
      local orphan = hm.create_session("孤儿", true, nil) -- 另一个根，但手动删除引用

      -- 直接操作 sessions 表创建孤儿
      hm.delete_session(orphan) -- 删除后 orphan 已不在

      -- cleanup_orphans 不应崩溃
      hm.cleanup_orphans()
      assert.not_nil(hm.get_session(root), "根会话应保留")
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

