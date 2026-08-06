--- 模型注册表
--- @module NeoAI.core.model.registry
--- 运行时动态更新的模型列表。
--- - list(provider?)：异步返回可用模型（含 fallback 链）
--- - get(model_id)：获取单个模型
--- - subscribe(cb)：订阅变更（MODELS_UPDATED 事件）
--- - update(provider, models)：写入新列表并通知
--- - 支持 models_override 手动覆盖 + API 自动发现

local adapter = require("NeoAI.core.model.adapter")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有状态 ==========

local state = {
  models = {}, -- provider -> { id = {provider, id, status}, ... }
  order = {}, -- provider -> 数组排序
  updated_at = {}, -- provider -> os.time()
}

-- ========== 私有函数 ==========

--- 获取某 provider 的配置
--- @param provider string
--- @return table|nil
local function _get_provider(provider)
  if not provider then
    provider = config_store.get("ai.default_provider")
  end
  local providers = config_store.get("ai.providers") or {}
  return providers[provider], provider
end

--- 从配置静态列表构建（models_override 或 provider.models）
--- @param provider_name string
--- @param provider table
--- @return table 数组
local function _static_models(provider_name, provider)
  local list = provider.models_override or provider.models
  if not list then return {} end
  local out = {}
  for _, id in ipairs(list) do
    out[#out + 1] = { id = id, provider = provider_name, status = "available" }
  end
  return out
end

--- 合并静态与动态列表（动态优先，静态保持顺序）
--- @param provider_name string
--- @return table 数组
local function _merge(provider_name)
  local provider = _get_provider(provider_name)
  if not provider then return {} end
  local statics = _static_models(provider_name, provider)
  local dynamic = state.models[provider_name] or {}
  local merged = vim.deepcopy(dynamic)
  local seen = {}
  for _, m in ipairs(merged) do seen[m.id] = true end
  for _, m in ipairs(statics) do
    if not seen[m.id] then
      merged[#merged + 1] = m
      seen[m.id] = true
    end
  end
  if #merged == 0 then
    -- 兜底：adapter 默认列表
    local fb = adapter.get_fallback_models(provider_name)
    for _, id in ipairs(fb) do
      merged[#merged + 1] = { id = id, provider = provider_name, status = "unknown" }
    end
  end
  return merged
end

-- ========== 公开 API ==========

--- 获取可用模型列表（异步返回 Promise）
--- @param provider string|nil
--- @return Deferred resolve(数组)
function M.list(provider)
  local pname = provider or config_store.get("ai.default_provider")
  return async.resolve(_merge(pname))
end

--- 获取单个模型详情
--- @param model_id string
--- @param provider string|nil
--- @return table|nil
function M.get(model_id, provider)
  local pname = provider or config_store.get("ai.default_provider")
  for _, m in ipairs(_merge(pname)) do
    if m.id == model_id then return m end
  end
  return nil
end

--- 更新某 provider 的模型列表（由 fetcher 调用）
--- @param provider string
--- @param models table id 数组
function M.update(provider, models)
  if not models or #models == 0 then
    local logger = require("NeoAI.kernel.logger")
    logger.warn("[registry] 忽略空模型列表更新: %s", provider)
    return state.models[provider] or {}
  end
  local list = {}
  for _, id in ipairs(models) do
    list[#list + 1] = { id = id, provider = provider, status = "available" }
  end
  state.models[provider] = list
  state.updated_at[provider] = os.time()
  event_bus.emit(events.MODELS_UPDATED, { provider = provider, count = #list, models = list })
  local logger = require("NeoAI.kernel.logger")
  logger.info("[registry] %s 模型列表已更新: %d 个", provider, #list)
  return list
end

--- 订阅模型列表变更
--- @param cb function(payload)
--- @return function 取消订阅
function M.subscribe(cb)
  return event_bus.on(events.MODELS_UPDATED, cb)
end

--- 手动触发刷新（交给 fetcher）
--- @param provider string|nil
--- @return Deferred
function M.prefetch(provider)
  local fetcher = require("NeoAI.core.model.fetcher")
  return fetcher.fetch(provider)
end

--- 获取某 provider 的推荐模型（default_model="auto" 时用第一个）
--- @param provider string|nil
--- @return string|nil
function M.resolve_default(provider)
  local pname = provider or config_store.get("ai.default_provider")
  local default_model = config_store.get("ai.default_model") or "auto"
  if default_model ~= "auto" then return default_model end
  local merged = _merge(pname)
  if #merged > 0 then return merged[1].id end
  return nil
end

--- 重置（测试用）
function M.reset()
  state.models = {}
  state.order = {}
  state.updated_at = {}
end

return M
