--- 测试专用真实 TCP/HTTP 服务：随机端口、无 Python/外网依赖、总是释放连接。
local M = {}

function M.with_server(handler, fn)
  local server = assert(vim.uv.new_tcp())
  assert(server:bind("127.0.0.1", 0))
  local clients = {}
  assert(server:listen(16, function(err)
    assert(not err, err)
    local client = assert(vim.uv.new_tcp())
    clients[#clients + 1] = client
    assert(server:accept(client))
    local request = ""
    local handled = false
    client:read_start(vim.schedule_wrap(function(read_err, data)
      if client:is_closing() then return end
      if read_err or not data then client:close(); return end
      request = request .. data
      local header_end = request:find("\r\n\r\n", 1, true)
      local length = header_end and tonumber(request:sub(1, header_end):lower():match("content%-length:%s*(%d+)")) or 0
      if not handled and header_end and #request >= header_end + 3 + length then
        handled = true
        handler(client, request)
      end
    end))
  end))
  local ok, err = xpcall(function()
    fn("http://127.0.0.1:" .. server:getsockname().port)
  end, function(e) return e end)
  for _, client in ipairs(clients) do
    if not client:is_closing() then client:close() end
  end
  if not server:is_closing() then server:close() end
  if not ok then error(err, 0) end
end

function M.respond(client, body, status, headers)
  client:write("HTTP/1.1 " .. (status or "200 OK") .. "\r\nContent-Length: " .. #body
    .. "\r\nConnection: close\r\n" .. (headers or "") .. "\r\n" .. body)
  client:shutdown(function() if not client:is_closing() then client:close() end end)
end

return M
