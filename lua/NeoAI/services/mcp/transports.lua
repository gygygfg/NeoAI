--- MCP 传输层（stdio / Streamable HTTP）
--- @module NeoAI.services.mcp.transports
--- 两个传输实现统一接口（供 client.lua 消费）：
---   open():       启动连接 / 无操作
---   send(msg):    发送一条已编码 JSON-RPC 消息（字符串）
---   close(opts):  关闭连接（stdio 优雅退出；http 可选 DELETE session）
---   on_message:   function(msg) 客户端注册，收到一条已解码 JSON-RPC 消息时回调
---   is_open():    是否处于可发送状态
---
--- stdio：jobstart 子进程，按行分隔 JSON 帧（MCP 标准：消息分行为 JSON，内嵌换行需转义）。
--- http：Streamable HTTP POST，支持 application/json 单响应与 text/event-stream SSE。

local async = require("NeoAI.utils.async")
local http = require("NeoAI.utils.http")
local json = require("NeoAI.utils.json")
local logger = require("NeoAI.kernel.logger")

local M = {}

-- ========== 共有工具 ==========

--- 规范化服务器配置（取默认值）
local function _norm_cfg(server)
  server = server or {}
  server.transport = server.transport or "stdio"
  server.timeout_ms = server.timeout_ms or 60000
  server.env = server.env or {}
  return server
end

--- 构造基类字段
--- @param self table
--- @param name string
--- @param transport_type string
local function _base(self, name, transport_type)
  self.name = name
  self.transport = transport_type
  self.on_message = nil
  self.open_ = false
  return self
end

--- 是否已打开（通用）
function M.is_open(self)
  return self.open_
end

--- 大小写不敏感地取响应头
--- @param headers table|nil
--- @param want string
--- @return string|nil
function M._header_caseless(headers, want)
  if not headers then return nil end
  want = want:lower()
  for k, v in pairs(headers) do
    if tostring(k):lower() == want then return v end
  end
  return nil
end

-- ========== stdio 传输 ==========

--- 发送一条已解码的 JSON-RPC 消息（由 on_message 回调给客户端）
--- @param self table
--- @param line string
local function _emit_line(self, line)
  if line == "" then return end
  local ok, decoded = pcall(json.decode, line)
  if not ok then
    logger.warn("[mcp] %s stdout 解码失败: %s", self.name, tostring(decoded))
    return
  end
  if self.on_message then self.on_message(decoded) end
end

--- stdio 写队列去抖：合并一次事件循环内的多次写，且保证按顺序写 stdin
--- @param self table
local function _schedule_flush(self)
  if self.write_pending then return end
  self.write_pending = true
  vim.schedule(function()
    self.write_pending = false
    if not self.open_ or type(self.job) ~= "number" or self.job <= 0 then return end
    local ok, status = pcall(vim.fn.job_status, self.job)
    if not ok or status ~= "run" then return end
    local buffered = self._out
    self._out = {}
    for _, chunk in ipairs(buffered) do
      pcall(vim.fn.chansend, self.job, chunk)
    end
  end)
end

--- 创建 stdio 传输实例
--- @param server table 服务器配置 { command, args, env, timeout_ms }
--- @param opts table { name? }
--- @return table 传输实例
function M.stdio(server, opts)
  opts = opts or {}
  server = _norm_cfg(server)
  local self = setmetatable({}, { __index = M })
  _base(self, opts.name or "stdio", "stdio")
  self.command = server.command
  self.args = server.args or {}
  self.env = server.env or {}
  self.cwd = server.cwd
  self.timeout_ms = server.timeout_ms or 60000
  self.dead_ms = server.dead_ms or 15000 -- SIGTERM 后等待退出的时间
  self.job = nil
  self.buf = "" -- 行累积缓冲
  self.write_pending = false
  self._out = {}

  self.open = function()
    if self.open_ then return end
    local argv = {}
    if self.command then argv[#argv + 1] = self.command end
    for _, a in ipairs(self.args or {}) do argv[#argv + 1] = a end
    if #argv == 0 then
      logger.warn("[mcp] %s 无 command 可启动", self.name)
      return
    end
    -- 统一经沙箱创建 server 子进程：网络放行；只读暴露 command 所在目录（支持装在
    -- $HOME 下的 server）；cwd（或进程工作目录）作为可写根经 overlay 暂存，server 的
    -- 写入在退出时冻结为候选（与 edit_file 一样走暂存）。后端不可用时拒绝启动（fail-closed）。
    local sandbox_exec = require("NeoAI.sandbox.exec")
    local ro, rw = {}, {}
    local resolved = vim.fn.exepath(self.command)
    local cmd_path = (resolved ~= "" and resolved) or self.command
    if type(cmd_path) == "string" and cmd_path:sub(1, 1) == "/" then
      ro[#ro + 1] = vim.fn.fnamemodify(cmd_path, ":p:h")
    end
    if type(self.cwd) == "string" and self.cwd ~= "" then rw[#rw + 1] = self.cwd end
    local full, finish, werr = sandbox_exec.open(argv, {
      name = "mcp_" .. tostring(self.name),
      network = true,
      ro_binds = ro,
      writable_roots = rw,
      cwd = self.cwd,
      command = table.concat(argv, " "),
    })
    if not full then
      logger.warn("[mcp] %s 沙箱不可用，拒绝启动: %s", self.name, tostring(werr))
      return
    end
    self._sandbox_finish = finish
    self.job = vim.fn.jobstart(full, {
      stdin = "pipe",
      stdout_buffered = false,
      stderr_buffered = true,
      env = self.env,
      on_stdout = function(_, data)
        for _, piece in ipairs(data or {}) do
          if piece == "" then
            -- 行结束：把累积缓冲作为一条完整 JSON-RPC 消息处理
            if self.buf ~= "" then
              _emit_line(self, self.buf)
              self.buf = ""
            end
          else
            self.buf = self.buf .. piece
          end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data or {}) do
          if line ~= "" then
            logger.debug("[mcp] %s stderr: %s", self.name, line)
          end
        end
      end,
      on_exit = function(_, code)
        -- 收尾：处理未以换行结束的残余行
        if self.buf ~= "" then
          _emit_line(self, self.buf)
          self.buf = ""
        end
        -- 冻结 server 在 overlay 暂存层产生的写入为候选（退出时统一捕获）。
        if self._sandbox_finish then
          pcall(self._sandbox_finish, { code = code })
          self._sandbox_finish = nil
        end
        local was_open = self.open_
        self.open_ = false
        if was_open and self.on_exit then self.on_exit(code) end
      end,
    })
    if self.job <= 0 then
      self.job = nil
      logger.warn("[mcp] %s 无法启动子进程", self.name)
      return
    end
    self.open_ = true
    self.buf = ""
    self._out = {}
  end

  self.send = function(_, msg)
    if not self.open_ then
      logger.debug("[mcp] %s 未打开，丢弃消息", self.name)
      return
    end
    self._out[#self._out + 1] = msg .. "\n"
    _schedule_flush(self)
  end

  self.close = function(_, opts)
    opts = opts or {}
    self.open_ = false
    if type(self.job) == "number" and self.job > 0 then
      local ok, status = pcall(vim.fn.job_status, self.job)
      if ok and status == "run" then
        -- ① 关闭 stdin 通知服务器退出（优雅）
        pcall(vim.fn.chanclose, self.job, "stdin")
        -- ② SIGTERM
        pcall(vim.fn.jobstop, self.job)
        -- ③ SIGKILL 兜底（若 SIGTERM 后仍未退出）
        if self.dead_ms and self.dead_ms > 0 then
          vim.defer_fn(function()
            if type(self.job) == "number" and self.job > 0 then
              local ok2, st2 = pcall(vim.fn.job_status, self.job)
              if ok2 and st2 == "run" then
                pcall(vim.fn.jobstop, self.job)
              end
            end
          end, self.dead_ms)
        end
      end
    end
    self.job = nil
  end

  return self
end

-- ========== http（Streamable HTTP）传输 ==========

--- 构建请求头
--- @param self table
--- @return table
local function _build_headers(self)
  local h = {}
  for k, v in pairs(self.headers) do h[k] = v end
  h["Accept"] = "application/json, text/event-stream"
  h["Content-Type"] = "application/json"
  h["MCP-Protocol-Version"] = self.protocol_version
  if self.session_id then h["Mcp-Session-Id"] = self.session_id end
  return h
end

--- 解析 SSE 响应体中的每条 data 消息并回调
--- @param self table
--- @param body string
local function _parse_sse_body(self, body)
  for line in (body .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\r$", "")
    local content = line:match("^data:%s?(.*)$")
    if content then
      if content == "[DONE]" then break end
      local ok, decoded = pcall(json.decode, content)
      if ok and type(decoded) == "table" then
        if self.on_message then self.on_message(decoded) end
      else
        logger.warn("[mcp] %s SSE data 解码失败: %s", self.name, tostring(content))
      end
    end
  end
end

--- 创建 http 传输实例
--- @param server table 服务器配置 { url, headers, timeout_ms }
--- @param opts table { name?, protocol_version? }
--- @return table 传输实例
function M.http(server, opts)
  opts = opts or {}
  server = _norm_cfg(server)
  local self = setmetatable({}, { __index = M })
  _base(self, opts.name or "http", "http")
  self.url = server.url
  self.headers = server.headers or {}
  self.timeout_ms = server.timeout_ms or 60000
  self.session_id = server.session_id or nil
  self.protocol_version = server.protocol_version or (opts.protocol_version or "2025-06-18")
  self._active = 0

  self.open = function()
    self.open_ = true
  end

  self.send = function(_, msg)
    if not self.open_ then
      logger.debug("[mcp] %s 未打开，丢弃 HTTP 消息", self.name)
      return
    end
    self._active = self._active + 1
    local headers = _build_headers(self)
    http.request({
      base_url = self.url,
      path = "",
      method = "POST",
      headers = headers,
      body = msg,
      timeout_ms = self.timeout_ms,
      include_headers = true,
    }, {}):then_(function(resp)
      local body = ""
      local resp_headers = {}
      if type(resp) == "table" then
        body = resp.body or ""
        resp_headers = resp.headers or {}
      else
        body = resp
      end
      -- 会话 ID：服务器初始化时可下发
      local sid = M._header_caseless(resp_headers, "mcp-session-id")
      if sid and sid ~= "" then self.session_id = sid end
      -- 协议版本回显
      local pv = M._header_caseless(resp_headers, "mcp-protocol-version")
      if pv and pv ~= "" then self.protocol_version = pv end
      -- 内容分发
      local ct = M._header_caseless(resp_headers, "content-type") or ""
      if ct:find("text/event%-stream") then
        _parse_sse_body(self, body)
      else
        local ok, decoded = pcall(json.decode, body)
        if ok and type(decoded) == "table" then
          if self.on_message then self.on_message(decoded) end
        end
      end
    end, function(err)
      logger.warn("[mcp] %s HTTP 请求失败: %s", self.name, tostring(err and err.message or err))
    end):finally(function()
      self._active = math.max(0, self._active - 1)
    end)
  end

  self.close = function(_, opts)
    opts = opts or {}
    local terminate = opts.terminate ~= false
    self.open_ = false
    if terminate and self.session_id and self.url then
      local headers = {}
      for k, v in pairs(self.headers) do headers[k] = v end
      headers["Accept"] = "application/json, text/event-stream"
      headers["Mcp-Session-Id"] = self.session_id
      headers["MCP-Protocol-Version"] = self.protocol_version
      http.request({
        base_url = self.url,
        path = "",
        method = "DELETE",
        headers = headers,
        timeout_ms = 5000,
        include_headers = true,
      }, {}):then_(function() end, function() end)
    end
  end

  return self
end

--- 暴露测试辅助（stdio 帧解码 / HTTP SSE body 解析）
M._emit_line = _emit_line
M._parse_sse_body = _parse_sse_body

--- 工厂：按配置选择传输
--- @param server table 服务器配置
--- @param opts table { name?, protocol_version? }
--- @return table|nil 传输实例
function M.create(server, opts)
  server = _norm_cfg(server)
  if server.transport == "http" or server.url then
    if server.url then return M.http(server, opts) end
    logger.warn("[mcp] %s 配置为 http 但缺少 url", opts and opts.name or "server")
    return nil
  end
  return M.stdio(server, opts)
end

return M
