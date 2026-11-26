--- 工具后台化测试
--- @module 'NeoAI.tests.test_background_tools'
--- 覆盖：工具循环等待工具期间收到新消息时，不再等工具全部完成：
---   - 已真正开始执行的工具转为后台，插入 system 说明 + 新消息，立即发起下一轮；
---   - 等待审批 / ask_user 的工具保持前台，消息暂存到交互结束（timer 恢复）后再转后台；
---   - 后台工具完成时把返回信息追加到上下文末尾，且不触发再次后台化；
---   - 后台未清空时循环不结束；ESC/abort 追加取消结果且不悬挂；
---   - 请求构建为后台化调用补稳定的「后台执行」占位结果（而非 unavailable）。

local tests = require("NeoAI.tests")
local async = require("NeoAI.utils.async")

tests.suite("background_tools", function(_, it)
  local function init_chat()
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1" },
      session = { save_path = "/tmp/neoai_test_background_tools", file = "s.jsonl" },
      tools = { approval = { mode = "auto_allow" } },
    })
    local session_store = require("NeoAI.core.session.session_store")
    local chat = require("NeoAI.services.chat_service")
    local fs = require("NeoAI.utils.fs")
    chat.reset()
    session_store.reset()
    fs.delete_file("/tmp/neoai_test_background_tools/s.jsonl")
    session_store.init()
    return chat
  end

  --- 组装一次「assistant 已返回 tool_calls」的真实历史（tool_loop 依赖它是最后一条）。
  --- @param agent table
  --- @param calls table
  local function seed_tool_calls(agent, calls)
    agent:add_message("assistant", "")
    agent:set_tool_calls(calls)
  end

  --- 假工具服务：默认立即 start 计时器（模拟工具已真正开始执行），返回可控 Deferred。
  --- @param opts table|nil { auto_start? = boolean }
  --- @return table
  local function fake_tool_service(opts)
    opts = opts or {}
    local svc = {
      gates = {},
      timers = {},
      started = {},
      calls = 0,
      auto_start = opts.auto_start ~= false,
    }
    function svc.execute(_, _, _, tool_call_id, exec_opts)
      svc.calls = svc.calls + 1
      local d = async.Deferred.new()
      svc.gates[tool_call_id] = d
      svc.timers[tool_call_id] = exec_opts and exec_opts.timer
      if svc.auto_start and exec_opts and exec_opts.timer then
        exec_opts.timer:start(999999)
        svc.started[tool_call_id] = true
      end
      return d
    end
    return svc
  end

  local function tool_call(id, name)
    return {
      id = id,
      type = "function",
      ["function"] = { name = name or "slow_tool", arguments = "{}" },
    }
  end

  local function find_message(agent, pred)
    for i, m in ipairs(agent.messages) do
      if pred(m) then return m, i end
    end
    return nil, nil
  end

  local function note_count(agent)
    local n = 0
    for _, m in ipairs(agent.messages) do
      if m.background_note then n = n + 1 end
    end
    return n
  end

  it("工具在途时发消息：立即注入、插入后台说明、开启新轮且不结束循环", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent.config = { temperature = 0, stream = true, provider = "mock", model = "m1" }

    local rounds = 0
    local original = package.loaded["NeoAI.core.agent.recovery"]
    package.loaded["NeoAI.core.agent.recovery"] = {
      send_stream = function(_, _, on_chunk)
        rounds = rounds + 1
        on_chunk({ content = "第" .. rounds .. "轮" })
        return async.resolve({ finish_reason = "stop" })
      end,
    }

    local svc = fake_tool_service()
    local calls = { tool_call("c1"), tool_call("c2") }
    seed_tool_calls(agent, calls)
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local d = tool_loop.run(agent, calls, svc, {})

    t.true_(vim.wait(1000, function() return svc.calls == 2 end), "工具应启动")
    t.eq("tool_running", agent.state, "工具执行中状态应为 tool_running")

    -- 工具真正开始执行后发消息：不应进 pending，直接注入并后台化。
    local msg_d = chat.send_message("新消息")
    t.true_(vim.wait(1000, function() return msg_d:is_resolved() end), "消息应立即注入（不等工具完成）")
    t.eq(0, chat.pending_count_for_agent(agent.id), "消息不应留在暂存队列")

    local note = find_message(agent, function(m) return m.background_note == true end)
    t.not_nil(note, "应插入后台执行说明")
    t.matches("工具已在后台执行", note.content)
    t.matches("c1", note.content)
    t.matches("c2", note.content)

    local assistant = find_message(agent, function(m)
      return m.role == "assistant" and m.tool_calls and m.tool_calls[1] and m.tool_calls[1].id == "c1"
    end)
    t.not_nil(assistant, "应保留原 assistant tool_calls")
    t.true_(assistant.background_tool_ids and assistant.background_tool_ids.c1 == true,
      "assistant 应标记 c1 已后台化")
    t.true_(assistant.background_tool_ids and assistant.background_tool_ids.c2 == true,
      "assistant 应标记 c2 已后台化")

    t.eq(1, rounds, "后台化后应立即发起一轮模型请求")
    t.true_(d:is_pending(), "后台工具未完成时循环不应结束")
    t.eq("tool_running", agent.state, "等待后台工具时仍应保持忙碌")

    -- c1 完成：返回信息追加到末尾，并继续一轮。
    svc.gates.c1:resolve("结果1")
    local ok1 = vim.wait(2000, function()
      return find_message(agent, function(m)
        return m.background_result == true and m.background_tool_call_id == "c1"
      end) ~= nil
    end)
    t.true_(ok1, "c1 完成结果应追加到上下文末尾")
    t.eq(2, rounds, "后台结果追加后应继续下一轮")
    t.true_(d:is_pending(), "仍有 c2 后台执行，循环不应结束")

    -- c2 完成：追加结果后循环自然结束。
    svc.gates.c2:resolve("结果2")
    t.true_(vim.wait(3000, function() return not d:is_pending() end), "全部后台工具完成后循环应结束")
    t.eq(3, rounds, "每次后台结果追加后继续一轮")

    local c1, c1i = find_message(agent, function(m)
      return m.background_result == true and m.background_tool_call_id == "c1"
    end)
    local c2, c2i = find_message(agent, function(m)
      return m.background_result == true and m.background_tool_call_id == "c2"
    end)
    t.not_nil(c1, "应有 c1 后台结果")
    t.not_nil(c2, "应有 c2 后台结果")
    t.true_(c1i < c2i, "后台结果应按完成顺序追加")
    t.eq("结果1", c1.background_body, "后台结果正文应保留工具返回")
    t.eq("结果2", c2.background_body, "后台结果正文应保留工具返回")

    package.loaded["NeoAI.core.agent.recovery"] = original
    chat.reset()
  end)

  it("等待审批/ask_user 的工具保持前台，交互结束（timer 恢复）后才转后台", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent.config = { temperature = 0, stream = true, provider = "mock", model = "m1" }

    local rounds = 0
    local original = package.loaded["NeoAI.core.agent.recovery"]
    package.loaded["NeoAI.core.agent.recovery"] = {
      send_stream = function(_, _, on_chunk)
        rounds = rounds + 1
        on_chunk({ content = "轮" .. rounds })
        return async.resolve({ finish_reason = "stop" })
      end,
    }

    -- 不自动 start：模拟工具尚未开始执行（等待审批）或已暂停（等待 ask_user 回答）。
    local svc = fake_tool_service({ auto_start = false })
    local calls = { tool_call("c1") }
    seed_tool_calls(agent, calls)
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local d = tool_loop.run(agent, calls, svc, {})

    t.true_(vim.wait(1000, function() return svc.gates.c1 ~= nil end), "工具调用应已派发")
    local msg_d = chat.send_message("等待交互时的消息")
    vim.wait(100)
    t.eq(1, chat.pending_count_for_agent(agent.id), "等待交互时消息应继续暂存")
    t.eq(0, rounds, "等待交互时不应转后台/发新轮")
    t.eq(0, note_count(agent), "等待交互时不应插入后台说明")
    t.true_(d:is_pending(), "工具未完成时循环仍应进行中")

    -- 交互结束：工具真正开始执行 -> on_active 触发重新评估 -> 立即转后台。
    svc.timers.c1:start(999999)
    t.true_(vim.wait(1000, function() return msg_d:is_resolved() end),
      "交互结束后消息应被注入并转后台")
    t.eq(0, chat.pending_count_for_agent(agent.id), "转后台后暂存队列应清空")
    t.eq(1, note_count(agent), "应插入一条后台说明")
    t.eq(1, rounds, "转后台后应立即发起一轮")

    svc.gates.c1:resolve("结果")
    t.true_(vim.wait(3000, function() return not d:is_pending() end), "后台完成后循环应结束")

    package.loaded["NeoAI.core.agent.recovery"] = original
    chat.reset()
  end)

  it("后台工具完成不递归后台化当前前台批次", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent.config = { temperature = 0, stream = true, provider = "mock", model = "m1" }

    local rounds = 0
    local original = package.loaded["NeoAI.core.agent.recovery"]
    package.loaded["NeoAI.core.agent.recovery"] = {
      send_stream = function(_, _, on_chunk)
        rounds = rounds + 1
        if rounds == 1 then
          -- 后台化后的第一轮：模型又发起一个前台工具调用 c3。
          on_chunk({ tool_calls = {
            { index = 0, id = "c3", type = "function", ["function"] = { name = "slow3", arguments = "{}" } },
          } })
        else
          on_chunk({ content = "轮" .. rounds })
        end
        return async.resolve({ finish_reason = "stop" })
      end,
    }

    local svc = fake_tool_service()
    local calls = { tool_call("c1"), tool_call("c2") }
    seed_tool_calls(agent, calls)
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local d = tool_loop.run(agent, calls, svc, {})

    t.true_(vim.wait(1000, function() return svc.calls == 2 end), "首批工具应启动")
    local msg_d = chat.send_message("新消息")
    t.true_(vim.wait(1000, function() return msg_d:is_resolved() end), "消息应立即注入")
    t.true_(vim.wait(1000, function() return svc.gates.c3 ~= nil end), "应进入前台批次 c3")
    t.eq(1, rounds, "后台化后应发起一轮")
    t.eq(1, note_count(agent), "只应在前台→后台转换时插一条说明")

    -- 前台 c3 未完成时，后台 c1 完成：结果只能排队，不能递归后台化 c3，也不能中途插入。
    svc.gates.c1:resolve("后台结果1")
    vim.wait(150)
    t.eq(1, rounds, "前台批次在途时不应因后台完成而开启新轮")
    t.eq(1, note_count(agent), "后台完成不应再插后台说明")
    t.nil_(find_message(agent, function(m)
      return m.background_result == true and m.background_tool_call_id == "c1"
    end), "前台批次在途时后台结果不应中途插入")

    -- c3 完成：到达批次边界，后台结果随边界追加，并继续下一轮。
    svc.gates.c3:resolve("前台结果3")
    local ok = vim.wait(3000, function()
      return find_message(agent, function(m)
        return m.background_result == true and m.background_tool_call_id == "c1"
      end) ~= nil
    end)
    t.true_(ok, "前台批次结束后后台结果应追加到末尾")
    t.eq(2, rounds, "边界后应继续一轮")

    svc.gates.c2:resolve("后台结果2")
    t.true_(vim.wait(3000, function() return not d:is_pending() end), "全部完成后循环应结束")

    package.loaded["NeoAI.core.agent.recovery"] = original
    chat.reset()
  end)

  it("后台工具未完成时中止：追加取消结果且不悬挂", function(t)
    local chat = init_chat()
    local agent = chat.new_session({})
    agent.config = { temperature = 0, stream = true, provider = "mock", model = "m1" }

    local original = package.loaded["NeoAI.core.agent.recovery"]
    package.loaded["NeoAI.core.agent.recovery"] = {
      send_stream = function(_, _, on_chunk)
        on_chunk({ content = "继续" })
        return async.resolve({ finish_reason = "stop" })
      end,
    }

    local svc = fake_tool_service()
    local calls = { tool_call("c1"), tool_call("c2") }
    seed_tool_calls(agent, calls)
    local tool_loop = require("NeoAI.core.agent.tool_loop")
    local d = tool_loop.run(agent, calls, svc, {})

    t.true_(vim.wait(1000, function() return svc.calls == 2 end), "工具应启动")
    local msg_d = chat.send_message("新消息")
    t.true_(vim.wait(1000, function() return msg_d:is_resolved() end), "消息应立即注入")
    t.true_(d:is_pending(), "后台未完成时循环不应结束")

    agent.signal:abort("user_cancelled")
    local settled = vim.wait(3000, function() return not d:is_pending() end)
    t.true_(settled, "中止后循环应 settle")
    t.eq("rejected", d._state, "中止应 reject")

    for _, id in ipairs({ "c1", "c2" }) do
      local m = find_message(agent, function(x)
        return x.background_result == true and x.background_tool_call_id == id
      end)
      t.not_nil(m, "应为未完成后台工具追加取消结果: " .. id)
      t.true_(m.background_cancelled == true, "取消结果应带 background_cancelled 标记")
    end

    package.loaded["NeoAI.core.agent.recovery"] = original
    chat.reset()
  end)

  it("请求构建：后台化调用补稳定占位结果，末尾结果按 system_update 处理", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { system_in_history = false },
    })
    local agent_mod = require("NeoAI.core.agent.agent")
    local context_builder = require("NeoAI.core.session.context_builder")
    local agent = agent_mod.create({ config = {} })
    local calls = { tool_call("c1"), tool_call("c2") }
    agent:add_message("assistant", "")
    agent:set_tool_calls(calls)
    local assistant = agent.messages[#agent.messages]
    assistant.background_tool_ids = { c1 = true, c2 = true }
    agent:add_message("system", "工具已在后台执行，ID：c1, c2。", {
      system_update = true,
      background_note = true,
    })
    agent:add_message("user", "新消息", { mid_turn = true })
    agent:add_message("system", "后台工具已完成（ID：c1，工具：slow_tool）。返回结果：\n结果1", {
      system_update = true,
      background_result = true,
      background_tool_call_id = "c1",
      background_body = "结果1",
      tool_name = "slow_tool",
    })

    local wire = context_builder.build_from_agent(agent, { include_system = false })
    local ai
    for i, m in ipairs(wire) do
      if m.role == "assistant" and m.tool_calls then ai = i break end
    end
    t.not_nil(ai, "请求视图应保留 assistant tool_calls")
    t.eq("tool", wire[ai + 1].role, "tool_calls 后应紧跟占位 tool 结果")
    t.eq("c1", wire[ai + 1].tool_call_id)
    t.matches("后台执行", wire[ai + 1].content)
    t.false_(wire[ai + 1].content:find("unavailable", 1, true) ~= nil,
      "后台化调用不应被标记为 unavailable")
    t.eq("tool", wire[ai + 2].role)
    t.eq("c2", wire[ai + 2].tool_call_id)

    local note
    local result
    for _, m in ipairs(wire) do
      if m.role == "user" and type(m.content) == "string" and m.content:find("工具已在后台执行", 1, true) then
        note = m
      elseif m.role == "user" and type(m.content) == "string" and m.content:find("后台工具已完成", 1, true) then
        result = m
      end
    end
    t.not_nil(note, "后台说明应出现在 wire（默认降级为 user）")
    t.nil_(note.tool_call_id, "非 tool 消息不得携带 tool_call_id")
    t.not_nil(result, "后台结果应出现在 wire 末尾")
    t.matches("结果1", result.content)
    t.nil_(result.tool_call_id, "后台结果不得伪装成乱序 tool 消息")

    -- system_in_history=true：原位保留 system 角色（端点明确支持时）。
    config_store.load({ ai = { system_in_history = true } })
    local wire2 = context_builder.build_from_agent(agent, { include_system = false })
    local saw_system_note = false
    for _, m in ipairs(wire2) do
      if m.role == "system" and type(m.content) == "string"
        and m.content:find("工具已在后台执行", 1, true) then
        saw_system_note = true
      end
    end
    t.true_(saw_system_note, "ai.system_in_history=true 时应原位保留 system 说明")

    config_store.load({})
    agent_mod.dispose(agent)
  end)
end)
