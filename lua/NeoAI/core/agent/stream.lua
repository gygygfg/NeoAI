--- 流式响应处理
--- @module NeoAI.core.agent.stream
--- 处理流式数据块：把增量 tool_calls（OpenAI 分片格式）累积为完整 tool_call。
--- 同时负责把流式增量同步到 Agent 消息。

local M = {}

local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

-- ========== 私有函数 ==========

--- 累积工具调用增量
--- 输入 chunks 数组，每个可能是 { index, id?, type?, function = { name?, arguments? } }
--- @param acc table|nil 已累积的 { [index] = { id, name, arguments } }
--- @param tool_calls table 增量块
--- @return table 累积表
local function _accumulate_tool_calls(acc, tool_calls)
  acc = acc or {}
  for _, tc in ipairs(tool_calls or {}) do
    local idx = tc.index or 0
    local entry = acc[idx] or { id = nil, name = nil, arguments = "" }
    if tc.id then entry.id = tc.id end
    if tc.type then entry.type = tc.type end
    local fn = tc["function"]
    if fn then
      if fn.name then entry.name = entry.name and (entry.name .. fn.name) or fn.name end
      if fn.arguments then entry.arguments = entry.arguments .. fn.arguments end
    end
    acc[idx] = entry
  end
  return acc
end

--- 把累积表转换为完成的 tool_calls 数组
--- @param acc table
--- @return table 数组 { id, type = "function", function = { name, arguments } }
local function _finalize_tool_calls(acc)
  local out = {}
  local indices = {}
  for idx in pairs(acc) do indices[#indices + 1] = idx end
  table.sort(indices)
  for _, idx in ipairs(indices) do
    local entry = acc[idx]
    if entry and entry.name and entry.name ~= "" then
      out[#out + 1] = {
        id = entry.id or ("call_" .. tostring(idx)),
        type = "function",
        ["function"] = {
          name = entry.name,
          arguments = entry.arguments or "{}",
        },
      }
    end
  end
  return out
end

-- ========== 公开 API ==========

--- 创建流处理器
--- @param agent table Agent
--- @return table { push(raw, parsed), finish(), reset() }
function M.create(agent)
  local tool_acc = nil
  local reasoning_active = false

  local processor = {}

  --- 处理一个解析后的数据块
  --- @param parsed table { content?, reasoning?, tool_calls?, finish_reason? }
  --- @return table|nil 更新摘要
  function processor.process(parsed)
    if not parsed then return nil end
    local updated = {}
    if parsed.reasoning then
      if not reasoning_active then
        reasoning_active = true
        event_bus.emit(events.REASONING_STARTED, { agent_id = agent.id })
      end
      agent:append_reasoning(parsed.reasoning)
      updated.reasoning = true
    end
    if parsed.content then
      if reasoning_active then
        reasoning_active = false
        event_bus.emit(events.REASONING_COMPLETED, { agent_id = agent.id })
      end
      agent:append_content(parsed.content)
      updated.content = true
    end
    if parsed.tool_calls then
      tool_acc = _accumulate_tool_calls(tool_acc, parsed.tool_calls)
      updated.tool_calls = true
    end
    if parsed.finish_reason then
      updated.finish_reason = parsed.finish_reason
    end
    return updated
  end

  --- 结束流：把累积的 tool_calls 写入 agent
  --- @return table|nil 完成的 tool_calls
  function processor.finish()
    if reasoning_active then
      reasoning_active = false
      event_bus.emit(events.REASONING_COMPLETED, { agent_id = agent.id })
    end
    if tool_acc then
      local final = _finalize_tool_calls(tool_acc)
      if #final > 0 then
        agent:set_tool_calls(final)
        return final
      end
    end
    return nil
  end

  --- 重置
  function processor.reset()
    tool_acc = nil
    reasoning_active = false
  end

  return processor
end

--- 流式工具调用累积（供测试直接使用）
--- @param chunks table 数组，每项可为 { tool_calls = {...} } 或直接工具增量数组
--- @return table 完成的 tool_calls
function M.accumulate_tool_calls(chunks)
  local acc = nil
  for _, chunk in ipairs(chunks) do
    local tcs = chunk.tool_calls or chunk
    acc = _accumulate_tool_calls(acc, tcs)
  end
  return _finalize_tool_calls(acc)
end

return M
