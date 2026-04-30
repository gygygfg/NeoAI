-- Lua Shell 工具模块（使用Neovim伪终端）
-- 提供执行 shell 命令的工具，支持交互式命令的自动处理
-- 使用 vim.fn.termopen 和 vim.fn.jobstart 实现真正的伪终端通信
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- ============================================================================
-- Shell Session 管理器
-- ============================================================================
local sessions = {}
local session_counter = 0

-- ============================================================================
-- 终端输出格式化
-- ============================================================================

-- 去除 ANSI 转义序列
-- 匹配 CSI (Control Sequence Introducer) 序列: ESC [ 参数... 字母
-- 以及 OSC 序列: ESC ] ... BEL/ST
-- 以及其他常见终端控制序列
local function strip_ansi(str)
  -- 去除 CSI 序列: ESC [ <参数> <字母>
  str = str:gsub("\27%[%d;%d;%d;%d;%d;%d;%d;%d;%d;%d*[mHfABCDJKlLPSu]", "")
  str = str:gsub("\27%[%d;%d;%d;%d;%d;%d;%d;%d;%d*[mHfABCDJKlLPSu]", "")
  str = str:gsub("\27%[%d;%d;%d;%d;%d;%d;%d;%d*[mHfABCDJKlLPSu]", "")
  str = str:gsub("\27%[%d;%d;%d;%d;%d;%d;%d*[mHfABCDJKlLPSu]", "")
  str = str:gsub("\27%[%d;%d;%d;%d;%d;%d*[mHfABCDJKlLPSu]", "")
  str = str:gsub("\27%[%d;%d;%d;%d;%d*[mHfABCDJKlLPSu]", "")
  str = str:gsub("\27%[%d;%d;%d;%d*[mHfABCDJKlLPSu]", "")
  str = str:gsub("\27%[%d;%d;%d*[mHfABCDJKlLPSu]", "")
  str = str:gsub("\27%[%d;%d*[mHfABCDJKlLPSu]", "")
  str = str:gsub("\27%[%d*[mHfABCDJKlLPSu]", "")
  -- 去除 CSI 其他格式: ESC [ ? <参数> <字母>
  str = str:gsub("\27%[%?%d+;%d+;%d+;%d+;%d+[hl]", "")
  str = str:gsub("\27%[%?%d+;%d+;%d+;%d+[hl]", "")
  str = str:gsub("\27%[%?%d+;%d+;%d+[hl]", "")
  str = str:gsub("\27%[%?%d+;%d+[hl]", "")
  str = str:gsub("\27%[%?%d+[hl]", "")
  -- 去除 OSC 序列: ESC ] ... BEL (\007) 或 ESC ] ... ST (ESC \)
  str = str:gsub("\27%].-" .. "\007", "")
  str = str:gsub("\27%].-" .. "\027\\", "")
  -- 去除其他控制字符
  str = str:gsub("[\007\008\013]", "")
  -- 去除 SGR 重置序列
  str = str:gsub("\27%(", ""):gsub("\27)", "")
  return str
end

-- 折叠长路径：保留最后 2 个组件，前面的用 ... 替代
-- 例如：/home/user/very/long/path/to/dir -> .../path/to/dir
local function fold_path(path)
  -- 去除末尾的路径分隔符
  local p = path:gsub("/+$", "")
  -- 按 / 分割
  local parts = {}
  for part in p:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  if #parts <= 2 then
    return path
  end
  -- 保留最后 2 个组件
  local last_two = {}
  for i = #parts - 1, #parts do
    table.insert(last_two, parts[i])
  end
  return ".../" .. table.concat(last_two, "/")
end

-- 检测一行是否是提示符行（以 $、#、❯、% 等结尾，或包含 @ 的主机名格式）
local PROMPT_PATTERNS = {
  "^[%w_%-]+@[%w_%-]+.+", -- user@host 格式
  "^[%w_%-]+@.+",
  "^[%w_%-]+.+",
}

-- 格式化终端输出：美化提示符、折叠路径
local function format_terminal_output(raw_output)
  -- 先去除 ANSI 转义
  local cleaned = strip_ansi(raw_output)
  if cleaned == "" then
    return raw_output
  end

  local lines = {}
  for line in cleaned:gmatch("[^\n]+") do
    -- 去除行首尾空白
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      -- 检测是否是提示符行
      -- 提示符通常以 $、#、❯、% 结尾，或包含 @ 符号
      local is_prompt = line:match("[%$#%%❯>]$") or line:match("@") or line:match("^~")
      if is_prompt then
        -- 对提示符中的路径进行折叠
        -- 匹配 /path/to/dir 格式的路径
        line = line:gsub("(/[%w_%-%.]+(?:/[%w_%-%.]+)+)", function(path)
          return fold_path(path)
        end)
        -- 匹配 ~/path/to/dir 格式
        line = line:gsub("(~/[%w_%-%.]+(?:/[%w_%-%.]+)+)", function(path)
          return fold_path(path)
        end)
      end
      table.insert(lines, line)
    end
  end

  return table.concat(lines, "\n")
end

-- 伪终端配置
local PTY_CONFIG = {
  -- 伪终端宽度和高度
  width = 80,
  height = 24,
  -- 是否启用ANSI颜色
  ansi = true,
  -- 环境变量
  env = vim.empty_dict(),
  -- 清除环境变量
  clear_env = false,
  -- 工作目录
  cwd = nil,
  -- 是否分离模式
  detach = false,
  -- 伪终端类型
  pty = true,
  -- 输入模式
  input = "pipe",
  -- 输出模式
  output = "pipe",
  -- 错误输出模式
  error = "pipe",
  -- 伪终端超时检测间隔（毫秒）
  check_interval = 100,
  -- 等待输入的最大时间（秒）
  max_wait_time = 30,
  -- 缓冲区大小
  buffer_size = 1024 * 64, -- 64KB
}

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
  local session_id = args._session_id or ("shell_pty_" .. (session_counter + 1))
  session_counter = session_counter + 1

  local session = {
    id = session_id,
    command = command,
    state = "initializing", -- initializing | running | waiting | finished | error
    job_id = nil,
    channel_id = nil,
    buffer_name = nil,
    stdout_data = {},
    stderr_data = {},
    full_output = "",
    last_output = "",
    on_success = on_success,
    on_error = on_error,
    on_progress = on_progress,
    start_time = vim.fn.reltime(),
    timeout_sec = timeout_sec,
    timeout_timer = nil,
    check_timer = nil,
    waiting_timer = nil,
    is_waiting_for_input = false,
    pending_input = nil,
    input_callback = nil,
    exit_code = nil,
    exit_signal = nil,
    pty_width = PTY_CONFIG.width,
    pty_height = PTY_CONFIG.height,
  }

  sessions[session_id] = session

  -- 清理函数
  local function cleanup()
    if session.check_timer and vim.fn.timer_info(session.check_timer)[1] then
      vim.fn.timer_stop(session.check_timer)
    end

    if session.timeout_timer and vim.fn.timer_info(session.timeout_timer)[1] then
      vim.fn.timer_stop(session.timeout_timer)
    end

    if session.waiting_timer and vim.fn.timer_info(session.waiting_timer)[1] then
      vim.fn.timer_stop(session.waiting_timer)
    end

    -- 清除左侧窗口同步 autocommand
    if session.sync_augroup then
      pcall(vim.api.nvim_del_augroup_by_name, session.sync_augroup)
    end

    -- 如果还有作业在运行，尝试停止
    if session.job_id and vim.fn.jobwait({ session.job_id }, 0)[1] == -1 then
      vim.fn.jobstop(session.job_id)
    end

    -- 关闭伪终端浮动窗口，并恢复工具调用悬浮窗宽度
    if session.float_window_win and vim.api.nvim_win_is_valid(session.float_window_win) then
      vim.api.nvim_win_close(session.float_window_win, true)
    end
    if session.float_window_buf and vim.api.nvim_buf_is_valid(session.float_window_buf) then
      vim.api.nvim_buf_delete(session.float_window_buf, { force = true })
    end
    -- 恢复工具调用悬浮窗的原始宽度和边框
    if session._saved_tool_width and session._tool_display_win then
      local win = session._tool_display_win
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_config, win, {
          width = session._saved_tool_width,
          border = "rounded",
        })
      end
    end

    -- 清理缓冲区（旧方式兼容）
    if session.buffer_name and type(session.buffer_name) == "string" then
      local buf_nr = vim.fn.bufnr(session.buffer_name)
      if buf_nr > -1 and vim.fn.bufexists(buf_nr) then
        vim.api.nvim_buf_delete(buf_nr, { force = true })
      end
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

  -- 检查进程状态
  local function check_process_status()
    if session.state == "finished" or session.state == "error" then
      return
    end

    -- 检查作业是否还在运行
    if session.job_id then
      local result = vim.fn.jobwait({ session.job_id }, 0)
      if result[1] ~= -1 then
        -- 作业已结束
        session.exit_code = result[1]
        if session.state ~= "finished" then
          session.state = "finished"
          cleanup()

          local stdout = table.concat(session.stdout_data, "")
          local stderr = table.concat(session.stderr_data, "")

          local result_obj = {
            command = command,
            exit_code = session.exit_code,
            signal = session.exit_signal,
            stdout = stdout,
            stderr = stderr,
            session_id = session_id,
            state = "finished",
          }

          if on_success then
            on_success(result_obj)
          end
        end
        return
      end
    end

    -- 如果进程在运行，检查是否在等待输入
    if session.state == "running" and not session.is_waiting_for_input then
      -- 这里可以添加更复杂的逻辑来检测是否在等待输入
      -- 简单实现：如果一段时间没有新输出，且进程仍在运行，可能是在等待输入
      local now = vim.fn.reltime()
      local elapsed = vim.fn.reltimefloat(vim.fn.reltime(session.start_time))

      -- 如果有channel，可以检查是否有数据
      if session.channel_id then
        -- 暂时使用简单超时检测
        if elapsed > 2 and session.last_output == session.full_output then
          -- 可能是在等待输入
          session.is_waiting_for_input = true
          session.state = "waiting"

          -- 触发AI输入决策
          trigger_ai_input_decision()
        end
      end
    end
  end

  -- 开始状态检查定时器
  local function start_status_check()
    if session.check_timer and vim.fn.timer_info(session.check_timer)[1] then
      vim.fn.timer_stop(session.check_timer)
    end

    session.check_timer = vim.fn.timer_start(
      PTY_CONFIG.check_interval,
      function()
        check_process_status()
      end,
      { ["repeat"] = -1 } -- 重复执行
    )
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

    -- 添加换行符
    local data = input_text
    if not data:match("\n$") then
      data = data .. "\n"
    end

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

    if on_progress then
      on_progress("发送输入", "executing", 0, "AI 决定发送输入: " .. input_text)
    end

    -- 更新状态
    session.is_waiting_for_input = false
    session.state = "running"
    session.last_output = session.full_output

    -- 重新开始状态检查
    start_status_check()
  end

  -- 触发AI输入决策
  local function trigger_ai_input_decision()
    if session.state ~= "waiting" then
      return
    end

    -- 暂停状态检查
    if session.check_timer and vim.fn.timer_info(session.check_timer)[1] then
      vim.fn.timer_stop(session.check_timer)
    end

    -- 获取当前输出
    local current_output = session.full_output
    local last_part = session.last_output

    if on_progress then
      on_progress("等待输入", "waiting", 0, current_output)
    end

    -- 调用AI决定输入内容
    local tool_orchestrator = require("NeoAI.core.ai.tool_orchestrator")
    local chat_session_id = args._session_id

    vim.schedule(function()
      tool_orchestrator.execute_single_tool_request(chat_session_id, "send_input", {
        prompt = current_output,
        stdout = current_output,
        stderr = table.concat(session.stderr_data, ""),
        command = command,
        session_id = session_id,
        _disable_reasoning = true,
      }, function(success, result)
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
          if on_progress then
            on_progress("终止进程", "completed", 0, "AI 决定终止命令")
          end
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

        -- 获取输入内容
        local input_text = ""
        if result.args and result.args.input then
          input_text = result.args.input
        elseif result.input then
          input_text = result.input
        end

        if input_text and input_text ~= "" then
          -- 发送输入到伪终端
          send_input_to_pty(input_text)
        else
          -- 没有输入，继续等待
          session.is_waiting_for_input = false
          session.state = "running"
          start_status_check()
        end
      end)
    end)
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
      session.full_output = session.full_output .. data
    end

    -- 更新进度 - 传递格式化后的终端输出
    if on_progress and not is_stderr then
      -- 对完整输出进行终端格式化（去ANSI、美化提示符、折叠路径）
      local formatted = format_terminal_output(session.full_output)
      -- 获取最后几行用于显示
      local lines = {}
      for line in (formatted .. ""):gmatch("[^\n]+") do
        table.insert(lines, line)
      end
      -- 最多显示最后 20 行
      local display_lines = {}
      local start_idx = math.max(1, #lines - 19)
      for i = start_idx, #lines do
        table.insert(display_lines, lines[i])
      end
      local display_output = table.concat(display_lines, "\n")
      on_progress("执行命令", "executing", 0, display_output)
    end

    -- 检查常见的提示符模式
    local patterns = {
      "[Pp]assword: *$",
      "[Pp]assphrase: *$",
      "[Yy]/[Nn] *$",
      "[Yy]es/[Nn]o *$",
      "%[Yy]/[Nn]%] *$",
      "%[Yy]es/[Nn]o%] *$",
      ": *$",
      "%? *$",
      ">> *$",
      ">>> *$",
      "[%$#%>] *$",
    }

    for _, pattern in ipairs(patterns) do
      if data:match(pattern) and session.state == "running" then
        session.is_waiting_for_input = true
        session.state = "waiting"
        trigger_ai_input_decision()
        break
      end
    end
  end

  -- 创建伪终端（在工具调用悬浮窗右侧打开）
  local function create_pty()
    -- 获取工具调用悬浮窗的窗口信息
    local chat_window = require("NeoAI.ui.window.chat_window")
    local tool_display_win_id = chat_window.get_tool_display_window_id()

    local float_buf, float_win
    local right_border
    if tool_display_win_id then
      -- 在工具调用悬浮窗右侧创建子窗口
      local tool_win_info = require("NeoAI.ui.window.window_manager").get_window_info(tool_display_win_id)
      if tool_win_info and tool_win_info.win and vim.api.nvim_win_is_valid(tool_win_info.win) then
        local tool_win_config = vim.api.nvim_win_get_config(tool_win_info.win)
        local tool_width = tool_win_config.width or 60
        local tool_height = tool_win_config.height or 20
        local tool_row = tool_win_config.row or 1
        local tool_col = tool_win_config.col or 1

        -- 右侧子窗口宽度为工具调用悬浮窗的一半
        local right_width = math.floor(tool_width / 2)
        -- 左侧缩小 3 格（为右侧左边框和间距留空间），右侧位置不变
        local left_width = tool_width - right_width - 3
        local right_col = tool_col + tool_width - right_width + 2

        -- 右侧伪终端窗口：row 比左侧多 1（跳过左侧上边框），height 比左侧少 2（去掉上下边框占位）
        -- 取消左边框（左上角、左边、左下角），与左侧窗口无缝贴合
        right_border = {
          { "─", "FloatBorder" }, -- 左上角
          { "─", "FloatBorder" }, -- 上
          { "╮", "FloatBorder" }, -- 右上角
          { "│", "FloatBorder" }, -- 右
          { "╯", "FloatBorder" }, -- 右下角
          { "─", "FloatBorder" }, -- 下
          { "─", "FloatBorder" }, -- 左下角
          { " ", "FloatBorder" }, -- 左
        }
        float_buf = vim.api.nvim_create_buf(false, true)
        float_win = vim.api.nvim_open_win(float_buf, false, {
          relative = "editor",
          width = right_width - 2,
          height = tool_height,
          row = tool_row,
          col = right_col,
          border = right_border,
          title = " 💻 " .. command:sub(1, 50) .. (command:len() > 50 and "..." or "") .. " ",
          title_pos = "center",
          zindex = 101,
        })

        -- 保存原始宽度，用于恢复
        session._saved_tool_width = tool_width
        session._tool_display_win = tool_win_info.win

        -- 缩小工具调用悬浮窗左侧宽度，为右侧终端腾出空间
        vim.api.nvim_win_set_config(tool_win_info.win, {
          width = left_width,
        })

        -- 修改左侧窗口边框：右上角 → ┬，右下角 → ┴（与右侧窗口拼接）
        local left_border = {
          { "╭", "FloatBorder" },
          { "─", "FloatBorder" },
          { "┬", "FloatBorder" },
          { "│", "FloatBorder" },
          { "┴", "FloatBorder" },
          { "─", "FloatBorder" },
          { "╰", "FloatBorder" },
          { "│", "FloatBorder" },
        }
        vim.api.nvim_win_set_config(tool_win_info.win, {
          border = left_border,
        })

        -- 监听左侧工具调用悬浮窗大小变化事件，动态同步右侧窗口
        local sync_augroup = "NeoAIPTYSync_" .. session_id
        vim.api.nvim_create_augroup(sync_augroup, { clear = true })
        vim.api.nvim_create_autocmd("User", {
          pattern = "NeoAI:tool_display_resized",
          group = sync_augroup,
          callback = function()
            if not float_win or not vim.api.nvim_win_is_valid(float_win) then
              return
            end
            if not tool_win_info.win or not vim.api.nvim_win_is_valid(tool_win_info.win) then
              return
            end
            local cur_config = vim.api.nvim_win_get_config(tool_win_info.win)
            local cur_height = cur_config.height or tool_height
            local cur_row = cur_config.row or tool_row
            local cur_width = cur_config.width or left_width
            local cur_col = cur_config.col or tool_col
            -- 右侧窗口在左侧右侧基础上右移 3 格
            local new_right_col = cur_col + cur_width + 2
            -- 同步右侧窗口（重新配置浮动窗口必须传入 relative）
            vim.api.nvim_win_set_config(float_win, {
              relative = "editor",
              width = right_width - 2,
              height = cur_height,
              row = cur_row,
              col = new_right_col,
            })
          end,
        })
        session.sync_augroup = sync_augroup
      end
    end

    -- 如果无法获取工具调用悬浮窗，创建一个独立的浮动窗口
    if not float_win or not vim.api.nvim_win_is_valid(float_win) then
      local width = math.min(session.pty_width + 2, math.floor(vim.o.columns * 0.8))
      local height = math.min(session.pty_height * 2 + 2, math.floor(vim.o.lines * 0.6))
      local row = math.floor((vim.o.lines - height) / 2) + math.floor(vim.o.lines * 0.2)
      local col = math.floor((vim.o.columns - width) / 2)

      float_buf = vim.api.nvim_create_buf(false, true)
      float_win = vim.api.nvim_open_win(float_buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        border = "rounded",
        title = " 💻 " .. command:sub(1, 50) .. (command:len() > 50 and "..." or "") .. " ",
        title_pos = "center",
        zindex = 150,
        noautocmd = true,
      })
    end

    vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = float_win })
    vim.api.nvim_set_option_value("winblend", 0, { win = float_win })

    -- 强制刷新窗口以显示边框和标题
    vim.api.nvim_win_call(float_win, function()
      vim.cmd("redraw")
    end)

    -- 保存窗口和 buffer 信息
    session.float_window_win = float_win
    session.float_window_buf = float_buf
    session.buffer_name = float_buf

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
            if line and line ~= "" then
              handle_output(line, false)
            end
          end
        end
      end,
      on_stderr = function(_, data, _)
        if data and capture_stderr then
          for _, line in ipairs(data) do
            if line and line ~= "" then
              handle_output(line, true)
            end
          end
        end
      end,
      on_exit = function(_, exit_code, signal)
        session.exit_code = exit_code
        session.exit_signal = signal
        session.state = "finished"

        -- 延迟 1.5 秒后关闭窗口并回调
        vim.fn.timer_start(1500, function()
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
        end)
      end,
    }

    -- 切换到浮动窗口，然后在该窗口中启动伪终端
    local prev_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(float_win)
    -- 使用 termopen 启动伪终端（LSP 标记为弃用但功能正常）
    -- luacheck: ignore 122
    local job_id = vim.fn.termopen(command, term_opts)
    -- termopen 会重置窗口配置（如 style=minimal），需要重新设置边框和标题
    if float_win and vim.api.nvim_win_is_valid(float_win) then
      local restore_border = right_border
        or {
          { "╭", "FloatBorder" },
          { "─", "FloatBorder" },
          { "╮", "FloatBorder" },
          { "│", "FloatBorder" },
          { "╯", "FloatBorder" },
          { "─", "FloatBorder" },
          { "╰", "FloatBorder" },
          { "│", "FloatBorder" },
        }
      vim.api.nvim_win_set_config(float_win, {
        border = restore_border,
        title = " 💻 " .. command:sub(1, 50) .. (command:len() > 50 and "..." or "") .. " ",
        title_pos = "center",
      })
    end
    -- 切回之前的窗口
    if prev_win and vim.api.nvim_win_is_valid(prev_win) then
      vim.api.nvim_set_current_win(prev_win)
    end

    if job_id <= 0 then
      session.state = "error"
      -- 关闭浮动窗口
      if float_win and vim.api.nvim_win_is_valid(float_win) then
        vim.api.nvim_win_close(float_win, true)
      end
      if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
        vim.api.nvim_buf_delete(float_buf, { force = true })
      end
      cleanup()
      if on_error then
        on_error("无法启动伪终端")
      end
      return false
    end

    session.job_id = job_id
    session.channel_id = job_id
    session.state = "running"

    -- 设置超时
    setup_timeout()

    -- 开始状态检查
    start_status_check()

    if on_progress then
      on_progress("启动伪终端", "executing", 0, "正在执行命令: " .. command)
    end

    return true
  end

  -- 启动伪终端
  if not create_pty() then
    return
  end
end

M.run_command = define_tool({
  name = "run_command",
  description = "执行 shell 命令并返回完整的执行结果。使用伪终端自动处理交互式输入（如密码、确认等），无需手动调用 send_input。支持超时设置和工作目录指定。",
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

  -- 添加换行符
  local data = input_text
  if not data:match("\n$") then
    data = data .. "\n"
  end

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

  if on_progress then
    on_progress("发送输入", "completed", 0, string.format("已向 session '%s' 发送输入", session_id))
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
  description = "向正在等待输入的 shell session 发送输入内容（如用户名、密码、y/n 确认、菜单选项编号等）。如果命令已完成或不需要继续执行，设置 stop=true 终止进程。",
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
        description = "要发送的输入内容，如用户名、密码、y/n、菜单选项编号等。如果 stop=true 则不需要此参数。",
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
      output_length = #session.full_output,
      running_time = vim.fn.reltimefloat(vim.fn.reltime(session.start_time)),
    })
  end
  return result
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

  -- 这里可以添加实际的测试调用
  -- 注意：由于这是异步的，实际测试需要在Neovim环境中进行
  print("测试命令已准备: " .. test_cmd)
  print("在实际环境中，可以调用 M.run_command({command = test_cmd}, ...) 进行测试")
end

return M
