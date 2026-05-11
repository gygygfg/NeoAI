-- 子 agent 生命周期管理器
-- 职责：
--   1. 管理子 agent 的生命周期（创建、完成、清理）
--   2. 审核子 agent 的工具调用边界（委托给 plan_executor）
--   3. 构建子 agent 的系统提示词
--   4. 处理子 agent 的 AI 生成请求
--
-- 工具循环控制已统一由 tool_orchestrator 管理
-- sub_agent_engine 不再维护独立的循环控制逻辑

local M = {}

local logger = require("NeoAI.utils.logger")
local state_manager = require("NeoAI.core.config.state")
local event_constants = require("NeoAI.core.events")
local plan_executor = require("NeoAI.tools.builtin.plan_executor")
local request_builder = require("NeoAI.core.ai.request_builder")

-- ========== 子 agent 执行状态 ==========

local sub_agent_runners = {} -- sub_agent_id -> runner state

-- ========== 工具调用审核 ==========

--- 审核子 agent 的工具调用是否超出边界
--- 由 tool_orchestrator._execute_single_tool 在每次工具执行前调用
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

-- ========== 子 agent 工具循环 ==========

--- 启动子 agent 的工具循环
--- 注册子 agent 会话到 tool_orchestrator，然后通过 TOOL_RESULT_RECEIVED 事件触发 AI 生成
--- @param sub_agent_id string
--- @param tool_calls table 子 agent 首次返回的工具调用列表
--- @param session_context table 会话上下文
function M.start_sub_agent_loop(sub_agent_id, tool_calls, session_context)
  logger.debug("[sub_agent] start_sub_agent_loop: id=%s, tool_calls=%d", sub_agent_id, #(tool_calls or {}))

  local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")

  -- 注册子 agent 会话到 tool_orchestrator
  tool_orchestrator.register_sub_agent_session(sub_agent_id, session_context.session_id, session_context.window_id, {
    messages = session_context.messages or {},
    options = session_context.options or {},
    model_index = session_context.model_index or 1,
    ai_preset = session_context.ai_preset or {},
    on_summary = session_context.on_summary,
  })

  -- 注入子 agent ID 到工具调用
  M.inject_sub_agent_id(tool_calls, sub_agent_id)

  -- 构建子 agent 的系统提示词
  local context = plan_executor.get_sub_agent_context(sub_agent_id)
  local system_prompt = _build_sub_agent_system_prompt(context)

  -- 构建消息列表
  local messages = {}
  table.insert(messages, {
    role = "system",
    content = system_prompt,
  })
  table.insert(messages, {
    role = "user",
    content = string.format(
      "请执行以下任务：%s\n\n请使用可用的工具来完成此任务。完成任务后，请说明结果。",
      context and context.task or ""
    ),
  })

  -- 生成唯一的 generation_id
  local generation_id = "sub_agent_" .. sub_agent_id .. "_" .. os.time() .. "_" .. math.random(10000, 99999)

  -- 通过 TOOL_RESULT_RECEIVED 事件触发 AI 生成
  -- 携带 _sub_agent_id 标记，让 ai_engine.handle_tool_result 知道这是子 agent 请求
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_RESULT_RECEIVED,
    data = {
      generation_id = generation_id,
      tool_results = {},
      session_id = session_context.session_id,
      window_id = session_context.window_id,
      messages = messages,
      options = session_context.options or {},
      model_index = session_context.model_index or 1,
      ai_preset = session_context.ai_preset or {},
      accumulated_usage = {},
      last_reasoning = nil,
      _sub_agent_id = sub_agent_id,
    },
  })
end

-- ========== 子 agent 完成处理 ==========

--- 结束子 agent 并触发总结回调
--- 由 tool_orchestrator._finish_loop 在子 agent 循环结束时调用
--- @param sub_agent_id string
--- @param result string|nil 最终结果
function M._finalize_sub_agent(sub_agent_id, result)
  local runner = sub_agent_runners[sub_agent_id]
  if not runner then
    return
  end

  -- 标记子 agent 完成
  plan_executor._finalize_sub_agent(sub_agent_id)

  -- 获取执行总结
  local summary = plan_executor.get_summary(sub_agent_id) or result or "子 agent 执行完成，但未生成总结"

  -- 通过回调返回总结给主 agent
  if runner.on_summary then
    local cb = runner.on_summary
    runner.on_summary = nil
    pcall(cb, summary)
  end

  -- 清理 runner
  sub_agent_runners[sub_agent_id] = nil

  -- 注销 tool_orchestrator 中的子 agent 会话
  local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
  tool_orchestrator.unregister_sub_agent_session(sub_agent_id)
end

-- ========== AI 生成请求 ==========

--- 发起子 agent 的 AI 生成请求
--- 由 tool_orchestrator._request_generation 在子 agent 需要下一轮生成时调用
--- @param sub_agent_id string
function M._request_generation(sub_agent_id)
  local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
  local ss = tool_orchestrator.get_session_state(sub_agent_id)
  if not ss or ss.stop_requested then
    return
  end

  -- 退出时跳过
  if require("NeoAI.core.shutdown_flag").is_set() then
    return
  end

  -- 检查迭代上限
  local max_iter = ss.max_iterations or 10
  if ss.current_iteration >= max_iter then
    M._finalize_sub_agent(sub_agent_id, "达到最大迭代轮次")
    return
  end

  -- 同步迭代计数到 plan_executor
  plan_executor.update_iteration_count(sub_agent_id, ss.current_iteration + 1)

  -- 检查是否应该继续
  if not plan_executor.should_continue(sub_agent_id) then
    M._finalize_sub_agent(sub_agent_id)
    return
  end

  -- 生成新的 generation_id
  local old_generation_id = ss.generation_id
  ss.generation_id = "sub_agent_" .. sub_agent_id .. "_" .. os.time() .. "_" .. math.random(10000, 99999)
  pcall(function()
    require("NeoAI.utils.http_utils").clear_dedup(old_generation_id)
  end)

  -- 构建子 agent 的系统提示词
  local context = plan_executor.get_sub_agent_context(sub_agent_id)
  if not context then
    M._finalize_sub_agent(sub_agent_id)
    return
  end
  local system_prompt = _build_sub_agent_system_prompt(context)

  -- 构建消息列表
  local messages = {}
  table.insert(messages, {
    role = "system",
    content = system_prompt,
  })

  -- 从 ss.messages 中获取子 agent 的消息历史
  local runner_msgs = ss.messages or {}
  local filtered_msgs = {}
  for _, msg in ipairs(runner_msgs) do
    table.insert(filtered_msgs, vim.deepcopy(msg))
  end

  -- 检查并移除末尾孤立的 assistant 消息
  local last_msg = filtered_msgs[#filtered_msgs]
  local has_trailing_tool_calls = last_msg
    and last_msg.role == "assistant"
    and last_msg.tool_calls
    and #last_msg.tool_calls > 0
  if has_trailing_tool_calls then
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
      table.remove(filtered_msgs)
    end
  end

  for _, msg in ipairs(filtered_msgs) do
    table.insert(messages, msg)
  end

  -- 检查是否需要添加 user 消息
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
        "请继续执行以下任务：%s\n\n请使用可用的工具来完成此任务。",
        context.task
      ),
    })
  end

  -- 触发 TOOL_RESULT_RECEIVED 事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.TOOL_RESULT_RECEIVED,
    data = {
      generation_id = ss.generation_id,
      tool_results = {},
      session_id = ss._parent_session_id or sub_agent_id,
      window_id = ss.window_id,
      messages = messages,
      options = ss.options,
      model_index = ss.model_index,
      ai_preset = ss.ai_preset,
      accumulated_usage = ss.accumulated_usage or {},
      last_reasoning = ss.last_reasoning,
      _sub_agent_id = sub_agent_id,
    },
  })
end

-- ========== 辅助函数 ==========

--- 注入子 agent ID 到工具调用
--- @param tool_calls table
--- @param sub_agent_id string
function M.inject_sub_agent_id(tool_calls, sub_agent_id)
  for _, tc in ipairs(tool_calls or {}) do
    local func = tc["function"] or tc.func
    if func then
      local args = func.arguments
      if type(args) == "table" then
        args._sub_agent_id = sub_agent_id
      end
    end
  end
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

-- ========== 停止控制 ==========

function M.request_stop(sub_agent_id)
  local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
  tool_orchestrator.request_stop(sub_agent_id)
end

function M.is_running(sub_agent_id)
  local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
  local ss = tool_orchestrator.get_session_state(sub_agent_id)
  return ss ~= nil and not ss.stop_requested
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
