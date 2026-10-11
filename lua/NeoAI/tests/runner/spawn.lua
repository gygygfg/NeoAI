--- NeoAI 测试运行器：子进程执行器（输出卸载与结果 sidecar）
--- @module 'NeoAI.tests.runner.spawn'
--- 默认执行器把子进程 stdout/stderr **直接落盘到日志文件**（shell 重定向），父端不再逐行缓冲，
--- 仅解析子进程写出的结果 sidecar（小 JSON：passed/failed/errors/timings）。失败/verbose 时由
--- report 按需懒读日志尾部。保留可注入执行器（测试用），并把在跑 job 登记以便退出/超时清理。

local tests = require("NeoAI.tests")
local config = require("NeoAI.tests.runner.config")

local M = {}

-- 私有状态
local spawner = nil -- 注入的执行器 fn(req, opts)
local active_jobs = {} -- job_id -> pid
local leave_registered = false

--- 结束某 worker 及其整个进程树（委托 tests._kill_proc_tree）。
--- @param job number
--- @param immediate boolean|nil
function M.kill_tree(job, immediate)
  local pid = active_jobs[job]
  active_jobs[job] = nil
  if tests._kill_proc_tree then
    tests._kill_proc_tree(job, pid, immediate)
  else
    pcall(vim.fn.jobstop, job)
  end
end

--- 登记 VimLeavePre 兜底钩子（幂等）：父 nvim 退出时强杀所有在跑 worker 进程树。
local function _install_leave_hook()
  if leave_registered then return end
  leave_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("NeoAITestWorkersLeave", { clear = true }),
    callback = function()
      for job in pairs(active_jobs) do
        pcall(M.kill_tree, job, true)
      end
    end,
    desc = "NeoAI: 结束遗留的并行测试 worker 进程树",
  })
end

--- 覆盖子进程执行器（测试用）；传 nil 恢复默认
--- @param fn function|nil
function M.set_spawner(fn)
  spawner = fn
end

--- 当前执行器解析：显式注入 > 默认
--- @return function
function M.get()
  return spawner or M.default_spawn
end

--- 结束所有在跑 worker 的进程树（父端退出/中止时兜底；幂等）。
function M.abort_all()
  for job in pairs(active_jobs) do
    pcall(M.kill_tree, job, true)
  end
end

--- 重置注入状态（测试用）
function M.reset()
  spawner = nil
end

--- 写入临时子进程脚本
--- @param content string
--- @return string|nil
function M.write_script(content)
  local path = vim.fn.tempname() .. "_neoai_test_parallel.lua"
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(content)
  f:close()
  return path
end

--- 从结果 sidecar 读取结果字段（存在且为合法 JSON 时返回表，否则 nil）。
--- @param result_path string|nil
--- @return table|nil
function M.read_sidecar(result_path)
  if not result_path then return nil end
  local f = io.open(result_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

--- 把结果 sidecar 字段并入 res（若存在 sidecar）。
--- @param res table
--- @param result_path string|nil
local function _merge_sidecar(res, result_path)
  local data = M.read_sidecar(result_path)
  if not data then return false end
  res.passed = tonumber(data.passed) or 0
  res.failed = tonumber(data.failed) or 0
  res.errors = data.errors or {}
  res.timings = data.timings or {}
  res.has_result = true
  return true
end

--- 默认执行器：子进程输出直接落盘日志，父端仅读 sidecar；退出/超时后回调 opts.on_done(res)。
--- @param req table { script = string, result_path? = string, log_path? = string }
--- @param opts table { on_done = fun(res), timeout_ms? = number }
function M.default_spawn(req, opts)
  local root = tests._plugin_root()
  if not root then
    opts.on_done({ exit_code = -1, errors = { "无法定位插件根目录（tests/init.lua 路径异常）" } })
    return
  end
  local script_path = M.write_script(req.script)
  if not script_path then
    opts.on_done({ exit_code = -1, errors = { "无法写入测试脚本" } })
    return
  end
  local log_path = req.log_path or (vim.fn.tempname() .. "_neoai_shard.log")
  -- 用 shell 重定向把子进程 stdout/stderr 直接落盘到日志文件：父端 **零输出处理**
  -- （无 on_stdout/on_stderr、无逐行回调、不驻留任何输出），最大化主线程卸载。
  local argv = tests._child_cmd(root, script_path)
  local quoted = {}
  for _, a in ipairs(argv) do quoted[#quoted + 1] = vim.fn.shellescape(a) end
  local shell_cmd = table.concat(quoted, " ")
    .. " > " .. vim.fn.shellescape(log_path) .. " 2>&1"
  local cmd = { "sh", "-c", shell_cmd }

  local done = false
  local timer = nil
  local job = nil
  local function finish(code, timed_out)
    if done then return end
    done = true
    if job then active_jobs[job] = nil end
    if timer then
      pcall(function() timer:stop(); timer:close() end)
      timer = nil
    end
    pcall(os.remove, script_path)
    local res = { exit_code = code, log_path = log_path, result_path = req.result_path }
    local had_sidecar = _merge_sidecar(res, req.result_path)
    if timed_out then
      res.errors = res.errors or {}
      res.errors[#res.errors + 1] = "测试分片超时"
    end
    if not had_sidecar then
      -- 无 sidecar（异常退出/超时/旧路径）：保留提示，report 会懒读日志尾部。
      res.no_sidecar = true
    end
    opts.on_done(res)
  end

  job = vim.fn.jobstart(cmd, {
    on_exit = function(_, code) finish(code, false) end,
  })
  if job <= 0 then
    finish(-1, false)
    return
  end
  active_jobs[job] = vim.fn.jobpid(job)
  _install_leave_hook()
  local timeout_ms = tonumber(opts.timeout_ms) or config.DEFAULT_TIMEOUT_MS
  if timeout_ms > 0 then
    timer = vim.uv.new_timer()
    if timer then
      timer:start(timeout_ms, 0, function()
        if done then return end
        -- 超时：结束整个进程树（含脱离 job 进程组的沙箱常驻/PTY 后代）；
        -- worker 收到 SIGTERM 后自清插件再退出（见 _isolated_script 注入的 SIGTERM 处理器）。
        M.kill_tree(job)
        vim.schedule(function()
          finish(-1, true)
        end)
      end)
    end
  end
end

return M
