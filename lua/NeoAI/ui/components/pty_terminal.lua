---@module "NeoAI.ui.components.pty_terminal"
--- PTY 终端浮动窗口组件（纯 UI 层）
--- 负责 PTY 浮动窗口的创建、关闭、重新定位
--- 提供同步接口，供后端将隐藏 termopen buffer 内容同步到前台浮动窗口
---
--- 后端逻辑（隐藏 buffer 创建、termopen 调用、进程管理）在 tools/builtin/shell_tools.lua

local M = {}

local window_manager = require("NeoAI.ui.window.window_manager")

-- ============================================================================
-- 内部状态
-- ============================================================================
local state = {
  initialized = false,
  config = nil,
  window_id = nil, -- window_manager 管理的窗口 ID（前台浮动窗口）
  session_id = nil,
}

local function buf_valid(buf) return buf and vim.api.nvim_buf_is_valid(buf) end
local function win_valid(win) return win and vim.api.nvim_win_is_valid(win) end

-- ============================================================================
-- 布局计算
-- ============================================================================

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

-- ============================================================================
-- ANSI 转义码清理
-- ============================================================================

--- 剥离 ANSI 转义码
--- @param text string 原始文本
--- @return string 清理后的纯文本
function M.strip_ansi(text)
  if not text then return "" end
  local cleaned = text
  cleaned = cleaned:gsub("\027%[[a-zA-Z]", "")
  cleaned = cleaned:gsub("\027%[%?[a-zA-Z]", "")
  cleaned = cleaned:gsub("\027%[%d+[a-zA-Z]", "")
  cleaned = cleaned:gsub("\027%[%?%d+[a-zA-Z]", "")
  for num_semicolons = 50, 1, -1 do
    local parts = {}
    for _ = 1, num_semicolons + 1 do
      table.insert(parts, "%d+")
    end
    cleaned = cleaned:gsub("\027%[" .. table.concat(parts, ";") .. "[a-zA-Z]", "")
  end
  for num_semicolons = 50, 1, -1 do
    local parts = {}
    for _ = 1, num_semicolons + 1 do
      table.insert(parts, "%d+")
    end
    cleaned = cleaned:gsub("\027%[%?" .. table.concat(parts, ";") .. "[a-zA-Z]", "")
  end
  cleaned = cleaned:gsub("\027%][^\007\027]*[\007\027\\]", "")
  return cleaned
end

-- ============================================================================
-- 前台/后台同步接口
-- ============================================================================

--- 将内容同步到前台浮动窗口
--- 供后端在隐藏 buffer 内容变化时调用
--- @param lines table 要同步的行列表
function M.sync_content(lines)
  if not state.window_id then return end
  local front_buf = window_manager.get_window_buf(state.window_id)
  if not front_buf or not buf_valid(front_buf) then return end
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = front_buf })
  pcall(vim.api.nvim_buf_set_lines, front_buf, 0, -1, false, lines)
  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = front_buf })
end

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化组件
--- @param config table|nil 配置
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

-- ============================================================================
-- 窗口管理
-- ============================================================================

--- 打开 PTY 终端窗口（前台浮动窗口）
--- @param session_id string 会话 ID
--- @return table|nil { win = number, buf = number, window_id = string }
function M.open(session_id)
  if not state.initialized then return nil end
  M.close()

  local layout = calculate_layout()

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

  return { win = win, buf = buf, window_id = state.window_id }
end

--- 关闭 PTY 终端窗口
function M.close()
  if state.window_id then
    window_manager.close_window(state.window_id)
    state.window_id = nil
  end
  state.session_id = nil
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

--- 获取当前布局信息
--- @return table|nil { width, height, row, col }
function M.get_layout()
  if not state.window_id then return nil end
  local win = window_manager.get_window_win(state.window_id)
  if not win or not win_valid(win) then return nil end
  return vim.api.nvim_win_get_config(win)
end

-- ============================================================================
-- 查询接口
-- ============================================================================

function M.is_open() return state.window_id ~= nil end
function M.get_window_id() return state.window_id end
function M.get_session_id() return state.session_id end
function M.get_win() return state.window_id and window_manager.get_window_win(state.window_id) or nil end
function M.get_buf() return state.window_id and window_manager.get_window_buf(state.window_id) or nil end

-- ============================================================================
-- 配置
-- ============================================================================

--- 更新配置
function M.update_config(new_config)
  if not state.initialized then return end
  state.config = vim.tbl_extend("force", state.config, new_config or {})
end

return M
