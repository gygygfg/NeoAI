--- 工具系统入口
--- @module NeoAI.tools
--- 初始化工具注册表 + 加载内置工具 + 应用审批配置。

local registry = require("NeoAI.tools.registry")
local executor = require("NeoAI.tools.executor")
local validator = require("NeoAI.tools.validator")
local packer = require("NeoAI.tools.packer")
local config_store = require("NeoAI.kernel.config_store")
local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有状态 ==========

local state = {
  initialized = false,
}

-- ========== 私有函数 ==========

--- 内置工具模块表
local BUILTIN_MODULES = {
  "NeoAI.tools.builtin.file_ops",
  "NeoAI.tools.builtin.shell",
  "NeoAI.tools.builtin.git_ops",
  "NeoAI.tools.builtin.lsp_ops",
  "NeoAI.tools.builtin.tree_ops",
  "NeoAI.tools.builtin.log_ops",
  "NeoAI.tools.builtin.plan",
  "NeoAI.tools.builtin.todo",
  "NeoAI.tools.builtin.plan_mode",
}

--- 加载内置工具
--- @return table 错误数组
local function _load_builtin_tools()
  local errors = {}
  for _, mod_name in ipairs(BUILTIN_MODULES) do
    local ok, mod = pcall(require, mod_name)
    if ok then
      if mod and mod.get_tools then
        local result = registry.register_many(mod.get_tools())
        if #result.errors > 0 then
          for _, e in ipairs(result.errors) do errors[#errors + 1] = mod_name .. ": " .. e end
        end
      end
    else
      errors[#errors + 1] = mod_name .. ": " .. tostring(mod)
    end
  end
  return errors
end

-- ========== 公开 API ==========

--- 初始化工具系统
--- @return table tools
function M.init()
  if state.initialized then return M end
  state.initialized = true
  local logger = require("NeoAI.kernel.logger")

  -- 应用审批配置
  local tools_cfg = config_store.get("tools") or {}
  local approval = tools_cfg.approval or {}
  registry.apply_approval_config(approval.per_tool)

  -- 同步加载内置工具（仅注册定义，无 I/O，确保首个 Agent 请求前已就绪）
  if tools_cfg.builtin ~= false then
    local errors = _load_builtin_tools()
    if #errors > 0 then
      for _, e in ipairs(errors) do
        logger.warn("[tools] 内置工具加载错误: %s", e)
      end
    end
    logger.info("[tools] 内置工具加载完成: %d 个", registry.count())
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    event_bus.emit(events.TOOL_LOOP_FINISHED, { kind = "tools_loaded", count = registry.count() })
  end

  return M
end

--- 获取所有已注册工具
--- @return table 数组
function M.get_tools()
  return registry.list()
end

--- 按名称获取工具定义
--- @param name string
--- @return table|nil
function M.get_tool(name)
  return registry.get(name)
end

--- 执行工具
--- @param tool_name string
--- @param args any
--- @param ctx table|nil
--- @return Deferred
function M.execute(tool_name, args, ctx)
  return executor.execute(tool_name, args, ctx)
end

--- 工具数量
--- @return number
function M.count()
  return registry.count()
end

--- 重新加载内置工具（调试）
--- @return boolean
function M.reload_tools()
  registry.reset()
  local errors = _load_builtin_tools()
  return #errors == 0
end

--- 工具系统子模块引用
M.registry = registry
M.executor = executor
M.validator = validator
M.packer = packer

return M
