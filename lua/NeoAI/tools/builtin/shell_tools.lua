-- Lua Shell 工具模块（回调模式）
-- 提供执行 shell 命令的工具，支持交互式命令的 session 管理
-- run_command 检测到等待输入时返回 session_id，大模型可调用 send_input 继续
-- 工具函数签名：func(args, on_success, on_error, on_progress)
local M = {}

local define_tool = require("NeoAI.tools.builtin.tool_helpers").define_tool

-- ============================================================================
-- Shell Session 管理器
-- ============================================================================

local sessions = {}
local session_counter = 0

-- 常见等待输入提示符模式
local INPUT_PROMPT_PATTERNS = {
  "[Pp]assword:",
  "[Yy]es/[Nn]o",
  "[Yy]/[Nn]",
  "%[Y/n%]",
  "%[y/N%]",
  "[Pp]lease enter",
  "[Ee]nter your",
  "[Ss]elect",
  "[Cc]hoose",
  "[Cc]ontinue",
  "[Pp]ress any key",
  "[Pp]ress Enter",
  "[?] ",
  "> ",
  ": ",
  "\\$ ",
}

local function detect_input_prompt(output)
  if not output or output == "" then
    return false
  end
  local last_line = ""
  for line in output:gmatch("[^\n]+") do
    last_line = line
  end
  for _, pattern in ipairs(INPUT_PROMPT_PATTERNS) do
    if last_line:match(pattern) then
      return true
    end
  end
  return false
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
  local timeout_ms = (args.timeout or 30) * 1000
  -- 工作目录
  local cwd = args.cwd or vim.fn.getcwd()
  -- 是否捕获 stderr（默认 true）
  local capture_stderr = true
  if args.capture_stderr ~= nil then
    capture_stderr = args.capture_stderr
  end

  local stdout_data = {}
  local stderr_data = {}
  local current_stdout = ""

  -- 创建 pipe
  local stdin_pipe = vim.uv.new_pipe(false)
  local stdout_pipe = vim.uv.new_pipe(false)
  local stderr_pipe = capture_stderr and vim.uv.new_pipe(false) or nil

  -- 解析命令和参数
  local cmd_parts = {}
  if vim.fn.has("win32") == 1 then
    cmd_parts = { "cmd.exe", "/c", command }
  else
    cmd_parts = { "/bin/sh", "-c", command }
  end

  -- stdio 配置
  local stdio = { stdin_pipe, stdout_pipe, stderr_pipe or nil }

  local handle
  local timer
  local process_exited = false

  -- 创建 session
  session_counter = session_counter + 1
  local session_id = "shell_" .. session_counter

  local session = {
    id = session_id,
    command = command,
    state = "running", -- running | waiting | finished | error
    stdin_pipe = stdin_pipe,
    handle = handle,
    stdout_data = stdout_data,
    stderr_data = stderr_data,
    timer = timer,
    on_success = on_success,
    on_error = on_error,
    on_progress = on_progress,
  }

  local function cleanup()
    process_exited = true
    if timer and not timer:is_closing() then
      timer:close()
      timer = nil
    end
    if stdin_pipe and not stdin_pipe:is_closing() then
      stdin_pipe:read_stop()
      stdin_pipe:close()
    end
    if stdout_pipe and not stdout_pipe:is_closing() then
      stdout_pipe:read_stop()
      stdout_pipe:close()
    end
    if stderr_pipe and not stderr_pipe:is_closing() then
      stderr_pipe:read_stop()
      stderr_pipe:close()
    end
    -- 从 sessions 表中移除
    sessions[session_id] = nil
  end

  local function finish()
    if process_exited then
      return
    end
    cleanup()

    local stdout = table.concat(stdout_data, "")
    local stderr = table.concat(stderr_data, "")

    local result = {
      command = command,
      exit_code = 0,
      signal = nil,
      stdout = stdout,
      stderr = stderr,
      session_id = session_id,
      state = "finished",
    }

    if on_success then
      on_success(result)
    end
  end

  local function fail(err_msg)
    if process_exited then
      return
    end
    session.state = "error"
    cleanup()
    if on_error then
      on_error(err_msg)
    end
  end

  -- 写入 stdin
  local function write_stdin(text)
    if not stdin_pipe or stdin_pipe:is_closing() then
      return false
    end
    local data = text
    if not data:match("\n$") then
      data = data .. "\n"
    end
    local ok, err = stdin_pipe:write(data)
    return ok
  end

  -- 处理输出并检查是否需要输入
  local function process_output()
    local full_output = table.concat(stdout_data, "")
    local new_output = full_output:sub(#current_stdout + 1)
    if new_output and new_output ~= "" then
      current_stdout = full_output

      -- 通过 on_progress 报告实时输出
      if on_progress then
        on_progress("执行命令", "executing", 0, new_output)
      end

      -- 检查是否需要输入
      if detect_input_prompt(full_output) then
        -- 进入等待状态，返回当前输出 + session_id，让大模型调用 send_input
        session.state = "waiting"
        sessions[session_id] = session

        if on_progress then
          on_progress("等待输入", "pending", 0, full_output)
        end

        -- 返回当前输出和 session_id，通知大模型需要输入
        local stdout = table.concat(stdout_data, "")
        local stderr = table.concat(stderr_data, "")
        local result = {
          command = command,
          exit_code = nil,
          signal = nil,
          stdout = stdout,
          stderr = stderr,
          session_id = session_id,
          state = "waiting",
          waiting_for_input = true,
          prompt = full_output,
          message = "命令正在等待输入。请使用 send_input 工具向 session 发送输入内容。",
        }

        if on_success then
          on_success(result)
        end
        return false -- 已处理，不继续
      end
    end
    return true -- 继续执行
  end

  -- 启动进程
  local ok, spawn_err = pcall(function()
    handle = vim.uv.spawn(cmd_parts[1], {
      args = vim.list_slice(cmd_parts, 2),
      stdio = stdio,
      cwd = cwd,
    }, function(code, signal)
      if process_exited then
        return
      end
      cleanup()

      local stdout = table.concat(stdout_data, "")
      local stderr = table.concat(stderr_data, "")

      local result = {
        command = command,
        exit_code = code,
        signal = signal,
        stdout = stdout,
        stderr = stderr,
        session_id = session_id,
        state = "finished",
      }

      if on_success then
        on_success(result)
      end
    end)
  end)

  if not ok or not handle then
    cleanup()
    if on_error then
      on_error(string.format("无法启动命令: %s", spawn_err or "未知错误"))
    end
    return
  end

  -- 更新 session 的 handle
  session.handle = handle
  sessions[session_id] = session

  if on_progress then
    on_progress("启动进程", "completed", 0)
    on_progress("执行命令", "executing", 0)
  end

  -- 开始读取 stdout
  stdout_pipe:read_start(function(err, data)
    if process_exited then
      return
    end
    if data then
      table.insert(stdout_data, data)
      process_output()
    end
  end)

  -- 开始读取 stderr
  if stderr_pipe then
    stderr_pipe:read_start(function(err, data)
      if process_exited then
        return
      end
      if data then
        table.insert(stderr_data, data)
      end
    end)
  end

  -- 超时处理
  timer = vim.uv.new_timer()
  session.timer = timer
  if timer then
    timer:start(timeout_ms, 0, function()
      if process_exited then
        return
      end
      if handle and not handle:is_closing() then
        handle:close()
      end
      fail(string.format("命令执行超时（%d 秒）: %s", timeout_ms / 1000, command))
    end)
  end
end

M.run_command = define_tool({
  name = "run_command",
  description = "执行 shell 命令并返回输出结果。如果命令需要交互输入（如密码、确认等），会返回 waiting_for_input=true 和 session_id，请使用 send_input 工具继续。支持超时设置和工作目录指定。",
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
      session_id = { type = "string", description = "shell session ID，用于 send_input 工具" },
      state = { type = "string", description = "session 状态：running | waiting | finished | error" },
      waiting_for_input = { type = "boolean", description = "是否正在等待用户输入" },
      prompt = { type = "string", description = "等待输入时的提示信息" },
      message = { type = "string", description = "提示消息" },
    },
    description = "命令执行结果或等待输入状态",
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

  -- 写入输入到 stdin
  local stdin_pipe = session.stdin_pipe
  if not stdin_pipe or stdin_pipe:is_closing() then
    session.state = "error"
    sessions[session_id] = nil
    if on_error then
      on_error("stdin pipe 已关闭，无法发送输入")
    end
    return
  end

  -- 发送输入
  local data = input_text
  if not data:match("\n$") then
    data = data .. "\n"
  end

  local ok, write_err = stdin_pipe:write(data)
  if not ok then
    session.state = "error"
    sessions[session_id] = nil
    if on_error then
      on_error(string.format("写入输入失败: %s", write_err or "未知错误"))
    end
    return
  end

  -- 更新 session 状态为 running
  session.state = "running"

  if on_progress then
    on_progress("发送输入", "completed", 0, string.format("已向 session '%s' 发送输入", session_id))
  end

  -- 返回成功
  local result = {
    session_id = session_id,
    input = input_text,
    state = "running",
    message = string.format("已成功向 session '%s' 发送输入。命令将继续执行，请等待后续输出。", session_id),
  }

  if on_success then
    on_success(result)
  end
end

M.send_input = define_tool({
  name = "send_input",
  description = "向正在等待输入的 shell session 发送输入内容（如密码、确认等）。必须先调用 run_command 获取 session_id，当 run_command 返回 waiting_for_input=true 时使用此工具。",
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
        description = "要发送的输入内容（必填），如密码、y/n 确认等",
      },
    },
    required = { "session_id", "input" },
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

return M
