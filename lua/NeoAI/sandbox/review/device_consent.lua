--- 沙箱危险设备访问同意服务
--- @module 'NeoAI.sandbox.review.device_consent'
---
--- 命令引用可用于逃逸/内核控制的设备节点（/dev/kvm、/dev/net/tun、裸盘、/dev/mem 等）时，
--- 暂停并弹窗询问用户（默认 30s 无应答自动阻止）。批准后由门禁把该设备 `--dev-bind` 进本次
--- 命令的沙箱命名空间（见 `execution/wrapper` + `execution/runtime`），使 AI 真正可用。
---
--- 已批准设备记入**本会话**内存白名单（`tools.sandbox.devices.allowed`，config_store.set 热更新、
--- 不写盘；重开 nvim 恢复默认），由弹窗「本次会话允许」或审批悬浮窗「工具行为」页的编辑器写入。
---
--- UI 通过 `set_ui({ show = fn })` 注册（见 ui/components/device_consent）。`request` 返回
--- Deferred，resolve 决策字符串：`allow_once` | `allow_session` | `deny`。headless 无 UI 时失败
--- 关闭（拒绝）。

local M = {}

-- ========== 私有状态 ==========

local state = { ui = nil }

-- ========== 私有函数 ==========

--- @return table
local function _cfg()
  local c = require("NeoAI.kernel.config_store").get("tools.sandbox.devices")
  return type(c) == "table" and c or {}
end

--- glob（`*` 通配）匹配：把模式转为 Lua pattern 后整串匹配。
--- @param pat string
--- @param path string
--- @return boolean
local function _glob_match(pat, path)
  if type(pat) ~= "string" or pat == "" then return false end
  if pat == path then return true end
  local out = {}
  for i = 1, #pat do
    local c = pat:sub(i, i)
    if c == "*" then
      out[#out + 1] = ".*"
    elseif c:match("[%^%$%(%)%%%.%[%]%+%-%?]") then
      out[#out + 1] = "%" .. c
    else
      out[#out + 1] = c
    end
  end
  return path:match("^" .. table.concat(out) .. "$") ~= nil
end

--- 命中白名单（条目本身可含 `*` 通配）
--- @param list table
--- @param path string
--- @return boolean
local function _match_any(list, path)
  for _, p in ipairs(list or {}) do
    if _glob_match(p, path) then return true end
  end
  return false
end

--- 宿主上该路径是否为可 bind 的设备节点（字符/块设备；软链跟随一次）。
--- @param path string
--- @return boolean
local function _is_device(path)
  local st = vim.uv.fs_lstat(path)
  if not st then return false end
  if st.type == "char" or st.type == "block" then return true end
  if st.type == "link" then
    local t = vim.uv.fs_stat(path)
    return t ~= nil and (t.type == "char" or t.type == "block")
  end
  return false
end

--- 是否存在可交互的 Neovim UI（`--headless` 无 attached UI）。
--- @return boolean
local function _interactive()
  local ok, uis = pcall(vim.api.nvim_list_uis)
  return ok and type(uis) == "table" and #uis > 0
end

-- ========== 公开 API ==========

--- 注册/注销 UI（ui 组件 init/reset 调用）
--- @param ui table|nil { show = function(ctx, decide), hide? = function() }
function M.set_ui(ui)
  state.ui = ui
end

--- 是否启用危险设备门禁
--- @return boolean
function M.enabled()
  return _cfg().enabled ~= false
end

--- 动态监测是否生效：配置开启且运行期观测后端能提供 open 事件（eBPF）。
--- @return boolean
function M.dynamic_active()
  if _cfg().dynamic == false then return false end
  local ok, obs = pcall(require, "NeoAI.sandbox.observe.observer")
  if not ok or not obs or type(obs.backend) ~= "function" then return false end
  return obs.backend() == "ebpf"
end

--- 访问策略：`ask`（弹窗同意，默认）| `allow`（直接放行并暴露设备）| `deny`（直接拒绝）
--- @return string
function M.action()
  local a = _cfg().action
  if a ~= "allow" and a ~= "deny" then a = "ask" end
  return a
end

--- 弹窗无响应超时（毫秒；0 = 不限）。
--- @return number
function M.timeout_ms()
  local v = tonumber(_cfg().timeout_ms)
  if v == nil then v = 30000 end
  return v > 0 and v or 0
end

--- 需要确认的危险设备模式列表（配置原值）
--- @return table
function M.paths()
  local p = _cfg().paths
  return type(p) == "table" and p or {}
end

--- 本会话允许的设备组件列表（内存白名单）
--- @return table
function M.allowed()
  local cfg = require("NeoAI.kernel.config_store")
  local list = cfg.get("tools.sandbox.devices.allowed")
  return type(list) == "table" and list or {}
end

--- 覆盖写本会话允许设备列表
--- @param list table
function M.set_allowed(list)
  require("NeoAI.kernel.config_store").set("tools.sandbox.devices.allowed",
    type(list) == "table" and list or {})
end

--- 新增允许设备组件（去重）
--- @param path string
--- @return boolean ok
--- @return string|nil err
function M.add_allowed(path)
  if type(path) ~= "string" then return false, "路径为空" end
  local p = path:gsub("^%s+", ""):gsub("%s+$", "")
  if p == "" then return false, "路径为空" end
  if p:sub(1, 1) ~= "/" then return false, "需要绝对路径（以 / 开头）" end
  local list = vim.deepcopy(M.allowed())
  for _, d in ipairs(list) do
    if d == p then return false, "设备已存在" end
  end
  list[#list + 1] = p
  M.set_allowed(list)
  return true
end

--- 从本会话允许设备列表移除一项（按 1-based 序号）
--- @param index number
--- @return boolean ok
--- @return string|nil err
function M.remove_allowed(index)
  local list = vim.deepcopy(M.allowed())
  local i = tonumber(index)
  if not i or i < 1 or i > #list then return false, "序号越界" end
  table.remove(list, i)
  M.set_allowed(list)
  return true
end

--- 该具体设备是否在允许列表中
--- @param path string
--- @return boolean
function M.is_allowed(path)
  return _match_any(M.allowed(), path)
end

--- 本次会话是否已允许该具体设备（白名单或无状态 ctx 授权）
--- @param path string
--- @param ctx table|nil { sandbox_device_granted?: table }
--- @return boolean
function M.is_granted(path, ctx)
  if M.is_allowed(path) then return true end
  local g = type(ctx) == "table" and ctx.sandbox_device_granted
  if type(g) == "table" then
    for _, p in ipairs(g) do if p == path then return true end end
  end
  return false
end

--- 记录本次会话允许（并入白名单）
--- @param paths table
function M.allow_session(paths)
  if type(paths) ~= "table" then return end
  local list = vim.deepcopy(M.allowed())
  local function has(p)
    for _, d in ipairs(list) do if d == p then return true end end
    return false
  end
  for _, p in ipairs(paths) do
    if type(p) == "string" and p ~= "" and not has(p) then list[#list + 1] = p end
  end
  M.set_allowed(list)
end

--- 命令中命中且**尚未允许**的危险设备（供门禁判断是否需要弹窗）。
--- @param command string|nil 有效命令文本
--- @return table 待确认设备路径数组
function M.pending(command)
  local matched = require("NeoAI.sandbox.review.risk").device_access(command)
  if #matched == 0 then return {} end
  local out = {}
  for _, p in ipairs(matched) do
    if not M.is_allowed(p) then out[#out + 1] = p end
  end
  return out
end

--- 已批准且宿主真实存在的设备 → bwrap `--dev-bind` 挂载项。
--- @param paths table 本次命令引用的设备路径
--- @param ctx table|nil
--- @return table { { src, dst, mode = "dev" }, ... }
function M.bind_mounts(paths, ctx)
  local out, seen = {}, {}
  for _, p in ipairs(paths or {}) do
    if type(p) == "string" and p ~= "" and not seen[p] and M.is_granted(p, ctx) then
      seen[p] = true
      if _is_device(p) then
        out[#out + 1] = { src = p, dst = p, mode = "dev" }
      end
    end
  end
  return out
end

--- 是否可弹窗（启用且有独立 UI）
--- @return boolean
function M.available()
  if not M.enabled() then return false end
  return state.ui ~= nil and type(state.ui.show) == "function"
end

--- 是否可向用户呈现同意界面（独立弹窗或统一审批窗口任一可用，且确有可交互 UI）。
--- @return boolean
function M.can_prompt()
  if not M.enabled() then return false end
  if M.available() then return true end
  local ok, hub = pcall(require, "NeoAI.sandbox.review.approval_hub")
  return ok and hub.available() == true and _interactive()
end

--- 请求用户同意。
--- @param devices table 待确认设备路径数组
--- @return Deferred resolve(decision: "allow_once"|"allow_session"|"deny")
function M.request(devices)
  -- libuv 快速事件回调中不得弹窗（E5560）：调度到主循环再发起。
  if vim.in_fast_event and vim.in_fast_event() then
    local async0 = require("NeoAI.utils.async")
    local outer = async0.Deferred.new()
    vim.schedule(function()
      M.request(devices):then_(function(v) outer:resolve(v) end, function(e) outer:reject(e) end)
    end)
    return outer
  end
  local async = require("NeoAI.utils.async")
  local d = async.Deferred.new()
  devices = type(devices) == "table" and devices or {}
  if #devices == 0 then
    d:resolve("allow_once")
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
    -- 会话允许：并入本会话白名单（幂等；门禁侧另有同语义写入，二者互为兜底）。
    if decision == "allow_session" then M.allow_session(devices) end
    -- **按票据**关闭自己的窗与暂存：避免误关其它请求正在展示的同意浮窗（那会让那个请求的
    -- 决策回调永久丢失、审批中心条目残留 pending → Herder pane 一直 blocked）。
    if state.ui and state.ui.hide then pcall(state.ui.hide, ticket) end
    if hub_id then
      pcall(function()
        require("NeoAI.sandbox.review.approval_hub").clear(hub_id)
      end)
    end
    d:resolve(decision)
  end

  -- 无 UI（headless / 未启用 / 无窗口）：失败关闭。
  local hub = require("NeoAI.sandbox.review.approval_hub")
  local standalone = M.available()
  local via_hub = hub.available() and _interactive()
  if not standalone and not via_hub then
    pcall(function()
      require("NeoAI.kernel.logger").warn(
        "[device_consent] 无可用同意界面，拒绝设备访问 %s（standalone=%s hub=%s interactive=%s）",
        table.concat(devices, ","), tostring(standalone), tostring(hub.available()),
        tostring(_interactive()))
    end)
    d:resolve("deny")
    return d
  end

  local ctx = { devices = devices }
  -- 统一运行时请求广播（同一事件 SANDBOX_CONSENT_REQUESTED，page="behavior" 区分）。
  require("NeoAI.sandbox.review.consent").emit("behavior", {
    kind = "device", devices = vim.deepcopy(devices),
  })
  -- 镜像到审批分流中心「工具行为」页（窗口可决策；独立弹窗仍在时以先决策者为准）。
  hub_id = hub.submit("behavior", {
    title = "危险设备访问: " .. table.concat(devices, ", "),
    detail = {
      "设备: " .. table.concat(devices, ", "),
      "批准后该设备将绑定进本次命令的沙箱命名空间。",
    },
    decisions = {
      { key = "<CR>", label = "仅本次允许", value = "allow_once" },
      { key = "S", label = "本次会话允许该设备", value = "allow_session" },
      { key = "<Esc>", label = "拒绝", value = "deny" },
    },
    on_decision = decide,
    meta = { devices = vim.deepcopy(devices) },
  })

  -- 独立弹窗（即时阻塞响应）：存在时优先展示；决策后同步清理中心条目。
  if standalone then
    local ok, tk = pcall(state.ui.show, ctx, decide)
    if ok then ticket = tk else decide("deny") end
  else
    pcall(function() hub.open_page("behavior") end)
  end

  -- 超时兜底（fail-closed）：**仅在弹窗已呈现**时到时自动拒绝；暂存待弹 / 单槽位排队时不自动
  -- 拒绝（已镜像到统一审批悬浮窗），避免用户不在聊天界面或前一个弹窗未答完时被静默拒绝。
  -- 判定与关闭均按票据作用域：只看**本请求**的窗是否在展示，且只关自己的窗。
  -- 计时从「用户真正看到弹窗」开始（首次呈现重置完整预算），排队等待时间不计入。
  local tms = M.timeout_ms()
  if tms > 0 then
    local presented_at = nil
    local function arm(delay)
      vim.defer_fn(function()
        if done then return end
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
