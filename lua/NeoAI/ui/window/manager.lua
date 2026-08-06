--- 窗口管理器
--- @module NeoAI.ui.window.manager
--- 管理 float/tab/split 三种模式的窗口创建/关闭/聚焦。

local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  windows = {}, -- win_id -> { type, buf, win, mode }
}

-- 各视图 buffer 的固定名称，便于 :ls 检索、:b 切换
local BUFFER_NAMES = {
  chat = "NeoAI Chat",
  tree = "NeoAI Sessions",
}

-- ========== 私有函数 ==========

--- 获取窗口配置
--- @return table
local function _window_config()
  return config_store.get("ui.window") or { width = 80, height = 24, border = "rounded" }
end

--- 统一配置 NeoAI 窗口（避免继承全局 number/signcolumn 等导致渲染杂乱）
--- @param win number
local function _configure_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].list = false
  vim.wo[win].colorcolumn = ""
  vim.wo[win].spell = false
end

--- 创建浮动窗口
--- @param opts table { buf?, width?, height?, border?, title? }
--- @return number win_id, number buf_id
local function _open_float(opts)
  local cfg = _window_config()
  local width = opts.width or cfg.width or 80
  local height = opts.height or cfg.height or 24
  local border = opts.border or cfg.border or "rounded"
  local buf = opts.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = opts.filetype or "neoai"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(width, vim.o.columns - 4),
    height = math.min(height, vim.o.lines - 4),
    col = math.floor((vim.o.columns - math.min(width, vim.o.columns - 4)) / 2),
    row = math.floor((vim.o.lines - math.min(height, vim.o.lines - 4)) / 2),
    style = "minimal",
    border = border,
    title = opts.title,
    title_pos = "center",
  })
  _configure_window(win)
  return win, buf
end

--- 创建 tab 窗口
--- @param opts table { buf?, title? }
--- @return number win_id, number buf_id
local function _open_tab(opts)
  local buf = opts.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = opts.filetype or "neoai"
  vim.cmd("tabnew")
  -- :tabnew 会额外创建空的 [No Name] buffer，切换后立即清理，避免污染 buffer 列表
  local temp_buf = vim.api.nvim_get_current_buf()
  if temp_buf ~= buf then
    vim.api.nvim_set_current_buf(buf)
    pcall(vim.api.nvim_buf_delete, temp_buf, { force = true })
  end
  local win = vim.api.nvim_get_current_win()
  _configure_window(win)
  return win, buf
end

--- 创建 split 窗口
--- @param opts table { buf?, direction?, size? }
--- @return number win_id, number buf_id
local function _open_split(opts)
  local split_cfg = config_store.get("ui.split") or {}
  local direction = opts.direction or split_cfg.direction or "right"
  local size = opts.size or split_cfg.size or 80
  local buf = opts.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = opts.filetype or "neoai"
  local cmd = (direction == "left" and "topleft vsplit" or "botright vsplit")
  if direction == "top" then cmd = "topleft split" end
  if direction == "bottom" then cmd = "botright split" end
  vim.cmd(cmd)
  vim.api.nvim_win_set_width(vim.api.nvim_get_current_win(), size)
  vim.api.nvim_set_current_buf(buf)
  local win = vim.api.nvim_get_current_win()
  _configure_window(win)
  return win, buf
end

-- ========== 公开 API ==========

--- 创建窗口
--- @param window_type string "chat" | "tree"
--- @param opts table|nil { mode?, buf?, title? }
--- @return table { win_id, buf, mode }
function M.create(window_type, opts)
  opts = opts or {}
  local mode = opts.mode or config_store.get("ui.window_mode") or "tab"
  local win_id, buf
  if mode == "float" then
    win_id, buf = _open_float(opts)
  elseif mode == "split" then
    win_id, buf = _open_split(opts)
  else
    win_id, buf = _open_tab(opts)
  end
  -- 命名并列入 buffer 列表，使 :ls 可见、:b 可切换
  local buf_name = opts.title or BUFFER_NAMES[window_type]
  if buf_name then
    pcall(vim.api.nvim_buf_set_name, buf, buf_name)
    vim.bo[buf].buflisted = true
  end
  state.windows[win_id] = { type = window_type, buf = buf, win = win_id, mode = mode }
  event_bus.emit(events.WINDOW_OPENED, { win_id = win_id, type = window_type, mode = mode })
  return { win_id = win_id, buf = buf, mode = mode }
end

--- 关闭窗口
--- @param win_id number
function M.close(win_id)
  local info = state.windows[win_id]
  if not info then
    -- 可能是外部创建的窗口
    if vim.api.nvim_win_is_valid(win_id) then
      pcall(vim.api.nvim_win_close, win_id, true)
    end
    return
  end
  event_bus.emit(events.WINDOW_CLOSED, { win_id = win_id, type = info.type })
  pcall(vim.api.nvim_win_close, win_id, true)
  state.windows[win_id] = nil
end

--- 关闭所有窗口
function M.close_all()
  for win_id, info in pairs(state.windows) do
    event_bus.emit(events.WINDOW_CLOSED, { win_id = win_id, type = info.type })
    if vim.api.nvim_win_is_valid(win_id) then
      pcall(vim.api.nvim_win_close, win_id, true)
    end
  end
  state.windows = {}
end

--- 聚焦窗口
--- @param win_id number
function M.focus(win_id)
  if vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_set_current_win(win_id)
  end
end

--- 获取窗口的 nvim win 句柄
--- @param win_id number
--- @return number
function M.get_win(win_id)
  return win_id
end

--- 获取窗口信息
--- @param win_id number
--- @return table|nil
function M.get_info(win_id)
  return state.windows[win_id]
end

--- 列出所有窗口
--- @return table 数组
function M.list()
  local out = {}
  for win_id, info in pairs(state.windows) do
    if vim.api.nvim_win_is_valid(win_id) then
      out[#out + 1] = { win_id = win_id, type = info.type, buf = info.buf, mode = info.mode }
    else
      state.windows[win_id] = nil
    end
  end
  return out
end

--- 是否有窗口
--- @return boolean
function M.has_windows()
  return next(state.windows) ~= nil
end

--- 重置（测试用）
function M.reset()
  M.close_all()
end

return M
