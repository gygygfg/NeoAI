---@module "NeoAI.core.ai.stream_processor"
--- 流式处理器
--- 职责：创建流式处理器实例、处理流式数据块、管理 reasoning 节流
--- 闭包内私有状态：reasoning_throttle（节流定时器和缓存）

local event_constants = require("NeoAI.core.events")
local state_manager = require("NeoAI.core.config.state")
local logger = require("NeoAI.utils.logger")

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
function M.create_processor(generation_id, session_id, window_id, is_tool_loop)
  return {
    generation_id = generation_id,
    content_buffer = "",
    reasoning_buffer = "",
    tool_calls = {},
    usage = {},
    session_id = session_id,
    window_id = window_id,
    is_tool_loop = is_tool_loop or false,
    start_time = os.time(),
    is_finished = false,
    -- 工具调用累积状态（用于调试和完整性检查）
    _json_depth = 0,           -- 当前 JSON 嵌套深度（{+1, }-1）
    _json_depth_changed = false, -- 深度是否曾发生过变化
  }
end

--- 处理流式数据块
--- 注意：tool_calls 中的 arguments 字段在 http_client 中已解析为 Lua table
--- 流式场景中，每个数据块的 arguments 是部分 table，需要逐块合并
function M.process_chunk(processor, data)
  local result = { content = nil, reasoning_content = nil, tool_calls = nil, tool_calls_delta = nil, is_final = false }

  -- 如果已标记完成，只处理 usage 数据（某些 API 在 finish_reason 后发送 usage）
  if processor.is_finished then
    if data.usage then
      processor.usage = data.usage
      result.usage = data.usage
    end
    return result
  end

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
        -- tool_calls_delta：当前 chunk 的原始增量数据（arguments 是原始片段）
        result.tool_calls_delta = delta.tool_calls
        for _, tc in ipairs(delta.tool_calls) do
          local idx = tc.index or 0
          if not processor.tool_calls[idx + 1] then
            local safe_id = tc.id or ("call_" .. os.time() .. "_" .. idx)
            processor.tool_calls[idx + 1] = {
              id = safe_id, type = tc.type or "function",
              ["function"] = { name = "", arguments = {} },
            }
          end
          local e = processor.tool_calls[idx + 1]
          if tc.id then e.id = tc.id end
          if tc.type then e.type = tc.type end
          if tc["function"] then
            if tc["function"].name then e["function"].name = e["function"].name .. tc["function"].name end
            -- arguments 在流式场景中可能是字符串片段（逐个字符传输）
            -- 也可能是解析后的 Lua table（非流式或已解析的 chunk）
            if tc["function"].arguments ~= nil then
              if type(tc["function"].arguments) == "string" then
                -- 流式场景：arguments 是逐个字符传输的 JSON 字符串片段
                -- 需要拼接到累积的 arguments 字符串中
                if type(e["function"].arguments) == "table" then
                  -- 首次收到字符串参数，将初始空 table 转为空字符串
                  e["function"].arguments = tc["function"].arguments
                  -- 首次收到字符串参数时，计算初始 JSON 深度
                  M._update_json_depth(processor, tc["function"].arguments)
                elseif type(e["function"].arguments) == "string" then
                  -- 更新 JSON 深度（在拼接前计算新增片段的深度变化）
                  M._update_json_depth(processor, tc["function"].arguments)
                  e["function"].arguments = e["function"].arguments .. tc["function"].arguments
                end
              elseif type(tc["function"].arguments) == "table" then
                -- 直接替换为新的 table，避免空 table {} 无法覆盖之前累积的空字符串 ""
                e["function"].arguments = tc["function"].arguments
              end
            end
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
            ["function"] = { name = "", arguments = {} },
          }
        end
        local e = processor.tool_calls[idx + 1]
        if tc.id then e.id = tc.id end
        if tc.type then e.type = tc.type end
        if tc["function"] then
          if tc["function"].name then e["function"].name = tc["function"].name end
          -- arguments 在流式场景中可能是字符串片段
          if tc["function"].arguments ~= nil then
            if type(tc["function"].arguments) == "string" then
              if type(e["function"].arguments) == "table" then
                e["function"].arguments = tc["function"].arguments
                -- 首次收到字符串参数时，计算初始 JSON 深度
                M._update_json_depth(processor, tc["function"].arguments)
              elseif type(e["function"].arguments) == "string" then
                -- 更新 JSON 深度（在拼接前计算新增片段的深度变化）
                M._update_json_depth(processor, tc["function"].arguments)
                e["function"].arguments = e["function"].arguments .. tc["function"].arguments
              end
            elseif type(tc["function"].arguments) == "table" then
              -- 直接替换为新的 table，避免空 table {} 无法覆盖之前累积的空字符串 ""
              e["function"].arguments = tc["function"].arguments
            end
          end
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

  -- ===== 工具调用累积日志（仅调试用，不打断流式接收） =====
  if result.tool_calls_delta and #result.tool_calls_delta > 0 then
    if M._check_json_depth_zero(processor) and processor._json_depth_changed then
      logger.debug("[stream_processor] 工具调用 JSON 深度为0，等待 finish_reason")
    end
  end

  return result
end

--- 过滤无效工具调用（流式截断导致 name 为空或 arguments 为空）
--- 同时将流式累积的字符串 arguments 解析为 Lua table
function M.filter_valid_tool_calls(tool_calls)
  local valid = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name and func.name ~= "" then
      local args = func.arguments
      -- 将流式累积的字符串 arguments 解析为 Lua table
      if type(args) == "string" and args ~= "" then
        local ok, parsed = pcall(vim.json.decode, args)
        if ok and type(parsed) == "table" then
          func.arguments = parsed
          args = parsed
        end
      end
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
        local shared = state_manager.get_shared()
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

--- 更新 JSON 深度计数器
--- 统计字符串中的 { (+1) 和 } (-1)，用于判断 JSON 是否完整
--- @param processor table 流式处理器实例
--- @param str string 新增的字符串片段
function M._update_json_depth(processor, str)
  if not processor or not str or type(str) ~= "string" then
    return
  end
  local changed = false
  for i = 1, #str do
    local c = str:sub(i, i)
    if c == "{" then
      processor._json_depth = processor._json_depth + 1
      changed = true
    elseif c == "}" then
      processor._json_depth = processor._json_depth - 1
      changed = true
    end
  end
  if changed then
    processor._json_depth_changed = true
  end
end

--- 检查 JSON 深度是否为 0
--- 深度为 0 表示所有 { 都已闭合，JSON 可能完整
--- @param processor table 流式处理器实例
--- @return boolean
function M._check_json_depth_zero(processor)
  if not processor then
    return false
  end
  return processor._json_depth == 0
end

--- 尝试格式化当前累积的工具调用 arguments
--- 在流式结束后调用：将所有工具调用的 arguments 从字符串解析为 Lua table
--- @param processor table 流式处理器实例
--- @return table|nil 格式化成功的 tool_calls，或 nil
function M.try_finalize_tool_calls(processor)
  if not processor or not processor.tool_calls or #processor.tool_calls == 0 then
    return nil
  end

  local finalized = {}
  for _, tc in ipairs(processor.tool_calls) do
    local func = tc["function"] or tc.func
    if not func or not func.name or func.name == "" then
      -- 工具名称为空，跳过（可能是不完整的流式片段）
      logger.debug("[stream_processor] try_finalize_tool_calls: 跳过名称为空的工具调用")
      return nil
    end

    local args = func.arguments
    if type(args) == "string" and args ~= "" then
      local ok, parsed = pcall(vim.json.decode, args)
      if ok and type(parsed) == "table" then
        func.arguments = parsed
        args = parsed
      else
        -- JSON 不完整，无法完成
        logger.debug("[stream_processor] try_finalize_tool_calls: 工具 '%s' 的 arguments JSON 不完整: %s",
          func.name, args:sub(1, 200))
        return nil
      end
    end

    if args == nil then
      logger.debug("[stream_processor] try_finalize_tool_calls: 工具 '%s' 的 arguments 为 nil", func.name)
      return nil
    end

    table.insert(finalized, tc)
  end

  if #finalized > 0 then
    logger.debug("[stream_processor] try_finalize_tool_calls: 成功格式化 %d 个工具调用", #finalized)
    return finalized
  end
  return nil
end

--- 清理 reasoning 节流状态
function M.clear_reasoning_throttle()
  if _reasoning_throttle.timer then
    local timer = _reasoning_throttle.timer
    pcall(function()
      if timer:is_active() then timer:stop() end
      if not timer:is_closing() then timer:close() end
    end)
    _reasoning_throttle.timer = nil
  end
  _reasoning_throttle.pending_content = ""
  _reasoning_throttle.generation_id = nil
  _reasoning_throttle.processor = nil
  _reasoning_throttle.params = nil
end

--- 清理处理器中的工具调用状态
--- @param processor table|nil 流式处理器实例
function M.clear_dual_trigger_state(processor)
  if not processor then
    return
  end
  processor._json_depth = 0
  processor._json_depth_changed = false
end

--- 检查处理器是否已完成（兼容接口）
--- @param processor table 流式处理器实例
--- @return boolean
function M.is_tool_calls_ready(processor)
  return processor and processor.is_finished
end

return M
