--- 上下文压缩覆盖层测试
--- @module NeoAI.tests.test_compaction_overlay
--- 覆盖：
--- 1. 压缩覆盖层只影响请求视图，不改动 agent.messages（渲染仍原始）；
--- 2. 被替换前缀内的运行态快照一并折叠；
--- 3. 后台异步压缩（start_background）不阻塞、不触发弹窗事件；
--- 4. 覆盖层随会话持久化并在重开时恢复。

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

tests.suite("compaction_overlay", function(_, it)
  it("request_view：覆盖层仅影响请求，不改动原始消息", function(t)
    local context_builder = require("NeoAI.core.session.context_builder")
    local compactor = require("NeoAI.core.session.compactor")
    local agent = {
      messages = {
        { role = "user", content = "u1" },
        { role = "assistant", content = "a1" },
        { role = "user", content = "u2" },
        { role = "assistant", content = "a2" },
      },
      compaction = { checkpoint = compactor.checkpoint_message("摘要"), replaced = 2 },
    }
    local view = context_builder.request_view(agent)
    t.eq(3, #view, "请求视图 = 检查点 + 尾部两条")
    t.true_(view[1].checkpoint)
    t.eq("u2", view[2].content)
    t.eq("a2", view[3].content)

    local msgs = context_builder.build_from_agent(agent, { include_system = false })
    t.eq(3, #msgs, "build_from_agent 应使用请求视图")
    t.eq("user", msgs[1].role)
    t.true_(msgs[1].content:find("<compacted-summary>", 1, true) ~= nil)

    t.eq(4, #agent.messages, "原始消息不应被改动")
    t.eq("u1", agent.messages[1].content)
  end)

  it("request_view：被替换前缀内的运行态快照一并折叠", function(t)
    local context_builder = require("NeoAI.core.session.context_builder")
    local compactor = require("NeoAI.core.session.compactor")
    local agent = {
      messages = {
        { role = "user", content = "snap0", runtime_context = true },
        { role = "user", content = "u1" },
        { role = "user", content = "u2" },
      },
      compaction = { checkpoint = compactor.checkpoint_message("摘要"), replaced = 1 },
    }
    local view = context_builder.request_view(agent)
    t.eq(2, #view, "前缀内的运行态快照应被折叠")
    t.true_(view[1].checkpoint)
    t.eq("u2", view[2].content)
  end)

  it("start_background：后台压缩不阻塞且不触发弹窗事件", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "p1",
        providers = { p1 = { api_type = "openai", base_url = "http://x", api_key = "k" } },
        context_cache = {
          enabled = true, context_window = 100, threshold_ratio = 0.5,
          retain_ratio = 0.1, retain_min_tokens = 4, min_shadow_messages = 2,
          include_identity = false,
        },
      },
    })
    local agent_mod = require("NeoAI.core.agent.agent")
    local compactor = require("NeoAI.core.session.compactor")
    local agent = agent_mod.create({ config = { system_prompt = "persona", provider = "p1", model = "gpt-4o" } })
    -- 两轮、每轮超阈值
    agent_mod.add_message(agent, "user", ("x"):rep(200))
    agent_mod.add_message(agent, "assistant", ("y"):rep(200))
    agent_mod.add_message(agent, "user", ("z"):rep(200))

    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local started, chunked = 0, 0
    local unsub1 = event_bus.on(events.COMPACTION_STARTED, function() started = started + 1 end)
    local unsub2 = event_bus.on(events.COMPACTION_CHUNK, function() chunked = chunked + 1 end)

    local request_mod = require("NeoAI.core.agent.request")
    local orig = request_mod.send_stream
    request_mod.send_stream = function(_, _, on_chunk)
      if on_chunk then on_chunk({ content = "摘要" }) end
      return async.resolve({ content = "## 摘要\n- 压缩后的检查点", usage = nil })
    end

    local ret = compactor.start_background(agent, { allow_busy = true })
    t.eq(nil, ret, "start_background 应同步返回（不阻塞）")
    t.true_(vim.wait(2000, function() return agent.compaction ~= nil end), "后台压缩应完成")

    request_mod.send_stream = orig
    unsub1()
    unsub2()

    t.eq(0, started, "不应触发 COMPACTION_STARTED（不弹压缩窗）")
    t.eq(0, chunked, "不应触发 COMPACTION_CHUNK（不弹压缩窗）")
    t.not_nil(agent.compaction, "应写入覆盖层")
    t.eq(3, #agent.messages, "原始消息不应被改动")
  end)

  it("压缩覆盖层随会话持久化并在重开时恢复", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    local TEST_DIR = "/tmp/neoai_test_compaction_overlay"
    config_store.load({ session = { save_path = TEST_DIR, file = "s.jsonl" } })
    local session_store = require("NeoAI.core.session.session_store")
    local session_mod = require("NeoAI.core.session.session")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file(TEST_DIR .. "/s.jsonl")
    session_store.init()

    local s = session_store.create({ metadata = { name = "压缩" } })
    session_mod.add_message(s, { role = "user", content = "旧问题" })
    session_mod.add_message(s, { role = "assistant", content = "旧回答" })
    session_mod.add_message(s, { role = "user", content = "新问题" })
    session_mod.add_message(s, { role = "assistant", content = "新回答" })
    session_store.update(s)

    local agent = chat.load_session(s.id)
    local compactor = require("NeoAI.core.session.compactor")
    agent.compaction = { checkpoint = compactor.checkpoint_message("摘要"), replaced = 2 }

    chat.attach_window(1, agent)
    chat.detach_window(1)

    local reloaded = session_store.get(s.id)
    t.not_nil(reloaded.metadata.compaction, "覆盖层应持久化到会话元数据")
    t.eq(2, reloaded.metadata.compaction.replaced)
    t.eq(4, #reloaded.messages, "原始消息应完整保留（渲染用）")

    -- 重开：新建 Agent 应从元数据恢复覆盖层
    chat.reset()
    local agent2 = chat.load_session(s.id)
    t.not_nil(agent2.compaction, "重开应恢复压缩覆盖层")
    t.eq(2, agent2.compaction.replaced)
    local context_builder = require("NeoAI.core.session.context_builder")
    local view = context_builder.request_view(agent2)
    t.true_(view[1].checkpoint, "请求视图首条应为检查点")
    t.eq(4, #agent2.messages, "渲染消息仍为原始完整历史")

    chat.reset()
    session_store.reset()
    fs.delete_file(TEST_DIR .. "/s.jsonl")
  end)
end)
