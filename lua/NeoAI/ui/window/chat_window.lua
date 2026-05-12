local M = {}

local logger = require("NeoAI.utils.logger")
local window_manager = require("NeoAI.ui.window.window_manager")
local virtual_input = require("NeoAI.ui.components.virtual_input")
local Events = require("NeoAI.core.events")
local state_manager = require("NeoAI.core.config.state")

-- 模块级引用（避免函数内重复 require）
local chat_handlers = require("NeoAI.ui.handlers.chat_handlers")
local tool_pack = require("NeoAI.tools.tool_pack")
local config_merger = require("NeoAI.core.config.merger")
local async_worker = require("NeoAI.utils.async_worker")
local core = require("NeoAI.core")
local chat_service = require("NeoAI.core.ai.chat_service")
local approval_config_editor = require("NeoAI.ui.components.approval_config_editor")
local history_manager = require("NeoAI.core.history.manager")
local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
-- 所有悬浮窗组件通过 window_manager 和 window/components 管理
local reasoning_display = require("NeoAI.ui.components.reasoning_display")
local tool_display_component = require("NeoAI.ui.components.tool_display")
local file_utils = require("NeoAI.utils.file_utils")

-- ========== 辅助函数（不依赖 state） ==========

local function buf_valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function set_buf_modifiable(buf, modifiable)
  if not buf_valid(buf) then
    return
  end
  pcall(vim.api.nvim_set_option_value, "modifiable", modifiable, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "readonly", not modifiable, { buf = buf })
end

local function get_line_count(buf)
  return buf_valid(buf) and vim.api.nvim_buf_line_count(buf) or 0
end

local function get_last_line(buf)
  if not buf_valid(buf) then
    return ""
  end
  local lc = vim.api.nvim_buf_line_count(buf)
  if lc == 0 then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(buf, lc - 1, lc, false)
  return lines[1] or ""
end

local function cursor_near_end(win)
  if not win_valid(win) then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local total = get_line_count(vim.api.nvim_win_get_buf(win))
  return total - cursor[1] <= 5
end

local function scroll_to_end(win, buf)
  if not win_valid(win) or not buf_valid(buf) then
    return
  end
  local lc = vim.api.nvim_buf_line_count(buf)
  if lc > 0 then
    pcall(vim.api.nvim_win_call, win, function()
      local height = vim.api.nvim_win_get_height(win)
      local view = vim.fn.winsaveview()
      view.topline = math.max(1, lc - height + 1)
      vim.fn.winrestview(view)
    end)
  end
end

local function move_cursor_to_end(win, buf)
  if not win_valid(win) or not buf_valid(buf) then
    return
  end
  local lc = vim.api.nvim_buf_line_count(buf)
  if lc > 0 then
    local last_line = get_last_line(buf)
    pcall(vim.api.nvim_win_set_cursor, win, { lc, #last_line })
  end
end

local function fire_event(pattern, data)
  vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = data or {} })
end

--- 验证 buffer 是否为 NeoAI 聊天 buffer
--- 防止在窗口关闭后异步回调将内容写入到其他 buffer
--- @param buf number|nil buffer 句柄
--- @return boolean
local function _is_chat_buffer(buf)
  if not buf_valid(buf) then
    return false
  end
  local ok, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
  return ok and ft == "neoai"
end

-- 模块状态
local state = {
  initialized = false,
  current_window_id = nil, -- 当前聊天窗口的窗口ID
  current_session_id = nil, -- 当前聊天窗口关联的会话ID
  chat_buf = nil, -- 当前聊天窗口的 buffer 句柄（供 virtual_input 检测光标离开时使用）
  messages = {},
  cursor_augroup = nil, -- 光标移动自动命令组
  last_render_time = 0, -- 上次渲染时间
  render_debounce_timer = nil, -- 防抖定时器

  -- 当前场景内使用的模型候选索引（1-based）
  current_model_index = 1,

  -- 最近一次生成的 token 用量信息
  last_usage = nil,
  -- token 用量虚拟文本的 extmark id，用于清理旧虚拟文本
  usage_extmark_id = nil,

  -- 窗口正在关闭标记（阻止异步回调继续执行）
  closing = false,

  -- 流式渲染状态
  streaming = {
    active = false,
    generation_id = nil,
    message_index = nil, -- 当前正在流式更新的消息索引
    content_buffer = "", -- 累积的流式内容
    reasoning_buffer = "", -- 累积的思考内容
    reasoning_active = false, -- 是否正在输出思考内容
    reasoning_done = false, -- 思考内容是否已完成
    prefix_added = false, -- 是否已在缓冲区添加 AI 前缀行（分割线 + "🤖 AI:"）
    reasoning_prefix_added = false, -- 是否已在缓冲区添加思考标记行（"🤔 思考过程:"）
    content_separator_added = false, -- 是否已在思考内容和正文之间添加分割线
    _reasoning_display_timer = nil, -- 延迟打开 reasoning_display 的定时器
    message_start_line = nil, -- 当前流式消息在缓冲区中的起始行号（0-based），用于替换渲染
  },

  -- 工具调用悬浮显示状态
  tool_display = {
    active = false,
    -- 工具调用窗口 ID（由 window_manager 管理）
    window_id = nil,
    -- 实时参数预览窗口 ID（由 window_manager 管理）
    preview_window_id = nil,
    buffer = "", -- 累积的工具调用内容
    results = {}, -- 所有工具调用结果，用于生成折叠文本
    folded_saved = false, -- 标记折叠文本是否已保存到 state.messages
    -- 工具包分组显示支持
    packs = {}, -- { pack_name = { tools = { { name, status, duration, substeps = {} } }, order = n } }
    pack_order = {}, -- 有序的包名列表
    -- 子步骤显示支持
    substeps = {}, -- { [tool_name] = { { name, status, duration, detail } } }

    -- 防抖定时器，避免高频更新卡主线程
    _debounce_timer = nil,
    -- 上次更新的 buffer 内容缓存，用于增量更新
    _last_buffer = "",

    -- 流式工具调用预览（在 TOOL_LOOP_STARTED 前提前显示）
    streaming_preview = {
      timer = nil, -- 节流定时器
      generation_id = nil, -- 当前流式 generation_id
      tools = {}, -- { [tool_name] = { name, arguments (累积字符串), args_display (解析后的 table) } }
      window_shown = false, -- 是否已提前打开悬浮窗
      _pending_append = "", -- 待追加的增量文本累积
    },
  },

  -- 生成进行中标志
  -- 在 GENERATION_STARTED 中设为 true，在 GENERATION_COMPLETED/GENERATION_CANCELLED 中设为 false
  -- 用于阻止生成过程中打开虚拟输入框
  generation_in_progress = false,

  -- 工具调用循环进行中标志
  -- 在 TOOL_LOOP_STARTED 中设为 true，在 GENERATION_COMPLETED 中设为 false
  -- 用于阻止工具循环过程中打开虚拟输入框
  tool_loop_in_progress = false,

  -- 流式数据块节流状态
  --- @type { buffer: string, timer: vim.uv_timer_t|nil, pending: boolean, interval_ms: number }
  stream_throttle = {
    buffer = "",
    timer = nil,
    pending = false,
    interval_ms = 50, -- 每50ms批量处理一次
  },

  -- 光标跟随防抖状态
  -- 在 buffer 内容变化或工具调用悬浮窗打开时设置 pending，延迟后执行光标跳转
  cursor_follow = {
    pending = false,
    timer = nil,
  },

  -- 光标跟随标志（存储在模块级 state 表，避免协程共享表跨协程访问问题）
  -- true: 光标在末尾附近（后5行内），新内容写入时应自动跟随
  -- false: 光标不在末尾附近，不跟随
  should_follow = true,
}

-- ========== 依赖 state 的辅助函数 ==========

local function is_current_window(window_id)
  return not window_id or window_id == state.current_window_id
end

local function get_buf()
  return state.current_window_id and window_manager.get_window_buf(state.current_window_id) or nil
end

local function get_win()
  return state.current_window_id and window_manager.get_window_win(state.current_window_id) or nil
end

local function cancel_reasoning_timer()
  local t = state.streaming._reasoning_display_timer
  if t then
    pcall(t.stop, t)
    pcall(t.close, t)
    state.streaming._reasoning_display_timer = nil
  end
end

local function clear_stream_throttle()
  local t = state.stream_throttle.timer
  if t then
    t:stop()
    t:close()
  end
  state.stream_throttle.timer = nil
  state.stream_throttle.buffer = ""
  state.stream_throttle.pending = false
end

local function reset_streaming_state()
  cancel_reasoning_timer()
  clear_stream_throttle()
  local s = state.streaming
  s.active = false
  s.generation_id = nil
  s.message_index = nil
  s.content_buffer = ""
  s.reasoning_buffer = ""
  s.reasoning_active = false
  s.reasoning_done = false
  s.prefix_added = false
  s.reasoning_prefix_added = false
  s.content_separator_added = false
  s.message_start_line = nil
end

local function reset_tool_display()
  -- 通过 tool_display_component 统一管理
  tool_display_component.reset()
  -- 同步更新本地状态
  state.tool_display.active = false
  state.tool_display.buffer = ""
  state.tool_display.results = {}
  state.tool_display.folded_saved = false
  state.tool_display.substeps = {}
  state.tool_display._last_buffer = ""
  state.tool_display.window_id = nil
  state.tool_display.preview_window_id = nil
  state.tool_display.streaming_preview.timer = nil
  state.tool_display.streaming_preview.generation_id = nil
  state.tool_display.streaming_preview.tools = {}
  state.tool_display.streaming_preview.window_shown = false
end

local function close_reasoning_display()
  if reasoning_display.is_visible() then
    reasoning_display.close()
  end
end

local function close_tool_display()
  -- 通过 tool_display_component 关闭
  tool_display_component._close_display()
  state.tool_display.window_id = nil
end

--- 格式化 table 为多行字符串，强制每个元素换行显示
--- 避免 vim.inspect 将短数组合并为一行
--- @param t table
--- @param indent string 缩进前缀
--- @return string
local function _format_table_for_fold(t, indent)
  indent = indent or ""
  if type(t) == "string" then
    -- 如果字符串包含换行，使用多行格式
    if t:find("\n") then
      local lines = vim.split(t, "\n")
      local parts = {}
      for _, line in ipairs(lines) do
        table.insert(parts, indent .. "  " .. line)
      end
      return table.concat(parts, "\n")
    end
    return string.format("%q", t)
  end
  if type(t) ~= "table" then
    return tostring(t)
  end

  -- 估算 table 大小：如果元素超过 500 个，回退到单行 JSON 格式
  -- 避免生成超大折叠文本导致性能问题和界面卡顿
  local count = 0
  for _ in pairs(t) do
    count = count + 1
    if count > 500 then
      -- 超过 500 个元素，使用 JSON 编码单行显示
      local ok, encoded = pcall(vim.json.encode, t)
      if ok then
        return encoded
      end
      break
    end
  end

  -- 判断是数组还是字典
  local is_array = true
  local max_key = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
      is_array = false
      break
    end
    if k > max_key then
      max_key = k
    end
  end
  if is_array and max_key == #t then
    -- 数组：每个元素换行
    local parts = { "{" }
    for i, v in ipairs(t) do
      local val_str = _format_table_for_fold(v, indent .. "  ")
      table.insert(parts, indent .. "  " .. val_str .. ",")
    end
    table.insert(parts, indent .. "}")
    return table.concat(parts, "\n")
  else
    -- 字典：每个键值对换行
    local parts = { "{" }
    -- 排序键
    local keys = {}
    for k, _ in pairs(t) do
      table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then
        return tostring(a) < tostring(b)
      end
      return type(a) < type(b)
    end)
    for _, k in ipairs(keys) do
      local v = t[k]
      local key_str = type(k) == "string" and k or "[" .. tostring(k) .. "]"
      local val_str = _format_table_for_fold(v, indent .. "  ")
      table.insert(parts, indent .. "  " .. key_str .. " = " .. val_str .. ",")
    end
    table.insert(parts, indent .. "}")
    return table.concat(parts, "\n")
  end
end

--- 截断过长的内容，限制在 200 行以内
--- 如果超过 200 行，只保留前 200 行并添加截断提示
--- 用于折叠文本中的结果渲染，避免超大折叠文本导致界面卡顿
--- @param content string 原始内容
--- @param max_lines number|nil 最大行数，默认 200
--- @return string 截断后的内容
local function _truncate_content_for_fold(content, max_lines)
  max_lines = max_lines or 200
  if not content or content == "" then
    return content or ""
  end
  local lines = vim.split(content, "\n")
  if #lines <= max_lines then
    return content
  end
  local truncated = {}
  for i = 1, max_lines do
    table.insert(truncated, lines[i])
  end
  local remaining = #lines - max_lines
  table.insert(truncated, string.format("... [已截断，剩余 %d 行未显示]", remaining))
  return table.concat(truncated, "\n")
end

--- 格式化折叠文本 }}} 后的剩余内容（AI 总结正文）
--- 处理 JSON 格式的 content/reasoning_content，返回格式化后的行列表
--- @param content string 剩余内容文本
--- @return table 格式化后的行列表
local function _format_remaining_content(content)
  if not content or content == "" then
    return {}
  end
  local lines = {}
  -- 尝试解析 JSON 格式
  local json_ok, parsed = pcall(vim.json.decode, content)
  if json_ok and type(parsed) == "table" then
    local main_content = ""
    if parsed.content ~= nil then
      main_content = parsed.content
    end
    local reasoning_content = parsed.reasoning_content or ""
    if type(main_content) ~= "string" then
      local ok, encoded = pcall(vim.json.encode, main_content)
      main_content = ok and encoded or tostring(main_content)
    end
    if type(reasoning_content) ~= "string" then
      local ok, encoded = pcall(vim.json.encode, reasoning_content)
      reasoning_content = ok and encoded or tostring(reasoning_content)
    end
    if reasoning_content ~= "" then
      table.insert(lines, "🤖 AI: 🤔 思考过程:")
      for _, rline in ipairs(vim.split(reasoning_content, "\n")) do
        table.insert(lines, "    " .. rline)
      end
      table.insert(lines, "")
    end
    if main_content ~= "" then
      local msg_lines = vim.split(main_content, "\n")
      table.insert(lines, string.format("🤖 AI: %s", msg_lines[1]))
      for i = 2, #msg_lines do
        table.insert(lines, string.format("    %s", msg_lines[i]))
      end
    end
  else
    -- 非 JSON 格式，直接作为普通文本显示
    local msg_lines = vim.split(content, "\n")
    table.insert(lines, string.format("🤖 AI: %s", msg_lines[1]))
    for i = 2, #msg_lines do
      table.insert(lines, string.format("    %s", msg_lines[i]))
    end
  end
  return lines
end

--- 更新 buffer 中已有的折叠文本内容
--- 找到 buffer 中第一个 {{{ 到最后一个 }}} 的范围，替换为新的折叠文本
--- 在 buffer 内容变化之前检测光标是否在末尾附近（后5行内）
--- 调用方必须在修改 buffer 内容之前调用此函数，将结果缓存到协程共享表
--- 这样即使内容变化后 foldmethod=marker 改变了光标位置，也能正确判断是否应该跟随
local function _check_cursor_near_end()
  if not state.current_window_id then
    state.should_follow = false
    state_manager.set_shared("should_follow", false)
    return false
  end
  local win = window_manager.get_window_win(state.current_window_id)
  if not win or not vim.api.nvim_win_is_valid(win) then
    state.should_follow = false
    state_manager.set_shared("should_follow", false)
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local total = vim.api.nvim_buf_line_count(buf)
  local near_end = total - cursor[1] <= 5
  state.should_follow = near_end
  state_manager.set_shared("should_follow", near_end)
  return near_end
end

--- 执行光标跟随：将光标跳转到缓冲区末尾并滚动到窗口最底部
--- 先追加一个空行到末尾（空行不在任何 {{{...}}} 折叠区域内），再将光标设置到空行上
--- 插入空行前临时提高 foldlevel，防止 foldmethod=marker 将光标吸到折叠开始行
--- 使用协程共享表 should_follow 判断是否应该跟随（在 buffer 内容变化前已缓存）
local function _do_cursor_follow()
  if not state.should_follow then
    return
  end
  if not state.current_window_id then
    return
  end
  local win = window_manager.get_window_win(state.current_window_id)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lc = vim.api.nvim_buf_line_count(buf)
  local last_line = vim.api.nvim_buf_get_lines(buf, lc - 1, lc, false)[1] or ""
  if last_line == "}}}" then
    -- 最后一行是折叠结束标记 }}}，在它之后追加一个空行并将光标设置在空行上
    -- 这样光标在折叠区域之后的可视位置，不会被 foldmethod=marker 吸到折叠开始行
    -- 插入空行前临时提高 foldlevel，防止 foldmethod=marker 在插入后立即将光标吸到折叠开始行
    local saved_foldlevel = vim.api.nvim_get_option_value("foldlevel", { win = win })
    vim.api.nvim_set_option_value("foldlevel", 999, { win = win })
    set_buf_modifiable(buf, true)
    vim.api.nvim_buf_set_lines(buf, lc, lc, false, { "" })
    lc = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 })
    -- 恢复 foldlevel，使用 vim.schedule 延迟恢复，确保光标已稳定
    vim.schedule(function()
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_option_value("foldlevel", saved_foldlevel, { win = win })
      end
    end)
  else
    -- 普通内容：直接设置光标到最后一行末尾
    pcall(vim.api.nvim_win_set_cursor, win, { lc, #last_line })
  end
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! zb")
  end)
end

--- 安排光标跟随
--- @param delay_ms number|nil 延迟毫秒数，默认 0（使用 vim.schedule 下一个 tick 执行）
--- 内容写入后立即调用（delay_ms=0），工具调用悬浮窗打开后传 150ms
--- 注意：调用方必须在修改 buffer 内容之前调用 _check_cursor_near_end() 缓存光标状态
--- 此函数不再重新检测光标位置，直接使用协程共享表 should_follow 缓存值
local function _schedule_cursor_follow(delay_ms)
  if not state.current_window_id then
    return
  end
  if not state.should_follow then
    -- 光标不在后5行内（已在 buffer 内容变化前检测并缓存），不跟随
    return
  end
  delay_ms = delay_ms or 0
  if delay_ms > 0 then
    -- 防抖模式：取消旧定时器，启动新定时器
    state.cursor_follow.pending = true
    if state.cursor_follow.timer then
      pcall(state.cursor_follow.timer.stop, state.cursor_follow.timer)
      pcall(state.cursor_follow.timer.close, state.cursor_follow.timer)
      state.cursor_follow.timer = nil
    end
    state.cursor_follow.timer = vim.loop.new_timer()
    state.cursor_follow.timer:start(
      delay_ms,
      0,
      vim.schedule_wrap(function()
        if not state.cursor_follow.pending then
          return
        end
        state.cursor_follow.pending = false
        if state.cursor_follow.timer then
          pcall(state.cursor_follow.timer.close, state.cursor_follow.timer)
          state.cursor_follow.timer = nil
        end
        _do_cursor_follow()
      end)
    )
  else
    -- 立即模式：直接执行，不再通过 vim.schedule 延迟
    -- 因为 should_follow 已在 buffer 内容变化前缓存，无需等待下一个 tick
    _do_cursor_follow()
  end
end

--- 更新 buffer 中已有的折叠文本内容
--- 找到 buffer 中第一个 {{{ 到最后一个 }}} 的范围，替换为新的折叠文本
--- @param folded_text string 新的折叠文本
--- @param window_id string|nil 可选，指定目标窗口 ID
local function _update_folded_text_in_buffer(folded_text, window_id)
  local target_window_id = window_id or state.current_window_id
  if not target_window_id or not folded_text or folded_text == "" then
    return
  end

  local buf = window_manager.get_window_buf(target_window_id)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  if not _is_chat_buffer(buf) then
    return
  end

  -- 查找 buffer 中第一个 {{{ 和最后一个 }}}
  local lc = vim.api.nvim_buf_line_count(buf)
  local start_line = nil
  local end_line = nil
  for i = 0, lc - 1 do
    local line = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or ""
    if not start_line and line:find("^{{{") then
      start_line = i
    end
    if line == "}}}" then
      end_line = i
    end
  end

  if start_line == nil or end_line == nil then
    return
  end

  -- 使用 _render_single_message 生成新的折叠文本行
  local msg = { role = "assistant", content = folded_text }
  local new_lines = M._render_single_message(msg, nil)
  if #new_lines == 0 then
    return
  end

  -- 在修改 buffer 内容之前缓存光标位置
  _check_cursor_near_end()
  set_buf_modifiable(buf, true)

  -- 替换从 start_line 到 end_line+1（包含 }}} 行）的内容
  local old_count = end_line + 1 - start_line
  local new_count = #new_lines
  if new_count > old_count then
    local insert_count = new_count - old_count
    local insert_lines = {}
    for _ = 1, insert_count do
      table.insert(insert_lines, "")
    end
    vim.api.nvim_buf_set_lines(buf, end_line + 1, end_line + 1, false, insert_lines)
  elseif new_count < old_count then
    local delete_count = old_count - new_count
    vim.api.nvim_buf_set_lines(buf, end_line + 1 - delete_count, end_line + 1, false, {})
  end
  vim.api.nvim_buf_set_lines(buf, start_line, start_line + new_count, false, new_lines)
  vim.api.nvim_set_option_value("modified", false, { buf = buf })

  _schedule_cursor_follow()
end

local function get_chat_service()
  if chat_service and chat_service.is_initialized then
    return chat_service
  end
  return nil
end

local function get_config_merger()
  return config_merger
end

--- 初始化聊天窗口
--- @param config table 配置
function M.initialize(config)
  if state.initialized then
    return
  end
  state.initialized = true

  -- 初始化虚拟输入组件
  virtual_input.initialize(config)

  -- 注册AI响应事件监听器
  M._setup_event_listeners()
end

--- 打开聊天窗口
--- @param session_id string 会话ID
--- @param window_id string 窗口ID（必须由调用者通过 window_manager 创建）
--- @param branch_id string 分支ID（可选，仅用于兼容旧版本）
--- @return boolean 是否成功
function M.open(session_id, window_id, branch_id)
  if not state.initialized then
    error("Chat window not initialized")
  end

  -- 检查 window_id 参数
  if not window_id or type(window_id) ~= "string" then
    error("window_id parameter is required and must be a string")
  end

  -- 验证窗口ID格式
  if not window_id:match("^win_") then
    error("Invalid window_id format. Must start with 'win_'")
  end

  -- 如果已有窗口，先关闭（同步清理状态，不等待 defer_fn）
  if state.current_window_id then
    local old_id = state.current_window_id
    -- 立即清理状态，防止后续操作冲突
    state.closing = true
    -- 触发取消生成事件
    vim.api.nvim_exec_autocmds("User", { pattern = Events.CANCEL_GENERATION, data = {} })
    -- 关闭窗口
    window_manager.close_window(old_id)
    -- 重置流式状态
    reset_streaming_state()
    reset_tool_display()
    state.tool_loop_in_progress = false
    state.current_window_id = nil
    state.current_session_id = nil
    state.chat_buf = nil
    state.messages = {}
    state.last_usage = nil
    state.usage_extmark_id = nil
    state.closing = false
  end

  -- 处理旧版本兼容
  if branch_id and type(branch_id) == "string" and branch_id:match("^win_") then
    window_id = branch_id
    branch_id = "main"
  end

  state.current_window_id = window_id
  state.current_session_id = session_id -- 可能为 nil（用户尚未发送消息，会话未创建）
  state.messages = {}

  -- 获取缓冲区并快速设置关键选项
  local buf = window_manager.get_window_buf(window_id)
  local win_handle = window_manager.get_window_win(window_id)

  if buf and vim.api.nvim_buf_is_valid(buf) then
    -- 批量设置 buffer 选项（合并 API 调用）
    local buf_opts = {
      filetype = "neoai",
      buflisted = true,
      buftype = "nofile",
      swapfile = false,
      bufhidden = "hide",
      modified = false,
    }
    for name, val in pairs(buf_opts) do
      pcall(vim.api.nvim_set_option_value, name, val, { buf = buf })
    end
    pcall(vim.api.nvim_buf_set_var, buf, "neoai_no_lsp", true)
    pcall(vim.diagnostic.disable, buf)
    pcall(vim.api.nvim_buf_set_name, buf, "neoai://chat/" .. (session_id or "new"))

    -- 保存到模块 state 表，供 virtual_input 检测光标离开时使用
    state.chat_buf = buf
  end

  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    -- 批量设置窗口选项
    local win_opts = {
      wrap = true,
      linebreak = true,
      cursorline = true,
      foldmethod = "marker",
      foldmarker = "{{{,}}}",
      foldlevel = 0,
    }
    for name, val in pairs(win_opts) do
      pcall(vim.api.nvim_set_option_value, name, val, { win = win_handle })
    end
  end

  -- 阻止 LSP（异步执行，不阻塞窗口显示）
  vim.schedule(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      window_manager.block_lsp_for_buffer(buf, "chat_window")
    end
  end)

  -- 设置光标移动监听（检测用户手动移动光标到非末尾位置时取消跟随）
  M._setup_cursor_moved_listener()

  -- 触发窗口打开事件
  vim.api.nvim_exec_autocmds("User", { pattern = Events.WINDOW_OPENED, data = { window_id = window_id } })

  -- 设置按键映射
  M.set_keymaps()

  -- 获取焦点（仅在当前焦点不在其他非 NeoAI 窗口时聚焦）
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_win_get_buf(current_win)
  local ok_ft, current_ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = current_buf })
  if ok_ft and (current_ft == "neoai" or current_ft == "NeoAIInput") then
    M._focus_window()
  end

  -- 获取窗口的协程上下文（由 window_manager.create_window 创建）
  -- 后续所有协程内共享变量通过此上下文隔离
  local ctx = window_manager.get_window_context(window_id)

  -- 先显示一个简单的欢迎界面，让用户立即看到窗口
  local welcome_content = {
    "# NeoAI 聊天",
    "",
    "加载中...",
    "",
  }
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
    pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = buf })
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, welcome_content)
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
  end

  -- 异步加载所有内容
  vim.schedule(function()
    if state.closing or state.current_window_id ~= window_id then
      return
    end

    -- 在窗口的协程上下文中执行初始化操作
    -- 确保协程内共享变量（如 session_id、window_id 等）正确隔离
    local init_fn = function()
      -- 将 session_id 同步到协程共享表，供后续事件处理等场景使用
      if session_id and ctx then
        state_manager.set_shared("session_id", session_id)
      end
      if session_id then
        -- 有会话 ID：加载已有会话的消息
        M._load_messages(session_id)
        M.render_chat()
        M._update_usage_virt_text()
      else
        -- 无会话 ID：新会话，显示欢迎界面
        -- 会话将在用户第一次发送消息时由 chat_handlers.send_message 创建
        local welcome = {
          "# NeoAI 聊天",
          "",
          "新会话",
          "",
          "输入消息开始聊天...",
          "",
        }
        local buf = window_manager.get_window_buf(window_id)
        if buf and vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
          pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = buf })
          pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, welcome)
          pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
        end
      end

      -- 更新窗口标题
      local model_label = M._get_current_model_label()
      if model_label then
        M.update_title(string.format("NeoAI 聊天 [%s]", model_label))
      end

      -- 触发聊天框打开事件
      vim.api.nvim_exec_autocmds("User", { pattern = Events.CHAT_BOX_OPENED, data = { window_id = window_id } })

      -- 打开浮动虚拟输入框
      M._open_float_input()
    end

    if ctx then
      state_manager.with_context(ctx, init_fn)
    else
      init_fn()
    end
  end)

  return true
end

--- 渲染聊天内容
function M.render_chat()
  if not state.current_window_id then
    return
  end

  -- 防抖处理：避免频繁渲染
  local now = vim.loop.now()
  if now - state.last_render_time < 100 then -- 100毫秒内不重复渲染
    -- 取消之前的定时器
    if state.render_debounce_timer then
      pcall(state.render_debounce_timer.stop, state.render_debounce_timer)
      pcall(state.render_debounce_timer.close, state.render_debounce_timer)
      state.render_debounce_timer = nil
    end

    -- 设置新的定时器
    state.render_debounce_timer = vim.loop.new_timer()
    state.render_debounce_timer:start(
      100,
      0,
      vim.schedule_wrap(function()
        if state.render_debounce_timer then
          pcall(state.render_debounce_timer.close, state.render_debounce_timer)
          state.render_debounce_timer = nil
        end
        M._do_render_chat()
      end)
    )
    return
  end

  state.last_render_time = now
  -- 使用 vim.schedule 确保在当前事件处理完成后执行渲染
  -- 避免在 GENERATION_COMPLETED 事件处理中直接调用 _do_render_chat
  -- 导致 async_worker 的 worker 函数在 state.messages 被修改前执行
  vim.schedule(function()
    M._do_render_chat()
  end)
end

--- 将单条消息渲染为文本行列表
--- @param msg table 消息对象 {role, content}
--- @param prev_role string|nil 上一条消息的角色
--- @return table 文本行列表
--- 将单条消息渲染为文本行列表
--- 注意：返回的每一行都不包含 \n 换行符，由调用方逐行写入缓冲区
--- @param msg table 消息对象 {role, content}
--- @param prev_role string|nil 上一条消息的角色
--- @return table 文本行列表
function M._render_single_message(msg, prev_role)
  local lines = {}
  local role_prefix = msg.role == "user" and "👤 用户:" or "🤖 AI:"
  local raw_content = msg.content or ""
  -- 防御性检查：确保 raw_content 是字符串（_session_to_messages 可能返回 table）
  if type(raw_content) ~= "string" then
    local ok, encoded = pcall(vim.json.encode, raw_content)
    raw_content = ok and encoded or tostring(raw_content)
  end

  -- 响应内容已直接来自 json.decode，不再进行 %%XX URL 编码
  -- 无需额外的解码操作

  -- 每轮对话之间添加分割线（user 消息前，且不是第一条消息）
  -- 注意：只在最后一条消息前添加分割线，由 _do_render_chat 统一处理
  -- 这里不再添加，避免消息之间出现多余的分割线
  -- if msg.role == "user" and prev_role ~= nil then
  --   table.insert(lines, "---")
  --   table.insert(lines, "")
  -- end

  -- 检查是否是折叠文本（以 {{{ 开头）
  -- 注意：使用 raw_content 直接匹配，不 trim，因为 {{{ 必须在行首
  if msg.role == "assistant" and raw_content:find("^{{{") then
    -- 折叠文本：直接显示，不加 AI 标记
    -- 按行分割，每行作为独立元素
    -- 先清理 \r 字符，将 \r 渲染为换行
    local clean_content = raw_content:gsub("\r\n", "\n"):gsub("\r", "\n")
    -- 检测 }}} 后的剩余内容（AI 总结正文）
    local fold_end = select(2, clean_content:find("}}}%s*"))
    if fold_end then
      -- 提取折叠部分（包含 }}} 及其后的空白）
      local fold_part = clean_content:sub(1, fold_end)
      for _, line in ipairs(vim.split(fold_part, "\n")) do
        table.insert(lines, line)
      end
      -- 提取 }}} 后的剩余内容
      local remaining = clean_content:sub(fold_end + 1)
      remaining = remaining:gsub("^\n+", ""):gsub("\n+$", "")
      if remaining and remaining ~= "" then
        table.insert(lines, "")
        -- 对剩余内容应用正常的消息格式化
        local remaining_lines = _format_remaining_content(remaining)
        for _, rline in ipairs(remaining_lines) do
          table.insert(lines, rline)
        end
      end
    else
      -- 没有 }}}，按原逻辑处理
      for _, line in ipairs(vim.split(clean_content, "\n")) do
        table.insert(lines, line)
      end
    end
    table.insert(lines, "")
    return lines
  end

  -- 检查 msg 是否包含 tool_calls 字段（原生 table 结构）
  if msg.role == "assistant" and msg.tool_calls and type(msg.tool_calls) == "table" and #msg.tool_calls > 0 then
    -- 工具调用消息：显示工具调用信息
    table.insert(lines, role_prefix .. " 🔧 工具调用:")
    for _, tc in ipairs(msg.tool_calls) do
      local func = tc["function"] or tc.func or {}
      local tool_name = func.name or "unknown"
      local args_str = ""
      if func.arguments then
        local ok, parsed = pcall(vim.json.decode, func.arguments)
        if ok and parsed then
          args_str = vim.inspect(parsed)
          if #args_str > 100 then
            args_str = args_str:sub(1, 100) .. "..."
          end
        else
          args_str = func.arguments
        end
      end
      table.insert(lines, string.format("    🔧 %s(%s)", tool_name, args_str))
    end
    -- 如果有 content，也显示
    if raw_content and raw_content ~= "" then
      table.insert(lines, "")
      for _, mline in ipairs(vim.split(raw_content, "\n")) do
        table.insert(lines, mline)
      end
    end
    table.insert(lines, "")
    return lines
  end

  -- 尝试解析 JSON 格式（包含 reasoning_content 的 assistant 消息）
  local has_reasoning = false
  local reasoning_content = ""
  local main_content = raw_content
  local has_tool_calls = false

  if msg.role == "assistant" then
    local json_ok, parsed = pcall(vim.json.decode, raw_content)
    if json_ok and type(parsed) == "table" then
      if parsed.reasoning_content and parsed.reasoning_content ~= "" then
        has_reasoning = true
        reasoning_content = parsed.reasoning_content
        main_content = parsed.content or ""
      elseif parsed.content and parsed.content ~= "" then
        -- 只有 content 字段，没有 reasoning_content
        main_content = parsed.content
      end
      -- 检查 JSON 中是否包含 tool_calls
      if parsed.tool_calls and type(parsed.tool_calls) == "table" and #parsed.tool_calls > 0 then
        has_tool_calls = true
      end
    end
  end

  if has_tool_calls then
    -- 有工具调用的 JSON 格式消息
    table.insert(lines, role_prefix .. " 🔧 工具调用:")
    local json_ok, parsed = pcall(vim.json.decode, raw_content)
    if json_ok and parsed and parsed.tool_calls then
      for _, tc in ipairs(parsed.tool_calls) do
        local func = tc["function"] or tc.func or {}
        local tool_name = func.name or "unknown"
        local args_str = ""
        if func.arguments then
          local ok2, parsed2 = pcall(vim.json.decode, func.arguments)
          if ok2 and parsed2 then
            args_str = vim.inspect(parsed2)
            if #args_str > 100 then
              args_str = args_str:sub(1, 100) .. "..."
            end
          else
            args_str = func.arguments
          end
        end
        table.insert(lines, string.format("    🔧 %s(%s)", tool_name, args_str))
      end
    end
    if main_content and main_content ~= "" then
      table.insert(lines, "")
      for _, mline in ipairs(vim.split(main_content, "\n")) do
        table.insert(lines, mline)
      end
    end
    table.insert(lines, "")
    return lines
  end

  if has_reasoning then
    -- 有思考过程
    local reasoning_lines = vim.split(reasoning_content, "\n")
    -- 判断条件：与 _append_reasoning_folded_to_buffer 保持一致
    -- 只有无正文且短思考（<200字符）才不折叠，否则一律折叠
    local has_content = main_content and main_content ~= ""
    local reasoning_text_combined = table.concat(reasoning_lines, " ")
    local reasoning_short = #reasoning_text_combined < 200
    local use_folded = has_content or not reasoning_short

    if use_folded then
      -- 折叠文本格式
      table.insert(lines, "{{{ 🤔 思考过程")
      for _, rline in ipairs(reasoning_lines) do
        table.insert(lines, "  " .. rline)
      end
      table.insert(lines, "}}}")
    else
      -- 无正文且思考短：直接显示
      table.insert(lines, role_prefix .. " 🤔 思考过程:")
      for _, rline in ipairs(reasoning_lines) do
        table.insert(lines, "    " .. rline)
      end
    end
    if main_content and main_content ~= "" then
      table.insert(lines, "")
      for _, mline in ipairs(vim.split(main_content, "\n")) do
        table.insert(lines, mline)
      end
    end
  elseif main_content and main_content ~= "" then
    -- 普通消息（有实际内容）
    local msg_lines = vim.split(main_content, "\n")
    if #msg_lines > 0 then
      table.insert(lines, string.format("%s %s", role_prefix, msg_lines[1]))
      for i = 2, #msg_lines do
        table.insert(lines, string.format("    %s", msg_lines[i]))
      end
    end
  else
    -- 空内容消息，跳过不渲染
  end

  table.insert(lines, "")
  return lines
end

--- 实际执行渲染聊天内容
function M._do_render_chat()
  if not state.current_window_id then
    return
  end

  -- 使用异步渲染，避免阻塞主线程
  vim.schedule(function()
    -- 触发开始渲染对话事件
    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = Events.DIALOGUE_RENDERING_START, data = { window_id = state.current_window_id } }
    )

    -- 消息为空时直接渲染简单内容，避免 async_worker 调度开销
    if #state.messages == 0 then
      local empty_content = {
        "# NeoAI 聊天",
        "",
        string.format("会话: %s", state.current_session_id or "未知"),
        "",
        "暂无消息",
        "输入消息开始聊天...",
        "",
      }
      M._apply_rendered_content(empty_content)
      return
    end

    -- 使用异步工作器在后台构建内容
    async_worker.submit_task("render_chat_content", function()
      local content = {}

      -- 标题区域
      table.insert(content, "# NeoAI 聊天")
      table.insert(content, "")
      table.insert(content, string.format("会话: %s", state.current_session_id or "未知"))
      local model_label = M._get_current_model_label()
      if model_label then
        table.insert(content, string.format("模型: %s", model_label))
      end
      table.insert(content, "")

      -- 消息区域
      local prev_role = nil
      for _, msg in ipairs(state.messages) do
        local msg_lines = M._render_single_message(msg, prev_role)
        for _, line in ipairs(msg_lines) do
          table.insert(content, line)
        end
        prev_role = msg.role
      end

      return content
    end, function(success, content)
      if success and content then
        M._apply_rendered_content(content)
      else
        print("❌ 聊天内容渲染失败")
      end
    end, { auto_serialize = false })
  end)
end

--- 应用渲染后的内容到窗口（内部函数）
--- 提取自 async_worker 回调，供空消息快速渲染复用
--- @param content table 内容行列表
function M._apply_rendered_content(content)
  if not content or not state.current_window_id then
    return
  end

  -- 检查 Neovim 是否正在退出
  local ok_tp, tp = pcall(vim.api.nvim_get_current_tabpage)
  if not ok_tp or not tp then
    return
  end

  -- 在 buffer 内容变化之前检测光标是否在末尾附近（后5行内）
  -- 注意：必须在 set_window_content 之前检测，因为 foldmethod=marker 在内容变化后
  -- 会改变光标的实际位置，导致变化后检测误判光标不在末尾
  local near_end = false
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    local cursor = vim.api.nvim_win_get_cursor(win_handle)
    local buf = vim.api.nvim_win_get_buf(win_handle)
    local total_lines = vim.api.nvim_buf_line_count(buf)
    near_end = total_lines - cursor[1] <= 5
    -- 更新模块级 state 缓存和协程共享表
    state.should_follow = near_end
    state_manager.set_shared("should_follow", near_end)
  end

  -- 设置窗口内容
  local fold_win = window_manager.get_window_win(state.current_window_id)
  local saved_foldlevel = nil
  if fold_win and vim.api.nvim_win_is_valid(fold_win) then
    saved_foldlevel = vim.api.nvim_get_option_value("foldlevel", { win = fold_win })
  end
  window_manager.set_window_content(state.current_window_id, content)
  if fold_win and vim.api.nvim_win_is_valid(fold_win) and saved_foldlevel ~= nil then
    vim.api.nvim_set_option_value("foldlevel", saved_foldlevel, { win = fold_win })
  end

  -- 仅在光标跟随（near_end=true）时获取焦点并打开输入框
  -- 光标不跟随时（near_end=false），不抢焦点，保持用户当前工作状态
  if near_end then
    -- 自动获取焦点（如果虚拟输入框已激活，跳过，避免抢走输入框焦点）
    if not virtual_input.is_active() then
      M._focus_window()
    end
    _schedule_cursor_follow()
    if not state.streaming.active and not state.generation_in_progress then
      M._open_float_input()
    end
  end

  -- 触发渲染完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.RENDERING_COMPLETE,
    data = { window_id = state.current_window_id },
  })
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.DIALOGUE_RENDERING_COMPLETE,
    data = { window_id = state.current_window_id },
  })
end

--- 异步渲染聊天内容（非阻塞版本）
--- @param callback function|nil 回调函数
function M.render_chat_async(callback)
  if not state.current_window_id then
    if callback then
      callback(false, "没有活动的聊天窗口")
    end
    return
  end

  -- 使用异步工作器
  async_worker.submit_task("render_chat_async", function()
    -- 在后台线程中构建内容
    local content = {}

    -- 添加标题
    table.insert(content, "# NeoAI 聊天")
    table.insert(content, "")
    table.insert(content, string.format("会话: %s", state.current_session_id or "未知"))
    table.insert(content, "")

    -- 添加消息
    if #state.messages == 0 then
      table.insert(content, "暂无消息")
      table.insert(content, "输入消息开始聊天...")
    else
      for _, msg in ipairs(state.messages) do
        local role_prefix = msg.role == "user" and "👤 用户:" or "🤖 AI:"
        table.insert(content, string.format("%s %s", role_prefix, msg.content))
        table.insert(content, "")
      end
    end

    -- 不添加分隔线和输入提示（由内联输入区域替代）

    return content
  end, function(success, content)
    if success and content then
      -- async_worker 内部已用 vim.schedule_wrap 包裹回调，无需额外 vim.schedule
      window_manager.set_window_content(state.current_window_id, content)

      -- 检测光标是否在末尾附近，决定是否获取焦点和打开输入框
      local win_handle = window_manager.get_window_win(state.current_window_id)
      local near_end = false
      if win_handle and vim.api.nvim_win_is_valid(win_handle) then
        local cursor = vim.api.nvim_win_get_cursor(win_handle)
        local buf = vim.api.nvim_win_get_buf(win_handle)
        local total_lines = vim.api.nvim_buf_line_count(buf)
        near_end = total_lines - cursor[1] <= 5
      end

      if near_end then
        -- 自动获取焦点（如果虚拟输入框已激活，跳过，避免抢走输入框焦点）
        if not virtual_input.is_active() then
          M._focus_window()
        end
        -- 仅在非流式且无生成进行中时打开浮动虚拟输入框
        if not state.streaming.active and not state.generation_in_progress then
          M._open_float_input()
        end
      end

      if callback then
        callback(true, "聊天内容渲染完成")
      end
    else
      if callback then
        callback(false, "聊天内容渲染失败")
      end
    end
  end)
end

--- 刷新聊天窗口
function M.refresh_chat()
  if not state.current_window_id then
    return
  end

  -- 重新加载数据
  M._load_messages(state.current_session_id)

  -- 重新渲染
  M.render_chat()
end

--- 设置按键映射
function M.set_keymaps()
  if not state.current_window_id then
    return
  end

  local buf = window_manager.get_window_buf(state.current_window_id)
  if not buf then
    return
  end

  -- 从合并后的配置中获取 chat 上下文键位
  -- 所有键位统一由 default_config.lua 定义，模块内部不提供任何 fallback 默认值
  local ok, full_config = pcall(core.get_config)
  full_config = ok and full_config or {}
  local chat_config = full_config.keymaps and full_config.keymaps.chat or {}
  local keymaps = {
    insert = chat_config.insert.key,
    quit = chat_config.quit.key,
    refresh = chat_config.refresh.key,
    switch_model = chat_config.switch_model.key,
    cancel = chat_config.cancel.key,
    tool_approval = chat_config.tool_approval and chat_config.tool_approval.key or nil,
  }

  -- 使用闭包创建局部函数引用，避免每次按键都调用 require
  -- 这些函数形成闭包，可以访问外部作用域的 M 模块
  -- 使用 vim.keymap.set() 直接传递函数，性能更好且消除 LSP 警告
  local function enter_insert_mode()
    M._enter_insert_mode()
  end

  local function close_window()
    M.close()
  end

  local function refresh_chat_window()
    M.refresh_chat()
  end

  local function exit_insert_mode()
    M._exit_insert_mode()
  end

  local function switch_model()
    M.show_model_selector()
  end

  local function cancel_generation()
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.CANCEL_GENERATION,
      data = {},
    })
  end

  -- 设置按键映射（使用 vim.keymap.set 直接传递函数）
  for key, mapping in pairs(keymaps) do
    local callback = nil
    if key == "insert" then
      callback = enter_insert_mode
    elseif key == "quit" then
      callback = close_window
    elseif key == "refresh" then
      callback = refresh_chat_window
    elseif key == "switch_model" then
      callback = switch_model
    elseif key == "cancel" then
      callback = cancel_generation
    elseif key == "tool_approval" then
      callback = function()
        approval_config_editor.open()
      end
    end

    if callback then
      vim.keymap.set("n", mapping, callback, { buffer = buf, noremap = true, silent = true })
    end
  end

  -- 设置插入模式映射（Esc：取消生成或退出插入模式）
  vim.keymap.set("i", "<Esc>", function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = Events.CANCEL_GENERATION,
      data = {},
    })
    exit_insert_mode()
  end, { buffer = buf, noremap = true, silent = true, desc = "取消生成或退出插入模式" })
end

--- 将 chat 窗口的快捷键同步到指定 buffer（用于悬浮窗）
--- 除了 exclude_keys 中列出的快捷键（悬浮窗自己已注册的），其他 chat 快捷键都同步过去
--- @param target_buf number 目标 buffer 句柄
--- @param exclude_keys table|nil 排除的键名列表，如 { "quit", "cancel" }
function M.sync_keymaps_to_buf(target_buf, exclude_keys)
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
    return
  end

  local ok, full_config = pcall(core.get_config)
  full_config = ok and full_config or {}
  local chat_config = full_config.keymaps and full_config.keymaps.chat or {}
  exclude_keys = exclude_keys or {}

  -- 构建排除集合
  local excluded = {}
  for _, k in ipairs(exclude_keys) do
    excluded[k] = true
  end

  -- 定义所有可同步的快捷键（与 set_keymaps 保持一致）
  local sync_actions = {
    insert = function()
      -- 在悬浮窗中按 insert 键：聚焦到 chat 窗口再进入插入模式
      if state.current_window_id then
        local chat_win = window_manager.get_window_win(state.current_window_id)
        if chat_win and vim.api.nvim_win_is_valid(chat_win) then
          vim.api.nvim_set_current_win(chat_win)
          vim.api.nvim_command("startinsert")
        end
      end
    end,
    quit = function()
      M.close()
    end,
    refresh = function()
      M.refresh_chat()
    end,
    switch_model = function()
      M.show_model_selector()
    end,
    cancel = function()
      vim.api.nvim_exec_autocmds("User", {
        pattern = Events.CANCEL_GENERATION,
        data = {},
      })
    end,
    tool_approval = function()
      approval_config_editor.open()
    end,
  }

  for key, callback in pairs(sync_actions) do
    if not excluded[key] then
      local mapping = chat_config[key] and chat_config[key].key
      if mapping then
        vim.keymap.set("n", mapping, callback, {
          buffer = target_buf,
          noremap = true,
          silent = true,
          desc = "[同步] " .. (chat_config[key].desc or key),
        })
      end
    end
  end
end

--- 进入插入模式（内部函数）
function M._enter_insert_mode()
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    vim.api.nvim_set_current_win(win_handle)
    vim.api.nvim_command("startinsert")
  end
end

--- 退出插入模式（内部函数）
function M._exit_insert_mode()
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    vim.api.nvim_command("stopinsert")
  end
end

--- 获取窗口焦点（内部函数）
function M._focus_window()
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if win_handle and vim.api.nvim_win_is_valid(win_handle) then
    pcall(vim.api.nvim_set_current_win, win_handle)
    return true
  end
  return false
end

--- 调整窗口位置（内部函数）
--- 已禁用：用户喜欢屏幕最下方的虚拟输入框
function M._adjust_window_position()
  -- 不执行任何操作，保持窗口在屏幕底部
end

--- 打开浮动虚拟输入框（内部函数）
function M._open_float_input()
  if not state.current_window_id then
    return
  end

  -- 检查 Neovim 是否正在退出，避免在退出过程中打开新窗口导致死循环
  local ok_tp, tp = pcall(vim.api.nvim_get_current_tabpage)
  if not ok_tp or not tp then
    return
  end

  -- 如果已激活，跳过
  if virtual_input.is_active() then
    return
  end

  -- 生成进行中时不打开虚拟输入框
  if state.generation_in_progress then
    return
  end

  -- 工具调用循环进行中时不打开虚拟输入框
  -- 避免在工具循环过程中（TOOL_LOOP_FINISHED 之后、新一轮生成开始前）误开输入框
  if state.tool_loop_in_progress then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end

  -- 检查当前焦点是否在 chat 窗口或输入框上
  -- 如果焦点在其他非 NeoAI 窗口，打开输入框时不设置插入模式和焦点
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_win_get_buf(current_win)
  local ok_ft, current_ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = current_buf })
  local focus_on_chat = ok_ft and (current_ft == "neoai" or current_ft == "NeoAIInput" or current_win == win_handle)

  -- 计算 auto_focus：光标在末尾附近且焦点在 chat 相关窗口
  -- 优先从协程共享表读取（由 _check_cursor_near_end 在内容变化前缓存）
  -- 如果共享表没有值（初始打开时），主动检测光标位置
  local should_follow = state_manager.get_shared_value("should_follow", nil)
  if should_follow == nil then
    -- 初始打开时主动检测光标是否在末尾附近
    local cursor = vim.api.nvim_win_get_cursor(win_handle)
    local buf = vim.api.nvim_win_get_buf(win_handle)
    local total_lines = vim.api.nvim_buf_line_count(buf)
    should_follow = total_lines - cursor[1] <= 5
    -- 缓存结果
    state.should_follow = should_follow
    state_manager.set_shared("should_follow", should_follow)
  end
  local auto_focus = should_follow and focus_on_chat

  -- 打开浮动虚拟输入框
  virtual_input.open(win_handle, {
    placeholder = "输入消息...",
    auto_focus = auto_focus,
    on_submit = function(content)
      if content and content ~= "" then
        -- 如果当前没有会话 ID（新打开的窗口，用户尚未发送过消息），
        -- 先通过 history.manager 创建会话
        local target_session_id = state.current_session_id
        if not target_session_id then
          if history_manager.is_initialized() then
            -- 每次打开新窗口都创建全新的根会话，不复用已有会话
            -- 这样用户发送消息时才真正创建会话，不会产生空会话文件
            local session_id = history_manager.create_session("聊天会话", true, nil)
            if session_id then
              target_session_id = session_id
              -- 更新模块状态和 buffer 名称
              state.current_session_id = target_session_id
              local buf = window_manager.get_window_buf(state.current_window_id)
              if buf and vim.api.nvim_buf_is_valid(buf) then
                pcall(vim.api.nvim_buf_set_name, buf, "neoai://chat/" .. target_session_id)
              end
            end
          end
          -- 如果仍然没有 session ID，阻止提交
          if not target_session_id then
            vim.notify("[NeoAI] 无法创建会话，请检查 history.manager 状态", vim.log.levels.ERROR)
            return
          end
        end

        local success, result = chat_handlers.send_message(
          content,
          target_session_id,
          "main",
          state.current_window_id,
          true,
          function(async_success, async_result, async_error)
            if not async_success then
              print("✗ 异步消息发送失败: " .. tostring(async_error or async_result))
              M.show_floating_text("发送消息失败: " .. tostring(async_error or async_result), {
                timeout = 3000,
                position = "center",
                border = "single",
              })
            end
          end
        )
        if not success then
          print("⚠️  启动异步消息发送失败: " .. tostring(result))
          M.show_floating_text("启动发送失败: " .. tostring(result), {
            timeout = 3000,
            position = "center",
            border = "single",
          })
        else
          M.show_floating_text("消息发送中...", { timeout = 1000, position = "bottom" })
        end
      end
    end,
    on_cancel = function() end,
    on_change = function(content) end,
  })
end

--- 获取当前聊天窗口的 buffer 句柄
--- 供 virtual_input 检测光标离开时使用，替代全局状态切片
--- @return number|nil
function M.get_chat_buf()
  return state.chat_buf
end

--- 获取当前聊天窗口ID
--- @return string|nil
function M.get_current_window_id()
  return state.current_window_id
end

--- 显示悬浮文本

--- 加载消息数据（内部函数）
--- 通过后端 chat_service 获取消息数据
--- @param session_id string 会话ID
function M._load_messages(session_id)
  state.messages = {}

  -- 通过后端 chat_service 获取数据
  if not chat_service or not chat_service.is_initialized then
    return
  end
  -- 确保 chat_service 已初始化
  if not chat_service.is_initialized() then
    local config = core.get_config() or {}
    chat_service.initialize({ config = config })
  end

  local target_id = session_id
  if not target_id then
    local current = chat_service.get_current_session()
    if current then
      target_id = current.id
    else
      return
    end
  end

  -- 加载 usage 信息
  local current_session = chat_service.get_session(target_id)
  if current_session and current_session.usage and next(current_session.usage) then
    state.last_usage = current_session.usage
  else
    state.last_usage = nil
  end

  -- 通过后端获取原始消息（保留 JSON 格式）
  -- 使用 pcall 保护，避免 get_raw_messages 中的错误阻塞主线程
  -- 注意：必须使用闭包包装，不能直接用 pcall(cs.method, cs, args) 方式
  -- 因为 get_raw_messages 是用点号定义的 function M.get_raw_messages(session_id)
  -- pcall(cs.method, cs, args) 等价于冒号调用 cs:method(args)，会导致参数错位
  local ok, messages = pcall(function()
    return chat_service.get_raw_messages(target_id)
  end)
  if ok and messages then
    state.messages = messages
  end
end

--- 异步加载消息数据（内部函数）
--- @param session_id string 会话ID
--- @param callback function 回调函数
function M._load_messages_async(session_id, callback)
  -- 使用异步工作器
  local async_worker = require("NeoAI.utils.async_worker")

  async_worker.submit_task("load_chat_messages", function()
    -- 在后台线程中加载消息数据
    -- 这里应该从会话管理器加载消息数据
    -- 目前保持空数据
    local messages = {}

    return messages
  end, function(success, messages, error_msg)
    if callback then
      if success then
        callback(messages)
      else
        -- 如果异步失败，回退到同步版本
        M._load_messages(session_id)
        callback(state.messages)
      end
    end
  end)
end

--- 关闭聊天窗口
function M.close()
  if not state.current_window_id then
    return
  end

  -- 检查聊天框是否真的打开
  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    -- 窗口已关闭，清理状态但不触发事件
    state.current_window_id = nil
    state.current_session_id = nil
    state.chat_buf = nil
    state.messages = {}
    return
  end

  -- 清理所有定时器（防止窗口关闭后定时器仍然运行）
  if state.render_debounce_timer then
    pcall(state.render_debounce_timer.stop, state.render_debounce_timer)
    pcall(state.render_debounce_timer.close, state.render_debounce_timer)
    state.render_debounce_timer = nil
  end
  if state.stream_throttle.timer then
    pcall(state.stream_throttle.timer.stop, state.stream_throttle.timer)
    pcall(state.stream_throttle.timer.close, state.stream_throttle.timer)
    state.stream_throttle.timer = nil
  end
  state.stream_throttle.buffer = ""
  state.stream_throttle.pending = false
  if state.cursor_follow.timer then
    pcall(state.cursor_follow.timer.stop, state.cursor_follow.timer)
    pcall(state.cursor_follow.timer.close, state.cursor_follow.timer)
    state.cursor_follow.timer = nil
  end
  state.cursor_follow.pending = false

  -- 保存当前窗口ID到局部变量，供 defer_fn 使用
  -- 防止 defer_fn 执行时 state.current_window_id 已被 M.open() 修改
  local closing_window_id = state.current_window_id
  local closing_session_id = state.current_session_id

  -- 标记窗口正在关闭，阻止后续异步回调继续执行
  state.closing = true

  -- 关闭窗口前停止后台工具循环和AI生成
  -- 触发取消生成事件（ai_engine 监听此事件取消HTTP请求和工具循环）
  -- ai_engine.cancel_generation() 内部会调用 tool_orchestrator.request_stop()
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.CANCEL_GENERATION,
    data = {},
  })

  -- 额外确保工具循环停止：如果当前有活跃的工具循环但 cancel_generation 未能覆盖
  --（例如 state.current_generation_id 为 nil 但工具循环仍在运行）
  tool_orchestrator.request_stop(closing_session_id)

  -- 延迟执行窗口关闭，给异步回调一点时间完成
  -- 避免异步回调在窗口关闭后访问已清理的状态导致错误
  vim.defer_fn(function()
    -- 检查 Neovim 是否正在退出，如果是则跳过所有窗口操作
    -- 避免在 Neovim 退出过程中操作已无效的窗口导致死循环
    local is_exiting = false
    pcall(function()
      -- 尝试获取当前 tabpage，如果 Neovim 正在退出可能会失败
      local tp = vim.api.nvim_get_current_tabpage()
      if not tp then
        is_exiting = true
      end
    end)
    if is_exiting then
      state.closing = false
      return
    end

    -- 使用局部变量 closing_window_id，不受 state.current_window_id 变化的影响
    local win_handle = window_manager.get_window_win(closing_window_id)
    if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
      -- 窗口已关闭，清理状态但不触发事件
      state.closing = false
      return
    end

    -- 触发窗口关闭前事件
    vim.api.nvim_exec_autocmds("User", { pattern = Events.WINDOW_CLOSING, data = { window_id = closing_window_id } })

    -- 触发聊天框关闭事件
    vim.api.nvim_exec_autocmds("User", { pattern = Events.CHAT_BOX_CLOSING, data = { window_id = closing_window_id } })

    -- 关闭浮动虚拟输入框（所有模式下关闭聊天窗口时都关闭输入框）
    if virtual_input.is_active() then
      virtual_input.close()
    end

    window_manager.close_window(closing_window_id)

    -- 清理自动命令组
    if state.cursor_augroup then
      pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
      state.cursor_augroup = nil
    end

    -- 关闭思考过程悬浮窗
    if reasoning_display.is_visible() then
      reasoning_display.close()
    end

    -- 关闭工具调用悬浮窗
    if state.tool_display and state.tool_display.active then
      M._close_tool_display()
    end

    -- 重置流式状态（防止 reasoning 状态残留导致下次打开时内容叠加）
    -- 取消延迟打开 reasoning_display 的定时器
    if state.streaming._reasoning_display_timer then
      pcall(state.streaming._reasoning_display_timer.stop, state.streaming._reasoning_display_timer)
      pcall(state.streaming._reasoning_display_timer.close, state.streaming._reasoning_display_timer)
      state.streaming._reasoning_display_timer = nil
    end

    state.streaming.active = false
    state.streaming.generation_id = nil
    state.streaming.message_index = nil
    state.streaming.content_buffer = ""
    state.streaming.reasoning_buffer = ""
    state.streaming.reasoning_active = false
    state.streaming.reasoning_done = false
    state.streaming.prefix_added = false
    state.streaming.reasoning_prefix_added = false
    state.streaming.content_separator_added = false
    state.streaming._reasoning_display_timer = nil
    -- 通过 tool_display_component 统一清理
    tool_display_component.reset()
    state.tool_display.active = false
    state.tool_display.buffer = ""
    state.tool_display.results = {}
    state.tool_display._finished = false
    state.tool_display.folded_saved = false
    state.tool_display.window_id = nil
    state.tool_display.substeps = {}
    state.tool_display.preview_window_id = nil
    state.tool_display.streaming_preview.timer = nil
    state.tool_display.streaming_preview.generation_id = nil
    state.tool_display.streaming_preview.tools = {}
    state.tool_display.streaming_preview.window_shown = false
    state.tool_display.streaming_preview._last_buffer = ""

    -- 只有在 state.current_window_id 仍然是 closing_window_id 时才清理状态
    -- 防止 M.open() 已经设置了新的窗口，这里误清理
    if state.current_window_id == closing_window_id then
      state.current_window_id = nil
      state.current_session_id = nil
      state.chat_buf = nil
      state.messages = {}
      state.last_usage = nil
      state.usage_extmark_id = nil
    end
    -- 清理 completed_generations，避免无限增长
    completed_generations = {}
    -- 清理 file_utils 加载的后台 buffer
    pcall(function()
      if file_utils.cleanup_session_buffers then
        file_utils.cleanup_session_buffers()
      end
    end)
    state.closing = false

    -- 触发窗口关闭事件
    vim.api.nvim_exec_autocmds("User", { pattern = Events.WINDOW_CLOSED, data = { window_id = closing_window_id } })

    -- 触发聊天框关闭完成事件
    vim.api.nvim_exec_autocmds("User", { pattern = Events.CHAT_BOX_CLOSED, data = { window_id = closing_window_id } })
  end, 30) -- 30ms 延迟，给异步回调足够时间完成
end

--- 在 AI 回复末尾行添加 token 用量虚拟文本
--- 使用 nvim_buf_set_extmark 的 virt_text 特性，不修改缓冲区内容
function M._update_usage_virt_text()
  -- 流式进行中不显示用量信息，等流式完成后的全量重渲染再显示
  if state.streaming.active then
    return
  end
  if not state.current_window_id or not state.last_usage or not next(state.last_usage) then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end

  local buf = vim.api.nvim_win_get_buf(win_handle)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 获取或创建命名空间
  local ns_id = vim.api.nvim_create_namespace("NeoAIUsage")

  -- 清理旧的虚拟文本
  if state.usage_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, buf, ns_id, state.usage_extmark_id)
    state.usage_extmark_id = nil
  end

  -- 构建用量文本
  local usage = state.last_usage
  if not usage then
    return
  end

  local prompt_tokens = (usage.prompt_tokens or usage.promptTokens or usage.input_tokens or usage.inputTokens) or 0
  local completion_tokens = (
    usage.completion_tokens
    or usage.completionTokens
    or usage.output_tokens
    or usage.outputTokens
  ) or 0
  local total_tokens = (usage.total_tokens or usage.totalTokens) or (prompt_tokens + completion_tokens)

  local reasoning_tokens = 0
  if usage.completion_tokens_details and type(usage.completion_tokens_details) == "table" then
    reasoning_tokens = usage.completion_tokens_details.reasoning_tokens or 0
  end

  local usage_text
  if reasoning_tokens and reasoning_tokens > 0 then
    usage_text = string.format(
      "📊 Token 用量: 输入 %d · 输出 %d (思考 %d) · 总计 %d",
      prompt_tokens,
      completion_tokens,
      reasoning_tokens,
      total_tokens
    )
  else
    usage_text = string.format(
      "📊 Token 用量: 输入 %d · 输出 %d · 总计 %d",
      prompt_tokens,
      completion_tokens,
      total_tokens
    )
  end

  -- 先确保缓冲区可修改
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = buf })

  local line_count = vim.api.nvim_buf_line_count(buf)

  -- 在末尾追加用量文本（直接写入缓冲区，支持自动换行）
  -- 同时用 extmark 的 hl_group 设置整行颜色
  local usage_line = line_count
  vim.api.nvim_buf_set_lines(buf, usage_line, usage_line + 1, false, { usage_text })
  -- 用 extmark 给这一行设置高亮颜色
  state.usage_extmark_id = vim.api.nvim_buf_set_extmark(buf, ns_id, usage_line, 0, {
    hl_group = "Comment",
    hl_eol = true,
  })

  -- 恢复缓冲区状态
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
end

--- 更新配置
--- @param new_config table 新配置
function M.update_config(new_config)
  if not state.initialized then
    return
  end

  -- 如果窗口打开，重新设置按键映射
  if state.current_window_id then
    M.set_keymaps()
    M.render_chat()
  end
end

--- 更新聊天窗口标题
--- @param title string 新标题
function M.update_title(title)
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end

  -- 更新浮动窗口标题（Neovim 0.9+ 支持通过 nvim_win_set_config 更新 title）
  local ok, err = pcall(vim.api.nvim_win_set_config, win_handle, { title = title })
  if not ok then
    -- 如果 nvim_win_set_config 不支持 title 参数（旧版本 Neovim），静默忽略
    -- luacheck: ignore
    do
    end -- 空块：兼容旧版本 Neovim
  end
end

--- 刷新聊天窗口
--- @return boolean 是否成功
function M.refresh()
  if not state.initialized then
    return false
  end

  if not state.current_window_id then
    return false
  end

  -- 重新渲染聊天
  M.render_chat()
  return true
end

--- 检查聊天窗口是否已打开
--- @return boolean 是否已打开
function M.is_open()
  if not state.initialized then
    return false
  end

  return state.current_window_id ~= nil
end

--- 检查聊天窗口是否可用（兼容旧版本）
--- @return boolean 是否可用
function M.is_available()
  return M.is_open()
end

--- 发送消息（异步版本）
--- @param message string 消息内容
--- @param callback function|nil 回调函数（可选）
--- @return boolean 是否成功启动异步发送
--- @return string|nil 结果信息
function M.send_message(message, callback)
  if not state.initialized then
    if callback then
      callback(false, "聊天窗口未初始化")
    end
    return false, "聊天窗口未初始化"
  end

  if not message or vim.trim(message) == "" then
    if callback then
      callback(false, "消息内容不能为空")
    end
    return false, "消息内容不能为空"
  end

  -- 使用异步工作器发送消息，避免阻塞界面

  -- 提交异步任务
  local task_id = async_worker.submit_task("send_chat_message_window", function()
    -- 首先添加用户消息
    local success = M.add_message("user", message)
    if not success then
      return false, "无法添加用户消息"
    end

    -- 注意：不再在这里触发NeoAI:message_sent事件
    -- 这个事件现在由chat_handlers统一触发，避免重复触发

    return true, "消息已发送"
  end, function(success, result, error_msg)
    -- 异步任务完成后的回调
    if callback then
      callback(success, result, error_msg)
    end

    if success then
      print("✓ 聊天窗口异步消息发送完成: " .. tostring(result))
    else
      print("✗ 聊天窗口异步消息发送失败: " .. tostring(error_msg or result))
    end
  end, 0)

  return true, "聊天窗口异步消息发送任务已启动 (ID: " .. tostring(task_id) .. ")"
end

--- 添加消息到聊天
--- @param role string 角色 ('user' 或 'assistant')
--- @param content string 消息内容
--- @param opts table|nil 选项（allow_empty: 允许空内容用于流式占位符）
--- @return boolean 是否成功
function M.add_message(role, content, opts)
  if not state.initialized then
    return false
  end

  if role ~= "user" and role ~= "assistant" then
    return false
  end

  opts = opts or {}
  if not opts.allow_empty and (not content or vim.trim(content) == "") then
    return false
  end

  -- 触发消息添加事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = Events.MESSAGE_ADDING, data = { window_id = state.current_window_id, role = role, content = content } }
  )

  table.insert(state.messages, {
    role = role,
    content = content,
    timestamp = os.time(),
  })

  -- 触发消息添加完成事件（除非指定跳过，用于流式场景避免触发全量重渲染）
  if not opts.skip_event then
    vim.api.nvim_exec_autocmds(
      "User",
      { pattern = Events.MESSAGE_ADDED, data = { window_id = state.current_window_id, role = role, content = content } }
    )
  end

  -- 持久化消息到 session_manager 和 history_manager（除非指定跳过）
  if not opts.skip_persist then
    M._persist_message(role, content)
  end

  -- 如果窗口打开，更新显示（除非指定跳过渲染）
  -- 使用增量追加方式，避免全量重渲染刷新界面
  if state.current_window_id and not opts.skip_render then
    M._append_message_to_buffer(role, content)
  end

  return true
end

--- 触发自动保存（内部函数）
--- 由 history_manager 的防抖机制统一处理，不再单独调用
function M._trigger_auto_save()
  -- 由 history_manager.mark_dirty 防抖机制统一处理
end

--- 持久化消息到存储系统（内部函数）
--- 通过后端 chat_service 操作
--- @param role string 角色 ('user' 或 'assistant')
--- @param content string 消息内容
function M._persist_message(role, content)
  if not chat_service or not chat_service.get_current_session then
    return
  end
  local session = chat_service.get_current_session()
  if not session then
    return
  end
  if role == "user" then
    chat_service.add_round(session.id, content, {})
  elseif role == "assistant" then
    chat_service.update_last_assistant(session.id, content)
  end

  -- 触发自动保存
  M._trigger_auto_save()
end

--- 更新已持久化的消息
--- 通过后端 chat_service 操作
--- @param role string 角色 ('user' 或 'assistant')
--- @param content string 新消息内容
function M._update_persisted_message(role, content)
  if not chat_service or not chat_service.get_current_session then
    return
  end
  local session = chat_service.get_current_session()
  if not session then
    return
  end
  if role == "assistant" then
    chat_service.update_last_assistant(session.id, content)
  end
end

--- 将光标移动到缓冲区末尾（最新消息位置）
--- 在渲染完成后调用，方便用户查看最新输出
--- 滚动到缓冲区末尾，使最后一行位于窗口底部上方指定行数处
--- float 模式下虚拟输入框是独立浮动窗口，不占用 chat 窗口空间，无需留偏移
--- 其他模式（inline/tab/split）需要留出内联输入区域的空间
--- @param offset number|nil 距离底部的行数偏移，nil 时根据窗口模式自动计算
function M._scroll_to_end_with_offset(offset)
  if offset == nil then
    -- 根据窗口模式动态计算 offset
    local mode = window_manager.get_current_mode()
    if mode == "float" then
      offset = 0 -- float 模式：虚拟输入框独立，不占 chat 窗口空间
    else
      -- 其他模式：内联输入需要留空间，取虚拟输入框行数 + 5 行余量
      local vi = require("NeoAI.ui.components.virtual_input")
      local input_lines = vi.get_input_line_count()
      offset = (input_lines or 3) + 5
    end
  end
  if not state.current_window_id then
    return
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end

  local buf = window_manager.get_window_buf(state.current_window_id)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count > 0 then
    -- 只滚动视图让最后一行位于窗口底部，不移动光标
    pcall(vim.api.nvim_win_call, win_handle, function()
      local win_height = vim.api.nvim_win_get_height(win_handle)
      local target_topline = line_count - win_height + 1 + offset
      if target_topline < 1 then
        target_topline = 1
      end
      local view = vim.fn.winsaveview()
      view.topline = target_topline
      vim.fn.winrestview(view)
    end)
  end
end

--- 将光标移动到缓冲区末尾（最新消息位置）
--- 在渲染完成后调用，方便用户查看最新输出
function M._move_cursor_to_end()
  M._scroll_to_end_with_offset()
end

--- 显示悬浮文本
--- @param text string 要显示的文本
--- @param opts table|nil 选项
function M.show_floating_text(text, opts)
  if not state.current_window_id then
    return false
  end

  opts = opts or {}
  local win_handle = window_manager.get_window_win(state.current_window_id)

  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return false
  end

  -- 触发显示悬浮文本事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.FLOATING_TEXT_SHOWING,
    data = {
      window_id = state.current_window_id,
      text = text,
    },
  })

  -- 这里可以实现实际的悬浮文本显示逻辑
  -- 例如使用 nvim_open_win 创建浮动窗口

  -- 触发显示悬浮文本完成事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.FLOATING_TEXT_SHOWN,
    data = {
      window_id = state.current_window_id,
      text = text,
    },
  })

  return true
end

--- 关闭悬浮文本
function M.close_floating_text()
  if not state.current_window_id then
    return false
  end

  -- 触发关闭悬浮文本事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = Events.FLOATING_TEXT_CLOSING, data = {
      window_id = state.current_window_id,
    } }
  )

  -- 这里可以实现实际的悬浮文本关闭逻辑

  -- 触发关闭悬浮文本完成事件
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = Events.FLOATING_TEXT_CLOSED, data = {
      window_id = state.current_window_id,
    } }
  )

  return true
end

-- ========== 辅助：提取响应内容 ==========

local function extract_response_content(response)
  if type(response) == "string" then
    return response
  end
  if type(response) == "table" then
    if response.content then
      return response.content
    end
    if response.text then
      return response.text
    end
  end
  return tostring(response)
end

local function find_folded_msg_idx()
  for i = #state.messages, 1, -1 do
    if state.messages[i].role == "assistant" and (state.messages[i].content or ""):find("^{{{") then
      return i
    end
  end
  return nil
end

local function find_placeholder_idx()
  for i = #state.messages, 1, -1 do
    if state.messages[i].role == "assistant" and state.messages[i].content == "🤖 AI正在思考..." then
      return i
    end
  end
  return nil
end

--- 设置事件监听器（内部函数）
function M._setup_event_listeners()
  -- GENERATION_STARTED：关闭虚拟输入框，标记生成进行中
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_STARTED,
    callback = function()
      state.generation_in_progress = true
      -- 重置工具循环完成标志，确保新的生成能正常显示实时参数悬浮窗
      state.tool_display._finished = false
      if virtual_input.is_active() then
        virtual_input.close()
      end
    end,
  })

  -- GENERATION_COMPLETED：处理 AI 响应完成
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_COMPLETED,
    callback = function(args)
      local data = args.data or {}
      if not is_current_window(data.window_id) then
        return
      end

      local response_content = extract_response_content(data.response)
      local reasoning_text = data.reasoning_text or ""
      local usage = data.usage or {}

      -- 即使 response_content 为空，如果有 reasoning_text，仍需继续处理
      -- 因为 reasoning 已通过 _append_reasoning_folded_to_buffer 追加到缓冲区
      local has_reasoning = reasoning_text ~= ""
      if not response_content or response_content == "" then
        if not has_reasoning then
          close_tool_display()
          reset_tool_display()
          reset_streaming_state()
          state.tool_loop_in_progress = false
          return
        end
        -- 只有 reasoning 没有正文：response_content 保持空字符串
      end

      local has_tool_results = state.tool_display.active and #state.tool_display.results > 0
      local folded_saved = state.tool_display.folded_saved
      local msg_idx = state.streaming.message_index

      -- 更新消息内容
      -- 注意：思考过程已通过 _append_reasoning_folded_to_buffer 在 STREAM_CHUNK 或
      -- STREAM_COMPLETED 事件中单独追加到聊天缓冲区。
      -- 但 state.messages 中保存的内容需要包含 reasoning，以便全量重渲染时正确显示。
      -- 如果 reasoning 已追加，state.messages 中的内容应保存为 JSON 格式（含 reasoning_content），
      -- 这样 _render_single_message 可以正确解析并渲染。
      -- 如果 reasoning 短且无正文（不折叠），则保存为 JSON 格式。
      -- 如果 reasoning 折叠或有正文，则保存为 JSON 格式（_render_single_message 会处理折叠）。
      local content_with_reasoning = response_content
      if has_reasoning then
        content_with_reasoning = vim.json.encode({
          reasoning_content = reasoning_text,
          content = response_content,
        })
      end

      if msg_idx and state.messages[msg_idx] then
        if folded_saved then
          local folded_idx = find_folded_msg_idx()
          if folded_idx then
            local append_content = has_reasoning and content_with_reasoning or response_content
            state.messages[folded_idx].content = state.messages[folded_idx].content .. "\n\n" .. append_content
            if msg_idx ~= folded_idx then
              table.remove(state.messages, msg_idx)
            end
          else
            state.messages[msg_idx].content = content_with_reasoning
          end
        elseif has_tool_results then
          local folded = M._build_tool_folded_text(state.tool_display.results)
          state.messages[msg_idx].content = (folded ~= "" and folded .. "\n\n" or "") .. content_with_reasoning
        else
          state.messages[msg_idx].content = content_with_reasoning
        end
      else
        if folded_saved then
          local folded_idx = find_folded_msg_idx()
          if folded_idx then
            local append_content = has_reasoning and content_with_reasoning or response_content
            state.messages[folded_idx].content = state.messages[folded_idx].content .. "\n\n" .. append_content
          else
            table.insert(
              state.messages,
              { role = "assistant", content = content_with_reasoning, timestamp = os.time() }
            )
          end
        elseif has_tool_results then
          local folded = M._build_tool_folded_text(state.tool_display.results)
          local final = (folded ~= "" and folded .. "\n\n" or "") .. content_with_reasoning
          table.insert(state.messages, { role = "assistant", content = final, timestamp = os.time() })
        else
          local placeholder_idx = find_placeholder_idx()
          if placeholder_idx then
            table.remove(state.messages, placeholder_idx)
          end
          M.add_message("assistant", content_with_reasoning, { skip_render = true, skip_event = true })
        end
      end

      -- 将最终内容保存到 history_manager（确保包含折叠文本的完整内容被持久化）
      -- 通过 HISTORY_SAVE_FINAL 事件通知 history_saver 异步保存
      local final_entry = M._save_final_content_to_history(data)
      if final_entry then
        vim.api.nvim_exec_autocmds("User", {
          pattern = "NeoAI:history_save_final",
          data = {
            session_id = data.session_id,
            content = final_entry.content,
            reasoning_content = final_entry.reasoning_content,
            usage = data.usage or {},
          },
        })
      end

      -- 清理状态
      state.tool_display.folded_saved = false
      if has_tool_results then
        reset_tool_display()
      end
      if usage and next(usage) then
        state.last_usage = usage
      end

      cancel_reasoning_timer()
      close_reasoning_display()
      if state.tool_display.active then
        close_tool_display()
        reset_tool_display()
        state.tool_display._finished = false
      end
      clear_stream_throttle()
      -- 通过 tool_display_component 清理流式工具预览状态
      tool_display_component.clear_streaming_preview()
      -- 同步更新本地状态
      state.tool_display.streaming_preview.timer = nil
      state.tool_display.streaming_preview.generation_id = nil
      state.tool_display.streaming_preview.tools = {}
      state.tool_display.streaming_preview.window_shown = false
      state.tool_display.streaming_preview._last_buffer = ""

      -- 保存流式状态，用于判断是否需要增量更新
      -- 注意：reasoning_done 为 true 表示思考过程折叠文本已通过 _append_reasoning_folded_to_buffer 追加到缓冲区
      -- 此时即使 prefix_added 为 false（只有思考没有正文），也应视为已有流式内容，避免重复追加
      local had_stream_prefix = state.streaming.prefix_added
        or state.streaming.reasoning_prefix_added
        or state.streaming.reasoning_done
      state.tool_display.active = false
      reset_streaming_state()
      state.tool_loop_in_progress = false
      state.generation_in_progress = false

      -- 增量更新：仅当没有流式数据时（非流式总结），才追加完整消息到缓冲区
      -- 如果总结内容已通过流式方式追加，跳过以避免重复
      if not had_stream_prefix then
        local last = state.messages[#state.messages]
        if last and last.role == "assistant" then
          M._append_message_to_buffer("assistant", last.content, data.window_id)
        end
      end

      M._update_usage_virt_text()
      -- 先主动检测光标位置，确保协程共享的 should_follow 是最新值
      _check_cursor_near_end()
      -- 注意：直接使用模块级 state.should_follow，避免通过协程共享表读取
      -- 事件回调不在协程上下文中，state_manager.get_shared_value 会返回默认值
      if state.should_follow then
        -- 光标在末尾附近：执行跟随并打开输入框
        _do_cursor_follow()
        M._open_float_input()
        if virtual_input.is_active() then
          virtual_input.focus_and_insert()
        end
      else
        -- 光标不在末尾附近：打开输入框但不聚焦
        M._open_float_input()
      end
    end,
  })

  -- STREAM_CHUNK：流式数据块
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.STREAM_CHUNK,
    callback = function(args)
      local data = args.data or {}
      if not is_current_window(data.window_id) then
        return
      end

      local chunk = data.chunk
      local generation_id = data.generation_id
      local chunk_content = extract_response_content(chunk)

      if chunk_content == "\n" or chunk_content == "\r\n" then
        -- 换行符：追加到 content_buffer 后重新渲染
        state.streaming.content_buffer = state.streaming.content_buffer .. "\n"
        M._append_stream_chunk_to_buffer("")
        return
      end
      if not chunk_content or chunk_content == "" then
        return
      end

      -- 初始化流式状态
      if not state.streaming.active or state.streaming.generation_id ~= generation_id then
        state.streaming.active = true
        state.streaming.generation_id = generation_id
        state.streaming.content_buffer = ""
        state.streaming.reasoning_buffer = ""
        state.streaming.reasoning_active = false
        state.streaming.reasoning_done = false
        state.streaming.message_start_line = nil
        local ok = M.add_message("assistant", "", { allow_empty = true, skip_render = true, skip_event = true })
        if ok then
          state.streaming.message_index = #state.messages
        end
      end

      -- 从思考切换到正文
      if state.streaming.reasoning_active then
        state.streaming.reasoning_active = false
        state.streaming.reasoning_done = true
        state.streaming.content_separator_added = false
        local rt = state.streaming.reasoning_buffer or ""
        local mi = state.streaming.message_index
        if rt ~= "" and mi and state.messages[mi] then
          state.messages[mi].content = vim.json.encode({ reasoning_content = rt, content = "" })
        end
        -- 思考过程完毕：将完整的思考过程以折叠文本格式追加到聊天缓冲区
        -- 注意：此时悬浮窗已滚动显示完所有思考内容，关闭悬浮窗后将折叠文本写入缓冲区
        if rt ~= "" then
          M._append_reasoning_folded_to_buffer(rt, data.window_id)
        end
        close_reasoning_display()
      end

      state.streaming.content_buffer = state.streaming.content_buffer .. chunk_content
      M._append_stream_chunk_to_buffer(chunk_content, nil, data.window_id)
    end,
  })

  -- 追踪已完成的 generation_id
  local completed_generations = {}

  -- REASONING_CONTENT：思考内容
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.REASONING_CONTENT,
    callback = function(args)
      local data = args.data or {}
      if not is_current_window(data.window_id) then
        return
      end
      if state.closing then
        return
      end

      local rc = data.reasoning_content
      local gid = data.generation_id
      if not rc or rc == "" or completed_generations[gid] then
        return
      end

      -- 检查光标是否在末尾附近（决定是否显示悬浮窗）
      local win = get_win()
      local should_follow = cursor_near_end(win)

      if not state.streaming.active or state.streaming.generation_id ~= gid then
        state.streaming.active = true
        state.streaming.generation_id = gid
        state.streaming.content_buffer = ""
        state.streaming.reasoning_buffer = ""
        state.streaming.reasoning_active = true
        state.streaming.reasoning_done = false
        state.streaming.message_start_line = nil
        local ok = M.add_message("assistant", "", { allow_empty = true, skip_render = true, skip_event = true })
        if ok then
          state.streaming.message_index = #state.messages
        end
        cancel_reasoning_timer()
        -- 仅在光标跟随模式下显示思考过程悬浮窗
        if should_follow then
          reasoning_display.show("🤔 AI正在思考...")
        end
      end

      state.streaming.reasoning_active = true
      -- reasoning_buffer 保持编码后的原始内容，与 content_buffer 一致
      state.streaming.reasoning_buffer = state.streaming.reasoning_buffer .. rc
      -- 仅在光标跟随模式下更新思考过程悬浮窗内容
      -- 注意：思考过程只在悬浮窗中滚动显示，不追加到聊天缓冲区
      -- 等思考过程完毕后，再以折叠文本格式一次性追加到聊天缓冲区
      -- 响应内容已直接来自 json.decode，不再进行 %%XX URL 编码
      if should_follow then
        if reasoning_display.is_visible() then
          reasoning_display.append(rc)
        end
      end
    end,
  })

  -- AI_RESPONSE_CHUNK：兼容旧事件
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.AI_RESPONSE_CHUNK,
    callback = function(args)
      local data = args.data or {}
      local chunk_content = extract_response_content(data.chunk)
      if not chunk_content or chunk_content == "" then
        return
      end

      if not state.streaming.active then
        state.streaming.active = true
        state.streaming.generation_id = data.generation_id
        state.streaming.content_buffer = ""
        state.streaming.reasoning_buffer = ""
        state.streaming.message_start_line = nil
        local ok = M.add_message("assistant", "", { allow_empty = true, skip_render = true, skip_event = true })
        if ok then
          state.streaming.message_index = #state.messages
        end
      end
      state.streaming.content_buffer = state.streaming.content_buffer .. chunk_content
      M._append_stream_chunk_to_buffer(chunk_content, nil, data.window_id)
    end,
  })

  -- STREAM_COMPLETED：流式完成
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.STREAM_COMPLETED,
    callback = function(args)
      local data = args.data or {}
      local gid = data.generation_id

      if not state.streaming.active or state.streaming.generation_id ~= gid then
        close_reasoning_display()
        return
      end

      cancel_reasoning_timer()

      -- 如果思考过程仍在进行中（从未收到正文 STREAM_CHUNK），在此处追加折叠文本
      -- 正常情况下 reasoning→content 切换由 STREAM_CHUNK 回调处理
      -- 但如果没有正文内容（只有思考过程），STREAM_CHUNK 不会触发切换逻辑
      if state.streaming.reasoning_active then
        local rt = state.streaming.reasoning_buffer or ""
        if rt ~= "" then
          state.streaming.reasoning_active = false
          state.streaming.reasoning_done = true
          M._append_reasoning_folded_to_buffer(rt, data.window_id)
        end
      end

      close_reasoning_display()
      completed_generations[gid] = true

      -- 只清理部分状态，保留 message_index 供 GENERATION_COMPLETED 使用
      -- 注意：保留 reasoning_done 状态，供 GENERATION_COMPLETED 判断是否已追加思考过程折叠文本
      -- GENERATION_COMPLETED 回调中计算 had_stream_prefix 后会由 reset_streaming_state() 统一重置
      state.streaming.active = false
      state.streaming.content_buffer = ""
      state.streaming.reasoning_buffer = ""
      state.streaming.prefix_added = false
      state.streaming.reasoning_prefix_added = false
      state.streaming.content_separator_added = false
    end,
  })

  -- 辅助：更新工具包分组中的工具状态
  local function update_tool_in_pack(pack_name, tool_name, status, duration)
    local pack = state.tool_display.packs[pack_name]
    if not pack then
      return
    end
    for _, t in ipairs(pack.tools) do
      if t.name == tool_name then
        t.status = status
        t.duration = duration
        break
      end
    end
  end

  -- 辅助：根据工具包分组重建显示 buffer（含子步骤树形显示）
  local function rebuild_tool_display_buffer()
    local text = "🔧 工具调用中...\n"
    for _, pack_name in ipairs(state.tool_display.pack_order) do
      local pack = state.tool_display.packs[pack_name]
      if pack then
        local icon = tool_pack.get_pack_icon(pack_name)
        local display_name = tool_pack.get_pack_display_name(pack_name)
        text = text .. "\n" .. icon .. " " .. display_name .. "\n"
        for _, t in ipairs(pack.tools) do
          local status_icon = "⏳"
          local status_text = "等待中"
          if t.status == "executing" then
            status_icon = "🔄"
            status_text = "执行中..."
          elseif t.status == "completed" then
            status_icon = "✅"
            status_text = string.format("(%.1fs)", t.duration or 0)
          elseif t.status == "error" then
            status_icon = "❌"
            status_text = string.format("(失败, %.1fs)", t.duration or 0)
          end
          text = text .. "  " .. status_icon .. " " .. t.name .. " " .. status_text .. "\n"

          -- 显示 AI 填入的参数（缩进显示）
          if t.args and type(t.args) == "table" and next(t.args) then
            for k, v in pairs(t.args) do
              if k ~= "_session_id" and k ~= "_tool_call_id" then
                local v_str = type(v) == "string" and v or vim.inspect(v)
                -- 临时 URL 解码（仅用于显示）
                v_str = vim.uri_decode(v_str)
                -- 尝试将解码后的 JSON 字符串解析为 table 以格式化显示
                if v_str:sub(1, 1) == "{" or v_str:sub(1, 1) == "[" then
                  local ok, parsed = pcall(vim.json.decode, v_str)
                  if ok and type(parsed) == "table" then
                    v_str = vim.inspect(parsed, { indent = "", newline = "", separator = ", " })
                  end
                end
                -- 截断到窗口宽度
                local max_width = math.floor(vim.o.columns * 0.8) - 8
                if #v_str > max_width then
                  v_str = v_str:sub(1, max_width - 3) .. "..."
                end
                -- 多行值只取第一行
                local first_line = v_str:match("([^\n]+)") or v_str
                text = text .. "    " .. k .. ": " .. first_line .. "\n"
              end
            end
          end

          -- 显示子步骤（树形缩进）
          local substeps = state.tool_display.substeps[t.name]
          if substeps and #substeps > 0 then
            for i, s in ipairs(substeps) do
              local is_last = (i == #substeps)
              local prefix = is_last and "    └── " or "    ├── "
              local ss_icon = "⏳"
              local ss_text = "等待中"
              if s.status == "executing" then
                ss_icon = "🔄"
                ss_text = "执行中..."
              elseif s.status == "completed" then
                ss_icon = "✅"
                ss_text = string.format("(%.1fs)", s.duration or 0)
              elseif s.status == "error" then
                ss_icon = "❌"
                ss_text = string.format("(失败, %.1fs)", s.duration or 0)
              end
              -- 先渲染子步骤标题行
              text = text .. prefix .. ss_icon .. " " .. s.name .. " " .. ss_text .. "\n"
            end
          end
        end
      end
    end
    state.tool_display.buffer = text
  end

  -- 辅助：更新工具显示 buffer 中的状态图标
  local function update_tool_status(tool_name, icon, suffix)
    local escaped = tool_name:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
    local replaced = state.tool_display.buffer:gsub(
      "  🔄 " .. escaped .. " %(执行中%.%.%.%)",
      "  " .. icon .. " " .. tool_name .. " " .. suffix
    )
    if replaced == state.tool_display.buffer then
      state.tool_display.buffer =
        state.tool_display.buffer:gsub("  ⏳ " .. escaped, "  " .. icon .. " " .. tool_name .. " " .. suffix)
    else
      state.tool_display.buffer = replaced
    end
  end

  -- 构建流式工具调用预览 buffer（从 TOOL_CALL_DETECTED 的累积数据生成）
  -- 将 JSON 中的转义字符（\n、\t、\\ 等）渲染为可读格式
  local function escape_json_for_display(str)
    -- 先处理 \n（两个字符：反斜杠 + n）为真正换行
    str = str:gsub("\\n", "\n")
    -- 处理 \t 为制表符
    str = str:gsub("\\t", "\t")
    -- 处理 \\ 为单个反斜杠
    str = str:gsub("\\\\", "\\")
    -- 处理 \" 为 "
    str = str:gsub('\\"', '"')
    return str
  end

  function M.build_streaming_preview_buffer()
    local preview = state.tool_display.streaming_preview
    local tools = preview.tools or {}
    if not next(tools) then
      return "🔧 正在接收工具调用参数..."
    end

    local text = "🔧 工具调用（参数接收中...）"
    for _, t in pairs(tools) do
      text = text .. "\n\n  🔄 " .. t.name .. " (参数接收中...)"
      if t.arguments and t.arguments ~= "" then
        local display_args = escape_json_for_display(t.arguments)
        -- 将换行后的行加上缩进
        display_args = display_args:gsub("\n", "\n  ")
        text = text .. "\n  " .. display_args
      end
    end
    return text
  end

  -- 尝试将累积的 arguments JSON 片段解析为 table，增量更新 args_display
  local function try_parse_streaming_args(tool_entry)
    local raw = tool_entry.arguments or ""
    if raw == "" then
      return
    end
    -- 尝试直接解析（可能不完整，但能解析的部分就是已接收到的完整字段）
    local ok, parsed = pcall(vim.json.decode, raw)
    if ok and type(parsed) == "table" then
      tool_entry.args_display = parsed
    end
  end

  -- TOOL_CALL_DETECTED：流式响应中检测到工具调用
  -- 通过 tool_display_component 管理实时参数预览
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_CALL_DETECTED,
    callback = function(args)
      local data = args.data or {}
      if not is_current_window(data.window_id) then
        return
      end

      local tool_calls = data.tool_calls or {}
      if #tool_calls == 0 then
        return
      end

      local gen_id = data.generation_id

      -- 如果 TOOL_LOOP_STARTED 已经触发（工具循环已开始），不再处理流式预览
      if state.tool_display.active then
        return
      end

      -- 通过 tool_display_component 更新流式工具数据
      local tool_calls_delta = data.tool_calls_delta or {}
      tool_display_component.update_streaming_tools(tool_calls, tool_calls_delta, gen_id)

      -- 同步更新本地状态
      state.tool_display.streaming_preview.generation_id = gen_id
      state.tool_display.streaming_preview.tools = tool_display_component.get_streaming_preview_tools()

      -- 委托 tool_display_component 处理节流和预览窗口显示
      -- 注意：_pending_append 由 tool_display_component.update_streaming_tools 内部累积
      -- 不能直接检查 chat_window 本地状态的 _pending_append（两者不同步）
      tool_display_component.schedule_preview_update()
    end,
  })

  -- TOOL_LOOP_STARTED：工具循环开始
  -- 通过 tool_display_component 管理工具调用悬浮窗
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_LOOP_STARTED,
    callback = function(args)
      local data = args.data or {}
      if not is_current_window(data.window_id) then
        return
      end

      local tool_calls = data.tool_calls or {}
      if #tool_calls == 0 then
        return
      end

      clear_stream_throttle()

      -- 在清空流式状态之前，先保存思考过程内容并追加到缓冲区
      -- 因为 TOOL_LOOP_STARTED 会在 STREAM_COMPLETED 之前触发（当 AI 返回工具调用时）
      -- 如果不提前保存，思考过程折叠文本会丢失
      local saved_reasoning = state.streaming.reasoning_buffer or ""
      local saved_message_index = state.streaming.message_index
      if saved_reasoning ~= "" and saved_message_index then
        state.streaming.reasoning_active = false
        state.streaming.reasoning_done = true
        M._append_reasoning_folded_to_buffer(saved_reasoning)
      end

      local s = state.streaming
      s.active = false
      s.generation_id = nil
      s.message_index = nil
      s.content_buffer = ""
      s.reasoning_buffer = ""
      s.reasoning_active = false
      s.prefix_added = false
      s.reasoning_prefix_added = false
      s.content_separator_added = false
      s.message_start_line = nil
      state.tool_loop_in_progress = true

      -- 通过 tool_display_component 清理流式预览并初始化工具包分组
      tool_display_component.clear_streaming_preview()
      tool_display_component.init_packs(tool_calls, data.pack_order or {})

      -- 同步更新本地状态
      state.tool_display.streaming_preview.timer = nil
      state.tool_display.streaming_preview.generation_id = nil
      state.tool_display.streaming_preview.tools = {}
      state.tool_display.streaming_preview.window_shown = false
      state.tool_display.preview_window_id = nil

      state.tool_display.active = true
      state.tool_display.buffer = tool_display_component.get_buffer()
      state.tool_display.results = {}
      state.tool_display._finished = false
      state.tool_display.folded_saved = false
      state.tool_display.packs = tool_display_component.get_packs()
      state.tool_display.pack_order = tool_display_component.get_pack_order()
      state.tool_display.substeps = {}

      -- 仅在光标在后5行内时才显示工具调用悬浮窗
      local win = get_win()
      local near_end = cursor_near_end(win)
      state.should_follow = near_end
      if near_end then
        vim.schedule(function()
          tool_display_component.show_display()
          state.tool_display.window_id = tool_display_component.get_window_id()
          -- 如果悬浮窗已存在（上一轮未关闭），立即同步新内容
          tool_display_component._sync_display()
        end)
        _schedule_cursor_follow(150)
      else
        state.tool_display.active = false
      end
    end,
  })

  -- TOOL_EXECUTION_STARTED：工具开始执行
  -- 通过 tool_display_component 管理
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_EXECUTION_STARTED,
    callback = function(args)
      if state.closing or not is_current_window((args.data or {}).window_id) then
        return
      end
      local data = args.data or {}
      local pack_name = data.pack_name
      if pack_name and state.tool_display.packs[pack_name] then
        tool_display_component.update_tool_status(pack_name, data.tool_name, "executing", 0)
      end
    end,
  })

  -- TOOL_EXECUTION_ERROR：工具执行失败
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_EXECUTION_ERROR,
    callback = function(args)
      if state.closing or not is_current_window((args.data or {}).window_id) then
        return
      end
      local data = args.data or {}
      -- 收集结果（即使 tool_display.active 为 false）
      table.insert(state.tool_display.results, {
        tool_name = data.tool_name,
        arguments = data.args or {},
        result = "[失败] " .. (data.error_msg or "未知错误"),
        duration = data.duration or 0,
        is_error = true,
        pack_name = data.pack_name,
      })
      tool_display_component.add_result(state.tool_display.results[#state.tool_display.results])

      -- 如果折叠文本已写入 buffer，每次工具完成时更新 buffer 中的折叠文本
      if state.tool_display.folded_saved then
        local folded_text = tool_display_component.build_folded_text()
        if folded_text ~= "" then
          -- 更新 state.messages 中的折叠文本
          for i = #state.messages, 1, -1 do
            if state.messages[i].role == "assistant" and (state.messages[i].content or ""):find("^{{{") then
              state.messages[i].content = folded_text
              break
            end
          end
          -- 更新 buffer 中的折叠文本
          _update_folded_text_in_buffer(folded_text, data.window_id)
        end
      end

      if not state.tool_display.active then
        return
      end
      local pack_name = data.pack_name
      if pack_name and state.tool_display.packs[pack_name] then
        tool_display_component.update_tool_status(pack_name, data.tool_name, "error", data.duration or 0)
      end
    end,
  })

  -- TOOL_EXECUTION_SUBSTEP：工具执行子步骤状态更新
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_EXECUTION_SUBSTEP,
    callback = function(args)
      if state.closing or not is_current_window((args.data or {}).window_id) then
        return
      end
      if not state.tool_display.active then
        return
      end
      local data = args.data or {}
      if not data.tool_name or not data.substep_name then
        return
      end

      tool_display_component.update_substep(
        data.tool_name,
        data.substep_name,
        data.status or "pending",
        data.duration or 0,
        data.detail
      )
    end,
  })

  -- TOOL_EXECUTION_ALL_COMPLETED：本轮所有工具执行完毕，更新悬浮窗显示完成状态
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_EXECUTION_ALL_COMPLETED,
    callback = function(args)
      if state.closing or not is_current_window((args.data or {}).window_id) then
        return
      end
      if not state.tool_display.active then
        return
      end
      -- 触发 tool_display 重建 buffer（_rebuild_buffer 中 _all_tools_done 为 true 时会显示等待状态）
      tool_display_component._rebuild_buffer()
      tool_display_component._sync_display()
    end,
  })

  -- TOOL_EXECUTION_COMPLETED：工具执行成功
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_EXECUTION_COMPLETED,
    callback = function(args)
      if state.closing or not is_current_window((args.data or {}).window_id) then
        return
      end
      local data = args.data or {}
      -- 收集结果
      table.insert(state.tool_display.results, {
        tool_name = data.tool_name,
        arguments = data.args or {},
        result = data.result or "",
        duration = data.duration or 0,
        pack_name = data.pack_name,
      })
      tool_display_component.add_result(state.tool_display.results[#state.tool_display.results])

      -- 如果折叠文本已写入 buffer，每次工具完成时更新 buffer 中的折叠文本
      if state.tool_display.folded_saved then
        local folded_text = tool_display_component.build_folded_text()
        if folded_text ~= "" then
          -- 更新 state.messages 中的折叠文本
          for i = #state.messages, 1, -1 do
            if state.messages[i].role == "assistant" and (state.messages[i].content or ""):find("^{{{") then
              state.messages[i].content = folded_text
              break
            end
          end
          -- 更新 buffer 中的折叠文本
          _update_folded_text_in_buffer(folded_text, data.window_id)
        end
      end

      if not state.tool_display.active then
        return
      end
      local pack_name = data.pack_name
      if pack_name and state.tool_display.packs[pack_name] then
        tool_display_component.update_tool_status(pack_name, data.tool_name, "completed", data.duration or 0)
      end
    end,
  })

  -- TOOL_LOOP_FINISHED：工具循环结束
  -- is_round_end=true 时：关闭悬浮窗、写入折叠文本
  --   由工具完成触发时（AI 还在输出）：不重置 tool_loop_in_progress，不打开输入框
  --   由 AI 完成触发时：重置 tool_loop_in_progress，打开输入框
  -- is_round_end=false 时：不关闭悬浮窗，不写入折叠文本
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.TOOL_LOOP_FINISHED,
    callback = function(args)
      if state.closing then
        return
      end
      local data = args.data or {}
      if not is_current_window(data.window_id) then
        return
      end

      local is_round_end = data.is_round_end == true

      -- 通过 tool_display_component 清理流式预览
      tool_display_component.clear_streaming_preview()
      state.tool_display.streaming_preview.timer = nil
      state.tool_display.streaming_preview.generation_id = nil
      state.tool_display.streaming_preview.tools = {}
      state.tool_display.streaming_preview.window_shown = false
      state.tool_display.streaming_preview._pending_append = ""
      state.tool_display.preview_window_id = nil

      if not is_round_end then
        -- 非本轮结束（下一轮开始前）：不关闭悬浮窗，不写入折叠文本
        return
      end

      -- ===== 本轮结束：关闭悬浮窗、写入折叠文本 =====

      if state.tool_display._finished then
        -- 即使 _finished=true，如果 results 有新增，更新 state.messages 和 buffer 中的折叠文本
        -- 但不重新追加新消息（避免重复），只更新已有内容
        local results = state.tool_display.results or {}
        if #results > 0 then
          local folded_text = tool_display_component.build_folded_text()
          if folded_text ~= "" then
            -- 更新 state.messages 中的折叠文本
            for i = #state.messages, 1, -1 do
              if state.messages[i].role == "assistant" and (state.messages[i].content or ""):find("^{{{") then
                state.messages[i].content = folded_text
                break
              end
            end
            -- 更新 buffer 中已有的折叠文本（如果之前已写入 buffer）
            if state.tool_display.folded_saved then
              _update_folded_text_in_buffer(folded_text, data.window_id)
            end
          end
        end
        -- 确保悬浮窗关闭
        if state.tool_display.active then
          close_tool_display()
        end
        state.tool_display.active = false
        fire_event(Events.TOOL_DISPLAY_CLOSED, {
          window_id = data.window_id,
          session_id = data.session_id,
          generation_id = data.generation_id,
        })
        return
      end
      state.tool_display._finished = true

      clear_stream_throttle()

      -- 调试日志：打印 results 数量
      local debug_results = state.tool_display.results or {}
      require("NeoAI.utils.logger").debug("[TOOL_LOOP_FINISHED] results count=%d, folded_saved=%s", #debug_results, tostring(state.tool_display.folded_saved))
      for _, dr in ipairs(debug_results) do
        require("NeoAI.utils.logger").debug("[TOOL_LOOP_FINISHED]   tool=%s, pack=%s", dr.tool_name or "nil", dr.pack_name or "nil")
      end

      -- 生成折叠文本并写入缓冲区
      local results = state.tool_display.results or {}
      if #results > 0 or state.tool_display.buffer ~= "" then
        local folded_text = tool_display_component.build_folded_text()
        require("NeoAI.utils.logger").debug("[TOOL_LOOP_FINISHED] folded_text length=%d, contains %d {{{ blocks", #folded_text, select(2, folded_text:gsub("{{{", "")))
        if folded_text == "" then
          folded_text = "{{{ 🔧 工具调用\n  ❌ 所有工具调用均失败\n}}}"
        end

        -- 查找是否已有折叠消息，有则更新，无则插入（避免每次迭代累积多条）
        local existing_idx = nil
        for i = #state.messages, 1, -1 do
          if state.messages[i].role == "assistant" and (state.messages[i].content or ""):find("^{{{") then
            existing_idx = i
            break
          end
        end
        if existing_idx then
          state.messages[existing_idx].content = folded_text
        else
          table.insert(state.messages, { role = "assistant", content = folded_text, timestamp = os.time() })
        end
        -- 仅在第一次写入缓冲区，后续迭代只更新 state.messages
        if not state.tool_display.folded_saved then
          state.tool_display.folded_saved = true
          M._append_message_to_buffer("assistant", folded_text, data.window_id)
        end
      end
      if state.tool_display.active then
        close_tool_display()
      end

      state.tool_display.active = false
      close_reasoning_display()
      -- 记录折叠文本是否已通过 _append_message_to_buffer 写入缓冲区
      -- 必须在 reset_streaming_state 之前读取，因为 reset_streaming_state 会重置 streaming 状态
      local folded_already_appended = state.tool_display.folded_saved
      reset_streaming_state()
      -- 如果折叠文本已写入缓冲区，设置 prefix_added 标记
      -- 这样后续 GENERATION_COMPLETED 回调中 had_stream_prefix 为 true，避免重复追加
      if folded_already_appended then
        state.streaming.prefix_added = true
      end
      fire_event(Events.TOOL_DISPLAY_CLOSED, {
        window_id = data.window_id,
        session_id = data.session_id,
        generation_id = data.generation_id,
      })

      -- 根据触发来源决定后续行为
      -- trigger_source="tools_complete"：工具完成触发，AI 还在输出
      --   不重置 tool_loop_in_progress，不打开输入框（由后续 GENERATION_COMPLETED 处理）
      -- trigger_source="ai_complete"：AI 完成触发
      --   重置 tool_loop_in_progress，打开输入框
      if data.trigger_source == "ai_complete" then
        state.tool_loop_in_progress = false
        M._open_float_input()
        local chat_handlers = require("NeoAI.ui.handlers.chat_handlers")
        if virtual_input.is_active() and chat_handlers.get_should_follow() then
          virtual_input.focus_and_insert()
        end
      end
      -- tools_complete 触发时不操作，由后续 GENERATION_COMPLETED 处理
    end,
  })

  -- GENERATION_CANCELLED：生成取消
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.GENERATION_CANCELLED,
    callback = function(args)
      if state.closing then
        return
      end
      -- 保存用量信息（如果有）
      local data = args.data or {}
      if data.usage and next(data.usage) then
        state.last_usage = data.usage
      end
      cancel_reasoning_timer()
      close_reasoning_display()
      -- 关闭工具调用悬浮窗
      close_tool_display()
      reset_tool_display()
      clear_stream_throttle()
      reset_streaming_state()
      state.tool_loop_in_progress = false
      state.generation_in_progress = false
      M._update_usage_virt_text()
      -- 根据光标位置决定是否打开输入框
      local cancel_win = get_win()
      if cancel_win and vim.api.nvim_win_is_valid(cancel_win) then
        local cancel_cursor = vim.api.nvim_win_get_cursor(cancel_win)
        local cancel_buf = vim.api.nvim_win_get_buf(cancel_win)
        local cancel_total = vim.api.nvim_buf_line_count(cancel_buf)
        if cancel_total - cancel_cursor[1] <= 5 then
          M._open_float_input()
        end
        -- 光标不在后5行内：不打开输入框
      end
      M.show_floating_text("AI生成已取消", { timeout = 3000, position = "center", border = "single" })
    end,
  })

  -- SESSION_RENAMED：更新 buffer 名称
  vim.api.nvim_create_autocmd("User", {
    pattern = Events.SESSION_RENAMED,
    callback = function(args)
      local data = args.data or {}
      if not data.session_id or data.session_id ~= state.current_session_id then
        return
      end
      local buf = get_buf()
      if buf_valid(buf) then
        pcall(vim.api.nvim_buf_set_name, buf, "neoai://chat/" .. data.session_id .. " - " .. (data.name or ""))
      end
    end,
  })

  -- VimResized：窗口大小变化时动态调整工具调用悬浮窗和虚拟输入框位置
  -- 通过 tool_display_component 和 window_manager 管理
  vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      -- 调整工具调用悬浮窗
      if state.tool_display.window_id then
        local window_info = window_manager.get_window_info(state.tool_display.window_id)
        if window_info and window_info.win and vim.api.nvim_win_is_valid(window_info.win) then
          local lines = vim.split(state.tool_display.buffer or "", "\n")
          local max_tool_height = math.max(5, math.floor(vim.o.lines / 2))
          local dynamic_height = math.max(5, math.min(#lines + 2, max_tool_height))
          local config = vim.api.nvim_win_get_config(window_info.win)
          config.height = dynamic_height
          local total_cols = vim.o.columns
          config.width = math.floor(total_cols * 0.8)
          config.col = math.floor((total_cols - config.width) / 2)
          local tool_row = 1
          if reasoning_display.is_visible() then
            local rwid = reasoning_display.get_window_id()
            if rwid then
              local rwin = window_manager.get_window_win(rwid)
              if rwin and vim.api.nvim_win_is_valid(rwin) then
                local rc = vim.api.nvim_win_get_config(rwin)
                tool_row = (rc.row or 1) + (rc.height or 5) + 1
              end
            end
          end
          config.row = tool_row
          pcall(vim.api.nvim_win_set_config, window_info.win, config)

          vim.api.nvim_exec_autocmds("User", {
            pattern = "NeoAI:tool_display_resized",
            data = {
              window_id = state.tool_display.window_id,
              height = dynamic_height,
              row = tool_row,
              width = config.width,
              col = config.col,
            },
          })
        end
      end

      -- 调整虚拟输入框位置
      if virtual_input.is_active() then
        virtual_input.reposition()
      end
    end,
    desc = "窗口大小变化时调整工具调用悬浮窗和虚拟输入框位置",
  })
end

--- 设置光标移动监听
--- 当用户在 chat 窗口中手动移动光标到非末尾位置时，取消自动光标跟随
function M._setup_cursor_moved_listener()
  -- 清理旧的自动命令组
  if state.cursor_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.cursor_augroup)
    state.cursor_augroup = nil
  end

  local win_handle = window_manager.get_window_win(state.current_window_id)
  if not win_handle or not vim.api.nvim_win_is_valid(win_handle) then
    return
  end

  local buf = vim.api.nvim_win_get_buf(win_handle)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  state.cursor_augroup = vim.api.nvim_create_augroup("NeoAIChatCursorMoved", { clear = true })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.cursor_augroup,
    buffer = buf,
    callback = function()
      -- 检查当前焦点是否在 chat 窗口
      local current_win = vim.api.nvim_get_current_win()
      if current_win ~= win_handle then
        return
      end

      -- 检测光标是否在末尾附近（后5行内）
      local cursor = vim.api.nvim_win_get_cursor(win_handle)
      local total = vim.api.nvim_buf_line_count(buf)
      local near_end = total - cursor[1] <= 5

      -- 更新模块级 state 缓存
      state.should_follow = near_end
    end,
    desc = "检测用户手动移动光标位置，更新光标跟随状态",
  })
end

--- 获取当前聊天窗口的窗口ID
--- @return string|nil 窗口ID，如果没有打开的窗口则返回nil
function M.get_current_window_id()
  return state.current_window_id
end

--- 获取聊天窗口中的消息
--- @return table 消息列表
function M.get_messages()
  return state.messages or {}
end

--- 设置聊天窗口中的消息
--- @param messages table 消息列表
--- @return boolean 是否成功
function M.set_messages(messages)
  if not messages or type(messages) ~= "table" then
    return false
  end

  state.messages = messages

  -- 如果窗口打开，更新显示
  if state.current_window_id then
    M.render_chat()
  end

  return true
end

--- 更新特定消息
--- @param index number 消息索引（1-based）
--- @param content string 新的消息内容
--- @return boolean 是否成功
function M.update_message(index, content)
  if not state.messages or index < 1 or index > #state.messages then
    return false
  end

  if not content or type(content) ~= "string" then
    return false
  end

  state.messages[index].content = content

  -- 如果窗口打开，更新显示
  if state.current_window_id then
    M.render_chat()
  end

  return true
end

--- 将单条消息增量追加到缓冲区末尾（避免全量重渲染）
--- @param role string 角色 ('user' 或 'assistant')
--- @param content string 消息内容
--- @param window_id string|nil 可选，指定目标窗口 ID，默认使用 state.current_window_id
function M._append_message_to_buffer(role, content, window_id)
  local target_window_id = window_id or state.current_window_id
  if not target_window_id or not content then
    return
  end

  local buf = window_manager.get_window_buf(target_window_id)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 验证 buffer 是 neoai 类型，防止写入到非聊天 buffer
  if not _is_chat_buffer(buf) then
    return
  end

  -- 在修改 buffer 内容之前缓存光标位置
  _check_cursor_near_end()

  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = buf })

  -- 使用 _render_single_message 生成文本行
  local msg = { role = role, content = content }
  local prev_role = nil
  if #state.messages >= 2 then
    -- 获取上一条消息的角色（排除当前刚添加的消息）
    prev_role = state.messages[#state.messages - 1].role
  end
  local lines = M._render_single_message(msg, prev_role)

  -- 获取当前行数
  local line_count = vim.api.nvim_buf_line_count(buf)

  -- 追加消息内容
  vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, lines)
  -- 注意：不追加分割线，分割线只在 _do_render_chat 全量重渲染时添加

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })

  -- 执行光标跟随（使用协程共享表 should_follow 缓存值）
  _schedule_cursor_follow()
end

--- 替换缓冲区中指定消息的行（从起始行到末尾或到指定结束行）
--- 用于流式渲染时更新已追加到缓冲区的消息内容
--- @param start_line number 起始行号（0-based）
--- @param lines table 新行列表
--- @param end_line number|nil 结束行号（0-based），nil 表示替换到末尾
local function _replace_message_in_buffer(start_line, lines, end_line)
  local buf = get_buf()
  if not buf_valid(buf) then
    return
  end

  -- 验证 buffer 是 neoai 类型，防止窗口关闭后写入其他 buffer
  if not _is_chat_buffer(buf) then
    return
  end

  set_buf_modifiable(buf, true)
  local lc = get_line_count(buf)
  local replace_end = end_line or lc
  -- 确保起始行有效
  if start_line < 0 or start_line > lc then
    return
  end
  -- 如果新行数比旧行数多，需要先扩展；如果少，需要先删除多余行
  local old_count = replace_end - start_line
  local new_count = #lines
  if new_count > old_count then
    -- 需要插入空行
    local insert_count = new_count - old_count
    local insert_lines = {}
    for _ = 1, insert_count do
      table.insert(insert_lines, "")
    end
    vim.api.nvim_buf_set_lines(buf, replace_end, replace_end, false, insert_lines)
  elseif new_count < old_count then
    -- 需要删除多余行
    local delete_count = old_count - new_count
    vim.api.nvim_buf_set_lines(buf, replace_end - delete_count, replace_end, false, {})
  end
  -- 写入新内容
  vim.api.nvim_buf_set_lines(buf, start_line, start_line + new_count, false, lines)
  vim.api.nvim_set_option_value("modified", false, { buf = buf })
end

--- 使用 _render_single_message 渲染当前流式消息并替换缓冲区中的对应行
--- 统一流式渲染和历史渲染的显示格式
--- 在流式 chunk 到达或思考过程完成时调用
--- @param window_id string|nil 可选，指定目标窗口 ID，默认使用 state.current_window_id
local function _render_streaming_message(window_id)
  local mi = state.streaming.message_index
  if not mi or not state.messages[mi] then
    return
  end
  local msg = state.messages[mi]
  -- 使用 _render_single_message 生成行列表
  local prev_role = nil
  if mi > 1 then
    prev_role = state.messages[mi - 1].role
  end
  local lines = M._render_single_message(msg, prev_role)
  if #lines == 0 then
    return
  end
  local target_window_id = window_id or state.current_window_id
  local buf = target_window_id and window_manager.get_window_buf(target_window_id) or get_buf()
  if not buf_valid(buf) then
    return
  end

  -- 验证 buffer 是 neoai 类型，防止窗口关闭后写入其他 buffer
  if not _is_chat_buffer(buf) then
    return
  end

  -- 在修改 buffer 内容之前缓存光标位置
  _check_cursor_near_end()
  local start_line = state.streaming.message_start_line
  if start_line then
    -- 已有起始行：替换从起始行到末尾的内容
    _replace_message_in_buffer(start_line, lines)
  else
    -- 没有起始行：追加到缓冲区末尾
    set_buf_modifiable(buf, true)
    local lc = get_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, lc, lc, false, lines)
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    -- 记录起始行
    state.streaming.message_start_line = lc
  end
  _schedule_cursor_follow()
end

--- 将思考过程追加到聊天缓冲区末尾
--- 在思考过程完成后调用
--- 逻辑：
---   如果思考过程结束后没有正文（content_buffer 为空）且思考长度 < 200 字符，则不折叠直接显示
---   否则（有正文或思考长度 >= 200 字符）使用折叠格式 {{{ ... }}}
--- @param reasoning_text string 完整的思考过程文本
--- @param window_id string|nil 可选，指定目标窗口 ID，默认使用 state.current_window_id
function M._append_reasoning_folded_to_buffer(reasoning_text, window_id)
  if not state.current_window_id or not reasoning_text or reasoning_text == "" then
    return
  end

  -- 更新 state.messages 中的内容为 JSON 格式（含 reasoning_content）
  -- 这样 _render_single_message 可以正确解析并渲染
  local mi = state.streaming.message_index
  local full_content = state.streaming.content_buffer or ""
  local encoded = vim.json.encode({
    reasoning_content = reasoning_text,
    content = full_content,
  })
  if mi and state.messages[mi] then
    state.messages[mi].content = encoded
  end

  -- 使用 _render_streaming_message 统一渲染（复用 _render_single_message）
  _render_streaming_message(window_id)
end

--- 在缓冲区末尾插入一个空行（处理换行符数据块）
function M._append_newline_to_buffer()
  if not state.current_window_id then
    return
  end
  local buf = window_manager.get_window_buf(state.current_window_id)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 验证 buffer 是 neoai 类型，防止窗口关闭后写入其他 buffer
  if not _is_chat_buffer(buf) then
    return
  end
  -- 在修改 buffer 内容之前缓存光标位置
  _check_cursor_near_end()
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = buf })
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "" })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
  _schedule_cursor_follow()
end

--- 追加流式数据块到缓冲区（增量渲染）
--- @param chunk_content string 数据块内容
--- @param content_type string|nil 内容类型 ("reasoning" 或 "content")
--- @param window_id string|nil 可选，指定目标窗口 ID，默认使用 state.current_window_id
function M._append_stream_chunk_to_buffer(chunk_content, content_type, window_id)
  local target_window_id = window_id or state.current_window_id
  if not target_window_id then
    return
  end

  -- 更新消息列表中的累积内容，并同步保存到历史文件
  local mi = state.streaming.message_index
  if mi and state.messages[mi] then
    local full = state.streaming.content_buffer or ""
    local rt = state.streaming.reasoning_buffer or ""
    local new_content = (rt ~= "") and { reasoning_content = rt, content = full } or { content = full }
    state.messages[mi].content = (rt ~= "") and vim.json.encode({ reasoning_content = rt, content = full }) or full

    -- 流式更新保存到 history_manager
    -- 每 10 次更新触发一次防抖保存，确保流式内容不会丢失
    local hm_ok, hm = pcall(require, "NeoAI.core.history.manager")
    if hm_ok and hm.is_initialized() then
      local session = hm.get_current_session()
      if session then
        hm.update_last_assistant(session.id, new_content)
        -- 定期保存：每 10 次 chunk 触发一次防抖保存
        state.streaming._save_counter = (state.streaming._save_counter or 0) + 1
        if state.streaming._save_counter >= 10 then
          state.streaming._save_counter = 0
          hm._mark_dirty()
        end
      end
    end
  end

  -- 使用 _render_streaming_message 统一渲染（复用 _render_single_message）
  _render_streaming_message(window_id)
end

--- 完成流式渲染
--- 将累积的流式内容临时保存到消息列表中，并触发全量重渲染
--- 注意：流式完成后服务器会重新发送完整正文（通过 NeoAI:generation_completed 事件），
--- 所以这里只做临时保存，最终内容由 generation_completed 事件处理替换
function M._finalize_streaming()
  if not state.streaming.active then
    return
  end

  local message_index = state.streaming.message_index
  local full_content = state.streaming.content_buffer or ""
  local reasoning_text = state.streaming.reasoning_buffer or ""

  -- 临时保存累积内容到消息列表（后续会被 generation_completed 的完整响应替换）
  if message_index and state.messages[message_index] then
    if reasoning_text and reasoning_text ~= "" then
      local combined = vim.json.encode({
        reasoning_content = reasoning_text,
        content = full_content,
      })
      state.messages[message_index].content = combined
    else
      state.messages[message_index].content = full_content
    end
  end

  -- 更新已持久化的占位符消息（而不是添加新消息）
  if reasoning_text and reasoning_text ~= "" then
    local combined = vim.json.encode({
      reasoning_content = reasoning_text,
      content = full_content,
    })
    M._update_persisted_message("assistant", combined)
  elseif full_content and full_content ~= "" then
    M._update_persisted_message("assistant", full_content)
  end

  -- 不进行全量重渲染，流式内容已通过 _append_stream_chunk_to_buffer 增量追加到缓冲区
  -- 只需确保 state.messages 中的数据正确即可
  -- 注意：不重置 message_index，保留供 generation_completed 事件使用
  -- 重置其他状态
  state.streaming.active = false
  state.streaming.content_buffer = ""
  state.streaming.reasoning_buffer = ""
  state.streaming.reasoning_active = false
  state.streaming.reasoning_done = false
  state.streaming.prefix_added = false
  state.streaming.reasoning_prefix_added = false
  state.streaming.content_separator_added = false
end

--- 显示工具调用悬浮窗口（委托给 tool_display_component）
--- @param is_preview boolean 是否为实时参数预览窗口
function M._show_tool_display(is_preview)
  if is_preview then
    if state.tool_display.preview_window_id then
      return
    end
    tool_display_component.show_preview()
    state.tool_display.preview_window_id = tool_display_component.get_preview_window_id()
  else
    if state.tool_display.window_id then
      return
    end
    tool_display_component.show_display()
    state.tool_display.window_id = tool_display_component.get_window_id()
  end
end

--- 更新工具调用悬浮窗内容（委托给 tool_display_component）
function M._update_tool_display()
  tool_display_component.update_display()
end

--- 获取工具调用悬浮窗的窗口ID
--- @return string|nil
function M.get_tool_display_window_id()
  if state.tool_display and state.tool_display.active and state.tool_display.window_id then
    return state.tool_display.window_id
  end
  return nil
end

--- 关闭工具调用悬浮窗口
function M._close_tool_display()
  tool_display_component._close_display()
  state.tool_display.window_id = nil
end

--- 构建工具调用结果的折叠文本（委托给 tool_display_component）
--- @param results table 工具调用结果列表
--- @return string 折叠文本格式的字符串
function M._build_tool_folded_text(results)
  return tool_display_component.build_folded_text()
end

--- 获取当前使用的模型标签
--- @return string|nil 模型标签，如 "deepseek/deepseek-chat"
function M._get_current_model_label()
  -- 使用 get_available_models 获取所有可用模型
  local models = config_merger.get_available_models("chat")
  local target = models[state.current_model_index]
  if target then
    return string.format("%s/%s", target.provider or "?", target.model_name or "?")
  end
  return nil
end

--- 获取当前使用的模型候选索引
--- @return number 当前模型索引（1-based）
function M.get_current_model_index()
  return state.current_model_index or 1
end

--- 显示模型选择器（浮动窗口菜单）
--- 列出当前场景（chat）内所有场景候选，用户选择后切换
function M.show_model_selector()
  if not state.current_window_id then
    return
  end

  -- 使用 get_available_models 获取所有可用模型（所有提供商，所有模型）
  local models = config_merger.get_available_models("chat")

  if #models == 0 then
    vim.notify("[NeoAI] 没有可用的模型（请检查 API key 配置）", vim.log.levels.WARN)
    return
  end

  -- 构建选择菜单项
  local items = {}
  for i, m in ipairs(models) do
    local indicator = (i == state.current_model_index) and "✓ " or "  "
    table.insert(items, string.format("%s%s/%s", indicator, m.provider or "?", m.model_name or "?"))
  end

  local current_label = "未知"
  local current = models[state.current_model_index]
  if current then
    current_label = string.format("%s/%s", current.provider or "?", current.model_name or "?")
  end

  vim.ui.select(items, {
    prompt = "选择 AI 模型 (当前: " .. current_label .. ")",
    format_item = function(item)
      return item
    end,
  }, function(choice, idx)
    if choice and idx and idx ~= state.current_model_index then
      M.switch_to_model(idx)
    end
  end)
end

--- 切换到当前场景内的指定模型候选
--- @param model_index number 模型候选索引（1-based）
function M.switch_to_model(model_index)
  if not model_index or model_index == state.current_model_index then
    return
  end

  -- 使用 get_available_models 获取所有可用模型
  local models = config_merger.get_available_models("chat")
  local target = models[model_index]

  if not target then
    vim.notify("[NeoAI] 无效的模型索引: " .. tostring(model_index), vim.log.levels.WARN)
    return
  end

  local old_index = state.current_model_index
  state.current_model_index = model_index

  -- 更新聊天窗口标题
  M.update_title(string.format("NeoAI 聊天 [%s/%s]", target.provider or "?", target.model_name or "?"))

  -- 重新渲染聊天内容（标题区域会显示新模型）
  M.render_chat()

  -- 触发模型切换事件
  vim.api.nvim_exec_autocmds("User", {
    pattern = Events.MODEL_SWITCHED,
    data = {
      old_index = old_index,
      new_index = model_index,
      provider = target.provider,
      model_name = target.model_name,
      window_id = state.current_window_id,
    },
  })

  local label = string.format("%s/%s", target.provider or "?", target.model_name or "?")
  vim.notify(string.format("[NeoAI] 已切换到模型: %s", label), vim.log.levels.INFO)
end

--- 获取最后一条 assistant 消息的内容
--- 供 chat_handlers 在保存历史时获取包含折叠文本的完整内容
--- @return string|nil
function M.get_last_assistant_content()
  for i = #state.messages, 1, -1 do
    if state.messages[i].role == "assistant" then
      return state.messages[i].content
    end
  end
  return nil
end

--- 将最终回复内容保存到 history_manager
--- 在 GENERATION_COMPLETED 回调中调用
--- 由 history_saver 模块通过事件监听统一处理（队列异步写入，保证原子性）
--- 此函数仅负责构建最终内容字符串，不再直接调用 add_assistant_entry
--- @param data table GENERATION_COMPLETED 事件数据
--- @return string|nil 构建的最终内容（供 saver 使用），nil 表示无需保存
function M._save_final_content_to_history(data)
  local session_id = data.session_id
  if not session_id then
    return nil
  end

  -- 获取最终回复内容（优先使用 state.messages 中的折叠文本）
  local response = data.response
  local reasoning_text = data.reasoning_text or ""

  local response_content = ""
  if type(response) == "string" then
    response_content = response
  elseif type(response) == "table" and response.content then
    response_content = response.content
  else
    response_content = tostring(response)
  end

  -- 检查是否有工具调用结果，构建含折叠文本的最终回复
  local has_tool_results = state.tool_display.active and #state.tool_display.results > 0
  local folded_saved = state.tool_display.folded_saved

  -- 构建最终内容：优先从 state.messages 中获取已合并的完整内容（含折叠文本+AI回复）
  local final_content = response_content
  if has_tool_results or folded_saved then
    local last_assistant_content = M.get_last_assistant_content()
    if last_assistant_content and last_assistant_content ~= "" then
      -- 如果最后一条 assistant 内容以折叠文本开头，说明是工具调用折叠文本
      -- 注意：在 GENERATION_COMPLETED 回调中，折叠文本可能已被追加了 AI 回复
      -- （state.messages[folded_idx].content = folded_text .. "\n\n" .. append_content）
      -- 所以直接使用 last_assistant_content 即可，无需再次追加 response_content
      if last_assistant_content:match("^{{{") then
        final_content = last_assistant_content
      else
        final_content = last_assistant_content
      end
    elseif has_tool_results then
      -- 如果 state.messages 中没有 assistant 消息，从 tool_display 构建折叠文本
      local folded = M._build_tool_folded_text(state.tool_display.results)
      if folded ~= "" then
        final_content = (response_content ~= "") and (folded .. "\n\n" .. response_content) or folded
      end
    end
  end

  if final_content == "" and reasoning_text == "" then
    return nil
  end

  -- 返回构建的最终内容，由 history_saver 通过事件监听统一保存
  return {
    content = final_content,
    reasoning_content = reasoning_text,
  }
end

--- 获取当前流式状态中的已生成内容
--- 供 chat_handlers 在取消生成时获取已生成的思考过程和正文
--- @return table|nil { reasoning_buffer: string, content_buffer: string }
function M.get_streaming_content()
  if not state.streaming.active and state.streaming.reasoning_buffer == "" and state.streaming.content_buffer == "" then
    return nil
  end
  return {
    reasoning_buffer = state.streaming.reasoning_buffer or "",
    content_buffer = state.streaming.content_buffer or "",
  }
end

-- 暴露内部函数供其他模块使用
M._schedule_cursor_follow = _schedule_cursor_follow
M._do_cursor_follow = _do_cursor_follow
M._check_cursor_near_end = _check_cursor_near_end

--- 设置光标跟随缓存变量（供 virtual_input 等外部模块调用）
--- @param should boolean 是否应该跟随
function M._set_cursor_follow_should(should)
  state.should_follow = should
end

return M
