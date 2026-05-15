-- AI 引擎核心
-- 职责：AI 生成流程编排、事件调度
-- 请求构建委托给 request_handler
-- 重试逻辑委托给 request_handler
-- 工具循环委托给 tool_cycle
-- HTTP 请求委托给 http_utils
-- 工具管理委托给 tool_registry
-- 自动命名委托给 chat_service

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local json = require("NeoAI.utils.json")
local config_merger = require("NeoAI.core.config.merger")
local shutdown_flag = require("NeoAI.core.shutdown_flag")
local state_manager = require("NeoAI.core.config.state")

-- 子模块
local http_utils = require("NeoAI.utils.http_utils")
local tool_cycle = require("NeoAI.core.ai.tool_cycle")
local request_handler = require("NeoAI.core.ai.request_handler")

-- ========== 闭包内私有状态 ==========
local state = {
  initialized = false,
  is_generating = false,
  current_generation_id = nil,
  event_listeners = {},
  max_retries = 3,
  retry_delay_ms = 1000,
  active_generations = {},
  -- 防止 cancel_generation 被重复执行（多次按停止键时只生效一次）
  _cancel_processed = false,
}

-- ========== 初始化 ==========
local M = {}

function M.initialize(options)
  if state.initialized then return M end

  http_utils.initialize({ config = {} })
  local full_config = (options or {}).config or {}
  tool_cycle.initialize({ config = full_config })
  local tool_pack = require("NeoAI.tools.tool_pack")
  tool_pack.initialize()
  _setup_event_listeners()
  state.initialized = true
  vim.api.nvim_exec_autocmds("User", { pattern = event_constants.PLUGIN_INITIALIZED })
  logger.info("AI engine initialized")
  return M
end

-- ========== 事件监听 ==========
function _setup_event_listeners()
  state.event_listeners.tool_result_received = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.TOOL_RESULT_RECEIVED,
    callback = function(args) M.handle_tool_result(args.data) end,
  })
  state.event_listeners.stream_completed = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.STREAM_COMPLETED,
    callback = function(args) M.handle_stream_completed(args.data) end,
  })
  state.event_listeners.cancel_generation = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.CANCEL_GENERATION,
    callback = function() M.cancel_generation() end,
  })
  -- TOOL_CALLS_READY 事件监听器（保留但不再触发提前结束）
  -- 流式接收将持续到 finish_reason 到达，不再由双触发机制提前结束
  state.event_listeners.tool_calls_ready = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.TOOL_CALLS_READY,
    callback = function(args)
      local data = args.data
      if not data or not data.generation_id then
        return
      end
      local gen = state.active_generations[data.generation_id]
      if not gen then
        return
      end
      local processor = gen._stream_processor
      if not processor then
        return
      end
      -- 仅记录日志，不再触发提前结束
      logger.debug("[ai_engine] TOOL_CALLS_READY 事件到达（不再触发提前结束，等待 finish_reason）")
    end,
  })
end

-- ========== 配置解析 ==========
local function resolve_scenario_config(scenario)
  if config_merger and config_merger.get_preset then
    local preset = config_merger.get_preset(scenario)
    if preset and preset.base_url and preset.api_key then return preset end
  end
  local core = require("NeoAI.core")
  local full_config = core.get_config() or {}
  local ai_config = (full_config and full_config.ai) or {}
  local scenarios = ai_config.scenarios or {}
  local entry = scenarios[scenario] or scenarios[ai_config.default or "chat"]
  if not entry then return {} end
  local candidate = type(entry) == "table" and (entry[1] or entry) or entry
  if not candidate then return {} end
  local provider_name = candidate.provider or "deepseek"
  local provider = (ai_config.providers or {})[provider_name]
  local result = {}
  if provider then result.base_url = provider.base_url; result.api_key = provider.api_key end
  for k, v in pairs(candidate) do result[k] = v end
  if result.stream == nil then result.stream = ai_config.stream end
  if result.timeout == nil then result.timeout = ai_config.timeout end
  if result.system_prompt == nil then result.system_prompt = ai_config.system_prompt end
  return result
end

local function get_model_config(model_index)
  model_index = model_index or 1
  local preset = {}
  -- 优先使用场景候选配置（用户通过 scenarios 指定的模型和参数）
  if config_merger and config_merger.get_scenario_candidates then
    local candidates = config_merger.get_scenario_candidates("chat")
    local target = candidates[model_index]
    if target then
      preset = vim.deepcopy(target)
      preset.model = preset.model_name
      logger.debug("[ai_engine] get_model_config: 从场景候选获取 model_name=%s, provider=%s", tostring(preset.model_name), tostring(preset.provider))
    end
  end
  -- 如果场景候选没有 base_url/api_key（如 api_key 为空），回退到 get_available_models
  if not preset.base_url or not preset.api_key then
    if config_merger and config_merger.get_available_models then
      local models = config_merger.get_available_models("chat")
      local target = models[model_index]
      if target then
        local core = require("NeoAI.core")
        local full_config = core.get_config() or {}
        local providers = (full_config and full_config.ai and full_config.ai.providers) or {}
        local pdef = providers[target.provider]
        if pdef then
          preset.base_url = pdef.base_url; preset.api_key = pdef.api_key
          preset.provider = target.provider; preset.model_name = target.model_name
          preset.model = target.model_name
          -- 从场景配置中继承 temperature/max_tokens 等参数
          local candidates = config_merger.get_scenario_candidates("chat")
          for _, c in ipairs(candidates) do
            if c.provider == target.provider and c.model_name == target.model_name then
              for k, v in pairs(c) do
                if k ~= "provider" and k ~= "model_name" and k ~= "base_url" and k ~= "api_key" and k ~= "api_type" then
                  preset[k] = v
                end
              end
              break
            end
          end
          if not preset.stream then preset.stream = true end
          if not preset.timeout then preset.timeout = 60000 end
          logger.debug("[ai_engine] get_model_config: 从可用模型列表获取 model_name=%s, provider=%s", tostring(preset.model_name), tostring(preset.provider))
        end
      end
    end
  end
  if not preset.base_url or not preset.api_key then
    preset = resolve_scenario_config("chat")
    logger.debug("[ai_engine] get_model_config: 回退到 resolve_scenario_config, model_name=%s", tostring(preset.model_name))
  end
  logger.debug("[ai_engine] get_model_config 最终结果: model_name=%s, base_url=%s", tostring(preset.model_name), tostring(preset.base_url))
  return preset
end

-- ========== 核心生成流程 ==========
function M.generate_response(messages, params)
  http_utils.clear_reasoning_throttle()
  -- 新生成开始时重置停止标志，允许下次按停止键生效
  state._cancel_processed = false
  local session_id = params.session_id; local window_id = params.window_id; local options = params.options or {}
  state.is_generating = true
  local model_index = params.model_index or 1; local ai_preset = get_model_config(model_index)
  logger.debug("[ai_engine] generate_response: ai_preset.model_name=%s, options.model=%s", tostring(ai_preset.model_name), tostring(options.model))
  local generation_id = os.time() .. "_" .. math.random(1000, 9999)
  state.current_generation_id = generation_id
  state.active_generations[generation_id] = {
    start_time = os.time(), messages = messages, session_id = session_id, window_id = window_id,
    options = options, model_index = model_index, ai_preset = ai_preset, retry_count = 0, accumulated_usage = {},
  }

  -- 创建协程上下文，将共享变量写入 shared 表
  -- 后续所有子调用（_send_stream_request、_send_non_stream_request、
  -- tool_cycle、http_utils、stream_processor 等）
  -- 通过 state_manager.get_shared() 直接访问，无需函数参数传递
  local ctx = state_manager.create_context({
    session_id = session_id,
    generation_id = generation_id,
    window_id = window_id,
    model_index = model_index,
    ai_preset = ai_preset,
    options = options,
    messages = messages,
    accumulated_usage = {},
    stop_requested = false,
    user_cancelled = false,
  })

  local formatted = request_handler.format_messages(messages)
  if ai_preset.system_prompt and ai_preset.system_prompt ~= "" then
    local has_system = false
    for _, msg in ipairs(formatted) do if msg.role == "system" then has_system = true; break end end
    if not has_system then table.insert(formatted, 1, { role = "system", content = ai_preset.system_prompt }) end
  end
  local stream_val
  if options.stream ~= nil then
    stream_val = options.stream
  else
    stream_val = (ai_preset.stream ~= false)
  end
  local request = request_handler.build_request({
    messages = formatted,
    options = vim.tbl_extend("force", options, {
      model = ai_preset.model_name or options.model, temperature = ai_preset.temperature or options.temperature,
      max_tokens = ai_preset.max_tokens or options.max_tokens, stream = stream_val,
    }), session_id = session_id, generation_id = generation_id,
  })
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_STARTED,
    data = { generation_id = generation_id, formatted_messages = formatted, request = request, session_id = session_id, window_id = window_id },
  })

  -- 调试：打印 request.stream 值
  -- 在协程上下文中执行请求
  state_manager.with_context(ctx, function()
    if request.stream then
      _send_stream_request(generation_id, request, { session_id = session_id, window_id = window_id, options = options })
    else
      _send_non_stream_request(generation_id, request, { session_id = session_id, window_id = window_id, options = options })
    end
  end)
end

-- ========== 非流式请求 ==========
function _send_non_stream_request(generation_id, request, params)
  http_utils.clear_reasoning_throttle()
  if not state.active_generations then return end
  local generation = state.active_generations[generation_id]
  if not generation then return end
  local shared = state_manager.get_shared() or {}
  local ai_preset = shared.ai_preset or generation.ai_preset or {}
    local response, err = http_utils.send_request({
    request = request, generation_id = generation_id, base_url = ai_preset.base_url, api_key = ai_preset.api_key,
    timeout = ai_preset.timeout, api_type = ai_preset.api_type or "openai", provider_config = ai_preset,
  })
  if err then
    if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then return end
    if generation.retry_count < state.max_retries then
      generation.retry_count = generation.retry_count + 1
      vim.defer_fn(function()
        if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then return end
        _send_non_stream_request(generation_id, request, params)
      end, state.retry_delay_ms)
      return
    end
    M.handle_generation_error(generation_id, err); return
  end
  if response and response.error then
    local err_msg = response.error.message
    if not err_msg then pcall(function() err_msg = json.encode(response.error) end) end
    M.handle_generation_error(generation_id, err_msg or "未知错误"); return
  end
  _handle_ai_response(generation_id, response, params)
end

-- ========== 流式请求 ==========
function _send_stream_request(generation_id, request, params)
  local shared = state_manager.get_shared() or {}
  local session_id = shared.session_id or params.session_id
  local window_id = shared.window_id or params.window_id
  local options = shared.options or params.options or {}
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.STREAM_STARTED,
    data = { generation_id = generation_id, session_id = session_id, window_id = window_id },
  })
  local processor = http_utils.create_stream_processor(generation_id, session_id, window_id, params and params.is_tool_loop)
  if not state.active_generations then state.active_generations = {} end
  local gen = state.active_generations[generation_id]
  if gen then gen._stream_processor = processor; gen._last_request = request end
  local ai_preset = shared.ai_preset or (gen and gen.ai_preset) or {}
  if not ai_preset.base_url or not ai_preset.api_key then
    ai_preset = get_model_config(shared.model_index or (gen and gen.model_index) or 1)
    shared.ai_preset = ai_preset
    if gen then gen.ai_preset = ai_preset end
  end
  if not ai_preset.base_url or not ai_preset.api_key then
    M.handle_generation_error(generation_id, "AI 配置无效：缺少 base_url 或 api_key"); return
  end
  local function retry_or_error(err)
    if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then return end
    local g = state.active_generations[generation_id]
    if g and g.retry_count < state.max_retries then
      g.retry_count = g.retry_count + 1
      vim.defer_fn(function()
        if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then return end
        -- 清除去重缓存，避免重试请求被去重机制拦截
        http_utils.clear_request_dedup(generation_id)
        _send_stream_request(generation_id, request, params)
      end, state.retry_delay_ms)
      return
    end
    M.handle_generation_error(generation_id, err)
  end
  http_utils.send_stream_request({
    request = request, generation_id = generation_id, base_url = ai_preset.base_url, api_key = ai_preset.api_key,
    timeout = ai_preset.timeout, api_type = ai_preset.api_type or "openai", provider_config = ai_preset,
  }, function(data) _handle_stream_chunk(generation_id, data, processor, params) end,
     function() _handle_stream_end(generation_id, processor, params) end,
     function(err) retry_or_error(err) end)
end

-- ========== 流式处理 ==========
function _handle_stream_chunk(generation_id, data, processor, params)
  -- 如果处理器已标记完成（finish_reason 已到达），只处理 usage 数据
  if processor.is_finished then
    local result = http_utils.process_stream_chunk(processor, data)
    if result and result.usage then
      local gen = state.active_generations[generation_id]
      if gen then
        gen.accumulated_usage = result.usage
      end
    end
    return
  end

  -- 处理空闲超时标记（不再提前结束流式接收，仅记录日志）
  if data._idle_timeout then
    local finalized = http_utils.try_finalize_tool_calls(processor)
    if finalized then
      logger.debug("[ai_engine] 空闲超时但工具调用已完整，等待 finish_reason 确认: %d 个工具调用", #finalized)
    else
      logger.debug("[ai_engine] 空闲超时但工具调用不完整，继续等待后续数据")
    end
    return
  end

  local result = http_utils.process_stream_chunk(processor, data)
  if not result then return end
  local shared = state_manager.get_shared() or {}
  local sid = shared.session_id or processor.session_id or (params and params.session_id)
  local wid = shared.window_id or processor.window_id or (params and params.window_id)
  if result.content then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.STREAM_CHUNK,
      data = { generation_id = generation_id, chunk = result.content, session_id = sid, window_id = wid, is_final = false },
    })
  end
  if result.reasoning_content then
    http_utils.push_reasoning_content(generation_id, result.reasoning_content, processor, params)
  end
  if result.tool_calls and #result.tool_calls > 0 then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_CALL_DETECTED,
      data = {
        generation_id = generation_id,
        tool_calls = result.tool_calls,
        tool_calls_delta = result.tool_calls_delta,
        session_id = sid,
        window_id = wid,
      },
    })
  end

  -- ===== 工具调用累积（不提前结束流式接收） =====
  -- AI 可能在一轮中输出多个工具调用，流式接收将持续到 finish_reason 到达
  -- 所有工具调用参数会在 stream_processor 中持续累积拼接
end

function _handle_stream_end(generation_id, processor, params)
  -- 防重入：如果已经处理过结束，跳过
  if processor._stream_end_handled then
    logger.debug("[ai_engine] _handle_stream_end 防重入跳过: generation_id=%s", generation_id)
    -- 补充更新 usage 数据（第二次调用可能包含完整的 token 用量信息）
    if processor.usage and next(processor.usage) then
      local gen = state.active_generations[generation_id]
      if gen then
        gen.accumulated_usage = processor.usage
      end
    end
    return
  end
  processor._stream_end_handled = true
  local full_response = processor.content_buffer or ""
  local reasoning_text = processor.reasoning_buffer or ""
  local usage = processor.usage or {}
  local tool_calls = http_utils.filter_valid_tool_calls(processor.tool_calls or {})
  http_utils.clear_reasoning_throttle()
  local gen = state.active_generations[generation_id]
  if reasoning_text ~= "" and gen then gen.last_reasoning_content = reasoning_text end

  local shared = state_manager.get_shared() or {}
  local sid = shared.session_id or processor.session_id or (params and params.session_id)
  local wid = shared.window_id or processor.window_id or (params and params.window_id)

  local is_tool_loop = params and params.is_tool_loop
  local abnormal, reason = request_handler.detect_abnormal_response(full_response, tool_calls, { is_tool_loop = is_tool_loop })
  if abnormal then
    local gen = state.active_generations[generation_id]
    if gen then
      local retry_count = gen.retry_count or 0
      if is_tool_loop and reason and reason:find("空响应") then
        state.is_generating = false; state.current_generation_id = nil; state.active_generations[generation_id] = nil
        -- 检查是否为子 agent 的空响应，传入 _sub_agent_id 确保正确转发
        local sub_agent_id = params and params._sub_agent_id
        tool_cycle.on_generation_complete({
          generation_id = generation_id,
          tool_calls = {},
          content = full_response,
          reasoning = reasoning_text,
          usage = usage,
          session_id = sid,
          _sub_agent_id = sub_agent_id,
        })
        return
      end
      if request_handler.can_retry(retry_count) then
        local new_retry_count = retry_count + 1; gen.retry_count = new_retry_count
        local delay = request_handler.get_retry_delay(new_retry_count)
        vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_RETRYING, data = { generation_id = generation_id, retry_count = new_retry_count, max_retries = request_handler.get_max_retries(), reason = reason, session_id = sid, window_id = wid } })
        local saved_request = gen._last_request
        if not saved_request and gen.messages and #gen.messages > 0 then
          local formatted = request_handler.format_messages(gen.messages)
          saved_request = request_handler.build_request({ messages = formatted, options = vim.tbl_extend("force", gen.options or {}, { model = (gen.ai_preset and gen.ai_preset.model_name) or (gen.options and gen.options.model), temperature = (gen.ai_preset and gen.ai_preset.temperature) or (gen.options and gen.options.temperature), max_tokens = (gen.ai_preset and gen.ai_preset.max_tokens) or (gen.options and gen.options.max_tokens), stream = true }), session_id = sid, generation_id = generation_id })
          gen._last_request = saved_request
        end
        vim.defer_fn(function()
          if not state.active_generations or not state.active_generations[generation_id] then return end
          if saved_request then
            http_utils.clear_request_dedup(generation_id)
            vim.defer_fn(function()
              if not state.active_generations or not state.active_generations[generation_id] then return end
              _send_stream_request(generation_id, saved_request, params)
            end, 100)
          else
            vim.defer_fn(function()
              local s = state.active_generations[generation_id]
              if not s then return end
              -- 重新构建请求，避免 handle_tool_result 依赖空消息
              local formatted = request_handler.format_messages(s.messages or {})
              local rebuilt_request = request_handler.build_request({
                messages = formatted,
                options = vim.tbl_extend("force", s.options or {}, {
                  model = (s.ai_preset and s.ai_preset.model_name) or (s.options and s.options.model),
                  temperature = (s.ai_preset and s.ai_preset.temperature) or (s.options and s.options.temperature),
                  max_tokens = (s.ai_preset and s.ai_preset.max_tokens) or (s.options and s.options.max_tokens),
                  stream = true,
                }),
                session_id = s.session_id,
                generation_id = generation_id,
              })
              s._last_request = rebuilt_request
              _send_stream_request(generation_id, rebuilt_request, params)
            end, 100)
          end
        end, delay)
        return
      else
        if reason and reason:find("空响应") then M.handle_generation_error(generation_id, "AI 多次返回空响应: " .. tostring(reason)); return end
      end
    end
  end

  local is_tool_loop = params and params.is_tool_loop
  local tools_enabled = true
  local core = require("NeoAI.core")
  local full_config = core.get_config() or {}
  if full_config and full_config.tools and full_config.tools.enabled ~= nil then tools_enabled = full_config.tools.enabled
  elseif full_config and full_config.ai then tools_enabled = full_config.ai.tools_enabled end

  if #tool_calls > 0 and tools_enabled then
    if is_tool_loop then
      -- 调试日志
      require("NeoAI.utils.logger").debug("[DEBUG_DUP] _handle_stream_end: is_tool_loop=true, tool_calls=%d, _tool_loop_processed=%s",
        #tool_calls, tostring(params and params._tool_loop_processed))
      -- 防止 on_generation_complete 内部的同步回调导致重复执行
      if params and params._tool_loop_processed then
        return
      end
      if params then params._tool_loop_processed = true end
      state.is_generating = false; state.current_generation_id = nil
      -- 检测是否为子 agent 的工具调用
      local sub_agent_id = params and params._sub_agent_id
      if sub_agent_id then
        if not shutdown_flag.is_set() then
          tool_cycle.on_generation_complete({
            generation_id = generation_id,
            tool_calls = tool_calls,
            content = full_response,
            reasoning = reasoning_text,
            usage = usage,
            session_id = sid,
            _sub_agent_id = sub_agent_id,
          })
        end
      else
        tool_cycle.on_generation_complete({ generation_id = generation_id, tool_calls = tool_calls, content = full_response, reasoning = reasoning_text, usage = usage, session_id = sid })
      end
      state.active_generations[generation_id] = nil
      return
    end
    local gen = state.active_generations[generation_id]
    local messages = gen and gen.messages or {}; local options = gen and gen.options or {}
    local model_index = gen and gen.model_index or 1; local ai_preset = gen and gen.ai_preset or {}
    -- 首次生成（非工具循环）时，不在此处插入 assistant 消息
    -- on_generation_complete 回调中会统一插入 assistant 消息（带 tool_calls）
    -- 避免重复插入导致消息历史膨胀
    state.is_generating = false; state.current_generation_id = nil
    if state.session_locks then state.session_locks[sid] = nil end
    tool_cycle.start_async_loop({ generation_id = generation_id, tool_calls = tool_calls, content = full_response, reasoning = reasoning_text, session_id = sid, window_id = wid, options = options, messages = messages, model_index = model_index, ai_preset = ai_preset, on_complete = function(success, result)
      if not success then logger.error("Tool loop failed: " .. tostring(result)) end
      state.active_generations[generation_id] = nil; state.is_generating = false; state.current_generation_id = nil
      local ok, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
      if ok and lsp and lsp.flush_deferred_cleanups then lsp.flush_deferred_cleanups() end
    end })
    return
  end

  if is_tool_loop then
    -- 调试日志
    require("NeoAI.utils.logger").debug("[DEBUG_DUP] _handle_stream_end: is_tool_loop=true (no tools), _tool_loop_processed=%s",
      tostring(params and params._tool_loop_processed))
    -- 防止第一个分支（#tool_calls > 0）执行后，同步回调导致再次进入此分支
    if params and params._tool_loop_processed then
      return
    end
    if params then params._tool_loop_processed = true end
    state.is_generating = false; state.current_generation_id = nil
    -- 检测是否为子 agent 的完成事件
    local sub_agent_id = params and params._sub_agent_id
    if sub_agent_id then
      if not shutdown_flag.is_set() then
        tool_cycle.on_generation_complete({
          generation_id = generation_id,
          tool_calls = tool_calls,
          content = full_response,
          reasoning = reasoning_text,
          usage = usage,
          session_id = sid,
          _sub_agent_id = sub_agent_id,
        })
      end
    else
      tool_cycle.on_generation_complete({ generation_id = generation_id, tool_calls = {}, content = full_response, reasoning = reasoning_text, usage = usage, session_id = sid })
    end
    state.active_generations[generation_id] = nil
  else
    state.is_generating = false; state.current_generation_id = nil
    vim.api.nvim_exec_autocmds("User", { pattern = event_constants.STREAM_COMPLETED, data = { generation_id = generation_id, full_response = full_response, reasoning_text = reasoning_text, usage = usage, session_id = sid, window_id = wid } })
    state.active_generations[generation_id] = nil
  end
end

-- ========== 非流式 AI 响应处理 ==========
function _handle_ai_response(generation_id, response, params)
  local shared = state_manager.get_shared() or {}
  local session_id = shared.session_id or params.session_id
  local window_id = shared.window_id or params.window_id
  local options = shared.options or params.options or {}
  local response_content = ""; local reasoning_content = nil; local tool_calls = {}; local usage = {}
  if response.choices and #response.choices > 0 then
    local choice = response.choices[1]
    if choice.message then
      if choice.message.content then response_content = choice.message.content end
      if choice.message.reasoning_content then
        reasoning_content = choice.message.reasoning_content
        vim.api.nvim_exec_autocmds("User", { pattern = event_constants.REASONING_CONTENT, data = { generation_id = generation_id, reasoning_content = reasoning_content, session_id = session_id, window_id = window_id } })
      end
      if choice.message.tool_calls and #choice.message.tool_calls > 0 then
        tool_calls = choice.message.tool_calls
        vim.api.nvim_exec_autocmds("User", { pattern = event_constants.TOOL_CALL_DETECTED, data = { generation_id = generation_id, tool_calls = tool_calls, session_id = session_id, window_id = window_id, reasoning_content = reasoning_content } })
      end
    end
  end
  tool_calls = http_utils.filter_valid_tool_calls(tool_calls)

  local is_tool_loop = params and params.is_tool_loop
  local abnormal, reason = request_handler.detect_abnormal_response(response_content, tool_calls, { is_tool_loop = is_tool_loop })
  if abnormal then
    local generation = state.active_generations[generation_id]
    if generation then
      local retry_count = generation.retry_count or 0
      if request_handler.can_retry(retry_count) then
        local new_retry_count = retry_count + 1; generation.retry_count = new_retry_count
        local delay = request_handler.get_retry_delay(new_retry_count)
        vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_RETRYING, data = { generation_id = generation_id, retry_count = new_retry_count, max_retries = request_handler.get_max_retries(), reason = reason, session_id = session_id, window_id = window_id } })
        vim.defer_fn(function()
          if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then return end
          _send_non_stream_request(generation_id, request, params)
        end, delay)
        return
      else
        if reason and reason:find("空响应") then M.handle_generation_error(generation_id, "AI 多次返回空响应: " .. tostring(reason)); return end
      end
    end
  end

  local tools_enabled = true
  local core = require("NeoAI.core")
  local full_config = core.get_config() or {}
  if full_config and full_config.tools and full_config.tools.enabled ~= nil then tools_enabled = full_config.tools.enabled
  elseif full_config and full_config.ai then tools_enabled = full_config.ai.tools_enabled end
  http_utils.clear_reasoning_throttle()

  local is_tool_loop = params and params.is_tool_loop

  if #tool_calls > 0 and tools_enabled then
    if is_tool_loop then
      -- 防止 on_generation_complete 内部的同步回调导致重复执行
      if params and params._tool_loop_processed then
        return
      end
      if params then params._tool_loop_processed = true end
      state.is_generating = false; state.current_generation_id = nil
      -- 检测是否为子 agent 的工具调用
      local sub_agent_id = params and params._sub_agent_id
      if sub_agent_id then
        if not shutdown_flag.is_set() then
          tool_cycle.on_generation_complete({
            generation_id = generation_id,
            tool_calls = tool_calls,
            content = response_content,
            reasoning = reasoning_content,
            usage = response.usage or {},
            session_id = session_id,
            _sub_agent_id = sub_agent_id,
          })
        end
      else
        tool_cycle.on_generation_complete({ generation_id = generation_id, tool_calls = tool_calls, content = response_content, reasoning = reasoning_content, usage = response.usage or {}, session_id = session_id })
      end
      state.active_generations[generation_id] = nil
      return
    end
    local gen = state.active_generations[generation_id]
    local messages = gen and gen.messages or {}; local model_index = gen and gen.model_index or 1; local ai_preset = gen and gen.ai_preset or {}
    local tc_msg = { role = "assistant", content = response_content or "", tool_calls = tool_calls, timestamp = os.time(), window_id = window_id }
    if reasoning_content and reasoning_content ~= "" then tc_msg.reasoning_content = reasoning_content end
    table.insert(messages, tc_msg)
    state.is_generating = false; state.current_generation_id = nil
    tool_cycle.start_async_loop({ generation_id = generation_id, tool_calls = tool_calls, session_id = session_id, window_id = window_id, options = options, messages = messages, model_index = model_index, ai_preset = ai_preset, on_complete = function(success, result)
      if not success then logger.error("Tool loop failed: " .. tostring(result)) end
      state.active_generations[generation_id] = nil; state.is_generating = false; state.current_generation_id = nil
      local ok, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
      if ok and lsp and lsp.flush_deferred_cleanups then lsp.flush_deferred_cleanups() end
    end })
    return
  end

  if response.usage then usage = response.usage end
  if is_tool_loop then
    -- 防止第一个分支（#tool_calls > 0）执行后，同步回调导致再次进入此分支
    if params and params._tool_loop_processed then
      return
    end
    if params then params._tool_loop_processed = true end
    state.is_generating = false; state.current_generation_id = nil
    -- 检测是否为子 agent 的完成事件
    local sub_agent_id = params and params._sub_agent_id
    if sub_agent_id then
      if not shutdown_flag.is_set() then
        tool_cycle.on_generation_complete({
          generation_id = generation_id,
          tool_calls = tool_calls,
          content = response_content,
          reasoning = reasoning_content,
          usage = usage,
          session_id = session_id,
          _sub_agent_id = sub_agent_id,
        })
      end
    else
      tool_cycle.on_generation_complete({ generation_id = generation_id, tool_calls = {}, content = response_content, reasoning = reasoning_content, usage = usage, session_id = session_id })
    end
    state.active_generations[generation_id] = nil
  else
    _finalize_generation(generation_id, response_content, { session_id = session_id, window_id = window_id, reasoning_text = reasoning_content, usage = usage })
  end
end

-- ========== 完成生成 ==========
function _finalize_generation(generation_id, response_text, params)
  local generation = state.active_generations[generation_id]
  if not generation then return end
  local shared = state_manager.get_shared() or {}
  local current_usage = params.usage or {}
  if current_usage and next(current_usage) then
    local acc = generation.accumulated_usage or {}
    acc.prompt_tokens = (acc.prompt_tokens or 0) + (current_usage.prompt_tokens or current_usage.promptTokens or current_usage.input_tokens or current_usage.inputTokens or 0)
    acc.completion_tokens = (acc.completion_tokens or 0) + (current_usage.completion_tokens or current_usage.completionTokens or current_usage.output_tokens or current_usage.outputTokens or 0)
    acc.total_tokens = (acc.total_tokens or 0) + (current_usage.total_tokens or current_usage.totalTokens or 0)
    if current_usage.completion_tokens_details and type(current_usage.completion_tokens_details) == "table" then
      local rt = current_usage.completion_tokens_details.reasoning_tokens or 0
      if not acc.completion_tokens_details then acc.completion_tokens_details = {} end
      acc.completion_tokens_details.reasoning_tokens = (acc.completion_tokens_details.reasoning_tokens or 0) + rt
    end
    generation.accumulated_usage = acc
    shared.accumulated_usage = acc
  end
  local messages = generation.messages
  local assistant_msg = { role = "assistant", content = response_text or "", timestamp = os.time(), window_id = shared.window_id or params.window_id }
  if params.reasoning_text and params.reasoning_text ~= "" then assistant_msg.reasoning_content = params.reasoning_text end
  table.insert(messages, assistant_msg)
  local final_usage = generation.accumulated_usage
  if not final_usage or not next(final_usage) then final_usage = params.usage or {} end
  vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_COMPLETED, data = { generation_id = generation_id, response = response_text or "", reasoning_text = params.reasoning_text or "", usage = final_usage, session_id = shared.session_id or params.session_id, window_id = shared.window_id or params.window_id, duration = os.time() - generation.start_time } })
  state.active_generations[generation_id] = nil; state.is_generating = false; state.current_generation_id = nil
  if state.session_locks and generation then state.session_locks[generation.session_id] = nil end
  local ok, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
  if ok and lsp and lsp.flush_deferred_cleanups then lsp.flush_deferred_cleanups() end
end

-- ========== 处理工具结果 ==========
function M.handle_tool_result(data)
  -- ===== 子 agent 请求：绕过 state.is_generating 检查 =====
  -- 子 agent 使用独立的 generation_id（格式：sub_agent_<id>_<timestamp>_<random>），
  -- 与主 agent 的 generation_id 不同，因此不会被 state.is_generating 阻塞。
  -- 但子 agent 的 TOOL_RESULT_RECEIVED 事件也会触发此函数，
  -- 需要直接转发给 sub_agent_engine，不经过主 agent 的生成流程。
  if data._sub_agent_id then
    local logger = require("NeoAI.utils.logger")
    logger.info("[sub_agent] handle_tool_result: id=%s, msgs=%d", data._sub_agent_id, #(data.messages or {}))
    local sub_agent_engine = require("NeoAI.core.ai.sub_agent_engine")
    -- 子 agent 的请求直接发起 AI 生成，不经过主 agent 的状态管理
    local sa_session_id = data.session_id
    local sa_window_id = data.window_id
    local sa_messages = data.messages or {}
    local sa_options = data.options or {}
    local sa_model_index = data.model_index or 1
    local sa_ai_preset = data.ai_preset or {}
    local sa_accumulated_usage = data.accumulated_usage or {}
    local sa_last_reasoning = data.last_reasoning
    -- 使用随机后缀确保 generation_id 唯一
    local sa_generation_id = data.generation_id or ("sub_agent_" .. data._sub_agent_id .. "_" .. os.time() .. "_" .. math.random(10000, 99999))

    -- 注意：不检查 tool_cycle.is_stop_requested
    -- 子 agent 使用独立的 generation_id 和独立的工具循环，
    -- 不应该被主 agent 的 stop_requested 状态影响
    -- 退出时跳过子 agent 请求，防止死循环
    if shutdown_flag.is_set() then
      logger.warn("[sub_agent] handle_tool_result: shutdown_flag set for %s", data._sub_agent_id)
      return
    end
    if not sa_messages or #sa_messages == 0 then
      logger.warn("[sub_agent] handle_tool_result: empty messages for %s", data._sub_agent_id)
      return
    end

    -- 构建请求并直接发送
    local formatted = request_handler.format_messages(sa_messages)
    local stream_val = (sa_options.stream ~= nil) and sa_options.stream or (sa_ai_preset.stream ~= false)
    local request = request_handler.build_request({
      messages = formatted,
      options = vim.tbl_extend("force", sa_options, {
        model = sa_ai_preset.model_name or sa_options.model,
        temperature = sa_ai_preset.temperature or sa_options.temperature,
        max_tokens = sa_ai_preset.max_tokens or sa_options.max_tokens,
        stream = stream_val,
      }),
      session_id = sa_session_id,
      generation_id = sa_generation_id,
    })
    -- 子 agent 工具循环中也不发送 max_tokens，避免 AI 输出被截断
    request.max_tokens = nil

    -- 子 agent 请求需要携带工具列表，让 AI 知道有哪些工具可用
    -- 但只携带边界允许的工具（如果设置了 allowed_tools）
    local plan_executor = require("NeoAI.tools.builtin.plan_executor")
    local context = plan_executor.get_sub_agent_context(data._sub_agent_id)
    local allowed_tools = context and context.boundaries and context.boundaries.allowed_tools or nil

    if allowed_tools and #allowed_tools > 0 then
      -- 只保留边界允许的工具
      local all_defs = request_handler.get_tool_definitions() or {}
      local filtered = {}
      for _, def in ipairs(all_defs) do
      local def_name = (def["function"] and def["function"].name) or def.name or ""
        for _, pattern in ipairs(allowed_tools) do
          if def_name:match(pattern) then
            table.insert(filtered, def)
            break
          end
        end
      end
      -- 即使 filtered 为空，也传递空表而非 nil，
      -- 这样 AI 知道没有可用工具，不会尝试调用工具
      request.tools = filtered
    else
      -- 没有边界限制，使用所有可用工具
      request.tools = request_handler.get_tool_definitions() or {}
    end
    request.tool_choice = "auto"

    -- 创建独立的协程上下文（变量隔离）
    local ctx = state_manager.create_context({
      session_id = sa_session_id,
      generation_id = sa_generation_id,
      window_id = sa_window_id,
      sub_agent_id = data._sub_agent_id,
      messages = sa_messages,
      options = sa_options,
      model_index = sa_model_index,
      ai_preset = sa_ai_preset,
      accumulated_usage = sa_accumulated_usage,
      last_reasoning = sa_last_reasoning,
    })

    -- 保存到 active_generations 供流式处理使用
    if not state.active_generations then state.active_generations = {} end
    state.active_generations[sa_generation_id] = {
      start_time = os.time(),
      messages = sa_messages,
      session_id = sa_session_id,
      window_id = sa_window_id,
      options = sa_options,
      model_index = sa_model_index,
      ai_preset = sa_ai_preset,
      retry_count = 0,
      accumulated_usage = sa_accumulated_usage,
      last_reasoning_content = sa_last_reasoning,
      _sub_agent_id = data._sub_agent_id,
    }

    state_manager.with_context(ctx, function()
      if request.stream then
        _send_stream_request(sa_generation_id, request, {
          session_id = sa_session_id,
          window_id = sa_window_id,
          options = sa_options,
          is_tool_loop = true,
          _sub_agent_id = data._sub_agent_id,
        })
      else
        _send_non_stream_request(sa_generation_id, request, {
          session_id = sa_session_id,
          window_id = sa_window_id,
          options = sa_options,
          is_tool_loop = true,
          _sub_agent_id = data._sub_agent_id,
        })
      end
    end)
    return
  end

  local shared = state_manager.get_shared() or {}
  local generation_id = data.generation_id or shared.generation_id
  local session_id = data.session_id or shared.session_id
  local window_id = data.window_id or shared.window_id
  local messages = data.messages or shared.messages or {}
  local options = data.options or shared.options or {}
  local model_index = data.model_index or shared.model_index or 1
  local ai_preset = data.ai_preset or shared.ai_preset or {}
  local accumulated_usage = data.accumulated_usage or shared.accumulated_usage or {}
  local last_reasoning = data.last_reasoning or shared.last_reasoning

  if tool_cycle.is_stop_requested(session_id) then return end
  if not messages or #messages == 0 then logger.warn("handle_tool_result: 消息为空，跳过"); return end

  local cleaned = {}; local seen_ids = {}; local last_assistant_empty = false
  for _, msg in ipairs(messages) do
    if msg.role == "tool" then
      if msg.tool_call_id and seen_ids[msg.tool_call_id] then goto skip end
      if msg.tool_call_id then seen_ids[msg.tool_call_id] = true end
    end
    -- 去重连续重复的 assistant 空消息（content="" 且没有 tool_calls）
    if msg.role == "assistant" and (not msg.content or msg.content == "") and (not msg.tool_calls or #msg.tool_calls == 0) then
      if last_assistant_empty then
        goto skip
      end
      last_assistant_empty = true
    else
      last_assistant_empty = false
    end
    table.insert(cleaned, msg)
    ::skip::
  end
  messages = cleaned

  -- 调试日志：追踪 handle_tool_result 调用
  require("NeoAI.utils.logger").debug("[DEBUG_DUP] handle_tool_result: gen_id=%s, session=%s, is_generating=%s, cur_gen_id=%s, msgs=%d, stack=%s",
    tostring(generation_id),
    tostring(session_id),
    tostring(state.is_generating),
    tostring(state.current_generation_id),
    #messages,
    debug.traceback()
  )

  -- 检查 session 级别的生成锁，避免多会话互相阻塞
  -- 同一个 session 的 generation_id 应该匹配，不同 session 的不应互相影响
  if not state.session_locks then state.session_locks = {} end
  if state.session_locks[session_id] and state.session_locks[session_id] ~= generation_id then
    -- 同一个 session 有正在进行的请求，跳过
    return
  end
  state.session_locks[session_id] = generation_id

  if not state.active_generations then state.active_generations = {} end
  if not generation_id then state.session_locks[session_id] = nil; return end

  -- 更新 shared 表中的数据
  shared.messages = messages
  shared.options = options
  shared.model_index = model_index
  shared.ai_preset = ai_preset
  shared.accumulated_usage = accumulated_usage
  shared.last_reasoning = last_reasoning

  if not state.active_generations[generation_id] then
    state.active_generations[generation_id] = { start_time = os.time(), messages = messages, session_id = session_id, window_id = window_id, options = options, model_index = model_index, ai_preset = ai_preset, retry_count = 0, accumulated_usage = accumulated_usage, last_reasoning_content = last_reasoning }
  else
    local gen = state.active_generations[generation_id]
    if not gen then
      state.active_generations[generation_id] = { start_time = os.time(), messages = messages, session_id = session_id, window_id = window_id, options = options, model_index = model_index, ai_preset = ai_preset, retry_count = 0, accumulated_usage = accumulated_usage, last_reasoning_content = last_reasoning }
    else
      gen.messages = messages; gen.options = options; gen.ai_preset = ai_preset; gen.model_index = model_index; gen.accumulated_usage = accumulated_usage; gen.last_reasoning_content = last_reasoning
    end
  end

  local formatted = request_handler.format_messages(messages)
  local stream_val = (options.stream ~= nil) and options.stream or (ai_preset.stream ~= false)
  local request = request_handler.build_request({ messages = formatted, options = vim.tbl_extend("force", options, { model = ai_preset.model_name or options.model, temperature = ai_preset.temperature or options.temperature, max_tokens = ai_preset.max_tokens or options.max_tokens, stream = stream_val }), session_id = session_id, generation_id = generation_id })
  -- 工具循环中不发送 max_tokens，避免 AI 输出被截断导致 tool_calls arguments 不完整
  request.max_tokens = nil
  -- 清除去重缓存，确保新请求不被去重机制拦截
  -- 工具循环和总结轮次可能复用相同的 generation_id
  http_utils.clear_request_dedup(generation_id)
  vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_STARTED, data = { generation_id = generation_id, formatted_messages = formatted, request = request, session_id = session_id, window_id = window_id, is_tool_loop = true } })
  if request.stream then
    _send_stream_request(generation_id, request, { session_id = session_id, window_id = window_id, options = options, is_tool_loop = true })
  else
    _send_non_stream_request(generation_id, request, { session_id = session_id, window_id = window_id, options = options, is_tool_loop = true })
  end
end

-- ========== 流式完成 / 错误处理 ==========
function M.handle_stream_completed(data)
  local generation_id = data.generation_id
  if not state.active_generations[generation_id] then return end
  local shared = state_manager.get_shared() or {}
  _finalize_generation(generation_id, data.full_response, {
    session_id = shared.session_id or data.session_id,
    window_id = shared.window_id or data.window_id,
    reasoning_text = data.reasoning_text,
    usage = data.usage or {},
  })
end

function M.handle_generation_error(generation_id, error_msg)
  local generation = state.active_generations[generation_id]
  if not generation then return end
  local shared = state_manager.get_shared() or {}
  vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_ERROR, data = { generation_id = generation_id, error_msg = error_msg, session_id = shared.session_id or generation.session_id, window_id = shared.window_id or generation.window_id } })

  -- 检测是否为子 agent 的生成错误，通知 tool_cycle 结束
  local sub_agent_id = generation._sub_agent_id
  if sub_agent_id then
    local tool_cycle = require("NeoAI.core.ai.tool_cycle")
    tool_cycle.on_generation_complete({
      generation_id = generation_id,
      tool_calls = {},
      content = "[AI 生成错误] " .. error_msg,
      reasoning = "",
      usage = {},
      session_id = generation.session_id,
      _sub_agent_id = sub_agent_id,
    })
  end

  state.active_generations[generation_id] = nil; state.is_generating = false; state.current_generation_id = nil
  local hm_ok, hm = pcall(require, "NeoAI.core.history.manager")
  if hm_ok and hm and hm._save then hm._save() end
  local ok_lsp, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
  if ok_lsp and lsp and lsp.flush_deferred_cleanups then lsp.flush_deferred_cleanups() end
end

-- ========== 取消生成 ==========
function M.cancel_generation()
  -- 幂等性保护：如果已经处理过停止请求，不再重复执行
  -- 防止多次按停止键时重复触发 GENERATION_CANCELLED 事件、重复显示通知和追加用量行
  if state._cancel_processed then
    return
  end
  state._cancel_processed = true

  http_utils.clear_reasoning_throttle()
  local generation_id = state.current_generation_id; local generation = state.active_generations[generation_id]
  -- 写入 shared 表，供协程内其他模块读取
  local shared = state_manager.get_shared() or {}
  shared.stop_requested = true
  shared.user_cancelled = true

  if generation and generation.session_id then
    local ss = tool_cycle.get_session_state and tool_cycle.get_session_state(generation.session_id)
    if ss then ss.stop_requested = true; ss.user_cancelled = true; ss.active_tool_calls = {} end
  else
    local all_sessions = tool_cycle.get_all_session_ids and tool_cycle.get_all_session_ids()
    if all_sessions then
      for _, sid in ipairs(all_sessions) do
        local ss = tool_cycle.get_session_state(sid)
        if ss then ss.stop_requested = true; ss.user_cancelled = true; ss.active_tool_calls = {} end
      end
    end
  end
  http_utils.cancel_all_requests()
  if generation then
    local acc = generation.accumulated_usage or {}
    vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_CANCELLED, data = { generation_id = generation_id, session_id = shared.session_id or generation.session_id, window_id = shared.window_id or generation.window_id, usage = acc } })
    if generation_id then state.active_generations[generation_id] = nil end
  else
    vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_CANCELLED, data = { generation_id = nil, session_id = nil, window_id = nil } })
  end
  local has_active_loop = tool_cycle.is_executing()
  if state.is_generating or has_active_loop then vim.notify("[NeoAI] 已停止生成", vim.log.levels.INFO) end
  state.is_generating = false; state.current_generation_id = nil
  local hm_ok, hm = pcall(require, "NeoAI.core.history.manager")
  if hm_ok and hm and hm._save then hm._save() end
  local ok_lsp, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
  if ok_lsp and lsp and lsp.flush_deferred_cleanups then lsp.flush_deferred_cleanups() end
end

-- ========== 工具管理 ==========
--- 设置可用工具列表
--- 注册工具到 tool_registry，同步到 tool_cycle 和 request_handler
function M.set_tools(tools)
  local tools_map = tools or {}
  local tool_defs = {}
  local tool_registry = require("NeoAI.tools.tool_registry")
  for name, def in pairs(tools_map) do
    if def.func then
      if not tool_registry.exists(name) then
        pcall(tool_registry.register, { name = name, func = def.func, description = def.description or ("执行 " .. name .. " 操作"), parameters = def.parameters, category = def.category or "ai" })
      end
      local tf = { name = name, description = def.description or ("执行 " .. name .. " 操作") }
      local params = def.parameters
      if params and type(params) == "table" then
        local has_props = false
        if params.properties then for _,_ in pairs(params.properties) do has_props = true; break end end
        if has_props then
          local cp = { type = params.type or "object", properties = params.properties }
          if params.required and type(params.required) == "table" and #params.required > 0 then cp.required = params.required end
          tf.parameters = cp
        end
      end
      table.insert(tool_defs, { type = "function", ["function"] = tf })
    end
  end
  -- 同步到 tool_cycle 和 request_handler
  local to = require("NeoAI.core.ai.tool_cycle")
  to.set_tools(tools_map)
  request_handler.set_tool_definitions(tool_defs)
end

-- ========== 公共接口 ==========
function M.process_query(query, options)
  if not state.initialized then error("AI engine not initialized") end
  request_handler.reset_first_request()
  tool_cycle.reset_iteration()
  local messages = { { role = "user", content = query } }
  vim.api.nvim_exec_autocmds("User", { pattern = event_constants.USER_MESSAGE_SENT, data = { message = messages[1], session_id = options and options.session_id, timestamp = os.time() } })
  return M.generate_response(messages, { options = options })
end

function M.get_status()
  local tc_tools = tool_cycle.get_tools() or {}
  return { initialized = state.initialized, is_generating = state.is_generating, current_generation_id = state.current_generation_id, active_generations_count = vim.tbl_count(state.active_generations), tools_available = next(tc_tools) ~= nil, tool_cycle = { current_iteration = tool_cycle.get_current_iteration() }, http_utils = http_utils.get_state(), submodules = { ai_engine = true, http_utils = true, tool_cycle = true, request_handler = true } }
end

function M.cleanup_event_listeners()
  for _, id in pairs(state.event_listeners) do if id then pcall(vim.api.nvim_del_autocmd, id) end end
  state.event_listeners = {}
end

--- 清理所有活跃的生成状态（退出时使用，防止回调死循环）
function M.cleanup_all_generations()
  state.is_generating = false
  state.current_generation_id = nil
  state.active_generations = {}
end

function M.shutdown()
  if not state.initialized then return end
  http_utils.clear_reasoning_throttle()
  if state.is_generating then M.cancel_generation() end
  http_utils.shutdown(); M.cleanup_event_listeners()
  state.active_generations = {}; state.initialized = false; state.is_generating = false; state.current_generation_id = nil
end

return M
