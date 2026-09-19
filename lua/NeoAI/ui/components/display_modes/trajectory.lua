--- 显示模式插件：轨迹
--- @module NeoAI.ui.components.display_modes.trajectory
--- 轨迹显示模式（参考 deepseek-harness 的 trajectory 视图）：
--- 多级折叠，逐层展开：
--- - 层级 1（turn）：每个 turn（用户请求 → AI 请求 → 工具调用 → 结果）是一个折叠；
--- - 层级 2（小节）：turn 内的「用户请求」「请求 #N」各为一个折叠；
--- - 层级 3（子块）：请求内的推理 / 工具调用 / 原始请求体 / 原始响应各为一个折叠，
---   避免展开请求时一次性倾倒全部 wire 级数据。
--- 折叠等级由行缩进深度决定：▸ 头行 = 该级折叠起点，内容按缩进归属对应层级。
--- 由 display_modes 管理器懒加载，本模块顶层向管理器自注册。

local manager = require("NeoAI.ui.components.display_modes")
local stringx = require("NeoAI.utils.stringx")
local incremental = require("NeoAI.ui.components.incremental")

local M = {
  name = "trajectory",
  label = "轨迹",
  desc = "轨迹模式：多级折叠，逐层展示原始请求/响应/工具调用等 wire 级细节",
}

-- ========== 私有常量 ==========

-- 原始请求体 / 原始 SSE 分片的显示字符上限（完整数据仍存于消息元数据）
local MAX_REQUEST_BODY_CHARS = 8000
local MAX_RAW_CHUNKS_CHARS = 6000

-- ========== 私有函数 ==========

--- 拆分为行数组（统一 \r\n/\r）
--- @param text string|nil
--- @return table
local function _split_lines(text)
  text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(text, "\n", { plain = true })
end

--- 追加缩进文本块（每行前缀 base 级 * 2 空格；空行保留为空白）
--- @param lines table
--- @param text string
--- @param base number 缩进级数（2 空格/级）
local function _append_raw(lines, text, base)
  for _, l in ipairs(_split_lines(text)) do
    if l == "" then
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = string.rep("  ", base) .. l
    end
  end
end

--- 折叠文本：turn 摘要（用户内容预览 + 请求/工具数量）
--- @param turn table
--- @return string
local function _header(turn)
  local parts = { "⏷ Turn " .. turn.index }
  if turn.user and turn.user.content and turn.user.content ~= "" then
    local preview = turn.user.content:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    preview = stringx.truncate(preview, 48)
    parts[#parts + 1] = "用户: " .. preview
  else
    parts[#parts + 1] = "用户"
  end
  local req, tools = 0, 0
  for _, e in ipairs(turn.entries) do
    if e.role == "assistant" then
      req = req + 1
      if e.tool_calls then tools = tools + #e.tool_calls end
    end
  end
  if req > 0 then parts[#parts + 1] = req .. " 请求" end
  if tools > 0 then parts[#parts + 1] = tools .. " 工具" end
  return table.concat(parts, " · ")
end

--- 追加系统提示词块（层级 1 折叠，内容层级 2 缩进）
--- @param lines table
--- @param turn table
local function _append_system(lines, turn)
  lines[#lines + 1] = "⏷ SYSTEM · 系统提示词"
  for _, msg in ipairs(turn.sys_msgs or {}) do
    if msg.content and msg.content ~= "" then
      _append_raw(lines, msg.content, 2)
    end
  end
end

--- 追加单个工具子块（层级 3）：▸ 工具调用 + 参数/结果
--- @param lines table
--- @param marks table 与 lines 并行的元数据数组（登记行内密钥高亮区间）
--- @param tool_call table
--- @param result_msg table|nil 对应工具结果消息
local function _append_tool_sub(lines, marks, tool_call, result_msg)
  local fold = require("NeoAI.ui.components.fold")
  local helpers = require("NeoAI.ui.components.message_list").helpers
  local fn = tool_call["function"]
  local name = fn and fn.name or "unknown"
  local status_emoji, time_str = "⏳", ""
  if result_msg then
    status_emoji = helpers.tool_result_failed(result_msg.content) and "❌" or "✅"
    if result_msg.duration_ms then time_str = " · " .. fold.format_ms(result_msg.duration_ms) end
  else
    local status = fold.get_status(tool_call.id)
    if status == "success" then
      status_emoji = "✅"
    elseif status == "failure" then
      status_emoji = "❌"
    end
    local dur = fold.get_duration(tool_call.id)
    if dur then time_str = " · " .. fold.format_ms(dur) end
  end
  -- 密钥防护：命令参数或结果（模型上下文）含密钥时，在工具行追加醒目标记，
  -- 并在结果下方给出「哪个命令/工具获取或使用了哪个密钥文件」的明细。
  local secret_line = helpers.secret_warning_line and helpers.secret_warning_line(fn, result_msg) or nil
  local has_secret = secret_line ~= nil
  local secret_str = has_secret and "  ⚠ 密钥" or ""
  -- 含密钥的工具调用：参数/结果完整展示（不截断），并登记行内密钥高亮区间。
  -- 先收集本子块的行，再整块一次性扫描（避免逐行检测拖慢大结果）。
  local sub_lines = {}
  local function push(text) sub_lines[#sub_lines + 1] = text end
  push("    ▸ 工具调用: " .. name .. " " .. status_emoji .. time_str .. secret_str)
  local arg_lines = helpers.tool_arguments_lines(fn, { full = has_secret })
  if arg_lines then
    push("      参数:")
    for _, l in ipairs(arg_lines) do
      push("        " .. l)
    end
  end
  if result_msg then
    push("      结果:")
    for _, l in ipairs(helpers.result_lines(result_msg.content, { full = has_secret })) do
      push("        " .. l)
    end
    -- 工具结果 UI 附加提示（如沙箱降级）：仅用户可见，不进入模型上下文。
    if result_msg.notice and result_msg.notice ~= "" then
      for _, l in ipairs(vim.split(tostring(result_msg.notice), "\n", { plain = true })) do
        push("      " .. l)
      end
    end
  end
  if has_secret and helpers.attach_secret_spans then
    helpers.attach_secret_spans(sub_lines, true)
  end
  for _, l in ipairs(sub_lines) do
    if type(l) == "table" then
      lines[#lines + 1] = l.text
      if l.secret_spans then marks[#lines] = { secret_spans = l.secret_spans } end
    else
      lines[#lines + 1] = l
    end
  end
  if secret_line then
    lines[#lines + 1] = "      " .. secret_line
    marks[#lines] = { secret = true }
  end
end

--- 追加单个请求的 wire 级细节（层级 3 子块）：请求参数 / 原始请求体 / 原始响应。
--- 数据来自 agent 在每次请求后附加到 assistant 消息的 request/response 元数据；
--- 无元数据（如历史会话）时跳过，不影响基本展示。
--- @param lines table
--- @param msg table assistant 消息
--- @param full boolean|nil true=保存日志：不截断原始请求体/响应分片（完整 wire 数据）
local function _append_request_meta(lines, msg, full)
  local helpers = require("NeoAI.ui.components.message_list").helpers
  local fold = require("NeoAI.ui.components.fold")
  local req = msg.request
  local resp = msg.response
  if not req and not resp then return end

  -- 请求参数（层级 2 内容行，展开请求小节即见）
  if req then
    local parts = {}
    local body = req.body
    if req.model then parts[#parts + 1] = "模型 " .. req.model end
    if req.provider then parts[#parts + 1] = "提供商 " .. req.provider end
    if body then
      if body.stream ~= nil then parts[#parts + 1] = "流式 " .. tostring(body.stream) end
      if body.temperature ~= nil then parts[#parts + 1] = "温度 " .. tostring(body.temperature) end
      if body.max_tokens then parts[#parts + 1] = "max_tokens " .. tostring(body.max_tokens) end
      if body.messages then parts[#parts + 1] = "消息 " .. #body.messages .. " 条" end
      if body.tools then parts[#parts + 1] = "工具 " .. #body.tools .. " 个" end
    end
    if #parts > 0 then
      lines[#lines + 1] = "    ⚙ 请求参数: " .. table.concat(parts, " · ")
    end
  end

  -- 原始请求体（实际 POST 给 API 的完整 payload，层级 3 子块）
  if req and req.body then
    lines[#lines + 1] = "    ▸ 原始请求体"
    local encoded = helpers.pretty_json(req.body)
    if not full then encoded = helpers.truncate(encoded, MAX_REQUEST_BODY_CHARS) end
    for _, l in ipairs(helpers.split_lines(encoded)) do
      lines[#lines + 1] = "      " .. l
    end
  end

  -- 原始响应（层级 3 子块）
  if resp then
    lines[#lines + 1] = "    ▸ 原始响应"
    if resp.finish_reason then
      lines[#lines + 1] = "      finish_reason: " .. tostring(resp.finish_reason)
    end
    if resp.usage then
      local u = resp.usage
      local uparts = {}
      if u.prompt_tokens then uparts[#uparts + 1] = "prompt " .. u.prompt_tokens end
      if u.completion_tokens then uparts[#uparts + 1] = "completion " .. u.completion_tokens end
      if u.prompt_cache_hit_tokens then uparts[#uparts + 1] = "缓存读 " .. u.prompt_cache_hit_tokens end
      if u.prompt_cache_miss_tokens then uparts[#uparts + 1] = "缓存未命中 " .. u.prompt_cache_miss_tokens end
      if #uparts > 0 then lines[#lines + 1] = "      用量: " .. table.concat(uparts, " · ") end
    end
    local time_parts = {}
    if resp.total_ms then time_parts[#time_parts + 1] = "总耗时 " .. fold.format_ms(resp.total_ms) end
    if resp.ttft_ms then time_parts[#time_parts + 1] = "首token " .. fold.format_ms(resp.ttft_ms) end
    if resp.status then time_parts[#time_parts + 1] = "状态 " .. resp.status end
    if #time_parts > 0 then lines[#lines + 1] = "      " .. table.concat(time_parts, " · ") end

    -- 原始响应分片（SSE wire 数据，作为原始响应的内容，不单独成折叠）
    if resp.raw_chunks and #resp.raw_chunks > 0 then
      local chunks = resp.raw_chunks
      local total_chars, truncated = 0, false
      local shown = {}
      for _, c in ipairs(chunks) do
        if not full and total_chars + #c > MAX_RAW_CHUNKS_CHARS then
          truncated = true
          break
        end
        shown[#shown + 1] = c
        total_chars = total_chars + #c
      end
      lines[#lines + 1] = string.format("      📦 原始响应分片（SSE）· %d 片%s",
        #chunks, (resp.raw_truncated or truncated) and "（已截断）" or "")
      for _, c in ipairs(shown) do
        for _, l in ipairs(helpers.split_lines(c)) do
          lines[#lines + 1] = "        " .. l
        end
      end
    end
  end
end

--- 追加一个 turn 折叠块（层级 1）：
--- - 层级 2 小节：▸ 用户请求、▸ 请求 #N；
--- - 层级 3 子块：推理、工具调用、原始请求体、原始响应。
--- @param lines table
--- @param marks table 与 lines 并行的元数据数组
--- @param turn table
--- @param full boolean|nil true=保存日志：不截断 wire 数据
local function _append_turn(lines, marks, turn, full)
  lines[#lines + 1] = _header(turn)
  if turn.user then
    lines[#lines + 1] = "  ▸ 用户请求"
    if turn.user.content and turn.user.content ~= "" then
      _append_raw(lines, turn.user.content, 2)
    end
  end
  local message_list = require("NeoAI.ui.components.message_list")
  local entries = turn.entries
  local i, req_seq = 1, 0
  while i <= #entries do
    local msg = entries[i]
    if msg.role == "assistant" then
      req_seq = req_seq + 1
      lines[#lines + 1] = "  ▸ 请求 #" .. req_seq .. " · ASSISTANT"
      if message_list.is_show_reasoning() and msg.reasoning and msg.reasoning ~= "" then
        lines[#lines + 1] = "    ▸ 推理"
        _append_raw(lines, msg.reasoning, 3)
      end
      if msg.content and msg.content ~= "" then
        _append_raw(lines, msg.content, 2)
      end
      if msg.tool_calls and #msg.tool_calls > 0 then
        local ridx = i + 1
        for _, tc in ipairs(msg.tool_calls) do
          local result_msg = nil
          if entries[ridx] and entries[ridx].role == "tool" then
            result_msg = entries[ridx]
            ridx = ridx + 1
          end
          _append_tool_sub(lines, marks, tc, result_msg)
        end
        i = ridx
      else
        i = i + 1
      end
      -- wire 级细节：请求参数 + 原始请求体 + 原始响应（层级 3 子块）
      _append_request_meta(lines, msg, full)
    else
      i = i + 1
    end
  end
end

--- 把消息序列分组为 turns（系统提示词块 + 用户 turn）
--- 用户 turn 从 1 开始独立编号；系统提示词块 index 固定为 0（不占 turn 序号）。
--- @param messages table
--- @return table 数组
local function _group_turns(messages)
  local turns = {}
  local cur = nil
  local user_seq = 0
  for _, msg in ipairs(messages or {}) do
    if msg.role == "system" then
      if not cur then
        cur = { kind = "system", index = 0, sys_msgs = {} }
        turns[#turns + 1] = cur
      end
      if cur.kind == "system" then
        cur.sys_msgs[#cur.sys_msgs + 1] = msg
      end
    elseif msg.role == "user" then
      user_seq = user_seq + 1
      cur = { kind = "user", index = user_seq, user = msg, entries = {} }
      turns[#turns + 1] = cur
    else
      if not cur or cur.kind ~= "user" then
        user_seq = user_seq + 1
        cur = { kind = "user", index = user_seq, user = nil, entries = {} }
        turns[#turns + 1] = cur
      end
      cur.entries[#cur.entries + 1] = msg
    end
  end
  return turns
end

--- 生成轨迹视图的全部行（全量；供 build_lines / build_log / 测试使用）
--- @param messages table
--- @param opts table|nil { full? } full=true 时不截断原始请求体/响应分片（供保存日志）
--- @return table 行数组
--- @return table 与行并行的元数据数组（密钥高亮等）
local function _build_lines(messages, opts)
  opts = opts or {}
  local lines, marks = {}, {}
  local turns = _group_turns(messages)
  if #turns == 0 then
    return { "NeoAI 聊天（轨迹模式）", "", "输入消息开始对话。", "" }, {}
  end
  for _, turn in ipairs(turns) do
    if turn.kind == "system" then
      _append_system(lines, turn)
    else
      _append_turn(lines, marks, turn, opts.full)
    end
  end
  return lines, marks
end

--- 文本指纹（见 incremental.fingerprint）
--- @param s string|nil
--- @return string
local function _fingerprint(s)
  return incremental.fingerprint(s)
end

--- 请求元数据签名（覆盖请求参数与原始请求体）
--- @param req table|nil
--- @return string
local function _req_sig(req)
  if not req then return "nil" end
  local helpers = require("NeoAI.ui.components.message_list").helpers
  local body_fp = "nil"
  if req.body then
    local ok, enc = pcall(helpers.pretty_json, req.body)
    body_fp = _fingerprint(ok and enc or tostring(req.body))
  end
  return table.concat({ tostring(req.model), tostring(req.provider), body_fp }, ",")
end

--- 响应元数据签名（覆盖 finish_reason / 用量 / 耗时 / SSE 分片）
--- @param resp table|nil
--- @return string
local function _resp_sig(resp)
  if not resp then return "nil" end
  local p = {
    tostring(resp.finish_reason), tostring(resp.ttft_ms), tostring(resp.total_ms),
    tostring(resp.status), tostring(resp.raw_truncated),
  }
  local u = resp.usage
  if u then
    for _, k in ipairs({ "prompt_tokens", "completion_tokens", "prompt_cache_hit_tokens", "prompt_cache_miss_tokens" }) do
      p[#p + 1] = tostring(u[k])
    end
  end
  local ch = resp.raw_chunks
  if ch then
    p[#p + 1] = "#" .. #ch
    p[#p + 1] = _fingerprint(table.concat(ch))
  end
  return table.concat(p, ",")
end

--- 单个 turn 的渲染签名：覆盖该 turn 全部渲染输入（用户内容、各条 entry 的
--- 角色/正文/推理/工具调用/耗时、请求与响应元数据、推理开关与 full 标志）。
--- @param turn table
--- @param full boolean|nil
--- @return string
local function _turn_sig(turn, full)
  local message_list = require("NeoAI.ui.components.message_list")
  local fold = require("NeoAI.ui.components.fold")
  local p = {
    tostring(turn.kind), tostring(turn.index), full and "F" or "-",
    message_list.is_show_reasoning() and "R" or "-",
  }
  if turn.kind == "system" then
    for _, m in ipairs(turn.sys_msgs or {}) do
      p[#p + 1] = _fingerprint(m.content)
    end
    return table.concat(p, "\1")
  end
  if turn.user then
    p[#p + 1] = _fingerprint(turn.user.content)
  end
  for _, m in ipairs(turn.entries or {}) do
    p[#p + 1] = tostring(m.role)
    p[#p + 1] = _fingerprint(m.content)
    p[#p + 1] = _fingerprint(m.reasoning)
    p[#p + 1] = tostring(m.duration_ms)
    for _, tc in ipairs(m.tool_calls or {}) do
      local fn = tc["function"] or {}
      p[#p + 1] = "tc"
      p[#p + 1] = tostring(tc.id)
      p[#p + 1] = tostring(fn.name)
      p[#p + 1] = _fingerprint(fn.arguments)
      p[#p + 1] = tostring(fold.get_status(tc.id))
      p[#p + 1] = tostring(fold.get_duration(tc.id))
    end
    p[#p + 1] = _req_sig(m.request)
    p[#p + 1] = _resp_sig(m.response)
  end
  return table.concat(p, "\1")
end

--- 把消息分组为可缓存的渲染块（系统提示词块 + 每个 turn 一块）
--- @param messages table
--- @param full boolean|nil
--- @return table 块数组 { { key, sig, build } }
local function _render_blocks(messages, full)
  local blocks = {}
  for _, turn in ipairs(_group_turns(messages)) do
    local snap = turn
    local sig = _turn_sig(snap, full)
    blocks[#blocks + 1] = {
      key = "t:" .. tostring(snap.index) .. ":" .. tostring(snap.kind),
      sig = sig,
      build = function()
        local lines, marks = {}, {}
        if snap.kind == "system" then
          _append_system(lines, snap)
        else
          _append_turn(lines, marks, snap, full)
        end
        return { lines = lines, marks = marks }
      end,
    }
  end
  return blocks
end

--- 逐行计算折叠等级（多级：turn=1、小节=2、子块=3）。
--- - ⏷ 头行（0 缩进）→ 强制开启层级 1 折叠；
--- - ▸ 头行 → 按缩进开启对应层级折叠（2 格=2 级，4 格=3 级）；
--- - 其余缩进内容 → 等级 = 缩进深度（封顶 3，深层内容不产生多余折叠）；
--- - 空白行 → 并入相邻折叠（沿用上一行等级）。
--- @return string|number
local function _foldexpr()
  local ln = vim.v.lnum
  local text = vim.fn.getline(ln)
  local t = text:gsub("^%s+", "")
  -- turn 头行：开启层级 1 折叠
  if t:find("⏷", 1, true) == 1 then
    return ">1"
  end
  -- 空白行：并入相邻折叠
  if text:match("^%s*$") then
    local prev = vim.fn.getline(ln - 1)
    if prev:match("^%s+%S") then
      return "="
    end
    return "0"
  end
  -- 缩进行
  local indent = #(text:match("^(%s*)%S") or "")
  -- ▸ 小节/子块头行：开启新折叠，等级 = 缩进深度 + 1（2 格 → 2 级，4 格 → 3 级）
  -- 注：▸/⏷ 为多字节 UTF-8 字符，须用 find（sub(1,1) 只取 1 字节导致比较失败）
  if t:find("▸", 1, true) == 1 then
    return ">" .. (math.floor(indent / 2) + 1)
  end
  -- 普通缩进内容：等级 = 缩进深度，封顶 3
  return tostring(math.min(math.floor(indent / 2), 3))
end

--- 折叠文本：直接返回折叠首行（即 ⏷ turn 头 / ▸ 小节/子块头）
--- @return string
local function _foldtext()
  return vim.fn.getline(vim.v.foldstart) or ""
end

-- ========== 插件生命周期 ==========

--- 激活：安装轨迹折叠行为。重渲染由管理器统一触发。
--- @param host table|nil 宿主 API
function M.load(host)
  if host then
    host.set_foldexpr(_foldexpr)
    host.set_foldtext(_foldtext)
  end
end

--- 停用：还原默认折叠行为
--- @param host table|nil 宿主 API
function M.unload(host)
  if host then
    host.set_foldexpr(nil)
    host.set_foldtext(nil)
  end
end

--- 渲染消息到 buffer（增量：按 turn 块缓存 + 差分写入）
--- @param buf number
--- @param messages table
--- @return table 增量写入结果 { changed, start, removed, inserted, full }
function M.render(buf, messages)
  local cache = incremental.cache_for(buf)
  local lines = cache:render(_render_blocks(messages, nil))
  if #lines == 0 then
    -- 空对话占位（与全量渲染一致）
    lines = { "NeoAI 聊天（轨迹模式）", "", "输入消息开始对话。", "" }
    cache.new_lines = lines
    cache.new_marks = {}
  end
  local diff = cache:write(buf)
  vim.bo[buf].modifiable = true
  -- 行内密钥高亮：仅对本次实际写入的行重贴（含密钥的工具调用参数/结果完整展示）。
  if diff.changed then
    local helpers = require("NeoAI.ui.components.message_list").helpers
    local from, to = incremental.written_range(diff)
    if from > 0 then
      helpers.apply_secret_hl(buf, cache.marks, 1, from, to)
    end
  end
  return diff
end

--- 文本构建（测试用，无 buffer 副作用）
--- @param messages table
--- @return table 行数组
function M.build_lines(messages)
  local lines = _build_lines(messages)
  return lines
end

-- ========== 日志保存 ==========

--- 构建完整轨迹日志行（full=true：不截断原始请求体 / 原始 SSE 分片）
--- @param messages table
--- @return table 行数组
function M.build_log(messages)
  local lines = _build_lines(messages, { full = true })
  return lines
end

--- 生成文件头（保存时间 / 会话信息）
--- @param messages table|nil
--- @return table
local function _log_header(messages)
  local lines = { "# NeoAI 轨迹日志", "# 保存时间: " .. os.date("%Y-%m-%d %H:%M:%S") }
  if messages and #messages > 0 then
    lines[#lines + 1] = "# 消息数: " .. #messages
  end
  lines[#lines + 1] = ""
  return lines
end

--- 解析保存目录（缺省 ui.trajectory.log_dir，未配置回退 ~/.cache/nvim/NeoAI/logs）
--- @param opts table { dir? }
--- @return string dir
local function _resolve_dir(opts)
  local config_store = require("NeoAI.kernel.config_store")
  local fs = require("NeoAI.utils.fs")
  local dir = opts.dir or config_store.get("ui.trajectory.log_dir")
  dir = fs.expand(dir or "")
  if dir == "" then
    dir = vim.fn.stdpath("cache") .. "/NeoAI/logs"
  end
  fs.ensure_dir(dir)
  return dir
end

--- 计算文件名（补 .log 后缀；缺省按时间戳）
--- @param opts table { filename? }
--- @return string
local function _resolve_filename(opts)
  local filename = opts.filename or ("neoai-trajectory-" .. os.date("%Y%m%d-%H%M%S") .. ".log")
  if filename:sub(-4) ~= ".log" then filename = filename .. ".log" end
  return filename
end

--- 生成完整日志内容（文件头 + 不截断的轨迹正文）
--- @param messages table
--- @return string
local function _log_content(messages)
  local body = table.concat(M.build_log(messages or {}), "\n") .. "\n"
  local header = table.concat(_log_header(messages), "\n") .. "\n"
  return header .. body
end

--- 把轨迹日志保存成文件到指定目录（缺省 ui.trajectory.log_dir，默认 ~/.cache/nvim/NeoAI/logs）。
--- 同步写入，返回路径。写入的是完整 wire 数据（不截断请求体与响应分片）。
--- @param messages table
--- @param opts table|nil { dir? 自定义保存目录; filename? 自定义文件名（缺省按时间戳） }
--- @return string|nil 文件路径；失败时返回 nil（内部已 vim.notify 报错）
function M.save_log(messages, opts)
  opts = opts or {}
  local fs = require("NeoAI.utils.fs")
  local path = fs.join(_resolve_dir(opts), _resolve_filename(opts))
  local w_ok, w_err = fs.write_file(path, _log_content(messages))
  if not w_ok then
    vim.notify("[NeoAI] 写入轨迹日志失败: " .. tostring(w_err), vim.log.levels.ERROR)
    return nil
  end
  return path
end

--- 异步写入轨迹日志（线程池，不阻塞主线程）。给 vim 保存事件钩子用，避免每次 :w 卡顿。
--- @param messages table
--- @param opts table|nil { dir?; filename? }
--- @return Deferred resolve(文件路径 string)；失败会 notify 并 reject
function M.save_log_async(messages, opts)
  opts = opts or {}
  local fs = require("NeoAI.utils.fs")
  local path = fs.join(_resolve_dir(opts), _resolve_filename(opts))
  return fs.write_file_async(path, _log_content(messages)):then_(function()
    return path
  end, function(err)
    local msg = tostring(err and err.message or err)
    vim.notify("[NeoAI] 写入轨迹日志失败: " .. msg, vim.log.levels.ERROR)
    return nil
  end)
end

-- ========== vim 原生保存事件钩子 ==========

--- 把 agent id 规范化成安全文件名（供会话稳定文件名使用）
--- @param id string
--- @return string
local function _safe_name(id)
  local s = tostring(id or ""):gsub("[^%w%-_]", "_")
  if s == "" then s = "default" end
  return s
end

--- 已挂钩的 buffer 集合（buf -> true），保证每个 buffer 只挂一次
local hooked_bufs = {}

--- 上次成功保存的目录（作为下次弹窗默认值；缺省取配置 log_dir）
local last_save_dir = nil

--- 会话日志文件的稳定名（按 session_id 派生；缺省用默认名）
--- @return string
function M.log_filename()
  local ok, chat_service = pcall(require, "NeoAI.services.chat_service")
  if not ok then return "neoai-trajectory.log" end
  local session_id = chat_service.get_current_session_id()
  if session_id then
    return "neoai-trajectory-" .. _safe_name(session_id) .. ".log"
  end
  return "neoai-trajectory.log"
end

--- 默认保存目录（配置 log_dir，未配置回退 ~/.cache/nvim/NeoAI/logs）
--- @return string
local function _default_dir()
  local config_store = require("NeoAI.kernel.config_store")
  local fs = require("NeoAI.utils.fs")
  return fs.expand(config_store.get("ui.trajectory.log_dir") or vim.fn.stdpath("cache") .. "/NeoAI/logs")
end

--- 依据弹窗输入路径写入轨迹日志。
--- 规则：以 `.log` 结尾 → 视为完整文件路径；否则视为目录，自动加会话文件名。
--- target 为空 → 落盘到默认目录。
--- @param messages table
--- @param target string|nil 用户输入的路径
--- @param silent boolean
--- @return string|nil 保存路径
local function _save_by_input(messages, target, silent)
  local fs = require("NeoAI.utils.fs")
  target = (target or ""):match("^%s*(.-)%s*$")
  local dir, filename
  if target == "" then
    dir = _default_dir()
    filename = M.log_filename()
  elseif target:match("%.log$") then
    dir = fs.dirname(fs.expand(target))
    filename = fs.basename(fs.expand(target))
  else
    dir = fs.expand(target)
    filename = M.log_filename()
  end
  local path = M.save_log(messages, { dir = dir, filename = filename })
  if path then
    last_save_dir = fs.dirname(path)
    if not silent then
      vim.notify("[NeoAI] 轨迹日志已保存: " .. path, vim.log.levels.INFO)
    end
  end
  return path
end

-- ========== 路径输入浮窗 ==========

local dlg = { win = nil, buf = nil, on_confirm = nil, on_cancel = nil, prompt_ns = nil, guard_aucmd = nil }

-- 输入行在 buffer 中的行号（1-based）：第 1 行为不可编辑的提示（virt_text），第 2 行为可编辑的输入
local INPUT_LINE = 2

--- 关闭路径浮窗（不触发回调，仅清理）
local function _dlg_close()
  if dlg.win and vim.api.nvim_win_is_valid(dlg.win) then
    pcall(vim.api.nvim_win_close, dlg.win, true)
  end
  if dlg.guard_aucmd then
    pcall(vim.api.nvim_del_autocmd, dlg.guard_aucmd)
  end
  dlg.guard_aucmd = nil
  dlg.prompt_ns = nil
  dlg.win = nil
  dlg.buf = nil
  dlg.on_confirm = nil
  dlg.on_cancel = nil
end

--- 读取浮窗输入行（第 2 行）的值
--- @return string
local function _dlg_value()
  if dlg.buf and vim.api.nvim_buf_is_valid(dlg.buf) then
    local l = vim.api.nvim_buf_get_lines(dlg.buf, INPUT_LINE - 1, INPUT_LINE, false)
    return (l[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
  end
  return ""
end

--- 确认提交（Enter 或测试调用）：以给定值（缺省取输入行）保存
--- @param value string|nil
function M._path_confirm(value)
  local cb = dlg.on_confirm
  if type(value) ~= "string" then value = _dlg_value() end
  _dlg_close()
  if cb then cb(value) end
end

--- 取消（Esc 或测试调用）：不保存
function M._path_cancel()
  local cb = dlg.on_cancel
  _dlg_close()
  if cb then cb() end
end

--- 浮窗键位：回车确认，Esc 取消
local function _dlg_set_keymaps()
  if not dlg.buf then return end
  -- 回车确认（插入 + 普通模式）
  vim.keymap.set({ "i", "n" }, "<CR>", function() M._path_confirm(_dlg_value()) end, { buffer = dlg.buf, desc = "确认保存路径" })
  -- Esc：插入模式先退回普通模式（支持 normal 下用 vim 编辑），普通模式下再按 Esc 才取消
  vim.keymap.set("i", "<Esc>", function() vim.cmd("stopinsert") end, { buffer = dlg.buf, desc = "退出插入（普通模式）" })
  vim.keymap.set("n", "<Esc>", function() M._path_cancel() end, { buffer = dlg.buf, desc = "取消保存" })
  -- 普通模式回到插入：i 光标前插入 / a 行尾追加
  vim.keymap.set("n", "i", function() vim.api.nvim_feedkeys("i", "n", false) end, { buffer = dlg.buf, desc = "进入插入" })
  vim.keymap.set("n", "a", function() vim.api.nvim_feedkeys("A", "n", false) end, { buffer = dlg.buf, desc = "进入插入（追加）" })
end

--- 弹出「设置日志保存路径」浮窗，光标自动落入输入行（插入模式）
--- @param default string 默认路径
--- @param on_confirm function(value) 确认时回调
--- @param on_cancel function() 取消时回调
local function _open_path_dialog(default, on_confirm, on_cancel)
  if dlg.win and vim.api.nvim_win_is_valid(dlg.win) then _dlg_close() end
  dlg.on_confirm = on_confirm
  dlg.on_cancel = on_cancel
  dlg.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[dlg.buf].filetype = "neoai_traj_path"
  -- nofile：纯飘窗暂存，用户可编辑输入行，但退出/切走不会触发 E37/E162
  vim.bo[dlg.buf].buftype = "nofile"
  vim.bo[dlg.buf].modifiable = true
  vim.bo[dlg.buf].bufhidden = "wipe"
  vim.bo[dlg.buf].swapfile = false
  local height = 3
  local width = math.min(90, vim.o.columns - 6)
  -- 第 1 行放不可编辑的提示文本（virt_text，不进入 buffer 内容）；第 2 行是可编辑的输入。
  vim.api.nvim_buf_set_lines(dlg.buf, 0, -1, false, { "", default })
  dlg.prompt_ns = vim.api.nvim_create_namespace("neoai_traj_prompt")
  vim.api.nvim_buf_set_extmark(dlg.buf, dlg.prompt_ns, 0, 0, {
    virt_text = { { "保存轨迹日志到路径（回车确认，Esc 取消）: ", "Comment" } },
    virt_text_pos = "inline",
  })
  local ok, wid = pcall(vim.api.nvim_open_win, dlg.buf, false, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = "💾 NeoAI 保存轨迹日志",
    title_pos = "center",
  })
  if not ok then
    dlg.buf = nil
    dlg.on_confirm, dlg.on_cancel = nil, nil
    vim.notify("[NeoAI] 无法打开保存路径弹窗: " .. tostring(wid), vim.log.levels.ERROR)
    return
  end
  dlg.win = wid
  vim.wo[dlg.win].wrap = true
  vim.wo[dlg.win].foldenable = false
  _dlg_set_keymaps()
  -- 锁定输入行为第 2 行：光标/编辑被吸附到该行，提示行（第 1 行）不可被修改
  dlg.guard_aucmd = vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter" }, {
    buffer = dlg.buf,
    callback = function()
      if not dlg.win or not vim.api.nvim_win_is_valid(dlg.win) then return end
      local cur = vim.api.nvim_win_get_cursor(dlg.win)
      if cur[1] ~= INPUT_LINE then
        local input = vim.api.nvim_buf_get_lines(dlg.buf, INPUT_LINE - 1, INPUT_LINE, false)
        pcall(vim.api.nvim_win_set_cursor, dlg.win, { INPUT_LINE, #(input[1] or "") })
      end
    end,
  })
  -- 焦点与光标必须在 :w 写命令彻底返回后再落到弹窗（否则写命令结束会还原焦点到原窗口）。
  -- 用 schedule 延后到下一 tick：此时写命令已完成，set_current_win 才真正生效。
  -- 默认进入普通模式（光标落在输入行第 2 行），按 i/a 进入插入编辑，回车确认，Esc 取消。
  local input_len = #(default or "")
  vim.schedule(function()
    if not dlg.win or not vim.api.nvim_win_is_valid(dlg.win) then return end
    pcall(vim.api.nvim_win_set_cursor, dlg.win, { INPUT_LINE, input_len })
    vim.api.nvim_set_current_win(dlg.win)
  end)
end

--- 安装「vim 原生保存事件」钩子：把指定 buffer 切为 acwrite 并挂 BufWriteCmd。
--- 仅在轨迹模式激活时调用（chat_view 依显示模式同步）。:w 时弹窗让用户设置日志路径。
--- acwrite 的非 ''/help buftype 仍能跳过 native LSP 自动启用（与 nofile 等效），仅由 BufWriteCmd 接管保存。
--- 幂等：同一 buffer 重复调用无副作用。
--- @param buf number
--- @param opts table|nil { silent? } 缺省 false（notify 保存成功）；true=静默
--- @return boolean 是否已安装
function M.install_save_hook(buf, opts)
  opts = opts or {}
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  if hooked_bufs[buf] then return true end
  hooked_bufs[buf] = true
  local silent = opts.silent == true
  pcall(vim.api.nvim_set_option_value, "buftype", "acwrite", { buf = buf })
  if vim.api.nvim_buf_get_name(buf) == "" then
    pcall(vim.api.nvim_buf_set_name, buf, "NeoAI-" .. tostring(buf))
  end
  local augroup = "NeoAISaveTrajectory" .. buf
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = vim.api.nvim_create_augroup(augroup, { clear = true }),
    buffer = buf,
    callback = function()
      local ok, chat_service = pcall(require, "NeoAI.services.chat_service")
      if ok then
        local agent = chat_service.get_current_agent()
        if agent and agent.messages and #agent.messages > 0 then
          local messages = agent.messages
          -- 默认位置 = 目录 + 会话文件名（完整路径），用户可改
          local fs = require("NeoAI.utils.fs")
          local default = fs.join(last_save_dir or _default_dir(), M.log_filename())
          _open_path_dialog(default, function(value)
            _save_by_input(messages, value, silent)
          end, function()
            -- 取消（Esc）：不保存
          end)
        end
      end
      -- 清掉修改标志：保存由弹窗流程接管（无真实文件），否则 vim 会认为未保存
      vim.bo[buf].modified = false
    end,
  })
  return true
end

--- 移除保存事件钩子：删除 BufWriteCmd，并把 buffer 恢复为 nofile（非轨迹模式下 :w 报原生 E382）。
--- @param buf number|nil 缺省移除全部
function M.remove_save_hook(buf)
  local function _disable(b)
    pcall(vim.api.nvim_set_option_value, "buftype", "nofile", { buf = b })
  end
  if buf then
    pcall(vim.api.nvim_del_augroup_by_name, "NeoAISaveTrajectory" .. buf)
    hooked_bufs[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then _disable(buf) end
    return
  end
  for b in pairs(hooked_bufs) do
    pcall(vim.api.nvim_del_augroup_by_name, "NeoAISaveTrajectory" .. b)
    if vim.api.nvim_buf_is_valid(b) then _disable(b) end
  end
  hooked_bufs = {}
end

--- 旧名兼容（测试/外部曾用）
function M.uninstall_save_hook(...)
  M.remove_save_hook(...)
end

manager.register(M)

return M