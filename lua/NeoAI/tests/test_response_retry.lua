--- 测试: core/ai/response_retry.lua
--- 测试响应重试模块的异常检测、重试管理、总结内容检测等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_response_retry ===")

  return test.run_tests({
    --- 测试 is_summary_content
    test_is_summary_content = function()
      local rr = require("NeoAI.core.ai.response_retry")

      -- 中文总结关键词
      assert.is_true(rr.is_summary_content("综上所述，任务已完成"))
      assert.is_true(rr.is_summary_content("总结一下："))
      assert.is_true(rr.is_summary_content("任务完成"))

      -- 英文总结关键词
      assert.is_true(rr.is_summary_content("In summary, the task is done"))
      assert.is_true(rr.is_summary_content("All tasks completed"))
      assert.is_true(rr.is_summary_content("Here is the summary"))

      -- 非总结内容
      assert.is_false(rr.is_summary_content("你好，今天天气不错"))
      assert.is_false(rr.is_summary_content(""))
      assert.is_false(rr.is_summary_content(nil))
    end,

    --- 测试 detect_abnormal_response - 空内容
    test_detect_empty = function()
      local rr = require("NeoAI.core.ai.response_retry")

      -- 非工具循环模式：空内容不视为异常
      local abnormal, reason = rr.detect_abnormal_response("", nil, {})
      assert.is_false(abnormal, "非工具循环空内容不应视为异常")

      -- 工具循环模式：空内容视为异常
      local abnormal2, reason2 = rr.detect_abnormal_response("", nil, { is_tool_loop = true })
      assert.is_true(abnormal2, "工具循环空内容应视为异常")
      assert.not_nil(reason2)
    end,

    --- 测试 detect_abnormal_response - 内容重复
    test_detect_repeated = function()
      local rr = require("NeoAI.core.ai.response_retry")

      local content = "第一行\n第二行\n第二行\n第四行"
      local abnormal, reason = rr.detect_abnormal_response(content, nil, {})
      assert.is_true(abnormal, "重复行应视为异常")
      assert.not_nil(reason)
    end,

    --- 测试 detect_abnormal_response - 截断
    test_detect_truncated = function()
      local rr = require("NeoAI.core.ai.response_retry")

      -- 未闭合的代码块
      local content = "一些文本\n```lua\nlocal x = 1"
      local abnormal, reason = rr.detect_abnormal_response(content, nil, {})
      assert.is_true(abnormal, "未闭合代码块应视为异常")

      -- 以英文逗号结尾
      local content2 = "这是一段话,"
      local abnormal2, reason2 = rr.detect_abnormal_response(content2, nil, {})
      assert.is_true(abnormal2, "以英文逗号结尾应视为截断")
    end,

    --- 测试 detect_abnormal_response - 工具调用异常
    test_detect_abnormal_tool_calls = function()
      local rr = require("NeoAI.core.ai.response_retry")

      -- 空参数工具调用
      local tool_calls = {
        { ["function"] = { name = "read_file", arguments = "" } },
      }
      local abnormal, reason = rr.detect_abnormal_response("", tool_calls, { is_tool_loop = true })
      assert.is_true(abnormal, "空参数工具调用应视为异常")

      -- 重复工具调用（同名+同参数）
      local tool_calls2 = {
        { ["function"] = { name = "read_file", arguments = '{"path":"/tmp/test"}' } },
        { ["function"] = { name = "read_file", arguments = '{"path":"/tmp/test"}' } },
      }
      local abnormal2, reason2 = rr.detect_abnormal_response("", tool_calls2, { is_tool_loop = true })
      assert.is_true(abnormal2, "重复工具调用应视为异常")
    end,

    --- 测试 detect_abnormal_response - 正常响应
    test_detect_normal = function()
      local rr = require("NeoAI.core.ai.response_retry")

      local abnormal, reason = rr.detect_abnormal_response("这是一个正常的响应内容。", nil, {})
      assert.is_false(abnormal, "正常响应不应视为异常")
      assert.equal(nil, reason)
    end,

    --- 测试 detect_abnormal_response - 最终轮次
    test_detect_final_round = function()
      local rr = require("NeoAI.core.ai.response_retry")

      -- 最终轮次空内容视为异常
      local abnormal, reason = rr.detect_abnormal_response("", nil, { is_final_round = true })
      assert.is_true(abnormal, "最终轮次空内容应视为异常")

      -- 最终轮次正常内容
      local abnormal2, reason2 = rr.detect_abnormal_response("任务完成，总结如上。", nil, { is_final_round = true })
      assert.is_false(abnormal2, "最终轮次正常内容不应视为异常")
    end,

    --- 测试 get_retry_delay
    test_get_retry_delay = function()
      local rr = require("NeoAI.core.ai.response_retry")

      assert.equal(0, rr.get_retry_delay(0), "第0次重试延迟应为0")
      assert.equal(1000, rr.get_retry_delay(1), "第1次重试延迟应为1000")
      assert.equal(2000, rr.get_retry_delay(2), "第2次重试延迟应为2000")
      assert.equal(4000, rr.get_retry_delay(3), "第3次重试延迟应为4000")
      assert.equal(8000, rr.get_retry_delay(4), "第4次重试延迟应为8000")
      assert.equal(16000, rr.get_retry_delay(5), "第5次重试延迟应为16000")
    end,

    --- 测试 can_retry
    test_can_retry = function()
      local rr = require("NeoAI.core.ai.response_retry")

      assert.is_true(rr.can_retry(0), "0次重试应可继续")
      assert.is_true(rr.can_retry(3), "3次重试应可继续")
      assert.is_true(rr.can_retry(4), "4次重试应可继续")
      assert.is_false(rr.can_retry(5), "5次重试应不可继续")
      assert.is_false(rr.can_retry(10), "10次重试应不可继续")
    end,

    --- 测试 get_max_retries
    test_get_max_retries = function()
      local rr = require("NeoAI.core.ai.response_retry")
      assert.is_true(rr.get_max_retries() > 0, "最大重试次数应大于0")
    end,

    --- 测试 set_config
    test_set_config = function()
      local rr = require("NeoAI.core.ai.response_retry")
      rr.set_config({ max_retries = 3, retry_delays = { 500, 1000, 2000 } })

      assert.is_false(rr.can_retry(3))
      assert.equal(500, rr.get_retry_delay(1))
      assert.equal(1000, rr.get_retry_delay(2))

      -- 恢复默认
      rr.set_config({ max_retries = 5, retry_delays = { 1000, 2000, 4000, 8000, 16000 } })
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
