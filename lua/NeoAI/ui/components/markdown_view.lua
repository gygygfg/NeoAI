--- Markdown 渲染器
--- @module NeoAI.ui.components.markdown_view
--- 轻量 markdown 到纯文本/高亮行转换。用于聊天窗口渲染。
--- 支持代码块、行内代码、标题、列表、表格。

local M = {}

-- ========== 私有常量 ==========

local MARKDOWN_EXTS = { lua = "lua", py = "python", js = "javascript", ts = "typescript", sh = "sh", bash = "sh", json = "json", md = "markdown", txt = "text" }

-- 转义竖线占位符（\| 在拆分表格单元格前暂存，避免被当作列分隔符）
local PIPE_PLACEHOLDER = "\1"

-- 表格列显示宽度上限：单格内容过长时截断显示，避免按最长格做整表对齐
-- （一个超长格会让所有行/分隔行填充成几十万字节的巨长行，渲染与重绘卡死）
local MAX_COL_WIDTH = 60
-- 单行扫描上限：超过则只处理有界前缀（任何单元格展示宽度最多 MAX_COL_WIDTH，
-- 超长行的后半段本就不会被显示，无需对几十万字节做模式匹配）
local TABLE_ROW_SCAN_LIMIT = 2048

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

--- 拆分表格行为单元格数组（保留空单元格，支持 \| 转义）。
--- 用 string.find 定位分隔符（O(n) 快速路径），避免逐字符 sub 分配。
--- @param line string
--- @return table
local function _split_table_row(line)
  line = line:gsub("^%s*%|%s*", ""):gsub("%s*%|%s*$", "")
  line = line:gsub("\\%|", PIPE_PLACEHOLDER)
  local cells = {}
  local start = 1
  while true do
    local pos = line:find("|", start, true)
    if pos then
      cells[#cells + 1] = line:sub(start, pos - 1):gsub(PIPE_PLACEHOLDER, "|")
      start = pos + 1
    else
      cells[#cells + 1] = line:sub(start):gsub(PIPE_PLACEHOLDER, "|")
      break
    end
  end
  return cells
end

--- 判断单元格是否为分隔符单元格（--- 或 :---:）
--- @param cell string
--- @return boolean
local function _is_sep_cell(cell)
  return cell:match("^:?%-+:?$") ~= nil
end

--- 按显示宽度截断字符串，超出部分以 … 结尾（CJK 占 2 列）。
--- 字节数超过 max_width*3（最多 3 字节/字符）时显示宽度必然超限，跳过 strwidth
--- 快速截断；否则先做一次 strwidth 判断。strcharpart 取前 max_width 个字符再回退，
--- 保证只做有界的 strwidth 调用。
--- @param str string
--- @param max_width number 显示宽度上限
--- @return string
local function _truncate_display(str, max_width)
  if #str <= max_width * 3 and vim.fn.strwidth(str) <= max_width then return str end
  local s = vim.fn.strcharpart(str, 0, max_width)
  while vim.fn.strwidth(s) > max_width - 1 do
    s = vim.fn.strcharpart(s, 0, vim.fn.strchars(s) - 1)
  end
  return s .. "…"
end

--- 渲染 markdown 表格：按列显示宽度对齐（CJK 占 2 列）。
--- 需要至少一个分隔行（---/:-+:）才认为是表格；否则返回 nil（当作普通行）。
--- 每列宽度上限 MAX_COL_WIDTH：超长单元格截断显示，避免整表被单个巨长格撑爆。
--- @param rows table 连续表格行
--- @return table|nil 对齐后的行数组
local function _render_table(rows)
  local split = {}
  local sep_idx = nil
  for idx, row in ipairs(rows) do
    -- 超长行只处理有界前缀：后半个单元格本就会被截断显示，跳过可避免对
    -- 几十万字节做 gsub/逐字符拆分（卡死主因）。
    local line = row
    if #line > TABLE_ROW_SCAN_LIMIT then
      line = line:sub(1, TABLE_ROW_SCAN_LIMIT)
    end
    local cells = _split_table_row(line)
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

  -- 一次性处理所有单元格：超长格先截断显示宽度再清理行内标记
  -- （宽度计算与渲染共用，避免对超大字符串重复 strwidth/gsub）
  local cleaned = {}
  for idx, cells in ipairs(split) do
    cleaned[idx] = {}
    for ci, c in ipairs(cells) do
      local raw = c:gsub("^%s+", ""):gsub("%s+$", "")
      cleaned[idx][ci] = _clean_inline(_truncate_display(raw, MAX_COL_WIDTH))
    end
  end

  local col_count = 0
  for _, cells in ipairs(split) do
    col_count = math.max(col_count, #cells)
  end
  local widths = {}
  for ci = 1, col_count do
    local w = 1
    for idx = 1, #split do
      if idx ~= sep_idx then
        w = math.max(w, vim.fn.strwidth(cleaned[idx][ci] or ""))
      end
    end
    widths[ci] = math.min(w, MAX_COL_WIDTH)
  end

  local out = {}
  for idx = 1, #split do
    local parts = {}
    for ci = 1, col_count do
      local cell = cleaned[idx][ci] or ""
      if idx == sep_idx then
        parts[#parts + 1] = string.rep("─", widths[ci])
      else
        local disp = _truncate_display(cell, MAX_COL_WIDTH)
        local pad = math.max(0, widths[ci] - vim.fn.strwidth(disp))
        parts[#parts + 1] = disp .. string.rep(" ", pad)
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
