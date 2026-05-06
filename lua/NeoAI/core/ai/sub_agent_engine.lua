-- 子 agent 执行引擎
-- 负责管理子 agent 的独立工具循环生命周期
--
-- 工作机制：
--   1. tool_orchestrator 检测到 create_sub_agent 工具调用时，委托给本模块
--   2. 本模块创建独立的协程上下文（变量隔离），启动子 agent 工具循环
--   3. 每次工具调用前通过 plan_executor.review_tool_call() 审核边界
--   4. 子 agent 结束后自动生成执行总结
--   5. 总结通过 tool_orchestrator 的消息系统返回给主 agent

local M = {}

local logger = require("NeoAI.utils.logger")
local state_manager = require("NeoAI.core.config.state")
local event_constants = require("NeoAI.core.events")
local plan_executor = require("NeoAI.tools.builtin.plan_executor")

-- ========== 子 agent 执行状态 ==========

local sub_agent_runners = {}  -- sub_agent_id -> runner state

-- ========== 工具调用审核 ==========

--- 审核子 agent 的工具调用是否超出边界
--- 由 tool_executor 在每次工具执行前调用
--- @param sub_agent_id string
--- @param tool_name string
--- @param args table
--- @return boolean allowed, string|nil reason
function M.review_tool_call(sub_agent_id, tool_name, args)
  -- 委托给 plan_executor 的边界检查
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
  if not tool_call then return nil end
  local func = tool_call["function"] or tool_call.func
  if not func then return nil end
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
---   - session_id: string 主会话 ID
---   - window_id: number
---   - generation_id: string
---   - messages: table 子 agent 的消息历史
---   - options: table AI 选项
---   - model_index: number
---   - ai_preset: table
---   - on_summary: function(summary) 子 agent 完成时的回调
function M.start_sub_agent_loop(sub_agent_id, tool_calls, session_context)
  local runner = {
    sub_agent_id = sub_agent_id,
    session_id = session_context.session_id,
    window_id = session_context.window_id,
    generation_id = "sub_agent_" .. sub_agent_id .. "_" .. os.time(),
    messages = session_context.messages or {},
    options = session_context.options or {},
    model_index = session_context.model_index or 1,
    ai_preset = session_context.ai_preset or {},
    on_summary = session_context.on_summary,
    current_iteration = 0,
    max_iterations = 20,
    stop_requested = false,
    active_tool_calls = {},
    phase = "idle",  -- idle | waiting_tools | waiting_model | round_complete
    _tools_complete_in_progress = false,
    _proceed_in_progress = false,
    autocmd_ids = {},
  }

  sub_agent_runners[sub_agent_id] = runner

  -- 注册事件监听
  local ids = {}

  -- GENERATION_COMPLETED 监听器
  table.insert(ids, vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.GENERATION_COMPLETED,
    callback = function(args)
      local data = args.data
      if data.generation_id ~= runner.generation_id then return end
      if runner.stop_requested then return end

      -- 累积 usage
      if data.usage and next(data.usage) then
        local acc = runner.accumulated_usage or {}
        acc.prompt_tokens = (acc.prompt_tokens or 0) + (data.usage.prompt_tokens or data.usage.input_tokens or 0)
        acc.completion_tokens = (acc.completion_tokens or 0) + (data.usage.completion_tokens or data.usage.output_tokens or 0)
        acc.total_tokens = (acc.total_tokens or 0) + (data.usage.total_tokens or 0)
        runner.accumulated_usage = acc
      end

      M._check_round_complete(sub_agent_id)
    end,
  }))

  runner.autocmd_ids = ids

  -- 注入子 agent ID 到工具调用
  M.inject_sub_agent_id(tool_calls, sub_agent_id)

  -- 启动第一轮工具执行
  M._execute_tools(sub_agent_id, tool_calls)
end

-- ========== 工具执行 ==========

function M._execute_tools(sub_agent_id, tool_calls)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then return end

  if runner.stop_requested then return end

  if #tool_calls == 0 then
    -- 没有工具调用，请求 AI 生成
    vim.schedule(function()
      M._request_generation(sub_agent_id)
    end)
    return
  end

  runner.phase = "waiting_tools"
  runner.active_tool_calls = {}

  -- 并发执行所有工具
  for _, tc in ipairs(tool_calls) do
    M._execute_single_tool(sub_agent_id, tc)
  end
end

function M._execute_single_tool(sub_agent_id, tool_call)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner or not tool_call then return end
  if runner.stop_requested then return end

  local func = tool_call["function"] or tool_call.func
  if not func or not func.name then return end

  local tool_name = func.name

  -- 生成唯一 tool_call_id
  if not M._tool_call_counter then M._tool_call_counter = 0 end
  M._tool_call_counter = M._tool_call_counter + 1
  local tool_call_id = tool_call.id or ("sub_call_" .. os.time() .. "_" .. M._tool_call_counter .. "_" .. math.random(10000, 99999))
  tool_call.id = tool_call_id
  runner.active_tool_calls[tool_call_id] = true

  -- ===== 边界审核 =====
  local args = func.arguments or {}
  if type(args) == "string" then
    local ok, parsed = pcall(vim.json.decode, args)
    if ok and type(parsed) == "table" then args = parsed else args = {} end
  end

  local allowed, reason = M.review_tool_call(sub_agent_id, tool_name, args)
  if not allowed then
    -- 被调度 agent 驳回
    runner.active_tool_calls[tool_call_id] = nil
    plan_executor.record_error(sub_agent_id, string.format("工具 '%s' 被驳回: %s", tool_name, reason))

    -- 将驳回信息作为工具结果返回给 AI
    local result_str = string.format("[调度 agent 驳回] 工具 '%s' 的调用被拒绝。原因: %s\n请调整策略后重试。", tool_name, reason)
    M._add_tool_result_to_messages(sub_agent_id, tool_call_id, tool_name, result_str)

    local remaining = vim.tbl_count(runner.active_tool_calls)
    if remaining == 0 and runner.phase ~= "round_complete" then
      M._on_tools_complete(sub_agent_id)
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
        if not r then return end

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

        if remaining == 0 and r.phase ~= "round_complete" then
          M._on_tools_complete(sub_agent_id)
        end
      end,
    })
  end)
end

-- ========== 完成检查 ==========

function M._on_tools_complete(sub_agent_id)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then return end
  if runner._tools_complete_in_progress then return end
  runner._tools_complete_in_progress = true

  if runner.stop_requested then
    runner.phase = "idle"
    runner._tools_complete_in_progress = false
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  if runner.phase == "waiting_tools" then
    runner.phase = "waiting_model"
    runner._tools_complete_in_progress = false
    M._request_generation(sub_agent_id)
  elseif runner.phase == "round_complete" then
    runner._tools_complete_in_progress = false
    M._proceed_to_next_round(sub_agent_id)
  else
    runner._tools_complete_in_progress = false
  end
end

function M._check_round_complete(sub_agent_id)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then return end

  local active_count = vim.tbl_count(runner.active_tool_calls)

  if runner.stop_requested then
    runner.phase = "idle"
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  if runner.phase == "waiting_model" then
    if active_count == 0 then
      if runner._proceed_in_progress then return end
      runner.phase = "round_complete"
      M._proceed_to_next_round(sub_agent_id)
    else
      runner.phase = "waiting_tools"
    end
  elseif runner.phase == "waiting_tools" then
    if active_count == 0 then
      if runner._proceed_in_progress then return end
      runner.phase = "round_complete"
      M._proceed_to_next_round(sub_agent_id)
    end
  end
end

function M._proceed_to_next_round(sub_agent_id)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then return end
  if runner._proceed_in_progress then return end
  runner._proceed_in_progress = true

  runner.phase = "idle"
  runner.active_tool_calls = {}

  if runner.current_iteration >= runner.max_iterations then
    runner._proceed_in_progress = false
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  if runner.stop_requested then
    runner._proceed_in_progress = false
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  runner.current_iteration = runner.current_iteration + 1
  runner.phase = "waiting_model"
  runner._proceed_in_progress = false

  M._request_generation(sub_agent_id)
end

-- ========== 请求 AI 生成 ==========

function M._request_generation(sub_agent_id)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner or runner.stop_requested then return end

  -- 退出时跳过，防止死循环
  if require("NeoAI.core.shutdown_flag").is_set() then
    return
  end

  -- 检查子 agent 是否应该继续
  if not plan_executor.should_continue(sub_agent_id) then
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  -- 构建子 agent 的系统提示词
  local context = plan_executor.get_sub_agent_context(sub_agent_id)
  local system_prompt = _build_sub_agent_system_prompt(context)

  -- 构建消息列表：主 agent 共享上下文 + 子 agent 系统提示 + 子 agent 对话历史
  local messages = {}
  -- 从 runner 中获取子 agent 的消息历史
  for _, msg in ipairs(runner.messages or {}) do
    table.insert(messages, vim.deepcopy(msg))
  end
  -- 添加子 agent 系统提示
  table.insert(messages, {
    role = "system",
    content = system_prompt,
  })

  -- 触发 TOOL_RESULT_RECEIVED 事件，让 AI 生成下一轮回复
  -- 使用主会话的 session_id 但标记为子 agent 请求
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
      _sub_agent_id = sub_agent_id,  -- 标记为子 agent 请求
    },
  })
end

--- 构建子 agent 系统提示词
function _build_sub_agent_system_prompt(context)
  if not context then return "" end

  local boundaries = context.boundaries or {}
  local boundary_desc = boundaries.description or "未设置边界描述"

  -- 构建边界说明
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

  -- 构建额外上下文
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
3. 如果工具调用被驳回，请根据驳回理由调整策略后重试
4. 完成任务后，请明确说明任务已完成，并总结关键结果
5. 不要尝试访问边界之外的文件、目录或执行边界之外的命令
6. 如果遇到无法解决的问题，请说明原因并请求主 agent 协助

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
  if not runner then return end

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

  -- 记录到 plan_executor
  plan_executor.record_message(sub_agent_id, "tool", result_str:sub(1, 500))
end

-- ========== 子 agent 完成处理 ==========

function M._finalize_sub_agent(sub_agent_id)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then return end

  -- 清理事件监听
  for _, id in ipairs(runner.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, id)
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
  if not sub_agent_id then return end

  local runner = sub_agent_runners[sub_agent_id]
  if not runner then return end

  if runner.stop_requested then return end

  local tool_calls = data.tool_calls or {}
  local content = data.content or ""
  local is_final_round = data.is_final_round or false

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

  -- 记录 AI 回复
  if content and content ~= "" then
    plan_executor.record_message(sub_agent_id, "assistant", content)
    table.insert(runner.messages, {
      role = "assistant",
      content = content,
      timestamp = os.time(),
      window_id = runner.window_id,
    })
  end

  -- 注入子 agent ID 到工具调用
  M.inject_sub_agent_id(tool_calls, sub_agent_id)

  if is_final_round or #tool_calls == 0 or runner.current_iteration >= runner.max_iterations then
    -- 没有更多工具调用，子 agent 完成
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  -- 继续工具循环
  runner.current_iteration = runner.current_iteration + 1
  M._execute_tools(sub_agent_id, tool_calls)
end

-- ========== 清理 ==========

function M.cleanup_all()
  for sub_agent_id, runner in pairs(sub_agent_runners) do
    runner.stop_requested = true
    for _, id in ipairs(runner.autocmd_ids or {}) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
  end
  sub_agent_runners = {}
end

--- 重置（测试用）
function M._test_reset()
  M.cleanup_all()
end

return M
