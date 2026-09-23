--- 密钥告警服务：AI 上下文/工具调用中出现**真实密钥**（疑似突破沙箱）或向非白名单地址
--- **发送密钥**时，阻塞式弹窗让用户确认；确认后继续，否则停止 Agent。headless 无 UI 时失败关闭。
--- @module NeoAI.sandbox.secret_alert
--- UI 通过 `set_ui({ show = fn })` 注册（见 ui/components/secret_alert）。`request` 返回 Deferred，
--- resolve 决策字符串：`allow_once`（保留真实密钥，仅本次允许）| `fake`（替换为假密钥并继续）|
--- `whitelist`（加入发送白名单）| `stop`。
--- 弹窗上下文 `ctx` 会携带来源命令/工具、命中的真实密钥、以及将使用的假密钥，供 UI 展示。

local M = {}

local state = {
  ui = nil,
}

--- 注册/注销 UI（ui 组件 init/reset 调用）
--- @param ui table|nil { show = function(ctx, decide) }
function M.set_ui(ui)
  state.ui = ui
end

--- 是否存在可交互的 Neovim UI（`--headless` 无 attached UI）。
--- @return boolean
local function _interactive()
  local ok, uis = pcall(vim.api.nvim_list_uis)
  return ok and type(uis) == "table" and #uis > 0
end

--- 是否可用（未禁用，且有专用弹窗 UI 或可交互 Neovim 供内建确认回退）
--- @return boolean
function M.available()
  local cfg = require("NeoAI.kernel.config_store").get("tools.sandbox.secrets.alert")
  if type(cfg) == "table" and cfg.enabled == false then return false end
  if state.ui ~= nil and type(state.ui.show) == "function" then return true end
  return _interactive()
end

--- 内建确认回退：专用弹窗 UI 未注册但为交互式 Neovim 时，用 `confirm` 暂停并询问。
--- @param ctx table
--- @param decide function(decision)
function M._confirm_fallback(ctx, decide)
  ctx = ctx or {}
  local has_fake = ctx.fake ~= nil and ctx.fake ~= ""
  local title
  if ctx.kind == "egress" then
    title = "向非白名单地址发送密钥，是否允许？目标: " .. tostring(ctx.dest or "?")
  elseif ctx.kind == "context" then
    title = "AI 上下文中出现真实密钥，是否继续？"
  else
    title = "工具调用中出现真实密钥，是否继续？"
  end
  local choices
  if has_fake then
    choices = "仅本次允许\n替换为假密钥并继续\n停止 Agent"
  elseif ctx.kind == "egress" then
    choices = "仅本次允许\n加入白名单\n停止 Agent"
  else
    choices = "仅本次允许\n停止 Agent"
  end
  local choice = vim.fn.confirm(title, choices, 3, "Question")
  if has_fake then
    if choice == 1 then decide("allow_once")
    elseif choice == 2 then decide("fake")
    else decide("stop") end
  elseif ctx.kind == "egress" then
    if choice == 1 then decide("allow_once")
    elseif choice == 2 then decide("whitelist")
    else decide("stop") end
  else
    if choice == 1 then decide("allow_once") else decide("stop") end
  end
end

--- 阻塞式请求用户确认。
--- @param ctx table { kind, tool?, command?, agent?, secret?, secret_preview?, fake?, dest?, reason? }
--- @return Deferred resolve(decision)
function M.request(ctx)
  local async = require("NeoAI.utils.async")
  local d = async.Deferred.new()
  if not M.available() then
    -- headless / 无 UI 且无回退：失败关闭
    d:resolve("stop")
    return d
  end
  local done = false
  local function decide(decision)
    if done then return end
    done = true
    if decision ~= "allow_once" and decision ~= "fake"
      and decision ~= "whitelist" and decision ~= "stop" then
      decision = "stop"
    end
    d:resolve(decision)
  end
  if state.ui ~= nil and type(state.ui.show) == "function" then
    local ok = pcall(state.ui.show, ctx or {}, decide)
    if not ok then decide("stop") end
    return d
  end
  -- 专用 UI 未注册：交互式 Neovim 用内建确认（暂停 Agent 直到用户选择）
  local ok = pcall(M._confirm_fallback, ctx or {}, decide)
  if not ok then decide("stop") end
  return d
end

--- 重置（测试用）
function M.reset()
  state.ui = nil
end

return M
