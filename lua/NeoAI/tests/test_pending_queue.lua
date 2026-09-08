--- 消息暂存 / 轮末注入测试
--- @module NeoAI.tests.test_pending_queue
--- 覆盖：agent 忙碌（tool_running/generating）期间用户发送的消息被 pending_queue
--- 暂存，不会立刻写进对话；工具循环轮末（工具结果记录后、下次模型调用前）由
--- chat_service 注册的注入器把暂存消息插入对话，供下一轮模型感知。

local tests = require("NeoAI.tests")

tests.suite("pending_queue", function(_, it)
  local function init_chat()
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1" },
      session = { save_path = "/tmp/neoai_test_pending", file = "s.jsonl" },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_pending/s.jsonl")
    session_store.init()
    return chat
  end

  it("busy 期间暂存，round 边界才注入对话", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent:set_state("tool_running")
    local d = chat.send_message("用户后续消息")
    -- 忙碌期间消息只暂存，不应写进对话
    t.eq(0, #agent.messages, "busy 时不应立即写入对话")
    t.true_(d:is_pending(), "暂存消息的 Deferred 应仍挂起")

    -- 模拟工具循环轮末（_loop 在下次 _send_round 前调用 inject_pending）
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    tool_loop.inject_pending(agent)

    t.eq(1, #agent.messages, "轮末应把暂存消息注入对话")
    t.eq("user", agent.messages[1].role)
    t.eq("用户后续消息", agent.messages[1].content)
    t.true_(d:is_resolved(), "注入后 Deferred 应 resolve")
  end)

  it("无暂存消息时注入为 no-op", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    tool_loop.inject_pending(agent)
    t.eq(0, #agent.messages, "无暂存时不应注入任何消息")
  end)

  it("多次暂存按顺序全部注入", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent:set_state("generating")
    chat.send_message("第一条")
    chat.send_message("第二条")
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    tool_loop.inject_pending(agent)
    t.eq(2, #agent.messages)
    t.eq("第一条", agent.messages[1].content)
    t.eq("第二条", agent.messages[2].content)
  end)

  it("reset 后清空暂存并注销注入器", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent:set_state("tool_running")
    chat.send_message("将被取消")
    chat.reset()
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    tool_loop.inject_pending(agent)
    t.eq(0, #agent.messages, "reset 后暂存已清空，不应再注入")
  end)

  it("同一 tick 连续运行时按忙碌拒绝/入队（原子占用，防并行生成）", function(t)
    local async = require("NeoAI.utils.async")
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "deepseek", default_model = "auto",
        providers = { deepseek = { api_type = "openai", base_url = "http://127.0.0.1:8950", api_key = "k" } },
        modes = { chat = { provider = "deepseek", model = "m1", temperature = 0.7, max_tokens = 4096, stream = true } },
        context_cache = { enabled = false },
      },
      session = { save_path = "/tmp/neoai_test_claim", file = "s.jsonl" },
      tools = { approval = { mode = "auto_allow" } },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local runtime = require("NeoAI.core.agent.runtime")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset(); runtime.reset(); session_store.reset()
    fs.delete_file("/tmp/neoai_test_claim/s.jsonl")
    session_store.init()

    -- stub 网络：立即返回一条简单回复，让被占用的首轮正常结束并清掉 claim
    local http = require("NeoAI.utils.http")
    local original_http = http.request
    http.request = function(opts, cb)
      local d = async.Deferred.new()
      vim.schedule(function()
        local on_chunk = cb and cb.on_chunk
        if on_chunk then
          on_chunk(vim.json.encode({ choices = { { delta = { content = "ok" }, finish_reason = "stop" } } }), false)
          vim.schedule(function() on_chunk("finished", true) end)
        end
        d:resolve({})
      end)
      return d
    end

    local agent = chat.new_session({})
    -- 首轮：runtime.run 应同步占用生成槽位，即使 agent.state 此刻仍是 idle
    local d1 = runtime.run(agent, "first")
    t.true_(agent._turn_claim ~= nil, "首轮运行应同步占用生成槽位")
    t.eq("idle", agent.state, "此时 state 尚未置 generating（异步链先跑）")

    -- 同一 tick 内再次 runtime.run：应立即被 busy 拒绝，而非并行启动
    local d2 = runtime.run(agent, "second")
    local kind = nil
    d2:catch(function(e) kind = e and e.kind end)
    vim.wait(50, function() return kind ~= nil end)
    t.eq("busy", kind, "二次 runtime.run 应拒绝 busy")

    -- send_message 在槽位被占用时应收纳为 pending（而不是直接失败/并行运行）
    local d3 = chat.send_message("queued-while-busy")
    t.true_(d3:is_pending(), "槽位被占用时 send_message 应暂存为 pending")

    -- 等待首轮（与暂存队列中的消息）自然结束并清掉 claim
    vim.wait(500, function() return agent._turn_claim == nil end)
    t.nil_(agent._turn_claim, "运行结束后生成占用应被释放")

    http.request = original_http
    runtime.reset()
    chat.reset()
  end)
end)
