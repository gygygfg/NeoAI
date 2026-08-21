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
    input_box.create({
      on_submit = function(c)
        submitted = c
      end,
    })
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
  it("输入框同步主界面的 chat 按键且回车语义正确（insert 换行 / normal 发送）", function(t)
    local input_box = require("NeoAI.ui.components.input_box")
    input_box.reset()
    local chat_actions = {
      quit = function() end,
      cancel = function() end,
      toggle_reasoning = function() end,
      switch_model = function() end,
      insert = function() end,
      send = function() end,
      cycle_mode = function() end,
      tool_approval = function() end,
    }
    local submitted = nil
    input_box.create({
      on_submit = function(c)
        submitted = c
      end,
      chat_actions = chat_actions,
    })
    local buf = input_box.get_buf()

    -- input_box 应在输入 buffer 普通模式注册 M / <C-a> / m / r / q（与主界面一致）
    local n_maps = vim.api.nvim_buf_get_keymap(buf, "n")
    local registered = {}
    for _, m in ipairs(n_maps) do
      registered[m.lhs] = true
    end
    for _, key in ipairs({ "M", "<C-A>", "m", "r", "q" }) do
      t.true_(registered[key], "输入框普通模式应注册 " .. key)
    end

    -- 普通模式回车 = 发送：从 buffer-local keymap 取出回调并触发
    local function buf_map(mode, lhs)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if m.lhs == lhs then
          return m
        end
      end
      return nil
    end

    local send_normal_entry = buf_map("n", "<CR>")
    t.not_nil(send_normal_entry, "普通模式应注册回车发送")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello normal" })
    send_normal_entry.callback()
    t.eq("hello normal", submitted, "普通模式回车应发送")

    -- 插入模式回车 = 换行（不发送）
    input_box.on_submitted()
    submitted = nil
    vim.cmd("new")
    local win = vim.api.nvim_get_current_win()
    input_box.attach_window(win)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1" })
    local insert_cr_entry = buf_map("i", "<CR>")
    t.not_nil(insert_cr_entry, "插入模式应注册回车换行映射")
    -- 在行中间（第 2 个字符后）插入换行，确定性地拆成两行且不丢失内容
    vim.api.nvim_win_set_cursor(win, { 1, 2 })
    insert_cr_entry.callback()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    t.eq(2, #lines, "插入回车应拆成两行")
    t.eq("li", lines[1], "第一行为换行点之前的文本")
    t.eq("ne1", lines[2], "第二行为换行点之后的文本")
    t.nil_(submitted, "插入回车不应发送")

    pcall(vim.api.nvim_win_close, win, true)
    input_box.reset()
  end)
  it("插入模式回车换行（多字节文本）不复制上一行内容", function(t)
    local input_box = require("NeoAI.ui.components.input_box")
    input_box.reset()
    input_box.create({ on_submit = function() end })
    local buf = input_box.get_buf()
    vim.cmd("new")
    local win = vim.api.nvim_get_current_win()
    input_box.attach_window(win)
    -- 中文（多字节）内容在行尾回车：新行应为空，绝不能复制整行内容
    -- 注：nvim_win_set_cursor 会把越界 col 按字符边界钳制（如 21→18），
    -- 故用有效字节位 6（"第三" 之后）验证按字节切分不丢字、不复制。
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "第三行中文测试" })
    vim.api.nvim_win_set_cursor(win, { 1, 6 })
    local insert_cr = nil
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do
      if m.lhs == "<CR>" then
        insert_cr = m
      end
    end
    t.not_nil(insert_cr, "插入模式应注册回车换行映射")
    insert_cr.callback()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    t.eq(2, #lines, "回车应拆成两行")
    t.eq("第三", lines[1], "第一行为光标前的字节内容")
    t.eq("行中文测试", lines[2], "第二行为光标后的字节内容（不得复制整行）")
    t.false_(lines[2]:find("\n") ~= nil, "行内不应包含换行符")
    pcall(vim.api.nvim_win_close, win, true)
    input_box.reset()
  end)
  it("输入窗口被切到别的 buffer 时 focus() 不写入该 buffer", function(t)
    local input_box = require("NeoAI.ui.components.input_box")
    input_box.reset()
    input_box.create({ on_submit = function() end })
    local buf = input_box.get_buf()
    -- 手动创建窗口并绑定输入 buffer
    vim.cmd("new")
    local win = vim.api.nvim_get_current_win()
    input_box.attach_window(win)
    -- 模拟用户把输入窗口切到一个"文件" buffer（焦点跳到别的 buffer）
    local file_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { "FILE-ORIG" })
    vim.api.nvim_win_set_buf(win, file_buf)
    -- Agent 结束 / 重开窗口时聚焦输入框
    local ok = input_box.focus()
    t.true_(ok, "focus 应成功")
    -- 输入窗口应恢复显示输入 buffer，文件 buffer 不应被追加任何字符
    t.eq(buf, vim.api.nvim_win_get_buf(win), "focus 后输入窗口应重新绑定输入 buffer")
    local file_lines = vim.api.nvim_buf_get_lines(file_buf, 0, -1, false)
    t.eq(1, #file_lines, "文件 buffer 行数不应变化")
    t.eq("FILE-ORIG", file_lines[1], "文件 buffer 不应被追加 'A' 等字符")
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, file_buf, { force = true })
    input_box.reset()
  end)

  it("send_message 端到端收到回复（mock）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "mock",
        providers = {
          mock = {
            api_type = "openai",
            base_url = "http://127.0.0.1:8980",
            api_key = "test",
            models_override = { "mock-model" },
          },
        },
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
      local code =
        vim.fn.system("curl -sS --max-time 1 -o /dev/null -w '%{http_code}' http://127.0.0.1:8980/ 2>/dev/null")
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
