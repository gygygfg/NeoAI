--- 全局键位插件
--- @module NeoAI.plugins.builtin.keymaps
--- 按 config.keymaps.global 注册全局快捷键；卸载时删除。经 kernel.services.use 获取 UI 服务。
--- `M.run(action)` 抽出自成一体，供懒加载占位键位在首次触发时就绪后复用，避免重复服务逻辑。

local services = require("NeoAI.kernel.services")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 公开 API ==========

--- 执行一个全局键位动作（就绪后调用；服务缺失时静默降级）
--- @param action string "open_chat"|"open_tree"|"close_all"|"toggle_ui"
--- @return any
function M.run(action)
  local ui = services.use("services.ui")
  if not ui then return nil end
  if action == "open_chat" then
    return ui.open_chat()
  elseif action == "open_tree" then
    return ui.open_tree()
  elseif action == "close_all" then
    return ui.close_all()
  elseif action == "toggle_ui" then
    if ui.has_windows() then
      return ui.close_all()
    end
    return ui.open_tree()
  end
  return nil
end

--- 注册全局快捷键
--- @return function 清理函数
function M.start()
  local keymaps = config_store.get("keymaps.global") or {}
  local registered = {} -- { key, ... }

  for action, conf in pairs(keymaps) do
    if conf and conf.key then
      vim.keymap.set("n", conf.key, function()
        M.run(action)
      end, { desc = conf.desc or ("NeoAI " .. action) })
      registered[#registered + 1] = conf.key
    end
  end

  return function()
    for _, key in ipairs(registered) do
      pcall(vim.keymap.del, "n", key)
    end
  end
end

return M
