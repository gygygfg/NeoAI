--- 调试测试：验证子 agent 工具循环
local logger = require("NeoAI.utils.logger")
logger.set_level("DEBUG")
local plan_executor = require("NeoAI.tools.builtin.plan_executor")
local sub_agent_engine = require("NeoAI.core.ai.sub_agent_engine")

-- 初始化 AI engine（注册事件监听器）
local ai_engine = require("NeoAI.core.ai.ai_engine")
pcall(ai_engine.initialize, {})

-- 先清理
plan_executor.cleanup_all()
sub_agent_engine.cleanup_all()

-- 创建子 agent
local result = nil
plan_executor.create_sub_agent.func({
  task = "测试任务：列出当前目录的文件",
  boundaries = {
    allowed_tools = { "^run_command$" },
    allowed_commands = { "^ls " },
    description = "只允许 ls 命令",
    max_tool_calls = 5,
    max_iterations = 3,
  },
  timeout = 30,
}, function(res)
  result = res
  logger.info("[test] create_sub_agent 回调: sub_agent_id=%s", res.sub_agent_id)
end, function(err)
  result = { error = err }
  logger.info("[test] create_sub_agent 错误: %s", err)
end)

-- 等待创建完成
vim.wait(2000, function() return result ~= nil end)

if not result or result.error then
  logger.error("[test] 创建子 agent 失败: %s", result and result.error or "超时")
  return
end

local sub_agent_id = result.sub_agent_id
logger.info("[test] 子 agent 已创建: %s", sub_agent_id)

-- 验证子 agent 状态
local agents = plan_executor.get_all_agents_data()
for _, agent in ipairs(agents) do
  if agent.sub_agent_id == sub_agent_id then
    logger.info("[test] 子 agent 状态: status=%s, tool_calls=%d, iterations=%d",
      agent.status, agent.tool_call_count, agent.iteration_count)
  end
end

-- 测试边界审核
local allowed, reason = plan_executor.review_tool_call(sub_agent_id, {
  name = "run_command",
  arguments = { cmd = "ls -la" },
})
logger.info("[test] review_tool_call(run_command): allowed=%s, reason=%s", allowed, reason)

local denied, deny_reason = plan_executor.review_tool_call(sub_agent_id, {
  name = "read_file",
  arguments = { filepath = "/tmp/test.txt" },
})
logger.info("[test] review_tool_call(read_file): allowed=%s, reason=%s", denied, deny_reason)

-- 模拟工具执行完成后的流程
-- 直接测试 _on_tools_complete → _request_generation 链路
logger.info("[test] 测试 _on_tools_complete 链路...")

-- 手动模拟 runner 状态
local runner = {
  sub_agent_id = sub_agent_id,
  session_id = "test_session",
  window_id = 1000,
  generation_id = "sub_agent_" .. sub_agent_id .. "_test",
  messages = {},
  options = {},
  model_index = 1,
  ai_preset = {},
  on_summary = function(summary)
    logger.info("[test] 子 agent 总结: %s", summary)
  end,
  iteration_count = 0,
  max_iterations = 20,
  stop_requested = false,
  active_tool_calls = {},
  _round_in_progress = false,
  _tools_complete_in_progress = false,
  accumulated_usage = {},
  last_reasoning = nil,
}

-- 注入 runner 到 sub_agent_runners
-- 通过 start_sub_agent_loop 来创建 runner
sub_agent_engine.start_sub_agent_loop(sub_agent_id, {}, {
  session_id = "test_session",
  window_id = 1000,
  messages = {},
  options = {},
  model_index = 1,
  ai_preset = {},
  on_summary = function(summary)
    logger.info("[test] 子 agent 总结: %s", summary)
  end,
})

  -- 等待一段时间看是否有日志输出
  vim.wait(3000, function()
    local agents_check = plan_executor.get_all_agents_data()
    for _, a in ipairs(agents_check) do
      if a.sub_agent_id == sub_agent_id and a.status ~= "running" then
        return true
      end
    end
    return false
  end)

-- 直接检查 sub_agent_runners 表（通过调试接口）
-- 注意：sub_agent_runners 是模块局部变量，无法直接访问
-- 通过检查 plan_executor 中的状态来判断
local agents_after = plan_executor.get_all_agents_data()
for _, agent in ipairs(agents_after) do
  if agent.sub_agent_id == sub_agent_id then
    logger.info("[test] 最终状态: status=%s, tool_calls=%d, iterations=%d",
      agent.status, agent.tool_call_count, agent.iteration_count)
  end
end

if #agents_after == 0 or agents_after[1].status ~= "running" then
  logger.info("[test] 子 agent 已结束")
else
  logger.info("[test] 子 agent 仍在运行")
end

-- 清理
plan_executor.cleanup_all()
sub_agent_engine.cleanup_all()
logger.info("[test] 测试完成")
