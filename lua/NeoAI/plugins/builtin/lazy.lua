--- 懒加载占位插件
--- @module NeoAI.plugins.builtin.lazy
--- setup() 时注册全部 NeoAI 命令与全局键位的「占位符」：首次触发才异步启动插件图。
--- 分两阶段：UI/打开类命令在阶段 1（UI 就绪）后执行；其余命令等全量启动完成后再执行，
--- 避免访问尚未就绪的沙箱/工具服务。真实命令与键位注册时会 force 覆盖占位符。
---
--- 无配置：懒加载为默认行为。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- 仅依赖阶段 1（UI/chat/status）即可执行的命令；其余等全量启动。
local PHASE1_COMMANDS = {
  NeoAIOpen = true,
  NeoAIChat = true,
  NeoAITree = true,
  NeoAIClose = true,
  NeoAIKeymaps = true,
  NeoAIChatStatus = true,
  NeoAICycleDisplay = true,
  NeoAIReloadDisplay = true,
  NeoAIPlan = true,
  NeoAIApprovePlan = true,
  NeoAIStatusline = true,
}

-- ========== 私有函数 ==========

--- user_command 回调的 mods 字符串 → nvim_cmd mods 表
--- @param mods any
--- @return table
local function _mods_table(mods)
  if type(mods) == "table" then return mods end
  local out = {}
  if type(mods) == "string" then
    for m in mods:gmatch("[%w!]+") do
      m = m:gsub("!$", "")
      if m ~= "" then out[m] = true end
    end
  end
  return out
end

--- 转发一次原始命令调用到真实命令
--- @param name string
--- @param opts table user_command 回调参数
local function _redispatch(name, opts)
  local cmd = {
    cmd = name,
    args = opts.fargs,
    bang = opts.bang,
  }
  local mods = _mods_table(opts.mods)
  if next(mods) ~= nil then cmd.mods = mods end
  if type(opts.count) == "number" and opts.count >= 0 then cmd.count = opts.count end
  if opts.range and opts.range > 0 then
    cmd.range = { opts.line1, opts.line2 }
  end
  local ok, err = pcall(vim.api.nvim_cmd, cmd, {})
  if not ok then
    vim.notify("[NeoAI] 命令执行失败: " .. name .. "\n" .. tostring(err), vim.log.levels.ERROR)
  end
end

-- ========== 公开 API ==========

--- 注册占位命令与键位
--- @param api table { ensure_phase1: fun(cb)|nil, ensure_started: fun(cb), is_started: fun():boolean }
--- @return function 清理函数
function M.register(api)
  local commands = require("NeoAI.plugins.builtin.commands").NAMES or {}
  local registered_cmds = {}
  local dispatching = {}
  local registered_keys = {}

  for _, name in ipairs(commands) do
    local needs_full = not PHASE1_COMMANDS[name]
    vim.api.nvim_create_user_command(name, function(opts)
      -- 防重入：真实命令缺失时避免占位符自递归
      if dispatching[name] then
        vim.notify("[NeoAI] 命令暂不可用: " .. name, vim.log.levels.WARN)
        return
      end
      local function run(ok)
        if not ok then
          vim.notify("[NeoAI] 懒加载启动失败，命令未执行: " .. name, vim.log.levels.ERROR)
          return
        end
        dispatching[name] = true
        _redispatch(name, opts)
        dispatching[name] = nil
      end
      if needs_full then
        api.ensure_started(run)
      else
        api.ensure_phase1(run)
      end
    end, { nargs = "*", force = true, desc = "NeoAI: " .. name .. "（懒加载）" })
    registered_cmds[#registered_cmds + 1] = name
  end

  -- 全局键位占位：阶段 1 就绪后执行动作
  local keymaps = config_store.get("keymaps.global") or {}
  for action, conf in pairs(keymaps) do
    if conf and conf.key then
      vim.keymap.set("n", conf.key, function()
        api.ensure_phase1(function(ok)
          if not ok then return end
          local ok2, err = pcall(function()
            require("NeoAI.plugins.builtin.keymaps").run(action)
          end)
          if not ok2 then
            vim.notify("[NeoAI] 键位执行失败: " .. tostring(action) .. "\n" .. tostring(err), vim.log.levels.ERROR)
          end
        end)
      end, { desc = conf.desc or ("NeoAI " .. action) })
      registered_keys[#registered_keys + 1] = conf.key
    end
  end

  return function()
    -- 阶段 1 已完成时真实命令/键位已接管清理，勿删占位造成误删。
    if api.is_started() then return end
    for _, name in ipairs(registered_cmds) do
      pcall(vim.api.nvim_del_user_command, name)
    end
    for _, key in ipairs(registered_keys) do
      pcall(vim.keymap.del, "n", key)
    end
  end
end

return M
