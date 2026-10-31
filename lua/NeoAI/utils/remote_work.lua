--- 远程工作池客户端（单 worker 进程 + 并行任务槽）
--- @module 'NeoAI.utils.remote_work'
--- 主进程只保留事件循环与 UI；纯 Lua 工作函数经 Unix socket + msgpack 帧提交给后台
--- worker（headless nvim，`posix_spawn` 启动），worker 内用 `vim.uv.new_work` 并行执行。
---
--- 生命周期：
---   absent → starting（首次任务）→ ready → busy → ready
---   ready/busy → idle_ttl → draining → absent
---   crash → 有排队/在途任务才按退避重启，否则保持 absent
---
--- 单实例：socket 路径包含主 nvim pid，同一主进程最多一个 worker；不会按任务多开。
--- 主进程 `pin()`（如审批窗口打开）期间不空闲回收。

local async = require("NeoAI.utils.async")
local uv = vim.uv

local M = {}

local state = {
  pipe = nil,
  connecting_pipe = nil,
  connected = false,
  starting = nil, -- Deferred
  starting_timer = nil,
  connect_timer = nil,
  spawn_pid = nil,
  reaper = nil,
  seq = 0,
  pending = {}, -- id -> { d, timer, sent_at, kind }
  queue = {}, -- { id, req, d, kind, bytes }
  buf = "",
  last_used = 0,
  pins = {},
  idle_timer = nil,
  stopped = false,
  restarts = 0,
  spawn_log = nil,
  token = nil,
  socket = nil,
}

local DEFAULTS = {
  enabled = true,
  mode = "on_demand",
  offload = "all",
  min_bytes = 0,
  max_concurrency = 4,
  idle_ttl_ms = 60000,
  startup_timeout_ms = 5000,
  request_timeout_ms = 120000,
  max_restarts = 3,
  restart_backoff_ms = { 200, 1000, 3000 },
  max_pending = 64,
  log_max_bytes = 1024 * 1024,
}

local function _plugin_root()
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    return vim.fn.fnamemodify(src:sub(2), ":p:h:h:h:h")
  end
  return vim.fn.getcwd()
end

local function _cache_dir()
  local base = vim.fn.stdpath("cache") .. "/NeoAI"
  pcall(vim.fn.mkdir, base, "p")
  return base
end

local function _cfg()
  local out = {}
  for k, v in pairs(DEFAULTS) do out[k] = v end
  local ok, cs = pcall(require, "NeoAI.kernel.config_store")
  if ok and type(cs.get) == "function" then
    local ok2, v = pcall(cs.get, "tools.worker")
    if ok2 and type(v) == "table" then
      for k, val in pairs(v) do out[k] = val end
    end
  end
  -- 测试/诊断覆盖（不写入用户配置）。
  local ttl = tonumber(os.getenv("NEOAI_WORKER_IDLE_TTL_MS"))
  if ttl then out.idle_ttl_ms = ttl end
  local conc = tonumber(os.getenv("NEOAI_WORKER_CONCURRENCY"))
  if conc then out.max_concurrency = conc end
  return out
end

local _debug = os.getenv("NEOAI_WORKER_DEBUG") == "1"

local function _log(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  if _debug then
    pcall(function() io.stderr:write("[neoai-worker-client] " .. tostring(msg) .. "\n") end)
  end
  -- 可能在 libuv fast event 回调中调用：logger 必须回到主循环。
  vim.schedule(function()
    pcall(function()
      require("NeoAI.kernel.logger").debug("[worker] " .. tostring(msg))
    end)
  end)
end

--- 从 fast event 回调切回主循环执行（配置读取、事件、Deferred 回调都只能在主循环）。
local function _defer(fn)
  vim.schedule(fn)
end

local function _u32(n)
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256
  )
end

local function _frame(msg)
  local ok, payload = pcall(vim.mpack.encode, msg)
  if not ok then
    _log("frame encode failed: %s", tostring(payload))
    if _debug and type(msg) == "table" then
      for k, v in pairs(msg) do
        local ok1, e1 = pcall(vim.mpack.encode, { v = v })
        if not ok1 then
          _log("  field %s type=%s serialize err=%s", tostring(k), type(v), tostring(e1))
        end
      end
    end
    payload = vim.mpack.encode({ ok = false, error = "encode failed: " .. tostring(payload) })
  end
  return _u32(#payload) .. payload
end

local function _write(msg)
  if not state.pipe or not state.connected then return false end
  local ok, res = pcall(function()
    return state.pipe:write(_frame(msg))
  end)
  if _debug then
    pcall(function()
      io.stderr:write("[neoai-worker-client] write op=" .. tostring(msg.op or msg.id)
        .. " ok=" .. tostring(ok) .. " res=" .. tostring(res) .. "\n")
    end)
  end
  return ok and res ~= nil
end

local function _close_timer(t)
  if not t then return end
  pcall(function() t:stop() end)
  pcall(function() t:close() end)
end

local function _clear_idle()
  _close_timer(state.idle_timer)
  state.idle_timer = nil
end

local function _note_used()
  state.last_used = uv.hrtime()
  _clear_idle()
end

local function _has_pins()
  return next(state.pins) ~= nil
end

local function _reject_pending(err)
  for id, p in pairs(state.pending) do
    state.pending[id] = nil
    _close_timer(p.timer)
    pcall(function() p.d:reject(err) end)
  end
end

local function _reject_all(err)
  _reject_pending(err)
  local q = state.queue
  state.queue = {}
  for _, item in ipairs(q) do
    pcall(function() item.d:reject(err) end)
  end
end

-- 前向声明（send/flush 互相引用）
local _send_request, _submit

local function _schedule_idle()
  if state.stopped or not state.connected then return end
  if next(state.pending) ~= nil or next(state.queue) ~= nil or _has_pins() then return end
  _clear_idle()
  local cfg = _cfg()
  local ttl = tonumber(cfg.idle_ttl_ms) or 60000
  if ttl <= 0 then return end
  local timer = uv.new_timer()
  state.idle_timer = timer
  timer:start(ttl, 0, function()
    _defer(function()
      state.idle_timer = nil
      _close_timer(timer)
      if state.stopped or not state.connected then return end
      if next(state.pending) ~= nil or next(state.queue) ~= nil or _has_pins() then return end
      pcall(function()
        _write({ id = "idle-" .. tostring(state.seq), op = "shutdown_if_idle" })
      end)
      _log("idle ttl reached; requesting worker shutdown")
    end)
  end)
end

local function _retry_restart()
  if state.stopped then return end
  local cfg = _cfg()
  if state.restarts >= (tonumber(cfg.max_restarts) or 3) then
    _reject_all({ kind = "worker", message = "worker 重启次数超过上限" })
    return
  end
  state.restarts = state.restarts + 1
  local delays = cfg.restart_backoff_ms or DEFAULTS.restart_backoff_ms
  local delay = tonumber(delays[math.min(state.restarts, #delays)]) or 500
  _log("restart worker in %dms (attempt %d)", delay, state.restarts)
  vim.defer_fn(function()
    if state.stopped then return end
    if state.connected or state.starting then return end
    M.ensure_started():then_(function()
      state.restarts = 0
    end, function(err)
      _reject_all(err)
    end)
  end, delay)
end

local function _handle_response(msg)
  if type(msg) ~= "table" then return end
  local id = msg.id
  local p = id and state.pending[id]
  if not p then return end
  state.pending[id] = nil
  _close_timer(p.timer)
  if msg.ok then
    if type(p.kind) == "table" and p.kind.kind == "run_codec" then
      local ok, decoded = pcall(vim.mpack.decode, msg.out or "")
      if ok then
        if decoded == vim.NIL then decoded = nil end
        pcall(function() p.d:resolve(decoded) end)
      else
        pcall(function() p.d:reject({ kind = "work", message = "worker 返回解码失败: " .. tostring(decoded) }) end)
      end
    else
      pcall(function() p.d:resolve(msg.out) end)
    end
  else
    pcall(function() p.d:reject({ kind = "worker", message = tostring(msg.error or "worker error") }) end)
  end
  _note_used()
  _schedule_idle()
end

local function _parse(data)
  state.buf = state.buf .. data
  while true do
    if #state.buf < 4 then return end
    local b1, b2, b3, b4 = state.buf:byte(1, 4)
    local len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    if #state.buf < 4 + len then return end
    local payload = state.buf:sub(5, 4 + len)
    state.buf = state.buf:sub(5 + len)
    local ok, msg = pcall(vim.mpack.decode, payload)
    if ok and type(msg) == "table" then _handle_response(msg) end
  end
end

local function _on_disconnect(reason)
  local was = state.connected
  state.connected = false
  if state.pipe then
    pcall(function() state.pipe:close() end)
    state.pipe = nil
  end
  if state.connecting_pipe then
    pcall(function() state.connecting_pipe:close() end)
    state.connecting_pipe = nil
  end
  -- 连接断开后旧进程不可复用：清空 pid 与 reaper，必要时终止仍存活的旧 worker，
  -- 让下一次 ensure_started 重新 spawn（避免反复连接已失效的 socket）。
  if state.spawn_pid then
    local old = state.spawn_pid
    state.spawn_pid = nil
    if state.reaper then
      _close_timer(state.reaper)
      state.reaper = nil
    end
    local ps = require("NeoAI.utils.posix_spawn")
    local r = ps.reap(old)
    if not r and ps.alive(old) then pcall(ps.kill, old, 15) end
  end
  state.buf = ""
  _clear_idle()
  if was then _log("worker disconnected: %s", tostring(reason or "eof")) end
  -- 已发送的任务可能已在 worker 内执行：直接 reject，绝不自动重跑（避免重复写盘）。
  -- 尚未发送的排队任务保留，稍后由新 worker 处理。
  _reject_pending({ kind = "worker", message = "worker 已断开: " .. tostring(reason or "eof") })
  if state.stopped then return end
  if #state.queue > 0 or _has_pins() then
    _retry_restart()
  end
end

local function _handshake()
  state.seq = state.seq + 1
  local id = "hs-" .. tostring(state.seq)
  local d = async.Deferred.new()
  state.pending[id] = {
    d = d,
    kind = "handshake",
    timer = nil,
  }
  _write({ id = id, op = "handshake", token = state.token, pid = uv.os_getpid() })
  return d
end

local function _flush_queue()
  if not state.connected then return end
  local q = state.queue
  state.queue = {}
  for _, item in ipairs(q) do
    _send_request(item.req, item.d, item.kind, item.bytes)
  end
end

local function _on_connected()
  state.connected = true
  state.restarts = 0
  state.buf = ""
  state.pipe:read_start(function(err, data)
    if err or not data then
      _defer(function() _on_disconnect(err or "eof") end)
      return
    end
    if data ~= "" then _defer(function() _parse(data) end) end
  end)
  _handshake():then_(function()
    _log("worker ready pid=%s", tostring(state.spawn_pid))
    local starting = state.starting
    state.starting = nil
    if starting then pcall(function() starting:resolve(true) end) end
    _flush_queue()
    _schedule_idle()
  end, function(err)
    _log("handshake failed: %s", tostring(err and err.message or err))
    _on_disconnect("handshake failed")
  end)
end

local function _try_connect()
  _log("try connect socket=%s stopped=%s connected=%s", tostring(state.socket),
    tostring(state.stopped), tostring(state.connected))
  if state.stopped or state.connected then return end
  local pipe = uv.new_pipe(false)
  if not pipe then _log("new_pipe failed"); return end
  -- 必须持有强引用：luv 的 handle 在 Lua GC 后可能被关闭，connect 回调永远不会触发。
  state.connecting_pipe = pipe
  local done = false
  local function retry(err)
    if state.connecting_pipe == pipe then state.connecting_pipe = nil end
    pcall(function() pipe:close() end)
    if state.stopped or state.connected then return end
    _log("connect retry: %s", tostring(err))
    if _debug then pcall(function() io.stderr:write("[neoai-worker-client] retry timer\n") end) end
    local timer = uv.new_timer()
    timer:start(80, 0, function()
      if _debug then pcall(function() io.stderr:write("[neoai-worker-client] retry tick\n") end) end
      _defer(function()
        _close_timer(timer)
        _try_connect()
      end)
    end)
  end
  local cok, cerr = pcall(function()
    pipe:connect(state.socket, function(err)
      _defer(function()
        _log("connect callback err=%s", tostring(err))
        if done then return end
        done = true
        if err then
          pcall(function() pipe:close() end)
          return retry(err)
        end
        if state.connecting_pipe == pipe then state.connecting_pipe = nil end
        state.pipe = pipe
        _on_connected()
      end)
    end)
  end)
  if not cok then
    _log("pipe connect throw: %s", tostring(cerr))
    done = true
    retry(cerr)
  end
end

local function _spawn()
  local cfg = _cfg()
  local ps = require("NeoAI.utils.posix_spawn")
  if not ps.available() then
    return nil, ps._error or "posix_spawn 不可用"
  end
  local root = _plugin_root()
  local cache = _cache_dir()
  local pid = uv.os_getpid()
  state.socket = string.format("%s/worker-%d.sock", cache, pid)
  -- Unix socket 路径长度上限约 108 字节；缓存目录很深时退回 /tmp（权限仍为 0600）。
  if #state.socket > 100 then
    local uid = (type(uv.getuid) == "function" and tostring(uv.getuid())) or "u"
    state.socket = string.format("/tmp/neoai-worker-%s-%d.sock", uid, pid)
  end
  state.token = tostring(vim.fn.sha256(tostring(pid) .. ":" .. tostring(uv.hrtime())))
  state.spawn_log = string.format("%s/worker-%d.log", cache, pid)
  pcall(uv.fs_unlink, state.socket)
  pcall(uv.fs_unlink, state.spawn_log)
  local nvim = vim.v.progpath
  if type(nvim) ~= "string" or nvim == "" then
    nvim = vim.fn.exepath("nvim")
  end
  if type(nvim) ~= "string" or nvim == "" then
    return nil, "找不到 nvim 可执行文件"
  end
  local threads = math.max(1, math.min(16, tonumber(cfg.max_concurrency) or 4))
  local argv = {
    nvim, "--headless", "--clean", "-u", "NONE", "-n",
    "-l", root .. "/lua/NeoAI/kernel/worker_main.lua",
  }
  local env = {
    NEOAI_PLUGIN_ROOT = root,
    NEOAI_WORKER_SOCKET = state.socket,
    NEOAI_WORKER_TOKEN = state.token,
    NEOAI_WORKER_PARENT = tostring(pid),
    NEOAI_WORKER_IDLE_TTL_MS = tostring(tonumber(cfg.idle_ttl_ms) or 60000),
    UV_THREADPOOL_SIZE = tostring(threads),
    NEOAI_WORKER_DEBUG = _debug and "1" or nil,
  }
  local spid, err = ps.spawn(argv, {
    env = env,
    stdout = state.spawn_log,
    stderr = state.spawn_log,
  })
  if not spid then return nil, err end
  state.spawn_pid = spid
  _log("spawned worker pid=%s socket=%s log=%s", tostring(spid), state.socket, state.spawn_log)
  -- 非阻塞回收 + 崩溃探测。
  if state.reaper then _close_timer(state.reaper) end
  local reaper = uv.new_timer()
  state.reaper = reaper
  reaper:start(500, 500, function()
    _defer(function()
      if not state.spawn_pid then
        _close_timer(reaper)
        state.reaper = nil
        return
      end
      local r = ps.reap(state.spawn_pid)
      if r then
        _close_timer(reaper)
        state.reaper = nil
        _log("worker exited code=%s signal=%s", tostring(r.code), tostring(r.signal))
        state.spawn_pid = nil
        _on_disconnect("worker exited")
      end
    end)
  end)
  return spid
end

local function _starting_deferred()
  if state.starting then return state.starting end
  local d = async.Deferred.new()
  state.starting = d
  local cfg = _cfg()
  local timeout = tonumber(cfg.startup_timeout_ms) or 5000
  local timer = uv.new_timer()
  state.starting_timer = timer
  timer:start(timeout, 0, function()
    _defer(function()
      _close_timer(timer)
      if state.starting == d then
        state.starting = nil
        pcall(function() d:reject({ kind = "worker", message = "worker 启动超时" }) end)
      end
    end)
  end)
  return d
end

--- 确保 worker 已就绪（单飞）。返回 Deferred。
--- @return Deferred
function M.ensure_started()
  if state.stopped then
    return async.reject({ kind = "worker", message = "worker 已停止" })
  end
  if state.connected then return async.resolve(true) end
  -- worker 已退出但 reaper 尚未回调：不要用旧 pid 无限重连。清掉后按需重新 spawn。
  if state.spawn_pid ~= nil then
    local ps = require("NeoAI.utils.posix_spawn")
    if not ps.alive(state.spawn_pid) then
      _log("stale worker pid=%s; respawn", tostring(state.spawn_pid))
      state.spawn_pid = nil
      if state.reaper then
        _close_timer(state.reaper)
        state.reaper = nil
      end
    end
  end
  local d = _starting_deferred()
  if state.spawn_pid == nil then
    local spid, err = _spawn()
    if not spid then
      state.starting = nil
      _close_timer(state.starting_timer)
      state.starting_timer = nil
      return async.reject({ kind = "worker", message = tostring(err) })
    end
  end
  _try_connect()
  return d
end

--- 是否启用远程工作池。
--- @return boolean
function M.enabled()
  -- fast event 上下文不能读 vim.g / 配置 / spawn；退化为本地线程池。
  if vim.in_fast_event and vim.in_fast_event() then return false end
  if vim.g.neoai_worker_server then return false end
  if vim.env.NEOAI_WORKER == "0" then return false end
  if vim.g.neoai_test and vim.env.NEOAI_TEST_WORKER ~= "1" then return false end
  local cfg = _cfg()
  if cfg.enabled == false then return false end
  if cfg.mode == "off" then return false end
  return true
end

--- 是否值得/需要卸载到 worker。
--- @param bytes number|nil 输入规模
--- @return boolean
function M.should_offload(bytes)
  if not M.enabled() then return false end
  -- posix_spawn 不可用（非 Linux/LuaJIT FFI 受限）时回退本地线程池，避免插件整体不可用。
  local ok_ps, ps = pcall(require, "NeoAI.utils.posix_spawn")
  if not ok_ps or not ps.available then return false end
  local ok_av, av = pcall(ps.available)
  if not ok_av or not av then return false end
  local cfg = _cfg()
  if cfg.offload == "large" then
    return (tonumber(bytes) or 0) >= (tonumber(cfg.min_bytes) or 0)
  end
  return true
end

--- 提交一个 `work.run` 任务。
--- @param code string string.dump 字节码
--- @param args table 原始类型参数数组
--- @param opts table|nil { kind?, bytes?, timeout_ms? }
--- @return Deferred
function M.run(code, args, opts)
  opts = opts or {}
  local cfg = _cfg()
  local req = {
    id = "t-" .. tostring(uv.hrtime()) .. "-" .. tostring(math.random(1, 1e9)),
    op = "run",
    code = code,
    args = args or {},
  }
  return _submit(req, opts)
end

--- 提交一个 `work.run_codec` 任务。
--- @param code string
--- @param payload string mpack 编码输入
--- @param extras table|nil
--- @param opts table|nil
--- @return Deferred
function M.run_codec(code, payload, extras, opts)
  opts = opts or {}
  local req = {
    id = "t-" .. tostring(uv.hrtime()) .. "-" .. tostring(math.random(1, 1e9)),
    op = "run_codec",
    code = code,
    payload = payload,
    extras = extras or {},
  }
  return _submit(req, opts)
end

_send_request = function(req, d, kind, bytes)
  if state.stopped then
    return pcall(function() d:reject({ kind = "worker", not_started = true, message = "worker 已停止" }) end)
  end
  if not state.connected then
    state.queue[#state.queue + 1] = { req = req, d = d, kind = kind, bytes = bytes }
    M.ensure_started()
    return
  end
  local cfg = _cfg()
  local timeout = tonumber((kind and kind.timeout_ms) or cfg.request_timeout_ms) or 120000
  local timer = uv.new_timer()
  state.pending[req.id] = { d = d, timer = timer, kind = kind, bytes = bytes }
  timer:start(timeout, 0, function()
    _defer(function()
      _close_timer(timer)
      local p = state.pending[req.id]
      if p then
        state.pending[req.id] = nil
        pcall(function()
          p.d:reject({ kind = "worker", message = "worker 请求超时: " .. tostring(req.op) })
        end)
      end
    end)
  end)
  if not _write(req) then
    state.pending[req.id] = nil
    _close_timer(timer)
    pcall(function() d:reject({ kind = "worker", message = "worker 写入失败" }) end)
  end
  _note_used()
end

_submit = function(req, opts)
  local d = async.Deferred.new()
  local cfg = _cfg()
  if #state.queue >= (tonumber(cfg.max_pending) or 64) and not state.connected then
    return async.reject({ kind = "worker", not_started = true, message = "worker 队列已满" })
  end
  _send_request(req, d, opts, opts.bytes)
  return d
end

--- 保持 worker 存活（审批窗口打开 / 批量应用）。
--- @param reason string
function M.pin(reason)
  state.pins[reason or "default"] = true
  _clear_idle()
end

--- 解除 pin。
--- @param reason string
function M.unpin(reason)
  state.pins[reason or "default"] = nil
  _schedule_idle()
end

--- 主动停止（测试 / 插件关闭）。best-effort，不阻塞主线程。
--- @param timeout_ms number|nil
function M.stop(timeout_ms)
  state.stopped = true
  _clear_idle()
  _close_timer(state.starting_timer)
  state.starting_timer = nil
  if state.starting then
    pcall(function() state.starting:reject({ kind = "worker", message = "worker stopped" }) end)
    state.starting = nil
  end
  _reject_all({ kind = "worker", message = "worker stopped" })
  if state.connected then
    pcall(function() _write({ id = "stop", op = "shutdown" }) end)
  end
  local pid = state.spawn_pid
  state.spawn_pid = nil
  if state.pipe then pcall(function() state.pipe:close() end) end
  state.pipe = nil
  if state.connecting_pipe then
    pcall(function() state.connecting_pipe:close() end)
    state.connecting_pipe = nil
  end
  if state.reaper then
    _close_timer(state.reaper)
    state.reaper = nil
  end
  state.connected = false
  if pid then
    local ps = require("NeoAI.utils.posix_spawn")
    vim.defer_fn(function()
      local r = ps.reap(pid)
      if not r then
        ps.kill(pid, 15)
        vim.defer_fn(function()
          local r2 = ps.reap(pid)
          if not r2 then ps.kill(pid, 9) end
        end, math.max(200, tonumber(timeout_ms) or 1000))
      end
    end, math.max(100, math.floor((tonumber(timeout_ms) or 1000) / 2)))
  end
end

--- 重启（诊断命令）。
function M.restart()
  M.stop(500)
  state.stopped = false
  state.restarts = 0
  return M.ensure_started()
end

--- worker 状态（诊断）。
--- @return table
function M.status()
  return {
    enabled = M.enabled(),
    connected = state.connected,
    starting = state.starting ~= nil,
    pid = state.spawn_pid,
    pending = vim.tbl_count(state.pending),
    queued = #state.queue,
    socket = state.socket,
    log = state.spawn_log,
    pinned = next(state.pins) ~= nil,
    stopped = state.stopped,
  }
end

--- 测试/重置。
function M.reset()
  M.stop(200)
  state.stopped = false
  state.restarts = 0
  state.queue = {}
  state.pending = {}
  state.pins = {}
  state.buf = ""
  state.socket = nil
  state.token = nil
  state.spawn_log = nil
  state.last_used = 0
end

return M
