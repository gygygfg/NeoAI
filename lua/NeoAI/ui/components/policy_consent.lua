--- 沙箱策略确认弹窗（代理规避等）
--- @module 'NeoAI.ui.components.policy_consent'
--- 与网络同意 / 工具审批 / 设备同意同款浮窗（圆角 + 按键提示 + 焦点门控）。
--- 注册到 `sandbox.policy_consent`（`sandbox/review/policy_consent.set_ui`）；同步阻塞由来源模块
--- 用 `vim.wait` 驱动，本组件只负责渲染与按键回调。

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

--- 展示策略确认弹窗（实际建窗）
--- @param ctx table { title?, detail? }
--- @param decide function(decision: "allow_once"|"allow_session"|"deny")
local function _present(ctx, decide)
  if state.win_id and vim.api.nvim_win_is_valid(state.win_id) then _close() end
  state.decide = decide
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = "neoai_policy_consent"
  local lines = _text(ctx)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  -- 内容自适应高度：按显示宽度折行后适配（CJK 按 2 列），避免长标题/命令被截断。
  local geom_opts = { w_ratio = 0.60, h_ratio = 0.40, fit_lines = lines, fit_pad = 2 }
  local geom = geometry.compute(geom_opts)
  local ok, wid = pcall(vim.api.nvim_open_win, state.buf, true, {
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
    _close()
    decide("deny")
    return
  end
  state.win_id = wid
  geometry.track(state.win_id, geom_opts)
  vim.wo[state.win_id].wrap = true
  vim.wo[state.win_id].linebreak = true
  pcall(vim.cmd, "stopinsert")
  vim.bo[state.buf].modifiable = false
  _set_keymaps()
end

--- 展示弹窗。**聊天界面焦点门控**（`focus.gate`）：当前窗口是 NeoAI 界面时立即弹出；
--- 否则**暂存**，待切回 NeoAI 界面再弹。审批分流中心始终**直接新建条目**，故暂存期间可在多级
--- 审批悬浮窗决策。
--- @param ctx table { title?, detail? }
--- @param decide function(decision)
function M.show(ctx, decide)
  require("NeoAI.ui.focus").gate("policy_consent", function() _present(ctx, decide) end)
end

--- 隐藏弹窗
function M.hide()
  require("NeoAI.ui.focus").cancel_gate("policy_consent")
  _close()
end

--- 弹窗当前是否已呈现（供策略模块区分「已弹出」与「暂存待弹」：仅前者到时自动拒绝）
--- @return boolean
function M.is_open()
  return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
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
  _close()
  pcall(function() require("NeoAI.ui.focus").cancel_gate("policy_consent") end)
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
