-- 循环调用管理器（事件驱动架构）
-- 负责管理 AI 工具调用的循环执行
--
-- 阶段定义：
--   idle          - 空闲状态
--   waiting_tools - 等待工具执行完成
--   waiting_model - 等待模型生成完成
--   round_complete - 本轮所有操作已完成

local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")

-- ========== 状态 ==========

local state = {
  initialized = false,
  config = nil,
  session_manager = nil,
  tools = {},
  max_iterations = 20,
  tool_timeout_ms = 30000,
  sessions = {},
}

-- ========== 辅助函数 ==========

--- 创建一次性 TOOL_DISPLAY_CLOSED 监听器
--- 监听器触发后执行回调，5 秒超时后强制执行
--- 注意：此函数可能被 fast event 上下文调用，因此使用 vim.schedule 延迟 autocmd 创建
local function once_display_closed(session_id, callback)
  -- 使用 vim.schedule 确保不在 fast event 上下文中创建 autocmd
  vim.schedule(function()
    local autocmd_id = vim.api.nvim_create_autocmd("User", {
      pattern = event_constants.TOOL_DISPLAY_CLOSED,
      once = true,
      callback = function(args)
        local data = args.data or {}
        if data.session_id ~= session_id then return end
        logger.debug("[tool_orchestrator] 收到 TOOL_DISPLAY_CLOSED")
        callback()
      end,
    })
    vim.defer_fn(function()
      local ok, exists = pcall(vim.api.nvim_get_autocmds, { id = autocmd_id })
      if ok and exists and #exists > 0 then
        pcall(vim.api.nvim_del_autocmd, autocmd_id)
        logger.debug("[tool_orchestrator] 超时未收到 TOOL_DISPLAY_CLOSED，强制执行")
        callback()
      end
    end, 5000)
  end)
end

--- 触发 TOOL_LOOP_FINISHED 事件
--- 使用 pcall 保护，避免在 fast event 上下文中调用失败
local function fire_loop_finished(ss)
  local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event_constants.TOOL_LOOP_FINISHED,
    data = {
      generation_id = ss.generation_id,
      tool_results = {},
      iteration_count = ss.current_iteration,
      session_id = ss.session_id,
      window_id = ss.window_id,
    },
  })
  if not ok then
    -- fast event 上下文，用 vim.schedule 重试
    vim.schedule(function()
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_LOOP_FINISHED,
        data = {
          generation_id = ss.generation_id,
          tool_results = {},
          iteration_count = ss.current_iteration,
          session_id = ss.session_id,
          window_id = ss.window_id,
        },
      })
    end)
  end
end

--- 触发 TOOL_LOOP_STARTED 事件
--- 使用 pcall 保护，避免在 fast event 上下文中调用失败
local function fire_loop_started(ss, tool_calls)
  local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event_constants.TOOL_LOOP_STARTED,
    data = {
      generation_id = ss.generation_id,
      tool_calls = tool_calls or {},
      session_id = ss.session_id,
      window_id = ss.window_id,
      iteration = ss.current_iteration,
    },
  })
  if not ok then
    vim.schedule(function()
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_LOOP_STARTED,
        data = {
          generation_id = ss.generation_id,
          tool_calls = tool_calls or {},
          session_id = ss.session_id,
          window_id = ss.window_id,
          iteration = ss.current_iteration,
        },
      })
    end)
  end
end

--- 触发 TOOL_RESULT_RECEIVED 事件
--- 使用 pcall 保护，避免在 fast event 上下文中调用失败
local function fire_tool_result_received(ss, is_final_round)
  local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event_constants.TOOL_RESULT_RECEIVED,
    data = {
      generation_id = ss.generation_id,
      tool_results = {},
      session_id = ss.session_id,
      window_id = ss.window_id,
      messages = ss.messages,
      options = ss.options,
      model_index = ss.model_index,
      ai_preset = ss.ai_preset,
      is_final_round = is_final_round or false,
      accumulated_usage = ss.accumulated_usage,
      last_reasoning = ss.last_reasoning,
    },
  })
  if not ok then
    vim.schedule(function()
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_RESULT_RECEIVED,
        data = {
          generation_id = ss.generation_id,
          tool_results = {},
          session_id = ss.session_id,
          window_id = ss.window_id,
          messages = ss.messages,
          options = ss.options,
          model_index = ss.model_index,
          ai_preset = ss.ai_preset,
          is_final_round = is_final_round or false,
          accumulated_usage = ss.accumulated_usage,
          last_reasoning = ss.last_reasoning,
        },
      })
    end)
  end
end

-- ========== 会话状态 ==========

local function create_session_state(session_id, window_id)
  return {
    session_id = session_id,
    window_id = window_id,
    generation_id = nil,
    phase = "idle",
    _tools_complete_in_progress = false,
    _proceed_in_progress = false,
    _summary_in_progress = false,
    active_tool_calls = {},
    current_iteration = 0,
    messages = {},
    options = {},
    model_index = 1,
    ai_preset = {},
    accumulated_usage = {},
    last_reasoning = nil,
    stop_requested = false,
    on_complete = nil,
    autocmd_ids = {},
  }
end

-- ========== 初始化 ==========

function M.initialize(options)
  if state.initialized then return M end
  state.config = options.config or {}
  state.session_manager = options.session_manager
  state.tool_timeout_ms = (state.config.tool_timeout_ms or 30) * 1000
  state.max_iterations = state.config.max_tool_iterations or 20
  state.initialized = true
  return M
end

-- ========== 会话生命周期 ==========

function M.register_session(session_id, window_id)
  if state.sessions[session_id] then return end

  local ss = create_session_state(session_id, window_id)
  local ids = {}

  -- GENERATION_COMPLETED 监听器
  table.insert(ids, vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.GENERATION_COMPLETED,
    callback = function(args)
      local data = args.data
      if data.session_id ~= session_id then return end
      local s = state.sessions[session_id]
      if not s then return end

      -- 累积 usage
      if data.usage and next(data.usage) then
        local acc = s.accumulated_usage or {}
        acc.prompt_tokens = (acc.prompt_tokens or 0) + (data.usage.prompt_tokens or data.usage.input_tokens or 0)
        acc.completion_tokens = (acc.completion_tokens or 0) + (data.usage.completion_tokens or data.usage.output_tokens or 0)
        acc.total_tokens = (acc.total_tokens or 0) + (data.usage.total_tokens or 0)
        if data.usage.completion_tokens_details and type(data.usage.completion_tokens_details) == "table" then
          local rt = data.usage.completion_tokens_details.reasoning_tokens or 0
          if not acc.completion_tokens_details then acc.completion_tokens_details = {} end
          acc.completion_tokens_details.reasoning_tokens = (acc.completion_tokens_details.reasoning_tokens or 0) + rt
        end
        s.accumulated_usage = acc
      end
      if data.reasoning_text and data.reasoning_text ~= "" then
        s.last_reasoning = data.reasoning_text
      end
      M._check_round_complete(session_id)
    end,
  }))

  -- TOOL_LOOP_STOP_REQUESTED 监听器
  table.insert(ids, vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.TOOL_LOOP_STOP_REQUESTED,
    callback = function(args)
      local data = args.data or {}
      local target = data.session_id or session_id
      if target ~= session_id then return end
      local s = state.sessions[session_id]
      if not s then return end

      s.stop_requested = true

      -- 主动触发总结轮次：如果当前没有正在执行的工具，直接进入总结
      -- 注意：使用 vim.schedule 延迟执行，避免在 autocmd 回调中嵌套调用
      vim.schedule(function()
        local ss = state.sessions[session_id]
        if not ss or ss._summary_in_progress then return end

        -- 检查是否有活跃的工具调用
        local has_active = false
        for _ in pairs(ss.active_tool_calls or {}) do
          has_active = true
          break
        end

        if not has_active then
          -- 没有活跃工具，直接进入总结轮次
          M._request_summary_round(session_id)
        end
        -- 如果有活跃工具，_on_tools_complete 会在工具完成后触发总结
      end)
    end,
  }))

  ss.autocmd_ids = ids
  state.sessions[session_id] = ss
end

function M.unregister_session(session_id)
  local ss = state.sessions[session_id]
  if not ss then return end
  for _, id in ipairs(ss.autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state.sessions[session_id] = nil
end

-- ========== 循环调度 ==========

function M.start_async_loop(params)
  if not params then return end
  if not state.initialized then
    if params.on_complete then vim.schedule(function() params.on_complete(false, nil, "Tool orchestrator not initialized") end) end
    return
  end

  local session_id = params.session_id
  local window_id = params.window_id

  if not state.sessions[session_id] then
    M.register_session(session_id, window_id)
  end

  local ss = state.sessions[session_id]
  ss.generation_id = params.generation_id
  ss.current_iteration = 0
  ss.stop_requested = false
  ss.messages = params.messages or {}
  ss.options = params.options or {}
  ss.model_index = params.model_index or 1
  ss.ai_preset = params.ai_preset or {}
  ss.on_complete = params.on_complete
  ss.accumulated_usage = {}
  ss.last_reasoning = nil

  fire_loop_started(ss, params.tool_calls)

  ss.current_iteration = 1
  M._execute_tools(session_id, params.tool_calls or {})
end

-- ========== 工具执行 ==========

function M._execute_tools(session_id, tool_calls)
  local ss = state.sessions[session_id]
  if not ss then return end

  if #tool_calls == 0 then
    vim.schedule(function() M._request_generation(session_id) end)
    return
  end

  ss.phase = "waiting_tools"
  ss.active_tool_calls = {}

  for _, tc in ipairs(tool_calls) do
    M._execute_single_tool(session_id, tc)
  end
end

function M._execute_single_tool(session_id, tool_call)
  local ss = state.sessions[session_id]
  if not ss or not tool_call then return end

  local tool_func = tool_call["function"] or tool_call.func
  if not tool_func then return end

  local tool_name = tool_func.name
  local arguments = {}
  if tool_func.arguments then
    local ok, parsed = pcall(vim.json.decode, tool_func.arguments)
    if ok and parsed then arguments = parsed end
  end

  local tool_call_id = tool_call.id or ("call_" .. os.time() .. "_" .. math.random(10000, 99999))
  tool_call.id = tool_call_id
  ss.active_tool_calls[tool_call_id] = true

  local tool_registry = require("NeoAI.tools.tool_registry")
  pcall(tool_registry.initialize, {})

  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_EXECUTION_STARTED,
    data = {
      tool_name = tool_name, arguments = arguments,
      session_id = session_id, window_id = ss.window_id, generation_id = ss.generation_id,
    },
  })

  local tool_executor = require("NeoAI.tools.tool_executor")
  local function on_result(result, is_error)
    local s = state.sessions[session_id]
    if not s then return end

    if s.stop_requested then
      s.active_tool_calls[tool_call_id] = nil
      if vim.tbl_count(s.active_tool_calls) == 0 then M._on_tools_complete(session_id) end
      return
    end

    local result_str = is_error and ("[工具执行失败] " .. result) or result
    M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str)

    s.active_tool_calls[tool_call_id] = nil
    local remaining = vim.tbl_count(s.active_tool_calls)

    if remaining == 0 and s.phase ~= "round_complete" then
      M._on_tools_complete(session_id)
    end
  end

  tool_executor.execute_async(tool_name, arguments,
    function(result) on_result(result, false) end,
    function(err) on_result(err, true) end
  )
end

-- ========== 完成检查 ==========

function M._on_tools_complete(session_id)
  local ss = state.sessions[session_id]
  if not ss then return end
  if ss._tools_complete_in_progress then return end
  ss._tools_complete_in_progress = true

  if ss.stop_requested then
    ss.phase = "idle"
    ss._tools_complete_in_progress = false
    vim.schedule(function() M._request_summary_round(session_id) end)
    return
  end

  if ss.phase == "waiting_tools" then
    ss.phase = "waiting_model"
    ss._tools_complete_in_progress = false
    once_display_closed(session_id, function()
      vim.schedule(function() M._request_generation(session_id) end)
    end)
    fire_loop_finished(ss)
  elseif ss.phase == "round_complete" then
    ss._tools_complete_in_progress = false
    vim.schedule(function() M._proceed_to_next_round(session_id) end)
  else
    ss._tools_complete_in_progress = false
  end
end

function M._check_round_complete(session_id)
  local ss = state.sessions[session_id]
  if not ss then return end

  local active_count = vim.tbl_count(ss.active_tool_calls)

  if ss.stop_requested then
    ss.phase = "idle"
    vim.schedule(function() M._request_summary_round(session_id) end)
    return
  end

  if ss.phase == "waiting_model" then
    if active_count == 0 then
      if ss._proceed_in_progress then return end
      ss.phase = "round_complete"
      vim.schedule(function() M._proceed_to_next_round(session_id) end)
    else
      ss.phase = "round_complete"
    end
  elseif ss.phase == "waiting_tools" then
    ss.phase = "round_complete"
  end
end

function M._proceed_to_next_round(session_id)
  local ss = state.sessions[session_id]
  if not ss then return end
  if ss._proceed_in_progress then return end
  ss._proceed_in_progress = true

  ss.phase = "idle"
  ss.active_tool_calls = {}

  if ss.current_iteration >= state.max_iterations then
    ss._proceed_in_progress = false
    fire_loop_finished(ss)
    M._finish_loop(session_id, true, "已达到最大迭代次数")
    return
  end

  if ss.stop_requested then
    ss._proceed_in_progress = false
    M._request_summary_round(session_id)
    return
  end

  fire_loop_finished(ss)
  ss.current_iteration = ss.current_iteration + 1
  ss.phase = "waiting_model"
  ss._proceed_in_progress = false

  vim.schedule(function() M._request_generation(session_id) end)
end

-- ========== 请求 AI 生成 ==========

function M._request_generation(session_id)
  local ss = state.sessions[session_id]
  if not ss then return end
  fire_tool_result_received(ss, false)
end

function M._request_summary_round(session_id)
  local ss = state.sessions[session_id]
  if not ss then return end
  if ss._summary_in_progress then return end
  ss._summary_in_progress = true

  -- 复制 messages 并添加系统提示
  local messages = {}
  for _, msg in ipairs(ss.messages or {}) do
    table.insert(messages, msg)
  end
  table.insert(messages, {
    role = "system",
    content = "工具调用循环已结束。请根据所有工具执行的结果，对已完成的工作进行总结，然后返回最终结果给用户。总结应包括：完成了哪些任务、关键发现或结果、以及后续建议（如有）。",
  })

  local saved = {
    generation_id = ss.generation_id,
    window_id = ss.window_id,
    messages = messages,
    options = ss.options,
    model_index = ss.model_index,
    ai_preset = ss.ai_preset,
    accumulated_usage = ss.accumulated_usage,
    last_reasoning = ss.last_reasoning,
  }

  once_display_closed(session_id, function()
    local s = state.sessions[session_id]
    if not s then return end
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_RESULT_RECEIVED,
      data = {
        generation_id = saved.generation_id, tool_results = {},
        session_id = session_id, window_id = saved.window_id,
        messages = saved.messages, options = saved.options,
        model_index = saved.model_index, ai_preset = saved.ai_preset,
        is_final_round = true,
        accumulated_usage = saved.accumulated_usage, last_reasoning = saved.last_reasoning,
      },
    })
  end)

  fire_loop_finished(ss)
end

-- ========== 外部回调 ==========

function M.on_generation_complete(data)
  local session_id = data.session_id
  local ss = state.sessions[session_id]
  if not ss or ss.generation_id ~= data.generation_id then return end

  local tool_calls = data.tool_calls or {}
  local content = data.content or ""
  local is_final_round = data.is_final_round or false

  if ss.stop_requested then
    M._finish_loop(session_id, true, content)
    return
  end

  -- 将 AI 响应加入消息历史
  local assistant_msg = {
    role = "assistant", content = content, timestamp = os.time(), window_id = ss.window_id,
  }
  if data.reasoning and data.reasoning ~= "" then
    assistant_msg.reasoning_content = data.reasoning
    ss.last_reasoning = data.reasoning
  end
  if #tool_calls > 0 then
    assistant_msg.tool_calls = tool_calls
  end
  table.insert(ss.messages, assistant_msg)

  if is_final_round or #tool_calls == 0 or ss.current_iteration >= state.max_iterations then
    M._finish_loop(session_id, true, content)
    return
  end

  -- 关闭旧悬浮窗，打开新悬浮窗并执行工具
  ss.current_iteration = ss.current_iteration + 1

  once_display_closed(session_id, function()
    local s = state.sessions[session_id]
    if not s then return end
    fire_loop_started(s, tool_calls)
    M._execute_tools(session_id, tool_calls)
  end)

  fire_loop_finished(ss)
end

function M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result)
  local ss = state.sessions[session_id]
  if not ss then return end

  local safe_id = tool_call_id or ("call_" .. os.time() .. "_" .. math.random(10000, 99999))
  local result_str = type(result) == "string" and result or (result ~= nil and pcall(vim.json.encode, result) and vim.json.encode(result) or tostring(result)) or ""

  local tool_msg = {
    role = "tool", tool_call_id = safe_id, content = result_str,
    timestamp = os.time(), window_id = ss.window_id,
  }
  if tool_name then tool_msg.name = tool_name end
  table.insert(ss.messages, tool_msg)
end

-- ========== 结束循环 ==========

function M._finish_loop(session_id, success, result)
  local ss = state.sessions[session_id]
  if not ss then return end
  if ss.on_complete == nil then return end

  local on_complete = ss.on_complete
  local usage = ss.accumulated_usage or {}
  local saved_generation_id = ss.generation_id
  local saved_window_id = ss.window_id
  local saved_reasoning = ss.last_reasoning or ""

  fire_loop_finished(ss)

  ss.phase = "idle"
  ss.active_tool_calls = {}
  ss.current_iteration = 0
  ss.generation_id = nil
  ss.on_complete = nil

  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.GENERATION_COMPLETED,
      data = {
        generation_id = saved_generation_id, response = result or "",
        reasoning_text = saved_reasoning, usage = usage,
        session_id = session_id, window_id = saved_window_id, duration = 0,
      },
    })
    on_complete(success, result, usage)
  end)
end

-- ========== 停止控制 ==========

function M.request_stop(session_id)
  if session_id then
    local ss = state.sessions[session_id]
    if ss then
      ss.stop_requested = true
      if next(ss.active_tool_calls) ~= nil then
        ss.active_tool_calls = {}
        vim.schedule(function() M._on_tools_complete(session_id) end)
      end
      vim.api.nvim_exec_autocmds("User", {
        pattern = event_constants.TOOL_LOOP_STOP_REQUESTED,
        data = { session_id = session_id },
      })
    end
  else
    for sid, _ in pairs(state.sessions) do
      M.request_stop(sid)
    end
  end
end

function M.is_stop_requested(session_id)
  if session_id then
    local ss = state.sessions[session_id]
    return ss and ss.stop_requested or false
  end
  return false
end

function M.reset_stop_requested(session_id)
  if session_id then
    local ss = state.sessions[session_id]
    if ss then ss.stop_requested = false end
  else
    for _, ss in pairs(state.sessions) do
      ss.stop_requested = false
    end
  end
end

-- ========== 工具管理 ==========

function M.set_tools(tools)
  state.tools = tools or {}
end

function M.get_tools()
  return state.tools
end

-- ========== 状态查询 ==========

function M.get_current_iteration(session_id)
  if session_id then
    local ss = state.sessions[session_id]
    return ss and ss.current_iteration or 0
  end
  return 0
end

function M.reset_iteration(session_id)
  if session_id then
    local ss = state.sessions[session_id]
    if ss then ss.current_iteration = 0 end
  else
    for _, ss in pairs(state.sessions) do
      ss.current_iteration = 0
    end
  end
end

function M.is_executing(session_id)
  if session_id then
    local ss = state.sessions[session_id]
    if not ss then return false end
    return ss.phase == "waiting_tools" or ss.phase == "waiting_model"
  end
  for _, ss in pairs(state.sessions) do
    if ss.phase == "waiting_tools" or ss.phase == "waiting_model" then
      return true
    end
  end
  return false
end

-- ========== 关闭清理 ==========

function M.shutdown()
  for session_id, _ in pairs(state.sessions) do
    M.unregister_session(session_id)
  end
  state.sessions = {}
  state.tools = {}
  state.initialized = false
end

return M
