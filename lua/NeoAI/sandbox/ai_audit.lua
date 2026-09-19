--- 待审变更的 AI 审计
--- @module NeoAI.sandbox.ai_audit
--- 在沙箱待审审批界面按快捷键触发：把**原会话的用户消息**与**分级的待审变更/修改内容**
--- 拼成结构化文本，交给模型为每个文件（主机操作则为其命令）生成一句不超过 50 字的
--- 简体中文风险说明。说明作为**暗灰色补充说明显示在对应文件行下方**，不进入聊天界面，
--- 也**不自动应用或拒绝**任何变更。
---
--- `M.build_text(items, cfg)` / `M.build_messages(...)` / `M.parse_notes(...)` 为纯函数，便于离线测试；
--- `M.generate(items, user_messages, opts, on_done)` 负责异步请求，失败时回传错误文本。

local config_store = require("NeoAI.kernel.config_store")

local M = {}

-- ========== 私有状态 ==========

local state = {
  generator = nil, -- 测试注入：function(items, user_messages, on_done)
  active = 0, -- 在途审计请求数
  queue = {}, -- 等待中的审计任务（FIFO）
  max_concurrent = 10, -- 全局并发上限（由配置 tools.sandbox.review.ai_audit.max_concurrent 覆盖）
}

-- 重入保护：注入生成器可能同步回调，此时由外层 while 继续泵送，避免递归。
local pumping = false

-- ========== 私有常量 ==========

-- 安全级别 -> 风险档标签
local RISK_LABEL = {
  [0] = "低危(L0)",
  [1] = "中危(L1)",
  [2] = "高危(L2)",
  [3] = "严重(L3)",
}

-- 审计助手系统提示（稳定文本，便于前缀缓存复用）
local SYSTEM_PROMPT = table.concat({
  "你是 NeoAI 的变更审计助手。用户会提供一组待审的沙箱变更（含风险分级、修改内容与 diff）。",
  "请对其中每个文件（主机操作则为其命令）给出**一句不超过 50 个字的简体中文风险说明**。",
  "说明必须**先说结论**：以「安全」或「不安全」开头，再简述主要原因，",
  "例如「不安全：写入系统路径且难以回滚」。高危（L2/L3）变更同样必须给出说明，不得省略。",
  "严格按以下格式逐行输出，不要输出任何标题、总结或其他内容：",
  "<文件绝对路径或命令> => <安全|不安全>：<说明>",
}, "\n")

-- ========== 私有函数 ==========

--- 安全级别 -> 中文风险档
--- @param level number|nil
--- @return string
local function _risk_label(level)
  return RISK_LABEL[tonumber(level) or 0] or RISK_LABEL[0]
end

--- 将任意值压成单行
--- @param s any
--- @return string
local function _one_line(s)
  if s == nil then return "" end
  return (tostring(s):gsub("\r\n", "⏎"):gsub("[\r\n]", "⏎"))
end

--- 截断文本（字节），超出追加提示
--- @param s string|nil
--- @param max number|nil
--- @return string
local function _truncate(s, max)
  s = tostring(s or "")
  if not max or max <= 0 or #s <= max then return s end
  return s:sub(1, max) .. "\n…（已截断，共 " .. #s .. " 字节）"
end

--- 按字符（码点）截断，超出追加省略号，保证总长不超过 max 字
--- @param s string|nil
--- @param max number
--- @return string
local function _truncate_chars(s, max)
  s = tostring(s or "")
  max = tonumber(max) or 50
  if vim.fn.strchars(s) <= max then return s end
  return vim.fn.strcharpart(s, 0, math.max(0, max - 1)) .. "…"
end

--- 读取文件内容（不存在返回 ""）
--- @param path string
--- @return string
local function _read_file(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local c = f:read("*a")
  f:close()
  return c or ""
end

--- 从消息 content（字符串或多模态分段数组）提取纯文本
--- @param content any
--- @return string|nil
local function _text_of(content)
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    local parts = {}
    for _, seg in ipairs(content) do
      if type(seg) == "string" then
        parts[#parts + 1] = seg
      elseif type(seg) == "table" and type(seg.text) == "string" then
        parts[#parts + 1] = seg.text
      end
    end
    if #parts > 0 then return table.concat(parts, "\n") end
  end
  return nil
end

--- 构造单个文件的修改文本（unified diff；create 无差异时回退为内容）
--- @param f table 文件条目
--- @param cfg table 配置
--- @return string|nil
local function _file_diff(f, cfg)
  local action = tostring(f.action or "modify")
  if action == "mkdir" or action == "rmdir" then return nil end
  local before = action == "create" and "" or _read_file(f.path)
  local after = action == "delete" and "" or tostring(f.content or "")
  if before == "" and after == "" then return nil end
  local ok, diff = pcall(vim.diff, before, after, {
    result_type = "unified", ctxlen = 3, algorithm = "histogram",
  })
  if ok and type(diff) == "string" and diff ~= "" then
    return _truncate(diff, cfg.max_diff_chars)
  end
  -- 无差异或无法 diff：create 直接给出内容，便于模型判断新增内容是否安全。
  if action == "create" and after ~= "" then
    return _truncate(after, cfg.max_diff_chars)
  end
  return nil
end

--- 追加单个待审条目的结构化描述
--- @param lines table 行缓冲
--- @param item table 待审条目
--- @param index number 序号
--- @param cfg table 配置
local function _append_item(lines, item, index, cfg)
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("## 变更 %d：%s", index, tostring(item.change_set_id or "?"))
  lines[#lines + 1] = "- 工具：" .. tostring(item.tool or "?")
  if item.privilege_tier ~= nil then
    lines[#lines + 1] = "- 权限档：T" .. tostring(item.privilege_tier)
  end
  local reasons = table.concat(item.risk_reasons or {}, "；")
  lines[#lines + 1] = string.format("- 风险级别：%s%s", _risk_label(item.risk_level),
    reasons ~= "" and ("（" .. reasons .. "）") or "")
  if item.secret_warning and (tonumber(item.secret_warning.count) or 0) > 0 then
    lines[#lines + 1] = "- 敏感凭据：涉及密钥/凭据操作，需重点确认"
  end
  if item.package then
    local names = table.concat(item.package_names or {}, ", ")
    lines[#lines + 1] = string.format("- 包安装：%s%s", tostring(item.package_manager or "?"),
      names ~= "" and (": " .. names) or "")
  end
  if item.command then
    lines[#lines + 1] = "- 命令：" .. _one_line(item.command)
  end
  -- 主机操作（T2 提案）：无文件，只有一条待主机 replay 的命令
  if item.kind == "host_op" or (not item.files and item.write_set) then
    local cmd = (item.write_set and item.write_set[1]) or item.command or "?"
    lines[#lines + 1] = "- 主机操作命令：$ " .. _one_line(cmd)
    return
  end
  local files = item.files or {}
  if #files > 0 then
    lines[#lines + 1] = "- 修改文件："
    for _, f in ipairs(files) do
      lines[#lines + 1] = string.format("  - [%s] %s", tostring(f.action or "modify"), tostring(f.path or "?"))
      local diff = _file_diff(f, cfg)
      if diff then
        lines[#lines + 1] = "    ```diff"
        for _, dl in ipairs(vim.split(diff, "\n", { plain = true })) do
          lines[#lines + 1] = "    " .. dl
        end
        lines[#lines + 1] = "    ```"
      end
    end
  end
end

-- ========== 公开 API ==========

--- 审计助手系统提示
--- @return string
function M.system_prompt()
  return SYSTEM_PROMPT
end

--- 提取 Agent 中的真实用户消息（排除运行上下文快照与压缩检查点）
--- @param agent table|nil
--- @return table 文本数组
function M.user_messages(agent)
  local out = {}
  for _, m in ipairs((agent and agent.messages) or {}) do
    if m.role == "user" and not m.runtime_context and not m.checkpoint then
      local text = _text_of(m.content)
      if text and text:gsub("%s", "") ~= "" then
        out[#out + 1] = text
      end
    end
  end
  return out
end

--- 构造结构化审计文本（纯函数，便于测试）
--- @param items table 待审条目数组（sandbox.list_reviews 结果）
--- @param cfg table|nil 配置（tools.sandbox.review.ai_audit）
--- @return string
function M.build_text(items, cfg)
  cfg = cfg or {}
  -- 高风险优先：保证高危变更排在审计文本前部，避免因总长/输出上限截断而缺失其说明。
  local ordered = {}
  for i, item in ipairs(items or {}) do ordered[i] = item end
  table.sort(ordered, function(a, b)
    local la, lb = tonumber(a and a.risk_level) or 0, tonumber(b and b.risk_level) or 0
    if la ~= lb then return la > lb end
    return tostring(a and a.change_set_id or "") < tostring(b and b.change_set_id or "")
  end)
  local lines = {}
  lines[#lines + 1] = "【审计任务】"
  lines[#lines + 1] = "请对下列每个文件（主机操作为其命令）给出一句不超过 50 个字的简体中文风险说明，"
    .. "必须以「安全」或「不安全」开头，格式：<路径或命令> => <安全|不安全>：<说明>。"
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("【待审变更】共 %d 项（已按风险从高到低排列，高危变更不得省略说明）", #ordered)
  for i, item in ipairs(ordered) do
    _append_item(lines, item, i, cfg)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "请严格按 <路径或命令> => <安全|不安全>：<说明> 的格式逐行输出，不要输出其他内容。"
  return _truncate(table.concat(lines, "\n"), cfg.max_total_chars)
end

--- 解析模型输出为 { [路径或命令] = 说明 }；说明按字符截断到 max_chars（默认 50）。
--- 支持 `=>` / `::` / `：` 分隔；容忍 `[action]` 前缀。
--- @param text string|nil
--- @param max_chars number|nil
--- @return table
function M.parse_notes(text, max_chars)
  max_chars = max_chars or 50
  local notes = {}
  for _, raw in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
    local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      local key, note = line:match("^(.-)%s*=>%s*(.+)$")
      if not key then key, note = line:match("^(.-)%s*::%s*(.+)$") end
      if not key then key, note = line:match("^(.-)%s*：%s*(.+)$") end
      if key and note and note:gsub("%s", "") ~= "" then
        key = key:gsub("^%[.-%]%s*", "") -- 去掉可能的 [action] 前缀
        if key ~= "" then notes[key] = _truncate_chars(note, max_chars) end
      end
    end
  end
  return notes
end

--- 汇总审计结论：任一说明含「不安全」即判为存在不安全变更；否则仅在至少一条以「安全」
--- 开头时判为安全；模型未按格式给出明确结论时返回 nil（避免误报为安全）。
--- @param notes table|nil { [路径或命令]=说明 }
--- @return string|nil "unsafe" | "safe" | nil
function M.verdict(notes)
  local any, explicit_safe = false, false
  for _, note in pairs(notes or {}) do
    any = true
    local s = tostring(note or ""):gsub("^%s+", "")
    if s:sub(1, #"不安全") == "不安全" or s:find("不安全", 1, true) then
      return "unsafe"
    end
    if s:sub(1, #"安全") == "安全" then explicit_safe = true end
  end
  if not any then return nil end
  return explicit_safe and "safe" or nil
end

--- 构造请求消息：系统提示 + 用户消息（意图背景）+ 结构化审计文本
--- @param items table
--- @param user_messages table
--- @param cfg table|nil
--- @return table messages
function M.build_messages(items, user_messages, cfg)
  cfg = cfg or {}
  local messages = { { role = "system", content = SYSTEM_PROMPT } }
  for _, um in ipairs(user_messages or {}) do
    messages[#messages + 1] = { role = "user", content = _truncate(um, cfg.max_user_chars) }
  end
  messages[#messages + 1] = { role = "user", content = M.build_text(items, cfg) }
  return messages
end

--- 实际执行一次审计请求（测试注入优先）。on_done(result|nil, err|nil) 至多调用一次。
--- @param items table
--- @param user_messages table
--- @param opts table
--- @param on_done function
local function _invoke(items, user_messages, opts, on_done)
  if type(state.generator) == "function" then
    local ok = pcall(state.generator, items, user_messages, on_done)
    if not ok then on_done(nil, "生成器异常") end
    return
  end
  local cfg = opts.cfg or config_store.get("tools.sandbox.review.ai_audit") or {}
  local messages = M.build_messages(items, user_messages, cfg)
  local ok, d = pcall(function()
    return require("NeoAI.core.agent.request").send(messages, {
      agent_config = opts.agent_config,
      temperature = 0.2,
      max_tokens = cfg.max_tokens or 1024,
      max_retries = 0,
      timeout_ms = cfg.timeout_ms or 30000,
    })
  end)
  if not ok or not d or type(d.then_) ~= "function" then
    on_done(nil, "模型不可用")
    return
  end
  d:then_(function(resp)
    local content = resp and resp.content
    if type(content) == "string" and content:gsub("%s", "") ~= "" then
      local notes = M.parse_notes(content, 50)
      local fallback
      if next(notes) == nil then
        -- 模型未按格式输出：整段压成一句作为兜底说明（同样 ≤50 字）
        fallback = _truncate_chars(content:gsub("%s+", " "), 50)
      end
      on_done({ notes = notes, fallback = fallback }, nil)
    else
      on_done(nil, "模型未返回内容")
    end
  end, function(err)
    on_done(nil, (err and (err.message or tostring(err))) or "请求失败")
  end)
end

--- 泵送队列：在并发上限内启动等待中的审计任务（FIFO）。
local function _pump()
  if pumping then return end
  pumping = true
  while state.active < state.max_concurrent and #state.queue > 0 do
    local job = table.remove(state.queue, 1)
    state.active = state.active + 1
    local settled = false
    local function done(result, err)
      if settled then return end
      settled = true
      state.active = state.active - 1
      -- 调用方回调异常不应卡死泵送（否则 pumping 永不复位、队列停滞）。
      pcall(job.on_done, result, err)
      _pump()
    end
    local ok, err = pcall(_invoke, job.items, job.user_messages, job.opts, done)
    if not ok then done(nil, tostring(err)) end
  end
  pumping = false
end

--- 异步生成审计结论。成功时 on_done(result, nil)，result = { notes = { [key]=说明 }, fallback? = string }；
--- 失败时 on_done(nil, err)。全局并发上限 `max_concurrent`（默认 10）：在途请求达上限时
--- 后续任务排队，FIFO 等待空位。
--- @param items table 待审条目
--- @param user_messages table 原会话用户消息
--- @param opts table|nil { cfg?=table, agent_config?=table }
--- @param on_done function(result|nil, err|nil)
function M.generate(items, user_messages, opts, on_done)
  opts = opts or {}
  on_done = on_done or function() end
  local cfg = opts.cfg or config_store.get("tools.sandbox.review.ai_audit") or {}
  local limit = tonumber(cfg.max_concurrent) or 10
  if limit < 1 then limit = 1 end
  state.max_concurrent = limit
  state.queue[#state.queue + 1] = {
    items = items, user_messages = user_messages, opts = opts, on_done = on_done,
  }
  _pump()
end

--- 注入测试用生成器（nil 恢复默认）
--- @param fn function|nil
function M.set_generator(fn)
  state.generator = fn
end

--- 重置（测试用）
function M.reset()
  state.generator = nil
  state.active = 0
  state.queue = {}
  state.max_concurrent = 10
  pumping = false
end

return M
