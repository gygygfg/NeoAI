--- Docker Engine API 的最小 HTTP/1.1 解析与规范化
--- @module 'NeoAI.sandbox.docker.http'
---
--- 只服务自研 Unix socket 代理：解析请求、做结构校验、**重新编码**后再转发上游。
--- 绝不把客户端原始字节直接透传（避免请求走私、重复 Content-Length、header 注入、
--- percent-encoding/path traversal 绕过 body 检查）。
---
--- 本模块无 I/O、无模块状态，可离线单测。

local M = {}

local MAX_HEADER_BYTES = 32 * 1024
local MAX_BODY_BYTES = 8 * 1024 * 1024
local MAX_CHUNK_LINE = 4096

-- ========== 私有函数 ==========

--- percent-decode 单个路径段；拒绝编码后的 `/`、`\`、NUL（不允许借编码改变段结构）。
--- @param s string
--- @return string|nil
local function _decode_segment(s)
  if s:find("%z") then return nil end
  local out = s:gsub("%%(%x%x)", function(hex)
    local b = tonumber(hex, 16)
    if b == 0x2f or b == 0x5c or b == 0 then
      return "\0" -- 标记非法，下方拒绝
    end
    return string.char(b)
  end)
  if out:find("%z") then return nil end
  return out
end

--- 解析 header 区块（不含结尾空行）。
--- @param text string
--- @return table|nil headers
--- @return string|nil err
local function _parse_headers(text)
  local headers = {}
  if text == "" then return headers end
  for line in (text .. "\r\n"):gmatch("(.-)\r\n") do
    if line == "" then break end
    if line:sub(1, 1) == " " or line:sub(1, 1) == "\t" then
      return nil, "OBS_FOLD"
    end
    local name, value = line:match("^([^:]+):[ \t]*(.*)$")
    if not name or name == "" then return nil, "BAD_HEADER" end
    name = name:lower()
    if not name:match("^[%w!#%$%%&'%*%+%-%._%^_`|~]+$") then
      return nil, "BAD_HEADER_NAME"
    end
    if headers[name] ~= nil then
      -- 重复 header：按逗号合并（Content-Length/Transfer-Encoding 在调用方单独拒绝）
      headers[name] = headers[name] .. ", " .. value
    else
      headers[name] = value
    end
  end
  return headers, nil
end

--- 解码 chunked 请求体（仅请求方向；拒绝非法 chunk）。
--- @param data string
--- @param max_bytes number
--- @return string|nil body
--- @return number|nil consumed
--- @return string|nil err
local function _decode_chunked(data, max_bytes)
  local pos = 1
  local out = {}
  local total = 0
  while true do
    local line_end = data:find("\r\n", pos, true)
    if not line_end then return nil, nil, "INCOMPLETE" end
    local line = data:sub(pos, line_end - 1)
    if #line > MAX_CHUNK_LINE then return nil, nil, "CHUNK_LINE_TOO_LONG" end
    local hex = line:match("^([0-9a-fA-F]+)")
    if not hex then return nil, nil, "BAD_CHUNK_SIZE" end
    local size = tonumber(hex, 16)
    if not size then return nil, nil, "BAD_CHUNK_SIZE" end
    pos = line_end + 2
    if size == 0 then
      -- trailer：读到空行
      while true do
        local te = data:find("\r\n", pos, true)
        if not te then return nil, nil, "INCOMPLETE" end
        if te == pos then
          pos = pos + 2
          return table.concat(out), pos - 1, nil
        end
        pos = te + 2
      end
    end
    total = total + size
    if total > max_bytes then return nil, nil, "BODY_TOO_LARGE" end
    if #data < pos + size + 1 then return nil, nil, "INCOMPLETE" end
    out[#out + 1] = data:sub(pos, pos + size - 1)
    if data:sub(pos + size, pos + size + 1) ~= "\r\n" then
      return nil, nil, "BAD_CHUNK_TERMINATOR"
    end
    pos = pos + size + 2
  end
end

-- ========== 公开 API ==========

--- 解析一个完整/不完整的 HTTP 请求。
--- @param buf string 当前缓冲区
--- @param opts table|nil { max_header_bytes?, max_body_bytes? }
--- @return table|nil req { method, path, version, headers, body }
--- @return number|nil consumed 已消费字节数（req 非 nil 时）
--- @return string|nil err "INCOMPLETE" 或具体错误
function M.parse_request(buf, opts)
  opts = opts or {}
  local max_header = tonumber(opts.max_header_bytes) or MAX_HEADER_BYTES
  local max_body = tonumber(opts.max_body_bytes) or MAX_BODY_BYTES

  local header_end = buf:find("\r\n\r\n", 1, true)
  if not header_end then
    if #buf > max_header then return nil, nil, "HEADER_TOO_LARGE" end
    return nil, nil, "INCOMPLETE"
  end
  if header_end - 1 > max_header then return nil, nil, "HEADER_TOO_LARGE" end
  local head = buf:sub(1, header_end - 1)
  local rest = buf:sub(header_end + 4)

  local first_end = head:find("\r\n", 1, true)
  local request_line = first_end and head:sub(1, first_end - 1) or head
  local method, target, version = request_line:match("^([A-Z]+) ([^ ]+) HTTP/(%d+%.%d+)$")
  if not method then return nil, nil, "BAD_REQUEST_LINE" end
  if version ~= "1.1" and version ~= "1.0" then return nil, nil, "BAD_HTTP_VERSION" end
  if #target > 8192 then return nil, nil, "TARGET_TOO_LONG" end

  local header_text = first_end and head:sub(first_end + 2) or ""
  local headers, herr = _parse_headers(header_text)
  if not headers then return nil, nil, herr end
  if headers["content-length"] and headers["transfer-encoding"] then
    return nil, nil, "AMBIGUOUS_BODY"
  end

  local body = ""
  local body_bytes = 0
  if headers["transfer-encoding"] then
    if headers["transfer-encoding"]:lower() ~= "chunked" then
      return nil, nil, "UNSUPPORTED_TRANSFER_ENCODING"
    end
    local decoded, used, derr = _decode_chunked(rest, max_body)
    if not decoded then
      if derr == "INCOMPLETE" then return nil, nil, "INCOMPLETE" end
      return nil, nil, derr
    end
    body = decoded
    body_bytes = used
  elseif headers["content-length"] then
    local cl = headers["content-length"]:match("^%s*(%d+)%s*$")
    if not cl then return nil, nil, "BAD_CONTENT_LENGTH" end
    local n = tonumber(cl)
    if not n or n < 0 then return nil, nil, "BAD_CONTENT_LENGTH" end
    if n > max_body then return nil, nil, "BODY_TOO_LARGE" end
    if #rest < n then return nil, nil, "INCOMPLETE" end
    body = rest:sub(1, n)
    body_bytes = n
  end

  local consumed = header_end + 3 + body_bytes
  return {
    method = method,
    path = target,
    version = version,
    headers = headers,
    body = body,
  }, consumed, nil
end

--- 规范化请求路径：剥离 `/v1.xx` 版本前缀，解码段，拒绝路径穿越。
--- @param path string
--- @return table|nil info { path, segments, version_prefix }
--- @return string|nil err
function M.normalize_path(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" then
    return nil, "BAD_PATH"
  end
  local query = path:find("?", 1, true)
  local raw_path = query and path:sub(1, query - 1) or path
  local raw_query = query and path:sub(query) or ""
  if raw_path:find("//", 1, true) then return nil, "BAD_PATH" end
  if raw_path:find("\\", 1, true) then return nil, "BAD_PATH" end

  local segs = {}
  for part in raw_path:gmatch("[^/]+") do
    if part == "." or part == ".." then return nil, "PATH_TRAVERSAL" end
    local decoded = _decode_segment(part)
    if not decoded then return nil, "PATH_TRAVERSAL" end
    if decoded == "." or decoded == ".." then return nil, "PATH_TRAVERSAL" end
    segs[#segs + 1] = decoded
  end

  local version_prefix = nil
  if segs[1] and segs[1]:match("^v%d+%.%d+$") then
    version_prefix = table.remove(segs, 1)
  end
  if #segs == 0 then return nil, "BAD_PATH" end
  return {
    path = "/" .. table.concat(segs, "/"),
    segments = segs,
    version_prefix = version_prefix,
    query = raw_query,
  }, nil
end

--- 生成上游请求字节（Connection: close，代理对每个客户端请求开一条上游连接）。
--- @param req table
--- @param opts table|nil { keep_headers?: table<string,boolean> }
--- @return string
function M.encode_request(req, opts)
  opts = opts or {}
  local headers = {}
  local skip = {
    host = true, connection = true, ["content-length"] = true, ["transfer-encoding"] = true,
    keepalive = true, ["proxy-connection"] = true, te = true, trailer = true,
    upgrade = true,
  }
  if opts.keep_upgrade then
    skip.connection = nil
    skip.upgrade = nil
  end
  for k, v in pairs(req.headers or {}) do
    if not skip[k] and not (opts.drop_headers and opts.drop_headers[k]) then
      headers[#headers + 1] = k .. ": " .. tostring(v)
    end
  end
  headers[#headers + 1] = "Host: docker"
  if not opts.keep_upgrade then
    headers[#headers + 1] = "Connection: close"
  end
  local body = req.body or ""
  if #body > 0 or req.method == "POST" or req.method == "PUT" then
    headers[#headers + 1] = "Content-Length: " .. tostring(#body)
  end
  return table.concat({
    req.method .. " " .. req.path .. " HTTP/1.1",
    table.concat(headers, "\r\n"),
    "",
    body,
  }, "\r\n")
end

--- 解析 JSON body（失败返回 nil + 原因）。
--- @param body string
--- @return table|nil
--- @return string|nil
function M.decode_json(body)
  if type(body) ~= "string" or body == "" then return nil, "EMPTY_BODY" end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" then return nil, "BAD_JSON" end
  return decoded, nil
end

--- 构造 Docker 风格 JSON 错误响应。
--- @param status number
--- @param message string
--- @return string
function M.error_response(status, message)
  local body = vim.json.encode({ message = tostring(message or "error") })
  local reason = ({
    [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found",
    [405] = "Method Not Allowed", [413] = "Payload Too Large",
    [500] = "Internal Server Error", [502] = "Bad Gateway",
  })[status] or "Error"
  return table.concat({
    ("HTTP/1.1 %d %s"):format(status, reason),
    "Content-Type: application/json",
    "Content-Length: " .. tostring(#body),
    "Connection: close",
    "",
    body,
  }, "\r\n")
end

--- 构造成功 JSON 响应（仅内部端点/测试用）。
--- @param status number
--- @param obj table
--- @return string
function M.json_response(status, obj)
  local body = vim.json.encode(obj or {})
  return table.concat({
    ("HTTP/1.1 %d OK"):format(status),
    "Content-Type: application/json",
    "Content-Length: " .. tostring(#body),
    "Connection: close",
    "",
    body,
  }, "\r\n")
end

M.MAX_HEADER_BYTES = MAX_HEADER_BYTES
M.MAX_BODY_BYTES = MAX_BODY_BYTES

return M
