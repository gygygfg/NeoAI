--- 输入框
--- @module NeoAI.ui.components.input_box
--- 聊天窗口底部的输入框。管理输入 buffer、提交、键位。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  buf = nil, -- 输入 buffer
  win_id = nil, -- 输入窗口
  on_submit = nil,
  on_cancel = nil,
  on_quit = nil,
  submitting = false,
  unsubs = {},
  on_enter = nil, -- prompt 回调引用（供测试/复用）
}

-- ========== 私有函数 ==========

--- 获取输入内容（去掉可能的 "> " 提示前缀）
local function _get_content()
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local content = table.concat(lines, "\n")
  content = content:gsub("^>%s*", ""):gsub("%s+$", "")
  return content
end

--- 设置输入内容（prompt 前缀由 prompt_setprompt 负责显示）
local function _set_content(content)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { content })
end

--- 绑定输入框键位
local function _set_keymaps()
  if not state.buf then return end
  local keymaps = config_store.get("keymaps.chat") or {}
  local send_conf = keymaps.send or {}
  local k_send_insert = send_conf.insert and send_conf.insert.key or "<C-s>"
  local k_send_normal = send_conf.normal and send_conf.normal.key or "<CR>"
  local k_cancel = keymaps.cancel and keymaps.cancel.key or "<Esc>"
  local k_quit = keymaps.quit and keymaps.quit.key or "q"

  -- 普通模式：退出聊天窗口
  if k_quit and k_quit ~= "" then
    vim.keymap.set("n", k_quit, function()
      if state.on_quit then state.on_quit() end
    end, { buffer = state.buf, desc = "NeoAI 退出" })
  end

  -- 插入模式：发送 / 换行 / 退出
  vim.keymap.set("i", k_send_insert, function()
    if state.submitting then return end
    local content = _get_content()
    if content == "" then return end
    M.submit(content)
  end, { buffer = state.buf, desc = "NeoAI 发送" })
  vim.keymap.set("i", k_cancel, function()
    if state.submitting and state.on_cancel then
      state.on_cancel()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k_cancel, true, false, true), "n", false)
    end
  end, { buffer = state.buf, desc = "NeoAI 取消/退出插入" })

  -- 普通模式：进入插入 / 发送
  vim.keymap.set("n", k_send_normal, function()
    if state.submitting then return end
    local content = _get_content()
    if content == "" then
      vim.api.nvim_feedkeys("i", "n", false)
      return
    end
    M.submit(content)
  end, { buffer = state.buf, desc = "NeoAI 发送" })
  vim.keymap.set("n", "i", function()
    vim.api.nvim_feedkeys("A", "n", false)
  end, { buffer = state.buf, desc = "NeoAI 输入" })
  vim.keymap.set("n", "a", function()
    vim.api.nvim_feedkeys("A", "n", false)
  end, { buffer = state.buf, desc = "NeoAI 输入" })
end

-- ========== 公开 API ==========

--- 创建输入框
--- @param opts table { on_submit?, on_cancel?, buf?, win_id? }
--- @return table { buf, win_id }
function M.create(opts)
  opts = opts or {}
  state.on_submit = opts.on_submit
  state.on_cancel = opts.on_cancel
  state.on_quit = opts.on_quit

  state.buf = opts.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "prompt"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].modifiable = true
  vim.bo[state.buf].filetype = "neoai_input"
  -- 用 nvim 原生 prompt 显示 "> " 前缀（避免默认 "% " 与手动前缀叠加）
  vim.fn.prompt_setprompt(state.buf, "> ")
  -- prompt 回调：回车发送（兼容任何终端，避免 <C-s> 被终端流量控制吞掉）
  state.on_enter = function()
    if state.submitting then return end
    local content = _get_content()
    if content == "" then return end
    M.submit(content)
  end
  vim.fn.prompt_setcallback(state.buf, state.on_enter)
  _set_content("")
  state.win_id = opts.win_id
  _set_keymaps()
  return { buf = state.buf, win_id = state.win_id }
end

--- 绑定到已存在的窗口（用于 split 布局）
--- @param win_id number
function M.attach_window(win_id)
  state.win_id = win_id
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_set_buf(win_id, state.buf)
  end
end

--- 获取输入 buffer
--- @return number|nil
function M.get_buf()
  return state.buf
end

--- 获取输入窗口
--- @return number|nil
function M.get_win()
  return state.win_id
end

--- 获取回车提交回调（测试用；等价于 prompt 回调）
--- @return function|nil
function M.get_enter_callback()
  return state.on_enter
end

--- 聚焦输入框并进入插入模式
function M.focus()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_set_current_win(state.win_id)
  end
  vim.api.nvim_feedkeys("A", "n", false)
end

--- 设置提交回调
--- @param fn function(content)
function M.set_on_submit(fn)
  state.on_submit = fn
end

--- 设置取消回调
--- @param fn function()
function M.set_on_cancel(fn)
  state.on_cancel = fn
end

--- 提交
--- @param content string|nil 可选，直接传入内容
--- @return boolean 是否已提交
function M.submit(content)
  if state.submitting then return false end
  content = content or _get_content()
  content = content:gsub("^>%s*", ""):gsub("%s+$", "")
  if content == "" then return false end
  state.submitting = true
  if state.on_submit then
    state.on_submit(content)
  end
  return true
end

--- 提交完成（发送完成后重置输入框）
function M.on_submitted()
  state.submitting = false
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    _set_content("")
  end
end

--- 取消输入
function M.cancel()
  if state.submitting and state.on_cancel then
    state.on_cancel()
  end
end

--- 清空输入
function M.clear()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    _set_content("")
  end
end

--- 重置（测试用）
function M.reset()
  for _, unsub in ipairs(state.unsubs) do unsub() end
  state.unsubs = {}
  state.buf = nil
  state.win_id = nil
  state.on_submit = nil
  state.on_cancel = nil
  state.on_quit = nil
  state.on_enter = nil
  state.submitting = false
end

return M
