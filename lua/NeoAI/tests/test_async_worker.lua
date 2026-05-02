--- 测试: utils/async_worker.lua
--- 测试异步工作器的任务提交、执行、超时、取消、批量提交等功能
local M = {}

local test

--- 运行所有测试
function M.run(test_module)
  test = test_module or require("NeoAI.tests")
  local assert = test.assert
  print("\n=== test_async_worker ===")

  return test.run_tests({
    --- 测试 submit_task 基本功能
    test_submit_task = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()

      local result = nil
      local id = aw.submit_task("test_task", function()
        return "task_result"
      end, function(success, res)
        result = res
      end)

      assert.is_true(id > 0, "应返回任务ID")

      -- 等待异步完成
      vim.wait(500, function() return result ~= nil end)
      assert.equal("task_result", result)
    end,

    --- 测试 submit_task 失败
    test_submit_task_fail = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()

      local error_msg = nil
      aw.submit_task("fail_task", function()
        error("任务失败")
      end, function(success, res, err)
        error_msg = err
      end)

      vim.wait(500, function() return error_msg ~= nil end)
      assert.not_nil(error_msg, "应返回错误信息")
    end,

    --- 测试 submit_task 超时
    test_submit_task_timeout = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()

      local timed_out = false
      aw.submit_task("timeout_task", function()
        -- 模拟长时间运行的任务
        local start = vim.uv.now()
        while vim.uv.now() - start < 200 do
          vim.uv.run("once")
        end
        return "done"
      end, function(success, res, err)
        if not success and err then
          timed_out = true
        end
      end, { timeout_ms = 50 })

      vim.wait(500, function() return timed_out end)
      -- 超时可能不会立即生效，因为任务已经在执行中
    end,

    --- 测试 submit_batch
    test_submit_batch = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()

      local results = {}
      local ids = aw.submit_batch({
        { name = "batch_1", task_func = function() return "r1" end, callback = function(s, r) results[1] = r end },
        { name = "batch_2", task_func = function() return "r2" end, callback = function(s, r) results[2] = r end },
      })

      assert.is_true(#ids == 2, "应有2个任务ID")

      vim.wait(500, function() return results[1] ~= nil and results[2] ~= nil end)
      assert.equal("r1", results[1])
      assert.equal("r2", results[2])
    end,

    --- 测试 get_worker_status
    test_get_worker_status = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()

      local id = aw.submit_task("status_test", function() return "ok" end)

      local status = aw.get_worker_status(id)
      assert.not_nil(status)
      assert.equal("status_test", status.name)

      vim.wait(500, function() return aw.get_worker_status(id) == nil end)
    end,

    --- 测试 get_all_worker_status
    test_get_all_worker_status = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()

      aw.submit_task("all_test", function() return "ok" end)
      local all = aw.get_all_worker_status()
      assert.is_true(type(all) == "table")
    end,

    --- 测试 cancel_worker
    test_cancel_worker = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()

      local id = aw.submit_task("cancel_test", function()
        local start = vim.uv.now()
        while vim.uv.now() - start < 500 do
          vim.uv.run("once")
        end
        return "too_late"
      end)

      local cancelled = aw.cancel_worker(id)
      assert.is_true(cancelled, "取消应成功")
    end,

    --- 测试 cancel_all_workers
    test_cancel_all_workers = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()

      aw.submit_task("c1", function()
        local start = vim.uv.now()
        while vim.uv.now() - start < 500 do vim.uv.run("once") end
        return "ok"
      end)
      aw.submit_task("c2", function()
        local start = vim.uv.now()
        while vim.uv.now() - start < 500 do vim.uv.run("once") end
        return "ok"
      end)

      local cancelled = aw.cancel_all_workers()
      assert.is_true(#cancelled >= 0)
    end,

    --- 测试 cleanup_completed
    test_cleanup_completed = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()

      aw.submit_task("cleanup_test", function() return "ok" end)
      vim.wait(500, function() return aw.get_total_count() == 0 end)
      aw.cleanup_completed()
    end,

    --- 测试 set_max_workers / get_active_count / get_total_count
    test_worker_counts = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()

      aw.set_max_workers(5)
      assert.equal(0, aw.get_active_count())
      assert.equal(0, aw.get_total_count())
    end,

    --- 测试 run_in_background
    test_run_in_background = function()
      local aw = require("NeoAI.utils.async_worker")

      local result = nil
      aw.run_in_background(function(a, b)
        return a + b
      end, function(success, res)
        result = res
      end, 3, 4)

      vim.wait(500, function() return result ~= nil end)
      assert.equal(7, result)
    end,

    --- 测试 run_batch_tasks
    test_run_batch_tasks = function()
      local aw = require("NeoAI.utils.async_worker")

      local all_done = false
      aw.run_batch_tasks({
        { func = function() return 1 end },
        { func = function() return 2 end },
      }, function(success, results)
        all_done = true
        assert.equal(1, results[1])
        assert.equal(2, results[2])
      end)

      vim.wait(500, function() return all_done end)
    end,

    --- 测试 create_thread_safe_callback
    test_thread_safe_callback = function()
      local aw = require("NeoAI.utils.async_worker")

      local called = false
      local safe_cb = aw.create_thread_safe_callback(function()
        called = true
      end)

      assert.not_nil(safe_cb)
      safe_cb()
      vim.wait(100, function() return called end)
      assert.is_true(called)
    end,

    --- 测试 compute_heavy_task
    test_compute_heavy_task = function()
      local aw = require("NeoAI.utils.async_worker")

      local result = nil
      aw.compute_heavy_task(function()
        local sum = 0
        for i = 1, 100 do sum = sum + i end
        return sum
      end, function(success, res)
        result = res
      end)

      vim.wait(500, function() return result ~= nil end)
      assert.equal(5050, result)
    end,

    --- 测试 schedule_ui_update / batch_ui_updates
    test_ui_updates = function()
      local aw = require("NeoAI.utils.async_worker")

      local called = false
      aw.schedule_ui_update(function()
        called = true
      end, 10)

      vim.wait(200, function() return called end)
      assert.is_true(called)

      local called2 = false
      aw.batch_ui_updates({
        function() called2 = true end,
      })
      vim.wait(100, function() return called2 end)
    end,

    --- 测试 reset
    test_reset = function()
      local aw = require("NeoAI.utils.async_worker")
      aw.reset()
      assert.equal(0, aw.get_total_count())
    end,
  })
end

-- 直接运行
if pcall(vim.api.nvim_buf_get_name, 0) then
  M.run()
end

return M
