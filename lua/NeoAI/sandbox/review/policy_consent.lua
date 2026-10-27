--- 沙箱策略确认：代理规避等「需用户批准」的操作暂停 Agent 并弹窗询问。
--- 优先使用与网络同意/工具审批/设备同意同款的**沙箱浮窗**（`ui/components/policy_consent`，经
--- `set_ui` 注册）；无注册 UI 时回退内建 `confirm`；真正 headless（无 attached UI）失败关闭（拒绝）。
---
--- 主路径是**异步** `request(kind, opts)`（返回 Deferred，浮窗按键经正常事件循环处理）；
--- `ask` 为兼容用的**同步**入口（仅测试/非 UI 场景），生产门禁请用 `request`。
--- 会话级「始终允许」按 kind 记忆。策略由 `tools.sandbox.network.block_proxy_evasion` 选择。
--- @module 'NeoAI.sandbox.review.policy_consent'

local M = {}

local state = { session = {}, ui = nil }

--- 是否存在可交互的 Neovim UI（`--headless` 无 attached UI）。
--- @return boolean
local function _interactive()
  local ok, uis = pcall(vim.api.nvim_list_uis)
  return ok and type(uis) == "table" and #uis > 0
end

--- 弹窗无响应超时（毫秒；0 = 不限）。复用网络同意的超时配置。
--- @return number
local function _timeout_ms()
  local net = require("NeoAI.kernel.config_store").get("tools.sandbox.network") or {}
  local v = tonumber(net.consent_timeout_ms)
  if v == nil then v = 30000 end
  return v > 0 and v or 0
end

--- 注册/注销沙箱策略确认 UI（由 ui 层注入；传 nil 解绑）。
--- @param ui table|nil { show = function(ctx, decide), hide? = function() }
function M.set_ui(ui)
  state.ui = ui
end

--- 是否有可用的浮窗 UI。
--- @return boolean
function M.available()
  return state.ui ~= nil and type(state.ui.show) == "function"
end

--- 本会话是否已对某策略「始终允许」
--- @param kind string
--- @return boolean
function M.is_session_allowed(kind)
  return type(kind) == "string" and state.session[kind] == true
end

--- 记住本会话「始终允许」
--- @param kind string
function M.allow_session(kind)
  if type(kind) == "string" and kind ~= "" then state.session[kind] = true end
end

--- 同步回退：内建 `confirm`（仅无浮窗 UI 的交互式场景；会**阻塞**且不处理浮窗输入）。
--- @param kind string
--- @param opts table
--- @return string "once"|"session"|"deny"
local function _ask_confirm(kind, opts)
  local prompt = tostring(opts.title or "沙箱策略确认")
  local detail = opts.detail
  if type(detail) == "table" then detail = table.concat(detail, " ") end
  if type(detail) == "string" and detail ~= "" then
    prompt = prompt .. " " .. detail:gsub("%s+", " ")
  end
  local choices = "仅本次允许\n本次会话始终允许\n拒绝"
  local confirm = vim.fn.confirm --[[@as fun(title: string, choices: string, default: integer, kind: string): integer]]
  local ret = confirm(prompt, choices, 3, "Warning")
  if ret == 1 then return "once" end
  if ret == 2 then M.allow_session(kind); return "session" end
  return "deny"
end

--- 异步请求用户同意（主路径）。
--- @param kind string 策略标识（如 "proxy_evasion"）
--- @param opts table|nil { title?, detail? }
--- @return Deferred resolve("allow_once"|"allow_session"|"deny")
function M.request(kind, opts)
  opts = opts or {}
  -- libuv 快速事件回调中不得弹窗/confirm（E5560）：调度到主循环再发起。
  if vim.in_fast_event and vim.in_fast_event() then
    local async = require("NeoAI.utils.async")
    local outer = async.Deferred.new()
    vim.schedule(function()
      M.request(kind, opts):then_(function(v) outer:resolve(v) end, function(e) outer:reject(e) end)
    end)
    return outer
  end
  local async = require("NeoAI.utils.async")
  local d = async.Deferred.new()
  if M.is_session_allowed(kind) then
    vim.schedule(function() d:resolve("allow_session") end)
    return d
  end

  local done = false
  local hub_id
  local ticket -- 独立弹窗票据（ui/consent_slot）：hide/is_open 按票据作用域生效
  local function decide(decision)
    if done then return end
    done = true
    if decision ~= "allow_once" and decision ~= "allow_session" and decision ~= "deny" then
      decision = "deny"
    end
    if decision == "allow_session" then M.allow_session(kind) end
    -- **按票据**关闭自己的窗与暂存：避免误关其它请求正在展示的同意浮窗（那会让那个请求的
    -- 决策回调永久丢失、审批中心条目残留 pending → Herder pane 一直 blocked）。
    if state.ui and state.ui.hide then pcall(state.ui.hide, ticket) end
    if hub_id then
      pcall(function() require("NeoAI.sandbox.review.approval_hub").clear(hub_id) end)
    end
    d:resolve(decision)
  end

  local hub = require("NeoAI.sandbox.review.approval_hub")
  local standalone = M.available()
  local via_hub = hub.available() and _interactive()
  if not standalone and not via_hub then
    -- 无浮窗/统一窗口可用：交互式退回内建 confirm（同步），headless 失败关闭。
    if _interactive() then
      local decision = _ask_confirm(kind, opts)
      decide(decision)
      return d
    end
    pcall(function()
      require("NeoAI.kernel.logger").warn("[policy_consent] 无可用确认界面，拒绝策略 %s", tostring(kind))
    end)
    decide("deny")
    return d
  end

  -- 统一运行时请求广播（同一事件 SANDBOX_CONSENT_REQUESTED，page="behavior" 区分）。
  require("NeoAI.sandbox.review.consent").emit("behavior", {
    kind = "policy", reason = kind, title = tostring(opts.title or ""),
  })
  -- 镜像到审批分流中心「工具行为」页（窗口可决策；独立弹窗仍在时以先决策者为准）。
  local hub_detail = {}
  if type(opts.detail) == "table" then
    for _, l in ipairs(opts.detail) do hub_detail[#hub_detail + 1] = tostring(l) end
  elseif type(opts.detail) == "string" and opts.detail ~= "" then
    hub_detail[1] = opts.detail
  end
  hub_id = hub.submit("behavior", {
    title = tostring(opts.title or "沙箱策略确认"),
    detail = hub_detail,
    decisions = {
      { key = "<CR>", label = "仅本次允许", value = "allow_once" },
      { key = "S", label = "本次会话始终允许", value = "allow_session" },
      { key = "<Esc>", label = "拒绝", value = "deny" },
    },
    on_decision = decide,
    meta = { kind = kind },
  })

  if standalone then
    local ok, tk = pcall(state.ui.show, { title = opts.title, detail = opts.detail }, decide)
    if ok then ticket = tk else decide("deny") end
  else
    pcall(function() hub.open_page("behavior") end)
  end

  local tms = _timeout_ms()
  if tms > 0 then
    local presented_at = nil
    local function arm(delay)
      vim.defer_fn(function()
        if done then return end
        -- 仅在弹窗**已呈现**时到时自动拒绝；暂存待弹（聊天界面不在前台）/ 单槽位排队时
        -- 不拒绝（请求已镜像到统一审批悬浮窗）。判定与关闭均按票据作用域：
        -- 只看**本请求**的窗是否在展示，且只关自己的窗（避免误关其它请求的弹窗）。
        -- 计时从「用户真正看到弹窗」开始（首次呈现重置完整预算），排队等待时间不计入。
        local ui = state.ui
        local presented = (ui == nil) or (type(ui.is_open) ~= "function") or ui.is_open(ticket)
        if not presented then
          arm(tms) -- 仍暂存/排队（未呈现）：继续等待，不计时
          return
        end
        local now = vim.uv.now()
        if not presented_at then
          presented_at = now
          arm(tms)
          return
        end
        local left = tms - (now - presented_at)
        if left > 0 then
          arm(left)
          return
        end
        if ui and ui.hide then pcall(ui.hide, ticket) end
        decide("deny")
      end, delay or tms)
    end
    arm(tms)
  end
  return d
end

--- 同步询问（兼容入口，仅测试/无浮窗场景）。返回 `"once"|"session"|"deny"`。
--- @param kind string
--- @param opts table|nil { title?, detail? }
--- @return string
function M.ask(kind, opts)
  opts = opts or {}
  if M.is_session_allowed(kind) then return "session" end
  if _interactive() then
    return _ask_confirm(kind, opts)
  end
  return "deny"
end

--- 重置（测试用）
function M.reset()
  state.session = {}
  state.ui = nil
end

-- 同意窗属「等待人类交互」：等待期间暂停工具计时器（不累计耗时、不消耗超时预算）。
-- 以 Deferred 结算为驱动（不依赖配对），故早返回/无 UI 直接拒绝等路径均安全。
local _request = M.request
M.request = function(...)
  return require("NeoAI.utils.timer").await(_request(...))
end

return M
