--- 后台 worker 进程（headless nvim）
--- @module 'NeoAI.kernel.worker_server'
--- 单一进程、按任务并行：主进程通过 Unix socket + msgpack 帧提交 `utils.work` 任务，
--- 本模块用 `vim.uv.new_work` 在线程池中并行执行，结果回传。worker 内**不加载 NeoAI
--- 插件**、不启动 UI、不做配置引导，避免递归与额外内存。
---
--- 启动方式（由 utils/remote_work 经 posix_spawn 拉起）：
---   nvim --headless --clean -u NONE -n
---        --cmd "set rtp+=<plugin_root>"
---        -l <plugin_root>/lua/NeoAI/kernel/worker_main.lua
--- 环境变量：
---   NEOAI_WORKER_SOCKET        Unix socket 路径
---   NEOAI_WORKER_TOKEN         握手 token
---   NEOAI_WORKER_IDLE_TTL_MS   无客户端时退出延迟
---   UV_THREADPOOL_SIZE         并行槽数量

local M = {}

local uv = vim.uv
local runner = require("NeoAI.utils.worker_runner")

local state = {
  socket = nil,
  token = nil,
  server = nil,
  clients = {}, -- id -> { pipe, buf, ready }
  active = 0,
  seq = 0,
  stopping = false,
  exit_scheduled = false,
  idle_ttl = 5000,
  orphan_timer = nil,
}

local function _log(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  pcall(function() io.stderr:write("[neoai-worker] " .. tostring(msg) .. "\n") end)
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
    payload = vim.mpack.encode({ ok = false, error = "encode failed: " .. tostring(payload) })
  end
  return _u32(#payload) .. payload
end

local function _send(client, msg)
  if not client or not client.pipe or client.closed then return end
  pcall(function() client.pipe:write(_frame(msg)) end)
end

local function _schedule_exit(delay)
  if state.exit_scheduled then return end
  state.exit_scheduled = true
  vim.defer_fn(function()
    state.stopping = true
    pcall(function() if state.server then state.server:close() end end)
    for _, c in pairs(state.clients) do
      if c.pipe then pcall(function() c.pipe:close() end) end
      c.closed = true
    end
    pcall(vim.cmd, "qa!")
  end, math.max(0, tonumber(delay) or 10))
end

local function _maybe_exit_if_empty()
  if state.active > 0 then return end
  if next(state.clients) ~= nil then return end
  -- 客户端已断开：本 worker 是单客户端（socket 含主进程 pid），无需等完整 idle TTL。
  _schedule_exit(math.min(state.idle_ttl, 1000))
end

local function _decode_args(v)
  if type(v) ~= "table" then return {} end
  return v
end

local function _handle_task(client, req)
  local op = req.op
  local code = req.code
  if type(code) ~= "string" or code == "" then
    return _send(client, { id = req.id, ok = false, error = "missing code" })
  end
  if os.getenv("NEOAI_WORKER_DEBUG") == "1" then
    io.stderr:write("[neoai-worker] task start op=" .. tostring(op) .. " id=" .. tostring(req.id) .. "\n")
  end
  state.active = state.active + 1
  local function done(out)
    if os.getenv("NEOAI_WORKER_DEBUG") == "1" then
      io.stderr:write("[neoai-worker] task done id=" .. tostring(req.id) .. " out=" .. tostring(out and #out) .. "\n")
    end
    state.active = math.max(0, state.active - 1)
    if out and out:sub(1, 1) == "\1" then
      _send(client, { id = req.id, ok = true, out = out:sub(2) })
    else
      _send(client, { id = req.id, ok = false, error = (out and out:sub(2)) or "worker exited" })
    end
    if state.stopping and state.active == 0 then _schedule_exit(10) end
  end
  local ok, ctx
  if op == "run_codec" then
    local payload = req.payload
    if type(payload) ~= "string" then
      state.active = state.active - 1
      return _send(client, { id = req.id, ok = false, error = "missing payload" })
    end
    local extras = _decode_args(req.extras)
    ok, ctx = pcall(uv.new_work, runner.CODEC_RUNNER, done)
    if not ok then
      state.active = state.active - 1
      return _send(client, { id = req.id, ok = false, error = "new_work failed: " .. tostring(ctx) })
    end
    local unpackx = table.unpack or unpack
    local queued, err = ctx:queue(code, payload, unpackx(extras, 1, #extras))
    if not queued then
      state.active = state.active - 1
      return _send(client, { id = req.id, ok = false, error = "queue failed: " .. tostring(err) })
    end
  else
    local args = _decode_args(req.args)
    ok, ctx = pcall(uv.new_work, runner.RUNNER, done)
    if not ok then
      state.active = state.active - 1
      return _send(client, { id = req.id, ok = false, error = "new_work failed: " .. tostring(ctx) })
    end
    local unpackx = table.unpack or unpack
    local queued, err = ctx:queue(code, unpackx(args, 1, #args))
    if not queued then
      state.active = state.active - 1
      return _send(client, { id = req.id, ok = false, error = "queue failed: " .. tostring(err) })
    end
  end
end

local function _handle(client, req)
  local op = req.op
  if os.getenv("NEOAI_WORKER_DEBUG") == "1" then
    io.stderr:write("[neoai-worker] handle op=" .. tostring(op) .. " ready=" .. tostring(client.ready)
      .. " keys=" .. table.concat((function() local k = {}; for x in pairs(req) do k[#k + 1] = tostring(x) end; return k end)(), ",") .. "\n")
  end
  if op == "handshake" then
    if req.token ~= state.token then
      _send(client, { id = req.id, ok = false, error = "bad token" })
      pcall(function() client.pipe:close() end)
      return
    end
    client.ready = true
    _send(client, { id = req.id, ok = true, data = { pid = uv.os_getpid(), active = state.active } })
    return
  end
  if op == "ping" then
    return _send(client, { id = req.id, ok = true, data = { pid = uv.os_getpid(), active = state.active } })
  end
  if op == "stats" then
    return _send(client, { id = req.id, ok = true, data = {
      pid = uv.os_getpid(), active = state.active, clients = vim.tbl_count(state.clients),
      threads = tonumber(os.getenv("UV_THREADPOOL_SIZE")) or nil,
    } })
  end
  if op == "shutdown" then
    _send(client, { id = req.id, ok = true, data = { stopping = true } })
    state.stopping = true
    if state.active == 0 then _schedule_exit(20) end
    return
  end
  if op == "shutdown_if_idle" then
    local idle = state.active == 0
    _send(client, { id = req.id, ok = true, data = { idle = idle } })
    if idle then state.stopping = true; _schedule_exit(20) end
    return
  end
  if not client.ready then
    return _send(client, { id = req.id, ok = false, error = "handshake required" })
  end
  if op == "run" or op == "run_codec" then
    return _handle_task(client, req)
  end
  _send(client, { id = req.id, ok = false, error = "unknown op: " .. tostring(op) })
end

local function _parse(client, data)
  client.buf = client.buf .. data
  while true do
    if #client.buf < 4 then return end
    local b1, b2, b3, b4 = client.buf:byte(1, 4)
    local len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    if os.getenv("NEOAI_WORKER_DEBUG") == "1" then
      io.stderr:write("[neoai-worker] parse have=" .. tostring(#client.buf)
        .. " want=" .. tostring(4 + len) .. "\n")
    end
    if #client.buf < 4 + len then return end
    local payload = client.buf:sub(5, 4 + len)
    client.buf = client.buf:sub(5 + len)
    local ok, req = pcall(vim.mpack.decode, payload)
    if ok and type(req) == "table" then
      local hok, herr = pcall(_handle, client, req)
      if not hok then
        _log("handle error: %s", tostring(herr))
        _send(client, { id = req.id, ok = false, error = "handle error: " .. tostring(herr) })
      end
    else
      _log("decode error: %s", tostring(req))
    end
  end
end

local function _on_client(pipe)
  if state.orphan_timer then
    pcall(function() state.orphan_timer:stop() end)
    pcall(function() state.orphan_timer:close() end)
    state.orphan_timer = nil
  end
  state.seq = state.seq + 1
  local id = state.seq
  local client = { id = id, pipe = pipe, buf = "", ready = false, closed = false }
  state.clients[id] = client
  pipe:read_start(function(err, data)
    if err or not data then
      client.closed = true
      state.clients[id] = nil
      pcall(function() pipe:close() end)
      _maybe_exit_if_empty()
      return
    end
    if data ~= "" then
      if os.getenv("NEOAI_WORKER_DEBUG") == "1" then
        io.stderr:write("[neoai-worker] read " .. tostring(#data) .. " bytes\n")
      end
      _parse(client, data)
    end
  end)
end

--- 启动 server（阻塞至进程退出）
--- @return number exit_code
function M.main()
  vim.g.neoai_worker_server = true
  state.socket = vim.env.NEOAI_WORKER_SOCKET
  state.token = vim.env.NEOAI_WORKER_TOKEN
  state.idle_ttl = tonumber(vim.env.NEOAI_WORKER_IDLE_TTL_MS) or 5000
  if not state.socket or state.socket == "" then
    _log("missing NEOAI_WORKER_SOCKET")
    return 2
  end
  local dir = vim.fn.fnamemodify(state.socket, ":h")
  pcall(vim.fn.mkdir, dir, "p")
  pcall(uv.fs_unlink, state.socket)
  local server = uv.new_pipe(false)
  if not server then
    _log("new_pipe failed")
    return 2
  end
  state.server = server
  local ok, err = pcall(function()
    server:bind(state.socket)
  end)
  if not ok then
    _log("bind failed: %s", tostring(err))
    return 2
  end
  pcall(uv.fs_chmod, state.socket, 384) -- 0600
  server:listen(128, function(cerr)
    if cerr then
      _log("listen error: %s", tostring(cerr))
      return
    end
    local pipe = uv.new_pipe(false)
    if not pipe then return end
    server:accept(pipe)
    _on_client(pipe)
  end)
  -- 孤儿兜底：主进程在 spawn 后崩溃/被 kill 时可能来不及 connect；没有客户端且没有任务的
  -- worker 不能永久驻留。正常启动会很快连接，届时取消该定时器。
  local ot = uv.new_timer()
  state.orphan_timer = ot
  ot:start(15000, 0, function()
    state.orphan_timer = nil
    pcall(function() ot:close() end)
    if next(state.clients) == nil and state.active == 0 then
      _log("no client connected; worker exiting")
      _schedule_exit(10)
    end
  end)
  _log("ready pid=%d socket=%s", uv.os_getpid(), state.socket)
  -- 处理事件直到 _schedule_exit 调用 qa!。使用有限超时循环，避免不同 Neovim 版本对
  -- `vim.wait(-1)` 的处理差异导致进程立即退出。
  while true do
    vim.wait(1000, function() return false end, 50)
  end
end

return M
