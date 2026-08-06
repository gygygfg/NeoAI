--- 消息列表渲染
--- @module NeoAI.ui.components.message_list
--- 将 Agent 消息渲染到 buffer。支持流式更新、推理折叠、工具结果展示。

local markdown_view = require("NeoAI.ui.components.markdown_view")
local stringx = require("NeoAI.utils.stringx")
local config_store = require("NeoAI.kernel.config_store")

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

--- 格式化消息为文本行数组
--- @param message table
--- @return table 行数组
local function _format_message(message)
  local lines = {}
  local label = ROLE_LABELS[message.role] or message.role
  lines[#lines + 1] = "### " .. label

  -- 推理正文缩进两个空格，由聊天窗口的 indent 折叠自动收起。
  -- 标题由折叠占位文本提供，避免折叠后显示重复标题。
  if message.reasoning and message.reasoning ~= "" and state.show_reasoning then
    local rl = markdown_view.render(message.reasoning)
    for _, l in ipairs(rl) do
      lines[#lines + 1] = l.text == "" and "" or ("  " .. l.text)
    end
    -- indent 折叠至少需要两行；空白行会被忽略，因此补一个推理标题行。
    if #rl == 1 then
      lines[#lines + 1] = "  思考过程"
    end
    lines[#lines + 1] = ""
  end

  -- 工具调用
  if message.tool_calls and #message.tool_calls > 0 then
    for _, tc in ipairs(message.tool_calls) do
      local fn = tc["function"]
      if fn then
        lines[#lines + 1] = string.format("⚡ 调用工具: %s(%s)", fn.name or "", fn.arguments or "")
      end
    end
    lines[#lines + 1] = ""
  end

  -- 正文内容（markdown 渲染）——工具消息除外（工具结果单独展示）
  if message.role ~= "tool" and message.content and message.content ~= "" then
    local rendered = markdown_view.render(message.content)
    for _, l in ipairs(rendered) do
      if l.text ~= "" then
        lines[#lines + 1] = l.text
      end
    end
  end

  -- 工具结果
  if message.role == "tool" then
    lines[#lines + 1] = "工具: " .. (message.tool_name or "未知")
    lines[#lines + 1] = "```"
    lines[#lines + 1] = stringx.truncate(message.content or "", 500)
    lines[#lines + 1] = "```"
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "────────────────────"
  lines[#lines + 1] = ""
  return lines
end

-- ========== 公开 API ==========

--- 渲染消息列表到 buffer
--- @param buf number
--- @param messages table 数组
function M.render(buf, messages)
  local all_lines = {}
  for _, msg in ipairs(messages or {}) do
    if msg.role ~= "system" then
      local lines = _format_message(msg)
      for _, l in ipairs(lines) do
        all_lines[#all_lines + 1] = l
      end
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
  local lines = _format_message(message)
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count - 1, -1, false, lines)
end

--- 切换推理显示
--- @return boolean 新状态
function M.toggle_reasoning()
  state.show_reasoning = not state.show_reasoning
  return state.show_reasoning
end

--- 设置推理显示
--- @param show boolean
function M.set_show_reasoning(show)
  state.show_reasoning = show
end

--- 重置（测试用）
function M.reset()
  state.show_reasoning = true
end

return M
