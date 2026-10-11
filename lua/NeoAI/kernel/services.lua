--- 服务定位器
--- @module 'NeoAI.kernel.services'
--- 业务代码通过 use(name) 获取「当前配置下生效」的服务实现，而非直接 require 具体模块。
--- - provide(name, impl)：由插件宿主在插件启动时登记服务实现。
--- - use(name)：返回当前实现；未提供/被禁用时返回 nil（绝不回退到默认 require）。
--- - wait(name, cb)：服务尚未提供时等待其就绪（依赖等待）。
--- 这样可在配置中替换服务实现，或禁用 UI/MCP 等，而不会偷偷回退到默认模块。

local M = {}

-- ========== 私有状态 ==========

-- 已知服务名（内置服务提供方）。用于拼写错误诊断：use/wait 遇到「形如 services.* 但既非
-- 已知、也未登记」的名字时告警一次（不抛错，保持向后兼容）。provide() 会自动把新名字并入。
local KNOWN = {
  "services.agent",
  "services.chat_service",
  "services.herder",
  "services.herder_install",
  "services.mcp",
  "services.model_service",
  "services.pty",
  "services.sandbox",
  "services.session",
  "services.skills",
  "services.status",
  "services.tool_service",
  "services.tools",
  "services.ui",
}

local state = {
  providers = {}, -- name -> impl
  waiters = {}, -- name -> { cb }
  known = {}, -- name -> true（已知或已登记）
  warned = {}, -- name -> true（已就未知名告警，去重）
}

-- 种子已知服务名
for _, n in ipairs(KNOWN) do
  state.known[n] = true
end

-- ========== 私有函数 ==========

--- 未知服务名（形如 services.* 但未注册）告警一次，帮助定位拼写错误。
--- 仅当实现缺失时检查，避免对「已就绪」调用产生无谓开销。
--- @param name string
local function _warn_unknown(name)
  if type(name) ~= "string" then return end
  if name:sub(1, 9) ~= "services." then return end
  if state.known[name] or state.providers[name] ~= nil then return end
  if state.warned[name] then return end
  state.warned[name] = true
  require("NeoAI.kernel.logger").warn("[services] 未知服务名（拼写错误？）: %s", name)
end

--- 通知某服务的等待者（服务就绪后调用）
--- @param name string
--- @param impl any
local function _notify(name, impl)
  local list = state.waiters[name]
  if not list then return end
  state.waiters[name] = nil
  for _, cb in ipairs(list) do
    local ok, err = pcall(cb, impl)
    if not ok then
      local logger = require("NeoAI.kernel.logger")
      logger.warn("[services] wait 回调异常 %s: %s", name, tostring(err))
    end
  end
end

-- ========== 公开 API ==========

--- 登记服务实现（同名覆盖，用于替换/热重载）
--- @param name string
--- @param impl any
--- @return table M
function M.provide(name, impl)
  if type(name) ~= "string" or name == "" then
    error("services.provide: name 必须为非空字符串")
  end
  state.providers[name] = impl
  state.known[name] = true
  _notify(name, impl)
  return M
end

--- 获取当前服务实现；未提供/已禁用返回 nil
--- @param name string
--- @return any
function M.use(name)
  local impl = state.providers[name]
  if impl == nil then _warn_unknown(name) end
  return impl
end

--- 服务是否已提供
--- @param name string
--- @return boolean
function M.has(name)
  return state.providers[name] ~= nil
end

--- 注销服务实现；可选校验当前实现是否匹配
--- @param name string
--- @param expected any|nil 传入时仅当当前实现相同时才注销
--- @return boolean 是否注销成功
function M.revoke(name, expected)
  if state.providers[name] == nil then return false end
  if expected ~= nil and state.providers[name] ~= expected then return false end
  state.providers[name] = nil
  return true
end

--- 等待服务就绪（已就绪则立即回调）
--- @param name string
--- @param cb function(impl)
--- @return function 取消等待
function M.wait(name, cb)
  if state.providers[name] ~= nil then
    local ok, err = pcall(cb, state.providers[name])
    if not ok then
      local logger = require("NeoAI.kernel.logger")
      logger.warn("[services] wait 回调异常 %s: %s", name, tostring(err))
    end
    return function() end
  end
  _warn_unknown(name)
  if not state.waiters[name] then state.waiters[name] = {} end
  table.insert(state.waiters[name], cb)
  local removed = false
  return function()
    if removed then return end
    removed = true
    local list = state.waiters[name]
    if not list then return end
    for i, f in ipairs(list) do
      if f == cb then
        table.remove(list, i)
        break
      end
    end
  end
end

--- 列出已提供的服务名（按字典序）
--- @return table 数组
function M.list()
  local out = {}
  for name in pairs(state.providers) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- 重置（测试用）
function M.reset()
  state.providers = {}
  state.waiters = {}
  state.warned = {}
  -- 已知服务名（内置常量）保留；动态登记的名字随 providers 清空而失效。
  state.known = {}
  for _, n in ipairs(KNOWN) do
    state.known[n] = true
  end
end

return M
