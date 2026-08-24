--- 集成测试
--- @module NeoAI.tests.test_integration
--- 完整流程：Agent 生成 → 工具调用 → 工具执行 → 最终回复。
--- 使用内置 mock LLM server（jobstart），不依赖外部网络。

local tests = require("NeoAI.tests")

local MOCK_SERVER = [[
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        msgs = req.get("messages", [])
        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        if not has_tool_result:
            first = 'data: ' + json.dumps({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"mock_add","arguments":"{\"a\":1,\"b\":2}"}}]}}]})
        else:
            first = 'data: ' + json.dumps({"choices":[{"delta":{"content":"the sum is 3"}}]})
        second = 'data: ' + json.dumps({"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}})
        resp = first + "\n\n" + second + "\n\n" + "data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(resp.encode())))
        self.end_headers()
        self.wfile.write(resp.encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8950), H).serve_forever()
]]

tests.suite("integration", function(_, it)
  it("完整 Agent 生成流程（mock server）", function(t)
    local async = require("NeoAI.utils.async")
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "mock",
        providers = { mock = { api_type = "openai", base_url = "http://127.0.0.1:8950", api_key = "test" } },
      },
      tools = { approval = { mode = "auto_allow", per_tool = {} } },
      session = { save_path = "/tmp/neoai_test_int", file = "s.jsonl" },
    })

    local job = vim.fn.jobstart({ "python3", "-c", MOCK_SERVER }, { stdout_buffered = true })

    -- 注册 mock 工具
    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool(
      "mock_add", "adds numbers",
      { type = "object", properties = { a = { type = "number" }, b = { type = "number" } }, required = { "a", "b" } },
      function(args, on_success) on_success("sum is 3") end,
      { category = "system" }
    ))

    -- mock tool_service
    local tool_service = require("NeoAI.services.tool_service")

    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local agent = runtime.create({ scenario = "chat" })
    agent.tools = registry.list_as_map()

    runtime.run(agent, "calculate 1+2"):then_(function()
      t.eq("idle", agent.state)
      t.eq(4, #agent.messages) -- user, assistant(tool_call), tool, assistant(final)
      local last = agent.messages[#agent.messages]
      t.eq("assistant", last.role)
      t.eq("the sum is 3", last.content)
      t.ok(agent.usage.completion > 0)
      vim.fn.jobstop(job)
      print("  integration done")
    end):catch(function(e)
      vim.fn.jobstop(job)
      t.true_(false, "集成测试失败: " .. tostring(e.message or e))
      print("  integration error:", e.kind, e.message)
    end)
  end)

  it("取消生成（abort）", function(t)
    local async = require("NeoAI.utils.async")
    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local a = runtime.create({})
    runtime.abort(a, "cancel")
    t.eq("aborted", a.state)
    t.true_(a.signal:aborted())
  end)

  it("多个工具调用并行执行（审批串行不互相覆盖）", function(t)
    local async = require("NeoAI.utils.async")
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "mock2",
        providers = { mock2 = { api_type = "openai", base_url = "http://127.0.0.1:8951", api_key = "test" } },
        model_refresh = { on_startup = false },
        scenarios = { chat = { provider = "mock2", preset = "balanced" } },
      },
      tools = { approval = { mode = "prompt", per_tool = {}, timeout_ms = 5000 } },
      session = { save_path = "/tmp/neoai_test_int2", file = "s.jsonl" },
    })

    -- mock server：第 1 轮返回两个工具调用，第 2 轮返回最终文本
    local MOCK2 = [[
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        msgs = req.get("messages", [])
        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        if not has_tool_result:
            a = 'data: ' + json.dumps({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"tool_serial_a","arguments":"{}"}}]}}]})
            b = 'data: ' + json.dumps({"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"tool_serial_b","arguments":"{}"}}]}}]})
            first = a + "\n\n" + b + "\n\n"
            second = 'data: ' + json.dumps({"choices":[{"delta":{},"finish_reason":"tool_calls"}]})
        else:
            first = 'data: ' + json.dumps({"choices":[{"delta":{"content":"serial done"}}]})
            second = 'data: ' + json.dumps({"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}})
        resp = first + second + "\n\n" + "data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(resp.encode())))
        self.end_headers()
        self.wfile.write(resp.encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8951), H).serve_forever()
]]
    local job = vim.fn.jobstart({ "python3", "-c", MOCK2 }, { stdout_buffered = true })
    vim.wait(5000, function()
      local code = vim.fn.system("curl -sS --max-time 1 -o /dev/null -w '%{http_code}' http://127.0.0.1:8951/ 2>/dev/null")
      return code ~= "" and code ~= "000"
    end)

    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    local order = {}
    local b_started_before_a_done = false
    registry.register(helpers.define_tool(
      "tool_serial_a", "A", { type = "object", properties = {}, required = {} },
      function(args, on_success)
        order[#order + 1] = "a_start"
        async.sleep(60):then_(function()
          order[#order + 1] = "a_done"
          on_success("a ok")
        end)
      end
    ))
    registry.register(helpers.define_tool(
      "tool_serial_b", "B", { type = "object", properties = {}, required = {} },
      function(args, on_success)
        order[#order + 1] = "b_start"
        -- 并行：B 启动时 A 应仍在运行（a_done 尚未出现）
        local a_done_yet = false
        for _, o in ipairs(order) do
          if o == "a_done" then a_done_yet = true end
        end
        if not a_done_yet then b_started_before_a_done = true end
        on_success("b ok")
      end
    ))

    -- 审批 UI：延迟确认（模拟真实弹窗保持打开），验证审批串行：同一时刻至多一个弹窗
    local dialog_open = false
    local dialog_overlap = 0
    local show_order = {}
    local tool_service = require("NeoAI.services.tool_service")
    tool_service.set_approval_ui({
      show = function(config)
        if dialog_open then dialog_overlap = dialog_overlap + 1 end
        dialog_open = true
        show_order[#show_order + 1] = config.tool_name
        vim.schedule(function()
          dialog_open = false
          config.on_confirm()
        end)
      end,
      hide = function() end,
    })

    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local agent = runtime.create({ scenario = "chat" })
    agent.tools = registry.list_as_map()

    runtime.run(agent, "run both tools"):then_(function()
      t.eq(5, #agent.messages, "user, assistant(tool_call), tool, tool, assistant(final)")
      local last = agent.messages[#agent.messages]
      t.eq("assistant", last.role)
      t.eq("serial done", last.content)
      t.true_(b_started_before_a_done, "工具应并行执行：B 启动时 A 应仍在运行（审批串行不影响执行并行）")
      t.eq(0, dialog_overlap, "审批弹窗应串行：同一时刻至多一个")
      t.eq(2, #show_order)
      t.eq("tool_serial_a", show_order[1])
      t.eq("tool_serial_b", show_order[2])
      t.eq("idle", agent.state)
      vim.fn.jobstop(job)
      print("  parallel tools done")
    end):catch(function(e)
      vim.fn.jobstop(job)
      t.true_(false, "并行工具测试失败: " .. tostring(e.message or e))
      print("  parallel error:", e.kind, e.message)
    end)
  end)

  it("第二个 turn 工具调用可开启（assistant tool_calls 消息省略空 content）", function(t)
    -- 回归测试一：stream 字段。tool_loop 第二轮起（_send_round）曾漏传 stream=true，
    -- 请求体 stream=false 会让真实 API 以非流式 JSON 返回，客户端却按 SSE 解析，
    -- 全部事件丢失 -> 模型"未返回后续内容"（EMPTY_RESPONSE_MESSAGE），第二个 turn 无法开启。
    -- 回归测试二：带 tool_calls 的 assistant 消息发送 content:""（应为 null/省略），
    -- 要求严格的 API 会在后续轮次返回空输出，同样表现为 EMPTY_RESPONSE_MESSAGE。
    local config_store = require("NeoAI.kernel.config_store")
    local body_file = "/tmp/neoai_test_turn2_bodies.jsonl"
    os.remove(body_file)

    config_store.load({
      ai = {
        default_provider = "turn2",
        providers = { turn2 = { api_type = "openai", base_url = "http://127.0.0.1:8952", api_key = "test" } },
        model_refresh = { on_startup = false },
        scenarios = { chat = { provider = "turn2", preset = "balanced" } },
        context_cache = { enabled = false },
      },
      tools = { approval = { mode = "auto_allow", per_tool = {} } },
      session = { save_path = "/tmp/neoai_test_int_turn2", file = "s.jsonl" },
    })

    -- mock server：尊重请求体的 stream 字段（stream=false 返回非流式 JSON，仿真真实 API）。
    -- 记录每个请求体用于协议断言；turn1/turn2 首轮返回 tool_calls，随后返回最终文本
    local MOCK2 = [[
import http.server, json
def ev(o):
    return 'data: ' + json.dumps(o) + '\n\n'
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        msgs = req.get("messages", [])
        tool_msgs = [m for m in msgs if m.get("role") == "tool"]
        stream = bool(req.get("stream", False))
        with open("/tmp/neoai_test_turn2_bodies.jsonl", "a") as f:
            f.write(json.dumps({"stream": stream, "messages": msgs}) + "\n")
        n_user = sum(1 for m in msgs if m.get("role") == "user")
        needs_tool = (n_user == 1 and len(tool_msgs) == 0) or (n_user == 2 and len(tool_msgs) == 1)
        if needs_tool:
            name = "tool_turn1" if n_user == 1 else "tool_turn2"
            delta = {"tool_calls":[{"index":0,"id":"call_" + str(n_user),"function":{"name":name,"arguments":"{}"}}]}
            fin = "tool_calls"
        else:
            text = "final1" if n_user == 1 else "final2"
            delta = {"content": text}
            fin = "stop"
        if stream:
            parts = [ev({"choices":[{"delta": delta}]}),
                     ev({"choices":[{"delta":{},"finish_reason": fin}],"usage":{"prompt_tokens":10,"completion_tokens":5}})]
            resp = "".join(parts) + "data: [DONE]\n\n"
        else:
            # 请求体声明非流式：返回普通 JSON（若客户端仍按 SSE 解析会丢失全部事件）
            msg = {"role":"assistant"}
            if needs_tool:
                msg["tool_calls"] = [{"id":"call_" + str(n_user),"type":"function","function":{"name":name,"arguments":"{}"}}]
            else:
                msg["content"] = text
            resp = json.dumps({"choices":[{"message": msg, "finish_reason": fin}],"usage":{"prompt_tokens":10,"completion_tokens":5}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if stream else "application/json")
        self.send_header("Content-Length", str(len(resp.encode())))
        self.end_headers()
        self.wfile.write(resp.encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8952), H).serve_forever()
]]
    local job = vim.fn.jobstart({ "python3", "-c", MOCK2 }, { stdout_buffered = true })
    local ok_ready = vim.wait(5000, function()
      local code = vim.fn.system("curl -sS --max-time 1 -o /dev/null -w '%{http_code}' http://127.0.0.1:8952/ 2>/dev/null")
      return code ~= "" and code ~= "000"
    end)
    if not ok_ready then
      vim.fn.jobstop(job)
      t.true_(false, "mock server 未就绪")
      return
    end

    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    registry.register(helpers.define_tool(
      "tool_turn1", "T1", { type = "object", properties = {}, required = {} },
      function(args, on_success) on_success("t1 ok") end
    ))
    registry.register(helpers.define_tool(
      "tool_turn2", "T2", { type = "object", properties = {}, required = {} },
      function(args, on_success) on_success("t2 ok") end
    ))

    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local agent = runtime.create({ scenario = "chat" })
    agent.tools = registry.list_as_map()

    -- 同步等待异步流程：headless 下若直接返回，外层 qa! 会先于 vim.schedule 回调退出，
    -- 异步断言不生效（测试框架对异步用例是同步计数的），因此这里 vim.wait 等完成再断言。
    local done = false
    local fail = nil
    runtime.run(agent, "first request"):then_(function()
      return runtime.run(agent, "second request")
    end):then_(function()
      done = true
    end, function(e)
      fail = e
      done = true
    end)
    vim.wait(15000, function() return done end)

    if fail then
      vim.fn.jobstop(job)
      t.true_(false, "第二个 turn 工具循环失败: " .. tostring(fail.message or fail))
      return
    end

    -- 端到端结果：两个 turn 的工具都执行了，最终均返回文本（无 EMPTY 提示）
    local last = agent.messages[#agent.messages]
    t.eq("assistant", last.role)
    t.eq("final2", last.content, "第二个 turn 应正常完成，而非提示模型未返回后续内容")
    local empties = 0
    for _, m in ipairs(agent.messages) do
      if m.role == "assistant" and (m.content or ""):find("模型未返回后续内容") then empties = empties + 1 end
    end
    t.eq(0, empties, "不应出现 EMPTY_RESPONSE_MESSAGE")
    t.eq("idle", agent.state)

    -- 协议格式断言（对 mock 记录的所有请求体）：
    -- 1) 所有请求都要携带 stream=true（tool_loop 第二轮起若漏传 stream 字段，
    --    请求体 stream=false，API 以非流式 JSON 返回、SSE 解析丢失全部事件）
    -- 2) 带 tool_calls 的 assistant 消息（content 为空）必须省略 content 字段
    local f = io.open(body_file, "r")
    t.not_nil(f, "mock 应已记录请求体")
    local bad = 0
    local non_stream_reqs = 0
    local total_reqs = 0
    if f then
      for line in f:lines() do
        total_reqs = total_reqs + 1
        local entry = vim.json.decode(line)
        if entry.stream ~= true then non_stream_reqs = non_stream_reqs + 1 end
        for _, m in ipairs(entry.messages or {}) do
          if m.role == "assistant" and m.tool_calls and #m.tool_calls > 0 then
            if m.content ~= nil then
              bad = bad + 1
            end
          end
        end
      end
      f:close()
    end
    t.true_(total_reqs >= 4, "应至少记录 4 次请求（两个 turn × 工具轮 + 最终轮），实际 " .. total_reqs)
    t.eq(0, non_stream_reqs, "所有请求必须携带 stream=true（否则第二轮起事件全部丢失）")
    t.eq(0, bad, "带 tool_calls 的 assistant 消息 content 应为 null/省略（第二、第三轮格式合规）")

    vim.fn.jobstop(job)
    print("  two-turn tool loop done")
  end)

  it("审批弹窗展示失败不阻塞工具循环（多轮工具调用不卡死）", function(t)
    -- 回归测试：审批弹窗展示（真实 UI 中 nvim_open_win 浮窗创建）偶发抛错时，
    -- 若串行审批槽位不释放，后续审批只入队不弹窗、Deferred 永不 settle，
    -- 工具循环永久卡死（表现为多轮工具调用后完全无响应）。
    -- 期望：弹窗失败的工具被降级为拒绝（错误结果），循环继续并最终正常回复。
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "apfail",
        providers = { apfail = { api_type = "openai", base_url = "http://127.0.0.1:8954", api_key = "test" } },
        model_refresh = { on_startup = false },
        scenarios = { chat = { provider = "apfail", preset = "balanced" } },
        context_cache = { enabled = false },
      },
      tools = { approval = { mode = "prompt", per_tool = {}, timeout_ms = 15000 } },
      session = { save_path = "/tmp/neoai_test_apfail", file = "s.jsonl" },
    })

    -- mock：3 次工具调用后返回最终文本
    local MOCK = [[
import http.server, json
def ev(o):
    return 'data: ' + json.dumps(o) + '\n\n'
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        msgs = req.get("messages", [])
        tool_msgs = [m for m in msgs if m.get("role") == "tool"]
        stream = bool(req.get("stream", False))
        n_tool = len(tool_msgs)
        if n_tool < 3:
            name = "tool_req" + str(n_tool + 1)
            args = json.dumps({"description": "执行工具 " + name})
            delta = {"tool_calls":[{"index":0,"id":"call_" + str(n_tool + 1),"function":{"name":name,"arguments":args}}]}
            fin = "tool_calls"
        else:
            delta = {"content": "completed after popup failure"}
            fin = "stop"
        if stream:
            parts = [ev({"choices":[{"delta": delta}]}),
                     ev({"choices":[{"delta":{},"finish_reason": fin}],"usage":{"prompt_tokens":1,"completion_tokens":1}})]
            resp = "".join(parts) + "data: [DONE]\n\n"
        else:
            msg = {"role":"assistant"}
            if n_tool < 3:
                args = json.dumps({"description": "执行工具 " + name})
                msg["tool_calls"] = [{"id":"call_" + str(n_tool + 1),"type":"function","function":{"name":name,"arguments":args}}]
            else:
                msg["content"] = "completed after popup failure"
            resp = json.dumps({"choices":[{"message": msg, "finish_reason": fin}],"usage":{"prompt_tokens":1,"completion_tokens":1}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if stream else "application/json")
        self.send_header("Content-Length", str(len(resp.encode())))
        self.end_headers()
        self.wfile.write(resp.encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8954), H).serve_forever()
]]
    local job = vim.fn.jobstart({ "python3", "-c", MOCK }, { stdout_buffered = true })
    local ready = vim.wait(5000, function()
      local code = vim.fn.system("curl -sS --max-time 1 -o /dev/null -w '%{http_code}' http://127.0.0.1:8954/ 2>/dev/null")
      return code ~= "" and code ~= "000"
    end)
    if not ready then
      vim.fn.jobstop(job)
      t.true_(false, "mock server 未就绪")
      return
    end

    local registry = require("NeoAI.tools.registry")
    local helpers = require("NeoAI.tools.builtin.tool_helpers")
    for i = 1, 3 do
      registry.register(helpers.define_tool(
        "tool_req" .. i, "R" .. i, { type = "object", properties = {}, required = {} },
        function(args, on_success) on_success("ok " .. i) end
      ))
    end

    -- 审批 UI：第 2 次弹窗 show 抛错（模拟浮窗创建偶发失败），其余自动确认
    local shown = 0
    local tool_service = require("NeoAI.services.tool_service")
    tool_service.set_approval_ui({
      show = function(config)
        shown = shown + 1
        if shown == 2 then
          error("模拟浮窗创建失败")
        end
        vim.schedule(function() config.on_confirm() end)
      end,
      hide = function() end,
    })

    local runtime = require("NeoAI.core.agent.runtime")
    runtime.reset()
    local agent = runtime.create({ scenario = "chat" })
    agent.tools = registry.list_as_map()

    -- 同步等待异步流程，避免 headless 下 qa! 先于异步断言退出
    local done = false
    local fail = nil
    runtime.run(agent, "run three tools"):then_(function()
      done = true
    end, function(e)
      fail = e
      done = true
    end)
    vim.wait(20000, function() return done end)

    if fail then
      vim.fn.jobstop(job)
      t.true_(false, "生成失败: " .. tostring(fail.message or fail))
      return
    end

    -- 断言：弹窗失败的工具被降级拒绝（错误结果），循环继续，最终正常回复且不卡死
    local last = agent.messages[#agent.messages]
    t.eq("assistant", last.role)
    t.eq("completed after popup failure", last.content, "弹窗失败后工具循环应继续并正常完成，而非卡死/无响应")
    t.eq("idle", agent.state)

    -- 工具执行记录：tool_req2 因弹窗失败被拒绝（结果含 error），tool_req1/3 正常执行
    local executed = {}
    local rejected = false
    for _, m in ipairs(agent.messages) do
      if m.role == "tool" then
        local c = tostring(m.content or "")
        if c:find("审批弹窗展示失败") then rejected = true end
        if c:match("ok %d") then executed[#executed + 1] = c end
      end
    end
    t.true_(rejected, "弹窗失败的工具应被降级为拒绝（错误结果）")
    t.eq(2, #executed, "其余两个工具应正常执行")

    vim.fn.jobstop(job)
    print("  approval-popup-failure loop done")
  end)
end)
