--- 会话内 Docker API 代理（自研 Unix socket + body 检查）
--- @module 'NeoAI.sandbox.docker.broker'
---
--- 宿主侧可信进程内的 Unix socket 代理：
---   Agent ── /run/docker.sock ──> broker ── runtime.sock ──> 会话内 rootless runtime
---
--- 关键点：
---   * 上游 socket 由会话内 runtime 创建，宿主通过 bind mount 的 socket 目录访问；
---     Agent 只看到 broker socket（权限隔离，默认 agent 为非 root uid）。
---   * 不转发客户端原始字节：解析 → 策略/改写 → 重新编码 → 上游。
---   * 每个客户端请求一条上游连接（Connection: close）；logs/stats/attach 支持流式。
---   * 容器 id 操作先 inspect + 安全审查；blocked/sensitive/未批准按操作矩阵拒绝。
---
--- 生命周期由 `services.sandbox` 的 shutdown 调 `M.stop()`；惰性 `ensure()`。

local uv = vim.uv or vim.loop
local async = require("NeoAI.utils.async")
local events = require("NeoAI.kernel.events")
local http = require("NeoAI.sandbox.docker.http")
local policy = require("NeoAI.sandbox.docker.policy")
local probe = require("NeoAI.sandbox.docker.probe")
local review = require("NeoAI.sandbox.docker.review")

local M = {}

local state = {
  server = nil,
  socket_path = nil,
  upstream_path = nil,
  opts = {},
  clients = {},
  running = false,
  stats = { requests = 0, allowed = 0, denied = 0, errors = 0 },
  upstream_override = nil, -- 测试：function(req, cb)
  monitor_timer = nil,
  monitor_states = {},
}

-- ========== 私有函数 ==========

local function _emit(name, payload)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(name, payload or {})
  end)
end

local function _log(level, fmt, ...)
  local args = { ... }
  local n = select("#", ...)
  pcall(function()
    local logger = require("NeoAI.kernel.logger")
    logger[level]("[docker:broker] " .. tostring(fmt), unpack(args, 1, n))
  end)
end

--- 关闭并清理一个 socket/pipe。
local function _close(pipe)
  if not pipe then return end
  pcall(function() pipe:read_stop() end)
  pcall(function() pipe:close() end)
end

--- 发送响应并关闭客户端。
local function _respond(client, raw)
  if not client then return end
  local ok = pcall(function()
    client:write(raw, function()
      _close(client)
    end)
  end)
  if not ok then _close(client) end
end

--- 构造上游请求路径（保留原 path；版本前缀原样）。
local function _upstream_path(req)
  return req.path
end

-- ========== 上游 inspect / 审查 ==========

--- 读取上游完整 HTTP 响应（上限 8MB）。
--- @param upstream_path string
--- @param req table
--- @param cb fun(ok: boolean, status: number|nil, body: string|nil, raw: string|nil)
local function _upstream_call(upstream_path, req, cb)
  if state.upstream_override then
    return state.upstream_override(req, cb)
  end
  local pipe = uv.new_pipe(false)
  if not pipe then return cb(false, nil, nil, nil) end
  local buf = ""
  local done = false
  local function finish(ok, status, body, raw)
    if done then return end
    done = true
    _close(pipe)
    cb(ok, status, body, raw)
  end
  local okc = pcall(function()
    pipe:connect(upstream_path, function(err)
      if err then return finish(false) end
      local raw = http.encode_request(req)
      pcall(function() pipe:write(raw) end)
    end)
  end)
  if not okc then return finish(false) end
  pipe:read_start(function(err, data)
    if err then return finish(false) end
    if data then
      buf = buf .. data
      if #buf > 8 * 1024 * 1024 then return finish(false) end
      return
    end
    -- EOF：解析响应头/body（简单 status/body），供审查使用。
    local header_end = buf:find("\r\n\r\n", 1, true)
    if not header_end then return finish(false) end
    local head = buf:sub(1, header_end - 1)
    local status = tonumber(head:match("^HTTP/%d+%.%d+%s+(%d+)"))
    local body = buf:sub(header_end + 4)
    finish(true, status, body, buf)
  end)
end

--- inspect 一个容器并审查。
--- @param id string
--- @param ctx table
--- @param cb fun(ok: boolean, verdict: table|nil, insp: table|nil, reason: string|nil)
local function _review_container(id, ctx, cb)
  local req = {
    method = "GET",
    path = "/containers/" .. id .. "/json",
    headers = { ["content-type"] = "application/json" },
    body = "",
  }
  _upstream_call(state.upstream_path, req, function(ok, status, body)
    if not ok or status ~= 200 or not body then
      return cb(false, nil, nil, "NO_SUCH_CONTAINER")
    end
    local decoded, derr = http.decode_json(body)
    if not decoded then return cb(false, nil, nil, derr) end
    local verdict = review.evaluate(decoded, {
      workspace_roots = ctx.workspace_roots,
      session_netns = ctx.session_netns,
    })
    cb(true, verdict, decoded, nil)
  end)
end

-- ========== 请求处理 ==========

--- 判定 endpoint 对应的操作类别。
local function _op_for(info, method)
  local seg = info.segments
  if seg[1] == "containers" and #seg == 3 and method == "GET" then return "inspect" end
  if seg[1] == "containers" and #seg == 3 and method == "DELETE" then return "destructive" end
  if seg[1] == "containers" and #seg == 4 then
    local action = seg[4]
    if action == "logs" then return "logs" end
    if action == "stats" then return "observe" end
    if action == "attach" then return "logs" end
    if action == "exec" then return "exec" end
    if action == "kill" then return "destructive" end
    if action == "start" or action == "stop" or action == "restart" or action == "wait" or action == "resize" then
      return "lifecycle"
    end
  end
  if seg[1] == "exec" then return "exec" end
  return "other"
end

--- 流式 endpoint（读到哪里写到哪里）。
local function _is_stream(info)
  local seg = info.segments
  if seg[1] == "containers" and #seg == 4 then
    local action = seg[4]
    if action == "logs" or action == "stats" or action == "attach" or action == "wait" then return true end
  end
  if seg[1] == "images" and #seg == 2 and seg[2] == "create" then return true end
  return false
end

--- 是否 attach（hijack）。
local function _is_attach(info)
  return info.segments[1] == "containers" and info.segments[4] == "attach"
end

--- 记录容器重建规格（create/start 成功后）。
local function _capture_spec(id, ctx)
  if type(id) ~= "string" or id == "" then return end
  _review_container(id, ctx, function(ok, _verdict, insp)
    if not ok or not insp then return end
    local oks, specs = pcall(require, "NeoAI.sandbox.docker.specs")
    if not oks or not specs then return end
    local spec = specs.capture(insp, {
      workspace_roots = ctx.workspace_roots,
      session = ctx.labels and ctx.labels["neoai.sandbox.session"] or nil,
      agent = ctx.labels and ctx.labels["neoai.sandbox.agent"] or nil,
      owner = ctx.labels and ctx.labels["neoai.sandbox.owner"] or nil,
      was_running = insp.State and insp.State.Running == true,
    })
    if spec then
      _emit(events.SANDBOX_DOCKER_REBUILD_CAPTURED, {
        spec_id = spec.spec_id, mode = spec.mode, name = spec.name, reasons = spec.review_reasons,
      })
    end
  end)
end

--- 简单响应完成后：create/start 捕获重建规格。
local function _after_response(req, info, ctx, raw)
  local seg = info.segments
  if seg[1] ~= "containers" then return end
  if #seg == 2 and seg[2] == "create" then
    local he = raw:find("\r\n\r\n", 1, true)
    if not he then return end
    local body = raw:sub(he + 4)
    local obj = http.decode_json(body)
    if obj and obj.Id then _capture_spec(obj.Id, ctx) end
    return
  end
  if #seg == 4 and seg[3] == "start" then
    _capture_spec(seg[2], ctx)
  end
end

--- 转发到上游（简单响应：收齐后写给客户端；流式：边读边写）。
local function _forward(client, req, info, ctx, cb)
  if state.upstream_override then
    state.upstream_override(req, function(ok, status, body, raw)
      if raw then _respond(client, raw)
      elseif ok then _respond(client, http.json_response(status or 200, { body = body or "" }))
      else _respond(client, http.error_response(502, "upstream error")) end
      cb(ok)
    end)
    return
  end

  local up = uv.new_pipe(false)
  if not up then
    _respond(client, http.error_response(500, "upstream unavailable"))
    return cb(false)
  end
  local stream = _is_stream(info)
  local attach = _is_attach(info)
  local connected = false
  local simple_buf = ""

  local function fail(msg)
    if not connected then
      _respond(client, http.error_response(502, msg or "upstream error"))
    else
      _close(client)
      _close(up)
    end
    cb(false)
  end

  local okc = pcall(function()
    up:connect(state.upstream_path, function(err)
      if err then return fail(tostring(err)) end
      connected = true
      local encoded
      if attach then
        encoded = http.encode_request(req, { keep_upgrade = true })
      else
        encoded = http.encode_request(req, { drop_headers = { ["x-registry-auth"] = true } })
      end
      pcall(function() up:write(encoded) end)
      if attach then
        -- hijack：双向复制。客户端刚发完请求，恢复读，转发 stdin。
        pcall(function()
          client:read_start(function(cerr, cdata)
            if cerr then return fail("client read") end
            if cdata then pcall(function() up:write(cdata) end) end
          end)
        end)
      end
    end)
  end)
  if not okc then return fail("connect failed") end

  up:read_start(function(err, data)
    if err then return fail(tostring(err)) end
    if data then
      if stream or attach then
        pcall(function() client:write(data) end)
      else
        -- 简单响应：先缓存，EOF 后一次写给客户端（保证审查/过滤可做）。
        simple_buf = simple_buf .. data
        if #simple_buf > 32 * 1024 * 1024 then
          return fail("response too large")
        end
      end
      return
    end
    -- EOF
    if not stream and not attach then
      pcall(_after_response, req, info, ctx, simple_buf)
      _respond(client, simple_buf)
    else
      _close(client)
      _close(up)
    end
    cb(true)
  end)
end

--- 处理一个已解析请求。
local function _handle(client, req)
  state.stats.requests = state.stats.requests + 1
  local info, perr = http.normalize_path(req.path)
  if not info then
    state.stats.denied = state.stats.denied + 1
    return _respond(client, http.error_response(400, perr or "bad path"))
  end

  local snap = probe.snapshot()
  local ctx = vim.tbl_extend("force", {
    tier = snap.tier,
    workspace_roots = state.opts.workspace_roots or {},
    session_netns = state.opts.session_netns == true,
    allow_binds = state.opts.allow_binds == true,
    allow_exec = state.opts.allow_exec == true and snap.tier == "N2",
    allow_attach = state.opts.allow_attach ~= false,
    allow_pull = state.opts.allow_pull ~= false,
    labels = state.opts.labels or {},
    limits = state.opts.limits or {},
    runtimes = state.opts.runtimes,
  }, state.opts)

  local decision = policy.check(req, ctx)
  if not decision.allow then
    state.stats.denied = state.stats.denied + 1
    _emit(events.SANDBOX_DOCKER_DENIED, {
      method = req.method, path = info.path, reason = decision.reason,
    })
    -- 对外只给 Docker 风格通用错误，具体策略原因只进事件/审计，不回传模型。
    local status = decision.status or 403
    local msg = status == 403 and "permission denied" or (decision.reason or "denied")
    return _respond(client, http.error_response(status, msg))
  end
  req = decision.request or req

  -- 容器 id 操作：inspect + 审查 + 操作矩阵。
  local op = _op_for(info, req.method)
  if op ~= "other" and info.segments[1] == "containers" and #info.segments >= 3 then
    local id = info.segments[2]
    return _review_container(id, ctx, function(ok, verdict, insp, reason)
      if not ok or not verdict then
        state.stats.denied = state.stats.denied + 1
        return _respond(client, http.error_response(404, "No such container"))
      end
      local approved = review.is_approved(id, verdict.digest)
      local owned = type(insp) == "table"
        and type(insp.Config) == "table"
        and type(insp.Config.Labels) == "table"
        and insp.Config.Labels["neoai.sandbox.owner"] ~= nil
      local allowed = review.operation_allowed(verdict.level, op, {
        approved = approved, owned = owned, tier = snap.tier,
      })
      if not allowed then
        state.stats.denied = state.stats.denied + 1
        _emit(events.SANDBOX_DOCKER_DENIED, {
          method = req.method, path = info.path, reason = "REVIEW_" .. verdict.level,
          id = id, level = verdict.level,
        })
        return _respond(client, http.error_response(403, "operation not permitted"))
      end
      state.stats.allowed = state.stats.allowed + 1
      _emit(events.SANDBOX_DOCKER_REQUEST, {
        method = req.method, path = info.path, decision = "allow", id = id, level = verdict.level,
      })
      _forward(client, req, info, ctx, function() end)
    end)
  end

  state.stats.allowed = state.stats.allowed + 1
  _emit(events.SANDBOX_DOCKER_REQUEST, {
    method = req.method, path = info.path, decision = "allow",
  })
  _forward(client, req, info, ctx, function() end)
end

--- 接收客户端。
local function _on_client(pipe)
  state.clients[pipe] = true
  local buf = ""
  local done = false
  pipe:read_start(function(err, data)
    if done then return end
    if err then
      done = true
      state.clients[pipe] = nil
      return _close(pipe)
    end
    if data then
      buf = buf .. data
      local req, consumed, perr = http.parse_request(buf)
      if not req then
        if perr == "INCOMPLETE" then return end
        done = true
        state.clients[pipe] = nil
        return _respond(pipe, http.error_response(400, perr or "bad request"))
      end
      buf = buf:sub((consumed or 0) + 1)
      done = true
      pcall(function() pipe:read_stop() end)
      _handle(pipe, req)
      return
    end
    -- EOF
    done = true
    state.clients[pipe] = nil
    _close(pipe)
  end)
end

-- ========== 资源监测 ==========

--- 监测一个容器（inspect + stats -> monitor.observe -> 可能 kill）。
local function _monitor_one(id, ctx, done)
  local okm, monitor = pcall(require, "NeoAI.sandbox.docker.monitor")
  if not okm or not monitor then return done() end
  _upstream_call(state.upstream_path, {
    method = "GET", path = "/containers/" .. id .. "/json", headers = {}, body = "",
  }, function(ok, status, body)
    if not ok or status ~= 200 or not body then return done() end
    local insp = http.decode_json(body)
    if not insp then return done() end
    local hc = type(insp.HostConfig) == "table" and insp.HostConfig or {}
    local name = tostring(insp.Name or id):gsub("^/", "")
    local st = state.monitor_states[id] or monitor.new_state()
    state.monitor_states[id] = st
    _upstream_call(state.upstream_path, {
      method = "GET", path = "/containers/" .. id .. "/stats?stream=false", headers = {}, body = "",
    }, function(ok2, status2, body2)
      if not ok2 or status2 ~= 200 or not body2 then return done() end
      local stats = http.decode_json(body2)
      if not stats then return done() end
      local dec = monitor.observe(st, stats, {
        memory_limit = tonumber(hc.Memory),
        pids_limit = tonumber(hc.PidsLimit),
        nano_cpus = tonumber(hc.NanoCpus),
        limits = state.opts.monitor_limits,
      })
      if dec.kill then
        local labels = type(insp.Config) == "table" and type(insp.Config.Labels) == "table" and insp.Config.Labels or {}
        local agent_id = labels["neoai.sandbox.agent"] or ""
        local text = monitor.kill_text(name, dec.reason, dec.snapshot)
        monitor.push_notice(agent_id, text)
        monitor.mark_killed()
        _emit(events.SANDBOX_DOCKER_RESOURCE_KILLED, {
          id = id, name = name, reason = dec.reason, snapshot = dec.snapshot,
        })
        _upstream_call(state.upstream_path, {
          method = "POST", path = "/containers/" .. id .. "/kill", headers = {}, body = "",
        }, function() done() end)
        return
      end
      if dec.warn then
        _emit(events.SANDBOX_DOCKER_RESOURCE_WARN, { id = id, name = name, snapshot = dec.snapshot })
      end
      done()
    end)
  end)
end

--- 一轮监测：列出 managed 容器并逐个采样。
local function _monitor_tick()
  if not state.running then return end
  _upstream_call(state.upstream_path, {
    method = "GET", path = "/containers/json?all=1", headers = {}, body = "",
  }, function(ok, status, body)
    if not ok or status ~= 200 or not body then return end
    local list = http.decode_json(body)
    if type(list) ~= "table" then return end
    local ids = {}
    for _, c in ipairs(list) do
      local labels = type(c.Labels) == "table" and c.Labels or {}
      if labels["neoai.sandbox.managed"] == "true" or labels["neoai.sandbox.owner"] ~= nil then
        if c.Id and #ids < 32 then ids[#ids + 1] = c.Id end
      end
    end
    local i = 1
    local function next_one()
      if i > #ids then return end
      local id = ids[i]; i = i + 1
      _monitor_one(id, state.opts, next_one)
    end
    next_one()
  end)
end

--- 启动监测定时器（仅会话 runtime；默认关闭，测试不触发）。
function M.start_monitor()
  if state.monitor_timer then return end
  local timer = uv.new_timer()
  if not timer then return end
  state.monitor_timer = timer
  timer:start(2000, 2000, function()
    vim.schedule(function() pcall(_monitor_tick) end)
  end)
end

--- 停止监测。
function M.stop_monitor()
  if state.monitor_timer then
    pcall(function() state.monitor_timer:stop(); state.monitor_timer:close() end)
    state.monitor_timer = nil
  end
  state.monitor_states = {}
end

-- ========== 公开 API ==========

--- 启动/复用 broker。
--- @param opts table {
---   socket_path: string, upstream_path: string,
---   workspace_roots?: string[], session_netns?: boolean,
---   allow_binds?: boolean, allow_exec?: boolean, allow_attach?: boolean,
---   allow_pull?: boolean, labels?: table, limits?: table,
--- }
--- @return boolean ok
--- @return string|nil err
function M.ensure(opts)
  opts = opts or {}
  if state.running and state.socket_path == opts.socket_path
    and state.upstream_path == opts.upstream_path then
    state.opts = opts
    return true
  end
  M.stop()
  if type(opts.socket_path) ~= "string" or opts.socket_path == "" then
    return false, "BROKER_NO_SOCKET"
  end
  if type(opts.upstream_path) ~= "string" or opts.upstream_path == "" then
    return false, "BROKER_NO_UPSTREAM"
  end
  local dir = vim.fn.fnamemodify(opts.socket_path, ":h")
  vim.fn.mkdir(dir, "p", 0)
  pcall(uv.fs_unlink, opts.socket_path)
  local server = uv.new_pipe(false)
  if not server then return false, "BROKER_NEW_PIPE_FAILED" end
  local ok, err = pcall(function() server:bind(opts.socket_path) end)
  if not ok then
    _close(server)
    return false, "BROKER_BIND_FAILED:" .. tostring(err)
  end
  pcall(uv.fs_chmod, opts.socket_path, 438) -- 0666：目录本身 0700，仅会话内可见
  server:listen(128, function(lerr)
    if lerr then
      _log("warn", "listen error: %s", tostring(lerr))
      return
    end
    local client = uv.new_pipe(false)
    if not client then return end
    server:accept(client)
    _on_client(client)
  end)
  state.server = server
  state.socket_path = opts.socket_path
  state.upstream_path = opts.upstream_path
  state.opts = opts
  state.running = true
  if opts.monitor == true then M.start_monitor() end
  _emit(events.SANDBOX_DOCKER_STARTED, { socket = opts.socket_path, upstream = opts.upstream_path })
  return true
end

--- 停止并清理。
function M.stop()
  M.stop_monitor()
  for client in pairs(state.clients) do _close(client) end
  state.clients = {}
  if state.server then _close(state.server) end
  if state.socket_path then pcall(uv.fs_unlink, state.socket_path) end
  local was = state.running
  state.server = nil
  state.socket_path = nil
  state.upstream_path = nil
  state.opts = {}
  state.running = false
  if was then _emit(events.SANDBOX_DOCKER_STOPPED, {}) end
end

--- 内部请求（重建/监测用；仍走同一策略入口之外的受控上游）。
--- @param method string
--- @param path string
--- @param body string|nil
--- @param cb fun(ok:boolean, status:number|nil, body:string|nil)
function M.request(method, path, body, cb)
  _upstream_call(state.upstream_path, {
    method = method, path = path,
    headers = { ["content-type"] = "application/json" },
    body = body or "",
  }, function(ok, status, resbody)
    cb(ok, status, resbody)
  end)
end

--- 运行状态。
--- @return table
function M.status()
  return {
    running = state.running,
    socket = state.socket_path,
    upstream = state.upstream_path,
    tier = probe.tier(),
    stats = vim.deepcopy(state.stats),
  }
end

--- 计数清零（测试）。
function M.reset_stats()
  state.stats = { requests = 0, allowed = 0, denied = 0, errors = 0 }
end

--- 测试注入上游处理（传 nil 清除）。
--- @param fn function|nil
function M._set_upstream(fn)
  state.upstream_override = fn
end

--- 清空（测试）。
function M.reset()
  M.stop()
  state.stats = { requests = 0, allowed = 0, denied = 0, errors = 0 }
  state.upstream_override = nil
end

return M
