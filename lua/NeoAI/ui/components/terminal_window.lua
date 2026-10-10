--- 交互式终端悬浮窗
--- @module NeoAI.ui.components.terminal_window
--- 用 `nvim_open_term` 在浮动窗口里渲染交互式命令的终端画面（真实 VT 模拟），
--- 并支持手动键入转发给会话。多会话按 id 独立窗口。
---
--- 折叠/展开：窗口以**折叠态**（屏幕右上角小窗）打开，避免一开场大面积遮挡；当焦点进入
--- 某终端窗（WinEnter）时展开为全尺寸，焦点移出时自动折叠。`expand`/`collapse`/`is_collapsed`
--- 暴露给调用方；`geometry.track` 的 apply 按当前折叠态在 resize 时重算几何。
--- headless（无 UI）下所有接口为安全 no-op。

local geometry = require("NeoAI.ui.geometry")

local M = {}

-- ========== 私有状态 ==========

local state = {
  -- id -> { id, buf, win, chan, title, geom_opts, collapsed }
  items = {},
  on_key = false,   -- vim.on_key 是否已安装
  ns = nil,         -- on_key 命名空间 id
  win_group = nil,  -- WinEnter 展/缩自动命令组 id
  force_ui = false, -- 测试钩子：headless 下强制视作「有 UI」
}

-- 折叠态：右上角小窗，仅露出标题/尾部输出；获得焦点时展开为全尺寸。
local COLLAPSED_W = 30
local COLLAPSED_H = 3
local COLLAPSED_MARGIN = 2

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
--- 注意：Neovim 0.12 起 `vim.on_key` 回调**只允许返回空字符串 `""`（消费按键）或不返回**；
--- 返回非空字符串会报 `With ns_id ...: return string must be empty`。故「保留原按键」一律
--- 用 `return`（nil），不要 `return key`。
local function _on_key(key)
  local id = _current_id()
  if not id then return end
  -- 仅在终端/插入模式转发按键，Normal 模式下保留原按键（可 : 命令、i 进入输入、<C-q> 关窗）
  local mode = vim.api.nvim_get_mode().mode
  if mode ~= "t" and mode ~= "i" then return end
  -- 保留退出终端模式的按键，避免把用户困在终端里
  if key == "<Esc>" or key == "<C-\\>" or key == "<C-n>" then return end
  local pty = require("NeoAI.kernel.services").use("services.pty")
  if not pty then return end
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
  return
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
  if state.force_ui then return true end
  local ok, uis = pcall(vim.api.nvim_list_uis)
  return ok and type(uis) == "table" and #uis > 0
end

--- 折叠态几何：贴屏幕右上角的小窗（宽 min(30, cols-4)，高 3，行 2，列 cols-width-2）。
--- 纯函数，便于单测；对极窄/极矮屏做边界兜底。
--- @return table { width, height, col, row }
function M._collapsed_geom()
  local cols = math.max(1, vim.o.columns or 1)
  local lines = math.max(1, vim.o.lines or 1)
  local width = math.max(8, math.min(COLLAPSED_W, cols - 4))
  local height = math.min(COLLAPSED_H, lines)
  local col = math.max(0, cols - width - COLLAPSED_MARGIN)
  local row = math.max(0, math.min(COLLAPSED_MARGIN, lines - height))
  return { width = width, height = height, col = col, row = row }
end

--- 按当前折叠状态把几何写回窗口
--- @param it table
local function _apply_geom(it)
  if not it or not it.win or not vim.api.nvim_win_is_valid(it.win) then return end
  local g
  if it.collapsed then
    g = M._collapsed_geom()
  else
    g = geometry.compute(it.geom_opts or { w_ratio = 0.80, h_ratio = 0.70, min_h = 5 })
  end
  pcall(vim.api.nvim_win_set_config, it.win, {
    relative = "editor",
    width = g.width,
    height = g.height,
    col = g.col,
    row = g.row,
  })
end

--- 安装 WinEnter 自动命令（幂等）：焦点进入某终端窗 → 展开；其余终端窗 → 折叠。
--- 只在「焦点归属」维度做展/缩，不影响各会话窗口自身的存在性。
local function _install_win_autocmds()
  if state.win_group then return end
  state.win_group = vim.api.nvim_create_augroup("NeoAITerminalWin", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = state.win_group,
    callback = function()
      local cur = vim.api.nvim_get_current_win()
      for id, it in pairs(state.items) do
        if it.win == cur then
          M.expand(id)
        else
          M.collapse(id)
        end
      end
    end,
  })
end

local function _uninstall_win_autocmds()
  if state.win_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.win_group)
    state.win_group = nil
  end
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
    local geom_opts = { w_ratio = 0.80, h_ratio = 0.70, min_h = 5 }
    -- 启动即折叠：缩到屏幕右上角小窗，避免一开场就大面积遮挡；获得焦点时由 WinEnter 展开。
    local geom = M._collapsed_geom()
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = geom.width,
      height = geom.height,
      col = geom.col,
      row = geom.row,
      style = "minimal",
      border = "rounded",
      title = title or ("命令终端 · " .. id),
      title_pos = "center",
    })
    local item = {
      id = id, buf = buf, win = win,
      title = title, geom_opts = geom_opts, collapsed = true,
    }
    -- resize 跟随：按当前折叠状态重算几何（展开态用 geom_opts，折叠态贴右上角）。
    geometry.track(win, geom_opts, function(w)
      local cur = state.items[id]
      if cur and cur.win == w then _apply_geom(cur) end
    end)
    local chan = vim.api.nvim_open_term(buf, {})
    vim.w[win].neoai_pty_id = id
    -- Normal 模式 <C-q> 关闭悬浮窗（不结束命令）
    vim.keymap.set("n", "<C-q>", function() M.close(id) end,
      { buffer = buf, silent = true, desc = "关闭 NeoAI 终端窗口" })
    item.chan = chan
    return item
  end)
  if not ok or not res then return nil end
  state.items[id] = res
  _install_on_key()
  _install_win_autocmds()
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
  it.title = title
  pcall(vim.api.nvim_win_set_config, it.win, { title = title, title_pos = "center" })
end

--- 展开某会话窗口为全尺寸（获得焦点时调用）
--- @param id string
function M.expand(id)
  local it = state.items[id]
  if not it or not vim.api.nvim_win_is_valid(it.win) then return end
  it.collapsed = false
  _apply_geom(it)
end

--- 折叠某会话窗口为右上角小窗（失去焦点时调用）
--- @param id string
function M.collapse(id)
  local it = state.items[id]
  if not it or not vim.api.nvim_win_is_valid(it.win) then return end
  it.collapsed = true
  _apply_geom(it)
end

--- 某会话窗口是否处于折叠态
--- @param id string
--- @return boolean
function M.is_collapsed(id)
  local it = state.items[id]
  return it ~= nil and it.collapsed == true
end

--- 覆盖「有 UI」判定（测试用）；传 nil 恢复默认
--- @param v boolean|nil
function M._set_force_ui(v)
  state.force_ui = v == true
end

--- 关闭某会话窗口
--- @param id string
function M.close(id)
  local it = state.items[id]
  if not it then return end
  state.items[id] = nil
  geometry.untrack(it.win)
  if it.win and vim.api.nvim_win_is_valid(it.win) then
    pcall(vim.api.nvim_win_close, it.win, true)
  end
  if it.buf and vim.api.nvim_buf_is_valid(it.buf) then
    pcall(vim.api.nvim_buf_delete, it.buf, { force = true })
  end
  if next(state.items) == nil then
    _uninstall_on_key()
    _uninstall_win_autocmds()
  end
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
  _uninstall_win_autocmds()
  state.items = {}
  state.force_ui = false
end

return M
