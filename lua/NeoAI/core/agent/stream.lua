--- 流式响应处理
--- @module NeoAI.core.agent.stream
--- 处理流式数据块：把增量 tool_calls（OpenAI 分片格式）累积为完整 tool_call。
--- 同时负责把流式增量同步到 Agent 消息。

local M = {}

local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

-- ========== 私有常量 ==========

-- 工具参数快照推送节流（毫秒）：`_finalize_tool_calls` 会拼接全部已累积参数，逐分片调用
-- 对超大参数（如 write_file 写入大文件）是 O(n²) 主线程开销。改为最多每此间隔推一次快照，
-- 首个分片立即推送（UI 据此打开"接收参数"悬浮窗），完整结果由 finish() 统一给出。
local TOOL_ARG_EMIT_INTERVAL_MS = 50

-- ========== 私有函数 ==========

--- 累积工具调用增量
--- 参数/名称分片按数组累积、仅在 finalize 时 concat：逐分片 `s = s .. frag` 对超大参数
--- （write_file 写入大文件）是 O(n²) 主线程拷贝，会让单核长时间跑满；分片累积为 O(n)。
--- 输入 chunks 数组，每个可能是 { index, id?, type?, function = { name?, arguments? } }
--- @param acc table|nil 已累积的 { [index] = { id, name_parts, arg_parts } }
--- @param tool_calls table 增量块
--- @return table 累积表
local function _accumulate_tool_calls(acc, tool_calls)
  acc = acc or {}
  for _, tc in ipairs(tool_calls or {}) do
    local idx = tc.index or 0
    local entry = acc[idx] or { id = nil, name = nil, name_parts = {}, arg_parts = {} }
    if tc.id then entry.id = tc.id end
    if tc.type then entry.type = tc.type end
    local fn = tc["function"]
    if fn then
      if fn.name then
        entry.name_parts[#entry.name_parts + 1] = fn.name
        entry.name = table.concat(entry.name_parts)
      end
      if fn.arguments then entry.arg_parts[#entry.arg_parts + 1] = fn.arguments end
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
      local args = entry.arguments
      if args == nil and entry.arg_parts then args = table.concat(entry.arg_parts) end
      out[#out + 1] = {
        id = entry.id or ("call_" .. tostring(idx)),
        type = "function",
        ["function"] = {
          name = entry.name,
          arguments = (args ~= nil and args ~= "") and args or "{}",
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
  local last_arg_emit_ms = 0

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
      -- 实时推送当前累积的工具调用快照（节流）：UI 用它像思考过程悬浮窗一样打开"接收参数"悬浮窗。
      local now_ms = vim.uv.hrtime() / 1e6
      if now_ms - last_arg_emit_ms >= TOOL_ARG_EMIT_INTERVAL_MS then
        last_arg_emit_ms = now_ms
        event_bus.emit(events.TOOL_ARG_CHUNK, {
          agent_id = agent.id,
          tool_calls = _finalize_tool_calls(tool_acc),
        })
      end
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
        event_bus.emit(events.TOOL_ARG_COMPLETED, { agent_id = agent.id })
        return final
      end
    end
    return nil
  end

  --- 重置
  function processor.reset()
    tool_acc = nil
    reasoning_active = false
    last_arg_emit_ms = 0
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
