--- 网络访问同意弹窗
--- @module NeoAI.ui.components.net_consent
--- 沙箱内进程/端口在沙箱内访问免权限；访问沙箱外部（宿主本机其他端口、外部主机）时
--- 阻塞并请用户确认。注册到 sandbox.net_consent。

local geometry = require("NeoAI.ui.geometry")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  decide = nil,
}

-- ========== 私有函数 ==========

local function _close()
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then
    pcall(vim.api.nvim_win_close, state.win_id, true)
  end
  geometry.untrack(state.win_id)
  state.win_id = nil
  state.buf = nil
  state.decide = nil
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
    return require("NeoAI.sandbox.secret").redact(s)
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

local function _set_keymaps()
  if not state.buf then return end
  local function bind(mode, key, fn)
    vim.keymap.set(mode, key, fn, { buffer = state.buf })
  end
  local function close_then(decision)
    local d = state.decide
    _close()
    if d then d(decision) end
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

--- 展示同意弹窗
--- @param ctx table { host, port, local_?, proto? }
--- @param decide function(decision)
function M.show(ctx, decide)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then _close() end
  state.decide = decide
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_net_consent"
  local lines = _text(ctx)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  local geom_opts = { w_ratio = 0.60, h_ratio = 0.40, fit_h = #lines + 2 }
  local geom = geometry.compute(geom_opts)
  local ok, wid = pcall(vim.api.nvim_open_win, state.buf, true, {
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
    _close()
    decide("deny")
    return
  end
  state.win_id = wid
  geometry.track(state.win_id, geom_opts)
  vim.wo[state.win_id].wrap = true
  pcall(vim.cmd, "stopinsert")
  vim.bo[state.buf].modifiable = false
  _set_keymaps()
end

--- 隐藏弹窗
function M.hide()
  _close()
end

--- 注册到 sandbox.net_consent
function M.init()
  local consent = require("NeoAI.sandbox.net_consent")
  consent.set_ui({ show = M.show, hide = M.hide })
end

--- 重置（测试用）
function M.reset()
  _close()
  pcall(function() require("NeoAI.sandbox.net_consent").set_ui(nil) end)
end

return M
