--- 聊天服务
--- @module NeoAI.services.chat_service
--- 前后端桥梁。UI 通过此服务发送消息、绑定/解绑窗口。
--- - send_message(content)：创建或复用当前 Agent 并发送
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
      session_mod.add_message(session, {
        role = msg.role,
        content = msg.content or "",
        reasoning = msg.reasoning,
        tool_calls = msg.tool_calls,
        tool_call_id = msg.tool_call_id,
      })
      msg._synced = true
    end
  end
  session.model = agent.model
  session.metadata.usage = agent.usage
  if session.metadata.auto_naming == false then end
  session_store.persist(session)
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
    runtime.dispose(agent)
    state.agents[agent_id] = nil
    local session_id = agent.session_id
    if session_id and state.sessions[session_id] == agent_id then
      state.sessions[session_id] = nil
    end
  end
  state.windows[win_id] = nil
end

--- 取消当前生成
function M.cancel_generation()
  local agent = M.get_current_agent()
  if agent then
    runtime.abort(agent, "user_cancelled")
  end
end

--- 切换当前 Agent 模型
--- @param model_id string
function M.switch_model(model_id)
  local agent = M.get_current_agent()
  if agent then
    agent.model = model_id
  end
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
--- @return table Agent
function M.load_session(session_id)
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
  -- 创建新 Agent 并载入会话消息
  local agent = runtime.create({
    session_id = session.id,
    scenario = "chat",
    model = session.model,
  })
  local registry = require("NeoAI.tools.registry")
  agent.tools = registry.list_as_map()
  -- 载入历史消息（标记已同步）
  for _, msg in ipairs(session.messages or {}) do
    local copy = vim.deepcopy(msg)
    copy._synced = true
    agent.messages[#agent.messages + 1] = copy
  end
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
