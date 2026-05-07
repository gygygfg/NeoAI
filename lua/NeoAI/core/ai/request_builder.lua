---@module "NeoAI.core.ai.request_builder"
--- AI 请求构建器
--- 职责：构建 AI API 请求体、格式化消息、构建工具结果消息
---
--- 状态管理：
---   tool_definitions、first_request、tool_call_counter 均为模块闭包内私有状态
---   协程上下文共享数据（session_id、ai_preset 等）通过 state_manager 访问

local logger = require("NeoAI.utils.logger")
local http_utils = require("NeoAI.core.ai.http_utils")

-- ========== 闭包内私有状态 ==========
local _tool_definitions = {}
local _first_request = true
local tool_call_counter = 0

-- ========== 辅助函数 ==========

--- 获取工具定义列表
local function get_tool_definitions()
  return _tool_definitions or {}
end

--- 获取首次请求标志
local function get_first_request()
  return _first_request ~= false
end

--- 设置首次请求标志
local function set_first_request(val)
  _first_request = val
end

-- ========== 公共接口 ==========
local M = {}

--- 格式化消息（带多层去重）
function M.format_messages(messages)
  if not messages then return {} end

  -- 第一步：预去重，移除连续重复的消息
  local deduped = {}
  for _, msg in ipairs(messages) do
    local last = deduped[#deduped]
    if last and last.role == msg.role and last.role ~= "tool" then
      local last_content = type(last.content) == "string" and last.content or ""
      local msg_content = type(msg.content) == "string" and msg.content or ""
      if last_content == msg_content then goto continue end
    end
    if last and last.role == "tool" and msg.role == "tool" then
      if last.tool_call_id == msg.tool_call_id then goto continue end
    end
    table.insert(deduped, msg)
    ::continue::
  end
  messages = deduped

  -- 第二步：过滤 assistant 消息中的 UI 折叠文本（{{{ ... }}}）
  local filtered = {}
  for _, msg in ipairs(messages) do
    if msg.role == "assistant" and msg.content and type(msg.content) == "string" then
      local content = msg.content
      local lines = vim.split(content, "\n")
      local in_fold = false
      local cleaned = {}
      for _, line in ipairs(lines) do
        if line:find("^{{{") then in_fold = true end
        if not in_fold then table.insert(cleaned, line) end
        if in_fold and line:find("^}}}") then in_fold = false end
      end
      local cleaned_str = vim.trim(table.concat(cleaned, "\n"))
      if cleaned_str ~= content then
        local new_msg = vim.deepcopy(msg)
        new_msg.content = cleaned_str
        table.insert(filtered, new_msg)
      else
        table.insert(filtered, msg)
      end
    else
      table.insert(filtered, msg)
    end
  end
  messages = filtered

  -- 第三步：收集 tool_call_id 并处理占位
  local result = {}
  local expected_ids = {}
  for _, msg in ipairs(messages) do
    if msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        if tc.id and tc.id ~= "" then
          expected_ids[tc.id] = (expected_ids[tc.id] or 0) + 1
        else
          local pid = "call_placeholder_" .. os.time() .. "_" .. math.random(10000, 99999)
          expected_ids[pid] = (expected_ids[pid] or 0) + 1
        end
      end
    end
  end
  for _, msg in ipairs(messages) do
    local fm = { role = msg.role or "user" }
    if msg.content then fm.content = type(msg.content) == "table" and msg.content or tostring(msg.content) end
    if msg.tool_calls then fm.tool_calls = msg.tool_calls end
    if msg.role == "tool" then
      if msg.tool_call_id and msg.tool_call_id ~= "" then
        fm.tool_call_id = msg.tool_call_id
        if expected_ids[msg.tool_call_id] then
          expected_ids[msg.tool_call_id] = expected_ids[msg.tool_call_id] - 1
          if expected_ids[msg.tool_call_id] <= 0 then expected_ids[msg.tool_call_id] = nil end
        end
      else
        fm.role = "user"
      end
      if fm.content == nil then fm.content = "" end
    elseif msg.tool_call_id then
      fm.tool_call_id = msg.tool_call_id
    end
    if msg.name then fm.name = msg.name end
    if msg.reasoning_content then fm.reasoning_content = msg.reasoning_content end
    table.insert(result, fm)
  end

  -- 第四步：添加缺失的 tool 占位消息
  local missing = {}
  for id, count in pairs(expected_ids) do
    if count and count > 0 then table.insert(missing, id) end
  end
  for _, id in ipairs(missing) do
    table.insert(result, { role = "tool", tool_call_id = id, content = "[工具结果缺失]" })
  end
  return result
end

--- 构建工具结果消息
function M.build_tool_result_message(tool_call_id, result, tool_name)
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
  if tool_name then msg.name = tool_name end
  return msg
end

--- 添加工具调用到消息历史
function M.add_tool_call_to_history(messages, tool_call, tool_result)
  local updated = vim.deepcopy(messages or {})
  local tf = tool_call["function"] or tool_call.func
  if not tool_call or not tf or not tf.name then return updated end
  local safe_id = tool_call.id
  if not safe_id or safe_id == "" then
    safe_id = "call_" .. os.time() .. "_" .. math.random(10000, 99999)
    tool_call.id = safe_id
  end
  table.insert(updated, { role = "assistant", tool_calls = { tool_call } })
  table.insert(updated, M.build_tool_result_message(safe_id, tool_result, tf.name))
  return updated
end

--- 获取工具定义列表
function M.get_tool_definitions()
  return _tool_definitions or {}
end

--- 设置工具定义列表
function M.set_tool_definitions(defs)
  _tool_definitions = defs or {}
end

--- 重置首次请求标志
function M.reset_first_request()
  _first_request = true
end

--- 构建 AI 请求体
function M.build_request(params)
  local messages = params.messages or {}
  local options = params.options or {}
  local session_id = params.session_id

  -- 解码消息中的 %%XX URL 编码（使用 http_utils 替代 http_client 跨模块依赖）
  for _, msg in ipairs(messages) do
    if msg.content and type(msg.content) == "string" then
      msg.content = http_utils.decode_special_chars(msg.content)
    end
    if msg.reasoning_content and type(msg.reasoning_content) == "string" then
      msg.reasoning_content = http_utils.decode_special_chars(msg.reasoning_content)
    end
    if msg.tool_calls and type(msg.tool_calls) == "table" then
      for _, tc in ipairs(msg.tool_calls) do
        local func = tc["function"] or tc.func
        if func and func.arguments and type(func.arguments) == "string" then
          func.arguments = http_utils.decode_special_chars(func.arguments)
        end
      end
    end
  end

  tool_call_counter = tool_call_counter + 1
  local generation_id = params.generation_id
    or (os.time() .. "_" .. math.random(1000, 9999) .. "_" .. tool_call_counter)

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
    if use_stream == nil then use_stream = true end
    request = {
      model = options.model or "gpt-4",
      messages = messages,
      max_tokens = options.max_tokens or 2000,
      stream = use_stream,
    }
  end

  if mode ~= "fim" then
    local reasoning_enabled = (options.reasoning_enabled ~= nil) and options.reasoning_enabled or false
    local model_name = options.model or ""

    if reasoning_enabled then
      local raw_effort = options.reasoning_effort or "high"
      local effort_map = { low = "low", medium = "low", high = "high", xhigh = "max", max = "max" }
      request.extra_body = { thinking = { type = "enabled" }, reasoning_effort = effort_map[raw_effort] or "high" }
    else
      request.temperature = options.temperature or 0.7
      request.extra_body = { thinking = { type = "disabled" } }
      if model_name and type(model_name) == "string" and model_name:lower():find("reasoner") then
        local new_model = model_name:gsub("reasoner", "chat"):gsub("re$", "")
        if new_model == model_name then new_model = "deepseek-chat" end
        request.model = new_model
      end
    end

    -- 强制工具调用时禁用思考模式
    local has_forced_tool = (
      options.tool_choice and type(options.tool_choice) == "table" and options.tool_choice.type == "function"
    ) or (params.tool_choice and type(params.tool_choice) == "table" and params.tool_choice.type == "function")
    if has_forced_tool and request.extra_body and request.extra_body.thinking then
      request.extra_body.thinking = nil
      request.extra_body.reasoning_effort = nil
      if not next(request.extra_body) then request.extra_body = nil end
      request.temperature = options.temperature or 0.7
    end

    -- 工具定义
    local tools_enabled
    if options.tools_enabled ~= nil then
      tools_enabled = options.tools_enabled
    else
      local core = require("NeoAI.core")
      local ok, full_config = pcall(core.get_config)
      full_config = ok and full_config or {}
      if full_config and full_config.tools and full_config.tools.enabled ~= nil then
        tools_enabled = full_config.tools.enabled
      elseif full_config and full_config.ai then
        tools_enabled = full_config.ai.tools_enabled
      end
    end

    local is_first = get_first_request()
    if is_first then set_first_request(false) end

    local defs = get_tool_definitions()
    if tools_enabled and #defs > 0 then
      local model_lower = (options.model or ""):lower()
      if not model_lower:find("reasoner") then
        local tools_to_use = defs
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

  if session_id then request.session_id = session_id end
  request.generation_id = generation_id
  return request
end

--- 估算 token 数
function M.estimate_tokens(text)
  if not text or text == "" then return 0 end
  return math.ceil(#text / 4)
end

function M.estimate_message_tokens(messages)
  if not messages then return 0 end
  local total = 0
  for _, msg in ipairs(messages) do
    total = total + 3
    if msg.content then total = total + M.estimate_tokens(msg.content) end
    if msg.role then total = total + M.estimate_tokens(msg.role) end
    if msg.name then total = total + M.estimate_tokens(msg.name) end
  end
  return total
end

function M.estimate_request_tokens(request)
  if not request then return 0 end
  local total = 0
  if request.messages then
    for _, msg in ipairs(request.messages) do
      if msg.content then
        if type(msg.content) == "string" then
          local cc = 0
          for _ in msg.content:gmatch("[\228-\233][\128-\191][\128-\191]") do cc = cc + 1 end
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

return M
