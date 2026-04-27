-- 循环调用管理器（事件驱动架构）
-- 负责管理 AI 工具调用的循环执行
--
-- 设计原则：
-- 1. 事件驱动：所有阶段通过 User autocommand 事件触发，解耦各模块
-- 2. 按会话为单位加载：每个会话窗口独立维护循环状态
-- 3. 异步执行：所有工具通过 async_worker 异步执行
-- 4. 阶段状态机：使用 phase 字段替代 model_completed + tools_completed 两个布尔值
--    避免竞态条件导致的循环卡死
--
-- 阶段定义：
--   idle          - 空闲状态，未开始任何操作
--   waiting_tools - 等待工具执行完成（工具正在执行中）
--   waiting_model - 等待模型生成完成（AI 正在生成中）
--   round_complete - 本轮所有操作已完成，准备进入下一轮
--
-- 事件监听器：
--   1. 会话完成监听器（GENERATION_COMPLETED）：
--      - 累积 usage 和 reasoning
--      - 调用 _check_round_complete 检查是否可进入下一轮
--   2. stop_tool_loop 监听器（TOOL_LOOP_STOP_REQUESTED）：
--      - 设置跳出循环变量 = true
--      - 若跳出循环变量为 true，下一轮会话为不调用工具的总结会话

local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events.event_constants")
local async_worker = require("NeoAI.utils.async_worker")

-- ========== 状态 ==========

local state = {
  initialized = false,
  config = nil,
  session_manager = nil,
  tools = {},
  max_iterations = 20,
  tool_timeout_ms = 30000,

  -- 按会话窗口 ID 存储的循环状态
  -- sessions[session_id] = { ... }
  sessions = {},
}

-- ========== 会话状态结构 ==========

--- 创建新的会话循环状态
--- @param session_id string
--- @param window_id number
--- @return table
local function create_session_state(session_id, window_id)
  return {
    session_id = session_id,
    window_id = window_id,
    generation_id = nil,

  -- 阶段状态机
    -- phase: "idle" | "waiting_tools" | "waiting_model" | "round_complete"
    phase = "idle",
    -- 防重复调用标记（_on_tools_complete 防重入）
    _tools_complete_in_progress = false,

    -- 工具调用注册表 { [tool_call_id] = true }
    active_tool_calls = {},

    -- 当前轮次数据
    current_iteration = 0,
    messages = {},
    options = {},
    model_index = 1,
    ai_preset = {},
    accumulated_usage = {},
    last_reasoning = nil,

    -- 停止控制
    stop_requested = false,

    -- 完成回调
    on_complete = nil,

    -- 自动命令 ID 列表（按会话注册）
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

-- ========== 会话生命周期管理 ==========

--- 为指定会话注册事件监听器
--- @param session_id string
--- @param window_id number
function M.register_session(session_id, window_id)
  if state.sessions[session_id] then
    logger.debug("[tool_orchestrator] 会话 " .. session_id .. " 已注册，跳过")
    return
  end

  local ss = create_session_state(session_id, window_id)
  local ids = {}

  -- 1. 会话完成监听器（GENERATION_COMPLETED）
  -- 注意：工具完成不再通过事件监听，而是在 async_worker 回调中直接处理
  local id4 = vim.api.nvim_create_autocmd("User", {
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

      -- 保存 reasoning
      if data.reasoning_text and data.reasoning_text ~= "" then
        s.last_reasoning = data.reasoning_text
      end

      M._check_round_complete(session_id)
    end,
  })
  table.insert(ids, id4)

  -- 2. stop_tool_loop 监听器
  local id5 = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.TOOL_LOOP_STOP_REQUESTED,
    callback = function(args)
      local data = args.data or {}
      local target_session_id = data.session_id or session_id
      if target_session_id ~= session_id then return end
      local s = state.sessions[session_id]
      if not s then return end

      s.stop_requested = true
      logger.debug("[tool_orchestrator] 会话 " .. session_id .. " 请求停止工具循环")
    end,
  })
  table.insert(ids, id5)

  ss.autocmd_ids = ids
  state.sessions[session_id] = ss
  logger.debug("[tool_orchestrator] 已注册会话 " .. session_id)
end

--- 注销指定会话的事件监听器
--- @param session_id string
function M.unregister_session(session_id)
  local ss = state.sessions[session_id]
  if not ss then return end

  -- 删除自动命令
  for _, id in ipairs(ss.autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end

  state.sessions[session_id] = nil
  logger.debug("[tool_orchestrator] 已注销会话 " .. session_id)
end

-- ========== 循环调度 ==========

--- 启动异步工具循环
function M.start_async_loop(params)
  if not params then
    logger.error("[tool_orchestrator] start_async_loop: params 为 nil")
    return
  end

  if not state.initialized then
    if params.on_complete then
      vim.schedule(function() params.on_complete(false, nil, "Tool orchestrator not initialized") end)
    end
    return
  end

  local session_id = params.session_id
  local window_id = params.window_id

  -- 确保会话已注册
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

  logger.debug("[tool_orchestrator] start_async_loop: 会话=" .. session_id .. ", generation_id=" .. tostring(params.generation_id) .. ", tool_calls数量=" .. #(params.tool_calls or {}))

  -- 触发 TOOL_LOOP_STARTED 事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_STARTED,
    data = {
      generation_id = params.generation_id,
      tool_calls = params.tool_calls or {},
      session_id = session_id,
      window_id = window_id,
    },
  })

  -- 开始第一轮：执行工具
  ss.current_iteration = 1
  logger.debug("[tool_orchestrator] start_async_loop: 开始第 1 轮，调用 _execute_tools")
  M._execute_tools(session_id, params.tool_calls or {})
end

--- 执行工具（异步）
function M._execute_tools(session_id, tool_calls)
  local ss = state.sessions[session_id]
  if not ss then
    logger.debug("[tool_orchestrator] _execute_tools: 会话 " .. session_id .. " 不存在")
    return
  end

  logger.debug("[tool_orchestrator] _execute_tools: 会话=" .. session_id .. ", tool_calls数量=" .. #tool_calls .. ", 当前阶段=" .. ss.phase)

  if #tool_calls == 0 then
    -- 没有工具调用，直接请求 AI 生成
    logger.debug("[tool_orchestrator] _execute_tools: 无工具调用，直接请求 AI 生成")
    vim.schedule(function()
      M._request_generation(session_id)
    end)
    return
  end

  -- 设置阶段为等待工具完成
  ss.phase = "waiting_tools"
  ss.active_tool_calls = {}
  logger.debug("[tool_orchestrator] _execute_tools: 阶段设为 waiting_tools，注册 " .. #tool_calls .. " 个工具")

  -- 为每个工具调用注册并异步执行
  for _, tc in ipairs(tool_calls) do
    M._execute_single_tool(session_id, tc)
  end
end

--- 执行单个工具
function M._execute_single_tool(session_id, tool_call)
  local ss = state.sessions[session_id]
  if not ss then
    logger.debug("[tool_orchestrator] _execute_single_tool: 会话 " .. session_id .. " 不存在")
    return
  end

  -- 先检查 tool_call 是否为 nil，再访问其字段
  if not tool_call then
    logger.debug("[tool_orchestrator] _execute_single_tool: tool_call 为 nil")
    return
  end
  local tool_func = tool_call["function"] or tool_call.func
  if not tool_func then
    logger.debug("[tool_orchestrator] _execute_single_tool: tool_func 为 nil")
    return
  end

  local tool_name = tool_func.name
  local arguments_str = tool_func.arguments
  local arguments = {}
  if arguments_str then
    local ok, parsed = pcall(vim.json.decode, arguments_str)
    if ok and parsed then arguments = parsed end
  end

  local tool_call_id = tool_call.id
  if not tool_call_id or tool_call_id == "" then
    tool_call_id = "call_" .. os.time() .. "_" .. math.random(10000, 99999)
    tool_call.id = tool_call_id
  end

  logger.debug("[tool_orchestrator] _execute_single_tool: 工具=" .. tool_name .. ", id=" .. tool_call_id .. ", 参数=" .. tostring(arguments_str))

  -- 注册到活动工具调用表
  ss.active_tool_calls[tool_call_id] = true
  logger.debug("[tool_orchestrator] _execute_single_tool: 已注册到 active_tool_calls, 当前活跃工具数=" .. vim.tbl_count(ss.active_tool_calls))

  -- 确保 tool_registry 已初始化
  local tool_registry = require("NeoAI.tools.tool_registry")
  pcall(tool_registry.initialize, {})
  local tool = tool_registry.get(tool_name)
  logger.debug("[tool_orchestrator] _execute_single_tool: tool_registry.get(" .. tool_name .. ") = " .. tostring(tool and "找到" or "未找到"))

  -- 触发 TOOL_EXECUTION_STARTED 事件（通知 UI 更新工具状态）
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_EXECUTION_STARTED,
    data = {
      tool_name = tool_name,
      arguments = arguments,
      session_id = session_id,
      window_id = ss.window_id,
      generation_id = ss.generation_id,
    },
  })

  -- 使用 async_worker 异步执行工具
  -- 回调通过 vim.schedule 确保在主事件循环中执行
  async_worker.submit_task(
    "tool_" .. tool_name,
    function()
      if not tool or not tool.func then
        logger.debug("[tool_orchestrator] async_worker 任务: 工具 " .. tool_name .. " 不存在")
        return setmetatable({ _error = true, message = "工具不存在: " .. tool_name }, {
          __tostring = function() return "工具不存在: " .. tool_name end,
        })
      end
      logger.debug("[tool_orchestrator] async_worker 任务: 开始执行工具 " .. tool_name)
      local ok, r = pcall(tool.func, arguments)
      if ok then
        logger.debug("[tool_orchestrator] async_worker 任务: 工具 " .. tool_name .. " 执行成功")
        return r
      end
      logger.debug("[tool_orchestrator] async_worker 任务: 工具 " .. tool_name .. " 执行失败: " .. tostring(r))
      return setmetatable({ _error = true, message = tostring(r) }, {
        __tostring = function() return tostring(r) end,
      })
    end,
    function(success, result, error_msg, worker_info)
      local s = state.sessions[session_id]
      if not s then
        logger.debug("[tool_orchestrator] async_worker 回调: 会话 " .. session_id .. " 已不存在")
        return
      end

      logger.debug("[tool_orchestrator] async_worker 回调: 工具=" .. tool_name .. ", id=" .. tool_call_id .. ", success=" .. tostring(success) .. ", 当前阶段=" .. s.phase)

      -- 触发 TOOL_EXECUTION_COMPLETED 事件（通知 UI 更新工具状态）
      vim.api.nvim_exec_autocmds("User", {
        pattern = event_constants.TOOL_EXECUTION_COMPLETED,
        data = {
          tool_name = tool_name,
          arguments = arguments,
          result = success and result or ("[工具执行失败] " .. tostring(error_msg or result)),
          duration = 0,
          session_id = session_id,
          window_id = s.window_id,
          generation_id = s.generation_id,
        },
      })

      -- 将工具执行结果加入消息历史（确保 API 消息历史完整）
      if success then
        M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result)
      else
        M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, "[工具执行失败] " .. tostring(error_msg or result))
      end

      -- 直接从 active_tool_calls 移除本工具调用
      s.active_tool_calls[tool_call_id] = nil
      local remaining = vim.tbl_count(s.active_tool_calls)
      logger.debug("[tool_orchestrator] async_worker 回调: 已移除 " .. tool_call_id .. ", 剩余活跃工具数=" .. remaining)

      -- 检查工具调用表是否为空，且不在 round_complete 阶段（避免竞态）
      if remaining == 0 and s.phase ~= "round_complete" then
        logger.debug("[tool_orchestrator] async_worker 回调: 所有工具已完成，调用 _on_tools_complete")
        M._on_tools_complete(session_id)
      else
        logger.debug("[tool_orchestrator] async_worker 回调: 不触发 _on_tools_complete, remaining=" .. remaining .. ", phase=" .. s.phase)
      end
    end,
    {
      timeout_ms = state.tool_timeout_ms,
      auto_serialize = true,
    }
  )
  logger.debug("[tool_orchestrator] _execute_single_tool: async_worker.submit_task 已提交")
end

-- ========== 完成检查 ==========

--- 工具全部执行完成回调
--- 使用阶段状态机判断下一步操作
function M._on_tools_complete(session_id)
  local ss = state.sessions[session_id]
  if not ss then
    logger.debug("[tool_orchestrator] _on_tools_complete: 会话 " .. session_id .. " 不存在")
    return
  end

  logger.debug("[tool_orchestrator] _on_tools_complete: 会话=" .. session_id .. ", 当前阶段=" .. ss.phase .. ", 迭代=" .. ss.current_iteration)

  -- 防重复调用保护
  if ss._tools_complete_in_progress then
    logger.debug("[tool_orchestrator] _on_tools_complete: 防重入保护触发，跳过")
    return
  end
  ss._tools_complete_in_progress = true

  local phase = ss.phase

  -- 检查是否请求停止（优先处理）
  if ss.stop_requested then
    logger.debug("[tool_orchestrator] _on_tools_complete: 已请求停止，触发总结会话")
    ss.phase = "idle"
    ss._tools_complete_in_progress = false
    vim.schedule(function()
      M._request_summary_round(session_id)
    end)
    return
  end

  if phase == "waiting_tools" then
    -- 工具执行完成，但模型尚未生成（第一轮：先执行工具，再请求 AI 生成）
    -- 先触发 TOOL_LOOP_FINISHED 关闭悬浮窗，等待关闭完成后再请求 AI 生成
    -- 避免本轮工具结果还没写入缓冲区就提前开始下一轮
    ss.phase = "waiting_model"
    ss._tools_complete_in_progress = false
    logger.debug("[tool_orchestrator] _on_tools_complete: waiting_tools -> waiting_model, 先关闭悬浮窗再请求 AI 生成")
    -- 注册一次性 TOOL_DISPLAY_CLOSED 监听器
    local autocmd_id = vim.api.nvim_create_autocmd("User", {
      pattern = event_constants.TOOL_DISPLAY_CLOSED,
      once = true,
      callback = function(args)
        local data = args.data or {}
        if data.session_id ~= session_id then return end
        logger.debug("[tool_orchestrator] _on_tools_complete: 收到 TOOL_DISPLAY_CLOSED，请求 AI 生成")
        vim.schedule(function()
          M._request_generation(session_id)
        end)
      end,
    })
    -- 触发 TOOL_LOOP_FINISHED 事件，让 UI 关闭悬浮窗并触发 TOOL_DISPLAY_CLOSED
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_LOOP_FINISHED,
      data = {
        generation_id = ss.generation_id,
        tool_results = {},
        iteration_count = ss.current_iteration,
        session_id = session_id,
        window_id = ss.window_id,
      },
    })
    -- 安全机制：5 秒超时后仍然请求 AI 生成
    vim.defer_fn(function()
      local ok, exists = pcall(vim.api.nvim_get_autocmds, { id = autocmd_id })
      if ok and exists and #exists > 0 then
        pcall(vim.api.nvim_del_autocmd, autocmd_id)
        logger.debug("[tool_orchestrator] _on_tools_complete: 超时未收到 TOOL_DISPLAY_CLOSED，强制请求 AI 生成")
        vim.schedule(function()
          M._request_generation(session_id)
        end)
      end
    end, 5000)
  elseif phase == "round_complete" then
    -- 模型已完成，工具也完成，进入下一轮
    ss._tools_complete_in_progress = false
    logger.debug("[tool_orchestrator] _on_tools_complete: round_complete, 进入下一轮")
    vim.schedule(function()
      M._proceed_to_next_round(session_id)
    end)
  else
    ss._tools_complete_in_progress = false
    logger.debug("[tool_orchestrator] _on_tools_complete: 阶段=" .. phase .. " 不匹配，忽略")
  end
end

--- 检查本轮模型与工具是否都已完成
--- 由 GENERATION_COMPLETED 事件监听器调用
function M._check_round_complete(session_id)
  local ss = state.sessions[session_id]
  if not ss then
    logger.debug("[tool_orchestrator] _check_round_complete: 会话 " .. session_id .. " 不存在")
    return
  end

  local active_count = vim.tbl_count(ss.active_tool_calls)
  logger.debug("[tool_orchestrator] _check_round_complete: 会话=" .. session_id .. ", 阶段=" .. ss.phase .. ", 活跃工具数=" .. active_count)

  -- 如果已请求停止，直接结束循环
  if ss.stop_requested then
    logger.debug("[tool_orchestrator] _check_round_complete: 已请求停止，触发总结会话")
    ss.phase = "idle"
    vim.schedule(function()
      M._request_summary_round(session_id)
    end)
    return
  end

  if ss.phase == "waiting_model" then
    -- 模型已完成，检查工具是否也完成
    if active_count == 0 then
      -- 工具也完成了，进入下一轮
      -- 注意：_on_tools_complete 也可能同时触发 _proceed_to_next_round
      -- 使用防重入标记 _proceed_in_progress 防止重复进入
      if ss._proceed_in_progress then
        logger.debug("[tool_orchestrator] _check_round_complete: _proceed_in_progress 已设置，跳过")
        return
      end
      ss.phase = "round_complete"
      logger.debug("[tool_orchestrator] _check_round_complete: waiting_model -> round_complete, 工具已完成，进入下一轮")
      vim.schedule(function()
        M._proceed_to_next_round(session_id)
      end)
    else
      -- 工具尚未完成，标记本轮完成，等待工具完成回调触发 _on_tools_complete
      ss.phase = "round_complete"
      logger.debug("[tool_orchestrator] _check_round_complete: waiting_model -> round_complete, 等待 " .. active_count .. " 个工具完成")
    end
  elseif ss.phase == "waiting_tools" then
    -- 工具先完成，模型后完成的情况
    -- 标记为 round_complete，等待 _on_tools_complete 触发下一轮
    ss.phase = "round_complete"
    logger.debug("[tool_orchestrator] _check_round_complete: waiting_tools -> round_complete, 等待工具回调触发下一轮")
  else
    logger.debug("[tool_orchestrator] _check_round_complete: 阶段=" .. ss.phase .. " 不匹配，忽略")
  end
end

--- 进入下一轮
function M._proceed_to_next_round(session_id)
  local ss = state.sessions[session_id]
  if not ss then
    logger.debug("[tool_orchestrator] _proceed_to_next_round: 会话 " .. session_id .. " 不存在")
    return
  end

  -- 防重入保护：如果已经在 round_complete 阶段，说明 _proceed_to_next_round 正在执行中
  if ss._proceed_in_progress then
    logger.debug("[tool_orchestrator] _proceed_to_next_round: 防重入保护触发，跳过")
    return
  end
  ss._proceed_in_progress = true

  logger.debug("[tool_orchestrator] _proceed_to_next_round: 会话=" .. session_id .. ", 当前迭代=" .. ss.current_iteration .. ", max=" .. state.max_iterations)

  -- 重置阶段为 idle
  ss.phase = "idle"
  ss.active_tool_calls = {}

  -- 检查是否达到最大迭代次数
  if ss.current_iteration >= state.max_iterations then
    ss._proceed_in_progress = false
    logger.debug("[tool_orchestrator] _proceed_to_next_round: 达到最大迭代次数，结束循环")
    -- 触发 TOOL_LOOP_FINISHED 事件，让 UI 关闭工具调用悬浮窗
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_LOOP_FINISHED,
      data = {
        generation_id = ss.generation_id,
        tool_results = {},
        iteration_count = ss.current_iteration,
        session_id = session_id,
        window_id = ss.window_id,
      },
    })
    M._finish_loop(session_id, true, "已达到最大迭代次数")
    return
  end

  -- 检查是否请求停止
  if ss.stop_requested then
    ss._proceed_in_progress = false
    logger.debug("[tool_orchestrator] _proceed_to_next_round: 请求停止，触发总结会话")
    M._request_summary_round(session_id)
    return
  end

  -- 触发 TOOL_LOOP_FINISHED 事件（本轮工具循环结束）
  -- chat_window 的监听器会同步关闭悬浮窗并触发 TOOL_DISPLAY_CLOSED
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_FINISHED,
    data = {
      generation_id = ss.generation_id,
      tool_results = {},
      iteration_count = ss.current_iteration,
      session_id = session_id,
      window_id = ss.window_id,
    },
  })

  -- 递增迭代计数器
  ss.current_iteration = ss.current_iteration + 1
  ss.phase = "waiting_model"
  ss._proceed_in_progress = false
  logger.debug("[tool_orchestrator] _proceed_to_next_round: 进入第 " .. ss.current_iteration .. " 轮，阶段设为 waiting_model")

  -- 使用 vim.schedule 延迟一帧请求 AI 生成，确保 TOOL_LOOP_FINISHED 事件
  -- 的监听器（关闭悬浮窗、触发 TOOL_DISPLAY_CLOSED）已完全处理完毕
  -- 避免悬浮窗关闭和新一轮 TOOL_LOOP_STARTED 之间的竞态条件
  vim.schedule(function()
    M._request_generation(session_id)
  end)
end

--- 请求 AI 生成（下一轮）
function M._request_generation(session_id)
  local ss = state.sessions[session_id]
  if not ss then
    logger.debug("[tool_orchestrator] _request_generation: 会话 " .. session_id .. " 不存在")
    return
  end

  logger.debug("[tool_orchestrator] _request_generation: 触发 TOOL_RESULT_RECEIVED 事件, 会话=" .. session_id .. ", generation_id=" .. tostring(ss.generation_id))

  -- 触发 TOOL_RESULT_RECEIVED 事件，由 ai_engine 监听并发起 AI 请求
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_RESULT_RECEIVED,
    data = {
      generation_id = ss.generation_id,
      tool_results = {},
      session_id = session_id,
      window_id = ss.window_id,
      messages = ss.messages,
      options = ss.options,
      model_index = ss.model_index,
      ai_preset = ss.ai_preset,
      is_final_round = false,
      accumulated_usage = ss.accumulated_usage,
      last_reasoning = ss.last_reasoning,
    },
  })
  logger.debug("[tool_orchestrator] _request_generation: TOOL_RESULT_RECEIVED 事件已触发")
end

--- 请求总结会话（停止时调用，不包含工具）
function M._request_summary_round(session_id)
  local ss = state.sessions[session_id]
  if not ss then return end

  -- 保存需要在回调中使用的数据（防止 ss 被清理后丢失）
  local saved_data = {
    generation_id = ss.generation_id,
    iteration_count = ss.current_iteration,
    window_id = ss.window_id,
    messages = nil, -- 下面单独处理
    options = ss.options,
    model_index = ss.model_index,
    ai_preset = ss.ai_preset,
    accumulated_usage = ss.accumulated_usage,
    last_reasoning = ss.last_reasoning,
  }

  -- 复制 messages 并添加系统提示
  local ok_copy, messages = pcall(vim.deepcopy, ss.messages)
  if not ok_copy or not messages then
    messages = {}
    for _, msg in ipairs(ss.messages or {}) do
      table.insert(messages, msg)
    end
  end
  table.insert(messages, {
    role = "system",
    content = "工具调用循环已结束。请根据所有工具执行的结果，对已完成的工作进行总结，然后返回最终结果给用户。总结应包括：完成了哪些任务、关键发现或结果、以及后续建议（如有）。",
  })
  saved_data.messages = messages

  -- 先注册一次性 TOOL_DISPLAY_CLOSED 监听器，再触发 TOOL_LOOP_FINISHED
  -- 顺序很重要：必须先注册监听器，因为 TOOL_LOOP_FINISHED 会同步触发
  -- chat_window 的监听器关闭悬浮窗并触发 TOOL_DISPLAY_CLOSED，
  -- 如果监听器注册在 TOOL_LOOP_FINISHED 之后，就会错过该事件
  local autocmd_id = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.TOOL_DISPLAY_CLOSED,
    once = true, -- 一次性监听器，触发后自动删除
    callback = function(args)
      local data = args.data or {}
      -- 验证 session_id 匹配
      if data.session_id ~= session_id then
        return
      end

      logger.debug("[tool_orchestrator] _request_summary_round: 收到 TOOL_DISPLAY_CLOSED，触发总结会话")

      -- 再次检查会话是否还存在
      local s = state.sessions[session_id]
      if not s then
        logger.debug("[tool_orchestrator] _request_summary_round: 会话 " .. session_id .. " 已不存在，跳过")
        return
      end

      -- 触发总结会话（is_final_round = true，不包含工具）
      vim.api.nvim_exec_autocmds("User", {
        pattern = event_constants.TOOL_RESULT_RECEIVED,
        data = {
          generation_id = saved_data.generation_id,
          tool_results = {},
          session_id = session_id,
          window_id = saved_data.window_id,
          messages = saved_data.messages,
          options = saved_data.options,
          model_index = saved_data.model_index,
          ai_preset = saved_data.ai_preset,
          is_final_round = true,
          accumulated_usage = saved_data.accumulated_usage,
          last_reasoning = saved_data.last_reasoning,
        },
      })
    end,
  })

  -- 触发 TOOL_LOOP_FINISHED 事件，让 UI 关闭工具调用悬浮窗
  -- chat_window 的监听器会同步关闭悬浮窗并触发 TOOL_DISPLAY_CLOSED
  -- 由于上面已注册一次性监听器，能正确收到该事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_FINISHED,
    data = {
      generation_id = saved_data.generation_id,
      tool_results = {},
      iteration_count = saved_data.iteration_count,
      session_id = session_id,
      window_id = saved_data.window_id,
    },
  })

  -- 安全机制：如果 5 秒内未收到 TOOL_DISPLAY_CLOSED，仍然触发总结会话
  -- 防止悬浮窗关闭事件丢失导致循环卡死
  vim.defer_fn(function()
    -- 检查监听器是否已被触发（once=true 的 autocmd 触发后自动删除）
    local ok, exists = pcall(vim.api.nvim_get_autocmds, {
      id = autocmd_id,
    })
    if ok and exists and #exists > 0 then
      -- 监听器仍然存在，说明 TOOL_DISPLAY_CLOSED 未被触发
      logger.debug("[tool_orchestrator] _request_summary_round: 超时未收到 TOOL_DISPLAY_CLOSED，强制触发总结会话")
      -- 手动删除监听器
      pcall(vim.api.nvim_del_autocmd, autocmd_id)

      local s = state.sessions[session_id]
      if not s then return end

      vim.api.nvim_exec_autocmds("User", {
        pattern = event_constants.TOOL_RESULT_RECEIVED,
        data = {
          generation_id = saved_data.generation_id,
          tool_results = {},
          session_id = session_id,
          window_id = saved_data.window_id,
          messages = saved_data.messages,
          options = saved_data.options,
          model_index = saved_data.model_index,
          ai_preset = saved_data.ai_preset,
          is_final_round = true,
          accumulated_usage = saved_data.accumulated_usage,
          last_reasoning = saved_data.last_reasoning,
        },
      })
    end
  end, 5000) -- 5 秒超时
end

-- ========== 外部回调（由 ai_engine 调用） ==========

--- AI 生成完成回调（由 ai_engine 在流式/非流式结束时调用）
--- 将 AI 响应加入消息历史，检查是否有工具调用，有则执行工具
function M.on_generation_complete(data)
  local session_id = data.session_id
  local ss = state.sessions[session_id]
  if not ss then
    logger.debug("[tool_orchestrator] on_generation_complete: 会话 " .. session_id .. " 不存在")
    return
  end
  if ss.generation_id ~= data.generation_id then
    logger.debug("[tool_orchestrator] on_generation_complete: generation_id 不匹配, 期望=" .. tostring(ss.generation_id) .. ", 实际=" .. tostring(data.generation_id))
    return
  end

  local tool_calls = data.tool_calls or {}
  local content = data.content or ""
  local reasoning = data.reasoning
  local is_final_round = data.is_final_round or false

  logger.debug("[tool_orchestrator] on_generation_complete: 会话=" .. session_id .. ", 工具调用数=" .. #tool_calls .. ", 迭代=" .. ss.current_iteration .. ", 阶段=" .. ss.phase .. ", is_final_round=" .. tostring(is_final_round))

  -- 检查是否已请求停止（防止 stop_tool_loop 被 AI 重复调用导致卡死）
  if ss.stop_requested then
    logger.debug("[tool_orchestrator] on_generation_complete: 已请求停止，直接结束循环")
    M._finish_loop(session_id, true, content)
    return
  end

  -- 将 AI 响应加入消息历史
  -- 注意：content 和 tool_calls 合并到同一条 assistant 消息中
  -- 不要分成两条消息，否则 AI 会看到两条连续的 assistant 消息
  local assistant_msg = {
    role = "assistant",
    content = content,
    timestamp = os.time(),
    window_id = ss.window_id,
  }
  if reasoning and reasoning ~= "" then
    assistant_msg.reasoning_content = reasoning
    -- 同时更新 last_reasoning，确保 _finish_loop 能获取到当前轮的 reasoning
    ss.last_reasoning = reasoning
  end
  if #tool_calls > 0 then
    assistant_msg.tool_calls = tool_calls
  end
  table.insert(ss.messages, assistant_msg)

  -- 如果是最后一轮（总结轮），结束循环
  if is_final_round then
    M._finish_loop(session_id, true, content)
    return
  end

  -- 没有工具调用，结束循环
  if #tool_calls == 0 then
    M._finish_loop(session_id, true, content)
    return
  end

  -- 检查是否达到最大迭代次数
  if ss.current_iteration >= state.max_iterations then
    M._finish_loop(session_id, true, content)
    return
  end

  -- 先触发 TOOL_LOOP_FINISHED 关闭上一轮悬浮窗，等待关闭完成后再打开新悬浮窗
  -- 注册一次性 TOOL_DISPLAY_CLOSED 监听器
  local autocmd_id = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.TOOL_DISPLAY_CLOSED,
    once = true,
    callback = function(args)
      local data = args.data or {}
      if data.session_id ~= session_id then return end
      logger.debug("[tool_orchestrator] on_generation_complete: 收到 TOOL_DISPLAY_CLOSED，打开新悬浮窗并执行工具")
      -- 触发 TOOL_LOOP_STARTED 事件（打开新悬浮窗）
      vim.api.nvim_exec_autocmds("User", {
        pattern = event_constants.TOOL_LOOP_STARTED,
        data = {
          generation_id = ss.generation_id,
          tool_calls = tool_calls,
          session_id = session_id,
          window_id = ss.window_id,
          iteration = ss.current_iteration,
        },
      })
      -- 异步执行工具
      M._execute_tools(session_id, tool_calls)
    end,
  })

  -- 触发 TOOL_LOOP_FINISHED 事件，关闭上一轮悬浮窗
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_FINISHED,
    data = {
      generation_id = ss.generation_id,
      tool_results = {},
      iteration_count = ss.current_iteration,
      session_id = session_id,
      window_id = ss.window_id,
    },
  })

  -- 递增迭代计数器
  ss.current_iteration = ss.current_iteration + 1
  logger.debug("[tool_orchestrator] on_generation_complete: 递增迭代至 " .. ss.current_iteration .. ", 等待悬浮窗关闭后执行工具")

  -- 安全机制：5 秒超时后仍然打开新悬浮窗和执行工具
  vim.defer_fn(function()
    local ok, exists = pcall(vim.api.nvim_get_autocmds, { id = autocmd_id })
    if ok and exists and #exists > 0 then
      pcall(vim.api.nvim_del_autocmd, autocmd_id)
      logger.debug("[tool_orchestrator] on_generation_complete: 超时未收到 TOOL_DISPLAY_CLOSED，强制打开新悬浮窗")
      vim.api.nvim_exec_autocmds("User", {
        pattern = event_constants.TOOL_LOOP_STARTED,
        data = {
          generation_id = ss.generation_id,
          tool_calls = tool_calls,
          session_id = session_id,
          window_id = ss.window_id,
          iteration = ss.current_iteration,
        },
      })
      M._execute_tools(session_id, tool_calls)
    end
  end, 5000)
end

--- 将工具执行结果加入消息历史
--- 由 _execute_single_tool 的回调在工具执行完成后调用
--- @param session_id string
--- @param tool_call_id string
--- @param tool_name string
--- @param result any 工具执行结果
function M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result)
  local ss = state.sessions[session_id]
  if not ss then return end

  local safe_id = tool_call_id
  if not safe_id or safe_id == "" then
    safe_id = "call_" .. os.time() .. "_" .. math.random(10000, 99999)
  end

  local result_str = ""
  if type(result) == "string" then
    result_str = result
  elseif result ~= nil then
    local ok, encoded = pcall(vim.json.encode, result)
    if ok then
      result_str = encoded
    else
      result_str = tostring(result)
    end
  end

  local tool_msg = {
    role = "tool",
    tool_call_id = safe_id,
    content = result_str,
    timestamp = os.time(),
    window_id = ss.window_id,
  }
  if tool_name then
    tool_msg.name = tool_name
  end
  table.insert(ss.messages, tool_msg)
  logger.debug("[tool_orchestrator] _add_tool_result_to_messages: 已添加 tool 消息, tool_call_id=" .. safe_id .. ", tool_name=" .. tostring(tool_name))
end

-- ========== 结束循环 ==========

--- 结束循环
function M._finish_loop(session_id, success, result)
  local ss = state.sessions[session_id]
  if not ss then
    logger.debug("[tool_orchestrator] _finish_loop: 会话 " .. session_id .. " 不存在")
    return
  end

  logger.debug("[tool_orchestrator] _finish_loop: 会话=" .. session_id .. ", success=" .. tostring(success) .. ", 迭代=" .. ss.current_iteration)

  -- 如果已经结束（on_complete 已被清空），防止重复调用
  if ss.on_complete == nil then
    logger.debug("[tool_orchestrator] _finish_loop: 已结束，跳过重复调用")
    return
  end

  local on_complete = ss.on_complete
  local usage = ss.accumulated_usage or {}
  local saved_generation_id = ss.generation_id
  local saved_window_id = ss.window_id
  local saved_reasoning = ss.last_reasoning or ""

  -- 触发 TOOL_LOOP_FINISHED 事件，让 UI 关闭工具调用悬浮窗
  -- 必须在清理状态之前触发，因为 chat_window 需要读取 state.tool_display
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_FINISHED,
    data = {
      generation_id = saved_generation_id,
      tool_results = {},
      iteration_count = ss.current_iteration,
      session_id = session_id,
      window_id = saved_window_id,
    },
  })

  -- 清理本轮状态（不清除会话注册，保留监听器供下次使用）
  ss.phase = "idle"
  ss.active_tool_calls = {}
  ss.current_iteration = 0
  ss.generation_id = nil
  ss.on_complete = nil

  -- 触发 GENERATION_COMPLETED 事件，通知 chat_window 渲染 UI
  -- 这是工具循环结束后的最终 AI 回复，需要触发 UI 更新
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.GENERATION_COMPLETED,
      data = {
        generation_id = saved_generation_id,
        response = result or "",
        reasoning_text = saved_reasoning,
        usage = usage,
        session_id = session_id,
        window_id = saved_window_id,
        duration = 0,
      },
    })

    -- 调用完成回调
    on_complete(success, result, usage)
  end)
end

-- ========== 停止控制 ==========

function M.request_stop(session_id)
  if session_id then
    -- 停止指定会话
    local ss = state.sessions[session_id]
    if ss then
      ss.stop_requested = true
      -- 不取消所有 worker，只取消非 stop_tool_loop 的 worker
      -- 让 stop_tool_loop 工具正常完成回调，从而触发 TOOL_LOOP_FINISHED 事件关闭悬浮窗
      for id, w in pairs(async_worker.get_all_worker_status()) do
        if w.name ~= "tool_stop_tool_loop" then
          async_worker.cancel_worker(id)
        end
      end
      -- 触发停止事件，监听器会处理
      vim.api.nvim_exec_autocmds("User", {
        pattern = event_constants.TOOL_LOOP_STOP_REQUESTED,
        data = { session_id = session_id },
      })
    end
  else
    -- 停止所有会话
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
    -- 使用阶段状态机判断：waiting_tools 或 waiting_model 表示正在执行
    return ss.phase == "waiting_tools" or ss.phase == "waiting_model"
  end
  -- 检查是否有任何会话在执行
  for _, ss in pairs(state.sessions) do
    if ss.phase == "waiting_tools" or ss.phase == "waiting_model" then
      return true
    end
  end
  return false
end

-- ========== 关闭清理 ==========

function M.shutdown()
  -- 注销所有会话
  for session_id, _ in pairs(state.sessions) do
    M.unregister_session(session_id)
  end
  async_worker.cancel_all_workers()
  state.sessions = {}
  state.tools = {}
  state.initialized = false
end

return M
