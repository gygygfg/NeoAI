--- 会话内 Docker HTTP 解析/规范化测试
local tests = require("NeoAI.tests")

tests.suite("sandbox_docker_http", function(_, it)
  local http = require("NeoAI.sandbox.docker.http")

  it("解析 GET 与 POST Content-Length", function(t)
    local req, used, err = http.parse_request("GET /v1.43/_ping HTTP/1.1\r\nHost: docker\r\n\r\n")
    t.eq(nil, err)
    t.eq("GET", req.method)
    t.eq("/v1.43/_ping", req.path)
    t.eq(#"GET /v1.43/_ping HTTP/1.1\r\nHost: docker\r\n\r\n", used)

    local body = '{"Image":"alpine"}'
    local post, used2 = http.parse_request(
      "POST /containers/create HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body)
    t.eq("POST", post.method)
    t.eq(body, post.body)
    local raw_post = "POST /containers/create HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
    t.eq(#raw_post, used2)
  end)

  it("不完整请求返回 INCOMPLETE，非法 Content-Length 拒绝", function(t)
    local req, _, err = http.parse_request("POST /containers/create HTTP/1.1\r\nContent-Length: 10\r\n\r\n{")
    t.eq(nil, req)
    t.eq("INCOMPLETE", err)
    local req2, _, err2 = http.parse_request("POST / HTTP/1.1\r\nContent-Length: 1x\r\n\r\n")
    t.eq(nil, req2)
    t.eq("BAD_CONTENT_LENGTH", err2)
  end)

  it("拒绝 Content-Length 与 Transfer-Encoding 混淆", function(t)
    local req, _, err = http.parse_request(
      "POST /containers/create HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
    t.eq(nil, req)
    t.eq("AMBIGUOUS_BODY", err)
  end)

  it("支持 chunked 请求体", function(t)
    local req, _, err = http.parse_request(
      "POST /containers/create HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        .. "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
    t.eq(nil, err)
    t.eq("hello world", req.body)
  end)

  it("路径规范化：剥离版本前缀并拒绝穿越", function(t)
    local info, err = http.normalize_path("/v1.43/containers/abc/json")
    t.eq(nil, err)
    t.eq("/containers/abc/json", info.path)
    t.eq("v1.43", info.version_prefix)
    local bad, berr = http.normalize_path("/v1.43/containers/../etc/json")
    t.eq(nil, bad)
    t.eq("PATH_TRAVERSAL", berr)
    local enc, eerr = http.normalize_path("/containers/%2e%2e/json")
    t.eq(nil, enc)
    t.eq("PATH_TRAVERSAL", eerr)
  end)

  it("重新编码会去掉 hop-by-hop 并重算长度", function(t)
    local raw = http.encode_request({
      method = "POST", path = "/containers/create",
      headers = { ["content-type"] = "application/json", connection = "keep-alive", ["content-length"] = "999" },
      body = "{}",
    })
    t.matches("^POST /containers/create HTTP/1.1\r\n", raw)
    t.matches("Connection: close", raw)
    t.matches("Content%-Length: 2", raw)
    t.false_(raw:find("Content%-Length: 999") ~= nil)
  end)
end)
