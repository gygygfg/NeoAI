--- Herder 终端状态信号服务测试
--- @module NeoAI.tests.test_herder

local tests = require("NeoAI.tests")

-- 测试通过覆盖 job 运行器来捕获上报命令，避免真正调用 herdr。
local captured = {}

local function reset_herder_env()
  -- 保留并清空目标 env（测试结束后恢复，避免影响其它套件）
  local orig = {
    HERDR_ENV = vim.env.HERDR_ENV,
    HERDER_BIN_PATH = vim.env.HERDER_BIN_PATH,
    HERDR_BIN_PATH = vim.env.HERDR_BIN_PATH,
    HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
  }
  -- 先设置为已知值
  vim.env.HERDR_ENV = "1"
  vim.env.HERDER_BIN_PATH = "/usr/local/bin/herdr"
  vim.env.HERDR_BIN_PATH = "/usr/local/bin/herdr"
  vim.env.HERDR_PANE_ID = "w1:p1"
  return orig
end

local function restore_env(orig)
  vim.env.HERDR_ENV = orig.HERDR_ENV
  vim.env.HERDER_BIN_PATH = orig.HERDER_BIN_PATH
  vim.env.HERDR_BIN_PATH = orig.HERDR_BIN_PATH
  vim.env.HERDR_PANE_ID = orig.HERDR_PANE_ID
end

--- 初始化 herder（加载含默认 herder 配置的 config）
local function init_herder()
  local config_store = require("NeoAI.kernel.config_store")
  config_store.load({}) -- 合并默认配置（含 herder.enabled = true）
  local herder = require("NeoAI.services.herder")
  herder.reset()
  captured = {}
  herder.set_job(function(argv) captured[#captured + 1] = argv end)
  herder.init()
  return herder
end

--- 取某条捕获 argv 中的 --state 值
local function arg_state(argv)
  for i, a in ipairs(argv) do
    if a == "--state" then return argv[i + 1] end
  end
  return nil
end

--- 取某条捕获 argv 中的第 3 个元素（子命令）
local function arg_command(argv)
  return argv[3]
end

--- 模拟 agent 创建
local function emit_created(agent_id)
  local eb = require("NeoAI.kernel.event_bus")
  local ev = require("NeoAI.kernel.events")
  eb.emit(ev.AGENT_CREATED, { agent = { id = agent_id, state = "idle" } })
end

--- 模拟 agent 状态切换
local function emit_state(agent_id, new_state)
  local eb = require("NeoAI.kernel.event_bus")
  local ev = require("NeoAI.kernel.events")
  eb.emit(ev.AGENT_STATE_CHANGED, { agent_id = agent_id, new = new_state })
end

tests.suite("herder", function(_, it)
  it("非 Herder 环境时完全 no-op", function(t)
    local orig = reset_herder_env()
    vim.env.HERDR_ENV = nil -- 取消 Herder 标记
    local herder = init_herder()
    t.false_(herder.is_available(), "无 HERDR_ENV 时不应可用")
    t.eq("idle", herder.get_state())
    -- 触发事件也不应产生任何上报
    emit_created("a0")
    t.eq(0, #captured, "非 Herder 环境不应调用上报命令")
    restore_env(orig)
  end)

  it("首个非 idle 信号才接管权威，随后上报回到 idle", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    t.true_(herder.is_available())

    emit_created("a1")
    t.eq(0, #captured, "创建即 idle 不应上报")
    t.false_(herder.has_authority())

    emit_state("a1", "generating")
    t.eq(1, #captured)
    t.eq("working", arg_state(captured[1]))
    t.true_(herder.has_authority(), "进入 working 后接管权威")

    emit_state("a1", "idle")
    t.eq(2, #captured)
    t.eq("idle", arg_state(captured[2]))
    restore_env(orig)
  end)

  it("审批阻塞态优先级高于 working", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    local eb = require("NeoAI.kernel.event_bus")
    local ev = require("NeoAI.kernel.events")

    emit_created("a1")
    emit_created("a2")
    emit_state("a1", "generating")
    t.eq("working", arg_state(captured[1]))

    eb.emit(ev.TOOL_APPROVAL_REQUESTED, { agent_id = "a1", tool_name = "edit_file", args = {} })
    t.eq("blocked", arg_state(captured[2]), "审批中应上报 blocked")

    eb.emit(ev.TOOL_APPROVED, { agent_id = "a1", tool_name = "edit_file" })
    t.eq("working", arg_state(captured[3]), "审批通过且仍 working 应回落 working")
    restore_env(orig)
  end)

  it("ask_user 等待触发 blocked，回答后回到 idle", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    local eb = require("NeoAI.kernel.event_bus")
    local ev = require("NeoAI.kernel.events")

    emit_created("a1")
    eb.emit(ev.ASK_USER_WAITING, { agent_id = "a1" })
    t.eq("blocked", arg_state(captured[1]), "等待用户回答应上报 blocked")

    eb.emit(ev.ASK_USER_ANSWERED, { agent_id = "a1" })
    t.eq("idle", arg_state(captured[2]), "回答后应回到 idle")
    restore_env(orig)
  end)

  it("最后一个 agent 移除时释放权威", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    local eb = require("NeoAI.kernel.event_bus")
    local ev = require("NeoAI.kernel.events")

    emit_created("a1")
    emit_state("a1", "generating")
    t.true_(herder.has_authority())

    eb.emit(ev.AGENT_DISPOSED, { agent_id = "a1" })
    t.eq(2, #captured)
    t.eq("release-agent", arg_command(captured[2]), "最后一个 agent 移除应调用 release-agent")
    t.false_(herder.has_authority(), "释放后不再持有权威")

    -- 释放后再创建 idle agent 不应重新上报
    emit_created("a2")
    t.eq(2, #captured)
    restore_env(orig)
  end)

  it("多会话聚合：任一 blocked 即上报 blocked", function(t)
    local orig = reset_herder_env()
    local herder = init_herder()
    local eb = require("NeoAI.kernel.event_bus")
    local ev = require("NeoAI.kernel.events")

    emit_created("a1")
    emit_created("a2")
    emit_state("a1", "generating")
    t.eq("working", arg_state(captured[1]))

    eb.emit(ev.ASK_USER_WAITING, { agent_id = "a2" })
    t.eq("blocked", arg_state(captured[2]), "只要任一会话阻塞就上报 blocked")

    eb.emit(ev.ASK_USER_ANSWERED, { agent_id = "a2" })
    t.eq("working", arg_state(captured[3]), "阻塞解除后回落 working")
    restore_env(orig)
  end)
end)
