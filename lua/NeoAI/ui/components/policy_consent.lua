--- 沙箱策略确认弹窗（代理规避等）
--- @module 'NeoAI.ui.components.policy_consent'
--- 与网络同意 / 工具审批 / 设备同意同款浮窗（圆角 + 按键提示 + 焦点门控）。
--- 注册到 `sandbox.policy_consent`（`sandbox/review/policy_consent.set_ui`）；同步阻塞由来源模块
--- 用 `vim.wait` 驱动，本组件只负责渲染与按键回调。

local geometry = require("NeoAI.ui.geometry")
local services = require("NeoAI.kernel.services")

local M = {}

--- 组件标识：用于单槽位 key 与焦点门控 key 前缀（`policy_consent#<ticket>`）。
local KEY = "policy_consent"

-- ========== 私有状态 ==========

-- 单槽位（ui/consent_slot）保证全局同一时刻只展示一个同意类浮窗。
local state = {
  current = nil, -- { ticket, win_id, buf, decide, closing, aucmd }
  unwait = nil, -- services.wait 取消句柄（延迟注册）
}

-- ========== 私有函数 ==========

--- 关掉一个窗口记录（幂等；先删 WinClosed 监听再关窗，避免自己触发「外部关窗」）。
--- @param rec table|nil
local function _close_win(rec)
  if not rec then return end
  rec.closing = true
  if rec.aucmd then
    pcall(vim.api.nvim_del_autocmd, rec.aucmd)
    rec.aucmd = nil
  end
  if rec.win_id and vim.api.nvim_win_is_valid(rec.win_id) then
    pcall(vim.api.nvim_win_close, rec.win_id, true)
  end
  geometry.untrack(rec.win_id)
  rec.win_id = nil
  rec.buf = nil
  if state.current == rec then state.current = nil end
end

--- 按票据关闭：仅当该票据正是当前展示的窗口时才关（勿误关其它请求的窗）。
--- @param ticket table|nil
local function _close_ticket(ticket)
  local rec = state.current
  if rec and (ticket == nil or rec.ticket == ticket) then _close_win(rec) end
end

--- 窗口被外部关闭（`:q` / `<C-w>c`）：按安全默认拒绝结算，避免 Deferred 悬挂、
--- 审批中心条目残留（表现为 Herder pane 一直 blocked）。
--- @param rec table
local function _on_win_closed(rec)
  if state.current ~= rec or rec.closing then return end
  local decide, ticket = rec.decide, rec.ticket
  rec.aucmd = nil
  _close_win(rec)
  pcall(function() require("NeoAI.ui.consent_slot").cancel(ticket) end)
  if decide then decide("deny") end
end

--- 单行化（浮窗内容不接受换行）
--- @param s any
--- @return string
local function _one_line(s)
  if s == nil then return "" end
  return (tostring(s):gsub("[\r\n]", " "))
end

--- 拼合窗口行（不做字节级折行——按字节 `sub` 会切断多字节 UTF-8 字符导致乱码；交由窗口
--- `wrap`/`linebreak` 按显示宽度换行）。`ctx.detail` 可为字符串或行数组。
--- @param ctx table { title?, detail? }
--- @return table
local function _text(ctx)
  local lines = {}
  lines[#lines + 1] = "⚠ 沙箱策略确认"
  lines[#lines + 1] = ""
  if ctx.title and ctx.title ~= "" then lines[#lines + 1] = _one_line(ctx.title) end
  local detail = ctx.detail
  local extra = {}
  if type(detail) == "table" then
    for _, l in ipairs(detail) do extra[#extra + 1] = _one_line(l) end
  elseif type(detail) == "string" and detail ~= "" then
    extra[#extra + 1] = _one_line(detail)
  end
  if #extra > 0 then
    lines[#lines + 1] = ""
    for _, l in ipairs(extra) do lines[#lines + 1] = l end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "快捷键: [回车] 仅本次允许    [S] 本次会话始终允许    [Esc] 拒绝"
  return lines
end

local function _set_keymaps(rec)
  if not rec.buf then return end
  local function bind(mode, key, fn)
    vim.keymap.set(mode, key, fn, { buffer = rec.buf })
  end
  --- 决策：先关自己的窗并让出槽位（下一个排队请求立刻展示），再回调决策。
  local function close_then(decision)
    local decide, ticket = rec.decide, rec.ticket
    _close_win(rec)
    pcall(function() require("NeoAI.ui.consent_slot").release(ticket) end)
    if decide then decide(decision) end
  end
  for _, mode in ipairs({ "n", "i" }) do
    bind(mode, "<CR>", function() close_then("allow_once") end)
    bind(mode, "S", function() close_then("allow_session") end)
    bind(mode, "s", function() close_then("allow_session") end)
    bind(mode, "<Esc>", function() close_then("deny") end)
    bind(mode, "q", function() close_then("deny") end)
  end
end

-- ========== 公开 API ==========

--- 展示策略确认弹窗（实际建窗）。单槽位保证同一时刻只有一个同意类浮窗。
--- @param ticket table 槽位票据（`ui/consent_slot`）
--- @param ctx table { title?, detail? }
--- @param decide function(decision: "allow_once"|"allow_session"|"deny")
local function _present(ticket, ctx, decide)
  local slot = require("NeoAI.ui.consent_slot")
  if slot.current() ~= ticket then return end -- 已被取消/让位：不再建窗
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neoai_policy_consent"
  local lines = _text(ctx)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- 内容自适应高度：按显示宽度折行后适配（CJK 按 2 列），避免长标题/命令被截断。
  local geom_opts = { w_ratio = 0.60, h_ratio = 0.40, fit_lines = lines, fit_pad = 2 }
  local geom = geometry.compute(geom_opts)
  local ok, wid = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = geom.width,
    height = geom.height,
    col = geom.col,
    row = geom.row,
    style = "minimal",
    border = "rounded",
    title = "⚠ 沙箱策略确认",
    title_pos = "center",
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    -- 建窗失败（如 UI 不可用）：按安全默认拒绝，保证请求结算、槽位不卡死。
    if decide then decide("deny") end
    return
  end
  local rec = { ticket = ticket, decide = decide, buf = buf, win_id = wid, closing = false }
  state.current = rec
  geometry.track(wid, geom_opts)
  vim.wo[wid].wrap = true
  vim.wo[wid].linebreak = true
  pcall(vim.cmd, "stopinsert")
  vim.bo[buf].modifiable = false
  slot.mark_presented(ticket)
  -- 外部关窗（`:q` / `<C-w>c`）：按安全默认拒绝结算，避免 Deferred 悬挂、条目残留。
  rec.aucmd = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(wid),
    once = true,
    callback = function() _on_win_closed(rec) end,
  })
  _set_keymaps(rec)
end

--- 展示弹窗。**单槽位串行**（`ui/consent_slot`）：与密钥/网络/设备弹窗共用展示槽位，
--- 任一时刻只展示一个，其余排队——避免多窗叠加、未可见请求的决策回调永久丢失（Herder pane
--- 停留在 blocked）。**聊天界面焦点门控**（`focus.gate`）：当前窗口是 NeoAI 界面时立即弹出，
--- 否则暂存待切回再弹（审批中心仍可直接决策）。
--- @param ctx table { title?, detail? }
--- @param decide function(decision)
--- @return table ticket 票据（`state.ui.hide/is_open` 按票据作用域生效）
function M.show(ctx, decide)
  local slot = require("NeoAI.ui.consent_slot")
  local focus = require("NeoAI.ui.focus")
  return slot.acquire({
    key = KEY,
    open = function(ticket)
      focus.gate(KEY .. "#" .. ticket.id, function() _present(ticket, ctx, decide) end)
    end,
    close = function(ticket) _close_ticket(ticket) end,
  })
end

--- 隐藏弹窗（按票据作用域：只关/只撤销**自己的**窗与暂存，不误关其它请求的窗）。
--- 无参调用为旧契约兼容路径：关闭本组件当前窗口并丢弃本组件全部暂存。
--- @param ticket table|nil
function M.hide(ticket)
  local slot = require("NeoAI.ui.consent_slot")
  local focus = require("NeoAI.ui.focus")
  if type(ticket) ~= "table" then
    focus.cancel_gate_prefix(KEY .. "#")
    local rec = state.current
    if rec then slot.cancel(rec.ticket) end
    return
  end
  focus.cancel_gate(KEY .. "#" .. tostring(ticket.id))
  slot.cancel(ticket)
end

--- 弹窗当前是否已呈现（供策略模块区分「已弹出」与「暂存待弹/排队中」：仅前者到时自动拒绝）。
--- 令牌作用域：仅当**该票据**的窗口确实在展示时返回 true。
--- @param ticket table|nil
--- @return boolean
function M.is_open(ticket)
  local rec = state.current
  if type(ticket) == "table" then
    if ticket.suppressed then
      local oks, slot = pcall(require, "NeoAI.ui.consent_slot")
      return oks and slot.is_presented(ticket) or false
    end
    if not (rec and rec.ticket == ticket) then return false end
  end
  return rec ~= nil and rec.win_id ~= nil and vim.api.nvim_win_is_valid(rec.win_id)
end

--- 注册到 sandbox.policy_consent。
--- 沙箱服务属 phase 2、UI 属 phase 1：UI 初始化时沙箱尚未就绪，经 `services.wait` 延迟登记。
function M.init()
  if state.unwait then state.unwait() end
  state.unwait = services.wait("services.sandbox", function(sandbox)
    if sandbox and sandbox.set_policy_consent_ui then
      sandbox.set_policy_consent_ui({ show = M.show, hide = M.hide, is_open = M.is_open })
    end
  end)
end

--- 重置（测试用）
function M.reset()
  _close_ticket(nil)
  pcall(function() require("NeoAI.ui.focus").cancel_gate_prefix(KEY .. "#") end)
  pcall(function() require("NeoAI.ui.consent_slot").reset() end)
  if state.unwait then
    pcall(state.unwait)
    state.unwait = nil
  end
  pcall(function()
    local sandbox = services.use("services.sandbox")
    if sandbox and sandbox.set_policy_consent_ui then sandbox.set_policy_consent_ui(nil) end
  end)
end

return M
