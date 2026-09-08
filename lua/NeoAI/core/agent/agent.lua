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
    cache = {
      last_prefix_id = nil, -- 上一个请求的前缀缓存身份指纹
      identity_changes = 0, -- 缓存身份变更次数
      compaction_usage = nil, -- 最近一次压缩摘要调用的缓存用量
    },
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

--- 给最后一条 assistant 消息附加请求/响应元数据（仅供轨迹展示，不进入模型上下文）
--- @param agent table
--- @param round table { request?, response? }
--- @return table|nil 消息
function M.attach_round(agent, round)
  local last = agent.messages[#agent.messages]
  if not last or last.role ~= "assistant" then return nil end
  if round and round.request then last.request = round.request end
  if round and round.response then last.response = round.response end
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
--- @param extra table|nil { duration_ms? } 附加元数据（仅 UI 展示用，不进入模型上下文）
--- @return table 消息
function M.add_tool_result(agent, tool_call_id, tool_name, result, extra)
  local msg = {
    role = "tool",
    tool_call_id = tool_call_id,
    tool_name = tool_name,
    content = result or "",
    ts = os.time(),
  }
  if extra then
    for k, v in pairs(extra) do
      msg[k] = v
    end
  end
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
  agent._turn_claim = nil
  event_bus.emit(events.AGENT_DISPOSED, { agent_id = agent.id })
end

-- ========== 其它 ==========

--- 累加 usage（兼容 openai 的 prompt_tokens/completion_tokens 与内部 prompt/completion 两种形状）
--- @param agent table
--- @param usage table
--- @return table Agent
function M.add_usage(agent, usage)
  local prompt_all = tonumber(usage.prompt or usage.prompt_tokens or 0) or 0
  local completion = tonumber(usage.completion or usage.completion_tokens or 0) or 0
  local prefix = require("NeoAI.core.agent.prefix")
  local cu = prefix.parse_cache_usage(usage)
  local cache_read = cu and cu.cache_read or 0
  -- 对齐 deepseek-harness：DeepSeek 的 prompt_tokens 已折叠缓存命中
  -- （prompt_tokens = prompt_cache_hit_tokens + prompt_cache_miss_tokens），计费的
  -- 「未缓存输入」= prompt_tokens - cache_read，缓存命中单独统计、不重复计入输入。
  -- 对不返回 cache 计数的 provider（cache_read=0）此式退化为原值，无副作用。
  agent.usage.prompt = agent.usage.prompt + math.max(0, prompt_all - cache_read)
  agent.usage.completion = agent.usage.completion + completion
  if cu then
    agent.usage.cache_read = (agent.usage.cache_read or 0) + cu.cache_read
    agent.usage.cache_write = (agent.usage.cache_write or 0) + cu.cache_write
    agent.usage.cache_miss = (agent.usage.cache_miss or 0) + cu.cache_miss
    agent.usage.requests = (agent.usage.requests or 0) + 1
    -- 缓存命中率只对 prompt 维度（DeepSeek 缓存不涉及输出 token）
    agent.usage.prompt_cache_total = (agent.usage.prompt_cache_total or 0) + cu.cache_read
    agent.usage.prompt_total = (agent.usage.prompt_total or 0) + prompt_all
    agent.usage.cache_ratio = agent.usage.prompt_total > 0
      and (agent.usage.prompt_cache_total / agent.usage.prompt_total)
      or 0
  end
  return agent
end

--- 重置（测试用）
function M.reset_state()
  STATES = nil -- 保持常量引用
end

return M
