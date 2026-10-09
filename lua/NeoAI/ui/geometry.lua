--- 浮窗几何计算：按屏幕相对比例得出尺寸与居中/贴边位置（消除像素硬编码）
--- @module NeoAI.ui.geometry
---
--- 所有弹窗/悬浮窗共用本模块，依当前屏幕（vim.o.columns × vim.o.lines）的相对比例计算
--- width/height/col/row，保证大小屏表现一致；内容自适应弹窗用 fit_h 把高度压到内容所需
--- （但仍受比例上限约束）。避免各处散落 `math.min(70, vim.o.columns - 10)` 之类的像素常量。

local M = {}

--- 当前屏幕尺寸（行列数）
--- @return number cols
--- @return number lines
local function _screen()
  return vim.o.columns, vim.o.lines
end

--- 计算浮窗几何。
--- @param opts table|nil {
---   w_ratio? number 宽度占屏幕列比例（如 0.7）
---   h_ratio? number 高度占屏幕行比例（如 0.6）
---   fit_h? number   内容所需高度：与实际高度取较小值（内容自适应；仅压不撑）
---   min_w? number   宽度下限（单元格）
---   max_w? number   宽度上限（单元格）
---   min_h? number   高度下限（单元格）
---   max_h? number   高度上限（单元格）
---   margin? number  距屏幕边缘最小留白（默认 2），保证不贴边/不越界
---   anchor? string  "center"（默认）| "top" | "bottom"，决定纵向位置
---   row? number     显式指定顶部行号（0-based），覆盖 anchor
--- }
--- @return table { width, height, col, row }
function M.compute(opts)
  opts = opts or {}
  local cols, lines = _screen()

  local margin = tonumber(opts.margin) or 2
  -- 极端小屏兜底：margin 不超过屏幕一半，避免可用空间为负。
  margin = math.max(0, math.min(margin, math.floor(cols / 2), math.floor(lines / 2)))

  local avail_w = math.max(1, cols - margin * 2)
  local avail_h = math.max(1, lines - margin * 2)

  -- 宽度：比例 → 屏幕可用宽 → min/max → 夹紧
  local width = math.floor(cols * (tonumber(opts.w_ratio) or 0.6))
  width = math.min(width, avail_w)
  if type(opts.max_w) == "number" then width = math.min(width, opts.max_w) end
  if type(opts.min_w) == "number" then width = math.max(width, opts.min_w) end
  width = math.max(1, math.min(width, avail_w))

  -- 高度：比例 → 屏幕可用高 → fit_h（内容自适应，仅压不撑）→ min/max → 夹紧
  local height = math.floor(lines * (tonumber(opts.h_ratio) or 0.6))
  if type(opts.fit_h) == "number" then height = math.min(height, opts.fit_h) end
  height = math.min(height, avail_h)
  if type(opts.max_h) == "number" then height = math.min(height, opts.max_h) end
  if type(opts.min_h) == "number" then height = math.max(height, opts.min_h) end
  height = math.max(1, math.min(height, avail_h))

  local col = math.floor((cols - width) / 2)
  col = math.max(0, math.min(col, cols - width))

  local row
  if type(opts.row) == "number" then
    row = opts.row
  else
    local anchor = opts.anchor or "center"
    if anchor == "top" then
      row = margin
    elseif anchor == "bottom" then
      row = lines - height - margin
    else
      row = math.floor((lines - height) / 2)
    end
  end
  row = math.max(0, math.min(row, math.max(0, lines - height)))

  return { width = width, height = height, col = col, row = row }
end

return M
