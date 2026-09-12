--- HTTP 客户端
--- @module NeoAI.utils.http
--- 基于 curl + vim.fn.jobstart 的异步 HTTP 客户端。
--- - 非阻塞：进程在后台运行，回调走 vim.schedule 进入主循环
--- - 支持流式（SSE）与普通请求
--- - 支持 AbortSignal：取消时直接 kill 进程
--- - 指数退避重试见 utils.async.retry

local async = require("NeoAI.utils.async")

local M = {}

-- 流式成功响应只经 on_chunk 交付；仅保留有界错误体供诊断/溢出恢复。
local MAX_STREAM_ERROR_BYTES = 64 * 1024

-- ========== 私有工具 ==========

local function _which_curl()
  if vim.fn.executable("curl") ~= 1 then
    return nil
  end
  return vim.fn.exepath("curl")
end

-- 懒检测：--fail-with-body 让 4xx/5xx 以非零退出码结束并保留响应体
local _fail_with_body_support = nil
local function _supports_fail_with_body()
  if _fail_with_body_support ~= nil then return _fail_with_body_support end
  local curl = _which_curl()
  local ok = curl ~= nil
  if ok then
    local handle = io.popen(curl .. " --help all 2>/dev/null")
    if handle then
      local out = handle:read("*a")
      handle:close()
      ok = out and out:find("--fail%-with%-body") ~= nil
    end
  end
  _fail_with_body_support = ok
  return ok
end

--- 从 curl 错误信息中解析真实 HTTP 状态码
--- 如 "curl: (22) The requested URL returned error: 400"
--- @param err_msg string
--- @return number|nil
local function _parse_http_status(err_msg)
  local status = err_msg and err_msg:match("error: (%d+)")
  if status then return tonumber(status) end
  return nil
end

--- 解析 curl --dump-header 临时文件为 header 映射（key 小写）
--- @param path string
--- @return table
local function _parse_headers_file(path)
  local out = {}
  local f = io.open(path, "rb")
  if not f then return out end
  local content = f:read("*a")
  f:close()
  for line in (content .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\r$", "")
    -- CONNECT / 100 Continue 的头部不得混入最终响应。
    if line:match("^HTTP/%S+ %d+") then out = {} end
    local name, value = line:match("^([%w%-_%[%]]+):%s*(.-)%s*$")
    if name then
      out[name:lower()] = value
    end
  end
  return out
end

local function _build_url(base_url, path)
  if not path or path == "" then return base_url end
  if base_url:match("/$") then
    return base_url .. (path:gsub("^/+", ""))
  end
  return base_url .. "/" .. (path:gsub("^/+", ""))
end

local function _format_headers(headers)
  local out = {}
  for k, v in pairs(headers or {}) do
    out[#out + 1] = "-H"
    out[#out + 1] = string.format("%s: %s", k, tostring(v))
  end
  return out
end

local function _build_args(opts)
  local args = { "-sS", "--no-buffer" }
  if opts.include_headers then
    -- 捕获响应头（供 MCP http 会话 id / 内容类型检测）：
    -- 使用临时文件转储头部，避免与响应体混淆。
    if not opts._dump_headers_path then
      opts._dump_headers_path = vim.fn.tempname()
    end
    args[#args + 1] = "--dump-header"
    args[#args + 1] = opts._dump_headers_path
  end
  if opts.stream then
    -- 流式请求：用空闲超时（--speed-time/--speed-limit）替代总时长上限（--max-time）。
    -- 流式（尤其是长推理 / 长生成）会在超过 timeout 秒内持续收到数据，若按总时长用
    -- --max-time 强制掐断，会出现 curl 错误 28（"Operation timed out after ... "）且已收到
    -- 大片数据（如 "with 2021737 bytes received"）。改为：连续 timeout_ms/1000 秒无任何
    -- 数据到达才判定为超时中断；只要数据持续流动就不再限时，避免长耗时流被误杀。
    args[#args + 1] = "--speed-time"
    args[#args + 1] = tostring(math.max(1, math.ceil((opts.timeout_ms or 30000) / 1000)))
    args[#args + 1] = "--speed-limit"
    args[#args + 1] = "1"
  else
    args[#args + 1] = "--max-time"
    args[#args + 1] = tostring((opts.timeout_ms or 30000) / 1000)
  end
  if _supports_fail_with_body() then
    -- 4xx/5xx 以非零退出码结束并保留响应体，避免错误被静默吞掉
    args[#args + 1] = "--fail-with-body"
  end
  if opts.stream then
    args[#args + 1] = "-N"
  end
  local method = (opts.method or "GET"):upper()
  local url = _build_url(opts.base_url, opts.path)
  if method == "GET" and opts.query then
    local qs = {}
    for k, v in pairs(opts.query) do
      qs[#qs + 1] = vim.uri_encode(k) .. "=" .. vim.uri_encode(tostring(v))
    end
    if #qs > 0 then
      url = url .. (url:match("?") and "&" or "?") .. table.concat(qs, "&")
    end
  end
  args[#args + 1] = "-X"
  args[#args + 1] = method
  local headers = {}
  for k, v in pairs(opts.headers or {}) do
    headers[k] = v
  end
  if opts.body ~= nil and not headers["Content-Type"] then
    headers["Content-Type"] = "application/json"
  end
  local hdr_args = _format_headers(headers)
  for _, h in ipairs(hdr_args) do args[#args + 1] = h end
  if opts.body ~= nil then
    local body = opts.body
    if type(body) == "table" then
      local json = require("NeoAI.utils.json")
      body = json.encode(body)
    end
    args[#args + 1] = "--data-binary"
    args[#args + 1] = "@-"
    args[#args + 1] = "--"
    args[#args + 1] = url
    return args, tostring(body)
  end
  args[#args + 1] = "--"
  args[#args + 1] = url
  return args, nil
end

-- ========== 流式事件解析（SSE） ==========

--- 将累计的 buffer 解析为 SSE 事件
--- 返回 { events = {...}, rest = 剩余未消费的字符串 }
--- 只消费以换行结尾的完整 data 行；行尾未到的部分保留在 rest 中等待后续数据，
--- 避免把跨多次 on_stdout 回调的 data 行当作完整事件消费掉而丢失
--- （丢事件 = 丢工具调用增量/内容增量，表现为"工具调用后不再进入下一轮"）。
local function _parse_sse(buffer)
  local events = {}
  local rest = buffer
  while true do
    local line_end = rest:find("\n", 1, true)
    local line, remainder
    if line_end then
      line = rest:sub(1, line_end - 1)
      remainder = rest:sub(line_end + 1)
    else
      -- 最后一行尚未收全（缺行尾换行）：保留缓冲，等待后续数据补齐
      break
    end
    line = line:gsub("\r$", "") -- 兼容 CRLF 行尾
    -- 兼容 "data: " 与 "data:"（MCP streamable HTTP 部分服务器不带空格）
    local content = line:match("^data:%s?(.*)$")
    if content then
      rest = remainder
      if content == "[DONE]" then
        events[#events + 1] = { type = "done" }
        break
      end
      events[#events + 1] = { type = "data", data = content }
    end
    rest = remainder
  end
  return events, rest
end

-- ========== 公共 API ==========

--- SSE 解析器（测试用：与 stream.accumulate_tool_calls 同类导出约定）
M._parse_sse = _parse_sse

--- 发起 HTTP 请求
--- @param opts table { base_url, path?, method?, headers?, query?, body?, timeout_ms?, stream? }
--- @param callbacks table|nil { on_chunk?: fun(data: string, done: boolean), signal? }
--- @return Deferred resolve(响应体字符串；流式为 ""), reject(错误)
function M.request(opts, callbacks)
  callbacks = callbacks or {}
  if callbacks.signal and callbacks.signal:aborted() then
    return async.reject({ kind = "aborted", message = callbacks.signal:reason() })
  end
  local curl = _which_curl()
  if not curl then
    return async.reject({ kind = "http", message = "curl 不可用，无法发送 HTTP 请求" })
  end

  -- 每次请求独占头部文件；不把内部临时路径写回调用方的 opts。
  opts = vim.tbl_extend("force", {}, opts)
  opts._dump_headers_path = opts.include_headers and vim.fn.tempname() or nil
  local args, stdin_body = _build_args(opts)
  local stdout = {}
  local stdout_bytes = 0
  local body_truncated = false
  local stderr = {}
  local done = false
  local sse_done = false
  local skip_line = false
  local chunk_acc = ""

  local d = async.Deferred.new()
  local job
  local cleanup_unsub = function() end
  local function cleanup()
    cleanup_unsub()
    if opts._dump_headers_path then pcall(vim.fn.delete, opts._dump_headers_path) end
  end

  local function fail(err)
    if done then return end
    done = true
    if job and job > 0 then pcall(vim.fn.jobstop, job) end
    cleanup()
    d:reject(err)
  end

  local function deliver(chunk, is_done)
    if not callbacks.on_chunk then return true end
    local ok, err = pcall(callbacks.on_chunk, chunk, is_done)
    if not ok then
      fail({ kind = "callback", message = tostring(err) })
    end
    return ok
  end

  local function consume(buffer)
    if skip_line then
      local nl = buffer:find("\n", 1, true)
      if not nl then return end
      buffer = buffer:sub(nl + 1)
      skip_line = false
    end
    local parsed, rest = _parse_sse(buffer)
    chunk_acc = rest
    for _, ev in ipairs(parsed) do
      if ev.type == "done" then
        sse_done = true
        chunk_acc = ""
        break
      elseif not deliver(ev.data, false) then
        break
      end
      if done then break end -- on_chunk 内也可能触发取消
    end
    -- 非 data 行（如巨大的 JSON 错误体）不需要无限缓存到行尾。
    if chunk_acc ~= "" and not chunk_acc:match("^data:")
      and ("data:"):sub(1, #chunk_acc) ~= chunk_acc then
      chunk_acc = ""
      skip_line = true
    end
  end

  if callbacks.signal then
    cleanup_unsub = callbacks.signal:subscribe(function(reason)
      fail({ kind = "aborted", message = reason })
    end)
  end

  local started, result = pcall(vim.fn.jobstart, {
    curl,
    unpack(args),
  }, {
    stdin = stdin_body and "pipe" or nil,
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if done then return end
      -- 元素间才是换行；首尾元素可以是跨回调的同一行片段。
      local chunk = table.concat(data or {}, "\n")
      local saved = chunk
      if opts.stream then
        saved = chunk:sub(1, math.max(0, MAX_STREAM_ERROR_BYTES - stdout_bytes))
        body_truncated = body_truncated or #saved < #chunk
      end
      if saved ~= "" then
        stdout[#stdout + 1] = saved
        stdout_bytes = stdout_bytes + #saved
      end
      if opts.stream and not sse_done then
        consume(chunk_acc .. chunk)
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      -- 取消后 curl 仍可能在退出前创建 dump-header 文件，再清理一次。
      if done then cleanup(); return end
      if opts.stream and code == 0 then
        -- 消费剩余缓冲（补一个换行让末行没有行尾换行时也能被解析）
        if not sse_done and chunk_acc ~= "" then
          consume(chunk_acc .. "\n")
        end
        if done then return end
        if not deliver(nil, true) or done then return end
      end
      done = true
      local body = opts.stream and code == 0 and "" or table.concat(stdout)
      -- include_headers：读取 curl --dump-header 临时文件，解析响应头
      local headers = nil
      if opts.include_headers and opts._dump_headers_path and vim.fn.filereadable(opts._dump_headers_path) == 1 then
        headers = _parse_headers_file(opts._dump_headers_path)
      end
      cleanup()
      if code == 0 then
        if opts.include_headers then
          d:resolve({ body = body, headers = headers or {} })
        else
          d:resolve(body)
        end
      else
        local err_msg = table.concat(stderr, "\n")
        if err_msg == "" then err_msg = "curl 退出码 " .. tostring(code) end
        local status = _parse_http_status(err_msg)
        local err = { kind = "http", status = status or code, message = err_msg, body = body }
        if body_truncated then err.body_truncated = true end
        if opts.include_headers then err.headers = headers or {} end
        d:reject(err)
      end
    end,
  })

  if not started or result <= 0 then
    fail({ kind = "http", message = "无法启动 curl 进程: " .. tostring(result) })
    return d
  end
  job = result

  if stdin_body then
    pcall(vim.fn.chansend, job, stdin_body)
    pcall(vim.fn.chanclose, job, "stdin")
  end

  return d
end

--- 便捷：JSON 请求，自动编解码
--- @param opts table 同 M.request，另支持 json=true
--- @return Deferred resolve(解码后的数据或 nil)
function M.json_request(opts, callbacks)
  local req_opts = vim.deepcopy(opts)
  if req_opts.body ~= nil and type(req_opts.body) ~= "string" then
    local json = require("NeoAI.utils.json")
    req_opts.body = json.encode(req_opts.body)
  end
  return M.request(req_opts, callbacks):then_(function(body)
    local json = require("NeoAI.utils.json")
    local decoded, err = json.decode_or_nil(body)
    if decoded == nil and body ~= "" then
      return nil
    end
    return decoded
  end)
end

--- 便捷：GET JSON
--- @param base_url string
--- @param path string|nil
--- @param opts table|nil { headers?, query?, timeout_ms?, signal? }
--- @return Deferred
function M.get_json(base_url, path, opts)
  opts = opts or {}
  return M.json_request({
    base_url = base_url,
    path = path,
    method = "GET",
    headers = opts.headers,
    query = opts.query,
    timeout_ms = opts.timeout_ms,
  }, { signal = opts.signal })
end

return M
