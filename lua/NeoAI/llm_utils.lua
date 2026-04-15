-- NeoAI LLM 工具模块
-- 供 LLM 调用的工具（shell 执行、文件操作等）

local ShellMonitor = {}

-- 检查进程状态（免 root）
function ShellMonitor.check_process_simple(pid)
  if not pid then
    return "unknown"
  end

  -- Linux: 通过 /proc 检查
  local stat_file = "/proc/" .. pid .. "/stat"
  local f = io.open(stat_file, "r")
  if f then
    local content = f:read("*all")
    f:close()
    if content then
      local state = content:match("%) (%S)")
      if state then
        if state == "R" then
          return "running"
        elseif state == "S" or state == "D" then
          return "sleeping"
        elseif state == "Z" then
          return "zombie"
        elseif state == "T" then
          return "stopped"
        elseif state == "X" or state == "x" then
          return "dead"
        end
      end
    end
  end

  -- 回退: ps 命令
  local handle = io.popen("ps -p " .. pid .. " -o state= 2>/dev/null")
  if handle then
    local state = handle:read("*l")
    handle:close()
    if state then
      state = state:gsub("%s+", "")
      if state == "R" then
        return "running"
      elseif state == "S" or state == "D" then
        return "sleeping"
      elseif state == "Z" then
        return "zombie"
      elseif state == "T" then
        return "stopped"
      end
    end
  end

  return "finished"
end

-- 读取 /proc/<pid>/stat 状态
function ShellMonitor.read_proc_stat(pid)
  if not pid then
    return nil
  end

  local stat_file = "/proc/" .. pid .. "/stat"
  local f = io.open(stat_file, "r")
  if not f then
    return nil
  end

  local content = f:read("*all")
  f:close()

  if not content then
    return nil
  end

  local state = content:match("%) (%S)")
  if state then
    return { state = state, raw = content }
  end

  return nil
end

-- 读取 /proc/<pid>/wchan
function ShellMonitor.read_proc_wchan(pid)
  if not pid then
    return nil
  end

  local wchan_file = "/proc/" .. pid .. "/wchan"
  local f = io.open(wchan_file, "r")
  if not f then
    return nil
  end

  local content = f:read("*l")
  f:close()

  if content and content ~= "0" and content ~= "" then
    return content
  end

  return nil
end

-- 休眠（秒）
function ShellMonitor.sleep(seconds)
  if vim then
    local uv = vim.loop or vim.uv
    if uv and uv.sleep then
      uv.sleep(math.floor(seconds * 1000))
      return
    end
  end
  os.execute("sleep " .. tostring(seconds))
end

-- 带监控执行命令
-- @param cmd 命令
-- @param on_state_change 状态回调 function(旧, 新, 输出)
-- @param on_output 输出回调 function(行)
-- @return 最终状态, 完整输出
function ShellMonitor.execute_with_monitoring(cmd, on_state_change, on_output)
  local cmd_handle = io.popen(cmd .. " 2>&1", "r")
  if not cmd_handle then
    return "error", "无法启动: " .. cmd
  end

  local cmd_pid = nil
  local pid_handle = io.popen("echo $!")
  if pid_handle then
    cmd_pid = tonumber(pid_handle:read("*l"))
    pid_handle:close()
  end

  local last_state = "running"
  local output_buffer = ""
  local last_activity = os.time()

  local output_reader = coroutine.create(function()
    while true do
      local line = cmd_handle:read("*l")
      if line then
        output_buffer = output_buffer .. line .. "\n"
        last_activity = os.time()
        if on_output then
          on_output(line)
        end
      else
        coroutine.yield()
      end
    end
  end)

  while true do
    local status, err = coroutine.resume(output_reader)
    if not status then
      break
    end

    local current_state = ShellMonitor.check_process_simple(cmd_pid)

    if current_state ~= last_state then
      if on_state_change then
        on_state_change(last_state, current_state, output_buffer)
      end
      last_state = current_state
    end

    if current_state == "sleeping" then
      local stat = ShellMonitor.read_proc_stat(cmd_pid)
      if stat and stat.state == "S" then
        local wchan = ShellMonitor.read_proc_wchan(cmd_pid)
        if wchan and (wchan:match("tty") or wchan:match("read")) then
          return "waiting_input", output_buffer
        end
      end
    elseif current_state == "finished" then
      break
    end

    ShellMonitor.sleep(0.1)
  end

  local final_output = output_buffer
  while true do
    local line = cmd_handle:read("*l")
    if not line then
      break
    end
    final_output = final_output .. line .. "\n"
  end

  cmd_handle:close()
  return "finished", final_output
end

-- LLM 可调用的 shell 工具
local M = {}

--- 执行 shell 命令
-- @param params {command: 命令, timeout: 超时秒}
-- @return {success: 布尔, output: 输出, exit_code: 退出码, status: 状态}
function M.shell_execute(params)
  params = params or {}
  local cmd = params.command
  local timeout = params.timeout or 30

  if not cmd or cmd == "" then
    return { success = false, output = "错误: 未提供命令", exit_code = -1, status = "error" }
  end

  -- 安全检查: 禁止危险命令
  local dangerous_patterns = {
    "rm%s+%%-rf%s+/",
    "mkfs",
    "dd%s+if=",
  }

  for _, pattern in ipairs(dangerous_patterns) do
    if cmd:match(pattern) then
      return { success = false, output = "错误: 命令被拒绝", exit_code = -1, status = "blocked" }
    end
  end

  local status, output = ShellMonitor.execute_with_monitoring(cmd, function(old_state, new_state, current_output)
    if vim then
      vim.notify(string.format("[Shell] %s -> %s", old_state, new_state), vim.log.levels.DEBUG)
    end
  end, nil)

  return {
    success = (status == "finished"),
    output = output or "",
    exit_code = (status == "finished") and 0 or 1,
    status = status,
  }
end

--- 读取文件内容
-- @param params {filepath: 文件路径}
-- @return {success: 布尔, content: 内容, error: 错误信息}
function M.read_file(params)
  params = params or {}
  local filepath = params.filepath

  if not filepath or filepath == "" then
    return { success = false, error = "未提供文件路径" }
  end

  -- 安全检查：防止读取敏感文件
  local sensitive_patterns = {
    "/etc/passwd",
    "/etc/shadow",
    "/root/",
    "/proc/",
    "/sys/",
  }

  for _, pattern in ipairs(sensitive_patterns) do
    if filepath:match(pattern) then
      return { success = false, error = "禁止读取敏感文件: " .. pattern }
    end
  end

  local f = io.open(filepath, "r")
  if not f then
    return { success = false, error = "无法打开文件: " .. filepath }
  end

  local content = f:read("*all")
  f:close()

  return { success = true, content = content }
end

--- 写入文件内容
-- @param params {filepath: 文件路径, content: 内容}
-- @return {success: 布尔, error: 错误信息}
function M.write_file(params)
  params = params or {}
  local filepath = params.filepath
  local content = params.content or ""

  if not filepath or filepath == "" then
    return { success = false, error = "未提供文件路径" }
  end

  -- 安全检查：防止写入敏感位置
  local sensitive_patterns = {
    "/etc/",
    "/root/",
    "/proc/",
    "/sys/",
    "/dev/",
  }

  for _, pattern in ipairs(sensitive_patterns) do
    if filepath:match(pattern) then
      return { success = false, error = "禁止写入敏感位置: " .. pattern }
    end
  end

  local f = io.open(filepath, "w")
  if not f then
    return { success = false, error = "无法打开文件: " .. filepath }
  end

  f:write(content)
  f:close()

  return { success = true }
end

--- 列出目录内容
-- @param params {directory: 目录路径}
-- @return {success: 布尔, files: 文件列表, error: 错误信息}
function M.list_directory(params)
  params = params or {}
  local directory = params.directory or "."

  -- 安全检查
  local sensitive_patterns = {
    "/etc/",
    "/root/",
    "/proc/",
    "/sys/",
  }

  for _, pattern in ipairs(sensitive_patterns) do
    if directory:match(pattern) then
      return { success = false, error = "禁止访问敏感目录: " .. pattern }
    end
  end

  local handle = io.popen("ls -la " .. directory .. " 2>/dev/null")
  if not handle then
    return { success = false, error = "无法列出目录: " .. directory }
  end

  local output = handle:read("*all")
  handle:close()

  return { success = true, output = output }
end

--- 分析代码文件
-- @param params {filepath: 文件路径, language: 语言（可选）}
-- @return {success: 布尔, analysis: 分析结果, error: 错误信息}
function M.analyze_code(params)
  params = params or {}
  local filepath = params.filepath
  local language = params.language

  if not filepath or filepath == "" then
    return { success = false, error = "未提供文件路径" }
  end

  local read_result = M.read_file({ filepath = filepath })
  if not read_result.success then
    return read_result
  end

  local content = read_result.content

  -- 自动检测语言
  if not language then
    if filepath:match("%.lua$") then
      language = "lua"
    elseif filepath:match("%.py$") then
      language = "python"
    elseif filepath:match("%.js$") or filepath:match("%.ts$") then
      language = "javascript"
    elseif filepath:match("%.go$") then
      language = "go"
    elseif filepath:match("%.rs$") then
      language = "rust"
    elseif filepath:match("%.cpp$") or filepath:match("%.h$") then
      language = "cpp"
    else
      language = "unknown"
    end
  end

  -- 简单分析
  local lines = {}
  for line in content:gmatch("[^\n]+") do
    table.insert(lines, line)
  end

  local line_count = #lines
  local char_count = #content
  local word_count = 0
  for word in content:gmatch("%S+") do
    word_count = word_count + 1
  end

  -- 检测函数定义
  local functions = {}
  if language == "lua" then
    for i, line in ipairs(lines) do
      if line:match("function%s+") then
        local func_name = line:match("function%s+([%w_%.]+)")
        if func_name then
          table.insert(functions, { name = func_name, line = i })
        end
      end
    end
  elseif language == "python" then
    for i, line in ipairs(lines) do
      if line:match("^def%s+") then
        local func_name = line:match("def%s+([%w_]+)")
        if func_name then
          table.insert(functions, { name = func_name, line = i })
        end
      end
    end
  end

  return {
    success = true,
    analysis = {
      language = language,
      line_count = line_count,
      char_count = char_count,
      word_count = word_count,
      functions = functions,
      function_count = #functions,
    },
  }
end

--- 获取工具描述（LLM function calling 用）
function M.get_tools()
  return {
    {
      type = "function",
      ["function"] = {
        name = "shell_execute",
        description = "执行 shell 命令并返回输出",
        parameters = {
          type = "object",
          properties = {
            command = { type = "string", description = "要执行的 shell 命令" },
            timeout = { type = "number", description = "超时秒数（默认 30）" },
          },
          required = { "command" },
        },
      },
    },
    {
      type = "function",
      ["function"] = {
        name = "read_file",
        description = "读取文件内容",
        parameters = {
          type = "object",
          properties = {
            filepath = { type = "string", description = "文件路径" },
          },
          required = { "filepath" },
        },
      },
    },
    {
      type = "function",
      ["function"] = {
        name = "write_file",
        description = "写入文件内容",
        parameters = {
          type = "object",
          properties = {
            filepath = { type = "string", description = "文件路径" },
            content = { type = "string", description = "要写入的内容" },
          },
          required = { "filepath", "content" },
        },
      },
    },
    {
      type = "function",
      ["function"] = {
        name = "list_directory",
        description = "列出目录内容",
        parameters = {
          type = "object",
          properties = {
            directory = { type = "string", description = "目录路径（默认当前目录）" },
          },
          required = {},
        },
      },
    },
    {
      type = "function",
      ["function"] = {
        name = "analyze_code",
        description = "分析代码文件（统计行数、函数等）",
        parameters = {
          type = "object",
          properties = {
            filepath = { type = "string", description = "文件路径" },
            language = { type = "string", description = "编程语言（可选，自动检测）" },
          },
          required = { "filepath" },
        },
      },
    },
  }
end

M.ShellMonitor = ShellMonitor
return M
