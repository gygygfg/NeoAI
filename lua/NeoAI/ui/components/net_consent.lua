--- 网络访问同意弹窗
--- @module NeoAI.ui.components.net_consent
--- 沙箱内进程/端口在沙箱内访问免权限；访问沙箱外部（宿主本机其他端口、外部主机）时
--- 阻塞并请用户确认。注册到 sandbox.net_consent。

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
  state.win_id = nil
  state.buf = nil
  state.decide = nil
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
  lines[#lines + 1] = ""
  lines[#lines + 1] = "沙箱内部进程/端口互访无需确认；此处为出沙箱访问，请确认是否放行。"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "快捷键: [回车] 仅本次允许    [S] 本次会话始终允许    [Esc] 拒绝"
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
  local height = math.min(#lines + 2, 16)
  local width = math.min(78, vim.o.columns - 8)
  local ok, wid = pcall(vim.api.nvim_open_win, state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
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
