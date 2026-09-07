local tests = require("NeoAI.tests")

-- 热重载测试使用的临时插件模块（位于 display_modes 目录，测试结束清理）
local FIXTURE_NAME = "zz_reload_fixture"
local FIXTURE_PATH = "/root/NeoAI/lua/NeoAI/ui/components/display_modes/" .. FIXTURE_NAME .. ".lua"

local function _write_fixture(desc)
  local f = io.open(FIXTURE_PATH, "w")
  f:write(string.format([[
_G.__NEOAI_FIXTURE_LOADS = (_G.__NEOAI_FIXTURE_LOADS or 0) + 1
local manager = require("NeoAI.ui.components.display_modes")
local M = { name = "zz_reload_fixture", label = "ReloadFixture", desc = "%s" }
function M.load(host) if host then host.set_foldexpr(function() return "0" end) end end
function M.unload(host) if host then host.set_foldexpr(nil) end end
manager.register(M)
return M
]], desc))
  f:close()
end

local function _cleanup_fixture()
  pcall(os.remove, FIXTURE_PATH)
  package.loaded["NeoAI.ui.components.display_modes." .. FIXTURE_NAME] = nil
end

-- 端到端 mock 流式服务器（端口 8981，与 chat_keys 的 8980 区分开）
local MOCK_SERVER = [[
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        body = json.dumps({"choices":[{"delta":{"content":"hello from mock"}}]})
        finish = json.dumps({"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":3}})
        resp = "data: " + body + "\n\n" + "data: " + finish + "\n\n" + "data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(resp.encode())))
        self.end_headers()
        self.wfile.write(resp.encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8981), H).serve_forever()
]]

tests.suite("display_modes", function(_, it)
  it("轨迹模式：每个 turn 一个折叠，详细展示请求/响应/工具调用", function(t)
    local display_modes = require("NeoAI.ui.components.display_modes")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local fold = require("NeoAI.ui.components.fold")
    display_modes.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "system", content = "你是助手" },
      { role = "user", content = "查一下 git 状态" },
      { role = "assistant", content = "", reasoning = "先看看", tool_calls = {
        { id = "c1", ["function"] = { name = "git_status", arguments = '{"path":"."}' } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "git_status", content = "M f1", duration_ms = 120 },
      { role = "assistant", content = "当前有改动" },
      { role = "user", content = "第二个问题" },
      { role = "assistant", content = "第二个答案" },
    }

    chat_view.set_display("trajectory")
    chat_view.refresh()

    -- 轨迹模式应安装轨迹折叠覆盖
    t.true_(fold.has_foldexpr_override(), "轨迹模式应安装 foldexpr 覆盖")
    t.true_(fold.has_foldtext_override(), "轨迹模式应安装 foldtext 覆盖")

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    -- turn 头行：系统提示词 + 各轮用户请求
    t.true_(joined:find("⏷ SYSTEM · 系统提示词", 1, true) ~= nil, "应显示系统提示词折叠")
    t.true_(joined:find("⏷ Turn 1", 1, true) ~= nil, "应有 Turn 1 头行")
    t.true_(joined:find("⏷ Turn 2", 1, true) ~= nil, "应有 Turn 2 头行")
    -- 请求标签：每个 assistant 消息一个请求序号
    t.true_(joined:find("▸ 请求 #1 · ASSISTANT", 1, true) ~= nil, "应有请求 #1 小节")
    t.true_(joined:find("▸ 请求 #2 · ASSISTANT", 1, true) ~= nil, "应有请求 #2 小节")
    -- 用户请求内容与工具详情
    t.true_(joined:find("▸ 用户请求", 1, true) ~= nil, "应展示用户请求小节")
    t.true_(joined:find("查一下 git 状态", 1, true) ~= nil, "应展示用户内容")
    t.true_(joined:find("git_status", 1, true) ~= nil, "应展示工具调用")
    t.true_(joined:find('"path": "."', 1, true) ~= nil, "应展示工具参数")
    t.true_(joined:find("M f1", 1, true) ~= nil, "应展示工具结果")
    t.true_(joined:find("第二个问题", 1, true) ~= nil, "应展示第二轮用户请求")
    t.true_(joined:find("第二个答案", 1, true) ~= nil, "应展示第二轮回复")

    -- 每个 turn 头行应是一个折叠起点且默认收起
    vim.api.nvim_set_current_win(opened.win_id)
    local turn_line = 0
    for i, l in ipairs(lines) do
      if l:find("⏷ Turn 1", 1, true) then turn_line = i break end
    end
    t.true_(turn_line > 0, "应找到 Turn 1 折叠起点")
    local fc = vim.fn.foldclosed(turn_line)
    t.true_(fc > 0, "turn 折叠应默认收起，实际 foldclosed=" .. tostring(fc))
    local foldtext = vim.fn.foldtextresult(fc)
    t.true_(foldtext:find("Turn 1", 1, true) ~= nil, "折叠文本应包含 Turn 1，实际 " .. foldtext)
    t.true_(foldtext:find("2 请求", 1, true) ~= nil, "折叠文本应显示请求数，实际 " .. foldtext)
    t.true_(foldtext:find("1 工具", 1, true) ~= nil, "折叠文本应显示工具数，实际 " .. foldtext)

    chat_view.reset()
    chat_service.reset()
    display_modes.reset()
  end)

  it("轨迹模式多级折叠：turn=1、小节=2、子块=3，逐层展开", function(t)
    local display_modes = require("NeoAI.ui.components.display_modes")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    display_modes.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "user", content = "查一下" },
      { role = "assistant", content = "先输出", reasoning = "思考过程", tool_calls = {
        { id = "c1", ["function"] = { name = "git_status", arguments = '{"path":"."}' } },
      } },
      { role = "tool", tool_call_id = "c1", tool_name = "git_status", content = "M f1", duration_ms = 120 },
      { role = "assistant", content = "最终答复" },
    }
    chat_view.set_display("trajectory")
    chat_view.refresh()
    vim.api.nvim_set_current_win(opened.win_id)

    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)
    -- turn 头行为层级 1
    local turn_line = 0
    for i, l in ipairs(lines) do
      if l:find("⏷ Turn 1", 1, true) then turn_line = i break end
    end
    t.eq(1, vim.fn.foldlevel(turn_line), "turn 头行应为层级 1 折叠")
    -- 小节（▸ 用户请求 / ▸ 请求 #N）为层级 2
    local section_lines = {}
    for i, l in ipairs(lines) do
      if l:find("▸ 请求 #1", 1, true) then section_lines[#section_lines + 1] = i end
    end
    t.eq(2, vim.fn.foldlevel(section_lines[1]), "请求小节头行应为层级 2")
    -- 子块（▸ 推理 / ▸ 工具调用）为层级 3
    local sub_lines = {}
    for i, l in ipairs(lines) do
      if l:find("▸ 推理", 1, true) or l:find("▸ 工具调用", 1, true) then
        sub_lines[#sub_lines + 1] = i
      end
    end
    t.eq(2, #sub_lines, "应有推理与工具两个子块")
    for _, ln in ipairs(sub_lines) do
      t.eq(3, vim.fn.foldlevel(ln), "子块头行应为层级 3，实际 " .. tostring(vim.fn.foldlevel(ln)))
    end

    -- 逐层展开：zo turn → 只露出小节头行（内容仍折叠）
    vim.api.nvim_win_set_cursor(opened.win_id, { turn_line, 0 })
    vim.cmd("silent! normal! zo")
    local vis = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)) do
      -- 可见 = 不在任何折叠内（fc=-1）或本身是收起折叠的首行（fc==i，显示折叠文本）
      local fc = vim.fn.foldclosed(i)
      if fc == -1 or fc == i then vis[#vis + 1] = l end
    end
    local visible = table.concat(vis, "\n")
    t.true_(visible:find("▸ 用户请求", 1, true) ~= nil, "展开 turn 应露出用户请求小节头行")
    t.true_(visible:find("▸ 请求 #1 · ASSISTANT", 1, true) ~= nil, "展开 turn 应露出请求小节头行")
    t.false_(visible:find("思考过程", 1, true) ~= nil, "展开 turn 不应一次性露出子块内容（推理正文）")
    t.false_(visible:find("M f1", 1, true) ~= nil, "展开 turn 不应一次性露出工具结果")
    -- 小节折叠文本为小节头行
    t.true_(vim.fn.foldtextresult(section_lines[1]):find("请求 #1", 1, true) ~= nil,
      "小节折叠文本应为小节头行，实际 " .. vim.fn.foldtextresult(section_lines[1]))

    chat_view.reset()
    chat_service.reset()
    display_modes.reset()
  end)

  it("轨迹模式折叠行为：turn 头行起折叠、缩进内容并入、相邻 turn 独立", function(t)
    local display_modes = require("NeoAI.ui.components.display_modes")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    display_modes.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "user", content = "q1" },
      { role = "assistant", content = "a1" },
      { role = "user", content = "q2" },
      { role = "assistant", content = "a2" },
    }
    chat_view.set_display("trajectory")
    chat_view.refresh()

    vim.api.nvim_set_current_win(opened.win_id)
    local lines = vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false)

    -- 两个 turn 头行 = 两个独立折叠
    local starts = {}
    for i, l in ipairs(lines) do
      if l:find("⏷ Turn", 1, true) then
        local fc = vim.fn.foldclosed(i)
        t.true_(fc > 0, "turn 头行应在折叠内，实际 foldclosed=" .. tostring(fc))
        starts[#starts + 1] = fc
      end
    end
    t.eq(2, #starts, "应有 2 个 turn 折叠")
    t.ne(starts[1], starts[2], "两个 turn 应为独立折叠")

    -- 切回对话模式：恢复默认折叠行为，内容按角色渲染
    chat_view.set_display("chat")
    local joined = table.concat(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false), "\n")
    t.true_(joined:find("👤 用户", 1, true) ~= nil, "对话模式应显示角色头")
    t.false_(joined:find("⏷ Turn", 1, true) ~= nil, "对话模式不应有轨迹头行")

    chat_view.reset()
    chat_service.reset()
    display_modes.reset()
  end)

  it("显示模式插件生命周期：切换时卸载旧插件、加载新插件", function(t)
    local display_modes = require("NeoAI.ui.components.display_modes")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local fold = require("NeoAI.ui.components.fold")
    display_modes.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    t.not_nil(opened, "应打开聊天窗口")
    t.eq("chat", display_modes.get_current_name(), "默认应激活 chat 模式")
    t.false_(fold.has_foldexpr_override(), "对话模式不应有 foldexpr 覆盖")
    t.false_(fold.has_foldtext_override(), "对话模式不应有 foldtext 覆盖")

    local plugin = display_modes.get("trajectory")
    t.not_nil(plugin, "应能获取 trajectory 插件")
    t.eq("trajectory", plugin.name, "插件 name 应正确")
    t.eq("轨迹", plugin.label, "插件应带中文 label")

    -- 切换到轨迹：加载轨迹插件并安装折叠覆盖
    chat_view.set_display("trajectory")
    t.eq("trajectory", display_modes.get_current_name(), "应激活 trajectory")
    t.true_(fold.has_foldexpr_override(), "轨迹模式应安装 foldexpr 覆盖")
    t.true_(fold.has_foldtext_override(), "轨迹模式应安装 foldtext 覆盖")

    -- 切回对话：卸载轨迹插件、清除覆盖
    chat_view.set_display("chat")
    t.eq("chat", display_modes.get_current_name(), "应回到 chat")
    t.false_(fold.has_foldexpr_override(), "切回对话后应清除 foldexpr 覆盖")
    t.false_(fold.has_foldtext_override(), "切回对话后应清除 foldtext 覆盖")

    -- cycle_display：chat -> trajectory -> chat
    chat_view.cycle_display()
    t.eq("trajectory", display_modes.get_current_name(), "循环切换应到 trajectory")
    chat_view.cycle_display()
    t.eq("chat", display_modes.get_current_name(), "循环切换应回到 chat")

    chat_view.reset()
    chat_service.reset()
    display_modes.reset()
  end)

  it("输入框插入模式 <C-t> 可直接切换显示模式（不必退出插入模式）", function(t)
    local display_modes = require("NeoAI.ui.components.display_modes")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    local input_box = require("NeoAI.ui.components.input_box")
    display_modes.reset()
    chat_view.reset()
    chat_service.reset()

    chat_view.open()
    local ibuf = input_box.get_buf()
    local cbt = nil
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(ibuf, "i")) do
      if m.lhs == "<C-T>" then cbt = m.callback break end
    end
    t.not_nil(cbt, "输入框插入模式应注册 <C-t> 切换显示模式映射")

    -- 触发 <C-t>：应切到轨迹模式并重渲染（用户停留在输入框也不影响）
    cbt()
    t.eq("trajectory", display_modes.get_current_name(), "插入模式 <C-t> 应切换到轨迹模式")

    local buf = require("NeoAI.ui.components.input_box").get_buf()
    local joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    -- 输入框内容不应被破坏（<C-t> 是切换动作而非输入字符）
    t.eq("", joined, "输入框内容应保持为空，不被 <C-t> 写入字符")

    cbt()
    t.eq("chat", display_modes.get_current_name(), "再次 <C-t> 应切回对话模式")

    chat_view.reset()
    chat_service.reset()
    display_modes.reset()
  end)

  it("轨迹模式展示原始请求体/原始响应/用量/耗时/SSE 分片", function(t)
    local display_modes = require("NeoAI.ui.components.display_modes")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    display_modes.reset()
    chat_view.reset()
    chat_service.reset()

    local opened = chat_view.open()
    local agent = chat_service.get_current_agent()
    agent.messages = {
      { role = "user", content = "问题" },
      {
        role = "assistant", content = "回答", reasoning = "思考",
        request = {
          model = "m1", provider = "p1",
          body = { model = "m1", stream = true, temperature = 0.7, max_tokens = 100,
            messages = { { role = "user", content = "问题" } },
            tools = { { type = "function" } } },
        },
        response = {
          finish_reason = "stop",
          usage = { prompt_tokens = 10, completion_tokens = 5, prompt_cache_hit_tokens = 4 },
          ttft_ms = 250, total_ms = 1500, status = "ok",
          raw_chunks = { '{"c":1}', '{"c":2}' },
        },
      },
    }
    chat_view.set_display("trajectory")
    chat_view.refresh()

    local joined = table.concat(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false), "\n")
    -- 请求参数
    t.true_(joined:find("⚙ 请求参数", 1, true) ~= nil, "应展示请求参数段")
    t.true_(joined:find("模型 m1", 1, true) ~= nil, "请求参数应含模型")
    t.true_(joined:find("消息 1 条", 1, true) ~= nil, "请求参数应含消息数")
    t.true_(joined:find("工具 1 个", 1, true) ~= nil, "请求参数应含工具数")
    -- 原始请求体
    t.true_(joined:find("▸ 原始请求体", 1, true) ~= nil, "应展示原始请求体子块")
    t.true_(joined:find('"max_tokens": 100', 1, true) ~= nil, "原始请求体应含 max_tokens")
    t.true_(joined:find('"stream": true', 1, true) ~= nil, "原始请求体应含 stream")
    -- 原始响应
    t.true_(joined:find("▸ 原始响应", 1, true) ~= nil, "应展示原始响应子块")
    t.true_(joined:find("finish_reason: stop", 1, true) ~= nil, "应展示 finish_reason")
    t.true_(joined:find("prompt 10", 1, true) ~= nil, "应展示用量 prompt")
    t.true_(joined:find("缓存读 4", 1, true) ~= nil, "应展示缓存命中用量")
    t.true_(joined:find("首token 250ms", 1, true) ~= nil, "应展示首token耗时")
    t.true_(joined:find("总耗时 1.5s", 1, true) ~= nil, "应展示总耗时")
    -- 原始 SSE 分片
    t.true_(joined:find("原始响应分片（SSE）· 2 片", 1, true) ~= nil, "应展示 SSE 分片计数")
    t.true_(joined:find('{"c":1}', 1, true) ~= nil, "应展示原始 SSE 分片内容")

    chat_view.reset()
    chat_service.reset()
    display_modes.reset()
  end)

  it("端到端捕获原始请求/响应元数据（mock 流式服务器）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "mock",
        providers = {
          mock = {
            api_type = "openai",
            base_url = "http://127.0.0.1:8981",
            api_key = "test",
            models_override = { "mock-model" },
          },
        },
        model_refresh = { on_startup = false },
        modes = { chat = { provider = "mock", model = "mock-model" } },
      },
      session = { save_path = "/tmp/neoai_display", file = "s.jsonl" },
    })
    local registry = require("NeoAI.core.model.registry")
    registry.reset()
    registry.update("mock", { "mock-model" })
    local session_store = require("NeoAI.core.session.session_store")
    local fs = require("NeoAI.utils.fs")
    session_store.reset()
    fs.delete_file("/tmp/neoai_display/s.jsonl")

    local job = vim.fn.jobstart({ "python3", "-c", MOCK_SERVER }, { stdout_buffered = true })
    local ready = vim.wait(5000, function()
      local code =
        vim.fn.system("curl -sS --max-time 1 -o /dev/null -w '%{http_code}' http://127.0.0.1:8981/ 2>/dev/null")
      return code ~= "" and code ~= "000"
    end)
    t.true_(ready, "mock 服务器应就绪")

    local chat_service = require("NeoAI.services.chat_service")
    chat_service.reset()
    chat_service.send_message("hello")
    local got = vim.wait(8000, function()
      local agent = chat_service.get_current_agent()
      if not agent then return false end
      local last = agent.messages[#agent.messages]
      return last and last.role == "assistant" and last.request ~= nil and last.response ~= nil
    end)
    local agent = chat_service.get_current_agent()
    local last = agent and agent.messages[#agent.messages]
    t.true_(got, "应完成一轮生成并捕获元数据")
    t.not_nil(last, "应有最后一条消息")
    t.eq("assistant", last.role, "最后一条应为 assistant")
    t.not_nil(last.request, "应捕获 request 元数据")
    t.not_nil(last.request.body, "应捕获原始请求体")
    t.eq("mock-model", last.request.body.model, "原始请求体应含模型")
    t.true_(last.request.body.stream, "原始请求体应含 stream=true")
    t.true_(type(last.request.body.messages) == "table" and #last.request.body.messages >= 2,
      "原始请求体应含消息上下文（system + user）")
    t.not_nil(last.response, "应捕获 response 元数据")
    t.eq("stop", last.response.finish_reason, "应捕获 finish_reason")
    t.not_nil(last.response.usage, "应捕获用量")
    t.true_(last.response.raw_chunks and #last.response.raw_chunks > 0, "应捕获原始 SSE 分片")
    t.not_nil(last.response.ttft_ms, "应捕获首 token 耗时")
    t.not_nil(last.response.total_ms, "应捕获总耗时")
    vim.fn.jobstop(job)
  end)

  it("显示模式插件热加载：清除 require 缓存并加载磁盘新代码", function(t)
    local display_modes = require("NeoAI.ui.components.display_modes")
    local chat_view = require("NeoAI.ui.window.chat_view")
    local chat_service = require("NeoAI.services.chat_service")
    display_modes.reset()
    chat_view.reset()
    chat_service.reset()
    _cleanup_fixture()
    _G.__NEOAI_FIXTURE_LOADS = nil

    _write_fixture("v1")
    chat_view.open()
    chat_view.set_display(FIXTURE_NAME)
    t.eq(FIXTURE_NAME, display_modes.get_current_name(), "应激活 fixture 插件")
    t.eq("v1", display_modes.get(FIXTURE_NAME).desc, "fixture desc 应为 v1")
    t.eq(1, _G.__NEOAI_FIXTURE_LOADS, "模块应已执行一次")

    -- 热重载（文件未变）：require 缓存被清除，模块重新执行并重新注册
    chat_view.reload_display(FIXTURE_NAME)
    t.eq(FIXTURE_NAME, display_modes.get_current_name(), "热重载后应仍激活")
    t.eq(2, _G.__NEOAI_FIXTURE_LOADS, "热重载应重新执行模块（缓存清除）")
    t.eq("v1", display_modes.get(FIXTURE_NAME).desc, "文件未变时 desc 不变")

    -- 修改磁盘文件后热重载：新代码立即生效（无需重启界面）
    _write_fixture("v2")
    chat_view.reload_display(FIXTURE_NAME)
    t.eq("v2", display_modes.get(FIXTURE_NAME).desc, "热重载应加载磁盘上的新代码")
    t.eq(3, _G.__NEOAI_FIXTURE_LOADS, "第二次热重载应再次执行模块")

    -- 清理
    _cleanup_fixture()
    chat_view.reset()
    chat_service.reset()
    display_modes.reset()
  end)
end)