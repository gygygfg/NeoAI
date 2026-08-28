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
--- @param tool_call table
--- @param result_msg table|nil 对应工具结果消息
local function _append_tool_sub(lines, tool_call, result_msg)
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
  lines[#lines + 1] = "    ▸ 工具调用: " .. name .. " " .. status_emoji .. time_str
  local arg_lines = helpers.tool_arguments_lines(fn)
  if arg_lines then
    lines[#lines + 1] = "      参数:"
    for _, l in ipairs(arg_lines) do
      lines[#lines + 1] = "        " .. l
    end
  end
  if result_msg then
    lines[#lines + 1] = "      结果:"
    for _, l in ipairs(helpers.result_lines(result_msg.content)) do
      lines[#lines + 1] = "        " .. l
    end
  end
end

--- 追加单个请求的 wire 级细节（层级 3 子块）：请求参数 / 原始请求体 / 原始响应。
--- 数据来自 agent 在每次请求后附加到 assistant 消息的 request/response 元数据；
--- 无元数据（如历史会话）时跳过，不影响基本展示。
--- @param lines table
--- @param msg table assistant 消息
local function _append_request_meta(lines, msg)
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
    for _, l in ipairs(helpers.split_lines(helpers.truncate(encoded, MAX_REQUEST_BODY_CHARS))) do
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
        if total_chars + #c > MAX_RAW_CHUNKS_CHARS then
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
--- @param turn table
local function _append_turn(lines, turn)
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
          _append_tool_sub(lines, tc, result_msg)
        end
        i = ridx
      else
        i = i + 1
      end
      -- wire 级细节：请求参数 + 原始请求体 + 原始响应（层级 3 子块）
      _append_request_meta(lines, msg)
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

--- 生成轨迹视图的全部行
--- @param messages table
--- @return table
local function _build_lines(messages)
  local lines = {}
  local turns = _group_turns(messages)
  if #turns == 0 then
    return { "NeoAI 聊天（轨迹模式）", "", "输入消息开始对话。", "" }
  end
  for _, turn in ipairs(turns) do
    if turn.kind == "system" then
      _append_system(lines, turn)
    else
      _append_turn(lines, turn)
    end
  end
  return lines
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

--- 渲染消息到 buffer
--- @param buf number
--- @param messages table
function M.render(buf, messages)
  local lines = _build_lines(messages)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = true
end

--- 文本构建（测试用，无 buffer 副作用）
--- @param messages table
--- @return table 行数组
function M.build_lines(messages)
  return _build_lines(messages)
end

manager.register(M)

return M