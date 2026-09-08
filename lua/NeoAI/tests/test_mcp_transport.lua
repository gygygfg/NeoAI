--- MCP 传输层测试（stdio 帧解析 / HTTP SSE body 解析 / header 大小写无关）
--- @module NeoAI.tests.test_mcp_transport

local tests = require("NeoAI.tests")

tests.suite("mcp_transport", function(_, it)
  it("stdio 单行 JSON 解码并分发到 on_message", function(t)
    local transports = require("NeoAI.services.mcp.transports")
    local tr = transports.stdio({ command = "x" }, { name = "t" })
    tr.open_ = true
    local got = {}
    tr.on_message = function(m) got[#got + 1] = m end
    tr:_emit_line('{"jsonrpc":"2.0","id":1,"result":{"ok":true}}')
    t.eq(1, #got)
    t.eq(1, got[1].id)
    t.eq(true, got[1].result.ok)
  end)

  it("stdio 非法 JSON 行不崩溃（仅告警）", function(t)
    local transports = require("NeoAI.services.mcp.transports")
    local tr = transports.stdio({ command = "x" }, { name = "t" })
    tr.open_ = true
    local got = 0
    tr.on_message = function() got = got + 1 end
    local ok = pcall(function() tr:_emit_line("not valid json") end)
    t.true_(ok, "非法行不应抛错")
    t.eq(0, got)
  end)

  it("stdio 发送按行加换行", function(t)
    local transports = require("NeoAI.services.mcp.transports")
    local tr = transports.stdio({ command = "x" }, { name = "t" })
    tr.open_ = true
    tr.job = -1 -- 非运行态，仅验证入队；_schedule_flush 在 job 非 run 时丢弃
    tr._out = {}
    tr:send('{"jsonrpc":"2.0","id":1,"method":"ping"}')
    t.eq('{"jsonrpc":"2.0","id":1,"method":"ping"}\n', tr._out[1])
  end)

  it("HTTP SSE body 逐条 data 消息分发", function(t)
    local transports = require("NeoAI.services.mcp.transports")
    local tr = transports.http({ url = "http://x/mcp", headers = {} }, { name = "t" })
    local got = {}
    tr.on_message = function(m) got[#got + 1] = m end
    tr:_parse_sse_body('data: {"jsonrpc":"2.0","id":1,"result":{"a":1}}\ndata: {"jsonrpc":"2.0","id":2,"method":"m"}\n')
    t.eq(2, #got)
    t.eq(1, got[1].id)
    t.eq("m", got[2].method)
  end)

  it("HTTP SSE 兼容无空格 data:", function(t)
    local transports = require("NeoAI.services.mcp.transports")
    local tr = transports.http({ url = "http://x/mcp", headers = {} }, { name = "t" })
    local got = {}
    tr.on_message = function(m) got[#got + 1] = m end
    tr:_parse_sse_body('data:{"jsonrpc":"2.0","id":9,"result":true}\n')
    t.eq(1, #got)
    t.eq(9, got[1].id)
  end)

  it("HTTP 响应头大小写不敏感读取", function(t)
    local transports = require("NeoAI.services.mcp.transports")
    t.eq("abc", transports._header_caseless({ ["Mcp-Session-Id"] = "abc" }, "mcp-session-id"))
    t.eq("text/event-stream", transports._header_caseless({ ["Content-Type"] = "text/event-stream" }, "content-type"))
    t.eq(nil, transports._header_caseless({}, "content-type"))
  end)

  it("create 按 transport 字段选择传输", function(t)
    local transports = require("NeoAI.services.mcp.transports")
    local a = transports.create({ transport = "stdio", command = "x" }, { name = "a" })
    t.eq("stdio", a.transport)
    t.eq("x", a.command)
    local b = transports.create({ transport = "http", url = "http://x" }, { name = "b" })
    t.eq("http", b.transport)
    t.eq("http://x", b.url)
    t.eq(false, b:is_open())
    b:open()
    t.eq(true, b:is_open())
  end)
end)
