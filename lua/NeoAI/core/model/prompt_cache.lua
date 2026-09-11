--- 显式缓存管理器
--- @module NeoAI.core.model.prompt_cache
--- 按模型缓存机制（capabilities.cache_kind）在请求体上注入显式缓存指令；任一环节失败
--- 静默降级为隐式缓存，绝不阻断请求。
---   - Anthropic：cache_control 断点（system / 最后一个工具），≤ max_breakpoints
---   - OpenAI：prompt_cache_options.mode="explicit" + 内容块 prompt_cache_breakpoint（默认关闭，需显式开启）
---   - Gemini：cachedContents 资源生命周期（create / 复用 / 续期 / delete）
--- 生命周期状态按 provider|model 维度缓存，指纹变化或 TTL 到期即重建。

local async = require("NeoAI.utils.async")
local http = require("NeoAI.utils.http")
local json = require("NeoAI.utils.json")
local config_store = require("NeoAI.kernel.config_store")
local logger = require("NeoAI.kernel.logger")

local M = {}

-- ========== 私有状态 ==========

local state = {
  caches = {}, -- key -> { name, expire_at, fingerprint, provider, base_url, model }
  inflight = {}, -- key -> Deferred
}

-- 可注入传输层（测试用）；默认走 utils.http
local transport = nil

-- ========== 私有函数 ==========

--- 显式缓存总开关 / 分机制开关
--- @param kind string|nil
--- @return boolean
local function _enabled(kind)
  if config_store.get("ai.model_policy.enabled") == false then return false end
  if config_store.get("ai.model_policy.explicit_cache.enabled") == false then return false end
  if kind and config_store.get("ai.model_policy.explicit_cache." .. kind) == false then return false end
  return true
end

--- 缓存 key（provider|model）
local function _key(provider_name, model)
  return tostring(provider_name) .. "|" .. tostring(model)
end

--- 稳定前缀指纹（system + tools 的确定性序列化）
--- @param spec table
--- @return string
local function _fingerprint(spec)
  local prefix = require("NeoAI.core.agent.prefix")
  local parts = {
    tostring(spec.provider_name or ""),
    tostring(spec.model or ""),
    prefix.canonical_json(spec.system or ""),
    prefix.canonical_json(spec.tools or {}),
  }
  return table.concat(parts, "\n")
end

--- 估算稳定前缀 token（字符/4 粗估，用于 Gemini 最小可缓存判断）
local function _estimate_prefix_tokens(spec)
  local raw = json.encode({ system = spec.system or "", tools = spec.tools or {} })
  return math.ceil(#raw / 4)
end

--- Anthropic：cache_control 断点（system + 最后一个工具）
--- @param body table
--- @param caps table
local function _apply_anthropic(body, caps)
  local bp = caps.max_breakpoints or 4
  local used = 0
  local function cc()
    return { type = "ephemeral" }
  end
  if type(body.system) == "string" and body.system ~= "" then
    body.system = { { type = "text", text = body.system, cache_control = cc() } }
    used = used + 1
  elseif type(body.system) == "table" and #body.system > 0 then
    body.system[#body.system].cache_control = cc()
    used = used + 1
  end
  if type(body.tools) == "table" and #body.tools > 0 and used < bp then
    body.tools[#body.tools].cache_control = cc()
  end
end

--- OpenAI：explicit 模式 + 断点（保守，默认关闭）
--- @param body table
--- @param caps table
local function _apply_openai(body, caps)
  if not caps.explicit_cache then return end
  body.prompt_cache_options = { mode = "explicit" }
  local msgs = body.messages
  local last = msgs and msgs[#msgs]
  if not last then return end
  if type(last.content) == "string" then
    last.content = { { type = "text", text = last.content } }
  end
  if type(last.content) == "table" and #last.content > 0 then
    last.content[#last.content].prompt_cache_breakpoint = { mode = "explicit" }
  end
end

--- 删除 Gemini 缓存对象（best-effort）
--- @param entry table
local function _delete_gemini(entry)
  if not entry or not entry.name then return end
  local id = entry.name:match("cachedContents/(.+)$") or entry.name
  local do_request = transport or function(o) return http.request(o) end
  pcall(function()
    do_request({
      base_url = entry.base_url,
      path = "/cachedContents/" .. id .. "?key=" .. (entry.api_key or ""),
      method = "DELETE",
      timeout_ms = 10000,
    })
  end)
end

--- Gemini：确保 cachedContent 存在（create / 复用 / 续期），并挂到 body
--- @param spec table
--- @return Deferred resolve(boolean)
local function _apply_gemini(spec)
  local body = spec.body
  local caps = spec.caps or {}
  local key = _key(spec.provider_name, spec.model)
  local fp = _fingerprint(spec)
  local ttl = caps.cache_ttl or 3600
  local min_tokens = caps.min_cacheable or 0

  local entry = state.caches[key]
  if entry and entry.fingerprint == fp and entry.expire_at and entry.expire_at > os.time() + 60 then
    body.cachedContent = entry.name
    body.systemInstruction = nil
    body.tools = nil
    return async.resolve(true)
  end

  if _estimate_prefix_tokens(spec) < min_tokens then
    return async.resolve(false) -- 未达最小可缓存长度，降级隐式
  end

  if state.inflight[key] then
    return state.inflight[key]:then_(function(name)
      if name then
        body.cachedContent = name
        body.systemInstruction = nil
        body.tools = nil
      end
      return true
    end)
  end

  local provider = spec.provider or {}
  local request_body = {
    model = "models/" .. tostring(spec.model),
    ttl = tostring(ttl) .. "s",
  }
  if type(spec.system) == "table" and #spec.system > 0 then
    request_body.systemInstruction = { parts = spec.system }
  end
  if type(spec.tools) == "table" and #spec.tools > 0 then
    request_body.tools = spec.tools
  end

  local do_request = transport or function(o) return http.request(o) end
  local d = do_request({
    base_url = provider.base_url,
    path = "/cachedContents?key=" .. (provider.api_key or ""),
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = request_body,
    timeout_ms = config_store.get("ai.timeout_ms") or 60000,
  }, { signal = spec.signal }):then_(function(resp)
    local obj = type(resp) == "table" and resp or json.decode_or_nil(resp)
    if not obj or not obj.name then
      logger.warn("[prompt_cache] Gemini 显式缓存创建失败，降级为隐式")
      return nil
    end
    -- 清理旧缓存对象，避免泄漏
    if entry then _delete_gemini(entry) end
    state.caches[key] = {
      name = obj.name,
      expire_at = os.time() + ttl,
      fingerprint = fp,
      base_url = provider.base_url,
      api_key = provider.api_key,
      model = spec.model,
    }
    body.cachedContent = obj.name
    body.systemInstruction = nil
    body.tools = nil
    return obj.name
  end, function()
    logger.warn("[prompt_cache] Gemini 显式缓存请求异常，降级为隐式")
    return nil
  end)

  state.inflight[key] = d
  return d:then_(function(name)
    state.inflight[key] = nil
    return name ~= nil
  end)
end

-- ========== 公开 API ==========

--- 注入显式缓存（异步；Anthropic/OpenAI 同步完成，Gemini 可能发起创建请求）
--- @param spec table { body, provider, provider_name, model, dialect, caps, system?, tools?, stream?, signal? }
--- @return Deferred resolve(boolean) 是否注入了显式缓存
function M.apply_async(spec)
  if not spec or not spec.body then return async.resolve(false) end
  local caps = spec.caps or {}
  local kind = caps.cache_kind
  if not _enabled(kind) then return async.resolve(false) end
  if kind == "anthropic" then
    _apply_anthropic(spec.body, caps)
    return async.resolve(true)
  elseif kind == "openai" then
    _apply_openai(spec.body, caps)
    return async.resolve(true)
  elseif kind == "gemini" then
    return _apply_gemini(spec)
  end
  return async.resolve(false)
end

--- 失效指定 provider|model 的显式缓存（压缩 / 前缀变化后调用）
--- @param provider_name string
--- @param model string
function M.invalidate(provider_name, model)
  local key = _key(provider_name, model)
  local entry = state.caches[key]
  if entry then
    _delete_gemini(entry)
    state.caches[key] = nil
  end
end

--- 释放指定 provider|model 的显式缓存（会话销毁时调用）
--- @param provider_name string|nil
--- @param model string|nil
function M.dispose(provider_name, model)
  if provider_name and model then
    M.invalidate(provider_name, model)
    return
  end
  for key, entry in pairs(state.caches) do
    _delete_gemini(entry)
    state.caches[key] = nil
  end
end

--- 注入传输层（测试用）
--- @param fn function|nil
function M._set_transport(fn)
  transport = fn
end

--- 重置（测试用）
function M.reset()
  state.caches = {}
  state.inflight = {}
  transport = nil
end

--- 读取缓存条目（测试用）
--- @param provider_name string
--- @param model string
--- @return table|nil
function M._entry(provider_name, model)
  return state.caches[_key(provider_name, model)]
end

return M
