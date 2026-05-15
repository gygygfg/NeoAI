---@module "NeoAI.core.ai.request_handler"
--- AI 请求处理器
--- 职责：构建 AI API 请求体、适配各 API 提供商格式、检测异常响应并管理重试
---
--- 子模块划分：
---   builder - 请求构建：构建请求体、格式化消息、工具结果消息、Token 估算
---   adapter - API 适配：将统一请求格式转换为各提供商原生格式（OpenAI/Anthropic/Google）
---   retry   - 响应重试：检测异常响应（重复/截断/空响应）并触发指数退避重试
---
--- 注意：engine 中的重试逻辑（_handle_stream_end/_handle_ai_response 中的异常检测）
--- 也已委托至此模块的 detect_abnormal_response/can_retry/get_retry_delay 接口。
--- engine 不再维护独立的 retry_count/max_retries 状态，统一由此模块管理。

local logger = require("NeoAI.utils.logger")
local json = require("NeoAI.utils.json")

local M = {}

-- ====================================================================
-- 第一部分：Builder - 请求构建
-- ====================================================================

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

-- ========== Builder 公共接口 ==========

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
    if msg.tool_calls then
      -- tool_calls 中的 arguments 在整个系统内部保持 Lua table 形式
      -- http_utils 发送前会统一编码为 JSON 字符串
      fm.tool_calls = msg.tool_calls
    end
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

  -- 消息中的 content/reasoning_content 已直接来自 json.decode 的原始值
  -- tool_calls.arguments 已在 http_utils 中解析为 Lua table
  -- 无需额外的 URL 解码

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



-- ====================================================================
-- 第二部分：Adapter - API 适配器
-- ====================================================================

-- ========== 适配器注册表 ==========

local adapters = {}

--- 注册适配器
--- @param api_type string API 类型名称
--- @param adapter table 适配器，包含 transform_request 和 transform_response 方法
function M.register_adapter(api_type, adapter)
  adapters[api_type] = adapter
  logger.debug(string.format("Request adapter registered: %s", api_type))
end

--- 获取适配器
--- @param api_type string API 类型名称
--- @return table|nil 适配器
function M.get_adapter(api_type)
  return adapters[api_type or "openai"]
end

-- ========== OpenAI 适配器（默认） ==========

M.register_adapter("openai", {
  name = "OpenAI 兼容格式",

  --- 转换请求体为 OpenAI 格式
  --- @param request table 统一请求格式
  --- @param provider_config table 提供商配置
  --- @return table OpenAI 格式的请求体
  transform_request = function(request, provider_config)
    -- OpenAI 格式已经是标准格式，直接返回
    -- 但需要处理 extra_body（如 DeepSeek Thinking Mode）
    local result = {}
    for k, v in pairs(request) do
      if k ~= "extra_body" then
        result[k] = v
      end
    end
    -- 将 extra_body 中的字段合并到顶层
    if request.extra_body then
      for k, v in pairs(request.extra_body) do
        result[k] = v
      end
    end
    return result
  end,

  --- 转换响应为统一格式
  --- @param response table API 原始响应
  --- @return table 统一格式的响应
  transform_response = function(response)
    -- OpenAI 格式已经是标准格式
    return response
  end,

  --- 获取请求头
  --- @param api_key string API 密钥
  --- @return table HTTP 请求头
  get_headers = function(api_key)
    return {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. api_key,
    }
  end,
})

-- ========== Anthropic 适配器 ==========

M.register_adapter("anthropic", {
  name = "Anthropic Messages API",

  --- 转换请求体为 Anthropic Messages API 格式
  --- @param request table 统一请求格式
  --- @param provider_config table 提供商配置
  --- @return table Anthropic 格式的请求体
  transform_request = function(request, provider_config)
    local anthropic_request = {
      model = request.model,
      max_tokens = request.max_tokens or 4096,
      stream = request.stream or false,
    }

    -- 处理 system 消息（Anthropic 将 system 作为顶层字段）
    local messages = {}
    local system_content = nil

    if request.messages then
      for _, msg in ipairs(request.messages) do
        if msg.role == "system" then
          -- Anthropic 的 system 消息是顶层字段
          if type(msg.content) == "string" then
            system_content = msg.content
          elseif type(msg.content) == "table" then
            system_content = msg.content
          end
        elseif msg.role == "tool" then
          -- Anthropic 的工具结果格式：role = "user"，content 包含 tool_result 块
          local tool_result_content = ""
          if type(msg.content) == "string" then
            tool_result_content = msg.content
          elseif type(msg.content) == "table" then
            local ok, encoded = pcall(json.encode, msg.content)
            tool_result_content = ok and encoded or tostring(msg.content)
          else
            tool_result_content = tostring(msg.content)
          end

          table.insert(messages, {
            role = "user",
            content = {
              {
                type = "tool_result",
                tool_use_id = msg.tool_call_id or "",
                content = tool_result_content,
              },
            },
          })
        elseif msg.role == "assistant" and msg.tool_calls then
          -- Anthropic 的工具调用格式：content 包含 tool_use 块
          local content_blocks = {}

          -- 如果有文本内容，先添加 text 块
          if msg.content and msg.content ~= "" then
            table.insert(content_blocks, {
              type = "text",
              text = msg.content,
            })
          end

          -- 添加 tool_use 块
          -- arguments 已在 http_utils 中解析为 Lua table
          for _, tc in ipairs(msg.tool_calls) do
            local tool_func = tc["function"] or tc.func
            local arguments = {}
            if tool_func and tool_func.arguments then
              if type(tool_func.arguments) == "table" then
                arguments = tool_func.arguments
              end
            end

            table.insert(content_blocks, {
              type = "tool_use",
              id = tc.id or ("toolu_" .. tostring(os.time())),
              name = tool_func and tool_func.name or "",
              input = arguments,
            })
          end

          table.insert(messages, {
            role = "assistant",
            content = content_blocks,
          })
        else
          -- 普通 user/assistant 消息
          local anthropic_msg = {
            role = msg.role,
            content = msg.content or "",
          }

          -- 处理 reasoning_content（Anthropic 不支持，但保留以防后续支持）
          if msg.reasoning_content then
            anthropic_msg.reasoning_content = msg.reasoning_content
          end

          table.insert(messages, anthropic_msg)
        end
      end
    end

    anthropic_request.messages = messages

    -- 设置 system 字段
    if system_content then
      anthropic_request.system = system_content
    end

    -- 处理工具定义（Anthropic 的 tools 格式）
    if request.tools and #request.tools > 0 then
      local anthropic_tools = {}
      for _, tool in ipairs(request.tools) do
        if tool.type == "function" and tool["function"] then
          table.insert(anthropic_tools, {
            name = tool["function"].name,
            description = tool["function"].description or "",
            input_schema = tool["function"].parameters or {
              type = "object",
              properties = {},
            },
          })
        end
      end
      if #anthropic_tools > 0 then
        anthropic_request.tools = anthropic_tools
      end
    end

    -- 处理 thinking/extra_body（Anthropic 原生支持 extended thinking）
    if request.extra_body and request.extra_body.thinking then
      anthropic_request.thinking = request.extra_body.thinking
    end

    -- 处理 temperature（Anthropic 支持）
    if request.temperature then
      anthropic_request.temperature = request.temperature
    end

    -- 处理 top_p（Anthropic 支持）
    if request.top_p then
      anthropic_request.top_p = request.top_p
    end

    -- 处理 stop_sequences（Anthropic 支持）
    if request.stop then
      anthropic_request.stop_sequences = type(request.stop) == "table" and request.stop or { request.stop }
    end

    -- 处理 metadata
    if request.metadata then
      anthropic_request.metadata = request.metadata
    end

    return anthropic_request
  end,

  --- 转换 Anthropic 响应为统一格式
  --- @param response table Anthropic 原始响应
  --- @return table 统一格式的响应
  transform_response = function(response)
    -- 转换为 OpenAI 兼容格式
    local unified = {
      id = response.id or "",
      object = "chat.completion",
      created = os.time(),
      model = response.model or "",
      choices = {},
      usage = {},
    }

    if response.content and #response.content > 0 then
      local message = {
        role = "assistant",
        content = "",
        tool_calls = {},
      }

      local text_parts = {}
      local tool_calls = {}

      for _, block in ipairs(response.content) do
        if block.type == "text" then
          table.insert(text_parts, block.text or "")
        elseif block.type == "tool_use" then
          local arguments_table = {}
          if block.input and type(block.input) == "table" then
            arguments_table = block.input
          end

          table.insert(tool_calls, {
            id = block.id or ("toolu_" .. tostring(os.time())),
            type = "function",
            ["function"] = {
              name = block.name or "",
              arguments = arguments_table,
            },
          })
        end
      end

      message.content = table.concat(text_parts, "")

      if #tool_calls > 0 then
        message.tool_calls = tool_calls
      end

      -- 处理 thinking/redacted_thinking（Anthropic extended thinking）
      for _, block in ipairs(response.content) do
        if block.type == "thinking" then
          message.reasoning_content = block.thinking or ""
          break
        elseif block.type == "redacted_thinking" then
          message.reasoning_content = (message.reasoning_content or "") .. "[Redacted Thinking]"
        end
      end

      local finish_reason = response.stop_reason or "stop"
      -- 映射 Anthropic 的 stop_reason 到 OpenAI 格式
      local finish_reason_map = {
        end_turn = "stop",
        stop_sequence = "stop",
        max_tokens = "length",
        tool_use = "tool_calls",
      }

      table.insert(unified.choices, {
        index = 0,
        message = message,
        finish_reason = finish_reason_map[finish_reason] or finish_reason,
        delta = message,
      })
    end

    -- 处理 usage
    if response.usage then
      unified.usage = {
        prompt_tokens = response.usage.input_tokens or 0,
        completion_tokens = response.usage.output_tokens or 0,
        total_tokens = (response.usage.input_tokens or 0) + (response.usage.output_tokens or 0),
      }
    end

    -- 处理 stop_reason 为 tool_use 但没有 content 的情况
    if response.stop_reason == "tool_use" and #unified.choices == 0 then
      -- 这种情况不应该发生，但做防御
      table.insert(unified.choices, {
        index = 0,
        message = {
          role = "assistant",
          content = "",
          tool_calls = {},
        },
        finish_reason = "tool_calls",
      })
    end

    return unified
  end,

  --- 获取 Anthropic 请求头
  --- @param api_key string API 密钥
  --- @return table HTTP 请求头
  get_headers = function(api_key)
    return {
      ["Content-Type"] = "application/json",
      ["x-api-key"] = api_key,
      ["anthropic-version"] = "2023-06-01",
    }
  end,
})

-- ========== Google Gemini 适配器 ==========

M.register_adapter("google", {
  name = "Google Gemini API",

  --- 转换请求体为 Google Gemini 格式
  --- @param request table 统一请求格式
  --- @param provider_config table 提供商配置
  --- @return table Google Gemini 格式的请求体
  transform_request = function(request, provider_config)
    local gemini_contents = {}
    local system_instruction = nil

    if request.messages then
      for _, msg in ipairs(request.messages) do
        if msg.role == "system" then
          -- Gemini 的 system_instruction 是顶层字段
          system_instruction = {
            parts = {
              {
                text = type(msg.content) == "string" and msg.content or tostring(msg.content),
              },
            },
          }
        elseif msg.role == "tool" then
          -- Gemini 的工具结果：role = "function"，parts 包含 functionResponse
          local content = msg.content or ""
          if type(content) ~= "string" then
            local ok, encoded = pcall(json.encode, content)
            content = ok and encoded or tostring(content)
          end

          table.insert(gemini_contents, {
            role = "function",
            parts = {
              {
                functionResponse = {
                  name = msg.name or "",
                  response = {
                    name = msg.name or "",
                    content = content,
                  },
                },
              },
            },
          })
        elseif msg.role == "assistant" and msg.tool_calls then
          -- Gemini 的工具调用：parts 包含 functionCall
          local parts = {}

          -- 如果有文本内容
          if msg.content and msg.content ~= "" then
            table.insert(parts, {
              text = msg.content,
            })
          end

          -- 添加 functionCall
          -- arguments 已在 http_utils 中解析为 Lua table
          for _, tc in ipairs(msg.tool_calls) do
            local tool_func = tc["function"] or tc.func
            local args = {}
            if tool_func and tool_func.arguments then
              if type(tool_func.arguments) == "table" then
                args = tool_func.arguments
              end
            end

            table.insert(parts, {
              functionCall = {
                name = tool_func and tool_func.name or "",
                args = args,
              },
            })
          end

          table.insert(gemini_contents, {
            role = "model",
            parts = parts,
          })
        else
          -- 普通消息
          local gemini_role = msg.role
          if gemini_role == "assistant" then
            gemini_role = "model"
          end

          local content = msg.content or ""
          if type(content) ~= "string" then
            local ok, encoded = pcall(json.encode, content)
            content = ok and encoded or tostring(content)
          end

          table.insert(gemini_contents, {
            role = gemini_role,
            parts = {
              {
                text = content,
              },
            },
          })
        end
      end
    end

    local gemini_request = {
      contents = gemini_contents,
    }

    -- 设置 system_instruction
    if system_instruction then
      gemini_request.system_instruction = system_instruction
    end

    -- 处理 generationConfig
    local generation_config = {}

    if request.temperature then
      generation_config.temperature = request.temperature
    end
    if request.max_tokens then
      generation_config.max_output_tokens = request.max_tokens
    end
    if request.top_p then
      generation_config.top_p = request.top_p
    end
    if request.stop then
      generation_config.stop_sequences = type(request.stop) == "table" and request.stop or { request.stop }
    end

    if next(generation_config) then
      gemini_request.generation_config = generation_config
    end

    -- 处理工具定义
    if request.tools and #request.tools > 0 then
      local gemini_tools = {}
      for _, tool in ipairs(request.tools) do
        if tool.type == "function" and tool["function"] then
          table.insert(gemini_tools, {
            function_declarations = {
              {
                name = tool["function"].name,
                description = tool["function"].description or "",
                parameters = tool["function"].parameters or {
                  type = "object",
                  properties = {},
                },
              },
            },
          })
        end
      end
      if #gemini_tools > 0 then
        gemini_request.tools = gemini_tools
      end
    end

    -- 处理 stream
    if request.stream then
      -- Gemini 流式通过不同的端点处理，这里标记
      gemini_request.stream = true
    end

    return gemini_request
  end,

  --- 转换 Google Gemini 响应为统一格式
  --- @param response table Google Gemini 原始响应
  --- @return table 统一格式的响应
  transform_response = function(response)
    local unified = {
      id = "gemini-" .. tostring(os.time()),
      object = "chat.completion",
      created = os.time(),
      model = response.model or "",
      choices = {},
      usage = {},
    }

    if response.candidates and #response.candidates > 0 then
      local candidate = response.candidates[1]
      local message = {
        role = "assistant",
        content = "",
        tool_calls = {},
      }

      local text_parts = {}
      local tool_calls = {}

      if candidate.content and candidate.content.parts then
        for _, part in ipairs(candidate.content.parts) do
          if part.text then
            table.insert(text_parts, part.text)
          elseif part.functionCall then
            local arguments_table = {}
            if part.functionCall.args and type(part.functionCall.args) == "table" then
              arguments_table = part.functionCall.args
            end

            table.insert(tool_calls, {
              id = "fcall_" .. tostring(os.time()) .. "_" .. tostring(#tool_calls + 1),
              type = "function",
              ["function"] = {
                name = part.functionCall.name or "",
                arguments = arguments_table,
              },
            })
          end
        end
      end

      message.content = table.concat(text_parts, "")

      if #tool_calls > 0 then
        message.tool_calls = tool_calls
      end

      local finish_reason = candidate.finishReason or "STOP"
      local finish_reason_map = {
        STOP = "stop",
        MAX_TOKENS = "length",
        SAFETY = "content_filter",
        RECITATION = "content_filter",
        OTHER = "stop",
        FUNCTION_CALL = "tool_calls",
      }

      table.insert(unified.choices, {
        index = 0,
        message = message,
        finish_reason = finish_reason_map[finish_reason] or "stop",
        delta = message,
      })
    end

    -- 处理 usage
    if response.usageMetadata then
      unified.usage = {
        prompt_tokens = response.usageMetadata.promptTokenCount or 0,
        completion_tokens = response.usageMetadata.candidatesTokenCount or 0,
        total_tokens = (response.usageMetadata.promptTokenCount or 0) + (response.usageMetadata.candidatesTokenCount or 0),
      }
    end

    return unified
  end,

  --- 获取 Google Gemini 请求头
  --- @param api_key string API 密钥
  --- @return table HTTP 请求头
  get_headers = function(api_key)
    return {
      ["Content-Type"] = "application/json",
      ["x-goog-api-key"] = api_key,
    }
  end,
})

-- ========== 通用适配器接口 ==========

--- 转换请求体
--- @param request table 统一请求格式
--- @param api_type string API 类型
--- @param provider_config table 提供商配置
--- @return table 转换后的请求体
function M.transform_request(request, api_type, provider_config)
  local adapter = adapters[api_type or "openai"]
  if not adapter then
    logger.warn(string.format("No adapter found for api_type '%s', falling back to openai", api_type or "nil"))
    adapter = adapters["openai"]
  end
  return adapter.transform_request(request, provider_config)
end

--- 转换响应
--- @param response table API 原始响应
--- @param api_type string API 类型
--- @return table 转换后的响应
function M.transform_response(response, api_type)
  local adapter = adapters[api_type or "openai"]
  if not adapter then
    return response
  end
  return adapter.transform_response(response)
end

--- 获取请求头
--- @param api_key string API 密钥
--- @param api_type string API 类型
--- @return table HTTP 请求头
function M.get_headers(api_key, api_type)
  local adapter = adapters[api_type or "openai"]
  if not adapter then
    -- 默认使用 Bearer token
    return {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. api_key,
    }
  end
  return adapter.get_headers(api_key)
end

--- 获取适配器名称
--- @param api_type string API 类型
--- @return string 适配器名称
function M.get_adapter_name(api_type)
  local adapter = adapters[api_type or "openai"]
  return adapter and adapter.name or "Unknown"
end

--- 获取所有已注册的适配器类型
--- @return table 适配器类型列表
function M.get_available_types()
  local types = {}
  for t, _ in pairs(adapters) do
    table.insert(types, t)
  end
  table.sort(types)
  return types
end



-- ====================================================================
-- 第三部分：Retry - 响应重试
-- ====================================================================

-- ========== 配置 ==========

local retry_config = {
  max_retries = 5,
  retry_delays = { 1000, 2000, 4000, 8000, 16000 }, -- 指数退避（毫秒）
}

-- ========== 总结内容检测 ==========

--- 判断 AI 返回的内容是否为总结性质
--- 当内容包含总结类关键词时，视为正常结束，不触发重试也不触发额外总结轮次
--- @param content string AI 响应文本
--- @return boolean 是否为总结内容
function M.is_summary_content(content)
  if not content or content == "" then
    return false
  end

  -- 总结类关键词列表（不区分大小写）
  local summary_keywords = {
    "总结",
    "汇总",
    "概述",
    "小结",
    "综上所述",
    "总而言之",
    "任务完成",
    "已完成",
    "已完成的任务",
    "最终结果",
    "最终回复",
    "以上是",
    "以上就是",
    "summary",
    "summarize",
    "summarise",
    "in summary",
    "in conclusion",
    "to summarize",
    "to sum up",
    "all tasks completed",
    "task completed",
    "tasks completed",
    "here is the summary",
    "here's the summary",
    "here are the results",
    "here's the result",
    "final result",
    "final response",
    "that's all",
    "that is all",
  }

  local lower_content = content:lower()
  for _, keyword in ipairs(summary_keywords) do
    if lower_content:find(keyword, 1, true) then
      return true
    end
  end

  return false
end

-- ========== 异常检测 ==========

--- 检测响应文本中是否存在重复段落
--- 策略：将文本按换行分割，检查是否有相同的行/块重复出现
--- @param text string 响应文本
--- @return boolean 是否检测到重复
local function has_repeated_content(text)
  if not text or text == "" then
    return false
  end

  -- 按行分割
  local lines = vim.split(text, "\n")
  if #lines < 3 then
    return false -- 行数太少，无法判断重复
  end

  -- 检查是否有连续重复的行
  for i = 1, #lines - 1 do
    local line = vim.trim(lines[i])
    local next_line = vim.trim(lines[i + 1])
    if line ~= "" and line == next_line then
      logger.debug("[request_handler.retry] 检测到连续重复行: " .. line:sub(1, 50))
      return true
    end
  end

  -- 检查是否有重复的段落（以 ## 开头的标题行重复）
  local headers = {}
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed:match("^##+%s+") then
      if headers[trimmed] then
        logger.debug("[request_handler.retry] 检测到重复标题: " .. trimmed:sub(1, 50))
        return true
      end
      headers[trimmed] = true
    end
  end

  -- 检查是否有大段重复内容（超过 50 个字符的相同行）
  local seen_lines = {}
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if #trimmed > 50 then
      if seen_lines[trimmed] then
        logger.debug("[request_handler.retry] 检测到长文本重复行: " .. trimmed:sub(1, 50) .. "...")
        return true
      end
      seen_lines[trimmed] = true
    end
  end

  return false
end

--- 检测响应是否被截断
--- 策略：检查文本是否以不完整的句子/代码块结束
--- @param text string 响应文本
--- @return boolean 是否检测到截断
local function has_truncated_content(text)
  if not text or text == "" then
    return false
  end

  -- 检查代码块是否未闭合
  local open_count = 0
  for match in text:gmatch("```") do
    open_count = open_count + 1
  end
  if open_count % 2 ~= 0 then
    logger.debug("[request_handler.retry] 检测到未闭合的代码块")
    return true
  end

  -- 检查是否以不完整的句子结束（以逗号、冒号、分号结尾）
  -- 注意：不检测 "-"（连字符），因为 Markdown 列表项、日期等正常文本可能以 "-" 结尾
  -- 同时不检测 "/" 和 "\\"，因为文件路径可能以这些字符结尾
  local last_char = text:sub(-1)
  local incomplete_endings = { [","] = true, [":"] = true, [";"] = true, ["|"] = true }
  if incomplete_endings[last_char] then
    logger.debug("[request_handler.retry] 检测到不完整结尾: '" .. last_char .. "'")
    return true
  end

  -- 检查是否以不完整的 Markdown 语法结束（仅检测结尾处未闭合的语法）
  -- 注意：使用锚定到行尾的匹配，避免误判文本中正常出现的 "[" 或 "("
  if text:match("%[%s*$") or text:match("%(%s*$") or text:match("!%[%s*$") then
    logger.debug("[request_handler.retry] 检测到不完整的 Markdown 语法")
    return true
  end

  return false
end

--- 检测工具调用是否异常
--- 策略：检查工具调用参数是否为空，以及是否存在完全相同的重复调用（同名+同参数）
--- 注意：同名但不同参数的多次工具调用（如多次 read_file 读取不同文件）是正常行为，不视为异常
--- @param tool_calls table 工具调用列表
--- @return boolean 是否检测到异常
local function has_abnormal_tool_calls(tool_calls)
  if not tool_calls or #tool_calls == 0 then
    return false
  end

  -- 检查是否有空参数的工具调用
  -- arguments 已在 http_utils 中解析为 Lua table
  for i, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func then
      local args = func.arguments
      -- 只检测真正为空的情况：nil 或空 table
      if args == nil then
        logger.debug(
          string.format(
            "[request_handler.retry] 检测到空参数工具调用 #%d: name=%s, args=nil",
            i,
            tostring(func.name)
          )
        )
        return true
      end
      -- 空 table {} 是合法参数（如 git_status、get_log_levels 等工具不需要参数），不视为异常
      -- 仅 args 为 nil 时才视为异常
      if type(args) == "table" and vim.tbl_isempty(args) then
        -- 不视为异常，允许继续执行
        -- 这些工具可能确实不需要参数
      end
    end
  end

  -- 检查是否有完全相同的重复调用（同名 + 同参数）
  -- 注意：仅同名但参数不同的多次调用（如多次 read_file 读取不同文件）是正常行为
  -- arguments 已是 Lua table，直接使用 vim.inspect 生成签名
  local seen_signatures = {}
  for i, tc in ipairs(tool_calls) do
    local func = tc["function"] or tc.func
    if func and func.name then
      local args = func.arguments
      local args_str = (type(args) == "table") and vim.inspect(args) or tostring(args or "")
      local signature = func.name .. ":" .. args_str
      if seen_signatures[signature] then
        logger.debug(
          string.format(
            "[request_handler.retry] 检测到完全相同的重复工具调用 #%d: name=%s, signature=%s",
            i,
            func.name,
            signature
          )
        )
        return true
      end
      seen_signatures[signature] = true
    end
  end

  return false
end

--- 综合检测响应是否异常
--- @param content string AI 响应文本
--- @param tool_calls table|nil 工具调用列表
--- @param opts table|nil 可选参数
---   - is_tool_loop boolean 是否在工具循环模式中
--- @return boolean 是否异常
--- @return string|nil 异常原因
function M.detect_abnormal_response(content, tool_calls, opts)
  opts = opts or {}

  -- 工具循环模式：AI 本轮不调用工具就算自动停止循环
  -- 有内容但无工具调用：视为 AI 自动退出，不再重试
  -- AI 可能认为任务已完成，直接返回文本回复
  if opts.is_tool_loop then
    -- 空内容且无工具调用：模型可能卡住，需要重试
    if (not content or content == "") and (not tool_calls or #tool_calls == 0) then
      return true, "空响应：AI 未返回任何内容或工具调用"
    end

    -- 有内容但无工具调用：视为 AI 自动退出，不再重试
    -- AI 认为任务已完成，直接返回文本回复，停止循环
    if content and content ~= "" and (not tool_calls or #tool_calls == 0) then
      return false, nil
    end

    -- 有工具调用：正常继续循环，但需检测工具调用本身是否异常
    if tool_calls and #tool_calls > 0 then
      if has_abnormal_tool_calls(tool_calls) then
        return true, "工具调用异常：检测到重复或空参数的工具调用"
      end
    end
  end

  -- 1. 空内容检测（非工具循环模式）
  -- 非工具循环模式下，空内容+无工具调用可能是正常的（如命名请求）
  -- 但如果有工具调用列表却为空，仍可能是异常
  if (not content or content == "") and (not tool_calls or #tool_calls == 0) then
    -- 非工具循环模式：不将空内容视为异常，让上层逻辑处理
    return false, nil
  end

  -- 2. 内容重复检测
  if content and content ~= "" then
    if has_repeated_content(content) then
      return true, "内容重复：检测到重复段落或标题"
    end
    if has_truncated_content(content) then
      return true, "内容截断：检测到不完整的结尾"
    end
  end

  -- 3. 工具调用异常检测
  if tool_calls and #tool_calls > 0 then
    if has_abnormal_tool_calls(tool_calls) then
      return true, "工具调用异常：检测到重复或空参数的工具调用"
    end
  end

  return false, nil
end

-- ========== 重试管理 ==========

--- 获取重试延迟
--- @param retry_count number 当前已重试次数（从 0 开始）
--- @return number 延迟毫秒数
function M.get_retry_delay(retry_count)
  if retry_count < 1 then
    return 0
  end
  local index = math.min(retry_count, #retry_config.retry_delays)
  return retry_config.retry_delays[index]
end

--- 检查是否可以继续重试
--- @param retry_count number 当前已重试次数
--- @return boolean
function M.can_retry(retry_count)
  return retry_count < retry_config.max_retries
end

--- 获取最大重试次数
--- @return number
function M.get_max_retries()
  return retry_config.max_retries
end

--- 设置重试配置
--- @param opts table { max_retries?, retry_delays? }
function M.set_retry_config(opts)
  if opts.max_retries then
    retry_config.max_retries = opts.max_retries
  end
  if opts.retry_delays then
    retry_config.retry_delays = opts.retry_delays
  end
end

return M
