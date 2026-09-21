--- 会话进度增量持久化测试
--- @module NeoAI.tests.test_session_progress
--- 覆盖：长回合/工具循环中途的实时进度会被增量落盘，而不是等整个 agent 循环结束才保存。
--- - 用户消息发送后立即持久化（生成尚未结束也不丢）；
--- - 工具循环每轮工具结果落库后触发轮末持久化钩子；
--- - 关闭/意外退出前 persist_active_sessions 兜底落盘进行中的新增消息。

local tests = require("NeoAI.tests")

tests.suite("session_progress", function(_, it)
  local function setup(path)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "deepseek", default_model = "auto",
        providers = { deepseek = { api_type = "openai", base_url = "http://127.0.0.1:8950", api_key = "k" } },
        modes = { chat = { provider = "deepseek", model = "m1", temperature = 0.7, max_tokens = 4096, stream = true } },
        context_cache = { enabled = false },
      },
      session = { save_path = path, file = "s.jsonl" },
      tools = { approval = { mode = "auto_allow" } },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local runtime = require("NeoAI.core.agent.runtime")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset(); runtime.reset(); session_store.reset()
    fs.delete_file(path .. "/s.jsonl")
    session_store.init()
    return chat, session_store
  end

  local function read_log(path)
    local lines = vim.fn.readfile(path .. "/s.jsonl")
    return table.concat(lines, "\n")
  end

  it("发送后立即落盘用户消息（生成未结束也不丢）", function(t)
    local async = require("NeoAI.utils.async")
    local chat, session_store = setup("/tmp/neoai_test_progress1")
    -- stub 网络：请求一直挂起，模拟生成尚未结束
    local http = require("NeoAI.utils.http")
    local original = http.request
    http.request = function() return async.Deferred.new() end

    local agent = chat.new_session({})
    chat.send_message("进行中的用户消息")
    local session_id = chat.get_current_session_id()
    t.not_nil(session_store.get(session_id), "会话应已持久化")
    -- 发送路径经 _distill_if_needed 的异步微任务后才写入并落盘用户消息，等待该微任务。
    local found = false
    vim.wait(500, function()
      local stored = session_store.get(session_id)
      for _, m in ipairs(stored and stored.messages or {}) do
        if m.role == "user" and m.content == "进行中的用户消息" then found = true end
      end
      return found
    end)
    t.true_(found, "用户消息应在生成结束前已落盘到会话")
    t.true_(read_log("/tmp/neoai_test_progress1"):find("进行中的用户消息", 1, true) ~= nil,
      "JSONL 文件应含用户消息")

    http.request = original
    chat.reset()
  end)

  it("工具循环每轮结束触发轮末持久化钩子", function(t)
    local async = require("NeoAI.utils.async")
    setup("/tmp/neoai_test_progress2")
    local agent_mod = require("NeoAI.core.agent.agent")
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local recovery = require("NeoAI.core.agent.recovery")
    local agent = agent_mod.create({ config = {}, model = "m1" })
    local tool_service = { execute = function() return async.resolve("ok") end }
    local original = recovery.send_stream
    recovery.send_stream = function() return async.resolve({ finish_reason = "stop" }) end
    local persisted = 0
    tool_loop.set_round_persist(function() persisted = persisted + 1 end)
    local done = false
    tool_loop.run(agent,
      { { id = "c1", ["function"] = { name = "read_file", arguments = "{}" } } },
      tool_service, {}):then_(function() done = true end, function() done = true end)
    t.true_(vim.wait(3000, function() return done end), "工具循环应结束")
    t.eq(1, persisted, "每轮工具结果落库后应触发一次轮末持久化")
    recovery.send_stream = original
    tool_loop.set_round_persist(nil)
  end)

  it("persist_active_sessions 兜底落盘进行中的新增消息", function(t)
    local chat = setup("/tmp/neoai_test_progress3")
    local agent = chat.new_session({})
    agent:add_message("user", "关闭前的进行中进度")
    chat.persist_active_sessions()
    t.true_(read_log("/tmp/neoai_test_progress3"):find("关闭前的进行中进度", 1, true) ~= nil,
      "persist_active_sessions 应落盘未同步消息")
    chat.reset()
  end)

  it("工具结果 UI 元数据（密钥/提示/耗时）随会话持久化，重开后不丢", function(t)
    local chat = setup("/tmp/neoai_test_progress4")
    local agent = chat.new_session({})
    agent:add_message("assistant", "", { tool_calls = {
      { id = "c1", ["function"] = { name = "run_command", arguments = '{"command":"cat ~/.ssh/id_rsa"}' } },
    } })
    agent:add_tool_result("c1", "run_command", "ok", {
      duration_ms = 1234,
      notice = "[NeoAI] 降级提示",
      secret_paths = { "/root/.ssh/id_rsa" },
    })
    chat.persist_active_sessions()
    local sid = chat.get_current_session_id()
    -- 模拟关闭会话再打开：清空运行时后重新载入
    chat.reset()
    local loaded = chat.load_session(sid)
    local tool_msg
    for _, m in ipairs(loaded.messages) do
      if m.role == "tool" then tool_msg = m end
    end
    t.not_nil(tool_msg, "应载入工具结果消息")
    t.eq("run_command", tool_msg.tool_name, "工具名应持久化")
    t.eq(1234, tool_msg.duration_ms, "耗时元数据应持久化")
    t.eq("[NeoAI] 降级提示", tool_msg.notice, "UI 附加提示应持久化")
    t.eq("/root/.ssh/id_rsa", (tool_msg.secret_paths or {})[1], "密钥路径元数据应持久化")
    chat.reset()
  end)
end)
