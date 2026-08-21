--- Markdown 渲染器
--- @module NeoAI.ui.components.markdown_view
--- 轻量 markdown 到纯文本/高亮行转换。用于聊天窗口渲染。
--- 支持代码块、行内代码、标题、列表、表格。

local M = {}

-- ========== 私有常量 ==========

local MARKDOWN_EXTS = { lua = "lua", py = "python", js = "javascript", ts = "typescript", sh = "sh", bash = "sh", json = "json", md = "markdown", txt = "text" }

-- 转义竖线占位符（\| 在拆分表格单元格前暂存，避免被当作列分隔符）
local PIPE_PLACEHOLDER = "\1"

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

--- 判断是否为表格行（以 | 开头）
--- @param line string
--- @return boolean
local function _is_table_row(line)
  return line:match("^%s*%|") ~= nil
end

--- 拆分表格行为单元格数组（保留空单元格，支持 \| 转义）
--- @param line string
--- @return table
local function _split_table_row(line)
  line = line:gsub("^%s*%|%s*", ""):gsub("%s*%|%s*$", "")
  line = line:gsub("\\%|", PIPE_PLACEHOLDER)
  local cells = {}
  local buf = {}
  for i = 1, #line do
    local ch = line:sub(i, i)
    if ch == "|" then
      cells[#cells + 1] = table.concat(buf):gsub(PIPE_PLACEHOLDER, "|")
      buf = {}
    else
      buf[#buf + 1] = ch
    end
  end
  cells[#cells + 1] = table.concat(buf):gsub(PIPE_PLACEHOLDER, "|")
  return cells
end

--- 判断单元格是否为分隔符单元格（--- 或 :---:）
--- @param cell string
--- @return boolean
local function _is_sep_cell(cell)
  return cell:match("^:?%-+:?$") ~= nil
end

--- 渲染 markdown 表格：按列显示宽度对齐（CJK 占 2 列）。
--- 需要至少一个分隔行（---/:-+:）才认为是表格；否则返回 nil（当作普通行）。
--- @param rows table 连续表格行
--- @return table|nil 对齐后的行数组
local function _render_table(rows)
  local split = {}
  local sep_idx = nil
  for idx, row in ipairs(rows) do
    local cells = _split_table_row(row)
    split[idx] = cells
    if not sep_idx and #cells > 0 then
      local is_sep = true
      for _, c in ipairs(cells) do
        if not _is_sep_cell((c:gsub("^%s+", ""):gsub("%s+$", ""))) then
          is_sep = false
          break
        end
      end
      if is_sep then sep_idx = idx end
    end
  end
  if sep_idx == nil then return nil end

  local col_count = 0
  for _, cells in ipairs(split) do
    col_count = math.max(col_count, #cells)
  end
  local widths = {}
  for ci = 1, col_count do
    local w = 1
    for idx, cells in ipairs(split) do
      if idx ~= sep_idx then
        local cell = (cells[ci] or ""):gsub("^%s+", ""):gsub("%s+$", "")
        w = math.max(w, vim.fn.strwidth(_clean_inline(cell)))
      end
    end
    widths[ci] = w
  end

  local out = {}
  for idx, cells in ipairs(split) do
    local parts = {}
    for ci = 1, col_count do
      local cell = (cells[ci] or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if idx == sep_idx then
        parts[#parts + 1] = string.rep("─", widths[ci])
      else
        local cleaned = _clean_inline(cell)
        local pad = math.max(0, widths[ci] - vim.fn.strwidth(cleaned))
        parts[#parts + 1] = cleaned .. string.rep(" ", pad)
      end
    end
    out[#out + 1] = "| " .. table.concat(parts, " | ") .. " |"
  end
  return out
end

-- ========== 公开 API ==========

--- 将 markdown 文本转换为可渲染的行数组
--- @param text string
--- @return table { { text, style } } style = "normal"|"code"|"heading"|"list"|"quote"|"table"
function M.render(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  local out = {}
  local in_code = false
  local code_lang = nil
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if line:match("^```") then
      if in_code then
        in_code = false
      else
        in_code = true
        code_lang = line:match("^```%s*(%w*)")
      end
      out[#out + 1] = { text = "", style = "code_fence" }
      i = i + 1
    elseif in_code then
      out[#out + 1] = { text = line, style = "code", lang = code_lang }
      i = i + 1
    elseif _is_table_row(line) then
      -- 收集连续的表格行，整块按列宽对齐渲染
      local block = {}
      local j = i
      while j <= #lines and _is_table_row(lines[j]) do
        block[#block + 1] = lines[j]
        j = j + 1
      end
      local rendered = _render_table(block)
      if rendered then
        for _, r in ipairs(rendered) do
          out[#out + 1] = { text = r, style = "table" }
        end
        i = j
      else
        out[#out + 1] = { text = _clean_inline(line), style = "normal" }
        i = i + 1
      end
    elseif line:match("^#+ ") then
      out[#out + 1] = { text = _clean_inline(line:gsub("^#+%s*", "")), style = "heading" }
      i = i + 1
    elseif line:match("^[-*+] ") then
      out[#out + 1] = { text = "• " .. _clean_inline(line:gsub("^[-*+]%s*", "")), style = "list" }
      i = i + 1
    elseif line:match("^%d+%. ") then
      out[#out + 1] = { text = _clean_inline(line), style = "list" }
      i = i + 1
    elseif line:match("^>") then
      out[#out + 1] = { text = _clean_inline(line:gsub("^>%s*", "")), style = "quote" }
      i = i + 1
    elseif line == "---" then
      out[#out + 1] = { text = string.rep("─", 30), style = "hr" }
      i = i + 1
    else
      out[#out + 1] = { text = _clean_inline(line), style = "normal" }
      i = i + 1
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
