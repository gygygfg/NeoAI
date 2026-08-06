--- 工具调用循环
--- @module NeoAI.core.agent.tool_loop
--- Agent 的工具调用循环：执行工具 → 请求 AI 继续 → 直到无工具调用。
--- 每轮创建持久流处理器累积 tool_calls 增量。
--- 工具执行经 tool_service（审批 + 调度 + 执行）。

local async = require("NeoAI.utils.async")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local stream_mod = require("NeoAI.core.agent.stream")

local M = {}

-- ========== 私有常量 ==========

local MAX_ROUNDS = 20

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
--- @param agent table
--- @param tool_call table
--- @param tool_service table
--- @param opts table { is_sub_agent? }
--- @return Deferred resolve(结果字符串)
local function _execute_single(agent, tool_call, tool_service, opts)
  local fn = tool_call["function"]
  local name = fn and fn.name or "unknown"
  local args = _parse_arguments(fn and fn.arguments or "{}")

  event_bus.emit(events.TOOL_EXECUTION_STARTED, { agent_id = agent.id, name = name, args = args })

  return tool_service.execute(agent, name, args, tool_call.id, {
    is_sub_agent = opts.is_sub_agent,
    signal = agent.signal,
  }):then_(function(result)
    local result_str = result
    if type(result) ~= "string" then
      local json = require("NeoAI.utils.json")
      result_str = json.encode(result)
    end
    agent:add_tool_result(tool_call.id, name, result_str)
    event_bus.emit(events.TOOL_EXECUTION_COMPLETED, { agent_id = agent.id, name = name, result = result_str })
    return result_str
  end, function(err)
    local json = require("NeoAI.utils.json")
    local err_msg = type(err) == "table" and (err.message or json.encode(err)) or tostring(err)
    local result_str = json.encode({ error = err_msg, tool = name })
    agent:add_tool_result(tool_call.id, name, result_str)
    event_bus.emit(events.TOOL_EXECUTION_ERROR, { agent_id = agent.id, name = name, error = err_msg })
    return result_str
  end)
end

--- 从 Agent 提取工具定义（供请求使用）
--- @param agent table
--- @return table 数组
function M._tool_definitions(agent)
  local out = {}
  for name, tool in pairs(agent.tools or {}) do
    local tf = { name = name, description = tool.description or ("执行 " .. name) }
    local params = tool.parameters
    if params and params.properties then
      local cp = { type = params.type or "object", properties = params.properties }
      if params.required and #params.required > 0 then
        cp.required = params.required
      end
      tf.parameters = cp
    end
    out[#out + 1] = { type = "function", ["function"] = tf }
  end
  return out
end

--- 发送一次请求（带持久流处理器）
--- @param agent table
--- @param request table core.agent.request
--- @param context_builder table
--- @return Deferred resolve({ next_calls = table|nil, response = table })
local function _send_round(agent, request, context_builder)
  local messages = context_builder.build_from_agent(agent)
  local proc = stream_mod.create(agent)
  return request.send_stream(messages, {
    agent_config = agent.config,
    model = agent.model,
    tools = M._tool_definitions(agent),
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
  local request = require("NeoAI.core.agent.request")
  local context_builder = require("NeoAI.core.session.context_builder")

  local function _loop()
    if agent.signal:aborted() then
      return async.reject({ kind = "aborted", message = "工具循环被取消" })
    end
    rounds = rounds + 1
    if rounds > MAX_ROUNDS then
      return async.reject({ kind = "loop", message = "工具循环超过最大轮数 " .. tostring(MAX_ROUNDS) })
    end
    if not current_calls or #current_calls == 0 then
      return async.resolve({ response = agent.messages[#agent.messages], rounds = rounds })
    end

    agent:set_state("tool_running")
    event_bus.emit(events.TOOL_LOOP_STARTED, { agent_id = agent.id, tool_calls = current_calls })

    local tasks = {}
    for _, tc in ipairs(current_calls) do
      tasks[#tasks + 1] = _execute_single(agent, tc, tool_service, opts)
    end

    return async.all(tasks):then_(function()
      agent:set_state("generating")
      event_bus.emit(events.TOOL_LOOP_FINISHED, { agent_id = agent.id, rounds = rounds })
      return _send_round(agent, request, context_builder):then_(function(result)
        current_calls = result.next_calls
        return _loop()
      end)
    end)
  end

  return _loop()
end

return M
