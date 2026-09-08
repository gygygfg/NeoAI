--- MCP JSON-RPC 2.0 客户端（传输无关）
--- @module NeoAI.services.mcp.client
--- 管理 id 关联、请求超时与取消（notifications/cancelled）、服务器主动请求/通知分发、
--- initialize/initialized 握手、断线重连。传输层（stdio/http）见 transports.lua。
--- 纯异步，基于 utils/async 的 Deferred。

local async = require("NeoAI.utils.async")
local json = require("NeoAI.utils.json")
local logger = require("NeoAI.kernel.logger")

local M = {}

-- JSON-RPC 标准错误码
local ERROR_CODES = {
  PARSE_ERROR = -32700,
  INVALID_REQUEST = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS = -32602,
  INTERNAL = -32603,
}

-- ========== 私有工具 ==========

--- 错误对象构造（JSON-RPC error 与内部错误统一形状）
--- @param code number
--- @param message string
--- @param err_data any
--- @return table
local function _rpc_error(code, message, err_data)
  return { code = code, message = message or "", data = err_data }
end

--- 判断错误是否为「客户端可取消」类（超时/取消，而非协议内部错误）
--- @param err table|nil
--- @return boolean
local function _is_client_abort(err)
  return err and (err.kind == "timeout" or err.kind == "cancelled" or err.kind == "aborted")
end

-- ========== 构造函数 ==========

--- 创建 MCP 客户端
--- @param transport table 传输实例（含 open/send/close/is_open）
--- @param opts table { name?, timeout_ms?, signal?, on_log?, on_disconnect? }
--- @return table Client
function M.new(transport, opts)
  opts = opts or {}
  local self = setmetatable({}, { __index = M })
  self.transport = transport
  self.name = opts.name or "mcp"
  self.timeout_ms = opts.timeout_ms or 60000
  self.signal = opts.signal
  self.on_disconnect = opts.on_disconnect
  self.next_id = 1
  self.pending = {} -- id -> { d, timer, method, cancelled }
  self.notification_handlers = {} -- method -> { fn }
  self.request_handlers = {} -- method -> fn(params) -> result|Deferred
  self.initialized = false
  self.closed = false
  self.transport_dead = false -- 底层传输已断开（stdio 进程退出 / 连接失效），需重建
  -- 传输消息到达：统一入口（transports 通过 on_message 回调解码后的 msg）
  self.transport.on_message = function(msg) M._dispatch(self, msg) end
  -- 传输断开（如 stdio 子进程退出）：标记失效并拒绝挂起请求，供上层重连
  self.transport.on_exit = function(code) M._on_transport_exit(self, code) end
  return self
end

--- 传输断开处理：拒绝所有挂起请求并通知上层（重连）
--- @param self table
--- @param code number|nil 退出码
function M._on_transport_exit(self, code)
  if self.closed then return end
  self.transport_dead = true
  self.initialized = false
  for id, entry in pairs(self.pending) do
    entry.cancelled = true
    if entry.d:is_pending() then
      entry.d:reject({ kind = "disconnected", code = -1, message = "MCP 传输已断开", method = entry.method })
    end
    self.pending[id] = nil
  end
  if self.on_disconnect then
    local ok, err = pcall(self.on_disconnect, code)
    if not ok then logger.warn("[mcp] %s on_disconnect 回调异常: %s", self.name, tostring(err)) end
  end
end

-- ========== 消息分发 ==========

--- 处理一条已解码的 JSON-RPC 消息
--- @param msg table
function M._dispatch(self, msg)
  if type(msg) ~= "table" then return end
  local id = msg.id
  local method = msg.method
  if method ~= nil then
    if id ~= nil then
      -- 服务器->客户端 请求（如 ping / sampling / roots）
      M._handle_server_request(self, msg)
    else
      -- 服务器->客户端 通知（如 notifications/tools/list_changed, logging）
      M._dispatch_notification(self, method, msg.params)
    end
  else
    -- 客户端->服务器 请求的响应
    M._handle_response(self, id, msg.result, msg.error)
  end
end

--- 响应处理：resolve/reject 挂起请求
--- @param id any
--- @param result any
--- @param err table|nil
function M._handle_response(self, id, result, err)
  local entry = self.pending[id]
  if not entry then return end
  self.pending[id] = nil
  entry.cancelled = true
  if err then
    local e = {
      kind = "mcp",
      code = err.code,
      message = err.message or "MCP 请求失败",
      data = err.data,
      method = entry.method,
    }
    entry.d:reject(e)
  else
    entry.d:resolve(result)
  end
end

--- 通知分发
--- @param method string
--- @param params table|nil
function M._dispatch_notification(self, method, params)
  local handlers = self.notification_handlers[method]
  if handlers then
    for _, h in ipairs(handlers) do
      pcall(h, params or {})
    end
  else
    logger.debug("[mcp] %s 收到未处理通知: %s", self.name, method)
  end
end

--- 服务器->客户端请求处理
--- @param msg table { id, method, params }
function M._handle_server_request(self, msg)
  local method = msg.method
  local handler = self.request_handlers[method]
  if not handler then
    -- 未知方法：回 -32601
    M._send_response(self, msg.id, nil, _rpc_error(ERROR_CODES.METHOD_NOT_FOUND, "method not found: " .. tostring(method)))
    return
  end
  local ok, res = pcall(handler, msg.params or {})
  if not ok then
    M._send_response(self, msg.id, nil, _rpc_error(ERROR_CODES.INTERNAL, tostring(res)))
    return
  end
  if type(res) == "table" and res.then_ then
    res:then_(
      function(v) M._send_response(self, msg.id, v, nil) end,
      function(e) M._send_response(self, msg.id, nil, _rpc_error(ERROR_CODES.INTERNAL, tostring(e and e.message or e))) end
    )
  else
    M._send_response(self, msg.id, res, nil)
  end
end

--- 发送 JSON-RPC 响应（回服务器请求）
--- @param id any
--- @param result any
--- @param err table|nil
function M._send_response(self, id, result, err)
  if self.closed then return end
  local msg = { jsonrpc = "2.0", id = id }
  if err then
    msg.error = err
  else
    msg.result = result
  end
  M._send(self, msg)
end

--- 发送一条消息到传输层
--- @param msg table
function M._send(self, msg)
  if self.closed then return end
  local ok, encoded = pcall(json.encode, msg)
  if not ok then
    logger.warn("[mcp] %s 编码失败: %s", self.name, tostring(encoded))
    return
  end
  self.transport:send(encoded)
end

-- ========== 公开 API ==========

--- initialize / 握手（客户端先发 initialize，服务器回 capability；随后发 initialized 通知）
--- @param opts table { protocolVersion?, clientInfo?, capabilities?, timeout_ms? }
--- @return Deferred resolve(initialize result)
function M.initialize(self, opts)
  opts = opts or {}
  local result = self:request("initialize", {
    protocolVersion = opts.protocolVersion or "2025-06-18",
    capabilities = opts.capabilities or {},
    clientInfo = opts.clientInfo or { name = "NeoAI", version = "1.0.0" },
  }, { timeout_ms = opts.timeout_ms or self.timeout_ms })
  return result:then_(function(res)
    self.initialized = true
    -- 发送 initialized 通知，表示已就绪可正常通讯
    self:notify("notifications/initialized", {})
    return res
  end)
end

--- 发起 JSON-RPC 请求（自动分配 id、关联响应、超时/取消）
--- @param method string
--- @param params table|nil
--- @param opts table { timeout_ms?, signal? }
--- @return Deferred resolve(result), reject(error)
function M.request(self, method, params, opts)
  opts = opts or {}
  if self.closed then
    return async.reject({ kind = "mcp", code = -1, message = "MCP 客户端已关闭", method = method })
  end
  if self.transport_dead then
    return async.reject({ kind = "disconnected", code = -1, message = "MCP 传输已断开", method = method })
  end
  local id = self.next_id
  self.next_id = self.next_id + 1
  local d = async.Deferred.new()
  local entry = { d = d, method = method, timeout_ms = opts.timeout_ms or self.timeout_ms, cancelled = false }
  self.pending[id] = entry

  -- 超时：发 cancelled 通知 + reject。
  -- 注意：vim.defer_fn 返回 libuv 定时器（userdata），无法用 vim.fn.timer_stop 取消，
  -- 故用 entry.cancelled 标志位兜底（响应到达/手动取消时置位，回调即成为 no-op）。
  local timer = vim.defer_fn(function()
    if entry.cancelled or not entry.d:is_pending() then return end
    entry.cancelled = true
    self.pending[id] = nil
    -- 通知服务器取消该请求
    self:notify("notifications/cancelled", { requestId = id, reason = "timeout" })
    d:reject({ kind = "timeout", code = -2, message = "MCP 请求超时: " .. tostring(method), method = method })
  end, entry.timeout_ms)
  entry.timer = timer

  -- 绑定取消信号（AbortSignal）
  local unsubs = {}
  if opts.signal then
    unsubs[#unsubs + 1] = opts.signal:subscribe(function(reason)
      local pending = self.pending[id]
      if pending then
        pending.cancelled = true
        self.pending[id] = nil
        self:notify("notifications/cancelled", { requestId = id, reason = tostring(reason) })
        d:reject({ kind = "cancelled", code = -2, message = "MCP 请求已取消: " .. tostring(method), method = method })
      end
    end)
  end

  local msg = { jsonrpc = "2.0", id = id, method = method }
  if params ~= nil then msg.params = params end
  M._send(self, msg)

  -- 注意：此库的 Deferred:finally 会“吸收”reject（以错误对象 resolve）。
  -- 若 request 返回 finally 包装结果，则超时/关闭的错误会以值形式流入 then_ 的
  -- on_success 分支，on_error 永不触发。这里用 then_ 显式清理并保留 reject 语义。
  return d:then_(function(v)
    for _, u in ipairs(unsubs) do u() end
    return v
  end, function(e)
    for _, u in ipairs(unsubs) do u() end
    return async.reject(e)
  end)
end

--- 发送通知（无需响应）<br/>
--- 用法：`client:notify("notifications/initialized", {})`
--- @param method string
--- @param params table|nil
function M.notify(self, method, params)
  local msg = { jsonrpc = "2.0", method = method }
  if params ~= nil then msg.params = params end
  M._send(self, msg)
end

--- 注册通知处理器
--- @param method string
--- @param fn function(params)
--- @return function 取消订阅
function M.on_notification(self, method, fn)
  self.notification_handlers[method] = self.notification_handlers[method] or {}
  table.insert(self.notification_handlers[method], fn)
  local removed = false
  return function()
    if removed then return end
    removed = true
    local list = self.notification_handlers[method]
    if not list then return end
    for i, h in ipairs(list) do
      if h == fn then table.remove(list, i) break end
    end
  end
end

--- 注册服务器请求处理器（返回结果或 Deferred）
--- @param method string
--- @param fn function(params) -> result | Deferred
function M.on_request(self, method, fn)
  self.request_handlers[method] = fn
end

--- 打开传输并开始接收消息（供 reconnect 使用；也开放一次 open 以支持多请求）
function M.open(self)
  self.closed = false
  self.transport_dead = false
  self.transport:open()
end

--- 关闭客户端与底层传输
--- @param opts table { timeout_ms? }
function M.close(self, opts)
  opts = opts or {}
  if self.closed then return end
  self.closed = true
  self.initialized = false
  -- 拒绝所有挂起请求
  for id, entry in pairs(self.pending) do
    entry.cancelled = true
    if entry.d:is_pending() then
      entry.d:reject({ kind = "mcp", code = -1, message = "MCP 连接已关闭", method = entry.method })
    end
    self.pending[id] = nil
  end
  self.transport:close(opts)
end

--- 是否已连接并完成握手
--- @return boolean
function M.is_initialized(self)
  return self.initialized and not self.closed and not self.transport_dead
end

return M
