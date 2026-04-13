local M = {}
-- 导入依赖
local backend = require("NeoAI.backend")
local config = require("NeoAI.config")

-- ── 模块常量与状态 ───────────────────────────────────────────────────────────

-- UI模式常量
M.ui_modes = { FLOAT = "float", SPLIT = "split", TAB = "tab" }
M.current_mode = M.ui_modes.FLOAT -- 当前UI模式

-- 窗口和缓冲区管理
M.windows = {} -- 主窗口表
M.buffers = {} -- 主缓冲区表
M.tree_windows = {} -- 树视图窗口表
M.tree_buffers = {} -- 树视图缓冲区表
-- 状态标志
M.is_open = false -- 是否已打开
M.config = nil -- 配置对象
M.original_tabline = nil -- 原始标签栏设置
M.original_showtabline = nil -- 原始标签栏显示设置
M.input_start_line = nil -- 输入起始行
M.input_end_line = nil -- 输入结束行
M.showing_tree = true -- 是否显示树视图

-- 防抖和调整状态
M._debounce_timers = {} -- 防抖定时器表
M._resize_pending = false -- 窗口调整挂起标志

-- 窗口大小限制配置
M.WINDOW_LIMITS = {
  float = { min_width = 50, min_height = 8, max_width_ratio = 0.85, max_height_ratio = 0.85 },
  split = { min_width = 40, max_width_ratio = 0.6, min_height = 8, max_height_ratio = 0.95 },
  tab = { min_width = 60, min_height = 10 },
  tree = { min_width = 40, max_width_ratio = 0.35 },
}

-- 边框字符定义
local BORDER_CHARS = {
  rounded = {
    top_left = "╭",
    top_right = "╮",
    bottom_left = "╰",
    bottom_right = "╯",
    vertical = "│",
    horizontal = "─",
  },
  single = {
    top_left = "┌",
    top_right = "┐",
    bottom_left = "└",
    bottom_right = "┘",
    vertical = "│",
    horizontal = "─",
  },
  double = {
    top_left = "╔",
    top_right = "╗",
    bottom_left = "╚",
    bottom_right = "╝",
    vertical = "║",
    horizontal = "═",
  },
  solid = {
    top_left = "┏",
    top_right = "┓",
    bottom_left = "┗",
    bottom_right = "┛",
    vertical = "┃",
    horizontal = "━",
  },
  none = { top_left = "", top_right = "", bottom_left = "", bottom_right = "", vertical = "", horizontal = "" },
}

-- 分隔符字符定义
local SEPARATOR_CHARS = { single = "─", double = "═", solid = "━", dotted = "┈", dashed = "┄" }

-- ── 工具函数集 ───────────────────────────────────────────────────────────────

--- 防抖函数：延迟执行，在指定时间内重复调用会重新计时
-- @param fn 要执行的函数
-- @param delay_ms 延迟毫秒数
-- @return 防抖包装函数
local function debounce(fn, delay_ms)
  return function(...)
    local args = { ... }
    local timer_name = tostring(fn):match("function:%s*(.+)") or tostring(fn)

    -- 取消现有定时器
    local old_timer = M._debounce_timers[timer_name]
    if old_timer then
      old_timer:stop()
      if not old_timer:is_closing() then
        old_timer:close()
      end
    end

    -- 启动新定时器
    local timer = assert(vim.loop.new_timer())
    M._debounce_timers[timer_name] = timer
    timer:start(delay_ms, 0, function()
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
end

--- 将值限制在最小和最大值之间
-- @param val 原始值
-- @param min_val 最小值
-- @param max_val 最大值
-- @return 钳制后的值
local function clamp(val, min_val, max_val)
  return math.max(min_val, math.min(val, max_val))
end

--- 检查窗口是否有效
-- @param win 窗口ID
-- @return boolean 是否有效
local function is_win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

--- 检查缓冲区是否有效
-- @param buf 缓冲区ID
-- @return boolean 是否有效
local function is_buf_valid(buf)
  return type(buf) == "number" and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

--- 安全调用窗口相关函数
-- @param fn 要调用的函数
-- @return boolean 是否成功, 结果
local function safe_win_call(fn)
  return pcall(fn)
end

--- 文本换行函数
-- @param text 原始文本
-- @param max_width 最大宽度
-- @return table 换行后的文本数组
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

--- 将值限制在最小和最大值之间
local function clamp(val, min_val, max_val)
  return math.max(min_val, math.min(val, max_val))
end

--- 检查窗口是否有效
local function is_win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

--- 检查缓冲区是否有效
local function is_buf_valid(buf)
  return type(buf) == "number" and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

--- 安全调用窗口相关函数
local function safe_win_call(fn)
  return pcall(fn)
end

--- 文本换行函数
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

--- 截断内容到最大长度
local function truncate_content(content, max_len)
  if #content <= max_len then
    return content
  end
  return content:sub(1, max_len) .. "..."
end

--- 消息内容换行
local function wrap_message_content(content, max_width)
  local result = {}
  for line in content:gmatch("[^\r\n]+") do
    for _, wl in ipairs(wrap_text(line, max_width)) do
      table.insert(result, wl)
    end
  end
  return #result > 0 and result or { "" }
end

--- 获取边框字符
function M.get_border_chars()
  return BORDER_CHARS[M.config.ui.info_border] or BORDER_CHARS.single
end

--- 获取分隔符字符
function M.get_separator_char()
  return SEPARATOR_CHARS[M.config.ui.input_separator] or "─"
end

--- 计算字符串的显示宽度（考虑中文字符）
-- @param str 输入字符串
-- @return integer 显示宽度
local function display_width(str)
  if not str or str == "" then
    return 0
  end
  -- 替换中文字符为两个宽度
  local chinese_chars = str:gsub("[%z\1-\127\194-\244][\128-\191]*", function(ch)
    -- 简单判断：如果字符的UTF-8编码范围是中文常见范围，认 为宽度为2
    if #ch >= 3 then
      return "aa" -- 用两个字符表示宽度
    else
      return ch
    end
  end)
  return #chinese_chars
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

--- 计划调整窗口大小
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

--- 防抖后的更新显示函数
M.update_display_debounced = debounce(function()
  M.update_display()
end, 50)

--- 调整窗口大小
-- @param content_width 内容宽度
-- @param content_height 内容高度
function M.adjust_window_size(content_width, content_height)
  if not is_win_valid(M.windows.main) then
    return
  end

  local mode = M.current_mode
  local editor_w = vim.o.columns
  local editor_h = vim.o.lines

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
  elseif mode == M.ui_modes.SPLIT then
    local w = clamp(content_width + 6, 40, math.min(math.floor(editor_w * 0.6), 120))
    w = M.apply_size_limits("split", w, editor_h)

    safe_win_call(function()
      vim.api.nvim_win_set_width(M.windows.main, w)
    end)
  end
  -- 标签模式由Neovim自动管理
end

--- 调整树窗口大小（修复宽度不够问题）
function M.adjust_tree_window_size()
  if not is_win_valid(M.windows.tree) or not is_buf_valid(M.tree_buffers.main) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(M.tree_buffers.main, 0, -1, false)
  local max_w = 0

  for _, line in ipairs(lines) do
    local width = display_width(line)
    max_w = math.max(max_w, width)
  end

  -- 增加边距确保边框完整显示
  local target = math.min(max_w + 8, 60) -- 增加边距从4到8
  target = math.max(target, M.WINDOW_LIMITS.tree.min_width)

  if M.current_mode == M.ui_modes.FLOAT and is_win_valid(M.windows.main) then
    local main_w = vim.api.nvim_win_get_width(M.windows.main)
    target = math.min(target, math.floor(main_w * 0.35))
  end

  -- 确保窗口不会超出屏幕
  local editor_w = vim.o.columns
  if target > editor_w * 0.9 then
    target = math.floor(editor_w * 0.9)
  end

  safe_win_call(function()
    vim.api.nvim_win_set_width(M.windows.tree, target)
  end)
end

-- ── 窗口策略函数 ─────────────────────────────────────────────────────────────

--- 获取窗口策略函数
-- @param mode 窗口模式
-- @return function 窗口策略函数
function M.get_window_strategy(mode)
  local strategies = {
    [M.ui_modes.FLOAT] = function()
      local width = math.min(M.config.ui.width, vim.o.columns - 10)
      local height = math.min(M.config.ui.height, vim.o.lines - 10)
      width, height = M.apply_size_limits("float", width, height)

      local row = math.floor((vim.o.lines - height) / 2)
      local col = math.floor((vim.o.columns - width) / 2)
      row, col, width, height = M.validate_window_position(row, col, width, height)

      return {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        border = M.config.ui.border,
        style = "minimal",
        focusable = true,
      }
    end,

    [M.ui_modes.SPLIT] = function()
      local width = math.floor(vim.o.columns * 0.4)
      local height = M.config.ui.height
      width, height = M.apply_size_limits("split", width, height)

      return {
        relative = "editor",
        width = width,
        height = height,
        row = 0,
        col = vim.o.columns - width,
        style = "minimal",
      }
    end,

    [M.ui_modes.TAB] = function()
      local width = vim.o.columns
      local height = vim.o.lines
      width, height = M.apply_size_limits("tab", width, height)
      return { width = width, height = height }
    end,

    tree = function(parent_win, width)
      width = width or 45 -- 增加默认宽度
      width = math.max(width, M.WINDOW_LIMITS.tree.min_width)

      if M.WINDOW_LIMITS.tree.max_width_ratio and parent_win and is_win_valid(parent_win) then
        local parent_width = vim.api.nvim_win_get_width(parent_win)
        width = math.min(width, math.floor(parent_width * M.WINDOW_LIMITS.tree.max_width_ratio))
      end

      -- 确保最小宽度
      width = math.max(width, 45)

      return {
        relative = "win",
        win = parent_win or M.windows.main,
        width = width,
        height = math.min(M.config.ui.height, vim.o.lines - 10),
        row = 0,
        col = 0,
        style = "minimal",
        border = M.config.ui.border,
        focusable = true,
      }
    end,
  }

  return strategies[mode]
end

--- 设置窗口
-- @param win_opts 窗口选项
function M.setup_windows(win_opts)
  M.windows.main = vim.api.nvim_open_win(M.buffers.main, true, win_opts)
  M.set_window_wrap()
  M.setup_buffers()
  M.is_open = true

  -- 异步等待渲染完成后将光标定位到输入提示行
  vim.defer_fn(function()
    if M.is_open and is_win_valid(M.windows.main) and is_buf_valid(M.buffers.main) then
      -- 确保缓冲区已渲染完成
      vim.api.nvim_buf_call(M.buffers.main, function()
        vim.cmd("redraw")
      end)
      -- 将光标定位到输入提示行
      M.focus_input_line()
      -- 确保输入行可编辑
      vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main })
      vim.api.nvim_set_option_value("readonly", false, { buf = M.buffers.main })
      -- 进入插入模式准备输入
      vim.cmd("startinsert")
    end
  end, 10)
end

--- 打开树窗口
-- @param parent_win 父窗口
-- @param width 宽度
function M.open_tree_window(parent_win, width)
  local strategy = M.get_window_strategy("tree")
  local opts = strategy(parent_win, width)

  if not is_buf_valid(M.tree_buffers.main) then
    M.create_tree_buffers()
  end

  M.windows.tree = vim.api.nvim_open_win(M.tree_buffers.main, false, opts)
  vim.api.nvim_set_option_value("winfixwidth", true, { win = M.windows.tree })

  if is_win_valid(M.windows.tree) then
    vim.api.nvim_set_option_value("wrap", true, { win = M.windows.tree })
    vim.api.nvim_set_option_value("linebreak", true, { win = M.windows.tree })
  end

  -- 创建后立即调整大小
  vim.defer_fn(function()
    M.adjust_tree_window_size()
  end, 10)
end

-- ── 标签页标签管理 ─────────────────────────────────────────────────────────

--- 获取标签页标签
-- @return string 标签页标签字符串
function M.get_tab_label()
  local label = ""
  for n, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    label = label .. (tabpage == vim.api.nvim_get_current_tabpage() and "%#TabLineSel#" or "%#TabLine#")
    label = label .. "%" .. n .. "T "

    local wins = vim.api.nvim_tabpage_list_wins(tabpage)
    local has_neoai = false

    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_get_name(buf):match("^NeoAI") or vim.api.nvim_buf_get_name(buf):match("NeoAI://") then
        has_neoai = true
        break
      end
    end

    if has_neoai then
      label = label .. "🤖 NeoAI"
    else
      local buflist = vim.fn.tabpagebuflist(tabpage)
      if buflist and #buflist > 0 then
        local bufname = vim.fn.bufname(buflist[1])
        label = label .. (bufname and bufname ~= "" and vim.fn.fnamemodify(bufname, ":t") or "[No Name]")
      end
    end
    label = label .. " "
  end

  return label .. "%#TabLine#%T"
end

-- ── 缓冲区管理 ──────────────────────────────────────────────────────────────

--- 创建主缓冲区
function M.create_buffers()
  M.buffers.main = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(M.buffers.main, 0, -1, false, {
    "",
    "  欢迎使用 NeoAI!",
    "  输入消息开始对话",
    "",
  })
end

--- 创建树视图缓冲区
function M.create_tree_buffers()
  M.tree_buffers.main = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(M.tree_buffers.main, "NeoAI-Tree")
  vim.api.nvim_set_option_value("filetype", "NeoAITree", { buf = M.tree_buffers.main })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = M.tree_buffers.main })
  M.render_session_tree()
  M.setup_tree_keymaps()
end

--- 设置缓冲区属性
function M.setup_buffers()
  vim.api.nvim_buf_set_name(M.buffers.main, "NeoAI")
  vim.api.nvim_set_option_value("filetype", "NeoAI", { buf = M.buffers.main })
  vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.buffers.main })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = M.buffers.main })
  vim.api.nvim_set_option_value("swapfile", false, { buf = M.buffers.main })
  M.setup_keymaps()
  M.setup_input_handling()
  M.update_display()
end

-- ── 树视图管理 ─────────────────────────────────────────────────────────────

--- 将消息按对话轮次分组（仅用于树视图）
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

--- 渲染会话树（修复宽度不够问题）
function M.render_session_tree()
  local buf = M.tree_buffers.main
  if not is_buf_valid(buf) then
    return
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

  local lines = {}
  local ns_id = vim.api.nvim_create_namespace("NeoAITree")
  M.tree_buffers.session_positions = {}

  -- 标题（缩短以适配更小宽度）
  local title = "📂 Chat History"
  local title_width = display_width(title)
  local separator_len = 30
  table.insert(lines, "╭─ " .. title .. " ─" .. string.rep("─", separator_len) .. "╮")

  if backend.sessions and #backend.sessions > 0 then
    for session_id, session in pairs(backend.sessions) do
      local is_current = (session_id == backend.current_session)
      local icon = is_current and "📁" or "📂"
      local session_info = string.format("%s %s (%d)", icon, session.name, #session.messages)
      table.insert(lines, session_info)

      local line_idx = #lines
      M.tree_buffers.session_positions[line_idx] = { type = "session", id = session_id, line = line_idx - 1 }

      M._render_session_messages(lines, session, session_id, is_current)
      table.insert(lines, "")
    end
  else
    table.insert(lines, "│")
    table.insert(lines, "│  暂无会话")
    table.insert(lines, "│")
    table.insert(lines, "│  按 <CR> 创建新会话")
    table.insert(lines, "")
  end

  -- 底部（缩短以适应更小宽度）
  local bottom_width = 50
  table.insert(lines, string.rep("─", bottom_width))
  table.insert(lines, "🔹 <CR> 选择  🔹 n 新建  🔹 q 关闭")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- 应用高亮
  for line_num, pos in pairs(M.tree_buffers.session_positions) do
    if pos.type == "session" then
      local hl = (pos.id == backend.current_session) and "Todo" or "Normal"
      vim.api.nvim_buf_add_highlight(buf, ns_id, hl, line_num - 1, 0, -1)
    end
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })

  -- 延迟调整大小，确保内容已渲染
  vim.defer_fn(function()
    M.adjust_tree_window_size()
  end, 10)
end

--- 渲染会话消息
-- @param lines 行数组
-- @param session 会话对象
-- @param session_id 会话ID
-- @param is_current 是否为当前会话
function M._render_session_messages(lines, session, session_id, is_current)
  if not session.messages or #session.messages == 0 then
    table.insert(lines, "  └─ (空会话)")
    return
  end

  local turns = group_messages_into_turns(session.messages)
  local max_turns = math.min(#turns, 8) -- 减少显示轮次以 适应更小宽度

  for i = 1, max_turns do
    local turn = turns[i]
    local is_last = (i == max_turns)
    local indent = is_last and "  └─ " or "  ├─ "

    -- 用户消息预览（缩短内容）
    local user_preview = truncate_content(turn.user_msg.content, 20)
    local user_time = os.date("%H:%M", turn.user_msg.timestamp)
    table.insert(lines, string.format("%s💬 [%s] %s", indent, user_time, user_preview))

    local line_idx = #lines
    M.tree_buffers.session_positions[line_idx] = {
      type = "conversation_turn",
      session_id = session_id,
      turn_index = i,
      user_message_index = turn.index,
      line = line_idx - 1,
    }

    -- 助手消息预览
    if turn.assistant_msg then
      local asst_preview = truncate_content(turn.assistant_msg.content, 25)
      local asst_time = os.date("%H:%M", turn.assistant_msg.timestamp)
      local reply_indent = is_last and "     " or "  │  "
      table.insert(lines, string.format("%s🤖 [%s] %s", reply_indent, asst_time, asst_preview))

      local reply_idx = #lines
      M.tree_buffers.session_positions[reply_idx] = {
        type = "assistant_reply",
        session_id = session_id,
        turn_index = i,
        line = reply_idx - 1,
      }
    end
  end

  if #turns > 8 then
    table.insert(lines, string.format("  └─ ... 还有 %d 轮 对话", #turns - 8))
  end
end

--- 设置树视图快捷键
function M.setup_tree_keymaps()
  if not is_buf_valid(M.tree_buffers.main) then
    return
  end

  local buf = M.tree_buffers.main

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = desc, noremap = true })
  end

  map("<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(M.windows.tree)
    local line = cursor[1] -- 1-indexed
    local pos = M.tree_buffers.session_positions[line]

    if pos and (pos.type == "session" or pos.type == "conversation_turn" or pos.type == "assistant_reply") then
      local sid = pos.type == "session" and pos.id or pos.session_id
      -- 同步当前会话数据
      backend.sync_data(backend.current_session)
      
      backend.current_session = sid
      local session = backend.sessions[sid]
      vim.notify("[NeoAI] 切换到会话: " .. (session and session.name or sid))
      M.open_chat_after_tree_selection()
    else
      backend.new_session("会话 " .. (#backend.sessions + 1))
      vim.notify("[NeoAI] 新会话已创建")
      M.open_chat_after_tree_selection()
    end
  end, "选择会话")

  map("n", function()
    backend.new_session("会话 " .. (#backend.sessions + 1))
    vim.notify("[NeoAI] 新会话已创建")
    M.render_session_tree()
  end, "新建会话")

  map("q", M.close, "关闭")
  map("<Esc>", M.close, "关闭")

  map("r", function()
    M.render_session_tree()
    vim.notify("[NeoAI] 已刷新")
  end, "刷新树")
end

-- ── 会话管理 ───────────────────────────────────────────────────────────────

--- 添加对话消息到缓冲区（简化函数）
-- @param role 角色 (user/assistant/system)
-- @param content 消息内容
function M.add_message(role, content)
  if not is_buf_valid(M.buffers.main) then
    return
  end

  local session = backend.current_session and backend.sessions[backend.current_session]
  if not session then
    vim.notify("[NeoAI] 错误: 没有活跃的会话", vim.log.levels.WARN)
    return
  end

  -- 创建消息对象
  local msg = {
    id = vim.uv.hrtime(),
    role = role,
    content = content,
    timestamp = os.time(),
  }

  -- 添加到会话
  table.insert(session.messages, msg)
  
  -- 更新显示
  M.update_display()
end

--- 更新主显示
function M.update_display()
  local buf = M.buffers.main
  if not is_buf_valid(buf) then
    return
  end

  -- 保存光标位置
  local save_cursor = is_win_valid(M.windows.main) and vim.api.nvim_win_get_cursor(M.windows.main) or nil

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

  -- 清除旧的虚拟文本和高亮
  local ns_virtual_text = vim.api.nvim_create_namespace("NeoAIVirtualText")
  local ns_highlight = vim.api.nvim_create_namespace("NeoAIHighlight")
  vim.api.nvim_buf_clear_namespace(buf, ns_virtual_text, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_highlight, 0, -1)

  local lines = {}
  local max_width = 60
  local separator_positions = {}
  local session = backend.current_session and backend.sessions[backend.current_session]

  -- 渲染消息
  if session and session.messages and #session.messages > 0 then
    for i, msg in ipairs(session.messages) do
      -- 添加角色标题行（可编辑）
      local role_icon = M.config.show_role_icons and (M.config.role_icons[msg.role] or "") or ""
      local role_name = string.upper(msg.role)
      local header = role_icon .. " " .. role_name
      if M.config.show_timestamps then
        header = header .. " · " .. os.date("%H:%M", msg.timestamp)
      end
      table.insert(lines, header)

      -- 添加消息内容（可编辑）
      local content_lines = wrap_message_content(msg.content, max_width - 4)
      for _, line in ipairs(content_lines) do
        table.insert(lines, line)
      end

      -- 记录分割线位置（不可编辑）
      if i < #session.messages then
        table.insert(lines, "") -- 占位行
        table.insert(separator_positions, #lines - 1)
      end
    end
  else
    -- 空状态
    table.insert(lines, "")
    table.insert(lines, "  欢迎使用 NeoAI!")
    table.insert(lines, "  输入消息开始对话")
    table.insert(lines, "")
  end

  -- 记录输入提示分割线位置
  local separator_line_num = #lines
  table.insert(lines, "")
  table.insert(separator_positions, separator_line_num)

  -- 记录输入行位置
  local input_line = #lines
  table.insert(lines, "")
  M.input_start_line = input_line
  M.input_end_line = input_line

  -- 写入缓冲区
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- 添加虚拟文本分割线（不可编辑）
  for _, sep_line in ipairs(separator_positions) do
    vim.api.nvim_buf_set_extmark(buf, ns_virtual_text, sep_line, 0, {
      virt_text = { { string.rep(M.get_separator_char(), max_width), "Comment" } },
      virt_text_pos = "overlay",
    })
  end

  -- 设置消息区域为可编辑，分割线区域不可编辑
  M._setup_editability(buf, session)

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

  -- 记录当前缓冲区行数
  M._last_buffer_line_count = vim.api.nvim_buf_line_count(buf)

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

  -- 刷新树视图
  if M.showing_tree and is_win_valid(M.windows.tree) and is_buf_valid(M.tree_buffers.main) then
    M.render_session_tree()
  end
end

--- 设置缓冲区可编辑性
function M._setup_editability(buf, session)
  if not session or not session.messages then
    return
  end

  M._line_to_message = {}
  local current_line = 0

  for i, msg in ipairs(session.messages) do
    -- 标题行（不映射）
    local header_line = current_line
    current_line = current_line + 1

    -- 获取当前消息的内容行数
    local content_lines = wrap_message_content(msg.content, 60 - 4)
    
    -- 只映射内容行（不映射标题行）
    for j, content_line in ipairs(content_lines) do
      local line_num = current_line + j - 1
      M._line_to_message[line_num] = {
        session_id = session.id,
        message_id = msg.id,
      }
    end

    current_line = current_line + #content_lines

    -- 跳过消息间的空行（分割线占位符）
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
    backend.new_session("默认会话")
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
  -- 关闭树视图窗口
  if is_win_valid(M.windows.tree) then
    vim.api.nvim_win_close(M.windows.tree, true)
    M.windows.tree = nil
  end

  if is_buf_valid(M.tree_buffers.main) then
    vim.api.nvim_buf_delete(M.tree_buffers.main, { force = true })
    M.tree_buffers.main = nil
  end

  local mode = M.current_mode
  if mode == M.ui_modes.FLOAT then
    local opts = M.get_window_strategy(M.ui_modes.FLOAT)()
    M.setup_windows(opts)
  elseif mode == M.ui_modes.SPLIT then
    vim.cmd("belowright vsplit")
    M.windows.main = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
    M.set_window_wrap()
    M.setup_buffers()
  elseif mode == M.ui_modes.TAB then
    vim.cmd("tabnew")
    M.windows.main = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
    M.set_window_wrap()
    M.original_tabline = vim.o.tabline
    M.original_showtabline = vim.o.showtabline
    vim.o.showtabline = 2
    vim.o.tabline = '%!v:lua.require("NeoAI.ui").get_tab_label()'
    M.setup_buffers()
  end
end

--- 打开浮窗模式
function M.open_float()
  ensure_active_session()
  M.create_buffers()

  if M.showing_tree and not is_buf_valid(M.tree_buffers.main) then
    M.create_tree_buffers()
  end

  if M.showing_tree then
    local strategy = M.get_window_strategy("tree")
    local opts = strategy(M.windows.main, math.min(50, math.floor(M.config.ui.width * 0.5)))
    M.windows.tree = vim.api.nvim_open_win(M.tree_buffers.main, true, opts)
    vim.api.nvim_set_option_value("winfixwidth", true, { win = M.windows.tree })
    M.is_open = true
    M.current_mode = M.ui_modes.FLOAT
    return
  end

  local opts = M.get_window_strategy(M.ui_modes.FLOAT)()
  M.setup_windows(opts)
  M.current_mode = M.ui_modes.FLOAT
end

--- 打开分割窗口模式
function M.open_split()
  ensure_active_session()
  M.create_buffers()

  if M.showing_tree and not is_buf_valid(M.tree_buffers.main) then
    M.create_tree_buffers()
  end

  if M.showing_tree then
    local strategy = M.get_window_strategy("tree")
    local tree_w = math.min(50, math.floor(vim.o.columns * 0.3))
    local opts = strategy(M.windows.main, tree_w)
    vim.cmd("vsplit")
    M.windows.tree = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.windows.tree, M.tree_buffers.main)
    vim.api.nvim_win_set_width(M.windows.tree, opts.width)
    vim.api.nvim_set_option_value("winfixwidth", true, { win = M.windows.tree })
    M.is_open = true
    M.current_mode = M.ui_modes.SPLIT
    return
  end

  vim.cmd("belowright vsplit")
  M.windows.main = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
  local opts = M.get_window_strategy(M.ui_modes.SPLIT)()
  vim.api.nvim_win_set_width(M.windows.main, opts.width)
  M.set_window_wrap()
  M.setup_buffers()
  M.is_open = true
  M.current_mode = M.ui_modes.SPLIT
end

--- 打开标签页模式
function M.open_tab()
  ensure_active_session()
  M.create_buffers()

  if M.showing_tree and not is_buf_valid(M.tree_buffers.main) then
    M.create_tree_buffers()
  end

  if M.showing_tree then
    vim.cmd("tabnew")
    local strategy = M.get_window_strategy("tree")
    local tree_w = math.min(50, math.floor(vim.o.columns * 0.3))
    local opts = strategy(nil, tree_w)
    M.windows.tree = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.windows.tree, M.tree_buffers.main)
    vim.api.nvim_win_set_width(M.windows.tree, opts.width)
    vim.api.nvim_set_option_value("winfixwidth", true, { win = M.windows.tree })
    M.is_open = true
    M.current_mode = M.ui_modes.TAB
    return
  end

  vim.cmd("tabnew")
  M.windows.main = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
  M.set_window_wrap()
  M.original_tabline = vim.o.tabline
  M.original_showtabline = vim.o.showtabline
  vim.o.showtabline = 2
  vim.o.tabline = '%!v:lua.require("NeoAI.ui").get_tab_label()'
  M.setup_buffers()
  M.is_open = true
  M.current_mode = M.ui_modes.TAB
end

-- ── 输入处理 ───────────────────────────────────────────────────────────────

--- 设置输入处理
function M.setup_input_handling()
  local group = vim.api.nvim_create_augroup("NeoAIInput", { clear = true })

  -- 焦点进入/离开聊天窗口时重新设置快捷键
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    pattern = "*",
    callback = function()
      if M.windows.main and vim.api.nvim_get_current_win() == M.windows.main then
        M.setup_keymaps()
      else
        M.clear_keymaps()
      end
    end,
  })

  -- 根据光标位置切换可编辑状态
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = M.buffers.main,
    callback = function()
      if not is_win_valid(M.windows.main) or not is_buf_valid(M.buffers.main) then
        return
      end
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1

      -- 检查是否是输入区域
      local is_input_region = false
      if M.input_start_line and M.input_end_line then
        is_input_region = cur_line >= M.input_start_line and cur_line <= M.input_end_line
      elseif M.input_start_line and cur_line == M.input_start_line then
        is_input_region = true
      end

      -- 检查是否是可编辑的消息内容行
      local is_editable = M._line_to_message and M._line_to_message[cur_line] ~= nil
      
      -- 输入区域始终可编辑
      if is_input_region then
        is_editable = true
      end

      vim.api.nvim_set_option_value("modifiable", is_editable, { buf = M.buffers.main })
      vim.api.nvim_set_option_value("readonly", not is_editable, { buf = M.buffers.main })

      -- 管理输入行虚拟文本提示
      if cur_line == M.input_start_line and is_buf_valid(M.buffers.main) then
        M._update_input_prompt()
      end
    end,
  })

  -- 跟踪输入区域的行数变化（插入模式下）
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = M.buffers.main,
    callback = function()
      if not is_win_valid(M.windows.main) or not is_buf_valid(M.buffers.main) then
        return
      end
      
      -- 更新输入提示
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
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    buffer = M.buffers.main,
    callback = function()
      if not is_win_valid(M.windows.main) or not is_buf_valid(M.buffers.main) then
        return
      end
      
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1
      
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
        M._last_buffer_line_count = current_count
      end
    end,
  })

  -- 离开编辑行时保存
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = M.buffers.main,
    callback = function()
      if not is_win_valid(M.windows.main) or not is_buf_valid(M.buffers.main) then
        return
      end
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1

      -- 如果在可编辑的消息内容行，保存编辑的内容
      if M._line_to_message and M._line_to_message[cur_line] then
        local msg_info = M._line_to_message[cur_line]
        local session = backend.sessions[msg_info.session_id]
        if session then
          -- 查找消息
          for _, msg in ipairs(session.messages) do
            if tostring(msg.id) == tostring(msg_info.message_id) then
              -- 保存编辑前的内容提示
              vim.notify("[NeoAI] 正在保存编辑: " .. string.sub(msg.content, 1, 30) .. "...", vim.log.levels.INFO)
              break
            end
          end
        end
        
        M._save_edited_line(cur_line)
      end
    end,
  })
end

--- 保存编辑的消息行（支持多行）
function M._save_edited_line(line_num)
  if not is_buf_valid(M.buffers.main) then
    return
  end

  -- 查找对应的消息信息
  local msg_info = M._line_to_message and M._line_to_message[line_num]
  if not msg_info then
    return
  end

  local session = backend.sessions[msg_info.session_id]
  if not session then
    return
  end

  -- 找到对应的消息对象
  local target_msg = nil
  local msg_index = nil
  for i, msg in ipairs(session.messages) do
    -- 兼容字符串和数字ID
    if tostring(msg.id) == tostring(msg_info.message_id) then
      target_msg = msg
      msg_index = i
      break
    end
  end

  if not target_msg then
    vim.notify("[NeoAI] 未找到对应的消息", vim.log.levels.WARN)
    return
  end

  -- 收集属于同一消息的所有连续行
  local start_line = line_num
  local end_line = line_num

  -- 向前查找消息内容的起始行
  while start_line >= 0 do
    local info = M._line_to_message and M._line_to_message[start_line]
    if not info or tostring(info.message_id) ~= tostring(msg_info.message_id) then
      start_line = start_line + 1
      break
    end
    start_line = start_line - 1
  end
  start_line = math.max(0, start_line + 1)

  -- 向后查找消息内容的结束行
  local buf_line_count = vim.api.nvim_buf_line_count(M.buffers.main)
  while end_line < buf_line_count do
    local info = M._line_to_message and M._line_to_message[end_line]
    if not info or tostring(info.message_id) ~= tostring(msg_info.message_id) then
      end_line = end_line - 1
      break
    end
    end_line = end_line + 1
  end
  end_line = math.min(buf_line_count, end_line)

  -- 获取编辑后的内容行
  local lines = vim.api.nvim_buf_get_lines(M.buffers.main, start_line, end_line, false)

  -- 过滤内容：跳过标题行（如 "👤 USER · 14:30"），保留实际内容
  -- 使用 _line_to_message 来判断是否是内容行（更可靠）
  local content_lines = {}
  for i, line in ipairs(lines) do
    local actual_line = start_line + i - 1
    local line_info = M._line_to_message and M._line_to_message[actual_line]
    
    -- 只有当该行属于消息内容（不是标题行）时才保留
    -- 标题行不在 _line_to_message 映射中，只有内容行在
    if line_info then
      table.insert(content_lines, line)
    end
  end

  -- 连接内容
  local content = table.concat(content_lines, "\n")
  content = vim.trim(content)

  -- 如果内容为空或与原内容相同，则不保存
  if content == "" or content == target_msg.content then
    return
  end

  -- 更新消息
  if backend.edit_message then
    local success = backend.edit_message(msg_info.session_id, msg_info.message_id, content)
    if success then
      vim.notify("[NeoAI] 消息已保存", vim.log.levels.INFO)
    else
      vim.notify("[NeoAI] 保存失败", vim.log.levels.WARN)
    end
  end
end

--- 更新输入提示虚拟文本
function M._update_input_prompt()
  if not M.input_start_line or not is_buf_valid(M.buffers.main) then
    return
  end

  local ns_id = vim.api.nvim_create_namespace("NeoAIInputPrompt")
  -- 先清除旧的提示
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
function M.save_and_send()
  if not M.input_start_line or not is_buf_valid(M.buffers.main) then
    vim.notify("[NeoAI] 错误: 缓冲区无效", vim.log.levels.WARN)
    return
  end
  if not backend.current_session then
    vim.notify("[NeoAI] 错误: 没有活跃的会话", vim.log.levels.WARN)
    return
  end

  -- 获取输入区域的所有行
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

  -- 连接多行内容
  local text = table.concat(lines, "\n")
  text = vim.trim(text)
  if text == "" then
    vim.notify("[NeoAI] 警告: 输入内容为空", vim.log.levels.WARN)
    return
  end

  -- 清空输入区域
  local input_line_count = end_line - M.input_start_line + 1
  vim.api.nvim_buf_set_lines(M.buffers.main, M.input_start_line, M.input_start_line + input_line_count, false, { "" })
  M.input_end_line = M.input_start_line

  if backend.send_message(text) then
    vim.notify("[NeoAI] 消息已发送", vim.log.levels.INFO)
  else
    vim.notify("[NeoAI] 错误: 消息发送失败", vim.log.levels.ERROR)
  end
  
  -- 延迟更新显示，确保消息已添加到后端
  vim.defer_fn(function()
    M.update_display()
  end, 100)
end

--- 光标定位到输入消息行
function M.focus_input_line()
  if M.input_start_line and is_buf_valid(M.buffers.main) and is_win_valid(M.windows.main) then
    vim.api.nvim_win_set_cursor(M.windows.main, { M.input_start_line + 1, 0 })
  end
end

-- ── 快捷键管理 ─────────────────────────────────────────────────────────────

--- 清理快捷键
function M.clear_keymaps()
  if not is_buf_valid(M.buffers.main) then
    return
  end

  for _, mode in ipairs({ "n", "i", "v", "x", "s", "o" }) do
    local kms = vim.api.nvim_buf_get_keymap(M.buffers.main, mode)
    for _, km in ipairs(kms) do
      vim.api.nvim_buf_del_keymap(M.buffers.main, mode, km.lhs)
    end
  end
end

--- 设置快捷键
function M.setup_keymaps()
  if not is_win_valid(M.windows.main) then
    return
  end

  local buf = M.buffers.main

  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, noremap = true })
  end

  -- 普通模式快捷键
  map("n", "e", function()
    if is_win_valid(M.windows.main) then
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1
      -- 检查是否在可编辑行
      if M._line_to_message and M._line_to_message[cur_line] then
        vim.cmd("startinsert")
      else
        vim.notify("[NeoAI] 此行不可编辑")
      end
    end
  end, "编辑消息")

  map("n", "s", function()
    if backend.current_session then
      backend.export_session(backend.current_session)
      vim.notify("[NeoAI] 会话已导出")
    end
  end, "导出会话")

  -- 配置快捷键
  map("n", M.config.keymaps.open, "<cmd>NeoAIOpen<CR>", "打开聊天")
  map("n", M.config.keymaps.close, M.close, "关闭聊天")
  map("n", M.config.keymaps.new, "<cmd>NeoAINew<CR>", "新建会话")
  map("n", "q", M.close, "关闭聊天")
  map("n", "<Esc>", M.close, "关闭聊天")

  -- 正常模式下回车 → 发送消息或进入编辑模式
  map("n", M.config.keymaps.normal_mode_send, function()
    if is_win_valid(M.windows.main) then
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1
      local input_end = M.input_end_line or M.input_start_line
      -- 检查是否在输入区域
      if M.input_start_line and cur_line >= M.input_start_line and cur_line <= input_end then
        -- 在输入区域，发送消息
        M.save_and_send()
      elseif M._line_to_message and M._line_to_message[cur_line] then
        -- 在可编辑行，进入插入模式
        vim.cmd("startinsert")
      end
    end
  end, "发送消息或编辑")

  -- 插入模式下 Ctrl+s → 发送消息
  map("i", M.config.keymaps.insert_mode_send, M.save_and_send, "发送消息")
  map("i", "<C-c>", M.close, "关闭聊天")

  -- 插入模式下回车 → 换行
  map("i", "<CR>", function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
  end, "换行")
end

-- ── 窗口控制 ──────────────────────────────────────────────────────────────

--- 关闭所有窗口
function M.close()
  -- 同步所有会话数据
  if backend.sessions then
    backend.sync_data()
  end
  
  -- 关闭窗口
  for _, win in pairs(M.windows) do
    if is_win_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- 删除缓冲区
  for _, buf in pairs(M.buffers) do
    if is_buf_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  for _, buf in pairs(M.tree_buffers) do
    if is_buf_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  -- 停止定时器
  for _, timer in pairs(M._debounce_timers) do
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
  end
  M._debounce_timers = {}

  -- 清理自动命令
  pcall(vim.api.nvim_del_augroup_by_name, "NeoAIInput")
  pcall(vim.api.nvim_del_augroup_by_name, "NeoAIResize")

  -- 恢复标签栏设置
  if M.original_tabline then
    vim.o.tabline = M.original_tabline
  end
  if M.original_showtabline then
    vim.o.showtabline = M.original_showtabline
  end

  -- 重置状态
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
end

--- 切换UI模式
-- @param mode UI模式
function M.switch_mode(mode)
  if M.is_open then
    M.close()
  end

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
function M.toggle_tree_view()
  M.showing_tree = not M.showing_tree
  if M.is_open then
    local mode = M.current_mode
    M.close()

    if mode == M.ui_modes.FLOAT then
      M.open_float()
    elseif mode == M.ui_modes.SPLIT then
      M.open_split()
    elseif mode == M.ui_modes.TAB then
      M.open_tab()
    end

    vim.notify("[NeoAI] 树视图已" .. (M.showing_tree and " 显示" or "隐藏"))
  else
    vim.notify("[NeoAI] 树视图将在下次打开聊天时" .. (M.showing_tree and "显示" or "隐藏"))
  end
end

-- ── 模块初始化 ──────────────────────────────────────────────────────────────

--- 模块初始化
-- @param user_config 用户配置
function M.setup(user_config)
  M.config = vim.tbl_deep_extend("force", config.defaults, user_config or {})

  -- 事件监听（防抖处理）
  backend.on("message_added", function(data)
    M.update_display_debounced()
    -- 每轮对话结束后自动定位光标到输入行
    vim.defer_fn(function()
      M.focus_input_line()
    end, 50)
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)
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
  backend.on("message_deleted", function(data)
    M.update_display_debounced()
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)
  backend.on("ai_replied", function(data)
    M.update_display_debounced()
    -- AI回复完成后，异步等待渲染完成再定位光标
    vim.defer_fn(function()
      if M.update_display_debounced then
        -- 等待防抖更新完成
        vim.defer_fn(function()
          M.focus_input_line()
        end, 60)
      end
    end, 10)
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)
  backend.on("response_received", function(data)
    M.update_display_debounced()
    -- 响应接收后，异步等待渲染完成再定位光标
    vim.defer_fn(function()
      if M.update_display_debounced then
        -- 等待防抖更新完成
        vim.defer_fn(function()
          M.focus_input_line()
        end, 60)
      end
    end, 10)
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)
  backend.on("session_created", function(data)
    M.update_display_debounced()
    -- 自动同步数据
    backend.debounce_sync(data.id)
  end)
  backend.on("data_synced", function(data)
    -- 数据已同步，可以在这里添加UI反馈（如状态栏提示）
    -- 暂时不需要额外操作，仅作日志记录
    -- vim.notify("[NeoAI] 数据已同步: " .. data.action, vim.log.levels.DEBUG)
  end)

  -- 窗口调整处理
  local group = vim.api.nvim_create_augroup("NeoAIResize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    pattern = "*",
    callback = function()
      M.schedule_resize()
    end,
  })

  -- 窗口关闭时清理
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = "*",
    callback = function()
      M.cleanup_windows()
    end,
  })
  
  -- Neovim退出前自动同步所有数据
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    pattern = "*",
    callback = function()
      if backend.sessions then
        backend.sync_data()
      end
    end,
  })
end

return M
