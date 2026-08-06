--- 工具审批弹窗
--- @module NeoAI.ui.components.tool_approval
--- 工具执行审批 UI。注册到 tool_service。

local tool_service = require("NeoAI.services.tool_service")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  on_confirm = nil,
  on_cancel = nil,
  on_confirm_all = nil,
}

-- ========== 私有函数 ==========

local function _close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  state.win_id = nil
  state.buf = nil
  state.on_confirm = nil
  state.on_cancel = nil
  state.on_confirm_all = nil
end

--- 设置快捷键
local function _set_keymaps()
  if not state.buf then return end
  local config = require("NeoAI.kernel.config_store")
  local approval_cfg = (config.get("keymaps.chat.approval") or {})
  local k_confirm = approval_cfg.confirm and approval_cfg.confirm.key or "<CR>"
  local k_confirm_all = approval_cfg.confirm_all and approval_cfg.confirm_all.key or "A"
  local k_cancel = approval_cfg.cancel and approval_cfg.cancel.key or "<Esc>"
  local k_cancel_reason = approval_cfg.cancel_with_reason and approval_cfg.cancel_with_reason.key or "C"

  vim.keymap.set("n", k_confirm, function()
    if state.on_confirm then state.on_confirm() end
    _close()
  end, { buffer = state.buf })
  vim.keymap.set("n", k_confirm_all, function()
    if state.on_confirm_all then state.on_confirm_all() end
    _close()
  end, { buffer = state.buf })
  vim.keymap.set("n", k_cancel, function()
    if state.on_cancel then state.on_cancel("用户取消") end
    _close()
  end, { buffer = state.buf })
  vim.keymap.set("n", k_cancel_reason, function()
    if state.on_cancel then state.on_cancel("用户拒绝") end
    _close()
  end, { buffer = state.buf })
end

-- ========== 公开 API ==========

--- 展示审批弹窗
--- @param config table { text, tool_name, args, on_confirm, on_cancel, on_confirm_all }
function M.show(config)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    _close()
  end
  state.on_confirm = config.on_confirm
  state.on_cancel = config.on_cancel
  state.on_confirm_all = config.on_confirm_all

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_approval"
  local lines = vim.split(config.text or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

  local height = math.min(#lines + 4, 20)
  local width = math.min(70, vim.o.columns - 10)
  state.win_id = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = "🔒 工具审批: " .. (config.tool_name or ""),
    title_pos = "center",
  })
  vim.wo[state.win_id].wrap = true
  _set_keymaps()
end

--- 隐藏弹窗
function M.hide()
  _close()
end

--- 注册到 tool_service
function M.init()
  tool_service.set_approval_ui({
    show = M.show,
    hide = M.hide,
  })
end

--- 重置（测试用）
function M.reset()
  _close()
end

return M
