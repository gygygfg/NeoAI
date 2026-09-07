--- 运行时上下文快照测试
--- @module NeoAI.tests.test_runtime_context
--- 对齐 deepseek-harness：易变运行态（todos/计划模式）不以系统提示段注入（否则系统提示
--- 变化会让整段前缀缓存失效），而是以 user 角色「运行时上下文快照」消息追加进历史；
--- 仅在内容变化时追加（newer supersedes older），系统提示保持逐字节稳定。

local tests = require("NeoAI.tests")

tests.suite("runtime_context", function(_, it)
  local function fresh_agent(id)
    return {
      id = id or "agent-1",
      session_id = "s-1",
      config = {},
      messages = {},
      plan_mode = false,
      plan = nil,
    }
  end

  it("无运行态时不插入快照", function(t)
    local rc = require("NeoAI.core.session.runtime_context")
    local agent = fresh_agent()
    t.nil_(rc.ensure(agent))
    t.eq(0, #agent.messages)
  end)

  it("有 todo 时注入快照，重复调用 no-op", function(t)
    local rc = require("NeoAI.core.session.runtime_context")
    local todo = require("NeoAI.tools.builtin.todo")
    todo.reset()
    todo.seed("s-1", { { content = "任务A", status = "pending" } })
    local agent = fresh_agent()
    local snap = rc.ensure(agent)
    t.not_nil(snap)
    t.eq(1, #agent.messages)
    t.eq("user", snap.role)
    t.true_(snap.runtime_context)
    t.true_(snap.content:find("当前运行上下文", 1, true) ~= nil)
    t.true_(snap.content:find("任务A", 1, true) ~= nil)
    -- 内容未变：再次 ensure 不应追加
    t.nil_(rc.ensure(agent))
    t.eq(1, #agent.messages)
    todo.reset()
  end)

  it("todo 变化时追加新快照（supersede），旧快照不改写", function(t)
    local rc = require("NeoAI.core.session.runtime_context")
    local todo = require("NeoAI.tools.builtin.todo")
    todo.reset()
    todo.seed("s-1", { { content = "任务A", status = "pending" } })
    local agent = fresh_agent()
    rc.ensure(agent)
    local old = agent.messages[1]
    -- 变化任务清单
    todo.seed("s-1", { { content = "任务A", status = "completed" }, { content = "任务B", status = "pending" } })
    local snap2 = rc.ensure(agent)
    t.not_nil(snap2)
    t.eq(2, #agent.messages)
    t.eq(agent.messages[1], old, "旧快照不应被改写")
    t.true_(snap2.content:find("任务B", 1, true) ~= nil)
    todo.reset()
  end)

  it("快照追加到历史，不进入系统提示（系统提示保持稳定）", function(t)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load({
      ai = { default_provider = "deepseek", default_model = "m1", system_prompt = "persona" },
    })
    local prefix = require("NeoAI.core.agent.prefix")
    local rc = require("NeoAI.core.session.runtime_context")
    local todo = require("NeoAI.tools.builtin.todo")
    todo.reset()
    todo.seed("s-1", { { content = "任务A", status = "pending" } })
    local agent = fresh_agent()
    agent.config = { system_prompt = "persona" }
    rc.ensure(agent)
    -- 系统提示不应再包含待办清单文本
    local sys = prefix.build_system_prompt(agent)
    t.nil_(sys:find("当前任务清单", 1, true), "系统提示不应含待办")
    t.true_(sys:find("persona", 1, true) ~= nil, "系统提示仍含 persona")
    -- 待办以 user 快照注入历史
    t.eq(1, #agent.messages)
    t.true_(agent.messages[1].content:find("任务A", 1, true) ~= nil)
    todo.reset()
  end)

  it("计划模式激活时快照含计划策略段", function(t)
    local rc = require("NeoAI.core.session.runtime_context")
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local agent = fresh_agent()
    pm.enter(agent)
    local snap = rc.ensure(agent)
    t.not_nil(snap)
    t.true_(snap.content:find("计划模式", 1, true) ~= nil)
    pm.exit(agent)
    -- 退出计划模式：快照内容变化（不再含计划策略），应追加新快照
    local snap2 = rc.ensure(agent)
    t.not_nil(snap2)
    t.nil_(snap2.content:find("计划模式", 1, true))
    pm.cleanup(agent)
  end)
end)
