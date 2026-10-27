--- 密钥告警弹窗
--- @module 'NeoAI.ui.components.secret_alert'
--- 真实密钥出现在 AI 上下文/工具调用，或向非白名单地址发送密钥时，阻塞 Agent 并请用户确认。
--- 注册到 sandbox.secret_alert。

local geometry = require("NeoAI.ui.geometry")
local services = require("NeoAI.kernel.services")

local M = {}

--- 组件标识：用于单槽位 key 与焦点门控 key 前缀（`secret_alert#<ticket>`）。
local KEY = "secret_alert"

-- ========== 私有状态 ==========

-- 单槽位（ui/consent_slot）保证全局同一时刻只展示一个同意/告警类浮窗。
local state = {
  current = nil, -- { ticket, win_id, buf, decide, has_fake, closing, aucmd }
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
  rec.has_fake = false
  if state.current == rec then state.current = nil end
end

--- 按票据关闭：仅当该票据正是当前展示的窗口时才关（勿误关其它请求的窗）。
--- @param ticket table|nil
local function _close_ticket(ticket)
  local rec = state.current
  if rec and (ticket == nil or rec.ticket == ticket) then _close_win(rec) end
end

--- 窗口被外部关闭（`:q` / `<C-w>c`）：按**安全默认**终止（stop）结算，避免 Deferred 悬挂、
--- 审批中心条目残留（表现为 Herder pane 一直 blocked）。
--- @param rec table
local function _on_win_closed(rec)
  if state.current ~= rec or rec.closing then return end
  local decide, ticket = rec.decide, rec.ticket
  rec.aucmd = nil
  _close_win(rec)
  pcall(function() require("NeoAI.ui.consent_slot").cancel(ticket) end)
  if decide then decide("stop") end
end

--- 截断长文本用于弹窗展示（保留足够辨识信息）
--- @param s any
--- @param n number|nil
--- @return string
local function _short(s, n)
  s = tostring(s or "")
  n = n or 120
  if #s > n then return s:sub(1, n) .. "…（共 " .. #s .. " 字符）" end
  return s
end

--- 构建弹窗文本（同时供测试直接断言）
--- @param ctx table
--- @return table lines
local function _text(ctx)
  ctx = ctx or {}
  local lines = {}
  local has_fake = ctx.fake ~= nil and ctx.fake ~= ""
  if ctx.kind == "egress" then
    lines[#lines + 1] = "⚠ 检测到向非白名单地址发送密钥"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "目标: " .. tostring(ctx.dest or "?")
    if ctx.command then lines[#lines + 1] = "来源命令: " .. _short(ctx.command, 200) end
    if ctx.secret or ctx.secret_preview then
      lines[#lines + 1] = "密钥: " .. _short(ctx.secret or ctx.secret_preview)
    end
  elseif ctx.kind == "context" then
    lines[#lines + 1] = "⚠ AI 上下文中出现真实密钥（沙箱可能已被突破）"
    lines[#lines + 1] = ""
    if ctx.command then lines[#lines + 1] = "来源: " .. _short(ctx.command, 200) end
    lines[#lines + 1] = "密钥: " .. _short(ctx.secret or ctx.secret_preview or "?")
    if has_fake then lines[#lines + 1] = "将替换为假密钥: " .. tostring(ctx.fake) end
  else
    lines[#lines + 1] = "⚠ 工具调用中出现真实密钥（沙箱可能已被突破）"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "来源工具: " .. tostring(ctx.tool or "?")
    if ctx.command then lines[#lines + 1] = "来源命令: " .. _short(ctx.command, 200) end
    lines[#lines + 1] = "密钥: " .. _short(ctx.secret or ctx.secret_preview or "?")
    if has_fake then lines[#lines + 1] = "将替换为假密钥: " .. tostring(ctx.fake) end
  end
  lines[#lines + 1] = ""
  if has_fake then
    lines[#lines + 1] = "快捷键: [回车] 保留真实密钥仅本次允许    [F] 替换为假密钥并继续    [Esc] 停止 Agent"
  elseif ctx.kind == "egress" then
    lines[#lines + 1] = "快捷键: [回车] 仅本次允许    [W] 加入白名单    [Esc] 停止 Agent"
  else
    lines[#lines + 1] = "快捷键: [回车] 仅本次允许    [Esc] 停止 Agent"
  end
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
    bind(mode, "W", function() close_then("whitelist") end)
    bind(mode, "w", function() close_then("whitelist") end)
    if rec.has_fake then
      bind(mode, "F", function() close_then("fake") end)
      bind(mode, "f", function() close_then("fake") end)
    end
    bind(mode, "<Esc>", function() close_then("stop") end)
    bind(mode, "q", function() close_then("stop") end)
  end
end

-- ========== 公开 API ==========

--- 展示告警弹窗（实际建窗）。单槽位保证同一时刻只有一个同意/告警类浮窗。
--- @param ticket table 槽位票据（`ui/consent_slot`）
--- @param ctx table
--- @param decide function(decision)
local function _present(ticket, ctx, decide)
  local slot = require("NeoAI.ui.consent_slot")
  if slot.current() ~= ticket then return end -- 已被取消/让位：不再建窗
  local has_fake = ctx and ctx.fake ~= nil and ctx.fake ~= ""
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neoai_secret_alert"
  local lines = _text(ctx)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
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
    title = "🔑 密钥告警",
    title_pos = "center",
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    -- 建窗失败（如 UI 不可用）：按安全默认终止 Agent，保证请求结算、槽位不卡死。
    if decide then decide("stop") end
    return
  end
  local rec = {
    ticket = ticket, decide = decide, buf = buf, win_id = wid,
    has_fake = has_fake, closing = false,
  }
  state.current = rec
  geometry.track(wid, geom_opts)
  vim.wo[wid].wrap = true
  pcall(vim.cmd, "stopinsert")
  vim.bo[buf].modifiable = false
  slot.mark_presented(ticket)
  -- 外部关窗（`:q` / `<C-w>c`）：按安全默认（stop）结算，避免 Deferred 悬挂、条目残留。
  rec.aucmd = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(wid),
    once = true,
    callback = function() _on_win_closed(rec) end,
  })
  _set_keymaps(rec)
end

--- 展示告警弹窗。**单槽位串行**（`ui/consent_slot`）：与网络/设备/策略同意弹窗共用展示槽位，
--- 任一时刻只展示一个，其余排队——避免多窗叠加、未可见请求的决策回调永久丢失（Herder pane
--- 停留在 blocked）。焦点不在 NeoAI 界面时经 `focus.gate` 暂存，切回后弹出。
--- @param ctx table
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

--- 隐藏弹窗（按票据作用域：只关/只撤销**自己的**窗与暂存）。
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

--- 弹窗当前是否已呈现（与其它同意弹窗对齐：供来源模块区分「已弹出」与「暂存待弹/排队中」）。
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

--- 注册到 sandbox.secret_alert。
--- 沙箱服务属 phase 2、UI 属 phase 1：UI 初始化时 `services.sandbox` 往往尚未就绪，
--- 直接 `use` 会拿到 nil 而静默跳过注册。经 `services.wait` 延迟登记（已就绪则立即回调），
--- 保证弹窗 UI 最终一定注册，避免真密钥告警回退到 nvim 原生 `vim.fn.confirm`。
function M.init()
  if state.unwait then state.unwait() end
  state.unwait = services.wait("services.sandbox", function(sandbox)
    if sandbox and sandbox.set_secret_alert_ui then
      sandbox.set_secret_alert_ui({ show = M.show, hide = M.hide, is_open = M.is_open })
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
    if sandbox and sandbox.set_secret_alert_ui then sandbox.set_secret_alert_ui(nil) end
  end)
end

--- 构建弹窗文本（测试用）
--- @param ctx table
--- @return table
function M._text(ctx)
  return _text(ctx)
end

return M
