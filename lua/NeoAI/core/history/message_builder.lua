--- NeoAI 消息构建器
--- 职责：将会话数据展平为 role/content 消息列表、构建 round text
--- 从 history/manager.lua 提取，减轻其负担
---
--- 注意：assistant 条目统一使用 Lua table 格式，不再使用 JSON 字符串。
--- 条目结构：
---   { content = "...", reasoning_content = "..." }  -- 普通 AI 回复（含可选的思考过程）
---   { type = "tool_call", tool_name = "...", arguments = {}, result = "..." }  -- 工具调用
---   "{{{...}}}"  -- 折叠文本（纯字符串，用于兼容旧数据）
--- 写入/读取文件时由 persistence 模块统一做 JSON 编解码。

local M = {}

-- ========== 消息展平 ==========

--- 将单个会话的消息展平为 role/content 列表
--- @param session table 会话对象
--- @return table { {role, content}, ... }
--- content 字段：
---   - 普通消息：纯字符串
---   - 含思考过程的消息：{ reasoning_content = "...", content = "..." }（Lua table）
---   - 折叠文本："{{{...}}}"（纯字符串）
function M.session_to_messages(session)
  if not session then return {} end

  local msgs = {}
  if session.user and session.user ~= "" then
    table.insert(msgs, { role = "user", content = session.user })
  end

  local assistant_list = session.assistant
  if type(assistant_list) ~= "table" then
    assistant_list = (assistant_list and assistant_list ~= "") and { assistant_list } or {}
  end

  -- 工具调用计数器，用于生成占位 tool_call_id
  local tool_call_counter = 0
  -- 当前正在构建的 tool 消息列表（用于连续工具调用合并）
  local pending_tool_msgs = nil
  local pending_assistant = nil

  local function flush_pending_tools()
    if pending_assistant and pending_tool_msgs then
      -- 先插入占位 assistant 消息，再插入所有 tool 消息
      table.insert(msgs, pending_assistant)
      for _, tm in ipairs(pending_tool_msgs) do
        table.insert(msgs, tm)
      end
    end
    pending_assistant = nil
    pending_tool_msgs = nil
  end

  for _, entry in ipairs(assistant_list) do
    -- 统一转为 Lua table
    local parsed = M._normalize_entry(entry)
    if not parsed then
      flush_pending_tools()
      goto continue
    end

    if parsed.type == "tool_call" then
      -- 工具调用条目：转换为 role="tool" 消息
      -- 如果还没有占位 assistant，创建一个
      if not pending_assistant then
        tool_call_counter = tool_call_counter + 1
        local placeholder_id = "call_history_" .. os.time() .. "_" .. tool_call_counter .. "_" .. math.random(10000, 99999)
        pending_assistant = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = placeholder_id,
              type = "function",
              ["function"] = {
                name = parsed.tool_name or "unknown",
                arguments = vim.json.encode(parsed.arguments or {}),
              },
            },
          },
        }
        pending_tool_msgs = {}
      else
        -- 已有占位 assistant，追加 tool_call 到其 tool_calls 数组
        tool_call_counter = tool_call_counter + 1
        local placeholder_id = "call_history_" .. os.time() .. "_" .. tool_call_counter .. "_" .. math.random(10000, 99999)
        table.insert(pending_assistant.tool_calls, {
          id = placeholder_id,
          type = "function",
          ["function"] = {
            name = parsed.tool_name or "unknown",
            arguments = vim.json.encode(parsed.arguments or {}),
          },
        })
      end

      -- 构建 tool 消息内容
      local result_content = ""
      if parsed.results then
        local parts = {}
        for _, res in ipairs(parsed.results) do
          local s = type(res) == "string" and res or (pcall(vim.json.encode, res) and vim.json.encode(res) or vim.inspect(res))
          table.insert(parts, s)
        end
        result_content = table.concat(parts, "\n")
      else
        result_content = tostring(parsed.result or "")
      end

      -- 暂存 tool 消息（使用占位 assistant 中最后添加的 tool_call_id）
      local last_tc = pending_assistant.tool_calls[#pending_assistant.tool_calls]
      table.insert(pending_tool_msgs, {
        role = "tool",
        tool_call_id = last_tc.id,
        name = parsed.tool_name or "unknown",
        content = result_content,
      })
    else
      -- 普通 AI 回复条目：先刷新待处理的工具消息
      flush_pending_tools()

      local content
      if parsed.reasoning_content and parsed.reasoning_content ~= "" then
        content = {
          reasoning_content = parsed.reasoning_content,
          content = parsed.content or "",
        }
      else
        content = parsed.content or ""
      end
      table.insert(msgs, { role = "assistant", content = content })
    end
    ::continue::
  end

  -- 刷新最后待处理的工具消息
  flush_pending_tools()

  return msgs
end

--- 将 assistant 条目统一规范化为 Lua table
--- 兼容旧数据格式（JSON 字符串、纯字符串等）
--- @param entry any assistant 条目
--- @return table|nil 规范化的 table，nil 表示无效条目
function M._normalize_entry(entry)
  if type(entry) == "table" then
    -- 已经是 table，直接使用
    return entry
  end

  if type(entry) ~= "string" or entry == "" then
    return nil
  end

  -- 尝试 JSON 解码（兼容旧格式：预编码的 JSON 字符串）
  local ok, parsed = pcall(vim.json.decode, entry)
  if ok and type(parsed) == "table" then
    return parsed
  end

  -- 纯字符串：包装为 { content = entry }
  return { content = entry }
end

--- 构建工具调用折叠文本
--- @param parsed table 工具调用条目
--- @return string
function M._build_tool_call_text(parsed)
  local tool_name = parsed.tool_name or "unknown"
  local args_str
  if parsed.arguments_list then
    local parts = {}
    for i, args in ipairs(parsed.arguments_list) do
      table.insert(parts, "  [" .. i .. "] " .. vim.inspect(args or {}))
    end
    args_str = table.concat(parts, "\n")
  else
    args_str = vim.inspect(parsed.arguments or {})
  end
  args_str = args_str:gsub("}}}", "} } }"):gsub("{{{", "{ { {")

  local result_str
  if parsed.results then
    local parts = {}
    for i, res in ipairs(parsed.results) do
      local s = type(res) == "string" and res or (pcall(vim.json.encode, res) and vim.json.encode(res) or vim.inspect(res))
      table.insert(parts, "  [" .. i .. "] " .. s)
    end
    result_str = table.concat(parts, "\n")
  else
    result_str = tostring(parsed.result or "")
  end
  result_str = result_str:gsub("\\r\\n", "\n"):gsub("\\r", "\n")

  local has_warning = false
  for line in result_str:gmatch("[^\n]+") do
    if line:match("^⚠️%s*警告：") then has_warning = true; break end
  end
  local icon = parsed.is_error and "❌" or (has_warning and "⚠️" or "✅")
  result_str = result_str:gsub("}}}", "} } }"):gsub("{{{", "{ { {"):gsub("\n", "\n    ")
  local duration_str = parsed.duration and string.format(" (%.1fs)", parsed.duration) or ""

  local pack_name = parsed.pack_name or "_uncategorized"
  local pack_icon = "🔧"
  local pack_display = "工具调用"
  local ok_tp, tool_pack = pcall(require, "NeoAI.tools.tool_pack")
  if ok_tp then
    pack_icon = tool_pack.get_pack_icon(pack_name) or "🔧"
    pack_display = tool_pack.get_pack_display_name(pack_name) or "工具调用"
  end

  return "{{{ " .. pack_icon .. " " .. pack_display .. " - " .. icon .. " " .. tool_name .. duration_str
    .. "\n    参数: " .. args_str
    .. "\n    结果: " .. result_str
    .. "\n}}}"
end

-- ========== Round Text 构建 ==========

--- 使用 Neovim 内置函数截断 UTF-8 字符串
--- @param str string
--- @param max_len number
--- @return string
local function truncate_utf8(str, max_len)
  if not str or str == "" then return str end
  local positions = vim.str_utf_pos(str)
  if #positions <= max_len then return str end
  local byte_pos = positions[max_len + 1] - 1
  return str:sub(1, byte_pos)
end

--- 构建会话的 round text（用于树视图显示）
--- @param session table 会话对象
--- @return string
function M.build_round_text(session)
  if not session then return "" end

  local user_text = ""
  local ai_text = ""

  if session.user and session.user ~= "" then
    user_text = session.user:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end

  if session.assistant and (
    (type(session.assistant) == "table" and #session.assistant > 0) or
    (type(session.assistant) == "string" and session.assistant ~= "")
  ) then
    local last_entry = session.assistant
    if type(session.assistant) == "table" and #session.assistant > 0 then
      last_entry = session.assistant[#session.assistant]
    end

    -- 统一规范化
    local parsed = M._normalize_entry(last_entry)
    if parsed then
      if parsed.content then
        ai_text = parsed.content
      elseif parsed.type == "tool_call" then
        ai_text = "🔧 " .. (parsed.tool_name or "工具调用")
      end
    elseif type(last_entry) == "string" then
      ai_text = last_entry
    end
    ai_text = ai_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end

  local text = ""
  if user_text ~= "" and ai_text ~= "" then
    local user_len = #user_text
    if user_len > 15 then
      user_text = truncate_utf8(user_text, 15) .. "…"
      user_len = 15
    end
    text = "👤" .. user_text
    local max_ai = 20 - user_len
    if max_ai < 0 then max_ai = 0 end
    if #ai_text > max_ai then
      ai_text = truncate_utf8(ai_text, max_ai) .. "…"
    end
    text = text .. " | 🤖" .. ai_text
  elseif user_text ~= "" then
    if #user_text > 20 then
      user_text = truncate_utf8(user_text, 20) .. "…"
    end
    text = "👤" .. user_text
  elseif ai_text ~= "" then
    if #ai_text > 20 then
      ai_text = truncate_utf8(ai_text, 20) .. "…"
    end
    text = "🤖" .. ai_text
  end
  return text
end

return M
