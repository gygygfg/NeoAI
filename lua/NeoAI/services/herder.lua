--- Herder 终端状态信号服务
--- @module NeoAI.services.herder
--- 本模块只负责"信号生成端"：把 NeoAI agent 的真实作态翻译成 Herder 语义的
--- working / idle / blocked，并通过 `herdr pane report-agent` 上报。Herder 侧的
--- 识别/解析不在此处（由别的部分处理）。
---
--- 设计要点：
--- - **no-op 守护**：仅在 Herder 环境（HERDR_ENV=1）且二进制/ Pane id 齐备时生效；
---   否则模块为惰性空转，不订阅事件、不产生任何副作用。
--- - **多会话聚合**：单个 neovim pane 内可能有多个 AI 会话（含子 Agent）。对每个
---   agent 独立跟踪，聚合出 pane 级状态：blocked > working > idle。
--- - **并发安全**：所有上报带严格递增的 --seq，令 Herder 忽略同一 source 的旧包。
--- - **权威接管**：首个非 idle 信号才接管该 pane 的 lifecycle 权威；此后上报含回到
---   idle 的后续变化；最后一个 agent 被移除时调用 release-agent 释放权威。

local M = {}

-- ========== 私有状态 ==========

local state = {
  initialized = false,
  available = false, -- 是否真正处于 Herder 环境（可上报）
  bin = nil, -- herdr 可执行文件路径
  pane_id = nil, -- HERDR_PANE_ID
  source = nil, -- 生命周期权威标识（--source）
  agent = nil, -- agent 名称（--agent，Herder 侧识别用）
  agents = {}, -- agent_id -> { state, blocked, ask_user_waiting }
  seq = 0, -- 单调递增信号序号
  last_reported = nil, -- 上次已上报的 pane 状态；nil = 尚未接管权威
}

local subs = {} -- 事件订阅取消函数

-- ========== 私有函数 ==========

--- 默认 job 运行器：fire-and-forget 异步执行，绝不阻塞 Neovim 事件循环。
--- @param argv table argv 列表（含命令与全部参数）
local function _job_default(argv)
  if not argv or #argv == 0 then return end
  local ok, err = pcall(vim.fn.jobstart, argv, { detach = true })
  if not ok then
    local logger = require("NeoAI.kernel.logger")
    logger.warn("[herder] 上报失败: %s", tostring(err))
  end
end

-- job 运行器（测试可覆盖）
local job = _job_default

--- 运行上报命令（仅在可上报状态下）
--- @param argv table
local function _run(argv)
  if not state.available then return end
  job(argv)
end

--- 记录一次生命周期权威上报
--- @param command string "report-agent" | "release-agent"
--- @param extra_argv table 附加 argv（--state/--seq 等）
local function _run_report(command, extra_argv)
  state.seq = state.seq + 1
  local argv = {
    state.bin,
    "pane", command, state.pane_id,
    "--source", state.source,
    "--agent", state.agent,
    "--seq", tostring(state.seq),
  }
  for _, a in ipairs(extra_argv or {}) do
    argv[#argv + 1] = a
  end
  _run(argv)
end

--- 上报 pane 状态
--- @param herder_state string "working"|"idle"|"blocked"
local function _report(herder_state)
  _run_report("report-agent", { "--state", herder_state })
end

--- 释放该 source 的生命周期权威（agent 全部退出时）
local function _release()
  _run_report("release-agent")
end

--- 聚合所有已跟踪 agent 的 pane 级状态：blocked > working > idle
--- @return string
local function _aggregate()
  local blocked, working = false, false
  for _, e in pairs(state.agents) do
    if e.blocked > 0 or e.ask_user_waiting then
      blocked = true
    else
      local st = e.state
      if st == "generating" or st == "tool_running" then
        working = true
      end
    end
  end
  if blocked then return "blocked" end
  if working then return "working" end
  return "idle"
end

--- 聚合变化时触发一次状态上报
local function _recompute()
  if not state.available then return end
  -- 已无任何跟踪 agent：若此前接管过权威，释放并复位，交由 Herder 回退屏幕绘制
  if next(state.agents) == nil then
    if state.last_reported then
      state.last_reported = nil
      _release()
    end
    return
  end
  local s = _aggregate()
  -- 从未接管权威且当前为 idle：不打扰 Herder（保持其屏幕启发式/回退），避免空转上报
  if state.last_reported == nil and s == "idle" then
    return
  end
  if s ~= state.last_reported then
    state.last_reported = s
    _report(s)
  end
end

-- ========== 事件处理 ==========

--- 登记一个新 agent（创建/派生）
--- @param agent table
local function _track(agent)
  if not agent or not agent.id then return end
  if state.agents[agent.id] then return end
  state.agents[agent.id] = {
    state = agent.state or "idle",
    blocked = 0,
    ask_user_waiting = false,
  }
  _recompute()
end

--- 移除一个 agent（销毁）
--- @param agent_id string
local function _untrack(agent_id)
  if not agent_id or not state.agents[agent_id] then return end
  state.agents[agent_id] = nil
  _recompute()
end

--- agent 中止：清除其等待/审批中的阻塞状态（避免取消后残留 blocked）
--- @param agent_id string
local function _reset_waiting(agent_id)
  if not agent_id then return end
  local e = state.agents[agent_id]
  if not e then return end
  e.blocked = 0
  e.ask_user_waiting = false
  _recompute()
end

--- 更新 agent 状态
--- @param agent_id string
--- @param new_state string
local function _set_state(agent_id, new_state)
  if not agent_id then return end
  local e = state.agents[agent_id]
  if not e then
    e = { state = "idle", blocked = 0, ask_user_waiting = false }
    state.agents[agent_id] = e
  end
  e.state = new_state or "idle"
  _recompute()
end

--- 标记一次工具审批阻塞
--- @param agent_id string
local function _blocked_inc(agent_id)
  if not agent_id then return end
  local e = state.agents[agent_id]
  if not e then
    e = { state = "idle", blocked = 0, ask_user_waiting = false }
    state.agents[agent_id] = e
  end
  e.blocked = e.blocked + 1
  _recompute()
end

--- 解除一次工具审批阻塞
--- @param agent_id string
local function _blocked_dec(agent_id)
  if not agent_id then return end
  local e = state.agents[agent_id]
  if not e then return end
  e.blocked = math.max(0, e.blocked - 1)
  _recompute()
end

--- 设置/清除 ask_user 等待用户回答状态
--- @param agent_id string
--- @param waiting boolean
local function _ask_waiting(agent_id, waiting)
  if not agent_id then return end
  local e = state.agents[agent_id]
  if not e then
    e = { state = "idle", blocked = 0, ask_user_waiting = false }
    state.agents[agent_id] = e
  end
  e.ask_user_waiting = not not waiting
  _recompute()
end

--- 订阅事件总线（仅在可上报状态下调用一次）
local function _subscribe()
  local eb = require("NeoAI.kernel.event_bus")
  local ev = require("NeoAI.kernel.events")

  local function on(event_name, cb)
    subs[#subs + 1] = eb.on(event_name, cb)
  end

  on(ev.AGENT_CREATED, function(d) _track(d and d.agent) end)
  on(ev.AGENT_SPAWNED, function(d) _track(d and d.agent) end)
  on(ev.AGENT_DISPOSED, function(d) _untrack(d and d.agent_id) end)
  on(ev.AGENT_ABORTED, function(d) _reset_waiting(d and d.agent_id) end)
  on(ev.AGENT_STATE_CHANGED, function(d) _set_state(d and d.agent_id, d and d.new) end)
  on(ev.TOOL_APPROVAL_REQUESTED, function(d) _blocked_inc(d and d.agent_id) end)
  on(ev.TOOL_APPROVED, function(d) _blocked_dec(d and d.agent_id) end)
  on(ev.TOOL_APPROVAL_CANCELLED, function(d) _blocked_dec(d and d.agent_id) end)
  on(ev.ASK_USER_WAITING, function(d) _ask_waiting(d and d.agent_id, true) end)
  on(ev.ASK_USER_ANSWERED, function(d) _ask_waiting(d and d.agent_id, false) end)
end

-- ========== 公开 API ==========

--- 初始化：检测 Herder 环境，就绪则订阅事件。幂等；非 Herder 环境为 no-op。
function M.init()
  if state.initialized then return end
  state.initialized = true

  local config_store = require("NeoAI.kernel.config_store")
  if config_store.get("herder.enabled") == false then
    return
  end
  -- Herder 注入的环境标记
  if os.getenv("HERDR_ENV") ~= "1" then
    return
  end
  local bin = os.getenv("HERDER_BIN_PATH") or os.getenv("HERDR_BIN_PATH")
  local pane_id = os.getenv("HERDR_PANE_ID")
  if not bin or bin == "" or not pane_id or pane_id == "" then
    return
  end

  state.available = true
  state.bin = bin
  state.pane_id = pane_id
  state.source = config_store.get("herder.source") or "custom:neoai"
  state.agent = config_store.get("herder.agent") or "neoai"
  _subscribe()
end

--- 是否处于可上报的 Herder 环境
--- @return boolean
function M.is_available()
  return state.available
end

--- 当前聚合的 pane 级状态（调试/测试用）
--- @return string
function M.get_state()
  return _aggregate()
end

--- 当前是否已接管权威（上报过非 idle 信号）
--- @return boolean
function M.has_authority()
  return state.last_reported ~= nil
end

--- 当前信号序号（测试用）
--- @return number
function M.get_seq()
  return state.seq
end

--- 覆盖 job 运行器（测试用）。传 nil 恢复默认。
--- @param fn function(argv)|nil
function M.set_job(fn)
  job = fn or _job_default
end

--- 重置（测试用）：取消订阅并清空状态
function M.reset()
  for _, u in ipairs(subs) do
    if u then pcall(u) end
  end
  subs = {}
  state = {
    initialized = false,
    available = false,
    bin = nil,
    pane_id = nil,
    source = nil,
    agent = nil,
    agents = {},
    seq = 0,
    last_reported = nil,
  }
  job = _job_default
end

return M
