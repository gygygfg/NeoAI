--- 会话层测试
--- @module NeoAI.tests.test_session

local tests = require("NeoAI.tests")

tests.suite("session", function(_, it)
  it("会话创建与根判定", function(t)
    local session = require("NeoAI.core.session.session")
    local s = session.create({ model = "m1" })
    t.not_nil(s.id)
    t.true_(session.is_root(s))
    t.eq(s.id, s.root_id)
  end)

  it("消息添加与获取", function(t)
    local session = require("NeoAI.core.session.session")
    local s = session.create({})
    session.add_message(s, { role = "user", content = "hi" })
    session.add_message(s, { role = "assistant", content = "hello", reasoning = "think" })
    t.eq(2, #s.messages)
    t.eq("user", s.messages[1].role)
    t.eq("hello", s.messages[2].content)
    t.eq("think", s.messages[2].reasoning)
  end)

  it("消息更新/删除", function(t)
    local session = require("NeoAI.core.session.session")
    local s = session.create({})
    session.add_message(s, { role = "user", content = "a" })
    session.add_message(s, { role = "user", content = "b" })
    session.update_message(s, 1, { content = "A" })
    t.eq("A", s.messages[1].content)
    local ok = session.delete_message(s, 1)
    t.true_(ok)
    t.eq(1, #s.messages)
  end)

  it("序列化/反序列化往返", function(t)
    local session = require("NeoAI.core.session.session")
    local s = session.create({ model = "m2", metadata = { name = "命名" } })
    session.add_message(s, { role = "user", content = "test" })
    local ser = session.serialize(s)
    local s2 = session.deserialize(ser)
    t.eq(s.id, s2.id)
    t.eq("m2", s2.model)
    t.eq("命名", s2.metadata.name)
    t.eq(1, #s2.messages)
  end)

  it("fork 分支：复制消息 + 父链", function(t)
    local session = require("NeoAI.core.session.session")
    local s = session.create({})
    session.add_message(s, { role = "user", content = "ctx" })
    local child = session.fork(s, { copy_messages = true })
    t.eq(s.id, child.parent_id)
    t.eq(s.root_id, child.root_id)
    t.eq(1, #child.messages)
    t.eq("ctx", child.messages[1].content)
    local child2 = session.fork(s, { copy_messages = false })
    t.eq(0, #child2.messages)
  end)

  it("消息裁剪", function(t)
    local session = require("NeoAI.core.session.session")
    local s = session.create({})
    session.add_message(s, { role = "system", content = "sys" })
    for i = 1, 20 do
      session.add_message(s, { role = "user", content = "m" .. i })
    end
    session.trim_messages(s, 10)
    t.eq(10, #s.messages)
    t.eq("system", s.messages[1].role)
  end)

  it("usage 累加", function(t)
    local session = require("NeoAI.core.session.session")
    local s = session.create({})
    session.add_usage(s, { prompt = 10, completion = 20 })
    t.eq(10, s.metadata.usage.prompt)
    t.eq(20, s.metadata.usage.completion)
  end)

  it("session_store CRUD + 持久化", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ session = { save_path = "/tmp/neoai_test_sess", file = "s.jsonl" } })
    local store = require("NeoAI.core.session.session_store")
    store.reset()
    store.init()
    local s1 = store.create({ model = "m1" })
    local s2 = store.create({ parent_id = s1.id })
    store.create({ parent_id = s1.id })
    t.eq(3, store.count())
    t.eq(2, #store.get_children(s1.id))
    t.eq(1, #store.get_roots())
    store.save_all()
    store.reset()
    store.init()
    t.eq(3, store.count())
    local loaded = store.get(s1.id)
    t.eq("m1", loaded.model)
    local deleted = store.delete(s1.id)
    t.eq(3, #deleted)
    t.eq(0, store.count())
  end)

  it("context_builder 构建消息", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({ session = { max_history_per_session = 3 } })
    local session = require("NeoAI.core.session.session")
    local ctx = require("NeoAI.core.session.context_builder")
    local s = session.create({})
    for i = 1, 10 do
      session.add_message(s, { role = "user", content = "u" .. i })
    end
    local msgs = ctx.build(s)
    t.eq(4, #msgs) -- system + 3 history
    t.eq("system", msgs[1].role)
    t.eq("u10", msgs[#msgs].content)
  end)

  it("context_builder 从 Agent 构建", function(t)
    local session = require("NeoAI.core.session.session")
    local ctx = require("NeoAI.core.session.context_builder")
    local agent = {
      messages = { { role = "user", content = "hello" }, { role = "assistant", content = "world" } },
      config = {},
    }
    local msgs = ctx.build_from_agent(agent, { include_system = false })
    t.eq(2, #msgs)
    t.eq("world", msgs[2].content)
  end)

  it("context_builder 修复中断调用且不修改原始历史", function(t)
    local ctx = require("NeoAI.core.session.context_builder")
    local source = {
      { role = "assistant", tool_calls = {
        { id = "a", type = "function", ["function"] = { name = "read_file", arguments = "{}" } },
        { id = "b", type = "function", ["function"] = { name = "write_file", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "a", content = "actual result" },
      { role = "user", content = "continue" },
    }
    local before = vim.deepcopy(source)
    for _, build in ipairs({
      function() return ctx.build({ messages = source }, { include_system = false, max_history = 100 }) end,
      function() return ctx.build_from_agent({ messages = source }, { include_system = false, max_history = 100 }) end,
      function() return ctx.build_prefix(nil, source) end,
    }) do
      local msgs = build()
      t.eq(4, #msgs)
      t.eq("actual result", msgs[2].content)
      t.eq("b", msgs[3].tool_call_id)
      t.matches("Execution status is unknown", msgs[3].content)
      t.eq("user", msgs[4].role)
    end
    t.deep_eq(before, source)
    local msgs = ctx.build_from_agent({ messages = { source[1] } }, {
      include_system = false, extra_user = "retry", max_history = 100,
    })
    t.eq(4, #msgs)
    t.eq("a", msgs[2].tool_call_id)
    t.eq("b", msgs[3].tool_call_id)
    t.eq("retry", msgs[4].content)
    t.eq(3, #ctx.build_prefix(nil, { source[1] }))
  end)

  it("context_builder 裁剪保留完整工具轮次并过滤孤立或重复结果", function(t)
    local ctx = require("NeoAI.core.session.context_builder")
    local source = {
      { role = "user", content = "read" },
      { role = "assistant", tool_calls = {
        { id = "a", type = "function", ["function"] = { name = "read_file", arguments = "{}" } },
        { id = "b", type = "function", ["function"] = { name = "read_file", arguments = "{}" } },
      } },
      { role = "tool", tool_call_id = "a", content = "A" },
      { role = "tool", tool_call_id = "b", content = "B" },
      { role = "user", content = "continue" },
    }
    for _, build in ipairs({ ctx.build, ctx.build_from_agent }) do
      local msgs = build({ messages = source }, { include_system = false, max_history = 2 })
      t.eq(4, #msgs)
      t.deep_eq(source[2].tool_calls, msgs[1].tool_calls)
      t.eq("A", msgs[2].content)
      t.eq("B", msgs[3].content)
    end
    t.deep_eq(source, ctx.build_prefix(nil, source))
    local msgs = ctx.build_prefix(nil, { source[3], source[2], source[4], source[4], source[3], source[5], source[3] })
    t.eq(4, #msgs)
    t.eq("B", msgs[2].content)
    t.eq("A", msgs[3].content)
    t.eq("user", msgs[4].role)
  end)

  it("context_builder 带 tool_calls 的 assistant 消息省略空 content", function(t)
    -- 协议要求：OpenAI/DeepSeek 中带 tool_calls 的 assistant 消息 content 必须为
    -- null/省略；发送 content:"" 会让要求严格的模型在后续轮次返回空输出，
    -- 表现为工具循环第二轮起模型"未返回后续内容"（第二个 turn 无法开启）。
    local ctx = require("NeoAI.core.session.context_builder")

    -- 空 content + tool_calls：必须省略 content 字段
    local with_calls = ctx.to_api_message({
      role = "assistant",
      content = "",
      tool_calls = { { id = "c1", type = "function", ["function"] = { name = "read_file", arguments = "{}" } } },
    })
    t.eq("assistant", with_calls.role)
    t.nil_(with_calls.content, "带 tool_calls 且 content 为空的 assistant 消息不应输出 content")
    t.eq(1, #with_calls.tool_calls)

    -- 有实际内容的 assistant 消息：保留 content
    local with_text = ctx.to_api_message({
      role = "assistant",
      content = "我先查一下",
      tool_calls = { { id = "c2", type = "function", ["function"] = { name = "read_file", arguments = "{}" } } },
    })
    t.eq("我先查一下", with_text.content)

    -- tool 消息 / 普通消息不受影响
    local tool_msg = ctx.to_api_message({ role = "tool", content = "ok", tool_call_id = "c1" })
    t.eq("ok", tool_msg.content)
    t.eq("c1", tool_msg.tool_call_id)

    local empty_plain = ctx.to_api_message({ role = "assistant", content = "" })
    t.eq("", empty_plain.content, "无 tool_calls 的空 content 保持原样")
  end)
end)
