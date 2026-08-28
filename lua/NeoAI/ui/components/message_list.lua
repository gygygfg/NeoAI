--- 消息列表渲染
--- @module NeoAI.ui.components.message_list
--- 将 Agent 消息渲染到 buffer。支持流式更新、推理折叠、工具结果展示。

local markdown_view = require("NeoAI.ui.components.markdown_view")
local stringx = require("NeoAI.utils.stringx")
local fold = require("NeoAI.ui.components.fold")
local config_store = require("NeoAI.kernel.config_store")
local json = require("NeoAI.utils.json")
local display_modes = require("NeoAI.ui.components.display_modes")

local M = {}

-- ========== 私有常量 ==========

local ROLE_LABELS = {
  user = "👤 用户",
  assistant = "🤖 AI",
  system = "⚙️ 系统",
  tool = "🔧 工具",
}

-- ========== 私有状态 ==========

local state = {
  show_reasoning = true,
}

-- ========== 私有函数 ==========

--- 将文本拆分为不含换行符的行数组（统一 \r\n/\r，避免 nvim_buf_set_lines 报错）
--- @param text string|nil
--- @return table 行数组
local function _split_lines(text)
  text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(text, "\n", { plain = true })
end

--- 追加一个可折叠块（推理 / 单个工具块）。所有行缩进 2 格，由聊天窗口的
--- expr 折叠（components.fold.foldexpr）把每块独立成折叠，块与块之间无需分隔行。
--- 空行保留为空白分隔（expr 折叠会把紧邻缩进内容的空行并入折叠）。
--- @param lines table
--- @param rows table 块内文本行（单行纯文本，不含换行）
local function _append_fold_block(lines, rows)
  if not rows or #rows == 0 then return end
  for _, l in ipairs(rows) do
    if l == "" then
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = "  " .. l
    end
  end
end

--- 判断消息是否为轮次边界（其后应绘制分割线）。
--- 一轮 = 从用户消息开始，到下一个用户消息（或消息列表末尾）结束。
--- 轮内（推理/工具调用/工具结果与正文之间）一律不画分割线，只保留轮间分割。
--- @param messages table
--- @param i number 当前消息下标
--- @return boolean
local function _is_turn_end(messages, i)
  local msg = messages[i]
  if msg.role == "user" then
    return true -- 用户消息始终后接分割线（与 AI 回复的视觉分隔）
  end
  if msg.role ~= "assistant" then
    return false -- 工具结果不带分割线（与所属 AI 轮保持连续）
  end
  -- assistant：仅当它是本轮的可见最后一条（后面是下一条用户消息或列表末尾）时画分割线
  for j = i + 1, #messages do
    if messages[j].role ~= "system" then
      return messages[j].role == "user"
    end
  end
  return true
end

--- 追加角色头（非工具消息）
--- @param lines table
--- @param message table
local function _append_role_header(lines, message)
  local label = ROLE_LABELS[message.role] or message.role
  lines[#lines + 1] = label
end

--- 追加推理折叠块（缩进 2 格，由聊天窗口 expr 折叠自动收起）
--- @param lines table
--- @param message table
local function _append_reasoning(lines, message)
  local has_reasoning = message.reasoning ~= nil and message.reasoning ~= "" and state.show_reasoning
  if not has_reasoning then return end
  local rl = markdown_view.render(message.reasoning)
  local rows = {}
  for _, l in ipairs(rl) do
    rows[#rows + 1] = l.text
  end
  _append_fold_block(lines, rows)
end

--- 追加正文内容（markdown 渲染）——工具消息除外
--- @param lines table
--- @param message table
local function _append_content(lines, message)
  if message.role == "tool" or not message.content or message.content == "" then return end
  local rendered = markdown_view.render(message.content)
  for _, l in ipairs(rendered) do
    if l.text ~= "" then
      lines[#lines + 1] = l.text
    end
  end
end

--- 工具结果是否为失败（错误 JSON 对象含 error 字段）
--- 工具结果可能是任意 JSON（布尔/字符串/数字/数组），只有对象含 error 字段才算失败，
--- 非对象（如 is_named_node 返回的 true/false）一律视为成功。
--- @param content string|nil
--- @return boolean
local function _tool_result_failed(content)
  if not content or content == "" then return false end
  local json = require("NeoAI.utils.json")
  local decoded = json.decode_or_nil(content)
  if type(decoded) ~= "table" then return false end
  return decoded.error ~= nil
end

--- 提取工具调用的目的说明（description 参数）
--- @param fn table tool_call["function"]
--- @return string|nil
local function _tool_description(fn)
  if not fn or type(fn.arguments) ~= "string" or fn.arguments == "" then return nil end
  local json = require("NeoAI.utils.json")
  local decoded = json.decode_or_nil(fn.arguments)
  if type(decoded) ~= "table" then return nil end
  local desc = decoded.description
  if type(desc) ~= "string" or desc == "" then return nil end
  -- 折叠文本单行展示：折行/换行压缩为空格
  desc = desc:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if desc == "" then return nil end
  return desc
end

--- 递归将 JSON 值格式化为带缩进的多行文本（数组/对象均结构化展示）。
--- @param value any
--- @param indent number
--- @return string
local function _pretty_json(value, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  if type(value) ~= "table" then
    return json.encode(value)
  end
  if not next(value) then return "{}" end
  -- 数组判断：键为 1..n 的连续整数序列（#value > 0 才可能是数组，避免把字符串键对象误判）
  local is_array = #value > 0
  if is_array then
    for i = 1, #value do
      if value[i] == nil then is_array = false break end
    end
  end
  if is_array then
    local parts = {}
    for i = 1, #value do
      parts[i] = pad .. "  " .. _pretty_json(value[i], indent + 1)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  end
  local parts = {}
  local n = 0
  for k, v in pairs(value) do
    n = n + 1
    parts[n] = pad .. "  " .. json.encode(k) .. ": " .. _pretty_json(v, indent + 1)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

--- 工具调用参数的结构化展示行（解析 JSON，剔除 description 样板字段后缩进展示）。
--- @param fn table tool_call["function"]
--- @return table|nil 行数组（无参数时 nil）
local function _tool_arguments_lines(fn)
  if not fn or type(fn.arguments) ~= "string" or fn.arguments == "" then return nil end
  local decoded = json.decode_or_nil(fn.arguments)
  if decoded == nil then return { fn.arguments } end
  if type(decoded) == "table" then
    local filtered = {}
    for k, v in pairs(decoded) do
      if k ~= "description" then filtered[k] = v end
    end
    if not next(filtered) then return nil end
    return _split_lines(stringx.truncate(_pretty_json(filtered), 500))
  end
  return { json.encode(decoded) }
end

--- 工具结果的结构化展示行（JSON 内容解析后多行缩进展示，非 JSON 原样截断展示）。
--- 结果含 read_image 的图像引用时先行渲染一条图像摘要行。
--- @param content string|nil
--- @return table 行数组
local function _result_lines(content)
  if not content or content == "" then return { "(空)" } end
  local decoded = json.decode_or_nil(content)
  if type(decoded) == "table" then
    local img = decoded.image
    if type(img) == "table" and img.attachmentId then
      local dims = img.width and img.height and (string.format(" %dx%dpx", img.width, img.height)) or ""
      local lines = {
        string.format("🖼️ 图像%s（%s, %d 字节）", dims, img.mediaType or img.media_type or "image", img.bytes or 0),
      }
      local json_lines = _split_lines(stringx.truncate(_pretty_json(decoded), 500))
      for _, l in ipairs(json_lines) do
        lines[#lines + 1] = l
      end
      return lines
    end
    return _split_lines(stringx.truncate(_pretty_json(decoded), 500))
  end
  return _split_lines(stringx.truncate(content, 500))
end

--- 追加单个工具块（调用 + 结果合并成一个折叠块）。
--- 块首行即状态标记：执行中显示 ⏳（无结果），结果到达后更新为 ✅（成功）或 ❌（失败），
--- 折叠文本（foldtext）按首行 emoji 自动切换图标。结果未到达时只显示首行（仍可折叠）。
--- 首行在工具名后展示目的说明（" · 修改配置"），随后追加耗时（" · 1.2s"）：
--- 执行中显示已执行时长，完成后显示总时长（由 fold 计时提供）。
--- @param lines table
--- @param tool_call table
--- @param result_msg table|nil 对应的工具结果消息
local function _append_tool_block(lines, tool_call, result_msg)
  local fn = tool_call["function"]
  local rows = {}
  if fn then
    local name = fn.name or ""
    local desc = _tool_description(fn)
    local desc_str = desc and (" · " .. desc) or ""
    -- 已完成工具优先用结果消息里持久化的总时长；执行中/无持久化时回退 fold 计时
    local duration = (result_msg and result_msg.duration_ms) or fold.get_duration(tool_call.id)
    local time_str = duration and (" · " .. fold.format_ms(duration)) or ""
    if result_msg then
      local failed = _tool_result_failed(result_msg.content)
      rows[#rows + 1] = string.format("%s 工具: %s%s%s", failed and "❌" or "✅", name, desc_str, time_str)
    else
      -- 结果消息未到达时按各自执行状态渲染（fold 计时记录了每个工具的开始/结束状态）：
      -- 已完成的工具立即显示 ✅/❌ 并锁定总耗时，仍在执行的显示 ⏳ + 实时耗时。
      local status = fold.get_status(tool_call.id)
      if status == "success" then
        rows[#rows + 1] = string.format("✅ 工具: %s%s%s", name, desc_str, time_str)
      elseif status == "failure" then
        rows[#rows + 1] = string.format("❌ 工具: %s%s%s", name, desc_str, time_str)
      else
        rows[#rows + 1] = string.format("⏳ 调用工具: %s%s%s", name, desc_str, time_str)
      end
    end
  end
  -- 结构化调用参数：无论工具最终成功/失败，展开折叠都能看到本次调用传了哪些参数
  local arg_lines = _tool_arguments_lines(fn)
  if arg_lines then
    rows[#rows + 1] = "参数:"
    for _, l in ipairs(arg_lines) do
      rows[#rows + 1] = l
    end
  end
  -- 结构化执行结果：成功/失败都有对应的结果内容（失败时通常为 error 对象）
  if result_msg then
    rows[#rows + 1] = "结果:"
    for _, l in ipairs(_result_lines(result_msg.content)) do
      rows[#rows + 1] = l
    end
  end
  _append_fold_block(lines, rows)
end

--- 追加轮次分割线（仅在轮次边界出现）
--- @param lines table
local function _append_turn_sep(lines)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "────────────────────"
  lines[#lines + 1] = ""
end

--- 格式化一条不含工具调用/结果的消息为文本行数组
--- @param message table
--- @param is_turn_end boolean
--- @return table
local function _format_message(message, is_turn_end)
  local lines = {}
  _append_role_header(lines, message)
  _append_reasoning(lines, message)
  _append_content(lines, message)
  if is_turn_end then
    _append_turn_sep(lines)
  end
  return lines
end

-- ========== 公开 API ==========

--- 渲染消息列表到 buffer（按当前激活的显示模式插件分派）
--- 未激活任何显示模式插件时回退到默认对话渲染（render_chat）。
--- 工具调用与其结果按「每个工具一个折叠块」分组：assistant 消息里的每个
--- tool_call 与紧随其后的 tool 结果消息配对渲染进同一个折叠块。
--- @param buf number
--- @param messages table 数组
function M.render(buf, messages)
  local plugin = display_modes.get_current()
  if plugin and plugin.render then
    plugin.render(buf, messages)
    return
  end
  M.render_chat(buf, messages)
end

--- 渲染消息列表到 buffer（默认对话模式）
--- @param buf number
--- @param messages table 数组
function M.render_chat(buf, messages)
  local all_lines = {}
  local msgs = messages or {}
  local i = 1
  while i <= #msgs do
    local msg = msgs[i]
    if msg.role == "system" then
      i = i + 1
    elseif msg.role == "assistant" and msg.tool_calls and #msg.tool_calls > 0 then
      -- 该 assistant 消息带工具调用：渲染角色头 + 推理 + 正文（模型常在调用工具前
      -- 先输出一段话，这段正文必须保留，否则工具调用落地后正文会从界面消失），
      -- 再把每个调用与其结果配对
      local lines = {}
      _append_role_header(lines, msg)
      _append_reasoning(lines, msg)
      _append_content(lines, msg)
      -- 工具结果消息按调用顺序紧随其后（tool_loop 保证顺序一致）。
      -- 仅在当前位置确实是工具结果时才推进（否则工具未返回结果时会把
      -- 下一条非工具消息（如下一轮用户消息）当作结果位置消费掉，导致其从界面消失）
      local result_idx = i + 1
      for _, tc in ipairs(msg.tool_calls) do
        local result_msg = nil
        if msgs[result_idx] and msgs[result_idx].role == "tool" then
          result_msg = msgs[result_idx]
          result_idx = result_idx + 1
        end
        _append_tool_block(lines, tc, result_msg)
      end
      -- 消费掉该 assistant 消息与所有配对到的工具结果消息
      local consumed_until = result_idx - 1
      -- 轮次分割线：若本条 assistant 消息是本轮可见最后一条则补分割线
      local turn_end = _is_turn_end(msgs, i)
      if turn_end then
        _append_turn_sep(lines)
      end
      for _, l in ipairs(lines) do
        all_lines[#all_lines + 1] = l
      end
      i = consumed_until + 1
    else
      local lines = _format_message(msg, _is_turn_end(msgs, i))
      for _, l in ipairs(lines) do
        all_lines[#all_lines + 1] = l
      end
      i = i + 1
    end
  end
  if #all_lines == 0 then
    all_lines = { "NeoAI 聊天", "", "输入消息开始对话。", "" }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.bo[buf].modifiable = true
end

--- 追加消息到 buffer（增量渲染）
--- @param buf number
--- @param message table
function M.append(buf, message)
  local lines = _format_message(message, true)
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count - 1, -1, false, lines)
end

--- 切换推理显示
--- @return boolean 新状态
function M.toggle_reasoning()
  state.show_reasoning = not state.show_reasoning
  return state.show_reasoning
end

--- 当前是否显示推理（显示模式插件渲染时读取）
--- @return boolean
function M.is_show_reasoning()
  return state.show_reasoning
end

--- 设置推理显示
--- @param show boolean
function M.set_show_reasoning(show)
  state.show_reasoning = show
end

-- ========== 显示模式插件共享工具 ==========

--- 供显示模式插件复用的渲染工具
--- @type table
M.helpers = {
  append_tool_block = _append_tool_block,
  pretty_json = _pretty_json,
  split_lines = _split_lines,
  truncate = function(s, n) return stringx.truncate(s, n) end,
  tool_arguments_lines = _tool_arguments_lines,
  result_lines = _result_lines,
  tool_result_failed = _tool_result_failed,
}

--- 重置（测试用）
function M.reset()
  state.show_reasoning = true
end

return M
