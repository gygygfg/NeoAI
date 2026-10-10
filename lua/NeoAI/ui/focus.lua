--- NeoAI 界面焦点信号
--- @module 'NeoAI.ui.focus'
--- 跟踪「用户当前是否在看 NeoAI 界面」，并在焦点于 NeoAI 界面 / 非 NeoAI 窗口之间跳变时
--- 广播 `UI_FOCUS_CHANGED`。判定为「当前窗口的 buffer 是 NeoAI 界面 buffer」（filetype 前缀
--- `neoai*`，或已打 `b:neoai_ui` 标记）**且** nvim 应用本身有焦点（`FocusLost`/`FocusGained`）。
---
--- 用途：
---   - 焦点离开 NeoAI 界面（用户切到其他窗口 / 终端）时，pty 悬浮终端与 ask_user 提问弹窗
---     进入等待、不抢占注意力；切回 NeoAI 界面时再弹。
---   - 审批悬浮窗在切回时强制刷新，避免展示陈旧/部分状态。
--- 副作用可卸载（架构硬性约定）：install 返回清理函数，uninstall/reset 注销 autocmd。
local event_bus = require("NeoAI.kernel.event_bus")
local events = require("NeoAI.kernel.events")

local M = {}

-- ========== 私有状态 ==========

local state = {
  installed = false,
  -- nvim 应用是否有焦点（headless / 无 UI 时视为有焦点，仅靠窗口判定）。
  app_focused = true,
  -- 当前窗口是否为 NeoAI 界面 buffer。
  win_is_neoai = false,
  -- 对外语义的合成焦点：app_focused and win_is_neoai。
  focused = false,
  augroup = nil,
  focus_sub = nil, -- UI_FOCUS_CHANGED 订阅（切回时 flush 待展示弹窗）
  force_ui = false, -- 测试钩子：强制视作「有 attached UI」（headless 下也验证焦点语义）
}

--- 是否有 attached UI（headless / 无 UI 时无「其他窗口」可切，不做焦点抑制）。
--- @return boolean
local function _has_ui()
  if state.force_ui then return true end
  local ok, uis = pcall(vim.api.nvim_list_uis)
  return ok and type(uis) == "table" and #uis > 0
end

-- 焦点门控的待展示登记：key -> present 函数（失焦时暂存，切回 NeoAI 界面再执行）。
-- 供 tool_approval / secret_alert / net_consent / ask_user 统一「失焦不弹、切回再弹」。
local gated = {}

-- ========== 私有函数 ==========

-- 前向声明（定义见文件末尾）：install 的订阅闭包会调用它。
local _flush_gated

--- buffer 是否为 NeoAI 界面（与 lsp_guard 同口径：已标记，或 filetype 前缀为 neoai）
--- @param buf number|nil
--- @return boolean
local function _is_neoai_buf(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return false end
  if vim.b[buf] and vim.b[buf].neoai_ui then return true end
  local ft = vim.bo[buf].filetype
  return type(ft) == "string" and ft:sub(1, 5) == "neoai"
end

--- 当前窗口是否为 NeoAI 界面
--- @return boolean
local function _current_win_is_neoai()
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then return false end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  return ok and _is_neoai_buf(buf)
end

--- 合成并广播焦点（仅在值变化时广播）
local function _recompute()
  local focused = state.app_focused and state.win_is_neoai
  if focused == state.focused then return end
  state.focused = focused
  event_bus.emit(events.UI_FOCUS_CHANGED, { focused = focused })
end

-- ========== 公开 API ==========

--- 当前是否聚焦在 NeoAI 界面。
--- 无 attached UI（headless/测试，且未 force）时返回 true——没有「其他窗口」可切，
--- 不做焦点抑制；未安装监听（UI 未启动 / 懒加载阶段）时同样返回 true（无信号即不抑制）。
--- @return boolean
function M.is_focused()
  if not _has_ui() then return true end
  if not state.installed then return true end
  return state.focused == true
end

--- 测试钩子：强制视作「有 attached UI」（headless 下也能验证焦点门控）。
--- @param v boolean
function M._set_force_ui(v)
  state.force_ui = not not v
end

--- 重新计算当前焦点（依据当前窗口/应用焦点），变化时广播。
function M.refresh()
  state.win_is_neoai = _current_win_is_neoai()
  _recompute()
end

--- 安装焦点监听（幂等）。autocmd 覆盖窗口切换（WinEnter/BufEnter）、应用焦点变化
--- （FocusGained/FocusLost）与终端挂起恢复（VimResume/VimSuspend）。
function M.install()
  if state.installed then return end
  state.installed = true
  state.win_is_neoai = _current_win_is_neoai()
  state.focused = state.app_focused and state.win_is_neoai
  local group = vim.api.nvim_create_augroup("NeoAIUiFocus", { clear = true })
  state.augroup = group
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = group,
    callback = function() M.refresh() end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      state.app_focused = true
      M.refresh()
    end,
  })
  -- FocusLost / VimSuspend：应用（或终端）失去焦点即视为「未聚焦」，不弹交互窗。
  vim.api.nvim_create_autocmd({ "FocusLost", "VimSuspend" }, {
    group = group,
    callback = function()
      state.app_focused = false
      _recompute()
    end,
  })
  vim.api.nvim_create_autocmd("VimResume", {
    group = group,
    callback = function()
      state.app_focused = true
      M.refresh()
    end,
  })
  -- 切回 NeoAI 界面时 flush 待展示弹窗（失焦期间暂存者）。
  if not state.focus_sub then
    state.focus_sub = event_bus.on(events.UI_FOCUS_CHANGED, function(payload)
      if payload and payload.focused == true then _flush_gated() end
    end)
  end
end

--- 卸载焦点监听并复位状态。
function M.uninstall()
  state.installed = false
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  if state.focus_sub then
    pcall(state.focus_sub)
    state.focus_sub = nil
  end
  gated = {}
  state.app_focused = true
  state.win_is_neoai = false
  state.focused = false
  state.force_ui = false
end

--- 焦点门控展示：聚焦 NeoAI 界面（或焦点模块未安装）时立即执行 present；
--- 否则登记为待展示，待切回 NeoAI 界面（UI_FOCUS_CHANGED focused=true）再执行。
--- 供 tool_approval / secret_alert / net_consent / ask_user 统一「失焦不弹、切回再弹」。
--- @param key string 唯一键（同名重复登记会覆盖旧的）
--- @param present function 无参展示函数（内部完成所有建窗/状态设置）
--- @return boolean shown 是否已立即展示（false = 已登记待展示）
function M.gate(key, present)
  if type(key) ~= "string" or key == "" or type(present) ~= "function" then return false end
  if M.is_focused() then
    gated[key] = nil
    present()
    return true
  end
  gated[key] = present
  return false
end

--- 取消待展示登记（隐藏/取消/超时时调用，丢弃暂存不再弹出）。
--- @param key string
function M.cancel_gate(key)
  if type(key) == "string" then gated[key] = nil end
end

--- 是否存在某 key 的待展示登记（测试用）。
--- @param key string
--- @return boolean
function M.has_gate(key)
  return type(key) == "string" and gated[key] ~= nil
end

--- 执行并清空全部待展示登记（切回 NeoAI 界面时调用）。
_flush_gated = function()
  local pending = gated
  gated = {}
  for _, fn in pairs(pending) do pcall(fn) end
end

--- 测试钩子：直接设置「应用是否有焦点」并重算（headless 下无法触发 FocusLost/Gained）。
--- @param v boolean
function M._set_app_focused(v)
  state.app_focused = not not v
  M.refresh()
end

--- 重置（测试/卸载）：卸载监听并复位。
function M.reset()
  M.uninstall()
end

return M
