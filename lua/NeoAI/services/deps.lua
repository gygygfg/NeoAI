--- 可选安全依赖管理服务
--- @module 'NeoAI.services.deps'
---
--- `:NeoAI Deps` 的后端：探测可选依赖、生成**结构化 argv**（不经 shell）、启动包管理器、
--- 发事件并可在插件卸载时终止任务。安装必须由用户显式选择并确认；不注册为 AI 工具。

local catalog = require("NeoAI.utils.deps_catalog")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

local state = {
  job = nil,
  plan = nil,
  last = nil,
}

local function _emit(name, payload)
  pcall(function() event_bus.emit(name, payload or {}) end)
end

--- 依赖状态列表。
--- @return table[]
function M.status()
  return catalog.status()
end

--- 生成安装计划。
--- @param ids string[]
--- @return table|nil
--- @return string|nil
function M.plan(ids)
  return catalog.plan(ids)
end

--- 展示命令。
--- @param plan table
--- @return string
function M.command_string(plan)
  return catalog.command_string(plan)
end

--- 运行安装计划（异步）。
--- @param plan table
--- @param opts table|nil { on_output?: fun(chunk:string), on_done?: fun(ok:boolean, code:number) }
--- @return number|nil job
function M.run(plan, opts)
  opts = opts or {}
  if type(plan) ~= "table" or type(plan.argv) ~= "table" then return nil end
  if state.job and vim.fn.jobwait({ state.job }, 0)[1] == -1 then
    return nil -- 已有安装任务
  end
  state.plan = plan
  _emit(events.SANDBOX_DEPS_INSTALL_STARTED, {
    pm = plan.pm, packages = plan.packages, argv = plan.argv,
  })
  local job = vim.fn.jobstart(plan.argv, {
    pty = plan.interactive == true,
    on_stdout = function(_, data)
      if not data or #data == 0 then return end
      local text = table.concat(data, "\n")
      if opts.on_output then pcall(opts.on_output, text) end
    end,
    on_stderr = function(_, data)
      if not data or #data == 0 then return end
      local text = table.concat(data, "\n")
      if opts.on_output then pcall(opts.on_output, text) end
    end,
    on_exit = function(_, code)
      state.job = nil
      local ok = code == 0
      state.last = { ok = ok, code = code, at = os.time(), packages = plan.packages }
      if ok then
        _emit(events.SANDBOX_DEPS_INSTALL_FINISHED, { pm = plan.pm, packages = plan.packages })
      else
        _emit(events.SANDBOX_DEPS_INSTALL_FAILED, { pm = plan.pm, packages = plan.packages, code = code })
      end
      if opts.on_done then pcall(opts.on_done, ok, code) end
    end,
  })
  if job <= 0 then
    state.job = nil
    _emit(events.SANDBOX_DEPS_INSTALL_FAILED, { pm = plan.pm, reason = "JOBSTART_FAILED" })
    return nil
  end
  state.job = job
  return job
end

--- 在终端 split 中运行安装计划（可视化、支持 sudo 输入密码）。
--- @param plan table
--- @param opts table|nil { on_done?: fun(ok:boolean, code:number) }
--- @return number|nil job
function M.run_terminal(plan, opts)
  opts = opts or {}
  if type(plan) ~= "table" or type(plan.argv) ~= "table" then return nil end
  if state.job and vim.fn.jobwait({ state.job }, 0)[1] == -1 then
    vim.notify("[NeoAI] 已有依赖安装任务在运行", vim.log.levels.WARN)
    return nil
  end
  state.plan = plan
  _emit(events.SANDBOX_DEPS_INSTALL_STARTED, {
    pm = plan.pm, packages = plan.packages, argv = plan.argv,
  })
  vim.cmd("botright new")
  vim.bo.bufhidden = "wipe"
  vim.bo.swapfile = false
  vim.bo.buftype = "nofile"
  local job = vim.fn.termopen(plan.argv, {
    on_exit = function(_, code)
      state.job = nil
      local ok = code == 0
      state.last = { ok = ok, code = code, at = os.time(), packages = plan.packages }
      if ok then
        _emit(events.SANDBOX_DEPS_INSTALL_FINISHED, { pm = plan.pm, packages = plan.packages })
      else
        _emit(events.SANDBOX_DEPS_INSTALL_FAILED, { pm = plan.pm, packages = plan.packages, code = code })
      end
      if opts.on_done then pcall(opts.on_done, ok, code) end
    end,
  })
  if job <= 0 then
    state.job = nil
    _emit(events.SANDBOX_DEPS_INSTALL_FAILED, { pm = plan.pm, reason = "TERMOPEN_FAILED" })
    return nil
  end
  state.job = job
  vim.cmd("startinsert")
  return job
end

--- 终止安装任务。
function M.stop()
  if state.job then
    pcall(vim.fn.jobstop, state.job)
    state.job = nil
  end
end

--- 最近一次结果。
--- @return table|nil
function M.last()
  return state.last
end

--- 重置（测试）。
function M.reset()
  M.stop()
  state.plan = nil
  state.last = nil
  catalog.reset()
end

return M
