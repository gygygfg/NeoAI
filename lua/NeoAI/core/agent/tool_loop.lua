--- 工具调用循环
--- @module NeoAI.core.agent.tool_loop
--- Agent 的工具调用循环：执行工具 → 请求 AI 继续 → 直到无工具调用。
--- 每轮创建持久流处理器累积 tool_calls 增量。
--- 工具执行经 tool_service（审批 + 调度 + 执行）。
--- 工具调用并行执行；审批在 tool_service 内串行化（单槽位弹窗互不覆盖）。

local async = require("NeoAI.utils.async")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local stream_mod = require("NeoAI.core.agent.stream")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有常量 ==========

local MAX_ROUNDS = 1000

-- 达到轮数上限时写入 agent 消息队列的停止说明（chat 界面经 MESSAGE_ADDED 直接可见）
local LOOP_LIMIT_MESSAGE = "⚠️ 工具循环达到最大轮数限制（" .. tostring(MAX_ROUNDS) .. "），已停止继续执行。"

-- 工具执行完毕后模型未返回内容时的收尾说明：避免循环静默结束、聊天看起来"卡住"
local EMPTY_RESPONSE_MESSAGE = "⚠️ 工具已执行完毕，但模型未返回后续内容，本轮生成到此结束。"

--- 供 runtime 在无工具调用的空响应场景复用同一文案
M.EMPTY_RESPONSE_MESSAGE = EMPTY_RESPONSE_MESSAGE

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
  local start_ms = vim.uv.hrtime() / 1e6

  event_bus.emit(events.TOOL_EXECUTION_STARTED, {
    agent_id = agent.id, name = name, args = args, tool_call_id = tool_call.id,
  })

  return tool_service.execute(agent, name, args, tool_call.id, {
    is_sub_agent = opts.is_sub_agent,
    signal = agent.signal,
  }):then_(function(result)
    local duration_ms = vim.uv.hrtime() / 1e6 - start_ms
    local result_str = result
    if type(result) ~= "string" then
      local json = require("NeoAI.utils.json")
      result_str = json.encode(result)
    end
    event_bus.emit(events.TOOL_EXECUTION_COMPLETED, {
      agent_id = agent.id, name = name, result = result_str,
      tool_call_id = tool_call.id, duration_ms = duration_ms,
    })
    return { tool_call_id = tool_call.id, name = name, result_str = result_str, duration_ms = duration_ms }
  end, function(err)
    local duration_ms = vim.uv.hrtime() / 1e6 - start_ms
    local json = require("NeoAI.utils.json")
    local err_msg = type(err) == "table" and (err.message or json.encode(err)) or tostring(err)
    local result_str = json.encode({ error = err_msg, tool = name })
    event_bus.emit(events.TOOL_EXECUTION_ERROR, {
      agent_id = agent.id, name = name, error = err_msg,
      tool_call_id = tool_call.id, duration_ms = duration_ms,
    })
    return { tool_call_id = tool_call.id, name = name, result_str = result_str, duration_ms = duration_ms }
  end)
end

--- 从 Agent 提取工具定义（供请求使用）
--- 工具按名称字典序输出：确定性 → 相同工具集跨请求逐字节相同，前缀缓存友好。
--- 空 properties 不输出该字段：JSON 中空 Lua 表会编码为 []，DeepSeek 拒绝 [] schema。
--- @param agent table
--- @return table 数组
function M._tool_definitions(agent)
  local names = {}
  for name in pairs(agent.tools or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local tool = agent.tools[name]
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

--- 发送一次请求（带持久流处理器 + 溢出恢复）
--- @param agent table
--- @return Deferred resolve({ next_calls = table|nil, response = table })
local function _send_round(agent)
  local recovery = require("NeoAI.core.agent.recovery")
  local proc = stream_mod.create(agent)
  return recovery.send_stream(agent, {
    agent_config = agent.config,
    model = agent.model,
    signal = agent.signal,
  }, function(chunk)
    if chunk then proc.process(chunk) end
  end):then_(function(response)
    -- 内容已由 on_chunk 增量写入 agent，这里仅终结工具调用
    if response.usage then agent:add_usage(response.usage) end
    local next_calls = proc.finish()
    return { next_calls = next_calls, response = response }
  end)
end

-- ========== 公开 API ==========

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
          agent:add_tool_result(res.tool_call_id, res.name, res.result_str, { duration_ms = res.duration_ms })
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

      agent:set_state("generating")
      event_bus.emit(events.TOOL_LOOP_FINISHED, { agent_id = agent.id, rounds = rounds })
      return _send_round(agent):then_(function(result)
        current_calls = result.next_calls
        if not current_calls or #current_calls == 0 then
          -- 模型既没返回新内容也没请求更多工具：避免循环静默结束、聊天看起来"卡住"，
          -- 写一条可见的 assistant 说明作为本轮收尾。
          local last = agent.messages[#agent.messages]
          if last and last.role == "tool" then
            agent:add_message("assistant", EMPTY_RESPONSE_MESSAGE)
          end
        end
        return _loop()
      end)
    end)
  end

  return _loop()
end

return M
