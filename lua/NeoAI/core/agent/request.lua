--- 请求构建 + 发送 + 重试
--- @module NeoAI.core.agent.request
--- 构建请求体（经 adapter），发送（流式/非流式），指数退避重试。
--- 依赖：kernel(adapter) + utils(http/async)。

local async = require("NeoAI.utils.async")
local http = require("NeoAI.utils.http")
local adapter = require("NeoAI.core.model.adapter")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 原始请求/响应捕获 ==========
-- 轨迹显示需要 wire 级数据：每个请求的原始请求体 + 原始响应（SSE 分片）。
-- 分片与字节数设上限，避免长会话把内存撑爆；超限后截断并标记。

local MAX_RAW_CHUNKS = 500 -- 原始分片数上限
local MAX_RAW_BYTES = 300000 -- 原始分片字节数上限

--- 追加一段原始分片（受上限约束）
--- @param raw table { chunks = table, bytes = number, truncated = boolean }
--- @param chunk string|nil
local function _append_raw(raw, chunk)
  if raw.truncated then return end
  if not chunk or chunk == "" then return end
  if #raw.chunks >= MAX_RAW_CHUNKS or raw.bytes + #chunk > MAX_RAW_BYTES then
    raw.truncated = true
    return
  end
  raw.chunks[#raw.chunks + 1] = chunk
  raw.bytes = raw.bytes + #chunk
end

--- 由发送结果构建 round 元数据（供轨迹展示；字段不进入模型上下文）
--- @param response table send/send_stream 的返回值（含 request_body/raw_chunks 等）
--- @param opts table|nil { ttft_ms?, total_ms? }
--- @return table { request = table, response = table }
function M.build_round_meta(response, opts)
  opts = opts or {}
  local body = response and response.request_body
  return {
    request = {
      model = response and response.model,
      provider = response and response.provider,
      -- 直接引用请求体：仅用于轨迹展示，发送后不再修改，避免对整段 body（含全部消息+
      -- 工具 schema）做 vim.deepcopy（每轮一次的大对象拷贝）。
      body = body,
    },
    response = {
      finish_reason = response and response.finish_reason,
      usage = response and response.usage,
      ttft_ms = opts.ttft_ms,
      total_ms = opts.total_ms,
      status = "ok",
      raw_chunks = response and response.raw_chunks,
      raw_truncated = response and response.raw_truncated,
    },
  }
end

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

--- 构建请求上下文（协议编码 + 方言 + 显式缓存）
--- @param messages table 已物化的 wire 消息（内部规范）
--- @param opts table { model?, stream?, temperature?, max_tokens?, tools?, agent_config?, reasoning_enabled?, reasoning_budget?, reasoning_effort? }
--- @return table ctx { body, provider, provider_name, model_id, adapter, dialect, caps, path, headers }
local function _build_request(messages, opts)
  opts = opts or {}
  local model_id, provider_name = _resolve_provider_model(opts.model, opts.agent_config)
  local providers = config_store.get("ai.providers") or {}
  local provider = providers[provider_name] or {}
  local api_type = provider.api_type or "openai"
  local a = adapter.get(api_type) or adapter.get("openai")

  local profiles = require("NeoAI.core.model.profiles")
  local capabilities = require("NeoAI.core.model.capabilities")
  local dialect = profiles.resolve(provider_name, provider, model_id)
  local caps = capabilities.resolve(model_id, provider_name, provider)

  local reasoning_enabled = opts.reasoning_enabled
  if reasoning_enabled == nil then
    reasoning_enabled = config_store.get("ai.reasoning_enabled")
  end

  -- 协议编码：内部规范 → 各协议 wire 形态（Anthropic system/blocks、Gemini contents 等）
  local encoded = a.encode_messages(messages, dialect)
  local tools = a.encode_tools(opts.tools, dialect)

  -- 请求参数回落：显式 opts → 场景配置（modes 的 temperature/max_tokens）
  local ac = opts.agent_config or {}
  local temperature = opts.temperature
  if temperature == nil then temperature = ac.temperature end
  local max_tokens = opts.max_tokens
  if max_tokens == nil then max_tokens = ac.max_tokens end

  -- 输出上限发送策略：仅用户显式配置（opts.max_tokens 或场景 modes.*.max_tokens）才下发；
  -- 未配置则不发送该参数，由模型/厂商默认最大输出决定（实时/override 值不再自动发送）。
  -- 例外：协议必填（如 Anthropic max_tokens）用能力表 max_output 兜底。
  -- 显式值超出模型上限时收敛，避免厂商 400（超过模型最大输出）。
  local cap_out = tonumber(caps.max_output)
  if max_tokens == nil and dialect.max_tokens_required then
    max_tokens = cap_out
  elseif max_tokens ~= nil and cap_out and cap_out > 0 and max_tokens > cap_out then
    local logger = require("NeoAI.kernel.logger")
    logger.debug("[request] max_tokens %d 超出 %s 上限 %d，已收敛", max_tokens, tostring(model_id), cap_out)
    max_tokens = cap_out
  end

  local body = a.build_body({
    model = model_id,
    messages = encoded.messages,
    system = encoded.system,
    stream = opts.stream or false,
    temperature = temperature,
    max_tokens = max_tokens,
    reasoning_enabled = reasoning_enabled,
    reasoning_budget = opts.reasoning_budget or caps.reasoning_budget,
    reasoning_effort = opts.reasoning_effort,
    tools = tools,
    dialect = dialect,
  })

  -- 显式缓存由发送阶段异步注入（Gemini 需先创建 cachedContents），见 send / send_stream。

  return {
    body = body,
    provider = provider,
    provider_name = provider_name,
    model_id = model_id,
    adapter = a,
    dialect = dialect,
    caps = caps,
    system = encoded.system,
    tools = tools,
    path = a.chat_path(provider, model_id, { stream = opts.stream }),
    headers = a.headers(provider, dialect),
  }
end

--- 先物化消息（多模态：把会话内的图像引用解析为 wire part；模型不支持图像则原样文本）
--- 对齐 deepseek-harness：文本消息保持字符串，图像消息转为 part 数组。
--- @param messages table
--- @param opts table { model?, agent_config? }
--- @return Deferred resolve(wire 消息数组)
local function _prepare_messages(messages, opts)
  local model_id, provider_name = _resolve_provider_model(opts.model, opts.agent_config)
  local vision = false
  if model_id then
    local attachments = require("NeoAI.core.attachment.attachment")
    vision = attachments.enabled() and attachments.supports_image(model_id, provider_name)
  end
  local content = require("NeoAI.core.model.content")
  return content.materialize(messages, { vision = vision })
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

--- 是否上下文溢出错误（触发压缩后重试）
--- 各提供商措辞不一，匹配常见标识；HTTP body 与 message 都检查。
--- @param err table|nil
--- @return boolean
local function _is_context_overflow(err)
  if type(err) ~= "table" then return false end
  if err.kind == "aborted" or err.kind == "approval" or err.kind == "timeout" then return false end
  local status = err.status
  -- 主要看 400（OpenAI/DeepSeek 超长上下文）与 413（负载过大）
  if status and status ~= 400 and status ~= 413 and status ~= 429 then return false end
  local haystack = table.concat({
    type(err.body) == "string" and err.body or "",
    type(err.message) == "string" and err.message or "",
  }, "\n"):lower()
  local patterns = {
    "context_length", "context length", "context window",
    "maximum context", "max context", "prompt is too long",
    "input is too long", "too many tokens", "token limit",
    "request too large", "the input is too large", "context_exceeded",
    "context_length_exceeded", "exceeds the maximum",
  }
  for _, p in ipairs(patterns) do
    if haystack:find(p, 1, true) then return true end
  end
  return false
end

-- ========== 公开 API ==========

--- 上下文溢出判断（供 recovery 模块使用）
--- @param err table|nil
--- @return boolean
M.is_context_overflow = _is_context_overflow

--- 发送请求（非流式）
--- @param messages table
--- @param opts table { model?, agent_config?, tools?, temperature?, max_tokens?, signal? }
--- @return Deferred resolve(解析后的响应)
function M.send(messages, opts)
  opts = opts or {}
  return _prepare_messages(messages, opts):then_(function(prepared)
    local ctx = _build_request(prepared, opts)
    local timeout_ms = opts.timeout_ms or config_store.get("ai.timeout_ms") or 60000
    local max_retries = opts.max_retries or config_store.get("ai.max_retries") or 3

    return require("NeoAI.core.model.prompt_cache").apply_async({
      body = ctx.body, provider = ctx.provider, provider_name = ctx.provider_name,
      model = ctx.model_id, dialect = ctx.dialect, caps = ctx.caps,
      system = ctx.system, tools = ctx.tools, stream = opts.stream, signal = opts.signal,
    }):then_(function()
      return async.retry(function()
        return http.request({
          base_url = ctx.provider.base_url,
          path = ctx.path,
          method = "POST",
          headers = ctx.headers,
          body = ctx.body,
          timeout_ms = timeout_ms,
        }, { signal = opts.signal }):then_(function(resp_body)
          local parsed = ctx.adapter.parse_response(resp_body)
          if not parsed then
            return async.reject({ kind = "parse", message = "响应解析失败" })
          end
          return {
            content = parsed.content,
            reasoning = parsed.reasoning,
            tool_calls = parsed.tool_calls,
            finish_reason = parsed.finish_reason,
            usage = parsed.usage,
            provider = ctx.provider.api_type,
            model = ctx.model_id,
            request_body = ctx.body,
            raw_body = resp_body,
          }
        end)
        end, {
          retries = max_retries,
          delay_ms = 1000,
          backoff = 2,
          signal = opts.signal,
          should_retry = _should_retry,
        })
      end)
    end)
end

--- 发送流式请求
--- @param messages table
--- @param opts table { model?, agent_config?, tools?, temperature?, max_tokens?, signal? }
--- @param on_chunk function(chunk: table) chunk = { content?, reasoning?, tool_calls? }
--- @return Deferred resolve({ content, reasoning, tool_calls, finish_reason, usage })
function M.send_stream(messages, opts, on_chunk)
  opts = opts or {}
  -- 流式请求的请求体必须声明 stream=true：否则 API（如 DeepSeek）会以非流式
  -- JSON 返回，而客户端按 SSE 逐事件解析，两者不匹配导致工具循环第二轮及以后
  -- 的所有内容/工具调用增量全部丢失（表现为"模型未返回后续内容"，工具循环的
  -- 第二轮 turn 无法开启）。runtime 首轮显式传了 stream=true，tool_loop 的
  -- _send_round 之前漏传，这里统一强制。
  opts = vim.tbl_extend("force", opts, { stream = true })
  return _prepare_messages(messages, opts):then_(function(prepared)
    local ctx = _build_request(prepared, opts)
    local timeout_ms = opts.timeout_ms or config_store.get("ai.timeout_ms") or 60000
    local max_retries = opts.max_retries or config_store.get("ai.max_retries") or 3

    local acc = { content_parts = {}, reasoning_parts = {}, tool_calls = nil, finish_reason = nil, usage = nil }
    local raw = { chunks = {}, bytes = 0, truncated = false }
    local done = false
    local emitted = false

    return require("NeoAI.core.model.prompt_cache").apply_async({
      body = ctx.body, provider = ctx.provider, provider_name = ctx.provider_name,
      model = ctx.model_id, dialect = ctx.dialect, caps = ctx.caps,
      system = ctx.system, tools = ctx.tools, stream = true, signal = opts.signal,
    }):then_(function()
    return async.retry(function()
      acc = { content_parts = {}, reasoning_parts = {}, tool_calls = nil, finish_reason = nil, usage = nil }
      raw = { chunks = {}, bytes = 0, truncated = false }
      done = false
      emitted = false
      return http.request({
        base_url = ctx.provider.base_url,
        path = ctx.path,
        method = "POST",
        headers = ctx.headers,
        body = ctx.body,
        timeout_ms = timeout_ms,
        stream = true,
      }, {
        signal = opts.signal,
        on_chunk = function(raw_chunk, is_done)
          if is_done then
            done = true
            return
          end
          -- 原始响应（SSE 分片）捕获：供轨迹显示查看 wire 级数据
          _append_raw(raw, raw_chunk)
          local parsed = ctx.adapter.parse_stream_chunk(raw_chunk)
          if not parsed then return end
          if type(parsed.content) == "string" then
            emitted = emitted or parsed.content ~= ""
            acc.content_parts[#acc.content_parts + 1] = parsed.content
            if on_chunk then on_chunk({ content = parsed.content }) end
          end
          if type(parsed.reasoning) == "string" then
            emitted = emitted or parsed.reasoning ~= ""
            acc.reasoning_parts[#acc.reasoning_parts + 1] = parsed.reasoning
            if on_chunk then on_chunk({ reasoning = parsed.reasoning }) end
          end
          if parsed.tool_calls then
            emitted = true
            acc.tool_calls = acc.tool_calls or {}
            for _, tc in ipairs(parsed.tool_calls) do
              acc.tool_calls[#acc.tool_calls + 1] = tc
            end
            if on_chunk then on_chunk({ tool_calls = parsed.tool_calls }) end
          end
          if parsed.finish_reason then
            acc.finish_reason = parsed.finish_reason
          end
          -- 必须用 type 判断：JSON null 经 vim.json.decode 变成 vim.NIL(userdata)，为真值，
          -- 直接传给 tbl_deep_extend 会报 "expected table, got userdata"。
          if type(parsed.usage) == "table" then
            -- 跨分片合并：Anthropic 在 message_start 回传输入/缓存 token、message_delta 回传输出 token
            acc.usage = vim.tbl_deep_extend("force", acc.usage or {}, parsed.usage)
          end
        end,
      }):then_(function()
        local content = table.concat(acc.content_parts)
        local reasoning = table.concat(acc.reasoning_parts)
        return {
          content = content ~= "" and content or nil,
          reasoning = reasoning ~= "" and reasoning or nil,
          tool_calls = acc.tool_calls,
          finish_reason = acc.finish_reason,
          usage = acc.usage,
          provider = ctx.provider.api_type,
          model = ctx.model_id,
          request_body = ctx.body,
          raw_chunks = raw.chunks,
          raw_truncated = raw.truncated,
        }
      end)
      end, {
        retries = max_retries,
        delay_ms = 1000,
        backoff = 2,
        signal = opts.signal,
        should_retry = function(err)
          -- 一旦流式增量交付给调用方，重放请求会重复正文/工具参数。
          if done or emitted then return false end
          return _should_retry(err)
        end,
      })
    end)
    end)
end

return M
