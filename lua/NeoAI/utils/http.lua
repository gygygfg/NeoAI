--- HTTP 客户端
--- @module NeoAI.utils.http
--- 基于 curl + vim.fn.jobstart 的异步 HTTP 客户端。
--- - 非阻塞：进程在后台运行，回调走 vim.schedule 进入主循环
--- - 支持流式（SSE）与普通请求
--- - 支持 AbortSignal：取消时直接 kill 进程
--- - 指数退避重试见 utils.async.retry

local async = require("NeoAI.utils.async")

local M = {}

-- ========== 私有工具 ==========

local function _which_curl()
  if vim.fn.executable("curl") ~= 1 then
    return nil
  end
  return vim.fn.exepath("curl")
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
  local args = { "-sS", "--no-buffer", "--max-time", tostring((opts.timeout_ms or 30000) / 1000) }
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
local function _parse_sse(buffer)
  local events = {}
  local rest = buffer
  while true do
    local data_start = rest:find("data: ")
    if not data_start then break end
    local line_end = rest:find("\n", data_start, true)
    local line = line_end and rest:sub(data_start + 6, line_end - 1) or rest:sub(data_start + 6)
    if line == "[DONE]" then
      events[#events + 1] = { type = "done" }
      rest = line_end and rest:sub(line_end + 1) or ""
      break
    end
    events[#events + 1] = { type = "data", data = line }
    if line_end then
      rest = rest:sub(line_end + 1)
    else
      rest = ""
      break
    end
  end
  return events, rest
end

-- ========== 公共 API ==========

--- 发起 HTTP 请求
--- @param opts table { base_url, path?, method?, headers?, query?, body?, timeout_ms?, stream? }
--- @param callbacks table|nil { on_chunk?: fun(data: string, done: boolean), signal? }
--- @return Deferred resolve(响应体字符串), reject(错误)
function M.request(opts, callbacks)
  callbacks = callbacks or {}
  local curl = _which_curl()
  if not curl then
    return async.reject({ kind = "http", message = "curl 不可用，无法发送 HTTP 请求" })
  end

  local args, stdin_body = _build_args(opts)
  local stdout = {}
  local stderr = {}
  local done = false
  local chunk_acc = ""

  local d = async.Deferred.new()
  local cleanup_unsub = function() end

  if callbacks.signal then
    cleanup_unsub = callbacks.signal:subscribe(function(reason)
      if job and vim.fn.job_status(job) == "run" then
        pcall(vim.fn.chanclose, job)
        pcall(vim.fn.jobstop, job)
      end
      if not done then
        done = true
        d:reject({ kind = "aborted", message = reason })
      end
    end)
  end

  local job = vim.fn.jobstart({
    curl,
    unpack(args),
  }, {
    stdin = stdin_body and "pipe" or nil,
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if done then return end
      if opts.stream then
        for _, line in ipairs(data or {}) do
          if line ~= "" then
            chunk_acc = chunk_acc .. line .. "\n"
            local events, rest = _parse_sse(chunk_acc)
            chunk_acc = rest
            for _, ev in ipairs(events) do
              if ev.type == "done" then
                -- 结束标记，等待 on_exit 最终 resolve
              elseif ev.type == "data" and callbacks.on_chunk then
                callbacks.on_chunk(ev.data, false)
              end
            end
          end
        end
      else
        for _, line in ipairs(data or {}) do
          if line ~= "" then stdout[#stdout + 1] = line end
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      if done then return end
      done = true
      cleanup_unsub()
      if opts.stream and callbacks.on_chunk then
        -- 消费剩余缓冲
        if chunk_acc and chunk_acc ~= "" then
          local events, _ = _parse_sse(chunk_acc)
          for _, ev in ipairs(events) do
            if ev.type == "data" then callbacks.on_chunk(ev.data, false) end
          end
        end
        callbacks.on_chunk(nil, true)
      end
      if code == 0 then
        local body = table.concat(stdout, "\n")
        d:resolve(body)
      else
        local err_msg = table.concat(stderr, "\n")
        if err_msg == "" then err_msg = "curl 退出码 " .. tostring(code) end
        d:reject({ kind = "http", status = code, message = err_msg, body = table.concat(stdout, "\n") })
      end
    end,
  })

  if job <= 0 then
    done = true
    cleanup_unsub()
    return async.reject({ kind = "http", message = "无法启动 curl 进程" })
  end

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
