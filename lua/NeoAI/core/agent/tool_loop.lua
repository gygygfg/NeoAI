--- 工具调用循环
--- @module NeoAI.core.agent.tool_loop
--- Agent 的工具调用循环：执行工具 → 请求 AI 继续 → 直到无工具调用。
--- 每轮创建持久流处理器累积 tool_calls 增量。
--- 工具执行经 tool_service（审批 + 调度 + 执行）。
--- 工具调用并行执行；审批在 tool_service 内串行化（单槽位弹窗互不覆盖）。
--- 每轮发送前在轮边界做上下文压力检查（allow_busy 压缩）：上一轮工具结果已回写、
--- 下一轮请求尚未发出，此时折叠历史安全；长循环因此可逐轮收敛，不耗尽上下文。

local async = require("NeoAI.utils.async")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local stream_mod = require("NeoAI.core.agent.stream")
local config_store = require("NeoAI.kernel.config_store")
local services = require("NeoAI.kernel.services")

local M = {}

-- ========== 私有常量 ==========

local MAX_ROUNDS = 1000

-- 轮末用户消息注入器：由 chat_service 注册（避免 core→service 反向依赖）。
-- 工具循环每轮结束（工具结果记录完、下次模型调用之前）调用它，把用户在
-- agent 忙碌期间发送、被 pending_queue 暂存的消息插入对话，让下一轮模型看到
-- 这条用户消息，而不是等整个工具循环彻底结束后才插入。
local inject_user = nil

-- 轮前刷新钩子：由 chat_service/mcp 注册（避免 core→service 反向依赖）。
-- 工具循环每轮发送请求（_send_round）之前调用，返回 Deferred。用于在下一轮模型
-- 请求前刷新「因 schema 变化而 stale」的 MCP 工具定义并重绑定 agent.tools，
-- 使下一 Turn 模型看到最新工具签名（失败驱动的时序保证）。
local pre_round_refresh = nil

-- 达到轮数上限时写入 agent 消息队列的停止说明（chat 界面经 MESSAGE_ADDED 直接可见）
local LOOP_LIMIT_MESSAGE = "⚠️ 工具循环达到最大轮数限制（" .. tostring(MAX_ROUNDS) .. "），已停止继续执行。"

-- 工具执行完毕后模型未返回内容时的收尾说明：避免循环静默结束、聊天看起来"卡住"
local EMPTY_RESPONSE_MESSAGE = "⚠️ 工具已执行完毕，但模型未返回后续内容，本轮生成到此结束。"

-- 工具被取消/中止时写入的显式结果：避免留下孤立 tool_calls，使后续请求被合成
-- 「Tool result unavailable」而让模型误以为调用结果未知。
local CANCELLED_RESULT_MESSAGE =
  "Tool call cancelled: the agent was stopped before this call completed. "
  .. "No side effects should be assumed; re-run the tool if its result is still needed."

--- 供 runtime 在无工具调用的空响应场景复用同一文案
M.EMPTY_RESPONSE_MESSAGE = EMPTY_RESPONSE_MESSAGE

-- 截断续写：模型输出被输出上限截断（finish_reason=length/max_tokens/MAX_TOKENS）且本轮无
-- 工具调用时，自动附加一条"继续"提示重发，直到获得正文/工具调用或达到次数上限，避免循环
-- 静默退出。提示经 extra_user 只进请求 wire、不落库，续写内容追加进同一条 assistant 消息。
local DEFAULT_MAX_CONTINUES = 3
local CONTINUE_NUDGE = "请从中断处继续输出，不要重复已输出的内容。"
local TRUNCATED_MESSAGE = "⚠️ 模型输出达到长度上限被截断，已尝试自动续写仍未完成，本轮生成到此结束。"
M.TRUNCATED_MESSAGE = TRUNCATED_MESSAGE

-- 各协议/厂商的截断 finish_reason（归一化小写）：OpenAI/DeepSeek "length"、Anthropic
-- "max_tokens"、Gemini "MAX_TOKENS"。
local TRUNCATED_REASONS = {
  length = true,
  max_tokens = true,
  max_output_tokens = true,
  maxtokens = true,
}

--- 是否为输出被截断的 finish_reason
--- @param finish_reason string|nil
--- @return boolean
local function _is_truncated(finish_reason)
  if not finish_reason then return false end
  return TRUNCATED_REASONS[tostring(finish_reason):lower()] == true
end

M.is_truncated = _is_truncated

--- 是否还能继续自动续写（受 ai.truncation.enabled / max_continues 约束）
--- @param agent table
--- @return boolean
local function _can_continue(agent)
  local cfg = config_store.get("ai.truncation") or {}
  if cfg.enabled == false then return false end
  local max = tonumber(cfg.max_continues) or DEFAULT_MAX_CONTINUES
  return (agent._truncation_continues or 0) < max
end

--- 记一次续写并返回续写提示文本
--- @param agent table
--- @return string
local function _begin_continue(agent)
  agent._truncation_continues = (agent._truncation_continues or 0) + 1
  local cfg = config_store.get("ai.truncation") or {}
  return cfg.nudge or CONTINUE_NUDGE
end

-- ========== 私有函数 ==========

--- 解析 tool_call 的 arguments JSON
--- @param arguments string
--- @return table
local function _parse_arguments(arguments)
  local json = require("NeoAI.utils.json")
  local decoded, _ = json.decode_or_nil(arguments or "{}")
  if decoded == nil then
    local repaired = (arguments or ""):gsub("%s+", " ")
    if repaired:sub(1, 1) ~= "{" then repaired = "{" .. repaired end
    if repaired:sub(-1) ~= "}" then repaired = repaired .. "}" end
    decoded, _ = json.decode_or_nil(repaired)
  end
  if decoded == nil then return {} end
  return decoded
end

--- 单个工具调用执行
--- 只负责执行并返回结果，不直接写入 agent 消息队列：并行执行时结果按完成顺序
--- 返回，写入由调用方统一按工具调用原始顺序进行（乱序 tool 消息可能被严格兼容
--- 的 API 拒绝，也会破坏前缀缓存确定性）。
--- @param agent table
--- @param tool_call table
--- @param tool_service table
--- @param opts table { is_sub_agent? }
--- @return Deferred resolve({ tool_call_id, name, result_str })
local function _execute_single(agent, tool_call, tool_service, opts)
  local fn = tool_call["function"]
  local name = fn and fn.name or "unknown"
  local args = _parse_arguments(fn and fn.arguments or "{}")
  local logger = require("NeoAI.kernel.logger")
  -- 可暂停计时器：从工具真正开始执行（审批通过 / 直接执行）才计时，
  -- 等待用户审批或 ask_user 回答期间暂停，耗时与超时均不含等待时间。
  local timer = require("NeoAI.utils.timer").create()
  local exec_opts = vim.tbl_extend("force", {}, opts or {}, { timer = timer })
  exec_opts.ui_notice = nil -- 由 tool_service 在执行后回填（仅 UI 展示，不进入模型上下文）
  logger.warn("[tool_loop] 执行工具 %s round=%s", name, tostring(agent._round_seq or ""))

  -- 以原对象注册到 fold：事件经 nvim_exec_autocmds 深拷贝会丢失元表/方法，计时器无法随
  -- 事件传播。tool_loop 直接以原对象（含元表）注册，供 UI 实时读取剔除等待的活跃耗时。
  require("NeoAI.ui.components.fold").set_live_timer(tool_call.id, timer)

  event_bus.emit(events.TOOL_EXECUTION_STARTED, {
    agent_id = agent.id, name = name, args = args, tool_call_id = tool_call.id,
  })

  return tool_service.execute(agent, name, args, tool_call.id, exec_opts):then_(function(result)
    local duration_ms = timer:elapsed()
    logger.warn("[tool_loop] 工具完成 %s 耗时 %dms", name, math.floor(duration_ms))
    local result_str = result
    if type(result) ~= "string" then
      local json = require("NeoAI.utils.json")
      result_str = json.encode(result)
    end
    event_bus.emit(events.TOOL_EXECUTION_COMPLETED, {
      agent_id = agent.id, name = name, result = result_str,
      tool_call_id = tool_call.id, duration_ms = duration_ms,
    })
    return { tool_call_id = tool_call.id, name = name, result_str = result_str, duration_ms = duration_ms,
      notice = exec_opts.ui_notice, secret_paths = exec_opts.observed_secret_paths }
  end, function(err)
    local duration_ms = timer:elapsed()
    local logger = require("NeoAI.kernel.logger")
    logger.warn("[tool_loop] 工具失败 %s 耗时 %dms err=%s", name, math.floor(duration_ms), tostring(err and err.message or err))
    local json = require("NeoAI.utils.json")
    local err_msg = type(err) == "table" and (err.message or json.encode(err)) or tostring(err)
    local result_str = json.encode({ error = err_msg, tool = name })
    event_bus.emit(events.TOOL_EXECUTION_ERROR, {
      agent_id = agent.id, name = name, error = err_msg,
      tool_call_id = tool_call.id, duration_ms = duration_ms,
    })
    return { tool_call_id = tool_call.id, name = name, result_str = result_str, duration_ms = duration_ms,
      notice = exec_opts.ui_notice, secret_paths = exec_opts.observed_secret_paths }
  end)
end

--- 从 Agent 提取工具定义（供请求使用）
--- 工具按名称字典序输出：确定性 → 相同工具集跨请求逐字节相同，前缀缓存友好。
--- 空 properties 不输出该字段：JSON 中空 Lua 表会编码为 []，DeepSeek 拒绝 [] schema。
--- 拼接工具上下文前先做环境探测：无法获取 workspace/git 目录时禁用相关工具
--- （tools.environment.filter_tools），避免向模型暴露必然失败的调用。
--- @param agent table
--- @return table 数组
function M._tool_definitions(agent)
  local environment = require("NeoAI.tools.environment")
  local tools = environment.filter_tools(agent.tools or {})
  -- 计划模式：工具上下文只保留只读/信息查询 + ask_user（不暴露任何修改类工具）
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  tools = plan_mode.apply_tool_filter(agent, tools)
  local names = {}
  for name in pairs(tools) do
    names[#names + 1] = name
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local tool = tools[name]
    local tf = { name = name, description = tool.description or ("执行 " .. name) }
    local params = tool.parameters
    if params then
      local cp = { type = params.type or "object" }
      if params.properties and next(params.properties) then
        cp.properties = params.properties
      end
      if params.required and #params.required > 0 then
        cp.required = params.required
      end
      tf.parameters = cp
    end
    out[#out + 1] = { type = "function", ["function"] = tf }
  end
  return out
end

-- 前向声明：_send_round 需在定义前引用 _do_send_round（Lua 局部作用域限制，
-- 前向引用会绕过局部声明而解析到 global nil）。故先声明后赋函数体。
local _do_send_round

--- 发送一次请求（带持久流处理器 + 溢出恢复）
--- 轮边界压力检查：上一轮工具结果已回写、下一轮请求尚未发出，此时做上下文压缩是
--- 安全的（无并发写入）。长工具循环会在此逐轮累积压缩，避免耗尽上下文后撞溢出。
--- 顺序：轮边界压缩 → 轮前刷新（MCP stale schema）→ 实际发送。
--- @param agent table
--- @param opts table|nil { extra_user? = string } extra_user 仅注入请求 wire（截断续写提示）
--- @return Deferred resolve({ next_calls = table|nil, response = table })
local function _send_round(agent, opts)
  -- 轮前刷新：若 MCP 工具因 schema 变化被标记 stale，先刷新定义并重绑定 agent.tools，
  -- 确保下一轮模型看到的工具签名与服务器一致（失败驱动的时序保证）。
  local function _refresh_then_send()
    local refresh_d = M.pre_round_refresh(agent)
    if refresh_d then
      return refresh_d:then_(function() return _do_send_round(agent, opts) end)
    end
    return _do_send_round(agent, opts)
  end
  -- 轮边界压缩：allow_busy=true 放宽 idle 要求（此刻状态为 generating，且即将发送请求）。
  -- 后台异步执行，不阻塞本轮发送；完成后覆盖层对后续轮次生效。失败/无可折叠内容均为
  -- no-op，不影响循环。
  local compactor = require("NeoAI.core.session.compactor")
  compactor.start_background(agent, { allow_busy = true })
  pcall(function()
    local status = services.use("services.status")
    if status then status.check_pressure(agent) end
  end)
  return _refresh_then_send()
end

--- 实际发送一轮请求
--- @param agent table
--- @param opts table|nil { extra_user? = string }
--- @return Deferred
_do_send_round = function(agent, opts)
  opts = opts or {}
  local recovery = require("NeoAI.core.agent.recovery")
  local proc = stream_mod.create(agent)
  local start_ms = vim.uv.hrtime() / 1e6
  local first_chunk_ms = nil
  agent._round_seq = (agent._round_seq or 0) + 1
  local round_seq = agent._round_seq
  return recovery.send_stream(agent, {
    agent_config = agent.config,
    model = agent.model,
    signal = agent.signal,
    extra_user = opts.extra_user,
  }, function(chunk)
    if chunk and first_chunk_ms == nil then
      first_chunk_ms = vim.uv.hrtime() / 1e6
      local logger = require("NeoAI.kernel.logger")
      logger.warn("[tool_loop] 本轮首 token 延迟 %dms round=%d", math.floor(first_chunk_ms - start_ms), round_seq)
    end
    if chunk then proc.process(chunk) end
  end):then_(function(response)
    -- 内容已由 on_chunk 增量写入 agent，这里仅终结工具调用
    if response.usage then agent:add_usage(response.usage) end
    local next_calls = proc.finish()
    -- 附加本轮原始请求/响应元数据（轨迹显示用；不进入模型上下文）
    local request = require("NeoAI.core.agent.request")
    agent:attach_round(request.build_round_meta(response, {
      ttft_ms = first_chunk_ms and (first_chunk_ms - start_ms) or nil,
      total_ms = vim.uv.hrtime() / 1e6 - start_ms,
    }))
    return { next_calls = next_calls, response = response }
  end)
end

--- 截断续写递归（不含预算重置；预算以「一次截断响应」为单位）
--- @param agent table
--- @param result table { next_calls, response }
--- @return Deferred resolve(result)
local function _drain(agent, result)
  local calls = result and result.next_calls
  if calls and #calls > 0 then return async.resolve(result) end
  if not _is_truncated(result and result.response and result.response.finish_reason) then
    return async.resolve(result)
  end
  if not _can_continue(agent) then
    return async.resolve(result)
  end
  local nudge = _begin_continue(agent)
  local logger = require("NeoAI.kernel.logger")
  logger.warn("[tool_loop] 输出被截断，自动续写第 %d 次", agent._truncation_continues)
  return _send_round(agent, { extra_user = nudge }):then_(function(next_result)
    return _drain(agent, next_result)
  end)
end

--- 处理"无工具调用但输出被截断"：自动附加续写提示重发，直到获得工具调用/正文或达到上限。
--- 续写提示经 extra_user 只进请求 wire、不落库；续写内容追加进同一条 assistant 消息
--- （append_content 作用于最后一条 assistant）。每个截断响应独立预算（进入时重置计数）。
--- @param agent table
--- @param result table { next_calls, response }
--- @return Deferred resolve(result)
function M._drain_truncation(agent, result)
  agent._truncation_continues = 0
  return _drain(agent, result)
end

-- ========== 公开 API ==========

--- 注册轮末用户消息注入器（由 chat_service 调用；nil 清除）
--- @param fn function(agent)|nil
function M.set_inject_user(fn)
  inject_user = fn
end

--- 注册轮前刷新钩子（由 chat_service/mcp 调用；nil 清除）
--- @param fn function(agent) -> Deferred|nil
function M.set_pre_round_refresh(fn)
  pre_round_refresh = fn
end

--- 在轮末触发一次 pending 注入（工具循环每轮结束调用；也可手动复用）
--- @param agent table
function M.inject_pending(agent)
  if inject_user then inject_user(agent) end
end

--- 在轮前触发一次刷新钩子（工具循环每轮发送前调用；返回 Deferred）
--- @param agent table
--- @return Deferred|nil
function M.pre_round_refresh(agent)
  if pre_round_refresh then return pre_round_refresh(agent) end
  return nil
end

--- 为一轮中尚未记录结果的工具调用补写「已取消」结果，保持 assistant.tool_calls 与
--- tool 消息一一对应。否则历史中会留下孤立 tool_calls，下一轮请求被合成
--- 「Tool result unavailable」，模型无法区分「结果未知」与「用户主动取消」。
--- @param agent table
--- @param calls table 工具调用数组
local function _settle_cancelled_calls(agent, calls)
  for _, tc in ipairs(calls or {}) do
    local name = tc["function"] and tc["function"].name or "unknown"
    agent:add_tool_result(tc.id, name, CANCELLED_RESULT_MESSAGE)
  end
end

--- 运行工具循环
--- @param agent table Agent
--- @param tool_calls table 首轮工具调用
--- @param tool_service table services.tool_service
--- @param opts table { is_sub_agent? }
--- @return Deferred resolve({ response = table, rounds = number })
function M.run(agent, tool_calls, tool_service, opts)
  opts = opts or {}
  local current_calls = tool_calls
  local rounds = 0

  local function _loop()
    if agent.signal:aborted() then
      -- 取消发生在上一轮结果落库之后、本轮执行之前：本轮 tool_calls 已有 assistant
      -- 消息但无结果，补写显式取消结果，避免孤立调用污染后续请求。
      _settle_cancelled_calls(agent, current_calls)
      return async.reject({ kind = "aborted", message = "工具循环被取消" })
    end
    rounds = rounds + 1
    if rounds > MAX_ROUNDS then
      -- 达到上限即停止。停止原因直接写入 agent 消息队列（role=assistant），
      -- chat 界面经 MESSAGE_ADDED 事件重绘即可看到输出，而不是只弹一个 notify。
      agent:add_message("assistant", LOOP_LIMIT_MESSAGE)
      event_bus.emit(events.TOOL_LOOP_LIMIT_REACHED, { agent_id = agent.id, rounds = rounds })
      return async.resolve({ response = agent.messages[#agent.messages], rounds = rounds, stopped = true })
    end
    if not current_calls or #current_calls == 0 then
      return async.resolve({ response = agent.messages[#agent.messages], rounds = rounds })
    end

    agent:set_state("tool_running")
    event_bus.emit(events.TOOL_LOOP_STARTED, { agent_id = agent.id, tool_calls = current_calls })

    -- 并行执行工具调用。审批在 tool_service 内串行化（单槽位弹窗一次只展示一个，
    -- 前一个未决策时后续弹窗排队等待），因此并发启动不会让弹窗互相覆盖，
    -- 每个 Deferred 都能正常 settle，工具循环不会挂起。
    -- 结果在所有工具完成后统一按原始调用顺序写回消息队列（_execute_single 不直接
    -- 写入），保证 tool 消息顺序与 assistant 的 tool_calls 一致，API 兼容且前缀缓存确定。
    local promises = {}
    for i, tc in ipairs(current_calls) do
      promises[i] = _execute_single(agent, tc, tool_service, opts)
    end

    return async.all(promises):then_(function(results)
      for i, res in ipairs(results) do
        if res then
          agent:add_tool_result(res.tool_call_id, res.name, res.result_str, {
            duration_ms = res.duration_ms, notice = res.notice, secret_paths = res.secret_paths,
          })
        end
      end

      -- 循环护栏：检测连续重复工具调用并注入提醒（observe-and-enrich，不否决）。
      -- 提醒作为 user 消息插入工具结果与下一轮 assistant 之间，模型可见。
      local guard = require("NeoAI.core.agent.guard")
      local guard_cfg = config_store.get("tools.guard.repeat_tool") or {}
      local reminder = guard.check_round(agent, current_calls, guard_cfg)
      if reminder then
        agent:add_message("user", reminder)
        event_bus.emit(events.TOOL_LOOP_GUARD_REMINDER, { agent_id = agent.id, repeats = agent.guard and agent.guard.repeats })
      end

      -- 轮末注入：用户在 agent 忙碌期间发送、暂存在 pending_queue 的消息，
      -- 于本轮工具结果记录后、下次模型调用之前插入对话，供下一轮模型感知。
      M.inject_pending(agent)

      -- 同步最新的运行时上下文快照（todos/计划模式可能在上一轮工具执行中变化）；
      -- 仅在内容变化时追加，系统提示保持稳定，不影响前缀缓存。
      require("NeoAI.core.session.runtime_context").ensure(agent)

      agent:set_state("generating")
      event_bus.emit(events.TOOL_LOOP_FINISHED, { agent_id = agent.id, rounds = rounds })
      return _send_round(agent):then_(function(result)
        -- 输出被截断且无工具调用时自动续写（提示不落库），直到获得调用/正文或达到上限。
        return M._drain_truncation(agent, result):then_(function(final_result)
          current_calls = final_result.next_calls
          if not current_calls or #current_calls == 0 then
            -- 模型既没返回新内容也没请求更多工具：避免循环静默结束、聊天看起来"卡住"，
            -- 写一条可见的 assistant 说明作为本轮收尾。截断未续写成功时优先提示截断。
            local last = agent.messages[#agent.messages]
            if _is_truncated(final_result.response and final_result.response.finish_reason) then
              agent:add_message("assistant", TRUNCATED_MESSAGE)
            elseif last and last.role == "tool" then
              agent:add_message("assistant", EMPTY_RESPONSE_MESSAGE)
            end
          end
          return _loop()
        end)
      end)
    end, function(err)
      -- 本轮工具并发执行被取消/异常：补写取消结果，避免孤立 tool_calls。
      _settle_cancelled_calls(agent, current_calls)
      return async.reject(err)
    end)
  end

  return _loop()
end

return M
