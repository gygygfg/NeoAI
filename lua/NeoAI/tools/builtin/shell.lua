--- Shell 命令工具
--- @module NeoAI.tools.builtin.shell
--- 执行 Shell 命令（异步，非交互）。交互式 PTY 见阶段8 ui/components。

local async = require("NeoAI.utils.async")
local helpers = require("NeoAI.tools.builtin.tool_helpers")

local M = {}

-- ========== 私有函数 ==========

--- 执行 shell 命令（jobstart，收集 stdout/stderr）
--- @param command string
--- @param opts table { timeout_ms?, signal? }
--- @return Deferred resolve({ code, stdout, stderr })
local function _run_command(command, opts)
  opts = opts or {}
  local d = async.Deferred.new()
  local stdout = {}
  local stderr = {}
  local done = false
  local timeout_ms = opts.timeout_ms or 30000

  local unsub = function() end
  if opts.signal then
    unsub = opts.signal:subscribe(function(reason)
      if job and vim.fn.job_status(job) == "run" then
        pcall(vim.fn.jobstop, job)
      end
      if not done then
        done = true
        d:reject({ kind = "aborted", message = reason })
      end
    end)
  end

  local timer
  if timeout_ms > 0 then
    timer = true
    vim.defer_fn(function()
      if not done then
        done = true
        pcall(vim.fn.jobstop, job)
        d:reject({ kind = "timeout", message = "命令执行超时" })
      end
    end, timeout_ms)
  end

  local job = vim.fn.jobstart({ "sh", "-c", command }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then stdout[#stdout + 1] = line end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      if done then return end
      done = true
      unsub()
      if timer then timer = nil end
      d:resolve({ code = code, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n") })
    end,
  })

  if job <= 0 then
    done = true
    if timer then timer = nil end
    return async.reject({ kind = "shell", message = "无法启动 shell 进程" })
  end
  return d
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
    _run_command(command, { timeout_ms = args.timeout_ms, signal = signal }):then_(function(result)
      if result.code == 0 then
        on_success(result.stdout ~= "" and result.stdout or "（无输出）")
      else
        on_success(string.format("命令退出码 %d\n%s", result.code, result.stderr ~= "" and result.stderr or result.stdout))
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
