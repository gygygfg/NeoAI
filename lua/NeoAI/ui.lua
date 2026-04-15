-- NeoAI UI 模块
-- 负责聊天窗口的创建、渲染、窗口管理、快捷键绑定和输入处理
local M = {}
local backend = require("NeoAI.backend")
local config = require("NeoAI.config")
local utils = require("NeoAI.utils")

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

-- ── 推理内容显示引擎（浮动窗口 → 折叠文本） ──────────────────────────────────
-- 三阶段生命周期：
--   1. start_reasoning(msg_id)    — 开启浮动窗口
--   2. update_reasoning(msg_id)   — 实时更新浮动窗口文本
--   3. finish_reasoning(msg_id)   — 关闭浮动窗口，变为折叠文本

--- 推理显示配置表
M.reasoning_config = {
  max_width = 80, -- 浮动窗口最大宽度
  max_height = 8, -- 浮动窗口最大高度
  fold_on_finish = true, -- 思考完成后是否默认折叠
}

-- 前向声明：这些函数在 utils 模块中定义

--- 推理显示状态管理（内部）
local reasoning_engine = {
  config = M.reasoning_config, -- 引用配置表
  -- { message_id = {
  --   phase = "idle" | "thinking" | "finished",
  --   float_win = nil,          -- 浮动窗口 ID
  --   float_buf = nil,          -- 浮动窗口缓冲区 ID
  --   anchor_win = nil,         -- 锚点窗口
  --   anchor_row = nil,         -- 锚点行
  --   text = "",                -- 当前推理文本
  --   fold_state = false,       -- 折叠状态（仅在 finished 阶段有效）
  -- } }
  states = {},
}

--- 阶段 1：开启推理浮动窗口
-- @param message_id 消息ID
-- @param anchor_win 锚点窗口（通常是主窗口）
-- @param anchor_row 锚点行（相对于窗口的行号）
function M.start_reasoning(message_id, anchor_win, anchor_row)
  local state = utils.get_reasoning_state(reasoning_engine.states, message_id)
  state.phase = "thinking"
  state.text = ""
  state.anchor_win = (anchor_win and utils.is_win_valid(anchor_win)) and anchor_win or M.windows.main
  state.anchor_row = anchor_row

  -- 守护检查：锚点窗口必须有效
  if not utils.is_win_valid(state.anchor_win) then
    return
  end

  -- 销毁旧浮动窗口
  utils.destroy_reasoning_float(reasoning_engine.states, message_id)

  -- 创建新缓冲区
  local buf = vim.api.nvim_create_buf(false, true)
  state.float_buf = buf

  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "NeoAIReasoning", { buf = buf })

  -- 计算浮动窗口位置
  local ok, win_config = pcall(vim.api.nvim_win_get_config, state.anchor_win)
  if not ok then
    return
  end
  local win_row = win_config.row or 0
  local win_col = win_config.col or 0

  local ok2, cursor = pcall(vim.api.nvim_win_get_cursor, state.anchor_win)
  local target_row = anchor_row or (ok2 and cursor[1] or 1)

  local float_width = reasoning_engine.config.max_width
  local float_height = reasoning_engine.config.max_height
  local float_row = win_row + target_row - vim.fn.line("w0", state.anchor_win) + 1
  local float_col = win_col + 2

  -- 确保不超出屏幕
  if float_row + float_height > vim.o.lines then
    float_row = vim.o.lines - float_height - 2
  end

  -- 创建浮动窗口
  local win_id = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.max(0, float_row),
    col = math.max(0, float_col),
    width = float_width,
    height = float_height,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 100,
  })

  -- 设置窗口选项
  vim.api.nvim_set_option_value("wrap", true, { win = win_id })
  vim.api.nvim_set_option_value("linebreak", true, { win = win_id })
  vim.api.nvim_set_option_value("breakindent", false, { win = win_id })
  vim.api.nvim_set_option_value("number", false, { win = win_id })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win_id })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = win_id })
  vim.api.nvim_set_option_value("foldenable", false, { win = win_id })
  vim.api.nvim_set_option_value("winhl", "NormalFloat:CommentFloat", { win = win_id })

  state.float_win = win_id

  -- 同步到旧的兼容表
  M._reasoning_float_wins[message_id] = win_id
  M._reasoning_float_buffers[message_id] = buf
end

--- 阶段 2：更新推理文本（实时更新）
-- @param message_id 消息ID
-- @param text 完整的推理文本（替换现有内容）
function M.update_reasoning(message_id, text)
  local state = utils.get_reasoning_state(reasoning_engine.states, message_id)
  if state.phase ~= "thinking" then
    return
  end

  if text and text ~= "" then
    -- 检查新文本是否只是现有文本的扩展（避免重复）
    local current_text = state.text or ""

    -- 如果文本完全相同，不需要更新
    if text == current_text then
      return
    end

    -- 检查是否是扩展（新文本以现有文本开头）
    if text:sub(1, #current_text) == current_text then
      -- 新文本是现有文本的扩展，更新为完整的新文本
      state.text = text
    elseif current_text:sub(1, #text) == text then
      -- 新文本是现有文本的前缀（可能后端发送了旧版本），保持现有文本
      -- 不更新
    else
      -- 完全不同的文本，直接替换
      state.text = text
    end
  end

  utils.refresh_reasoning_float(state, reasoning_engine.config)
end

--- 阶段 3：完成推理，关闭浮动窗口，变为折叠文本
-- @param message_id 消息ID
-- @param fold_on_finish 是否默认折叠（可选，默认使用配置）
function M.finish_reasoning(message_id, fold_on_finish)
  local state = utils.get_reasoning_state(reasoning_engine.states, message_id)
  if state.phase ~= "thinking" then
    return
  end

  state.phase = "finished"
  state.fold_state = (fold_on_finish ~= nil) and fold_on_finish or reasoning_engine.config.fold_on_finish

  -- 关闭浮动窗口
  utils.destroy_reasoning_float(reasoning_engine.states, message_id)

  -- 同步到旧的兼容表
  M._reasoning_float_wins[message_id] = nil
  M._reasoning_float_buffers[message_id] = nil
  M._reasoning_fold_state[message_id] = state.fold_state
end

--- 获取推理内容在正文中的显示行（用于 _build_chat_content 调用）
-- 根据当前阶段和折叠状态生成正确的显示行
-- @param message_id 消息ID
-- @param max_width 最大行宽
-- @return table 显示行数组
function M.get_reasoning_display_lines(message_id, max_width)
  -- 尝试从引擎状态获取
  local state = reasoning_engine.states[message_id]

  -- 如果状态不存在或文本为空，尝试从当前会话的消息中恢复
  if not state or state.text == "" then
    state = M._restore_reasoning_state_from_message(message_id)
    if not state or state.text == "" then
      return {}
    end
  end

  local total_lines = 0
  for _ in state.text:gmatch("[^\r\n]+") do
    total_lines = total_lines + 1
  end

  if total_lines == 0 then
    return {}
  end

  local result = {}

  if state.phase == "thinking" then
    -- 思考中：只显示标题行（内容在浮动窗口中）
    local float_visible = state.float_win and vim.api.nvim_win_is_valid(state.float_win)
    local icon = float_visible and "▼" or "▶"
    table.insert(result, string.format("  %s [思考中，共 %d 行] 浮动窗口", icon, total_lines))
  elseif state.phase == "finished" then
    -- 思考完成：使用 Neovim 折叠标记
    if state.fold_state then
      -- 折叠状态：使用折叠标记包裹内容
      table.insert(result, string.format("  ▶ [思考完成，共 %d 行] {{{", total_lines))
      for line in state.text:gmatch("[^\r\n]+") do
        local cleaned = utils.truncate_content(utils.sanitize_line(line), max_width - 6)
        table.insert(result, "    " .. cleaned)
      end
      table.insert(result, "    }}}")
    else
      -- 展开状态：显示标题和全部内容
      table.insert(result, string.format("  ▼ [思考完成，共 %d 行]", total_lines))
      for line in state.text:gmatch("[^\r\n]+") do
        local cleaned = utils.truncate_content(utils.sanitize_line(line), max_width - 6)
        table.insert(result, "    " .. cleaned)
      end
    end
  end

  return result
end

--- 从消息元数据恢复推理状态
-- @param message_id 消息ID
-- @return table|nil 恢复的状态对象
function M._restore_reasoning_state_from_message(message_id)
  local session = backend.current_session and backend.sessions[backend.current_session]
  if not session or not session.messages then
    return nil
  end

  -- 查找对应的消息
  local target_msg = nil
  for _, msg in ipairs(session.messages) do
    if tostring(msg.id) == tostring(message_id) then
      target_msg = msg
      break
    end
  end

  if not target_msg then
    return nil
  end

  -- 检查是否有推理内容
  if not target_msg.metadata or not target_msg.metadata.has_reasoning or not target_msg.metadata.reasoning_content then
    return nil
  end

  -- 创建或更新状态
  local state = utils.get_reasoning_state(reasoning_engine.states, message_id)
  state.text = target_msg.metadata.reasoning_content or ""

  -- 判断阶段：如果消息已完成（非 pending），则为 finished 阶段
  if target_msg.pending then
    state.phase = "thinking"
    state.fold_state = false -- 思考中默认展开
  else
    state.phase = "finished"
    -- 从折叠状态表恢复折叠状态
    state.fold_state = M._reasoning_fold_state[message_id] or M.reasoning_config.fold_on_finish
  end

  return state
end

--- 切换推理内容的折叠状态
-- @param message_id 消息ID
function M.toggle_reasoning_fold(message_id)
  -- 尝试恢复状态
  local state = reasoning_engine.states[message_id]
  if not state then
    state = M._restore_reasoning_state_from_message(message_id)
  end

  if state and state.phase == "finished" then
    state.fold_state = not state.fold_state
    M._reasoning_fold_state[message_id] = state.fold_state
    M.update_display()

    -- 使用 Neovim 折叠命令确保折叠状态生效
    vim.defer_fn(function()
      if utils.is_win_valid(M.windows.main) then
        vim.api.nvim_win_call(M.windows.main, function()
          if state.fold_state then
            vim.cmd("fold")
          else
            vim.cmd("unfold")
          end
        end)
      end
    end, 50)
  end
end

--- 判断推理内容是否处于折叠状态
-- @param message_id 消息ID
-- @return boolean true=折叠，false=展开
function M.is_reasoning_folded(message_id)
  local state = reasoning_engine.states[message_id]
  if state then
    if state.phase == "finished" then
      return state.fold_state
    end
    return false -- 思考中默认展开
  end
  -- 回退到旧兼容表
  if M._reasoning_fold_state[message_id] == nil then
    return false
  end
  return M._reasoning_fold_state[message_id]
end

--- 关闭指定消息的推理浮动窗口（兼容旧接口）
-- @param message_id 消息ID
function M.close_reasoning_float(message_id)
  utils.destroy_reasoning_float(reasoning_engine.states, message_id)
  M._reasoning_float_wins[message_id] = nil
  M._reasoning_float_buffers[message_id] = nil
end

--- 为推理内容创建浮动窗口（兼容旧接口，内部使用引擎）
-- @param message_id 消息ID
-- @param reasoning_text 推理内容
-- @param anchor_win 锚点窗口
-- @param anchor_row 锚点行
-- @return number 浮动窗口ID
function M.create_reasoning_float_window(message_id, reasoning_text, anchor_win, anchor_row)
  local state = utils.get_reasoning_state(reasoning_engine.states, message_id)
  if state.float_win and vim.api.nvim_win_is_valid(state.float_win) then
    utils.destroy_reasoning_float(reasoning_engine.states, message_id)
  end

  state.phase = "thinking"
  state.text = reasoning_text or ""
  state.anchor_win = (anchor_win and utils.is_win_valid(anchor_win)) and anchor_win or M.windows.main
  state.anchor_row = anchor_row

  -- 守护检查
  if not utils.is_win_valid(state.anchor_win) then
    return nil
  end

  -- 创建新缓冲区
  local buf = vim.api.nvim_create_buf(false, true)
  state.float_buf = buf

  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "NeoAIReasoning", { buf = buf })

  -- 格式化文本
  local width = reasoning_engine.config.max_width - 2
  local lines = {}
  for line in (reasoning_text or ""):gmatch("[^\r\n]+") do
    local cleaned = utils.sanitize_line(line)
    local wrapped = utils.wrap_text(cleaned, width)
    for _, wl in ipairs(wrapped) do
      table.insert(lines, wl)
    end
  end
  if #lines == 0 then
    table.insert(lines, "暂无思考内容")
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })

  -- 计算位置
  local ok, win_config = pcall(vim.api.nvim_win_get_config, state.anchor_win)
  if not ok then
    return nil
  end
  local win_row = win_config.row or 0
  local win_col = win_config.col or 0
  local ok2, cursor = pcall(vim.api.nvim_win_get_cursor, state.anchor_win)
  local target_row = anchor_row or (ok2 and cursor[1] or 1)

  local float_width = reasoning_engine.config.max_width
  local float_height = math.min(reasoning_engine.config.max_height, #lines)
  local float_row = win_row + target_row - vim.fn.line("w0", state.anchor_win) + 1
  local float_col = win_col + 2

  if float_row + float_height > vim.o.lines then
    float_row = vim.o.lines - float_height - 2
  end

  local win_id = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.max(0, float_row),
    col = math.max(0, float_col),
    width = float_width,
    height = float_height,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 100,
  })

  vim.api.nvim_set_option_value("wrap", true, { win = win_id })
  vim.api.nvim_set_option_value("linebreak", true, { win = win_id })
  vim.api.nvim_set_option_value("breakindent", false, { win = win_id })
  vim.api.nvim_set_option_value("number", false, { win = win_id })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win_id })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = win_id })
  vim.api.nvim_set_option_value("foldenable", false, { win = win_id })
  vim.api.nvim_set_option_value("winhl", "NormalFloat:CommentFloat", { win = win_id })

  state.float_win = win_id
  M._reasoning_float_wins[message_id] = win_id
  M._reasoning_float_buffers[message_id] = buf

  return win_id
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

--- 获取输入框分隔线字符
-- @return string 分隔线字符
function M.get_separator_char()
  return SEPARATOR_CHARS[M.config.ui.input_separator] or "─"
end

-- ── 窗口管理函数 ─────────────────────────────────────────────────────────────

--- 清理无效的窗口和缓冲区
-- @return integer 清理的数量
function M.cleanup_windows()
  -- 先关闭所有推理浮动窗口
  for msg_id, _ in pairs(M._reasoning_float_wins) do
    M.close_reasoning_float(msg_id)
  end

  return utils.cleanup_windows(
    M.windows,
    M.buffers,
    M.tree_buffers,
    M._reasoning_float_wins,
    M._reasoning_float_buffers
  )
end

--- 计划调整窗口大小（防抖）
function M.schedule_resize()
  if M._resize_pending then
    return
  end
  M._resize_pending = true

  vim.defer_fn(function()
    M._resize_pending = false
    if M.is_open and utils.is_win_valid(M.windows.main) then
      M.update_display()
    end
  end, 100)
end

--- 防抖后的更新显示函数集合（50ms 延迟）
-- 为不同事件类型创建独立的防抖函数，避免共享定时器导致意外延迟
-- 每个事件类型使用唯一前缀，确保定时器不会互相干扰
M.update_display_debounced = {}

-- 通用防抖更新（向后兼容）
M.update_display_debounced.default = utils.debounce(function()
  M.update_display()
end, 50, "update_display_default", M._debounce_timers)

-- 各事件类型独立的防抖更新函数
M.update_display_debounced.message = utils.debounce(function()
  M.update_display()
end, 50, "update_display_message", M._debounce_timers)

M.update_display_debounced.delete = utils.debounce(function()
  M.update_display()
end, 50, "update_display_delete", M._debounce_timers)

M.update_display_debounced.reply = utils.debounce(function()
  M.update_display()
end, 50, "update_display_reply", M._debounce_timers)

M.update_display_debounced.response = utils.debounce(function()
  M.update_display()
end, 50, "update_display_response", M._debounce_timers)

M.update_display_debounced.session = utils.debounce(function()
  M.update_display()
end, 50, "update_display_session", M._debounce_timers)

M.update_display_debounced.turn = utils.debounce(function()
  M.update_display()
end, 50, "update_display_turn", M._debounce_timers)

--- 调整窗口大小（根据内容自动计算）
-- @param content_width 内容宽度
-- @param content_height 内容高度
function M.adjust_window_size(content_width, content_height)
  utils.adjust_window_size(M.windows, M.current_mode, content_width, content_height, M.WINDOW_LIMITS)
end

--- 调整树窗口大小（动态宽度，最大值为屏幕一半）
function M.adjust_tree_window_size()
  utils.adjust_tree_window_size(M.windows, M.tree_buffers, M.WINDOW_LIMITS)
end

--- 设置窗口换行选项（内联实现）
local function set_window_wrap_inline(windows)
  for _, win in pairs(windows) do
    if utils.is_win_valid(win) then
      vim.api.nvim_set_option_value("wrap", true, { win = win })
      vim.api.nvim_set_option_value("linebreak", true, { win = win })
      vim.api.nvim_set_option_value("breakindent", true, { win = win })
      -- 启用折叠功能，使用标记折叠法
      vim.api.nvim_set_option_value("foldmethod", "marker", { win = win })
      vim.api.nvim_set_option_value("foldenable", true, { win = win })
    end
  end
end

-- ── 窗口策略函数 ─────────────────────────────────────────────────────────────

--- 获取窗口策略函数
-- 根据不同的窗口模式（浮动、分割、标签、树视图）返回对应的窗口配置生成函数
-- @param mode 窗口模式 (float/split/tab/tree)
-- @return function 窗口策略函数，调用后返回窗口配置表
function M.get_window_strategy(mode)
  return utils.get_window_strategy(mode, M.config, M.WINDOW_LIMITS)
end

--- 设置窗口
-- 打开主聊天窗口并初始化相关组件（缓冲区、快捷键、输入处理）
-- 完成后自动将光标定位到输入行并进入插入模式
-- @param win_opts 窗口配置选项表
function M.setup_windows(win_opts)
  utils.setup_windows(M.windows, M.buffers, win_opts, M.setup_buffers, function(windows)
    for _, win in pairs(windows) do
      if utils.is_win_valid(win) then
        vim.api.nvim_set_option_value("wrap", true, { win = win })
        vim.api.nvim_set_option_value("linebreak", true, { win = win })
        vim.api.nvim_set_option_value("breakindent", true, { win = win })
        -- 启用折叠功能，使用标记折叠法
        vim.api.nvim_set_option_value("foldmethod", "marker", { win = win })
        vim.api.nvim_set_option_value("foldenable", true, { win = win })
      end
    end
  end)
  M.is_open = true
end

--- 设置树窗口光标移动自动命令
-- 为树缓冲区注册 CursorMoved 事件处理器，支持智能跳转：
-- 向下移动时跳到下一轮对话开始，向上移动时跳到上一轮对话开始
function M.setup_tree_cursor_autocmd()
  if not utils.is_buf_valid(M.tree_buffers.main) then
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
      if not is_ready or is_moving or not utils.is_win_valid(M.windows.tree) then
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
              if not utils.is_win_valid(M.windows.tree) then
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
  if utils.is_buf_valid(M.buffers.main) then
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
  if utils.is_buf_valid(M.tree_buffers.main) then
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
  vim.api.nvim_set_option_value("filetype", "text", { buf = M.buffers.main })
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
  if not utils.is_buf_valid(buf) then
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
        string.format("%s%s %s (%d)", prefix, file_icon, utils.sanitize_line(session.name), #session.messages)
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
  if utils.is_win_valid(M.windows.tree) then
    win_width = vim.api.nvim_win_get_width(M.windows.tree)
  elseif utils.is_win_valid(M.windows.main) then
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
    if utils.display_width(test_line) <= max_width_per_line and current_line ~= "" then
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

  local separator_len = utils.calculate_text_width()

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
    if not utils.is_buf_valid(buf) then
      return
    end

    local text_width = utils.calculate_text_width()
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
  if not utils.is_buf_valid(buf) then
    return
  end

  -- 保存当前光标位置
  local save_cursor = utils.is_win_valid(M.windows.main) and vim.api.nvim_win_get_cursor(M.windows.main) or nil

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
  local max_width = utils.calculate_text_width()
  M.adjust_window_size(max_width, #lines)
  set_window_wrap_inline(M.windows)

  -- 恢复光标或滚动到底部
  if utils.is_win_valid(M.windows.main) then
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

--- 为所有推理内容创建浮动窗口（使用新引擎，仅为思考中的消息创建）
-- 遍历会话消息，为思考中的消息创建浮动窗口
function M._create_reasoning_float_windows()
  local session = backend.current_session and backend.sessions[backend.current_session]
  if not session or not session.messages then
    return
  end

  if not utils.is_win_valid(M.windows.main) or not utils.is_buf_valid(M.buffers.main) then
    return
  end

  -- 遍历消息，为思考中的消息创建/更新浮动窗口
  local current_line = 0
  for _, msg in ipairs(session.messages) do
    -- 标题行
    current_line = current_line + 1

    -- 检查是否有推理内容
    if
      msg.metadata
      and msg.metadata.has_reasoning
      and msg.metadata.reasoning_content
      and M.config.llm.show_reasoning
    then
      local is_pending = msg.pending -- true = 思考中
      local reasoning_text = msg.metadata.reasoning_content

      -- 记录行号
      M._reasoning_line_for_msg[msg.id] = current_line

      -- 优先使用推理引擎的状态（比 msg.pending 更准确）
      local state = reasoning_engine.states[msg.id]
      local engine_phase = state and state.phase or "idle"

      -- 如果状态不存在，尝试从消息元数据恢复
      if not state then
        state = M._restore_reasoning_state_from_message(msg.id)
        if state then
          engine_phase = state.phase
        end
      end

      if engine_phase == "thinking" then
        -- 思考中：检查是否需要更新浮动窗口
        -- 注意：这里不调用 update_reasoning，因为实时更新由 ai_reasoning_update 事件处理
        -- 我们只需要确保浮动窗口存在
        if not state.float_win or not vim.api.nvim_win_is_valid(state.float_win) then
          -- 浮动窗口不存在，重新创建
          M.start_reasoning(msg.id, M.windows.main, current_line)
          M.update_reasoning(msg.id, reasoning_text)
        end
      elseif engine_phase == "finished" then
        -- 思考已完成（引擎状态优先）：确保浮动窗口已关闭
        if state and (state.float_win or state.float_buf) then
          utils.destroy_reasoning_float(reasoning_engine.states, msg.id)
          M._reasoning_float_wins[msg.id] = nil
          M._reasoning_float_buffers[msg.id] = nil
        end
      elseif is_pending and reasoning_text and reasoning_text ~= "" then
        -- 引擎状态为 idle 但消息仍在 pending：首次检测到推理，启动引擎
        utils.get_reasoning_state(reasoning_engine.states, msg.id)
        reasoning_engine.states[msg.id].phase = "thinking"
        reasoning_engine.states[msg.id].text = reasoning_text
        M.start_reasoning(msg.id, M.windows.main, current_line)
        M.update_reasoning(msg.id, reasoning_text)
      elseif not is_pending then
        -- 消息已完成：确保引擎处于 finished 状态
        if not state or state.phase ~= "finished" then
          utils.get_reasoning_state(reasoning_engine.states, msg.id)
          reasoning_engine.states[msg.id].phase = "finished"
          reasoning_engine.states[msg.id].text = reasoning_text
          reasoning_engine.states[msg.id].fold_state = M._reasoning_fold_state[msg.id] or false
          utils.destroy_reasoning_float(reasoning_engine.states, msg.id)
          M._reasoning_float_wins[msg.id] = nil
          M._reasoning_float_buffers[msg.id] = nil
        end
      end

      current_line = current_line + 1
    end

    -- 跳过消息内容行
    local content_lines = utils.wrap_message_content(msg.content or "", utils.calculate_text_width() - 4)
    current_line = current_line + #content_lines

    -- 跳过消息间的空行
    current_line = current_line + 1
  end
end

-- ── 旧兼容层：清理所有推理状态 ───────────────────────────────────────────────
-- 窗口大小变化时调用，清理所有推理引擎状态
-- @param message_id 消息ID（可选，不提供则清理所有）
function M.cleanup_reason_state(message_id)
  if message_id then
    utils.destroy_reasoning_float(reasoning_engine.states, message_id)
    reasoning_engine.states[message_id] = nil
  else
    for msg_id, _ in pairs(reasoning_engine.states) do
      utils.destroy_reasoning_float(reasoning_engine.states, msg_id)
    end
    reasoning_engine.states = {}
  end
end

--- 构建聊天内容（内部辅助函数）
-- @return table 行数组, table 分隔线位置
function M._build_chat_content()
  local lines = {}
  local max_width = utils.calculate_text_width()
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
      if
        msg.metadata
        and msg.metadata.has_reasoning
        and msg.metadata.reasoning_content
        and M.config.llm.show_reasoning
      then
        -- 判断推理是否完成：优先使用 reasoning_finished 标记（模型开始输出正文时设置）
        local is_complete = msg.metadata.reasoning_finished or not msg.pending
        local reasoning_display_lines = M.get_reasoning_display_lines(msg.id, max_width)
        for _, rline in ipairs(reasoning_display_lines) do
          table.insert(lines, rline)
        end
      end

      -- 添加消息内容（自动换行）
      local content_lines = utils.wrap_message_content(msg.content or "", max_width - 4)
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
  local max_width = utils.calculate_text_width()
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

--- 渲染会话树（文件树样式，合并共享历史）
-- 在树视图中展示所有会话及其消息预览，支持点击切换会话
function M.render_session_tree()
  if not utils.is_buf_valid(M.tree_buffers.main) then
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
  local turns = utils.group_messages_into_turns(session.messages or {})
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
  local preview_len = utils.calc_preview_length(tree_prefix)
  for i = 1, #turns do
    local turn = turns[i]
    local is_last_turn = (i == #turns) and (max_branch_turn == 0)
    local line_prefix = tree_prefix .. (is_last_turn and "└─ " or "├─ ")

    -- 用户消息
    local user_preview = utils.truncate_content(utils.sanitize_line(turn.user_msg.content), preview_len)
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
      local asst_preview = utils.truncate_content(utils.sanitize_line(turn.assistant_msg.content), preview_len)
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
  local turns = utils.group_messages_into_turns(session.messages or {})
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

  local preview_len = utils.calc_preview_length(tree_prefix)

  for i = skip_turns + 1, #turns do
    local turn = turns[i]
    local is_last_turn = (i == #turns) and (max_branch_turn <= i)
    local line_prefix = tree_prefix .. (is_last_turn and "└─ " or "├─ ")

    local user_preview = utils.truncate_content(utils.sanitize_line(turn.user_msg.content), preview_len)
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
      local asst_preview = utils.truncate_content(utils.sanitize_line(turn.assistant_msg.content), preview_len)
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
  if not utils.is_buf_valid(M.tree_buffers.main) then
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
  if M.should_show_tree() and utils.is_win_valid(M.windows.tree) and utils.is_buf_valid(M.tree_buffers.main) then
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
    if
      msg.metadata
      and msg.metadata.has_reasoning
      and msg.metadata.reasoning_content
      and M.config.llm.show_reasoning
    then
      -- 判断推理是否完成：优先使用 reasoning_finished 标记
      local is_complete = msg.metadata.reasoning_finished or not msg.pending
      local reasoning_display_lines = M.get_reasoning_display_lines(msg.id, 60)
      current_line = current_line + #reasoning_display_lines
    end

    -- 获取当前消息的内容行数（自动换行后的行数）
    local content_lines = utils.wrap_message_content(msg.content or "", 60 - 4)

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

--- 选择会话后打开聊天窗口
function M.open_chat_after_tree_selection()
  local mode = M.current_mode

  if mode == M.ui_modes.FLOAT then
    -- 浮动模式：树和主窗口是同一个，先替换缓冲区再删除树缓冲区
    if utils.is_win_valid(M.windows.main) then
      -- 切换回聊天缓冲区
      vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
      M.windows.tree = nil -- 树视图已隐藏
      set_window_wrap_inline(M.windows)
      M.setup_buffers()
      -- 删除树缓冲区
      if utils.is_buf_valid(M.tree_buffers.main) then
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
    if utils.is_win_valid(M.windows.tree) then
      -- 将树窗口重新用于显示聊天内容
      vim.api.nvim_win_set_buf(M.windows.tree, M.buffers.main)
      M.windows.main = M.windows.tree
      M.windows.tree = nil
      vim.api.nvim_win_set_width(M.windows.main, math.floor(vim.o.columns * 0.4))
      -- 禁用行号
      vim.api.nvim_set_option_value("number", false, { win = M.windows.main })
      vim.api.nvim_set_option_value("relativenumber", false, { win = M.windows.main })
      set_window_wrap_inline(M.windows)
      M.setup_buffers()
    else
      -- 如果树窗口不存在，创建新的分割窗口
      vim.cmd("belowright vsplit")
      M.windows.main = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
      -- 禁用行号
      vim.api.nvim_set_option_value("number", false, { win = M.windows.main })
      vim.api.nvim_set_option_value("relativenumber", false, { win = M.windows.main })
      set_window_wrap_inline(M.windows)
      M.setup_buffers()
    end
    -- 删除树缓冲区
    if utils.is_buf_valid(M.tree_buffers.main) then
      vim.api.nvim_buf_delete(M.tree_buffers.main, { force = true })
      M.tree_buffers.main = nil
    end
  elseif mode == M.ui_modes.TAB then
    -- 标签页模式：复用当前标签页，只替换缓冲区内容
    if utils.is_win_valid(M.windows.tree) then
      -- 将树窗口重新用于显示聊天内容
      vim.api.nvim_win_set_buf(M.windows.tree, M.buffers.main)
      M.windows.main = M.windows.tree
      M.windows.tree = nil
      set_window_wrap_inline(M.windows)
      M.setup_buffers()
    else
      -- 如果树窗口不存在，创建新的标签页
      vim.cmd("tabnew")
      M.windows.main = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
      set_window_wrap_inline(M.windows)
      M.setup_buffers()
    end
    -- 删除树缓冲区
    if utils.is_buf_valid(M.tree_buffers.main) then
      vim.api.nvim_buf_delete(M.tree_buffers.main, { force = true })
      M.tree_buffers.main = nil
    end
  end

  -- 从树选择后切换到聊天界面：定位光标到输入行
  vim.defer_fn(function()
    if utils.is_win_valid(M.windows.main) and utils.is_buf_valid(M.buffers.main) and M.input_start_line then
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
  utils.ensure_active_session(backend)

  if M.should_show_tree() then
    if not utils.is_buf_valid(M.tree_buffers.main) then
      M.create_tree_buffers()
    end

    -- 先创建主缓冲区（不显示）
    if not utils.is_buf_valid(M.buffers.main) then
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
      if utils.is_win_valid(M.windows.tree) and utils.is_buf_valid(M.tree_buffers.main) then
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
  utils.ensure_active_session(backend)

  if M.should_show_tree() then
    if not utils.is_buf_valid(M.tree_buffers.main) then
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
      if utils.is_win_valid(M.windows.tree) and utils.is_buf_valid(M.tree_buffers.main) then
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
  set_window_wrap_inline(M.windows)
  M.setup_buffers()
  M.is_open = true
  M.current_mode = M.ui_modes.SPLIT

  -- 非树模式：定位光标到输入行
  vim.defer_fn(function()
    if
      M.is_open
      and utils.is_win_valid(M.windows.main)
      and utils.is_buf_valid(M.buffers.main)
      and M.input_start_line
    then
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
  utils.ensure_active_session(backend)

  if M.should_show_tree() then
    -- 先创建主缓冲区（不打开窗口）
    M.create_buffers()

    -- 创建树缓冲区
    if not utils.is_buf_valid(M.tree_buffers.main) then
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
      if utils.is_win_valid(M.windows.tree) and utils.is_buf_valid(M.tree_buffers.main) then
        vim.api.nvim_win_set_cursor(M.windows.tree, { 1, 0 })
      end
    end, 50)
    return
  end

  M.create_buffers()

  vim.cmd("tabnew")
  M.windows.main = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.windows.main, M.buffers.main)
  set_window_wrap_inline(M.windows)
  M.setup_buffers()
  M.is_open = true
  M.current_mode = M.ui_modes.TAB

  -- 非树模式：定位光标到输入行
  vim.defer_fn(function()
    if
      M.is_open
      and utils.is_win_valid(M.windows.main)
      and utils.is_buf_valid(M.buffers.main)
      and M.input_start_line
    then
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
      if not utils.is_win_valid(M.windows.main) or not utils.is_buf_valid(M.buffers.main) then
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
      if cur_line == M.input_start_line and utils.is_buf_valid(M.buffers.main) then
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
      if not utils.is_win_valid(M.windows.main) or not utils.is_buf_valid(M.buffers.main) then
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
      if not utils.is_win_valid(M.windows.main) or not utils.is_buf_valid(M.buffers.main) then
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
      if not utils.is_win_valid(M.windows.main) or not utils.is_buf_valid(M.buffers.main) then
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
  if not utils.is_buf_valid(M.buffers.main) then
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
  if not M.input_start_line or not utils.is_buf_valid(M.buffers.main) then
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
  if not M.input_start_line or not utils.is_buf_valid(M.buffers.main) then
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
  if M.input_start_line and utils.is_buf_valid(M.buffers.main) and utils.is_win_valid(M.windows.main) then
    local line_count = vim.api.nvim_buf_line_count(M.buffers.main)
    local target_line = M.input_start_line + 1 -- +1 因为 cursor 是 1-indexed
    -- 确保输入区域只有 1 行高
    if M.input_end_line and M.input_end_line > M.input_start_line then
      M.input_end_line = M.input_start_line
    end
    -- 边界检查：确保目标行在缓冲区范围内
    if target_line > line_count then
      target_line = math.max(1, line_count)
    end
    pcall(vim.api.nvim_win_set_cursor, M.windows.main, { target_line, 0 })
  end
end

-- ── 快捷键管理 ─────────────────────────────────────────────────────────────

--- 清理快捷键
-- 删除主缓冲区所有模式下的自定义快捷键，避免与其他插件冲突
function M.clear_keymaps()
  if not utils.is_buf_valid(M.buffers.main) then
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
  if not utils.is_win_valid(M.windows.main) then
    return
  end

  local buf = M.buffers.main

  -- 辅助函数：快速绑定缓冲区快捷键
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, noremap = true })
  end

  -- 普通模式：e 键进入编辑模式
  map("n", "e", function()
    if utils.is_win_valid(M.windows.main) then
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
    if utils.is_win_valid(M.windows.main) then
      local cur_line = vim.api.nvim_win_get_cursor(M.windows.main)[1] - 1
      -- 检查当前行是否属于某个有推理内容的消息
      local session = backend.current_session and backend.sessions[backend.current_session]
      if session and session.messages then
        local current_line = 0
        for _, msg in ipairs(session.messages) do
          -- 标题行
          current_line = current_line + 1
          -- 推理内容行
          if
            msg.metadata
            and msg.metadata.has_reasoning
            and msg.metadata.reasoning_content
            and M.config.llm.show_reasoning
          then
            -- 如果光标在推理内容标题行上
            if cur_line == current_line then
              -- 判断推理是否完成：优先使用 reasoning_finished 标记
              local is_complete = msg.metadata.reasoning_finished or not msg.pending

              if is_complete then
                -- 思考完成后：切换折叠状态
                M.toggle_reasoning_fold(msg.id)
              else
                -- 思考中：切换浮动窗口
                if M._reasoning_float_wins[msg.id] then
                  M.close_reasoning_float(msg.id)
                else
                  M.create_reasoning_float_window(msg.id, msg.metadata.reasoning_content, M.windows.main, current_line)
                end
              end

              -- 刷新显示
              M.update_display_debounced.message()
              return
            end
            current_line = current_line + 1
          else
            -- 跳过内容和分隔行
            local content_lines = utils.wrap_message_content(msg.content or "", utils.calculate_text_width() - 4)
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
    if utils.is_win_valid(M.windows.main) then
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
    if utils.is_win_valid(win) then
      utils.safe_win_call(function()
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
    if utils.is_buf_valid(buf) then
      pcall(function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end)
    end
  end

  -- 删除所有树视图缓冲区
  for _, buf in pairs(M.tree_buffers) do
    if utils.is_buf_valid(buf) then
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
    -- 尝试关闭浮动窗口（如果还未关闭的话，幂等操作）
    if data.message and data.message.id and data.message.metadata and data.message.metadata.has_reasoning then
      local msg_id = data.message.id
      M.finish_reasoning(msg_id, true)
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

    -- 光标跟随到输入行
    vim.defer_fn(function()
      M.focus_input_line()
    end, 30)
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)

  -- AI 推理内容更新事件（流式思考过程）：实时更新推理内容显示
  backend.on("ai_reasoning_update", function(data)
    -- 使用新引擎：启动或更新推理浮动窗口
    if M.config.llm.show_reasoning and utils.is_buf_valid(M.buffers.main) and data.message then
      local msg = data.message
      local msg_id = msg.id
      local reasoning_text = msg.metadata and msg.metadata.reasoning_content or ""

      local state = reasoning_engine.states[msg_id]

      -- 如果推理已完成，忽略后续更新（防止浮动窗口重新出现）
      if state and state.phase == "finished" then
        return
      end

      if state and state.phase == "thinking" then
        -- 引擎已在 thinking 阶段，直接更新文本
        M.update_reasoning(msg_id, reasoning_text)
      else
        -- 首次启动：计算锚点行
        local anchor_row = M._reasoning_line_for_msg[msg_id]
        M.start_reasoning(msg_id, M.windows.main, anchor_row)
        M.update_reasoning(msg_id, reasoning_text)
      end

      -- 注意：这里不需要调用 M.update_display()，因为：
      -- 1. update_reasoning 已经更新了浮动窗口内容
      -- 2. 聊天界面的推理标题行不需要实时更新（只在思考完成时更新）
      -- 3. 频繁调用 update_display 会导致整个界面重绘，影响性能

      -- 滚动浮动窗口到底部
      vim.defer_fn(function()
        if msg_id then
          local float_win = M._reasoning_float_wins[msg_id]
          if float_win and vim.api.nvim_win_is_valid(float_win) then
            local buf = vim.api.nvim_win_get_buf(float_win)
            local line_count = vim.api.nvim_buf_line_count(buf)
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

  -- AI 推理完成事件：立即关闭思考浮动窗口
  backend.on("ai_reasoning_finished", function(data)
    if data.message and data.message.id then
      local msg_id = data.message.id
      -- 立即关闭浮动窗口，变为折叠文本
      M.finish_reasoning(msg_id, true)
      M.update_display()
    end
    -- 自动同步数据
    backend.debounce_sync(data.session_id)
  end)

  -- 窗口大小变化时自动更新推理内容宽度
  vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      if M.is_open and utils.is_buf_valid(M.buffers.main) then
        -- 只关闭浮动窗口，但保留推理状态（包括折叠状态）
        for msg_id, state in pairs(reasoning_engine.states) do
          utils.destroy_reasoning_float(reasoning_engine.states, msg_id)
          M._reasoning_float_wins[msg_id] = nil
          M._reasoning_float_buffers[msg_id] = nil
          -- 确保状态中的浮动窗口引用也被清理
          if state then
            state.float_win = nil
            state.float_buf = nil
          end
        end
      end
    end,
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
    if M.should_show_tree() and utils.is_buf_valid(M.tree_buffers.main) then
      vim.schedule(function()
        M.render_session_tree()
        -- 重置光标追踪状态（缓冲区内容已重建）
        if utils.is_win_valid(M.windows.tree) then
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
    if M.should_show_tree() and utils.is_buf_valid(M.tree_buffers.main) then
      vim.schedule(function()
        M.render_session_tree()
        -- 重置光标追踪状态（缓冲区内容已重建）
        if utils.is_win_valid(M.windows.tree) then
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
          if utils.is_buf_valid(M.buffers.main) then
            M._render_chat_interface()
          end

          -- 重新渲染树视图
          if M.should_show_tree() and utils.is_buf_valid(M.tree_buffers.main) then
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
