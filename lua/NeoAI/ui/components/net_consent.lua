--- 网络访问同意弹窗
--- @module 'NeoAI.ui.components.net_consent'
--- 沙箱内进程/端口在沙箱内访问免权限；访问沙箱外部（宿主本机其他端口、外部主机）时
--- 阻塞并请用户确认。注册到 sandbox.net_consent。

local geometry = require("NeoAI.ui.geometry")
local services = require("NeoAI.kernel.services")

local M = {}

--- 组件标识：用于单槽位 key 与焦点门控 key 前缀（`net_consent#<ticket>`）。
local KEY = "net_consent"

-- ========== 私有状态 ==========

-- 单槽位（ui/consent_slot）保证全局同一时刻只展示一个同意类浮窗，故这里只保留当前窗口记录。
local state = {
  current = nil, -- { ticket, win_id, buf, decide, closing, aucmd } 当前展示的窗口
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

--- 按票据关闭：仅当该票据正是当前展示的窗口时才关（票据作用域，勿误关他人窗口）。
--- @param ticket table|nil
local function _close_ticket(ticket)
  local rec = state.current
  if rec and (ticket == nil or rec.ticket == ticket) then _close_win(rec) end
end

--- 窗口被外部关闭（`:q` / `<C-w>c` / 其它插件）：按安全默认决策结算，避免
--- Deferred 悬挂、审批中心镜像条目残留（表现为 Herder pane 一直 blocked）。
--- @param rec table
local function _on_win_closed(rec)
  if state.current ~= rec or rec.closing then return end
  local decide, ticket = rec.decide, rec.ticket
  rec.aucmd = nil
  _close_win(rec)
  pcall(function() require("NeoAI.ui.consent_slot").cancel(ticket) end)
  if decide then decide("deny") end
end

--- 目标去重键：仅当审批中心可用（同目标条目会被合并、一次决策结算全部挂起请求）时
--- 才按目标去重；否则独立弹窗必须逐个展示，避免后到请求只能等到超时。
--- 粒度与沙箱侧/中心一致：`host:port`，并在解析到监听进程时细化为 `host:port:comm:pid`
--- （同一端口换了服务进程即视为不同目标，不能因去重把后一个请求的窗吞掉）。
--- @param ctx table|nil
--- @return string|nil
local function _dedupe_key(ctx)
  if type(ctx) ~= "table" or ctx.host == nil or ctx.port == nil then return nil end
  local ok, hub = pcall(require, "NeoAI.sandbox.review.approval_hub")
  if not (ok and type(hub) == "table" and type(hub.available) == "function") then return nil end
  local oka, avail = pcall(hub.available)
  if not (oka and avail) then return nil end
  local key = tostring(ctx.host) .. ":" .. tostring(ctx.port)
  local svc = ctx.service
  if type(svc) == "table" and svc.comm then
    key = key .. ":" .. tostring(svc.comm) .. ":" .. tostring(svc.pid or "")
  end
  return key
end

--- 单行化（浮窗内容不接受换行）
--- @param s any
--- @return string
local function _one_line(s)
  if s == nil then return "" end
  return (tostring(s):gsub("[\r\n]", " "))
end

--- 脱敏命令行摘要（复用密钥脱敏，避免把密钥参数展示在弹窗）。
--- @param s string|nil
--- @return string|nil
local function _sanitize_cmdline(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, red = pcall(function()
    local sandbox = services.use("services.sandbox")
    return sandbox and sandbox.redact(s)
  end)
  local v = (ok and red) or s
  if #v > 160 then v = v:sub(1, 157) .. "…" end
  return v
end

local function _text(ctx)
  local lines = {}
  lines[#lines + 1] = "⚠ 沙箱外部命令请求访问沙箱外目标"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "目标: " .. tostring(ctx.host or "?") .. ":" .. tostring(ctx.port or "?")
  lines[#lines + 1] = "类型: " .. (ctx.local_ and "宿主本机服务" or "外部网络")
  if ctx.proto then
    lines[#lines + 1] = "协议: " .. tostring(ctx.proto)
  end
  -- 宿主服务进程身份（端口背后的监听进程）：用户据此判断是否放行。
  local svc = ctx.service
  if svc then
    local who = _one_line(svc.comm or "?")
    if svc.pid then who = who .. " (pid " .. tostring(svc.pid) .. ")" end
    lines[#lines + 1] = "服务: " .. who
    if svc.exe then lines[#lines + 1] = "程序: " .. _one_line(svc.exe) end
    local cmd = _sanitize_cmdline(svc.cmdline)
    if cmd then lines[#lines + 1] = "命令行: " .. cmd end
  elseif ctx.local_ then
    lines[#lines + 1] = "服务: （未识别到监听进程）"
  end
  -- 相关历史批准提示：同进程的其它端口 / 同端口的其它进程（按 (端口,进程) 颗粒度批准）。
  local rel = ctx.related
  if rel and ((rel.ports and #rel.ports > 0) or (rel.services and #rel.services > 0)) then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "相关已批准（本会话）:"
    if rel.services and #rel.services > 0 then
      lines[#lines + 1] = "  同端口其它进程: " .. _one_line(table.concat(rel.services, ", "))
    end
    if rel.ports and #rel.ports > 0 then
      lines[#lines + 1] = "  同一服务的其它端口: " .. _one_line(table.concat(rel.ports, ", "))
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "沙箱内部进程/端口互访无需确认；此处为出沙箱访问，请确认是否放行。"
  lines[#lines + 1] = "S 仅记住当前「端口+服务进程」，同端口换进程会重新询问。"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "快捷键: [回车] 仅本次允许    [S] 本次会话允许该服务    [Esc] 拒绝"
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

--- 展示同意弹窗（实际建窗）。单槽位保证同一时刻只有一个同意类浮窗，故不再覆盖旧窗。
--- @param ticket table 槽位票据（`ui/consent_slot`）
--- @param ctx table { host, port, local_?, proto? }
--- @param decide function(decision)
local function _present(ticket, ctx, decide)
  local slot = require("NeoAI.ui.consent_slot")
  if slot.current() ~= ticket then return end -- 已被取消/让位：不再建窗
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neoai_net_consent"
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
    title = "🌐 沙箱网络访问",
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

--- 展示同意弹窗。**单槽位串行**（`ui/consent_slot`）：密钥/网络/设备/策略四类阻塞浮窗共用
--- 一个展示槽位，任一时刻只展示一个，其余排队——避免多窗叠加后只有可见的那个被回答、另一个
--- 决策回调永久丢失（表现为 Herder pane 一直 `blocked`）。**聊天界面焦点门控**（`focus.gate`）：
--- 当前窗口是 NeoAI 界面时立即弹出，否则暂存待切回再弹（审批中心仍可直接决策）。
--- @param ctx table { host, port, local_?, proto? }
--- @param decide function(decision)
--- @return table ticket 票据（`state.ui.hide/is_open` 按票据作用域生效）
function M.show(ctx, decide)
  local slot = require("NeoAI.ui.consent_slot")
  local focus = require("NeoAI.ui.focus")
  return slot.acquire({
    key = KEY,
    dedupe = _dedupe_key(ctx),
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

--- 弹窗当前是否已呈现（供同意模块区分「已弹出」与「暂存待弹/排队中」：仅前者到时自动拒绝）。
--- 令牌作用域：仅当**该票据**的窗口确实在展示时返回 true；被去重抑制的票据跟随其代表票据。
--- @param ticket table|nil
--- @return boolean
function M.is_open(ticket)
  if type(ticket) == "table" then
    if ticket.suppressed then
      local oks, slot = pcall(require, "NeoAI.ui.consent_slot")
      return oks and slot.is_presented(ticket) or false
    end
    local rec = state.current
    if not (rec and rec.ticket == ticket) then return false end
    return rec.win_id ~= nil and vim.api.nvim_win_is_valid(rec.win_id)
  end
  local rec = state.current
  return rec ~= nil and rec.win_id ~= nil and vim.api.nvim_win_is_valid(rec.win_id)
end

--- 注册到 sandbox.net_consent。
--- 沙箱服务属 phase 2、UI 属 phase 1：UI 初始化时沙箱尚未就绪，直接 `use` 会得到 nil。
--- 经 `services.wait` 延迟登记（就绪即回调），保证同意弹窗最终注册，与其它审批弹窗一致。
function M.init()
  if state.unwait then state.unwait() end
  state.unwait = services.wait("services.sandbox", function(sandbox)
    if sandbox and sandbox.set_net_consent_ui then
      sandbox.set_net_consent_ui({ show = M.show, hide = M.hide, is_open = M.is_open })
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
    if sandbox and sandbox.set_net_consent_ui then sandbox.set_net_consent_ui(nil) end
  end)
end

return M
