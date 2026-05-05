--- NeoAI 消息构建器
--- 职责：将会话数据展平为 role/content 消息列表、构建 round text
--- 从 history/manager.lua 提取，减轻其负担

local M = {}

-- ========== 消息展平 ==========

--- 将单个会话的消息展平为 role/content 列表
--- @param session table 会话对象
--- @return table { {role, content}, ... }
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

  for _, entry in ipairs(assistant_list) do
    local content = entry
    local parsed = entry
    if type(entry) == "string" then
      local ok, decoded = pcall(vim.json.decode, entry)
      if ok and type(decoded) == "table" then
        parsed = decoded
      else
        parsed = nil
      end
    end

    if type(parsed) == "table" then
      if parsed.type == "tool_call" then
        content = M._build_tool_call_text(parsed)
      elseif parsed.content then
        content = parsed.content
        if parsed.reasoning_content and parsed.reasoning_content ~= "" then
          content = vim.json.encode({
            reasoning_content = parsed.reasoning_content,
            content = parsed.content,
          })
        end
      elseif parsed.reasoning_content and parsed.reasoning_content ~= "" then
        content = vim.json.encode({
          reasoning_content = parsed.reasoning_content,
          content = "",
        })
      end
    end
    table.insert(msgs, { role = "assistant", content = content })
  end
  return msgs
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

    if type(last_entry) == "table" then
      if last_entry.content then
        ai_text = last_entry.content
      elseif last_entry.type == "tool_call" then
        ai_text = "🔧 " .. (last_entry.tool_name or "工具调用")
      end
    elseif type(last_entry) == "string" then
      local ok, parsed = pcall(vim.json.decode, last_entry)
      if ok and type(parsed) == "table" then
        if parsed.content then
          ai_text = parsed.content
        elseif parsed.type == "tool_call" then
          ai_text = "🔧 " .. (parsed.tool_name or "工具调用")
        end
      else
        ai_text = last_entry
      end
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
