--- 密钥告警服务：AI 上下文/工具调用中出现**真实密钥**（疑似突破沙箱）或向非白名单地址
--- **发送密钥**时，阻塞式弹窗让用户确认；确认后继续，否则停止 Agent。headless 无 UI 时失败关闭。
--- @module 'NeoAI.sandbox.secret.secret_alert'
--- UI 通过 `set_ui({ show = fn })` 注册（见 ui/components/secret_alert）。`request` 返回 Deferred，
--- resolve 决策字符串：`allow_once`（保留真实密钥，仅本次允许）| `fake`（替换为假密钥并继续）|
--- `whitelist`（加入发送白名单）| `stop`。
--- 弹窗上下文 `ctx` 会携带来源命令/工具、命中的真实密钥、以及将使用的假密钥，供 UI 展示。

local M = {}

local state = {
  ui = nil,
  dialog_seq = 0, -- 无审批中心时的本地阻塞弹窗 id 计数（Herder 联动）
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

--- 广播阻塞弹窗生命周期（无审批中心条目时兜底，保证 Herder 仍能标记 blocked）。
--- @param event_name string
--- @param id string
--- @param ctx table
local function _emit_dialog(event_name, id, ctx)
  pcall(function()
    require("NeoAI.kernel.event_bus").emit(event_name, {
      id = id, page = "behavior",
      kind = (ctx and ctx.kind) or "secret",
    })
  end)
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
  local confirm = vim.fn.confirm --[[@as fun(title: string, choices: string, default: integer, kind: string): integer]]
  local choice = confirm(title, choices, 3, "Question")
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
  -- libuv 快速事件回调中不得弹窗/confirm（E5560）：调度到主循环再发起。
  if vim.in_fast_event and vim.in_fast_event() then
    local async0 = require("NeoAI.utils.async")
    local outer = async0.Deferred.new()
    vim.schedule(function()
      M.request(ctx):then_(function(v) outer:resolve(v) end, function(e) outer:reject(e) end)
    end)
    return outer
  end
  local async = require("NeoAI.utils.async")
  local d = async.Deferred.new()
  ctx = ctx or {}
  if not M.available() then
    -- headless / 无 UI 且无回退：失败关闭
    d:resolve("stop")
    return d
  end
  local done = false
  local hub_id
  local local_dialog_id = nil
  local function close_local_dialog()
    if not local_dialog_id then return end
    _emit_dialog(require("NeoAI.kernel.events").SANDBOX_APPROVAL_BLOCKING_CLOSED, local_dialog_id, ctx)
    local_dialog_id = nil
  end
  local function open_local_dialog()
    if hub_id or local_dialog_id then return end
    state.dialog_seq = state.dialog_seq + 1
    local_dialog_id = "secret_alert_" .. tostring(state.dialog_seq)
    _emit_dialog(require("NeoAI.kernel.events").SANDBOX_APPROVAL_BLOCKING_OPENED, local_dialog_id, ctx)
  end
  local function decide(decision)
    if done then return end
    done = true
    close_local_dialog()
    if decision ~= "allow_once" and decision ~= "fake"
      and decision ~= "whitelist" and decision ~= "stop" then
      decision = "stop"
    end
    if state.ui and state.ui.hide then pcall(state.ui.hide) end
    if hub_id then
      pcall(function() require("NeoAI.sandbox.review.approval_hub").clear(hub_id) end)
    end
    d:resolve(decision)
  end

  local has_fake = ctx.fake ~= nil and ctx.fake ~= ""
  -- 广播到审批分流中心「工具行为」页：统一审批悬浮窗（多级页面）同步出现该条目并可决策。
  local ok_hub, hub = pcall(require, "NeoAI.sandbox.review.approval_hub")
  if ok_hub and hub.available() and _interactive() then
    local title
    if ctx.kind == "egress" then
      title = "密钥外发: " .. tostring(ctx.dest or "?")
    elseif ctx.kind == "context" then
      title = "AI 上下文出现真实密钥"
    else
      title = "工具调用出现真实密钥: " .. tostring(ctx.tool or "?")
    end
    local detail = {}
    if ctx.command then detail[#detail + 1] = "来源命令: " .. tostring(ctx.command):gsub("[\r\n]+", " ") end
    if ctx.dest then detail[#detail + 1] = "目标: " .. tostring(ctx.dest) end
    local s_label = has_fake and "替换为假密钥"
      or (ctx.kind == "egress" and "加入白名单" or "停止 Agent")
    hub_id = hub.submit("behavior", {
      title = title,
      detail = detail,
      decisions = {
        { key = "<CR>", label = "仅本次允许", value = "allow_once" },
        { key = "S", label = s_label, value = "allow_session" },
        { key = "<Esc>", label = "停止 Agent", value = "deny" },
      },
      on_decision = function(v)
        if v == "allow_once" then
          decide("allow_once")
        elseif v == "allow_session" then
          if has_fake then decide("fake")
          elseif ctx.kind == "egress" then decide("whitelist")
          else decide("allow_once") end
        else
          decide("stop")
        end
      end,
      meta = { kind = ctx.kind },
    })
  end

  -- 没有审批中心条目时（hub 不可用/无 UI），仍广播本地阻塞弹窗生命周期给 Herder。
  open_local_dialog()
  if state.ui ~= nil and type(state.ui.show) == "function" then
    local ok = pcall(state.ui.show, ctx, decide)
    if not ok then decide("stop") end
    return d
  end
  -- 专用 UI 未注册：交互式 Neovim 用内建确认（暂停 Agent 直到用户选择）
  local ok = pcall(M._confirm_fallback, ctx, decide)
  if not ok then decide("stop") end
  return d
end

--- 重置（测试用）
function M.reset()
  state.ui = nil
end

-- 同意窗属「等待人类交互」：等待期间暂停工具计时器（不累计耗时、不消耗超时预算）。
-- 以 Deferred 结算为驱动（不依赖配对），故早返回/无 UI 直接拒绝等路径均安全。
local _request = M.request
M.request = function(...)
  return require("NeoAI.utils.timer").await(_request(...))
end

return M
