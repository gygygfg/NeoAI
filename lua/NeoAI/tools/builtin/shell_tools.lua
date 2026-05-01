-- Lua Shell 工具模块（使用Neovim伪终端 + PID进程监控）
-- 提供执行 shell 命令的工具，支持交互式命令的自动处理
-- 在伪终端中启动shell，获取PID后通过exec替换进程，监控进程状态
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- ============================================================================
-- 特殊按键映射表
-- ============================================================================
-- 将可读的按键名称转换为终端控制序列
-- AI 可以在 input 参数中使用这些标记来发送特殊按键
local KEY_MAP = {
  ["<enter>"] = "\r",
  ["<up>"] = "\027[A",
  ["<down>"] = "\027[B",
  ["<right>"] = "\027[C",
  ["<left>"] = "\027[D",
  ["<ctrl_c>"] = "\x03",
  ["<ctrl_d>"] = "\x04",
  ["<tab>"] = "\t",
  ["<escape>"] = "\027",
  ["<backspace>"] = "\x7f",
  ["<home>"] = "\027[H",
  ["<end>"] = "\027[F",
  ["<page_up>"] = "\027[5~",
  ["<page_down>"] = "\027[6~",
  ["<del>"] = "\027[3~",
  ["<insert>"] = "\027[2~",
  ["<f1>"] = "\027OP",
  ["<f2>"] = "\027OQ",
  ["<f3>"] = "\027OR",
  ["<f4>"] = "\027OS",
  ["<f5>"] = "\027[15~",
  ["<f6>"] = "\027[17~",
  ["<f7>"] = "\027[18~",
  ["<f8>"] = "\027[19~",
  ["<f9>"] = "\027[20~",
  ["<f10>"] = "\027[21~",
  ["<f11>"] = "\027[23~",
  ["<f12>"] = "\027[24~",
}

-- 将特殊按键标记转换为实际控制序列
local function resolve_key_sequences(text)
  if not text then
    return ""
  end
  for pattern, replacement in pairs(KEY_MAP) do
    text = text:gsub(pattern, replacement)
  end
  return text
end

-- ============================================================================
-- Shell Session 管理器
-- ============================================================================
local sessions = {}
local session_counter = 0

-- ============================================================================
-- PTY 浮动窗口管理
-- ============================================================================
-- 存储当前正在显示的 PTY 浮动窗口信息
-- 格式: { win_id = string, win = number, buf = number, session_id = string }
local pty_float_window = nil

--- 获取屏幕尺寸信息
local function get_screen_dimensions()
  return vim.o.columns, vim.o.lines
end

--- 关闭 PTY 浮动窗口
local function close_pty_float_window()
  if not pty_float_window then
    return
  end

  if pty_float_window.win and vim.api.nvim_win_is_valid(pty_float_window.win) then
    pcall(vim.api.nvim_win_close, pty_float_window.win, true)
  end
  if pty_float_window.buf and vim.api.nvim_buf_is_valid(pty_float_window.buf) then
    pcall(vim.api.nvim_buf_delete, pty_float_window.buf, { force = true })
  end

  pty_float_window = nil
end

--- 创建右侧 PTY 浮动窗口
local function create_pty_float_window(session_id, pty_buf)
  -- 先关闭已有的 PTY 浮动窗口
  if pty_float_window then
    close_pty_float_window()
  end

  local total_cols, total_lines = get_screen_dimensions()
  local left_width = math.floor(total_cols / 2) - 1
  local right_col = left_width + 2 -- 留 1 列间隙
  local right_width = total_cols - right_col - 1
  if right_width < 20 then
    right_width = 20
    right_col = total_cols - right_width - 1
  end

  -- 计算高度：从屏幕顶部到底部，留出底部状态栏空间
  local win_height = total_lines - 2 -- 留底部 2 行
  local win_row = 1

  -- 创建浮动窗口
  local pty_border = {
    { "╭", "FloatBorder" },
    { "─", "FloatBorder" },
    { "╮", "FloatBorder" },
    { "│", "FloatBorder" },
    { "╯", "FloatBorder" },
    { "─", "FloatBorder" },
    { "╰", "FloatBorder" },
    { "│", "FloatBorder" },
  }

  local buf
  if pty_buf and vim.api.nvim_buf_is_valid(pty_buf) then
    buf = pty_buf
  else
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "delete", { buf = buf })
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = right_width,
    height = win_height,
    row = win_row,
    col = right_col,
    style = "minimal",
    border = pty_border,
    title = "💻 终端",
    title_pos = "center",
    zindex = 150,
  })

  if not win or not vim.api.nvim_win_is_valid(win) then
    if not pty_buf then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    return nil
  end

  vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder", { win = win })

  -- 设置 PTY 窗口的按键映射（允许用户手动关闭）
  local buf_keymaps = buf
  vim.keymap.set("n", "q", function()
    close_pty_float_window()
  end, { buffer = buf_keymaps, noremap = true, silent = true, desc = "关闭终端窗口" })
  vim.keymap.set("n", "<Esc>", function()
    -- 只在非终端模式（normal模式）下按Esc关闭
    local mode = vim.api.nvim_get_mode().mode
    if mode == "n" then
      close_pty_float_window()
    end
  end, { buffer = buf_keymaps, noremap = true, silent = true, desc = "关闭终端窗口" })

  pty_float_window = {
    win = win,
    buf = buf,
    session_id = session_id,
  }

  return win
end

-- 伪终端配置
local PTY_CONFIG = {
  width = 80,
  height = 24,
  ansi = true,
  env = vim.empty_dict(),
  clear_env = false,
  cwd = nil,
  detach = false,
  pty = true,
  input = "pipe",
  output = "pipe",
  error = "pipe",
  check_interval = 100, -- 状态检查间隔（毫秒）
  max_wait_time = 30, -- 等待输入的最大时间（秒）
  buffer_size = 1024 * 64, -- 64KB
}

-- 进程状态监控器
local ProcessMonitor = {}
ProcessMonitor.__index = ProcessMonitor

function ProcessMonitor.new(pid, session_id)
  local self = setmetatable({}, ProcessMonitor)
  self.pid = pid
  self.session_id = session_id
  self.monitor_timer = nil
  self.last_state = nil
  self.waiting_since = nil
  self.is_waiting_for_input = false
  self.state_history = {}
  return self
end

-- 检查进程状态
function ProcessMonitor:check_process_state()
  if not self.pid then
    return nil, "No PID"
  end

  -- 读取 /proc/<pid>/stat 文件
  local stat_path = "/proc/" .. self.pid .. "/stat"
  local stat_file = io.open(stat_path, "r")
  if not stat_file then
    return nil, "Process not found"
  end

  local stat_data = stat_file:read("*a")
  stat_file:close()

  if not stat_data then
    return nil, "Failed to read stat"
  end

  -- 解析 stat 文件格式：pid (comm) state ppid pgrp session tty_nr tpgid ...
  local close_paren = stat_data:find(")")
  if not close_paren then
    return nil, "Invalid stat format"
  end

  -- 获取状态字符（第三个字段）
  local state_char = stat_data:sub(close_paren + 2, close_paren + 2)
  if not state_char or state_char == "" then
    return nil, "No state char"
  end

  -- 获取进程名
  local comm = stat_data:sub(stat_data:find("%(") + 1, close_paren - 1)

  -- 获取 tty（第七个字段）
  local fields = {}
  for field in stat_data:sub(close_paren + 2):gmatch("%S+") do
    table.insert(fields, field)
  end

  local tty_nr = fields[4] -- 索引从0开始，所以tty是第7个字段

  -- 检查进程是否在等待终端输入
  local is_waiting = false
  local waiting_reason = ""

  if state_char == "S" or state_char == "D" then
    -- 检查等待通道
    local wchan_path = "/proc/" .. self.pid .. "/wchan"
    local wchan_file = io.open(wchan_path, "r")
    if wchan_file then
      local wchan = wchan_file:read("*l")
      wchan_file:close()

      if wchan then
        -- 检查是否在等待终端输入
        if
          wchan:match("tty_read")
          or wchan:match("n_tty_read")
          or wchan:match("wait_for_completion")
          or wchan:match("pipe_wait")
          or wchan:match("wait_woken")
        then
          -- 检查是否连接到终端
          if tty_nr and tty_nr ~= "0" then
            is_waiting = true
            waiting_reason = wchan
          end
        end

        -- 如果主进程在等待子进程（do_wait），递归检查子进程
        if not is_waiting and wchan:match("do_wait") then
          local child_pid = self:_find_child_waiting_for_input()
          if child_pid then
            is_waiting = true
            waiting_reason = "child_wait_woken"
          end
        end
      end
    end
  end

  local state_info = {
    pid = self.pid,
    state_char = state_char,
    comm = comm,
    tty_nr = tty_nr,
    is_waiting = is_waiting,
    waiting_reason = waiting_reason,
    timestamp = os.time(),
  }

  table.insert(self.state_history, state_info)
  if #self.state_history > 100 then
    table.remove(self.state_history, 1)
  end

  -- 更新等待状态
  if is_waiting and not self.is_waiting_for_input then
    self.is_waiting_for_input = true
    self.waiting_since = os.time()
  elseif not is_waiting and self.is_waiting_for_input then
    self.is_waiting_for_input = false
    self.waiting_since = nil
  end

  self.last_state = state_info
  return state_info, nil
end

-- 递归查找子进程中是否有正在等待输入的进程
function ProcessMonitor:_find_child_waiting_for_input()
  local task_path = "/proc/" .. self.pid .. "/task/" .. self.pid .. "/children"
  local children_file = io.open(task_path, "r")
  if not children_file then
    return nil
  end

  local children_data = children_file:read("*a")
  children_file:close()

  if not children_data or children_data == "" then
    return nil
  end

  for child_pid_str in children_data:gmatch("%d+") do
    local child_pid = tonumber(child_pid_str)
    if child_pid then
      -- 检查子进程的 wchan
      local wchan_path = "/proc/" .. child_pid .. "/wchan"
      local wchan_file = io.open(wchan_path, "r")
      if wchan_file then
        local wchan = wchan_file:read("*l")
        wchan_file:close()

        if wchan then
          if wchan:match("wait_woken") or wchan:match("tty_read") or wchan:match("n_tty_read") then
            -- 检查子进程的 tty
            local stat_path = "/proc/" .. child_pid .. "/stat"
            local stat_file = io.open(stat_path, "r")
            if stat_file then
              local stat_data = stat_file:read("*a")
              stat_file:close()
              local close_paren = stat_data:find(")")
              if close_paren then
                local fields = {}
                for field in stat_data:sub(close_paren + 2):gmatch("%S+") do
                  table.insert(fields, field)
                end
                local tty_nr = fields[4]
                if tty_nr and tty_nr ~= "0" then
                  return child_pid
                end
              end
            end
          end

          -- 递归检查子进程的子进程
          if wchan:match("do_wait") or wchan:match("wait_woken") then
            -- 创建临时 monitor 来递归查找
            local child_monitor = ProcessMonitor.new(child_pid, self.session_id)
            local grandchild_pid = child_monitor:_find_child_waiting_for_input()
            if grandchild_pid then
              return grandchild_pid
            end
          end
        end
      end
    end
  end

  return nil
end

-- 开始监控
function ProcessMonitor:start_monitoring(interval_ms, callback)
  if self.monitor_timer then
    return false, "Already monitoring"
  end

  self.interval_ms = interval_ms
  self.callback = callback

  self.monitor_timer = vim.fn.timer_start(
    interval_ms,
    function()
      local state, err = self:check_process_state()
      if callback then
        callback(state, err)
      end
    end,
    { ["repeat"] = -1 } -- 重复执行
  )

  return true, nil
end

-- 暂停监控（检测到 waiting 时调用，等待 AI 输入）
function ProcessMonitor:pause_monitoring()
  if self.monitor_timer and vim.fn.timer_info(self.monitor_timer)[1] then
    vim.fn.timer_stop(self.monitor_timer)
    self.monitor_timer = nil
    return true
  end
  return false
end

-- 恢复监控（AI 输入后调用，继续轮询）
function ProcessMonitor:resume_monitoring()
  if self.monitor_timer then
    return false, "Already monitoring"
  end
  if not self.interval_ms or not self.callback then
    return false, "No interval or callback saved"
  end

  self.monitor_timer = vim.fn.timer_start(self.interval_ms, function()
    local state, err = self:check_process_state()
    if self.callback then
      self.callback(state, err)
    end
  end, { ["repeat"] = -1 })

  return true, nil
end

-- 停止监控
function ProcessMonitor:stop_monitoring()
  if self.monitor_timer and vim.fn.timer_info(self.monitor_timer)[1] then
    vim.fn.timer_stop(self.monitor_timer)
    self.monitor_timer = nil
  end
end

-- 获取最近的等待状态
function ProcessMonitor:get_waiting_info()
  if not self.is_waiting_for_input or not self.waiting_since then
    return nil
  end

  return {
    waiting_since = self.waiting_since,
    duration = os.time() - self.waiting_since,
    last_state = self.last_state,
  }
end

-- ============================================================================
-- 工具 run_command
-- ============================================================================

local function _run_command(args, on_success, on_error, on_progress)
  if not args then
    if on_error then
      on_error("需要命令参数")
    end
    return
  end

  local command = args.command or args.cmd
  if not command or command == "" then
    if on_error then
      on_error("需要 command 参数")
    end
    return
  end

  -- 超时设置，默认 30 秒
  local timeout_sec = args.timeout or 30
  -- 工作目录
  local cwd = args.cwd or vim.fn.getcwd()
  -- 是否捕获 stderr（默认 true）
  local capture_stderr = true
  if args.capture_stderr ~= nil then
    capture_stderr = args.capture_stderr
  end

  -- 创建 session
  local session_id = args._session_id or ("shell_pty_pid_" .. (session_counter + 1))
  session_counter = session_counter + 1

  local session = {
    id = session_id,
    command = command,
    state = "initializing", -- initializing | running | waiting | finished | error
    job_id = nil,
    channel_id = nil,
    process_monitor = nil,
    pid = nil,
    stdout_data = {},
    stderr_data = {},
    full_output = "",
    on_success = on_success,
    on_error = on_error,
    on_progress = on_progress,
    start_time = vim.fn.reltime(),
    timeout_sec = timeout_sec,
    timeout_timer = nil,
    is_waiting_for_input = false,
    pending_input = nil,
    input_callback = nil,
    exit_code = nil,
    exit_signal = nil,
    pty_width = args.pty_width or PTY_CONFIG.width,
    pty_height = args.pty_height or PTY_CONFIG.height,
    _cleaned_up = false, -- 防止重复清理的标志
    last_buffer_pos = 0, -- 上次已读取的 PTY buffer 位置（字节），用于增量读取
    interaction_round = 0, -- 交互轮次计数，每次触发 AI 输入决策时递增
    interaction_history = {}, -- 记录每次交互的输入内容，用于构建历史摘要
  }

  sessions[session_id] = session

  -- 清理函数（幂等，防止重复调用）
  local function cleanup()
    if session._cleaned_up then
      return
    end
    session._cleaned_up = true

    if session.process_monitor then
      session.process_monitor:stop_monitoring()
      session.process_monitor = nil
    end

    if session.timeout_timer and vim.fn.timer_info(session.timeout_timer)[1] then
      vim.fn.timer_stop(session.timeout_timer)
    end

    -- 关闭 PTY 浮动窗口（pcall 保护，headless 模式下可能没有窗口）
    pcall(close_pty_float_window)

    -- 如果还有作业在运行，尝试停止
    if session.job_id and vim.fn.jobwait({ session.job_id }, 0)[1] == -1 then
      vim.fn.jobstop(session.job_id)
    end

    session.state = "finished"
    sessions[session_id] = nil
  end

  -- 超时处理
  local function setup_timeout()
    session.timeout_timer = vim.fn.timer_start(timeout_sec * 1000, function()
      if session.state == "running" or session.state == "waiting" then
        session.state = "error"
        cleanup()
        if on_error then
          on_error(string.format("命令执行超时（%d 秒）: %s", timeout_sec, command))
        end
      end
    end)
  end

  -- 剥离 ANSI 转义码
  -- 注意：nvim_buf_get_lines 返回的已经是 Neovim 终端模拟器渲染后的纯文本
  -- 此函数仅作为兜底，处理极少数可能残留的 ANSI 序列
  local function strip_ansi(text)
    if not text then
      return ""
    end
    -- 移除所有 CSI 序列：ESC [ 可选? 可选数字 可选;数字... 以字母结尾
    local cleaned = text
    -- 模式1：ESC [ 字母（无参数，如 \027[H 光标归位）
    cleaned = cleaned:gsub("\027%[[a-zA-Z]", "")
    -- 模式2：ESC [ ? 字母（DEC私有模式，如 \027[?25l 隐藏光标）
    -- 注意：? 在 Lua 模式匹配中是特殊字符，需要用 %? 转义
    cleaned = cleaned:gsub("\027%[%?[a-zA-Z]", "")
    -- 模式3：ESC [ 数字 字母（如 \027[2J 清屏、\027[K 清除到行尾）
    cleaned = cleaned:gsub("\027%[%d+[a-zA-Z]", "")
    -- 模式4：ESC [ ? 数字 字母（DEC私有模式带参数）
    cleaned = cleaned:gsub("\027%[%?%d+[a-zA-Z]", "")
    -- 模式5：ESC [ 数字;数字;...;数字 字母（SGR等带分号序列）
    -- 使用循环匹配 1 到 50 个分号
    for num_semicolons = 50, 1, -1 do
      local parts = {}
      for _ = 1, num_semicolons + 1 do
        table.insert(parts, "%d+")
      end
      cleaned = cleaned:gsub("\027%[" .. table.concat(parts, ";") .. "[a-zA-Z]", "")
    end
    -- 模式6：ESC [ ? 数字;数字;...;数字 字母（DEC私有模式带分号）
    for num_semicolons = 50, 1, -1 do
      local parts = {}
      for _ = 1, num_semicolons + 1 do
        table.insert(parts, "%d+")
      end
      cleaned = cleaned:gsub("\027%[%?" .. table.concat(parts, ";") .. "[a-zA-Z]", "")
    end
    -- 移除 OSC 序列（ESC] 开头）
    cleaned = cleaned:gsub("\027%][^\007\027]*[\007\027\\]", "")
    return cleaned
  end

  -- 从 PTY buffer 中读取所有内容（解决 on_stdout 可能丢失无换行符数据的问题）
  -- 直接返回整个 buffer 的纯文本内容
  local function read_pty_buffer_output()
    -- 检查是否在 headless 模式（headless 模式下没有 PTY 浮动窗口）
    if not pty_float_window then
      return ""
    end
    -- 尝试从 PTY 浮动窗口的 buffer 中读取内容
    if pty_float_window and pty_float_window.buf and vim.api.nvim_buf_is_valid(pty_float_window.buf) then
      local ok, lines = pcall(vim.api.nvim_buf_get_lines, pty_float_window.buf, 0, -1, false)
      if ok and lines then
        local raw = table.concat(lines, "\n")
        -- 去除 ANSI 转义码
        return strip_ansi(raw)
      end
    end
    return ""
  end

  -- 发送输入到伪终端
  local function send_input_to_pty(input_text)
    if not session.channel_id or not session.job_id then
      session.state = "error"
      cleanup()
      if on_error then
        on_error("无法发送输入：伪终端连接已断开")
      end
      return
    end

    -- 解析输入内容（将特殊按键标记转换为控制序列）
    local data = resolve_key_sequences(input_text)

    -- 通过channel发送输入
    local success, err = pcall(function()
      vim.fn.chansend(session.channel_id, data)
    end)

    if not success then
      session.state = "error"
      cleanup()
      if on_error then
        on_error("发送输入失败: " .. tostring(err))
      end
      return
    end

    -- 更新状态
    session.is_waiting_for_input = false
    session.state = "running"

    -- 记录交互历史
    table.insert(session.interaction_history, {
      round = session.interaction_round,
      input = input_text,
      timestamp = os.time(),
    })
    -- 只保留最近 10 条
    if #session.interaction_history > 10 then
      table.remove(session.interaction_history, 1)
    end

    -- 重置 buffer 位置，下次 waiting 时从最新位置开始增量读取
    -- 因为输入后终端会输出新内容（如回显、下一行提示等）
    local full_buffer = read_pty_buffer_output()
    if full_buffer ~= "" then
      session.last_buffer_pos = #full_buffer
    end

    -- 恢复轮询，继续监控进程状态
    if session.process_monitor then
      session.process_monitor:resume_monitoring()
    end
  end

  -- 触发AI输入决策（带防抖，避免重复触发）
  local ai_decision_pending = false
  local function trigger_ai_input_decision()
    if session.state ~= "waiting" then
      ai_decision_pending = false
      return
    end

    -- 防抖：如果已经有 AI 决策请求在等待中，不再重复触发
    if ai_decision_pending then
      return
    end
    ai_decision_pending = true

    -- 增加交互轮次计数
    session.interaction_round = session.interaction_round + 1

    -- 构建历史摘要函数
    local function build_interaction_summary()
      local history = session.interaction_history
      if #history == 0 then
        return ""
      end
      local lines = { "\n=== 之前已发送的输入（供参考，避免重复选择） ===" }
      for _, h in ipairs(history) do
        lines[#lines + 1] = string.format('  第%d轮: 输入了 "%s"', h.round, h.input)
      end
      lines[#lines + 1] = "================================================\n"
      return table.concat(lines, "\n")
    end

    -- 调用AI决定输入内容
    -- 注意：PTY buffer 的读取放在 vim.schedule 回调内部，确保每次获取最新内容
    local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
    local chat_session_id = args._session_id

    vim.schedule(function()
      -- 读取完整的 PTY buffer 内容，让 AI 看到完整的菜单和选项
      -- 注意：之前使用增量读取导致 AI 丢失上下文，输入无效选项
      local full_buffer = read_pty_buffer_output()
      if full_buffer == "" then
        full_buffer = session.full_output
      end

      -- 使用完整的 buffer 内容
      local new_content = full_buffer
      -- 更新 last_buffer_pos 用于后续参考（不再用于增量截断）
      session.last_buffer_pos = #full_buffer

      -- 清理特殊字符：移除空字符、控制字符等可能导致 JSON 序列化失败的内容
      -- 确保字符串可以被安全嵌入 JSON：转义反斜杠和双引号，修复无效 UTF-8 序列
      -- 注意：保留所有原始数据（包括空字符、控制字符等），只修复格式问题
      local function sanitize_for_json(text)
        if not text then
          return ""
        end
        local result = {}
        local i = 1
        while i <= #text do
          local byte = text:byte(i)
          if byte == 92 then
            -- 反斜杠：转义为 \\
            result[#result + 1] = "\\\\"
            i = i + 1
          elseif byte == 34 then
            -- 双引号：转义为 \"
            result[#result + 1] = '\\"'
            i = i + 1
          elseif byte >= 194 and byte <= 244 then
            -- 可能是 UTF-8 多字节字符的开头
            local trailing = 0
            if byte >= 240 then
              trailing = 3 -- 4 字节字符
            elseif byte >= 224 then
              trailing = 2 -- 3 字节字符
            else
              trailing = 1 -- 2 字节字符
            end
            -- 检查后续字节是否足够且有效（10xxxxxx 格式）
            local valid = true
            for j = 1, trailing do
              local next_byte = text:byte(i + j)
              if not next_byte or next_byte < 128 or next_byte > 191 then
                valid = false
                break
              end
            end
            if valid then
              -- 完整有效的 UTF-8 字符，保留
              result[#result + 1] = text:sub(i, i + trailing)
              i = i + trailing + 1
            else
              -- 无效的 UTF-8 序列：将开头的字节作为单个字节保留
              result[#result + 1] = string.char(byte)
              i = i + 1
            end
          else
            -- 所有其他字节（包括空字符 \0、控制字符、ASCII 可打印字符等）原样保留
            result[#result + 1] = string.char(byte)
            i = i + 1
          end
        end
        return table.concat(result)
      end

      -- 构建轮次信息和历史摘要（添加到 prompt 开头，让 AI 有上下文感知）
      local round_info = ""
      if session.interaction_round > 1 then
        round_info = string.format(
          "[注意] 这是第 %d 轮交互。如果看到与之前相同的菜单/提示，说明命令在循环执行。\n",
          session.interaction_round
        )
        round_info = round_info
          .. "如果已经完成了需要的操作，或者发现自己在重复选择相同的选项，请设置 stop=true 终止进程。\n"
      end
      local history_summary = build_interaction_summary()

      -- 限制传递给 AI 的输出大小（最大 50KB），只取最后部分
      local MAX_OUTPUT_LEN = 50 * 1024
      local prompt_output = sanitize_for_json(new_content)
      if #prompt_output > MAX_OUTPUT_LEN then
        prompt_output = "[输出过长，已截断前 "
          .. (#prompt_output - MAX_OUTPUT_LEN)
          .. " 字节]\n...\n"
          .. prompt_output:sub(-MAX_OUTPUT_LEN)
      end

      local stderr_output = sanitize_for_json(table.concat(session.stderr_data, ""))
      if #stderr_output > MAX_OUTPUT_LEN then
        stderr_output = "[stderr 过长，已截断前 "
          .. (#stderr_output - MAX_OUTPUT_LEN)
          .. " 字节]\n...\n"
          .. stderr_output:sub(-MAX_OUTPUT_LEN)
      end

      -- 将轮次信息和历史摘要添加到 prompt 开头
      local enhanced_prompt = history_summary .. round_info .. prompt_output

      tool_orchestrator.execute_single_tool_request(chat_session_id, "send_input", {
        prompt = enhanced_prompt,
        stdout = enhanced_prompt,
        stderr = stderr_output,
        command = command,
        session_id = session_id,
        _disable_reasoning = true,
        process_state = session.process_monitor.last_state,
      }, function(success, result)
        ai_decision_pending = false

        if session.state ~= "waiting" then
          return
        end

        if not success then
          session.state = "error"
          cleanup()
          if on_error then
            on_error("AI 输入决策失败: " .. tostring(result))
          end
          return
        end

        -- 处理AI返回的stop=true
        if result.stop == true or (result.args and result.args.stop == true) then
          cleanup()

          local result_obj = {
            command = command,
            exit_code = -1,
            signal = nil,
            stdout = table.concat(session.stdout_data, ""),
            stderr = table.concat(session.stderr_data, ""),
            session_id = session_id,
            state = "finished",
            stopped_by_ai = true,
          }

          if on_success then
            on_success(result_obj)
          end
          return
        end

        -- 获取输入内容（允许空字符串，AI 可能返回空字符串表示只发送回车）
        local input_text = nil
        if result.args and result.args.input ~= nil then
          input_text = result.args.input
        elseif result.input ~= nil then
          input_text = result.input
        end

        if input_text ~= nil then
          -- 判断是否包含特殊按键标记（<...>）
          local has_special_key = input_text:match("<[a-z_]+>") ~= nil

          if has_special_key then
            -- AI 设置了按键标记：按原样发送，不追加任何内容
            send_input_to_pty(input_text)
          elseif input_text == "" then
            -- 空字符串：只发送回车
            send_input_to_pty("<enter>")
          else
            -- AI 发送的是纯文本：先发送文本
            send_input_to_pty(input_text)

            -- 短暂延迟后检查是否还在等待输入，如果是则补发回车
            vim.defer_fn(function()
              if session.state == "waiting" and session.is_waiting_for_input then
                send_input_to_pty("<enter>")
              end
            end, 300)
          end
        else
          -- 没有输入字段，继续等待
          session.is_waiting_for_input = false
          session.state = "running"

          -- 恢复轮询，继续监控进程状态
          if session.process_monitor then
            session.process_monitor:resume_monitoring()
          end
        end
      end)
    end)
  end

  -- 处理进程状态变化
  local function handle_process_state(state, err)
    if session.state == "finished" or session.state == "error" then
      return
    end

    if err then
      -- 进程可能已结束
      if err == "Process not found" or err == "Failed to read stat" then
        -- 检查作业是否真的结束了
        if session.job_id then
          local result = vim.fn.jobwait({ session.job_id }, 0)
          if result[1] ~= -1 then
            session.exit_code = result[1]
            if session.state ~= "finished" then
              session.state = "finished"
              cleanup()

              local result_obj = {
                command = command,
                exit_code = session.exit_code,
                signal = session.exit_signal,
                stdout = table.concat(session.stdout_data, ""),
                stderr = table.concat(session.stderr_data, ""),
                session_id = session_id,
                state = "finished",
              }

              if on_success then
                on_success(result_obj)
              end
            end
          end
        end
      end
      return
    end

    -- 检查是否在等待输入
    if state.is_waiting then
      if not session.is_waiting_for_input then
        -- 进程首次进入等待状态
        session.is_waiting_for_input = true
        session.state = "waiting"

        -- 暂停轮询，等待 AI 输入决策
        if session.process_monitor then
          session.process_monitor:pause_monitoring()
        end
      end

      -- 短暂延迟，确保输出已刷新（给 termopen 时间将内容写入 buffer）
      -- trigger_ai_input_decision 内部会进行增量读取，无需在此预先读取
      vim.defer_fn(function()
        trigger_ai_input_decision()
      end, 200)
    elseif not state.is_waiting and session.is_waiting_for_input then
      -- 进程退出等待状态
      session.is_waiting_for_input = false
      if session.state == "waiting" then
        session.state = "running"
      end
    end
  end

  -- 处理输出
  local function handle_output(data, is_stderr)
    if not data or data == "" then
      return
    end

    -- 记录输出
    if is_stderr then
      table.insert(session.stderr_data, data)
    else
      table.insert(session.stdout_data, data)
      -- 存储剥离 ANSI 码后的纯文本版本，用于传递给 AI
      local clean_data = strip_ansi(data)
      session.full_output = session.full_output .. clean_data
    end
  end

  -- 创建伪终端
  local function create_pty()
    -- 直接执行命令，不使用 exec 包装
    -- 注意：之前使用 (sleep 0.5; exec command) 包装会导致 jobpid 返回外层 shell 的 PID
    -- 该外层 shell 的 wchan 为 do_wait（等待子进程），而非实际命令的 wait_woken
    -- 导致 ProcessMonitor 无法检测到进程在等待输入
    local exec_command
    if vim.fn.has("win32") == 1 then
      -- Windows
      exec_command = "cmd.exe /c " .. command
    else
      -- Unix/Linux: 直接执行命令
      exec_command = command
    end

    -- 检查是否在 headless 模式
    -- headless 模式下 nvim_list_uis() 返回空表
    local uis = vim.api.nvim_list_uis()
    local is_headless = #uis == 0

    -- 仅在非 headless 模式下创建 PTY 浮动窗口
    local pty_win = nil
    if not is_headless then
      pty_win = create_pty_float_window(session_id, nil)
      if pty_win then
        -- 将当前窗口切换到 PTY 浮动窗口，使 termopen 在其中创建终端
        local ok, _ = pcall(vim.api.nvim_set_current_win, pty_win)
        if not ok then
          pty_win = nil
        end
      end
    end

    -- 配置伪终端选项
    local term_opts = {
      cwd = cwd,
      env = PTY_CONFIG.env,
      width = session.pty_width,
      height = session.pty_height,
      pty = PTY_CONFIG.pty,
      on_stdout = function(_, data, _)
        if data then
          for _, line in ipairs(data) do
            if line then
              -- 注意：不丢弃空行，因为 read -p 的提示信息可能以空行形式出现在伪终端输出中
              handle_output(line, false)
            end
          end
        end
      end,
      on_stderr = function(_, data, _)
        if data and capture_stderr then
          for _, line in ipairs(data) do
            if line then
              handle_output(line, true)
            end
          end
        end
      end,
      on_exit = function(_, exit_code, signal)
        session.exit_code = exit_code
        session.exit_signal = signal
        session.state = "finished"

        -- 仅在非 headless 模式下延迟关闭 PTY 浮动窗口
        if not is_headless then
          vim.defer_fn(function()
            close_pty_float_window()
          end, 1500)
        end

        vim.schedule(function()
          cleanup()

          local result_obj = {
            command = command,
            exit_code = exit_code,
            signal = signal,
            stdout = table.concat(session.stdout_data, ""),
            stderr = table.concat(session.stderr_data, ""),
            session_id = session_id,
            state = "finished",
          }

          if on_success then
            on_success(result_obj)
          end
        end)
      end,
    }

    -- 根据 headless 模式选择不同的启动方式
    local job_id
    if is_headless then
      -- headless 模式：使用 jobstart 替代 termopen
      local headless_opts = {
        cwd = cwd,
        env = PTY_CONFIG.env,
        on_stdout = function(_, data, _)
          if data then
            for _, line in ipairs(data) do
              if line then
                handle_output(line, false)
              end
            end
          end
        end,
        on_stderr = function(_, data, _)
          if data and capture_stderr then
            for _, line in ipairs(data) do
              if line then
                handle_output(line, true)
              end
            end
          end
        end,
        on_exit = function(_, exit_code, signal)
          session.exit_code = exit_code
          session.exit_signal = signal
          session.state = "finished"

          vim.schedule(function()
            cleanup()

            local result_obj = {
              command = command,
              exit_code = exit_code,
              signal = signal,
              stdout = table.concat(session.stdout_data, ""),
              stderr = table.concat(session.stderr_data, ""),
              session_id = session_id,
              state = "finished",
            }

            if on_success then
              on_success(result_obj)
            end
          end)
        end,
      }
      -- 在 headless 模式下直接执行命令
      job_id = vim.fn.jobstart(exec_command, headless_opts)
    else
      -- GUI 模式：使用 termopen
      ---@diagnostic disable-next-line: deprecated
      job_id = vim.fn.termopen(exec_command, term_opts)
    end

    if not job_id or job_id <= 0 then
      session.state = "error"
      pcall(close_pty_float_window)
      cleanup()
      if on_error then
        on_error("无法启动命令")
      end
      return false
    end

    session.job_id = job_id
    session.channel_id = job_id
    session.state = "running"

    -- 如果成功创建了 PTY 浮动窗口，更新其 buf 引用为 termopen 创建的终端 buffer
    if not is_headless and pty_win and pty_float_window then
      local ok, term_buf = pcall(vim.api.nvim_win_get_buf, pty_win)
      if ok then
        pty_float_window.buf = term_buf
      end
    end

    -- 设置超时
    setup_timeout()

    -- 延迟获取PID（给进程一些启动时间）
    vim.defer_fn(function()
      -- 检查 job 是否仍然有效（避免进程已退出导致 Invalid channel id）
      local ok, job_info = pcall(vim.fn.jobpid, job_id)
      if ok and job_info and job_info > 0 then
        session.pid = job_info

        -- 创建进程监控器
        session.process_monitor = ProcessMonitor.new(session.pid, session_id)

        -- 启动进程状态监控
        local ok2, err = session.process_monitor:start_monitoring(PTY_CONFIG.check_interval, handle_process_state)
      end
    end, 500) -- 500ms延迟，确保进程已启动

    return true
  end

  -- 启动伪终端
  if not create_pty() then
    return
  end
end

M.run_command = define_tool({
  name = "run_command",
  description = "执行 shell 命令并返回完整的执行结果。使用伪终端自动处理交互式输入，通过进程 PID 监控状态，无需手动调用 send_input。支持超时设置和工作目录指定。",
  func = _run_command,
  async = true,
  parameters = {
    type = "object",
    properties = {
      command = {
        type = "string",
        description = "要执行的 shell 命令（必填）",
      },
      cmd = {
        type = "string",
        description = "command 的别名，与 command 等效",
      },
      timeout = {
        type = "number",
        description = "超时时间（秒），默认 30 秒",
        default = 30,
      },
      cwd = {
        type = "string",
        description = "工作目录，默认为当前 Neovim 工作目录",
      },
      capture_stderr = {
        type = "boolean",
        description = "是否捕获标准错误输出，默认 true",
        default = true,
      },
      pty_width = {
        type = "number",
        description = "伪终端宽度，默认 80",
        default = 80,
      },
      pty_height = {
        type = "number",
        description = "伪终端高度，默认 24",
        default = 24,
      },
    },
    required = { "command" },
  },
  returns = {
    type = "object",
    properties = {
      command = { type = "string", description = "执行的命令" },
      exit_code = { type = "number", description = "退出码（命令结束后才有）" },
      signal = { type = "number", description = "终止信号（如果有）" },
      stdout = { type = "string", description = "标准输出内容" },
      stderr = { type = "string", description = "标准错误内容" },
      session_id = { type = "string", description = "shell session ID" },
      state = { type = "string", description = "session 状态：finished | error" },
      message = { type = "string", description = "提示消息" },
    },
    description = "命令执行结果",
  },
  category = "system",
  permissions = { execute = true },
})

-- ============================================================================
-- 工具 send_input
-- ============================================================================

local function _send_input(args, on_success, on_error, on_progress)
  if not args then
    if on_error then
      on_error("需要参数")
    end
    return
  end

  local session_id = args.session_id
  if not session_id then
    if on_error then
      on_error("需要 session_id 参数")
    end
    return
  end

  local input_text = args.input
  if not input_text then
    if on_error then
      on_error("需要 input 参数（要发送的输入内容）")
    end
    return
  end

  local session = sessions[session_id]
  if not session then
    if on_error then
      on_error(string.format("session '%s' 不存在或已结束", session_id))
    end
    return
  end

  if session.state ~= "waiting" then
    if on_error then
      on_error(string.format("session '%s' 当前状态为 '%s'，不在等待输入状态", session_id, session.state))
    end
    return
  end

  -- 发送输入到伪终端
  if not session.channel_id then
    session.state = "error"
    sessions[session_id] = nil
    if on_error then
      on_error("伪终端连接已关闭，无法发送输入")
    end
    return
  end

  -- 解析输入内容（将特殊按键标记转换为控制序列）
  local data = resolve_key_sequences(input_text)

  local success, err = pcall(function()
    vim.fn.chansend(session.channel_id, data)
  end)

  if not success then
    session.state = "error"
    sessions[session_id] = nil
    if on_error then
      on_error(string.format("发送输入失败: %s", err))
    end
    return
  end

  -- 更新 session 状态
  session.state = "running"
  session.is_waiting_for_input = false

  -- 重置 buffer 位置，下次 waiting 时从最新位置开始增量读取
  local full_buffer = read_pty_buffer_output()
  if full_buffer ~= "" then
    session.last_buffer_pos = #full_buffer
  end

  -- 恢复轮询，继续监控进程状态
  if session.process_monitor then
    session.process_monitor:resume_monitoring()
  end

  -- 返回成功
  local result = {
    session_id = session_id,
    input = input_text,
    state = "running",
    message = string.format(
      "已成功向 session '%s' 发送输入。命令将继续执行，请等待后续输出。",
      session_id
    ),
  }

  if on_success then
    on_success(result)
  end
end

M.send_input = define_tool({
  name = "send_input",
  description = "向正在等待输入的 shell session 发送输入内容（如用户名、密码、y/n 确认、菜单选项编号等）。支持使用特殊按键标记发送控制序列：<enter>（回车确认）、<up>/<down>/<left>/<right>（方向键）、<ctrl_c>（中断）、<ctrl_d>（EOF）、<tab>、<escape>、<backspace> 等。如果命令已完成或不需要继续执行，设置 stop=true 终止进程。",
  func = _send_input,
  async = true,
  parameters = {
    type = "object",
    properties = {
      session_id = {
        type = "string",
        description = "run_command 返回的 session_id（必填）",
      },
      input = {
        type = "string",
        description = "要发送的输入内容。支持特殊按键标记：<enter>（回车确认）、<up>/<down>/<left>/<right>（方向键）、<ctrl_c>（中断）、<ctrl_d>（EOF）、<tab>、<escape>、<backspace>。例如：'y' 发送 'y' 加回车；'<enter>' 只发送回车；'<down><enter>' 发送下键+回车；'<ctrl_c>' 发送 Ctrl+C。",
      },
      stop = {
        type = "boolean",
        description = "设为 true 时终止 shell 进程（命令已完成或不需要继续执行时使用）",
      },
    },
  },
  returns = {
    type = "object",
    properties = {
      session_id = { type = "string", description = "shell session ID" },
      input = { type = "string", description = "已发送的输入内容" },
      state = { type = "string", description = "session 当前状态" },
      message = { type = "string", description = "提示消息" },
    },
    description = "输入发送结果",
  },
  category = "system",
  permissions = { execute = true },
})

-- ============================================================================
-- 工具函数：获取所有session
-- ============================================================================

function M.list_sessions()
  local result = {}
  for session_id, session in pairs(sessions) do
    table.insert(result, {
      id = session_id,
      command = session.command,
      state = session.state,
      pid = session.pid,
      output_length = #table.concat(session.stdout_data, ""),
      running_time = vim.fn.reltimefloat(vim.fn.reltime(session.start_time)),
    })
  end
  return result
end

-- ============================================================================
-- 工具函数：获取进程状态
-- ============================================================================

function M.get_process_state(session_id)
  local session = sessions[session_id]
  if not session then
    return nil, "Session not found"
  end

  if not session.process_monitor then
    return nil, "No process monitor"
  end

  return session.process_monitor.last_state
end

-- ============================================================================
-- 工具函数：停止session
-- ============================================================================

function M.stop_session(session_id)
  local session = sessions[session_id]
  if not session then
    return false, "Session not found"
  end

  if session.job_id and vim.fn.jobwait({ session.job_id }, 0)[1] == -1 then
    vim.fn.jobstop(session.job_id)
  end

  -- 关闭 PTY 浮动窗口
  close_pty_float_window()

  sessions[session_id] = nil
  return true, "Session stopped"
end

-- ============================================================================
-- get_tools()
-- ============================================================================

function M.get_tools()
  local tools = {}
  for _, v in pairs(M) do
    if type(v) == "table" and v.name and v.func then
      table.insert(tools, v)
    end
  end
  table.sort(tools, function(a, b)
    return a.name < b.name
  end)
  return tools
end

-- ============================================================================
-- 测试函数
-- ============================================================================

function M.test_interactive()
  print("测试交互式命令执行...")

  local test_cmd = [[
echo "开始测试交互式命令"
echo -n "请输入你的名字: "
read name
echo "你好, $name!"
echo -n "继续吗? [y/N]: "
read confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
  echo "你选择了继续"
else
  echo "你选择了退出"
fi
echo "测试完成"
]]

  print("测试命令已准备: " .. test_cmd)
  print("在实际环境中，可以调用 M.run_command({command = test_cmd}, ...) 进行测试")
end

return M
