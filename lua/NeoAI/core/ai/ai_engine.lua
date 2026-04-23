-- AI 引擎主入口（重新设计）
-- 负责接收聊天事件信息，协调各个子模块工作
-- 使用真正的 HTTP 客户端调用 AI API，不再使用模拟响应
local M = {}

-- 导入子模块
local request_builder = require("NeoAI.core.ai.request_builder")
local reasoning_manager = require("NeoAI.core.ai.reasoning_manager")
local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
local stream_processor = require("NeoAI.core.ai.stream_processor")
local response_builder = require("NeoAI.core.ai.response_builder")
local http_client = require("NeoAI.core.ai.http_client")

-- 导入工具
local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events.event_constants")
local json = require("NeoAI.utils.json")

-- 模块内部状态
local state = {
  initialized = false,
  config = {},
  is_generating = false,
  current_generation_id = nil,
  tools = {},
  session_manager = nil,
  active_generations = {},
  event_listeners = {},

  -- 子模块引用
  request_builder = request_builder,
  response_builder = response_builder,
  reasoning_manager = reasoning_manager,
  tool_orchestrator = tool_orchestrator,
  stream_processor = stream_processor,
  http_client = http_client,

  -- 重试配置
  max_retries = 3,
  retry_delay_ms = 1000,
}

--- 初始化 AI 引擎
--- @param options table 初始化选项，包含配置和会话管理器
--- @return table 返回模块自身，支持链式调用
function M.initialize(options)
  if state.initialized then
    return M
  end

  -- 从选项参数中提取并存储必要的组件
  state.config = options.config or {}
  state.session_manager = options.session_manager

  -- 初始化所有子模块
  state.request_builder.initialize({
    config = state.config,
  })

  state.response_builder.initialize({
    config = state.config,
    session_manager = state.session_manager,
  })

  state.reasoning_manager.initialize({
    config = state.config,
  })

  state.tool_orchestrator.initialize({
    config = state.config,
    session_manager = state.session_manager,
    max_iterations = state.config.max_tool_iterations or 10,
  })

  state.stream_processor.initialize({
    config = state.config,
  })

  -- 初始化 HTTP 客户端（真正的 AI API 调用）
  state.http_client.initialize({
    config = {
      base_url = state.config.base_url,
      api_key = state.config.api_key,
      timeout = state.config.timeout or 60000,
    },
  })

  -- 设置事件监听器
  M.setup_event_listeners()

  -- 标记引擎为已初始化状态
  state.initialized = true

  -- 触发插件初始化完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.PLUGIN_INITIALIZED,
  })

  logger.info("AI engine initialized")
  return M
end

--- 设置事件监听器
function M.setup_event_listeners()
  -- 监听发送消息事件
  state.event_listeners.send_message = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.SEND_MESSAGE,
    callback = function(args)
      M.handle_send_message(args.data)
    end,
  })

  -- 监听工具执行完成事件
  state.event_listeners.tool_result_received = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.TOOL_RESULT_RECEIVED,
    callback = function(args)
      M.handle_tool_result(args.data)
    end,
  })

  -- 监听流式处理完成事件
  state.event_listeners.stream_completed = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.STREAM_COMPLETED,
    callback = function(args)
      M.handle_stream_completed(args.data)
    end,
  })

  logger.debug("Event listeners setup completed")
end

--- 处理发送消息事件
--- @param data table 事件数据
function M.handle_send_message(data)
  if not state.initialized then
    logger.error("AI engine not initialized when handling send message")
    return
  end

  if state.is_generating then
    logger.warn("Already generating, ignoring new message")
    return
  end

  local content = data.content
  local session_id = data.session_id
  local window_id = data.window_id
  local options = data.options or {}

  logger.debug(string.format("Handling send message: session=%s, window=%s", session_id or "nil", window_id or "nil"))

  -- 设置生成状态
  state.is_generating = true

  -- 从会话管理器获取消息历史
  local messages = {}
  if state.session_manager and session_id and state.session_manager.get_session then
    local session = state.session_manager.get_session(session_id)
    if session and session.get_messages then
      messages = session:get_messages() or {}
    end
  end

  -- 添加用户消息
  table.insert(messages, {
    role = "user",
    content = content,
    timestamp = os.time(),
    window_id = window_id,
  })

  -- 触发用户消息发送事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.USER_MESSAGE_SENT,
    data = {
      message = messages[#messages],
      session_id = session_id,
      window_id = window_id,
      timestamp = os.time(),
    },
  })

  -- 开始生成响应
  M.generate_response(messages, {
    session_id = session_id,
    window_id = window_id,
    options = options,
  })
end

--- 生成 AI 响应
--- 使用真正的 HTTP 客户端调用 AI API，支持流式和非流式模式
--- @param messages table 消息列表
--- @param params table 生成参数
function M.generate_response(messages, params)
  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}

  -- 生成唯一ID
  local generation_id = tostring(os.time()) .. "_" .. math.random(1000, 9999)
  state.current_generation_id = generation_id
  state.active_generations[generation_id] = {
    start_time = os.time(),
    messages = messages,
    session_id = session_id,
    window_id = window_id,
    options = options,
    retry_count = 0,
  }

  -- 格式化消息
  local formatted_messages = state.request_builder.format_messages(messages)

  -- 构建请求
  local request = state.request_builder.build_request({
    messages = formatted_messages,
    options = options,
    session_id = session_id,
    generation_id = generation_id,
  })

  -- 触发生成开始事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_STARTED,
    data = {
      generation_id = generation_id,
      formatted_messages = formatted_messages,
      request = request,
      session_id = session_id,
      window_id = window_id,
    },
  })

  -- logger.info(string.format(
  --   "Generation started: id=%s, messages=%d, tools=%s, stream=%s",
  --   generation_id,
  --   #formatted_messages,
  --   request.tools and #request.tools or 0,
  --   tostring(request.stream)
  -- ))

  -- 根据是否启用流式选择不同的请求方式
  if request.stream then
    M._send_stream_request(generation_id, request, {
      session_id = session_id,
      window_id = window_id,
      options = options,
    })
  else
    M._send_non_stream_request(generation_id, request, {
      session_id = session_id,
      window_id = window_id,
      options = options,
    })
  end
end

--- 发送非流式请求
--- @param generation_id string 生成ID
--- @param request table 请求体
--- @param params table 参数
function M._send_non_stream_request(generation_id, request, params)
  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}
  local generation = state.active_generations[generation_id]

  if not generation then
    return
  end

  -- 发送请求到 AI API
  local response, err = state.http_client.send_request({
    request = request,
    generation_id = generation_id,
  })

  if err then
    -- 检查是否需要重试
    if generation.retry_count < state.max_retries then
      generation.retry_count = generation.retry_count + 1
      logger.warn(
        string.format(
          "Request failed (generation=%s, attempt=%d/%d): %s. Retrying...",
          generation_id,
          generation.retry_count,
          state.max_retries,
          err
        )
      )
      vim.wait(state.retry_delay_ms)
      M._send_non_stream_request(generation_id, request, params)
      return
    end

    M.handle_generation_error(generation_id, err)
    return
  end

  -- 检查 API 错误
  if response.error then
    local err_msg = response.error.message or json.encode(response.error)
    M.handle_generation_error(generation_id, err_msg)
    return
  end

  -- 处理响应
  M.handle_ai_response(generation_id, response, {
    session_id = session_id,
    window_id = window_id,
    options = options,
  })
end

--- 发送流式请求
--- @param generation_id string 生成ID
--- @param request table 请求体
--- @param params table 参数
function M._send_stream_request(generation_id, request, params)
  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}

  -- 触发流式开始事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.STREAM_STARTED,
    data = {
      generation_id = generation_id,
      session_id = session_id,
      window_id = window_id,
    },
  })

  -- 初始化流式处理器
  state.stream_processor.start_stream({
    generation_id = generation_id,
    session_id = session_id,
    window_id = window_id,
  })

  -- 发送流式请求
  state.http_client.send_stream_request(
    {
      request = request,
      generation_id = generation_id,
    },
    -- on_chunk: 处理每个数据块
    function(data)
      M._handle_stream_chunk(generation_id, data, {
        session_id = session_id,
        window_id = window_id,
        options = options,
      })
    end,
    -- on_complete: 流式请求完成
    function()
      M._handle_stream_end(generation_id, {
        session_id = session_id,
        window_id = window_id,
        options = options,
      })
    end,
    -- on_error: 流式请求出错
    function(err)
      local generation = state.active_generations[generation_id]
      if generation and generation.retry_count < state.max_retries then
        generation.retry_count = generation.retry_count + 1
        logger.warn(
          string.format(
            "Stream request failed (generation=%s, attempt=%d/%d): %s. Retrying...",
            generation_id,
            generation.retry_count,
            state.max_retries,
            err
          )
        )
        vim.wait(state.retry_delay_ms)
        M._send_stream_request(generation_id, request, params)
        return
      end
      M.handle_generation_error(generation_id, err)
    end
  )
end

--- 处理流式数据块
--- @param generation_id string 生成ID
--- @param data table SSE 数据块
--- @param params table 参数
function M._handle_stream_chunk(generation_id, data, params)
  local session_id = params.session_id
  local window_id = params.window_id

  -- 使用 stream_processor 解析数据块
  local result = state.stream_processor.process_chunk({
    generation_id = generation_id,
    data = data,
    session_id = session_id,
    window_id = window_id,
  })

  if not result then
    return
  end

  -- 处理思考内容
  if result.reasoning_content then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.REASONING_CONTENT,
      data = {
        generation_id = generation_id,
        reasoning_content = result.reasoning_content,
        session_id = session_id,
        window_id = window_id,
      },
    })
  end

  -- 处理普通内容
  if result.content then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.STREAM_CHUNK,
      data = {
        generation_id = generation_id,
        chunk = result.content,
        session_id = session_id,
        window_id = window_id,
        is_final = false,
      },
    })
  end

  -- 处理工具调用
  if result.tool_calls and #result.tool_calls > 0 then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_CALL_DETECTED,
      data = {
        generation_id = generation_id,
        tool_calls = result.tool_calls,
        session_id = session_id,
        window_id = window_id,
      },
    })
  end
end

--- 处理流式请求结束
--- @param generation_id string 生成ID
--- @param params table 参数
function M._handle_stream_end(generation_id, params)
  local session_id = params.session_id
  local window_id = params.window_id

  -- 获取完整的流式响应
  local full_response = state.stream_processor.get_full_response(generation_id)
  local reasoning_text = state.stream_processor.get_reasoning_text(generation_id)
  local usage = state.stream_processor.get_usage(generation_id)

  -- 清理流式处理器
  state.stream_processor.end_stream(generation_id)

  -- 触发流式完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.STREAM_COMPLETED,
    data = {
      generation_id = generation_id,
      full_response = full_response,
      reasoning_text = reasoning_text,
      usage = usage,
      session_id = session_id,
      window_id = window_id,
    },
  })

  -- 完成生成（传入 reasoning_text，因为 stream_processor 已被清理）
  M._finalize_generation(generation_id, full_response, {
    session_id = session_id,
    window_id = window_id,
    reasoning_text = reasoning_text,
    usage = usage,
  })
end

--- 完成生成（通用结束处理）
--- @param generation_id string 生成ID
--- @param response_text string 响应文本
--- @param params table 参数
function M._finalize_generation(generation_id, response_text, params)
  local session_id = params.session_id
  local window_id = params.window_id
  local generation = state.active_generations[generation_id]

  if not generation then
    return
  end

  local messages = generation.messages

  -- 添加助手响应到消息历史
  table.insert(messages, {
    role = "assistant",
    content = response_text or "",
    timestamp = os.time(),
    window_id = window_id,
  })

  -- 获取思考内容（优先使用传入的参数，因为流式处理器可能已被清理）
  local reasoning_text = params.reasoning_text or state.stream_processor.get_reasoning_text(generation_id)
  local usage = params.usage or {}

  -- 触发生成完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_COMPLETED,
    data = {
      generation_id = generation_id,
      response = response_text or "",
      reasoning_text = reasoning_text or "",
      usage = usage,
      session_id = session_id,
      window_id = window_id,
      duration = os.time() - generation.start_time,
    },
  })

  -- 清理活跃生成
  state.active_generations[generation_id] = nil
  state.is_generating = false
  state.current_generation_id = nil

  -- logger.info(string.format(
  --   "Generation completed: id=%s, duration=%ds",
  --   generation_id, os.time() - generation.start_time
  -- ))

  -- 保存会话
  if
    state.session_manager
    and session_id
    and state.session_manager.get_session
    and state.session_manager.save_session
  then
    local session = state.session_manager.get_session(session_id)
    if session then
      state.session_manager.save_session(session_id)
    end
  end
end

--- 处理AI响应（非流式）
--- 从真正的 API 响应中提取内容
--- @param generation_id string 生成ID
--- @param response table API响应
--- @param params table 参数
function M.handle_ai_response(generation_id, response, params)
  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}

  -- 从 API 响应中提取内容
  local response_content = ""
  local reasoning_content = nil
  local tool_calls = {}

  if response.choices and #response.choices > 0 then
    local choice = response.choices[1]

    -- 提取消息内容
    if choice.message then
      if choice.message.content then
        response_content = choice.message.content
      end

      -- 提取思考内容（非流式模式：不触发 REASONING_CONTENT 事件，避免打开悬浮窗）
      if choice.message.reasoning_content then
        reasoning_content = choice.message.reasoning_content
      end

      -- 提取工具调用
      if choice.message.tool_calls and #choice.message.tool_calls > 0 then
        tool_calls = choice.message.tool_calls

        vim.api.nvim_exec_autocmds("User", {
          pattern = event_constants.TOOL_CALL_DETECTED,
          data = {
            generation_id = generation_id,
            tool_calls = tool_calls,
            session_id = session_id,
            window_id = window_id,
          },
        })
      end
    end
  end

  -- 如果有工具调用，交给工具编排器处理
  if #tool_calls > 0 and state.config.tools_enabled ~= false then
    local tool_results = state.tool_orchestrator.execute_tool_loop({
      generation_id = generation_id,
      tool_calls = tool_calls,
      session_id = session_id,
      window_id = window_id,
      options = options,
    })

    if tool_results and #tool_results > 0 then
      -- 触发工具结果接收事件
      vim.api.nvim_exec_autocmds("User", {
        pattern = event_constants.TOOL_RESULT_RECEIVED,
        data = {
          generation_id = generation_id,
          tool_results = tool_results,
          session_id = session_id,
          window_id = window_id,
        },
      })
      return
    end
  end

  -- 完成生成
  M._finalize_generation(generation_id, response_content, {
    session_id = session_id,
    window_id = window_id,
    reasoning_text = reasoning_content,
  })
end

--- 处理工具执行结果
--- @param data table 事件数据
function M.handle_tool_result(data)
  local generation_id = data.generation_id
  local tool_results = data.tool_results
  local session_id = data.session_id
  local window_id = data.window_id

  if not state.active_generations[generation_id] then
    logger.warn(string.format("No active generation found for tool result: %s", generation_id))
    return
  end

  local generation = state.active_generations[generation_id]
  local messages = generation.messages
  local options = generation.options or {}

  -- 添加工具调用结果到消息历史
  for _, tool_result in ipairs(tool_results or {}) do
    messages = state.request_builder.add_tool_call_to_history(messages, tool_result.tool_call, tool_result.result)
  end

  -- 更新活跃生成的消息
  generation.messages = messages

  -- 继续生成响应
  M.generate_response(messages, {
    session_id = session_id,
    window_id = window_id,
    options = options,
  })
end

--- 处理流式处理完成
--- @param data table 事件数据
function M.handle_stream_completed(data)
  local generation_id = data.generation_id
  local full_response = data.full_response
  local session_id = data.session_id
  local window_id = data.window_id

  if not state.active_generations[generation_id] then
    logger.warn(string.format("No active generation found for stream completion: %s", generation_id))
    return
  end

  -- 使用统一的结束处理
  M._finalize_generation(generation_id, full_response, {
    session_id = session_id,
    window_id = window_id,
    reasoning_text = data.reasoning_text,
  })
end

--- 处理生成错误
--- @param generation_id string 生成ID
--- @param error_msg string 错误信息
function M.handle_generation_error(generation_id, error_msg)
  local generation = state.active_generations[generation_id]
  if not generation then
    return
  end

  -- 触发生成错误事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_ERROR,
    data = {
      generation_id = generation_id,
      error_msg = error_msg,
      session_id = generation.session_id,
      window_id = generation.window_id,
    },
  })

  -- 清理活跃生成
  state.active_generations[generation_id] = nil
  state.is_generating = false
  state.current_generation_id = nil

  -- logger.error(string.format("Generation error: id=%s, error=%s", generation_id, error_msg))
end

--- 取消当前正在进行的生成任务
function M.cancel_generation()
  if not state.is_generating then
    return
  end

  local generation_id = state.current_generation_id
  local generation = state.active_generations[generation_id]

  if generation then
    -- 取消 HTTP 请求
    state.http_client.cancel_all_requests()

    -- 清理流式处理器
    state.stream_processor.end_stream(generation_id)

    -- 触发取消事件
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.GENERATION_CANCELLED,
      data = {
        generation_id = generation_id,
        session_id = generation.session_id,
        window_id = generation.window_id,
      },
    })

    -- 清理活跃生成
    if generation_id then
      state.active_generations[generation_id] = nil
    end
  end

  -- 清理生成状态
  state.is_generating = false
  state.current_generation_id = nil

  -- logger.info(string.format("Generation cancelled: id=%s", generation_id or "unknown"))
end

--- 设置引擎可用的工具函数
--- @param tools table 工具函数表
function M.set_tools(tools)
  if not tools then
    state.tools = {}
    state.request_builder.set_tools({})
    state.tool_orchestrator.set_tools({})
    return
  end

  -- 存储工具
  state.tools = tools

  -- 设置到各个子模块
  state.request_builder.set_tools(tools)
  state.tool_orchestrator.set_tools(tools)

  logger.debug(
    string.format(
      "AI engine tools set: %d tools available",
      type(tools) == "table" and (tools[1] and #tools or vim.tbl_count(tools)) or 0
    )
  )
end

--- 处理用户查询（便捷函数）
--- @param query string 用户输入的查询文本
--- @param options table 可选的生成参数
function M.process_query(query, options)
  if not state.initialized then
    error("AI engine not initialized")
  end

  -- 构建消息
  local messages = {
    {
      role = "user",
      content = query,
    },
  }

  -- 触发用户消息发送事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.USER_MESSAGE_SENT,
    data = {
      message = messages[1],
      timestamp = os.time(),
    },
  })

  -- 调用内部生成函数
  return M.generate_response(messages, {
    options = options,
  })
end

--- 获取引擎的当前状态
--- @return table 返回包含状态信息的表
function M.get_status()
  return {
    initialized = state.initialized,
    is_generating = state.is_generating,
    current_generation_id = state.current_generation_id,
    active_generations_count = vim.tbl_count(state.active_generations),
    tools_available = state.tools and (state.tools[1] and #state.tools > 0 or vim.tbl_count(state.tools) > 0),
    submodules = {
      request_builder = state.request_builder.get_status and state.request_builder.get_status()
        or { initialized = true },
      response_builder = state.response_builder.get_state and state.response_builder.get_state()
        or { initialized = true },
      reasoning_manager = state.reasoning_manager.get_reasoning_state and state.reasoning_manager.get_reasoning_state()
        or { active = false },
      tool_orchestrator = {
        current_iteration = state.tool_orchestrator.get_current_iteration
            and state.tool_orchestrator.get_current_iteration()
          or 0,
        tools_count = state.tools and (state.tools[1] and #state.tools or vim.tbl_count(state.tools)) or 0,
      },
      http_client = state.http_client.get_state and state.http_client.get_state() or { initialized = false },
    },
  }
end

--- 清理事件监听器
function M.cleanup_event_listeners()
  for name, id in pairs(state.event_listeners) do
    if id then
      vim.api.nvim_del_autocmd(id)
    end
  end
  state.event_listeners = {}
  logger.debug("Event listeners cleaned up")
end

--- 关闭 AI 引擎
function M.shutdown()
  if not state.initialized then
    return
  end

  -- 取消所有活跃的生成
  if state.is_generating then
    M.cancel_generation()
  end

  -- 关闭 HTTP 客户端
  state.http_client.shutdown()

  -- 关闭流式处理器
  state.stream_processor.shutdown()

  -- 清理事件监听器
  M.cleanup_event_listeners()

  -- 清理活跃生成
  state.active_generations = {}

  -- 重置状态
  state.initialized = false
  state.is_generating = false
  state.current_generation_id = nil

  logger.info("AI engine shutdown")
end

-- ========== 子模块功能接口 ==========

--- 请求构建器接口
function M.build_request(params)
  return state.request_builder.build_request(params)
end

function M.format_messages(messages)
  return state.request_builder.format_messages(messages)
end

function M.build_tool_call_message(tool_name, arguments, tool_call_id)
  return state.request_builder.build_tool_call_message(tool_name, arguments, tool_call_id)
end

function M.build_tool_result_message(tool_call_id, result, tool_name)
  return state.request_builder.build_tool_result_message(tool_call_id, result, tool_name)
end

function M.estimate_request_tokens(request)
  return state.request_builder.estimate_request_tokens(request)
end

--- 响应构建器接口
function M.build_messages(history, query, options)
  return state.response_builder.build_messages(history, query, options)
end

function M.format_tool_result(result)
  return state.response_builder.format_tool_result(result)
end

function M.create_summary(messages, max_length)
  return state.response_builder.create_summary(messages, max_length)
end

function M.compact_context(messages, max_tokens)
  return state.response_builder.compact_context(messages, max_tokens)
end

function M.estimate_tokens(text)
  return state.response_builder.estimate_tokens(text)
end

function M.estimate_message_tokens(messages)
  return state.response_builder.estimate_message_tokens(messages)
end

--- 思考管理器接口
function M.start_reasoning()
  return state.reasoning_manager.start_reasoning()
end

function M.append_reasoning(content)
  return state.reasoning_manager.append_reasoning(content)
end

function M.finish_reasoning()
  return state.reasoning_manager.finish_reasoning()
end

function M.get_reasoning()
  return state.reasoning_manager.get_reasoning()
end

function M.get_reasoning_text()
  return state.reasoning_manager.get_reasoning_text()
end

function M.clear_reasoning()
  return state.reasoning_manager.clear_reasoning()
end

function M.is_reasoning_active()
  return state.reasoning_manager.is_reasoning_active()
end

function M.get_reasoning_summary(max_length)
  return state.reasoning_manager.get_reasoning_summary(max_length)
end

function M.format_reasoning(reasoning_text_or_include_timestamps, include_timestamps)
  return state.reasoning_manager.format_reasoning(reasoning_text_or_include_timestamps, include_timestamps)
end

--- 工具编排器接口
function M.execute_tool_loop(messages)
  return state.tool_orchestrator.execute_tool_loop(messages)
end

function M.execute_tools(messages_or_tool_calls)
  return state.tool_orchestrator.execute_tools(messages_or_tool_calls)
end

function M.select_tools(query, available_tools)
  return state.tool_orchestrator.select_tools(query, available_tools)
end

function M.merge_results(results)
  return state.tool_orchestrator.merge_results(results)
end

function M.validate_tool_use(tool_call)
  return state.tool_orchestrator.validate_tool_use(tool_call)
end

function M.extract_tool_calls(response)
  return state.tool_orchestrator.extract_tool_calls(response)
end

function M.execute_tool(tool_call)
  return state.tool_orchestrator.execute_tool(tool_call)
end

function M.build_context(tool_results)
  return state.tool_orchestrator.build_context(tool_results)
end

function M.should_continue(tool_results)
  return state.tool_orchestrator.should_continue(tool_results)
end

function M.get_current_iteration()
  return state.tool_orchestrator.get_current_iteration()
end

function M.get_tools()
  return state.tool_orchestrator.get_tools()
end

--- 流式处理器接口
function M.process_chunk(chunk)
  return state.stream_processor.process_chunk(chunk)
end

--- 导出模块
return M
