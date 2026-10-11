--- 子 Agent 列表弹出窗
--- @module 'NeoAI.ui.components.sub_agent_list'
--- 在聊天窗口顶部（winbar 显示子 Agent 名字处）下方弹出一个**无边框**悬浮窗，列出当前会话
--- 的所有子 Agent。↑/↓（k/j）移动光标，<CR> 在新窗口进入对应子 Agent 会话，q/<Esc> 关闭。
--- 浮窗相对聊天主窗口定位，编辑器/窗口尺寸变化时重算几何（宽度/高度/位置）跟随。

local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")
local services = require("NeoAI.kernel.services")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win = nil,
  buf = nil,
  anchor = nil, -- 聊天主窗口（定位基准）
  agent = nil, -- 打开时捕获的会话 Agent
  entries = {}, -- 子 Agent 条目数组
  lines = {}, -- 渲染行
  sel = 1,
  prev_win = nil, -- 打开前的焦点窗口（关闭时恢复）
  unsubs = {},
  augroup = nil,
}

local ICON = { running = "⏳", completed = "✅", error = "❌", cancelled = "⏹" }

-- 相对聊天窗口的定位微调：向右 2 格、向上 1 格（紧贴 winbar 名字处）
local ROW_OFFSET = -1
local COL_OFFSET = 2

-- ========== 私有函数 ==========

--- 查找聊天主窗口（buffer filetype == "neoai"）
--- @return number|nil
local function _chat_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == "neoai" then return w end
  end
  return nil
end

--- 采集当前会话的子 Agent
local function _refresh_entries()
  local entries = {}
  local agent = state.agent
  if agent then
    local ok, manager = pcall(require, "NeoAI.core.agent.sub_agent")
    if ok and manager then entries = manager.list_for(agent.id) end
  end
  state.entries = entries
  local lines = {}
  for _, e in ipairs(entries) do
    lines[#lines + 1] = string.format("%s %s", ICON[e.status] or "•", e.name or e.id)
  end
  if #lines == 0 then lines[1] = "（无子 Agent）" end
  state.lines = lines
  if state.sel > #entries then state.sel = math.max(1, #entries) end
end

--- 内容所需宽度（最长行显示宽度 + 内边距）
--- @return number
local function _content_width()
  local w = 0
  for _, l in ipairs(state.lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  return w + 2
end

--- 计算浮窗几何（相对聊天主窗口顶部居中，紧贴 winbar 下方）
--- @return number|nil width, number|nil height, number|nil col
local function _metrics()
  local anchor = state.anchor
  if not anchor or not vim.api.nvim_win_is_valid(anchor) then return nil end
  local aw = vim.api.nvim_win_get_width(anchor)
  local ah = vim.api.nvim_win_get_height(anchor)
  local maxw = math.max(12, aw - 2)
  local width = math.max(12, math.min(_content_width(), maxw))
  width = math.min(width, math.max(1, aw))
  local height = math.max(1, math.min(#state.lines, math.max(1, ah - 1)))
  -- 顶部居中（在 winbar 显示子 Agent 名字处正下方弹出），再向右 2 格
  local col = math.max(0, math.floor((aw - width) / 2) + COL_OFFSET)
  return width, height, col
end

--- 写回/更新浮窗几何（开窗与 resize 共用）
local function _apply_geometry()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  if not state.anchor or not vim.api.nvim_win_is_valid(state.anchor) then
    -- 定位基准（聊天主窗口）已关闭：一并关闭列表
    M.close({ restore = false })
    return
  end
  local width, height, col = _metrics()
  if not width then return end
  pcall(vim.api.nvim_win_set_config, state.win, {
    relative = "win", win = state.anchor, anchor = "NW",
    row = ROW_OFFSET, col = col, width = width, height = height,
    style = "minimal", border = "none", zindex = 60,
  })
end

--- 把光标移到当前选中行
local function _set_cursor()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local n = math.max(1, math.min(state.sel, math.max(1, #state.lines)))
  pcall(vim.api.nvim_win_set_cursor, state.win, { n, 0 })
end

--- 渲染缓冲内容
local function _render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, state.lines)
  vim.bo[state.buf].modifiable = false
  _set_cursor()
end

--- 移动选中
--- @param delta number
local function _move(delta)
  local count = #state.entries
  if count == 0 then return end
  state.sel = math.max(1, math.min(count, state.sel + delta))
  _set_cursor()
end

--- 进入选中的子 Agent 会话（新窗口）
local function _enter()
  local e = state.entries[state.sel]
  if not e then return end
  if not e.session_id then
    vim.notify("[NeoAI] 子 Agent 会话不可用", vim.log.levels.WARN)
    return
  end
  M.close({ restore = false })
  require("NeoAI.ui.window.chat_view").open({ new_window = true, session_id = e.session_id })
end

--- 绑定浮窗按键
local function _bind_keys()
  local b = state.buf
  local function map(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = b, nowait = true }) end
  map("j", function() _move(1) end)
  map("<Down>", function() _move(1) end)
  map("k", function() _move(-1) end)
  map("<Up>", function() _move(-1) end)
  map("<CR>", _enter)
  map("q", function() M.close() end)
  map("<Esc>", function() M.close() end)
end

--- 订阅子 Agent 事件，运行中打开也实时刷新
local function _subscribe()
  local function refresh()
    _refresh_entries()
    _render()
    _apply_geometry()
  end
  for _, ev in ipairs({
    events.SUB_AGENT_CREATED, events.SUB_AGENT_UPDATED,
    events.SUB_AGENT_COMPLETED, events.SUB_AGENT_ERROR,
  }) do
    state.unsubs[#state.unsubs + 1] = event_bus.on(ev, refresh)
  end
end

local function _unsubscribe()
  for _, u in ipairs(state.unsubs) do
    if u then pcall(u) end
  end
  state.unsubs = {}
end

--- 监听窗口尺寸变化，重算浮窗几何（相对聊天窗口定位）
local function _ensure_augroup()
  if state.augroup then return end
  local ok, grp = pcall(vim.api.nvim_create_augroup, "NeoAISubAgentList", { clear = true })
  if not ok then return end
  state.augroup = grp
  pcall(vim.api.nvim_create_autocmd, "VimResized", {
    group = grp,
    callback = function() _apply_geometry() end,
  })
  pcall(vim.api.nvim_create_autocmd, "WinResized", {
    group = grp,
    callback = function() _apply_geometry() end,
  })
end

local function _del_augroup()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

-- ========== 公开 API ==========

--- 打开（已开则刷新）子 Agent 列表弹出窗
--- @return number|nil win_id
function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    _refresh_entries()
    _render()
    _apply_geometry()
    return state.win
  end
  local anchor = _chat_win()
  if not anchor then
    vim.notify("[NeoAI] 请先打开聊天窗口", vim.log.levels.WARN)
    return nil
  end
  local chat_service = services.use("services.chat_service")
  if not chat_service then
    vim.notify("[NeoAI] 聊天服务未就绪", vim.log.levels.WARN)
    return nil
  end
  state.anchor = anchor
  state.agent = chat_service.get_agent_for_buffer(vim.api.nvim_win_get_buf(anchor))
  state.prev_win = vim.api.nvim_get_current_win()
  state.sel = 1
  _refresh_entries()

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_sub_agent_list"
  vim.bo[state.buf].bufhidden = "wipe"
  _render()

  local width, height, col = _metrics()
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "win", win = anchor, anchor = "NW",
    row = ROW_OFFSET, col = col, width = width, height = height,
    style = "minimal", border = "none", zindex = 60,
  })
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].wrap = false
  vim.wo[state.win].number = false
  vim.wo[state.win].signcolumn = "no"
  _bind_keys()
  _subscribe()
  _ensure_augroup()
  _set_cursor()
  return state.win
end

--- 关闭弹出窗
--- @param opts table|nil { restore? boolean 是否恢复原焦点窗口（默认 true） }
function M.close(opts)
  opts = opts or {}
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  _unsubscribe()
  _del_augroup()
  state.win, state.buf = nil, nil
  state.entries, state.lines, state.sel = {}, {}, 1
  local prev = state.prev_win
  state.prev_win = nil
  state.anchor, state.agent = nil, nil
  if opts.restore ~= false and prev and vim.api.nvim_win_is_valid(prev) then
    pcall(vim.api.nvim_set_current_win, prev)
  end
end

--- 切换（开/关）
function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

--- 是否打开
--- @return boolean
function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- 重置（测试/卸载用）
function M.reset()
  M.close({ restore = false })
  state.entries, state.lines, state.sel = {}, {}, 1
end

return M
