-- 统一的工具循环引擎（事件驱动架构）
-- 职责：管理主 agent 和子 agent 的工具调用循环执行
--
-- 阶段定义：
--   idle          - 空闲状态
--   waiting_tools - 等待工具执行完成
--   waiting_model - 等待模型生成完成
--   round_complete - 本轮所有操作已完成
--
-- 工具包支持：
--   同一工具包内的多个工具调用会被分组并发执行
--   UI 按包分组显示执行状态
--
-- 子 agent 支持：
--   通过 _sub_agent_id 区分主 agent 和子 agent 的会话
--   子 agent 拥有独立的会话状态（消息、迭代计数、停止标志）
--   所有工具执行的循环控制统一由本模块管理
--
-- 不在此模块的职责：
--   - 工具名称模糊匹配 → tool_executor._normalize_tool_name
--   - 单次工具请求 → tool_executor.execute_single_tool_request
--   - 工具注册 → tool_registry

local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local tool_pack = require("NeoAI.tools.tool_pack")
local shutdown_flag = require("NeoAI.core.shutdown_flag")
local request_handler = require("NeoAI.core.ai.request_handler")
local state_manager = require("NeoAI.core.config.state")
local plan_executor = require("NeoAI.tools.builtin.plan_executor")

-- ========== 状态 ==========

local _tools = {}

local state = {
  initialized = false,
  config = nil,
  sessions = {}, -- 主 agent 会话
  sub_agent_sessions = {}, -- 子 agent 会话（sub_agent_id -> session state）
}

-- ========== 辅助函数 ==========

--- 检查 Neovim 是否正在退出
--- 使用统一的 shutdown_flag 模块
local function is_shutting_down()
  return shutdown_flag.is_set()
end

--- 设置退出标志（由 VimLeavePre 回调调用）
--- 委托给统一的 shutdown_flag 模块
function M.set_shutting_down()
  shutdown_flag.set()
end

--- 等待 TOOL_DISPLAY_CLOSED 事件后执行回调
--- 优化：移除 5 秒超时等待，直接通过 vim.schedule 执行回调
--- TOOL_DISPLAY_CLOSED 由 chat_window 在 TOOL_LOOP_FINISHED 回调中触发
--- 由于 fire_loop_finished 在调用此函数之前已触发，事件可能已错过
--- 因此直接执行回调，不再等待事件
local function once_display_closed(session_id, callback)
  -- 直接执行回调，不再使用 vim.schedule 延迟
  -- 之前的 vim.schedule 是为了等待 TOOL_DISPLAY_CLOSED 事件
  -- 但现在该事件已不再使用，直接执行回调可以减少工具循环的延迟
  if is_shutting_down() then
    return
  end
  callback()
end

--- 触发 TOOL_LOOP_FINISHED 事件
--- 使用 pcall 保护，避免在 fast event 上下文中调用失败
--- @param ss table 会话状态
--- @param is_round_end boolean|nil 是否为本轮真正结束（所有工具和 AI 都完成）
--- @param trigger_source string|nil 触发来源："tools_complete"（工具完成）、"ai_complete"（AI 完成）
local function fire_loop_finished(ss, is_round_end, trigger_source)
  if not ss then
    return
  end
  -- 检查 Neovim 是否正在退出，避免在退出过程中调度事件导致死循环
  if is_shutting_down() then
    return
  end

  local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event_constants.TOOL_LOOP_FINISHED,
    data = {
      generation_id = ss.generation_id,
      tool_results = {},
      iteration_count = ss.current_iteration,
      session_id = ss.session_id,
      window_id = ss.window_id,
      is_round_end = is_round_end == true,
      trigger_source = trigger_source or "tools_complete",
    },
  })
  if not ok then
    -- 再次检查 Neovim 是否正在退出
    if is_shutting_down() then
      return
    end

    -- fast event 上下文，用 vim.schedule 重试
    vim.schedule(function()
      if is_shutting_down() then
        return
      end
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_LOOP_FINISHED,
        data = {
          generation_id = ss.generation_id,
          tool_results = {},
          iteration_count = ss.current_iteration,
          session_id = ss.session_id,
          window_id = ss.window_id,
          is_round_end = is_round_end == true,
        },
      })
    end)
  end
end

--- 触发 TOOL_RESULT_RECEIVED 事件
--- 使用 pcall 保护，避免在 fast event 上下文中调用失败
local function fire_tool_result_received(ss)
  if not ss then
    return
  end
  -- 检查 Neovim 是否正在退出
  if is_shutting_down() then
    return
  end

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
      accumulated_usage = ss.accumulated_usage,
      last_reasoning = ss.last_reasoning,
    },
  })
  if not ok then
    if is_shutting_down() then
      return
    end

    vim.schedule(function()
      if is_shutting_down() then
        return
      end
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
    active_tool_calls = {},
    current_iteration = 0,
    messages = {},
    options = {},
    model_index = 1,
    ai_preset = {},
    accumulated_usage = {},
    last_reasoning = nil,
    stop_requested = false,
    user_cancelled = false, -- 用户主动取消标志
    _tool_retry_count = 0, -- 工具调用重试计数
    _generation_completed = false, -- GENERATION_COMPLETED 事件是否已到达
    _tools_all_completed = false, -- TOOL_EXECUTION_ALL_COMPLETED 事件是否已到达
    on_complete = nil,
    autocmd_ids = {},
  }
end

-- ========== 初始化 ==========

function M.initialize(options)
  if state.initialized then
    return M
  end
  state.config = options.config or {}
  state.initialized = true

  _tools = {}

  -- 初始化工具包管理模块
  tool_pack.initialize()

  return M
end

-- ========== 会话生命周期 ==========

function M.register_session(session_id, window_id)
  if state.sessions[session_id] then
    return
  end

  local ss = create_session_state(session_id, window_id)
  local ids = {}

  -- GENERATION_COMPLETED 监听器
  table.insert(
    ids,
    vim.api.nvim_create_autocmd("User", {
      pattern = event_constants.GENERATION_COMPLETED,
      callback = function(args)
        local data = args.data
        if data.session_id ~= session_id then
          return
        end
        local s = state.sessions[session_id]
        if not s then
          return
        end

        -- 累积 usage
        if data.usage and next(data.usage) then
          local acc = s.accumulated_usage or {}
          acc.prompt_tokens = (acc.prompt_tokens or 0) + (data.usage.prompt_tokens or data.usage.input_tokens or 0)
          acc.completion_tokens = (acc.completion_tokens or 0)
            + (data.usage.completion_tokens or data.usage.output_tokens or 0)
          acc.total_tokens = (acc.total_tokens or 0) + (data.usage.total_tokens or 0)
          if data.usage.completion_tokens_details and type(data.usage.completion_tokens_details) == "table" then
            local rt = data.usage.completion_tokens_details.reasoning_tokens or 0
            if not acc.completion_tokens_details then
              acc.completion_tokens_details = {}
            end
            acc.completion_tokens_details.reasoning_tokens = (acc.completion_tokens_details.reasoning_tokens or 0) + rt
          end
          s.accumulated_usage = acc
        end
        if data.reasoning_text and data.reasoning_text ~= "" then
          s.last_reasoning = data.reasoning_text
        end

        M._check_round_complete(session_id)
      end,
    })
  )

  -- TOOL_LOOP_FINISHED 监听器（统一处理进入 idle 状态）
  table.insert(
    ids,
    vim.api.nvim_create_autocmd("User", {
      pattern = event_constants.TOOL_LOOP_FINISHED,
      callback = function(args)
        local data = args.data
        if data.session_id ~= session_id then
          return
        end
        if not data.is_round_end then
          return
        end
        local s = state.sessions[session_id]
        if not s then
          return
        end
        -- 统一由事件驱动进入 idle 状态
        s.phase = "idle"
      end,
    })
  )

  ss.autocmd_ids = ids
  state.sessions[session_id] = ss
end

function M.unregister_session(session_id)
  local ss = state.sessions[session_id]
  if not ss then
    return
  end
  for _, id in ipairs(ss.autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state.sessions[session_id] = nil
end

-- ========== 子 agent 会话管理 ==========

--- 注册子 agent 会话到 tool_orchestrator
--- 子 agent 使用独立的会话状态（消息、迭代计数、停止标志）
--- @param sub_agent_id string
--- @param session_id string 所属主 agent 的 session_id
--- @param window_id number|nil
--- @param params table 初始参数 { messages, options, model_index, ai_preset, on_summary }
function M.register_sub_agent_session(sub_agent_id, session_id, window_id, params)
  if state.sub_agent_sessions[sub_agent_id] then
    return
  end

  local ss = create_session_state(sub_agent_id, window_id)
  ss._is_sub_agent = true
  ss._parent_session_id = session_id
  ss.messages = params.messages or {}
  ss.options = params.options or {}
  ss.model_index = params.model_index or 1
  ss.ai_preset = params.ai_preset or {}
  ss._on_summary = params.on_summary
  ss.max_iterations = params.max_iterations or 10

  -- 为子 agent 注册 TOOL_LOOP_FINISHED 监听器（统一 idle 状态管理）
  local ids = {}
  table.insert(
    ids,
    vim.api.nvim_create_autocmd("User", {
      pattern = event_constants.TOOL_LOOP_FINISHED,
      callback = function(args)
        local data = args.data
        if data.session_id ~= sub_agent_id then
          return
        end
        if not data.is_round_end then
          return
        end
        local s = state.sub_agent_sessions[sub_agent_id]
        if not s then
          return
        end
        s.phase = "idle"
      end,
    })
  )
  ss.autocmd_ids = ids

  state.sub_agent_sessions[sub_agent_id] = ss
end

--- 注销子 agent 会话
--- @param sub_agent_id string
function M.unregister_sub_agent_session(sub_agent_id)
  local ss = state.sub_agent_sessions[sub_agent_id]
  if not ss then
    return
  end
  for _, id in ipairs(ss.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state.sub_agent_sessions[sub_agent_id] = nil
end

--- 获取会话状态（支持主 agent 和子 agent）
--- @param id string session_id 或 sub_agent_id
--- @param is_sub_agent boolean|nil
--- @return table|nil
function M._get_session(id, is_sub_agent)
  if is_sub_agent then
    return state.sub_agent_sessions[id]
  end
  return state.sessions[id]
end

-- ========== 循环调度 ==========

-- 全局 ESC 停止监听器 ID（在循环开始时注册，结束时清理）
-- 使用 local 声明，确保在闭包内私有
local _stop_listener_id = nil

function M.start_async_loop(params)
  if not params then
    return
  end
  if not state.initialized then
    if params.on_complete then
      vim.schedule(function()
        params.on_complete(false, nil, "Tool orchestrator not initialized")
      end)
    end
    return
  end

  -- 通过闭包捕获当前协程上下文（如果存在），供后续工具执行路径使用
  local coroutine_ctx = state_manager.get_current_context()

  local session_id = params.session_id
  local window_id = params.window_id
  local sub_agent_id = params._sub_agent_id
  local is_sub_agent = sub_agent_id ~= nil

  -- 确定会话 ID 和会话存储
  local sid = is_sub_agent and sub_agent_id or session_id
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions

  if not sessions_table[sid] then
    if is_sub_agent then
      -- 子 agent 会话应由 register_sub_agent_session 预先注册
      logger.warn("[tool_orchestrator] start_async_loop: 子 agent 会话 %s 未注册，自动创建", sid)
      M.register_sub_agent_session(sub_agent_id, session_id, window_id, {
        messages = params.messages or {},
        options = params.options or {},
        model_index = params.model_index or 1,
        ai_preset = params.ai_preset or {},
        on_summary = params.on_summary,
      })
    else
      M.register_session(session_id, window_id)
    end
  end

  local ss = sessions_table[sid]
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
  ss._coroutine_ctx = coroutine_ctx
  ss._is_sub_agent = is_sub_agent
  ss._parent_session_id = is_sub_agent and session_id or nil

  ss.current_iteration = 1
  ss._tool_retry_count = 0
  -- start_async_loop 由 ai_engine 在 AI 生成完成后调用，标记 AI 生成已完成
  ss._generation_completed = true
  ss._tools_all_completed = false

  -- 首次进入工具循环时（非工具循环重入），插入 assistant 消息（带 tool_calls）
  -- 确保 tool 结果消息前面有对应的 assistant 消息，避免 API 报错
  -- "Messages with role 'tool' must be a response to a preceding message with 'tool_calls'"
  if params.tool_calls and #params.tool_calls > 0 then
    local last_msg = ss.messages[#ss.messages]
    if not last_msg or last_msg.role ~= "assistant" or not last_msg.tool_calls then
      local assistant_msg = {
        role = "assistant",
        content = params.content or "",
        timestamp = os.time(),
        window_id = ss.window_id,
      }
      if params.reasoning and params.reasoning ~= "" then
        assistant_msg.reasoning_content = params.reasoning
        ss.last_reasoning = params.reasoning
      end
      assistant_msg.tool_calls = params.tool_calls
      table.insert(ss.messages, assistant_msg)
    end
  end

  -- 注册全局 ESC 停止监听器（仅在循环开始时注册一次）
  if not _stop_listener_id then
    _stop_listener_id = vim.api.nvim_create_autocmd("User", {
      pattern = event_constants.CANCEL_GENERATION,
      callback = function()
        -- 停止所有主 agent 会话
        for sid, s in pairs(state.sessions) do
          if s then
            s.stop_requested = true
            s.user_cancelled = true
            s.active_tool_calls = {}
          end
        end
        -- 停止所有子 agent 会话
        for sid, s in pairs(state.sub_agent_sessions) do
          if s then
            s.stop_requested = true
            s.active_tool_calls = {}
          end
        end
        -- 清理所有活跃的 HTTP 请求
        local http_utils = require("NeoAI.utils.http_utils")
        http_utils.cancel_all_requests()
      end,
    })
  end

  M._execute_tools(sid, params.tool_calls or {}, is_sub_agent)
end

-- ========== 工具执行 ==========

function M._execute_tools(session_id, tool_calls, is_sub_agent)
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local ss = sessions_table[session_id]
  if not ss then
    return
  end

  -- 如果已请求停止，跳过所有工具执行
  if ss.stop_requested then
    return
  end

  require("NeoAI.utils.logger").debug(
    "[DEBUG_DUP] _execute_tools 进入: session=%s, tool_calls=%d, phase=%s",
    tostring(session_id),
    #tool_calls,
    tostring(ss and ss.phase)
  )

  if #tool_calls == 0 then
    vim.schedule(function()
      M._request_generation(session_id, is_sub_agent)
    end)
    return
  end

  -- 调试日志：追踪 _execute_tools 调用
  local tool_names = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    table.insert(tool_names, func and func.name or "unknown")
  end
  require("NeoAI.utils.logger").debug(
    "[DEBUG_DUP] _execute_tools: session=%s, tools=%s, phase=%s, iter=%d, stack=%s",
    tostring(session_id),
    table.concat(tool_names, ","),
    tostring(ss.phase),
    ss.current_iteration or 0,
    debug.traceback()
  )

  ss.phase = "waiting_tools"
  ss.active_tool_calls = {}

  -- 强制刷新 UI，让用户看到工具执行开始

  -- 按工具包分组，触发 PACK_STARTED 事件
  local grouped = tool_pack.group_by_pack(tool_calls)
  local pack_order = {}
  for pack_name, _ in pairs(grouped) do
    table.insert(pack_order, pack_name)
  end
  table.sort(pack_order, function(a, b)
    return tool_pack.get_pack_order(a) < tool_pack.get_pack_order(b)
  end)

  -- 触发 TOOL_LOOP_STARTED 时附带包分组信息
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_LOOP_STARTED,
    data = {
      generation_id = ss.generation_id,
      tool_calls = tool_calls,
      tool_packs = grouped,
      pack_order = pack_order,
      session_id = ss.session_id,
      window_id = ss.window_id,
      iteration = ss.current_iteration,
    },
  })

  -- 所有工具并发执行（保持原有异步并发行为）
  for _, tc in ipairs(tool_calls) do
    M._execute_single_tool(session_id, tc, is_sub_agent)
  end
end

function M._execute_single_tool(session_id, tool_call, is_sub_agent)
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local ss = sessions_table[session_id]
  if not ss or not tool_call then
    return
  end

  -- 如果已请求停止，跳过工具执行
  if ss.stop_requested then
    return
  end

  local tool_func = tool_call["function"] or tool_call.func
  if not tool_func then
    logger.warn(
      "[tool_orchestrator] _execute_single_tool: tool_call 缺少 function 字段, tool_call=" .. vim.inspect(tool_call)
    )
    return
  end

  local tool_name = tool_func.name
  if not tool_name or tool_name == "" then
    logger.warn("[tool_orchestrator] _execute_single_tool: tool_func.name 为空, tool_func=" .. vim.inspect(tool_func))
    return
  end

  -- ===== 工具名称修正（别名映射 + 模糊匹配） =====
  local tool_executor = require("NeoAI.tools.tool_executor")
  local tool_registry = require("NeoAI.tools.tool_registry")
  -- ===== 工具名称和参数规范化（别名映射 + 模糊匹配） =====
  -- 不检查工具是否存在，直接对工具名称和参数做规范化
  -- 规范化后更新 ss.messages 中的记录，确保上下文和历史一致
  local original_tool_name = tool_name
  local tool_def = tool_registry.get(tool_name)
  local tool_name_changed = false

  -- 1) 别名映射
  local normalized_name, _ = tool_executor._normalize_tool_name(tool_name)
  if normalized_name and normalized_name ~= tool_name then
    tool_name = normalized_name
    tool_def = tool_registry.get(tool_name)
    tool_name_changed = true
    logger.warn("[tool_orchestrator] 工具名称别名修正: '%s' -> '%s'", original_tool_name, tool_name)
  end

  -- 2) 模糊匹配（别名映射未命中时）
  if not tool_def then
    local all_tools = tool_registry.list()
    local all_names = {}
    for _, t in ipairs(all_tools) do
      table.insert(all_names, t.name)
    end
    local best_match = M._fuzzy_match_tool(original_tool_name, all_names)
    if best_match then
      tool_name = best_match
      tool_def = tool_registry.get(tool_name)
      tool_name_changed = true
      logger.warn("[tool_orchestrator] 工具名称模糊匹配修正: '%s' -> '%s'", original_tool_name, tool_name)
    end
  end

  -- 如果工具名称发生变化，更新 ss.messages 中的记录
  if tool_name_changed then
    -- 更新 tool_call 中的工具名称
    tool_func.name = tool_name
    -- 更新 ss.messages 中所有 assistant 消息的 tool_calls
    if ss.messages then
      for i = #ss.messages, 1, -1 do
        local msg = ss.messages[i]
        if msg.role == "assistant" and msg.tool_calls then
          local updated = false
          for _, tc in ipairs(msg.tool_calls) do
            local tc_func = tc["function"] or tc.func
            if tc_func and tc_func.name == original_tool_name then
              tc_func.name = tool_name
              updated = true
            end
          end
          if updated then
            logger.debug(
              "[tool_orchestrator] 已更新 assistant 消息中工具名称: '%s' -> '%s'",
              original_tool_name,
              tool_name
            )
          end
        end
      end
    end
  end

  -- 3) 参数规范化
  if tool_def and tool_func.arguments then
    local normalized_args, args_changed = tool_executor._normalize_arguments(tool_name, tool_func.arguments)
    if args_changed then
      tool_func.arguments = normalized_args
      logger.warn("[tool_orchestrator] 工具 '%s' 参数已规范化", tool_name)
      -- 更新 ss.messages 中的参数
      if ss.messages then
        for i = #ss.messages, 1, -1 do
          local msg = ss.messages[i]
          if msg.role == "assistant" and msg.tool_calls then
            local updated = false
            for _, tc in ipairs(msg.tool_calls) do
              local tc_func = tc["function"] or tc.func
              if tc_func and tc_func.name == tool_name then
                tc_func.arguments = normalized_args
                updated = true
              end
            end
            if updated then
              logger.debug("[tool_orchestrator] 已更新 assistant 消息中工具 '%s' 的参数", tool_name)
            end
          end
        end
      end
    end
  end

  -- 调试日志：追踪 _execute_single_tool 调用
  require("NeoAI.utils.logger").debug(
    "[DEBUG_DUP] _execute_single_tool: session=%s, tool=%s, tool_call_id=%s, active_count=%d, stack=%s",
    tostring(session_id),
    tostring(tool_name),
    tostring(tool_call.id or "nil"),
    vim.tbl_count(ss.active_tool_calls or {}),
    debug.traceback()
  )

  -- 生成唯一 tool_call_id
  if not M._tool_call_counter then
    M._tool_call_counter = 0
  end
  M._tool_call_counter = M._tool_call_counter + 1
  local tool_call_id = tool_call.id
    or ("call_" .. os.time() .. "_" .. M._tool_call_counter .. "_" .. math.random(10000, 99999))
  tool_call.id = tool_call_id
  ss.active_tool_calls[tool_call_id] = true

  -- ===== 子 agent 工具调用边界审核 =====
  if is_sub_agent then
    local args = tool_func.arguments or {}
    if type(args) ~= "table" then
      args = {}
    end
    local sub_agent_engine = require("NeoAI.core.ai.sub_agent_engine")
    local allowed, reason = sub_agent_engine.review_tool_call(session_id, tool_name, args)
    if not allowed then
      local result_str = string.format(
        "[调度 agent 驳回] 工具 '%s' 的调用被拒绝。原因: %s\n此工具不在你的允许列表中，请不要再尝试调用它。请使用其他允许的工具继续完成任务，或直接返回文本说明任务无法完成。",
        tool_name,
        reason
      )
      M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str, is_sub_agent)
      ss.active_tool_calls[tool_call_id] = nil
      local remaining = vim.tbl_count(ss.active_tool_calls)
      if remaining == 0 then
        M._on_tools_complete(session_id, is_sub_agent)
      end
      return
    end
  end

  -- ===== 检测 create_sub_agent 工具调用（仅主 agent） =====
  if tool_name == "create_sub_agent" and not is_sub_agent then
    local args = tool_func.arguments or {}
    if type(args) ~= "table" then
      args = {}
    end

    local tool_executor = require("NeoAI.tools.tool_executor")
    local pack_name = tool_pack.get_pack_for_tool(tool_name)

    tool_executor.execute_with_orchestrator(tool_name, tool_func.arguments, {
      session_id = session_id,
      window_id = ss.window_id,
      generation_id = ss.generation_id,
      tool_call_id = tool_call_id,
      pack_name = pack_name,
    }, {
      on_result = function(success, result)
        local s = sessions_table[session_id]
        if not s then
          return
        end

        if s.stop_requested then
          s.active_tool_calls[tool_call_id] = nil
          if vim.tbl_count(s.active_tool_calls) == 0 then
            M._on_tools_complete(session_id, is_sub_agent)
          end
          return
        end

        if success and result then
          local result_str = type(result) == "string" and result or ""
          local ok2, parsed_result = pcall(vim.json.decode, result_str)
          local sub_agent_id = parsed_result and parsed_result.sub_agent_id or nil

          if sub_agent_id then
            plan_executor.record_message(sub_agent_id, "system", "子 agent 已创建，任务: " .. (args.task or ""))
          end

          M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str, is_sub_agent)

          if sub_agent_id then
            -- 注册子 agent 会话到 tool_orchestrator
            M.register_sub_agent_session(sub_agent_id, session_id, ss.window_id, {
              messages = {},
              options = ss.options,
              model_index = ss.model_index,
              ai_preset = ss.ai_preset,
              on_summary = function(summary)
                local s2 = sessions_table[session_id]
                if not s2 then
                  return
                end

                local summary_msg =
                  string.format("【子 agent 执行完成】\n子 agent ID: %s\n\n%s", sub_agent_id, summary)

                table.insert(s2.messages, {
                  role = "user",
                  content = summary_msg,
                  timestamp = os.time(),
                  window_id = s2.window_id,
                })

                vim.notify(string.format("[NeoAI] 子 agent [%s] 执行完成", sub_agent_id), vim.log.levels.INFO)

                local chat_window = require("NeoAI.ui.window.chat_window")
                pcall(chat_window.render_chat)

                plan_executor.cleanup_sub_agent(sub_agent_id)
                M.unregister_sub_agent_session(sub_agent_id)
              end,
              max_iterations = (args.boundaries and args.boundaries.max_iterations) or 10,
            })

            -- 启动子 agent 的工具循环（异步，不阻塞主 agent）
            vim.schedule(function()
              local sub_agent_engine = require("NeoAI.core.ai.sub_agent_engine")
              sub_agent_engine.start_sub_agent_loop(sub_agent_id, {}, {
                session_id = session_id,
                window_id = ss.window_id,
                messages = {},
                options = ss.options,
                model_index = ss.model_index,
                ai_preset = ss.ai_preset,
                on_summary = nil, -- 由 tool_orchestrator 的 on_summary 处理
              })
            end)
          end
        else
          local err_msg = type(result) == "string" and result or "创建子 agent 失败"
          M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, err_msg, is_sub_agent)
        end

        s.active_tool_calls[tool_call_id] = nil
        local remaining = vim.tbl_count(s.active_tool_calls)
        if remaining == 0 and s.phase ~= "round_complete" then
          M._on_tools_complete(session_id, is_sub_agent)
        end
      end,
    })
    return
  end

  -- ===== 普通工具执行 =====
  local pack_name = tool_pack.get_pack_for_tool(tool_name)
  local tool_executor = require("NeoAI.tools.tool_executor")

  local execute_fn = function()
    tool_executor.execute_with_orchestrator(tool_name, tool_func.arguments, {
      session_id = session_id,
      window_id = ss.window_id,
      generation_id = ss.generation_id,
      tool_call_id = tool_call_id,
      pack_name = pack_name,
    }, {
      on_result = function(success, result)
        local s = sessions_table[session_id]
        if not s then
          return
        end

        if s.stop_requested then
          s.active_tool_calls[tool_call_id] = nil
          if vim.tbl_count(s.active_tool_calls) == 0 then
            M._on_tools_complete(session_id, is_sub_agent)
          end
          return
        end

        local result_str = success and result or ("[工具执行失败] " .. result)
        M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str, is_sub_agent)

        s.active_tool_calls[tool_call_id] = nil
        local remaining = vim.tbl_count(s.active_tool_calls)

        if remaining == 0 and s.phase ~= "round_complete" then
          M._on_tools_complete(session_id, is_sub_agent)
        end
      end,
    })
  end

  if ss._coroutine_ctx then
    state_manager.with_context(ss._coroutine_ctx, execute_fn)
  else
    execute_fn()
  end
end

-- ========== 完成检查 ==========

function M._on_tools_complete(session_id, is_sub_agent)
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local ss = sessions_table[session_id]
  if not ss then
    return
  end
  -- 退出时直接跳过，避免触发事件或发起 AI 请求导致死循环
  if is_shutting_down() then
    return
  end

  -- 触发 TOOL_EXECUTION_ALL_COMPLETED 事件，通知 tool_display 所有工具执行完毕
  -- 让悬浮窗显示"等待 AI 响应..."状态
  if not is_shutting_down() then
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = event_constants.TOOL_EXECUTION_ALL_COMPLETED,
      data = {
        generation_id = ss.generation_id,
        session_id = ss.session_id,
        window_id = ss.window_id,
        iteration = ss.current_iteration,
      },
    })
  end

  -- 标记 TOOL_EXECUTION_ALL_COMPLETED 已到达
  ss._tools_all_completed = true

  -- 调试日志：追踪 _on_tools_complete 调用
  require("NeoAI.utils.logger").debug(
    "[DEBUG_DUP] _on_tools_complete: session=%s, phase=%s, iter=%d, _tools_complete_in_progress=%s, active_count=%d, stack=%s",
    tostring(session_id),
    tostring(ss.phase),
    ss.current_iteration or 0,
    tostring(ss._tools_complete_in_progress),
    vim.tbl_count(ss.active_tool_calls or {}),
    debug.traceback()
  )

  if ss._tools_complete_in_progress then
    return
  end
  ss._tools_complete_in_progress = true

  if ss.stop_requested then
    ss._tools_complete_in_progress = false
    ss._generation_completed = false
    ss._tools_all_completed = false
    -- 退出时直接跳过，不触发任何事件或总结
    if is_shutting_down() then
      return
    end
    -- 用户取消或跳过总结时，触发 GENERATION_COMPLETED 事件显示用量，然后直接结束
    if ss.user_cancelled then
      -- 触发 GENERATION_COMPLETED 事件显示用量信息
      local saved_usage = ss.accumulated_usage or {}
      local saved_gen_id = ss.generation_id
      local saved_win_id = ss.window_id
      local saved_reasoning = ss.last_reasoning or ""
      fire_loop_finished(ss, true, "tools_complete")
      once_display_closed(session_id, function()
        local s = sessions_table[session_id]
        if not s then
          return
        end
        if is_shutting_down() then
          return
        end
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = event_constants.GENERATION_COMPLETED,
          data = {
            generation_id = saved_gen_id,
            response = "",
            reasoning_text = saved_reasoning,
            usage = saved_usage,
            session_id = session_id,
            window_id = saved_win_id,
            duration = 0,
          },
        })
        if s.on_complete then
          local cb = s.on_complete
          s.on_complete = nil
          cb(true, "", saved_usage)
        end
      end)
      return
    end
    fire_loop_finished(ss, true, "tools_complete")
    return
  end

  if ss.phase == "waiting_tools" then
    ss.phase = "waiting_model"
    -- 工具执行完毕不关闭悬浮窗，等待 AI 输出完成后统一关闭
    fire_loop_finished(ss, false, "tools_complete")
    once_display_closed(session_id, function()
      local s = sessions_table[session_id]
      if not s then
        return
      end
      -- 在回调内部重置 _tools_complete_in_progress，防止在异步调度期间
      -- 被第二次 _on_tools_complete 调用绕过保护
      s._tools_complete_in_progress = false
      if is_shutting_down() then
        return
      end
      if s.stop_requested then
        logger.debug(
          "[tool_orchestrator] _on_tools_complete: once_display_closed 回调中检测到 stop_requested，跳过 _check_round_complete"
        )
        return
      end
      -- 工具全部完成，检查是否两个事件都已到达，决定是否开启下一轮
      M._check_round_complete(session_id, is_sub_agent)
    end)
  elseif ss.phase == "round_complete" then
    ss._tools_complete_in_progress = false
    -- 本轮已完成，由 _check_round_complete 决定是否开启下一轮
    M._check_round_complete(session_id, is_sub_agent)
  else
    ss._tools_complete_in_progress = false
  end
end

function M._check_round_complete(session_id, is_sub_agent)
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local ss = sessions_table[session_id]
  if not ss then
    return
  end

  if ss.stop_requested then
    -- idle 状态由 TOOL_LOOP_FINISHED 监听器统一设置
    return
  end

  -- 双事件等待机制：必须 GENERATION_COMPLETED 和 TOOL_EXECUTION_ALL_COMPLETED 都到达
  -- 才能开启下一轮 AI 请求
  if not ss._generation_completed or not ss._tools_all_completed then
    -- 其中一个事件尚未到达，继续等待
    require("NeoAI.utils.logger").debug(
      "[tool_orchestrator] _check_round_complete: 等待双事件到达, session=%s, gen_completed=%s, tools_completed=%s, phase=%s",
      tostring(session_id),
      tostring(ss._generation_completed),
      tostring(ss._tools_all_completed),
      tostring(ss.phase)
    )
    return
  end

  -- 两个事件都已到达，重置标志并进入下一轮
  ss._generation_completed = false
  ss._tools_all_completed = false

  -- 如果还有活跃的工具调用（AI 刚返回工具调用，工具尚未执行），不进入下一轮
  if vim.tbl_count(ss.active_tool_calls) > 0 then
    require("NeoAI.utils.logger").debug(
      "[tool_orchestrator] _check_round_complete: 还有活跃工具调用, 跳过下一轮, session=%s, active_count=%d",
      tostring(session_id),
      vim.tbl_count(ss.active_tool_calls)
    )
    return
  end

  if ss._proceed_in_progress then
    return
  end

  ss.phase = "round_complete"
  M._proceed_to_next_round(session_id, is_sub_agent)
end

function M._proceed_to_next_round(session_id, is_sub_agent)
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local ss = sessions_table[session_id]
  if not ss then
    return
  end

  -- 调试日志：追踪 _proceed_to_next_round 调用
  require("NeoAI.utils.logger").debug(
    "[DEBUG_DUP] _proceed_to_next_round: session=%s, phase=%s, iter=%d, _proceed_in_progress=%s, stack=%s",
    tostring(session_id),
    tostring(ss.phase),
    ss.current_iteration or 0,
    tostring(ss._proceed_in_progress),
    debug.traceback()
  )

  if ss._proceed_in_progress then
    return
  end
  ss._proceed_in_progress = true

  ss.phase = "idle"
  ss.active_tool_calls = {}

  if ss.stop_requested then
    ss._proceed_in_progress = false
    return
  end

  fire_loop_finished(ss, false, "tools_complete")
  ss.current_iteration = ss.current_iteration + 1
  ss.phase = "waiting_model"
  ss._proceed_in_progress = false

  -- 使用 vim.schedule 异步执行 _request_generation，防止 handle_tool_result
  -- 的同步回调导致递归调用 _proceed_to_next_round，造成工具被重复执行
  vim.schedule(function()
    local s = sessions_table[session_id]
    if not s or s.stop_requested then
      return
    end
    M._request_generation(session_id, is_sub_agent)
  end)
end

-- ========== 请求 AI 生成 ==========

function M._request_generation(session_id, is_sub_agent)
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local ss = sessions_table[session_id]
  if not ss or ss.stop_requested then
    return
  end

  if is_sub_agent then
    -- 子 agent 请求：传递 _sub_agent_id 标记
    local sub_agent_engine = require("NeoAI.core.ai.sub_agent_engine")
    sub_agent_engine._request_generation(session_id)
  else
    fire_tool_result_received(ss)
  end
end

-- ========== 外部回调 ==========

function M.on_generation_complete(data)
  local sub_agent_id = data._sub_agent_id
  local is_sub_agent = sub_agent_id ~= nil
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local session_id = is_sub_agent and sub_agent_id or data.session_id

  require("NeoAI.utils.logger").debug(
    "[DEBUG_DUP] on_generation_complete 进入: session=%s, gen_id=%s, data.gen_id=%s, tool_calls=%d, ss=%s",
    tostring(session_id),
    tostring(sessions_table[session_id] and sessions_table[session_id].generation_id),
    tostring(data.generation_id),
    #(data.tool_calls or {}),
    tostring(sessions_table[session_id] ~= nil)
  )

  local ss = sessions_table[session_id]
  if not ss or ss.generation_id ~= data.generation_id then
    require("NeoAI.utils.logger").debug(
      "[DEBUG_DUP] on_generation_complete 提前返回: ss=%s, ss.gen_id=%s, data.gen_id=%s",
      tostring(ss ~= nil),
      tostring(ss and ss.generation_id),
      tostring(data.generation_id)
    )
    return
  end

  local tool_calls = data.tool_calls or {}
  local content = data.content or ""

  -- 累积 usage
  local current_usage = data.usage or {}
  if current_usage and next(current_usage) then
    local acc = ss.accumulated_usage or {}
    acc.prompt_tokens = (acc.prompt_tokens or 0) + (current_usage.prompt_tokens or current_usage.input_tokens or 0)
    acc.completion_tokens = (acc.completion_tokens or 0)
      + (current_usage.completion_tokens or current_usage.output_tokens or 0)
    acc.total_tokens = (acc.total_tokens or 0) + (current_usage.total_tokens or 0)
    if current_usage.completion_tokens_details and type(current_usage.completion_tokens_details) == "table" then
      local rt = current_usage.completion_tokens_details.reasoning_tokens or 0
      if not acc.completion_tokens_details then
        acc.completion_tokens_details = {}
      end
      acc.completion_tokens_details.reasoning_tokens = (acc.completion_tokens_details.reasoning_tokens or 0) + rt
    end
    ss.accumulated_usage = acc
  end

  -- 过滤无效工具调用
  local valid_tool_calls = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name and func.name ~= "" then
      local args = func.arguments
      -- 尝试修复 arguments：如果是字符串，尝试 JSON 解析
      if type(args) == "string" then
        local ok, parsed = pcall(vim.json.decode, args)
        if ok and type(parsed) == "table" then
          func.arguments = parsed
          args = parsed
          logger.warn(
            "[tool_orchestrator] on_generation_complete: 工具 '%s' 的 arguments 为字符串，已解析为 table",
            func.name
          )
        else
          logger.warn(
            "[tool_orchestrator] on_generation_complete: 工具 '%s' 的 arguments 为无效 JSON 字符串，跳过该工具调用: %s",
            func.name,
            tostring(args):sub(1, 200)
          )
          goto continue
        end
      end
      -- 空 table {}（vim.empty_dict()）是无参数工具的合法参数，不应跳过
      if args ~= nil and type(args) == "table" and (next(args) ~= nil or vim.tbl_isempty(args)) then
        table.insert(valid_tool_calls, tc)
      else
        logger.warn(
          "[tool_orchestrator] on_generation_complete: 工具 '%s' 的 arguments 无效，跳过该工具调用: %s",
          func.name,
          tostring(args):sub(1, 200)
        )
      end
    end
    ::continue::
  end
  tool_calls = valid_tool_calls

  -- 子 agent 完成：AI 返回纯文本回复（无工具调用）
  if is_sub_agent and #tool_calls == 0 then
    local sub_agent_engine = require("NeoAI.core.ai.sub_agent_engine")
    sub_agent_engine._finalize_sub_agent(sub_agent_id, content)
    return
  end

  if ss.stop_requested then
    M._finish_loop(session_id, true, content, is_sub_agent)
    return
  end

  -- ===== 工具调用异常检测与重试 =====
  local abnormal, reason = request_handler.detect_abnormal_response(content, tool_calls, {
    is_tool_loop = true,
  })
  if abnormal then
    local retry_count = ss._tool_retry_count or 0
    if request_handler.can_retry(retry_count) then
      local new_retry_count = retry_count + 1
      ss._tool_retry_count = new_retry_count
      local delay = request_handler.get_retry_delay(new_retry_count)
      logger.warn(
        string.format(
          "[tool_orchestrator] 检测到异常工具调用 (重试 %d/%d): %s, 延迟 %dms 后重试",
          new_retry_count,
          request_handler.get_max_retries(),
          reason,
          delay
        )
      )
      vim.api.nvim_exec_autocmds("User", {
        pattern = event_constants.GENERATION_RETRYING,
        data = {
          generation_id = ss.generation_id,
          retry_count = new_retry_count,
          max_retries = request_handler.get_max_retries(),
          reason = reason,
          session_id = session_id,
          window_id = ss.window_id,
          layer = "tool_orchestrator",
        },
      })
      if #ss.messages > 0 then
        local last_msg = ss.messages[#ss.messages]
        if last_msg.role == "assistant" and last_msg.tool_calls then
          table.remove(ss.messages)
        end
      end
      vim.defer_fn(function()
        M._request_generation(session_id, is_sub_agent)
      end, delay)
      return
    else
      logger.warn(
        string.format(
          "[tool_orchestrator] 工具调用异常但重试已达上限 (%d/%d): %s",
          retry_count,
          request_handler.get_max_retries(),
          reason
        )
      )
      if reason and reason:find("空响应") then
        logger.warn("[tool_orchestrator] 空响应重试已达上限，触发生成错误")
        M._finish_loop(session_id, false, "AI 多次返回空响应", is_sub_agent)
        return
      end
    end
  end
  if ss then
    ss._tool_retry_count = 0
  end

  -- 中间轮次保存到 history_manager（仅主 agent）
  if not is_sub_agent then
    local hm_ok, hm = pcall(require, "NeoAI.core.history.manager")
    if hm_ok and hm.is_initialized() then
      local assistant_entry = { content = content }
      if data.reasoning and data.reasoning ~= "" then
        assistant_entry.reasoning_content = data.reasoning
      end
      hm.add_assistant_entry(session_id, assistant_entry)
      hm._mark_dirty()
    end
  end

  if #tool_calls == 0 then
    -- AI 返回纯文本回复，直接结束循环
    -- 重置 _tools_all_completed 标志，防止 _finish_loop 触发的 GENERATION_COMPLETED
    -- 事件监听器中的 _check_round_complete 错误地进入下一轮
    ss._tools_all_completed = false
    if #tool_calls == 0 and content and content ~= "" then
      logger.debug("[tool_orchestrator] AI 返回纯文本回复，直接结束循环，跳过总结轮次")
      local assistant_msg = {
        role = "assistant",
        content = content,
        timestamp = os.time(),
        window_id = ss.window_id,
      }
      if data.reasoning and data.reasoning ~= "" then
        assistant_msg.reasoning_content = data.reasoning
        ss.last_reasoning = data.reasoning
      end
      table.insert(ss.messages, assistant_msg)

      local saved_usage = ss.accumulated_usage or {}
      local saved_reasoning = ss.last_reasoning or ""
      local saved_win_id = ss.window_id
      local saved_gen_id = ss.generation_id
      local on_complete = ss.on_complete
      ss.on_complete = nil
      -- idle 状态由 TOOL_LOOP_FINISHED 监听器统一设置
      ss.active_tool_calls = {}
      ss.current_iteration = 0
      ss.generation_id = nil
      fire_loop_finished(ss, true, "ai_complete")
      return
    end

    if #tool_calls == 0 and (not content or content == "") then
      -- 空响应：直接结束
      logger.debug("[tool_orchestrator] AI 返回空响应，直接结束循环")
      local saved_usage = ss.accumulated_usage or {}
      local saved_reasoning = ss.last_reasoning or ""
      local saved_win_id = ss.window_id
      local saved_gen_id = ss.generation_id
      local on_complete = ss.on_complete
      ss.on_complete = nil
      -- idle 状态由 TOOL_LOOP_FINISHED 监听器统一设置
      ss.active_tool_calls = {}
      ss.current_iteration = 0
      ss.generation_id = nil
      fire_loop_finished(ss, true, "ai_complete")
      once_display_closed(session_id, function()
        local s = sessions_table[session_id]
        if not s then
          return
        end
        if is_shutting_down() then
          return
        end
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = event_constants.GENERATION_COMPLETED,
          data = {
            generation_id = saved_gen_id,
            response = "",
            reasoning_text = saved_reasoning,
            usage = saved_usage,
            session_id = session_id,
            window_id = saved_win_id,
            duration = 0,
          },
        })
        if on_complete then
          on_complete(true, "", saved_usage)
        end
      end)
      return
    end

    M._finish_loop(session_id, true, content, is_sub_agent)
    return
  end

  -- 继续工具循环
  local assistant_msg = {
    role = "assistant",
    content = content,
    timestamp = os.time(),
    window_id = ss.window_id,
  }
  if data.reasoning and data.reasoning ~= "" then
    assistant_msg.reasoning_content = data.reasoning
    ss.last_reasoning = data.reasoning
  end
  if #tool_calls > 0 then
    assistant_msg.tool_calls = tool_calls
  end
  table.insert(ss.messages, assistant_msg)

  ss.current_iteration = ss.current_iteration + 1

  -- 标记 AI 生成已完成（用于双事件等待机制）
  -- 注意：必须在工具执行前设置，这样工具完成后 _check_round_complete 才能检测到两个事件都已到达
  ss._generation_completed = true

  fire_loop_finished(ss, false, "ai_complete")
  once_display_closed(session_id, function()
    local s = sessions_table[session_id]
    if not s then
      return
    end
    if is_shutting_down() then
      return
    end
    if s.stop_requested then
      logger.debug(
        "[tool_orchestrator] on_generation_complete: once_display_closed 回调中检测到 stop_requested，跳过工具执行"
      )
      return
    end
    M._execute_tools(session_id, tool_calls, is_sub_agent)
  end)
end

--- @deprecated 已移至 tool_executor
--- 计算两个字符串的编辑距离（Levenshtein）
--- @param s1 string
--- @param s2 string
--- @return number
local function _levenshtein(s1, s2)
  local len1 = #s1
  local len2 = #s2
  local matrix = {}
  for i = 0, len1 do
    matrix[i] = { [0] = i }
  end
  for j = 0, len2 do
    matrix[0][j] = j
  end
  for i = 1, len1 do
    for j = 1, len2 do
      local cost = s1:sub(i, i) == s2:sub(j, j) and 0 or 1
      matrix[i][j] = math.min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + cost)
    end
  end
  return matrix[len1][len2]
end

--- @deprecated 已移至 tool_executor._normalize_tool_name
--- 模糊匹配工具名称
--- 当模型调用了不存在的工具时，尝试找到最相似的工具
--- 新代码请使用 tool_executor._normalize_tool_name()
--- @param input string 模型输入的工具名称
--- @param all_names string[] 所有可用工具名称列表
--- @return string|nil 最匹配的工具名称，或 nil
function M._fuzzy_match_tool(input, all_names)
  if not input or not all_names or #all_names == 0 then
    return nil
  end

  local input_lower = input:lower()

  -- 1) 精确匹配（忽略大小写）
  for _, name in ipairs(all_names) do
    if name:lower() == input_lower then
      return name
    end
  end

  -- 2) 前缀匹配
  local prefix_matches = {}
  for _, name in ipairs(all_names) do
    if name:lower():find(input_lower, 1, true) == 1 then
      table.insert(prefix_matches, name)
    elseif input_lower:find(name:lower(), 1, true) == 1 then
      table.insert(prefix_matches, name)
    end
  end
  if #prefix_matches == 1 then
    return prefix_matches[1]
  end

  -- 3) 子串匹配
  local substr_matches = {}
  for _, name in ipairs(all_names) do
    if name:lower():find(input_lower, 1, true) then
      table.insert(substr_matches, name)
    end
  end
  if #substr_matches == 1 then
    return substr_matches[1]
  end

  -- 4) 单词匹配（按 _ 或 - 分割）
  local input_parts = {}
  for part in input_lower:gmatch("[%w_]+") do
    table.insert(input_parts, part)
  end
  local best_score = 0
  local best_name = nil
  for _, name in ipairs(all_names) do
    local name_lower = name:lower()
    local score = 0
    for _, part in ipairs(input_parts) do
      if name_lower == part then
        score = score + 10
      elseif name_lower:find(part, 1, true) then
        score = score + 5
      end
    end
    if score > best_score then
      best_score = score
      best_name = name
    end
  end

  if best_score > 0 then
    return best_name
  end

  -- 5) 编辑距离匹配（处理拼写错误）
  local best_dist = math.huge
  local best_dist_name = nil
  local input_len = #input_lower
  for _, name in ipairs(all_names) do
    local name_lower = name:lower()
    -- 只考虑长度差异不超过 50% 的
    local len_diff = math.abs(#name_lower - input_len)
    if len_diff <= math.max(#name_lower, input_len) * 0.5 then
      local dist = _levenshtein(input_lower, name_lower)
      -- 编辑距离不超过名称长度的 40%
      local max_len = math.max(#name_lower, input_len)
      if dist <= max_len * 0.4 and dist < best_dist then
        best_dist = dist
        best_dist_name = name
      end
    end
  end

  if best_dist_name then
    return best_dist_name
  end

  return nil
end

function M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result, is_sub_agent)
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local ss = sessions_table[session_id]
  if not ss then
    return
  end

  local safe_id = tool_call_id or ("call_" .. os.time() .. "_" .. math.random(10000, 99999))
  local result_str = type(result) == "string" and result
    or (result ~= nil and pcall(vim.json.encode, result) and vim.json.encode(result) or tostring(result))
    or ""

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

  -- 工具结果实时持久化到 history_manager（由 tool_executor 统一保存）
  -- tool_executor 的 on_success_wrapper/on_error_wrapper 中已调用 _save_tool_result_to_history
  -- 此处不再重复保存，避免竞态和重复
  -- 注意：_add_tool_result_to_messages 只负责将工具结果加入 ss.messages（AI 请求上下文）
  -- 持久化由 tool_executor 集中处理
end

-- ========== 结束循环 ==========

function M._finish_loop(session_id, success, result, is_sub_agent)
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local ss = sessions_table[session_id]
  if not ss then
    return
  end

  -- 子 agent 完成：直接结束，不触发总结轮次
  if is_sub_agent then
    local sub_agent_engine = require("NeoAI.core.ai.sub_agent_engine")
    sub_agent_engine._finalize_sub_agent(session_id, result or "")
    return
  end

  -- 检查是否所有会话都已空闲
  local all_idle = true
  for _, s in pairs(state.sessions) do
    if s.phase ~= "idle" then
      all_idle = false
      break
    end
  end
  if all_idle and _stop_listener_id then
    pcall(vim.api.nvim_del_autocmd, _stop_listener_id)
    _stop_listener_id = nil
  end

  -- 先触发 TOOL_LOOP_FINISHED（is_round_end=true），由监听器统一设置 idle 状态
  fire_loop_finished(ss, true, "tools_complete")

  -- 第二次调用 _finish_loop（on_complete 已被消费）
  if ss.on_complete == nil then
    local saved_gen_id = ss.generation_id
    local saved_win_id = ss.window_id
    local saved_usage = ss.accumulated_usage or {}
    local saved_reasoning = ss.last_reasoning or ""
    local saved_result = result or ""

    -- idle 状态由 TOOL_LOOP_FINISHED 监听器统一设置
    ss.active_tool_calls = {}
    ss.current_iteration = 0
    ss.generation_id = nil
    ss._generation_completed = false
    ss._tools_all_completed = false

    if not is_shutting_down() then
      vim.schedule(function()
        if is_shutting_down() then
          return
        end
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = event_constants.GENERATION_COMPLETED,
          data = {
            generation_id = saved_gen_id,
            response = saved_result,
            reasoning_text = "",
            usage = saved_usage,
            session_id = session_id,
            window_id = saved_win_id,
            duration = 0,
          },
        })
      end)
    end
    return
  end

  local on_complete = ss.on_complete
  local saved_usage = ss.accumulated_usage or {}
  local saved_generation_id = ss.generation_id
  local saved_window_id = ss.window_id
  local saved_reasoning = ss.last_reasoning or ""
  local saved_result = result or ""

  ss.on_complete = nil
  -- idle 状态由 TOOL_LOOP_FINISHED 监听器统一设置
  ss.active_tool_calls = {}
  ss.current_iteration = 0
  ss.generation_id = nil
  ss._generation_completed = false
  ss._tools_all_completed = false

  -- 调用 on_complete 回调，通知调用方循环已结束
  if on_complete then
    vim.schedule(function()
      if is_shutting_down() then
        return
      end
      on_complete(true, saved_result, saved_usage)
    end)
  end

  -- 触发 GENERATION_COMPLETED 事件
  if not is_shutting_down() then
    vim.schedule(function()
      if is_shutting_down() then
        return
      end
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.GENERATION_COMPLETED,
        data = {
          generation_id = saved_generation_id,
          response = saved_result,
          reasoning_text = "",
          usage = saved_usage,
          session_id = session_id,
          window_id = saved_window_id,
          duration = 0,
        },
      })
    end)
  end
end

-- ========== 停止控制 ==========

function M.request_stop(session_id)
  if session_id then
    -- 同时检查主 agent 和子 agent 会话
    local ss = state.sessions[session_id] or state.sub_agent_sessions[session_id]
    if ss then
      ss.stop_requested = true
      if next(ss.active_tool_calls) ~= nil then
        ss.active_tool_calls = {}
        vim.schedule(function()
          M._on_tools_complete(session_id, ss._is_sub_agent)
        end)
      end
    end
  else
    for sid, _ in pairs(state.sessions) do
      M.request_stop(sid)
    end
    for sid, _ in pairs(state.sub_agent_sessions) do
      M.request_stop(sid)
    end
  end
end

function M.is_stop_requested(session_id)
  if session_id then
    local ss = state.sessions[session_id] or state.sub_agent_sessions[session_id]
    return ss and ss.stop_requested or false
  end
  for _, ss in pairs(state.sessions) do
    if ss.stop_requested then
      return true
    end
  end
  for _, ss in pairs(state.sub_agent_sessions) do
    if ss.stop_requested then
      return true
    end
  end
  return false
end

function M.reset_stop_requested(session_id)
  if session_id then
    local ss = state.sessions[session_id] or state.sub_agent_sessions[session_id]
    if ss then
      ss.stop_requested = false
    end
  else
    for _, ss in pairs(state.sessions) do
      ss.stop_requested = false
    end
    for _, ss in pairs(state.sub_agent_sessions) do
      ss.stop_requested = false
    end
  end
end

-- ========== 工具管理 ==========

function M.set_tools(tools)
  _tools = tools or {}
end

function M.get_tools()
  return _tools or {}
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
    if ss then
      ss.current_iteration = 0
    end
  else
    for _, ss in pairs(state.sessions) do
      ss.current_iteration = 0
    end
  end
end

-- ========== 单次工具请求（不计入工具循环） ==========

--- @deprecated 已移至 tool_executor.register_tool_for_request
--- 临时注册一个工具到 tool_registry，供 execute_single_tool_request 使用
--- 返回一个清理函数，调用后移除该工具
--- 新代码请使用 tool_executor.register_tool_for_request()
--- @param tool_name string 工具名称
--- @return function|nil 清理函数，调用后移除工具；注册失败返回 nil
function M.register_tool_for_request(tool_name)
  -- 从 shell_tools 模块获取工具定义
  local ok, shell_tools = pcall(require, "NeoAI.tools.builtin.shell_tools")
  if not ok or not shell_tools then
    logger.warn("[tool_orchestrator] register_tool_for_request: 无法加载 shell_tools 模块")
    return nil
  end

  local tool_def = shell_tools[tool_name]
  if not tool_def or type(tool_def) ~= "table" or not tool_def.name or not tool_def.func then
    logger.warn("[tool_orchestrator] register_tool_for_request: 工具 '%s' 未在 shell_tools 中找到", tool_name)
    return nil
  end

  -- 注册到 tool_registry
  local tool_registry = require("NeoAI.tools.tool_registry")
  pcall(tool_registry.initialize, {})

  -- 如果已存在，先移除再重新注册（确保使用最新定义）
  if tool_registry.exists(tool_name) then
    tool_registry.unregister(tool_name)
  end

  local ok2, err = pcall(tool_registry.register, tool_def)
  if not ok2 then
    logger.warn("[tool_orchestrator] register_tool_for_request: 注册工具 '%s' 失败: %s", tool_name, tostring(err))
    return nil
  end

  logger.debug("[tool_orchestrator] register_tool_for_request: 已临时注册工具 '%s'", tool_name)

  -- 返回清理函数
  return function()
    pcall(tool_registry.unregister, tool_name)
    logger.debug("[tool_orchestrator] register_tool_for_request: 已移除临时工具 '%s'", tool_name)
  end
end

--- @deprecated 已移至 tool_executor.execute_single_tool_request
--- 执行一次非流式 AI 请求，只允许调用指定的工具，不计入工具循环
--- 用于 shell 交互式命令的自动输入场景
--- 新代码请使用 tool_executor.execute_single_tool_request()
--- @param session_id string 会话 ID
--- @param tool_name string 允许调用的工具名称（如 "send_input"）
--- @param args table 工具参数，支持以下字段：
---   - fixed_args (可选): table，这些参数不会暴露给 AI 的工具定义，
---     但在 AI 返回工具调用时会自动合并到参数中（用于程序自动注入的参数，如 session_id）
--- @param callback function 回调函数，接收 (success, result)
function M.execute_single_tool_request(session_id, tool_name, args, callback)
  -- 提取 fixed_args（不暴露给 AI 的固定参数）
  local fixed_args = args and args.fixed_args or {}
  if args then
    args.fixed_args = nil
  end

  -- 参数检查
  if not session_id then
    logger.warn("[tool_orchestrator] execute_single_tool_request: session_id 为空")
    if callback then
      callback(false, "session_id 为空")
    end
    return
  end
  if not tool_name or tool_name == "" then
    logger.warn("[tool_orchestrator] execute_single_tool_request: tool_name 为空")
    if callback then
      callback(false, "tool_name 为空")
    end
    return
  end
  if not callback then
    logger.warn("[tool_orchestrator] execute_single_tool_request: callback 为空，工具调用结果将无法返回")
  end

  local ss = state.sessions[session_id]
  if not ss then
    if callback then
      callback(false, "会话不存在")
    end
    return
  end

  -- 构建只包含指定工具的消息
  -- 注意：过滤掉带 tool_calls 的 assistant 消息及其对应的 tool 消息，
  -- 避免 API 报错 'assistant message with tool_calls must be followed by tool messages'
  -- 或 'tool message without matching tool_calls'
  local messages = {}
  local skip_tool_call_ids = {}
  for _, msg in ipairs(ss.messages or {}) do
    -- 记录需要跳过的 tool_call_id
    if msg.role == "assistant" and msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        skip_tool_call_ids[tc.id or tc.tool_call_id] = true
      end
      goto continue
    end
    -- 跳过对应被过滤 assistant 消息的 tool 消息
    if msg.role == "tool" and msg.tool_call_id and skip_tool_call_ids[msg.tool_call_id] then
      goto continue
    end
    table.insert(messages, vim.deepcopy(msg))
    ::continue::
  end

  -- 防御性修复：将过滤后仍可能存在的孤立 tool 消息转为 user 消息
  -- 这些 tool 消息的 tool_call_id 在剩余消息中没有对应的 assistant tool_calls
  -- 会导致 API 报错 'tool message without matching tool_calls'
  do
    -- 收集剩余 assistant 消息中声明的 tool_call_id
    local remaining_tool_call_ids = {}
    for _, msg in ipairs(messages) do
      if msg.role == "assistant" and msg.tool_calls then
        for _, tc in ipairs(msg.tool_calls) do
          local tc_id = tc.id or tc.tool_call_id
          if tc_id then
            remaining_tool_call_ids[tc_id] = true
          end
        end
      end
    end
    -- 将没有对应 tool_call_id 的 tool 消息转为 user
    local fixed_count = 0
    for _, msg in ipairs(messages) do
      if msg.role == "tool" then
        local is_orphan = false
        if msg.tool_call_id and msg.tool_call_id ~= "" then
          if not remaining_tool_call_ids[msg.tool_call_id] then
            is_orphan = true
          end
        else
          is_orphan = true
        end
        if is_orphan then
          msg.role = "user"
          msg.tool_call_id = nil
          msg.name = nil
          fixed_count = fixed_count + 1
        end
      end
    end
    if fixed_count > 0 then
      logger.debug(
        "[tool_orchestrator] execute_single_tool_request: 防御性修复 %d 条孤立 tool 消息",
        fixed_count
      )
    end
  end

  -- 添加系统提示，要求 AI 使用指定工具
  -- 提供完整的上下文：执行的命令、当前输出、以及明确的指令
  local cmd_context = args.command or ""
  local stdout_content = args.stdout or args.prompt or ""
  local stderr_content = args.stderr or ""
  local combined_output = stdout_content
  if stderr_content and stderr_content ~= "" then
    combined_output = combined_output .. "\n[stderr]\n" .. stderr_content
  end

  -- 分析最后几行输出，判断最可能的输入类型
  local last_lines = {}
  for line in (combined_output .. ""):gmatch("[^\n]+") do
    table.insert(last_lines, line)
    if #last_lines > 5 then
      table.remove(last_lines, 1)
    end
  end
  local last_line = last_lines[#last_lines] or ""

  -- 根据最后一行内容推断输入类型
  local input_guidance = ""
  if
    last_line:match("[Yy]es/[Nn]o")
    or last_line:match("[Yy]/[Nn]")
    or last_line:match("%%[Y/n%%]")
    or last_line:match("%%[y/N%%]")
  then
    input_guidance = "\n提示：命令正在询问 yes/no 确认，请根据上下文输入 'y' 或 'n'。"
  elseif last_line:match("[Pp]assword:") or last_line:match("密码:") then
    input_guidance = "\n提示：命令正在询问密码，请输入密码。"
  elseif
    last_line:match("[Ss]elect")
    or last_line:match("[Cc]hoose")
    or last_line:match("[Oo]ption")
    or last_line:match("[Nn]umber")
    or last_line:match("#%?[%s]*$")
  then
    input_guidance =
      "\n提示：命令正在显示菜单选项，请根据选项列表输入对应的编号或关键字。"
  elseif
    last_line:match("[Ee]nter your")
    or last_line:match("[Ii]nput your")
    or last_line:match("[Pp]lease enter")
    or last_line:match("[Pp]lease input")
    or last_line:match("请输入")
  then
    input_guidance =
      "\n提示：命令正在要求输入文本内容（如用户名、名称等），请输入合适的文本。"
  elseif
    last_line:match("[Cc]ontinue")
    or last_line:match("[Pp]ress any key")
    or last_line:match("[Pp]ress Enter")
    or last_line:match("按 Enter 键继续")
  then
    input_guidance = "\n提示：命令正在等待按任意键继续，请直接发送空字符串或按 Enter。"
  elseif last_line:match("> %s*$") or last_line:match(": %s*$") or last_line:match("#?%s*$") then
    input_guidance = "\n提示：命令正在等待输入，请根据上下文输入合适的内容。"
  end

  local system_msg = {
    role = "system",
    content = string.format(
      "你正在与一个交互式 shell 命令交互。命令当前正在等待输入。\n"
        .. "执行的命令: %s\n\n"
        .. "请仔细分析命令当前输出的**最后一行**，它指示了需要输入的内容类型。\n"
        .. '1. 如果最后一行是 "请输入你的名字:"、"Enter your name:" 等，输入对应的文本内容（如用户名）\n'
        .. "2. 如果最后一行是 \"y/n\"、\"Yes/No\" 等，输入 'y' 或 'n'\n"
        .. '3. 如果最后一行是 "Password:" 或包含 "密码"，输入密码\n'
        .. '4. 如果最后一行是菜单选项（如 "#?"、"Select"），根据选项列表输入对应的编号\n'
        .. '5. 如果最后一行包含 "按 Enter 键继续"、"Press Enter" 等，发送 \'<enter>\' 即可（只发送回车键）\n'
        .. "6. 如果需要选择菜单项（如上下方向键），使用 '<up>'、'<down>'、'<enter>' 等特殊按键标记\n"
        .. "7. 如果需要中断命令（如 Ctrl+C），发送 '<ctrl_c>'\n"
        .. "8. 如果命令已执行完毕或不需要继续执行，请调用 %s 工具并设置 stop=true 来终止进程\n\n"
        .. "=== 特殊按键标记说明 ===\n"
        .. "  <enter> - 回车确认（Enter 键）\n"
        .. "  <up> - 上方向键\n"
        .. "  <down> - 下方向键\n"
        .. "  <left> - 左方向键\n"
        .. "  <right> - 右方向键\n"
        .. "  <ctrl_c> - Ctrl+C（中断）\n"
        .. "  <ctrl_d> - Ctrl+D（EOF）\n"
        .. "  <tab> - Tab 键\n"
        .. "  <escape> - Escape 键\n"
        .. "  <backspace> - Backspace 键\n"
        .. "你可以组合使用这些标记，例如 '<down><down><enter>' 表示按两次下方向键后按回车。\n"
        .. "=== 命令当前输出 ===\n%s%s",
      cmd_context,
      tool_name,
      combined_output,
      input_guidance
    ),
  }
  table.insert(messages, system_msg)

  -- 构建工具定义（只包含允许调用的工具）
  -- 从 tool_registry 获取。调用方需在使用前通过 register_tool_for_request
  -- 临时注册 send_input、check_shell_timeout 等非公开工具。
  local tool_def = nil
  local tool_registry = require("NeoAI.tools.tool_registry")
  pcall(tool_registry.initialize, {})
  local registered_tool = tool_registry.get(tool_name)

  if registered_tool then
    local tf = {
      name = registered_tool.name,
      description = registered_tool.description or ("执行 " .. registered_tool.name .. " 操作"),
    }
    if
      registered_tool.parameters
      and type(registered_tool.parameters) == "table"
      and registered_tool.parameters.properties
    then
      -- 复制 properties 并移除 fixed_args 中的字段（不暴露给 AI）
      local filtered_properties = {}
      for k, v in pairs(registered_tool.parameters.properties) do
        if not fixed_args[k] then
          filtered_properties[k] = vim.deepcopy(v)
        end
      end
      local cp = { type = "object", properties = filtered_properties }
      if
        registered_tool.parameters.required
        and type(registered_tool.parameters.required) == "table"
        and #registered_tool.parameters.required > 0
      then
        -- 同样过滤 required 中的 fixed_args 字段
        local filtered_required = {}
        for _, field in ipairs(registered_tool.parameters.required) do
          if not fixed_args[field] then
            table.insert(filtered_required, field)
          end
        end
        if #filtered_required > 0 then
          cp.required = filtered_required
        end
      end
      tf.parameters = cp
    end
    tool_def = { type = "function", ["function"] = tf }
  end

  -- 回退：从闭包 tools 查找
  if not tool_def then
    local tools = _tools or {}
    for _, t in ipairs(tools) do
      if t.name == tool_name then
        local tf = { name = t.name, description = t.description or ("执行 " .. t.name .. " 操作") }
        if t.parameters and type(t.parameters) == "table" and t.parameters.properties then
          -- 复制 properties 并移除 fixed_args 中的字段（不暴露给 AI）
          local filtered_properties = {}
          for k, v in pairs(t.parameters.properties) do
            if not fixed_args[k] then
              filtered_properties[k] = vim.deepcopy(v)
            end
          end
          local cp = { type = "object", properties = filtered_properties }
          if t.parameters.required and type(t.parameters.required) == "table" and #t.parameters.required > 0 then
            -- 同样过滤 required 中的 fixed_args 字段
            local filtered_required = {}
            for _, field in ipairs(t.parameters.required) do
              if not fixed_args[field] then
                table.insert(filtered_required, field)
              end
            end
            if #filtered_required > 0 then
              cp.required = filtered_required
            end
          end
          tf.parameters = cp
        end
        tool_def = { type = "function", ["function"] = tf }
        break
      end
    end
  end

  if not tool_def then
    if callback then
      callback(false, "工具定义未找到: " .. tool_name)
    end
    return
  end

  -- 构建非流式请求
  -- 注意：强制工具调用时禁用思考模式（DeepSeek 等 API 不支持思考模式下的强制工具调用）
  local request_handler = require("NeoAI.core.ai.request_handler")
  local formatted = request_handler.format_messages(messages)

  local http_utils = require("NeoAI.utils.http_utils")
  local ai_preset = ss.ai_preset or {}

  local request = request_handler.build_request({
    messages = formatted,
    options = vim.tbl_extend("force", ss.options or {}, {
      model = (ss.ai_preset or {}).model_name or (ss.options or {}).model,
      stream = false,
      tools_enabled = true,
      -- 强制工具调用时禁用思考模式
      reasoning_enabled = false,
    }),
    session_id = session_id,
    generation_id = "single_tool_" .. session_id .. "_" .. os.time(),
  })

  -- 覆盖 build_request 可能从 state.tool_definitions 设置的 tools，只保留指定工具
  request.tools = { tool_def }
  -- 使用指定工具模式（强制调用指定工具）
  request.tool_choice = { type = "function", ["function"] = { name = tool_name } }
  -- 防御性清除 extra_body 中的 thinking 字段（思考模式下不支持强制工具调用）
  if request.extra_body and request.extra_body.thinking then
    local thinking_type = type(request.extra_body.thinking) == "table" and request.extra_body.thinking.type or ""
    if thinking_type == "enabled" then
      request.extra_body.thinking.type = "disabled"
    end
    request.extra_body.reasoning_effort = nil
  end

  -- 构建 http_utils 参数
  local http_params = {
    request = request,
    generation_id = request.generation_id,
    base_url = ai_preset.base_url,
    api_key = ai_preset.api_key,
    api_type = ai_preset.api_type or "openai",
    provider_config = ai_preset,
  }

  -- 调试日志：输出最终请求的 model 和 thinking 状态
  local thinking_status = "unknown"
  if request.extra_body and request.extra_body.thinking then
    thinking_status = type(request.extra_body.thinking) == "table" and (request.extra_body.thinking.type or "no_type")
      or tostring(request.extra_body.thinking)
  end
  logger.debug(
    "[tool_orchestrator] execute_single_tool_request 最终请求: model=%s, thinking.type=%s",
    request.model or "nil",
    thinking_status
  )

  -- 如果调用方要求禁用思考模式，传递标记
  if args and args._disable_reasoning then
    http_params._disable_reasoning = true
  end

  -- 使用异步请求，避免阻塞主线程（否则 UI 更新和停止快捷键都会失效）
  -- 回调函数在 jobstart 的 on_exit 中通过 vim.schedule 调用
  local _callback = callback
  -- 重试计数器
  local max_retries = 3
  local retry_delay_ms = 1000
  local retry_count = 0

  local function do_request()
    http_utils.send_request_async(http_params, function(response, err)
      -- 检查会话是否已被停止
      local current_ss = state.sessions[session_id]
      if not current_ss or current_ss.stop_requested then
        if _callback then
          _callback(false, "会话已停止")
        end
        return
      end

      if err then
        -- 自动重试（最多 3 次）
        if retry_count < max_retries then
          retry_count = retry_count + 1
          logger.warn(
            "[tool_orchestrator] execute_single_tool_request 请求失败 (重试 %d/%d): %s | request_model=%s | request_messages_count=%d",
            retry_count,
            max_retries,
            tostring(err),
            request.model or "nil",
            request.messages and #request.messages or 0
          )
          vim.defer_fn(do_request, retry_delay_ms)
          return
        end
        if _callback then
          _callback(false, "AI 请求失败: " .. tostring(err))
        end
        return
      end

      if not response or not response.choices or #response.choices == 0 then
        -- 自动重试
        if retry_count < max_retries then
          retry_count = retry_count + 1
          logger.warn(
            "[tool_orchestrator] execute_single_tool_request 响应无效 (重试 %d/%d)",
            retry_count,
            max_retries
          )
          vim.defer_fn(do_request, retry_delay_ms)
          return
        end
        if _callback then
          _callback(false, "AI 响应无效")
        end
        return
      end

      local choice = response.choices[1]
      local message = choice.message or {}

      -- 检查是否有工具调用
      if message.tool_calls and #message.tool_calls > 0 then
        local tc = message.tool_calls[1]
        local func = tc["function"] or tc.func
        if func and func.name == tool_name then
          -- arguments 已在 http_client 中解析为 Lua table
          local parsed_args = func.arguments or {}
          if type(parsed_args) == "table" then
            -- 自动合并 fixed_args（程序注入的参数，AI 不可见）
            for k, v in pairs(fixed_args) do
              parsed_args[k] = v
            end
            if _callback then
              _callback(true, { action = "send_input", args = parsed_args })
            end
            return
          end
        end
      end

      -- 检查 AI 是否回复了 ABORT 或类似内容
      local content = message.content or ""
      if content:upper():match("ABORT") or content:upper():match("CANCEL") or content:upper():match("STOP") then
        if _callback then
          _callback(true, { action = "abort", reason = content })
        end
        return
      end

      -- 默认：将 AI 的文本回复作为输入内容
      if content and content ~= "" then
        if _callback then
          _callback(true, { action = "send_input", args = { input = content } })
        end
        return
      end

      -- 无法决定时，安全地结束
      if _callback then
        _callback(true, { action = "abort", reason = "AI 无法决定输入内容" })
      end
    end)
  end

  -- 发起首次请求
  do_request()
end

--- 获取会话状态（供外部模块直接操作，如 cancel_generation）
--- @param session_id string
--- @return table|nil
function M.get_session_state(session_id)
  return state.sessions[session_id] or state.sub_agent_sessions[session_id]
end

--- 获取所有会话ID列表（包括子 agent）
--- @return table string[]
function M.get_all_session_ids()
  local ids = {}
  for sid, _ in pairs(state.sessions) do
    table.insert(ids, sid)
  end
  for sid, _ in pairs(state.sub_agent_sessions) do
    table.insert(ids, sid)
  end
  return ids
end

function M.is_executing(session_id)
  if session_id then
    local ss = state.sessions[session_id] or state.sub_agent_sessions[session_id]
    if not ss then
      return false
    end
    return ss.phase == "waiting_tools" or ss.phase == "waiting_model"
  end
  for _, ss in pairs(state.sessions) do
    if ss.phase == "waiting_tools" or ss.phase == "waiting_model" then
      return true
    end
  end
  for _, ss in pairs(state.sub_agent_sessions) do
    if ss.phase == "waiting_tools" or ss.phase == "waiting_model" then
      return true
    end
  end
  return false
end

-- ========== 关闭清理 ==========

function M.shutdown()
  if _stop_listener_id then
    pcall(vim.api.nvim_del_autocmd, _stop_listener_id)
    _stop_listener_id = nil
  end
  for session_id, _ in pairs(state.sessions) do
    M.unregister_session(session_id)
  end
  for sub_agent_id, _ in pairs(state.sub_agent_sessions) do
    M.unregister_sub_agent_session(sub_agent_id)
  end
  state.sessions = {}
  state.sub_agent_sessions = {}
  _tools = {}
  state.initialized = false
end

--- 重置（测试用）
function M._test_reset()
  state.initialized = false
  state.sessions = {}
  state.sub_agent_sessions = {}
  state.config = {}
  _tools = {}
end

--- 紧急清理（VimLeavePre 中使用）
function M.cleanup_all()
  if _stop_listener_id then
    pcall(vim.api.nvim_del_autocmd, _stop_listener_id)
    _stop_listener_id = nil
  end

  for _, ss in pairs(state.sessions) do
    ss.stop_requested = true
    ss.phase = "idle"
    ss.active_tool_calls = {}
    ss.current_iteration = 0
    ss.generation_id = nil
    ss._tools_complete_in_progress = false
    ss._proceed_in_progress = false
  end
  for _, ss in pairs(state.sub_agent_sessions) do
    ss.stop_requested = true
    ss.phase = "idle"
    ss.active_tool_calls = {}
    ss.current_iteration = 0
    ss.generation_id = nil
    ss._tools_complete_in_progress = false
    ss._proceed_in_progress = false
  end

  pcall(function()
    local http_ok, http_utils = pcall(require, "NeoAI.utils.http_utils")
    if http_ok and http_utils and http_utils.cancel_all_requests then
      http_utils.cancel_all_requests()
    end
  end)

  for session_id, _ in pairs(state.sessions) do
    M.unregister_session(session_id)
  end
  for sub_agent_id, _ in pairs(state.sub_agent_sessions) do
    M.unregister_sub_agent_session(sub_agent_id)
  end

  state.sessions = {}
  state.sub_agent_sessions = {}
  _tools = {}
end

return M
