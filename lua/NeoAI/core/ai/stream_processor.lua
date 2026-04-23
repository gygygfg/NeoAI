-- 流式处理器（重写）
-- 负责处理 AI 响应的流式数据，解析 SSE 格式，支持思考过程、工具调用和普通内容
-- 与 http_client 配合使用，处理真正的 AI API 流式响应
local M = {}

local json = require("NeoAI.utils.json")
local logger = require("NeoAI.utils.logger")

-- 模块状态
local state = {
  initialized = false,
  config = nil,
  active_processors = {}, -- 活跃的流式处理器
}

--- 初始化流式处理器
--- @param options table 配置选项
function M.initialize(options)
  if state.initialized then
    return M
  end

  state.config = options.config or {}
  state.initialized = true

  logger.info("Stream processor initialized")
  return M
end

--- 开始一个新的流式处理会话
--- @param params table 参数
function M.start_stream(params)
  local generation_id = params.generation_id
  local session_id = params.session_id
  local window_id = params.window_id

  state.active_processors[generation_id] = {
    buffer = "",                    -- 原始缓冲区
    content_buffer = "",            -- 累积的普通内容
    reasoning_buffer = "",          -- 累积的思考内容
    tool_calls = {},                -- 累积的工具调用
    usage = {},                     -- token 用量
    session_id = session_id,
    window_id = window_id,
    start_time = os.time(),
    is_finished = false,
  }

  logger.debug(string.format("Stream started: generation=%s", generation_id))
end

--- 处理 SSE 数据块
--- 接收来自 http_client 解析后的 JSON 数据
--- @param params table 处理参数
--- @return table|nil 处理结果
function M.process_chunk(params)
  if not state.initialized then
    error("Stream processor not initialized")
  end

  local generation_id = params.generation_id
  local data = params.data  -- 已解析的 JSON 数据
  local session_id = params.session_id
  local window_id = params.window_id

  local processor = state.active_processors[generation_id]
  if not processor then
    logger.warn(string.format("No active processor for generation %s", generation_id))
    return nil
  end

  if processor.is_finished then
    return nil
  end

  local result = {
    content = nil,
    reasoning_content = nil,
    tool_calls = nil,
    is_final = false,
  }

  -- 解析 SSE 数据
  if data.choices and #data.choices > 0 then
    local choice = data.choices[1]

    if choice.delta then
      local delta = choice.delta

      -- 处理思考内容（DeepSeek 格式）
      if delta.reasoning_content ~= nil then
        local rc = delta.reasoning_content
        if rc ~= "" then
          processor.reasoning_buffer = processor.reasoning_buffer .. rc
          result.reasoning_content = rc
        end
      end

      -- 处理普通内容
      if delta.content ~= nil then
        local content = delta.content
        if content ~= "" then
          processor.content_buffer = processor.content_buffer .. content
          result.content = content
        end
      end

      -- 处理工具调用（流式工具调用可能分多个块）
      if delta.tool_calls then
        for _, tc in ipairs(delta.tool_calls) do
          local index = tc.index or 0
          if not processor.tool_calls[index + 1] then
            processor.tool_calls[index + 1] = {
              id = tc.id or ("call_" .. tostring(os.time()) .. "_" .. tostring(index)),
              type = tc.type or "function",
              ["function"] = {
                name = "",
                arguments = "",
              },
            }
          end

          local existing = processor.tool_calls[index + 1]
          if tc.id then existing.id = tc.id end
          if tc.type then existing.type = tc.type end
          if tc["function"] then
            if tc["function"].name then
              existing["function"].name = existing["function"].name .. tc["function"].name
            end
            if tc["function"].arguments then
              existing["function"].arguments = existing["function"].arguments .. tc["function"].arguments
            end
          end
        end

        -- 只在有完整工具调用时返回
        if #processor.tool_calls > 0 then
          result.tool_calls = vim.deepcopy(processor.tool_calls)
        end
      end
    end

    -- 检查是否结束
    if choice.finish_reason then
      result.is_final = true
      processor.is_finished = true

      logger.debug(string.format(
        "Stream finished (generation=%s): reason=%s, content_len=%d, reasoning_len=%d, tool_calls=%d",
        generation_id,
        choice.finish_reason,
        #processor.content_buffer,
        #processor.reasoning_buffer,
        #processor.tool_calls
      ))
    end
  end

  -- 处理 usage 信息
  if data.usage then
    processor.usage = data.usage
    result.usage = data.usage
  end

  return result
end

--- 获取完整的响应内容
--- @param generation_id string 生成ID
--- @return string 完整的响应文本
function M.get_full_response(generation_id)
  local processor = state.active_processors[generation_id]
  if not processor then
    return ""
  end
  return processor.content_buffer or ""
end

--- 获取 usage 信息
--- @param generation_id string 生成ID
--- @return table usage 信息
function M.get_usage(generation_id)
  local processor = state.active_processors[generation_id]
  if not processor then
    return {}
  end
  return processor.usage or {}
end

--- 获取思考内容
--- @param generation_id string 生成ID
--- @return string 思考文本
function M.get_reasoning_text(generation_id)
  local processor = state.active_processors[generation_id]
  if not processor then
    return ""
  end
  return processor.reasoning_buffer or ""
end

--- 获取工具调用
--- @param generation_id string 生成ID
--- @return table 工具调用列表
function M.get_tool_calls(generation_id)
  local processor = state.active_processors[generation_id]
  if not processor then
    return {}
  end
  return processor.tool_calls or {}
end

--- 结束流式处理
--- @param generation_id string 生成ID
function M.end_stream(generation_id)
  local processor = state.active_processors[generation_id]
  if processor then
    local duration = os.time() - processor.start_time
  logger.debug(string.format(
    "Stream ended (generation=%s): duration=%ds, content=%d chars, reasoning=%d chars",
    generation_id, duration, #(processor.content_buffer or ""), #(processor.reasoning_buffer or "")
  ))
  -- 清理前保存 usage
  processor.usage = processor.usage or {}
    state.active_processors[generation_id] = nil
  end
end

--- 获取模块状态
--- @return table 状态信息
function M.get_state()
  return {
    initialized = state.initialized,
    active_processors_count = vim.tbl_count(state.active_processors),
    config = state.config,
  }
end

--- 关闭流式处理器
function M.shutdown()
  if not state.initialized then
    return
  end

  -- 清理所有活跃处理器
  state.active_processors = {}
  state.initialized = false

  logger.info("Stream processor shutdown")
end

return M
