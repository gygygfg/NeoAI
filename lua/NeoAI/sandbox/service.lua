--- 沙箱长驻服务
--- @module NeoAI.sandbox.service
--- 后台进程跨工具调用存活，直到显式停止 / 会话结束。每个服务使用**独立 overlay attempt**
--- （独立 upper/work，不与 run_command 的共享会话暂存竞争）：
---   * 启动：把工作区暂存内容物化进服务 overlay（单向快照），使服务看到 AI 尚未发布的编辑；
---   * 停止：捕获服务 overlay 改动 → 冻结候选 → 合并回工作区暂存（边界同步，非实时互通），
---     经异步审批入队（复用 wrapper.settle_exec_candidate）。
--- 资源域（cgroup v2）随服务创建，停止时 cgroup.kill 精确终止整个进程树（无 cgroup 时回退
--- jobstop）。日志为会话内环形缓冲，读取时经 conceal 脱敏。
---
--- 与 run_command 不同：服务不在 wrapper 的一次性进程 FIFO 内，可与其他命令并发运行；其
--- 隔离由本模块自建（runtime.process_prefix），门禁仍完成策略/脚本扫描/硬拒绝预检
--- （见 wrapper 的 long_lived 分支）。

local async = require("NeoAI.utils.async")
local config_store = require("NeoAI.kernel.config_store")
local fs = require("NeoAI.utils.fs")
local cgroup = require("NeoAI.sandbox.cgroup")
local candidate = require("NeoAI.sandbox.candidate")
local control = require("NeoAI.sandbox.control")
local store = require("NeoAI.sandbox.store")
local runtime = require("NeoAI.sandbox.runtime")
local wrapper = require("NeoAI.sandbox.wrapper")
local secret = require("NeoAI.sandbox.secret")
local conceal = require("NeoAI.sandbox.conceal")
local logger = require("NeoAI.kernel.logger")

local M = {}

local state = {
  services = {}, -- id -> svc
  order = {},    -- 有序 id 列表
  seq = 0,
}

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  return config_store.get("tools.sandbox.service") or {}
end

--- @return string
local function _services_root()
  return (store.root() or (vim.fn.stdpath("cache") .. "/NeoAI/sandbox")) .. "/services"
end

--- 按名字查找服务（id 或 name 均可）
--- @param key string
--- @return table|nil
local function _find(key)
  if type(key) ~= "string" or key == "" then return nil end
  if state.services[key] then return state.services[key] end
  for _, svc in pairs(state.services) do
    if svc.name == key then return svc end
  end
  return nil
end

--- @return string
local function _shell_bin()
  return vim.fn.executable("bash") == 1 and "bash" or "sh"
end

--- 追加日志（环形缓冲，按字节上限裁剪最旧内容）。
--- @param svc table
--- @param chunk string
local function _append_log(svc, chunk)
  if type(chunk) ~= "string" or chunk == "" then return end
  svc.logs[#svc.logs + 1] = chunk
  svc.log_bytes = svc.log_bytes + #chunk
  local cap = tonumber(_cfg().max_log_bytes) or 262144
  while svc.log_bytes > cap and #svc.logs > 1 do
    local removed = table.remove(svc.logs, 1)
    svc.log_bytes = svc.log_bytes - #removed
  end
end

--- 拼接日志（可截取尾部字节）。
--- @param svc table
--- @param tail number|nil 返回末尾字节数；nil/<=0 返回全部
--- @return string
local function _logs_text(svc, tail)
  local text = table.concat(svc.logs)
  if tail and tail > 0 and #text > tail then
    text = text:sub(-tail)
  end
  return text
end

--- 构造服务运行环境与进程前缀。
--- @param svc table
--- @param opts table { cwd?, network?, writable_roots? }
--- @return table|nil full_argv
--- @return string|nil err
local function _build(svc, opts)
  local cfg = _cfg()
  local sandbox_cfg = config_store.get("tools.sandbox") or {}
  local roots = {}
  for _, r in ipairs(opts.writable_roots or { svc.cwd }) do
    if type(r) == "string" and r ~= "" then
      pcall(vim.fn.mkdir, r, "p")
      if vim.fn.isdirectory(r) == 1 then roots[#roots + 1] = (r:gsub("/+$", "")) end
    end
  end
  local real_cwd = opts.cwd or (roots[1] or vim.fn.getcwd())
  svc.cwd = real_cwd
  svc.roots = roots
  local svc_dir = _services_root() .. "/" .. svc.id
  svc.dir = svc_dir
  fs.ensure_dir(svc_dir)

  local attempt = control.new_attempt("service_" .. svc.name, { command = svc.command }, svc.ctx or {}, svc.spec)
  svc.attempt = attempt
  candidate.begin(attempt, store.root())
  local specs = wrapper.build_overlay_specs(real_cwd, svc_dir, roots)
  for _, s in ipairs(specs) do
    if runtime.overlay_available() and runtime.overlay_writable(s.root, s.upper, s.work) then
      s.mode = "overlay"
    else
      s.mode = "bind"
    end
  end
  candidate.materialize_overlay(specs)
  svc.specs = specs

  local priv = {
    network = (opts.network ~= false) and sandbox_cfg.offline ~= true,
    cap_add = {}, mounts = {}, userns = false, unmask = roots,
  }
  local prefix, perr = runtime.process_prefix({
    cwd = real_cwd, overlays = specs, privileges = priv, session_tmp_dir = svc_dir,
  })
  if not prefix then return nil, perr end

  -- 资源域：服务独立 cgroup，停止时精确终止整个进程树。
  local cg_handle = nil
  if cgroup.limits_configured() then
    local h, cerr = cgroup.prepare("svc_" .. svc.id, cgroup.resolve_limits())
    if h then cg_handle = h else logger.warn("[sandbox:service] cgroup 不可用，跳过：%s", tostring(cerr)) end
  end
  svc.cg = cg_handle

  local full = {}
  if cg_handle then
    for _, v in ipairs(cgroup.join_prefix(cg_handle)) do full[#full + 1] = v end
  end
  for _, v in ipairs(prefix) do full[#full + 1] = v end
  local unset = runtime.proxy_unset_snippet()
  local command = secret.detokenize(svc.command)
  if unset then command = unset .. "\n" .. command end
  full[#full + 1] = _shell_bin()
  full[#full + 1] = "-c"
  full[#full + 1] = command
  svc.env = runtime.sandbox_env(priv)
  return full, nil
end

-- ========== 公开 API ==========

--- 启动一个长驻服务。
--- @param name string 服务名（唯一）
--- @param command string shell 命令
--- @param opts table|nil { cwd?, network?, writable_roots? }
--- @return table|nil svc
--- @return string|nil err
function M.start(name, command, opts)
  opts = opts or {}
  if _cfg().enabled == false then return nil, "SERVICE_DISABLED: 沙箱长驻服务已禁用" end
  if type(name) ~= "string" or name == "" then return nil, "服务名不能为空" end
  if type(command) ~= "string" or command == "" then return nil, "服务命令不能为空" end
  if _find(name) then return nil, "同名服务已存在：" .. name end
  local max = tonumber(_cfg().max_services) or 16
  if #state.order >= max then return nil, "服务数量已达上限（" .. max .. "），请先 service_stop" end

  state.seq = state.seq + 1
  local id = string.format("svc_%d_%d", os.time(), state.seq)
  local svc = {
    id = id, name = name, command = command,
    logs = {}, log_bytes = 0,
    started_at = os.time(), status = "starting", exit_code = nil,
  }
  local full, err = _build(svc, opts)
  if not full then
    if svc.attempt then candidate.cleanup(svc.attempt.attempt_id) end
    if svc.cg then cgroup.release(svc.cg) end
    return nil, err or "服务启动失败"
  end

  local job = vim.fn.jobstart(full, {
    cwd = svc.cwd,
    env = svc.env,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if data and #data > 0 then _append_log(svc, table.concat(data, "\n") .. "\n") end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then _append_log(svc, table.concat(data, "\n") .. "\n") end
    end,
    on_exit = function(_, code)
      svc.status = "exited"
      svc.exit_code = code
      svc.stopped_at = os.time()
      if svc.cg then pcall(cgroup.release, svc.cg); svc.cg = nil end
      _append_log(svc, string.format("\n[service] 进程已退出，退出码 %d\n", code))
    end,
  })
  if job <= 0 then
    if svc.attempt then candidate.cleanup(svc.attempt.attempt_id) end
    if svc.cg then cgroup.release(svc.cg) end
    return nil, "无法启动服务进程"
  end
  svc.job = job
  svc.status = "running"
  state.services[id] = svc
  state.order[#state.order + 1] = id
  return svc
end

--- 读取服务日志（末尾 tail 字节）。
--- @param key string
--- @param tail number|nil
--- @return string|nil text
--- @return string|nil err
function M.logs(key, tail)
  local svc = _find(key)
  if not svc then return nil, "服务不存在：" .. tostring(key) end
  return conceal.redact(_logs_text(svc, tail)), nil
end

--- 服务状态。
--- @param key string
--- @return table|nil
function M.status(key)
  local svc = _find(key)
  if not svc then return nil end
  return {
    id = svc.id, name = svc.name, status = svc.status, exit_code = svc.exit_code,
    pid = svc.job, cwd = svc.cwd, started_at = svc.started_at, stopped_at = svc.stopped_at,
    log_bytes = svc.log_bytes, command = svc.command,
  }
end

--- 列出全部服务。
--- @return table 数组
function M.list()
  local out = {}
  for _, id in ipairs(state.order) do
    local svc = state.services[id]
    if svc then out[#out + 1] = M.status(svc.id) end
  end
  return out
end

--- 停止服务并把其改动冻结/合并回工作区暂存（异步）。
--- @param key string
--- @param cb function|nil cb(err, info)
function M.stop(key, cb)
  cb = cb or function() end
  local svc = _find(key)
  if not svc then cb("服务不存在：" .. tostring(key)); return end
  state.services[svc.id] = nil
  for i, id in ipairs(state.order) do
    if id == svc.id then table.remove(state.order, i); break end
  end
  -- 终止：cgroup.kill 精确杀整个进程树；jobstop 兜底。
  if svc.cg then pcall(cgroup.kill, svc.cg) end
  if type(svc.job) == "number" and svc.job > 0 then
    pcall(vim.fn.jobstop, svc.job)
  end
  svc.status = "stopped"
  svc.stopped_at = os.time()
  local cg = svc.cg
  svc.cg = nil

  local function finish_capture()
    if cg then pcall(cgroup.release, cg) end
    local attempt = svc.attempt
    if not attempt then cb(nil, M._info(svc)); return end
    local captures = {}
    for _, s in ipairs(svc.specs or {}) do
      captures[#captures + 1] = candidate.capture_overlay_async(attempt.attempt_id, s.root,
        s.mode == "bind" and s.bind or s.upper)
    end
    if #captures == 0 then
      candidate.cleanup(attempt.attempt_id)
      cb(nil, M._info(svc))
      return
    end
    async.all(captures):then_(function()
      return candidate.finish_async(attempt.attempt_id)
    end):then_(function(cand)
      local ok, serr = pcall(wrapper.settle_exec_candidate, attempt, cand, svc.ctx or {}, svc.spec,
        { code = svc.exit_code or 0 }, { command = svc.command })
      if not ok then
        logger.warn("[sandbox:service] 停止结算失败：%s", tostring(serr))
      end
      cb(nil, M._info(svc))
    end, function(e)
      logger.warn("[sandbox:service] 停止捕获失败：%s", tostring(e and (e.message or e) or e))
      candidate.cleanup(attempt.attempt_id)
      cb(nil, M._info(svc))
    end)
  end

  -- 等待进程优雅退出（有界），再捕获（确保写入落盘）。
  local timeout = tonumber(_cfg().stop_timeout_ms) or 5000
  vim.defer_fn(function()
    if type(svc.job) == "number" and svc.job > 0 then
      local ok, st = pcall(vim.fn.job_status, svc.job)
      if ok and st == "run" then pcall(vim.fn.jobstop, svc.job) end
    end
    finish_capture()
  end, math.min(300, timeout))
end

--- 停止全部服务（会话结束 / 卸载 / 关闭）。best-effort，捕获经 vim.wait 有界等待。
--- @param opts table|nil { timeout_ms? }
function M.stop_all(opts)
  opts = opts or {}
  local ids = vim.deepcopy(state.order)
  if #ids == 0 then return end
  local remaining = #ids
  local done = false
  for _, id in ipairs(ids) do
    local svc = state.services[id]
    if not svc then
      remaining = remaining - 1
    else
      M.stop(id, function()
        remaining = remaining - 1
      end)
    end
  end
  if remaining > 0 then
    vim.wait(tonumber(opts.timeout_ms) or 10000, function() return remaining <= 0 end, 20)
  end
  state.services = {}
  state.order = {}
end

--- 服务信息快照（内部/工具用）。
--- @param svc table
--- @return table
function M._info(svc)
  return {
    id = svc.id, name = svc.name, status = svc.status, exit_code = svc.exit_code,
    log_bytes = svc.log_bytes, cwd = svc.cwd,
  }
end

--- 重置（测试用）
function M.reset()
  M.stop_all({ timeout_ms = 3000 })
  state.services = {}
  state.order = {}
  state.seq = 0
  pcall(function() vim.fn.delete(_services_root(), "rf") end)
end

return M
