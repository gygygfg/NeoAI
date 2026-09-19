--- Markdown 渲染器
--- @module NeoAI.ui.components.markdown_view
--- 轻量 markdown 到纯文本/高亮行转换。用于聊天窗口渲染。
--- 支持代码块、行内代码、标题、列表、表格。
--- 文本度量（显示宽度 / 切片）全部走纯 Lua 的 `utils.textmetrics`，避免逐字符
--- 调用 `vim.fn.strwidth/strcharpart/strchars` 的 C 边界开销（表格折行是渲染热点）。

local tm = require("NeoAI.utils.textmetrics")

local M = {}

-- ========== 私有常量 ==========

local MARKDOWN_EXTS = { lua = "lua", py = "python", js = "javascript", ts = "typescript", sh = "sh", bash = "sh", json = "json", md = "markdown", txt = "text" }

-- 转义竖线占位符（\| 在拆分表格单元格前暂存，避免被当作列分隔符）
local PIPE_PLACEHOLDER = "\1"

-- 单列显示宽度上限：未传入自适应 table_width（无窗口上下文/纯文本导出）时，
-- 每列最多加到此宽度，整列超宽单元格按此列宽折行；原来按最长格做整表对齐把
-- 所有行/分隔行填充成几十万字节的巨长行，卡死渲染。
local MAX_COL_WIDTH = 60
-- 单列内容宽下限（窗口自适应缩列时保底，表头/单字可换行显示）。
local MIN_COL_WIDTH = 3
-- 单格折行数上限：折行超过此数时末行以 … 结尾，避免单个巨长格撑爆 buffer。
-- 折行显示（不再整格截断丢弃）已让长内容可读，但数量仍须有界。
local MAX_CELL_LINES = 8
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

--- 按显示宽度折行字符串（CJK 占 2 列），每行显示宽度不超过 max_width。
--- 折行数超过 MAX_CELL_LINES 时截断：末行末尾以 … 结尾，保证输出有界，
--- 避免单个超长格被折成数千行撑爆 buffer。
--- @param str string
--- @param max_width number 每行显示宽度上限
--- @return table 折行行数组
local function _wrap_display(str, max_width)
  local out = {}
  local line = {}
  local w = 0
  -- 单遍扫描：纯 Lua 逐码点取宽度（每个码点只解码一次），避免 O(n²) 的逐字符切片。
  for ch, cw in tm.each_char(str) do
    if w + cw > max_width and w > 0 then
      out[#out + 1] = table.concat(line)
      line = {}
      w = 0
    end
    line[#line + 1] = ch
    w = w + cw
  end
  out[#out + 1] = table.concat(line)
  if #out == 0 then out[1] = "" end
  if #out > MAX_CELL_LINES then
    local capped = {}
    for k = 1, MAX_CELL_LINES - 1 do capped[k] = out[k] end
    -- 逐字回退末行，保证「末行 + …」的显示宽度不超出 max_width，
    -- 避免截断后反而溢出列宽、破坏该行与下一列边框的对齐。
    -- 回退必须「严格递减」：当末行只剩单个宽字符（CJK 宽 2）而 avail 更小时，
    -- strcharpart(last, 0, math.max(1, n-1)) 对 n=1 恒返回原串，宽度不变 → 死循环
    -- 卡死主线程（思考/历史消息重渲染时命中）。改为 k 从字符数递减到 0，
    -- k=0 取空串必然满足宽度条件，保证终止。
    local last = out[MAX_CELL_LINES]
    local avail = math.max(0, max_width - tm.strwidth("…"))
    local k = tm.strchars(last)
    while k > 0 and tm.strwidth(tm.strcharpart(last, 0, k)) > avail do
      k = k - 1
    end
    last = tm.strcharpart(last, 0, k)
    capped[MAX_CELL_LINES] = last .. "…"
    return capped
  end
  return out
end

--- 解析分隔行单元格的对齐标记（:--- / :---: / ---:），无冒号默认左对齐。
--- @param cell string 已 trim 的分隔行单元格
--- @return string "left"|"center"|"right"
local function _sep_align(cell)
  if cell:match("^:%-+:$") then return "center" end
  if cell:match("^:%-+$") then return "left" end
  if cell:match("^-+:$") then return "right" end
  return "left"
end

--- 把单格内容按对齐方式在显示宽度内填充空格（左对齐补右、右对齐补左、居中两侧均分）。
--- @param line string
--- @param width number 目标显示宽度
--- @param align string "left"|"center"|"right"
--- @return string
local function _pad_cell(line, width, align)
  local extra = math.max(0, width - tm.strwidth(line))
  if align == "right" then
    return string.rep(" ", extra) .. line
  elseif align == "center" then
    local left = math.floor(extra / 2)
    return string.rep(" ", left) .. line .. string.rep(" ", extra - left)
  end
  return line .. string.rep(" ", extra)
end

--- 渲染 markdown 表格：按列显示宽度对齐（CJK 占 2 列），带完整上下边框。
--- 需要至少一个分隔行（---/:-+:）才认为是表格；否则返回 nil（当作普通行）。
--- streaming=true 时正在生成：原样返回表格行（不填充空格/不折行），等生成结束后
--- 再由本函数做一次完整对齐填充，避免表格流式生成期间列宽不断跳动。
--- 表格最大总宽随调用方传入自适应（见 opts.table_width），在列间按自然宽度分摊；
--- 超宽单元格按所分列宽折行（_wrap_display），每行输出多条物理行，行高 = 该行最高
--- 单元格行数，其余单元格补空行使整行同步加高。
--- @param rows table 连续表格行
--- @param streaming boolean|nil 是否处于流式生成中
--- @param table_width number|nil 表格最大总显示宽度（含边框；默认 MAX_TABLE_WIDTH）
--- @return table|nil 对齐后的行数组（streaming 时为原样行）
local function _render_table(rows, streaming, table_width)
  if streaming then return rows end

  local split = {}
  local sep_idx = nil
  local aligns = {}
  for idx, row in ipairs(rows) do
    -- 超长行只处理有界前缀：后半个单元格本就会被折行/截断显示，跳过可避免对
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
      if is_sep then
        sep_idx = idx
        -- 提取每列对齐标记（缺省左对齐），用于后续单元格填充
        for ci, c in ipairs(cells) do
          aligns[ci] = _sep_align(c:gsub("^%s+", ""):gsub("%s+$", ""))
        end
      end
    end
  end
  if sep_idx == nil then return nil end

  -- 一次性清理所有单元格的行内标记（宽度计算与渲染共用，避免重复 strwidth/gsub）
  local cleaned = {}
  for idx, cells in ipairs(split) do
    cleaned[idx] = {}
    for ci, c in ipairs(cells) do
      local raw = c:gsub("^%s+", ""):gsub("%s+$", "")
      cleaned[idx][ci] = _clean_inline(raw)
    end
  end

  local col_count = 0
  for _, cells in ipairs(split) do
    col_count = math.max(col_count, #cells)
  end
  if col_count == 0 then return nil end

  -- 各列自然显示宽度（该列非分隔行单元格的最大显示宽度）
  local natural = {}
  for ci = 1, col_count do
    local w = 1
    for idx = 1, #split do
      if idx ~= sep_idx then
        w = math.max(w, tm.strwidth(cleaned[idx][ci] or ""))
      end
    end
    natural[ci] = w
  end

  -- 列宽分配：
  -- - 未传 table_width（无窗口上下文）：每列 = min(自然宽, MAX_COL_WIDTH)，不做总宽缩减；
  -- - 传了 table_width（随窗口自适应）：把「表格最大总宽」折算为列内容可用宽度分摊，
  --   放不下时缩列，并严格保证 sum(列宽) <= avail，即整表（含边框与单元格 padding）
  --   永不超出 table_width —— 长内容由单元格折行（_wrap_display）消化，窄窗下表格能被
  --   压进窗口宽度自动换行，而不是溢出窗口后被 nvim 从中间硬折、破坏边框对齐。
  --   缩列采用「削峰/水填」：优先缩最宽的列、保留较窄列（如短表头列的自然宽），
  --   每列不低于 min(自然宽, MIN_COL_WIDTH)，故列宽永不超过自然宽。
  -- cell_pad_w=2：单元格左右各 1 空格；边界符（首尾 + 列间）共 col_count+1 个。
  local cell_pad_w = 2
  local widths = {}
  if table_width == nil then
    for ci = 1, col_count do
      widths[ci] = math.min(natural[ci], MAX_COL_WIDTH)
    end
  else
    local avail = math.max(col_count, table_width - (col_count + 1) - cell_pad_w * col_count)
    local sum_nat = 0
    local max_nat = 0
    for ci = 1, col_count do
      sum_nat = sum_nat + natural[ci]
      if natural[ci] > max_nat then max_nat = natural[ci] end
    end
    if sum_nat <= avail then
      -- 自然宽合计放得下：不缩列、不折行，直接用自然宽
      for ci = 1, col_count do widths[ci] = natural[ci] end
    else
      -- 各列缩列下限（不高于自然宽，避免把窄列虚增到 MIN_COL_WIDTH）
      local mins = {}
      local min_total = 0
      for ci = 1, col_count do
        mins[ci] = math.min(natural[ci], MIN_COL_WIDTH)
        min_total = min_total + mins[ci]
      end
      -- 极端窄窗：连下限都放不下时退化为每列至少 1 列（不可再缩，允许极小溢出）
      if min_total > avail then
        for ci = 1, col_count do mins[ci] = 1 end
      end
      -- 二分求“削峰水位” level：宽列截到 level、窄列保留自然宽，
      -- 使 sum(clamp(自然宽, mins, level)) 尽量贴合 avail（单调，可二分）。
      local function _sum_at(level)
        local s = 0
        for i = 1, col_count do
          local w = (natural[i] < level) and natural[i] or level
          if w < mins[i] then w = mins[i] end
          s = s + w
        end
        return s
      end
      local lo, hi = 0, max_nat
      while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if _sum_at(mid) <= avail then lo = mid else hi = mid - 1 end
      end
      local total = 0
      for ci = 1, col_count do
        local w = (natural[ci] < lo) and natural[ci] or lo
        if w < mins[ci] then w = mins[ci] end
        widths[ci] = w
        total = total + w
      end
      -- 水位取整会残留不足一列宽的空档（< 列数）：补给仍可增宽的自然宽最大的列
      while total < avail do
        local pick, pick_nat = nil, 0
        for ci = 1, col_count do
          if widths[ci] < natural[ci] and natural[ci] > pick_nat then
            pick, pick_nat = ci, natural[ci]
          end
        end
        if not pick then break end
        widths[pick] = widths[pick] + 1
        total = total + 1
      end
    end
  end

  -- 各列对齐方式补齐到默认左对齐
  for ci = 1, col_count do
    if aligns[ci] == nil then aligns[ci] = "left" end
  end

  -- 按行折行：每格先折成 <=列宽 的多行，行高 = 该行最高单元格行数。
  local wrapped = {}
  for idx = 1, #split do
    wrapped[idx] = {}
    if idx ~= sep_idx then
      for ci = 1, col_count do
        wrapped[idx][ci] = _wrap_display(cleaned[idx][ci] or "", widths[ci])
      end
    end
  end

  -- 构造边框横线块（块宽 = 列宽 + 2，字符为 ─）
  local function _h_blocks()
    local parts = {}
    for ci = 1, col_count do
      parts[ci] = string.rep("─", widths[ci] + cell_pad_w)
    end
    return parts
  end

  local out = {}
  -- 顶边：┌──┬──┐ 封顶
  local top = _h_blocks()
  out[#out + 1] = { text = "┌" .. table.concat(top, "┬") .. "┐", k = "border" }
  -- 内容行奇偶（用于斑马纹背景）：从表头起算，折行的每个物理行同属一个逻辑行
  local content_n = 0
  for idx = 1, #split do
    if idx == sep_idx then
      -- 表头与数据之间的分隔横线：├──┼──┤
      local mid = _h_blocks()
      out[#out + 1] = { text = "├" .. table.concat(mid, "┼") .. "┤", k = "border" }
    else
      content_n = content_n + 1
      local k = (content_n % 2 == 1) and "odd" or "even"
      local height = 0
      for ci = 1, col_count do
        height = math.max(height, #wrapped[idx][ci])
      end
      for ln = 1, height do
        local parts = {}
        for ci = 1, col_count do
          local line_text = wrapped[idx][ci][ln] or ""
          parts[ci] = " " .. _pad_cell(line_text, widths[ci], aligns[ci]) .. " "
        end
        out[#out + 1] = { text = "│" .. table.concat(parts, "│") .. "│", k = k }
      end
    end
  end
  -- 底边：└──┴──┘ 封底
  local bottom = _h_blocks()
  out[#out + 1] = { text = "└" .. table.concat(bottom, "┴") .. "┘", k = "border" }
  return out
end

-- ========== 公开 API ==========

--- 将 markdown 文本转换为可渲染的行数组
--- @param text string
--- @param opts table|nil { streaming? boolean; table_width? number }
---   streaming=true 时表格原样输出；table_width 限制表格总显示宽度（随窗口自适应）
--- @return table { { text, style, tbl? } } style = "normal"|"code"|"heading"|"list"|"quote"|"table"
function M.render(text, opts)
  opts = opts or {}
  local lines = tm.split_lines(text or "")
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
      local rendered = _render_table(block, opts.streaming, opts.table_width)
      if rendered then
        for _, r in ipairs(rendered) do
          if type(r) == "string" then
            -- 流式期间原样行：仅标记为表格，不变更内容
            out[#out + 1] = { text = r, style = "table" }
          else
            out[#out + 1] = { text = r.text, style = "table", tbl = r.k }
          end
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
--- @param opts table|nil 传给 M.render 的选项
--- @return string
function M.to_plain(text, opts)
  local lines = M.render(text, opts)
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
