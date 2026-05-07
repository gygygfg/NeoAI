-- 子 agent 执行引擎
-- 负责管理子 agent 的独立工具循环生命周期
--
-- 工作机制：
--   1. tool_orchestrator 检测到 create_sub_agent 工具调用时，委托给本模块
--   2. 本模块创建独立的协程上下文（变量隔离），启动子 agent 工具循环
--   3. 每次工具调用前通过 plan_executor.review_tool_call() 审核边界
--   4. 子 agent 结束后自动生成执行总结
--   5. 总结通过 tool_orchestrator 的消息系统返回给主 agent
--
-- 修复说明（2026-05-07）：
--   - 简化状态机：移除 _check_round_complete（GENERATION_COMPLETED 监听器），
--     改为纯回调驱动（_on_tools_complete → _request_generation → on_generation_complete）
--   - 修复竞态条件：使用 _round_in_progress 互斥锁防止重复进入
--   - 修复空工具调用结束逻辑：AI 返回无工具调用时正常结束
--   - 修复迭代计数不一致：统一使用 runner.iteration_count

local M = {}

local logger = require("NeoAI.utils.logger")
local state_manager = require("NeoAI.core.config.state")
local event_constants = require("NeoAI.core.events")
local plan_executor = require("NeoAI.tools.builtin.plan_executor")

-- ========== 子 agent 执行状态 ==========

local sub_agent_runners = {} -- sub_agent_id -> runner state

-- ========== 工具调用审核 ==========

--- 审核子 agent 的工具调用是否超出边界
--- 由 tool_executor 在每次工具执行前调用
--- @param sub_agent_id string
--- @param tool_name string
--- @param args table
--- @return boolean allowed, string|nil reason
function M.review_tool_call(sub_agent_id, tool_name, args)
  local tool_call = {
    name = tool_name,
    arguments = args,
  }
  return plan_executor.review_tool_call(sub_agent_id, tool_call)
end

--- 检查工具调用是否属于某个子 agent
--- @param tool_call table 工具调用对象
--- @return string|nil sub_agent_id
function M.get_sub_agent_id(tool_call)
  if not tool_call then
    return nil
  end
  local func = tool_call["function"] or tool_call.func
  if not func then
    return nil
  end
  local args = func.arguments or {}
  if type(args) == "string" then
    local ok, parsed = pcall(vim.json.decode, args)
    if ok and type(parsed) == "table" then
      args = parsed
    end
  end
  return args and args._sub_agent_id or nil
end

--- 标记工具调用属于某个子 agent（注入 _sub_agent_id）
--- @param tool_calls table 工具调用列表
--- @param sub_agent_id string
function M.inject_sub_agent_id(tool_calls, sub_agent_id)
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func then
      local args = func.arguments
      if type(args) == "string" then
        local ok, parsed = pcall(vim.json.decode, args)
        if ok and type(parsed) == "table" then
          parsed._sub_agent_id = sub_agent_id
          func.arguments = vim.json.encode(parsed)
        end
      elseif type(args) == "table" then
        args._sub_agent_id = sub_agent_id
      end
    end
  end
end

-- ========== 子 agent 工具循环 ==========

--- 启动子 agent 的工具循环
--- 在独立的协程上下文中执行，变量与主 agent 隔离
--- @param sub_agent_id string
--- @param tool_calls table 子 agent 首次返回的工具调用列表
--- @param session_context table 会话上下文
function M.start_sub_agent_loop(sub_agent_id, tool_calls, session_context)
  logger.debug("[sub_agent] start_sub_agent_loop: id=%s, tool_calls=%d", sub_agent_id, #(tool_calls or {}))
  local runner = {
    sub_agent_id = sub_agent_id,
    session_id = session_context.session_id,
    window_id = session_context.window_id,
    generation_id = "sub_agent_" .. sub_agent_id .. "_" .. os.time() .. "_" .. math.random(10000, 99999),
    messages = session_context.messages or {},
    options = session_context.options or {},
    model_index = session_context.model_index or 1,
    ai_preset = session_context.ai_preset or {},
    on_summary = session_context.on_summary,
    iteration_count = 0,
    max_iterations = 20,
    stop_requested = false,
    active_tool_calls = {},
    -- 互斥锁，防止竞态
    _round_in_progress = false,
    _tools_complete_in_progress = false,
  }

  sub_agent_runners[sub_agent_id] = runner

  -- 注入子 agent ID 到工具调用
  M.inject_sub_agent_id(tool_calls, sub_agent_id)

  -- 启动第一轮：执行工具或直接请求 AI 生成
  M._execute_tools(sub_agent_id, tool_calls)
end

-- ========== 工具执行 ==========

function M._execute_tools(sub_agent_id, tool_calls)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then
    logger.warn("[sub_agent] _execute_tools: runner not found for %s", sub_agent_id)
    return
  end
  if runner.stop_requested then
    logger.warn("[sub_agent] _execute_tools: stop_requested for %s", sub_agent_id)
    return
  end

  -- 过滤无效工具调用
  local valid_tool_calls = {}
  for _, tc in ipairs(tool_calls or {}) do
    local func = tc["function"] or tc.func
    if func and func.name and func.name ~= "" then
      local args = func.arguments
      if args ~= nil and args ~= "" then
        table.insert(valid_tool_calls, tc)
      end
    end
  end
  tool_calls = valid_tool_calls

  if #tool_calls == 0 then
    -- 检查是否没有任何可用工具（allowed_tools 为空列表）
    -- 如果是，直接结束子 agent，避免 AI 反复尝试调用被驳回的工具
    local context = plan_executor.get_sub_agent_context(sub_agent_id)
    local allowed_tools = context and context.boundaries and context.boundaries.allowed_tools
    if allowed_tools ~= nil and #allowed_tools == 0 then
      plan_executor.record_error(sub_agent_id, "没有允许的工具可用，子 agent 无法执行任何操作")
      M._finalize_sub_agent(sub_agent_id)
      return
    end
    -- 没有工具调用，直接请求 AI 生成
    M._request_generation(sub_agent_id)
    return
  end

  runner.active_tool_calls = {}

  -- 并发执行所有工具
  for _, tc in ipairs(tool_calls) do
    M._execute_single_tool(sub_agent_id, tc)
  end
end

function M._execute_single_tool(sub_agent_id, tool_call)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner or not tool_call or runner.stop_requested then
    return
  end

  local func = tool_call["function"] or tool_call.func
  if not func or not func.name then
    return
  end

  local tool_name = func.name

  -- 生成唯一 tool_call_id
  if not M._tool_call_counter then
    M._tool_call_counter = 0
  end
  M._tool_call_counter = M._tool_call_counter + 1
  local tool_call_id = tool_call.id
    or ("sub_call_" .. os.time() .. "_" .. M._tool_call_counter .. "_" .. math.random(10000, 99999))
  tool_call.id = tool_call_id
  runner.active_tool_calls[tool_call_id] = true

  -- ===== 边界审核 =====
  local args = func.arguments or {}
  if type(args) == "string" then
    local ok, parsed = pcall(vim.json.decode, args)
    if ok and type(parsed) == "table" then
      args = parsed
    else
      args = {}
    end
  end

  local allowed, reason = M.review_tool_call(sub_agent_id, tool_name, args)
  if not allowed then
    -- 被调度 agent 驳回
    runner.active_tool_calls[tool_call_id] = nil
    plan_executor.record_error(sub_agent_id, string.format("工具 '%s' 被驳回: %s", tool_name, reason))

    -- 将驳回信息作为工具结果返回给 AI
    -- 明确告诉 AI 不要重试此工具，避免陷入驳回-重试死循环
    local result_str = string.format(
      "[调度 agent 驳回] 工具 '%s' 的调用被拒绝。原因: %s\n此工具不在你的允许列表中，请不要再尝试调用它。请使用其他允许的工具继续完成任务，或直接返回文本说明任务无法完成。",
      tool_name,
      reason
    )
    M._add_tool_result_to_messages(sub_agent_id, tool_call_id, tool_name, result_str)

    local remaining = vim.tbl_count(runner.active_tool_calls)
    if remaining == 0 then
      -- 使用 vim.schedule 延迟调用，避免在 _execute_tools 遍历期间同步触发重入
      vim.schedule(function()
        M._on_tools_complete(sub_agent_id)
      end)
    end
    return
  end

  -- ===== 通过审核，执行工具 =====
  local tool_executor = require("NeoAI.tools.tool_executor")

  -- 创建子 agent 独立的协程上下文（变量隔离）
  local ctx = state_manager.create_context({
    session_id = runner.session_id,
    generation_id = runner.generation_id,
    window_id = runner.window_id,
    sub_agent_id = sub_agent_id,
  })

  state_manager.with_context(ctx, function()
    tool_executor.execute_with_orchestrator(tool_name, func.arguments, {
      session_id = runner.session_id,
      window_id = runner.window_id,
      generation_id = runner.generation_id,
      tool_call_id = tool_call_id,
      pack_name = "sub_agent_" .. sub_agent_id,
    }, {
      on_result = function(success, result)
        local r = sub_agent_runners[sub_agent_id]
        if not r then
          return
        end

        if r.stop_requested then
          r.active_tool_calls[tool_call_id] = nil
          if vim.tbl_count(r.active_tool_calls) == 0 then
            M._on_tools_complete(sub_agent_id)
          end
          return
        end

        local result_str = success and result or ("[工具执行失败] " .. result)

        -- 记录执行结果
        if success then
          plan_executor.record_result(sub_agent_id, string.format("[%s] %s", tool_name, result_str:sub(1, 500)))
        else
          plan_executor.record_error(sub_agent_id, string.format("[%s] %s", tool_name, result_str))
        end

        M._add_tool_result_to_messages(sub_agent_id, tool_call_id, tool_name, result_str)

        r.active_tool_calls[tool_call_id] = nil
        local remaining = vim.tbl_count(r.active_tool_calls)

        if remaining == 0 then
          -- 使用 vim.schedule 延迟调用，避免在工具执行回调中同步触发重入
          vim.schedule(function()
            M._on_tools_complete(sub_agent_id)
          end)
        end
      end,
    })
  end)
end

-- ========== 完成检查 ==========

--- 所有工具执行完成后的回调
--- 触发下一轮 AI 生成
function M._on_tools_complete(sub_agent_id)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then
    logger.warn("[sub_agent] _on_tools_complete: runner not found for %s", sub_agent_id)
    return
  end
  if runner._tools_complete_in_progress then
    logger.warn("[sub_agent] _on_tools_complete: already in progress for %s", sub_agent_id)
    return
  end
  logger.info("[sub_agent] _on_tools_complete: id=%s", sub_agent_id)
  runner._tools_complete_in_progress = true

  if runner.stop_requested then
    runner._tools_complete_in_progress = false
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  runner._tools_complete_in_progress = false
  M._request_generation(sub_agent_id)
end

-- ========== 请求 AI 生成 ==========

function M._request_generation(sub_agent_id)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then
    logger.warn("[sub_agent] _request_generation: runner not found for %s", sub_agent_id)
    return
  end
  if runner.stop_requested then
    logger.warn("[sub_agent] _request_generation: stop_requested for %s", sub_agent_id)
    return
  end
  logger.info(
    "[sub_agent] _request_generation: id=%s, iter=%d, max=%d",
    sub_agent_id,
    runner.iteration_count,
    runner.max_iterations
  )

  -- 退出时跳过，防止死循环
  if require("NeoAI.core.shutdown_flag").is_set() then
    return
  end

  -- 检查迭代上限
  if runner.iteration_count >= runner.max_iterations then
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  -- 递增迭代计数
  runner.iteration_count = runner.iteration_count + 1

  -- 同步到 plan_executor
  if not plan_executor.should_continue(sub_agent_id) then
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  -- 生成新的 generation_id，避免 HTTP 客户端去重机制阻塞后续轮次
  -- 同一个 generation_id 的重复请求会被 http_utils.check_dedup 忽略（TTL=3s）
  local old_generation_id = runner.generation_id
  runner.generation_id = "sub_agent_" .. sub_agent_id .. "_" .. os.time() .. "_" .. math.random(10000, 99999)
  -- 清除旧的去重缓存，确保新请求不被忽略
  pcall(function()
    require("NeoAI.core.ai.http_utils").clear_dedup(old_generation_id)
  end)

  -- 构建子 agent 的系统提示词
  local context = plan_executor.get_sub_agent_context(sub_agent_id)
  if not context then
    logger.warn("[sub_agent] _request_generation: context not found for %s, finalizing", sub_agent_id)
    M._finalize_sub_agent(sub_agent_id)
    return
  end
  local system_prompt = _build_sub_agent_system_prompt(context)

  -- 构建消息列表
  local messages = {}
  -- 系统提示词放在最前面
  table.insert(messages, {
    role = "system",
    content = system_prompt,
  })
  -- 从 runner 中获取子 agent 的消息历史
  -- 注意：过滤掉末尾孤立的 assistant 消息（带 tool_calls 但后续没有 tool 消息），
  -- 这种情况可能发生在子 agent 初始消息中包含了主 agent 的最后一条 assistant 消息
  local runner_msgs = runner.messages or {}
  -- 深拷贝一份，避免修改原始 runner.messages
  local filtered_msgs = {}
  for _, msg in ipairs(runner_msgs) do
    table.insert(filtered_msgs, vim.deepcopy(msg))
  end
  -- 检查最后一条消息是否为带 tool_calls 的 assistant 消息
  local last_msg = filtered_msgs[#filtered_msgs]
  local has_trailing_tool_calls = last_msg
    and last_msg.role == "assistant"
    and last_msg.tool_calls
    and #last_msg.tool_calls > 0
  if has_trailing_tool_calls then
    -- 检查倒数第二条消息是否为匹配的 tool 消息
    local has_following_tool = false
    if #filtered_msgs >= 2 then
      local second_last = filtered_msgs[#filtered_msgs - 1]
      if second_last and second_last.role == "tool" then
        for _, tc in ipairs(last_msg.tool_calls) do
          if second_last.tool_call_id == (tc.id or tc.tool_call_id) then
            has_following_tool = true
            break
          end
        end
      end
    end
    if not has_following_tool then
      -- 移除最后一条孤立的 assistant 消息
      table.remove(filtered_msgs)
    end
  end
  for _, msg in ipairs(filtered_msgs) do
    table.insert(messages, msg)
  end

  -- 检查是否需要添加 user 消息来触发 AI 生成
  -- 条件：过滤后只有 system 提示词（没有 user/assistant/tool 消息）
  -- 这种情况可能发生在：
  --   1. 首次请求且 runner.messages 为空
  --   2. runner.messages 中所有消息都被过滤掉（如只有孤立 assistant 消息）
  local has_non_system = false
  for _, msg in ipairs(messages) do
    if msg.role ~= "system" then
      has_non_system = true
      break
    end
  end
  if not has_non_system then
    table.insert(messages, {
      role = "user",
      content = string.format(
        "请执行以下任务：%s\n\n请使用可用的工具来完成此任务。完成任务后，请说明结果。",
        context.task
      ),
    })
  end

  -- 触发 TOOL_RESULT_RECEIVED 事件，让 AI 生成下一轮回复
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_RESULT_RECEIVED,
    data = {
      generation_id = runner.generation_id,
      tool_results = {},
      session_id = runner.session_id,
      window_id = runner.window_id,
      messages = messages,
      options = runner.options,
      model_index = runner.model_index,
      ai_preset = runner.ai_preset,
      is_final_round = false,
      accumulated_usage = runner.accumulated_usage or {},
      last_reasoning = runner.last_reasoning,
      _sub_agent_id = sub_agent_id,
    },
  })
end

--- 构建子 agent 系统提示词
function _build_sub_agent_system_prompt(context)
  if not context then
    return ""
  end

  local boundaries = context.boundaries or {}
  local boundary_desc = boundaries.description or "未设置边界描述"

  local boundary_lines = { "=== 工作边界 ===" }
  boundary_lines[#boundary_lines + 1] = "边界描述: " .. boundary_desc

  if boundaries.allowed_tools and #boundaries.allowed_tools > 0 then
    boundary_lines[#boundary_lines + 1] = "允许的工具: " .. table.concat(boundaries.allowed_tools, ", ")
  end
  if boundaries.allowed_commands and #boundaries.allowed_commands > 0 then
    boundary_lines[#boundary_lines + 1] = "允许的命令: " .. table.concat(boundaries.allowed_commands, ", ")
  end
  if boundaries.allowed_files and #boundaries.allowed_files > 0 then
    boundary_lines[#boundary_lines + 1] = "允许的文件: " .. table.concat(boundaries.allowed_files, ", ")
  end
  if boundaries.allowed_directories and #boundaries.allowed_directories > 0 then
    boundary_lines[#boundary_lines + 1] = "允许的目录: " .. table.concat(boundaries.allowed_directories, ", ")
  end
  if boundaries.max_tool_calls then
    boundary_lines[#boundary_lines + 1] = "最大工具调用次数: " .. boundaries.max_tool_calls
  end

  local context_lines = {}
  if context.context and next(context.context) then
    context_lines[#context_lines + 1] = "=== 额外上下文 ==="
    for k, v in pairs(context.context) do
      local vs = type(v) == "table" and vim.inspect(v) or tostring(v)
      context_lines[#context_lines + 1] = k .. ": " .. vs
    end
  end

  local prompt = string.format(
    [[你是一个子 agent，由主 agent 创建来执行特定的子任务。

=== 你的任务 ===
%s

%s

%s

=== 执行规则 ===
1. 你拥有独立的工具调用循环，可以像主 agent 一样调用工具
2. 你的所有工具调用都会经过调度 agent 审核，超出边界会被驳回
3. 如果工具调用被驳回，说明该工具不在你的允许列表中，请**不要再次尝试调用同一个工具**
4. 被驳回后，请使用其他允许的工具继续完成任务，或直接返回文本说明任务无法完成
5. 完成任务后，请明确说明任务已完成，并总结关键结果
6. 不要尝试访问边界之外的文件、目录或执行边界之外的命令
7. 如果遇到无法解决的问题（如所有可用工具都被驳回），请说明原因并请求主 agent 协助

请开始执行你的任务。]],
    context.task,
    table.concat(boundary_lines, "\n"),
    #context_lines > 0 and table.concat(context_lines, "\n") or ""
  )

  return prompt
end

-- ========== 消息管理 ==========

function M._add_tool_result_to_messages(sub_agent_id, tool_call_id, tool_name, result)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then
    return
  end

  local safe_id = tool_call_id or ("sub_call_" .. os.time() .. "_" .. math.random(10000, 99999))
  local result_str = type(result) == "string" and result
    or (result ~= nil and pcall(vim.json.encode, result) and vim.json.encode(result) or tostring(result))
    or ""

  local tool_msg = {
    role = "tool",
    tool_call_id = safe_id,
    content = result_str,
    timestamp = os.time(),
    window_id = runner.window_id,
  }
  if tool_name then
    tool_msg.name = tool_name
  end
  table.insert(runner.messages, tool_msg)

  plan_executor.record_message(sub_agent_id, "tool", result_str:sub(1, 500))
end

-- ========== 子 agent 完成处理 ==========

function M._finalize_sub_agent(sub_agent_id)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then
    return
  end

  -- 标记子 agent 完成
  plan_executor._finalize_sub_agent(sub_agent_id)

  -- 获取执行总结
  local summary = plan_executor.get_summary(sub_agent_id) or "子 agent 执行完成，但未生成总结"

  -- 通过回调返回总结给主 agent
  if runner.on_summary then
    local cb = runner.on_summary
    runner.on_summary = nil
    pcall(cb, summary)
  end

  -- 清理 runner
  sub_agent_runners[sub_agent_id] = nil
end

-- ========== 停止控制 ==========

function M.request_stop(sub_agent_id)
  local runner = sub_agent_runners[sub_agent_id]
  if runner then
    runner.stop_requested = true
    if next(runner.active_tool_calls) ~= nil then
      runner.active_tool_calls = {}
      vim.schedule(function()
        M._on_tools_complete(sub_agent_id)
      end)
    end
  end
end

function M.is_running(sub_agent_id)
  local runner = sub_agent_runners[sub_agent_id]
  return runner ~= nil and not runner.stop_requested
end

-- ========== AI 生成完成回调 ==========

--- 由 ai_engine 在子 agent 的 AI 生成完成后调用
--- @param data table 包含 tool_calls, content, generation_id, session_id, _sub_agent_id 等
function M.on_generation_complete(data)
  local sub_agent_id = data._sub_agent_id
  if not sub_agent_id then
    logger.warn("[sub_agent] on_generation_complete: no sub_agent_id")
    return
  end

  local runner = sub_agent_runners[sub_agent_id]
  if not runner then
    logger.warn("[sub_agent] on_generation_complete: runner not found for %s", sub_agent_id)
    return
  end
  if runner.stop_requested then
    logger.warn("[sub_agent] on_generation_complete: stop_requested for %s", sub_agent_id)
    return
  end

  -- 互斥锁：防止 _round_in_progress 为 true 时重复进入
  if runner._round_in_progress then
    logger.warn("[sub_agent] on_generation_complete: round in progress for %s", sub_agent_id)
    return
  end
  logger.info(
    "[sub_agent] on_generation_complete: id=%s, tool_calls=%d, content_len=%d",
    sub_agent_id,
    #(data.tool_calls or {}),
    #(data.content or "")
  )
  runner._round_in_progress = true

  -- 同步 runner 的 generation_id 为当前完成轮的 ID
  -- 确保后续 _request_generation 使用正确的 generation_id
  if data.generation_id then
    runner.generation_id = data.generation_id
  end

  local tool_calls = data.tool_calls or {}
  local content = data.content or ""

  -- 过滤无效工具调用
  local valid_tool_calls = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name and func.name ~= "" then
      local args = func.arguments
      if args ~= nil and args ~= "" then
        table.insert(valid_tool_calls, tc)
      end
    end
  end
  tool_calls = valid_tool_calls

  -- 记录 AI 回复（包含 tool_calls，确保消息历史完整性）
  if content and content ~= "" then
    plan_executor.record_message(sub_agent_id, "assistant", content)
    local assistant_msg = {
      role = "assistant",
      content = content,
      timestamp = os.time(),
      window_id = runner.window_id,
    }
    -- 保存 tool_calls 到 assistant 消息，避免 tool 消息成为孤立消息
    if #tool_calls > 0 then
      assistant_msg.tool_calls = tool_calls
    end
    table.insert(runner.messages, assistant_msg)
  elseif #tool_calls > 0 then
    -- 即使 content 为空，也要保存带 tool_calls 的 assistant 消息
    plan_executor.record_message(sub_agent_id, "assistant", "")
    table.insert(runner.messages, {
      role = "assistant",
      content = "",
      tool_calls = tool_calls,
      timestamp = os.time(),
      window_id = runner.window_id,
    })
  end

  -- 注入子 agent ID 到工具调用
  M.inject_sub_agent_id(tool_calls, sub_agent_id)

  -- 判断是否应该结束
  local should_finalize = false

  if #tool_calls == 0 then
    -- AI 返回纯文本回复，没有工具调用 → 子 agent 完成
    should_finalize = true
  elseif runner.iteration_count >= runner.max_iterations then
    -- 达到最大迭代次数
    should_finalize = true
  end

  if should_finalize then
    runner._round_in_progress = false
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  -- 继续工具循环
  runner._round_in_progress = false
  M._execute_tools(sub_agent_id, tool_calls)
end

-- ========== 清理 ==========

function M.cleanup_all()
  for sub_agent_id, runner in pairs(sub_agent_runners) do
    runner.stop_requested = true
  end
  sub_agent_runners = {}
end

--- 重置（测试用）
function M._test_reset()
  M.cleanup_all()
end

return M
