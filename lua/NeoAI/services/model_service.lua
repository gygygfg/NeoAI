--- 模型服务
--- @module NeoAI.services.model_service
--- 供 UI（model_picker）选择/切换模型。
--- - list()：异步返回所有可用模型
--- - set_active(model_id)：切换当前 Agent 模型
--- - prefetch()：手动刷新模型列表

local registry = require("NeoAI.core.model.registry")
local fetcher = require("NeoAI.core.model.fetcher")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有状态 ==========

local state = {
  active_model = nil, -- 当前选中模型
  active_provider = nil,
}

-- ========== 公开 API ==========

--- 获取所有可用模型（按 provider 分组）
--- @return Deferred resolve({ { provider, models = {...} } })
function M.list()
  local providers = config_store.get("ai.providers") or {}
  local tasks = {}
  local names = {}
  for name in pairs(providers) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    tasks[#tasks + 1] = registry.list(name):then_(function(models)
      return { provider = name, models = models }
    end)
  end
  return async.all(tasks)
end

--- 设置当前激活模型
--- @param model_id string
--- @param provider string|nil
--- @return table { model, provider }
function M.set_active(model_id, provider)
  if not provider then
    -- 从 model_id 反查 provider
    provider = state.active_provider or config_store.get("ai.default_provider")
    local providers = config_store.get("ai.providers") or {}
    for pname, p in pairs(providers) do
      local list = p.models_override or p.models or {}
      for _, m in ipairs(list) do
        if m == model_id then provider = pname break end
      end
    end
  end
  state.active_model = model_id
  state.active_provider = provider
  event_bus.emit(events.MODEL_SWITCHED, { model = model_id, provider = provider })
  local logger = require("NeoAI.kernel.logger")
  logger.info("[model_service] 切换模型: %s (%s)", model_id, provider)
  return { model = model_id, provider = provider }
end

--- 获取当前激活模型
--- @return table|nil { model, provider }
function M.get_active()
  if state.active_model then
    return { model = state.active_model, provider = state.active_provider }
  end
  return nil
end

--- 后台刷新模型列表
--- @param provider string|nil
--- @return Deferred
function M.prefetch(provider)
  return fetcher.prefetch(provider)
end

--- 订阅模型变更
--- @param cb function
--- @return function
function M.subscribe(cb)
  return event_bus.on(events.MODELS_UPDATED, cb)
end

--- 初始化时后台拉取（懒调用）
function M.start_background_refresh()
  local model_refresh = config_store.get("ai.model_refresh") or {}
  if model_refresh.on_startup == false then return end
  -- 沙箱内（嵌套 Neovim）不自动刷新：其缓存写入会被沙箱当作待审变更捕获。
  if require("NeoAI.utils.env").in_sandbox() then return end
  vim.schedule(function()
    M.prefetch()
  end)
end

--- 重置（测试用）
function M.reset()
  state.active_model = nil
  state.active_provider = nil
end

return M
