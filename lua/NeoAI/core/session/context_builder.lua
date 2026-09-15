--- 上下文构建
--- @module NeoAI.core.session.context_builder
--- 从会话构建发送给模型的消息上下文。
--- 替代旧 get_context_and_new_parent 复杂路径算法。

local session_mod = require("NeoAI.core.session.session")
local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有函数 ==========

--- 构建系统消息（按有序段渲染，前缀缓存稳定）
--- @param agent table|nil
--- @return table
local function _build_system_message(agent)
  local prefix = require("NeoAI.core.agent.prefix")
  return { role = "system", content = prefix.build_system_prompt(agent) }
end

--- 将内部消息转换为 API 消息（供压缩回放等复用，保证字节一致）
--- OpenAI/DeepSeek 工具调用协议要求：带 tool_calls 的 assistant 消息，content 必须
--- 为 null（或省略该字段）。发送 content:"" 会被要求严格的模型判定为格式异常，
--- 在后续轮次直接返回空输出（无内容、无工具调用），表现为工具循环进入第二轮后
--- 模型"未返回后续内容"（EMPTY_RESPONSE_MESSAGE，相当于第二轮 turn 无法开启）。
--- @param message table
--- @return table
local function _to_api_message(message)
  local content = message.content or ""
  local has_tool_calls = message.tool_calls and #message.tool_calls > 0
  local out = { role = message.role }
  -- 仅当 assistant 消息带 tool_calls 且 content 为空时省略 content 字段；
  -- 有实际内容的 assistant 消息、普通消息、tool 消息保持原样输出。
  if content ~= "" or message.role ~= "assistant" or not has_tool_calls then
    out.content = content
  end
  -- 推理内容（reasoning_content / 思维链）不随历史回传，仅用于 UI 展示：
  --   1) 符合 OpenAI/DeepSeek 协议（assistant 消息无 reasoning_content 字段）；
  --   2) 避免每次请求把整段思维链重复发送，显著降低 prompt token；
  --   3) 推理内容若随两轮之间的变化写回，会让 DeepSeek 前缀缓存从该 assistant 消息起
  --      字节不一致而失效（这里规避，缓存命中率更高）。内部 message.reasoning 仍保留用于渲染。
  if has_tool_calls then
    out.tool_calls = message.tool_calls
  end
  if message.tool_call_id then
    out.tool_call_id = message.tool_call_id
  end
  return out
end

--- 只修复出站副本：中断/循环上限可能留下未完成调用，旧历史也可能有孤立结果。
--- 结果必须紧跟调用且每个 id 恰好一次；缺失结果不代表工具未执行，不能伪造成功。
local function _balance_tools(messages)
  local out, pending, order = {}, {}, {}
  local function flush()
    for _, id in ipairs(order) do
      if pending[id] then
        out[#out + 1] = {
          role = "tool", tool_call_id = id,
          content = "Tool result unavailable: this call has no recorded result. Execution status is unknown; verify any side effects before retrying.",
        }
      end
    end
    pending, order = {}, {}
  end
  for _, m in ipairs(messages) do
    if m.role == "tool" then
      if m.tool_call_id and pending[m.tool_call_id] then
        out[#out + 1] = m
        pending[m.tool_call_id] = nil
      end
    else
      flush()
      out[#out + 1] = m
      if m.role == "assistant" then
        for _, tc in ipairs(m.tool_calls or {}) do
          if tc.id and not pending[tc.id] then
            pending[tc.id] = true
            order[#order + 1] = tc.id
          end
        end
      end
    end
  end
  flush()
  return out
end

--- 若窗口从工具结果开始，向前扩展到发起调用的消息，保留完整工具轮次。
local function _history_start(source, max_history)
  local start = math.max(1, #source - max_history + 1)
  while start > 1 and source[start] and source[start].role == "tool" do
    start = start - 1
  end
  return start
end

--- 应用压缩覆盖层：检查点消息取代 messages 的前 replaced 条「非运行态快照」消息。
--- 运行态快照（runtime_context）若落在被替换前缀内则一并折叠；前缀之后的消息全部保留。
--- 覆盖层不改动原始 messages（渲染仍为原始上下文），仅用于构建请求视图。
--- @param messages table 原始内部消息
--- @param comp table|nil { checkpoint = table, replaced = number }
--- @return table 请求视图消息数组
local function _apply_overlay(messages, comp)
  messages = messages or {}
  if type(comp) ~= "table" or not comp.checkpoint or type(comp.replaced) ~= "number" or comp.replaced <= 0 then
    return messages
  end
  local out = { comp.checkpoint }
  local skipped = 0
  for _, m in ipairs(messages) do
    if skipped < comp.replaced then
      if m and m.runtime_context then
        -- 前缀内的运行态快照随被替换区间一并折叠（检查点已概括）
      else
        skipped = skipped + 1
      end
    else
      out[#out + 1] = m
    end
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
    messages[#messages + 1] = _build_system_message(nil)
  end
  local max_history = opts.max_history
    or config_store.get("session.max_history_per_session")
    or 1000
  -- 请求视图：应用会话持久化的压缩覆盖层（渲染仍用原始 session.messages）
  local comp = session.metadata and session.metadata.compaction
  local source = _apply_overlay(session.messages, comp)
  -- 截断历史（保留最近的 max_history 条非 system）
  local non_system = {}
  for _, m in ipairs(source) do
    if m.role ~= "system" then
      non_system[#non_system + 1] = m
    end
  end
  local start = _history_start(non_system, max_history)
  for i = start, #non_system do
    messages[#messages + 1] = _to_api_message(non_system[i])
  end
  if opts.extra_user then
    messages[#messages + 1] = { role = "user", content = opts.extra_user }
  end
  return _balance_tools(messages)
end

--- 从 Agent 构建上下文消息（Agent 持有私有消息队列 + 配置）
--- @param agent table Agent
--- @param opts table|nil { max_history?, include_system? }
--- @return table API 消息数组
function M.build_from_agent(agent, opts)
  opts = opts or {}
  local messages = {}
  if opts.include_system ~= false then
    messages[#messages + 1] = _build_system_message(agent)
  end
  local max_history = opts.max_history
    or config_store.get("session.max_history_per_session")
    or 1000
  local source = M.request_view(agent)
  local start = _history_start(source, max_history)
  for i = start, #source do
    messages[#messages + 1] = _to_api_message(source[i])
  end
  if opts.extra_user then
    messages[#messages + 1] = { role = "user", content = opts.extra_user }
  end
  return _balance_tools(messages)
end

--- 构建 Agent 的请求视图：应用压缩覆盖层（若有）。
--- 覆盖层仅影响发往模型的上下文；agent.messages 保持原始，供渲染与持久化。
--- @param agent table Agent
--- @return table 内部消息数组（原始或「检查点 + 尾部」）
function M.request_view(agent)
  if not agent then return {} end
  return _apply_overlay(agent.messages, agent.compaction)
end

--- 将内部消息转换为 API 消息（与请求发送完全一致，压缩回放保证字节一致）
--- @param message table
--- @return table
M.to_api_message = _to_api_message

--- 构建压缩回放前缀：系统消息 + 指定区间消息（供压缩辅助调用复用前缀缓存）
--- @param agent table Agent
--- @param range_messages table 需回放的消息数组（原对象）
--- @return table API 消息数组（不含压缩指令，调用方自行追加）
function M.build_prefix(agent, range_messages)
  local messages = {}
  if agent then
    messages[#messages + 1] = _build_system_message(agent)
  end
  for _, m in ipairs(range_messages or {}) do
    messages[#messages + 1] = _to_api_message(m)
  end
  return _balance_tools(messages)
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

--- 估算单条消息 content 的 token（字符/系数粗估），content 可能是字符串，
--- 也可能是多模态块数组（{ type="text", text=.. } / { type="image", attachment=ref }）。
--- @param content any
--- @param divisor number|nil 每 token 字符数（缺省 4；CJK 模型可传更小值）
--- @return number
local function _estimate_content(content, divisor)
  divisor = divisor or 4
  if type(content) == "string" then
    return math.ceil(#content / divisor)
  elseif type(content) == "table" then
    local n = 0
    for _, b in ipairs(content) do
      if type(b) ~= "table" then
        n = n + math.ceil(#tostring(b) / divisor)
      elseif b.type == "text" then
        n = n + math.ceil(#(b.text or "") / divisor)
      elseif b.type == "image" then
        n = n + M._estimate_image(b.attachment or b)
      end
    end
    return n
  elseif content ~= nil then
    return math.ceil(#tostring(content) / divisor)
  end
  return 0
end

--- 估算单图 token（按像素/4 或字节兜底，低估会污染容量显示故宁可稍高）
--- @param ref table|nil { width?, height?, bytes? }
--- @return number
function M._estimate_image(ref)
  if type(ref) ~= "table" then return 100 end
  local w = tonumber(ref.width) or 0
  local h = tonumber(ref.height) or 0
  if w > 0 and h > 0 then
    return math.max(100, math.ceil(w * h / 750))
  end
  local bytes = tonumber(ref.bytes) or 0
  if bytes > 0 then
    return math.max(100, math.ceil(bytes / 400))
  end
  return 100
end

--- 统计上下文的 token 估算（字符/系数粗估，兼容多模态 content 块与 m.image）
--- @param messages table
--- @param opts table|nil { chars_per_token?: number } 模型级字符/token 系数
--- @return number
function M.estimate_tokens(messages, opts)
  local divisor = opts and opts.chars_per_token or 4
  local total = 0
  for _, m in ipairs(messages or {}) do
    total = total + _estimate_content(m.content, divisor)
    if m.image then
      total = total + M._estimate_image(m.image)
    end
    if m.tool_calls then
      for _, tc in ipairs(m.tool_calls) do
        local fn = tc["function"]
        total = total + math.ceil(#(fn and fn.name or "") / divisor)
        total = total + math.ceil(#(fn and fn.arguments or "") / divisor)
      end
    end
  end
  return total
end

--- 估算「完整请求」的 token：系统提示 + 工具定义 + 消息。
--- 只估算 messages 会漏掉 system/tools，导致压缩阈值偏低、实际请求先于压缩而溢出。
--- @param agent table|nil
--- @param opts table|nil { chars_per_token?, messages?, tools?, include_system? }
--- @return number
function M.estimate_request(agent, opts)
  opts = opts or {}
  local divisor = tonumber(opts.chars_per_token) or 4
  local total = 0
  if opts.include_system ~= false and agent then
    local ok, sys = pcall(function()
      return require("NeoAI.core.agent.prefix").build_system_prompt(agent)
    end)
    if ok and type(sys) == "string" then
      total = total + math.ceil(#sys / divisor)
    end
  end
  local messages = opts.messages
  if messages == nil then
    messages = agent and M.build_from_agent(agent, { include_system = false }) or {}
  end
  total = total + M.estimate_tokens(messages, { chars_per_token = divisor })
  local tools = opts.tools
  if tools == nil and agent and agent.tools then
    local ok, defs = pcall(function()
      return require("NeoAI.core.agent.tool_loop")._tool_definitions(agent)
    end)
    if ok then tools = defs end
  end
  if type(tools) == "table" and next(tools) ~= nil then
    local ok, encoded = pcall(function()
      return require("NeoAI.utils.json").encode(tools)
    end)
    if ok and type(encoded) == "string" then
      total = total + math.ceil(#encoded / divisor)
    end
  end
  return total
end

--- 当前上下文占用 token：优先用 API 最近一次请求回传的输入 token（最准确，天然含
--- 系统提示/工具定义/缓存命中），缺失时回退本地完整请求估算。
--- @param agent table|nil
--- @param opts table|nil { chars_per_token? } 回退估算用
--- @return number
--- @return string 取值来源 "api" | "estimate"
function M.used_tokens(agent, opts)
  opts = opts or {}
  local last = agent and agent.usage and agent.usage.last_prompt
  if type(last) == "number" and last > 0 then
    return last, "api"
  end
  return M.estimate_request(agent, opts), "estimate"
end

return M
