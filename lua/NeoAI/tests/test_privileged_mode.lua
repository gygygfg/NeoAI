--- 高权限模式测试
--- @module 'NeoAI.tests.test_privileged_mode'
--- 验证：opt-in + 仅异步审批可用、与计划模式互斥、m 循环顺序、生成中延迟应用、
--- 持久化恢复，以及沙箱进程级注册表标记。

local tests = require("NeoAI.tests")

tests.suite("privileged_mode", function(_, it)
  local function load_cfg(overrides)
    local config_store = require("NeoAI.kernel.config_store")
    config_store.load(vim.tbl_deep_extend("force", {
      ai = {
        default_provider = "deepseek",
        providers = {
          deepseek = { api_type = "openai", base_url = "http://127.0.0.1:1", api_key = "k" },
        },
        modes = {
          chat = { provider = "deepseek", model = "chat-model", temperature = 0.7, stream = true },
          plan = { provider = "deepseek", model = "plan-model", temperature = 0.3, stream = true },
          privileged = { provider = "deepseek", model = "priv-model", temperature = 0.5, stream = true },
        },
      },
      tools = {
        approval = { mode = "async", per_tool = {} },
        privileged_mode = { enabled = true, require_async_approval = true },
      },
    }, overrides or {}))
  end

  local function reset_all()
    local chat_service = require("NeoAI.services.chat_service")
    local tool_service = require("NeoAI.services.tool_service")
    chat_service.reset()
    tool_service.reset()
    require("NeoAI.sandbox.privileged").reset()
    require("NeoAI.tools.builtin.privileged_mode").reset()
    require("NeoAI.tools.builtin.plan_mode").reset()
  end

  it("opt-in + 仅异步审批可用", function(t)
    local pv = require("NeoAI.tools.builtin.privileged_mode")
    load_cfg({ tools = { privileged_mode = { enabled = false } } })
    local ok, reason = pv.available()
    t.false_(ok)
    t.eq("PRIVILEGED_MODE_DISABLED", reason)

    load_cfg({ tools = { privileged_mode = { enabled = true }, approval = { mode = "prompt" } } })
    ok, reason = pv.available()
    t.false_(ok)
    t.eq("PRIVILEGED_MODE_REQUIRES_ASYNC", reason)

    load_cfg()
    t.true_(pv.available(), "enabled + async 时应可用")
    reset_all()
  end)

  it("enter/exit 标记沙箱进程级注册表，并与计划模式互斥", function(t)
    load_cfg()
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local pv = require("NeoAI.tools.builtin.privileged_mode")
    local sp = require("NeoAI.sandbox.privileged")
    local agent = { id = "priv_source_agent", config = {}, cache = {} }

    t.true_(pm.enter(agent))
    t.true_(pm.is_active(agent))
    t.true_(pv.enter(agent), "高权限模式应可进入")
    t.false_(pm.is_active(agent), "进入高权限模式应退出计划模式")
    t.true_(pv.is_active(agent))
    t.true_(sp.is_marked("priv_source_agent"), "应标记沙箱注册表")
    sp.set_current("priv_source_agent")
    t.true_(sp.active(), "当前 agent 应处于高权限")

    t.true_(pm.enter(agent))
    t.false_(pv.is_active(agent), "进入计划模式应退出高权限模式")
    t.false_(sp.is_marked("priv_source_agent"), "应取消沙箱标记")

    pv.enter(agent)
    t.true_(pv.exit(agent))
    t.false_(pv.is_active(agent))
    t.false_(sp.is_marked("priv_source_agent"))
    reset_all()
  end)

  it("m 循环：CHAT -> PLAN -> PRIV -> CHAT", function(t)
    load_cfg()
    local chat_service = require("NeoAI.services.chat_service")
    local pv = require("NeoAI.tools.builtin.privileged_mode")
    reset_all()
    t.eq("chat", chat_service.get_mode())
    t.eq("plan", chat_service.cycle_mode())
    local agent = chat_service.get_current_agent()
    t.not_nil(agent)
    t.true_(agent.plan_mode == true)
    t.eq("privileged", chat_service.cycle_mode())
    t.true_(agent.privileged_mode == true)
    t.false_(agent.plan_mode == true)
    t.eq("chat", chat_service.cycle_mode())
    t.false_(agent.privileged_mode == true)
    t.true_(pv.available())
    reset_all()
  end)

  it("未启用或非异步审批时 m 只在 CHAT/PLAN 间循环", function(t)
    local chat_service = require("NeoAI.services.chat_service")
    reset_all()
    load_cfg({ tools = { privileged_mode = { enabled = false } } })
    t.eq("plan", chat_service.cycle_mode())
    t.eq("chat", chat_service.cycle_mode(), "disabled 时不应进入 PRIV")
    reset_all()

    load_cfg({ tools = { privileged_mode = { enabled = true }, approval = { mode = "prompt" } } })
    t.eq("plan", chat_service.cycle_mode())
    t.eq("chat", chat_service.cycle_mode(), "非 async 时不应进入 PRIV")
    reset_all()
  end)

  it("生成中切换高权限模式：网络/容器策略立即生效，模型延后", function(t)
    load_cfg()
    local chat_service = require("NeoAI.services.chat_service")
    local sp = require("NeoAI.sandbox.privileged")
    local nc = require("NeoAI.sandbox.net.net_consent")
    reset_all()
    local agent = chat_service.new_session({})
    local chat_model = agent.model
    t.eq("ask", nc.policy(), "默认按配置 ask")
    agent.state = "generating"
    t.eq("plan", chat_service.cycle_mode())
    t.eq("privileged", chat_service.cycle_mode())
    t.true_(chat_service.has_pending_mode())
    t.true_(sp.is_marked(agent.id), "生成中应立即应用沙箱策略（网络放行/容器直连）")
    t.eq("allow", nc.policy(), "生成中网络同意策略应立即放行")
    t.eq(false, agent.privileged_mode == true, "agent 模式标志延后到本轮结束")
    t.eq(chat_model, agent.model, "模型本轮不切换")
    t.eq("privileged", chat_service.pending_mode())
    t.matches("立即生效", chat_service.pending_mode_hint())
    agent:set_state("idle")
    t.true_(agent.privileged_mode == true, "空闲后应用暂存的高权限模式")
    t.eq("priv-model", agent.model, "空闲后切到 PRIV 模型")
    t.false_(chat_service.has_pending_mode())
    reset_all()
  end)

  it("生成中退出高权限模式立即收回网络放行", function(t)
    load_cfg()
    local chat_service = require("NeoAI.services.chat_service")
    local sp = require("NeoAI.sandbox.privileged")
    local nc = require("NeoAI.sandbox.net.net_consent")
    reset_all()
    local agent = chat_service.new_session({})
    t.true_(chat_service.toggle_privileged_mode())
    t.eq("allow", nc.policy())
    t.true_(sp.is_marked(agent.id))
    agent.state = "generating"
    t.false_(chat_service.toggle_privileged_mode(), "再次切换应退出 PRIV")
    t.false_(sp.is_marked(agent.id), "生成中也应立即收回沙箱放行")
    t.eq("ask", nc.policy(), "收回后恢复按配置 ask")
    t.eq("chat", chat_service.pending_mode(), "仍保持待应用的模式切换")
    t.matches("立即收回", chat_service.pending_mode_hint())
    agent:set_state("idle")
    t.false_(agent.privileged_mode == true)
    t.false_(chat_service.has_pending_mode())
    reset_all()
  end)

  it("生成中先开 PRIV 再退回：放行立即授予并立即收回", function(t)
    load_cfg()
    local chat_service = require("NeoAI.services.chat_service")
    local sp = require("NeoAI.sandbox.privileged")
    local nc = require("NeoAI.sandbox.net.net_consent")
    reset_all()
    local agent = chat_service.new_session({})
    agent.state = "generating"
    t.eq("plan", chat_service.cycle_mode())
    t.eq("privileged", chat_service.cycle_mode())
    t.true_(sp.is_marked(agent.id), "同一轮内开启应立即授予放行")
    t.eq("allow", nc.policy())
    t.eq("chat", chat_service.cycle_mode())
    t.false_(sp.is_marked(agent.id), "同一轮内退回应立即收回放行（agent 标志此时尚未置位）")
    t.eq("ask", nc.policy())
    agent:set_state("idle")
    t.false_(agent.privileged_mode == true)
    t.false_(chat_service.has_pending_mode())
    reset_all()
  end)

  it("restore 还原高权限模式；计划模式优先", function(t)
    load_cfg()
    local pv = require("NeoAI.tools.builtin.privileged_mode")
    local pm = require("NeoAI.tools.builtin.plan_mode")
    local sp = require("NeoAI.sandbox.privileged")
    local agent = { id = "priv_restore_agent", config = {}, cache = {} }
    pv.restore(agent, { active = true })
    t.true_(pv.is_active(agent))
    t.true_(sp.is_marked("priv_restore_agent"))

    local agent2 = { id = "priv_restore_agent2", config = {}, cache = {} }
    pm.enter(agent2)
    pv.restore(agent2, { active = true })
    t.false_(pv.is_active(agent2), "计划模式优先")
    t.true_(pm.is_active(agent2))
    reset_all()
  end)
end)
