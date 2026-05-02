--- 测试: core/history/persistence.lua
--- 测试历史持久化模块的序列化、反序列化、文件 IO、写入队列等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_history_persistence ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()
      p.initialize({ config = { session = { save_path = "/tmp/neoai_test_persist" } } })
    end,

    --- 测试 serialize
    test_serialize = function()
      local p = require("NeoAI.core.history.persistence")

      local sessions = {
        session_1 = { id = "session_1", name = "测试", user = "你好", assistant = {}, created_at = 100, updated_at = 100 },
      }

      local json = p.serialize(sessions)
      assert.not_nil(json, "序列化应返回字符串")
      assert.is_true(#json > 0, "序列化结果不应为空")

      -- 空会话表
      local json2 = p.serialize({})
      assert.equal("[]", json2, "空表应序列化为 []")
    end,

    --- 测试 deserialize
    test_deserialize = function()
      local p = require("NeoAI.core.history.persistence")

      local json = '[{"id":"session_1","name":"测试","user":"你好","assistant":[],"created_at":100,"updated_at":100}]'
      local sessions = p.deserialize(json)
      assert.not_nil(sessions.session_1, "应反序列化出会话")
      assert.equal("session_1", sessions.session_1.id)
      assert.equal("测试", sessions.session_1.name)

      -- 空 JSON
      local sessions2 = p.deserialize("[]")
      assert.is_true(next(sessions2) == nil, "空 JSON 应返回空表")

      -- 无效 JSON
      local sessions3 = p.deserialize("invalid")
      assert.is_true(next(sessions3) == nil, "无效 JSON 应返回空表")

      -- nil
      local sessions4 = p.deserialize(nil)
      assert.is_true(next(sessions4) == nil)
    end,

    --- 测试 serialize / deserialize 往返
    test_roundtrip = function()
      local p = require("NeoAI.core.history.persistence")

      local sessions = {
        session_1 = { id = "session_1", name = "会话1", user = "你好", assistant = { { content = "回复" } }, created_at = 100, updated_at = 100, is_root = true, child_ids = {}, usage = { prompt_tokens = 10 } },
        session_2 = { id = "session_2", name = "会话2", user = "测试", assistant = {}, created_at = 200, updated_at = 200, is_root = true, child_ids = {}, usage = {} },
      }

      local json = p.serialize(sessions)
      local restored = p.deserialize(json)

      assert.not_nil(restored.session_1)
      assert.not_nil(restored.session_2)
      assert.equal("会话1", restored.session_1.name)
      assert.equal("你好", restored.session_1.user)
      assert.equal(10, restored.session_1.usage.prompt_tokens)
    end,

    --- 测试 enqueue_save / flush_queue
    test_enqueue_flush = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()
      p.initialize({ config = { session = { save_path = "/tmp/neoai_test_persist" } } })

      local id1 = p.enqueue_save("test", "content1")
      local id2 = p.enqueue_save("test", "content2")
      assert.is_true(id1 > 0, "应返回任务ID")
      assert.is_true(id2 > id1, "任务ID应递增")

      local count = p.flush_queue()
      assert.is_true(count >= 2, "应有至少2个任务被清空")
    end,

    --- 测试 sync_save
    test_sync_save = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()
      p.initialize({ config = { session = { save_path = "/tmp/neoai_test_persist" } } })

      local sessions = {
        session_1 = { id = "session_1", name = "同步测试", user = "hello", assistant = {}, created_at = 100, updated_at = 100 },
      }

      local ok, err = p.sync_save(sessions)
      assert.is_true(ok, "同步保存应成功: " .. tostring(err))

      -- 验证文件已创建
      local filepath = "/tmp/neoai_test_persist/sessions.json"
      local file = io.open(filepath, "r")
      if file then
        local content = file:read("*a")
        file:close()
        assert.is_true(#content > 0, "文件内容不应为空")
        os.remove(filepath)
      end
    end,

    --- 测试 load
    test_load = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()
      p.initialize({ config = { session = { save_path = "/tmp/neoai_test_persist" } } })

      -- 先保存再加载
      local sessions = {
        session_1 = { id = "session_1", name = "加载测试", user = "world", assistant = {}, created_at = 100, updated_at = 100 },
      }
      p.sync_save(sessions)

      local loaded = p.load()
      assert.not_nil(loaded.session_1, "应加载出会话")
      assert.equal("加载测试", loaded.session_1.name)

      -- 清理
      local filepath = "/tmp/neoai_test_persist/sessions.json"
      os.remove(filepath)
    end,

    --- 测试 set_shutting_down / is_shutting_down
    test_shutting_down = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()

      assert.is_false(p.is_shutting_down(), "初始不应关闭")
      p.set_shutting_down()
      assert.is_true(p.is_shutting_down(), "设置后应为 true")
    end,

    --- 测试 debounced_save
    test_debounced_save = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()
      p.initialize({ config = { session = { save_path = "/tmp/neoai_test_persist" } } })

      local call_count = 0
      local function get_sessions()
        call_count = call_count + 1
        return { test = { id = "test" } }
      end

      p.debounced_save(get_sessions, 50)
      p.debounced_save(get_sessions, 50) -- 第二次应合并
      -- 等待防抖完成
      vim.wait(200, function() return false end)

      -- 清理
      p._test_reset()
    end,

    --- 测试 _test_reset
    test_reset = function()
      local p = require("NeoAI.core.history.persistence")
      p._test_reset()
      -- 重置后应能重新初始化
      p.initialize({ config = { session = { save_path = "/tmp/neoai_test_persist" } } })
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
