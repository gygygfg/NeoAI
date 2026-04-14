-- NeoAI UI 模块
-- 负责聊天窗口的创建、渲染、窗口管理、快捷键绑定和输入处理
local M = {}
local backend = require("NeoAI.backend")
local config = require("NeoAI.config")

-- ── 模块常量与状态 ───────────────────────────────────────────────────────────

-- UI 模式枚举
M.ui_modes = { FLOAT = "float", SPLIT = "split", TAB = "tab" }
M.current_mode = M.ui_modes.FLOAT -- 当前 UI 模式
M.windows = {} -- 窗口句柄表
M.buffers = {} -- 缓冲区句柄表
M.tree_windows = {} -- 树视图窗口表
M.tree_buffers = {} -- 树视图缓冲区表
M.is_open = false -- 聊天窗口是否打开
M.config = nil -- 当前配置
M.original_tabline = nil -- 原始标签栏设置
M.original_showtabline = nil -- 原始标签栏显示设置
M.input_start_line = nil -- 输入区域起始行
M.input_end_line = nil -- 输入区域结束行
M._showing_tree = nil -- 运行时的树视图切换状态（nil=由后端决定）
M._debounce_timers = {} -- 防抖计时器表
M._resize_pending = false -- 是否有待处理的调整大小请求
M._reasoning_line_for_msg = {} -- 推理内容行映射 {message_id = line_number}
M._reasoning_fold_state = {} -- 推理内容折叠状态 {message_id = true/false}
M._reasoning_float_wins = {} -- 推理浮动窗口 {message_id = win_id}
M._reasoning_float_buffers = {} -- 推理浮动窗口缓冲区 {message_id = buf_id}
M._last_reasoning_len_for_float = 0 -- 上次推理内容长度（用于检测停止增长）
M._no_reasoning_update_count = 0 -- 连续没有推理内容更新的次数

--- 关闭指定消息的推理浮动窗口
-- @param message_id 消息ID
function M.close_reasoning_float(message_id)
  local win_id = M._reasoning_float_wins[message_id]
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_close(win_id, true)
  end
  M._reasoning_float_wins[message_id] = nil
  M._reasoning_float_buffers[message_id] = nil
end

--- 为推理内容创建浮动窗口
-- @param message_id 消息ID
-- @param reasoning_text 推理内容
-- @param anchor_win 锚点窗口（通常是主窗口）
-- @param anchor_row 锚点行（相对于窗口的行号）
-- @return number 浮动窗口ID
function M.create_reasoning_float_window(message_id, reasoning_text, anchor_win, anchor_row)
  -- 先关闭已存在的浮动窗口
  M.close_reasoning_float(message_id)
  
  -- 创建缓冲区
  local buf = vim.api.nvim_create_buf(false, true)
  M._reasoning_float_buffers[message_id] = buf
  
  -- 设置缓冲区内容（自动换行）
  local lines = {}
  local float_width = math.min(80, vim.o.columns - 5)
  local max_width = float_width - 2
  
  for line in reasoning_text:gmatch("[^\r\n]+") do
    -- Inline sanitize logic: remove newlines and malformed tags
    local cleaned = tostring(line):gsub("[\r\n]+", " "):gsub("<%x%x>", "")
    
    -- Inline wrap_text logic (UTF-8 aware)
    local wrapped = {}
    local current = ""
    for ch in cleaned:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      if #current + #ch <= max_width or current == "" then
        current = current .. ch
      else
        table.insert(wrapped, current)
        current = ch
      end
    end
    if current ~= "" then
      table.insert(wrapped, current)
    end
    if #wrapped == 0 then
      table.insert(wrapped, cleaned)
    end
    
    for _, wl in ipairs(wrapped) do
      table.insert(lines, wl)
    end
  end
  if #lines == 0 then
    table.insert(lines, "暂无思考内容")
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('readonly', true, { buf = buf })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'NeoAIReasoning', { buf = buf })

  -- 计算浮动窗口位置（相对于编辑器）
  local win_config = vim.api.nvim_win_get_config(anchor_win)
  local win_row = win_config.row or 0
  local win_col = win_config.col or 0

  -- 获取光标位置或指定的锚点行
  local cursor = vim.api.nvim_win_get_cursor(anchor_win)
  local target_row = anchor_row or cursor[1]

  -- 浮动窗口配置
  local float_width = math.min(80, vim.o.columns - win_col - 5)
  local float_height = 5
  local float_row = win_row + target_row - vim.fn.line('w0', anchor_win) + 1
  local float_col = win_col + 2

  -- 确保不超出屏幕
  if float_row + float_height > vim.o.lines then
    float_row = vim.o.lines - float_height - 2
  end

  -- 创建浮动窗口
  local win_id = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    row = math.max(0, float_row),
    col = math.max(0, float_col),
    width = float_width,
    height = float_height,
    style = 'minimal',
    border = 'rounded',
    focusable = false,
    zindex = 100,
  })

  -- 设置窗口选项（这些是窗口本地选项）
  vim.api.nvim_set_option_value('wrap', true, { win = win_id })
  vim.api.nvim_set_option_value('linebreak', true, { win = win_id })
  vim.api.nvim_set_option_value('breakindent', false, { win = win_id })
  vim.api.nvim_set_option_value('number', false, { win = win_id })
  vim.api.nvim_set_option_value('relativenumber', false, { win = win_id })
  vim.api.nvim_set_option_value('signcolumn', 'no', { win = win_id })
  vim.api.nvim_set_option_value('foldenable', false, { win = win_id })
  vim.api.nvim_set_option_value('winhl', 'NormalFloat:CommentFloat', { win = win_id })
  
  M._reasoning_float_wins[message_id] = win_id
  
  return win_id
end

--- 切换推理内容的折叠状态
-- @param message_id 消息ID
function M.toggle_reasoning_fold(message_id)
  M._reasoning_fold_state[message_id] = not M._reasoning_fold_state[message_id]
  M.update_display()
end

--- 判断推理内容是否处于折叠状态
-- @param message_id 消息ID
-- @return boolean true=折叠，false=展开
function M.is_reasoning_folded(message_id)
  -- 默认：思考中时展开，思考完成后折叠
  if M._reasoning_fold_state[message_id] == nil then
    return false -- 默认展开
  end
  return M._reasoning_fold_state[message_id]
end

-- 判断是否应显示树视图（优先使用运行时切换状态，否则由后端决定）
-- @return boolean
function M.should_show_tree()
  if M._showing_tree ~= nil then
    return M._showing_tree
  end
  return backend.should_show_tree()
end

-- 各模式窗口大小限制
M.WINDOW_LIMITS = {
  float = { min_width = 50, min_height = 8, max_width_ratio = 0.85, max_height_ratio = 0.85 },
  split = { min_width = 40, max_width_ratio = 0.6, min_height = 8, max_height_ratio = 0.95 },
  tab = { min_width = 60, min_height = 10 },
  tree = { min_width = 40, max_width_ratio = 0.35 },
}

-- 分隔线字符映射表
local SEPARATOR_CHARS = { single = "─", double = "═", solid = "━", dotted = "┈", dashed = "┄" }

-- ── 工具函数集 ───────────────────────────────────────────────────────────────

-- ── 防抖定时器管理 ───────────────────────────────────────────────────────────

--- 生成唯一的防抖定时器名称
-- @param prefix 前缀标识
-- @return string 唯一的定时器名称（带时间戳）
local function make_debounce_key(prefix)
  return string.format("%s_%d_%d", prefix, vim.loop.now(), math.random(100000, 999999))
end

--- 清理指定的防抖定时器
-- @param timer_name 定时器名称
local function cleanup_debounce_timer(timer_name)
  local old_timer = M._debounce_timers[timer_name]
  if old_timer then
    old_timer:stop()
    if not old_timer:is_closing() then
      old_timer:close()
    end
    M._debounce_timers[timer_name] = nil
  end
end

--- 清理所有防抖定时器
local function cleanup_all_debounce_timers()
  for name, timer in pairs(M._debounce_timers) do
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    M._debounce_timers[name] = nil
  end
end

--- 防抖函数：在指定延迟后执行函数，期间重复调用会重置计时器
-- @param fn 要执行的函数
-- @param delay_ms 延迟时间（毫秒）
-- @param key_prefix 可选的前缀标识（用于区分不同的防抖场景）
-- @return function 包装后的防抖函数
local function debounce(fn, delay_ms, key_prefix)
  key_prefix = key_prefix or tostring(fn)

  return function(...)
    local args = { ... }
    -- 生成唯一的定时器名称，避免不同场景共享同一个定时器
    local timer_name = make_debounce_key(key_prefix)

    -- 如果提供了 key_prefix，则清理该前缀下的所有旧定时器
    -- 否则仅清理基于函数名的旧定时器（向后兼容）
    if key_prefix ~= tostring(fn) then
      -- 清理同前缀的旧定时器
      for name, _ in pairs(M._debounce_timers) do
        if name:find("^" .. key_prefix .. "_") then
          cleanup_debounce_timer(name)
        end
      end
    else
      -- 向后兼容：清理基于函数名的旧定时器
      cleanup_debounce_timer(timer_name)
    end

    -- 创建新的计时器
    local timer = assert(vim.loop.new_timer())
    M._debounce_timers[timer_name] = timer
    timer:start(delay_ms, 0, function()
      vim.schedule(function()
        -- 执行完成后清理定时器引用
        M._debounce_timers[timer_name] = nil
        fn(unpack(args))
      end)
    end)
  end
end

--- 将值限制在指定范围内
-- @param val 输入值
-- @param min_val 最小值
-- @param max_val 最大值
-- @return number 限制后的值
local function clamp(val, min_val, max_val)
  return math.max(min_val, math.min(val, max_val))
end

--- 检查窗口句柄是否有效
-- @param win 窗口句柄
-- @return boolean 是否有效
local function is_win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

--- 检查缓冲区是否有效
-- @param buf 缓冲区句柄
-- @return boolean 是否有效
local function is_buf_valid(buf)
  return type(buf) == "number" and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

--- 安全地调用窗口操作（捕获可能的异常）
-- @param fn 要执行的函数
-- @return boolean 是否成功
local function safe_win_call(fn)
  return pcall(fn)
end

--- 计算窗口实际文本可用宽度（减去装饰列）
-- @return number 文本可用宽度
local function calculate_text_width()
  -- 获取窗口宽度（含所有装饰列）
  local win_width = 0
  if is_win_valid(M.windows.tree) then
    win_width = vim.api.nvim_win_get_width(M.windows.tree)
  elseif is_win_valid(M.windows.main) then
    win_width = vim.api.nvim_win_get_width(M.windows.main)
  end

  if win_width < 1 then
    return 40 -- 默认值
  end

  -- 获取实际文本可用宽度（减去装饰列）
  local target_win = is_win_valid(M.windows.tree) and M.windows.tree or M.windows.main
  local text_width = win_width

  if target_win then
    -- 行号列宽度
    if
      vim.api.nvim_get_option_value("number", { win = target_win })
      or vim.api.nvim_get_option_value("relativenumber", { win = target_win })
    then
      local nw = vim.api.nvim_get_option_value("numberwidth", { win = target_win })
      text_width = text_width - (tonumber(nw) or 4)
    end

    -- 符号列宽度
    local sc = vim.api.nvim_get_option_value("signcolumn", { win = target_win })
    if sc == "yes" then
      text_width = text_width - 2
    elseif sc == "auto" then
      -- auto 时检查是否有符号显示
      local signs = vim.fn.sign_getplaced(vim.api.nvim_win_get_buf(target_win), { group = "*" })
      if signs and signs[1] and #signs[1].signs > 0 then
        text_width = text_width - 2
      end
    end

    -- 折叠列宽度
    if vim.api.nvim_get_option_value("foldenable", { win = target_win }) then
      local fc = vim.api.nvim_get_option_value("foldcolumn", { win = target_win })
      if fc ~= "0" and fc ~= 0 then
        text_width = text_width - (tonumber(fc) or 1)
      end
    end
  end

  return math.max(1, text_width)
end

--- 文本自动换行
-- @param text 原始文本
-- @param max_width 最大宽度（字符数）
-- @return table 换行后的行数组
local function wrap_text(text, max_width)
  local wrapped = {}
  local current = ""
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if #current + #ch <= max_width or current == "" then
      current = current .. ch
    else
      table.insert(wrapped, current)
      current = ch
    end
  end
  if current ~= "" then
    table.insert(wrapped, current)
  end
  return #wrapped > 0 and wrapped or { text }
end

--- 截断过长的内容（正确支持 UTF-8 多字节字符）
-- @param content 原始内容
-- @param max_chars 最大字符数（中文/英文都算 1 个字符）
-- @return string 截断后的内容
local function truncate_content(content, max_chars)
  if not content or content == "" then
    return ""
  end
  -- 统计字符数（使用 Lua 标准库的 string.len 和模式匹配处理 UTF-8）
  local char_count = 0
  local byte_idx = 1
  local pos = 1
  local len = #content

  while pos <= len and char_count < max_chars do
    local byte = content:byte(pos)
    -- 确定 UTF-8 字符字节数
    local char_len
    if byte < 0x80 then
      char_len = 1
    elseif byte < 0xE0 then
      char_len = 2
    elseif byte < 0xF0 then
      char_len = 3
    elseif byte < 0xF8 then
      char_len = 4
    else
      char_len = 1 -- 无效字节，跳过
    end

    pos = pos + char_len
    char_count = char_count + 1
  end

  if char_count < max_chars or pos > len then
    return content
  end

  -- 截断到完整的字符边界
  local truncated = content:sub(1, pos - 1)
  return truncated .. "…"
end

--- 将消息内容按行换行处理
-- @param content 原始内容
-- @param max_width 最大宽度
-- @return table 换行后的行数组
local function wrap_message_content(content, max_width)
  local result = {}
  for line in content:gmatch("[^\r\n]+") do
    for _, wl in ipairs(wrap_text(line, max_width)) do
      table.insert(result, wl)
    end
  end
  return #result > 0 and result or { "" }
end

--- 计算字符串的显示宽度（考虑中文等宽字符）
-- @param str 输入字符串
-- @return number 显示宽度
local function display_width(str)
  if not str or str == "" then
    return 0
  end
  local chinese_chars = str:gsub("[%z\1-\127\194-\244][\128-\191]*", function(ch)
    if #ch >= 3 then
      return "aa" -- 中文字符按 2 个英文字符宽度计算
    else
      return ch
    end
  end)
  return #chinese_chars
end

--- 清理字符串中的换行符和乱码标记（如 <e5>、<e8><af> 等）
-- @param str 输入字符串
-- @return string 清理后的字符串
local function sanitize_line(str)
  if not str then
    return ""
  end
  return tostring(str):gsub("[\r\n]+", " "):gsub("<%x%x>", "")
end

--- 根据缩进深度动态计算预览长度（越深的分支越短）
-- @param tree_prefix 树形缩进前缀
-- @param max_chars 最大字符数（默认 20）
-- @return number 预览字符数（范围 5~max_chars）
local function calc_preview_length(tree_prefix, max_chars)
  max_chars = max_chars or 20
  -- 计算缩进深度（每个 "│  " 或 "   " 或 "├─ " 或 "└─ " 算一级）
  local depth = 0
  local pos = 1
  while pos <= #tree_prefix do
    local segment = tree_prefix:sub(pos, pos + 2)
    if segment == "│  " or segment == "   " or segment == "├─ " or segment == "└─ " then
      depth = depth + 1
      pos = pos + 3
    else
      pos = pos + 1
    end
  end
  -- 深度越深，预览越短（范围 5~20）
  return math.max(5, max_chars - depth)
end

--- 获取输入框分隔线字符
-- @return string 分隔线字符
function M.get_separator_char()
  return SEPARATOR_CHARS[M.config.ui.input_separator] or "─"
end

-- ── 窗口管理函数 ─────────────────────────────────────────────────────────────

--- 验证并限制窗口位置和大小
-- @param row 行
-- @param col 列
-- @param width 宽度
-- @param height 高度
-- @return 验证后的行、列、宽度、高度
function M.validate_window_position(row, col, width, height)
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines - (vim.o.cmdheight or 1)

  width = clamp(width, 10, editor_width)
  height = clamp(height, 5, editor_height)
  row = clamp(row, 0, editor_height - height)
  col = clamp(col, 0, editor_width - width)

  return row, col, width, height
end

--- 根据窗口模式应用大小限制
-- @param mode 窗口模式
-- @param width 原始宽度
-- @param height 原始高度
-- @return 调整后的宽度和高度
function M.apply_size_limits(mode, width, height)
  local limits = M.WINDOW_LIMITS[mode] or M.WINDOW_LIMITS.float
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  if limits.max_width_ratio then
    width = math.min(width, math.floor(editor_width * limits.max_width_ratio))
  end
  if limits.max_height_ratio then
    height = math.min(height, math.floor(editor_height * limits.max_height_ratio))
  end
  if limits.min_width then
    width = math.max(width, limits.min_width)
  end
  if limits.min_height then
    height = math.max(height, limits.min_height)
  end

  return width, height
end

--- 清理无效的窗口和缓冲区
-- @return integer 清理的数量
function M.cleanup_windows()
  local cleaned = 0

  local function cleanup_table(t, validator)
    for key, value in pairs(t) do
      if not validator(value) then
        t[key] = nil
        cleaned = cleaned + 1
      end
    end
  end

  cleanup_table(M.windows, is_win_valid)
  cleanup_table(M.buffers, is_buf_valid)
  cleanup_table(M.tree_buffers, is_buf_valid)
  
  -- 清理推理浮动窗口
  for msg_id, _ in pairs(M._reasoning_float_wins) do
    M.close_reasoning_float(msg_id)
    cleaned = cleaned + 1
  end
  cleanup_table(M._reasoning_float_wins, function(win) return win and vim.api.nvim_win_is_valid(win) end)
  cleanup_table(M._reasoning_float_buffers, is_buf_valid)

  -- 清理已删除的缓冲区引用
  if not is_buf_valid(M.buffers.main) then
    M.buffers.main = nil
  end
  if not is_buf_valid(M.tree_buffers.main) then
    M.tree_buffers.main = nil
  end

  return cleaned
end

--- 设置窗口换行选项
function M.set_window_wrap()
  for _, win in pairs(M.windows) do
    if is_win_valid(win) then
      vim.api.nvim_set_option_value("wrap", true, { win = win })
      vim.api.nvim_set_option_value("linebreak", true, { win = win })
      vim.api.nvim_set_option_value("breakindent", true, { win = win })
    end
  end
end

--- 计划调整窗口大小（防抖）
function M.schedule_resize()
  if M._resize_pending then
    return
  end
  M._resize_pending = true

  vim.defer_fn(function()
    M._resize_pending = false
    if M.is_open and is_win_valid(M.windows.main) then
      M.update_display()
    end
  end, 100)
end

--- 防抖后的更新显示函数集合（50ms 延迟）
-- 为不同事件类型创建独立的防抖函数，避免共享定时器导致意外延迟
-- 每个事件类型使用唯一前缀，确保定时器不会互相干扰
M.update_display_debounced = {}

-- 通用防抖更新（向后兼容）
M.update_display_debounced.default = debounce(function()
  M.update_display()
end, 50, "update_display_default")

-- 各事件类型独立的防抖更新函数
M.update_display_debounced.message = debounce(function()
  M.update_display()
end, 50, "update_display_message")

M.update_display_debounced.delete = debounce(function()
  M.update_display()
end, 50, "update_display_delete")

M.update_display_debounced.reply = debounce(function()
  M.update_display()
end, 50, "update_display_reply")

M.update_display_debounced.response = debounce(function()
  M.update_display()
end, 50, "update_display_response")

M.update_display_debounced.session = debounce(function()
  M.update_display()
end, 50, "update_display_session")

M.update_display_debounced.turn = debounce(function()
  M.update_display()
end, 50, "update_display_turn")

--- 调整窗口大小（根据内容自动计算）
-- @param content_width 内容宽度
-- @param content_height 内容高度
function M.adjust_window_size(content_width, content_height)
  if not is_win_valid(M.windows.main) then
    return
  end

  local mode = M.current_mode
  local editor_w = vim.o.columns
  local editor_h = vim.o.lines

  -- 浮动模式：居中显示，自动调整大小
  if mode == M.ui_modes.FLOAT then
    local w = clamp(content_width + 6, 50, math.min(math.floor(editor_w * 0.85), 140))
    local h = clamp(content_height + 6, 8, math.min(editor_h - 6, 45))
    w, h = M.apply_size_limits("float", w, h)

    local row = math.max(0, math.floor((editor_h - h) / 2))
    local col = math.max(0, math.floor((editor_w - w) / 2))
    row, col, w, h = M.validate_window_position(row, col, w, h)

    safe_win_call(function()
      vim.api.nvim_win_set_config(M.windows.main, {
        relative = "editor",
        row = row,
        col = col,
        width = w,
        height = h,
      })
    end)
  -- 分割模式：调整宽度
  elseif mode == M.ui_modes.SPLIT then
    local w = clamp(content_width + 6, 40, math.min(math.floor(editor_w * 0.6), 120))
    w = M.apply_size_limits("split", w, editor_h)

    safe_win_call(function()
      vim.api.nvim_win_set_width(M.windows.main, w)
    end)
  end
  -- 标签模式由Neovim自动管理
end

--- 调整树窗口大小（动态宽度，最大值为屏幕一半）
function M.adjust_tree_window_size()
  if not is_win_valid(M.windows.tree) or not is_buf_valid(M.tree_buffers.main) then
    return
  end

  local editor_w = vim.o.columns
  local max_width = math.floor(editor_w * 0.5)

  -- 计算树内容的最大宽度
  local lines = vim.api.nvim_buf_get_lines(M.tree_buffers.main, 0, -1, false)
  local max_w = 0

  for _, line in ipairs(lines) do
    local width = display_width(line)
    max_w = math.max(max_w, width)
  end

  -- 动态宽度 = 内容宽度 + 边距，但不超过屏幕一半
  local target = math.min(max_w + 10, max_width)
  target = clamp(target, M.WINDOW_LIMITS.tree.min_width, max_width)

  local current_w = vim.api.nvim_win_get_width(M.windows.tree)
  if target ~= current_w then
    safe_win_call(function()
      vim.api.nvim_win_set_width(M.windows.tree, target)
    end)
  end
end

-- ── 窗口策略函数 ─────────────────────────────────────────────────────────────

--- 获取窗口策略函数
-- 根据不同的窗口模式（浮动、分割、标签、树视图）返回对应的窗口配置生成函数
-- @param mode 窗口模式 (float/split/tab/tree)
-- @return function 窗口策略函数，调用后返回窗口配置表
function M.get_window_strategy(mode)
  local strategies = {
    -- 浮动窗口策略：在编辑器中央弹出独立窗口
    [M.ui_modes.FLOAT] = function()
      local width = math.min(M.config.ui.width, vim.o.columns - 10)
      local height = math.min(M.config.ui.height, vim.o.lines - 10)
      width, height = M.apply_size_limits("float", width, height)

      -- 居中计算
      local row = math.floor((vim.o.lines - height) / 2)
      local col = math.floor((vim.o.columns - width) / 2)
      row, col, width, height = M.validate_window_position(row, col, width, height)

      return {
        relative = "editor", -- 相对于整个编辑器
        width = width,
        height = height,
        row = row,
        col = col,
        border = M.config.ui.border, -- 使用配置的边框样式
        style = "minimal", -- 最小化样式，隐藏行号等
        focusable = true, -- 允许获取焦点
      }
    end,

    -- 分割窗口策略：在编辑器右侧打开垂直分割窗口
    [M.ui_modes.SPLIT] = function()
      local width = math.floor(vim.o.columns * 0.4) -- 默认占屏幕40%宽度
      local height = M.config.ui.height
      width, height = M.apply_size_limits("split", width, height)

      return {
        relative = "editor",
        width = width,
        height = height,
        row = 0,
        col = vim.o.columns - width, -- 靠右对齐
        style = "minimal",
        border = M.config.ui.border,
      }
    end,

    -- 标签页模式策略：占满整个标签页
    [M.ui_modes.TAB] = function()
      local width = vim.o.columns
      local height = vim.o.lines
      width, height = M.apply_size_limits("tab", width, height)
      return { width = width, height = height }
    end,

    -- 树视图窗口策略：相对于父窗口定位
    tree = function(parent_win, width)
      width = width or 45 -- 增加默认宽度
      width = math.max(width, M.WINDOW_LIMITS.tree.min_width)

      -- 限制树窗口宽度不超过父窗口的指定比例
      if M.WINDOW_LIMITS.tree.max_width_ratio and parent_win and is_win_valid(parent_win) then
        local parent_width = vim.api.nvim_win_get_width(parent_win)
        width = math.min(width, math.floor(parent_width * M.WINDOW_LIMITS.tree.max_width_ratio))
      end

      -- 确保最小宽度
      width = math.max(width, 45)

      return {
        relative = "win", -- 相对于指定窗口
        win = parent_win or M.windows.main,
        width = width,
        height = math.min(M.config.ui.height, vim.o.lines - 10),
        row = 0,
        col = 0, -- 与父窗口左上角对齐
        style = "minimal",
        border = M.config.ui.border,
        focusable = true,
      }
    end,
  }

  return strategies[mode]
end

--- 设置窗口
-- 打开主聊天窗口并初始化相关组件（缓冲区、快捷键、输入处理）
-- 完成后自动将光标定位到输入行并进入插入模式
-- @param win_opts 窗口配置选项表
function M.setup_windows(win_opts)
  M.windows.main = vim.api.nvim_open_win(M.buffers.main, true, win_opts)
  M.set_window_wrap()
  M.setup_buffers()
  M.is_open = true

  -- 异步等待渲染完成后将光标定位到输入提示行
  vim.defer_fn(function()
    if M.is_open and is_win_valid(M.windows.main) and is_buf_valid(M.buffers.main) then
      -- 确保输入行可编辑
      vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main })
      vim.api.nvim_set_option_value("readonly", false, { buf = M.buffers.main })

      -- 定位到输入行
      if M.input_start_line then
        local cursor_line = M.input_start_line + 1 -- +1 因为 cursor 是 1-indexed
        vim.api.nvim_win_set_cursor(M.windows.main, { cursor_line, 0 })
        vim.cmd("normal! zb")
        -- 进入插入模式准备输入
        vim.cmd("startinsert")
      end
    end
  end, 100) -- 100ms 延迟确保渲染完成
end

--- 设置树窗口光标移动自动命令
-- 为树缓冲区注册 CursorMoved 事件处理器，支持智能跳转：
-- 向下移动时跳到下一轮对话开始，向上移动时跳到上一轮对话开始
function M.setup_tree_cursor_autocmd()
  if not is_buf_valid(M.tree_buffers.main) then
    return
  end

  -- ── 统一的定时器生命周期管理 ──
  -- 存储该 autocmd 实例相关的所有定时器
  local autocmd_timers = {}

  --- 注册定时器到统一管理
  local function register_timer(timer)
    if timer then
      table.insert(autocmd_timers, timer)
    end
    return timer
  end

  --- 清理所有注册的定时器
  local function cleanup_autocmd_timers()
    for _, timer in ipairs(autocmd_timers) do
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    autocmd_timers = {}
  end

  -- 记录上一次的光标位置
  local last_cursor_pos = { 0, 0 }
  -- 防止递归触发
  local is_moving = false
  -- 记录上一次的跳转目标（用于避免重复跳转）
  local last_target_line = nil
  -- 等待树渲染完成的防抖定时器
  local is_ready = false
  local ready_timer = nil
  -- 跳转防抖定时器（防止过快触发）
  local jump_debounce_timer = nil
  -- 树渲染版本计数器（用于检测删除/刷新后的状态重置）
  local tree_render_version = 0

  -- 延迟启用跳转功能，等待树渲染完成
  local function enable_after_delay()
    if ready_timer then
      ready_timer:stop()
      if not ready_timer:is_closing() then
        ready_timer:close()
      end
    end

    ready_timer = vim.loop.new_timer()
    if ready_timer then
      register_timer(ready_timer)
      ready_timer:start(200, 0, function()
        vim.schedule(function()
          is_ready = true
        end)
      end)
    end
  end

  enable_after_delay()

  local tree_augroup = vim.api.nvim_create_augroup("NeoAITreeCursor", { clear = true })

  -- 注册缓冲区删除/窗口关闭时的清理回调，防止内存泄漏
  vim.api.nvim_create_autocmd({ "BufDelete", "WinClosed" }, {
    group = tree_augroup,
    buffer = M.tree_buffers.main,
    callback = function()
      cleanup_autocmd_timers()
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = tree_augroup,
    buffer = M.tree_buffers.main,
    callback = function()
      -- 未就绪或正在移动或窗口无效，直接返回
      if not is_ready or is_moving or not is_win_valid(M.windows.tree) then
        return
      end

      local current_pos = vim.api.nvim_win_get_cursor(M.windows.tree)
      local current_line = current_pos[1]

      -- 检测树是否被重新渲染（版本号变化或总行数变化）
      local buf_line_count = vim.api.nvim_buf_line_count(M.tree_buffers.main)
      local current_version = M._tree_version or 0
      if current_version ~= tree_render_version or buf_line_count < last_cursor_pos[1] then
        -- 树已修改，重置导航状态
        tree_render_version = current_version
        last_cursor_pos = current_pos
        last_target_line = nil
        return
      end

      local last_line = last_cursor_pos[1]

      -- 只在行号改变时触发（忽略列移动）
      if current_line == last_line then
        last_cursor_pos = current_pos
        return
      end

      -- 判断移动方向
      local direction = 0
      if current_line > last_line then
        direction = 1 -- 向下
      elseif current_line < last_line then
        direction = -1 -- 向上
      end

      -- 如果有上下移动，尝试跳转到下一个/上一个对话轮次
      if direction ~= 0 then
        -- 确保 session_positions 已初始化且为 table
        local session_positions = M.tree_buffers.session_positions
        if not session_positions or type(session_positions) ~= "table" then
          -- 未初始化完成，重置就绪状态并重新计时
          is_ready = false
          enable_after_delay()
          last_cursor_pos = current_pos
          return
        end

        -- 创建快照（防止并发修改）
        local positions_snapshot = vim.deepcopy(session_positions) or {}

        -- 收集所有可导航的行（对话轮次 + 所有会话节点）
        local all_turn_lines = {}
        for line_num, pos in pairs(positions_snapshot) do
          if pos and type(pos) == "table" then
            if pos.type == "conversation_turn" then
              table.insert(all_turn_lines, { line = line_num, turn_index = pos.turn_index, pos = pos })
            elseif pos.type == "session" and pos.id then
              -- 所有会话节点都作为导航目标（包括空会话和有消息的会话）
              table.insert(all_turn_lines, { line = line_num, turn_index = 0, pos = pos })
            end
          end
        end

        -- 按行号排序
        table.sort(all_turn_lines, function(a, b)
          return a.line < b.line
        end)

        -- 查找目标行
        local target_line = nil

        if direction == 1 then
          -- 向下：找第一个大于当前行的对话轮次
          for _, item in ipairs(all_turn_lines) do
            if item.line > current_line then
              target_line = item.line
              break
            end
          end
        else
          -- 向上：找最后一个小于当前行的对话轮次
          for i = #all_turn_lines, 1, -1 do
            if all_turn_lines[i].line < current_line then
              target_line = all_turn_lines[i].line
              break
            end
          end
        end

        -- 如果找到目标行且与上次跳转不同，执行跳转
        if target_line and target_line ~= last_target_line then
          -- 取消之前的防抖定时器
          if jump_debounce_timer then
            jump_debounce_timer:stop()
            if not jump_debounce_timer:is_closing() then
              jump_debounce_timer:close()
            end
          end

          -- 防抖延迟（50ms）
          jump_debounce_timer = vim.loop.new_timer()
          if not jump_debounce_timer then
            return
          end

          -- 注册到统一生命周期管理
          register_timer(jump_debounce_timer)

          local captured_target_line = target_line

          jump_debounce_timer:start(50, 0, function()
            vim.schedule(function()
              if not is_win_valid(M.windows.tree) then
                return
              end

              is_moving = true
              last_target_line = captured_target_line

              -- 更新位置为目标行（避免再次触发）
              last_cursor_pos = { captured_target_line, 0 }

              -- 设置光标
              pcall(function()
                vim.api.nvim_win_set_cursor(M.windows.tree, { captured_target_line, 0 })
              end)
              is_moving = false
            end)
          end)
          return
        end

        -- 没找到目标行（已在边界），清除上次目标记录
        last_target_line = nil
      end

      -- 更新上一次的位置
      last_cursor_pos = current_pos
    end,
  })
end

-- ── 标签页标签管理 ─────────────────────────────────────────────────────────

--- 获取标签页标签
-- 生成自定义的标签栏显示内容，为包含 NeoAI 窗口的标签页显示特殊标识
-- 使用 Neovim 的 statusline 语法（%#TabLineSel#、%#TabLine# 等）
-- @return string 标签页标签字符串（用于 vim.o.tabline）
function M.get_tab_label()
  local label = ""
  -- 遍历所有标签页，构建标签栏字符串
  for n, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    -- 根据是否为当前活动标签页，使用不同的高亮组
    label = label .. (tabpage == vim.api.nvim_get_current_tabpage() and "%#TabLineSel#" or "%#TabLine#")
    label = label .. "%" .. n .. "T " -- 设置标签页点击区域

    -- 检查该标签页是否包含 NeoAI 窗口
    local wins = vim.api.nvim_tabpage_list_wins(tabpage)
    local has_neoai = false

    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      -- 通过缓冲区名称判断是否为 NeoAI
      local bufname = vim.api.nvim_buf_get_name(buf)
      if
        bufname
        and (
          bufname:match("NeoAI")
          or bufname:match("NeoAI://")
          or bufname:match("NeoAI%-Tree")
          or vim.api.nvim_get_option_value("filetype", { buf = buf }) == "NeoAI"
          or vim.api.nvim_get_option_value("filetype", { buf = buf }) == "NeoAITree"
        )
      then
        has_neoai = true
        break
      end
    end

    -- 根据是否包含 NeoAI 显示不同的标签内容
    if has_neoai then
      label = label .. "🤖 NeoAI" -- NeoAI 标签页显示机器人图标
    else
      -- 非 NeoAI 标签页显示第一个缓冲区的文件名
      local tabnr = vim.api.nvim_tabpage_get_number(tabpage)
      local buflist = vim.fn.tabpagebuflist(tabnr)
      if buflist and #buflist > 0 then
        local bufname = vim.fn.bufname(buflist[1])
        label = label .. (bufname and bufname ~= "" and vim.fn.fnamemodify(bufname, ":t") or "[No Name]")
      end
    end
    label = label .. " "
  end

  return label .. "%#TabLine#%T" -- 结尾添加默认标签样式
end

-- 为 vim 表达式提供全局函数（解决 E117 错误）
_G.neoai_get_tab_label = function()
  return M.get_tab_label()
end

-- ── 缓冲区管理 ──────────────────────────────────────────────────────────────

--- 创建主缓冲区
-- 创建用于显示聊天内容的主缓冲区，并初始化欢迎信息
function M.create_buffers()
  -- 如果已存在有效缓冲区，直接复用
  if is_buf_valid(M.buffers.main) then
    return
  end

  M.buffers.main = vim.api.nvim_create_buf(false, true) -- 不关联文件，设为列表缓冲区
  vim.api.nvim_buf_set_name(M.buffers.main, "NeoAI:chat") -- 设置缓冲区名称，方便 :b 切换
  vim.api.nvim_set_option_value("buflisted", true, { buf = M.buffers.main }) -- 让 buffer 出现在 :ls 列表中
  -- 初始化欢迎信息
  vim.api.nvim_buf_set_lines(M.buffers.main, 0, -1, false, {
    "",
    "  欢迎使用 NeoAI!",
    "  输入消息开始对话",
    "",
  })
end

--- 创建树视图缓冲区
-- 创建用于显示会话列表树视图的缓冲区，设置文件类型和渲染初始内容
function M.create_tree_buffers()
  -- 如果已存在有效树缓冲区，直接复用
  if is_buf_valid(M.tree_buffers.main) then
    return
  end

  M.tree_buffers.main = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(M.tree_buffers.main, "NeoAI-Tree")
  vim.api.nvim_set_option_value("filetype", "NeoAITree", { buf = M.tree_buffers.main }) -- 设置专属文件类型（用于语法高亮等）
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.tree_buffers.main }) -- 非文件缓冲区
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = M.tree_buffers.main }) -- 隐藏时保留缓冲区
  vim.api.nvim_set_option_value("buflisted", true, { buf = M.tree_buffers.main }) -- 让 buffer 出现在 :ls 列表中
  M.render_session_tree() -- 渲染会话树内容
  M.setup_tree_keymaps() -- 设置树视图快捷键
end

--- 设置缓冲区属性
-- 配置主缓冲区的各项属性，并初始化快捷键、输入处理和显示
function M.setup_buffers()
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = M.buffers.main })
  vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main }) -- 允许编辑
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.buffers.main }) -- 非文件缓冲区
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = M.buffers.main }) -- 隐藏时保留缓冲区
  vim.api.nvim_set_option_value("swapfile", false, { buf = M.buffers.main }) -- 不创建交换文件
  
  -- 设置缩进选项
  vim.api.nvim_set_option_value("shiftwidth", 4, { buf = M.buffers.main })
  vim.api.nvim_set_option_value("tabstop", 4, { buf = M.buffers.main })
  vim.api.nvim_set_option_value("softtabstop", 4, { buf = M.buffers.main })
  vim.api.nvim_set_option_value("expandtab", true, { buf = M.buffers.main })
  
  M.setup_keymaps() -- 设置快捷键
  M.setup_input_handling() -- 设置输入处理（自动命令）
  M.update_display() -- 初始渲染显示
end

-- ── 统一重绘函数 ─────────────────────────────────────────────────────────────

--- 统一重绘树视图界面
-- 封装树视图的完整渲染流程：清除内容、重绘、设置高亮、调整大小
function M._render_tree_interface()
  local buf = M.tree_buffers.main
  if not is_buf_valid(buf) then
    return
  end

  -- 确保缓冲区可修改
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = buf })

  -- 清除旧内容和虚拟文本
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  local ns_bottom_hint = vim.api.nvim_create_namespace("NeoAITreeBottomHint")
  vim.api.nvim_buf_clear_namespace(buf, ns_bottom_hint, 0, -1)

  -- 递增版本号（通知光标回调重置导航状态）
  M._tree_version = (M._tree_version or 0) + 1

  -- 渲染树内容
  M._build_tree_content()

  -- 应用高亮和设置只读
  M._apply_tree_highlights(buf)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })

  -- 延迟调整窗口大小
  vim.defer_fn(function()
    M.adjust_tree_window_size()
  end, 10)
end

--- 构建树视图内容（内部辅助函数）
-- @return table 行数组
function M._build_tree_content()
  local buf = M.tree_buffers.main
  local lines = {}
  local ns_id = vim.api.nvim_create_namespace("NeoAITree")
  M.tree_buffers.session_positions = {}
  M._next_line_num = 1

  -- 标题
  local title = "Chat History"
  local separator_len = 30
  table.insert(lines, "╭─ " .. title .. " ─" .. string.rep("─", separator_len) .. "╮")
  M._next_line_num = M._next_line_num + 1

  if backend.sessions and #backend.sessions > 0 then
    local root_sessions = {}
    for session_id, session in pairs(backend.sessions) do
      local graph = backend.session_graph[session_id]
      if not graph or not graph.parent or not backend.sessions[graph.parent] then
        table.insert(root_sessions, session_id)
      end
    end
    table.sort(root_sessions)

    for idx, session_id in ipairs(root_sessions) do
      local is_last_root = (idx == #root_sessions)
      local session = backend.sessions[session_id]
      local prefix = is_last_root and "└─ " or "├─ "
      local file_icon = "󰈙"
      local session_info =
        string.format("%s%s %s (%d)", prefix, file_icon, sanitize_line(session.name), #session.messages)
      table.insert(lines, session_info)

      M.tree_buffers.session_positions[M._next_line_num] =
        { type = "session", id = session_id, line = M._next_line_num - 1 }
      M._next_line_num = M._next_line_num + 1

      local child_prefix = is_last_root and "   " or "│  "
      M._render_session_tree_recursive(lines, session_id, session, child_prefix, true)

      table.insert(lines, "")
      M._next_line_num = M._next_line_num + 1
    end
  else
    table.insert(lines, "│")
    M._next_line_num = M._next_line_num + 1
    table.insert(lines, "│  暂无会话")
    M._next_line_num = M._next_line_num + 1
    table.insert(lines, "│")
    M._next_line_num = M._next_line_num + 1
    table.insert(lines, "│  按 <CR> 创建新会话")
    M._next_line_num = M._next_line_num + 1
    table.insert(lines, "")
    M._next_line_num = M._next_line_num + 1
  end

  -- 写入缓冲区
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- 添加底部提示
  M._add_tree_bottom_hints(buf, lines, ns_id)
end

--- 添加树视图底部提示（内部辅助函数）
-- @param buf 缓冲区句柄
-- @param lines 行数组
-- @param ns_id 命名空间ID
function M._add_tree_bottom_hints(buf, lines, ns_id)
  local win_width = 40
  if is_win_valid(M.windows.tree) then
    win_width = vim.api.nvim_win_get_width(M.windows.tree)
  elseif is_win_valid(M.windows.main) then
    win_width = vim.api.nvim_win_get_width(M.windows.main)
  end

  local max_width_per_line = math.max(25, win_width - 2)

  local all_parts = {
    "<CR> 选择",
    "n 分支",
    "N 空对话",
    "d 删轮次",
    "D 删分支",
    "q 关闭",
  }

  local hint_lines = {}
  local current_line = ""
  for _, part in ipairs(all_parts) do
    local prefixed = "🔹 " .. part
    local test_line = current_line == "" and prefixed or (current_line .. "  " .. prefixed)
    if display_width(test_line) <= max_width_per_line and current_line ~= "" then
      current_line = test_line
    else
      if current_line ~= "" then
        table.insert(hint_lines, current_line)
      end
      current_line = prefixed
    end
  end
  if current_line ~= "" then
    table.insert(hint_lines, current_line)
  end

  local separator_len = calculate_text_width()

  table.insert(lines, "")
  M._next_line_num = M._next_line_num + 1
  local separator_line = #lines
  table.insert(lines, string.rep(M.get_separator_char(), separator_len))
  M._next_line_num = M._next_line_num + 1

  for _, line in ipairs(hint_lines) do
    table.insert(lines, line)
    M._next_line_num = M._next_line_num + 1
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.api.nvim_buf_set_extmark(buf, ns_id, separator_line, 0, {
    end_row = separator_line + 1,
    hl_group = "Comment",
    hl_eol = true,
  })

  -- 延迟调整分隔线长度
  vim.defer_fn(function()
    if not is_buf_valid(buf) then
      return
    end

    local text_width = calculate_text_width()
    local line_count = vim.api.nvim_buf_line_count(buf)
    local sep_line_idx = nil
    for i = line_count, 1, -1 do
      local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
      if line and line:match("^[─]+$") and #line > 10 then
        sep_line_idx = i - 1
        break
      end
    end

    if not sep_line_idx then
      return
    end

    local new_sep_text = string.rep(M.get_separator_char(), text_width)

    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_set_option_value("readonly", false, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, sep_line_idx, sep_line_idx + 1, false, { new_sep_text })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("readonly", true, { buf = buf })
  end, 50)
end

--- 应用树视图高亮（内部辅助函数）
-- @param buf 缓冲区句柄
function M._apply_tree_highlights(buf)
  local ns_id = vim.api.nvim_create_namespace("NeoAITree")

  for line_num, pos in pairs(M.tree_buffers.session_positions) do
    if pos.type == "session" then
      local hl = "Normal"
      local line_idx = line_num - 1
      local buf_line_count = vim.api.nvim_buf_line_count(buf)
      if line_idx >= 0 and line_idx < buf_line_count then
        vim.api.nvim_buf_set_extmark(buf, ns_id, line_idx, 0, {
          end_row = line_idx + 1,
          end_col = 0,
          hl_group = hl,
        })
      end
    end
  end
end

--- 统一重绘聊天界面
-- 封装聊天界面的完整渲染流程：清除内容、重绘消息、设置可编辑性、调整窗口
function M._render_chat_interface()
  local buf = M.buffers.main
  if not is_buf_valid(buf) then
    return
  end

  -- 保存当前光标位置
  local save_cursor = is_win_valid(M.windows.main) and vim.api.nvim_win_get_cursor(M.windows.main) or nil

  -- 确保缓冲区可修改
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = buf })

  -- 清除旧内容和命名空间
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  local ns_virtual_text = vim.api.nvim_create_namespace("NeoAIVirtualText")
  local ns_highlight = vim.api.nvim_create_namespace("NeoAIHighlight")
  vim.api.nvim_buf_clear_namespace(buf, ns_virtual_text, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_highlight, 0, -1)

  -- 构建聊天内容
  local lines, separator_positions = M._build_chat_content()

  -- 写入缓冲区
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- 添加分隔线和输入提示
  M._add_chat_separators(buf, lines, separator_positions, ns_virtual_text, ns_highlight)

  -- 设置可编辑性
  local session = backend.current_session and backend.sessions[backend.current_session]
  M._setup_editability(buf, session)

  -- 记录行数
  M._last_buffer_line_count = vim.api.nvim_buf_line_count(buf)

  -- 调整窗口大小
  local max_width = calculate_text_width()
  M.adjust_window_size(max_width, #lines)
  M.set_window_wrap()

  -- 恢复光标或滚动到底部
  if is_win_valid(M.windows.main) then
    local last_line = vim.api.nvim_buf_line_count(buf)
    if save_cursor and save_cursor[1] <= last_line then
      pcall(vim.api.nvim_win_set_cursor, M.windows.main, save_cursor)
    else
      vim.api.nvim_win_set_cursor(M.windows.main, { M.input_start_line + 1, 0 })
    end
  end
  
  -- 创建推理内容浮动窗口（延迟执行，确保渲染完成）
  vim.defer_fn(function()
    M._create_reasoning_float_windows()
  end, 50)
end

--- 为所有推理内容创建浮动窗口（仅为思考中的消息创建）
-- 遍历会话消息，为思考中的消息创建浮动窗口
function M._create_reasoning_float_windows()
  local session = backend.current_session and backend.sessions[backend.current_session]
  if not session or not session.messages then
    return
  end
  
  if not is_win_valid(M.windows.main) or not is_buf_valid(M.buffers.main) then
    return
  end
  
  -- 遍历消息，为思考中的消息创建浮动窗口
  local current_line = 0
  for _, msg in ipairs(session.messages) do
    -- 标题行
    current_line = current_line + 1
    
    -- 检查是否有推理内容且正在思考中
    if msg.metadata and msg.metadata.has_reasoning and msg.metadata.reasoning_content
      and M.config.llm.show_reasoning and msg.pending then
      -- 记录推理内容所在的行号
      M._reasoning_line_for_msg[msg.id] = current_line
      
      -- 只为思考中的消息创建浮动窗口
      M.create_reasoning_float_window(
        msg.id, 
        msg.metadata.reasoning_content, 
        M.windows.main, 
        current_line
      )
      
      -- 跳过推理内容行（只有标题行）
      current_line = current_line + 1
    elseif msg.metadata and msg.metadata.has_reasoning and msg.metadata.reasoning_content
      and M.config.llm.show_reasoning then
      -- 思考已完成的消息，只记录行号
      M._reasoning_line_for_msg[msg.id] = current_line
      current_line = current_line + 1
    end
    
    -- 跳过消息内容行
    local content_lines = wrap_message_content(msg.content or "", calculate_text_width() - 4)
    current_line = current_line + #content_lines
    
    -- 跳过消息间的空行
    current_line = current_line + 1
  end
end

-- ── 推理内容自动折叠显示 ────────────────────────────────────────────────────

-- 命名空间 ID（用于虚拟文本）
local reasoning_ns_id = vim.api.nvim_create_namespace('NeoAIReasoningVirtualText')

-- 推理内容状态管理 {message_id = {word_queue, extmark_id, anchor_line, ...}}
local reasoning_state = {}

-- 默认配置
local REASONING_MAX_LINES = 5  -- 思考中时最多显示行数
local REASONING_MAX_WIDTH = 80  -- 默认最大宽度，会自动更新

--- 获取当前窗口的可用宽度
local function get_reasoning_available_width()
  local win_width = 0
  if is_win_valid(M.windows.main) then
    win_width = vim.api.nvim_win_get_width(M.windows.main)
  else
    return REASONING_MAX_WIDTH
  end
  
  local sign_width = 0
  local number_width = 0
  
  -- 获取符号列宽度
  local sc = vim.api.nvim_get_option_value("signcolumn", { win = M.windows.main })
  if sc == "yes" or sc == "auto" then
    sign_width = 2
  end
  
  -- 获取行号列宽度
  if vim.api.nvim_get_option_value("number", { win = M.windows.main })
    or vim.api.nvim_get_option_value("relativenumber", { win = M.windows.main }) then
    number_width = vim.api.nvim_get_option_value("numberwidth", { win = M.windows.main }) or 4
  end
  
  return win_width - sign_width - number_width - 2  -- 减去边距
end

--- 将推理文本格式化为显示行（支持自动换行）
-- @param word_queue 单词/行队列
-- @param width 最大宽度
-- @return table 格式化后的行数组
local function format_reasoning_to_lines(word_queue, width)
  width = width or get_reasoning_available_width()
  local lines = {}
  local current_line = ""
  
  for _, word in ipairs(word_queue) do
    if current_line == "" then
      current_line = word
    else
      local new_line = current_line .. " " .. word
      if #new_line <= width then
        current_line = new_line
      else
        table.insert(lines, current_line)
        current_line = word
      end
    end
  end
  
  if current_line ~= "" then
    table.insert(lines, current_line)
  end
  
  return lines
end

--- 更新推理内容的虚拟文本显示
-- @param message_id 消息ID
-- @param buf 缓冲区句柄
-- @param anchor_line 锚点行（在缓冲区中的位置）
local function update_reasoning_display(message_id, buf, anchor_line)
  local state = reasoning_state[message_id]
  if not state or not is_buf_valid(buf) then
    return
  end
  
  -- 计算所有行
  local all_lines = format_reasoning_to_lines(state.word_queue, get_reasoning_available_width())
  
  -- 只保留最后 REASONING_MAX_LINES 行
  local display_lines = {}
  local start_idx = math.max(1, #all_lines - REASONING_MAX_LINES + 1)
  for i = start_idx, #all_lines do
    table.insert(display_lines, all_lines[i])
  end
  
  -- 构建虚拟行数据（带语法高亮）
  local virt_lines_data = {}
  for _, line in ipairs(display_lines) do
    table.insert(virt_lines_data, {{line, "Comment"}})
  end
  
  -- 清除旧的 extmark
  vim.api.nvim_buf_clear_namespace(buf, reasoning_ns_id, 0, -1)
  
  -- 创建新的 extmark（在锚点行上方显示）
  state.extmark_id = vim.api.nvim_buf_set_extmark(buf, reasoning_ns_id, anchor_line, 0, {
    virt_lines = virt_lines_data,
    virt_lines_above = true,
    hl_mode = "combine",
    id = state.extmark_id,  -- 复用已有的 ID
  })
end

--- 添加推理内容到消息队列
-- @param message_id 消息ID
-- @param text 新增的推理文本
-- @param buf 缓冲区句柄
-- @param anchor_line 锚点行
function M.add_reasoning_text(message_id, text, buf, anchor_line)
  if not text or text == "" then
    return
  end
  
  -- 初始化状态
  if not reasoning_state[message_id] then
    reasoning_state[message_id] = {
      word_queue = {},
      extmark_id = nil,
      anchor_line = anchor_line,
    }
  end
  
  local state = reasoning_state[message_id]
  
  -- 简单的分词，按空格和换行分割
  for word in text:gmatch("%S+") do
    table.insert(state.word_queue, word)
  end
  
  -- 更新显示
  update_reasoning_display(message_id, buf, anchor_line)
end

--- 完成推理内容显示
-- @param message_id 消息ID
-- @param buf 缓冲区句柄
-- @param is_fold_completed 是否折叠已完成的内容
-- @return table 完成后的全部显示行
function M.complete_reasoning(message_id, buf, is_fold_completed)
  local state = reasoning_state[message_id]
  if not state then
    return {}
  end
  
  -- 清除虚拟文本
  if is_buf_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, reasoning_ns_id, 0, -1)
  end
  
  -- 生成最终的显示行
  local all_lines = format_reasoning_to_lines(state.word_queue, get_reasoning_available_width())
  
  -- 如果已完成且需要折叠，只保留标题行
  if is_fold_completed then
    local result = {}
    local total_lines = #all_lines
    local header = string.format("  ▼ [思考完成，共 %d 行] 点击折叠/展开", total_lines)
    table.insert(result, header)
    -- 不添加内容行（已折叠）
    return result
  end
  
  -- 否则返回全部行
  local result = {}
  for _, line in ipairs(all_lines) do
    if line and line ~= "" then
      table.insert(result, "    " .. sanitize_line(line))
    end
  end
  
  return result
end

--- 清理推理内容状态
-- @param message_id 消息ID（可选，不提供则清理所有）
function M.cleanup_reason_state(message_id)
  if message_id then
    reasoning_state[message_id] = nil
  else
    reasoning_state = {}
  end
end

--- 构建推理内容显示行（内部辅助函数）
-- 思考中时使用浮动窗口，思考完成后变为折叠文本
-- @param reasoning_text 推理内容字符串
-- @param max_width 最大宽度
-- @param is_complete 思考是否已完成
-- @param message_id 消息ID（用于跟踪折叠状态）
-- @return table 推理内容行数组
local function build_reasoning_lines(reasoning_text, max_width, is_complete, message_id)
  local reasoning_lines_list = {}
  for line in reasoning_text:gmatch("[^\r\n]+") do
    table.insert(reasoning_lines_list, line)
  end

  local total_lines = #reasoning_lines_list
  local result = {}

  if total_lines == 0 then
    return {}
  end

  -- 构建标题行
  local status_text = is_complete and "思考完成" or "思考中"

  -- 思考中：使用浮动窗口显示
  if not is_complete then
    local float_visible = M._reasoning_float_wins[message_id] ~= nil
    local fold_icon = float_visible and "▼" or "▶"
    local header = string.format("  %s [%s，共 %d 行] 浮动窗口", fold_icon, status_text, total_lines)
    table.insert(result, header)
    -- 不在正文中显示内容，浮动窗口会显示
    return result
  end

  -- 思考完成后：使用折叠文本显示
  local folded = M.is_reasoning_folded(message_id)
  local fold_icon = folded and "▶" or "▼"
  local header = string.format("  %s [%s，共 %d 行] 点击展开/折叠", fold_icon, status_text, total_lines)
  table.insert(result, header)

  -- 根据折叠状态决定是否显示内容
  if not folded then
    -- 展开状态：显示全部内容
    for i = 1, total_lines do
      local display_line = reasoning_lines_list[i]
      if display_line and display_line ~= "" then
        local truncated = truncate_content(sanitize_line(display_line), max_width - 6)
        table.insert(result, "    " .. truncated)
      end
    end
  end

  return result
end

--- 构建聊天内容（内部辅助函数）
-- @return table 行数组, table 分隔线位置
function M._build_chat_content()
  local lines = {}
  local max_width = calculate_text_width()
  local separator_positions = {}
  local session = backend.current_session and backend.sessions[backend.current_session]

  -- 清理旧的推理行映射和折叠状态
  M._reasoning_line_for_msg = {}
  -- 清理已完成推理的旧消息的折叠状态（保留当前 pending 消息的状态）
  if session and session.messages then
    local active_msg_ids = {}
    for _, msg in ipairs(session.messages) do
      if msg.metadata and msg.metadata.has_reasoning then
        active_msg_ids[msg.id] = true
      end
    end
    -- 清理不存在消息的折叠状态
    for msg_id in pairs(M._reasoning_fold_state) do
      if not active_msg_ids[msg_id] then
        M._reasoning_fold_state[msg_id] = nil
      end
    end
  end

  -- 渲染消息
  if session and session.messages and #session.messages > 0 then
    for i, msg in ipairs(session.messages) do
      -- 添加角色标题行
      local role_icon = M.config.show_role_icons and (M.config.role_icons[msg.role] or "") or ""
      local role_name = string.upper(msg.role)
      local header = role_icon .. " " .. role_name
      if M.config.show_timestamps then
        header = header .. " · " .. os.date("%H:%M", msg.timestamp)
      end
      table.insert(lines, header)

      -- 如果消息有推理内容且启用了显示，直接插入推理内容行
      if msg.metadata and msg.metadata.has_reasoning and msg.metadata.reasoning_content
        and M.config.llm.show_reasoning then
        local is_complete = not msg.pending -- pending=false 表示思考已完成
        local reasoning_display_lines = build_reasoning_lines(msg.metadata.reasoning_content, max_width, is_complete, msg.id)
        for _, rline in ipairs(reasoning_display_lines) do
          table.insert(lines, rline)
        end
      end

      -- 添加消息内容（自动换行）
      local content_lines = wrap_message_content(msg.content or "", max_width - 4)
      for _, line in ipairs(content_lines) do
        table.insert(lines, line)
      end

      -- 记录分割线位置
      if i < #session.messages then
        table.insert(lines, "")
        table.insert(separator_positions, #lines - 1)
      end
    end
  else
    -- 空状态：显示欢迎信息
    table.insert(lines, "")
    table.insert(lines, "  欢迎使用 NeoAI!")
    table.insert(lines, "  输入消息开始对话")
    table.insert(lines, "")
  end

  return lines, separator_positions
end

--- 添加聊天分隔和输入提示（内部辅助函数）
-- @param buf 缓冲区句柄
-- @param lines 行数组
-- @param separator_positions 分隔线位置
-- @param ns_virtual_text 虚拟文本命名空间
-- @param ns_highlight 高亮命名空间
function M._add_chat_separators(buf, lines, separator_positions, ns_virtual_text, ns_highlight)
  -- 记录输入提示分割线位置
  local separator_line_num = #lines
  table.insert(lines, "")
  table.insert(separator_positions, separator_line_num)

  -- 记录输入行位置
  local input_line = #lines
  table.insert(lines, "")
  M.input_start_line = input_line
  M.input_end_line = input_line

  -- 重新写入缓冲区
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- 添加虚拟文本分割线
  local max_width = calculate_text_width()
  for _, sep_line in ipairs(separator_positions) do
    vim.api.nvim_buf_set_extmark(buf, ns_virtual_text, sep_line, 0, {
      virt_text = { { string.rep(M.get_separator_char(), max_width), "Comment" } },
      virt_text_pos = "overlay",
    })
  end

  -- 为输入行添加虚拟文本提示
  local ns_input = vim.api.nvim_create_namespace("NeoAIInputPrompt")
  vim.api.nvim_buf_set_extmark(buf, ns_input, M.input_start_line, 0, {
    virt_text = { { "输入消息: ", "Comment" } },
    virt_text_pos = "overlay",
  })

  -- 高亮输入区域
  vim.api.nvim_buf_set_extmark(buf, ns_highlight, M.input_start_line, 0, {
    end_row = M.input_end_line + 1,
    hl_group = "NeoAIInput",
    hl_eol = true,
  })
end

-- ── 树视图管理 ─────────────────────────────────────────────────────────────

--- 将消息按对话轮次分组（仅用于树视图）
-- 将扁平的消息列表按"用户消息 + 助手回复"为一组进行聚合
-- 便于在树视图中以对话轮次为单位展示
-- @param messages 消息数组
-- @return table 分组后的对话轮次表
local function group_messages_into_turns(messages)
  local turns = {}
  local current = nil

  for i, msg in ipairs(messages) do
    if msg.role == "user" then
      current = { user_msg = msg, assistant_msg = nil, index = i }
      table.insert(turns, current)
    elseif msg.role == "assistant" and current and not current.assistant_msg then
      current.assistant_msg = msg
    else
      table.insert(turns, { user_msg = msg, assistant_msg = nil, index = i })
    end
  end

  return turns
end

--- 渲染会话树（文件树样式，合并共享历史）
-- 在树视图中展示所有会话及其消息预览，支持点击切换会话
function M.render_session_tree()
  if not is_buf_valid(M.tree_buffers.main) then
    return
  end

  M._render_tree_interface()
end

--- 递归渲染会话树（合并共享历史，在分支点展开子节点）
-- @param lines 行数组（会被修改）
-- @param session_id 当前会话 ID
-- @param session 会话对象
-- @param tree_prefix 树形缩进前缀
-- @param is_last 是否为最后一个兄弟节点
function M._render_session_tree_recursive(lines, session_id, session, tree_prefix, is_last)
  local turns = group_messages_into_turns(session.messages or {})
  if #turns == 0 then
    local empty_line = tree_prefix .. "└─ (空会话)"
    table.insert(lines, empty_line)
    M.tree_buffers.session_positions[M._next_line_num] =
      { type = "session", id = session_id, line = M._next_line_num - 1 }
    M._next_line_num = M._next_line_num + 1
    return
  end

  -- 找出所有子分支及其共同前缀轮次
  local children = backend.get_children(session_id)
  local child_info = {} -- { session_id, common_turns }

  for _, child_id in ipairs(children) do
    if backend.sessions[child_id] then
      local common = backend.get_common_prefix_turns(session_id, child_id)
      table.insert(child_info, { session_id = child_id, common_turns = common })
    end
  end

  -- 计算最大分支点（所有子分支中最大的共同前缀轮次）
  local max_branch_turn = 0
  for _, info in ipairs(child_info) do
    if info.common_turns > max_branch_turn then
      max_branch_turn = info.common_turns
    end
  end

  -- 按共同前缀轮次分组的子分支
  local branches_by_turn = {}
  for _, info in ipairs(child_info) do
    if info.common_turns > 0 then
      branches_by_turn[info.common_turns] = branches_by_turn[info.common_turns] or {}
      table.insert(branches_by_turn[info.common_turns], info)
    end
  end

  -- 渲染消息轮次
  local preview_len = calc_preview_length(tree_prefix)
  for i = 1, #turns do
    local turn = turns[i]
    local is_last_turn = (i == #turns) and (max_branch_turn == 0)
    local line_prefix = tree_prefix .. (is_last_turn and "└─ " or "├─ ")

    -- 用户消息
    local user_preview = truncate_content(sanitize_line(turn.user_msg.content), preview_len)
    local user_time = os.date("%H:%M", turn.user_msg.timestamp)
    table.insert(lines, string.format("%s💬 [%s] %s", line_prefix, user_time, user_preview))

    M.tree_buffers.session_positions[M._next_line_num] = {
      type = "conversation_turn",
      session_id = session_id,
      turn_index = i,
      user_message_index = turn.index,
      line = M._next_line_num - 1,
    }
    M._next_line_num = M._next_line_num + 1

    -- 助手消息
    if turn.assistant_msg then
      local asst_preview = truncate_content(sanitize_line(turn.assistant_msg.content), preview_len)
      local asst_time = os.date("%H:%M", turn.assistant_msg.timestamp)
      local reply_prefix = tree_prefix .. (is_last_turn and "   " or "│  ")
      table.insert(lines, string.format("%s🤖 [%s] %s", reply_prefix, asst_time, asst_preview))

      M.tree_buffers.session_positions[M._next_line_num] = {
        type = "assistant_reply",
        session_id = session_id,
        turn_index = i,
        line = M._next_line_num - 1,
      }
      M._next_line_num = M._next_line_num + 1
    end

    -- 检查是否在这个轮次有分支点
    if branches_by_turn[i] then
      local branch_children = branches_by_turn[i]
      local cont_prefix = tree_prefix .. (is_last_turn and "   " or "│  ")

      for bidx, branch in ipairs(branch_children) do
        local child_session = backend.sessions[branch.session_id]
        if child_session then
          local is_last_child = (bidx == #branch_children)
          local child_prefix = cont_prefix .. (is_last_child and "└─ " or "├─ ")
          local child_icon = "󰈙"
          local child_info_line = string.format(
            "%s%s %s (%d)",
            child_prefix,
            child_icon,
            sanitize_line(child_session.name),
            #child_session.messages
          )
          table.insert(lines, child_info_line)

          M.tree_buffers.session_positions[M._next_line_num] = {
            type = "session",
            id = branch.session_id,
            line = M._next_line_num - 1,
          }
          M._next_line_num = M._next_line_num + 1

          -- 递归渲染子会话（只渲染超出共同前缀的部分）
          local sub_prefix = cont_prefix .. (is_last_child and "   " or "│  ")
          M._render_session_tree_tail(lines, branch.session_id, child_session, sub_prefix, true, i)
        end
      end
    end
  end
end

--- 渲染会话的"尾部"消息（超出共同前缀的部分）
-- @param lines 行数组
-- @param session_id 会话 ID
-- @param session 会话对象
-- @param tree_prefix 树形缩进前缀
-- @param is_last 是否为最后一个兄弟
-- @param skip_turns 跳过的轮次数（与父会话的共同前缀）
function M._render_session_tree_tail(lines, session_id, session, tree_prefix, is_last, skip_turns)
  local turns = group_messages_into_turns(session.messages or {})
  if skip_turns >= #turns then
    return
  end

  -- 检查是否有子分支
  local children = backend.get_children(session_id)
  local child_info = {}
  for _, child_id in ipairs(children) do
    if backend.sessions[child_id] then
      local common = backend.get_common_prefix_turns(session_id, child_id)
      table.insert(child_info, { session_id = child_id, common_turns = common })
    end
  end

  -- 找出在尾部范围内的最大分支点
  local max_branch_turn = 0
  for _, info in ipairs(child_info) do
    if info.common_turns > max_branch_turn and info.common_turns > skip_turns then
      max_branch_turn = info.common_turns
    end
  end

  -- 按绝对轮次分组的子分支（只包含在尾部范围内的）
  local branches_by_turn = {}
  for _, info in ipairs(child_info) do
    if info.common_turns > skip_turns then
      branches_by_turn[info.common_turns] = branches_by_turn[info.common_turns] or {}
      table.insert(branches_by_turn[info.common_turns], info)
    end
  end

  local preview_len = calc_preview_length(tree_prefix)

  for i = skip_turns + 1, #turns do
    local turn = turns[i]
    local is_last_turn = (i == #turns) and (max_branch_turn <= i)
    local line_prefix = tree_prefix .. (is_last_turn and "└─ " or "├─ ")

    local user_preview = truncate_content(sanitize_line(turn.user_msg.content), preview_len)
    local user_time = os.date("%H:%M", turn.user_msg.timestamp)
    table.insert(lines, string.format("%s💬 [%s] %s", line_prefix, user_time, user_preview))

    M.tree_buffers.session_positions[M._next_line_num] = {
      type = "conversation_turn",
      session_id = session_id,
      turn_index = i,
      user_message_index = turn.index,
      line = M._next_line_num - 1,
    }
    M._next_line_num = M._next_line_num + 1

    if turn.assistant_msg then
      local asst_preview = truncate_content(sanitize_line(turn.assistant_msg.content), preview_len)
      local asst_time = os.date("%H:%M", turn.assistant_msg.timestamp)
      local reply_prefix = tree_prefix .. (is_last_turn and "   " or "│  ")
      table.insert(lines, string.format("%s🤖 [%s] %s", reply_prefix, asst_time, asst_preview))

      M.tree_buffers.session_positions[M._next_line_num] = {
        type = "assistant_reply",
        session_id = session_id,
        turn_index = i,
        line = M._next_line_num - 1,
      }
      M._next_line_num = M._next_line_num + 1
    end

    -- 检查子分支（使用绝对轮次索引）
    if branches_by_turn[i] then
      local branch_children = branches_by_turn[i]
      local cont_prefix = tree_prefix .. (is_last_turn and "   " or "│  ")

      for bidx, branch in ipairs(branch_children) do
        local child_session = backend.sessions[branch.session_id]
        if child_session then
          local is_last_child = (bidx == #branch_children)
          local child_prefix = cont_prefix .. (is_last_child and "└─ " or "├─ ")
          local child_icon = "󰈙"
          local child_info_line = string.format(
            "%s%s %s (%d)",
            child_prefix,
            child_icon,
            sanitize_line(child_session.name),
            #child_session.messages
          )
          table.insert(lines, child_info_line)

          M.tree_buffers.session_positions[M._next_line_num] = {
            type = "session",
            id = branch.session_id,
            line = M._next_line_num - 1,
          }
          M._next_line_num = M._next_line_num + 1

          local sub_prefix = cont_prefix .. (is_last_child and "   " or "│  ")
          M._render_session_tree_tail(lines, branch.session_id, child_session, sub_prefix, true, i)
        end
      end
    end
  end
end

--- 设置树视图快捷键
-- 为树视图缓冲区绑定导航和操作快捷键
function M.setup_tree_keymaps()
  if not is_buf_valid(M.tree_buffers.main) then
    return
  end

  local buf = M.tree_buffers.main

  -- 辅助函数：快速绑定普通模式快捷键
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = desc, noremap = true })
  end

  -- 回车键：选择会话或创建新会话
  map("<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(M.windows.tree)
    local line = cursor[1] -- 1-indexed
    local pos = M.tree_buffers.session_positions and M.tree_buffers.session_positions[line]

    if pos and (pos.type == "session" or pos.type == "conversation_turn" or pos.type == "assistant_reply") then
      -- 点击在会话或消息行上：切换到对应会话
      local sid = pos.type == "session" and pos.id or pos.session_id
      -- 同步当前会话数据
      backend.sync_data(backend.current_session)

      backend.current_session = sid
      -- local session = backend.sessions[sid]
      -- vim.notify("[NeoAI] 切换到会话: " .. (session and session.name or sid))
      M.open_chat_after_tree_selection()
    else
      -- 点击在空白行：创建新会话
      backend.new_session()
      vim.notify("[NeoAI] 新会话已创建")
      M.open_chat_after_tree_selection()
    end
  end, "选择会话")

  -- n键：在当前光标位置新建对话分支
  map(M.config.tree_keymaps.new_branch, function()
    local cursor = vim.api.nvim_win_get_cursor(M.windows.tree)
    local line = cursor[1] -- 1-indexed
    local pos = M.tree_buffers.session_positions and M.tree_buffers.session_positions[line]

    if pos and (pos.type == "conversation_turn" or pos.type == "assistant_reply") then
      -- 在对话轮次或助手回复行上：创建分支
      local sid = pos.session_id
      local turn_index = pos.turn_index
      local new_session = backend.create_branch_at_turn(sid, turn_index)
      if new_session then
        vim.schedule(function()
          M.render_session_tree()
        end)
        backend.current_session = new_session.id
        M.open_chat_after_tree_selection()
      end
    elseif pos and pos.type == "session" then
      -- 在会话标题行上：复制整个会话作为新分支
      local sid = pos.id
      local session = backend.sessions[sid]
      if session and #session.messages > 0 then
        -- 在最后一轮创建分支
        local turn_count = 0
        for _, msg in ipairs(session.messages) do
          if msg.role == "user" then
            turn_count = turn_count + 1
          end
        end
        if turn_count > 0 then
          local new_session = backend.create_branch_at_turn(sid, turn_count)
          if new_session then
            vim.schedule(function()
              M.render_session_tree()
            end)
            backend.current_session = new_session.id
            M.open_chat_after_tree_selection()
          end
        else
          vim.notify("[NeoAI] 该会话没有对话轮次", vim.log.levels.WARN)
        end
      else
        vim.notify("[NeoAI] 该会话为空", vim.log.levels.WARN)
      end
    else
      vim.notify("[NeoAI] 请先选择一个对话轮次", vim.log.levels.WARN)
    end
  end, "新建分支")

  -- N键：新建空对话
  map(M.config.tree_keymaps.new_conversation, function()
    backend.new_empty_conversation()
    vim.schedule(function()
      M.render_session_tree()
    end)
    M.open_chat_after_tree_selection() -- 跳到对话界面
  end, "新建空对话")

  -- d键：删除当前光标这一轮对话
  map(M.config.tree_keymaps.delete_turn, function()
    local cursor = vim.api.nvim_win_get_cursor(M.windows.tree)
    local line = cursor[1] -- 1-indexed
    local pos = M.tree_buffers.session_positions and M.tree_buffers.session_positions[line]

    if pos and (pos.type == "conversation_turn" or pos.type == "assistant_reply") then
      -- 在对话轮次或助手回复行上：删除该轮
      local sid = pos.session_id
      local turn_index = pos.turn_index
      if backend.delete_turn(sid, turn_index) then
        vim.schedule(function()
          M.render_session_tree()
        end)
      end
    elseif pos and pos.type == "session" then
      -- 在会话标题行上：检查是否为空会话
      local sid = pos.id
      local session = backend.sessions[sid]
      if session and #(session.messages or {}) == 0 then
        -- 空会话：直接删除
        if backend.delete_branch(sid) then
          vim.schedule(function()
            M.render_session_tree()
          end)
        end
      elseif session and #(session.messages or {}) > 0 then
        vim.notify("[NeoAI] 该会话有对话内容，请使用 D 删除整个分支", vim.log.levels.WARN)
      else
        vim.notify("[NeoAI] 找不到该会话，请刷新树后重试", vim.log.levels.WARN)
      end
    else
      vim.notify("[NeoAI] 请将光标放在要删除的对话轮次或会话上", vim.log.levels.WARN)
    end
  end, "删除当前轮次")

  -- D键：删除当前分支
  map(M.config.tree_keymaps.delete_branch, function()
    local cursor = vim.api.nvim_win_get_cursor(M.windows.tree)
    local line = cursor[1] -- 1-indexed
    local pos = M.tree_buffers.session_positions and M.tree_buffers.session_positions[line]

    if pos and pos.type == "session" then
      -- 在会话标题行上：删除该会话及其所有子会话
      local sid = pos.id
      local session = backend.sessions[sid]
      if session then
        -- 空会话直接删除，有内容的需要确认
        if #(session.messages or {}) == 0 then
          if backend.delete_branch(sid) then
            vim.schedule(function()
              M.render_session_tree()
            end)
          end
        else
          local confirm =
            vim.fn.confirm("确定要删除分支 '" .. session.name .. "' 及其所有子会话吗？", "&Yes\n&No", 2)
          if confirm == 1 then
            if backend.delete_branch(sid) then
              vim.schedule(function()
                M.render_session_tree()
              end)
            end
          end
        end
      else
        vim.notify("[NeoAI] 找不到该会话，请刷新树后重试", vim.log.levels.WARN)
      end
    elseif pos and (pos.type == "conversation_turn" or pos.type == "assistant_reply") then
      -- 在对话轮次或助手回复行上：删除该轮次所在的分支
      local sid = pos.session_id
      local session = backend.sessions[sid]
      if session then
        local confirm =
          vim.fn.confirm("确定要删除分支 '" .. session.name .. "' 及其所有子会话吗？", "&Yes\n&No", 2)
        if confirm == 1 then
          if backend.delete_branch(sid) then
            vim.schedule(function()
              M.render_session_tree()
            end)
          end
        end
      else
        vim.notify("[NeoAI] 找不到该会话，请刷新树后重试", vim.log.levels.WARN)
      end
    else
      vim.notify("[NeoAI] 请将光标放在要删除的会话或对话轮次上", vim.log.levels.WARN)
    end
  end, "删除当前分支")

  -- 关闭快捷键
  map("q", M.close, "关闭")
  map("<Esc>", M.close, "关闭")

  -- r键：刷新树
  map("r", function()
    M.render_session_tree()
    vim.notify("[NeoAI] 已刷新")
  end, "刷新树")

  -- e键：打开配置文件
  map(M.config.tree_keymaps.open_config, function()
    if M.config and M.config.background and M.config.background.config_dir then
      local config_file = require("NeoAI.config").get_config_file(M.config.background)
      vim.cmd("edit " .. vim.fn.fnameescape(config_file))
    else
      vim.notify("[NeoAI] 无法找到配置文件路径", vim.log.levels.WARN)
    end
  end, "打开配置文件")
end

--- 更新主显示
-- 重新渲染主缓冲区的内容，包括所有会话消息和输入提示区域
function M.update_display()
  -- 渲染聊天界面
  M._render_chat_interface()

  -- 刷新树视图（如果应该显示）
  if M.should_show_tree() and is_win_valid(M.windows.tree) and is_buf_valid(M.tree_buffers.main) then
    M.render_session_tree()
  end
end

--- 设置缓冲区可编辑性
-- 建立缓冲区行号到消息对象的映射表，用于控制哪些行可以编辑
-- @param _ 缓冲区句柄（当前未使用）
-- @param session 会话对象
function M._setup_editability(_, session)
  if not session or not session.messages then
    return
  end

  M._line_to_message = {} -- 行号 -> {session_id, message_id} 映射表
  local current_line = 0

  for i, msg in ipairs(session.messages) do
    -- 标题行（不映射，不可编辑）
    current_line = current_line + 1

    -- 跳过推理内容行（不映射，不可编辑）
    if msg.metadata and msg.metadata.has_reasoning and msg.metadata.reasoning_content
      and M.config.llm.show_reasoning then
      local is_complete = not msg.pending
      local reasoning_display_lines = build_reasoning_lines(msg.metadata.reasoning_content, 60, is_complete, msg.id)
      current_line = current_line + #reasoning_display_lines
    end

    -- 获取当前消息的内容行数（自动换行后的行数）
    local content_lines = wrap_message_content(msg.content or "", 60 - 4)

    -- 只映射内容行（不映射标题行），这些行可以被用户编辑
    for j, _ in ipairs(content_lines) do
      local line_num = current_line + j - 1
      M._line_to_message[line_num] = {
        session_id = session.id,
        message_id = msg.id,
      }
    end

    current_line = current_line + #content_lines

    -- 跳过消息间的空行（分割线占位符，不可编辑）
    if i < #session.messages then
      current_line = current_line + 1
    end
  end
end

-- ── 会话管理 ───────────────────────────────────────────────────────────────

--- 确保存在活跃会话
-- @return boolean 是否成功
local function ensure_active_session()
  if backend.current_session and backend.sessions[backend.current_session] then
    return true
  end

  if #backend.sessions == 0 then
    backend.new_session()
  else
    for id, _ in pairs(backend.sessions) do
      backend.current_session = id
      break
    end
  end

  return true
end

--- 选择会话后打开聊天窗口
function M.open_chat_after_tree_selection()
  local mode = M.current_mode

  if mode == M.ui_modes.FLOAT then
    -- 浮动模式：树和主窗口是同一个，先替换缓冲区再删除树缓冲区
    if is_win_valid(M.windows.main) then
      -- 切换回聊天缓冲区
      vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
      M.windows.tree = nil -- 树视图已隐藏
      M.set_window_wrap()
      M.setup_buffers()
      -- 删除树缓冲区
      if is_buf_valid(M.tree_buffers.main) then
        vim.api.nvim_buf_delete(M.tree_buffers.main, { force = true })
        M.tree_buffers.main = nil
      end
      -- 确保光标聚焦在浮动窗口上
      vim.api.nvim_set_current_win(M.windows.main)
    else
      -- 窗口不存在，重新创建
      local opts = M.get_window_strategy(M.ui_modes.FLOAT)()
      M.setup_windows(opts)
    end
  elseif mode == M.ui_modes.SPLIT then
    -- 分割模式：复用现有的分割窗口，只替换缓冲区内容
    if is_win_valid(M.windows.tree) then
      -- 将树窗口重新用于显示聊天内容
      vim.api.nvim_win_set_buf(M.windows.tree, M.buffers.main)
      M.windows.main = M.windows.tree
      M.windows.tree = nil
      vim.api.nvim_win_set_width(M.windows.main, math.floor(vim.o.columns * 0.4))
      -- 禁用行号
      vim.api.nvim_set_option_value("number", false, { win = M.windows.main })
      vim.api.nvim_set_option_value("relativenumber", false, { win = M.windows.main })
      M.set_window_wrap()
      M.setup_buffers()
    else
      -- 如果树窗口不存在，创建新的分割窗口
      vim.cmd("belowright vsplit")
      M.windows.main = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
      -- 禁用行号
      vim.api.nvim_set_option_value("number", false, { win = M.windows.main })
      vim.api.nvim_set_option_value("relativenumber", false, { win = M.windows.main })
      M.set_window_wrap()
      M.setup_buffers()
    end
    -- 删除树缓冲区
    if is_buf_valid(M.tree_buffers.main) then
      vim.api.nvim_buf_delete(M.tree_buffers.main, { force = true })
      M.tree_buffers.main = nil
    end
  elseif mode == M.ui_modes.TAB then
    -- 标签页模式：复用当前标签页，只替换缓冲区内容
    if is_win_valid(M.windows.tree) then
      -- 将树窗口重新用于显示聊天内容
      vim.api.nvim_win_set_buf(M.windows.tree, M.buffers.main)
      M.windows.main = M.windows.tree
      M.windows.tree = nil
      M.set_window_wrap()
      M.setup_buffers()
    else
      -- 如果树窗口不存在，创建新的标签页
      vim.cmd("tabnew")
      M.windows.main = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
      M.set_window_wrap()
      M.setup_buffers()
    end
    -- 删除树缓冲区
    if is_buf_valid(M.tree_buffers.main) then
      vim.api.nvim_buf_delete(M.tree_buffers.main, { force = true })
      M.tree_buffers.main = nil
    end
  end

  -- 从树选择后切换到聊天界面：定位光标到输入行
  vim.defer_fn(function()
    if is_win_valid(M.windows.main) and is_buf_valid(M.buffers.main) and M.input_start_line then
      vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main })
      vim.api.nvim_set_option_value("readonly", false, { buf = M.buffers.main })
      vim.api.nvim_win_set_cursor(M.windows.main, { M.input_start_line + 1, 0 })
      vim.cmd("normal! zb")
      vim.cmd("startinsert")
    end
  end, 50)
end

--- 打开浮窗模式
function M.open_float()
  ensure_active_session()

  if M.should_show_tree() then
    if not is_buf_valid(M.tree_buffers.main) then
      M.create_tree_buffers()
    end

    -- 先创建主缓冲区（不显示）
    if not is_buf_valid(M.buffers.main) then
      M.create_buffers()
    end

    -- 计算树窗口宽度（动态宽度，最大值为屏幕一半）
    local editor_width = vim.o.columns
    local max_width = math.floor(editor_width * 0.5)

    -- 根据内容计算宽度
    local lines = vim.api.nvim_buf_get_lines(M.tree_buffers.main, 0, -1, false)
    local max_content_width = 0
    for _, line in ipairs(lines) do
      local w = display_width(line)
      if w > max_content_width then
        max_content_width = w
      end
    end

    -- 动态宽度 = 内容宽度 + 边距，但不超过屏幕一半
    local tree_w = math.min(max_content_width + 10, max_width)
    tree_w = clamp(tree_w, M.WINDOW_LIMITS.tree.min_width, max_width)

    local float_opts = M.get_window_strategy(M.ui_modes.FLOAT)()
    float_opts.width = tree_w
    float_opts.col = math.floor((vim.o.columns - tree_w) / 2)

    M.windows.tree = vim.api.nvim_open_win(M.tree_buffers.main, true, float_opts)
    M.windows.main = M.windows.tree -- 树窗口就是主窗口

    -- 设置窗口选项
    vim.api.nvim_set_option_value("winfixwidth", true, { win = M.windows.tree })
    vim.api.nvim_set_option_value("wrap", true, { win = M.windows.tree })
    vim.api.nvim_set_option_value("linebreak", true, { win = M.windows.tree })
    vim.api.nvim_set_option_value("breakindent", true, { win = M.windows.tree })

    M.setup_tree_cursor_autocmd()
    M.is_open = true
    M.current_mode = M.ui_modes.FLOAT

    -- 树视图模式：定位光标到第一行
    vim.defer_fn(function()
      if is_win_valid(M.windows.tree) and is_buf_valid(M.tree_buffers.main) then
        vim.api.nvim_win_set_cursor(M.windows.tree, { 1, 0 })
      end
    end, 50)
    return
  end

  M.create_buffers()
  local opts = M.get_window_strategy(M.ui_modes.FLOAT)()
  M.setup_windows(opts)
  M.current_mode = M.ui_modes.FLOAT
end

--- 打开分割窗口模式
function M.open_split()
  ensure_active_session()

  if M.should_show_tree() then
    if not is_buf_valid(M.tree_buffers.main) then
      M.create_tree_buffers()
    end

    -- 先创建主缓冲区（不打开窗口）
    M.create_buffers()

    -- 使用 split 打开窗口，然后用树缓冲区替换
    vim.cmd("belowright vsplit")
    M.windows.tree = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.windows.tree, M.tree_buffers.main)
    local tree_w = math.min(50, math.floor(vim.o.columns * 0.3))
    vim.api.nvim_win_set_width(M.windows.tree, tree_w)
    vim.api.nvim_set_option_value("winfixwidth", true, { win = M.windows.tree })
    -- 启用自动换行
    vim.api.nvim_set_option_value("wrap", true, { win = M.windows.tree })
    vim.api.nvim_set_option_value("linebreak", true, { win = M.windows.tree })
    vim.api.nvim_set_option_value("breakindent", false, { win = M.windows.tree })
    M.setup_tree_cursor_autocmd()
    M.is_open = true
    M.current_mode = M.ui_modes.SPLIT

    -- 树视图模式：定位光标到第一行
    vim.defer_fn(function()
      if is_win_valid(M.windows.tree) and is_buf_valid(M.tree_buffers.main) then
        vim.api.nvim_win_set_cursor(M.windows.tree, { 1, 0 })
      end
    end, 50)
    return
  end

  M.create_buffers()

  vim.cmd("belowright vsplit")
  M.windows.main = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
  local opts = M.get_window_strategy(M.ui_modes.SPLIT)()
  vim.api.nvim_win_set_width(M.windows.main, opts.width)
  -- 禁用行号
  vim.api.nvim_set_option_value("number", false, { win = M.windows.main })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.windows.main })
  M.set_window_wrap()
  M.setup_buffers()
  M.is_open = true
  M.current_mode = M.ui_modes.SPLIT

  -- 非树模式：定位光标到输入行
  vim.defer_fn(function()
    if M.is_open and is_win_valid(M.windows.main) and is_buf_valid(M.buffers.main) and M.input_start_line then
      vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main })
      vim.api.nvim_set_option_value("readonly", false, { buf = M.buffers.main })
      vim.api.nvim_win_set_cursor(M.windows.main, { M.input_start_line + 1, 0 })
      vim.cmd("normal! zb")
      vim.cmd("startinsert")
    end
  end, 50)
end

--- 打开标签页模式
function M.open_tab()
  ensure_active_session()

  if M.should_show_tree() then
    -- 先创建主缓冲区（不打开窗口）
    M.create_buffers()

    -- 创建树缓冲区
    if not is_buf_valid(M.tree_buffers.main) then
      M.create_tree_buffers()
    end

    vim.cmd("tabnew")
    local temp_buf = vim.api.nvim_get_current_buf()

    -- 隐藏临时缓冲区而不是删除，避免产生空buffer
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = temp_buf })
    vim.api.nvim_set_option_value("buflisted", false, { buf = temp_buf })

    M.windows.tree = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.windows.tree, M.tree_buffers.main)

    local tree_w = math.min(50, math.floor(vim.o.columns * 0.3))
    vim.api.nvim_win_set_width(M.windows.tree, tree_w)
    vim.api.nvim_set_option_value("winfixwidth", true, { win = M.windows.tree })
    -- 启用自动换行
    vim.api.nvim_set_option_value("wrap", true, { win = M.windows.tree })
    vim.api.nvim_set_option_value("linebreak", true, { win = M.windows.tree })
    vim.api.nvim_set_option_value("breakindent", false, { win = M.windows.tree })
    M.setup_tree_cursor_autocmd()

    M.is_open = true
    M.current_mode = M.ui_modes.TAB

    -- 树视图模式：定位光标到第一行
    vim.defer_fn(function()
      if is_win_valid(M.windows.tree) and is_buf_valid(M.tree_buffers.main) then
        vim.api.nvim_win_set_cursor(M.windows.tree, { 1, 0 })
      end
    end, 50)
    return
  end

  M.create_buffers()

  vim.cmd("tabnew")
  M.windows.main = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
  M.set_window_wrap()
  M.setup_buffers()
  M.is_open = true
  M.current_mode = M.ui_modes.TAB

  -- 非树模式：定位光标到输入行
  vim.defer_fn(function()
    if M.is_open and is_win_valid(M.windows.main) and is_buf_valid(M.buffers.main) and M.input_start_line then
      vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main })
      vim.api.nvim_set_option_value("readonly", false, { buf = M.buffers.main })
      vim.api.nvim_win_set_cursor(M.windows.main, { M.input_start_line + 1, 0 })
      vim.cmd("normal! zb")
      vim.cmd("startinsert")
    end
  end, 50)
end

-- ── 输入处理 ───────────────────────────────────────────────────────────────

--- 设置输入处理
-- 注册各种自动命令（autocmd），处理窗口焦点、光标移动、文本变化等事件
-- 实现动态可编辑区域、输入提示、自动保存编辑等功能
function M.setup_input_handling()
  local group = vim.api.nvim_create_augroup("NeoAIInput", { clear = true })

  -- 焦点进入/离开聊天窗口时重新设置快捷键
  -- 确保只有聊天窗口激活时才绑定自定义快捷键
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    pattern = "*",
    callback = function()
      if M.windows.main and vim.api.nvim_get_current_win() == M.windows.main then
        M.setup_keymaps() -- 窗口获得焦点时设置快捷键
      else
        M.clear_keymaps() -- 窗口失去焦点时清理快捷键
      end
    end,
  })

  -- 根据光标位置切换可编辑状态
  -- 光标在消息内容行或输入区域时允许编辑，其他区域只读
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = M.buffers.main,
    callback = function()
      if not is_win_valid(M.windows.main) or not is_buf_valid(M.buffers.main) then
        return
      end
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1 -- 0-indexed

      -- 检查是否是输入区域（缓冲区底部的用户输入区域）
      local is_input_region = false
      if M.input_start_line and M.input_end_line then
        is_input_region = cur_line >= M.input_start_line and cur_line <= M.input_end_line
      elseif M.input_start_line and cur_line == M.input_start_line then
        is_input_region = true
      end

      -- 检查是否是可编辑的消息内容行（通过 _line_to_message 映射表判断）
      local is_editable = M._line_to_message and M._line_to_message[cur_line] ~= nil

      -- 输入区域始终可编辑（优先级高于消息内容行）
      if is_input_region then
        is_editable = true
      end

      -- 动态设置缓冲区的可编辑/只读状态
      vim.api.nvim_set_option_value("modifiable", is_editable, { buf = M.buffers.main })
      vim.api.nvim_set_option_value("readonly", not is_editable, { buf = M.buffers.main })

      -- 管理输入行虚拟文本提示（光标在输入行时显示"输入消息: "提示）
      if cur_line == M.input_start_line and is_buf_valid(M.buffers.main) then
        M._update_input_prompt()
      end
    end,
  })

  -- 跟踪输入区域的行数变化（插入模式下）
  -- 用户输入多行文本时，动态更新 input_end_line 边界
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = M.buffers.main,
    callback = function()
      if not is_win_valid(M.windows.main) or not is_buf_valid(M.buffers.main) then
        return
      end

      -- 更新输入提示（根据输入内容是否为空显示/隐藏提示）
      if M.input_start_line then
        M._update_input_prompt()
      end

      -- 检查输入区域的行数变化
      local current_count = vim.api.nvim_buf_line_count(M.buffers.main)
      if M.input_start_line and M.input_end_line then
        -- 如果当前行数超过了 input_end_line，更新它
        if current_count > M.input_end_line + 1 then
          M.input_end_line = current_count - 1
        end
      end
    end,
  })

  -- 正常模式下文本变化时保存编辑的消息（用于检测换行等操作）
  -- 处理用户在普通模式下对消息内容进行换行或合并的情况
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    buffer = M.buffers.main,
    callback = function()
      if not is_win_valid(M.windows.main) or not is_buf_valid(M.buffers.main) then
        return
      end

      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1

      -- 检查是否在输入区域（输入区域不应触发消息保存）
      if M.input_start_line and cur_line >= M.input_start_line then
        return -- 在输入区域，直接返回
      end

      -- 检查缓冲区行数变化
      local current_count = vim.api.nvim_buf_line_count(M.buffers.main)
      if M._last_buffer_line_count and current_count ~= M._last_buffer_line_count then
        -- 行数发生变化，检查是否在消息编辑区域
        if M._line_to_message then
          -- 检查当前行和上一行是否是消息内容
          if M._line_to_message[cur_line] or M._line_to_message[cur_line - 1] then
            -- 保存编辑的内容
            if M._line_to_message[cur_line] then
              M._save_edited_line(cur_line)
            elseif M._line_to_message[cur_line - 1] then
              M._save_edited_line(cur_line - 1)
            end
          end
        end
        M._last_buffer_line_count = current_count -- 更新行数记录
      end
    end,
  })

  -- 离开编辑行时保存（InsertLeave 事件）
  -- 用户退出插入模式时，自动保存对消息内容的修改
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = M.buffers.main,
    callback = function()
      if not is_win_valid(M.windows.main) or not is_buf_valid(M.buffers.main) then
        return
      end
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1

      -- 检查是否在输入区域（输入区域不应触发"消息修改已保存"）
      if M.input_start_line and cur_line >= M.input_start_line then
        return -- 在输入区域，直接返回，不保存
      end

      -- 如果在可编辑的消息内容行，保存编辑的内容
      if M._line_to_message and M._line_to_message[cur_line] then
        M._save_edited_line(cur_line)
      end
    end,
  })
end

--- 保存编辑的消息行（支持多行）
-- 委托 backend.save_buffer_edit 接口处理缓冲区读取和消息保存
-- @param line_num 编辑的行号（0-indexed）
function M._save_edited_line(line_num)
  if not is_buf_valid(M.buffers.main) then
    return
  end

  local msg_info = M._line_to_message and M._line_to_message[line_num]
  if not msg_info then
    return
  end

  local session = backend.sessions[msg_info.session_id]
  if not session then
    return
  end

  -- 使用 backend 接口查找消息范围
  local info = backend.find_message_at_line(session, M.buffers.main, line_num)
  if not info then
    vim.notify("[NeoAI] 未找到对应的消息", vim.log.levels.WARN)
    return
  end

  -- 调用 backend 保存接口
  local success, msg =
    backend.save_buffer_edit(msg_info.session_id, msg_info.message_id, M.buffers.main, info.start_line, info.end_line)

  if success then
    -- 只有在实际修改成功时才显示通知（避免空操作或无修改时的干扰）
    vim.notify("[NeoAI] 消息修改已保存: " .. msg, vim.log.levels.INFO)
  elseif msg and msg ~= "内容未修改" then
    -- 只在非"未修改"的错误时显示警告
    vim.notify("[NeoAI] 消息修改保存失败: " .. msg, vim.log.levels.WARN)
  end
  -- 如果 msg == "内容未修改"，不显示任何通知，静默忽略
end

--- 更新输入提示虚拟文本
-- 当输入行为空时显示"输入消息: "提示，有内容时隐藏
function M._update_input_prompt()
  if not M.input_start_line or not is_buf_valid(M.buffers.main) then
    return
  end

  local ns_id = vim.api.nvim_create_namespace("NeoAIInputPrompt")
  -- 先清除旧的提示（避免重复叠加）
  vim.api.nvim_buf_clear_namespace(M.buffers.main, ns_id, M.input_start_line, M.input_start_line + 1)

  local current_text = vim.api.nvim_buf_get_lines(M.buffers.main, M.input_start_line, M.input_start_line + 1, false)[1]
    or ""

  -- 仅在输入行为空时显示提示
  if vim.trim(current_text) == "" then
    vim.api.nvim_buf_set_extmark(M.buffers.main, ns_id, M.input_start_line, 0, {
      virt_text = { { "输入消息: ", "Comment" } },
      virt_text_pos = "overlay",
    })
  end
end

--- 保存并发送消息
-- 从输入区域读取用户输入的内容，发送到后端 AI，并清空输入区域
function M.save_and_send()
  if not M.input_start_line or not is_buf_valid(M.buffers.main) then
    vim.notify("[NeoAI] 错误: 缓冲区无效", vim.log.levels.WARN)
    return
  end
  if not backend.current_session then
    vim.notify("[NeoAI] 错误: 没有活跃的会话", vim.log.levels.WARN)
    return
  end

  -- 获取输入区域的所有行（支持多行输入）
  local current_count = vim.api.nvim_buf_line_count(M.buffers.main)
  local end_line = M.input_end_line or M.input_start_line
  -- 确保 end_line 不超出缓冲区
  end_line = math.min(end_line, current_count - 1)

  if end_line < M.input_start_line then
    end_line = M.input_start_line
  end

  local lines = vim.api.nvim_buf_get_lines(M.buffers.main, M.input_start_line, end_line + 1, false)
  if #lines == 0 then
    vim.notify("[NeoAI] 警告: 无法读取输入内容", vim.log.levels.WARN)
    return
  end

  -- 连接多行内容为单个字符串
  local text = table.concat(lines, "\n")
  text = vim.trim(text)
  if text == "" then
    vim.notify("[NeoAI] 警告: 输入内容为空", vim.log.levels.WARN)
    return
  end

  -- 清空输入区域（重置为单行空行）
  local input_line_count = end_line - M.input_start_line + 1
  vim.api.nvim_buf_set_lines(M.buffers.main, M.input_start_line, M.input_start_line + input_line_count, false, { "" })
  M.input_end_line = M.input_start_line -- 重置结束行

  -- 调用后端发送消息
  if backend.send_message(text) then
    -- vim.notify("[NeoAI] 消息已发送", vim.log.levels.INFO)
  else
    vim.notify("[NeoAI] 错误: 消息发送失败", vim.log.levels.ERROR)
  end

  -- 延迟更新显示，确保消息已添加到后端
  vim.defer_fn(function()
    M.update_display()
  end, 100)
end

--- 光标定位到输入消息行
-- 将光标移动到缓冲区底部的输入区域，方便用户继续输入
function M.focus_input_line()
  if M.input_start_line and is_buf_valid(M.buffers.main) and is_win_valid(M.windows.main) then
    -- 确保输入区域只有 1 行高
    if M.input_end_line and M.input_end_line > M.input_start_line then
      M.input_end_line = M.input_start_line
    end
    vim.api.nvim_win_set_cursor(M.windows.main, { M.input_start_line + 1, 0 }) -- +1 因为 cursor 是 1-indexed
  end
end

-- ── 快捷键管理 ─────────────────────────────────────────────────────────────

--- 清理快捷键
-- 删除主缓冲区所有模式下的自定义快捷键，避免与其他插件冲突
function M.clear_keymaps()
  if not is_buf_valid(M.buffers.main) then
    return
  end

  -- 遍历所有模式（普通、插入、可视、选择等）
  for _, mode in ipairs({ "n", "i", "v", "x", "s", "o" }) do
    local kms = vim.api.nvim_buf_get_keymap(M.buffers.main, mode)
    for _, km in ipairs(kms) do
      vim.api.nvim_buf_del_keymap(M.buffers.main, mode, km.lhs)
    end
  end
end

--- 设置快捷键
-- 为主缓冲区绑定所有自定义快捷键，包括消息编辑、会话管理、发送等功能
function M.setup_keymaps()
  if not is_win_valid(M.windows.main) then
    return
  end

  local buf = M.buffers.main

  -- 辅助函数：快速绑定缓冲区快捷键
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, noremap = true })
  end

  -- 普通模式：e 键进入编辑模式
  map("n", "e", function()
    if is_win_valid(M.windows.main) then
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1
      -- 检查是否在可编辑行（通过 _line_to_message 映射表判断）
      if M._line_to_message and M._line_to_message[cur_line] then
        vim.cmd("startinsert") -- 进入插入模式
      else
        vim.notify("[NeoAI] 此行不可编辑")
      end
    end
  end, "编辑消息")

  -- 普通模式：r 键切换推理内容显示
  -- 思考中：打开/关闭浮动窗口
  -- 思考完成后：展开/折叠文本
  map("n", "r", function()
    if is_win_valid(M.windows.main) then
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1
      -- 检查当前行是否属于某个有推理内容的消息
      local session = backend.current_session and backend.sessions[backend.current_session]
      if session and session.messages then
        local current_line = 0
        for _, msg in ipairs(session.messages) do
          -- 标题行
          current_line = current_line + 1
          -- 推理内容行
          if msg.metadata and msg.metadata.has_reasoning and msg.metadata.reasoning_content
            and M.config.llm.show_reasoning then
            -- 如果光标在推理内容标题行上
            if cur_line == current_line then
              local is_complete = not msg.pending
              
              if is_complete then
                -- 思考完成后：切换折叠状态
                M.toggle_reasoning_fold(msg.id)
              else
                -- 思考中：切换浮动窗口
                if M._reasoning_float_wins[msg.id] then
                  M.close_reasoning_float(msg.id)
                else
                  M.create_reasoning_float_window(
                    msg.id, 
                    msg.metadata.reasoning_content, 
                    M.windows.main, 
                    current_line
                  )
                end
              end
              
              -- 刷新显示
              M.update_display_debounced.message()
              return
            end
            current_line = current_line + 1
          else
            -- 跳过内容和分隔行
            local content_lines = wrap_message_content(msg.content or "", calculate_text_width() - 4)
            current_line = current_line + #content_lines
          end
          -- 消息间的空行
          current_line = current_line + 1
        end
        vim.notify("[NeoAI] 将光标移到推理内容标题行上以切换显示")
      end
    end
  end, "切换推理内容显示")

  -- 普通模式：s 键导出当前会话
  map("n", "s", function()
    if backend.current_session then
      backend.export_session(backend.current_session)
      vim.notify("[NeoAI] 会话已导出")
    end
  end, "导出会话")

  -- 配置的快捷键（从用户配置中读取）
  map("n", M.config.keymaps.open, "<cmd>NeoAIOpen<CR>", "打开聊天")
  map("n", M.config.keymaps.close, M.close, "关闭聊天")
  map("n", M.config.keymaps.new, "<cmd>NeoAINew<CR>", "新建会话")
  map("n", "q", M.close, "关闭聊天")
  map("n", "<Esc>", M.close, "关闭聊天")

  -- 正常模式下回车：智能判断是发送消息还是进入编辑模式
  map("n", M.config.keymaps.normal_mode_send, function()
    if is_win_valid(M.windows.main) then
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1
      local input_end = M.input_end_line or M.input_start_line
      -- 检查是否在输入区域（缓冲区底部）
      if M.input_start_line and cur_line >= M.input_start_line and cur_line <= input_end then
        -- 在输入区域，发送消息
        M.save_and_send()
      elseif M._line_to_message and M._line_to_message[cur_line] then
        -- 在可编辑的消息行，进入插入模式
        vim.cmd("startinsert")
      end
    end
  end, "发送消息或编辑")

  -- 插入模式下：Ctrl+s 发送消息
  map("i", M.config.keymaps.insert_mode_send, M.save_and_send, "发送消息")
  map("i", "<C-c>", M.close, "关闭聊天")

  -- 插入模式下回车：正常换行（不发送消息）
  map("i", "<CR>", function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
  end, "换行")
end

-- ── 窗口控制 ──────────────────────────────────────────────────────────────

--- 关闭所有窗口
-- 清理所有 NeoAI 相关的窗口、缓冲区、定时器、自动命令，并恢复编辑器原始状态
function M.close()
  -- 同步所有会话数据到持久化存储
  if backend.sessions then
    backend.sync_data()
  end

  -- 关闭所有推理浮动窗口
  for msg_id, _ in pairs(M._reasoning_float_wins) do
    M.close_reasoning_float(msg_id)
  end

  -- 关闭所有窗口（主窗口、树视图窗口等）
  for _, win in pairs(M.windows) do
    if is_win_valid(win) then
      safe_win_call(function()
        -- 标签模式下，关闭整个标签页而不是单个窗口
        if M.current_mode == M.ui_modes.TAB then
          local tab = vim.api.nvim_win_get_tabpage(win)
          if tab ~= vim.api.nvim_get_current_tabpage() then
            pcall(vim.api.nvim_command, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
          else
            pcall(vim.api.nvim_command, "tabclose")
          end
        else
          vim.api.nvim_win_close(win, true)
        end
      end)
    end
  end

  -- 删除所有主缓冲区
  for _, buf in pairs(M.buffers) do
    if is_buf_valid(buf) then
      pcall(function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end)
    end
  end

  -- 删除所有树视图缓冲区
  for _, buf in pairs(M.tree_buffers) do
    if is_buf_valid(buf) then
      pcall(function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end)
    end
  end

  -- 停止所有防抖定时器（防止后台回调引发错误）
  for _, timer in pairs(M._debounce_timers) do
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
  end
  M._debounce_timers = {}

  -- 清理自动命令组（避免内存泄漏）
  pcall(vim.api.nvim_del_augroup_by_name, "NeoAIInput")
  pcall(vim.api.nvim_del_augroup_by_name, "NeoAITreeCursor")
  pcall(vim.api.nvim_del_augroup_by_name, "NeoAIResize")

  -- 重置所有状态变量
  M.windows = {}
  M.buffers = {}
  M.tree_windows = {}
  M.tree_buffers = {}
  M.is_open = false
  M.input_start_line = nil
  M.input_end_line = nil
  M._resize_pending = false
  M._line_to_message = nil
  M._last_buffer_line_count = nil
  M._next_line_num = nil
  M._reasoning_line_for_msg = nil
end

--- 切换UI模式
-- 关闭当前窗口，然后以新模式重新打开
-- @param mode UI模式 (float/split/tab)
function M.switch_mode(mode)
  -- 如果当前有窗口打开，先关闭
  if M.is_open then
    M.close()
  end

  -- 根据新模式打开对应类型的窗口
  if mode == M.ui_modes.FLOAT then
    M.open_float()
  elseif mode == M.ui_modes.SPLIT then
    M.open_split()
  elseif mode == M.ui_modes.TAB then
    M.open_tab()
  end

  vim.notify("切换到 " .. mode .. " 模式")
end

--- 切换树视图显示
-- 显示/隐藏会话列表的树视图窗口，需要重新创建窗口才能生效
function M.toggle_tree_view()
  M._showing_tree = not M._showing_tree -- 切换状态
  if M.is_open then
    local mode = M.current_mode
    M.close() -- 关闭当前窗口

    -- 以原模式重新打开
    if mode == M.ui_modes.FLOAT then
      M.open_float()
    elseif mode == M.ui_modes.SPLIT then
      M.open_split()
    elseif mode == M.ui_modes.TAB then
      M.open_tab()
    end

    vim.notify("[NeoAI] 树视图已" .. (M._showing_tree and " 显示" or "隐藏"))
  else
    vim.notify("[NeoAI] 树视图将在下次打开聊天时" .. (M._showing_tree and "显示" or "隐藏"))
  end
end

-- ── 模块初始化 ──────────────────────────────────────────────────────────────

--- 模块初始化
-- 合并用户配置，注册后端事件监听器，设置窗口生命周期相关的自动命令
-- @param user_config 用户配置表
function M.setup(user_config)
  -- 合并默认配置和用户配置
  M.config = vim.tbl_deep_extend("force", config.defaults, user_config or {})

  -- ── 后端事件监听器（使用防抖处理） ──

  -- 消息添加事件：更新显示并定位光标到输入行
  backend.on("message_added", function(data)
    M.update_display_debounced.message() -- 防抖更新显示
    -- 每轮对话结束后自动定位光标到输入行
    vim.defer_fn(function()
      M.focus_input_line()
    end, 50)
    -- 自动同步数据到持久化存储
    backend.debounce_sync(data.session_id)
  end)

  -- 消息编辑事件：更新行映射，但不刷新显示（避免覆盖用户编辑的内容）
  backend.on("message_edited", function(data)
    -- 编辑事件由前端 _save_edited_line 触发，后端已保存数据
    -- 不需要 update_display，否则会覆盖用户刚编辑的内容
    -- 仅更新行映射以保持一致性
    local session = backend.current_session and backend.sessions[backend.current_session]
    if session and M.buffers.main then
      M._setup_editability(M.buffers.main, session)
      M._last_buffer_line_count = vim.api.nvim_buf_line_count(M.buffers.main)
    end
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)

  -- 消息删除事件：刷新显示
  backend.on("message_deleted", function(data)
    M.update_display_debounced.delete()
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)

  -- AI 回复完成事件：刷新显示并定位光标
  backend.on("ai_replied", function(data)
    -- 思考完成时：关闭推理浮动窗口，并将内容设为折叠状态
    if data.message and data.message.id then
      local msg_id = data.message.id
      -- 关闭浮动窗口
      M.close_reasoning_float(msg_id)
      M._last_reasoning_len_for_float = 0
      M._no_reasoning_update_count = 0
      -- 将推理内容设为折叠状态（思考完成后默认折叠）
      if data.message.metadata and data.message.metadata.has_reasoning then
        M._reasoning_fold_state[msg_id] = true
      end
    end
    M.update_display_debounced.reply()
    -- AI回复完成后，异步等待渲染完成再定位光标
    vim.defer_fn(function()
      if M.update_display_debounced.reply then
        -- 等待防抖更新完成
        vim.defer_fn(function()
          M.focus_input_line()
        end, 60)
      end
    end, 10)
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)

  -- AI 流式更新事件：实时更新显示，光标自动跟随
  backend.on("ai_stream_update", function(data)
    -- 立即更新显示，不使用防抖（需要实时显示流式内容）
    M.update_display()
    
    -- 检测推理内容是否已停止更新（思考完成但回复还在继续）
    -- 策略：记录每次更新时是否有推理内容，如果连续多次没有，说明思考已完成
    vim.defer_fn(function()
      if data.message and data.message.id and data.message.metadata then
        local msg_id = data.message.id
        local float_win = M._reasoning_float_wins[msg_id]
        
        -- 如果浮动窗口存在，检查推理内容是否停止
        if float_win and vim.api.nvim_win_is_valid(float_win) then
          local current_reasoning = data.message.metadata.reasoning_content or ""
          local current_len = #current_reasoning
          local prev_len = M._last_reasoning_len_for_float or 0
          
          -- 如果推理内容长度没有变化，增加计数
          if current_len > 0 and current_len == prev_len then
            M._no_reasoning_update_count = (M._no_reasoning_update_count or 0) + 1
            
            -- 如果连续 3 次没有更新，关闭浮动窗口
            if M._no_reasoning_update_count >= 3 then
              M.close_reasoning_float(msg_id)
              M._no_reasoning_update_count = 0
            end
          else
            -- 有更新或刚开始，重置计数
            M._no_reasoning_update_count = 0
          end
          
          M._last_reasoning_len_for_float = current_len
        end
      end
    end, 150)
    
    -- 光标跟随到输入行
    vim.defer_fn(function()
      M.focus_input_line()
    end, 30)
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)

  -- AI 推理内容更新事件（流式思考过程）：实时更新推理内容显示
  backend.on("ai_reasoning_update", function(data)
    -- 重置长度跟踪和计数（思考还在进行中）
    M._last_reasoning_len_for_float = 0
    M._no_reasoning_update_count = 0
    
    -- 立即更新显示以更新推理内容虚拟文本
    if M.config.llm.show_reasoning and is_buf_valid(M.buffers.main) then
      M.update_display()
      
      -- 滚动浮动窗口到底部
      vim.defer_fn(function()
        local msg = data.message
        if msg and msg.id then
          local float_win = M._reasoning_float_wins[msg.id]
          if float_win and vim.api.nvim_win_is_valid(float_win) then
            local buf = vim.api.nvim_win_get_buf(float_win)
            local line_count = vim.api.nvim_buf_line_count(buf)
            -- 将光标移动到底部并滚动
            vim.api.nvim_win_set_cursor(float_win, { line_count, 0 })
            vim.api.nvim_win_call(float_win, function()
              vim.cmd("normal! Gzb")
            end)
          end
        end
      end, 50)
    end
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)

  -- 窗口大小变化时自动更新推理内容宽度
  vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      if M.is_open and is_buf_valid(M.buffers.main) then
        -- 清理所有推理状态，下次更新时会重新计算宽度
        M.cleanup_reason_state()
      end
    end
  })

  -- 响应接收事件：刷新显示并定位光标
  backend.on("response_received", function(data)
    M.update_display_debounced.response()
    -- 响应接收后，异步等待渲染完成再定位光标
    vim.defer_fn(function()
      if M.update_display_debounced.response then
        -- 等待防抖更新完成
        vim.defer_fn(function()
          M.focus_input_line()
        end, 60)
      end
    end, 10)
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)

  -- 会话创建事件：刷新显示
  backend.on("session_created", function(data)
    M.update_display_debounced.session()
    -- 自动同步数据
    backend.debounce_sync(data.id)
  end)

  -- 数据同步事件：预留回调（可用于状态栏提示等）
  backend.on("data_synced", function(_)
    -- 数据已同步，可以在这里添加UI反馈（如状态栏提示）
    -- 暂时不需要额外操作，仅作日志记录
    -- vim.notify("[NeoAI] 数据已同步", vim.log.levels.DEBUG)
  end)

  -- 轮次删除事件：重新渲染树视图
  backend.on("turn_deleted", function(data)
    if M.should_show_tree() and is_buf_valid(M.tree_buffers.main) then
      vim.schedule(function()
        M.render_session_tree()
        -- 重置光标追踪状态（缓冲区内容已重建）
        if is_win_valid(M.windows.tree) then
          vim.api.nvim_win_set_cursor(M.windows.tree, { 1, 0 })
        end
        M.setup_tree_cursor_autocmd()
      end)
    end
    M.update_display_debounced.turn()
    backend.debounce_sync(data.session_id)
  end)

  -- 分支删除事件：重新渲染树视图
  backend.on("branch_deleted", function(data)
    if M.should_show_tree() and is_buf_valid(M.tree_buffers.main) then
      vim.schedule(function()
        M.render_session_tree()
        -- 重置光标追踪状态（缓冲区内容已重建）
        if is_win_valid(M.windows.tree) then
          vim.api.nvim_win_set_cursor(M.windows.tree, { 1, 0 })
        end
        M.setup_tree_cursor_autocmd()
      end)
    end
    M.update_display_debounced.turn()
    backend.debounce_sync(data.session_id or M.current_session)

    -- 提示：数据已持久化
    vim.notify(
      "[NeoAI] 分支已删除并同步到 "
        .. (backend.config_file and backend.config_file:match("([^/]+)$") or "sessions.json"),
      vim.log.levels.INFO
    )
  end)

  -- ── Neovim 自动命令 ──

  -- 窗口大小调整事件：防抖后重新计算窗口大小
  local group = vim.api.nvim_create_augroup("NeoAIResize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    pattern = "*",
    callback = function()
      M.schedule_resize() -- 防抖调整窗口大小
    end,
  })

  -- 窗口大小调整事件：重新渲染整个界面（tree 和 chat）
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    pattern = "*",
    callback = function()
      if M.is_open then
        -- 防抖后重新渲染整个界面（包括聊天和树视图）
        vim.defer_fn(function()
          if not M.is_open then
            return
          end

          -- 重新渲染聊天界面
          if is_buf_valid(M.buffers.main) then
            M._render_chat_interface()
          end

          -- 重新渲染树视图
          if M.should_show_tree() and is_buf_valid(M.tree_buffers.main) then
            M._render_tree_interface()
          end
        end, 100)
      end
    end,
  })

  -- 窗口关闭事件：清理无效的窗口/缓冲区引用
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = "*",
    callback = function()
      M.cleanup_windows()
    end,
  })

  -- Neovim 退出前事件：自动同步所有会话数据到持久化存储
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    pattern = "*",
    callback = function()
      if backend.sessions then
        backend.sync_data() -- 确保数据不丢失
      end
    end,
  })
end

return M
