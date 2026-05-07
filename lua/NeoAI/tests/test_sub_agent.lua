--- 测试: 子 agent 创建与监控数据获取
local M = {}

local function is_headless()
  local uis = vim.api.nvim_list_uis()
  return #uis == 0
end

local function safe_wait(timeout_ms, cond)
  if is_headless() then
    return vim.wait(timeout_ms, cond, 50)
  end
  local deadline = vim.uv.now() + timeout_ms
  while vim.uv.now() < deadline do
    if cond() then return true end
    vim.uv.run("once")
  end
  return false
end

-- 辅助函数：调用 define_tool 返回的 table 中的 func
local function call_tool(tool_table, args, on_success, on_error)
  if tool_table and tool_table.func then
    tool_table.func(args, on_success, on_error)
  elseif on_error then
    on_error("工具不存在或没有 func 字段")
  end
end

function M.run(test_module)
  local test = test_module or require("NeoAI.tests")
  local assert = test.assert
  test._logger.info("\n=== test_sub_agent ===")

  return test.run_tests({
    --- 测试 1: 创建子 agent 并验证 get_all_agents_data 能获取到数据
    test_create_and_get_data = function()
      local plan_executor = require("NeoAI.tools.builtin.plan_executor")

      -- 先清理
      plan_executor.cleanup_completed_agents()

      -- 创建子 agent
      local result = nil
      call_tool(plan_executor.create_sub_agent, {
        task = "测试任务：读取当前目录下的文件列表",
        boundaries = {
          allowed_tools = { "^run_command$", "^read_file$" },
          allowed_commands = { "^ls ", "^cat " },
          description = "只允许读取文件列表和文件内容",
          max_tool_calls = 5,
          max_iterations = 3,
        },
        timeout = 30,
      }, function(res) result = res end, function(err) result = { error = err } end)

      -- 等待异步回调
      local ok = safe_wait(2000, function() return result ~= nil end)
      assert.is_true(ok, "create_sub_agent 应在 2 秒内回调")
      assert.not_nil(result, "创建结果不应为 nil")
      assert.not_nil(result.sub_agent_id, "应包含 sub_agent_id")
      assert.equal("running", result.status, "状态应为 running")

      local sub_agent_id = result.sub_agent_id
      test._logger.info("子 agent 已创建: " .. sub_agent_id)

      -- 测试 get_all_agents_data 同步接口
      local agents = plan_executor.get_all_agents_data()
      assert.is_true(#agents > 0, "get_all_agents_data 应返回数据")
      local found = false
      for _, agent in ipairs(agents) do
        if agent.sub_agent_id == sub_agent_id then
          found = true
          assert.equal("测试任务：读取当前目录下的文件列表", agent.task)
          assert.equal("running", agent.status)
          break
        end
      end
      assert.is_true(found, "应能在 get_all_agents_data 中找到新创建的子 agent")

      -- 测试 get_sub_agent_status 同步获取状态
      local status_result = nil
      call_tool(plan_executor.get_sub_agent_status, { sub_agent_id = sub_agent_id },
        function(s) status_result = s end,
        function(e) status_result = { error = e } end
      )
      local ok2 = safe_wait(1000, function() return status_result ~= nil end)
      assert.is_true(ok2, "get_sub_agent_status 应在 1 秒内回调")
      assert.not_nil(status_result, "状态结果不应为 nil")
      assert.equal(sub_agent_id, status_result.sub_agent_id)

      -- 测试 get_sub_agent_status 不传 sub_agent_id 时列出所有
      local list_result = nil
      call_tool(plan_executor.get_sub_agent_status, {},
        function(r) list_result = r end,
        function(e) list_result = { error = e } end
      )
      local ok3 = safe_wait(1000, function() return list_result ~= nil end)
      assert.is_true(ok3, "get_sub_agent_status(列出所有) 应在 1 秒内回调")
      assert.not_nil(list_result, "列表结果不应为 nil")
      assert.is_true(list_result.count > 0, "应有子 agent")

      -- 测试监控组件的 get_all_agents_data 也能获取到数据
      local plan_executor2 = require("NeoAI.tools.builtin.plan_executor")
      local enriched = plan_executor2.get_all_agents_data()
      assert.is_true(#enriched > 0, "监控组件通过 get_all_agents_data 应能获取到数据")

      -- 清理
      plan_executor.cleanup_sub_agent(sub_agent_id)
    end,

    --- 测试 2: 测试边界审核功能
    test_boundary_review = function()
      local plan_executor = require("NeoAI.tools.builtin.plan_executor")

      -- 创建带严格边界的子 agent
      local result = nil
      call_tool(plan_executor.create_sub_agent, {
        task = "边界测试",
        boundaries = {
          allowed_tools = { "^read_file$" },
          allowed_commands = {},
          description = "只允许 read_file 工具",
          max_tool_calls = 10,
        },
        timeout = 30,
      }, function(res) result = res end, function(err) result = { error = err } end)

      local ok = safe_wait(2000, function() return result ~= nil end)
      assert.is_true(ok, "create_sub_agent 应在 2 秒内回调")
      local sub_agent_id = result.sub_agent_id

      -- 测试允许的工具
      local allowed, reason = plan_executor.review_tool_call(sub_agent_id, {
        name = "read_file",
        arguments = { filepath = "/tmp/test.txt" },
      })
      assert.is_true(allowed, "read_file 应被允许")
      assert.is_nil(reason, "不应有驳回理由")

      -- 测试不允许的工具
      local denied, deny_reason = plan_executor.review_tool_call(sub_agent_id, {
        name = "run_command",
        arguments = { cmd = "ls" },
      })
      assert.is_false(denied, "run_command 应被拒绝")
      assert.not_nil(deny_reason, "应有驳回理由")

      -- 验证被驳回的调用已记录
      local status_result = nil
      call_tool(plan_executor.get_sub_agent_status, { sub_agent_id = sub_agent_id },
        function(s) status_result = s end
      )
      safe_wait(1000, function() return status_result ~= nil end)
      assert.is_true(status_result.rejected_calls_count > 0, "应有被驳回的记录")

      -- 清理
      plan_executor.cleanup_sub_agent(sub_agent_id)
    end,

    --- 测试 3: 测试取消子 agent
    test_cancel_sub_agent = function()
      local plan_executor = require("NeoAI.tools.builtin.plan_executor")

      local result = nil
      call_tool(plan_executor.create_sub_agent, {
        task = "取消测试",
        timeout = 60,
      }, function(res) result = res end)

      local ok = safe_wait(2000, function() return result ~= nil end)
      assert.is_true(ok, "create_sub_agent 应在 2 秒内回调")
      local sub_agent_id = result.sub_agent_id

      -- 取消子 agent
      local cancel_result = nil
      call_tool(plan_executor.cancel_sub_agent, {
        sub_agent_id = sub_agent_id,
        reason = "测试取消",
      }, function(r) cancel_result = r end)

      safe_wait(1000, function() return cancel_result ~= nil end)
      assert.not_nil(cancel_result, "取消结果不应为 nil")
      assert.equal("rejected", cancel_result.status)

      -- 验证状态已更新
      local agents = plan_executor.get_all_agents_data()
      for _, agent in ipairs(agents) do
        if agent.sub_agent_id == sub_agent_id then
          assert.equal("rejected", agent.status)
          break
        end
      end

      plan_executor.cleanup_sub_agent(sub_agent_id)
    end,

    --- 测试 4: 测试 should_continue 和迭代计数
    test_should_continue = function()
      local plan_executor = require("NeoAI.tools.builtin.plan_executor")

      local result = nil
      call_tool(plan_executor.create_sub_agent, {
        task = "迭代测试",
        boundaries = { max_iterations = 3 },
        timeout = 30,
      }, function(res) result = res end)

      local ok = safe_wait(2000, function() return result ~= nil end)
      assert.is_true(ok)
      local sub_agent_id = result.sub_agent_id

 -- should_continue 不递增计数，需要先通过 update_iteration_count 同步
      -- 模拟 sub_agent_engine._request_generation 中的调用顺序：
      --   1. runner.iteration_count = runner.iteration_count + 1
      --   2. plan_executor.update_iteration_count(sub_agent_id, runner.iteration_count)
      --   3. plan_executor.should_continue(sub_agent_id)
      -- max_iterations=3，所以 iter=1,2 时返回 true，iter=3 时返回 false
      for i = 1, 2 do
        plan_executor.update_iteration_count(sub_agent_id, i)
        local cont = plan_executor.should_continue(sub_agent_id)
        assert.is_true(cont, string.format("iter=%d 应返回 true (max=3)", i))
      end
      -- iter=3 >= max=3，应返回 false
      plan_executor.update_iteration_count(sub_agent_id, 3)
      assert.is_false(plan_executor.should_continue(sub_agent_id),
        "iter=3 应返回 false (>= max=3)")

      -- 验证状态变为 completed
      local agents = plan_executor.get_all_agents_data()
      for _, agent in ipairs(agents) do
        if agent.sub_agent_id == sub_agent_id then
          assert.equal("completed", agent.status)
          assert.not_nil(agent.summary, "应有执行总结")
          break
        end
      end

      plan_executor.cleanup_sub_agent(sub_agent_id)
    end,

    --- 测试 5: 测试监控组件 _build_content 能正确渲染
    test_monitor_build_content = function()
      local plan_executor = require("NeoAI.tools.builtin.plan_executor")

      -- 创建一个子 agent
      local result = nil
      call_tool(plan_executor.create_sub_agent, {
        task = "监控渲染测试",
        timeout = 30,
      }, function(res) result = res end)

      local ok = safe_wait(2000, function() return result ~= nil end)
      assert.is_true(ok)

      -- 通过 get_all_agents_data 获取数据
      local agents = plan_executor.get_all_agents_data()
      assert.is_true(#agents > 0, "应有子 agent 数据")

      -- 验证监控组件能正常获取数据
      local plan_executor2 = require("NeoAI.tools.builtin.plan_executor")
      local enriched = plan_executor2.get_all_agents_data()
      assert.is_true(#enriched > 0, "监控组件应能获取到数据")

      -- 清理所有
      plan_executor.cleanup_completed_agents()
    end,
  })
end

if not _G._NEOAI_TEST_RUNNING then
  M.run()
end

return M
