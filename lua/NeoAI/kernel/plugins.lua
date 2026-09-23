--- 插件宿主
--- @module NeoAI.kernel.plugins
--- 管理插件状态、依赖注入、服务提供、启停与失败回滚。
---
--- 插件规格（spec）：
---   {
---     id = "services.model_service",        -- 全局唯一标识
---     deps = { "services.session" },        -- 依赖的插件 id（启动前先启动）
---     service = "services.model_service",   -- 可选：对外提供的服务名
---     module = "NeoAI.services.model_service", -- 可选：服务实现模块
---     start = function(ctx) ... end,         -- 可选：副作用启动，返回清理函数
---     stop = function(ctx) ... end,          -- 可选：额外清理
---   }
---
--- 生命周期：
---   register → start（先依赖、再提供服务、再执行 start）→ started
---   失败时回滚本次新启动的插件；stop 时逆序执行清理并注销服务。
--- 所有启动/停止幂等，可重复调用。

local services = require("NeoAI.kernel.services")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  plugins = {}, -- id -> { spec, status, cleanups, error }
  order = {}, -- 注册顺序
}

-- ========== 私有函数 ==========

--- 逆序执行清理函数列表
--- @param cleanups table
local function _run_cleanups(cleanups)
  local logger = require("NeoAI.kernel.logger")
  for i = #cleanups, 1, -1 do
    local ok, err = pcall(cleanups[i])
    if not ok then
      logger.warn("[plugins] 清理函数异常: %s", tostring(err))
    end
  end
end

--- 触发插件事件
--- @param event string
--- @param payload table
local function _emit(event, payload)
  local event_bus = require("NeoAI.kernel.event_bus")
  event_bus.emit(event, payload)
end

--- 递归启动插件及其依赖
--- @param id string
--- @param newly table 本次调用中新启动的插件 id 列表
--- @param visiting table 循环依赖检测
--- @return boolean ok
--- @return string|nil err
local function _start_recursive(id, newly, visiting)
  local p = state.plugins[id]
  if not p then return false, "未注册的插件: " .. tostring(id) end
  if p.status == "started" then return true end
  if visiting[id] or p.status == "starting" then
    return false, "检测到循环依赖: " .. tostring(id)
  end

  visiting[id] = true
  p.status = "starting"

  -- 1) 依赖优先
  for _, dep in ipairs(p.spec.deps or {}) do
    local ok, err = _start_recursive(dep, newly, visiting)
    if not ok then
      visiting[id] = nil
      p.status = "registered"
      return false, err
    end
  end

  -- 2) 提供服务实现
  if p.spec.service and p.spec.module then
    local ok, mod = pcall(require, p.spec.module)
    if not ok then
      visiting[id] = nil
      p.status = "registered"
      return false, ("服务模块加载失败 %s: %s"):format(p.spec.module, tostring(mod))
    end
    services.provide(p.spec.service, mod)
  end

  -- 3) 执行启动副作用
  local cleanups = {}
  local ctx = {
    id = id,
    plugins = M,
    services = services,
    on_cleanup = function(fn)
      if type(fn) == "function" then table.insert(cleanups, fn) end
    end,
  }
  if p.spec.start then
    local ok, res = pcall(p.spec.start, ctx)
    if not ok then
      _run_cleanups(cleanups)
      if p.spec.service then services.revoke(p.spec.service) end
      p.status = "failed"
      p.error = tostring(res)
      visiting[id] = nil
      _emit(events.PLUGIN_FAILED, { id = id, error = p.error })
      return false, p.error
    end
    if type(res) == "function" then
      table.insert(cleanups, res)
    elseif type(res) == "table" then
      for _, fn in ipairs(res) do
        if type(fn) == "function" then table.insert(cleanups, fn) end
      end
    end
  end

  p.cleanups = cleanups
  p.status = "started"
  p.error = nil
  visiting[id] = nil
  newly[#newly + 1] = id
  _emit(events.PLUGIN_LOADED, { id = id, service = p.spec.service })
  return true
end

--- 回滚本次调用中新启动的插件（逆序）
--- @param newly table
local function _rollback(newly)
  for i = #newly, 1, -1 do
    M.stop(newly[i])
  end
end

-- ========== 公开 API ==========

--- 注册插件规格
--- @param spec table
--- @return boolean, string|nil
function M.register(spec)
  if type(spec) ~= "table" or type(spec.id) ~= "string" or spec.id == "" then
    return false, "插件 spec 必须包含非空 id"
  end
  if state.plugins[spec.id] then
    return false, "插件已注册: " .. spec.id
  end
  state.plugins[spec.id] = {
    spec = spec,
    status = "registered",
    cleanups = {},
    error = nil,
  }
  state.order[#state.order + 1] = spec.id
  return true
end

--- 批量注册
--- @param specs table 数组
--- @return table { ok = number, errors = {...} }
function M.register_many(specs)
  local result = { ok = 0, errors = {} }
  for _, spec in ipairs(specs or {}) do
    local ok, err = M.register(spec)
    if ok then
      result.ok = result.ok + 1
    else
      result.errors[#result.errors + 1] = err
    end
  end
  return result
end

--- 注销插件（须先停止）
--- @param id string
--- @return boolean
function M.unregister(id)
  local p = state.plugins[id]
  if not p then return false end
  if p.status == "started" then M.stop(id) end
  state.plugins[id] = nil
  for i, v in ipairs(state.order) do
    if v == id then table.remove(state.order, i) break end
  end
  return true
end

--- 启动插件（含依赖）；失败时回滚本次新启动的插件
--- @param id string
--- @return boolean ok
--- @return string|nil err
function M.start(id)
  local p = state.plugins[id]
  if not p then return false, "未注册的插件: " .. tostring(id) end
  if p.status == "started" then return true end
  local newly = {}
  local ok, err = _start_recursive(id, newly, {})
  if not ok then
    _rollback(newly)
    return false, err
  end
  return true
end

--- 停止插件：逆序清理 + 注销服务（幂等）
--- @param id string
--- @return boolean
function M.stop(id)
  local p = state.plugins[id]
  if not p or p.status ~= "started" then return false end
  _run_cleanups(p.cleanups or {})
  if p.spec.stop then
    local ok, err = pcall(p.spec.stop, { id = id, plugins = M, services = services })
    if not ok then
      require("NeoAI.kernel.logger").warn("[plugins] stop 异常 %s: %s", id, tostring(err))
    end
  end
  if p.spec.service then services.revoke(p.spec.service) end
  p.cleanups = {}
  p.status = "stopped"
  _emit(events.PLUGIN_UNLOADED, { id = id, service = p.spec.service })
  return true
end

--- 启动所有已注册插件；任一失败则整批回滚
--- @return table { ok = boolean, failed = string|nil, error = string|nil }
function M.start_all()
  local before = {}
  for id, p in pairs(state.plugins) do
    if p.status == "started" then before[id] = true end
  end
  for _, id in ipairs(state.order) do
    local ok, err = M.start(id)
    if not ok then
      local to_stop = {}
      for _, oid in ipairs(state.order) do
        local p = state.plugins[oid]
        if p and p.status == "started" and not before[oid] then
          to_stop[#to_stop + 1] = oid
        end
      end
      for i = #to_stop, 1, -1 do M.stop(to_stop[i]) end
      return { ok = false, failed = id, error = err }
    end
  end
  return { ok = true }
end

--- 按给定顺序分帧异步启动插件（每帧启动 batch 个后让出事件循环，避免阻塞 UI）。
--- 依赖须在 ids 中靠前（调用方保证）；已启动的条目会跳过。
--- 失败时回滚本次新启动的插件（不停止调用前已启动的），并以 on_done(false, info) 回调。
--- @param ids table 插件 id 数组
--- @param on_done function(ok: boolean, info: table|nil) info = { failed, error }
--- @param opts table|nil { batch?: number } 每帧启动个数（默认 1）
function M.start_list_async(ids, on_done, opts)
  opts = opts or {}
  local batch = math.max(1, tonumber(opts.batch) or 1)
  ids = ids or {}
  if #ids == 0 then
    on_done(true, nil)
    return
  end

  local before = {}
  for id, p in pairs(state.plugins) do
    if p.status == "started" then before[id] = true end
  end

  local idx = 1
  local finished = false

  local function rollback_pass()
    for i = #state.order, 1, -1 do
      local oid = state.order[i]
      local p = state.plugins[oid]
      if p and p.status == "started" and not before[oid] then
        M.stop(oid)
      end
    end
  end

  local function step()
    if finished then return end
    local done = 0
    while done < batch and idx <= #ids do
      local id = ids[idx]
      idx = idx + 1
      local p = state.plugins[id]
      if p and p.status ~= "started" then
        local ok, err = M.start(id)
        if not ok then
          rollback_pass()
          finished = true
          on_done(false, { failed = id, error = err })
          return
        end
      end
      done = done + 1
    end
    if idx > #ids then
      finished = true
      on_done(true, nil)
      return
    end
    vim.defer_fn(step, 0)
  end

  vim.defer_fn(step, 0)
end

--- 停止所有已启动插件（注册顺序逆序）
--- @return number 停止数量
function M.stop_all()
  local count = 0
  for i = #state.order, 1, -1 do
    local p = state.plugins[state.order[i]]
    if p and p.status == "started" then
      if M.stop(state.order[i]) then count = count + 1 end
    end
  end
  return count
end

--- 获取插件规格
--- @param id string
--- @return table|nil
function M.spec(id)
  local p = state.plugins[id]
  return p and p.spec or nil
end

--- 获取插件状态
--- @param id string
--- @return string|nil "registered"|"starting"|"started"|"failed"|"stopped"
function M.status(id)
  local p = state.plugins[id]
  return p and p.status or nil
end

--- 是否已启动
--- @param id string
--- @return boolean
function M.is_started(id)
  local p = state.plugins[id]
  return p ~= nil and p.status == "started"
end

--- 列出已注册插件 id（注册顺序）
--- @return table 数组
function M.list()
  return vim.deepcopy(state.order)
end

--- 重置（测试用）：先停止全部再清空注册
function M.reset()
  M.stop_all()
  state.plugins = {}
  state.order = {}
end

return M
