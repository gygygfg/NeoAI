-- NeoAI 工具函数模块
-- 从 backend.lua 和 ui.lua 提取的通用工具函数

local M = {}

-- ── 文本处理工具 ───────────────────────────────────────────────────────────

--- 清理字符串中的换行符和乱码标记（如 <e5>、<e8><af> 等）
-- @param str 输入字符串
-- @return string 清理后的字符串
function M.sanitize_line(str)
  if not str then
    return ""
  end
  return tostring(str):gsub("[\r\n]+", " "):gsub("<%x%x>", "")
end

--- 文本自动换行
-- @param text 原始文本
-- @param max_width 最大宽度（显示宽度）
-- @return table 换行后的行数组
function M.wrap_text(text, max_width)
  local wrapped = {}
  local current = ""
  local current_width = 0

  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local ch_width = M.display_width(ch)

    if current_width + ch_width <= max_width or current == "" then
      current = current .. ch
      current_width = current_width + ch_width
    else
      table.insert(wrapped, current)
      current = ch
      current_width = ch_width
    end
  end

  if current ~= "" then
    table.insert(wrapped, current)
  end

  return #wrapped > 0 and wrapped or { text }
end

--- 将消息内容按行换行处理
-- @param content 原始内容
-- @param max_width 最大宽度
-- @return table 换行后的行数组
function M.wrap_message_content(content, max_width)
  local result = {}
  for line in content:gmatch("[^\r\n]+") do
    for _, wl in ipairs(M.wrap_text(line, max_width)) do
      table.insert(result, wl)
    end
  end
  return #result > 0 and result or { "" }
end

--- 截断过长的内容（正确支持 UTF-8 多字节字符）
-- @param content 原始内容
-- @param max_chars 最大字符数（中文/英文都算 1 个字符）
-- @return string 截断后的内容
function M.truncate_content(content, max_chars)
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

--- 计算字符串的显示宽度（考虑中文等宽字符）
-- 使用更准确的字符宽度计算，支持中文、英文、标点等
-- @param str 输入字符串
-- @return number 显示宽度
function M.display_width(str)
  if not str or str == "" then
    return 0
  end

  local width = 0
  local pos = 1
  local len = #str

  while pos <= len do
    local byte = str:byte(pos)
    local char_len

    -- 确定 UTF-8 字符字节数
    if byte < 0x80 then
      char_len = 1
      -- ASCII 字符（英文、数字、标点）宽度为 1
      width = width + 1
    elseif byte < 0xE0 then
      char_len = 2
      -- 2字节字符（如拉丁扩展）宽度为 1
      width = width + 1
    elseif byte < 0xF0 then
      char_len = 3
      -- 3字节字符（如中文、日文、韩文）宽度为 2
      width = width + 2
    elseif byte < 0xF8 then
      char_len = 4
      -- 4字节字符（如表情符号）宽度为 2
      width = width + 2
    else
      char_len = 1
      width = width + 1 -- 无效字节，按 1 宽度处理
    end

    pos = pos + char_len
  end

  return width
end

--- 将值限制在指定范围内
-- @param val 输入值
-- @param min_val 最小值
-- @param max_val 最大值
-- @return number 限制后的值
function M.clamp(val, min_val, max_val)
  return math.max(min_val, math.min(val, max_val))
end

--- 根据缩进深度动态计算预览长度（越深的分支越短）
-- @param tree_prefix 树形缩进前缀
-- @param max_chars 最大字符数（默认 20）
-- @return number 预览字符数（范围 5~max_chars）
function M.calc_preview_length(tree_prefix, max_chars)
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

-- ── 窗口/缓冲区验证工具 ────────────────────────────────────────────────────

--- 检查窗口句柄是否有效
-- @param win 窗口句柄
-- @return boolean 是否有效
function M.is_win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

--- 检查缓冲区是否有效
-- @param buf 缓冲区句柄
-- @return boolean 是否有效
function M.is_buf_valid(buf)
  return type(buf) == "number" and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

-- ── 防抖工具 ───────────────────────────────────────────────────────────────

--- 生成唯一的防抖定时器名称
-- @param prefix 前缀标识
-- @return string 唯一的定时器名称（带时间戳）
function M.make_debounce_key(prefix)
  return string.format("%s_%d_%d", prefix, vim.loop.now(), math.random(100000, 999999))
end

-- ── SSE 解析工具 ───────────────────────────────────────────────────────────

--- 解析 SSE (Server-Sent Events) 数据行
-- 从流式响应中提取 "data:" 字段的 JSON 内容
-- @param line SSE 数据行（如 "data: {...}"）
-- @return table? 解析后的 JSON 对象，失败返回 nil
function M.parse_sse_data(line)
  if not line or not line:match("^data:") then
    return nil
  end

  local json_str = line:match("^data:%s*(.+)$")
  if not json_str or json_str == "[DONE]" then
    return nil
  end

  local ok, parsed = pcall(vim.fn.json_decode, json_str)
  if not ok or not parsed then
    return nil
  end

  return parsed
end

--- 从 SSE delta 中提取推理/思考内容（reasoning_content）
-- deepseek-reasoner 等思考模型会在 delta 中返回 reasoning_content 字段
-- @param delta SSE delta 对象
-- @return string? 推理内容片段，无则返回 nil
function M.extract_reasoning_from_delta(delta)
  if not delta then
    return nil
  end
  -- OpenAI 兼容格式：delta.reasoning_content 或 delta.reasoning
  local reasoning = delta.reasoning_content or delta.reasoning
  -- 过滤 vim.NIL（JSON null 值）
  if reasoning and reasoning ~= vim.NIL then
    return tostring(reasoning)
  end
  return nil
end

-- ── 推理内容显示工具 ──────────────────────────────────────────────────────

--- 计算推理内容在UI中占用的行数
-- 思考中：1 行（标题行）
-- 完成后：1 行（标题行）或 1 + 全部行数（展开状态）
-- @param reasoning_text 推理内容字符串
-- @param max_width 最大宽度
-- @param is_complete 思考是否已完成
-- @param message_id 消息ID（用于查询折叠状态）
-- @param is_reasoning_folded_func 判断推理是否折叠的函数（可选）
-- @return number 推理内容显示行数
function M.count_reasoning_display_lines(reasoning_text, max_width, is_complete, message_id, is_reasoning_folded_func)
  if not reasoning_text or reasoning_text == "" then
    return 0
  end

  -- 思考中：只有标题行
  if not is_complete then
    return 1
  end

  -- 思考完成后：查询折叠状态
  local folded = false
  if is_reasoning_folded_func then
    folded = is_reasoning_folded_func(message_id)
  else
    -- 尝试从 ui 模块获取
    local ok, ui = pcall(require, "NeoAI.ui")
    if ok and ui then
      folded = ui.is_reasoning_folded(message_id)
    end
  end

  if folded then
    return 1 -- 仅标题行
  else
    -- 计算内容行数
    local line_count = 0
    for _ in reasoning_text:gmatch("[^\r\n]+") do
      line_count = line_count + 1
    end
    return 1 + line_count -- 标题行 + 全部内容
  end
end

-- ── 窗口计算工具 ──────────────────────────────────────────────────────────

--- 计算窗口实际文本可用宽度（减去装饰列）
-- @param target_win 目标窗口句柄（可选）
-- @return number 文本可用宽度
function M.calculate_text_width(target_win)
  -- 获取窗口宽度（含所有装饰列）
  local win_width = 0
  if target_win and M.is_win_valid(target_win) then
    win_width = vim.api.nvim_win_get_width(target_win)
  end

  if win_width < 1 then
    return 40 -- 默认值
  end

  -- 获取实际文本可用宽度（减去装饰列）
  local text_width = win_width

  if target_win then
    -- 检查是否有边框（边框占用左右各1列）
    -- 注意：只有浮动窗口（relative="editor"或relative="win"）才有边框配置
    local win_config = vim.api.nvim_win_get_config(target_win)
    if win_config and win_config.relative and win_config.relative ~= "" then
      -- 这是浮动窗口，检查边框
      if win_config.border and win_config.border ~= "none" then
        -- 边框占用左右各1列，共2列
        text_width = text_width - 2
      end
    end
    -- 普通分割窗口没有边框配置，不需要减去边框宽度

    -- 行号列宽度
    -- 只有当行号确实显示时才减去行号列宽度
    local number_enabled = vim.api.nvim_get_option_value("number", { win = target_win })
    local relativenumber_enabled = vim.api.nvim_get_option_value("relativenumber", { win = target_win })

    if number_enabled or relativenumber_enabled then
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

-- ── 防抖工具（完整实现） ───────────────────────────────────────────────────

--- 清理指定的防抖定时器
-- @param debounce_timers 防抖定时器表
-- @param timer_name 定时器名称
function M.cleanup_debounce_timer(debounce_timers, timer_name)
  local old_timer = debounce_timers[timer_name]
  if old_timer then
    old_timer:stop()
    if not old_timer:is_closing() then
      old_timer:close()
    end
    debounce_timers[timer_name] = nil
  end
end

--- 清理所有防抖定时器
-- @param debounce_timers 防抖定时器表
function M.cleanup_all_debounce_timers(debounce_timers)
  for name, timer in pairs(debounce_timers) do
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    debounce_timers[name] = nil
  end
end

--- 防抖函数：在指定延迟后执行函数，期间重复调用会重置计时器
-- @param fn 要执行的函数
-- @param delay_ms 延迟时间（毫秒）
-- @param key_prefix 可选的前缀标识（用于区分不同的防抖场景）
-- @param debounce_timers 防抖定时器表（由调用者管理）
-- @return function 包装后的防抖函数
function M.debounce(fn, delay_ms, key_prefix, debounce_timers)
  key_prefix = key_prefix or tostring(fn)

  return function(...)
    local args = { ... }
    -- 生成唯一的定时器名称，避免不同场景共享同一个定时器
    local timer_name = M.make_debounce_key(key_prefix)

    -- 如果提供了 key_prefix，则清理该前缀下的所有旧定时器
    -- 否则仅清理基于函数名的旧定时器（向后兼容）
    if key_prefix ~= tostring(fn) then
      -- 清理同前缀的旧定时器
      for name, _ in pairs(debounce_timers) do
        if name:find("^" .. key_prefix .. "_") then
          M.cleanup_debounce_timer(debounce_timers, name)
        end
      end
    else
      -- 向后兼容：清理基于函数名的旧定时器
      M.cleanup_debounce_timer(debounce_timers, timer_name)
    end

    -- 创建新的计时器
    local timer = assert(vim.loop.new_timer())
    debounce_timers[timer_name] = timer
    timer:start(delay_ms, 0, function()
      vim.schedule(function()
        -- 执行完成后清理定时器引用
        debounce_timers[timer_name] = nil
        fn(unpack(args))
      end)
    end)
  end
end

-- ── 窗口管理工具 ──────────────────────────────────────────────────────────

--- 验证并限制窗口位置和大小
-- @param row 行
-- @param col 列
-- @param width 宽度
-- @param height 高度
-- @return 验证后的行、列、宽度、高度
function M.validate_window_position(row, col, width, height)
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines - (vim.o.cmdheight or 1)

  width = M.clamp(width, 10, editor_width)
  height = M.clamp(height, 5, editor_height)
  row = M.clamp(row, 0, editor_height - height)
  col = M.clamp(col, 0, editor_width - width)

  return row, col, width, height
end

--- 根据窗口模式应用大小限制
-- @param mode 窗口模式
-- @param width 原始宽度
-- @param height 原始高度
-- @param window_limits 窗口限制配置表
-- @return 调整后的宽度和高度
function M.apply_size_limits(mode, width, height, window_limits)
  local limits = window_limits[mode] or window_limits.float
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

--- 设置窗口换行选项
-- @param windows 窗口表
function M.set_window_wrap(windows)
  for _, win in pairs(windows) do
    if M.is_win_valid(win) then
      vim.api.nvim_set_option_value("wrap", true, { win = win })
      vim.api.nvim_set_option_value("linebreak", true, { win = win })
      vim.api.nvim_set_option_value("breakindent", true, { win = win })
      -- 启用折叠功能，使用标记折叠法
      vim.api.nvim_set_option_value("foldmethod", "marker", { win = win })
      vim.api.nvim_set_option_value("foldenable", true, { win = win })
    end
  end
end

--- 清理无效的窗口和缓冲区
-- @param windows 窗口表
-- @param buffers 缓冲区表
-- @param tree_buffers 树缓冲区表
-- @param reasoning_float_wins 推理浮动窗口表
-- @param reasoning_float_buffers 推理浮动缓冲区表
-- @return integer 清理的数量
function M.cleanup_windows(windows, buffers, tree_buffers, reasoning_float_wins, reasoning_float_buffers)
  local cleaned = 0

  local function cleanup_table(t, validator)
    for key, value in pairs(t) do
      if not validator(value) then
        t[key] = nil
        cleaned = cleaned + 1
      end
    end
  end

  cleanup_table(windows, M.is_win_valid)
  cleanup_table(buffers, M.is_buf_valid)
  cleanup_table(tree_buffers, M.is_buf_valid)

  -- 清理推理浮动窗口（由调用者负责关闭）
  cleanup_table(reasoning_float_wins, function(win)
    return win and vim.api.nvim_win_is_valid(win)
  end)
  cleanup_table(reasoning_float_buffers, M.is_buf_valid)

  -- 清理已删除的缓冲区引用
  if not M.is_buf_valid(buffers.main) then
    buffers.main = nil
  end
  if not M.is_buf_valid(tree_buffers.main) then
    tree_buffers.main = nil
  end

  return cleaned
end

--- 计算文本换行后的行数
-- @param content 文本内容
-- @param max_width 最大宽度
-- @return number 行数
function M.count_wrapped_lines(content, max_width)
  if not content or content == "" then
    return 1
  end

  local lines = M.wrap_message_content(content, max_width)
  return #lines
end

-- ── 会话消息工具 ──────────────────────────────────────────────────────────

--- 构建 API 请求的消息列表（包含系统提示和历史上下文）
-- @param session 会话对象
-- @param user_content 用户新消息内容
-- @param llm_config LLM配置
-- @param config 默认配置
-- @return table 消息列表（符合 OpenAI API 格式）
function M.build_api_messages(session, user_content, llm_config, config)
  local messages = {}

  -- 添加系统提示
  local sys_prompt = llm_config and llm_config.system_prompt
  if not sys_prompt and config then
    -- 处理两种配置类型：config 模块或验证后的配置表
    if config.defaults then
      sys_prompt = config.defaults.llm.system_prompt
    elseif config.llm then
      sys_prompt = config.llm.system_prompt
    end
  end
  -- 如果仍然没有获取到，使用空字符串
  sys_prompt = sys_prompt or ""
  if sys_prompt and sys_prompt ~= "" then
    table.insert(messages, {
      role = "system",
      content = sys_prompt,
    })
  end

  -- 添加历史消息（排除最新的用户消息，因为会单独添加）
  local max_history = nil
  if config then
    -- 处理两种配置类型：config 模块或验证后的配置表
    if config.defaults then
      max_history = config.defaults.background.max_history
    elseif config.background then
      max_history = config.background.max_history
    end
  end
  -- 如果仍然没有获取到，使用默认值 100
  max_history = max_history or 100
  local history_count = math.min(#session.messages, max_history - 1)
  local start_idx = math.max(1, #session.messages - history_count + 1)

  for i = start_idx, #session.messages do
    local msg = session.messages[i]
    if msg.role == "user" or msg.role == "assistant" then
      table.insert(messages, {
        role = msg.role,
        content = msg.content or "",
      })
    end
  end

  -- 添加当前用户消息
  table.insert(messages, {
    role = "user",
    content = user_content,
  })

  return messages
end

--- 将消息按对话轮次分组（仅用于树视图）
-- 将扁平的消息列表按"用户消息 + 助手回复"为一组进行聚合
-- 便于在树视图中以对话轮次为单位展示
-- @param messages 消息数组
-- @return table 分组后的对话轮次表
function M.group_messages_into_turns(messages)
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

-- ── 推理显示引擎工具 ──────────────────────────────────────────────────────

--- 获取推理显示状态
-- @param states 状态表
-- @param message_id 消息ID
-- @return table 状态对象
function M.get_reasoning_state(states, message_id)
  if not states[message_id] then
    states[message_id] = {
      phase = "idle",
      float_win = nil,
      float_buf = nil,
      anchor_win = nil,
      anchor_row = nil,
      text = "",
      fold_state = false,
    }
  end
  return states[message_id]
end

--- 清理指定消息的浮动窗口
-- @param states 状态表
-- @param message_id 消息ID
function M.destroy_reasoning_float(states, message_id)
  local state = states[message_id]
  if not state then
    return
  end

  if state.float_win and vim.api.nvim_win_is_valid(state.float_win) then
    vim.api.nvim_win_close(state.float_win, true)
  end
  state.float_win = nil
  state.float_buf = nil
end

--- 创建或更新浮动窗口内容
-- @param state 推理状态对象
-- @param config 推理配置
function M.refresh_reasoning_float(state, config)
  if not state.float_win or not vim.api.nvim_win_is_valid(state.float_win) then
    return
  end

  local buf = state.float_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 缓存上一次的文本，用于比较
  local last_text = state._last_float_text or ""
  local current_text = state.text or ""

  -- 如果文本没有变化，不需要更新
  if last_text == current_text then
    return
  end

  -- 更新缓存
  state._last_float_text = current_text

  -- 格式化文本为行数组（自动换行）
  local width = config.max_width - 2
  local lines = {}
  for line in current_text:gmatch("[^\r\n]+") do
    local cleaned = M.sanitize_line(line)
    local wrapped = M.wrap_text(cleaned, width)
    for _, wl in ipairs(wrapped) do
      table.insert(lines, wl)
    end
  end

  if #lines == 0 then
    table.insert(lines, "思考中...")
  end

  -- 更新缓冲区内容
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- 滚动到底部
  local line_count = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_cursor, state.float_win, { line_count, 0 })
end

-- ── 会话管理工具 ──────────────────────────────────────────────────────────

--- 确保存在活跃会话
-- @param backend 后端模块
-- @return boolean 是否成功
function M.ensure_active_session(backend)
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

--- 防抖同步函数
-- @param sync_func 同步函数
-- @param session_id 会话 ID
-- @param delay_ms 延迟时间（毫秒），默认 500
-- @param timer_ref 定时器引用表
-- @return function 防抖同步函数
function M.create_debounce_sync(sync_func, session_id, delay_ms, timer_ref)
  delay_ms = delay_ms or 500

  return function()
    -- 停止旧的计时器
    if timer_ref.timer then
      timer_ref.timer:stop()
      if not timer_ref.timer:is_closing() then
        timer_ref.timer:close()
      end
    end

    -- 创建新的计时器
    timer_ref.timer = vim.loop.new_timer()
    if timer_ref.timer then
      timer_ref.timer:start(delay_ms, 0, function()
        vim.schedule(function()
          sync_func(session_id)
        end)
      end)
    end
  end
end

-- ── 窗口策略工具 ──────────────────────────────────────────────────────────

--- 获取窗口策略函数
-- 根据不同的窗口模式（浮动、分割、标签、树视图）返回对应的窗口配置生成函数
-- @param mode 窗口模式 (float/split/tab/tree)
-- @param config UI配置
-- @param window_limits 窗口限制配置
-- @return function 窗口策略函数，调用后返回窗口配置表
function M.get_window_strategy(mode, config, window_limits)
  local strategies = {
    -- 浮动窗口策略：在编辑器中央弹出独立窗口
    float = function()
      local width = math.min(config.ui.width, vim.o.columns - 10)
      local height = math.min(config.ui.height, vim.o.lines - 10)
      width, height = M.apply_size_limits("float", width, height, window_limits)

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
        border = config.ui.border, -- 使用配置的边框样式
        style = "minimal", -- 最小化样式，隐藏行号等
        focusable = true, -- 允许获取焦点
      }
    end,

    -- 分割窗口策略：在编辑器右侧打开垂直分割窗口
    split = function()
      local width = math.floor(vim.o.columns * 0.4) -- 默认占屏幕40%宽度
      local height = config.ui.height
      width, height = M.apply_size_limits("split", width, height, window_limits)

      return {
        relative = "editor",
        width = width,
        height = height,
        row = 0,
        col = vim.o.columns - width, -- 靠右对齐
        style = "minimal",
        border = config.ui.border,
      }
    end,

    -- 标签页模式策略：占满整个标签页
    tab = function()
      local width = vim.o.columns
      local height = vim.o.lines
      width, height = M.apply_size_limits("tab", width, height, window_limits)
      return { width = width, height = height }
    end,

    -- 树视图窗口策略：相对于父窗口定位
    tree = function(parent_win, width)
      width = width or 45 -- 增加默认宽度
      width = math.max(width, window_limits.tree.min_width)

      -- 限制树窗口宽度不超过父窗口的指定比例
      if window_limits.tree.max_width_ratio and parent_win and M.is_win_valid(parent_win) then
        local parent_width = vim.api.nvim_win_get_width(parent_win)
        width = math.min(width, math.floor(parent_width * window_limits.tree.max_width_ratio))
      end

      -- 确保最小宽度
      width = math.max(width, 45)

      return {
        relative = "win", -- 相对于指定窗口
        win = parent_win,
        width = width,
        height = math.min(config.ui.height, vim.o.lines - 10),
        row = 0,
        col = 0, -- 与父窗口左上角对齐
        style = "minimal",
        border = config.ui.border,
        focusable = true,
      }
    end,
  }

  return strategies[mode]
end

--- 调整窗口大小（根据内容自动计算）
-- @param windows 窗口表
-- @param current_mode 当前模式
-- @param content_width 内容宽度
-- @param content_height 内容高度
-- @param window_limits 窗口限制配置
function M.adjust_window_size(windows, current_mode, content_width, content_height, window_limits)
  if not M.is_win_valid(windows.main) then
    return
  end

  local editor_w = vim.o.columns
  local editor_h = vim.o.lines

  -- 浮动模式：居中显示，自动调整大小
  if current_mode == "float" then
    local w = M.clamp(content_width + 6, 50, math.min(math.floor(editor_w * 0.85), 140))
    local h = M.clamp(content_height + 6, 8, math.min(editor_h - 6, 45))
    w, h = M.apply_size_limits("float", w, h, window_limits)

    local row = math.max(0, math.floor((editor_h - h) / 2))
    local col = math.max(0, math.floor((editor_w - w) / 2))
    row, col, w, h = M.validate_window_position(row, col, w, h)

    pcall(function()
      vim.api.nvim_win_set_config(windows.main, {
        relative = "editor",
        row = row,
        col = col,
        width = w,
        height = h,
      })
    end)
  -- 分割模式：调整宽度
  elseif current_mode == "split" then
    local w = M.clamp(content_width + 6, 40, math.min(math.floor(editor_w * 0.6), 120))
    w = M.apply_size_limits("split", w, editor_h, window_limits)

    pcall(function()
      vim.api.nvim_win_set_width(windows.main, w)
    end)
  end
  -- 标签模式由Neovim自动管理
end

--- 调整树窗口大小（动态宽度，最大值为屏幕一半）
-- @param windows 窗口表
-- @param tree_buffers 树缓冲区表
-- @param window_limits 窗口限制配置
function M.adjust_tree_window_size(windows, tree_buffers, window_limits)
  if not M.is_win_valid(windows.tree) or not M.is_buf_valid(tree_buffers.main) then
    return
  end

  local editor_w = vim.o.columns
  local max_width = math.floor(editor_w * 0.5)

  -- 计算树内容的最大宽度
  local lines = vim.api.nvim_buf_get_lines(tree_buffers.main, 0, -1, false)
  local max_w = 0

  for _, line in ipairs(lines) do
    local width = M.display_width(line)
    max_w = math.max(max_w, width)
  end

  -- 动态宽度 = 内容宽度 + 边距，但不超过屏幕一半
  local target = math.min(max_w + 10, max_width)
  target = M.clamp(target, window_limits.tree.min_width, max_width)

  local current_w = vim.api.nvim_win_get_width(windows.tree)
  if target ~= current_w then
    pcall(function()
      vim.api.nvim_win_set_width(windows.tree, target)
    end)
  end
end

--- 设置窗口
-- 打开主聊天窗口并初始化相关组件（缓冲区、快捷键、输入处理）
-- 完成后自动将光标定位到输入行并进入插入模式
-- @param windows 窗口表
-- @param buffers 缓冲区表
-- @param win_opts 窗口配置选项表
-- @param setup_buffers_func 设置缓冲区的函数
-- @param set_window_wrap_func 设置窗口换行的函数
function M.setup_windows(windows, buffers, win_opts, setup_buffers_func, set_window_wrap_func)
  windows.main = vim.api.nvim_open_win(buffers.main, true, win_opts)
  set_window_wrap_func(windows)
  setup_buffers_func()

  -- 异步等待渲染完成后将光标定位到输入提示行
  vim.defer_fn(function()
    if M.is_win_valid(windows.main) and M.is_buf_valid(buffers.main) then
      -- 确保输入行可编辑
      vim.api.nvim_set_option_value("modifiable", true, { buf = buffers.main })
      vim.api.nvim_set_option_value("readonly", false, { buf = buffers.main })

      -- 定位到输入行
      if windows.input_start_line then
        local cursor_line = windows.input_start_line + 1 -- +1 因为 cursor 是 1-indexed
        vim.api.nvim_win_set_cursor(windows.main, { cursor_line, 0 })
        vim.cmd("normal! zb")
        -- 进入插入模式准备输入
        vim.cmd("startinsert")
      end
    end
  end, 100) -- 100ms 延迟确保渲染完成
end

--- 创建一条新消息
-- @param role 角色类型 (user/assistant/system)
-- @param content 消息内容
-- @param timestamp 时间戳（可选，默认为当前时间）
-- @param metadata 附加元数据（可选）
-- @return table 消息对象
function M.create_message(role, content, timestamp, metadata)
  return {
    id = os.time() .. math.random(1000, 9999), -- 唯一 ID
    role = role,
    content = content,
    timestamp = timestamp or os.time(),
    metadata = metadata or {},
    editable = false, -- 是否可编辑
    pending = false, -- 是否正在等待 AI 回复
  }
end

-- ── 分隔线工具 ────────────────────────────────────────────────────────────

--- 分隔线字符映射表
M.SEPARATOR_CHARS = { single = "─", double = "═", solid = "━", dotted = "┈", dashed = "┄" }

--- 生成分隔线字符串
-- @param separator_type 分隔线类型（single/double/solid/dotted/dashed）
-- @param length 分隔线长度
-- @param config UI配置（可选，用于获取默认分隔线类型）
-- @return string 分隔线字符串
function M.generate_separator(separator_type, length, config)
  local char = M.SEPARATOR_CHARS[separator_type] or "─"

  -- 如果提供了配置，尝试从配置中获取分隔线类型
  if config and config.ui and config.ui.input_separator then
    char = M.SEPARATOR_CHARS[config.ui.input_separator] or char
  end

  return string.rep(char, length)
end

--- 为缓冲区添加分隔线虚拟文本
-- @param buf 缓冲区句柄
-- @param line_num 行号（0-indexed）
-- @param max_width 最大宽度
-- @param separator_type 分隔线类型（可选）
-- @param config UI配置（可选）
-- @param ns_id 命名空间ID（可选，不提供则创建新命名空间）
-- @return number 命名空间ID
function M.add_separator_virtual_text(buf, line_num, max_width, separator_type, config, ns_id)
  if not M.is_buf_valid(buf) then
    return nil
  end

  ns_id = ns_id or vim.api.nvim_create_namespace("NeoAISeparator")
  local separator_text = M.generate_separator(separator_type, max_width, config)

  vim.api.nvim_buf_set_extmark(buf, ns_id, line_num, 0, {
    virt_text = { { separator_text, "Comment" } },
    virt_text_pos = "overlay",
  })

  return ns_id
end

--- 为缓冲区添加分隔线实际文本
-- @param buf 缓冲区句柄
-- @param line_num 行号（0-indexed）
-- @param max_width 最大宽度
-- @param separator_type 分隔线类型（可选）
-- @param config UI配置（可选）
-- @return boolean 是否成功
function M.add_separator_actual_text(buf, line_num, max_width, separator_type, config)
  if not M.is_buf_valid(buf) then
    return false
  end

  local separator_text = M.generate_separator(separator_type, max_width, config)

  -- 确保缓冲区可修改
  local was_modifiable = vim.api.nvim_get_option_value("modifiable", { buf = buf })
  local was_readonly = vim.api.nvim_get_option_value("readonly", { buf = buf })

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = buf })

  -- 插入分隔线
  vim.api.nvim_buf_set_lines(buf, line_num, line_num + 1, false, { separator_text })

  -- 恢复原始状态
  vim.api.nvim_set_option_value("modifiable", was_modifiable, { buf = buf })
  vim.api.nvim_set_option_value("readonly", was_readonly, { buf = buf })

  return true
end

return M
