--- 上下文压缩
--- @module NeoAI.core.session.compactor
--- 策略对齐 deepseek-harness 的 compaction：
--- 1. 达到 token 压力阈值时，先做模型无关的工具结果裁剪（tool_result_pruner）；
---    裁剪后已回到阈值内则跳过摘要调用。
--- 2. 仍需摘要时，折叠最早的整段历史，保留最近尾部（retain 预算）；
---    切点保持工具调用配对平衡，绝不拆散 assistant.tool_calls 与其 tool 结果。
--- 3. 辅助摘要调用「逐字节回放」会话前缀：相同的系统提示、工具 schema、被折叠区消息，
---    再把压缩指令作为最后的 user 消息追加 → 复用 provider 的热前缀缓存。
--- 4. 用带 <compacted-summary> 标签的检查点 user 消息替换被折叠区间；
---    后续请求在替换点之前的未变前缀仍然可复用缓存。仅替换而非追加：不产生第二份副本。
--- 5. 摘要后仍高于阈值时按 compaction_retries 重试；溢出恢复走最大化平衡头部缩减
---    （retain 0，只保留最新一个不可分单元）。

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

--- 解析模型能力表（缓存机制 / 上下文窗口）
--- @param agent table
--- @return table
local function _caps(agent)
  local provider_name = (agent.config and agent.config.provider)
    or config_store.get("ai.default_provider")
  return require("NeoAI.core.model.capabilities").resolve(agent.model, provider_name)
end

--- 解析有效上下文窗口（用户显式配置优先，否则按模型能力表；未知模型回退默认）
--- @param agent table
--- @param cfg table
--- @return number
local function _window_for(agent, cfg)
  if type(cfg.context_window) == "number" and cfg.context_window > 0 and cfg.context_window ~= 64000 then
    return cfg.context_window
  end
  return require("NeoAI.core.model.capabilities").resolve_window(
    cfg.context_window, agent.model, agent.config and agent.config.provider)
end

--- 有效阈值比例：显式缓存模型取更保守（更高阈值），减少前缀重写导致的缓存失效
--- @param cfg table
--- @param caps table
--- @return number
local function _threshold_ratio(cfg, caps)
  local r = cfg.threshold_ratio or 0.8
  if caps.explicit_cache then r = math.max(r, 0.85) end
  return r
end

--- 有效尾部保留比例：显式缓存模型稍大（保留更多热前缀）
--- @param cfg table
--- @param caps table
--- @return number
local function _retain_ratio(cfg, caps)
  local r = cfg.retain_ratio or 0.16
  if caps.explicit_cache then r = math.min(0.5, r * 1.25) end
  return r
end

--- 估算当前上下文 token 占用（优先 API 最近一次请求的真实用量，缺失回退完整请求估算）
--- @param agent table
--- @return number
local function _estimate(agent)
  local context_builder = require("NeoAI.core.session.context_builder")
  local caps = _caps(agent)
  return context_builder.used_tokens(agent, { chars_per_token = caps.chars_per_token })
end

--- 切点（位置 idx 之前）是否工具配对平衡：前 idx-1 条消息里没有未配对的 tool_call。
--- @param messages table
--- @param idx number 保留区间的起始下标（1-based）
--- @return boolean
local function _pairing_balanced_before(messages, idx)
  local open = 0
  for i = 1, idx - 1 do
    local m = messages[i]
    if not m then return false end
    if m.role == "assistant" and m.tool_calls and #m.tool_calls > 0 then
      open = open + #m.tool_calls
    end
    if m.role == "tool" then
      open = open - 1
    end
    if open < 0 then return false end
  end
  return open == 0
end

--- 选择被折叠区间：折叠最早的整段消息，保留最近尾部（retain 预算）。
--- 切点必须工具配对平衡，否则前移切点（并入更多消息）直到平衡；移到头部则返回空。
--- @param agent table
--- @param cfg table
--- @param opts table|nil { retain_tokens?, min_shadow? } 溢出恢复传 retain_tokens=0 做最大化缩减
--- @return table 被折叠消息数组（保留原顺序，可为空）
local function _select_shadow_range(agent, cfg, opts)
  opts = opts or {}
  local messages = agent.messages or {}
  local context_builder = require("NeoAI.core.session.context_builder")
  local caps = _caps(agent)
  local window = _window_for(agent, cfg)
  local retain_budget
  if type(opts.retain_tokens) == "number" then
    retain_budget = opts.retain_tokens
  else
    retain_budget = _retain_ratio(cfg, caps) * window
    local retain_min = cfg.retain_min_tokens or 4096
    if retain_budget < retain_min then retain_budget = retain_min end
  end
  local min_shadow = opts.min_shadow or cfg.min_shadow_messages or 2

  local keep_start = #messages + 1
  local tail_tokens = 0
  for i = #messages, 1, -1 do
    tail_tokens = tail_tokens + context_builder.estimate_tokens({ messages[i] })
    keep_start = i
    if tail_tokens >= retain_budget then break end
  end
  -- 工具配对安全：切点不能落在 assistant.tool_calls 与其 tool 结果之间，
  -- 否则压缩后请求会缺少配对的 tool 结果而被 API 拒绝。
  while keep_start > 1 and not _pairing_balanced_before(messages, keep_start) do
    keep_start = keep_start - 1
  end
  if keep_start <= 1 then return {} end
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

--- 模型无关的工具结果裁剪（摘要前的第一道压缩）；有裁剪则作废过期 API 用量。
--- @param agent table
--- @param cfg table
--- @return boolean 是否发生了裁剪
local function _prune(agent, cfg)
  if cfg.prune_enabled == false then return false end
  local pruner = require("NeoAI.core.session.tool_result_pruner")
  -- 裁剪是可选优化：任何异常都不得阻断发送（对齐 harness 的"操作失败告警后继续"）
  local ok, result = pcall(pruner.prune_agent, agent, { context_cache = cfg })
  if not ok then
    logger.warn("[compactor] 工具结果裁剪失败，跳过: %s", tostring(result))
    return false
  end
  if result.pruned > 0 then
    if agent.usage then agent.usage.last_prompt = nil end
    return true
  end
  return false
end

-- ========== 公开 API ==========

--- 内部压缩执行（maybe_compact 与 force_compact 共用）
--- @param agent table
--- @param cfg table
--- @param opts table|nil { threshold?, retain_tokens?, min_shadow? }
--- @return Deferred resolve(boolean)
local function _compact(agent, cfg, opts)
  opts = opts or {}
  agent._compacting = true
  local est = _estimate(agent)
  event_bus.emit(events.COMPACTION_STARTED, {
    agent_id = agent.id,
    estimated_tokens = est,
    threshold = opts.threshold or 0,
  })

  local max_attempts = (tonumber(cfg.compaction_retries) or 1) + 1
  local compacted_any = false
  local function finish(ok)
    agent._compacting = false
    return async.resolve(ok)
  end

  local function step(attempt)
    local shadow = _select_shadow_range(agent, cfg, opts)
    if #shadow == 0 then
      if not compacted_any then
        logger.warn("[compactor] 可折叠消息过少，无法压缩")
      end
      return finish(compacted_any)
    end
    return _summarize(agent, shadow, cfg):then_(function(response)
      local summary = response and response.content
      if not summary or summary:gsub("%s", "") == "" then
        logger.warn("[compactor] 摘要为空，跳过压缩")
        return finish(compacted_any)
      end
      _replace_with_checkpoint(agent, shadow, summary)
      compacted_any = true
      -- 历史被替换：作废上一轮 API 用量，避免用压缩前的旧值再次触发压缩
      if agent.usage then agent.usage.last_prompt = nil end
      -- 压缩会替换较早历史：显式缓存（尤其 Gemini cachedContents，绑定 system+tools）
      -- 需失效重建，避免命中陈旧前缀
      pcall(function()
        require("NeoAI.core.model.prompt_cache").invalidate(
          agent.config and agent.config.provider or config_store.get("ai.default_provider"), agent.model)
      end)
      if response.usage then
        local prefix = require("NeoAI.core.agent.prefix")
        local cu = prefix.parse_cache_usage(response.usage)
        if cu then
          local cache = agent.cache or {}
          cache.compaction_usage = cu
          agent.cache = cache
        end
      end
      -- 收敛：仍在阈值之上且还有重试预算则继续折叠更早区间
      if opts.threshold and _estimate(agent) >= opts.threshold and attempt + 1 < max_attempts then
        return step(attempt + 1)
      end
      return finish(true)
    end, function(err)
      logger.warn("[compactor] 压缩失败: %s", tostring(err and err.message or err))
      return finish(compacted_any)
    end)
  end

  return step(0)
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
  local caps = _caps(agent)
  local window = _window_for(agent, cfg)
  local threshold = window * _threshold_ratio(cfg, caps)
  local est = _estimate(agent)
  if est < threshold then
    return async.resolve(false)
  end
  -- 先裁剪工具结果：多数情况下裁剪后即回到阈值内，无需摘要调用
  if _prune(agent, cfg) and _estimate(agent) < threshold then
    return async.resolve(true)
  end
  return _compact(agent, cfg, { threshold = threshold })
end

--- 强制压缩（上下文溢出恢复用）：跳过压力阈值判断，仍保留空闲/并发锁检查。
--- 先裁剪；裁剪已足以回到窗口内则不再摘要；否则做最大化平衡头部缩减（retain 0）。
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
  if _prune(agent, cfg) and _estimate(agent) < _window_for(agent, cfg) then
    return async.resolve(true)
  end
  return _compact(agent, cfg, { retain_tokens = 0, min_shadow = 1 })
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
