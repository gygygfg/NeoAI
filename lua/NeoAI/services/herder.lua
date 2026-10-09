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
---   idle 的后续变化；最后一个 agent 被移除时清除展示元数据并调用 release-agent 释放权威。
--- - **展示识别**：接管权威时附带一次 `report-metadata`（--display-agent/--state-label/--title），
---   让 Herder 侧边栏显示 "NeoAI" 与中文状态文案，而非仅裸 agent 标签。

local M = {}

-- ========== 私有状态 ==========

local state = {
  initialized = false,
  available = false, -- 是否真正处于 Herder 环境（可上报）
  bin = nil, -- herdr 可执行文件路径
  pane_id = nil, -- HERDR_PANE_ID
  source = nil, -- 生命周期权威标识（--source）
  agent = nil, -- agent 名称（--agent，Herder 侧识别用）
  display_agent = nil, -- 展示名（report-metadata --display-agent）
  state_labels = nil, -- 状态文案覆盖（report-metadata --state-label STATUS=TEXT）
  title = nil, -- 展示标题（report-metadata --title，可选）
  report_metadata = true, -- 是否上报展示元数据
  auto_install = true, -- 启动时是否异步自动安装 Herder 展示增强片段（幂等）
  metadata_sent = false, -- 本次权威生命周期内是否已上报过展示元数据
  agents = {}, -- agent_id -> { state, blocked, ask_user_waiting }
  seq = 0, -- 单调递增信号序号（init/reset 时用挂钟基数 _seq_base() 起始，见下）
  last_reported = nil, -- 上次已上报的 pane 状态；nil = 尚未接管权威
}

local subs = {} -- 事件订阅取消函数

-- report-metadata 状态文案的确定性顺序（避免 pairs 顺序不定导致测试抖动）
local LABEL_ORDER = { "working", "blocked", "idle", "done", "unknown" }

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

--- 信号序号的挂钟基数（微秒级）。
--- herdr 按 (pane, source) 记住已见的最大 --seq，并丢弃更小的（视为过期包）；
--- release-agent 不会清除该记忆。若 seq 每次从 1 开始，插件 reload（:NeoAIReloadAll）
--- 或同一 pane 内重开 nvim 后，新报告会因序号更小而**全部被丢弃**，表现为
--- 「herdr 不再跟随 NeoAI 生命周期」。故用挂钟时间做基数，保证跨进程单调不回退
--- （与 Herdr 官方集成一致：opencode 脚本用 `Date.now() * 1000` 做基数）。
--- @return number
local function _seq_base()
  local ok, sec, usec = pcall(vim.uv.gettimeofday)
  if ok and sec then
    return sec * 1000000 + usec
  end
  return os.time() * 1000000
end

--- 运行上报命令（仅在可上报状态下）
--- @param argv table
local function _run(argv)
  if not state.available then return end
  job(argv)
end

--- 记录一次生命周期权威上报
--- @param command string "report-agent" | "report-metadata" | "release-agent"
--- @param extra_argv table|nil 附加 argv（--state/--seq 等）
local function _run_report(command, extra_argv)
  state.seq = state.seq + 1
  local argv = {
    state.bin,
    "pane", command, state.pane_id,
    "--source", state.source,
    "--agent", state.agent,
    -- 显式整数格式：seq 基数为 ~1.8e15，缺省 tostring 会输出科学计数法（"1.8e+15"），
    -- herdr 无法解析为整数序号。
    "--seq", string.format("%d", state.seq),
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

--- 装配展示元数据的 report-metadata 附加 argv（display_agent / state_labels / title）
--- @return table
local function _metadata_argv()
  local extra = {}
  if state.display_agent and state.display_agent ~= "" then
    extra[#extra + 1] = "--display-agent"
    extra[#extra + 1] = state.display_agent
  end
  if state.state_labels then
    local seen = {}
    for _, status in ipairs(LABEL_ORDER) do
      local text = state.state_labels[status]
      seen[status] = true
      if text and text ~= "" then
        extra[#extra + 1] = "--state-label"
        extra[#extra + 1] = status .. "=" .. text
      end
    end
    -- 兜底：用户自定义了 LABEL_ORDER 之外的状态键（按字典序确定性输出）
    local rest = {}
    for status, text in pairs(state.state_labels) do
      if not seen[status] and text and text ~= "" then rest[#rest + 1] = status end
    end
    table.sort(rest)
    for _, status in ipairs(rest) do
      extra[#extra + 1] = "--state-label"
      extra[#extra + 1] = status .. "=" .. state.state_labels[status]
    end
  end
  if state.title and state.title ~= "" then
    extra[#extra + 1] = "--title"
    extra[#extra + 1] = state.title
  end
  return extra
end

--- 上报展示元数据（让 Herder 侧边栏显示 display_agent / 中文状态文案 / 标题）
--- 幂等：本次权威生命周期内只上报一次（除非 force）。
--- @param force boolean|nil
--- @return boolean 是否发起了上报
local function _report_metadata(force)
  if not state.report_metadata then return false end
  if not force and state.metadata_sent then return false end
  local extra = _metadata_argv()
  if #extra == 0 then return false end
  state.metadata_sent = true
  _run_report("report-metadata", extra)
  return true
end

--- 清除本 source 的展示元数据（agent 全部退出、释放权威前调用，避免残留展示标签）
local function _clear_metadata()
  if not state.report_metadata then return end
  _run_report("report-metadata", { "--clear-display-agent", "--clear-state-labels", "--clear-title" })
end

--- 启动时**异步、静默、幂等**地安装 Herder 展示增强片段。
--- 仅在确实处于 Herder 环境（state.available）时执行；已安装则为 no-op。
--- 不阻塞启动、不打扰用户（结果仅写入日志）。
local function _schedule_auto_install()
  if not state.auto_install then return end
  vim.schedule(function()
    if not state.available then return end
    local ok, install = pcall(require, "NeoAI.services.herder_install")
    if not ok or type(install) ~= "table" or type(install.install_async) ~= "function" then return end
    pcall(install.install_async, {
      on_done = function(res)
        local logger = require("NeoAI.kernel.logger")
        if res and res.ok then
          if res.changed then
            logger.info("[herder] 已自动写入展示增强片段: %s", tostring(res.path))
          else
            logger.debug("[herder] 展示增强片段已存在，跳过")
          end
        else
          logger.warn("[herder] 展示增强片段自动安装失败: %s", tostring(res and res.error))
        end
      end,
    })
  end)
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
  -- 已无任何跟踪 agent：若此前接管过权威，清除展示元数据并释放，交由 Herder 回退屏幕绘制
  if next(state.agents) == nil then
    if state.last_reported then
      state.last_reported = nil
      _clear_metadata()
      _release()
    end
    state.metadata_sent = false
    return
  end
  local s = _aggregate()
  -- 从未接管权威且当前为 idle：不打扰 Herder（保持其屏幕启发式/回退），避免空转上报
  if state.last_reported == nil and s == "idle" then
    return
  end
  if s ~= state.last_reported then
    state.last_reported = s
    -- 首个非 idle 信号接管权威时，附带一次展示元数据（display_agent/状态文案/标题）
    _report_metadata()
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
  -- Herdr 在 pane 内只注入 HERDR_ENV / HERDR_PANE_ID / HERDR_SOCKET_PATH，**不注入**
  -- HERDER_BIN_PATH / HERDR_BIN_PATH（实测 pane 内 `env | grep BIN_PATH` 为空）。
  -- 因此缺省必须回退到 PATH 上的 `herdr`（与独立脚本 herdr-agent-state.sh、
  -- 安装器 herder_install._bin() 及 Herdr 官方集成一致），否则本集成为永久 no-op、
  -- Herdr 永远收不到上报。
  local bin = os.getenv("HERDER_BIN_PATH") or os.getenv("HERDR_BIN_PATH")
  if not bin or bin == "" then bin = "herdr" end
  local pane_id = os.getenv("HERDR_PANE_ID")
  if not pane_id or pane_id == "" then
    return
  end

  state.available = true
  state.bin = bin
  state.pane_id = pane_id
  -- 用挂钟基数起始：保证 reload / 重开 nvim 后 seq 不回退（否则 herdr 丢弃所有新报告）
  state.seq = _seq_base()
  state.source = config_store.get("herder.source") or "custom:neoai"
  state.agent = config_store.get("herder.agent") or "neoai"
  state.display_agent = config_store.get("herder.display_agent") or "NeoAI"
  local labels = config_store.get("herder.state_labels")
  if labels == false or labels == nil then
    state.state_labels = nil
  else
    state.state_labels = labels
  end
  state.title = config_store.get("herder.title")
  state.report_metadata = config_store.get("herder.report_metadata") ~= false
  state.auto_install = config_store.get("herder.auto_install") ~= false
  _subscribe()
  -- 启动时异步、静默、幂等地安装展示增强片段（非 Herder 环境或已安装时均为 no-op）
  _schedule_auto_install()
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

--- 当前上报的 agent 标签（--agent）
--- @return string|nil
function M.get_agent()
  return state.agent
end

--- 当前生命周期权威标识（--source）
--- @return string|nil
function M.get_source()
  return state.source
end

--- 当前 Herder pane id（HERDR_PANE_ID）
--- @return string|nil
function M.get_pane_id()
  return state.pane_id
end

--- 当前展示名（report-metadata --display-agent）
--- @return string|nil
function M.get_display_agent()
  return state.display_agent
end

--- 手动上报展示元数据（可用性守卫；force=true 时忽略「本生命周期已发」去重）
--- @param force boolean|nil
--- @return boolean 是否发起了上报
function M.report_metadata(force)
  if not state.available then return false end
  return _report_metadata(force)
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
    display_agent = nil,
    state_labels = nil,
    title = nil,
    report_metadata = true,
    auto_install = true,
    metadata_sent = false,
    agents = {},
    seq = _seq_base(),
    last_reported = nil,
  }
  job = _job_default
end

return M
