--- 复用流式悬浮窗
--- @module 'NeoAI.ui.components.float_stream_window'
--- 在独立浮动窗口实时展示流式内容，支持替换 / 追加 / 关闭。
--- 供思考过程（reasoning_panel）、接收参数（tool_args_panel）、
--- 上下文压缩 / 计划蒸馏（chat_view 直接使用）等共享同一个窗口实例。
--- 各消费者通过 open(title, {filetype = ...}) 复用切换，互不重叠。
--- 思考过程与接收参数均走 append 增量追加（逐片追加，不整段重排）。

local geometry = require("NeoAI.ui.geometry")

-- 多实例：每个聊天实例持有**独立**的流式悬浮窗（各自 win/buf/filetype），互不干扰。
-- 由 _make() 闭包工厂构造；模块表是「当前悬浮窗」代理（兼容既有调用与测试）。
local function _make()
  local M = {}

  -- ========== 私有状态 ==========

  local state = {
    win_id = nil,
    buf = nil,
    filetype = nil,
    -- 当前消费者的高度上限（nil = 使用默认上限）；由 open 传入 max_height 时按 filetype 更新。
    max_height = nil,
  }

-- ========== 私有函数 ==========

--- 窗口高度上限：内容变长时自动增高，避免长摘要被截断。
--- 依屏幕相对比例（h_ratio=0.6，受最小留白约束）计算，而非像素硬编码。
--- @return number
local function _max_height()
  return math.max(6, geometry.compute({ h_ratio = 0.6 }).height)
end

--- 当前内容的显示行数（考虑 wrap 折行）。buffer 行数在 wrap 开启时低估了实际占用行数，
--- 长单行（如工具参数 JSON）会被折成多行，用 nvim_win_text_height 取真实行高，
--- 旧版本无该 API 时回退到 buffer 行数。
--- @return number
local function _content_rows()
  local ok, h = pcall(vim.api.nvim_win_text_height, state.win_id, { start_row = 0, end_row = -1 })
  if ok and type(h) == "table" and h.all then return h.all end
  return vim.api.nvim_buf_line_count(state.buf)
end

--- 依据当前内容行数自动调整窗口高度（内容变长增高，至多到上限；不主动缩小）
local function _maybe_grow()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  -- 消费者可指定高度上限（如思考过程/接收参数限 5 行）；未指定时用默认上限。
  local max_h = state.max_height or _max_height()
  local base = math.min(6, max_h)
  -- 以显示行数（含 wrap 折行）为准：长单行也能把窗口撑到足够高度。
  local rows = math.max(vim.api.nvim_buf_line_count(state.buf), _content_rows())
  local h = math.max(base, math.min(max_h, rows + 1))
  local cfg = vim.api.nvim_win_get_config(state.win_id)
  pcall(vim.api.nvim_win_set_config, state.win_id, {
    width = cfg.width,
    height = h,
  })
end

--- 本窗的 compute 参数（宽度按屏宽比例，高度取内容自适应上限）——供开窗与 resize 跟随共用。
--- @return table
local function _geom_opts()
  return { w_ratio = 0.70, h_ratio = 0.60, fit_h = state.max_height or 6, anchor = "top", row = 2 }
end

--- resize 跟随的自定义 apply：先按新屏宽重算 width/col/row（及高度兜底），
--- 再复用内容自适应逻辑重算高度，避免固定高度覆盖流式内容的自适应结果。
--- @param win number
--- @param g table { width, height, col, row }
local function _apply_resize(win, g)
  pcall(vim.api.nvim_win_set_config, win, {
    relative = "editor",
    width = g.width,
    height = g.height,
    col = g.col,
    row = g.row,
  })
  _maybe_grow()
end

--- 把光标移到内容末尾（末行末列）并让末行贴到窗口底部。
--- 仅 set_cursor 到最后一行首列时，wrap 开启下长单行只显示开头（光标在行首，
--- nvim 不会滚动到行尾），必须把光标移到末行末列（内容末尾），光标可见性才能驱动
--- 视口滚到尾部；再 zb 把末行平移到窗口底部。
local function _scroll_to_end()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  vim.api.nvim_win_call(state.win_id, function()
    vim.cmd("silent! normal! G$")
    vim.cmd("silent! normal! zb")
  end)
end

--- 应用内容（替换整段）
--- @param text string
local function _set_text(text)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
  -- 先增高再滚：否则增高会把末行顶离窗口底部，_scroll_to_end 之后又不再触发滚动。
  _maybe_grow()
  _scroll_to_end()
end

-- ========== 公开 API ==========

--- 打开悬浮窗
--- @param title string|nil
--- @param opts table|nil { filetype?, max_height? } max_height 为高度上限（nil = 默认）
--- @return number win_id
function M.open(title, opts)
  opts = opts or {}
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    -- 复用已有窗口：切换标题与文件类型（供 reasoning / tool_args / compaction 共享）。
    -- 仅在显式给出 filetype 时同步高度上限，避免内部 open()（append/set_text）清掉消费者设置。
    if opts.filetype then
      state.filetype = opts.filetype
      state.max_height = opts.max_height
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        vim.bo[state.buf].filetype = opts.filetype
      end
      -- 高度上限随消费者变化，同步更新 resize 跟随参数。
      geometry.track(state.win_id, _geom_opts(), _apply_resize)
    end
    if title then
      pcall(vim.api.nvim_win_set_config, state.win_id, { title = title })
    end
    return state.win_id
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  state.filetype = opts.filetype
  state.max_height = opts.max_height
  if opts.filetype then
    vim.bo[state.buf].filetype = opts.filetype
  end
  -- 初始高度：消费者上限（或默认 6）与屏高比例上限取小；宽度按屏宽比例。
  local geom_opts = _geom_opts()
  local geom = geometry.compute(geom_opts)
  state.win_id = vim.api.nvim_open_win(state.buf, false, {
    relative = "editor",
    width = geom.width,
    height = geom.height,
    col = geom.col,
    row = geom.row,
    style = "minimal",
    border = "rounded",
    title = title or "",
    title_pos = "center",
  })
  geometry.track(state.win_id, geom_opts, _apply_resize)
  vim.wo[state.win_id].wrap = true
  -- 开启平滑滚动：wrap 下长行会折成多个屏幕行，光标停在逻辑行首位时无法把折行的尾部
  -- 滚入视口（末行会停在窗口中部以下无内容可滚）。smoothscroll 让 <C-e>/zb 能按屏幕行
  -- 滚动，从而把长单行的尾部显示出来（Neovim 0.10+，旧版本 pcall 忽略）。
  pcall(function() vim.wo[state.win_id].smoothscroll = true end)
  -- 最小化浮窗会继承全局 foldenable/foldmethod（如 indent + foldenable），
  -- 导致内容被自动收起而看不到，这里统一关闭。
  vim.wo[state.win_id].foldenable = false
  vim.wo[state.win_id].foldmethod = "manual"
  vim.wo[state.win_id].foldcolumn = "0"
  return state.win_id
end

--- 替换展示内容
--- @param text string
function M.set_text(text)
  M.open()
  _set_text(text)
end

--- 追加内容（流式分片可能从一行中间开始，先续接已有末行，再追加其余新行）
--- @param text string
function M.append(text)
  if not text or text == "" then return end
  M.open()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local line_count = vim.api.nvim_buf_line_count(state.buf)
  local lines = vim.split(text, "\n", { plain = true })
  lines[1] = vim.api.nvim_buf_get_lines(state.buf, line_count - 1, line_count, false)[1] .. lines[1]
  vim.api.nvim_buf_set_lines(state.buf, line_count - 1, line_count, false, lines)
  -- 先增高再滚（同 _set_text）：保证末行最终贴到窗口底部。
  _maybe_grow()
  _scroll_to_end()
end

--- 当前展示文本（测试用）
--- @return string
function M.get_text()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
end

--- 当前窗口的 filetype（用于消费者判断是否仍是自己占用的窗口）
--- @return string|nil
function M.get_filetype()
  if not M.is_open() then return nil end
  return state.filetype
end

--- 关闭悬浮窗
function M.close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  geometry.untrack(state.win_id)
  state.win_id = nil
  state.buf = nil
  state.filetype = nil
  state.max_height = nil
end

--- 是否打开
--- @return boolean
function M.is_open()
  return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
end

--- 重置（测试用）
function M.reset()
  M.close()
end

  return M
end

-- ========== 模块级：当前悬浮窗代理（兼容既有调用 / 测试） ==========

local M = {}
local _current = nil

--- 新建一个独立悬浮窗实例，并设为「当前」。
--- @return table
function M.new()
  local inst = _make()
  _current = inst
  return inst
end

--- 直接指定「当前」悬浮窗实例。
--- @param inst table
function M._set_current(inst)
  if inst then _current = inst end
end

--- 当前悬浮窗实例。
--- @return table
local function _cur()
  if not _current then _current = _make() end
  return _current
end

for _, name in ipairs({
  "open", "set_text", "append", "get_text", "get_filetype", "close", "is_open", "reset",
}) do
  M[name] = function(...)
    local cur = _cur()
    if cur and type(cur[name]) == "function" then return cur[name](...) end
  end
end

return M
