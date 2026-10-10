--- 计划阶段上下文提取
--- @module NeoAI.core.session.plan_distill
--- 在「plan 完成 → 用户以任何非计划模式（chat/auto）确认开始」的边界，**不再**做 8 段蒸馏压缩。
--- 改为：在**尚未加入用户真实消息**的前提下，内部追加「XML 结构化提取」请求：
---   - 回放现有前缀（系统 + 全部历史，复用前缀缓存）后追加提取指令，让 AI 输出结构化计划；
---   - 解析 <target> / <stepN> / <files> / <Rollback> / <Information> 等标签（忽略大小写）；
---   - 关键字段（target + 至少一个 stepN）缺失时重试，最多 distill_max_attempts 次，仍缺则忽略缺失；
---   - 把 <files> 涉及的文件在计划调研窗口中出现的 function/tool 成对消息**原样**取出，
---     与解析出的新上下文一起，作为**请求覆盖层**（agent.plan_extract）注入。
--- 覆盖层只影响发往模型的请求视图：agent.messages 保持原始，聊天显示与落盘**完全不变**，
--- 提取指令与 AI 的 XML 回复都**不进入** agent.messages。
--- 触发由 chat_service._distill_if_needed / approve_plan 统一判定（各触发一次）。
--- 失败一律 no-op：不阻塞发送、不改变历史，仅返回 false 并原样继续执行。
---
--- 并行编排（distill_parallel，默认开启）：
---   不再让单次请求串行生成全部标签，而是拆成多路并发请求，把墙钟时间压到「最慢一路」：
---   - front 压缩：对「进入 plan 前」的 front 用压缩器同款 8 段指令蒸馏为一条检查点消息；
---   - 第 1 轮（并行 3 路）：target / steps / files —— 各自只输出自己那组标签；
---   - 第 2 轮（并行 4 路）：background / constraints / verify / fallback —— 前缀回放
---     「历史 + 第 1 轮回显」，既复用缓存又让可选段引用已提炼的目标与步骤；
---   - 所有请求都先回放 `build_prefix(agent, agent.messages)`（system+历史+工具 schema，
---     与上一轮 plan 请求逐字节一致），以命中 provider 前缀缓存，多路增量只按缓存读+本路输出计费。
---   distill_parallel=false 时回退为旧的「单请求串行输出全部标签」legacy 路径（见 _extract_and_parse）。

local async = require("NeoAI.utils.async")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local logger = require("NeoAI.kernel.logger")
local json = require("NeoAI.utils.json")
local stringx = require("NeoAI.utils.stringx")

local M = {}

-- ========== 私有常量 ==========

--- legacy 路径关键字段缺失时的最大总尝试次数（首跑 + 重试）
local MAX_ATTEMPTS = 3

--- 并行路径默认单通道最大尝试次数
local DEFAULT_MAX_ATTEMPTS = 2

--- 共享输出规则：所有通道指令尾部一致，保证「只输出 XML、不调用工具」等约束统一。
local OUTPUT_RULES = table.concat({
  "要求：",
  "1. 只输出 XML 文本，不要输出任何解释、Markdown 代码围栏或多余文字；",
  "2. 不要调用任何工具；",
  "3. 每个标签都必须成对出现，标签名忽略大小写；",
  "4. 只输出下面“本路需要输出的标签”，不要输出其它标签；没有内容就整段省略（不要输出空标签）。",
}, "\n")

--- 第 1 轮通道：必需标量 / 步骤列表 / 涉及文件（相互独立，可完全并发）。
local CHANNELS_R1 = {
  {
    name = "target",
    label = "目标",
    tags = { "<target>" },
    instruction = table.concat({
      "请把上文的计划调研结论中的**任务目标**整理为结构化 XML，供后续执行阶段使用。",
      "",
      OUTPUT_RULES,
      "",
      "本路需要输出的标签：",
      "- <target>：任务目标（必需，概述这次要做成什么）。",
      "",
      "输出示例：",
      "<target>...</target>",
    }, "\n"),
  },
  {
    name = "steps",
    label = "步骤",
    tags = { "<stepN>" },
    instruction = table.concat({
      "请把上文的计划调研结论中的**执行步骤**整理为结构化 XML，供后续执行阶段使用。",
      "",
      OUTPUT_RULES,
      "",
      "本路需要输出的标签：",
      "- <step1><step2>…<stepN>：按执行先后顺序逐条给出可执行步骤（从 1 连续编号，至少一个）。",
      "",
      "输出示例：",
      "<step1>...</step1>",
      "<step2>...</step2>",
    }, "\n"),
  },
  {
    name = "files",
    label = "涉及文件",
    tags = { "<files>" },
    instruction = table.concat({
      "请从上文的计划调研结论中提取**完成目标所涉及的文件**，整理为结构化 XML，供后续执行阶段使用。",
      "",
      OUTPUT_RULES,
      "",
      "本路需要输出的标签：",
      "- <files>：完成目标所涉及的文件（必要读取和修改的文件；每行一个路径）。",
      "",
      "输出示例：",
      "<files>lua/foo.lua\\nlua/bar.lua</files>",
    }, "\n"),
  },
}

--- 第 2 轮通道：可选补充信息，按类别分成 4 路并发（前缀含第 1 轮回显）。
local CHANNELS_R2 = {
  {
    name = "background",
    label = "背景",
    tags = { "<Context>", "<Scope>", "<OutOfScope>" },
    instruction = table.concat({
      "请把上文的计划调研结论中的**背景与范围**整理为结构化 XML，供后续执行阶段使用。",
      "",
      OUTPUT_RULES,
      "",
      "本路需要输出的标签（均为可选）：",
      "- <Context>：背景（为什么做）",
      "- <Scope>：本次改动范围",
      "- <OutOfScope>：明确不做的事",
    }, "\n"),
  },
  {
    name = "constraints",
    label = "约束",
    tags = { "<Constraints>", "<Commands>", "<Dependencies>", "<Environment>" },
    instruction = table.concat({
      "请把上文的计划调研结论中的**约束与技术信息**整理为结构化 XML，供后续执行阶段使用。",
      "",
      OUTPUT_RULES,
      "",
      "本路需要输出的标签（均为可选）：",
      "- <Constraints>：约束条件",
      "- <Commands>：关键命令",
      "- <Dependencies>：依赖 / 前置条件",
      "- <Environment>：环境 / 技术栈",
    }, "\n"),
  },
  {
    name = "verify",
    label = "验证",
    tags = { "<Verify>", "<Risks>" },
    instruction = table.concat({
      "请把上文的计划调研结论中的**验证与风险**整理为结构化 XML，供后续执行阶段使用。",
      "",
      OUTPUT_RULES,
      "",
      "本路需要输出的标签（均为可选）：",
      "- <Verify>：验证 / 验收方式",
      "- <Risks>：风险与注意事项",
    }, "\n"),
  },
  {
    name = "fallback",
    label = "回退",
    tags = { "<Rollback>", "<Questions>", "<Information>" },
    instruction = table.concat({
      "请把上文的计划调研结论中的**回退与补充信息**整理为结构化 XML，供后续执行阶段使用。",
      "",
      OUTPUT_RULES,
      "",
      "本路需要输出的标签（均为可选）：",
      "- <Rollback>：回退方案",
      "- <Questions>：待澄清问题",
      "- <Information>：所需的其他信息",
    }, "\n"),
  },
}

--- legacy 路径：单请求串行输出全部标签。
local PLAN_EXTRACT_INSTRUCTION = table.concat({
  "请把上文的计划调研结论整理为结构化 XML，供后续执行阶段使用。",
  "",
  "要求：",
  "1. 只输出 XML 文本，不要输出任何解释、Markdown 代码围栏或多余文字；",
  "2. 不要调用任何工具；",
  "3. 每个标签都必须成对出现，标签名忽略大小写；",
  "4. <target> 与 <step1><step2>…<stepN> 为必需：target 概述任务目标；",
  "   stepN 按执行先后顺序逐条给出可执行步骤（从 1 连续编号，至少一个）；",
  "5. 其余为可选标签，没有内容就整段省略（不要输出空标签）。",
  "",
  "允许的标签清单（标签名忽略大小写）：",
  "- <target>：任务目标（必需）",
  "- <stepN>：第 N 个执行步骤（必需，至少一个，从 step1 连续编号）",
  "- <files>：完成目标所涉及的文件（必要读取和修改的文件；每行一个路径）",
  "- <Rollback>：回退方案",
  "- <Information>：所需的其他信息",
  "- <Context>：背景（为什么做）",
  "- <Scope>：本次改动范围",
  "- <OutOfScope>：明确不做的事",
  "- <Constraints>：约束条件",
  "- <Commands>：关键命令",
  "- <Dependencies>：依赖 / 前置条件",
  "- <Environment>：环境 / 技术栈",
  "- <Verify>：验证 / 验收方式",
  "- <Risks>：风险与注意事项",
  "- <Questions>：待澄清问题",
  "",
  "输出示例：",
  "<target>...</target>",
  "<step1>...</step1>",
  "<step2>...</step2>",
  "<files>lua/foo.lua\nlua/bar.lua</files>",
  "<Rollback>...</Rollback>",
}, "\n")

--- 新上下文消息的小节顺序（{ key, label }）；空节省略。
local CONTEXT_SECTIONS = {
  { key = "context", label = "背景" },
  { key = "scope", label = "范围" },
  { key = "outofscope", label = "不做的事" },
  { key = "constraints", label = "约束条件" },
  { key = "files", label = "涉及文件" },
  { key = "commands", label = "关键命令" },
  { key = "dependencies", label = "依赖 / 前置条件" },
  { key = "environment", label = "环境 / 技术栈" },
  { key = "verify", label = "验证 / 验收" },
  { key = "risks", label = "风险与注意事项" },
  { key = "rollback", label = "回退方案" },
  { key = "questions", label = "待澄清问题" },
  { key = "information", label = "其他信息" },
}

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

--- 去除首尾空白
--- @param s string
--- @return string
local function _trim(s)
  if type(s) ~= "string" then return "" end
  return stringx.trim(s)
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

--- 读取单个标签的值（忽略大小写）。low 为 text 的小写副本（字节长度一致）。
--- @param text string 原文
--- @param low string 小写副本
--- @param tag string 小写标签名
--- @return string|nil 去首尾空白后的值（找到标签但无闭合返回 nil）
local function _tag_value(text, low, tag)
  local open = "<" .. tag .. ">"
  local close = "</" .. tag .. ">"
  local s = low:find(open, 1, true)
  if not s then return nil end
  local e = low:find(close, s + #open, true)
  if not e then return nil end
  return _trim(text:sub(s + #open, e - 1))
end

--- 解析提取结果文本为字段表（忽略大小写）。
--- @param text string
--- @return table { target?, steps={...}, files?, context?, ... }
local function _parse(text)
  local fields = { steps = {} }
  if type(text) ~= "string" or text == "" then return fields end
  -- 小写副本：string.lower 只改写 ASCII（字节数不变），可用同一下标切回原文取值。
  local low = text:lower()

  fields.target = _tag_value(text, low, "target")

  -- 步骤：扫描所有 <stepN>，按 N 升序取用（自动支持 step1..stepN 任意数量）。
  local nums = {}
  for n in low:gmatch("<step(%d+)>") do
    local v = tonumber(n)
    if v and v >= 1 and v <= 500 then nums[#nums + 1] = v end
  end
  table.sort(nums)
  local seen = {}
  for _, n in ipairs(nums) do
    if not seen[n] then
      seen[n] = true
      local v = _tag_value(text, low, "step" .. n)
      if v and v ~= "" then fields.steps[#fields.steps + 1] = v end
    end
  end

  for _, sec in ipairs(CONTEXT_SECTIONS) do
    local v = _tag_value(text, low, sec.key)
    if v and v ~= "" then fields[sec.key] = v end
  end
  return fields
end

--- 关键字段是否缺失（target + 至少一个 stepN）
--- @param fields table
--- @return boolean need_retry
--- @return string missing 描述
local function _needs_retry(fields)
  local missing = {}
  if not fields or not fields.target or fields.target == "" then missing[#missing + 1] = "<target>" end
  if not fields or not fields.steps or #fields.steps == 0 then missing[#missing + 1] = "<stepN>" end
  return #missing > 0, table.concat(missing, ", ")
end

--- 从 <files> 文本提取候选路径（用于匹配工具调用参数 / 结果）。
--- @param files_text string|nil
--- @return table 数组 of string
local function _file_candidates(files_text)
  local out, seen = {}, {}
  if type(files_text) ~= "string" then return out end
  for tok in files_text:gmatch("[%w%._/%-]+") do
    if #tok >= 3 and (tok:find("%.") or tok:find("/")) and not seen[tok] then
      seen[tok] = true
      out[#out + 1] = tok
    end
  end
  return out
end

--- 在计划窗口中挑出与 <files> 相关的 function/tool 成对消息（原对象、按原顺序、逐字节原样）。
--- 匹配规则：工具调用参数或工具结果内容中出现任一候选路径 → 认为是相关调用。
--- 成对：命中的 assistant(tool_calls) 消息 + 其对应的 tool 结果消息一并取出。
--- @param window table 计划窗口（原始内部消息）
--- @param files_text string|nil <files> 标签原文
--- @return table 数组（对相关消息的原始引用，保持顺序）
local function _collect_file_tool_messages(window, files_text)
  local candidates = _file_candidates(files_text)
  if #candidates == 0 then return {} end

  local function _matches(text)
    if type(text) ~= "string" or text == "" then return false end
    for _, p in ipairs(candidates) do
      if text:find(p, 1, true) then return true end
    end
    return false
  end

  -- tool_call_id -> 发起它的 assistant 消息下标
  local call_owner = {}
  for i, m in ipairs(window) do
    if m and m.role == "assistant" and m.tool_calls then
      for _, tc in ipairs(m.tool_calls) do
        if tc and tc.id then call_owner[tc.id] = i end
      end
    end
  end

  local included = {}
  for i, m in ipairs(window) do
    if m and m.role == "assistant" and m.tool_calls then
      for _, tc in ipairs(m.tool_calls) do
        local fn = tc and tc["function"] or {}
        local args = fn.arguments
        if type(args) ~= "string" then args = _render_content(args) end
        if _matches(args) then included[i] = true end
      end
    elseif m and m.role == "tool" then
      if _matches(_render_content(m.content)) then
        local owner = call_owner[m.tool_call_id]
        if owner then
          included[owner] = true
          included[i] = true
        end
      end
    end
  end

  -- 补齐成对：命中的 assistant 消息，其紧随的 tool 结果尽量一并取出（保持协议完整）。
  for i, m in ipairs(window) do
    if included[i] and m.role == "assistant" and m.tool_calls then
      for j = i + 1, #window do
        local r = window[j]
        if r and r.role == "tool" and call_owner[r.tool_call_id] == i then
          included[j] = true
        else
          break
        end
      end
    end
  end

  local out = {}
  for i = 1, #window do
    if included[i] then out[#out + 1] = window[i] end
  end
  return out
end

--- 把解析出的字段组装成一条新的「用户」上下文消息（空节省略）。
--- @param fields table
--- @return string
local function _build_context_message(fields)
  local lines = { "以下是计划阶段提炼出的执行上下文（已确认的计划，请据此继续执行）：", "" }

  if fields.target and fields.target ~= "" then
    lines[#lines + 1] = "## 任务目标"
    lines[#lines + 1] = fields.target
    lines[#lines + 1] = ""
  end

  for _, sec in ipairs(CONTEXT_SECTIONS) do
    local v = fields[sec.key]
    if v and v ~= "" then
      lines[#lines + 1] = "## " .. sec.label
      lines[#lines + 1] = v
      lines[#lines + 1] = ""
    end
  end

  if fields.steps and #fields.steps > 0 then
    lines[#lines + 1] = "## 执行步骤"
    for i, s in ipairs(fields.steps) do
      lines[#lines + 1] = ("%d. %s"):format(i, s)
    end
  end

  return table.concat(lines, "\n")
end

--- 由解析出的步骤构建任务清单项（每步一项，pending）。
--- @param fields table
--- @return table 数组 { content, status }
local function _build_todo_items(fields)
  local out = {}
  for _, s in ipairs(fields and fields.steps or {}) do
    if type(s) == "string" and _trim(s) ~= "" then
      out[#out + 1] = { content = _trim(s), status = "pending" }
    end
  end
  return out
end

--- 内部分类调用（可在测试中替换）：回放 messages → 流式接收 XML。
--- @param agent table
--- @param messages table API 消息数组
--- @param cfg table
--- @param on_chunk function|nil
--- @return Deferred resolve(string|nil content)
local function _send_extract(agent, messages, cfg, on_chunk)
  local request = require("NeoAI.core.agent.request")
  local tool_loop = require("NeoAI.core.agent.tool_loop")
  local tool_defs = tool_loop._tool_definitions(agent)
  return request.send_stream(messages, {
    agent_config = agent.config,
    model = agent.model,
    tools = tool_defs,
    signal = agent.signal,
    -- 提取输出上限：nil（默认）＝不下发 max_tokens，由厂商默认最大输出决定，避免推理型模型
    -- 在固定小上限处被 finish_reason=length 截断、关键字段缺失后触发整轮重试（见 default_config）。
    max_tokens = cfg.extract_max_tokens,
  }, on_chunk):then_(function(resp)
    return resp and resp.content
  end)
end

-- ========== legacy 路径：单请求串行输出全部标签 ==========

--- 提取并按关键字段缺失重试（总尝试 ≤ MAX_ATTEMPTS）。失败返回 nil。
--- @param agent table
--- @param base table 前缀 API 消息数组（不含提取指令）
--- @param cfg table
--- @return Deferred resolve(table fields)|resolve(nil)
local function _extract_and_parse(agent, base, cfg)
  local function attempt_once(extra)
    local msgs = {}
    for _, m in ipairs(base or {}) do msgs[#msgs + 1] = m end
    msgs[#msgs + 1] = { role = "user", content = extra }
    local acc_reasoning, acc_content = "", ""
    return M._send_extract(agent, msgs, cfg, function(chunk)
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
    end)
  end

  local function loop(attempt)
    local n = attempt + 1
    local extra = PLAN_EXTRACT_INSTRUCTION
    if n > 1 then
      extra = extra .. "\n\n注意：上一次输出缺少必需的 <target> 或至少一个 <stepN>，请务必补齐。"
    end
    return attempt_once(extra):then_(function(content)
      local fields = _parse(content)
      local need, missing = _needs_retry(fields)
      if not need then return fields end
      if n >= MAX_ATTEMPTS then
        logger.warn("[plan_extract] 第 %d 次提取仍缺少 %s，忽略缺失", n, missing)
        return fields
      end
      return loop(n)
    end, function(err)
      if n >= MAX_ATTEMPTS then
        logger.warn("[plan_extract] 提取失败: %s", tostring(err and err.message or err))
        return nil
      end
      return loop(n)
    end)
  end

  return loop(0)
end

-- ========== 并行路径：多轮多路并发提取 ==========

--- 单通道请求：回放 base（+ 可选前置回显）→ 追加该通道指令 → 流式接收。
--- 每路的分片经 on_chunk(channel, acc_reasoning, acc_content) 回调，供 UI 合并展示。
--- @param agent table
--- @param base table 前缀 API 消息数组
--- @param prefix_extra table|nil 追加在 base 之后、指令之前的消息（R2 的回显）
--- @param channel table { name, label, instruction }
--- @param cfg table
--- @param on_chunk function|nil (channel, reasoning, content)
--- @return Deferred resolve(string|nil content)
local function _send_channel(agent, base, prefix_extra, channel, cfg, on_chunk)
  local msgs = {}
  for _, m in ipairs(base or {}) do msgs[#msgs + 1] = m end
  for _, m in ipairs(prefix_extra or {}) do msgs[#msgs + 1] = m end
  msgs[#msgs + 1] = { role = "user", content = channel.instruction }

  local acc_reasoning, acc_content = "", ""
  return M._send_extract(agent, msgs, cfg, function(chunk)
    if not chunk then return end
    if chunk.reasoning and chunk.reasoning ~= "" then
      acc_reasoning = acc_reasoning .. chunk.reasoning
    end
    if chunk.content and chunk.content ~= "" then
      acc_content = acc_content .. chunk.content
    end
    if on_chunk then on_chunk(channel, acc_reasoning, acc_content) end
  end)
end

--- 单通道「发送 + 解析 + 按缺失重试」，返回该通道的字段片段。
--- 解析出 trigger（触发重试）后，重试次数由调用方按 (attempts - 1) 计数；此函数内部
--- 最多尝试两次（首跑 + 一次带「请补齐」提示的重试）；调用方可用 on_attempt 感知首跑结果。
--- @param agent table
--- @param base table
--- @param prefix_extra table|nil
--- @param channel table
--- @param cfg table
--- @param trigger_retry function(fields)->boolean, string|nil 首跑是否需重试
--- @param on_chunk function|nil
--- @return Deferred resolve(table fields|nil) 解析到的字段（可能为空表）
local function _run_channel(agent, base, prefix_extra, channel, cfg, trigger_retry, on_chunk)
  local max_attempts = tonumber(cfg.distill_max_attempts) or DEFAULT_MAX_ATTEMPTS
  if max_attempts < 1 then max_attempts = 1 end

  local function attempt(n, extra_hint)
    local ch = channel
    if extra_hint then
      ch = vim.tbl_extend("force", {}, channel)
      ch.instruction = channel.instruction .. "\n\n" .. extra_hint
    end
    return _send_channel(agent, base, prefix_extra, ch, cfg, on_chunk):then_(function(content)
      local fields = _parse(content)
      local need, missing = trigger_retry(fields)
      if not need then return fields end
      if n >= max_attempts then
        return fields
      end
      logger.debug("[plan_extract] 通道 %s 缺少 %s，重试 (%d/%d)",
        channel.name, tostring(missing), n + 1, max_attempts)
      return attempt(n + 1, ("注意：上一次输出缺少必需的 %s，请务必补齐。"):format(tostring(missing)))
    end, function(err)
      if n >= max_attempts then
        logger.warn("[plan_extract] 通道 %s 提取失败: %s", channel.name,
          tostring(err and err.message or err))
        return nil
      end
      return attempt(n + 1, nil)
    end)
  end

  return attempt(1, nil)
end

--- 合并两轮字段（后者不覆盖前者已有的非空值）。
--- @param dst table
--- @param src table|nil
local function _merge_fields(dst, src)
  if type(src) ~= "table" then return dst end
  if (dst.target == nil or dst.target == "") and src.target and src.target ~= "" then
    dst.target = src.target
  end
  if src.steps and #src.steps > 0 and (not dst.steps or #dst.steps == 0) then
    dst.steps = src.steps
  end
  for _, sec in ipairs(CONTEXT_SECTIONS) do
    local v = src[sec.key]
    if v and v ~= "" and (dst[sec.key] == nil or dst[sec.key] == "") then
      dst[sec.key] = v
    end
  end
  return dst
end

--- 把第 1 轮字段回显为一条 user「回显」消息（供第 2 轮前缀引用，同时稳定缓存）。
--- @param fields table R1 合并结果
--- @return table API 消息
local function _echo_r1_message(fields)
  local lines = { "以下是已提炼的计划要点（请据此补全其余可选信息）：" }
  if fields.target and fields.target ~= "" then
    lines[#lines + 1] = "<target>" .. fields.target .. "</target>"
  end
  for i, s in ipairs(fields.steps or {}) do
    lines[#lines + 1] = ("<step%d>%s</step%d>"):format(i, s, i)
  end
  if fields.files and fields.files ~= "" then
    lines[#lines + 1] = "<files>" .. fields.files .. "</files>"
  end
  return { role = "user", content = table.concat(lines, "\n") }
end

--- 并行提取编排：front 压缩 + 两轮多路并发。
--- @param agent table
--- @param base table 前缀 API 消息数组（build_prefix 结果，逐字节一致以命中缓存）
--- @param front table front 消息数组（原始内部消息）
--- @param cfg table
--- @return Deferred resolve({ fields, front_checkpoint })
local function _extract_parallel(agent, base, front, cfg)
  -- 合并视图：各通道分片带标题追加，UI 默认单栏展示也能区分来源。
  local acc = {}
  local function on_chunk(channel, reasoning, content)
    acc[channel.name] = { label = channel.label, reasoning = reasoning, content = content }
    local order = {}
    local function push(name)
      local e = acc[name]
      if not e then return end
      order[#order + 1] = "### " .. e.label
      if e.reasoning and e.reasoning ~= "" then order[#order + 1] = e.reasoning end
      if e.content and e.content ~= "" then order[#order + 1] = e.content end
    end
    for _, c in ipairs(CHANNELS_R1) do push(c.name) end
    for _, c in ipairs(CHANNELS_R2) do push(c.name) end
    event_bus.emit(events.PLAN_DISTILL_CHUNK, {
      agent_id = agent.id,
      channel = channel.name,
      content = table.concat(order, "\n\n"),
    })
  end

  --- front 压缩：仅回放 system+front，产出 8 段检查点消息；失败返回 nil（回退原样 front）。
  local function run_front()
    if cfg.distill_front == false or #front == 0 then
      return async.resolve(nil)
    end
    local ok_c, compactor = pcall(require, "NeoAI.core.session.compactor")
    if not ok_c or type(compactor) ~= "table" then return async.resolve(nil) end
    local context_builder = require("NeoAI.core.session.context_builder")
    local prefix_ok, prefix_msgs = pcall(context_builder.build_prefix, agent, front)
    if not prefix_ok or type(prefix_msgs) ~= "table" then return async.resolve(nil) end
    prefix_msgs[#prefix_msgs + 1] = { role = "user", content = compactor.COMPACTION_INSTRUCTION }
    return M._send_extract(agent, prefix_msgs, { max_tokens = cfg.extract_max_tokens }):then_(function(content)
      if not content or _trim(content) == "" then return nil end
      local ck = compactor.checkpoint_message(content)
      ck.ts = os.time()
      return ck
    end, function(err)
      logger.warn("[plan_extract] front 压缩失败，回退原样 front: %s", tostring(err and err.message or err))
      return nil
    end)
  end

  -- 第 1 轮：3 路并发（target / steps / files）
  local r1_tasks = {}
  for _, ch in ipairs(CHANNELS_R1) do
    local channel = ch
    r1_tasks[#r1_tasks + 1] = function()
      local trigger
      if channel.name == "target" then
        trigger = function(f) if not f.target or f.target == "" then return true, "<target>" end return false end
      elseif channel.name == "steps" then
        trigger = function(f) if not f.steps or #f.steps == 0 then return true, "<stepN>" end return false end
      else
        trigger = function() return false end -- files 缺失即忽略，不重试
      end
      return _run_channel(agent, base, nil, channel, cfg, trigger, on_chunk)
    end
  end

  local r1_ds = {}
  for _, t in ipairs(r1_tasks) do r1_ds[#r1_ds + 1] = t() end
  local d_r1 = async.all(r1_ds)

  local d_full = d_r1:then_(function(r1_results)
    r1_results = r1_results or {}
    local fields = { steps = {} }
    _merge_fields(fields, r1_results[1]) -- target
    _merge_fields(fields, r1_results[2]) -- steps
    _merge_fields(fields, r1_results[3]) -- files

    -- R1 完全失败（既无 target 也无步骤）：整体放弃（no-op）。
    -- 与 legacy 一致：只要拿到 target 或至少一个步骤即继续（缺一个不阻塞发送）。
    local has_target = fields.target and fields.target ~= ""
    local has_steps = fields.steps and #fields.steps > 0
    if not has_target and not has_steps then
      return { fields = nil, front_checkpoint = nil }
    end

    -- 第 2 轮：4 路并发，前缀回放「base + R1 回显」
    local echo = _echo_r1_message(fields)
    local r2_ds = {}
    for _, ch in ipairs(CHANNELS_R2) do
      local channel = ch
      r2_ds[#r2_ds + 1] = _run_channel(agent, base, { echo }, channel, cfg, function() return false end, on_chunk)
    end
    local d_r2 = async.all(r2_ds)

    return d_r2:then_(function(r2_results)
      for _, frag in ipairs(r2_results or {}) do _merge_fields(fields, frag) end
      return { fields = fields }
    end, function()
      -- R2 全失败：用 R1 结果继续
      return { fields = fields }
    end)
  end)

  local d_front = run_front()

  return async.all({ d_full, d_front }):then_(function(res)
    local full = res[1] or {}
    return { fields = full.fields, front_checkpoint = res[2] }
  end)
end

-- ========== 公开 API ==========

--- 在 plan→execute 边界执行「XML 计划提取」，结果写入请求覆盖层 agent.plan_extract。
--- 不改动 agent.messages（显示 / 落盘不变）。
--- @param agent table Agent
--- @param opts table|nil { plan_mode? 覆盖 tools.plan_mode }
--- @return Deferred resolve({ fields, steps })|resolve(false)
function M.run(agent, opts)
  if not agent or not agent.messages then
    return async.resolve(false)
  end
  local cfg = _cfg(opts)
  if cfg.distill_on_execute == false then
    return async.resolve(false)
  end
  local window, front = _window(agent)
  if #window == 0 then
    return async.resolve(false)
  end

  -- 回放现有前缀（系统 + 全部历史原对象）以复用前缀缓存；失败时退化为原始消息数组。
  local context_builder = require("NeoAI.core.session.context_builder")
  local ok, base = pcall(context_builder.build_prefix, agent, agent.messages)
  if not ok or type(base) ~= "table" then base = agent.messages end

  agent._distilling = true
  event_bus.emit(events.PLAN_DISTILL_STARTED, { agent_id = agent.id })

  local d
  if cfg.distill_parallel == false then
    -- legacy：单请求串行输出全部标签
    d = _extract_and_parse(agent, base, cfg):then_(function(fields)
      return { fields = fields, front_checkpoint = nil }
    end)
  else
    d = _extract_parallel(agent, base, front, cfg)
  end

  return d:then_(function(res)
    agent._distilling = false
    local fields = res and res.fields
    if not fields then
      return async.resolve(false)
    end
    local file_msgs = _collect_file_tool_messages(window, fields.files)
    local inject = {}
    for _, m in ipairs(file_msgs) do inject[#inject + 1] = m end
    inject[#inject + 1] = { role = "user", content = _build_context_message(fields) }
    agent.plan_extract = {
      front_count = #front,
      window_end = #(agent.messages),
      inject = inject,
      front_checkpoint = res and res.front_checkpoint or nil,
    }
    event_bus.emit(events.PLAN_DISTILLED, {
      agent_id = agent.id,
      fields = fields,
      steps = #fields.steps,
    })
    return async.resolve({ fields = fields, steps = fields.steps })
  end, function(err)
    agent._distilling = false
    logger.warn("[plan_extract] 提取异常: %s", tostring(err and err.message or err))
    return async.resolve(false)
  end)
end

-- ========== 测试辅助：暴露内部纯函数 ==========
M._window = _window
M._parse = _parse
M._needs_retry = _needs_retry
M._file_candidates = _file_candidates
M._collect_file_tool_messages = _collect_file_tool_messages
M._build_context_message = _build_context_message
M._build_todo_items = _build_todo_items
M._extract_and_parse = _extract_and_parse
M._send_extract = _send_extract
M._send_channel = _send_channel
M._run_channel = _run_channel
M._extract_parallel = _extract_parallel
M._merge_fields = _merge_fields
M._echo_r1_message = _echo_r1_message
M._build_prompt = PLAN_EXTRACT_INSTRUCTION
M.CHANNELS_R1 = CHANNELS_R1
M.CHANNELS_R2 = CHANNELS_R2

return M
