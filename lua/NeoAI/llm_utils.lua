-- NeoAI LLM 工具模块
-- 供 LLM 调用的工具（shell 执行、文件操作等）

local ShellMonitor = {}

-- 检查进程状态（免 root）
function ShellMonitor.check_process_simple(pid)
    if not pid then return "unknown" end

    -- Linux: 通过 /proc 检查
    local stat_file = "/proc/" .. pid .. "/stat"
    local f = io.open(stat_file, "r")
    if f then
        local content = f:read("*all")
        f:close()
        if content then
            local state = content:match("%) (%S)")
            if state then
                if state == "R" then return "running"
                elseif state == "S" or state == "D" then return "sleeping"
                elseif state == "Z" then return "zombie"
                elseif state == "T" then return "stopped"
                elseif state == "X" or state == "x" then return "dead"
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
            if state == "R" then return "running"
            elseif state == "S" or state == "D" then return "sleeping"
            elseif state == "Z" then return "zombie"
            elseif state == "T" then return "stopped"
            end
        end
    end

    return "finished"
end

-- 读取 /proc/<pid>/stat 状态
function ShellMonitor.read_proc_stat(pid)
    if not pid then return nil end

    local stat_file = "/proc/" .. pid .. "/stat"
    local f = io.open(stat_file, "r")
    if not f then return nil end

    local content = f:read("*all")
    f:close()

    if not content then return nil end

    local state = content:match("%) (%S)")
    if state then
        return { state = state, raw = content }
    end

    return nil
end

-- 读取 /proc/<pid>/wchan
function ShellMonitor.read_proc_wchan(pid)
    if not pid then return nil end

    local wchan_file = "/proc/" .. pid .. "/wchan"
    local f = io.open(wchan_file, "r")
    if not f then return nil end

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
                if on_output then on_output(line) end
            else
                coroutine.yield()
            end
        end
    end)

    while true do
        local status, err = coroutine.resume(output_reader)
        if not status then break end

        local current_state = ShellMonitor.check_process_simple(cmd_pid)

        if current_state ~= last_state then
            if on_state_change then on_state_change(last_state, current_state, output_buffer) end
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
        if not line then break end
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
        if vim then vim.notify(string.format("[Shell] %s -> %s", old_state, new_state), vim.log.levels.DEBUG) end
    end, nil)

    return {
        success = (status == "finished"),
        output = output or "",
        exit_code = (status == "finished") and 0 or 1,
        status = status
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
                        timeout = { type = "number", description = "超时秒数（默认 30）" }
                    },
                    required = { "command" }
                }
            }
        }
    }
end

M.ShellMonitor = ShellMonitor
return M
