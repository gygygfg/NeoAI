--- 密钥告警弹窗
--- @module NeoAI.ui.components.secret_alert
--- 真实密钥出现在 AI 上下文/工具调用，或向非白名单地址发送密钥时，阻塞 Agent 并请用户确认。
--- 注册到 sandbox.secret_alert。

local geometry = require("NeoAI.ui.geometry")
local services = require("NeoAI.kernel.services")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  decide = nil,
  has_fake = false,
  unwait = nil, -- services.wait 取消句柄（延迟注册）
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
  state.has_fake = false
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
    bind(mode, "W", function() close_then("whitelist") end)
    bind(mode, "w", function() close_then("whitelist") end)
    if state.has_fake then
      bind(mode, "F", function() close_then("fake") end)
      bind(mode, "f", function() close_then("fake") end)
    end
    bind(mode, "<Esc>", function() close_then("stop") end)
    bind(mode, "q", function() close_then("stop") end)
  end
end

-- ========== 公开 API ==========

--- 展示告警弹窗（实际建窗）
--- @param ctx table
--- @param decide function(decision)
local function _present(ctx, decide)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then _close() end
  state.decide = decide
  state.has_fake = ctx and ctx.fake ~= nil and ctx.fake ~= ""
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_secret_alert"
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
    title = "🔑 密钥告警",
    title_pos = "center",
  })
  if not ok then
    _close()
    decide("stop")
    return
  end
  state.win_id = wid
  geometry.track(state.win_id, geom_opts)
  vim.wo[state.win_id].wrap = true
  pcall(vim.cmd, "stopinsert")
  vim.bo[state.buf].modifiable = false
  _set_keymaps()
end

--- 展示告警弹窗。焦点不在 NeoAI 界面（用户切到其他窗口）时不立即弹出，暂存并进入等待，
--- 待切回 NeoAI 界面再弹（经 `focus.gate`）。
--- @param ctx table
--- @param decide function(decision)
function M.show(ctx, decide)
  require("NeoAI.ui.focus").gate("secret_alert", function() _present(ctx, decide) end)
end

--- 隐藏弹窗
function M.hide()
  require("NeoAI.ui.focus").cancel_gate("secret_alert")
  _close()
end

--- 注册到 sandbox.secret_alert。
--- 沙箱服务属 phase 2、UI 属 phase 1：UI 初始化时 `services.sandbox` 往往尚未就绪，
--- 直接 `use` 会拿到 nil 而静默跳过注册。经 `services.wait` 延迟登记（已就绪则立即回调），
--- 保证弹窗 UI 最终一定注册，避免真密钥告警回退到 nvim 原生 `vim.fn.confirm`。
function M.init()
  if state.unwait then state.unwait() end
  state.unwait = services.wait("services.sandbox", function(sandbox)
    if sandbox and sandbox.set_secret_alert_ui then
      sandbox.set_secret_alert_ui({ show = M.show, hide = M.hide })
    end
  end)
end

--- 重置（测试用）
function M.reset()
  _close()
  pcall(function() require("NeoAI.ui.focus").cancel_gate("secret_alert") end)
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
