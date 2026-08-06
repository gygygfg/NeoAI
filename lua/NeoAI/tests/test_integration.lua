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
end)
