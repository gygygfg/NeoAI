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
M.showing_tree = true -- 是否显示树视图
M._debounce_timers = {} -- 防抖计时器表
M._resize_pending = false -- 是否有待处理的调整大小请求

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

--- 防抖函数：在指定延迟后执行函数，期间重复调用会重置计时器
-- @param fn 要执行的函数
-- @param delay_ms 延迟时间（毫秒）
-- @return function 包装后的防抖函数
local function debounce(fn, delay_ms)
  return function(...)
    local args = { ... }
    local timer_name = tostring(fn)

    -- 停止旧的计时器
    local old_timer = M._debounce_timers[timer_name]
    if old_timer then
      old_timer:stop()
      if not old_timer:is_closing() then
        old_timer:close()
      end
    end

    -- 创建新的计时器
    local timer = assert(vim.loop.new_timer())
    M._debounce_timers[timer_name] = timer
    timer:start(delay_ms, 0, function()
      vim.schedule(function()
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

--- 截断过长的内容
-- @param content 原始内容
-- @param max_len 最大长度
-- @return string 截断后的内容
local function truncate_content(content, max_len)
  if #content <= max_len then
    return content
  end
  return content:sub(1, max_len) .. "..."
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

--- 清理字符串中的换行符
-- @param str 输入字符串
-- @return string 清理后的字符串
local function sanitize_line(str)
  if not str then
    return ""
  end
  return tostring(str):gsub("[\r\n]+", " ")
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

--- 防抖后的更新显示函数（50ms 延迟）
M.update_display_debounced = debounce(function()
  M.update_display()
end, 50)

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
  vim.schedule(function()
    if M.is_open and is_win_valid(M.windows.main) and is_buf_valid(M.buffers.main) then
      -- 确保输入行可编辑
      vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main })
      vim.api.nvim_set_option_value("readonly", false, { buf = M.buffers.main })
      -- 滚动到最后一行（输入行），确保光标在最下面
      local line_count = vim.api.nvim_buf_line_count(M.buffers.main)
      vim.api.nvim_win_set_cursor(M.windows.main, { line_count, 0 })
      vim.cmd("normal! zb")
      -- 进入插入模式准备输入
      vim.cmd("startinsert")
    end
  end)
end

--- 设置树窗口光标移动自动命令
-- 为树缓冲区注册 CursorMoved 事件处理器，支持智能跳转：
-- 向下移动时跳到下一轮对话开始，向上移动时跳到上一轮对话开始
function M.setup_tree_cursor_autocmd()
  if not is_buf_valid(M.tree_buffers.main) then
    return
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
      ready_timer:start(200, 0, function()
        vim.schedule(function()
          is_ready = true
        end)
      end)
    end
  end

  enable_after_delay()

  local tree_augroup = vim.api.nvim_create_augroup("NeoAITreeCursor", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = tree_augroup,
    buffer = M.tree_buffers.main,
    callback = function()
      -- 未就绪或正在移动或窗口无效，直接返回
      if not is_ready or is_moving or not is_win_valid(M.windows.tree) then
        return
      end

      local current_pos = vim.api.nvim_win_get_cursor(M.windows.tree)
      local last_line = last_cursor_pos[1]
      local current_line = current_pos[1]

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

        -- 收集所有对话轮次的行
        local all_turn_lines = {}
        for line_num, pos in pairs(positions_snapshot) do
          if pos and type(pos) == "table" and pos.type == "conversation_turn" then
            table.insert(all_turn_lines, { line = line_num, turn_index = pos.turn_index, pos = pos })
          end
        end

        -- 按行号排序
        table.sort(all_turn_lines, function(a, b)
          return a.line < b.line
        end)

        -- 查找目标行
        local target_line = nil
        local target_pos = nil

        if direction == 1 then
          -- 向下：找第一个大于当前行的对话轮次
          for _, item in ipairs(all_turn_lines) do
            if item.line > current_line then
              target_line = item.line
              target_pos = item.pos
              break
            end
          end
        else
          -- 向上：找最后一个小于当前行的对话轮次
          for i = #all_turn_lines, 1, -1 do
            if all_turn_lines[i].line < current_line then
              target_line = all_turn_lines[i].line
              target_pos = all_turn_lines[i].pos
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
          or vim.api.nvim_buf_get_option(buf, "filetype") == "NeoAI"
          or vim.api.nvim_buf_get_option(buf, "filetype") == "NeoAITree"
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
  vim.api.nvim_set_option_value("filetype", "NeoAI", { buf = M.buffers.main })
  vim.api.nvim_set_option_value("modifiable", true, { buf = M.buffers.main }) -- 允许编辑
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.buffers.main }) -- 非文件缓冲区
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = M.buffers.main }) -- 隐藏时保留缓冲区
  vim.api.nvim_set_option_value("swapfile", false, { buf = M.buffers.main }) -- 不创建交换文件
  M.setup_keymaps() -- 设置快捷键
  M.setup_input_handling() -- 设置输入处理（自动命令）
  M.update_display() -- 初始渲染显示
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
      -- 用户消息：创建新的对话轮次
      current = { user_msg = msg, assistant_msg = nil, index = i }
      table.insert(turns, current)
    elseif msg.role == "assistant" and current and not current.assistant_msg then
      -- 助手消息：附加到当前轮次（每条用户消息只对应一条助手回复）
      current.assistant_msg = msg
    else
      -- 其他情况：创建独立轮次（如孤立的助手消息）
      table.insert(turns, { user_msg = msg, assistant_msg = nil, index = i })
    end
  end

  return turns
end

--- 渲染会话树（修复宽度不够问题）
-- 在树视图中展示所有会话及其消息预览，支持点击切换会话
function M.render_session_tree()
  local buf = M.tree_buffers.main
  if not is_buf_valid(buf) then
    return
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

  local lines = {}
  local ns_id = vim.api.nvim_create_namespace("NeoAITree") -- 高亮命名空间
  M.tree_buffers.session_positions = {} -- 记录每行对应的会话/消息位置信息

  -- 标题（缩短以适配更小宽度）
  local title = "📂 Chat History"
  local title_width = display_width(title)
  local separator_len = 30
  table.insert(lines, "╭─ " .. title .. " ─" .. string.rep("─", separator_len) .. "╮")

  if backend.sessions and #backend.sessions > 0 then
    -- 遍历所有会话，渲染每个会话及其消息预览
    for session_id, session in pairs(backend.sessions) do
      local is_current = (session_id == backend.current_session)
      local icon = is_current and "📁" or "📂" -- 当前会话用打开的文件夹图标
      local session_info = string.format("%s %s (%d)", icon, sanitize_line(session.name), #session.messages)
      table.insert(lines, session_info)

      local line_idx = #lines
      -- 记录该行对应的会话信息（用于点击事件处理）
      M.tree_buffers.session_positions[line_idx] = { type = "session", id = session_id, line = line_idx - 1 }

      -- 渲染该会话的消息预览
      M._render_session_messages(lines, session, session_id, is_current)
      table.insert(lines, "") -- 会话间空行
    end
  else
    -- 无会话时的提示
    table.insert(lines, "│")
    table.insert(lines, "│  暂无会话")
    table.insert(lines, "│")
    table.insert(lines, "│  按 <CR> 创建新会话")
    table.insert(lines, "")
  end

  -- 底部操作提示
  local bottom_width = 50
  table.insert(lines, string.rep("─", bottom_width))
  table.insert(lines, "🔹 <CR> 选择  🔹 n 新建  🔹 q 关闭")

  -- 写入缓冲区
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- 应用高亮（当前会话用 Todo 高亮，其他用 Normal）
  for line_num, pos in pairs(M.tree_buffers.session_positions) do
    if pos.type == "session" then
      local hl = (pos.id == backend.current_session) and "Todo" or "Normal"
      vim.api.nvim_buf_add_highlight(buf, ns_id, hl, line_num - 1, 0, -1)
    end
  end

  -- 设置只读，防止误编辑
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })

  -- 延迟调整大小，确保内容已渲染
  vim.defer_fn(function()
    M.adjust_tree_window_size()
  end, 10)
end

--- 渲染会话消息
-- 在树视图中渲染单个会话的消息预览（按对话轮次展示）
-- @param lines 行数组（会被修改）
-- @param session 会话对象
-- @param session_id 会话ID
-- @param is_current 是否为当前会话
function M._render_session_messages(lines, session, session_id, is_current)
  if not session.messages or #session.messages == 0 then
    table.insert(lines, "  └─ (空会话)")
    return
  end

  local turns = group_messages_into_turns(session.messages)

  for i = 1, #turns do
    local turn = turns[i]
    local is_last = (i == #turns)
    local indent = is_last and "  └─ " or "  ├─ " -- 最后一轮用 └─，其他用 ├─

    -- 用户消息预览（截断为40字符）
    local user_preview = truncate_content(sanitize_line(turn.user_msg.content), 40)
    local user_time = os.date("%H:%M", turn.user_msg.timestamp)
    table.insert(lines, string.format("%s💬 [%s] %s", indent, user_time, user_preview))

    local line_idx = #lines
    -- 记录该行的位置信息（用于点击后跳转到对应消息）
    M.tree_buffers.session_positions[line_idx] = {
      type = "conversation_turn",
      session_id = session_id,
      turn_index = i,
      user_message_index = turn.index,
      line = line_idx - 1,
    }

    -- 助手消息预览
    if turn.assistant_msg then
      local asst_preview = truncate_content(sanitize_line(turn.assistant_msg.content), 45)
      local asst_time = os.date("%H:%M", turn.assistant_msg.timestamp)
      local reply_indent = is_last and "     " or "  │  " -- 缩进样式
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
      local session = backend.sessions[sid]
      vim.notify("[NeoAI] 切换到会话: " .. (session and session.name or sid))
      M.open_chat_after_tree_selection()
    else
      -- 点击在空白行：创建新会话
      backend.new_session("会话 " .. (#backend.sessions + 1))
      vim.notify("[NeoAI] 新会话已创建")
      M.open_chat_after_tree_selection()
    end
  end, "选择会话")

  -- n键：新建会话并跳到开始对话界面
  map("n", function()
    backend.new_session("会话 " .. (#backend.sessions + 1))
    vim.notify("[NeoAI] 新会话已创建")
    M.render_session_tree() -- 刷新树视图
    M.open_chat_after_tree_selection() -- 跳到对话界面
  end, "新建会话")

  -- 关闭快捷键
  map("q", M.close, "关闭")
  map("<Esc>", M.close, "关闭")

  -- r键：刷新树
  map("r", function()
    M.render_session_tree()
    vim.notify("[NeoAI] 已刷新")
  end, "刷新树")
end

--- 更新主显示
-- 重新渲染主缓冲区的内容，包括所有会话消息和输入提示区域
function M.update_display()
  local buf = M.buffers.main
  if not is_buf_valid(buf) then
    return
  end

  -- 保存当前光标位置（刷新后恢复）
  local save_cursor = is_win_valid(M.windows.main) and vim.api.nvim_win_get_cursor(M.windows.main) or nil

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

  -- 清除旧的虚拟文本和高亮（避免重复叠加）
  local ns_virtual_text = vim.api.nvim_create_namespace("NeoAIVirtualText")
  local ns_highlight = vim.api.nvim_create_namespace("NeoAIHighlight")
  vim.api.nvim_buf_clear_namespace(buf, ns_virtual_text, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_highlight, 0, -1)

  local lines = {}
  local max_width = 60
  local separator_positions = {} -- 记录分割线位置（不可编辑区域）
  local session = backend.current_session and backend.sessions[backend.current_session]

  -- 渲染消息
  if session and session.messages and #session.messages > 0 then
    for i, msg in ipairs(session.messages) do
      -- 添加角色标题行（如 "💬 USER · 14:30"）
      local role_icon = M.config.show_role_icons and (M.config.role_icons[msg.role] or "") or ""
      local role_name = string.upper(msg.role)
      local header = role_icon .. " " .. role_name
      if M.config.show_timestamps then
        header = header .. " · " .. os.date("%H:%M", msg.timestamp)
      end
      table.insert(lines, header)

      -- 添加消息内容（自动换行处理）
      local content_lines = wrap_message_content(msg.content, max_width - 4)
      for _, line in ipairs(content_lines) do
        table.insert(lines, line)
      end

      -- 记录分割线位置（消息之间的分隔线，不可编辑）
      if i < #session.messages then
        table.insert(lines, "") -- 占位行
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

  -- 记录输入提示分割线位置
  local separator_line_num = #lines
  table.insert(lines, "")
  table.insert(separator_positions, separator_line_num)

  -- 记录输入行位置（用户输入区域，默认 1 行高）
  local input_line = #lines
  table.insert(lines, "")
  M.input_start_line = input_line -- 输入区域起始行
  M.input_end_line = input_line -- 输入区域结束行（默认 1 行高）

  -- 写入缓冲区
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- 添加虚拟文本分割线（不可编辑的分隔线）
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
-- 建立缓冲区行号到消息对象的映射表，用于控制哪些行可以编辑
-- @param buf 缓冲区句柄
-- @param session 会话对象
function M._setup_editability(buf, session)
  if not session or not session.messages then
    return
  end

  M._line_to_message = {} -- 行号 -> {session_id, message_id} 映射表
  local current_line = 0

  for i, msg in ipairs(session.messages) do
    -- 标题行（不映射，不可编辑）
    local header_line = current_line
    current_line = current_line + 1

    -- 获取当前消息的内容行数（自动换行后的行数）
    local content_lines = wrap_message_content(msg.content, 60 - 4)

    -- 只映射内容行（不映射标题行），这些行可以被用户编辑
    for j, content_line in ipairs(content_lines) do
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
end

--- 打开浮窗模式
function M.open_float()
  ensure_active_session()

  if M.showing_tree then
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

  if M.showing_tree then
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
    M.setup_tree_cursor_autocmd()
    M.is_open = true
    M.current_mode = M.ui_modes.SPLIT
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
end

--- 打开标签页模式
function M.open_tab()
  ensure_active_session()

  if M.showing_tree then
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
    M.setup_tree_cursor_autocmd()

    M.is_open = true
    M.current_mode = M.ui_modes.TAB
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
    vim.notify("[NeoAI] 消息修改已保存: " .. msg, vim.log.levels.INFO)
  else
    vim.notify("[NeoAI] 消息修改保存失败" .. msg, vim.log.levels.INFO)
  end
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

  -- 关闭所有窗口（主窗口、树视图窗口等）
  for _, win in pairs(M.windows) do
    if is_win_valid(win) then
      safe_win_call(function()
        -- 标签模式下，关闭整个标签页而不是单个窗口
        if M.current_mode == M.ui_modes.TAB then
          local tab = vim.api.nvim_win_get_tabpage(win)
          if tab ~= vim.api.nvim_get_current_tabpage() then
            pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
          else
            pcall(vim.cmd, "tabclose")
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
  M.showing_tree = not M.showing_tree -- 切换状态
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

    vim.notify("[NeoAI] 树视图已" .. (M.showing_tree and " 显示" or "隐藏"))
  else
    vim.notify("[NeoAI] 树视图将在下次打开聊天时" .. (M.showing_tree and "显示" or "隐藏"))
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
    M.update_display_debounced() -- 防抖更新显示
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
    M.update_display_debounced()
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)

  -- AI 回复完成事件：刷新显示并定位光标
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

  -- 响应接收事件：刷新显示并定位光标
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

  -- 会话创建事件：刷新显示
  backend.on("session_created", function(data)
    M.update_display_debounced()
    -- 自动同步数据
    backend.debounce_sync(data.id)
  end)

  -- 数据同步事件：预留回调（可用于状态栏提示等）
  backend.on("data_synced", function(data)
    -- 数据已同步，可以在这里添加UI反馈（如状态栏提示）
    -- 暂时不需要额外操作，仅作日志记录
    -- vim.notify("[NeoAI] 数据已同步: " .. data.action, vim.log.levels.DEBUG)
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
