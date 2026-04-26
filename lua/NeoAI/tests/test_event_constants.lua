--- 测试: core/events/event_constants.lua
--- 验证所有事件常量定义正确、无重复、命名规范
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_event_constants ===")

  return test.run_tests({
    --- 测试所有常量已定义且为字符串
    test_all_constants_are_strings = function()
      local Events = require("NeoAI.core.events.event_constants")
      for name, value in pairs(Events) do
        assert.is_true(type(value) == "string",
          string.format("常量 %s 应为字符串, 实际为 %s", name, type(value)))
      end
    end,

    --- 测试所有常量以 "NeoAI:" 开头
    test_all_constants_have_prefix = function()
      local Events = require("NeoAI.core.events.event_constants")
      for name, value in pairs(Events) do
        assert.is_true(string.find(value, "^NeoAI:") ~= nil,
          string.format("常量 %s 的值 '%s' 应以 'NeoAI:' 开头", name, value))
      end
    end,

    --- 测试无重复值
    test_no_duplicate_values = function()
      local Events = require("NeoAI.core.events.event_constants")
      local seen = {}
      for name, value in pairs(Events) do
        if seen[value] then
          error(string.format("重复的事件值: %s (已由 %s 定义, 又由 %s 定义)", value, seen[value], name))
        end
        seen[value] = name
      end
    end,

    --- 测试关键常量存在
    test_key_constants_exist = function()
      local Events = require("NeoAI.core.events.event_constants")
      local required = {
        "GENERATION_STARTED", "GENERATION_COMPLETED", "GENERATION_ERROR",
        "STREAM_STARTED", "STREAM_CHUNK", "STREAM_COMPLETED",
        "REASONING_CONTENT", "REASONING_STARTED", "REASONING_COMPLETED",
        "TOOL_CALL_DETECTED", "TOOL_RESULT_RECEIVED",
        "SESSION_CREATED", "SESSION_DELETED", "SESSION_CHANGED",
        "MESSAGE_ADDED", "MESSAGE_SENT",
        "CHAT_WINDOW_OPENED", "TREE_WINDOW_OPENED",
        "SEND_MESSAGE", "CANCEL_GENERATION",
        "PLUGIN_INITIALIZED",
      }
      for _, name in ipairs(required) do
        assert.not_nil(Events[name], string.format("必需常量 %s 不存在", name))
      end
    end,

    --- 测试常量命名规范（大写+下划线）
    test_naming_convention = function()
      local Events = require("NeoAI.core.events.event_constants")
      for name, _ in pairs(Events) do
        assert.is_true(string.match(name, "^[A-Z][A-Z0-9_]*$") ~= nil,
          string.format("常量名 '%s' 不符合大写+下划线规范", name))
      end
    end,

    --- 测试常量数量
    test_constant_count = function()
      local Events = require("NeoAI.core.events.event_constants")
      local count = 0
      for _ in pairs(Events) do
        count = count + 1
      end
      assert.is_true(count > 50, string.format("应有 50+ 个常量, 实际 %d 个", count))
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M

