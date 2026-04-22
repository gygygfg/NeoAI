-- 定义 AI 引擎模块
local M = {}

-- 导入子模块
local response_builder = require("NeoAI.core.ai.response_builder")
local reasoning_manager = require("NeoAI.core.ai.reasoning_manager")
local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
local stream_processor = require("NeoAI.core.ai.stream_processor")
local ai_provider = require("NeoAI.core.ai.ai_provider")
local ai_response_flow = require("NeoAI.core.ai.ai_response_flow")

-- 模块内部状态表
-- 用于维护引擎的运行时状态，避免使用全局变量
local state = {
  initialized = false, -- 标记引擎是否已完成初始化
  config = {}, -- 存储引擎配置
  is_generating = false, -- 标记当前是否正在生成响应
  current_generation_id = nil, -- 当前生成任务的唯一标识符
  tools = {}, -- 存储可用的工具函数

  -- 子模块引用
  response_builder = response_builder,
  reasoning_manager = reasoning_manager,
  tool_orchestrator = tool_orchestrator,
  stream_processor = stream_processor,
  ai_provider = ai_provider,
  ai_response_flow = ai_response_flow,
}

-- 初始化 AI 引擎
-- @param options table 初始化选项，包含事件总线、配置和会话管理器等
-- @return table 返回模块自身，支持链式调用
function M.initialize(options)
  -- 如果已经初始化，则直接返回，避免重复初始化
  if state.initialized then
    return M
  end

  -- 从选项参数中提取并存储必要的组件
  state.config = options.config or {} -- 引擎配置，默认为空表
  state.session_manager = options.session_manager -- 会话管理器

  -- 初始化所有子模块
  state.response_builder.initialize({
    config = state.config,
  })

  state.reasoning_manager.initialize({
    config = state.config,
  })

  state.tool_orchestrator.initialize({
    event_bus = nil, -- 不再需要事件总线，使用原生事件
    config = state.config,
    session_manager = state.session_manager,
    max_iterations = state.config.max_tool_iterations or 10,
  })

  state.stream_processor.initialize({
    config = state.config,
  })

  -- 导入事件常量
  state.event_constants = require("NeoAI.core.events.event_constants")

  -- 初始化AI提供者
  state.ai_provider.initialize(state.config)

  -- 初始化AI响应流程模块
  state.ai_response_flow.initialize({
    config = state.config,
    session_manager = state.session_manager,
  })

  -- 设置事件监听器
  M._setup_event_listeners()

  -- 标记引擎为已初始化状态
  state.initialized = true
  return M
end

-- 生成 AI 响应（非流式）
-- @param messages table 消息列表，通常包含用户输入和可能的上下文
-- @param options table 可选的生成参数
-- @return string 返回本次生成任务的ID
function M.generate_response(messages, options)
  -- 安全检查：确保引擎已初始化
  if not state.initialized then
    error("AI engine not initialized")
  end

  -- 设置生成状态
  state.is_generating = true

  -- 使用 AI 响应流程模块执行完整的响应流程
  local generation_id = state.ai_response_flow.execute_response_flow(messages, options)

  -- 存储生成ID
  state.current_generation_id = generation_id

  return generation_id
end

-- 流式生成 AI 响应
-- @param messages table 消息列表
-- @param options table 可选的生成参数
-- @return function 返回一个流式处理器函数，用于处理数据块
function M.stream_response(messages, options)
  if not state.initialized then
    error("AI engine not initialized")
  end

  -- 设置生成状态
  state.is_generating = true

  -- 设置流式选项
  local flow_options = options or {}
  flow_options.stream = true

  -- 使用 AI 响应流程模块执行流式响应流程
  local generation_id = state.ai_response_flow.execute_response_flow(messages, flow_options)

  -- 存储生成ID
  state.current_generation_id = generation_id

  -- 返回一个空的流式处理器（实际处理在事件中完成）
  local stream_handler = function(chunk)
    -- 这个函数现在由事件系统处理
  end

  -- 返回处理器和取消函数
  return stream_handler, function()
    -- 取消生成
    state.ai_response_flow.cancel_generation()
  end
end

-- 取消当前正在进行的生成任务
-- 无参数，无返回值
function M.cancel_generation()
  -- 如果没有正在生成的任务，则直接返回
  if not state.is_generating then
    return
  end

  -- 获取当前任务ID（可用于日志或事件）
  local generation_id = state.current_generation_id

  -- 调用 AI 响应流程模块的取消函数
  if state.ai_response_flow then
    state.ai_response_flow.cancel_generation()
  end

  -- 清理生成状态
  state.is_generating = false
  state.current_generation_id = nil

  -- 触发取消事件（使用原生事件）
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoAI:generation_cancelled",
    data = {
      generation_id = generation_id,
    },
  })
end

-- 检查引擎是否正在生成响应
-- @return boolean 如果正在生成则返回 true，否则返回 false
function M.is_generating()
  return state.is_generating
end

-- 设置引擎可用的工具函数
-- 支持两种格式：
-- 1. 数组格式: [{name = "tool1", func = function() end}, ...]
-- 2. 键值对格式: {tool1 = {func = function() end}, ...}
-- @param tools table 工具函数表
function M.set_tools(tools)
  if not tools then
    state.tools = {}
    if state.tool_orchestrator then
      state.tool_orchestrator.set_tools({})
    end
    return
  end

  -- 转换工具格式为键值对（工具编排器需要的格式）
  local tools_dict = {}

  if type(tools) == "table" then
    -- 检查是数组还是键值对
    local is_array = false
    for k, v in pairs(tools) do
      if type(k) == "number" then
        is_array = true
        break
      end
    end

    if is_array then
      -- 数组格式：转换为键值对
      for _, tool_def in ipairs(tools) do
        if tool_def.name and tool_def.func then
          tools_dict[tool_def.name] = tool_def
        end
      end
      state.tools = tools -- 保持原始数组格式
    else
      -- 已经是键值对格式
      tools_dict = tools
      -- 转换为数组格式存储
      state.tools = {}
      for name, tool_def in pairs(tools) do
        if tool_def.func then
          table.insert(state.tools, {
            name = name,
            func = tool_def.func,
            description = tool_def.description,
            parameters = tool_def.parameters,
          })
        end
      end
    end
  end

  -- 设置到工具编排器
  if state.tool_orchestrator then
    state.tool_orchestrator.set_tools(tools_dict)
  end

  -- 设置到 AI 响应流程模块
  if state.ai_response_flow then
    state.ai_response_flow.set_tools(tools_dict)
  end
end

-- 处理用户查询（便捷函数）
-- 此函数封装了消息构建和生成响应的过程
-- @param query string 用户输入的查询文本
-- @param options table 可选的生成参数
-- @return nil 不再返回ID，ID将通过事件提供
function M.process_query(query, options)
  if not state.initialized then
    error("AI engine not initialized")
  end

  -- 构建符合接口要求的消息格式
  local messages = {
    {
      role = "user",
      content = query,
    },
  }

  -- 调用内部生成函数
  return M.generate_response(messages, options)
end

-- 获取引擎的当前状态
-- @return table 返回包含状态信息的表
function M.get_status()
  return {
    initialized = state.initialized,
    is_generating = state.is_generating,
    current_generation_id = state.current_generation_id,
    tools_available = state.tools and #state.tools > 0, -- 判断是否有可用工具
    submodules = {
      response_builder = state.response_builder.get_state and state.response_builder.get_state()
        or { initialized = true },
      reasoning_manager = state.reasoning_manager.get_reasoning_state and state.reasoning_manager.get_reasoning_state()
        or { active = false },
      tool_orchestrator = {
        current_iteration = state.tool_orchestrator.get_current_iteration
            and state.tool_orchestrator.get_current_iteration()
          or 0,
        tools_count = state.tools and #state.tools or 0,
      },
      ai_provider = state.ai_provider.get_status and state.ai_provider.get_status() or { initialized = false },
      ai_response_flow = state.ai_response_flow.get_status and state.ai_response_flow.get_status()
        or { initialized = false },
    },
  }
end

-- ========== 子模块功能接口 ==========

-- 响应构建器接口
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

function M.build_tool_call_message(tool_name, arguments, tool_call_id)
  return state.response_builder.build_tool_call_message(tool_name, arguments, tool_call_id)
end

function M.build_tool_result_message(tool_call_id, result, tool_name)
  return state.response_builder.build_tool_result_message(tool_call_id, result, tool_name)
end

function M.build_response(params)
  return state.response_builder.build_response(params)
end

-- 思考管理器接口
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

function M.format_reasoning(reasoning_text_or_include_timestamps)
  return state.reasoning_manager.format_reasoning(reasoning_text_or_include_timestamps)
end

-- 工具编排器接口
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

-- 流式处理器接口
function M.process_chunk(chunk)
  return state.stream_processor.process_chunk(chunk)
end

--- 设置事件监听器（内部函数）
function M._setup_event_listeners()
  -- 注意：AI 响应流程模块已经设置了事件监听器
  -- 这里可以添加其他特定于 AI 引擎的事件监听器
  print("✅ AI 引擎事件监听器已设置（主要监听器在 AI 响应流程模块中）")
end

-- 导出模块
return M
