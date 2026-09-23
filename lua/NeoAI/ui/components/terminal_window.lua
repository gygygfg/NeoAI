--- 交互式终端悬浮窗
--- @module NeoAI.ui.components.terminal_window
--- 用 `nvim_open_term` 在浮动窗口里渲染交互式命令的终端画面（真实 VT 模拟），
--- 并支持手动键入转发给会话。多会话按 id 独立窗口。
--- headless（无 UI）下所有接口为安全 no-op。

local M = {}

-- ========== 私有状态 ==========

local state = {
  items = {},      -- id -> { id, buf, win, chan }
  on_key = false,  -- vim.on_key 是否已安装
  ns = nil,        -- on_key 命名空间 id
}

-- ========== 私有函数 ==========

--- 当前窗口对应的会话 id（手动输入转发用）
--- @return string|nil
local function _current_id()
  local win = vim.api.nvim_get_current_win()
  local ok, id = pcall(function() return vim.w[win].neoai_pty_id end)
  if ok and type(id) == "string" then return id end
  return nil
end

--- 全局按键转发：焦点在终端窗时，把按键转成字节写入会话（交互式）。
local function _on_key(key)
  local id = _current_id()
  if not id then return key end
  -- 仅在终端/插入模式转发按键，Normal 模式下保留原按键（可 : 命令、i 进入输入、<C-q> 关窗）
  local mode = vim.api.nvim_get_mode().mode
  if mode ~= "t" and mode ~= "i" then return key end
  -- 保留退出终端模式的按键，避免把用户困在终端里
  if key == "<Esc>" or key == "<C-\\>" or key == "<C-n>" then return key end
  local pty = require("NeoAI.kernel.services").use("services.pty")
  if not pty then return key end
  local b = pty.key_bytes and pty.key_bytes(key)
  if b then
    pcall(pty.send_bytes, id, b)
    -- 无控制终端时 Ctrl-C 的 ISIG 不生效，额外向进程组发 SIGINT
    local lower = key:lower()
    if lower == "<c-c>" or lower == "<ctrl-c>" or lower == "^c" then
      pcall(pty.signal, id, 2)
    end
    return ""
  end
  return key
end

local function _install_on_key()
  if state.on_key then return end
  state.on_key = true
  state.ns = vim.api.nvim_create_namespace("NeoAITerminalInput")
  vim.on_key(_on_key, state.ns)
end

local function _uninstall_on_key()
  if not state.on_key then return end
  state.on_key = false
  if state.ns then
    pcall(vim.on_key, nil, state.ns)
    state.ns = nil
  end
end

-- ========== 公开 API ==========

--- 是否有可用 UI
--- @return boolean
local function _has_ui()
  local ok, uis = pcall(vim.api.nvim_list_uis)
  return ok and type(uis) == "table" and #uis > 0
end

--- 打开（或复用）某会话的悬浮终端
--- @param session table 需含 id；用于标题
--- @param title string|nil
--- @return table|nil handle
function M.open(session, title)
  if not _has_ui() then return nil end
  local id = type(session) == "table" and session.id or tostring(session)
  if not id then return nil end
  local it = state.items[id]
  if it and vim.api.nvim_win_is_valid(it.win) then return it end

  local ok, res = pcall(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "neoai_terminal"
    local width = math.min(90, math.max(20, vim.o.columns - 8))
    local height = math.min(24, math.max(5, vim.o.lines - 8))
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = width,
      height = height,
      col = math.floor((vim.o.columns - width) / 2),
      row = math.max(1, math.floor((vim.o.lines - height) / 2)),
      style = "minimal",
      border = "rounded",
      title = title or ("命令终端 · " .. id),
      title_pos = "center",
    })
    local chan = vim.api.nvim_open_term(buf, {})
    vim.w[win].neoai_pty_id = id
    -- Normal 模式 <C-q> 关闭悬浮窗（不结束命令）
    vim.keymap.set("n", "<C-q>", function() M.close(id) end,
      { buffer = buf, silent = true, desc = "关闭 NeoAI 终端窗口" })
    return { id = id, buf = buf, win = win, chan = chan }
  end)
  if not ok or not res then return nil end
  state.items[id] = res
  _install_on_key()
  return res
end

--- 把终端输出喂给窗口
--- @param id string
--- @param text string
function M.feed(id, text)
  local it = state.items[id]
  if not it or type(text) ~= "string" or text == "" then return end
  pcall(vim.api.nvim_chan_send, it.chan, text)
end

--- 设置窗口标题
--- @param id string
--- @param title string
function M.set_title(id, title)
  local it = state.items[id]
  if not it or not vim.api.nvim_win_is_valid(it.win) then return end
  pcall(vim.api.nvim_win_set_config, it.win, { title = title, title_pos = "center" })
end

--- 关闭某会话窗口
--- @param id string
function M.close(id)
  local it = state.items[id]
  if not it then return end
  state.items[id] = nil
  if it.win and vim.api.nvim_win_is_valid(it.win) then
    pcall(vim.api.nvim_win_close, it.win, true)
  end
  if it.buf and vim.api.nvim_buf_is_valid(it.buf) then
    pcall(vim.api.nvim_buf_delete, it.buf, { force = true })
  end
  if next(state.items) == nil then _uninstall_on_key() end
end

--- 关闭全部窗口
function M.close_all()
  for id in pairs(state.items) do M.close(id) end
end

--- 已打开窗口数
--- @return number
function M.count()
  local n = 0
  for _ in pairs(state.items) do n = n + 1 end
  return n
end

--- 某会话窗口是否打开
--- @param id string
--- @return boolean
function M.is_open(id)
  local it = state.items[id]
  return it ~= nil and it.win ~= nil and vim.api.nvim_win_is_valid(it.win)
end

--- 重置（测试用/卸载）
function M.reset()
  M.close_all()
  _uninstall_on_key()
  state.items = {}
end

return M
