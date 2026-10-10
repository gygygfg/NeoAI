--- 计划阶段上下文提取
--- @module NeoAI.core.session.plan_distill
--- 在「plan 完成 → 用户以任何非计划模式（chat/auto）确认开始」的边界，**不再**做 8 段蒸馏压缩。
--- 改为：在**尚未加入用户真实消息**的前提下，内部追加一轮「XML 结构化提取」请求：
---   - 回放现有前缀（系统 + 全部历史，复用前缀缓存）后追加提取指令，让 AI 输出结构化计划；
---   - 解析 <target> / <stepN> / <files> / <Rollback> / <Information> 等标签（忽略大小写）；
---   - 关键字段（target + 至少一个 stepN）缺失时重试，最多 3 次（总尝试次数），仍缺则忽略缺失；
---   - 把 <files> 涉及的文件在计划调研窗口中出现的 function/tool 成对消息**原样**取出，
---     与解析出的新上下文一起，作为**请求覆盖层**（agent.plan_extract）注入。
--- 覆盖层只影响发往模型的请求视图：agent.messages 保持原始，聊天显示与落盘**完全不变**，
--- 提取指令与 AI 的 XML 回复都**不进入** agent.messages。
--- 触发由 chat_service._distill_if_needed / approve_plan 统一判定（各触发一次）。
--- 失败一律 no-op：不阻塞发送、不改变历史，仅返回 false 并原样继续执行。

local async = require("NeoAI.utils.async")
local config_store = require("NeoAI.kernel.config_store")
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local logger = require("NeoAI.kernel.logger")
local json = require("NeoAI.utils.json")
local stringx = require("NeoAI.utils.stringx")

local M = {}

-- ========== 私有常量 ==========

--- 关键字段缺失时的最大总尝试次数（首跑 + 重试）
local MAX_ATTEMPTS = 3

--- XML 提取指令：作为「不进入历史」的最后一条 user 消息投递。
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

  return _extract_and_parse(agent, base, cfg):then_(function(fields)
    agent._distilling = false
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
M._build_prompt = PLAN_EXTRACT_INSTRUCTION

return M
