-- AI 引擎（精简版）
-- 职责：AI 生成流程编排、事件调度、工具管理
-- 请求构建委托给 request_builder
-- 流式处理委托给 stream_processor
-- 重试逻辑委托给 response_retry
-- 工具循环委托给 tool_orchestrator
-- HTTP 请求委托给 http_client

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local json = require("NeoAI.utils.json")
local config_merger = require("NeoAI.core.config.merger")
local shutdown_flag = require("NeoAI.core.shutdown_flag")
local state_manager = require("NeoAI.core.config.state")

-- 子模块
local http_client = require("NeoAI.core.ai.http_client")
local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
local response_retry = require("NeoAI.core.ai.response_retry")
local request_builder = require("NeoAI.core.ai.request_builder")
local stream_processor = require("NeoAI.core.ai.stream_processor")

-- ========== 闭包内私有状态 ==========
local _tools = {}           -- tools 映射表
local _tool_definitions = {} -- tool 定义列表
local state = {
  initialized = false,
  is_generating = false,
  current_generation_id = nil,
  event_listeners = {},
  max_retries = 3,
  retry_delay_ms = 1000,
  active_generations = {},
}

-- ========== 初始化 ==========
local M = {}

function M.initialize(options)
  if state.initialized then return M end

  http_client.initialize({ config = {} })
  local full_config = (options or {}).config or {}
  tool_orchestrator.initialize({ config = full_config })
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
  if not result.stream then result.stream = ai_config.stream end
  if not result.timeout then result.timeout = ai_config.timeout end
  if not result.system_prompt then result.system_prompt = ai_config.system_prompt end
  return result
end

local function get_model_config(model_index)
  model_index = model_index or 1
  local preset = {}
  -- 优先使用 get_available_models（与 UI 模型选择器使用的列表一致）
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
  if not preset.base_url or not preset.api_key then
    -- 回退到场景候选
    if config_merger and config_merger.get_scenario_candidates then
      local candidates = config_merger.get_scenario_candidates("chat")
      local target = candidates[model_index]
      if target then
        preset = vim.deepcopy(target); preset.model = preset.model_name
        logger.debug("[ai_engine] get_model_config: 回退到场景候选 model_name=%s", tostring(preset.model_name))
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
  stream_processor.clear_reasoning_throttle()
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
  -- tool_orchestrator、http_client、stream_processor 等）
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

  local formatted = request_builder.format_messages(messages)
  if ai_preset.system_prompt and ai_preset.system_prompt ~= "" then
    local has_system = false
    for _, msg in ipairs(formatted) do if msg.role == "system" then has_system = true; break end end
    if not has_system then table.insert(formatted, 1, { role = "system", content = ai_preset.system_prompt }) end
  end
  local stream_val = (options.stream ~= nil) and options.stream or (ai_preset.stream ~= false)
  local request = request_builder.build_request({
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
  stream_processor.clear_reasoning_throttle()
  if not state.active_generations then return end
  local generation = state.active_generations[generation_id]
  if not generation then return end
  local shared = state_manager.get_shared()
  local ai_preset = shared.ai_preset or generation.ai_preset or {}
  local response, err = http_client.send_request({
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
  local shared = state_manager.get_shared()
  local session_id = shared.session_id or params.session_id
  local window_id = shared.window_id or params.window_id
  local options = shared.options or params.options or {}
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.STREAM_STARTED,
    data = { generation_id = generation_id, session_id = session_id, window_id = window_id },
  })
  local processor = stream_processor.create_processor(generation_id, session_id, window_id)
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
        _send_stream_request(generation_id, request, params)
      end, state.retry_delay_ms)
      return
    end
    M.handle_generation_error(generation_id, err)
  end
  http_client.send_stream_request({
    request = request, generation_id = generation_id, base_url = ai_preset.base_url, api_key = ai_preset.api_key,
    timeout = ai_preset.timeout, api_type = ai_preset.api_type or "openai", provider_config = ai_preset,
  }, function(data) _handle_stream_chunk(generation_id, data, processor, params) end,
     function() _handle_stream_end(generation_id, processor, params) end,
     function(err) retry_or_error(err) end)
end

-- ========== 流式处理 ==========
function _handle_stream_chunk(generation_id, data, processor, params)
  local result = stream_processor.process_chunk(processor, data)
  if not result then return end
  local shared = state_manager.get_shared()
  local sid = shared.session_id or processor.session_id
  local wid = shared.window_id or processor.window_id
  if result.content then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.STREAM_CHUNK,
      data = { generation_id = generation_id, chunk = result.content, session_id = sid, window_id = wid, is_final = false },
    })
  end
  if result.reasoning_content then
    stream_processor.push_reasoning_content(generation_id, result.reasoning_content, processor, params)
  end
  if result.tool_calls and #result.tool_calls > 0 then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_CALL_DETECTED,
      data = { generation_id = generation_id, tool_calls = result.tool_calls, session_id = sid, window_id = wid },
    })
  end
end

function _handle_stream_end(generation_id, processor, params)
  local full_response = processor.content_buffer or ""
  local reasoning_text = processor.reasoning_buffer or ""
  local usage = processor.usage or {}
  local tool_calls = stream_processor.filter_valid_tool_calls(processor.tool_calls or {})
  stream_processor.clear_reasoning_throttle()
  local gen = state.active_generations[generation_id]
  if reasoning_text ~= "" and gen then gen.last_reasoning_content = reasoning_text end

  local shared = state_manager.get_shared()
  local sid = shared.session_id or processor.session_id
  local wid = shared.window_id or processor.window_id

  local is_tool_loop = params and params.is_tool_loop
  local is_final_round = params and params.is_final_round
  local abnormal, reason = response_retry.detect_abnormal_response(full_response, tool_calls, { is_tool_loop = is_tool_loop, is_final_round = is_final_round })
  if abnormal then
    local gen = state.active_generations[generation_id]
    if gen then
      local retry_count = gen.retry_count or 0
      if is_tool_loop and reason and reason:find("空响应") then
        state.is_generating = false; state.current_generation_id = nil; state.active_generations[generation_id] = nil
        tool_orchestrator.on_generation_complete({ generation_id = generation_id, tool_calls = {}, content = full_response, reasoning = reasoning_text, usage = usage, session_id = sid, is_final_round = true })
        return
      end
      if response_retry.can_retry(retry_count) then
        local new_retry_count = retry_count + 1; gen.retry_count = new_retry_count
        local delay = response_retry.get_retry_delay(new_retry_count)
        vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_RETRYING, data = { generation_id = generation_id, retry_count = new_retry_count, max_retries = response_retry.get_max_retries(), reason = reason, session_id = sid, window_id = wid } })
        local saved_request = gen._last_request
        if not saved_request and gen.messages and #gen.messages > 0 then
          local formatted = request_builder.format_messages(gen.messages)
          saved_request = request_builder.build_request({ messages = formatted, options = vim.tbl_extend("force", gen.options or {}, { model = (gen.ai_preset and gen.ai_preset.model_name) or (gen.options and gen.options.model), temperature = (gen.ai_preset and gen.ai_preset.temperature) or (gen.options and gen.options.temperature), max_tokens = (gen.ai_preset and gen.ai_preset.max_tokens) or (gen.options and gen.options.max_tokens), stream = true }), session_id = sid, generation_id = generation_id })
          gen._last_request = saved_request
        end
        vim.defer_fn(function()
          if not state.active_generations or not state.active_generations[generation_id] then return end
          if saved_request then
            http_client.clear_request_dedup(generation_id)
            vim.defer_fn(function()
              if not state.active_generations or not state.active_generations[generation_id] then return end
              _send_stream_request(generation_id, saved_request, params)
            end, 100)
          else
            vim.defer_fn(function()
              local s = state.active_generations[generation_id]
              if not s then return end
              -- 重新构建请求，避免 handle_tool_result 依赖空消息
              local formatted = request_builder.format_messages(s.messages or {})
              local rebuilt_request = request_builder.build_request({
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
        if is_final_round then M.handle_generation_error(generation_id, "总结轮次重试耗尽: " .. tostring(reason)); return end
        if reason and reason:find("空响应") then M.handle_generation_error(generation_id, "AI 多次返回空响应: " .. tostring(reason)); return end
      end
    end
  end

  local is_tool_loop = params and params.is_tool_loop
  local is_final_round = params and params.is_final_round
  local tools_enabled = true
  local core = require("NeoAI.core")
  local full_config = core.get_config() or {}
  if full_config and full_config.tools and full_config.tools.enabled ~= nil then tools_enabled = full_config.tools.enabled
  elseif full_config and full_config.ai then tools_enabled = full_config.ai.tools_enabled end

  if #tool_calls > 0 and tools_enabled then
    if is_tool_loop then
      state.is_generating = false; state.current_generation_id = nil
      tool_orchestrator.on_generation_complete({ generation_id = generation_id, tool_calls = tool_calls, content = full_response, reasoning = reasoning_text, usage = usage, session_id = sid, is_final_round = is_final_round or false })
      state.active_generations[generation_id] = nil
      return
    end
    local gen = state.active_generations[generation_id]
    local messages = gen and gen.messages or {}; local options = gen and gen.options or {}
    local model_index = gen and gen.model_index or 1; local ai_preset = gen and gen.ai_preset or {}
    local tc_msg = { role = "assistant", content = full_response or "", tool_calls = tool_calls, timestamp = os.time(), window_id = wid }
    if reasoning_text and reasoning_text ~= "" then tc_msg.reasoning_content = reasoning_text end
    table.insert(messages, tc_msg)
    state.is_generating = false; state.current_generation_id = nil
    tool_orchestrator.start_async_loop({ generation_id = generation_id, tool_calls = tool_calls, session_id = sid, window_id = wid, options = options, messages = messages, model_index = model_index, ai_preset = ai_preset, on_complete = function(success, result)
      if not success then logger.error("Tool loop failed: " .. tostring(result)) end
      state.active_generations[generation_id] = nil; state.is_generating = false; state.current_generation_id = nil
      local ok, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
      if ok and lsp and lsp.flush_deferred_cleanups then lsp.flush_deferred_cleanups() end
    end })
    return
  end

  if is_tool_loop then
    state.is_generating = false; state.current_generation_id = nil
    tool_orchestrator.on_generation_complete({ generation_id = generation_id, tool_calls = {}, content = full_response, reasoning = reasoning_text, usage = usage, session_id = sid, is_final_round = is_final_round or false })
    state.active_generations[generation_id] = nil
  else
    state.is_generating = false; state.current_generation_id = nil
    vim.api.nvim_exec_autocmds("User", { pattern = event_constants.STREAM_COMPLETED, data = { generation_id = generation_id, full_response = full_response, reasoning_text = reasoning_text, usage = usage, session_id = sid, window_id = wid } })
    state.active_generations[generation_id] = nil
  end
end

-- ========== 非流式 AI 响应处理 ==========
function _handle_ai_response(generation_id, response, params)
  local shared = state_manager.get_shared()
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
  tool_calls = stream_processor.filter_valid_tool_calls(tool_calls)

  local is_tool_loop = params and params.is_tool_loop; local is_final_round = params and params.is_final_round
  local abnormal, reason = response_retry.detect_abnormal_response(response_content, tool_calls, { is_tool_loop = is_tool_loop, is_final_round = is_final_round })
  if abnormal then
    local generation = state.active_generations[generation_id]
    if generation then
      local retry_count = generation.retry_count or 0
      if response_retry.can_retry(retry_count) then
        local new_retry_count = retry_count + 1; generation.retry_count = new_retry_count
        local delay = response_retry.get_retry_delay(new_retry_count)
        vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_RETRYING, data = { generation_id = generation_id, retry_count = new_retry_count, max_retries = response_retry.get_max_retries(), reason = reason, session_id = session_id, window_id = window_id } })
        vim.defer_fn(function()
          if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then return end
          _send_non_stream_request(generation_id, request, params)
        end, delay)
        return
      else
        if is_final_round then M.handle_generation_error(generation_id, "总结轮次重试耗尽: " .. tostring(reason)); return end
        if reason and reason:find("空响应") then M.handle_generation_error(generation_id, "AI 多次返回空响应: " .. tostring(reason)); return end
      end
    end
  end

  local tools_enabled = true
  local core = require("NeoAI.core")
  local full_config = core.get_config() or {}
  if full_config and full_config.tools and full_config.tools.enabled ~= nil then tools_enabled = full_config.tools.enabled
  elseif full_config and full_config.ai then tools_enabled = full_config.ai.tools_enabled end
  stream_processor.clear_reasoning_throttle()

  local is_tool_loop = params and params.is_tool_loop; local is_final_round = params and params.is_final_round

  if #tool_calls > 0 and tools_enabled then
    if is_tool_loop then
      state.is_generating = false; state.current_generation_id = nil
      tool_orchestrator.on_generation_complete({ generation_id = generation_id, tool_calls = tool_calls, content = response_content, reasoning = reasoning_content, usage = response.usage or {}, session_id = session_id, is_final_round = is_final_round or false })
      state.active_generations[generation_id] = nil
      return
    end
    local gen = state.active_generations[generation_id]
    local messages = gen and gen.messages or {}; local model_index = gen and gen.model_index or 1; local ai_preset = gen and gen.ai_preset or {}
    local tc_msg = { role = "assistant", content = response_content or "", tool_calls = tool_calls, timestamp = os.time(), window_id = window_id }
    if reasoning_content and reasoning_content ~= "" then tc_msg.reasoning_content = reasoning_content end
    table.insert(messages, tc_msg)
    state.is_generating = false; state.current_generation_id = nil
    tool_orchestrator.start_async_loop({ generation_id = generation_id, tool_calls = tool_calls, session_id = session_id, window_id = window_id, options = options, messages = messages, model_index = model_index, ai_preset = ai_preset, on_complete = function(success, result)
      if not success then logger.error("Tool loop failed: " .. tostring(result)) end
      state.active_generations[generation_id] = nil; state.is_generating = false; state.current_generation_id = nil
      local ok, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
      if ok and lsp and lsp.flush_deferred_cleanups then lsp.flush_deferred_cleanups() end
    end })
    return
  end

  if response.usage then usage = response.usage end
  if is_tool_loop then
    state.is_generating = false; state.current_generation_id = nil
    tool_orchestrator.on_generation_complete({ generation_id = generation_id, tool_calls = {}, content = response_content, reasoning = reasoning_content, usage = usage, session_id = session_id, is_final_round = is_final_round or false })
    state.active_generations[generation_id] = nil
  else
    _finalize_generation(generation_id, response_content, { session_id = session_id, window_id = window_id, reasoning_text = reasoning_content, usage = usage })
  end
end

-- ========== 完成生成 ==========
function _finalize_generation(generation_id, response_text, params)
  local generation = state.active_generations[generation_id]
  if not generation then return end
  local shared = state_manager.get_shared()
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
  local ok, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
  if ok and lsp and lsp.flush_deferred_cleanups then lsp.flush_deferred_cleanups() end
end

-- ========== 处理工具结果 ==========
function M.handle_tool_result(data)
  local shared = state_manager.get_shared()
  local generation_id = data.generation_id or shared.generation_id
  local session_id = data.session_id or shared.session_id
  local window_id = data.window_id or shared.window_id
  local messages = data.messages or shared.messages or {}
  local options = data.options or shared.options or {}
  local model_index = data.model_index or shared.model_index or 1
  local ai_preset = data.ai_preset or shared.ai_preset or {}
  local is_final_round = data.is_final_round or false
  local accumulated_usage = data.accumulated_usage or shared.accumulated_usage or {}
  local last_reasoning = data.last_reasoning or shared.last_reasoning

  if tool_orchestrator.is_stop_requested(session_id) then return end
  if not messages or #messages == 0 then logger.warn("handle_tool_result: 消息为空，跳过"); return end

  local cleaned = {}; local seen_ids = {}
  for _, msg in ipairs(messages) do
    if msg.role == "tool" then
      if msg.tool_call_id and seen_ids[msg.tool_call_id] then goto skip end
      if msg.tool_call_id then seen_ids[msg.tool_call_id] = true end
    end
    table.insert(cleaned, msg)
    ::skip::
  end
  messages = cleaned

  if is_final_round and #messages > 0 then
    -- 修复：当 is_final_round=true 时，如果最后一条消息是 tool 类型，
    -- 且倒数第二条是带 tool_calls 的 assistant 消息，
    -- 需要同时移除 assistant 消息（因为它的 tool_calls 没有对应的 tool 响应了）
    -- 否则 API 会报错："An assistant message with 'tool_calls' must be followed by tool messages"
    local last_msg = messages[#messages]
    if last_msg.role == "tool" then
      if #messages >= 2 then
        local prev_msg = messages[#messages - 1]
        if prev_msg.role == "assistant" and prev_msg.tool_calls then
          -- 同时移除 assistant 消息和 tool 消息
          table.remove(messages) -- 移除 tool 消息
          table.remove(messages) -- 移除 assistant 消息
        else
          table.remove(messages) -- 只移除 tool 消息
        end
      else
        table.remove(messages) -- 只有一条 tool 消息，直接移除
      end
    elseif last_msg.role == "assistant" and last_msg.tool_calls then
      -- 如果最后一条消息是带 tool_calls 的 assistant 消息（没有对应的 tool 响应），
      -- 也需要移除，避免 API 报错
      table.remove(messages)
    end
  end

  if state.is_generating and state.current_generation_id ~= generation_id then return end
  if state.is_generating and state.current_generation_id == generation_id then return end
  if is_final_round and state.is_generating then state.is_generating = false; state.current_generation_id = nil end

  state.is_generating = true; state.current_generation_id = generation_id
  if not state.active_generations then state.active_generations = {} end
  if not generation_id then state.is_generating = false; state.current_generation_id = nil; return end

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

  local formatted = request_builder.format_messages(messages)
  local stream_val = (options.stream ~= nil) and options.stream or (ai_preset.stream ~= false)
  local request = request_builder.build_request({ messages = formatted, options = vim.tbl_extend("force", options, { model = ai_preset.model_name or options.model, temperature = ai_preset.temperature or options.temperature, max_tokens = ai_preset.max_tokens or options.max_tokens, stream = stream_val }), session_id = session_id, generation_id = generation_id })
  if is_final_round then request.tools = nil; request.tool_choice = nil end
  vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_STARTED, data = { generation_id = generation_id, formatted_messages = formatted, request = request, session_id = session_id, window_id = window_id, is_tool_loop = true, is_final_round = is_final_round } })
  if request.stream then
    _send_stream_request(generation_id, request, { session_id = session_id, window_id = window_id, options = options, is_tool_loop = true, is_final_round = is_final_round })
  else
    _send_non_stream_request(generation_id, request, { session_id = session_id, window_id = window_id, options = options, is_tool_loop = true, is_final_round = is_final_round })
  end
end

-- ========== 流式完成 / 错误处理 ==========
function M.handle_stream_completed(data)
  local generation_id = data.generation_id
  if not state.active_generations[generation_id] then return end
  local shared = state_manager.get_shared()
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
  local shared = state_manager.get_shared()
  vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_ERROR, data = { generation_id = generation_id, error_msg = error_msg, session_id = shared.session_id or generation.session_id, window_id = shared.window_id or generation.window_id } })
  state.active_generations[generation_id] = nil; state.is_generating = false; state.current_generation_id = nil
  local hm_ok, hm = pcall(require, "NeoAI.core.history.manager")
  if hm_ok and hm and hm._save then hm._save() end
  local ok_lsp, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
  if ok_lsp and lsp and lsp.flush_deferred_cleanups then lsp.flush_deferred_cleanups() end
end

-- ========== 取消生成 ==========
function M.cancel_generation()
  stream_processor.clear_reasoning_throttle()
  local generation_id = state.current_generation_id; local generation = state.active_generations[generation_id]
  -- 写入 shared 表，供协程内其他模块读取
  local shared = state_manager.get_shared()
  shared.stop_requested = true
  shared.user_cancelled = true

  if generation and generation.session_id then
    local ss = tool_orchestrator.get_session_state and tool_orchestrator.get_session_state(generation.session_id)
    if ss then ss.stop_requested = true; ss.user_cancelled = true; ss.active_tool_calls = {} end
  else
    local all_sessions = tool_orchestrator.get_all_session_ids and tool_orchestrator.get_all_session_ids()
    if all_sessions then
      for _, sid in ipairs(all_sessions) do
        local ss = tool_orchestrator.get_session_state(sid)
        if ss then ss.stop_requested = true; ss.user_cancelled = true; ss.active_tool_calls = {} end
      end
    end
  end
  http_client.cancel_all_requests()
  if generation then
    local acc = generation.accumulated_usage or {}
    vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_CANCELLED, data = { generation_id = generation_id, session_id = shared.session_id or generation.session_id, window_id = shared.window_id or generation.window_id, usage = acc } })
    if generation_id then state.active_generations[generation_id] = nil end
  else
    vim.api.nvim_exec_autocmds("User", { pattern = event_constants.GENERATION_CANCELLED, data = { generation_id = nil, session_id = nil, window_id = nil } })
  end
  local has_active_loop = tool_orchestrator.is_executing()
  if state.is_generating or has_active_loop then vim.notify("[NeoAI] 已停止生成", vim.log.levels.INFO) end
  state.is_generating = false; state.current_generation_id = nil
  local hm_ok, hm = pcall(require, "NeoAI.core.history.manager")
  if hm_ok and hm and hm._save then hm._save() end
  local ok_lsp, lsp = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
  if ok_lsp and lsp and lsp.flush_deferred_cleanups then lsp.flush_deferred_cleanups() end
end

-- ========== 工具管理 ==========
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
  _tools = tools_map
  _tool_definitions = tool_defs
  -- 同步到 tool_orchestrator
  local to = require("NeoAI.core.ai.tool_orchestrator")
  to.set_tools(tools_map)
  request_builder.set_tool_definitions(tool_defs)
end

-- ========== 公共接口 ==========
function M.process_query(query, options)
  if not state.initialized then error("AI engine not initialized") end
  request_builder.reset_first_request()
  tool_orchestrator.reset_iteration()
  local messages = { { role = "user", content = query } }
  vim.api.nvim_exec_autocmds("User", { pattern = event_constants.USER_MESSAGE_SENT, data = { message = messages[1], session_id = options and options.session_id, timestamp = os.time() } })
  return M.generate_response(messages, { options = options })
end

function M.get_status()
  local tools = _tools or {}
  return { initialized = state.initialized, is_generating = state.is_generating, current_generation_id = state.current_generation_id, active_generations_count = vim.tbl_count(state.active_generations), tools_available = next(tools) ~= nil, tool_orchestrator = { current_iteration = tool_orchestrator.get_current_iteration() }, http_client = http_client.get_state(), submodules = { ai_engine = true, http_client = true, tool_orchestrator = true, request_builder = true, stream_processor = true } }
end

function M.cleanup_event_listeners()
  for _, id in pairs(state.event_listeners) do if id then pcall(vim.api.nvim_del_autocmd, id) end end
  state.event_listeners = {}
end

function M.shutdown()
  if not state.initialized then return end
  stream_processor.clear_reasoning_throttle()
  if state.is_generating then M.cancel_generation() end
  http_client.shutdown(); M.cleanup_event_listeners()
  state.active_generations = {}; state.initialized = false; state.is_generating = false; state.current_generation_id = nil
end

-- ========== 自动命名会话 ==========
function M.auto_name_session(session_id, user_msg, callback)
  if not state.initialized then if callback then callback(false, "AI engine not initialized") end; return end
  if not user_msg or user_msg == "" then if callback then callback(false, "无用户消息") end; return end
  local naming_text = user_msg:sub(1, 200)
  vim.schedule(function()
    local preset = resolve_scenario_config("naming")
    if not preset or not preset.base_url or not preset.api_key then preset = resolve_scenario_config("chat") end
    if not preset or not preset.base_url or not preset.api_key then if callback then callback(false, "未配置 AI 提供商") end; return end
    local response, err = http_client.send_request({ request = { model = preset.model_name or preset.model or "", messages = { { role = "system", content = "你是一个会话命名助手。根据用户的第一条消息，生成一个简短（不超过20个字符）且有意义的会话名称。只返回名称本身，不要加引号、标点或解释。" }, { role = "user", content = "请为以下对话生成一个简短的名称：" .. naming_text } }, temperature = 0.3, max_tokens = 50, stream = false }, generation_id = "naming_" .. session_id .. "_" .. os.time(), base_url = preset.base_url, api_key = preset.api_key, timeout = preset.timeout or 10000, api_type = preset.api_type or "openai", provider_config = preset })
    if err then if callback then callback(false, "命名请求失败: " .. tostring(err)) end; return end
    if not response or not response.choices or #response.choices == 0 then if callback then callback(false, "命名响应无效") end; return end
    local msg = response.choices[1].message; local name = msg.content or ""
    if name == "" and msg.reasoning_content then name = msg.reasoning_content end
    name = name:gsub("^[%s\"'「『]+(.-)[%s\"'」』]+$", "%1"):gsub("^%s*(.-)%s*$", "%1"):gsub("[。，！？、；：]$", "")
    if #name > 30 then name = name:sub(1, 30) .. "…" end
    if name == "" then if callback then callback(false, "生成的名称无效") end; return end
    if callback then callback(true, name) end
  end)
end

-- ========== 兼容接口 ==========
function M.build_request(params) return request_builder.build_request(params) end
function M.format_messages(msgs) return request_builder.format_messages(msgs) end
function M.build_tool_result_message(id, r, n) return request_builder.build_tool_result_message(id, r, n) end
function M.add_tool_call_to_history(msgs, tc, tr) return request_builder.add_tool_call_to_history(msgs, tc, tr) end
function M.reset_first_request() request_builder.reset_first_request() end
function M.estimate_tokens(text) return request_builder.estimate_tokens(text) end
function M.estimate_message_tokens(messages) return request_builder.estimate_message_tokens(messages) end
function M.estimate_request_tokens(request) return request_builder.estimate_request_tokens(request) end

-- 工具编排器接口转发
function M.start_async_loop(params) return tool_orchestrator.start_async_loop(params) end
function M.on_generation_complete(data) return tool_orchestrator.on_generation_complete(data) end
function M.get_current_iteration(session_id) return tool_orchestrator.get_current_iteration(session_id) end
function M.get_tools() return _tools or {} end
function M.is_executing(session_id) return tool_orchestrator.is_executing(session_id) end
function M.get_loop_status() return "deprecated" end
function M.is_reasoning_active() return false end

return M
