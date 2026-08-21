--- 多提供商协议适配
--- @module NeoAI.core.model.adapter
--- 统一 openai / anthropic / google 协议的请求构造、响应解析、models 列表解析。
--- 不绑定特定 LLM 厂商，新提供商只需注册适配器。

local M = {}

-- ========== 私有常量 ==========

--- 默认模型列表（当获取失败且无缓存时兜底）
local FALLBACK_MODELS = {
  deepseek = { "deepseek-v4-flash", "deepseek-v4-pro" },
  openai = { "gpt-4o", "gpt-4o-mini", "gpt-4-turbo" },
  anthropic = { "claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022" },
  google = { "gemini-2.0-flash", "gemini-1.5-pro" },
}

-- ========== OpenAI 协议 ==========

local openai = {}

function openai.chat_path(provider)
  return "/chat/completions"
end

function openai.models_path(provider)
  return "/models"
end

--- 构造 OpenAI 格式的请求体
function openai.build_body(opts)
  local body = {
    model = opts.model,
    messages = opts.messages,
    stream = opts.stream or false,
    temperature = opts.temperature,
  }
  if opts.max_tokens then body.max_tokens = opts.max_tokens end
  if opts.reasoning_enabled and opts.reasoning_effort then
    body.reasoning_effort = opts.reasoning_effort
  end
  if opts.tools and #opts.tools > 0 then
    body.tools = opts.tools
  end
  return body
end

--- 解析 OpenAI 流式 chunk
--- @param raw string data 行内容（不含 "data: " 前缀）
--- @return table|nil { content?, reasoning?, tool_calls?, finish_reason? }
function openai.parse_stream_chunk(raw)
  local json = require("NeoAI.utils.json")
  local obj = json.decode_or_nil(raw)
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
  if obj.usage then
    out.usage = obj.usage
  end
  if next(out) then return out end
  return nil
end

--- 解析 OpenAI 非流式响应
function openai.parse_response(body)
  local json = require("NeoAI.utils.json")
  local obj = json.decode_or_nil(body)
  if not obj then return nil end
  local choice = obj.choices and obj.choices[1]
  if not choice then return nil end
  return {
    content = choice.message and choice.message.content or nil,
    reasoning = choice.message and (choice.message.reasoning_content or choice.message.reasoning) or nil,
    tool_calls = choice.message and choice.message.tool_calls or nil,
    finish_reason = choice.finish_reason,
    usage = obj.usage,
  }
end

--- 解析 OpenAI /models 响应
function openai.parse_models(body)
  local json = require("NeoAI.utils.json")
  local obj = json.decode_or_nil(body)
  if not obj or not obj.data then return nil end
  local models = {}
  for _, item in ipairs(obj.data) do
    if item.id then models[#models + 1] = item.id end
  end
  return models
end

--- 构造鉴权请求头
function openai.headers(provider)
  return {
    ["Content-Type"] = "application/json",
    Authorization = "Bearer " .. (provider.api_key or ""),
  }
end

-- ========== Anthropic 协议 ==========

local anthropic = {}

function anthropic.chat_path(provider)
  return "/v1/messages"
end

function anthropic.models_path(provider)
  return "/v1/models"
end

function anthropic.build_body(opts)
  local body = {
    model = opts.model,
    max_tokens = opts.max_tokens or 4096,
    messages = opts.messages,
    stream = opts.stream or false,
  }
  if opts.temperature then body.temperature = opts.temperature end
  if opts.system then body.system = opts.system end
  if opts.tools and #opts.tools > 0 then body.tools = opts.tools end
  return body
end

function anthropic.parse_stream_chunk(raw)
  local json = require("NeoAI.utils.json")
  local obj = json.decode_or_nil(raw)
  if not obj then return nil end
  if obj.type == "content_block_delta" and obj.delta then
    local out = {}
    if obj.delta.text then out.content = obj.delta.text end
    if obj.delta.thinking then out.reasoning = obj.delta.thinking end
    if next(out) then return out end
  elseif obj.type == "message_delta" and obj.delta and obj.delta.stop_reason then
    local out = { finish_reason = obj.delta.stop_reason }
    if obj.usage then out.usage = obj.usage end
    return out
  elseif obj.type == "content_block_start" and obj.content_block then
    if obj.content_block.type == "tool_use" then
      return { tool_call_start = { id = obj.content_block.id, name = obj.content_block.name } }
    end
  end
  return nil
end

function anthropic.parse_response(body)
  local json = require("NeoAI.utils.json")
  local obj = json.decode_or_nil(body)
  if not obj then return nil end
  local content = {}
  local tool_calls = {}
  for _, block in ipairs(obj.content or {}) do
    if block.type == "text" then
      content[#content + 1] = block.text
    elseif block.type == "tool_use" then
      tool_calls[#tool_calls + 1] = {
        id = block.id,
        type = "function",
        ["function"] = {
          name = block.name,
          arguments = json.encode(block.input or {}),
        },
      }
    end
  end
  return {
    content = #content > 0 and table.concat(content, "") or nil,
    tool_calls = #tool_calls > 0 and tool_calls or nil,
    finish_reason = obj.stop_reason,
    usage = obj.usage,
  }
end

function anthropic.parse_models(body)
  local json = require("NeoAI.utils.json")
  local obj = json.decode_or_nil(body)
  if not obj or not obj.data then return nil end
  local models = {}
  for _, item in ipairs(obj.data) do
    if item.id then models[#models + 1] = item.id end
  end
  return models
end

function anthropic.headers(provider)
  return {
    ["Content-Type"] = "application/json",
    ["x-api-key"] = provider.api_key or "",
    ["anthropic-version"] = "2023-06-01",
  }
end

-- ========== Google 协议 ==========

local google = {}

function google.chat_path(provider, model)
  return "/models/" .. model .. ":generateContent"
end

function google.models_path(provider)
  return "/models?key=" .. (provider.api_key or "")
end

function google.build_body(opts)
  local body = {
    contents = opts.messages,
    generationConfig = {},
  }
  if opts.temperature then body.generationConfig.temperature = opts.temperature end
  if opts.max_tokens then body.generationConfig.maxOutputTokens = opts.max_tokens end
  return body
end

function google.parse_stream_chunk(raw)
  local json = require("NeoAI.utils.json")
  local obj = json.decode_or_nil(raw)
  if not obj then return nil end
  local cand = obj.candidates and obj.candidates[1]
  if cand and cand.content and cand.content.parts then
    local out = {}
    for _, part in ipairs(cand.content.parts) do
      if part.text then
        out.content = (out.content or "") .. part.text
      end
    end
    if obj.usageMetadata then
      out.usage = obj.usageMetadata
    end
    if cand.finishReason then
      out.finish_reason = cand.finishReason
    end
    if next(out) then return out end
  end
  return nil
end

function google.parse_response(body)
  local json = require("NeoAI.utils.json")
  local obj = json.decode_or_nil(body)
  if not obj then return nil end
  local cand = obj.candidates and obj.candidates[1]
  if not cand then return nil end
  local content = ""
  if cand.content and cand.content.parts then
    for _, part in ipairs(cand.content.parts) do
      if part.text then content = content .. part.text end
    end
  end
  return {
    content = content ~= "" and content or nil,
    finish_reason = cand.finishReason,
    usage = obj.usageMetadata,
  }
end

function google.parse_models(body)
  local json = require("NeoAI.utils.json")
  local obj = json.decode_or_nil(body)
  if not obj or not obj.models then return nil end
  local models = {}
  for _, item in ipairs(obj.models) do
    if item.name then
      local name = item.name:match("models/(.+)$") or item.name
      models[#models + 1] = name
    end
  end
  return models
end

function google.headers(provider)
  return { ["Content-Type"] = "application/json" }
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
