--- 模型列表异步获取器
--- @module NeoAI.core.model.fetcher
--- 并发拉取所有已配置 provider 的 /models 端点。
--- 指数退避重试（3 次：1s/2s/4s）。
--- 成功 → registry.update；失败 → cache；无缓存 → 静态 fallback。

local async = require("NeoAI.utils.async")
local http = require("NeoAI.utils.http")
local adapter = require("NeoAI.core.model.adapter")
local registry = require("NeoAI.core.model.registry")
local cache = require("NeoAI.core.model.cache")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  fetching = {}, -- provider -> Deferred
}

-- ========== 私有函数 ==========

--- 拉取单个 provider 的模型列表
--- @param provider_name string
--- @param provider table
--- @param opts table { timeout_ms?, signal? }
--- @return Deferred resolve(模型 id 数组)
local function _fetch_provider(provider_name, provider, opts)
  local a = adapter.get(provider.api_type)
  if not a or not adapter.can_fetch(provider) then
    return async.resolve(adapter.get_fallback_models(provider_name))
  end
  local timeout_ms = opts.timeout_ms or config_store.get("ai.model_refresh.timeout_ms") or 10000

  local attempt
  attempt = function(n)
    return http.request({
      base_url = provider.base_url,
      path = a.models_path(provider),
      method = "GET",
      headers = a.headers(provider),
      timeout_ms = timeout_ms,
      signal = opts.signal,
    }):then_(function(body)
      local models = a.parse_models(body)
      if not models or #models == 0 then
        return async.reject({ kind = "http", message = "解析模型列表失败" })
      end
      return models
    end, function(err)
      if n >= 3 then return async.reject(err) end
      local delays = { 1000, 2000, 4000 }
      return async.sleep(delays[n]):then_(function() return attempt(n + 1) end)
    end)
  end
  return attempt(1)
end

-- ========== 公开 API ==========

--- 拉取模型列表
--- @param provider string|nil 指定 provider；nil 则拉取所有
--- @return Deferred resolve({ provider = {ok, models} })
function M.fetch(provider)
  if provider then
    if state.fetching[provider] then return state.fetching[provider] end
    state.fetching[provider] = M._fetch_single(provider)
    state.fetching[provider]:finally(function()
      state.fetching[provider] = nil
    end)
    return state.fetching[provider]
  end

  local providers = config_store.get("ai.providers") or {}
  local tasks = {}
  for name in pairs(providers) do
    tasks[#tasks + 1] = name
  end
  local results = {}
  for _, name in ipairs(tasks) do
    results[#results + 1] = M._fetch_single(name):then_(function(models)
      return { name = name, ok = true, models = models }
    end, function(err)
      return { name = name, ok = false, error = err }
    end)
  end
  return async.all(results)
end

--- 拉取单个 provider（含缓存回退逻辑）
--- @param provider_name string
--- @return Deferred
function M._fetch_single(provider_name)
  local provider = (config_store.get("ai.providers") or {})[provider_name]
  if not provider then
    return async.reject({ kind = "config", message = "provider 不存在: " .. provider_name })
  end

  -- models_override 时直接使用，不发起请求
  if provider.models_override and #provider.models_override > 0 then
    local models = provider.models_override
    registry.update(provider_name, models)
    return async.resolve(models)
  end

  local logger = require("NeoAI.kernel.logger")
  logger.info("[fetcher] 开始获取 %s 模型列表", provider_name)

  return _fetch_provider(provider_name, provider, {}):then_(function(models)
    cache.write(provider_name, models)
    registry.update(provider_name, models)
    return models
  end, function(err)
    logger.warn("[fetcher] %s 获取失败: %s，回退缓存", provider_name, tostring(err.message or err))
    -- 失败回退链：缓存 → registry 当前值 → 静态 fallback
    local cached = cache.read(provider_name)
    if cached and cached.models and #cached.models > 0 then
      registry.update(provider_name, cached.models)
      return cached.models
    end
    return registry.list(provider_name):then_(function(merged)
      if #merged > 0 then
        local models = {}
        for _, m in ipairs(merged) do models[#models + 1] = m.id end
        return models
      end
      local fb = adapter.get_fallback_models(provider_name)
      registry.update(provider_name, fb)
      return fb
    end)
  end)
end

--- 手动刷新（model_service.prefetch 调用）
--- @param provider string|nil
--- @return Deferred
function M.prefetch(provider)
  event_bus.emit(events.MODEL_REFRESH_STARTED, { provider = provider })
  return M.fetch(provider)
end

--- 重置（测试用）
function M.reset()
  state.fetching = {}
end

return M
