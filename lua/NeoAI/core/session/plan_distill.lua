--- 计划阶段上下文蒸馏
--- @module NeoAI.core.session.plan_distill
--- 在「plan 完成 → 用户以任何非计划模式（chat/auto）确认开始」的边界，把计划阶段的
--- 调研上下文（工具调用、推理、正文）按顺序分块标号，通过一次内部分类调用交给 AI，
--- 用 compactor 的 8 段 <compacted-summary> 结构提炼出对执行有用的信息（目标、环境、
--- 文件、注意事项），再用提炼后的检查点消息【替换压缩】原调研窗口，重建上下文后开始执行。
--- 触发由 chat_service._distill_if_needed 统一判定（approve_plan 自动执行、手动切到
--- chat/auto、cycle plan→auto 等首次非 plan 发送前各触发一次）。
--- 与 compactor 的差异：
--- - compactor 按 token 压力折叠【最早的】消息（replaced_tail=false，从 durable 头部移除）；
--- - plan_distill 在 plan→execute 边界折叠【计划阶段尾部】消息（replaced_tail=true，从尾部移除），
---   待蒸馏窗口取 agent._plan_enter_index（进入计划模式时记录）之后的全部消息。
--- 失败一律 no-op：不阻塞审批、不改变历史，仅返回 false 并原样继续执行。

local async = require("NeoAI.utils.async")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local logger = require("NeoAI.kernel.logger")
local json = require("NeoAI.utils.json")

local M = {}

-- ========== 私有常量 ==========

--- 分类蒸馏指令：作为承载「编号分块」的最后一条 user 消息投递，
--- 沿用 compactor 的 8 段结构，并强调按用户要求分类筛选目标/环境/文件/注意事项。
local PLAN_DISTILL_INSTRUCTION = table.concat({
  "你是一个计划阶段上下文蒸馏引擎。上方历史消息与下面编号分块（[编号] 类别 内容）",
  "共同构成一次计划调研。请从中分类筛选出对执行仍然有用、必须保留的信息，剔除冗余过程性",
  "细节（大量搜索/读取结果、中间推理、临时命令等），集成成一份结构化检查点。",
  "",
  "只需输出下面的 Markdown 结构：按顺序保留每个 section，用精简要点而非段落；",
  "没有内容的 section 写 \"(none)\"，绝不省略任何 section。",
  "",
  "## Primary Request and Intent",
  "- [用户原始且不断演进的目标；关键措辞逐字引用]",
  "",
  "## Key Technical Concepts",
  "- [技术栈、框架、约定、在运用的模式]",
  "",
  "## Files and Code",
  "- [精确路径：为什么重要、关键改动或片段]",
  "",
  "## Errors and Fixes",
  "- [错误：如何解决，以及相关用户反馈]",
  "",
  "## Pending Jobs",
  "- [明确要求但尚未完成的工作]",
  "",
  "## Current Work",
  "- [此检查点处正处于什么状态/已批准的计划]",
  "",
  "## Next Step",
  "- [紧接最近一次请求的下一步，或 \"(none)\"]",
  "",
  "## Critical Context",
  "- [决策与理由、约束、用户偏好、澄清、需要的数据才能继续]",
  "",
  "分类筛选重点（务必覆盖）：",
  "- 目标：用户真正想要什么、本期要做什么（源自 Primary Request）；",
  "- 环境信息 / 技术背景：技术栈、工具、约定、运行环境；",
  "- 文件信息：精确文件路径、为什么重要、关键片段或函数签名；",
  "- 注意事项：约束、用户明确反馈与修正、需澄清的问题、回滚/验证方案、踩坑点。",
  "",
  "规则：",
  "- 使用简洁的中文工程描述。保留精确文件路径、命令、错误文本、标识符、数值、函数签名。",
  "- 忠实记录用户明确的反馈与修正。",
  "- 不要提及本蒸馏请求，也不要提及上下文被压缩。",
  "- 只输出检查点文本：不要调用任何工具，也不要执行其他动作。",
  "- 若上下文中已存在 <compacted-summary> 块，它是更早的检查点：不要原样照搬，",
  "  保留仍成立的事实、丢弃过时信息，把更新的信息合并进同一结构。",
}, "\n")

-- ========== 私有函数 ==========

--- 读取配置（允许 opts.plan_mode 覆盖）
--- @return table
local function _cfg(opts)
  local cfg = vim.deepcopy(config_store.get("tools.plan_mode") or {})
  if opts and opts.plan_mode then
    for k, v in pairs(opts.plan_mode) do cfg[k] = v end
  end
  return cfg
end

--- 渲染消息 content（字符串直出；table/多模态或其它用 JSON；nil 返回 ""）
--- @param content any
--- @return string
local function _render_content(content)
  if content == nil then return "" end
  if type(content) == "string" then return content end
  if type(content) == "table" then
    local ok, s = pcall(json.encode, content)
    return ok and s or tostring(content)
  end
  return tostring(content)
end

--- 切分计划窗口：窗口 = 进入计划模式之后的消息；front = 之前的消息（保留，不动）。
--- 进入计划模式时记录 agent._plan_enter_index = 当时消息数（0-based split）。
--- @param agent table
--- @return table window, table front
local function _window(agent)
  local messages = agent.messages or {}
  local split = agent._plan_enter_index and (agent._plan_enter_index + 0) or 0
  if split < 0 then split = 0 end
  if split > #messages then split = #messages end
  local front, window = {}, {}
  for i = 1, split do front[#front + 1] = messages[i] end
  for i = split + 1, #messages do window[#window + 1] = messages[i] end
  return window, front
end

--- 把窗口消息拆成按顺序编号的细粒度分块（正文/reasoning/每个工具调用/每个工具结果）
--- @param window table
--- @return table 数组 { n, label, text }
local function _chunk(window)
  local chunks = {}
  local n = 0
  for _, msg in ipairs(window or {}) do
    local role = msg.role or "?"
    -- 正文：tool 消息的 content 就是调用结果，交给下方「工具结果」分支统一标注，避免重复。
    if role ~= "tool" and msg.content and msg.content ~= "" then
      n = n + 1
      chunks[#chunks + 1] = { n = n, label = ("%s 正文"):format(role), text = _render_content(msg.content) }
    end
    if msg.reasoning and msg.reasoning ~= "" then
      n = n + 1
      chunks[#chunks + 1] = { n = n, label = "推理", text = _render_content(msg.reasoning) }
    end
    if msg.tool_calls and #msg.tool_calls > 0 then
      for _, tc in ipairs(msg.tool_calls) do
        local fn = tc and tc["function"] or {}
        local name = fn.name or "?"
        local args = fn.arguments or "{}"
        if type(args) ~= "string" then args = json.encode(args) end
        n = n + 1
        chunks[#chunks + 1] = { n = n, label = ("工具调用 %s"):format(name), text = tostring(args) }
      end
    end
    if role == "tool" then
      local name = msg.name or msg.tool_name or "?"
      n = n + 1
      chunks[#chunks + 1] = { n = n, label = ("工具结果 %s"):format(name), text = _render_content(msg.content) }
    end
  end
  return chunks
end

--- 组装分类请求的最后一条 user 消息内容（指令 + 编号分块）
--- @param chunks table
--- @return string
local function _build_prompt(chunks)
  local lines = { PLAN_DISTILL_INSTRUCTION, "", "编号分块（按对话顺序，由早到晚）：", "" }
  for _, c in ipairs(chunks) do
    lines[#lines + 1] = ("[%d] %s: %s"):format(c.n, c.label, c.text)
  end
  return table.concat(lines, "\n")
end

--- 内部分类调用：回放校验前置 front（复用前缀缓存），追加承载编号分块的 user 消息。
--- @param agent table
--- @param front table 计划入口之前的消息（保留）
--- @param chunks table 编号分块
--- @param cfg table
--- @return Deferred resolve({ content, usage })
local function _classify(agent, front, chunks, cfg)
  local request = require("NeoAI.core.agent.request")
  local context_builder = require("NeoAI.core.session.context_builder")
  local tool_loop = require("NeoAI.core.agent.tool_loop")

  local messages = context_builder.build_prefix(agent, front)
  messages[#messages + 1] = { role = "user", content = _build_prompt(chunks) }

  local tool_defs = tool_loop._tool_definitions(agent)
  -- 流式接收分类摘要：实时把收到的推理 / 正文分片广播出去，UI 端显示"计划蒸馏"悬浮窗。
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
    event_bus.emit(events.PLAN_DISTILL_CHUNK, {
      agent_id = agent.id,
      reasoning = acc_reasoning,
      content = acc_content,
    })
  end):then_(function(resp)
    return { content = resp and resp.content, usage = resp and resp.usage }
  end)
end

--- 用检查点消息替换窗口（移除窗口（尾部）→ 插入检查点）
--- @param agent table
--- @param window table
--- @param summary string
local function _splice(agent, window, summary)
  local remove_count = #window
  -- 记录被替换消息中已落盘的条数（与 compactor 一致）：蒸馏在 plan→execute 边界触发，
  -- 窗口消息通常已同步；仍按实际标记记录，保证 durable surface 删除与落盘状态严格对应。
  local synced_count = 0
  for _, m in ipairs(window) do
    if m and m._synced then synced_count = synced_count + 1 end
  end
  for _ = 1, remove_count do
    table.remove(agent.messages)
  end
  local compactor = require("NeoAI.core.session.compactor")
  local checkpoint = compactor.checkpoint_message(summary)
  checkpoint.ts = os.time()
  checkpoint.replaced_count = remove_count
  checkpoint.replaced_synced_count = synced_count
  checkpoint.replaced_tail = true
  table.insert(agent.messages, checkpoint)
  event_bus.emit(events.PLAN_DISTILLED, {
    agent_id = agent.id,
    replaced = remove_count,
    summary = summary,
  })
end

--- 蒸馏内部分类调用（maybe 语义：仅在 plan→execute 边界且启用时；失败 no-op）
--- @param agent table Agent
--- @param opts table|nil { plan_mode?, min_chunks? }
--- @return Deferred resolve(boolean) 是否发生了蒸馏
local function _distill(agent, opts)
  opts = opts or {}
  local cfg = _cfg(opts)
  if cfg.distill_on_execute == false then
    return async.resolve(false)
  end
  local window, front = _window(agent)
  if #window == 0 then
    return async.resolve(false)
  end
  local chunks = _chunk(window)
  if #chunks < (opts.min_chunks or 2) then
    logger.warn("[plan_distill] 计划窗口分块过少（%d），无需蒸馏", #chunks)
    return async.resolve(false)
  end
  agent._distilling = true
  event_bus.emit(events.PLAN_DISTILL_STARTED, { agent_id = agent.id })
  return _classify(agent, front, chunks, cfg):then_(function(res)
    local summary = res and res.content
    if not summary or summary:gsub("%s", "") == "" then
      logger.warn("[plan_distill] 分类摘要为空，跳过蒸馏")
      agent._distilling = false
      return async.resolve(false)
    end
    -- 记录分类调用的缓存用量（对齐 compactor 的 compaction_usage；供轨迹/统计复用）
    if res and res.usage then
      local prefix = require("NeoAI.core.agent.prefix")
      local cu = prefix.parse_cache_usage(res.usage)
      if cu then
        local cache = agent.cache or {}
        cache.distill_usage = cu
        agent.cache = cache
      end
    end
    _splice(agent, window, summary)
    agent._distilling = false
    return async.resolve(true)
  end, function(err)
    agent._distilling = false
    logger.warn("[plan_distill] 分类失败: %s", tostring(err and err.message or err))
    return async.resolve(false)
  end)
end

-- ========== 公开 API ==========

--- 在 plan→execute 边界蒸馏（供 approve_plan 自动执行前调用；失败 no-op）
--- @param agent table Agent
--- @param opts table|nil { plan_mode? 覆盖 tools.plan_mode, min_chunks? }
--- @return Deferred resolve(boolean)
function M.run(agent, opts)
  if not agent or not agent.messages then
    return async.resolve(false)
  end
  return _distill(agent, opts)
end

--- 窗口切分（供测试直接使用）
M._window = _window
--- 分块（供测试直接使用）
M._chunk = _chunk

return M
