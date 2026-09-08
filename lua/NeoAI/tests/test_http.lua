--- HTTP SSE 解析测试
--- @module NeoAI.tests.test_http
--- 回归：SSE data 行跨多次 on_stdout 回调拆分时不得丢失事件。
--- （nvim job on_stdout 以空串元素标记行尾；行片段可能不带换行到达。
---  旧实现把无换行的片段当完整行消费 → 工具调用/内容增量丢失 →
---  表现为"工具调用返回后不再进入下一轮"。）

local tests = require("NeoAI.tests")

tests.suite("http", function(_, it)
  it("完整 data 行逐事件解析", function(t)
    local http = require("NeoAI.utils.http")
    local events, rest = http._parse_sse('data: {"a":1}\n\ndata: {"b":2}\n\n')
    t.eq(2, #events)
    t.eq("data", events[1].type)
    t.eq('{"a":1}', events[1].data)
    t.eq('{"b":2}', events[2].data)
    -- rest 只含空白分隔行（无 data 前缀，后续解析自动跳过），不得残留事件内容
    t.true_(rest:match("^%s*$") ~= nil, "rest 应为空白，实际 " .. vim.inspect(rest))
  end)

  it("跨缓冲区拆分的 data 行被重组（核心回归）", function(t)
    local http = require("NeoAI.utils.http")
    -- 模拟 nvim on_stdout：先到 "data: PART1"（无换行），再到 "PART2\n"（行尾补全）
    local acc = ""
    local function feed(chunk)
      acc = acc .. chunk
      local events, rest = http._parse_sse(acc)
      acc = rest
      return events
    end
    -- 片段 1：无行尾换行 → 不应产生事件，片段保留在缓冲中
    local e1 = feed('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a",')
    t.eq(0, #e1, "无行尾换行的片段不应被当作完整事件消费")
    -- 片段 2：行尾补齐 → 事件完整重组
    local e2 = feed('"function":{"name":"tool_a","arguments":"{}"}}]}}]}\n\n')
    t.eq(1, #e2)
    t.matches('tool_calls', e2[1].data)
    t.matches('call_a', e2[1].data)
    -- 片段 3：后续事件照常解析
    local e3 = feed('data: [DONE]\n\n')
    t.eq(1, #e3)
    t.eq("done", e3[1].type)
  end)

  it("流结束补 \n 后末行（无行尾换行）仍被解析", function(t)
    local http = require("NeoAI.utils.http")
    local events = http._parse_sse('data: {"content":"tail"}')
    t.eq(0, #events, "缺行尾换行时保持缓冲")
    -- on_exit 兜底：补一个换行再解析
    local events2 = http._parse_sse('data: {"content":"tail"}\n')
    t.eq(1, #events2)
    t.eq('{"content":"tail"}', events2[1].data)
  end)

  it("CRLF 行尾兼容", function(t)
    local http = require("NeoAI.utils.http")
    local events = http._parse_sse('data: {"a":1}\r\n\ndata: {"b":2}\r\n\n')
    t.eq(2, #events)
    t.eq('{"a":1}', events[1].data)
    t.eq('{"b":2}', events[2].data)
  end)

  it("无空格 data:兼容（MCP streamable HTTP）", function(t)
    local http = require("NeoAI.utils.http")
    local events = http._parse_sse('data:{"jsonrpc":"2.0","id":1}\n\ndata:{"jsonrpc":"2.0","id":2}\n\n')
    t.eq(2, #events)
    t.eq('{"jsonrpc":"2.0","id":1}', events[1].data)
    t.eq('{"jsonrpc":"2.0","id":2}', events[2].data)
  end)

  it("[DONE] 终止并丢弃其后内容", function(t)
    local http = require("NeoAI.utils.http")
    local events, rest = http._parse_sse('data: {"a":1}\n\ndata: [DONE]\n\ngarbage')
    t.eq(2, #events)
    t.eq("done", events[2].type)
    -- [DONE] 之后的垃圾不被解析为事件
    t.true_(rest:find("garbage") ~= nil)
    local more = http._parse_sse(rest)
    t.eq(0, #more)
  end)

  it("多事件单缓冲 + 末尾未完成行：完整事件先出，片段保留", function(t)
    local http = require("NeoAI.utils.http")
    local events, rest = http._parse_sse('data: {"a":1}\n\ndata: {"b":2}\n\ndata: {"par')
    t.eq(2, #events)
    t.true_(rest:find('data: {"par') ~= nil, "未完成行保留在 rest 等待补齐，实际 " .. vim.inspect(rest))
    local events2, rest2 = http._parse_sse(rest .. 'tial":3}\n\n')
    t.eq(1, #events2)
    t.eq('{"partial":3}', events2[1].data)
    t.true_(rest2:match("^%s*$") ~= nil, "rest2 应为空白")
  end)

  it("请求体含非法 UTF-8 字节时被清洗为合法 JSON（回归 BUG-4）", function(t)
    local json = require("NeoAI.utils.json")
    -- vim.json.encode 原样透传非法字节（如 0xff、孤立的替换字符首字节），
    -- 导致服务端报 "invalid unicode code point"。编码前必须清洗为合法 UTF-8。
    local raw = "hi \xff \xc3\xa9" -- 非法 0xff + 合法 é
    local body = json.encode({ messages = { { role = "user", content = raw } } })
    -- 输出必须能被子 JSON 解析器（解码）接受：无未转义非法字节
    local ok, obj = pcall(json.decode, body)
    t.true_(ok, "编码后 JSON 不得含非法字节，无法解析: " .. tostring(obj))
    t.eq("hi \xef\xbf\xbd \xc3\xa9", obj.messages[1].content, "非法字节应替换为 U+FFFD，合法 UTF-8 保留")
    -- 扁平内容（tool 结果、助手消息）同样被清洗
    local body2 = json.encode({ a = "x \xc3", b = { "\xed\xa0\x80" } })
    local ok2, obj2 = pcall(json.decode, body2)
    t.true_(ok2, "嵌套非法字节同样被清洗: " .. tostring(obj2))
  end)
end)
