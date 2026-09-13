--- Shell 命令工具
--- @module NeoAI.tools.builtin.shell
--- 执行 Shell 命令（异步，非交互）。交互式 PTY 见阶段8 ui/components。

local async = require("NeoAI.utils.async")
local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有函数 ==========

--- 为 argv 前置沙箱运行时前缀（隔离执行）
--- @param argv table
--- @param opts table { prefix?: table }
--- @return table
local function _sandboxed_argv(argv, opts)
  if not (opts and opts.prefix and #opts.prefix > 0) then return argv end
  local full = {}
  for _, v in ipairs(opts.prefix) do full[#full + 1] = v end
  for _, v in ipairs(argv) do full[#full + 1] = v end
  return full
end

--- 执行 shell 命令（jobstart，实时累积 stdout/stderr）。
--- 采用非缓冲输出：命令超时/被取消时也能回传「此刻终端已产生的内容」，
--- 而不是只剩一句错误信息。始终 resolve 结果表（含 timed_out/aborted 标记），
--- 由调用方决定如何呈现；只有进程无法启动才 reject。
--- @param command string
--- @param opts table { timeout_ms?, signal? }
--- @return Deferred resolve({ code, stdout, stderr, timed_out?, aborted?, message? })
local function _run_command(command, opts)
  opts = opts or {}
  local d = async.Deferred.new()
  local stdout_chunks = {}
  local stderr_chunks = {}
  local done = false
  local job
  local timeout_ms = opts.timeout_ms or 30000

  local function snapshot()
    return table.concat(stdout_chunks), table.concat(stderr_chunks)
  end

  local unsub = function() end

  local function settle(result)
    if done then return end
    done = true
    unsub()
    d:resolve(result)
  end

  if opts.signal then
    unsub = opts.signal:subscribe(function(reason)
      if job then pcall(vim.fn.jobstop, job) end
      local out, errout = snapshot()
      settle({ code = -1, stdout = out, stderr = errout, aborted = true, message = reason })
    end)
  end

  if timeout_ms > 0 then
    vim.defer_fn(function()
      if done then return end
      if job then pcall(vim.fn.jobstop, job) end
      local out, errout = snapshot()
      settle({ code = -1, stdout = out, stderr = errout, timed_out = true })
    end, timeout_ms)
  end

  job = vim.fn.jobstart(_sandboxed_argv({ "sh", "-c", command }, opts), {
    cwd = opts.cwd,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if data and #data > 0 then
        stdout_chunks[#stdout_chunks + 1] = table.concat(data, "\n")
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        stderr_chunks[#stderr_chunks + 1] = table.concat(data, "\n")
      end
    end,
    on_exit = function(_, code)
      local out, errout = snapshot()
      settle({ code = code, stdout = out, stderr = errout })
    end,
  })

  if job <= 0 then
    done = true
    return async.reject({ kind = "shell", message = "无法启动 shell 进程" })
  end
  return d
end

--- 组合「状态行 + 已产生的终端输出」，错误路径也保留输出内容
--- @param status string
--- @param out string
--- @param errout string
--- @return string
local function _with_status(status, out, errout)
  local parts = { status }
  if out and out ~= "" then parts[#parts + 1] = out end
  if errout and errout ~= "" then parts[#parts + 1] = errout end
  if #parts == 1 then parts[#parts + 1] = "（无输出）" end
  return table.concat(parts, "\n")
end

-- ========== 工具定义 ==========

local shell_tools = {}

shell_tools.run_command = helpers.define_tool(
  "run_command",
  "执行 Shell 命令。command 必填。timeout_ms 可选（默认 30000，-1 为不限）。",
  {
    type = "object",
    properties = {
      command = { type = "string", description = "要执行的 shell 命令" },
      timeout_ms = { type = "integer", description = "超时毫秒数" },
    },
    required = { "command" },
  },
  function(args, on_success, on_error, ctx)
    local command = args.command
    local signal = ctx and ctx.signal
    _run_command(command, {
      timeout_ms = args.timeout_ms,
      signal = signal,
      prefix = ctx and ctx.sandbox_prefix,
      cwd = ctx and ctx.sandbox_cwd,
    }):then_(function(result)
      local out = result.stdout or ""
      local errout = result.stderr or ""
      if result.aborted then
        -- 取消/超时/非零退出都回传已产生的终端内容，模型仍能看到当前进度
        on_success(_with_status("命令已取消：" .. tostring(result.message or "cancelled"), out, errout))
      elseif result.timed_out then
        on_success(_with_status("命令执行超时", out, errout))
      elseif result.code == 0 then
        on_success(out ~= "" and out or "（无输出）")
      else
        on_success(_with_status(string.format("命令退出码 %d", result.code), out, errout))
      end
    end, function(err)
      on_error(err.message or tostring(err))
    end)
  end,
  { category = "system", approval = { auto_allow = false }, timeout = -1 }
)

--- 获取工具列表
--- @return table 数组
function M.get_tools()
  local out = {}
  for _, tool in pairs(shell_tools) do
    out[#out + 1] = tool
  end
  return out
end

return M
