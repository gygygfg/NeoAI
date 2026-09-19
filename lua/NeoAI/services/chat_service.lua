--- 聊天服务
--- @module NeoAI.services.chat_service
--- 前后端桥梁。UI 通过此服务发送消息、绑定/解绑窗口。
--- - send_message(content)：创建或复用当前 Agent 并发送
--- - approve_plan()：用户确认计划 → 任务清单 + 转入 CHAT
--- - attach_window(win_id, agent)：绑定窗口到 Agent
--- - detach_window(win_id)：解绑（窗口关闭时调用，持久化会话）

local async = require("NeoAI.utils.async")
local runtime = require("NeoAI.core.agent.runtime")
local session_store = require("NeoAI.core.session.session_store")
local session_mod = require("NeoAI.core.session.session")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local services = require("NeoAI.kernel.services")

local M = {}

-- 计划确认后自动执行时注入的用户消息（代表用户的确认指令）
local APPROVE_EXECUTE_MESSAGE = "计划已确认，请按任务清单逐项开始执行。"

-- ========== 私有状态 ==========

local state = {
  windows = {}, -- win_id -> agent_id
  agents = {}, -- agent_id -> { session_id }
  sessions = {}, -- session_id -> agent_id
  current_agent_id = nil,
}

-- 正忙时暂存的消息队列：agent_id -> { { content, opts, d = Deferred }, ... }。
-- AI 忙碌（generating / tool_running）期间用户发送的消息先入队，当前 turn 结束
-- （Agent 回到非忙碌状态）后再逐条发送，而不是直接提示失败。
local pending_queue = {}
local queue_state_sub = nil -- 监听 Agent 状态变化以在 turn 结束时机性刷新的订阅

-- 生成中切换模式：暂存目标模式（"chat"|"plan"|"auto"），待 Agent 空闲后再应用，
-- 保证当前回合在旧模式下跑完（不中途改工具集 / 系统策略 / 模型）。
local pending_mode = nil
local pending_mode_agent_id = nil

-- ========== 私有函数 ==========

--- 判断 Agent 是否已被销毁
--- @param agent table
--- @return boolean
local function agent_mod_is_disposed(agent)
  return agent.state == "disposed" or (agent.messages and #agent.messages == 0 and agent.signal and agent.signal:aborted())
end

--- plan→其它模式执行前的蒸馏：仅当「上一回合是计划模式」且「本次以非计划模式发送」时触发一次。
--- 触发条件（对齐 plan→execute 语义）：
--- - 当前不在计划模式（正在计划模式下发送是计划回合，不得蒸馏）；
--- - 本 agent 记录过进入计划模式的边界（_plan_enter_index）且尚未蒸馏（_plan_distilled）；
--- - 窗口非空（有计划阶段内容待压缩）。
--- 蒸馏失败/空摘要/窗口过小一律 no-op（plan_distill 内部已兜底），不阻塞发送。
--- @param agent table
--- @return Deferred resolve(boolean) 是否执行了蒸馏
local function _distill_if_needed(agent)
  if not agent or not agent.messages then
    return async.resolve(false)
  end
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  if plan_mode.is_active(agent) then
    return async.resolve(false)
  end
  if not agent._plan_enter_index or agent._plan_distilled then
    return async.resolve(false)
  end
  if #agent.messages <= agent._plan_enter_index then
    return async.resolve(false)
  end
  local plan_distill = require("NeoAI.core.session.plan_distill")
  return plan_distill.run(agent):then_(function(done)
    if done then agent._plan_distilled = true end
    return done
  end, function()
    return async.resolve(false)
  end)
end

--- 创建/获取当前 Agent
--- @param opts table|nil { model?, mode?, scenario? }
--- @return table Agent
local function _get_or_create_agent(opts)
  opts = opts or {}
  local agent_id = state.current_agent_id
  local agent = agent_id and runtime.get(agent_id) or nil
  if not agent or agent_mod_is_disposed(agent) then
    -- 新建 Agent 按当前模式解析 provider/model 配置；默认 chat。
    local mode = opts.mode or opts.scenario or M.get_mode()
    local session = session_store.create()
    agent = runtime.create({
      session_id = session.id,
      mode = mode,
      model = opts.model,
      config = opts.config,
    })
    -- 绑定工具（懒加载工具系统）
    local registry = require("NeoAI.tools.registry")
    agent.tools = registry.list_as_map()
    state.agents[agent.id] = { session_id = session.id }
    state.sessions[session.id] = agent.id
    state.current_agent_id = agent.id
  end
  return agent
end

--- 持久化 Agent 消息到会话
--- @param agent table
local function _persist_agent(agent)
  local info = state.agents[agent.id]
  if not info then return true end
  local stored = session_store.get(info.session_id)
  if not stored then return true end
  -- 在候选快照上同步，落盘成功后再标记 _synced；写入失败可安全重试。
  local session = vim.deepcopy(stored)
  local synced = {}
  -- 同步消息；跳过运行时上下文快照（runtime_context），重开会话时由快照重新渲染，
  -- 避免把易变运行态固化到持久历史并污染「用户轮次」计数。
  for _, msg in ipairs(agent.messages) do
    if not msg._synced and not msg.runtime_context then
      -- 压缩检查点：先在 durable surface 移除被替换的「已同步」旧消息（替换而非追加）。
      -- front 替换（compactor）从头部移除；tail 替换（plan_distill）从尾部移除。
      -- 按 replaced_synced_count（被替换消息中已落盘的条数）而非 replaced_count 删除：
      -- 回合边界压缩时两者相等；但工具循环中途压缩时，本回合新增消息尚未落盘，
      -- 若按 replaced_count 删除会把上一回合的历史误删。缺省回退到 replaced_count 以
      -- 兼容旧数据/未记录该字段的检查点。
      if msg.checkpoint and msg.replaced_count and session.messages then
        local n = msg.replaced_synced_count
        if n == nil then n = msg.replaced_count end
        n = math.min(n, #session.messages)
        if msg.replaced_tail then
          for _ = 1, n do
            table.remove(session.messages)
          end
        else
          for _ = 1, n do
            table.remove(session.messages, 1)
          end
        end
      end
      session_mod.add_message(session, {
        role = msg.role,
        content = msg.content or "",
        reasoning = msg.reasoning,
        tool_calls = msg.tool_calls,
        tool_call_id = msg.tool_call_id,
        checkpoint = msg.checkpoint,
      })
      synced[#synced + 1] = msg
    end
  end
  session.model = agent.model
  session.provider = agent.config and agent.config.provider or nil
  session.metadata.usage = vim.deepcopy(agent.usage)
  -- 同步待办清单与计划模式状态到 durable surface（重开会话时还原）
  local todo_mod = require("NeoAI.tools.builtin.todo")
  session.metadata.todos = todo_mod.get(info.session_id)
  session.metadata.plan = {
    active = agent.plan_mode == true,
    plan = agent.plan,
  }
  -- 压缩覆盖层随会话持久化：重开后仍用压缩替换发请求；渲染/持久化的 messages 仍是原始上下文。
  if agent.compaction then
    session.metadata.compaction = vim.deepcopy(agent.compaction)
  else
    session.metadata.compaction = nil
  end
  if session.metadata.auto_naming == false then end
  local ok, err = session_store.persist(session)
  if not ok then
    vim.notify("[NeoAI] 会话保存失败，消息仍保留在内存中: " .. tostring(err), vim.log.levels.ERROR)
    return false, err
  end
  for k, v in pairs(session) do stored[k] = v end
  for _, msg in ipairs(synced) do msg._synced = true end
  return true
end

-- ========== 正忙暂存队列 ==========

--- Agent 是否处于忙碌状态（generating / tool_running / 生成槽位被占用）。
--- `_turn_claim` 是 runtime.run 同步设置的生成占用令牌：状态要等异步链才置为
--- generating，若只看 state，同一 tick 内连续两次 send 会被判为 idle 而并行启动。
--- @param agent table
--- @return boolean
local function _is_busy(agent)
  return agent.state == "generating" or agent.state == "tool_running" or agent._turn_claim ~= nil
end

--- 实际执行一轮生成（含 MESSAGE_SENT 事件 + 持久化）
--- @param agent table
--- @param content string
--- @param opts table|nil
--- @return Deferred
local function _do_run(agent, content, opts)
  event_bus.emit(events.MESSAGE_SENT, { agent_id = agent.id, content = content })
  return runtime.run(agent, content):then_(function(resp)
    local ok, err = _persist_agent(agent)
    if not ok then return async.reject({ kind = "persistence", message = tostring(err) }) end
    return resp
  end, function(err)
    _persist_agent(agent)
    return async.reject(err)
  end)
end

--- 发送一条消息（不做忙碌检查：调用方需保证 agent 空闲）。
--- 发送前做 plan→非plan 边界蒸馏：计划完成、用户以任何非计划模式确认开始即自动蒸馏一次。
--- @param agent table
--- @param content string
--- @param opts table|nil
--- @return Deferred
local function _run_message(agent, content, opts)
  return _distill_if_needed(agent):then_(function()
    return _do_run(agent, content, opts)
  end, function()
    return _do_run(agent, content, opts)
  end)
end

--- 发送队列中的下一条暂存消息（Agent 空闲时调用；每次只发一条，
--- 发送后 Agent 重新忙碌，待其再次空闲时由状态事件驱动发送下一条）
--- @param agent_id string
local function _flush_pending(agent_id)
  local q = pending_queue[agent_id]
  if not q or #q == 0 then
    pending_queue[agent_id] = nil
    return
  end
  local agent = runtime.get(agent_id)
  if not agent or agent_mod_is_disposed(agent) then
    -- Agent 已被销毁：拒绝所有仍在等待的消息，避免永久挂起
    for _, item in ipairs(q) do
      item.d:reject({ kind = "cancelled", message = "会话已关闭，暂存消息已取消" })
    end
    pending_queue[agent_id] = nil
    return
  end
  if _is_busy(agent) then return end
  local item = table.remove(q, 1)
  if #q == 0 then pending_queue[agent_id] = nil end
  _run_message(agent, item.content, item.opts):then_(
    function(resp) item.d:resolve(resp) end,
    function(err) item.d:reject(err) end
  )
end

--- 把暂存队列中的用户消息直接注入 agent 对话（工具循环轮末调用）。
--- 与 _flush_pending 不同：_flush_pending 在 agent 空闲（整个工具循环结束）后才发送；
--- 这里在工具循环中途、本轮工具结果记录后、下次模型调用之前插入，供下一轮模型感知，
--- 而不是等整个工具循环彻底结束才补上。
--- @param agent table
local function _inject_pending(agent)
  local q = pending_queue[agent.id]
  if not q or #q == 0 then
    pending_queue[agent.id] = nil
    return
  end
  pending_queue[agent.id] = nil
  for _, item in ipairs(q) do
    agent:add_message("user", item.content)
    event_bus.emit(events.MESSAGE_SENT, { agent_id = agent.id, content = item.content })
    -- 消息已插入对话即视为已发送；resolve 避免 UI await 挂起（UI 主要只关心 reject）。
    -- 若 Agent 中途被销毁，会由 detach_window 走 _flush_pending 的拒绝逻辑，不在此重复。
    item.d:resolve(true)
  end
end

-- 注入器是否已默认注册到 tool_loop（幂等）
local injector_registered = false

--- 懒加载地把 pending 注入器注册到 tool_loop（幂等）。core 模块不反向依赖服务，
--- 因此通过 tool_loop.set_inject_user 把「拉取暂存消息」的实现注入进去。
local function _ensure_injector()
  if injector_registered then return end
  injector_registered = true
  local tool_loop = require("NeoAI.core.agent.tool_loop")
  tool_loop.set_inject_user(function(agent)
    _inject_pending(agent)
  end)
end

-- ========== 生成中切换模式（延迟到本轮结束应用） ==========

--- 当前实际生效的模式（不含待应用的目标模式）
--- @return string "chat" | "plan" | "auto"
local function _actual_mode()
  local tool_service = services.use("services.tool_service")
  if tool_service and tool_service.is_auto_mode() then return "auto" end
  local agent = M.get_current_agent()
  if agent and agent.plan_mode == true then return "plan" end
  return "chat"
end

--- 应用目标模式到 Agent（要求 Agent 空闲，同步）
--- @param agent table
--- @param target string "chat" | "plan" | "auto"
local function _apply_target_mode(agent, target)
  local tool_service = services.use("services.tool_service")
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  if target == "plan" then
    plan_mode.enter(agent)
    if tool_service then tool_service.set_auto_mode(false) end
  elseif target == "auto" then
    plan_mode.exit(agent)
    if tool_service then tool_service.set_auto_mode(true) end
  else
    plan_mode.exit(agent)
    if tool_service then tool_service.set_auto_mode(false) end
  end
  runtime.apply_mode(agent, target)
end

--- Agent 空闲时应用暂存的模式切换（若有）
--- @param agent table
local function _apply_pending_mode(agent)
  if not pending_mode or not agent then return end
  if pending_mode_agent_id and agent.id ~= pending_mode_agent_id then return end
  if _is_busy(agent) then return end
  local target = pending_mode
  pending_mode = nil
  pending_mode_agent_id = nil
  _apply_target_mode(agent, target)
end

--- 确保已监听 Agent 状态变化（幂等）：Agent 回到非忙碌状态时先应用暂存的模式切换，
--- 再刷新暂存队列（保证入队消息以切换后的模式发送）
local function _ensure_queue_observer()
  if queue_state_sub then return end
  queue_state_sub = event_bus.on(events.AGENT_STATE_CHANGED, function(data)
    if not data or not data.agent_id then return end
    local agent = runtime.get(data.agent_id)
    if not agent or _is_busy(agent) then return end
    _apply_pending_mode(agent)
    _flush_pending(data.agent_id)
  end)
end

-- ========== MCP 集成（动态工具更新） ==========

local mcp_pre_round_registered = false
local mcp_observer_sub = nil

--- MCP 刷新钩子：每轮模型请求前刷新 stale 的 MCP 工具定义并就地更新 agent.tools 中
--- 已有 MCP 工具的签名，保证下一轮模型看到与服务器一致的 schema（失败驱动时序）。
--- @param agent table
--- @return Deferred resolve(boolean changed)
local function _mcp_pre_round(agent)
  local mcp = services.use("services.mcp")
  if not mcp then return async.resolve(false) end
  return mcp.pre_round():then_(function(changed)
    if changed and agent and agent.tools then
      local registry = require("NeoAI.tools.registry")
      for name in pairs(agent.tools) do
        local def = registry.get(name)
        if def and def.source == "mcp" then
          agent.tools[name] = def
        end
      end
    end
    return changed
  end)
end

--- 懒加载地注册 MCP 轮前刷新钩子到 tool_loop（幂等）
local function _ensure_mcp_pre_round()
  if mcp_pre_round_registered then return end
  mcp_pre_round_registered = true
  local tool_loop = require("NeoAI.core.agent.tool_loop")
  tool_loop.set_pre_round_refresh(_mcp_pre_round)
end

--- 懒加载地监听 MCP 工具更新，把当前主 Agent 的工具集与注册表同步（幂等）。
--- 连接晚于 Agent 创建时，MCP 工具在 MCP_TOOLS_UPDATED 时被补进当前 Agent。
local function _ensure_mcp_observer()
  if mcp_observer_sub then return end
  mcp_observer_sub = event_bus.on(events.MCP_TOOLS_UPDATED, function()
    local registry = require("NeoAI.tools.registry")
    local aid = state.current_agent_id
    local agent = aid and runtime.get(aid)
    if agent and not agent_mod_is_disposed(agent) and not _is_busy(agent) and agent.tools then
      agent.tools = registry.list_as_map()
    end
  end)
end

--- 一次性确保 MCP 相关钩子（幂等；在模块加载时调用）
local function _ensure_mcp_hooks()
  _ensure_mcp_pre_round()
  _ensure_mcp_observer()
end

--- 暂存一条消息：AI 忙碌时不拒绝，而是入队。工具循环中途（下轮模型调用前）由
--- 注入器插入对话；若没有工具循环则在整个循环结束、agent 空闲后由 flush 发送。
--- @param agent table
--- @param content string
--- @param opts table|nil
--- @return Deferred 等消息真正发送后 resolve，失败则 reject
local function _enqueue_message(agent, content, opts)
  _ensure_queue_observer()
  _ensure_injector()
  local d = async.Deferred.new()
  local q = pending_queue[agent.id]
  if not q then
    q = {}
    pending_queue[agent.id] = q
  end
  table.insert(q, { content = content, opts = opts, d = d })
  -- 通知状态栏：消息已入队（agent 正忙），渲染「待发N」徽标
  event_bus.emit(events.MESSAGE_QUEUED, { agent_id = agent.id, count = #q })
  -- 静默暂存：不提示失败、也不提示"正忙"，随下轮模型调用或本轮结束自动发送
  return d
end

--- 组装会话链消息：祖先链（根→父）全部消息 + 选中会话截止本轮 + 下游单子链全部消息。
--- 从树界面进入会话时，仅打开选中会话会丢失分支上下文；这里沿会话树
--- 先向上遍历到首轮，再向下延展到分裂分支或末尾，拼出完整线性对话。
--- @param session table 选中会话
--- @param round number|nil 选中轮次（nil = 整个会话，即选择会话节点）
--- @return table 消息数组
local function _build_chain_messages(session, round)
  local out = {}
  -- 祖先链：根 → 父会话（不含选中会话自身）全部消息
  local chain = session_store.get_chain(session.id)
  for _, s in ipairs(chain) do
    if s.id ~= session.id then
      for _, m in ipairs(s.messages or {}) do
        out[#out + 1] = m
      end
    end
  end
  -- 选中会话：截止本轮（nil = 整个会话；round N = 到第 N 条用户消息为止）
  local selected = session.messages or {}
  if round then
    local user_count = 0
    for _, m in ipairs(selected) do
      if m.role == "user" then
        user_count = user_count + 1
        if user_count > round then break end
      end
      out[#out + 1] = m
    end
  else
    for _, m in ipairs(selected) do
      out[#out + 1] = m
    end
  end
  -- 下游：沿单子链向下，各会话全部消息，直到分裂分支或末尾
  for _, s in ipairs(session_store.get_downstream(session.id)) do
    for _, m in ipairs(s.messages or {}) do
      out[#out + 1] = m
    end
  end
  return out
end

-- ========== 公开 API ==========

--- 发送消息
--- @param content string
--- @param opts table|nil { model?, scenario? }
--- @return Deferred resolve(响应)
function M.send_message(content, opts)
  opts = opts or {}
  if not content or content:gsub("%s", "") == "" then
    return async.resolve(nil)
  end
  local agent = _get_or_create_agent(opts)
  -- AI 正忙：不入库、不报错，暂存起来等本轮 turn 结束后再发送。
  if _is_busy(agent) then
    return _enqueue_message(agent, content, opts)
  end
  return _run_message(agent, content, opts)
end

--- 获取当前 Agent
--- @return table|nil
function M.get_current_agent()
  if not state.current_agent_id then return nil end
  return runtime.get(state.current_agent_id)
end

--- 当前 Agent 暂存队列中的消息数（agent 正忙时入队的待发消息）
--- @return number
function M.pending_count()
  if not state.current_agent_id then return 0 end
  local q = pending_queue[state.current_agent_id]
  return (q and #q) or 0
end

--- 当前 Agent 是否仍有未完成的工作（正忙，或暂存队列里还有待发消息）。
--- 供 UI 在生成结束（GENERATION_COMPLETED/GENERATION_ERROR/AGENT_ABORTED）时判断
--- 是否把光标移回输入框：还有工作（暂存消息正逐条刷新/继续生成）就不移，
--- 避免反复进入插入模式、且让光标停留在主窗口以观看继续进行的流式输出。
--- @return boolean
function M.has_pending_work()
  local agent = M.get_current_agent()
  if agent and _is_busy(agent) then return true end
  return M.pending_count() > 0
end

--- 获取当前 Agent 的消息
--- @return table
function M.get_messages()
  local agent = M.get_current_agent()
  if not agent then return {} end
  return agent.messages
end

--- 获取当前会话 id
--- @return string|nil
function M.get_current_session_id()
  local agent = M.get_current_agent()
  if not agent then return nil end
  local info = state.agents[agent.id]
  return info and info.session_id or nil
end

--- 判断会话是否正在被聊天服务使用（有活跃 Agent 绑定）
--- 供会话清理逻辑跳过正在聊天中、尚未产出消息的会话。
--- @param session_id string
--- @return boolean
function M.is_session_active(session_id)
  if not session_id then return false end
  return runtime.get_by_session(session_id) ~= nil
end

--- 绑定窗口到 Agent
--- @param win_id number
--- @param agent table|nil Agent；nil 则用当前 Agent
function M.attach_window(win_id, agent)
  agent = agent or M.get_current_agent()
  if not agent then return end
  state.windows[win_id] = agent.id
end

--- 解绑窗口（窗口关闭时调用，持久化会话）
--- @param win_id number
function M.detach_window(win_id)
  local agent_id = state.windows[win_id]
  if not agent_id then return end
  local agent = runtime.get(agent_id)
  if agent then
    local ok, err = _persist_agent(agent)
    if not ok then return false, err end
    local session_id = agent.session_id
    runtime.dispose(agent)
    if session_id then
      local todo_mod = require("NeoAI.tools.builtin.todo")
      todo_mod.cleanup(agent)
    end
    state.agents[agent_id] = nil
    if session_id and state.sessions[session_id] == agent_id then
      state.sessions[session_id] = nil
    end
  end
  state.windows[win_id] = nil
  -- 窗口关闭时若仍有暂存消息（Agent 正忙时被入队），Agent 已销毁，拒绝它们以免永久挂起
  _flush_pending(agent_id)
  -- 窗口关闭时清理正在展示/排队的审批，释放串行审批槽位，
  -- 否则 approval_showing 残留 true 会让后续工具审批只入队不弹窗，循环卡死。
  local tool_service = services.use("services.tool_service")
  if tool_service then tool_service.clear_approval() end
end

--- 取消当前生成
function M.cancel_generation()
  local agent = M.get_current_agent()
  if agent then
    runtime.abort(agent, "user_cancelled")
  end
  -- 取消时同样清理待审批项（弹窗与信号无关，abort 不会自动关掉它），
  -- 释放串行槽位，避免下一轮工具调用卡在审批队列。
  local tool_service = services.use("services.tool_service")
  if tool_service then tool_service.clear_approval() end
end

--- 把当前运行模式（chat/plan/auto）对应的 provider/model 配置应用到 Agent
--- @param agent table|nil
local function _apply_current_mode(agent)
  agent = agent or M.get_current_agent()
  if not agent then return end
  runtime.apply_mode(agent, _actual_mode())
end

--- 请求切换到目标模式：Agent 空闲时立即应用；生成中（generating/tool_running）则暂存，
--- 待本轮结束（Agent 回到 idle）后应用，避免中途改变工具集 / 系统策略 / 模型而打断当前回合。
--- @param target string "chat" | "plan" | "auto"
--- @return string 目标模式
--- @return boolean 是否已立即应用（false = 已暂存待本轮结束）
local function _request_mode(target)
  local agent = M.get_current_agent()
  if not agent then return target, false end
  if _is_busy(agent) then
    -- AUTO 是审批放宽开关（不放宽工具集/模型）：生成中/工具执行中也应立即生效，
    -- 立刻批准当前待审批/排队的工具（set_auto_mode 内部 _approve_all_pending），
    -- 避免「切到 AUTO 后本轮仍在弹审批框」。其余模式切换（工具集/模型）仍延迟到
    -- 本轮结束由 _apply_pending_mode 应用，不打断当前回合；离开 AUTO 同样延迟，
    -- 防止本轮中途突然弹出审批框。
    if target == "auto" then
      local tool_service = services.use("services.tool_service")
      if tool_service then tool_service.set_auto_mode(true) end
    end
    pending_mode = target
    pending_mode_agent_id = agent.id
    _ensure_queue_observer()
    return target, false
  end
  pending_mode = nil
  pending_mode_agent_id = nil
  _apply_target_mode(agent, target)
  return target, true
end

--- 切换当前 Agent 模型
--- @param model_id string
--- @param provider string|nil 模型所属提供商；省略时保持当前 provider 不变
function M.switch_model(model_id, provider)
  local agent = M.get_current_agent()
  if not agent then return end
  agent.model = model_id
  if provider and provider ~= "" then
    agent.config.provider = provider
  end
  event_bus.emit(events.MODEL_SWITCHED, {
    agent_id = agent.id,
    model = agent.model,
    provider = agent.config.provider,
  })
  _persist_agent(agent)
end

--- 切换当前 Agent 的计划模式
--- @return boolean|nil 切换后的状态（无 Agent 时 nil）
function M.toggle_plan_mode()
  local agent = M.get_current_agent()
  if not agent then return nil end
  local target = (M.get_mode() == "plan") and "chat" or "plan"
  _request_mode(target)
  return target == "plan"
end

--- 用户确认计划：解析计划为任务清单（todo）→ 退出计划模式（直接转入 CHAT）→ 可选自动执行。
--- 计划文本取自 agent.plan 或最后一条 assistant 消息（AI 在计划模式下输出的格式化计划）。
--- @param opts table|nil { auto_execute? boolean 覆盖配置 tools.plan_mode.auto_execute_on_approve }
--- @return table|Deferred 未自动执行时返回 { approved, plan, todo_count, error? }；
---   自动执行时返回 Deferred（resolve 同样的表）
function M.approve_plan(opts)
  opts = opts or {}
  local agent = M.get_current_agent()
  if not agent then
    return { approved = false, error = "无当前 Agent" }
  end
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  if not plan_mode.is_active(agent) then
    return { approved = false, error = "当前不在计划模式，无法确认计划" }
  end
  local plan = opts.plan
  if not plan or plan == "" then plan = agent.plan end
  if not plan or plan == "" then
    local last = agent.messages[#agent.messages]
    if last and last.role == "assistant" and last.content and last.content ~= "" then
      plan = last.content
    end
  end
  if not plan or plan == "" then
    return { approved = false, error = "未找到计划内容（AI 尚未输出计划）" }
  end

  -- 计划 → 任务清单
  local todo_mod = require("NeoAI.tools.builtin.todo")
  local items = plan_mode.plan_to_todos(plan)
  local session_id = agent.session_id
  if #items > 0 then
    todo_mod.seed(session_id, items)
    event_bus.emit(events.TODO_UPDATED, { session_id = session_id, count = #items })
  end

  agent.plan = plan
  pending_mode = nil -- 确认计划后清除待应用的模式切换（以本次退出为准）
  pending_mode_agent_id = nil
  plan_mode.exit(agent) -- 直接转入 CHAT 模式
  _apply_current_mode(agent) -- 按退出后的模式应用 provider/model 配置
  _persist_agent(agent)

  local auto = opts.auto_execute
  if auto == nil then
    auto = config_store.get("tools.plan_mode.auto_execute_on_approve") ~= false
  end
  if auto and #items > 0 then
    -- 自动执行：发送确认指令驱动一轮生成，AI 按任务清单（todo）开始工作。
    -- plan→非plan 边界蒸馏由发送路径统一触发（_run_message → _distill_if_needed）。
    return M.send_message(APPROVE_EXECUTE_MESSAGE):then_(function(resp)
      return { approved = true, plan = plan, todo_count = #items, message = resp }
    end, function(err)
      return { approved = true, plan = plan, todo_count = #items, error = tostring(err and err.message or err) }
    end)
  end
  return { approved = true, plan = plan, todo_count = #items }
end

--- 切换 AUTO 模式（自动允许所有工具调用，全局运行期开关）
--- @return boolean 切换后的状态
function M.toggle_auto_mode()
  local target = (M.get_mode() == "auto") and "chat" or "auto"
  _request_mode(target)
  return target == "auto"
end

--- 是否处于 AUTO 模式
--- @return boolean
function M.is_auto_mode()
  local tool_service = services.use("services.tool_service")
  return tool_service and tool_service.is_auto_mode() or false
end

--- 当前模式（互斥：一次只处于一种模式）。
--- 生成中切换时返回待应用的目标模式，让状态栏/UI 立即反映用户意图；
--- 实际生效（工具集/系统策略/模型）在 Agent 空闲后由 _apply_pending_mode 应用。
--- @return string "chat" | "plan" | "auto"
function M.get_mode()
  if pending_mode then return pending_mode end
  return _actual_mode()
end

--- 是否有待本轮结束应用的模式切换
--- @return boolean
function M.has_pending_mode()
  return pending_mode ~= nil
end

--- 循环切换模式：chat -> plan -> auto -> chat
--- @return string 切换后的模式
function M.cycle_mode()
  local mode = M.get_mode()
  local target
  if mode == "chat" then
    target = "plan"
  elseif mode == "plan" then
    target = "auto"
  else
    target = "chat"
  end
  -- 无 Agent 时先创建（新会话从 CHAT 开始，再应用目标模式）
  local agent = M.get_current_agent()
  if not agent then
    agent = M.new_session({})
    _apply_target_mode(agent, target)
    return target
  end
  _request_mode(target)
  return target
end

--- 当前 Agent 计划模式状态
--- @return table { active, plan }
function M.get_plan_state()
  local agent = M.get_current_agent()
  if not agent then return { active = false, plan = nil } end
  return { active = agent.plan_mode == true, plan = agent.plan }
end

--- 当前 Agent 的待办清单
--- @return table|nil
function M.get_todos()
  local agent = M.get_current_agent()
  if not agent then return nil end
  local todo_mod = require("NeoAI.tools.builtin.todo")
  return todo_mod.get(agent.session_id)
end

--- 创建新会话（新 Agent）；新会话默认从 CHAT 模式开始
--- @param opts table|nil
--- @return table Agent
function M.new_session(opts)
  opts = opts or {}
  state.current_agent_id = nil
  -- 新会话从 CHAT（或显式 opts.mode）开始，丢弃上一会话遗留的待应用模式切换
  pending_mode = nil
  pending_mode_agent_id = nil
  local o = vim.tbl_extend("force", {}, opts, { mode = opts.mode or "chat" })
  return _get_or_create_agent(o)
end

--- 加载已有会话到当前 Agent（从会话树选择时调用）
--- @param session_id string
--- @param opts table|nil { round? number 选中轮次；nil = 整个会话 }
--- @return table Agent
function M.load_session(session_id, opts)
  opts = opts or {}
  local session = session_store.get(session_id)
  if not session then
    return M.new_session({})
  end
  -- 若已有该会话的 Agent 直接复用
  local existing_agent_id = state.sessions and state.sessions[session_id]
  if existing_agent_id then
    local existing = runtime.get(existing_agent_id)
    if existing then
      state.current_agent_id = existing.id
      return existing
    end
  end
  -- 创建新 Agent 并载入会话链消息（祖先链 + 选中会话 + 下游单子链）
  local agent = runtime.create({
    session_id = session.id,
    scenario = "chat",
    model = session.model,
    config = session.provider and { provider = session.provider } or nil,
  })
  local registry = require("NeoAI.tools.registry")
  agent.tools = registry.list_as_map()
  -- 载入历史消息（标记已同步，避免 _persist_agent 把祖先/下游消息误写进选中会话）
  local chain_messages = _build_chain_messages(session, opts.round)
  for _, msg in ipairs(chain_messages) do
    local copy = vim.deepcopy(msg)
    copy._synced = true
    agent.messages[#agent.messages + 1] = copy
  end
  -- 还原计划模式状态（标志 + 计划文本）；易变运行态经运行时上下文快照注入历史，
  -- 不再注册系统提示段，系统提示保持逐字节稳定以复用前缀缓存。
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  plan_mode.restore(agent, session.metadata and session.metadata.plan)
  -- 还原压缩覆盖层：仅当载入链恰好等于会话自身消息时应用（分支链含祖先/下游，索引会错位，
  -- 此时放弃还原，由后续阈值触发重新压缩）。
  local comp = session.metadata and session.metadata.compaction
  if comp and comp.checkpoint and comp.replaced
    and #chain_messages == #(session.messages or {}) then
    agent.compaction = vim.deepcopy(comp)
  end
  -- 还原累计用量（含前缀缓存命中/未命中统计），避免重开会话后缓存命中率归零
  local meta = session.metadata or {}
  if meta.usage and type(meta.usage) == "table" then
    agent.usage = vim.deepcopy(meta.usage)
  end
  -- 还原待办清单（供 todo_read / 运行时上下文快照注入）；系统提示段已废弃，不需注册。
  local todo_mod = require("NeoAI.tools.builtin.todo")
  todo_mod.seed(session.id, session.metadata and session.metadata.todos)
  -- 重开后首次生成时由 runtime.run 的 runtime_context.ensure 重建快照，
  -- 保证易变状态以最新内容注入历史、系统提示稳定。
  require("NeoAI.core.session.runtime_context").ensure(agent)
  state.sessions = state.sessions or {}
  state.sessions[session.id] = agent.id
  state.agents[agent.id] = { session_id = session.id }
  state.current_agent_id = agent.id
  -- 恢复会话后按还原的模式（含计划模式）应用对应 provider/model 配置
  _apply_current_mode(agent)
  -- 会话保存了显式选择的模型/提供商时以其为准，覆盖模式默认（避免重开后回退到
  -- 模式默认模型而把不属于该提供商的模型 id 发往错误端点）。
  if session.model then agent.model = session.model end
  if session.provider then agent.config.provider = session.provider end
  return agent
end

--- 重置（测试用）
function M.reset()
  for _, agent_id in pairs(state.windows) do
    local agent = runtime.get(agent_id)
    if agent then runtime.dispose(agent) end
  end
  state.windows = {}
  state.agents = {}
  state.sessions = {}
  state.current_agent_id = nil
  -- 清理待应用的模式切换与状态监听，避免跨测试/重载残留
  pending_mode = nil
  pending_mode_agent_id = nil
  if queue_state_sub then
    queue_state_sub()
    queue_state_sub = nil
  end
  -- 清理暂存队列、状态监听与注入器，避免测试间/重载后残留并重复发送
  local tool_loop = require("NeoAI.core.agent.tool_loop")
  tool_loop.set_inject_user(nil)
  tool_loop.set_pre_round_refresh(nil)
  injector_registered = false
  mcp_pre_round_registered = false
  if mcp_observer_sub then
    mcp_observer_sub()
    mcp_observer_sub = nil
  end
  for _, q in pairs(pending_queue) do
    for _, item in ipairs(q) do
      item.d:reject({ kind = "cancelled", message = "会话已重置，暂存消息已取消" })
    end
  end
  pending_queue = {}
  -- 恢复 MCP 钩子（幂等）：reset 清空后重新注册，保证工具动态更新仍能被感知与刷新
  _ensure_mcp_hooks()
end

-- 模块加载即注册 MCP 钩子（幂等）：保证工具动态更新在任意时刻都能被感知与刷新。
_ensure_mcp_hooks()

return M
