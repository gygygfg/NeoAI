--- Agent 对象
--- @module NeoAI.core.agent.agent
--- 每次对话 = 全新 Agent 实例。持有私有消息队列、工具集、取消信号。
--- 状态机：idle → generating → tool_running → idle（或 aborted / error）
--- 纯净对象，不含 I/O；运行时行为在 runtime.lua。

local stringx = require("NeoAI.utils.stringx")
local async = require("NeoAI.utils.async")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local config_store = require("NeoAI.kernel.config_store")

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

-- 前向声明：add_message/add_tool_result 在 _event_message_stub 定义前引用它。
-- 局部函数前向引用会解析到 global nil，故先声明后赋函数体（见流式累积段）。
local _event_message_stub

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
  event_bus.emit(events.MESSAGE_ADDED, { agent_id = agent.id, message = _event_message_stub(msg) })
  return msg
end

-- ========== 流式累积（避免 O(n²) 拼接） ==========
-- 逐分片 `field = field .. chunk` 对长响应是 O(n²) 主线程拷贝（每个分片都复制整段）。
-- 自适应策略：小内容（< SMALL_CONTENT_BYTES）逐分片物化，行为与旧实现完全一致（UI 实时、
-- 单测语义不变）；超过后改为分片数组累积，达到字节/分片/时间阈值才物化一次，流结束强制物化。
-- 这样把长响应的 O(n²) 降为「按阈值/时间分段」的有界拷贝，同时不牺牲小响应实时性。
-- 阈值取 8KB：64KB 窗口下 60KB 响应按小分片追加实测 ~100ms 主线程（O(n²) 拷贝）；
-- 降到 8KB 后同规模响应只做有界分段拷贝（大响应内容最多滞后 ~100ms，随后自愈）。

local SMALL_CONTENT_BYTES = 8192
local MATERIALIZE_BYTES = 131072
local MATERIALIZE_PARTS = 2048
local MATERIALIZE_INTERVAL_MS = 100

--- 把增量分片并入正式字段（内部）
--- @param msg table
--- @param field string
--- @param parts_field string
local function _materialize(msg, field, parts_field)
  local parts = msg[parts_field]
  if not parts or #parts == 0 then
    msg[parts_field] = nil
    return
  end
  msg[field] = (msg[field] or "") .. table.concat(parts)
  for i = #parts, 1, -1 do parts[i] = nil end
  msg[parts_field] = nil
end

--- 追加一个流式分片（自适应物化）
--- @param msg table
--- @param field string
--- @param parts_field string
--- @param bytes_field string
--- @param time_field string
--- @param chunk string
local function _append_stream_field(msg, field, parts_field, bytes_field, time_field, chunk)
  local parts = msg[parts_field]
  if not parts then
    parts = {}
    msg[parts_field] = parts
  end
  parts[#parts + 1] = chunk
  local pending = (msg[bytes_field] or 0) + #chunk
  msg[bytes_field] = pending
  local total = #(msg[field] or "") + pending
  local now = vim.uv.hrtime() / 1e6
  local due = total < SMALL_CONTENT_BYTES
    or pending >= MATERIALIZE_BYTES
    or #parts >= MATERIALIZE_PARTS
    or (msg[time_field] and (now - msg[time_field]) >= MATERIALIZE_INTERVAL_MS)
  if due then
    _materialize(msg, field, parts_field)
    msg[bytes_field] = nil
    msg[time_field] = now
  end
end

--- 事件用轻量消息视图：只保留订阅方需要的标量字段，剔除大文本（content/reasoning）、
--- 累积中的流式瞬态字段（`_` 前缀分片数组）与 tool_calls 详情。
--- 事件经 `nvim_exec_autocmds` 传递 data 会深拷贝：若 payload 携带完整正文/工具结果/
--- 原始分片，每个分片都要复制整段内容，退化为 O(n²) 主线程开销与内存峰值。订阅方
--- （chat_view）只判断「正文是否开始 / 消息是否变化」，并从 agent 消息队列读取内容渲染，
--- 故事件只暴露这些标量标志。
--- @param msg table
--- @return table
_event_message_stub = function(msg)
  return {
    role = msg.role,
    ts = msg.ts,
    tool_call_id = msg.tool_call_id,
    tool_name = msg.tool_name,
    checkpoint = msg.checkpoint,
    runtime_context = msg.runtime_context,
    has_content = type(msg.content) == "string" and msg.content ~= "",
    has_reasoning = type(msg.reasoning) == "string" and msg.reasoning ~= "",
    tool_call_count = type(msg.tool_calls) == "table" and #msg.tool_calls or 0,
  }
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
  chunk = chunk or ""
  _append_stream_field(last, "content", "_content_parts", "_content_bytes", "_content_at", chunk)
  event_bus.emit(events.MESSAGE_UPDATED, { agent_id = agent.id, message = _event_message_stub(last) })
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
  chunk = chunk or ""
  _append_stream_field(last, "reasoning", "_reasoning_parts", "_reasoning_bytes", "_reasoning_at", chunk)
  -- 只发分片本身：不再随每个分片携带完整累计 reasoning（深拷贝 O(n²)）。
  -- 订阅方需要完整文本时从 agent 消息队列读取。
  event_bus.emit(events.REASONING_CHUNK, {
    agent_id = agent.id,
    chunk = chunk,
  })
  return last
end

--- 物化流式累积缓冲：把最后一条消息的 content/reasoning 增量并入正式字段。
--- 流结束时（stream.processor.finish）必须调用，保证读取方拿到完整文本。
--- @param agent table
function M.finalize_stream(agent)
  if not agent or not agent.messages then return end
  local last = agent.messages[#agent.messages]
  if not last then return end
  _materialize(last, "content", "_content_parts")
  _materialize(last, "reasoning", "_reasoning_parts")
  last._content_bytes = nil
  last._reasoning_bytes = nil
  last._content_at = nil
  last._reasoning_at = nil
end

-- ========== 轨迹 wire 数据（有界保留） ==========
-- 每轮请求体随上下文增长，原始 SSE 分片单轮上限 300KB；若全部常驻，长工具循环内存会
-- 线性/二次膨胀且不落盘（会话持久化不含 request/response）。这里只保留最近 max_rounds
-- 轮完整数据，更早轮次降级为轻量摘要（完整数据由实时落盘机制保存）。

local TRACE_MAX_ROUNDS_DEFAULT = 8

--- 解析 wire 数据保留配置
--- @return boolean capture
--- @return number max_rounds
local function _trace_cfg()
  local cfg = config_store.get("ai.trace") or {}
  local capture = cfg.capture ~= false
  local max_rounds = tonumber(cfg.max_rounds) or TRACE_MAX_ROUNDS_DEFAULT
  if max_rounds < 1 then max_rounds = 1 end
  return capture, max_rounds
end

--- 把一轮的 request/response 元数据降级为轻量摘要（丢弃完整请求体与原始 SSE 分片）
--- @param msg table
local function _summarize_round(msg)
  if not msg then return end
  local req = msg.request
  if req then
    local body = req.body or {}
    msg.request = {
      model = req.model,
      provider = req.provider,
      body = {
        stream = body.stream,
        temperature = body.temperature,
        max_tokens = body.max_tokens,
        message_count = body.message_count
          or (type(body.messages) == "table" and #body.messages or 0),
        tool_count = body.tool_count
          or (type(body.tools) == "table" and #body.tools or 0),
      },
    }
  end
  local resp = msg.response
  if resp then
    msg.response = {
      finish_reason = resp.finish_reason,
      usage = resp.usage,
      ttft_ms = resp.ttft_ms,
      total_ms = resp.total_ms,
      status = resp.status,
      raw_truncated = true,
    }
  end
end

--- 维护有界的 wire 数据保留窗口。
--- capture=false 时立即摘要化；否则保留最近 max_rounds 轮，旧轮摘要化。
--- 同一条 assistant 消息可能被多次 attach（截断续写对同一消息追加），尾部去重。
--- @param agent table
--- @param msg table
local function _retain_trace(agent, msg)
  local capture, max_rounds = _trace_cfg()
  if not capture then
    _summarize_round(msg)
    return
  end
  local trace = agent._trace_rounds
  if not trace then
    trace = {}
    agent._trace_rounds = trace
  end
  if trace[#trace] ~= msg then
    trace[#trace + 1] = msg
  end
  while #trace > max_rounds do
    local old = table.remove(trace, 1)
    if old and old ~= msg then _summarize_round(old) end
  end
end

--- 给最后一条 assistant 消息附加请求/响应元数据（仅供轨迹展示，不进入模型上下文）
--- 超出保留窗口的旧轮会降级为轻量摘要，避免长循环内存膨胀。
--- @param agent table
--- @param round table { request?, response? }
--- @return table|nil 消息
function M.attach_round(agent, round)
  local last = agent.messages[#agent.messages]
  if not last or last.role ~= "assistant" then return nil end
  if round and round.request then last.request = round.request end
  if round and round.response then last.response = round.response end
  _retain_trace(agent, last)
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
--- @param extra table|nil { duration_ms?, notice? } 附加元数据（仅 UI 展示用，不进入模型上下文）
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
  event_bus.emit(events.TOOL_RESULT_RECEIVED, { agent_id = agent.id, message = _event_message_stub(msg) })
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
  agent.compaction = nil
  agent.tools = {}
  agent.state = STATES.IDLE
  agent._turn_claim = nil
  agent._trace_rounds = nil
  event_bus.emit(events.AGENT_DISPOSED, { agent_id = agent.id })
end

-- ========== 其它 ==========

--- 累加 usage（兼容 openai 的 prompt_tokens/completion_tokens 与内部 prompt/completion 两种形状）
--- 按模型缓存机制分派解析缓存命中（Anthropic/Gemini 字段与 OpenAI/DeepSeek 不同）。
--- @param agent table
--- @param usage table
--- @return table Agent
function M.add_usage(agent, usage)
  if type(usage) ~= "table" then return agent end
  local meta_usage = usage.usageMetadata or usage
  local provider_name = agent.config and agent.config.provider or nil
  local prefix = require("NeoAI.core.agent.prefix")
  local cu = prefix.parse_cache_usage(usage, agent.model, provider_name)
  local cache_read = cu and cu.cache_read or 0
  -- 输入总量（含缓存命中）：OpenAI/DeepSeek 的 prompt_tokens 已含命中；Anthropic/Gemini
  -- 无此字段时用解析器归一量（未命中+命中+写入）回退。
  local prompt_all = tonumber(usage.prompt or meta_usage.prompt_tokens or meta_usage.promptTokenCount)
  if not prompt_all and cu then
    prompt_all = cu.cache_read + cu.cache_write + cu.cache_miss
  end
  prompt_all = prompt_all or 0
  local completion = tonumber(usage.completion or meta_usage.completion_tokens
    or meta_usage.output_tokens or meta_usage.candidatesTokenCount or 0) or 0
  -- 最近一次请求的 API 实际用量：容量显示/压缩阈值优先据此计算，避免本地字符估算偏差
  -- （prompt_all 含缓存命中，即真实送入模型的上下文规模）。
  agent.usage.last_prompt = prompt_all
  agent.usage.last_prompt_uncached = math.max(0, prompt_all - cache_read)
  agent.usage.last_completion = completion
  agent.usage.last_cache_read = cache_read
  -- 计费的「未缓存输入」= 输入总量 - 缓存命中，缓存命中单独统计、不重复计入输入。
  -- 对不返回 cache 计数的 provider（cache_read=0）此式退化为原值，无副作用。
  agent.usage.prompt = agent.usage.prompt + math.max(0, prompt_all - cache_read)
  agent.usage.completion = agent.usage.completion + completion
  if cu then
    agent.usage.cache_read = (agent.usage.cache_read or 0) + cu.cache_read
    agent.usage.cache_write = (agent.usage.cache_write or 0) + cu.cache_write
    agent.usage.cache_miss = (agent.usage.cache_miss or 0) + cu.cache_miss
    agent.usage.requests = (agent.usage.requests or 0) + 1
    -- 缓存命中率只对 prompt 维度（缓存不涉及输出 token）
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
