local tests = require("NeoAI.tests")

local MOCK_SERVER = [[
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        body = json.dumps({"choices":[{"delta":{"content":"hello from mock"}}]})
        finish = json.dumps({"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2}})
        resp = "data: " + body + "\n\n" + "data: " + finish + "\n\n" + "data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(resp.encode())))
        self.end_headers()
        self.wfile.write(resp.encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8980), H).serve_forever()
]]

tests.suite("chat_keys", function(_, it)
  it("回车提交回调触发发送", function(t)
    local input_box = require("NeoAI.ui.components.input_box")
    input_box.reset()
    local submitted = nil
    input_box.create({ on_submit = function(c) submitted = c end })
    local buf = input_box.get_buf()
    -- prompt 前缀应为 "> "（避免默认 "% " 叠加）
    t.eq("> ", vim.fn.prompt_getprompt(buf))
    -- 设置内容后调用回车回调，应触发 submit
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
    local cb = input_box.get_enter_callback()
    t.not_nil(cb)
    cb()
    t.eq("hello", submitted)
    -- 空内容不应提交
    submitted = nil
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "   " })
    cb()
    t.nil_(submitted)
    input_box.reset()
  end)

  it("send_message 端到端收到回复（mock）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "mock",
        providers = { mock = { api_type = "openai", base_url = "http://127.0.0.1:8980", api_key = "test", models_override = { "mock-model" } } },
        model_refresh = { on_startup = false },
        scenarios = { chat = { provider = "mock", preset = "balanced" } },
      },
      session = { save_path = "/tmp/neoai_keys", file = "s.jsonl" },
    })
    local registry = require("NeoAI.core.model.registry")
    registry.reset()
    registry.update("mock", { "mock-model" })
    local session_store = require("NeoAI.core.session.session_store")
    local fs = require("NeoAI.utils.fs")
    session_store.reset()
    fs.delete_file("/tmp/neoai_keys/s.jsonl")

    local job = vim.fn.jobstart({ "python3", "-c", MOCK_SERVER }, { stdout_buffered = true })
    -- 等待服务器就绪（用 curl 探测）
    local ready = vim.wait(5000, function()
      local code = vim.fn.system("curl -sS --max-time 1 -o /dev/null -w '%{http_code}' http://127.0.0.1:8980/ 2>/dev/null")
      return code ~= "" and code ~= "000"
    end)

    local chat_service = require("NeoAI.services.chat_service")
    chat_service.reset()
    chat_service.send_message("hello there")
    local got = vim.wait(8000, function()
      local agent = chat_service.get_current_agent()
      return agent and #agent.messages >= 2
    end)
    local agent = chat_service.get_current_agent()
    t.true_(got, "超时未收到回复，消息数=" .. tostring(agent and #agent.messages or 0))
    t.eq("hello there", agent.messages[1].content)
    t.eq("hello from mock", agent.messages[#agent.messages].content)
    vim.fn.jobstop(job)
  end)
end)
