--- 工具系统入口
--- @module NeoAI.tools
--- 初始化工具注册表 + 加载内置工具 + 应用审批配置。
--- 插件化后：内置工具由各自插件（tool.*）调用 load_module/unload_module 独立加载与释放；
--- init({ builtin = false }) 仅应用审批配置，供 services.tools 插件使用。

local registry = require("NeoAI.tools.registry")
local executor = require("NeoAI.tools.executor")
local validator = require("NeoAI.tools.validator")
local packer = require("NeoAI.tools.packer")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  approval_applied = false,
  loaded = {}, -- module_name -> { tool_name, ... }
}

--- 内置工具模块表
local BUILTIN_MODULES = {
  "NeoAI.tools.builtin.file_ops",
  "NeoAI.tools.builtin.shell",
  "NeoAI.tools.builtin.git_ops",
  "NeoAI.tools.builtin.lsp_ops",
  "NeoAI.tools.builtin.tree_ops",
  "NeoAI.tools.builtin.log_ops",
  "NeoAI.tools.builtin.plan",
  "NeoAI.tools.builtin.terminal",
  "NeoAI.tools.builtin.todo",
  "NeoAI.tools.builtin.plan_mode",
  "NeoAI.tools.builtin.ask_user",
  "NeoAI.tools.builtin.read_image",
  "NeoAI.tools.builtin.web_fetch",
  "NeoAI.tools.builtin.skills",
  "NeoAI.tools.builtin.reload_all",
}

-- ========== 公开 API ==========

--- 应用审批配置（来自 config_store）
function M.apply_approval()
  local tools_cfg = config_store.get("tools") or {}
  local approval = tools_cfg.approval or {}
  registry.apply_approval_config(approval.per_tool)
  state.approval_applied = true
end

--- 加载单个内置工具模块（幂等：同名工具覆盖）
--- 加载器是沙箱强制点：所有经此加载的工具都被附加 __sandbox 规格，
--- 执行时由 tools.executor 统一过沙箱门禁（fail-closed）。
--- @param mod_name string
--- @param opts table|nil { sandbox? = table } 沙箱服务（缺省回退 services.use）
--- @return boolean ok
--- @return table|string names_or_err
function M.load_module(mod_name, opts)
  opts = opts or {}
  local ok, mod = pcall(require, mod_name)
  if not ok then return false, tostring(mod) end
  if not (mod and mod.get_tools) then
    return false, "模块缺少 get_tools: " .. mod_name
  end
  local sandbox = opts.sandbox
  if not sandbox then
    sandbox = require("NeoAI.kernel.services").use("services.sandbox")
  end
  local tools = mod.get_tools() or {}
  local names = {}
  for _, tool in ipairs(tools) do
    if sandbox and sandbox.attach then
      sandbox.attach(tool)
    else
      require("NeoAI.sandbox.wrapper").attach(tool)
    end
    registry.update(tool)
    names[#names + 1] = tool.name
  end
  state.loaded[mod_name] = names
  return true, names
end

--- 卸载单个内置工具模块（移除工具并调用模块 reset）
--- @param mod_name string
--- @return boolean
function M.unload_module(mod_name)
  local names = state.loaded[mod_name]
  if not names then return false end
  for _, name in ipairs(names) do
    registry.remove(name)
  end
  state.loaded[mod_name] = nil
  local ok, mod = pcall(require, mod_name)
  if ok and mod and mod.reset then pcall(mod.reset) end
  return true
end

--- 初始化工具系统
--- @param opts table|nil { builtin?: boolean }
--- @return table tools
function M.init(opts)
  opts = opts or {}
  local logger = require("NeoAI.kernel.logger")

  if not state.approval_applied then
    M.apply_approval()
  end

  local tools_cfg = config_store.get("tools") or {}
  if opts.builtin ~= false and tools_cfg.builtin ~= false then
    for _, mod_name in ipairs(BUILTIN_MODULES) do
      local ok, err = M.load_module(mod_name)
      if not ok then
        logger.warn("[tools] 内置工具加载错误: %s: %s", mod_name, tostring(err))
      end
    end
    logger.info("[tools] 内置工具加载完成: %d 个", registry.count())
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
  local loaded_names = {}
  for mod_name in pairs(state.loaded) do
    loaded_names[#loaded_names + 1] = mod_name
  end
  for _, mod_name in ipairs(loaded_names) do
    M.unload_module(mod_name)
  end
  local errors = 0
  for _, mod_name in ipairs(BUILTIN_MODULES) do
    local ok = M.load_module(mod_name)
    if not ok then errors = errors + 1 end
  end
  return errors == 0
end

--- 已加载的内置工具模块（测试/调试用）
--- @return table module_name -> tool names
function M.loaded_modules()
  return vim.deepcopy(state.loaded)
end

--- 重置（测试用）
function M.reset()
  state.approval_applied = false
  state.loaded = {}
end

--- 工具系统子模块引用
M.registry = registry
M.executor = executor
M.validator = validator
M.packer = packer
M.BUILTIN_MODULES = BUILTIN_MODULES

return M
