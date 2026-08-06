--- 请求构建 + 发送 + 重试
--- @module NeoAI.core.agent.request
--- 构建请求体（经 adapter），发送（流式/非流式），指数退避重试。
--- 依赖：kernel(adapter) + utils(http/async)。

local async = require("NeoAI.utils.async")
local http = require("NeoAI.utils.http")
local adapter = require("NeoAI.core.model.adapter")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有函数 ==========

--- 解析 model:provider 字符串
--- @param model string|nil
--- @return string model_id, string provider_name
local function _resolve_provider_model(model, agent_config)
  local provider_name = (agent_config and agent_config.provider)
    or config_store.get("ai.default_provider")
  local model_id = model or (agent_config and agent_config.model) or nil
  if not model_id then
    local registry = require("NeoAI.core.model.registry")
    model_id = registry.resolve_default(provider_name)
  end
  if type(model_id) == "string" and model_id:find(":") then
    local p, m = model_id:match("^([^:]+):(.+)$")
    if p and m then
      provider_name = p
      model_id = m
    end
  end
  return model_id, provider_name
end

--- 构建请求体
--- @param messages table
--- @param opts table { model?, stream?, temperature?, max_tokens?, tools?, agent_config?, reasoning_enabled? }
--- @return table, string provider_name, string model_id
local function _build_request(messages, opts)
  opts = opts or {}
  local model_id, provider_name = _resolve_provider_model(opts.model, opts.agent_config)
  local providers = config_store.get("ai.providers") or {}
  local provider = providers[provider_name] or {}
  local a = adapter.get(provider.api_type or "openai") or adapter.get("openai")

  local reasoning_enabled = opts.reasoning_enabled
  if reasoning_enabled == nil then
    reasoning_enabled = config_store.get("ai.reasoning_enabled")
  end

  local body = a.build_body({
    model = model_id,
    messages = messages,
    stream = opts.stream or false,
    temperature = opts.temperature,
    max_tokens = opts.max_tokens,
    reasoning_enabled = reasoning_enabled,
    tools = opts.tools,
  })

  return body, provider, model_id, a
end

--- 是否需要重试该错误
--- @param err table
--- @return boolean
local function _should_retry(err)
  if type(err) ~= "table" then return false end
  if err.kind == "aborted" then return false end
  if err.kind == "http" then
    local status = err.status
    if status and status >= 400 and status < 500 then return false end -- 4xx 不重试
    return true
  end
  return true
end

-- ========== 公开 API ==========

--- 发送请求（非流式）
--- @param messages table
--- @param opts table { model?, agent_config?, tools?, temperature?, max_tokens?, signal? }
--- @return Deferred resolve(解析后的响应)
function M.send(messages, opts)
  opts = opts or {}
  local body, provider, model_id, a = _build_request(messages, opts)
  local timeout_ms = opts.timeout_ms or config_store.get("ai.timeout_ms") or 60000
  local max_retries = opts.max_retries or config_store.get("ai.max_retries") or 3

  return async.retry(function()
    return http.request({
      base_url = provider.base_url,
      path = a.chat_path(provider),
      method = "POST",
      headers = a.headers(provider),
      body = body,
      timeout_ms = timeout_ms,
    }, { signal = opts.signal }):then_(function(resp_body)
      local parsed = a.parse_response(resp_body)
      if not parsed then
        return async.reject({ kind = "parse", message = "响应解析失败" })
      end
      return {
        content = parsed.content,
        reasoning = parsed.reasoning,
        tool_calls = parsed.tool_calls,
        finish_reason = parsed.finish_reason,
        usage = parsed.usage,
        provider = provider.api_type,
        model = model_id,
      }
    end)
  end, {
    retries = max_retries,
    delay_ms = 1000,
    backoff = 2,
    signal = opts.signal,
    should_retry = _should_retry,
  })
end

--- 发送流式请求
--- @param messages table
--- @param opts table { model?, agent_config?, tools?, temperature?, max_tokens?, signal? }
--- @param on_chunk function(chunk: table) chunk = { content?, reasoning?, tool_calls? }
--- @return Deferred resolve({ content, reasoning, tool_calls, finish_reason, usage })
function M.send_stream(messages, opts, on_chunk)
  opts = opts or {}
  local body, provider, model_id, a = _build_request(messages, opts)
  local timeout_ms = opts.timeout_ms or config_store.get("ai.timeout_ms") or 60000
  local max_retries = opts.max_retries or config_store.get("ai.max_retries") or 3

  local acc = { content = "", reasoning = "", tool_calls = nil, finish_reason = nil }
  local done = false

  return async.retry(function()
    acc = { content = "", reasoning = "", tool_calls = nil, finish_reason = nil }
    done = false
    return http.request({
      base_url = provider.base_url,
      path = a.chat_path(provider),
      method = "POST",
      headers = a.headers(provider),
      body = body,
      timeout_ms = timeout_ms,
      stream = true,
    }, {
      signal = opts.signal,
      on_chunk = function(raw, is_done)
        if is_done then
          done = true
          return
        end
        local parsed = a.parse_stream_chunk(raw)
        if not parsed then return end
        if type(parsed.content) == "string" then
          acc.content = acc.content .. parsed.content
          if on_chunk then on_chunk({ content = parsed.content }) end
        end
        if type(parsed.reasoning) == "string" then
          acc.reasoning = acc.reasoning .. parsed.reasoning
          if on_chunk then on_chunk({ reasoning = parsed.reasoning }) end
        end
        if parsed.tool_calls then
          acc.tool_calls = acc.tool_calls or {}
          for _, tc in ipairs(parsed.tool_calls) do
            acc.tool_calls[#acc.tool_calls + 1] = tc
          end
          if on_chunk then on_chunk({ tool_calls = parsed.tool_calls }) end
        end
        if parsed.finish_reason then
          acc.finish_reason = parsed.finish_reason
        end
      end,
    }):then_(function()
      return {
        content = acc.content ~= "" and acc.content or nil,
        reasoning = acc.reasoning ~= "" and acc.reasoning or nil,
        tool_calls = acc.tool_calls,
        finish_reason = acc.finish_reason,
        provider = provider.api_type,
        model = model_id,
      }
    end)
  end, {
    retries = max_retries,
    delay_ms = 1000,
    backoff = 2,
    signal = opts.signal,
    should_retry = function(err)
      if done then return false end
      return _should_retry(err)
    end,
  })
end

return M
