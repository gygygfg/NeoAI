---@module "NeoAI.ui.components.floating_text"
--- 悬浮文本提示组件
--- 从 chat_window.lua 分离，负责创建/销毁临时悬浮文本提示窗口
--- 所有窗口创建/销毁均通过 window_manager 管理

local M = {}

local logger = require("NeoAI.utils.logger")
local window_manager = require("NeoAI.ui.window.window_manager")
local Events = require("NeoAI.core.events")

local state = {
  initialized = false,
  config = nil,
  window_id = nil, -- 当前活跃的悬浮文本窗口 ID
  timer = nil,     -- 自动关闭定时器
}

local function buf_valid(buf) return buf and vim.api.nvim_buf_is_valid(buf) end
local function win_valid(win) return win and vim.api.nvim_win_is_valid(win) end

--- 初始化
--- @param config table|nil 配置
function M.initialize(config)
  if state.initialized then return end
  state.config = config or {}
  state.initialized = true
end

--- 计算浮动窗口的位置
--- @param chat_win number 聊天窗口句柄
--- @param width number 浮动窗口宽度
--- @param height number 浮动窗口高度
--- @param position string "center" | "bottom" | "top"
--- @return table { row, col, width, height, relative, anchor }
local function calc_position(chat_win, width, height, position)
  local chat_config = vim.api.nvim_win_get_config(chat_win)
  local chat_row = chat_config.row or 1
  local chat_col = chat_config.col or 1
  local chat_width = chat_config.width or 80
  local chat_height = chat_config.height or 20

  local row, col
  if position == "center" then
    row = chat_row + math.floor((chat_height - height) / 2)
    col = chat_col + math.floor((chat_width - width) / 2)
  elseif position == "bottom" then
    row = chat_row + chat_height - height - 1
    col = chat_col + math.floor((chat_width - width) / 2)
  else -- top
    row = chat_row + 1
    col = chat_col + math.floor((chat_width - width) / 2)
  end

  return {
    relative = "editor",
    row = math.max(1, row),
    col = math.max(1, col),
    width = width,
    height = height,
  }
end

--- 显示悬浮文本
--- @param text string 要显示的文本
--- @param opts table|nil 选项:
---   timeout: number 自动关闭毫秒数（默认 3000）
---   position: string "center"|"bottom"|"top"（默认 "center"）
---   border: string 边框样式（默认 "single"）
---   chat_win: number 关联的聊天窗口句柄（必填）
---   chat_window_id: string 关联的聊天窗口 ID（必填，用于触发事件）
function M.show(text, opts)
  if not state.initialized then return false end

  -- 先关闭已有悬浮文本
  M.close()

  opts = opts or {}
  local chat_win = opts.chat_win
  local chat_window_id = opts.chat_window_id

  if not chat_win or not win_valid(chat_win) then
    return false
  end

  -- 触发显示悬浮文本事件
  if chat_window_id then
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.FLOATING_TEXT_SHOWING,
      data = { window_id = chat_window_id, text = text },
    })
  end

  -- 计算尺寸
  local lines = vim.split(text, "\n")
  local max_line_len = 0
  for _, line in ipairs(lines) do
    if #line > max_line_len then max_line_len = #line end
  end
  local width = math.min(math.max(max_line_len + 4, 20), 80)
  local height = math.min(#lines + 2, 10)

  -- 计算位置
  local pos = calc_position(chat_win, width, height, opts.position or "center")

  -- 通过 window_manager 创建临时悬浮窗
  state.window_id = window_manager.create_window("floating_text", {
    title = "",
    width = pos.width,
    height = pos.height,
    border = opts.border or "single",
    style = "minimal",
    relative = pos.relative,
    row = pos.row,
    col = pos.col,
    zindex = 200,
    window_mode = "float",
  })

  if not state.window_id then
    return false
  end

  -- 设置 buffer 内容
  local buf = window_manager.get_window_buf(state.window_id)
  if buf and buf_valid(buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_set_option_value("filetype", "neoai_floating_text", { buf = buf })
  end

  -- 设置窗口选项
  local win = window_manager.get_window_win(state.window_id)
  if win and win_valid(win) then
    vim.api.nvim_set_option_value("wrap", true, { win = win })
    vim.api.nvim_set_option_value("cursorline", false, { win = win })
  end

  -- 自动关闭定时器
  local timeout = opts.timeout or 3000
  if timeout > 0 then
    state.timer = vim.defer_fn(function()
      M.close()
    end, timeout)
  end

  -- 触发显示完成事件
  if chat_window_id then
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.FLOATING_TEXT_SHOWN,
      data = { window_id = chat_window_id, text = text },
    })
  end

  return true
end

--- 关闭悬浮文本
function M.close()
  if not state.initialized then return true end

  -- 取消定时器
  if state.timer then
    pcall(vim.uv.timer_stop, state.timer)
    state.timer = nil
  end

  -- 触发关闭事件并关闭窗口
  if state.window_id then
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.FLOATING_TEXT_CLOSING,
      data = { window_id = state.window_id },
    })

    window_manager.close_window(state.window_id)
    state.window_id = nil

    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.FLOATING_TEXT_CLOSED,
      data = {},
    })
  end

  return true
end

--- 检查是否有悬浮文本正在显示
function M.is_visible()
  return state.window_id ~= nil
end

return M
