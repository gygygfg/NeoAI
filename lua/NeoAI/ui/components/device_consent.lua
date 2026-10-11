--- 危险设备访问同意弹窗
--- @module 'NeoAI.ui.components.device_consent'
--- 命令引用 /dev/kvm、/dev/net/tun 等逃逸面设备时，阻塞并请用户确认（30s 无应答自动阻止）。
--- 批准后该设备绑定进本次命令的沙箱命名空间。注册到 sandbox.device_consent。

local geometry = require("NeoAI.ui.geometry")
local services = require("NeoAI.kernel.services")

local M = {}

-- ========== 私有状态 ==========

local state = {
  win_id = nil,
  buf = nil,
  decide = nil,
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
end

--- 单行化（浮窗内容不接受换行）
--- @param s any
--- @return string
local function _one_line(s)
  if s == nil then return "" end
  return (tostring(s):gsub("[\r\n]", " "))
end

local function _text(ctx)
  local devices = ctx.devices or {}
  local lines = {}
  lines[#lines + 1] = "⚠ 命令试图访问危险设备（可能用于沙箱逃逸 / 内核控制）"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "设备: " .. _one_line(table.concat(devices, ", "))
  lines[#lines + 1] = ""
  lines[#lines + 1] = "批准后该设备将绑定进本次命令的沙箱命名空间（仅本次/本会话）。"
  lines[#lines + 1] = "未批准时命令被拒绝；30 秒无应答自动阻止。"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "快捷键: [回车] 仅本次允许    [S] 本次会话允许该设备    [Esc] 拒绝"
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

--- 展示同意弹窗（实际建窗）
--- @param ctx table { devices: string[] }
--- @param decide function(decision)
local function _present(ctx, decide)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then _close() end
  state.decide = decide
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_device_consent"
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
    title = "🔌 沙箱设备访问",
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

--- 展示同意弹窗。**应用级焦点门控**（`focus.gate_app`）：只要 nvim 有 OS 焦点即**立即弹出**，
--- 不因当前窗口不是 NeoAI 界面而延迟；仅 nvim 失焦时暂存，回焦再弹。同意超时/经审批中心
--- 决策会调用 `hide()` 取消暂存。
--- @param ctx table { devices: string[] }
--- @param decide function(decision)
function M.show(ctx, decide)
  require("NeoAI.ui.focus").gate_app("device_consent", function() _present(ctx, decide) end)
end

--- 隐藏弹窗
function M.hide()
  require("NeoAI.ui.focus").cancel_gate("device_consent")
  _close()
end

--- 注册到 sandbox.device_consent。
--- 沙箱服务属 phase 2、UI 属 phase 1：UI 初始化时沙箱尚未就绪，直接 `use` 会得到 nil。
--- 经 `services.wait` 延迟登记（就绪即回调），保证同意弹窗最终注册，与其它审批弹窗一致。
function M.init()
  if state.unwait then state.unwait() end
  state.unwait = services.wait("services.sandbox", function(sandbox)
    if sandbox and sandbox.set_device_consent_ui then
      sandbox.set_device_consent_ui({ show = M.show, hide = M.hide })
    end
  end)
end

--- 重置（测试用）
function M.reset()
  _close()
  pcall(function() require("NeoAI.ui.focus").cancel_gate("device_consent") end)
  if state.unwait then
    pcall(state.unwait)
    state.unwait = nil
  end
  pcall(function()
    local sandbox = services.use("services.sandbox")
    if sandbox and sandbox.set_device_consent_ui then sandbox.set_device_consent_ui(nil) end
  end)
end

return M
