---@module "NeoAI.core.ai.stream_processor"
--- 流式处理器
--- 职责：创建流式处理器实例、处理流式数据块、管理 reasoning 节流
--- 闭包内私有状态：reasoning_throttle（节流定时器和缓存）

local event_constants = require("NeoAI.core.events")

-- ========== 闭包内私有状态 ==========
local _reasoning_throttle = {
  timer = nil,
  pending_content = "",
  generation_id = nil,
  processor = nil,
  params = nil,
  interval_ms = 80,
}

-- ========== 公共接口 ==========
local M = {}

--- 创建流式处理器实例
function M.create_processor(generation_id, session_id, window_id)
  return {
    generation_id = generation_id,
    content_buffer = "",
    reasoning_buffer = "",
    tool_calls = {},
    usage = {},
    session_id = session_id,
    window_id = window_id,
    start_time = os.time(),
    is_finished = false,
  }
end

--- 处理流式数据块
function M.process_chunk(processor, data)
  if processor.is_finished then return nil end
  local result = { content = nil, reasoning_content = nil, tool_calls = nil, is_final = false }

  if data.choices and #data.choices > 0 then
    local choice = data.choices[1]
    if choice.delta then
      local delta = choice.delta
      if delta.reasoning_content ~= nil and delta.reasoning_content ~= "" then
        processor.reasoning_buffer = processor.reasoning_buffer .. delta.reasoning_content
        result.reasoning_content = delta.reasoning_content
      end
      if delta.content ~= nil and delta.content ~= "" then
        processor.content_buffer = processor.content_buffer .. delta.content
        result.content = delta.content
      end
      if delta.tool_calls then
        for _, tc in ipairs(delta.tool_calls) do
          local idx = tc.index or 0
          if not processor.tool_calls[idx + 1] then
            local safe_id = tc.id or ("call_" .. os.time() .. "_" .. idx)
            processor.tool_calls[idx + 1] = {
              id = safe_id, type = tc.type or "function",
              ["function"] = { name = "", arguments = "" },
            }
          end
          local e = processor.tool_calls[idx + 1]
          if tc.id then e.id = tc.id end
          if tc.type then e.type = tc.type end
          if tc["function"] then
            if tc["function"].name then e["function"].name = e["function"].name .. tc["function"].name end
            if tc["function"].arguments then e["function"].arguments = e["function"].arguments .. tc["function"].arguments end
          end
        end
        if #processor.tool_calls > 0 then result.tool_calls = vim.deepcopy(processor.tool_calls) end
      end
    end
    if choice.message and choice.message.tool_calls then
      for _, tc in ipairs(choice.message.tool_calls) do
        local idx = tc.index or 0
        if not processor.tool_calls[idx + 1] then
          local safe_id = tc.id or ("call_" .. os.time() .. "_" .. idx)
          processor.tool_calls[idx + 1] = {
            id = safe_id, type = tc.type or "function",
            ["function"] = { name = "", arguments = "" },
          }
        end
        local e = processor.tool_calls[idx + 1]
        if tc.id then e.id = tc.id end
        if tc.type then e.type = tc.type end
        if tc["function"] then
          if tc["function"].name then e["function"].name = tc["function"].name end
          if tc["function"].arguments then e["function"].arguments = tc["function"].arguments end
        end
      end
      if #processor.tool_calls > 0 then result.tool_calls = vim.deepcopy(processor.tool_calls) end
    end
    if choice.finish_reason then
      result.is_final = true
      processor.is_finished = true
    end
  end
  if data.usage then
    processor.usage = data.usage
    result.usage = data.usage
  end
  return result
end

--- 过滤无效工具调用（流式截断导致 name 为空或 arguments 为空）
function M.filter_valid_tool_calls(tool_calls)
  local valid = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name and func.name ~= "" then
      local args = func.arguments
      if args ~= nil and args ~= "" then
        table.insert(valid, tc)
      end
    end
  end
  return valid
end

--- 推送 reasoning 内容（带节流）
function M.push_reasoning_content(generation_id, content, processor, params)
  _reasoning_throttle.pending_content = _reasoning_throttle.pending_content .. (content or "")
  _reasoning_throttle.generation_id = generation_id
  _reasoning_throttle.processor = processor
  _reasoning_throttle.params = params

  if not _reasoning_throttle.timer then
    _reasoning_throttle.timer = vim.defer_fn(function()
      local content = _reasoning_throttle.pending_content
      local gid = _reasoning_throttle.generation_id
      local proc = _reasoning_throttle.processor
      _reasoning_throttle.pending_content = ""
      _reasoning_throttle.timer = nil

      if content ~= "" then
        -- 优先从协程共享表读取 session_id/window_id
        local shared = nil
        pcall(function()
          local sm = require("NeoAI.core.config.state")
          shared = sm.get_shared()
        end)
        local sid = shared and shared.session_id or (proc and proc.session_id)
        local wid = shared and shared.window_id or (proc and proc.window_id)
        vim.api.nvim_exec_autocmds("User", {
          pattern = event_constants.REASONING_CONTENT,
          data = {
            generation_id = gid,
            reasoning_content = content,
            session_id = sid,
            window_id = wid,
          },
        })
      end
    end, _reasoning_throttle.interval_ms)
  end
end

--- 清理 reasoning 节流状态
function M.clear_reasoning_throttle()
  if _reasoning_throttle.timer then
    pcall(_reasoning_throttle.timer.stop, _reasoning_throttle.timer)
    pcall(_reasoning_throttle.timer.close, _reasoning_throttle.timer)
    _reasoning_throttle.timer = nil
  end
  _reasoning_throttle.pending_content = ""
  _reasoning_throttle.generation_id = nil
  _reasoning_throttle.processor = nil
  _reasoning_throttle.params = nil
end

return M
