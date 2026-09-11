--- 工具循环内上下文压缩测试
--- @module NeoAI.tests.test_loop_compaction
--- 验证：压缩不再被 idle 守卫一律拒绝——
--- 1. maybe_compact 默认仍要求 idle（回合边界），传入 allow_busy 后允许非 idle 压缩；
--- 2. force_compact 缺省 allow_busy（溢出恢复在 generating/tool_running 下也能真正压缩）；
--- 3. tool_loop 轮边界（工具结果已回写、下一轮请求发出前）触发压力压缩，且循环继续；
--- 4. 循环中途压缩的检查点只按「已同步条数」从 durable surface 删除，不误删上一回合历史。

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

tests.suite("loop_compaction", function(_, it)
  local TEST_DIR = "/tmp/neoai_test_loop_compact"

  --- 载入一份小窗口配置，令少量消息即可越过压缩阈值
  local function load_cfg()
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = {
        default_provider = "p1",
        providers = { p1 = { api_type = "openai", base_url = "http://x", api_key = "k" } },
        context_cache = {
          enabled = true,
          context_window = 100,
          threshold_ratio = 0.5,
          retain_ratio = 0.02,
          retain_min_tokens = 4,
          min_shadow_messages = 2,
          compact_max_tokens = 512,
          include_identity = false,
        },
      },
      session = { save_path = TEST_DIR, file = "s.jsonl" },
    })
  end

  --- 桩 compactor 摘要调用：不真实发请求，直接返回摘要
  local function stub_summarize()
    local request_mod = require("NeoAI.core.agent.request")
    local orig = request_mod.send_stream
    request_mod.send_stream = function(_, _, on_chunk)
      if on_chunk then on_chunk({ content = "## 摘要\n- 压缩后的检查点" }) end
      return async.resolve({ content = "## 摘要\n- 压缩后的检查点", usage = nil })
    end
    return function() request_mod.send_stream = orig end
  end

  --- 初始化为 chat 服务可用状态（隔离会话存储）
  local function init_chat()
    local chat = require("NeoAI.services.chat_service")
    local session_store = require("NeoAI.core.session.session_store")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file(TEST_DIR .. "/s.jsonl")
    session_store.init()
    return chat
  end

  --- 构造已达阈值、且工具配对平衡的 agent：
  --- 3 条较长 user 消息（每条约 20 token）+ assistant(tool_calls) + tool 结果
  local function seed_paired_agent(bool_agent)
    local agent_mod = require("NeoAI.core.agent.agent")
    local agent = bool_agent or agent_mod.create({
      config = { system_prompt = "persona", provider = "p1", model = "gpt-4o" },
    })
    for _, c in ipairs({ ("A"):rep(80), ("B"):rep(80), ("C"):rep(80) }) do
      agent_mod.add_message(agent, "user", c)
    end
    agent_mod.set_tool_calls(agent, {
      { id = "t1", type = "function", ["function"] = { name = "tool1", arguments = "{}" } },
    })
    return agent
  end

  it("maybe_compact 默认要求 idle：非 idle 不压缩", function(t)
    load_cfg()
    local compactor = require("NeoAI.core.session.compactor")
    local agent = seed_paired_agent()
    agent.state = "tool_running"
    local done, val = false, nil
    compactor.maybe_compact(agent):then_(function(r) done = true; val = r end)
    t.true_(vim.wait(1500, function() return done end), "异步未完成")
    t.eq(false, val, "非 idle 且未 allow_busy 时应拒绝压缩")
    t.eq(4, #agent.messages, "消息不应被改动")
  end)

  it("maybe_compact allow_busy：非 idle 也能压缩", function(t)
    load_cfg()
    local restore = stub_summarize()
    local compactor = require("NeoAI.core.session.compactor")
    local agent = seed_paired_agent()
    agent.state = "tool_running"
    local done, val = false, nil
    compactor.maybe_compact(agent, { allow_busy = true }):then_(function(r) done = true; val = r end)
    t.true_(vim.wait(2000, function() return done end), "异步未完成")
    restore()
    t.eq(true, val, "allow_busy 下非 idle 也应压缩")
    t.true_(agent.messages[1].checkpoint, "首条应被替换为检查点")
    t.eq("user", agent.messages[1].role)
  end)

  it("force_compact 缺省 allow_busy：非 idle 也能压缩（溢出恢复回归）", function(t)
    load_cfg()
    local restore = stub_summarize()
    local compactor = require("NeoAI.core.session.compactor")
    local agent = seed_paired_agent()
    agent.state = "generating"
    local done, val = false, nil
    compactor.force_compact(agent):then_(function(r) done = true; val = r end,
      function() done = true; val = false end)
    t.true_(vim.wait(2000, function() return done end), "异步未完成")
    restore()
    t.eq(true, val, "force_compact 非 idle 也应压缩（修复前恒 false）")
  end)

  it("force_compact allow_busy=false：显式要求 idle 时非 idle 拒绝", function(t)
    load_cfg()
    local compactor = require("NeoAI.core.session.compactor")
    local agent = seed_paired_agent()
    agent.state = "tool_running"
    local done, val = false, nil
    compactor.force_compact(agent, { allow_busy = false }):then_(function(r) done = true; val = r end)
    t.true_(vim.wait(1500, function() return done end), "异步未完成")
    t.eq(false, val)
  end)

  it("已取消的 agent 不压缩", function(t)
    load_cfg()
    local compactor = require("NeoAI.core.session.compactor")
    local agent = seed_paired_agent()
    agent.state = "tool_running"
    agent.signal:abort("user_cancelled")
    local done, val = false, nil
    compactor.force_compact(agent):then_(function(r) done = true; val = r end)
    t.true_(vim.wait(1500, function() return done end), "异步未完成")
    t.eq(false, val, "已取消不应压缩")
  end)

  it("工具循环轮边界触发压缩且循环继续", function(t)
    load_cfg()
    local chat = init_chat()
    local agent = chat.new_session({})
    agent.config = { temperature = 0, stream = true, provider = "p1", model = "gpt-4o" }
    -- 重置为 seed 形态（new_session 后 messages 为空，重新灌入配对平衡的长历史）
    agent.messages = {}
    local agent_mod = require("NeoAI.core.agent.agent")
    for _, c in ipairs({ ("A"):rep(80), ("B"):rep(80), ("C"):rep(80) }) do
      agent_mod.add_message(agent, "user", c)
    end
    agent_mod.set_tool_calls(agent, {
      { id = "t1", type = "function", ["function"] = { name = "tool1", arguments = "{}" } },
    })

    -- 桩 recovery：轮边界之后模型返回最终正文（无工具调用）→ 循环收尾
    local restore_recovery
    do
      local original = package.loaded["NeoAI.core.agent.recovery"]
      package.loaded["NeoAI.core.agent.recovery"] = {
        send_stream = function(_, _, on_chunk)
          on_chunk({ content = "最终回答" })
          return async.resolve({})
        end,
      }
      restore_recovery = function() package.loaded["NeoAI.core.agent.recovery"] = original end
    end
    local restore_summarize = stub_summarize()

    local compaction_events = 0
    local event_bus = require("NeoAI.kernel.event_bus")
    local events = require("NeoAI.kernel.events")
    local unsub = event_bus.on(events.COMPACTION_COMPLETED, function() compaction_events = compaction_events + 1 end)

    local tool_service = { execute = function() return async.resolve("工具结果") end }
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local d = tool_loop.run(agent, {
      { id = "t1", type = "function", ["function"] = { name = "tool1", arguments = "{}" } },
    }, tool_service, {})
    local resolved = vim.wait(5000, function() return not d:is_pending() end)

    unsub()
    restore_recovery()
    restore_summarize()

    t.true_(resolved, "工具循环应正常完成")
    t.true_(compaction_events >= 1, "轮边界应触发压缩")
    t.true_(agent.messages[1].checkpoint, "头部应被检查点替换")
    t.eq("最终回答", agent.messages[#agent.messages].content, "压缩后循环应继续到最终回答")
  end)

  it("循环中途压缩的检查点只按已同步条数删除（durable 不误删）", function(t)
    load_cfg()
    local session_store = require("NeoAI.core.session.session_store")
    local session_mod = require("NeoAI.core.session.session")
    local chat = init_chat()

    -- 已有会话：上一回合的两条历史已落盘
    local s = session_store.create({ metadata = { name = "既有" } })
    session_mod.add_message(s, { role = "user", content = "旧问题" })
    session_mod.add_message(s, { role = "assistant", content = "旧回答" })
    session_store.update(s)

    local agent = chat.load_session(s.id)
    -- 手工构造「循环中途压缩」后的 agent 消息：检查点 + 一条本回合新消息。
    -- 被替换 4 条，其中只有 2 条已同步（上一回合的两条历史）。
    local compactor = require("NeoAI.core.session.compactor")
    local checkpoint = compactor.checkpoint_message("摘要")
    checkpoint.replaced_count = 4
    checkpoint.replaced_synced_count = 2
    checkpoint.ts = os.time()
    agent.messages = { checkpoint, { role = "user", content = "保留" } }

    -- 通过窗口解绑触发持久化（内部调用 _persist_agent）
    chat.attach_window(1, agent)
    chat.detach_window(1)

    local reloaded = session_store.get(s.id)
    t.not_nil(reloaded, "会话应仍存在")
    local has_checkpoint = false
    for _, m in ipairs(reloaded.messages) do
      if m.checkpoint then has_checkpoint = true end
      t.ne("旧问题", m.content, "已同步的旧历史应被检查点替换（只删已同步条数）")
      t.ne("旧回答", m.content, "已同步的旧历史应被检查点替换（只删已同步条数）")
    end
    t.true_(has_checkpoint, "检查点应被持久化")
    t.eq("保留", reloaded.messages[#reloaded.messages].content, "未同步的本回合消息应保留")
  end)
end)
