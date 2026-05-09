-- 循环调用管理器（事件驱动架构）
-- 负责管理 AI 工具调用的循环执行
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

local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local tool_pack = require("NeoAI.tools.tool_pack")
local shutdown_flag = require("NeoAI.core.shutdown_flag")
local response_retry = require("NeoAI.core.ai.response_retry")
local state_manager = require("NeoAI.core.config.state")
local sub_agent_engine = require("NeoAI.core.ai.sub_agent_engine")
local plan_executor = require("NeoAI.tools.builtin.plan_executor")

-- ========== 状态 ==========

local _tools = {}

local state = {
  initialized = false,
  config = nil,
  max_iterations = 20,
  sessions = {},
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
  vim.schedule(function()
    -- 检查是否正在退出，避免在退出过程中执行回调导致卡死
    if is_shutting_down() then
      return
    end
    callback()
  end)
end

--- 触发 TOOL_LOOP_FINISHED 事件
--- 使用 pcall 保护，避免在 fast event 上下文中调用失败
local function fire_loop_finished(ss)
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
        },
      })
    end)
  end
end

--- 触发 TOOL_RESULT_RECEIVED 事件
--- 使用 pcall 保护，避免在 fast event 上下文中调用失败
local function fire_tool_result_received(ss, is_final_round)
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
      is_final_round = is_final_round or false,
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
    user_cancelled = false, -- 用户主动取消标志，为 true 时不触发总结
    _skip_summary = false, -- 跳过总结轮次标志（由 generate_summary=false 触发）
    _tool_retry_count = 0, -- 工具调用重试计数
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
  state.max_iterations = state.config.max_tool_iterations or 20
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
        -- 注意：总结轮次（_summary_in_progress）时，_finalize_generation 中
        -- generation.accumulated_usage 已包含历史累积 + 当前轮次 usage，
        -- 直接赋值给 s.accumulated_usage 即可，避免重复累加
        if data.usage and next(data.usage) then
          if s._summary_in_progress then
            -- 总结轮次：_finalize_generation 中的 accumulated_usage 已包含完整历史
            s.accumulated_usage = vim.deepcopy(data.usage)
          else
            -- 普通轮次：逐轮累加 usage
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
              acc.completion_tokens_details.reasoning_tokens = (acc.completion_tokens_details.reasoning_tokens or 0)
                + rt
            end
            s.accumulated_usage = acc
          end
        end
        if data.reasoning_text and data.reasoning_text ~= "" then
          s.last_reasoning = data.reasoning_text
        end

        -- 总结轮次完成：清理状态，不再触发 GENERATION_COMPLETED 事件
        -- _finalize_generation 已触发 GENERATION_COMPLETED 事件，chat_window 已处理
        if s._summary_in_progress then
          s._summary_in_progress = false
          s.phase = "idle"
          s.active_tool_calls = {}
          s.current_iteration = 0
          s.generation_id = nil
          return
        end

        M._check_round_complete(session_id)
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
  -- 工具执行路径（_execute_tools → _execute_single_tool → execute_async）
  -- 通过 vim.schedule 调度，不在协程上下文中，因此需要手动恢复
  local coroutine_ctx = state_manager.get_current_context()

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
  ss._coroutine_ctx = coroutine_ctx -- 保存协程上下文，供工具执行路径恢复

  ss.current_iteration = 1
  ss._tool_retry_count = 0 -- 新循环开始时重置重试计数

  -- 工具包分组信息已由 _execute_tools 中的 TOOL_LOOP_STARTED 事件携带
  -- 这里不再调用 fire_loop_started，避免重复触发

  -- 注册全局 ESC 停止监听器（仅在循环开始时注册一次）
  -- 确保工具调用和循环过程中按 ESC 能立即停止
  if not _stop_listener_id then
    _stop_listener_id = vim.api.nvim_create_autocmd("User", {
      pattern = event_constants.CANCEL_GENERATION,
      callback = function()
        -- 停止所有会话的工具循环
        for sid, _ in pairs(state.sessions) do
          local s = state.sessions[sid]
          if s then
            s.stop_requested = true
            s.user_cancelled = true -- 标记为用户取消，不触发总结
            s.active_tool_calls = {}
          end
        end
        -- 清理所有活跃的 HTTP 请求
        local http_client = require("NeoAI.core.ai.http_client")
        http_client.cancel_all_requests()
      end,
    })
  end

  M._execute_tools(session_id, params.tool_calls or {})
end

-- ========== 工具执行 ==========

function M._execute_tools(session_id, tool_calls)
  local ss = state.sessions[session_id]
  if not ss then
    return
  end

  -- 如果已请求停止，跳过所有工具执行
  if ss.stop_requested then
    return
  end

  if #tool_calls == 0 then
    -- 即使没有工具调用也刷新 UI，确保生成状态可见
    vim.schedule(function()
      M._request_generation(session_id)
    end)
    return
  end

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
    M._execute_single_tool(session_id, tc)
  end
end

function M._execute_single_tool(session_id, tool_call)
  local ss = state.sessions[session_id]
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

  -- 生成唯一 tool_call_id
  if not M._tool_call_counter then
    M._tool_call_counter = 0
  end
  M._tool_call_counter = M._tool_call_counter + 1
  local tool_call_id = tool_call.id
    or ("call_" .. os.time() .. "_" .. M._tool_call_counter .. "_" .. math.random(10000, 99999))
  tool_call.id = tool_call_id
  ss.active_tool_calls[tool_call_id] = true

  -- ===== 检测子 agent 工具调用 =====
  if tool_name == "create_sub_agent" then
    -- 将 create_sub_agent 委托给子 agent 引擎处理
    local args = tool_func.arguments or {}
    if type(args) == "string" then
      local ok, parsed = pcall(vim.json.decode, args)
      if ok and type(parsed) == "table" then
        args = parsed
      else
        args = {}
      end
    end

    -- 通过 tool_executor 执行 create_sub_agent（创建子 agent 记录）
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
        local s = state.sessions[session_id]
        if not s then
          return
        end

        if s.stop_requested then
          s.active_tool_calls[tool_call_id] = nil
          if vim.tbl_count(s.active_tool_calls) == 0 then
            M._on_tools_complete(session_id)
          end
          return
        end

        if success and result then
          -- 解析创建结果，获取 sub_agent_id
          local result_str = type(result) == "string" and result or ""
          local ok2, parsed_result = pcall(vim.json.decode, result_str)
          local sub_agent_id = parsed_result and parsed_result.sub_agent_id or nil

          -- 记录子 agent 创建消息
          if sub_agent_id then
            plan_executor.record_message(sub_agent_id, "system", "子 agent 已创建，任务: " .. (args.task or ""))
          end

          -- 将创建结果加入主 agent 消息
          M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str)

          -- 如果成功创建了子 agent，启动子 agent 的工具循环
          if sub_agent_id then
            -- 保存 on_summary 回调，用于接收子 agent 的总结
            local sub_agent_runner = {
              sub_agent_id = sub_agent_id,
              messages = {}, -- 子 agent 不继承主 agent 的消息历史，只接收任务指令
              on_summary = function(summary)
                -- 子 agent 完成时，将总结作为工具结果加入主 agent 消息
                local s2 = state.sessions[session_id]
                if not s2 then
                  return
                end

                local summary_msg =
                  string.format("【子 agent 执行完成】\n子 agent ID: %s\n\n%s", sub_agent_id, summary)

                -- 将总结作为 user 消息加入主 agent 上下文
                table.insert(s2.messages, {
                  role = "user",
                  content = summary_msg,
                  timestamp = os.time(),
                  window_id = s2.window_id,
                })

                -- 通知用户子 agent 执行完成
                vim.notify(string.format("[NeoAI] 子 agent [%s] 执行完成", sub_agent_id), vim.log.levels.INFO)

                -- 触发 UI 刷新，让用户看到总结消息
                local chat_window = require("NeoAI.ui.window.chat_window")
                pcall(chat_window.render_chat)

                -- 清理子 agent 资源
                plan_executor.cleanup_sub_agent(sub_agent_id)
              end,
            }

            -- 存储子 agent runner 引用
            if not ss._sub_agent_runners then
              ss._sub_agent_runners = {}
            end
            ss._sub_agent_runners[sub_agent_id] = sub_agent_runner

            -- 启动子 agent 的工具循环（异步，不阻塞主 agent）
            vim.schedule(function()
              sub_agent_engine.start_sub_agent_loop(sub_agent_id, {}, {
                session_id = session_id,
                window_id = ss.window_id,
                messages = {}, -- 子 agent 不继承主 agent 的消息历史
                options = ss.options,
                model_index = ss.model_index,
                ai_preset = ss.ai_preset,
                on_summary = sub_agent_runner.on_summary,
              })
            end)
          end
        else
          -- create_sub_agent 失败
          local err_msg = type(result) == "string" and result or "创建子 agent 失败"
          M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, err_msg)
        end

        s.active_tool_calls[tool_call_id] = nil
        local remaining = vim.tbl_count(s.active_tool_calls)
        if remaining == 0 and s.phase ~= "round_complete" then
          M._on_tools_complete(session_id)
        end
      end,
    })
    return
  end

  -- ===== 检测子 agent 的其他工具调用（由子 agent 引擎处理） =====
  -- 这些工具调用已被 sub_agent_engine 拦截，不会到达这里

  -- 获取工具所属包名
  local pack_name = tool_pack.get_pack_for_tool(tool_name)

  -- 委托给 tool_executor.execute_with_orchestrator
  -- 参数规范化、URL 解码、别名映射、超时管理全部由 tool_executor 负责
  local tool_executor = require("NeoAI.tools.tool_executor")

  -- 在协程上下文中执行工具（如果存在保存的协程上下文）
  -- 确保 tool_validator.check_approval → approval_handler.is_allow_all
  -- 能正确读取当前协程的共享变量
  local execute_fn = function()
    tool_executor.execute_with_orchestrator(tool_name, tool_func.arguments, {
      session_id = session_id,
      window_id = ss.window_id,
      generation_id = ss.generation_id,
      tool_call_id = tool_call_id,
      pack_name = pack_name,
    }, {
      on_result = function(success, result)
        local s = state.sessions[session_id]
        if not s then
          return
        end

        if s.stop_requested then
          s.active_tool_calls[tool_call_id] = nil
          if vim.tbl_count(s.active_tool_calls) == 0 then
            M._on_tools_complete(session_id)
          end
          return
        end

        local result_str = success and result or ("[工具执行失败] " .. result)
        M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str)

        s.active_tool_calls[tool_call_id] = nil
        local remaining = vim.tbl_count(s.active_tool_calls)

        if remaining == 0 and s.phase ~= "round_complete" then
          M._on_tools_complete(session_id)
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

function M._on_tools_complete(session_id)
  local ss = state.sessions[session_id]
  if not ss then
    return
  end
  -- 退出时直接跳过，避免触发事件或发起 AI 请求导致死循环
  if is_shutting_down() then
    return
  end
  if ss._tools_complete_in_progress then
    return
  end
  ss._tools_complete_in_progress = true

  if ss.stop_requested then
    ss.phase = "idle"
    ss._tools_complete_in_progress = false
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
      fire_loop_finished(ss)
      once_display_closed(session_id, function()
        local s = state.sessions[session_id]
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
        -- 调用 on_complete 回调
        if s.on_complete then
          local cb = s.on_complete
          s.on_complete = nil
          cb(true, "", saved_usage)
        end
      end)
      return
    end
    fire_loop_finished(ss)
    once_display_closed(session_id, function()
      local s = state.sessions[session_id]
      if not s then
        return
      end
      if is_shutting_down() then
        return
      end
      M._request_summary_round(session_id)
    end)
    return
  end

  if ss.phase == "waiting_tools" then
    ss.phase = "waiting_model"
    ss._tools_complete_in_progress = false
    fire_loop_finished(ss)
    once_display_closed(session_id, function()
      local s = state.sessions[session_id]
      if not s then
        return
      end
      -- 检查是否正在退出，避免在退出过程中触发事件导致卡死
      if is_shutting_down() then
        return
      end
      if s.stop_requested then
        logger.debug(
          "[tool_orchestrator] _on_tools_complete: once_display_closed 回调中检测到 stop_requested，跳过 _request_generation"
        )
        return
      end
      M._request_generation(session_id)
    end)
  elseif ss.phase == "round_complete" then
    ss._tools_complete_in_progress = false
    M._proceed_to_next_round(session_id)
  else
    ss._tools_complete_in_progress = false
  end
end

function M._check_round_complete(session_id)
  local ss = state.sessions[session_id]
  if not ss then
    return
  end

  local active_count = vim.tbl_count(ss.active_tool_calls)

  if ss.stop_requested then
    ss.phase = "idle"
    -- 用户取消或跳过总结时不触发总结
    if not ss.user_cancelled then
      M._request_summary_round(session_id)
    end
    return
  end

  if ss.phase == "waiting_model" then
    if active_count == 0 then
      -- 模型先完成，工具也已全部完成：直接触发下一轮
      if ss._proceed_in_progress then
        return
      end
      ss.phase = "round_complete"
      M._proceed_to_next_round(session_id)
    else
      -- 模型先完成，但工具还在执行中：
      -- 将 phase 设回 waiting_tools，等待工具完成后由 _on_tools_complete 处理
      -- 避免 _on_tools_complete 跳过 fire_loop_finished → once_display_closed → _request_generation 的正常流程
      ss.phase = "waiting_tools"
    end
  elseif ss.phase == "waiting_tools" then
    -- 工具先完成，模型后完成（正常路径）
    -- _on_tools_complete 已将 phase 设为 waiting_model
    -- 此时 active_count 应为 0，直接进入下一轮
    if active_count == 0 then
      if ss._proceed_in_progress then
        return
      end
      ss.phase = "round_complete"
      M._proceed_to_next_round(session_id)
    end
  end
end

function M._proceed_to_next_round(session_id)
  local ss = state.sessions[session_id]
  if not ss then
    return
  end
  if ss._proceed_in_progress then
    return
  end
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
    -- 用户取消或跳过总结时不触发总结
    if not ss.user_cancelled then
      M._request_summary_round(session_id)
    elseif ss._skip_summary then
      -- 跳过总结时触发 GENERATION_COMPLETED 事件显示用量
      local saved_usage = ss.accumulated_usage or {}
      local saved_gen_id = ss.generation_id
      local saved_win_id = ss.window_id
      local saved_reasoning = ss.last_reasoning or ""
      local saved_result = ""
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
              reasoning_text = saved_reasoning,
              usage = saved_usage,
              session_id = session_id,
              window_id = saved_win_id,
              duration = 0,
            },
          })
        end)
      end
    end
    return
  end

  fire_loop_finished(ss)
  ss.current_iteration = ss.current_iteration + 1
  ss.phase = "waiting_model"
  ss._proceed_in_progress = false

  M._request_generation(session_id)
end

-- ========== 请求 AI 生成 ==========

function M._request_generation(session_id)
  local ss = state.sessions[session_id]
  if not ss or ss.stop_requested then
    return
  end
  fire_tool_result_received(ss, false)
end

function M._request_summary_round(session_id)
  local ss = state.sessions[session_id]
  if not ss then
    return
  end
  if ss._summary_in_progress then
    return
  end
  -- 退出时不发起总结轮次，避免死循环
  if is_shutting_down() then
    ss._summary_in_progress = false
    return
  end
  ss._summary_in_progress = true

  -- 复制 messages 并添加系统提示
  -- 使用 vim.deepcopy 深拷贝，防止 format_messages 修改原始消息对象（如添加占位 tool_call_id）
  local messages = {}
  for _, msg in ipairs(ss.messages or {}) do
    table.insert(messages, vim.deepcopy(msg))
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
    if not s then
      return
    end
    -- 检查是否正在退出，避免在退出过程中触发事件导致卡死
    if is_shutting_down() then
      return
    end
    -- 注意：不检查 stop_requested。总结轮次是由循环结束触发的最终行为，
    -- 即使 stop_requested 为 true 也应执行总结，否则 AI 不会生成最终回复。
    -- 临时清除 stop_requested 标志，避免 ai_engine.handle_tool_result 跳过总结轮次的 AI 请求
    local saved_stop_requested = s.stop_requested
    s.stop_requested = false
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_RESULT_RECEIVED,
      data = {
        generation_id = saved.generation_id,
        tool_results = {},
        session_id = session_id,
        window_id = saved.window_id,
        messages = saved.messages,
        options = saved.options,
        model_index = saved.model_index,
        ai_preset = saved.ai_preset,
        is_final_round = true,
        accumulated_usage = saved.accumulated_usage,
        last_reasoning = saved.last_reasoning,
      },
    })
    -- 恢复 stop_requested 标志
    s.stop_requested = saved_stop_requested
  end)

  fire_loop_finished(ss)
end

-- ========== 外部回调 ==========

function M.on_generation_complete(data)
  -- ===== 子 agent 的 AI 生成完成 =====
  if data._sub_agent_id then
    sub_agent_engine.on_generation_complete(data)
    return
  end

  local session_id = data.session_id
  local ss = state.sessions[session_id]
  if not ss or ss.generation_id ~= data.generation_id then
    -- 总结轮次时，ss.generation_id 可能已被清空，但 data.generation_id 仍有值
    -- 此时通过 _summary_in_progress 标志来确认是否应该继续处理
    if not (ss and ss._summary_in_progress) then
      return
    end
  end

  local tool_calls = data.tool_calls or {}
  local content = data.content or ""
  local is_final_round = data.is_final_round or false

  -- 累积当前轮次的 usage 到 ss.accumulated_usage
  -- on_generation_complete 不是通过 GENERATION_COMPLETED 事件触发的，
  -- 所以需要在这里手动处理 usage 累积，否则 ss.accumulated_usage 会丢失当前轮次的用量
  local current_usage = data.usage or {}
  if current_usage and next(current_usage) then
    if ss._summary_in_progress then
      -- 总结轮次：直接赋值（_finalize_generation 中的 accumulated_usage 已包含完整历史）
      ss.accumulated_usage = vim.deepcopy(current_usage)
    else
      -- 普通轮次：逐轮累加
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
  end

  -- 过滤掉流式截断导致的无效工具调用（name 为空、arguments 为空、或 arguments JSON 解析失败的条目）
  -- encode_response_strings 不再编码 " 和 \，arguments 中的 JSON 结构保持完整，可直接解析
  local valid_tool_calls = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name and func.name ~= "" then
      local args = func.arguments
      if args ~= nil and args ~= "" then
        -- 策略 1：直接 JSON 解析
        local ok, parsed = pcall(vim.json.decode, args)
        if not (ok and type(parsed) == "table") then
          -- 策略 2：解码后重试（兼容旧数据中的 %XX 编码）
          if type(args) == "string" and args:find("%%") then
            local http_utils = require("NeoAI.core.ai.http_utils")
            local decoded = http_utils.decode_special_chars(args)
            ok, parsed = pcall(vim.json.decode, decoded)
          end
        end
        if ok and type(parsed) == "table" then
          table.insert(valid_tool_calls, tc)
        else
          logger.warn(
            "[tool_orchestrator] on_generation_complete: 工具 '%s' 的 arguments JSON 解析失败，跳过该工具调用: %s",
            func.name,
            tostring(args):sub(1, 200)
          )
        end
      end
    end
  end
  tool_calls = valid_tool_calls

  if ss.stop_requested then
    M._finish_loop(session_id, true, content)
    return
  end

  -- ===== 工具调用异常检测与重试 =====
  -- 仅在非最终轮次时检测（总结轮次不重试）
  if not is_final_round then
    local abnormal, reason = response_retry.detect_abnormal_response(content, tool_calls, {
      is_tool_loop = true,
      is_final_round = false,
    })
    if abnormal then
      local retry_count = ss._tool_retry_count or 0
      if response_retry.can_retry(retry_count) then
        local new_retry_count = retry_count + 1
        ss._tool_retry_count = new_retry_count
        local delay = response_retry.get_retry_delay(new_retry_count)
        logger.warn(
          string.format(
            "[tool_orchestrator] 检测到异常工具调用 (重试 %d/%d): %s, 延迟 %dms 后重试",
            new_retry_count,
            response_retry.get_max_retries(),
            reason,
            delay
          )
        )
        -- 通知 UI 正在重试
        vim.api.nvim_exec_autocmds("User", {
          pattern = event_constants.GENERATION_RETRYING,
          data = {
            generation_id = ss.generation_id,
            retry_count = new_retry_count,
            max_retries = response_retry.get_max_retries(),
            reason = reason,
            session_id = session_id,
            window_id = ss.window_id,
            layer = "tool_orchestrator",
          },
        })
        -- 移除最后一条 assistant 消息（包含异常工具调用），然后重新请求
        if #ss.messages > 0 then
          local last_msg = ss.messages[#ss.messages]
          if last_msg.role == "assistant" and last_msg.tool_calls then
            table.remove(ss.messages)
          end
        end
        vim.defer_fn(function()
          M._request_generation(session_id)
        end, delay)
        return
      else
        logger.warn(
          string.format(
            "[tool_orchestrator] 工具调用异常但重试已达上限 (%d/%d): %s",
            retry_count,
            response_retry.get_max_retries(),
            reason
          )
        )
        -- 重试已达上限：不再重试，继续正常处理当前工具调用
        -- 避免工具调用被丢弃导致 UI 不渲染且不保存
        -- 空响应重试耗尽：触发错误，避免卡住
        if reason and reason:find("空响应") then
          logger.warn("[tool_orchestrator] 空响应重试已达上限，触发生成错误")
          M._finish_loop(session_id, false, "AI 多次返回空响应")
          return
        end
      end
    end
  end
  -- 重置工具调用重试计数（正常响应时清零）
  if ss then
    ss._tool_retry_count = 0
  end

  -- 将中间轮次的 AI 回复保存到 history_manager（确保多轮工具调用的完整历史被持久化）
  -- 注意：is_final_round 时由总结轮次统一保存，此处不重复保存
  -- #tool_calls == 0 时也需要保存（AI 返回纯文本回复的中间轮次）
  if not is_final_round and ss.current_iteration < state.max_iterations then
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

  if is_final_round or #tool_calls == 0 or ss.current_iteration >= state.max_iterations then
    -- 不将当前 AI 响应（可能包含 tool_calls）添加到 ss.messages
    -- _finish_loop 会触发总结轮次，总结轮次会自己构建消息
    -- 如果先添加了带 tool_calls 的 assistant 消息，总结轮次的消息中就会包含
    -- 未匹配的 tool_call_id，导致 API 报错

    -- AI 返回纯文本回复（无工具调用），说明 AI 认为任务已完成
    -- 直接结束循环，不再触发额外的总结轮次，避免重复总结
    if #tool_calls == 0 and content and content ~= "" then
      logger.debug("[tool_orchestrator] AI 返回纯文本回复，直接结束循环，跳过总结轮次")
      -- 保存当前 AI 响应到消息历史
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
      -- 直接结束，不触发总结轮次
      local saved_usage = ss.accumulated_usage or {}
      local saved_reasoning = ss.last_reasoning or ""
      local saved_win_id = ss.window_id
      local saved_gen_id = ss.generation_id
      local on_complete = ss.on_complete
      ss.on_complete = nil
      ss.phase = "idle"
      ss.active_tool_calls = {}
      ss.current_iteration = 0
      ss.generation_id = nil
      fire_loop_finished(ss)
      once_display_closed(session_id, function()
        local s = state.sessions[session_id]
        if not s then
          return
        end
        if is_shutting_down() then
          return
        end
        -- 触发 GENERATION_COMPLETED 事件，通知 UI 更新
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = event_constants.GENERATION_COMPLETED,
          data = {
            generation_id = saved_gen_id,
            response = content,
            reasoning_text = saved_reasoning,
            usage = saved_usage,
            session_id = session_id,
            window_id = saved_win_id,
            duration = 0,
          },
        })
        if on_complete then
          on_complete(true, content, saved_usage)
        end
      end)
      return
    end

    -- is_final_round 为 true 时：直接结束循环，不再触发 _finish_loop
    -- _finish_loop 会触发 _request_summary_round 再次发起总结轮次，
    -- 导致总结轮次完成后再次进入 on_generation_complete → _finish_loop 的循环
    -- 直接保存当前 AI 响应到消息历史，触发 SUMMARY_COMPLETED 事件后结束
    if is_final_round then
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
      ss.phase = "idle"
      ss.active_tool_calls = {}
      ss.current_iteration = 0
      ss.generation_id = nil
      ss._summary_in_progress = false

      fire_loop_finished(ss)
      once_display_closed(session_id, function()
        local s = state.sessions[session_id]
        if not s then
          return
        end
        if is_shutting_down() then
          return
        end
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = event_constants.SUMMARY_COMPLETED,
          data = {
            generation_id = saved_gen_id,
            response = content,
            reasoning_text = saved_reasoning,
            usage = saved_usage,
            session_id = session_id,
            window_id = saved_win_id,
            duration = 0,
          },
        })
        if on_complete then
          on_complete(true, content, saved_usage)
        end
      end)
      return
    end

    -- 非最终轮次（#tool_calls == 0 或达到最大迭代次数）：触发 _finish_loop
    M._finish_loop(session_id, true, content)
    return
  end

  -- 将 AI 响应加入消息历史（仅当需要继续工具循环时）
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

  -- 关闭旧悬浮窗，打开新悬浮窗并执行工具
  ss.current_iteration = ss.current_iteration + 1

  fire_loop_finished(ss)
  once_display_closed(session_id, function()
    local s = state.sessions[session_id]
    if not s then
      return
    end
    -- 检查是否正在退出，避免在退出过程中执行工具导致卡死
    if is_shutting_down() then
      return
    end
    -- 检查 stop_requested，防止在延迟执行期间停止信号已到达
    if s.stop_requested then
      logger.debug(
        "[tool_orchestrator] on_generation_complete: once_display_closed 回调中检测到 stop_requested，跳过工具执行"
      )
      return
    end
    -- TOOL_LOOP_STARTED 事件由 _execute_tools 内部触发（携带工具包分组信息）
    M._execute_tools(session_id, tool_calls)
  end)
end

function M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result)
  local ss = state.sessions[session_id]
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

function M._finish_loop(session_id, success, result)
  local ss = state.sessions[session_id]
  if not ss then
    return
  end

  -- 循环结束，强制刷新 UI

  -- 检查是否所有会话都已空闲，如果是则清理全局 ESC 监听器
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

  -- 第二次调用 _finish_loop（总结轮次完成时）：触发 GENERATION_COMPLETED 事件
  -- 让 UI 更新用量提示和最终响应
  if ss.on_complete == nil then
    -- 保存当前数据用于事件
    local saved_gen_id = ss.generation_id
    local saved_win_id = ss.window_id
    local saved_usage = ss.accumulated_usage or {}
    local saved_reasoning = ss.last_reasoning or ""
    local saved_result = result or ""

    ss.phase = "idle"
    ss.active_tool_calls = {}
    ss.current_iteration = 0
    ss.generation_id = nil

    -- 触发 GENERATION_COMPLETED 事件，通知 UI 更新用量提示
    -- 注意：这里使用 vim.schedule 但检查 is_shutting_down，如果正在退出则跳过
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
            reasoning_text = saved_reasoning,
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

  -- 保存回调，稍后使用
  local on_complete = ss.on_complete
  local saved_usage = ss.accumulated_usage or {}
  local saved_generation_id = ss.generation_id
  local saved_window_id = ss.window_id
  local saved_reasoning = ss.last_reasoning or ""
  local saved_result = result or ""

  -- 用户取消时不触发总结，直接结束
  if ss.user_cancelled then
    ss.on_complete = nil
    ss.phase = "idle"
    ss.active_tool_calls = {}
    ss.current_iteration = 0
    ss.generation_id = nil
    -- 跳过总结时触发 GENERATION_COMPLETED 事件显示用量
    if ss._skip_summary then
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
              reasoning_text = saved_reasoning,
              usage = saved_usage,
              session_id = session_id,
              window_id = saved_window_id,
              duration = 0,
            },
          })
        end)
      end
    end
    if on_complete then
      vim.schedule(function()
        on_complete(true, saved_result, saved_usage)
      end)
    end
    return
  end

  -- 如果总结轮次已经在进行中（_summary_in_progress 为 true），
  -- 说明 _on_tools_complete 的 stop_requested 路径已触发过 _request_summary_round，
  -- 当前是 on_generation_complete 回调中总结轮次完成后的再次调用。
  -- 此时直接触发 GENERATION_COMPLETED 事件，避免重复触发总结轮次。
  if ss._summary_in_progress then
    ss.on_complete = nil
    ss.phase = "idle"
    ss.active_tool_calls = {}
    ss.current_iteration = 0
    ss.generation_id = nil
    ss._summary_in_progress = false
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
            reasoning_text = saved_reasoning,
            usage = saved_usage,
            session_id = session_id,
            window_id = saved_window_id,
            duration = 0,
          },
        })
      end)
    end
    return
  end

  -- 触发一次总结轮次（不带工具），让 AI 根据工具执行结果进行总结
  -- 注意：_request_summary_round 会通过 TOOL_RESULT_RECEIVED 事件触发 AI 生成
  -- AI 生成完成后会调用 on_generation_complete，其中会再次调用 _finish_loop
  -- 但此时 ss.on_complete 已被置为 nil，避免无限递归
  ss.on_complete = nil

  ss.phase = "idle"
  ss.active_tool_calls = {}
  ss.current_iteration = 0

  -- 先关闭工具显示（fire_loop_finished 由 _request_summary_round 内部触发）
  -- 触发总结轮次，让 AI 根据工具结果生成最终回复
  -- 总结完成后会通过 GENERATION_COMPLETED 事件通知 UI
  M._request_summary_round(session_id)

  -- 总结轮次已触发（内部已保存 generation_id 副本），现在可以安全清空
  -- 注意：不能在此处清空 ss.generation_id，因为 _request_summary_round 中的
  -- once_display_closed 回调是异步的（vim.schedule），on_generation_complete
  -- 需要依赖 ss.generation_id 做匹配检查。
  -- ss.generation_id 会在总结轮次完成后的 GENERATION_COMPLETED 回调中由
  -- tool_orchestrator 的监听器清空（见 register_session 中的 _summary_in_progress 分支）
  -- ss.generation_id = nil
end

-- ========== 停止控制 ==========

function M.request_stop(session_id)
  if session_id then
    local ss = state.sessions[session_id]
    if ss then
      ss.stop_requested = true
      if next(ss.active_tool_calls) ~= nil then
        ss.active_tool_calls = {}
        vim.schedule(function()
          M._on_tools_complete(session_id)
        end)
      end
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
  -- 无 session_id 时检查所有 session
  for _, ss in pairs(state.sessions) do
    if ss.stop_requested then
      return true
    end
  end
  return false
end

function M.reset_stop_requested(session_id)
  if session_id then
    local ss = state.sessions[session_id]
    if ss then
      ss.stop_requested = false
    end
  else
    for _, ss in pairs(state.sessions) do
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

--- 临时注册一个工具到 tool_registry，供 execute_single_tool_request 使用
--- 返回一个清理函数，调用后移除该工具
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

--- 执行一次非流式 AI 请求，只允许调用指定的工具，不计入工具循环
--- 用于 shell 交互式命令的自动输入场景
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
  local ai_engine = require("NeoAI.core.ai.ai_engine")
  local formatted = ai_engine.format_messages(messages)

  local http_client = require("NeoAI.core.ai.http_client")
  local ai_preset = ss.ai_preset or {}

  local request = ai_engine.build_request({
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

  -- 构建 http_client 参数
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
    http_client.send_request_async(http_params, function(response, err)
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
          -- 解码 URL 编码的 arguments（http_client 的 encode_response_strings 会对所有字符串进行 URL 编码）
          local raw_args_str = func.arguments or ""
          local decoded_args = raw_args_str
          if raw_args_str:find("%%") then
            local http_utils = require("NeoAI.core.ai.http_utils")
            decoded_args = http_utils.decode_special_chars(raw_args_str)
          end
          local ok, parsed_args = pcall(vim.json.decode, decoded_args)
          if ok and type(parsed_args) == "table" then
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
  return state.sessions[session_id]
end

--- 获取所有会话ID列表
--- @return table string[]
function M.get_all_session_ids()
  local ids = {}
  for sid, _ in pairs(state.sessions) do
    table.insert(ids, sid)
  end
  return ids
end

function M.is_executing(session_id)
  if session_id then
    local ss = state.sessions[session_id]
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
  return false
end

-- ========== 关闭清理 ==========

function M.shutdown()
  -- 清理全局 ESC 停止监听器
  if _stop_listener_id then
    pcall(vim.api.nvim_del_autocmd, _stop_listener_id)
    _stop_listener_id = nil
  end
  for session_id, _ in pairs(state.sessions) do
    M.unregister_session(session_id)
  end
  state.sessions = {}
  _tools = {}
  state.initialized = false
end

--- 重置（测试用）
function M._test_reset()
  state.initialized = false
  state.sessions = {}
  state.config = {}
  state.max_iterations = 20
  _tools = {}
end

--- 紧急清理（VimLeavePre 中使用）
--- 比 shutdown 更激进：直接清空所有状态，不触发任何事件或回调
function M.cleanup_all()
  -- 清理全局 ESC 停止监听器
  if _stop_listener_id then
    pcall(vim.api.nvim_del_autocmd, _stop_listener_id)
    _stop_listener_id = nil
  end

  -- 先设置所有会话的停止标志，防止任何回调继续执行
  for _, ss in pairs(state.sessions) do
    ss.stop_requested = true
    ss.phase = "idle"
    ss.active_tool_calls = {}
    ss.current_iteration = 0
    ss.generation_id = nil
    ss._tools_complete_in_progress = false
    ss._proceed_in_progress = false
    ss._summary_in_progress = false
  end

  -- 取消所有 HTTP 请求
  pcall(function()
    local http_ok, http_client = pcall(require, "NeoAI.core.ai.http_client")
    if http_ok and http_client and http_client.cancel_all_requests then
      http_client.cancel_all_requests()
    end
  end)

  -- 注销所有会话（删除 autocmd）
  for session_id, _ in pairs(state.sessions) do
    M.unregister_session(session_id)
  end

  -- 清空所有状态
  state.sessions = {}
  _tools = {}
end

return M
