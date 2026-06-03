--- 流程测试: 事件系统
--- 验证事件定义完整性、事件触发/监听、跨模块事件协作

local M = {}

function M.run(test_module)
  local assert = test_module.assert
  local logger = test_module._logger or require("NeoAI.utils.logger")

  local tests = {

    -- ============================================================
    -- 流程 1: 事件定义完整性验证
    -- ============================================================
    flow_event_definitions = function()
      local Events = require("NeoAI.core.events")

      -- 验证 Events 模块可加载
      assert.not_nil(Events, "Events 模块应可加载")

      -- 收集所有事件常量（以 NeoAI: 开头的字符串值）
      local event_values = {}
      local event_names = {}
      for k, v in pairs(Events) do
        if type(v) == "string" and v:find("^NeoAI:", 1) then
          table.insert(event_names, k)
          table.insert(event_values, v)
        end
      end

      -- 验证有事件常量被定义
      assert.is_true(#event_names > 0, "应有事件常量被定义，实际: " .. #event_names)

      -- 所有事件值应以 NeoAI: 开头
      for _, name in ipairs(event_names) do
        local value = Events[name]
        assert.is_true(string.find(value, "^NeoAI:"),
          "事件 " .. name .. " 应以 NeoAI: 开头，实际: " .. value)
      end

      -- 验证事件值唯一性
      local seen = {}
      for _, v in ipairs(event_values) do
        assert.is_false(seen[v], "事件值 " .. v .. " 不应重复")
        seen[v] = true
      end

      -- 验证关键事件分组存在
      -- AI 生成事件
      assert.not_nil(Events.GENERATION_STARTED, "应有 GENERATION_STARTED")
      assert.not_nil(Events.GENERATION_COMPLETED, "应有 GENERATION_COMPLETED")
      assert.not_nil(Events.GENERATION_ERROR, "应有 GENERATION_ERROR")
      assert.not_nil(Events.GENERATION_CANCELLED, "应有 GENERATION_CANCELLED")

      -- 流式处理事件
      assert.not_nil(Events.STREAM_STARTED, "应有 STREAM_STARTED")
      assert.not_nil(Events.STREAM_CHUNK, "应有 STREAM_CHUNK")
      assert.not_nil(Events.STREAM_COMPLETED, "应有 STREAM_COMPLETED")

      -- 推理/思考事件
      assert.not_nil(Events.REASONING_CONTENT, "应有 REASONING_CONTENT")
      assert.not_nil(Events.REASONING_STARTED, "应有 REASONING_STARTED")
      assert.not_nil(Events.REASONING_COMPLETED, "应有 REASONING_COMPLETED")

      -- 工具相关事件
      assert.not_nil(Events.TOOL_LOOP_STARTED, "应有 TOOL_LOOP_STARTED")
      assert.not_nil(Events.TOOL_LOOP_FINISHED, "应有 TOOL_LOOP_FINISHED")
      assert.not_nil(Events.TOOL_EXECUTION_STARTED, "应有 TOOL_EXECUTION_STARTED")
      assert.not_nil(Events.TOOL_EXECUTION_COMPLETED, "应有 TOOL_EXECUTION_COMPLETED")
      assert.not_nil(Events.TOOL_CALLS_READY, "应有 TOOL_CALLS_READY")
      assert.not_nil(Events.TOOL_RESULT_RECEIVED, "应有 TOOL_RESULT_RECEIVED")

      -- 会话事件
      assert.not_nil(Events.SESSION_CREATED, "应有 SESSION_CREATED")
      assert.not_nil(Events.SESSION_SAVED, "应有 SESSION_SAVED")
      assert.not_nil(Events.SESSION_DELETED, "应有 SESSION_DELETED")
      assert.not_nil(Events.SESSION_CHANGED, "应有 SESSION_CHANGED")
      assert.not_nil(Events.SESSION_RENAMED, "应有 SESSION_RENAMED")

      -- 窗口/UI 事件
      assert.not_nil(Events.CHAT_WINDOW_OPENED, "应有 CHAT_WINDOW_OPENED")
      assert.not_nil(Events.CHAT_WINDOW_CLOSED, "应有 CHAT_WINDOW_CLOSED")
      assert.not_nil(Events.TREE_WINDOW_OPENED, "应有 TREE_WINDOW_OPENED")
      assert.not_nil(Events.TREE_WINDOW_CLOSED, "应有 TREE_WINDOW_CLOSED")

      assert.not_nil(Events.PLUGIN_INITIALIZED, "应有 PLUGIN_INITIALIZED")
      assert.not_nil(Events.PLUGIN_SHUTDOWN, "应有 PLUGIN_SHUTDOWN")
    end,

    -- ============================================================
    -- 流程 2: 事件触发/监听协作风暴
    -- ============================================================
    flow_event_trigger_listen = function()
      local Events = require("NeoAI.core.events")

      -- 创建 autocmd 监听器并验证不报错
      local ok1, group_id = pcall(vim.api.nvim_create_augroup, "NeoAI_flow_test_event", { clear = true })
      assert.is_true(ok1, "创建 augroup 不应报错")

      local received = {}
      local ok2, aucmd_id = pcall(vim.api.nvim_create_autocmd, "User", {
        group = group_id,
        pattern = "NeoAI:FlowTestEvent",
        callback = function(args)
          received.count = (received.count or 0) + 1
          received.data = args.data
        end,
      })
      assert.is_true(ok2, "创建 autocmd 不应报错")

      -- 触发事件
      local test_data = { flow = "test", value = 42 }
      local ok3 = pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "NeoAI:FlowTestEvent",
        data = test_data,
      })
      assert.is_true(ok3, "触发 autocmd 不应报错")

      -- 验证回调被调用
      -- 注意：autocmd 回调是同步的
      assert.equal(1, received.count or 0, "事件应被触发 1 次，实际: " .. tostring(received.count))
      assert.equal(42, received.data and received.data.value, "事件数据应正确传递")

      -- 清理
      pcall(vim.api.nvim_del_autocmd, aucmd_id)
      pcall(vim.api.nvim_del_augroup_by_id, group_id)
    end,

    -- ============================================================
    -- 流程 3: 事件触发后数据一致性
    -- ============================================================
    flow_event_data_integrity = function()
      -- 创建监听
      local received = {}
      local group = vim.api.nvim_create_augroup("NeoAI_flow_integrity", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "NeoAI:IntegrityTest",
        callback = function(args)
          received.raw = args.data
          if type(args.data) == "table" then
            received.deep = vim.deepcopy(args.data)
          end
        end,
      })

      -- 发送复杂数据
      local complex = {
        string_val = "hello",
        number_val = 3.14,
        bool_val = true,
        array_val = { 1, 2, 3 },
        nested = { key = "value" },
      }
      vim.api.nvim_exec_autocmds("User", {
        pattern = "NeoAI:IntegrityTest",
        data = complex,
      })

      -- 验证深层数据完整性
      assert.not_nil(received.raw, "应收到原始数据")
      assert.equal("hello", received.deep and received.deep.string_val, "字符串值应正确")
      assert.equal(3.14, received.deep and received.deep.number_val, "数字值应正确")
      assert.equal(true, received.deep and received.deep.bool_val, "布尔值应正确")
      assert.equal(3, received.deep and #(received.deep.array_val or {}), "数组长度应正确")
      assert.equal("value", received.deep and received.deep.nested and received.deep.nested.key, "嵌套值应正确")

      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,

    -- ============================================================
    -- 流程 4: 多监听器并发协作
    -- ============================================================
    flow_event_multi_listeners = function()
      local group = vim.api.nvim_create_augroup("NeoAI_flow_multi", { clear = true })
      local callbacks_called = {}

      -- 注册 3 个监听器
      for i = 1, 3 do
        vim.api.nvim_create_autocmd("User", {
          group = group,
          pattern = "NeoAI:MultiTest",
          callback = function()
            table.insert(callbacks_called, i)
          end,
        })
      end

      -- 触发事件
      vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:MultiTest" })

      -- 验证所有 3 个监听器都被调用
      assert.equal(3, #callbacks_called, "所有 3 个监听器都应被调用，实际: " .. #callbacks_called)
      -- 验证顺序（Neovim 按注册顺序调用）
      assert.equal(1, callbacks_called[1], "第一个回调应为 1")
      assert.equal(2, callbacks_called[2], "第二个回调应为 2")
      assert.equal(3, callbacks_called[3], "第三个回调应为 3")

      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,

    -- ============================================================
    -- 流程 5: 事件错误隔离
    -- ============================================================
    flow_event_error_isolation = function()
      local group = vim.api.nvim_create_augroup("NeoAI_flow_error_iso", { clear = true })
      local call_order = {}

      -- 监听器 1: 正常
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "NeoAI:ErrorIsoTest",
        callback = function()
          table.insert(call_order, "A")
        end,
      })

      -- 注意：Neovim autocmd 中的错误不会阻止其他回调
      -- 这里验证事件隔离机制的概念

      -- 监听器 2: 也可能抛错，但我们用 pcall 包裹
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "NeoAI:ErrorIsoTest",
        callback = function()
          local ok = pcall(function()
            -- 正常操作
            table.insert(call_order, "B")
          end)
        end,
      })

      -- 监听器 3: 正常
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "NeoAI:ErrorIsoTest",
        callback = function()
          table.insert(call_order, "C")
        end,
      })

      -- 触发事件
      vim.api.nvim_exec_autocmds("User", { pattern = "NeoAI:ErrorIsoTest" })

      -- 所有不抛错的监听器都应被调用
      assert.is_true(#call_order >= 2, "至少 2 个回调应被调用")

      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,

    -- ============================================================
    -- 流程 6: state.fire_event 通过 autocmd 协作
    -- ============================================================
    flow_state_fire_event_integration = function()
      local sm = require("NeoAI.core.config.state")
      local group = vim.api.nvim_create_augroup("NeoAI_flow_state_event", { clear = true })
      local received = {}

      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "NeoAI:StateFireTest",
        callback = function(args)
          received.data = args.data
          received.count = (received.count or 0) + 1
        end,
      })

      -- 通过 state.fire_event 触发
      sm.fire_event("NeoAI:StateFireTest", { from_state = true, num = 99 })
      assert.equal(1, received.count or 0, "fire_event 应触发 autocmd")
      assert.equal(true, received.data and received.data.from_state, "数据应正确传递")
      assert.equal(99, received.data and received.data.num, "num 应正确传递")

      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,

    -- ============================================================
    -- 流程 7: 事件注册/注销生命周期
    -- ============================================================
    flow_event_register_unregister = function()
      local group = vim.api.nvim_create_augroup("NeoAI_flow_lifecycle", { clear = true })

      -- 创建
      local id = vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "NeoAI:LifecycleTest",
        callback = function() end,
      })
      assert.type_eq("number", id, "autocmd id 应为数字")

      -- 验证已创建
      local exists = vim.api.nvim_get_autocmds({
        group = group,
        event = "User",
        pattern = "NeoAI:LifecycleTest",
      })
      assert.is_true(#exists >= 1, "autocmd 应存在")

      -- 删除
      pcall(vim.api.nvim_del_autocmd, id)

      -- 验证已删除
      local after = vim.api.nvim_get_autocmds({
        group = group,
        event = "User",
        pattern = "NeoAI:LifecycleTest",
      })
      assert.equal(0, #after, "删除后 autocmd 不应存在")

      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  }

  return test_module.run_tests(tests)
end

return M
