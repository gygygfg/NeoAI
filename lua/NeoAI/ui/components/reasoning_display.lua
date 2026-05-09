---@module "NeoAI.ui.components.reasoning_display"
--- 思考过程悬浮窗组件
--- 所有窗口创建/销毁均通过 window_manager 管理

local M = {}

local logger = require("NeoAI.utils.logger")
local window_manager = require("NeoAI.ui.window.window_manager")

local state = {
  initialized = false,
  config = nil,
  window_id = nil, -- window_manager 管理的窗口 ID
  content_buffer = "",
  is_visible = false,
  position = { x = 0, y = 0 },
}

local function buf_valid(buf) return buf and vim.api.nvim_buf_is_valid(buf) end
local function win_valid(win) return win and vim.api.nvim_win_is_valid(win) end

--- 初始化
function M.initialize(config)
  if state.initialized then return end
  state.config = config or {}
  state.initialized = true

  local group = vim.api.nvim_create_augroup("NeoAIReasoningDisplay", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "show_reasoning_display",
    callback = function(args) M.show(args.data and args.data[1] or "") end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "reasoning_content",
    callback = function(args) M.append(args.data and args.data[1] or "") end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "reasoning_chunk",
    callback = function(args) M.append(args.data and args.data[1] or "") end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "close_reasoning_display",
    callback = function(args)
      local reasoning_text = args.data and args.data[1] or ""
      M._convert_to_folded_text(reasoning_text)
      M.close()
    end,
  })

  -- 监听 window_manager 的隐藏/显示事件，同步更新 is_visible 状态
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "NeoAI:float_windows_hidden",
    callback = function()
      if state.window_id then
        state.is_visible = false
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "NeoAI:float_windows_shown",
    callback = function()
      if state.window_id then
        state.is_visible = true
      end
    end,
  })
end

--- 显示思考过程悬浮窗
--- @param content string 初始内容
function M.show(content)
  if not state.initialized then return end
  if state.window_id then M.close() end

  state.content_buffer = tostring(content or "")
  state.is_visible = true

  -- 通过 window_manager 创建 reasoning 类型窗口
  state.window_id = window_manager.create_window("reasoning", {
    title = "NeoAI 思考过程",
    width = state.config.width or 60,
    height = state.config.height or 5,
    border = state.config.border or "rounded",
    style = "minimal",
    relative = "editor",
    row = state.position.y or 1,
    col = state.position.x or 1,
    zindex = 100,
    window_mode = "float",
  })

  if not state.window_id then
    state.is_visible = false
    return
  end

  -- 设置 buffer 内容
  local buf = window_manager.get_window_buf(state.window_id)
  if buf and buf_valid(buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
    local win = window_manager.get_window_win(state.window_id)
    if win and win_valid(win) then
      vim.api.nvim_set_option_value("wrap", true, { win = win })
      vim.api.nvim_set_option_value("cursorline", true, { win = win })
    end
  end

  M._update_window_content()
  M._setup_keymaps()
  return state.window_id
end

--- 追加思考内容
function M.append(content)
  if not state.initialized then return end
  local content_str = tostring(content or "")
  if content_str == "" then return end

  if not state.is_visible or not state.window_id then
    M.show(content_str)
    return
  end

  -- 注意：content_str 是增量 chunk，调用方（REASONING_CONTENT 事件）保证不会重复发送
  -- 因此不需要防重复检查，直接追加即可

  state.content_buffer = state.content_buffer .. content_str

  local buf = window_manager.get_window_buf(state.window_id)
  if not buf or not buf_valid(buf) then return end

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  local lc = vim.api.nvim_buf_line_count(buf)
  local has_nl = content_str:find("\n")

  if has_nl then
    local lines = vim.split(content_str, "\n", { plain = true })
    local last = (lc > 0) and (vim.api.nvim_buf_get_lines(buf, lc - 1, lc, false)[1] or "") or ""
    local new_lines = { last .. (lines[1] or "") }
    for i = 2, #lines do table.insert(new_lines, lines[i] or "") end
    pcall(vim.api.nvim_buf_set_lines, buf, math.max(0, lc - 1), lc, false, new_lines)
  elseif lc > 0 then
    local last = vim.api.nvim_buf_get_lines(buf, lc - 1, lc, false)[1] or ""
    pcall(vim.api.nvim_buf_set_lines, buf, lc - 1, lc, false, { last .. content_str })
  else
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, { content_str })
  end

  vim.api.nvim_set_option_value("modified", false, { buf = buf })
  local win = window_manager.get_window_win(state.window_id)
  if win and win_valid(win) then
    local new_lc = vim.api.nvim_buf_line_count(buf)
    if new_lc > 0 then pcall(vim.api.nvim_win_set_cursor, win, { new_lc, 0 }) end
  end
end

--- 关闭
function M.close()
  if not state.initialized then return end
  if state.window_id then
    window_manager.close_window(state.window_id)
    state.window_id = nil
  end
  state.content_buffer = ""
  state.is_visible = false
end

function M.is_visible() return state.is_visible end
function M.get_window_id() return state.window_id end

--- 隐藏（通过 window_manager 的 hide_float_window）
function M.hide()
  if not state.initialized or not state.window_id then return end
  local buf = window_manager.get_window_buf(state.window_id)
  if buf then window_manager.hide_float_window(buf) end
  state.is_visible = false
end

--- 更新内容
function M.update(content)
  if not state.initialized then return end
  local content_str = tostring(content or "")
  if not state.is_visible or not state.window_id then
    M.show(content_str)
    return
  end
  local old = state.content_buffer or ""
  if content_str:sub(1, #old) == old then
    local diff = content_str:sub(#old + 1)
    if diff ~= "" then state.content_buffer = content_str; M.append(diff) end
  else
    state.content_buffer = content_str
    M._update_window_content()
  end
end

--- 转换为折叠文本
function M._convert_to_folded_text(reasoning_text)
  local reasoning_str = tostring(reasoning_text or "")
  if reasoning_str == "" then return "" end
  local lines = { "{{{ 🤔 思考过程" }
  for _, line in ipairs(vim.split(reasoning_str, "\n")) do
    table.insert(lines, "  " .. line)
  end
  table.insert(lines, "}}}")
  return table.concat(lines, "\n")
end

function M._update_window_content()
  if not state.window_id then return end
  local buf = window_manager.get_window_buf(state.window_id)
  if not buf or not buf_valid(buf) then return end

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = buf })
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, {})
  local lines = vim.split(state.content_buffer or "", "\n")
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("modified", false, { buf = buf })

  local win = window_manager.get_window_win(state.window_id)
  if win and win_valid(win) then
    local lc = vim.api.nvim_buf_line_count(buf)
    if lc > 0 then pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 }) end
  end
end

function M._setup_keymaps()
  if not state.window_id then return end
  local buf = window_manager.get_window_buf(state.window_id)
  if not buf or not buf_valid(buf) then return end

  pcall(vim.api.nvim_buf_clear_name_keymap, buf, "n")
  local function force_close()
    if state.window_id then
      window_manager.close_window(state.window_id)
      state.window_id = nil
      state.content_buffer = ""
      state.is_visible = false
    end
  end
  vim.keymap.set("n", "q", force_close, { buffer = buf, silent = true, noremap = true, desc = "关闭窗口" })
  vim.keymap.set("n", "<Esc>", force_close, { buffer = buf, silent = true, noremap = true, desc = "关闭窗口" })
  vim.keymap.set("n", "<C-c>", force_close, { buffer = buf, silent = true, noremap = true, desc = "关闭窗口" })
  vim.keymap.set("n", "yy", function()
    if state.content_buffer ~= "" then
      vim.fn.setreg("+", state.content_buffer)
      vim.fn.setreg("*", state.content_buffer)
      vim.notify("内容已复制到剪贴板", vim.log.levels.INFO)
    end
  end, { buffer = buf, silent = true, noremap = true, desc = "复制内容" })

  -- 同步 chat 快捷键
  local ok, chat_window = pcall(require, "NeoAI.ui.window.chat_window")
  if ok and chat_window.sync_keymaps_to_buf then
    chat_window.sync_keymaps_to_buf(buf, { "quit" })
  end
end

function M.resize(width, height)
  if not state.initialized or not state.window_id then return end
  window_manager.update_window_options(state.window_id, { width = width, height = height })
end

function M.set_position(x, y)
  if not state.initialized or not state.window_id then return end
  state.position.x = x or state.position.x
  state.position.y = y or state.position.y
  window_manager.update_window_options(state.window_id, { col = state.position.x, row = state.position.y })
end

--- 移动窗口
--- @param direction string 方向 ('up', 'down', 'left', 'right')
--- @param amount number 移动量
function M.move(direction, amount)
  if not state.initialized or not state.window_id then return end
  amount = amount or 5
  local new_position = vim.deepcopy(state.position)
  if direction == "up" then
    new_position.y = math.max(1, new_position.y - amount)
  elseif direction == "down" then
    new_position.y = new_position.y + amount
  elseif direction == "left" then
    new_position.x = math.max(1, new_position.x - amount)
  elseif direction == "right" then
    new_position.x = new_position.x + amount
  end
  M.set_position(new_position.x, new_position.y)
end

--- 切换可见性
function M.toggle()
  if not state.initialized then return end
  if state.is_visible then
    M.close()
  else
    M.show(state.content_buffer)
  end
end

--- 复制内容到剪贴板
function M._copy_to_clipboard()
  if state.content_buffer == "" then
    vim.notify("没有内容可复制", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("+", state.content_buffer)
  vim.fn.setreg("*", state.content_buffer)
  vim.notify("内容已复制到剪贴板", vim.log.levels.INFO)
end

--- 保存内容到文件
function M._save_to_file()
  if state.content_buffer == "" then
    vim.notify("没有内容可保存", vim.log.levels.WARN)
    return
  end
  local filename = vim.fn.input("保存文件为: ", "reasoning_" .. os.date("%Y%m%d_%H%M%S") .. ".md")
  if filename == "" then return end
  local file = io.open(filename, "w")
  if file then
    file:write(state.content_buffer)
    file:close()
    vim.notify("内容已保存到: " .. filename, vim.log.levels.INFO)
  else
    vim.notify("无法保存文件: " .. filename, vim.log.levels.ERROR)
  end
end

--- 复制内容（内部使用）
function M._copy_content()
  if not state.initialized then return end
  local content_str = tostring(state.content_buffer or "")
  if content_str == "" then return end
  vim.fn.setreg("+", content_str)
  vim.notify("思考内容已复制到剪贴板", vim.log.levels.INFO)
end

function M.update_config(new_config)
  if not state.initialized then return end
  state.config = vim.tbl_extend("force", state.config, new_config or {})
  if state.window_id then
    M._setup_keymaps()
    M._update_window_content()
  end
end

return M
