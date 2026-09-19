--- 内置插件目录与默认组合
--- @module NeoAI.plugins.catalog
--- 把现有功能登记为可替换服务与副作用插件，并处理配置覆盖：
---   plugins.builtin        -- false 时不登记任何内置插件
---   plugins.disabled       -- 禁用的插件/服务 id 列表
---   plugins.entries[id]    -- false 禁用；{ module = "..." } 替换实现
--- 被禁用插件所依赖的下游插件会一并移除（依赖闭包）。

local plugins = require("NeoAI.kernel.plugins")
local services = require("NeoAI.kernel.services")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有函数 ==========

--- 判断插件是否被配置禁用
--- @param cfg table plugins 配置
--- @param id string
--- @return boolean
local function _disabled(cfg, id)
  local entry = (cfg.entries or {})[id]
  if entry == false then return true end
  if type(entry) == "table" and entry.enabled == false then return true end
  for _, v in ipairs(cfg.disabled or {}) do
    if v == id then return true end
  end
  return false
end

--- 应用 entries[id].module 替换
--- @param cfg table
--- @param spec table
local function _apply_entry(cfg, spec)
  local entry = (cfg.entries or {})[spec.id]
  if type(entry) == "table" and entry.module then
    spec.module = entry.module
  end
end

--- 构造单个工具插件规格
--- @param default_mod string
--- @return table
local function _tool_spec(default_mod)
  local short = default_mod:match("([^.]+)$")
  return {
    id = "tool." .. short,
    module = default_mod,
    deps = { "services.tools", "services.sandbox" },
    start = function(ctx)
      local tools = require("NeoAI.tools")
      local spec = ctx.plugins.spec(ctx.id)
      local mod_name = (spec and spec.module) or default_mod
      local sandbox = ctx.services.use("services.sandbox")
      local ok, err = tools.load_module(mod_name, { sandbox = sandbox })
      if not ok then error(err) end
      return function()
        tools.unload_module(mod_name)
      end
    end,
  }
end

--- 服务提供方规格（纯 provider，或带生命周期）
--- @return table 数组
local function _service_specs()
  return {
    { id = "services.session", module = "NeoAI.core.session.session_store", service = "services.session" },
    { id = "services.agent", module = "NeoAI.core.agent.agent", service = "services.agent" },
    {
      id = "services.tools", module = "NeoAI.tools", service = "services.tools",
      start = function() require("NeoAI.tools").init({ builtin = false }) end,
    },
    {
      id = "services.sandbox", module = "NeoAI.sandbox", service = "services.sandbox",
      start = function() require("NeoAI.sandbox").init() end,
      stop = function() pcall(require("NeoAI.sandbox").shutdown) end,
    },
    { id = "services.model_service", module = "NeoAI.services.model_service", service = "services.model_service" },
    {
      id = "services.chat_service", module = "NeoAI.services.chat_service", service = "services.chat_service",
      deps = { "services.session", "services.agent" },
    },
    {
      id = "services.tool_service", module = "NeoAI.services.tool_service", service = "services.tool_service",
      deps = { "services.tools" },
    },
    { id = "services.skills", module = "NeoAI.services.skills", service = "services.skills" },
    {
      id = "services.mcp", module = "NeoAI.services.mcp", service = "services.mcp",
      deps = { "services.tools" },
    },
    {
      id = "services.status", module = "NeoAI.services.status", service = "services.status",
      deps = { "services.chat_service" },
    },
    { id = "services.herder", module = "NeoAI.services.herder", service = "services.herder" },
  }
end

--- 副作用插件规格
--- @return table 数组
local function _side_effect_specs()
  return {
    {
      id = "ui", module = "NeoAI.ui", service = "services.ui",
      deps = { "services.chat_service" },
      start = function() require("NeoAI.ui").init() end,
      stop = function() pcall(require("NeoAI.ui").reset) end,
    },
    {
      id = "commands",
      deps = { "ui", "services.chat_service", "services.tool_service", "services.status" },
      start = function() return require("NeoAI.plugins.builtin.commands").start() end,
    },
    {
      id = "keymaps", deps = { "ui" },
      start = function() return require("NeoAI.plugins.builtin.keymaps").start() end,
    },
    {
      id = "model_prefetch", deps = { "services.model_service" },
      start = function()
        local cfg = config_store.get("ai.model_refresh") or {}
        if cfg.on_startup == false then return end
        vim.schedule(function()
          if require("NeoAI.kernel.lifecycle").is_shutting_down() then return end
          local model_service = services.use("services.model_service")
          if model_service then pcall(model_service.prefetch) end
        end)
      end,
    },
    {
      id = "mcp.connect", deps = { "services.mcp", "services.tools" },
      start = function()
        local mcp = services.use("services.mcp")
        if mcp then mcp.init() end
      end,
      stop = function()
        local mcp = services.use("services.mcp")
        if mcp then pcall(mcp.shutdown) end
      end,
    },
    {
      id = "skills.scan", deps = { "services.skills" },
      start = function()
        local skills = services.use("services.skills")
        if skills then skills.init() end
      end,
      stop = function()
        local skills = services.use("services.skills")
        if skills then skills.reset() end
      end,
    },
    {
      -- agent 循环内共用同一沙箱会话；agentEnd 时轮换并迁移暂存内容
      id = "sandbox.session", deps = { "services.sandbox" },
      start = function()
        local sandbox = services.use("services.sandbox")
        if sandbox then return sandbox.watch_sessions() end
      end,
    },
    {
      id = "statusline", deps = { "services.status" },
      start = function()
        local status = services.use("services.status")
        if not status then return end
        status.watch()
        pcall(status.ensure_lualine_extension)
      end,
      stop = function()
        local status = services.use("services.status")
        if status then status.unwatch() end
      end,
    },
    {
      id = "herder", deps = { "services.herder" },
      start = function()
        local herder = services.use("services.herder")
        if herder then herder.init() end
      end,
      stop = function()
        local herder = services.use("services.herder")
        if herder then herder.reset() end
      end,
    },
  }
end

--- 汇总并过滤全部内置规格（禁用 + 依赖闭包）
--- @param cfg table
--- @return table 数组
local function _collect_specs(cfg)
  local specs = {}
  local function add(list)
    for _, s in ipairs(list) do specs[#specs + 1] = s end
  end
  add(_service_specs())
  add(_side_effect_specs())
  for _, mod_name in ipairs(require("NeoAI.tools").BUILTIN_MODULES or {}) do
    specs[#specs + 1] = _tool_spec(mod_name)
  end

  -- 应用禁用与实现替换
  local present = {}
  for _, s in ipairs(specs) do
    if not _disabled(cfg, s.id) then
      _apply_entry(cfg, s)
      present[s.id] = true
    end
  end

  -- 依赖闭包：依赖缺失则一并移除
  local changed = true
  while changed do
    changed = false
    for _, s in ipairs(specs) do
      if present[s.id] then
        for _, dep in ipairs(s.deps or {}) do
          if not present[dep] then
            present[s.id] = nil
            changed = true
            break
          end
        end
      end
    end
  end

  local out = {}
  for _, s in ipairs(specs) do
    if present[s.id] then out[#out + 1] = s end
  end
  return out
end

-- ========== 公开 API ==========

--- 按当前配置构建内置插件规格（禁用/替换/依赖闭包均已应用；不产生副作用）
--- @return table 数组
function M.build_specs()
  local cfg = config_store.get("plugins") or {}
  if cfg.builtin == false then return {} end
  return _collect_specs(cfg)
end

--- 登记内置插件（不启动）
--- @return table { ok = number, errors = {...} }
function M.register_builtins()
  local specs = M.build_specs()
  if #specs == 0 then return { ok = 0, errors = {} } end
  return plugins.register_many(specs)
end

--- 登记并启动内置插件
--- @return table { ok = boolean, failed = string|nil, error = string|nil }
function M.setup()
  M.register_builtins()
  return plugins.start_all()
end

--- 计算将被登记的内置插件 id（测试/诊断用，不产生副作用）
--- @return table 数组
function M.builtin_ids()
  local out = {}
  for _, s in ipairs(M.build_specs()) do out[#out + 1] = s.id end
  return out
end

return M
