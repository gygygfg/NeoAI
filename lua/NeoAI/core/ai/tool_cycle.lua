---@diagnostic disable: undefined-global, unused-local, redefined-local, unused-function
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

-- 模块局部变量：参数修正重试计数，按 (session_id, tool_name) 为 key
local _param_retry_counts = {}
local _inline_fuzzy_match

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local tool_pack = require("NeoAI.tools.tool_pack")
local shutdown_flag = require("NeoAI.core.shutdown_flag")
local tool_executor = require("NeoAI.tools.tool_executor")
local request_handler = require("NeoAI.core.ai.request_handler")
local state_manager = require("NeoAI.core.config.state")
local plan_executor = require("NeoAI.tools.builtin.plan_executor")

-- 性能优化：延迟求值 debug.traceback()，仅在 DEBUG 级别时计算
-- debug.traceback() 是 Lua 中开销最大的操作之一，不应在非 DEBUG 模式下执行
local function _traceback_if_debug()
  if logger.get_level and logger.get_level() == "DEBUG" then
    return debug.traceback()
  end
  return "traceback_disabled"
end

-- 单条工具结果内容最大长度（字符数），超出部分截断
-- 防止大文件读取或命令输出撑爆消息上下文
local MAX_TOOL_RESULT_LENGTH = 32000  -- 32KB

-- 单次请求最大 body 大小（字节），超过此大小直接报错并打印完整请求体
-- 61MB 的请求体导致 DeepSeek 等模型空闲超时（30s），触发重试死循环
-- 设置为 10MB，给正常请求留足空间
local MAX_BODY_SIZE_BYTES = 10 * 1024 * 1024  -- 10MB

-- 估算消息列表序列化为 JSON 后的 body 大小（字节）
-- 使用近似估算而非完整序列化，避免性能开销
-- @param messages table 消息列表
-- @return number 估算的 body 大小（字节）
local function _estimate_body_size(messages)
  local size = 0
  for _, msg in ipairs(messages) do
    -- 每条消息的固定开销（role, tool_call_id 等字段）
    size = size + 50
    if msg.content and type(msg.content) == "string" then
      size = size + #msg.content
    end
    if msg.name then
      size = size + #msg.name
    end
    if msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        size = size + 100  -- tool_call 固定开销
        if tc["function"] then
          size = size + #(tc["function"].name or "")
          size = size + #(tc["function"].arguments or "")
        end
        if tc.func then
          size = size + #(tc.func.name or "")
          size = size + #(tc.func.arguments or "")
        end
      end
    end
  end
  return size
end

-- 截断 oversized 的 tool 结果内容，使 body 大小不超过 MAX_BODY_SIZE_BYTES
-- 从最旧的 tool 消息开始截断，保留最新的 tool 结果完整
-- @param messages table 消息列表
-- @param system_count number 系统消息数量
local function _truncate_oversized_tool_results(messages, system_count)
  local estimated = _estimate_body_size(messages)
  if estimated <= MAX_BODY_SIZE_BYTES then
    return
  end

  logger.warn(
    "[tool_orchestrator] body 大小 %.1fMB 超过限制 %.1fMB，开始截断 tool 结果",
    estimated / (1024 * 1024),
    MAX_BODY_SIZE_BYTES / (1024 * 1024)
  )

  -- 打印消息摘要到日志，帮助诊断 body 膨胀原因
  local summary_lines = {}
  table.insert(summary_lines, "===== 请求体超限，消息摘要 =====")
  table.insert(summary_lines, string.format("消息总数: %d, 估算大小: %.1fMB", #messages, estimated / (1024 * 1024)))
  for i, msg in ipairs(messages) do
    local tc_args_size = 0
    if msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        if tc["function"] then
          tc_args_size = tc_args_size + #(tc["function"].arguments or "")
        end
        if tc.func then
          tc_args_size = tc_args_size + #(tc.func.arguments or "")
        end
      end
    end
    table.insert(summary_lines, string.format("  [%d] role=%-10s name=%-20s content_len=%-8d tool_calls=%-2d tc_args_size=%-8d",
      i, msg.role or "?", msg.name or "-", #(msg.content or ""),
      msg.tool_calls and #msg.tool_calls or 0, tc_args_size))
  end
  logger.warn("[tool_orchestrator] 请求体超限消息摘要:\n%s", table.concat(summary_lines, "\n"))

  -- 从最旧的 tool 消息开始截断，保留最新的 tool 结果完整
  -- 收集所有 tool 消息的索引
  local tool_indices = {}
  for i = system_count + 1, #messages do
    if messages[i].role == "tool" and messages[i].content and #messages[i].content > 500 then
      table.insert(tool_indices, i)
    end
  end

  -- 从旧到新截断，直到 body 大小低于限制
  for _, idx in ipairs(tool_indices) do
    if _estimate_body_size(messages) <= MAX_BODY_SIZE_BYTES then
      break
    end
    local msg = messages[idx]
    local tool_name = msg.name or "unknown"
    local original_len = #(msg.content or "")
    -- 截断到 500 字符 + 摘要标记
    local summary = (msg.content or ""):sub(1, 500)
    local lower = summary:lower()
    if lower:find("error") or lower:find("失败") or lower:find("错误") or lower:find("fail") then
      msg.content = string.format("[执行失败] 工具: %s, 错误: %s\n...(截断，原大小 %d 字节)", tool_name, summary, original_len)
    else
      msg.content = string.format("[执行成功] 工具: %s\n%s\n...(截断，原大小 %d 字节)", tool_name, summary, original_len)
    end
    logger.debug("[tool_orchestrator] 截断 tool 结果: %s, %d -> %d 字节", tool_name, original_len, #msg.content)
  end

  local final_estimated = _estimate_body_size(messages)
  if final_estimated > MAX_BODY_SIZE_BYTES then
    -- 截断后仍然超限：打印完整请求体到日志，然后报错
    -- 收集所有消息的完整内容用于诊断
    local dump_lines = {}
    table.insert(dump_lines, "===== 请求体过大，截断后仍超限 =====")
    table.insert(dump_lines, string.format("原始大小: %.1fMB, 截断后大小: %.1fMB, 限制: %.1fMB",
      estimated / (1024 * 1024), final_estimated / (1024 * 1024), MAX_BODY_SIZE_BYTES / (1024 * 1024)))
    table.insert(dump_lines, string.format("消息总数: %d", #messages))
    for i, msg in ipairs(messages) do
      local content_preview = ""
      if msg.content and type(msg.content) == "string" then
        content_preview = msg.content:sub(1, 200)
      end
      local tc_count = msg.tool_calls and #msg.tool_calls or 0
      table.insert(dump_lines, string.format("  [%d] role=%s, name=%s, tool_call_id=%s, content_len=%d, tool_calls=%d, content_preview=%s",
        i, msg.role or "?", msg.name or "-", msg.tool_call_id or "-",
        #(msg.content or ""), tc_count, content_preview))
    end
    local dump_text = table.concat(dump_lines, "\n")
    logger.error("[tool_orchestrator] 请求体过大，截断后仍超限:\n%s", dump_text)
    error(string.format("请求体过大: 截断后仍为 %.1fMB (限制 %.1fMB)，已打印完整请求体到日志",
      final_estimated / (1024 * 1024), MAX_BODY_SIZE_BYTES / (1024 * 1024)))
  end

  logger.warn(
    "[tool_orchestrator] 截断后 body 大小: %.1fMB (原 %.1fMB)",
    final_estimated / (1024 * 1024),
    estimated / (1024 * 1024)
  )
end

-- 检查消息 body 大小，超限时截断 tool 结果或直接报错
-- 取消消息数量轮次限制，只保留 body 大小限制
local function _trim_messages(messages)
  -- 只检查 body 大小，不限制消息数量
  -- 找到系统消息数量用于截断逻辑
  local system_count = 0
  for _, msg in ipairs(messages) do
    if msg.role == "system" then system_count = system_count + 1 else break end
  end
  _truncate_oversized_tool_results(messages, system_count)
end

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

-- ========== 文件修改确认工具 ==========
--- AI 预览文件修改后，通过此工具确认执行、放弃修改或覆盖参数重试
local _CONFIRM_TOOL_NAME = "confirm_file_change"

--- confirm_file_change 的工具定义（OpenAI 格式）
--- 统一处理：确认执行、拒绝修改、放弃修改、覆盖参数重试
local _CONFIRM_TOOL_DEF = {
  type = "function",
  ["function"] = {
    name = _CONFIRM_TOOL_NAME,
    description = [[处理文件修改的最终决定。当工具执行涉及文件写入操作时，AI 会先看到模拟的修改结果（修改点附近 ±10 行的内容），然后需要调用此工具来决定如何处理。

选项说明（三选一）：
1. 确认执行：设置 action="confirm"，进入用户审批流程
2. 放弃修改：设置 action="abandon"，不再尝试修改此文件
3. 覆盖参数重试：设置 action="retry"，同时传入修正后的 arguments 重新执行

注意：action="retry" 最多可重试 3 次，超过后将自动放弃。]],
    strict = true,
    parameters = {
      type = "object",
      properties = {
        action = {
          type = "string",
          description = [[操作类型：
- "confirm": 确认执行修改，进入用户审批流程
- "abandon": 放弃修改，不再尝试
- "retry": 覆盖参数后重试（需同时传入 arguments）]],
          enum = { "confirm", "abandon", "retry" },
        },
        reason = {
          type = "string",
          description = "操作原因说明（必填）",
        },
        arguments = {
          type = "object",
          description = "仅当 action='retry' 时必填。修正后的参数，key-value 格式。例如修正文件路径、修改内容等。",
          additionalProperties = true,
        },
      },
      required = { "action", "reason" },
      additionalProperties = false,
    },
  },
}

--- 注册 confirm_file_change 到 request_handler 的工具定义中
local function _register_confirm_tool()
  local current_defs = request_handler.get_tool_definitions() or {}
  -- 检查是否已存在，避免重复注册
  for _, def in ipairs(current_defs) do
    local def_name = (def["function"] and def["function"].name) or def.name or ""
    if def_name == _CONFIRM_TOOL_NAME then
      return
    end
  end
  table.insert(current_defs, vim.deepcopy(_CONFIRM_TOOL_DEF))
  request_handler.set_tool_definitions(current_defs)
end

--- 从 request_handler 的工具定义中移除 confirm_file_change
local function _unregister_confirm_tool()
  local current_defs = request_handler.get_tool_definitions() or {}
  local filtered = {}
  for _, def in ipairs(current_defs) do
    local def_name = (def["function"] and def["function"].name) or def.name or ""
    if def_name ~= _CONFIRM_TOOL_NAME then
      table.insert(filtered, def)
    end
  end
  request_handler.set_tool_definitions(filtered)
end
--- 委托给统一的 shutdown_flag 模块
function M.set_shutting_down()
  shutdown_flag.set()
end

--- 等待 TOOL_DISPLAY_CLOSED 事件后执行回调
--- 优化：使用 vim.defer_fn 延迟 150ms 执行回调，让出事件循环以避免 CPU 尖峰
--- 之前的同步执行会在工具完成时立即触发下一轮，导致紧密循环
--- 150ms 的延迟对人类感知无影响，但能显著降低 CPU 占用并避免回调风暴
---@diagnostic disable-next-line: unused-local
local function once_display_closed(session_id, callback)
  if is_shutting_down() then
    return
  end
  -- 使用 vim.defer_fn 延迟执行回调，让出事件循环
  -- pcall 保护：防止回调异常导致后续状态转换无法执行
  vim.defer_fn(function()
    if is_shutting_down() then
      return
    end
    local ok, err = pcall(callback)
    if not ok then
      logger.warn("[tool_orchestrator] once_display_closed 回调异常: %s", tostring(err))
    end
  end, 150)
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

  local ok, _ = pcall(vim.api.nvim_exec_autocmds, "User", {
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

  local ok, _ = pcall(vim.api.nvim_exec_autocmds, "User", {
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
    _param_retry_count = 0, -- 参数修正重试计数（工具执行失败后 AI 修正参数的重试）
    _generation_completed = false, -- GENERATION_COMPLETED 事件是否已到达
    _tools_all_completed = false, -- TOOL_EXECUTION_ALL_COMPLETED 事件是否已到达
    _executed_tool_call_ids = {}, -- 已执行过的 tool_call_id 集合（用于去重）
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

        -- 注意：不在此处调用 _check_round_complete，因为 _generation_completed 尚未被设置。
        -- on_generation_complete() 会在设置 _generation_completed=true 后通过 _execute_tools
        -- → _on_tools_complete → _check_round_complete 的路径触发轮次检查。
        -- 在此处调用会导致 _check_round_complete 发现 _generation_completed=false 而进入等待，
        -- 而本模块已废弃轮询机制，直接 return 不会重试，可能导致循环卡死。
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
  -- 清理该 session 相关的参数重试计数，防止内存泄漏
  local prefix = session_id .. ":"
  for key, _ in pairs(_param_retry_counts) do
    if vim.startswith(key, prefix) then
      _param_retry_counts[key] = nil
    end
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
  -- 清理该 sub_agent 相关的参数重试计数，防止内存泄漏
  local prefix = sub_agent_id .. ":"
  for key, _ in pairs(_param_retry_counts) do
    if vim.startswith(key, prefix) then
      _param_retry_counts[key] = nil
    end
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

  -- 重置文件变更追踪器，为新工具循环做准备
  -- 注意：在 _proceed_to_next_round 中不重置，而是在此处（新轮次开始时）重置
  -- 确保 _proceed_to_next_round → _request_generation → build_request 生成节点报告时文件追踪器仍然有效
  request_handler.reset_file_tracker()

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
        ---@diagnostic disable-next-line: redefined-local
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

  -- 重置 _tools_complete_in_progress，确保新轮次工具完成后能正常触发 _on_tools_complete。
  -- 上一轮 _on_tools_complete 进入下一轮后可能保持 _tools_complete_in_progress=true
  -- 以阻止旧工具回调绕过保护，新轮次开始前必须重置。
  ss._tools_complete_in_progress = false

  -- 如果已请求停止，跳过所有工具执行
  if ss.stop_requested then
    return
  end

  -- 防止重复触发：如果 phase 已经是 waiting_tools，说明 _execute_tools 已被调用过
  -- 此时工具正在执行中，跳过本次调用避免重复执行
  if ss.phase == "waiting_tools" then
    local tool_names_str = ""
    for _, tc in ipairs(tool_calls) do
      local func = tc["function"] or tc.func
      local name = func and func.name or "unknown"
      local tid = tc.id or "no-id"
      tool_names_str = tool_names_str .. name .. "(" .. tid .. "), "
    end
    logger.warn(
      "[tool_orchestrator] _execute_tools 跳过: phase 已是 waiting_tools, session=%s, tools=[%s], stack=%s",
      tostring(session_id),
      tool_names_str,
      _traceback_if_debug()
    )
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
    _traceback_if_debug()
  )

  -- 清空前检查是否有活跃工具调用（竞态检测）
  local prev_active_count = vim.tbl_count(ss.active_tool_calls)
  if prev_active_count > 0 then
    require("NeoAI.utils.logger").warn(
      "[tool_orchestrator] _execute_tools: 清空 %d 个活跃工具调用, session=%s, stack=%s",
      prev_active_count,
      tostring(session_id),
      _traceback_if_debug()
    )
  end
  ss.phase = "waiting_tools"
  -- 原地清理而非替换表引用：避免孤立仍在异步执行中的旧工具回调。
  -- 旧回调通过 sessions_table[session_id].active_tool_calls 动态访问，替换表引用会导致
  -- 旧回调写入新表、污染新轮次的工具计数，引发错误的 _on_tools_complete 触发。
  for k in pairs(ss.active_tool_calls) do
    ss.active_tool_calls[k] = nil
  end

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

  -- 第一步：预注册所有工具的 tool_call_id，防止同步工具在循环中立即完成
  -- 时误判所有工具已执行完毕（竞态条件）
  for _, tc in ipairs(tool_calls) do
    local tool_func = tc["function"] or tc.func
    if tool_func and tool_func.name then
      local tid = tc.id
      if not tid or tid == "" then
        if not M._tool_call_counter then
          M._tool_call_counter = 0
        end
        M._tool_call_counter = M._tool_call_counter + 1
        tid = "call_" .. os.time() .. "_" .. M._tool_call_counter .. "_" .. math.random(10000, 99999)
        tc.id = tid
      end
      ss.active_tool_calls[tid] = true
    end
  end

  -- 第二步：异步并发执行所有工具
  -- 所有工具同时通过 vim.schedule 启动，利用 Neovim 事件循环并发执行
  -- 每个工具完成时从 active_tool_calls 中移除自己
  -- 当 active_tool_calls 为空时触发 _on_tools_complete
  -- 注意：需要审批的工具在审批通过前 active_tool_calls 中仍有记录
  -- 因此不会误触发完成
  for _, tc in ipairs(tool_calls) do
    vim.schedule(function()
      local s = sessions_table[session_id]
      if not s or s.stop_requested then
        return
      end
      M._execute_single_tool(session_id, tc, is_sub_agent, nil)
    end)
  end

  -- ===== 工具执行超时保护 =====
  -- 如果某些工具的 on_result 回调因异常（工具 hang、crash 等）永不触发，
  -- active_tool_calls 中对应的条目永远不会被移除，导致 _on_tools_complete 永远不被调用，
  -- 整个工具循环永久卡死。此超时作为兜底保护。
  -- 默认 300 秒（5 分钟），可通过 M.tool_timeout_ms 配置。
  -- 注意：超时检查会跳过正在等待审批的工具（approval_handler.is_showing() 或队列非空），
  -- 避免在用户审批期间强制推进循环。
  local timeout_ms = M.tool_timeout_ms or 300000 -- 默认 300 秒，可通过 M.tool_timeout_ms 配置
  local timeout_gen = ss.generation_id -- 捕获当前的 generation_id，防止跨轮误触发
  -- 超时重试计数：审批等待最多重试 60 次（每次 5 秒 = 额外 5 分钟）
  local timeout_retries = 0
  local max_timeout_retries = 60
  local function _timeout_check()
    local s = sessions_table[session_id]
    if not s then
      return
    end
    -- 仅当 generation_id 匹配（未进入新轮次）且仍有活跃工具时才触发超时
    if s.generation_id == timeout_gen and vim.tbl_count(s.active_tool_calls) > 0 then
      -- 检查是否有工具正在等待审批，如果有则延长等待
      local approval_ok, approval_handler = pcall(require, "NeoAI.tools.approval_handler")
      if approval_ok and approval_handler then
        if approval_handler.is_showing() or approval_handler.queue_length() > 0 then
          if timeout_retries < max_timeout_retries then
            timeout_retries = timeout_retries + 1
            logger.debug(
              "[tool_orchestrator] 工具执行超时检查: 仍有审批进行中 (showing=%s, queue=%d)，延长等待 (%d/%d)",
              tostring(approval_handler.is_showing()),
              approval_handler.queue_length(),
              timeout_retries,
              max_timeout_retries
            )
            -- 审批仍在进行中，延长 5 秒后重新检查
            vim.defer_fn(_timeout_check, 5000)
            return
          end
          logger.warn(
            "[tool_orchestrator] 工具执行超时: 审批等待次数已达上限 (%d)，强制推进",
            max_timeout_retries
          )
        end
      end

      local stuck_ids = {}
      for tid in pairs(s.active_tool_calls) do
        table.insert(stuck_ids, tid)
      end
      logger.warn(
        "[tool_orchestrator] 工具执行超时 (%d ms), 强制完成 %d 个卡住的工具调用: %s, session=%s",
        timeout_ms,
        #stuck_ids,
        table.concat(stuck_ids, ", "),
        tostring(session_id)
      )
      -- 强制清理：移除所有卡住的工具调用
      for _, tid in ipairs(stuck_ids) do
        s.active_tool_calls[tid] = nil
      end
      -- 强制触发完成
      if s.phase ~= "round_complete" then
        M._on_tools_complete(session_id, is_sub_agent)
      end
    end
  end
  vim.defer_fn(_timeout_check, timeout_ms)
end

function M._execute_single_tool(session_id, tool_call, is_sub_agent, on_complete)
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local ss = sessions_table[session_id]
  if not ss or not tool_call then
    if on_complete then
      on_complete()
    end
    return
  end

  -- 如果已请求停止，跳过工具执行
  if ss.stop_requested then
    if on_complete then
      on_complete()
    end
    return
  end

  local tool_func = tool_call["function"] or tool_call.func
  if not tool_func then
    logger.warn(
      "[tool_orchestrator] _execute_single_tool: tool_call 缺少 function 字段, tool_call=" .. vim.inspect(tool_call)
    )
    if on_complete then
      on_complete()
    end
    return
  end

  local tool_name = tool_func.name
  if not tool_name or tool_name == "" then
    logger.warn("[tool_orchestrator] _execute_single_tool: tool_func.name 为空, tool_func=" .. vim.inspect(tool_func))
    if on_complete then
      on_complete()
    end
    return
  end

  -- ===== 工具名称修正（别名映射 + 模糊匹配） =====
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
  -- 内联实现，避免调用已废弃的 M._fuzzy_match_tool
  if not tool_def then
    local all_tools = tool_registry.list()
    local all_names = {}
    for _, t in ipairs(all_tools) do
      table.insert(all_names, t.name)
    end
    local best_match = _inline_fuzzy_match(original_tool_name, all_names)
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

  -- 调试日志：追踪 _execute_single_tool 调用（仅在 DEBUG 级别时发费性能求值）
  local log_mod = require("NeoAI.utils.logger")
  if log_mod.get_level and log_mod.get_level() == "DEBUG" then
    log_mod.debug(
      "[DEBUG_DUP] _execute_single_tool: session=%s, tool=%s, tool_call_id=%s, active_count=%d, stack=%s",
      tostring(session_id),
      tostring(tool_name),
      tostring(tool_call.id or "nil"),
      vim.tbl_count(ss.active_tool_calls or {}),
      debug.traceback()
    )
  end

  -- 生成唯一 tool_call_id（如果已在 _execute_tools 中预注册，则跳过）
  local tool_call_id = tool_call.id
  if not tool_call_id or tool_call_id == "" then
    if not M._tool_call_counter then
      M._tool_call_counter = 0
    end
    M._tool_call_counter = M._tool_call_counter + 1
    tool_call_id = "call_" .. os.time() .. "_" .. M._tool_call_counter .. "_" .. math.random(10000, 99999)
    tool_call.id = tool_call_id
  end
  -- 如果 _execute_tools 已预注册，不再重复添加
  if not ss.active_tool_calls[tool_call_id] then
    ss.active_tool_calls[tool_call_id] = true
  end

  -- ===== tool_call_id 级别去重：防止同一个工具调用被执行两次 =====
  if ss._executed_tool_call_ids[tool_call_id] then
    require("NeoAI.utils.logger").warn(
      "[tool_orchestrator] _execute_single_tool 跳过: tool_call_id 已执行过, session=%s, tool=%s, tool_call_id=%s",
      tostring(session_id),
      tostring(tool_name),
      tostring(tool_call_id)
    )
    if on_complete then
      on_complete()
    end
    return
  end
  ss._executed_tool_call_ids[tool_call_id] = true

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
      if on_complete then
        on_complete()
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

    local pack_name = tool_pack.get_pack_for_tool(tool_name)

    -- execute_with_orchestrator 返回规范化后的参数
    ---@diagnostic disable-next-line: unused-local
    local normalized_args = tool_executor.execute_with_orchestrator(tool_name, tool_func.arguments, {
      session_id = session_id,
      window_id = ss.window_id,
      generation_id = ss.generation_id,
      tool_call_id = tool_call_id,
      pack_name = pack_name,
    }, {
      on_result = function(success, result)
        local s = sessions_table[session_id]
        if not s then
          if on_complete then
            on_complete()
          end
          return
        end

        if s.stop_requested then
          s.active_tool_calls[tool_call_id] = nil
          if vim.tbl_count(s.active_tool_calls) == 0 then
            M._on_tools_complete(session_id, is_sub_agent)
            if on_complete then
              on_complete()
            end
          end
          return
        end

        if success and result then
          -- 工具执行成功，清除该工具的参数重试计数（避免 key 残留导致内存泄漏）
          local retry_key = session_id .. ":" .. tool_name
          _param_retry_counts[retry_key] = nil

          local result_str = type(result) == "string" and result or ""
          local _, parsed_result = pcall(vim.json.decode, result_str)
          local sub_agent_id = parsed_result and parsed_result.sub_agent_id or nil

          if sub_agent_id then
            plan_executor.record_message(sub_agent_id, "system", "子 agent 已创建，任务: " .. (args.task or ""))
          end

          M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str, is_sub_agent, normalized_args)

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

                -- 通知 UI 刷新：子 agent 摘要已添加到消息列表
                pcall(vim.api.nvim_exec_autocmds, "User", {
                  pattern = event_constants.SUB_AGENT_SUMMARY_READY,
                  data = {
                    session_id = session_id,
                    sub_agent_id = sub_agent_id,
                    window_id = s2.window_id,
                  },
                })

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

          -- 合并修正提示到 tool 消息内容中（不插入独立的 user 消息，避免违反 API 规范）
          -- 每个工具独立计数，互不影响
          local retry_key = session_id .. ":" .. tool_name
          local tool_retry_count = _param_retry_counts[retry_key] or 0
          if tool_retry_count < 3 then
            _param_retry_counts[retry_key] = tool_retry_count + 1
            local combined_msg = string.format(
              "[工具执行失败] %s\n\n"
                .. "请直接重新调用工具 `%s`，使用修正后的参数重试。\n"
                .. "（修正尝试 %d/3，超过后自动放弃）",
              err_msg,
              tool_name,
              _param_retry_counts[retry_key]
            )
            M._add_tool_result_to_messages(
              session_id,
              tool_call_id,
              tool_name,
              combined_msg,
              is_sub_agent,
              normalized_args
            )
            logger.debug(
              "[tool_orchestrator] 工具 '%s' 执行失败，等待 AI 修正参数重试 (尝试 %d/3)",
              tool_name,
              _param_retry_counts[retry_key]
            )
          else
            _param_retry_counts[retry_key] = nil
            M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, err_msg, is_sub_agent, normalized_args)
          end
        end

        s.active_tool_calls[tool_call_id] = nil
        local remaining = vim.tbl_count(s.active_tool_calls)
        if remaining == 0 and s.phase ~= "round_complete" then
          M._on_tools_complete(session_id, is_sub_agent)
        end
        if on_complete then
          on_complete()
        end
      end,
    })
    return
  end

  -- ===== 拦截 confirm_file_change 调用（统一处理确认/放弃/重试） =====
  if tool_name == _CONFIRM_TOOL_NAME then
    local args = tool_func.arguments or {}
    if type(args) ~= "table" then
      args = {}
    end
    local action = args.action or ""
    local reason = args.reason or ""
    local corrected_args = args.arguments or {}

    -- 移除 confirm_file_change 工具定义
    _unregister_confirm_tool()

    -- 查找上一个 write 工具的信息
    local last_write_tool_name = nil
    local last_write_args = nil

    for i = #ss.messages, 1, -1 do
      local msg = ss.messages[i]
      if msg.role == "tool" and msg.name then
        if tool_executor._is_write_tool(msg.name) then
          last_write_tool_name = msg.name
          if msg.normalized_args then
            last_write_args = vim.deepcopy(msg.normalized_args)
          end
          break
        end
      end
    end

    local substep_tool_name = last_write_tool_name or tool_name

    -- ===== action = "confirm"：确认执行，进入用户审批 =====
    if action == "confirm" then
      -- 更新 AI 检查子步骤状态
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_EXECUTION_SUBSTEP,
        data = {
          tool_name = substep_tool_name,
          substep_name = "AI 检查",
          status = "completed",
          duration = 0,
          detail = "AI 已确认: " .. reason,
          session_id = session_id,
        },
      })

      if last_write_tool_name and last_write_args then
        local result_str = string.format(
          "[AI 已确认文件修改] 原因: %s\n\nAI 已确认上述文件修改，正在进入用户审批流程...",
          reason
        )
        M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str, is_sub_agent)

        local pack_name = tool_pack.get_pack_for_tool(last_write_tool_name)

        last_write_args._needs_ai_preview = nil
        last_write_args._approval_timeout_ms = nil

        if not M._tool_call_counter then
          M._tool_call_counter = 0
        end
        M._tool_call_counter = M._tool_call_counter + 1
        local new_tool_call_id = "call_confirm_"
          .. os.time()
          .. "_"
          .. M._tool_call_counter
          .. "_"
          .. math.random(10000, 99999)

        vim.schedule(function()
          local s = sessions_table[session_id]
          if not s or s.stop_requested then
            return
          end

          s.active_tool_calls[new_tool_call_id] = true

          ---@diagnostic disable-next-line: unused-local
          local normalized_args = tool_executor.execute_with_orchestrator(last_write_tool_name, last_write_args, {
            session_id = session_id,
            window_id = ss.window_id,
            generation_id = ss.generation_id,
            tool_call_id = new_tool_call_id,
            pack_name = pack_name,
          }, {
            on_result = function(_, result)
              local s2 = sessions_table[session_id]
              if not s2 then
                return
              end

              ---@diagnostic disable-next-line: redefined-local
              local result_str = type(result) == "string" and result or vim.json.encode(result) or ""
              M._add_tool_result_to_messages(
                session_id,
                new_tool_call_id,
                last_write_tool_name,
                result_str,
                is_sub_agent,
                normalized_args
              )

              s2.active_tool_calls[new_tool_call_id] = nil
              local remaining = vim.tbl_count(s2.active_tool_calls)
              if remaining == 0 and s2.phase ~= "round_complete" then
                M._on_tools_complete(session_id, is_sub_agent)
              end
            end,
          })
        end)
        -- 关键：write 工具已通过 vim.schedule 异步调度，其 on_result 回调负责清理和触发 _on_tools_complete。
        -- 必须在此 return，防止穿透到下方的统一清理逻辑（行 1397），否则会提前移除 confirm 的 tool_call_id
        -- 并在 write 工具尚未执行时错误触发 _on_tools_complete → _proceed_to_next_round，导致竞态死锁。
        return
      else
        local result_str =
          "[确认失败] 找不到原始工具调用信息，请重新调用编辑工具来修改文件。"
        M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str, is_sub_agent)
        -- 清理并触发完成，防止穿透到下方的统一清理逻辑（行 1397）
        ss.active_tool_calls[tool_call_id] = nil
        local remaining = vim.tbl_count(ss.active_tool_calls)
        if remaining == 0 and ss.phase ~= "round_complete" then
          M._on_tools_complete(session_id, is_sub_agent)
        end
        if on_complete then
          on_complete()
        end
        return
      end

    -- ===== action = "abandon"：放弃修改 =====
    elseif action == "abandon" then
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.TOOL_EXECUTION_SUBSTEP,
        data = {
          tool_name = substep_tool_name,
          substep_name = "AI 检查",
          status = "error",
          duration = 0,
          detail = "AI 已放弃修改: " .. reason,
          session_id = session_id,
        },
      })

      local result_str = string.format(
        "[AI 放弃修改] 原因: %s\n\nAI 已决定放弃对此文件的修改，不再尝试。",
        reason
      )
      M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str, is_sub_agent)

    -- ===== action = "retry"：覆盖参数重试 =====
    elseif action == "retry" then
      -- 检查重试次数
      local retry_key = session_id .. ":" .. (last_write_tool_name or tool_name)
      local retry_count = _param_retry_counts[retry_key] or 0

      if retry_count >= 3 then
        -- 已达重试上限，自动放弃
        _param_retry_counts[retry_key] = nil
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = event_constants.TOOL_EXECUTION_SUBSTEP,
          data = {
            tool_name = substep_tool_name,
            substep_name = "AI 检查",
            status = "error",
            duration = 0,
            detail = "重试已达上限(3/3)，自动放弃: " .. reason,
            session_id = session_id,
          },
        })

        local result_str = string.format(
          "[重试已达上限] 工具 '%s' 的参数修正重试已达上限 (3/3)，已自动放弃。\n原因: %s",
          last_write_tool_name or tool_name,
          reason
        )
        M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str, is_sub_agent)
      else
        -- 增加重试计数
        _param_retry_counts[retry_key] = retry_count + 1

        -- 更新 AI 检查子步骤状态
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = event_constants.TOOL_EXECUTION_SUBSTEP,
          data = {
            tool_name = substep_tool_name,
            substep_name = "AI 检查",
            status = "executing",
            duration = 0,
            detail = string.format("AI 正在重试 (%d/3): %s", retry_count + 1, reason),
            session_id = session_id,
          },
        })

        -- 用修正后的参数重新执行原工具（仍然走 AI 预览拦截）
        local target_tool = last_write_tool_name or tool_name
        local target_args = corrected_args
        -- 如果 corrected_args 为空且 last_write_args 存在，使用 last_write_args
        if not next(corrected_args) and last_write_args then
          target_args = last_write_args
        end

        local pack_name = tool_pack.get_pack_for_tool(target_tool)

        -- 重新注册 confirm_file_change 工具供 AI 再次确认
        _register_confirm_tool()

        -- 重新执行（仍然走 AI 预览拦截）
        ---@diagnostic disable-next-line: unused-local
        local normalized_args = tool_executor.execute_with_orchestrator(target_tool, target_args, {
          session_id = session_id,
          window_id = ss.window_id,
          generation_id = ss.generation_id,
          tool_call_id = tool_call_id,
          pack_name = pack_name,
        }, {
          on_result = function(_, result)
            local s = sessions_table[session_id]
            if not s then
              _unregister_confirm_tool()
              if on_complete then
                on_complete()
              end
              return
            end

            local result_str = type(result) == "string" and result or vim.json.encode(result) or ""
            M._add_tool_result_to_messages(
              session_id,
              tool_call_id,
              target_tool,
              result_str,
              is_sub_agent,
              normalized_args
            )

            s.active_tool_calls[tool_call_id] = nil
            local remaining = vim.tbl_count(s.active_tool_calls)
            if remaining == 0 and s.phase ~= "round_complete" then
              M._on_tools_complete(session_id, is_sub_agent)
            end
            if on_complete then
              on_complete()
            end
          end,
        })

        -- 返回（避免后续重复处理）
        ss.active_tool_calls[tool_call_id] = nil
        local remaining = vim.tbl_count(ss.active_tool_calls)
        if remaining == 0 and ss.phase ~= "round_complete" then
          M._on_tools_complete(session_id, is_sub_agent)
        end
        if on_complete then
          on_complete()
        end
        return
      end
    else
      -- 未知 action
      local result_str =
        string.format("[无效操作] 未知的操作类型 '%s'，请使用 confirm、abandon 或 retry。", action)
      M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str, is_sub_agent)
    end

    ss.active_tool_calls[tool_call_id] = nil
    local remaining = vim.tbl_count(ss.active_tool_calls)
    if remaining == 0 and ss.phase ~= "round_complete" then
      M._on_tools_complete(session_id, is_sub_agent)
    end
    if on_complete then
      on_complete()
    end
    return
  end

  -- ===== 如果是 write 工具，注册 confirm_file_change 工具供 AI 调用 =====
  if tool_executor._is_write_tool(tool_name) then
    _register_confirm_tool()
    logger.debug(
      "[tool_orchestrator] write 工具 '%s' 已注册 confirm_file_change 工具等待 AI 确认",
      tool_name
    )
  end

  -- ===== 普通工具执行 =====
  local pack_name = tool_pack.get_pack_for_tool(tool_name)

  local execute_fn = function()
    -- execute_with_orchestrator 返回规范化后的参数
    ---@diagnostic disable-next-line: unused-local
    local normalized_args = tool_executor.execute_with_orchestrator(tool_name, tool_func.arguments, {
      session_id = session_id,
      window_id = ss.window_id,
      generation_id = ss.generation_id,
      tool_call_id = tool_call_id,
      pack_name = pack_name,
    }, {
      on_result = function(success, result)
        local s = sessions_table[session_id]
        if not s then
          if on_complete then
            on_complete()
          end
          return
        end

        if s.stop_requested then
          s.active_tool_calls[tool_call_id] = nil
          if vim.tbl_count(s.active_tool_calls) == 0 then
            M._on_tools_complete(session_id, is_sub_agent)
          end
          if on_complete then
            on_complete()
          end
          return
        end

        if success then
          -- 工具执行成功：保存规范化参数到会话历史
          local result_str = type(result) == "string" and result or vim.json.encode(result) or ""
          M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result_str, is_sub_agent, normalized_args)
        else
          -- 判断是否为只读工具
          local is_readonly = tool_executor._is_readonly_tool(tool_name)

          if is_readonly then
            -- 只读工具（read_file、search_files 等）失败不提示重试
            -- 因为文件不存在或路径错误是确定性的，重试也没有意义
            local result_str = string.format(
              "[工具执行失败] %s\n\n"
                .. "提示：这是一个只读操作，失败原因通常是文件不存在或路径错误。\n"
                .. "请检查文件路径是否正确，或使用 list_files/search_files 先确认文件是否存在。",
              tostring(result)
            )
            M._add_tool_result_to_messages(
              session_id,
              tool_call_id,
              tool_name,
              result_str,
              is_sub_agent,
              normalized_args
            )
            logger.debug(
              "[tool_orchestrator] 只读工具 '%s' 执行失败，不提示重试: %s",
              tool_name,
              tostring(result)
            )
          else
            -- 写入工具执行失败：按 (session_id, tool_name) 独立检查重试次数
            local retry_key = session_id .. ":" .. tool_name
            local tool_retry_count = _param_retry_counts[retry_key] or 0

            if tool_retry_count < 3 then
              _param_retry_counts[retry_key] = tool_retry_count + 1

              -- 注册 confirm_file_change 到 request_handler，让 AI 通过工具调用传递修正参数
              _register_confirm_tool()

              -- 构建工具可用参数提示
              local tdef = tool_registry.get(tool_name)
              local param_hint = ""
              if tdef and tdef.parameters and tdef.parameters.properties then
                local props = {}
                for pname, pschema in pairs(tdef.parameters.properties) do
                  local desc = pschema.description or ""
                  local ptype = pschema.type or "any"
                  table.insert(props, string.format("  - %s (%s): %s", pname, ptype, desc))
                end
                if #props > 0 then
                  param_hint = "\n\n工具 " .. tool_name .. " 的可用参数:\n" .. table.concat(props, "\n")
                end
              end

              local result_str = string.format(
                "[工具执行失败] %s\n\n"
                  .. "请直接重新调用工具 `%s`，使用修正后的参数重试。\n"
                  .. "你传入的错误参数:\n"
                  .. "%s\n"
                  .. "%s\n"
                  .. "（修正尝试 %d/3，超过后自动放弃）",
                tostring(result),
                tool_name,
                vim.inspect(normalized_args or tool_func.arguments),
                param_hint,
                _param_retry_counts[retry_key]
              )
              M._add_tool_result_to_messages(
                session_id,
                tool_call_id,
                tool_name,
                result_str,
                is_sub_agent,
                normalized_args
              )

              logger.debug(
                "[tool_orchestrator] 工具 '%s' 执行失败，等待 AI 修正参数重试 (尝试 %d/3)",
                tool_name,
                _param_retry_counts[retry_key]
              )
            else
              -- 该工具重试已达上限，自动放弃，不再提示重试
              _param_retry_counts[retry_key] = nil
              local skip_msg = string.format(
                "[工具调用已放弃] 工具 '%s' 的参数修正重试已达上限 (3/3)，已自动放弃此修改。",
                tool_name
              )
              M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, skip_msg, is_sub_agent, normalized_args)
              logger.warn(
                "[tool_orchestrator] 工具 '%s' 参数修正重试已达上限 (3/3)，已自动放弃",
                tool_name
              )
            end
          end
        end

        s.active_tool_calls[tool_call_id] = nil
        local remaining = vim.tbl_count(s.active_tool_calls)

        if remaining == 0 and s.phase ~= "round_complete" then
          M._on_tools_complete(session_id, is_sub_agent)
        end
        -- on_complete 无条件调用（并发模式下由外部 completed_count 控制完成检测）
        if on_complete then
          on_complete()
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

  -- 工具执行完毕，清理 confirm_file_change（如果 AI 没有调用它而是调用了其他工具）
  _unregister_confirm_tool()

  -- 调试日志：追踪 _on_tools_complete 调用
  require("NeoAI.utils.logger").debug(
    "[DEBUG_DUP] _on_tools_complete: session=%s, phase=%s, iter=%d, _tools_complete_in_progress=%s, active_count=%d, stack=%s",
    tostring(session_id),
    tostring(ss.phase),
    ss.current_iteration or 0,
    tostring(ss._tools_complete_in_progress),
    vim.tbl_count(ss.active_tool_calls or {}),
    _traceback_if_debug()
  )

  -- 防止重复触发：如果 _tools_all_completed 已为 true，说明 _on_tools_complete
  -- 已经被调用过（或正在执行），不应再次进入。
  -- 注意：_tools_complete_in_progress 保护在异步回调场景下可能失效，
  -- 因为 once_display_closed 回调中会重置它，导致后续工具回调绕过保护。
  if ss._tools_all_completed or ss._tools_complete_in_progress then
    return
  end
  ss._tools_complete_in_progress = true

  -- 标记 TOOL_EXECUTION_ALL_COMPLETED 已到达（在防重入检查之后设置）
  ss._tools_all_completed = true

  -- ===== 按对话轮次分割，精简非最后一轮的 tool 消息 =====
  -- _add_tool_result_to_messages 中所有 tool 消息都完整插入
  -- 现在找到最后一条 assistant+trool_calls 消息，它之前的所有 tool 消息属于上一轮
  -- 将这些非本轮 tool 消息精简为摘要，减少历史消息体积
  -- 本轮（最后一条 assistant+trool_calls 之后）的 tool 消息保持完整
  local last_assistant_idx = nil
  for i = #ss.messages, 1, -1 do
    local msg = ss.messages[i]
    if msg.role == "assistant" and msg.tool_calls and #msg.tool_calls > 0 then
      last_assistant_idx = i
      break
    end
  end

  if last_assistant_idx then
    -- last_assistant_idx 之前的 tool 消息属于上一轮，精简为摘要
    -- 保留工具名称和关键信息，让 AI 在后续轮次中能看到上下文
    for i = 1, last_assistant_idx - 1 do
      local msg = ss.messages[i]
      if msg.role == "tool" and msg.content and msg.content ~= "" then
        local tool_name = msg.name or "unknown"
        -- 检查是否包含错误信息
        local lower = msg.content:lower()
        if lower:find("error") or lower:find("失败") or lower:find("错误") or lower:find("fail") then
          msg.content = string.format("[执行失败] 工具: %s, 错误: %s", tool_name, msg.content:sub(1, 300))
        else
          -- 保留工具名称和结果摘要（前 500 字符）
          local summary = msg.content:sub(1, 500)
          -- 如果内容较长，添加截断标记
          if #msg.content > 500 then
            summary = summary .. "\n...(截断，完整结果可通过 get_file_context 工具获取)"
          end
          msg.content = string.format("[执行成功] 工具: %s\n%s", tool_name, summary)
        end
      end
      -- 同时精简 assistant 消息中的 tool_calls.arguments（参数字符串通常很大）
      if msg.role == "assistant" and msg.tool_calls then
        for _, tc in ipairs(msg.tool_calls) do
          local func = tc["function"] or tc.func
          if func and func.arguments and #func.arguments > 500 then
            func.arguments = func.arguments:sub(1, 500) .. "\n...(截断，原大小 " .. #func.arguments .. " 字节)"
          end
        end
      end
    end
  end

  -- ===== 下下轮压缩：对上一轮追踪过的文件的工具结果进行压缩 =====
  -- 如果上一轮追踪器中有文件被访问，本轮中这些文件的工具结果将被压缩为摘要
  -- 并在请求末尾通过虚拟工具 get_file_context 提供实时信息
  local prev_tracker = request_handler.get_prev_file_tracker()
  if prev_tracker and next(prev_tracker) then
    for i = #ss.messages, 1, -1 do
      local msg = ss.messages[i]
      if msg.role == "tool" and msg.content and msg.content ~= "" then
        local tool_name = msg.name or ""
        -- 检查该工具是否访问了上一轮追踪过的文件
        local should_compress = false
        if msg.normalized_args then
          local filepath = msg.normalized_args.filepath or msg.normalized_args.path or msg.normalized_args.cwd or ""
          if filepath ~= "" then
            local abs_path = vim.fn.fnamemodify(filepath, ":p")
            if prev_tracker[abs_path] then
              should_compress = true
            end
          end
        end
        -- 如果工具名匹配已知的文件访问工具，也尝试压缩
        if not should_compress then
          local file_access_tools = {
            read_file = true, write_file = true, insert_edit_into_file = true,
            create_file = true, delete_file = true, edit_node = true, delete_node = true,
            replace_text = true, search_files = true, grep_search = true,
            file_exists = true, list_files = true, ensure_dir = true, create_directory = true,
            get_node_type = true, get_node_at_position = true, get_child_nodes = true,
            get_parent_node = true, get_node_code = true, get_node_range = true,
            is_named_node = true, query_tree = true, parse_file = true,
          }
          if file_access_tools[tool_name] then
            should_compress = true
          end
        end

        if should_compress and not msg.content:find("^%[执行成功%]", 1, true) and not msg.content:find("^%[执行失败%]", 1, true) then
          local lower = msg.content:lower()
          if lower:find("error") or lower:find("失败") or lower:find("错误") or lower:find("fail") then
            msg.content = string.format("[执行失败] 工具: %s, 错误: %s", tool_name, msg.content:sub(1, 300))
          else
            -- 压缩为摘要，保留前 200 字符
            local summary = msg.content:sub(1, 200)
            if #msg.content > 200 then
              summary = summary .. "\n...(截断，完整结果可通过 get_file_context 虚拟工具获取最新文件内容)"
            end
            msg.content = string.format("[执行成功] 工具: %s\n%s", tool_name, summary)
          end
        end
      end
    end
  end

  -- ===== 保存本轮文件追踪快照供下一轮使用 =====
  request_handler.snapshot_file_tracker()

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
        require("NeoAI.utils.logger").debug(
          "[tool_orchestrator] _on_tools_complete: once_display_closed 回调中 session 已为 nil, session=%s",
          tostring(session_id)
        )
        return
      end
      if is_shutting_down() then
        return
      end
      if s.stop_requested then
        logger.debug(
          "[tool_orchestrator] _on_tools_complete: once_display_closed 回调中检测到 stop_requested，跳过 _check_round_complete"
        )
        s._tools_complete_in_progress = false
        return
      end
      require("NeoAI.utils.logger").debug(
        "[tool_orchestrator] _on_tools_complete: once_display_closed 回调执行, session=%s, phase=%s, iter=%d, _generation_completed=%s, _tools_all_completed=%s",
        tostring(session_id),
        tostring(s.phase),
        s.current_iteration or 0,
        tostring(s._generation_completed),
        tostring(s._tools_all_completed)
      )
      -- 工具全部完成，检查是否两个事件都已到达，决定是否开启下一轮
      M._check_round_complete(session_id, is_sub_agent)
      -- 检查是否已进入下一轮：如果 _generation_completed 已被重置为 false，
      -- 说明 _check_round_complete 成功推进了循环。此时不重置 _tools_complete_in_progress，
      -- 防止后续工具回调（异步竞态）绕过保护再次触发 _on_tools_complete。
      -- 后续轮次的 _on_tools_complete 会在新轮次工具完成后，由 _check_round_complete
      -- 重置的 _tools_all_completed=false 配合 _tools_complete_in_progress=false 正常进入。
      if s._generation_completed == false and s._tools_all_completed == false then
        -- 已进入下一轮，保持 _tools_complete_in_progress=true 阻止旧工具回调
        logger.debug(
          "[tool_orchestrator] _on_tools_complete: 已进入下一轮，保持 _tools_complete_in_progress 阻止旧工具回调, session=%s",
          tostring(session_id)
        )
      else
        s._tools_complete_in_progress = false
      end
    end)
  elseif ss.phase == "round_complete" then
    ss._tools_complete_in_progress = false
    -- 本轮已完成，由 _check_round_complete 决定是否开启下一轮
    M._check_round_complete(session_id, is_sub_agent)
  else
    -- phase 异常时（如 idle/waiting_model），仍应调用 _check_round_complete
    -- 避免 _tools_all_completed 已设为 true 但双事件检查永不触发导致循环卡死
    ss._tools_complete_in_progress = false
    logger.warn(
      "[tool_orchestrator] _on_tools_complete: phase 异常 '%s'，仍触发 _check_round_complete, session=%s",
      tostring(ss.phase),
      tostring(session_id)
    )
    M._check_round_complete(session_id, is_sub_agent)
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
    require("NeoAI.utils.logger").debug(
      "[tool_orchestrator] _check_round_complete: 双事件未就绪, session=%s, _generation_completed=%s, _tools_all_completed=%s, phase=%s, iter=%d",
      tostring(session_id),
      tostring(ss._generation_completed),
      tostring(ss._tools_all_completed),
      tostring(ss.phase),
      ss.current_iteration or 0
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
  -- 注意：reset_file_tracker() 已移至 start_async_loop 中调用
  -- 确保在 _request_generation → build_request 生成节点报告时文件追踪器仍然有效
  -- 新轮次开始时（start_async_loop）才重置，而非在进入下一轮前重置
  require("NeoAI.utils.logger").debug(
    "[DEBUG_DUP] _proceed_to_next_round: session=%s, phase=%s, iter=%d, _proceed_in_progress=%s, stack=%s",
    tostring(session_id),
    tostring(ss.phase),
    ss.current_iteration or 0,
    tostring(ss._proceed_in_progress),
    _traceback_if_debug()
  )

  if ss._proceed_in_progress then
    return
  end
  ss._proceed_in_progress = true

  -- pcall 保护：确保 _proceed_in_progress 始终被重置，防止异常导致永久卡死
  local ok, proceed_err = pcall(function()
    ss.phase = "idle"
    -- 原地清空而非替换表引用：防止 vim.schedule 中延迟执行的旧工具回调
    -- 通过 sessions_table[session_id].active_tool_calls 写入新表，
    -- 导致旧工具回调的 tool_call_id 出现在新轮次中，污染工具计数。
    for k in pairs(ss.active_tool_calls) do
      ss.active_tool_calls[k] = nil
    end
    ss._executed_tool_call_ids = {} -- 重置已执行工具 ID 集合，新的一轮重新计数

    if ss.stop_requested then
      return
    end

    fire_loop_finished(ss, false, "tools_complete")
    ss.current_iteration = ss.current_iteration + 1
    ss.phase = "waiting_model"
  end)

  ss._proceed_in_progress = false

  if not ok then
    logger.warn("[tool_orchestrator] _proceed_to_next_round 内部异常: %s", tostring(proceed_err))
    return
  end

  if ss.stop_requested then
    return
  end

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
    require("NeoAI.utils.logger").warn(
      "[tool_orchestrator] on_generation_complete 跳过: generation_id 不匹配 (session=%s, ss=%s, ss.gen_id=%s, data.gen_id=%s)",
      tostring(session_id),
      tostring(ss ~= nil),
      tostring(ss and ss.generation_id),
      tostring(data.generation_id)
    )
    return
  end

  -- 防止重复触发：如果 _generation_completed 已经为 true，说明此回调已被处理过
  -- 这可能在流式结束和非流式响应同时到达时发生
  if ss._generation_completed then
    require("NeoAI.utils.logger").warn(
      "[tool_orchestrator] on_generation_complete 被防重入拦截 (session=%s)，但仍尝试补充 usage 数据",
      tostring(session_id)
    )
    -- 防重入时仍尝试累积 usage（某些 API 在 finish_reason 之后单独发送 usage chunk）
    if data.usage and next(data.usage) then
      local acc = ss.accumulated_usage or {}
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
      ss.accumulated_usage = acc
    end
    return
  end
  ss._generation_completed = true

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
        -- 先尝试直接解析
        local ok, parsed = pcall(vim.json.decode, args)
        local used_fix = false
        if not ok or type(parsed) ~= "table" then
          -- 修复：AI 有时会在包含双引号的字符串值周围使用单引号（如 '"""text"""'），这不是合法 JSON
          -- 将单引号包裹的字符串值中的双引号转义，然后把单引号换为双引号
          local fixed_args = args:gsub("'([^']-)'", function(inner)
            local escaped = inner:gsub('"', '\\"')
            return '"' .. escaped .. '"'
          end)
          ok, parsed = pcall(vim.json.decode, fixed_args)
          used_fix = true
        end
        if ok and type(parsed) == "table" then
          func.arguments = parsed
          args = parsed
          if used_fix then
            logger.warn(
              "[tool_orchestrator] on_generation_complete: 工具 '%s' 的 arguments 为字符串（已修复单引号），已解析为 table",
              func.name
            )
          end
        else
          -- 容错：create_sub_agent 的 arguments 不是 JSON 时，将纯文本作为 task 参数
          if func.name == "create_sub_agent" and type(args) == "string" and args ~= "" then
            local text = args
            -- 清理前导标点符号和代码块标记
            text = text:gsub("^[%s。，,%-.]*", "")
            text = text:gsub("```[a-z]*\n?", "")
            text = text:gsub("\n```%s*$", "")
            func.arguments = { task = text }
            args = func.arguments
            logger.warn(
              "[tool_orchestrator] 工具 '%s' 的 arguments 为无效 JSON，已将纯文本作为 task 参数: %s",
              func.name,
              tostring(text):sub(1, 100)
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

    -- 如果是空响应重试（模型超时），先检查 body 大小
    -- _trim_messages → _truncate_oversized_tool_results 会处理截断
    -- 如果截断后仍然超限会直接 error 报错并打印完整请求体
    if reason and reason:find("空响应") then
      _trim_messages(ss.messages)
    end

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
      -- 回滚失败的工具交互：找到最后一条 assistant+tool_calls 消息，
      -- 删除它及其后续所有消息（tool 结果等），避免 AI 在重试时看到孤儿 tool 结果
      if #ss.messages > 0 then
        -- 从后向前查找最后一条 assistant+tool_calls 消息
        local remove_from = nil
        for i = #ss.messages, 1, -1 do
          local msg = ss.messages[i]
          if msg.role == "assistant" and msg.tool_calls then
            remove_from = i
            break
          end
        end
        if remove_from then
          -- 删除从该位置到末尾的所有消息
          for _ = #ss.messages, remove_from, -1 do
            table.remove(ss.messages)
          end
        end
      end
      -- 重置双事件标志，确保重试生成完成后能正常触发 _check_round_complete
      ss._generation_completed = false
      ss._tools_all_completed = false
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
    end
  end

  if #tool_calls == 0 then
    -- 检测：AI 本意是调用工具但所有工具调用因 arguments 解析失败被跳过
    -- 此时应触发重试，让 AI 重新生成正确的工具调用
    local original_tool_count = #(data.tool_calls or {})
    if original_tool_count > 0 then
      logger.warn(
        "[tool_orchestrator] AI 返回了 %d 个工具调用但全部因参数无效被跳过，触发重试",
        original_tool_count
      )
      local retry_count = ss._tool_retry_count or 0
      if request_handler.can_retry(retry_count) then
        local new_retry_count = retry_count + 1
        ss._tool_retry_count = new_retry_count
        local delay = request_handler.get_retry_delay(new_retry_count)
        logger.warn(
          "[tool_orchestrator] 无效工具调用重试 (%d/%d): 延迟 %dms 后重试",
          new_retry_count,
          request_handler.get_max_retries(),
          delay
        )
        vim.api.nvim_exec_autocmds("User", {
          pattern = event_constants.GENERATION_RETRYING,
          data = {
            generation_id = ss.generation_id,
            retry_count = new_retry_count,
            max_retries = request_handler.get_max_retries(),
            reason = "所有工具调用因参数无效被跳过",
            session_id = session_id,
            window_id = ss.window_id,
            layer = "tool_orchestrator",
          },
        })
        -- 回滚失败的工具交互：找到最后一条 assistant+tool_calls 消息，
        -- 删除它及其后续所有消息（tool 结果等），避免 AI 在重试时看到孤儿 tool 结果
        if #ss.messages > 0 then
          -- 从后向前查找最后一条 assistant+tool_calls 消息
          local remove_from = nil
          for i = #ss.messages, 1, -1 do
            local msg = ss.messages[i]
            if msg.role == "assistant" and msg.tool_calls then
              remove_from = i
              break
            end
          end
          if remove_from then
            -- 删除从该位置到末尾的所有消息
            for _ = #ss.messages, remove_from, -1 do
              table.remove(ss.messages)
            end
          end
        end
        -- 重置双事件标志，确保重试生成完成后能正常触发 _check_round_complete
        ss._generation_completed = false
        ss._tools_all_completed = false
        vim.defer_fn(function()
          M._request_generation(session_id, is_sub_agent)
        end, delay)
        return
      else
        logger.warn(
          "[tool_orchestrator] 无效工具调用重试已达上限 (%d/%d)",
          retry_count,
          request_handler.get_max_retries()
        )
      end
    end

  -- AI 返回纯文本回复，直接结束循环
  -- 重置 _tools_all_completed 标志，防止 _check_round_complete 错误地进入下一轮
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

    -- ===== 修复：将 AI 回复持久化到 history_manager =====
    -- 确保下一轮对话能获取到上一轮的 AI 消息
    if not is_sub_agent then
      local hm_ok, hm = pcall(require, "NeoAI.core.history.manager")
      if hm_ok and hm.is_initialized() then
        local assistant_entry = { content = content }
        if data.reasoning and data.reasoning ~= "" then
          assistant_entry.reasoning_content = data.reasoning
        end
        hm.add_assistant_entry(session_id, assistant_entry)
        -- 触发立即保存，确保数据持久化
        hm._mark_dirty()
      end
    end

      local saved_usage = ss.accumulated_usage or {}
      local saved_reasoning = ss.last_reasoning or ""
      local saved_win_id = ss.window_id
      local saved_gen_id = ss.generation_id
      local saved_content = content
      local on_complete = ss.on_complete
      ss.on_complete = nil
      -- idle 状态由 TOOL_LOOP_FINISHED 监听器统一设置
      ss.active_tool_calls = {}
      ss.current_iteration = 0
      ss.generation_id = nil
      -- 先触发 GENERATION_COMPLETED 事件（此时 chat_window 的 streaming.message_index 仍然有效），
      -- 再触发 TOOL_LOOP_FINISHED（reset_streaming_state 会清除 message_index）。
      -- 否则 GENERATION_COMPLETED 事件处理中 mi 为 nil，导致纯文本回复无法渲染到聊天窗口。
      -- 直接触发 GENERATION_COMPLETED 事件（此时 chat_window 的 streaming.message_index 仍然有效），
      -- 再触发 TOOL_LOOP_FINISHED（reset_streaming_state 会清除 message_index）。
      -- 注意：不使用 once_display_closed 延迟触发，因为 TOOL_LOOP_FINISHED 会立即调用 reset_streaming_state，
      -- 延迟后 GENERATION_COMPLETED 中 mi 为 nil，导致纯文本回复无法渲染到聊天窗口。
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event_constants.GENERATION_COMPLETED,
        data = {
          generation_id = saved_gen_id,
          response = saved_content,
          reasoning_text = saved_reasoning,
          usage = saved_usage,
          session_id = session_id,
          window_id = saved_win_id,
          duration = 0,
        },
      })
      if on_complete then
        on_complete(true, saved_content, saved_usage)
      end
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
      -- 先触发 GENERATION_COMPLETED 再触发 TOOL_LOOP_FINISHED
      -- 确保 chat_window 的 streaming.message_index 在 GENERATION_COMPLETED 处理时仍有效
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
      fire_loop_finished(ss, true, "ai_complete")
      return
    end
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

  -- 性能优化：裁剪消息上下文窗口，防止无限增长
  _trim_messages(ss.messages)

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

--- 内联编辑距离计算
--- @param s1 string
--- @param s2 string
--- @return number
local function _inline_levenshtein(s1, s2)
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

--- 内联模糊匹配工具名称
--- 替代已废弃的 M._fuzzy_match_tool
--- @param input string 模型输入的工具名称
--- @param all_names string[] 所有可用工具名称列表
--- @return string|nil 最匹配的工具名称，或 nil
---@diagnostic disable-next-line: unused-local
_inline_fuzzy_match = function(input, all_names)
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
    local len_diff = math.abs(#name_lower - input_len)
    if len_diff <= math.max(#name_lower, input_len) * 0.5 then
      local dist = _inline_levenshtein(input_lower, name_lower)
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

function M._add_tool_result_to_messages(session_id, tool_call_id, tool_name, result, is_sub_agent, normalized_args)
  local sessions_table = is_sub_agent and state.sub_agent_sessions or state.sessions
  local ss = sessions_table[session_id]
  if not ss then
    return
  end

  local safe_id = tool_call_id or ("call_" .. os.time() .. "_" .. math.random(10000, 99999))

  -- 先完整插入工具结果
  -- _on_tools_complete 中会按对话轮次分割，将非最后一轮的 tool 消息精简为摘要
  local tool_msg = request_handler.build_tool_result_message(safe_id, result, tool_name, true)
  tool_msg.timestamp = os.time()
  tool_msg.window_id = ss.window_id

  if normalized_args and type(normalized_args) == "table" and next(normalized_args) then
    tool_msg.normalized_args = vim.deepcopy(normalized_args)
  end
  table.insert(ss.messages, tool_msg)

  -- ===== 追踪文件变更（Tree-sitter 语法树节点级追踪） =====
  -- 记录被访问文件的语法树节点，在请求末尾按节点展示原始代码 vs 当前代码
  if tool_name then
    local is_read_tool = tool_executor._is_readonly_tool(tool_name)
    local is_write_tool = tool_executor._is_write_tool(tool_name)

    if is_read_tool and normalized_args and normalized_args.filepath then
      request_handler.track_file_read(normalized_args.filepath, normalized_args, tool_name, result)
    elseif is_write_tool and normalized_args then
      local filepath = normalized_args.filepath or (normalized_args.path or "")
      if filepath and filepath ~= "" then
        request_handler.track_file_write(filepath, normalized_args, tool_name)
      end
    end
  end

  -- 工具结果实时持久化到 history_manager（由 tool_executor 统一保存）
  -- tool_executor 的 on_success_wrapper/on_error_wrapper 中已调用 _save_tool_result_to_history
  -- 此处不再重复保存，避免竞态和重复
  -- 注意：_add_tool_result_to_messages 只负责将工具结果加入 ss.messages（AI 请求上下文）
  -- 持久化由 tool_executor 集中处理

  -- 性能优化：裁剪消息上下文窗口，防止无限增长
  _trim_messages(ss.messages)
end

-- ========== 结束循环 ==========

---@diagnostic disable-next-line: unused-local
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
    local saved_result = result or ""

    -- idle 状态由 TOOL_LOOP_FINISHED 监听器统一设置
    ss.active_tool_calls = {}
    ss._executed_tool_call_ids = {}
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
  local saved_result = result or ""

  ss.on_complete = nil
  -- idle 状态由 TOOL_LOOP_FINISHED 监听器统一设置
  ss.active_tool_calls = {}
  ss._executed_tool_call_ids = {}
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
      ss._executed_tool_call_ids = {}
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
  request_handler = require("NeoAI.core.ai.request_handler")
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

-- ========== 模型切换事件监听 ==========
-- 当用户通过 model_selector 切换模型时，同步更新所有活跃会话的 model_index 和 ai_preset
-- 确保下一轮工具循环使用新模型
vim.api.nvim_create_autocmd("User", {
  pattern = event_constants.MODEL_SWITCHED,
  callback = function(args)
    local data = args.data or {}
    local new_index = data.new_index
    if not new_index then
      return
    end

    -- 延时加载 engine 模块，避免循环依赖（engine 在初始化时 require tool_cycle）
    local ok, engine = pcall(require, "NeoAI.core.ai.engine")
    if not ok or not engine or not engine.get_model_config then
      -- 如果 engine 还未加载完成，至少更新 model_index
      for _, ss in pairs(state.sessions) do
        ss.model_index = new_index
      end
      for _, ss in pairs(state.sub_agent_sessions) do
        ss.model_index = new_index
      end
      return
    end

    local new_preset = engine.get_model_config(new_index)
    for _, ss in pairs(state.sessions) do
      ss.model_index = new_index
      ss.ai_preset = new_preset
    end
    for _, ss in pairs(state.sub_agent_sessions) do
      ss.model_index = new_index
      ss.ai_preset = new_preset
    end
  end,
})

return M

