--- 上下文压缩
--- @module NeoAI.core.session.compactor
--- 后台异步、非阻塞压缩：
--- 1. 达到 token 压力阈值时，先做模型无关的工具结果裁剪（tool_result_pruner）；
---    裁剪后已回到阈值内则跳过摘要调用。
--- 2. 仍需摘要时，折叠第一轮至倒数第二轮（保留最后一轮完整）；溢出恢复则做最大化
---    平衡头部缩减（retain 0，只保留最新一个不可分单元，绝不拆散 tool_calls 与其结果）。
--- 3. 辅助摘要调用「逐字节回放」请求视图前缀：相同的系统提示、工具 schema、被折叠区消息，
---    再把压缩指令作为最后的 user 消息追加 → 复用 provider 的热前缀缓存。
--- 4. 摘要结果写入压缩覆盖层 `agent.compaction = { checkpoint, replaced }`，**不改动
---    agent.messages**：渲染与会话持久化仍是原始上下文，后续请求与再次压缩经
---    `context_builder.request_view` 使用「检查点 + 未替换尾部」。
--- 5. `start_background` 启动后台压缩后立即返回（agent 不被阻塞，不弹压缩悬浮窗）；
---    `maybe_compact` 为可等待版本；`force_compact`（溢出恢复）仍阻塞等待。

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
  local context_builder = require("NeoAI.core.session.context_builder")
  local messages = context_builder.request_view(agent)
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

--- 按轮次选择被折叠区间：折叠第一轮至倒数第二轮，保留最后一轮完整。
--- 在请求视图上操作（可能已含上一次的检查点）：以最后一条非运行态 user 消息为最后一轮起点。
--- @param agent table
--- @param cfg table
--- @return table shadow 被折叠消息数组（可为空）
--- @return number added 其中「原始（非运行态、非检查点）消息」条数，用于累加覆盖层 replaced
local function _select_round_shadow(agent, cfg)
  local context_builder = require("NeoAI.core.session.context_builder")
  local messages = context_builder.request_view(agent)
  local last_user = nil
  for i = #messages, 1, -1 do
    local m = messages[i]
    if m and m.role == "user" and not m.runtime_context then
      last_user = i
      break
    end
  end
  if not last_user or last_user <= 1 then return {}, 0 end
  local shadow, added = {}, 0
  for i = 1, last_user - 1 do
    local m = messages[i]
    shadow[#shadow + 1] = m
    if m and not m.runtime_context and not m.checkpoint then added = added + 1 end
  end
  return shadow, added
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
  -- 后台异步压缩：不再向 UI 广播分片/打开「上下文压缩」悬浮窗（压缩不阻塞 agent，
  -- 也无须弹窗打断用户）。摘要结果直接用于构建请求视图覆盖层。
  return request.send_stream(messages, {
    agent_config = agent.config,
    model = agent.model,
    tools = tool_defs,
    signal = agent.signal,
    max_tokens = cfg.compact_max_tokens or 8192,
  })
end

--- 压缩门禁：无效 agent / 正在压缩 / 已取消 一律拒绝。
--- 默认要求 agent 处于 idle（回合边界压缩）；opts.allow_busy 为真时放宽该要求，
--- 允许在 generating / tool_running 状态下压缩——供工具循环轮边界与溢出恢复使用。
--- 调用方须自行保证此刻没有并发写入 agent.messages（工具结果已回写、下一轮请求尚未发出；
--- 或请求已失败进入恢复路径）。
--- @param agent table
--- @param opts table|nil { allow_busy? = boolean }
--- @return boolean
local function _can_compact(agent, opts)
  if not agent or agent._compacting then return false end
  -- 已取消（ESC / 销毁）：不再压缩，避免与取消/清理竞态。
  if agent.signal and agent.signal.aborted and agent.signal:aborted() then return false end
  if not (opts and opts.allow_busy) and agent.state ~= "idle" then return false end
  return true
end

--- 应用压缩覆盖层：用检查点取代「前 added 条原始消息」的请求视图，不改动 agent.messages。
--- 渲染与持久化仍使用原始消息；后续请求与再次压缩都走覆盖层后的请求视图。
--- @param agent table
--- @param summary string 摘要文本
--- @param added number 本次新折叠的原始（非运行态、非检查点）消息条数
local function _apply_overlay(agent, summary, added)
  local prev = (agent.compaction and tonumber(agent.compaction.replaced)) or 0
  local checkpoint = M.checkpoint_message(summary)
  checkpoint.ts = os.time()
  checkpoint.replaced_count = prev + (added or 0)
  agent.compaction = { checkpoint = checkpoint, replaced = prev + (added or 0) }
  event_bus.emit(events.COMPACTION_COMPLETED, {
    agent_id = agent.id,
    replaced = added or 0,
    summary = summary,
  })
end

--- 模型无关的工具结果裁剪（摘要前的第一道压缩）；有裁剪则作废过期 API 用量。
--- 裁剪计算（码点统计/切片）经 pruner 卸载到工作线程池，避免 MB 级结果阻塞主线程；
--- 线程池不可用时 pruner 仍可同步处理块数组内容，语义不变。
--- @param agent table
--- @param cfg table
--- @return Deferred resolve(boolean) 是否发生了裁剪
local function _prune_async(agent, cfg)
  if cfg.prune_enabled == false then return async.resolve(false) end
  local pruner = require("NeoAI.core.session.tool_result_pruner")
  -- 裁剪是可选优化：任何异常都不得阻断发送（对齐 harness 的"操作失败告警后继续"）
  local ok, d = pcall(pruner.prune_agent_async, agent, { context_cache = cfg })
  if not ok or not (type(d) == "table" and type(d.then_) == "function") then
    logger.warn("[compactor] 工具结果裁剪失败，跳过: %s", tostring(d))
    return async.resolve(false)
  end
  return d:then_(function(result)
    if result and (result.pruned or 0) > 0 then
      if agent.usage then agent.usage.last_prompt = nil end
      return true
    end
    return false
  end, function(err)
    logger.warn("[compactor] 工具结果裁剪失败，跳过: %s", tostring(err and err.message or err))
    return false
  end)
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

  local max_attempts = (tonumber(cfg.compaction_retries) or 1) + 1
  local compacted_any = false
  local function finish(ok)
    agent._compacting = false
    return async.resolve(ok)
  end

  local function step(attempt)
    local shadow, added
    if opts.mode == "overflow" then
      shadow = _select_shadow_range(agent, cfg, opts)
    else
      -- 默认（阈值触发）：折叠第一轮至倒数第二轮，保留最后一轮完整。
      shadow, added = _select_round_shadow(agent, cfg)
    end
    if #shadow == 0 then
      if not compacted_any then
        logger.warn("[compactor] 可折叠消息过少，无法压缩")
      end
      return finish(compacted_any)
    end
    if opts.mode == "overflow" then
      added = 0
      for _, m in ipairs(shadow) do
        if m and not m.runtime_context and not m.checkpoint then added = added + 1 end
      end
    elseif not added or added == 0 then
      -- 仅剩检查点、没有可折叠的原始消息：不再重复摘要。
      return finish(compacted_any)
    end
    return _summarize(agent, shadow, cfg):then_(function(response)
      local summary = response and response.content
      if not summary or summary:gsub("%s", "") == "" then
        logger.warn("[compactor] 摘要为空，跳过压缩")
        return finish(compacted_any)
      end
      _apply_overlay(agent, summary, added)
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

--- 检查 token 压力并按需压缩。
--- 默认仅在 Agent 空闲时执行（回合边界）；opts.allow_busy 为真时允许在工具循环
--- 轮边界（generating/tool_running）执行——此时工具结果已回写、下一轮请求尚未发出，
--- 可安全折叠历史并复用前缀缓存。
--- @param agent table Agent
--- @param opts table|nil { context_cache?, allow_busy? }
--- @return Deferred resolve(boolean) 是否发生了压缩
function M.maybe_compact(agent, opts)
  opts = opts or {}
  local cfg = _cfg(opts)
  if cfg.enabled == false then
    return async.resolve(false)
  end
  if not _can_compact(agent, opts) then
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
  return _prune_async(agent, cfg):then_(function(pruned)
    if pruned and _estimate(agent) < threshold then return true end
    return _compact(agent, cfg, { mode = "round", threshold = threshold })
  end)
end

--- 后台异步压缩（非阻塞）：达到压力阈值时启动压缩，立即返回，不等待摘要完成。
--- agent 继续用当前（原始）请求视图执行；压缩完成后覆盖层生效，后续请求与再次压缩
--- 都基于压缩后的替换。不弹出任何 UI。裁剪同步完成（廉价），摘要异步进行。
--- @param agent table Agent
--- @param opts table|nil { context_cache?, allow_busy? }
function M.start_background(agent, opts)
  opts = opts or {}
  local cfg = _cfg(opts)
  if cfg.enabled == false then return end
  if not _can_compact(agent, opts) then return end
  local caps = _caps(agent)
  local window = _window_for(agent, cfg)
  local threshold = window * _threshold_ratio(cfg, caps)
  if _estimate(agent) < threshold then return end
  _prune_async(agent, cfg):then_(function(pruned)
    if pruned and _estimate(agent) < threshold then return end
    local d = _compact(agent, cfg, { mode = "round", threshold = threshold })
    if d and d.catch then
      d:catch(function(err)
        logger.warn("[compactor] 后台压缩失败: %s", tostring(err and err.message or err))
      end)
    end
  end)
end

--- 强制压缩（上下文溢出恢复用）：跳过压力阈值判断。
--- 溢出恢复路径固定在 allow_busy 下执行（不要求 idle）：请求已因溢出失败，
--- 此刻无并发写入，压缩安全；回合首轮与工具循环中途均会走此路径。
--- 先裁剪；裁剪已足以回到窗口内则不再摘要；否则做最大化平衡头部缩减（retain 0）。
--- @param agent table Agent
--- @param opts table|nil { context_cache?, allow_busy? } allow_busy 缺省视为 true
--- @return Deferred resolve(boolean) 是否发生了压缩
function M.force_compact(agent, opts)
  opts = opts or {}
  -- 溢出恢复默认放宽 idle：除非调用方显式 allow_busy=false，否则允许在循环中途压缩。
  if opts.allow_busy == nil then opts.allow_busy = true end
  local cfg = _cfg(opts)
  if cfg.enabled == false then
    return async.resolve(false)
  end
  if not _can_compact(agent, opts) then
    return async.resolve(false)
  end
  return _prune_async(agent, cfg):then_(function(pruned)
    if pruned and _estimate(agent) < _window_for(agent, cfg) then return true end
    return _compact(agent, cfg, { mode = "overflow", retain_tokens = 0, min_shadow = 1 })
  end)
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
