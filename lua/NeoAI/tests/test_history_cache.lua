--- 测试: core/history/cache.lua
--- 测试历史缓存模块的初始化、缓存失效、列表/树/round_text 缓存等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_history_cache ===")

  return test.run_tests({
    --- 测试 initialize
    test_initialize = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()

      local sessions = {}
      local function get_sessions() return sessions end
      local function build_round_text(s) return s.name or "" end

      cache.initialize(get_sessions, build_round_text)
      -- 幂等初始化
      cache.initialize(get_sessions, build_round_text)
    end,

    --- 测试 invalidate_all
    test_invalidate_all = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()

      local sessions = {}
      local function get_sessions() return sessions end
      local function build_round_text(s) return s.name or "" end
      cache.initialize(get_sessions, build_round_text)

      cache.invalidate_all()
      -- 不应崩溃
    end,

    --- 测试 invalidate_round_text
    test_invalidate_round_text = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()

      local sessions = {}
      local function get_sessions() return sessions end
      local function build_round_text(s) return s.name or "" end
      cache.initialize(get_sessions, build_round_text)

      cache.invalidate_round_text("session_1")
      cache.invalidate_round_text() -- 清除所有
    end,

    --- 测试 invalidate_list / invalidate_tree
    test_invalidate_list_tree = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()

      local sessions = {}
      local function get_sessions() return sessions end
      local function build_round_text(s) return s.name or "" end
      cache.initialize(get_sessions, build_round_text)

      cache.invalidate_list()
      cache.invalidate_tree()
    end,

    --- 测试 get_list
    test_get_list = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()

      local sessions = {
        session_1 = { id = "session_1", name = "会话1", created_at = 100, updated_at = 100, is_root = true, child_ids = {}, user = "你好" },
        session_2 = { id = "session_2", name = "会话2", created_at = 200, updated_at = 200, is_root = true, child_ids = {}, user = "测试" },
      }
      local function get_sessions() return sessions end
      local function build_round_text(s) return s.name or "" end
      cache.initialize(get_sessions, build_round_text)

      local list = cache.get_list()
      assert.is_true(#list >= 2, "应有至少2个会话")
      assert.equal("session_1", list[1].id)
      assert.equal("会话1", list[1].name)
      assert.is_true(list[1].is_root)
    end,

    --- 测试 get_round_text
    test_get_round_text = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()

      local sessions = {}
      local function get_sessions() return sessions end
      local function build_round_text(s) return "Round: " .. (s.name or "") end
      cache.initialize(get_sessions, build_round_text)

      local session = { id = "session_1", name = "测试会话" }
      local text = cache.get_round_text(session)
      assert.equal("Round: 测试会话", text)

      -- 缓存命中
      local text2 = cache.get_round_text(session)
      assert.equal("Round: 测试会话", text2)
    end,

    --- 测试 get_round_text 缓存失效
    test_get_round_text_cache_invalidation = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()

      local sessions = {}
      local function get_sessions() return sessions end
      local function build_round_text(s) return "Round: " .. (s.name or "") end
      cache.initialize(get_sessions, build_round_text)

      local session = { id = "session_1", name = "旧名称" }
      local text = cache.get_round_text(session)
      assert.equal("Round: 旧名称", text)

      -- 修改名称后清除缓存
      cache.invalidate_round_text("session_1")
      session.name = "新名称"
      local text2 = cache.get_round_text(session)
      assert.equal("Round: 新名称", text2)
    end,

    --- 测试 _test_reset
    test_reset = function()
      local cache = require("NeoAI.core.history.cache")
      cache._test_reset()
      -- 重置后应能重新初始化
      local sessions = {}
      local function get_sessions() return sessions end
      local function build_round_text(s) return "" end
      cache.initialize(get_sessions, build_round_text)
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
