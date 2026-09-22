--- 多提供商协议适配
--- @module NeoAI.core.model.adapter
--- 统一 openai / anthropic / google 协议的请求构造、消息/工具/图像编码、响应解析、
--- models 列表解析。不绑定特定 LLM 厂商：协议族内的厂商方言由 core.model.profiles
--- 提供的 dialect 表注入，本模块只负责「内部规范 ↔ 协议」的编解码。
---
--- 内部规范：
---   - 消息为 OpenAI 形 { role, content(string|parts), tool_calls?, tool_call_id? }
---     parts 内的图像为中立块 { type="image", media_type, base64, _bytes }（由 content.materialize 产出）
---   - 工具定义为 [{ type="function", function={ name, description, parameters } }]
---   - 响应统一为 { content, reasoning, tool_calls, finish_reason, usage }

local M = {}

-- ========== 私有常量 ==========

--- 默认模型列表（当获取失败且无缓存时兜底）
local FALLBACK_MODELS = {
  deepseek = { "deepseek-v4-flash", "deepseek-v4-pro", "deepseek-v4-flash-vision-exp" },
  openai = { "gpt-4o", "gpt-4o-mini", "gpt-4-turbo" },
  anthropic = { "claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022" },
  google = { "gemini-2.0-flash", "gemini-1.5-pro" },
}

-- ========== 私有工具 ==========

local function _json()
  return require("NeoAI.utils.json")
end

--- 中立图像块 → data URL
--- @param part table { media_type, base64 }
--- @return string
local function _data_url(part)
  return "data:" .. (part.media_type or "application/octet-stream") .. ";base64," .. (part.base64 or "")
end

--- 是否中立图像块
local function _is_image(part)
  return type(part) == "table" and part.type == "image"
end

--- 是否文本块
local function _is_text(part)
  return type(part) == "table" and part.type == "text"
end

--- 解析工具调用 arguments（JSON 字符串）为对象。
--- 按 arguments 字符串做有界记忆化：历史工具调用参数每轮请求都会被重新解码，
--- 对长会话是重复的主线程开销；参数串不可变，可安全复用解码结果（调用方只读）。
--- @param arguments string|table|nil
--- @return table
local _args_cache = {}
local _args_cache_n = 0
local ARGS_CACHE_MAX = 512

local function _args_object(arguments)
  if type(arguments) == "table" then return arguments end
  local key = arguments or "{}"
  local hit = _args_cache[key]
  if hit then return hit end
  local decoded = _json().decode_or_nil(key)
  if type(decoded) ~= "table" then return {} end
  if _args_cache_n >= ARGS_CACHE_MAX then
    _args_cache = {}
    _args_cache_n = 0
  end
  _args_cache[key] = decoded
  _args_cache_n = _args_cache_n + 1
  return decoded
end

--- 图像引用解析结果 → 中立图像块
--- @param ref table { mediaType?, data? }
--- @return table
local function _image_part_from_ref(ref)
  local image = require("NeoAI.utils.image")
  return {
    type = "image",
    media_type = ref.mediaType,
    base64 = image.base64_encode(ref.data),
    _bytes = ref.bytes,
  }
end

M._image_part_from_ref = _image_part_from_ref

--- 清理请求体中的内部字段（_bytes 等），避免泄漏进 wire JSON
--- @param value any
--- @return any
local function _strip_internal(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    if type(k) == "string" and k:sub(1, 1) ~= "_" then
      out[k] = _strip_internal(v)
    end
  end
  return out
end

M._strip_internal = _strip_internal

-- ========== 数值元数据提取（模型列表实时获取） ==========
-- 不少端点（Gemini / Groq / OpenRouter / Together 等）在 /models 响应里直接回传上下文窗口与
-- 最大输出，这些数值随厂商更新自动生效，优先于内置能力表。键名大小写不敏感，兼容常见命名。

--- 把对象的键统一为小写，便于大小写不敏感查找
--- @param item table
--- @return table
local function _lower_keys(item)
  local m = {}
  for k, v in pairs(item) do
    if type(k) == "string" then m[k:lower()] = v end
  end
  return m
end

--- 正数取值
local function _pos_number(v)
  local n = tonumber(v)
  if n and n > 0 then return n end
  return nil
end

--- 从模型对象中提取上下文窗口 / 最大输出（大小写不敏感 + 常见嵌套）
--- @param item table 单个模型对象
--- @return number|nil context_window
--- @return number|nil max_output
local function _extract_meta(item)
  local lm = _lower_keys(item)
  local window = _pos_number(lm.context_length)
    or _pos_number(lm.context_window)
    or _pos_number(lm.max_input_tokens)
    or _pos_number(lm.max_model_len)
    or _pos_number(lm.max_context_length)
    or _pos_number(lm.inputtokenlimit)
  local max_out = _pos_number(lm.max_output_tokens)
    or _pos_number(lm.max_completion_tokens)
    or _pos_number(lm.max_output)
    or _pos_number(lm.outputtokenlimit)
  -- OpenRouter 等把限制放在 top_provider 下
  local tp = item.top_provider or item.topProvider
  if type(tp) == "table" then
    local tlm = _lower_keys(tp)
    window = window
      or _pos_number(tlm.context_length)
      or _pos_number(tlm.context_window)
    max_out = max_out
      or _pos_number(tlm.max_completion_tokens)
      or _pos_number(tlm.max_output_tokens)
  end
  return window, max_out
end

M._extract_meta = _extract_meta

--- 取模型列表中的 id 数组（兼容 string[] / object[]）
--- @param list table|nil
--- @return table id 数组
function M.model_ids(list)
  local out = {}
  for _, m in ipairs(list or {}) do
    if type(m) == "string" then
      out[#out + 1] = m
    elseif type(m) == "table" and m.id then
      out[#out + 1] = m.id
    end
  end
  return out
end

-- ========== OpenAI 协议 ==========

local openai = { protocol = "openai" }

function openai.chat_path(provider, model, opts)
  return "/chat/completions"
end

function openai.models_path(provider)
  return "/models"
end

--- 编码消息：内部规范 → OpenAI 形（图像块 → image_url）
--- @param messages table
--- @param dialect table|nil
--- @return table { messages = table }
function openai.encode_messages(messages, dialect)
  local out = {}
  for _, m in ipairs(messages or {}) do
    local msg = { role = m.role }
    if type(m.content) == "table" then
      local parts = {}
      for _, p in ipairs(m.content) do
        if _is_text(p) then
          parts[#parts + 1] = { type = "text", text = p.text }
        elseif _is_image(p) then
          parts[#parts + 1] = { type = "image_url", image_url = { url = _data_url(p) } }
        end
      end
      msg.content = parts
    else
      msg.content = m.content
    end
    if m.tool_calls then msg.tool_calls = m.tool_calls end
    if m.tool_call_id then msg.tool_call_id = m.tool_call_id end
    out[#out + 1] = msg
  end
  return { messages = out }
end

--- 编码工具：OpenAI 形即内部规范，原样透传
--- @param tools table
--- @param dialect table|nil
--- @return table
function openai.encode_tools(tools, dialect)
  return tools
end

--- 构造 OpenAI 格式的请求体
--- @param opts table { model, messages, system?, stream?, temperature?, max_tokens?, tools?, reasoning_enabled?, reasoning_effort?, dialect? }
--- @return table
function openai.build_body(opts)
  local d = opts.dialect or {}
  local body = {
    model = opts.model,
    messages = opts.messages,
    stream = opts.stream or false,
  }
  if opts.temperature and d.temperature_supported ~= false then
    body.temperature = opts.temperature
  end
  local field = d.max_tokens_field or "max_tokens"
  if opts.max_tokens then body[field] = opts.max_tokens end

  if opts.reasoning_enabled then
    local kind = d.reasoning_kind or "none"
    if kind == "effort" then
      body.reasoning_effort = opts.reasoning_effort or d.default_effort or "medium"
    elseif kind == "enable_thinking" then
      body.enable_thinking = true
    elseif kind == "thinking_object" then
      body.thinking = { type = "enabled" }
    elseif kind == "openrouter_object" then
      body.reasoning = { enabled = true, exclude = false }
    end
  end

  if opts.stream and d.stream_usage ~= false then
    -- 流式需显式声明 include_usage，OpenAI 兼容端点才会在末尾回传 usage（缓存命中统计依赖它）
    body.stream_options = { include_usage = true }
  end
  if opts.tools and #opts.tools > 0 then
    body.tools = opts.tools
  end
  return body
end

--- 解析 OpenAI 流式 chunk
--- @param raw string data 行内容（不含 "data: " 前缀）
--- @return table|nil { content?, reasoning?, tool_calls?, finish_reason?, usage? }
function openai.parse_stream_chunk(raw)
  local obj = _json().decode_or_nil(raw)
  if not obj then return nil end
  local delta = obj.choices and obj.choices[1] and obj.choices[1].delta
  local out = {}
  if delta then
    if type(delta.content) == "string" then out.content = delta.content end
    if type(delta.reasoning_content) == "string" then out.reasoning = delta.reasoning_content end
    if type(delta.reasoning) == "string" then out.reasoning = delta.reasoning end
    if type(delta.tool_calls) == "table" then out.tool_calls = delta.tool_calls end
  end
  if obj.choices and obj.choices[1] and obj.choices[1].finish_reason then
    out.finish_reason = obj.choices[1].finish_reason
  end
  if type(obj.usage) == "table" then
    out.usage = obj.usage
  end
  if next(out) then return out end
  return nil
end

--- 解析 OpenAI 非流式响应
function openai.parse_response(body)
  local obj = _json().decode_or_nil(body)
  if not obj then return nil end
  local choice = obj.choices and obj.choices[1]
  if not choice then return nil end
  return {
    content = choice.message and choice.message.content or nil,
    reasoning = choice.message and (choice.message.reasoning_content or choice.message.reasoning) or nil,
    tool_calls = choice.message and choice.message.tool_calls or nil,
    finish_reason = choice.finish_reason,
    usage = type(obj.usage) == "table" and obj.usage or nil,
  }
end

--- 解析 OpenAI /models 响应（含实时数值元数据，缺失则为 nil）
--- @return table { { id, context_window?, max_output? }, ... }
function openai.parse_models(body)
  local obj = _json().decode_or_nil(body)
  if not obj or not obj.data then return nil end
  local models = {}
  for _, item in ipairs(obj.data) do
    if item.id then
      local window, max_out = _extract_meta(item)
      models[#models + 1] = { id = item.id, context_window = window, max_output = max_out }
    end
  end
  return models
end

--- 构造鉴权请求头
function openai.headers(provider, dialect)
  local headers = {
    ["Content-Type"] = "application/json",
    Authorization = "Bearer " .. (provider.api_key or ""),
  }
  if dialect and dialect.extra_headers then
    for k, v in pairs(dialect.extra_headers) do headers[k] = v end
  end
  return headers
end

-- ========== Anthropic 协议 ==========

local anthropic = { protocol = "anthropic" }

function anthropic.chat_path(provider, model, opts)
  return "/messages"
end

function anthropic.models_path(provider)
  return "/models"
end

--- 编码消息：内部规范 → Anthropic（system 顶层 + content blocks + tool_use/tool_result）
--- @param messages table
--- @param dialect table|nil
--- @return table { system = string, messages = table }
function anthropic.encode_messages(messages, dialect)
  local system_chunks = {}
  local out = {}
  for _, m in ipairs(messages or {}) do
    if m.role == "system" then
      if type(m.content) == "string" and m.content ~= "" then
        system_chunks[#system_chunks + 1] = m.content
      end
    elseif m.role == "tool" then
      out[#out + 1] = {
        role = "user",
        content = {
          { type = "tool_result", tool_use_id = m.tool_call_id, content = m.content or "" },
        },
      }
    elseif m.role == "assistant" then
      local blocks = {}
      if type(m.content) == "string" and m.content ~= "" then
        blocks[#blocks + 1] = { type = "text", text = m.content }
      elseif type(m.content) == "table" then
        for _, p in ipairs(m.content) do
          if _is_text(p) then blocks[#blocks + 1] = { type = "text", text = p.text } end
        end
      end
      local echo = dialect and dialect.reasoning_echo or "never"
      if echo == "within_round" and type(m.reasoning_blocks) == "table" then
        for _, b in ipairs(m.reasoning_blocks) do blocks[#blocks + 1] = b end
      end
      if m.tool_calls then
        for _, tc in ipairs(m.tool_calls) do
          local fn = tc["function"] or {}
          blocks[#blocks + 1] = {
            type = "tool_use",
            id = tc.id,
            name = fn.name,
            input = _args_object(fn.arguments),
          }
        end
      end
      if #blocks > 0 then
        out[#out + 1] = { role = "assistant", content = blocks }
      end
    else -- user
      if type(m.content) == "table" then
        local blocks = {}
        for _, p in ipairs(m.content) do
          if _is_text(p) then
            blocks[#blocks + 1] = { type = "text", text = p.text }
          elseif _is_image(p) then
            blocks[#blocks + 1] = {
              type = "image",
              source = { type = "base64", media_type = p.media_type, data = p.base64 },
            }
          end
        end
        out[#out + 1] = { role = "user", content = blocks }
      else
        out[#out + 1] = { role = "user", content = m.content }
      end
    end
  end
  return { system = table.concat(system_chunks, "\n\n"), messages = out }
end

--- 编码工具：OpenAI 形 → Anthropic { name, description, input_schema }
--- @param tools table
--- @param dialect table|nil
--- @return table
function anthropic.encode_tools(tools, dialect)
  local out = {}
  for _, td in ipairs(tools or {}) do
    local fn = td["function"] or {}
    local t = { name = fn.name, description = fn.description }
    if fn.parameters then t.input_schema = fn.parameters end
    out[#out + 1] = t
  end
  return out
end

--- 构造 Anthropic 请求体
function anthropic.build_body(opts)
  local d = opts.dialect or {}
  local body = {
    model = opts.model,
    max_tokens = opts.max_tokens or 4096,
    messages = opts.messages,
    stream = opts.stream or false,
  }
  if opts.system and opts.system ~= "" then body.system = opts.system end
  if opts.tools and #opts.tools > 0 then body.tools = opts.tools end

  if opts.reasoning_enabled and d.reasoning_kind == "budget" then
    -- Anthropic 扩展思考：开启后 temperature 必须为 1（或省略）
    body.thinking = { type = "enabled", budget_tokens = opts.reasoning_budget or 2048 }
    body.temperature = 1
  elseif opts.temperature and d.temperature_supported ~= false then
    body.temperature = opts.temperature
  end
  return body
end

--- 解析 Anthropic 流式 chunk
function anthropic.parse_stream_chunk(raw)
  local obj = _json().decode_or_nil(raw)
  if not obj then return nil end
  if obj.type == "message_start" and obj.message then
    local out = {}
    if type(obj.message.usage) == "table" then out.usage = obj.message.usage end
    if next(out) then return out end
  elseif obj.type == "content_block_delta" and obj.delta then
    local out = {}
    if obj.delta.type == "thinking_delta" and obj.delta.thinking then
      out.reasoning = obj.delta.thinking
    elseif obj.delta.text then
      out.content = obj.delta.text
    end
    if next(out) then return out end
  elseif obj.type == "message_delta" and obj.delta and obj.delta.stop_reason then
    local out = { finish_reason = obj.delta.stop_reason }
    if type(obj.usage) == "table" then out.usage = obj.usage end
    return out
  elseif obj.type == "content_block_start" and obj.content_block then
    if obj.content_block.type == "tool_use" then
      return { tool_call_start = { id = obj.content_block.id, name = obj.content_block.name } }
    end
  end
  return nil
end

--- 解析 Anthropic 非流式响应
function anthropic.parse_response(body)
  local obj = _json().decode_or_nil(body)
  if not obj then return nil end
  local content = {}
  local reasoning = {}
  local tool_calls = {}
  for _, block in ipairs(obj.content or {}) do
    if block.type == "text" then
      content[#content + 1] = block.text
    elseif block.type == "thinking" and block.thinking then
      reasoning[#reasoning + 1] = block.thinking
    elseif block.type == "tool_use" then
      tool_calls[#tool_calls + 1] = {
        id = block.id,
        type = "function",
        ["function"] = {
          name = block.name,
          arguments = _json().encode(block.input or {}),
        },
      }
    end
  end
  return {
    content = #content > 0 and table.concat(content, "") or nil,
    reasoning = #reasoning > 0 and table.concat(reasoning, "") or nil,
    tool_calls = #tool_calls > 0 and tool_calls or nil,
    finish_reason = obj.stop_reason,
    usage = type(obj.usage) == "table" and obj.usage or nil,
  }
end

--- 解析 Anthropic /models 响应（含实时数值元数据，缺失则为 nil）
--- @return table { { id, context_window?, max_output? }, ... }
function anthropic.parse_models(body)
  local obj = _json().decode_or_nil(body)
  if not obj or not obj.data then return nil end
  local models = {}
  for _, item in ipairs(obj.data) do
    if item.id then
      local window, max_out = _extract_meta(item)
      models[#models + 1] = { id = item.id, context_window = window, max_output = max_out }
    end
  end
  return models
end

function anthropic.headers(provider, dialect)
  local headers = {
    ["Content-Type"] = "application/json",
    ["x-api-key"] = provider.api_key or "",
    ["anthropic-version"] = "2023-06-01",
  }
  if dialect and dialect.extra_headers then
    for k, v in pairs(dialect.extra_headers) do headers[k] = v end
  end
  return headers
end

-- ========== Google 协议 ==========

local google = { protocol = "google" }

--- Gemini schema 类型映射（Gemini 要求大写类型名）
local GEMINI_TYPES = {
  string = "STRING", number = "NUMBER", integer = "INTEGER",
  boolean = "BOOLEAN", object = "OBJECT", array = "ARRAY", null = "NULL",
}
--- Gemini 不支持的 JSON Schema 关键字（裁剪掉，避免 400）
local GEMINI_DROP_KEYS = {
  additionalProperties = true, ["$schema"] = true, default = true,
  title = true, examples = true, ["$ref"] = true, allOf = true, anyOf = true, oneOf = true,
}

--- 递归把 JSON Schema 转换为 Gemini functionDeclaration 可接受的形态
--- @param schema table|nil
--- @return table|nil
local function _gemini_schema(schema)
  if type(schema) ~= "table" then return schema end
  local out = {}
  for k, v in pairs(schema) do
    if not GEMINI_DROP_KEYS[k] then
      if k == "type" and type(v) == "string" then
        out.type = GEMINI_TYPES[v:lower()] or v:upper()
      elseif k == "properties" and type(v) == "table" then
        local props = {}
        for pk, pv in pairs(v) do props[pk] = _gemini_schema(pv) end
        out.properties = props
      elseif k == "items" then
        out.items = _gemini_schema(v)
      else
        out[k] = v
      end
    end
  end
  return out
end

--- 编码消息：内部规范 → Gemini contents + systemInstruction
--- @param messages table
--- @param dialect table|nil
--- @return table { system = table(parts), messages = table(contents) }
function google.encode_messages(messages, dialect)
  local system_parts = {}
  local contents = {}
  for _, m in ipairs(messages or {}) do
    if m.role == "system" then
      if type(m.content) == "string" and m.content ~= "" then
        system_parts[#system_parts + 1] = { text = m.content }
      end
    elseif m.role == "assistant" then
      local parts = {}
      if type(m.content) == "string" and m.content ~= "" then
        parts[#parts + 1] = { text = m.content }
      end
      if m.tool_calls then
        for _, tc in ipairs(m.tool_calls) do
          local fn = tc["function"] or {}
          parts[#parts + 1] = { functionCall = { name = fn.name, args = _args_object(fn.arguments) } }
        end
      end
      if #parts > 0 then contents[#contents + 1] = { role = "model", parts = parts } end
    elseif m.role == "tool" then
      contents[#contents + 1] = {
        role = "user",
        parts = {
          { functionResponse = { name = m.tool_name or "tool", response = { result = m.content or "" } } },
        },
      }
    else -- user
      local parts = {}
      if type(m.content) == "table" then
        for _, p in ipairs(m.content) do
          if _is_text(p) then
            parts[#parts + 1] = { text = p.text }
          elseif _is_image(p) then
            parts[#parts + 1] = { inlineData = { mimeType = p.media_type, data = p.base64 } }
          end
        end
      else
        parts[#parts + 1] = { text = m.content or "" }
      end
      contents[#contents + 1] = { role = "user", parts = parts }
    end
  end
  return { system = system_parts, messages = contents }
end

--- 编码工具：OpenAI 形 → Gemini [{ functionDeclarations = [...] }]
--- @param tools table
--- @param dialect table|nil
--- @return table
function google.encode_tools(tools, dialect)
  local decls = {}
  for _, td in ipairs(tools or {}) do
    local fn = td["function"] or {}
    local decl = { name = fn.name, description = fn.description }
    if fn.parameters then decl.parameters = _gemini_schema(fn.parameters) end
    decls[#decls + 1] = decl
  end
  return { { functionDeclarations = decls } }
end

--- 构造 Gemini 请求体
function google.build_body(opts)
  local d = opts.dialect or {}
  local body = {
    contents = opts.messages,
    generationConfig = {},
  }
  if type(opts.system) == "table" and #opts.system > 0 then
    body.systemInstruction = { parts = opts.system }
  end
  if opts.temperature and d.temperature_supported ~= false then
    body.generationConfig.temperature = opts.temperature
  end
  if opts.max_tokens then
    body.generationConfig[d.max_tokens_field or "maxOutputTokens"] = opts.max_tokens
  end
  if opts.reasoning_enabled and d.reasoning_kind == "thinking_config" then
    body.generationConfig.thinkingConfig = {
      thinkingBudget = opts.reasoning_budget or 2048,
      includeThoughts = true,
    }
  end
  if opts.tools and #opts.tools > 0 then
    body.tools = opts.tools
  end
  return body
end

function google.chat_path(provider, model, opts)
  local key = provider.api_key or ""
  if opts and opts.stream then
    return "/models/" .. tostring(model) .. ":streamGenerateContent?alt=sse&key=" .. key
  end
  return "/models/" .. tostring(model) .. ":generateContent?key=" .. key
end

function google.models_path(provider)
  return "/models?key=" .. (provider.api_key or "")
end

function google.parse_stream_chunk(raw)
  local obj = _json().decode_or_nil(raw)
  if not obj then return nil end
  local cand = obj.candidates and obj.candidates[1]
  local out = {}
  if cand and cand.content and cand.content.parts then
    for _, part in ipairs(cand.content.parts) do
      if part.text then
        if part.thought then
          out.reasoning = (out.reasoning or "") .. part.text
        else
          out.content = (out.content or "") .. part.text
        end
      end
    end
  end
  if type(obj.usageMetadata) == "table" then out.usage = obj.usageMetadata end
  if cand and cand.finishReason then out.finish_reason = cand.finishReason end
  if next(out) then return out end
  return nil
end

function google.parse_response(body)
  local obj = _json().decode_or_nil(body)
  if not obj then return nil end
  local cand = obj.candidates and obj.candidates[1]
  if not cand then return nil end
  local content = {}
  local reasoning = {}
  local tool_calls = {}
  if cand.content and cand.content.parts then
    for _, part in ipairs(cand.content.parts) do
      if part.text then
        if part.thought then reasoning[#reasoning + 1] = part.text else content[#content + 1] = part.text end
      elseif part.functionCall then
        tool_calls[#tool_calls + 1] = {
          id = "call_" .. (part.functionCall.name or "tool"),
          type = "function",
          ["function"] = {
            name = part.functionCall.name,
            arguments = _json().encode(part.functionCall.args or {}),
          },
        }
      end
    end
  end
  return {
    content = #content > 0 and table.concat(content, "") or nil,
    reasoning = #reasoning > 0 and table.concat(reasoning, "") or nil,
    tool_calls = #tool_calls > 0 and tool_calls or nil,
    finish_reason = cand.finishReason,
    usage = type(obj.usageMetadata) == "table" and obj.usageMetadata or nil,
  }
end

--- 解析 Google /models 响应（inputTokenLimit / outputTokenLimit → 实时元数据）
--- @return table { { id, context_window?, max_output? }, ... }
function google.parse_models(body)
  local obj = _json().decode_or_nil(body)
  if not obj or not obj.models then return nil end
  local models = {}
  for _, item in ipairs(obj.models) do
    if item.name then
      local name = item.name:match("models/(.+)$") or item.name
      local window, max_out = _extract_meta(item)
      models[#models + 1] = { id = name, context_window = window, max_output = max_out }
    end
  end
  return models
end

function google.headers(provider, dialect)
  local headers = { ["Content-Type"] = "application/json" }
  if dialect and dialect.extra_headers then
    for k, v in pairs(dialect.extra_headers) do headers[k] = v end
  end
  return headers
end

-- ========== 适配器注册表 ==========

local ADAPTERS = {
  openai = openai,
  anthropic = anthropic,
  google = google,
}

--- 获取适配器
--- @param api_type string
--- @return table|nil
function M.get(api_type)
  return ADAPTERS[api_type]
end

--- 注册自定义适配器
--- @param api_type string
--- @param adapter table
function M.register(api_type, adapter)
  ADAPTERS[api_type] = adapter
end

--- 获取 fallback 模型列表
--- @param provider_name string
--- @return table
function M.get_fallback_models(provider_name)
  return vim.deepcopy(FALLBACK_MODELS[provider_name] or {})
end

--- 该提供商是否支持自动获取模型
--- @param provider table
--- @return boolean
function M.can_fetch(provider)
  if provider.fetch_models == false then return false end
  return ADAPTERS[provider.api_type] ~= nil
end

return M
