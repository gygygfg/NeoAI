--- 上下文压缩
--- @module NeoAI.core.session.compactor
--- 策略对齐 deepseek-harness 的 compaction：
--- 1. 达到 token 压力阈值时，折叠最早的整段历史，保留最近尾部（retain 预算）。
--- 2. 辅助摘要调用「逐字节回放」会话前缀：相同的系统提示、工具 schema、被折叠区消息，
---    再把压缩指令作为最后的 user 消息追加 → 复用 provider 的热前缀缓存。
--- 3. 用带 <compacted-summary> 标签的检查点 user 消息替换被折叠区间；
---    后续请求在替换点之前的未变前缀仍然可复用缓存。
--- 4. 仅替换而非追加：不产生第二份历史副本。

local async = require("NeoAI.utils.async")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local logger = require("NeoAI.kernel.logger")

local M = {}

-- ========== 私有常量 ==========

--- 压缩指令：作为回放会话之后的「最后一条 user 消息」投递，
--- 而不是单独的压缩器 system 提示，保证回放前缀与已路由请求逐字节一致。
local COMPACTION_INSTRUCTION = table.concat({
  "You are now acting as a compaction engine for this AI coding assistant. Condense the conversation ABOVE into a structured checkpoint that lets another model resume the work with no loss of essential context.",
  "",
  "Output EXACTLY the Markdown structure below: keep every section, in order. Use terse bullets, not prose paragraphs. Write \"(none)\" for an empty section — never drop a section.",
  "",
  "## Primary Request and Intent",
  "- [the user's original and evolving goals; quote verbatim where the exact wording matters]",
  "",
  "## Key Technical Concepts",
  "- [technologies, frameworks, patterns, and conventions in play]",
  "",
  "## Files and Code",
  "- [exact path: why it matters, key changes or snippets]",
  "",
  "## Errors and Fixes",
  "- [error: how it was resolved, plus any related user feedback]",
  "",
  "## Pending Jobs",
  "- [explicitly requested work not yet completed]",
  "",
  "## Current Work",
  "- [precisely what was in progress at this checkpoint]",
  "",
  "## Next Step",
  "- [the single next action, directly in line with the most recent request, or \"(none)\"]",
  "",
  "## Critical Context",
  "- [decisions and their rationale, constraints, user preferences, open questions, data needed to continue]",
  "",
  "Rules:",
  "- Write concise English engineering prose. Preserve exact file paths, commands, error strings, identifiers, numeric values, function signatures, and syntax fragments.",
  "- Capture user feedback and explicit instructions faithfully, especially corrections.",
  "- Do NOT mention this summarization request or that the context was compacted.",
  "- Output only the checkpoint text: do not call any tool or take any other action.",
  "- If the conversation already contains a <compacted-summary> block, it is a PRIOR checkpoint. Do not copy it forward verbatim: preserve still-true facts, drop stale ones, and merge newer information into a single consolidated summary under the same structure.",
}, "\n")

--- 检查点前置说明：把替代消息确立为既定上下文。
local CHECKPOINT_PREAMBLE = "这是一个自动生成的检查点，对对话较早部分进行压缩以释放上下文。请将其视为既定背景直接使用，不要复述或提及此检查点，直接基于其后的消息继续任务。"

-- ========== 私有函数 ==========

--- 获取配置（允许 opts 覆盖）
--- @param opts table|nil
--- @return table
local function _cfg(opts)
  local cfg = vim.deepcopy(config_store.get("ai.context_cache") or {})
  if opts and opts.context_cache then
    for k, v in pairs(opts.context_cache) do cfg[k] = v end
  end
  return cfg
end

--- 估算当前上下文 token 占用
--- @param agent table
--- @return number
local function _estimate(agent)
  local context_builder = require("NeoAI.core.session.context_builder")
  return context_builder.estimate_tokens(agent.messages or {})
end

--- 选择被折叠区间：折叠最早的整段消息，保留最近尾部（retain 预算）
--- @param agent table
--- @param cfg table
--- @return table 被折叠消息数组（保留原顺序，可为空）
local function _select_shadow_range(agent, cfg)
  local messages = agent.messages or {}
  local context_builder = require("NeoAI.core.session.context_builder")
  local window = cfg.context_window or 64000
  local retain_budget = (cfg.retain_ratio or 0.16) * window
  local retain_min = cfg.retain_min_tokens or 4096
  if retain_budget < retain_min then retain_budget = retain_min end
  local min_shadow = cfg.min_shadow_messages or 2

  local keep_start = #messages + 1
  local tail_tokens = 0
  for i = #messages, 1, -1 do
    local toks = context_builder.estimate_tokens({ messages[i] })
    if tail_tokens + toks > retain_budget then
      break
    end
    tail_tokens = tail_tokens + toks
    keep_start = i
  end
  local shadow_count = keep_start - 1
  if shadow_count < min_shadow then return {} end
  local shadow = {}
  for i = 1, shadow_count do
    shadow[#shadow + 1] = messages[i]
  end
  return shadow
end

--- 回放被折叠区间做辅助摘要（前缀缓存复用）
--- @param agent table
--- @param shadow table 被折叠消息（原对象，保持字节一致）
--- @param cfg table
--- @return Deferred resolve({ content, usage })
local function _summarize(agent, shadow, cfg)
  local request = require("NeoAI.core.agent.request")
  local context_builder = require("NeoAI.core.session.context_builder")
  local tool_loop = require("NeoAI.core.agent.tool_loop")

  local messages = context_builder.build_prefix(agent, shadow)
  messages[#messages + 1] = { role = "user", content = COMPACTION_INSTRUCTION }

  local tool_defs = tool_loop._tool_definitions(agent)
  -- 流式接收摘要：实时把收到的推理 / 正文分片广播出去，UI 端显示"上下文压缩"悬浮窗，
  -- 避免压缩期间界面无任何反馈、看起来像卡住。
  local acc_reasoning = ""
  local acc_content = ""
  return request.send_stream(messages, {
    agent_config = agent.config,
    model = agent.model,
    tools = tool_defs,
    signal = agent.signal,
    max_tokens = cfg.compact_max_tokens or 8192,
  }, function(chunk)
    if not chunk then return end
    if chunk.reasoning and chunk.reasoning ~= "" then
      acc_reasoning = acc_reasoning .. chunk.reasoning
    end
    if chunk.content and chunk.content ~= "" then
      acc_content = acc_content .. chunk.content
    end
    event_bus.emit(events.COMPACTION_CHUNK, {
      agent_id = agent.id,
      reasoning = acc_reasoning,
      content = acc_content,
    })
  end)
end

--- 用检查点 user 消息替换被折叠区间
--- @param agent table
--- @param shadow table 被折叠消息
--- @param summary string 摘要文本
local function _replace_with_checkpoint(agent, shadow, summary)
  local remove_count = #shadow
  if remove_count == 0 then return end
  for _ = 1, remove_count do
    table.remove(agent.messages, 1)
  end
  local checkpoint = M.checkpoint_message(summary)
  checkpoint.ts = os.time()
  checkpoint.replaced_count = remove_count
  table.insert(agent.messages, 1, checkpoint)
  event_bus.emit(events.COMPACTION_COMPLETED, {
    agent_id = agent.id,
    replaced = remove_count,
    summary = summary,
  })
end

-- ========== 公开 API ==========

--- 内部压缩执行（maybe_compact 与 force_compact 共用）
--- @param agent table
--- @param cfg table
--- @return Deferred resolve(boolean)
local function _compact(agent, cfg)
  agent._compacting = true
  local est = _estimate(agent)
  event_bus.emit(events.COMPACTION_STARTED, { agent_id = agent.id, estimated_tokens = est, threshold = 0 })

  local shadow = _select_shadow_range(agent, cfg)
  if #shadow < (cfg.min_shadow_messages or 2) then
    logger.warn("[compactor] 可折叠消息过少，无法压缩")
    agent._compacting = false
    return async.resolve(false)
  end

  return _summarize(agent, shadow, cfg):then_(function(response)
    local summary = response and response.content
    if not summary or summary:gsub("%s", "") == "" then
      logger.warn("[compactor] 摘要为空，跳过压缩")
      agent._compacting = false
      return async.resolve(false)
    end
    _replace_with_checkpoint(agent, shadow, summary)
    if response.usage then
      local prefix = require("NeoAI.core.agent.prefix")
      local cu = prefix.parse_cache_usage(response.usage)
      if cu then
        local cache = agent.cache or {}
        cache.compaction_usage = cu
        agent.cache = cache
      end
    end
    agent._compacting = false
    return async.resolve(true)
  end, function(err)
    agent._compacting = false
    logger.warn("[compactor] 压缩失败: %s", tostring(err and err.message or err))
    return async.resolve(false)
  end)
end

--- 检查 token 压力并按需压缩（仅在 Agent 空闲时执行）
--- @param agent table Agent
--- @param opts table|nil { context_cache? }
--- @return Deferred resolve(boolean) 是否发生了压缩
function M.maybe_compact(agent, opts)
  opts = opts or {}
  local cfg = _cfg(opts)
  if cfg.enabled == false then
    return async.resolve(false)
  end
  if not agent or agent.state ~= "idle" or agent._compacting then
    return async.resolve(false)
  end
  local window = cfg.context_window or 64000
  local threshold = window * (cfg.threshold_ratio or 0.8)
  local est = _estimate(agent)
  if est < threshold then
    return async.resolve(false)
  end
  return _compact(agent, cfg)
end

--- 强制压缩（上下文溢出恢复用）：跳过压力阈值判断，仍保留空闲/并发锁检查
--- @param agent table Agent
--- @param opts table|nil { context_cache? }
--- @return Deferred resolve(boolean) 是否发生了压缩
function M.force_compact(agent, opts)
  opts = opts or {}
  local cfg = _cfg(opts)
  if cfg.enabled == false then
    return async.resolve(false)
  end
  if not agent or agent.state ~= "idle" or agent._compacting then
    return async.resolve(false)
  end
  return _compact(agent, cfg)
end

--- 构建检查点消息（供测试直接使用）
--- @param summary string
--- @return table
function M.checkpoint_message(summary)
  return {
    role = "user",
    content = CHECKPOINT_PREAMBLE .. "\n\n<compacted-summary>\n" .. summary .. "\n</compacted-summary>",
    checkpoint = true,
  }
end

--- 被折叠区间选择（供测试直接使用）
M._select_shadow_range = _select_shadow_range

return M
