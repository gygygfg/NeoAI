--- HTTP SSE 解析测试
--- @module NeoAI.tests.test_http
--- 回归：SSE data 行跨多次 on_stdout 回调拆分时不得丢失事件。
--- （nvim job on_stdout 元素之间表示换行；首尾可能为跨回调的行片段。
---  旧实现把无换行的片段当完整行消费 → 工具调用/内容增量丢失 →
---  表现为"工具调用返回后不再进入下一轮"。）

local tests = require("NeoAI.tests")

tests.suite("http", function(_, it)
  it("真实 HTTP：event/data 相邻行与跨包 UTF-8 完整交付", function(t)
    local server = require("NeoAI.tests.http_server")
    local expected = '{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}'
    local split = expected:find("你好", 1, true) + 1
    server.with_server(function(client)
      client:write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
        .. "event: content_block_delta\ndata: " .. expected:sub(1, split))
      vim.defer_fn(function()
        if client:is_closing() then return end
        client:write(expected:sub(split + 1) .. "\n\ndata: [DONE]\n\ndata: ignored\n\n")
        client:shutdown(function() if not client:is_closing() then client:close() end end)
      end, 30)
    end, function(base)
      local chunks, finished = {}, 0
      local body = t.await(require("NeoAI.utils.http").request({ base_url = base, stream = true }, {
        on_chunk = function(chunk, done)
          if done then finished = finished + 1 else chunks[#chunks + 1] = chunk end
        end,
      }))
      t.deep_eq({ expected }, chunks)
      t.eq(1, finished)
      t.eq("", body, "流式成功不返回重复的原始响应")
    end)
  end)

  it("真实 HTTP：普通响应跨包重组逐字节一致（含空行/尾换行）", function(t)
    local server = require("NeoAI.tests.http_server")
    local first = '{"content":"' .. string.rep("a", 8192) .. "\228"
    local second = '\189\160"}\n\n'
    server.with_server(function(client)
      client:write("HTTP/1.1 200 OK\r\nContent-Length: " .. (#first + #second)
        .. "\r\nX-Test: value\r\n\r\n" .. first)
      vim.defer_fn(function()
        if client:is_closing() then return end
        client:write(second)
      end, 30)
    end, function(base)
      local opts = { base_url = base, include_headers = true }
      local response = t.await(require("NeoAI.utils.http").request(opts))
      t.eq(first .. second, response.body)
      t.eq("value", response.headers["x-test"])
      t.nil_(opts._dump_headers_path)
    end)
  end)

  it("真实 HTTP：取消停止 curl、清理头部文件，预取消不启动进程", function(t)
    local server = require("NeoAI.tests.http_server")
    local async = require("NeoAI.utils.async")
    local original = vim.fn.jobstart
    local job, header_path, starts = nil, nil, 0
    local ok, err = xpcall(function()
      vim.fn.jobstart = function(argv, opts)
        starts = starts + 1
        for i, arg in ipairs(argv) do
          if arg == "--dump-header" then header_path = argv[i + 1] end
        end
        job = original(argv, opts)
        return job
      end
      local ready = false
      server.with_server(function(client)
        client:write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
        ready = true
      end, function(base)
        local signal = async.create_signal()
        local d = require("NeoAI.utils.http").request({ base_url = base, stream = true, include_headers = true }, { signal = signal })
        t.true_(vim.wait(3000, function() return ready end, 10))
        signal:abort("cancel")
        t.eq("aborted", d._error.kind)
        t.true_(vim.wait(3000, function() return vim.fn.jobwait({ job }, 0)[1] ~= -1 end, 10))
        t.eq(0, vim.fn.filereadable(header_path))
        local rejected = require("NeoAI.utils.http").request({ base_url = base }, { signal = signal })
        t.await(rejected:catch(function(e) t.eq("aborted", e.kind) end))
        t.eq(1, starts)
      end)
    end, function(e) return e end)
    vim.fn.jobstart = original
    if job then pcall(vim.fn.jobstop, job) end
    if not ok then error(err, 0) end
  end)

  it("真实 HTTP：大流式响应不返回副本，错误体有界且不发送成功结束事件", function(t)
    local server = require("NeoAI.tests.http_server")
    local http = require("NeoAI.utils.http")
    local payload = string.rep("data: " .. string.rep("x", 1000) .. "\n\n", 200)
    server.with_server(function(client) server.respond(client, payload) end, function(base)
      local count = 0
      local body = t.await(http.request({ base_url = base, stream = true }, {
        on_chunk = function(chunk) if chunk then count = count + 1 end end,
      }))
      t.eq(200, count)
      t.eq("", body)
    end)
    server.with_server(function(client)
      server.respond(client, '{"error":"context length exceeded ' .. string.rep("x", 200000) .. '"}', "400 Bad Request")
    end, function(base)
      local ended = false
      local failure
      t.await(http.request({ base_url = base, stream = true }, {
        on_chunk = function(_, done) ended = ended or done end,
      }):catch(function(e) failure = e end))
      t.not_nil(failure)
      t.eq(400, failure.status)
      t.true_(#failure.body <= 64 * 1024)
      t.true_(failure.body_truncated)
      t.matches("context length exceeded", failure.body)
      t.false_(ended)
    end)
  end)

  it("真实 HTTP：on_chunk 异常拒绝请求而非永久挂起", function(t)
    local server = require("NeoAI.tests.http_server")
    server.with_server(function(client) server.respond(client, "data: test\n\n") end, function(base)
      local failure
      t.await(require("NeoAI.utils.http").request({ base_url = base, stream = true }, {
        on_chunk = function() error("callback failed") end,
      }):catch(function(e) failure = e end))
      t.eq("callback", failure.kind)
    end)
  end)

  it("真实 HTTP：同一批 SSE 中取消后不再交付剩余事件", function(t)
    local server = require("NeoAI.tests.http_server")
    server.with_server(function(client)
      server.respond(client, "data: first\n\ndata: second\n\n")
    end, function(base)
      local signal = require("NeoAI.utils.async").create_signal()
      local count, failure = 0, nil
      t.await(require("NeoAI.utils.http").request({ base_url = base, stream = true }, {
        signal = signal,
        on_chunk = function() count = count + 1; signal:abort("stop") end,
      }):catch(function(e) failure = e end))
      t.eq(1, count)
      t.eq("aborted", failure.kind)
    end)
  end)

  it("真实请求链：首分片前失败可重试，已交付增量后不重复生成", function(t)
    local server = require("NeoAI.tests.http_server")
    local config = require("NeoAI.kernel.config_store")
    local saved = vim.deepcopy(config.get_all() or {})
    local ok, err = xpcall(function()
      for _, partial in ipairs({ false, true }) do
        local requests, chunks = 0, {}
        server.with_server(function(client)
          requests = requests + 1
          if requests == 1 then
            if partial then
              -- 声明的 Content-Length 大于实际正文：curl 以 18 退出。
              client:write('HTTP/1.1 200 OK\r\nContent-Length: 9999\r\n\r\ndata: {"choices":[{"delta":{"content":"partial"}}]}\n\n')
              client:shutdown(function() if not client:is_closing() then client:close() end end)
            else
              server.respond(client, '{"error":"temporary"}', "500 Internal Server Error")
            end
          else
            server.respond(client, 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
          end
        end, function(base)
          config.load({ ai = { providers = { http_test = { api_type = "openai", base_url = base, api_key = "test" } }, model_policy = { explicit_cache = { enabled = false } } } })
          local failure, response
          t.await(require("NeoAI.core.agent.request").send_stream({ { role = "user", content = "hello" } }, {
            model = "test", agent_config = { provider = "http_test" }, max_retries = 2,
          }, function(chunk) if chunk.content then chunks[#chunks + 1] = chunk.content end end):then_(
            function(r) response = r end, function(e) failure = e end))
          if partial then
            t.eq(1, requests)
            t.deep_eq({ "partial" }, chunks)
            t.eq("http", failure.kind)
          else
            t.eq(2, requests)
            t.nil_(failure)
            t.eq("ok", response.content)
            t.deep_eq({ "ok" }, chunks)
          end
        end)
      end
    end, function(e) return e end)
    config.load(saved)
    if not ok then error(err, 0) end
  end)

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
