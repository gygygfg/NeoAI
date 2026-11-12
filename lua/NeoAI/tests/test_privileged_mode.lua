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

  it("生成中切换高权限模式延迟到本轮结束后应用", function(t)
    load_cfg()
    local chat_service = require("NeoAI.services.chat_service")
    reset_all()
    local agent = chat_service.new_session({})
    agent.state = "generating"
    t.eq("plan", chat_service.cycle_mode())
    t.eq("privileged", chat_service.cycle_mode())
    t.true_(chat_service.has_pending_mode())
    t.eq(false, agent.privileged_mode == true, "生成中不得立即切换")
    agent:set_state("idle")
    t.true_(agent.privileged_mode == true, "空闲后应用暂存的高权限模式")
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
