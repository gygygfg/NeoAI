--- 配置存储
--- @module NeoAI.kernel.config_store
--- load(): 纯函数，merge + validate，返回不可变配置。
--- get(path): 按点分路径读取（如 "ui.window.width"）。
--- watch(path, cb): 监听配置变更。
--- 替代旧 merger + state 混合体，不管理任何业务状态。

local default_config = require("NeoAI.default_config")

local M = {}

-- ========== 私有状态 ==========

local state = {
  config = nil, -- 合并后的不可变配置
  watchers = {}, -- path -> { cb }
}

-- ========== 私有函数 ==========

--- 深度合并 user 覆盖 default
--- @param base table
--- @param override table
--- @return table 新表
local function _deep_merge(base, override)
  local result = {}
  for k, v in pairs(base or {}) do
    result[k] = vim.deepcopy(v)
  end
  for k, v in pairs(override or {}) do
    if type(v) == "table" and type(base[k]) == "table" then
      result[k] = _deep_merge(base[k], v)
    else
      result[k] = vim.deepcopy(v)
    end
  end
  return result
end

--- 校验配置，收集错误
--- @param config table
--- @return table 错误数组
local function _validate(config)
  local errors = {}
  local ai = config.ai or {}
  if not ai.default_provider then
    table.insert(errors, "ai.default_provider 缺失，将使用 'deepseek'")
  end
  if not ai.providers or next(ai.providers) == nil then
    table.insert(errors, "ai.providers 为空，AI 功能不可用")
  end
  for name, provider in pairs(ai.providers or {}) do
    if not provider.base_url then
      table.insert(errors, string.format("ai.providers.%s.base_url 缺失", name))
    end
  end
  local sc = ai.scenarios or {}
  for sname, sval in pairs(sc) do
    if type(sval) ~= "table" or not sval.provider then
      table.insert(errors, string.format("ai.scenarios.%s 应为 { provider = ... }", sname))
    end
  end
  return errors
end

--- 按点分路径读取配置
--- @param config table
--- @param path string
--- @return any
local function _get_path(config, path)
  local current = config
  for part in path:gmatch("[^.]+") do
    if type(current) ~= "table" then return nil end
    current = current[part]
  end
  return current
end

--- 按点分路径设置配置（内部）
local function _set_path(config, path, value)
  local parts = {}
  for part in path:gmatch("[^.]+") do parts[#parts + 1] = part end
  local current = config
  for i = 1, #parts - 1 do
    if type(current[parts[i]]) ~= "table" then
      current[parts[i]] = {}
    end
    current = current[parts[i]]
  end
  current[parts[#parts]] = value
end

-- ========== 公开 API ==========

--- 加载配置：merge + validate，返回不可变配置
--- @param user_config table
--- @return table 合并后的配置
function M.load(user_config)
  local base = default_config.get_default_config()
  state.config = _deep_merge(base, user_config)
  local errors = _validate(state.config)
  local logger = require("NeoAI.kernel.logger")
  if #errors > 0 then
    for _, e in ipairs(errors) do
      logger.warn("[config_store] 配置校验: %s", e)
    end
  end
  -- 触发配置加载事件
  local event_bus = require("NeoAI.kernel.event_bus")
  local events = require("NeoAI.kernel.events")
  event_bus.emit(events.CONFIG_LOADED, state.config)
  return state.config
end

--- 按点分路径读取配置
--- @param path string
--- @param default any|nil
--- @return any
function M.get(path, default)
  if not state.config then
    state.config = _deep_merge(default_config.get_default_config(), {})
  end
  local value = _get_path(state.config, path)
  if value == nil then return default end
  return value
end

--- 获取完整配置
--- @return table
function M.get_all()
  return state.config
end

--- 监听配置变更（path 前缀匹配）
--- @param path string
--- @param cb function(new_value, old_value)
--- @return function 取消监听
function M.watch(path, cb)
  if not state.watchers[path] then
    state.watchers[path] = {}
  end
  table.insert(state.watchers[path], cb)
  local removed = false
  return function()
    if removed then return end
    removed = true
    local list = state.watchers[path]
    if not list then return end
    for i, w in ipairs(list) do
      if w == cb then
        table.remove(list, i)
        break
      end
    end
  end
end

--- 更新配置（运行时热更新，触发 watch + CONFIG_CHANGED）
--- @param path string
--- @param value any
function M.set(path, value)
  if not state.config then return end
  local old = _get_path(state.config, path)
  _set_path(state.config, path, value)
  local new = _get_path(state.config, path)
  local event_bus = require("NeoAI.kernel.event_bus")
  local events = require("NeoAI.kernel.events")
  event_bus.emit(events.CONFIG_CHANGED, { path = path, old = old, new = new })
  for watch_path, cbs in pairs(state.watchers) do
    if path:sub(1, #watch_path) == watch_path then
      for _, cb in ipairs(cbs) do
        local ok, err = pcall(cb, new, old)
        if not ok then
          local logger = require("NeoAI.kernel.logger")
          logger.warn("[config_store] watch 回调异常 %s: %s", watch_path, tostring(err))
        end
      end
    end
  end
end

--- 重置（测试用）
function M.reset()
  state.config = nil
  state.watchers = {}
end

return M
