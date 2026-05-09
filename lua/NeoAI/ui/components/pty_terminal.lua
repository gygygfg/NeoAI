---@module "NeoAI.ui.components.pty_terminal"
--- PTY 终端浮动窗口组件
--- 所有窗口创建/销毁均通过 window_manager 管理
--- 自动跟随工具调用悬浮窗布局变化

local M = {}

local window_manager = require("NeoAI.ui.window.window_manager")

local state = {
  initialized = false,
  config = nil,
  window_id = nil, -- window_manager 管理的窗口 ID
  session_id = nil,
  pty_buf = nil,
}

local function buf_valid(buf) return buf and vim.api.nvim_buf_is_valid(buf) end
local function win_valid(win) return win and vim.api.nvim_win_is_valid(win) end

--- 获取屏幕尺寸
local function get_screen_dimensions()
  return vim.o.columns, vim.o.lines
end

--- 检测工具调用窗口布局
local function get_tool_display_layout()
  local ok, chat_window = pcall(require, "NeoAI.ui.window.chat_window")
  if not ok then return nil end
  local window_id = chat_window.get_tool_display_window_id()
  if not window_id then return nil end
  local win = window_manager.get_window_win(window_id)
  if not win or not win_valid(win) then return nil end
  local config = vim.api.nvim_win_get_config(win)
  if not config or not config.width or not config.height then return nil end
  return { width = config.width, height = config.height, row = config.row or 1, col = config.col or 1 }
end

--- 计算 PTY 窗口布局（在工具调用窗口右侧）
local function calculate_layout()
  local tool_layout = get_tool_display_layout()
  local total_cols, total_lines = get_screen_dimensions()
  local right_col, right_width, win_height, win_row

  if tool_layout then
    local gap = 1
    right_col = tool_layout.col + tool_layout.width + gap
    right_width = total_cols - right_col - 1
    if right_width < 20 then right_width = 20; right_col = total_cols - right_width - 1 end
    win_height = tool_layout.height
    if tool_layout.row + win_height > total_lines - 2 then win_height = total_lines - 2 - tool_layout.row end
    if win_height < 5 then win_height = 5 end
    win_row = tool_layout.row
  else
    local left_width = math.floor(total_cols / 2) - 1
    right_col = left_width + 2
    right_width = total_cols - right_col - 1
    if right_width < 20 then right_width = 20; right_col = total_cols - right_width - 1 end
    win_height = total_lines - 2
    win_row = 1
  end
  return { width = right_width, height = win_height, row = win_row, col = right_col }
end

--- 初始化
function M.initialize(config)
  if state.initialized then return end
  state.config = config or {}
  state.initialized = true

  -- 监听工具调用窗口大小变化
  local group = vim.api.nvim_create_augroup("NeoAIPtySyncToolDisplay", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "NeoAI:tool_display_resized",
    callback = function(event)
      if not state.window_id then return end
      M.reposition()
    end,
    desc = "工具调用窗口大小变化时同步调整 PTY 终端窗口",
  })
end

--- 打开 PTY 终端窗口
--- @param session_id string 会话 ID
--- @param pty_buf number|nil 已有的 PTY buffer
--- @return number|nil 窗口句柄
function M.open(session_id, pty_buf)
  if not state.initialized then return nil end
  M.close()

  local layout = calculate_layout()
  local total_cols, _ = get_screen_dimensions()

  local tool_border = {
    { "╭", "FloatBorder" }, { "─", "FloatBorder" }, { "╮", "FloatBorder" },
    { "│", "FloatBorder" }, { "╯", "FloatBorder" }, { "─", "FloatBorder" },
    { "╰", "FloatBorder" }, { "│", "FloatBorder" },
  }

  state.window_id = window_manager.create_window("pty_terminal", {
    title = "💻 终端",
    width = layout.width, height = layout.height,
    border = tool_border, style = "minimal", relative = "editor",
    row = layout.row, col = layout.col, zindex = 150, window_mode = "float",
    _pty_buf = pty_buf,
  })

  if not state.window_id then return nil end

  state.session_id = session_id

  local buf = window_manager.get_window_buf(state.window_id)
  local win = window_manager.get_window_win(state.window_id)

  if buf and buf_valid(buf) then
    vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder", { win = win })
    -- 设置按键映射
    vim.keymap.set("n", "q", function() M.close() end,
      { buffer = buf, noremap = true, silent = true, desc = "关闭终端窗口" })
    vim.keymap.set("n", "<Esc>", function()
      if vim.api.nvim_get_mode().mode == "n" then M.close() end
    end, { buffer = buf, noremap = true, silent = true, desc = "关闭终端窗口" })
  end

  return win
end

--- 关闭 PTY 终端窗口
function M.close()
  if state.window_id then
    window_manager.close_window(state.window_id)
    state.window_id = nil
  end
  state.session_id = nil
  state.pty_buf = nil
end

--- 重新定位（窗口大小变化时调用）
function M.reposition()
  if not state.window_id then return end
  local layout = calculate_layout()
  local win = window_manager.get_window_win(state.window_id)
  if not win or not win_valid(win) then return end
  pcall(vim.api.nvim_win_set_config, win, {
    relative = "editor",
    width = layout.width, height = layout.height,
    row = layout.row, col = layout.col,
  })
end

function M.is_open() return state.window_id ~= nil end
function M.get_window_id() return state.window_id end
function M.get_session_id() return state.session_id end

--- 更新配置
function M.update_config(new_config)
  if not state.initialized then return end
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
