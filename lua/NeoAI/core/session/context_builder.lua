--- 上下文构建
--- @module NeoAI.core.session.context_builder
--- 从会话构建发送给模型的消息上下文。
--- 替代旧 get_context_and_new_parent 复杂路径算法。

local session_mod = require("NeoAI.core.session.session")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有函数 ==========

--- 构建系统消息
--- @param agent_config table|nil
--- @return table
local function _build_system_message(agent_config)
  local system_prompt = agent_config and agent_config.system_prompt
    or config_store.get("ai.system_prompt")
    or "你是一个AI编程助手，帮助用户解决编程问题。"
  return { role = "system", content = system_prompt }
end

--- 将内部消息转换为 API 消息
--- @param message table
--- @return table
local function _to_api_message(message)
  local out = { role = message.role, content = message.content or "" }
  if message.reasoning and message.role == "assistant" then
    -- 推理内容随回复一起保留（部分 API 用 reasoning_content 字段）
    out.reasoning_content = message.reasoning
  end
  if message.tool_calls and #message.tool_calls > 0 then
    out.tool_calls = message.tool_calls
  end
  if message.tool_call_id then
    out.tool_call_id = message.tool_call_id
  end
  return out
end

-- ========== 公开 API ==========

--- 从会话构建上下文消息列表
--- @param session table
--- @param opts table|nil { max_history?=session 配置, include_system?=true, extra_user?=string|nil }
--- @return table API 消息数组
function M.build(session, opts)
  opts = opts or {}
  local messages = {}
  if opts.include_system ~= false then
    messages[#messages + 1] = _build_system_message(opts.agent_config)
  end
  local max_history = opts.max_history
    or config_store.get("session.max_history_per_session")
    or 1000
  local source = session.messages
  -- 截断历史（保留最近的 max_history 条非 system）
  local non_system = {}
  for _, m in ipairs(source) do
    if m.role ~= "system" then
      non_system[#non_system + 1] = m
    end
  end
  local start = math.max(1, #non_system - max_history + 1)
  for i = start, #non_system do
    messages[#messages + 1] = _to_api_message(non_system[i])
  end
  if opts.extra_user then
    messages[#messages + 1] = { role = "user", content = opts.extra_user }
  end
  return messages
end

--- 从 Agent 构建上下文消息（Agent 持有私有消息队列 + 配置）
--- @param agent table Agent
--- @param opts table|nil { max_history?, include_system? }
--- @return table API 消息数组
function M.build_from_agent(agent, opts)
  opts = opts or {}
  local messages = {}
  if opts.include_system ~= false then
    local system_prompt = (agent.config and agent.config.system_prompt)
      or config_store.get("ai.system_prompt")
      or "你是一个AI编程助手，帮助用户解决编程问题。"
    messages[#messages + 1] = { role = "system", content = system_prompt }
  end
  local max_history = opts.max_history
    or config_store.get("session.max_history_per_session")
    or 1000
  local source = agent.messages or {}
  local start = math.max(1, #source - max_history + 1)
  for i = start, #source do
    messages[#messages + 1] = _to_api_message(source[i])
  end
  if opts.extra_user then
    messages[#messages + 1] = { role = "user", content = opts.extra_user }
  end
  return messages
end

--- 从父会话派生子会话的初始上下文
--- @param session table 当前会话
--- @param task string|nil 附加任务描述（作为 user 消息）
--- @return table 上下文消息
function M.build_fork_context(session, task)
  local ctx = session_mod.fork(session, { copy_messages = true })
  local messages = M.build(ctx)
  if task then
    messages[#messages + 1] = { role = "user", content = task }
  end
  return messages
end

--- 统计上下文的 token 估算（字符/4 粗估）
--- @param messages table
--- @return number
function M.estimate_tokens(messages)
  local total = 0
  for _, m in ipairs(messages or {}) do
    local content = m.content or ""
    total = total + math.ceil(#content / 4)
    if m.tool_calls then
      for _, tc in ipairs(m.tool_calls) do
        local fn = tc["function"]
        total = total + math.ceil(#(fn and fn.name or "") / 4)
        total = total + math.ceil(#(fn and fn.arguments or "") / 4)
      end
    end
  end
  return total
end

return M
