--- 全局键位插件
--- @module NeoAI.plugins.builtin.keymaps
--- 按 config.keymaps.global 注册全局快捷键；卸载时删除。经 kernel.services.use 获取 UI 服务。

local services = require("NeoAI.kernel.services")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 公开 API ==========

--- 注册全局快捷键
--- @return function 清理函数
function M.start()
  local keymaps = config_store.get("keymaps.global") or {}
  local registered = {} -- { [mode] = { key, ... } }

  local function _bind(key, fn, desc)
    vim.keymap.set("n", key, fn, { desc = desc })
    registered[#registered + 1] = key
  end

  for action, conf in pairs(keymaps) do
    if conf and conf.key then
      local fn
      if action == "open_chat" then
        fn = function()
          local ui = services.use("services.ui")
          if ui then ui.open_chat() end
        end
      elseif action == "open_tree" then
        fn = function()
          local ui = services.use("services.ui")
          if ui then ui.open_tree() end
        end
      elseif action == "close_all" then
        fn = function()
          local ui = services.use("services.ui")
          if ui then ui.close_all() end
        end
      elseif action == "toggle_ui" then
        fn = function()
          local ui = services.use("services.ui")
          if not ui then return end
          if ui.has_windows() then ui.close_all() else ui.open_tree() end
        end
      end
      if fn then
        _bind(conf.key, fn, conf.desc or ("NeoAI " .. action))
      end
    end
  end

  return function()
    for _, key in ipairs(registered) do
      pcall(vim.keymap.del, "n", key)
    end
  end
end

return M
