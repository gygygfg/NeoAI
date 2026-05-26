--- NeoAI 异步编排器
--- 职责：管理 AI→工具→AI 的异步循环编排
---
--- 架构：
---   AI 请求线程 → 获取响应 → 解析 tool_calls
---     → 有工具调用：批量创建工具调用线程（全部并行）
---     → 工具线程全部完成后 → 汇总结果 → 新建 AI 请求线程
---     → 无工具调用：结束循环，返回最终结果
---
--- 线程模型：
---   每次 AI 请求 → 新开一个线程（curl jobstart 子进程）
---   每个工具调用 → 新开一个线程（jobstart/主线程）
---   线程完成后自动回收
---
--- 与 UI 的关系：
---   编排器通过事件通知 UI 更新（TOOL_LOOP_STARTED、STREAM_CHUNK 等）
---   UI 仅做展示，不阻断后台执行
---   工具审批通过事件机制在主线程暂停，审批通过后恢复
---
--- 使用方式：
---   local orch = require("NeoAI.core.ai.async_orchestrator")
---   
---   orch.start_loop({
---     session_id = "sess_001",
---     window_id = 42,
---     messages = {...},
---     options = {...},
---     on_complete = function(success, result, usage) ... end,
---   })

local M = {}

local logger = require("NeoAI.utils.logger")
local thread_pool = require("NeoAI.core.ai.thread_pool")
local event_constants = require("NeoAI.core.events")
local state_manager = require("NeoAI.core.config.state")
local shutdown_flag = require("NeoAI.core.shutdown_flag")
local http_utils = require("NeoAI.utils.http_utils")
local request_handler = require("NeoAI.core.ai.request_handler")
local tool_pack = require("NeoAI.tools.tool_pack")
local tool_executor = require("NeoAI.tools.tool_executor")

-- ========== 编排器状态 ==========

local orch_state = {
  initialized = false,
  active_loops = {},     -- session_id → loop_state
  stop_listeners = {},   -- session_id → autocmd_id
}

-- ========== 初始化 ==========

function M.initialize(options)
  if orch_state.initialized then return M end
  thread_pool.initialize(options or {})
  orch_state.initialized = true
  logger.info("[async_orchestrator] 异步编排器初始化完成, instance=%s", thread_pool.get_instance_id())
  return M
end

-- ========== 循环启动 ==========

--- 启动 AI→工具→AI 异步循环
--- @param params table
---   session_id: string
---   window_id: number
---   messages: table
---   options: table
---   model_index: number
---   ai_preset: table
---   on_complete: function
function M.start_loop(params)
  if not orch_state.initialized then
    M.initialize()
  end

  local session_id = params.session_id
  if not session_id then
    logger.error("[async_orchestrator] start_loop: session_id 为空")
    if params.on_complete then
      params.on_complete(false, nil, "session_id is required")
    end
    return
  end

  -- 创建循环状态
  local loop = {
    session_id = session_id,
    window_id = params.window_id,
    messages = params.messages or {},
    options = params.options or {},
    model_index = params.model_index or 1,
    ai_preset = params.ai_preset or {},
    on_complete = params.on_complete,
    generation_id = params.generation_id or (os.time() .. "_" .. math.random(1000, 9999)),
    iteration = 0,
    stop_requested = false,
    accumulated_usage = {},
    last_reasoning = nil,
    worker_ids = {},     -- 当前活跃的线程 IDs
  }

  orch_state.active_loops[session_id] = loop

  logger.info("[async_orchestrator] 循环启动: session=%s, generation=%s, messages=%d",
    session_id, loop.generation_id, #loop.messages)

  -- 注册停止监听器
  _register_stop_listener(session_id, loop)

  -- 启动第一轮 AI 请求
  loop.iteration = 1
  _request_ai_generation(loop)
end

-- ========== AI 请求线程 ==========

--- 发起 AI 生成请求（新线程）
--- @param loop table 循环状态
function _request_ai_generation(loop)
  if loop.stop_requested then
    _finish_loop(loop, false, nil, "stopped")
    return
  end

  if shutdown_flag.is_set() then
    _finish_loop(loop, false, nil, "shutdown")
    return
  end

  -- 检查迭代上限
  local max_iter = loop.options.max_iterations or 30
  if loop.iteration > max_iter then
    logger.warn("[async_orchestrator] 达到最大迭代轮次: %d", max_iter)
    _finish_loop(loop, true, loop.messages[#loop.messages] and loop.messages[#loop.messages].content or "", "max_iterations")
    return
  end

  logger.info("[async_orchestrator] AI请求线程: session=%s, 轮次=%d", loop.session_id, loop.iteration)

  -- 构建请求
  local ai_preset = loop.ai_preset
  local formatted = request_handler.format_messages(loop.messages)

  -- 插入系统提示词（如果有）
  if ai_preset.system_prompt and ai_preset.system_prompt ~= "" then
    local has_system = false
    for _, msg in ipairs(formatted) do
      if msg.role == "system" then
        has_system = true
        break
      end
    end
    if not has_system then
      table.insert(formatted, 1, { role = "system", content = ai_preset.system_prompt })
    end
  end

  local stream_val = loop.options.stream
  if stream_val == nil then
    stream_val = ai_preset.stream ~= false
  end

  local request = request_handler.build_request({
    messages = formatted,
    options = vim.tbl_extend("force", loop.options, {
      model = ai_preset.model_name or loop.options.model,
      temperature = ai_preset.temperature or loop.options.temperature,
      max_tokens = ai_preset.max_tokens or loop.options.max_tokens,
      stream = stream_val,
    }),
    session_id = loop.session_id,
    generation_id = loop.generation_id,
  })

  -- 更新 loop 的 generation_id（如果 build_request 生成了新的）
  loop.generation_id = request.generation_id or loop.generation_id

  -- 提交到线程池
  local worker_id, wrapped_cb = thread_pool.submit_ai_request({
    request = request,
    generation_id = loop.generation_id,
    base_url = ai_preset.base_url,
    api_key = ai_preset.api_key,
    api_type = ai_preset.provider or "deepseek",
    stream = stream_val,
  }, function(success, response, err)
    _on_ai_response(loop, success, response, err)
  end)

  if worker_id then
    table.insert(loop.worker_ids, worker_id)
  end

  -- 使用流式请求
  if stream_val then
    -- 创建流式处理器
    local processor = http_utils.create_stream_processor(
      loop.generation_id, loop.session_id, loop.window_id, true)

    -- 发送流式请求
    _send_stream_ai_request(loop, request, ai_preset, processor, wrapped_cb)
  else
    -- 发送非流式请求
    _send_non_stream_ai_request(loop, request, ai_preset, wrapped_cb)
  end
end

--- 发送流式 AI 请求
function _send_stream_ai_request(loop, request, ai_preset, processor, wrapped_cb)
  local params = {
    request = request,
    generation_id = loop.generation_id,
    base_url = ai_preset.base_url,
    api_key = ai_preset.api_key,
    api_type = ai_preset.provider or "deepseek",
    stream = true,
  }

  http_utils.send_stream_request(params,
    -- on_chunk: 流式数据块
    function(chunk)
      if not chunk or loop.stop_requested then return end

      local result = http_utils.process_stream_chunk(processor, chunk)
      if not result then return end

      -- 发送 STREAM_CHUNK 事件（UI 更新）
      if not shutdown_flag.is_set() then
        if result.tool_calls and #result.tool_calls > 0 then
          vim.api.nvim_exec_autocmds("User", {
            pattern = event_constants.TOOL_CALLS_READY,
            data = {
              generation_id = loop.generation_id,
              tool_calls = result.tool_calls,
              session_id = loop.session_id,
              window_id = loop.window_id,
            },
          })
        end
      end

      -- 发送内容块到 UI
      if result.content or result.reasoning_content then
        if not shutdown_flag.is_set() then
          vim.api.nvim_exec_autocmds("User", {
            pattern = event_constants.STREAM_CHUNK,
            data = {
              generation_id = loop.generation_id,
              content = result.content,
              reasoning_content = result.reasoning_content,
              session_id = loop.session_id,
              window_id = loop.window_id,
              is_final = result.is_final,
              usage = result.usage,
              tool_calls = result.tool_calls,
            },
          })
        end
      end
    end,
    -- on_complete: 流式完成
    function()
      -- 处理最终结果
      local full_response = processor.content_buffer or ""
      local reasoning_text = processor.reasoning_buffer or ""
      local usage = processor.usage or {}
      local tool_calls = http_utils.filter_valid_tool_calls(processor.tool_calls or {})

      -- XML 回退
      if #tool_calls == 0 and full_response ~= "" then
        local xml_tool_calls = request_handler.extract_xml_tool_calls(full_response)
        if xml_tool_calls and #xml_tool_calls > 0 then
          tool_calls = xml_tool_calls
        end
      end

      local response = {
        content = full_response,
        reasoning_content = reasoning_text,
        usage = usage,
        tool_calls = tool_calls,
      }

      wrapped_cb(true, response, nil)
    end,
    -- on_error: 流式错误
    function(err)
      wrapped_cb(false, nil, err)
    end
  )
end

--- 发送非流式 AI 请求
function _send_non_stream_ai_request(loop, request, ai_preset, wrapped_cb)
  http_utils.send_request_async({
    request = request,
    generation_id = loop.generation_id,
    base_url = ai_preset.base_url,
    api_key = ai_preset.api_key,
    api_type = ai_preset.provider or "deepseek",
  }, function(response, err)
    if err then
      wrapped_cb(false, nil, err)
      return
    end

    if not response then
      wrapped_cb(false, nil, "empty response")
      return
    end

    -- 解析响应
    local content = ""
    local reasoning_content = nil
    local usage = {}
    local tool_calls = {}

    if response.choices and #response.choices > 0 then
      local choice = response.choices[1]
      if choice.message then
        content = choice.message.content or ""
        reasoning_content = choice.message.reasoning_content
        if choice.message.tool_calls then
          tool_calls = choice.message.tool_calls
        end
      end
    end

    if response.usage then
      usage = response.usage
    end

    -- XML 回退
    if #tool_calls == 0 and content ~= "" then
      local xml_tool_calls = request_handler.extract_xml_tool_calls(content)
      if xml_tool_calls and #xml_tool_calls > 0 then
        tool_calls = xml_tool_calls
      end
    end

    wrapped_cb(true, {
      content = content,
      reasoning_content = reasoning_content,
      usage = usage,
      tool_calls = tool_calls,
    }, nil)
  end)
end

-- ========== AI 响应处理 ==========

--- 处理 AI 响应
--- @param loop table
--- @param success boolean
--- @param response table|nil
--- @param err string|nil
function _on_ai_response(loop, success, response, err)
  if loop.stop_requested then
    _finish_loop(loop, false, nil, "stopped during AI response")
    return
  end

  if shutdown_flag.is_set() then
    _finish_loop(loop, false, nil, "shutdown")
    return
  end

  if not success or not response then
    logger.error("[async_orchestrator] AI请求失败: session=%s, err=%s", loop.session_id, tostring(err))
    -- 触发重试逻辑（委托给 request_handler）
    _handle_ai_error(loop, err)
    return
  end

  local content = response.content or ""
  local reasoning_text = response.reasoning_content or ""
  local usage = response.usage or {}
  local tool_calls = response.tool_calls or {}

  -- 累积 usage
  if usage and next(usage) then
    local acc = loop.accumulated_usage or {}
    acc.prompt_tokens = (acc.prompt_tokens or 0) + (usage.prompt_tokens or 0)
    acc.completion_tokens = (acc.completion_tokens or 0) + (usage.completion_tokens or 0)
    acc.total_tokens = (acc.total_tokens or 0) + (usage.total_tokens or 0)
    loop.accumulated_usage = acc
  end

  -- 保存 reasoning
  if reasoning_text ~= "" then
    loop.last_reasoning = reasoning_text
  end

  -- 异常检测
  local is_tool_loop = loop.iteration > 1
  local abnormal, reason = request_handler.detect_abnormal_response(content, tool_calls, {
    is_tool_loop = is_tool_loop,
  })

  if abnormal then
    logger.warn("[async_orchestrator] 检测到异常响应: session=%s, reason=%s", loop.session_id, reason)
    local retry_count = loop._ai_retry_count or 0
    if request_handler.can_retry(retry_count, reason, is_tool_loop) then
      loop._ai_retry_count = retry_count + 1
      local delay = request_handler.get_retry_delay(retry_count)

      -- 触发重试事件
      if not shutdown_flag.is_set() then
        vim.api.nvim_exec_autocmds("User", {
          pattern = event_constants.GENERATION_RETRYING,
          data = {
            session_id = loop.session_id,
            retry_count = loop._ai_retry_count,
            reason = reason,
          },
        })
      end

      vim.defer_fn(function()
        _request_ai_generation(loop)
      end, delay)
      return
    end
  else
    loop._ai_retry_count = 0
  end

  -- 添加 assistant 消息到消息历史
  local assistant_msg = {
    role = "assistant",
    content = content,
    timestamp = os.time(),
    window_id = loop.window_id,
  }
  if reasoning_text ~= "" then
    assistant_msg.reasoning_content = reasoning_text
  end
  if #tool_calls > 0 then
    assistant_msg.tool_calls = tool_calls
  end
  table.insert(loop.messages, assistant_msg)

  -- 检查是否有工具调用
  local tools_enabled = true
  local core_ok, core = pcall(require, "NeoAI.core")
  if core_ok and core.get_config then
    local cfg = core.get_config() or {}
    if cfg.tools then
      tools_enabled = cfg.tools.enabled ~= false
    end
  end

  if #tool_calls > 0 and tools_enabled then
    -- 有工具调用：进入工具执行阶段
    logger.info("[async_orchestrator] AI返回 %d 个工具调用，进入工具执行阶段: session=%s, 轮次=%d",
      #tool_calls, loop.session_id, loop.iteration)
    _execute_tools_phase(loop, tool_calls)
  else
    -- 无工具调用：循环结束
    logger.info("[async_orchestrator] AI无工具调用，循环结束: session=%s, 轮次=%d",
      loop.session_id, loop.iteration)
    _finish_loop(loop, true, content, nil)
  end
end

-- ========== 工具执行线程 ==========

--- 工具执行阶段：批量并发执行所有工具
--- @param loop table
--- @param tool_calls table
function _execute_tools_phase(loop, tool_calls)
  if loop.stop_requested then
    _finish_loop(loop, false, nil, "stopped")
    return
  end

  loop.iteration = loop.iteration + 1

  -- 按工具包分组
  local grouped = tool_pack.group_by_pack(tool_calls)
  local pack_order = {}
  for pack_name, _ in pairs(grouped) do
    table.insert(pack_order, pack_name)
  end
  table.sort(pack_order, function(a, b)
    return tool_pack.get_pack_order(a) < tool_pack.get_pack_order(b)
  end)

  -- 触发 TOOL_LOOP_STARTED 事件（UI 展示）
  if not shutdown_flag.is_set() then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_LOOP_STARTED,
      data = {
        generation_id = loop.generation_id,
        tool_calls = tool_calls,
        tool_packs = grouped,
        pack_order = pack_order,
        session_id = loop.session_id,
        window_id = loop.window_id,
        iteration = loop.iteration,
      },
    })
  end

  -- 构建工具任务列表（每个工具一个线程）
  local tasks = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name then
      local tool_name = func.name
      local args = func.arguments or {}

      -- 规范化工具名称
      local normalized_name, _ = tool_executor._normalize_tool_name(tool_name)

      table.insert(tasks, {
        name = normalized_name or tool_name,
        func = function()
          -- 工具实际执行（在 tool_executor 中）
          -- 这里返回一个占位，实际执行由 tool_cycle 管理
          return tool_executor.execute(normalized_name or tool_name, args)
        end,
        args = args,
        raw_tc = tc,
      })
    end
  end

  if #tasks == 0 then
    -- 没有有效工具，直接进入下一轮 AI 请求
    _request_ai_generation(loop)
    return
  end

  logger.info("[async_orchestrator] 工具执行阶段: session=%s, 工具数=%d, 并行执行",
    loop.session_id, #tasks)

  -- 通过 tool_cycle 执行工具（保持兼容性）
  -- tool_cycle 内部的 _execute_tools 已经通过 vim.schedule 实现了异步并发
  -- 这里我们通过线程池的 submit_tool_batch 增强并行性
  local tool_cycle = require("NeoAI.core.ai.tool_cycle")

  -- 使用 tool_cycle 的现有机制执行工具
  -- 注入 session_id 和 on_complete
  local sid = loop.session_id
  local ss = tool_cycle.get_session_state(sid)
  if not ss then
    -- 注册会话
    tool_cycle.register_session(sid, loop.window_id)
    ss = tool_cycle.get_session_state(sid)
  end

  if ss then
    ss.generation_id = loop.generation_id
    ss.messages = loop.messages
    ss.options = loop.options
    ss.model_index = loop.model_index
    ss.ai_preset = loop.ai_preset
    ss.accumulated_usage = loop.accumulated_usage
    ss.last_reasoning = loop.last_reasoning
    ss.current_iteration = loop.iteration
    ss.stop_requested = loop.stop_requested

    -- 注册完成回调
    ss.on_complete = function(success, result, err)
      if success then
        -- 工具全部执行完毕，进入下一轮 AI 请求
        -- 更新 loop 的消息和状态
        loop.messages = ss.messages or loop.messages
        loop.accumulated_usage = ss.accumulated_usage or loop.accumulated_usage
        loop.last_reasoning = ss.last_reasoning

        -- 检查是否还有工具调用
        if result and type(result) == "table" and result.tool_calls and #result.tool_calls > 0 then
          -- AI 返回了新的工具调用
          _execute_tools_phase(loop, result.tool_calls)
        else
          -- 继续 AI 请求
          _request_ai_generation(loop)
        end
      else
        _finish_loop(loop, false, nil, err or "tool execution failed")
      end
    end

    -- 设置临时 on_complete（用于本轮工具执行）
    ss._temp_on_tools_complete = function()
      -- 工具执行完毕后触发 AI 请求
      -- 此回调由 tool_cycle._on_tools_complete 间接调用
      loop.messages = ss.messages or loop.messages
      loop.accumulated_usage = ss.accumulated_usage or loop.accumulated_usage
      loop.last_reasoning = ss.last_reasoning
      _request_ai_generation(loop)
    end
  end

  -- 委托给 tool_cycle 执行工具
  tool_cycle._execute_tools(sid, tool_calls, false)
end

-- ========== 错误处理 ==========

--- 处理 AI 请求错误
--- @param loop table
--- @param err string|nil
function _handle_ai_error(loop, err)
  local retry_count = loop._ai_retry_count or 0
  local max_retries = 3

  if retry_count < max_retries then
    loop._ai_retry_count = retry_count + 1
    local delay = request_handler.get_retry_delay(retry_count) or (retry_count * 2000)

    logger.warn("[async_orchestrator] AI请求错误，%dms后重试 (%d/%d): %s",
      delay, loop._ai_retry_count, max_retries, tostring(err))

    if not shutdown_flag.is_set() then
      vim.api.nvim_exec_autocmds("User", {
        pattern = event_constants.GENERATION_RETRYING,
        data = {
          session_id = loop.session_id,
          retry_count = loop._ai_retry_count,
          reason = tostring(err),
        },
      })
    end

    vim.defer_fn(function()
      if not loop.stop_requested then
        _request_ai_generation(loop)
      end
    end, delay)
  else
    logger.error("[async_orchestrator] AI请求重试耗尽: session=%s, err=%s", loop.session_id, tostring(err))
    _finish_loop(loop, false, nil, err)
  end
end

-- ========== 循环结束 ==========

--- 结束循环
--- @param loop table
--- @param success boolean
--- @param result string|nil
--- @param err string|nil
function _finish_loop(loop, success, result, err)
  if loop._finished then return end
  loop._finished = true

  logger.info("[async_orchestrator] 循环结束: session=%s, success=%s, 总轮次=%d, 总tokens=%d",
    loop.session_id, tostring(success), loop.iteration,
    loop.accumulated_usage and loop.accumulated_usage.total_tokens or 0)

  -- 清理停止监听器
  _unregister_stop_listener(loop.session_id)

  -- 取消所有活跃线程
  for _, wid in ipairs(loop.worker_ids) do
    thread_pool.cancel_worker(wid)
  end

  -- 触发 GENERATION_COMPLETED 事件
  if not shutdown_flag.is_set() then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.GENERATION_COMPLETED,
      data = {
        session_id = loop.session_id,
        success = success,
        content = result,
        error = err,
        usage = loop.accumulated_usage,
      },
    })
  end

  -- 调用完成回调
  if loop.on_complete then
    local cb = loop.on_complete
    loop.on_complete = nil
    cb(success, result, err, loop.accumulated_usage)
  end

  -- 清理循环状态
  orch_state.active_loops[loop.session_id] = nil
end

-- ========== 停止控制 ==========

--- 注册停止监听器
function _register_stop_listener(session_id, loop)
  if orch_state.stop_listeners[session_id] then
    pcall(vim.api.nvim_del_autocmd, orch_state.stop_listeners[session_id])
  end

  orch_state.stop_listeners[session_id] = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.CANCEL_GENERATION,
    callback = function()
      if loop and not loop._finished then
        loop.stop_requested = true

        -- 取消所有线程
        for _, wid in ipairs(loop.worker_ids) do
          thread_pool.cancel_worker(wid)
        end

        -- 取消 HTTP 请求
        http_utils.cancel_all_requests()

        _finish_loop(loop, false, nil, "user_cancelled")
      end
    end,
  })
end

--- 取消注册停止监听器
function _unregister_stop_listener(session_id)
  local id = orch_state.stop_listeners[session_id]
  if id then
    pcall(vim.api.nvim_del_autocmd, id)
    orch_state.stop_listeners[session_id] = nil
  end
end

--- 请求停止指定会话的循环
function M.request_stop(session_id)
  local loop = orch_state.active_loops[session_id]
  if loop then
    loop.stop_requested = true
    for _, wid in ipairs(loop.worker_ids) do
      thread_pool.cancel_worker(wid)
    end
    http_utils.cancel_all_requests()
  end
end

-- ========== 状态查询 ==========

--- 获取指定会话的循环状态
function M.get_loop_state(session_id)
  return orch_state.active_loops[session_id]
end

--- 检查是否有活跃的循环
function M.has_active_loops()
  return next(orch_state.active_loops) ~= nil
end

--- 获取线程池状态
function M.get_thread_pool_status()
  return thread_pool.get_status()
end

--- 获取所有活跃循环 ID
function M.get_active_session_ids()
  local ids = {}
  for sid, _ in pairs(orch_state.active_loops) do
    table.insert(ids, sid)
  end
  return ids
end

-- ========== 清理 ==========

--- 清理所有循环
function M.shutdown()
  for session_id, loop in pairs(orch_state.active_loops) do
    loop.stop_requested = true
    _finish_loop(loop, false, nil, "shutdown")
  end
  orch_state.active_loops = {}
  orch_state.stop_listeners = {}
  -- 使用 thread_pool.shutdown() 来清理线程和临时目录
  thread_pool.shutdown()
end

--- 重置（测试用）
function M._test_reset()
  M.shutdown()
  thread_pool._test_reset()
end

return M
