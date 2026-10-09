--- 浮窗几何计算：按屏幕相对比例得出尺寸与居中/贴边位置（消除像素硬编码）
--- @module NeoAI.ui.geometry
---
--- 所有弹窗/悬浮窗共用本模块，依当前屏幕（vim.o.columns × vim.o.lines）的相对比例计算
--- width/height/col/row，保证大小屏表现一致；内容自适应弹窗用 fit_h 把高度压到内容所需
--- （但仍受比例上限约束）。避免各处散落 `math.min(70, vim.o.columns - 10)` 之类的像素常量。
---
--- 另设全局最小尺寸兜底（`ui.float.min_width/min_height`，默认 24/4），避免小窗口下浮窗
--- 过窄过矮导致渲染糟糕；并暴露 `track/untrack/refresh/reset` 让已打开的浮窗在编辑器窗口
--- 尺寸变化（VimResized）时实时重算跟随。

local M = {}

--- 全局最小尺寸兜底（单元格）。可被配置 `ui.float.min_width/min_height` 覆盖；
--- 单个 `compute` 调用可用显式 `min_w/min_h` 覆盖，传 0 解除默认下限。
M.MIN_WIDTH = 24
M.MIN_HEIGHT = 4

--- 解析最小尺寸：优先读配置 `ui.float.<key>`，失败/非法时回退到给定默认。
--- @param key string "min_width" | "min_height"
--- @param fallback number
--- @return number
local function _resolve_min(key, fallback)
  local ok, v = pcall(function()
    return require("NeoAI.kernel.config_store").get("ui.float." .. key)
  end)
  local n = ok and tonumber(v) or nil
  if n and n >= 0 then return math.floor(n) end
  return fallback
end

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

  -- 默认最小尺寸（全局兜底，可由 ui.float 覆盖）：显式 min_w/min_h 优先，传 0 解除。
  local def_min_w = _resolve_min("min_width", M.MIN_WIDTH)
  local def_min_h = _resolve_min("min_height", M.MIN_HEIGHT)

  -- 宽度：比例 → 屏幕可用宽 → 全局最小 → max_w → min_w → 夹紧
  local width = math.floor(cols * (tonumber(opts.w_ratio) or 0.6))
  width = math.min(width, avail_w)
  if type(opts.max_w) == "number" then width = math.min(width, opts.max_w) end
  local min_w = type(opts.min_w) == "number" and opts.min_w or def_min_w
  if min_w > 0 then width = math.max(width, min_w) end
  width = math.max(1, math.min(width, avail_w))

  -- 高度：比例 → fit_h（内容自适应，仅压不撑）→ 屏幕可用高 → 全局最小 → max_h → min_h → 夹紧
  local height = math.floor(lines * (tonumber(opts.h_ratio) or 0.6))
  if type(opts.fit_h) == "number" then height = math.min(height, opts.fit_h) end
  height = math.min(height, avail_h)
  if type(opts.max_h) == "number" then height = math.min(height, opts.max_h) end
  local min_h = type(opts.min_h) == "number" and opts.min_h or def_min_h
  if min_h > 0 then height = math.max(height, min_h) end
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

-- ========== resize 跟随 ==========

-- 已登记的浮窗：win_id -> { opts = compute 参数, apply = 自定义应用函数|nil }
-- VimResized 时按最新屏幕尺寸重算并应用（不改变 compute 语义）。
local tracked = {}
local resize_augroup = nil

--- 懒创建 VimResized 自动命令组（仅在有窗口登记时才安装）。
local function _ensure_augroup()
  if resize_augroup then return end
  resize_augroup = vim.api.nvim_create_augroup("NeoAIFloatResize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = resize_augroup,
    callback = function() M.refresh() end,
  })
end

--- 默认应用：把重算后的几何写回窗口（保持相对 editor 与既有边框/title）。
--- @param win number
--- @param g table { width, height, col, row }
local function _default_apply(win, g)
  pcall(vim.api.nvim_win_set_config, win, {
    relative = "editor",
    width = g.width,
    height = g.height,
    col = g.col,
    row = g.row,
  })
end

--- 登记窗口，使其在编辑器窗口 resize 时跟随重算。
--- 注意：登记时**不立即应用**几何（调用方刚按同一参数开好窗），仅 VimResized 时生效，
--- 避免覆盖内容自适应窗口（如流式窗）已计算好的高度。
--- @param win number 窗口句柄
--- @param opts table|nil 与开窗时相同的 `compute` 参数
--- @param apply function|nil 自定义应用函数 `function(win, geom)`；缺省写回 width/height/col/row
function M.track(win, opts, apply)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  tracked[win] = { opts = vim.deepcopy(opts or {}), apply = apply }
  _ensure_augroup()
end

--- 注销窗口的 resize 跟随。
--- @param win number
function M.untrack(win)
  if win then tracked[win] = nil end
end

--- 按当前屏幕尺寸重算并应用所有已登记窗口的几何；自动清理已失效的窗口。
function M.refresh()
  for win, rec in pairs(tracked) do
    if not vim.api.nvim_win_is_valid(win) then
      tracked[win] = nil
    else
      local g = M.compute(rec.opts)
      if rec.apply then
        pcall(rec.apply, win, g)
      else
        _default_apply(win, g)
      end
    end
  end
end

--- 清空登记并卸载 VimResized 自动命令（测试/卸载用）。
function M.reset()
  tracked = {}
  if resize_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, resize_augroup)
    resize_augroup = nil
  end
end

return M
