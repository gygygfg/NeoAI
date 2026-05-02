-- AI 引擎（精简版）
-- 合并原 ai_engine + request_builder + stream_processor + reasoning_manager + response_builder
local M = {}

local logger = require("NeoAI.utils.logger")
local event_constants = require("NeoAI.core.events")
local json = require("NeoAI.utils.json")
local config_merger = require("NeoAI.core.config.merger")
local state_manager = require("NeoAI.core.config.state")
local shutdown_flag = require("NeoAI.core.shutdown_flag")

-- 子模块
local http_client = require("NeoAI.core.ai.http_client")
local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
local response_retry = require("NeoAI.core.ai.response_retry")

-- ========== 状态 ==========

local state = {
  initialized = false,
  is_generating = false,
  current_generation_id = nil,
  tools = {},
  tool_definitions = {},
  tool_call_counter = 0,
  first_request = true,
  active_generations = {},
  event_listeners = {},

  -- 重试配置
  max_retries = 3,
  retry_delay_ms = 1000,
}

-- 流式 reasoning 节流状态
local _reasoning_throttle = {
  timer = nil,
  pending_content = "",
  generation_id = nil,
  processor = nil,
  params = nil,
  interval_ms = 80, -- 每 80ms 批量刷新一次 reasoning UI
}

-- ========== 初始化 ==========

function M.initialize(options)
  if state.initialized then
    return M
  end

  http_client.initialize({ config = {} })
  -- 优先从统一状态管理器获取配置
  -- 若 state_manager 未初始化（如测试环境），回退到 options.config
  local full_config
  if state_manager.is_initialized() then
    full_config = state_manager.get_config()
  else
    full_config = (options or {}).config or {}
  end
  tool_orchestrator.initialize({ config = full_config })

  -- 初始化工具包管理模块
  local tool_pack = require("NeoAI.tools.tool_pack")
  tool_pack.initialize()

  M._setup_event_listeners()
  state.initialized = true

  vim.api.nvim_exec_autocmds("User", { pattern = event_constants.PLUGIN_INITIALIZED })
  logger.info("AI engine initialized")
  return M
end

-- ========== 事件监听 ==========

function M._setup_event_listeners()
  state.event_listeners.tool_result_received = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.TOOL_RESULT_RECEIVED,
    callback = function(args)
      M.handle_tool_result(args.data)
    end,
  })
  state.event_listeners.stream_completed = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.STREAM_COMPLETED,
    callback = function(args)
      M.handle_stream_completed(args.data)
    end,
  })
  -- 注意：TOOL_LOOP_STOP_REQUESTED 事件由 tool_orchestrator.request_stop() 内部触发并处理
  -- 不需要在此处额外监听，否则会导致无限递归
  state.event_listeners.cancel_generation = vim.api.nvim_create_autocmd("User", {
    pattern = event_constants.CANCEL_GENERATION,
    callback = function()
      M.cancel_generation()
    end,
  })
end

-- ========== 配置解析 ==========

--- 获取场景的 AI 配置
local function resolve_scenario_config(scenario)
  if config_merger and config_merger.get_preset then
    local preset = config_merger.get_preset(scenario)
    if preset and preset.base_url and preset.api_key then
      return preset
    end
  end

  local full_config = state_manager.get_config()
  local ai_config = (full_config and full_config.ai) or {}
  local scenarios = ai_config.scenarios or {}
  local entry = scenarios[scenario] or scenarios[ai_config.default or "chat"]
  if not entry then
    return {}
  end

  local candidate = type(entry) == "table" and (entry[1] or entry) or entry
  if not candidate then
    return {}
  end

  local provider_name = candidate.provider or "deepseek"
  local provider = (ai_config.providers or {})[provider_name]
  local result = {}
  if provider then
    result.base_url = provider.base_url
    result.api_key = provider.api_key
  end
  for k, v in pairs(candidate) do
    result[k] = v
  end
  if not result.stream then
    result.stream = ai_config.stream
  end
  if not result.timeout then
    result.timeout = ai_config.timeout
  end
  if not result.system_prompt then
    result.system_prompt = ai_config.system_prompt
  end
  return result
end

--- 获取模型配置（统一入口）
local function get_model_config(model_index)
  model_index = model_index or 1
  local preset = {}

  -- 1. 场景候选列表
  if config_merger and config_merger.get_scenario_candidates then
    local candidates = config_merger.get_scenario_candidates("chat")
    local target = candidates[model_index]
    if target then
      preset = vim.deepcopy(target)
      preset.model = preset.model_name
    end
  end

  -- 2. get_available_models 回退
  if not preset.base_url or not preset.api_key then
    if config_merger and config_merger.get_available_models then
      local models = config_merger.get_available_models("chat")
      local target = models[model_index]
      if target then
        local full_config = state_manager.get_config()
        local providers = (full_config and full_config.ai and full_config.ai.providers) or {}
        local pdef = providers[target.provider]
        if pdef then
          preset.base_url = pdef.base_url
          preset.api_key = pdef.api_key
        end
        preset.provider = target.provider
        preset.model_name = target.model_name
        preset.model = target.model_name
        preset.stream = true
        preset.timeout = 60000
      end
    end
  end

  -- 3. 最终回退
  if not preset.base_url or not preset.api_key then
    preset = resolve_scenario_config("chat")
  end
  return preset
end

-- ========== 消息处理 ==========

--- 格式化消息（带多层去重）
--- 去重规则：
--- 1. 连续相同的 user 消息只保留最后一条
--- 2. 连续相同的 assistant 消息只保留最后一条
--- 3. 未匹配的 tool_call_id 添加占位消息（已有）
local function format_messages(messages)
  if not messages then
    return {}
  end

  -- 第一步：预去重，移除连续重复的消息
  local deduped = {}
  for _, msg in ipairs(messages) do
    local last = deduped[#deduped]
    if last and last.role == msg.role and last.role ~= "tool" then
      -- 对于 user 和 assistant 消息，检查内容是否相同
      local last_content = type(last.content) == "string" and last.content or ""
      local msg_content = type(msg.content) == "string" and msg.content or ""
      if last_content == msg_content then
        -- 跳过重复消息
        goto continue
      end
    end
    -- 对于 tool 消息，检查 tool_call_id 是否重复
    if last and last.role == "tool" and msg.role == "tool" then
      if last.tool_call_id == msg.tool_call_id then
        goto continue
      end
    end
    table.insert(deduped, msg)
    ::continue::
  end

  -- 使用去重后的消息列表
  messages = deduped

  -- 第二步：过滤 assistant 消息中的 UI 折叠文本（{{{ ... }}}）
  -- 这些折叠文本是 chat_window 为 UI 显示而添加的，不应发送给 API
  -- 折叠块格式：以 {{{ 开头，以 }}} 结尾，中间可能包含任意内容
  -- 注意：_build_tool_folded_text 中已对 {{{ 和 }}} 做了转义（} } }），所以不会嵌套
  -- 但折叠块内可能包含 } 字符（如 JSON 数据），所以不能用 [^}] 匹配
  -- 使用平衡匹配 %b{} 来匹配最外层的折叠块
  -- 注意：不修改原始消息对象，创建新消息列表
  local filtered_messages = {}
  for _, msg in ipairs(messages) do
    if msg.role == "assistant" and msg.content and type(msg.content) == "string" then
      local content = msg.content
      -- 只移除完整的折叠块（{{{ ... }}}），保留折叠块之外的内容
      -- 策略：逐行扫描，跳过折叠块区域
      local lines = vim.split(content, "\n")
      local in_fold = false
      local cleaned_lines = {}
      for _, line in ipairs(lines) do
        if line:find("^{{{") then
          in_fold = true
        end
        if not in_fold then
          table.insert(cleaned_lines, line)
        end
        if in_fold and line:find("^}}}") then
          in_fold = false
        end
      end
      local cleaned = table.concat(cleaned_lines, "\n")
      cleaned = vim.trim(cleaned)
      if cleaned ~= content then
        -- 创建新消息对象，不修改原始 msg
        local new_msg = vim.deepcopy(msg)
        new_msg.content = cleaned
        table.insert(filtered_messages, new_msg)
      else
        table.insert(filtered_messages, msg)
      end
    else
      table.insert(filtered_messages, msg)
    end
  end
  messages = filtered_messages

  local result = {}
  -- 收集所有 tool_call_id（来自 assistant 消息的 tool_calls）
  -- 对于没有 id 的 tool_call，生成占位 ID 并直接添加到消息中
  -- 使用计数器跟踪每个 tool_call_id 的预期出现次数，避免重复 tool 消息导致匹配混乱
  -- 注意：不修改原始消息对象（tc.id），使用深拷贝的 tool_calls 列表
  local expected_tool_call_ids = {} ---@type table<string,number>
  for _, msg in ipairs(messages) do
    if msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        if tc.id and tc.id ~= "" then
          expected_tool_call_ids[tc.id] = (expected_tool_call_ids[tc.id] or 0) + 1
        else
          -- 为没有 id 的 tool_call 生成占位 ID，避免 API 报错
          -- 使用局部变量，不修改原始消息对象
          local placeholder_id = "call_placeholder_" .. os.time() .. "_" .. math.random(10000, 99999)
          expected_tool_call_ids[placeholder_id] = (expected_tool_call_ids[placeholder_id] or 0) + 1
        end
      end
    end
  end
  for _, msg in ipairs(messages) do
    local fm = { role = msg.role or "user" }
    if msg.content then
      fm.content = type(msg.content) == "table" and msg.content or tostring(msg.content)
    end
    if msg.tool_calls then
      fm.tool_calls = msg.tool_calls
    end
    if msg.role == "tool" then
      if msg.tool_call_id and msg.tool_call_id ~= "" then
        fm.tool_call_id = msg.tool_call_id
        -- 从期望列表中递减已匹配的 tool_call_id 计数
        if expected_tool_call_ids[msg.tool_call_id] then
          expected_tool_call_ids[msg.tool_call_id] = expected_tool_call_ids[msg.tool_call_id] - 1
          if expected_tool_call_ids[msg.tool_call_id] <= 0 then
            expected_tool_call_ids[msg.tool_call_id] = nil
          end
        end
      else
        fm.role = "user"
      end
      if fm.content == nil then
        fm.content = ""
      end
    elseif msg.tool_call_id then
      fm.tool_call_id = msg.tool_call_id
    end
    if msg.name then
      fm.name = msg.name
    end
    if msg.reasoning_content then
      fm.reasoning_content = msg.reasoning_content
    end
    table.insert(result, fm)
  end
  -- 检查是否有未匹配的 tool_call_id（assistant 的 tool_calls 没有对应的 tool 消息）
  -- 使用计数器过滤：只保留计数 > 0 的 ID（值为 nil 的 key 已被删除）
  local missing_ids = {}
  for id, count in pairs(expected_tool_call_ids) do
    if count and count > 0 then
      table.insert(missing_ids, id)
    end
  end
  if #missing_ids > 0 then
    for _, id in ipairs(missing_ids) do
      table.insert(result, { role = "tool", tool_call_id = id, content = "[工具结果缺失]" })
    end
  end
  return result
end

--- 构建工具结果消息
local function build_tool_result_message(tool_call_id, result, tool_name)
  local safe_id = tool_call_id
  if not safe_id or safe_id == "" then
    safe_id = "call_" .. os.time() .. "_" .. math.random(10000, 99999)
  end
  local msg = { role = "tool", tool_call_id = safe_id, content = "" }
  if type(result) == "string" then
    msg.content = result
  elseif result ~= nil then
    msg.content = tostring(result)
  end
  if tool_name then
    msg.name = tool_name
  end
  return msg
end

--- 添加工具调用到消息历史
local function add_tool_call_to_history(messages, tool_call, tool_result)
  local updated = vim.deepcopy(messages or {})
  local tf = tool_call["function"] or tool_call.func
  if not tool_call or not tf or not tf.name then
    return updated
  end
  local safe_id = tool_call.id
  if not safe_id or safe_id == "" then
    safe_id = "call_" .. os.time() .. "_" .. math.random(10000, 99999)
    tool_call.id = safe_id
  end
  table.insert(updated, { role = "assistant", tool_calls = { tool_call } })
  table.insert(updated, build_tool_result_message(safe_id, tool_result, tf.name))
  return updated
end

-- ========== 请求构建 ==========

--- 构建 AI 请求体
local function build_request(params)
  local messages = params.messages or {}
  -- 解码消息内容中的 %%XX URL 编码（由 http_client._encode_special_chars 编码的响应内容）
  local http_client = require("NeoAI.core.ai.http_client")
  for _, msg in ipairs(messages) do
    if msg.content and type(msg.content) == "string" then
      msg.content = http_client._decode_special_chars(msg.content)
    end
    if msg.reasoning_content and type(msg.reasoning_content) == "string" then
      msg.reasoning_content = http_client._decode_special_chars(msg.reasoning_content)
    end
    -- 解码 tool_calls 中的 arguments
    if msg.tool_calls and type(msg.tool_calls) == "table" then
      for _, tc in ipairs(msg.tool_calls) do
        local func = tc["function"] or tc.func
        if func and func.arguments and type(func.arguments) == "string" then
          func.arguments = http_client._decode_special_chars(func.arguments)
        end
      end
    end
  end
  local options = params.options or {}
  local session_id = params.session_id
  state.tool_call_counter = state.tool_call_counter + 1
  local generation_id = params.generation_id
    or (os.time() .. "_" .. math.random(1000, 9999) .. "_" .. state.tool_call_counter)

  local mode = options.mode or "chat"
  local request

  if mode == "fim" then
    request = {
      model = options.model or "gpt-4",
      prompt = options.prompt or "",
      suffix = options.suffix or "",
      max_tokens = options.max_tokens or 64,
      stream = false,
    }
  else
    local use_stream = options.stream
    if use_stream == nil then
      use_stream = true
    end
    request = {
      model = options.model or "gpt-4",
      messages = messages,
      max_tokens = options.max_tokens or 2000,
      stream = use_stream,
    }
  end

  if mode ~= "fim" then
    local reasoning_enabled = (options.reasoning_enabled ~= nil) and options.reasoning_enabled or false

    -- 获取当前模型名，用于后续可能的切换
    local model_name = options.model or ""

    if reasoning_enabled then
      local raw_effort = options.reasoning_effort or "high"
      local effort_map = { low = "low", medium = "low", high = "high", xhigh = "max", max = "max" }
      request.extra_body = { thinking = { type = "enabled" }, reasoning_effort = effort_map[raw_effort] or "high" }
    else
      request.temperature = options.temperature or 0.7
      -- 新 DeepSeek API 默认启用思考模式，需要显式禁用以支持工具调用等功能
      request.extra_body = { thinking = { type = "disabled" } }

      -- deepseek-reasoner 是思考模式的模型名，禁用思考模式时应使用 deepseek-chat
      -- 两者实际都是 deepseek-v4-flash
      if model_name and type(model_name) == "string" and model_name:lower():find("reasoner") then
        local new_model = model_name:gsub("reasoner", "chat"):gsub("re$", "")
        if new_model == model_name then
          new_model = "deepseek-chat"
        end
        request.model = new_model
      end
    end

    -- 防御性检查：如果外部调用方已设置了强制工具调用（tool_choice 为 function 类型），
    -- 则自动禁用思考模式。DeepSeek 等 API 在思考模式下不支持强制工具调用。
    -- 注意：tool_choice 为 "auto" 或 "none" 时不处理。
    -- 此检查必须在工具定义处理之前，因为工具定义处理可能会设置 tool_choice = "auto"
    local has_forced_tool = (
      options.tool_choice
      and type(options.tool_choice) == "table"
      and options.tool_choice.type == "function"
    )
      or (params.tool_choice and type(params.tool_choice) == "table" and params.tool_choice.type == "function")
    if has_forced_tool and request.extra_body and request.extra_body.thinking then
      request.extra_body.thinking = nil
      request.extra_body.reasoning_effort = nil
      if not next(request.extra_body) then
        request.extra_body = nil
      end
      -- 恢复 temperature（思考模式禁用后需要 temperature）
      request.temperature = options.temperature or 0.7
    end

    -- 工具定义
    local tools_enabled
    if options.tools_enabled ~= nil then
      tools_enabled = options.tools_enabled
    else
      local full_config = state_manager.get_config()
      if full_config and full_config.tools and full_config.tools.enabled ~= nil then
        tools_enabled = full_config.tools.enabled
      elseif full_config and full_config.ai then
        tools_enabled = full_config.ai.tools_enabled
      end
    end

    local is_first = state.first_request
    if is_first then
      state.first_request = false
    end

    if tools_enabled and #state.tool_definitions > 0 then
      local model_name = (options.model or ""):lower()
      if not model_name:find("reasoner") then
        local tools_to_use = state.tool_definitions
        if is_first then
          tools_to_use = {}
          for _, td in ipairs(state.tool_definitions) do
            if td["function"] and td["function"].name ~= "stop_tool_loop" then
              table.insert(tools_to_use, td)
            end
          end
        end
        if reasoning_enabled then
          local strict_tools = {}
          for _, td in ipairs(tools_to_use) do
            local s = vim.deepcopy(td)
            if s["function"] then
              s["function"].strict = true
              if s["function"].parameters then
                s["function"].parameters.additionalProperties = false
              end
            end
            table.insert(strict_tools, s)
          end
          request.tools = strict_tools
        else
          request.tools = tools_to_use
        end
        request.tool_choice = "auto"
      end
    end
  end

  if session_id then
    request.session_id = session_id
  end
  request.generation_id = generation_id
  return request
end

-- ========== 流式处理（内联） ==========

local function create_stream_processor(generation_id, session_id, window_id)
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

local function process_stream_chunk(processor, data)
  if processor.is_finished then
    return nil
  end
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
            processor.tool_calls[idx + 1] =
              { id = safe_id, type = tc.type or "function", ["function"] = { name = "", arguments = "" } }
          end
          local e = processor.tool_calls[idx + 1]
          if tc.id then
            e.id = tc.id
          end
          if tc.type then
            e.type = tc.type
          end
          if tc["function"] then
            if tc["function"].name then
              e["function"].name = e["function"].name .. tc["function"].name
            end
            if tc["function"].arguments then
              e["function"].arguments = e["function"].arguments .. tc["function"].arguments
            end
          end
        end
        if #processor.tool_calls > 0 then
          result.tool_calls = vim.deepcopy(processor.tool_calls)
        end
      end
    end
    if choice.message and choice.message.tool_calls then
      for _, tc in ipairs(choice.message.tool_calls) do
        local idx = tc.index or 0
        if not processor.tool_calls[idx + 1] then
          local safe_id = tc.id or ("call_" .. os.time() .. "_" .. idx)
          processor.tool_calls[idx + 1] =
            { id = safe_id, type = tc.type or "function", ["function"] = { name = "", arguments = "" } }
        end
        local e = processor.tool_calls[idx + 1]
        if tc.id then
          e.id = tc.id
        end
        if tc.type then
          e.type = tc.type
        end
        if tc["function"] then
          if tc["function"].name then
            e["function"].name = tc["function"].name
          end
          if tc["function"].arguments then
            e["function"].arguments = tc["function"].arguments
          end
        end
      end
      if #processor.tool_calls > 0 then
        result.tool_calls = vim.deepcopy(processor.tool_calls)
      end
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

-- ========== 核心生成流程 ==========

--- 生成 AI 响应
function M.generate_response(messages, params)
  -- 清理 reasoning 节流状态，确保新一轮生成不受旧状态影响
  if _reasoning_throttle.timer then
    pcall(_reasoning_throttle.timer.stop, _reasoning_throttle.timer)
    pcall(_reasoning_throttle.timer.close, _reasoning_throttle.timer)
    _reasoning_throttle.timer = nil
  end
  _reasoning_throttle.pending_content = ""
  _reasoning_throttle.generation_id = nil
  _reasoning_throttle.processor = nil
  _reasoning_throttle.params = nil

  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}
  state.is_generating = true

  local model_index = params.model_index or 1
  local ai_preset = get_model_config(model_index)

  local generation_id = os.time() .. "_" .. math.random(1000, 9999)
  state.current_generation_id = generation_id
  state.active_generations[generation_id] = {
    start_time = os.time(),
    messages = messages,
    session_id = session_id,
    window_id = window_id,
    options = options,
    model_index = model_index,
    ai_preset = ai_preset,
    retry_count = 0,
    accumulated_usage = {}, -- 累积各次工具循环的 token 用量
  }

  -- 注入 system_prompt：如果 ai_preset 有 system_prompt 且消息中还没有 system 消息，则添加到开头
  -- 支持预设级别单独 system_prompt，未设置时使用全局 system_prompt
  local formatted = format_messages(messages)
  if ai_preset.system_prompt and ai_preset.system_prompt ~= "" then
    local has_system = false
    for _, msg in ipairs(formatted) do
      if msg.role == "system" then
        has_system = true
        break
      end
    end
    if not has_system then
      table.insert(formatted, 1, {
        role = "system",
        content = ai_preset.system_prompt,
      })
    end
  end
  local stream_val = (options.stream ~= nil) and options.stream or (ai_preset.stream ~= false)
  local request = build_request({
    messages = formatted,
    options = vim.tbl_extend("force", options, {
      model = ai_preset.model_name or options.model,
      temperature = ai_preset.temperature or options.temperature,
      max_tokens = ai_preset.max_tokens or options.max_tokens,
      stream = stream_val,
    }),
    session_id = session_id,
    generation_id = generation_id,
  })

  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_STARTED,
    data = {
      generation_id = generation_id,
      formatted_messages = formatted,
      request = request,
      session_id = session_id,
      window_id = window_id,
    },
  })

  if request.stream then
    M._send_stream_request(
      generation_id,
      request,
      { session_id = session_id, window_id = window_id, options = options }
    )
  else
    M._send_non_stream_request(
      generation_id,
      request,
      { session_id = session_id, window_id = window_id, options = options }
    )
  end
end

--- 非流式请求
function M._send_non_stream_request(generation_id, request, params)
  -- 清理 reasoning 节流状态，确保新一轮生成不受旧状态影响
  if _reasoning_throttle.timer then
    pcall(_reasoning_throttle.timer.stop, _reasoning_throttle.timer)
    pcall(_reasoning_throttle.timer.close, _reasoning_throttle.timer)
    _reasoning_throttle.timer = nil
  end
  _reasoning_throttle.pending_content = ""
  _reasoning_throttle.generation_id = nil
  _reasoning_throttle.processor = nil
  _reasoning_throttle.params = nil

  -- 防御性检查：确保 active_generations 表存在
  if not state.active_generations then
    return
  end
  local generation = state.active_generations[generation_id]
  if not generation then
    return
  end

  local ai_preset = generation.ai_preset or {}
  local response, err = http_client.send_request({
    request = request,
    generation_id = generation_id,
    base_url = ai_preset.base_url,
    api_key = ai_preset.api_key,
    timeout = ai_preset.timeout,
    api_type = ai_preset.api_type or "openai",
    provider_config = ai_preset,
  })

  if err then
    if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then
      return
    end
    if generation.retry_count < state.max_retries then
      generation.retry_count = generation.retry_count + 1
      -- 使用 vim.defer_fn 延迟重试，避免阻塞事件循环
      vim.defer_fn(function()
        -- 检查是否已被取消
        if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then
          logger.warn(
            "[ai_engine] _send_non_stream_request 重试已取消：用户按下了停止键或 generation 已失效"
          )
          return
        end
        M._send_non_stream_request(generation_id, request, params)
      end, state.retry_delay_ms)
      return
    end
    M.handle_generation_error(generation_id, err)
    return
  end

  if response and response.error then
    local err_msg = response.error.message
    if not err_msg then
      pcall(function()
        err_msg = json.encode(response.error)
      end)
    end
    if not err_msg then
      err_msg = "未知错误"
    end
    M.handle_generation_error(generation_id, err_msg)
    return
  end

  M._handle_ai_response(generation_id, response, params)
end

--- 流式请求
function M._send_stream_request(generation_id, request, params)
  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}

  logger.debug(
    "[ai_engine] _send_stream_request: generation_id="
      .. tostring(generation_id)
      .. ", session_id="
      .. tostring(session_id)
      .. ", is_tool_loop="
      .. tostring(params.is_tool_loop)
  )

  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.STREAM_STARTED,
    data = { generation_id = generation_id, session_id = session_id, window_id = window_id },
  })

  local processor = create_stream_processor(generation_id, session_id, window_id)
  -- 防御性检查：确保 active_generations 表存在
  if not state.active_generations then
    state.active_generations = {}
  end
  local gen = state.active_generations[generation_id]
  if gen then
    gen._stream_processor = processor
    gen._last_request = request -- 保存请求体，供重试时使用
  end

  local ai_preset = gen and gen.ai_preset or {}
  if not ai_preset.base_url or not ai_preset.api_key then
    logger.debug("[ai_engine] _send_stream_request: ai_preset 缺少 base_url/api_key，重新获取模型配置")
    ai_preset = get_model_config(gen and gen.model_index or 1)
    if gen then
      gen.ai_preset = ai_preset
    end
  end

  if not ai_preset.base_url or not ai_preset.api_key then
    logger.error(
      "[ai_engine] _send_stream_request: 无法获取有效的 AI 配置，base_url="
        .. tostring(ai_preset.base_url)
        .. ", api_key="
        .. tostring(ai_preset.api_key and "***" or nil)
    )
    M.handle_generation_error(generation_id, "AI 配置无效：缺少 base_url 或 api_key")
    return
  end

  local function retry_or_error(err)
    if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then
      return
    end
    local g = state.active_generations[generation_id]
    if g and g.retry_count < state.max_retries then
      g.retry_count = g.retry_count + 1
      logger.debug("[ai_engine] _send_stream_request: 重试第 " .. g.retry_count .. " 次，错误=" .. tostring(err))
      -- 使用 vim.defer_fn 延迟重试，避免在 job 回调中调用 vim.wait 阻塞事件循环
      vim.defer_fn(function()
        -- 检查是否已被取消（用户按停止键后，state.is_generating 会被设为 false）
        if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then
          logger.warn(
            "[ai_engine] _send_stream_request 重试已取消：用户按下了停止键或 generation 已失效"
          )
          return
        end
        M._send_stream_request(generation_id, request, params)
      end, state.retry_delay_ms)
      return
    end
    logger.error("[ai_engine] _send_stream_request: 重试耗尽，错误=" .. tostring(err))
    M.handle_generation_error(generation_id, err)
  end

  local request_body_size = #(vim.json.encode(request or {}))
  logger.debug(
    string.format(
      "[ai_engine] _send_stream_request: generation_id=%s, base_url=%s, 请求体大小=%d bytes, is_tool_loop=%s, is_final_round=%s",
      tostring(generation_id),
      tostring(ai_preset.base_url),
      request_body_size,
      tostring(params and params.is_tool_loop),
      tostring(params and params.is_final_round)
    )
  )
  http_client.send_stream_request({
    request = request,
    generation_id = generation_id,
    base_url = ai_preset.base_url,
    api_key = ai_preset.api_key,
    timeout = ai_preset.timeout,
    api_type = ai_preset.api_type or "openai",
    provider_config = ai_preset,
  }, function(data)
    M._handle_stream_chunk(generation_id, data, processor, params)
  end, function()
    M._handle_stream_end(generation_id, processor, params)
  end, function(err)
    retry_or_error(err)
  end)
end

--- 处理流式数据块（带 reasoning 节流）
function M._handle_stream_chunk(generation_id, data, processor, params)
  local result = process_stream_chunk(processor, data)
  if not result then
    return
  end

  -- 内容块：直接触发事件（已在主线程的 job 回调中运行，无需 vim.schedule）
  if result.content then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.STREAM_CHUNK,
      data = {
        generation_id = generation_id,
        chunk = result.content,
        session_id = processor.session_id,
        window_id = processor.window_id,
        is_final = false,
      },
    })
  end

  -- reasoning 内容：节流处理，避免高频 UI 更新堆积事件队列
  if result.reasoning_content then
    _reasoning_throttle.pending_content = _reasoning_throttle.pending_content .. result.reasoning_content
    _reasoning_throttle.generation_id = generation_id
    _reasoning_throttle.processor = processor
    _reasoning_throttle.params = params

    if not _reasoning_throttle.timer then
      _reasoning_throttle.timer = vim.defer_fn(function()
        local content = _reasoning_throttle.pending_content
        local gid = _reasoning_throttle.generation_id
        local proc = _reasoning_throttle.processor
        local p = _reasoning_throttle.params
        _reasoning_throttle.pending_content = ""
        _reasoning_throttle.timer = nil

        if content ~= "" then
          vim.api.nvim_exec_autocmds("User", {
            pattern = event_constants.REASONING_CONTENT,
            data = {
              generation_id = gid,
              reasoning_content = content,
              session_id = proc and proc.session_id,
              window_id = proc and proc.window_id,
            },
          })
        end
      end, _reasoning_throttle.interval_ms)
    end
  end

  -- tool_calls 检测：只触发事件通知 UI，不启动工具
  -- 等待流式结束（_handle_stream_end）时 arguments 才完整
  if result.tool_calls and #result.tool_calls > 0 then
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.TOOL_CALL_DETECTED,
      data = {
        generation_id = generation_id,
        tool_calls = result.tool_calls,
        session_id = processor.session_id,
        window_id = processor.window_id,
      },
    })
  end
end

--- 处理流式结束
function M._handle_stream_end(generation_id, processor, params)
  local full_response = processor.content_buffer or ""
  local reasoning_text = processor.reasoning_buffer or ""
  local usage = processor.usage or {}
  local tool_calls = processor.tool_calls or {}
  logger.debug(
    string.format(
      "[ai_engine] _handle_stream_end: generation_id=%s, content_buffer大小=%d, tool_calls数量=%d, is_finished=%s",
      tostring(generation_id),
      #full_response,
      #tool_calls,
      tostring(processor.is_finished)
    )
  )

  -- 过滤掉流式截断导致的无效工具调用（name 为空或 arguments 为空的条目）
  -- DeepSeek 等模型在流式过程中可能发送空的 tool_call 骨架，流式结束时需清理
  -- 注意："{}"（空 JSON 对象）是合法参数，表示工具不需要参数（如 stop_tool_loop），不应过滤
  local valid_tool_calls = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name and func.name ~= "" then
      local args = func.arguments
      -- 跳过 arguments 为 nil 或空字符串的条目（流式截断导致）
      -- 保留 "{}"（空 JSON 对象），这是合法的空参数
      if args ~= nil and args ~= "" then
        table.insert(valid_tool_calls, tc)
      end
    end
  end
  tool_calls = valid_tool_calls

  -- 清理 reasoning 节流状态
  if _reasoning_throttle.timer then
    pcall(_reasoning_throttle.timer.stop, _reasoning_throttle.timer)
    pcall(_reasoning_throttle.timer.close, _reasoning_throttle.timer)
    _reasoning_throttle.timer = nil
  end
  _reasoning_throttle.pending_content = ""
  _reasoning_throttle.generation_id = nil
  _reasoning_throttle.processor = nil
  _reasoning_throttle.params = nil

  -- 保存 reasoning 到 generation 记录
  local gen = state.active_generations[generation_id]
  if reasoning_text ~= "" and gen then
    gen.last_reasoning_content = reasoning_text
  end

  -- 清理 reasoning 节流状态（确保不残留到下一轮工具循环）
  if _reasoning_throttle.timer then
    pcall(_reasoning_throttle.timer.stop, _reasoning_throttle.timer)
    pcall(_reasoning_throttle.timer.close, _reasoning_throttle.timer)
    _reasoning_throttle.timer = nil
  end
  _reasoning_throttle.pending_content = ""
  _reasoning_throttle.generation_id = nil
  _reasoning_throttle.processor = nil
  _reasoning_throttle.params = nil

  -- ===== 响应异常检测与重试 =====
  local is_tool_loop = params and params.is_tool_loop
  local is_final_round = params and params.is_final_round
  local abnormal, reason = response_retry.detect_abnormal_response(full_response, tool_calls, {
    is_tool_loop = is_tool_loop,
    is_final_round = is_final_round,
  })
  if abnormal then
    local gen = state.active_generations[generation_id]
    if gen then
      local retry_count = gen.retry_count or 0
      logger.debug(
        string.format(
          "[ai_engine] 异常响应详情: generation_id=%s, reason=%s, retry_count=%d, processor.start_time=%d, 耗时=%ds, processor.is_finished=%s, usage=%s",
          tostring(generation_id),
          tostring(reason),
          retry_count,
          processor.start_time or 0,
          os.time() - (processor.start_time or os.time()),
          tostring(processor.is_finished),
          vim.inspect(processor.usage or {})
        )
      )
      -- 工具循环模式下空响应：不重试，直接结束工具循环
      -- DeepSeek 等 API 在处理复杂上下文时可能返回空 HTTP 200，重试无意义
      if is_tool_loop and reason and reason:find("空响应") then
        logger.warn("[ai_engine] 工具循环中检测到空响应，直接结束工具循环")
        state.is_generating = false
        state.current_generation_id = nil
        state.active_generations[generation_id] = nil
        tool_orchestrator.on_generation_complete({
          generation_id = generation_id,
          tool_calls = {},
          content = full_response,
          reasoning = reasoning_text,
          usage = usage,
          session_id = processor.session_id,
          is_final_round = true,
        })
        return
      end

      if response_retry.can_retry(retry_count) then
        local new_retry_count = retry_count + 1
        gen.retry_count = new_retry_count
        local delay = response_retry.get_retry_delay(new_retry_count)
        -- 输出原始响应内容以便排查
        local raw_response_for_log = full_response and full_response:sub(1, 1000) or "nil"
        if full_response and #full_response > 1000 then
          raw_response_for_log = raw_response_for_log .. "...[truncated, total=" .. #full_response .. "]"
        end
        local tool_calls_count = tool_calls and #tool_calls or 0
        -- 通知 UI 正在重试
        vim.api.nvim_exec_autocmds("User", {
          pattern = event_constants.GENERATION_RETRYING,
          data = {
            generation_id = generation_id,
            retry_count = new_retry_count,
            max_retries = response_retry.get_max_retries(),
            reason = reason,
            session_id = processor.session_id,
            window_id = processor.window_id,
          },
        })
        local saved_request = gen._last_request
        if not saved_request then
          -- 如果 request 未保存，从 generation 记录中重建
          local s = state.active_generations[generation_id]
          if s and s.messages and #s.messages > 0 then
            local formatted = format_messages(s.messages)
            saved_request = build_request({
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
            gen._last_request = saved_request
          end
        end

        -- 如果是因为缺少 stop_tool_loop 而重试，在消息中插入提示
        -- 告知 AI 必须调用 stop_tool_loop 工具来结束对话
        if reason and reason:find("缺少 stop_tool_loop") then
          local retry_prompt = "【系统提示】你刚刚直接返回了文本而没有调用 stop_tool_loop 工具。"
            .. "在工具循环模式下，当你认为任务已完成时，必须调用 stop_tool_loop 工具来结束对话，"
            .. "而不是直接返回文本。请调用 stop_tool_loop 工具来结束当前任务。"
          if saved_request and saved_request.messages then
            local inserted = false
            -- 在最后一条 user 消息之后、最后一条 assistant 消息之前插入
            for i = #saved_request.messages, 1, -1 do
              if saved_request.messages[i].role == "user" then
                table.insert(saved_request.messages, i + 1, {
                  role = "system",
                  content = retry_prompt,
                })
                inserted = true
                break
              end
            end
            if not inserted then
              table.insert(saved_request.messages, {
                role = "system",
                content = retry_prompt,
              })
            end
          end
        end

        vim.defer_fn(function()
          -- 检查是否已被取消（用户按停止键后，state.is_generating 会被设为 false）
          if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then
            logger.warn(
              string.format(
                "[ai_engine] 流式重试已取消：用户按下了停止键或 generation 已失效 | is_generating=%s | generation_exists=%s | generation_id=%s",
                tostring(state.is_generating),
                tostring(state.active_generations and state.active_generations[generation_id] ~= nil),
                tostring(generation_id)
              )
            )
            return
          end
          if saved_request then
            -- 释放生成状态，允许新一轮流式请求正常处理
            state.is_generating = false
            state.current_generation_id = nil
            -- 清除去重缓存，防止重试请求被去重机制拦截（请求体相同导致直接回调 on_complete，再次触发空响应）
            local http_client = require("NeoAI.core.ai.http_client")
            http_client.clear_request_dedup(generation_id)
            vim.defer_fn(function()
              if not state.active_generations or not state.active_generations[generation_id] then
                logger.warn("[ai_engine] 流式重试: generation 已失效，跳过")
                return
              end
              M._send_stream_request(generation_id, saved_request, params)
            end, 100)
          else
            -- 极端情况：没有保存的 request，通过 handle_tool_result 重新发起
            logger.warn("[ai_engine] 流式重试: 未找到保存的 request，通过 handle_tool_result 重新发起")
            -- 先释放生成状态，防止 handle_tool_result 中的 state.is_generating 检查跳过重试
            state.is_generating = false
            state.current_generation_id = nil
            vim.defer_fn(function()
              local s = state.active_generations[generation_id]
              if not s then
                logger.warn("[ai_engine] 流式重试: generation 记录已不存在，跳过")
                return
              end
              M.handle_tool_result({
                generation_id = generation_id,
                session_id = s.session_id,
                window_id = s.window_id,
                messages = s.messages,
                options = s.options,
                model_index = s.model_index,
                ai_preset = s.ai_preset,
                is_final_round = false,
                accumulated_usage = s.accumulated_usage,
                last_reasoning = s.last_reasoning_content,
              })
            end, 100)
          end
        end, delay)
        return
      else
        logger.warn(
          string.format(
            "[ai_engine] 流式响应异常但重试已达上限 (%d/%d): %s",
            retry_count,
            response_retry.get_max_retries(),
            reason
          )
        )
        -- 重试已达上限：不再重试
        -- 如果是在工具循环中且 AI 未调用 stop_tool_loop，强制结束循环
        if is_tool_loop and reason and reason:find("缺少 stop_tool_loop") then
          logger.warn("[ai_engine] 重试已达上限且 AI 未调用 stop_tool_loop，强制结束工具循环")
          state.is_generating = false
          state.current_generation_id = nil
          state.active_generations[generation_id] = nil
          tool_orchestrator.on_generation_complete({
            generation_id = generation_id,
            tool_calls = {},
            content = full_response,
            reasoning = reasoning_text,
            usage = usage,
            session_id = processor.session_id,
            is_final_round = true,
          })
          return
        end
        -- 总结轮次重试耗尽：直接触发错误，避免不完整的 tool_calls 污染消息历史
        if is_final_round then
          logger.warn("[ai_engine] 总结轮次重试已达上限，触发生成错误")
          M.handle_generation_error(generation_id, "总结轮次重试耗尽: " .. tostring(reason))
          return
        end
        -- 空响应重试耗尽：直接触发错误，避免卡住
        if reason and reason:find("空响应") then
          logger.warn("[ai_engine] 空响应重试已达上限，触发生成错误")
          M.handle_generation_error(generation_id, "AI 多次返回空响应: " .. tostring(reason))
          return
        end
        -- 其他异常：继续正常处理当前响应（包含 tool_calls）
        -- 避免工具调用被丢弃导致 UI 不渲染且不保存
        -- 注意：此时 tool_calls 可能不完整（流式截断导致），后续 API 调用可能失败
        -- 清理 tool_calls 中可能不完整的条目，避免污染消息历史
        local cleaned_tool_calls = {}
        for _, tc in ipairs(tool_calls) do
          local func = tc["function"] or tc.func
          if func and func.name and func.name ~= "" then
            local args = func.arguments
            if args and args ~= "" and args ~= "{}" then
              table.insert(cleaned_tool_calls, tc)
            end
          end
        end
        tool_calls = cleaned_tool_calls
      end
    end
  end

  -- 检查是否在工具循环模式中
  local is_tool_loop = params and params.is_tool_loop
  local is_final_round = params and params.is_final_round

  -- 检查工具是否启用
  local tools_enabled = true
  local full_config = state_manager.get_config()
  if full_config and full_config.tools and full_config.tools.enabled ~= nil then
    tools_enabled = full_config.tools.enabled
  elseif full_config and full_config.ai then
    tools_enabled = full_config.ai.tools_enabled
  end

  if #tool_calls > 0 and tools_enabled then
    if is_tool_loop then
      -- 工具循环模式：将 tool_calls 回传给 orchestrator，由它决定是否继续循环
      -- 先释放生成状态，允许下一轮 handle_tool_result 正常处理
      state.is_generating = false
      state.current_generation_id = nil
      -- 清理 active_generations，防止 handle_tool_result 中走错误的 else 分支
      state.active_generations[generation_id] = nil
      tool_orchestrator.on_generation_complete({
        generation_id = generation_id,
        tool_calls = tool_calls,
        content = full_response,
        reasoning = reasoning_text,
        usage = usage,
        session_id = processor.session_id,
        is_final_round = is_final_round or false,
      })
      return
    end

    -- 普通模式（非工具循环）：启动新的异步工具循环
    local tc_copy = {}
    for i, tc in ipairs(tool_calls) do
      tc_copy[i] = {
        id = tc.id,
        type = tc.type,
        ["function"] = { name = tc["function"].name, arguments = tc["function"].arguments },
      }
    end

    -- 注意：不在此处保存 AI 回复到 history。
    -- AI 回复（含工具调用折叠文本和思考过程）由 chat_window 的
    -- _save_final_content_to_history 在 GENERATION_COMPLETED 事件中统一保存。
    -- 工具调用结果由 tool_orchestrator 的 _add_tool_result_to_messages 实时保存。

    local gen = state.active_generations[generation_id]
    local messages = gen and gen.messages or {}
    local options = gen and gen.options or {}
    local model_index = gen and gen.model_index or 1
    local ai_preset = gen and gen.ai_preset or {}

    -- 将 content 和 tool_calls 合并到同一条 assistant 消息中
    local tc_msg = {
      role = "assistant",
      content = full_response or "",
      tool_calls = tc_copy,
      timestamp = os.time(),
      window_id = processor.window_id,
    }
    if reasoning_text and reasoning_text ~= "" then
      tc_msg.reasoning_content = reasoning_text
    end
    table.insert(messages, tc_msg)

    -- 释放生成状态，允许 handle_tool_result 处理后续 AI 请求
    state.is_generating = false
    state.current_generation_id = nil
    -- 清理 active_generations，防止 handle_tool_result 中走错误的 else 分支
    state.active_generations[generation_id] = nil

    tool_orchestrator.start_async_loop({
      generation_id = generation_id,
      tool_calls = tc_copy,
      session_id = processor.session_id,
      window_id = processor.window_id,
      options = options,
      messages = messages,
      model_index = model_index,
      ai_preset = ai_preset,
      on_complete = function(success, result, usage)
        if not success then
          logger.error("Tool loop failed: " .. tostring(result))
        end
        state.active_generations[generation_id] = nil
        state.is_generating = false
        state.current_generation_id = nil

        local ok, lsp_module = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
        if ok and lsp_module and lsp_module.flush_deferred_cleanups then
          lsp_module.flush_deferred_cleanups()
        end
      end,
    })
    return
  end

  if is_tool_loop then
    -- 工具循环模式：将结果回传给 orchestrator
    -- 先释放生成状态，允许下一轮 handle_tool_result 正常处理
    state.is_generating = false
    state.current_generation_id = nil
    state.active_generations[generation_id] = nil
    tool_orchestrator.on_generation_complete({
      generation_id = generation_id,
      tool_calls = {},
      content = full_response,
      reasoning = reasoning_text,
      usage = usage,
      session_id = processor.session_id,
      is_final_round = is_final_round or false,
    })
  else
    -- 普通模式：触发 STREAM_COMPLETED 事件
    state.is_generating = false
    state.current_generation_id = nil
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.STREAM_COMPLETED,
      data = {
        generation_id = generation_id,
        full_response = full_response,
        reasoning_text = reasoning_text,
        usage = usage,
        session_id = processor.session_id,
        window_id = processor.window_id,
      },
    })
  end
end

--- 处理 AI 响应（非流式）
function M._handle_ai_response(generation_id, response, params)
  local session_id = params.session_id
  local window_id = params.window_id
  local options = params.options or {}
  local response_content = ""
  local reasoning_content = nil
  local tool_calls = {}
  local usage = {}

  if response.choices and #response.choices > 0 then
    local choice = response.choices[1]
    if choice.message then
      if choice.message.content then
        response_content = choice.message.content
      end
      if choice.message.reasoning_content then
        reasoning_content = choice.message.reasoning_content
        vim.api.nvim_exec_autocmds("User", {
          pattern = event_constants.REASONING_CONTENT,
          data = {
            generation_id = generation_id,
            reasoning_content = reasoning_content,
            session_id = session_id,
            window_id = window_id,
          },
        })
      end
      if choice.message.tool_calls and #choice.message.tool_calls > 0 then
        tool_calls = choice.message.tool_calls
        vim.api.nvim_exec_autocmds("User", {
          pattern = event_constants.TOOL_CALL_DETECTED,
          data = {
            generation_id = generation_id,
            tool_calls = tool_calls,
            session_id = session_id,
            window_id = window_id,
            reasoning_content = reasoning_content,
          },
        })
      end
    end
  end

  -- 过滤掉无效的工具调用（name 为空或 arguments 为空的条目）
  -- 注意："{}"（空 JSON 对象）是合法参数，表示工具不需要参数（如 stop_tool_loop），不应过滤
  local valid_tool_calls = {}
  for _, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name and func.name ~= "" then
      local args = func.arguments
      -- 跳过 arguments 为 nil 或空字符串的条目
      -- 保留 "{}"（空 JSON 对象），这是合法的空参数
      if args ~= nil and args ~= "" then
        table.insert(valid_tool_calls, tc)
      end
    end
  end
  tool_calls = valid_tool_calls

  -- ===== 响应异常检测与重试 =====
  local is_tool_loop = params and params.is_tool_loop
  local is_final_round = params and params.is_final_round
  local abnormal, reason = response_retry.detect_abnormal_response(response_content, tool_calls, {
    is_tool_loop = is_tool_loop,
    is_final_round = is_final_round,
  })
  if abnormal then
    local generation = state.active_generations[generation_id]
    if generation then
      local retry_count = generation.retry_count or 0
      if response_retry.can_retry(retry_count) then
        local new_retry_count = retry_count + 1
        generation.retry_count = new_retry_count
        local delay = response_retry.get_retry_delay(new_retry_count)
        logger.warn(
          string.format(
            "[ai_engine] 检测到异常响应 (重试 %d/%d): %s, 延迟 %dms 后重试",
            new_retry_count,
            response_retry.get_max_retries(),
            reason,
            delay
          )
        )
        -- 通知 UI 正在重试
        vim.api.nvim_exec_autocmds("User", {
          pattern = event_constants.GENERATION_RETRYING,
          data = {
            generation_id = generation_id,
            retry_count = new_retry_count,
            max_retries = response_retry.get_max_retries(),
            reason = reason,
            session_id = params.session_id,
            window_id = params.window_id,
          },
        })
        vim.defer_fn(function()
          -- 检查是否已被取消
          if not state.is_generating or not state.active_generations or not state.active_generations[generation_id] then
            logger.warn("[ai_engine] 非流式响应重试已取消：用户按下了停止键或 generation 已失效")
            return
          end
          M._send_non_stream_request(generation_id, request, params)
        end, delay)
        return
      else
        logger.warn(
          string.format(
            "[ai_engine] 响应异常但重试已达上限 (%d/%d): %s",
            retry_count,
            response_retry.get_max_retries(),
            reason
          )
        )
        -- 重试已达上限：不再重试
        -- 总结轮次重试耗尽：直接触发错误，避免不完整的 tool_calls 污染消息历史
        if is_final_round then
          logger.warn("[ai_engine] 总结轮次重试已达上限，触发生成错误")
          M.handle_generation_error(generation_id, "总结轮次重试耗尽: " .. tostring(reason))
          return
        end
        -- 空响应重试耗尽：直接触发错误，避免卡住
        if reason and reason:find("空响应") then
          logger.warn("[ai_engine] 非流式空响应重试已达上限，触发生成错误")
          M.handle_generation_error(generation_id, "AI 多次返回空响应: " .. tostring(reason))
          return
        end
        -- 其他异常：继续正常处理当前响应（包含 tool_calls）
        -- 避免工具调用被丢弃导致 UI 不渲染且不保存
        -- 清理 tool_calls 中可能不完整的条目，避免污染消息历史
        local cleaned_tool_calls = {}
        for _, tc in ipairs(tool_calls) do
          local func = tc["function"] or tc.func
          if func and func.name and func.name ~= "" then
            local args = func.arguments
            if args and args ~= "" and args ~= "{}" then
              table.insert(cleaned_tool_calls, tc)
            end
          end
        end
        tool_calls = cleaned_tool_calls
      end
    end
  end

  local tools_enabled = true
  local full_config = state_manager.get_config()
  if full_config and full_config.tools and full_config.tools.enabled ~= nil then
    tools_enabled = full_config.tools.enabled
  elseif full_config and full_config.ai then
    tools_enabled = full_config.ai.tools_enabled
  end

  -- 清理 reasoning 节流状态（确保不残留到下一轮工具循环）
  if _reasoning_throttle.timer then
    pcall(_reasoning_throttle.timer.stop, _reasoning_throttle.timer)
    pcall(_reasoning_throttle.timer.close, _reasoning_throttle.timer)
    _reasoning_throttle.timer = nil
  end
  _reasoning_throttle.pending_content = ""
  _reasoning_throttle.generation_id = nil
  _reasoning_throttle.processor = nil
  _reasoning_throttle.params = nil

  -- 检查是否在工具循环模式中
  local is_tool_loop = params and params.is_tool_loop
  local is_final_round = params and params.is_final_round

  if #tool_calls > 0 and tools_enabled then
    if is_tool_loop then
      -- 工具循环模式：将 tool_calls 回传给 orchestrator，由它决定是否继续循环
      -- 先释放生成状态，允许下一轮 handle_tool_result 正常处理
      state.is_generating = false
      state.current_generation_id = nil
      state.active_generations[generation_id] = nil
      tool_orchestrator.on_generation_complete({
        generation_id = generation_id,
        tool_calls = tool_calls,
        content = response_content,
        reasoning = reasoning_content,
        usage = response.usage or {},
        session_id = session_id,
        is_final_round = is_final_round or false,
      })
      return
    end

    -- 普通模式（非工具循环）：启动新的异步工具循环
    local gen = state.active_generations[generation_id]
    local messages = gen and gen.messages or {}

    -- 注意：不在此处保存 AI 回复到 history。
    -- 由 chat_window 的 _save_final_content_to_history 统一保存。

    local model_index = gen and gen.model_index or 1
    local ai_preset = gen and gen.ai_preset or {}

    -- 将 content 和 tool_calls 合并到同一条 assistant 消息中
    local tc_msg = {
      role = "assistant",
      content = response_content or "",
      tool_calls = tool_calls,
      timestamp = os.time(),
      window_id = window_id,
    }
    if reasoning_content and reasoning_content ~= "" then
      tc_msg.reasoning_content = reasoning_content
    end
    table.insert(messages, tc_msg)

    -- 释放生成状态，允许 handle_tool_result 处理后续 AI 请求
    state.is_generating = false
    state.current_generation_id = nil
    state.active_generations[generation_id] = nil

    -- 启动异步工具循环
    tool_orchestrator.start_async_loop({
      generation_id = generation_id,
      tool_calls = tool_calls,
      session_id = session_id,
      window_id = window_id,
      options = options,
      messages = messages,
      model_index = model_index,
      ai_preset = ai_preset,
      on_complete = function(success, result, loop_usage)
        if not success then
          logger.error("Tool loop failed: " .. tostring(result))
        end
        state.active_generations[generation_id] = nil
        state.is_generating = false
        state.current_generation_id = nil

        local ok, lsp_module = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
        if ok and lsp_module and lsp_module.flush_deferred_cleanups then
          lsp_module.flush_deferred_cleanups()
        end
      end,
    })
    return
  end

  if response.usage then
    usage = response.usage
  end

  if is_tool_loop then
    -- 工具循环模式：将结果回传给 orchestrator
    -- 先释放生成状态，允许下一轮 handle_tool_result 正常处理
    state.is_generating = false
    state.current_generation_id = nil
    state.active_generations[generation_id] = nil
    tool_orchestrator.on_generation_complete({
      generation_id = generation_id,
      tool_calls = {},
      content = response_content,
      reasoning = reasoning_content,
      usage = usage,
      session_id = session_id,
      is_final_round = is_final_round or false,
    })
  else
    -- 普通模式：直接完成生成
    M._finalize_generation(generation_id, response_content, {
      session_id = session_id,
      window_id = window_id,
      reasoning_text = reasoning_content,
      usage = usage,
    })
  end
end

--- 完成生成
function M._finalize_generation(generation_id, response_text, params)
  local generation = state.active_generations[generation_id]
  if not generation then
    return
  end

  -- 将本次 usage 累积到 accumulated_usage
  local current_usage = params.usage or {}
  if current_usage and next(current_usage) then
    local acc = generation.accumulated_usage or {}
    acc.prompt_tokens = (acc.prompt_tokens or 0)
      + (
        current_usage.prompt_tokens
        or current_usage.promptTokens
        or current_usage.input_tokens
        or current_usage.inputTokens
        or 0
      )
    acc.completion_tokens = (acc.completion_tokens or 0)
      + (
        current_usage.completion_tokens
        or current_usage.completionTokens
        or current_usage.output_tokens
        or current_usage.outputTokens
        or 0
      )
    acc.total_tokens = (acc.total_tokens or 0) + (current_usage.total_tokens or current_usage.totalTokens or 0)
    -- 累积 reasoning_tokens
    if current_usage.completion_tokens_details and type(current_usage.completion_tokens_details) == "table" then
      local rt = current_usage.completion_tokens_details.reasoning_tokens or 0
      if not acc.completion_tokens_details then
        acc.completion_tokens_details = {}
      end
      acc.completion_tokens_details.reasoning_tokens = (acc.completion_tokens_details.reasoning_tokens or 0) + rt
    end
    generation.accumulated_usage = acc
  end

  local messages = generation.messages
  local assistant_msg =
    { role = "assistant", content = response_text or "", timestamp = os.time(), window_id = params.window_id }
  if params.reasoning_text and params.reasoning_text ~= "" then
    assistant_msg.reasoning_content = params.reasoning_text
  end
  table.insert(messages, assistant_msg)

  -- 确定最终 usage：优先使用 accumulated_usage（非空），否则使用 params.usage
  local final_usage = generation.accumulated_usage
  if not final_usage or not next(final_usage) then
    final_usage = params.usage or {}
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_COMPLETED,
    data = {
      generation_id = generation_id,
      response = response_text or "",
      reasoning_text = params.reasoning_text or "",
      usage = final_usage,
      session_id = params.session_id,
      window_id = params.window_id,
      duration = os.time() - generation.start_time,
    },
  })

  state.active_generations[generation_id] = nil
  state.is_generating = false
  state.current_generation_id = nil

  -- 会话历史保存已由 history_saver 通过事件监听统一处理
  -- 此处不再直接调用 session_manager 保存

  -- 刷新 LSP 延迟清理队列（确保临时 buffer 被关闭）
  local ok, lsp_module = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
  if ok and lsp_module and lsp_module.flush_deferred_cleanups then
    lsp_module.flush_deferred_cleanups()
  end
end

--- 处理工具结果（异步循环架构）
--- 由 tool_orchestrator 在工具执行完成后调度，发起新一轮 AI 生成
--- 此函数不再维护循环状态，只负责发起 AI 请求并将结果回传给 orchestrator
function M.handle_tool_result(data)
  local generation_id = data.generation_id
  local session_id = data.session_id
  local window_id = data.window_id
  local messages = data.messages
  local options = data.options or {}
  local model_index = data.model_index or 1
  local ai_preset = data.ai_preset or {}
  local is_final_round = data.is_final_round or false
  local accumulated_usage = data.accumulated_usage or {}
  local last_reasoning = data.last_reasoning

  -- 检查工具编排器是否已请求停止
  local tool_orc = require("NeoAI.core.ai.tool_orchestrator")
  if tool_orc.is_stop_requested(session_id) then
    logger.debug(
      "[ai_engine] handle_tool_result: 工具编排器已请求停止，跳过新一轮生成 (session="
        .. tostring(session_id)
        .. ")"
    )
    return
  end

  logger.debug(
    "[ai_engine] handle_tool_result: 会话="
      .. tostring(session_id)
      .. ", generation_id="
      .. tostring(generation_id)
      .. ", is_final_round="
      .. tostring(is_final_round)
      .. ", 消息数="
      .. tostring(#(messages or {}))
  )

  if not messages or #messages == 0 then
    logger.warn("handle_tool_result: 消息为空，跳过")
    return
  end

  -- 消息去重：移除所有重复的 tool 消息（防止 tool_call_id 未匹配导致叠加）
  -- 使用 seen_tool_ids 跟踪已出现的 tool_call_id，去重非连续的重复 tool 消息
  local cleaned_messages = {}
  local seen_tool_ids = {} ---@type table<string,boolean>
  for _, msg in ipairs(messages) do
    local last = cleaned_messages[#cleaned_messages]
    if msg.role == "tool" then
      if msg.tool_call_id and seen_tool_ids[msg.tool_call_id] then
        -- 跳过已出现过的 tool_call_id（无论是否连续）
        goto skip_msg
      end
      if msg.tool_call_id then
        seen_tool_ids[msg.tool_call_id] = true
      end
    end
    if last and last.role == "assistant" and msg.role == "assistant" then
      local last_content = type(last.content) == "string" and last.content or ""
      local msg_content = type(msg.content) == "string" and msg.content or ""
      if last_content == msg_content and not last.tool_calls and not msg.tool_calls then
        goto skip_msg
      end
    end
    table.insert(cleaned_messages, msg)
    ::skip_msg::
  end
  messages = cleaned_messages

  -- 如果是最终轮次（总结轮次），移除末尾孤立的 tool 消息
  -- 这些 tool 消息没有对应的 assistant tool_calls（assistant 消息已被过滤或移除）
  -- 会导致 format_messages 添加 [工具结果缺失] 占位消息，影响 AI 响应
  if is_final_round and #messages > 0 then
    local last_msg = messages[#messages]
    if last_msg.role == "tool" then
      -- 检查倒数第二条消息是否为 assistant（带 tool_calls）
      if #messages >= 2 then
        local prev_msg = messages[#messages - 1]
        if not (prev_msg.role == "assistant" and prev_msg.tool_calls) then
          -- 倒数第二条不是带 tool_calls 的 assistant，移除孤立的 tool 消息
          table.remove(messages)
        end
      else
        -- 只有一条 tool 消息，移除它
        table.remove(messages)
      end
    end
  end

  -- 如果已有其他 generation 在生成中，跳过（防止竞态）
  if state.is_generating and state.current_generation_id ~= generation_id then
    logger.warn(
      "handle_tool_result: 其他 generation 正在生成中，跳过 (current="
        .. tostring(state.current_generation_id)
        .. ", expected="
        .. tostring(generation_id)
        .. ")"
    )
    return
  end

  -- 如果已经是当前 generation 且正在生成中，跳过（防止重复触发）
  if state.is_generating and state.current_generation_id == generation_id then
    logger.warn("handle_tool_result: 当前 generation 已在生成中，跳过")
    return
  end

  -- 如果 is_final_round 为 true，强制释放生成状态（防止 stop_tool_loop 后卡住）
  if is_final_round and state.is_generating then
    logger.debug("handle_tool_result: is_final_round=true，强制释放生成状态")
    state.is_generating = false
    state.current_generation_id = nil
  end

  -- 设置生成状态
  state.is_generating = true
  state.current_generation_id = generation_id

  -- 防御性检查：确保 active_generations 表存在（防止竞态条件或模块重载导致 nil）
  if not state.active_generations then
    state.active_generations = {}
  end

  -- 防御性检查：如果 generation_id 为 nil，跳过处理（防止竞态条件导致崩溃）
  if not generation_id then
    logger.warn("handle_tool_result: generation_id 为 nil，跳过")
    state.is_generating = false
    state.current_generation_id = nil
    return
  end

  -- 更新或创建 generation 记录
  if not state.active_generations[generation_id] then
    state.active_generations[generation_id] = {
      start_time = os.time(),
      messages = messages,
      session_id = session_id,
      window_id = window_id,
      options = options,
      model_index = model_index,
      ai_preset = ai_preset,
      retry_count = 0,
      accumulated_usage = accumulated_usage,
      last_reasoning_content = last_reasoning,
    }
  else
    local gen = state.active_generations[generation_id]
    if not gen then
      -- 竞态条件：generation 记录已被清理（如 cancel_generation），重新创建
      logger.warn(
        "handle_tool_result: generation 记录已被清理，重新创建 (generation_id="
          .. tostring(generation_id)
          .. ")"
      )
      state.active_generations[generation_id] = {
        start_time = os.time(),
        messages = messages,
        session_id = session_id,
        window_id = window_id,
        options = options,
        model_index = model_index,
        ai_preset = ai_preset,
        retry_count = 0,
        accumulated_usage = accumulated_usage,
        last_reasoning_content = last_reasoning,
      }
    else
      gen.messages = messages
      gen.options = options
      gen.ai_preset = ai_preset -- 修复：更新 ai_preset，确保后续 HTTP 请求使用正确的配置
      gen.model_index = model_index
      gen.accumulated_usage = accumulated_usage
      gen.last_reasoning_content = last_reasoning
    end
  end

  -- 构建并发送 AI 请求
  local formatted = format_messages(messages)
  local stream_val = (options.stream ~= nil) and options.stream or (ai_preset.stream ~= false)

  local request = build_request({
    messages = formatted,
    options = vim.tbl_extend("force", options, {
      model = ai_preset.model_name or options.model,
      temperature = ai_preset.temperature or options.temperature,
      max_tokens = ai_preset.max_tokens or options.max_tokens,
      stream = stream_val,
    }),
    session_id = session_id,
    generation_id = generation_id,
  })

  -- 标记是否是最后一轮（orchestrator 会在请求中附加特殊标记）
  if is_final_round then
    -- 在请求中不包含 tools，强制 AI 返回文本响应
    request.tools = nil
    request.tool_choice = nil
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_STARTED,
    data = {
      generation_id = generation_id,
      formatted_messages = formatted,
      request = request,
      session_id = session_id,
      window_id = window_id,
      is_tool_loop = true,
      is_final_round = is_final_round,
    },
  })

  if request.stream then
    M._send_stream_request(generation_id, request, {
      session_id = session_id,
      window_id = window_id,
      options = options,
      is_tool_loop = true,
      is_final_round = is_final_round,
    })
  else
    M._send_non_stream_request(generation_id, request, {
      session_id = session_id,
      window_id = window_id,
      options = options,
      is_tool_loop = true,
      is_final_round = is_final_round,
    })
  end
end

--- 处理流式完成
function M.handle_stream_completed(data)
  local generation_id = data.generation_id
  if not state.active_generations[generation_id] then
    return
  end
  M._finalize_generation(generation_id, data.full_response, {
    session_id = data.session_id,
    window_id = data.window_id,
    reasoning_text = data.reasoning_text,
    usage = data.usage or {},
  })
end

--- 处理生成错误
function M.handle_generation_error(generation_id, error_msg)
  local generation = state.active_generations[generation_id]
  if not generation then
    return
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.GENERATION_ERROR,
    data = {
      generation_id = generation_id,
      error_msg = error_msg,
      session_id = generation.session_id,
      window_id = generation.window_id,
    },
  })

  state.active_generations[generation_id] = nil
  state.is_generating = false
  state.current_generation_id = nil

  local hm_ok, hm = pcall(require, "NeoAI.core.history.manager")
  if hm_ok and hm and hm._save then
    hm._save()
  end

  -- 刷新 LSP 延迟清理队列
  local ok_lsp, lsp_module = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
  if ok_lsp and lsp_module and lsp_module.flush_deferred_cleanups then
    lsp_module.flush_deferred_cleanups()
  end
end

--- 取消生成
function M.cancel_generation()
  -- 清理 reasoning 节流定时器
  if _reasoning_throttle.timer then
    pcall(_reasoning_throttle.timer.stop, _reasoning_throttle.timer)
    pcall(_reasoning_throttle.timer.close, _reasoning_throttle.timer)
    _reasoning_throttle.timer = nil
  end
  _reasoning_throttle.pending_content = ""
  _reasoning_throttle.generation_id = nil
  _reasoning_throttle.processor = nil
  _reasoning_throttle.params = nil

  -- 即使 state.is_generating 为 false，也清理可能残留的请求
  local generation_id = state.current_generation_id
  local generation = state.active_generations[generation_id]

  -- 直接设置所有会话的停止标志，不调用 request_stop
  -- request_stop 会清空 active_tool_calls 并调度 _on_tools_complete，触发总结轮次
  -- cancel_generation 是用户强制取消，不应该触发总结
  local tool_orc = require("NeoAI.core.ai.tool_orchestrator")
  if generation and generation.session_id then
    local ss = tool_orc.get_session_state and tool_orc.get_session_state(generation.session_id)
    if ss then
      ss.stop_requested = true
      ss.user_cancelled = true -- 标记为用户取消，不触发总结
      ss.active_tool_calls = {}
    end
  else
    -- 没有 session_id 时，停止所有会话
    -- 遍历 tool_orchestrator 中的所有会话
    local all_sessions = tool_orc.get_all_session_ids and tool_orc.get_all_session_ids()
    if all_sessions then
      for _, sid in ipairs(all_sessions) do
        local ss = tool_orc.get_session_state(sid)
        if ss then
          ss.stop_requested = true
          ss.user_cancelled = true -- 标记为用户取消，不触发总结
          ss.active_tool_calls = {}
        end
      end
    end
  end

  -- 取消所有 HTTP 请求（jobstop 会触发 on_exit 回调，但此时 stop_requested 已设置）
  http_client.cancel_all_requests()

  if generation then
    -- 获取累积用量信息，用于取消时保存到历史
    local accumulated_usage = generation.accumulated_usage or {}
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.GENERATION_CANCELLED,
      data = {
        generation_id = generation_id,
        session_id = generation.session_id,
        window_id = generation.window_id,
        usage = accumulated_usage,
      },
    })
    if generation_id then
      state.active_generations[generation_id] = nil
    end
  else
    -- 仍然触发取消事件，让界面更新状态
    vim.api.nvim_exec_autocmds("User", {
      pattern = event_constants.GENERATION_CANCELLED,
      data = { generation_id = nil, session_id = nil, window_id = nil },
    })
  end

  -- 检查是否有活跃的工具循环，有则显示通知
  local tool_orc = require("NeoAI.core.ai.tool_orchestrator")
  local has_active_loop = tool_orc.is_executing()
  if state.is_generating or has_active_loop then
    vim.notify("[NeoAI] 已停止生成", vim.log.levels.INFO)
  end

  state.is_generating = false
  state.current_generation_id = nil

  local hm_ok, hm = pcall(require, "NeoAI.core.history.manager")
  if hm_ok and hm and hm._save then
    hm._save()
  end

  -- 刷新 LSP 延迟清理队列
  local ok_lsp, lsp_module = pcall(require, "NeoAI.tools.builtin.neovim_lsp")
  if ok_lsp and lsp_module and lsp_module.flush_deferred_cleanups then
    lsp_module.flush_deferred_cleanups()
  end
end

-- ========== 工具管理 ==========

function M.set_tools(tools)
  state.tools = tools or {}
  state.tool_definitions = {}

  -- 注册工具到 tool_registry，使 tool_executor 能通过注册表找到工具
  local tool_registry = require("NeoAI.tools.tool_registry")

  for name, def in pairs(state.tools) do
    if def.func then
      -- 如果工具已注册，跳过（避免重复注册日志刷屏）
      if not tool_registry.exists(name) then
        -- 注册到 tool_registry
        local tool_def = {
          name = name,
          func = def.func,
          description = def.description or ("执行 " .. name .. " 操作"),
          parameters = def.parameters,
          category = def.category or "ai",
        }
        pcall(tool_registry.register, tool_def)
      end

      -- 构建 AI 工具定义（用于发送给 LLM）
      local tf = { name = name, description = def.description or ("执行 " .. name .. " 操作") }
      local params = def.parameters
      if params and type(params) == "table" then
        local has_props = false
        if params.properties then
          for _, _ in pairs(params.properties) do
            has_props = true
            break
          end
        end
        if has_props then
          local cp = { type = params.type or "object", properties = params.properties }
          if params.required and type(params.required) == "table" and #params.required > 0 then
            cp.required = params.required
          end
          tf.parameters = cp
        end
      end
      table.insert(state.tool_definitions, { type = "function", ["function"] = tf })
    end
  end

  tool_orchestrator.set_tools(state.tools)
end

-- ========== 公共接口 ==========

function M.process_query(query, options)
  if not state.initialized then
    error("AI engine not initialized")
  end
  state.first_request = true
  tool_orchestrator.reset_iteration()
  -- 注意：process_query 没有 session_id，需要调用方传入

  local messages = { { role = "user", content = query } }
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_constants.USER_MESSAGE_SENT,
    data = { message = messages[1], session_id = options and options.session_id, timestamp = os.time() },
  })
  return M.generate_response(messages, { options = options })
end

function M.get_status()
  return {
    initialized = state.initialized,
    is_generating = state.is_generating,
    current_generation_id = state.current_generation_id,
    active_generations_count = vim.tbl_count(state.active_generations),
    tools_available = next(state.tools) ~= nil,
    tool_orchestrator = { current_iteration = tool_orchestrator.get_current_iteration() },
    http_client = http_client.get_state(),
  }
end

function M.cleanup_event_listeners()
  for _, id in pairs(state.event_listeners) do
    if id then
      pcall(vim.api.nvim_del_autocmd, id)
    end
  end
  state.event_listeners = {}
end

function M.shutdown()
  if not state.initialized then
    return
  end
  -- 清理 reasoning 节流定时器
  if _reasoning_throttle.timer then
    pcall(_reasoning_throttle.timer.stop, _reasoning_throttle.timer)
    pcall(_reasoning_throttle.timer.close, _reasoning_throttle.timer)
    _reasoning_throttle.timer = nil
  end
  _reasoning_throttle.pending_content = ""
  _reasoning_throttle.generation_id = nil
  _reasoning_throttle.processor = nil
  _reasoning_throttle.params = nil

  if state.is_generating then
    M.cancel_generation()
  end
  http_client.shutdown()
  M.cleanup_event_listeners()
  state.active_generations = {}
  state.initialized = false
  state.is_generating = false
  state.current_generation_id = nil
end

-- ========== 自动命名会话 ==========

function M.auto_name_session(session_id, user_msg, callback)
  if not state.initialized then
    if callback then
      callback(false, "AI engine not initialized")
    end
    return
  end
  if not user_msg or user_msg == "" then
    if callback then
      callback(false, "无用户消息")
    end
    return
  end

  local naming_text = user_msg:sub(1, 200)
  vim.schedule(function()
    local preset = resolve_scenario_config("naming")
    if not preset or not preset.base_url or not preset.api_key then
      preset = resolve_scenario_config("chat")
    end
    if not preset or not preset.base_url or not preset.api_key then
      if callback then
        callback(false, "未配置 AI 提供商")
      end
      return
    end

    local request = {
      model = preset.model_name or preset.model or "",
      messages = {
        {
          role = "system",
          content = "你是一个会话命名助手。根据用户的第一条消息，生成一个简短（不超过20个字符）且有意义的会话名称。只返回名称本身，不要加引号、标点或解释。",
        },
        { role = "user", content = "请为以下对话生成一个简短的名称：" .. naming_text },
      },
      temperature = 0.3,
      max_tokens = 50,
      stream = false,
    }

    local gid = "naming_" .. session_id .. "_" .. os.time()
    local response, err = http_client.send_request({
      request = request,
      generation_id = gid,
      base_url = preset.base_url,
      api_key = preset.api_key,
      timeout = preset.timeout or 10000,
      api_type = preset.api_type or "openai",
      provider_config = preset,
    })

    if err then
      if callback then
        callback(false, "命名请求失败: " .. tostring(err))
      end
      return
    end
    if not response or not response.choices or #response.choices == 0 then
      if callback then
        callback(false, "命名响应无效")
      end
      return
    end

    local msg = response.choices[1].message
    local name = msg.content or ""
    if name == "" and msg.reasoning_content then
      name = msg.reasoning_content
    end
    name = name:gsub("^[%s\"'「『]+(.-)[%s\"'」』]+$", "%1")
    name = name:gsub("^%s*(.-)%s*$", "%1")
    name = name:gsub("[。，！？、；：]$", "")
    if #name > 30 then
      name = name:sub(1, 30) .. "…"
    end
    if name == "" then
      if callback then
        callback(false, "生成的名称无效")
      end
      return
    end
    if callback then
      callback(true, name)
    end
  end)
end

-- ========== 兼容接口 ==========

function M.build_request(params)
  return build_request(params)
end
function M.format_messages(msgs)
  return format_messages(msgs)
end
function M.build_tool_result_message(id, r, n)
  return build_tool_result_message(id, r, n)
end
function M.add_tool_call_to_history(msgs, tc, tr)
  return add_tool_call_to_history(msgs, tc, tr)
end
function M.reset_first_request()
  state.first_request = true
end

function M.estimate_tokens(text)
  if not text or text == "" then
    return 0
  end
  return math.ceil(#text / 4)
end

function M.estimate_message_tokens(messages)
  if not messages then
    return 0
  end
  local total = 0
  for _, msg in ipairs(messages) do
    total = total + 3
    if msg.content then
      total = total + M.estimate_tokens(msg.content)
    end
    if msg.role then
      total = total + M.estimate_tokens(msg.role)
    end
    if msg.name then
      total = total + M.estimate_tokens(msg.name)
    end
  end
  return total
end

function M.estimate_request_tokens(request)
  if not request then
    return 0
  end
  local total = 0
  if request.messages then
    for _, msg in ipairs(request.messages) do
      if msg.content then
        if type(msg.content) == "string" then
          local cc = 0
          for _ in msg.content:gmatch("[\228-\233][\128-\191][\128-\191]") do
            cc = cc + 1
          end
          local ec = #msg.content - cc * 3
          total = total + math.ceil(cc * 1.5) + math.ceil(ec / 4)
        elseif type(msg.content) == "table" then
          local ok, s = pcall(vim.json.encode, msg.content)
          total = total + (ok and math.ceil(#s / 4) or 100)
        end
      end
    end
  end
  if request.tools then
    for _, t in ipairs(request.tools) do
      local ok, s = pcall(vim.json.encode, t)
      total = total + (ok and math.ceil(#s / 4) or 50)
    end
  end
  return total
end

-- 工具编排器接口转发
function M.start_async_loop(params)
  return tool_orchestrator.start_async_loop(params)
end
function M.on_generation_complete(data)
  return tool_orchestrator.on_generation_complete(data)
end
function M.get_current_iteration(session_id)
  return tool_orchestrator.get_current_iteration(session_id)
end
function M.get_tools()
  return tool_orchestrator.get_tools()
end
function M.is_executing(session_id)
  return tool_orchestrator.is_executing(session_id)
end
function M.get_loop_status()
  return "deprecated"
end

return M
