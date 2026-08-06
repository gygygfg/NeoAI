--- Agent 对象
--- @module NeoAI.core.agent.agent
--- 每次对话 = 全新 Agent 实例。持有私有消息队列、工具集、取消信号。
--- 状态机：idle → generating → tool_running → idle（或 aborted / error）
--- 纯净对象，不含 I/O；运行时行为在 runtime.lua。

local stringx = require("NeoAI.utils.stringx")
local async = require("NeoAI.utils.async")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 状态常量 ==========

local STATES = {
  IDLE = "idle",
  GENERATING = "generating",
  TOOL_RUNNING = "tool_running",
  ABORTED = "aborted",
  ERROR = "error",
}

-- ========== 构造函数 ==========

--- 创建 Agent 实例
--- @param opts table { session_id?, config?, tools?, model?, parent? }
--- @return table Agent
function M.create(opts)
  opts = opts or {}
  local agent = {
    id = stringx.uuid("agent"),
    session_id = opts.session_id or nil,
    parent = opts.parent or nil, -- parent agent id
    config = vim.deepcopy(opts.config or {}), -- 配置快照
    messages = {}, -- 私有消息队列
    tools = vim.deepcopy(opts.tools or {}), -- 可见工具子集（name -> tool def）
    model = opts.model or nil,
    signal = opts.signal or async.create_signal(),
    state = STATES.IDLE,
    iterations = 0,
    usage = { prompt = 0, completion = 0 },
  }
  setmetatable(agent, { __index = M })
  return agent
end

-- ========== 状态 ==========

--- 设置状态并触发事件
--- @param agent table
--- @param new_state string
function M.set_state(agent, new_state)
  if agent.state == new_state then return agent end
  local old = agent.state
  agent.state = new_state
  event_bus.emit(events.AGENT_STATE_CHANGED, { agent_id = agent.id, old = old, new = new_state })
  return agent
end

--- 当前状态
--- @param agent table
--- @return string
function M.get_state(agent)
  return agent.state
end

--- 是否空闲（可接收新输入）
--- @param agent table
--- @return boolean
function M.is_idle(agent)
  return agent.state == STATES.IDLE
end

--- 是否忙碌
--- @param agent table
--- @return boolean
function M.is_busy(agent)
  return agent.state == STATES.GENERATING or agent.state == STATES.TOOL_RUNNING
end

--- 是否已取消
--- @param agent table
--- @return boolean
function M.is_aborted(agent)
  return agent.state == STATES.ABORTED or agent.signal:aborted()
end

-- ========== 消息 ==========

--- 添加消息到私有队列
--- @param agent table
--- @param role string
--- @param content string
--- @param extra table|nil { reasoning?, tool_calls? }
--- @return table 消息
function M.add_message(agent, role, content, extra)
  local msg = {
    role = role,
    content = content or "",
    ts = os.time(),
  }
  if extra then
    for k, v in pairs(extra) do
      msg[k] = vim.deepcopy(v)
    end
  end
  table.insert(agent.messages, msg)
  event_bus.emit(events.MESSAGE_ADDED, { agent_id = agent.id, message = msg })
  return msg
end

--- 追加流式内容到最后一条 assistant 消息
--- @param agent table
--- @param chunk string
--- @return table 消息
function M.append_content(agent, chunk)
  local last = agent.messages[#agent.messages]
  if not last or last.role ~= "assistant" then
    last = M.add_message(agent, "assistant", "")
  end
  last.content = last.content .. (chunk or "")
  event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = last })
  return last
end

--- 追加推理内容
--- @param agent table
--- @param chunk string
--- @return table 消息
function M.append_reasoning(agent, chunk)
  local last = agent.messages[#agent.messages]
  if not last or last.role ~= "assistant" then
    last = M.add_message(agent, "assistant", "")
  end
  last.reasoning = (last.reasoning or "") .. (chunk or "")
  event_bus.emit(events.REASONING_CHUNK, {
    agent_id = agent.id,
    chunk = chunk or "",
    reasoning = last.reasoning,
  })
  return last
end

--- 获取消息
--- @param agent table
--- @return table
function M.get_messages(agent)
  return agent.messages
end

--- 设置工具调用到最后一条 assistant 消息
--- @param agent table
--- @param tool_calls table
--- @return table 消息
function M.set_tool_calls(agent, tool_calls)
  local last = agent.messages[#agent.messages]
  if not last or last.role ~= "assistant" then
    last = M.add_message(agent, "assistant", "")
  end
  last.tool_calls = tool_calls
  event_bus.emit(events.TOOL_CALL_DETECTED, { agent_id = agent.id, tool_calls = tool_calls })
  return last
end

--- 添加工具结果消息
--- @param agent table
--- @param tool_call_id string
--- @param tool_name string
--- @param result string
--- @return table 消息
function M.add_tool_result(agent, tool_call_id, tool_name, result)
  local msg = {
    role = "tool",
    tool_call_id = tool_call_id,
    tool_name = tool_name,
    content = result or "",
    ts = os.time(),
  }
  table.insert(agent.messages, msg)
  event_bus.emit(events.TOOL_RESULT_RECEIVED, { agent_id = agent.id, message = msg })
  return msg
end

-- ========== 工具 ==========

--- 是否拥有工具
--- @param agent table
--- @param name string
--- @return boolean
function M.has_tool(agent, name)
  return agent.tools[name] ~= nil
end

--- 获取工具
--- @param agent table
--- @param name string
--- @return table|nil
function M.get_tool(agent, name)
  return agent.tools[name]
end

-- ========== 取消 ==========

--- 取消 Agent（级联传播到 HTTP + 工具）
--- @param agent table
--- @param reason string|nil
--- @return table Agent
function M.abort(agent, reason)
  agent.signal:abort(reason or "user_cancelled")
  M.set_state(agent, STATES.ABORTED)
  event_bus.emit(events.AGENT_ABORTED, { agent_id = agent.id, reason = agent.signal:reason() })
  return agent
end

--- 取消信号
--- @param agent table
--- @return Signal
function M.get_signal(agent)
  return agent.signal
end

-- ========== 清理 ==========

--- 释放资源（窗口关闭/任务结束）
--- @param agent table
function M.dispose(agent)
  if not agent.signal:aborted() then
    agent.signal:abort("disposed")
  end
  agent.messages = {}
  agent.tools = {}
  agent.state = STATES.IDLE
  event_bus.emit(events.AGENT_DISPOSED, { agent_id = agent.id })
end

-- ========== 其它 ==========

--- 累加 usage
--- @param agent table
--- @param usage table
--- @return table Agent
function M.add_usage(agent, usage)
  agent.usage.prompt = agent.usage.prompt + (usage.prompt or 0)
  agent.usage.completion = agent.usage.completion + (usage.completion or 0)
  return agent
end

--- 重置（测试用）
function M.reset_state()
  STATES = nil -- 保持常量引用
end

return M
