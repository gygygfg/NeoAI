--- Markdown 渲染器
--- @module NeoAI.ui.components.markdown_view
--- 轻量 markdown 到纯文本/高亮行转换。用于聊天窗口渲染。
--- 支持代码块、行内代码、标题、列表。

local M = {}

-- ========== 私有常量 ==========

local MARKDOWN_EXTS = { lua = "lua", py = "python", js = "javascript", ts = "typescript", sh = "sh", bash = "sh", json = "json", md = "markdown", txt = "text" }

-- ========== 私有函数 ==========

--- 清理行内 markdown 标记
--- @param line string
--- @return string
local function _clean_inline(line)
  line = line:gsub("`([^`]+)`", "%1") -- 行内代码
  line = line:gsub("%*%*(.-)%*%*", "%1") -- **bold**
  line = line:gsub("%*(.-)%*", "%1") -- *italic*
  line = line:gsub("__(.-)__", "%1") -- __underline__
  line = line:gsub("%[([^%]]*)%]%([^%)]*%)", "%1") -- [text](url)
  return line
end

-- ========== 公开 API ==========

--- 将 markdown 文本转换为可渲染的行数组
--- @param text string
--- @return table { { text, style } } style = "normal"|"code"|"heading"|"list"|"quote"
function M.render(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  local out = {}
  local in_code = false
  local code_lang = nil
  for _, line in ipairs(lines) do
    if line:match("^```") then
      if in_code then
        in_code = false
      else
        in_code = true
        code_lang = line:match("^```%s*(%w*)")
      end
      out[#out + 1] = { text = "", style = "code_fence" }
    elseif in_code then
      out[#out + 1] = { text = line, style = "code", lang = code_lang }
    elseif line:match("^#{1,6} ") then
      out[#out + 1] = { text = _clean_inline(line:gsub("^#+%s*", "")), style = "heading" }
    elseif line:match("^[-*+] ") then
      out[#out + 1] = { text = "• " .. _clean_inline(line:gsub("^[-*+]%s*", "")), style = "list" }
    elseif line:match("^%d+%. ") then
      out[#out + 1] = { text = _clean_inline(line), style = "list" }
    elseif line:match("^>") then
      out[#out + 1] = { text = _clean_inline(line:gsub("^>%s*", "")), style = "quote" }
    elseif line == "---" then
      out[#out + 1] = { text = string.rep("─", 30), style = "hr" }
    else
      out[#out + 1] = { text = _clean_inline(line), style = "normal" }
    end
  end
  return out
end

--- 将 markdown 渲染为纯文本（紧凑）
--- @param text string
--- @return string
function M.to_plain(text)
  local lines = M.render(text)
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = l.text
  end
  return table.concat(out, "\n")
end

--- 获取语言显示名
--- @param lang string|nil
--- @return string
function M.lang_name(lang)
  return MARKDOWN_EXTS[lang] or lang or "text"
end

--- 为代码块生成可折叠的折叠标记（可选）
--- @param rendered table
--- @return string 渲染文本
function M.flatten(rendered)
  local out = {}
  for _, l in ipairs(rendered) do
    out[#out + 1] = l.text
  end
  return table.concat(out, "\n")
end

return M
