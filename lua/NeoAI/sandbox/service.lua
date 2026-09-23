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

--- 是否允许按 Restart= 策略自动重启（含 StartLimitBurst/Interval 限流）。
--- @param svc table
--- @param restart table { policy, sec?, burst?, interval? }
--- @param code number 刚退出的退出码
--- @return boolean
local function _restart_allows(svc, restart, code)
  local policy = restart.policy
  local allow
  if policy == "always" then allow = true
  elseif policy == "on-failure" then allow = (code ~= 0)
  elseif policy == "on-success" then allow = (code == 0)
  elseif policy == "on-abnormal" then allow = (code ~= 0 and code ~= 143 and code ~= 130)
  elseif policy == "on-abort" then allow = (svc.signaled == true)
  else allow = false end
  if not allow then return false end
  -- StartLimit：burst 次重启 / interval 秒窗口内，超过则不再重启（真实 systemd 语义）。
  local burst = tonumber(restart.burst) or 5
  local interval = tonumber(restart.interval) or 10
  local now = vim.uv.now()
  local times = {}
  for _, tm in ipairs(svc.restart_times or {}) do
    if now - tm < interval * 1000 then times[#times + 1] = tm end
  end
  if #times >= burst then
    svc.restart_times = times
    svc.start_limit_hit = true
    return false
  end
  times[#times + 1] = now
  svc.restart_times = times
  return true
end

--- 启动/重启服务进程：按当前 overlay/前缀装配 argv 并（重建）资源域。
--- `svc.restart` 存在时，进程意外退出会按 RestartSec 延迟自动重启（NRestarts 累加）。
--- @param svc table
--- @return boolean|nil ok
--- @return string|nil err
local function _spawn(svc)
  if svc.cg then pcall(cgroup.release, svc.cg); svc.cg = nil end
  local limits = svc.limits or {}
  local want_cg = cgroup.limits_configured()
    or (tonumber(limits.memory_bytes) or 0) > 0
    or (tonumber(limits.pids) or 0) > 0
    or (tonumber(limits.cpu_max) or 0) > 0
  local cg_handle = nil
  if want_cg then
    local h, cerr = cgroup.prepare("svc_" .. svc.id, limits)
    if h then cg_handle = h
    else logger.warn("[sandbox:service] cgroup 不可用，跳过：%s", tostring(cerr)) end
  end
  svc.cg = cg_handle

  local full = {}
  if cg_handle then
    for _, v in ipairs(cgroup.join_prefix(cg_handle)) do full[#full + 1] = v end
  end
  for _, v in ipairs(svc.prefix) do full[#full + 1] = v end
  full[#full + 1] = _shell_bin()
  full[#full + 1] = "-c"
  full[#full + 1] = svc.shell_command

  local function finish(code)
    svc.status = "exited"
    svc.exited = true
    svc.exit_code = code
    svc.stopped_at = os.time()
  end

  local function on_exit(_, code)
    if svc.cg then pcall(cgroup.release, svc.cg); svc.cg = nil end
    pcall(function()
      require("NeoAI.sandbox.net_consent").unregister_ports(svc.internal_ports)
    end)
    local restart = svc.restart
    if restart and not svc.stopping and _restart_allows(svc, restart, code) then
      svc.restart_count = (svc.restart_count or 0) + 1
      svc.status = "starting"
      svc.exited = false
      svc.exit_code = nil
      _append_log(svc, string.format(
        "\n[service] 进程退出（退出码 %s），按 Restart=%s 于 %ss 后重启（第 %d 次）\n",
        tostring(code), tostring(restart.policy), tostring(restart.sec or 0.1), svc.restart_count))
      local delay = math.max(100, math.floor((tonumber(restart.sec) or 0.1) * 1000))
      vim.defer_fn(function()
        if svc.stopping then return end
        local ok, err = _spawn(svc)
        if not ok then
          finish(1)
          _append_log(svc, "\n[service] 自动重启失败：" .. tostring(err) .. "\n")
        end
      end, delay)
      return
    end
    finish(code)
    if svc.start_limit_hit then
      _append_log(svc, string.format(
        "\n[service] 进程已退出（退出码 %d）；超过 StartLimitBurst，不再自动重启\n", code))
    else
      _append_log(svc, string.format("\n[service] 进程已退出，退出码 %d\n", code))
    end
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
    on_exit = on_exit,
  })
  if job <= 0 then
    if cg_handle then pcall(cgroup.release, cg_handle) end
    svc.cg = nil
    return nil, "无法启动服务进程"
  end
  svc.job = job
  svc.status = "running"
  svc.exited = false
  -- 沙箱内部服务端口登记：沙箱内访问这些端口免权限（出沙箱仍按网络策略处理）。
  pcall(function()
    svc.internal_ports = require("NeoAI.sandbox.net_consent").register_from_command(svc.command, svc.env)
  end)
  return true
end

--- 构造服务运行环境与进程前缀。
--- @param svc table
--- @param opts table { cwd?, network?, writable_roots?, limits?, restart?, env? }
--- @return boolean|nil ok
--- @return string|nil err
local function _build(svc, opts)
  local cfg = _cfg()
  local sandbox_cfg = config_store.get("tools.sandbox") or {}
  local base_cwd = opts.workdir or opts.cwd or vim.fn.getcwd()
  local roots = {}
  for _, r in ipairs(opts.writable_roots or { base_cwd }) do
    if type(r) == "string" and r ~= "" then
      pcall(vim.fn.mkdir, r, "p")
      if vim.fn.isdirectory(r) == 1 then roots[#roots + 1] = (r:gsub("/+$", "")) end
    end
  end
  local real_cwd = opts.workdir or opts.cwd or (roots[1] or vim.fn.getcwd())
  svc.cwd = real_cwd
  svc.roots = roots
  local svc_dir = _services_root() .. "/" .. svc.id
  svc.dir = svc_dir
  fs.ensure_dir(svc_dir)

  local attempt = control.new_attempt("service_" .. svc.name, { command = svc.command }, svc.ctx or {}, svc.spec)
  svc.attempt = attempt
  candidate.begin(attempt, store.root())
  -- 覆盖所有已暂存路径：使服务与只读工具看到同一暂存视图（边界同步为单向快照，
  -- 但快照必须包含工作区外的暂存编辑，否则服务读到真实磁盘、视图分裂）。
  local extra = {}
  for _, r in ipairs(roots) do extra[#extra + 1] = r end
  local known = { real_cwd }
  for _, r in ipairs(roots) do known[#known + 1] = r end
  for _, r in ipairs(candidate.staged_overlay_roots(known)) do extra[#extra + 1] = r end
  local specs = wrapper.build_overlay_specs(real_cwd, svc_dir, extra)
  for _, s in ipairs(specs) do
    if runtime.overlay_writable(s.root, s.upper, s.work) then
      s.mode = "overlay"
    else
      s.mode = "bind"
    end
  end
  local conflicts = candidate.materialize_overlay(specs)
  if conflicts and #conflicts > 0 then
    candidate.cleanup(attempt.attempt_id)
    return nil, "SANDBOX_MATERIALIZE_TYPE_CONFLICT: " .. tostring(conflicts[1] and conflicts[1].real)
  end
  svc.specs = specs

  local priv = {
    network = (opts.network ~= false) and sandbox_cfg.offline ~= true,
    cap_add = {}, mounts = {}, userns = false, unmask = roots,
  }
  -- 与 run_command/exec 共用同一「稳定」临时根（/tmp、/var/tmp、/run）：服务据此看到 AI 写入
  -- 会话私有 /run 的脚本/单元，避免「ExecStart 指向 /run 脚本却 No such file or directory」。
  local tmp_base = runtime.stable_tmp_base()
  local prefix, perr = runtime.process_prefix({
    cwd = real_cwd, overlays = specs, privileges = priv,
    session_tmp_dir = tmp_base, tmpfs_base = tmp_base,
  })
  if not prefix then return nil, perr end
  svc.prefix = prefix

  -- 资源限制：全局推导基线；单元 MemoryMax/CPUQuota 覆盖对应项。
  local limits = cgroup.resolve_limits()
  if type(opts.limits) == "table" then
    if (tonumber(opts.limits.memory_bytes) or 0) > 0 then
      limits.memory_bytes = tonumber(opts.limits.memory_bytes)
    end
    if (tonumber(opts.limits.cpu_max) or 0) > 0 then limits.cpu_max = tonumber(opts.limits.cpu_max) end
    if (tonumber(opts.limits.pids) or 0) > 0 then limits.pids = tonumber(opts.limits.pids) end
  end
  svc.limits = limits
  svc.restart = type(opts.restart) == "table" and opts.restart or nil
  svc.stopping = false
  svc.restart_count = 0

  local command = secret.detokenize(svc.command)
  local unset = runtime.proxy_unset_snippet()
  if unset then command = unset .. "\n" .. command end
  svc.shell_command = command
  svc.env = runtime.sandbox_env(priv) or {}
  -- systemctl 门面等调用方可注入单元 Environment= 变量（覆盖沙箱环境同名项）。
  if type(opts.env) == "table" then
    for k, v in pairs(opts.env) do
      if type(k) == "string" and v ~= nil then svc.env[k] = tostring(v) end
    end
  end
  return _spawn(svc)
end

-- ========== 公开 API ==========

--- 启动一个长驻服务。
--- @param name string 服务名（唯一）
--- @param command string shell 命令
--- @param opts table|nil { cwd?, network?, writable_roots?, limits?, restart?, env?, unit? }
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
    unit = opts.unit,
    logs = {}, log_bytes = 0,
    started_at = os.time(), status = "starting", exit_code = nil,
  }
  local ok, err = _build(svc, opts)
  if not ok then
    if svc.attempt then candidate.cleanup(svc.attempt.attempt_id) end
    if svc.cg then cgroup.release(svc.cg) end
    return nil, err or "服务启动失败"
  end
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
  local restarts = tonumber(svc.restart_count) or 0
  local policy = svc.restart and svc.restart.policy or "no"
  return {
    id = svc.id, name = svc.name, status = svc.status, exit_code = svc.exit_code,
    pid = svc.job, cwd = svc.cwd, started_at = svc.started_at, stopped_at = svc.stopped_at,
    log_bytes = svc.log_bytes, command = svc.command, unit = svc.unit,
    restart_count = restarts, restart_policy = policy,
    start_limit_hit = svc.start_limit_hit == true,
    memory_current = cgroup.current_memory(svc.cg),
  }
end

--- 向服务进程发送信号（systemctl kill 语义）。优先 cgroup 内载荷进程，回退 job PID。
--- @param key string
--- @param sig number|nil 信号编号（默认 15/SIGTERM）
--- @return boolean ok
--- @return string|nil err
function M.signal(key, sig)
  local svc = _find(key)
  if not svc then return false, "服务不存在：" .. tostring(key) end
  sig = tonumber(sig) or 15
  if not svc.exited then svc.signaled = true end
  if svc.cg then
    local ok = cgroup.signal(svc.cg, sig)
    if ok then return true end
  end
  if type(svc.job) == "number" and svc.job > 0 then
    local pid = vim.fn.jobpid(svc.job)
    if pid and pid > 0 then
      local ok = pcall(vim.uv.kill, pid, sig)
      return ok
    end
  end
  return false, "Unit has no processes"
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
--- 优雅停止：先向资源域内进程发 SIGTERM，等待 stop_timeout_ms（`opts.grace_ms` 可覆盖）
--- 让载荷清理退出；到时仍存活才 SIGKILL 整个进程树。进程确认退出后再捕获（确保写入落盘）。
--- @param key string
--- @param cb function|nil cb(err, info)
--- @param opts table|nil { grace_ms? } 优雅退出窗口（ms），默认 tools.sandbox.service.stop_timeout_ms
function M.stop(key, cb, opts)
  cb = cb or function() end
  opts = opts or {}
  local svc = _find(key)
  if not svc then cb("服务不存在：" .. tostring(key)); return end
  svc.stopping = true
  state.services[svc.id] = nil
  for i, id in ipairs(state.order) do
    if id == svc.id then table.remove(state.order, i); break end
  end
  pcall(function()
    require("NeoAI.sandbox.net_consent").unregister_ports(svc.internal_ports)
  end)
  if not svc.exited then svc.status = "stopping" end
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

  --- 强制终止整个进程树（优雅窗口耗尽后的兜底）：优先 cgroup.kill，其次按宿主 PID SIGKILL。
  local function hard_kill()
    if cg then pcall(cgroup.kill, cg) end
    if type(svc.job) == "number" and svc.job > 0 then
      if not cg then
        local pid = vim.fn.jobpid(svc.job)
        if pid and pid > 0 then pcall(vim.uv.kill, pid, 9) end
      end
      pcall(vim.fn.jobstop, svc.job)
    end
  end

  -- 先优雅：只向资源域内的载荷进程发 SIGTERM（`cgroup.term` 会跳过 bwrap 监视进程——
  -- 对 bwrap 发信号会立即销毁命名空间，载荷来不及执行 trap），给载荷 stop_timeout_ms 的
  -- 优雅退出窗口；到时仍存活才 SIGKILL。无资源域时无法只对载荷发信号，直接 jobstop。
  local grace = tonumber(opts.grace_ms) or tonumber(_cfg().stop_timeout_ms) or 5000
  if cg then
    pcall(cgroup.term, cg)
  elseif type(svc.job) == "number" and svc.job > 0 then
    pcall(vim.fn.jobstop, svc.job)
  end

  local deadline = vim.uv.hrtime() + math.max(0, grace) * 1e6
  local function poll()
    if svc.exited then
      finish_capture()
      return
    end
    if vim.uv.hrtime() >= deadline then
      hard_kill()
      -- 给 on_exit 一点时间触发（SIGKILL 立即生效），再捕获，确保写入已落盘。
      vim.defer_fn(function()
        if not svc.exited then
          svc.status = "stopped"
          svc.stopped_at = os.time()
        end
        finish_capture()
      end, 200)
      return
    end
    vim.defer_fn(poll, 50)
  end
  poll()
end

--- 停止全部服务（会话结束 / 卸载 / 关闭）。best-effort，捕获经 vim.wait 有界等待。
--- 优雅停止窗口取 min(stop_timeout_ms, opts.timeout_ms)，避免总等待超出调用方预算。
--- @param opts table|nil { timeout_ms? }
function M.stop_all(opts)
  opts = opts or {}
  local ids = vim.deepcopy(state.order)
  if #ids == 0 then return end
  local total = tonumber(opts.timeout_ms) or 10000
  local grace = tonumber(_cfg().stop_timeout_ms) or 5000
  if total > 0 then grace = math.min(grace, total) end
  local remaining = #ids
  for _, id in ipairs(ids) do
    local svc = state.services[id]
    if not svc then
      remaining = remaining - 1
    else
      M.stop(id, function()
        remaining = remaining - 1
      end, { grace_ms = grace })
    end
  end
  if remaining > 0 then
    vim.wait(total, function() return remaining <= 0 end, 20)
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
    restart_count = tonumber(svc.restart_count) or 0,
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
