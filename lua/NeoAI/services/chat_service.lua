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

-- ========== 私有函数 ==========

--- 判断 Agent 是否已被销毁
--- @param agent table
--- @return boolean
local function agent_mod_is_disposed(agent)
  return agent.state == "disposed" or (agent.messages and #agent.messages == 0 and agent.signal and agent.signal:aborted())
end

--- 创建/获取当前 Agent
--- @param opts table|nil { model?, scenario? }
--- @return table Agent
local function _get_or_create_agent(opts)
  opts = opts or {}
  local agent_id = state.current_agent_id
  local agent = agent_id and runtime.get(agent_id) or nil
  if not agent or agent_mod_is_disposed(agent) then
    local session = session_store.create()
    agent = runtime.create({
      session_id = session.id,
      scenario = opts.scenario or "chat",
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
  if not info then return end
  local session = session_store.get(info.session_id)
  if not session then return end
  -- 同步消息
  for _, msg in ipairs(agent.messages) do
    if not msg._synced then
      -- 压缩检查点：先在 durable surface 移除被替换的已同步旧消息（替换而非追加）
      if msg.checkpoint and msg.replaced_count and session.messages then
        local n = math.min(msg.replaced_count, #session.messages)
        for _ = 1, n do
          table.remove(session.messages, 1)
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
      msg._synced = true
    end
  end
  session.model = agent.model
  session.metadata.usage = agent.usage
  -- 同步待办清单与计划模式状态到 durable surface（重开会话时还原）
  local todo_mod = require("NeoAI.tools.builtin.todo")
  session.metadata.todos = todo_mod.get(info.session_id)
  session.metadata.plan = {
    active = agent.plan_mode == true,
    plan = agent.plan,
  }
  if session.metadata.auto_naming == false then end
  session_store.persist(session)
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
  event_bus.emit(events.MESSAGE_SENT, { agent_id = agent.id, content = content })
  return runtime.run(agent, content):then_(function(resp)
    _persist_agent(agent)
    return resp
  end, function(err)
    _persist_agent(agent)
    return async.reject(err)
  end)
end

--- 获取当前 Agent
--- @return table|nil
function M.get_current_agent()
  if not state.current_agent_id then return nil end
  return runtime.get(state.current_agent_id)
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
    _persist_agent(agent)
    local session_id = agent.session_id
    runtime.dispose(agent)
    if session_id then
      local todo_mod = require("NeoAI.tools.builtin.todo")
      todo_mod.cleanup(session_id)
    end
    state.agents[agent_id] = nil
    if session_id and state.sessions[session_id] == agent_id then
      state.sessions[session_id] = nil
    end
  end
  state.windows[win_id] = nil
  -- 窗口关闭时清理正在展示/排队的审批，释放串行审批槽位，
  -- 否则 approval_showing 残留 true 会让后续工具审批只入队不弹窗，循环卡死。
  local tool_service = require("NeoAI.services.tool_service")
  tool_service.clear_approval()
end

--- 取消当前生成
function M.cancel_generation()
  local agent = M.get_current_agent()
  if agent then
    runtime.abort(agent, "user_cancelled")
  end
  -- 取消时同样清理待审批项（弹窗与信号无关，abort 不会自动关掉它），
  -- 释放串行槽位，避免下一轮工具调用卡在审批队列。
  local tool_service = require("NeoAI.services.tool_service")
  tool_service.clear_approval()
end

--- 切换当前 Agent 模型
--- @param model_id string
function M.switch_model(model_id)
  local agent = M.get_current_agent()
  if agent then
    agent.model = model_id
  end
end

--- 切换当前 Agent 的计划模式
--- @return boolean|nil 切换后的状态（无 Agent 时 nil）
function M.toggle_plan_mode()
  local agent = M.get_current_agent()
  if not agent then return nil end
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  return plan_mode.toggle(agent)
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
  local plan = agent.plan
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
  plan_mode.exit(agent) -- 直接转入 CHAT 模式
  _persist_agent(agent)

  local auto = opts.auto_execute
  if auto == nil then
    auto = config_store.get("tools.plan_mode.auto_execute_on_approve") ~= false
  end
  if auto and #items > 0 then
    -- 自动执行：以确认指令驱动一轮生成，AI 按任务清单（todo）开始工作
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
  local tool_service = require("NeoAI.services.tool_service")
  return tool_service.toggle_auto_mode()
end

--- 是否处于 AUTO 模式
--- @return boolean
function M.is_auto_mode()
  local tool_service = require("NeoAI.services.tool_service")
  return tool_service.is_auto_mode()
end

--- 当前模式（互斥：一次只处于一种模式）
--- @return string "chat" | "plan" | "auto"
function M.get_mode()
  local plan = M.get_plan_state()
  local auto = M.is_auto_mode()
  if auto then return "auto" end
  if plan.active then return "plan" end
  return "chat"
end

--- 循环切换模式：chat -> plan -> auto -> chat
--- @return string 切换后的模式
function M.cycle_mode()
  local tool_service = require("NeoAI.services.tool_service")
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  local mode = M.get_mode()
  if mode == "chat" then
    -- 进入计划模式（无 Agent 时先创建）
    local agent = M.get_current_agent() or M.new_session({})
    plan_mode.enter(agent)
    tool_service.set_auto_mode(false)
    return "plan"
  elseif mode == "plan" then
    -- 退出计划模式，进入 AUTO
    local agent = M.get_current_agent()
    if agent then plan_mode.exit(agent) end
    tool_service.set_auto_mode(true)
    return "auto"
  else -- auto
    tool_service.set_auto_mode(false)
    return "chat"
  end
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

--- 创建新会话（新 Agent）
--- @param opts table|nil
--- @return table Agent
function M.new_session(opts)
  opts = opts or {}
  state.current_agent_id = nil
  return _get_or_create_agent(opts)
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
  -- 还原计划模式状态（计划模式提示段 + 标志）
  local plan_mode = require("NeoAI.tools.builtin.plan_mode")
  plan_mode.restore(agent, session.metadata and session.metadata.plan)
  -- 还原待办清单（供 todo_read / 系统提示注入）
  local todo_mod = require("NeoAI.tools.builtin.todo")
  todo_mod.seed(session.id, session.metadata and session.metadata.todos)
  state.sessions = state.sessions or {}
  state.sessions[session.id] = agent.id
  state.agents[agent.id] = { session_id = session.id }
  state.current_agent_id = agent.id
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
end

return M
